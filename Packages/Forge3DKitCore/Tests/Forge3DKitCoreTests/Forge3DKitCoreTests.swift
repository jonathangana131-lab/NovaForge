import Foundation
import Testing
@testable import Forge3DKitCore

private func transform() throws -> Forge3DTransform {
    try Forge3DTransform(
        position: Forge3DVector3(x: 0, y: 0, z: 0),
        rotationRadians: Forge3DVector3(x: 0, y: 0, z: 0),
        scale: Forge3DVector3(x: 1, y: 1, z: 1)
    )
}

@Test func rejectsNonFiniteVector() {
    #expect(throws: Forge3DValidationError.nonFiniteValue) {
        _ = try Forge3DVector3(x: .infinity, y: 0, z: 0)
    }
}

@Test func rejectsNonPositiveScale() throws {
    let zero = try Forge3DVector3(x: 0, y: 1, z: 1)
    #expect(throws: Forge3DValidationError.invalidRange) {
        _ = try Forge3DTransform(position: zero, rotationRadians: zero, scale: zero)
    }
}

@Test func budgetFailsClosed() throws {
    let load = try Forge3DSceneLoad(entities: 501, dynamicBodies: 0, lights: 0, textureMemoryMB: 0)
    #expect(throws: Forge3DValidationError.budgetExceeded) {
        try load.validate(against: .iPhone12Baseline)
    }
}

@Test func axisDeadZoneIsDeterministic() throws {
    let binding = try Forge3DInputBinding(actionID: "steer", source: .touchAxis, deadZone: 0.2)
    #expect(try binding.normalizedAxis(0.1) == 0)
    #expect(try binding.normalizedAxis(1.5) == 1)
    #expect(try binding.normalizedAxis(-0.6) == -0.5)
}

@Test func duplicateEntitiesFailClosed() throws {
    let entity = try Forge3DEntity(id: "car", transform: transform(), dynamicBody: true)
    #expect(throws: Forge3DValidationError.duplicateEntity) {
        _ = try Forge3DProjectSpec(projectID: "p", sourceRevision: "r1", entities: [entity, entity], inputBindings: [], budget: .iPhone12Baseline)
    }
}

@Test func duplicateActionsFailClosed() throws {
    let first = try Forge3DInputBinding(actionID: "drive", source: .touchAxis)
    let second = try Forge3DInputBinding(actionID: "drive", source: .controllerAxis)
    #expect(throws: Forge3DValidationError.duplicateAction) {
        _ = try Forge3DProjectSpec(projectID: "p", sourceRevision: "r1", entities: [], inputBindings: [first, second], budget: .iPhone12Baseline)
    }
}

@Test func projectCanonicalizesStableOrdering() throws {
    let z = try Forge3DEntity(id: "z", transform: transform(), dynamicBody: false)
    let a = try Forge3DEntity(id: "a", transform: transform(), dynamicBody: false)
    let spec = try Forge3DProjectSpec(projectID: " p ", sourceRevision: " r1 ", entities: [z, a], inputBindings: [], budget: .iPhone12Baseline)
    #expect(spec.projectID == "p")
    #expect(spec.sourceRevision == "r1")
    #expect(spec.entities.map(\.id) == ["a", "z"])
}

@Test func decodeRevalidatesArchive() throws {
    let entity = try Forge3DEntity(id: "car", transform: transform(), dynamicBody: true)
    let spec = try Forge3DProjectSpec(projectID: "p", sourceRevision: "r1", entities: [entity], inputBindings: [], budget: .iPhone12Baseline)
    let data = try JSONEncoder().encode(spec)
    #expect(try Forge3DProjectSpec.decodeValidated(data) == spec)
}
