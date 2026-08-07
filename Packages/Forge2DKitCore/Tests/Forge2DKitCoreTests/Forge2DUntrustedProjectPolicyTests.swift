import Foundation
import Testing
@testable import Forge2DKitCore

@Test func untrustedInputMapAcceptsCanonicalBoundedConfiguration() throws {
    let move = Forge2DActionID(rawValue: "move-x")
    let binding = try Forge2DInputBinding(
        id: "left-stick-x",
        action: move,
        source: .controllerAxis(id: "gamepad.leftX", minimum: -1, maximum: 1)
    )
    let map = try Forge2DInputMap(actions: [move], bindings: [binding])
    let data = try JSONEncoder().encode(map)
    #expect(try Forge2DUntrustedProjectPolicy.decodeInputMap(data) == map)
}

@Test func untrustedInputMapRejectsNonCanonicalBindingIdentity() throws {
    let move = Forge2DActionID(rawValue: "move")
    let binding = try Forge2DInputBinding(id: " move-binding ", action: move, source: .touchButton(id: "touch.move"))
    let map = try Forge2DInputMap(actions: [move], bindings: [binding])
    #expect(throws: Forge2DUntrustedProjectError.invalidIdentifier(field: "binding")) {
        try Forge2DUntrustedProjectPolicy.validate(map)
    }
}

@Test func untrustedInputMapRejectsOversizedSerializedDataBeforeDecode() {
    let data = Data(repeating: 0x20, count: Forge2DUntrustedProjectLimits.maximumInputMapBytes + 1)
    #expect(throws: Forge2DUntrustedProjectError.serializedDataTooLarge(
        kind: "inputMap",
        maximumBytes: Forge2DUntrustedProjectLimits.maximumInputMapBytes
    )) {
        _ = try Forge2DUntrustedProjectPolicy.decodeInputMap(data)
    }
}

@Test func untrustedInputMapRejectsExcessActionCount() throws {
    let actions = (0...Forge2DUntrustedProjectLimits.maximumActions).map { Forge2DActionID(rawValue: "a\($0)") }
    let map = try Forge2DInputMap(actions: actions, bindings: [])
    #expect(throws: Forge2DUntrustedProjectError.collectionTooLarge(
        kind: "actions",
        maximumCount: Forge2DUntrustedProjectLimits.maximumActions
    )) {
        try Forge2DUntrustedProjectPolicy.validate(map)
    }
}

@Test func untrustedInputMapRejectsControlCharacterInSourceIdentity() throws {
    let fire = Forge2DActionID(rawValue: "fire")
    let binding = try Forge2DInputBinding(id: "fire-button", action: fire, source: .controllerButton(id: "gamepad\na"))
    let map = try Forge2DInputMap(actions: [fire], bindings: [binding])
    #expect(throws: Forge2DUntrustedProjectError.invalidIdentifier(field: "inputSource")) {
        try Forge2DUntrustedProjectPolicy.validate(map)
    }
}

@Test func untrustedCollisionTableRejectsOversizedSerializedDataBeforeDecode() {
    let data = Data(repeating: 0x20, count: Forge2DUntrustedProjectLimits.maximumCollisionTableBytes + 1)
    #expect(throws: Forge2DUntrustedProjectError.serializedDataTooLarge(
        kind: "collisionTable",
        maximumBytes: Forge2DUntrustedProjectLimits.maximumCollisionTableBytes
    )) {
        _ = try Forge2DUntrustedProjectPolicy.decodeCollisionTable(data)
    }
}

@Test func untrustedCollisionTableRejectsExcessRuleCount() throws {
    let a = try Forge2DCollisionLayer.singleBit(0)
    let b = try Forge2DCollisionLayer.singleBit(1)
    let rule = try Forge2DCollisionRule(first: a, second: b, shouldCollide: true)

    // The base table rejects duplicate pairs, so construct unique single-bit self-pairs and repeat
    // only through a decoded fixture would fail earlier. Validate the policy ceiling with a table
    // composed from every unique ordered pair the 32-bit layer space permits (528 maximum), which
    // proves the configured ceiling remains above the representable collision-pair domain.
    var rules: [Forge2DCollisionRule] = [rule]
    for firstBit in 0..<32 {
        for secondBit in firstBit..<32 {
            let first = try Forge2DCollisionLayer.singleBit(firstBit)
            let second = try Forge2DCollisionLayer.singleBit(secondBit)
            let candidate = try Forge2DCollisionRule(first: first, second: second, shouldCollide: true)
            if !rules.contains(candidate) { rules.append(candidate) }
        }
    }
    let table = try Forge2DCollisionTable(rules: rules)
    #expect(table.rules.count <= Forge2DUntrustedProjectLimits.maximumCollisionRules)
    try Forge2DUntrustedProjectPolicy.validate(table)
}

@Test func untrustedSaveEnvelopeAcceptsExactCanonicalIdentity() throws {
    let envelope = try Forge2DSaveEnvelope(
        projectID: "project-1",
        slotID: "autosave",
        sourceRevision: "revision-7",
        payload: Data("state".utf8)
    )
    let data = try JSONEncoder().encode(envelope)
    #expect(try Forge2DUntrustedProjectPolicy.decodeSaveEnvelope(
        data,
        expectedProjectID: "project-1",
        expectedSourceRevision: "revision-7"
    ) == envelope)
}

@Test func untrustedSaveEnvelopeRejectsNonCanonicalSlotIdentity() throws {
    let envelope = try Forge2DSaveEnvelope(
        projectID: "project-1",
        slotID: " autosave ",
        sourceRevision: "revision-7",
        payload: Data()
    )
    let data = try JSONEncoder().encode(envelope)
    #expect(throws: Forge2DUntrustedProjectError.invalidIdentifier(field: "slotID")) {
        _ = try Forge2DUntrustedProjectPolicy.decodeSaveEnvelope(
            data,
            expectedProjectID: "project-1",
            expectedSourceRevision: "revision-7"
        )
    }
}

@Test func untrustedSaveEnvelopeRejectsOversizedSerializedDataBeforeDecode() {
    let data = Data(repeating: 0x20, count: Forge2DUntrustedProjectLimits.maximumEncodedSaveBytes + 1)
    #expect(throws: Forge2DUntrustedProjectError.serializedDataTooLarge(
        kind: "saveEnvelope",
        maximumBytes: Forge2DUntrustedProjectLimits.maximumEncodedSaveBytes
    )) {
        _ = try Forge2DUntrustedProjectPolicy.decodeSaveEnvelope(
            data,
            expectedProjectID: "project-1",
            expectedSourceRevision: "revision-7"
        )
    }
}
