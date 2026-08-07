import AgentDomain
import XCTest

@testable import ForgeMission

final class ForgeMissionTests: XCTestCase {
  private let now = AgentInstant(rawValue: 1_800_000_000_000)

  func testStartActivatesDependencyReadyStageAndLeaseBindsProjectRouteRevision() throws {
    var state = try makeState()
    try state.start()
    let active = try XCTUnwrap(state.graph.activeStages.first)
    let lease = try state.makeWorkLease(for: active.stageID)
    XCTAssertEqual(lease.missionID, state.missionID)
    XCTAssertEqual(lease.projectID, state.projectID)
    XCTAssertEqual(lease.acceptedRouteDescriptorID, state.acceptedRouteDescriptorID)
    XCTAssertEqual(lease.missionRevision, state.revision)
    XCTAssertEqual(lease.graphRevision, state.graph.revision)
  }

  func testNeedsDecisionCannotResumeOrUseGenericRetry() throws {
    var state = try makeState()
    try state.start()
    let stage = try XCTUnwrap(state.graph.activeStages.first)
    let lease = try state.makeWorkLease(for: stage.stageID)
    try state.acceptWorkerResult(
      lease: lease,
      outcome: .needsDecision(prompt: "Choose camera", allowsDelegation: true),
      at: now
    )
    XCTAssertEqual(state.phase, .needsDecision)
    XCTAssertThrowsError(try state.resume())
    XCTAssertThrowsError(try state.retryExternalBlocker(stageID: stage.stageID))
    XCTAssertThrowsError(try state.acceptDecision(answer: nil, at: now))
    try state.acceptDecision(answer: nil, decideForMe: true, at: now)
    XCTAssertEqual(state.phase, .executing)
    XCTAssertNil(state.pendingDecision)
    XCTAssertEqual(state.decisions.last?.delegatedToNovaForge, true)
  }

  func testDecisionDelegationCanBeForbidden() throws {
    var state = try makeState()
    try state.start()
    let stage = try XCTUnwrap(state.graph.activeStages.first)
    let lease = try state.makeWorkLease(for: stage.stageID)
    try state.acceptWorkerResult(
      lease: lease,
      outcome: .needsDecision(prompt: "Permission-sensitive choice", allowsDelegation: false),
      at: now
    )
    XCTAssertThrowsError(try state.acceptDecision(answer: nil, decideForMe: true, at: now)) {
      error in
      XCTAssertEqual(error as? ForgeMissionError, .decisionDelegationNotAllowed)
    }
    try state.acceptDecision(answer: "Use option A", at: now)
    XCTAssertEqual(state.decisions.last?.answer, "Use option A")
  }

  func testExternalBlockerRemainsRetryableWithoutPretendingItWasDecision() throws {
    var state = try makeState()
    try state.start()
    let stage = try XCTUnwrap(state.graph.activeStages.first)
    let lease = try state.makeWorkLease(for: stage.stageID)
    try state.acceptWorkerResult(
      lease: lease, outcome: .blockedExternal(summary: "Network unavailable"), at: now)
    XCTAssertEqual(state.phase, .blockedExternal)
    XCTAssertNil(state.pendingDecision)
    XCTAssertEqual(state.workerReceipts.last?.summary, "Network unavailable")
    try state.retryExternalBlocker(stageID: stage.stageID)
    XCTAssertEqual(state.phase, .executing)
    XCTAssertEqual(state.graph.activeStages.first?.stageID, stage.stageID)
  }

  func testRouteSwitchInvalidatesOutstandingLease() throws {
    var state = try makeState()
    try state.start()
    let stage = try XCTUnwrap(state.graph.activeStages.first)
    let lease = try state.makeWorkLease(for: stage.stageID)
    state.switchAcceptedRoute(to: route("route-2"))
    XCTAssertThrowsError(
      try state.acceptWorkerResult(
        lease: lease, outcome: .completed(evidenceSummary: "late"), at: now)
    ) { error in
      XCTAssertEqual(error as? ForgeMissionError, .staleWorkerResult)
    }
  }

  func testCancelInvalidatesWorkAndRejectsNewStages() throws {
    var state = try makeState()
    try state.start()
    let stage = try XCTUnwrap(state.graph.activeStages.first)
    let lease = try state.makeWorkLease(for: stage.stageID)
    try state.cancel()
    XCTAssertEqual(state.phase, .cancelled)
    XCTAssertThrowsError(
      try state.acceptWorkerResult(
        lease: lease, outcome: .completed(evidenceSummary: "late"), at: now))
    XCTAssertThrowsError(try state.appendStages([newStage(order: 2)]))
  }

  func testCompletionRequiresExpectedEvidenceOrExplicitKnownLimitations() throws {
    var state = try makeState(expectedEvidence: [.runtimeTested, .visuallyInspected])
    try completeRequiredWork(&state)
    XCTAssertEqual(state.phase, .validating)
    XCTAssertThrowsError(try state.finalizeCompletion(observedEvidence: [.runtimeTested]))
    try state.finalizeCompletion(
      observedEvidence: [.runtimeTested],
      knownLimitations: ["Visual inspection unavailable on this worker"]
    )
    XCTAssertEqual(state.phase, .completedWithKnownLimitations)
    XCTAssertEqual(state.knownLimitations.count, 1)
    XCTAssertEqual(state.completionEvidence?.values, [.runtimeTested])
  }

  func testCompletionWithAllEvidenceIsDurableTruth() throws {
    var state = try makeState(expectedEvidence: [.runtimeTested])
    try completeRequiredWork(&state)
    try state.finalizeCompletion(observedEvidence: [.runtimeTested])
    XCTAssertEqual(state.phase, .completedWithEvidence)
    XCTAssertNoThrow(try ForgeMissionArchive(state: state))
  }

  func testCompletedMissionCanReopenForNewWorkButNormalizesInjectedStatus() throws {
    var state = try makeState(expectedEvidence: [])
    try completeRequiredWork(&state)
    try state.finalizeCompletion(observedEvidence: [])
    let injected = MissionStage(
      stageID: MissionStageID(),
      kind: .polish,
      title: "Improve",
      order: 2,
      status: .completed
    )
    try state.appendStages([injected])
    XCTAssertEqual(state.phase, .executing)
    XCTAssertNil(state.completionEvidence)
    XCTAssertEqual(state.graph.stages.last?.status, .active)
  }

  func testCheckpointBindsAcceptedProjectStateAndRestoreRequiresExternalVerification() throws {
    var state = try makeState()
    let projectState = acceptedProjectState("project-state-42")
    let evidence = evidenceReceipt("evidence-7")
    let checkpoint = state.checkpoint(
      acceptedProjectStateID: projectState,
      evidenceReceiptIDs: [evidence],
      summary: "Accepted build",
      at: now
    )
    let request = try state.prepareRestore(to: checkpoint.id)
    XCTAssertEqual(request.projectID, state.projectID)
    XCTAssertEqual(request.acceptedProjectStateID, projectState)
    XCTAssertThrowsError(
      try state.acceptVerifiedRestore(
        request, verifiedProjectStateID: acceptedProjectState("other-state"))
    )
    try state.acceptVerifiedRestore(request, verifiedProjectStateID: projectState)
    XCTAssertEqual(state.phase, .pausedByUser)
  }

  func testArchiveDecodeFailsClosedForWrongExpectedProject() throws {
    let state = try makeState()
    let data = try JSONEncoder().encode(ForgeMissionArchive(state: state))
    XCTAssertThrowsError(try ForgeMissionArchive.decode(data, expectedProjectID: ProjectID())) {
      error in
      XCTAssertEqual(error as? ForgeMissionError, .wrongProject)
    }
    XCTAssertEqual(
      try ForgeMissionArchive.decode(data, expectedProjectID: state.projectID).state, state)
  }

  func testRestoreBranchesFutureCheckpointsFromRestoredCheckpoint() throws {
    var state = try makeState()
    let first = state.checkpoint(
      acceptedProjectStateID: acceptedProjectState("state-1"),
      evidenceReceiptIDs: [],
      summary: "first",
      at: now
    )
    _ = state.checkpoint(
      acceptedProjectStateID: acceptedProjectState("state-2"),
      evidenceReceiptIDs: [],
      summary: "second",
      at: now
    )
    let request = try state.prepareRestore(to: first.id)
    try state.acceptVerifiedRestore(request, verifiedProjectStateID: first.acceptedProjectStateID)
    let branched = state.checkpoint(
      acceptedProjectStateID: acceptedProjectState("state-3"),
      evidenceReceiptIDs: [],
      summary: "branch",
      at: now
    )
    XCTAssertEqual(branched.parentID, first.id)
    XCTAssertEqual(state.activeCheckpointID, branched.id)
  }

  func testArchiveRejectsUnsupportedSchemaVersion() throws {
    let state = try makeState()
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(ForgeMissionArchive(state: state)))
        as? [String: Any])
    object["schemaVersion"] = 99
    let data = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(try JSONDecoder().decode(ForgeMissionArchive.self, from: data)) { error in
      XCTAssertEqual(error as? ForgeMissionError, .unsupportedArchiveVersion(99))
    }
  }

  func testBlankWorkerSummaryCannotBecomeDurableReceipt() throws {
    var state = try makeState()
    try state.start()
    let stage = try XCTUnwrap(state.graph.activeStages.first)
    let lease = try state.makeWorkLease(for: stage.stageID)
    XCTAssertThrowsError(
      try state.acceptWorkerResult(
        lease: lease, outcome: .completed(evidenceSummary: "   "), at: now)
    ) { error in
      XCTAssertEqual(error as? ForgeMissionError, .blankWorkerSummary)
    }
    XCTAssertTrue(state.workerReceipts.isEmpty)
    XCTAssertEqual(state.graph.activeStages.first?.stageID, stage.stageID)
  }

  func testAlreadySatisfiedGraphStartsAtValidationInsteadOfDeadExecutingState() throws {
    let missionID = MissionID()
    let projectID = ProjectID()
    let constitution = makeConstitution(missionID: missionID, projectID: projectID)
    let completed = MissionStage(
      stageID: MissionStageID(), kind: .implement, title: "Already built", order: 1,
      status: .completed)
    var state = try ForgeMissionState(
      constitution: constitution,
      graph: MissionStageGraph(missionID: missionID, stages: [completed]),
      acceptedRouteDescriptorID: route("route-1")
    )
    try state.start()
    XCTAssertEqual(state.phase, .validating)
    XCTAssertTrue(state.graph.activeStages.isEmpty)
  }

  func testArchiveRejectsCheckpointParentThatWasNeverAccepted() throws {
    var state = try makeState()
    _ = state.checkpoint(
      acceptedProjectStateID: acceptedProjectState("state-1"),
      evidenceReceiptIDs: [],
      summary: "checkpoint",
      at: now
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(ForgeMissionArchive(state: state)))
        as? [String: Any])
    var encodedState = try XCTUnwrap(object["state"] as? [String: Any])
    var checkpoints = try XCTUnwrap(encodedState["checkpoints"] as? [[String: Any]])
    checkpoints[0]["parentID"] = ["rawValue": UUID().uuidString]
    encodedState["checkpoints"] = checkpoints
    object["state"] = encodedState
    let data = try JSONSerialization.data(withJSONObject: object)
    XCTAssertThrowsError(try JSONDecoder().decode(ForgeMissionArchive.self, from: data)) { error in
      XCTAssertEqual(error as? ForgeMissionError, .invalidCheckpointLineage)
    }
  }

  func testIndependentReadyStagesCanActivateInBoundedParallel() throws {
    let missionID = MissionID()
    let projectID = ProjectID()
    let constitution = makeConstitution(missionID: missionID, projectID: projectID)
    let graph = MissionStageGraph(
      missionID: missionID,
      stages: [newStage(order: 1), newStage(order: 2)]
    )
    var state = try ForgeMissionState(
      constitution: constitution,
      graph: graph,
      acceptedRouteDescriptorID: route("route-1")
    )
    try state.start(maxParallelStages: 2)
    XCTAssertEqual(state.graph.activeStages.count, 2)
  }

  func testRequiredStageCannotBeDeferred() throws {
    var state = try makeState()
    XCTAssertThrowsError(try state.deferOptionalStage(state.graph.stages[0].stageID)) { error in
      XCTAssertEqual(error as? ForgeMissionError, .requiredStageCannotBeDeferred)
    }
  }

  private func completeRequiredWork(_ state: inout ForgeMissionState) throws {
    try state.start()
    while let active = state.graph.activeStages.first {
      let lease = try state.makeWorkLease(for: active.stageID)
      try state.acceptWorkerResult(
        lease: lease, outcome: .completed(evidenceSummary: "verified"), at: now)
      if state.phase == .validating { break }
    }
  }

  private func makeState(expectedEvidence: [MissionEvidenceClass] = []) throws -> ForgeMissionState
  {
    let missionID = MissionID()
    let projectID = ProjectID()
    return try ForgeMissionState(
      constitution: makeConstitution(
        missionID: missionID, projectID: projectID, expectedEvidence: expectedEvidence),
      graph: MissionStageGraph(
        missionID: missionID,
        stages: [
          MissionStage(stageID: MissionStageID(), kind: .implement, title: "Build", order: 1)
        ]
      ),
      acceptedRouteDescriptorID: route("route-1")
    )
  }

  private func makeConstitution(
    missionID: MissionID,
    projectID: ProjectID,
    expectedEvidence: [MissionEvidenceClass] = []
  ) -> MissionConstitution {
    MissionConstitution(
      missionID: missionID,
      projectID: projectID,
      acceptedAt: now,
      productGoal: "Build a polished app",
      projectType: "Forge Runtime app",
      expectedEvidence: MissionEvidenceSet(expectedEvidence)
    )
  }

  private func newStage(order: UInt32) -> MissionStage {
    MissionStage(stageID: MissionStageID(), kind: .polish, title: "Stage \(order)", order: order)
  }

  private func route(_ value: String) -> AcceptedRouteDescriptorID {
    AcceptedRouteDescriptorID(rawValue: value)!
  }

  private func acceptedProjectState(_ value: String) -> AcceptedProjectStateID {
    AcceptedProjectStateID(rawValue: value)!
  }

  private func evidenceReceipt(_ value: String) -> MissionEvidenceReceiptID {
    MissionEvidenceReceiptID(rawValue: value)!
  }
}
