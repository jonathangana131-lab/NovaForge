import Foundation
import Testing
@testable import ForgeGameInspectorCore

@Test func incompleteReportedProducerMetadataIsRejected() throws {
    #expect(throws: ForgeGameInspectorError.incompleteReportedProducerMetadata) {
        try ForgeGameInspectionSnapshotCandidate(
            target: makeTarget(),
            entities: [makeEntity()],
            reportedProducer: "runtime-scene-bridge",
            reportedProducerReceiptID: nil
        )
    }
}

@Test func entityDecodeStopsAtTunableLimit() throws {
    let entity = try makeEntity()
    let encoded = try JSONEncoder().encode(entity)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let tunables = try #require(object["tunables"] as? [[String: Any]])
    object["tunables"] = Array(repeating: tunables[0], count: 65)
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ForgeGameInspectorError.tooManyTunables) {
        try JSONDecoder().decode(ForgeGameEntityCandidate.self, from: tampered)
    }
}

@Test func snapshotDecodeStopsAtEntityLimit() throws {
    let snapshot = try makeSnapshot()
    let encoded = try JSONEncoder().encode(snapshot)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let entities = try #require(object["entities"] as? [[String: Any]])
    object["entities"] = Array(repeating: entities[0], count: ForgeGameInspectionSnapshotCandidate.maximumEntityCount + 1)
    let tampered = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ForgeGameInspectorError.tooManyEntities) {
        try JSONDecoder().decode(ForgeGameInspectionSnapshotCandidate.self, from: tampered)
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
