import Foundation
import Testing
@testable import Forge2DKit

@Test func actionIDsFailClosed() throws {
    #expect(throws: Forge2DContractError.invalidActionID) { try Forge2DActionID("") }
    #expect(throws: Forge2DContractError.invalidActionID) { try Forge2DActionID(" drive") }
    #expect(throws: Forge2DContractError.invalidActionID) { try Forge2DActionID("drive\n") }
    #expect(try Forge2DActionID("vehicle.throttle").rawValue == "vehicle.throttle")
}

@Test func actionIDDecodeRejectsInvalidPersistedValue() throws {
    let data = Data("\" bad\"".utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Forge2DActionID.self, from: data) }
}

@Test func fixedStepClockAccumulatesSubstepsDeterministically() throws {
    var clock = Forge2DFixedStepClock(configuration: try Forge2DLoopConfiguration(simulationHz: 60, maxCatchUpSteps: 4))
    let first = clock.advance(frameDuration: 1.0 / 120.0)
    #expect(first.stepCount == 0)
    #expect(abs(first.interpolationAlpha - 0.5) < 0.000_001)

    let second = clock.advance(frameDuration: 1.0 / 120.0)
    #expect(second.stepCount == 1)
    #expect(second.interpolationAlpha < 0.000_001)
}

@Test func fixedStepClockCapsForegroundRecovery() throws {
    let configuration = try Forge2DLoopConfiguration(simulationHz: 60, maxCatchUpSteps: 4)
    var clock = Forge2DFixedStepClock(configuration: configuration)
    let plan = clock.advance(frameDuration: 5)
    #expect(plan.stepCount == 4)
    #expect(plan.discardedFrameDuration > 4.9)
    #expect(plan.interpolationAlpha >= 0 && plan.interpolationAlpha < 1)
}

@Test func fixedStepClockTreatsInvalidDurationsAsNoWork() throws {
    var clock = Forge2DFixedStepClock(configuration: try Forge2DLoopConfiguration())
    #expect(clock.advance(frameDuration: -.infinity).stepCount == 0)
    #expect(clock.advance(frameDuration: .nan).stepCount == 0)
    #expect(clock.advance(frameDuration: -1).stepCount == 0)
}

@Test func loopConfigurationRejectsRunawayValues() {
    #expect(throws: Forge2DContractError.invalidLoopConfiguration) { try Forge2DLoopConfiguration(simulationHz: 0) }
    #expect(throws: Forge2DContractError.invalidLoopConfiguration) { try Forge2DLoopConfiguration(maxCatchUpSteps: 17) }
}

@Test func touchStickDeadZoneAndClampAreStable() throws {
    let stick = try Forge2DTouchStick(center: .zero, radius: 100, deadZoneFraction: 0.2)
    #expect(stick.sample(touchPoint: Forge2DVector(x: 10, y: 0)) == .zero)

    let halfway = stick.sample(touchPoint: Forge2DVector(x: 60, y: 0))
    #expect(abs(halfway.x - 0.5) < 0.000_001)
    #expect(abs(halfway.y) < 0.000_001)

    let clamped = stick.sample(touchPoint: Forge2DVector(x: 500, y: 0))
    #expect(abs(clamped.x - 1) < 0.000_001)
}

@Test func inputSnapshotClampsAndPauseNeutralizes() throws {
    let throttle = try Forge2DActionID("throttle")
    let snapshot = Forge2DInputSnapshot(source: .touch, values: [throttle: 4])
    #expect(snapshot.value(for: throttle) == 1)
    #expect(snapshot.forSimulation(isPaused: true).value(for: throttle) == 0)
}

@Test func inputCombinerUsesMagnitudeAndNeutralizesExactConflict() throws {
    let steer = try Forge2DActionID("steer")
    let positive = Forge2DInputSnapshot(source: .touch, values: [steer: 0.7])
    let negative = Forge2DInputSnapshot(source: .controller, values: [steer: -0.7])
    let duplicatePositive = Forge2DInputSnapshot(source: .keyboard, values: [steer: 0.7])
    #expect(Forge2DInputCombiner.combine([positive, negative]).value(for: steer) == 0)
    #expect(Forge2DInputCombiner.combine([positive, negative, duplicatePositive]).value(for: steer) == 0)
    #expect(Forge2DInputCombiner.combine([negative, duplicatePositive, positive]).value(for: steer) == 0)

    let stronger = Forge2DInputSnapshot(source: .controller, values: [steer: -0.9])
    #expect(Forge2DInputCombiner.combine([positive, stronger]).value(for: steer) == -0.9)
}

@Test func controllerMapScalesAndClampsSemanticActions() throws {
    let steer = try Forge2DActionID("steer")
    let throttle = try Forge2DActionID("throttle")
    let map = Forge2DControllerMap(bindings: [
        try Forge2DControllerBinding(element: .leftStickX, action: steer, scale: -1),
        try Forge2DControllerBinding(element: .rightTrigger, action: throttle, scale: 2),
    ])
    let snapshot = map.snapshot(elements: [.leftStickX: 0.25, .rightTrigger: 0.8])
    #expect(snapshot.value(for: steer) == -0.25)
    #expect(snapshot.value(for: throttle) == 1)
}

@Test func invalidControllerScaleFailsClosed() throws {
    let action = try Forge2DActionID("jump")
    #expect(throws: Forge2DContractError.invalidControllerBinding) {
        try Forge2DControllerBinding(element: .buttonSouth, action: action, scale: 0)
    }
}

@Test func collisionReturnsMinimumAxisSeparation() {
    let moving = Forge2DRect(center: Forge2DVector(x: 0, y: 0), size: Forge2DVector(x: 10, y: 10))
    let obstacle = Forge2DRect(center: Forge2DVector(x: 8, y: 0), size: Forge2DVector(x: 10, y: 10))
    let contact = Forge2DCollision.contact(moving: moving, obstacle: obstacle)
    #expect(contact?.normal == Forge2DVector(x: -1, y: 0))
    #expect(contact?.penetration == 2)
    #expect(contact?.separation == Forge2DVector(x: -2, y: 0))
}

@Test func collisionDoesNotTreatEdgeTouchAsPenetration() {
    let moving = Forge2DRect(center: Forge2DVector(x: 0, y: 0), size: Forge2DVector(x: 10, y: 10))
    let obstacle = Forge2DRect(center: Forge2DVector(x: 10, y: 0), size: Forge2DVector(x: 10, y: 10))
    #expect(Forge2DCollision.contact(moving: moving, obstacle: obstacle) == nil)
}

@Test func cameraDeadZoneAvoidsUnnecessaryMotion() throws {
    let policy = try Forge2DCameraPolicy(
        viewportSize: Forge2DVector(x: 100, y: 100),
        deadZoneSize: Forge2DVector(x: 20, y: 20)
    )
    #expect(policy.follow(currentCenter: .zero, target: Forge2DVector(x: 9, y: -9)) == .zero)
    #expect(policy.follow(currentCenter: .zero, target: Forge2DVector(x: 30, y: 0)) == Forge2DVector(x: 20, y: 0))
}

@Test func cameraClampsToWorldBounds() throws {
    let policy = try Forge2DCameraPolicy(
        viewportSize: Forge2DVector(x: 100, y: 100),
        deadZoneSize: .zero,
        worldBounds: Forge2DRect(min: .zero, max: Forge2DVector(x: 500, y: 500))
    )
    #expect(policy.follow(currentCenter: Forge2DVector(x: 250, y: 250), target: Forge2DVector(x: 490, y: 490)) == Forge2DVector(x: 450, y: 450))
}

@Test func cameraCentersWhenWorldIsSmallerThanViewport() throws {
    let world = Forge2DRect(min: Forge2DVector(x: 10, y: 20), max: Forge2DVector(x: 50, y: 60))
    let policy = try Forge2DCameraPolicy(
        viewportSize: Forge2DVector(x: 100, y: 100),
        deadZoneSize: .zero,
        worldBounds: world
    )
    #expect(policy.follow(currentCenter: .zero, target: Forge2DVector(x: 500, y: 500)) == world.center)
}

@Test func performanceBudgetReportsOnlyExceededDimensions() throws {
    let budget = try Forge2DPerformanceBudget(targetFramesPerSecond: 60, maxVisibleSprites: 10, maxPhysicsBodies: 5, maxParticles: 100)
    let violations = budget.evaluate(Forge2DPerformanceSample(measuredFramesPerSecond: 57.5, visibleSprites: 11, physicsBodies: 5, particles: 101))
    #expect(violations == [
        .frameRate(actual: 57.5, target: 60),
        .visibleSprites(actual: 11, limit: 10),
        .particles(actual: 101, limit: 100),
    ])
}

@Test func performanceBudgetDoesNotInventFrameRateEvidence() throws {
    let budget = try Forge2DPerformanceBudget(targetFramesPerSecond: 60, maxVisibleSprites: 10)
    let violations = budget.evaluate(Forge2DPerformanceSample(measuredFramesPerSecond: .nan, visibleSprites: 0, physicsBodies: 0, particles: 0))
    #expect(violations.isEmpty)
}

@Test func performanceBudgetRejectsUnsupportedTargetFrameRate() {
    #expect(throws: Forge2DContractError.invalidPerformanceBudget) {
        try Forge2DPerformanceBudget(targetFramesPerSecond: 240)
    }
}

@Test func saveEnvelopeRoundTripsAndRejectsWrongVersion() throws {
    let envelope = try Forge2DSaveEnvelope(projectID: "project-1", slot: "autosave", payload: Data([1, 2, 3]))
    let data = try JSONEncoder().encode(envelope)
    #expect(try JSONDecoder().decode(Forge2DSaveEnvelope.self, from: data) == envelope)

    #expect(throws: Forge2DContractError.invalidSaveEnvelope) {
        try Forge2DSaveEnvelope(projectID: "project-1", slot: "autosave", payload: Data(), formatVersion: 2)
    }
}

@Test func saveEnvelopeRejectsUnboundedPayload() {
    #expect(throws: Forge2DContractError.invalidSaveEnvelope) {
        try Forge2DSaveEnvelope(projectID: "project-1", slot: "autosave", payload: Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1))
    }
}

@Test func persistedValidatedContractsFailClosedOnDecode() throws {
    let decoder = JSONDecoder()

    #expect(throws: DecodingError.self) {
        try decoder.decode(Forge2DLoopConfiguration.self, from: Data(#"{"simulationHz":0,"maxCatchUpSteps":4}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(Forge2DTouchStick.self, from: Data(#"{"center":{"x":0,"y":0},"radius":0,"deadZoneFraction":0.12}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(Forge2DControllerBinding.self, from: Data(#"{"element":"leftStickX","action":"steer","scale":0}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(Forge2DCameraPolicy.self, from: Data(#"{"viewportSize":{"x":100,"y":100},"deadZoneSize":{"x":101,"y":20}}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(Forge2DPerformanceBudget.self, from: Data(#"{"targetFramesPerSecond":240,"maxVisibleSprites":1,"maxPhysicsBodies":1,"maxParticles":1}"#.utf8))
    }
}
