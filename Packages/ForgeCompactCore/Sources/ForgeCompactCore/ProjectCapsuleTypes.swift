import Foundation

public enum ForgeCompactError: Error, Equatable, Sendable {
    case blankIdentity(field: String)
    case blankFactID
    case blankFactSummary(id: String)
    case invalidTokenEstimate(id: String)
    case invalidRelevance(id: String)
    case missingProvenance(id: String)
    case blankProvenanceID(factID: String)
    case duplicateFactID(String)
    case staleProtectedTruth(String)
    case invalidBudget
    case requiredTruthExceedsBudget(required: Int, available: Int)
    case requiredTruthExceedsFactCount(required: Int, available: Int)
    case archiveSchema(Int)
    case archiveBudgetMismatch
    case archiveTokenTotalMismatch
    case archiveContainsDuplicateFact(String)
    case archiveOmittedProtectedTruth(String)
    case archiveSelectionOrder
}

public struct ProjectCapsuleIdentity: Codable, Equatable, Hashable, Sendable {
    public let projectID: String
    public let missionID: String
    public let sourceRevision: String
    public let missionRevision: UInt64
    public let authorityEpoch: UInt64

    public init(
        projectID: String,
        missionID: String,
        sourceRevision: String,
        missionRevision: UInt64,
        authorityEpoch: UInt64
    ) throws {
        self.projectID = try Self.requireIdentity(projectID, field: "projectID")
        self.missionID = try Self.requireIdentity(missionID, field: "missionID")
        self.sourceRevision = try Self.requireIdentity(sourceRevision, field: "sourceRevision")
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, missionID, sourceRevision, missionRevision, authorityEpoch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            missionID: container.decode(String.self, forKey: .missionID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            missionRevision: container.decode(UInt64.self, forKey: .missionRevision),
            authorityEpoch: container.decode(UInt64.self, forKey: .authorityEpoch)
        )
    }

    private static func requireIdentity(_ value: String, field: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ForgeCompactError.blankIdentity(field: field) }
        return normalized
    }
}

public enum ProjectCapsuleLayer: Int, Codable, CaseIterable, Comparable, Sendable {
    case l0AlwaysResident = 0
    case l1ActiveWorkingSet = 1
    case l2ProjectMemory = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ProjectCapsuleFactKind: String, Codable, CaseIterable, Sendable {
    case missionIdentity
    case currentStage
    case privacyPolicy
    case requirement
    case unresolvedDecision
    case acceptedDecision
    case activeFailure
    case knownDefect
    case designDNA
    case sourceReference
    case testReceipt
    case runtimeReceipt
    case performanceReceipt
    case knownLimitation
    case recentChange
    case historicalContext

    public var isProtectedTruth: Bool {
        switch self {
        case .missionIdentity, .currentStage, .privacyPolicy, .requirement,
             .unresolvedDecision, .acceptedDecision, .activeFailure, .designDNA, .knownLimitation:
            true
        case .knownDefect, .sourceReference, .testReceipt,
             .runtimeReceipt, .performanceReceipt, .recentChange, .historicalContext:
            false
        }
    }
}

public enum ProjectCapsuleFreshness: String, Codable, Sendable {
    case current
    case stale
    case unknown
}

public enum ProjectCapsuleProvenanceKind: String, Codable, CaseIterable, Sendable {
    case userDecision
    case missionState
    case sourceRevision
    case testReceipt
    case runtimeReceipt
    case performanceReceipt
    case policy
    case designDecision
}

public struct ProjectCapsuleProvenance: Codable, Equatable, Hashable, Sendable {
    public let kind: ProjectCapsuleProvenanceKind
    public let stableID: String

    public init(kind: ProjectCapsuleProvenanceKind, stableID: String) throws {
        let normalized = stableID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ForgeCompactError.blankProvenanceID(factID: "<construction>")
        }
        self.kind = kind
        self.stableID = normalized
    }

    private enum CodingKeys: String, CodingKey { case kind, stableID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ProjectCapsuleProvenanceKind.self, forKey: .kind),
            stableID: container.decode(String.self, forKey: .stableID)
        )
    }
}
