import CryptoKit
import CoreData
import Darwin
import OSLog
import SwiftData
import SwiftUI
import UIKit

struct LaunchPersistenceStorePaths: Equatable {
    let supportURL: URL
    let primaryStoreURL: URL

    init(supportURL: URL, primaryStoreURL: URL? = nil) {
        self.supportURL = supportURL
        self.primaryStoreURL = primaryStoreURL ?? supportURL
            .appendingPathComponent("NovaForge.store")
    }

    var compatibilityStoreURL: URL {
        supportURL
            .appendingPathComponent("CompatibilityRecovery", isDirectory: true)
            .appendingPathComponent("NovaForge-Compatibility.store")
    }

    var compatibilityActiveGuardURL: URL {
        compatibilityStoreURL.deletingLastPathComponent()
            .appendingPathComponent("active-fallback.commit")
    }

    var recoveryDirectoryURL: URL {
        supportURL.appendingPathComponent("RecoveredStores", isDirectory: true)
    }

    func recoveryAttemptDirectoryURL(recoveryID: UUID) -> URL {
        recoveryDirectoryURL.appendingPathComponent(
            recoveryID.uuidString.lowercased(),
            isDirectory: true
        )
    }
}

#if DEBUG || targetEnvironment(simulator)
enum LaunchDebugPersistenceResetError: Error, Equatable {
    case supportDirectoryUnavailable
    case invalidSupportDirectory
    case symbolicLinkRejected
    case invalidEntryType
    case activeRecoveryLease
    case fileSystemFailure
    case defaultsClearFailed
}

/// Clears only the debug/UI-test persistence authority that must move as one
/// unit. The durable run index and policy ledgers are removed before SwiftData
/// so a crash can never leave an empty model store governed by stale terminal
/// or mutation authority. User workspaces, recovery snapshots, compatibility
/// stores, Keychain material, and unrelated defaults remain untouched.
struct LaunchDebugPersistenceReset {
    struct Dependencies {
        var removeItem: (URL) throws -> Void
        var synchronizeDirectory: (URL) throws -> Void

        static func live(fileManager: FileManager) -> Self {
            Self(
                removeItem: { try fileManager.removeItem(at: $0) },
                synchronizeDirectory: { try LaunchDebugPersistenceReset
                    .liveSynchronizeDirectory($0) }
            )
        }
    }

    private enum ItemKind: Equatable {
        case missing
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    private final class RecoveryLeaseGuard {
        private let descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        deinit {
            var lock = Darwin.flock()
            lock.l_type = Int16(F_UNLCK)
            lock.l_whence = Int16(SEEK_SET)
            lock.l_start = 0
            lock.l_len = 0
            _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
            Darwin.close(descriptor)
        }
    }

    static func reset(
        at requestedSupportURL: URL?,
        fileManager: FileManager = .default,
        migrationStore: UserDefaults = .standard,
        dependencies requestedDependencies: Dependencies? = nil
    ) throws {
        guard let requestedSupportURL else {
            throw LaunchDebugPersistenceResetError.supportDirectoryUnavailable
        }
        guard requestedSupportURL.isFileURL,
              requestedSupportURL.path.hasPrefix("/")
        else {
            throw LaunchDebugPersistenceResetError.invalidSupportDirectory
        }

        let supportURL = requestedSupportURL.standardizedFileURL
        guard supportURL.path != "/",
              try itemKind(at: supportURL) == .directory
        else {
            throw LaunchDebugPersistenceResetError.invalidSupportDirectory
        }

        let paths = LaunchPersistenceStorePaths(supportURL: supportURL)
        let dependencies = requestedDependencies ?? .live(
            fileManager: fileManager
        )
        let engineURL = try strictChild(named: "AgentEngine", of: supportURL)
        let policyURL = try strictChild(named: "AgentPolicy", of: supportURL)
        let compatibilityDirectoryURL = paths.compatibilityStoreURL
            .deletingLastPathComponent()

        let engineKind = try validatedOptionalKind(
            at: engineURL,
            allowed: .directory
        )
        let policyKind = try validatedOptionalKind(
            at: policyURL,
            allowed: .directory
        )
        let compatibilityDirectoryKind = try validatedOptionalKind(
            at: compatibilityDirectoryURL,
            allowed: .directory
        )
        let storeURLs = ["", "-shm", "-wal"].map {
            URL(fileURLWithPath: paths.primaryStoreURL.path + $0)
        }
        let storeKinds = try storeURLs.map {
            try validatedOptionalKind(at: $0, allowed: .regularFile)
        }
        let compatibilityGuardKind = try validatedOptionalKind(
            at: paths.compatibilityActiveGuardURL,
            allowed: .regularFile
        )

        let leaseGuard = try acquireExistingRecoveryLeaseGuard(
            engineURL: engineURL
        )
        try withExtendedLifetime(leaseGuard) {
            // Establish and durably flush authority-first ordering before any
            // SwiftData file is unlinked.
            try removeItem(
                at: engineURL,
                expected: engineKind,
                dependencies: dependencies
            )
            try removeItem(
                at: policyURL,
                expected: policyKind,
                dependencies: dependencies
            )
            try dependencies.synchronizeDirectory(supportURL)

            for (url, kind) in zip(storeURLs, storeKinds) {
                try removeItem(
                    at: url,
                    expected: kind,
                    dependencies: dependencies
                )
            }
            try dependencies.synchronizeDirectory(supportURL)

            try removeItem(
                at: paths.compatibilityActiveGuardURL,
                expected: compatibilityGuardKind,
                dependencies: dependencies
            )
            if compatibilityDirectoryKind == .directory {
                try dependencies.synchronizeDirectory(
                    compatibilityDirectoryURL
                )
            }
        }

        migrationStore.removeObject(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        )
        guard migrationStore.object(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ) == nil else {
            throw LaunchDebugPersistenceResetError.defaultsClearFailed
        }
    }

    private static func strictChild(
        named name: String,
        of parent: URL
    ) throws -> URL {
        let child = parent.appendingPathComponent(
            name,
            isDirectory: true
        ).standardizedFileURL
        let parentComponents = parent.pathComponents
        let childComponents = child.pathComponents
        guard childComponents.count == parentComponents.count + 1,
              childComponents.prefix(parentComponents.count)
                .elementsEqual(parentComponents)
        else {
            throw LaunchDebugPersistenceResetError.invalidSupportDirectory
        }
        return child
    }

    private static func validatedOptionalKind(
        at url: URL,
        allowed: ItemKind
    ) throws -> ItemKind {
        let observed = try itemKind(at: url)
        switch observed {
        case .missing:
            return observed
        case allowed:
            return observed
        case .symbolicLink:
            throw LaunchDebugPersistenceResetError.symbolicLinkRejected
        case .directory, .regularFile, .other:
            throw LaunchDebugPersistenceResetError.invalidEntryType
        }
    }

    private static func itemKind(at url: URL) throws -> ItemKind {
        var status = stat()
        if Darwin.lstat(url.path, &status) == 0 {
            switch status.st_mode & S_IFMT {
            case S_IFDIR: return .directory
            case S_IFREG: return .regularFile
            case S_IFLNK: return .symbolicLink
            default: return .other
            }
        }
        if errno == ENOENT { return .missing }
        throw LaunchDebugPersistenceResetError.fileSystemFailure
    }

    private static func acquireExistingRecoveryLeaseGuard(
        engineURL: URL
    ) throws -> RecoveryLeaseGuard? {
        let lockURL = engineURL
            .appendingPathComponent(
                AgentEngineRunIndexStorePaths.schemaVersion,
                isDirectory: true
            )
            .appendingPathComponent(
                ProductionAgentRecoveryLeadershipLeaseAcquirer.lockFileName,
                isDirectory: false
            )
        switch try itemKind(at: lockURL) {
        case .missing:
            return nil
        case .symbolicLink:
            throw LaunchDebugPersistenceResetError.symbolicLinkRejected
        case .directory, .other:
            throw LaunchDebugPersistenceResetError.invalidEntryType
        case .regularFile:
            break
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw LaunchDebugPersistenceResetError.symbolicLinkRejected
            }
            throw LaunchDebugPersistenceResetError.fileSystemFailure
        }
        var descriptorOwnedByCaller = true
        defer {
            if descriptorOwnedByCaller {
                Darwin.close(descriptor)
            }
        }

        var descriptorStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0,
              Darwin.lstat(lockURL.path, &pathStatus) == 0,
              descriptorStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_mode & S_IFMT == S_IFREG,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino,
              descriptorStatus.st_nlink == 1,
              pathStatus.st_nlink == 1,
              descriptorStatus.st_uid == Darwin.geteuid(),
              pathStatus.st_uid == Darwin.geteuid()
        else {
            throw LaunchDebugPersistenceResetError.invalidEntryType
        }

        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        guard Darwin.fcntl(descriptor, F_SETLK, &lock) == 0 else {
            if errno == EACCES || errno == EAGAIN {
                throw LaunchDebugPersistenceResetError.activeRecoveryLease
            }
            throw LaunchDebugPersistenceResetError.fileSystemFailure
        }

        descriptorOwnedByCaller = false
        return RecoveryLeaseGuard(descriptor: descriptor)
    }

    private static func removeItem(
        at url: URL,
        expected: ItemKind,
        dependencies: Dependencies
    ) throws {
        let observed = try itemKind(at: url)
        guard observed == expected else {
            if observed == .symbolicLink {
                throw LaunchDebugPersistenceResetError.symbolicLinkRejected
            }
            throw LaunchDebugPersistenceResetError.fileSystemFailure
        }
        guard observed != .missing else { return }
        do {
            try dependencies.removeItem(url)
        } catch {
            throw LaunchDebugPersistenceResetError.fileSystemFailure
        }
        guard try itemKind(at: url) == .missing else {
            throw LaunchDebugPersistenceResetError.fileSystemFailure
        }
    }

    private static func liveSynchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw LaunchDebugPersistenceResetError.symbolicLinkRejected
            }
            throw LaunchDebugPersistenceResetError.fileSystemFailure
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw LaunchDebugPersistenceResetError.fileSystemFailure
        }
    }
}
#endif

struct LaunchPersistenceFileFingerprint: Codable, Equatable {
    let byteCount: UInt64
    let sha256: String
}

struct LaunchPersistenceFileOperations {
    var fileExists: (URL) -> Bool
    var createDirectory: (URL) throws -> Void
    var createDirectoryExclusively: (URL) throws -> Void
    var copyItem: (URL, URL) throws -> Void
    var fingerprint: (URL) throws -> LaunchPersistenceFileFingerprint
    var removeItem: (URL) throws -> Void
    var writeDataDurably: (Data, URL) throws -> Void
    var readData: (URL) throws -> Data
    var synchronizeFile: (URL) throws -> Void
    var synchronizeDirectory: (URL) throws -> Void

    private struct POSIXOperationError: Error {
        let code: Int32
    }

    static var live: Self {
        let fileManager = FileManager.default
        return Self(
            fileExists: { fileManager.fileExists(atPath: $0.path) },
            createDirectory: {
                try fileManager.createDirectory(
                    at: $0,
                    withIntermediateDirectories: true
                )
            },
            createDirectoryExclusively: { url in
                try liveCreateDirectoryExclusively(at: url)
            },
            copyItem: { try fileManager.copyItem(at: $0, to: $1) },
            fingerprint: { try liveFingerprint(at: $0) },
            removeItem: { try fileManager.removeItem(at: $0) },
            writeDataDurably: { data, url in
                try liveWriteDataExclusively(data, to: url)
            },
            readData: {
                try Data(contentsOf: $0, options: [.uncached])
            },
            synchronizeFile: { url in
                try liveSynchronize(at: url, openFlags: O_RDWR)
            },
            synchronizeDirectory: { url in
                try liveSynchronize(at: url, openFlags: O_RDONLY)
            }
        )
    }

    private static func liveWriteDataExclusively(
        _ data: Data,
        to url: URL
    ) throws {
        let descriptor = try openExclusiveFileDescriptor(at: url)

        var descriptorIsOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var writtenByteCount = 0
                while writtenByteCount < bytes.count {
                    let result = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: writtenByteCount),
                        bytes.count - writtenByteCount
                    )
                    if result > 0 {
                        writtenByteCount += result
                    } else if result < 0, errno == EINTR {
                        continue
                    } else {
                        throw POSIXOperationError(code: result < 0 ? errno : EIO)
                    }
                }
            }
            try synchronizeDescriptor(descriptor)
            try closeDescriptor(descriptor)
            descriptorIsOpen = false
        } catch {
            if descriptorIsOpen {
                try? closeDescriptor(descriptor)
            }
            removePartialPOSIXFile(at: url)
            throw error
        }
    }

    private static func liveSynchronize(
        at url: URL,
        openFlags: Int32
    ) throws {
        let descriptor = try openExistingFileDescriptor(
            at: url,
            flags: openFlags
        )
        var descriptorIsOpen = true
        do {
            try synchronizeDescriptor(descriptor)
            try closeDescriptor(descriptor)
            descriptorIsOpen = false
        } catch {
            if descriptorIsOpen {
                try? closeDescriptor(descriptor)
            }
            throw error
        }
    }

    private static func liveCreateDirectoryExclusively(at url: URL) throws {
        while true {
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.mkdir(path, S_IRWXU)
            }
            if result == 0 { return }
            let code = errno
            if code == EINTR { continue }
            throw POSIXOperationError(code: code)
        }
    }

    private static func openExclusiveFileDescriptor(at url: URL) throws -> Int32 {
        while true {
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(
                    path,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
            }
            if descriptor >= 0 { return descriptor }
            let code = errno
            if code == EINTR { continue }
            throw POSIXOperationError(code: code)
        }
    }

    private static func openExistingFileDescriptor(
        at url: URL,
        flags: Int32
    ) throws -> Int32 {
        while true {
            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, flags | O_CLOEXEC)
            }
            if descriptor >= 0 { return descriptor }
            let code = errno
            if code == EINTR { continue }
            throw POSIXOperationError(code: code)
        }
    }

    private static func synchronizeDescriptor(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            guard errno == EINTR else {
                throw POSIXOperationError(code: errno)
            }
        }
    }

    private static func closeDescriptor(_ descriptor: Int32) throws {
        while Darwin.close(descriptor) != 0 {
            guard errno == EINTR else {
                throw POSIXOperationError(code: errno)
            }
        }
    }

    private static func removePartialPOSIXFile(at url: URL) {
        while true {
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.unlink(path)
            }
            if result == 0 || errno == ENOENT { return }
            if errno != EINTR { return }
        }
    }

    private static func liveFingerprint(
        at url: URL
    ) throws -> LaunchPersistenceFileFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576),
              !chunk.isEmpty {
            byteCount += UInt64(chunk.count)
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return LaunchPersistenceFileFingerprint(
            byteCount: byteCount,
            sha256: digest
        )
    }
}

enum LaunchPersistenceErrorClassifier {
    static func isUnknownStagedMigrationVersion(_ error: Error) -> Bool {
        containsUnknownStagedMigrationVersion(error as NSError, depth: 0)
    }

    private static func containsUnknownStagedMigrationVersion(
        _ error: NSError,
        depth: Int
    ) -> Bool {
        // Core Data reports "Cannot use staged migration with an unknown model
        // version" as NSCocoaErrorDomain 134504.
        if error.domain == NSCocoaErrorDomain, error.code == 134_504 {
            return true
        }

        let descriptions = [
            error.localizedDescription,
            error.localizedFailureReason,
            error.localizedRecoverySuggestion,
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        let describesStagedMigration =
            descriptions.contains("staged migration") ||
            descriptions.contains("staging migration")
        let describesUnknownModelVersion =
            descriptions.contains("unknown model version") ||
            descriptions.contains("unrecognized model version") ||
            descriptions.contains("unrecognised model version")
        if describesStagedMigration, describesUnknownModelVersion {
            return true
        }

        guard depth < 8 else { return false }
        for value in error.userInfo.values {
            if let nested = value as? NSError,
               containsUnknownStagedMigrationVersion(nested, depth: depth + 1) {
                return true
            }
            if let nestedErrors = value as? [NSError],
               nestedErrors.contains(where: {
                   containsUnknownStagedMigrationVersion($0, depth: depth + 1)
               }) {
                return true
            }
            if let nested = value as? Error,
               containsUnknownStagedMigrationVersion(
                   nested as NSError,
                   depth: depth + 1
               ) {
                return true
            }
            if let nestedErrors = value as? [Error],
               nestedErrors.contains(where: {
                   containsUnknownStagedMigrationVersion(
                       $0 as NSError,
                       depth: depth + 1
                   )
               }) {
                return true
            }
        }
        return false
    }
}

enum LaunchPersistenceKnownLegacyStore: Equatable {
    /// The default, non-`VersionedSchema` model shipped before the explicit
    /// NovaForgeSchemaV1 baseline. It also reports a 1.0.0 identifier, so the
    /// identifier alone can never authorize this compatibility migration.
    case preExplicitSchemaV1
}

enum LaunchPersistenceKnownLegacyStoreClassifier {
    private static let modelVersionChecksumKey =
        "NSStoreModelVersionChecksumKey"
    private static let modelVersionHashesKey =
        "NSStoreModelVersionHashes"
    private static let modelVersionHashesDigestKey =
        "NSStoreModelVersionHashesDigest"
    private static let modelVersionIdentifiersKey =
        "NSStoreModelVersionIdentifiers"

    private static let preExplicitSchemaV1Checksum =
        "aQOGil0EMr8AGv/erCZU9WHPLjisZqFlY+zxDBGc0Ag="
    private static let preExplicitSchemaV1HashesDigest =
        "masscU9dDKfkvThS8HL2SNsPQ8xkq3WNzYSvll3+5yodpVgBRY3wEcdeOCSL/1yTS43oIYe8fgLzUspAbHtuGg=="
    private static let preExplicitSchemaV1EntityNames: Set<String> = [
        "AgentSettings",
        "ChatMessage",
        "Conversation",
        "Project",
        "ProjectArtifact",
        "ProjectEvent",
        "ProjectFileChange",
        "ProjectOSRun",
        "ProjectOSStep",
        "TerminalCommandRecord",
        "ToolRun",
    ]

    static func classify(
        metadata: [String: Any]
    ) -> LaunchPersistenceKnownLegacyStore? {
        guard metadata[modelVersionChecksumKey] as? String ==
                preExplicitSchemaV1Checksum,
              metadata[modelVersionHashesDigestKey] as? String ==
                preExplicitSchemaV1HashesDigest,
              modelVersionIdentifiers(
                  from: metadata[modelVersionIdentifiersKey]
              ) == Set<String>(["1.0.0"]),
              modelVersionEntityNames(
                  from: metadata[modelVersionHashesKey]
              ) == preExplicitSchemaV1EntityNames
        else {
            return nil
        }
        return .preExplicitSchemaV1
    }

    private static func modelVersionIdentifiers(
        from value: Any?
    ) -> Set<String>? {
        if let identifiers = value as? Set<String> {
            return identifiers
        }
        if let identifiers = value as? [String] {
            return Set(identifiers)
        }
        return nil
    }

    private static func modelVersionEntityNames(
        from value: Any?
    ) -> Set<String>? {
        if let hashes = value as? [String: Any] {
            return Set(hashes.keys)
        }
        if let hashes = value as? NSDictionary {
            let names = hashes.allKeys.compactMap { $0 as? String }
            guard names.count == hashes.count else { return nil }
            return Set(names)
        }
        return nil
    }

    static func classify(
        storeAt storeURL: URL
    ) -> LaunchPersistenceKnownLegacyStore? {
        guard let metadata = try? NSPersistentStoreCoordinator
            .metadataForPersistentStore(
                type: .sqlite,
                at: storeURL,
                options: [NSReadOnlyPersistentStoreOption: true]
            )
        else {
            return nil
        }
        return classify(metadata: metadata)
    }
}

enum LaunchPersistenceExplicitV1StoreClassifier {
    private static let modelVersionChecksumKey =
        "NSStoreModelVersionChecksumKey"
    private static let modelVersionHashesKey =
        "NSStoreModelVersionHashes"
    private static let modelVersionHashesDigestKey =
        "NSStoreModelVersionHashesDigest"
    private static let modelVersionIdentifiersKey =
        "NSStoreModelVersionIdentifiers"

    private static let explicitV1Checksum =
        "df3CbAxOVVJKxOmHskef4t1iO5rKU8+N9ZQ7ID9xMLY="
    private static let explicitV1HashesDigest =
        "OcI25dwnfUynOVuoNe7Nec0uP5Oq/MWjChDZ8Wko98px76e7Bt3AX4khfDW/UQeWzm+bC9dPmJ4sGmciUczMNA=="
    private static let explicitV1EntityNames: Set<String> = [
        "AgentRunRecord",
        "AgentSettings",
        "ChatMessage",
        "Conversation",
        "Project",
        "ProjectArtifact",
        "ProjectEvent",
        "ProjectFileChange",
        "ProjectOSRun",
        "ProjectOSStep",
        "TerminalCommandRecord",
        "ToolOperationRecord",
        "ToolRun",
    ]

    static func matches(metadata: [String: Any]) -> Bool {
        guard metadata[modelVersionChecksumKey] as? String ==
                explicitV1Checksum,
              metadata[modelVersionHashesDigestKey] as? String ==
                explicitV1HashesDigest,
              modelVersionIdentifiers(
                  from: metadata[modelVersionIdentifiersKey]
              ) == Set<String>(["1.0.0"]),
              modelVersionEntityNames(
                  from: metadata[modelVersionHashesKey]
              ) == explicitV1EntityNames
        else {
            return false
        }
        return true
    }

    static func matches(storeAt storeURL: URL) -> Bool {
        guard let metadata = try? NSPersistentStoreCoordinator
            .metadataForPersistentStore(
                type: .sqlite,
                at: storeURL,
                options: [NSReadOnlyPersistentStoreOption: true]
            )
        else {
            return false
        }
        return matches(metadata: metadata)
    }

    private static func modelVersionIdentifiers(
        from value: Any?
    ) -> Set<String>? {
        if let identifiers = value as? Set<String> {
            return identifiers
        }
        if let identifiers = value as? [String] {
            return Set(identifiers)
        }
        return nil
    }

    private static func modelVersionEntityNames(
        from value: Any?
    ) -> Set<String>? {
        if let hashes = value as? [String: Any] {
            return Set(hashes.keys)
        }
        if let hashes = value as? NSDictionary {
            let names = hashes.allKeys.compactMap { $0 as? String }
            guard names.count == hashes.count else { return nil }
            return Set(names)
        }
        return nil
    }
}

enum LaunchPersistenceKnownLegacyMigrator {
    struct Dependencies<Container> {
        var openInferredV1Bridge: (URL) throws -> Void
        var isExactExplicitV1Store: (URL) -> Bool
        var openCurrentStagedContainer: (URL) throws -> Container
    }

    private enum MigrationError: Error {
        case inferredBridgeSignatureMismatch
    }

    static func open<Container>(
        storeAt storeURL: URL,
        dependencies: Dependencies<Container>
    ) throws -> Container {
        // A non-versioned schema is intentional here. The legacy store and the
        // first explicit schema both advertise 1.0.0, so asking the V4 staged
        // plan to identify the legacy checksum fails with Core Data 134504.
        // First let Core Data infer only the additive legacy -> explicit-V1
        // change, then require the exact released V1 signature before the
        // ordinary V1 -> V4 staged plan is allowed to run.
        try dependencies.openInferredV1Bridge(storeURL)
        guard dependencies.isExactExplicitV1Store(storeURL) else {
            throw MigrationError.inferredBridgeSignatureMismatch
        }
        return try dependencies.openCurrentStagedContainer(storeURL)
    }

    static func openCurrentContainer(
        storeAt storeURL: URL,
        targetSchema: Schema
    ) throws -> ModelContainer {
        try open(
            storeAt: storeURL,
            dependencies: Dependencies(
                openInferredV1Bridge: { bridgeStoreURL in
                    try performInferredV1Bridge(at: bridgeStoreURL)
                },
                isExactExplicitV1Store: { bridgeStoreURL in
                    LaunchPersistenceExplicitV1StoreClassifier.matches(
                        storeAt: bridgeStoreURL
                    )
                },
                openCurrentStagedContainer: { migratedStoreURL in
                    try ModelContainer(
                        for: targetSchema,
                        migrationPlan: NovaForgeSchemaMigrationPlan.self,
                        configurations: [
                            ModelConfiguration(url: migratedStoreURL)
                        ]
                    )
                }
            )
        )
    }

    private static func performInferredV1Bridge(at storeURL: URL) throws {
        let bridgeSchema = Schema(
            NovaForgeSchemaV1.models,
            version: NovaForgeSchemaV1.versionIdentifier
        )
        try autoreleasepool {
            let bridgeContainer = try ModelContainer(
                for: bridgeSchema,
                configurations: [ModelConfiguration(url: storeURL)]
            )
            // Keep the coordinator alive until initialization has completed,
            // then drain it before validating metadata or opening staged V4.
            withExtendedLifetime(bridgeContainer) {}
        }
    }
}

enum LaunchPersistenceContainerSelectionMode: Equatable {
    case primary
    case migratedKnownLegacyPrimary
    case resumedCompatibility
    case unknownVersionCompatibility
    case recoverySnapshotFailureCompatibility
    case recoverySnapshotCompatibility

    var isCompatibilityFallback: Bool {
        switch self {
        case .primary, .migratedKnownLegacyPrimary:
            false
        case .resumedCompatibility,
             .unknownVersionCompatibility,
             .recoverySnapshotFailureCompatibility,
             .recoverySnapshotCompatibility:
            true
        }
    }
}

struct LaunchPersistenceContainerSelection<Container> {
    let container: Container
    let storeURL: URL
    let mode: LaunchPersistenceContainerSelectionMode

    var isCompatibilityFallback: Bool {
        mode.isCompatibilityFallback
    }
}

struct LaunchPersistenceContainerSelectionDependencies<Container> {
    var fileOperations: LaunchPersistenceFileOperations
    var now: () -> Date
    var makeRecoveryID: () -> UUID
    var openContainer: (URL) throws -> Container
    var isUnknownModelVersion: (Error) -> Bool
    var classifyKnownLegacyStore: (URL) -> LaunchPersistenceKnownLegacyStore? = {
        _ in nil
    }
    var openKnownLegacyContainer: ((URL) throws -> Container)? = nil
}

struct LaunchPersistenceRecoveryManifest: Codable, Equatable {
    struct FileRecord: Codable, Equatable {
        let fileName: String
        let fingerprint: LaunchPersistenceFileFingerprint
    }

    let formatVersion: Int
    let recoveryID: UUID
    let createdAt: Date
    let failureType: String
    let sourceStoreName: String
    let sourceDisposition: String
    let files: [FileRecord]
}

enum LaunchPersistenceStoreQuarantine {
    static let manifestFileName = "recovery-manifest.json"
    static let verifiedCommitFileName = "recovery-verified.commit"

    private enum QuarantineError: Error {
        case copyVerificationFailed
        case manifestVerificationFailed
    }

    private struct FilePair {
        let source: URL
        let destination: URL
    }

    @discardableResult
    static func perform(
        paths: LaunchPersistenceStorePaths,
        reason: Error,
        now: Date,
        recoveryID: UUID,
        files: LaunchPersistenceFileOperations
    ) -> Bool {
        let attemptDirectory = paths.recoveryAttemptDirectoryURL(
            recoveryID: recoveryID
        )

        // The exclusive mkdir is the ownership boundary. A check followed by a
        // normal create would allow two launchers to race into the same attempt.
        do {
            try files.createDirectory(paths.recoveryDirectoryURL)
            try files.synchronizeDirectory(paths.supportURL)
            try files.createDirectoryExclusively(attemptDirectory)
            try files.synchronizeDirectory(paths.recoveryDirectoryURL)
        } catch {
            return false
        }

        let candidateSources = ["", "-wal", "-shm"].map { suffix in
            URL(fileURLWithPath: paths.primaryStoreURL.path + suffix)
        }
        let pairs = candidateSources.compactMap { source -> FilePair? in
            guard files.fileExists(source) else { return nil }
            return FilePair(
                source: source,
                destination: attemptDirectory.appendingPathComponent(
                    source.lastPathComponent
                )
            )
        }
        guard !pairs.isEmpty else { return false }

        let manifestURL = attemptDirectory.appendingPathComponent(
            manifestFileName
        )
        let verifiedCommitURL = attemptDirectory.appendingPathComponent(
            verifiedCommitFileName
        )
        let plannedDestinations = pairs.map { $0.destination } + [
            manifestURL,
            verifiedCommitURL,
        ]
        guard plannedDestinations.allSatisfy({ !files.fileExists($0) }) else {
            return false
        }

        do {
            var records: [LaunchPersistenceRecoveryManifest.FileRecord] = []
            for pair in pairs {
                let sourceFingerprintBeforeCopy = try files.fingerprint(
                    pair.source
                )
                try files.copyItem(pair.source, pair.destination)
                try files.synchronizeFile(pair.destination)
                let sourceFingerprintAfterCopy = try files.fingerprint(
                    pair.source
                )
                let destinationFingerprint = try files.fingerprint(
                    pair.destination
                )
                guard sourceFingerprintBeforeCopy == sourceFingerprintAfterCopy,
                      sourceFingerprintAfterCopy == destinationFingerprint
                else {
                    throw QuarantineError.copyVerificationFailed
                }
                records.append(
                    .init(
                        fileName: pair.destination.lastPathComponent,
                        fingerprint: destinationFingerprint
                    )
                )
            }
            try files.synchronizeDirectory(attemptDirectory)

            let manifest = LaunchPersistenceRecoveryManifest(
                formatVersion: 2,
                recoveryID: recoveryID,
                createdAt: now,
                failureType: String(reflecting: type(of: reason)),
                sourceStoreName: paths.primaryStoreURL.lastPathComponent,
                sourceDisposition: "retained",
                files: records
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let manifestData = try encoder.encode(manifest)
            try files.writeDataDurably(manifestData, manifestURL)
            try files.synchronizeFile(manifestURL)
            guard try files.readData(manifestURL) == manifestData else {
                throw QuarantineError.manifestVerificationFailed
            }
            try files.synchronizeDirectory(attemptDirectory)

            // Re-fingerprint both sides after the manifest is durable and just
            // before publishing the commit. A changing source never produces a
            // verified snapshot.
            let capturedSources = Set(pairs.map { $0.source })
            guard candidateSources.allSatisfy({ source in
                files.fileExists(source) == capturedSources.contains(source)
            }) else {
                throw QuarantineError.copyVerificationFailed
            }
            for (pair, record) in zip(pairs, records) {
                guard try files.fingerprint(pair.source) == record.fingerprint,
                      try files.fingerprint(pair.destination) == record.fingerprint
                else {
                    throw QuarantineError.copyVerificationFailed
                }
            }

            let manifestDigest = SHA256.hash(data: manifestData).map {
                String(format: "%02x", $0)
            }.joined()
            let commitData = Data(
                "NovaForge recovery snapshot v2\nsource=retained\n\(manifestDigest)\n".utf8
            )
            try files.writeDataDurably(commitData, verifiedCommitURL)
            try files.synchronizeFile(verifiedCommitURL)
            guard try files.readData(verifiedCommitURL) == commitData else {
                throw QuarantineError.manifestVerificationFailed
            }
            try files.synchronizeDirectory(attemptDirectory)
        } catch {
            // Incomplete attempts are retained as evidence but are never
            // trusted because they do not have a fully durable verified commit.
            return false
        }

        // A recovery snapshot is deliberately non-destructive. The original
        // SQLite main/WAL/SHM set remains byte-for-byte in place.
        return true
    }
}

enum LaunchPersistenceContainerSelector {
    private enum SelectionError: Error {
        case compatibilityGuardCommitFailed
        case compatibilityGuardClearFailed
        case activeCompatibilityStoreMissing
    }

    private static let compatibilityGuardData = Data(
        "NovaForge compatibility fallback active v1\n".utf8
    )

    static func select<Container>(
        paths: LaunchPersistenceStorePaths,
        migrationStore: UserDefaults,
        dependencies: LaunchPersistenceContainerSelectionDependencies<Container>
    ) throws -> LaunchPersistenceContainerSelection<Container> {
        let files = dependencies.fileOperations
        let compatibilityWasActive = migrationStore.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ) || files.fileExists(paths.compatibilityActiveGuardURL)
        let durableCompatibilityExists = files.fileExists(
            paths.compatibilityStoreURL
        )

        var migratedKnownLegacyPrimary = false
        var knownLegacySnapshotCompleted: Bool?
        let primaryResult: Result<Container, Error>
        do {
            primaryResult = .success(
                try dependencies.openContainer(paths.primaryStoreURL)
            )
        } catch let primaryError {
            if dependencies.classifyKnownLegacyStore(
                   paths.primaryStoreURL
               ) != nil,
               let openKnownLegacyContainer =
                   dependencies.openKnownLegacyContainer {
                // This is the only path allowed to mutate a known legacy
                // primary. The exact main/WAL/SHM preimage must already have a
                // fully durable verified commit before Core Data is allowed to
                // attempt its inferred lightweight migration.
                let snapshotCompleted = LaunchPersistenceStoreQuarantine.perform(
                    paths: paths,
                    reason: primaryError,
                    now: dependencies.now(),
                    recoveryID: dependencies.makeRecoveryID(),
                    files: files
                )
                knownLegacySnapshotCompleted = snapshotCompleted
                if snapshotCompleted {
                    do {
                        primaryResult = .success(
                            try openKnownLegacyContainer(
                                paths.primaryStoreURL
                            )
                        )
                        migratedKnownLegacyPrimary = true
                    } catch {
                        // The verified pre-migration snapshot remains durable.
                        // Preserve the original staged error so the ordinary
                        // unknown-version branch still fails closed.
                        primaryResult = .failure(primaryError)
                    }
                } else {
                    primaryResult = .failure(primaryError)
                }
            } else {
                primaryResult = .failure(primaryError)
            }
        }

        switch primaryResult {
        case let .success(container):
            if compatibilityWasActive {
                if durableCompatibilityExists {
                    // Opening primary proves only that it is readable. It does
                    // not prove that the active fallback lacks newer chats,
                    // receipts, or project state. Keep serving the fallback
                    // until an explicit identity-aware reconciliation clears
                    // its active marker.
                    let fallback = try openCompatibilityContainer(
                        paths: paths,
                        migrationStore: migrationStore,
                        dependencies: dependencies,
                        requireExistingStore: true
                    )
                    return compatibilitySelection(
                        container: fallback,
                        paths: paths,
                        mode: .resumedCompatibility
                    )
                }
                // The active marker is stale only when no fallback store exists.
                // Verify its durable removal before selecting primary.
                try clearCompatibilityActiveGuard(
                    paths: paths,
                    migrationStore: migrationStore,
                    files: files
                )
            }
            return LaunchPersistenceContainerSelection(
                container: container,
                storeURL: paths.primaryStoreURL,
                mode: migratedKnownLegacyPrimary
                    ? .migratedKnownLegacyPrimary
                    : .primary
            )
        case let .failure(primaryError):
            // An active durable branch is pending reconciliation, not a launch
            // pin. Probe primary on every launch; if it still fails, resume the
            // branch without modifying either store.
            if compatibilityWasActive, durableCompatibilityExists {
                let fallback = try openCompatibilityContainer(
                    paths: paths,
                    migrationStore: migrationStore,
                    dependencies: dependencies,
                    requireExistingStore: true
                )
                return compatibilitySelection(
                    container: fallback,
                    paths: paths,
                    mode: .resumedCompatibility
                )
            }

            if compatibilityWasActive {
                // Never create an empty replacement when the durable marker says
                // a fallback branch owns data but that branch is unavailable.
                throw SelectionError.activeCompatibilityStoreMissing
            }

            // A fallback must be open and its active guard visible before the
            // generic recovery snapshot below. The exact known-legacy path has
            // already required its own verified snapshot before any migration.
            // If fallback open fails, this branch does not mutate the primary.
            let fallback = try openCompatibilityContainer(
                paths: paths,
                migrationStore: migrationStore,
                dependencies: dependencies,
                requireExistingStore: false
            )

            if let knownLegacySnapshotCompleted {
                return compatibilitySelection(
                    container: fallback,
                    paths: paths,
                    mode: knownLegacySnapshotCompleted
                        ? .unknownVersionCompatibility
                        : .recoverySnapshotFailureCompatibility
                )
            }

            if dependencies.isUnknownModelVersion(primaryError) {
                return compatibilitySelection(
                    container: fallback,
                    paths: paths,
                    mode: .unknownVersionCompatibility
                )
            }

            let snapshotCompleted = LaunchPersistenceStoreQuarantine.perform(
                paths: paths,
                reason: primaryError,
                now: dependencies.now(),
                recoveryID: dependencies.makeRecoveryID(),
                files: files
            )
            guard snapshotCompleted else {
                return compatibilitySelection(
                    container: fallback,
                    paths: paths,
                    mode: .recoverySnapshotFailureCompatibility
                )
            }
            return compatibilitySelection(
                container: fallback,
                paths: paths,
                mode: .recoverySnapshotCompatibility
            )
        }
    }

    private static func openCompatibilityContainer<Container>(
        paths: LaunchPersistenceStorePaths,
        migrationStore: UserDefaults,
        dependencies: LaunchPersistenceContainerSelectionDependencies<Container>,
        requireExistingStore: Bool
    ) throws -> Container {
        if requireExistingStore,
           !dependencies.fileOperations.fileExists(
               paths.compatibilityStoreURL
           ) {
            throw SelectionError.activeCompatibilityStoreMissing
        }
        let compatibilityDirectory = paths.compatibilityStoreURL
            .deletingLastPathComponent()
        try dependencies.fileOperations.createDirectory(
            compatibilityDirectory
        )
        try dependencies.fileOperations.synchronizeDirectory(
            paths.supportURL
        )
        let container = try dependencies.openContainer(
            paths.compatibilityStoreURL
        )
        guard dependencies.fileOperations.fileExists(
            paths.compatibilityStoreURL
        ) else {
            throw SelectionError.activeCompatibilityStoreMissing
        }
        if dependencies.fileOperations.fileExists(
            paths.compatibilityActiveGuardURL
        ) {
            // Existence, not marker payload, is the durable active-branch fact.
            // A torn or older marker must resume an existing fallback safely.
        } else {
            try dependencies.fileOperations.writeDataDurably(
                compatibilityGuardData,
                paths.compatibilityActiveGuardURL
            )
            try dependencies.fileOperations.synchronizeFile(
                paths.compatibilityActiveGuardURL
            )
            guard try dependencies.fileOperations.readData(
                paths.compatibilityActiveGuardURL
            ) == compatibilityGuardData else {
                throw SelectionError.compatibilityGuardCommitFailed
            }
            try dependencies.fileOperations.synchronizeDirectory(
                compatibilityDirectory
            )
        }
        ProjectBootstrap.setCompatibilityFallbackActive(
            true,
            in: migrationStore
        )
        guard migrationStore.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ) else {
            throw SelectionError.compatibilityGuardCommitFailed
        }
        return container
    }

    private static func clearCompatibilityActiveGuard(
        paths: LaunchPersistenceStorePaths,
        migrationStore: UserDefaults,
        files: LaunchPersistenceFileOperations
    ) throws {
        if files.fileExists(paths.compatibilityActiveGuardURL) {
            try files.removeItem(paths.compatibilityActiveGuardURL)
            guard !files.fileExists(paths.compatibilityActiveGuardURL) else {
                throw SelectionError.compatibilityGuardClearFailed
            }
            try files.synchronizeDirectory(
                paths.compatibilityActiveGuardURL.deletingLastPathComponent()
            )
            guard !files.fileExists(paths.compatibilityActiveGuardURL) else {
                throw SelectionError.compatibilityGuardClearFailed
            }
        }
        ProjectBootstrap.setCompatibilityFallbackActive(
            false,
            in: migrationStore
        )
        guard !migrationStore.bool(
            forKey: ProjectBootstrap.compatibilityFallbackActiveKey
        ) else {
            throw SelectionError.compatibilityGuardClearFailed
        }
    }

    private static func compatibilitySelection<Container>(
        container: Container,
        paths: LaunchPersistenceStorePaths,
        mode: LaunchPersistenceContainerSelectionMode
    ) -> LaunchPersistenceContainerSelection<Container> {
        return LaunchPersistenceContainerSelection(
            container: container,
            storeURL: paths.compatibilityStoreURL,
            mode: mode
        )
    }
}

@MainActor
@main
struct NovaForgeMainApp: App {
    @UIApplicationDelegateAdaptor(NovaForgeAppDelegate.self) private var appDelegate
    let container: ModelContainer
    private static let safeStartTitle = LaunchConversationSelection.safeStartTitle
    private static let launchPersistenceLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.joey.NovaForge",
        category: "LaunchPersistence"
    )
    @AppStorage(AgentTheme.storageKey) private var selectedThemeRawValue = AgentTheme.defaultTheme.rawValue

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let launchTheme = AgentTheme.launchOverride(from: arguments) {
            UserDefaults.standard.set(launchTheme.rawValue, forKey: AgentTheme.storageKey)
            AgentPalette.refreshThemeCache(launchTheme)
        } else {
            AgentPalette.refreshThemeCache(AgentTheme.normalizeStoredTheme())
        }
        AgentThemeUIKit.apply(AgentTheme.current)
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let supportURL {
            try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        }

        let schema = Schema(versionedSchema: NovaForgeSchemaV4.self)

        let persistenceSupportURL = supportURL ?? FileManager.default.temporaryDirectory
        let storeURL = persistenceSupportURL.appendingPathComponent("NovaForge.store")

        #if DEBUG || targetEnvironment(simulator)
        if arguments.contains("--reset-ui") {
            do {
                try LaunchDebugPersistenceReset.reset(at: supportURL)
            } catch {
                // Do not interpolate storage errors: they can contain local
                // paths or persistent payload details.
                fatalError(
                    "NovaForge could not safely reset its debug fixture state."
                )
            }
            UserDefaults.standard.set(AgentTheme.defaultTheme.rawValue, forKey: AgentTheme.storageKey)
            if let launchTheme = AgentTheme.launchOverride(from: arguments) {
                UserDefaults.standard.set(launchTheme.rawValue, forKey: AgentTheme.storageKey)
            }
            AgentPalette.refreshThemeCache(AgentTheme.current)
            AgentThemeUIKit.apply(AgentTheme.current)
            UserDefaults.standard.removeObject(forKey: LaunchConversationSelection.persistedSelectionKey)
            UserDefaults.standard.removeObject(forKey: AgentRunPreferenceStore.effortKey)
            UserDefaults.standard.removeObject(forKey: AgentRunPreferenceStore.orchestrationKey)
        }
        #endif

        let containerOpenResult = Self.makeContainer(
            schema: schema,
            primaryStoreURL: storeURL,
            supportURL: persistenceSupportURL
        )
        container = containerOpenResult.container

        let context = container.mainContext
        do {
            var settingsFetch = FetchDescriptor<AgentSettings>()
            settingsFetch.fetchLimit = 1
            let existingSettings = try context.fetch(settingsFetch)
            let existingConversations = try context.fetch(FetchDescriptor<Conversation>())
            let projectRecords = try ProjectBootstrap.prefetchRecords(in: context)

            // Launch mutation begins only after all required store reads have
            // succeeded, so a fetch error can never manufacture empty defaults.
            let settings: AgentSettings
            if let existing = existingSettings.first {
                settings = existing
                if settings.provider == .openAI,
                   settings.modelID == "gpt-5.5" {
                    settings.provider = .local
                    settings.modelID = AIProvider.local.defaultModel
                    settings.updatedAt = Date()
                } else if settings.provider == .local,
                          let selectedVariant = LocalModelCatalog.variant(for: settings.modelID),
                          LocalModelCatalog.compatibilityMessage(for: selectedVariant) != nil {
                    settings.modelID = LocalModelCatalog.defaultVariant.id
                    settings.updatedAt = Date()
                }
            } else {
                let created = AgentSettings()
                context.insert(created)
                settings = created
            }

            let activeProject = ProjectBootstrap.ensureDefaultProject(
                in: context,
                settings: settings,
                prefetched: projectRecords
            )

            if existingConversations.isEmpty {
                insertReadyConversation(in: context, project: activeProject)
            } else {
                normalizeConversationMetadata(existingConversations)
                ensureFreshLaunchConversation(
                    in: context,
                    project: activeProject,
                    conversations: existingConversations
                )
            }

            var deferredSelectionID: UUID?
            if Self.hasLaunchFlag("--stress-chat", in: arguments),
               let stressConversation = try seedStressConversation(in: context, project: activeProject) {
                deferredSelectionID = stressConversation.id
            }
            #if DEBUG || targetEnvironment(simulator)
            if arguments.contains("--stress-tool-batch"),
               let batchConversation = try seedToolBatchConversation(in: context, project: activeProject) {
                deferredSelectionID = batchConversation.id
            }
            if arguments.contains("--running-tool-call-demo"),
               let runningConversation = try seedRunningToolCallConversation(in: context, project: activeProject) {
                deferredSelectionID = runningConversation.id
            }
            if arguments.contains("--failed-tool-call-demo"),
               let failedConversation = try seedFailedToolCallConversation(in: context, project: activeProject) {
                deferredSelectionID = failedConversation.id
            }
            if arguments.contains("--code-block-demo"),
               let codeBlockConversation = try seedCodeBlockConversation(in: context, project: activeProject) {
                deferredSelectionID = codeBlockConversation.id
            }
            #endif

            try context.save()
            ProjectBootstrap.markLegacyOwnershipMigrationComplete()
            if let deferredSelectionID {
                UserDefaults.standard.set(
                    deferredSelectionID.uuidString,
                    forKey: LaunchConversationSelection.persistedSelectionKey
                )
            }
        } catch {
            context.rollback()
            // Keep the log intentionally free of store paths, payloads, and
            // provider configuration. A later launch can safely retry.
            Self.launchPersistenceLogger.error("Launch persistence transaction failed; changes were rolled back.")
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .modelContainer(container)
                .agentThemeTypography(selectedTheme)
                .preferredColorScheme(selectedTheme.preferredColorScheme)
        }
    }

    private var selectedTheme: AgentTheme {
        AgentTheme.resolved(from: selectedThemeRawValue)
    }

    // MARK: - Static Helpers

    private static func hasLaunchFlag(_ flag: String, in arguments: [String]) -> Bool {
        arguments.contains(flag) ||
            arguments.joined(separator: " ").contains(flag) ||
            arguments.contains { argument in
                argument == flag ||
                    argument.hasPrefix("\(flag)=") ||
                    argument.split(whereSeparator: { $0.isWhitespace }).contains(Substring(flag))
            }
    }

    private static func makeContainer(
        schema: Schema,
        primaryStoreURL: URL,
        supportURL: URL
    ) -> ContainerOpenResult {
        let paths = LaunchPersistenceStorePaths(
            supportURL: supportURL,
            primaryStoreURL: primaryStoreURL
        )
        do {
            let selection = try LaunchPersistenceContainerSelector.select(
                paths: paths,
                migrationStore: .standard,
                dependencies: LaunchPersistenceContainerSelectionDependencies(
                    fileOperations: .live,
                    now: Date.init,
                    makeRecoveryID: { UUID() },
                    openContainer: { storeURL in
                        try ModelContainer(
                            for: schema,
                            migrationPlan: NovaForgeSchemaMigrationPlan.self,
                            configurations: [ModelConfiguration(url: storeURL)]
                        )
                    },
                    isUnknownModelVersion: LaunchPersistenceErrorClassifier
                        .isUnknownStagedMigrationVersion,
                    classifyKnownLegacyStore: { storeURL in
                        LaunchPersistenceKnownLegacyStoreClassifier.classify(
                            storeAt: storeURL
                        )
                    },
                    openKnownLegacyContainer: { storeURL in
                        try LaunchPersistenceKnownLegacyMigrator
                            .openCurrentContainer(
                                storeAt: storeURL,
                                targetSchema: schema
                            )
                    }
                )
            )

            switch selection.mode {
            case .primary:
                retainCompatibilityBranchForExplicitRecovery(paths: paths)
            case .migratedKnownLegacyPrimary:
                launchPersistenceLogger.notice(
                    "NovaForge migrated a verified known legacy store and retained its pre-migration recovery snapshot."
                )
            case .resumedCompatibility:
                launchPersistenceLogger.notice(
                    "NovaForge probed the primary store and resumed its durable compatibility branch without discarding either branch."
                )
            case .unknownVersionCompatibility:
                launchPersistenceLogger.error(
                    "The persistent store uses an unrecognized model version; NovaForge retained that branch and is using its durable compatibility store."
                )
            case .recoverySnapshotFailureCompatibility:
                launchPersistenceLogger.error(
                    "A recovery snapshot could not be durably verified; NovaForge is using its durable compatibility store."
                )
            case .recoverySnapshotCompatibility:
                launchPersistenceLogger.notice(
                    "A non-destructive recovery snapshot was verified; NovaForge is using its durable compatibility store for this launch."
                )
            }
            return ContainerOpenResult(container: selection.container)
        } catch {
            // Do not interpolate storage errors: they can contain local paths,
            // model metadata, or persistent payload details.
            fatalError("NovaForge could not safely open a durable persistent store.")
        }
    }

    private static func retainCompatibilityBranchForExplicitRecovery(
        paths: LaunchPersistenceStorePaths
    ) {
        guard FileManager.default.fileExists(
            atPath: paths.compatibilityStoreURL.path
        ) else { return }
        // A blind two-store merge could overwrite UUID-owned chats, projects,
        // receipts, or dispositions. Retain the compatibility branch for an
        // explicit identity-aware recovery/import.
        launchPersistenceLogger.notice(
            "The primary store reopened; a separate compatibility branch was retained for explicit recovery."
        )
    }

    private struct ContainerOpenResult {
        let container: ModelContainer
    }

    private static func configureTabBarAppearance() {
        AgentThemeUIKit.apply(AgentTheme.current)
    }

    // MARK: - Instance Helpers

    private func ensureFreshLaunchConversation(
        in context: ModelContext,
        project: Project,
        conversations: [Conversation]
    ) {
        let readyConversations = conversations.filter { $0.title == Self.safeStartTitle }
        if let unusedReady = readyConversations.first(where: { !$0.hasUserMessages }) {
            unusedReady.project = nil
            for message in unusedReady.messages {
                context.delete(message)
            }
            unusedReady.messages.removeAll()
            unusedReady.refreshMessageMetadata(updateTimestamp: Date())
        } else {
            insertReadyConversation(in: context, project: project)
        }
    }

    private func normalizeConversationMetadata(_ conversations: [Conversation]) {
        for conversation in conversations {
            conversation.refreshMessageMetadata()
        }
    }

    private func insertReadyConversation(in context: ModelContext, project: Project) {
        let conversation = Conversation(title: Self.safeStartTitle, project: nil)
        context.insert(conversation)
        ProjectEventRecorder.record(
            project: nil,
            kind: .conversationStarted,
            title: "Launch conversation ready",
            detail: conversation.title,
            severity: .info,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
    }

    @discardableResult
    private func seedStressConversation(in context: ModelContext, project: Project) throws -> Conversation? {
        let marker = "NovaForge Stress — 200 messages / 66 tools"
        let legacyMarker = "NovaForge Stress — 60 messages / 20 tools"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { conversation in
            conversation.title == marker || conversation.title == legacyMarker || conversation.title == "NovaForge Stress — 61 messages / 20 tools"
        })
        if let existing = try context.fetch(descriptor).first {
            existing.title = marker
            existing.project = project
            ensureStressConversationHasLongHistory(existing, context: context)
            existing.refreshMessageMetadata(updateTimestamp: Date())
            try seedStressToolRuns(in: context, project: project)
            return existing
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)
        ensureStressConversationHasLongHistory(conversation, context: context)
        conversation.refreshMessageMetadata(updateTimestamp: Date())
        try seedStressToolRuns(in: context, project: project)
        return conversation
    }

    private func ensureStressConversationHasLongHistory(_ conversation: Conversation, context: ModelContext) {
        let existingStressMessages = conversation.messages.filter { message in
            message.content.hasPrefix("Stress message ") ||
            message.content.hasPrefix("I'll inspect that file.") ||
            message.content.hasPrefix("Read Sources/File")
        }
        let seededExchangeCount = min(Self.stressExchangeCount, existingStressMessages.count / 3)
        if seededExchangeCount < Self.stressExchangeCount {
            for index in (seededExchangeCount + 1)...Self.stressExchangeCount {
                appendStressExchange(index, to: conversation, context: context)
            }
        }

        if !conversation.messages.contains(where: { $0.content == Self.stressCompletionText }) {
            appendStressCompletion(to: conversation, context: context)
        }
        if !conversation.messages.contains(where: { $0.content == Self.stressFinalCheckpointText }) {
            let checkpoint = ChatMessage(
                role: .assistant,
                content: Self.stressFinalCheckpointText,
                conversation: conversation
            )
            conversation.appendMessage(checkpoint)
            context.insert(checkpoint)
        }
    }

    private func appendStressExchange(_ index: Int, to conversation: Conversation, context: ModelContext) {
        let user = ChatMessage(
            role: .user,
            content: "Stress message \(index): inspect Sources/File\(index).swift and summarize it.",
            conversation: conversation
        )
        let call = APIToolCall(
            id: "stress-call-\(index)",
            type: "function",
            function: APIFunctionCall(name: "read_file", arguments: "{\"path\":\"Sources/File\(index).swift\"}")
        )
        let callJSON = (try? JSONEncoder().encode([call])).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: "I'll inspect that file.",
            toolCallsJSON: callJSON,
            conversation: conversation
        )
        let tool = ChatMessage(
            role: .tool,
            content: "Read Sources/File\(index).swift\n" + String(repeating: "fixture output ", count: 42),
            toolCallID: call.id,
            conversation: conversation
        )
        conversation.appendMessages([user, assistant, tool])
        context.insert(user)
        context.insert(assistant)
        context.insert(tool)
    }

    private func appendStressCompletion(to conversation: Conversation, context: ModelContext) {
        let completion = ChatMessage(
            role: .assistant,
            content: Self.stressCompletionText,
            conversation: conversation
        )
        conversation.appendMessage(completion)
        context.insert(completion)
    }

    private static let stressExchangeCount = 66
    private static let stressCompletionText = "Stress navigation fixture ready: 66 file reads completed, drawer rows and tab switching are ready to verify."
    private static let stressFinalCheckpointText = "Stress window checkpoint: this conversation intentionally contains 200 messages so long-history rendering, jump-to-latest, and tab transitions can be verified."

    private func seedStressToolRuns(in context: ModelContext, project: Project) throws {
        for index in 1...66 {
            let name = "stress_read_file_\(index)"
            var descriptor = FetchDescriptor<ToolRun>(
                predicate: #Predicate { $0.name == name }
            )
            descriptor.fetchLimit = 1
            if let existing = try context.fetch(descriptor).first {
                existing.project = project
                continue
            }

            let run = ToolRun(
                name: name,
                argumentsJSON: "{\"path\":\"Sources/File\(index).swift\"}",
                output: "Read Sources/File\(index).swift\n" + String(repeating: "fixture output ", count: 90),
                status: index.isMultiple(of: 9) ? .failed : .completed,
                requiresApproval: false,
                isMutating: false,
                project: project
            )
            run.createdAt = Date().addingTimeInterval(-Double(index) * 45)
            run.completedAt = run.createdAt.addingTimeInterval(Double(90 + index * 12) / 1000.0)
            context.insert(run)
        }
    }

    #if DEBUG || targetEnvironment(simulator)
    @discardableResult
    private func seedToolBatchConversation(in context: ModelContext, project: Project) throws -> Conversation? {
        let marker = "NovaForge Batch — 14 resolved actions"
        let legacyMarker = "NovaForge Stress — batched tool calls"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == marker })
        if let existing = try context.fetch(descriptor).first {
            existing.project = project
            ensureToolBatchConversationCompletesWithAssistant(existing, context: context)
            existing.refreshMessageMetadata(updateTimestamp: Date())
            return existing
        }
        let legacyDescriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == legacyMarker })
        if let legacy = try context.fetch(legacyDescriptor).first {
            legacy.title = marker
            legacy.project = project
            ensureToolBatchConversationCompletesWithAssistant(legacy, context: context)
            legacy.refreshMessageMetadata(updateTimestamp: Date())
            return legacy
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)

        let user = ChatMessage(
            role: .user,
            content: "Inspect this generated module map and queue the useful file reads.",
            conversation: conversation
        )
        let calls = (1...14).map { index in
            APIToolCall(
                id: "batch-read-\(index)",
                type: "function",
                function: APIFunctionCall(
                    name: "read_file",
                    arguments: "{\"path\":\"Sources/Generated/Module\(index).swift\"}"
                )
            )
        }
        let callJSON = (try? JSONEncoder().encode(calls)).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: "I'll inspect the generated modules in a single batch.",
            toolCallsJSON: callJSON,
            conversation: conversation
        )
        let toolMessages = calls.enumerated().map { offset, call in
            let index = offset + 1
            let failed = index.isMultiple(of: 6)
            return ChatMessage(
                role: .tool,
                content: failed
                    ? "Error: Sources/Generated/Module\(index).swift was not found."
                    : "Read Sources/Generated/Module\(index).swift\n" + String(repeating: "validated symbol map ", count: 36),
                toolCallID: call.id,
                conversation: conversation
            )
        }

        conversation.appendMessages([user, assistant] + toolMessages)
        context.insert(user)
        context.insert(assistant)
        toolMessages.forEach(context.insert)
        appendToolBatchCompletion(to: conversation, context: context)
        conversation.refreshMessageMetadata(updateTimestamp: Date())
        return conversation
    }

    private static let toolBatchCompletionText = "Batch fixture complete: 14 actions resolved with completed and failed labels ready to inspect."

    private func ensureToolBatchConversationCompletesWithAssistant(_ conversation: Conversation, context: ModelContext) {
        let ordered = conversation.messages.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard ordered.last?.content != Self.toolBatchCompletionText else { return }
        appendToolBatchCompletion(to: conversation, context: context)
    }

    private func appendToolBatchCompletion(to conversation: Conversation, context: ModelContext) {
        let completion = ChatMessage(
            role: .assistant,
            content: Self.toolBatchCompletionText,
            conversation: conversation
        )
        conversation.appendMessage(completion)
        context.insert(completion)
    }

    @discardableResult
    private func seedRunningToolCallConversation(in context: ModelContext, project: Project) throws -> Conversation? {
        let marker = "NovaForge Running Action — compact fixture"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == marker })
        if let existing = try context.fetch(descriptor).first {
            existing.project = project
            existing.refreshMessageMetadata(updateTimestamp: Date())
            return existing
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)
        let user = ChatMessage(
            role: .user,
            content: "Read the config file and keep the activity visible while it runs.",
            conversation: conversation
        )
        let call = APIToolCall(
            id: "running-read-config",
            type: "function",
            function: APIFunctionCall(
                name: "read_file",
                arguments: #"{"path":"Sources/Generated/Config.swift"}"#
            )
        )
        let callJSON = (try? JSONEncoder().encode([call])).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: "I'll read that file and keep the activity visible while it runs.",
            toolCallsJSON: callJSON,
            conversation: conversation
        )

        conversation.appendMessages([user, assistant], updateTimestamp: Date())
        context.insert(user)
        context.insert(assistant)
        return conversation
    }

    @discardableResult
    private func seedFailedToolCallConversation(in context: ModelContext, project: Project) throws -> Conversation? {
        let marker = "NovaForge Failed Action — compact fixture"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == marker })
        if let existing = try context.fetch(descriptor).first {
            existing.project = project
            existing.refreshMessageMetadata(updateTimestamp: Date())
            return existing
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)
        let user = ChatMessage(
            role: .user,
            content: "Read the missing config file and tell me what happened.",
            conversation: conversation
        )
        let call = APIToolCall(
            id: "failed-read-config",
            type: "function",
            function: APIFunctionCall(
                name: "read_file",
                arguments: #"{"path":"Sources/Missing/Config.swift"}"#
            )
        )
        let callJSON = (try? JSONEncoder().encode([call])).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: "I'll check that file quietly and surface the result.",
            toolCallsJSON: callJSON,
            conversation: conversation
        )
        let tool = ChatMessage(
            role: .tool,
            content: "Error: Sources/Missing/Config.swift was not found. Check the path or create the file before retrying.",
            toolCallID: call.id,
            conversation: conversation
        )
        let completion = ChatMessage(
            role: .assistant,
            content: "I could not read Config.swift. The file is missing, so create it or update the path before retrying.",
            conversation: conversation
        )

        conversation.appendMessages([user, assistant, tool, completion], updateTimestamp: Date())
        context.insert(user)
        context.insert(assistant)
        context.insert(tool)
        context.insert(completion)
        return conversation
    }

    @discardableResult
    private func seedCodeBlockConversation(in context: ModelContext, project: Project) throws -> Conversation? {
        let marker = "NovaForge Code Block — actions fixture"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == marker })
        if let existing = try context.fetch(descriptor).first {
            existing.project = project
            existing.refreshMessageMetadata(updateTimestamp: Date())
            return existing
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)
        let user = ChatMessage(
            role: .user,
            content: "Generate a small Swift helper and make it easy to copy or save.",
            conversation: conversation
        )
        let helperSource = (1...36)
            .map { "    func generatedStep\($0)() -> String { \"step-\($0)\" }" }
            .joined(separator: "\n")
        let assistant = ChatMessage(
            role: .assistant,
            content: """
            Here is the generated helper:

            ```swift
            struct GeneratedHelper {
                let name: String

            \(helperSource)
            }
            ```
            """,
            conversation: conversation
        )
        conversation.appendMessages([user, assistant], updateTimestamp: Date())
        context.insert(user)
        context.insert(assistant)
        return conversation
    }
    #endif
}

@MainActor
final class NovaForgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        ArtifactOrientationController.supportedInterfaceOrientations
    }
}
