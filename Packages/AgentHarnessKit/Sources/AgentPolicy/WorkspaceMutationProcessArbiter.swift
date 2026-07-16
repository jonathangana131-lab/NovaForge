import AgentDomain
import Darwin
import Dispatch
import Foundation

enum WorkspaceMutationProcessArbiterError: Error, Equatable, Sendable {
    case invalidDirectoryIdentity
    case invalidLockIdentity
    case lockUnavailable
    case persistenceFailed
}

/// An OS-backed lease for one workspace mutation lane. It is intentionally
/// package-internal; callers receive only the higher-level gateway result.
final class WorkspaceMutationProcessLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        stateLock.lock()
        let descriptor = self.descriptor
        self.descriptor = nil
        stateLock.unlock()
        guard let descriptor else { return }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_UNLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
        Darwin.close(descriptor)
    }

    deinit { release() }
}

/// Cross-process workspace serialization held across the complete effect
/// boundary. The lifecycle ledger's short transaction lock is deliberately
/// separate so journal reads/writes cannot deadlock this lease.
final class WorkspaceMutationProcessArbiter: @unchecked Sendable {
    fileprivate struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private static let identityRegistry = WorkspaceLockIdentityRegistry()

    let directoryURL: URL
    let timeoutMilliseconds: UInt64
    private let directoryIdentity: FileIdentity

    init(
        directoryURL: URL,
        timeoutMilliseconds: UInt64 = 5_000
    ) throws {
        guard (1...60_000).contains(timeoutMilliseconds) else {
            throw WorkspaceMutationProcessArbiterError.lockUnavailable
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw WorkspaceMutationProcessArbiterError.persistenceFailed
        }
        let canonical = directoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let descriptor = Darwin.open(
            canonical.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw WorkspaceMutationProcessArbiterError
                .invalidDirectoryIdentity
        }
        defer { Darwin.close(descriptor) }
        let status = try Self.validatedDirectory(descriptor)
        self.directoryURL = canonical
        self.timeoutMilliseconds = timeoutMilliseconds
        directoryIdentity = FileIdentity(status)
    }

    func acquire(
        workspaceID: WorkspaceID
    ) async throws -> WorkspaceMutationProcessLease {
        try Task.checkCancellation()
        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw WorkspaceMutationProcessArbiterError
                .invalidDirectoryIdentity
        }
        defer { Darwin.close(directoryDescriptor) }
        let directoryStatus = try Self.validatedDirectory(
            directoryDescriptor
        )
        guard FileIdentity(directoryStatus) == directoryIdentity else {
            throw WorkspaceMutationProcessArbiterError
                .invalidDirectoryIdentity
        }

        let lockName = "workspace-\(workspaceID.description).lock"
        let descriptor = lockName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw WorkspaceMutationProcessArbiterError.invalidLockIdentity
        }
        var keepDescriptor = false
        defer {
            if !keepDescriptor { Darwin.close(descriptor) }
        }
        let openedStatus = try Self.validatedLock(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            name: lockName
        )
        let registryKey = directoryURL.path + "/" + lockName
        if let pinned = Self.identityRegistry.identity(for: registryKey),
           pinned != FileIdentity(openedStatus) {
            throw WorkspaceMutationProcessArbiterError.invalidLockIdentity
        }

        let deadline = DispatchTime.now()
            + .milliseconds(Int(timeoutMilliseconds))
        while true {
            try Task.checkCancellation()
            var lock = Darwin.flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            lock.l_start = 0
            lock.l_len = 0
            if Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 { break }
            let code = errno
            guard code == EACCES || code == EAGAIN,
                  DispatchTime.now() < deadline
            else {
                throw WorkspaceMutationProcessArbiterError.lockUnavailable
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        do {
            let lockedStatus = try Self.validatedLock(
                descriptor: descriptor,
                directoryDescriptor: directoryDescriptor,
                name: lockName
            )
            let identity = FileIdentity(lockedStatus)
            guard identity == FileIdentity(openedStatus),
                  Self.identityRegistry.pin(
                      identity,
                      for: registryKey
                  )
            else {
                throw WorkspaceMutationProcessArbiterError
                    .invalidLockIdentity
            }
            let expectedMarker = Data(
                "NovaForgeWorkspaceMutationLock-v1:\(workspaceID.description)\n"
                    .utf8
            )
            let marker = try Self.read(
                descriptor: descriptor,
                expectedSize: Int(lockedStatus.st_size),
                maximumBytes: 256
            )
            if marker.isEmpty {
                try Self.replaceContents(
                    descriptor: descriptor,
                    data: expectedMarker
                )
                try Self.synchronize(directoryDescriptor)
            } else if marker != expectedMarker {
                throw WorkspaceMutationProcessArbiterError
                    .invalidLockIdentity
            }
            try Task.checkCancellation()
            keepDescriptor = true
            return WorkspaceMutationProcessLease(descriptor: descriptor)
        } catch {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            unlock.l_start = 0
            unlock.l_len = 0
            _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
            throw error
        }
    }

    func lockURL(workspaceID: WorkspaceID) -> URL {
        directoryURL.appendingPathComponent(
            "workspace-\(workspaceID.description).lock"
        )
    }

    private static func validatedDirectory(
        _ descriptor: Int32
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == Darwin.geteuid(),
              status.st_mode & 0o022 == 0
        else {
            throw WorkspaceMutationProcessArbiterError
                .invalidDirectoryIdentity
        }
        return status
    }

    private static func validatedLock(
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
              descriptorStatus.st_ino == pathStatus.st_ino,
              descriptorStatus.st_size >= 0,
              descriptorStatus.st_size <= 256
        else {
            throw WorkspaceMutationProcessArbiterError.invalidLockIdentity
        }
        return descriptorStatus
    }

    private static func read(
        descriptor: Int32,
        expectedSize: Int,
        maximumBytes: Int
    ) throws -> Data {
        guard expectedSize >= 0, expectedSize <= maximumBytes,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
        else {
            throw WorkspaceMutationProcessArbiterError.invalidLockIdentity
        }
        var bytes = [UInt8](repeating: 0, count: max(1, maximumBytes))
        var result = Data()
        while true {
            let count = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkspaceMutationProcessArbiterError.persistenceFailed
            }
            guard result.count + count <= maximumBytes else {
                throw WorkspaceMutationProcessArbiterError.invalidLockIdentity
            }
            result.append(bytes, count: count)
        }
        guard result.count == expectedSize else {
            throw WorkspaceMutationProcessArbiterError.invalidLockIdentity
        }
        return result
    }

    private static func replaceContents(
        descriptor: Int32,
        data: Data
    ) throws {
        guard Darwin.ftruncate(descriptor, 0) == 0,
              Darwin.lseek(descriptor, 0, SEEK_SET) >= 0
        else {
            throw WorkspaceMutationProcessArbiterError.persistenceFailed
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw WorkspaceMutationProcessArbiterError
                        .persistenceFailed
                }
                guard count > 0 else {
                    throw WorkspaceMutationProcessArbiterError
                        .persistenceFailed
                }
                offset += count
            }
        }
        try synchronize(descriptor)
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw WorkspaceMutationProcessArbiterError.persistenceFailed
        }
    }
}

private final class WorkspaceLockIdentityRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [String: WorkspaceMutationProcessArbiter.FileIdentity]
        = [:]

    func identity(
        for key: String
    ) -> WorkspaceMutationProcessArbiter.FileIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identities[key]
    }

    func pin(
        _ identity: WorkspaceMutationProcessArbiter.FileIdentity,
        for key: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = identities[key] { return existing == identity }
        identities[key] = identity
        return true
    }
}
