import Foundation

public enum MissionIDTag: AgentIdentifierTag {}
public enum MissionStageIDTag: AgentIdentifierTag {}

public typealias MissionID = AgentIdentifier<MissionIDTag>
public typealias MissionStageID = AgentIdentifier<MissionStageIDTag>

// MARK: - Mission identity and constitution

public enum MissionLifecycleState: String, Codable, CaseIterable, Hashable, Sendable {
    case draftIntent
    case planning
    case needsDecision
    case ready
    case executing
    case pausedByUser
    case pausedByPolicy
    case blockedExternal
    case interruptedRecoverable
    case validating
    case polishing
    case completedWithEvidence
    case completedWithKnownLimitations
    case cancelled
    case failedIrrecoverably

    public var isTerminal: Bool {
        switch self {
        case .completedWithEvidence, .completedWithKnownLimitations, .cancelled, .failedIrrecoverably:
            true
        default:
            false
        }
    }

    public var isCompletion: Bool {
        self == .completedWithEvidence || self == .completedWithKnownLimitations
    }

    public func canTransition(to next: Self) -> Bool {
        guard self != next else { return true }

        switch self {
        case .draftIntent:
            return [.planning, .cancelled].contains(next)
        case .planning:
            return [.needsDecision, .ready, .cancelled, .failedIrrecoverably].contains(next)
        case .needsDecision:
            return [.planning, .ready, .cancelled].contains(next)
        case .ready:
            return [.executing, .pausedByUser, .cancelled].contains(next)
        case .executing:
            return [
                .pausedByUser,
                .pausedByPolicy,
                .blockedExternal,
                .interruptedRecoverable,
                .validating,
                .polishing,
                .completedWithEvidence,
                .completedWithKnownLimitations,
                .cancelled,
                .failedIrrecoverably,
            ].contains(next)
        case .pausedByUser:
            return [.ready, .executing, .cancelled].contains(next)
        case .pausedByPolicy:
            return [.ready, .executing, .cancelled, .failedIrrecoverably].contains(next)
        case .blockedExternal:
            return [.ready, .executing, .cancelled, .failedIrrecoverably].contains(next)
        case .interruptedRecoverable:
            return [.ready, .executing, .cancelled, .failedIrrecoverably].contains(next)
        case .validating:
            return [
                .executing,
                .pausedByUser,
                .pausedByPolicy,
                .blockedExternal,
                .interruptedRecoverable,
                .polishing,
                .completedWithEvidence,
                .completedWithKnownLimitations,
                .cancelled,
                .failedIrrecoverably,
            ].contains(next)
        case .polishing:
            return [
                .executing,
                .validating,
                .pausedByUser,
                .pausedByPolicy,
                .blockedExternal,
                .interruptedRecoverable,
                .completedWithEvidence,
                .completedWithKnownLimitations,
                .cancelled,
                .failedIrrecoverably,
            ].contains(next)
        case .completedWithEvidence, .completedWithKnownLimitations, .cancelled, .failedIrrecoverably:
            return false
        }
    }
}

public enum MissionProjectKind: String, Codable, CaseIterable, Hashable, Sendable {
    case app
    case game2D
    case game3D
    case webExperience
    case nativeSwiftProject
    case other
}

public enum MissionOrientationTarget: String, Codable, CaseIterable, Hashable, Sendable {
    case portrait
    case landscape
    case automatic
    case mixed
}

public enum MissionBuildDepth: String, Codable, CaseIterable, Hashable, Sendable {
    case prototype
    case polished
    case obsessive
}

public enum MissionCreativity: String, Codable, CaseIterable, Hashable, Sendable {
    case faithful
    case balanced
    case inventive
}

public enum MissionRefactorRisk: String, Codable, CaseIterable, Hashable, Sendable {
    case preserve
    case balanced
    case rebuild
}

public enum MissionLocalityPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case localOnly
    case hybrid
    case hostedAllowed
}

public enum MissionPersistenceExpectation: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case local
    case durable
}

public enum MissionEvidenceClass: String, Codable, CaseIterable, Hashable, Sendable {
    case sourceReview
    case tests
    case runtime
    case visual
    case accessibility
    case performance
    case simulator
    case physicalDevice
}

public struct MissionCapability: Codable, Hashable, Sendable {
    public let identifier: String
    public let displayName: String

    public init(identifier: String, displayName: String) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

/// The accepted, user-editable definition of done for a durable mission.
///
/// This intentionally contains no hidden reasoning. It stores only explicit product intent,
/// policy-relevant choices, and acceptance targets that can survive model/provider changes.
public struct MissionConstitution: Codable, Hashable, Sendable {
    public let productGoal: String
    public let projectKind: MissionProjectKind
    public let designIntent: String?
    public let orientationTarget: MissionOrientationTarget
    public let deviceTarget: String?
    public let requiredCapabilities: Set<MissionCapability>
    public let explicitNonGoals: [String]
    public let buildDepth: MissionBuildDepth
    public let creativity: MissionCreativity
    public let refactorRisk: MissionRefactorRisk
    public let localityPolicy: MissionLocalityPolicy
    public let performanceTarget: String?
    public let accessibilityTarget: String?
    public let persistenceExpectation: MissionPersistenceExpectation
    public let acceptanceJourneys: [String]
    public let expectedEvidence: Set<MissionEvidenceClass>

    public init(
        productGoal: String,
        projectKind: MissionProjectKind,
        designIntent: String? = nil,
        orientationTarget: MissionOrientationTarget = .automatic,
        deviceTarget: String? = nil,
        requiredCapabilities: Set<MissionCapability> = [],
        explicitNonGoals: [String] = [],
        buildDepth: MissionBuildDepth = .polished,
        creativity: MissionCreativity = .balanced,
        refactorRisk: MissionRefactorRisk = .balanced,
        localityPolicy: MissionLocalityPolicy = .hybrid,
        performanceTarget: String? = nil,
        accessibilityTarget: String? = nil,
        persistenceExpectation: MissionPersistenceExpectation = .durable,
        acceptanceJourneys: [String] = [],
        expectedEvidence: Set<MissionEvidenceClass> = [.tests, .runtime]
    ) {
        self.productGoal = productGoal
        self.projectKind = projectKind
        self.designIntent = designIntent
        self.orientationTarget = orientationTarget
        self.deviceTarget = deviceTarget
        self.requiredCapabilities = requiredCapabilities
        self.explicitNonGoals = explicitNonGoals
        self.buildDepth = buildDepth
        self.creativity = creativity
        self.refactorRisk = refactorRisk
        self.localityPolicy = localityPolicy
        self.performanceTarget = performanceTarget
        self.accessibilityTarget = accessibilityTarget
        self.persistenceExpectation = persistenceExpectation
        self.acceptanceJourneys = acceptanceJourneys
        self.expectedEvidence = expectedEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case productGoal
        case projectKind
        case designIntent
        case orientationTarget
        case deviceTarget
        case requiredCapabilities
        case explicitNonGoals
        case buildDepth
        case creativity
        case refactorRisk
        case localityPolicy
        case performanceTarget
        case accessibilityTarget
        case persistenceExpectation
        case acceptanceJourneys
        case expectedEvidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        productGoal = try container.decode(String.self, forKey: .productGoal)
        projectKind = try container.decode(MissionProjectKind.self, forKey: .projectKind)
        designIntent = try container.decodeIfPresent(String.self, forKey: .designIntent)
        orientationTarget = try container.decode(MissionOrientationTarget.self, forKey: .orientationTarget)
        deviceTarget = try container.decodeIfPresent(String.self, forKey: .deviceTarget)
        requiredCapabilities = Set(try container.decode([MissionCapability].self, forKey: .requiredCapabilities))
        explicitNonGoals = try container.decode([String].self, forKey: .explicitNonGoals)
        buildDepth = try container.decode(MissionBuildDepth.self, forKey: .buildDepth)
        creativity = try container.decode(MissionCreativity.self, forKey: .creativity)
        refactorRisk = try container.decode(MissionRefactorRisk.self, forKey: .refactorRisk)
        localityPolicy = try container.decode(MissionLocalityPolicy.self, forKey: .localityPolicy)
        performanceTarget = try container.decodeIfPresent(String.self, forKey: .performanceTarget)
        accessibilityTarget = try container.decodeIfPresent(String.self, forKey: .accessibilityTarget)
        persistenceExpectation = try container.decode(MissionPersistenceExpectation.self, forKey: .persistenceExpectation)
        acceptanceJourneys = try container.decode([String].self, forKey: .acceptanceJourneys)
        expectedEvidence = Set(try container.decode([MissionEvidenceClass].self, forKey: .expectedEvidence))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(productGoal, forKey: .productGoal)
        try container.encode(projectKind, forKey: .projectKind)
        try container.encodeIfPresent(designIntent, forKey: .designIntent)
        try container.encode(orientationTarget, forKey: .orientationTarget)
        try container.encodeIfPresent(deviceTarget, forKey: .deviceTarget)
        try container.encode(
            requiredCapabilities.sorted {
                if $0.identifier != $1.identifier { return $0.identifier < $1.identifier }
                return $0.displayName < $1.displayName
            },
            forKey: .requiredCapabilities
        )
        try container.encode(explicitNonGoals, forKey: .explicitNonGoals)
        try container.encode(buildDepth, forKey: .buildDepth)
        try container.encode(creativity, forKey: .creativity)
        try container.encode(refactorRisk, forKey: .refactorRisk)
        try container.encode(localityPolicy, forKey: .localityPolicy)
        try container.encodeIfPresent(performanceTarget, forKey: .performanceTarget)
        try container.encodeIfPresent(accessibilityTarget, forKey: .accessibilityTarget)
        try container.encode(persistenceExpectation, forKey: .persistenceExpectation)
        try container.encode(acceptanceJourneys, forKey: .acceptanceJourneys)
        try container.encode(expectedEvidence.sorted { $0.rawValue < $1.rawValue }, forKey: .expectedEvidence)
    }
}
