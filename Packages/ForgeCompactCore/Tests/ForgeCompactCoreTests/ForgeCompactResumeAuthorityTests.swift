import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactResumeAuthorityTests: XCTestCase {
    func testResumeAuthorityRequiresOpaqueCanonicalReceipts() throws {
        let capsule = try makeCapsule()

        XCTAssertThrowsError(
            try ForgeCompactResumeAuthority(
                capsule: capsule,
                currentStageID: "verify",
                projectBrainRevisionID: "brain-r7",
                acceptedCheckpointReceiptID: "receipt-checkpoint-4",
                missionPolicyReceiptID: "",
                modelPolicyReceiptID: "receipt-model-policy-2"
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactResumeError,
                .invalidIdentifier(field: "resume.missionPolicyReceiptID")
            )
        }
    }

    func testResumeAuthorityDecodeRevalidatesCurrentStage() throws {
        let authority = try makeAuthority()
        let encoded = try JSONEncoder().encode(authority)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["currentStageID"] = " "
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(ForgeCompactResumeAuthority.self, from: corrupted)
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactResumeError,
                .invalidIdentifier(field: "resume.currentStageID")
            )
        }
    }

    func testResumeAuthorityRejectsBlankDesignDNARevisionWhenPresent() throws {
        XCTAssertThrowsError(
            try makeAuthority(designDNARevisionID: " ")
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactResumeError,
                .invalidIdentifier(field: "resume.designDNARevisionID")
            )
        }
    }

    func testResumeGateAcceptsOnlyExactProjectMissionSourceAndMissionRevision() throws {
        let authority = try makeAuthority(designDNARevisionID: "design-r3")
        let exact = try ForgeCompactResumeTarget(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-9",
            missionRevision: 4
        )
        XCTAssertTrue(ForgeCompactResumeGate.canResume(authority: authority, target: exact))

        let staleSource = try ForgeCompactResumeTarget(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-8",
            missionRevision: 4
        )
        XCTAssertFalse(
            ForgeCompactResumeGate.canResume(authority: authority, target: staleSource)
        )

        let staleMissionRevision = try ForgeCompactResumeTarget(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-9",
            missionRevision: 3
        )
        XCTAssertFalse(
            ForgeCompactResumeGate.canResume(
                authority: authority,
                target: staleMissionRevision
            )
        )

        let wrongMission = try ForgeCompactResumeTarget(
            projectID: "project-1",
            missionID: "mission-2",
            sourceRevision: "source-9",
            missionRevision: 4
        )
        XCTAssertFalse(
            ForgeCompactResumeGate.canResume(authority: authority, target: wrongMission)
        )

        let wrongProject = try ForgeCompactResumeTarget(
            projectID: "project-2",
            missionID: "mission-1",
            sourceRevision: "source-9",
            missionRevision: 4
        )
        XCTAssertFalse(
            ForgeCompactResumeGate.canResume(authority: authority, target: wrongProject)
        )
    }

    func testResumeAuthoritySchemaFailsClosedOnDecode() throws {
        let authority = try makeAuthority()
        let encoded = try JSONEncoder().encode(authority)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = 7
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(ForgeCompactResumeAuthority.self, from: corrupted)
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactResumeError,
                .unsupportedSchema(7)
            )
        }
    }

    private func makeAuthority(
        designDNARevisionID: String? = nil
    ) throws -> ForgeCompactResumeAuthority {
        try ForgeCompactResumeAuthority(
            capsule: makeCapsule(),
            currentStageID: "verify",
            projectBrainRevisionID: "brain-r7",
            acceptedCheckpointReceiptID: "receipt-checkpoint-4",
            missionPolicyReceiptID: "receipt-mission-policy-6",
            modelPolicyReceiptID: "receipt-model-policy-2",
            designDNARevisionID: designDNARevisionID
        )
    }

    private func makeCapsule() throws -> ForgeProjectCapsule {
        try ForgeProjectCapsule(
            projectID: "project-1",
            missionID: "mission-1",
            checkpointID: "checkpoint-4",
            sourceRevision: "source-9",
            missionRevision: 4,
            acceptedDecisionIDs: ["decision-a"],
            unresolvedDecisionIDs: ["decision-b"],
            evidenceReceiptIDs: ["receipt-checkpoint-4"],
            knownDefectIDs: ["defect-low-1"],
            estimatedTokens: 360
        )
    }
}
