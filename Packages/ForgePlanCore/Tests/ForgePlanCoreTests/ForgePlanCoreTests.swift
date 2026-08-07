import XCTest
@testable import ForgePlanCore

final class ForgePlanCoreTests: XCTestCase {
    func testInferableQuestionsStayOutOfPlanSpaceAndDoNotBlockForge() {
        let proposal = PlanSpaceProposal(
            intentSummary: "Open-world scooter game",
            questions: [
                PlanQuestion(
                    id: "camera",
                    prompt: "Camera",
                    importance: .material,
                    controlKind: .segmentedChoice,
                    options: [
                        .init(id: "first", label: "First"),
                        .init(id: "third", label: "Third")
                    ]
                ),
                PlanQuestion(
                    id: "internal-name",
                    prompt: "Internal project slug",
                    importance: .inferable,
                    controlKind: .freeText
                )
            ]
        )

        XCTAssertEqual(proposal.presentedQuestions.map(\.id), ["camera"])
        XCTAssertTrue(proposal.isReadyToForge(answers: ["camera": .choice("first")]))
    }

    func testDecideForMeResolvesMaterialQuestionWithoutInventingAnAnswer() {
        let proposal = PlanSpaceProposal(
            intentSummary: "Driving game",
            questions: [
                PlanQuestion(
                    id: "world-feel",
                    prompt: "World feel",
                    controlKind: .segmentedChoice,
                    options: [
                        .init(id: "realistic", label: "Realistic"),
                        .init(id: "arcade", label: "Arcade")
                    ]
                )
            ]
        )

        XCTAssertTrue(proposal.isReadyToForge(answers: ["world-feel": .decideForMe]))
        XCTAssertEqual(PlanAnswer.decideForMe, PlanAnswer.decideForMe)
    }

    func testInvalidChoiceKeepsPlanSpaceUnresolved() {
        let question = PlanQuestion(
            id: "orientation",
            prompt: "Orientation",
            controlKind: .orientation,
            options: [
                .init(id: "portrait", label: "Portrait"),
                .init(id: "landscape", label: "Landscape")
            ]
        )
        let proposal = PlanSpaceProposal(intentSummary: "Utility", questions: [question])

        XCTAssertFalse(proposal.isReadyToForge(answers: ["orientation": .choice("diagonal")]))
        XCTAssertEqual(proposal.unresolvedQuestionIDs(answers: ["orientation": .choice("diagonal")]), ["orientation"])
    }

    func testNumericAnswersMustStayInsideDeclaredRange() {
        let question = PlanQuestion(
            id: "detail",
            prompt: "Detail",
            controlKind: .slider,
            range: .init(minimum: 0, maximum: 10, step: 1)
        )

        XCTAssertTrue(question.accepts(.scalar(7)))
        XCTAssertFalse(question.accepts(.scalar(7.5)))
        XCTAssertFalse(question.accepts(.scalar(11)))
    }

    func testMalformedQuestionSchemaFailsClosed() {
        let malformed = PlanQuestion(
            id: "camera",
            prompt: "Camera",
            controlKind: .segmentedChoice,
            options: [.init(id: "first", label: "First")]
        )
        let proposal = PlanSpaceProposal(intentSummary: "Game", questions: [malformed])

        XCTAssertFalse(proposal.schemaValidationIssues.isEmpty)
        XCTAssertFalse(proposal.isReadyToForge(answers: ["camera": .choice("first")]))
    }

    func testForgeControlsClampNormalizedValues() {
        XCTAssertEqual(NormalizedForgeControl(-4).value, 0)
        XCTAssertEqual(NormalizedForgeControl(4).value, 1)
        XCTAssertEqual(NormalizedForgeControl(0.42).value, 0.42)
        XCTAssertEqual(NormalizedForgeControl(.nan).value, 0.5)
    }

    func testIntelligenceNeverClaimsNativeReasoningWhenProviderDoesNotSupportIt() {
        let unsupported = ForgeIntelligence.extreme.resolve(
            providerCapabilities: .init(supportsNativeReasoning: false)
        )
        let supported = ForgeIntelligence.deep.resolve(
            providerCapabilities: .init(supportsNativeReasoning: true)
        )

        XCTAssertEqual(unsupported.orchestrationDepth, .extreme)
        XCTAssertNil(unsupported.nativeReasoningPreference)
        XCTAssertEqual(supported.orchestrationDepth, .deep)
        XCTAssertEqual(supported.nativeReasoningPreference, 0.75)
    }

    func testPrimaryActionMorphingIsPresentationOnlyAndDeterministic() {
        XCTAssertEqual(ForgePrimaryActionState.composing.primaryAction, .send)
        XCTAssertEqual(ForgePrimaryActionState.waitingForPlanDecision.primaryAction, .plan)
        XCTAssertEqual(ForgePrimaryActionState.readyToForge.primaryAction, .forge)
        XCTAssertEqual(ForgePrimaryActionState.missionRunning.primaryAction, .pause)
        XCTAssertEqual(ForgePrimaryActionState.missionPaused.primaryAction, .resume)
        XCTAssertEqual(ForgePrimaryActionState.missionComplete(runnable: true).primaryAction, .run)
        XCTAssertEqual(ForgePrimaryActionState.missionComplete(runnable: false).primaryAction, .forge)
    }

    func testPlanAnswerRoundTripsThroughCodable() throws {
        let original: [PlanAnswer] = [
            .choice("landscape"),
            .scalar(0.8),
            .interval(lower: 2, upper: 8),
            .text("Keep it minimal"),
            .decideForMe
        ]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([PlanAnswer].self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testReadySummaryPreservesSelectionsAndDelegationWithoutGuessing() throws {
        let proposal = PlanSpaceProposal(
            intentSummary: "Open-world scooter game",
            questions: [
                PlanQuestion(
                    id: "camera",
                    prompt: "Camera",
                    controlKind: .segmentedChoice,
                    options: [
                        .init(id: "first", label: "First person"),
                        .init(id: "third", label: "Third person")
                    ]
                ),
                PlanQuestion(
                    id: "world-feel",
                    prompt: "World feel",
                    controlKind: .segmentedChoice,
                    options: [
                        .init(id: "sim", label: "Simulation"),
                        .init(id: "arcade", label: "Arcade")
                    ]
                )
            ]
        )

        let summary = try XCTUnwrap(proposal.readySummary(answers: [
            "camera": .choice("first"),
            "world-feel": .decideForMe
        ]))

        XCTAssertEqual(summary.intentSummary, "Open-world scooter game")
        XCTAssertEqual(summary.decisions[0].value, .selected(optionID: "first", label: "First person"))
        XCTAssertEqual(summary.decisions[1].value, .delegatedToNovaForge)
    }

    func testReadySummaryDoesNotExistWhileMaterialDecisionIsUnresolved() {
        let proposal = PlanSpaceProposal(
            intentSummary: "Utility",
            questions: [
                PlanQuestion(id: "name", prompt: "Name", controlKind: .freeText)
            ]
        )

        XCTAssertNil(proposal.readySummary(answers: [:]))
    }

    func testDuplicateQuestionIDsFailClosed() {
        let first = PlanQuestion(id: "camera", prompt: "Camera", controlKind: .freeText)
        let second = PlanQuestion(id: "camera", prompt: "Camera style", controlKind: .freeText)
        let proposal = PlanSpaceProposal(intentSummary: "Game", questions: [first, second])

        XCTAssertTrue(proposal.schemaValidationIssues.contains(.duplicateQuestionID("camera")))
        XCTAssertFalse(proposal.isReadyToForge(answers: ["camera": .text("first person")]))
    }
}
