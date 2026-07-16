import AgentDomain
import Foundation
import XCTest

final class AgentDomainEncodingTests: XCTestCase {
    func testJSONValuePreservesScalarKindsAndNestedContainers() throws {
        let data = Data(#"{"false":false,"true":true,"one":1,"zero":0,"decimal":1.25,"nothing":null,"nested":[true,1,null]}"#.utf8)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        guard case let .object(object) = decoded else {
            return XCTFail("Expected an object")
        }
        XCTAssertEqual(object["false"], .bool(false))
        XCTAssertEqual(object["true"], .bool(true))
        XCTAssertEqual(object["zero"], .number(.integer(0)))
        XCTAssertEqual(object["one"], .number(.integer(1)))
        XCTAssertEqual(object["decimal"], .number(.floatingPoint(1.25)))
        XCTAssertEqual(object["nothing"], .null)
        XCTAssertEqual(
            object["nested"],
            .array([.bool(true), .number(.integer(1)), .null])
        )

        let roundTrip = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(roundTrip, decoded)
    }

    func testJSONValueEncodingIsDeterministicAcrossObjectInsertionOrder() throws {
        let left = JSONValue.object([
            "z": .array([.number(.integer(1)), .bool(false)]),
            "a": .object(["b": .null, "a": .string("value")]),
        ])
        let right = JSONValue.object([
            "a": .object(["a": .string("value"), "b": .null]),
            "z": .array([.number(.integer(1)), .bool(false)]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(try encoder.encode(left), try encoder.encode(right))
        XCTAssertEqual(left, right)
    }

    func testNonFiniteJSONNumberCannotEncode() {
        XCTAssertThrowsError(
            try JSONEncoder().encode(JSONValue.number(.floatingPoint(.infinity)))
        )
        XCTAssertThrowsError(
            try JSONEncoder().encode(JSONValue.number(.floatingPoint(.nan)))
        )
    }

    func testVersionedCommandAndEventRoundTripDeterministically() throws {
        let fixture = Fixture()
        let command = AgentCommand(
            header: AgentCommandHeader(
                commandID: fixture.commandID,
                runID: fixture.context.lineage.runID,
                issuedAt: fixture.instant,
                correlationID: fixture.correlationID
            ),
            payload: .send(
                SendCommand(context: fixture.context, userItem: fixture.userItem)
            )
        )
        let event = AgentEvent(
            header: AgentEventHeader(
                eventID: fixture.eventID,
                schemaVersion: fixture.context.schemaVersion,
                context: fixture.context,
                sequence: .first,
                timestamp: fixture.instant,
                causationID: fixture.causationID,
                correlationID: fixture.correlationID
            ),
            payload: .runAccepted(
                RunAcceptedEvent(context: fixture.context, initialItems: [fixture.userItem])
            )
        )

        try assertRoundTrip(command)
        try assertRoundTrip(event)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let commandObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(command)) as? [String: Any]
        )
        let commandPayload = try XCTUnwrap(commandObject["payload"] as? [String: Any])
        XCTAssertEqual(commandPayload["kind"] as? String, "send")

        let eventObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(event)) as? [String: Any]
        )
        let eventPayload = try XCTUnwrap(eventObject["payload"] as? [String: Any])
        XCTAssertEqual(eventPayload["kind"] as? String, "runAccepted")
        let eventHeader = try XCTUnwrap(eventObject["header"] as? [String: Any])
        let schema = try XCTUnwrap(eventHeader["schemaVersion"] as? [String: Any])
        XCTAssertEqual(schema["major"] as? Int, 1)
        XCTAssertEqual(schema["minor"] as? Int, 0)
    }

    func testSchemaCompatibilityIsMajorStrictAndMinorForwardSafe() {
        XCTAssertTrue(AgentSchemaVersion(major: 1, minor: 0).canBeDecoded(by: .v1))
        XCTAssertFalse(AgentSchemaVersion(major: 1, minor: 1).canBeDecoded(by: .v1))
        XCTAssertTrue(AgentSchemaVersion.v1.canBeDecoded(by: .v1_1))
        XCTAssertTrue(AgentSchemaVersion.v1_1.canBeDecoded(by: .current))
        XCTAssertFalse(AgentSchemaVersion(major: 2, minor: 0).canBeDecoded(by: .v1))
    }

    func testCanonicalJournalDigestsAndProviderScopeRejectAmbiguousForms() throws {
        let digest = try AgentCanonicalSHA256Digest(
            "sha256:" + String(repeating: "0a", count: 32)
        )
        XCTAssertEqual(digest.rawValue.count, 71)
        XCTAssertThrowsError(try AgentCanonicalSHA256Digest(
            "sha256:" + String(repeating: "A", count: 64)
        ))
        XCTAssertThrowsError(try AgentCanonicalSHA256Digest(
            "sha256:" + String(repeating: "١", count: 32)
        ))
        XCTAssertNoThrow(try ProviderAttemptScopeReference(
            requestID: "request-1",
            attemptID: "attempt-1"
        ))
        XCTAssertThrowsError(try ProviderAttemptScopeReference(
            requestID: " request-1",
            attemptID: "attempt-1"
        ))
        XCTAssertThrowsError(try ProviderAttemptScopeReference(
            requestID: "request-1",
            attemptID: "attempt\n1"
        ))
    }

    func testV10AcceptanceOmitsV11FieldAndDecodesFrozenEngineDefault() throws {
        let fixture = Fixture()
        let payload = RunAcceptedEvent(
            context: fixture.context,
            initialItems: [fixture.userItem]
        )
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(object["acceptedEngineVersion"])
        let decoded = try JSONDecoder().decode(RunAcceptedEvent.self, from: data)
        XCTAssertEqual(decoded.acceptedEngineVersion, .agentHarnessV1)
        XCTAssertEqual(decoded, payload)
    }

    func testV11AcceptanceRequiresAndBindsAcceptedEngineVersion() throws {
        let legacy = Fixture()
        let context = AgentRunContext(
            schemaVersion: .v1_1,
            lineage: legacy.context.lineage,
            conversationID: legacy.context.conversationID,
            projectID: legacy.context.projectID,
            workspaceID: legacy.context.workspaceID,
            executionNodeID: legacy.context.executionNodeID,
            engineVersion: .agentHarnessV2,
            acceptedAt: legacy.context.acceptedAt,
            features: legacy.context.features,
            cancellation: legacy.context.cancellation,
            initialBudget: legacy.context.initialBudget
        )
        let payload = RunAcceptedEvent(
            context: context,
            initialItems: [legacy.userItem]
        )
        let data = try JSONEncoder().encode(payload)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            object["acceptedEngineVersion"] as? String,
            "agent-harness-v2"
        )

        object.removeValue(forKey: "acceptedEngineVersion")
        let missing = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(RunAcceptedEvent.self, from: missing))
    }

    func testProviderAttemptMetadataRejectsPartialOrDisguisedLegacyRecords() throws {
        let recorded: ProviderAttemptJournalMetadata = .recordedV1_1(
            requestDigest: try AgentCanonicalSHA256Digest(
                "sha256:" + String(repeating: "ab", count: 32)
            ),
            scope: try ProviderAttemptScopeReference(
                requestID: "request-1",
                attemptID: "attempt-1"
            ),
            ordinal: 7,
            recoverySeed: 99
        )
        try assertRoundTrip(recorded)

        let partial = Data(#"{"kind":"recordedV1_1","ordinal":7,"recoverySeed":99}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProviderAttemptJournalMetadata.self,
            from: partial
        ))
        let disguised = Data(#"{"kind":"legacyV1","ordinal":7}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProviderAttemptJournalMetadata.self,
            from: disguised
        ))
    }

    func testApprovalRejectionResultIsCanonicalAndEffectFree() {
        let result = ToolResult.approvalRejected(
            modelItemID: tagged(90),
            callID: tagged(91)
        )
        XCTAssertTrue(result.isCanonicalApprovalRejection)
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.artifacts.isEmpty)
        XCTAssertTrue(result.evidence.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.error?.category, .authorization)
        XCTAssertEqual(result.error?.code, "approval_rejected")
    }

    func testRunAndCancellationLineageRoundTrip() throws {
        let root = AgentRunLineage.root(tagged(1) as RunID)
        let child = AgentRunLineage.child(tagged(2) as RunID, of: root)
        let retry = AgentRunLineage.retry(tagged(3) as RunID, of: child)

        XCTAssertNil(root.validationError)
        XCTAssertNil(child.validationError)
        XCTAssertNil(retry.validationError)
        XCTAssertEqual(retry.rootRunID, root.runID)
        XCTAssertEqual(retry.parentRunID, child.parentRunID)
        XCTAssertEqual(retry.retryOfRunID, child.runID)
        XCTAssertEqual(retry.generation, child.generation + 1)

        let cancellation = CancellationLineage(
            scopeID: tagged(11),
            parentScopeID: tagged(10)
        )
        try assertRoundTrip(cancellation)
    }

    func testFeatureSetCanonicalizesDuplicatesAndOrdering() {
        let features = AgentFeatureSet(["worker", "tools", "worker", "memory"])
        XCTAssertEqual(features.values, ["memory", "tools", "worker"])
        XCTAssertTrue(features.contains("tools"))
        XCTAssertFalse(features.contains("browser"))
    }

    func testBudgetTracksExactIntegerUsageAndRejectsArithmeticOverflow() throws {
        let limits = AgentBudgetLimits(
            iterations: .max,
            providerAttempts: .max,
            retries: .max,
            toolInvocations: .max,
            inputTokens: .max,
            outputTokens: .max,
            elapsedMilliseconds: .max,
            costMicrounits: .max,
            childRuns: .max,
            childDepth: .max
        )
        let budget = AgentBudget(
            limits: limits,
            usage: AgentBudgetUsage(inputTokens: UInt64.max - 1)
        )
        let atLimit = try budget.applying(AgentBudgetUsage(inputTokens: 1))
        XCTAssertEqual(atLimit.usage.inputTokens, UInt64.max)
        XCTAssertEqual(atLimit.exhaustedDimensions, [.inputTokens])
        XCTAssertThrowsError(try atLimit.applying(AgentBudgetUsage(inputTokens: 1))) { error in
            XCTAssertEqual(
                error as? AgentBudgetArithmeticError,
                .overflow(.inputTokens)
            )
        }
    }

    func testToolInvocationProviderCallIdentityIsBackwardCompatibleAndOptional() throws {
        let legacy = ToolInvocation(
            callID: tagged(31),
            modelAttemptID: tagged(32),
            tool: ToolIdentity(name: "read_file", version: "1.0.0"),
            arguments: .object(["path": .string("README.md")]),
            canonicalArgumentDigest: "sha256:arguments",
            idempotencyKey: "legacy-invocation",
            effectClass: .readOnlyLocal,
            locality: .onDevice
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let legacyData = try encoder.encode(legacy)
        let legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        )
        XCTAssertNil(legacyObject["providerCallID"])
        XCTAssertNil(try JSONDecoder().decode(ToolInvocation.self, from: legacyData).providerCallID)

        let current = ToolInvocation(
            callID: legacy.callID,
            providerCallID: "call_provider_31",
            modelAttemptID: legacy.modelAttemptID,
            tool: legacy.tool,
            arguments: legacy.arguments,
            canonicalArgumentDigest: legacy.canonicalArgumentDigest,
            idempotencyKey: legacy.idempotencyKey,
            effectClass: legacy.effectClass,
            locality: legacy.locality
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ToolInvocation.self, from: encoder.encode(current)),
            current
        )
    }

    private func assertRoundTrip<Value: Codable & Equatable>(
        _ value: Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(value)
        let second = try encoder.encode(value)
        XCTAssertEqual(first, second, file: file, line: line)
        XCTAssertEqual(
            try JSONDecoder().decode(Value.self, from: first),
            value,
            file: file,
            line: line
        )
    }
}

private struct Fixture {
    let instant = AgentInstant(rawValue: 1_750_000_000_000)
    let commandID: CommandID = tagged(20)
    let eventID: EventID = tagged(21)
    let correlationID: CorrelationID = tagged(22)
    let causationID: CausationID = tagged(23)
    let context: AgentRunContext
    let userItem: ModelItem

    init() {
        let runID: RunID = tagged(1)
        let acceptedAt = AgentInstant(rawValue: 1_750_000_000_000)
        context = AgentRunContext(
            schemaVersion: .v1,
            lineage: .root(runID),
            conversationID: tagged(2),
            projectID: tagged(3),
            workspaceID: tagged(4),
            executionNodeID: tagged(5),
            engineVersion: .agentHarnessV1,
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["typed-events", "pure-reducer"]),
            cancellation: CancellationLineage(scopeID: tagged(6)),
            initialBudget: AgentBudget(limits: .standard)
        )
        userItem = ModelItem(
            id: tagged(7),
            createdAt: acceptedAt,
            payload: .message(
                ModelMessage(role: .user, content: [.text("Build the feature")])
            )
        )
    }
}

private func tagged<Tag: AgentIdentifierTag>(_ value: UInt64) -> AgentIdentifier<Tag> {
    let suffix = String(format: "%012llX", value)
    return AgentIdentifier(rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!)
}
