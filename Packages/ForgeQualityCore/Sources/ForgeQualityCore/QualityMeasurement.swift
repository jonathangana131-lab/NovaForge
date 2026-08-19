import Foundation

public struct ForgeQualityMeasurement: Codable, Hashable, Sendable {
    public let measurementID: ForgeQualityID
    public let producerReceiptID: ForgeQualityID
    public let binding: ForgeQualityRunBinding
    public let measurementProtocol: ForgeQualityMeasurementProtocolIdentity
    public let metric: ForgeQualityMetric
    public let scope: ForgeQualityScope
    public let evidenceKind: ForgeQualityEvidenceKind
    public let value: Double
    public let sampleCount: Int

    public init(
        measurementID: ForgeQualityID,
        producerReceiptID: ForgeQualityID,
        binding: ForgeQualityRunBinding,
        measurementProtocol: ForgeQualityMeasurementProtocolIdentity,
        metric: ForgeQualityMetric,
        scope: ForgeQualityScope = .run,
        evidenceKind: ForgeQualityEvidenceKind,
        value: Double,
        sampleCount: Int
    ) throws {
        guard metric.acceptsValue(value) else {
            throw ForgeQualityError.invalidMeasurement(metric)
        }
        guard (1...10_000_000).contains(sampleCount) else {
            throw ForgeQualityError.invalidSampleCount
        }
        guard evidenceKind == metric.expectedEvidenceKind else {
            throw ForgeQualityError.evidenceKindMismatch(
                metric: metric,
                expected: metric.expectedEvidenceKind,
                actual: evidenceKind
            )
        }
        self.measurementID = measurementID
        self.producerReceiptID = producerReceiptID
        self.binding = binding
        self.measurementProtocol = measurementProtocol
        self.metric = metric
        self.scope = scope
        self.evidenceKind = evidenceKind
        self.value = value
        self.sampleCount = sampleCount
    }

    internal var key: ForgeQualityTargetKey {
        ForgeQualityTargetKey(metric: metric, scope: scope)
    }

    private enum CodingKeys: String, CodingKey {
        case measurementID
        case producerReceiptID
        case binding
        case measurementProtocol
        case metric
        case scope
        case evidenceKind
        case value
        case sampleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            measurementID: container.decode(ForgeQualityID.self, forKey: .measurementID),
            producerReceiptID: container.decode(ForgeQualityID.self, forKey: .producerReceiptID),
            binding: container.decode(ForgeQualityRunBinding.self, forKey: .binding),
            measurementProtocol: container.decode(ForgeQualityMeasurementProtocolIdentity.self, forKey: .measurementProtocol),
            metric: container.decode(ForgeQualityMetric.self, forKey: .metric),
            scope: container.decode(ForgeQualityScope.self, forKey: .scope),
            evidenceKind: container.decode(ForgeQualityEvidenceKind.self, forKey: .evidenceKind),
            value: container.decode(Double.self, forKey: .value),
            sampleCount: container.decode(Int.self, forKey: .sampleCount)
        )
    }
}

/// Legacy package-internal compatibility subject for deterministic unit tests and future producer
/// adapter construction. Public acceptance no longer consumes an array of these independently.
public struct ForgeQualityTrustedMeasurement: Equatable, Sendable {
    private let authenticatedMeasurement: ForgeQualityMeasurement

    public var measurementID: ForgeQualityID { authenticatedMeasurement.measurementID }
    public var producerReceiptID: ForgeQualityID { authenticatedMeasurement.producerReceiptID }
    public var binding: ForgeQualityRunBinding { authenticatedMeasurement.binding }
    public var measurementProtocol: ForgeQualityMeasurementProtocolIdentity { authenticatedMeasurement.measurementProtocol }
    public var metric: ForgeQualityMetric { authenticatedMeasurement.metric }
    public var scope: ForgeQualityScope { authenticatedMeasurement.scope }
    public var evidenceKind: ForgeQualityEvidenceKind { authenticatedMeasurement.evidenceKind }
    public var value: Double { authenticatedMeasurement.value }
    public var sampleCount: Int { authenticatedMeasurement.sampleCount }

    init(authenticatedMeasurement: ForgeQualityMeasurement) {
        self.authenticatedMeasurement = authenticatedMeasurement
    }

    func exactlyMatches(_ candidate: ForgeQualityMeasurement) -> Bool {
        authenticatedMeasurement == candidate
    }

    internal var candidate: ForgeQualityMeasurement {
        authenticatedMeasurement
    }
}

/// Candidate whole-run quality evidence. One batch is the indivisible producer subject for one exact
/// run + measurement-protocol revision. Individual producer receipt IDs may repeat because one
/// canonical profiler/audit receipt can legitimately attest multiple metric observations.
public struct ForgeQualityMeasurementBatch: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumMeasurements = 256

    public let schemaVersion: Int
    public let batchReceiptID: ForgeQualityID
    public let binding: ForgeQualityRunBinding
    public let measurementProtocol: ForgeQualityMeasurementProtocolIdentity
    public let measurements: [ForgeQualityMeasurement]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        batchReceiptID: ForgeQualityID,
        binding: ForgeQualityRunBinding,
        measurementProtocol: ForgeQualityMeasurementProtocolIdentity,
        measurements: [ForgeQualityMeasurement]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeQualityError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !measurements.isEmpty else {
            throw ForgeQualityError.emptyMeasurementBatch
        }
        guard measurements.count <= Self.maximumMeasurements else {
            throw ForgeQualityError.tooManyMeasurements
        }

        var measurementIDs = Set<ForgeQualityID>()
        var targetKeys = Set<ForgeQualityTargetKey>()
        for measurement in measurements {
            guard measurement.binding == binding else {
                throw ForgeQualityError.measurementBatchBindingMismatch
            }
            guard measurement.measurementProtocol == measurementProtocol else {
                throw ForgeQualityError.measurementBatchProtocolMismatch
            }
            guard measurementIDs.insert(measurement.measurementID).inserted else {
                throw ForgeQualityError.duplicateMeasurementID(measurement.measurementID)
            }
            guard targetKeys.insert(measurement.key).inserted else {
                throw ForgeQualityError.duplicateMeasurement(
                    metric: measurement.metric,
                    scope: measurement.scope
                )
            }
        }

        self.schemaVersion = schemaVersion
        self.batchReceiptID = batchReceiptID
        self.binding = binding
        self.measurementProtocol = measurementProtocol
        self.measurements = measurements.sorted { lhs, rhs in
            if lhs.scope.sortKey == rhs.scope.sortKey {
                if lhs.metric.rawValue == rhs.metric.rawValue {
                    return lhs.measurementID < rhs.measurementID
                }
                return lhs.metric.rawValue < rhs.metric.rawValue
            }
            return lhs.scope.sortKey < rhs.scope.sortKey
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case batchReceiptID
        case binding
        case measurementProtocol
        case measurements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            batchReceiptID: container.decode(ForgeQualityID.self, forKey: .batchReceiptID),
            binding: container.decode(ForgeQualityRunBinding.self, forKey: .binding),
            measurementProtocol: container.decode(ForgeQualityMeasurementProtocolIdentity.self, forKey: .measurementProtocol),
            measurements: container.decode([ForgeQualityMeasurement].self, forKey: .measurements)
        )
    }
}

/// Non-Codable producer trust over the complete validated batch. A future canonical runtime/
/// accessibility adapter inside this module must mint this only after authenticating the whole batch;
/// an ordinary caller cannot combine independently trusted-looking scalar observations into acceptance.
public struct ForgeQualityTrustedMeasurementBatch: Equatable, Sendable {
    private let authenticatedBatch: ForgeQualityMeasurementBatch

    public var batchReceiptID: ForgeQualityID { authenticatedBatch.batchReceiptID }
    public var binding: ForgeQualityRunBinding { authenticatedBatch.binding }
    public var measurementProtocol: ForgeQualityMeasurementProtocolIdentity { authenticatedBatch.measurementProtocol }

    init(authenticatedBatch: ForgeQualityMeasurementBatch) {
        self.authenticatedBatch = authenticatedBatch
    }

    func exactlyMatches(_ candidate: ForgeQualityMeasurementBatch) -> Bool {
        authenticatedBatch == candidate
    }

    internal var candidate: ForgeQualityMeasurementBatch {
        authenticatedBatch
    }
}
