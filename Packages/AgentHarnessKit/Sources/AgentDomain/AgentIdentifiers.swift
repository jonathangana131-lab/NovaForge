import Foundation

/// Marker protocol for strongly typed UUID identifiers.
public protocol AgentIdentifierTag: Sendable {}

/// A UUID whose tag prevents identifiers from unrelated domains being mixed.
public struct AgentIdentifier<Tag: AgentIdentifierTag>:
    RawRepresentable,
    Codable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum RunIDTag: AgentIdentifierTag {}
public enum EventIDTag: AgentIdentifierTag {}
public enum CommandIDTag: AgentIdentifierTag {}
public enum ExecutionNodeIDTag: AgentIdentifierTag {}
public enum ConversationIDTag: AgentIdentifierTag {}
public enum ProjectIDTag: AgentIdentifierTag {}
public enum WorkspaceIDTag: AgentIdentifierTag {}
public enum CorrelationIDTag: AgentIdentifierTag {}
public enum CausationIDTag: AgentIdentifierTag {}
public enum AttemptIDTag: AgentIdentifierTag {}
public enum ToolCallIDTag: AgentIdentifierTag {}
public enum ApprovalRequestIDTag: AgentIdentifierTag {}
public enum ModelItemIDTag: AgentIdentifierTag {}
public enum ArtifactIDTag: AgentIdentifierTag {}
public enum ContextCheckpointIDTag: AgentIdentifierTag {}
public enum CancellationScopeIDTag: AgentIdentifierTag {}

public typealias RunID = AgentIdentifier<RunIDTag>
public typealias EventID = AgentIdentifier<EventIDTag>
public typealias CommandID = AgentIdentifier<CommandIDTag>
public typealias ExecutionNodeID = AgentIdentifier<ExecutionNodeIDTag>
public typealias ConversationID = AgentIdentifier<ConversationIDTag>
public typealias ProjectID = AgentIdentifier<ProjectIDTag>
public typealias WorkspaceID = AgentIdentifier<WorkspaceIDTag>
public typealias CorrelationID = AgentIdentifier<CorrelationIDTag>
public typealias CausationID = AgentIdentifier<CausationIDTag>
public typealias AttemptID = AgentIdentifier<AttemptIDTag>
public typealias ToolCallID = AgentIdentifier<ToolCallIDTag>
public typealias ApprovalRequestID = AgentIdentifier<ApprovalRequestIDTag>
public typealias ModelItemID = AgentIdentifier<ModelItemIDTag>
public typealias ArtifactID = AgentIdentifier<ArtifactIDTag>
public typealias ContextCheckpointID = AgentIdentifier<ContextCheckpointIDTag>
public typealias CancellationScopeID = AgentIdentifier<CancellationScopeIDTag>

public struct AgentSchemaVersion: Codable, Hashable, Sendable, Comparable {
    public static let v1 = AgentSchemaVersion(major: 1, minor: 0)
    public static let v1_1 = AgentSchemaVersion(major: 1, minor: 1)
    public static let current = v1_1

    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public func canBeDecoded(by supported: Self = .current) -> Bool {
        major == supported.major && minor <= supported.minor
    }
}

public struct EngineVersion: RawRepresentable, Codable, Hashable, Sendable {
    public static let agentHarnessV1 = EngineVersion(rawValue: "agent-harness-v1")
    public static let agentHarnessV2 = EngineVersion(rawValue: "agent-harness-v2")

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct EventSequence: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public static let first = EventSequence(rawValue: 1)

    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var successor: Self? {
        guard rawValue < UInt64.max else { return nil }
        return Self(rawValue: rawValue + 1)
    }
}

/// Integer milliseconds from the Unix epoch, used instead of encoder-specific Date formats.
public struct AgentInstant: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(_ date: Date) {
        self.init(rawValue: Int64((date.timeIntervalSince1970 * 1_000).rounded()))
    }

    public var date: Date {
        Date(timeIntervalSince1970: Double(rawValue) / 1_000)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
