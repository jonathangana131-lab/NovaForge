import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestQualificationAdversarialTests: XCTestCase {
    private func project() throws -> ForgePlaytestProjectRevision {
        try ForgePlaytestProjectRevision(projectID: "project-alpha", sourceRevision: "rev-7")
    }

    private func evidence(
        _ kind: ForgePlaytestEvidenceKind,
        receipt: String,
        journey: String
    ) throws -> ForgePlaytestEvidenceReference {
        try ForgePlaytestEvidenceReference(
            receiptID: receipt,
            project: project(),
            journeyID: journey,
            kind: kind
        )
    }

    private func plan(
        journey: String,
        persona: ForgePlaytestPersona,
        expectedMilestones: Set<String> = []
    ) throws -> ForgePlaytestJourneyPlan {
        try ForgePlaytestJourneyPlan(
            journeyID: journey,
            project: project(),
            persona: persona,
            trace: ForgePlaytestTrace(traceID: "trace-\(journey)", steps: []),
            expectedMilestoneIDs: expectedMilestones
        )
    }

    private func completedResult(
        journey: String,
        persona: ForgePlaytestPersona,
        extraEvidence: [ForgePlaytestEvidenceReference] = [],
        milestones: [ForgePlaytestMilestoneObservation] = []
    ) throws -> ForgePlaytestJourneyResult {
        try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: journey,
            persona: persona,
            traceID: "trace-\(journey)",
            status: .completed,
            evidence: [try evidence(.runtimeExecution, receipt: "exec-\(journey)", journey: journey)] + extraEvidence,
            milestones: milestones
        )
    }

    func testQualifiedJourneySelectionDoesNotDependOnLexicographicFailure() throws {
        let stateA = try evidence(.runtimeState, receipt: "state-a", journey: "a")
        let stateB = try evidence(.runtimeState, receipt: "state-b", journey: "b")
        let runtimeB = try evidence(.runtimeEventLog, receipt: "milestone-b", journey: "b")
        let reached = try ForgePlaytestMilestoneObservation(
            milestoneID: "win",
            evidenceReceiptIDs: [runtimeB.receiptID]
        )
        let a = try completedResult(journey: "a", persona: .goalRunner, extraEvidence: [stateA])
        let b = try completedResult(
            journey: "b",
            persona: .goalRunner,
            extraEvidence: [stateB, runtimeB],
            milestones: [reached]
        )
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(
                persona: .goalRunner,
                requiredEvidenceKinds: [.runtimeExecution, .runtimeState]
            ),
        ])

        guard case let .accepted(projection) = try ForgePlaytestGateEvaluator.evaluate(
            project: project(),
            policy: policy,
            plans: [
                try plan(journey: "a", persona: .goalRunner, expectedMilestones: ["win"]),
                try plan(journey: "b", persona: .goalRunner, expectedMilestones: ["win"]),
            ],
            results: [a, b]
        ) else {
            return XCTFail("Expected the qualifying journey to be selected")
        }
        XCTAssertEqual(projection.acceptedJourneyIDs, ["b"])
    }

    func testRequiredEvidenceCannotBeFragmentedAcrossMinimumJourneys() throws {
        let screenshot = try evidence(.screenshot, receipt: "shot-a", journey: "a")
        let a = try completedResult(journey: "a", persona: .visualReviewer, extraEvidence: [screenshot])
        let b = try completedResult(journey: "b", persona: .visualReviewer)
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(
                persona: .visualReviewer,
                minimumCompletedJourneys: 2,
                requiredEvidenceKinds: [.runtimeExecution, .screenshot]
            ),
        ])

        XCTAssertEqual(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy,
                plans: [
                    try plan(journey: "a", persona: .visualReviewer),
                    try plan(journey: "b", persona: .visualReviewer),
                ],
                results: [a, b]
            ),
            .blocked([.missingEvidence(persona: .visualReviewer, kind: .screenshot)])
        )
    }

    func testJourneyCollectionsAreBounded() throws {
        let refs = try (0 ... ForgePlaytestJourneyResult.maximumEvidenceReferences).map { index in
            try evidence(.runtimeExecution, receipt: "receipt-\(index)", journey: "goal")
        }
        XCTAssertThrowsError(
            try ForgePlaytestJourneyResult(
                project: project(),
                journeyID: "goal",
                persona: .goalRunner,
                traceID: "trace-goal",
                status: .completed,
                evidence: refs
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlaytestError,
                .collectionTooLarge(
                    field: "journey.evidence",
                    maximum: ForgePlaytestJourneyResult.maximumEvidenceReferences
                )
            )
        }
    }

    func testEvaluatorCollectionsAreBounded() throws {
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])
        let plans = try (0 ... ForgePlaytestGateEvaluator.maximumJourneyPlans).map { index in
            try plan(journey: "plan-\(index)", persona: .goalRunner)
        }
        XCTAssertThrowsError(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy,
                plans: plans,
                results: []
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlaytestError,
                .collectionTooLarge(
                    field: "playtest.plans",
                    maximum: ForgePlaytestGateEvaluator.maximumJourneyPlans
                )
            )
        }
    }
}
