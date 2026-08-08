import Foundation

public struct VisualFramePerformanceSample: Codable, Equatable, Hashable, Sendable {
    public let frameOrdinal: UInt64
    public let frameDurationMilliseconds: Double
    public let dropped: Bool

    public init(frameOrdinal: UInt64, frameDurationMilliseconds: Double, dropped: Bool) throws {
        guard frameDurationMilliseconds.isFinite, frameDurationMilliseconds > 0 else {
            throw VisualAcceptanceEvidenceError.invalidPerformanceSample
        }
        self.frameOrdinal = frameOrdinal
        self.frameDurationMilliseconds = frameDurationMilliseconds
        self.dropped = dropped
    }

    private enum CodingKeys: String, CodingKey { case frameOrdinal, frameDurationMilliseconds, dropped }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            frameOrdinal: values.decode(UInt64.self, forKey: .frameOrdinal),
            frameDurationMilliseconds: values.decode(Double.self, forKey: .frameDurationMilliseconds),
            dropped: values.decode(Bool.self, forKey: .dropped)
        )
    }
}

public struct VisualFramePerformanceSummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let averageFrameDurationMilliseconds: Double
    public let p95FrameDurationMilliseconds: Double
    public let worstFrameDurationMilliseconds: Double
    public let droppedFrameRatio: Double
}

public struct VisualPerformanceReceipt: Codable, Equatable, Sendable, Identifiable {
    public static let maximumSamples = 20_000

    public let id: UUID
    public let capture: VisualCaptureReceipt
    public let environment: VisualExecutionEnvironmentIdentity
    public let samples: [VisualFramePerformanceSample]
    public let summary: VisualFramePerformanceSummary

    public init(
        id: UUID = UUID(),
        capture: VisualCaptureReceipt,
        environment: VisualExecutionEnvironmentIdentity,
        samples: [VisualFramePerformanceSample]
    ) throws {
        guard VisualAccessibilityReceipt.validRuntimeCapture(capture), capture.evidenceKind == .runtimeFrameSequence else {
            throw VisualAcceptanceEvidenceError.invalidRuntimeCapture
        }
        guard !samples.isEmpty, samples.count <= Self.maximumSamples else {
            throw VisualAcceptanceEvidenceError.tooManyPerformanceSamples
        }
        var previous: UInt64?
        for sample in samples {
            guard sample.frameDurationMilliseconds.isFinite, sample.frameDurationMilliseconds > 0 else {
                throw VisualAcceptanceEvidenceError.invalidPerformanceSample
            }
            if let previous, sample.frameOrdinal <= previous {
                throw VisualAcceptanceEvidenceError.duplicateOrUnorderedFrameOrdinal
            }
            previous = sample.frameOrdinal
        }
        self.id = id
        self.capture = capture
        self.environment = environment
        self.samples = samples
        self.summary = try Self.makeSummary(samples)
    }

    private static func makeSummary(_ samples: [VisualFramePerformanceSample]) throws -> VisualFramePerformanceSummary {
        var total = 0.0
        for sample in samples {
            total += sample.frameDurationMilliseconds
            guard total.isFinite else { throw VisualAcceptanceEvidenceError.invalidPerformanceSample }
        }
        let sorted = samples.map(\.frameDurationMilliseconds).sorted()
        let p95Index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1))
        let droppedCount = samples.reduce(into: 0) { if $1.dropped { $0 += 1 } }
        return VisualFramePerformanceSummary(
            sampleCount: samples.count,
            averageFrameDurationMilliseconds: total / Double(samples.count),
            p95FrameDurationMilliseconds: sorted[p95Index],
            worstFrameDurationMilliseconds: sorted[sorted.count - 1],
            droppedFrameRatio: Double(droppedCount) / Double(samples.count)
        )
    }

    private enum CodingKeys: String, CodingKey { case id, capture, environment, samples, summary }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSummary = try values.decode(VisualFramePerformanceSummary.self, forKey: .summary)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            capture: values.decode(VisualCaptureReceipt.self, forKey: .capture),
            environment: values.decode(VisualExecutionEnvironmentIdentity.self, forKey: .environment),
            samples: values.decode([VisualFramePerformanceSample].self, forKey: .samples)
        )
        guard summary == decodedSummary else { throw VisualAcceptanceEvidenceError.invalidPerformanceSample }
    }
}

public struct VisualPerformanceAcceptancePolicy: Codable, Equatable, Sendable {
    public let minimumSampleCount: Int
    public let maximumP95FrameDurationMilliseconds: Double
    public let maximumWorstFrameDurationMilliseconds: Double
    public let maximumDroppedFrameRatio: Double
    public let requiresPhysicalDevice: Bool

    public init(
        minimumSampleCount: Int,
        maximumP95FrameDurationMilliseconds: Double,
        maximumWorstFrameDurationMilliseconds: Double,
        maximumDroppedFrameRatio: Double,
        requiresPhysicalDevice: Bool = false
    ) throws {
        guard minimumSampleCount > 0, minimumSampleCount <= VisualPerformanceReceipt.maximumSamples,
              maximumP95FrameDurationMilliseconds.isFinite, maximumP95FrameDurationMilliseconds > 0,
              maximumWorstFrameDurationMilliseconds.isFinite,
              maximumWorstFrameDurationMilliseconds >= maximumP95FrameDurationMilliseconds,
              maximumDroppedFrameRatio.isFinite,
              (0 ... 1).contains(maximumDroppedFrameRatio) else {
            throw VisualAcceptanceEvidenceError.invalidPerformancePolicy
        }
        self.minimumSampleCount = minimumSampleCount
        self.maximumP95FrameDurationMilliseconds = maximumP95FrameDurationMilliseconds
        self.maximumWorstFrameDurationMilliseconds = maximumWorstFrameDurationMilliseconds
        self.maximumDroppedFrameRatio = maximumDroppedFrameRatio
        self.requiresPhysicalDevice = requiresPhysicalDevice
    }

    private enum CodingKeys: String, CodingKey {
        case minimumSampleCount, maximumP95FrameDurationMilliseconds, maximumWorstFrameDurationMilliseconds
        case maximumDroppedFrameRatio, requiresPhysicalDevice
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minimumSampleCount: values.decode(Int.self, forKey: .minimumSampleCount),
            maximumP95FrameDurationMilliseconds: values.decode(Double.self, forKey: .maximumP95FrameDurationMilliseconds),
            maximumWorstFrameDurationMilliseconds: values.decode(Double.self, forKey: .maximumWorstFrameDurationMilliseconds),
            maximumDroppedFrameRatio: values.decode(Double.self, forKey: .maximumDroppedFrameRatio),
            requiresPhysicalDevice: values.decode(Bool.self, forKey: .requiresPhysicalDevice)
        )
    }
}

public enum VisualPerformanceAcceptanceBlocker: Equatable, Sendable {
    case physicalDeviceRequired
    case insufficientSamples(actual: Int, required: Int)
    case p95Exceeded(actual: Double, maximum: Double)
    case worstFrameExceeded(actual: Double, maximum: Double)
    case droppedFrameRatioExceeded(actual: Double, maximum: Double)
}

public enum VisualPerformanceAcceptanceVerdict: Equatable, Sendable {
    case accepted(receiptID: UUID, summary: VisualFramePerformanceSummary)
    case blocked([VisualPerformanceAcceptanceBlocker])
}

public enum VisualPerformanceEvidenceEvaluator {
    public static func evaluate(
        receipt: VisualPerformanceReceipt,
        policy: VisualPerformanceAcceptancePolicy
    ) -> VisualPerformanceAcceptanceVerdict {
        var blockers: [VisualPerformanceAcceptanceBlocker] = []
        let summary = receipt.summary
        if policy.requiresPhysicalDevice && receipt.environment.kind != .physicalDevice {
            blockers.append(.physicalDeviceRequired)
        }
        if summary.sampleCount < policy.minimumSampleCount {
            blockers.append(.insufficientSamples(actual: summary.sampleCount, required: policy.minimumSampleCount))
        }
        if summary.p95FrameDurationMilliseconds > policy.maximumP95FrameDurationMilliseconds {
            blockers.append(.p95Exceeded(actual: summary.p95FrameDurationMilliseconds, maximum: policy.maximumP95FrameDurationMilliseconds))
        }
        if summary.worstFrameDurationMilliseconds > policy.maximumWorstFrameDurationMilliseconds {
            blockers.append(.worstFrameExceeded(actual: summary.worstFrameDurationMilliseconds, maximum: policy.maximumWorstFrameDurationMilliseconds))
        }
        if summary.droppedFrameRatio > policy.maximumDroppedFrameRatio {
            blockers.append(.droppedFrameRatioExceeded(actual: summary.droppedFrameRatio, maximum: policy.maximumDroppedFrameRatio))
        }
        return blockers.isEmpty ? .accepted(receiptID: receipt.id, summary: summary) : .blocked(blockers)
    }
}
