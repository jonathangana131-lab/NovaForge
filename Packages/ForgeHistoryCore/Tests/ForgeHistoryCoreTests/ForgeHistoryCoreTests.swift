import ForgeHistoryCore
import Foundation
import XCTest

final class ForgeHistoryCoreTests: XCTestCase {
    func testOpaqueStrongIdentifiersAreStableAndRejectPathLikeOrWhitespaceValues() throws {
        XCTAssertEqual(try checkpointID(" checkpoint-1 ").rawValue, "checkpoint-1")
        XCTAssertEqual(try missionID("mission:v13.2").rawValue, "mission:v13.2")
        XCTAssertThrowsError(try checkpointID("checkpoint one"))
        XCTAssertThrowsError(try artifactID("/tmp/checkpoint"))
        XCTAssertThrowsError(try projectID(""))
    }

    func testTimelineCanonicalizesSequenceOrderWithoutInventingVisualEvidence() throws {
        let first = try checkpoint(
            "c1",
            sequence: 1,
            acceptedAt: 100,
            artifacts: [.init(kind: .sourceSnapshot, id: artifactID("source-1"))]
        )
        let second = try checkpoint(
            "c2",
            parent: "c1",
            sequence: 2,
            acceptedAt: 200,
            artifacts: [.init(kind: .screenshot, id: artifactID("shot-2"))]
        )
        let timeline = try makeTimeline([second, first])

        XCTAssertEqual(timeline.checkpoints.map(\.id.rawValue), ["c1", "c2"])
        XCTAssertTrue(timeline.visualTimeMachineItems[0].screenshotReferences.isEmpty)
        XCTAssertEqual(
            timeline.visualTimeMachineItems[1].primaryScreenshotReference?.id.rawValue,
            "shot-2"
        )
        XCTAssertEqual(timeline.latestCheckpoint?.id.rawValue, "c2")
    }

    func testDuplicateCheckpointIdentityAndSequenceFailClosed() throws {
        let first = try checkpoint("c1", sequence: 1, acceptedAt: 100)
        let duplicateID = try checkpoint("c1", sequence: 2, acceptedAt: 200)
        let duplicateSequence = try checkpoint("c2", sequence: 1, acceptedAt: 200)

        XCTAssertThrowsError(try makeTimeline([first, duplicateID])) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .duplicateCheckpointID("c1"))
        }
        XCTAssertThrowsError(try makeTimeline([first, duplicateSequence])) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .duplicateSequence(1))
        }
    }

    func testParentMustExistEarlierAndCannotTravelBackwardInTime() throws {
        let missing = try checkpoint("c2", parent: "ghost", sequence: 2, acceptedAt: 200)
        XCTAssertThrowsError(try makeTimeline([missing])) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .missingParent(checkpointID: "c2", parentID: "ghost")
            )
        }

        let child = try checkpoint("c1", parent: "c2", sequence: 1, acceptedAt: 100)
        let futureParent = try checkpoint("c2", sequence: 2, acceptedAt: 200)
        XCTAssertThrowsError(try makeTimeline([child, futureParent])) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .parentNotEarlier(checkpointID: "c1", parentID: "c2")
            )
        }

        let parent = try checkpoint("c1", sequence: 1, acceptedAt: 200)
        let earlierChild = try checkpoint("c2", parent: "c1", sequence: 2, acceptedAt: 100)
        XCTAssertThrowsError(try makeTimeline([parent, earlierChild])) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .timestampPrecedesParent(checkpointID: "c2", parentID: "c1")
            )
        }
    }

    func testBranchLineageAndChildrenRemainExact() throws {
        let root = try checkpoint("root", sequence: 1, acceptedAt: 100)
        let main = try checkpoint("main-2", parent: "root", sequence: 2, acceptedAt: 200)
        let branch = try checkpoint("wild-idea", parent: "root", sequence: 3, acceptedAt: 300)
        let branchChild = try checkpoint("wild-idea-2", parent: "wild-idea", sequence: 4, acceptedAt: 400)
        let timeline = try makeTimeline([branchChild, main, root, branch])

        XCTAssertEqual(
            try timeline.lineage(to: checkpointID("wild-idea-2")).map(\.id.rawValue),
            ["root", "wild-idea", "wild-idea-2"]
        )
        XCTAssertEqual(
            try timeline.children(of: checkpointID("root")).map(\.id.rawValue),
            ["main-2", "wild-idea"]
        )
    }

    func testEvidenceMustBeProvenAndArtifactBackedWhenItReferencesAnArtifact() throws {
        let screenshot = ForgeHistoryArtifactReference(kind: .screenshot, id: try artifactID("shot"))
        let visualClaim = try evidence(.visuallyInspected, artifact: screenshot)

        XCTAssertNoThrow(
            try checkpoint(
                "c1",
                sequence: 1,
                acceptedAt: 100,
                artifacts: [screenshot],
                evidence: [visualClaim]
            )
        )
        XCTAssertThrowsError(
            try checkpoint("c1", sequence: 1, acceptedAt: 100, evidence: [visualClaim])
        ) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .evidenceArtifactNotAttached("shot"))
        }

        let unproven = try evidence(.compiled)
        XCTAssertThrowsError(
            try checkpoint("c1", sequence: 1, acceptedAt: 100, evidence: [unproven])
        ) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .unprovenEvidence(.compiled))
        }
    }

    func testCheckpointExecutionReceiptCanProveEvidenceWithoutDuplicatingReceiptPerClaim() throws {
        let claim = try evidence(.runtimeTested, environment: .simulator)
        let checkpoint = try ForgeHistoryCheckpoint(
            id: checkpointID("c1"),
            sequence: 1,
            acceptedAtMilliseconds: 100,
            title: "Runnable",
            acceptedExecutionReceiptReference: receiptID("run-1"),
            evidence: [claim]
        )
        XCTAssertEqual(checkpoint.evidence, [claim])
        XCTAssertEqual(checkpoint.acceptedExecutionReceiptReference?.rawValue, "run-1")
    }

    func testComparisonOnlySurfacesRecordedPairsAndDirectDiffs() throws {
        let beforeGenerated = try evidence(.generated, receipt: receiptID("gen-before"))
        let before = try checkpoint(
            "before",
            sequence: 1,
            acceptedAt: 100,
            artifacts: [
                .init(kind: .sourceSnapshot, id: artifactID("src-before")),
                .init(kind: .screenshot, id: artifactID("shot-before")),
            ],
            evidence: [beforeGenerated],
            limitations: ["Audio not tested"]
        )
        let runtimeClaim = try evidence(.runtimeTested, environment: .simulator, receipt: receiptID("runtime-after"))
        let after = try checkpoint(
            "after",
            parent: "before",
            sequence: 2,
            acceptedAt: 200,
            artifacts: [
                .init(kind: .sourceSnapshot, id: artifactID("src-after")),
                .init(kind: .sourceDiff, id: artifactID("diff-before-after")),
                .init(kind: .testReport, id: artifactID("tests-after")),
            ],
            evidence: [beforeGenerated, runtimeClaim],
            limitations: ["Controller mapping remains unverified"]
        )
        let timeline = try makeTimeline([before, after])
        let comparison = try timeline.comparison(from: before.id, to: after.id)

        XCTAssertTrue(comparison.hasSourcePair)
        XCTAssertFalse(comparison.hasVisualPair)
        XCTAssertEqual(comparison.beforeScreenshots.first?.id.rawValue, "shot-before")
        XCTAssertTrue(comparison.afterScreenshots.isEmpty)
        XCTAssertEqual(comparison.directRecordedSourceDiff?.id.rawValue, "diff-before-after")
        XCTAssertEqual(comparison.addedEvidence.map(\.kind), [.runtimeTested])
        XCTAssertEqual(comparison.addedLimitations, ["Controller mapping remains unverified"])
        XCTAssertEqual(comparison.resolvedLimitations, ["Audio not tested"])
    }

    func testRecordedDirectDiffIsNotReusedForNonParentComparison() throws {
        let root = try checkpoint("root", sequence: 1, acceptedAt: 100)
        let middle = try checkpoint("middle", parent: "root", sequence: 2, acceptedAt: 200)
        let end = try checkpoint(
            "end",
            parent: "middle",
            sequence: 3,
            acceptedAt: 300,
            artifacts: [.init(kind: .sourceDiff, id: artifactID("middle-to-end"))]
        )
        let timeline = try makeTimeline([root, middle, end])

        XCTAssertEqual(
            try timeline.comparison(from: middle.id, to: end.id).directRecordedSourceDiff?.id.rawValue,
            "middle-to-end"
        )
        XCTAssertNil(try timeline.comparison(from: root.id, to: end.id).directRecordedSourceDiff)
    }

    func testRestoreForkAndCompareAreBoundIntentsNotExecutionClaims() throws {
        let first = try checkpoint("c1", sequence: 1, acceptedAt: 100)
        let second = try checkpoint("c2", parent: "c1", sequence: 2, acceptedAt: 200)
        let timeline = try makeTimeline([first, second])
        let project = try projectID("project-1")

        XCTAssertEqual(
            try timeline.restoreIntent(to: first.id),
            .restore(projectID: project, checkpointID: first.id)
        )
        XCTAssertEqual(
            try timeline.forkIntent(from: first.id),
            .fork(projectID: project, checkpointID: first.id)
        )
        XCTAssertEqual(
            try timeline.compareIntent(from: first.id, to: second.id),
            .compare(projectID: project, from: first.id, to: second.id)
        )
    }

    func testUnknownAndIdenticalHistoryActionsFailClosed() throws {
        let only = try checkpoint("c1", sequence: 1, acceptedAt: 100)
        let timeline = try makeTimeline([only])

        XCTAssertThrowsError(try timeline.restoreIntent(to: checkpointID("ghost"))) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .unknownCheckpoint("ghost"))
        }
        XCTAssertThrowsError(try timeline.comparison(from: only.id, to: only.id)) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .identicalComparisonEndpoints("c1"))
        }
    }

    func testEnvironmentVerificationRequiresExecutionReceiptNotJustAnArtifact() throws {
        let screenshot = ForgeHistoryArtifactReference(kind: .screenshot, id: try artifactID("device-shot"))
        let simulatorClaim = try evidence(
            .simulatorVerified,
            environment: .simulator,
            artifact: screenshot
        )

        XCTAssertThrowsError(
            try checkpoint(
                "c1",
                sequence: 1,
                acceptedAt: 100,
                artifacts: [screenshot],
                evidence: [simulatorClaim]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .environmentVerificationRequiresReceipt(.simulatorVerified)
            )
        }

        XCTAssertNoThrow(
            try ForgeHistoryCheckpoint(
                id: checkpointID("c1"),
                sequence: 1,
                acceptedAtMilliseconds: 100,
                title: "Simulator proof",
                acceptedExecutionReceiptReference: receiptID("sim-receipt"),
                artifacts: [screenshot],
                evidence: [simulatorClaim]
            )
        )
    }

    func testSimulatorAndPhysicalDeviceEvidenceCannotBeMislabelled() throws {
        XCTAssertNoThrow(
            try evidence(.simulatorVerified, environment: .simulator, receipt: receiptID("sim-proof"))
        )
        XCTAssertNoThrow(
            try evidence(.physicalDeviceVerified, environment: .iPhonePhysical, receipt: receiptID("phone-proof"))
        )

        XCTAssertThrowsError(
            try evidence(.physicalDeviceVerified, environment: .simulator, receipt: receiptID("bad"))
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .invalidEvidenceEnvironment(kind: .physicalDeviceVerified, environment: .simulator)
            )
        }
        XCTAssertThrowsError(
            try evidence(.simulatorVerified, environment: .iPhonePhysical, receipt: receiptID("bad"))
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .invalidEvidenceEnvironment(kind: .simulatorVerified, environment: .iPhonePhysical)
            )
        }
    }

    func testCheckpointNormalizesHumanTextAndCanonicalizesEvidence() throws {
        let claim = try evidence(.runtimeTested, environment: .simulator, receipt: receiptID("run-proof"))
        let checkpoint = try ForgeHistoryCheckpoint(
            id: checkpointID("c1"),
            sequence: 1,
            acceptedAtMilliseconds: 100,
            title: "  First runnable build  ",
            summary: "   ",
            evidence: [claim, claim],
            knownLimitations: [" Audio not tested ", "", "Audio not tested"]
        )

        XCTAssertEqual(checkpoint.title, "First runnable build")
        XCTAssertNil(checkpoint.summary)
        XCTAssertEqual(checkpoint.evidence, [claim])
        XCTAssertEqual(checkpoint.knownLimitations, ["Audio not tested"])
    }

    func testDuplicateArtifactReferenceFailsClosedEvenAcrossKinds() throws {
        let reference = try artifactID("artifact-1")
        XCTAssertThrowsError(
            try checkpoint(
                "c1",
                sequence: 1,
                acceptedAt: 100,
                artifacts: [
                    .init(kind: .screenshot, id: reference),
                    .init(kind: .sourceSnapshot, id: reference),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .duplicateArtifactReference("artifact-1"))
        }
    }

    func testTimelineRoundTripRevalidatesDecodedLineage() throws {
        let first = try checkpoint("c1", sequence: 1, acceptedAt: 100)
        let second = try checkpoint("c2", parent: "c1", sequence: 2, acceptedAt: 200)
        let timeline = try makeTimeline([first, second])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(timeline)

        XCTAssertEqual(try JSONDecoder().decode(ForgeHistoryTimeline.self, from: encoded), timeline)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var checkpoints = try XCTUnwrap(object["checkpoints"] as? [[String: Any]])
        checkpoints[1]["parentID"] = "ghost"
        object["checkpoints"] = checkpoints
        let malformed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeHistoryTimeline.self, from: malformed)) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .missingParent(checkpointID: "c2", parentID: "ghost")
            )
        }
    }

    func testCanonicalOrderingProducesDeterministicEncoding() throws {
        let shot = ForgeHistoryArtifactReference(kind: .screenshot, id: try artifactID("shot"))
        let source = ForgeHistoryArtifactReference(kind: .sourceSnapshot, id: try artifactID("source"))
        let generated = try evidence(.generated, receipt: receiptID("generated"))
        let runtime = try evidence(.runtimeTested, environment: .simulator, receipt: receiptID("runtime"))
        let left = try checkpoint(
            "c1",
            sequence: 1,
            acceptedAt: 100,
            artifacts: [shot, source],
            evidence: [runtime, generated]
        )
        let right = try checkpoint(
            "c1",
            sequence: 1,
            acceptedAt: 100,
            artifacts: [source, shot],
            evidence: [generated, runtime]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        XCTAssertEqual(try encoder.encode(left), try encoder.encode(right))
    }

    func testProjectTimelineCanCrossMissionsWhileMissionScopedTimelineFailsClosed() throws {
        let missionA = try missionID("mission-a")
        let missionB = try missionID("mission-b")
        let first = try checkpoint(
            "c1",
            mission: missionA,
            sequence: 1,
            acceptedAt: 100
        )
        let second = try checkpoint(
            "c2",
            parent: "c1",
            mission: missionB,
            sequence: 2,
            acceptedAt: 200
        )

        let projectTimeline = try ForgeHistoryTimeline(
            projectID: projectID("project-1"),
            checkpoints: [second, first]
        )
        XCTAssertEqual(
            projectTimeline.visualTimeMachineItems.map { $0.originatingMissionID?.rawValue },
            ["mission-a", "mission-b"]
        )

        XCTAssertThrowsError(
            try ForgeHistoryTimeline(
                projectID: projectID("project-1"),
                missionID: missionA,
                checkpoints: [first, second]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryError,
                .missionScopeMismatch(
                    checkpointID: "c2",
                    expectedMissionID: "mission-a",
                    actualMissionID: "mission-b"
                )
            )
        }

        XCTAssertNoThrow(
            try ForgeHistoryTimeline(
                projectID: projectID("project-1"),
                missionID: missionA,
                checkpoints: [first]
            )
        )
    }

    func testEmptyTimelineIsValidAndMakesNoCurrentStateClaim() throws {
        let timeline = try makeTimeline([])
        XCTAssertNil(timeline.latestCheckpoint)
        XCTAssertTrue(timeline.visualTimeMachineItems.isEmpty)
    }

    private func makeTimeline(_ checkpoints: [ForgeHistoryCheckpoint]) throws -> ForgeHistoryTimeline {
        try ForgeHistoryTimeline(
            projectID: projectID("project-1"),
            checkpoints: checkpoints
        )
    }

    private func checkpoint(
        _ value: String,
        parent: String? = nil,
        mission: ForgeHistoryMissionID? = nil,
        sequence: UInt64,
        acceptedAt: Int64,
        artifacts: [ForgeHistoryArtifactReference] = [],
        evidence: [ForgeHistoryEvidenceClaim] = [],
        limitations: [String] = []
    ) throws -> ForgeHistoryCheckpoint {
        try ForgeHistoryCheckpoint(
            id: checkpointID(value),
            parentID: try parent.map(checkpointID),
            originatingMissionID: mission,
            sequence: sequence,
            acceptedAtMilliseconds: acceptedAt,
            title: value,
            artifacts: artifacts,
            evidence: evidence,
            knownLimitations: limitations
        )
    }

    private func evidence(
        _ kind: ForgeHistoryEvidenceKind,
        environment: ForgeHistoryEvidenceEnvironment = .unspecified,
        artifact: ForgeHistoryArtifactReference? = nil,
        receipt: ForgeHistoryReceiptID? = nil
    ) throws -> ForgeHistoryEvidenceClaim {
        try ForgeHistoryEvidenceClaim(
            kind: kind,
            environment: environment,
            artifact: artifact,
            receiptReference: receipt
        )
    }

    private func projectID(_ value: String) throws -> ForgeHistoryProjectID {
        try ForgeHistoryProjectID(value)
    }

    private func missionID(_ value: String) throws -> ForgeHistoryMissionID {
        try ForgeHistoryMissionID(value)
    }

    private func checkpointID(_ value: String) throws -> ForgeHistoryCheckpointID {
        try ForgeHistoryCheckpointID(value)
    }

    private func artifactID(_ value: String) throws -> ForgeHistoryArtifactID {
        try ForgeHistoryArtifactID(value)
    }

    private func receiptID(_ value: String) throws -> ForgeHistoryReceiptID {
        try ForgeHistoryReceiptID(value)
    }
}
