import Foundation
import Testing
@testable import ForgeGameInspectorCore

private func makeTarget(
    projectID: String = "project-1",
    sourceRevision: String = "source-a",
    runtimeSessionID: String = "session-1",
    runtimeVersion: String = "runtime-1",
    captureID: String = "capture-1",
    frameSequence: UInt64 = 8
) throws -> ForgeGameInspectionTarget {
    try ForgeGameInspectionTarget(
        projectID: projectID,
        sourceRevision: sourceRevision,
        runtimeSessionID: runtimeSessionID,
        runtimeVersion: runtimeVersion,
        captureID: captureID,
        frameSequence: frameSequence
    )
}

private func makeSource(_ key: String = "player.mass") throws -> ForgeGameSourceAssociation {
    try ForgeGameSourceAssociation(
        relativeFilePath: "game/entities/player.js",
        symbolID: "PlayerController",
        configKey: key
    )
}

private func makeMassTunable() throws -> ForgePhysicsTunableCandidate {
    try ForgePhysicsTunableCandidate(
        id: "mass",
        kind: .mass,
        label: "Mass",
        unit: "kg",
        currentValue: 1200,
        minimumValue: 500,
        maximumValue: 2500,
        step: 10,
        source: makeSource()
    )
}

private func makeEntity() throws -> ForgeGameEntityCandidate {
    try ForgeGameEntityCandidate(
        id: "player-car",
        kind: .physicsBody,
        displayName: "Player Car",
        normalizedBounds: ForgeGameNormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3),
        source: makeSource(),
        tunables: [makeMassTunable()]
    )
}

private func makeSnapshot(target: ForgeGameInspectionTarget? = nil) throws -> ForgeGameInspectionSnapshotCandidate {
    try ForgeGameInspectionSnapshotCandidate(
        target: target ?? makeTarget(),
        entities: [makeEntity()],
        reportedProducer: "runtime-scene-bridge",
        reportedProducerReceiptID: "candidate-receipt-1"
    )
}

@Test func resolvesSelectionOnlyAgainstExactFrameTarget() throws {
    let snapshot = try makeSnapshot()
    let selection = try ForgeGameEntitySelectionCandidate(target: snapshot.target, entityID: "player-car")
    let entity = try ForgeGameInspectorCandidateResolver.resolve(selection: selection, in: snapshot)
    #expect(entity.id == "player-car")

    let staleTarget = try makeTarget(frameSequence: snapshot.target.frameSequence + 1)
    let staleSelection = try ForgeGameEntitySelectionCandidate(target: staleTarget, entityID: "player-car")
    #expect(throws: ForgeGameInspectorError.selectionTargetMismatch) {
        try ForgeGameInspectorCandidateResolver.resolve(selection: staleSelection, in: snapshot)
    }
}

@Test func crossRuntimeVersionSelectionFailsClosed() throws {
    let snapshot = try makeSnapshot()
    let otherRuntime = try makeTarget(runtimeVersion: "runtime-2")
    let selection = try ForgeGameEntitySelectionCandidate(target: otherRuntime, entityID: "player-car")

    #expect(throws: ForgeGameInspectorError.selectionTargetMismatch) {
        try ForgeGameInspectorCandidateResolver.resolve(selection: selection, in: snapshot)
    }
}

@Test func duplicateEntityIDsAreRejected() throws {
    let entity = try makeEntity()
    #expect(throws: ForgeGameInspectorError.duplicateEntityID("player-car")) {
        try ForgeGameInspectionSnapshotCandidate(target: makeTarget(), entities: [entity, entity])
    }
}

@Test func danglingParentEntityIsRejected() throws {
    let child = try ForgeGameEntityCandidate(
        id: "wheel",
        parentID: "missing-car",
        kind: .sceneObject,
        displayName: "Wheel",
        source: makeSource()
    )

    #expect(throws: ForgeGameInspectorError.entityNotFound("missing-car")) {
        try ForgeGameInspectionSnapshotCandidate(target: makeTarget(), entities: [child])
    }
}

@Test func cyclicEntityHierarchyIsRejected() throws {
    let source = try makeSource()
    let a = try ForgeGameEntityCandidate(
        id: "a",
        parentID: "b",
        kind: .sceneObject,
        displayName: "A",
        source: source
    )
    let b = try ForgeGameEntityCandidate(
        id: "b",
        parentID: "a",
        kind: .sceneObject,
        displayName: "B",
        source: source
    )

    #expect(throws: ForgeGameInspectorError.invalidIdentity("entityHierarchyCycle")) {
        try ForgeGameInspectionSnapshotCandidate(target: makeTarget(), entities: [a, b])
    }
}

@Test func sourceAssociationRejectsPathTraversalAndAbsolutePaths() {
    #expect(throws: ForgeGameInspectorError.invalidSourceAssociation) {
        try ForgeGameSourceAssociation(relativeFilePath: "../secrets.js")
    }
    #expect(throws: ForgeGameInspectorError.invalidSourceAssociation) {
        try ForgeGameSourceAssociation(relativeFilePath: "/tmp/game.js")
    }
}

@Test func normalizedBoundsRejectOverflowAndNonFiniteNumbers() {
    #expect(throws: ForgeGameInspectorError.invalidBounds) {
        try ForgeGameNormalizedRect(x: 0.8, y: 0, width: 0.3, height: 1)
    }
    #expect(throws: ForgeGameInspectorError.nonFiniteNumber) {
        try ForgeGameNormalizedRect(x: .nan, y: 0, width: 0.1, height: 0.1)
    }
}

@Test func duplicateTunablesAreRejectedPerEntity() throws {
    let mass = try makeMassTunable()
    #expect(throws: ForgeGameInspectorError.duplicateTunableID("mass")) {
        try ForgeGameEntityCandidate(
            id: "player-car",
            kind: .physicsBody,
            displayName: "Player Car",
            source: makeSource(),
            tunables: [mass, mass]
        )
    }
}

@Test func tuningProposalMustRemainInsideDeclaredRange() throws {
    let snapshot = try makeSnapshot()
    let valid = try ForgePhysicsTuningProposalCandidate(
        target: snapshot.target,
        entityID: "player-car",
        tunableID: "mass",
        proposedValue: 1400
    )
    let tunable = try ForgeGameInspectorCandidateResolver.resolve(tuning: valid, in: snapshot)
    #expect(tunable.currentValue == 1200)

    let invalid = try ForgePhysicsTuningProposalCandidate(
        target: snapshot.target,
        entityID: "player-car",
        tunableID: "mass",
        proposedValue: 4000
    )
    #expect(throws: ForgeGameInspectorError.tuningOutOfRange) {
        try ForgeGameInspectorCandidateResolver.resolve(tuning: invalid, in: snapshot)
    }
}

@Test func snapshotDecodeRevalidatesDuplicateEntities() throws {
    let snapshot = try makeSnapshot()
    let encoded = try JSONEncoder().encode(snapshot)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let entities = try #require(object["entities"] as? [[String: Any]])
    object["entities"] = [entities[0], entities[0]]
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ForgeGameInspectionSnapshotCandidate.self, from: tampered)
    }
}

@Test func tunableDecodeRevalidatesRange() throws {
    let tunable = try makeMassTunable()
    let encoded = try JSONEncoder().encode(tunable)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["minimumValue"] = 3000.0
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(ForgePhysicsTunableCandidate.self, from: tampered)
    }
}

@Test func snapshotRoundTripPreservesCandidateMetadataWithoutAuthorityUpgrade() throws {
    let snapshot = try makeSnapshot()
    let encoded = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ForgeGameInspectionSnapshotCandidate.self, from: encoded)

    #expect(decoded == snapshot)
    #expect(decoded.reportedProducer == "runtime-scene-bridge")
    #expect(decoded.reportedProducerReceiptID == "candidate-receipt-1")
}
