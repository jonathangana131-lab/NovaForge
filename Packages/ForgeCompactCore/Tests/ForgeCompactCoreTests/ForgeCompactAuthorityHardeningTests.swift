import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactAuthorityHardeningTests: XCTestCase {
    func testAuthorityRejectsWhitespaceAliasInsteadOfNormalizing() {
        XCTAssertThrowsError(
            try ProjectCapsuleAuthority(
                projectID: " project-1 ",
                missionID: "mission-1",
                sourceRevision: "source-r1",
                missionRevision: 1,
                authorityEpoch: 1,
                capsuleRevision: 1
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidIdentifier(field: "projectID"))
        }
    }

    func testDecodedAuthorityRejectsWhitespaceSourceRevisionAlias() throws {
        let authority = try ProjectCapsuleAuthority(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-r1",
            missionRevision: 1,
            authorityEpoch: 1,
            capsuleRevision: 1
        )
        let data = try JSONEncoder().encode(authority)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sourceRevision"] = " source-r1 "
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ProjectCapsuleAuthority.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidIdentifier(field: "sourceRevision"))
        }
    }

    func testProvenanceRejectsControlCharacterIdentity() {
        XCTAssertThrowsError(
            try ForgeCompactProvenance(kind: .runtime, reference: "receipt\u{0000}forged")
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .invalidIdentifier(field: "provenance.reference")
            )
        }
    }
}
