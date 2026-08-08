import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestReceiptUniquenessTests: XCTestCase {
    func testPublicGateRejectsReceiptIDReuseAcrossJourneys() throws {
        let project = try ForgePlaytestProjectRevision(projectID: "project-alpha", sourceRevision: "rev-7")
        let traceA = try ForgePlaytestTrace(traceID: "trace-a", steps: [])
        let traceB = try ForgePlaytestTrace(traceID: "trace-b", steps: [])
        let planA = try ForgePlaytestJourneyPlan(journeyID: "a", project: project, persona: .goalRunner, trace: traceA)
        let planB = try ForgePlaytestJourneyPlan(journeyID: "b", project: project, persona: .goalRunner, trace: traceB)
        let evidenceA = try ForgePlaytestEvidenceReference(receiptID: "shared-exec", project: project, journeyID: "a", kind: .runtimeExecution)
        let evidenceB = try ForgePlaytestEvidenceReference(receiptID: "shared-exec", project: project, journeyID: "b", kind: .runtimeExecution)
        let resultA = try ForgePlaytestJourneyResult(project: project, journeyID: "a", persona: .goalRunner, traceID: traceA.traceID, status: .completed, evidence: [evidenceA])
        let resultB = try ForgePlaytestJourneyResult(project: project, journeyID: "b", persona: .goalRunner, traceID: traceB.traceID, status: .completed, evidence: [evidenceB])
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner, minimumCompletedJourneys: 2),
        ])
        let bindings = try [
            ForgePlaytestExecutionBinding(executionEvidence: evidenceA, trace: traceA),
            ForgePlaytestExecutionBinding(executionEvidence: evidenceB, trace: traceB),
        ]

        XCTAssertThrowsError(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project,
                policy: policy,
                plans: [planA, planB],
                results: [resultA, resultB],
                executionBindings: bindings
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .duplicateReceiptID("shared-exec"))
        }
    }
}
