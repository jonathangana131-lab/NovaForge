from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


source_path = Path("Packages/AgentHarnessKit/Sources/ForgeMission/ForgeMission.swift")
tests_path = Path("Packages/AgentHarnessKit/Tests/ForgeMissionTests/ForgeMissionTests.swift")

s = source_path.read_text()
s = replace_once(s, '''        guard phase == .needsDecision else { throw ForgeMissionError.invalidPhase(phase) }
        guard !acceptedAnswer.trimmed.isEmpty, !decisionReceiptID.trimmed.isEmpty else { throw ForgeMissionError.invalidDecision }
        guard let request = pendingDecision,
''', '''        guard phase == .needsDecision else { throw ForgeMissionError.invalidPhase(phase) }
        let normalizedAnswer = acceptedAnswer.trimmed
        guard !normalizedAnswer.isEmpty,
              !normalizedAnswer.isUnresolvedDecisionDelegation,
              !decisionReceiptID.trimmed.isEmpty else { throw ForgeMissionError.invalidDecision }
        guard let request = pendingDecision,
''', 'concrete decision guard')
s = replace_once(s, '''            stageID: stageID,
            acceptedAnswer: acceptedAnswer.trimmed,
            decisionReceiptID: decisionReceiptID.trimmed,
''', '''            stageID: stageID,
            acceptedAnswer: normalizedAnswer,
            decisionReceiptID: decisionReceiptID.trimmed,
''', 'normalized accepted decision')
s = replace_once(s, '''private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
''', '''private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var isUnresolvedDecisionDelegation: Bool {
        let token = trimmed
            .uppercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        return token == "DECIDE_FOR_ME"
    }
}
''', 'delegation token helper')
source_path.write_text(s)

t = tests_path.read_text()
insertion = '''
    func testDecideForMePlaceholderCannotBecomeAcceptedSemanticDecision() throws {
        var mission = try makeMission()
        let stageID = try XCTUnwrap(mission.runnableStageIDs.first)
        let lease = try mission.beginWork(on: [stageID])[0]
        try mission.acceptWorkerResult(
            .init(
                lease: lease,
                outcome: .needsDecision,
                summary: "Choose camera",
                allowsDecisionDelegation: true
            ),
            at: instant(75)
        )
        let requestID = try XCTUnwrap(mission.pendingDecision?.requestID)

        XCTAssertThrowsError(try mission.acceptDecision(
            stageID: stageID,
            decisionRequestID: requestID,
            acceptedAnswer: "DECIDE_FOR_ME",
            decisionReceiptID: "decision:delegated",
            at: instant(76)
        )) { error in
            XCTAssertEqual(error as? ForgeMissionError, .invalidDecision)
        }
        XCTAssertThrowsError(try mission.acceptDecision(
            stageID: stageID,
            decisionRequestID: requestID,
            acceptedAnswer: "Decide for me",
            decisionReceiptID: "decision:delegated",
            at: instant(76)
        ))
        XCTAssertEqual(mission.phase, .needsDecision)
        XCTAssertNotNil(mission.pendingDecision)

        try mission.acceptDecision(
            stageID: stageID,
            decisionRequestID: requestID,
            acceptedAnswer: "Third person",
            decisionReceiptID: "decision:delegated:resolved",
            at: instant(77)
        )
        XCTAssertEqual(mission.decisions.last?.acceptedAnswer, "Third person")
        XCTAssertEqual(mission.phase, .ready)
    }

'''
t = replace_once(t, '''    func testExternalBlockRequiresResolutionReceipt() throws {
''', insertion + '''    func testExternalBlockRequiresResolutionReceipt() throws {
''', 'delegation placeholder regression')
tests_path.write_text(t)
