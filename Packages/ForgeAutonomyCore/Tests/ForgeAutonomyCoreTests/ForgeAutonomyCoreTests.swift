import Foundation
import Testing
@testable import ForgeAutonomyCore

private func authority() throws -> ForgeAutonomyAuthority {
    try ForgeAutonomyAuthority(
        projectID: "project-1",
        missionID: "mission-1",
        checkpointID: "checkpoint-9",
        missionRevision: 42,
        authorityEpoch: 3
    )
}

private func budget(
    elapsed: UInt64 = 10_000,
    actions: UInt64 = 100,
    repairs: UInt64 = 4,
    nonProgress: UInt64 = 6,
    leadElapsed: UInt64 = 1_000,
    leadActions: UInt64 = 10
) throws -> ForgeAutonomyBudget {
    try ForgeAutonomyBudget(
        policyRevision: 7,
        maximumElapsedMilliseconds: elapsed,
        maximumActions: actions,
        maximumRepairAttemptsPerDefect: repairs,
        maximumConsecutiveNonProgressActions: nonProgress,
        checkpointLeadMilliseconds: leadElapsed,
        checkpointLeadActions: leadActions
    )
}

private func observation(
    elapsed: UInt64 = 1_000,
    actions: UInt64 = 10,
    repairs: UInt64 = 0,
    nonProgress: UInt64 = 0,
    thermal: ForgeThermalPressure = .nominal,
    memory: ForgeMemoryPressure = .nominal,
    directive: ForgeUserDirective = .none,
    unresolved: Bool = false,
    approval: Bool = false,
    external: Bool = false,
    checkpoint: Bool = false
) -> ForgeAutonomyObservation {
    ForgeAutonomyObservation(
        elapsedMilliseconds: elapsed,
        actionsUsed: actions,
        repairAttemptsForCurrentDefect: repairs,
        consecutiveNonProgressActions: nonProgress,
        thermalPressure: thermal,
        memoryPressure: memory,
        userDirective: directive,
        hasUnresolvedMaterialDecision: unresolved,
        hasPendingPolicyApproval: approval,
        hasExternalBlocker: external,
        hasFreshCheckpointForCurrentAuthority: checkpoint
    )
}

@Test func nominalStateProceeds() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation())
    #expect(decision.disposition == .proceed)
    #expect(decision.reason == .withinBudget)
    #expect(!decision.requiresCheckpoint)
}

@Test func userCancellationWinsOverEveryOtherCondition() throws {
    let decision = ForgeAutonomyDecision.evaluate(
        authority: try authority(), budget: try budget(),
        observation: observation(elapsed: 10_000, actions: 100, thermal: .critical, directive: .cancel, unresolved: true)
    )
    #expect(decision.disposition == .cancel)
    #expect(decision.reason == .userCancelled)
}

@Test func userPauseStopsAutonomy() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(directive: .pause))
    #expect(decision.disposition == .pause)
    #expect(decision.reason == .userPaused)
    #expect(decision.requiresCheckpoint)
}

@Test func materialDecisionStopsAutonomy() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(unresolved: true))
    #expect(decision.reason == .unresolvedMaterialDecision)
    #expect(decision.requiresCheckpoint)
}

@Test func pendingApprovalStopsAutonomy() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(approval: true))
    #expect(decision.reason == .pendingPolicyApproval)
}

@Test func externalBlockerStopsAutonomy() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(external: true))
    #expect(decision.reason == .externalBlocker)
}

@Test func criticalThermalPressureStopsAndRequestsCheckpoint() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(thermal: .critical))
    #expect(decision.disposition == .pause)
    #expect(decision.reason == .thermalCritical)
    #expect(decision.requiresCheckpoint)
}

@Test func existingCheckpointAvoidsDuplicateCriticalCheckpointRequest() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(thermal: .critical, checkpoint: true))
    #expect(decision.disposition == .pause)
    #expect(!decision.requiresCheckpoint)
}

@Test func criticalMemoryPressureStopsAutonomy() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(memory: .critical))
    #expect(decision.reason == .memoryCritical)
}

@Test func elapsedHardCeilingIsFailClosed() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(elapsed: 10_000))
    #expect(decision.disposition == .pause)
    #expect(decision.reason == .elapsedBudgetExhausted)
}

@Test func actionHardCeilingIsFailClosed() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(actions: 100))
    #expect(decision.reason == .actionBudgetExhausted)
}

@Test func repairCeilingRequiresEscalation() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(repairs: 4))
    #expect(decision.reason == .repairEscalationRequired)
}

@Test func nonProgressCeilingRequiresEscalation() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(nonProgress: 6))
    #expect(decision.reason == .noProgressEscalationRequired)
}

@Test func seriousThermalPressureDegradesBeforeHardStop() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(thermal: .serious))
    #expect(decision.disposition == .degradeThenProceed)
    #expect(decision.reason == .thermalSerious)
    #expect(decision.requiresCheckpoint)
}

@Test func memoryWarningDegradesBeforeHardStop() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(memory: .warning))
    #expect(decision.disposition == .degradeThenProceed)
    #expect(decision.reason == .memoryWarning)
}

@Test func elapsedLeadRequestsCheckpointBeforeLimit() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(elapsed: 9_000))
    #expect(decision.disposition == .checkpointThenProceed)
    #expect(decision.reason == .elapsedBudgetNearLimit)
}

@Test func actionLeadRequestsCheckpointBeforeLimit() throws {
    let decision = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(actions: 90))
    #expect(decision.disposition == .checkpointThenProceed)
    #expect(decision.reason == .actionBudgetNearLimit)
}

@Test func freshCheckpointAllowsNearLimitContinuation() throws {
    let decision = ForgeAutonomyDecision.evaluate(
        authority: try authority(), budget: try budget(),
        observation: observation(elapsed: 9_500, actions: 95, checkpoint: true)
    )
    #expect(decision.disposition == .proceed)
}

@Test func budgetRejectsZeroHardCeilings() {
    #expect(throws: ForgeAutonomyValidationError.invalidBudget(field: "maximumActions")) {
        _ = try budget(actions: 0, leadActions: 0)
    }
}

@Test func budgetRejectsCheckpointLeadAtOrBeyondHardLimit() {
    #expect(throws: ForgeAutonomyValidationError.invalidCheckpointLead(field: "checkpointLeadActions")) {
        _ = try budget(actions: 10, leadActions: 10)
    }
}

@Test func authorityRejectsWhitespaceAndPathLikeIdentifiers() {
    #expect(throws: ForgeAutonomyValidationError.invalidIdentifier(field: "projectID")) {
        _ = try ForgeAutonomyAuthority(
            projectID: " ../project ", missionID: "mission", checkpointID: "checkpoint",
            missionRevision: 1, authorityEpoch: 1
        )
    }
}

@Test func decisionRoundTripsAndRevalidates() throws {
    let original = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(memory: .warning))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ForgeAutonomyDecision.self, from: data)
    #expect(decoded == original)
}

@Test func decodedDecisionCannotForgeProceed() throws {
    let original = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation(thermal: .critical))
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["disposition"] = "proceed"
    object["reason"] = "withinBudget"
    object["requiresCheckpoint"] = false
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeAutonomyValidationError.forgedDecision) {
        _ = try JSONDecoder().decode(ForgeAutonomyDecision.self, from: tampered)
    }
}

@Test func decodedBudgetRevalidatesConstructorInvariants() throws {
    let original = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation())
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedBudget = try #require(object["budget"] as? [String: Any])
    encodedBudget["maximumActions"] = 0
    object["budget"] = encodedBudget
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeAutonomyValidationError.invalidBudget(field: "maximumActions")) {
        _ = try JSONDecoder().decode(ForgeAutonomyDecision.self, from: tampered)
    }
}

@Test func unknownPressureValueFailsClosedDuringDecode() throws {
    let original = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation())
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedObservation = try #require(object["observation"] as? [String: Any])
    encodedObservation["thermalPressure"] = "impossiblyHot"
    object["observation"] = encodedObservation
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(ForgeAutonomyDecision.self, from: tampered)
    }
}

@Test func maximumCountersFailClosedWithoutOverflow() throws {
    let extremeBudget = try budget(
        elapsed: UInt64.max, actions: UInt64.max, repairs: UInt64.max, nonProgress: UInt64.max,
        leadElapsed: UInt64.max - 1, leadActions: UInt64.max - 1
    )
    let decision = ForgeAutonomyDecision.evaluate(
        authority: try authority(), budget: extremeBudget,
        observation: observation(elapsed: UInt64.max, actions: UInt64.max)
    )
    #expect(decision.disposition == .pause)
    #expect(decision.reason == .elapsedBudgetExhausted)
}

@Test func decodedAuthorityRevalidatesOpaqueIdentifiers() throws {
    let original = ForgeAutonomyDecision.evaluate(authority: try authority(), budget: try budget(), observation: observation())
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedAuthority = try #require(object["authority"] as? [String: Any])
    encodedAuthority["projectID"] = "../project"
    object["authority"] = encodedAuthority
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeAutonomyValidationError.invalidIdentifier(field: "projectID")) {
        _ = try JSONDecoder().decode(ForgeAutonomyDecision.self, from: tampered)
    }
}
