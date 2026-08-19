import Foundation
import XCTest
@testable import ForgeCompletionCore

final class ForgeCompletionRevisionInvariantTests: XCTestCase {
    func testTargetRejectsZeroConstitutionRevision() throws {
        XCTAssertThrowsError(
            try ForgeCompletionTarget(
                missionID: "mission-1",
                projectID: "project-1",
                sourceRevision: "source-1",
                constitutionRevision: 0,
                constitutionReceiptID: "constitution-receipt-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompletionError,
                .invalidRevision("target.constitutionRevision")
            )
        }
    }

    func testTargetDecodeRejectsPersistedZeroConstitutionRevision() throws {
        let data = try XCTUnwrap(
            """
            {
              "missionID": "mission-1",
              "projectID": "project-1",
              "sourceRevision": "source-1",
              "constitutionRevision": 0,
              "constitutionReceiptID": "constitution-receipt-1"
            }
            """.data(using: .utf8)
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ForgeCompletionTarget.self, from: data)
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompletionError,
                .invalidRevision("target.constitutionRevision")
            )
        }
    }

    func testTargetAcceptsAndRoundTripsFirstCanonicalRevision() throws {
        let target = try ForgeCompletionTarget(
            missionID: "mission-1",
            projectID: "project-1",
            sourceRevision: "source-1",
            constitutionRevision: 1,
            constitutionReceiptID: "constitution-receipt-1"
        )

        let decoded = try JSONDecoder().decode(
            ForgeCompletionTarget.self,
            from: JSONEncoder().encode(target)
        )
        XCTAssertEqual(decoded, target)
        XCTAssertEqual(decoded.constitutionRevision, 1)
    }
}
