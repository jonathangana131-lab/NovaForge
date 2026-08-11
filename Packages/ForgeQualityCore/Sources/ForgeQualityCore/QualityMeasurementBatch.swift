import Foundation

/// Durable candidate for one producer's coherent measurement batch.
///
/// The batch binds every observation to one exact run, measurement protocol, and producer receipt.
/// Persisted bytes remain candidate data only; acceptance requires the non-Codable trusted subject
/// below so a copied receipt cannot authenticate altered or fragmented observations.
public struct ForgeQualityMeasurementBatch: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumMeasurements = 64

    public let schemaVersion: Int
    public let producerReceiptID: ForgeQualityID
    public let binding: ForgeQualityRunBinding
    public let measurementProtocol: ForgeQualityMeasurementProtocolIdentity
    public let measurements: [ForgeQualityMeasurement]

    public init(measurements: [ForgeQualityMeasurement]) throws {
        guard !measurements.isEmpty else {
            throw ForgeQualityError.emptyMeasurementBatch
        }
        guard measurements.count <= Self.maximumMeasurements else {
            throw ForgeQualityError.tooManyMeasurementsInBatch
        }

        let first = measurements[0]
        var seenMeasurementIDs = Set<ForgeQualityID>()
        var seenTargets = Set<ForgeQualityTargetKey>()

        for measurement in measurements {
            guard measurement.binding == first.binding else {
                throw ForgeQualityError.mixedMeasurementBatchBinding
            }
            guard measurement.measurementProtocol == first.measurementProtocol else {
                throw ForgeQualityError.mixedMeasurementBatchProtocol
            }
            guard measurement.producerReceiptID == first.producerReceiptID else {
                throw ForgeQualityError.mixedMeasurementBatchProducerReceipt
            }
            guard seenMeasurementIDs.insert(measurement.measurementID).inserted else {
                throw ForgeQualityError.duplicateMeasurementID(measurement.measurementID)
            }
            guard seenTargets.insert(measurement.key).inserted else {
                throw ForgeQualityError.duplicateMeasurement(
                    metric: measurement.metric,
                    scope: measurement.scope
                )
            }
        }

        try Self.validateFrameStatisticCoherence(measurements)

        schemaVersion = Self.currentSchemaVersion
        producerReceiptID = first.producerReceiptID
        binding = first.binding
        measurementProtocol = first.measurementProtocol
        self.measurements = measurements.sorted { lhs, rhs in
            if lhs.scope.sortKey == rhs.scope.sortKey {
                return lhs.metric.rawValue < rhs.metric.rawValue
            }
            return lhs.scope.sortKey < rhs.scope.sortKey
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case producerReceiptID
        case binding
        case measurementProtocol
        case measurements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeQualityError.unsupportedSchemaVersion(schemaVersion)
        }

        let decodedProducerReceiptID = try container.decode(
            ForgeQualityID.self,
            forKey: .producerReceiptID
        )
        let decodedBinding = try container.decode(
            ForgeQualityRunBinding.self,
            forKey: .binding
        )
        let decodedProtocol = try container.decode(
            ForgeQualityMeasurementProtocolIdentity.self,
            forKey: .measurementProtocol
        )
        let decodedMeasurements = try container.decode(
            [ForgeQualityMeasurement].self,
            forKey: .measurements
        )
        let validated = try Self(measurements: decodedMeasurements)

        guard validated.producerReceiptID == decodedProducerReceiptID else {
            throw ForgeQualityError.mixedMeasurementBatchProducerReceipt
        }
        guard validated.binding == decodedBinding else {
            throw ForgeQualityError.mixedMeasurementBatchBinding
        }
        guard validated.measurementProtocol == decodedProtocol else {
            throw ForgeQualityError.mixedMeasurementBatchProtocol
        }

        self = validated
    }

    private static func validateFrameStatisticCoherence(
        _ measurements: [ForgeQualityMeasurement]
    ) throws {
        let grouped = Dictionary(grouping: measurements) { $0.scope }

        for (scope, scopedMeasurements) in grouped {
            let frameStatistics = scopedMeasurements.filter {
                switch $0.metric {
                case .averageFrameTimeMilliseconds,
                     .p95FrameTimeMilliseconds,
                     .p99FrameTimeMilliseconds:
                    true
                default:
                    false
                }
            }

            guard frameStatistics.count > 1 else { continue }
            guard Set(frameStatistics.map(\.sampleCount)).count == 1 else {
                throw ForgeQualityError.incoherentMeasurementSet(scope: scope)
            }

            let byMetric = Dictionary(uniqueKeysWithValues: frameStatistics.map { ($0.metric, $0) })
            if let p95 = byMetric[.p95FrameTimeMilliseconds],
               let p99 = byMetric[.p99FrameTimeMilliseconds],
               p95.value > p99.value {
                throw ForgeQualityError.incoherentMeasurementSet(scope: scope)
            }
        }
    }
}

/// Non-Codable host trust over the complete validated producer batch.
/// The initializer is module-internal so a persisted batch or copied receipt cannot mint authority.
public struct ForgeQualityTrustedMeasurementBatch: Equatable, Sendable {
    private let authenticatedBatch: ForgeQualityMeasurementBatch

    public var producerReceiptID: ForgeQualityID { authenticatedBatch.producerReceiptID }
    public var binding: ForgeQualityRunBinding { authenticatedBatch.binding }
    public var measurementProtocol: ForgeQualityMeasurementProtocolIdentity {
        authenticatedBatch.measurementProtocol
    }
    public var measurements: [ForgeQualityMeasurement] { authenticatedBatch.measurements }

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
