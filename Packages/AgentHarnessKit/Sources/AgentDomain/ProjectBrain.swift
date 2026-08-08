import Foundation

public enum ProjectBrainFactIDTag: AgentIdentifierTag {}
public typealias ProjectBrainFactID = AgentIdentifier<ProjectBrainFactIDTag>

public enum ProjectBrainFactKind: String, Codable, CaseIterable, Sendable {
    case intent
    case designDNA
    case feature
    case architecture
    case sourceStructure
    case runtimeCapability
    case testEvidence
    case acceptedDecision
    case unresolvedBlocker
    case performanceEvidence
    case modelRunHistory
    case checkpoint
}

public enum ProjectBrainScopeKind: String, Codable, CaseIterable, Sendable {
    case project
    case mission
    case file
    case symbol
    case runtime
}

public struct ProjectBrainScope: Codable, Equatable, Sendable {
    public let kind: ProjectBrainScopeKind
    public let reference: String?

    public init(kind: ProjectBrainScopeKind, reference: String? = nil) {
        self.kind = kind
        self.reference = reference
    }

    public var validationError: ProjectBrainValidationError? {
        switch kind {
        case .project:
            if let reference, !reference.hasProjectBrainContent {
                return .blankScopeReference
            }
            return nil
        case .mission, .file, .symbol, .runtime:
            guard reference?.hasProjectBrainContent == true else {
                return .missingScopeReference
            }
            return nil
        }
    }
}

public enum ProjectBrainProvenanceKind: String, Codable, CaseIterable, Sendable {
    case userDecision
    case sourceFile
    case runtimeEvidence
    case testEvidence
    case checkpoint
    case acceptedSummary
    case modelObservation

    /// Summaries and model observations are useful retrieval accelerators, but
    /// cannot be the only authority for a fact promoted to project truth.
    public var isSourceAuthority: Bool {
        switch self {
        case .acceptedSummary, .modelObservation:
            false
        case .userDecision, .sourceFile, .runtimeEvidence, .testEvidence, .checkpoint:
            true
        }
    }
}

public struct ProjectBrainProvenance: Codable, Equatable, Sendable {
    public let kind: ProjectBrainProvenanceKind
    public let reference: String
    public let capturedAt: AgentInstant
    public let contentDigest: String?

    public init(
        kind: ProjectBrainProvenanceKind,
        reference: String,
        capturedAt: AgentInstant,
        contentDigest: String? = nil
    ) {
        self.kind = kind
        self.reference = reference
        self.capturedAt = capturedAt
        self.contentDigest = contentDigest
    }

    public var validationError: ProjectBrainValidationError? {
        guard reference.hasProjectBrainContent else { return .blankProvenanceReference }
        if let contentDigest, !contentDigest.hasProjectBrainContent {
            return .blankContentDigest
        }
        return nil
    }
}

public enum ProjectBrainFreshness: String, Codable, CaseIterable, Sendable {
    case current
    case stale
    case unknown
}

/// A single durable, source-backed item in Project Brain.
///
/// Facts preserve where their authority came from and whether that source has
/// been reverified. Derived summaries can accompany source evidence but cannot
/// silently become the sole source of project truth.
public struct ProjectBrainFact: Codable, Equatable, Sendable {
    public let factID: ProjectBrainFactID
    public let projectID: ProjectID
    public let missionID: MissionID?
    public let kind: ProjectBrainFactKind
    public let statement: String
    public let scope: ProjectBrainScope
    public let provenance: [ProjectBrainProvenance]
    public let lastVerifiedAt: AgentInstant
    public let freshness: ProjectBrainFreshness
    public let staleReason: String?

    public init(
        factID: ProjectBrainFactID,
        projectID: ProjectID,
        missionID: MissionID? = nil,
        kind: ProjectBrainFactKind,
        statement: String,
        scope: ProjectBrainScope,
        provenance: [ProjectBrainProvenance],
        lastVerifiedAt: AgentInstant,
        freshness: ProjectBrainFreshness = .current,
        staleReason: String? = nil
    ) {
        self.factID = factID
        self.projectID = projectID
        self.missionID = missionID
        self.kind = kind
        self.statement = statement
        self.scope = scope
        self.provenance = provenance
        self.lastVerifiedAt = lastVerifiedAt
        self.freshness = freshness
        self.staleReason = staleReason
    }

    public var hasSourceAuthority: Bool {
        provenance.contains { $0.kind.isSourceAuthority }
    }

    public var validationError: ProjectBrainValidationError? {
        guard statement.hasProjectBrainContent else { return .blankStatement }
        if let scopeError = scope.validationError { return scopeError }
        guard !provenance.isEmpty else { return .missingProvenance }
        if let provenanceError = provenance.lazy.compactMap(\.validationError).first {
            return provenanceError
        }
        guard hasSourceAuthority else { return .derivedOnlyProvenance }

        switch freshness {
        case .current, .unknown:
            if let staleReason, staleReason.hasProjectBrainContent {
                return .unexpectedStaleReason
            }
            if staleReason != nil {
                return .blankStaleReason
            }
        case .stale:
            guard staleReason?.hasProjectBrainContent == true else {
                return .missingStaleReason
            }
        }
        return nil
    }

    public func markingStale(reason: String) -> Self {
        Self(
            factID: factID,
            projectID: projectID,
            missionID: missionID,
            kind: kind,
            statement: statement,
            scope: scope,
            provenance: provenance,
            lastVerifiedAt: lastVerifiedAt,
            freshness: .stale,
            staleReason: reason
        )
    }

    public func refreshed(
        statement: String? = nil,
        provenance: [ProjectBrainProvenance],
        verifiedAt: AgentInstant
    ) -> Self {
        Self(
            factID: factID,
            projectID: projectID,
            missionID: missionID,
            kind: kind,
            statement: statement ?? self.statement,
            scope: scope,
            provenance: provenance,
            lastVerifiedAt: verifiedAt,
            freshness: .current
        )
    }
}

public enum ProjectBrainValidationError: String, Error, Codable, Equatable, Sendable {
    case blankStatement
    case blankScopeReference
    case missingScopeReference
    case missingProvenance
    case blankProvenanceReference
    case blankContentDigest
    case derivedOnlyProvenance
    case unexpectedStaleReason
    case blankStaleReason
    case missingStaleReason
}

private extension String {
    var hasProjectBrainContent: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
