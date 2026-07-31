import Foundation

enum AgentEngineRunIndexStorePathError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case invalidApplicationSupportDirectory
    case symbolicLinkRejected
    case invalidEntryType
    case fileSystemFailure
    case protectionUnavailable
    case backupExclusionUnavailable
}

/// Canonical protected location for the process-safe engine run index.
struct AgentEngineRunIndexStorePaths: Equatable, Sendable {
    static let schemaVersion = "v1"

    let applicationSupportDirectory: URL
    let engineDirectory: URL
    let versionDirectory: URL
    let ledgerURL: URL

    static func prepare(
        fileManager: FileManager = .default
    ) throws -> AgentEngineRunIndexStorePaths {
        guard let requestedSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw AgentEngineRunIndexStorePathError.applicationSupportUnavailable
        }
        guard requestedSupport.isFileURL,
              requestedSupport.path.hasPrefix("/"),
              requestedSupport.standardizedFileURL.path != "/"
        else {
            throw AgentEngineRunIndexStorePathError.invalidApplicationSupportDirectory
        }

        let support = requestedSupport.standardizedFileURL
        let engine = support.appendingPathComponent(
            "AgentEngine",
            isDirectory: true
        ).standardizedFileURL
        let version = engine.appendingPathComponent(
            schemaVersion,
            isDirectory: true
        ).standardizedFileURL
        let ledger = version.appendingPathComponent(
            "run-ownership-index.ledger",
            isDirectory: false
        ).standardizedFileURL
        guard isStrictDescendant(engine, of: support),
              isStrictDescendant(version, of: engine),
              isStrictDescendant(ledger, of: version)
        else {
            throw AgentEngineRunIndexStorePathError.invalidApplicationSupportDirectory
        }

        try requireDirectory(support, fileManager: fileManager, mayCreate: false)
        try requireDirectory(engine, fileManager: fileManager, mayCreate: true)
        try requireDirectory(version, fileManager: fileManager, mayCreate: true)
        try requireSafeLedgerLocation(ledger, fileManager: fileManager)
        return AgentEngineRunIndexStorePaths(
            applicationSupportDirectory: support,
            engineDirectory: engine,
            versionDirectory: version,
            ledgerURL: ledger
        )
    }

    private static func requireDirectory(
        _ url: URL,
        fileManager: FileManager,
        mayCreate: Bool
    ) throws {
        switch try itemKind(at: url, fileManager: fileManager) {
        case .missing where mayCreate:
            do {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.complete]
                )
            } catch {
                let cocoa = error as NSError
                let isExistingEntryRace = (
                    cocoa.domain == NSCocoaErrorDomain
                        && cocoa.code == NSFileWriteFileExistsError
                ) || (
                    cocoa.domain == NSPOSIXErrorDomain
                        && cocoa.code == POSIXErrorCode.EEXIST.rawValue
                )
                guard isExistingEntryRace else {
                    throw AgentEngineRunIndexStorePathError.fileSystemFailure
                }

                // Another process can win the missing -> mkdir race. Accept
                // only the exact requested path after reinspection proves it
                // is a real directory. Symlinks and every other entry type
                // remain fail-closed, and the protection/backup checks below
                // still have to succeed before this directory is returned.
                switch try itemKind(at: url, fileManager: fileManager) {
                case .directory:
                    break
                case .symbolicLink:
                    throw AgentEngineRunIndexStorePathError.symbolicLinkRejected
                case .missing:
                    throw AgentEngineRunIndexStorePathError.fileSystemFailure
                case .regularFile, .other:
                    throw AgentEngineRunIndexStorePathError.invalidEntryType
                }
            }
        case .directory:
            break
        case .symbolicLink:
            throw AgentEngineRunIndexStorePathError.symbolicLinkRejected
        case .missing:
            throw AgentEngineRunIndexStorePathError.invalidApplicationSupportDirectory
        case .regularFile, .other:
            throw AgentEngineRunIndexStorePathError.invalidEntryType
        }

        guard try itemKind(at: url, fileManager: fileManager) == .directory else {
            throw AgentEngineRunIndexStorePathError.invalidEntryType
        }
        guard mayCreate else { return }

        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
            var mutable = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutable.setResourceValues(values)
        } catch {
            throw AgentEngineRunIndexStorePathError.fileSystemFailure
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw AgentEngineRunIndexStorePathError.fileSystemFailure
        }
        guard AgentCompleteDataProtection.satisfiesPostcondition(
            attributes[.protectionKey]
        ) else {
            throw AgentEngineRunIndexStorePathError.protectionUnavailable
        }
        do {
            guard try url.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup == true else {
                throw AgentEngineRunIndexStorePathError.backupExclusionUnavailable
            }
        } catch let error as AgentEngineRunIndexStorePathError {
            throw error
        } catch {
            throw AgentEngineRunIndexStorePathError.backupExclusionUnavailable
        }
        guard try itemKind(at: url, fileManager: fileManager) == .directory else {
            throw AgentEngineRunIndexStorePathError.invalidEntryType
        }
    }

    private static func requireSafeLedgerLocation(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        switch try itemKind(at: url, fileManager: fileManager) {
        case .missing, .regularFile:
            return
        case .symbolicLink:
            throw AgentEngineRunIndexStorePathError.symbolicLinkRejected
        case .directory, .other:
            throw AgentEngineRunIndexStorePathError.invalidEntryType
        }
    }

    private enum ItemKind: Equatable {
        case missing
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    private static func itemKind(
        at url: URL,
        fileManager: FileManager
    ) throws -> ItemKind {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory: return .directory
            case .typeRegular: return .regularFile
            case .typeSymbolicLink: return .symbolicLink
            default: return .other
            }
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile
                || error.code == .fileReadNoSuchFile
        {
            return .missing
        } catch {
            throw AgentEngineRunIndexStorePathError.fileSystemFailure
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

/// NovaForge always requests `NSFileProtectionComplete`. CoreSimulator has no
/// real locked-device data-protection state: the macOS host commonly records
/// the request as `CompleteUntilFirstUserAuthentication`, while Foundation in
/// the simulator guest can expose no protection value at all. Accept those
/// simulator-only representations so integration tests can exercise the real
/// durable composition. Device builds remain strictly fail-closed on anything
/// other than Complete.
enum AgentCompleteDataProtection {
    static func satisfiesPostcondition(_ rawValue: Any?) -> Bool {
        if (rawValue as? FileProtectionType) == .complete
            || (rawValue as? String) == FileProtectionType.complete.rawValue
        {
            return true
        }
        #if targetEnvironment(simulator)
        return rawValue == nil
            || (rawValue as? FileProtectionType)
                == .completeUntilFirstUserAuthentication
            || (rawValue as? String)
                == FileProtectionType.completeUntilFirstUserAuthentication
                    .rawValue
        #else
        return false
        #endif
    }
}
