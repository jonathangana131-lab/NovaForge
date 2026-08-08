import Foundation
import Testing
@testable import ForgeRepairCore

private struct Fixture {
    let project: RepairProjectID
    let revision: RepairRevisionID
    let checkpoint: RepairCheckpointID
    let defect: RepairDefect
    let policy: RepairPolicy
}

private func fixture(maxAttempts: Int = 4, escalation: Int = 2) throws -> Fixture {
    let project = try RepairProjectID(rawValue: "project-1")
    let revision = try RepairRevisionID(rawValue: "revision-1")
    let checkpoint = try RepairCheckpointID(rawValue: "checkpoint-good")
    let defect = try RepairDefect(
        id: RepairDefectID(rawValue: "defect-1"),
        projectID: project,
        discoveredRevisionID: revision,
        defectClass: .runtime,
        severity: .high,
        summary: "Crash after restart",
        evidenceReceiptIDs: [RepairReceiptID(rawValue: "discovery-r1")]
    )
    return Fixture(
        project: project,
        revision: revision,
        checkpoint: checkpoint,
        defect: defect,
        policy: try RepairPolicy(maximumAttempts: maxAttempts, escalateAfterNonImprovingAttempts: escalation)
    )
}

private func score(
    target: Bool,
    critical: Int = 0,
    high: Int = 0,
    failed: Int = 0,
    visual: Int = 0,
    a11y: Int = 0,
    performance: Int = 0,
    receipt: String
) throws -> RepairEvidenceScorecard {
    try RepairEvidenceScorecard(
        targetDefectObserved: target,
        criticalBlockers: critical,
        highBlockers: high,
        failedJourneys: failed,
        visualRegressions: visual,
        accessibilityViolations: a11y,
        performanceViolations: performance,
        receiptIDs: [RepairReceiptID(rawValue: receipt)]
    )
}

private func verification(
    focused: Bool = false,
    full: Bool = false,
    visual: Bool = false,
    a11y: Bool = false,
    performance: Bool = false
) throws -> RepairVerificationReceipts {
    try RepairVerificationReceipts(
        focusedTest: focused ? RepairReceiptID(rawValue: "focused") : nil,
        fullJourney: full ? RepairReceiptID(rawValue: "full") : nil,
        visualRegression: visual ? RepairReceiptID(rawValue: "visual") : nil,
        accessibility: a11y ? RepairReceiptID(rawValue: "a11y") : nil,
        performance: performance ? RepairReceiptID(rawValue: "perf") : nil
    )
}

private func attempt(
    fixture f: Fixture,
    ordinal: Int,
    before: RepairEvidenceScorecard,
    after: RepairEvidenceScorecard,
    verification receipts: RepairVerificationReceipts = try! RepairVerificationReceipts()
) throws -> RepairAttempt {
    try RepairAttempt(
        id: RepairAttemptID(rawValue: "attempt-\(ordinal)"),
        ordinal: ordinal,
        projectID: f.project,
        defectID: f.defect.id,
        sourceRevisionID: f.revision,
        candidateRevisionID: RepairRevisionID(rawValue: "candidate-\(ordinal)"),
        knownGoodCheckpointID: f.checkpoint,
        before: before,
        after: after,
        verification: receipts
    )
}

@Test func freshCampaignRequestsFocusedRepair() throws {
    let f = try fixture()
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy)
    #expect(campaign.assess().nextAction == .retryFocusedRepair)
}

@Test func rejectsCrossProjectDefect() throws {
    let f = try fixture()
    #expect(throws: ForgeRepairError.identityMismatch) {
        _ = try RepairCampaign(
            projectID: RepairProjectID(rawValue: "other-project"),
            defect: f.defect,
            knownGoodCheckpointID: f.checkpoint,
            policy: f.policy
        )
    }
}

@Test func candidateMustDifferFromSourceRevision() throws {
    let f = try fixture()
    let before = try score(target: true, high: 1, receipt: "before")
    #expect(throws: ForgeRepairError.candidateMatchesSourceRevision) {
        _ = try RepairAttempt(
            id: RepairAttemptID(rawValue: "attempt-1"), ordinal: 1, projectID: f.project,
            defectID: f.defect.id, sourceRevisionID: f.revision, candidateRevisionID: f.revision,
            knownGoodCheckpointID: f.checkpoint, before: before, after: before,
            verification: RepairVerificationReceipts()
        )
    }
}

@Test func improvedEvidenceIsDerivedNotModelDeclared() throws {
    let f = try fixture()
    let a = try attempt(
        fixture: f, ordinal: 1,
        before: score(target: true, high: 1, receipt: "before"),
        after: score(target: true, receipt: "after")
    )
    #expect(a.trend == .improved)
}

@Test func regressionRestoresKnownGoodAndEscalates() throws {
    let f = try fixture()
    let a = try attempt(
        fixture: f, ordinal: 1,
        before: score(target: true, high: 1, receipt: "before"),
        after: score(target: true, critical: 1, high: 1, receipt: "after")
    )
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a])
    #expect(campaign.assess().nextAction == .restoreKnownGoodAndEscalate)
}

@Test func unresolvedImprovementRetriesWithinBudget() throws {
    let f = try fixture()
    let a = try attempt(
        fixture: f, ordinal: 1,
        before: score(target: true, high: 2, receipt: "before"),
        after: score(target: true, high: 1, receipt: "after")
    )
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a])
    #expect(campaign.assess().nextAction == .retryFocusedRepair)
}

@Test func repeatedNonImprovementEscalatesRootCause() throws {
    let f = try fixture()
    let baseline = try score(target: true, high: 1, receipt: "baseline")
    let a1 = try attempt(fixture: f, ordinal: 1, before: baseline, after: score(target: true, high: 1, receipt: "after1"))
    let a2 = try attempt(fixture: f, ordinal: 2, before: baseline, after: score(target: true, high: 1, receipt: "after2"))
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a1, a2])
    #expect(campaign.assess().nextAction == .escalateRootCause)
    #expect(campaign.assess().consecutiveNonImprovingAttempts == 2)
}

@Test func budgetExhaustionStopsBlocked() throws {
    let f = try fixture(maxAttempts: 2, escalation: 2)
    let before = try score(target: true, high: 3, receipt: "before")
    let a1 = try attempt(fixture: f, ordinal: 1, before: before, after: score(target: true, high: 2, receipt: "after1"))
    let a2 = try attempt(fixture: f, ordinal: 2, before: before, after: score(target: true, high: 1, receipt: "after2"))
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a1, a2])
    #expect(campaign.assess().nextAction == .stopBlocked)
}

@Test func resolvedCandidateStillRequiresFocusedTest() throws {
    let f = try fixture()
    let a = try attempt(
        fixture: f, ordinal: 1,
        before: score(target: true, high: 1, receipt: "before"),
        after: score(target: false, receipt: "after")
    )
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a])
    #expect(campaign.assess().nextAction == .runFocusedTest)
}

@Test func verificationSequenceIsEvidenceGated() throws {
    let f = try fixture()
    let before = try score(target: true, high: 1, receipt: "before")
    let after = try score(target: false, receipt: "after")
    let focused = try attempt(fixture: f, ordinal: 1, before: before, after: after, verification: verification(focused: true))
    #expect(try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [focused]).assess().nextAction == .runFullJourney)

    let full = try attempt(fixture: f, ordinal: 1, before: before, after: after, verification: verification(focused: true, full: true))
    #expect(try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [full]).assess().nextAction == .runVisualRegression)
}

@Test func acceptanceRequiresAllConfiguredReceipts() throws {
    let f = try fixture()
    let a = try attempt(
        fixture: f, ordinal: 1,
        before: score(target: true, high: 1, receipt: "before"),
        after: score(target: false, receipt: "after"),
        verification: verification(focused: true, full: true, visual: true, a11y: true, performance: true)
    )
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a])
    #expect(campaign.assess().nextAction == .acceptCandidate)
}

@Test func resolvedTargetWithNewBlockerRestoresKnownGood() throws {
    let f = try fixture()
    let a = try attempt(
        fixture: f, ordinal: 1,
        before: score(target: true, high: 1, receipt: "before"),
        after: score(target: false, visual: 1, receipt: "after")
    )
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a])
    #expect(campaign.assess().nextAction == .restoreKnownGoodAndEscalate)
}

@Test func duplicateAttemptIDFailsClosed() throws {
    let f = try fixture()
    let before = try score(target: true, high: 2, receipt: "before")
    let a1 = try attempt(fixture: f, ordinal: 1, before: before, after: score(target: true, high: 1, receipt: "after1"))
    let a2 = try RepairAttempt(
        id: a1.id, ordinal: 2, projectID: f.project, defectID: f.defect.id,
        sourceRevisionID: f.revision, candidateRevisionID: RepairRevisionID(rawValue: "candidate-2"),
        knownGoodCheckpointID: f.checkpoint, before: before,
        after: score(target: true, receipt: "after2"), verification: RepairVerificationReceipts()
    )
    #expect(throws: ForgeRepairError.duplicateAttemptID) {
        _ = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a1, a2])
    }
}

@Test func skippedAttemptOrdinalFailsClosed() throws {
    let f = try fixture()
    let a = try attempt(
        fixture: f, ordinal: 2,
        before: score(target: true, receipt: "before"),
        after: score(target: false, receipt: "after")
    )
    #expect(throws: ForgeRepairError.nonMonotonicAttemptOrdinal) {
        _ = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a])
    }
}

@Test func decodedBudgetReentersValidation() {
    let json = Data(#"{"maximumAttempts":0,"escalateAfterNonImprovingAttempts":1,"requireFullJourney":true,"requireVisualRegression":true,"requireAccessibility":true,"requirePerformance":true}"#.utf8)
    #expect(throws: ForgeRepairError.invalidBudget) {
        _ = try JSONDecoder().decode(RepairPolicy.self, from: json)
    }
}

@Test func decodedEvidenceReentersValidation() {
    let json = Data(#"{"targetDefectObserved":true,"criticalBlockers":-1,"highBlockers":0,"failedJourneys":0,"visualRegressions":0,"accessibilityViolations":0,"performanceViolations":0,"receiptIDs":["r1"]}"#.utf8)
    #expect(throws: ForgeRepairError.invalidEvidence) {
        _ = try JSONDecoder().decode(RepairEvidenceScorecard.self, from: json)
    }
}

@Test func archiveRoundTripsExactDerivedAssessment() throws {
    let f = try fixture()
    let a = try attempt(
        fixture: f, ordinal: 1,
        before: score(target: true, high: 1, receipt: "before"),
        after: score(target: false, receipt: "after"),
        verification: verification(focused: true, full: true, visual: true, a11y: true, performance: true)
    )
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy, attempts: [a])
    let archive = ForgeRepairArchive(campaign: campaign)
    let decoded = try JSONDecoder().decode(ForgeRepairArchive.self, from: JSONEncoder().encode(archive))
    #expect(decoded == archive)
    #expect(decoded.assessment.nextAction == .acceptCandidate)
}

@Test func archiveRejectsForgedAssessment() throws {
    let f = try fixture()
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy)
    let archive = ForgeRepairArchive(campaign: campaign)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
    var assessment = try #require(object["assessment"] as? [String: Any])
    assessment["nextAction"] = "acceptCandidate"
    object["assessment"] = assessment
    #expect(throws: ForgeRepairError.assessmentMismatch) {
        _ = try JSONDecoder().decode(ForgeRepairArchive.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

@Test func archiveRejectsUnknownSchema() throws {
    let f = try fixture()
    let campaign = try RepairCampaign(projectID: f.project, defect: f.defect, knownGoodCheckpointID: f.checkpoint, policy: f.policy)
    let archive = ForgeRepairArchive(campaign: campaign)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
    object["schemaVersion"] = 99
    #expect(throws: ForgeRepairError.unsupportedArchiveSchema(99)) {
        _ = try JSONDecoder().decode(ForgeRepairArchive.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
