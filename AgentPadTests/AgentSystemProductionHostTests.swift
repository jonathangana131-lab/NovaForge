import AgentDomain
import Foundation
import SwiftData
import XCTest
@testable import NovaForge

@MainActor
final class AgentSystemProductionHostTests: XCTestCase {
    func testConcurrentSameContainerCallersJoinExactlyOneOrderedBootstrap()
        async throws
    {
        let container = try makeContainer()
        let recorder = HostRecorder()
        let gate = HostGate()
        let runIDs = [runID(1), runID(2)]
        let compositionID = uuid(100)
        let host = makeHost(
            recorder: recorder,
            compositionID: compositionID,
            preparedRunIDs: runIDs,
            recoveredRunIDs: runIDs,
            installGate: gate
        )

        let first = Task { @MainActor in
            try await host.bootstrap(container: container)
        }
        try await waitUntil { recorder.installCount == 1 }
        let second = Task { @MainActor in
            try await host.bootstrap(container: container)
        }
        await Task.yield()

        XCTAssertEqual(host.status.phase, .bootstrapping)
        XCTAssertEqual(host.revision, 1)
        XCTAssertEqual(recorder.events, ["make", "install"])

        await gate.open()
        let firstReport = try await first.value
        let secondReport = try await second.value

        XCTAssertEqual(firstReport, secondReport)
        XCTAssertEqual(firstReport.preparedRunCount, 2)
        XCTAssertEqual(firstReport.recoveredRunCount, 2)
        XCTAssertEqual(recorder.makeCount, 1)
        XCTAssertEqual(recorder.installCount, 1)
        XCTAssertEqual(recorder.recoverCount, 1)
        XCTAssertEqual(recorder.events, ["make", "install", "recover"])
        XCTAssertEqual(host.status.phase, .ready)
        XCTAssertEqual(host.status.preparedRunCount, 2)
        XCTAssertEqual(host.status.recoveredRunCount, 2)
        XCTAssertNil(host.userFacingFailure)
        XCTAssertEqual(host.revision, 2)

        _ = try await host.bootstrap(container: container)
        XCTAssertEqual(recorder.makeCount, 1)
        XCTAssertEqual(recorder.installCount, 1)
        XCTAssertEqual(recorder.recoverCount, 1)
        XCTAssertEqual(host.revision, 2)
    }

    func testDifferentContainerFailsClosedWithoutPoisoningActiveAuthority()
        async throws
    {
        let activeContainer = try makeContainer()
        let foreignContainer = try makeContainer()
        let recorder = HostRecorder()
        let gate = HostGate()
        let host = makeHost(
            recorder: recorder,
            compositionID: uuid(200),
            preparedRunIDs: [],
            recoveredRunIDs: [],
            installGate: gate
        )
        let active = Task { @MainActor in
            try await host.bootstrap(container: activeContainer)
        }
        try await waitUntil { recorder.installCount == 1 }

        await assertFailure(.containerIdentityConflict) {
            try await host.bootstrap(container: foreignContainer)
        }
        XCTAssertEqual(host.status.phase, .bootstrapping)
        XCTAssertNil(host.status.failure)
        XCTAssertEqual(host.revision, 1)
        XCTAssertEqual(recorder.makeCount, 1)

        await gate.open()
        _ = try await active.value
        await assertFailure(.containerIdentityConflict) {
            try await host.bootstrap(container: foreignContainer)
        }
        XCTAssertEqual(host.status.phase, .ready)
        XCTAssertEqual(host.revision, 2)
        XCTAssertEqual(recorder.makeCount, 1)
        XCTAssertEqual(recorder.installCount, 1)
        XCTAssertEqual(recorder.recoverCount, 1)
    }

    func testRawCompositionFailureIsSanitizedAndNeverRetried() async throws {
        let container = try makeContainer()
        let recorder = HostRecorder()
        let secret = "sk-hostile-secret /Users/private/workspace"
        let dependencies = AgentSystemProductionHostDependencies(
            makeComposition: { _ in
                recorder.makeCount += 1
                throw HostileHostError(detail: secret)
            },
            installAndReconcile: { _ in
                recorder.installCount += 1
                throw HostileHostError(detail: secret)
            },
            recoverPreparedAcceptedRunIDs: {
                recorder.recoverCount += 1
                throw HostileHostError(detail: secret)
            }
        )
        let host = AgentSystemProductionHost(dependencies: dependencies)

        await assertFailure(.compositionUnavailable) {
            try await host.bootstrap(container: container)
        }
        XCTAssertEqual(host.status.phase, .failed)
        XCTAssertEqual(host.status.failure, .compositionUnavailable)
        XCTAssertEqual(host.revision, 2)
        let message = try XCTUnwrap(host.userFacingFailure)
        XCTAssertEqual(
            AgentSystemProductionHostFailure
                .compositionUnavailable.localizedDescription,
            message
        )
        XCTAssertFalse(message.contains("sk-"))
        XCTAssertFalse(message.contains("/Users"))
        XCTAssertFalse(message.contains("workspace"))

        await assertFailure(.compositionUnavailable) {
            try await host.bootstrap(container: container)
        }
        XCTAssertEqual(recorder.makeCount, 1)
        XCTAssertEqual(recorder.installCount, 0)
        XCTAssertEqual(recorder.recoverCount, 0)
        XCTAssertEqual(host.revision, 2)
    }

    func testRecoveryMustReturnExactPreparedFIFOAndCompositionIsRetained()
        async throws
    {
        let container = try makeContainer()
        let recorder = HostRecorder()
        let weakBox = HostWeakBox()
        let prepared = [runID(11), runID(12)]
        let compositionID = uuid(300)
        let dependencies = AgentSystemProductionHostDependencies(
            makeComposition: { _ in
                recorder.record("make")
                let authority = HostLifetimeAuthority()
                weakBox.value = authority
                return AgentSystemProductionComposition(
                    id: compositionID,
                    engineFactory: .unavailable,
                    recoveryQueuePreparer: authority
                )
            },
            installAndReconcile: { composition in
                recorder.record("install")
                return AgentSystemStartupReport(
                    compositionID: composition.id,
                    recoveryFIFO: prepared
                )
            },
            recoverPreparedAcceptedRunIDs: {
                recorder.record("recover")
                return Array(prepared.reversed())
            }
        )
        let host = AgentSystemProductionHost(dependencies: dependencies)

        await assertFailure(.acceptedRunRecoveryFailed) {
            try await host.bootstrap(container: container)
        }
        XCTAssertEqual(recorder.events, ["make", "install", "recover"])
        XCTAssertEqual(host.status.phase, .failed)
        XCTAssertEqual(host.status.failure, .acceptedRunRecoveryFailed)
        XCTAssertNotNil(weakBox.value)

        await assertFailure(.acceptedRunRecoveryFailed) {
            try await host.bootstrap(container: container)
        }
        XCTAssertEqual(recorder.makeCount, 1)
        XCTAssertEqual(recorder.installCount, 1)
        XCTAssertEqual(recorder.recoverCount, 1)
        XCTAssertNotNil(weakBox.value)
    }

    func testInstallAndRecoveryErrorsRemainStageBoundedAndSanitized()
        async throws
    {
        let secret = "sk-stage-secret /private/provider/cache"
        let installRecorder = HostRecorder()
        let installCompositionID = uuid(350)
        let installHost = AgentSystemProductionHost(
            dependencies: AgentSystemProductionHostDependencies(
                makeComposition: { _ in
                    installRecorder.record("make")
                    return AgentSystemProductionComposition(
                        id: installCompositionID,
                        engineFactory: .unavailable,
                        recoveryQueuePreparer: HostLifetimeAuthority()
                    )
                },
                installAndReconcile: { _ in
                    installRecorder.record("install")
                    throw HostileHostError(detail: secret)
                },
                recoverPreparedAcceptedRunIDs: {
                    installRecorder.record("recover")
                    return []
                }
            )
        )

        await assertFailure(.startupReconciliationFailed) {
            try await installHost.bootstrap(container: try self.makeContainer())
        }
        XCTAssertEqual(installRecorder.events, ["make", "install"])
        assertSanitized(installHost.userFacingFailure, secret: secret)

        let recoveryRecorder = HostRecorder()
        let recoveryCompositionID = uuid(351)
        let recoveryHost = AgentSystemProductionHost(
            dependencies: AgentSystemProductionHostDependencies(
                makeComposition: { _ in
                    recoveryRecorder.record("make")
                    return AgentSystemProductionComposition(
                        id: recoveryCompositionID,
                        engineFactory: .unavailable,
                        recoveryQueuePreparer: HostLifetimeAuthority()
                    )
                },
                installAndReconcile: { composition in
                    recoveryRecorder.record("install")
                    return AgentSystemStartupReport(
                        compositionID: composition.id,
                        recoveryFIFO: []
                    )
                },
                recoverPreparedAcceptedRunIDs: {
                    recoveryRecorder.record("recover")
                    throw HostileHostError(detail: secret)
                }
            )
        )

        await assertFailure(.acceptedRunRecoveryFailed) {
            try await recoveryHost.bootstrap(container: try self.makeContainer())
        }
        XCTAssertEqual(
            recoveryRecorder.events,
            ["make", "install", "recover"]
        )
        assertSanitized(recoveryHost.userFacingFailure, secret: secret)
    }

    func testRevisionSaturatesInsteadOfWrapping() async throws {
        let container = try makeContainer()
        let recorder = HostRecorder()
        let host = makeHost(
            recorder: recorder,
            compositionID: uuid(400),
            preparedRunIDs: [],
            recoveredRunIDs: [],
            initialRevision: .max
        )

        _ = try await host.bootstrap(container: container)
        XCTAssertEqual(host.status.phase, .ready)
        XCTAssertEqual(host.revision, .max)
    }

    private func makeHost(
        recorder: HostRecorder,
        compositionID: UUID,
        preparedRunIDs: [RunID],
        recoveredRunIDs: [RunID],
        installGate: HostGate? = nil,
        initialRevision: UInt64 = 0
    ) -> AgentSystemProductionHost {
        let dependencies = AgentSystemProductionHostDependencies(
            makeComposition: { _ in
                recorder.record("make")
                return AgentSystemProductionComposition(
                    id: compositionID,
                    engineFactory: .unavailable,
                    recoveryQueuePreparer: HostLifetimeAuthority()
                )
            },
            installAndReconcile: { composition in
                recorder.record("install")
                if let installGate { await installGate.wait() }
                return AgentSystemStartupReport(
                    compositionID: composition.id,
                    recoveryFIFO: preparedRunIDs
                )
            },
            recoverPreparedAcceptedRunIDs: {
                recorder.record("recover")
                return recoveredRunIDs
            }
        )
        return AgentSystemProductionHost(
            dependencies: dependencies,
            initialRevision: initialRevision
        )
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV4.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func runID(_ value: UInt32) -> RunID {
        RunID(rawValue: uuid(value))
    }

    private func uuid(_ value: UInt32) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0,
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ))
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for deterministic host condition")
        throw HostWaitError.timedOut
    }

    private func assertFailure(
        _ expected: AgentSystemProductionHostFailure,
        operation: @escaping @MainActor () async throws -> Any
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected production host failure: \(expected)")
        } catch {
            XCTAssertEqual(
                error as? AgentSystemProductionHostFailure,
                expected
            )
        }
    }

    private func assertSanitized(_ message: String?, secret: String) {
        guard let message else {
            XCTFail("Expected a fixed user-facing failure")
            return
        }
        XCTAssertFalse(message.contains(secret))
        XCTAssertFalse(message.contains("sk-"))
        XCTAssertFalse(message.contains("/private"))
        XCTAssertLessThan(message.utf8.count, 160)
    }
}

@MainActor
private final class HostRecorder {
    var makeCount = 0
    var installCount = 0
    var recoverCount = 0
    var events: [String] = []

    func record(_ event: String) {
        events.append(event)
        switch event {
        case "make": makeCount += 1
        case "install": installCount += 1
        case "recover": recoverCount += 1
        default: break
        }
    }
}

private actor HostGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

private final class HostLifetimeAuthority:
    AgentRecoveryQueuePreparing,
    @unchecked Sendable
{
    func prepareRecoveryQueue() async throws -> [RunID] { [] }
}

@MainActor
private final class HostWeakBox {
    weak var value: HostLifetimeAuthority?
}

private struct HostileHostError: LocalizedError, Sendable {
    let detail: String
    var errorDescription: String? { detail }
}

private enum HostWaitError: Error {
    case timedOut
}
