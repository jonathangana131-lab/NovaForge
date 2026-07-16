import AgentDomain
import AgentEngine
import AgentProviders
import AgentTools
import CryptoKit
import Foundation

enum AgentCanonicalContextLimitKind: String, Equatable, Sendable {
    case modelItems
    case providerMessages
    case contentParts
    case toolDefinitions
    case toolCalls
    case requestUTF8Bytes
    case digestMaterialUTF8Bytes
    case textPartUTF8Bytes
    case structuredPartUTF8Bytes
    case instructionUTF8Bytes
    case jsonNodes
    case jsonDepth
    case estimatedInputTokens
}

enum AgentCanonicalContextPreparerError: Error, Equatable, Sendable {
    case unsupportedConfigurationSchema(AgentSchemaVersion)
    case unsupportedEngineVersion(EngineVersion)
    case invalidConfigurationLineage(AgentRunLineageError)
    case invalidProviderID
    case invalidModelID
    case missingPreferredAdapter
    case invalidPreferredAdapterID(String)
    case duplicatePreferredAdapterID(String)
    case invalidGenerationOptions(String)
    case invalidInstruction(String)
    case invalidLimits
    case missingRunContext
    case runContextMismatch
    case unsupportedStateSchema(AgentSchemaVersion)
    case stateNotProviderReady(AgentRunPhase)
    case missingEventCursor
    case eventCursorMismatch
    case terminalCursorPresent
    case activeAttemptPresent(AttemptID)
    case cancellationPending
    case pendingApproval(ApprovalRequestID)
    case unsettledTool(ToolCallID, ToolExecutionStatus)
    case missingBudget
    case budgetExceeded
    case duplicateModelItemID(ModelItemID)
    case duplicateAttemptID(AttemptID)
    case invalidAttempt(AttemptID, String)
    case duplicateArtifactID(ArtifactID)
    case duplicateCheckpointID(ContextCheckpointID)
    case invalidToolDescriptor(String, String)
    case duplicateToolName(String)
    case toolAliasCollision(String)
    case toolLocalityMapMismatch
    case invalidToolLocality(String, ToolExecutionLocality)
    case missingToolExecutionState(ToolCallID)
    case missingToolInvocationItem(ToolCallID)
    case duplicateToolCallID(ToolCallID)
    case duplicateProviderCallID(String)
    case duplicateIdempotencyKey(String)
    case missingProviderCallID(ToolCallID)
    case toolInvocationContractMismatch(ToolCallID)
    case toolArgumentContractMismatch(ToolCallID)
    case missingToolResult(ToolCallID)
    case orphanToolResult(ToolCallID)
    case duplicateToolResult(ToolCallID)
    case toolResultMismatch(ToolCallID)
    case toolResultPrecedesInvocation(ToolCallID)
    case toolEnvelopeNotAdjacent(ToolCallID)
    case multiToolAssistantEnvelopeProvenanceUnavailable(AttemptID)
    case invalidModelItem(ModelItemID, String)
    case invalidArtifact(ArtifactID, String)
    case invalidCheckpoint(ContextCheckpointID, String)
    case invalidJSON(String)
    case limitExceeded(AgentCanonicalContextLimitKind, actual: UInt64, limit: UInt64)
    case contextWindowExceeded(required: UInt64, available: UInt64)
    case arithmeticOverflow
    case canonicalEncodingFailed
}

struct AgentCanonicalContextLimits: Equatable, Sendable {
    static let production = AgentCanonicalContextLimits()

    let maximumModelItems: Int
    let maximumProviderMessages: Int
    let maximumContentParts: Int
    let maximumToolDefinitions: Int
    let maximumToolCallsPerTurn: Int
    let maximumRequestUTF8Bytes: Int
    let maximumDigestMaterialUTF8Bytes: Int
    let maximumTextPartUTF8Bytes: Int
    let maximumStructuredPartUTF8Bytes: Int
    let maximumInstructionUTF8Bytes: Int
    let maximumJSONNodes: Int
    let maximumJSONDepth: Int
    let maximumEstimatedInputTokens: UInt64
    let maximumOutputTokens: UInt64
    let maximumContextWindowTokens: UInt64

    init(
        maximumModelItems: Int = 500,
        maximumProviderMessages: Int = 512,
        maximumContentParts: Int = 4_096,
        maximumToolDefinitions: Int = 128,
        maximumToolCallsPerTurn: Int = 128,
        maximumRequestUTF8Bytes: Int = 8 * 1_024 * 1_024,
        maximumDigestMaterialUTF8Bytes: Int = 16 * 1_024 * 1_024,
        maximumTextPartUTF8Bytes: Int = 1 * 1_024 * 1_024,
        maximumStructuredPartUTF8Bytes: Int = 1 * 1_024 * 1_024,
        maximumInstructionUTF8Bytes: Int = 256 * 1_024,
        maximumJSONNodes: Int = 200_000,
        maximumJSONDepth: Int = 64,
        maximumEstimatedInputTokens: UInt64 = 128_000,
        maximumOutputTokens: UInt64 = 16_384,
        maximumContextWindowTokens: UInt64 = 128_000
    ) {
        self.maximumModelItems = maximumModelItems
        self.maximumProviderMessages = maximumProviderMessages
        self.maximumContentParts = maximumContentParts
        self.maximumToolDefinitions = maximumToolDefinitions
        self.maximumToolCallsPerTurn = maximumToolCallsPerTurn
        self.maximumRequestUTF8Bytes = maximumRequestUTF8Bytes
        self.maximumDigestMaterialUTF8Bytes = maximumDigestMaterialUTF8Bytes
        self.maximumTextPartUTF8Bytes = maximumTextPartUTF8Bytes
        self.maximumStructuredPartUTF8Bytes = maximumStructuredPartUTF8Bytes
        self.maximumInstructionUTF8Bytes = maximumInstructionUTF8Bytes
        self.maximumJSONNodes = maximumJSONNodes
        self.maximumJSONDepth = maximumJSONDepth
        self.maximumEstimatedInputTokens = maximumEstimatedInputTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumContextWindowTokens = maximumContextWindowTokens
    }
}

struct AgentCanonicalContextConfiguration: Equatable, Sendable {
    let context: AgentRunContext
    let providerID: ProviderID
    let model: ProviderModelID
    let preferredAdapterIDs: [ProviderAdapterID]
    let options: ProviderGenerationOptions
    let systemInstruction: String?
    let developerInstruction: String?
    let toolLocalities: [String: ToolExecutionLocality]
    let limits: AgentCanonicalContextLimits

    init(
        context: AgentRunContext,
        providerID: ProviderID,
        model: ProviderModelID,
        preferredAdapterIDs: [ProviderAdapterID],
        options: ProviderGenerationOptions,
        systemInstruction: String? = nil,
        developerInstruction: String? = nil,
        toolLocalities: [String: ToolExecutionLocality],
        limits: AgentCanonicalContextLimits = .production
    ) {
        self.context = context
        self.providerID = providerID
        self.model = model
        self.preferredAdapterIDs = preferredAdapterIDs
        self.options = options
        self.systemInstruction = systemInstruction
        self.developerInstruction = developerInstruction
        self.toolLocalities = toolLocalities
        self.limits = limits
    }
}

/// Deterministic, dispatch-free context authority for the v2 agent engine.
///
/// This type owns no mutable provider configuration. Every routing, generation,
/// instruction, tool-contract, and locality fact is captured with the run context
/// at initialization and is cryptographically bound to each prepared turn.
struct AgentCanonicalContextPreparer: AgentContextPreparing, Sendable {
    static let version = "canonical-context-v1"

    let configuration: AgentCanonicalContextConfiguration

    init(configuration: AgentCanonicalContextConfiguration) throws {
        try Self.validate(configuration: configuration)
        self.configuration = configuration
    }

    func prepareProviderTurn(
        state: AgentDomain.AgentRunState,
        tools: [ToolDescriptor]
    ) async throws -> AgentPreparedProviderTurn {
        try Task.checkCancellation()
        try validate(state: state)
        try enforceLimit(
            .modelItems,
            actual: state.modelItems.count,
            limit: configuration.limits.maximumModelItems
        )
        try enforceLimit(
            .toolDefinitions,
            actual: tools.count,
            limit: configuration.limits.maximumToolDefinitions
        )

        var jsonNodeCount = 0
        let toolContracts = try validateAndBindTools(
            tools,
            jsonNodeCount: &jsonNodeCount
        )
        try Task.checkCancellation()

        let transcript = try validateTranscript(
            state: state,
            tools: tools,
            jsonNodeCount: &jsonNodeCount
        )
        try Task.checkCancellation()

        var messages: [ProviderMessage] = []
        messages.reserveCapacity(state.modelItems.count + 3)
        if let systemInstruction = configuration.systemInstruction {
            messages.append(ProviderMessage(
                role: .system,
                content: [.text(systemInstruction)]
            ))
        }
        if let developerInstruction = configuration.developerInstruction {
            messages.append(ProviderMessage(
                role: .developer,
                content: [.text(developerInstruction)]
            ))
        }
        if !state.artifacts.isEmpty || !state.checkpoints.isEmpty {
            let supplement = AgentCanonicalContextSupplement(
                kind: "novaforge_context_supplement_v1",
                artifacts: state.artifacts,
                checkpoints: state.checkpoints
            )
            let text = try canonicalJSONString(supplement)
            try enforceUTF8Limit(
                text,
                kind: .textPartUTF8Bytes,
                limit: configuration.limits.maximumTextPartUTF8Bytes
            )
            messages.append(ProviderMessage(
                role: .developer,
                content: [.text(text)]
            ))
        }

        var contentPartCount = messages.reduce(0) { $0 + $1.content.count }
        for item in state.modelItems {
            try Task.checkCancellation()
            let message = try providerMessage(
                for: item,
                transcript: transcript,
                jsonNodeCount: &jsonNodeCount
            )
            let addition = contentPartCount.addingReportingOverflow(message.content.count)
            guard !addition.overflow else {
                throw AgentCanonicalContextPreparerError.arithmeticOverflow
            }
            contentPartCount = addition.partialValue
            messages.append(message)
        }

        try enforceLimit(
            .providerMessages,
            actual: messages.count,
            limit: configuration.limits.maximumProviderMessages
        )
        try enforceLimit(
            .contentParts,
            actual: contentPartCount,
            limit: configuration.limits.maximumContentParts
        )
        try enforceLimit(
            .jsonNodes,
            actual: jsonNodeCount,
            limit: configuration.limits.maximumJSONNodes
        )
        guard !messages.isEmpty else {
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "empty_provider_context"
            )
        }

        let sequence = try eventSequence(in: state)
        let requestID = "novaforge:\(configuration.context.lineage.runID):provider-turn:\(sequence.rawValue)"
        let definitions = tools.map { descriptor in
            AgentProviders.ProviderToolDefinition(
                name: descriptor.name,
                description: descriptor.description,
                parameters: descriptor.argumentSchema.strictProviderValue,
                strict: true
            )
        }
        let request = CanonicalProviderRequest(
            requestID: requestID,
            model: configuration.model,
            messages: messages,
            tools: definitions,
            options: configuration.options,
            metadata: metadata(sequence: sequence, state: state)
        )
        let requestData = try canonicalData(request)
        try enforceLimit(
            .requestUTF8Bytes,
            actual: requestData.count,
            limit: configuration.limits.maximumRequestUTF8Bytes
        )

        // One UTF-8 byte per token is deliberately conservative and cannot
        // understate byte-fallback tokenizers for arbitrary model input. The
        // attested local-agent adapter consumes tool definitions in its
        // deterministic grammar controller; only messages enter the GGUF
        // tokenizer. Hosted adapters send the complete request and therefore
        // retain full-envelope accounting.
        let inferenceInputData: Data
        if configuration.providerID == ProviderID(
            rawValue: "novaforge-local"
        ), configuration.toolLocalities.values.allSatisfy({
            $0 == .onDevice
        }) {
            inferenceInputData = try canonicalData(messages)
        } else {
            inferenceInputData = requestData
        }
        let estimatedTokens = UInt64(inferenceInputData.count)
        try enforceLimit(
            .estimatedInputTokens,
            actual: estimatedTokens,
            limit: configuration.limits.maximumEstimatedInputTokens
        )
        guard let outputTokens = configuration.options.maximumOutputTokens,
              let contextWindow = configuration.options.minimumContextWindowTokens
        else {
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "missing_explicit_token_limits"
            )
        }
        let requiredWindow = estimatedTokens.addingReportingOverflow(outputTokens)
        guard !requiredWindow.overflow else {
            throw AgentCanonicalContextPreparerError.arithmeticOverflow
        }
        guard requiredWindow.partialValue <= contextWindow else {
            throw AgentCanonicalContextPreparerError.contextWindowExceeded(
                required: requiredWindow.partialValue,
                available: contextWindow
            )
        }

        let itemIDs = state.modelItems.map(\.id)
        let digestMaterial = AgentCanonicalContextDigestMaterial(
            scheme: "novaforge_agent_context_v1",
            context: configuration.context,
            providerID: configuration.providerID.rawValue,
            preferredAdapterIDs: configuration.preferredAdapterIDs.map(\.rawValue),
            request: request,
            state: state,
            orderedItemIDs: itemIDs.map(\.description),
            toolContracts: toolContracts
        )
        let digestData = try canonicalData(digestMaterial)
        try enforceLimit(
            .digestMaterialUTF8Bytes,
            actual: digestData.count,
            limit: configuration.limits.maximumDigestMaterialUTF8Bytes
        )
        let hash = SHA256.hash(data: digestData)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        guard let digest = try? AgentCanonicalSHA256Digest("sha256:" + hex) else {
            throw AgentCanonicalContextPreparerError.canonicalEncodingFailed
        }
        try Task.checkCancellation()

        return AgentPreparedProviderTurn(
            request: request,
            preferredAdapterIDs: configuration.preferredAdapterIDs,
            itemIDs: itemIDs,
            estimatedTokens: estimatedTokens,
            contextDigest: digest,
            toolLocalities: configuration.toolLocalities
        )
    }
}

// MARK: - Static configuration validation

private extension AgentCanonicalContextPreparer {
    static func validate(configuration: AgentCanonicalContextConfiguration) throws {
        guard configuration.context.schemaVersion == .current else {
            throw AgentCanonicalContextPreparerError.unsupportedConfigurationSchema(
                configuration.context.schemaVersion
            )
        }
        guard configuration.context.engineVersion == .agentHarnessV2 else {
            throw AgentCanonicalContextPreparerError.unsupportedEngineVersion(
                configuration.context.engineVersion
            )
        }
        if let lineageError = configuration.context.lineage.validationError {
            throw AgentCanonicalContextPreparerError.invalidConfigurationLineage(
                lineageError
            )
        }
        guard safeMetadataIdentity(
            configuration.providerID.rawValue,
            maximumUTF8Count: 128
        ) else {
            throw AgentCanonicalContextPreparerError.invalidProviderID
        }
        guard safeIdentity(configuration.model.rawValue, maximumUTF8Count: 256) else {
            throw AgentCanonicalContextPreparerError.invalidModelID
        }
        guard !configuration.preferredAdapterIDs.isEmpty else {
            throw AgentCanonicalContextPreparerError.missingPreferredAdapter
        }
        var adapterIDs: Set<String> = []
        for adapter in configuration.preferredAdapterIDs {
            guard safeIdentity(adapter.rawValue, maximumUTF8Count: 256) else {
                throw AgentCanonicalContextPreparerError.invalidPreferredAdapterID(
                    adapter.rawValue
                )
            }
            guard adapterIDs.insert(adapter.rawValue).inserted else {
                throw AgentCanonicalContextPreparerError.duplicatePreferredAdapterID(
                    adapter.rawValue
                )
            }
        }

        try validate(limits: configuration.limits)
        try validate(
            instruction: configuration.systemInstruction,
            name: "system",
            limits: configuration.limits
        )
        try validate(
            instruction: configuration.developerInstruction,
            name: "developer",
            limits: configuration.limits
        )
        try validate(options: configuration.options, limits: configuration.limits)

        for (name, locality) in configuration.toolLocalities {
            guard validToolName(name), locality != .either else {
                throw AgentCanonicalContextPreparerError.invalidToolLocality(name, locality)
            }
        }
    }

    static func validate(limits: AgentCanonicalContextLimits) throws {
        let positiveInts = [
            limits.maximumModelItems,
            limits.maximumProviderMessages,
            limits.maximumContentParts,
            limits.maximumToolDefinitions,
            limits.maximumToolCallsPerTurn,
            limits.maximumRequestUTF8Bytes,
            limits.maximumDigestMaterialUTF8Bytes,
            limits.maximumTextPartUTF8Bytes,
            limits.maximumStructuredPartUTF8Bytes,
            limits.maximumInstructionUTF8Bytes,
            limits.maximumJSONNodes,
            limits.maximumJSONDepth,
        ]
        guard positiveInts.allSatisfy({ $0 > 0 }),
              limits.maximumProviderMessages <= 512,
              limits.maximumContentParts <= 4_096,
              limits.maximumToolDefinitions <= 128,
              limits.maximumToolCallsPerTurn <= 128,
              limits.maximumRequestUTF8Bytes <= 8 * 1_024 * 1_024,
              limits.maximumJSONNodes <= 200_000,
              limits.maximumJSONDepth <= 64,
              limits.maximumEstimatedInputTokens > 0,
              limits.maximumOutputTokens > 0,
              limits.maximumContextWindowTokens > 0,
              limits.maximumOutputTokens <= limits.maximumContextWindowTokens,
              limits.maximumTextPartUTF8Bytes <= limits.maximumRequestUTF8Bytes,
              limits.maximumStructuredPartUTF8Bytes <= limits.maximumRequestUTF8Bytes,
              limits.maximumInstructionUTF8Bytes <= limits.maximumRequestUTF8Bytes
        else {
            throw AgentCanonicalContextPreparerError.invalidLimits
        }
    }

    static func validate(
        instruction: String?,
        name: String,
        limits: AgentCanonicalContextLimits
    ) throws {
        guard let instruction else { return }
        guard !instruction.isEmpty,
              instruction.utf8.count <= limits.maximumInstructionUTF8Bytes,
              !instruction.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw AgentCanonicalContextPreparerError.invalidInstruction(name)
        }
    }

    static func validate(
        options: ProviderGenerationOptions,
        limits: AgentCanonicalContextLimits
    ) throws {
        guard let outputTokens = options.maximumOutputTokens,
              outputTokens > 0,
              outputTokens <= limits.maximumOutputTokens,
              let contextTokens = options.minimumContextWindowTokens,
              contextTokens > 0,
              contextTokens <= limits.maximumContextWindowTokens,
              outputTokens <= contextTokens
        else {
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "invalid_explicit_token_limits"
            )
        }
        if let temperature = options.temperature,
           (!temperature.isFinite || temperature < 0 || temperature > 2) {
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "invalid_temperature"
            )
        }
        if let cacheKey = options.promptCacheKey,
           !safeIdentity(cacheKey, maximumUTF8Count: 512) {
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "invalid_prompt_cache_key"
            )
        }
        if let responseID = options.previousResponseID,
           !safeIdentity(responseID, maximumUTF8Count: 512) {
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "invalid_previous_response_id"
            )
        }
        if case let .named(name) = options.toolChoice, !validToolName(name) {
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "invalid_named_tool_choice"
            )
        }
        if options.parallelToolCalls == true,
           limits.maximumToolCallsPerTurn < 2 {
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "parallel_tool_capacity_below_two"
            )
        }
    }
}

// MARK: - State and transcript validation

private extension AgentCanonicalContextPreparer {
    struct InvocationRecord {
        let itemID: ModelItemID
        let itemIndex: Int
        let invocation: ToolInvocation
    }

    struct ResultRecord {
        let itemID: ModelItemID
        let itemIndex: Int
        let result: ToolResult
    }

    struct ValidatedTranscript {
        let invocationsByCallID: [ToolCallID: InvocationRecord]
        let resultsByCallID: [ToolCallID: ResultRecord]
    }

    func validate(state: AgentDomain.AgentRunState) throws {
        guard let context = state.context else {
            throw AgentCanonicalContextPreparerError.missingRunContext
        }
        guard context == configuration.context else {
            throw AgentCanonicalContextPreparerError.runContextMismatch
        }
        guard state.schemaVersion == .current else {
            throw AgentCanonicalContextPreparerError.unsupportedStateSchema(
                state.schemaVersion
            )
        }
        guard state.phase == .running else {
            throw AgentCanonicalContextPreparerError.stateNotProviderReady(state.phase)
        }
        guard state.lastSequence != nil, state.lastEventID != nil else {
            throw AgentCanonicalContextPreparerError.missingEventCursor
        }
        guard state.appliedEventIDs.last == state.lastEventID else {
            throw AgentCanonicalContextPreparerError.eventCursorMismatch
        }
        guard state.terminalEventID == nil else {
            throw AgentCanonicalContextPreparerError.terminalCursorPresent
        }
        if let activeAttemptID = state.activeAttemptID {
            throw AgentCanonicalContextPreparerError.activeAttemptPresent(activeAttemptID)
        }
        guard state.cancellation == nil else {
            throw AgentCanonicalContextPreparerError.cancellationPending
        }
        if let pending = state.approvals.first(where: { $0.status == .pending }) {
            throw AgentCanonicalContextPreparerError.pendingApproval(
                pending.request.requestID
            )
        }
        if let unsettled = state.tools.first(where: { !$0.status.isSettled }) {
            throw AgentCanonicalContextPreparerError.unsettledTool(
                unsettled.invocation.callID,
                unsettled.status
            )
        }
        guard let budget = state.budget else {
            throw AgentCanonicalContextPreparerError.missingBudget
        }
        guard budget.exceededDimensions.isEmpty else {
            throw AgentCanonicalContextPreparerError.budgetExceeded
        }

        var itemIDs: Set<ModelItemID> = []
        for item in state.modelItems where !itemIDs.insert(item.id).inserted {
            throw AgentCanonicalContextPreparerError.duplicateModelItemID(item.id)
        }
        var attemptIDs: Set<AttemptID> = []
        for attempt in state.modelAttempts {
            guard attemptIDs.insert(attempt.attemptID).inserted else {
                throw AgentCanonicalContextPreparerError.duplicateAttemptID(
                    attempt.attemptID
                )
            }
            guard Self.safeIdentity(attempt.route.provider, maximumUTF8Count: 256),
                  Self.safeIdentity(attempt.route.model, maximumUTF8Count: 256),
                  Self.safeIdentity(attempt.route.adapter, maximumUTF8Count: 256),
                  !attempt.providerAttempt.isLegacyV1
            else {
                throw AgentCanonicalContextPreparerError.invalidAttempt(
                    attempt.attemptID,
                    "invalid_route_or_missing_v1_1_attempt_metadata"
                )
            }
            if attempt.status == .responseCommitted,
               (attempt.usage == nil || attempt.finishReason == nil) {
                throw AgentCanonicalContextPreparerError.invalidAttempt(
                    attempt.attemptID,
                    "committed_attempt_missing_usage_or_finish_reason"
                )
            }
        }
        var artifactIDs: Set<ArtifactID> = []
        for artifact in state.artifacts {
            guard artifactIDs.insert(artifact.artifactID).inserted else {
                throw AgentCanonicalContextPreparerError.duplicateArtifactID(
                    artifact.artifactID
                )
            }
            try validate(artifact: artifact)
        }
        var checkpointIDs: Set<ContextCheckpointID> = []
        for checkpoint in state.checkpoints {
            guard checkpointIDs.insert(checkpoint.checkpointID).inserted else {
                throw AgentCanonicalContextPreparerError.duplicateCheckpointID(
                    checkpoint.checkpointID
                )
            }
            try validate(checkpoint: checkpoint, knownItemIDs: itemIDs)
        }
    }

    func validateTranscript(
        state: AgentDomain.AgentRunState,
        tools: [ToolDescriptor],
        jsonNodeCount: inout Int
    ) throws -> ValidatedTranscript {
        let descriptorsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        let attemptsByID = Dictionary(
            uniqueKeysWithValues: state.modelAttempts.map { ($0.attemptID, $0) }
        )
        var invocations: [ToolCallID: InvocationRecord] = [:]
        var results: [ToolCallID: ResultRecord] = [:]
        var providerCallIDs: Set<String> = []
        var idempotencyKeys: Set<String> = []
        var attemptOrder: [AttemptID] = []
        var invocationCountByAttempt: [AttemptID: Int] = [:]
        var priorItemIDs: Set<ModelItemID> = []

        for (index, item) in state.modelItems.enumerated() {
            try Task.checkCancellation()
            switch item.payload {
            case let .toolInvocation(invocation):
                guard invocations[invocation.callID] == nil else {
                    throw AgentCanonicalContextPreparerError.duplicateToolCallID(
                        invocation.callID
                    )
                }
                guard invocation.hasCanonicalProviderCallID,
                      let providerCallID = invocation.providerCallID
                else {
                    throw AgentCanonicalContextPreparerError.missingProviderCallID(
                        invocation.callID
                    )
                }
                guard providerCallIDs.insert(providerCallID).inserted else {
                    throw AgentCanonicalContextPreparerError.duplicateProviderCallID(
                        providerCallID
                    )
                }
                guard Self.safeIdentity(
                    invocation.idempotencyKey,
                    maximumUTF8Count: 512
                ), idempotencyKeys.insert(invocation.idempotencyKey).inserted else {
                    throw AgentCanonicalContextPreparerError.duplicateIdempotencyKey(
                        invocation.idempotencyKey
                    )
                }
                guard let descriptor = descriptorsByName[invocation.tool.name],
                      descriptor.identity == invocation.tool,
                      descriptor.effectClass == invocation.effectClass,
                      configuration.toolLocalities[descriptor.name] == invocation.locality
                else {
                    throw AgentCanonicalContextPreparerError.toolInvocationContractMismatch(
                        invocation.callID
                    )
                }
                do {
                    guard try descriptor.canonicalArgumentDigest(
                        for: invocation.arguments
                    ) == invocation.canonicalArgumentDigest else {
                        throw AgentCanonicalContextPreparerError.toolArgumentContractMismatch(
                            invocation.callID
                        )
                    }
                } catch let error as AgentCanonicalContextPreparerError {
                    throw error
                } catch {
                    throw AgentCanonicalContextPreparerError.toolArgumentContractMismatch(
                        invocation.callID
                    )
                }
                try validateJSON(
                    invocation.arguments,
                    context: "tool_arguments:\(invocation.callID)",
                    nodeCount: &jsonNodeCount
                )
                let argumentData = try canonicalData(invocation.arguments)
                guard argumentData.count <= descriptor.limits.maximumArgumentBytes else {
                    throw AgentCanonicalContextPreparerError.toolArgumentContractMismatch(
                        invocation.callID
                    )
                }
                try enforceLimit(
                    .structuredPartUTF8Bytes,
                    actual: argumentData.count,
                    limit: configuration.limits.maximumStructuredPartUTF8Bytes
                )
                guard let attempt = attemptsByID[invocation.modelAttemptID],
                      attempt.status == .responseCommitted,
                      attempt.finishReason == .toolCalls
                else {
                    throw AgentCanonicalContextPreparerError.invalidAttempt(
                        invocation.modelAttemptID,
                        "tool_call_does_not_bind_committed_tool_attempt"
                    )
                }
                if invocationCountByAttempt[invocation.modelAttemptID] == nil {
                    attemptOrder.append(invocation.modelAttemptID)
                }
                invocationCountByAttempt[invocation.modelAttemptID, default: 0] += 1
                invocations[invocation.callID] = InvocationRecord(
                    itemID: item.id,
                    itemIndex: index,
                    invocation: invocation
                )

            case let .toolResult(result):
                guard result.modelItemID == item.id else {
                    throw AgentCanonicalContextPreparerError.toolResultMismatch(
                        result.callID
                    )
                }
                guard results[result.callID] == nil else {
                    throw AgentCanonicalContextPreparerError.duplicateToolResult(
                        result.callID
                    )
                }
                results[result.callID] = ResultRecord(
                    itemID: item.id,
                    itemIndex: index,
                    result: result
                )

            case let .contextCheckpoint(checkpoint):
                try validate(
                    checkpoint: checkpoint,
                    knownItemIDs: priorItemIDs
                )
            case .message, .reasoningSummary:
                break
            }
            priorItemIDs.insert(item.id)
        }

        for attemptID in attemptOrder
        where invocationCountByAttempt[attemptID, default: 0] > 1 {
            // ModelItem currently omits attempt provenance from assistant text and
            // reasoning. Reconstructing a multi-call assistant envelope would
            // therefore require an ordering/grouping guess, which production blocks.
            throw AgentCanonicalContextPreparerError
                .multiToolAssistantEnvelopeProvenanceUnavailable(attemptID)
        }
        try enforceLimit(
            .toolCalls,
            actual: invocations.count,
            limit: configuration.limits.maximumToolCallsPerTurn
        )

        var executions: [ToolCallID: ToolExecutionState] = [:]
        for execution in state.tools {
            guard executions[execution.invocation.callID] == nil else {
                throw AgentCanonicalContextPreparerError.duplicateToolCallID(
                    execution.invocation.callID
                )
            }
            executions[execution.invocation.callID] = execution
        }
        for item in state.modelItems {
            guard case let .toolInvocation(invocation) = item.payload else { continue }
            guard let execution = executions[invocation.callID] else {
                throw AgentCanonicalContextPreparerError.missingToolExecutionState(
                    invocation.callID
                )
            }
            guard execution.invocation == invocation else {
                throw AgentCanonicalContextPreparerError.toolInvocationContractMismatch(
                    invocation.callID
                )
            }
            guard let invocationRecord = invocations[invocation.callID] else {
                throw AgentCanonicalContextPreparerError.missingToolInvocationItem(
                    invocation.callID
                )
            }
            guard let resultRecord = results[invocation.callID] else {
                throw AgentCanonicalContextPreparerError.missingToolResult(
                    invocation.callID
                )
            }
            guard resultRecord.itemIndex > invocationRecord.itemIndex else {
                throw AgentCanonicalContextPreparerError.toolResultPrecedesInvocation(
                    invocation.callID
                )
            }
            guard resultRecord.itemIndex == invocationRecord.itemIndex + 1 else {
                throw AgentCanonicalContextPreparerError.toolEnvelopeNotAdjacent(
                    invocation.callID
                )
            }
            guard execution.result == resultRecord.result else {
                throw AgentCanonicalContextPreparerError.toolResultMismatch(
                    invocation.callID
                )
            }
            try validate(result: resultRecord.result, jsonNodeCount: &jsonNodeCount)
        }
        for execution in state.tools where invocations[execution.invocation.callID] == nil {
            throw AgentCanonicalContextPreparerError.missingToolInvocationItem(
                execution.invocation.callID
            )
        }
        for result in results.values where invocations[result.result.callID] == nil {
            throw AgentCanonicalContextPreparerError.orphanToolResult(
                result.result.callID
            )
        }
        return ValidatedTranscript(
            invocationsByCallID: invocations,
            resultsByCallID: results
        )
    }
}

// MARK: - Tool validation and digest contracts

private extension AgentCanonicalContextPreparer {
    func validateAndBindTools(
        _ tools: [ToolDescriptor],
        jsonNodeCount: inout Int
    ) throws -> [JSONValue] {
        let names = tools.map(\.name)
        guard Set(names) == Set(configuration.toolLocalities.keys),
              names.count == configuration.toolLocalities.count
        else {
            throw AgentCanonicalContextPreparerError.toolLocalityMapMismatch
        }
        var canonicalNames: Set<String> = []
        for descriptor in tools {
            guard canonicalNames.insert(descriptor.name).inserted else {
                throw AgentCanonicalContextPreparerError.duplicateToolName(
                    descriptor.name
                )
            }
        }
        var aliases: Set<String> = []
        var contracts: [JSONValue] = []
        contracts.reserveCapacity(tools.count)
        for descriptor in tools {
            try Task.checkCancellation()
            try validate(descriptor: descriptor, canonicalNames: canonicalNames)
            for alias in descriptor.aliases {
                guard !canonicalNames.contains(alias), aliases.insert(alias).inserted else {
                    throw AgentCanonicalContextPreparerError.toolAliasCollision(alias)
                }
            }
            guard let locality = configuration.toolLocalities[descriptor.name],
                  locality != .either,
                  descriptor.availability.allowedLocalities.contains(.either)
                    || descriptor.availability.allowedLocalities.contains(locality)
            else {
                throw AgentCanonicalContextPreparerError.invalidToolLocality(
                    descriptor.name,
                    configuration.toolLocalities[descriptor.name] ?? .either
                )
            }
            let providerSchema = descriptor.argumentSchema.strictProviderValue
            try validateJSON(
                providerSchema,
                context: "tool_schema:\(descriptor.name)",
                nodeCount: &jsonNodeCount
            )
            let schemaData = try canonicalData(providerSchema)
            try enforceLimit(
                .structuredPartUTF8Bytes,
                actual: schemaData.count,
                limit: configuration.limits.maximumStructuredPartUTF8Bytes
            )
            contracts.append(toolContract(descriptor, locality: locality))
        }
        switch configuration.options.toolChoice {
        case .required where tools.isEmpty:
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "required_tool_choice_without_tools"
            )
        case let .named(name) where !canonicalNames.contains(name):
            throw AgentCanonicalContextPreparerError.invalidGenerationOptions(
                "named_tool_choice_not_supplied"
            )
        default:
            break
        }
        return contracts
    }

    func validate(
        descriptor: ToolDescriptor,
        canonicalNames: Set<String>
    ) throws {
        guard Self.validToolName(descriptor.name),
              descriptor.aliases.allSatisfy(Self.validToolName),
              descriptor.version.major > 0,
              descriptor.version.minor >= 0,
              descriptor.version.patch >= 0,
              !descriptor.toolset.isEmpty,
              descriptor.toolset.utf8.count <= 128,
              !descriptor.description.isEmpty,
              descriptor.description.utf8.count <= configuration.limits.maximumTextPartUTF8Bytes,
              descriptor.limits.timeoutMilliseconds > 0,
              descriptor.limits.maximumArgumentBytes > 0,
              descriptor.limits.maximumOutputBytes > 0,
              !descriptor.availability.allowedLocalities.isEmpty,
              Set(descriptor.availability.allowedLocalities).count
                == descriptor.availability.allowedLocalities.count,
              Set(descriptor.availability.requiredCapabilities).count
                == descriptor.availability.requiredCapabilities.count,
              !(descriptor.availability.allowedLocalities.contains(.either)
                && descriptor.availability.allowedLocalities.count > 1),
              descriptor.parallelSafety != .denied,
              descriptor.effectClass != .unrecoverableDenied,
              descriptor.approvalClass != .alwaysDenied
        else {
            throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                descriptor.name,
                "invalid_identity_limits_availability_or_denied_contract"
            )
        }
        if let concurrencyKey = descriptor.concurrencyKey,
           !Self.safeIdentity(concurrencyKey, maximumUTF8Count: 128) {
            throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                descriptor.name,
                "invalid_concurrency_key"
            )
        }
        var schemaNodes = 0
        try validate(
            schema: descriptor.argumentSchema,
            toolName: descriptor.name,
            depth: 1,
            nodeCount: &schemaNodes
        )
        guard schemaNodes <= configuration.limits.maximumJSONNodes else {
            throw AgentCanonicalContextPreparerError.limitExceeded(
                .jsonNodes,
                actual: UInt64(schemaNodes),
                limit: UInt64(configuration.limits.maximumJSONNodes)
            )
        }
        var seenAliases: Set<String> = []
        for alias in descriptor.aliases {
            guard alias != descriptor.name,
                  !canonicalNames.contains(alias),
                  seenAliases.insert(alias).inserted
            else {
                throw AgentCanonicalContextPreparerError.toolAliasCollision(alias)
            }
        }
    }

    func validate(
        schema: JSONSchema,
        toolName: String,
        depth: Int,
        nodeCount: inout Int
    ) throws {
        guard depth <= configuration.limits.maximumJSONDepth else {
            throw AgentCanonicalContextPreparerError.limitExceeded(
                .jsonDepth,
                actual: UInt64(depth),
                limit: UInt64(configuration.limits.maximumJSONDepth)
            )
        }
        let next = nodeCount.addingReportingOverflow(1)
        guard !next.overflow else {
            throw AgentCanonicalContextPreparerError.arithmeticOverflow
        }
        nodeCount = next.partialValue
        switch schema {
        case .null, .boolean:
            return
        case let .integer(_, minimum, maximum):
            guard minimum == nil || maximum == nil || minimum! <= maximum! else {
                throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                    toolName,
                    "invalid_integer_bounds"
                )
            }
        case let .number(_, minimum, maximum):
            guard minimum?.isFinite != false,
                  maximum?.isFinite != false,
                  minimum == nil || maximum == nil || minimum! <= maximum!
            else {
                throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                    toolName,
                    "invalid_number_bounds"
                )
            }
        case let .string(_, minimum, maximum, allowedValues):
            guard minimum == nil || minimum! >= 0,
                  maximum == nil || maximum! >= 0,
                  minimum == nil || maximum == nil || minimum! <= maximum!,
                  allowedValues.map({ Set($0).count == $0.count }) != false
            else {
                throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                    toolName,
                    "invalid_string_contract"
                )
            }
        case let .array(_, items, minimum, maximum):
            guard minimum == nil || minimum! >= 0,
                  maximum == nil || maximum! >= 0,
                  minimum == nil || maximum == nil || minimum! <= maximum!
            else {
                throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                    toolName,
                    "invalid_array_bounds"
                )
            }
            try validate(
                schema: items,
                toolName: toolName,
                depth: depth + 1,
                nodeCount: &nodeCount
            )
        case let .object(_, properties, required, additionalProperties):
            guard !additionalProperties else {
                throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                    toolName,
                    "strict_schema_allows_additional_properties"
                )
            }
            let requiredSet = Set(required)
            guard requiredSet.count == required.count,
                  required.allSatisfy({ properties[$0] != nil }),
                  properties.keys.allSatisfy({
                      !$0.isEmpty && $0.utf8.count <= 128
                        && !$0.unicodeScalars.contains(where: {
                            CharacterSet.controlCharacters.contains($0)
                        })
                  }),
                  properties.allSatisfy({ key, value in
                      requiredSet.contains(key) || value.acceptsNull
                  })
            else {
                throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                    toolName,
                    "invalid_strict_object_contract"
                )
            }
            for key in properties.keys.sorted() {
                guard let child = properties[key] else {
                    throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                        toolName,
                        "schema_property_disappeared"
                    )
                }
                try validate(
                    schema: child,
                    toolName: toolName,
                    depth: depth + 1,
                    nodeCount: &nodeCount
                )
            }
        case let .oneOf(_, schemas):
            guard schemas.count >= 2, Set(schemas).count == schemas.count else {
                throw AgentCanonicalContextPreparerError.invalidToolDescriptor(
                    toolName,
                    "invalid_union_contract"
                )
            }
            for child in schemas {
                try validate(
                    schema: child,
                    toolName: toolName,
                    depth: depth + 1,
                    nodeCount: &nodeCount
                )
            }
        }
    }
}

// MARK: - Model conversion

private extension AgentCanonicalContextPreparer {
    func providerMessage(
        for item: ModelItem,
        transcript: ValidatedTranscript,
        jsonNodeCount: inout Int
    ) throws -> ProviderMessage {
        switch item.payload {
        case let .message(message):
            guard !message.content.isEmpty else {
                throw AgentCanonicalContextPreparerError.invalidModelItem(
                    item.id,
                    "empty_message"
                )
            }
            let role: ProviderMessageRole = message.role == .user ? .user : .assistant
            var parts: [ProviderContentPart] = []
            parts.reserveCapacity(message.content.count)
            for part in message.content {
                switch part {
                case let .text(text):
                    try enforceUTF8Limit(
                        text,
                        kind: .textPartUTF8Bytes,
                        limit: configuration.limits.maximumTextPartUTF8Bytes
                    )
                    parts.append(.text(text))
                case let .structured(value):
                    try validateJSON(
                        value,
                        context: "model_item:\(item.id)",
                        nodeCount: &jsonNodeCount
                    )
                    let data = try canonicalData(value)
                    try enforceLimit(
                        .structuredPartUTF8Bytes,
                        actual: data.count,
                        limit: configuration.limits.maximumStructuredPartUTF8Bytes
                    )
                    parts.append(.structured(value))
                case let .image(image):
                    guard Self.safeIdentity(image.mediaType, maximumUTF8Count: 255),
                          Self.safeIdentity(image.contentDigest, maximumUTF8Count: 2_048),
                          image.detail.map({
                              Self.safeIdentity($0, maximumUTF8Count: 64)
                          }) != false
                    else {
                        throw AgentCanonicalContextPreparerError.invalidModelItem(
                            item.id,
                            "invalid_image_reference"
                        )
                    }
                    parts.append(.image(ProviderImageInput(
                        mediaType: image.mediaType,
                        source: image.contentDigest,
                        detail: image.detail
                    )))
                case let .artifact(artifact):
                    try validate(artifact: artifact)
                    let value = artifactValue(artifact)
                    try validateJSON(
                        value,
                        context: "artifact_content:\(artifact.artifactID)",
                        nodeCount: &jsonNodeCount
                    )
                    parts.append(.structured(value))
                }
            }
            return ProviderMessage(role: role, content: parts)

        case let .reasoningSummary(reasoning):
            guard !reasoning.text.isEmpty,
                  reasoning.text.utf8.count <= configuration.limits.maximumTextPartUTF8Bytes,
                  reasoning.providerReference.map({
                      Self.safeIdentity($0, maximumUTF8Count: 512)
                  }) != false
            else {
                throw AgentCanonicalContextPreparerError.invalidModelItem(
                    item.id,
                    "invalid_reasoning_summary"
                )
            }
            let text = try canonicalJSONString(AgentCanonicalReasoningEnvelope(
                kind: "reasoning_summary",
                body: reasoning
            ))
            try enforceUTF8Limit(
                text,
                kind: .textPartUTF8Bytes,
                limit: configuration.limits.maximumTextPartUTF8Bytes
            )
            return ProviderMessage(role: .assistant, content: [.text(text)])

        case let .toolInvocation(invocation):
            guard let record = transcript.invocationsByCallID[invocation.callID],
                  record.itemID == item.id,
                  let providerCallID = invocation.providerCallID
            else {
                throw AgentCanonicalContextPreparerError.toolInvocationContractMismatch(
                    invocation.callID
                )
            }
            return ProviderMessage(
                role: .assistant,
                content: [.toolCall(ProviderToolCallInput(
                    callID: providerCallID,
                    name: invocation.tool.name,
                    arguments: invocation.arguments
                ))]
            )

        case let .toolResult(result):
            guard let resultRecord = transcript.resultsByCallID[result.callID],
                  resultRecord.itemID == item.id,
                  let invocation = transcript.invocationsByCallID[result.callID]?.invocation,
                  let providerCallID = invocation.providerCallID
            else {
                throw AgentCanonicalContextPreparerError.toolResultMismatch(result.callID)
            }
            let text = try canonicalJSONString(AgentCanonicalToolResultEnvelope(
                kind: "tool_result",
                body: result
            ))
            try enforceUTF8Limit(
                text,
                kind: .textPartUTF8Bytes,
                limit: configuration.limits.maximumTextPartUTF8Bytes
            )
            return ProviderMessage(
                role: .tool,
                content: [.text(text)],
                toolCallID: providerCallID
            )

        case let .contextCheckpoint(checkpoint):
            try validate(checkpoint: checkpoint, knownItemIDs: nil)
            let text = try canonicalJSONString(AgentCanonicalCheckpointEnvelope(
                kind: "context_checkpoint",
                body: checkpoint
            ))
            try enforceUTF8Limit(
                text,
                kind: .textPartUTF8Bytes,
                limit: configuration.limits.maximumTextPartUTF8Bytes
            )
            return ProviderMessage(role: .developer, content: [.text(text)])
        }
    }

    func validate(
        result: ToolResult,
        jsonNodeCount: inout Int
    ) throws {
        try validateJSON(
            result.output,
            context: "tool_result_output:\(result.callID)",
            nodeCount: &jsonNodeCount
        )
        for artifact in result.artifacts {
            try validate(artifact: artifact)
        }
        for evidence in result.evidence {
            guard Self.safeIdentity(evidence.kind, maximumUTF8Count: 128),
                  Self.safeIdentity(evidence.digest, maximumUTF8Count: 512)
            else {
                throw AgentCanonicalContextPreparerError.toolResultMismatch(
                    result.callID
                )
            }
            try validateJSON(
                evidence.metadata,
                context: "tool_evidence:\(result.callID)",
                nodeCount: &jsonNodeCount
            )
        }
        guard result.warnings.allSatisfy({
            $0.utf8.count <= configuration.limits.maximumTextPartUTF8Bytes
        }), result.error.map({ error in
            Self.safeIdentity(error.code, maximumUTF8Count: 256)
                && !error.publicMessage.isEmpty
                && error.publicMessage.utf8.count
                    <= configuration.limits.maximumTextPartUTF8Bytes
        }) != false else {
            throw AgentCanonicalContextPreparerError.toolResultMismatch(result.callID)
        }
        let text = try canonicalJSONString(AgentCanonicalToolResultEnvelope(
            kind: "tool_result",
            body: result
        ))
        try enforceUTF8Limit(
            text,
            kind: .textPartUTF8Bytes,
            limit: configuration.limits.maximumTextPartUTF8Bytes
        )
    }

    func validate(artifact: ArtifactReference) throws {
        guard Self.safeIdentity(artifact.mediaType, maximumUTF8Count: 255),
              Self.safeIdentity(artifact.contentDigest, maximumUTF8Count: 2_048),
              !artifact.displayName.isEmpty,
              artifact.displayName.utf8.count <= 512,
              !artifact.displayName.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw AgentCanonicalContextPreparerError.invalidArtifact(
                artifact.artifactID,
                "invalid_reference"
            )
        }
    }

    func validate(
        checkpoint: ContextCheckpointReference,
        knownItemIDs: Set<ModelItemID>?
    ) throws {
        let sourceIDs = Set(checkpoint.sourceItemIDs)
        guard checkpoint.schemaVersion == .current,
              !checkpoint.summary.isEmpty,
              checkpoint.summary.utf8.count <= configuration.limits.maximumTextPartUTF8Bytes,
              Self.safeIdentity(checkpoint.sourceDigest, maximumUTF8Count: 512),
              sourceIDs.count == checkpoint.sourceItemIDs.count,
              knownItemIDs.map({ sourceIDs.isSubset(of: $0) }) != false
        else {
            throw AgentCanonicalContextPreparerError.invalidCheckpoint(
                checkpoint.checkpointID,
                "invalid_reference_or_sources"
            )
        }
    }
}

// MARK: - Canonical helpers

private extension AgentCanonicalContextPreparer {
    func eventSequence(
        in state: AgentDomain.AgentRunState
    ) throws -> EventSequence {
        guard let sequence = state.lastSequence else {
            throw AgentCanonicalContextPreparerError.missingEventCursor
        }
        return sequence
    }

    func metadata(
        sequence: EventSequence,
        state: AgentDomain.AgentRunState
    ) -> JSONValue {
        let context = configuration.context
        var values: [String: JSONValue] = [
            "scheme": .string("novaforge_agent_context_v1"),
            "run_id": .string(context.lineage.runID.description),
            "conversation_id": .string(context.conversationID.description),
            "workspace_id": .string(context.workspaceID.description),
            "execution_node_id": .string(context.executionNodeID.description),
            "event_sequence": .string(String(sequence.rawValue)),
            "provider_id": .string(configuration.providerID.rawValue),
            "item_count": .string(String(state.modelItems.count)),
            "tool_count": .string(String(configuration.toolLocalities.count)),
        ]
        if let projectID = context.projectID {
            values["project_id"] = .string(projectID.description)
        }
        return .object(values)
    }

    func validateJSON(
        _ value: JSONValue,
        context: String,
        nodeCount: inout Int,
        depth: Int = 1
    ) throws {
        guard depth <= configuration.limits.maximumJSONDepth else {
            throw AgentCanonicalContextPreparerError.limitExceeded(
                .jsonDepth,
                actual: UInt64(depth),
                limit: UInt64(configuration.limits.maximumJSONDepth)
            )
        }
        let next = nodeCount.addingReportingOverflow(1)
        guard !next.overflow else {
            throw AgentCanonicalContextPreparerError.arithmeticOverflow
        }
        nodeCount = next.partialValue
        guard nodeCount <= configuration.limits.maximumJSONNodes else {
            throw AgentCanonicalContextPreparerError.limitExceeded(
                .jsonNodes,
                actual: UInt64(nodeCount),
                limit: UInt64(configuration.limits.maximumJSONNodes)
            )
        }
        switch value {
        case .null, .bool, .number(.integer), .number(.unsignedInteger):
            return
        case let .number(.floatingPoint(number)):
            guard number.isFinite else {
                throw AgentCanonicalContextPreparerError.invalidJSON(context)
            }
        case let .string(string):
            guard string.utf8.count <= configuration.limits.maximumTextPartUTF8Bytes else {
                throw AgentCanonicalContextPreparerError.limitExceeded(
                    .textPartUTF8Bytes,
                    actual: UInt64(string.utf8.count),
                    limit: UInt64(configuration.limits.maximumTextPartUTF8Bytes)
                )
            }
        case let .array(values):
            for child in values {
                try validateJSON(
                    child,
                    context: context,
                    nodeCount: &nodeCount,
                    depth: depth + 1
                )
            }
        case let .object(values):
            for key in values.keys.sorted() {
                guard !key.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                }), key.utf8.count <= 512, let child = values[key] else {
                    throw AgentCanonicalContextPreparerError.invalidJSON(context)
                }
                try validateJSON(
                    child,
                    context: context,
                    nodeCount: &nodeCount,
                    depth: depth + 1
                )
            }
        }
    }

    func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw AgentCanonicalContextPreparerError.canonicalEncodingFailed
        }
    }

    func canonicalJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try canonicalData(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentCanonicalContextPreparerError.canonicalEncodingFailed
        }
        return string
    }

    func enforceUTF8Limit(
        _ value: String,
        kind: AgentCanonicalContextLimitKind,
        limit: Int
    ) throws {
        try enforceLimit(kind, actual: value.utf8.count, limit: limit)
    }

    func enforceLimit(
        _ kind: AgentCanonicalContextLimitKind,
        actual: Int,
        limit: Int
    ) throws {
        guard actual <= limit else {
            throw AgentCanonicalContextPreparerError.limitExceeded(
                kind,
                actual: UInt64(actual),
                limit: UInt64(limit)
            )
        }
    }

    func enforceLimit(
        _ kind: AgentCanonicalContextLimitKind,
        actual: UInt64,
        limit: UInt64
    ) throws {
        guard actual <= limit else {
            throw AgentCanonicalContextPreparerError.limitExceeded(
                kind,
                actual: actual,
                limit: limit
            )
        }
    }

    static func safeIdentity(_ value: String, maximumUTF8Count: Int) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Count,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    static func safeMetadataIdentity(
        _ value: String,
        maximumUTF8Count: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumUTF8Count else { return false }
        return bytes.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || byte == 45
                || byte == 46
                || byte == 58
                || byte == 95
        }
    }

    static func validToolName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count <= 64,
              let first = bytes.first,
              (97 ... 122).contains(first)
        else { return false }
        return bytes.allSatisfy {
            (97 ... 122).contains($0)
                || (48 ... 57).contains($0)
                || $0 == 95
        }
    }

    func artifactValue(_ artifact: ArtifactReference) -> JSONValue {
        .object([
            "kind": .string("artifact_reference"),
            "artifact_id": .string(artifact.artifactID.description),
            "media_type": .string(artifact.mediaType),
            "content_digest": .string(artifact.contentDigest),
            "display_name": .string(artifact.displayName),
        ])
    }
}

// MARK: - Full descriptor binding

private extension AgentCanonicalContextPreparer {
    func toolContract(
        _ descriptor: ToolDescriptor,
        locality: ToolExecutionLocality
    ) -> JSONValue {
        .object([
            "name": .string(descriptor.name),
            "version": .object([
                "major": .number(.integer(Int64(descriptor.version.major))),
                "minor": .number(.integer(Int64(descriptor.version.minor))),
                "patch": .number(.integer(Int64(descriptor.version.patch))),
            ]),
            "aliases": .array(descriptor.aliases.map(JSONValue.string)),
            "toolset": .string(descriptor.toolset),
            "description": .string(descriptor.description),
            "source_schema": descriptor.argumentSchema.providerValue,
            "provider_schema": descriptor.argumentSchema.strictProviderValue,
            "availability": .object([
                "allowed_localities": .array(
                    descriptor.availability.allowedLocalities.map {
                        .string($0.rawValue)
                    }
                ),
                "required_capabilities": .array(
                    descriptor.availability.requiredCapabilities.map {
                        .string($0.rawValue)
                    }
                ),
                "requires_workspace": .bool(
                    descriptor.availability.requiresWorkspace
                ),
            ]),
            "effect_class": .string(descriptor.effectClass.rawValue),
            "approval_class": .string(descriptor.approvalClass.rawValue),
            "target_strategy": targetStrategyValue(descriptor.targetStrategy),
            "parallel_safety": .string(descriptor.parallelSafety.rawValue),
            "concurrency_key": descriptor.concurrencyKey.map(JSONValue.string) ?? .null,
            "locality": .string(locality.rawValue),
            "limits": .object([
                "timeout_milliseconds": .number(.integer(
                    Int64(descriptor.limits.timeoutMilliseconds)
                )),
                "maximum_argument_bytes": .number(.integer(
                    Int64(descriptor.limits.maximumArgumentBytes)
                )),
                "maximum_output_bytes": .number(.integer(
                    Int64(descriptor.limits.maximumOutputBytes)
                )),
            ]),
            "redaction": redactionValue(descriptor.redaction),
            "legacy_adapter": legacyAdapterValue(descriptor.legacyAdapter),
            "receipt": .object([
                "action_verb": .string(descriptor.receipt.actionVerb),
                "success_summary": .string(descriptor.receipt.successSummary),
            ]),
            "evidence": .string(descriptor.evidence.rawValue),
            "ui": .object([
                "title": .string(descriptor.ui.title),
                "system_image_name": .string(descriptor.ui.systemImageName),
                "category": .string(descriptor.ui.category.rawValue),
                "result_presentation": .string(
                    descriptor.ui.resultPresentation.rawValue
                ),
            ]),
        ])
    }

    func targetStrategyValue(_ strategy: ToolTargetStrategy) -> JSONValue {
        switch strategy {
        case let .workspaceRoot(access):
            return .object([
                "kind": .string("workspace_root"),
                "access": .string(access.rawValue),
            ])
        case let .argumentPaths(rules):
            return .object([
                "kind": .string("argument_paths"),
                "rules": .array(rules.map(targetRuleValue)),
            ])
        case let .arrayArgumentPaths(arrayPath, rules):
            return .object([
                "kind": .string("array_argument_paths"),
                "array_path": .array(arrayPath.map(JSONValue.string)),
                "rules": .array(rules.map(targetRuleValue)),
            ])
        case .legacyCommandParserRequired:
            return .object(["kind": .string("legacy_command_parser_required")])
        }
    }

    func targetRuleValue(_ rule: ToolTargetRule) -> JSONValue {
        .object([
            "argument_path": .array(rule.argumentPath.map(JSONValue.string)),
            "access": .string(rule.access.rawValue),
            "optional": .bool(rule.optional),
            "default_value": rule.defaultValue.map(JSONValue.string) ?? .null,
        ])
    }

    func redactionValue(_ redaction: ToolRedactionPolicy) -> JSONValue {
        let output: JSONValue
        switch redaction.output {
        case .none:
            output = .object(["kind": .string("none")])
        case let .replace(value):
            output = .object([
                "kind": .string("replace"),
                "value": value,
            ])
        }
        return .object([
            "argument_rules": .array(redaction.argumentRules.map { rule in
                .object([
                    "path": .array(rule.path.map(JSONValue.string)),
                    "replacement": rule.replacement,
                ])
            }),
            "output": output,
        ])
    }

    func legacyAdapterValue(
        _ adapter: LegacySandboxToolAdapterContract?
    ) -> JSONValue {
        guard let adapter else { return .null }
        return .object([
            "executor_name": .string(adapter.executorName),
            "supported_major_version": .number(.integer(
                Int64(adapter.supportedMajorVersion)
            )),
            "field_mappings": .array(adapter.fieldMappings.map { mapping in
                .object([
                    "argument_name": .string(mapping.argumentName),
                    "encoding": .string(mapping.encoding.rawValue),
                    "omit_if_null": .bool(mapping.omitIfNull),
                ])
            }),
        ])
    }
}

private struct AgentCanonicalContextSupplement: Encodable {
    let kind: String
    let artifacts: [ArtifactReference]
    let checkpoints: [ContextCheckpointReference]
}

private struct AgentCanonicalReasoningEnvelope: Encodable {
    let kind: String
    let body: ReasoningSummary
}

private struct AgentCanonicalToolResultEnvelope: Encodable {
    let kind: String
    let body: ToolResult
}

private struct AgentCanonicalCheckpointEnvelope: Encodable {
    let kind: String
    let body: ContextCheckpointReference
}

private struct AgentCanonicalContextDigestMaterial: Encodable {
    let scheme: String
    let context: AgentRunContext
    let providerID: String
    let preferredAdapterIDs: [String]
    let request: CanonicalProviderRequest
    let state: AgentDomain.AgentRunState
    let orderedItemIDs: [String]
    let toolContracts: [JSONValue]
}
