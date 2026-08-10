import Foundation
import Testing
@testable import ForgeGameInspectorCore

@Test func resolvesSelectionOnlyAgainstExactFrameTarget() throws {
    let snapshot = try makeSnapshot()
    let selection = try ForgeGameEntitySelectionCandidate(target: snapshot.target, entityID: "player-car")
    #expect(try ForgeGameInspectorCandidateResolver.resolve(selection: selection, in: snapshot).id == "player-car")

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

@Test func danglingAndCyclicParentEntitiesAreRejected() throws {
    let child = try ForgeGameEntityCandidate(
        id: "wheel", parentID: "missing-car", kind: .sceneObject, displayName: "Wheel", source: makeSource()
    )
    #expect(throws: ForgeGameInspectorError.entityNotFound("missing-car")) {
        try ForgeGameInspectionSnapshotCandidate(target: makeTarget(), entities: [child])
    }

    let source = try makeSource()
    let a = try ForgeGameEntityCandidate(id: "a", parentID: "b", kind: .sceneObject, displayName: "A", source: source)
    let b = try ForgeGameEntityCandidate(id: "b", parentID: "a", kind: .sceneObject, displayName: "B", source: source)
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
            id: "player-car", kind: .physicsBody, displayName: "Player Car", source: makeSource(), tunables: [mass, mass]
        )
    }
}

@Test func tuningProposalMustRemainInsideDeclaredRange() throws {
    let snapshot = try makeSnapshot()
    let valid = try ForgePhysicsTuningProposalCandidate(
        target: snapshot.target, entityID: "player-car", tunableID: "mass", proposedValue: 1400
    )
    #expect(try ForgeGameInspectorCandidateResolver.resolve(tuning: valid, in: snapshot).currentValue == 1200)

    let invalid = try ForgePhysicsTuningProposalCandidate(
        target: snapshot.target, entityID: "player-car", tunableID: "mass", proposedValue: 4000
    )
    #expect(throws: ForgeGameInspectorError.tuningOutOfRange) {
        try ForgeGameInspectorCandidateResolver.resolve(tuning: invalid, in: snapshot)
    }
}
