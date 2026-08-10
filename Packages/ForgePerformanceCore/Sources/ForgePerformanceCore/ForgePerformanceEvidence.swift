import Foundation

public enum ForgePerformanceEvidenceAuthority: String, Codable, CaseIterable, Sendable {
    case hostRuntimeProfiler
    case xctestPerformanceHarness
    case instrumentsHarness
}

public struct ForgePerformanceMetrics: Codable, Equatable, Sendable {
    public let frameSampleCount: Int
    public let p50FrameTimeMilliseconds: Double
    public let p95FrameTimeMilliseconds: Double
    public let p99FrameTimeMilliseconds: Double
    public let maximumFrameTimeMilliseconds: Double
    public let peakResidentMemoryBytes: UInt64?
    public let interactionSampleCount: Int?
    public let interactionP95LatencyMilliseconds: Double?
    public let coldLaunchMilliseconds: Double?

    public init(
        frameSampleCount: Int,
        p50FrameTimeMilliseconds: Double,
        p95FrameTimeMilliseconds: Double,
        p99FrameTimeMilliseconds: Double,
        maximumFrameTimeMilliseconds: Double,
        peakResidentMemoryBytes: UInt64? = nil,
        interactionSampleCount: Int? = nil,
        interactionP95LatencyMilliseconds: Double? = nil,
        coldLaunchMilliseconds: Double? = nil
    ) throws {
        guard (1...1_000_000).contains(frameSampleCount) else { throw ForgePerformanceError.invalidMetric(field: "metrics.frameSampleCount") }
        let p50 = try ForgePerformanceValidation.finiteNonnegative(p50FrameTimeMilliseconds, field: "metrics.p50FrameTimeMilliseconds")
        let p95 = try ForgePerformanceValidation.finiteNonnegative(p95FrameTimeMilliseconds, field: "metrics.p95FrameTimeMilliseconds")
        let p99 = try ForgePerformanceValidation.finiteNonnegative(p99FrameTimeMilliseconds, field: "metrics.p99FrameTimeMilliseconds")
        let maxFrame = try ForgePerformanceValidation.finiteNonnegative(maximumFrameTimeMilliseconds, field: "metrics.maximumFrameTimeMilliseconds")
        guard p50 > 0, p50 <= p95, p95 <= p99, p99 <= maxFrame else { throw ForgePerformanceError.invalidMetric(field: "metrics.framePercentiles") }
        if let peakResidentMemoryBytes, peakResidentMemoryBytes == 0 { throw ForgePerformanceError.invalidMetric(field: "metrics.peakResidentMemoryBytes") }
        if let interactionSampleCount, !(1...1_000_000).contains(interactionSampleCount) { throw ForgePerformanceError.invalidMetric(field: "metrics.interactionSampleCount") }
        let interactionP95 = try interactionP95LatencyMilliseconds.map { try ForgePerformanceValidation.finiteNonnegative($0, field: "metrics.interactionP95LatencyMilliseconds") }
        guard (interactionSampleCount == nil) == (interactionP95LatencyMilliseconds == nil) else { throw ForgePerformanceError.invalidMetric(field: "metrics.interactionPair") }
        let launch = try coldLaunchMilliseconds.map { try ForgePerformanceValidation.finiteNonnegative($0, field: "metrics.coldLaunchMilliseconds") }

        self.frameSampleCount = frameSampleCount
        self.p50FrameTimeMilliseconds = p50
        self.p95FrameTimeMilliseconds = p95
        self.p99FrameTimeMilliseconds = p99
        self.maximumFrameTimeMilliseconds = maxFrame
        self.peakResidentMemoryBytes = peakResidentMemoryBytes
        self.interactionSampleCount = interactionSampleCount
        self.interactionP95LatencyMilliseconds = interactionP95
        self.coldLaunchMilliseconds = launch
    }

    private enum CodingKeys: String, CodingKey {
        case frameSampleCount, p50FrameTimeMilliseconds, p95FrameTimeMilliseconds, p99FrameTimeMilliseconds, maximumFrameTimeMilliseconds
        case peakResidentMemoryBytes, interactionSampleCount, interactionP95LatencyMilliseconds, coldLaunchMilliseconds
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            frameSampleCount: c.decode(Int.self, forKey: .frameSampleCount),
            p50FrameTimeMilliseconds: c.decode(Double.self, forKey: .p50FrameTimeMilliseconds),
            p95FrameTimeMilliseconds: c.decode(Double.self, forKey: .p95FrameTimeMilliseconds),
            p99FrameTimeMilliseconds: c.decode(Double.self, forKey: .p99FrameTimeMilliseconds),
            maximumFrameTimeMilliseconds: c.decode(Double.self, forKey: .maximumFrameTimeMilliseconds),
            peakResidentMemoryBytes: c.decodeIfPresent(UInt64.self, forKey: .peakResidentMemoryBytes),
            interactionSampleCount: c.decodeIfPresent(Int.self, forKey: .interactionSampleCount),
            interactionP95LatencyMilliseconds: c.decodeIfPresent(Double.self, forKey: .interactionP95LatencyMilliseconds),
            coldLaunchMilliseconds: c.decodeIfPresent(Double.self, forKey: .coldLaunchMilliseconds)
        )
    }
}

public struct ForgePerformanceRunEvidence: Codable, Equatable, Sendable {
    public let runID: String
    public let target: ForgePerformanceTarget
    public let policyRevision: String
    public let scenarioID: String
    public let scenarioRevision: String
    public let executionContext: ForgePerformanceExecutionContext
    public let authority: ForgePerformanceEvidenceAuthority
    public let producerReceiptID: String
    public let metrics: ForgePerformanceMetrics

    public init(
        runID: String,
        target: ForgePerformanceTarget,
        policyRevision: String,
        scenarioID: String,
        scenarioRevision: String,
        executionContext: ForgePerformanceExecutionContext,
        authority: ForgePerformanceEvidenceAuthority,
        producerReceiptID: String,
        metrics: ForgePerformanceMetrics
    ) throws {
        self.runID = try ForgePerformanceValidation.identifier(runID, field: "run.runID", maximumLength: 256)
        self.target = target
        self.policyRevision = try ForgePerformanceValidation.identifier(policyRevision, field: "run.policyRevision", maximumLength: 256)
        self.scenarioID = try ForgePerformanceValidation.identifier(scenarioID, field: "run.scenarioID", maximumLength: 256)
        self.scenarioRevision = try ForgePerformanceValidation.identifier(scenarioRevision, field: "run.scenarioRevision", maximumLength: 256)
        self.executionContext = executionContext
        self.authority = authority
        self.producerReceiptID = try ForgePerformanceValidation.identifier(producerReceiptID, field: "run.producerReceiptID", maximumLength: 512)
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey { case runID, target, policyRevision, scenarioID, scenarioRevision, executionContext, authority, producerReceiptID, metrics }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runID: c.decode(String.self, forKey: .runID),
            target: c.decode(ForgePerformanceTarget.self, forKey: .target),
            policyRevision: c.decode(String.self, forKey: .policyRevision),
            scenarioID: c.decode(String.self, forKey: .scenarioID),
            scenarioRevision: c.decode(String.self, forKey: .scenarioRevision),
            executionContext: c.decode(ForgePerformanceExecutionContext.self, forKey: .executionContext),
            authority: c.decode(ForgePerformanceEvidenceAuthority.self, forKey: .authority),
            producerReceiptID: c.decode(String.self, forKey: .producerReceiptID),
            metrics: c.decode(ForgePerformanceMetrics.self, forKey: .metrics)
        )
    }
}

/// Non-Codable host trust for the complete validated producer run. Its initializer is module-internal
/// so persisted/model-authored run bytes cannot mint producer authority merely by copying fields.
public struct ForgePerformanceTrustedProducerReceipt: Equatable, Sendable {
    private let authenticatedRun: ForgePerformanceRunEvidence

    public var producerReceiptID: String { authenticatedRun.producerReceiptID }
    public var runID: String { authenticatedRun.runID }
    public var target: ForgePerformanceTarget { authenticatedRun.target }
    public var executionContext: ForgePerformanceExecutionContext { authenticatedRun.executionContext }

    init(authenticatedRun: ForgePerformanceRunEvidence) {
        self.authenticatedRun = authenticatedRun
    }

    func exactlyMatches(_ run: ForgePerformanceRunEvidence) -> Bool { authenticatedRun == run }
}
