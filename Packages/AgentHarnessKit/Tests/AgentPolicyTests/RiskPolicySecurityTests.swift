import AgentDomain
@testable import AgentPolicy
import AgentTools
import Foundation
import XCTest

final class RiskPolicySecurityTests: XCTestCase {
    func testWindowsRootedBackslashPathIsRejectedAfterSeparatorNormalization() {
        XCTAssertThrowsError(
            try NormalizedToolTarget(
                path: "\\private\\secret.txt",
                access: .read
            )
        ) { error in
            XCTAssertEqual(
                error as? NormalizedToolTargetError,
                .absolutePath
            )
        }
    }

    func testCaseCollidingPolicyPrefixesAreRejectedCanonically() throws {
        XCTAssertThrowsError(
            try UserPolicyRestrictions(
                allowedTargetPrefixes: ["Sources", "sources"]
            )
        ) { error in
            XCTAssertEqual(
                error as? NormalizedToolTargetError,
                .ambiguousCaseCollision("Sources", "sources")
            )
        }

        let descriptor = try AgentPolicyTestFixture.descriptor("read_file")
        XCTAssertThrowsError(
            try PolicyGrant(
                grantID: "ambiguous-prefixes",
                scope: .session(sessionID: "session"),
                tool: descriptor.identity,
                targetPrefixes: ["Private", "private"],
                expiresAt: AgentInstant(rawValue: 10_000)
            )
        ) { error in
            XCTAssertEqual(
                error as? NormalizedToolTargetError,
                .ambiguousCaseCollision("Private", "private")
            )
        }
    }

    func testPrefixAuthorizationDoesNotCaseFoldWithoutFilesystemProof() throws {
        let target = try NormalizedToolTarget(
            path: "Sources/App.swift",
            access: .read
        )
        XCTAssertTrue(target.isWithin(prefix: "Sources"))
        XCTAssertFalse(target.isWithin(prefix: "sources"))
        XCTAssertTrue(target.isWithinDeniedPrefix("sources"))
    }

    func testControlCharacterInIdempotencyKeyFailsBeforeResolution() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let (descriptor, original) = try AgentPolicyTestFixture.invocation(
            "read_file",
            arguments: .object(["path": .string("a.txt")])
        )
        let invocation = ToolInvocation(
            callID: original.callID,
            modelAttemptID: original.modelAttemptID,
            tool: original.tool,
            arguments: original.arguments,
            canonicalArgumentDigest: original.canonicalArgumentDigest,
            idempotencyKey: "operation\u{0}spoof",
            effectClass: original.effectClass,
            locality: original.locality
        )

        do {
            _ = try await RiskPolicyRequest.resolveAgentV2(
                runID: RunID(),
                projectID: nil,
                workspaceID: WorkspaceID(),
                sessionID: nil,
                backend: .onDevice,
                descriptor: descriptor,
                invocation: invocation,
                using: resolver
            )
            XCTFail("control characters must not enter durable operation keys")
        } catch {
            XCTAssertEqual(
                error as? RiskPolicyRequestError,
                .invalidIdempotencyKey
            )
        }
        let resolutionCount = await backend.resolutionCount
        XCTAssertEqual(resolutionCount, 0)
    }

    func testUnicodeFormatCharactersFailClosedInPathsAndOperationKeys() async throws {
        for scalar in ["\u{202E}", "\u{2066}", "\u{200B}"] {
            XCTAssertThrowsError(
                try NormalizedToolTarget(
                    path: "Sources/\(scalar)spoof.swift",
                    access: .write
                )
            ) { error in
                XCTAssertEqual(
                    error as? NormalizedToolTargetError,
                    .controlCharacter
                )
            }
            XCTAssertThrowsError(try ApprovalNonce("nonce\(scalar)spoof")) {
                error in
                XCTAssertEqual(
                    error as? ApprovalNonceValidationError,
                    .invalid
                )
            }
        }

        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let (descriptor, original) = try AgentPolicyTestFixture.invocation(
            "read_file",
            arguments: .object(["path": .string("a.txt")])
        )
        for scalar in ["\u{202E}", "\u{2066}", "\u{200B}"] {
            let invocation = ToolInvocation(
                callID: original.callID,
                modelAttemptID: original.modelAttemptID,
                tool: original.tool,
                arguments: original.arguments,
                canonicalArgumentDigest: original.canonicalArgumentDigest,
                idempotencyKey: "operation\(scalar)spoof",
                effectClass: original.effectClass,
                locality: original.locality
            )
            do {
                _ = try await RiskPolicyRequest.resolveAgentV2(
                    runID: RunID(),
                    projectID: nil,
                    workspaceID: WorkspaceID(),
                    sessionID: nil,
                    backend: .onDevice,
                    descriptor: descriptor,
                    invocation: invocation,
                    using: resolver
                )
                XCTFail("format controls must not enter durable operation keys")
            } catch {
                XCTAssertEqual(
                    error as? RiskPolicyRequestError,
                    .invalidIdempotencyKey
                )
            }
        }
        let resolutionCount = await backend.resolutionCount
        XCTAssertEqual(resolutionCount, 0)
    }

    func testAliasedMoveTargetsResolvingToSameObjectFailClosed() async throws {
        let backend = MutableResolutionBackend()
        await backend.configure(resolvedPathOverride: "actual/shared.txt")
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)

        do {
            _ = try await AgentPolicyTestFixture.request(
                "move_path",
                arguments: .object([
                    "from": .string("Alias/source.txt"),
                    "to": .string("Alias/destination.txt"),
                ]),
                resolver: resolver
            )
            XCTFail("two logical targets must not alias one resolved object")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceTargetAuthorityError,
                .resolvedObjectCollision
            )
        }
    }

    func testMultiplyLinkedRegularFileEvidenceFailsClosed() async throws {
        let backend = MutableResolutionBackend()
        await backend.configure(objectLinkCount: 2)
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)

        do {
            _ = try await AgentPolicyTestFixture.request(
                "write_file",
                arguments: .object([
                    "path": .string("Sources/shared.txt"),
                    "contents": .string("replacement"),
                ]),
                resolver: resolver
            )
            XCTFail("a mutable hardlink alias must never become authority")
        } catch {
            XCTAssertEqual(
                error as? ResolvedToolTargetValidationError,
                .multiplyLinkedRegularFile
            )
        }
    }

    func testDistinctPathsWithSameOpenedObjectIdentityFailClosed() async throws {
        let backend = MutableResolutionBackend()
        await backend.configure(objectInodeOverride: 42)
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)

        do {
            _ = try await AgentPolicyTestFixture.request(
                "move_path",
                arguments: .object([
                    "from": .string("Sources/source.txt"),
                    "to": .string("Archive/destination.txt"),
                ]),
                resolver: resolver
            )
            XCTFail("distinct spellings of one inode must be rejected")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceTargetAuthorityError,
                .resolvedObjectCollision
            )
        }
    }

    func testDistinctPathsWithSameContainmentIdentityFailClosed() async throws {
        let backend = MutableResolutionBackend()
        await backend.configure(containmentIdentityOverride: "same-parent-chain")
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)

        do {
            _ = try await AgentPolicyTestFixture.request(
                "move_path",
                arguments: .object([
                    "from": .string("Sources/source.txt"),
                    "to": .string("Archive/destination.txt"),
                ]),
                resolver: resolver
            )
            XCTFail("distinct targets must not share containment evidence")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceTargetAuthorityError,
                .resolvedObjectCollision
            )
        }
    }

    func testPolicyScopesTrustedResolvedPathInsteadOfCallerSpelling() async throws {
        let backend = MutableResolutionBackend()
        await backend.configure(resolvedPathOverride: "Private/secret.txt")
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("Alias/public.txt")]),
            resolver: resolver
        )
        XCTAssertEqual(request.logicalTargets.map(\.path), ["Alias/public.txt"])
        XCTAssertEqual(request.resolvedTargets.map(\.path), ["Private/secret.txt"])

        let configuration = try RiskPolicyConfiguration(
            user: UserPolicyRestrictions(deniedTargetPrefixes: ["Private"])
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: configuration,
            clock: SequencePolicyClock([10]),
            resolver: resolver
        )
        let result = await evaluator.evaluate(request)
        XCTAssertEqual(
            result.decision,
            .deny([.targetExplicitlyDenied("Private/secret.txt")])
        )
        XCTAssertNil(result.executionPermit)
    }

    func testCommandTargetsComeOnlyFromTrustedParserBackend() async throws {
        let backend = MutableResolutionBackend()
        await backend.configure(commandTargets: [
            try NormalizedToolTarget(path: "Secrets", access: .write),
        ])
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "run_command",
            arguments: .object(["command": .string("allowed-tool --benign-looking")]),
            resolver: resolver
        )
        XCTAssertEqual(request.logicalTargets.map(\.path), ["Secrets"])

        let grant = try PolicyGrant(
            grantID: "command-grant",
            scope: .session(sessionID: "session"),
            tool: request.invocation.tool,
            targetPrefixes: ["Public"],
            expiresAt: AgentInstant(rawValue: 10_000)
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(grants: [grant]),
            clock: SequencePolicyClock([10]),
            resolver: resolver
        )
        let result = await evaluator.evaluate(request)
        XCTAssertEqual(
            result.decision,
            .requiresApproval([.explicitApprovalRequired])
        )
        XCTAssertNil(result.executionPermit)
    }

    func testMatchingReusableGrantCannotBecomeBroadCommandAuthority() async throws {
        let backend = MutableResolutionBackend()
        await backend.configure(
            resolvedPathOverride: "Sources",
            commandTargets: [
                try NormalizedToolTarget(
                    path: "Alias/Sources",
                    access: .write
                ),
            ]
        )
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let descriptor = try AgentPolicyTestFixture.descriptor("run_command")
        let grant = try PolicyGrant(
            grantID: "overbroad-command-grant",
            scope: .session(sessionID: "session"),
            tool: descriptor.identity,
            targetPrefixes: ["Sources"],
            expiresAt: AgentInstant(rawValue: 10_000)
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(grants: [grant]),
            clock: SequencePolicyClock([10, 11]),
            resolver: resolver
        )

        for command in [
            "allowed-tool Alias/Sources",
            "different-tool --different-argv Alias/Sources",
        ] {
            let (_, invocation) = try AgentPolicyTestFixture.invocation(
                "run_command",
                arguments: .object(["command": .string(command)])
            )
            let request = try await RiskPolicyRequest.resolveAgentV2(
                runID: RunID(),
                projectID: nil,
                workspaceID: WorkspaceID(),
                sessionID: "session",
                backend: .onDevice,
                descriptor: descriptor,
                invocation: invocation,
                using: resolver
            )
            XCTAssertEqual(request.logicalTargets.map(\.path), ["Alias/Sources"])
            XCTAssertEqual(request.resolvedTargets.map(\.path), ["Sources"])

            let result = await evaluator.evaluate(request)
            XCTAssertEqual(
                result.decision,
                .requiresApproval([.explicitApprovalRequired])
            )
            XCTAssertNil(result.executionPermit)
        }
    }

    func testCommandWithNoTrustedParsedTargetsFailsClosed() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        do {
            _ = try await AgentPolicyTestFixture.request(
                "run_command",
                arguments: .object(["command": .string("pwd")]),
                resolver: resolver
            )
            XCTFail("empty command target set must fail")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceTargetAuthorityError,
                .commandTargetsMissing
            )
        }
    }

    func testRequestFromAnotherResolverAuthorityCannotBeEvaluated() async throws {
        let firstBackend = MutableResolutionBackend()
        let firstResolver = WorkspaceTargetResolverAuthority(
            trustedBackend: firstBackend
        )
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: firstResolver
        )
        let secondResolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: SequencePolicyClock([10, 11]),
            resolver: secondResolver
        )
        let result = await evaluator.evaluate(request)
        XCTAssertEqual(
            result.decision,
            .indeterminate(.targetRevalidationFailed)
        )
        XCTAssertNil(result.executionPermit)
    }

    func testPreviewChangeBeforeEvaluationFailsClosed() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        await backend.configure(previewSeed: "changed")
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: SequencePolicyClock([10, 11]),
            resolver: resolver
        )
        let result = await evaluator.evaluate(request)
        XCTAssertEqual(
            result.decision,
            .indeterminate(.targetRevalidationFailed)
        )
        XCTAssertNil(result.executionPermit)
    }

    func testFinalEffectBoundaryDetectsTOCTOUAfterEvaluation() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let clock = SequencePolicyClock([10, 11, 12, 13])
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: clock,
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(request)
        let preliminary = try XCTUnwrap(evaluation.executionPermit)
        await backend.configure(workspaceRevision: "workspace-r2")
        do {
            _ = try await evaluator.finalizeForExecution(preliminary)
            XCTFail("preliminary evaluation permit must not survive TOCTOU")
        } catch {
            XCTAssertEqual(
                error as? PolicyEffectFinalizationError,
                .targetRevalidationFailed
            )
        }
    }

    func testFinalEffectPermitRequiresThirdResolverPassAndFinalClockRead() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let clock = SequencePolicyClock([10, 11, 12, 13])
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: clock,
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(request)
        let preliminary = try XCTUnwrap(evaluation.executionPermit)
        let effect = try await evaluator.finalizeForExecution(preliminary)
        XCTAssertEqual(effect.requestSHA256, request.requestSHA256)
        XCTAssertEqual(effect.authorizedAt, AgentInstant(rawValue: 13))
        let resolutionCount = await backend.resolutionCount
        let clockReads = await clock.readCount
        XCTAssertEqual(resolutionCount, 3)
        XCTAssertEqual(clockReads, 4)
        do {
            _ = try await evaluator.finalizeForExecution(preliminary)
            XCTFail("copied preliminary permit must finalize once per process")
        } catch {
            XCTAssertEqual(
                error as? PolicyEffectFinalizationError,
                .authorizationAlreadyFinalized
            )
        }
    }

    func testExecutorCapabilityRequiresDurableEffectClaimAndRejectsReplay() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: SequencePolicyClock([10, 11, 12, 13]),
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(request)
        let preliminary = try XCTUnwrap(evaluation.executionPermit)
        let effect = try await evaluator.finalizeForExecution(preliminary)
        XCTAssertEqual(effect.callID, request.invocation.callID)
        XCTAssertEqual(effect.idempotencyKey, request.invocation.idempotencyKey)

        let store = InMemoryToolEffectClaimStore()
        let claims = ToolEffectClaimAuthority(
            store: store,
            clock: SequencePolicyClock([14, 15]),
            resolver: resolver,
            policyRevisionAuthority: evaluator.policyRevisionAuthority
        )
        let executable = try await claims.claim(effect)
        XCTAssertEqual(executable.effectKeySHA256, effect.effectKeySHA256)
        XCTAssertFalse(executable.isRecovery)
        do {
            _ = try await claims.claim(effect)
            XCTFail("copying a fresh effect intent must not mint twice")
        } catch {
            XCTAssertEqual(error as? ToolEffectClaimError, .alreadyClaimed)
        }
        let claimSnapshot = await store.snapshot()
        XCTAssertEqual(claimSnapshot.claims.count, 1)
    }

    func testCrashAfterEffectClaimReturnsNoExecutorCapabilityAndRecoversSameKey() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: SequencePolicyClock([10, 11, 12, 13]),
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(request)
        let effect = try await evaluator.finalizeForExecution(
            try XCTUnwrap(evaluation.executionPermit)
        )
        let disk = EffectClaimDisk()
        let crashing = ToolEffectClaimAuthority(
            store: CrashAfterEffectClaimStore(disk: disk, crash: true),
            clock: SequencePolicyClock([14]),
            resolver: resolver,
            policyRevisionAuthority: evaluator.policyRevisionAuthority
        )
        do {
            _ = try await crashing.claim(effect)
            XCTFail("post-commit crash must return no executor capability")
        } catch {
            XCTAssertEqual(
                error as? ToolEffectClaimError,
                .durableCommitFailed
            )
        }
        let persistedClaim = await disk.claim(effect.effectKeySHA256)
        XCTAssertNotNil(persistedClaim)

        let reopened = ToolEffectClaimAuthority(
            store: CrashAfterEffectClaimStore(disk: disk, crash: false),
            clock: SequencePolicyClock([15, 16]),
            resolver: resolver,
            policyRevisionAuthority: evaluator.policyRevisionAuthority
        )
        do {
            _ = try await reopened.claim(effect)
            XCTFail("normal claim path cannot duplicate persisted claim")
        } catch {
            XCTAssertEqual(error as? ToolEffectClaimError, .alreadyClaimed)
        }
        let recovered = try await reopened.recoverPendingClaim(effect)
        XCTAssertTrue(recovered.isRecovery)
        XCTAssertEqual(recovered.effectKeySHA256, effect.effectKeySHA256)
        XCTAssertEqual(recovered.idempotencyKey, request.invocation.idempotencyKey)
    }

    func testExecutorClaimRevalidatesContainmentImmediatelyBeforeCapability() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: SequencePolicyClock([10, 11, 12, 13]),
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(request)
        let effect = try await evaluator.finalizeForExecution(
            try XCTUnwrap(evaluation.executionPermit)
        )
        await backend.configure(
            workspaceRevision: "workspace-changed-before-claim"
        )
        let store = InMemoryToolEffectClaimStore()
        let authority = ToolEffectClaimAuthority(
            store: store,
            clock: SequencePolicyClock([14]),
            resolver: resolver,
            policyRevisionAuthority: evaluator.policyRevisionAuthority
        )
        do {
            _ = try await authority.claim(effect)
            XCTFail("executor capability must not survive post-finalize TOCTOU")
        } catch {
            XCTAssertEqual(
                error as? ToolEffectClaimError,
                .targetRevalidationFailed
            )
        }
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.claims.isEmpty)
    }

    func testExecutorClaimRevalidatesAgainAfterDurableCommit() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: SequencePolicyClock([10, 11, 12, 13]),
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(request)
        let effect = try await evaluator.finalizeForExecution(
            try XCTUnwrap(evaluation.executionPermit)
        )
        let store = MutatingEffectClaimStore(backend: backend)
        let authority = ToolEffectClaimAuthority(
            store: store,
            clock: SequencePolicyClock([14, 15]),
            resolver: resolver,
            policyRevisionAuthority: evaluator.policyRevisionAuthority
        )

        do {
            _ = try await authority.claim(effect)
            XCTFail("a target change during durable commit must mint no authority")
        } catch {
            XCTAssertEqual(
                error as? ToolEffectClaimError,
                .targetRevalidationFailed
            )
        }
        let persisted = await store.claim(
            effectKeySHA256: effect.effectKeySHA256
        )
        XCTAssertNotNil(persisted)

        await backend.configure(workspaceRevision: "workspace-r1")
        let reopened = ToolEffectClaimAuthority(
            store: store,
            clock: SequencePolicyClock([16]),
            resolver: resolver,
            policyRevisionAuthority: evaluator.policyRevisionAuthority
        )
        let recovered = try await reopened.recoverPendingClaim(effect)
        XCTAssertTrue(recovered.isRecovery)
        XCTAssertEqual(recovered.effectKeySHA256, effect.effectKeySHA256)
    }

    func testOneTimeGrantRaceCommitsExactlyOnePermit() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let grant = try PolicyGrant(
            grantID: "one",
            scope: .oneTime(nonce: "nonce-one"),
            tool: request.invocation.tool,
            targetPrefixes: [""],
            expiresAt: AgentInstant(rawValue: 50_000)
        )
        let store = InMemoryPolicyGrantRedemptionStore()
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(grants: [grant]),
            clock: SequencePolicyClock(Array(repeating: 10, count: 200)),
            resolver: resolver,
            grantStore: store
        )

        let results = await withTaskGroup(
            of: RiskPolicyEvaluation.self,
            returning: [RiskPolicyEvaluation].self
        ) { group in
            for _ in 0 ..< 32 {
                group.addTask { await evaluator.evaluate(request) }
            }
            var values: [RiskPolicyEvaluation] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.compactMap(\.executionPermit).count, 1)
        let redemptionSnapshot = await store.snapshot()
        XCTAssertEqual(redemptionSnapshot.redemptions.count, 1)
    }

    func testGrantExpiryIsCheckedAfterResolutionImmediatelyBeforePermit() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let grant = try PolicyGrant(
            grantID: "expiring",
            scope: .oneTime(nonce: "expires"),
            tool: request.invocation.tool,
            targetPrefixes: [""],
            expiresAt: AgentInstant(rawValue: 100)
        )
        let clock = SequencePolicyClock([10, 20, 100])
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(grants: [grant]),
            clock: clock,
            resolver: resolver,
            grantStore: InMemoryPolicyGrantRedemptionStore()
        )
        let result = await evaluator.evaluate(request)
        XCTAssertEqual(
            result.decision,
            .indeterminate(.grantRedemptionConflict("expiring"))
        )
        XCTAssertNil(result.executionPermit)
        let clockReads = await clock.readCount
        XCTAssertEqual(clockReads, 3)
    }

    func testCrashAfterDurableGrantCommitNeverReturnsAuthorityAndCannotReuse() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let grant = try PolicyGrant(
            grantID: "crash",
            scope: .oneTime(nonce: "crash-nonce"),
            tool: request.invocation.tool,
            targetPrefixes: [""],
            expiresAt: AgentInstant(rawValue: 10_000)
        )
        let disk = GrantDisk()
        let crashingStore = CrashAfterCommitGrantStore(disk: disk, crash: true)
        let first = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(grants: [grant]),
            clock: SequencePolicyClock([10, 11, 12]),
            resolver: resolver,
            grantStore: crashingStore
        )
        let firstResult = await first.evaluate(request)
        XCTAssertEqual(
            firstResult.decision,
            .indeterminate(.grantStoreUnavailable("crash"))
        )
        XCTAssertNil(firstResult.executionPermit)
        let persisted = await disk.record(
            grantID: "crash",
            nonce: "crash-nonce"
        )
        XCTAssertNotNil(persisted)

        let reopenedStore = CrashAfterCommitGrantStore(disk: disk, crash: false)
        let reopened = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(grants: [grant]),
            clock: SequencePolicyClock([20, 21, 22]),
            resolver: resolver,
            grantStore: reopenedStore
        )
        let retry = await reopened.evaluate(request)
        XCTAssertEqual(
            retry.decision,
            .indeterminate(.grantRedemptionConflict("crash"))
        )
        XCTAssertNil(retry.executionPermit)
    }

    func testAdvisoryStartAndDrainCanBlockWithoutExtendingDeadline() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )

        let startBlock = BlockingStartTransport()
        let startEvaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(
                advisoryTimeoutMilliseconds: 20
            ),
            clock: SequencePolicyClock([10]),
            resolver: resolver,
            advisory: startBlock
        )
        let startDate = Date()
        let startResult = await startEvaluator.evaluate(request)
        XCTAssertLessThan(Date().timeIntervalSince(startDate), 0.5)
        XCTAssertEqual(
            startResult.decision,
            .indeterminate(.advisoryTimeout)
        )
        startBlock.releaseAll()

        let drainBlock = BlockingDrainTransport()
        let drainEvaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(
                advisoryTimeoutMilliseconds: 20
            ),
            clock: SequencePolicyClock([10]),
            resolver: resolver,
            advisory: drainBlock
        )
        let drainDate = Date()
        let drainResult = await drainEvaluator.evaluate(request)
        XCTAssertLessThan(Date().timeIntervalSince(drainDate), 0.5)
        XCTAssertEqual(
            drainResult.decision,
            .indeterminate(.advisoryTimeout)
        )
        drainBlock.releaseAll()
    }

    func testAdvisoryCallbackThenStartThrowFailsClosed() async throws {
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(
                advisoryTimeoutMilliseconds: 1_000
            ),
            clock: SequencePolicyClock([10]),
            resolver: resolver,
            advisory: CallbackThenThrowTransport()
        )

        let result = await evaluator.evaluate(request)
        XCTAssertEqual(
            result.decision,
            .indeterminate(.advisoryFailure)
        )
        XCTAssertNil(result.executionPermit)
    }

    func testAdvisoryMultipleSynchronousCallbacksFailClosed() async throws {
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        for advisory in [
            CallbackTwiceTransport(throwsAfterCallbacks: false),
            CallbackTwiceTransport(throwsAfterCallbacks: true),
        ] {
            let evaluator = try LayeredRiskPolicyEvaluator(
                configuration: RiskPolicyConfiguration(
                    advisoryTimeoutMilliseconds: 1_000
                ),
                clock: SequencePolicyClock([10]),
                resolver: resolver,
                advisory: advisory
            )
            let result = await evaluator.evaluate(request)
            XCTAssertEqual(
                result.decision,
                .indeterminate(.advisoryFailure)
            )
            XCTAssertNil(result.executionPermit)
        }
    }

    func testAdvisoryDuplicateArrivingDuringDrainFailsClosed() async throws {
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(
                advisoryTimeoutMilliseconds: 1_000
            ),
            clock: SequencePolicyClock([10]),
            resolver: resolver,
            advisory: DuplicateDuringDrainTransport()
        )

        let result = await evaluator.evaluate(request)
        XCTAssertEqual(
            result.decision,
            .indeterminate(.advisoryFailure)
        )
        XCTAssertNil(result.executionPermit)
    }

    func testAdvisoryDecisionCannotCommitWhileDrainIsHung() async throws {
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let transport = CallbackThenBlockingDrainTransport()
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(
                advisoryTimeoutMilliseconds: 20
            ),
            clock: SequencePolicyClock([10]),
            resolver: resolver,
            advisory: transport
        )

        let started = Date()
        let result = await evaluator.evaluate(request)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(
            result.decision,
            .indeterminate(.advisoryTimeout)
        )
        XCTAssertNil(result.executionPermit)
        transport.releaseAll()
    }

    func testCancellationBeforeAdvisoryContinuationCannotHang() async throws {
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let transport = BlockingStartTransport()
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(
                advisoryTimeoutMilliseconds: 5_000
            ),
            clock: SequencePolicyClock([10]),
            resolver: resolver,
            advisory: transport
        )
        let task = Task { await evaluator.evaluate(request) }
        task.cancel()
        let started = Date()
        let result = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(
            result.decision,
            .indeterminate(.advisoryCancelled)
        )
        transport.releaseAll()
    }

    func testHostileAdvisoryThreadsAreHardCapped() async throws {
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let transport = BlockingStartTransport()
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(
                advisoryTimeoutMilliseconds: 20
            ),
            clock: SequencePolicyClock(Array(repeating: 10, count: 50)),
            resolver: resolver,
            advisory: transport
        )
        let limit = PolicyAdvisoryIsolationLimits
            .maximumOutstandingForeignOperations
        let count = limit + 3
        let results = await withTaskGroup(
            of: RiskPolicyEvaluation.self,
            returning: [RiskPolicyEvaluation].self
        ) { group in
            for _ in 0 ..< count {
                group.addTask { await evaluator.evaluate(request) }
            }
            var values: [RiskPolicyEvaluation] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, count)
        XCTAssertLessThanOrEqual(
            transport.startCount,
            limit
        )
        XCTAssertTrue(results.allSatisfy { $0.executionPermit == nil })
        XCTAssertTrue(results.contains {
            $0.decision == RiskPolicyDecision.indeterminate(.advisoryFailure)
        })
        transport.releaseAll()
        try? await Task.sleep(for: .milliseconds(50))
    }
}

private final class NoopAdvisoryOperation: PolicyAdvisoryOperation, @unchecked Sendable {
    func cancelAndDrain() {}
}

private struct CallbackThenThrowTransport: RiskPolicyAdvisoryTransport {
    func start(
        _ input: PolicyAdvisoryInput,
        completion: @escaping @Sendable (PolicyAdvisoryTransportResult) -> Void
    ) throws -> any PolicyAdvisoryOperation {
        _ = input
        completion(.decision(.noAdditionalRestriction))
        throw CallbackThenThrowError()
    }
}

private struct CallbackThenThrowError: Error {}

private struct CallbackTwiceTransport: RiskPolicyAdvisoryTransport {
    let throwsAfterCallbacks: Bool

    func start(
        _ input: PolicyAdvisoryInput,
        completion: @escaping @Sendable (PolicyAdvisoryTransportResult) -> Void
    ) throws -> any PolicyAdvisoryOperation {
        _ = input
        completion(.decision(.noAdditionalRestriction))
        completion(.decision(.deny("conflicting callback")))
        if throwsAfterCallbacks { throw CallbackThenThrowError() }
        return NoopAdvisoryOperation()
    }
}

private struct DuplicateDuringDrainTransport: RiskPolicyAdvisoryTransport {
    func start(
        _ input: PolicyAdvisoryInput,
        completion: @escaping @Sendable (PolicyAdvisoryTransportResult) -> Void
    ) throws -> any PolicyAdvisoryOperation {
        _ = input
        completion(.decision(.noAdditionalRestriction))
        return DuplicateDuringDrainOperation(completion: completion)
    }
}

private final class DuplicateDuringDrainOperation:
    PolicyAdvisoryOperation,
    @unchecked Sendable
{
    private let completion: @Sendable (PolicyAdvisoryTransportResult) -> Void

    init(
        completion: @escaping @Sendable (
            PolicyAdvisoryTransportResult
        ) -> Void
    ) {
        self.completion = completion
    }

    func cancelAndDrain() {
        let delivered = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [completion] in
            completion(.decision(.deny("conflicting async callback")))
            delivered.signal()
        }
        _ = delivered.wait(timeout: .now() + 1)
    }
}

private final class BlockingStartTransport:
    RiskPolicyAdvisoryTransport,
    @unchecked Sendable
{
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var starts = 0

    var startCount: Int {
        lock.withLock { starts }
    }

    func start(
        _ input: PolicyAdvisoryInput,
        completion: @escaping @Sendable (PolicyAdvisoryTransportResult) -> Void
    ) throws -> any PolicyAdvisoryOperation {
        _ = input
        _ = completion
        lock.withLock { starts += 1 }
        semaphore.wait()
        return NoopAdvisoryOperation()
    }

    func releaseAll() {
        for _ in 0 ..< 32 { semaphore.signal() }
    }
}

private final class BlockingDrainOperation:
    PolicyAdvisoryOperation,
    @unchecked Sendable
{
    let semaphore: DispatchSemaphore
    init(semaphore: DispatchSemaphore) { self.semaphore = semaphore }
    func cancelAndDrain() { semaphore.wait() }
}

private final class BlockingDrainTransport:
    RiskPolicyAdvisoryTransport,
    @unchecked Sendable
{
    private let semaphore = DispatchSemaphore(value: 0)

    func start(
        _ input: PolicyAdvisoryInput,
        completion: @escaping @Sendable (PolicyAdvisoryTransportResult) -> Void
    ) throws -> any PolicyAdvisoryOperation {
        _ = input
        _ = completion
        return BlockingDrainOperation(semaphore: semaphore)
    }

    func releaseAll() {
        for _ in 0 ..< 32 { semaphore.signal() }
    }
}

private final class CallbackThenBlockingDrainTransport:
    RiskPolicyAdvisoryTransport,
    @unchecked Sendable
{
    private let semaphore = DispatchSemaphore(value: 0)

    func start(
        _ input: PolicyAdvisoryInput,
        completion: @escaping @Sendable (PolicyAdvisoryTransportResult) -> Void
    ) throws -> any PolicyAdvisoryOperation {
        _ = input
        completion(.decision(.noAdditionalRestriction))
        return BlockingDrainOperation(semaphore: semaphore)
    }

    func releaseAll() {
        for _ in 0 ..< 32 { semaphore.signal() }
    }
}

private actor GrantDisk {
    private var records: [String: PolicyGrantRedemptionRecord] = [:]

    func commit(
        _ record: PolicyGrantRedemptionRecord
    ) -> PolicyGrantCommitDisposition {
        let key = record.grantID + "\u{0}" + record.nonce
        if let existing = records[key] { return .alreadyPresent(existing) }
        records[key] = record
        return .committed
    }

    func record(
        grantID: String,
        nonce: String
    ) -> PolicyGrantRedemptionRecord? {
        records[grantID + "\u{0}" + nonce]
    }
}

private struct CrashAfterCommitGrantStore:
    DurablePolicyGrantRedemptionStore,
    Sendable
{
    let disk: GrantDisk
    let crash: Bool

    func commitIfAbsent(
        _ record: PolicyGrantRedemptionRecord
    ) async throws -> PolicyGrantCommitDisposition {
        let disposition = await disk.commit(record)
        if crash, case .committed = disposition { throw SimulatedCrash() }
        return disposition
    }

    func redemption(
        grantID: String,
        nonce: String
    ) async -> PolicyGrantRedemptionRecord? {
        await disk.record(grantID: grantID, nonce: nonce)
    }
}

private struct SimulatedCrash: Error {}

private actor EffectClaimDisk {
    private var claims: [SHA256Digest: ToolEffectClaimRecord] = [:]

    func commit(
        _ record: ToolEffectClaimRecord
    ) -> ToolEffectClaimDisposition {
        if let existing = claims[record.effectKeySHA256] {
            return .alreadyPresent(existing)
        }
        claims[record.effectKeySHA256] = record
        return .committed
    }

    func claim(_ key: SHA256Digest) -> ToolEffectClaimRecord? { claims[key] }
}

private struct CrashAfterEffectClaimStore:
    DurableToolEffectClaimStore,
    Sendable
{
    let disk: EffectClaimDisk
    let crash: Bool

    func commitIfAbsent(
        _ record: ToolEffectClaimRecord
    ) async throws -> ToolEffectClaimDisposition {
        let result = await disk.commit(record)
        if crash, case .committed = result { throw SimulatedCrash() }
        return result
    }

    func claim(
        effectKeySHA256: SHA256Digest
    ) async -> ToolEffectClaimRecord? {
        await disk.claim(effectKeySHA256)
    }
}

private actor MutatingEffectClaimStore: DurableToolEffectClaimStore {
    private let backend: MutableResolutionBackend
    private var persisted: ToolEffectClaimRecord?

    init(backend: MutableResolutionBackend) {
        self.backend = backend
    }

    func commitIfAbsent(
        _ record: ToolEffectClaimRecord
    ) async -> ToolEffectClaimDisposition {
        if let persisted { return .alreadyPresent(persisted) }
        persisted = record
        await backend.configure(
            workspaceRevision: "workspace-changed-during-commit"
        )
        return .committed
    }

    func claim(
        effectKeySHA256: SHA256Digest
    ) -> ToolEffectClaimRecord? {
        guard persisted?.effectKeySHA256 == effectKeySHA256 else { return nil }
        return persisted
    }
}
