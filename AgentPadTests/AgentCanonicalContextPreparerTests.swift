import AgentDomain
import AgentEngine
import AgentProviders
import AgentTools
import Foundation
import XCTest
@testable import NovaForge

final class AgentCanonicalContextPreparerTests: XCTestCase {
    func testDeterministicPreparationPreservesEverySupportedContentKind() async throws {
        let fixture = CanonicalContextFixture(seed: 1)
        let artifact = ArtifactReference(
            artifactID: canonicalTagged(101),
            mediaType: "application/json",
            contentDigest: canonicalDigest(character: "a"),
            displayName: "report.json"
        )
        let userID: ModelItemID = canonicalTagged(102)
        let reasoningID: ModelItemID = canonicalTagged(103)
        let checkpointItemID: ModelItemID = canonicalTagged(104)
        let checkpoint = ContextCheckpointReference(
            checkpointID: canonicalTagged(105),
            schemaVersion: .current,
            summary: "The user requested a deterministic report.",
            sourceItemIDs: [userID],
            sourceDigest: canonicalDigest(character: "b")
        )
        let items = [
            ModelItem(
                id: userID,
                createdAt: AgentInstant(rawValue: 1_001),
                payload: .message(ModelMessage(
                    role: .user,
                    content: [
                        .text("Create the report."),
                        .structured(.object([
                            "format": .string("json"),
                            "retries": .number(.integer(2)),
                        ])),
                        .image(ModelImageReference(
                            mediaType: "image/png",
                            contentDigest: canonicalDigest(character: "c"),
                            detail: "high"
                        )),
                        .artifact(artifact),
                    ]
                ))
            ),
            ModelItem(
                id: reasoningID,
                createdAt: AgentInstant(rawValue: 1_002),
                payload: .reasoningSummary(ReasoningSummary(
                    text: "Use the requested schema and retain the artifact reference.",
                    providerReference: "response_001"
                ))
            ),
            ModelItem(
                id: checkpointItemID,
                createdAt: AgentInstant(rawValue: 1_003),
                payload: .contextCheckpoint(checkpoint)
            ),
        ]
        let state = fixture.state(
            modelItems: items,
            artifacts: [artifact],
            checkpoints: [checkpoint]
        )
        let preparer = try fixture.preparer()

        let first = try await preparer.prepareProviderTurn(state: state, tools: [])
        let second = try await preparer.prepareProviderTurn(state: state, tools: [])

        XCTAssertEqual(first.request, second.request)
        XCTAssertEqual(first.contextDigest, second.contextDigest)
        XCTAssertEqual(first.estimatedTokens, second.estimatedTokens)
        XCTAssertEqual(first.itemIDs, [userID, reasoningID, checkpointItemID])
        XCTAssertEqual(first.preferredAdapterIDs.map(\.rawValue), [
            "openai-responses-primary",
            "openai-chat-fallback",
        ])
        XCTAssertEqual(
            first.request.requestID,
            "novaforge:\(fixture.context.lineage.runID):provider-turn:3"
        )
        XCTAssertEqual(first.request.messages.map(\.role), [
            .system,
            .developer,
            .developer,
            .user,
            .assistant,
            .developer,
        ])
        XCTAssertEqual(first.request.messages[3].content.count, 4)
        guard case let .structured(structured) = first.request.messages[3].content[1],
              case let .image(image) = first.request.messages[3].content[2],
              case let .structured(artifactValue) = first.request.messages[3].content[3]
        else {
            return XCTFail("Every user content part must retain its canonical type")
        }
        XCTAssertEqual(structured, .object([
            "format": .string("json"),
            "retries": .number(.integer(2)),
        ]))
        XCTAssertEqual(image.source, canonicalDigest(character: "c"))
        XCTAssertEqual(image.mediaType, "image/png")
        XCTAssertEqual(
            artifactValue,
            .object([
                "kind": .string("artifact_reference"),
                "artifact_id": .string(artifact.artifactID.description),
                "media_type": .string("application/json"),
                "content_digest": .string(canonicalDigest(character: "a")),
                "display_name": .string("report.json"),
            ])
        )
        let supplement = try text(from: first.request.messages[2])
        let reasoning = try text(from: first.request.messages[4])
        let checkpointText = try text(from: first.request.messages[5])
        XCTAssertTrue(supplement.contains("novaforge_context_supplement_v1"))
        XCTAssertTrue(supplement.contains(artifact.artifactID.description))
        XCTAssertTrue(reasoning.contains("reasoning_summary"))
        XCTAssertTrue(reasoning.contains("response_001"))
        XCTAssertTrue(checkpointText.contains("context_checkpoint"))
        XCTAssertTrue(checkpointText.contains(checkpoint.checkpointID.description))

        let metadata = try canonicalJSONString(first.request.metadata)
        XCTAssertFalse(metadata.contains("Create the report"))
        XCTAssertFalse(metadata.contains("report.json"))
        XCTAssertEqual(first.request.tools, [])
        XCTAssertEqual(first.toolLocalities, [:])
    }

    func testSingleToolEnvelopeUsesExactProviderCallIDAndLosslessResult() async throws {
        let fixture = CanonicalContextFixture(seed: 2)
        let descriptor = try readFileDescriptor()
        let attemptID: AttemptID = canonicalTagged(201)
        let invocationItemID: ModelItemID = canonicalTagged(202)
        let resultItemID: ModelItemID = canonicalTagged(203)
        let callID: ToolCallID = canonicalTagged(204)
        let arguments: JSONValue = .object(["path": .string("notes.txt")])
        let invocation = ToolInvocation(
            callID: callID,
            providerCallID: "call_provider_exact_204",
            modelAttemptID: attemptID,
            tool: descriptor.identity,
            arguments: arguments,
            canonicalArgumentDigest: try descriptor.canonicalArgumentDigest(for: arguments),
            idempotencyKey: "idempotency_204",
            effectClass: descriptor.effectClass,
            locality: .onDevice
        )
        let artifact = ArtifactReference(
            artifactID: canonicalTagged(205),
            mediaType: "text/plain",
            contentDigest: canonicalDigest(character: "d"),
            displayName: "notes.txt"
        )
        let result = ToolResult(
            modelItemID: resultItemID,
            callID: callID,
            status: .succeeded,
            output: .object([
                "content": .string("hello"),
                "line_count": .number(.integer(1)),
            ]),
            artifacts: [artifact],
            evidence: [ToolEvidence(
                kind: "read",
                digest: canonicalDigest(character: "e"),
                metadata: .object(["bounded": .bool(true)])
            )],
            warnings: ["UTF-8 normalized"]
        )
        let items = [
            fixture.userItem(id: canonicalTagged(206)),
            ModelItem(
                id: invocationItemID,
                createdAt: AgentInstant(rawValue: 2_001),
                payload: .toolInvocation(invocation)
            ),
            ModelItem(
                id: resultItemID,
                createdAt: AgentInstant(rawValue: 2_002),
                payload: .toolResult(result)
            ),
        ]
        let attempt = try fixture.committedAttempt(
            id: attemptID,
            ordinal: 1,
            finishReason: .toolCalls
        )
        let state = fixture.state(
            modelItems: items,
            modelAttempts: [attempt],
            tools: [ToolExecutionState(
                invocation: invocation,
                status: .completed,
                result: result
            )]
        )
        let preparer = try fixture.preparer(
            toolLocalities: [descriptor.name: .onDevice]
        )

        let prepared = try await preparer.prepareProviderTurn(
            state: state,
            tools: [descriptor]
        )

        let assistantToolMessage = try XCTUnwrap(
            prepared.request.messages.first(where: { message in
                message.content.contains(where: {
                    if case .toolCall = $0 { return true }
                    return false
                })
            })
        )
        guard case let .toolCall(call) = assistantToolMessage.content[0] else {
            return XCTFail("Invocation must remain a provider tool-call part")
        }
        XCTAssertEqual(assistantToolMessage.role, .assistant)
        XCTAssertEqual(call.callID, "call_provider_exact_204")
        XCTAssertEqual(call.name, "read_file")
        XCTAssertEqual(call.arguments, arguments)

        let providerResult = try XCTUnwrap(
            prepared.request.messages.first(where: { $0.role == .tool })
        )
        XCTAssertEqual(providerResult.toolCallID, "call_provider_exact_204")
        XCTAssertNil(providerResult.name)
        let providerResultText = try text(from: providerResult)
        XCTAssertTrue(providerResultText.contains("\"kind\":\"tool_result\""))
        XCTAssertTrue(
            providerResultText.lowercased().contains(resultItemID.description)
        )
        XCTAssertTrue(providerResultText.contains("UTF-8 normalized"))
        XCTAssertEqual(prepared.request.tools, [AgentProviders.ProviderToolDefinition(
            name: descriptor.name,
            description: descriptor.description,
            parameters: descriptor.argumentSchema.strictProviderValue,
            strict: true
        )])
        XCTAssertEqual(prepared.toolLocalities, ["read_file": .onDevice])
    }

    func testMultipleCallsFromOneAttemptFailWithTypedProvenanceBlocker() async throws {
        let fixture = CanonicalContextFixture(seed: 3)
        let descriptor = try readFileDescriptor()
        let attemptID: AttemptID = canonicalTagged(301)
        let first = try toolRound(
            seed: 310,
            providerCallID: "call_provider_310",
            attemptID: attemptID,
            descriptor: descriptor
        )
        let second = try toolRound(
            seed: 320,
            providerCallID: "call_provider_320",
            attemptID: attemptID,
            descriptor: descriptor
        )
        let state = fixture.state(
            modelItems: [
                fixture.userItem(id: canonicalTagged(302)),
                first.invocationItem,
                second.invocationItem,
                first.resultItem,
                second.resultItem,
            ],
            modelAttempts: [try fixture.committedAttempt(
                id: attemptID,
                ordinal: 1,
                finishReason: .toolCalls
            )],
            tools: [first.execution, second.execution]
        )
        let preparer = try fixture.preparer(
            toolLocalities: [descriptor.name: .onDevice]
        )

        await assertCanonicalContextError(
            .multiToolAssistantEnvelopeProvenanceUnavailable(attemptID)
        ) {
            try await preparer.prepareProviderTurn(
                state: state,
                tools: [descriptor]
            )
        }
    }

    func testContextAndProviderReadyStateAreExactFailClosedBoundaries() async throws {
        let fixture = CanonicalContextFixture(seed: 4)
        let user = fixture.userItem(id: canonicalTagged(401))
        let preparer = try fixture.preparer()
        var wrongContextState = fixture.state(modelItems: [user])
        wrongContextState.context = CanonicalContextFixture(seed: 40).context

        await assertCanonicalContextError(.runContextMismatch) {
            try await preparer.prepareProviderTurn(
                state: wrongContextState,
                tools: []
            )
        }

        var nonReady = fixture.state(modelItems: [user])
        nonReady.phase = .awaitingApproval
        await assertCanonicalContextError(.stateNotProviderReady(.awaitingApproval)) {
            try await preparer.prepareProviderTurn(state: nonReady, tools: [])
        }
    }

    func testMissingProviderCallIDAndLocalityMapMismatchNeverFlattenTranscript() async throws {
        let fixture = CanonicalContextFixture(seed: 5)
        let descriptor = try readFileDescriptor()
        let attemptID: AttemptID = canonicalTagged(501)
        let callID: ToolCallID = canonicalTagged(502)
        let arguments: JSONValue = .object(["path": .string("unsafe.txt")])
        let invocation = ToolInvocation(
            callID: callID,
            providerCallID: nil,
            modelAttemptID: attemptID,
            tool: descriptor.identity,
            arguments: arguments,
            canonicalArgumentDigest: try descriptor.canonicalArgumentDigest(for: arguments),
            idempotencyKey: "idempotency_502",
            effectClass: descriptor.effectClass,
            locality: .onDevice
        )
        let state = fixture.state(
            modelItems: [
                fixture.userItem(id: canonicalTagged(503)),
                ModelItem(
                    id: canonicalTagged(504),
                    createdAt: AgentInstant(rawValue: 5_001),
                    payload: .toolInvocation(invocation)
                ),
            ],
            modelAttempts: [try fixture.committedAttempt(
                id: attemptID,
                ordinal: 1,
                finishReason: .toolCalls
            )]
        )
        let preparer = try fixture.preparer(
            toolLocalities: [descriptor.name: .onDevice]
        )
        await assertCanonicalContextError(.missingProviderCallID(callID)) {
            try await preparer.prepareProviderTurn(
                state: state,
                tools: [descriptor]
            )
        }

        let ordinaryState = fixture.state(modelItems: [fixture.userItem(
            id: canonicalTagged(505)
        )])
        await assertCanonicalContextError(.toolLocalityMapMismatch) {
            try await preparer.prepareProviderTurn(state: ordinaryState, tools: [])
        }
    }

    func testDuplicateItemAndTextCapAreRejectedBeforeDispatch() async throws {
        let fixture = CanonicalContextFixture(seed: 6)
        let duplicateID: ModelItemID = canonicalTagged(601)
        let duplicateState = fixture.state(modelItems: [
            fixture.userItem(id: duplicateID, text: "first"),
            fixture.userItem(id: duplicateID, text: "second"),
        ])
        let preparer = try fixture.preparer()
        await assertCanonicalContextError(.duplicateModelItemID(duplicateID)) {
            try await preparer.prepareProviderTurn(
                state: duplicateState,
                tools: []
            )
        }

        let tinyLimits = AgentCanonicalContextLimits(
            maximumTextPartUTF8Bytes: 4,
            maximumInstructionUTF8Bytes: 4
        )
        let tinyPreparer = try fixture.preparer(
            systemInstruction: nil,
            developerInstruction: nil,
            limits: tinyLimits
        )
        let oversized = fixture.state(modelItems: [fixture.userItem(
            id: canonicalTagged(602),
            text: "12345"
        )])
        await assertCanonicalContextError(
            .limitExceeded(.textPartUTF8Bytes, actual: 5, limit: 4)
        ) {
            try await tinyPreparer.prepareProviderTurn(
                state: oversized,
                tools: []
            )
        }
    }

    func testAttestedLocalToolSchemasDoNotConsumeGGUFMessageContext() async throws {
        let fixture = CanonicalContextFixture(seed: 8)
        let registry = try SandboxToolCatalog.localAgentRegistry()
        let toolLocalities = Dictionary(
            uniqueKeysWithValues: registry.descriptors.map {
                ($0.name, ToolExecutionLocality.onDevice)
            }
        )
        let preparer = try AgentCanonicalContextPreparer(configuration:
            AgentCanonicalContextConfiguration(
                context: fixture.context,
                providerID: ProviderID(rawValue: "novaforge-local"),
                model: ProviderModelID(
                    rawValue: LocalModelCatalog.defaultVariant.id
                ),
                preferredAdapterIDs: [
                    ProviderAdapterID(rawValue: "novaforge-local-llama")
                ],
                options: ProviderGenerationOptions(
                    maximumOutputTokens: 160,
                    temperature: 0.05,
                    parallelToolCalls: false,
                    toolChoice: .auto,
                    minimumContextWindowTokens: 1_024
                ),
                toolLocalities: toolLocalities
            )
        )
        let state = fixture.state(modelItems: [fixture.userItem(
            id: canonicalTagged(801),
            text: "Build a responsive snake game."
        )])

        let prepared = try await preparer.prepareProviderTurn(
            state: state,
            tools: registry.descriptors
        )

        XCTAssertEqual(prepared.request.tools.count, registry.descriptors.count)
        XCTAssertLessThanOrEqual(prepared.estimatedTokens + 160, 1_024)
    }

    func testPreCancelledPreparationPropagatesCancellation() async throws {
        let fixture = CanonicalContextFixture(seed: 7)
        let preparer = try fixture.preparer()
        let state = fixture.state(modelItems: [fixture.userItem(
            id: canonicalTagged(701)
        )])
        let task = Task {
            withUnsafeCurrentTask { current in
                current?.cancel()
            }
            return try await preparer.prepareProviderTurn(
                state: state,
                tools: []
            )
        }
        do {
            _ = try await task.value
            XCTFail("A pre-cancelled preparation unexpectedly completed")
        } catch is CancellationError {
            // Expected: the authority performs no provider, tool, or filesystem work.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct CanonicalContextFixture {
    let context: AgentRunContext
    let lastEventID: EventID

    init(seed: UInt64) {
        let base = seed * 10_000
        let runID: RunID = canonicalTagged(base + 1)
        context = AgentRunContext(
            lineage: .root(runID),
            conversationID: canonicalTagged(base + 2),
            projectID: canonicalTagged(base + 3),
            workspaceID: canonicalTagged(base + 4),
            executionNodeID: canonicalTagged(base + 5),
            engineVersion: .agentHarnessV2,
            acceptedAt: AgentInstant(rawValue: Int64(base)),
            features: AgentFeatureSet(["canonical_context", "hermes_baseline"]),
            cancellation: CancellationLineage(scopeID: canonicalTagged(base + 6)),
            initialBudget: AgentBudget(limits: .standard)
        )
        lastEventID = canonicalTagged(base + 7)
    }

    func preparer(
        toolLocalities: [String: ToolExecutionLocality] = [:],
        systemInstruction: String? = "You are NovaForge.",
        developerInstruction: String? = "Preserve canonical transcript order.",
        limits: AgentCanonicalContextLimits = .production
    ) throws -> AgentCanonicalContextPreparer {
        try AgentCanonicalContextPreparer(configuration:
            AgentCanonicalContextConfiguration(
                context: context,
                providerID: ProviderID(rawValue: "openai"),
                model: ProviderModelID(rawValue: "gpt-5-hermes"),
                preferredAdapterIDs: [
                    ProviderAdapterID(rawValue: "openai-responses-primary"),
                    ProviderAdapterID(rawValue: "openai-chat-fallback"),
                ],
                options: ProviderGenerationOptions(
                    maximumOutputTokens: 16_384,
                    temperature: 0.2,
                    parallelToolCalls: false,
                    toolChoice: .auto,
                    reasoningSummary: true,
                    promptCacheKey: "novaforge-cache-\(context.lineage.runID)",
                    minimumContextWindowTokens: 128_000
                ),
                systemInstruction: systemInstruction,
                developerInstruction: developerInstruction,
                toolLocalities: toolLocalities,
                limits: limits
            )
        )
    }

    func state(
        modelItems: [ModelItem],
        modelAttempts: [ModelAttemptState] = [],
        tools: [ToolExecutionState] = [],
        artifacts: [ArtifactReference] = [],
        checkpoints: [ContextCheckpointReference] = []
    ) -> AgentDomain.AgentRunState {
        AgentDomain.AgentRunState(
            context: context,
            phase: .running,
            lastSequence: EventSequence(rawValue: 3),
            lastEventID: lastEventID,
            appliedEventIDs: [lastEventID],
            budget: context.initialBudget,
            modelItems: modelItems,
            modelAttempts: modelAttempts,
            tools: tools,
            artifacts: artifacts,
            checkpoints: checkpoints
        )
    }

    func userItem(
        id: ModelItemID,
        text: String = "Inspect the workspace."
    ) -> ModelItem {
        ModelItem(
            id: id,
            createdAt: context.acceptedAt,
            payload: .message(ModelMessage(role: .user, content: [.text(text)]))
        )
    }

    func committedAttempt(
        id: AttemptID,
        ordinal: UInt32,
        finishReason: ModelFinishReason
    ) throws -> ModelAttemptState {
        ModelAttemptState(
            attemptID: id,
            route: ModelRoute(
                provider: "openai",
                model: "gpt-5-hermes",
                adapter: "openai-responses-primary"
            ),
            providerAttempt: .recordedV1_1(
                requestDigest: try AgentCanonicalSHA256Digest(
                    canonicalDigest(character: "f")
                ),
                scope: try ProviderAttemptScopeReference(
                    requestID: "request-\(ordinal)",
                    attemptID: "attempt-\(ordinal)"
                ),
                ordinal: ordinal,
                recoverySeed: UInt64(ordinal)
            ),
            status: .responseCommitted,
            usage: ModelUsage(inputTokens: 100, outputTokens: 20),
            finishReason: finishReason
        )
    }
}

private struct CanonicalToolRound {
    let invocationItem: ModelItem
    let resultItem: ModelItem
    let execution: ToolExecutionState
}

private func toolRound(
    seed: UInt64,
    providerCallID: String,
    attemptID: AttemptID,
    descriptor: ToolDescriptor
) throws -> CanonicalToolRound {
    let callID: ToolCallID = canonicalTagged(seed + 1)
    let invocationItemID: ModelItemID = canonicalTagged(seed + 2)
    let resultItemID: ModelItemID = canonicalTagged(seed + 3)
    let arguments: JSONValue = .object([
        "path": .string("file-\(seed).txt"),
    ])
    let invocation = ToolInvocation(
        callID: callID,
        providerCallID: providerCallID,
        modelAttemptID: attemptID,
        tool: descriptor.identity,
        arguments: arguments,
        canonicalArgumentDigest: try descriptor.canonicalArgumentDigest(for: arguments),
        idempotencyKey: "idempotency-\(seed)",
        effectClass: descriptor.effectClass,
        locality: .onDevice
    )
    let result = ToolResult(
        modelItemID: resultItemID,
        callID: callID,
        status: .succeeded,
        output: .object(["content": .string("ok")])
    )
    return CanonicalToolRound(
        invocationItem: ModelItem(
            id: invocationItemID,
            createdAt: AgentInstant(rawValue: Int64(seed)),
            payload: .toolInvocation(invocation)
        ),
        resultItem: ModelItem(
            id: resultItemID,
            createdAt: AgentInstant(rawValue: Int64(seed + 1)),
            payload: .toolResult(result)
        ),
        execution: ToolExecutionState(
            invocation: invocation,
            status: .completed,
            result: result
        )
    )
}

private func readFileDescriptor() throws -> ToolDescriptor {
    try SandboxToolCatalog.canonicalRegistry().descriptor(named: "read_file")
}

private func text(from message: ProviderMessage) throws -> String {
    guard message.content.count == 1,
          case let .text(text) = message.content[0] else {
        throw CanonicalContextTestError.expectedText
    }
    return text
}

private func canonicalJSONString(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func assertCanonicalContextError<T: Sendable>(
    _ expected: AgentCanonicalContextPreparerError,
    operation: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected canonical context error", file: file, line: line)
    } catch let error as AgentCanonicalContextPreparerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private func canonicalDigest(character: Character) -> String {
    "sha256:" + String(repeating: character, count: 64)
}

private func canonicalUUID(_ value: UInt64) -> UUID {
    UUID(
        uuidString: String(
            format: "00000000-0000-0000-0000-%012llX",
            value
        )
    )!
}

private func canonicalTagged<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    AgentIdentifier(rawValue: canonicalUUID(value))
}

private enum CanonicalContextTestError: Error {
    case expectedText
}
