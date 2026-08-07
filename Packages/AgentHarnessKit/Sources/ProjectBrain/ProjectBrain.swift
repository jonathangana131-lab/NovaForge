import AgentDomain
import Foundation

public enum ProjectBrainFactIDTag: AgentIdentifierTag {}
public typealias ProjectBrainFactID = AgentIdentifier<ProjectBrainFactIDTag>

public struct ProjectBrainRevision: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public static let initial = ProjectBrainRevision(rawValue: 0)
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

public enum ProjectBrainFactSource: Codable, Hashable, Sendable {
    case userDecision(decisionID: String)
    case sourceFile(path: String, digest: String)
    case runtimeEvidence(receiptID: String)
    case testEvidence(receiptID: String)
    case acceptedSummary(checkpointID: String)
}

public enum ProjectBrainScope: Codable, Hashable, Sendable {
    case project
    case feature(String)
    case file(String)
    case symbol(file: String, name: String)
}

public enum ProjectBrainFactStatus: String, Codable, Hashable, Sendable {
    case current
    case stale
}

public struct ProjectBrainFact: Codable, Hashable, Sendable {
    public let id: ProjectBrainFactID
    public let key: String
    public let value: String
    public let scope: ProjectBrainScope
    public let source: ProjectBrainFactSource
    public let verifiedAt: AgentInstant
    public let status: ProjectBrainFactStatus
    public let invalidatedAt: AgentInstant?

    public init(
        id: ProjectBrainFactID = ProjectBrainFactID(),
        key: String,
        value: String,
        scope: ProjectBrainScope,
        source: ProjectBrainFactSource,
        verifiedAt: AgentInstant,
        status: ProjectBrainFactStatus = .current,
        invalidatedAt: AgentInstant? = nil
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.scope = scope
        self.source = source
        self.verifiedAt = verifiedAt
        self.status = status
        self.invalidatedAt = invalidatedAt
    }

    public func markingStale(at instant: AgentInstant) -> Self {
        Self(
            id: id,
            key: key,
            value: value,
            scope: scope,
            source: source,
            verifiedAt: verifiedAt,
            status: .stale,
            invalidatedAt: instant
        )
    }
}

public struct ProjectBrainSnapshot: Codable, Hashable, Sendable {
    public let projectID: ProjectID
    public let revision: ProjectBrainRevision
    public let facts: [ProjectBrainFact]

    public init(
        projectID: ProjectID,
        revision: ProjectBrainRevision = .initial,
        facts: [ProjectBrainFact] = []
    ) {
        self.projectID = projectID
        self.revision = revision
        self.facts = facts.sorted { $0.id.description < $1.id.description }
    }

    public var currentFacts: [ProjectBrainFact] {
        facts.filter { $0.status == .current }
    }
}

public enum ProjectBrainMutationError: Error, Equatable, Sendable {
    case staleRevision(expected: ProjectBrainRevision, actual: ProjectBrainRevision)
    case revisionOverflow
}

public enum ProjectBrainReducer {
    public static func upsert(
        _ fact: ProjectBrainFact,
        expectedRevision: ProjectBrainRevision,
        into snapshot: ProjectBrainSnapshot
    ) throws -> ProjectBrainSnapshot {
        try requireRevision(expectedRevision, in: snapshot)
        let nextRevision = try nextRevision(after: snapshot.revision)
        var facts = snapshot.facts.filter { $0.id != fact.id }
        facts.append(fact)
        return ProjectBrainSnapshot(projectID: snapshot.projectID, revision: nextRevision, facts: facts)
    }

    public static func invalidate(
        source: ProjectBrainFactSource,
        at instant: AgentInstant,
        expectedRevision: ProjectBrainRevision,
        in snapshot: ProjectBrainSnapshot
    ) throws -> ProjectBrainSnapshot {
        try requireRevision(expectedRevision, in: snapshot)
        let nextRevision = try nextRevision(after: snapshot.revision)
        let facts = snapshot.facts.map { fact in
            guard fact.source == source, fact.status == .current else { return fact }
            return fact.markingStale(at: instant)
        }
        return ProjectBrainSnapshot(projectID: snapshot.projectID, revision: nextRevision, facts: facts)
    }

    private static func requireRevision(
        _ expected: ProjectBrainRevision,
        in snapshot: ProjectBrainSnapshot
    ) throws {
        guard expected == snapshot.revision else {
            throw ProjectBrainMutationError.staleRevision(expected: expected, actual: snapshot.revision)
        }
    }

    private static func nextRevision(after revision: ProjectBrainRevision) throws -> ProjectBrainRevision {
        guard let next = revision.successor else {
            throw ProjectBrainMutationError.revisionOverflow
        }
        return next
    }
}
