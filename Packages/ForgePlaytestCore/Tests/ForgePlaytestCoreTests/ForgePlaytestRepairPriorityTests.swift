import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestRepairPriorityTests: XCTestCase {
    func testKnownSevereDefectTakesPriorityOverMissingCompletedJourney() throws {
        let project = try ForgePlaytestProjectRevision(
            projectID: "project-repair-priority",
            sourceRevision: "rev-repair-priority"
        )
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])

        for status in [ForgePlaytestJourneyStatus.failed, .interrupted] {
            let suffix = status.rawValue
            let journeyID = "goal-\(suffix)"
            let trace = try ForgePlaytestTrace(
                traceID: "trace-\(suffix)",
                steps: []
            )
            let plan = try ForgePlaytestJourneyPlan(
                journeyID: journeyID,
                project: project,
                persona: .goalRunner,
                trace: trace
            )
            let crashEvidence = try ForgePlaytestEvidenceReference(
                receiptID: "crash-\(suffix)",
                project: project,
                journeyID: journeyID,
                kind: .crashLog
            )
            let defect = try ForgePlaytestDefect(
                defectID: "fatal-\(suffix)",
                severity: .critical,
                category: .runtime,
                summary: "Runtime terminates before the required goal journey completes.",
                evidenceReceiptIDs: [crashEvidence.receiptID]
            )
            let result = try ForgePlaytestJourneyResult(
                project: project,
                journeyID: journeyID,
                persona: .goalRunner,
                traceID: trace.traceID,
                status: status,
                evidence: [crashEvidence],
                defects: [defect]
            )

            XCTAssertEqual(
                try ForgePlaytestGateEvaluator.evaluate(
                    project: project,
                    policy: policy,
                    plans: [plan],
                    results: [result],
                    executionBindings: []
                ),
                .repairRequired([
                    ForgePlaytestRepairItem(
                        journeyID: journeyID,
                        persona: .goalRunner,
                        defect: defect
                    ),
                ]),
                "A known \(status.rawValue) critical defect must remain actionable instead of being hidden by a missing-completed-journey blocker."
            )
        }
    }
}
