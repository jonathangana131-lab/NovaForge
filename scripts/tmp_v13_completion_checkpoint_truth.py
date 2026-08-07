from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


source_path = Path("Packages/AgentHarnessKit/Sources/ForgeMission/ForgeMission.swift")
archive_path = Path("Packages/AgentHarnessKit/Sources/ForgeMission/ForgeMissionArchive.swift")
tests_path = Path("Packages/AgentHarnessKit/Tests/ForgeMissionTests/ForgeMissionTests.swift")

s = source_path.read_text()
s = replace_once(s, '''    case completionRequiresCheckpoint
    case completionProjectStateMismatch
    case completionMissingExpectedEvidence
''', '''    case completionRequiresCheckpoint
    case completionProjectStateMismatch
    case completionCheckpointAuthorityMismatch
    case completionMissingExpectedEvidence
''', 'completion authority error')

s = replace_once(s, '''        guard let checkpoint = checkpoints.last else { throw ForgeMissionError.completionRequiresCheckpoint }
        guard checkpoint.acceptedProjectStateID == evidence.acceptedProjectStateID.trimmed else { throw ForgeMissionError.completionProjectStateMismatch }
        guard !evidence.receiptIDs.values.isEmpty,
''', '''        guard let checkpoint = checkpoints.last else { throw ForgeMissionError.completionRequiresCheckpoint }
        guard checkpoint.acceptedProjectStateID == evidence.acceptedProjectStateID.trimmed else { throw ForgeMissionError.completionProjectStateMismatch }
        guard checkpoint.missionRevision == revision,
              checkpoint.authorityEpoch == authorityEpoch,
              checkpoint.constitutionRevision == constitution.revision,
              checkpoint.graph == graph,
              checkpoint.routeReceiptID == route.routeReceiptID else {
            throw ForgeMissionError.completionCheckpointAuthorityMismatch
        }
        guard !evidence.receiptIDs.values.isEmpty,
''', 'completion exact authority binding')
source_path.write_text(s)

a = archive_path.read_text()
a = replace_once(a, '''            guard checkpoint.acceptedProjectStateID == completion.acceptedProjectStateID.trimmed,
                  !completion.receiptIDs.values.isEmpty,
                  state.constitution.expectedEvidence.values.allSatisfy(completion.evidenceClasses.contains) else { throw ForgeMissionArchiveError.invalidCompletion }
''', '''            guard checkpoint.acceptedProjectStateID == completion.acceptedProjectStateID.trimmed,
                  checkpoint.graph == state.graph,
                  checkpoint.constitutionRevision == state.constitution.revision,
                  checkpoint.routeReceiptID == state.route.routeReceiptID,
                  checkpoint.missionRevision < UInt64.max,
                  checkpoint.authorityEpoch < UInt64.max,
                  checkpoint.missionRevision + 1 == state.revision,
                  checkpoint.authorityEpoch + 1 == state.authorityEpoch,
                  !completion.receiptIDs.values.isEmpty,
                  state.constitution.expectedEvidence.values.allSatisfy(completion.evidenceClasses.contains) else { throw ForgeMissionArchiveError.invalidCompletion }
''', 'archive terminal checkpoint authority')
archive_path.write_text(a)

t = tests_path.read_text()
t = replace_once(t, '''        try mission.deferOptionalStage(optionalID)
        try mission.complete(with: completion(state: "state:settled", classes: [.runtimeTested]))
        XCTAssertEqual(mission.phase, .completedWithEvidence)
''', '''        try mission.deferOptionalStage(optionalID)
        XCTAssertThrowsError(try mission.complete(with: completion(state: "state:settled", classes: [.runtimeTested]))) { error in
            XCTAssertEqual(error as? ForgeMissionError, .completionCheckpointAuthorityMismatch)
        }
        _ = try mission.checkpoint(
            acceptedProjectStateID: "state:settled",
            evidenceReceiptIDs: .init(["checkpoint:deferred"]),
            summary: "Optional work explicitly deferred",
            at: instant(73)
        )
        try mission.complete(with: completion(state: "state:settled", classes: [.runtimeTested]))
        XCTAssertEqual(mission.phase, .completedWithEvidence)
''', 'settled optional requires fresh checkpoint')

insertion = '''
    func testCompletionRejectsCheckpointFromStaleMissionAuthority() throws {
        var mission = try completedReadyMission()
        try mission.switchRoute(to: .init(routeReceiptID: "route:deep:2"))

        XCTAssertThrowsError(try mission.complete(with: completion(state: "state:1", classes: [.runtimeTested]))) { error in
            XCTAssertEqual(error as? ForgeMissionError, .completionCheckpointAuthorityMismatch)
        }
        _ = try mission.checkpoint(
            acceptedProjectStateID: "state:1",
            evidenceReceiptIDs: .init(["checkpoint:route:deep"]),
            summary: "Accepted current route authority",
            at: instant(74)
        )
        try mission.complete(with: completion(state: "state:1", classes: [.runtimeTested]))
        XCTAssertEqual(mission.phase, .completedWithEvidence)
        XCTAssertNoThrow(try ForgeMissionArchive(state: mission))
    }

'''
t = replace_once(t, '''    func testArchiveRoundTripIsDeterministicAndFailClosedOnSchema() throws {
''', insertion + '''    func testArchiveRoundTripIsDeterministicAndFailClosedOnSchema() throws {
''', 'completion authority regression test')
tests_path.write_text(t)
