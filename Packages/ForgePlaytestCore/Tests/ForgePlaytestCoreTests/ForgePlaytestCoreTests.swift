import XCTest
@testable import ForgePlaytestCore

final class ForgePlaytestCoreTests: XCTestCase {
    private func project(_ revision: String = "rev-7") throws -> ForgePlaytestProjectRevision {
        try ForgePlaytestProjectRevision(projectID: "project-alpha", sourceRevision: revision)
    }

    private func evidence(
        _ kind: ForgePlaytestEvidenceKind,
        receipt: String,
        journey: String,
        revision: String = "rev-7"
    ) throws -> ForgePlaytestEvidenceReference {
        try ForgePlaytestEvidenceReference(
            receiptID: receipt,
            project: project(revision),
            journeyID: journey,
            kind: kind
        )
    }

    private func plan(
        journey: String,
        persona: ForgePlaytestPersona,
        revision: String = "rev-7",
        expectedMilestones: Set<String> = []
    ) throws -> ForgePlaytestJourneyPlan {
        try ForgePlaytestJourneyPlan(
            journeyID: journey,
            project: project(revision),
            persona: persona,
            trace: ForgePlaytestTrace(traceID: "trace-\(journey)", steps: []),
            expectedMilestoneIDs: expectedMilestones
        )
    }

    private func completedResult(
        journey: String,
        persona: ForgePlaytestPersona,
        extraEvidence: [ForgePlaytestEvidenceReference] = [],
        milestones: [ForgePlaytestMilestoneObservation] = [],
        defects: [ForgePlaytestDefect] = []
    ) throws -> ForgePlaytestJourneyResult {
        let execution = try evidence(.runtimeExecution, receipt: "exec-\(journey)", journey: journey)
        return try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: journey,
            persona: persona,
            traceID: "trace-\(journey)",
            status: .completed,
            evidence: [execution] + extraEvidence,
            milestones: milestones,
            defects: defects
        )
    }

    func testSemanticAxisRejectsNonFiniteAndOutOfRangeValues() throws {
        XCTAssertThrowsError(try ForgePlaytestAction.validatedAxis(controlID: "move-x", value: .infinity))
        XCTAssertThrowsError(try ForgePlaytestAction.validatedAxis(controlID: "move-x", value: 1.01))
        XCTAssertNoThrow(try ForgePlaytestAction.validatedAxis(controlID: "move-x", value: -1.0))
    }

    func testPointerCoordinatesAreNormalizedUnitSpace() throws {
        XCTAssertThrowsError(
            try ForgePlaytestAction.validatedPointer(controlID: "aim", x: -0.01, y: 0.5, phase: .move)
        )
        XCTAssertNoThrow(
            try ForgePlaytestAction.validatedPointer(controlID: "aim", x: 0.25, y: 1.0, phase: .move)
        )
    }

    func testTraceRequiresContiguousSequenceAndMonotonicTicks() throws {
        let wait = try ForgePlaytestStep(sequence: 0, tick: 3, action: .wait)
        let backwards = try ForgePlaytestStep(sequence: 1, tick: 2, action: .wait)
        XCTAssertThrowsError(try ForgePlaytestTrace(traceID: "t", steps: [wait, backwards])) {
            XCTAssertEqual($0 as? ForgePlaytestError, .invalidStepTick)
        }

        let wrongSequence = try ForgePlaytestStep(sequence: 2, tick: 4, action: .wait)
        XCTAssertThrowsError(try ForgePlaytestTrace(traceID: "t", steps: [wait, wrongSequence])) {
            XCTAssertEqual($0 as? ForgePlaytestError, .invalidStepSequence)
        }
    }

    func testTraceIsBoundedByDurationAndStepCount() throws {
        let tooLate = try ForgePlaytestStep(
            sequence: 0,
            tick: 60 * ForgePlaytestTrace.maximumDurationSeconds + 1,
            action: .wait
        )
        XCTAssertThrowsError(try ForgePlaytestTrace(traceID: "late", tickRateHz: 60, steps: [tooLate]))

        let steps = try (0 ... ForgePlaytestTrace.maximumSteps).map {
            try ForgePlaytestStep(sequence: $0, tick: UInt64($0), action: .wait)
        }
        XCTAssertThrowsError(try ForgePlaytestTrace(traceID: "many", steps: steps))
    }

    func testAllAutonomousPersonasRemainExplicit() {
        XCTAssertEqual(
            Set(ForgePlaytestPersona.allCases),
            Set([
                .goalRunner, .explorer, .chaosTester, .newPlayer,
                .saveReloadTester, .visualReviewer, .performanceRunner, .accessibilityRunner,
            ])
        )
    }

    func testJourneyRejectsEvidenceFromAnotherProjectRevision() throws {
        let wrongRevision = try evidence(
            .runtimeExecution,
            receipt: "exec",
            journey: "goal",
            revision: "rev-6"
        )
        XCTAssertThrowsError(
            try ForgePlaytestJourneyResult(
                project: project(),
                journeyID: "goal",
                persona: .goalRunner,
                traceID: "trace",
                status: .completed,
                evidence: [wrongRevision]
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .sourceRevisionMismatch)
        }
    }

    func testMilestonesMustBeBackedByKnownEvidenceReceipt() throws {
        let milestone = try ForgePlaytestMilestoneObservation(
            milestoneID: "win",
            evidenceReceiptIDs: ["missing-receipt"]
        )
        XCTAssertThrowsError(
            try ForgePlaytestJourneyResult(
                project: project(),
                journeyID: "goal",
                persona: .goalRunner,
                traceID: "trace",
                status: .completed,
                evidence: [try evidence(.runtimeExecution, receipt: "exec", journey: "goal")],
                milestones: [milestone]
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .unknownReceiptReference("missing-receipt"))
        }
    }

    func testDefectsMustBeBackedByKnownEvidenceReceipt() throws {
        let defect = try ForgePlaytestDefect(
            defectID: "d1",
            severity: .high,
            category: .functional,
            summary: "Goal cannot be reached",
            evidenceReceiptIDs: ["runtime-log"]
        )
        XCTAssertThrowsError(
            try ForgePlaytestJourneyResult(
                project: project(),
                journeyID: "goal",
                persona: .goalRunner,
                traceID: "trace",
                status: .completed,
                evidence: [try evidence(.runtimeExecution, receipt: "exec", journey: "goal")],
                defects: [defect]
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .unknownReceiptReference("runtime-log"))
        }
    }

    func testPolicyCannotDropRuntimeExecutionEvidence() throws {
        XCTAssertThrowsError(
            try ForgePlaytestPersonaRequirement(
                persona: .visualReviewer,
                requiredEvidenceKinds: [.screenshot]
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .invalidEvidenceRequirement)
        }
    }

    func testMissingRequiredPersonaBlocksAcceptance() throws {
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
            try ForgePlaytestPersonaRequirement(persona: .newPlayer),
        ])
        let verdict = try ForgePlaytestGateEvaluator.evaluate(
            project: project(),
            policy: policy,
            plans: [try plan(journey: "goal", persona: .goalRunner)],
            results: [try completedResult(journey: "goal", persona: .goalRunner)]
        )
        XCTAssertEqual(verdict, .blocked([
            .missingCompletedJourneys(persona: .newPlayer, required: 1, actual: 0),
        ]))
    }

    func testInterruptedJourneyDoesNotCountAsCompletedEvidence() throws {
        let exec = try evidence(.runtimeExecution, receipt: "exec", journey: "goal")
        let interrupted = try ForgePlaytestJourneyResult(
            project: project(),
            journeyID: "goal",
            persona: .goalRunner,
            traceID: "trace-goal",
            status: .interrupted,
            evidence: [exec]
        )
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])
        XCTAssertEqual(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy,
                plans: [try plan(journey: "goal", persona: .goalRunner)],
                results: [interrupted]
            ),
            .blocked([.missingCompletedJourneys(persona: .goalRunner, required: 1, actual: 0)])
        )
    }

    func testVisualPersonaRequiresActualVisualEvidenceWhenPolicySaysSo() throws {
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(
                persona: .visualReviewer,
                requiredEvidenceKinds: [.runtimeExecution, .screenshot, .visualComparison]
            ),
        ])
        let onlyScreenshot = try evidence(.screenshot, receipt: "shot", journey: "visual")
        let result = try completedResult(
            journey: "visual",
            persona: .visualReviewer,
            extraEvidence: [onlyScreenshot]
        )
        XCTAssertEqual(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy,
                plans: [try plan(journey: "visual", persona: .visualReviewer)],
                results: [result]
            ),
            .blocked([.missingEvidence(persona: .visualReviewer, kind: .visualComparison)])
        )
    }

    func testSaveReloadMilestoneMustBeReceiptedAndReached() throws {
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(
                persona: .saveReloadTester,
                requiredEvidenceKinds: [.runtimeExecution, .saveReload],
                requiredMilestoneIDs: ["state-restored"]
            ),
        ])
        let saveEvidence = try evidence(.saveReload, receipt: "save-1", journey: "save")
        let missingMilestone = try completedResult(
            journey: "save",
            persona: .saveReloadTester,
            extraEvidence: [saveEvidence]
        )
        XCTAssertEqual(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy,
                plans: [try plan(journey: "save", persona: .saveReloadTester)],
                results: [missingMilestone]
            ),
            .blocked([.missingMilestone(persona: .saveReloadTester, milestoneID: "state-restored")])
        )
    }

    func testHighDefectRequiresRepairAfterEvidenceRequirementsPass() throws {
        let runtimeLog = try evidence(.runtimeEventLog, receipt: "log-goal", journey: "goal")
        let defect = try ForgePlaytestDefect(
            defectID: "goal-loop-broken",
            severity: .high,
            category: .functional,
            summary: "The win state never appears after the final checkpoint.",
            evidenceReceiptIDs: [runtimeLog.receiptID]
        )
        let result = try completedResult(
            journey: "goal",
            persona: .goalRunner,
            extraEvidence: [runtimeLog],
            defects: [defect]
        )
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])

        XCTAssertEqual(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy,
                plans: [try plan(journey: "goal", persona: .goalRunner)],
                results: [result]
            ),
            .repairRequired([
                ForgePlaytestRepairItem(journeyID: "goal", persona: .goalRunner, defect: defect),
            ])
        )
    }

    func testRepairQueueOrdersCriticalBeforeHighDeterministically() throws {
        let logA = try evidence(.runtimeEventLog, receipt: "log-a", journey: "a")
        let logB = try evidence(.runtimeEventLog, receipt: "log-b", journey: "b")
        let high = try ForgePlaytestDefect(
            defectID: "high",
            severity: .high,
            category: .controls,
            summary: "Primary action is unreachable.",
            evidenceReceiptIDs: [logA.receiptID]
        )
        let critical = try ForgePlaytestDefect(
            defectID: "critical",
            severity: .critical,
            category: .runtime,
            summary: "Runtime terminates during the journey.",
            evidenceReceiptIDs: [logB.receiptID]
        )
        let a = try completedResult(journey: "a", persona: .goalRunner, extraEvidence: [logA], defects: [high])
        let b = try completedResult(journey: "b", persona: .goalRunner, extraEvidence: [logB], defects: [critical])
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])

        guard case let .repairRequired(items) = try ForgePlaytestGateEvaluator.evaluate(
            project: project(),
            policy: policy,
            plans: [
                try plan(journey: "a", persona: .goalRunner),
                try plan(journey: "b", persona: .goalRunner),
            ],
            results: [a, b]
        ) else {
            return XCTFail("Expected repairRequired")
        }
        XCTAssertEqual(items.map(\.defect.defectID), ["critical", "high"])
    }

    func testMediumDefectDoesNotViolateDefaultNoHighCriticalGate() throws {
        let log = try evidence(.runtimeEventLog, receipt: "log", journey: "goal")
        let medium = try ForgePlaytestDefect(
            defectID: "medium",
            severity: .medium,
            category: .visual,
            summary: "Minor spacing inconsistency remains.",
            evidenceReceiptIDs: [log.receiptID]
        )
        let result = try completedResult(
            journey: "goal",
            persona: .goalRunner,
            extraEvidence: [log],
            defects: [medium]
        )
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])
        guard case .accepted = try ForgePlaytestGateEvaluator.evaluate(
            project: project(),
            policy: policy,
            plans: [try plan(journey: "goal", persona: .goalRunner)],
            results: [result]
        ) else {
            return XCTFail("Expected playtest gate acceptance")
        }
    }

    func testGateRejectsMixedProjectRevisionsEvenWhenEvidenceLooksComplete() throws {
        let good = try completedResult(journey: "good", persona: .goalRunner)
        let foreign = try ForgePlaytestJourneyResult(
            project: project("rev-8"),
            journeyID: "foreign",
            persona: .explorer,
            traceID: "trace-foreign",
            status: .completed,
            evidence: [try evidence(.runtimeExecution, receipt: "exec-foreign", journey: "foreign", revision: "rev-8")]
        )
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])
        XCTAssertThrowsError(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy,
                plans: [
                    try plan(journey: "good", persona: .goalRunner),
                    try plan(journey: "foreign", persona: .explorer, revision: "rev-8"),
                ],
                results: [good, foreign]
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .sourceRevisionMismatch)
        }
    }

    func testGateRejectsDuplicateJourneyIdentity() throws {
        let first = try completedResult(journey: "same", persona: .goalRunner)
        let second = try completedResult(journey: "same", persona: .goalRunner)
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])
        XCTAssertThrowsError(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy,
                plans: [try plan(journey: "same", persona: .goalRunner)],
                results: [first, second]
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .duplicateJourneyID("same"))
        }
    }

    func testAcceptedProjectionContainsOnlyReceiptsFromRequiredAcceptedJourneys() throws {
        let screenshot = try evidence(.screenshot, receipt: "shot", journey: "visual")
        let comparison = try evidence(.visualComparison, receipt: "compare", journey: "visual")
        let visual = try completedResult(
            journey: "visual",
            persona: .visualReviewer,
            extraEvidence: [screenshot, comparison]
        )
        let optional = try completedResult(journey: "optional-explorer", persona: .explorer)
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(
                persona: .visualReviewer,
                requiredEvidenceKinds: [.runtimeExecution, .screenshot, .visualComparison]
            ),
        ])

        guard case let .accepted(projection) = try ForgePlaytestGateEvaluator.evaluate(
            project: project(),
            policy: policy,
            plans: [
                try plan(journey: "optional-explorer", persona: .explorer),
                try plan(journey: "visual", persona: .visualReviewer),
            ],
            results: [optional, visual]
        ) else {
            return XCTFail("Expected accepted projection")
        }

        XCTAssertEqual(projection.project, try project())
        XCTAssertEqual(projection.acceptedJourneyIDs, ["visual"])
        XCTAssertEqual(projection.contributingReceiptIDs, ["compare", "exec-visual", "shot"])
        XCTAssertFalse(projection.contributingReceiptIDs.contains("exec-optional-explorer"))
    }

    func testCompletedJourneyCannotExistWithoutRuntimeExecutionReceipt() throws {
        XCTAssertThrowsError(
            try ForgePlaytestJourneyResult(
                project: project(),
                journeyID: "goal",
                persona: .goalRunner,
                traceID: "trace-goal",
                status: .completed,
                evidence: [try evidence(.runtimeState, receipt: "state", journey: "goal")]
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .completedJourneyMissingRuntimeExecution)
        }
    }

    func testResultMustBindExactPlannedPersonaAndTrace() throws {
        let result = try completedResult(journey: "goal", persona: .goalRunner)
        let wrongPersonaPlan = try ForgePlaytestJourneyPlan(
            journeyID: "goal",
            project: project(),
            persona: .explorer,
            trace: ForgePlaytestTrace(traceID: "trace-goal", steps: [])
        )
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])
        XCTAssertThrowsError(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(), policy: policy, plans: [wrongPersonaPlan], results: [result]
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .personaMismatch)
        }

        let wrongTracePlan = try ForgePlaytestJourneyPlan(
            journeyID: "goal",
            project: project(),
            persona: .goalRunner,
            trace: ForgePlaytestTrace(traceID: "different-trace", steps: [])
        )
        XCTAssertThrowsError(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(), policy: policy, plans: [wrongTracePlan], results: [result]
            )
        ) {
            XCTAssertEqual($0 as? ForgePlaytestError, .traceMismatch)
        }
    }

    func testPlannedMilestoneCannotBeSilentlyDroppedFromAcceptance() throws {
        let result = try completedResult(journey: "goal", persona: .goalRunner)
        let policy = try ForgePlaytestAcceptancePolicy(requirements: [
            try ForgePlaytestPersonaRequirement(persona: .goalRunner),
        ])
        XCTAssertEqual(
            try ForgePlaytestGateEvaluator.evaluate(
                project: project(),
                policy: policy,
                plans: [try plan(journey: "goal", persona: .goalRunner, expectedMilestones: ["win"])],
                results: [result]
            ),
            .blocked([.missingMilestone(persona: .goalRunner, milestoneID: "win")])
        )
    }

    func testEightPersonaEvidenceBackedAcceptancePacket() throws {
        let requirements = try ForgePlaytestPersona.allCases.map { persona in
            var kinds: Set<ForgePlaytestEvidenceKind> = [.runtimeExecution]
            switch persona {
            case .saveReloadTester: kinds.insert(.saveReload)
            case .visualReviewer: kinds.formUnion([.screenshot, .visualComparison])
            case .performanceRunner: kinds.insert(.performanceSample)
            case .accessibilityRunner: kinds.insert(.accessibilityAudit)
            default: kinds.insert(.runtimeState)
            }
            return try ForgePlaytestPersonaRequirement(persona: persona, requiredEvidenceKinds: kinds)
        }
        let policy = try ForgePlaytestAcceptancePolicy(requirements: requirements)

        let results = try ForgePlaytestPersona.allCases.enumerated().map { index, persona in
            let journey = "journey-\(index)-\(persona.rawValue)"
            let kind: ForgePlaytestEvidenceKind
            switch persona {
            case .saveReloadTester: kind = .saveReload
            case .visualReviewer: kind = .screenshot
            case .performanceRunner: kind = .performanceSample
            case .accessibilityRunner: kind = .accessibilityAudit
            default: kind = .runtimeState
            }
            var extra = [try evidence(kind, receipt: "evidence-\(index)", journey: journey)]
            if persona == .visualReviewer {
                extra.append(try evidence(.visualComparison, receipt: "compare-\(index)", journey: journey))
            }
            return try completedResult(journey: journey, persona: persona, extraEvidence: extra)
        }

        guard case let .accepted(projection) = try ForgePlaytestGateEvaluator.evaluate(
            project: project(),
            policy: policy,
            plans: try results.map { try plan(journey: $0.journeyID, persona: $0.persona) },
            results: results
        ) else {
            return XCTFail("Expected full persona acceptance")
        }
        XCTAssertEqual(projection.acceptedJourneyIDs.count, ForgePlaytestPersona.allCases.count)
        XCTAssertTrue(projection.contributingReceiptIDs.contains("compare-5"))
    }
}
