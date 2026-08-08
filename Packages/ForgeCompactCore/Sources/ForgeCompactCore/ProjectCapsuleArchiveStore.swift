import Foundation

public enum ProjectCapsuleArchiveStoreError: Error, Equatable, Sendable {
    case nonFileURL
    case directoryURL
    case archiveNotFound
    case parentDirectoryUnavailable
    case readFailed
    case decodeFailed
    case encodeFailed
    case writeFailed
    case verificationFailed
    case identityMismatch
    case historyRollback
    case divergentHistory(index: Int)
}

/// Actor-isolated file persistence for one Project Capsule archive.
///
/// Safety properties:
/// - the caller supplies the complete file URL; project/mission IDs are never interpolated into paths;
/// - decoded archives re-enter all `ProjectCapsuleArchive` domain validation;
/// - an existing archive may only be replaced by byte-equivalent history or a strict extension whose
///   existing capsules are an exact prefix;
/// - corrupt/unreadable existing state fails closed rather than being treated as an empty archive;
/// - writes use Foundation's atomic replacement and are immediately read back and compared.
///
/// One actor instance serializes access inside this process. Cross-process locking is intentionally
/// outside this core contract and must be supplied by a host if multiple processes can own one URL.
public actor ProjectCapsuleArchiveStore {
    public let fileURL: URL
    public let projectID: String
    public let missionID: String

    public init(
        fileURL: URL,
        projectID: String,
        missionID: String
    ) throws {
        guard fileURL.isFileURL else {
            throw ProjectCapsuleArchiveStoreError.nonFileURL
        }
        guard !fileURL.hasDirectoryPath else {
            throw ProjectCapsuleArchiveStoreError.directoryURL
        }

        self.fileURL = fileURL
        self.projectID = try ForgeCompactValidation.identifier(
            projectID,
            field: "archiveStore.projectID"
        )
        self.missionID = try ForgeCompactValidation.identifier(
            missionID,
            field: "archiveStore.missionID"
        )
    }

    /// Loads the archive when present. A corrupt, unreadable, or identity-mismatched file throws;
    /// only a genuinely absent path returns `nil`.
    public func loadIfPresent() throws -> ProjectCapsuleArchive? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        guard !isDirectory.boolValue else {
            throw ProjectCapsuleArchiveStoreError.readFailed
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ProjectCapsuleArchiveStoreError.readFailed
        }

        let archive: ProjectCapsuleArchive
        do {
            archive = try JSONDecoder().decode(ProjectCapsuleArchive.self, from: data)
        } catch {
            throw ProjectCapsuleArchiveStoreError.decodeFailed
        }

        guard archive.projectID == projectID,
              archive.missionID == missionID
        else {
            throw ProjectCapsuleArchiveStoreError.identityMismatch
        }

        return archive
    }

    public func load() throws -> ProjectCapsuleArchive {
        guard let archive = try loadIfPresent() else {
            throw ProjectCapsuleArchiveStoreError.archiveNotFound
        }
        return archive
    }

    /// Atomically persists an archive after proving it cannot erase or rewrite existing history.
    /// Re-saving the exact same archive is an idempotent no-op.
    public func save(_ archive: ProjectCapsuleArchive) throws {
        guard archive.projectID == projectID,
              archive.missionID == missionID
        else {
            throw ProjectCapsuleArchiveStoreError.identityMismatch
        }

        if let existing = try loadIfPresent() {
            try Self.validateMonotonicReplacement(existing: existing, incoming: archive)
            if existing == archive {
                return
            }
        }

        try ensureParentDirectoryExists()

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(archive)
        } catch {
            throw ProjectCapsuleArchiveStoreError.encodeFailed
        }

        do {
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw ProjectCapsuleArchiveStoreError.writeFailed
        }

        let verified: ProjectCapsuleArchive
        do {
            verified = try load()
        } catch {
            throw ProjectCapsuleArchiveStoreError.verificationFailed
        }
        guard verified == archive else {
            throw ProjectCapsuleArchiveStoreError.verificationFailed
        }
    }

    private func ensureParentDirectoryExists() throws {
        let parent = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ProjectCapsuleArchiveStoreError.parentDirectoryUnavailable
            }
            return
        }

        do {
            try fileManager.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProjectCapsuleArchiveStoreError.parentDirectoryUnavailable
        }
    }

    private static func validateMonotonicReplacement(
        existing: ProjectCapsuleArchive,
        incoming: ProjectCapsuleArchive
    ) throws {
        guard existing.projectID == incoming.projectID,
              existing.missionID == incoming.missionID
        else {
            throw ProjectCapsuleArchiveStoreError.identityMismatch
        }

        guard incoming.capsules.count >= existing.capsules.count else {
            throw ProjectCapsuleArchiveStoreError.historyRollback
        }

        for index in existing.capsules.indices {
            guard incoming.capsules[index] == existing.capsules[index] else {
                throw ProjectCapsuleArchiveStoreError.divergentHistory(index: index)
            }
        }
    }
}
