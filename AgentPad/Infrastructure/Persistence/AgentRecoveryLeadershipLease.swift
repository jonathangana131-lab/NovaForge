import Darwin
import Dispatch
import Foundation

enum AgentRecoveryLeadershipLeaseError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidFileURL
    case invalidDirectory
    case invalidEntryType
    case symbolicLinkRejected
    case hardLinkRejected
    case invalidOwner
    case insecurePermissions
    case pathIdentityMismatch
    case duplicateAcquisition
    case lockTimedOut
    case cancelled
    case protectionUnavailable
    case fileSystemFailure
}

enum AgentRecoveryLeadershipLeaseFaultPoint: Sendable {
    case afterLockBeforeRevalidation
}

typealias AgentRecoveryLeadershipLeaseFaultInjector = @Sendable (
    AgentRecoveryLeadershipLeaseFaultPoint,
    URL
) throws -> Void

/// Production process-lifetime election rooted beside the durable run index.
/// The returned reference owns the fcntl lock until its final strong reference
/// is released (normally when the process-owned `AgentSystem` is torn down).
struct ProductionAgentRecoveryLeadershipLeaseAcquirer:
    AgentRecoveryLeadershipLeaseAcquiring,
    Sendable
{
    static let lockFileName = "recovery-leadership.lock"

    private let lockTimeoutMilliseconds: UInt64

    init(lockTimeoutMilliseconds: UInt64 = 250) throws {
        guard AgentRecoveryLeadershipFileLeaseAcquirer.isValidTimeout(
            lockTimeoutMilliseconds
        ) else {
            throw AgentRecoveryLeadershipLeaseError.invalidConfiguration
        }
        self.lockTimeoutMilliseconds = lockTimeoutMilliseconds
    }

    func acquireProcessLifetimeLease() async throws
        -> any AgentRecoveryLeadershipLease
    {
        let paths = try AgentEngineRunIndexStorePaths.prepare()
        try Self.tightenVersionDirectoryPermissions(
            at: paths.versionDirectory
        )
        let fileURL = paths.versionDirectory.appendingPathComponent(
            Self.lockFileName,
            isDirectory: false
        )
        let acquirer = try AgentRecoveryLeadershipFileLeaseAcquirer(
            fileURL: fileURL,
            lockTimeoutMilliseconds: lockTimeoutMilliseconds,
            requireCompleteProtection: true
        )
        return try await acquirer.acquireProcessLifetimeLease()
    }

    /// `AgentEngineRunIndexStorePaths` establishes the trusted protected path,
    /// while the leadership directory additionally requires owner-only POSIX
    /// access. Tightening is descriptor-based and identity-pinned so production
    /// does not depend on the platform's usual 0755 mkdir default.
    private static func tightenVersionDirectoryPermissions(
        at url: URL
    ) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AgentRecoveryLeadershipLeaseError.invalidDirectory
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        var pathBefore = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Darwin.lstat(url.path, &pathBefore) == 0,
              before.st_mode & S_IFMT == S_IFDIR,
              pathBefore.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == Darwin.geteuid(),
              pathBefore.st_uid == Darwin.geteuid(),
              AgentRecoveryLeadershipFileIdentity(before)
                == AgentRecoveryLeadershipFileIdentity(pathBefore),
              Darwin.fchmod(descriptor, 0o700) == 0
        else { throw AgentRecoveryLeadershipLeaseError.invalidDirectory }

        var after = stat()
        var pathAfter = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Darwin.lstat(url.path, &pathAfter) == 0,
              AgentRecoveryLeadershipFileIdentity(after)
                == AgentRecoveryLeadershipFileIdentity(before),
              AgentRecoveryLeadershipFileIdentity(pathAfter)
                == AgentRecoveryLeadershipFileIdentity(before),
              after.st_mode & 0o777 == 0o700,
              pathAfter.st_mode & 0o777 == 0o700
        else { throw AgentRecoveryLeadershipLeaseError.invalidDirectory }
    }
}

/// File-based implementation kept internal so hostile filesystem tests can use
/// isolated temporary directories without weakening production protection.
struct AgentRecoveryLeadershipFileLeaseAcquirer:
    AgentRecoveryLeadershipLeaseAcquiring,
    Sendable
{
    private static let maximumLockTimeoutMilliseconds: UInt64 = 60_000
    private static let retryNanoseconds: UInt64 = 2_000_000

    private let fileURL: URL
    private let lockTimeoutMilliseconds: UInt64
    private let requireCompleteProtection: Bool
    private let faultInjector: AgentRecoveryLeadershipLeaseFaultInjector?

    init(
        fileURL requestedURL: URL,
        lockTimeoutMilliseconds: UInt64 = 250,
        requireCompleteProtection: Bool = false,
        faultInjector: AgentRecoveryLeadershipLeaseFaultInjector? = nil
    ) throws {
        guard Self.isValidTimeout(lockTimeoutMilliseconds) else {
            throw AgentRecoveryLeadershipLeaseError.invalidConfiguration
        }
        guard requestedURL.isFileURL,
              requestedURL.path.hasPrefix("/"),
              !requestedURL.lastPathComponent.isEmpty,
              requestedURL.lastPathComponent != ".",
              requestedURL.lastPathComponent != ".."
        else { throw AgentRecoveryLeadershipLeaseError.invalidFileURL }
        let standardized = requestedURL.standardizedFileURL
        let fileName = standardized.lastPathComponent
        guard !fileName.contains("/"),
              !fileName.contains("\0"),
              standardized.deletingLastPathComponent().path != "/"
        else { throw AgentRecoveryLeadershipLeaseError.invalidFileURL }

        fileURL = standardized
        self.lockTimeoutMilliseconds = lockTimeoutMilliseconds
        self.requireCompleteProtection = requireCompleteProtection
        self.faultInjector = faultInjector
    }

    static func isValidTimeout(_ milliseconds: UInt64) -> Bool {
        (1 ... maximumLockTimeoutMilliseconds).contains(milliseconds)
    }

    func acquireProcessLifetimeLease() async throws
        -> any AgentRecoveryLeadershipLease
    {
        guard !Task.isCancelled else {
            throw AgentRecoveryLeadershipLeaseError.cancelled
        }

        let canonicalPath = fileURL.path
        let registry = AgentRecoveryLeadershipProcessRegistry.shared
        guard registry.reserve(path: canonicalPath) else {
            throw AgentRecoveryLeadershipLeaseError.duplicateAcquisition
        }
        var reservationOwnedByCaller = true
        defer {
            if reservationOwnedByCaller {
                registry.releaseReservation(path: canonicalPath)
            }
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try Self.rejectSymbolicLink(at: directoryURL, missingAllowed: false)
        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            if errno == ELOOP {
                throw AgentRecoveryLeadershipLeaseError.symbolicLinkRejected
            }
            throw AgentRecoveryLeadershipLeaseError.invalidDirectory
        }
        defer { Darwin.close(directoryDescriptor) }
        try Self.validateDirectory(
            descriptor: directoryDescriptor,
            url: directoryURL,
            requireCompleteProtection: requireCompleteProtection
        )
        try Self.rejectSymbolicLink(at: fileURL, missingAllowed: true)

        let descriptor = fileURL.lastPathComponent.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw AgentRecoveryLeadershipLeaseError.symbolicLinkRejected
            }
            throw AgentRecoveryLeadershipLeaseError.fileSystemFailure
        }
        var descriptorOwnedByCaller = true
        defer {
            if descriptorOwnedByCaller {
                Darwin.close(descriptor)
            }
        }

        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw AgentRecoveryLeadershipLeaseError.fileSystemFailure
        }
        let identity = AgentRecoveryLeadershipFileIdentity(descriptorStatus)

        switch registry.register(
            path: canonicalPath,
            identity: identity,
            descriptor: descriptor
        ) {
        case .registered:
            descriptorOwnedByCaller = false
            reservationOwnedByCaller = false
        case .duplicateQuarantined:
            // Closing any descriptor for this inode could release the first
            // lease's process-wide POSIX record lock. The registry retains this
            // duplicate until the original lease is relinquished.
            descriptorOwnedByCaller = false
            reservationOwnedByCaller = false
            throw AgentRecoveryLeadershipLeaseError.duplicateAcquisition
        }

        var registeredLeaseTransferred = false
        var lockAcquired = false
        defer {
            if !registeredLeaseTransferred {
                registry.releaseRegisteredDescriptor(
                    path: canonicalPath,
                    identity: identity,
                    descriptor: descriptor,
                    unlock: lockAcquired
                )
            }
        }

        try Self.validateFile(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            fileName: fileURL.lastPathComponent,
            expectedIdentity: identity
        )
        if requireCompleteProtection {
            try Self.enforceAndValidateProtection(at: fileURL)
            try Self.validateFile(
                descriptor: descriptor,
                directoryDescriptor: directoryDescriptor,
                fileName: fileURL.lastPathComponent,
                expectedIdentity: identity
            )
        }

        try await acquireFileLock(
            descriptor: descriptor,
            timeoutMilliseconds: lockTimeoutMilliseconds
        )
        lockAcquired = true

        do {
            try faultInjector?(.afterLockBeforeRevalidation, fileURL)
        } catch {
            throw error
        }
        guard !Task.isCancelled else {
            throw AgentRecoveryLeadershipLeaseError.cancelled
        }
        try Self.validateDirectory(
            descriptor: directoryDescriptor,
            url: directoryURL,
            requireCompleteProtection: requireCompleteProtection
        )
        if requireCompleteProtection {
            try Self.validateProtection(at: fileURL)
        }
        try Self.validateFile(
            descriptor: descriptor,
            directoryDescriptor: directoryDescriptor,
            fileName: fileURL.lastPathComponent,
            expectedIdentity: identity
        )

        let lease = AgentRecoveryLeadershipFileLease(
            path: canonicalPath,
            identity: identity,
            descriptor: descriptor,
            registry: registry
        )
        registeredLeaseTransferred = true
        return lease
    }

    private func acquireFileLock(
        descriptor: Int32,
        timeoutMilliseconds: UInt64
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = timeoutMilliseconds * 1_000_000
        guard start <= UInt64.max - timeoutNanoseconds else {
            throw AgentRecoveryLeadershipLeaseError.invalidConfiguration
        }
        let deadline = start + timeoutNanoseconds

        while true {
            guard !Task.isCancelled else {
                throw AgentRecoveryLeadershipLeaseError.cancelled
            }
            var lock = Darwin.flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            lock.l_start = 0
            lock.l_len = 0
            if Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 { return }

            let code = errno
            guard code == EACCES || code == EAGAIN else {
                throw AgentRecoveryLeadershipLeaseError.fileSystemFailure
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw AgentRecoveryLeadershipLeaseError.lockTimedOut
            }
            let sleepNanoseconds = min(Self.retryNanoseconds, deadline - now)
            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch is CancellationError {
                throw AgentRecoveryLeadershipLeaseError.cancelled
            } catch {
                throw AgentRecoveryLeadershipLeaseError.fileSystemFailure
            }
        }
    }

    private static func validateDirectory(
        descriptor: Int32,
        url: URL,
        requireCompleteProtection: Bool
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              Darwin.lstat(url.path, &pathStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              descriptorStatus.st_uid == Darwin.geteuid(),
              pathStatus.st_uid == Darwin.geteuid(),
              descriptorStatus.st_mode & 0o777 == 0o700,
              pathStatus.st_mode & 0o777 == 0o700,
              AgentRecoveryLeadershipFileIdentity(descriptorStatus)
                == AgentRecoveryLeadershipFileIdentity(pathStatus)
        else { throw AgentRecoveryLeadershipLeaseError.invalidDirectory }

        guard requireCompleteProtection else { return }
        try validateProtection(at: url)
    }

    private static func rejectSymbolicLink(
        at url: URL,
        missingAllowed: Bool
    ) throws {
        var status = stat()
        if Darwin.lstat(url.path, &status) == 0 {
            guard status.st_mode & S_IFMT != S_IFLNK else {
                throw AgentRecoveryLeadershipLeaseError.symbolicLinkRejected
            }
            return
        }
        if missingAllowed, errno == ENOENT { return }
        throw AgentRecoveryLeadershipLeaseError.fileSystemFailure
    }

    private static func validateFile(
        descriptor: Int32,
        directoryDescriptor: Int32,
        fileName: String,
        expectedIdentity: AgentRecoveryLeadershipFileIdentity
    ) throws {
        var descriptorStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw AgentRecoveryLeadershipLeaseError.fileSystemFailure
        }
        let pathResult = fileName.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard pathResult == 0 else {
            throw AgentRecoveryLeadershipLeaseError.pathIdentityMismatch
        }
        if descriptorStatus.st_mode & S_IFMT != S_IFREG
            || pathStatus.st_mode & S_IFMT != S_IFREG
        {
            if pathStatus.st_mode & S_IFMT == S_IFLNK {
                throw AgentRecoveryLeadershipLeaseError.symbolicLinkRejected
            }
            throw AgentRecoveryLeadershipLeaseError.invalidEntryType
        }
        guard descriptorStatus.st_nlink == 1,
              pathStatus.st_nlink == 1
        else { throw AgentRecoveryLeadershipLeaseError.hardLinkRejected }
        guard descriptorStatus.st_uid == Darwin.geteuid(),
              pathStatus.st_uid == Darwin.geteuid()
        else { throw AgentRecoveryLeadershipLeaseError.invalidOwner }
        guard descriptorStatus.st_mode & 0o7777 == 0o600,
              pathStatus.st_mode & 0o7777 == 0o600
        else { throw AgentRecoveryLeadershipLeaseError.insecurePermissions }
        guard AgentRecoveryLeadershipFileIdentity(descriptorStatus)
                == expectedIdentity,
              AgentRecoveryLeadershipFileIdentity(pathStatus)
                == expectedIdentity
        else { throw AgentRecoveryLeadershipLeaseError.pathIdentityMismatch }
    }

    private static func enforceAndValidateProtection(at url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
        } catch {
            throw AgentRecoveryLeadershipLeaseError.protectionUnavailable
        }
        try validateProtection(at: url)
    }

    private static func validateProtection(at url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            let excluded = try url.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup == true
            guard AgentCompleteDataProtection.satisfiesPostcondition(
                attributes[.protectionKey]
            ), excluded else {
                throw AgentRecoveryLeadershipLeaseError.protectionUnavailable
            }
        } catch let error as AgentRecoveryLeadershipLeaseError {
            throw error
        } catch {
            throw AgentRecoveryLeadershipLeaseError.protectionUnavailable
        }
    }
}

private struct AgentRecoveryLeadershipFileIdentity:
    Equatable,
    Hashable,
    Sendable
{
    let device: UInt64
    let inode: UInt64

    init(_ status: stat) {
        device = UInt64(truncatingIfNeeded: status.st_dev)
        inode = UInt64(truncatingIfNeeded: status.st_ino)
    }
}

private final class AgentRecoveryLeadershipFileLease:
    AgentRecoveryLeadershipLease,
    @unchecked Sendable
{
    private let path: String
    private let identity: AgentRecoveryLeadershipFileIdentity
    private let descriptor: Int32
    private let registry: AgentRecoveryLeadershipProcessRegistry

    init(
        path: String,
        identity: AgentRecoveryLeadershipFileIdentity,
        descriptor: Int32,
        registry: AgentRecoveryLeadershipProcessRegistry
    ) {
        self.path = path
        self.identity = identity
        self.descriptor = descriptor
        self.registry = registry
    }

    deinit {
        registry.releaseRegisteredDescriptor(
            path: path,
            identity: identity,
            descriptor: descriptor,
            unlock: true
        )
    }
}

private final class AgentRecoveryLeadershipProcessRegistry:
    @unchecked Sendable
{
    enum RegistrationResult {
        case registered
        case duplicateQuarantined
    }

    private struct ActiveIdentity {
        let primaryPath: String
        var aliasPaths: Set<String>
        var quarantinedDescriptors: [Int32]
    }

    static let shared = AgentRecoveryLeadershipProcessRegistry()

    private let lock = NSLock()
    private var reservedPaths: Set<String> = []
    private var activeByIdentity: [
        AgentRecoveryLeadershipFileIdentity: ActiveIdentity
    ] = [:]

    func reserve(path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return reservedPaths.insert(path).inserted
    }

    func releaseReservation(path: String) {
        lock.lock()
        reservedPaths.remove(path)
        lock.unlock()
    }

    func register(
        path: String,
        identity: AgentRecoveryLeadershipFileIdentity,
        descriptor: Int32
    ) -> RegistrationResult {
        lock.lock()
        defer { lock.unlock() }
        if var active = activeByIdentity[identity] {
            active.aliasPaths.insert(path)
            active.quarantinedDescriptors.append(descriptor)
            activeByIdentity[identity] = active
            return .duplicateQuarantined
        }
        activeByIdentity[identity] = ActiveIdentity(
            primaryPath: path,
            aliasPaths: [],
            quarantinedDescriptors: []
        )
        return .registered
    }

    /// Releases and closes every descriptor for one identity while the
    /// registry mutex still blocks a replacement acquisition. This ordering is
    /// required because closing a quarantined descriptor after a new same-
    /// process lock was acquired could release that new POSIX record lock.
    func releaseRegisteredDescriptor(
        path: String,
        identity: AgentRecoveryLeadershipFileIdentity,
        descriptor: Int32,
        unlock: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }

        if unlock {
            var fileLock = Darwin.flock()
            fileLock.l_type = Int16(F_UNLCK)
            fileLock.l_whence = Int16(SEEK_SET)
            fileLock.l_start = 0
            fileLock.l_len = 0
            while Darwin.fcntl(descriptor, F_SETLK, &fileLock) != 0 {
                if errno == EINTR { continue }
                break
            }
        }
        Darwin.close(descriptor)

        guard let active = activeByIdentity.removeValue(forKey: identity) else {
            reservedPaths.remove(path)
            return
        }
        for quarantined in active.quarantinedDescriptors {
            Darwin.close(quarantined)
        }
        reservedPaths.remove(active.primaryPath)
        for alias in active.aliasPaths {
            reservedPaths.remove(alias)
        }
    }
}
