import XCTest
@testable import VoltlineGame

@MainActor
final class VoltlineGameTests: XCTestCase {
    func testDriveModesRemainOrderedAndHardwareBacked() {
        XCTAssertLessThan(DriveMode.walk.speedLimitMetersPerSecond, DriveMode.eco.speedLimitMetersPerSecond)
        XCTAssertLessThan(DriveMode.eco.speedLimitMetersPerSecond, DriveMode.drive.speedLimitMetersPerSecond)
        XCTAssertLessThan(DriveMode.drive.speedLimitMetersPerSecond, DriveMode.sport.speedLimitMetersPerSecond)
        XCTAssertEqual(DriveMode.sport.speedLimitMetersPerSecond * 3.6, 35, accuracy: 0.0001)
    }

    func testSurfaceGripChangesMeaningfully() {
        XCTAssertGreaterThan(RideSurface.dryAsphalt.frictionCoefficient, RideSurface.wetAsphalt.frictionCoefficient)
        XCTAssertGreaterThan(RideSurface.wetAsphalt.frictionCoefficient, RideSurface.gravel.frictionCoefficient)
        XCTAssertGreaterThan(RideSurface.gravel.rollingMultiplier, RideSurface.dryAsphalt.rollingMultiplier)
    }

    func testMaxshotStartsOwnedAndSelected() {
        let session = GameSession(startLoop: false)
        XCTAssertEqual(session.selectedScooterID, ScooterCatalogItem.maxshot.id)
        XCTAssertTrue(session.ownedScooterIDs.contains(ScooterCatalogItem.maxshot.id))
        XCTAssertEqual(session.selectedScooter.hardware.controller.lowVoltageCutoffVolts, 31, accuracy: 0.001)
        XCTAssertEqual(session.selectedScooter.hardware.battery.capacityAmpHours, 10.5, accuracy: 0.001)
    }

    func testFixedStepRideConsumesChargeAndMoves() {
        let session = GameSession(startLoop: false)
        let initialSOC = session.simulationState.batteryStateOfCharge
        session.touchThrottle = 1
        session.stepForTesting(seconds: 15)

        XCTAssertGreaterThan(session.simulationState.speedMetersPerSecond, 0)
        XCTAssertGreaterThan(session.tripMeters, 0)
        XCTAssertLessThan(session.simulationState.batteryStateOfCharge, initialSOC)
        XCTAssertGreaterThan(session.pendingDriveEarnings, 0)
        XCTAssertTrue(session.simulationState.batteryVoltage.isFinite)
    }

    func testBrakeOverridesThrottle() {
        let session = GameSession(startLoop: false)
        session.touchThrottle = 1
        session.stepForTesting(seconds: 8)
        let beforeBrake = session.simulationState.speedMetersPerSecond
        XCTAssertGreaterThan(beforeBrake, 0.5)

        session.touchBrake = 1
        session.stepForTesting(seconds: 3)
        XCTAssertLessThan(session.simulationState.speedMetersPerSecond, beforeBrake)
        XCTAssertEqual(session.simulationState.motorCurrentAmps, 0, accuracy: 0.15)
    }

    func testVESCConfigurationIsClampedToSimulatedHardware() {
        let session = GameSession(startLoop: false)
        session.installedItemIDs.insert("vesc-75-100")
        session.vescConfiguration.batteryCurrentLimitAmps = 999
        session.vescConfiguration.motorCurrentLimitAmps = 999
        session.vescConfiguration.regenCurrentLimitAmps = 999
        session.applyVESCConfiguration()

        XCTAssertEqual(session.vescConfiguration.batteryCurrentLimitAmps, 35, accuracy: 0.001)
        XCTAssertEqual(session.vescConfiguration.motorCurrentLimitAmps, 100, accuracy: 0.001)
        XCTAssertEqual(session.vescConfiguration.regenCurrentLimitAmps, 25, accuracy: 0.001)
    }

    func testDeliveryUsesDistanceProgressInsteadOfTimer() {
        let item = StoreItem.catalog[0]
        let order = DeliveryOrder(
            id: UUID(),
            itemID: item.id,
            orderedAtOdometerMeters: 1_000,
            requiredDistanceMeters: 5_000,
            delivered: false
        )

        XCTAssertEqual(order.progress(currentOdometerMeters: 1_000), 0, accuracy: 0.001)
        XCTAssertEqual(order.progress(currentOdometerMeters: 3_500), 0.5, accuracy: 0.001)
        XCTAssertEqual(order.progress(currentOdometerMeters: 6_000), 1, accuracy: 0.001)
        XCTAssertEqual(order.progress(currentOdometerMeters: 999_000), 1, accuracy: 0.001)
    }

    func testBatteryBarStatesAreDiscrete() {
        let session = GameSession(startLoop: false)
        XCTAssertEqual(session.batteryBars, 5)
        XCTAssertTrue((1...5).contains(session.batteryBars))
    }
}
