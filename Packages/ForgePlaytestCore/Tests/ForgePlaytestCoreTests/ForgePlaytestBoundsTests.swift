import Testing
@testable import ForgePlaytestCore

@Suite("ForgePlaytest bounds")
struct ForgePlaytestBoundsTests {
    @Test("candidate run rejects unbounded observation arrays before evaluation")
    func candidateRunBoundsObservationArrays() throws {
        let actionObservations = try (1 ... (ForgePlaytestJourney.maximumActions + 1)).map { index in
            try ForgePlaytestCandidateActionObservation(
                actionID: "action-\(index)",
                sequence: index,
                disposition: .reportedDelivered
            )
        }
        #expect(throws: ForgePlaytestValidationError.invalidLimit(field: "run.observations")) {
            _ = try ForgePlaytestCandidateRun(
                runID: "run-overflow",
                journeyID: "journey-1",
                projectID: "project-1",
                sourceRevision: "src-r1",
                checkpointID: "checkpoint-1",
                runtimeVersion: "runtime-1",
                deterministicSeed: 1,
                actionObservations: actionObservations,
                milestoneObservations: [],
                reportedFatalRuntimeErrorCount: 0
            )
        }
    }
}
