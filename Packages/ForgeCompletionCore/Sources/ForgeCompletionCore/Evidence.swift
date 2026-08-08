import Foundation

public enum ForgeCompletionEvidenceVerdict: String, Codable, Sendable {
    case passed
    case failed
    case inconclusive
}

/// Evidence is bound to the exact project/mission/checkpoint identity. A model assertion is representable for audit,
/// but the completion gate deliberately ignores it and criteria are forbidden from requiring it.
public struct ForgeCompletionEvidenceReceipt: Codable, Sendable {
    public let receiptID: String
    public let criterionID: String
    public let evidenceClass: ForgeCompletionEvidenceClass
    public let producer: ForgeCompletionEvidenceProducer
    public let verdict: ForgeCompletionEvidenceVerdict
    public let scope: ForgeCompletionScope
    public let environment: ForgeCompletionEvidenceEnvironment
    public let evidenceRevision: UInt64
    public let summary: String

    public init(
        receiptID: String,
        criterionID: String,
        evidenceClass: ForgeCompletionEvidenceClass,
        producer: ForgeCompletionEvidenceProducer,
        verdict: ForgeCompletionEvidenceVerdict,
        scope: ForgeCompletionScope,
        environment: ForgeCompletionEvidenceEnvironment,
        evidenceRevision: UInt64,
        summary: String
    ) throws {
        self.receiptID = try validatedCanonicalID(receiptID, field: "receiptID")
        self.criterionID = try validatedCanonicalID(criterionID, field: "criterionID")
        guard producer.mayProduce(evidenceClass) else { throw ForgeCompletionValidationError.evidenceProducerMismatch }
        self.evidenceClass = evidenceClass
        self.producer = producer
        self.verdict = verdict
        self.scope = scope
        self.environment = environment
        guard evidenceRevision > 0 else { throw ForgeCompletionValidationError.invalidRevision("evidenceRevision") }
        self.evidenceRevision = evidenceRevision
        self.summary = try validatedNonblank(summary, field: "receipt.summary")
    }

    private enum CodingKeys: String, CodingKey {
        case receiptID, criterionID, evidenceClass, producer, verdict, scope, environment, evidenceRevision, summary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            receiptID: container.decode(String.self, forKey: .receiptID),
            criterionID: container.decode(String.self, forKey: .criterionID),
            evidenceClass: container.decode(ForgeCompletionEvidenceClass.self, forKey: .evidenceClass),
            producer: container.decode(ForgeCompletionEvidenceProducer.self, forKey: .producer),
            verdict: container.decode(ForgeCompletionEvidenceVerdict.self, forKey: .verdict),
            scope: container.decode(ForgeCompletionScope.self, forKey: .scope),
            environment: container.decode(ForgeCompletionEvidenceEnvironment.self, forKey: .environment),
            evidenceRevision: container.decode(UInt64.self, forKey: .evidenceRevision),
            summary: container.decode(String.self, forKey: .summary)
        )
    }
}

private struct CurrentEvidenceKey: Hashable {
    let scope: ForgeCompletionScope
    let criterionID: String
    let evidenceClass: ForgeCompletionEvidenceClass
}

public struct ForgeCompletionEvidenceArchive: Codable, Sendable {
    public let receipts: [ForgeCompletionEvidenceReceipt]

    public init(receipts: [ForgeCompletionEvidenceReceipt]) throws {
        var receiptIDs = Set<String>()
        var currentKeys = Set<CurrentEvidenceKey>()
        for receipt in receipts {
            guard receiptIDs.insert(receipt.receiptID).inserted else {
                throw ForgeCompletionValidationError.duplicateReceiptID(receipt.receiptID)
            }
            guard receipt.evidenceClass != .modelAssertion else { continue }
            let key = CurrentEvidenceKey(scope: receipt.scope, criterionID: receipt.criterionID, evidenceClass: receipt.evidenceClass)
            guard currentKeys.insert(key).inserted else {
                throw ForgeCompletionValidationError.conflictingCurrentEvidence(receipt.criterionID)
            }
        }
        self.receipts = receipts.sorted { $0.receiptID < $1.receiptID }
    }

    private enum CodingKeys: String, CodingKey { case receipts }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(receipts: container.decode([ForgeCompletionEvidenceReceipt].self, forKey: .receipts))
    }
}
