import XCTest
import ForgePlanCore
@testable import ForgePlanMissionAdapter

final class ForgePlanMissionAdapterTests: XCTestCase {
    private func context() throws -> ForgePlanMissionContext {
        try .init(
            handoffRevision: 7,
            planAcceptanceReceiptID: "plan-accept-7"
        )
    }

    private func sourceBinding() throws -> ForgePlanMissionSourceBinding {
        try .init(
            composerDraftRevision: 11,
            planRevision: 4,
            planReferenceID: "plan-space-4"
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

    private func summary(
        profile: ForgeComposerV14ControlProfile? = nil,
        decisions: [PlanResolvedDecision] = [],
        intentSummary: String = "Build a calm local-first timer"
    ) throws -> ReadyToForgeSummary {
        let resolvedProfile: ForgeComposerV14ControlProfile
        if let profile {
            resolvedProfile = profile
        } else {
            resolvedProfile = try controls()
        }
        return .init(
            intentSummary: intentSummary,
            decisions: decisions,
            controls: resolvedProfile
        )
    }

    private func makeHandoff(summary: ReadyToForgeSummary) throws -> ForgePlanMissionHandoff {
        try ForgePlanMissionAdapter.makeHandoff(
            summary: summary,
            context: context(),
            sourceBinding: sourceBinding()
        )
    }

    func testLocalOnlyAndFullForgeSurviveAsTypedRoutingRequirements() throws {
        let profile = try controls(
            buildDepth: .obsessive,
            creativity: 0.8,
            refactorRisk: 0.1,
            autonomy: .fullForge,
            privacy: .localOnly
        )
        let handoff = try makeHandoff(summary: summary(profile: profile))
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
        XCTAssertTrue(handoff.executionPreconditions.contains(.sourceRevisionMatch(binding: binding)))
        XCTAssertTrue(handoff.executionPreconditions.contains(.planAcceptanceVerification(receiptID: "plan-accept-7")))
        XCTAssertTrue(handoff.executionPreconditions.contains(.localOnlyRouting))
        XCTAssertTrue(handoff.executionPreconditions.contains(.autonomyPolicyResolution(intent: .fullForge)))
        XCTAssertFalse(handoff.requiresExternalModelQualification)
        XCTAssertFalse(handoff.requiresDelegatedDecisionResolution)
    }

    func testReceiptAndSourceRevisionRemainVerificationRequirements() throws {
        let binding = try sourceBinding()
        let handoff = try makeHandoff(summary: summary())

        XCTAssertEqual(handoff.sourceBinding, binding)
        XCTAssertTrue(handoff.executionPreconditions.contains(.sourceRevisionMatch(binding: binding)))
        XCTAssertTrue(handoff.executionPreconditions.contains(.planAcceptanceVerification(receiptID: "plan-accept-7")))
    }

    func testProviderAllowlistRemainsExactAndRequiresEnforcement() throws {
        let privacy = try ForgeComposerPrivacyIntent.providers(["openai", "anthropic"])
        let profile = try controls(privacy: privacy)
        let handoff = try makeHandoff(summary: summary(profile: profile))

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
        let handoff = try makeHandoff(summary: summary(profile: profile))

        XCTAssertTrue(handoff.requiresExternalModelQualification)
        XCTAssertEqual(handoff.requestedExplicitModelReferenceID, "model.local.qwen35-4b")
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .explicitModelQualification(referenceID: "model.local.qwen35-4b")
            )
        )
        XCTAssertEqual(handoff.controlProfile.intelligence, modelIntent)
    }

    func testDelegatedDecisionSurvivesAsPreExecutionGate() throws {
        let decision = PlanResolvedDecision(
            id: "storage",
            prompt: "Which storage approach?",
            value: .delegatedToNovaForge
        )
        let handoff = try makeHandoff(summary: summary(decisions: [decision]))

        XCTAssertEqual(handoff.delegatedDecisionIDs, ["storage"])
        XCTAssertTrue(handoff.requiresDelegatedDecisionResolution)
        XCTAssertEqual(handoff.planDecisions, [decision])
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .delegatedDecisionResolution(decisionID: "storage")
            )
        )
    }

    func testExplicitModelFullForgeAndDelegationRemainSeparateRequirements() throws {
        let profile = try controls(
            intelligence: try .explicit(referenceID: "model.deep.local"),
            autonomy: .fullForge
        )
        let decision = PlanResolvedDecision(
            id: "physics",
            prompt: "Choose handling style",
            value: .delegatedToNovaForge
        )
        let handoff = try makeHandoff(
            summary: summary(profile: profile, decisions: [decision])
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
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .delegatedDecisionResolution(decisionID: "physics")
            )
        )
        XCTAssertEqual(handoff.autonomyIntent, .fullForge)
    }

    func testConcreteDecisionRemainsStructuredAndDoesNotBecomeDelegated() throws {
        let decision = PlanResolvedDecision(
            id: "theme",
            prompt: "Theme?",
            value: .selected(optionID: "dark", label: "Dark")
        )
        let handoff = try makeHandoff(summary: summary(decisions: [decision]))

        XCTAssertEqual(handoff.planDecisions, [decision])
        XCTAssertFalse(handoff.requiresDelegatedDecisionResolution)
        XCTAssertFalse(
            handoff.executionPreconditions.contains(
                .delegatedDecisionResolution(decisionID: "theme")
            )
        )
    }

    func testDirectlyConstructedBlankSummaryFailsClosed() throws {
        let bad = try summary(intentSummary: "  ")
        XCTAssertThrowsError(try makeHandoff(summary: bad)) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidSummary("intentSummary"))
        }
    }

    func testDuplicateDecisionIDsFailClosed() throws {
        let one = PlanResolvedDecision(id: "x", prompt: "One", value: .text("a"))
        let two = PlanResolvedDecision(id: "x", prompt: "Two", value: .text("b"))
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(decisions: [one, two]))
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .duplicateDecisionID("x"))
        }
    }

    func testTooManyDecisionsFailsClosed() throws {
        let decisions = (0..<129).map { index in
            PlanResolvedDecision(
                id: "decision-\(index)",
                prompt: "Decision \(index)?",
                value: .text("value")
            )
        }
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(decisions: decisions))
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidSummary("tooManyDecisions"))
        }
    }

    func testInvalidNonFiniteDecisionFailsClosed() throws {
        let bad = PlanResolvedDecision(id: "risk", prompt: "Risk?", value: .scalar(.infinity))
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(decisions: [bad]))
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidDecision("risk"))
        }
    }

    func testInvalidIntervalOrderingFailsClosed() throws {
        let bad = PlanResolvedDecision(
            id: "range",
            prompt: "Range?",
            value: .interval(lower: 2, upper: 1)
        )
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(decisions: [bad]))
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidDecision("range"))
        }
    }

    func testSelectedOptionIdentityRejectsControlCharacters() throws {
        let bad = PlanResolvedDecision(
            id: "theme",
            prompt: "Theme?",
            value: .selected(optionID: "dark\u{0000}", label: "Dark")
        )
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(decisions: [bad]))
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidDecision("theme"))
        }
    }

    func testTextAllowsNewlinesButRejectsOtherControlCharacters() throws {
        let good = PlanResolvedDecision(
            id: "notes",
            prompt: "Notes?",
            value: .text("line one\nline two")
        )
        XCTAssertNoThrow(try makeHandoff(summary: summary(decisions: [good])))

        let bad = PlanResolvedDecision(
            id: "bad-notes",
            prompt: "Notes?",
            value: .text("nope\u{0000}")
        )
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(decisions: [bad]))
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidDecision("bad-notes"))
        }
    }

    func testContextRejectsNonCanonicalReceiptIDAndZeroRevision() throws {
        XCTAssertThrowsError(
            try ForgePlanMissionContext(
                handoffRevision: 0,
                planAcceptanceReceiptID: "ok"
            )
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidContext("handoffRevision"))
        }
        XCTAssertThrowsError(
            try ForgePlanMissionContext(
                handoffRevision: 1,
                planAcceptanceReceiptID: " padded "
            )
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidContext("planAcceptanceReceiptID"))
        }
    }

    func testSourceBindingRejectsZeroRevisionAndNonCanonicalReference() throws {
        XCTAssertThrowsError(
            try ForgePlanMissionSourceBinding(
                composerDraftRevision: 0,
                planRevision: 1,
                planReferenceID: "plan-1"
            )
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidSourceBinding("composerDraftRevision"))
        }
        XCTAssertThrowsError(
            try ForgePlanMissionSourceBinding(
                composerDraftRevision: 1,
                planRevision: 0,
                planReferenceID: "plan-1"
            )
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidSourceBinding("planRevision"))
        }
        XCTAssertThrowsError(
            try ForgePlanMissionSourceBinding(
                composerDraftRevision: 1,
                planRevision: 1,
                planReferenceID: " plan-1 "
            )
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidSourceBinding("planReferenceID"))
        }
    }

    func testDecisionOrderingAndDelegatedPreconditionsAreCanonical() throws {
        let z = PlanResolvedDecision(id: "z", prompt: "Z", value: .delegatedToNovaForge)
        let a = PlanResolvedDecision(id: "a", prompt: "A", value: .delegatedToNovaForge)
        let handoff = try makeHandoff(summary: summary(decisions: [z, a]))

        XCTAssertEqual(handoff.planDecisions.map(\.id), ["a", "z"])
        XCTAssertEqual(handoff.delegatedDecisionIDs, ["a", "z"])
    }
}
