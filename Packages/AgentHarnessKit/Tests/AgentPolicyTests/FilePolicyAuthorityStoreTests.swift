import AgentDomain
@testable import AgentPolicy
import AgentTools
import Foundation
import XCTest

final class FilePolicyAuthorityStoreTests: XCTestCase {
    func testFinalComponentSymlinkAliasIsRejected() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let canonicalURL = directory.appendingPathComponent("canonical.json")
        let aliasURL = directory.appendingPathComponent("alias.json")
        _ = try FilePolicyAuthorityStore(fileURL: canonicalURL)
        try FileManager.default.createSymbolicLink(
            at: aliasURL,
            withDestinationURL: canonicalURL
        )
        XCTAssertThrowsError(
            try FilePolicyAuthorityStore(fileURL: aliasURL)
        ) { error in
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .invalidFileIdentity
            )
        }
    }

    func testNonFileAuthorityLedgerURLIsRejected() {
        XCTAssertThrowsError(
            try FilePolicyAuthorityStore(
                fileURL: URL(string: "https://example.invalid/policy.json")!
            )
        ) { error in
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .invalidFileURL
            )
        }
    }

    func testHardLinkAliasIsRejectedBeforeItCanSplitAuthorityLedger() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let canonicalURL = directory.appendingPathComponent("canonical.json")
        let aliasURL = directory.appendingPathComponent("alias.json")
        _ = try FilePolicyAuthorityStore(fileURL: canonicalURL)
        try FileManager.default.linkItem(at: canonicalURL, to: aliasURL)

        XCTAssertThrowsError(
            try FilePolicyAuthorityStore(fileURL: aliasURL)
        ) { error in
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .invalidFileIdentity
            )
        }
    }

    func testEffectClaimIsAtomicAcrossInstancesAndSurvivesReopen() async throws {
        let fixture = try await makeEffectFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let first = try FilePolicyAuthorityStore(fileURL: url)
        let second = try FilePolicyAuthorityStore(fileURL: url)
        let record = try ToolEffectClaimRecord.make(
            permit: fixture.effect,
            claimedAt: AgentInstant(rawValue: 14)
        )

        async let left = first.commitIfAbsent(record)
        async let right = second.commitIfAbsent(record)
        let dispositions = try await [left, right]
        XCTAssertEqual(dispositions.filter {
            if case .committed = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(dispositions.filter {
            if case .alreadyPresent = $0 { return true }
            return false
        }.count, 1)

        let reopened = try FilePolicyAuthorityStore(fileURL: url)
        let persisted = try await reopened.claim(
            effectKeySHA256: fixture.effect.effectKeySHA256
        )
        XCTAssertEqual(persisted, record)
        let claimSnapshot = try await reopened.effectClaimSnapshot()
        XCTAssertEqual(claimSnapshot.claims, [record])
    }

    func testApprovalConsumptionAndRecoverySurviveFileStoreReopen() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
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
        let evaluation = await policyEvaluator.evaluate(request)
        guard case .requiresApproval = evaluation.decision else {
            return XCTFail("write must require approval")
        }

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let clock = SequencePolicyClock([100, 110, 120, 130, 140, 150, 160])
        let prompt = StaticApprovalPrompt(.approved)
        let ui = try TrustedApprovalUIAuthority(
            signingKey: Data(repeating: 0x33, count: 32),
            prompt: prompt,
            clock: clock
        )
        let firstStore = try FilePolicyAuthorityStore(fileURL: url)
        let firstAuthority = DurableApprovalAuthority(
            store: firstStore,
            clock: clock,
            resolver: resolver,
            uiAuthority: ui,
            policyRevisionAuthority:
                policyEvaluator.policyRevisionAuthority
        )
        let durableRequest = try await firstAuthority.register(
            for: request,
            evaluation: evaluation,
            lifetimeMilliseconds: 1_000
        )
        let registeredLedger = try String(
            decoding: Data(contentsOf: url),
            as: UTF8.self
        )
        XCTAssertFalse(registeredLedger.contains("updated"))
        XCTAssertTrue(registeredLedger.contains(
            try XCTUnwrap(request.operationPreviewSHA256).rawValue
        ))
        _ = try await firstAuthority.resolve(
            requestID: durableRequest.requestID,
            for: request
        )
        _ = try await firstAuthority.authorize(
            requestID: durableRequest.requestID,
            for: request
        )

        let reopenedStore = try FilePolicyAuthorityStore(fileURL: url)
        let reopenedPolicyRevisionAuthority = try PolicyRevisionAuthority(
            configuration: RiskPolicyConfiguration()
        )
        let reopenedAuthority = DurableApprovalAuthority(
            store: reopenedStore,
            clock: clock,
            resolver: resolver,
            uiAuthority: ui,
            policyRevisionAuthority: reopenedPolicyRevisionAuthority
        )
        let recovered = try await reopenedAuthority.recoverLease(
            requestID: durableRequest.requestID,
            for: request
        )
        let effect = try await reopenedAuthority.finalizeForExecution(
            recovered
        )
        XCTAssertEqual(effect.requestSHA256, request.requestSHA256)
        XCTAssertTrue(recovered.isRecovery)
        let snapshot = try await reopenedStore.approvalSnapshot()
        XCTAssertEqual(snapshot.states.count, 1)
        XCTAssertNotNil(snapshot.states[0].consumption)
    }

    func testCreatableDestinationApprovalRoundTripsWithoutOptionalObjectKeys() async throws {
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: AbsentResolutionBackend()
        )
        let request = try await AgentPolicyTestFixture.request(
            "write_file",
            arguments: .object([
                "path": .string("new-file.txt"),
                "contents": .string("new contents"),
            ]),
            resolver: resolver
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(),
            clock: SequencePolicyClock([50]),
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(request)
        guard case .requiresApproval = evaluation.decision else {
            return XCTFail("write must require approval")
        }

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let store = try FilePolicyAuthorityStore(fileURL: url)
        let prompt = StaticApprovalPrompt(.approved)
        let clock = SequencePolicyClock([100])
        let ui = try TrustedApprovalUIAuthority(
            signingKey: Data(repeating: 0x44, count: 32),
            prompt: prompt,
            clock: clock
        )
        let authority = DurableApprovalAuthority(
            store: store,
            clock: clock,
            resolver: resolver,
            uiAuthority: ui,
            policyRevisionAuthority: evaluator.policyRevisionAuthority
        )
        let durable = try await authority.register(
            for: request,
            evaluation: evaluation,
            lifetimeMilliseconds: 1_000
        )

        let liveState = try await store.state(requestID: durable.requestID)
        XCTAssertEqual(liveState?.request, durable)
        let reopened = try FilePolicyAuthorityStore(fileURL: url)
        let reopenedState = try await reopened.state(
            requestID: durable.requestID
        )
        XCTAssertEqual(reopenedState?.request, durable)
    }

    func testOneTimeGrantCommitSurvivesReopenAndCannotBeReused() async throws {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await AgentPolicyTestFixture.request(
            "read_file",
            arguments: .object(["path": .string("a.txt")]),
            resolver: resolver
        )
        let grant = try PolicyGrant(
            grantID: "file-grant",
            scope: .oneTime(nonce: "file-nonce"),
            tool: request.invocation.tool,
            targetPrefixes: [""],
            expiresAt: AgentInstant(rawValue: 10_000)
        )
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let firstStore = try FilePolicyAuthorityStore(fileURL: url)
        let first = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(grants: [grant]),
            clock: SequencePolicyClock([10, 11, 12]),
            resolver: resolver,
            grantStore: firstStore
        )
        let firstResult = await first.evaluate(request)
        XCTAssertNotNil(firstResult.executionPermit)

        let reopenedStore = try FilePolicyAuthorityStore(fileURL: url)
        let retry = try LayeredRiskPolicyEvaluator(
            configuration: RiskPolicyConfiguration(grants: [grant]),
            clock: SequencePolicyClock([20, 21, 22]),
            resolver: resolver,
            grantStore: reopenedStore
        )
        let retryResult = await retry.evaluate(request)
        XCTAssertEqual(
            retryResult.decision,
            .indeterminate(.grantRedemptionConflict("file-grant"))
        )
        XCTAssertNil(retryResult.executionPermit)
        let grantSnapshot = try await reopenedStore.grantSnapshot()
        XCTAssertEqual(grantSnapshot.redemptions.count, 1)
    }

    func testFaultBeforeRenameLeavesOldLedgerAndReturnsNoAuthority() async throws {
        let fixture = try await makeEffectFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        _ = try FilePolicyAuthorityStore(fileURL: url)
        let faulting = try FilePolicyAuthorityStore(
            fileURL: url,
            faultInjector: { point in
                if case .afterFileSyncBeforeRename = point {
                    throw InjectedFileStoreFault()
                }
            }
        )
        let authority = ToolEffectClaimAuthority(
            store: faulting,
            clock: SequencePolicyClock([14]),
            resolver: fixture.resolver,
            policyRevisionAuthority: fixture.policyRevisionAuthority
        )
        do {
            _ = try await authority.claim(fixture.effect)
            XCTFail("pre-rename fault must return no executor capability")
        } catch {
            XCTAssertEqual(
                error as? ToolEffectClaimError,
                .durableCommitFailed
            )
        }
        let reopened = try FilePolicyAuthorityStore(fileURL: url)
        let claim = try await reopened.claim(
            effectKeySHA256: fixture.effect.effectKeySHA256
        )
        XCTAssertNil(claim)
    }

    func testFaultAfterRenameReturnsNoAuthorityButRecoveryFindsCommittedClaim() async throws {
        let fixture = try await makeEffectFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        _ = try FilePolicyAuthorityStore(fileURL: url)
        let faulting = try FilePolicyAuthorityStore(
            fileURL: url,
            faultInjector: { point in
                if case .afterRenameBeforeDirectorySync = point {
                    throw InjectedFileStoreFault()
                }
            }
        )
        let first = ToolEffectClaimAuthority(
            store: faulting,
            clock: SequencePolicyClock([14]),
            resolver: fixture.resolver,
            policyRevisionAuthority: fixture.policyRevisionAuthority
        )
        do {
            _ = try await first.claim(fixture.effect)
            XCTFail("post-rename fault must still return no authority")
        } catch {
            XCTAssertEqual(
                error as? ToolEffectClaimError,
                .durableCommitFailed
            )
        }

        let reopenedStore = try FilePolicyAuthorityStore(fileURL: url)
        let recoveredAuthority = ToolEffectClaimAuthority(
            store: reopenedStore,
            clock: SequencePolicyClock([15]),
            resolver: fixture.resolver,
            policyRevisionAuthority: fixture.policyRevisionAuthority
        )
        let recovered = try await recoveredAuthority.recoverPendingClaim(
            fixture.effect
        )
        XCTAssertTrue(recovered.isRecovery)
        XCTAssertEqual(
            recovered.effectKeySHA256,
            fixture.effect.effectKeySHA256
        )
    }

    func testEnvelopeWithoutEffectClaimsFailsClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        _ = try FilePolicyAuthorityStore(fileURL: url)
        try mutateEnvelope(at: url) { envelope in
            var state = try XCTUnwrap(envelope["state"] as? [String: Any])
            state.removeValue(forKey: "effectClaims")
            envelope["state"] = state
        }
        XCTAssertThrowsError(
            try FilePolicyAuthorityStore(fileURL: url)
        ) { error in
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .corruptEnvelope
            )
        }
    }

    func testTamperedFileClaimDigestFailsClosedOnReopen() async throws {
        let fixture = try await makeEffectFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let store = try FilePolicyAuthorityStore(fileURL: url)
        let record = try ToolEffectClaimRecord.make(
            permit: fixture.effect,
            claimedAt: AgentInstant(rawValue: 14)
        )
        _ = try await store.commitIfAbsent(record)

        let encoded = try Data(contentsOf: url)
        let replacement = try AgentPolicyTestFixture.digest("tampered-claim")
        let tampered = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)?
                .replacingOccurrences(
                    of: record.claimSHA256.rawValue,
                    with: replacement.rawValue
                )
                .data(using: .utf8)
        )
        try tampered.write(to: url)

        XCTAssertThrowsError(
            try FilePolicyAuthorityStore(fileURL: url)
        ) { error in
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .corruptEnvelope
            )
        }
    }

    func testDeletedClaimRecordFailsEnvelopeIntegrityCheck() async throws {
        let fixture = try await makeEffectFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let store = try FilePolicyAuthorityStore(fileURL: url)
        let record = try ToolEffectClaimRecord.make(
            permit: fixture.effect,
            claimedAt: AgentInstant(rawValue: 14)
        )
        _ = try await store.commitIfAbsent(record)

        try mutateEnvelope(at: url) { envelope in
            var state = try XCTUnwrap(envelope["state"] as? [String: Any])
            var claims = try XCTUnwrap(
                state["effectClaims"] as? [String: Any]
            )
            claims["claims"] = []
            state["effectClaims"] = claims
            envelope["state"] = state
        }

        XCTAssertThrowsError(
            try FilePolicyAuthorityStore(fileURL: url)
        ) { error in
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .corruptEnvelope
            )
        }
    }

    func testLiveStoreRejectsGenerationRollback() async throws {
        let fixture = try await makeEffectFixture()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let store = try FilePolicyAuthorityStore(fileURL: url)
        let oldEnvelope = try Data(contentsOf: url)
        let record = try ToolEffectClaimRecord.make(
            permit: fixture.effect,
            claimedAt: AgentInstant(rawValue: 14)
        )
        _ = try await store.commitIfAbsent(record)
        try overwriteFile(at: url, with: oldEnvelope)

        do {
            _ = try await store.claim(
                effectKeySHA256: fixture.effect.effectKeySHA256
            )
            XCTFail("a live authority must reject a replayed old generation")
        } catch {
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .generationRollback
            )
        }
    }

    func testPostInitializationLedgerSymlinkSwapFailsClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let replacement = directory.appendingPathComponent("replacement.json")
        let store = try FilePolicyAuthorityStore(fileURL: url)
        try FileManager.default.copyItem(at: url, to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: replacement
        )

        do {
            _ = try await store.effectClaimSnapshot()
            XCTFail("a post-init symlink swap must not be followed")
        } catch {
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .invalidFileIdentity
            )
        }
    }

    func testPostInitializationLedgerHardLinkSwapFailsClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let replacement = directory.appendingPathComponent("replacement.json")
        let store = try FilePolicyAuthorityStore(fileURL: url)
        try FileManager.default.copyItem(at: url, to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.linkItem(at: replacement, to: url)

        do {
            _ = try await store.effectClaimSnapshot()
            XCTFail("a post-init hardlink swap must not be trusted")
        } catch {
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .invalidFileIdentity
            )
        }
    }

    func testPostInitializationParentDirectoryReplacementFailsClosed() async throws {
        let container = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let authorityDirectory = container.appendingPathComponent(
            "authority",
            isDirectory: true
        )
        let displacedDirectory = container.appendingPathComponent(
            "displaced",
            isDirectory: true
        )
        let url = authorityDirectory.appendingPathComponent(
            "policy-ledger.json"
        )
        let store = try FilePolicyAuthorityStore(fileURL: url)
        try FileManager.default.moveItem(
            at: authorityDirectory,
            to: displacedDirectory
        )
        try FileManager.default.createDirectory(
            at: authorityDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            _ = try await store.effectClaimSnapshot()
            XCTFail("the store must bind the original parent directory inode")
        } catch {
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .invalidFileIdentity
            )
        }
    }

    func testPostInitializationLockReplacementFailsClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let lockURL = directory.appendingPathComponent("policy-ledger.json.lock")
        let store = try FilePolicyAuthorityStore(fileURL: url)
        let marker = try Data(contentsOf: lockURL)
        try FileManager.default.removeItem(at: lockURL)
        try marker.write(to: lockURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: lockURL.path
        )

        do {
            _ = try await store.effectClaimSnapshot()
            XCTFail("replacing the pinned lock inode must fail closed")
        } catch {
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .invalidFileIdentity
            )
        }
    }

    func testWorldReadableLedgerPermissionsFailClosed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        let store = try FilePolicyAuthorityStore(fileURL: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )

        do {
            _ = try await store.effectClaimSnapshot()
            XCTFail("authority evidence must remain owner-only")
        } catch {
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .invalidFileIdentity
            )
        }
    }

    func testUnsupportedFutureFileEnvelopeFailsClosed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("policy-ledger.json")
        _ = try FilePolicyAuthorityStore(fileURL: url)
        try mutateEnvelope(at: url) { envelope in
            envelope["formatVersion"] = 4
        }

        XCTAssertThrowsError(
            try FilePolicyAuthorityStore(fileURL: url)
        ) { error in
            XCTAssertEqual(
                error as? FilePolicyAuthorityStoreError,
                .unsupportedVersion(4)
            )
        }
    }

    private func mutateEnvelope(
        at url: URL,
        _ mutation: (inout [String: Any]) throws -> Void
    ) throws {
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: url)
            ) as? [String: Any]
        )
        try mutation(&envelope)
        let data = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        )
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func overwriteFile(at url: URL, with data: Data) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func makeEffectFixture() async throws -> EffectFixture {
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
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
        return EffectFixture(
            effect: effect,
            resolver: resolver,
            policyRevisionAuthority: evaluator.policyRevisionAuthority
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "novaforge-policy-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private struct EffectFixture: Sendable {
    let effect: ToolEffectPermit
    let resolver: WorkspaceTargetResolverAuthority
    let policyRevisionAuthority: PolicyRevisionAuthority
}

private struct InjectedFileStoreFault: Error {}

private actor AbsentResolutionBackend: WorkspaceTargetResolutionBackend {
    func resolveTargets(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        workspaceID: WorkspaceID
    ) async throws -> WorkspaceResolutionCandidate {
        let targets = try NormalizedToolTarget.canonicalize(
            descriptor.extractTargets(from: invocation.arguments)
        )
        let preconditions = try targets.enumerated().map { index, target in
            ApprovalPrecondition(
                resolution: try ResolvedToolTargetSnapshot.make(
                    workspaceID: workspaceID,
                    target: target,
                    resolvedRelativePath: target.path,
                    disposition: .creatableDestination,
                    workspaceRootIdentity: "root-identity",
                    containmentIdentity: "absent-parent-\(index)",
                    objectKind: .absent,
                    objectDevice: nil,
                    objectInode: nil,
                    objectLinkCount: nil,
                    resolutionRevision: "resolution-r1",
                    traversedSymlink: false
                ),
                previewSHA256: try AgentPolicyTestFixture.digest(
                    "absent-preview-\(index)"
                )
            )
        }
        return try WorkspaceResolutionCandidate(
            preconditions: preconditions,
            workspaceRevision: "workspace-r1"
        )
    }
}
