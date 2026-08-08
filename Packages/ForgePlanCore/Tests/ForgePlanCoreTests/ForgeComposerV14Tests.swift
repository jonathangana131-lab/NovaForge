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

    func testEnvelopeDefaultsLocalFirstAndDoesNotTurnFullForgeIntoAuthorization() throws {
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "Build a local-first notes app",
            creativity: ForgeComposerUnitInterval(0.5),
            refactorRisk: ForgeComposerUnitInterval(0.2)
        )

        XCTAssertEqual(envelope.autonomy, .collaborate)
        XCTAssertEqual(envelope.buildDepth, .complete)
        XCTAssertEqual(envelope.intelligence, .automatic)
        XCTAssertEqual(envelope.privacy, .localOnly)
        XCTAssertFalse(envelope.requestsFullForge)
        XCTAssertFalse(envelope.requiresExternalModelQualification)
    }

    func testEnvelopePreservesFullForgeAsUserIntentOnly() throws {
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "Build and autonomously polish a game",
            autonomy: .fullForge,
            buildDepth: .obsessive,
            intelligence: .automatic,
            privacy: .localOnly,
            creativity: ForgeComposerUnitInterval(0.8),
            refactorRisk: ForgeComposerUnitInterval(0.4),
            creationKind: .game,
            runTargetID: "iphone"
        )

        XCTAssertTrue(envelope.requestsFullForge)
        XCTAssertTrue(envelope.privacy.isLocalOnly)
        XCTAssertEqual(envelope.creationKind, .game)
        XCTAssertEqual(envelope.runTargetID, "iphone")
    }

    func testEnvelopeRejectsBlankOrControlCharacterIntent() throws {
        XCTAssertThrowsError(
            try ForgeComposerIntentEnvelope(
                intentSummary: "   ",
                creativity: ForgeComposerUnitInterval(0.5),
                refactorRisk: ForgeComposerUnitInterval(0.5)
            )
        )
        XCTAssertThrowsError(
            try ForgeComposerIntentEnvelope(
                intentSummary: "Build\u{0000}app",
                creativity: ForgeComposerUnitInterval(0.5),
                refactorRisk: ForgeComposerUnitInterval(0.5)
            )
        )
    }

    func testEnvelopeAllowsMultilineIntentAndTrimsOuterWhitespace() throws {
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "  Build this:\n- local\n- fast  ",
            creativity: ForgeComposerUnitInterval(0.5),
            refactorRisk: ForgeComposerUnitInterval(0.5)
        )
        XCTAssertEqual(envelope.intentSummary, "Build this:\n- local\n- fast")
    }

    func testEnvelopeRejectsMalformedRunTargetIdentity() throws {
        XCTAssertThrowsError(
            try ForgeComposerIntentEnvelope(
                intentSummary: "Build an app",
                creativity: ForgeComposerUnitInterval(0.5),
                refactorRisk: ForgeComposerUnitInterval(0.5),
                runTargetID: " iphone "
            )
        )
    }

    func testEnvelopeRoundTripsWithExplicitModelAndProviders() throws {
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "Build a driving simulator",
            autonomy: .fullForge,
            buildDepth: .obsessive,
            intelligence: .explicit(referenceID: "qualified-profile-42"),
            privacy: .providers(["anthropic", "openai"]),
            creativity: ForgeComposerUnitInterval(0.7),
            refactorRisk: ForgeComposerUnitInterval(0.3),
            creationKind: .game,
            runTargetID: "iphone"
        )

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(ForgeComposerIntentEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertTrue(decoded.requiresExternalModelQualification)
    }

    func testDecodeRejectsUnknownSchemaVersion() throws {
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "Build an app",
            creativity: ForgeComposerUnitInterval(0.5),
            refactorRisk: ForgeComposerUnitInterval(0.5)
        )
        let encoded = try JSONEncoder().encode(envelope)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 99
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeComposerIntentEnvelope.self, from: tampered))
    }

    func testDecodeRejectsLocalProviderAllowlistWithDuplicateIDs() throws {
        let envelope = try ForgeComposerIntentEnvelope(
            intentSummary: "Build an app",
            privacy: .providers(["openai"]),
            creativity: ForgeComposerUnitInterval(0.5),
            refactorRisk: ForgeComposerUnitInterval(0.5)
        )
        let encoded = try JSONEncoder().encode(envelope)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["privacy"] = ["kind": "providerAllowlist", "providerIDs": ["openai", "openai"]]
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
