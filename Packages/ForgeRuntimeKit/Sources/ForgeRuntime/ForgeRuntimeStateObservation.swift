import Foundation

public enum ForgeRuntimeStateObservationError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidRuntimeVersion
    case invalidStateKey(String)
    case invalidStateValue(String)
    case invalidPredicate(String)
    case emptyExpectations
    case tooManyExpectations(Int)
    case duplicateExpectationID(String)
    case tooManyFields(Int)
    case duplicateFieldKey(String)
    case unsupportedSchema(Int)
}

public struct ForgeRuntimeStateTarget: Codable, Equatable, Hashable, Sendable {
    public let projectID: String
    public let sourceRevision: String
    public let sessionID: String
    public let checkpointID: String
    public let runtimeVersion: ForgeRuntimeVersion

    public init(
        projectID: String,
        sourceRevision: String,
        sessionID: String,
        checkpointID: String,
        runtimeVersion: ForgeRuntimeVersion
    ) throws {
        self.projectID = try Self.validIdentifier(projectID, field: "projectID")
        self.sourceRevision = try Self.validIdentifier(sourceRevision, field: "sourceRevision")
        self.sessionID = try Self.validIdentifier(sessionID, field: "sessionID")
        self.checkpointID = try Self.validIdentifier(checkpointID, field: "checkpointID")
        guard runtimeVersion.major >= 0, runtimeVersion.minor >= 0 else {
            throw ForgeRuntimeStateObservationError.invalidRuntimeVersion
        }
        self.runtimeVersion = runtimeVersion
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, sourceRevision, sessionID, checkpointID, runtimeVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            sessionID: container.decode(String.self, forKey: .sessionID),
            checkpointID: container.decode(String.self, forKey: .checkpointID),
            runtimeVersion: container.decode(ForgeRuntimeVersion.self, forKey: .runtimeVersion)
        )
    }

    fileprivate static func validIdentifier(_ raw: String, field: String) throws -> String {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...128).contains(raw.utf8.count),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeRuntimeStateObservationError.invalidIdentifier(field: field)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:@,+"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ForgeRuntimeStateObservationError.invalidIdentifier(field: field)
        }
        return raw
    }
}

public enum ForgeRuntimeStateValue: Codable, Equatable, Sendable {
    case boolean(Bool)
    case number(Double)
    case text(String)

    fileprivate func validated(field: String) throws -> Self {
        switch self {
        case .boolean:
            return self
        case let .number(value):
            guard value.isFinite else {
                throw ForgeRuntimeStateObservationError.invalidStateValue(field)
            }
            return self
        case let .text(value):
            guard (0...1_024).contains(value.utf8.count),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw ForgeRuntimeStateObservationError.invalidStateValue(field)
            }
            return self
        }
    }
}

public struct ForgeRuntimeStateField: Codable, Equatable, Sendable {
    public let key: String
    public let value: ForgeRuntimeStateValue

    public init(key: String, value: ForgeRuntimeStateValue) throws {
        self.key = try Self.validKey(key)
        self.value = try value.validated(field: key)
    }

    fileprivate static func validKey(_ raw: String) throws -> String {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...96).contains(raw.utf8.count),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeRuntimeStateObservationError.invalidStateKey(raw)
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._:"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ForgeRuntimeStateObservationError.invalidStateKey(raw)
        }
        return raw
    }

    private enum CodingKeys: String, CodingKey { case key, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: container.decode(String.self, forKey: .key),
            value: container.decode(ForgeRuntimeStateValue.self, forKey: .value)
        )
    }
}

public enum ForgeRuntimeStatePredicate: Codable, Equatable, Sendable {
    case equals(ForgeRuntimeStateValue)
    case numberAtLeast(Double)
    case numberAtMost(Double)

    fileprivate func validated(expectationID: String) throws -> Self {
        switch self {
        case let .equals(value):
            _ = try value.validated(field: expectationID)
        case let .numberAtLeast(value), let .numberAtMost(value):
            guard value.isFinite else {
                throw ForgeRuntimeStateObservationError.invalidPredicate(expectationID)
            }
        }
        return self
    }
}

public struct ForgeRuntimeStateExpectation: Codable, Equatable, Sendable {
    public let id: String
    public let fieldKey: String
    public let predicate: ForgeRuntimeStatePredicate

    public init(id: String, fieldKey: String, predicate: ForgeRuntimeStatePredicate) throws {
        self.id = try ForgeRuntimeStateTarget.validIdentifier(id, field: "expectationID")
        self.fieldKey = try ForgeRuntimeStateField.validKey(fieldKey)
        self.predicate = try predicate.validated(expectationID: id)
    }

    private enum CodingKeys: String, CodingKey { case id, fieldKey, predicate }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            fieldKey: container.decode(String.self, forKey: .fieldKey),
            predicate: container.decode(ForgeRuntimeStatePredicate.self, forKey: .predicate)
        )
    }
}

public struct ForgeRuntimeStateRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumExpectations = 64

    public let schemaVersion: Int
    public let requestID: String
    public let target: ForgeRuntimeStateTarget
    public let expectedSnapshotSequence: UInt64
    public let afterDeliveryReceiptID: String?
    public let expectations: [ForgeRuntimeStateExpectation]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        requestID: String,
        target: ForgeRuntimeStateTarget,
        expectedSnapshotSequence: UInt64,
        afterDeliveryReceiptID: String? = nil,
        expectations: [ForgeRuntimeStateExpectation]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeRuntimeStateObservationError.unsupportedSchema(schemaVersion)
        }
        self.requestID = try ForgeRuntimeStateTarget.validIdentifier(requestID, field: "requestID")
        guard !expectations.isEmpty else {
            throw ForgeRuntimeStateObservationError.emptyExpectations
        }
        guard expectations.count <= Self.maximumExpectations else {
            throw ForgeRuntimeStateObservationError.tooManyExpectations(expectations.count)
        }
        var ids = Set<String>()
        for expectation in expectations {
            guard ids.insert(expectation.id).inserted else {
                throw ForgeRuntimeStateObservationError.duplicateExpectationID(expectation.id)
            }
        }
        self.schemaVersion = schemaVersion
        self.target = target
        self.expectedSnapshotSequence = expectedSnapshotSequence
        if let afterDeliveryReceiptID {
            self.afterDeliveryReceiptID = try ForgeRuntimeStateTarget.validIdentifier(
                afterDeliveryReceiptID,
                field: "afterDeliveryReceiptID"
            )
        } else {
            self.afterDeliveryReceiptID = nil
        }
        self.expectations = expectations.sorted { $0.id < $1.id }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, requestID, target, expectedSnapshotSequence, afterDeliveryReceiptID, expectations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            requestID: container.decode(String.self, forKey: .requestID),
            target: container.decode(ForgeRuntimeStateTarget.self, forKey: .target),
            expectedSnapshotSequence: container.decode(UInt64.self, forKey: .expectedSnapshotSequence),
            afterDeliveryReceiptID: container.decodeIfPresent(String.self, forKey: .afterDeliveryReceiptID),
            expectations: container.decode([ForgeRuntimeStateExpectation].self, forKey: .expectations)
        )
    }
}

/// Producer identity carried by candidate state data. This enum labels a report; it does not
/// authenticate who actually produced the snapshot.
public enum ForgeRuntimeStateReportedProducer: String, Codable, Equatable, Sendable {
    case runtimeBridge
    case hostTestHarness
}

/// Structurally validated state reported by a runtime-side or test-side producer.
///
/// This value is public and Codable by design, so it is always candidate data. Neither
/// `reportedProducer` nor `reportedProducerReceiptID` can authorize the snapshot. A later host
/// adapter must authenticate the complete snapshot subject before downstream Playtest/Completion
/// can promote it to accepted evidence.
public struct ForgeRuntimeStateSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumFields = 128

    public let schemaVersion: Int
    public let snapshotID: String
    public let requestID: String
    public let target: ForgeRuntimeStateTarget
    public let sequence: UInt64
    public let reportedProducer: ForgeRuntimeStateReportedProducer
    public let reportedProducerReceiptID: String
    public let causalDeliveryReceiptID: String?
    public let fields: [ForgeRuntimeStateField]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        snapshotID: String,
        requestID: String,
        target: ForgeRuntimeStateTarget,
        sequence: UInt64,
        reportedProducer: ForgeRuntimeStateReportedProducer,
        reportedProducerReceiptID: String,
        causalDeliveryReceiptID: String? = nil,
        fields: [ForgeRuntimeStateField]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeRuntimeStateObservationError.unsupportedSchema(schemaVersion)
        }
        self.snapshotID = try ForgeRuntimeStateTarget.validIdentifier(snapshotID, field: "snapshotID")
        self.requestID = try ForgeRuntimeStateTarget.validIdentifier(requestID, field: "requestID")
        self.reportedProducerReceiptID = try ForgeRuntimeStateTarget.validIdentifier(
            reportedProducerReceiptID,
            field: "reportedProducerReceiptID"
        )
        if let causalDeliveryReceiptID {
            self.causalDeliveryReceiptID = try ForgeRuntimeStateTarget.validIdentifier(
                causalDeliveryReceiptID,
                field: "causalDeliveryReceiptID"
            )
        } else {
            self.causalDeliveryReceiptID = nil
        }
        guard fields.count <= Self.maximumFields else {
            throw ForgeRuntimeStateObservationError.tooManyFields(fields.count)
        }
        var keys = Set<String>()
        for field in fields {
            guard keys.insert(field.key).inserted else {
                throw ForgeRuntimeStateObservationError.duplicateFieldKey(field.key)
            }
        }
        self.schemaVersion = schemaVersion
        self.target = target
        self.sequence = sequence
        self.reportedProducer = reportedProducer
        self.fields = fields.sorted { $0.key < $1.key }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, snapshotID, requestID, target, sequence, reportedProducer, reportedProducerReceiptID
        case causalDeliveryReceiptID, fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            snapshotID: container.decode(String.self, forKey: .snapshotID),
            requestID: container.decode(String.self, forKey: .requestID),
            target: container.decode(ForgeRuntimeStateTarget.self, forKey: .target),
            sequence: container.decode(UInt64.self, forKey: .sequence),
            reportedProducer: container.decode(ForgeRuntimeStateReportedProducer.self, forKey: .reportedProducer),
            reportedProducerReceiptID: container.decode(String.self, forKey: .reportedProducerReceiptID),
            causalDeliveryReceiptID: container.decodeIfPresent(String.self, forKey: .causalDeliveryReceiptID),
            fields: container.decode([ForgeRuntimeStateField].self, forKey: .fields)
        )
    }
}

public enum ForgeRuntimeStateCandidateBlocker: Equatable, Sendable {
    case requestMismatch
    case targetMismatch
    case sequenceMismatch
    case causalReceiptMismatch
    case unexpectedField(String)
    case missingField(expectationID: String, fieldKey: String)
    case typeMismatch(expectationID: String, fieldKey: String)
    case predicateNotSatisfied(expectationID: String, fieldKey: String)
}

public enum ForgeRuntimeStateCandidateVerdict: String, Equatable, Sendable {
    case satisfied
    case blocked
}

/// Fresh structural evaluation of caller/producer-reported state.
///
/// `satisfied` means only that the candidate snapshot matches the requested identity and predicates.
/// It is intentionally non-Codable and carries no trusted receipt or acceptance status. Persist the
/// request/snapshot inputs and require a canonical host-authenticated complete-subject binding before
/// any downstream component treats the state as evidence of real runtime behavior.
public struct ForgeRuntimeStateCandidateEvaluation: Equatable, Sendable {
    public let verdict: ForgeRuntimeStateCandidateVerdict
    public let blockers: [ForgeRuntimeStateCandidateBlocker]

    public var isSatisfied: Bool { verdict == .satisfied }
}

public enum ForgeRuntimeStateCandidateEvaluator {
    public static func evaluate(
        request: ForgeRuntimeStateRequest,
        snapshot: ForgeRuntimeStateSnapshot
    ) -> ForgeRuntimeStateCandidateEvaluation {
        guard request.requestID == snapshot.requestID else {
            return blocked(.requestMismatch)
        }
        guard request.target == snapshot.target else {
            return blocked(.targetMismatch)
        }
        guard request.expectedSnapshotSequence == snapshot.sequence else {
            return blocked(.sequenceMismatch)
        }
        guard request.afterDeliveryReceiptID == snapshot.causalDeliveryReceiptID else {
            return blocked(.causalReceiptMismatch)
        }

        let expectedKeys = Set(request.expectations.map(\.fieldKey))
        if let unexpected = snapshot.fields.map(\.key).first(where: { !expectedKeys.contains($0) }) {
            return blocked(.unexpectedField(unexpected))
        }

        let fields = Dictionary(uniqueKeysWithValues: snapshot.fields.map { ($0.key, $0.value) })
        var blockers: [ForgeRuntimeStateCandidateBlocker] = []
        for expectation in request.expectations {
            guard let actual = fields[expectation.fieldKey] else {
                blockers.append(.missingField(expectationID: expectation.id, fieldKey: expectation.fieldKey))
                continue
            }
            switch compare(actual, predicate: expectation.predicate) {
            case .satisfied:
                break
            case .typeMismatch:
                blockers.append(.typeMismatch(expectationID: expectation.id, fieldKey: expectation.fieldKey))
            case .notSatisfied:
                blockers.append(.predicateNotSatisfied(expectationID: expectation.id, fieldKey: expectation.fieldKey))
            }
        }

        return ForgeRuntimeStateCandidateEvaluation(
            verdict: blockers.isEmpty ? .satisfied : .blocked,
            blockers: blockers
        )
    }

    private enum Comparison {
        case satisfied
        case typeMismatch
        case notSatisfied
    }

    private static func compare(
        _ actual: ForgeRuntimeStateValue,
        predicate: ForgeRuntimeStatePredicate
    ) -> Comparison {
        switch predicate {
        case let .equals(expected):
            return actual == expected ? .satisfied : .notSatisfied
        case let .numberAtLeast(threshold):
            guard case let .number(value) = actual else { return .typeMismatch }
            return value >= threshold ? .satisfied : .notSatisfied
        case let .numberAtMost(threshold):
            guard case let .number(value) = actual else { return .typeMismatch }
            return value <= threshold ? .satisfied : .notSatisfied
        }
    }

    private static func blocked(_ blocker: ForgeRuntimeStateCandidateBlocker) -> ForgeRuntimeStateCandidateEvaluation {
        ForgeRuntimeStateCandidateEvaluation(verdict: .blocked, blockers: [blocker])
    }
}
