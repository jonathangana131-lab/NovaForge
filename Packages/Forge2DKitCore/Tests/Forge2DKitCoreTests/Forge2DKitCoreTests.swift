import Foundation
import Testing
@testable import Forge2DKitCore

@Test func fixedStepRunsDeterministically() throws {
    let policy = try Forge2DFixedStepPolicy(simulationHz: 60, maximumCatchUpSteps: 4, maximumFrameDelta: 0.25)
    var accumulator = Forge2DFixedStepAccumulator()
    let result = accumulator.advance(elapsed: 1.0 / 30.0, policy: policy, executionState: .running)
    #expect(result.simulationSteps == 2)
    #expect(abs(result.remainder) < 0.000_001)
    #expect(result.droppedTime == 0)
}

@Test func fixedStepDropsExcessCatchUpInsteadOfSpiraling() throws {
    let policy = try Forge2DFixedStepPolicy(simulationHz: 60, maximumCatchUpSteps: 2, maximumFrameDelta: 0.25)
    var accumulator = Forge2DFixedStepAccumulator()
    let result = accumulator.advance(elapsed: 0.2, policy: policy, executionState: .running)
    #expect(result.simulationSteps == 2)
    #expect(result.droppedTime > 0.15)
    #expect(result.remainder < policy.fixedDelta)
}

@Test func pausedLoopDoesNotConsumeTime() throws {
    let policy = try Forge2DFixedStepPolicy()
    var accumulator = Forge2DFixedStepAccumulator(remainder: 0.005)
    let result = accumulator.advance(elapsed: 0.1, policy: policy, executionState: .pausedByUser)
    #expect(result.simulationSteps == 0)
    #expect(result.remainder == 0.005)
}

@Test func invalidLoopConfigurationFailsClosed() {
    #expect(throws: Forge2DKitError.invalidLoopConfiguration) {
        _ = try Forge2DFixedStepPolicy(simulationHz: 0)
    }
}

@Test func baselineBudgetIsExplicitlyBounded() throws {
    let budget = Forge2DPerformanceBudget.iPhone12Baseline()
    let load = try Forge2DWorldLoad(entities: 513, dynamicBodies: 129, particles: 2001, audioVoices: 25, decodedTextureBytes: 100 * 1_024 * 1_024)
    #expect(load.violations(against: budget).count == 5)
}

@Test func worldLoadRejectsMoreBodiesThanEntities() {
    #expect(throws: Forge2DKitError.invalidWorldBudget) {
        _ = try Forge2DWorldLoad(entities: 1, dynamicBodies: 2, particles: 0, audioVoices: 0, decodedTextureBytes: 0)
    }
}

@Test func inputMapNormalizesAxes() throws {
    let move = Forge2DActionID(rawValue: "move-x")
    let binding = try Forge2DInputBinding(id: "left-stick-x", action: move, source: .controllerAxis(id: "gamepad.leftX", minimum: -0.5, maximum: 0.5))
    let map = try Forge2DInputMap(actions: [move], bindings: [binding])
    #expect(map.normalizedAxisValue(0, for: "left-stick-x") == 0)
    #expect(map.normalizedAxisValue(99, for: "left-stick-x") == 1)
    #expect(map.normalizedAxisValue(-99, for: "left-stick-x") == -1)
}

@Test func invalidAxisRangeFailsClosed() {
    #expect(throws: Forge2DKitError.invalidAxisRange) {
        _ = try Forge2DInputBinding(
            id: "axis",
            action: Forge2DActionID(rawValue: "move"),
            source: .touchAxis(id: "joystick", minimum: 1, maximum: 1)
        )
    }
}

@Test func duplicateActionsAreRejected() throws {
    let action = Forge2DActionID(rawValue: "jump")
    #expect(throws: Forge2DKitError.duplicateActionID("jump")) {
        _ = try Forge2DInputMap(actions: [action, action], bindings: [])
    }
}

@Test func duplicateBindingsAreRejected() throws {
    let action = Forge2DActionID(rawValue: "jump")
    let first = try Forge2DInputBinding(id: "jump-button", action: action, source: .touchButton(id: "touch.jump"))
    let second = try Forge2DInputBinding(id: "jump-button", action: action, source: .controllerButton(id: "gamepad.a"))
    #expect(throws: Forge2DKitError.duplicateBindingID("jump-button")) {
        _ = try Forge2DInputMap(actions: [action], bindings: [first, second])
    }
}

@Test func collisionRuleOrderingIsCanonical() throws {
    let player = try Forge2DCollisionLayer.singleBit(3)
    let world = try Forge2DCollisionLayer.singleBit(0)
    let rule = try Forge2DCollisionRule(first: player, second: world, shouldCollide: true)
    #expect(rule.first.rawValue == world.rawValue)
    #expect(rule.second.rawValue == player.rawValue)
}

@Test func collisionTableRejectsDuplicatePair() throws {
    let a = try Forge2DCollisionLayer.singleBit(0)
    let b = try Forge2DCollisionLayer.singleBit(1)
    let first = try Forge2DCollisionRule(first: a, second: b, shouldCollide: true)
    let second = try Forge2DCollisionRule(first: b, second: a, shouldCollide: false)
    #expect(throws: Forge2DKitError.duplicateCollisionRule) {
        _ = try Forge2DCollisionTable(rules: [first, second])
    }
}

@Test func collisionTableUsesExplicitDefault() throws {
    let a = try Forge2DCollisionLayer.singleBit(0)
    let b = try Forge2DCollisionLayer.singleBit(1)
    let table = try Forge2DCollisionTable(rules: [])
    #expect(table.shouldCollide(a, b) == false)
    #expect(table.shouldCollide(a, b, default: true) == true)
}

@Test func saveEnvelopeRoundTripsWithExactRevision() throws {
    let envelope = try Forge2DSaveEnvelope(projectID: "p1", slotID: "autosave", sourceRevision: "r7", payload: Data("hello".utf8))
    let data = try JSONEncoder().encode(envelope)
    let decoded = try Forge2DSaveEnvelope.decodeValidated(data, expectedProjectID: "p1", expectedSourceRevision: "r7")
    #expect(decoded == envelope)
}

@Test func staleSaveRevisionFailsClosed() throws {
    let envelope = try Forge2DSaveEnvelope(projectID: "p1", slotID: "autosave", sourceRevision: "r7", payload: Data())
    let data = try JSONEncoder().encode(envelope)
    #expect(throws: Forge2DKitError.invalidSaveEnvelope) {
        _ = try Forge2DSaveEnvelope.decodeValidated(data, expectedProjectID: "p1", expectedSourceRevision: "r8")
    }
}

@Test func oversizedSavePayloadIsRejected() {
    #expect(throws: Forge2DKitError.savePayloadTooLarge(maximumBytes: 4)) {
        _ = try Forge2DSaveEnvelope(projectID: "p1", slotID: "slot", sourceRevision: "r1", payload: Data(repeating: 1, count: 5), maximumPayloadBytes: 4)
    }
}

@Test func codableInputMapRoundTrips() throws {
    let fire = Forge2DActionID(rawValue: "fire")
    let binding = try Forge2DInputBinding(id: "fire", action: fire, source: .controllerButton(id: "gamepad.rightTrigger"))
    let original = try Forge2DInputMap(actions: [fire], bindings: [binding])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Forge2DInputMap.self, from: data)
    #expect(decoded == original)
}

@Test func decodedLoopPolicyRevalidatesInvariants() {
    let data = Data(#"{"simulationHz":0,"maximumCatchUpSteps":4,"maximumFrameDelta":0.25}"#.utf8)
    #expect(throws: Forge2DKitError.invalidLoopConfiguration) {
        _ = try JSONDecoder().decode(Forge2DFixedStepPolicy.self, from: data)
    }
}

@Test func decodedInputMapRejectsDuplicateActions() throws {
    let action = Forge2DActionID(rawValue: "jump")
    let valid = try Forge2DInputMap(actions: [action], bindings: [])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    object["actions"] = ["jump", "jump"]
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: Forge2DKitError.duplicateActionID("jump")) {
        _ = try JSONDecoder().decode(Forge2DInputMap.self, from: data)
    }
}

@Test func decodedCollisionTableRejectsDuplicatePairs() throws {
    let a = try Forge2DCollisionLayer.singleBit(0)
    let b = try Forge2DCollisionLayer.singleBit(1)
    let rule = try Forge2DCollisionRule(first: a, second: b, shouldCollide: true)
    let encodedRule = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
    let data = try JSONSerialization.data(withJSONObject: ["rules": [encodedRule, encodedRule]])
    #expect(throws: Forge2DKitError.duplicateCollisionRule) {
        _ = try JSONDecoder().decode(Forge2DCollisionTable.self, from: data)
    }
}

@Test func decodedSaveEnvelopeRejectsBlankSlot() throws {
    let envelope = try Forge2DSaveEnvelope(projectID: "p1", slotID: "slot", sourceRevision: "r1", payload: Data())
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
    object["slotID"] = "   "
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: Forge2DKitError.invalidSaveEnvelope) {
        _ = try JSONDecoder().decode(Forge2DSaveEnvelope.self, from: data)
    }
}
