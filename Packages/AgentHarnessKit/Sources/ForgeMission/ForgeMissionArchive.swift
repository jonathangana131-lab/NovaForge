import AgentDomain
import Foundation

public struct ForgeMissionArchive: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public let schemaVersion: Int
  public let state: ForgeMissionState

  public init(state: ForgeMissionState) throws {
    try Self.validate(state)
    schemaVersion = Self.currentSchemaVersion
    self.state = state
  }

  private enum CodingKeys: String, CodingKey { case schemaVersion, state }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw ForgeMissionError.unsupportedArchiveVersion(version)
    }
    let state = try container.decode(ForgeMissionState.self, forKey: .state)
    try Self.validate(state)
    self.schemaVersion = version
    self.state = state
  }

  public func encode(to encoder: Encoder) throws {
    try Self.validate(state)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(state, forKey: .state)
  }

  public static func decode(_ data: Data, expectedProjectID: ProjectID) throws
    -> ForgeMissionArchive
  {
    let archive = try JSONDecoder().decode(ForgeMissionArchive.self, from: data)
    guard archive.state.projectID == expectedProjectID else { throw ForgeMissionError.wrongProject }
    try validate(archive.state)
    return archive
  }

  public static func validate(_ state: ForgeMissionState) throws {
    guard state.constitution.missionID == state.missionID,
      state.constitution.projectID == state.projectID,
      state.graph.missionID == state.missionID
    else { throw ForgeMissionError.constitutionMismatch }
    guard state.constitution.validationError == nil else {
      throw ForgeMissionError.invalidConstitution
    }
    guard state.graph.validationError == nil else { throw ForgeMissionError.invalidGraph }
    var seenCheckpointIDs = Set<ForgeMissionCheckpointID>()
    var previousCheckpointRevision: UInt64 = 0
    for checkpoint in state.checkpoints {
      guard checkpoint.missionID == state.missionID else { throw ForgeMissionError.wrongMission }
      guard checkpoint.projectID == state.projectID else { throw ForgeMissionError.wrongProject }
      guard checkpoint.graph.missionID == state.missionID, checkpoint.graph.validationError == nil else {
        throw ForgeMissionError.invalidGraph
      }
      guard seenCheckpointIDs.insert(checkpoint.id).inserted else {
        throw ForgeMissionError.invalidCheckpointLineage
      }
      if let parentID = checkpoint.parentID, !seenCheckpointIDs.contains(parentID) {
        throw ForgeMissionError.invalidCheckpointLineage
      }
      guard checkpoint.missionRevision > previousCheckpointRevision,
        checkpoint.missionRevision <= state.revision,
        checkpoint.constitutionRevision <= state.constitution.revision
      else {
        throw ForgeMissionError.invalidCheckpointLineage
      }
      let checkpointStageIDs = Set(checkpoint.graph.stages.map(\.stageID))
      guard checkpoint.decisions.allSatisfy({ checkpointStageIDs.contains($0.stageID) }),
        checkpoint.workerReceipts.allSatisfy({ checkpointStageIDs.contains($0.stageID) })
      else {
        throw ForgeMissionError.invalidCheckpointLineage
      }
      previousCheckpointRevision = checkpoint.missionRevision
    }
    if let activeCheckpointID = state.activeCheckpointID, !seenCheckpointIDs.contains(activeCheckpointID) {
      throw ForgeMissionError.invalidCheckpointLineage
    }
    if state.phase == .completedWithEvidence || state.phase == .completedWithKnownLimitations {
      guard state.graph.requiredWorkIsSatisfied else { throw ForgeMissionError.invalidGraph }
    }
    if state.phase == .completedWithEvidence {
      guard let evidence = state.completionEvidence else {
        throw ForgeMissionError.completionEvidenceMissing(
          state.constitution.expectedEvidence.values)
      }
      let missing = state.constitution.expectedEvidence.values.filter { !evidence.contains($0) }
      guard missing.isEmpty else { throw ForgeMissionError.completionEvidenceMissing(missing) }
      guard state.knownLimitations.isEmpty else { throw ForgeMissionError.knownLimitationsRequired }
    }
    if state.phase == .completedWithKnownLimitations {
      guard state.completionEvidence != nil, !state.knownLimitations.isEmpty else {
        throw ForgeMissionError.knownLimitationsRequired
      }
    }
    if state.phase == .needsDecision {
      guard let pending = state.pendingDecision,
        state.graph.stages.contains(where: {
          $0.stageID == pending.stageID && $0.status == .waitingForDecision
        })
      else {
        throw ForgeMissionError.decisionRequired
      }
    } else if state.pendingDecision != nil {
      throw ForgeMissionError.decisionRequired
    }
  }
}
