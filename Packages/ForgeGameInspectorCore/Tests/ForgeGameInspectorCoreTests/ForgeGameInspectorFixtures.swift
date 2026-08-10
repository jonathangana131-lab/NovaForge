import Foundation
@testable import ForgeGameInspectorCore

func makeTarget(
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

func makeSource(_ key: String = "player.mass") throws -> ForgeGameSourceAssociation {
    try ForgeGameSourceAssociation(
        relativeFilePath: "game/entities/player.js",
        symbolID: "PlayerController",
        configKey: key
    )
}

func makeMassTunable() throws -> ForgePhysicsTunableCandidate {
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

func makeEntity() throws -> ForgeGameEntityCandidate {
    try ForgeGameEntityCandidate(
        id: "player-car",
        kind: .physicsBody,
        displayName: "Player Car",
        normalizedBounds: ForgeGameNormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.3),
        source: makeSource(),
        tunables: [makeMassTunable()]
    )
}

func makeSnapshot(target: ForgeGameInspectionTarget? = nil) throws -> ForgeGameInspectionSnapshotCandidate {
    try ForgeGameInspectionSnapshotCandidate(
        target: target ?? makeTarget(),
        entities: [makeEntity()],
        reportedProducer: "runtime-scene-bridge",
        reportedProducerReceiptID: "candidate-receipt-1"
    )
}
