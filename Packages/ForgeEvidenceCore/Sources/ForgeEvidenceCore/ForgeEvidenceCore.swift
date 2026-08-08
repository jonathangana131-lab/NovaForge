import Foundation

public enum ForgeEvidenceError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidDigest(field: String)
    case invalidSchema(Int)
    case invalidLedgerRevision
    case invalidEventSequence(expected: UInt64, actual: UInt64)
    case identityMismatch
    case duplicateReceiptID(String)
    case unknownReceiptID(String)
    case receiptNotCurrent(String)
    case invalidSupersession(String)
    case invalidRevocation(String)
}

public struct ForgeEvidenceIdentifier: Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard Self.isCanonical(rawValue) else {
            throw ForgeEvidenceError.invalidIdentifier(field: "identifier")
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    private static func isCanonical(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256 else { return false }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ForgeEvidenceDigest: Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.count == 64,
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 97...102: true
                  default: false
                  }
              })
        else {
            throw ForgeEvidenceError.invalidDigest(field: "digest")
        }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ForgeEvidenceBinding: Codable, Hashable, Sendable {
    public let projectID: ForgeEvidenceIdentifier
    public let sourceRevision: ForgeEvidenceIdentifier
    public let checkpointID: ForgeEvidenceIdentifier

    public init(
        projectID: ForgeEvidenceIdentifier,
        sourceRevision: ForgeEvidenceIdentifier,
        checkpointID: ForgeEvidenceIdentifier
    ) {
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.checkpointID = checkpointID
    }
}

public enum ForgeEvidenceClass: String, Codable, CaseIterable, Hashable, Sendable {
    case build
    case launch
    case runtimeJourney
    case test
    case visual
    case accessibility
    case performance
    case persistence
    case crash
}

public enum ForgeEvidenceProducerKind: String, Codable, CaseIterable, Hashable, Sendable {
    case buildSystem
    case runtimeHost
    case testHarness
    case visualQA
    case accessibilityHarness
    case performanceHarness
    case persistenceHarness
}

public struct ForgeEvidenceProducer: Codable, Hashable, Sendable {
    public let kind: ForgeEvidenceProducerKind
    public let id: ForgeEvidenceIdentifier

    public init(kind: ForgeEvidenceProducerKind, id: ForgeEvidenceIdentifier) {
        self.kind = kind
        self.id = id
    }
}

public enum ForgeEvidenceOutcome: String, Codable, Hashable, Sendable {
    case passed
    case failed
    case observed
}

public struct ForgeEvidenceReceipt: Codable, Hashable, Sendable {
    public let id: ForgeEvidenceIdentifier
    public let binding: ForgeEvidenceBinding
    public let evidenceClass: ForgeEvidenceClass
    public let subjectID: ForgeEvidenceIdentifier?
    public let producer: ForgeEvidenceProducer
    public let outcome: ForgeEvidenceOutcome
    public let payloadDigest: ForgeEvidenceDigest
    public let supersedes: [ForgeEvidenceIdentifier]

    public init(
        id: ForgeEvidenceIdentifier,
        binding: ForgeEvidenceBinding,
        evidenceClass: ForgeEvidenceClass,
        subjectID: ForgeEvidenceIdentifier? = nil,
        producer: ForgeEvidenceProducer,
        outcome: ForgeEvidenceOutcome,
        payloadDigest: ForgeEvidenceDigest,
        supersedes: [ForgeEvidenceIdentifier] = []
    ) throws {
        let canonicalSupersedes = supersedes.sorted()
        guard Set(canonicalSupersedes).count == canonicalSupersedes.count,
              !canonicalSupersedes.contains(id)
        else {
            throw ForgeEvidenceError.invalidSupersession(id.rawValue)
        }

        self.id = id
        self.binding = binding
        self.evidenceClass = evidenceClass
        self.subjectID = subjectID
        self.producer = producer
        self.outcome = outcome
        self.payloadDigest = payloadDigest
        self.supersedes = canonicalSupersedes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case binding
        case evidenceClass
        case subjectID
        case producer
        case outcome
        case payloadDigest
        case supersedes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ForgeEvidenceIdentifier.self, forKey: .id),
            binding: container.decode(ForgeEvidenceBinding.self, forKey: .binding),
            evidenceClass: container.decode(ForgeEvidenceClass.self, forKey: .evidenceClass),
            subjectID: container.decodeIfPresent(ForgeEvidenceIdentifier.self, forKey: .subjectID),
            producer: container.decode(ForgeEvidenceProducer.self, forKey: .producer),
            outcome: container.decode(ForgeEvidenceOutcome.self, forKey: .outcome),
            payloadDigest: container.decode(ForgeEvidenceDigest.self, forKey: .payloadDigest),
            supersedes: container.decode([ForgeEvidenceIdentifier].self, forKey: .supersedes)
        )
    }
}

public enum ForgeEvidenceRevocationReason: String, Codable, Hashable, Sendable {
    case producerCorrection
    case invalidArtifact
    case invalidMeasurement
    case withdrawnByProducer
}

public struct ForgeEvidenceRevocation: Codable, Hashable, Sendable {
    public let id: ForgeEvidenceIdentifier
    public let binding: ForgeEvidenceBinding
    public let targetReceiptID: ForgeEvidenceIdentifier
    public let producer: ForgeEvidenceProducer
    public let reason: ForgeEvidenceRevocationReason
    public let payloadDigest: ForgeEvidenceDigest

    public init(
        id: ForgeEvidenceIdentifier,
        binding: ForgeEvidenceBinding,
        targetReceiptID: ForgeEvidenceIdentifier,
        producer: ForgeEvidenceProducer,
        reason: ForgeEvidenceRevocationReason,
        payloadDigest: ForgeEvidenceDigest
    ) throws {
        guard id != targetReceiptID else {
            throw ForgeEvidenceError.invalidRevocation(id.rawValue)
        }
        self.id = id
        self.binding = binding
        self.targetReceiptID = targetReceiptID
        self.producer = producer
        self.reason = reason
        self.payloadDigest = payloadDigest
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case binding
        case targetReceiptID
        case producer
        case reason
        case payloadDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ForgeEvidenceIdentifier.self, forKey: .id),
            binding: container.decode(ForgeEvidenceBinding.self, forKey: .binding),
            targetReceiptID: container.decode(ForgeEvidenceIdentifier.self, forKey: .targetReceiptID),
            producer: container.decode(ForgeEvidenceProducer.self, forKey: .producer),
            reason: container.decode(ForgeEvidenceRevocationReason.self, forKey: .reason),
            payloadDigest: container.decode(ForgeEvidenceDigest.self, forKey: .payloadDigest)
        )
    }
}

public enum ForgeEvidenceLedgerEventPayload: Codable, Hashable, Sendable {
    case receipt(ForgeEvidenceReceipt)
    case revocation(ForgeEvidenceRevocation)

    private enum Kind: String, Codable {
        case receipt
        case revocation
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case receipt
        case revocation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .receipt:
            self = .receipt(try container.decode(ForgeEvidenceReceipt.self, forKey: .receipt))
        case .revocation:
            self = .revocation(try container.decode(ForgeEvidenceRevocation.self, forKey: .revocation))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .receipt(receipt):
            try container.encode(Kind.receipt, forKey: .kind)
            try container.encode(receipt, forKey: .receipt)
        case let .revocation(revocation):
            try container.encode(Kind.revocation, forKey: .kind)
            try container.encode(revocation, forKey: .revocation)
        }
    }
}

public struct ForgeEvidenceLedgerEvent: Codable, Hashable, Sendable {
    public let sequence: UInt64
    public let payload: ForgeEvidenceLedgerEventPayload

    public init(sequence: UInt64, payload: ForgeEvidenceLedgerEventPayload) throws {
        guard sequence > 0 else {
            throw ForgeEvidenceError.invalidEventSequence(expected: 1, actual: sequence)
        }
        self.sequence = sequence
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case sequence
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(UInt64.self, forKey: .sequence),
            payload: container.decode(ForgeEvidenceLedgerEventPayload.self, forKey: .payload)
        )
    }
}

public struct ForgeCurrentEvidenceProjection: Hashable, Sendable {
    public let binding: ForgeEvidenceBinding
    public let ledgerRevision: UInt64
    public let receipts: [ForgeEvidenceReceipt]

    fileprivate init(
        binding: ForgeEvidenceBinding,
        ledgerRevision: UInt64,
        receipts: [ForgeEvidenceReceipt]
    ) {
        self.binding = binding
        self.ledgerRevision = ledgerRevision
        self.receipts = receipts
    }
}

public struct ForgeEvidenceLedger: Hashable, Sendable {
    public static let archiveSchemaVersion = 1

    public let binding: ForgeEvidenceBinding
    public private(set) var events: [ForgeEvidenceLedgerEvent]

    private var receiptsByID: [ForgeEvidenceIdentifier: ForgeEvidenceReceipt]
    private var nonCurrentReceiptIDs: Set<ForgeEvidenceIdentifier>
    private var revocationIDs: Set<ForgeEvidenceIdentifier>

    public var revision: UInt64 { UInt64(events.count) }

    public init(binding: ForgeEvidenceBinding) {
        self.binding = binding
        self.events = []
        self.receiptsByID = [:]
        self.nonCurrentReceiptIDs = []
        self.revocationIDs = []
    }

    public mutating func record(_ receipt: ForgeEvidenceReceipt) throws {
        guard receipt.binding == binding else {
            throw ForgeEvidenceError.identityMismatch
        }
        guard receiptsByID[receipt.id] == nil, !revocationIDs.contains(receipt.id) else {
            throw ForgeEvidenceError.duplicateReceiptID(receipt.id.rawValue)
        }

        for supersededID in receipt.supersedes {
            guard let superseded = receiptsByID[supersededID] else {
                throw ForgeEvidenceError.unknownReceiptID(supersededID.rawValue)
            }
            guard isCurrent(supersededID) else {
                throw ForgeEvidenceError.receiptNotCurrent(supersededID.rawValue)
            }
            guard superseded.evidenceClass == receipt.evidenceClass,
                  superseded.subjectID == receipt.subjectID,
                  superseded.producer == receipt.producer
            else {
                throw ForgeEvidenceError.invalidSupersession(supersededID.rawValue)
            }
        }

        let event = try ForgeEvidenceLedgerEvent(
            sequence: nextSequence(),
            payload: .receipt(receipt)
        )
        events.append(event)
        receiptsByID[receipt.id] = receipt
        nonCurrentReceiptIDs.formUnion(receipt.supersedes)
    }

    public mutating func revoke(_ revocation: ForgeEvidenceRevocation) throws {
        guard revocation.binding == binding else {
            throw ForgeEvidenceError.identityMismatch
        }
        guard receiptsByID[revocation.id] == nil, !revocationIDs.contains(revocation.id) else {
            throw ForgeEvidenceError.duplicateReceiptID(revocation.id.rawValue)
        }
        guard let target = receiptsByID[revocation.targetReceiptID] else {
            throw ForgeEvidenceError.unknownReceiptID(revocation.targetReceiptID.rawValue)
        }
        guard isCurrent(revocation.targetReceiptID) else {
            throw ForgeEvidenceError.receiptNotCurrent(revocation.targetReceiptID.rawValue)
        }
        guard target.producer == revocation.producer else {
            throw ForgeEvidenceError.invalidRevocation(revocation.targetReceiptID.rawValue)
        }

        let event = try ForgeEvidenceLedgerEvent(
            sequence: nextSequence(),
            payload: .revocation(revocation)
        )
        events.append(event)
        nonCurrentReceiptIDs.insert(revocation.targetReceiptID)
        revocationIDs.insert(revocation.id)
    }

    public func currentProjection() -> ForgeCurrentEvidenceProjection {
        let receipts = receiptsByID.values
            .filter { isCurrent($0.id) }
            .sorted(by: Self.receiptSort)
        return ForgeCurrentEvidenceProjection(
            binding: binding,
            ledgerRevision: revision,
            receipts: receipts
        )
    }

    public func currentReceipts(for evidenceClass: ForgeEvidenceClass) -> [ForgeEvidenceReceipt] {
        currentProjection().receipts.filter { $0.evidenceClass == evidenceClass }
    }

    public func receipt(id: ForgeEvidenceIdentifier) -> ForgeEvidenceReceipt? {
        receiptsByID[id]
    }

    public func isCurrent(_ id: ForgeEvidenceIdentifier) -> Bool {
        receiptsByID[id] != nil && !nonCurrentReceiptIDs.contains(id)
    }

    public func archive() -> ForgeEvidenceLedgerArchive {
        ForgeEvidenceLedgerArchive(
            schemaVersion: Self.archiveSchemaVersion,
            binding: binding,
            ledgerRevision: revision,
            events: events
        )
    }

    private func nextSequence() throws -> UInt64 {
        guard revision < UInt64.max else {
            throw ForgeEvidenceError.invalidLedgerRevision
        }
        return revision + 1
    }

    private static func receiptSort(_ lhs: ForgeEvidenceReceipt, _ rhs: ForgeEvidenceReceipt) -> Bool {
        if lhs.evidenceClass.rawValue != rhs.evidenceClass.rawValue {
            return lhs.evidenceClass.rawValue < rhs.evidenceClass.rawValue
        }
        let lhsSubject = lhs.subjectID?.rawValue ?? ""
        let rhsSubject = rhs.subjectID?.rawValue ?? ""
        if lhsSubject != rhsSubject {
            return lhsSubject < rhsSubject
        }
        return lhs.id < rhs.id
    }

    fileprivate static func replay(
        binding: ForgeEvidenceBinding,
        events: [ForgeEvidenceLedgerEvent]
    ) throws -> ForgeEvidenceLedger {
        var ledger = ForgeEvidenceLedger(binding: binding)
        for (index, event) in events.enumerated() {
            let expected = UInt64(index) + 1
            guard event.sequence == expected else {
                throw ForgeEvidenceError.invalidEventSequence(expected: expected, actual: event.sequence)
            }
            switch event.payload {
            case let .receipt(receipt):
                try ledger.record(receipt)
            case let .revocation(revocation):
                try ledger.revoke(revocation)
            }
        }
        return ledger
    }
}

public struct ForgeEvidenceLedgerArchive: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let binding: ForgeEvidenceBinding
    public let ledgerRevision: UInt64
    public let events: [ForgeEvidenceLedgerEvent]

    fileprivate init(
        schemaVersion: Int,
        binding: ForgeEvidenceBinding,
        ledgerRevision: UInt64,
        events: [ForgeEvidenceLedgerEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.binding = binding
        self.ledgerRevision = ledgerRevision
        self.events = events
    }

    public func validatedLedger() throws -> ForgeEvidenceLedger {
        guard schemaVersion == ForgeEvidenceLedger.archiveSchemaVersion else {
            throw ForgeEvidenceError.invalidSchema(schemaVersion)
        }
        guard ledgerRevision == UInt64(events.count) else {
            throw ForgeEvidenceError.invalidLedgerRevision
        }
        return try ForgeEvidenceLedger.replay(binding: binding, events: events)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case binding
        case ledgerRevision
        case events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let binding = try container.decode(ForgeEvidenceBinding.self, forKey: .binding)
        let ledgerRevision = try container.decode(UInt64.self, forKey: .ledgerRevision)
        let events = try container.decode([ForgeEvidenceLedgerEvent].self, forKey: .events)

        let candidate = ForgeEvidenceLedgerArchive(
            schemaVersion: schemaVersion,
            binding: binding,
            ledgerRevision: ledgerRevision,
            events: events
        )
        _ = try candidate.validatedLedger()
        self = candidate
    }
}
