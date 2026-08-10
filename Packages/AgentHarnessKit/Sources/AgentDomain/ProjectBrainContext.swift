import Foundation

public enum ProjectBrainContextFreshnessPolicy: String, Codable, CaseIterable, Sendable {
    case currentOnly
    case currentAndUnknown
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

/// Bounded deterministic Project Brain retrieval. Mission-critical truth is an immutable floor:
/// callers may add required kinds/IDs but cannot remove Design DNA, accepted decisions, or blockers.
public struct ProjectBrainContextRequest: Equatable, Sendable {
    public static let maximumFactBudget = 256
    public static let maximumCharacterBudget = 262_144
    public static let maximumScopeCount = 64
    public static let maximumRequiredFactIDCount = 256
    public static let missionCriticalKinds: [ProjectBrainFactKind] = [
        .designDNA, .acceptedDecision, .unresolvedBlocker,
    ]

    public let projectID: ProjectID
    public let missionID: MissionID?
    public let scopes: [ProjectBrainScope]
    public let preferredKinds: [ProjectBrainFactKind]
    public let additionalRequiredKinds: [ProjectBrainFactKind]
    public let requiredFactIDs: [ProjectBrainFactID]
    public let freshnessPolicy: ProjectBrainContextFreshnessPolicy
    public let includeProjectScopeFallback: Bool
    public let maxFacts: Int
    public let maxCharacters: Int

    public var requiredKinds: [ProjectBrainFactKind] {
        Self.missionCriticalKinds + additionalRequiredKinds
    }

    /// `requiredKinds` is additive to the immutable mission-critical floor for source compatibility
    /// with the V13 donor. Passing an empty array cannot weaken that floor.
    public init(
        projectID: ProjectID,
        missionID: MissionID? = nil,
        scopes: [ProjectBrainScope] = [],
        preferredKinds: [ProjectBrainFactKind] = [],
        requiredKinds: [ProjectBrainFactKind] = [],
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
        self.additionalRequiredKinds = requiredKinds
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
        guard preferredKinds.count <= ProjectBrainFactKind.allCases.count else { return .tooManyPreferredKinds }
        guard additionalRequiredKinds.count <= ProjectBrainFactKind.allCases.count else { return .tooManyRequiredKinds }
        guard requiredFactIDs.count <= Self.maximumRequiredFactIDCount else { return .tooManyRequiredFactIDs }
        guard Set(preferredKinds.map(\.rawValue)).count == preferredKinds.count else { return .duplicatePreferredKind }
        let additional = additionalRequiredKinds.map(\.rawValue)
        guard Set(additional).count == additional.count else { return .duplicateRequiredKind }
        let floor = Set(Self.missionCriticalKinds.map(\.rawValue))
        guard additional.allSatisfy({ !floor.contains($0) }) else { return .duplicateRequiredKind }
        guard Set(requiredFactIDs).count == requiredFactIDs.count else { return .duplicateRequiredFactID }
        guard Set(scopes.map(ProjectBrainContextScopeKey.init)).count == scopes.count else { return .duplicateScope }
        guard scopes.allSatisfy({ $0.validationError == nil }) else { return .invalidScope }
        return nil
    }
}

public enum ProjectBrainContextSelectionError: Error, Equatable, Sendable {
    case invalidRequest(ProjectBrainContextRequestValidationError)
    case invalidFact(ProjectBrainFactID, ProjectBrainValidationError)
    case duplicateFactID(ProjectBrainFactID)
    case candidateFactLimitExceeded(actual: Int, maximum: Int)
    case missingRequiredFact(ProjectBrainFactID)
    case requiredFactExcludedByFreshness(ProjectBrainFactID, ProjectBrainFreshness)
    case requiredFactsExceedFactBudget(required: Int, maximum: Int)
    case requiredFactsExceedCharacterBudget(required: Int, maximum: Int)
}

public struct ProjectBrainContextSlice: Equatable, Sendable {
    public let projectID: ProjectID
    public let missionID: MissionID?
    public let facts: [ProjectBrainFact]
    public let budgetOmittedFactIDs: [ProjectBrainFactID]
    public let matchedFactCount: Int
    public let estimatedCharacterCount: Int
    public let maximumCharacterCount: Int

    init(
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

public enum ProjectBrainContextSelector {
    public static let maximumCandidateFacts = 4_096

    public static func select(
        from facts: [ProjectBrainFact],
        request: ProjectBrainContextRequest
    ) throws -> ProjectBrainContextSlice {
        if let error = request.validationError {
            throw ProjectBrainContextSelectionError.invalidRequest(error)
        }

        let preferredRank = Dictionary(
            uniqueKeysWithValues: request.preferredKinds.enumerated().map { ($1.rawValue, $0) }
        )
        let requiredKinds = Set(request.requiredKinds.map(\.rawValue))
        let requiredIDs = Set(request.requiredFactIDs)
        let requestedScopes = Set(request.scopes.map(ProjectBrainContextScopeKey.init))

        var candidates: [RankedFact] = []
        candidates.reserveCapacity(min(facts.count, maximumCandidateFacts))
        var seenRelevantIDs: Set<ProjectBrainFactID> = []
        var matchedRequiredIDs: Set<ProjectBrainFactID> = []
        var relevantFactCount = 0

        for fact in facts {
            guard fact.projectID == request.projectID else { continue }
            if let missionID = request.missionID {
                guard fact.missionID == nil || fact.missionID == missionID else { continue }
            } else {
                guard fact.missionID == nil else { continue }
            }

            relevantFactCount += 1
            guard relevantFactCount <= maximumCandidateFacts else {
                throw ProjectBrainContextSelectionError.candidateFactLimitExceeded(
                    actual: relevantFactCount,
                    maximum: maximumCandidateFacts
                )
            }
            guard seenRelevantIDs.insert(fact.factID).inserted else {
                throw ProjectBrainContextSelectionError.duplicateFactID(fact.factID)
            }
            if let error = fact.validationError {
                throw ProjectBrainContextSelectionError.invalidFact(fact.factID, error)
            }

            let requiredByID = requiredIDs.contains(fact.factID)
            let requiredByKind = requiredKinds.contains(fact.kind.rawValue)
            let isRequired = requiredByID || requiredByKind

            guard freshnessAllows(fact.freshness, policy: request.freshnessPolicy) else {
                if requiredByID {
                    throw ProjectBrainContextSelectionError.missingRequiredFact(fact.factID)
                }
                if requiredByKind {
                    throw ProjectBrainContextSelectionError.requiredFactExcludedByFreshness(
                        fact.factID,
                        fact.freshness
                    )
                }
                continue
            }

            let scopeRank: Int
            if requestedScopes.isEmpty || requestedScopes.contains(ProjectBrainContextScopeKey(fact.scope)) {
                scopeRank = 0
            } else if request.includeProjectScopeFallback, fact.scope.kind == .project {
                scopeRank = 1
            } else if isRequired {
                scopeRank = 2
            } else {
                continue
            }

            if requiredByID { matchedRequiredIDs.insert(fact.factID) }
            let missionRank = request.missionID == nil ? 0 : (fact.missionID == request.missionID ? 0 : 1)
            let kindRank = preferredRank[fact.kind.rawValue] ?? request.preferredKinds.count
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

        for requiredID in request.requiredFactIDs where !matchedRequiredIDs.contains(requiredID) {
            throw ProjectBrainContextSelectionError.missingRequiredFact(requiredID)
        }

        candidates.sort(by: rankedBefore)
        let required = candidates.filter(\.isRequired)
        guard required.count <= request.maxFacts else {
            throw ProjectBrainContextSelectionError.requiredFactsExceedFactBudget(
                required: required.count,
                maximum: request.maxFacts
            )
        }

        var usedCharacters = required.reduce(into: 0) {
            $0 = saturatingAdd($0, $1.estimatedCharacterCount)
        }
        guard usedCharacters <= request.maxCharacters else {
            throw ProjectBrainContextSelectionError.requiredFactsExceedCharacterBudget(
                required: usedCharacters,
                maximum: request.maxCharacters
            )
        }

        var selected = required.map(\.fact)
        var omitted: [ProjectBrainFactID] = []
        for candidate in candidates where !candidate.isRequired {
            guard selected.count < request.maxFacts else {
                omitted.append(candidate.fact.factID)
                continue
            }
            let proposed = saturatingAdd(usedCharacters, candidate.estimatedCharacterCount)
            guard proposed <= request.maxCharacters else {
                omitted.append(candidate.fact.factID)
                continue
            }
            selected.append(candidate.fact)
            usedCharacters = proposed
        }

        return ProjectBrainContextSlice(
            projectID: request.projectID,
            missionID: request.missionID,
            facts: selected,
            budgetOmittedFactIDs: omitted,
            matchedFactCount: candidates.count,
            estimatedCharacterCount: usedCharacters,
            maximumCharacterCount: request.maxCharacters
        )
    }

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
        case .currentOnly: freshness == .current
        case .currentAndUnknown: freshness != .stale
        case .includeStale: true
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
        if lhs.freshnessRank != rhs.freshnessRank { return lhs.freshnessRank < rhs.freshnessRank }
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
