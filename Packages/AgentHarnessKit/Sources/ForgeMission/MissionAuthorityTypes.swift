import AgentDomain
import Foundation

public struct AcceptedRouteDescriptorID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String
  public init?(rawValue: String) {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    self.rawValue = value
  }
}

public struct AcceptedProjectStateID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String
  public init?(rawValue: String) {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    self.rawValue = value
  }
}

public struct MissionEvidenceReceiptID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String
  public init?(rawValue: String) {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    self.rawValue = value
  }
}

public struct ForgeMissionCheckpointID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
  public init() { rawValue = UUID() }
}

public enum MissionWorkerOutcome: Equatable, Sendable {
  case completed(evidenceSummary: String)
  case blockedExternal(summary: String)
  case needsDecision(prompt: String, allowsDelegation: Bool)
  case failedRecoverably(summary: String)
}

public enum MissionWorkerReceiptKind: String, Codable, Equatable, Sendable {
  case completed
  case blockedExternal
  case needsDecision
  case failedRecoverably
}

public struct MissionWorkerReceipt: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let attemptID: AttemptID
  public let stageID: MissionStageID
  public let kind: MissionWorkerReceiptKind
  public let summary: String
  public let acceptedAt: AgentInstant
}

public struct MissionWorkLease: Codable, Equatable, Sendable {
  public let attemptID: AttemptID
  public let missionID: MissionID
  public let projectID: ProjectID
  public let stageID: MissionStageID
  public let missionRevision: UInt64
  public let graphRevision: UInt64
  public let checkpointID: ForgeMissionCheckpointID?
  public let acceptedRouteDescriptorID: AcceptedRouteDescriptorID
}

public struct MissionAcceptedDecision: Codable, Equatable, Sendable, Identifiable {
  public let id: UUID
  public let stageID: MissionStageID
  public let answer: String
  public let delegatedToNovaForge: Bool
  public let acceptedAt: AgentInstant
}

public struct MissionPendingDecision: Codable, Equatable, Sendable {
  public let stageID: MissionStageID
  public let prompt: String
  public let allowsDelegation: Bool
}

public struct ForgeMissionCheckpoint: Codable, Equatable, Sendable, Identifiable {
  public let id: ForgeMissionCheckpointID
  public let parentID: ForgeMissionCheckpointID?
  public let missionID: MissionID
  public let projectID: ProjectID
  public let missionRevision: UInt64
  public let constitutionRevision: UInt64
  public let acceptedAt: AgentInstant
  public let phase: MissionPhase
  public let graph: MissionStageGraph
  public let acceptedRouteDescriptorID: AcceptedRouteDescriptorID
  public let acceptedProjectStateID: AcceptedProjectStateID
  public let evidenceReceiptIDs: [MissionEvidenceReceiptID]
  public let summary: String
  public let decisions: [MissionAcceptedDecision]
  public let workerReceipts: [MissionWorkerReceipt]
}

public struct MissionRestoreRequest: Codable, Equatable, Sendable {
  public let checkpointID: ForgeMissionCheckpointID
  public let missionID: MissionID
  public let projectID: ProjectID
  public let acceptedProjectStateID: AcceptedProjectStateID
  public let evidenceReceiptIDs: [MissionEvidenceReceiptID]
}

public enum ForgeMissionError: Error, Equatable, Sendable {
  case constitutionMismatch
  case invalidConstitution
  case invalidGraph
  case invalidPhase(expected: [MissionPhase], actual: MissionPhase)
  case stageNotFound
  case stageNotActive
  case stageNotBlocked
  case decisionRequired
  case decisionDelegationNotAllowed
  case blankDecision
  case blankWorkerSummary
  case staleWorkerResult
  case wrongMission
  case wrongProject
  case staleRoute
  case checkpointNotFound
  case restoreReceiptMismatch
  case terminalMutation
  case requiredStageCannotBeDeferred
  case completionEvidenceMissing([MissionEvidenceClass])
  case knownLimitationsRequired
  case unsupportedArchiveVersion(Int)
  case invalidCheckpointLineage
}
