import Foundation

public enum ForgeQualityEvidenceKind: String, Codable, Hashable, Sendable {
    case runtimeTelemetry
    case runtimeDiagnostics
    case interactionHarness
    case accessibilityAudit
}

public enum ForgeQualityComparator: String, Codable, Hashable, Sendable {
    case atMost
    case atLeast

    internal func accepts(value: Double, threshold: Double) -> Bool {
        switch self {
        case .atMost:
            value <= threshold
        case .atLeast:
            value >= threshold
        }
    }
}

public enum ForgeQualityMetric: String, CaseIterable, Codable, Hashable, Sendable {
    case averageFrameTimeMilliseconds
    case p95FrameTimeMilliseconds
    case p99FrameTimeMilliseconds
    case longFrameRatePercent
    case sustainedFramesPerSecond
    case inputLatencyP95Milliseconds
    case peakResidentMemoryMegabytes
    case thermalCriticalEventCount
    case fatalRuntimeErrorCount
    case accessibilityCriticalViolationCount
    case accessibilitySeriousViolationCount
    case clippedInteractiveControlCount

    public var expectedEvidenceKind: ForgeQualityEvidenceKind {
        switch self {
        case .averageFrameTimeMilliseconds,
             .p95FrameTimeMilliseconds,
             .p99FrameTimeMilliseconds,
             .longFrameRatePercent,
             .sustainedFramesPerSecond,
             .peakResidentMemoryMegabytes,
             .thermalCriticalEventCount:
            .runtimeTelemetry
        case .inputLatencyP95Milliseconds:
            .interactionHarness
        case .fatalRuntimeErrorCount:
            .runtimeDiagnostics
        case .accessibilityCriticalViolationCount,
             .accessibilitySeriousViolationCount,
             .clippedInteractiveControlCount:
            .accessibilityAudit
        }
    }

    public var requiredComparator: ForgeQualityComparator {
        switch self {
        case .sustainedFramesPerSecond:
            .atLeast
        default:
            .atMost
        }
    }

    internal func acceptsValue(_ value: Double) -> Bool {
        guard value.isFinite, value >= 0 else { return false }
        switch self {
        case .longFrameRatePercent:
            return value <= 100
        case .thermalCriticalEventCount,
             .fatalRuntimeErrorCount,
             .accessibilityCriticalViolationCount,
             .accessibilitySeriousViolationCount,
             .clippedInteractiveControlCount:
            return value.rounded(.towardZero) == value
        default:
            return true
        }
    }
}

public enum ForgeQualityEnvironmentKind: String, Codable, Hashable, Sendable {
    case simulator
    case physicalDevice
}

public struct ForgeQualityRunBinding: Codable, Hashable, Sendable {
    public let projectID: ForgeQualityID
    public let sourceRevision: ForgeQualityID
    public let checkpointID: ForgeQualityID
    public let runtimeRevision: ForgeQualityID
    public let hostAppBuildID: ForgeQualityID
    public let runID: ForgeQualityID
    public let environmentKind: ForgeQualityEnvironmentKind
    public let deviceProfileID: ForgeQualityID
    public let osBuild: ForgeQualityID

    public init(
        projectID: ForgeQualityID,
        sourceRevision: ForgeQualityID,
        checkpointID: ForgeQualityID,
        runtimeRevision: ForgeQualityID,
        hostAppBuildID: ForgeQualityID,
        runID: ForgeQualityID,
        environmentKind: ForgeQualityEnvironmentKind,
        deviceProfileID: ForgeQualityID,
        osBuild: ForgeQualityID
    ) {
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.checkpointID = checkpointID
        self.runtimeRevision = runtimeRevision
        self.hostAppBuildID = hostAppBuildID
        self.runID = runID
        self.environmentKind = environmentKind
        self.deviceProfileID = deviceProfileID
        self.osBuild = osBuild
    }
}

/// Scope prevents evidence from one autonomous journey from satisfying another journey's budget.
public enum ForgeQualityScope: Codable, Hashable, Sendable {
    case run
    case journey(ForgeQualityID)

    internal var sortKey: String {
        switch self {
        case .run:
            "0:run"
        case let .journey(journeyID):
            "1:\(journeyID.rawValue)"
        }
    }
}

public enum ForgeQualityEnvironmentRequirement: Codable, Hashable, Sendable {
    case any
    case exact(
        kind: ForgeQualityEnvironmentKind,
        deviceProfileID: ForgeQualityID,
        osBuild: ForgeQualityID
    )

    internal func matches(_ binding: ForgeQualityRunBinding) -> Bool {
        switch self {
        case .any:
            true
        case let .exact(kind, deviceProfileID, osBuild):
            binding.environmentKind == kind
                && binding.deviceProfileID == deviceProfileID
                && binding.osBuild == osBuild
        }
    }
}

struct ForgeQualityTargetKey: Hashable {
    let metric: ForgeQualityMetric
    let scope: ForgeQualityScope
}
