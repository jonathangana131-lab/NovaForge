import Foundation

public enum ProjectBrainContextFreshnessPolicy: String, Codable, CaseIterable, Sendable {
    case currentOnly
    case currentAndUnknown
    case includeStale
}

public enum ProjectBrainSourceIdentityError: String, Error, Equatable, Sendable {
    case invalidAcceptedProjectStateID
    case invalidCheckpointReferenceID
    case invalidProjectRootRevisionID
}

/// Exact source/checkpoint identity used by authoritative Project Brain retrieval.
///
/// `acceptedProjectStateID` is the same semantic identity carried by canonical Mission checkpoints.
/// `checkpointReferenceID` is the host-authenticated canonical checkpoint reference (for example the
/// canonical MissionCheckpointID description) and `projectRootRevisionID` binds the exact accepted
/// source/project-root revision. Constructing this value is not an authority grant; only a module-
/// minted trusted subject/current-source capability can make the identity authoritative.
public struct ProjectBrainSourceIdentity: Hashable, Sendable {
    public let acceptedProjectStateID: String
    public let checkpointReferenceID: String
    public let projectRootRevisionID: String

    public init(
        acceptedProjectStateID: String,
        checkpointReferenceID: String,
        projectRootRevisionID: String
    ) throws {
        guard Self.isCanonicalIdentity(acceptedProjectStateID) else {
            throw ProjectBrainSourceIdentityError.invalidAcceptedProjectStateID
        }
        guard Self.isCanonicalIdentity(checkpointReferenceID) else {
            throw ProjectBrainSourceIdentityError.invalidCheckpointReferenceID
        }
        guard Self.isCanonicalIdentity(projectRootRevisionID) else {
            throw ProjectBrainSourceIdentityError.invalidProjectRootRevisionID
        }
        self.acceptedProjectStateID = acceptedProjectStateID
        self.checkpointReferenceID = checkpointReferenceID
        self.projectRootRevisionID = projectRootRevisionID
    }

    private init(
        uncheckedAcceptedProjectStateID: String,
        checkpointReferenceID: String,
        projectRootRevisionID: String
    ) {
        self.acceptedProjectStateID = uncheckedAcceptedProjectStateID
        self.checkpointReferenceID = checkpointReferenceID
        self.projectRootRevisionID = projectRootRevisionID
    }

    static let internalCandidateOnly = ProjectBrainSourceIdentity(
        uncheckedAcceptedProjectStateID: "internal-candidate-only",
        checkpointReferenceID: "internal-candidate-only",
        projectRootRevisionID: "internal-candidate-only"
    )

    static func isCanonicalAuthorityIdentity(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == trimmed
            && !value.isEmpty
            && value.utf8.count <= 512
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func isCanonicalIdentity(_ value: String) -> Bool {
        isCanonicalAuthorityIdentity(value)
    }
}

public enum ProjectBrainTrustedSelectionAuthorityError: Error, Equatable, Sendable {
    case invalidAuthorityReceiptID
}

/// Capability proving which accepted source/checkpoint identity the host considers current for this
/// selection. Construction is module-internal and the value is non-Codable, so a public request or
/// stale snapshot cannot self-declare itself current by copying identity strings.
///
/// A canonical host/store adapter must mint a fresh/current capability only after authenticating the
/// accepted project state + checkpoint + project-root revision. This type does not implement host
/// revocation by itself; the adapter owns capability lifetime and must not reuse superseded authority.
public struct ProjectBrainTrustedSelectionAuthority: Equatable, Sendable {
    public let projectID: ProjectID
    public let sourceIdentity: ProjectBrainSourceIdentity
    public let authorityReceiptID: String

    init(
        authenticatedProjectID projectID: ProjectID,
        sourceIdentity: ProjectBrainSourceIdentity,
        authorityReceiptID: String
    ) throws {
        guard ProjectBrainSourceIdentity.isCanonicalAuthorityIdentity(authorityReceiptID) else {
            throw ProjectBrainTrustedSelectionAuthorityError.invalidAuthorityReceiptID
        }
        self.projectID = projectID
        self.sourceIdentity = sourceIdentity
        self.authorityReceiptID = authorityReceiptID
    }
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

public enum ProjectBrainTrustedSnapshotError: Error, Equatable, Sendable {
    case invalidBrainRevision
    case invalidAuthorityReceiptID
    case invalidSnapshotDigest
    case tooManyFacts(actual: Int, maximum: Int)
    case crossProjectFact(ProjectBrainFactID)
    case invalidFact(ProjectBrainFactID, ProjectBrainValidationError)
    case duplicateFactID(ProjectBrainFactID)
}

/// Host-authenticated whole-subject Project Brain input for authoritative context selection.
///
/// Public/Codable `ProjectBrainFact` values are candidate transport. Their provenance labels are
/// structurally validated, but they do not authenticate that a user, source file, runtime, test,
/// or checkpoint actually produced the fact. Construction is therefore module-internal. A future
/// canonical Project Brain store/host adapter must authenticate the complete fact set *and* exact
/// accepted project-state/checkpoint/project-root identity before minting this non-Codable binding.
///
/// `brainRevision` is only a positive revision asserted by that authenticated producer. This type
/// does not prove monotonicity; the canonical store/adapter owns revision ordering. `snapshotDigest`
/// must identify the authenticated whole snapshot (source identity + exact fact set) so downstream
/// cache/receipt keys do not collapse two different snapshots that happen to share a receipt/revision.
public struct ProjectBrainTrustedSnapshot: Equatable, Sendable {
    public static let maximumFacts = 16_384

    public let projectID: ProjectID
    public let brainRevision: UInt64
    public let sourceIdentity: ProjectBrainSourceIdentity
    public let authorityReceiptID: String
    public let snapshotDigest: String
    public let facts: [ProjectBrainFact]

    init(
        authenticatedProjectID projectID: ProjectID,
        brainRevision: UInt64,
        sourceIdentity: ProjectBrainSourceIdentity,
        authorityReceiptID: String,
        snapshotDigest: String,
        facts: [ProjectBrainFact]
    ) throws {
        guard brainRevision > 0 else {
            throw ProjectBrainTrustedSnapshotError.invalidBrainRevision
        }
        guard ProjectBrainSourceIdentity.isCanonicalAuthorityIdentity(authorityReceiptID) else {
            throw ProjectBrainTrustedSnapshotError.invalidAuthorityReceiptID
        }
        guard ProjectBrainSourceIdentity.isCanonicalAuthorityIdentity(snapshotDigest) else {
            throw ProjectBrainTrustedSnapshotError.invalidSnapshotDigest
        }
        guard facts.count <= Self.maximumFacts else {
            throw ProjectBrainTrustedSnapshotError.tooManyFacts(
                actual: facts.count,
                maximum: Self.maximumFacts
            )
        }

        var seenFactIDs = Set<ProjectBrainFactID>()
        for fact in facts {
            guard fact.projectID == projectID else {
                throw ProjectBrainTrustedSnapshotError.crossProjectFact(fact.factID)
            }
            guard seenFactIDs.insert(fact.factID).inserted else {
                throw ProjectBrainTrustedSnapshotError.duplicateFactID(fact.factID)
            }
            if let validationError = fact.validationError {
                throw ProjectBrainTrustedSnapshotError.invalidFact(fact.factID, validationError)
            }
        }

        self.projectID = projectID
        self.brainRevision = brainRevision
        self.sourceIdentity = sourceIdentity
        self.authorityReceiptID = authorityReceiptID
        self.snapshotDigest = snapshotDigest
        self.facts = facts
    }
}

public enum ProjectBrainContextSelectionError: Error, Equatable, Sendable {
    case invalidRequest(ProjectBrainContextRequestValidationError)
    case trustedSnapshotProjectMismatch
    case trustedSelectionAuthorityProjectMismatch
    case trustedSnapshotSourceMismatch
    case invalidFact(ProjectBrainFactID, ProjectBrainValidationError)
    case duplicateFactID(ProjectBrainFactID)
    case candidateFactLimitExceeded(actual: Int, maximum: Int)
    case missingRequiredFact(ProjectBrainFactID)
    case requiredFactExcludedByFreshness(ProjectBrainFactID, ProjectBrainFreshness)
    case requiredFactsExceedFactBudget(required: Int, maximum: Int)
    case requiredFactsExceedCharacterBudget(required: Int, maximum: Int)
}

/// Context derived from a module-authenticated Project Brain snapshot and a separately authenticated
/// current-source capability. This value is deliberately non-Codable so relaunch/restore must
/// reacquire current Project Brain/source authority and re-run selection instead of replaying a
/// previously derived context as accepted truth.
public struct ProjectBrainContextSlice: Equatable, Sendable {
    public let projectID: ProjectID
    public let missionID: MissionID?
    public let snapshotBrainRevision: UInt64
    public let sourceIdentity: ProjectBrainSourceIdentity
    public let snapshotAuthorityReceiptID: String
    public let currentSourceAuthorityReceiptID: String
    public let snapshotDigest: String
    public let isTrustedSnapshotBound: Bool
    public let facts: [ProjectBrainFact]
    public let budgetOmittedFactIDs: [ProjectBrainFactID]
    public let matchedFactCount: Int
    public let estimatedCharacterCount: Int
    public let maximumCharacterCount: Int

    init(
        projectID: ProjectID,
        missionID: MissionID?,
        snapshotBrainRevision: UInt64,
        sourceIdentity: ProjectBrainSourceIdentity,
        snapshotAuthorityReceiptID: String,
        currentSourceAuthorityReceiptID: String,
        snapshotDigest: String,
        isTrustedSnapshotBound: Bool,
        facts: [ProjectBrainFact],
        budgetOmittedFactIDs: [ProjectBrainFactID],
        matchedFactCount: Int,
        estimatedCharacterCount: Int,
        maximumCharacterCount: Int
    ) {
        self.projectID = projectID
        self.missionID = missionID
        self.snapshotBrainRevision = snapshotBrainRevision
        self.sourceIdentity = sourceIdentity
        self.snapshotAuthorityReceiptID = snapshotAuthorityReceiptID
        self.currentSourceAuthorityReceiptID = currentSourceAuthorityReceiptID
        self.snapshotDigest = snapshotDigest
        self.isTrustedSnapshotBound = isTrustedSnapshotBound
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

    /// Authoritative selection requires two independently module-minted inputs: the authenticated
    /// whole Brain snapshot and the host's authenticated *current* accepted source/checkpoint state.
    /// A stale snapshot cannot self-validate by copying its own public identity into a request.
    public static func select(
        from snapshot: ProjectBrainTrustedSnapshot,
        currentAuthority: ProjectBrainTrustedSelectionAuthority,
        request: ProjectBrainContextRequest
    ) throws -> ProjectBrainContextSlice {
        if let error = request.validationError {
            throw ProjectBrainContextSelectionError.invalidRequest(error)
        }
        guard snapshot.projectID == request.projectID else {
            throw ProjectBrainContextSelectionError.trustedSnapshotProjectMismatch
        }
        guard currentAuthority.projectID == request.projectID else {
            throw ProjectBrainContextSelectionError.trustedSelectionAuthorityProjectMismatch
        }
        guard snapshot.sourceIdentity == currentAuthority.sourceIdentity else {
            throw ProjectBrainContextSelectionError.trustedSnapshotSourceMismatch
        }
        return try selectCandidateFacts(
            snapshot.facts,
            request: request,
            snapshotBrainRevision: snapshot.brainRevision,
            sourceIdentity: snapshot.sourceIdentity,
            snapshotAuthorityReceiptID: snapshot.authorityReceiptID,
            currentSourceAuthorityReceiptID: currentAuthority.authorityReceiptID,
            snapshotDigest: snapshot.snapshotDigest,
            isTrustedSnapshotBound: true
        )
    }

    /// Internal structural selector retained for package tests and future authenticated adapters.
    /// External consumers cannot turn public/Codable fact arrays into accepted context through it.
    static func select(
        from facts: [ProjectBrainFact],
        request: ProjectBrainContextRequest
    ) throws -> ProjectBrainContextSlice {
        try selectCandidateFacts(
            facts,
            request: request,
            snapshotBrainRevision: 0,
            sourceIdentity: .internalCandidateOnly,
            snapshotAuthorityReceiptID: "internal-candidate-only",
            currentSourceAuthorityReceiptID: "internal-candidate-only",
            snapshotDigest: "internal-candidate-only",
            isTrustedSnapshotBound: false
        )
    }

    private static func selectCandidateFacts(
        _ facts: [ProjectBrainFact],
        request: ProjectBrainContextRequest,
        snapshotBrainRevision: UInt64,
        sourceIdentity: ProjectBrainSourceIdentity,
        snapshotAuthorityReceiptID: String,
        currentSourceAuthorityReceiptID: String,
        snapshotDigest: String,
        isTrustedSnapshotBound: Bool
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
            snapshotBrainRevision: snapshotBrainRevision,
            sourceIdentity: sourceIdentity,
            snapshotAuthorityReceiptID: snapshotAuthorityReceiptID,
            currentSourceAuthorityReceiptID: currentSourceAuthorityReceiptID,
            snapshotDigest: snapshotDigest,
            isTrustedSnapshotBound: isTrustedSnapshotBound,
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
