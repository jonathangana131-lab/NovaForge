import XCTest
import ForgePlanCore
@testable import ForgePlanMissionAdapter

final class ForgePlanMissionAdapterTests: XCTestCase {
    private func context(
        handoffRevision: UInt64 = 7,
        receiptID: String = "plan-accept-7"
    ) throws -> ForgePlanMissionContext {
        try .init(
            handoffRevision: handoffRevision,
            planAcceptanceReceiptID: receiptID
        )
    }

    private func sourceBinding(
        composerDraftRevision: UInt64 = 11,
        planRevision: UInt64 = 4,
        planReferenceID: String = "plan-space-4"
    ) throws -> ForgePlanMissionSourceBinding {
        try .init(
            composerDraftRevision: composerDraftRevision,
            planRevision: planRevision,
            planReferenceID: planReferenceID
        )
    }

    private func controls(
        intelligence: ForgeComposerIntelligenceIntent = .automatic,
        buildDepth: ForgeComposerBuildDepthIntent = .complete,
        creativity: Double = 0.45,
        refactorRisk: Double = 0.25,
        autonomy: ForgeComposerAutonomyIntent = .collaborate,
        privacy: ForgeComposerPrivacyIntent = .localOnly
    ) throws -> ForgeComposerV14ControlProfile {
        try .validated(
            intelligence: intelligence,
            buildDepth: buildDepth,
            creativity: .init(creativity),
            refactorRisk: .init(refactorRisk),
            autonomy: autonomy,
            privacy: privacy
        )
    }

    private func proposal(
        profile: ForgeComposerV14ControlProfile? = nil,
        questions: [PlanQuestion] = [],
        intentSummary: String = "Build a calm local-first timer"
    ) throws -> PlanSpaceProposal {
        let resolvedProfile: ForgeComposerV14ControlProfile
        if let profile {
            resolvedProfile = profile
        } else {
            resolvedProfile = try controls()
        }
        return .init(
            intentSummary: intentSummary,
            questions: questions,
            controls: resolvedProfile
        )
    }

    private func choiceQuestion(
        id: String = "theme",
        prompt: String = "Theme?",
        allowsDecideForMe: Bool = true
    ) -> PlanQuestion {
        .init(
            id: id,
            prompt: prompt,
            reason: "Material design decision",
            importance: .material,
            controlKind: .segmentedChoice,
            options: [
                .init(id: "dark", label: "Dark", detail: "Dark surfaces", previewToken: "preview-dark"),
                .init(id: "light", label: "Light", detail: "Light surfaces", previewToken: "preview-light"),
            ],
            placeholder: "Choose a theme",
            allowsDecideForMe: allowsDecideForMe
        )
    }

    private func sliderQuestion(id: String = "density") -> PlanQuestion {
        .init(
            id: id,
            prompt: "Interface density?",
            reason: "Changes layout density",
            importance: .material,
            controlKind: .slider,
            range: .init(
                minimum: 0,
                maximum: 1,
                step: 0.25,
                lowLabel: "Airy",
                highLabel: "Dense"
            ),
            allowsDecideForMe: true
        )
    }

    private func makeHandoff(
        proposal: PlanSpaceProposal,
        answers: [String: PlanAnswer] = [:],
        context: ForgePlanMissionContext? = nil,
        sourceBinding: ForgePlanMissionSourceBinding? = nil
    ) throws -> ForgePlanMissionHandoff {
        let resolvedContext: ForgePlanMissionContext
        if let context {
            resolvedContext = context
        } else {
            resolvedContext = try self.context()
        }

        let resolvedSourceBinding: ForgePlanMissionSourceBinding
        if let sourceBinding {
            resolvedSourceBinding = sourceBinding
        } else {
            resolvedSourceBinding = try self.sourceBinding()
        }

        return try ForgePlanMissionAdapter.makeHandoff(
            proposal: proposal,
            answers: answers,
            context: resolvedContext,
            sourceBinding: resolvedSourceBinding
        )
    }

    func testLocalOnlyAndFullForgeSurviveAsTypedMissionEraRequirements() throws {
        let profile = try controls(
            buildDepth: .obsessive,
            creativity: 0.8,
            refactorRisk: 0.1,
            autonomy: .fullForge,
            privacy: .localOnly
        )
        let handoff = try makeHandoff(proposal: proposal(profile: profile))
        let binding = try sourceBinding()

        XCTAssertEqual(handoff.revision, 7)
        XCTAssertEqual(handoff.intentSummary, "Build a calm local-first timer")
        XCTAssertEqual(handoff.planAcceptanceReceiptID, "plan-accept-7")
        XCTAssertEqual(handoff.controlProfile, profile)
        XCTAssertEqual(handoff.controlProfile.buildDepth, .obsessive)
        XCTAssertEqual(handoff.controlProfile.creativity.value, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(handoff.controlProfile.refactorRisk.value, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(handoff.privacyIntent, .localOnly)
        XCTAssertEqual(handoff.autonomyIntent, .fullForge)
        XCTAssertEqual(handoff.sourceBinding, binding)
        XCTAssertFalse(handoff.authorizesExecution)

        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .composerPlanRevisionMatch(binding: binding)
            )
        )
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .acceptedPlanSubjectVerification(
                    receiptID: "plan-accept-7",
                    subject: handoff.acceptedPlanSubject
                )
            )
        )
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .missionControlEnvelopeBinding(envelope: handoff.controlEnvelope)
            )
        )
        XCTAssertTrue(handoff.executionPreconditions.contains(.localOnlyRouting))
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .autonomyPolicyResolution(intent: .fullForge)
            )
        )
        XCTAssertFalse(handoff.requiresExternalModelQualification)
        XCTAssertFalse(handoff.requiresDelegatedDecisionResolution)
    }

    func testReceiptRequirementBindsTheWholeAcceptedSubject() throws {
        let plan = try proposal()
        let handoff = try makeHandoff(proposal: plan)

        XCTAssertEqual(handoff.acceptedPlanSubject.proposal, plan)
        XCTAssertEqual(handoff.acceptedPlanSubject.acceptedAnswers, [])
        XCTAssertEqual(handoff.acceptedPlanSubject.summary.intentSummary, plan.intentSummary)
        XCTAssertEqual(handoff.acceptedPlanSubject.composerPlanBinding, try sourceBinding())
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .acceptedPlanSubjectVerification(
                    receiptID: "plan-accept-7",
                    subject: handoff.acceptedPlanSubject
                )
            )
        )
    }

    func testSameReceiptCannotMakeChangedPrivacyStructurallyIndistinguishable() throws {
        let localHandoff = try makeHandoff(
            proposal: proposal(profile: controls(privacy: .localOnly))
        )
        let hostedPrivacy = try ForgeComposerPrivacyIntent.providers(["openai", "anthropic"])
        let hostedHandoff = try makeHandoff(
            proposal: proposal(profile: controls(privacy: hostedPrivacy))
        )

        XCTAssertEqual(localHandoff.planAcceptanceReceiptID, hostedHandoff.planAcceptanceReceiptID)
        XCTAssertNotEqual(localHandoff.acceptedPlanSubject, hostedHandoff.acceptedPlanSubject)
        XCTAssertNotEqual(
            localHandoff.executionPreconditions[1],
            hostedHandoff.executionPreconditions[1]
        )
    }

    func testSameReceiptCannotMakeChangedDecisionStructurallyIndistinguishable() throws {
        let question = choiceQuestion()
        let plan = try proposal(questions: [question])
        let dark = try makeHandoff(proposal: plan, answers: ["theme": .choice("dark")])
        let light = try makeHandoff(proposal: plan, answers: ["theme": .choice("light")])

        XCTAssertEqual(dark.planAcceptanceReceiptID, light.planAcceptanceReceiptID)
        XCTAssertNotEqual(dark.acceptedPlanSubject, light.acceptedPlanSubject)
        XCTAssertEqual(dark.planDecisions.first?.value, .selected(optionID: "dark", label: "Dark"))
        XCTAssertEqual(light.planDecisions.first?.value, .selected(optionID: "light", label: "Light"))
    }

    func testSameReceiptCannotMakeChangedComposerPlanBindingIndistinguishable() throws {
        let plan = try proposal()
        let first = try makeHandoff(
            proposal: plan,
            sourceBinding: sourceBinding(planRevision: 4)
        )
        let second = try makeHandoff(
            proposal: plan,
            sourceBinding: sourceBinding(planRevision: 5)
        )

        XCTAssertEqual(first.planAcceptanceReceiptID, second.planAcceptanceReceiptID)
        XCTAssertNotEqual(first.acceptedPlanSubject, second.acceptedPlanSubject)
        XCTAssertNotEqual(first.controlEnvelope, second.controlEnvelope)
    }

    func testProviderAllowlistRemainsExactAndRequiresEnforcement() throws {
        let privacy = try ForgeComposerPrivacyIntent.providers(["openai", "anthropic"])
        let profile = try controls(privacy: privacy)
        let handoff = try makeHandoff(proposal: proposal(profile: profile))

        XCTAssertEqual(handoff.privacyIntent, try .providers(["anthropic", "openai"]))
        XCTAssertTrue(handoff.privacyIntent.allowsProvider("openai"))
        XCTAssertTrue(handoff.privacyIntent.allowsProvider("anthropic"))
        XCTAssertFalse(handoff.privacyIntent.allowsProvider("other-cloud"))
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .providerAllowlistEnforcement(providerIDs: ["anthropic", "openai"])
            )
        )
        XCTAssertFalse(handoff.executionPreconditions.contains(.localOnlyRouting))
    }

    func testExplicitModelReferenceCreatesQualificationPrecondition() throws {
        let modelIntent = try ForgeComposerIntelligenceIntent.explicit(
            referenceID: "model.local.qwen35-4b"
        )
        let profile = try controls(intelligence: modelIntent)
        let handoff = try makeHandoff(proposal: proposal(profile: profile))

        XCTAssertTrue(handoff.requiresExternalModelQualification)
        XCTAssertEqual(handoff.requestedExplicitModelReferenceID, "model.local.qwen35-4b")
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .explicitModelQualification(referenceID: "model.local.qwen35-4b")
            )
        )
        XCTAssertEqual(handoff.controlProfile.intelligence, modelIntent)
    }

    func testDelegatedChoicePreservesExactQuestionContractAndRejectsOutOfSchemaResolution() throws {
        let question = choiceQuestion(id: "storage", prompt: "Which storage approach?")
        let handoff = try makeHandoff(
            proposal: proposal(questions: [question]),
            answers: ["storage": .decideForMe]
        )

        XCTAssertEqual(handoff.delegatedDecisionIDs, ["storage"])
        XCTAssertTrue(handoff.requiresDelegatedDecisionResolution)
        XCTAssertEqual(handoff.delegatedDecisionContracts.count, 1)

        let contract = try XCTUnwrap(handoff.delegatedDecisionContracts.first)
        XCTAssertEqual(contract.question, question)
        XCTAssertEqual(contract.question.reason, "Material design decision")
        XCTAssertEqual(contract.question.controlKind, .segmentedChoice)
        XCTAssertEqual(contract.question.options.map(\.id), ["dark", "light"])
        XCTAssertTrue(contract.acceptsConcreteResolution(.choice("dark")))
        XCTAssertFalse(contract.acceptsConcreteResolution(.choice("other")))
        XCTAssertFalse(contract.acceptsConcreteResolution(.decideForMe))

        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .delegatedDecisionResolution(contract: contract)
            )
        )
    }

    func testDelegatedNumericContractEnforcesRangeAndStep() throws {
        let question = sliderQuestion()
        let handoff = try makeHandoff(
            proposal: proposal(questions: [question]),
            answers: ["density": .decideForMe]
        )

        let contract = try XCTUnwrap(handoff.delegatedDecisionContracts.first)
        XCTAssertEqual(contract.question.range, question.range)
        XCTAssertTrue(contract.acceptsConcreteResolution(.scalar(0.5)))
        XCTAssertFalse(contract.acceptsConcreteResolution(.scalar(0.6)))
        XCTAssertFalse(contract.acceptsConcreteResolution(.scalar(2)))
        XCTAssertFalse(contract.acceptsConcreteResolution(.text("0.5")))
    }

    func testExplicitModelFullForgeAndDelegationRemainSeparateRequirements() throws {
        let profile = try controls(
            intelligence: try .explicit(referenceID: "model.deep.local"),
            autonomy: .fullForge
        )
        let question = choiceQuestion(id: "physics", prompt: "Choose handling style")
        let handoff = try makeHandoff(
            proposal: proposal(profile: profile, questions: [question]),
            answers: ["physics": .decideForMe]
        )

        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .autonomyPolicyResolution(intent: .fullForge)
            )
        )
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .explicitModelQualification(referenceID: "model.deep.local")
            )
        )
        XCTAssertEqual(handoff.delegatedDecisionIDs, ["physics"])
        XCTAssertEqual(handoff.autonomyIntent, .fullForge)
        XCTAssertEqual(handoff.controlEnvelope.controlProfile, profile)
    }

    func testConcreteDecisionRemainsStructuredAndDoesNotBecomeDelegated() throws {
        let question = choiceQuestion()
        let handoff = try makeHandoff(
            proposal: proposal(questions: [question]),
            answers: ["theme": .choice("dark")]
        )

        XCTAssertEqual(
            handoff.planDecisions,
            [
                .init(
                    id: "theme",
                    prompt: "Theme?",
                    value: .selected(optionID: "dark", label: "Dark")
                )
            ]
        )
        XCTAssertFalse(handoff.requiresDelegatedDecisionResolution)
        XCTAssertTrue(handoff.delegatedDecisionContracts.isEmpty)
    }

    func testBlankProposalIntentFailsClosed() throws {
        let bad = try proposal(intentSummary: "  ")
        XCTAssertThrowsError(try makeHandoff(proposal: bad)) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidSummary("intentSummary")
            )
        }
    }

    func testPresentedAnswerSetMustBeExact() throws {
        let question = choiceQuestion()
        let plan = try proposal(questions: [question])

        XCTAssertThrowsError(try makeHandoff(proposal: plan, answers: [:])) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidAcceptedPlan("presentedAnswerSet")
            )
        }

        XCTAssertThrowsError(
            try makeHandoff(
                proposal: plan,
                answers: [
                    "theme": .choice("dark"),
                    "invented": .text("not part of plan"),
                ]
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidAcceptedPlan("presentedAnswerSet")
            )
        }
    }

    func testDecideForMeFailsWhenQuestionDoesNotPermitDelegation() throws {
        let question = choiceQuestion(allowsDecideForMe: false)
        let plan = try proposal(questions: [question])

        XCTAssertThrowsError(
            try makeHandoff(proposal: plan, answers: ["theme": .decideForMe])
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidAcceptedPlan("answers")
            )
        }
    }

    func testNonFiniteAnswerFailsBeforeHandoff() throws {
        let plan = try proposal(questions: [sliderQuestion()])
        XCTAssertThrowsError(
            try makeHandoff(proposal: plan, answers: ["density": .scalar(.infinity)])
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidAcceptedPlan("answers")
            )
        }
    }

    func testQuestionContractRejectsControlCharactersAndExcessCount() throws {
        let badQuestion = PlanQuestion(
            id: "bad",
            prompt: "Bad\u{0000}",
            controlKind: .freeText
        )
        XCTAssertThrowsError(
            try makeHandoff(
                proposal: proposal(questions: [badQuestion]),
                answers: ["bad": .text("value")]
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidPlanQuestion("bad")
            )
        }

        let questions = (0..<129).map { index in
            PlanQuestion(
                id: "q-\(index)",
                prompt: "Question \(index)?",
                importance: .inferable,
                controlKind: .freeText
            )
        }
        XCTAssertThrowsError(
            try makeHandoff(proposal: proposal(questions: questions))
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidSummary("tooManyQuestions")
            )
        }
    }

    func testTextAllowsNewlinesButRejectsOtherControlCharacters() throws {
        let question = PlanQuestion(
            id: "notes",
            prompt: "Notes?",
            controlKind: .freeText
        )
        let plan = try proposal(questions: [question])

        XCTAssertNoThrow(
            try makeHandoff(
                proposal: plan,
                answers: ["notes": .text("line one\nline two")]
            )
        )

        XCTAssertThrowsError(
            try makeHandoff(
                proposal: plan,
                answers: ["notes": .text("nope\u{0000}")]
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidDecision("notes")
            )
        }
    }

    func testContextRejectsNonCanonicalReceiptIDAndZeroRevision() throws {
        XCTAssertThrowsError(
            try ForgePlanMissionContext(
                handoffRevision: 0,
                planAcceptanceReceiptID: "ok"
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidContext("handoffRevision")
            )
        }
        XCTAssertThrowsError(
            try ForgePlanMissionContext(
                handoffRevision: 1,
                planAcceptanceReceiptID: " padded "
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidContext("planAcceptanceReceiptID")
            )
        }
    }

    func testComposerPlanBindingRejectsZeroRevisionAndNonCanonicalReference() throws {
        XCTAssertThrowsError(
            try ForgePlanMissionSourceBinding(
                composerDraftRevision: 0,
                planRevision: 1,
                planReferenceID: "plan-1"
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidSourceBinding("composerDraftRevision")
            )
        }
        XCTAssertThrowsError(
            try ForgePlanMissionSourceBinding(
                composerDraftRevision: 1,
                planRevision: 0,
                planReferenceID: "plan-1"
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidSourceBinding("planRevision")
            )
        }
        XCTAssertThrowsError(
            try ForgePlanMissionSourceBinding(
                composerDraftRevision: 1,
                planRevision: 1,
                planReferenceID: " plan-1 "
            )
        ) {
            XCTAssertEqual(
                $0 as? ForgePlanMissionHandoffError,
                .invalidSourceBinding("planReferenceID")
            )
        }
    }

    func testDecisionAndDelegatedContractOrderingAreCanonical() throws {
        let z = choiceQuestion(id: "z", prompt: "Z")
        let a = choiceQuestion(id: "a", prompt: "A")
        let handoff = try makeHandoff(
            proposal: proposal(questions: [z, a]),
            answers: [
                "z": .decideForMe,
                "a": .decideForMe,
            ]
        )

        XCTAssertEqual(handoff.planDecisions.map(\.id), ["a", "z"])
        XCTAssertEqual(handoff.delegatedDecisionIDs, ["a", "z"])
        XCTAssertEqual(
            handoff.acceptedPlanSubject.acceptedAnswers.map(\.questionID),
            ["a", "z"]
        )
    }
}
