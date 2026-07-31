import AgentDomain
import AgentEngine
import CryptoKit
import Darwin
import Dispatch
import Foundation

enum DurableAgentEngineRunIndexError: Error, Equatable, Sendable {
    case unsupportedVersion(UInt16)
    case corruptEnvelope
    case invalidFileURL
    case invalidFileIdentity
    case invalidLockTimeout
    case lockUnavailable
    case persistenceFailed
    case generationRollback
    case generationFork
    case capacityExceeded
}

enum DurableAgentEngineRunIndexEntryState: Equatable, Sendable {
    case active
    case abandoned
    case terminal(AgentEngineTerminalRecord)
}

struct DurableAgentEngineRunIndexEntrySnapshot: Equatable, Sendable {
    let runID: RunID
    let fence: AgentEngineOwnerFence
    let state: DurableAgentEngineRunIndexEntryState
}

struct DurableAgentEngineRunIndexCapacity: Equatable, Sendable {
    let usedEntryCount: Int
    let maximumEntryCount: Int

    var remainingEntryCount: Int {
        max(0, maximumEntryCount - usedEntryCount)
    }

    var isExhausted: Bool {
        usedEntryCount >= maximumEntryCount
    }
}

/// A canonical, ledger-generation-bound view used by startup reconciliation.
///
/// Terminal and abandoned entries remain enumerable generation tombstones.
/// The capacity fields intentionally expose the finite lifetime ceiling; this
/// type does not claim that entries can be evicted without a journal-anchored
/// compaction protocol.
struct DurableAgentEngineRunIndexSnapshot: Equatable, Sendable {
    let storeID: UUID
    let ledgerGeneration: UInt64
    let entries: [DurableAgentEngineRunIndexEntrySnapshot]
    let capacity: DurableAgentEngineRunIndexCapacity
}

enum DurableAgentEngineRunIndexFaultPoint: Sendable {
    case afterFileSyncBeforeRename
    case afterRenameBeforeDirectorySync
}

typealias DurableAgentEngineRunIndexFaultInjector =
    @Sendable (DurableAgentEngineRunIndexFaultPoint) throws -> Void

/// Process-safe durable ownership and terminal index for `AgentEngine`.
///
/// The index deliberately retains abandoned entries as generation tombstones.
/// A later claim therefore advances the same persisted generation instead of
/// reviving generation one. All reads and mutations cross one bounded POSIX
/// record lock, and every replacement is file-fsync, atomic-rename, then
/// directory-fsync ordered.
///
/// The checksum and live-instance generation observation detect corruption,
/// same-generation forks, and rollback observed by any still-live adapter.
/// They are not a secure monotonic anchor: a malicious same-user process that
/// can replace the complete directory while every adapter is stopped remains
/// outside the cooperating-process app boundary and is an M10 responsibility.
actor DurableAgentEngineRunIndex: AgentEngineRunIndexing {
    private static let formatVersion: UInt16 = 1
    private static let maximumEntryCount = 65_536
    private static let maximumLockTimeoutMilliseconds: UInt64 = 60_000

    private let location: DurableAgentEngineRunIndexFileIO.Location
    private let lockTimeoutMilliseconds: UInt64
    private let faultInjector: DurableAgentEngineRunIndexFaultInjector?
    private var lastObservedGeneration: UInt64
    private var lastObservedEnvelopeSHA256: String

    init(
        fileURL: URL,
        lockTimeoutMilliseconds: UInt64 = 250,
        requireCompleteProtection: Bool = false,
        faultInjector: DurableAgentEngineRunIndexFaultInjector? = nil
    ) throws {
        guard (1 ... Self.maximumLockTimeoutMilliseconds).contains(
            lockTimeoutMilliseconds
        ) else {
            throw DurableAgentEngineRunIndexError.invalidLockTimeout
        }
        let prepared = try DurableAgentEngineRunIndexFileIO.prepare(
            fileURL: fileURL,
            timeoutMilliseconds: lockTimeoutMilliseconds,
            formatVersion: Self.formatVersion,
            requireCompleteProtection: requireCompleteProtection
        )
        let envelope = try Self.decodeValidated(prepared.data)
        guard envelope.storeID == prepared.location.storeID else {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        location = prepared.location
        self.lockTimeoutMilliseconds = lockTimeoutMilliseconds
        self.faultInjector = faultInjector
        lastObservedGeneration = envelope.generation
        lastObservedEnvelopeSHA256 = envelope.envelopeSHA256
    }

    /// Production composition boundary. Its returned index lives only inside a
    /// complete-protection, backup-excluded Application Support directory.
    static func production(
        lockTimeoutMilliseconds: UInt64 = 250
    ) throws -> DurableAgentEngineRunIndex {
        let paths = try AgentEngineRunIndexStorePaths.prepare()
        return try DurableAgentEngineRunIndex(
            fileURL: paths.ledgerURL,
            lockTimeoutMilliseconds: lockTimeoutMilliseconds,
            requireCompleteProtection: true,
            faultInjector: nil
        )
    }

    func claim(
        runID: RunID,
        ownerID: UUID,
        mode: AgentEngineRunClaimMode
    ) throws -> AgentEngineOwnerFence {
        try transaction { entries in
            if var entry = entries[runID] {
                guard entry.terminal == nil else {
                    throw AgentEngineRunIndexError.runAlreadyTerminal(runID)
                }
                if entry.isActive, mode == .newRun {
                    throw AgentEngineRunIndexError.ownerAlreadyActive(runID)
                }
                guard entry.generation < UInt64.max else {
                    throw AgentEngineRunIndexError.generationExhausted(runID)
                }
                entry.generation += 1
                entry.ownerID = ownerID
                entry.isActive = true
                entries[runID] = entry
                return entry.fence
            }

            guard entries.count < Self.maximumEntryCount else {
                throw DurableAgentEngineRunIndexError.capacityExceeded
            }
            let entry = DiskEntry(
                runID: runID,
                ownerID: ownerID,
                generation: 1,
                isActive: true,
                terminal: nil
            )
            entries[runID] = entry
            return entry.fence
        }
    }

    func validate(_ fence: AgentEngineOwnerFence) throws {
        try read { _, entries in
            guard let entry = entries[fence.runID],
                  entry.isActive,
                  entry.terminal == nil,
                  entry.fence == fence
            else { throw AgentEngineRunIndexError.staleOwner(fence) }
        }
    }

    /// The package protocol cannot report an abandonment persistence failure.
    /// Failure therefore leaves the old durable owner active (fail closed), so
    /// recovery must supersede it with a higher generation.
    func abandon(_ fence: AgentEngineOwnerFence) {
        try? abandonDurably(fence)
    }

    func abandonDurably(_ fence: AgentEngineOwnerFence) throws {
        try transaction { entries in
            guard var entry = entries[fence.runID],
                  entry.isActive,
                  entry.terminal == nil,
                  entry.fence == fence
            else { return }
            entry.isActive = false
            entries[fence.runID] = entry
        }
    }

    func settle(_ record: AgentEngineTerminalRecord) throws {
        guard record.phase.isTerminal else {
            throw AgentEngineRunIndexError.invalidTerminalPhase(record.phase)
        }
        try transaction { entries in
            guard var entry = entries[record.runID],
                  entry.fence == record.fence
            else { throw AgentEngineRunIndexError.staleOwner(record.fence) }

            if let terminal = entry.terminal {
                guard terminal == record else {
                    throw AgentEngineRunIndexError.runAlreadyTerminal(record.runID)
                }
                return
            }
            guard entry.isActive else {
                throw AgentEngineRunIndexError.staleOwner(record.fence)
            }
            entry.isActive = false
            entry.terminal = record
            entries[record.runID] = entry
        }
    }

    func terminalRecord(for runID: RunID) throws -> AgentEngineTerminalRecord? {
        try read { _, entries in entries[runID]?.terminal }
    }

    func persistedFence(for runID: RunID) throws -> AgentEngineOwnerFence? {
        try read { _, entries in entries[runID]?.fence }
    }

    func snapshot() throws -> DurableAgentEngineRunIndexSnapshot {
        try read { envelope, entries in
            let snapshots = Self.entrySnapshot(entries).map { entry in
                let state: DurableAgentEngineRunIndexEntryState
                if let terminal = entry.terminal {
                    state = .terminal(terminal)
                } else if entry.isActive {
                    state = .active
                } else {
                    state = .abandoned
                }
                return DurableAgentEngineRunIndexEntrySnapshot(
                    runID: entry.runID,
                    fence: entry.fence,
                    state: state
                )
            }
            return DurableAgentEngineRunIndexSnapshot(
                storeID: envelope.storeID,
                ledgerGeneration: envelope.generation,
                entries: snapshots,
                capacity: DurableAgentEngineRunIndexCapacity(
                    usedEntryCount: snapshots.count,
                    maximumEntryCount: Self.maximumEntryCount
                )
            )
        }
    }

    private func read<Result: Sendable>(
        _ body: (DiskEnvelope, [RunID: DiskEntry]) throws -> Result
    ) throws -> Result {
        try DurableAgentEngineRunIndexFileIO.withExclusiveLock(
            at: location,
            timeoutMilliseconds: lockTimeoutMilliseconds
        ) { directoryDescriptor in
            let data = try DurableAgentEngineRunIndexFileIO.readLedger(
                directoryDescriptor: directoryDescriptor,
                location: location
            )
            let envelope = try Self.decodeValidated(data)
            try observe(envelope)
            return try body(envelope, try Self.entryMap(envelope.entries))
        }
    }

    private func transaction<Result: Sendable>(
        _ body: (inout [RunID: DiskEntry]) throws -> Result
    ) throws -> Result {
        try DurableAgentEngineRunIndexFileIO.withExclusiveLock(
            at: location,
            timeoutMilliseconds: lockTimeoutMilliseconds
        ) { directoryDescriptor in
            let data = try DurableAgentEngineRunIndexFileIO.readLedger(
                directoryDescriptor: directoryDescriptor,
                location: location
            )
            let current = try Self.decodeValidated(data)
            try observe(current)
            var entries = try Self.entryMap(current.entries)
            let before = entries
            let result = try body(&entries)
            guard entries != before else { return result }
            guard current.generation < UInt64.max else {
                throw DurableAgentEngineRunIndexError.capacityExceeded
            }
            let next = try DiskEnvelope.make(
                formatVersion: Self.formatVersion,
                storeID: current.storeID,
                generation: current.generation + 1,
                entries: Self.entrySnapshot(entries)
            )
            try DurableAgentEngineRunIndexFileIO.persist(
                next,
                directoryDescriptor: directoryDescriptor,
                location: location,
                faultInjector: faultInjector
            )
            lastObservedGeneration = next.generation
            lastObservedEnvelopeSHA256 = next.envelopeSHA256
            return result
        }
    }

    private func observe(_ envelope: DiskEnvelope) throws {
        guard envelope.storeID == location.storeID else {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        guard envelope.generation >= lastObservedGeneration else {
            throw DurableAgentEngineRunIndexError.generationRollback
        }
        if envelope.generation == lastObservedGeneration {
            guard envelope.envelopeSHA256 == lastObservedEnvelopeSHA256 else {
                throw DurableAgentEngineRunIndexError.generationFork
            }
        } else {
            lastObservedGeneration = envelope.generation
            lastObservedEnvelopeSHA256 = envelope.envelopeSHA256
        }
    }

    fileprivate static func validatedStoreID(in data: Data) throws -> UUID {
        try decodeValidated(data).storeID
    }

    private static func decodeValidated(_ data: Data) throws -> DiskEnvelope {
        let envelope: DiskEnvelope
        do {
            envelope = try JSONDecoder().decode(DiskEnvelope.self, from: data)
        } catch {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        guard envelope.formatVersion == formatVersion else {
            throw DurableAgentEngineRunIndexError.unsupportedVersion(
                envelope.formatVersion
            )
        }
        guard envelope.entries.count <= maximumEntryCount,
              envelope.envelopeSHA256.count == 64,
              envelope.envelopeSHA256 == envelope.envelopeSHA256.lowercased()
        else { throw DurableAgentEngineRunIndexError.corruptEnvelope }

        let rebuilt = try DiskEnvelope.make(
            formatVersion: envelope.formatVersion,
            storeID: envelope.storeID,
            generation: envelope.generation,
            entries: envelope.entries
        )
        guard rebuilt.envelopeSHA256 == envelope.envelopeSHA256 else {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalData: Data
        do {
            canonicalData = try canonicalEncoder.encode(envelope)
        } catch {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        guard canonicalData == data else {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        _ = try entryMap(envelope.entries)
        return envelope
    }

    private static func entryMap(
        _ snapshot: [DiskEntry]
    ) throws -> [RunID: DiskEntry] {
        var result: [RunID: DiskEntry] = [:]
        var previousRunID: String?
        for entry in snapshot {
            let runDescription = entry.runID.description
            if let previousRunID, runDescription <= previousRunID {
                throw DurableAgentEngineRunIndexError.corruptEnvelope
            }
            previousRunID = runDescription
            guard entry.generation > 0,
                  result.updateValue(entry, forKey: entry.runID) == nil
            else { throw DurableAgentEngineRunIndexError.corruptEnvelope }

            if let terminal = entry.terminal {
                guard !entry.isActive,
                      terminal.phase.isTerminal,
                      terminal.runID == entry.runID,
                      terminal.fence == entry.fence
                else { throw DurableAgentEngineRunIndexError.corruptEnvelope }
            }
        }
        return result
    }

    private static func entrySnapshot(
        _ entries: [RunID: DiskEntry]
    ) -> [DiskEntry] {
        entries.values.sorted { $0.runID.description < $1.runID.description }
    }
}

private struct DiskEntry: Codable, Equatable, Sendable {
    let runID: RunID
    var ownerID: UUID
    var generation: UInt64
    var isActive: Bool
    var terminal: AgentEngineTerminalRecord?

    var fence: AgentEngineOwnerFence {
        AgentEngineOwnerFence(
            runID: runID,
            ownerID: ownerID,
            generation: generation
        )
    }
}

private struct DiskEnvelope: Codable, Equatable, Sendable {
    let formatVersion: UInt16
    let storeID: UUID
    let generation: UInt64
    let entries: [DiskEntry]
    let envelopeSHA256: String

    static func make(
        formatVersion: UInt16,
        storeID: UUID,
        generation: UInt64,
        entries: [DiskEntry]
    ) throws -> DiskEnvelope {
        let payload = DiskEnvelopeChecksumPayload(
            formatVersion: formatVersion,
            storeID: storeID,
            generation: generation,
            entries: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        let digest = CryptoKit.SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return DiskEnvelope(
            formatVersion: formatVersion,
            storeID: storeID,
            generation: generation,
            entries: entries,
            envelopeSHA256: digest
        )
    }
}

private struct DiskEnvelopeChecksumPayload: Codable, Sendable {
    let formatVersion: UInt16
    let storeID: UUID
    let generation: UInt64
    let entries: [DiskEntry]
}

private enum DurableAgentEngineRunIndexFileIO {
    static let maximumFileBytes = 32 * 1_024 * 1_024
    static let maximumLockMarkerBytes = 128
    static let processSemaphore = DispatchSemaphore(value: 1)

    struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(truncatingIfNeeded: status.st_dev)
            inode = UInt64(truncatingIfNeeded: status.st_ino)
        }
    }

    struct Location: Sendable {
        let directoryURL: URL
        let fileName: String
        let lockName: String
        let storeID: UUID
        let directoryIdentity: FileIdentity
        let lockIdentity: FileIdentity
    }

    struct Preparation: Sendable {
        let location: Location
        let data: Data
    }

    static func prepare(
        fileURL requestedURL: URL,
        timeoutMilliseconds: UInt64,
        formatVersion: UInt16,
        requireCompleteProtection: Bool
    ) throws -> Preparation {
        guard requestedURL.isFileURL,
              requestedURL.path.hasPrefix("/"),
              !requestedURL.lastPathComponent.isEmpty,
              requestedURL.lastPathComponent != ".",
              requestedURL.lastPathComponent != ".."
        else { throw DurableAgentEngineRunIndexError.invalidFileURL }

        let fileURL = requestedURL.standardizedFileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        let fileName = fileURL.lastPathComponent
        guard !fileName.contains("/"), !fileName.contains("\0") else {
            throw DurableAgentEngineRunIndexError.invalidFileURL
        }
        let lockName = ".\(fileName).lock"
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

        // Another process may have initialized the marker while this process
        // waited for the record lock. Re-read size and fd/path identity only
        // after ownership; using a pre-lock st_size can misread a valid marker
        // as an empty/corrupt file during first-open races.
        let lockStatus = try validatedRegularFile(
            descriptor: lockDescriptor,
            directoryDescriptor: directoryDescriptor,
            name: lockName
        )

        let marker = try readAll(
            descriptor: lockDescriptor,
            expectedSize: Int(lockStatus.st_size),
            maximumBytes: maximumLockMarkerBytes
        )
        let ledgerExists = entryExists(
            directoryDescriptor: directoryDescriptor,
            name: fileName
        )

        let directoryIdentity = FileIdentity(directoryStatus)
        let lockIdentity = FileIdentity(lockStatus)
        let parsedMarkerStoreID = parseStoreID(from: marker)
        let storeID: UUID
        let data: Data
        let shouldRepairMarker: Bool

        if ledgerExists {
            let provisionalLocation = Location(
                directoryURL: directoryURL,
                fileName: fileName,
                lockName: lockName,
                storeID: parsedMarkerStoreID ?? UUID(),
                directoryIdentity: directoryIdentity,
                lockIdentity: lockIdentity
            )
            data = try readLedger(
                directoryDescriptor: directoryDescriptor,
                location: provisionalLocation
            )

            // An empty or torn marker can be the sole remainder of a crash
            // during first-open initialization. Repair it only after the
            // canonical ledger has passed the complete checksum, ordering,
            // version, and entry-state validator while this lock is held.
            let validatedLedgerStoreID = try DurableAgentEngineRunIndex
                .validatedStoreID(in: data)
            if let parsedMarkerStoreID {
                guard parsedMarkerStoreID == validatedLedgerStoreID else {
                    throw DurableAgentEngineRunIndexError.corruptEnvelope
                }
                storeID = parsedMarkerStoreID
                shouldRepairMarker = false
            } else {
                storeID = validatedLedgerStoreID
                shouldRepairMarker = true
            }
        } else {
            // A nonempty marker without its ledger is not distinguishable from
            // untrusted substitution and must never mint a replacement store.
            guard marker.isEmpty else {
                throw DurableAgentEngineRunIndexError.corruptEnvelope
            }
            storeID = UUID()
            let initial = try DiskEnvelope.make(
                formatVersion: formatVersion,
                storeID: storeID,
                generation: 0,
                entries: []
            )
            let initialLocation = Location(
                directoryURL: directoryURL,
                fileName: fileName,
                lockName: lockName,
                storeID: storeID,
                directoryIdentity: directoryIdentity,
                lockIdentity: lockIdentity
            )
            try persist(
                initial,
                directoryDescriptor: directoryDescriptor,
                location: initialLocation,
                faultInjector: nil
            )
            data = try readLedger(
                directoryDescriptor: directoryDescriptor,
                location: initialLocation
            )
            guard try DurableAgentEngineRunIndex.validatedStoreID(in: data)
                    == storeID
            else { throw DurableAgentEngineRunIndexError.corruptEnvelope }
            shouldRepairMarker = true
        }

        if shouldRepairMarker {
            try replaceContents(
                descriptor: lockDescriptor,
                data: lockMarker(storeID: storeID)
            )
            try synchronize(descriptor: directoryDescriptor)
        }

        let location = Location(
            directoryURL: directoryURL,
            fileName: fileName,
            lockName: lockName,
            storeID: storeID,
            directoryIdentity: directoryIdentity,
            lockIdentity: lockIdentity
        )
        if requireCompleteProtection {
            try enforceCompleteProtection(
                directoryURL: directoryURL,
                fileNames: [fileName, lockName]
            )
        }
        return Preparation(location: location, data: data)
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
            throw DurableAgentEngineRunIndexError.invalidFileIdentity
        }
        let lockDescriptor = try openLock(
            directoryDescriptor: directoryDescriptor,
            name: location.lockName
        )
        defer { Darwin.close(lockDescriptor) }
        let lockStatus = try validatedRegularFile(
            descriptor: lockDescriptor,
            directoryDescriptor: directoryDescriptor,
            name: location.lockName
        )
        guard FileIdentity(lockStatus) == location.lockIdentity else {
            throw DurableAgentEngineRunIndexError.invalidFileIdentity
        }
        try acquireFileLock(descriptor: lockDescriptor, until: deadline)
        defer { releaseFileLock(descriptor: lockDescriptor) }

        let lockedStatus = try validatedRegularFile(
            descriptor: lockDescriptor,
            directoryDescriptor: directoryDescriptor,
            name: location.lockName
        )
        guard FileIdentity(lockedStatus) == location.lockIdentity else {
            throw DurableAgentEngineRunIndexError.invalidFileIdentity
        }
        let marker = try readAll(
            descriptor: lockDescriptor,
            expectedSize: Int(lockedStatus.st_size),
            maximumBytes: maximumLockMarkerBytes
        )
        guard marker == lockMarker(storeID: location.storeID) else {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
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
                throw DurableAgentEngineRunIndexError.invalidFileIdentity
            }
            throw DurableAgentEngineRunIndexError.persistenceFailed
        }
        defer { Darwin.close(descriptor) }
        let status = try validatedRegularFile(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            name: location.fileName
        )
        guard status.st_size >= 0,
              status.st_size <= maximumFileBytes
        else { throw DurableAgentEngineRunIndexError.corruptEnvelope }
        return try readAll(
            descriptor: descriptor,
            expectedSize: Int(status.st_size),
            maximumBytes: maximumFileBytes
        )
    }

    static func persist(
        _ envelope: DiskEnvelope,
        directoryDescriptor: Int32,
        location: Location,
        faultInjector: DurableAgentEngineRunIndexFaultInjector?
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        guard data.count <= maximumFileBytes else {
            throw DurableAgentEngineRunIndexError.capacityExceeded
        }

        let temporaryName = ".\(location.fileName).\(UUID().uuidString).tmp"
        let descriptor = openAt(
            directoryDescriptor: directoryDescriptor,
            name: temporaryName,
            flags: O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            mode: S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw DurableAgentEngineRunIndexError.persistenceFailed
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

        let renameResult = temporaryName.withCString { temporary in
            location.fileName.withCString { destination in
                Darwin.renameat(
                    directoryDescriptor,
                    temporary,
                    directoryDescriptor,
                    destination
                )
            }
        }
        guard renameResult == 0 else {
            throw DurableAgentEngineRunIndexError.persistenceFailed
        }
        shouldUnlink = false
        _ = try openValidatedLedger(
            directoryDescriptor: directoryDescriptor,
            name: location.fileName
        )
        try faultInjector?(.afterRenameBeforeDirectorySync)
        try synchronize(descriptor: directoryDescriptor)
    }

    private static func openValidatedLedger(
        directoryDescriptor: Int32,
        name: String
    ) throws -> stat {
        let descriptor = openAt(
            directoryDescriptor: directoryDescriptor,
            name: name,
            flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW,
            mode: 0
        )
        guard descriptor >= 0 else {
            throw DurableAgentEngineRunIndexError.invalidFileIdentity
        }
        defer { Darwin.close(descriptor) }
        return try validatedRegularFile(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            name: name
        )
    }

    private static func deadline(after milliseconds: UInt64) -> DispatchTime {
        .now() + .milliseconds(Int(milliseconds))
    }

    private static func acquireProcessLock(until deadline: DispatchTime) throws {
        guard processSemaphore.wait(timeout: deadline) == .success else {
            throw DurableAgentEngineRunIndexError.lockUnavailable
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
                throw DurableAgentEngineRunIndexError.lockUnavailable
            }
            guard DispatchTime.now() < deadline else {
                throw DurableAgentEngineRunIndexError.lockUnavailable
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
            throw DurableAgentEngineRunIndexError.invalidFileIdentity
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
            throw DurableAgentEngineRunIndexError.lockUnavailable
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

    private static func validatedDirectory(descriptor: Int32) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == Darwin.geteuid(),
              status.st_mode & 0o022 == 0
        else { throw DurableAgentEngineRunIndexError.invalidFileIdentity }
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
        else { throw DurableAgentEngineRunIndexError.invalidFileIdentity }
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
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw DurableAgentEngineRunIndexError.persistenceFailed
        }
        var result = Data()
        result.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, maximumBytes))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw DurableAgentEngineRunIndexError.persistenceFailed
            }
            guard result.count + count <= maximumBytes else {
                throw DurableAgentEngineRunIndexError.corruptEnvelope
            }
            result.append(buffer, count: count)
        }
        guard result.count == expectedSize else {
            throw DurableAgentEngineRunIndexError.corruptEnvelope
        }
        return result
    }

    private static func writeAll(descriptor: Int32, data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw DurableAgentEngineRunIndexError.persistenceFailed
                }
                guard count > 0 else {
                    throw DurableAgentEngineRunIndexError.persistenceFailed
                }
                offset += count
            }
        }
    }

    private static func replaceContents(
        descriptor: Int32,
        data: Data
    ) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
        else { throw DurableAgentEngineRunIndexError.persistenceFailed }
        try writeAll(descriptor: descriptor, data: data)
        try synchronize(descriptor: descriptor)
    }

    private static func synchronize(descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw DurableAgentEngineRunIndexError.persistenceFailed
        }
    }

    private static func lockMarker(storeID: UUID) -> Data {
        let prefix = "novaforge-agent-engine-run-index-v1|"
        return Data(
            "\(prefix)\(storeID.uuidString.lowercased())\n".utf8
        )
    }

    private static func parseStoreID(from marker: Data) -> UUID? {
        let prefix = "novaforge-agent-engine-run-index-v1|"
        guard let value = String(data: marker, encoding: .utf8),
              value.hasPrefix(prefix),
              value.hasSuffix("\n")
        else { return nil }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let raw = String(value[start...].dropLast())
        guard raw == raw.lowercased() else { return nil }
        return UUID(uuidString: raw)
    }

    private static func enforceCompleteProtection(
        directoryURL: URL,
        fileNames: [String]
    ) throws {
        let manager = FileManager.default
        for name in fileNames {
            let url = directoryURL.appendingPathComponent(name)
            do {
                try manager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
                var mutable = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try mutable.setResourceValues(values)
                let attributes = try manager.attributesOfItem(atPath: url.path)
                let excluded = try url.resourceValues(
                    forKeys: [.isExcludedFromBackupKey]
                ).isExcludedFromBackup == true
                guard AgentCompleteDataProtection.satisfiesPostcondition(
                    attributes[.protectionKey]
                ), excluded else {
                    throw DurableAgentEngineRunIndexError.persistenceFailed
                }
            } catch let error as DurableAgentEngineRunIndexError {
                throw error
            } catch {
                throw DurableAgentEngineRunIndexError.persistenceFailed
            }
        }
    }
}
