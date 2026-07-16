import AgentDomain
import AgentEngine
import AgentPolicy
import AgentTools
import struct CryptoKit.SHA256
import Foundation
import XCTest
@testable import NovaForge

final class AgentPolicyEngineMutationAdapterTests: XCTestCase {
    func testMutationReceiptCountsSurviveCanonicalEventJSONRoundTrip()
        throws
    {
        let value = try AgentPolicyEngineMutationAdapter
            .canonicalNonnegativeJSONInteger(1)
        let encoded = try JSONEncoder().encode(value)

        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: encoded),
            value
        )
        XCTAssertEqual(value, .number(.integer(1)))
        XCTAssertThrowsError(
            try AgentPolicyEngineMutationAdapter
                .canonicalNonnegativeJSONInteger(-1)
        ) { error in
            XCTAssertEqual(
                error as? AgentPolicyEngineMutationAdapterError,
                .numericValueOutOfRange
            )
        }
    }

    func testDurablePreparationIsDeterministicAndContainsNoRawArguments()
        throws
    {
        let first = try makeRecord()
        let second = try makeRecord()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.authorityToken, second.authorityToken)
        XCTAssertTrue(first.authorityToken.hasPrefix(
            AgentPolicyEnginePreparationRecord.tokenPrefix
        ))

        let encoded = try JSONEncoder().encode(first)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("TOP-SECRET-CONTENTS"))
        XCTAssertFalse(text.contains("exactArguments"))
        XCTAssertFalse(text.contains("arguments"))
        XCTAssertEqual(
            try JSONDecoder().decode(
                AgentPolicyEnginePreparationRecord.self,
                from: encoded
            ),
            first
        )
    }

    func testForgedArgumentBindingGetsDifferentOpaqueToken() throws {
        let expected = try makeRecord(argumentDigestSeed: "expected")
        let forged = try makeRecord(argumentDigestSeed: "forged")

        XCTAssertNotEqual(expected.authorityToken, forged.authorityToken)
        XCTAssertNotEqual(expected.recordSHA256, forged.recordSHA256)
        XCTAssertNotEqual(
            expected.canonicalArgumentDigest,
            forged.canonicalArgumentDigest
        )
    }

    func testExactApprovalRequestIdentityIsPartOfDurableBinding() throws {
        let requestID = ApprovalRequestID(rawValue: uuid(40))
        let expected = try makeRecord(requestID: requestID)
        let substituted = try makeRecord(
            requestID: ApprovalRequestID(rawValue: uuid(41))
        )

        XCTAssertNotEqual(expected.authorityToken, substituted.authorityToken)
        guard case let .durableApproval(storedID, _) = expected.authorization
        else { return XCTFail("Expected durable approval binding") }
        XCTAssertEqual(storedID, requestID)
    }

    func testEffectKeyCollisionWithDifferentBindingFailsClosed() async throws {
        let store = InMemoryAgentPolicyEnginePreparationStore()
        let first = try makeRecord(argumentDigestSeed: "first")
        let collision = try makeRecord(
            argumentDigestSeed: "second",
            effectKeySeed: "effect"
        )
        let canonicalFirst = try makeRecord(
            argumentDigestSeed: "first",
            effectKeySeed: "effect"
        )

        _ = try await store.commitIfAbsent(canonicalFirst)
        do {
            _ = try await store.commitIfAbsent(collision)
            XCTFail("Expected a conflicting effect key to be rejected")
        } catch let error as AgentPolicyEngineMutationAdapterError {
            XCTAssertEqual(error, .preparationConflict)
        }
        XCTAssertNotEqual(first.authorityToken, collision.authorityToken)
    }

    func testPreparationSurvivesStoreRestartAndTamperingIsRejected()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "novaforge-engine-preparation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preparations.ledger")
        let record = try makeRecord()

        let first = try FileAgentPolicyEnginePreparationStore(fileURL: file)
        let commitResult = try await first.commitIfAbsent(record)
        XCTAssertEqual(commitResult, .committed)
        let restarted = try FileAgentPolicyEnginePreparationStore(
            fileURL: file
        )
        let authorityRecord = try await restarted.record(
            authorityToken: record.authorityToken
        )
        XCTAssertEqual(authorityRecord, record)
        let effectRecord = try await restarted.record(
            effectKeySHA256: record.effectKeySHA256
        )
        XCTAssertEqual(effectRecord, record)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file))
                as? [String: Any]
        )
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        records[0]["authorityToken"] = "m7-policy-preparation-v1:forged"
        object["records"] = records
        try JSONSerialization.data(withJSONObject: object)
            .write(to: file, options: .atomic)

        do {
            _ = try await restarted.record(
                authorityToken: record.authorityToken
            )
            XCTFail("Expected tampered durable evidence to fail closed")
        } catch let error as AgentPolicyEngineMutationAdapterError {
            XCTAssertEqual(error, .durableStoreCorrupt)
        }
    }

    func testBindingRejectsWrongRunWorkspaceCallArgumentAndAttempt() throws {
        let record = try makeRecord()
        let exact = try makeInvocation()
        let context = makeContext(
            runID: record.runID,
            workspaceID: record.workspaceID
        )
        XCTAssertTrue(record.matches(context: context, invocation: exact))

        XCTAssertFalse(record.matches(
            context: makeContext(
                runID: RunID(rawValue: uuid(70)),
                workspaceID: record.workspaceID
            ),
            invocation: exact
        ))
        XCTAssertFalse(record.matches(
            context: makeContext(
                runID: record.runID,
                workspaceID: WorkspaceID(rawValue: uuid(71))
            ),
            invocation: exact
        ))
        XCTAssertFalse(record.matches(
            context: context,
            invocation: try makeInvocation(callID: ToolCallID(rawValue: uuid(72)))
        ))
        XCTAssertFalse(record.matches(
            context: context,
            invocation: try makeInvocation(
                attemptID: AttemptID(rawValue: uuid(73))
            )
        ))
    }

    func testApplyHasNoHiddenPromptAndRecoveryNeverCallsApply() throws {
        let source = try String(
            contentsOf: sourceURL("AgentPolicyMutationService.swift"),
            encoding: .utf8
        )
        let apply = try slice(
            source,
            from: "    func applyAgentV2(\n        _ prepared: AgentPolicyStagedAgentV2Mutation,\n        approval: ApprovalResolution?\n    ) async throws -> AgentPolicyUnclassifiedMutationResult {\n        guard !Task.isCancelled",
            to: "    private static func domainApprovalRequest("
        )
        XCTAssertFalse(apply.contains("approvalAuthority.resolve("))
        XCTAssertTrue(apply.contains("approvalStore.state("))
        XCTAssertTrue(apply.contains("approvalAuthority.authorize("))

        let adapter = try String(
            contentsOf: sourceURL("AgentPolicyEngineMutationAdapter.swift"),
            encoding: .utf8
        )
        let recovery = try slice(
            adapter,
            from: "    func recoverMutation(\n        context:",
            to: "    func resolveApproval("
        )
        XCTAssertFalse(recovery.contains("applyAgentV2("))
        XCTAssertFalse(recovery.contains("applyMutation("))
        XCTAssertTrue(recovery.contains("system.recoverMutation("))
    }

    func testEngineSealAndDurableTokenAreBothCheckedBeforeApply() throws {
        let source = try String(
            contentsOf: sourceURL("AgentPolicyEngineMutationAdapter.swift"),
            encoding: .utf8
        )
        let apply = try slice(
            source,
            from: "    func applyMutation(\n        preparation:",
            to: "    func recoverMutation("
        )
        XCTAssertTrue(apply.contains("current.sealed == preparation"))
        XCTAssertTrue(apply.contains("preparationStore.record("))
        XCTAssertTrue(apply.contains("durable == current.record"))
    }

    func testRejectionCancellationAmbiguityAndDuplicateEffectStayFailClosed()
        throws
    {
        let service = try String(
            contentsOf: sourceURL("AgentPolicyMutationService.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(service.contains(
            "guard trusted.decision == .approved,\n                  approval.decision == .approved"
        ))
        XCTAssertTrue(service.contains(
            "catch is CancellationError {\n            throw AgentPolicyMutationServiceError.cancelled"
        ))
        XCTAssertTrue(service.contains(
            "claimed = try await claimAuthority.claim(permit)"
        ))
        XCTAssertFalse(service.contains(
            "recoverPendingClaim(permit)"
        ))

        let adapter = try String(
            contentsOf: sourceURL("AgentPolicyEngineMutationAdapter.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(adapter.contains(
            "case let .reconciliationRequired(digest):\n            return .reconciliationRequired(digest)"
        ))
        XCTAssertTrue(adapter.contains(
            "case .noDurableRecord:\n            return .noDurableRecord"
        ))
        XCTAssertTrue(adapter.contains(
            "case let .evidenceSettled(result), let .alreadySettled(result):\n            return .settled"
        ))
    }

    private func makeRecord(
        argumentDigestSeed: String = "argument",
        effectKeySeed: String = "effect",
        requestID: ApprovalRequestID? = nil
    ) throws -> AgentPolicyEnginePreparationRecord {
        let invocation = try makeInvocation(
            argumentDigestSeed: argumentDigestSeed
        )
        return try AgentPolicyEnginePreparationRecord.makeBinding(
            origin: .agentV2,
            runID: RunID(rawValue: uuid(1)),
            workspaceID: WorkspaceID(rawValue: uuid(2)),
            callID: invocation.callID,
            modelAttemptID: invocation.modelAttemptID,
            tool: invocation.tool,
            canonicalArgumentDigest: invocation.canonicalArgumentDigest,
            idempotencyKey: invocation.idempotencyKey,
            effectClass: invocation.effectClass,
            locality: invocation.locality,
            requestSHA256: try digest("request-\(argumentDigestSeed)"),
            policySHA256: try digest("policy"),
            targetAttestationSHA256: try digest("target"),
            workspaceRevision: "workspace-r1",
            effectKeySHA256: try digest(effectKeySeed),
            authorization: .durableApproval(
                requestID: requestID ?? ApprovalRequestID(
                    rawValue: uuid(30)
                ),
                bindingSHA256: try digest("approval-binding")
            )
        )
    }

    private func makeInvocation(
        callID: ToolCallID? = nil,
        attemptID: AttemptID? = nil,
        argumentDigestSeed: String = "argument"
    ) throws -> ToolInvocation {
        let descriptor = WriteFileTool.descriptor
        return ToolInvocation(
            callID: callID ?? ToolCallID(rawValue: uuid(3)),
            modelAttemptID: attemptID ?? AttemptID(rawValue: uuid(4)),
            tool: descriptor.identity,
            arguments: .object([
                "contents": .string("TOP-SECRET-CONTENTS"),
                "path": .string("Sources/App.swift"),
            ]),
            canonicalArgumentDigest: try digest(argumentDigestSeed).rawValue,
            idempotencyKey: "operation-1",
            effectClass: descriptor.effectClass,
            locality: .onDevice
        )
    }

    private func makeContext(
        runID: RunID,
        workspaceID: WorkspaceID
    ) -> AgentRunContext {
        AgentRunContext(
            lineage: .root(runID),
            conversationID: ConversationID(rawValue: uuid(10)),
            projectID: ProjectID(rawValue: uuid(11)),
            workspaceID: workspaceID,
            executionNodeID: ExecutionNodeID(rawValue: uuid(12)),
            engineVersion: .agentHarnessV2,
            acceptedAt: AgentInstant(rawValue: 1),
            features: AgentFeatureSet([]),
            cancellation: CancellationLineage(
                scopeID: CancellationScopeID(rawValue: uuid(13))
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
    }

    private func digest(_ value: String) throws -> AgentPolicy.SHA256Digest {
        let bytes = SHA256.hash(data: Data(value.utf8))
        return try AgentPolicy.SHA256Digest(
            "sha256:" + bytes.map { String(format: "%02x", $0) }.joined()
        )
    }

    private func uuid(_ byte: UInt8) -> UUID {
        UUID(uuid: (
            byte, byte, byte, byte, byte, byte, byte, byte,
            byte, byte, byte, byte, byte, byte, byte, byte
        ))
    }

    private func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AgentPad/Services")
            .appendingPathComponent(name)
    }

    private func slice(
        _ source: String,
        from start: String,
        to end: String
    ) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start)?.lowerBound)
        let upper = try XCTUnwrap(
            source.range(of: end, range: lower ..< source.endIndex)?.lowerBound
        )
        return String(source[lower ..< upper])
    }
}
