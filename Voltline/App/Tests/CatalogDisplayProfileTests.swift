import XCTest
@testable import VoltlineGame

final class CatalogDisplayProfileTests: XCTestCase {
    func testCatalogResolvesUniqueDisplayFamilies() {
        XCTAssertEqual(
            CatalogDisplayProfileResolver.identity(for: ScooterCatalogItem.maxshot.id).family,
            .maxshotLED
        )
        XCTAssertEqual(
            CatalogDisplayProfileResolver.identity(for: ScooterCatalogItem.kukirin.id).family,
            .kukirinMonochromeLCD
        )
        XCTAssertEqual(
            CatalogDisplayProfileResolver.identity(for: ScooterCatalogItem.dualtron.id).family,
            .dualtronEY4
        )
    }

    func testKukirinBriefSagDoesNotDropBatteryLevel() {
        var computer = ScooterDisplayComputer()
        var telemetry = ScooterDisplayTelemetry.preview
        telemetry.packVoltage = 57.8
        telemetry.stateOfCharge = 0.95

        for step in 0..<30 {
            _ = computer.update(
                telemetry: telemetry,
                profile: .kukirin52V,
                deltaTime: 0.1,
                ambientLuminance: 0.1,
                absoluteTime: Double(step) * 0.1
            )
        }
        XCTAssertEqual(computer.displayedSegments, 5)

        telemetry.packVoltage = 48.0
        for step in 30..<38 {
            _ = computer.update(
                telemetry: telemetry,
                profile: .kukirin52V,
                deltaTime: 0.1,
                ambientLuminance: 0.1,
                absoluteTime: Double(step) * 0.1
            )
        }
        XCTAssertEqual(computer.displayedSegments, 5)
    }

    func testKukirinSustainedLowVoltageDropsBars() {
        var computer = ScooterDisplayComputer()
        var telemetry = ScooterDisplayTelemetry.preview
        telemetry.packVoltage = 57.8

        for step in 0..<25 {
            _ = computer.update(
                telemetry: telemetry,
                profile: .kukirin52V,
                deltaTime: 0.1,
                ambientLuminance: 0.1,
                absoluteTime: Double(step) * 0.1
            )
        }

        telemetry.packVoltage = 47.0
        for step in 25..<95 {
            _ = computer.update(
                telemetry: telemetry,
                profile: .kukirin52V,
                deltaTime: 0.1,
                ambientLuminance: 0.1,
                absoluteTime: Double(step) * 0.1
            )
        }

        XCTAssertLessThanOrEqual(computer.displayedSegments, 2)
    }

    func testDualtronCriticalVoltageBlinksBottomStrip() {
        var computer = ScooterDisplayComputer()
        var telemetry = ScooterDisplayTelemetry.preview
        telemetry.packVoltage = 63.0

        var sawVisible = false
        var sawHidden = false
        for step in 0..<80 {
            let frame = computer.update(
                telemetry: telemetry,
                profile: .dualtron72V,
                deltaTime: 0.1,
                ambientLuminance: 0.05,
                absoluteTime: Double(step) * 0.1
            )
            sawVisible = sawVisible || frame.criticalBarVisible
            sawHidden = sawHidden || !frame.criticalBarVisible
        }

        XCTAssertTrue(sawVisible)
        XCTAssertTrue(sawHidden)
    }

    func testThunderProfileRetainsSixtyVoltCutoffContext() {
        XCTAssertEqual(BatterySegmentProfile.dualtron72V.cutoffVoltage, 60.0, accuracy: 0.001)
        XCTAssertEqual(BatterySegmentProfile.dualtron72V.thresholds.count, 5)
        XCTAssertEqual(BatterySegmentProfile.kukirin52V.cutoffVoltage, 42.0, accuracy: 0.001)
    }
}
