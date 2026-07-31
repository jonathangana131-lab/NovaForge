import XCTest
@testable import VoltlineGame

final class ScooterModelRegistryTests: XCTestCase {
    func testRegistryIDsAreUnique() {
        let ids = ScooterModelRegistry.records.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testCurrentPlayableScootersResolveToConcreteDashboardTechnology() {
        let playableIDs = ScooterCatalogItem.all.map(\.id)
        for id in playableIDs {
            let record = ScooterModelRegistry.record(id: id)
            XCTAssertNotNil(record, "Missing registry record for \(id)")
            XCTAssertNotEqual(record?.dashboardTechnology, .referenceRequired)
        }
    }

    func testVerifiedRecordsContainEvidenceFeatures() {
        for record in ScooterModelRegistry.records where record.verification == .verified {
            XCTAssertFalse(record.sourceBackedFeatures.isEmpty, "Verified record lacks evidence: \(record.id)")
            XCTAssertFalse(record.referenceNotes.isEmpty)
        }
    }

    func testBlockedRecordsCannotShipRenderer() {
        XCTAssertFalse(ScooterModelRegistry.blockedRecords.isEmpty)
        for record in ScooterModelRegistry.blockedRecords {
            XCTAssertFalse(record.canShipAuthenticRenderer)
        }
    }

    func testG2MaxDashboardRevisionsRemainDistinct() {
        let revisions = ["kukirin-g2-max-b", "kukirin-g2-max-c", "kukirin-g2-max-d"]
            .compactMap(ScooterModelRegistry.record(id:))
        XCTAssertEqual(revisions.count, 3)
        XCTAssertEqual(Set(revisions.compactMap(\.revision)).count, 3)
    }

    func testDualtronEY3AndEY4AreNotCollapsed() {
        let ey3 = ScooterModelRegistry.record(id: "dualtron-ey3-legacy-family")
        let ey4 = ScooterModelRegistry.record(id: "dualtron-ey4-current-family")
        XCTAssertEqual(ey3?.dashboardTechnology, .dualtronEY3)
        XCTAssertEqual(ey4?.dashboardTechnology, .dualtronEY4)
        XCTAssertNotEqual(ey3?.dashboardTechnology, ey4?.dashboardTechnology)
    }
}
