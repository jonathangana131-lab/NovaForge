import AgentDomain
import Foundation

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ProviderModelID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ProviderAdapterID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// A caller-stable identity for one wire attempt. It is deliberately distinct
/// from the logical request ID so provisional output from a failed attempt can
/// never be mistaken for output from its retry.
public struct ProviderAttemptID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ProviderAttemptScope: Codable, Hashable, Sendable {
    public let requestID: String
    public let attemptID: ProviderAttemptID

    public init(requestID: String, attemptID: ProviderAttemptID) {
        self.requestID = requestID
        self.attemptID = attemptID
    }
}

public enum ProviderAdapterDialect: String, Codable, Hashable, Sendable {
    case openAIChatCompletions
    case openAIResponses
    case openAICompatibleChat
}

/// Canonical reasoning effort understood by Responses-style providers. The
/// value is part of the immutable request contract; UI labels and effects live
/// in the host app rather than in this transport package.
public enum ProviderReasoningEffort: String, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case none
    case low
    case medium
    case high
    case xhigh
    case max

    public static func < (lhs: Self, rhs: Self) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs)
        else { return lhs.rawValue < rhs.rawValue }
        return left < right
    }
}

/// Where the model endpoint is deployed. This is part of the route contract,
/// not an inference from a provider name or relative HTTP path.
public enum ProviderDeployment: String, Codable, Hashable, Sendable {
    case hostedService
    case onDevice
    case remoteWorker
    case callerManaged
}

/// The authority that supplied a route descriptor. This value is diagnostic;
/// sensitive capability minting additionally requires a package-sealed trusted
/// catalog, so callers cannot gain authority by encoding this enum.
public enum ProviderRouteProvenance: String, Codable, Hashable, Sendable {
    case builtInOpenAIChatCompletions
    case builtInOpenAIResponses
    case builtInOpenAICodexResponses
    case builtInOpenCodeZenChatCompletions
    case builtInLocalModel
    case callerConfigured
}

public enum ProviderCapability: String, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case cancellation
    case imageInput
    case parallelToolCalls
    case promptCaching
    case reasoning
    case responseContinuation
    case streaming
    case strictToolSchema
    case structuredContent
    case temperature
    case tools
    case typedToolArguments
    case usageStreaming

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A deterministic capability set. Encoding a raw Set would make contract fixtures unstable.
public struct ProviderCapabilitySet: Codable, Equatable, Sendable {
    public let values: [ProviderCapability]

    public init(_ values: some Sequence<ProviderCapability>) {
        self.values = Array(Set(values)).sorted()
    }

    public func contains(_ capability: ProviderCapability) -> Bool {
        values.binarySearch(capability)
    }

    public func isSuperset(of requirements: ProviderCapabilitySet) -> Bool {
        requirements.values.allSatisfy(contains)
    }
}

public struct ProviderModelCapabilities: Codable, Equatable, Sendable {
    public let features: ProviderCapabilitySet
    public let contextWindowTokens: UInt64
    public let maximumOutputTokens: UInt64
    public let maximumToolDefinitions: UInt32
    public let maximumToolCallsPerTurn: UInt32

    public init(
        features: ProviderCapabilitySet,
        contextWindowTokens: UInt64,
        maximumOutputTokens: UInt64,
        maximumToolDefinitions: UInt32 = 128,
        maximumToolCallsPerTurn: UInt32 = 128
    ) {
        self.features = features
        self.contextWindowTokens = contextWindowTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumToolDefinitions = maximumToolDefinitions
        self.maximumToolCallsPerTurn = maximumToolCallsPerTurn
    }

    private enum CodingKeys: String, CodingKey {
        case features
        case contextWindowTokens
        case maximumOutputTokens
        case maximumToolDefinitions
        case maximumToolCallsPerTurn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = try container.decode(ProviderCapabilitySet.self, forKey: .features)
        contextWindowTokens = try container.decode(UInt64.self, forKey: .contextWindowTokens)
        maximumOutputTokens = try container.decode(UInt64.self, forKey: .maximumOutputTokens)
        let legacyToolDefault: UInt32 = features.contains(.tools) ? 128 : 0
        maximumToolDefinitions = try container.decodeIfPresent(
            UInt32.self,
            forKey: .maximumToolDefinitions
        ) ?? legacyToolDefault
        maximumToolCallsPerTurn = try container.decodeIfPresent(
            UInt32.self,
            forKey: .maximumToolCallsPerTurn
        ) ?? legacyToolDefault
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(features, forKey: .features)
        try container.encode(contextWindowTokens, forKey: .contextWindowTokens)
        try container.encode(maximumOutputTokens, forKey: .maximumOutputTokens)
        try container.encode(maximumToolDefinitions, forKey: .maximumToolDefinitions)
        try container.encode(maximumToolCallsPerTurn, forKey: .maximumToolCallsPerTurn)
    }

    public func supports(_ requirements: ProviderCapabilityRequirements) -> Bool {
        features.isSuperset(of: requirements.features) &&
            contextWindowTokens >= requirements.minimumContextWindowTokens &&
            maximumOutputTokens >= requirements.minimumOutputTokens &&
            maximumToolDefinitions >= requirements.minimumToolDefinitions &&
            maximumToolCallsPerTurn >= requirements.minimumToolCallsPerTurn
    }

    public static let hermesBaseline = ProviderModelCapabilities(
        features: ProviderCapabilitySet([
            .cancellation,
            .imageInput,
            .parallelToolCalls,
            .promptCaching,
            .reasoning,
            .responseContinuation,
            .streaming,
            .strictToolSchema,
            .structuredContent,
            .temperature,
            .tools,
            .typedToolArguments,
            .usageStreaming,
        ]),
        contextWindowTokens: 128_000,
        maximumOutputTokens: 16_384
    )

    public static let openAIChatBaseline = ProviderModelCapabilities(
        features: ProviderCapabilitySet([
            .cancellation,
            .imageInput,
            .parallelToolCalls,
            .promptCaching,
            .streaming,
            .strictToolSchema,
            .structuredContent,
            .temperature,
            .tools,
            .typedToolArguments,
            .usageStreaming,
        ]),
        contextWindowTokens: 128_000,
        maximumOutputTokens: 16_384
    )

    public static let openAIResponsesBaseline: ProviderModelCapabilities = .hermesBaseline

    /// Conservative common denominator for third-party Chat Completions
    /// endpoints. Hosts may explicitly advertise additional verified features.
    public static let openAICompatibleBaseline = ProviderModelCapabilities(
        features: ProviderCapabilitySet([
            .cancellation,
            .parallelToolCalls,
            .streaming,
            .temperature,
            .tools,
            .typedToolArguments,
            .usageStreaming,
        ]),
        contextWindowTokens: 32_768,
        maximumOutputTokens: 4_096
    )

    /// Conservative capabilities for the currently shipped on-device llama
    /// path. Tool support is deliberately absent until a model/backend pair
    /// proves schema-constrained generation and advertises a stronger route.
    public static let localTextBaseline = ProviderModelCapabilities(
        features: ProviderCapabilitySet([
            .cancellation,
            .streaming,
            .temperature,
            .usageStreaming,
        ]),
        contextWindowTokens: 4_096,
        maximumOutputTokens: 1_024,
        maximumToolDefinitions: 0,
        maximumToolCallsPerTurn: 0
    )
}

public struct ProviderCapabilityRequirements: Codable, Equatable, Sendable {
    public let features: ProviderCapabilitySet
    public let minimumContextWindowTokens: UInt64
    public let minimumOutputTokens: UInt64
    public let minimumToolDefinitions: UInt32
    public let minimumToolCallsPerTurn: UInt32

    public init(
        features: ProviderCapabilitySet,
        minimumContextWindowTokens: UInt64 = 0,
        minimumOutputTokens: UInt64 = 0,
        minimumToolDefinitions: UInt32 = 0,
        minimumToolCallsPerTurn: UInt32 = 0
    ) {
        self.features = features
        self.minimumContextWindowTokens = minimumContextWindowTokens
        self.minimumOutputTokens = minimumOutputTokens
        self.minimumToolDefinitions = minimumToolDefinitions
        self.minimumToolCallsPerTurn = minimumToolCallsPerTurn
    }

    private enum CodingKeys: String, CodingKey {
        case features
        case minimumContextWindowTokens
        case minimumOutputTokens
        case minimumToolDefinitions
        case minimumToolCallsPerTurn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = try container.decode(ProviderCapabilitySet.self, forKey: .features)
        minimumContextWindowTokens = try container.decodeIfPresent(
            UInt64.self,
            forKey: .minimumContextWindowTokens
        ) ?? 0
        minimumOutputTokens = try container.decodeIfPresent(
            UInt64.self,
            forKey: .minimumOutputTokens
        ) ?? 0
        minimumToolDefinitions = try container.decodeIfPresent(
            UInt32.self,
            forKey: .minimumToolDefinitions
        ) ?? 0
        minimumToolCallsPerTurn = try container.decodeIfPresent(
            UInt32.self,
            forKey: .minimumToolCallsPerTurn
        ) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(features, forKey: .features)
        try container.encode(minimumContextWindowTokens, forKey: .minimumContextWindowTokens)
        try container.encode(minimumOutputTokens, forKey: .minimumOutputTokens)
        try container.encode(minimumToolDefinitions, forKey: .minimumToolDefinitions)
        try container.encode(minimumToolCallsPerTurn, forKey: .minimumToolCallsPerTurn)
    }
}

public struct ProviderRoute: Codable, Equatable, Sendable {
    public let providerID: ProviderID
    public let modelID: ProviderModelID
    public let adapterID: ProviderAdapterID
    public let capabilities: ProviderModelCapabilities
    public let deployment: ProviderDeployment
    public let provenance: ProviderRouteProvenance

    public init(
        providerID: ProviderID,
        modelID: ProviderModelID,
        adapterID: ProviderAdapterID,
        capabilities: ProviderModelCapabilities,
        deployment: ProviderDeployment,
        provenance: ProviderRouteProvenance
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.adapterID = adapterID
        self.capabilities = capabilities
        self.deployment = deployment
        self.provenance = provenance
    }
}

public struct ProviderAdapterDescriptor: Codable, Equatable, Sendable {
    public let route: ProviderRoute
    public let dialect: ProviderAdapterDialect
    public let requestPath: String

    public init(route: ProviderRoute, dialect: ProviderAdapterDialect, requestPath: String) {
        self.route = route
        self.dialect = dialect
        self.requestPath = requestPath
    }
}

public enum ProviderMessageRole: String, Codable, Hashable, Sendable {
    case system
    case developer
    case user
    case assistant
    case tool
}

public struct ProviderImageInput: Codable, Equatable, Sendable {
    public let mediaType: String
    /// An opaque content-addressed reference or data URL supplied by the host.
    public let source: String
    public let detail: String?

    public init(mediaType: String, source: String, detail: String? = nil) {
        self.mediaType = mediaType
        self.source = source
        self.detail = detail
    }
}

/// A tool call already present in the canonical transcript (for example when
/// constructing the next request in a multi-round tool loop).
public struct ProviderToolCallInput: Codable, Equatable, Sendable {
    public let callID: String
    public let name: String
    public let arguments: JSONValue

    public init(callID: String, name: String, arguments: JSONValue) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public enum ProviderContentPart: Codable, Equatable, Sendable {
    case text(String)
    case structured(JSONValue)
    case image(ProviderImageInput)
    case toolCall(ProviderToolCallInput)

    private enum CodingKeys: String, CodingKey { case kind, body }
    private enum Kind: String, Codable { case text, structured, image, toolCall }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .body))
        case .structured:
            self = .structured(try container.decode(JSONValue.self, forKey: .body))
        case .image:
            self = .image(try container.decode(ProviderImageInput.self, forKey: .body))
        case .toolCall:
            self = .toolCall(try container.decode(ProviderToolCallInput.self, forKey: .body))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .structured(value):
            try container.encode(Kind.structured, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .image(value):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .toolCall(value):
            try container.encode(Kind.toolCall, forKey: .kind)
            try container.encode(value, forKey: .body)
        }
    }
}

public struct ProviderMessage: Codable, Equatable, Sendable {
    public let role: ProviderMessageRole
    public let content: [ProviderContentPart]
    public let toolCallID: String?
    public let name: String?

    public init(
        role: ProviderMessageRole,
        content: [ProviderContentPart],
        toolCallID: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.name = name
    }
}

public struct ProviderToolDefinition: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: JSONValue
    public let strict: Bool

    public init(name: String, description: String, parameters: JSONValue, strict: Bool = true) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}

public enum ProviderToolChoice: Codable, Equatable, Sendable {
    case auto
    case none
    case required
    case named(String)

    private enum CodingKeys: String, CodingKey { case kind, name }
    private enum Kind: String, Codable { case auto, none, required, named }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .auto: self = .auto
        case .none: self = .none
        case .required: self = .required
        case .named: self = .named(try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode(Kind.auto, forKey: .kind)
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .required:
            try container.encode(Kind.required, forKey: .kind)
        case let .named(name):
            try container.encode(Kind.named, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }
}

public struct ProviderGenerationOptions: Codable, Equatable, Sendable {
    public let maximumOutputTokens: UInt64?
    public let temperature: Double?
    public let parallelToolCalls: Bool?
    public let toolChoice: ProviderToolChoice
    public let reasoningSummary: Bool?
    public let reasoningEffort: ProviderReasoningEffort?
    public let promptCacheKey: String?
    public let previousResponseID: String?
    /// Host-estimated full request context (input plus reserved output). This
    /// is a routing constraint and is not sent to provider APIs.
    public let minimumContextWindowTokens: UInt64?

    public init(
        maximumOutputTokens: UInt64? = nil,
        temperature: Double? = nil,
        parallelToolCalls: Bool? = nil,
        toolChoice: ProviderToolChoice = .auto,
        reasoningSummary: Bool? = nil,
        reasoningEffort: ProviderReasoningEffort? = nil,
        promptCacheKey: String? = nil,
        previousResponseID: String? = nil,
        minimumContextWindowTokens: UInt64? = nil
    ) {
        self.maximumOutputTokens = maximumOutputTokens
        self.temperature = temperature
        self.parallelToolCalls = parallelToolCalls
        self.toolChoice = toolChoice
        self.reasoningSummary = reasoningSummary
        self.reasoningEffort = reasoningEffort
        self.promptCacheKey = promptCacheKey
        self.previousResponseID = previousResponseID
        self.minimumContextWindowTokens = minimumContextWindowTokens
    }
}

public struct CanonicalProviderRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let model: ProviderModelID
    public let messages: [ProviderMessage]
    public let tools: [ProviderToolDefinition]
    public let options: ProviderGenerationOptions
    public let metadata: JSONValue

    public init(
        requestID: String,
        model: ProviderModelID,
        messages: [ProviderMessage],
        tools: [ProviderToolDefinition] = [],
        options: ProviderGenerationOptions = ProviderGenerationOptions(),
        metadata: JSONValue = .object([:])
    ) {
        self.requestID = requestID
        self.model = model
        self.messages = messages
        self.tools = tools
        self.options = options
        self.metadata = metadata
    }

    public var requiredCapabilities: ProviderCapabilitySet {
        var requirements: [ProviderCapability] = [.cancellation, .streaming, .usageStreaming]
        if !tools.isEmpty || messages.contains(where: { message in
            message.content.contains { if case .toolCall = $0 { true } else { false } }
        }) {
            requirements.append(contentsOf: [.tools, .typedToolArguments])
        }
        if tools.contains(where: \.strict) {
            requirements.append(.strictToolSchema)
        }
        if options.parallelToolCalls == true {
            requirements.append(.parallelToolCalls)
        }
        if options.temperature != nil {
            requirements.append(.temperature)
        }
        if options.reasoningSummary == true || options.reasoningEffort != nil {
            requirements.append(.reasoning)
        }
        if options.promptCacheKey != nil {
            requirements.append(.promptCaching)
        }
        if options.previousResponseID != nil {
            requirements.append(.responseContinuation)
        }
        if messages.contains(where: { message in
            message.content.contains { if case .structured = $0 { true } else { false } }
        }) {
            requirements.append(.structuredContent)
        }
        if messages.contains(where: { message in
            message.content.contains { if case .image = $0 { true } else { false } }
        }) {
            requirements.append(.imageInput)
        }
        return ProviderCapabilitySet(requirements)
    }

    public var capabilityRequirements: ProviderCapabilityRequirements {
        let minimumToolCalls: UInt32
        if requiredCapabilities.contains(.tools) {
            // Tool definitions are a catalog, not concurrent emissions. A
            // non-parallel turn needs capacity for one selected call; explicit
            // parallel execution needs at least two. Actual emitted calls are
            // enforced by the stream session.
            minimumToolCalls = options.parallelToolCalls == true ? 2 : 1
        } else {
            minimumToolCalls = 0
        }
        return ProviderCapabilityRequirements(
            features: requiredCapabilities,
            minimumContextWindowTokens: options.minimumContextWindowTokens ?? 0,
            minimumOutputTokens: options.maximumOutputTokens ?? 0,
            minimumToolDefinitions: UInt32(clamping: tools.count),
            minimumToolCallsPerTurn: minimumToolCalls
        )
    }
}

public enum ProviderHTTPMethod: String, Codable, Hashable, Sendable {
    case post = "POST"
}

/// A credential-free request envelope. The host transport adds authorization and base URL.
public struct ProviderEncodedRequest: Codable, Equatable, Sendable {
    public let method: ProviderHTTPMethod
    public let relativePath: String
    public let body: JSONValue

    public init(method: ProviderHTTPMethod = .post, relativePath: String, body: JSONValue) {
        self.method = method
        self.relativePath = relativePath
        self.body = body
    }
}

public enum ProviderWireFrame: Equatable, Sendable {
    case json(JSONValue)
    case done
    case cancelled(reason: String?)
}

public struct ProviderResponseStart: Codable, Equatable, Sendable {
    public let responseID: String
    public let model: ProviderModelID

    public init(responseID: String, model: ProviderModelID) {
        self.responseID = responseID
        self.model = model
    }
}

public struct ProviderTextDelta: Codable, Equatable, Sendable {
    public let outputIndex: Int
    public let text: String

    public init(outputIndex: Int, text: String) {
        self.outputIndex = outputIndex
        self.text = text
    }
}

public struct ProviderToolCallStart: Codable, Equatable, Sendable {
    public let outputIndex: Int
    public let itemID: String?
    public let callID: String
    public let name: String

    public init(outputIndex: Int, itemID: String? = nil, callID: String, name: String) {
        self.outputIndex = outputIndex
        self.itemID = itemID
        self.callID = callID
        self.name = name
    }
}

public struct ProviderToolCallArgumentsDelta: Codable, Equatable, Sendable {
    public let outputIndex: Int
    public let callID: String
    public let fragment: String

    public init(outputIndex: Int, callID: String, fragment: String) {
        self.outputIndex = outputIndex
        self.callID = callID
        self.fragment = fragment
    }
}

public struct ProviderToolCallCompletion: Codable, Equatable, Sendable {
    public let outputIndex: Int
    public let itemID: String?
    public let callID: String
    public let name: String
    /// Fully assembled and typed JSON. Providers never collapse scalar kinds into strings.
    public let arguments: JSONValue

    public init(
        outputIndex: Int,
        itemID: String? = nil,
        callID: String,
        name: String,
        arguments: JSONValue
    ) {
        self.outputIndex = outputIndex
        self.itemID = itemID
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }
}

public struct ProviderUsage: Codable, Equatable, Sendable {
    public let inputTokens: UInt64
    public let cachedInputTokens: UInt64
    public let outputTokens: UInt64
    public let reasoningTokens: UInt64

    public init(
        inputTokens: UInt64,
        cachedInputTokens: UInt64 = 0,
        outputTokens: UInt64,
        reasoningTokens: UInt64 = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    public var modelUsage: ModelUsage {
        ModelUsage(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens
        )
    }

    public static let zero = ProviderUsage(inputTokens: 0, outputTokens: 0)

    public func adding(_ other: ProviderUsage) -> ProviderUsage {
        ProviderUsage(
            inputTokens: Self.saturatingAdd(inputTokens, other.inputTokens),
            cachedInputTokens: Self.saturatingAdd(cachedInputTokens, other.cachedInputTokens),
            outputTokens: Self.saturatingAdd(outputTokens, other.outputTokens),
            reasoningTokens: Self.saturatingAdd(reasoningTokens, other.reasoningTokens)
        )
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}

public struct ProviderResponseCompletion: Codable, Equatable, Sendable {
    public let responseID: String
    public let finishReason: ModelFinishReason

    public init(responseID: String, finishReason: ModelFinishReason) {
        self.responseID = responseID
        self.finishReason = finishReason
    }
}

public struct ProviderCancellation: Codable, Equatable, Sendable {
    public let responseID: String?
    public let reason: String?

    public init(responseID: String?, reason: String?) {
        self.responseID = responseID
        self.reason = reason
    }
}

/// Provider-neutral stream semantics consumed by the reducer/event writer.
public enum ProviderStreamEvent: Codable, Equatable, Sendable {
    case responseStarted(ProviderResponseStart)
    case textDelta(ProviderTextDelta)
    case reasoningDelta(ProviderTextDelta)
    case toolCallStarted(ProviderToolCallStart)
    case toolCallArgumentsDelta(ProviderToolCallArgumentsDelta)
    case toolCallCompleted(ProviderToolCallCompletion)
    case usage(ProviderUsage)
    case responseCompleted(ProviderResponseCompletion)
    case cancelled(ProviderCancellation)

    private enum CodingKeys: String, CodingKey { case kind, body }
    private enum Kind: String, Codable {
        case responseStarted
        case textDelta
        case reasoningDelta
        case toolCallStarted
        case toolCallArgumentsDelta
        case toolCallCompleted
        case usage
        case responseCompleted
        case cancelled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .responseStarted:
            self = .responseStarted(try container.decode(ProviderResponseStart.self, forKey: .body))
        case .textDelta:
            self = .textDelta(try container.decode(ProviderTextDelta.self, forKey: .body))
        case .reasoningDelta:
            self = .reasoningDelta(try container.decode(ProviderTextDelta.self, forKey: .body))
        case .toolCallStarted:
            self = .toolCallStarted(try container.decode(ProviderToolCallStart.self, forKey: .body))
        case .toolCallArgumentsDelta:
            self = .toolCallArgumentsDelta(
                try container.decode(ProviderToolCallArgumentsDelta.self, forKey: .body)
            )
        case .toolCallCompleted:
            self = .toolCallCompleted(try container.decode(ProviderToolCallCompletion.self, forKey: .body))
        case .usage:
            self = .usage(try container.decode(ProviderUsage.self, forKey: .body))
        case .responseCompleted:
            self = .responseCompleted(
                try container.decode(ProviderResponseCompletion.self, forKey: .body)
            )
        case .cancelled:
            self = .cancelled(try container.decode(ProviderCancellation.self, forKey: .body))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .responseStarted(value):
            try container.encode(Kind.responseStarted, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .textDelta(value):
            try container.encode(Kind.textDelta, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .reasoningDelta(value):
            try container.encode(Kind.reasoningDelta, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .toolCallStarted(value):
            try container.encode(Kind.toolCallStarted, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .toolCallArgumentsDelta(value):
            try container.encode(Kind.toolCallArgumentsDelta, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .toolCallCompleted(value):
            try container.encode(Kind.toolCallCompleted, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .usage(value):
            try container.encode(Kind.usage, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .responseCompleted(value):
            try container.encode(Kind.responseCompleted, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .cancelled(value):
            try container.encode(Kind.cancelled, forKey: .kind)
            try container.encode(value, forKey: .body)
        }
    }
}

/// Every canonical event remains attempt-scoped until a gateway atomically
/// commits that attempt. Consumers may render provisional events, but must key
/// their buffers by `scope` and discard the entire scope on failure.
public struct ProviderAttemptEvent: Codable, Equatable, Sendable {
    public let scope: ProviderAttemptScope
    public let sequence: UInt64
    public let event: ProviderStreamEvent

    public init(scope: ProviderAttemptScope, sequence: UInt64, event: ProviderStreamEvent) {
        self.scope = scope
        self.sequence = sequence
        self.event = event
    }
}

private extension Array where Element: Comparable {
    func binarySearch(_ target: Element) -> Bool {
        var lowerBound = startIndex
        var upperBound = endIndex
        while lowerBound < upperBound {
            let distance = self.distance(from: lowerBound, to: upperBound)
            let middle = index(lowerBound, offsetBy: distance / 2)
            if self[middle] == target { return true }
            if self[middle] < target {
                lowerBound = index(after: middle)
            } else {
                upperBound = middle
            }
        }
        return false
    }
}
