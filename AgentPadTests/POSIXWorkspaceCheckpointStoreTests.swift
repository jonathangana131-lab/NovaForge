import AgentDomain
import AgentPolicy
import Darwin
import Foundation
import XCTest
@testable import NovaForge

final class POSIXWorkspaceCheckpointStoreTests: XCTestCase {
    func testCheckpointPublishesAtomicallyAndRestoreRebuildsCompleteTree() throws {
        let fixture = try Fixture(rootExists: true)
        try fixture.write("alpha", to: "README.md")
        try fixture.write("beta", to: "Sources/App.swift")
        XCTAssertEqual(chmod(
            fixture.root.appendingPathComponent("README.md").path,
            0o640
        ), 0)
        let store = fixture.store()
        let identifiers = try fixture.identifiers()
        let revision = try fixture.currentRevision()

        let checkpoint = try store.checkpointForTesting(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            workspaceRevision: revision,
            operationPayloadSHA256: identifiers.operation
        )
        XCTAssertEqual(checkpoint.beforeStateSHA256.rawValue, revision)
        XCTAssertTrue(fixture.finalCheckpointExists(identifiers.effect))
        XCTAssertFalse(fixture.hasCheckpointStagingDirectory())

        for name in try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.path
        ) {
            try FileManager.default.removeItem(
                at: fixture.root.appendingPathComponent(name)
            )
        }
        try fixture.write("wrong", to: "other.txt")

        try store.restore(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            expected: checkpoint
        )
        XCTAssertEqual(try fixture.read("README.md"), "alpha")
        XCTAssertEqual(try fixture.read("Sources/App.swift"), "beta")
        XCTAssertFalse(fixture.exists("other.txt"))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.root.appendingPathComponent("README.md").path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o640
        )
    }

    func testCrashBeforePublishLeavesNoFinalAndRetryCleansStaging() throws {
        let fixture = try Fixture(rootExists: true)
        try fixture.write("stable", to: "value.txt")
        let identifiers = try fixture.identifiers()
        let revision = try fixture.currentRevision()
        let crashing = fixture.store(faultInjector:
            POSIXWorkspaceCheckpointFaultInjector { point in
                if point == .afterManifestSyncBeforePublish {
                    throw FixtureError.simulatedCrash
                }
            }
        )

        XCTAssertThrowsError(try crashing.checkpointForTesting(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            workspaceRevision: revision,
            operationPayloadSHA256: identifiers.operation
        ))
        XCTAssertFalse(fixture.finalCheckpointExists(identifiers.effect))
        XCTAssertTrue(fixture.hasCheckpointStagingDirectory())
        try fixture.ageCheckpointStagingDirectories()

        let checkpoint = try fixture.store().checkpointForTesting(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            workspaceRevision: revision,
            operationPayloadSHA256: identifiers.operation
        )
        XCTAssertEqual(checkpoint.beforeStateSHA256.rawValue, revision)
        XCTAssertTrue(fixture.finalCheckpointExists(identifiers.effect))
        XCTAssertFalse(fixture.hasCheckpointStagingDirectory())
    }

    func testConcurrentPublishersConvergeOnOneExclusiveCheckpoint() throws {
        let fixture = try Fixture(rootExists: true)
        try fixture.write("stable", to: "value.txt")
        let identifiers = try fixture.identifiers()
        let revision = try fixture.currentRevision()
        let results = LockedResults()

        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            let result = Result {
                try fixture.store().checkpointForTesting(
                    effectKeySHA256: identifiers.effect,
                    workspaceID: fixture.workspaceID,
                    workspaceRevision: revision,
                    operationPayloadSHA256: identifiers.operation
                )
            }
            results.append(result)
        }

        let values = results.values
        XCTAssertEqual(values.count, 2)
        let checkpoints = try values.map { try $0.get() }
        XCTAssertEqual(checkpoints[0], checkpoints[1])
        XCTAssertTrue(fixture.finalCheckpointExists(identifiers.effect))
        XCTAssertFalse(fixture.hasCheckpointStagingDirectory())
    }

    func testPreexistingEmptyFinalDirectoryIsNeverReplaced() throws {
        let fixture = try Fixture(rootExists: true)
        try fixture.write("stable", to: "value.txt")
        let identifiers = try fixture.identifiers()
        let emptyFinal = fixture.finalCheckpointURL(identifiers.effect)
        try FileManager.default.createDirectory(
            at: emptyFinal,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try fixture.store().checkpointForTesting(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            workspaceRevision: try fixture.currentRevision(),
            operationPayloadSHA256: identifiers.operation
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: emptyFinal.path
            ),
            []
        )
    }

    func testTruncatedManifestAndTamperedSnapshotFailBeforeRecoveryMutation() throws {
        let fixture = try Fixture(rootExists: true)
        try fixture.write("original", to: "value.txt")
        let identifiers = try fixture.identifiers()
        let checkpoint = try fixture.store().checkpointForTesting(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            workspaceRevision: try fixture.currentRevision(),
            operationPayloadSHA256: identifiers.operation
        )
        try fixture.write("current", to: "marker.txt")

        let manifest = fixture.finalCheckpointURL(identifiers.effect)
            .appendingPathComponent("manifest.json")
        try Data("{".utf8).write(to: manifest)
        XCTAssertThrowsError(try fixture.store().restore(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            expected: checkpoint
        )) { error in
            XCTAssertEqual(
                error as? POSIXWorkspaceInfrastructureError,
                .checkpointCorrupt
            )
        }
        XCTAssertEqual(try fixture.read("marker.txt"), "current")

        // Recreate a fresh checkpoint under a second content address, then
        // alter the stored bytes while keeping a valid canonical manifest.
        let secondEffect = try POSIXWorkspaceDigest.sha256(
            domain: "fixture-effect-v1",
            data: Data("second".utf8)
        )
        let secondRevision = try fixture.currentRevision()
        let second = try fixture.store().checkpointForTesting(
            effectKeySHA256: secondEffect,
            workspaceID: fixture.workspaceID,
            workspaceRevision: secondRevision,
            operationPayloadSHA256: identifiers.operation
        )
        let storedValue = fixture.finalCheckpointURL(secondEffect)
            .appendingPathComponent("snapshot/value.txt")
        try Data("tampered".utf8).write(to: storedValue)
        XCTAssertThrowsError(try fixture.store().restore(
            effectKeySHA256: secondEffect,
            workspaceID: fixture.workspaceID,
            expected: second
        )) { error in
            XCTAssertEqual(
                error as? POSIXWorkspaceInfrastructureError,
                .checkpointCorrupt
            )
        }
        XCTAssertEqual(try fixture.read("marker.txt"), "current")
    }

    func testWrongRecoveryDigestAndContainerIdentityFailClosed() throws {
        let fixture = try Fixture(rootExists: true)
        try fixture.write("before", to: "value.txt")
        let identifiers = try fixture.identifiers()
        let checkpoint = try fixture.store().checkpointForTesting(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            workspaceRevision: try fixture.currentRevision(),
            operationPayloadSHA256: identifiers.operation
        )
        try fixture.write("keep", to: "marker.txt")
        let wrong = MutationEffectCheckpointResult(
            beforeStateSHA256: try POSIXWorkspaceDigest.sha256(
                domain: "wrong-v1",
                data: Data("before".utf8)
            ),
            rollbackOrReconciliationPlanSHA256:
                checkpoint.rollbackOrReconciliationPlanSHA256
        )
        XCTAssertThrowsError(try fixture.store().restore(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            expected: wrong
        ))
        XCTAssertEqual(try fixture.read("marker.txt"), "keep")

        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true
        )
        try fixture.write("new-root", to: "marker.txt")
        XCTAssertThrowsError(try fixture.store().restore(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            expected: checkpoint
        )) { error in
            XCTAssertEqual(
                error as? POSIXWorkspaceInfrastructureError,
                .recoveryFailed
            )
        }
        XCTAssertEqual(try fixture.read("marker.txt"), "new-root")

        let otherContainer = fixture.base.appendingPathComponent(
            "OtherWorkspaces",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: otherContainer,
            withIntermediateDirectories: true
        )
        let otherProvider = BoundAgentWorkspaceRootProvider(
            workspaceID: fixture.workspaceID,
            location: try AgentWorkspaceRootLocation(
                containerURL: otherContainer,
                directoryName: "Workspace"
            )
        )
        let rebound = POSIXWorkspaceCheckpointStore(
            roots: otherProvider,
            checkpointDirectory: fixture.checkpoints
        )
        XCTAssertThrowsError(try rebound.restore(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            expected: checkpoint
        )) { error in
            XCTAssertEqual(
                error as? POSIXWorkspaceInfrastructureError,
                .recoveryFailed
            )
        }
        XCTAssertEqual(try fixture.read("marker.txt"), "new-root")
    }

    func testCheckpointParentSymlinkIsRejectedWithoutWritingThroughIt() throws {
        let fixture = try Fixture(rootExists: true)
        try fixture.write("value", to: "value.txt")
        let actual = fixture.base.appendingPathComponent(
            "ActualCheckpointDirectory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: actual,
            withIntermediateDirectories: true
        )
        let symlink = fixture.base.appendingPathComponent("CheckpointLink")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: actual
        )
        let store = POSIXWorkspaceCheckpointStore(
            roots: fixture.provider,
            checkpointDirectory: symlink
        )
        let identifiers = try fixture.identifiers()

        XCTAssertThrowsError(try store.checkpointForTesting(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            workspaceRevision: try fixture.currentRevision(),
            operationPayloadSHA256: identifiers.operation
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: actual.path),
            []
        )
    }

    func testCheckpointRejectsSymlinkHardlinkAndSpecialFileWithoutFinal() throws {
        for hostile in HostileObject.allCases {
            let fixture = try Fixture(rootExists: true)
            try fixture.write("source", to: "source.txt")
            switch hostile {
            case .symlink:
                try FileManager.default.createSymbolicLink(
                    at: fixture.root.appendingPathComponent("hostile"),
                    withDestinationURL: fixture.base
                )
            case .hardlink:
                XCTAssertEqual(link(
                    fixture.root.appendingPathComponent("source.txt").path,
                    fixture.root.appendingPathComponent("hostile").path
                ), 0)
            case .special:
                XCTAssertEqual(mkfifo(
                    fixture.root.appendingPathComponent("hostile").path,
                    0o600
                ), 0)
            }
            let identifiers = try fixture.identifiers(seed: hostile.rawValue)
            XCTAssertThrowsError(try fixture.store().checkpointForTesting(
                effectKeySHA256: identifiers.effect,
                workspaceID: fixture.workspaceID,
                workspaceRevision: "sha256:" + String(repeating: "0", count: 64),
                operationPayloadSHA256: identifiers.operation
            )) { error in
                XCTAssertEqual(
                    error as? POSIXWorkspaceInfrastructureError,
                    .unsafeFilesystemObject
                )
            }
            XCTAssertFalse(fixture.finalCheckpointExists(identifiers.effect))
        }
    }

    func testMissingRootCheckpointRestoresAbsenceAfterPartialSeed() throws {
        let fixture = try Fixture(rootExists: false)
        let identifiers = try fixture.identifiers()
        let container = try POSIXWorkspaceFD.openContainer(
            at: fixture.container
        )
        let revision = try POSIXWorkspaceTree.missingRootSHA256(
            container: container.stat,
            rootName: fixture.root.lastPathComponent
        ).rawValue
        let checkpoint = try fixture.store().checkpointForTesting(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            workspaceRevision: revision,
            operationPayloadSHA256: identifiers.operation,
            permitsMissingRoot: true
        )

        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true
        )
        try fixture.write("partial", to: "README.md")
        try fixture.store().restore(
            effectKeySHA256: identifiers.effect,
            workspaceID: fixture.workspaceID,
            expected: checkpoint
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
    }
}

private extension POSIXWorkspaceCheckpointStoreTests {
    enum FixtureError: Error { case simulatedCrash }

    enum HostileObject: String, CaseIterable {
        case symlink
        case hardlink
        case special
    }

    final class LockedResults: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<MutationEffectCheckpointResult, Error>] = []

        var values: [Result<MutationEffectCheckpointResult, Error>] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func append(_ value: Result<MutationEffectCheckpointResult, Error>) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }
    }

    final class Fixture: @unchecked Sendable {
        let base: URL
        let container: URL
        let root: URL
        let checkpoints: URL
        let workspaceID = WorkspaceID()
        let provider: BoundAgentWorkspaceRootProvider

        init(rootExists: Bool) throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(
                "POSIXCheckpointTests-\(UUID().uuidString)",
                isDirectory: true
            )
            container = base.appendingPathComponent("Workspaces", isDirectory: true)
            root = container.appendingPathComponent("Workspace", isDirectory: true)
            checkpoints = base.appendingPathComponent("Checkpoints", isDirectory: true)
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true
            )
            if rootExists {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
            }
            try FileManager.default.createDirectory(
                at: checkpoints,
                withIntermediateDirectories: true
            )
            provider = BoundAgentWorkspaceRootProvider(
                workspaceID: workspaceID,
                location: try AgentWorkspaceRootLocation(
                    containerURL: container,
                    directoryName: root.lastPathComponent
                )
            )
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        func store(
            faultInjector: POSIXWorkspaceCheckpointFaultInjector = .none
        ) -> POSIXWorkspaceCheckpointStore {
            POSIXWorkspaceCheckpointStore(
                roots: provider,
                checkpointDirectory: checkpoints,
                faultInjector: faultInjector
            )
        }

        func identifiers(seed: String = "default") throws -> (
            effect: PolicySHA256Digest,
            operation: PolicySHA256Digest
        ) {
            (
                try POSIXWorkspaceDigest.sha256(
                    domain: "fixture-effect-v1",
                    data: Data(seed.utf8)
                ),
                try POSIXWorkspaceDigest.sha256(
                    domain: "fixture-operation-v1",
                    data: Data(seed.utf8)
                )
            )
        }

        func currentRevision() throws -> String {
            try POSIXWorkspaceTree.capture(
                root: POSIXWorkspaceFD.openRoot(at: root),
                limits: .production
            ).physicalSHA256.rawValue
        }

        func finalCheckpointURL(_ effect: PolicySHA256Digest) -> URL {
            checkpoints.appendingPathComponent(
                String(effect.rawValue.dropFirst("sha256:".count)),
                isDirectory: true
            )
        }

        func finalCheckpointExists(_ effect: PolicySHA256Digest) -> Bool {
            FileManager.default.fileExists(
                atPath: finalCheckpointURL(effect).path
            )
        }

        func hasCheckpointStagingDirectory() -> Bool {
            ((try? FileManager.default.contentsOfDirectory(
                atPath: checkpoints.path
            )) ?? []).contains { $0.contains(".staging-") }
        }

        func ageCheckpointStagingDirectories() throws {
            for name in try FileManager.default.contentsOfDirectory(
                atPath: checkpoints.path
            ) where name.contains(".staging-") {
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1)],
                    ofItemAtPath: checkpoints.appendingPathComponent(name).path
                )
            }
        }

        func write(_ value: String, to path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(value.utf8).write(to: url)
        }

        func read(_ path: String) throws -> String {
            String(
                decoding: try Data(
                    contentsOf: root.appendingPathComponent(path)
                ),
                as: UTF8.self
            )
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(path).path
            )
        }
    }
}
