import ForgeHistoryCore
import XCTest

final class ForgeHistoryQualityEvidenceTests: XCTestCase {
    func testProjectorPreservesQualityEvidenceInCanonicalCheckpointOrder() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let first = try makeCheckpoint("c1", sequence: 1)
        let second = try makeCheckpoint("c2", parent: first.id, sequence: 2)
        let timeline = try ForgeHistoryTimeline(
            projectID: project,
            checkpoints: [second, first]
        )

        let projection = try ForgeHistoryAcceptedQualityTimelineProjector.project(
            timeline: timeline,
            acceptedQuality: [
                try binding(project: project, checkpoint: second.id, kind: .performance, receipt: "perf-2"),
                try binding(project: project, checkpoint: first.id, kind: .accessibility, receipt: "a11y-1"),
            ]
        )

        XCTAssertEqual(projection.qualityStates.map(\.checkpointID.rawValue), ["c1", "c2"])
        XCTAssertEqual(
            projection.qualityState(for: first.id)?.evidence(kind: .accessibility)?.producerReceiptReference.rawValue,
            "a11y-1"
        )
        XCTAssertEqual(
            projection.qualityState(for: second.id)?.evidence(kind: .performance)?.producerReceiptReference.rawValue,
            "perf-2"
        )
    }

    func testProjectorRejectsCrossProjectQualityBinding() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let otherProject = try ForgeHistoryProjectID("project-b")
        let checkpoint = try makeCheckpoint("c1", sequence: 1)
        let timeline = try ForgeHistoryTimeline(projectID: project, checkpoints: [checkpoint])
        let quality = try binding(
            project: otherProject,
            checkpoint: checkpoint.id,
            kind: .accessibility,
            receipt: "a11y-1"
        )

        XCTAssertThrowsError(
            try ForgeHistoryAcceptedQualityTimelineProjector.project(
                timeline: timeline,
                acceptedQuality: [quality]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryQualityProjectionError,
                .projectMismatch(
                    checkpointID: "c1",
                    expectedProjectID: "project-a",
                    actualProjectID: "project-b"
                )
            )
        }
    }

    func testProjectorRejectsUnknownCheckpoint() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let checkpoint = try makeCheckpoint("c1", sequence: 1)
        let timeline = try ForgeHistoryTimeline(projectID: project, checkpoints: [checkpoint])
        let ghost = try ForgeHistoryCheckpointID("ghost")

        XCTAssertThrowsError(
            try ForgeHistoryAcceptedQualityTimelineProjector.project(
                timeline: timeline,
                acceptedQuality: [
                    try binding(project: project, checkpoint: ghost, kind: .performance, receipt: "perf-ghost"),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryQualityProjectionError,
                .unknownCheckpoint("ghost")
            )
        }
    }

    func testProjectorRejectsDuplicateCheckpointBinding() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let checkpoint = try makeCheckpoint("c1", sequence: 1)
        let timeline = try ForgeHistoryTimeline(projectID: project, checkpoints: [checkpoint])

        XCTAssertThrowsError(
            try ForgeHistoryAcceptedQualityTimelineProjector.project(
                timeline: timeline,
                acceptedQuality: [
                    try binding(project: project, checkpoint: checkpoint.id, kind: .accessibility, receipt: "a11y-1"),
                    try binding(project: project, checkpoint: checkpoint.id, kind: .performance, receipt: "perf-1"),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryQualityProjectionError,
                .duplicateCheckpointBinding("c1")
            )
        }
    }

    func testBindingRejectsEmptyOrDuplicateQualityKinds() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let checkpoint = try ForgeHistoryCheckpointID("c1")

        XCTAssertThrowsError(
            try ForgeHistoryCheckpointQualityBinding(
                projectID: project,
                checkpointID: checkpoint,
                evidence: []
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryQualityProjectionError,
                .emptyQualityEvidence(checkpointID: "c1")
            )
        }

        let first = ForgeHistoryAcceptedQualityEvidenceReference(
            kind: .accessibility,
            producerReceiptReference: try ForgeHistoryReceiptID("a11y-1")
        )
        let second = ForgeHistoryAcceptedQualityEvidenceReference(
            kind: .accessibility,
            producerReceiptReference: try ForgeHistoryReceiptID("a11y-2")
        )
        XCTAssertThrowsError(
            try ForgeHistoryCheckpointQualityBinding(
                projectID: project,
                checkpointID: checkpoint,
                evidence: [first, second]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeHistoryQualityProjectionError,
                .duplicateQualityKind(checkpointID: "c1", kind: .accessibility)
            )
        }
    }

    func testQualityArtifactMustAlreadyBeAttachedToCanonicalCheckpoint() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let attached = ForgeHistoryArtifactReference(
            kind: .performanceReport,
            id: try ForgeHistoryArtifactID("perf-report-1")
        )
        let checkpoint = try makeCheckpoint("c1", sequence: 1, artifacts: [attached])
        let timeline = try ForgeHistoryTimeline(projectID: project, checkpoints: [checkpoint])

        let accepted = ForgeHistoryAcceptedQualityEvidenceReference(
            kind: .performance,
            producerReceiptReference: try ForgeHistoryReceiptID("perf-1"),
            artifactReference: attached
        )
        let projection = try ForgeHistoryAcceptedQualityTimelineProjector.project(
            timeline: timeline,
            acceptedQuality: [
                try ForgeHistoryCheckpointQualityBinding(
                    projectID: project,
                    checkpointID: checkpoint.id,
                    evidence: [accepted]
                ),
            ]
        )
        XCTAssertEqual(
            projection.qualityState(for: checkpoint.id)?.evidence(kind: .performance)?.artifactReference,
            attached
        )

        let unattached = ForgeHistoryArtifactReference(
            kind: .performanceReport,
            id: try ForgeHistoryArtifactID("perf-report-other")
        )
        XCTAssertThrowsError(
            try ForgeHistoryAcceptedQualityTimelineProjector.project(
                timeline: timeline,
                acceptedQuality: [
                    try ForgeHistoryCheckpointQualityBinding(
                        projectID: project,
                        checkpointID: checkpoint.id,
                        evidence: [
                            .init(
                                kind: .performance,
                                producerReceiptReference: try ForgeHistoryReceiptID("perf-2"),
                                artifactReference: unattached
                            ),
                        ]
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHistoryError, .evidenceArtifactNotAttached("perf-report-other"))
        }
    }

    func testProjectionDoesNotInferQualityEvidenceFromGenericCheckpointEvidence() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let artifact = ForgeHistoryArtifactReference(
            kind: .testReport,
            id: try ForgeHistoryArtifactID("test-report-1")
        )
        let checkpoint = try ForgeHistoryCheckpoint(
            id: ForgeHistoryCheckpointID("c1"),
            sequence: 1,
            acceptedAtMilliseconds: 100,
            title: "Accepted",
            artifacts: [artifact],
            evidence: [
                try ForgeHistoryEvidenceClaim(kind: .runtimeTested, artifact: artifact),
            ]
        )
        let timeline = try ForgeHistoryTimeline(projectID: project, checkpoints: [checkpoint])
        let projection = try ForgeHistoryAcceptedQualityTimelineProjector.project(
            timeline: timeline,
            acceptedQuality: []
        )

        XCTAssertTrue(projection.qualityStates.isEmpty)
        XCTAssertNil(projection.qualityState(for: checkpoint.id))
    }

    func testOneProducerReceiptCanRemainOpaqueAcrossDistinctQualityKinds() throws {
        let project = try ForgeHistoryProjectID("project-a")
        let checkpoint = try makeCheckpoint("c1", sequence: 1)
        let receipt = try ForgeHistoryReceiptID("quality-bundle-1")
        let binding = try ForgeHistoryCheckpointQualityBinding(
            projectID: project,
            checkpointID: checkpoint.id,
            evidence: [
                .init(kind: .performance, producerReceiptReference: receipt),
                .init(kind: .accessibility, producerReceiptReference: receipt),
            ]
        )

        XCTAssertEqual(binding.evidence.map(\.kind), [.accessibility, .performance])
        XCTAssertEqual(Set(binding.evidence.map(\.producerReceiptReference)), [receipt])
    }

    private func binding(
        project: ForgeHistoryProjectID,
        checkpoint: ForgeHistoryCheckpointID,
        kind: ForgeHistoryQualityEvidenceKind,
        receipt: String
    ) throws -> ForgeHistoryCheckpointQualityBinding {
        try ForgeHistoryCheckpointQualityBinding(
            projectID: project,
            checkpointID: checkpoint,
            evidence: [
                .init(
                    kind: kind,
                    producerReceiptReference: ForgeHistoryReceiptID(receipt)
                ),
            ]
        )
    }

    private func makeCheckpoint(
        _ rawID: String,
        parent: ForgeHistoryCheckpointID? = nil,
        sequence: UInt64,
        artifacts: [ForgeHistoryArtifactReference] = []
    ) throws -> ForgeHistoryCheckpoint {
        try ForgeHistoryCheckpoint(
            id: ForgeHistoryCheckpointID(rawID),
            parentID: parent,
            sequence: sequence,
            acceptedAtMilliseconds: Int64(sequence * 100),
            title: "Checkpoint \(rawID)",
            artifacts: artifacts
        )
    }
}
