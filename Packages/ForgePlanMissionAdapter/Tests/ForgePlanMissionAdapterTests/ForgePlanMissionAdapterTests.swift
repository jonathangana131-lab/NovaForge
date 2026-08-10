import Foundation
import XCTest
import AgentDomain
import ForgePlanCore
@testable import ForgePlanMissionAdapter

final class ForgePlanMissionAdapterTests: XCTestCase {
    private let missionID = MissionID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    private let projectID = ProjectID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    private func context() throws -> ForgePlanMissionContext {
        try .init(
            missionID: missionID,
            projectID: projectID,
            constitutionRevision: 7,
            projectedAcceptedAt: .init(rawValue: 1234),
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

    private func supplement() -> ForgePlanMissionSupplement {
        .init(
            projectType: "iPhone app",
            acceptanceJourneys: MissionStringSet(["Launch and complete the primary flow"]),
            expectedEvidence: MissionEvidenceSet([.compiled, .runtimeTested, .visuallyInspected])
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
        decisions: [PlanResolvedDecision] = []
    ) throws -> ReadyToForgeSummary {
        let resolvedProfile = try profile ?? controls()
        return .init(
            intentSummary: "Build a calm local-first timer",
            decisions: decisions,
            controls: resolvedProfile
        )
    }

    private func makeHandoff(
        summary: ReadyToForgeSummary,
        supplement: ForgePlanMissionSupplement? = nil
    ) throws -> ForgePlanMissionHandoff {
        try ForgePlanMissionAdapter.makeHandoff(
            summary: summary,
            context: context(),
            sourceBinding: sourceBinding(),
            supplement: supplement ?? self.supplement()
        )
    }

    func testLocalOnlySurvivesAsTypedMissionAndRoutingTruth() throws {
        let profile = try controls(
            buildDepth: .obsessive,
            creativity: 0.8,
            refactorRisk: 0.1,
            autonomy: .fullForge,
            privacy: .localOnly
        )
        let handoff = try makeHandoff(summary: summary(profile: profile))

        XCTAssertEqual(handoff.constitution.missionID, missionID)
        XCTAssertEqual(handoff.constitution.projectID, projectID)
        XCTAssertEqual(handoff.constitution.revision, 7)
        XCTAssertEqual(handoff.constitution.buildDepth, .obsessive)
        XCTAssertEqual(handoff.constitution.creativity, .inventive)
        XCTAssertEqual(handoff.constitution.refactorRisk, .preserve)
        XCTAssertEqual(handoff.constitution.localityPreference, .localOnly)
        XCTAssertEqual(handoff.privacyIntent, .localOnly)
        XCTAssertEqual(handoff.autonomyIntent, .fullForge)
        XCTAssertEqual(handoff.controlProfile, profile)
        XCTAssertEqual(handoff.sourceBinding, try sourceBinding())
        XCTAssertTrue(handoff.executionPreconditions.contains(.localOnlyRouting))
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .autonomyPolicyResolution(intent: .fullForge)
            )
        )
        XCTAssertFalse(handoff.requiresExternalModelQualification)
        XCTAssertFalse(handoff.requiresDelegatedDecisionResolution)
    }

    func testReceiptAndSourceRevisionNeverSelfAuthenticate() throws {
        let binding = try sourceBinding()
        let handoff = try makeHandoff(summary: summary())

        XCTAssertEqual(handoff.sourceBinding, binding)
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .sourceRevisionMatch(binding: binding)
            )
        )
        XCTAssertTrue(
            handoff.executionPreconditions.contains(
                .planAcceptanceVerification(receiptID: "plan-accept-7")
            )
        )
    }

    func testProviderAllowlistRemainsExactAndRequiresEnforcement() throws {
        let privacy = try ForgeComposerPrivacyIntent.providers(["openai", "anthropic"])
        let profile = try controls(privacy: privacy)
        let handoff = try makeHandoff(summary: summary(profile: profile))

        XCTAssertEqual(handoff.constitution.localityPreference, .unspecified)
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

    func testConcreteDecisionIsPreservedNotFlattenedIntoConstraints() throws {
        let decision = PlanResolvedDecision(
            id: "theme",
            prompt: "Theme?",
            value: .selected(optionID: "dark", label: "Dark")
        )
        let handoff = try makeHandoff(summary: summary(decisions: [decision]))

        XCTAssertEqual(handoff.planDecisions, [decision])
        XCTAssertTrue(handoff.constitution.constraints.values.isEmpty)
        XCTAssertFalse(handoff.requiresDelegatedDecisionResolution)
    }

    func testV14BuildDepthMappingsAreDeterministic() throws {
        func mapped(_ depth: ForgeComposerBuildDepthIntent) throws -> MissionBuildDepth {
            let handoff = try makeHandoff(
                summary: summary(profile: controls(buildDepth: depth))
            )
            return handoff.constitution.buildDepth
        }

        XCTAssertEqual(try mapped(.quick), .prototype)
        XCTAssertEqual(try mapped(.complete), .polished)
        XCTAssertEqual(try mapped(.obsessive), .obsessive)
    }

    func testThresholdMappingsAreDeterministicAtEdges() throws {
        func mapped(_ creativity: Double, _ risk: Double) throws -> (MissionCreativity, MissionRefactorRisk) {
            let handoff = try makeHandoff(
                summary: summary(
                    profile: controls(creativity: creativity, refactorRisk: risk)
                )
            )
            return (handoff.constitution.creativity, handoff.constitution.refactorRisk)
        }

        let low = try mapped((1.0 / 3.0) - 0.0001, (1.0 / 3.0) - 0.0001)
        XCTAssertEqual(low.0, .faithful)
        XCTAssertEqual(low.1, .preserve)

        let mid = try mapped(1.0 / 3.0, 1.0 / 3.0)
        XCTAssertEqual(mid.0, .balanced)
        XCTAssertEqual(mid.1, .balanced)

        let high = try mapped(2.0 / 3.0, 2.0 / 3.0)
        XCTAssertEqual(high.0, .inventive)
        XCTAssertEqual(high.1, .rebuild)
    }

    func testDirectlyConstructedBlankSummaryFailsClosed() throws {
        let bad = ReadyToForgeSummary(
            intentSummary: "  ",
            decisions: [],
            controls: try controls()
        )
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

    func testInvalidNonFiniteDecisionFailsClosed() throws {
        let bad = PlanResolvedDecision(id: "risk", prompt: "Risk?", value: .scalar(.infinity))
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(decisions: [bad]))
        )
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

    func testMissingAcceptanceJourneyFailsClosed() throws {
        let badSupplement = ForgePlanMissionSupplement(
            projectType: "app",
            acceptanceJourneys: MissionStringSet([]),
            expectedEvidence: MissionEvidenceSet([.compiled])
        )
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(), supplement: badSupplement)
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .missingAcceptanceJourneys)
        }
    }

    func testMissingExpectedEvidenceFailsClosed() throws {
        let badSupplement = ForgePlanMissionSupplement(
            projectType: "app",
            acceptanceJourneys: MissionStringSet(["launch"]),
            expectedEvidence: MissionEvidenceSet([])
        )
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(), supplement: badSupplement)
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .missingExpectedEvidence)
        }
    }

    func testInvalidSupplementConstitutionFailsClosed() throws {
        let badSupplement = ForgePlanMissionSupplement(
            projectType: " ",
            acceptanceJourneys: MissionStringSet(["launch"]),
            expectedEvidence: MissionEvidenceSet([.compiled])
        )
        XCTAssertThrowsError(
            try makeHandoff(summary: summary(), supplement: badSupplement)
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidConstitution(.missingProjectType))
        }
    }

    func testContextRejectsNonCanonicalReceiptIDAndZeroRevision() throws {
        XCTAssertThrowsError(
            try ForgePlanMissionContext(
                missionID: missionID,
                projectID: projectID,
                constitutionRevision: 0,
                projectedAcceptedAt: .init(rawValue: 1),
                planAcceptanceReceiptID: "ok"
            )
        )
        XCTAssertThrowsError(
            try ForgePlanMissionContext(
                missionID: missionID,
                projectID: projectID,
                constitutionRevision: 1,
                projectedAcceptedAt: .init(rawValue: 1),
                planAcceptanceReceiptID: " padded "
            )
        )
    }

    func testSourceBindingRejectsZeroRevisionAndNonCanonicalReference() throws {
        XCTAssertThrowsError(
            try ForgePlanMissionSourceBinding(
                composerDraftRevision: 0,
                planRevision: 1,
                planReferenceID: "plan-1"
            )
        )
        XCTAssertThrowsError(
            try ForgePlanMissionSourceBinding(
                composerDraftRevision: 1,
                planRevision: 0,
                planReferenceID: "plan-1"
            )
        )
        XCTAssertThrowsError(
            try ForgePlanMissionSourceBinding(
                composerDraftRevision: 1,
                planRevision: 1,
                planReferenceID: " plan-1 "
            )
        )
    }

    func testDecisionOrderingAndDelegatedPreconditionsAreCanonical() throws {
        let z = PlanResolvedDecision(id: "z", prompt: "Z", value: .delegatedToNovaForge)
        let a = PlanResolvedDecision(id: "a", prompt: "A", value: .delegatedToNovaForge)
        let handoff = try makeHandoff(summary: summary(decisions: [z, a]))

        XCTAssertEqual(handoff.planDecisions.map(\.id), ["a", "z"])
        XCTAssertEqual(handoff.delegatedDecisionIDs, ["a", "z"])
    }
}
