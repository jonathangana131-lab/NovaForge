import Foundation
import Testing
@testable import ForgePlaytestCore

@Suite("ForgePlaytestCore")
struct ForgePlaytestCoreTests {
    private func milestone(_ id: String, required: Bool = true) throws -> ForgePlaytestMilestone {
        try ForgePlaytestMilestone(id: id, description: "Reach \(id)", required: required)
    }

    private func activate(_ sequence: Int, id: String, target: String, milestones: [String] = []) throws -> ForgePlaytestAction {
        try ForgePlaytestAction(
            id: id,
            sequence: sequence,
            kind: .controlActivate,
            semanticTargetID: target,
            expectedMilestoneIDs: milestones
        )
    }

    private func goalJourney(sourceRevision: String = "src-r1") throws -> ForgePlaytestJourney {
        try ForgePlaytestJourney(
            journeyID: "journey-goal-1",
            projectID: "project-1",
            sourceRevision: sourceRevision,
            checkpointID: "checkpoint-4",
            runtimeVersion: "runtime-7",
            persona: .goalRunner,
            deterministicSeed: 42,
            maximumPlannedActions: 4,
            milestones: [milestone("goal-reached")],
            actions: [
                activate(1, id: "start", target: "start-button"),
                activate(2, id: "finish", target: "finish-button", milestones: ["goal-reached"]),
            ]
        )
    }

    private func delivered(_ id: String, _ sequence: Int) throws -> ForgePlaytestCandidateActionObservation {
        try ForgePlaytestCandidateActionObservation(actionID: id, sequence: sequence, disposition: .reportedDelivered)
    }

    private func run(
        journey: ForgePlaytestJourney,
        sourceRevision: String? = nil,
        actions: [ForgePlaytestCandidateActionObservation]? = nil,
        milestones: [ForgePlaytestCandidateMilestoneObservation]? = nil,
        fatalErrors: Int = 0
    ) throws -> ForgePlaytestCandidateRun {
        try ForgePlaytestCandidateRun(
            runID: "run-1",
            journeyID: journey.journeyID,
            projectID: journey.projectID,
            sourceRevision: sourceRevision ?? journey.sourceRevision,
            checkpointID: journey.checkpointID,
            runtimeVersion: journey.runtimeVersion,
            deterministicSeed: journey.deterministicSeed,
            actionObservations: actions ?? [delivered("start", 1), delivered("finish", 2)],
            milestoneObservations: milestones ?? [
                try ForgePlaytestCandidateMilestoneObservation(
                    milestoneID: "goal-reached",
                    firstObservedAfterActionSequence: 2
                )
            ],
            reportedFatalRuntimeErrorCount: fatalErrors
        )
    }

    @Test("goal runner projects satisfied candidate but never authority")
    func candidateSatisfiedIsNonAuthorizing() throws {
        let journey = try goalJourney()
        let projection = try ForgePlaytestCandidateEvaluator.project(journey: journey, run: run(journey: journey))
        #expect(projection.disposition == .satisfiedCandidate)
        #expect(projection.authorizesExecution == false)
        #expect(projection.authorizesCompletion == false)
    }

    @Test("exact source revision is replay boundary")
    func rejectsCrossRevisionReplay() throws {
        let journey = try goalJourney()
        #expect(throws: ForgePlaytestValidationError.candidateRunIdentityMismatch) {
            _ = try ForgePlaytestCandidateEvaluator.project(
                journey: journey,
                run: run(journey: journey, sourceRevision: "src-r0")
            )
        }
    }

    @Test("action trace must preserve exact journey order")
    func rejectsReorderedActionIdentity() throws {
        let journey = try goalJourney()
        let reversed = [try delivered("finish", 1), try delivered("start", 2)]
        #expect(throws: ForgePlaytestValidationError.observationActionMismatch) {
            _ = try ForgePlaytestCandidateEvaluator.project(
                journey: journey,
                run: run(journey: journey, actions: reversed)
            )
        }
    }

    @Test("partial trace is incomplete rather than passed")
    func partialTraceIsIncomplete() throws {
        let journey = try goalJourney()
        let candidate = try run(journey: journey, actions: [delivered("start", 1)], milestones: [])
        let projection = try ForgePlaytestCandidateEvaluator.project(journey: journey, run: candidate)
        guard case let .incomplete(failures) = projection.disposition else {
            Issue.record("expected incomplete projection")
            return
        }
        #expect(failures.contains(.incompleteActionTrace(expected: 2, observed: 1)))
        #expect(failures.contains(.requiredMilestoneMissing(milestoneID: "goal-reached")))
    }

    @Test("completed trace missing required goal is candidate failure")
    func missingRequiredMilestoneFails() throws {
        let journey = try goalJourney()
        let projection = try ForgePlaytestCandidateEvaluator.project(
            journey: journey,
            run: run(journey: journey, milestones: [])
        )
        guard case let .failedCandidate(failures) = projection.disposition else {
            Issue.record("expected candidate failure")
            return
        }
        #expect(failures.contains(.requiredMilestoneMissing(milestoneID: "goal-reached")))
    }

    @Test("reported runtime rejection blocks candidate success")
    func rejectedActionFailsCandidate() throws {
        let journey = try goalJourney()
        let observations = [
            try delivered("start", 1),
            try ForgePlaytestCandidateActionObservation(
                actionID: "finish",
                sequence: 2,
                disposition: .reportedRejected
            ),
        ]
        let projection = try ForgePlaytestCandidateEvaluator.project(
            journey: journey,
            run: run(journey: journey, actions: observations)
        )
        guard case let .failedCandidate(failures) = projection.disposition else {
            Issue.record("expected candidate failure")
            return
        }
        #expect(failures.contains(.actionNotReportedDelivered(actionID: "finish")))
    }

    @Test("reported fatal runtime error blocks candidate success")
    func fatalRuntimeErrorFailsCandidate() throws {
        let journey = try goalJourney()
        let projection = try ForgePlaytestCandidateEvaluator.project(
            journey: journey,
            run: run(journey: journey, fatalErrors: 1)
        )
        guard case let .failedCandidate(failures) = projection.disposition else {
            Issue.record("expected candidate failure")
            return
        }
        #expect(failures.contains(.reportedFatalRuntimeErrors(count: 1)))
    }

    @Test("milestone cannot appear before the action that expects it")
    func rejectsCausallyEarlyMilestone() throws {
        let journey = try goalJourney()
        let early = [
            try ForgePlaytestCandidateMilestoneObservation(
                milestoneID: "goal-reached",
                firstObservedAfterActionSequence: 1
            )
        ]
        let projection = try ForgePlaytestCandidateEvaluator.project(
            journey: journey,
            run: run(journey: journey, milestones: early)
        )
        guard case let .failedCandidate(failures) = projection.disposition else {
            Issue.record("expected candidate failure")
            return
        }
        #expect(failures.contains(.milestoneObservedBeforeExpectedAction(milestoneID: "goal-reached")))
    }

    @Test("persistence persona requires restart and post-restart required milestone")
    func persistenceJourneyRequiresRealRecoveryShape() throws {
        let save = try milestone("save-restored")
        #expect(throws: ForgePlaytestValidationError.persistenceJourneyMissingRestart) {
            _ = try ForgePlaytestJourney(
                journeyID: "persist-1",
                projectID: "project-1",
                sourceRevision: "src-r1",
                checkpointID: "checkpoint-1",
                runtimeVersion: "runtime-1",
                persona: .persistenceTester,
                deterministicSeed: 1,
                maximumPlannedActions: 2,
                milestones: [save],
                actions: [activate(1, id: "save", target: "save-button", milestones: ["save-restored"])]
            )
        }

        let restart = try ForgePlaytestAction(id: "restart", sequence: 2, kind: .runtimeRestart)
        #expect(throws: ForgePlaytestValidationError.persistenceJourneyMissingPostRestartMilestone) {
            _ = try ForgePlaytestJourney(
                journeyID: "persist-2",
                projectID: "project-1",
                sourceRevision: "src-r1",
                checkpointID: "checkpoint-1",
                runtimeVersion: "runtime-1",
                persona: .persistenceTester,
                deterministicSeed: 1,
                maximumPlannedActions: 2,
                milestones: [save],
                actions: [activate(1, id: "save", target: "save-button", milestones: ["save-restored"]), restart]
            )
        }
    }

    @Test("valid persistence journey places recovery proof after restart")
    func validPersistenceJourney() throws {
        let restored = try milestone("save-restored")
        let journey = try ForgePlaytestJourney(
            journeyID: "persist-ok",
            projectID: "project-1",
            sourceRevision: "src-r1",
            checkpointID: "checkpoint-1",
            runtimeVersion: "runtime-1",
            persona: .persistenceTester,
            deterministicSeed: 1,
            maximumPlannedActions: 3,
            milestones: [restored],
            actions: [
                activate(1, id: "save", target: "save-button"),
                try ForgePlaytestAction(id: "restart", sequence: 2, kind: .runtimeRestart),
                try ForgePlaytestAction(
                    id: "observe-restored",
                    sequence: 3,
                    kind: .observe,
                    expectedMilestoneIDs: ["save-restored"]
                ),
            ]
        )
        #expect(journey.persona == .persistenceTester)
    }

    @Test("action payload validation follows semantic kind")
    func rejectsInvalidActionPayloads() throws {
        #expect(throws: ForgePlaytestValidationError.invalidActionPayload) {
            _ = try ForgePlaytestAction(id: "bad", sequence: 1, kind: .controlActivate)
        }
        #expect(throws: ForgePlaytestValidationError.invalidActionPayload) {
            _ = try ForgePlaytestAction(
                id: "bad-value",
                sequence: 1,
                kind: .actionSetValue,
                semanticTargetID: "throttle",
                numericValue: .infinity
            )
        }
        #expect(throws: ForgePlaytestValidationError.invalidActionPayload) {
            _ = try ForgePlaytestAction(
                id: "bad-gesture",
                sequence: 1,
                kind: .gesturePerform,
                semanticTargetID: "look",
                gestureDurationMilliseconds: 30_001
            )
        }
    }

    @Test("path-like and padded identities fail closed")
    func rejectsNonCanonicalIdentifiers() throws {
        #expect(throws: ForgePlaytestValidationError.invalidIdentifier(field: "milestone.id")) {
            _ = try ForgePlaytestMilestone(id: " ../goal", description: "Goal", required: true)
        }
        #expect(throws: ForgePlaytestValidationError.invalidIdentifier(field: "action.id")) {
            _ = try ForgePlaytestAction(id: "path/to/action", sequence: 1, kind: .runtimeRestart)
        }
    }

    @Test("journey decode revalidates action order")
    func decodeRejectsTamperedJourney() throws {
        let journey = try goalJourney()
        let encoder = JSONEncoder()
        let data = try encoder.encode(journey)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var tampered = object
        var actions = try #require(tampered["actions"] as? [[String: Any]])
        actions[1]["sequence"] = 9
        tampered["actions"] = actions
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ForgePlaytestJourney.self, from: tamperedData)
        }
    }

    @Test("candidate run decode revalidates observation order")
    func decodeRejectsTamperedRun() throws {
        let journey = try goalJourney()
        let candidate = try run(journey: journey)
        let data = try JSONEncoder().encode(candidate)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var tampered = object
        var observations = try #require(tampered["actionObservations"] as? [[String: Any]])
        observations[0]["sequence"] = 2
        tampered["actionObservations"] = observations
        let tamperedData = try JSONSerialization.data(withJSONObject: tampered)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ForgePlaytestCandidateRun.self, from: tamperedData)
        }
    }

    @Test("candidate observation count cannot exceed journey actions")
    func rejectsObservationOverflow() throws {
        let journey = try goalJourney()
        let observations = [
            try delivered("start", 1),
            try delivered("finish", 2),
            try delivered("extra", 3),
        ]
        let candidate = try run(journey: journey, actions: observations)
        #expect(throws: ForgePlaytestValidationError.observationCountExceedsActions) {
            _ = try ForgePlaytestCandidateEvaluator.project(journey: journey, run: candidate)
        }
    }
}
