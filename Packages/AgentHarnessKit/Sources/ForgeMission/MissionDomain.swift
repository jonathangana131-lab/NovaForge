import AgentDomain
import Foundation
import ProjectBrain

public enum MissionIDTag: AgentIdentifierTag {}
public enum MissionStageIDTag: AgentIdentifierTag {}
public enum MissionCheckpointIDTag: AgentIdentifierTag {}
public enum MissionWorkerLeaseIDTag: AgentIdentifierTag {}

public typealias MissionID = AgentIdentifier<MissionIDTag>
public typealias MissionStageID = AgentIdentifier<MissionStageIDTag>
public typealias MissionCheckpointID = AgentIdentifier<MissionCheckpointIDTag>
public typealias MissionWorkerLeaseID = AgentIdentifier<MissionWorkerLeaseIDTag>

public struct MissionRevision: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public static let initial = MissionRevision(rawValue: 0)
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

public enum MissionStatus: String, Codable, Hashable, Sendable {
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
}

public enum MissionBuildDepth: String, Codable, Hashable, Sendable {
    case prototype
    case polished
    case obsessive
}

public enum MissionPrivacyMode: String, Codable, Hashable, Sendable {
    case localOnly
    case hybrid
    case hostedAllowed
}

public struct MissionConstitution: Codable, Hashable, Sendable {
    public let productGoal: String
    public let projectType: String
    public let designIntent: String
    public let targetDevices: [String]
    public let orientationPolicy: String
    public let requiredCapabilities: [String]
    public let explicitNonGoals: [String]
    public let buildDepth: MissionBuildDepth
    public let privacyMode: MissionPrivacyMode
    public let performanceTarget: String
    public let accessibilityTarget: String
    public let persistenceExpectations: String
    public let acceptanceJourneys: [String]
    public let expectedEvidenceClasses: [String]

    public init(
        productGoal: String,
        projectType: String,
        designIntent: String,
        targetDevices: [String],
        orientationPolicy: String,
        requiredCapabilities: [String],
        explicitNonGoals: [String],
        buildDepth: MissionBuildDepth,
        privacyMode: MissionPrivacyMode,
        performanceTarget: String,
        accessibilityTarget: String,
        persistenceExpectations: String,
        acceptanceJourneys: [String],
        expectedEvidenceClasses: [String]
    ) {
        self.productGoal = productGoal
        self.projectType = projectType
        self.designIntent = designIntent
        self.targetDevices = targetDevices
        self.orientationPolicy = orientationPolicy
        self.requiredCapabilities = requiredCapabilities
        self.explicitNonGoals = explicitNonGoals
        self.buildDepth = buildDepth
        self.privacyMode = privacyMode
        self.performanceTarget = performanceTarget
        self.accessibilityTarget = accessibilityTarget
        self.persistenceExpectations = persistenceExpectations
        self.acceptanceJourneys = acceptanceJourneys
        self.expectedEvidenceClasses = expectedEvidenceClasses
    }
}

public enum MissionStageKind: String, Codable, Hashable, Sendable {
    case understand
    case decide
    case design
    case implement
    case run
    case observe
    case diagnose
    case repair
    case test
    case visualCritique
    case accessibility
    case performance
    case polish
    case checkpoint
    case custom
}

public enum MissionStageState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case waitingForDecision
    case waitingForApproval
    case blocked
    case completed
    case skipped
    case failedRecoverable
    case failedTerminal
}

public struct MissionStage: Codable, Hashable, Sendable {
    public let id: MissionStageID
    public let title: String
    public let kind: MissionStageKind
    public let dependencyIDs: [MissionStageID]
    public let isOptional: Bool
    public let state: MissionStageState
    public let attempt: UInt32
    public let workerLeaseID: MissionWorkerLeaseID?
    public let acceptedSummary: String?
    public let acceptedEvidenceIDs: [String]

    public init(
        id: MissionStageID = MissionStageID(),
        title: String,
        kind: MissionStageKind,
        dependencyIDs: [MissionStageID] = [],
        isOptional: Bool = false,
        state: MissionStageState = .queued,
        attempt: UInt32 = 0,
        workerLeaseID: MissionWorkerLeaseID? = nil,
        acceptedSummary: String? = nil,
        acceptedEvidenceIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.dependencyIDs = dependencyIDs
        self.isOptional = isOptional
        self.state = state
        self.attempt = attempt
        self.workerLeaseID = workerLeaseID
        self.acceptedSummary = acceptedSummary
        self.acceptedEvidenceIDs = acceptedEvidenceIDs
    }

    func replacing(
        state: MissionStageState? = nil,
        attempt: UInt32? = nil,
        workerLeaseID: MissionWorkerLeaseID?? = nil,
        acceptedSummary: String?? = nil,
        acceptedEvidenceIDs: [String]? = nil
    ) -> Self {
        Self(
            id: id,
            title: title,
            kind: kind,
            dependencyIDs: dependencyIDs,
            isOptional: isOptional,
            state: state ?? self.state,
            attempt: attempt ?? self.attempt,
            workerLeaseID: workerLeaseID ?? self.workerLeaseID,
            acceptedSummary: acceptedSummary ?? self.acceptedSummary,
            acceptedEvidenceIDs: acceptedEvidenceIDs ?? self.acceptedEvidenceIDs
        )
    }
}

/// A reference to an already accepted provider/runtime route. This is not a support authority.
/// ProviderRuntime remains responsible for minting and validating the referenced descriptor.
public struct MissionWorkerSelection: Codable, Hashable, Sendable {
    public let providerID: String
    public let modelID: String
    public let acceptedRouteDescriptorID: String
    public let executionEnvironment: String

    public init(
        providerID: String,
        modelID: String,
        acceptedRouteDescriptorID: String,
        executionEnvironment: String
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.acceptedRouteDescriptorID = acceptedRouteDescriptorID
        self.executionEnvironment = executionEnvironment
    }
}

public struct MissionWorkToken: Codable, Hashable, Sendable {
    public let missionID: MissionID
    public let projectID: ProjectID
    public let stageID: MissionStageID
    public let attempt: UInt32
    public let workerLeaseID: MissionWorkerLeaseID

    public init(
        missionID: MissionID,
        projectID: ProjectID,
        stageID: MissionStageID,
        attempt: UInt32,
        workerLeaseID: MissionWorkerLeaseID
    ) {
        self.missionID = missionID
        self.projectID = projectID
        self.stageID = stageID
        self.attempt = attempt
        self.workerLeaseID = workerLeaseID
    }
}

/// A bounded acceptance candidate from a worker. `summary` is a concise durable work summary,
/// never hidden chain-of-thought. The reducer still requires a live work lease before acceptance.
public struct MissionWorkerResult: Codable, Hashable, Sendable {
    public let summary: String
    public let evidenceIDs: [String]

    public init(summary: String, evidenceIDs: [String]) {
        self.summary = summary
        self.evidenceIDs = evidenceIDs
    }
}

public struct MissionSnapshot: Codable, Hashable, Sendable {
    public let missionID: MissionID
    public let projectID: ProjectID
    public let constitution: MissionConstitution
    public let status: MissionStatus
    public let stages: [MissionStage]
    public let activeStageID: MissionStageID?
    public let workerSelection: MissionWorkerSelection?
    public let brain: ProjectBrainSnapshot
    public let latestCheckpointID: MissionCheckpointID?
    public let revision: MissionRevision
    public let createdAt: AgentInstant
    public let updatedAt: AgentInstant

    public init(
        missionID: MissionID,
        projectID: ProjectID,
        constitution: MissionConstitution,
        status: MissionStatus,
        stages: [MissionStage],
        activeStageID: MissionStageID?,
        workerSelection: MissionWorkerSelection?,
        brain: ProjectBrainSnapshot,
        latestCheckpointID: MissionCheckpointID?,
        revision: MissionRevision,
        createdAt: AgentInstant,
        updatedAt: AgentInstant
    ) {
        self.missionID = missionID
        self.projectID = projectID
        self.constitution = constitution
        self.status = status
        self.stages = stages
        self.activeStageID = activeStageID
        self.workerSelection = workerSelection
        self.brain = brain
        self.latestCheckpointID = latestCheckpointID
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct MissionCheckpoint: Codable, Hashable, Sendable {
    public let id: MissionCheckpointID
    public let parentID: MissionCheckpointID?
    public let snapshot: MissionSnapshot
    public let acceptedProjectStateID: String
    public let evidenceIDs: [String]
    public let createdAt: AgentInstant

    public init(
        id: MissionCheckpointID,
        parentID: MissionCheckpointID?,
        snapshot: MissionSnapshot,
        acceptedProjectStateID: String,
        evidenceIDs: [String],
        createdAt: AgentInstant
    ) {
        self.id = id
        self.parentID = parentID
        self.snapshot = snapshot
        self.acceptedProjectStateID = acceptedProjectStateID
        self.evidenceIDs = evidenceIDs
        self.createdAt = createdAt
    }
}
