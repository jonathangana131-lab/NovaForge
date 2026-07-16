import AgentDomain
import AgentProviders
import AgentTools
import Foundation

enum AgentLocalModelInferenceRole: String, Equatable, Sendable {
    case system
    case developer
    case user
    case assistant
}

struct AgentLocalModelInferenceMessage: Equatable, Sendable {
    let role: AgentLocalModelInferenceRole
    let content: String
}

struct AgentLocalModelInferenceRequest: Equatable, Sendable {
    let scope: ProviderAttemptScope
    let modelID: String
    let messages: [AgentLocalModelInferenceMessage]
    let temperature: Double
    let maximumOutputTokens: UInt64
}

enum AgentLocalModelInferenceFinishReason: Equatable, Sendable {
    case completed
    case length
}

enum AgentLocalModelInferenceEvent: Equatable, Sendable {
    case text(String)
    case usage(generatedTokenCount: UInt64)
    case completed(reason: AgentLocalModelInferenceFinishReason)
}

/// The only app-side seam between the canonical provider transport and llama.
/// It has no URL, credential, tool, image, or untyped request input.
protocol AgentLocalModelInferenceStreaming: Sendable {
    func stream(
        request: AgentLocalModelInferenceRequest,
        onEvent: @escaping @Sendable (AgentLocalModelInferenceEvent) async throws -> Void
    ) async throws

    func stop(request: AgentLocalModelInferenceRequest) async
}

/// Separate capability used only by the attested local-agent route. Plain
/// local text inference cannot accidentally advertise or emit tool calls.
protocol AgentLocalModelActionPlanning: Sendable {
    func decideLocalAgentTurn(
        request: AgentLocalModelInferenceRequest,
        completedToolCallCount: Int
    ) async throws -> LocalAgentModelDecision
}

/// Production local inference proves the exact on-disk model bytes before the
/// transport may emit text or even a deterministic tool call. Test inference
/// seams intentionally omit this capability and cannot be constructed by the
/// app's production composition.
protocol AgentLocalModelArtifactVerifying: Sendable {
    func verifyLocalModelArtifact(modelID: String) async throws
}

enum AgentLocalModelProviderTransportError: Error, Equatable, Sendable {
    case invalidDescriptor
    case invalidScope
    case scopeAlreadyConsumed
    case attemptRegistryCapacityExceeded
    case modelBusy
    case invalidRequestEnvelope
    case requestModelMismatch
    case inputLimitExceeded
    case duplicateUsage
    case missingUsage
    case invalidUsage
    case duplicateCompletion
    case missingCompletion
    case outputAfterUsage
    case eventAfterCompletion
    case invalidWireSequence
    case consumerBackpressureExceeded
    case inferenceFailed
}

private struct AgentLocalModelToolMode: Sendable {
    let capability: LocalModelSingleCallToolsProviderCapability
    let toolRegistry: ToolRegistry
    let workspace: SandboxWorkspace
    let encodedToolDefinitions: JSONValue
}

private struct AgentLocalModelParsedRequest: Sendable {
    let inference: AgentLocalModelInferenceRequest
    let latestUserPrompt: String
    let completedToolCallCount: Int
    let completedToolResults: [AgentLocalModelCompletedToolResult]
}

private struct AgentLocalModelCompletedToolResult: Sendable {
    let name: String
    let status: ToolResultStatus
    let errorCode: String?
    let contextSummary: String
}

private struct AgentLocalModelHistoricalToolCall: Sendable {
    let callID: String
    let name: String
}

private struct AgentLocalModelUnboundToolResult: Sendable {
    let callID: String
    let declaredName: String?
    let status: ToolResultStatus
    let errorCode: String?
    let contextSummary: String
}

/// Credential-free transport for package-sealed local text and agent lanes.
///
/// This boundary deliberately accepts only the exact descriptor generated for
/// a shipped `LocalModelCatalog` variant. The model file URL is resolved later
/// by `LocalModelClient`; callers can neither provide nor redirect it.
final class AgentLocalModelProviderTransport: ProviderTransport, Sendable {
    private static let requestPath = "/v1/local/chat/completions"
    private static let maximumMessages = 64
    private static let maximumBufferedFrames = 128
    static let maximumConsumedScopes = 16_384

    private let inference: any AgentLocalModelInferenceStreaming
    private let attempts: AgentLocalModelAttemptRegistry
    private let toolMode: AgentLocalModelToolMode?

    convenience init() {
        self.init(
            inference: LocalModelClient.shared,
            maximumConsumedScopes: Self.maximumConsumedScopes
        )
    }

    private static func finishDeterministicPlan(
        _ plan: LocalAgentPlan,
        completedToolResults: [AgentLocalModelCompletedToolResult],
        toolMode: AgentLocalModelToolMode,
        driver: AgentLocalModelWireAttemptDriver
    ) async throws -> [ProviderWireFrame] {
        let completedToolCallCount = completedToolResults.count
        guard completedToolCallCount >= 0,
              completedToolCallCount <= plan.toolCalls.count else {
            throw AgentLocalModelProviderTransportError
                .invalidRequestEnvelope
        }
        for (index, result) in completedToolResults.enumerated() {
            guard result.name == plan.toolCalls[index].function.name,
                  result.status == .succeeded else {
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
        }
        guard completedToolCallCount < plan.toolCalls.count else {
            return try await driver.finishDeterministicText(plan.completion)
        }

        let call = plan.toolCalls[completedToolCallCount]
        guard call.type == "function",
              isSafeIdentity(call.id, maximumUTF8Count: 256),
              isSafeIdentity(
                  call.function.name,
                  maximumUTF8Count: 128
              ),
              let argumentsData = call.function.arguments.data(
                  using: .utf8
              ),
              case let arguments = try JSONDecoder().decode(
                  JSONValue.self,
                  from: argumentsData
              ),
              case .object = arguments
        else {
            throw AgentLocalModelProviderTransportError
                .invalidRequestEnvelope
        }
        do {
            _ = try toolMode.toolRegistry.decode(
                name: call.function.name,
                arguments: arguments
            )
        } catch {
            throw AgentLocalModelProviderTransportError
                .invalidRequestEnvelope
        }
        return try await driver.finishDeterministicTool(
            callID: call.id,
            name: call.function.name,
            arguments: arguments,
            preface: completedToolCallCount == 0 ? plan.intro : nil
        )
    }

    private static func stoppedAfterFailedTool(
        _ result: AgentLocalModelCompletedToolResult,
        driver: AgentLocalModelWireAttemptDriver
    ) async throws -> [ProviderWireFrame] {
        let text: String
        if result.errorCode == "approval_rejected" {
            text = "I stopped because that \(result.name) action was not approved. No later actions ran."
        } else if result.status == .cancelled {
            text = "I stopped because the \(result.name) action was cancelled. No later actions ran."
        } else {
            text = "I stopped because the \(result.name) action failed. No later actions ran."
        }
        return try await driver.finishDeterministicText(text)
    }

    private static func encodedToolDefinitions(
        _ definitions: [AgentTools.ProviderToolDefinition]
    ) -> JSONValue {
        .array(definitions.map { tool in
            .object([
                "type": .string(tool.type),
                "function": .object([
                    "name": .string(tool.function.name),
                    "description": .string(tool.function.description),
                    "parameters": tool.function.parameters,
                    "strict": .bool(tool.function.strict),
                ]),
            ])
        })
    }

    private static func finishModelPlannedTurn(
        _ turn: LocalAgentModelTurn,
        toolMode: AgentLocalModelToolMode,
        driver: AgentLocalModelWireAttemptDriver
    ) async throws -> [ProviderWireFrame] {
        switch turn {
        case let .respond(text):
            return try await driver.finishDeterministicText(text)
        case let .tool(preface, call):
            guard call.type == "function",
                  isSafeIdentity(call.id, maximumUTF8Count: 256),
                  isSafeIdentity(
                      call.function.name,
                      maximumUTF8Count: 128
                  ),
                  let data = call.function.arguments.data(using: .utf8),
                  case let arguments = try JSONDecoder().decode(
                      JSONValue.self,
                      from: data
                  ),
                  case .object = arguments
            else {
                throw AgentLocalModelProviderTransportError
                    .invalidWireSequence
            }
            do {
                _ = try toolMode.toolRegistry.decode(
                    name: call.function.name,
                    arguments: arguments
                )
            } catch {
                throw AgentLocalModelProviderTransportError
                    .invalidWireSequence
            }
            return try await driver.finishDeterministicTool(
                callID: call.id,
                name: call.function.name,
                arguments: arguments,
                preface: preface
            )
        }
    }

    init(
        inference: any AgentLocalModelInferenceStreaming,
        maximumConsumedScopes: Int = AgentLocalModelProviderTransport.maximumConsumedScopes
    ) {
        precondition(maximumConsumedScopes > 0)
        self.inference = inference
        toolMode = nil
        attempts = AgentLocalModelAttemptRegistry(
            maximumConsumedScopes: maximumConsumedScopes
        )
    }

    init(
        inference: any AgentLocalModelInferenceStreaming,
        singleCallToolsCapability: LocalModelSingleCallToolsProviderCapability,
        toolRegistry: ToolRegistry,
        workspace: SandboxWorkspace,
        maximumConsumedScopes: Int = AgentLocalModelProviderTransport.maximumConsumedScopes
    ) {
        precondition(maximumConsumedScopes > 0)
        self.inference = inference
        toolMode = AgentLocalModelToolMode(
            capability: singleCallToolsCapability,
            toolRegistry: toolRegistry,
            workspace: workspace,
            encodedToolDefinitions: Self.encodedToolDefinitions(
                toolRegistry.providerDefinitions()
            )
        )
        attempts = AgentLocalModelAttemptRegistry(
            maximumConsumedScopes: maximumConsumedScopes
        )
    }

    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        try Task.checkCancellation()
        let toolMode = toolMode
        let variant: LocalModelVariant
        do {
            variant = try Self.validateDescriptor(
                descriptor,
                toolMode: toolMode
            )
        } catch {
            Self.recordDebugDiagnostic(
                stage: "validate-descriptor",
                error: error,
                request: request
            )
            throw error
        }
        do {
            try Self.validateScope(scope)
        } catch {
            Self.recordDebugDiagnostic(
                stage: "validate-scope",
                error: error,
                request: request
            )
            throw error
        }
        let parsed: AgentLocalModelParsedRequest
        do {
            parsed = try Self.parse(
                request,
                descriptor: descriptor,
                variant: variant,
                scope: scope,
                toolMode: toolMode
            )
        } catch {
            Self.recordDebugDiagnostic(
                stage: "parse-request",
                error: error,
                request: request
            )
            throw error
        }
        let inferenceRequest = parsed.inference
        if let verifier = inference as?
            any AgentLocalModelArtifactVerifying {
            do {
                try await verifier.verifyLocalModelArtifact(
                    modelID: inferenceRequest.modelID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.recordDebugDiagnostic(
                    stage: "verify-artifact",
                    error: error,
                    request: request
                )
                throw AgentLocalModelProviderTransportError.inferenceFailed
            }
        }
        try await attempts.reserve(
            scope: scope,
            modelID: inferenceRequest.modelID
        )
        do {
            try Task.checkCancellation()
        } catch {
            await attempts.finish(
                scope: scope,
                modelID: inferenceRequest.modelID
            )
            throw error
        }

        let inference = inference
        let attempts = attempts
        let stopGate = AgentLocalModelStopGate()
        let driver: AgentLocalModelWireAttemptDriver
        do {
            driver = try AgentLocalModelWireAttemptDriver(
                descriptor: descriptor,
                request: inferenceRequest,
                inputTokenUpperBound: Self.conservativeInputTokenUpperBound(
                    for: inferenceRequest.messages
                )
            )
        } catch {
            await attempts.finish(
                scope: scope,
                modelID: inferenceRequest.modelID
            )
            throw Self.sanitized(error)
        }

        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedFrames)
        ) { continuation in
            let producer = Task { @Sendable in
                do {
                    try Self.yield(
                        try await driver.begin(),
                        to: continuation
                    )
                    if let toolMode {
                        if let failed = parsed.completedToolResults.first(
                            where: { $0.status != .succeeded }
                        ) {
                            try Self.yield(
                                try await Self.stoppedAfterFailedTool(
                                    failed,
                                    driver: driver
                                ),
                                to: continuation
                            )
                        } else if let plan = LocalAgentPlanner.plan(
                            prompt: parsed.latestUserPrompt,
                            workspace: toolMode.workspace
                        ) {
                            try Self.yield(
                                try await Self.finishDeterministicPlan(
                                    plan,
                                    completedToolResults:
                                        parsed.completedToolResults,
                                    toolMode: toolMode,
                                    driver: driver
                                ),
                                to: continuation
                            )
                        } else if parsed.completedToolCallCount >=
                            LocalAgentModelGrammar.maximumModelPlannedToolCalls
                        {
                            try Self.yield(
                                try await driver.finishDeterministicText(
                                    "I stopped after six local actions so this run stays bounded. Review the completed tool cards, then ask me to continue if needed."
                                ),
                                to: continuation
                            )
                        } else {
                            guard let planner = inference as?
                                any AgentLocalModelActionPlanning else {
                                throw AgentLocalModelProviderTransportError
                                    .invalidDescriptor
                            }
                            let decision = try await planner
                                .decideLocalAgentTurn(
                                    request: inferenceRequest,
                                    completedToolCallCount:
                                        parsed.completedToolCallCount
                                )
                            let turn = try LocalAgentModelGrammar.compile(
                                decision
                            )
                            try Self.yield(
                                try await Self.finishModelPlannedTurn(
                                    turn,
                                    toolMode: toolMode,
                                    driver: driver
                                ),
                                to: continuation
                            )
                        }
                    } else {
                        try await inference.stream(
                            request: inferenceRequest
                        ) { event in
                            try Self.yield(
                                try await driver.receive(event),
                                to: continuation
                            )
                        }
                        try Self.yield(
                            try await driver.finishAfterInference(),
                            to: continuation
                        )
                    }
                    await attempts.finish(
                        scope: scope,
                        modelID: inferenceRequest.modelID
                    )
                    continuation.finish()
                } catch is CancellationError {
                    await Self.stopOnce(
                        stopGate: stopGate,
                        inference: inference,
                        request: inferenceRequest
                    )
                    let cancellationFrames = await driver.cancel()
                    try? Self.yield(cancellationFrames, to: continuation)
                    await attempts.finish(
                        scope: scope,
                        modelID: inferenceRequest.modelID
                    )
                    continuation.finish()
                } catch {
                    Self.recordDebugDiagnostic(
                        stage: "produce-wire-stream",
                        error: error,
                        request: request
                    )
                    await Self.stopOnce(
                        stopGate: stopGate,
                        inference: inference,
                        request: inferenceRequest
                    )
                    await attempts.finish(
                        scope: scope,
                        modelID: inferenceRequest.modelID
                    )
                    continuation.finish(throwing: Self.sanitized(error))
                }
            }
            continuation.onTermination = { @Sendable termination in
                guard case .cancelled = termination else { return }
                producer.cancel()
                Task { @Sendable in
                    await Self.stopOnce(
                        stopGate: stopGate,
                        inference: inference,
                        request: inferenceRequest
                    )
                }
            }
        }
    }

    /// A deliberately conservative upper bound, not a tokenizer estimate.
    /// Every UTF-8 byte can account for at most one ordinary tokenizer token;
    /// sixteen tokens per message plus sixteen fixed tokens cover the shipped
    /// llama chat-template markers. Reporting this upper bound can overcharge
    /// local input, but it never invents false precision or understates usage.
    static func conservativeInputTokenUpperBound(
        for messages: [AgentLocalModelInferenceMessage]
    ) throws -> UInt64 {
        var total: UInt64 = 16
        for message in messages {
            let byteCount = UInt64(message.content.utf8.count)
            let overhead = total.addingReportingOverflow(16)
            guard !overhead.overflow else { throw AgentLocalModelProviderTransportError.inputLimitExceeded }
            let content = overhead.partialValue.addingReportingOverflow(byteCount)
            guard !content.overflow else { throw AgentLocalModelProviderTransportError.inputLimitExceeded }
            total = content.partialValue
        }
        return total
    }

    private static func validateDescriptor(
        _ descriptor: ProviderAdapterDescriptor,
        toolMode: AgentLocalModelToolMode?
    ) throws -> LocalModelVariant {
        guard descriptor.route.deployment == .onDevice,
              descriptor.route.provenance == .builtInLocalModel,
              descriptor.dialect == .openAICompatibleChat,
              descriptor.requestPath == requestPath,
              let variant = LocalModelCatalog.variant(
                  for: descriptor.route.modelID.rawValue
              )
        else {
            throw AgentLocalModelProviderTransportError.invalidDescriptor
        }

        if let toolMode {
            let snapshot = toolMode.capability.snapshot
            guard snapshot.providerID == descriptor.route.providerID,
                  snapshot.modelID == descriptor.route.modelID,
                  snapshot.adapterID == descriptor.route.adapterID,
                  snapshot.dialect == descriptor.dialect,
                  snapshot.requestPath == descriptor.requestPath,
                  snapshot.capabilities == descriptor.route.capabilities,
                  snapshot.deployment == descriptor.route.deployment,
                  snapshot.provenance == descriptor.route.provenance,
                  snapshot.maximumToolDefinitions ==
                    UInt32(toolMode.toolRegistry.descriptors.count),
                  snapshot.maximumToolCallsPerTurn == 1,
                  !snapshot.parallelToolDispatchEnabled
            else {
                throw AgentLocalModelProviderTransportError
                    .invalidDescriptor
            }
        } else {
            let expected: ProviderAdapterDescriptor
            do {
                expected = try LocalModelAdapter(configuration: .init(
                    modelID: descriptor.route.modelID,
                    contextWindowTokens: UInt64(variant.contextTokens),
                    maximumOutputTokens: UInt64(variant.maxNewTokens),
                    toolMode: .textOnly
                )).descriptor
            } catch {
                throw AgentLocalModelProviderTransportError.invalidDescriptor
            }
            guard descriptor == expected else {
                throw AgentLocalModelProviderTransportError.invalidDescriptor
            }
        }
        return variant
    }

    private static func validateScope(_ scope: ProviderAttemptScope) throws {
        guard isSafeIdentity(scope.requestID, maximumUTF8Count: 512),
              isSafeIdentity(scope.attemptID.rawValue, maximumUTF8Count: 512)
        else { throw AgentLocalModelProviderTransportError.invalidScope }
    }

    private static func parse(
        _ request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        variant: LocalModelVariant,
        scope: ProviderAttemptScope,
        toolMode: AgentLocalModelToolMode?
    ) throws -> AgentLocalModelParsedRequest {
        guard request.method == .post,
              request.relativePath == requestPath,
              request.relativePath == descriptor.requestPath,
              case let .object(body) = request.body
        else { throw AgentLocalModelProviderTransportError.invalidRequestEnvelope }

        let requiredKeys: Set<String> = [
            "messages", "metadata", "model", "stream", "stream_options",
        ]
        var allowedKeys = requiredKeys.union([
            "max_completion_tokens", "parallel_tool_calls", "temperature",
        ])
        if toolMode != nil {
            allowedKeys.formUnion(["tool_choice", "tools"])
        }
        guard requiredKeys.isSubset(of: body.keys),
              Set(body.keys).isSubset(of: allowedKeys),
              body["stream"] == .bool(true),
              body["stream_options"] == .object(["include_usage": .bool(true)]),
              body["parallel_tool_calls"] == nil ||
                body["parallel_tool_calls"] == .bool(false)
        else { throw AgentLocalModelProviderTransportError.invalidRequestEnvelope }

        try validateMetadata(
            body["metadata"],
            scope: scope,
            descriptor: descriptor,
            expectedToolCount: toolMode?.toolRegistry.descriptors.count ?? 0
        )

        if let toolMode {
            guard body["tools"] == toolMode.encodedToolDefinitions,
                  body["tool_choice"] == .string("auto")
            else {
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
        } else if body["tools"] != nil || body["tool_choice"] != nil {
            throw AgentLocalModelProviderTransportError
                .invalidRequestEnvelope
        }

        guard let rawModelID = body["model"],
              case let .string(modelID) = rawModelID,
              modelID == descriptor.route.modelID.rawValue,
              modelID == variant.id
        else { throw AgentLocalModelProviderTransportError.requestModelMismatch }

        guard let rawMessageValue = body["messages"],
              case let .array(rawMessages) = rawMessageValue,
              (1 ... maximumMessages).contains(rawMessages.count)
        else { throw AgentLocalModelProviderTransportError.invalidRequestEnvelope }
        let parsedMessages = try rawMessages.map {
            try parseMessage($0, toolMode: toolMode)
        }
        let messages = parsedMessages.map(\.inference)
        guard let latestUserIndex = parsedMessages.lastIndex(where: {
            $0.isUser
        }) else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        let latestUserPrompt = messages[latestUserIndex].content
        var outstandingToolCalls: [String: String] = [:]
        var completedToolResults: [AgentLocalModelCompletedToolResult] = []
        for message in parsedMessages.dropFirst(latestUserIndex + 1) {
            if let call = message.toolCall {
                guard outstandingToolCalls.updateValue(
                    call.name,
                    forKey: call.callID
                ) == nil else {
                    throw AgentLocalModelProviderTransportError
                        .invalidRequestEnvelope
                }
            }
            if let result = message.toolResult {
                guard let name = outstandingToolCalls.removeValue(
                    forKey: result.callID
                ), result.declaredName == nil || result.declaredName == name
                else {
                    throw AgentLocalModelProviderTransportError
                        .invalidRequestEnvelope
                }
                completedToolResults.append(.init(
                    name: name,
                    status: result.status,
                    errorCode: result.errorCode,
                    contextSummary: result.contextSummary
                ))
            }
        }
        guard outstandingToolCalls.isEmpty else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        let completedToolCallCount = completedToolResults.count

        let maximumOutputTokens: UInt64
        if let rawMaximum = body["max_completion_tokens"] {
            maximumOutputTokens = try positiveInteger(rawMaximum)
        } else {
            maximumOutputTokens = descriptor.route.capabilities.maximumOutputTokens
        }
        guard maximumOutputTokens <= descriptor.route.capabilities.maximumOutputTokens,
              maximumOutputTokens <= UInt64(variant.maxNewTokens)
        else { throw AgentLocalModelProviderTransportError.invalidRequestEnvelope }

        let temperature: Double
        if let rawTemperature = body["temperature"] {
            temperature = try finiteDouble(rawTemperature)
        } else {
            temperature = 0.05
        }
        guard (0 ... 2).contains(temperature) else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }

        let inputUpperBound = try conservativeInputTokenUpperBound(for: messages)
        let reserved = inputUpperBound.addingReportingOverflow(maximumOutputTokens)
        guard !reserved.overflow,
              reserved.partialValue <= descriptor.route.capabilities.contextWindowTokens,
              reserved.partialValue <= UInt64(variant.contextTokens)
        else { throw AgentLocalModelProviderTransportError.inputLimitExceeded }

        return AgentLocalModelParsedRequest(
            inference: AgentLocalModelInferenceRequest(
                scope: scope,
                modelID: modelID,
                messages: messages,
                temperature: temperature,
                maximumOutputTokens: maximumOutputTokens
            ),
            latestUserPrompt: latestUserPrompt,
            completedToolCallCount: completedToolCallCount,
            completedToolResults: completedToolResults
        )
    }

    /// Canonical run metadata is provenance carried beside the request. It is
    /// never included in the llama prompt, but the local boundary still binds
    /// its exact shape so arbitrary caller metadata cannot cross the trusted
    /// route. Empty metadata remains valid for package contract probes.
    private static func validateMetadata(
        _ value: JSONValue?,
        scope: ProviderAttemptScope,
        descriptor: ProviderAdapterDescriptor,
        expectedToolCount: Int
    ) throws {
        guard case let .object(metadata)? = value else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        if metadata.isEmpty { return }

        let required: Set<String> = [
            "scheme", "run_id", "conversation_id", "workspace_id",
            "execution_node_id", "event_sequence", "provider_id",
            "item_count", "tool_count",
        ]
        let allowed = required.union(["project_id"])
        guard required.isSubset(of: metadata.keys),
              Set(metadata.keys).isSubset(of: allowed),
              metadata["scheme"] == .string("novaforge_agent_context_v1"),
              metadata["provider_id"] == .string(
                descriptor.route.providerID.rawValue
              ),
              case let .string(runID)? = metadata["run_id"],
              case let .string(conversationID)? = metadata["conversation_id"],
              case let .string(workspaceID)? = metadata["workspace_id"],
              case let .string(executionNodeID)? = metadata["execution_node_id"],
              case let .string(sequenceText)? = metadata["event_sequence"],
              case let .string(itemCountText)? = metadata["item_count"],
              case let .string(toolCountText)? = metadata["tool_count"],
              UUID(uuidString: runID) != nil,
              UUID(uuidString: conversationID) != nil,
              UUID(uuidString: workspaceID) != nil,
              UUID(uuidString: executionNodeID) != nil,
              let sequence = UInt64(sequenceText),
              sequence > 0,
              let itemCount = UInt64(itemCountText),
              itemCount <= UInt64(maximumMessages),
              let toolCount = Int(toolCountText),
              toolCount == expectedToolCount,
              scope.requestID ==
                "novaforge:\(runID):provider-turn:\(sequence)"
        else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        if let project = metadata["project_id"] {
            guard case let .string(projectID) = project,
                  UUID(uuidString: projectID) != nil else {
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
        }
    }

    private struct ParsedMessage {
        let inference: AgentLocalModelInferenceMessage
        let isUser: Bool
        let toolCall: AgentLocalModelHistoricalToolCall?
        let toolResult: AgentLocalModelUnboundToolResult?
    }

    private static func parseMessage(
        _ value: JSONValue,
        toolMode: AgentLocalModelToolMode?
    ) throws -> ParsedMessage {
        guard case let .object(object) = value,
              let rawRoleValue = object["role"],
              case let .string(rawRole) = rawRoleValue
        else { throw AgentLocalModelProviderTransportError.invalidRequestEnvelope }

        if toolMode == nil {
            guard Set(object.keys) == Set(["content", "role"]),
                  let role = AgentLocalModelInferenceRole(
                      rawValue: rawRole
                  ),
                  let rawContent = object["content"]
            else {
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
            let content = try parseTextContent(rawContent)
            return ParsedMessage(
                inference: .init(role: role, content: content),
                isUser: role == .user,
                toolCall: nil,
                toolResult: nil
            )
        }

        guard let toolMode else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        switch rawRole {
        case "system", "developer", "user":
            guard Set(object.keys) == Set(["content", "role"]),
                  let role = AgentLocalModelInferenceRole(
                      rawValue: rawRole
                  ),
                  let rawContent = object["content"]
            else {
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
            return ParsedMessage(
                inference: .init(
                    role: role,
                    content: try parseTextContent(rawContent)
                ),
                isUser: role == .user,
                toolCall: nil,
                toolResult: nil
            )

        case "assistant":
            let allowed = Set(["content", "role", "tool_calls"])
            guard Set(object.keys).isSubset(of: allowed),
                  object["content"] != nil
            else {
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
            var content: String
            var historicalCall: AgentLocalModelHistoricalToolCall?
            if object["content"] == .null {
                content = ""
            } else {
                content = try parseTextContent(object["content"]!)
            }
            if let rawCalls = object["tool_calls"] {
                let summary = try validateToolCallHistory(
                    rawCalls,
                    registry: toolMode.toolRegistry
                )
                let actionContext = "Selected action \(summary.name) with arguments \(Self.boundedContext(summary.argumentsJSON, limit: 600))."
                content = content.isEmpty
                    ? actionContext
                    : "\(content)\n\(actionContext)"
                historicalCall = .init(
                    callID: summary.callID,
                    name: summary.name
                )
            }
            guard !content.isEmpty else {
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
            return ParsedMessage(
                inference: .init(role: .assistant, content: content),
                isUser: false,
                toolCall: historicalCall,
                toolResult: nil
            )

        case "tool":
            let required = Set(["content", "role", "tool_call_id"])
            guard required.isSubset(of: object.keys),
                Set(object.keys).isSubset(of: required.union(["name"])),
                let rawCallID = object["tool_call_id"],
                case let .string(callID) = rawCallID,
                isSafeIdentity(callID, maximumUTF8Count: 256),
                let rawContent = object["content"]
            else {
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
            let declaredName: String?
            if let rawName = object["name"] {
                guard case let .string(name) = rawName,
                      isSafeIdentity(name, maximumUTF8Count: 128),
                      (try? toolMode.toolRegistry.resolve(name)) != nil
                else {
                    throw AgentLocalModelProviderTransportError
                        .invalidRequestEnvelope
                }
                declaredName = name
            } else {
                declaredName = nil
            }
            let resultContent = try parseToolResultContent(rawContent)
            let result = try parseCanonicalToolResult(resultContent)
            let outputContext = try encodedJSON(result.output)
            let errorContext = result.error.map {
                " Error \($0.code): \($0.publicMessage)"
            } ?? ""
            let toolLabel = declaredName.map { "Tool \($0)" }
                ?? "Tool result"
            let context = "\(toolLabel) finished with status \(result.status.rawValue). Output: \(Self.boundedContext(outputContext, limit: 900)).\(errorContext)"
            return ParsedMessage(
                inference: .init(
                    role: .assistant,
                    content: context
                ),
                isUser: false,
                toolCall: nil,
                toolResult: .init(
                    callID: callID,
                    declaredName: declaredName,
                    status: result.status,
                    errorCode: result.error?.code,
                    contextSummary: context
                )
            )

        default:
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
    }

    private static func encodedJSON(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentLocalModelProviderTransportError
                .invalidRequestEnvelope
        }
        return text
    }

    private struct CanonicalToolResultEnvelope: Decodable {
        let kind: String
        let body: ToolResult
    }

    private static func parseCanonicalToolResult(
        _ content: String
    ) throws -> ToolResult {
        guard let data = content.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                  CanonicalToolResultEnvelope.self,
                  from: data
              ),
              envelope.kind == "tool_result" else {
            throw AgentLocalModelProviderTransportError
                .invalidRequestEnvelope
        }
        return envelope.body
    }

    private static func boundedContext(
        _ value: String,
        limit: Int
    ) -> String {
        let sanitized = value.replacingOccurrences(of: "\0", with: "")
        guard sanitized.count > limit else { return sanitized }
        return String(sanitized.prefix(limit)) + "…"
    }

    private static func parseTextContent(_ rawContent: JSONValue) throws -> String {
        let content: String
        switch rawContent {
        case let .string(text):
            content = text
        case let .array(parts):
            guard !parts.isEmpty else {
                throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
            }
            content = try parts.map { part -> String in
                guard case let .object(textPart) = part,
                      Set(textPart.keys) == Set(["text", "type"]),
                      textPart["type"] == .string("text"),
                      let rawText = textPart["text"],
                      case let .string(text) = rawText
                else { throw AgentLocalModelProviderTransportError.invalidRequestEnvelope }
                return text
            }.joined()
        default:
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        guard !content.isEmpty else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        return content
    }

    private static func parseToolResultContent(
        _ rawContent: JSONValue
    ) throws -> String {
        if case .string = rawContent {
            return try parseTextContent(rawContent)
        }
        guard case let .array(parts) = rawContent, !parts.isEmpty else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        return try parts.map { part -> String in
            guard case let .object(object) = part,
                  let rawType = object["type"],
                  case let .string(type) = rawType
            else {
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
            switch type {
            case "text":
                guard Set(object.keys) == Set(["text", "type"]),
                      let rawText = object["text"],
                      case let .string(text) = rawText,
                      !text.isEmpty
                else {
                    throw AgentLocalModelProviderTransportError
                        .invalidRequestEnvelope
                }
                return text
            case "json":
                guard Set(object.keys) == Set(["json", "type"]),
                      object["json"] != nil
                else {
                    throw AgentLocalModelProviderTransportError
                        .invalidRequestEnvelope
                }
                return "Structured local tool result."
            default:
                throw AgentLocalModelProviderTransportError
                    .invalidRequestEnvelope
            }
        }.joined(separator: "\n")
    }

    private static func validateToolCallHistory(
        _ value: JSONValue,
        registry: ToolRegistry
    ) throws -> (callID: String, name: String, argumentsJSON: String) {
        guard case let .array(calls) = value, calls.count == 1,
              let call = calls.first,
              case let .object(object) = call,
              Set(object.keys) == Set(["function", "id", "type"]),
              object["type"] == .string("function"),
              let rawID = object["id"],
              case let .string(callID) = rawID,
              isSafeIdentity(callID, maximumUTF8Count: 256),
              let rawFunction = object["function"],
              case let .object(function) = rawFunction,
              Set(function.keys) == Set(["arguments", "name"]),
              let rawName = function["name"],
              case let .string(name) = rawName,
              let rawArguments = function["arguments"],
              case let .string(argumentsJSON) = rawArguments,
              let data = argumentsJSON.data(using: .utf8),
              case let arguments = try JSONDecoder().decode(
                  JSONValue.self,
                  from: data
              ),
              case .object = arguments
        else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        do {
            _ = try registry.decode(name: name, arguments: arguments)
        } catch {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        return (callID, name, argumentsJSON)
    }

    private static func positiveInteger(_ value: JSONValue) throws -> UInt64 {
        guard case let .number(number) = value else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        switch number {
        case let .unsignedInteger(value) where value > 0:
            return value
        case let .integer(value) where value > 0:
            return UInt64(value)
        case .integer, .unsignedInteger, .floatingPoint:
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
    }

    private static func finiteDouble(_ value: JSONValue) throws -> Double {
        guard case let .number(number) = value else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        let result: Double
        switch number {
        case let .integer(value): result = Double(value)
        case let .unsignedInteger(value): result = Double(value)
        case let .floatingPoint(value): result = value
        }
        guard result.isFinite else {
            throw AgentLocalModelProviderTransportError.invalidRequestEnvelope
        }
        return result
    }

    private static func isSafeIdentity(
        _ value: String,
        maximumUTF8Count: Int
    ) -> Bool {
        guard (1 ... maximumUTF8Count).contains(value.utf8.count),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    private static func yield(
        _ frames: [ProviderWireFrame],
        to continuation: AsyncThrowingStream<ProviderWireFrame, any Error>.Continuation
    ) throws {
        for frame in frames {
            switch continuation.yield(frame) {
            case .enqueued:
                continue
            case .dropped:
                throw AgentLocalModelProviderTransportError.consumerBackpressureExceeded
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw AgentLocalModelProviderTransportError.consumerBackpressureExceeded
            }
        }
    }

    private static func sanitized(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? AgentLocalModelProviderTransportError {
            return error
        }
        return AgentLocalModelProviderTransportError.inferenceFailed
    }

    private static func recordDebugDiagnostic(
        stage: String,
        error: any Error,
        request: ProviderEncodedRequest
    ) {
        #if DEBUG || targetEnvironment(simulator)
        let bodyKeys: String
        if case let .object(body) = request.body {
            bodyKeys = body.keys.sorted().joined(separator: ",")
        } else {
            bodyKeys = "not-an-object"
        }
        // Debug diagnostics are deliberately ephemeral. Persisting a second
        // transport-owned file beside the canonical run journal created an
        // ungoverned writer and retained error strings longer than needed.
        // Emit only bounded request shape and error type; never request values.
        print(
            "NOVAFORGE_LOCAL_TRANSPORT_DIAGNOSTIC " +
                "stage=\(stage) error_type=\(String(reflecting: type(of: error))) " +
                "method=\(request.method.rawValue) path=\(request.relativePath) " +
                "body_keys=\(bodyKeys)"
        )
        #endif
    }

    private static func stopOnce(
        stopGate: AgentLocalModelStopGate,
        inference: any AgentLocalModelInferenceStreaming,
        request: AgentLocalModelInferenceRequest
    ) async {
        guard await stopGate.claim() else { return }
        await inference.stop(request: request)
    }
}

private actor AgentLocalModelAttemptRegistry {
    private let maximumConsumedScopes: Int
    private var consumedScopes: Set<ProviderAttemptScope> = []
    private var activeModels: [String: ProviderAttemptScope] = [:]

    init(maximumConsumedScopes: Int) {
        self.maximumConsumedScopes = maximumConsumedScopes
    }

    func reserve(scope: ProviderAttemptScope, modelID: String) throws {
        guard !consumedScopes.contains(scope) else {
            throw AgentLocalModelProviderTransportError.scopeAlreadyConsumed
        }
        guard activeModels[modelID] == nil else {
            throw AgentLocalModelProviderTransportError.modelBusy
        }
        // The consumed set intentionally lives for the transport's lifetime so
        // an attempt can never be replayed after completion. It is bounded and
        // fails closed rather than evicting an identity that could be reused.
        guard consumedScopes.count < maximumConsumedScopes else {
            throw AgentLocalModelProviderTransportError.attemptRegistryCapacityExceeded
        }
        consumedScopes.insert(scope)
        activeModels[modelID] = scope
    }

    func finish(scope: ProviderAttemptScope, modelID: String) {
        guard activeModels[modelID] == scope else { return }
        activeModels.removeValue(forKey: modelID)
    }
}

private actor AgentLocalModelStopGate {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private actor AgentLocalModelWireAttemptDriver {
    private var wire: LocalModelWireSession
    private let inputTokenUpperBound: UInt64
    private let maximumOutputTokens: UInt64
    private var didBegin = false
    private var didEmitText = false
    private var didReportUsage = false
    private var completionReason: AgentLocalModelInferenceFinishReason?
    private var terminalPublished = false

    init(
        descriptor: ProviderAdapterDescriptor,
        request: AgentLocalModelInferenceRequest,
        inputTokenUpperBound: UInt64
    ) throws {
        wire = try LocalModelWireSession(
            responseID: "local-\(UUID().uuidString.lowercased())",
            descriptor: descriptor,
            requestedMaximumOutputTokens: request.maximumOutputTokens
        )
        self.inputTokenUpperBound = inputTokenUpperBound
        maximumOutputTokens = request.maximumOutputTokens
    }

    func begin() throws -> [ProviderWireFrame] {
        guard !didBegin else {
            throw AgentLocalModelProviderTransportError.invalidWireSequence
        }
        didBegin = true
        do {
            return [try wire.begin()]
        } catch {
            throw AgentLocalModelProviderTransportError.invalidWireSequence
        }
    }

    func receive(_ event: AgentLocalModelInferenceEvent) throws -> [ProviderWireFrame] {
        guard didBegin else {
            throw AgentLocalModelProviderTransportError.invalidWireSequence
        }
        guard completionReason == nil else {
            switch event {
            case .completed:
                throw AgentLocalModelProviderTransportError.duplicateCompletion
            case .text, .usage:
                throw AgentLocalModelProviderTransportError.eventAfterCompletion
            }
        }

        switch event {
        case let .text(text):
            guard !didReportUsage else {
                throw AgentLocalModelProviderTransportError.outputAfterUsage
            }
            guard !text.isEmpty else { return [] }
            didEmitText = true
            do {
                return try wire.text(text).map { [$0] } ?? []
            } catch {
                throw AgentLocalModelProviderTransportError.invalidWireSequence
            }

        case let .usage(generatedTokenCount):
            guard !didReportUsage else {
                throw AgentLocalModelProviderTransportError.duplicateUsage
            }
            guard generatedTokenCount <= maximumOutputTokens,
                  !didEmitText || generatedTokenCount > 0
            else { throw AgentLocalModelProviderTransportError.invalidUsage }
            didReportUsage = true
            do {
                return [try wire.usage(.init(
                    inputTokens: inputTokenUpperBound,
                    outputTokens: generatedTokenCount
                ))]
            } catch {
                throw AgentLocalModelProviderTransportError.invalidUsage
            }

        case let .completed(reason):
            guard didReportUsage else {
                throw AgentLocalModelProviderTransportError.missingUsage
            }
            completionReason = reason
            return []
        }
    }

    func finishAfterInference() throws -> [ProviderWireFrame] {
        guard didReportUsage else {
            throw AgentLocalModelProviderTransportError.missingUsage
        }
        guard let completionReason else {
            throw AgentLocalModelProviderTransportError.missingCompletion
        }
        let canonicalReason: ModelFinishReason = switch completionReason {
        case .completed: .completed
        case .length: .length
        }
        do {
            let frames = try wire.complete(canonicalReason)
            terminalPublished = true
            return frames
        } catch {
            throw AgentLocalModelProviderTransportError.invalidWireSequence
        }
    }

    func finishDeterministicTool(
        callID: String,
        name: String,
        arguments: JSONValue,
        preface: String?
    ) throws -> [ProviderWireFrame] {
        guard didBegin, !terminalPublished, !didReportUsage,
              completionReason == nil else {
            throw AgentLocalModelProviderTransportError.invalidWireSequence
        }
        do {
            var frames: [ProviderWireFrame] = []
            var outputTokens: UInt64 = 0
            if let preface, !preface.isEmpty {
                if let frame = try wire.text(preface) {
                    frames.append(frame)
                    outputTokens = estimatedTokenCount(for: preface)
                }
            }
            frames.append(try wire.toolCall(
                outputIndex: 0,
                callID: callID,
                name: name,
                arguments: arguments
            ))
            frames.append(try wire.usage(.init(
                inputTokens: inputTokenUpperBound,
                outputTokens: outputTokens
            )))
            frames.append(contentsOf: try wire.complete(.toolCalls))
            didReportUsage = true
            terminalPublished = true
            return frames
        } catch let error as AgentLocalModelProviderTransportError {
            throw error
        } catch {
            throw AgentLocalModelProviderTransportError.invalidWireSequence
        }
    }

    func finishDeterministicText(
        _ text: String
    ) throws -> [ProviderWireFrame] {
        guard didBegin, !terminalPublished, !didReportUsage,
              completionReason == nil, !text.isEmpty else {
            throw AgentLocalModelProviderTransportError.invalidWireSequence
        }
        do {
            var frames: [ProviderWireFrame] = []
            if let frame = try wire.text(text) { frames.append(frame) }
            frames.append(try wire.usage(.init(
                inputTokens: inputTokenUpperBound,
                outputTokens: estimatedTokenCount(for: text)
            )))
            frames.append(contentsOf: try wire.complete(.completed))
            didReportUsage = true
            terminalPublished = true
            return frames
        } catch let error as AgentLocalModelProviderTransportError {
            throw error
        } catch {
            throw AgentLocalModelProviderTransportError.invalidWireSequence
        }
    }

    private func estimatedTokenCount(for text: String) -> UInt64 {
        min(
            maximumOutputTokens,
            max(1, UInt64((text.utf8.count + 3) / 4))
        )
    }

    func cancel() -> [ProviderWireFrame] {
        guard didBegin, !terminalPublished else { return [] }
        terminalPublished = true
        return (try? [wire.cancel(reason: .userRequested)]) ?? []
    }
}
