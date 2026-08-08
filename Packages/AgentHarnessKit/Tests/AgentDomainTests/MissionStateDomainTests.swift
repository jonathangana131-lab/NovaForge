import AgentDomain
import Foundation
import XCTest

final class MissionStateDomainTests: XCTestCase {
    func testMissionPhaseSeparatesRecoverableInterruptionFromTerminalFailure() {
        XCTAssertFalse(MissionPhase.interruptedRecoverable.isTerminal)
        XCTAssertTrue(MissionPhase.interruptedRecoverable.canResumeWithoutChangingMissionIdentity)
        XCTAssertTrue(MissionPhase.pausedByPolicy.canResumeWithoutChangingMissionIdentity)
        XCTAssertTrue(MissionPhase.completedWithEvidence.isTerminal)
        XCTAssertTrue(MissionPhase.completedWithKnownLimitations.isTerminal)
        XCTAssertTrue(MissionPhase.failedIrrecoverably.isTerminal)
        XCTAssertFalse(MissionPhase.failedIrrecoverably.canResumeWithoutChangingMissionIdentity)
    }

    func testMissionStageGraphCanonicalizesOrderingAndDependencies() throws {
        let missionID = MissionID(rawValue: uuid(1))
        let understandID = MissionStageID(rawValue: uuid(2))
        let buildID = MissionStageID(rawValue: uuid(3))
        let testID = MissionStageID(rawValue: uuid(4))

        let graph = MissionStageGraph(
            missionID: missionID,
            stages: [
                MissionStage(
                    stageID: testID,
                    kind: .test,
                    title: "Run acceptance",
                    order: 30,
                    dependencies: [buildID, understandID, buildID],
                    status: .pending
                ),
                MissionStage(
                    stageID: understandID,
                    kind: .understand,
                    title: "Understand mission",
                    order: 10,
                    status: .completed
                ),
                MissionStage(
                    stageID: buildID,
                    kind: .implement,
                    title: "Build project",
                    order: 20,
                    dependencies: [understandID],
                    status: .active
                ),
            ]
        )

        XCTAssertNil(graph.validationError)
        XCTAssertEqual(graph.stages.map(\.stageID), [understandID, buildID, testID])
        XCTAssertEqual(graph.stages[2].dependencies, [understandID, buildID])
        XCTAssertEqual(graph.activeStages.map(\.stageID), [buildID])
        XCTAssertFalse(graph.requiredWorkIsSatisfied)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(graph)
        let decoded = try JSONDecoder().decode(MissionStageGraph.self, from: data)
        XCTAssertEqual(decoded, graph)
        XCTAssertEqual(try encoder.encode(decoded), data)
    }

    func testMissionStageGraphRejectsMissingDependencyAndCycles() {
        let missionID = MissionID(rawValue: uuid(10))
        let firstID = MissionStageID(rawValue: uuid(11))
        let secondID = MissionStageID(rawValue: uuid(12))
        let unknownID = MissionStageID(rawValue: uuid(13))

        let missing = MissionStageGraph(
            missionID: missionID,
            stages: [
                MissionStage(
                    stageID: firstID,
                    kind: .implement,
                    title: "Build",
                    order: 1,
                    dependencies: [unknownID]
                ),
            ]
        )
        XCTAssertEqual(missing.validationError, .missingDependency)

        let cycle = MissionStageGraph(
            missionID: missionID,
            stages: [
                MissionStage(
                    stageID: firstID,
                    kind: .implement,
                    title: "Build",
                    order: 1,
                    dependencies: [secondID]
                ),
                MissionStage(
                    stageID: secondID,
                    kind: .test,
                    title: "Test",
                    order: 2,
                    dependencies: [firstID]
                ),
            ]
        )
        XCTAssertEqual(cycle.validationError, .dependencyCycle)
    }

    func testRequiredStagesCannotBeDeferredAndMustCompleteForAcceptance() {
        let missionID = MissionID(rawValue: uuid(20))
        let requiredID = MissionStageID(rawValue: uuid(21))
        let optionalID = MissionStageID(rawValue: uuid(22))

        let invalid = MissionStageGraph(
            missionID: missionID,
            stages: [
                MissionStage(
                    stageID: requiredID,
                    kind: .accessibility,
                    title: "Accessibility pass",
                    order: 1,
                    required: true,
                    status: .deferred
                ),
            ]
        )
        XCTAssertEqual(invalid.validationError, .requiredStageDeferred)

        let satisfied = MissionStageGraph(
            missionID: missionID,
            stages: [
                MissionStage(
                    stageID: requiredID,
                    kind: .accessibility,
                    title: "Accessibility pass",
                    order: 1,
                    required: true,
                    status: .completed
                ),
                MissionStage(
                    stageID: optionalID,
                    kind: .custom,
                    title: "Optional experiment",
                    order: 2,
                    required: false,
                    status: .deferred
                ),
            ]
        )
        XCTAssertNil(satisfied.validationError)
        XCTAssertTrue(satisfied.requiredWorkIsSatisfied)
    }

    private func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, value
        ))
    }
}
