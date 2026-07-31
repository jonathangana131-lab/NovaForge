import Foundation

public struct AgentRunLineage: Codable, Equatable, Sendable {
    public let runID: RunID
    public let rootRunID: RunID
    public let parentRunID: RunID?
    public let retryOfRunID: RunID?
    public let generation: UInt32

    public init(
        runID: RunID,
        rootRunID: RunID,
        parentRunID: RunID? = nil,
        retryOfRunID: RunID? = nil,
        generation: UInt32
    ) {
        self.runID = runID
        self.rootRunID = rootRunID
        self.parentRunID = parentRunID
        self.retryOfRunID = retryOfRunID
        self.generation = generation
    }

    public static func root(_ runID: RunID) -> Self {
        Self(runID: runID, rootRunID: runID, generation: 0)
    }

    public static func child(
        _ runID: RunID,
        of parent: Self
    ) -> Self {
        Self(
            runID: runID,
            rootRunID: parent.rootRunID,
            parentRunID: parent.runID,
            generation: parent.generation + 1
        )
    }

    public static func retry(
        _ runID: RunID,
        of previous: Self
    ) -> Self {
        Self(
            runID: runID,
            rootRunID: previous.rootRunID,
            parentRunID: previous.parentRunID,
            retryOfRunID: previous.runID,
            generation: previous.generation + 1
        )
    }

    public var validationError: AgentRunLineageError? {
        if generation == 0 {
            guard runID == rootRunID,
                  parentRunID == nil,
                  retryOfRunID == nil
            else { return .invalidRoot }
            return nil
        }

        guard runID != rootRunID else { return .descendantMatchesRoot }
        guard parentRunID != nil || retryOfRunID != nil else {
            return .missingAncestor
        }
        guard retryOfRunID != runID, parentRunID != runID else {
            return .selfReference
        }
        return nil
    }
}

public enum AgentRunLineageError: String, Error, Codable, Equatable, Sendable {
    case invalidRoot
    case descendantMatchesRoot
    case missingAncestor
    case selfReference
}

public struct CancellationLineage: Codable, Equatable, Sendable {
    public let scopeID: CancellationScopeID
    public let parentScopeID: CancellationScopeID?

    public init(scopeID: CancellationScopeID, parentScopeID: CancellationScopeID? = nil) {
        self.scopeID = scopeID
        self.parentScopeID = parentScopeID
    }
}

/// Sorted unique feature names make encoded run routing deterministic.
public struct AgentFeatureSet: Codable, Equatable, Sendable {
    public let values: [String]

    private enum CodingKeys: String, CodingKey { case values }

    public init<S: Sequence>(_ values: S) where S.Element == String {
        self.values = Array(Set(values)).sorted()
    }

    public func contains(_ feature: String) -> Bool {
        values.binarySearch(feature)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode([String].self, forKey: .values))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
    }
}

public struct AgentRunContext: Codable, Equatable, Sendable {
    public let schemaVersion: AgentSchemaVersion
    public let lineage: AgentRunLineage
    public let conversationID: ConversationID
    public let projectID: ProjectID?
    public let workspaceID: WorkspaceID
    public let executionNodeID: ExecutionNodeID
    public let engineVersion: EngineVersion
    public let acceptedAt: AgentInstant
    public let features: AgentFeatureSet
    public let cancellation: CancellationLineage
    public let initialBudget: AgentBudget

    public init(
        schemaVersion: AgentSchemaVersion = .current,
        lineage: AgentRunLineage,
        conversationID: ConversationID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        executionNodeID: ExecutionNodeID,
        engineVersion: EngineVersion,
        acceptedAt: AgentInstant,
        features: AgentFeatureSet,
        cancellation: CancellationLineage,
        initialBudget: AgentBudget
    ) {
        self.schemaVersion = schemaVersion
        self.lineage = lineage
        self.conversationID = conversationID
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.executionNodeID = executionNodeID
        self.engineVersion = engineVersion
        self.acceptedAt = acceptedAt
        self.features = features
        self.cancellation = cancellation
        self.initialBudget = initialBudget
    }
}

private extension Array where Element == String {
    func binarySearch(_ value: String) -> Bool {
        var lowerBound = startIndex
        var upperBound = endIndex
        while lowerBound < upperBound {
            let distance = self.distance(from: lowerBound, to: upperBound)
            let middle = index(lowerBound, offsetBy: distance / 2)
            if self[middle] == value { return true }
            if self[middle] < value {
                lowerBound = index(after: middle)
            } else {
                upperBound = middle
            }
        }
        return false
    }
}
