import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestFailureTruthTests: XCTestCase {
    func testNonCompletedSevereDefectsPreventSameRevisionAcceptance() throws {
        let project = try ForgePlaytestProjectRevision(
            projectID: "project-alpha",
            sourceRevision: "rev-failure-truth"
        )
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])

        let goalPlan = try ForgePlaytestJourneyPlan(
            journeyID: "goal",
            project: project,
            persona: .goalRunner,
            trace: ForgePlaytestTrace(traceID: "trace-goal", steps: [])
        )
        let goalExecution = try ForgePlaytestEvidenceReference(
            receiptID: "exec-goal",
            project: project,
            journeyID: "goal",
            kind: .runtimeExecution
        )
        let goalResult = try ForgePlaytestJourneyResult(
            project: project,
            journeyID: "goal",
            persona: .goalRunner,
            traceID: "trace-goal",
            status: .completed,
            evidence: [goalExecution]
        )

        for status in [ForgePlaytestJourneyStatus.failed, .interrupted] {
            let journeyID = "chaos-\(status.rawValue)"
            let chaosPlan = try ForgePlaytestJourneyPlan(
                journeyID: journeyID,
                project: project,
                persona: .chaosTester,
                trace: ForgePlaytestTrace(traceID: "trace-\(journeyID)", steps: [])
            )
            let execution = try ForgePlaytestEvidenceReference(
                receiptID: "exec-\(journeyID)",
                project: project,
                journeyID: journeyID,
                kind: .runtimeExecution
            )
            let runtimeLog = try ForgePlaytestEvidenceReference(
                receiptID: "log-\(journeyID)",
                project: project,
                journeyID: journeyID,
                kind: .runtimeEventLog
            )
            let defect = try ForgePlaytestDefect(
                defectID: "runtime-\(status.rawValue)",
                severity: .high,
                category: .runtime,
                summary: "The adversarial journey discovered a same-revision runtime failure.",
                evidenceReceiptIDs: [runtimeLog.receiptID]
            )
            let result = try ForgePlaytestJourneyResult(
                project: project,
                journeyID: journeyID,
                persona: .chaosTester,
                traceID: "trace-\(journeyID)",
                status: status,
                evidence: [execution, runtimeLog],
                defects: [defect]
            )

            XCTAssertEqual(
                try ForgePlaytestGateEvaluator.evaluate(
                    project: project,
                    policy: policy,
                    plans: [goalPlan, chaosPlan],
                    results: [goalResult, result]
                ),
                .repairRequired([
                    ForgePlaytestRepairItem(
                        journeyID: journeyID,
                        persona: .chaosTester,
                        defect: defect
                    ),
                ]),
                "A \(status.rawValue) journey must not hide a receipted high-severity defect while another journey makes the gate otherwise eligible for acceptance."
            )
        }
    }
}
