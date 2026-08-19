import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestExecutionGateTests: XCTestCase {
    private func project() throws -> ForgePlaytestProjectRevision {
        try ForgePlaytestProjectRevision(projectID: "project-alpha", sourceRevision: "rev-7")
    }

    private func trace(
        id: String = "trace-goal",
        controlID: String? = nil
    ) throws -> ForgePlaytestTrace {
        guard let controlID else {
            return try ForgePlaytestTrace(traceID: id, steps: [])
        }
        let action = try ForgePlaytestAction.validatedButton(controlID: controlID, phase: .press)
        return try ForgePlaytestTrace(
            traceID: id,
            steps: [try ForgePlaytestStep(sequence: 0, tick: 0, action: action)]
        )
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

    private func policy(
        persona: ForgePlaytestPersona = .goalRunner,
        kinds: Set<ForgePlaytestEvidenceKind> = [.runtimeExecution]
    ) throws -> ForgePlaytestAcceptancePolicy {
        try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(
                persona: persona,
                requiredEvidenceKinds: kinds
            ),
        ])
    }

    func testPublicExecutionGateAcceptsExactAuthenticatedJourneyAndTrace() throws {
        let plannedTrace = try trace(controlID: "jump")
        let execution = try evidence(.runtimeExecution, receipt: "exec", journey: "goal")
        let plan = try ForgePlaytestJourneyPlan(
            journeyID: "goal",
            project: project(),
            persona: .goalRunner,
            trace: plannedTrace
        )
        let result = try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: "goal",
            persona: .goalRunner,
            traceID: plannedTrace.traceID,
            status: .completed,
            evidence: [execution]
        )
        let binding = try ForgePlaytestExecutionBinding(
            result: result,
            trace: plannedTrace
        )

        guard case let .accepted(projection) = try ForgePlaytestGateEvaluator.evaluate(
            project: project(),
            policy: policy(),
            plans: [plan],
            results: [result],
            executionBindings: [binding]
        ) else {
            return XCTFail("Expected exact authenticated journey binding to pass")
        }
        XCTAssertEqual(projection.acceptedJourneyIDs, ["goal"])
        XCTAssertEqual(projection.contributingReceiptIDs, ["exec"])
    }

    func testSameTraceIDWithDifferentControlsIsRejected() throws {
        let plannedTrace = try trace(id: "shared", controlID: "fire")
        let staleExecutedTrace = try trace(id: "shared", controlID: "jump")
        let execution = try evidence(.runtimeExecution, receipt: "exec-old", journey: "goal")
        let plan = try ForgePlaytestJourneyPlan(
            journeyID: "goal",
            project: project(),
            persona: .goalRunner,
            trace: plannedTrace
        )
        let staleResult = try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: "goal",
            persona: .goalRunner,
            traceID: "shared",
            status: .completed,
            evidence: [execution]
        )
        let staleBinding = try ForgePlaytestExecutionBinding(
            result: staleResult,
            trace: staleExecutedTrace
        )

        XCTAssertThrowsError(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy(),
                plans: [plan],
                results: [staleResult],
                executionBindings: [staleBinding]
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlaytestExecutionGateError,
                .executionTraceMismatch("goal")
            )
        }
    }

    func testCompletedJourneyCannotPassPublicGateWithoutExecutionBinding() throws {
        let plannedTrace = try trace()
        let execution = try evidence(.runtimeExecution, receipt: "exec", journey: "goal")
        let plan = try ForgePlaytestJourneyPlan(
            journeyID: "goal",
            project: project(),
            persona: .goalRunner,
            trace: plannedTrace
        )
        let result = try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: "goal",
            persona: .goalRunner,
            traceID: plannedTrace.traceID,
            status: .completed,
            evidence: [execution]
        )

        XCTAssertThrowsError(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy(),
                plans: [plan],
                results: [result],
                executionBindings: []
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestExecutionGateError, .missingBinding("goal"))
        }
    }

    func testAuthenticatedRuntimeReceiptCannotBeReplayedWithFabricatedResultEvidence() throws {
        let plannedTrace = try trace()
        let execution = try evidence(.runtimeExecution, receipt: "exec", journey: "goal")
        let plan = try ForgePlaytestJourneyPlan(
            journeyID: "goal",
            project: project(),
            persona: .goalRunner,
            trace: plannedTrace
        )
        let authenticatedResult = try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: "goal",
            persona: .goalRunner,
            traceID: plannedTrace.traceID,
            status: .completed,
            evidence: [execution]
        )
        let fabricatedScreenshot = try evidence(.screenshot, receipt: "fake-shot", journey: "goal")
        let callerRewrittenResult = try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: "goal",
            persona: .goalRunner,
            traceID: plannedTrace.traceID,
            status: .completed,
            evidence: [execution, fabricatedScreenshot]
        )
        let binding = try ForgePlaytestExecutionBinding(
            result: authenticatedResult,
            trace: plannedTrace
        )

        XCTAssertThrowsError(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: try policy(kinds: [.runtimeExecution, .screenshot]),
                plans: [plan],
                results: [callerRewrittenResult],
                executionBindings: [binding]
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlaytestExecutionGateError,
                .executionResultMismatch("goal")
            )
        }
    }

    func testAcceptedProjectionExcludesUnrelatedAuthenticatedEvidence() throws {
        let plannedTrace = try trace()
        let execution = try evidence(.runtimeExecution, receipt: "exec", journey: "goal")
        let unrelatedScreenshot = try evidence(.screenshot, receipt: "shot-unrelated", journey: "goal")
        let unrelatedLog = try evidence(.runtimeEventLog, receipt: "log-unrelated", journey: "goal")
        let plan = try ForgePlaytestJourneyPlan(
            journeyID: "goal",
            project: project(),
            persona: .goalRunner,
            trace: plannedTrace
        )
        let result = try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: "goal",
            persona: .goalRunner,
            traceID: plannedTrace.traceID,
            status: .completed,
            evidence: [execution, unrelatedScreenshot, unrelatedLog]
        )
        let binding = try ForgePlaytestExecutionBinding(result: result, trace: plannedTrace)

        guard case let .accepted(projection) = try ForgePlaytestGateEvaluator.evaluate(
            project: project(),
            policy: policy(),
            plans: [plan],
            results: [result],
            executionBindings: [binding]
        ) else {
            return XCTFail("Expected playtest acceptance")
        }
        XCTAssertEqual(projection.contributingReceiptIDs, ["exec"])
    }

    func testRequiredMilestoneReceiptsContributeToProjection() throws {
        let plannedTrace = try trace()
        let execution = try evidence(.runtimeExecution, receipt: "exec", journey: "goal")
        let milestoneLog = try evidence(.runtimeEventLog, receipt: "win-log", journey: "goal")
        let milestone = try ForgePlaytestMilestoneObservation(
            milestoneID: "win",
            evidenceReceiptIDs: [milestoneLog.receiptID]
        )
        let plan = try ForgePlaytestJourneyPlan(
            journeyID: "goal",
            project: project(),
            persona: .goalRunner,
            trace: plannedTrace,
            expectedMilestoneIDs: ["win"]
        )
        let result = try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: "goal",
            persona: .goalRunner,
            traceID: plannedTrace.traceID,
            status: .completed,
            evidence: [execution, milestoneLog],
            milestones: [milestone]
        )
        let binding = try ForgePlaytestExecutionBinding(result: result, trace: plannedTrace)

        guard case let .accepted(projection) = try ForgePlaytestGateEvaluator.evaluate(
            project: project(),
            policy: policy(),
            plans: [plan],
            results: [result],
            executionBindings: [binding]
        ) else {
            return XCTFail("Expected playtest acceptance")
        }
        XCTAssertEqual(projection.contributingReceiptIDs, ["exec", "win-log"])
    }

    func testJourneyPlanMilestonesAreBounded() throws {
        let milestones = Set((0 ... ForgePlaytestJourneyPlan.maximumExpectedMilestoneIDs).map { "m-\($0)" })
        XCTAssertThrowsError(
            try ForgePlaytestJourneyPlan(
                journeyID: "goal",
                project: project(),
                persona: .goalRunner,
                trace: trace(),
                expectedMilestoneIDs: milestones
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlaytestError,
                .collectionTooLarge(
                    field: "journeyPlan.expectedMilestoneIDs",
                    maximum: ForgePlaytestJourneyPlan.maximumExpectedMilestoneIDs
                )
            )
        }
    }

    func testPersonaRequirementMilestonesAreBounded() throws {
        let milestones = Set((0 ... ForgePlaytestPersonaRequirement.maximumRequiredMilestoneIDs).map { "m-\($0)" })
        XCTAssertThrowsError(
            try ForgePlaytestPersonaRequirement(
                persona: .goalRunner,
                requiredMilestoneIDs: milestones
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlaytestError,
                .collectionTooLarge(
                    field: "personaRequirement.requiredMilestoneIDs",
                    maximum: ForgePlaytestPersonaRequirement.maximumRequiredMilestoneIDs
                )
            )
        }
    }
}
