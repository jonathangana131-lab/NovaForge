import Foundation
import Testing
@testable import ForgeEvidenceCore

private let digestA = try! ForgeEvidenceDigest(rawValue: String(repeating: "a", count: 64))
private let digestB = try! ForgeEvidenceDigest(rawValue: String(repeating: "b", count: 64))
private let digestC = try! ForgeEvidenceDigest(rawValue: String(repeating: "c", count: 64))

private func id(_ value: String) -> ForgeEvidenceIdentifier {
    try! ForgeEvidenceIdentifier(rawValue: value)
}

private func binding(
    project: String = "project-1",
    revision: String = "rev-1",
    checkpoint: String = "checkpoint-1"
) -> ForgeEvidenceBinding {
    ForgeEvidenceBinding(
        projectID: id(project),
        sourceRevision: id(revision),
        checkpointID: id(checkpoint)
    )
}

private func producer(_ kind: ForgeEvidenceProducerKind = .testHarness, _ value: String = "producer-1") -> ForgeEvidenceProducer {
    ForgeEvidenceProducer(kind: kind, id: id(value))
}

private func receipt(
    _ value: String,
    binding receiptBinding: ForgeEvidenceBinding = binding(),
    evidenceClass: ForgeEvidenceClass = .test,
    subject: String? = "journey-1",
    producer receiptProducer: ForgeEvidenceProducer = producer(),
    outcome: ForgeEvidenceOutcome = .passed,
    digest: ForgeEvidenceDigest = digestA,
    supersedes: [String] = []
) throws -> ForgeEvidenceReceipt {
    try ForgeEvidenceReceipt(
        id: id(value),
        binding: receiptBinding,
        evidenceClass: evidenceClass,
        subjectID: subject.map(id),
        producer: receiptProducer,
        outcome: outcome,
        payloadDigest: digest,
        supersedes: supersedes.map(id)
    )
}

@Test func recordsCurrentEvidenceWithoutConvertingProducerOutcomeIntoCompletion() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1", outcome: .failed))
    try ledger.record(receipt("r2", evidenceClass: .visual, subject: "screen-home", producer: producer(.visualQA, "visual-qa"), outcome: .observed))

    #expect(ledger.revision == 2)
    #expect(ledger.currentProjection().receipts.map(\.id.rawValue) == ["r1", "r2"])
    #expect(ledger.currentReceipts(for: .test).first?.outcome == .failed)
}

@Test func rejectsCrossProjectRevisionAndCheckpointReceipts() throws {
    for wrongBinding in [
        binding(project: "project-2"),
        binding(revision: "rev-2"),
        binding(checkpoint: "checkpoint-2"),
    ] {
        var ledger = ForgeEvidenceLedger(binding: binding())
        #expect(throws: ForgeEvidenceError.identityMismatch) {
            try ledger.record(receipt("r1", binding: wrongBinding))
        }
    }
}

@Test func rejectsDuplicateReceiptIdentity() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1"))
    #expect(throws: ForgeEvidenceError.duplicateReceiptID("r1")) {
        try ledger.record(receipt("r1", digest: digestB))
    }
}

@Test func supersessionMakesOldReceiptNonCurrentButPreservesHistory() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1"))
    try ledger.record(receipt("r2", digest: digestB, supersedes: ["r1"]))

    #expect(!ledger.isCurrent(id("r1")))
    #expect(ledger.isCurrent(id("r2")))
    #expect(ledger.receipt(id: id("r1")) != nil)
    #expect(ledger.events.count == 2)
    #expect(ledger.currentProjection().receipts.map(\.id.rawValue) == ["r2"])
}

@Test func supersessionMustTargetCurrentKnownEvidence() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    #expect(throws: ForgeEvidenceError.unknownReceiptID("missing")) {
        try ledger.record(receipt("r2", supersedes: ["missing"]))
    }

    try ledger.record(receipt("r1"))
    try ledger.record(receipt("r2", digest: digestB, supersedes: ["r1"]))
    #expect(throws: ForgeEvidenceError.receiptNotCurrent("r1")) {
        try ledger.record(receipt("r3", digest: digestC, supersedes: ["r1"]))
    }
}

@Test func supersessionCannotCrossEvidenceClassSubjectOrProducer() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1"))

    #expect(throws: ForgeEvidenceError.invalidSupersession("r1")) {
        try ledger.record(receipt("visual", evidenceClass: .visual, producer: producer(.visualQA, "visual"), supersedes: ["r1"]))
    }
    #expect(throws: ForgeEvidenceError.invalidSupersession("r1")) {
        try ledger.record(receipt("other-subject", subject: "journey-2", supersedes: ["r1"]))
    }
    #expect(throws: ForgeEvidenceError.invalidSupersession("r1")) {
        try ledger.record(receipt("other-producer", producer: producer(.testHarness, "producer-2"), supersedes: ["r1"]))
    }
}

@Test func receiptRejectsDuplicateOrSelfSupersession() throws {
    #expect(throws: ForgeEvidenceError.invalidSupersession("r2")) {
        _ = try receipt("r2", supersedes: ["r1", "r1"])
    }
    #expect(throws: ForgeEvidenceError.invalidSupersession("r2")) {
        _ = try receipt("r2", supersedes: ["r2"])
    }
}

@Test func producerCanRevokeItsOwnCurrentReceipt() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    let owner = producer(.performanceHarness, "perf-harness")
    try ledger.record(receipt("perf-1", evidenceClass: .performance, subject: "heavy-path", producer: owner))
    let revocation = try ForgeEvidenceRevocation(
        id: id("revoke-1"),
        binding: binding(),
        targetReceiptID: id("perf-1"),
        producer: owner,
        reason: .invalidMeasurement,
        payloadDigest: digestB
    )
    try ledger.revoke(revocation)

    #expect(!ledger.isCurrent(id("perf-1")))
    #expect(ledger.currentReceipts(for: .performance).isEmpty)
    #expect(ledger.revision == 2)
}

@Test func anotherProducerCannotRevokeEvidence() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1"))
    let revocation = try ForgeEvidenceRevocation(
        id: id("revoke-1"),
        binding: binding(),
        targetReceiptID: id("r1"),
        producer: producer(.testHarness, "intruder"),
        reason: .withdrawnByProducer,
        payloadDigest: digestB
    )
    #expect(throws: ForgeEvidenceError.invalidRevocation("r1")) {
        try ledger.revoke(revocation)
    }
}

@Test func revokedOrSupersededReceiptCannotBeRevokedAgain() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    let owner = producer()
    try ledger.record(receipt("r1", producer: owner))
    try ledger.record(receipt("r2", producer: owner, digest: digestB, supersedes: ["r1"]))
    let revocation = try ForgeEvidenceRevocation(
        id: id("revoke-1"),
        binding: binding(),
        targetReceiptID: id("r1"),
        producer: owner,
        reason: .producerCorrection,
        payloadDigest: digestC
    )
    #expect(throws: ForgeEvidenceError.receiptNotCurrent("r1")) {
        try ledger.revoke(revocation)
    }
}

@Test func revocationRejectsCrossBindingAndSelfTarget() throws {
    #expect(throws: ForgeEvidenceError.invalidRevocation("revoke-1")) {
        _ = try ForgeEvidenceRevocation(
            id: id("revoke-1"),
            binding: binding(),
            targetReceiptID: id("revoke-1"),
            producer: producer(),
            reason: .producerCorrection,
            payloadDigest: digestA
        )
    }

    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1"))
    let wrong = try ForgeEvidenceRevocation(
        id: id("revoke-2"),
        binding: binding(revision: "rev-2"),
        targetReceiptID: id("r1"),
        producer: producer(),
        reason: .producerCorrection,
        payloadDigest: digestB
    )
    #expect(throws: ForgeEvidenceError.identityMismatch) {
        try ledger.revoke(wrong)
    }
}

@Test func opaqueIdentifiersRejectOnlyUnstableOrUnsafeShape() throws {
    for value in [" receipt", "receipt ", "line\nbreak", "", String(repeating: "a", count: 257)] {
        #expect(throws: ForgeEvidenceError.self) {
            _ = try ForgeEvidenceIdentifier(rawValue: value)
        }
    }

    #expect(try ForgeEvidenceIdentifier(rawValue: "mission:checkpoint/accepted-state").rawValue == "mission:checkpoint/accepted-state")
    #expect(try ForgeEvidenceIdentifier(rawValue: "Receipt_1.v2-test").rawValue == "Receipt_1.v2-test")
}

@Test func digestRequiresCanonicalLowercaseSHA256Shape() throws {
    #expect(throws: ForgeEvidenceError.invalidDigest(field: "digest")) {
        _ = try ForgeEvidenceDigest(rawValue: String(repeating: "A", count: 64))
    }
    #expect(throws: ForgeEvidenceError.invalidDigest(field: "digest")) {
        _ = try ForgeEvidenceDigest(rawValue: String(repeating: "a", count: 63))
    }
    #expect(try ForgeEvidenceDigest(rawValue: String(repeating: "0", count: 64)).rawValue.count == 64)
}

@Test func projectionOrderingIsDeterministicAcrossEvidenceClassesSubjectsAndIDs() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("z", evidenceClass: .visual, subject: "b", producer: producer(.visualQA, "v")))
    try ledger.record(receipt("b", evidenceClass: .test, subject: "z"))
    try ledger.record(receipt("a", evidenceClass: .test, subject: "a"))
    try ledger.record(receipt("c", evidenceClass: .test, subject: "a", digest: digestB))

    #expect(ledger.currentProjection().receipts.map(\.id.rawValue) == ["a", "c", "b", "z"])
}

@Test func archiveRoundTripReplaysExactCurrentLineage() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    let owner = producer()
    try ledger.record(receipt("r1", producer: owner))
    try ledger.record(receipt("r2", producer: owner, digest: digestB, supersedes: ["r1"]))
    let revocation = try ForgeEvidenceRevocation(
        id: id("revoke-1"),
        binding: binding(),
        targetReceiptID: id("r2"),
        producer: owner,
        reason: .producerCorrection,
        payloadDigest: digestC
    )
    try ledger.revoke(revocation)

    let data = try JSONEncoder().encode(ledger.archive())
    let decoded = try JSONDecoder().decode(ForgeEvidenceLedgerArchive.self, from: data)
    let replayed = try decoded.validatedLedger()

    #expect(replayed.binding == ledger.binding)
    #expect(replayed.events == ledger.events)
    #expect(replayed.currentProjection().receipts.isEmpty)
}

@Test func archiveRejectsUnknownSchema() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1"))
    let data = try JSONEncoder().encode(ledger.archive())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["schemaVersion"] = 99
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeEvidenceError.invalidSchema(99)) {
        _ = try JSONDecoder().decode(ForgeEvidenceLedgerArchive.self, from: tampered)
    }
}

@Test func archiveRejectsRevisionDrift() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1"))
    let data = try JSONEncoder().encode(ledger.archive())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["ledgerRevision"] = 2
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeEvidenceError.invalidLedgerRevision) {
        _ = try JSONDecoder().decode(ForgeEvidenceLedgerArchive.self, from: tampered)
    }
}

@Test func archiveRejectsSkippedOrReplayedEventSequence() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1"))
    try ledger.record(receipt("r2", subject: "journey-2", digest: digestB))
    let data = try JSONEncoder().encode(ledger.archive())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var events = try #require(object["events"] as? [[String: Any]])
    events[1]["sequence"] = 1
    object["events"] = events
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeEvidenceError.invalidEventSequence(expected: 2, actual: 1)) {
        _ = try JSONDecoder().decode(ForgeEvidenceLedgerArchive.self, from: tampered)
    }
}

@Test func decodedReceiptRevalidatesCanonicalSupersessionAndDigest() throws {
    let original = try receipt("r2", supersedes: ["r1"])
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["supersedes"] = ["r1", "r1"]
    let duplicateSupersession = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ForgeEvidenceError.invalidSupersession("r2")) {
        _ = try JSONDecoder().decode(ForgeEvidenceReceipt.self, from: duplicateSupersession)
    }

    object["supersedes"] = ["r1"]
    object["payloadDigest"] = String(repeating: "A", count: 64)
    let badDigest = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ForgeEvidenceError.invalidDigest(field: "digest")) {
        _ = try JSONDecoder().decode(ForgeEvidenceReceipt.self, from: badDigest)
    }
}

@Test func archiveReplayRejectsCrossRevisionEvidenceEvenIfOuterBindingLooksValid() throws {
    var ledger = ForgeEvidenceLedger(binding: binding())
    try ledger.record(receipt("r1"))
    let data = try JSONEncoder().encode(ledger.archive())
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var events = try #require(object["events"] as? [[String: Any]])
    var payload = try #require(events[0]["payload"] as? [String: Any])
    var receiptObject = try #require(payload["receipt"] as? [String: Any])
    var receiptBinding = try #require(receiptObject["binding"] as? [String: Any])
    receiptBinding["sourceRevision"] = "rev-2"
    receiptObject["binding"] = receiptBinding
    payload["receipt"] = receiptObject
    events[0]["payload"] = payload
    object["events"] = events
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeEvidenceError.identityMismatch) {
        _ = try JSONDecoder().decode(ForgeEvidenceLedgerArchive.self, from: tampered)
    }
}
