import Foundation

enum AgentPolicyStorePathError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case invalidApplicationSupportDirectory
    case pathEscapesApplicationSupport
    case symbolicLinkRejected
    case invalidEntryType
    case fileSystemFailure
    case protectionUnavailable
    case backupExclusionUnavailable
}

enum AgentPolicyStoreFileItemKind: Equatable, Sendable {
    case missing
    case directory
    case regularFile
    case symbolicLink
    case other
}

enum AgentPolicyDirectoryProtection: Equatable, Sendable {
    case complete
}

protocol AgentPolicyStoreFileSystem: Sendable {
    func applicationSupportDirectory() throws -> URL
    func itemKind(at url: URL) throws -> AgentPolicyStoreFileItemKind
    func createDirectory(
        at url: URL,
        protection: AgentPolicyDirectoryProtection
    ) throws
    func setProtection(
        _ protection: AgentPolicyDirectoryProtection,
        at url: URL
    ) throws
    func protection(
        at url: URL
    ) throws -> AgentPolicyDirectoryProtection?
    func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws
    func isExcludedFromBackup(at url: URL) throws -> Bool
}

/// Canonical on-device locations for AgentPolicy's two durable ledgers.
///
/// Callers cannot construct this value directly. `prepare()` is the only
/// composition boundary, so every returned location has passed lexical
/// containment, symlink, type, data-protection, and backup-exclusion checks.
struct AgentPolicyStorePaths: Equatable, Sendable {
    static let schemaVersion = "v1"

    let applicationSupportDirectory: URL
    let policyDirectory: URL
    let versionDirectory: URL
    let checkpointDirectory: URL
    let policyAuthorityLedgerURL: URL
    let mutationEffectLifecycleLedgerURL: URL

    private init(
        applicationSupportDirectory: URL,
        policyDirectory: URL,
        versionDirectory: URL,
        checkpointDirectory: URL,
        policyAuthorityLedgerURL: URL,
        mutationEffectLifecycleLedgerURL: URL
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.policyDirectory = policyDirectory
        self.versionDirectory = versionDirectory
        self.checkpointDirectory = checkpointDirectory
        self.policyAuthorityLedgerURL = policyAuthorityLedgerURL
        self.mutationEffectLifecycleLedgerURL = mutationEffectLifecycleLedgerURL
    }

    static func prepare(
        fileSystem: any AgentPolicyStoreFileSystem =
            AgentPolicyDefaultStoreFileSystem()
    ) throws -> AgentPolicyStorePaths {
        let requestedSupport: URL
        do {
            requestedSupport = try fileSystem.applicationSupportDirectory()
        } catch {
            throw AgentPolicyStorePathError.applicationSupportUnavailable
        }

        guard requestedSupport.isFileURL,
              requestedSupport.path.hasPrefix("/"),
              !requestedSupport.path.isEmpty
        else {
            throw AgentPolicyStorePathError.invalidApplicationSupportDirectory
        }

        let support = requestedSupport.standardizedFileURL
        guard support.path != "/" else {
            throw AgentPolicyStorePathError.invalidApplicationSupportDirectory
        }

        let policy = support.appendingPathComponent(
            "AgentPolicy",
            isDirectory: true
        ).standardizedFileURL
        let version = policy.appendingPathComponent(
            schemaVersion,
            isDirectory: true
        ).standardizedFileURL
        let checkpoints = version.appendingPathComponent(
            "checkpoints",
            isDirectory: true
        ).standardizedFileURL
        let authority = version.appendingPathComponent(
            "policy-authority.ledger",
            isDirectory: false
        ).standardizedFileURL
        let mutation = version.appendingPathComponent(
            "mutation-effect-lifecycle.ledger",
            isDirectory: false
        ).standardizedFileURL

        guard isStrictDescendant(policy, of: support),
              isStrictDescendant(version, of: policy),
              isStrictDescendant(checkpoints, of: version),
              isStrictDescendant(authority, of: version),
              isStrictDescendant(mutation, of: version)
        else {
            throw AgentPolicyStorePathError.pathEscapesApplicationSupport
        }

        try requireExistingDirectory(support, fileSystem: fileSystem)
        try prepareProtectedDirectory(policy, fileSystem: fileSystem)
        try prepareProtectedDirectory(version, fileSystem: fileSystem)
        try prepareProtectedDirectory(checkpoints, fileSystem: fileSystem)
        try requireSafeLedgerLocation(authority, fileSystem: fileSystem)
        try requireSafeLedgerLocation(mutation, fileSystem: fileSystem)

        return AgentPolicyStorePaths(
            applicationSupportDirectory: support,
            policyDirectory: policy,
            versionDirectory: version,
            checkpointDirectory: checkpoints,
            policyAuthorityLedgerURL: authority,
            mutationEffectLifecycleLedgerURL: mutation
        )
    }

    private static func requireExistingDirectory(
        _ url: URL,
        fileSystem: any AgentPolicyStoreFileSystem
    ) throws {
        switch try kind(at: url, fileSystem: fileSystem) {
        case .directory:
            return
        case .symbolicLink:
            throw AgentPolicyStorePathError.symbolicLinkRejected
        case .missing, .regularFile, .other:
            throw AgentPolicyStorePathError.invalidApplicationSupportDirectory
        }
    }

    private static func prepareProtectedDirectory(
        _ url: URL,
        fileSystem: any AgentPolicyStoreFileSystem
    ) throws {
        switch try kind(at: url, fileSystem: fileSystem) {
        case .missing:
            do {
                try fileSystem.createDirectory(at: url, protection: .complete)
            } catch {
                throw AgentPolicyStorePathError.fileSystemFailure
            }
        case .directory:
            break
        case .symbolicLink:
            throw AgentPolicyStorePathError.symbolicLinkRejected
        case .regularFile, .other:
            throw AgentPolicyStorePathError.invalidEntryType
        }

        // Re-inspect after creation before applying metadata. A path swap or a
        // filesystem implementation that did not create exactly a directory
        // must fail closed.
        switch try kind(at: url, fileSystem: fileSystem) {
        case .directory:
            break
        case .symbolicLink:
            throw AgentPolicyStorePathError.symbolicLinkRejected
        case .missing, .regularFile, .other:
            throw AgentPolicyStorePathError.invalidEntryType
        }

        do {
            try fileSystem.setProtection(.complete, at: url)
            try fileSystem.setExcludedFromBackup(true, at: url)
        } catch {
            throw AgentPolicyStorePathError.fileSystemFailure
        }

        let observedProtection: AgentPolicyDirectoryProtection?
        do {
            observedProtection = try fileSystem.protection(at: url)
        } catch {
            throw AgentPolicyStorePathError.protectionUnavailable
        }
        guard observedProtection == .complete else {
            throw AgentPolicyStorePathError.protectionUnavailable
        }

        let excluded: Bool
        do {
            excluded = try fileSystem.isExcludedFromBackup(at: url)
        } catch {
            throw AgentPolicyStorePathError.backupExclusionUnavailable
        }
        guard excluded else {
            throw AgentPolicyStorePathError.backupExclusionUnavailable
        }

        // Metadata APIs may resolve links internally, so pin the invariant one
        // final time after all mutations.
        switch try kind(at: url, fileSystem: fileSystem) {
        case .directory:
            return
        case .symbolicLink:
            throw AgentPolicyStorePathError.symbolicLinkRejected
        case .missing, .regularFile, .other:
            throw AgentPolicyStorePathError.invalidEntryType
        }
    }

    private static func requireSafeLedgerLocation(
        _ url: URL,
        fileSystem: any AgentPolicyStoreFileSystem
    ) throws {
        switch try kind(at: url, fileSystem: fileSystem) {
        case .missing, .regularFile:
            return
        case .symbolicLink:
            throw AgentPolicyStorePathError.symbolicLinkRejected
        case .directory, .other:
            throw AgentPolicyStorePathError.invalidEntryType
        }
    }

    private static func kind(
        at url: URL,
        fileSystem: any AgentPolicyStoreFileSystem
    ) throws -> AgentPolicyStoreFileItemKind {
        do {
            return try fileSystem.itemKind(at: url)
        } catch {
            throw AgentPolicyStorePathError.fileSystemFailure
        }
    }

    private static func isStrictDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.count > parentComponents.count else { return false }
        return childComponents.prefix(parentComponents.count)
            .elementsEqual(parentComponents)
    }
}

struct AgentPolicyDefaultStoreFileSystem: AgentPolicyStoreFileSystem {
    private var fileManager: FileManager { FileManager.default }

    func applicationSupportDirectory() throws -> URL {
        guard let url = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AgentPolicyStorePathError.applicationSupportUnavailable
        }
        return url
    }

    func itemKind(at url: URL) throws -> AgentPolicyStoreFileItemKind {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                return .directory
            case .typeRegular:
                return .regularFile
            case .typeSymbolicLink:
                return .symbolicLink
            default:
                return .other
            }
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile
                || error.code == .fileReadNoSuchFile
        {
            return .missing
        } catch {
            throw AgentPolicyStorePathError.fileSystemFailure
        }
    }

    func createDirectory(
        at url: URL,
        protection: AgentPolicyDirectoryProtection
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: protection.fileProtectionType]
        )
    }

    func setProtection(
        _ protection: AgentPolicyDirectoryProtection,
        at url: URL
    ) throws {
        try fileManager.setAttributes(
            [.protectionKey: protection.fileProtectionType],
            ofItemAtPath: url.path
        )
    }

    func protection(
        at url: URL
    ) throws -> AgentPolicyDirectoryProtection? {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        // CoreSimulator can omit NSFileProtectionKey entirely even after a
        // successful NSFileProtectionComplete write. The shared helper owns
        // that simulator-only representation; device builds still accept
        // only an explicit Complete value.
        if AgentCompleteDataProtection.satisfiesPostcondition(
            attributes[.protectionKey]
        ) {
            return .complete
        }
        return nil
    }

    func setExcludedFromBackup(_ excluded: Bool, at url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try mutableURL.setResourceValues(values)
    }

    func isExcludedFromBackup(at url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            .isExcludedFromBackup == true
    }
}

private extension AgentPolicyDirectoryProtection {
    var fileProtectionType: FileProtectionType {
        switch self {
        case .complete:
            return .complete
        }
    }
}
