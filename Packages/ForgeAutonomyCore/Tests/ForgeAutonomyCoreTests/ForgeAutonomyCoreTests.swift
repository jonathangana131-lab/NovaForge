import Foundation
import Testing
@testable import ForgeAutonomyCore

private func authority(
    checkpointID: String = "checkpoint-9",
    missionRevision: UInt64 = 42,
    authorityEpoch: UInt64 = 3
) throws -> ForgeAutonomyAuthority {
    try ForgeAutonomyAuthority(
        projectID: "project-1",
        missionID: "mission-1",
        checkpointID: checkpointID,
        missionRevision: missionRevision,
        authorityEpoch: authorityEpoch
    )
}

private func budget(
    policyRevision: UInt64 = 7,
    elapsed: UInt64 = 10_000,
    actions: UInt64 = 100,
    repairs: UInt64 = 4,
    nonProgress: UInt64 = 6,
    leadElapsed: UInt64 = 1_000,
    leadActions: UInt64 = 10
) throws -> ForgeAutonomyBudget {
    try ForgeAutonomyBudget(
        policyRevision: policyRevision,
        maximumElapsedMilliseconds: elapsed,
        maximumActions: actions,
        maximumRepairAttemptsPerDefect: repairs,
        maximumConsecutiveNonProgressActions: nonProgress,
        checkpointLeadMilliseconds: leadElapsed,
        checkpointLeadActions: leadActions
    )
}

private func checkpoint(
    checkpointID: String = "checkpoint-9",
    missionRevision: UInt64 = 42,
    authorityEpoch: UInt64 = 3,
    generation: UInt64 = 2,
    projectID: String = "project-1",
    missionID: String = "mission-1"
) throws -> ForgeAutonomyCheckpointObservation {
    try ForgeAutonomyCheckpointObservation(
        projectID: projectID,
        missionID: missionID,
        checkpointID: checkpointID,
        missionRevision: missionRevision,
        authorityEpoch: authorityEpoch,
        capturedAtObservationGeneration: generation
    )
}

private func observation(
    generation: UInt64 = 3,
    lastConsumedGeneration: UInt64 = 2,
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
    durableCheckpoint: ForgeAutonomyCheckpointObservation? = nil
) throws -> ForgeAutonomyObservation {
    try ForgeAutonomyObservation(
        observationGeneration: generation,
        lastConsumedObservationGeneration: lastConsumedGeneration,
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
        latestDurableCheckpoint: durableCheckpoint
    )
}

private func project(
    authority resolvedAuthority: ForgeAutonomyAuthority? = nil,
    budget resolvedBudget: ForgeAutonomyBudget? = nil,
    observation resolvedObservation: ForgeAutonomyObservation? = nil
) throws -> ForgeAutonomyCandidateProjection {
    ForgeAutonomyCandidateEvaluator.project(
        authority: try resolvedAuthority ?? authority(),
        budget: try resolvedBudget ?? budget(),
        observation: try resolvedObservation ?? observation()
    )
}

@Test func nominalProjectionIsExplicitlyCandidateOnly() throws {
    let projection = try project()
    #expect(projection.disposition == .proceed)
    #expect(projection.reason == .withinBudget)
    #expect(!projection.requiresCheckpoint)
    #expect(projection.projectionAuthority == .candidateOnly)
    #expect(!projection.authorizesExecution)
    #expect(projection.consumesObservationGeneration == 3)
}

@Test func serializedProceedRemainsCandidateOnlyAfterRestore() throws {
    let original = try project()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: data)

    #expect(decoded == original)
    #expect(decoded.disposition == .proceed)
    #expect(decoded.projectionAuthority == .candidateOnly)
    #expect(!decoded.authorizesExecution)
}

@Test func userCancellationWinsOverEveryOtherCondition() throws {
    let projection = try project(
        observation: observation(
            elapsed: 10_000,
            actions: 100,
            thermal: .critical,
            directive: .cancel,
            unresolved: true
        )
    )
    #expect(projection.disposition == .cancel)
    #expect(projection.reason == .userCancelled)
}

@Test func userPauseStopsCandidateContinuation() throws {
    let projection = try project(observation: observation(directive: .pause))
    #expect(projection.disposition == .pause)
    #expect(projection.reason == .userPaused)
    #expect(projection.requiresCheckpoint)
}

@Test func materialDecisionStopsCandidateContinuation() throws {
    let projection = try project(observation: observation(unresolved: true))
    #expect(projection.reason == .unresolvedMaterialDecision)
    #expect(projection.requiresCheckpoint)
}

@Test func pendingApprovalStopsCandidateContinuation() throws {
    let projection = try project(observation: observation(approval: true))
    #expect(projection.reason == .pendingPolicyApproval)
}

@Test func externalBlockerStopsCandidateContinuation() throws {
    let projection = try project(observation: observation(external: true))
    #expect(projection.reason == .externalBlocker)
}

@Test func criticalThermalPressureStopsAndRequestsCheckpoint() throws {
    let projection = try project(observation: observation(thermal: .critical))
    #expect(projection.disposition == .pause)
    #expect(projection.reason == .thermalCritical)
    #expect(projection.requiresCheckpoint)
}

@Test func exactCheckpointAvoidsDuplicateCriticalCheckpointRequest() throws {
    let projection = try project(
        observation: observation(
            thermal: .critical,
            durableCheckpoint: checkpoint()
        )
    )
    #expect(projection.disposition == .pause)
    #expect(!projection.requiresCheckpoint)
}

@Test func checkpointMustMatchExactProjectMissionCheckpointRevisionAndEpoch() throws {
    let mismatches = [
        try checkpoint(projectID: "project-other"),
        try checkpoint(missionID: "mission-other"),
        try checkpoint(checkpointID: "checkpoint-other"),
        try checkpoint(missionRevision: 41),
        try checkpoint(authorityEpoch: 2),
    ]

    for mismatchedCheckpoint in mismatches {
        let projection = try project(
            observation: observation(
                thermal: .critical,
                durableCheckpoint: mismatchedCheckpoint
            )
        )
        #expect(projection.requiresCheckpoint)
    }
}

@Test func futureCheckpointGenerationIsRejected() throws {
    #expect(throws: ForgeAutonomyValidationError.invalidCheckpointGeneration) {
        _ = try observation(
            generation: 3,
            lastConsumedGeneration: 2,
            durableCheckpoint: checkpoint(generation: 4)
        )
    }
}

@Test func criticalMemoryPressureStopsCandidateContinuation() throws {
    let projection = try project(observation: observation(memory: .critical))
    #expect(projection.reason == .memoryCritical)
}

@Test func elapsedHardCeilingIsFailClosed() throws {
    let projection = try project(observation: observation(elapsed: 10_000))
    #expect(projection.disposition == .pause)
    #expect(projection.reason == .elapsedBudgetExhausted)
}

@Test func actionHardCeilingIsFailClosed() throws {
    let projection = try project(observation: observation(actions: 100))
    #expect(projection.reason == .actionBudgetExhausted)
}

@Test func repairCeilingRequiresEscalation() throws {
    let projection = try project(observation: observation(repairs: 4))
    #expect(projection.reason == .repairEscalationRequired)
}

@Test func nonProgressCeilingRequiresEscalation() throws {
    let projection = try project(observation: observation(nonProgress: 6))
    #expect(projection.reason == .noProgressEscalationRequired)
}

@Test func seriousThermalPressureDegradesBeforeHardStop() throws {
    let projection = try project(observation: observation(thermal: .serious))
    #expect(projection.disposition == .degradeThenProceed)
    #expect(projection.reason == .thermalSerious)
    #expect(projection.requiresCheckpoint)
}

@Test func memoryWarningDegradesBeforeHardStop() throws {
    let projection = try project(observation: observation(memory: .warning))
    #expect(projection.disposition == .degradeThenProceed)
    #expect(projection.reason == .memoryWarning)
}

@Test func elapsedLeadRequestsCheckpointBeforeLimit() throws {
    let projection = try project(observation: observation(elapsed: 9_000))
    #expect(projection.disposition == .checkpointThenProceed)
    #expect(projection.reason == .elapsedBudgetNearLimit)
}

@Test func actionLeadRequestsCheckpointBeforeLimit() throws {
    let projection = try project(observation: observation(actions: 90))
    #expect(projection.disposition == .checkpointThenProceed)
    #expect(projection.reason == .actionBudgetNearLimit)
}

@Test func exactFreshCheckpointAllowsNearLimitCandidate() throws {
    let projection = try project(
        observation: observation(
            elapsed: 9_500,
            actions: 95,
            durableCheckpoint: checkpoint()
        )
    )
    #expect(projection.disposition == .proceed)
    #expect(!projection.authorizesExecution)
}

@Test func observationGenerationMustAdvancePastConsumedGeneration() {
    #expect(throws: ForgeAutonomyValidationError.invalidObservationGeneration) {
        _ = try observation(generation: 5, lastConsumedGeneration: 5)
    }
    #expect(throws: ForgeAutonomyValidationError.invalidObservationGeneration) {
        _ = try observation(generation: 4, lastConsumedGeneration: 5)
    }
    #expect(throws: ForgeAutonomyValidationError.invalidObservationGeneration) {
        _ = try observation(generation: 0, lastConsumedGeneration: 0)
    }
}

@Test func budgetRejectsZeroRevisionAndHardCeilings() {
    #expect(throws: ForgeAutonomyValidationError.invalidRevision(field: "policyRevision")) {
        _ = try budget(policyRevision: 0)
    }
    #expect(throws: ForgeAutonomyValidationError.invalidBudget(field: "maximumActions")) {
        _ = try budget(actions: 0, leadActions: 0)
    }
}

@Test func budgetRejectsEffectivelyUnboundedValues() {
    #expect(throws: ForgeAutonomyValidationError.budgetExceedsSafetyEnvelope(field: "maximumElapsedMilliseconds")) {
        _ = try budget(
            elapsed: UInt64.max,
            actions: 100,
            repairs: 4,
            nonProgress: 6,
            leadElapsed: 1_000,
            leadActions: 10
        )
    }
    #expect(throws: ForgeAutonomyValidationError.budgetExceedsSafetyEnvelope(field: "maximumActions")) {
        _ = try budget(actions: UInt64.max, leadActions: 10)
    }
}

@Test func packageSafetyEnvelopeExactBoundsRemainValid() throws {
    let exact = try ForgeAutonomyBudget(
        policyRevision: 1,
        maximumElapsedMilliseconds: ForgeAutonomyBudget.maximumAllowedElapsedMilliseconds,
        maximumActions: ForgeAutonomyBudget.maximumAllowedActions,
        maximumRepairAttemptsPerDefect: ForgeAutonomyBudget.maximumAllowedRepairAttemptsPerDefect,
        maximumConsecutiveNonProgressActions: ForgeAutonomyBudget.maximumAllowedConsecutiveNonProgressActions,
        checkpointLeadMilliseconds: 1,
        checkpointLeadActions: 1
    )
    #expect(exact.maximumActions == ForgeAutonomyBudget.maximumAllowedActions)
}

@Test func budgetRejectsCheckpointLeadAtOrBeyondHardLimit() {
    #expect(throws: ForgeAutonomyValidationError.invalidCheckpointLead(field: "checkpointLeadActions")) {
        _ = try budget(actions: 10, leadActions: 10)
    }
}

@Test func authorityRejectsZeroRevisionAndEpoch() {
    #expect(throws: ForgeAutonomyValidationError.invalidRevision(field: "missionRevision")) {
        _ = try authority(missionRevision: 0)
    }
    #expect(throws: ForgeAutonomyValidationError.invalidRevision(field: "authorityEpoch")) {
        _ = try authority(authorityEpoch: 0)
    }
}

@Test func authorityRejectsWhitespaceAndPathLikeIdentifiers() {
    #expect(throws: ForgeAutonomyValidationError.invalidIdentifier(field: "projectID")) {
        _ = try ForgeAutonomyAuthority(
            projectID: " ../project ",
            missionID: "mission",
            checkpointID: "checkpoint",
            missionRevision: 1,
            authorityEpoch: 1
        )
    }
}

@Test func checkpointRejectsZeroRevisionEpochAndGeneration() {
    #expect(throws: ForgeAutonomyValidationError.invalidRevision(field: "checkpoint.missionRevision")) {
        _ = try checkpoint(missionRevision: 0)
    }
    #expect(throws: ForgeAutonomyValidationError.invalidRevision(field: "checkpoint.authorityEpoch")) {
        _ = try checkpoint(authorityEpoch: 0)
    }
    #expect(throws: ForgeAutonomyValidationError.invalidCheckpointGeneration) {
        _ = try checkpoint(generation: 0)
    }
}

@Test func decodedProjectionCannotForgeProceed() throws {
    let original = try project(observation: observation(thermal: .critical))
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["disposition"] = "proceed"
    object["reason"] = "withinBudget"
    object["requiresCheckpoint"] = false
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeAutonomyValidationError.forgedProjection) {
        _ = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: tampered)
    }
}

@Test func decodedProjectionCannotForgeAuthorityClassOrGeneration() throws {
    let original = try project()
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["consumesObservationGeneration"] = 999
    let tamperedGeneration = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeAutonomyValidationError.forgedProjection) {
        _ = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: tamperedGeneration)
    }

    object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["projectionAuthority"] = "executionAuthorized"
    let tamperedAuthority = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: tamperedAuthority)
    }
}

@Test func decodedBudgetRevalidatesConstructorInvariants() throws {
    let original = try project()
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedBudget = try #require(object["budget"] as? [String: Any])
    encodedBudget["maximumActions"] = 0
    object["budget"] = encodedBudget
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeAutonomyValidationError.invalidBudget(field: "maximumActions")) {
        _ = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: tampered)
    }
}

@Test func decodedAuthorityRevalidatesOpaqueIdentifiersAndRevisions() throws {
    let original = try project()
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedAuthority = try #require(object["authority"] as? [String: Any])
    encodedAuthority["projectID"] = "../project"
    object["authority"] = encodedAuthority
    let malformedID = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeAutonomyValidationError.invalidIdentifier(field: "projectID")) {
        _ = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: malformedID)
    }

    object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    encodedAuthority = try #require(object["authority"] as? [String: Any])
    encodedAuthority["authorityEpoch"] = 0
    object["authority"] = encodedAuthority
    let zeroEpoch = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeAutonomyValidationError.invalidRevision(field: "authorityEpoch")) {
        _ = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: zeroEpoch)
    }
}

@Test func unknownPressureValueFailsClosedDuringDecode() throws {
    let original = try project()
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedObservation = try #require(object["observation"] as? [String: Any])
    encodedObservation["thermalPressure"] = "impossiblyHot"
    object["observation"] = encodedObservation
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: tampered)
    }
}

@Test func replayedObservationGenerationFailsClosedDuringDecode() throws {
    let original = try project()
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedObservation = try #require(object["observation"] as? [String: Any])
    encodedObservation["lastConsumedObservationGeneration"] = encodedObservation["observationGeneration"]
    object["observation"] = encodedObservation
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeAutonomyValidationError.invalidObservationGeneration) {
        _ = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: tampered)
    }
}

@Test func legacyBareCheckpointBooleanPayloadDoesNotRestoreAsCurrentProjection() throws {
    let original = try project()
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedObservation = try #require(object["observation"] as? [String: Any])
    encodedObservation.removeValue(forKey: "observationGeneration")
    encodedObservation.removeValue(forKey: "lastConsumedObservationGeneration")
    encodedObservation["hasFreshCheckpointForCurrentAuthority"] = true
    object["observation"] = encodedObservation
    let legacyShape = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(ForgeAutonomyCandidateProjection.self, from: legacyShape)
    }
}
