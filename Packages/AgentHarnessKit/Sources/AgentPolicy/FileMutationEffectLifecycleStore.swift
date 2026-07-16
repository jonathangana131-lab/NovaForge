import AgentDomain
import Darwin
import Dispatch
import Foundation

private let mutationEffectDiskFormatVersion: UInt16 = 6

public enum FileMutationEffectLifecycleStoreError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedVersion(UInt16)
    case corruptEnvelope
    case invalidFileURL
    case invalidFileIdentity
    case invalidLockTimeout
    case lockUnavailable
    case persistenceFailed
    case generationRollback
}

enum FileMutationEffectLifecycleStoreFaultPoint: Equatable, Sendable {
    case lifecycle(MutationEffectStoreFaultPoint)
    case afterFileSyncBeforeRename
    case afterRenameBeforeDirectorySync
}

typealias FileMutationEffectLifecycleStoreFaultInjector =
    @Sendable (FileMutationEffectLifecycleStoreFaultPoint) throws -> Void

/// Crash-recoverable mutation lifecycle ledger with an independent, strict
/// schema. Missing lifecycle fields never decode as empty state.
///
/// Security boundary and durability assumptions:
/// - the ledger lives on a local filesystem honoring atomic same-directory
///   rename plus file/directory `fsync`;
/// - its parent directory and files are owned by the current effective user;
/// - this store detects corruption, path substitution, hard links, symlinks,
///   and rollback observed during one store instance's lifetime;
/// - its SHA-256 envelope is an integrity checksum, not a MAC. A hostile actor
///   with the same-user filesystem authority can recompute it and can replay a
///   valid older snapshot across process relaunch. Preventing that stronger
///   attack requires an external monotonic/secure-storage anchor.
public actor FileMutationEffectLifecycleStore:
    DurableMutationEffectLifecycleStore
{
    private static let formatVersion = mutationEffectDiskFormatVersion
    private static let maximumLockTimeoutMilliseconds: UInt64 = 60_000

    private let location: MutationEffectFileIO.Location
    private let lockTimeoutMilliseconds: UInt64
    private let faultInjector: FileMutationEffectLifecycleStoreFaultInjector?
    private var lastObservedGeneration: UInt64
    nonisolated let workspaceProcessArbiter: WorkspaceMutationProcessArbiter

    public init(
        fileURL: URL,
        lockTimeoutMilliseconds: UInt64 = 250
    ) throws {
        guard (1...Self.maximumLockTimeoutMilliseconds)
            .contains(lockTimeoutMilliseconds)
        else {
            throw FileMutationEffectLifecycleStoreError.invalidLockTimeout
        }
        let prepared = try MutationEffectFileIO.prepare(
            fileURL: fileURL,
            timeoutMilliseconds: lockTimeoutMilliseconds,
            initialEnvelope: try MutationEffectDiskEnvelope.make(
                formatVersion: Self.formatVersion,
                generation: 0,
                snapshot: .init(records: [])
            )
        )
        location = prepared.location
        workspaceProcessArbiter = try WorkspaceMutationProcessArbiter(
            directoryURL: prepared.location.directoryURL
                .appendingPathComponent(
                    ".\(prepared.location.fileName).workspace-arbiters",
                    isDirectory: true
                ),
            timeoutMilliseconds: lockTimeoutMilliseconds
        )
        self.lockTimeoutMilliseconds = lockTimeoutMilliseconds
        faultInjector = nil
        lastObservedGeneration = prepared.generation
    }

    init(
        fileURL: URL,
        lockTimeoutMilliseconds: UInt64 = 250,
        faultInjector: @escaping FileMutationEffectLifecycleStoreFaultInjector
    ) throws {
        guard (1...Self.maximumLockTimeoutMilliseconds)
            .contains(lockTimeoutMilliseconds)
        else {
            throw FileMutationEffectLifecycleStoreError.invalidLockTimeout
        }
        let prepared = try MutationEffectFileIO.prepare(
            fileURL: fileURL,
            timeoutMilliseconds: lockTimeoutMilliseconds,
            initialEnvelope: try MutationEffectDiskEnvelope.make(
                formatVersion: Self.formatVersion,
                generation: 0,
                snapshot: .init(records: [])
            )
        )
        location = prepared.location
        workspaceProcessArbiter = try WorkspaceMutationProcessArbiter(
            directoryURL: prepared.location.directoryURL
                .appendingPathComponent(
                    ".\(prepared.location.fileName).workspace-arbiters",
                    isDirectory: true
                ),
            timeoutMilliseconds: lockTimeoutMilliseconds
        )
        self.lockTimeoutMilliseconds = lockTimeoutMilliseconds
        self.faultInjector = faultInjector
        lastObservedGeneration = prepared.generation
    }

    public func insertPendingIfAbsent(
        _ record: MutationEffectRecord
    ) throws -> MutationEffectInsertDisposition {
        guard record.isCanonical(), record.phase == .pending else {
            throw MutationEffectLifecycleError.invalidInitialPhase(record.phase)
        }
        return try transaction(
            faultPoints: (
                .beforePendingCommit,
                .afterPendingCommit
            )
        ) { records in
            if let existing = records[record.effectKeySHA256] {
                guard existing.binding == record.binding else {
                    throw MutationEffectLifecycleError.recordConflict(
                        record.effectKeySHA256
                    )
                }
                return (.alreadyPresent(existing), false)
            }
            records[record.effectKeySHA256] = record
            return (.inserted(record), true)
        }
    }

    public func compareAndTransition(
        expectedRecordSHA256: SHA256Digest,
        to next: MutationEffectRecord
    ) throws -> MutationEffectTransitionDisposition {
        try transaction(
            faultPoints: InMemoryMutationEffectLifecycleStore.faultPoints(
                for: next.phase
            )
        ) { records in
            guard let current = records[next.effectKeySHA256] else {
                throw MutationEffectLifecycleError.recordNotFound(
                    next.effectKeySHA256
                )
            }
            if current == next {
                return (.alreadyCommitted(current), false)
            }
            guard current.recordSHA256 == expectedRecordSHA256 else {
                throw MutationEffectLifecycleError.staleRecord(
                    expected: expectedRecordSHA256,
                    actual: current.recordSHA256
                )
            }
            try MutationEffectRecord.validateTransition(
                from: current,
                to: next
            )
            records[next.effectKeySHA256] = next
            return (.committed(next), true)
        }
    }

    public func record(
        effectKeySHA256: SHA256Digest
    ) throws -> MutationEffectRecord? {
        try read { records in records[effectKeySHA256] }
    }

    public func snapshot() throws -> MutationEffectLedgerSnapshot {
        try read { records in Self.snapshot(records) }
    }

    private func transaction<Result: Sendable>(
        faultPoints: (
            before: MutationEffectStoreFaultPoint,
            after: MutationEffectStoreFaultPoint
        ),
        _ mutation: (inout [SHA256Digest: MutationEffectRecord]) throws
            -> (result: Result, changed: Bool)
    ) throws -> Result {
        let location = location
        let timeout = lockTimeoutMilliseconds
        let injector = faultInjector
        let minimumGeneration = lastObservedGeneration
        let outcome = try MutationEffectFileIO.withExclusiveLock(
            at: location,
            timeoutMilliseconds: timeout
        ) { directoryDescriptor in
            let current = try Self.load(
                directoryDescriptor: directoryDescriptor,
                location: location
            )
            guard current.generation >= minimumGeneration else {
                throw FileMutationEffectLifecycleStoreError.generationRollback
            }
            var records = try Self.validatedMap(current.snapshot)
            let value = try mutation(&records)
            guard value.changed else {
                return TransactionOutcome(
                    result: value.result,
                    generation: current.generation
                )
            }
            guard current.generation < UInt64.max else {
                throw FileMutationEffectLifecycleStoreError.corruptEnvelope
            }
            try injector?(.lifecycle(faultPoints.before))
            let next = try MutationEffectDiskEnvelope.make(
                formatVersion: Self.formatVersion,
                generation: current.generation + 1,
                snapshot: Self.snapshot(records)
            )
            try MutationEffectFileIO.persist(
                next,
                directoryDescriptor: directoryDescriptor,
                location: location,
                faultInjector: injector
            )
            try injector?(.lifecycle(faultPoints.after))
            return TransactionOutcome(
                result: value.result,
                generation: next.generation
            )
        }
        lastObservedGeneration = max(
            lastObservedGeneration,
            outcome.generation
        )
        return outcome.result
    }

    private func read<Result: Sendable>(
        _ body: ([SHA256Digest: MutationEffectRecord]) throws -> Result
    ) throws -> Result {
        let location = location
        let minimumGeneration = lastObservedGeneration
        let outcome = try MutationEffectFileIO.withExclusiveLock(
            at: location,
            timeoutMilliseconds: lockTimeoutMilliseconds
        ) { directoryDescriptor in
            let envelope = try Self.load(
                directoryDescriptor: directoryDescriptor,
                location: location
            )
            guard envelope.generation >= minimumGeneration else {
                throw FileMutationEffectLifecycleStoreError.generationRollback
            }
            return TransactionOutcome(
                result: try body(Self.validatedMap(envelope.snapshot)),
                generation: envelope.generation
            )
        }
        lastObservedGeneration = max(
            lastObservedGeneration,
            outcome.generation
        )
        return outcome.result
    }

    private static func load(
        directoryDescriptor: Int32,
        location: MutationEffectFileIO.Location
    ) throws -> MutationEffectDiskEnvelope {
        let data = try MutationEffectFileIO.readLedger(
            directoryDescriptor: directoryDescriptor,
            location: location
        )
        let envelope: MutationEffectDiskEnvelope
        do {
            envelope = try JSONDecoder().decode(
                MutationEffectDiskEnvelope.self,
                from: data
            )
        } catch let error as FileMutationEffectLifecycleStoreError {
            throw error
        } catch {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        guard envelope.formatVersion == formatVersion else {
            throw FileMutationEffectLifecycleStoreError.unsupportedVersion(
                envelope.formatVersion
            )
        }
        _ = try validatedMap(envelope.snapshot)
        return envelope
    }

    private static func validatedMap(
        _ snapshot: MutationEffectLedgerSnapshot
    ) throws -> [SHA256Digest: MutationEffectRecord] {
        let map = try InMemoryMutationEffectLifecycleStore.validatedMap(
            snapshot.records
        )
        guard snapshot == Self.snapshot(map) else {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        return map
    }

    private static func snapshot(
        _ records: [SHA256Digest: MutationEffectRecord]
    ) -> MutationEffectLedgerSnapshot {
        MutationEffectLedgerSnapshot(records: records.values.sorted {
            $0.effectKeySHA256.rawValue < $1.effectKeySHA256.rawValue
        })
    }
}

private struct TransactionOutcome<Result: Sendable>: Sendable {
    let result: Result
    let generation: UInt64
}

private struct MutationEffectDiskEnvelope: Codable, Sendable {
    let formatVersion: UInt16
    let generation: UInt64
    let snapshot: MutationEffectLedgerSnapshot
    let envelopeSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let formatVersion: UInt16
        let generation: UInt64
        let snapshot: MutationEffectLedgerSnapshot
    }

    static func make(
        formatVersion: UInt16,
        generation: UInt64,
        snapshot: MutationEffectLedgerSnapshot
    ) throws -> Self {
        let map = try InMemoryMutationEffectLifecycleStore.validatedMap(
            snapshot.records
        )
        let canonical = MutationEffectLedgerSnapshot(
            records: map.values.sorted {
                $0.effectKeySHA256.rawValue < $1.effectKeySHA256.rawValue
            }
        )
        guard canonical == snapshot else {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        let material = DigestMaterial(
            formatVersion: formatVersion,
            generation: generation,
            snapshot: snapshot
        )
        return Self(
            formatVersion: formatVersion,
            generation: generation,
            snapshot: snapshot,
            envelopeSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationLedgerEnvelope,
                material
            )
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(
            UInt16.self,
            forKey: .formatVersion
        )
        guard formatVersion == mutationEffectDiskFormatVersion else {
            throw FileMutationEffectLifecycleStoreError.unsupportedVersion(
                formatVersion
            )
        }
        let generation = try container.decode(
            UInt64.self,
            forKey: .generation
        )
        let snapshot = try container.decode(
            MutationEffectLedgerSnapshot.self,
            forKey: .snapshot
        )
        let rebuilt = try Self.make(
            formatVersion: formatVersion,
            generation: generation,
            snapshot: snapshot
        )
        guard rebuilt.envelopeSHA256 == (try container.decode(
            SHA256Digest.self,
            forKey: .envelopeSHA256
        )) else {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        self = rebuilt
    }

    private init(
        formatVersion: UInt16,
        generation: UInt64,
        snapshot: MutationEffectLedgerSnapshot,
        envelopeSHA256: SHA256Digest
    ) {
        self.formatVersion = formatVersion
        self.generation = generation
        self.snapshot = snapshot
        self.envelopeSHA256 = envelopeSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case generation
        case snapshot
        case envelopeSHA256
    }
}

private enum MutationEffectFileIO {
    private static let maximumFileBytes: Int = 32 * 1_024 * 1_024
    private static let processSemaphore = DispatchSemaphore(value: 1)
    private static let lockMarker = Data(
        "NovaForgeMutationEffectLifecycleLock-v6\n".utf8
    )

    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    struct Location: Sendable {
        let directoryURL: URL
        let fileName: String
        let lockName: String
        let directoryIdentity: FileIdentity
        let lockIdentity: FileIdentity
    }

    struct Preparation: Sendable {
        let location: Location
        let generation: UInt64
    }

    static func prepare(
        fileURL: URL,
        timeoutMilliseconds: UInt64,
        initialEnvelope: MutationEffectDiskEnvelope
    ) throws -> Preparation {
        guard fileURL.isFileURL,
              !fileURL.lastPathComponent.isEmpty,
              fileURL.lastPathComponent != ".",
              fileURL.lastPathComponent != ".."
        else {
            throw FileMutationEffectLifecycleStoreError.invalidFileURL
        }
        let requestedDirectory = fileURL.standardizedFileURL
            .deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: requestedDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw FileMutationEffectLifecycleStoreError.persistenceFailed
        }
        let directoryURL = requestedDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let fileName = fileURL.lastPathComponent
        let lockName = ".\(fileName).mutation-effect.lock"

        let deadline = deadline(after: timeoutMilliseconds)
        try acquireProcessLock(until: deadline)
        defer { processSemaphore.signal() }

        let directoryDescriptor = try openDirectory(at: directoryURL)
        defer { Darwin.close(directoryDescriptor) }
        let directoryStatus = try validatedDirectory(
            descriptor: directoryDescriptor
        )
        let lockDescriptor = try openLock(
            directoryDescriptor: directoryDescriptor,
            name: lockName
        )
        defer { Darwin.close(lockDescriptor) }
        try acquireFileLock(descriptor: lockDescriptor, until: deadline)
        defer { releaseFileLock(descriptor: lockDescriptor) }
        let lockStatus = try validatedRegularFile(
            descriptor: lockDescriptor,
            directoryDescriptor: directoryDescriptor,
            name: lockName
        )
        let marker = try readAll(
            descriptor: lockDescriptor,
            expectedSize: Int(lockStatus.st_size),
            maximumBytes: lockMarker.count
        )
        let location = Location(
            directoryURL: directoryURL,
            fileName: fileName,
            lockName: lockName,
            directoryIdentity: FileIdentity(directoryStatus),
            lockIdentity: FileIdentity(lockStatus)
        )
        let ledgerExists = entryExists(
            directoryDescriptor: directoryDescriptor,
            name: fileName
        )
        if marker.isEmpty {
            if ledgerExists {
                _ = try readLedger(
                    directoryDescriptor: directoryDescriptor,
                    location: location
                )
            } else {
                try persist(
                    initialEnvelope,
                    directoryDescriptor: directoryDescriptor,
                    location: location,
                    faultInjector: nil
                )
            }
            try replaceContents(
                descriptor: lockDescriptor,
                data: lockMarker
            )
            try synchronize(descriptor: directoryDescriptor)
        } else {
            guard marker == lockMarker, ledgerExists else {
                throw FileMutationEffectLifecycleStoreError.corruptEnvelope
            }
        }

        let data = try readLedger(
            directoryDescriptor: directoryDescriptor,
            location: location
        )
        let envelope: MutationEffectDiskEnvelope
        do {
            envelope = try JSONDecoder().decode(
                MutationEffectDiskEnvelope.self,
                from: data
            )
        } catch let error as FileMutationEffectLifecycleStoreError {
            throw error
        } catch {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        guard envelope.formatVersion == initialEnvelope.formatVersion else {
            throw FileMutationEffectLifecycleStoreError.unsupportedVersion(
                envelope.formatVersion
            )
        }
        return Preparation(location: location, generation: envelope.generation)
    }

    static func withExclusiveLock<Result: Sendable>(
        at location: Location,
        timeoutMilliseconds: UInt64,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        let deadline = deadline(after: timeoutMilliseconds)
        try acquireProcessLock(until: deadline)
        defer { processSemaphore.signal() }
        let directoryDescriptor = try openDirectory(at: location.directoryURL)
        defer { Darwin.close(directoryDescriptor) }
        let directoryStatus = try validatedDirectory(
            descriptor: directoryDescriptor
        )
        guard FileIdentity(directoryStatus) == location.directoryIdentity else {
            throw FileMutationEffectLifecycleStoreError.invalidFileIdentity
        }
        let lockDescriptor = try openLock(
            directoryDescriptor: directoryDescriptor,
            name: location.lockName
        )
        defer { Darwin.close(lockDescriptor) }
        let openedLockStatus = try validatedRegularFile(
            descriptor: lockDescriptor,
            directoryDescriptor: directoryDescriptor,
            name: location.lockName
        )
        guard FileIdentity(openedLockStatus) == location.lockIdentity else {
            throw FileMutationEffectLifecycleStoreError.invalidFileIdentity
        }
        try acquireFileLock(descriptor: lockDescriptor, until: deadline)
        defer { releaseFileLock(descriptor: lockDescriptor) }
        let lockedStatus = try validatedRegularFile(
            descriptor: lockDescriptor,
            directoryDescriptor: directoryDescriptor,
            name: location.lockName
        )
        guard FileIdentity(lockedStatus) == location.lockIdentity else {
            throw FileMutationEffectLifecycleStoreError.invalidFileIdentity
        }
        let marker = try readAll(
            descriptor: lockDescriptor,
            expectedSize: Int(lockedStatus.st_size),
            maximumBytes: lockMarker.count
        )
        guard marker == lockMarker else {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        return try body(directoryDescriptor)
    }

    static func readLedger(
        directoryDescriptor: Int32,
        location: Location
    ) throws -> Data {
        let descriptor = openAt(
            directoryDescriptor: directoryDescriptor,
            name: location.fileName,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW,
            mode: 0
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw FileMutationEffectLifecycleStoreError.invalidFileIdentity
            }
            throw FileMutationEffectLifecycleStoreError.persistenceFailed
        }
        defer { Darwin.close(descriptor) }
        let status = try validatedRegularFile(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            name: location.fileName
        )
        guard status.st_size >= 0,
              status.st_size <= maximumFileBytes
        else {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        return try readAll(
            descriptor: descriptor,
            expectedSize: Int(status.st_size),
            maximumBytes: maximumFileBytes
        )
    }

    static func persist(
        _ envelope: MutationEffectDiskEnvelope,
        directoryDescriptor: Int32,
        location: Location,
        faultInjector: FileMutationEffectLifecycleStoreFaultInjector?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        guard data.count <= maximumFileBytes else {
            throw FileMutationEffectLifecycleStoreError.persistenceFailed
        }
        let temporaryName =
            ".\(location.fileName).\(UUID().uuidString).tmp"
        let descriptor = openAt(
            directoryDescriptor: directoryDescriptor,
            name: temporaryName,
            flags: O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode: S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw FileMutationEffectLifecycleStoreError.persistenceFailed
        }
        var shouldUnlink = true
        defer {
            Darwin.close(descriptor)
            if shouldUnlink {
                _ = temporaryName.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }
        _ = try validatedRegularFile(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            name: temporaryName
        )
        try writeAll(descriptor: descriptor, data: data)
        try synchronize(descriptor: descriptor)
        try faultInjector?(.afterFileSyncBeforeRename)
        let renamed = temporaryName.withCString { temporary in
            location.fileName.withCString { destination in
                Darwin.renameat(
                    directoryDescriptor,
                    temporary,
                    directoryDescriptor,
                    destination
                )
            }
        }
        guard renamed == 0 else {
            throw FileMutationEffectLifecycleStoreError.persistenceFailed
        }
        shouldUnlink = false
        try faultInjector?(.afterRenameBeforeDirectorySync)
        try synchronize(descriptor: directoryDescriptor)
    }

    private static func deadline(after milliseconds: UInt64) -> DispatchTime {
        .now() + .milliseconds(Int(milliseconds))
    }

    private static func acquireProcessLock(until deadline: DispatchTime) throws {
        guard processSemaphore.wait(timeout: deadline) == .success else {
            throw FileMutationEffectLifecycleStoreError.lockUnavailable
        }
    }

    private static func acquireFileLock(
        descriptor: Int32,
        until deadline: DispatchTime
    ) throws {
        while true {
            var lock = Darwin.flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            lock.l_start = 0
            lock.l_len = 0
            if Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 { return }
            let code = errno
            guard code == EACCES || code == EAGAIN else {
                throw FileMutationEffectLifecycleStoreError.lockUnavailable
            }
            guard DispatchTime.now() < deadline else {
                throw FileMutationEffectLifecycleStoreError.lockUnavailable
            }
            Darwin.usleep(2_000)
        }
    }

    private static func releaseFileLock(descriptor: Int32) {
        var lock = Darwin.flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    private static func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw FileMutationEffectLifecycleStoreError.invalidFileIdentity
        }
        return descriptor
    }

    private static func openLock(
        directoryDescriptor: Int32,
        name: String
    ) throws -> Int32 {
        let descriptor = openAt(
            directoryDescriptor: directoryDescriptor,
            name: name,
            flags: O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode: S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw FileMutationEffectLifecycleStoreError.lockUnavailable
        }
        return descriptor
    }

    private static func openAt(
        directoryDescriptor: Int32,
        name: String,
        flags: Int32,
        mode: mode_t
    ) -> Int32 {
        name.withCString {
            Darwin.openat(directoryDescriptor, $0, flags, mode)
        }
    }

    private static func validatedDirectory(
        descriptor: Int32
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == Darwin.geteuid(),
              status.st_mode & 0o022 == 0
        else {
            throw FileMutationEffectLifecycleStoreError.invalidFileIdentity
        }
        return status
    }

    private static func validatedRegularFile(
        descriptor: Int32,
        directoryDescriptor: Int32,
        name: String
    ) throws -> stat {
        var descriptorStatus = stat()
        var pathStatus = stat()
        let pathResult = name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              pathResult == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_mode & S_IFMT == S_IFREG,
              descriptorStatus.st_nlink == 1,
              pathStatus.st_nlink == 1,
              descriptorStatus.st_uid == Darwin.geteuid(),
              pathStatus.st_uid == Darwin.geteuid(),
              descriptorStatus.st_mode & 0o077 == 0,
              pathStatus.st_mode & 0o077 == 0,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino
        else {
            throw FileMutationEffectLifecycleStoreError.invalidFileIdentity
        }
        return descriptorStatus
    }

    private static func entryExists(
        directoryDescriptor: Int32,
        name: String
    ) -> Bool {
        var status = stat()
        return name.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        } == 0
    }

    private static func readAll(
        descriptor: Int32,
        expectedSize: Int,
        maximumBytes: Int
    ) throws -> Data {
        guard expectedSize >= 0, expectedSize <= maximumBytes else {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw FileMutationEffectLifecycleStoreError.persistenceFailed
        }
        var result = Data()
        result.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, max(1, maximumBytes)))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw FileMutationEffectLifecycleStoreError.persistenceFailed
            }
            guard result.count + count <= maximumBytes else {
                throw FileMutationEffectLifecycleStoreError.corruptEnvelope
            }
            result.append(buffer, count: count)
        }
        guard result.count == expectedSize else {
            throw FileMutationEffectLifecycleStoreError.corruptEnvelope
        }
        return result
    }

    private static func writeAll(descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FileMutationEffectLifecycleStoreError.persistenceFailed
                }
                guard written > 0 else {
                    throw FileMutationEffectLifecycleStoreError.persistenceFailed
                }
                offset += written
            }
        }
    }

    private static func replaceContents(
        descriptor: Int32,
        data: Data
    ) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
        else {
            throw FileMutationEffectLifecycleStoreError.persistenceFailed
        }
        try writeAll(descriptor: descriptor, data: data)
        try synchronize(descriptor: descriptor)
    }

    private static func synchronize(descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw FileMutationEffectLifecycleStoreError.persistenceFailed
        }
    }
}
