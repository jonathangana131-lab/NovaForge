import Foundation

public enum ProjectBrainContextFreshnessPolicy: String, Codable, CaseIterable, Sendable {
    /// Only facts whose source has been reverified and remains current.
    case currentOnly
    /// Current facts plus facts whose freshness is not yet known. Stale facts remain excluded.
    case currentAndUnknown
    /// Explicit expert/debug policy that allows stale facts to enter the slice with their
    /// `freshness` and `staleReason` preserved. Stale facts are always ranked last.
    case includeStale
}

public enum ProjectBrainContextRequestValidationError: String, Error, Codable, Equatable, Sendable {
    case emptyFactBudget
    case emptyCharacterBudget
    case duplicatePreferredKind
    case duplicateScope
    case invalidScope
}

/// Bounded, deterministic retrieval request for one Project Brain neighborhood.
///
/// This is deliberately not a semantic-search prompt. Callers resolve the structural
/// neighborhood they need (project / mission / file / symbol / runtime), then this request
/// selects source-backed durable facts without turning a transcript or generated summary into
/// canonical project state.
public struct ProjectBrainContextRequest: Equatable, Sendable {
    public let projectID: ProjectID
    public let missionID: MissionID?
    public let scopes: [ProjectBrainScope]
    public let preferredKinds: [ProjectBrainFactKind]
    public let freshnessPolicy: ProjectBrainContextFreshnessPolicy
    public let includeProjectScopeFallback: Bool
    public let maxFacts: Int
    public let maxCharacters: Int

    public init(
        projectID: ProjectID,
        missionID: MissionID? = nil,
        scopes: [ProjectBrainScope] = [],
        preferredKinds: [ProjectBrainFactKind] = [],
        freshnessPolicy: ProjectBrainContextFreshnessPolicy = .currentOnly,
        includeProjectScopeFallback: Bool = true,
        maxFacts: Int = 24,
        maxCharacters: Int = 16_000
    ) {
        self.projectID = projectID
        self.missionID = missionID
        self.scopes = scopes
        self.preferredKinds = preferredKinds
        self.freshnessPolicy = freshnessPolicy
        self.includeProjectScopeFallback = includeProjectScopeFallback
        self.maxFacts = maxFacts
        self.maxCharacters = maxCharacters
    }

    public var validationError: ProjectBrainContextRequestValidationError? {
        guard maxFacts > 0 else { return .emptyFactBudget }
        guard maxCharacters > 0 else { return .emptyCharacterBudget }
        guard Set(preferredKinds).count == preferredKinds.count else {
            return .duplicatePreferredKind
        }
        guard Set(scopes.map(ProjectBrainContextScopeKey.init)).count == scopes.count else {
            return .duplicateScope
        }
        guard scopes.allSatisfy({ $0.validationError == nil }) else {
            return .invalidScope
        }
        return nil
    }
}

public enum ProjectBrainContextSelectionError: Error, Equatable, Sendable {
    case invalidRequest(ProjectBrainContextRequestValidationError)
    case invalidFact(ProjectBrainFactID, ProjectBrainValidationError)
}

/// Exact source-backed facts selected for one bounded model/tool context.
///
/// No fact is rewritten or summarized here. `budgetOmittedFactIDs` makes compaction explicit so
/// callers can request a larger slice or retrieve a particular omitted fact by ID when needed.
public struct ProjectBrainContextSlice: Equatable, Sendable {
    public let projectID: ProjectID
    public let missionID: MissionID?
    public let facts: [ProjectBrainFact]
    public let budgetOmittedFactIDs: [ProjectBrainFactID]
    public let matchedFactCount: Int
    public let estimatedCharacterCount: Int
    public let maximumCharacterCount: Int

    public init(
        projectID: ProjectID,
        missionID: MissionID?,
        facts: [ProjectBrainFact],
        budgetOmittedFactIDs: [ProjectBrainFactID],
        matchedFactCount: Int,
        estimatedCharacterCount: Int,
        maximumCharacterCount: Int
    ) {
        self.projectID = projectID
        self.missionID = missionID
        self.facts = facts
        self.budgetOmittedFactIDs = budgetOmittedFactIDs
        self.matchedFactCount = matchedFactCount
        self.estimatedCharacterCount = estimatedCharacterCount
        self.maximumCharacterCount = maximumCharacterCount
    }

    public var isCompacted: Bool { !budgetOmittedFactIDs.isEmpty }
}

/// Structural Project Brain retrieval and context compaction.
///
/// Selection order is stable across launches and model/provider changes:
/// 1. exact requested scope before project fallback;
/// 2. requested mission facts before project-wide facts;
/// 3. caller preferred fact kinds;
/// 4. current before unknown before explicitly included stale facts;
/// 5. most recently verified source evidence;
/// 6. stable FactID tie-break.
public enum ProjectBrainContextSelector {
    public static func select(
        from facts: [ProjectBrainFact],
        request: ProjectBrainContextRequest
    ) throws -> ProjectBrainContextSlice {
        if let error = request.validationError {
            throw ProjectBrainContextSelectionError.invalidRequest(error)
        }

        var candidates: [RankedFact] = []
        candidates.reserveCapacity(facts.count)

        let preferredKindRank = Dictionary(
            uniqueKeysWithValues: request.preferredKinds.enumerated().map { ($1, $0) }
        )
        let requestedScopeKeys = Set(request.scopes.map(ProjectBrainContextScopeKey.init))

        for fact in facts {
            guard fact.projectID == request.projectID else { continue }
            if let missionID = request.missionID {
                guard fact.missionID == nil || fact.missionID == missionID else { continue }
            }

            if let error = fact.validationError {
                throw ProjectBrainContextSelectionError.invalidFact(fact.factID, error)
            }
            guard freshnessAllows(fact.freshness, policy: request.freshnessPolicy) else {
                continue
            }

            let scopeRank: Int
            if requestedScopeKeys.isEmpty {
                scopeRank = 0
            } else if requestedScopeKeys.contains(ProjectBrainContextScopeKey(fact.scope)) {
                scopeRank = 0
            } else if request.includeProjectScopeFallback, fact.scope.kind == .project {
                scopeRank = 1
            } else {
                continue
            }

            let missionRank: Int
            if request.missionID != nil {
                missionRank = fact.missionID == request.missionID ? 0 : 1
            } else {
                missionRank = 0
            }

            let kindRank = preferredKindRank[fact.kind] ?? request.preferredKinds.count
            candidates.append(RankedFact(
                fact: fact,
                scopeRank: scopeRank,
                missionRank: missionRank,
                kindRank: kindRank,
                freshnessRank: freshnessRank(fact.freshness),
                estimatedCharacterCount: estimatedCharacterCount(of: fact)
            ))
        }

        candidates.sort(by: rankedBefore)

        var selected: [ProjectBrainFact] = []
        selected.reserveCapacity(min(request.maxFacts, candidates.count))
        var budgetOmitted: [ProjectBrainFactID] = []
        var usedCharacters = 0

        for candidate in candidates {
            guard selected.count < request.maxFacts else {
                budgetOmitted.append(candidate.fact.factID)
                continue
            }
            let proposed = usedCharacters + candidate.estimatedCharacterCount
            guard proposed <= request.maxCharacters else {
                budgetOmitted.append(candidate.fact.factID)
                continue
            }
            selected.append(candidate.fact)
            usedCharacters = proposed
        }

        return ProjectBrainContextSlice(
            projectID: request.projectID,
            missionID: request.missionID,
            facts: selected,
            budgetOmittedFactIDs: budgetOmitted,
            matchedFactCount: candidates.count,
            estimatedCharacterCount: usedCharacters,
            maximumCharacterCount: request.maxCharacters
        )
    }

    /// Deterministic conservative character accounting for the full truth-bearing payload a
    /// caller must preserve when serializing a fact into model context. This is deliberately not
    /// presented as a token count; provider-specific token budgeting belongs above this layer.
    public static func estimatedCharacterCount(of fact: ProjectBrainFact) -> Int {
        var count = fact.statement.count
        count += fact.kind.rawValue.count
        count += fact.scope.kind.rawValue.count
        count += fact.scope.reference?.count ?? 0
        count += fact.staleReason?.count ?? 0
        for provenance in fact.provenance {
            count += provenance.kind.rawValue.count
            count += provenance.reference.count
            count += provenance.contentDigest?.count ?? 0
        }
        return count
    }

    private static func freshnessAllows(
        _ freshness: ProjectBrainFreshness,
        policy: ProjectBrainContextFreshnessPolicy
    ) -> Bool {
        switch policy {
        case .currentOnly:
            freshness == .current
        case .currentAndUnknown:
            freshness != .stale
        case .includeStale:
            true
        }
    }

    private static func freshnessRank(_ freshness: ProjectBrainFreshness) -> Int {
        switch freshness {
        case .current: 0
        case .unknown: 1
        case .stale: 2
        }
    }

    private static func rankedBefore(_ lhs: RankedFact, _ rhs: RankedFact) -> Bool {
        if lhs.scopeRank != rhs.scopeRank { return lhs.scopeRank < rhs.scopeRank }
        if lhs.missionRank != rhs.missionRank { return lhs.missionRank < rhs.missionRank }
        if lhs.kindRank != rhs.kindRank { return lhs.kindRank < rhs.kindRank }
        if lhs.freshnessRank != rhs.freshnessRank {
            return lhs.freshnessRank < rhs.freshnessRank
        }
        if lhs.fact.lastVerifiedAt != rhs.fact.lastVerifiedAt {
            return lhs.fact.lastVerifiedAt > rhs.fact.lastVerifiedAt
        }
        return lhs.fact.factID.description < rhs.fact.factID.description
    }

    private struct RankedFact {
        let fact: ProjectBrainFact
        let scopeRank: Int
        let missionRank: Int
        let kindRank: Int
        let freshnessRank: Int
        let estimatedCharacterCount: Int
    }
}

private struct ProjectBrainContextScopeKey: Hashable {
    let kind: ProjectBrainScopeKind
    let reference: String?

    init(_ scope: ProjectBrainScope) {
        kind = scope.kind
        reference = scope.reference
    }
}
