import Foundation

public enum ModelRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
}

public struct ModelImageReference: Codable, Equatable, Sendable {
    public let mediaType: String
    public let contentDigest: String
    public let detail: String?

    public init(mediaType: String, contentDigest: String, detail: String? = nil) {
        self.mediaType = mediaType
        self.contentDigest = contentDigest
        self.detail = detail
    }
}

public enum ModelContentPart: Codable, Equatable, Sendable {
    case text(String)
    case structured(JSONValue)
    case image(ModelImageReference)
    case artifact(ArtifactReference)

    private enum CodingKeys: String, CodingKey { case kind, body }
    private enum Kind: String, Codable { case text, structured, image, artifact }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .body))
        case .structured:
            self = .structured(try container.decode(JSONValue.self, forKey: .body))
        case .image:
            self = .image(try container.decode(ModelImageReference.self, forKey: .body))
        case .artifact:
            self = .artifact(try container.decode(ArtifactReference.self, forKey: .body))
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
        case let .artifact(value):
            try container.encode(Kind.artifact, forKey: .kind)
            try container.encode(value, forKey: .body)
        }
    }
}

public struct ModelMessage: Codable, Equatable, Sendable {
    public let role: ModelRole
    public let content: [ModelContentPart]

    public init(role: ModelRole, content: [ModelContentPart]) {
        self.role = role
        self.content = content
    }
}

public struct ReasoningSummary: Codable, Equatable, Sendable {
    public let text: String
    public let providerReference: String?

    public init(text: String, providerReference: String? = nil) {
        self.text = text
        self.providerReference = providerReference
    }
}

public struct ContextCheckpointReference: Codable, Equatable, Sendable {
    public let checkpointID: ContextCheckpointID
    public let schemaVersion: AgentSchemaVersion
    public let summary: String
    public let sourceItemIDs: [ModelItemID]
    public let sourceDigest: String

    public init(
        checkpointID: ContextCheckpointID,
        schemaVersion: AgentSchemaVersion,
        summary: String,
        sourceItemIDs: [ModelItemID],
        sourceDigest: String
    ) {
        self.checkpointID = checkpointID
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.sourceItemIDs = sourceItemIDs
        self.sourceDigest = sourceDigest
    }
}

public enum ModelItemPayload: Codable, Equatable, Sendable {
    case message(ModelMessage)
    case reasoningSummary(ReasoningSummary)
    case toolInvocation(ToolInvocation)
    case toolResult(ToolResult)
    case contextCheckpoint(ContextCheckpointReference)

    private enum CodingKeys: String, CodingKey { case kind, body }
    private enum Kind: String, Codable {
        case message
        case reasoningSummary
        case toolInvocation
        case toolResult
        case contextCheckpoint
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .message:
            self = .message(try container.decode(ModelMessage.self, forKey: .body))
        case .reasoningSummary:
            self = .reasoningSummary(try container.decode(ReasoningSummary.self, forKey: .body))
        case .toolInvocation:
            self = .toolInvocation(try container.decode(ToolInvocation.self, forKey: .body))
        case .toolResult:
            self = .toolResult(try container.decode(ToolResult.self, forKey: .body))
        case .contextCheckpoint:
            self = .contextCheckpoint(try container.decode(ContextCheckpointReference.self, forKey: .body))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .message(value):
            try container.encode(Kind.message, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .reasoningSummary(value):
            try container.encode(Kind.reasoningSummary, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .toolInvocation(value):
            try container.encode(Kind.toolInvocation, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .toolResult(value):
            try container.encode(Kind.toolResult, forKey: .kind)
            try container.encode(value, forKey: .body)
        case let .contextCheckpoint(value):
            try container.encode(Kind.contextCheckpoint, forKey: .kind)
            try container.encode(value, forKey: .body)
        }
    }
}

public struct ModelItem: Codable, Equatable, Sendable {
    public let id: ModelItemID
    public let createdAt: AgentInstant
    public let payload: ModelItemPayload

    public init(id: ModelItemID, createdAt: AgentInstant, payload: ModelItemPayload) {
        self.id = id
        self.createdAt = createdAt
        self.payload = payload
    }
}

public struct ModelUsage: Codable, Equatable, Sendable {
    public let inputTokens: UInt64
    public let cachedInputTokens: UInt64
    public let outputTokens: UInt64
    public let costMicrounits: UInt64

    public init(
        inputTokens: UInt64,
        cachedInputTokens: UInt64 = 0,
        outputTokens: UInt64,
        costMicrounits: UInt64 = 0
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.costMicrounits = costMicrounits
    }

    public var budgetUsage: AgentBudgetUsage {
        AgentBudgetUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            costMicrounits: costMicrounits
        )
    }
}

public struct ModelRoute: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String
    public let adapter: String

    public init(provider: String, model: String, adapter: String) {
        self.provider = provider
        self.model = model
        self.adapter = adapter
    }
}

public enum ModelFinishReason: String, Codable, Hashable, Sendable {
    case completed
    case toolCalls
    case length
    case contentFilter
    case cancelled
    case unknown
}
