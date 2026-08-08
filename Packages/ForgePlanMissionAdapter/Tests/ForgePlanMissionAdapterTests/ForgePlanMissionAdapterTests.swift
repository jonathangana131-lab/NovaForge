import Foundation
import XCTest
import AgentDomain
import ForgePlanCore
@testable import ForgePlanMissionAdapter

final class ForgePlanMissionAdapterTests: XCTestCase {
    private let missionID = MissionID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    private let projectID = ProjectID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    private func authority() throws -> ForgePlanMissionAuthority {
        try .init(missionID: missionID, projectID: projectID, constitutionRevision: 7, acceptedAt: .init(rawValue: 1234), planAcceptanceReceiptID: "plan-accept-7")
    }
    private func supplement(locality: MissionLocalityPreference = .unspecified) -> ForgePlanMissionSupplement {
        .init(projectType: "iPhone app", localityPreference: locality, acceptanceJourneys: MissionStringSet(["Launch and complete the primary flow"]), expectedEvidence: MissionEvidenceSet([.compiled, .runtimeTested, .visuallyInspected]))
    }
    private func summary(decisions: [PlanResolvedDecision] = []) -> ReadyToForgeSummary {
        .init(intentSummary: "Build a calm local-first timer", decisions: decisions, controls: .init(intelligence: .deep, buildDepth: .obsessive, creativity: .init(0.8), refactorRisk: .init(0.1), autonomy: .autopilot, localCompute: .init(1), cloudResource: .init(0)))
    }

    func testMapsPlanIntentWithoutInventingLocalityOrExecutionAuthority() throws {
        let handoff = try ForgePlanMissionAdapter.makeHandoff(summary: summary(), authority: authority(), supplement: supplement())
        XCTAssertEqual(handoff.constitution.missionID, missionID)
        XCTAssertEqual(handoff.constitution.projectID, projectID)
        XCTAssertEqual(handoff.constitution.revision, 7)
        XCTAssertEqual(handoff.constitution.buildDepth, .obsessive)
        XCTAssertEqual(handoff.constitution.creativity, .inventive)
        XCTAssertEqual(handoff.constitution.refactorRisk, .preserve)
        XCTAssertEqual(handoff.constitution.localityPreference, .unspecified)
        XCTAssertEqual(handoff.orchestrationIntent.localCompute, 1)
        XCTAssertEqual(handoff.orchestrationIntent.cloudResource, 0)
        XCTAssertFalse(handoff.requiresDelegatedDecisionResolution)
    }

    func testExplicitLocalOnlySupplementIsPreserved() throws {
        let handoff = try ForgePlanMissionAdapter.makeHandoff(summary: summary(), authority: authority(), supplement: supplement(locality: .localOnly))
        XCTAssertEqual(handoff.constitution.localityPreference, .localOnly)
    }

    func testDelegatedDecisionSurvivesAsPreExecutionGate() throws {
        let decision = PlanResolvedDecision(id: "storage", prompt: "Storage?", value: .delegatedToNovaForge)
        let handoff = try ForgePlanMissionAdapter.makeHandoff(summary: summary(decisions: [decision]), authority: authority(), supplement: supplement())
        XCTAssertEqual(handoff.delegatedDecisionIDs, ["storage"])
        XCTAssertTrue(handoff.requiresDelegatedDecisionResolution)
        XCTAssertEqual(handoff.acceptedPlanDecisions, [decision])
    }

    func testConcreteDecisionIsPreservedNotFlattenedIntoConstraints() throws {
        let decision = PlanResolvedDecision(id: "theme", prompt: "Theme?", value: .selected(optionID: "dark", label: "Dark"))
        let handoff = try ForgePlanMissionAdapter.makeHandoff(summary: summary(decisions: [decision]), authority: authority(), supplement: supplement())
        XCTAssertEqual(handoff.acceptedPlanDecisions, [decision])
        XCTAssertTrue(handoff.constitution.constraints.values.isEmpty)
    }

    func testDirectlyConstructedBlankSummaryFailsClosed() throws {
        let bad = ReadyToForgeSummary(intentSummary: "  ", decisions: [], controls: .init())
        XCTAssertThrowsError(try ForgePlanMissionAdapter.makeHandoff(summary: bad, authority: authority(), supplement: supplement())) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidSummary("intentSummary"))
        }
    }

    func testDuplicateDecisionIDsFailClosed() throws {
        let one = PlanResolvedDecision(id: "x", prompt: "One", value: .text("a"))
        let two = PlanResolvedDecision(id: "x", prompt: "Two", value: .text("b"))
        XCTAssertThrowsError(try ForgePlanMissionAdapter.makeHandoff(summary: summary(decisions: [one, two]), authority: authority(), supplement: supplement())) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .duplicateDecisionID("x"))
        }
    }

    func testInvalidNonFiniteDecisionFailsClosed() throws {
        let bad = PlanResolvedDecision(id: "risk", prompt: "Risk?", value: .scalar(.infinity))
        XCTAssertThrowsError(try ForgePlanMissionAdapter.makeHandoff(summary: summary(decisions: [bad]), authority: authority(), supplement: supplement()))
    }

    func testSelectedOptionIdentityRejectsControlCharacters() throws {
        let bad = PlanResolvedDecision(id: "theme", prompt: "Theme?", value: .selected(optionID: "dark\u{0000}", label: "Dark"))
        XCTAssertThrowsError(try ForgePlanMissionAdapter.makeHandoff(summary: summary(decisions: [bad]), authority: authority(), supplement: supplement())) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidDecision("theme"))
        }
    }

    func testMissingAcceptanceJourneyFailsClosed() throws {
        let s = ForgePlanMissionSupplement(projectType: "app", acceptanceJourneys: MissionStringSet([]), expectedEvidence: MissionEvidenceSet([.compiled]))
        XCTAssertThrowsError(try ForgePlanMissionAdapter.makeHandoff(summary: summary(), authority: authority(), supplement: s)) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .missingAcceptanceJourneys)
        }
    }

    func testMissingExpectedEvidenceFailsClosed() throws {
        let s = ForgePlanMissionSupplement(projectType: "app", acceptanceJourneys: MissionStringSet(["launch"]), expectedEvidence: MissionEvidenceSet([]))
        XCTAssertThrowsError(try ForgePlanMissionAdapter.makeHandoff(summary: summary(), authority: authority(), supplement: s)) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .missingExpectedEvidence)
        }
    }

    func testInvalidSupplementConstitutionFailsClosed() throws {
        let s = ForgePlanMissionSupplement(projectType: " ", acceptanceJourneys: MissionStringSet(["launch"]), expectedEvidence: MissionEvidenceSet([.compiled]))
        XCTAssertThrowsError(try ForgePlanMissionAdapter.makeHandoff(summary: summary(), authority: authority(), supplement: s)) {
            XCTAssertEqual($0 as? ForgePlanMissionHandoffError, .invalidConstitution(.missingProjectType))
        }
    }

    func testAuthorityRejectsNonCanonicalReceiptIDAndZeroRevision() throws {
        XCTAssertThrowsError(try ForgePlanMissionAuthority(missionID: missionID, projectID: projectID, constitutionRevision: 0, acceptedAt: .init(rawValue: 1), planAcceptanceReceiptID: "ok"))
        XCTAssertThrowsError(try ForgePlanMissionAuthority(missionID: missionID, projectID: projectID, constitutionRevision: 1, acceptedAt: .init(rawValue: 1), planAcceptanceReceiptID: " padded "))
    }

    func testDecisionOrderingIsCanonical() throws {
        let z = PlanResolvedDecision(id: "z", prompt: "Z", value: .text("z"))
        let a = PlanResolvedDecision(id: "a", prompt: "A", value: .text("a"))
        let handoff = try ForgePlanMissionAdapter.makeHandoff(summary: summary(decisions: [z, a]), authority: authority(), supplement: supplement())
        XCTAssertEqual(handoff.acceptedPlanDecisions.map(\.id), ["a", "z"])
    }

    func testThresholdMappingsAreDeterministicAtEdges() throws {
        func mapped(_ creativity: Double, _ risk: Double) throws -> (MissionCreativity, MissionRefactorRisk) {
            let s = ReadyToForgeSummary(intentSummary: "x", decisions: [], controls: .init(creativity: .init(creativity), refactorRisk: .init(risk)))
            let h = try ForgePlanMissionAdapter.makeHandoff(summary: s, authority: authority(), supplement: supplement())
            return (h.constitution.creativity, h.constitution.refactorRisk)
        }
        let low = try mapped((1.0 / 3.0) - 0.0001, (1.0 / 3.0) - 0.0001)
        XCTAssertEqual(low.0, .faithful); XCTAssertEqual(low.1, .preserve)
        let mid = try mapped(1.0 / 3.0, 1.0 / 3.0)
        XCTAssertEqual(mid.0, .balanced); XCTAssertEqual(mid.1, .balanced)
        let high = try mapped(2.0 / 3.0, 2.0 / 3.0)
        XCTAssertEqual(high.0, .inventive); XCTAssertEqual(high.1, .rebuild)
    }
}
