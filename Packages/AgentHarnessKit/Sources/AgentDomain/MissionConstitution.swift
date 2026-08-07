import Foundation

public enum MissionIDTag: AgentIdentifierTag {}
public typealias MissionID = AgentIdentifier<MissionIDTag>

/// User-facing build depth. This is independent from provider reasoning controls.
public enum MissionBuildDepth: String, Codable, CaseIterable, Sendable {
    case prototype
    case polished
    case obsessive
}

/// How freely the mission may invent within the accepted product intent.
public enum MissionCreativity: String, Codable, CaseIterable, Sendable {
    case faithful
    case balanced
    case inventive
}

/// How aggressively implementation may replace legacy structure.
public enum MissionRefactorRisk: String, Codable, CaseIterable, Sendable {
    case preserve
    case balanced
    case rebuild
}

/// Desired execution locality recorded by the mission contract.
/// Authorization and actual route eligibility remain policy/runtime concerns.
public enum MissionLocalityPreference: String, Codable, CaseIterable, Sendable {
    case unspecified
    case localOnly
    case hybrid
    case hostedAllowed
}

/// Evidence classes are claims the mission expects before completion can be accepted.
public enum MissionEvidenceClass: String, Codable, CaseIterable, Hashable, Sendable {
    case generated
    case compiled
    case runtimeTested
    case visuallyInspected
    case accessibilityChecked
    case performanceMeasured
    case simulatorVerified
    case physicalDeviceVerified
}

/// Sorted unique strings keep persisted mission contracts deterministic without
/// discarding the user's exact accepted wording.
public struct MissionStringSet: Codable, Equatable, Sendable {
    public let values: [String]

    private enum CodingKeys: String, CodingKey { case values }

    public init<S: Sequence>(_ values: S) where S.Element == String {
        self.values = Array(Set(values)).sorted()
    }

    public func contains(_ value: String) -> Bool {
        values.binarySearchMissionValue(value)
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

/// Sorted unique evidence classes make expected completion proof deterministic.
public struct MissionEvidenceSet: Codable, Equatable, Sendable {
    public let values: [MissionEvidenceClass]

    private enum CodingKeys: String, CodingKey { case values }

    public init<S: Sequence>(_ values: S) where S.Element == MissionEvidenceClass {
        self.values = Array(Set(values)).sorted { $0.rawValue < $1.rawValue }
    }

    public func contains(_ value: MissionEvidenceClass) -> Bool {
        values.contains(value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode([MissionEvidenceClass].self, forKey: .values))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
    }
}

/// Concise accepted definition of what the user asked NovaForge to build and
/// what evidence is required before the mission can truthfully call it done.
///
/// The constitution belongs to the durable mission, not to a provider transcript.
/// Editing it should create a new accepted revision rather than silently weakening
/// an existing contract.
public struct MissionConstitution: Codable, Equatable, Sendable {
    public let missionID: MissionID
    public let projectID: ProjectID
    public let revision: UInt64
    public let acceptedAt: AgentInstant

    public let productGoal: String
    public let projectType: String
    public let designIntent: String?
    public let orientationTarget: String?
    public let deviceTargets: MissionStringSet
    public let requiredCapabilities: MissionStringSet
    public let explicitNonGoals: MissionStringSet
    public let constraints: MissionStringSet

    public let buildDepth: MissionBuildDepth
    public let creativity: MissionCreativity
    public let refactorRisk: MissionRefactorRisk
    public let localityPreference: MissionLocalityPreference

    public let performanceTarget: String?
    public let accessibilityTarget: String?
    public let persistenceExpectations: String?
    public let acceptanceJourneys: MissionStringSet
    public let expectedEvidence: MissionEvidenceSet

    public init(
        missionID: MissionID,
        projectID: ProjectID,
        revision: UInt64 = 1,
        acceptedAt: AgentInstant,
        productGoal: String,
        projectType: String,
        designIntent: String? = nil,
        orientationTarget: String? = nil,
        deviceTargets: MissionStringSet = MissionStringSet([]),
        requiredCapabilities: MissionStringSet = MissionStringSet([]),
        explicitNonGoals: MissionStringSet = MissionStringSet([]),
        constraints: MissionStringSet = MissionStringSet([]),
        buildDepth: MissionBuildDepth = .polished,
        creativity: MissionCreativity = .balanced,
        refactorRisk: MissionRefactorRisk = .balanced,
        localityPreference: MissionLocalityPreference = .unspecified,
        performanceTarget: String? = nil,
        accessibilityTarget: String? = nil,
        persistenceExpectations: String? = nil,
        acceptanceJourneys: MissionStringSet = MissionStringSet([]),
        expectedEvidence: MissionEvidenceSet = MissionEvidenceSet([])
    ) {
        self.missionID = missionID
        self.projectID = projectID
        self.revision = revision
        self.acceptedAt = acceptedAt
        self.productGoal = productGoal
        self.projectType = projectType
        self.designIntent = designIntent
        self.orientationTarget = orientationTarget
        self.deviceTargets = deviceTargets
        self.requiredCapabilities = requiredCapabilities
        self.explicitNonGoals = explicitNonGoals
        self.constraints = constraints
        self.buildDepth = buildDepth
        self.creativity = creativity
        self.refactorRisk = refactorRisk
        self.localityPreference = localityPreference
        self.performanceTarget = performanceTarget
        self.accessibilityTarget = accessibilityTarget
        self.persistenceExpectations = persistenceExpectations
        self.acceptanceJourneys = acceptanceJourneys
        self.expectedEvidence = expectedEvidence
    }

    public var validationError: MissionConstitutionValidationError? {
        guard revision > 0 else { return .invalidRevision }
        guard productGoal.hasMissionContent else { return .missingProductGoal }
        guard projectType.hasMissionContent else { return .missingProjectType }

        let textFields = [
            designIntent,
            orientationTarget,
            performanceTarget,
            accessibilityTarget,
            persistenceExpectations,
        ]
        if textFields.contains(where: { value in
            guard let value else { return false }
            return !value.hasMissionContent
        }) {
            return .blankOptionalField
        }

        let sets = [
            deviceTargets.values,
            requiredCapabilities.values,
            explicitNonGoals.values,
            constraints.values,
            acceptanceJourneys.values,
        ]
        if sets.joined().contains(where: { !$0.hasMissionContent }) {
            return .blankSetValue
        }
        return nil
    }
}

public enum MissionConstitutionValidationError: String, Error, Codable, Equatable, Sendable {
    case invalidRevision
    case missingProductGoal
    case missingProjectType
    case blankOptionalField
    case blankSetValue
}

private extension String {
    var hasMissionContent: Bool {
        !trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension Array where Element == String {
    func binarySearchMissionValue(_ value: String) -> Bool {
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
