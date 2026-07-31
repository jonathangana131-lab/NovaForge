import AgentDomain
@testable import AgentPolicy
import AgentTools
import Foundation
import XCTest

final class DurableApprovalSecurityTests: XCTestCase {
    private let signingKey = Data(repeating: 0x5a, count: 32)

    func testRegistrationRejectsEvaluationBoundToForeignResolverAuthority() async throws {
        let foreignResolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let policyRequest = try await AgentPolicyTestFixture.request(
            "write_file",
            arguments: .object([
                "path": .string("Sources/App.swift"),
                "contents": .string("updated"),
            ]),
            resolver: foreignResolver
        )
        let policyRevisionAuthority = try PolicyRevisionAuthority(
            configuration: RiskPolicyConfiguration()
        )
        let evaluation = await (try LayeredRiskPolicyEvaluator(
            policyRevisionAuthority: policyRevisionAuthority,
            clock: SequencePolicyClock([50]),
            resolver: foreignResolver
        )).evaluate(policyRequest)
        guard case .requiresApproval = evaluation.decision else {
            return XCTFail("write must require approval")
        }

        let trustedResolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let clock = SequencePolicyClock([100])
        let store = InMemoryDurableApprovalStore()
        let ui = try TrustedApprovalUIAuthority(
            signingKey: signingKey,
            prompt: StaticApprovalPrompt(.approved),
            clock: clock
        )
        let authority = DurableApprovalAuthority(
            store: store,
            clock: clock,
            resolver: trustedResolver,
            uiAuthority: ui,
            policyRevisionAuthority: policyRevisionAuthority
        )

        do {
            _ = try await authority.register(
                for: policyRequest,
                evaluation: evaluation,
                lifetimeMilliseconds: 1_000
            )
            XCTFail("foreign target authority must not enter approval UI/store")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .targetRevalidationFailed
            )
        }
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.states.isEmpty)
        let clockReads = await clock.readCount
        XCTAssertEqual(clockReads, 0)
    }

    func testApprovalIsSignedDurableConsumedBeforeLeaseAndFinalizedAgain() async throws {
        let context = try await makeContext(clockValues: [100, 110, 120, 130, 140])
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        let requestID = request.requestID
        let resolution = try await context.authority.resolve(
            requestID: requestID,
            for: context.policyRequest
        )
        XCTAssertEqual(resolution.decision, .approved)
        XCTAssertTrue(
            resolution.authorityID.hasPrefix("trusted-ui-hmac-sha256:")
        )

        let preliminary = try await context.authority.authorize(
            requestID: requestID,
            for: context.policyRequest
        )
        let persistedState = await context.store.state(requestID: requestID)
        let persisted = try XCTUnwrap(persistedState)
        XCTAssertEqual(persisted.request, request)
        XCTAssertEqual(persisted.resolution, resolution)
        XCTAssertEqual(persisted.consumption, preliminary.consumption)

        let effect = try await context.authority.finalizeForExecution(
            preliminary
        )
        XCTAssertEqual(effect.requestSHA256, context.policyRequest.requestSHA256)
        XCTAssertEqual(effect.authorizedAt, AgentInstant(rawValue: 140))
        guard case let .durableApproval(id, digest, recovery) = effect.source else {
            return XCTFail("expected durable approval effect source")
        }
        XCTAssertEqual(id, requestID)
        XCTAssertEqual(digest, preliminary.consumption.consumptionSHA256)
        XCTAssertFalse(recovery)
        let clockReads = await context.clock.readCount
        let resolutionCount = await context.backend.resolutionCount
        XCTAssertEqual(clockReads, 5)
        XCTAssertEqual(resolutionCount, 5)
        do {
            _ = try await context.authority.finalizeForExecution(preliminary)
            XCTFail("copied approval lease must finalize once per process")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .authorizationAlreadyFinalized
            )
        }
    }

    func testPromptReceivesExactEphemeralPreviewWhileLedgerStoresOnlyDigest() async throws {
        let context = try await makeContext(clockValues: [100, 110])
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        _ = try await context.authority.resolve(
            requestID: request.requestID,
            for: context.policyRequest
        )

        let observedContext = await context.prompt.lastContext
        let promptContext = try XCTUnwrap(observedContext)
        XCTAssertEqual(promptContext.approvalRequest, request)
        XCTAssertEqual(
            promptContext.operationPreview.previewSHA256,
            request.binding.operationPreviewSHA256
        )
        XCTAssertTrue(
            promptContext.operationPreview.exactArgumentsJSON
                .contains("updated")
        )
        XCTAssertTrue(
            promptContext.operationPreview.humanReadableChanges
                .contains(where: { $0.contains("Exact contents: updated") })
        )

        let durableSnapshot = await context.store.snapshot()
        let durableData = try JSONEncoder().encode(durableSnapshot)
        let durableJSON = String(decoding: durableData, as: UTF8.self)
        XCTAssertFalse(durableJSON.contains("updated"))
        XCTAssertTrue(durableJSON.contains(
            request.binding.operationPreviewSHA256.rawValue
        ))
    }

    func testResolveWithDifferentLiveRequestNeverPrompts() async throws {
        let context = try await makeContext(clockValues: [100])
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        let differentRequest = try await AgentPolicyTestFixture.request(
            "write_file",
            arguments: .object([
                "path": .string("Sources/App.swift"),
                "contents": .string("different payload"),
            ]),
            resolver: context.resolver
        )

        do {
            _ = try await context.authority.resolve(
                requestID: request.requestID,
                for: differentRequest
            )
            XCTFail("approval UI must be bound to the exact live request")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .bindingChanged
            )
        }
        let promptCount = await context.prompt.promptCount
        XCTAssertEqual(promptCount, 0)
    }

    func testDurableBindingMissingPreviewDigestCannotDecode() async throws {
        let context = try await makeContext(clockValues: [100])
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(request.binding)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "operationPreviewSHA256")
        let missing = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DurableApprovalBinding.self,
                from: missing
            )
        )
    }

    func testRejectedTrustedDecisionNeverMintsConsumption() async throws {
        let context = try await makeContext(
            decision: .rejected,
            clockValues: [100, 110]
        )
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        let requestID = request.requestID
        _ = try await context.authority.resolve(
            requestID: requestID,
            for: context.policyRequest
        )
        do {
            _ = try await context.authority.authorize(
                requestID: requestID,
                for: context.policyRequest
            )
            XCTFail("rejection must fail closed")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .approvalRejected
            )
        }
        let persisted = await context.store.state(requestID: requestID)
        XCTAssertNil(try XCTUnwrap(persisted).consumption)
    }

    func testCallerForgedCodableResolutionMACIsRejectedOnRecovery() async throws {
        let original = try await makeConsumedContext()
        let snapshot = await original.store.snapshot()
        let resolution = try XCTUnwrap(snapshot.states.first?.resolution)
        let replacement = resolution.decisionMAC.rawValue.hasSuffix("0")
            ? String(resolution.decisionMAC.rawValue.dropLast()) + "1"
            : String(resolution.decisionMAC.rawValue.dropLast()) + "0"
        let encoded = try JSONEncoder().encode(snapshot)
        let forgedData = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)?
                .replacingOccurrences(
                    of: resolution.decisionMAC.rawValue,
                    with: replacement
                )
                .data(using: .utf8)
        )
        let forgedSnapshot = try JSONDecoder().decode(
            DurableApprovalLedgerSnapshot.self,
            from: forgedData
        )
        let reopenedStore = try InMemoryDurableApprovalStore(
            restoring: forgedSnapshot
        )
        let reopenedClock = SequencePolicyClock([200])
        let reopenedUI = try TrustedApprovalUIAuthority(
            signingKey: signingKey,
            prompt: StaticApprovalPrompt(.approved),
            clock: reopenedClock
        )
        let authority = DurableApprovalAuthority(
            store: reopenedStore,
            clock: reopenedClock,
            resolver: original.resolver,
            uiAuthority: reopenedUI,
            policyRevisionAuthority: try PolicyRevisionAuthority(
                configuration: RiskPolicyConfiguration()
            )
        )
        do {
            _ = try await authority.recoverLease(
                requestID: original.requestID,
                for: original.policyRequest
            )
            XCTFail("forged Codable decision must not mint recovery authority")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .untrustedResolution
            )
        }
    }

    func testWrongUIAuthorityKeyCannotRecoverSignedDecision() async throws {
        let original = try await makeConsumedContext()
        let reopenedStore = try InMemoryDurableApprovalStore(
            restoring: await original.store.snapshot()
        )
        let clock = SequencePolicyClock([200])
        let wrongUI = try TrustedApprovalUIAuthority(
            signingKey: Data(repeating: 0x44, count: 32),
            prompt: StaticApprovalPrompt(.approved),
            clock: clock
        )
        let authority = DurableApprovalAuthority(
            store: reopenedStore,
            clock: clock,
            resolver: original.resolver,
            uiAuthority: wrongUI,
            policyRevisionAuthority: try PolicyRevisionAuthority(
                configuration: RiskPolicyConfiguration()
            )
        )
        do {
            _ = try await authority.recoverLease(
                requestID: original.requestID,
                for: original.policyRequest
            )
            XCTFail("wrong signing authority must be rejected")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .untrustedResolution
            )
        }
    }

    func testConcurrentAuthoritiesConsumeApprovalExactlyOnce() async throws {
        let context = try await makeContext(
            clockValues: Array(stride(from: 100, through: 300, by: 10))
        )
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        let requestID = request.requestID
        _ = try await context.authority.resolve(
            requestID: requestID,
            for: context.policyRequest
        )
        let second = DurableApprovalAuthority(
            store: context.store,
            clock: context.clock,
            resolver: context.resolver,
            uiAuthority: context.uiAuthority,
            policyRevisionAuthority: context.policyRevisionAuthority
        )

        let results = await withTaskGroup(
            of: Bool.self,
            returning: [Bool].self
        ) { group in
            for authority in [context.authority, second] {
                group.addTask {
                    do {
                        _ = try await authority.authorize(
                            requestID: requestID,
                            for: context.policyRequest
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let storedState = await context.store.state(requestID: requestID)
        let state = try XCTUnwrap(storedState)
        XCTAssertNotNil(state.consumption)
    }

    func testStalePreviewBeforeConsumeLeavesLedgerUnconsumed() async throws {
        let context = try await makeContext(clockValues: [100, 110, 120])
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        let requestID = request.requestID
        _ = try await context.authority.resolve(
            requestID: requestID,
            for: context.policyRequest
        )
        await context.backend.configure(previewSeed: "changed-after-approval")
        do {
            _ = try await context.authority.authorize(
                requestID: requestID,
                for: context.policyRequest
            )
            XCTFail("stale preview must fail")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .targetRevalidationFailed
            )
        }
        let persisted = await context.store.state(requestID: requestID)
        XCTAssertNil(try XCTUnwrap(persisted).consumption)
    }

    func testFinalApprovalEffectBoundaryDetectsTOCTOUAfterConsumption() async throws {
        let context = try await makeContext(clockValues: [100, 110, 120, 130])
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        let requestID = request.requestID
        _ = try await context.authority.resolve(
            requestID: requestID,
            for: context.policyRequest
        )
        let lease = try await context.authority.authorize(
            requestID: requestID,
            for: context.policyRequest
        )
        await context.backend.configure(workspaceRevision: "workspace-r2")
        do {
            _ = try await context.authority.finalizeForExecution(lease)
            XCTFail("consumed preliminary lease must not survive TOCTOU")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .targetRevalidationFailed
            )
        }
    }

    func testApprovalRecoveryRemintsSameDurableEffectKeyWithoutDuplicateClaim() async throws {
        let context = try await makeContext(
            clockValues: Array(stride(from: 100, through: 300, by: 10))
        )
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        let requestID = request.requestID
        _ = try await context.authority.resolve(
            requestID: requestID,
            for: context.policyRequest
        )
        let normalLease = try await context.authority.authorize(
            requestID: requestID,
            for: context.policyRequest
        )
        let normalEffect = try await context.authority.finalizeForExecution(
            normalLease
        )
        let claimStore = InMemoryToolEffectClaimStore()
        let claimAuthority = ToolEffectClaimAuthority(
            store: claimStore,
            clock: context.clock,
            resolver: context.resolver,
            policyRevisionAuthority: context.policyRevisionAuthority
        )
        let claimed = try await claimAuthority.claim(normalEffect)

        let recoveryLease = try await context.authority.recoverLease(
            requestID: requestID,
            for: context.policyRequest
        )
        let recoveryEffect = try await context.authority.finalizeForExecution(
            recoveryLease
        )
        XCTAssertEqual(
            recoveryEffect.effectKeySHA256,
            normalEffect.effectKeySHA256
        )
        XCTAssertEqual(recoveryEffect.effectKeySHA256, claimed.effectKeySHA256)
        do {
            _ = try await claimAuthority.claim(recoveryEffect)
            XCTFail("approval recovery cannot create a second durable claim")
        } catch {
            XCTAssertEqual(error as? ToolEffectClaimError, .alreadyClaimed)
        }
        let recoveredClaim = try await claimAuthority.recoverPendingClaim(
            recoveryEffect
        )
        XCTAssertTrue(recoveredClaim.isRecovery)
        XCTAssertEqual(recoveredClaim.effectKeySHA256, claimed.effectKeySHA256)
    }

    func testExpiryAfterSlowRevalidationPreventsDurableConsumption() async throws {
        let context = try await makeContext(clockValues: [100, 110, 120, 201])
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 100
        )
        let requestID = request.requestID
        _ = try await context.authority.resolve(
            requestID: requestID,
            for: context.policyRequest
        )
        do {
            _ = try await context.authority.authorize(
                requestID: requestID,
                for: context.policyRequest
            )
            XCTFail("trusted final clock must catch expiry")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .expired
            )
        }
        let persisted = await context.store.state(requestID: requestID)
        XCTAssertNil(try XCTUnwrap(persisted).consumption)
    }

    func testCrashAfterDurableConsumptionReturnsNoLeaseThenRecoversFromStore() async throws {
        let base = try await makeContext(
            clockValues: Array(stride(from: 100, through: 300, by: 10))
        )
        let disk = ApprovalDisk()
        let crashing = CrashAfterConsumptionStore(disk: disk, crash: true)
        let authority = DurableApprovalAuthority(
            store: crashing,
            clock: base.clock,
            resolver: base.resolver,
            uiAuthority: base.uiAuthority,
            policyRevisionAuthority: base.policyRevisionAuthority
        )
        let request = try await authority.register(
            for: base.policyRequest,
            evaluation: base.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        let requestID = request.requestID
        _ = try await authority.resolve(
            requestID: requestID,
            for: base.policyRequest
        )
        do {
            _ = try await authority.authorize(
                requestID: requestID,
                for: base.policyRequest
            )
            XCTFail("simulated crash after commit must return no authority")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .durableCommitFailed
            )
        }
        let diskState = await disk.state(requestID: requestID)
        XCTAssertNotNil(try XCTUnwrap(diskState).consumption)

        let reopenedStore = CrashAfterConsumptionStore(
            disk: disk,
            crash: false
        )
        let reopened = DurableApprovalAuthority(
            store: reopenedStore,
            clock: base.clock,
            resolver: base.resolver,
            uiAuthority: base.uiAuthority,
            policyRevisionAuthority: base.policyRevisionAuthority
        )
        do {
            _ = try await reopened.authorize(
                requestID: requestID,
                for: base.policyRequest
            )
            XCTFail("normal path cannot consume twice")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .replayedConsumption
            )
        }
        let recovered = try await reopened.recoverLease(
            requestID: requestID,
            for: base.policyRequest
        )
        XCTAssertTrue(recovered.isRecovery)
        let effect = try await reopened.finalizeForExecution(recovered)
        guard case let .durableApproval(_, _, recovery) = effect.source else {
            return XCTFail("expected approval source")
        }
        XCTAssertTrue(recovery)
    }

    func testTamperedConsumptionDigestCannotDecodeOrRestore() async throws {
        let original = try await makeConsumedContext()
        let storedState = await original.store.state(
            requestID: original.requestID
        )
        let state = try XCTUnwrap(storedState)
        let consumption = try XCTUnwrap(state.consumption)
        let encoded = try JSONEncoder().encode(consumption)
        let replacement = try AgentPolicyTestFixture.digest("forged")
        let data = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)?
                .replacingOccurrences(
                    of: consumption.consumptionSHA256.rawValue,
                    with: replacement.rawValue
                )
                .data(using: .utf8)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DurableApprovalConsumptionRecord.self,
                from: data
            )
        )
    }

    private func makeContext(
        decision: ApprovalDecision = .approved,
        clockValues: [Int64]
    ) async throws -> ApprovalContext {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let policyRequest = try await AgentPolicyTestFixture.request(
            "write_file",
            arguments: .object([
                "path": .string("Sources/App.swift"),
                "contents": .string("updated"),
            ]),
            resolver: resolver
        )
        let policyEvaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: SequencePolicyClock([50]),
            resolver: resolver
        )
        let policyEvaluation = await policyEvaluator.evaluate(policyRequest)
        XCTAssertEqual(
            policyEvaluation.decision,
            .requiresApproval([.explicitApprovalRequired])
        )

        let clock = SequencePolicyClock(clockValues)
        let prompt = StaticApprovalPrompt(decision)
        let uiAuthority = try TrustedApprovalUIAuthority(
            signingKey: signingKey,
            prompt: prompt,
            clock: clock
        )
        let store = InMemoryDurableApprovalStore()
        let authority = DurableApprovalAuthority(
            store: store,
            clock: clock,
            resolver: resolver,
            uiAuthority: uiAuthority,
            policyRevisionAuthority:
                policyEvaluator.policyRevisionAuthority
        )
        return ApprovalContext(
            backend: backend,
            resolver: resolver,
            policyRequest: policyRequest,
            policyEvaluation: policyEvaluation,
            policyRevisionAuthority:
                policyEvaluator.policyRevisionAuthority,
            clock: clock,
            prompt: prompt,
            uiAuthority: uiAuthority,
            store: store,
            authority: authority
        )
    }

    private func makeConsumedContext() async throws -> ConsumedApprovalContext {
        let context = try await makeContext(
            clockValues: Array(stride(from: 100, through: 300, by: 10))
        )
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.policyEvaluation,
            lifetimeMilliseconds: 1_000
        )
        let requestID = request.requestID
        _ = try await context.authority.resolve(
            requestID: requestID,
            for: context.policyRequest
        )
        _ = try await context.authority.authorize(
            requestID: requestID,
            for: context.policyRequest
        )
        return ConsumedApprovalContext(context: context, requestID: requestID)
    }
}

private struct ApprovalContext: Sendable {
    let backend: MutableResolutionBackend
    let resolver: WorkspaceTargetResolverAuthority
    let policyRequest: RiskPolicyRequest
    let policyEvaluation: RiskPolicyEvaluation
    let policyRevisionAuthority: PolicyRevisionAuthority
    let clock: SequencePolicyClock
    let prompt: StaticApprovalPrompt
    let uiAuthority: TrustedApprovalUIAuthority
    let store: InMemoryDurableApprovalStore
    let authority: DurableApprovalAuthority
}

private struct ConsumedApprovalContext: Sendable {
    let context: ApprovalContext
    let requestID: ApprovalRequestID

    var backend: MutableResolutionBackend { context.backend }
    var resolver: WorkspaceTargetResolverAuthority { context.resolver }
    var policyRequest: RiskPolicyRequest { context.policyRequest }
    var policyEvaluation: RiskPolicyEvaluation { context.policyEvaluation }
    var policyRevisionAuthority: PolicyRevisionAuthority {
        context.policyRevisionAuthority
    }
    var store: InMemoryDurableApprovalStore { context.store }
}

private actor ApprovalDisk {
    private let store = InMemoryDurableApprovalStore()

    func register(
        _ request: DurableApprovalRequest
    ) async throws -> ApprovalRegistrationDisposition {
        try await store.registerIfAbsent(request)
    }

    func resolve(
        _ resolution: DurableApprovalResolution
    ) async throws -> ApprovalResolutionDisposition {
        try await store.resolveIfPending(resolution)
    }

    func consume(
        _ record: DurableApprovalConsumptionRecord
    ) async throws -> ApprovalConsumptionDisposition {
        try await store.consumeIfUnconsumed(record)
    }

    func state(
        requestID: ApprovalRequestID
    ) async -> DurableApprovalState? {
        await store.state(requestID: requestID)
    }

    func state(
        registrationKeySHA256: SHA256Digest
    ) async -> DurableApprovalState? {
        await store.state(
            registrationKeySHA256: registrationKeySHA256
        )
    }
}

private struct CrashAfterConsumptionStore: DurableApprovalStore, Sendable {
    let disk: ApprovalDisk
    let crash: Bool

    func registerIfAbsent(
        _ request: DurableApprovalRequest
    ) async throws -> ApprovalRegistrationDisposition {
        try await disk.register(request)
    }

    func resolveIfPending(
        _ resolution: DurableApprovalResolution
    ) async throws -> ApprovalResolutionDisposition {
        try await disk.resolve(resolution)
    }

    func consumeIfUnconsumed(
        _ consumption: DurableApprovalConsumptionRecord
    ) async throws -> ApprovalConsumptionDisposition {
        let result = try await disk.consume(consumption)
        if crash, case .consumed = result { throw ApprovalSimulatedCrash() }
        return result
    }

    func state(
        requestID: ApprovalRequestID
    ) async -> DurableApprovalState? {
        await disk.state(requestID: requestID)
    }

    func state(
        registrationKeySHA256: SHA256Digest
    ) async -> DurableApprovalState? {
        await disk.state(
            registrationKeySHA256: registrationKeySHA256
        )
    }
}

private struct ApprovalSimulatedCrash: Error {}
