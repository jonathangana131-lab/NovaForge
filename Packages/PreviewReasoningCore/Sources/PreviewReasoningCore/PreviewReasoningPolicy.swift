import Foundation

/// The stable product-level reasoning scale for the NovaForge Preview.
///
/// Provider-specific effort values are implementation details. These cases are
/// ordered by user intent and must remain the five public stops exposed by the
/// Preview: Low -> Medium -> High -> Extra High -> Ultra.
public enum PreviewReasoningLevel: String, CaseIterable, Codable, Sendable {
    case low
    case medium
    case high
    case extraHigh
    case ultra

    public var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .extraHigh: "Extra High"
        case .ultra: "Ultra"
        }
    }

    public var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        case .extraHigh: 3
        case .ultra: 4
        }
    }
}

public enum PreviewReasoningOrchestration: String, Codable, Sendable {
    case focused
    case reviewed
    case parallelReview
    case isolatedParallelReview
}

public enum PreviewReasoningContextDepth: String, Codable, Sendable {
    case compact
    case balanced
    case deep
    case maximumUseful
}

public enum PreviewReasoningVerification: String, Codable, Sendable {
    case normal
    case strict
    case strictest
}

/// Relative execution requirements for one Preview reasoning level.
///
/// These values intentionally describe orchestration and verification behavior,
/// not tokens, RAM, latency, or device performance. Runtime adapters still own
/// exact provider/device qualification and may fail closed when a requirement
/// cannot be satisfied.
public struct PreviewReasoningProfile: Equatable, Codable, Sendable {
    public let level: PreviewReasoningLevel
    public let orchestration: PreviewReasoningOrchestration
    public let contextDepth: PreviewReasoningContextDepth
    public let verification: PreviewReasoningVerification
    public let verifierPasses: UInt8
    public let requiresMaximumAvailableReasoning: Bool
    public let requiresIsolatedWorkspaces: Bool

    public init(level: PreviewReasoningLevel) {
        self.level = level
        switch level {
        case .low:
            orchestration = .focused
            contextDepth = .compact
            verification = .normal
            verifierPasses = 0
            requiresMaximumAvailableReasoning = false
            requiresIsolatedWorkspaces = false
        case .medium:
            orchestration = .focused
            contextDepth = .balanced
            verification = .normal
            verifierPasses = 0
            requiresMaximumAvailableReasoning = false
            requiresIsolatedWorkspaces = false
        case .high:
            orchestration = .reviewed
            contextDepth = .deep
            verification = .strict
            verifierPasses = 1
            requiresMaximumAvailableReasoning = false
            requiresIsolatedWorkspaces = false
        case .extraHigh:
            orchestration = .parallelReview
            contextDepth = .deep
            verification = .strict
            verifierPasses = 1
            requiresMaximumAvailableReasoning = false
            requiresIsolatedWorkspaces = false
        case .ultra:
            orchestration = .isolatedParallelReview
            contextDepth = .maximumUseful
            verification = .strictest
            verifierPasses = 2
            requiresMaximumAvailableReasoning = true
            requiresIsolatedWorkspaces = true
        }
    }
}

/// Compatibility-only vocabulary for the Preview's pre-V14 saved settings.
/// The bridge preserves old user intent without exposing these names as the new
/// product scale.
public struct LegacyPreviewReasoningSelection: Equatable, Sendable {
    public enum Effort: String, Sendable {
        case none
        case low
        case medium
        case high
        case xhigh
        case max
    }

    public enum Orchestration: String, Sendable {
        case standard
        case ultra
        case ultraCode
    }

    public let effort: Effort
    public let orchestration: Orchestration

    public init(effort: Effort, orchestration: Orchestration) {
        self.effort = effort
        self.orchestration = orchestration
    }

    /// Canonicalizes legacy settings onto the five public Preview levels.
    /// Both legacy Ultra variants preserve strongest-mode intent.
    public var canonicalLevel: PreviewReasoningLevel {
        switch orchestration {
        case .ultra, .ultraCode:
            return .ultra
        case .standard:
            return switch effort {
            case .none, .low: .low
            case .medium: .medium
            case .high: .high
            case .xhigh, .max: .extraHigh
            }
        }
    }
}
