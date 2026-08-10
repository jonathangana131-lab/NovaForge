import Testing
@testable import ForgePlaytestCore

@Suite("ForgePlaytest persistence causality review")
struct ForgePlaytestPersistenceCausalityReviewTests {
    @Test("required persistence milestone must be observed after restart")
    func requiredMilestoneObservedBeforeRestartCannotSatisfy() throws {
        let restored = try ForgePlaytestMilestone(
            id: "save-restored",
            description: "Saved state is restored after runtime restart",
            required: true
        )

        let journey = try ForgePlaytestJourney(
            journeyID: "persist-causal-review",
            projectID: "project-1",
            sourceRevision: "src-r1",
            checkpointID: "checkpoint-1",
            runtimeVersion: "runtime-1",
            persona: .persistenceTester,
            deterministicSeed: 7,
            maximumPlannedActions: 3,
            milestones: [restored],
            actions: [
                try ForgePlaytestAction(
                    id: "save",
                    sequence: 1,
                    kind: .controlActivate,
                    semanticTargetID: "save-button",
                    expectedMilestoneIDs: ["save-restored"]
                ),
                try ForgePlaytestAction(
                    id: "restart",
                    sequence: 2,
                    kind: .runtimeRestart
                ),
                try ForgePlaytestAction(
                    id: "observe-restored",
                    sequence: 3,
                    kind: .observe,
                    expectedMilestoneIDs: ["save-restored"]
                ),
            ]
        )

        let run = try ForgePlaytestCandidateRun(
            runID: "run-persist-causal-review",
            journeyID: journey.journeyID,
            projectID: journey.projectID,
            sourceRevision: journey.sourceRevision,
            checkpointID: journey.checkpointID,
            runtimeVersion: journey.runtimeVersion,
            deterministicSeed: journey.deterministicSeed,
            actionObservations: [
                try ForgePlaytestCandidateActionObservation(
                    actionID: "save",
                    sequence: 1,
                    disposition: .reportedDelivered
                ),
                try ForgePlaytestCandidateActionObservation(
                    actionID: "restart",
                    sequence: 2,
                    disposition: .reportedDelivered
                ),
                try ForgePlaytestCandidateActionObservation(
                    actionID: "observe-restored",
                    sequence: 3,
                    disposition: .reportedDelivered
                ),
            ],
            milestoneObservations: [
                try ForgePlaytestCandidateMilestoneObservation(
                    milestoneID: "save-restored",
                    firstObservedAfterActionSequence: 1
                )
            ],
            reportedFatalRuntimeErrorCount: 0
        )

        let projection = try ForgePlaytestCandidateEvaluator.project(journey: journey, run: run)

        #expect(
            projection.disposition != .satisfiedCandidate,
            "A persistence milestone observed before runtimeRestart must not satisfy the journey's required post-restart proof."
        )
    }
}
