import Foundation

public struct ForgeQualityMeasurement: Codable, Hashable, Sendable {
    public let measurementID: ForgeQualityID
    public let producerReceiptID: ForgeQualityID
    public let binding: ForgeQualityRunBinding
    public let metric: ForgeQualityMetric
    public let scope: ForgeQualityScope
    public let evidenceKind: ForgeQualityEvidenceKind
    public let value: Double
    public let sampleCount: Int

    public init(
        measurementID: ForgeQualityID,
        producerReceiptID: ForgeQualityID,
        binding: ForgeQualityRunBinding,
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
            metric: container.decode(ForgeQualityMetric.self, forKey: .metric),
            scope: container.decode(ForgeQualityScope.self, forKey: .scope),
            evidenceKind: container.decode(ForgeQualityEvidenceKind.self, forKey: .evidenceKind),
            value: container.decode(Double.self, forKey: .value),
            sampleCount: container.decode(Int.self, forKey: .sampleCount)
        )
    }
}

/// Non-Codable exact producer trust subject. A caller cannot promote a persisted/model-shaped
/// `ForgeQualityMeasurement` merely by copying its receipt IDs or authority labels.
public struct ForgeQualityTrustedMeasurement: Equatable, Sendable {
    private let authenticatedMeasurement: ForgeQualityMeasurement

    public var measurementID: ForgeQualityID { authenticatedMeasurement.measurementID }
    public var producerReceiptID: ForgeQualityID { authenticatedMeasurement.producerReceiptID }
    public var binding: ForgeQualityRunBinding { authenticatedMeasurement.binding }
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
