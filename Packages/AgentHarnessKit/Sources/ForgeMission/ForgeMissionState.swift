import AgentDomain
import Foundation

public struct ForgeMissionState: Codable, Equatable, Sendable {
  public let missionID: MissionID
  public let projectID: ProjectID
  public private(set) var constitution: MissionConstitution
  public private(set) var graph: MissionStageGraph
  public private(set) var phase: MissionPhase
  public private(set) var acceptedRouteDescriptorID: AcceptedRouteDescriptorID
  public private(set) var pendingDecision: MissionPendingDecision?
  public private(set) var decisions: [MissionAcceptedDecision]
  public private(set) var workerReceipts: [MissionWorkerReceipt]
  public private(set) var checkpoints: [ForgeMissionCheckpoint]
  public private(set) var activeCheckpointID: ForgeMissionCheckpointID?
  public private(set) var completionEvidence: MissionEvidenceSet?
  public private(set) var knownLimitations: [String]
  public private(set) var revision: UInt64

  public init(
    constitution: MissionConstitution,
    graph: MissionStageGraph,
    acceptedRouteDescriptorID: AcceptedRouteDescriptorID
  ) throws {
    guard constitution.validationError == nil else { throw ForgeMissionError.invalidConstitution }
    guard graph.validationError == nil else { throw ForgeMissionError.invalidGraph }
    guard constitution.missionID == graph.missionID else {
      throw ForgeMissionError.constitutionMismatch
    }
    self.missionID = constitution.missionID
    self.projectID = constitution.projectID
    self.constitution = constitution
    self.graph = graph
    self.phase = .planning
    self.acceptedRouteDescriptorID = acceptedRouteDescriptorID
    self.pendingDecision = nil
    self.decisions = []
    self.workerReceipts = []
    self.checkpoints = []
    self.activeCheckpointID = nil
    self.completionEvidence = nil
    self.knownLimitations = []
    self.revision = 1
  }

  public mutating func start(maxParallelStages: Int = 1) throws {
    try requirePhase([.planning, .ready])
    if graph.requiredWorkIsSatisfied {
      phase = .validating
    } else {
      phase = .executing
      try activateReadyStages(limit: maxParallelStages)
    }
    bumpRevision()
  }

  public mutating func pauseByUser() throws {
    try requirePhase([.executing, .validating, .polishing])
    phase = .pausedByUser
    bumpRevision()
  }

  public mutating func resume(maxParallelStages: Int = 1) throws {
    try requirePhase([.pausedByUser, .pausedByPolicy, .interruptedRecoverable])
    phase = .executing
    try activateReadyStages(limit: maxParallelStages)
    bumpRevision()
  }

  public mutating func cancel() throws {
    guard !phase.isTerminal else { throw ForgeMissionError.terminalMutation }
    phase = .cancelled
    pendingDecision = nil
    completionEvidence = nil
    knownLimitations = []
    bumpRevision()
  }

  public mutating func switchAcceptedRoute(to route: AcceptedRouteDescriptorID) {
    guard route != acceptedRouteDescriptorID else { return }
    acceptedRouteDescriptorID = route
    bumpRevision()
  }

  public func makeWorkLease(for stageID: MissionStageID, attemptID: AttemptID = AttemptID()) throws
    -> MissionWorkLease
  {
    try requirePhase([.executing, .validating, .polishing])
    guard let stage = graph.stages.first(where: { $0.stageID == stageID }) else {
      throw ForgeMissionError.stageNotFound
    }
    guard stage.status == .active else { throw ForgeMissionError.stageNotActive }
    return MissionWorkLease(
      attemptID: attemptID,
      missionID: missionID,
      projectID: projectID,
      stageID: stageID,
      missionRevision: revision,
      graphRevision: graph.revision,
      checkpointID: activeCheckpointID,
      acceptedRouteDescriptorID: acceptedRouteDescriptorID
    )
  }

  public mutating func acceptWorkerResult(
    lease: MissionWorkLease,
    outcome: MissionWorkerOutcome,
    at acceptedAt: AgentInstant,
    maxParallelStages: Int = 1
  ) throws {
    try validate(lease)
    let receipt: MissionWorkerReceipt
    switch outcome {
    case .completed(let evidenceSummary):
      let summary = try requireWorkerSummary(evidenceSummary)
      receipt = makeWorkerReceipt(
        lease: lease, kind: .completed, summary: summary, at: acceptedAt)
      try setStage(lease.stageID, status: .completed)
      pendingDecision = nil
      if graph.requiredWorkIsSatisfied {
        phase = .validating
      } else {
        phase = .executing
        try activateReadyStages(limit: maxParallelStages)
      }
    case .blockedExternal(let summary):
      let summary = try requireWorkerSummary(summary)
      receipt = makeWorkerReceipt(
        lease: lease, kind: .blockedExternal, summary: summary, at: acceptedAt)
      try setStage(lease.stageID, status: .blocked)
      pendingDecision = nil
      phase = .blockedExternal
    case .needsDecision(let prompt, let allowsDelegation):
      let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { throw ForgeMissionError.blankDecision }
      receipt = makeWorkerReceipt(
        lease: lease, kind: .needsDecision, summary: value, at: acceptedAt)
      try setStage(lease.stageID, status: .waitingForDecision)
      pendingDecision = MissionPendingDecision(
        stageID: lease.stageID, prompt: value, allowsDelegation: allowsDelegation)
      phase = .needsDecision
    case .failedRecoverably(let summary):
      let summary = try requireWorkerSummary(summary)
      receipt = makeWorkerReceipt(
        lease: lease, kind: .failedRecoverably, summary: summary, at: acceptedAt)
      try setStage(lease.stageID, status: .failedRecoverably)
      pendingDecision = nil
      phase = .interruptedRecoverable
    }
    workerReceipts.append(receipt)
    bumpRevision()
  }

  public mutating func retryExternalBlocker(stageID: MissionStageID, maxParallelStages: Int = 1)
    throws
  {
    try requirePhase([.blockedExternal, .interruptedRecoverable])
    guard let stage = graph.stages.first(where: { $0.stageID == stageID }) else {
      throw ForgeMissionError.stageNotFound
    }
    guard stage.status == .blocked || stage.status == .failedRecoverably else {
      throw ForgeMissionError.stageNotBlocked
    }
    try setStage(stageID, status: .pending)
    phase = .executing
    try activateReadyStages(limit: maxParallelStages)
    bumpRevision()
  }

  public mutating func acceptDecision(
    answer: String?,
    decideForMe: Bool = false,
    at acceptedAt: AgentInstant,
    maxParallelStages: Int = 1
  ) throws {
    try requirePhase([.needsDecision])
    guard let pendingDecision else { throw ForgeMissionError.decisionRequired }
    if decideForMe && !pendingDecision.allowsDelegation {
      throw ForgeMissionError.decisionDelegationNotAllowed
    }
    let normalized = answer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard decideForMe || !normalized.isEmpty else { throw ForgeMissionError.blankDecision }
    let acceptedAnswer = decideForMe ? "DECIDE_FOR_ME" : normalized
    decisions.append(
      MissionAcceptedDecision(
        id: UUID(),
        stageID: pendingDecision.stageID,
        answer: acceptedAnswer,
        delegatedToNovaForge: decideForMe,
        acceptedAt: acceptedAt
      )
    )
    self.pendingDecision = nil
    try setStage(pendingDecision.stageID, status: .pending)
    phase = .executing
    try activateReadyStages(limit: maxParallelStages)
    bumpRevision()
  }

  public mutating func deferOptionalStage(_ stageID: MissionStageID, maxParallelStages: Int = 1)
    throws
  {
    guard !phase.isTerminal else { throw ForgeMissionError.terminalMutation }
    guard let stage = graph.stages.first(where: { $0.stageID == stageID }) else {
      throw ForgeMissionError.stageNotFound
    }
    guard !stage.required else { throw ForgeMissionError.requiredStageCannotBeDeferred }
    try setStage(stageID, status: .deferred)
    if pendingDecision?.stageID == stageID { pendingDecision = nil }
    if phase == .needsDecision || phase == .blockedExternal { phase = .executing }
    try activateReadyStages(limit: maxParallelStages)
    bumpRevision()
  }

  public mutating func appendStages(_ stages: [MissionStage], maxParallelStages: Int = 1) throws {
    guard !stages.isEmpty else { return }
    if phase == .cancelled || phase == .failedIrrecoverably {
      throw ForgeMissionError.terminalMutation
    }
    let wasCompleted = phase == .completedWithEvidence || phase == .completedWithKnownLimitations
    let nextRevision = graph.revision &+ 1
    let normalizedStages = stages.map { stage in
      MissionStage(
        stageID: stage.stageID,
        kind: stage.kind,
        title: stage.title,
        order: stage.order,
        required: stage.required,
        dependencies: stage.dependencies,
        status: .pending
      )
    }
    let candidate = MissionStageGraph(
      missionID: missionID, revision: nextRevision, stages: graph.stages + normalizedStages)
    guard candidate.validationError == nil else { throw ForgeMissionError.invalidGraph }
    graph = candidate
    if wasCompleted {
      phase = .executing
      completionEvidence = nil
      knownLimitations = []
    }
    if phase == .executing { try activateReadyStages(limit: maxParallelStages) }
    bumpRevision()
  }

  public mutating func finalizeCompletion(
    observedEvidence: Set<MissionEvidenceClass>,
    knownLimitations: [String] = []
  ) throws {
    try requirePhase([.validating, .polishing])
    guard graph.requiredWorkIsSatisfied else { throw ForgeMissionError.invalidGraph }
    let missing = constitution.expectedEvidence.values.filter { !observedEvidence.contains($0) }
    let normalizedLimitations =
      knownLimitations
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if missing.isEmpty {
      phase = .completedWithEvidence
      self.knownLimitations = []
    } else {
      guard !normalizedLimitations.isEmpty else {
        throw ForgeMissionError.completionEvidenceMissing(missing)
      }
      phase = .completedWithKnownLimitations
      self.knownLimitations = normalizedLimitations
    }
    completionEvidence = MissionEvidenceSet(observedEvidence)
    bumpRevision()
  }

  @discardableResult
  public mutating func checkpoint(
    acceptedProjectStateID: AcceptedProjectStateID,
    evidenceReceiptIDs: [MissionEvidenceReceiptID],
    summary: String,
    at acceptedAt: AgentInstant
  ) -> ForgeMissionCheckpoint {
    bumpRevision()
    let checkpoint = ForgeMissionCheckpoint(
      id: ForgeMissionCheckpointID(),
      parentID: activeCheckpointID,
      missionID: missionID,
      projectID: projectID,
      missionRevision: revision,
      constitutionRevision: constitution.revision,
      acceptedAt: acceptedAt,
      phase: phase,
      graph: graph,
      acceptedRouteDescriptorID: acceptedRouteDescriptorID,
      acceptedProjectStateID: acceptedProjectStateID,
      evidenceReceiptIDs: Array(Set(evidenceReceiptIDs)).sorted { $0.rawValue < $1.rawValue },
      summary: summary,
      decisions: decisions,
      workerReceipts: workerReceipts
    )
    checkpoints.append(checkpoint)
    activeCheckpointID = checkpoint.id
    return checkpoint
  }

  public func prepareRestore(to checkpointID: ForgeMissionCheckpointID) throws
    -> MissionRestoreRequest
  {
    guard let checkpoint = checkpoints.first(where: { $0.id == checkpointID }) else {
      throw ForgeMissionError.checkpointNotFound
    }
    return MissionRestoreRequest(
      checkpointID: checkpoint.id,
      missionID: missionID,
      projectID: projectID,
      acceptedProjectStateID: checkpoint.acceptedProjectStateID,
      evidenceReceiptIDs: checkpoint.evidenceReceiptIDs
    )
  }

  public mutating func acceptVerifiedRestore(
    _ request: MissionRestoreRequest, verifiedProjectStateID: AcceptedProjectStateID
  ) throws {
    guard request.missionID == missionID else { throw ForgeMissionError.wrongMission }
    guard request.projectID == projectID else { throw ForgeMissionError.wrongProject }
    guard request.acceptedProjectStateID == verifiedProjectStateID else {
      throw ForgeMissionError.restoreReceiptMismatch
    }
    guard let checkpoint = checkpoints.first(where: { $0.id == request.checkpointID }) else {
      throw ForgeMissionError.checkpointNotFound
    }
    guard request.evidenceReceiptIDs == checkpoint.evidenceReceiptIDs else {
      throw ForgeMissionError.restoreReceiptMismatch
    }
    guard checkpoint.acceptedProjectStateID == verifiedProjectStateID else {
      throw ForgeMissionError.restoreReceiptMismatch
    }
    graph = checkpoint.graph
    acceptedRouteDescriptorID = checkpoint.acceptedRouteDescriptorID
    pendingDecision = nil
    decisions = checkpoint.decisions
    workerReceipts = checkpoint.workerReceipts
    activeCheckpointID = checkpoint.id
    completionEvidence = nil
    knownLimitations = []
    phase = .pausedByUser
    bumpRevision()
  }

  private mutating func activateReadyStages(limit: Int) throws {
    guard limit > 0 else { return }
    var statuses = Dictionary(uniqueKeysWithValues: graph.stages.map { ($0.stageID, $0.status) })
    let settled: Set<MissionStageID> = Set(
      graph.stages.filter { $0.status == .completed || $0.status == .deferred }.map(\.stageID))
    let alreadyActive = graph.stages.filter { $0.status == .active }.count
    var remaining = max(0, limit - alreadyActive)
    for stage in graph.stages where remaining > 0 && stage.status == .pending {
      if stage.dependencies.allSatisfy({ settled.contains($0) }) {
        statuses[stage.stageID] = .active
        remaining -= 1
      }
    }
    try rebuildGraph(statuses: statuses)
  }

  private mutating func setStage(_ stageID: MissionStageID, status: MissionStageStatus) throws {
    guard graph.stages.contains(where: { $0.stageID == stageID }) else {
      throw ForgeMissionError.stageNotFound
    }
    var statuses = Dictionary(uniqueKeysWithValues: graph.stages.map { ($0.stageID, $0.status) })
    statuses[stageID] = status
    try rebuildGraph(statuses: statuses)
  }

  private mutating func rebuildGraph(statuses: [MissionStageID: MissionStageStatus]) throws {
    let next = graph.stages.map { stage in
      MissionStage(
        stageID: stage.stageID,
        kind: stage.kind,
        title: stage.title,
        order: stage.order,
        required: stage.required,
        dependencies: stage.dependencies,
        status: statuses[stage.stageID] ?? stage.status
      )
    }
    let candidate = MissionStageGraph(
      missionID: missionID, revision: graph.revision &+ 1, stages: next)
    guard candidate.validationError == nil else { throw ForgeMissionError.invalidGraph }
    graph = candidate
  }

  private func validate(_ lease: MissionWorkLease) throws {
    guard lease.missionID == missionID else { throw ForgeMissionError.wrongMission }
    guard lease.projectID == projectID else { throw ForgeMissionError.wrongProject }
    guard lease.missionRevision == revision, lease.graphRevision == graph.revision,
      lease.checkpointID == activeCheckpointID
    else {
      throw ForgeMissionError.staleWorkerResult
    }
    guard lease.acceptedRouteDescriptorID == acceptedRouteDescriptorID else {
      throw ForgeMissionError.staleRoute
    }
    guard let stage = graph.stages.first(where: { $0.stageID == lease.stageID }) else {
      throw ForgeMissionError.stageNotFound
    }
    guard stage.status == .active else { throw ForgeMissionError.stageNotActive }
  }

  private func makeWorkerReceipt(
    lease: MissionWorkLease,
    kind: MissionWorkerReceiptKind,
    summary: String,
    at acceptedAt: AgentInstant
  ) -> MissionWorkerReceipt {
    MissionWorkerReceipt(
      id: UUID(),
      attemptID: lease.attemptID,
      stageID: lease.stageID,
      kind: kind,
      summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
      acceptedAt: acceptedAt
    )
  }

  private func requireWorkerSummary(_ summary: String) throws -> String {
    let value = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw ForgeMissionError.blankWorkerSummary }
    return value
  }

  private func requirePhase(_ expected: [MissionPhase]) throws {
    guard expected.contains(phase) else {
      throw ForgeMissionError.invalidPhase(expected: expected, actual: phase)
    }
  }

  private mutating func bumpRevision() { revision &+= 1 }
}
