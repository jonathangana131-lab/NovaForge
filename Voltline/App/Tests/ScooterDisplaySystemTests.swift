import XCTest
@testable import VoltlineGame

final class ScooterDisplaySystemTests: XCTestCase {
    func testMaxshotStartsWithFiveBarsAtFullVoltage() {
        var computer = ScooterDisplayComputer()
        let frame = computer.update(
            telemetry: telemetry(voltage: 41.5),
            profile: .maxshot36V,
            deltaTime: 0.016,
            ambientLuminance: 0.2,
            absoluteTime: 2
        )

        XCTAssertEqual(frame.batterySegments, 5)
        XCTAssertGreaterThan(frame.brightness, 0.7)
    }

    func testBatteryBarDoesNotDropFromBriefVoltageSag() {
        var computer = ScooterDisplayComputer()
        _ = computer.update(
            telemetry: telemetry(voltage: 40.5),
            profile: .maxshot36V,
            deltaTime: 0.016,
            ambientLuminance: 0.2,
            absoluteTime: 2
        )

        for step in 0..<60 {
            _ = computer.update(
                telemetry: telemetry(voltage: 35.0),
                profile: .maxshot36V,
                deltaTime: 1.0 / 60.0,
                ambientLuminance: 0.2,
                absoluteTime: 2 + Double(step) / 60.0
            )
        }

        XCTAssertEqual(computer.displayedSegments, 5)
    }

    func testBatteryBarDropsOnlyAfterFilteredVoltageAndDelay() {
        var computer = ScooterDisplayComputer()
        _ = computer.update(
            telemetry: telemetry(voltage: 40.5),
            profile: .maxshot36V,
            deltaTime: 0.016,
            ambientLuminance: 0.2,
            absoluteTime: 2
        )

        for step in 0..<600 {
            _ = computer.update(
                telemetry: telemetry(voltage: 35.0),
                profile: .maxshot36V,
                deltaTime: 1.0 / 60.0,
                ambientLuminance: 0.2,
                absoluteTime: 2 + Double(step) / 60.0
            )
        }

        XCTAssertLessThanOrEqual(computer.displayedSegments, 2)
    }

    func testBatteryBarRecoveryRequiresHigherVoltageAndLongerDelay() {
        var computer = ScooterDisplayComputer()

        for step in 0..<720 {
            _ = computer.update(
                telemetry: telemetry(voltage: 34.0),
                profile: .maxshot36V,
                deltaTime: 1.0 / 60.0,
                ambientLuminance: 0.2,
                absoluteTime: Double(step) / 60.0
            )
        }
        let lowSegments = computer.displayedSegments

        for step in 0..<120 {
            _ = computer.update(
                telemetry: telemetry(voltage: 38.2),
                profile: .maxshot36V,
                deltaTime: 1.0 / 60.0,
                ambientLuminance: 0.2,
                absoluteTime: 12 + Double(step) / 60.0
            )
        }

        XCTAssertEqual(computer.displayedSegments, lowSegments)
    }

    func testCriticalBarBlinks() {
        var computer = ScooterDisplayComputer()
        var hiddenSeen = false
        var visibleSeen = false

        for step in 0..<900 {
            let frame = computer.update(
                telemetry: telemetry(voltage: 32.5),
                profile: .maxshot36V,
                deltaTime: 1.0 / 60.0,
                ambientLuminance: 0.05,
                absoluteTime: Double(step) / 60.0
            )
            if frame.batterySegments == 1 {
                hiddenSeen = hiddenSeen || !frame.criticalBarVisible
                visibleSeen = visibleSeen || frame.criticalBarVisible
            }
        }

        XCTAssertTrue(hiddenSeen)
        XCTAssertTrue(visibleSeen)
    }

    func testBootSequenceReachesReady() {
        var computer = ScooterDisplayComputer()
        var finalFrame: ScooterDisplayFrame?

        for step in 0..<120 {
            finalFrame = computer.update(
                telemetry: telemetry(voltage: 40.0),
                profile: .maxshot36V,
                deltaTime: 1.0 / 60.0,
                ambientLuminance: 0.5,
                absoluteTime: Double(step) / 60.0
            )
        }

        XCTAssertEqual(finalFrame?.bootPhase, .ready)
    }

    func testPowerOffClearsDisplay() {
        var value = telemetry(voltage: 40.0)
        value.isPoweredOn = false
        var computer = ScooterDisplayComputer()

        let frame = computer.update(
            telemetry: value,
            profile: .maxshot36V,
            deltaTime: 0.016,
            ambientLuminance: 0.5,
            absoluteTime: 1
        )

        XCTAssertEqual(frame.bootPhase, .off)
        XCTAssertEqual(frame.batterySegments, 0)
        XCTAssertEqual(frame.brightness, 0)
    }

    private func telemetry(voltage: Double) -> ScooterDisplayTelemetry {
        var value = ScooterDisplayTelemetry.preview
        value.packVoltage = voltage
        value.isPoweredOn = true
        return value
    }
}
