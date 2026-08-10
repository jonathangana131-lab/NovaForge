import Foundation

/// Context virtualization tiers from the NovaForge V14 Project Brain design.
///
/// These tiers describe *retrieval placement*, not truth authority. The canonical
/// Project Brain owner remains responsible for deciding which facts are accepted.
public enum ProjectBrainContextTier: String, Codable, CaseIterable, Sendable {
    /// Mission identity, current task, and safety/privacy policy that must remain present.
    case l0AlwaysResident
    /// Exact files, symbols, diffs, failures, and recent accepted decisions for the active step.
    case l1ActiveWorkingSet
    /// Retrieved project memory such as Design DNA and prior accepted checkpoints.
    case l2ProjectMemory
    /// Old transcripts/logs/full diffs/screenshots that are retrieval-only by default.
    case l3ColdArchive

    fileprivate var selectionRank: Int {
        switch self {
        case .l0AlwaysResident: 0
        case .l1ActiveWorkingSet: 1
        case .l2ProjectMemory: 2
        case .l3ColdArchive: 3
        }
    }
}

/// Freshness is preserved from the upstream Project Brain projection. This
/// package never upgrades stale/unknown material to current truth.
public enum ProjectBrainRetrievalFreshness: String, Codable, CaseIterable, Sendable {
    case current
    case stale
    case unknown

    fileprivate var selectionRank: Int {
        switch self {
        case .current: 0
        case .unknown: 1
        case .stale: 2
        }
    }
}

/// Conservative implementation bounds. They are safety limits for this pure
/// Swift planner, not measured iPhone capacity or model context limits.
public enum ProjectBrainRetrievalLimits {
    public static let maximumIdentifierUTF8Bytes = 512
    public static let maximumFragmentUTF8Bytes = 131_072
    public static let maximumCandidateCount = 4_096
    public static let maximumSelectedItems = 1_024
    public static let maximumContextUTF8Bytes = 16 * 1_024 * 1_024
}

/// A fully rendered context fragment projected from an upstream Project Brain fact.
///
/// `renderedContext` must already contain whatever labels/provenance text the host
/// wants the model to receive. This lets the planner account exact UTF-8 bytes
/// without pretending bytes are model tokens. Exact token accounting belongs to
/// a tokenizer-qualified Forge Compact adapter.
public struct ProjectBrainRetrievalCandidate: Codable, Equatable, Sendable {
    public let factID: String
    public let projectID: String
    public let sourceRevisionID: String
    public let missionID: String?
    public let tier: ProjectBrainContextTier
    public let freshness: ProjectBrainRetrievalFreshness
    public let priority: UInt16
    public let relevance: UInt16
    public let renderedContext: String

    private enum CodingKeys: String, CodingKey {
        case factID
        case projectID
        case sourceRevisionID
        case missionID
        case tier
        case freshness
        case priority
        case relevance
        case renderedContext
    }

    public init(
        factID: String,
        projectID: String,
        sourceRevisionID: String,
        missionID: String? = nil,
        tier: ProjectBrainContextTier,
        freshness: ProjectBrainRetrievalFreshness,
        priority: UInt16 = 0,
        relevance: UInt16 = 0,
        renderedContext: String
    ) throws {
        try Self.validateIdentifier(factID, field: .factID)
        try Self.validateIdentifier(projectID, field: .projectID)
        try Self.validateIdentifier(sourceRevisionID, field: .sourceRevisionID)
        if let missionID {
            try Self.validateIdentifier(missionID, field: .missionID)
        }
        try Self.validateRenderedContext(renderedContext)

        self.factID = factID
        self.projectID = projectID
        self.sourceRevisionID = sourceRevisionID
        self.missionID = missionID
        self.tier = tier
        self.freshness = freshness
        self.priority = priority
        self.relevance = relevance
        self.renderedContext = renderedContext
    }

    public var renderedUTF8ByteCount: Int {
        renderedContext.utf8.count
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            factID: container.decode(String.self, forKey: .factID),
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevisionID: container.decode(String.self, forKey: .sourceRevisionID),
            missionID: container.decodeIfPresent(String.self, forKey: .missionID),
            tier: container.decode(ProjectBrainContextTier.self, forKey: .tier),
            freshness: container.decode(ProjectBrainRetrievalFreshness.self, forKey: .freshness),
            priority: container.decode(UInt16.self, forKey: .priority),
            relevance: container.decode(UInt16.self, forKey: .relevance),
            renderedContext: container.decode(String.self, forKey: .renderedContext)
        )
    }

    private static func validateIdentifier(
        _ value: String,
        field: ProjectBrainRetrievalIdentityField
    ) throws {
        guard !value.isEmpty else {
            throw ProjectBrainRetrievalError.invalidIdentifier(field)
        }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ProjectBrainRetrievalError.invalidIdentifier(field)
        }
        guard value.utf8.count <= ProjectBrainRetrievalLimits.maximumIdentifierUTF8Bytes else {
            throw ProjectBrainRetrievalError.invalidIdentifier(field)
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ProjectBrainRetrievalError.invalidIdentifier(field)
        }
    }

    private static func validateRenderedContext(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectBrainRetrievalError.blankRenderedContext
        }
        guard value.utf8.count <= ProjectBrainRetrievalLimits.maximumFragmentUTF8Bytes else {
            throw ProjectBrainRetrievalError.renderedContextTooLarge
        }
    }
}

public enum ProjectBrainRetrievalIdentityField: String, Codable, Equatable, Sendable {
    case requestID
    case factID
    case projectID
    case sourceRevisionID
    case missionID
}

public struct ProjectBrainRetrievalBudget: Codable, Equatable, Sendable {
    public let maximumItems: Int
    public let maximumUTF8Bytes: Int

    public init(maximumItems: Int, maximumUTF8Bytes: Int) throws {
        guard maximumItems > 0,
              maximumItems <= ProjectBrainRetrievalLimits.maximumSelectedItems
        else {
            throw ProjectBrainRetrievalError.invalidBudget
        }
        guard maximumUTF8Bytes > 0,
              maximumUTF8Bytes <= ProjectBrainRetrievalLimits.maximumContextUTF8Bytes
        else {
            throw ProjectBrainRetrievalError.invalidBudget
        }
        self.maximumItems = maximumItems
        self.maximumUTF8Bytes = maximumUTF8Bytes
    }

    private enum CodingKeys: String, CodingKey {
        case maximumItems
        case maximumUTF8Bytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumItems: container.decode(Int.self, forKey: .maximumItems),
            maximumUTF8Bytes: container.decode(Int.self, forKey: .maximumUTF8Bytes)
        )
    }
}

/// Host request for one bounded retrieval step.
///
/// `requiredFactIDs` represents facts the owning mission/Project Brain adapter says
/// cannot be omitted for this step. The retrieval package does not authenticate
/// that authority; it only guarantees those IDs are either included or planning
/// fails closed. L0 candidates are always treated as required independently.
public struct ProjectBrainRetrievalRequest: Codable, Equatable, Sendable {
    public let requestID: String
    public let projectID: String
    public let sourceRevisionID: String
    public let missionID: String?
    public let requiredFactIDs: [String]
    public let explicitlyRequestedColdFactIDs: [String]
    public let budget: ProjectBrainRetrievalBudget

    private enum CodingKeys: String, CodingKey {
        case requestID
        case projectID
        case sourceRevisionID
        case missionID
        case requiredFactIDs
        case explicitlyRequestedColdFactIDs
        case budget
    }

    public init(
        requestID: String,
        projectID: String,
        sourceRevisionID: String,
        missionID: String? = nil,
        requiredFactIDs: [String] = [],
        explicitlyRequestedColdFactIDs: [String] = [],
        budget: ProjectBrainRetrievalBudget
    ) throws {
        try Self.validateIdentifier(requestID, field: .requestID)
        try Self.validateIdentifier(projectID, field: .projectID)
        try Self.validateIdentifier(sourceRevisionID, field: .sourceRevisionID)
        if let missionID {
            try Self.validateIdentifier(missionID, field: .missionID)
        }
        try Self.validateFactIDSet(requiredFactIDs)
        try Self.validateFactIDSet(explicitlyRequestedColdFactIDs)

        self.requestID = requestID
        self.projectID = projectID
        self.sourceRevisionID = sourceRevisionID
        self.missionID = missionID
        self.requiredFactIDs = requiredFactIDs.sorted()
        self.explicitlyRequestedColdFactIDs = explicitlyRequestedColdFactIDs.sorted()
        self.budget = budget
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(String.self, forKey: .requestID),
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevisionID: container.decode(String.self, forKey: .sourceRevisionID),
            missionID: container.decodeIfPresent(String.self, forKey: .missionID),
            requiredFactIDs: container.decode([String].self, forKey: .requiredFactIDs),
            explicitlyRequestedColdFactIDs: container.decode([String].self, forKey: .explicitlyRequestedColdFactIDs),
            budget: container.decode(ProjectBrainRetrievalBudget.self, forKey: .budget)
        )
    }

    private static func validateIdentifier(
        _ value: String,
        field: ProjectBrainRetrievalIdentityField
    ) throws {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.utf8.count <= ProjectBrainRetrievalLimits.maximumIdentifierUTF8Bytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ProjectBrainRetrievalError.invalidIdentifier(field)
        }
    }

    private static func validateFactIDSet(_ values: [String]) throws {
        guard Set(values).count == values.count else {
            throw ProjectBrainRetrievalError.duplicateRequestedFactID
        }
        for value in values {
            try validateIdentifier(value, field: .factID)
        }
    }
}

public enum ProjectBrainRetrievalOmissionReason: String, Codable, Equatable, Sendable {
    case coldArchiveNotRequested
    case itemBudget
    case byteBudget
}

public struct ProjectBrainRetrievalOmission: Equatable, Sendable {
    public let factID: String
    public let reason: ProjectBrainRetrievalOmissionReason

    public init(factID: String, reason: ProjectBrainRetrievalOmissionReason) {
        self.factID = factID
        self.reason = reason
    }
}

/// Fresh derived context plan. It is intentionally not Codable: callers should
/// re-run retrieval against current source-bound candidates after relaunch or a
/// source revision change rather than restoring a stale selection as live state.
public struct ProjectBrainRetrievalPlan: Equatable, Sendable {
    public let requestID: String
    public let projectID: String
    public let sourceRevisionID: String
    public let missionID: String?
    public let selected: [ProjectBrainRetrievalCandidate]
    public let omissions: [ProjectBrainRetrievalOmission]
    public let renderedUTF8ByteCount: Int

    public var renderedContext: String {
        selected.map(\.renderedContext).joined(separator: "\n")
    }

    fileprivate init(
        request: ProjectBrainRetrievalRequest,
        selected: [ProjectBrainRetrievalCandidate],
        omissions: [ProjectBrainRetrievalOmission]
    ) {
        self.requestID = request.requestID
        self.projectID = request.projectID
        self.sourceRevisionID = request.sourceRevisionID
        self.missionID = request.missionID
        self.selected = selected
        self.omissions = omissions
        self.renderedUTF8ByteCount = selected
            .map(\.renderedContext)
            .joined(separator: "\n")
            .utf8
            .count
    }
}

public enum ProjectBrainRetrievalError: Error, Equatable, Sendable {
    case invalidIdentifier(ProjectBrainRetrievalIdentityField)
    case blankRenderedContext
    case renderedContextTooLarge
    case invalidBudget
    case duplicateRequestedFactID
    case tooManyCandidates
    case duplicateCandidateFactID(String)
    case projectMismatch(factID: String)
    case sourceRevisionMismatch(factID: String)
    case missionMismatch(factID: String)
    case missingRequiredFact(String)
    case requiredContextExceedsItemBudget
    case requiredContextExceedsByteBudget
}

public enum ProjectBrainRetrievalPlanner {
    public static func plan(
        request: ProjectBrainRetrievalRequest,
        candidates: [ProjectBrainRetrievalCandidate]
    ) throws -> ProjectBrainRetrievalPlan {
        guard candidates.count <= ProjectBrainRetrievalLimits.maximumCandidateCount else {
            throw ProjectBrainRetrievalError.tooManyCandidates
        }

        var byID: [String: ProjectBrainRetrievalCandidate] = [:]
        byID.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard candidate.projectID == request.projectID else {
                throw ProjectBrainRetrievalError.projectMismatch(factID: candidate.factID)
            }
            guard candidate.sourceRevisionID == request.sourceRevisionID else {
                throw ProjectBrainRetrievalError.sourceRevisionMismatch(factID: candidate.factID)
            }
            if let candidateMissionID = candidate.missionID {
                guard candidateMissionID == request.missionID else {
                    throw ProjectBrainRetrievalError.missionMismatch(factID: candidate.factID)
                }
            }
            guard byID[candidate.factID] == nil else {
                throw ProjectBrainRetrievalError.duplicateCandidateFactID(candidate.factID)
            }
            byID[candidate.factID] = candidate
        }

        for requiredFactID in request.requiredFactIDs where byID[requiredFactID] == nil {
            throw ProjectBrainRetrievalError.missingRequiredFact(requiredFactID)
        }

        let explicitlyRequestedColdIDs = Set(request.explicitlyRequestedColdFactIDs)
        var mandatoryIDs = Set(request.requiredFactIDs)
        for candidate in candidates where candidate.tier == .l0AlwaysResident {
            mandatoryIDs.insert(candidate.factID)
        }

        let mandatory = mandatoryIDs
            .compactMap { byID[$0] }
            .sorted(by: selectionPrecedes)

        guard mandatory.count <= request.budget.maximumItems else {
            throw ProjectBrainRetrievalError.requiredContextExceedsItemBudget
        }

        let mandatoryBytes = renderedByteCount(mandatory)
        guard mandatoryBytes <= request.budget.maximumUTF8Bytes else {
            throw ProjectBrainRetrievalError.requiredContextExceedsByteBudget
        }

        var selected = mandatory
        var selectedIDs = mandatoryIDs
        var usedBytes = mandatoryBytes
        var omissions: [ProjectBrainRetrievalOmission] = []

        let optional = candidates
            .filter { !selectedIDs.contains($0.factID) }
            .sorted(by: selectionPrecedes)

        for candidate in optional {
            if candidate.tier == .l3ColdArchive,
               !explicitlyRequestedColdIDs.contains(candidate.factID)
            {
                omissions.append(
                    .init(factID: candidate.factID, reason: .coldArchiveNotRequested)
                )
                continue
            }

            guard selected.count < request.budget.maximumItems else {
                omissions.append(.init(factID: candidate.factID, reason: .itemBudget))
                continue
            }

            let separatorBytes = selected.isEmpty ? 0 : 1
            let incrementalBytes = separatorBytes + candidate.renderedUTF8ByteCount
            guard incrementalBytes <= request.budget.maximumUTF8Bytes - usedBytes else {
                omissions.append(.init(factID: candidate.factID, reason: .byteBudget))
                continue
            }

            selected.append(candidate)
            selectedIDs.insert(candidate.factID)
            usedBytes += incrementalBytes
        }

        omissions.sort {
            if $0.factID != $1.factID { return $0.factID < $1.factID }
            return $0.reason.rawValue < $1.reason.rawValue
        }

        return ProjectBrainRetrievalPlan(
            request: request,
            selected: selected,
            omissions: omissions
        )
    }

    private static func selectionPrecedes(
        _ lhs: ProjectBrainRetrievalCandidate,
        _ rhs: ProjectBrainRetrievalCandidate
    ) -> Bool {
        if lhs.tier.selectionRank != rhs.tier.selectionRank {
            return lhs.tier.selectionRank < rhs.tier.selectionRank
        }
        if lhs.freshness.selectionRank != rhs.freshness.selectionRank {
            return lhs.freshness.selectionRank < rhs.freshness.selectionRank
        }
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        if lhs.relevance != rhs.relevance {
            return lhs.relevance > rhs.relevance
        }
        return lhs.factID < rhs.factID
    }

    private static func renderedByteCount(
        _ candidates: [ProjectBrainRetrievalCandidate]
    ) -> Int {
        guard !candidates.isEmpty else { return 0 }
        let payloadBytes = candidates.reduce(into: 0) { total, candidate in
            total += candidate.renderedUTF8ByteCount
        }
        return payloadBytes + candidates.count - 1
    }
}
