import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestRepairPriorityTests: XCTestCase {
    func testKnownSevereDefectNeedsTrustedEvidenceBeforeRepairPriority() throws {
        let project = try ForgePlaytestProjectRevision(
            projectID: "project-repair-priority",
            sourceRevision: "rev-repair-priority"
        )
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])

        for severity in [ForgePlaytestDefectSeverity.high, .critical] {
            for status in [ForgePlaytestJourneyStatus.failed, .interrupted] {
                let suffix = "\(status.rawValue)-\(severity.rawValue)"
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
                    severity: severity,
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

                XCTAssertThrowsError(
                    try ForgePlaytestGateEvaluator.evaluate(
                        project: project,
                        policy: policy,
                        plans: [plan],
                        results: [result],
                        executionBindings: []
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? ForgePlaytestExecutionGateError,
                        .missingDefectEvidenceBinding(
                            journeyID: journeyID,
                            defectID: defect.defectID
                        )
                    )
                }

                let authenticatedDefect = try ForgePlaytestAuthenticatedDefectBinding(
                    project: project,
                    journeyID: journeyID,
                    defect: defect,
                    supportingEvidence: [crashEvidence]
                )
                XCTAssertEqual(
                    try ForgePlaytestGateEvaluator.evaluate(
                        project: project,
                        policy: policy,
                        plans: [plan],
                        results: [result],
                        executionBindings: [],
                        defectEvidenceBindings: [authenticatedDefect]
                    ),
                    .repairRequired([
                        ForgePlaytestRepairItem(
                            journeyID: journeyID,
                            persona: .goalRunner,
                            defect: defect
                        ),
                    ]),
                    "Authenticated severity \(severity.rawValue) \(status.rawValue) defect must remain actionable before the generic missing-completed blocker."
                )
            }
        }
    }

    func testAuthenticatedDefectBindingRejectsRewrittenDefectAndEvidence() throws {
        let project = try ForgePlaytestProjectRevision(
            projectID: "project-binding",
            sourceRevision: "rev-binding"
        )
        let journeyID = "goal-binding"
        let crashEvidence = try ForgePlaytestEvidenceReference(
            receiptID: "crash-binding",
            project: project,
            journeyID: journeyID,
            kind: .crashLog
        )
        let defect = try ForgePlaytestDefect(
            defectID: "fatal-binding",
            severity: .high,
            category: .runtime,
            summary: "Authenticated crash.",
            evidenceReceiptIDs: [crashEvidence.receiptID]
        )
        let authenticated = try ForgePlaytestAuthenticatedDefectBinding(
            project: project,
            journeyID: journeyID,
            defect: defect,
            supportingEvidence: [crashEvidence]
        )

        let rewrittenDefect = try ForgePlaytestDefect(
            defectID: defect.defectID,
            severity: .critical,
            category: .runtime,
            summary: defect.summary,
            evidenceReceiptIDs: defect.evidenceReceiptIDs
        )
        XCTAssertNotEqual(authenticated.defect, rewrittenDefect)

        let unrelatedEvidence = try ForgePlaytestEvidenceReference(
            receiptID: "other-binding",
            project: project,
            journeyID: journeyID,
            kind: .runtimeEventLog
        )
        XCTAssertThrowsError(
            try ForgePlaytestAuthenticatedDefectBinding(
                project: project,
                journeyID: journeyID,
                defect: defect,
                supportingEvidence: [unrelatedEvidence]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgePlaytestExecutionGateError,
                .defectEvidenceBindingEvidenceMismatch(
                    journeyID: journeyID,
                    defectID: defect.defectID
                )
            )
        }
    }
}
