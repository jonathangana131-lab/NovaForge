import ForgeGhostBuildCore
import Foundation
import XCTest

final class ForgeGhostBuildCoreTests: XCTestCase {
    func testIdentifiersRejectAliasingWhitespaceAndControls() throws {
        XCTAssertThrowsError(try ForgeGhostBuildProjectID(" project-a"))
        XCTAssertThrowsError(try ForgeGhostBuildReceiptID("receipt\n1"))
        XCTAssertEqual(try ForgeGhostBuildProjectID("project-a").rawValue, "project-a")
        XCTAssertThrowsError(try ForgeGhostBuildProjectStateID(" state-a"))
        XCTAssertEqual(try ForgeGhostBuildProjectStateID("state with interior spaces").rawValue, "state with interior spaces")
    }

    func testReadyCandidateRequiresMaterializedDifferentStateAndReceipt() throws {
        let base = try state("accepted:1")
        XCTAssertThrowsError(try candidate(
            "c1",
            ordinal: 1,
            baseState: base,
            status: .previewReady,
            candidateState: nil,
            materializationReceipt: nil
        )) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .invalidCandidateShape)
        }
        XCTAssertThrowsError(try candidate(
            "c1",
            ordinal: 1,
            baseState: base,
            status: .previewReady,
            candidateState: base,
            materializationReceipt: try receipt("mat:1")
        )) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .candidateStateMatchesSource)
        }
    }

    func testFailedCandidateCannotCarryPreviewStateOrArtifacts() throws {
        let base = try state("accepted:1")
        let screenshot = ForgeGhostBuildArtifactReference(kind: .screenshot, id: try artifact("shot:1"))
        XCTAssertThrowsError(try candidate(
            "c1",
            ordinal: 1,
            baseState: base,
            status: .failed,
            candidateState: try state("candidate:1"),
            materializationReceipt: nil,
            previewArtifacts: [screenshot],
            failureReason: "build failed"
        )) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .invalidCandidateShape)
        }
        XCTAssertNoThrow(try candidate(
            "c1",
            ordinal: 1,
            baseState: base,
            status: .failed,
            candidateState: nil,
            materializationReceipt: nil,
            failureReason: "build failed"
        ))
    }

    func testCandidateRejectsDuplicateArtifactAndEvidenceReferences() throws {
        let base = try state("accepted:1")
        let shot = ForgeGhostBuildArtifactReference(kind: .screenshot, id: try artifact("shot:1"))
        XCTAssertThrowsError(try candidate(
            "c1",
            ordinal: 1,
            baseState: base,
            status: .previewReady,
            candidateState: try state("candidate:1"),
            materializationReceipt: try receipt("mat:1"),
            previewArtifacts: [shot, shot]
        )) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .duplicateArtifactReference("shot:1"))
        }
        let evidence = try receipt("evidence:1")
        XCTAssertThrowsError(try candidate(
            "c1",
            ordinal: 1,
            baseState: base,
            status: .previewReady,
            candidateState: try state("candidate:1"),
            materializationReceipt: try receipt("mat:1"),
            evidenceReceiptIDs: [evidence, evidence]
        )) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .duplicateEvidenceReceipt("evidence:1"))
        }
    }

    func testSessionRejectsCrossProjectAndCrossBaseCandidates() throws {
        let project = try ForgeGhostBuildProjectID("project-a")
        let checkpoint = try ForgeGhostBuildCheckpointID("checkpoint-1")
        let base = try state("accepted:1")
        let wrongProjectCandidate = try readyCandidate(
            "c1",
            ordinal: 1,
            projectID: try ForgeGhostBuildProjectID("project-b"),
            checkpointID: checkpoint,
            baseState: base
        )
        XCTAssertThrowsError(try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [wrongProjectCandidate])) { error in
            XCTAssertEqual(
                error as? ForgeGhostBuildError,
                .projectMismatch(candidateID: "c1", expectedProjectID: "project-a", actualProjectID: "project-b")
            )
        }

        let wrongCheckpointCandidate = try readyCandidate(
            "c2",
            ordinal: 2,
            projectID: project,
            checkpointID: try ForgeGhostBuildCheckpointID("checkpoint-2"),
            baseState: base
        )
        XCTAssertThrowsError(try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [wrongCheckpointCandidate])) { error in
            XCTAssertEqual(
                error as? ForgeGhostBuildError,
                .sourceCheckpointMismatch(candidateID: "c2", expectedCheckpointID: "checkpoint-1", actualCheckpointID: "checkpoint-2")
            )
        }

        let wrongStateCandidate = try readyCandidate(
            "c3",
            ordinal: 3,
            projectID: project,
            checkpointID: checkpoint,
            baseState: try state("accepted:other")
        )
        XCTAssertThrowsError(try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [wrongStateCandidate])) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .sourceStateMismatch(candidateID: "c3"))
        }
    }

    func testSessionRejectsDuplicateCandidateIdentityAndOrdinal() throws {
        let project = try ForgeGhostBuildProjectID("project-a")
        let checkpoint = try ForgeGhostBuildCheckpointID("checkpoint-1")
        let base = try state("accepted:1")
        let first = try readyCandidate("c1", ordinal: 1, projectID: project, checkpointID: checkpoint, baseState: base)
        let sameID = try readyCandidate("c1", ordinal: 2, projectID: project, checkpointID: checkpoint, baseState: base)
        XCTAssertThrowsError(try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [first, sameID])) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .duplicateCandidateID("c1"))
        }
        let sameOrdinal = try readyCandidate("c2", ordinal: 1, projectID: project, checkpointID: checkpoint, baseState: base)
        XCTAssertThrowsError(try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [first, sameOrdinal])) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .duplicateOrdinal(1))
        }
    }

    func testPromotionIntentBindsAcceptedBaseCandidateStateAndReceipts() throws {
        let project = try ForgeGhostBuildProjectID("project-a")
        let checkpoint = try ForgeGhostBuildCheckpointID("checkpoint-1")
        let base = try state("accepted:1")
        let candidate = try readyCandidate(
            "c1",
            ordinal: 1,
            projectID: project,
            checkpointID: checkpoint,
            baseState: base,
            evidence: [try receipt("test:1")]
        )
        let session = try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [candidate])
        let intent = try session.promotionIntent(candidateID: candidate.id)

        XCTAssertEqual(intent.projectID, project)
        XCTAssertEqual(intent.sourceCheckpointID, checkpoint)
        XCTAssertEqual(intent.sourceProjectStateID, base)
        XCTAssertEqual(intent.candidateID, candidate.id)
        XCTAssertEqual(intent.candidateProjectStateID, candidate.candidateProjectStateID)
        XCTAssertEqual(intent.materializationReceiptID, candidate.materializationReceiptID)
        XCTAssertEqual(intent.evidenceReceiptIDs.map(\.rawValue), ["test:1"])
    }

    func testFailedCandidateCannotMintPreviewOrPromotionIntent() throws {
        let project = try ForgeGhostBuildProjectID("project-a")
        let checkpoint = try ForgeGhostBuildCheckpointID("checkpoint-1")
        let base = try state("accepted:1")
        let failed = try candidate(
            "c1",
            ordinal: 1,
            projectID: project,
            checkpointID: checkpoint,
            baseState: base,
            status: .failed,
            candidateState: nil,
            materializationReceipt: nil,
            failureReason: "compile failed"
        )
        let session = try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [failed])
        XCTAssertThrowsError(try session.previewIntent(candidateID: failed.id)) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .candidateNotReady("c1"))
        }
        XCTAssertThrowsError(try session.promotionIntent(candidateID: failed.id)) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .candidateNotReady("c1"))
        }
    }

    func testComparisonNeverFabricatesVisualPair() throws {
        let project = try ForgeGhostBuildProjectID("project-a")
        let checkpoint = try ForgeGhostBuildCheckpointID("checkpoint-1")
        let base = try state("accepted:1")
        let left = try readyCandidate(
            "left",
            ordinal: 1,
            projectID: project,
            checkpointID: checkpoint,
            baseState: base,
            screenshots: ["shot:left"]
        )
        let right = try readyCandidate(
            "right",
            ordinal: 2,
            projectID: project,
            checkpointID: checkpoint,
            baseState: base
        )
        let session = try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [right, left])
        let comparison = try session.comparison(from: left.id, to: right.id)
        XCTAssertFalse(comparison.hasVisualPair)
        XCTAssertEqual(comparison.leftScreenshots.map(\.id.rawValue), ["shot:left"])
        XCTAssertTrue(comparison.rightScreenshots.isEmpty)
        XCTAssertThrowsError(try session.comparison(from: left.id, to: left.id)) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .identicalComparisonEndpoints("left"))
        }
    }

    func testTryAnotherIdeaBindsSameAcceptedBaseAndAdvancesOrdinal() throws {
        let project = try ForgeGhostBuildProjectID("project-a")
        let checkpoint = try ForgeGhostBuildCheckpointID("checkpoint-1")
        let base = try state("accepted:1")
        let first = try readyCandidate("c1", ordinal: 2, projectID: project, checkpointID: checkpoint, baseState: base)
        let session = try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [first])
        let intent = try session.tryAnotherIdeaIntent()
        XCTAssertEqual(intent.projectID, project)
        XCTAssertEqual(intent.sourceCheckpointID, checkpoint)
        XCTAssertEqual(intent.sourceProjectStateID, base)
        XCTAssertEqual(intent.requestedOrdinal, 3)
    }

    func testTryAnotherIdeaFailsClosedOnOrdinalOverflow() throws {
        let project = try ForgeGhostBuildProjectID("project-a")
        let checkpoint = try ForgeGhostBuildCheckpointID("checkpoint-1")
        let base = try state("accepted:1")
        let final = try readyCandidate("c-max", ordinal: UInt32.max, projectID: project, checkpointID: checkpoint, baseState: base)
        let session = try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [final])
        XCTAssertThrowsError(try session.tryAnotherIdeaIntent()) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .ordinalOverflow)
        }
    }

    func testArchiveRoundTripIsDeterministicAndRejectsTamperedProjectBinding() throws {
        let project = try ForgeGhostBuildProjectID("project-a")
        let checkpoint = try ForgeGhostBuildCheckpointID("checkpoint-1")
        let base = try state("accepted:1")
        let candidate = try readyCandidate("c1", ordinal: 1, projectID: project, checkpointID: checkpoint, baseState: base)
        let value = try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [candidate])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let decoded = try JSONDecoder().decode(ForgeGhostBuildSession.self, from: data)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(try encoder.encode(decoded), data)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var candidates = try XCTUnwrap(root["candidates"] as? [[String: Any]])
        candidates[0]["projectID"] = "project-b"
        root["candidates"] = candidates
        XCTAssertThrowsError(try JSONDecoder().decode(
            ForgeGhostBuildSession.self,
            from: JSONSerialization.data(withJSONObject: root)
        )) { error in
            XCTAssertEqual(
                error as? ForgeGhostBuildError,
                .projectMismatch(candidateID: "c1", expectedProjectID: "project-a", actualProjectID: "project-b")
            )
        }
    }

    func testArchiveRejectsUnsupportedSchemaAndTamperedCandidateShape() throws {
        let project = try ForgeGhostBuildProjectID("project-a")
        let checkpoint = try ForgeGhostBuildCheckpointID("checkpoint-1")
        let base = try state("accepted:1")
        let candidate = try readyCandidate("c1", ordinal: 1, projectID: project, checkpointID: checkpoint, baseState: base)
        let value = try session(projectID: project, checkpointID: checkpoint, baseState: base, candidates: [candidate])
        let data = try JSONEncoder().encode(value)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["schemaVersion"] = 99
        XCTAssertThrowsError(try JSONDecoder().decode(
            ForgeGhostBuildSession.self,
            from: JSONSerialization.data(withJSONObject: root)
        ))

        root["schemaVersion"] = 1
        var candidates = try XCTUnwrap(root["candidates"] as? [[String: Any]])
        candidates[0].removeValue(forKey: "materializationReceiptID")
        root["candidates"] = candidates
        XCTAssertThrowsError(try JSONDecoder().decode(
            ForgeGhostBuildSession.self,
            from: JSONSerialization.data(withJSONObject: root)
        )) { error in
            XCTAssertEqual(error as? ForgeGhostBuildError, .invalidCandidateShape)
        }
    }

    private func session(
        projectID: ForgeGhostBuildProjectID,
        checkpointID: ForgeGhostBuildCheckpointID,
        baseState: ForgeGhostBuildProjectStateID,
        candidates: [ForgeGhostBuildCandidate]
    ) throws -> ForgeGhostBuildSession {
        try ForgeGhostBuildSession(
            id: ForgeGhostBuildSessionID("session-1"),
            projectID: projectID,
            sourceCheckpointID: checkpointID,
            sourceProjectStateID: baseState,
            createdAtMilliseconds: 1_900_000_000_000,
            candidates: candidates
        )
    }

    private func readyCandidate(
        _ id: String,
        ordinal: UInt32,
        projectID: ForgeGhostBuildProjectID,
        checkpointID: ForgeGhostBuildCheckpointID,
        baseState: ForgeGhostBuildProjectStateID,
        evidence: [ForgeGhostBuildReceiptID] = [],
        screenshots: [String] = []
    ) throws -> ForgeGhostBuildCandidate {
        try candidate(
            id,
            ordinal: ordinal,
            projectID: projectID,
            checkpointID: checkpointID,
            baseState: baseState,
            status: .previewReady,
            candidateState: try state("candidate:\(id)"),
            materializationReceipt: try receipt("materialized:\(id)"),
            previewArtifacts: try screenshots.map {
                ForgeGhostBuildArtifactReference(kind: .screenshot, id: try artifact($0))
            },
            evidenceReceiptIDs: evidence
        )
    }

    private func candidate(
        _ id: String,
        ordinal: UInt32,
        projectID: ForgeGhostBuildProjectID = try! ForgeGhostBuildProjectID("project-a"),
        checkpointID: ForgeGhostBuildCheckpointID = try! ForgeGhostBuildCheckpointID("checkpoint-1"),
        baseState: ForgeGhostBuildProjectStateID,
        status: ForgeGhostBuildCandidateStatus,
        candidateState: ForgeGhostBuildProjectStateID?,
        materializationReceipt: ForgeGhostBuildReceiptID?,
        previewArtifacts: [ForgeGhostBuildArtifactReference] = [],
        evidenceReceiptIDs: [ForgeGhostBuildReceiptID] = [],
        failureReason: String? = nil
    ) throws -> ForgeGhostBuildCandidate {
        try ForgeGhostBuildCandidate(
            id: ForgeGhostBuildCandidateID(id),
            projectID: projectID,
            sourceCheckpointID: checkpointID,
            sourceProjectStateID: baseState,
            ordinal: ordinal,
            title: "Alternative \(id)",
            status: status,
            candidateProjectStateID: candidateState,
            materializationReceiptID: materializationReceipt,
            previewArtifacts: previewArtifacts,
            evidenceReceiptIDs: evidenceReceiptIDs,
            failureReason: failureReason
        )
    }

    private func state(_ value: String) throws -> ForgeGhostBuildProjectStateID { try .init(value) }
    private func receipt(_ value: String) throws -> ForgeGhostBuildReceiptID { try .init(value) }
    private func artifact(_ value: String) throws -> ForgeGhostBuildArtifactID { try .init(value) }
}
