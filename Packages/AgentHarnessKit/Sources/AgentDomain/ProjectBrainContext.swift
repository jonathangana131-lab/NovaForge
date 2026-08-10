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
    case factBudgetTooLarge
    case emptyCharacterBudget
    case characterBudgetTooLarge
    case tooManyScopes
    case tooManyPreferredKinds
    case tooManyRequiredKinds
    case tooManyRequiredFactIDs
    case duplicatePreferredKind
    case duplicateRequiredKind
    case duplicateRequiredFactID
    case duplicateScope
    case invalidScope
}

/// Bounded, deterministic retrieval request for one Project Brain neighborhood.
///
/// This is deliberately not a semantic-search prompt. Callers resolve the structural
/// neighborhood they need (project / mission / file / symbol / runtime), then this request
/// selects source-backed durable facts without turning a transcript or generated summary into
/// canonical project state.
///
/// Mission-critical facts are retained by default. A caller may add exact `requiredFactIDs`,
/// but cannot weaken the default required kinds. If required truth cannot fit the requested
/// budget, selection fails closed rather than silently dropping accepted state.
public struct ProjectBrainContextRequest: Equatable, Sendable {
    public static let maximumFactBudget = 256
    public static let maximumCharacterBudget = 262_144
    public static let maximumScopeCount = 64
    public static let maximumRequiredFactIDCount = 256
    public static let missionCriticalKinds: [ProjectBrainFactKind] = [
        .designDNA,
        .acceptedDecision,
        .unresolvedBlocker,
    ]

    public let projectID: ProjectID
    public let missionID: MissionID?
    public let scopes: [ProjectBrainScope]
    public let preferredKinds: [ProjectBrainFactKind]
    public let requiredKinds: [ProjectBrainFactKind]
    public let requiredFactIDs: [ProjectBrainFactID]
    public let freshnessPolicy: ProjectBrainContextFreshnessPolicy
    public let includeProjectScopeFallback: Bool
    public let maxFacts: Int
    public let maxCharacters: Int

    public init(
        projectID: ProjectID,
        missionID: MissionID? = nil,
        scopes: [ProjectBrainScope] = [],
        preferredKinds: [ProjectBrainFactKind] = [],
        requiredKinds: [ProjectBrainFactKind] = ProjectBrainContextRequest.missionCriticalKinds,
        requiredFactIDs: [ProjectBrainFactID] = [],
        freshnessPolicy: ProjectBrainContextFreshnessPolicy = .currentOnly,
        includeProjectScopeFallback: Bool = true,
        maxFacts: Int = 24,
        maxCharacters: Int = 16_000
    ) {
        self.projectID = projectID
        self.missionID = missionID
        self.scopes = scopes
        self.preferredKinds = preferredKinds
        self.requiredKinds = requiredKinds
        self.requiredFactIDs = requiredFactIDs
        self.freshnessPolicy = freshnessPolicy
        self.includeProjectScopeFallback = includeProjectScopeFallback
        self.maxFacts = maxFacts
        self.maxCharacters = maxCharacters
    }

    public var validationError: ProjectBrainContextRequestValidationError? {
        guard maxFacts > 0 else { return .emptyFactBudget }
        guard maxFacts <= Self.maximumFactBudget else { return .factBudgetTooLarge }
        guard maxCharacters > 0 else { return .emptyCharacterBudget }
        guard maxCharacters <= Self.maximumCharacterBudget else { return .characterBudgetTooLarge }
        guard scopes.count <= Self.maximumScopeCount else { return .tooManyScopes }
        guard preferredKinds.count <= ProjectBrainFactKind.allCases.count else {
            return .tooManyPreferredKinds
        }
        guard requiredKinds.count <= ProjectBrainFactKind.allCases.count else {
            return .tooManyRequiredKinds
        }
        guard requiredFactIDs.count <= Self.maximumRequiredFactIDCount else {
            return .tooManyRequiredFactIDs
        }
        guard Set(preferredKinds.map(\.rawValue)).count == preferredKinds.count else {
            return .duplicatePreferredKind
        }
        guard Set(requiredKinds.map(\.rawValue)).count == requiredKinds.count else {
            return .duplicateRequiredKind
        }
        guard Set(requiredFactIDs).count == requiredFactIDs.count else {
            return .duplicateRequiredFactID
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
    case duplicateFactID(ProjectBrainFactID)
    case candidateFactLimitExceeded(actual: Int, maximum: Int)
    case missingRequiredFact(ProjectBrainFactID)
    case requiredFactsExceedFactBudget(required: Int, maximum: Int)
    case requiredFactsExceedCharacterBudget(required: Int, maximum: Int)
}

/// Exact source-backed facts selected for one bounded model/tool context.
///
/// No fact is rewritten or summarized here. `budgetOmittedFactIDs` makes best-effort compaction
/// explicit. Required truth is never reported there: if it cannot fit, selection throws.
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
/// 1. required mission-critical/exact facts before best-effort facts;
/// 2. exact requested scope before project fallback, then required off-scope truth;
/// 3. requested mission facts before project-wide facts;
/// 4. current before unknown before explicitly included stale facts;
/// 5. caller preferred fact kinds;
/// 6. most recently verified source evidence;
/// 7. stable FactID tie-break.
public enum ProjectBrainContextSelector {
    public static let maximumCandidateFacts = 4_096

    public static func select(
        from facts: [ProjectBrainFact],
        request: ProjectBrainContextRequest
    ) throws -> ProjectBrainContextSlice {
        if let error = request.validationError {
            throw ProjectBrainContextSelectionError.invalidRequest(error)
        }
        guard facts.count <= maximumCandidateFacts else {
            throw ProjectBrainContextSelectionError.candidateFactLimitExceeded(
                actual: facts.count,
                maximum: maximumCandidateFacts
            )
        }

        var candidates: [RankedFact] = []
        candidates.reserveCapacity(min(facts.count, maximumCandidateFacts))

        let preferredKindRank = Dictionary(
            uniqueKeysWithValues: request.preferredKinds.enumerated().map { ($1.rawValue, $0) }
        )
        let requiredKinds = Set(request.requiredKinds.map(\.rawValue))
        let requiredFactIDs = Set(request.requiredFactIDs)
        let requestedScopeKeys = Set(request.scopes.map(ProjectBrainContextScopeKey.init))
        var seenRelevantFactIDs: Set<ProjectBrainFactID> = []
        var matchedRequiredFactIDs: Set<ProjectBrainFactID> = []

        for fact in facts {
            guard fact.projectID == request.projectID else { continue }
            if let missionID = request.missionID {
                guard fact.missionID == nil || fact.missionID == missionID else { continue }
            } else {
                // Project-wide context must not silently merge facts from unrelated historical
                // missions. Mission-scoped facts require an explicit mission neighborhood.
                guard fact.missionID == nil else { continue }
            }

            guard seenRelevantFactIDs.insert(fact.factID).inserted else {
                throw ProjectBrainContextSelectionError.duplicateFactID(fact.factID)
            }
            if let error = fact.validationError {
                throw ProjectBrainContextSelectionError.invalidFact(fact.factID, error)
            }

            let requiredByID = requiredFactIDs.contains(fact.factID)
            let requiredByKind = requiredKinds.contains(fact.kind.rawValue)
            let isRequired = requiredByID || requiredByKind

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
            } else if isRequired {
                // Required mission truth may not disappear merely because the active working-set
                // request is narrowed to a file/symbol/runtime neighborhood.
                scopeRank = 2
            } else {
                continue
            }

            if requiredByID {
                matchedRequiredFactIDs.insert(fact.factID)
            }

            let missionRank: Int
            if request.missionID != nil {
                missionRank = fact.missionID == request.missionID ? 0 : 1
            } else {
                missionRank = 0
            }

            let kindRank = preferredKindRank[fact.kind.rawValue] ?? request.preferredKinds.count
            candidates.append(RankedFact(
                fact: fact,
                isRequired: isRequired,
                scopeRank: scopeRank,
                missionRank: missionRank,
                kindRank: kindRank,
                freshnessRank: freshnessRank(fact.freshness),
                estimatedCharacterCount: estimatedCharacterCount(of: fact)
            ))
        }

        for requiredFactID in request.requiredFactIDs where !matchedRequiredFactIDs.contains(requiredFactID) {
            throw ProjectBrainContextSelectionError.missingRequiredFact(requiredFactID)
        }

        candidates.sort(by: rankedBefore)

        let requiredCandidates = candidates.filter(\.isRequired)
        guard requiredCandidates.count <= request.maxFacts else {
            throw ProjectBrainContextSelectionError.requiredFactsExceedFactBudget(
                required: requiredCandidates.count,
                maximum: request.maxFacts
            )
        }

        var usedCharacters = 0
        for candidate in requiredCandidates {
            usedCharacters = saturatingAdd(usedCharacters, candidate.estimatedCharacterCount)
        }
        guard usedCharacters <= request.maxCharacters else {
            throw ProjectBrainContextSelectionError.requiredFactsExceedCharacterBudget(
                required: usedCharacters,
                maximum: request.maxCharacters
            )
        }

        var selected = requiredCandidates.map(\.fact)
        selected.reserveCapacity(min(request.maxFacts, candidates.count))
        var budgetOmitted: [ProjectBrainFactID] = []

        for candidate in candidates where !candidate.isRequired {
            guard selected.count < request.maxFacts else {
                budgetOmitted.append(candidate.fact.factID)
                continue
            }
            let proposed = saturatingAdd(usedCharacters, candidate.estimatedCharacterCount)
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

    /// Deterministic model-independent character estimate for the complete fact identity, scope,
    /// freshness, statement, and provenance payload. Provider-specific serialization overhead and
    /// tokenization belong above this domain layer. Arithmetic saturates instead of trapping.
    public static func estimatedCharacterCount(of fact: ProjectBrainFact) -> Int {
        var count = fact.statement.count
        count = saturatingAdd(count, fact.factID.description.count)
        count = saturatingAdd(count, fact.projectID.description.count)
        count = saturatingAdd(count, fact.missionID?.description.count ?? 0)
        count = saturatingAdd(count, fact.kind.rawValue.count)
        count = saturatingAdd(count, fact.scope.kind.rawValue.count)
        count = saturatingAdd(count, fact.scope.reference?.count ?? 0)
        count = saturatingAdd(count, fact.freshness.rawValue.count)
        count = saturatingAdd(count, String(fact.lastVerifiedAt.rawValue).count)
        count = saturatingAdd(count, fact.staleReason?.count ?? 0)
        for provenance in fact.provenance {
            count = saturatingAdd(count, provenance.kind.rawValue.count)
            count = saturatingAdd(count, provenance.reference.count)
            count = saturatingAdd(count, String(provenance.capturedAt.rawValue).count)
            count = saturatingAdd(count, provenance.contentDigest?.count ?? 0)
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
        if lhs.isRequired != rhs.isRequired { return lhs.isRequired && !rhs.isRequired }
        if lhs.scopeRank != rhs.scopeRank { return lhs.scopeRank < rhs.scopeRank }
        if lhs.missionRank != rhs.missionRank { return lhs.missionRank < rhs.missionRank }
        if lhs.freshnessRank != rhs.freshnessRank {
            return lhs.freshnessRank < rhs.freshnessRank
        }
        if lhs.kindRank != rhs.kindRank { return lhs.kindRank < rhs.kindRank }
        if lhs.fact.lastVerifiedAt != rhs.fact.lastVerifiedAt {
            return lhs.fact.lastVerifiedAt > rhs.fact.lastVerifiedAt
        }
        return lhs.fact.factID.description < rhs.fact.factID.description
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private struct RankedFact {
        let fact: ProjectBrainFact
        let isRequired: Bool
        let scopeRank: Int
        let missionRank: Int
        let kindRank: Int
        let freshnessRank: Int
        let estimatedCharacterCount: Int
    }
}

private struct ProjectBrainContextScopeKey: Hashable {
    let kindRawValue: String
    let reference: String?

    init(_ scope: ProjectBrainScope) {
        kindRawValue = scope.kind.rawValue
        reference = scope.reference
    }
}
