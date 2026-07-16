import AgentDomain
@testable import AgentPolicy
import Foundation
import XCTest

final class FileMutationEffectLifecycleStoreTests: XCTestCase {
    func testRelaunchPreservesLifecycleAndExactCAS() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let context = try await MutationEffectTestContext.make()
        let pending = try await context.pendingRecord()

        let first = try FileMutationEffectLifecycleStore(fileURL: url)
        guard case .inserted = try await first.insertPendingIfAbsent(pending)
        else { return XCTFail("expected pending insert") }

        let reopened = try FileMutationEffectLifecycleStore(fileURL: url)
        let reopenedPending = try await reopened.record(
            effectKeySHA256: pending.effectKeySHA256
        )
        XCTAssertEqual(reopenedPending, pending)
        let applied = try pending.applying(
            applicationResult(seed: "relaunch"),
            at: AgentInstant(rawValue: 31)
        )
        guard case .committed = try await reopened.compareAndTransition(
            expectedRecordSHA256: pending.recordSHA256,
            to: applied
        ) else { return XCTFail("expected application commit") }

        let reopenedAgain = try FileMutationEffectLifecycleStore(fileURL: url)
        let reopenedApplied = try await reopenedAgain.record(
            effectKeySHA256: pending.effectKeySHA256
        )
        XCTAssertEqual(reopenedApplied, applied)
    }

    func testTwoStoreActorsSerializeInsertAndTransition() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let context = try await MutationEffectTestContext.make()
        let pending = try await context.pendingRecord()
        let first = try FileMutationEffectLifecycleStore(fileURL: url)
        let second = try FileMutationEffectLifecycleStore(fileURL: url)

        async let firstInsert = first.insertPendingIfAbsent(pending)
        async let secondInsert = second.insertPendingIfAbsent(pending)
        let inserts = try await [firstInsert, secondInsert]
        XCTAssertEqual(inserts.count, 2)
        XCTAssertEqual(
            inserts.filter {
                if case .inserted = $0 { return true }
                return false
            }.count,
            1
        )

        let applied = try pending.applying(
            applicationResult(seed: "concurrent"),
            at: AgentInstant(rawValue: 31)
        )
        async let firstCAS = first.compareAndTransition(
            expectedRecordSHA256: pending.recordSHA256,
            to: applied
        )
        async let secondCAS = second.compareAndTransition(
            expectedRecordSHA256: pending.recordSHA256,
            to: applied
        )
        _ = try await [firstCAS, secondCAS]
        let durable = try await first.record(
            effectKeySHA256: pending.effectKeySHA256
        )
        XCTAssertEqual(durable, applied)
    }

    func testFaultAfterFileSyncBeforeRenameLeavesOldLedger() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let fault = OneShotFileMutationStoreFault(
            .afterFileSyncBeforeRename
        )
        let store = try FileMutationEffectLifecycleStore(
            fileURL: url,
            faultInjector: { try fault.inject($0) }
        )
        let pending = try await MutationEffectTestContext.make()
            .pendingRecord()

        do {
            _ = try await store.insertPendingIfAbsent(pending)
            XCTFail("fault must surface")
        } catch is InjectedMutationEffectFault {}

        let reopened = try FileMutationEffectLifecycleStore(fileURL: url)
        let reopenedRecord = try await reopened.record(
            effectKeySHA256: pending.effectKeySHA256
        )
        XCTAssertNil(reopenedRecord)
    }

    func testFaultAfterRenameIsReadBackAsCommitted() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let fault = OneShotFileMutationStoreFault(
            .afterRenameBeforeDirectorySync
        )
        let store = try FileMutationEffectLifecycleStore(
            fileURL: url,
            faultInjector: { try fault.inject($0) }
        )
        let pending = try await MutationEffectTestContext.make()
            .pendingRecord()

        do {
            _ = try await store.insertPendingIfAbsent(pending)
            XCTFail("fault must surface")
        } catch is InjectedMutationEffectFault {}

        let reopened = try FileMutationEffectLifecycleStore(fileURL: url)
        let reopenedRecord = try await reopened.record(
            effectKeySHA256: pending.effectKeySHA256
        )
        XCTAssertEqual(reopenedRecord, pending)
    }

    func testPostInitLedgerSymlinkIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let backup = directory.appendingPathComponent("ledger-backup.json")
        let store = try FileMutationEffectLifecycleStore(fileURL: url)
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createSymbolicLink(
            atPath: url.path,
            withDestinationPath: backup.path
        )

        await assertFileStoreError(.invalidFileIdentity) {
            _ = try await store.snapshot()
        }
    }

    func testPostInitHardLinkIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let backup = directory.appendingPathComponent("ledger-backup.json")
        let store = try FileMutationEffectLifecycleStore(fileURL: url)
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.linkItem(at: backup, to: url)

        await assertFileStoreError(.invalidFileIdentity) {
            _ = try await store.snapshot()
        }
    }

    func testPostInitLockReplacementIsRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let lockURL = directory.appendingPathComponent(
            ".mutation-ledger.json.mutation-effect.lock"
        )
        let backup = directory.appendingPathComponent("lock-backup")
        let store = try FileMutationEffectLifecycleStore(fileURL: url)
        try FileManager.default.moveItem(at: lockURL, to: backup)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: lockURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ))

        await assertFileStoreError(.invalidFileIdentity) {
            _ = try await store.snapshot()
        }
    }

    func testParentDirectoryReplacementIsRejected() async throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("authority")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let moved = parent.appendingPathComponent("authority-moved")
        let store = try FileMutationEffectLifecycleStore(fileURL: url)
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        await assertFileStoreError(.invalidFileIdentity) {
            _ = try await store.snapshot()
        }
    }

    func testStrictSchemaRejectsMissingSnapshotAndUnsupportedVersion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingURL = directory.appendingPathComponent("missing.json")
        _ = try FileMutationEffectLifecycleStore(fileURL: missingURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: missingURL)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "snapshot")
        try overwritePreservingIdentity(
            JSONSerialization.data(withJSONObject: object),
            at: missingURL
        )
        XCTAssertThrowsError(
            try FileMutationEffectLifecycleStore(fileURL: missingURL)
        )

        let versionURL = directory.appendingPathComponent("version.json")
        _ = try FileMutationEffectLifecycleStore(fileURL: versionURL)
        var versionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: versionURL)
            ) as? [String: Any]
        )
        versionObject["formatVersion"] = 7
        try overwritePreservingIdentity(
            JSONSerialization.data(withJSONObject: versionObject),
            at: versionURL
        )
        XCTAssertThrowsError(
            try FileMutationEffectLifecycleStore(fileURL: versionURL)
        ) { error in
            XCTAssertEqual(
                error as? FileMutationEffectLifecycleStoreError,
                .unsupportedVersion(7)
            )
        }
    }

    func testGenerationRollbackIsRejectedWithinStoreLifetime() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let firstContext = try await MutationEffectTestContext.make(
            idempotencyKey: "first"
        )
        let secondContext = try await MutationEffectTestContext.make(
            idempotencyKey: "second"
        )
        let first = try await firstContext.pendingRecord()
        let second = try await secondContext.pendingRecord()
        let store = try FileMutationEffectLifecycleStore(fileURL: url)
        _ = try await store.insertPendingIfAbsent(first)
        let olderSnapshot = try Data(contentsOf: url)
        _ = try await store.insertPendingIfAbsent(second)

        try overwritePreservingIdentity(olderSnapshot, at: url)
        await assertFileStoreError(.generationRollback) {
            _ = try await store.snapshot()
        }
    }

    func testInitializedLedgerRemovalFailsClosedOnRelaunch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        _ = try FileMutationEffectLifecycleStore(fileURL: url)
        try FileManager.default.removeItem(at: url)

        XCTAssertThrowsError(
            try FileMutationEffectLifecycleStore(fileURL: url)
        ) { error in
            XCTAssertEqual(
                error as? FileMutationEffectLifecycleStoreError,
                .corruptEnvelope
            )
        }
    }

    func testSeparateProcessLockContentionTimesOutBoundedly() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutation-ledger.json")
        let store = try FileMutationEffectLifecycleStore(
            fileURL: url,
            lockTimeoutMilliseconds: 50
        )
        let lockURL = directory.appendingPathComponent(
            ".mutation-ledger.json.mutation-effect.lock"
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f,fcntl.LOCK_EX); print('locked',flush=True); time.sleep(5)",
            lockURL.path,
        ]
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let signal = output.fileHandleForReading.availableData
        XCTAssertEqual(String(data: signal, encoding: .utf8), "locked\n")

        let started = Date()
        await assertFileStoreError(.lockUnavailable) {
            _ = try await store.snapshot()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    private func applicationResult(
        seed: String
    ) throws -> MutationEffectApplicationResult {
        try MutationEffectApplicationResult(
            resultSHA256: AgentPolicyTestFixture.digest("result-\(seed)"),
            output: mutationEffectTestOutput(),
            evidence: [
                try MutationEffectEvidenceFact(
                    kind: .workspaceAfter,
                    digest: AgentPolicyTestFixture.digest("after-\(seed)")
                ),
            ]
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "novaforge-mutation-ledger-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func overwritePreservingIdentity(
        _ data: Data,
        at url: URL
    ) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    }

    private func assertFileStoreError(
        _ expected: FileMutationEffectLifecycleStoreError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(
                error as? FileMutationEffectLifecycleStoreError,
                expected
            )
        }
    }
}
