import Foundation
import XCTest
@testable import ForgePlanCore

final class ForgeComposerV14Tests: XCTestCase {
    func testRestingComposerRevealsNoControls() {
        XCTAssertEqual(ForgeComposerDisclosureSignals(hasIntent: false).visibleControls, [])
    }

    func testIntentRevealsPolicySignificantControlsOnlyByDefault() {
        XCTAssertEqual(
            ForgeComposerDisclosureSignals(hasIntent: true).visibleControls,
            [.autonomy, .buildDepth, .intelligence, .privacy]
        )
    }

    func testMaterialSignalsRevealOnlyRelevantSecondaryControls() {
        XCTAssertEqual(
            ForgeComposerDisclosureSignals(
                hasIntent: true,
                creativityIsMaterial: true,
                runTargetIsMaterial: true
            ).visibleControls,
            [.autonomy, .buildDepth, .intelligence, .privacy, .creativity, .runTarget]
        )
    }

    func testLocalOnlyNeverAllowsProvider() {
        let privacy = ForgeComposerPrivacyIntent.localOnly
        XCTAssertTrue(privacy.isLocalOnly)
        XCTAssertFalse(privacy.allowsProvider("openai"))
    }

    func testProviderAllowlistIsDeterministicAndExact() throws {
        let privacy = try ForgeComposerPrivacyIntent.providers(["openai", "anthropic"])
        XCTAssertEqual(privacy, .providerAllowlist(["anthropic", "openai"]))
        XCTAssertTrue(privacy.allowsProvider("openai"))
        XCTAssertFalse(privacy.allowsProvider("OpenAI"))
        XCTAssertFalse(privacy.isLocalOnly)
    }

    func testProviderAllowlistRejectsEmptyDuplicateAndMalformedIdentity() throws {
        XCTAssertThrowsError(try ForgeComposerPrivacyIntent.providers([]))
        XCTAssertThrowsError(try ForgeComposerPrivacyIntent.providers(["openai", "openai"]))
        XCTAssertThrowsError(try ForgeComposerPrivacyIntent.providers([" openai "]))
        XCTAssertThrowsError(try ForgeComposerPrivacyIntent.providers(["open\u{0000}ai"]))
    }

    func testProviderAllowlistRejectsUnboundedProviderCount() {
        let providers = (0..<17).map { "provider-\($0)" }
        XCTAssertThrowsError(try ForgeComposerPrivacyIntent.providers(providers))
    }

    func testExplicitIntelligenceIsPreferenceThatRequiresQualification() throws {
        let intelligence = try ForgeComposerIntelligenceIntent.explicit(referenceID: "local-model-profile-7")
        XCTAssertTrue(intelligence.requiresExternalQualification)
        XCTAssertFalse(ForgeComposerIntelligenceIntent.automatic.requiresExternalQualification)
    }

    func testExplicitModelRejectsNonCanonicalIdentity() {
        XCTAssertThrowsError(try ForgeComposerIntelligenceIntent.explicit(referenceID: " model "))
        XCTAssertThrowsError(try ForgeComposerIntelligenceIntent.explicit(referenceID: "model\nprofile"))
        XCTAssertThrowsError(
            try ForgeComposerIntelligenceIntent.explicit(referenceID: String(repeating: "m", count: 257))
        )
    }

    func testUnitIntervalFailsClosedInsteadOfClamping() {
        XCTAssertThrowsError(try ForgeComposerUnitInterval(-0.01))
        XCTAssertThrowsError(try ForgeComposerUnitInterval(1.01))
        XCTAssertThrowsError(try ForgeComposerUnitInterval(.nan))
        XCTAssertNoThrow(try ForgeComposerUnitInterval(0))
        XCTAssertNoThrow(try ForgeComposerUnitInterval(1))
    }

    func testV14ControlProfileDefaultsLocalFirst() {
        let controls = ForgeComposerV14ControlProfile()
        XCTAssertEqual(controls.autonomy, .collaborate)
        XCTAssertEqual(controls.buildDepth, .complete)
        XCTAssertEqual(controls.intelligence, .automatic)
        XCTAssertEqual(controls.privacy, .localOnly)
        XCTAssertFalse(controls.requestsFullForge)
        XCTAssertFalse(controls.requiresExternalModelQualification)
    }

    func testEnvelopeUsesSingleSharedV14ControlProfile() throws {
        let controls = ForgeComposerV14ControlProfile()
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "Build a local-first notes app",
            controls: controls
        )

        XCTAssertEqual(envelope.controls, controls)
        XCTAssertTrue(envelope.controls.privacy.isLocalOnly)
        XCTAssertFalse(envelope.requestsFullForge)
        XCTAssertFalse(envelope.requiresExternalModelQualification)
    }

    func testEnvelopePreservesFullForgeAsUserIntentOnly() throws {
        let controls = ForgeComposerV14ControlProfile(
            intelligence: .automatic,
            buildDepth: .obsessive,
            creativity: try ForgeComposerUnitInterval(0.8),
            refactorRisk: try ForgeComposerUnitInterval(0.4),
            autonomy: .fullForge,
            privacy: .localOnly
        )
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "Build and autonomously polish a game",
            controls: controls,
            creationKind: .game,
            runTargetID: "iphone"
        )

        XCTAssertTrue(envelope.requestsFullForge)
        XCTAssertTrue(envelope.controls.privacy.isLocalOnly)
        XCTAssertEqual(envelope.creationKind, .game)
        XCTAssertEqual(envelope.runTargetID, "iphone")
    }

    func testPlanSpaceAndReadySummaryPreserveExactV14ControlProfile() throws {
        let controls = ForgeComposerV14ControlProfile(
            intelligence: try .explicit(referenceID: "qualified-profile-42"),
            buildDepth: .obsessive,
            creativity: try ForgeComposerUnitInterval(0.7),
            refactorRisk: try ForgeComposerUnitInterval(0.3),
            autonomy: .fullForge,
            privacy: try .providers(["openai"])
        )
        let proposal = PlanSpaceProposal(
            intentSummary: "Build a driving simulator",
            questions: [PlanQuestion(id: "camera", prompt: "Camera", controlKind: .freeText)],
            controls: controls
        )
        let summary = try XCTUnwrap(proposal.readySummary(answers: ["camera": .text("cockpit")]))

        XCTAssertEqual(proposal.controls, controls)
        XCTAssertEqual(summary.controls, controls)
        XCTAssertTrue(summary.controls.requestsFullForge)
        XCTAssertTrue(summary.controls.requiresExternalModelQualification)
    }

    func testEnvelopeRejectsBlankOrControlCharacterIntent() throws {
        XCTAssertThrowsError(
            try ForgeComposerIntentEnvelope(intentSummary: "   ")
        )
        XCTAssertThrowsError(
            try ForgeComposerIntentEnvelope(intentSummary: "Build\u{0000}app")
        )
    }

    func testEnvelopeAllowsMultilineIntentAndTrimsOuterWhitespace() throws {
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "  Build this:\n- local\n- fast  "
        )
        XCTAssertEqual(envelope.intentSummary, "Build this:\n- local\n- fast")
    }

    func testEnvelopeRejectsMalformedRunTargetIdentity() {
        XCTAssertThrowsError(
            try ForgeComposerIntentEnvelope(
                intentSummary: "Build an app",
                runTargetID: " iphone "
            )
        )
    }

    func testEnvelopeRoundTripsWithExplicitModelAndProviders() throws {
        let controls = ForgeComposerV14ControlProfile(
            intelligence: try .explicit(referenceID: "qualified-profile-42"),
            buildDepth: .obsessive,
            creativity: try ForgeComposerUnitInterval(0.7),
            refactorRisk: try ForgeComposerUnitInterval(0.3),
            autonomy: .fullForge,
            privacy: try .providers(["anthropic", "openai"])
        )
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "Build a driving simulator",
            controls: controls,
            creationKind: .game,
            runTargetID: "iphone"
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(ForgeComposerIntentEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertTrue(decoded.requiresExternalModelQualification)
    }

    func testDecodeRejectsUnknownSchemaVersion() throws {
        let envelope = try ForgeComposerIntentEnvelope(intentSummary: "Build an app")
        let encoded = try JSONEncoder().encode(envelope)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 99
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeComposerIntentEnvelope.self, from: tampered))
    }

    func testDecodeRejectsDuplicateProviderIDsInsideSharedControls() throws {
        let controls = ForgeComposerV14ControlProfile(privacy: try .providers(["openai"]))
        let envelope = try ForgeComposerIntentEnvelope(intentSummary: "Build an app", controls: controls)
        let encoded = try JSONEncoder().encode(envelope)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var controlsObject = try XCTUnwrap(object["controls"] as? [String: Any])
        controlsObject["privacy"] = ["kind": "providerAllowlist", "providerIDs": ["openai", "openai"]]
        object["controls"] = controlsObject
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeComposerIntentEnvelope.self, from: tampered))
    }

    func testDecodeRejectsInvalidExplicitModelInsideSharedControls() throws {
        let controls = ForgeComposerV14ControlProfile(
            intelligence: try .explicit(referenceID: "qualified-profile")
        )
        let envelope = try ForgeComposerIntentEnvelope(intentSummary: "Build an app", controls: controls)
        let encoded = try JSONEncoder().encode(envelope)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var controlsObject = try XCTUnwrap(object["controls"] as? [String: Any])
        controlsObject["intelligence"] = ["kind": "explicitModel", "referenceID": " padded "]
        object["controls"] = controlsObject
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeComposerIntentEnvelope.self, from: tampered))
    }

    func testPrimaryActionMorphsAcrossCreationFlow() {
        XCTAssertEqual(ForgeComposerExperienceState.resting.nextAction, .describe)
        XCTAssertEqual(ForgeComposerExperienceState.described(needsMaterialPlan: true).nextAction, .plan)
        XCTAssertEqual(ForgeComposerExperienceState.described(needsMaterialPlan: false).nextAction, .forge)
        XCTAssertEqual(ForgeComposerExperienceState.waitingForPlanDecision.nextAction, .plan)
        XCTAssertEqual(ForgeComposerExperienceState.readyToForge.nextAction, .forge)
        XCTAssertEqual(ForgeComposerExperienceState.forging.nextAction, .watch)
        XCTAssertEqual(
            ForgeComposerExperienceState.completed(runnable: true, hasMaterialDefects: false).nextAction,
            .run
        )
        XCTAssertEqual(
            ForgeComposerExperienceState.completed(runnable: true, hasMaterialDefects: true).nextAction,
            .improve
        )
        XCTAssertEqual(
            ForgeComposerExperienceState.completed(runnable: false, hasMaterialDefects: false).nextAction,
            .improve
        )
    }
}
