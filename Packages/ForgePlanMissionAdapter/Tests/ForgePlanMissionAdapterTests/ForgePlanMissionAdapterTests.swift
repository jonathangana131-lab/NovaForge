import Foundation
import XCTest
import AgentDomain
import ForgePlanCore
@testable import ForgePlanMissionAdapter

final class ForgePlanMissionAdapterTests: XCTestCase {
    private let missionID = MissionID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    private let projectID = ProjectID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    private func authority() throws -> ForgePlanMissionAuthority {
        try .init(
            missionID: missionID,
            projectID: projectID,
            constitutionRevision: 7,
            acceptedAt: .init(rawValue: 1234),
            planAcceptanceReceiptID: "plan-accept-7"
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
        controls: ForgeComposerV14ControlProfile? = nil,
        decisions: [PlanResolvedDecision] = []
    ) throws -> ReadyToForgeSummary {
        .init(
            intentSummary: "Build a calm local-first timer",
            decisions: decisions,
            controls: try controls ?? self.controls()
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
        let handoff = try ForgePlanMissionAdapter.makeHandoff(
            summary: summary(controls: profile),
            authority: authority(),
            supplement: supplement()
        )

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
        XCTAssertFalse(handoff.requiresExternalModelQualification)
        XCTAssertFalse(handoff.requiresDelegatedDecisionResolution)
    }

    func testProviderAllowlistRemainsExactAndDoesNotMasqueradeAsLocalOnly() throws {
        let privacy = try ForgeComposerPrivacyIntent.providers(["openai", "anthropic"])
        let profile = try controls(privacy: privacy)
        let handoff = try ForgePlanMissionAdapter.makeHandoff(
            summary: summary(controls: profile),
            authority: authority(),
            supplement: supplement()
        )

        XCTAssertEqual(handoff.constitution.localityPreference, .unspecified)
        XCTAssertEqual(handoff.privacyIntent, try .providers(["anthropic", "openai"]))
        XCTAssertTrue(handoff.privacyIntent.allowsProvider("openai"))
        XCTAssertTrue(handoff.privacyIntent.allowsProvider("anthropic"))
        XCTAssertFalse(handoff.privacyIntent.allowsProvider("other-cloud"))
    }

    func testExplicitModelReferenceCreatesQualificationPrecondition() throws {
        let modelIntent = try ForgeComposerIntelligenceIntent.explicit(referenceID: "model.local.qwen35-4b")
        let profile = try controls(intelligence: modelIntent)
        let handoff = try ForgePlanMissionAdapter.makeHandoff(
            summary: summary(controls: profile),
            authority: authority(),
            supplement: supplement()
        )

        XCTAssertTrue(handoff.requiresExternalModelQualification)
        XCTAssertEqual(handoff.requestedExplicitModelReferenceID, "model.local.qwen35-4b")
        XCTAssertEqual(
            handoff.executionPreconditions,
            [.explicitModelQualification(referenceID: "model.local.qwen35-4b")]
        )
        XCTAssertEqual(handoff.controlProfile.intelligence, modelIntent)
    }

    func testDelegatedDecisionSurvivesAsPreExecutionGate() throws {
        let decision = PlanResolvedDecision(
            id: "storage",
            prompt: "Which storage approach?",
            value: .delegatedToNovaForge
        )
        let handoff = try ForgePlanMissionAdapter.makeHandoff(
            summary: summary(decisions: [decision]),
            authority: authority(),
            supplement: supplement()
        )

        XCTAssertEqual(handoff.delegatedDecisionIDs, ["storage"])
        XCTAssertTrue(handoff.requiresDelegatedDecisionResolution)
        XCTAssertEqual(handoff.acceptedPlanDecisions, [decision])
        XCTAssertEqual(
            handoff.executionPreconditions,
            [.delegatedDecisionResolution(decisionID: "storage")]
        )
    }

    func testExplicitModelAndDelegatedDecisionBothRemainUnresolved() throws {
        let profile = try controls(
            intelligence: try .explicit(referenceID: "model.deep.local"),
            autonomy: .fullForge
        )
        let decision = PlanResolvedDecision(
            id: "physics",
            prompt: "Choose handling style",
            value: .delegatedToNovaForge
        )
        let handoff = try ForgePlanMissionAdapter.makeHandoff(
            summary: summary(controls: profile, decisions: [decision]),
            authority: authority(),
            supplement: supplement()
        )

        XCTAssertEqual(
            handoff.executionPreconditions,
            [
                .explicitModelQualification(referenceID: "model.deep.local"),
                .delegatedDecisionResolution(decisionID: "physics")
            ]
        )
        XCTAssertEqual(handoff.autonomyIntent, .fullForge)
    }

    func testConcreteDecisionIsPreservedNotFlattenedIntoConstraints() throws {
        let decision = PlanResolvedDecision(
            id: "theme",
            prompt: "Theme?",
            value: .selected(optionID: "dark", label: "Dark")
        )
        let handoff = try ForgePlanMissionAdapter.makeHandoff(
            summary: summary(decisions: [decision]),
            authority: authority(),
            supplement: supplement()
        )

        XCTAssertEqual(handoff.acceptedPlanDecisions, [decision])
        XCTAssertTrue(handoff.constitution.constraints.values.isEmpty)
        XCTAssertTrue(handoff.executionPreconditions.isEmpty)
    }

    func testV14BuildDepthMappingsAreDeterministic() throws {
        func mapped(_ depth: ForgeComposerBuildDepthIntent) throws -> MissionBuildDepth {
            let handoff = try ForgePlanMissionAdapter.makeHandoff(
                summary: summary(controls: controls(buildDepth: depth)),
                authority: authority(),
                supplement: supplement()
            )
            return handoff.constitution.buildDepth
        }

        XCTAssertEqual(try mapped(.quick), .prototype)
        XCTAssertEqual(try mapped(.complete), .polished)
        XCTAssertEqual(try mapped(.obsessive), .obsessive)
    }

    func testThresholdMappingsAreDeterministicAtEdges() throws {
        func mapped(_ creativity: Double, _ risk: Double) throws -> (MissionCreativity, MissionRefactorRisk) {
            let handoff = try ForgePlanMissionAdapter.makeHandoff(
                summary: summary(controls: controls(creativity: creativity, refactorRisk: risk)),
                authority: authority(),
                supplement: supplement()
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
        XCTAssertThrowsError(
            try ForgePlanMissionAdapter.makeHandoff(
                summary: bad,
                authority: authority(),
                supplement: supplement()
            )
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidSummary("intentSummary"))
        }
    }

    func testDuplicateDecisionIDsFailClosed() throws {
        let one = PlanResolvedDecision(id: "x", prompt: "One", value: .text("a"))
        let two = PlanResolvedDecision(id: "x", prompt: "Two", value: .text("b"))
        XCTAssertThrowsError(
            try ForgePlanMissionAdapter.makeHandoff(
                summary: summary(decisions: [one, two]),
                authority: authority(),
                supplement: supplement()
            )
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .duplicateDecisionID("x"))
        }
    }

    func testInvalidNonFiniteDecisionFailsClosed() throws {
        let bad = PlanResolvedDecision(id: "risk", prompt: "Risk?", value: .scalar(.infinity))
        XCTAssertThrowsError(
            try ForgePlanMissionAdapter.makeHandoff(
                summary: summary(decisions: [bad]),
                authority: authority(),
                supplement: supplement()
            )
        )
    }

    func testSelectedOptionIdentityRejectsControlCharacters() throws {
        let bad = PlanResolvedDecision(
            id: "theme",
            prompt: "Theme?",
            value: .selected(optionID: "dark\u{0000}", label: "Dark")
        )
        XCTAssertThrowsError(
            try ForgePlanMissionAdapter.makeHandoff(
                summary: summary(decisions: [bad]),
                authority: authority(),
                supplement: supplement()
            )
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
            try ForgePlanMissionAdapter.makeHandoff(
                summary: summary(),
                authority: authority(),
                supplement: badSupplement
            )
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
            try ForgePlanMissionAdapter.makeHandoff(
                summary: summary(),
                authority: authority(),
                supplement: badSupplement
            )
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
            try ForgePlanMissionAdapter.makeHandoff(
                summary: summary(),
                authority: authority(),
                supplement: badSupplement
            )
        ) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidConstitution(.missingProjectType))
        }
    }

    func testAuthorityRejectsNonCanonicalReceiptIDAndZeroRevision() throws {
        XCTAssertThrowsError(
            try ForgePlanMissionAuthority(
                missionID: missionID,
                projectID: projectID,
                constitutionRevision: 0,
                acceptedAt: .init(rawValue: 1),
                planAcceptanceReceiptID: "ok"
            )
        )
        XCTAssertThrowsError(
            try ForgePlanMissionAuthority(
                missionID: missionID,
                projectID: projectID,
                constitutionRevision: 1,
                acceptedAt: .init(rawValue: 1),
                planAcceptanceReceiptID: " padded "
            )
        )
    }

    func testDecisionOrderingAndPreconditionsAreCanonical() throws {
        let z = PlanResolvedDecision(id: "z", prompt: "Z", value: .delegatedToNovaForge)
        let a = PlanResolvedDecision(id: "a", prompt: "A", value: .delegatedToNovaForge)
        let handoff = try ForgePlanMissionAdapter.makeHandoff(
            summary: summary(decisions: [z, a]),
            authority: authority(),
            supplement: supplement()
        )

        XCTAssertEqual(handoff.acceptedPlanDecisions.map(\.id), ["a", "z"])
        XCTAssertEqual(handoff.delegatedDecisionIDs, ["a", "z"])
    }
}
