import AgentDomain
import CryptoKit
import Foundation

public protocol ProviderAdapter: Sendable {
    var descriptor: ProviderAdapterDescriptor { get }
    func encode(_ request: CanonicalProviderRequest) throws -> ProviderEncodedRequest
}

extension ProviderAdapter {
    func makeStreamSession(
        scope: ProviderAttemptScope,
        request: CanonicalProviderRequest
    ) -> ProviderStreamSession {
        ProviderStreamSession(descriptor: descriptor, scope: scope, request: request)
    }

    func translateStream(
        _ frames: [ProviderWireFrame],
        scope: ProviderAttemptScope,
        request: CanonicalProviderRequest
    ) throws -> [ProviderAttemptEvent] {
        var session = makeStreamSession(scope: scope, request: request)
        var events: [ProviderAttemptEvent] = []
        for frame in frames {
            events.append(contentsOf: try session.receive(frame))
        }
        events.append(contentsOf: try session.finish())
        return events
    }

    func translateJSONStream(
        _ values: [JSONValue],
        scope: ProviderAttemptScope,
        request: CanonicalProviderRequest
    ) throws -> [ProviderAttemptEvent] {
        try translateStream(
            values.map(ProviderWireFrame.json) + [.done],
            scope: scope,
            request: request
        )
    }
}

public struct OpenAIChatCompletionsAdapter: ProviderAdapter {
    public let descriptor: ProviderAdapterDescriptor

    public init(
        model: ProviderModelID,
        capabilities: ProviderModelCapabilities = .openAIChatBaseline
    ) {
        descriptor = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: ProviderID(rawValue: "openai"),
                modelID: model,
                adapterID: ProviderAdapterID(rawValue: "openai-chat-completions"),
                capabilities: capabilities,
                deployment: .hostedService,
                provenance: .builtInOpenAIChatCompletions
            ),
            dialect: .openAIChatCompletions,
            requestPath: "/v1/chat/completions"
        )
    }

    public func encode(_ request: CanonicalProviderRequest) throws -> ProviderEncodedRequest {
        try ProviderRequestEncoder.encodeChat(request, descriptor: descriptor)
    }

}

/// Package-owned OpenCode Zen route. The provider implements the OpenAI Chat
/// Completions wire contract, while the distinct identity/provenance keeps its
/// credential and endpoint authority separate from OpenAI.
public struct OpenCodeZenChatCompletionsAdapter: ProviderAdapter {
    public let descriptor: ProviderAdapterDescriptor

    public init(
        model: ProviderModelID,
        capabilities: ProviderModelCapabilities = .openAICompatibleBaseline
    ) {
        descriptor = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: ProviderID(rawValue: "opencode-zen"),
                modelID: model,
                adapterID: ProviderAdapterID(
                    rawValue: "opencode-zen-chat-completions"
                ),
                capabilities: capabilities,
                deployment: .hostedService,
                provenance: .builtInOpenCodeZenChatCompletions
            ),
            dialect: .openAIChatCompletions,
            requestPath: "/zen/v1/chat/completions"
        )
    }

    public func encode(
        _ request: CanonicalProviderRequest
    ) throws -> ProviderEncodedRequest {
        try ProviderRequestEncoder.encodeChat(request, descriptor: descriptor)
    }
}

public struct OpenAIResponsesAdapter: ProviderAdapter {
    public let descriptor: ProviderAdapterDescriptor

    public init(
        model: ProviderModelID,
        capabilities: ProviderModelCapabilities = .openAIResponsesBaseline
    ) {
        descriptor = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: ProviderID(rawValue: "openai"),
                modelID: model,
                adapterID: ProviderAdapterID(rawValue: "openai-responses"),
                capabilities: capabilities,
                deployment: .hostedService,
                provenance: .builtInOpenAIResponses
            ),
            dialect: .openAIResponses,
            requestPath: "/v1/responses"
        )
    }

    public func encode(_ request: CanonicalProviderRequest) throws -> ProviderEncodedRequest {
        try ProviderRequestEncoder.encodeResponses(request, descriptor: descriptor)
    }

}

/// ChatGPT subscription-backed Codex Responses route. This is deliberately a
/// separate provider identity from API-key OpenAI Responses so credentials,
/// endpoint binding, and recovery policy cannot be mixed accidentally.
public struct OpenAICodexResponsesAdapter: ProviderAdapter {
    public let descriptor: ProviderAdapterDescriptor

    public init(
        model: ProviderModelID,
        capabilities: ProviderModelCapabilities = .openAIResponsesBaseline
    ) {
        descriptor = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: ProviderID(rawValue: "openai-codex"),
                modelID: model,
                adapterID: ProviderAdapterID(rawValue: "openai-codex-responses"),
                capabilities: capabilities,
                deployment: .hostedService,
                provenance: .builtInOpenAICodexResponses
            ),
            dialect: .openAIResponses,
            requestPath: "/codex/responses"
        )
    }

    public func encode(
        _ request: CanonicalProviderRequest
    ) throws -> ProviderEncodedRequest {
        try ProviderRequestEncoder.encodeResponses(request, descriptor: descriptor)
    }
}

public struct OpenAICompatibleAdapterConfiguration: Codable, Equatable, Sendable {
    public let providerID: ProviderID
    public let adapterID: ProviderAdapterID
    public let modelID: ProviderModelID
    /// Relative endpoint path only. Base URLs and credentials remain transport-owned.
    public let requestPath: String
    public let capabilities: ProviderModelCapabilities

    public init(
        providerID: ProviderID,
        adapterID: ProviderAdapterID,
        modelID: ProviderModelID,
        requestPath: String = "/v1/chat/completions",
        capabilities: ProviderModelCapabilities = .openAICompatibleBaseline
    ) {
        self.providerID = providerID
        self.adapterID = adapterID
        self.modelID = modelID
        self.requestPath = requestPath
        self.capabilities = capabilities
    }
}

/// Translation for endpoints implementing the OpenAI chat-completions wire contract.
public struct OpenAICompatibleAdapter: ProviderAdapter {
    public let descriptor: ProviderAdapterDescriptor

    public init(configuration: OpenAICompatibleAdapterConfiguration) {
        descriptor = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: configuration.providerID,
                modelID: configuration.modelID,
                adapterID: configuration.adapterID,
                capabilities: configuration.capabilities,
                deployment: .callerManaged,
                provenance: .callerConfigured
            ),
            dialect: .openAICompatibleChat,
            requestPath: configuration.requestPath
        )
    }

    public func encode(_ request: CanonicalProviderRequest) throws -> ProviderEncodedRequest {
        guard isSafeProviderRelativePath(descriptor.requestPath) else {
            throw ProviderFailureMapper.invalidRequest(
                "provider_endpoint_path_not_relative",
                descriptor: descriptor,
                message: "The provider adapter requires a relative endpoint path."
            )
        }
        return try ProviderRequestEncoder.encodeChat(request, descriptor: descriptor)
    }

}

public enum LocalModelAdapterConfigurationError: Error, Equatable, Sendable {
    case invalidAdapterID
    case invalidModelID
    case invalidContextWindow
    case invalidOutputLimit
    case invalidAttestationDigest
    case invalidGrammarCompilerID
    case invalidToolDefinitionCount
    case invalidToolLimit
    case invalidParallelToolLimit
}

/// Opaque package-minted proof used only after a backend verifier binds a
/// compiled grammar to the canonical tool catalog. It is deliberately not
/// Codable and has no public initializer, so persisted strings cannot mint
/// local tool capability.
public struct LocalModelGrammarAttestation: Equatable, Sendable {
    public let grammarSHA256: String
    public let toolCatalogSHA256: String
    let orderedToolCatalogSHA256: String?
    public let toolDefinitionCount: UInt32
    public let compilerID: String
    public let maximumToolCallsPerTurn: UInt32
    public let supportsParallelToolCalls: Bool

    init(
        grammarSHA256: String,
        toolCatalogSHA256: String,
        orderedToolCatalogSHA256: String? = nil,
        toolDefinitionCount: UInt32 = 1,
        compilerID: String,
        maximumToolCallsPerTurn: UInt32,
        supportsParallelToolCalls: Bool = false
    ) {
        self.grammarSHA256 = grammarSHA256
        self.toolCatalogSHA256 = toolCatalogSHA256
        self.orderedToolCatalogSHA256 = orderedToolCatalogSHA256
        self.toolDefinitionCount = toolDefinitionCount
        self.compilerID = compilerID
        self.maximumToolCallsPerTurn = maximumToolCallsPerTurn
        self.supportsParallelToolCalls = supportsParallelToolCalls
    }

    static func canonicalToolCatalogSHA256(
        for tools: [ProviderToolDefinition]
    ) throws -> String {
        let material = LocalToolCatalogDigestMaterial(
            scheme: "novaforge-local-tool-catalog-v1",
            tools: tools.sorted { lhs, rhs in
                if lhs.name == rhs.name { return lhs.description < rhs.description }
                return lhs.name < rhs.name
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(material))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:" + digest
    }

    static func canonicalOrderedToolCatalogSHA256(
        for tools: [ProviderToolDefinition]
    ) throws -> String {
        let material = LocalToolCatalogDigestMaterial(
            scheme: "novaforge-local-ordered-tool-catalog-v1",
            tools: tools
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(material))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:" + digest
    }
}

public enum LocalModelToolMode: Equatable, Sendable {
    case textOnly
    case grammarConstrained(LocalModelGrammarAttestation)
}

public struct LocalModelAdapterConfiguration: Equatable, Sendable {
    public let adapterID: ProviderAdapterID
    public let modelID: ProviderModelID
    public let contextWindowTokens: UInt64
    public let maximumOutputTokens: UInt64
    public let toolMode: LocalModelToolMode

    public init(
        adapterID: ProviderAdapterID = .init(rawValue: "novaforge-local-llama"),
        modelID: ProviderModelID,
        contextWindowTokens: UInt64 = ProviderModelCapabilities.localTextBaseline.contextWindowTokens,
        maximumOutputTokens: UInt64 = ProviderModelCapabilities.localTextBaseline.maximumOutputTokens,
        toolMode: LocalModelToolMode = .textOnly
    ) {
        self.adapterID = adapterID
        self.modelID = modelID
        self.contextWindowTokens = contextWindowTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.toolMode = toolMode
    }
}

/// Built-in on-device route using the same canonical request, attempt, stream,
/// retry, cancellation, and usage contracts as hosted adapters. The local
/// transport owns model loading and converts token/tool output with
/// `LocalModelWireSession`; it never receives credentials or a remote URL.
public struct LocalModelAdapter: ProviderAdapter {
    public let descriptor: ProviderAdapterDescriptor
    private let grammarAttestation: LocalModelGrammarAttestation?

    public init(configuration: LocalModelAdapterConfiguration) throws {
        try Self.validate(configuration)
        switch configuration.toolMode {
        case .textOnly:
            grammarAttestation = nil
        case let .grammarConstrained(attestation):
            grammarAttestation = attestation
        }
        descriptor = ProviderAdapterDescriptor(
            route: ProviderRoute(
                providerID: ProviderID(rawValue: "novaforge-local"),
                modelID: configuration.modelID,
                adapterID: configuration.adapterID,
                capabilities: Self.capabilities(configuration),
                deployment: .onDevice,
                provenance: .builtInLocalModel
            ),
            dialect: .openAICompatibleChat,
            requestPath: "/v1/local/chat/completions"
        )
    }

    public func encode(_ request: CanonicalProviderRequest) throws -> ProviderEncodedRequest {
        let encoded = try ProviderRequestEncoder.encodeChat(request, descriptor: descriptor)
        guard let grammarAttestation else { return encoded }
        guard UInt32(exactly: request.tools.count) == grammarAttestation.toolDefinitionCount else {
            throw ProviderFailureMapper.invalidRequest(
                "provider_local_tool_catalog_count_mismatch",
                descriptor: descriptor,
                message: "The local grammar is not attested for this tool catalog."
            )
        }
        let digest = try LocalModelGrammarAttestation.canonicalToolCatalogSHA256(
            for: request.tools
        )
        guard digest == grammarAttestation.toolCatalogSHA256 else {
            throw ProviderFailureMapper.invalidRequest(
                "provider_local_tool_catalog_digest_mismatch",
                descriptor: descriptor,
                message: "The local grammar is not attested for this tool catalog."
            )
        }
        if let expected = grammarAttestation.orderedToolCatalogSHA256 {
            let ordered = try LocalModelGrammarAttestation
                .canonicalOrderedToolCatalogSHA256(for: request.tools)
            guard ordered == expected else {
                throw ProviderFailureMapper.invalidRequest(
                    "provider_local_tool_catalog_order_mismatch",
                    descriptor: descriptor,
                    message: "The local grammar requires the canonical tool-definition order."
                )
            }
        }
        return encoded
    }

    private static func capabilities(
        _ configuration: LocalModelAdapterConfiguration
    ) -> ProviderModelCapabilities {
        var features: [ProviderCapability] = [
            .cancellation,
            .streaming,
            .temperature,
            .usageStreaming,
        ]
        let maximumToolDefinitions: UInt32
        let maximumToolCalls: UInt32
        switch configuration.toolMode {
        case .textOnly:
            maximumToolDefinitions = 0
            maximumToolCalls = 0
        case let .grammarConstrained(attestation):
            maximumToolDefinitions = attestation.toolDefinitionCount
            features.append(contentsOf: [
                .strictToolSchema,
                .tools,
                .typedToolArguments,
            ])
            if attestation.supportsParallelToolCalls {
                features.append(.parallelToolCalls)
                maximumToolCalls = attestation.maximumToolCallsPerTurn
            } else {
                // Every tool call in one model turn is concurrent from the
                // engine's perspective. A non-parallel route must therefore
                // advertise and enforce a one-call ceiling even if its grammar
                // compiler can represent a larger array.
                maximumToolCalls = 1
            }
        }
        return ProviderModelCapabilities(
            features: ProviderCapabilitySet(features),
            contextWindowTokens: configuration.contextWindowTokens,
            maximumOutputTokens: configuration.maximumOutputTokens,
            maximumToolDefinitions: maximumToolDefinitions,
            maximumToolCallsPerTurn: maximumToolCalls
        )
    }

    private static func validate(
        _ configuration: LocalModelAdapterConfiguration
    ) throws {
        guard isSafeIdentity(configuration.adapterID.rawValue) else {
            throw LocalModelAdapterConfigurationError.invalidAdapterID
        }
        guard isSafeIdentity(configuration.modelID.rawValue) else {
            throw LocalModelAdapterConfigurationError.invalidModelID
        }
        guard configuration.contextWindowTokens > 0 else {
            throw LocalModelAdapterConfigurationError.invalidContextWindow
        }
        guard configuration.maximumOutputTokens > 0,
              configuration.maximumOutputTokens <= configuration.contextWindowTokens
        else { throw LocalModelAdapterConfigurationError.invalidOutputLimit }

        guard case let .grammarConstrained(attestation) = configuration.toolMode else {
            return
        }
        guard isSHA256(attestation.grammarSHA256),
              isSHA256(attestation.toolCatalogSHA256),
              attestation.orderedToolCatalogSHA256.map(isSHA256) ?? true
        else { throw LocalModelAdapterConfigurationError.invalidAttestationDigest }
        guard isSafeIdentity(attestation.compilerID) else {
            throw LocalModelAdapterConfigurationError.invalidGrammarCompilerID
        }
        guard (1 ... 128).contains(attestation.toolDefinitionCount) else {
            throw LocalModelAdapterConfigurationError.invalidToolDefinitionCount
        }
        guard (1 ... 128).contains(attestation.maximumToolCallsPerTurn) else {
            throw LocalModelAdapterConfigurationError.invalidToolLimit
        }
        guard !attestation.supportsParallelToolCalls ||
                attestation.maximumToolCallsPerTurn >= 2
        else { throw LocalModelAdapterConfigurationError.invalidParallelToolLimit }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value.utf8.count == 71 else { return false }
        return value.utf8.dropFirst(7).allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func isSafeIdentity(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }
}

private enum ProviderRequestEncoder {
    static func encodeChat(
        _ request: CanonicalProviderRequest,
        descriptor: ProviderAdapterDescriptor
    ) throws -> ProviderEncodedRequest {
        try validate(request, descriptor: descriptor)

        var body: [String: JSONValue] = [
            "model": .string(request.model.rawValue),
            "messages": .array(try request.messages.map(chatMessage)),
            "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]),
            "metadata": request.metadata,
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.parameters,
                        "strict": .bool(tool.strict),
                    ]),
                ])
            })
            body["tool_choice"] = chatToolChoice(request.options.toolChoice)
        }
        if let maximum = request.options.maximumOutputTokens {
            let maximumOutputKey = descriptor.route.provenance ==
                .builtInOpenCodeZenChatCompletions
                ? "max_tokens"
                : "max_completion_tokens"
            body[maximumOutputKey] = .number(.unsignedInteger(maximum))
        }
        if let temperature = request.options.temperature {
            body["temperature"] = .number(.floatingPoint(temperature))
        }
        if let parallel = request.options.parallelToolCalls {
            body["parallel_tool_calls"] = .bool(parallel)
        }
        if let cacheKey = request.options.promptCacheKey {
            body["prompt_cache_key"] = .string(cacheKey)
        }
        return ProviderEncodedRequest(relativePath: descriptor.requestPath, body: .object(body))
    }

    static func encodeResponses(
        _ request: CanonicalProviderRequest,
        descriptor: ProviderAdapterDescriptor
    ) throws -> ProviderEncodedRequest {
        try validate(request, descriptor: descriptor)

        let isChatGPTCodex = descriptor.route.provenance ==
            .builtInOpenAICodexResponses
        let inputMessages = isChatGPTCodex
            ? request.messages.filter {
                $0.role != .system && $0.role != .developer
            }
            : request.messages
        var body: [String: JSONValue] = [
            "model": .string(request.model.rawValue),
            "input": .array(try inputMessages.flatMap(responsesInputs)),
            "stream": .bool(true),
        ]
        if isChatGPTCodex {
            body["store"] = .bool(false)
            if let instructions = try responsesInstructions(request.messages) {
                body["instructions"] = .string(instructions)
            }
        } else {
            body["metadata"] = request.metadata
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "parameters": tool.parameters,
                    "strict": .bool(tool.strict),
                ])
            })
            body["tool_choice"] = responsesToolChoice(request.options.toolChoice)
        }
        if !isChatGPTCodex,
           let maximum = request.options.maximumOutputTokens {
            body["max_output_tokens"] = .number(.unsignedInteger(maximum))
        }
        if let temperature = request.options.temperature {
            body["temperature"] = .number(.floatingPoint(temperature))
        }
        if let parallel = request.options.parallelToolCalls {
            body["parallel_tool_calls"] = .bool(parallel)
        }
        if request.options.reasoningSummary == true || request.options.reasoningEffort != nil {
            var reasoning: [String: JSONValue] = [:]
            if request.options.reasoningSummary == true {
                reasoning["summary"] = .string("auto")
            }
            if let effort = request.options.reasoningEffort {
                reasoning["effort"] = .string(effort.rawValue)
            }
            body["reasoning"] = .object(reasoning)
        }
        if let cacheKey = request.options.promptCacheKey {
            body["prompt_cache_key"] = .string(cacheKey)
        }
        if let previousResponseID = request.options.previousResponseID {
            body["previous_response_id"] = .string(previousResponseID)
        }
        return ProviderEncodedRequest(relativePath: descriptor.requestPath, body: .object(body))
    }

    private static func responsesInstructions(
        _ messages: [ProviderMessage]
    ) throws -> String? {
        let instructionMessages = messages.filter {
            $0.role == .system || $0.role == .developer
        }
        guard !instructionMessages.isEmpty else { return nil }

        var sections: [String] = []
        for message in instructionMessages {
            for part in message.content {
                switch part {
                case let .text(text):
                    sections.append(text)
                case let .structured(value):
                    sections.append(try canonicalJSONString(value))
                case .image, .toolCall:
                    throw EncodingError.invalidValue(
                        part,
                        .init(
                            codingPath: [],
                            debugDescription: "ChatGPT instructions must be text or structured JSON."
                        )
                    )
                }
            }
        }
        let joined = sections.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    private static func validate(
        _ request: CanonicalProviderRequest,
        descriptor: ProviderAdapterDescriptor
    ) throws {
        guard request.model == descriptor.route.modelID else {
            throw ProviderFailureMapper.invalidRequest(
                "provider_model_route_mismatch",
                descriptor: descriptor,
                message: "The request model does not match the selected provider route."
            )
        }
        do {
            try ProviderRequestBudget.validate(request)
        } catch {
            throw ProviderFailureMapper.invalidRequest(
                "provider_request_budget_exceeded",
                descriptor: descriptor,
                message: "The provider request exceeds the bounded request budget."
            )
        }
        guard descriptor.route.capabilities.features.isSuperset(of: request.requiredCapabilities) else {
            throw ProviderFailureMapper.invalidRequest(
                "provider_unsupported_capability",
                descriptor: descriptor,
                message: "The selected provider route does not support the request."
            )
        }
        guard descriptor.route.capabilities.contextWindowTokens >=
                (request.options.minimumContextWindowTokens ?? 0) else {
            throw ProviderFailureMapper.invalidRequest(
                "provider_context_window_too_small",
                descriptor: descriptor,
                message: "The selected provider route has an insufficient context window."
            )
        }
        guard request.tools.count <= Int(descriptor.route.capabilities.maximumToolDefinitions) else {
            throw ProviderFailureMapper.invalidRequest(
                "provider_tool_definition_limit_exceeded",
                descriptor: descriptor,
                message: "The request contains too many tool definitions for this route."
            )
        }
        let requirements = request.capabilityRequirements
        guard descriptor.route.capabilities.maximumToolCallsPerTurn >=
                requirements.minimumToolCallsPerTurn else {
            throw ProviderFailureMapper.invalidRequest(
                "provider_tool_call_limit_insufficient",
                descriptor: descriptor,
                message: "The selected provider route cannot emit the requested tool-call shape."
            )
        }
        if let maximum = request.options.maximumOutputTokens,
           maximum > descriptor.route.capabilities.maximumOutputTokens {
            throw ProviderFailureMapper.invalidRequest(
                "provider_output_limit_exceeded",
                descriptor: descriptor,
                message: "The requested output exceeds the model limit."
            )
        }
        if let temperature = request.options.temperature,
           (!temperature.isFinite || !(0 ... 2).contains(temperature)) {
            throw ProviderFailureMapper.invalidRequest(
                "provider_temperature_invalid",
                descriptor: descriptor,
                message: "Temperature must be finite and between 0 and 2."
            )
        }
        if let cacheKey = request.options.promptCacheKey, cacheKey.isEmpty {
            throw ProviderFailureMapper.invalidRequest(
                "provider_prompt_cache_key_invalid",
                descriptor: descriptor,
                message: "Prompt cache keys must be nonempty."
            )
        }
        if let previousResponseID = request.options.previousResponseID, previousResponseID.isEmpty {
            throw ProviderFailureMapper.invalidRequest(
                "provider_previous_response_id_invalid",
                descriptor: descriptor,
                message: "Previous response IDs must be nonempty."
            )
        }
        var toolNames: Set<String> = []
        for tool in request.tools {
            guard isSafeToolName(tool.name), case .object = tool.parameters,
                  toolNames.insert(tool.name).inserted
            else {
                throw ProviderFailureMapper.invalidRequest(
                    "provider_tool_schema_invalid",
                    descriptor: descriptor,
                    message: "Tool names must be unique safe identifiers and parameters must be JSON objects."
                )
            }
            do {
                try ProviderJSONSchemaValidator.validateSchema(tool.parameters)
            } catch {
                throw ProviderFailureMapper.invalidRequest(
                    "provider_tool_schema_invalid",
                    descriptor: descriptor,
                    message: "Tool parameter schemas must use the bounded supported JSON Schema subset."
                )
            }
        }
        guard descriptor.route.capabilities.supports(requirements) else {
            throw ProviderFailureMapper.invalidRequest(
                "provider_unsupported_capability",
                descriptor: descriptor,
                message: "The selected provider route does not support the request."
            )
        }
        switch request.options.toolChoice {
        case .auto, .none:
            break
        case .required where request.tools.isEmpty:
            throw ProviderFailureMapper.invalidRequest(
                "provider_required_tool_catalog_missing",
                descriptor: descriptor,
                message: "Required tool choice needs a nonempty tool catalog."
            )
        case let .named(name) where !toolNames.contains(name):
            throw ProviderFailureMapper.invalidRequest(
                "provider_named_tool_not_found",
                descriptor: descriptor,
                message: "The named tool choice is not present in the catalog."
            )
        default:
            break
        }
        if request.options.parallelToolCalls == true, request.tools.isEmpty {
            throw ProviderFailureMapper.invalidRequest(
                "provider_parallel_tool_catalog_missing",
                descriptor: descriptor,
                message: "Parallel tool mode needs a nonempty tool catalog."
            )
        }
        for message in request.messages where message.role == .tool {
            guard let callID = message.toolCallID, !callID.isEmpty else {
                throw ProviderFailureMapper.invalidRequest(
                    "provider_tool_result_missing_call_id",
                    descriptor: descriptor,
                    message: "Tool result messages require a call ID."
                )
            }
        }
        for message in request.messages {
            for part in message.content {
                guard case let .toolCall(call) = part else { continue }
                guard message.role == .assistant,
                      !call.callID.isEmpty,
                      !call.name.isEmpty,
                      case .object = call.arguments
                else {
                    throw ProviderFailureMapper.invalidRequest(
                        "provider_transcript_tool_call_invalid",
                        descriptor: descriptor,
                        message: "Transcript tool calls require an assistant role, identity, name, and object arguments."
                    )
                }
            }
        }
    }

    private static func chatMessage(_ message: ProviderMessage) throws -> JSONValue {
        let ordinaryParts = message.content.filter {
            if case .toolCall = $0 { false } else { true }
        }
        var object: [String: JSONValue] = [
            "role": .string(message.role.rawValue),
            "content": ordinaryParts.isEmpty ? .null : chatContent(ordinaryParts),
        ]
        let calls = message.content.compactMap { part -> ProviderToolCallInput? in
            if case let .toolCall(call) = part { call } else { nil }
        }
        if !calls.isEmpty {
            object["tool_calls"] = .array(try calls.map { call in
                .object([
                    "id": .string(call.callID),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(call.name),
                        "arguments": .string(try canonicalJSONString(call.arguments)),
                    ]),
                ])
            })
        }
        if let callID = message.toolCallID { object["tool_call_id"] = .string(callID) }
        if let name = message.name { object["name"] = .string(name) }
        return .object(object)
    }

    private static func chatContent(_ parts: [ProviderContentPart]) -> JSONValue {
        if parts.count == 1, case let .text(text) = parts[0] {
            return .string(text)
        }
        return .array(parts.map { part in
            switch part {
            case let .text(text):
                .object(["type": .string("text"), "text": .string(text)])
            case let .structured(value):
                .object(["type": .string("json"), "json": value])
            case let .image(image):
                .object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string(image.source),
                        "detail": image.detail.map(JSONValue.string) ?? .null,
                    ]),
                ])
            case .toolCall:
                // Tool calls are encoded in the sibling `tool_calls` field.
                .null
            }
        })
    }

    private static func responsesInputs(_ message: ProviderMessage) throws -> [JSONValue] {
        if message.role == .tool {
            return [.object([
                "type": .string("function_call_output"),
                "call_id": .string(message.toolCallID ?? ""),
                "output": responsesToolOutput(message.content),
            ])]
        }

        let ordinaryParts = message.content.filter {
            if case .toolCall = $0 { false } else { true }
        }
        var result: [JSONValue] = []
        if !ordinaryParts.isEmpty {
            result.append(.object([
                "type": .string("message"),
                "role": .string(message.role.rawValue),
                "content": .array(ordinaryParts.map { part in
                switch part {
                case let .text(text):
                    .object([
                        "type": .string(message.role == .assistant ? "output_text" : "input_text"),
                        "text": .string(text),
                    ])
                case let .structured(value):
                    .object([
                        "type": .string(message.role == .assistant ? "output_json" : "input_json"),
                        "json": value,
                    ])
                case let .image(image):
                    .object([
                        "type": .string("input_image"),
                        "image_url": .string(image.source),
                        "detail": image.detail.map(JSONValue.string) ?? .null,
                    ])
                case .toolCall:
                    .null
                }
                }),
            ]))
        }
        for part in message.content {
            guard case let .toolCall(call) = part else { continue }
            result.append(.object([
                "type": .string("function_call"),
                "call_id": .string(call.callID),
                "name": .string(call.name),
                "arguments": .string(try canonicalJSONString(call.arguments)),
            ]))
        }
        return result
    }

    private static func responsesToolOutput(_ parts: [ProviderContentPart]) -> JSONValue {
        if parts.count == 1 {
            switch parts[0] {
            case let .text(text): return .string(text)
            case let .structured(value): return value
            case let .image(image):
                return .object([
                    "media_type": .string(image.mediaType),
                    "source": .string(image.source),
                ])
            case let .toolCall(call):
                return .object([
                    "call_id": .string(call.callID),
                    "name": .string(call.name),
                    "arguments": call.arguments,
                ])
            }
        }
        return .array(parts.map { part in
            switch part {
            case let .text(text): return .string(text)
            case let .structured(value): return value
            case let .image(image):
                return .object([
                    "media_type": .string(image.mediaType),
                    "source": .string(image.source),
                ])
            case let .toolCall(call):
                return .object([
                    "call_id": .string(call.callID),
                    "name": .string(call.name),
                    "arguments": call.arguments,
                ])
            }
        })
    }

    private static func canonicalJSONString(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: [], debugDescription: "Canonical JSON must be UTF-8.")
            )
        }
        return result
    }

    private static func isSafeToolName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    private static func chatToolChoice(_ choice: ProviderToolChoice) -> JSONValue {
        switch choice {
        case .auto: .string("auto")
        case .none: .string("none")
        case .required: .string("required")
        case let .named(name):
            .object([
                "type": .string("function"),
                "function": .object(["name": .string(name)]),
            ])
        }
    }

    private static func responsesToolChoice(_ choice: ProviderToolChoice) -> JSONValue {
        switch choice {
        case .auto: .string("auto")
        case .none: .string("none")
        case .required: .string("required")
        case let .named(name):
            .object(["type": .string("function"), "name": .string(name)])
        }
    }
}

private struct LocalToolCatalogDigestMaterial: Codable {
    let scheme: String
    let tools: [ProviderToolDefinition]
}

private func isSafeProviderRelativePath(_ value: String) -> Bool {
    guard value.hasPrefix("/"), !value.hasPrefix("//"),
          !value.contains("://"), !value.contains("?"),
          !value.contains("#"), !value.contains("\\"),
          value.utf8.count <= 2_048
    else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
        !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.controlCharacters.contains(scalar) &&
            scalar.properties.generalCategory != .format
    }
}
