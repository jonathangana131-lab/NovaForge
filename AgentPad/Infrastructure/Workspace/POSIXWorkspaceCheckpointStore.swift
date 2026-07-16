import AgentDomain
import AgentPolicy
import CryptoKit
import Darwin
import Foundation

enum POSIXWorkspaceCheckpointFaultPoint: Equatable, Sendable {
    case afterSnapshotSync
    case afterManifestSyncBeforePublish
}

struct POSIXWorkspaceCheckpointFaultInjector: Sendable {
    let invoke: @Sendable (POSIXWorkspaceCheckpointFaultPoint) throws -> Void

    static let none = POSIXWorkspaceCheckpointFaultInjector { _ in }
}

struct POSIXWorkspaceCheckpointManifest: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let version: Int
    let effectKeySHA256: PolicySHA256Digest
    let workspaceID: WorkspaceID
    let workspaceRevision: String
    let operationPayloadSHA256: PolicySHA256Digest
    let workspaceWasPresent: Bool
    let workspaceRootIdentity: String
    let workspaceContainmentIdentity: String
    let workspaceDirectoryNameSHA256: PolicySHA256Digest
    let beforeStateSHA256: PolicySHA256Digest
    let entries: [POSIXWorkspaceSnapshotEntry]
}

/// Durable, content-addressed whole-workspace before-state storage.
///
/// `checkpointDirectory` must be `AgentPolicyStorePaths.checkpointDirectory`:
/// this type will only open that already-prepared directory with
/// `O_DIRECTORY|O_NOFOLLOW`; it never creates or weakens its parent boundary.
struct POSIXWorkspaceCheckpointStore:
    MutationEffectCheckpointing,
    Sendable
{
    private let roots: any AgentWorkspaceRootProviding
    private let checkpointDirectory: URL
    private let limits: POSIXWorkspaceLimits
    private let faultInjector: POSIXWorkspaceCheckpointFaultInjector

    init(
        roots: any AgentWorkspaceRootProviding,
        paths: AgentPolicyStorePaths,
        limits: POSIXWorkspaceLimits = .production,
        faultInjector: POSIXWorkspaceCheckpointFaultInjector = .none
    ) {
        self.init(
            roots: roots,
            checkpointDirectory: paths.checkpointDirectory,
            limits: limits,
            faultInjector: faultInjector
        )
    }

    init(
        roots: any AgentWorkspaceRootProviding,
        checkpointDirectory: URL,
        limits: POSIXWorkspaceLimits = .production,
        faultInjector: POSIXWorkspaceCheckpointFaultInjector = .none
    ) {
        self.roots = roots
        self.checkpointDirectory = checkpointDirectory
        self.limits = limits
        self.faultInjector = faultInjector
    }

    func checkpoint(
        _ request: MutationEffectCheckpointRequest
    ) throws -> MutationEffectCheckpointResult {
        do {
            let location = try roots.workspaceRootLocation(
                for: request.workspaceID
            )
            return try capture(
                effectKeySHA256: request.effectKeySHA256,
                workspaceID: request.workspaceID,
                workspaceRevision: request.workspaceRevision,
                operationPayloadSHA256:
                    request.operation.operationPayloadSHA256,
                permitsMissingRoot: Self.isSeed(request.operation.body),
                location: location
            )
        } catch let error as POSIXWorkspaceInfrastructureError {
            throw error
        } catch {
            throw POSIXWorkspaceInfrastructureError.persistenceFailed
        }
    }

    /// Idempotent recovery primitive. A crash during restore may leave a
    /// partially rebuilt root, but the immutable checkpoint remains published
    /// and calling this method again converges to the same verified tree.
    func restore(
        effectKeySHA256: PolicySHA256Digest,
        workspaceID: WorkspaceID,
        expected checkpoint: MutationEffectCheckpointResult
    ) throws {
        do {
            let location = try roots.workspaceRootLocation(for: workspaceID)
            let storeRoot = try POSIXWorkspaceFD.openRoot(
                at: checkpointDirectory
            )
            let finalName = Self.finalName(effectKeySHA256)
            let directory = try POSIXWorkspaceFD.openDirectory(
                parent: storeRoot.fd,
                name: finalName
            )
            let validated = try validatePublishedCheckpoint(
                directory: directory,
                expectedEffectKey: effectKeySHA256,
                expectedWorkspaceID: workspaceID,
                expectedOperationPayload: nil,
                expectedWorkspaceRevision: nil,
                expectedResult: checkpoint
            )
            let container = try POSIXWorkspaceFD.openContainer(
                at: location.containerURL
            )
            guard validated.manifest.workspaceContainmentIdentity
                    == POSIXWorkspaceFD.identityToken(container.stat),
                  validated.manifest.workspaceDirectoryNameSHA256
                    == (try Self.directoryNameDigest(location.directoryName))
            else {
                throw POSIXWorkspaceInfrastructureError.recoveryFailed
            }
            if !validated.manifest.workspaceWasPresent {
                if try POSIXWorkspaceFD.openRoot(
                    container: container,
                    name: location.directoryName
                ) != nil {
                    try POSIXWorkspaceFD.removeNode(
                        parent: container.fd,
                        name: location.directoryName
                    )
                    try POSIXWorkspaceFD.sync(container.fd)
                }
                return
            }

            guard let root = try POSIXWorkspaceFD.openRoot(
                container: container,
                name: location.directoryName
            ),
            POSIXWorkspaceFD.identityToken(root.stat)
                == validated.manifest.workspaceRootIdentity
            else {
                throw POSIXWorkspaceInfrastructureError.recoveryFailed
            }
            try POSIXWorkspaceFD.removeAllChildren(of: root.fd)
            let snapshot = try POSIXWorkspaceFD.openDirectory(
                parent: directory.fd,
                name: Self.snapshotDirectoryName
            )
            try restoreEntries(
                validated.manifest.entries,
                snapshot: snapshot,
                workspace: root
            )
            try POSIXWorkspaceFD.sync(root.fd)
        } catch let error as POSIXWorkspaceInfrastructureError {
            throw error
        } catch {
            throw POSIXWorkspaceInfrastructureError.recoveryFailed
        }
    }

    // Internal deterministic seam for tests; production callers use the
    // package-minted request above.
    func checkpointForTesting(
        effectKeySHA256: PolicySHA256Digest,
        workspaceID: WorkspaceID,
        workspaceRevision: String,
        operationPayloadSHA256: PolicySHA256Digest,
        permitsMissingRoot: Bool = false
    ) throws -> MutationEffectCheckpointResult {
        let location = try roots.workspaceRootLocation(for: workspaceID)
        return try capture(
            effectKeySHA256: effectKeySHA256,
            workspaceID: workspaceID,
            workspaceRevision: workspaceRevision,
            operationPayloadSHA256: operationPayloadSHA256,
            permitsMissingRoot: permitsMissingRoot,
            location: location
        )
    }

    private func capture(
        effectKeySHA256: PolicySHA256Digest,
        workspaceID: WorkspaceID,
        workspaceRevision: String,
        operationPayloadSHA256: PolicySHA256Digest,
        permitsMissingRoot: Bool,
        location: AgentWorkspaceRootLocation
    ) throws -> MutationEffectCheckpointResult {
        let storeRoot = try POSIXWorkspaceFD.openRoot(at: checkpointDirectory)
        let finalName = Self.finalName(effectKeySHA256)
        try removeStaleStagingDirectories(
            storeRoot: storeRoot,
            finalName: finalName
        )

        if let existing = try? POSIXWorkspaceFD.openDirectory(
            parent: storeRoot.fd,
            name: finalName
        ) {
            let validated = try validatePublishedCheckpoint(
                directory: existing,
                expectedEffectKey: effectKeySHA256,
                expectedWorkspaceID: workspaceID,
                expectedOperationPayload: operationPayloadSHA256,
                expectedWorkspaceRevision: workspaceRevision,
                expectedResult: nil
            )
            try verifyCurrentWorkspace(
                location: location,
                matches: validated.manifest
            )
            return validated.result
        }

        let stagingName = ".\(finalName).staging-\(UUID().uuidString)"
        guard stagingName.withCString({
            mkdirat(storeRoot.fd, $0, 0o700)
        }) == 0 else {
            throw POSIXWorkspaceInfrastructureError.persistenceFailed
        }
        let staging = try POSIXWorkspaceFD.openDirectory(
            parent: storeRoot.fd,
            name: stagingName
        )
        guard Self.snapshotDirectoryName.withCString({
            mkdirat(staging.fd, $0, 0o700)
        }) == 0 else {
            throw POSIXWorkspaceInfrastructureError.persistenceFailed
        }
        let snapshotDirectory = try POSIXWorkspaceFD.openDirectory(
            parent: staging.fd,
            name: Self.snapshotDirectoryName
        )

        let container = try POSIXWorkspaceFD.openContainer(
            at: location.containerURL
        )
        let root = try POSIXWorkspaceFD.openRoot(
            container: container,
            name: location.directoryName
        )
        let wasPresent = root != nil
        let entries: [POSIXWorkspaceSnapshotEntry]
        let beforeState: PolicySHA256Digest
        let rootIdentity: String
        if let root {
            let captured = try POSIXWorkspaceTree.capture(
                root: root,
                limits: limits,
                copyTo: snapshotDirectory.fd
            )
            guard fchmod(
                snapshotDirectory.fd,
                root.stat.st_mode & 0o777
            ) == 0 else {
                throw POSIXWorkspaceInfrastructureError.persistenceFailed
            }
            entries = captured.entries
            beforeState = captured.physicalSHA256
            rootIdentity = POSIXWorkspaceFD.identityToken(root.stat)
        } else {
            guard permitsMissingRoot else {
                throw POSIXWorkspaceInfrastructureError.workspaceUnavailable
            }
            entries = []
            beforeState = try POSIXWorkspaceTree.missingRootSHA256(
                container: container.stat,
                rootName: location.directoryName
            )
            rootIdentity = POSIXWorkspaceFD.missingRootIdentityToken(
                container: container.stat,
                rootName: location.directoryName
            )
        }
        guard beforeState.rawValue == workspaceRevision else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        try POSIXWorkspaceFD.sync(snapshotDirectory.fd)
        try faultInjector.invoke(.afterSnapshotSync)

        let manifest = POSIXWorkspaceCheckpointManifest(
            version: POSIXWorkspaceCheckpointManifest.schemaVersion,
            effectKeySHA256: effectKeySHA256,
            workspaceID: workspaceID,
            workspaceRevision: workspaceRevision,
            operationPayloadSHA256: operationPayloadSHA256,
            workspaceWasPresent: wasPresent,
            workspaceRootIdentity: rootIdentity,
            workspaceContainmentIdentity:
                POSIXWorkspaceFD.identityToken(container.stat),
            workspaceDirectoryNameSHA256:
                try Self.directoryNameDigest(location.directoryName),
            beforeStateSHA256: beforeState,
            entries: entries
        )
        let manifestData = try Self.encodeManifest(manifest)
        guard manifestData.count <= Self.maximumManifestBytes else {
            throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
        }
        let manifestFile = try POSIXWorkspaceFD.createRegularFile(
            parent: staging.fd,
            name: Self.manifestFileName,
            mode: 0o600
        )
        try POSIXWorkspaceFD.writeAll(manifestData, to: manifestFile.fd)
        try POSIXWorkspaceFD.sync(manifestFile.fd)
        try POSIXWorkspaceFD.sync(staging.fd)
        try faultInjector.invoke(.afterManifestSyncBeforePublish)

        let publishResult = stagingName.withCString { source in
            finalName.withCString { destination in
                renameatx_np(
                    storeRoot.fd,
                    source,
                    storeRoot.fd,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard publishResult == 0 else {
            // A concurrent identical publisher may have won. Never replace it;
            // verify it byte/content-addressedly before treating it as success.
            guard let existing = try? POSIXWorkspaceFD.openDirectory(
                parent: storeRoot.fd,
                name: finalName
            ) else {
                throw POSIXWorkspaceInfrastructureError.persistenceFailed
            }
            let validated = try validatePublishedCheckpoint(
                directory: existing,
                expectedEffectKey: effectKeySHA256,
                expectedWorkspaceID: workspaceID,
                expectedOperationPayload: operationPayloadSHA256,
                expectedWorkspaceRevision: workspaceRevision,
                expectedResult: nil
            )
            try? POSIXWorkspaceFD.removeNode(
                parent: storeRoot.fd,
                name: stagingName
            )
            return validated.result
        }
        try POSIXWorkspaceFD.sync(storeRoot.fd)
        let plan = try Self.planDigest(manifest)
        return MutationEffectCheckpointResult(
            beforeStateSHA256: beforeState,
            rollbackOrReconciliationPlanSHA256: plan
        )
    }

    private func verifyCurrentWorkspace(
        location: AgentWorkspaceRootLocation,
        matches manifest: POSIXWorkspaceCheckpointManifest
    ) throws {
        let container = try POSIXWorkspaceFD.openContainer(
            at: location.containerURL
        )
        guard manifest.workspaceContainmentIdentity
                == POSIXWorkspaceFD.identityToken(container.stat),
              manifest.workspaceDirectoryNameSHA256
                == (try Self.directoryNameDigest(location.directoryName))
        else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        if let root = try POSIXWorkspaceFD.openRoot(
            container: container,
            name: location.directoryName
        ) {
            guard manifest.workspaceWasPresent,
                  POSIXWorkspaceFD.identityToken(root.stat)
                    == manifest.workspaceRootIdentity,
                  try POSIXWorkspaceTree.capture(
                      root: root,
                      limits: limits
                  ).physicalSHA256 == manifest.beforeStateSHA256
            else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
        } else {
            guard !manifest.workspaceWasPresent,
                  try POSIXWorkspaceTree.missingRootSHA256(
                      container: container.stat,
                      rootName: location.directoryName
                  ) == manifest.beforeStateSHA256
            else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
        }
    }

    private struct ValidatedCheckpoint {
        let manifest: POSIXWorkspaceCheckpointManifest
        let result: MutationEffectCheckpointResult
    }

    private func validatePublishedCheckpoint(
        directory: POSIXWorkspaceDirectoryFD,
        expectedEffectKey: PolicySHA256Digest,
        expectedWorkspaceID: WorkspaceID,
        expectedOperationPayload: PolicySHA256Digest?,
        expectedWorkspaceRevision: String?,
        expectedResult: MutationEffectCheckpointResult?
    ) throws -> ValidatedCheckpoint {
        let manifestFile = try POSIXWorkspaceFD.openRegularFile(
            parent: directory.fd,
            name: Self.manifestFileName,
            writable: false
        )
        let data = try POSIXWorkspaceFD.readAll(
            from: manifestFile.fd,
            maximumBytes: UInt64(Self.maximumManifestBytes)
        )
        let manifest: POSIXWorkspaceCheckpointManifest
        do {
            manifest = try JSONDecoder().decode(
                POSIXWorkspaceCheckpointManifest.self,
                from: data
            )
        } catch {
            throw POSIXWorkspaceInfrastructureError.checkpointCorrupt
        }
        guard manifest.version == POSIXWorkspaceCheckpointManifest.schemaVersion,
              manifest.effectKeySHA256 == expectedEffectKey,
              manifest.workspaceID == expectedWorkspaceID,
              expectedOperationPayload.map({
                  $0 == manifest.operationPayloadSHA256
              }) ?? true,
              expectedWorkspaceRevision.map({
                  $0 == manifest.workspaceRevision
              }) ?? true,
              manifest.beforeStateSHA256.rawValue
                == manifest.workspaceRevision,
              manifest.entries.count <= limits.maximumEntryCount,
              try Self.encodeManifest(manifest) == data
        else {
            throw POSIXWorkspaceInfrastructureError.checkpointCorrupt
        }
        let plan = try Self.planDigest(manifest)
        let result = MutationEffectCheckpointResult(
            beforeStateSHA256: manifest.beforeStateSHA256,
            rollbackOrReconciliationPlanSHA256: plan
        )
        if let expectedResult, expectedResult != result {
            throw POSIXWorkspaceInfrastructureError.checkpointCorrupt
        }
        let snapshot = try POSIXWorkspaceFD.openDirectory(
            parent: directory.fd,
            name: Self.snapshotDirectoryName
        )
        try validateStoredSnapshot(snapshot, manifest: manifest)
        let allowed = Set([
            Self.manifestFileName,
            Self.snapshotDirectoryName,
        ])
        guard Set(try POSIXWorkspaceFD.listNames(directory.fd)) == allowed else {
            throw POSIXWorkspaceInfrastructureError.checkpointCorrupt
        }
        return ValidatedCheckpoint(manifest: manifest, result: result)
    }

    private func validateStoredSnapshot(
        _ snapshot: POSIXWorkspaceDirectoryFD,
        manifest: POSIXWorkspaceCheckpointManifest
    ) throws {
        if !manifest.workspaceWasPresent {
            guard manifest.entries.isEmpty,
                  try POSIXWorkspaceFD.listNames(snapshot.fd).isEmpty
            else {
                throw POSIXWorkspaceInfrastructureError.checkpointCorrupt
            }
            return
        }
        let stored = try POSIXWorkspaceTree.capture(
            root: POSIXWorkspaceRootFD(
                descriptor: snapshot.descriptor,
                stat: snapshot.stat
            ),
            limits: limits
        )
        let expectedByPath = Dictionary(
            uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) }
        )
        let storedByPath = Dictionary(
            uniqueKeysWithValues: stored.entries.map { ($0.path, $0) }
        )
        guard expectedByPath.keys == storedByPath.keys else {
            throw POSIXWorkspaceInfrastructureError.checkpointCorrupt
        }
        for (path, expected) in expectedByPath {
            guard let actual = storedByPath[path],
                  actual.kind == expected.kind,
                  actual.mode == expected.mode
            else {
                throw POSIXWorkspaceInfrastructureError.checkpointCorrupt
            }
            switch expected.kind {
            case .directory:
                guard expected.contentSHA256 == nil,
                      actual.contentSHA256 == nil
                else {
                    throw POSIXWorkspaceInfrastructureError.checkpointCorrupt
                }
            case .regularFile:
                guard actual.size == expected.size,
                      actual.contentSHA256 == expected.contentSHA256
                else {
                    throw POSIXWorkspaceInfrastructureError.checkpointCorrupt
                }
            }
        }
    }

    private func restoreEntries(
        _ entries: [POSIXWorkspaceSnapshotEntry],
        snapshot: POSIXWorkspaceDirectoryFD,
        workspace: POSIXWorkspaceRootFD
    ) throws {
        let nonRoot = entries.filter { !$0.path.isEmpty }
        let directories = nonRoot.filter { $0.kind == .directory }.sorted {
            $0.path.split(separator: "/").count
                < $1.path.split(separator: "/").count
        }
        let files = nonRoot.filter { $0.kind == .regularFile }

        for entry in directories {
            let path = try POSIXRelativePath(
                entry.path,
                allowRoot: false,
                maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
                maximumDepth: limits.maximumDepth
            )
            let parent = try POSIXWorkspaceFD.openParent(
                root: workspace,
                path: path,
                createIntermediates: true
            )
            let result = path.leaf.withCString {
                mkdirat(parent.fd, $0, mode_t(entry.mode))
            }
            guard result == 0 || errno == EEXIST else {
                throw POSIXWorkspaceInfrastructureError.recoveryFailed
            }
        }
        for entry in files {
            let path = try POSIXRelativePath(
                entry.path,
                allowRoot: false,
                maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
                maximumDepth: limits.maximumDepth
            )
            let sourceParent = try POSIXWorkspaceFD.openParent(
                root: POSIXWorkspaceRootFD(
                    descriptor: snapshot.descriptor,
                    stat: snapshot.stat
                ),
                path: path,
                createIntermediates: false
            )
            let destinationParent = try POSIXWorkspaceFD.openParent(
                root: workspace,
                path: path,
                createIntermediates: true
            )
            try POSIXWorkspaceFD.copyNode(
                sourceParent: sourceParent.fd,
                sourceName: path.leaf,
                destinationParent: destinationParent.fd,
                destinationName: path.leaf,
                limits: limits
            )
            let restored = try POSIXWorkspaceFD.openRegularFile(
                parent: destinationParent.fd,
                name: path.leaf,
                writable: false
            )
            guard fchmod(restored.fd, mode_t(entry.mode)) == 0 else {
                throw POSIXWorkspaceInfrastructureError.recoveryFailed
            }
            try setModificationTime(entry, fd: restored.fd)
        }
        for entry in directories.reversed() {
            let path = try POSIXRelativePath(
                entry.path,
                allowRoot: false,
                maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
                maximumDepth: limits.maximumDepth
            )
            let parent = try POSIXWorkspaceFD.openParent(
                root: workspace,
                path: path,
                createIntermediates: false
            )
            let directory = try POSIXWorkspaceFD.openDirectory(
                parent: parent.fd,
                name: path.leaf
            )
            guard fchmod(directory.fd, mode_t(entry.mode)) == 0 else {
                throw POSIXWorkspaceInfrastructureError.recoveryFailed
            }
            try setModificationTime(entry, fd: directory.fd)
            try POSIXWorkspaceFD.sync(directory.fd)
        }
        if let rootEntry = entries.first(where: { $0.path.isEmpty }) {
            guard fchmod(workspace.fd, mode_t(rootEntry.mode)) == 0 else {
                throw POSIXWorkspaceInfrastructureError.recoveryFailed
            }
            try setModificationTime(rootEntry, fd: workspace.fd)
        }
    }

    private func setModificationTime(
        _ entry: POSIXWorkspaceSnapshotEntry,
        fd: Int32
    ) throws {
        var times = [
            timespec(
                tv_sec: time_t(entry.modificationSeconds),
                tv_nsec: Int(entry.modificationNanoseconds)
            ),
            timespec(
                tv_sec: time_t(entry.modificationSeconds),
                tv_nsec: Int(entry.modificationNanoseconds)
            ),
        ]
        guard futimens(fd, &times) == 0 else {
            throw POSIXWorkspaceInfrastructureError.recoveryFailed
        }
    }

    private func removeStaleStagingDirectories(
        storeRoot: POSIXWorkspaceRootFD,
        finalName: String
    ) throws {
        let prefix = ".\(finalName).staging-"
        let cutoff = time(nil) - Self.stagingExpirySeconds
        for name in try POSIXWorkspaceFD.listNames(storeRoot.fd)
        where name.hasPrefix(prefix) {
            guard let metadata = try POSIXWorkspaceFD.statNoFollow(
                parent: storeRoot.fd,
                name: name
            ),
            POSIXWorkspaceFD.isDirectory(metadata),
            metadata.st_mtimespec.tv_sec <= cutoff
            else {
                continue
            }
            try POSIXWorkspaceFD.removeNode(parent: storeRoot.fd, name: name)
        }
    }

    private static func encodeManifest(
        _ manifest: POSIXWorkspaceCheckpointManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private static func planDigest(
        _ manifest: POSIXWorkspaceCheckpointManifest
    ) throws -> PolicySHA256Digest {
        try POSIXWorkspaceDigest.sha256(
            domain: "workspace-rollback-plan-v1",
            data: encodeManifest(manifest)
        )
    }

    private static func directoryNameDigest(
        _ name: String
    ) throws -> PolicySHA256Digest {
        try POSIXWorkspaceDigest.sha256(
            domain: "workspace-directory-name-v1",
            data: Data(name.utf8)
        )
    }

    private static func finalName(_ digest: PolicySHA256Digest) -> String {
        String(digest.rawValue.dropFirst("sha256:".count))
    }

    private static func isSeed(_ body: MutationEffectOperationBody) -> Bool {
        if case .seedWorkspace = body { return true }
        return false
    }

    private static let manifestFileName = "manifest.json"
    private static let snapshotDirectoryName = "snapshot"
    private static let maximumManifestBytes = 16 * 1_024 * 1_024
    private static let stagingExpirySeconds: time_t = 5 * 60
}
