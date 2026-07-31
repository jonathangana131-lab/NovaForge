import AgentDomain
@testable import AgentPolicy
import AgentTools
import Foundation
import XCTest

final class AuthorizationFreshnessSecurityTests: XCTestCase {
    private let signingKey = Data(repeating: 0x71, count: 32)

    func testPolicyChangeAfterEvaluationRejectsApprovalRegistration() async throws {
        let context = try await makeApprovalContext(clockValues: [100])
        try context.policyRevisionAuthority.replaceCurrentConfiguration(
            denying(context.policyRequest.invocation.tool)
        )

        do {
            _ = try await context.authority.register(
                for: context.policyRequest,
                evaluation: context.evaluation,
                lifetimeMilliseconds: 1_000
            )
            XCTFail("stale evaluation must not register an approval")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .policyChanged
            )
        }
        let snapshot = await context.store.snapshot()
        XCTAssertTrue(snapshot.states.isEmpty)
    }

    func testPolicyChangeAfterRegistrationRejectsAuthorization() async throws {
        let context = try await makeApprovalContext(
            clockValues: [100, 110, 120]
        )
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.evaluation,
            lifetimeMilliseconds: 1_000
        )
        _ = try await context.authority.resolve(
            requestID: request.requestID,
            for: context.policyRequest
        )
        try context.policyRevisionAuthority.replaceCurrentConfiguration(
            denying(context.policyRequest.invocation.tool)
        )

        do {
            _ = try await context.authority.authorize(
                requestID: request.requestID,
                for: context.policyRequest
            )
            XCTFail("registered approval must not outlive its policy revision")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .policyChanged
            )
        }
        let persisted = await context.store.state(requestID: request.requestID)
        XCTAssertNil(try XCTUnwrap(persisted).consumption)
    }

    func testPolicyChangeAfterRegistrationRejectsResolutionBeforePrompt() async throws {
        let context = try await makeApprovalContext(clockValues: [100])
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.evaluation,
            lifetimeMilliseconds: 1_000
        )
        try context.policyRevisionAuthority.replaceCurrentConfiguration(
            denying(context.policyRequest.invocation.tool)
        )

        do {
            _ = try await context.authority.resolve(
                requestID: request.requestID,
                for: context.policyRequest
            )
            XCTFail("stale policy must not reach approval UI")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .policyChanged
            )
        }
        let promptCount = await context.prompt.promptCount
        XCTAssertEqual(promptCount, 0)
    }

    func testPolicyChangeAfterLeaseRejectsFinalization() async throws {
        let context = try await makeApprovalContext(
            clockValues: [100, 110, 120, 130]
        )
        let request = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.evaluation,
            lifetimeMilliseconds: 1_000
        )
        _ = try await context.authority.resolve(
            requestID: request.requestID,
            for: context.policyRequest
        )
        let lease = try await context.authority.authorize(
            requestID: request.requestID,
            for: context.policyRequest
        )
        try context.policyRevisionAuthority.replaceCurrentConfiguration(
            denying(context.policyRequest.invocation.tool)
        )

        do {
            _ = try await context.authority.finalizeForExecution(lease)
            XCTFail("consumed lease must not outlive its policy revision")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .policyChanged
            )
        }
    }

    func testPolicyChangeAfterPermitRejectsClaimWithoutDurableInsert() async throws {
        let context = try await makeEffectContext()
        try context.policyRevisionAuthority.replaceCurrentConfiguration(
            denying(context.request.invocation.tool)
        )
        let store = InMemoryToolEffectClaimStore()
        let claims = ToolEffectClaimAuthority(
            store: store,
            clock: SequencePolicyClock([14, 15]),
            resolver: context.resolver,
            policyRevisionAuthority: context.policyRevisionAuthority
        )

        do {
            _ = try await claims.claim(context.effect)
            XCTFail("stale permit must not consume an effect key")
        } catch {
            XCTAssertEqual(error as? ToolEffectClaimError, .policyChanged)
        }
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.claims.isEmpty)
    }

    func testPolicyChangeDuringFinalClaimResolutionFailsClosed() async throws {
        let context = try await makeEffectContext()
        let changed = try denying(context.request.invocation.tool)
        let revisionAuthority = context.policyRevisionAuthority
        await context.backend.setResolutionHook { count in
            if count == 5 {
                _ = try? revisionAuthority.replaceCurrentConfiguration(changed)
            }
        }
        let store = InMemoryToolEffectClaimStore()
        let claims = ToolEffectClaimAuthority(
            store: store,
            clock: SequencePolicyClock([14, 15]),
            resolver: context.resolver,
            policyRevisionAuthority: revisionAuthority
        )

        do {
            _ = try await claims.claim(context.effect)
            XCTFail("a revision change during final resolution must mint nothing")
        } catch {
            XCTAssertEqual(error as? ToolEffectClaimError, .policyChanged)
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.claims.count, 1)
    }

    func testClaimExpiryIsRecheckedAfterSlowFinalResolver() async throws {
        let context = try await makeEffectContext()
        await context.backend.configure(delayNanoseconds: 20_000_000)
        let store = InMemoryToolEffectClaimStore()
        let claims = ToolEffectClaimAuthority(
            store: store,
            clock: SequencePolicyClock([
                14,
                context.effect.expiresAt.rawValue,
            ]),
            resolver: context.resolver,
            policyRevisionAuthority: context.policyRevisionAuthority
        )

        do {
            _ = try await claims.claim(context.effect)
            XCTFail("a slow resolver must not extend permit expiry")
        } catch {
            XCTAssertEqual(error as? ToolEffectClaimError, .expired)
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.claims.count, 1)
    }

    func testRecoveryExpiryIsRecheckedAfterSlowFinalResolver() async throws {
        let context = try await makeEffectContext()
        let store = InMemoryToolEffectClaimStore()
        let record = try ToolEffectClaimRecord.make(
            permit: context.effect,
            claimedAt: AgentInstant(rawValue: 14)
        )
        _ = try await store.commitIfAbsent(record)
        await context.backend.configure(delayNanoseconds: 20_000_000)
        let claims = ToolEffectClaimAuthority(
            store: store,
            clock: SequencePolicyClock([
                15,
                context.effect.expiresAt.rawValue,
            ]),
            resolver: context.resolver,
            policyRevisionAuthority: context.policyRevisionAuthority
        )

        do {
            _ = try await claims.recoverPendingClaim(context.effect)
            XCTFail("recovery must recheck expiry after its final resolver")
        } catch {
            XCTAssertEqual(error as? ToolEffectClaimError, .expired)
        }
    }

    func testExactRegistrationRetryReturnsOriginalIdentityAndLifetime() async throws {
        let context = try await makeApprovalContext(clockValues: [100, 999])
        let first = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.evaluation,
            lifetimeMilliseconds: 1_000
        )
        let retry = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.evaluation,
            lifetimeMilliseconds: 1_000
        )

        XCTAssertEqual(retry, first)
        XCTAssertEqual(retry.requestID, first.requestID)
        XCTAssertEqual(retry.binding.nonce, first.binding.nonce)
        XCTAssertEqual(retry.binding.issuedAt, first.binding.issuedAt)
        XCTAssertEqual(retry.binding.expiresAt, first.binding.expiresAt)
        let clockReads = await context.clock.readCount
        let snapshot = await context.store.snapshot()
        XCTAssertEqual(clockReads, 1)
        XCTAssertEqual(snapshot.states.count, 1)
    }

    func testRegistrationRetryRejectsChangedLifetimeOrBinding() async throws {
        let context = try await makeApprovalContext(clockValues: [100])
        _ = try await context.authority.register(
            for: context.policyRequest,
            evaluation: context.evaluation,
            lifetimeMilliseconds: 1_000
        )

        do {
            _ = try await context.authority.register(
                for: context.policyRequest,
                evaluation: context.evaluation,
                lifetimeMilliseconds: 1_001
            )
            XCTFail("same identity with a changed lifetime must conflict")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .bindingChanged
            )
        }

        let changed = try await changedRequestKeepingRegistrationIdentity(
            context
        )
        let changedEvaluation = await context.evaluator.evaluate(changed)
        do {
            _ = try await context.authority.register(
                for: changed,
                evaluation: changedEvaluation,
                lifetimeMilliseconds: 1_000
            )
            XCTFail("same identity with changed operation binding must conflict")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .bindingChanged
            )
        }
        let snapshot = await context.store.snapshot()
        XCTAssertEqual(snapshot.states.count, 1)
    }

    func testCrashAfterRegistrationCommitRecoversOriginalRequest() async throws {
        let context = try await makeApprovalContext(clockValues: [100, 999])
        let disk = RegistrationCrashDisk()
        let crashing = CrashAfterRegistrationStore(disk: disk, crash: true)
        let firstAuthority = DurableApprovalAuthority(
            store: crashing,
            clock: context.clock,
            resolver: context.resolver,
            uiAuthority: context.uiAuthority,
            policyRevisionAuthority: context.policyRevisionAuthority
        )
        do {
            _ = try await firstAuthority.register(
                for: context.policyRequest,
                evaluation: context.evaluation,
                lifetimeMilliseconds: 1_000
            )
            XCTFail("simulated crash after registration must return no request")
        } catch {
            XCTAssertEqual(
                error as? DurableApprovalAuthorityError,
                .durableCommitFailed
            )
        }

        let identity = try DurableApprovalRegistrationIdentity.make(
            runID: context.policyRequest.runID,
            callID: context.policyRequest.invocation.callID,
            idempotencyKey: context.policyRequest.invocation.idempotencyKey
        )
        let storedState = await disk.state(
            registrationKeySHA256: identity.keySHA256
        )
        let persisted = try XCTUnwrap(storedState)
        let reopened = DurableApprovalAuthority(
            store: CrashAfterRegistrationStore(disk: disk, crash: false),
            clock: context.clock,
            resolver: context.resolver,
            uiAuthority: context.uiAuthority,
            policyRevisionAuthority: context.policyRevisionAuthority
        )
        let recovered = try await reopened.register(
            for: context.policyRequest,
            evaluation: context.evaluation,
            lifetimeMilliseconds: 1_000
        )

        XCTAssertEqual(recovered, persisted.request)
        let clockReads = await context.clock.readCount
        let snapshot = await disk.snapshot()
        XCTAssertEqual(clockReads, 1)
        XCTAssertEqual(snapshot.states.count, 1)
    }

    func testClaimedPermitExposesExactTrustedOperationAndExpiry() async throws {
        let context = try await makeEffectContext()
        let claims = ToolEffectClaimAuthority(
            store: InMemoryToolEffectClaimStore(),
            clock: SequencePolicyClock([14, 15]),
            resolver: context.resolver,
            policyRevisionAuthority: context.policyRevisionAuthority
        )
        let claimed = try await claims.claim(context.effect)

        XCTAssertEqual(claimed.requestSHA256, context.request.requestSHA256)
        XCTAssertEqual(claimed.policySHA256, context.effect.policySHA256)
        XCTAssertEqual(claimed.tool, context.request.invocation.tool)
        XCTAssertEqual(claimed.effectClass, context.request.invocation.effectClass)
        XCTAssertEqual(
            claimed.canonicalArgumentDigest,
            context.request.invocation.canonicalArgumentDigest
        )
        XCTAssertEqual(
            claimed.operationPayloadSHA256,
            context.request.argumentSHA256
        )
        XCTAssertEqual(claimed.authorizedAt, context.effect.authorizedAt)
        XCTAssertEqual(claimed.expiresAt, context.effect.expiresAt)
        XCTAssertEqual(claimed.claimedAt, AgentInstant(rawValue: 14))
        XCTAssertEqual(claimed.effectPermit.descriptor, context.request.descriptor)
        XCTAssertEqual(claimed.effectPermit.invocation, context.request.invocation)
    }

    private func makeApprovalContext(
        clockValues: [Int64]
    ) async throws -> FreshApprovalContext {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let policyRequest = try await AgentPolicyTestFixture.request(
            "write_file",
            arguments: .object([
                "path": .string("Sources/App.swift"),
                "contents": .string("first"),
            ]),
            resolver: resolver
        )
        let policyRevisionAuthority = try PolicyRevisionAuthority(
            configuration: RiskPolicyConfiguration()
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            policyRevisionAuthority: policyRevisionAuthority,
            clock: SequencePolicyClock([50]),
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(policyRequest)
        guard case .requiresApproval = evaluation.decision else {
            throw FreshnessFixtureError.unexpectedDecision
        }
        let clock = SequencePolicyClock(clockValues)
        let prompt = StaticApprovalPrompt(.approved)
        let uiAuthority = try TrustedApprovalUIAuthority(
            signingKey: signingKey,
            prompt: prompt,
            clock: clock
        )
        let store = InMemoryDurableApprovalStore()
        return FreshApprovalContext(
            backend: backend,
            resolver: resolver,
            policyRequest: policyRequest,
            policyRevisionAuthority: policyRevisionAuthority,
            evaluator: evaluator,
            evaluation: evaluation,
            clock: clock,
            prompt: prompt,
            uiAuthority: uiAuthority,
            store: store,
            authority: DurableApprovalAuthority(
                store: store,
                clock: clock,
                resolver: resolver,
                uiAuthority: uiAuthority,
                policyRevisionAuthority: policyRevisionAuthority
            )
        )
    }

    private func makeEffectContext() async throws -> FreshEffectContext {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let policyRevisionAuthority = try PolicyRevisionAuthority(
            configuration: RiskPolicyConfiguration()
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            policyRevisionAuthority: policyRevisionAuthority,
            clock: SequencePolicyClock([10, 11, 12, 13]),
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(request)
        let effect = try await evaluator.finalizeForExecution(
            try XCTUnwrap(evaluation.executionPermit)
        )
        return FreshEffectContext(
            backend: backend,
            resolver: resolver,
            request: request,
            policyRevisionAuthority: policyRevisionAuthority,
            effect: effect
        )
    }

    private func changedRequestKeepingRegistrationIdentity(
        _ context: FreshApprovalContext
    ) async throws -> RiskPolicyRequest {
        let descriptor = context.policyRequest.descriptor
        let arguments = JSONValue.object([
            "path": .string("Sources/App.swift"),
            "contents": .string("changed"),
        ])
        let original = context.policyRequest.invocation
        let invocation = ToolInvocation(
            callID: original.callID,
            modelAttemptID: AttemptID(),
            tool: original.tool,
            arguments: arguments,
            canonicalArgumentDigest: try descriptor.canonicalArgumentDigest(
                for: arguments
            ),
            idempotencyKey: original.idempotencyKey,
            effectClass: original.effectClass,
            locality: original.locality
        )
        return try await RiskPolicyRequest.resolveAgentV2(
            runID: context.policyRequest.runID,
            projectID: context.policyRequest.projectID,
            workspaceID: context.policyRequest.workspaceID,
            sessionID: context.policyRequest.sessionID,
            backend: context.policyRequest.backend,
            descriptor: descriptor,
            invocation: invocation,
            using: context.resolver
        )
    }

    private func denying(
        _ tool: ToolIdentity
    ) throws -> RiskPolicyConfiguration {
        try RiskPolicyConfiguration(
            administrative: PolicyRestrictionSet(deniedTools: [tool])
        )
    }
}

private struct FreshApprovalContext: Sendable {
    let backend: MutableResolutionBackend
    let resolver: WorkspaceTargetResolverAuthority
    let policyRequest: RiskPolicyRequest
    let policyRevisionAuthority: PolicyRevisionAuthority
    let evaluator: LayeredRiskPolicyEvaluator
    let evaluation: RiskPolicyEvaluation
    let clock: SequencePolicyClock
    let prompt: StaticApprovalPrompt
    let uiAuthority: TrustedApprovalUIAuthority
    let store: InMemoryDurableApprovalStore
    let authority: DurableApprovalAuthority
}

private struct FreshEffectContext: Sendable {
    let backend: MutableResolutionBackend
    let resolver: WorkspaceTargetResolverAuthority
    let request: RiskPolicyRequest
    let policyRevisionAuthority: PolicyRevisionAuthority
    let effect: ToolEffectPermit
}

private enum FreshnessFixtureError: Error {
    case unexpectedDecision
}

private actor RegistrationCrashDisk {
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
        _ consumption: DurableApprovalConsumptionRecord
    ) async throws -> ApprovalConsumptionDisposition {
        try await store.consumeIfUnconsumed(consumption)
    }

    func state(requestID: ApprovalRequestID) async -> DurableApprovalState? {
        await store.state(requestID: requestID)
    }

    func state(
        registrationKeySHA256: SHA256Digest
    ) async -> DurableApprovalState? {
        await store.state(
            registrationKeySHA256: registrationKeySHA256
        )
    }

    func snapshot() async -> DurableApprovalLedgerSnapshot {
        await store.snapshot()
    }
}

private struct CrashAfterRegistrationStore: DurableApprovalStore, Sendable {
    let disk: RegistrationCrashDisk
    let crash: Bool

    func registerIfAbsent(
        _ request: DurableApprovalRequest
    ) async throws -> ApprovalRegistrationDisposition {
        let result = try await disk.register(request)
        if crash, case .registered = result {
            throw RegistrationSimulatedCrash()
        }
        return result
    }

    func resolveIfPending(
        _ resolution: DurableApprovalResolution
    ) async throws -> ApprovalResolutionDisposition {
        try await disk.resolve(resolution)
    }

    func consumeIfUnconsumed(
        _ consumption: DurableApprovalConsumptionRecord
    ) async throws -> ApprovalConsumptionDisposition {
        try await disk.consume(consumption)
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

private struct RegistrationSimulatedCrash: Error {}
