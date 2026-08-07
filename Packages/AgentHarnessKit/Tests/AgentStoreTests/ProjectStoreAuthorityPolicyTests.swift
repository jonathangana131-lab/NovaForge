import XCTest
@testable import AgentStore

final class ProjectStoreAuthorityPolicyTests: XCTestCase {
    func testReadablePrimaryWithoutActiveCompatibilityServesPrimary() {
        XCTAssertEqual(
            decide(primary: .readable, active: false, compatibilityExists: false),
            .servePrimary
        )
    }

    func testUnreadablePrimaryWithoutActiveCompatibilityEstablishesFallback() {
        XCTAssertEqual(
            decide(primary: .unreadable, active: false, compatibilityExists: false),
            .establishCompatibility
        )
    }

    func testActiveExistingCompatibilityWinsEvenWhenPrimaryIsReadable() {
        XCTAssertEqual(
            decide(primary: .readable, active: true, compatibilityExists: true),
            .resumeCompatibility
        )
    }

    func testActiveExistingCompatibilityResumesWhenPrimaryIsUnreadable() {
        XCTAssertEqual(
            decide(primary: .unreadable, active: true, compatibilityExists: true),
            .resumeCompatibility
        )
    }

    func testReadablePrimaryCanClearStaleActiveMarkerWhenFallbackIsMissing() {
        XCTAssertEqual(
            decide(primary: .readable, active: true, compatibilityExists: false),
            .clearStaleCompatibilityGuardAndServePrimary
        )
    }

    func testUnreadablePrimaryFailsClosedWhenActiveFallbackIsMissing() {
        XCTAssertEqual(
            decide(primary: .unreadable, active: true, compatibilityExists: false),
            .failClosedMissingActiveCompatibility
        )
    }

    func testInactiveOrphanCompatibilityDoesNotOverrideReadablePrimary() {
        XCTAssertEqual(
            decide(primary: .readable, active: false, compatibilityExists: true),
            .servePrimary
        )
    }

    func testInactiveOrphanCompatibilityDoesNotBlockEstablishingFallbackForUnreadablePrimary() {
        XCTAssertEqual(
            decide(primary: .unreadable, active: false, compatibilityExists: true),
            .establishCompatibility
        )
    }

    private func decide(
        primary: ProjectStorePrimaryAvailability,
        active: Bool,
        compatibilityExists: Bool
    ) -> ProjectStoreAuthorityDecision {
        ProjectStoreAuthorityPolicy.decide(
            ProjectStoreAuthorityProbe(
                primary: primary,
                compatibilityWasActive: active,
                compatibilityStoreExists: compatibilityExists
            )
        )
    }
}
