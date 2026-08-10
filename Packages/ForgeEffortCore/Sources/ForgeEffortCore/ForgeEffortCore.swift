import Foundation

/// A user-facing request for how much thinking and verification NovaForge should spend.
///
/// Effort is deliberately separate from Build Depth. Build Depth describes how complete
/// the product mission should become; Effort describes how hard NovaForge should work on
/// each bounded decision/implementation step.
public enum ForgeEffortLevel: String, CaseIterable, Codable, Comparable, Hashable, Sendable {
    case fast
    case balanced
    case deep
    case ultra

    public static func < (lhs: Self, rhs: Self) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs)
        else { return lhs.rawValue < rhs.rawValue }
        return left < right
    }

    public var displayName: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .deep: "Deep"
        case .ultra: "Ultra"
        }
    }
}

public enum ForgeEffortIntentError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

/// Durable user intent only. This does not authorize a provider, model, route, or spend.
public struct ForgeEffortIntent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let level: ForgeEffortLevel

    public init(level: ForgeEffortLevel = .balanced) {
        schemaVersion = Self.currentSchemaVersion
        self.level = level
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case level
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeEffortIntentError.unsupportedSchemaVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        level = try container.decode(ForgeEffortLevel.self, forKey: .level)
    }
}

/// Provider-neutral native reasoning vocabulary. Raw values intentionally match the
/// canonical AgentProviders reasoning-effort tokens so a later adapter can be lossless.
///
/// This type is not support authority. `ForgeEffortCore` never infers support from a model
/// family/name and never treats this value as permission to dispatch a request.
public enum ForgeNativeReasoningEffort: String, CaseIterable, Codable, Comparable, Hashable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    public static func < (lhs: Self, rhs: Self) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs)
        else { return lhs.rawValue < rhs.rawValue }
        return left < right
    }
}

/// Explicit native reasoning levels supplied by a canonical route/model qualification layer.
/// Empty means unavailable or unknown and therefore fails closed to NovaForge host work only.
public struct ForgeNativeReasoningSupport: Equatable, Sendable {
    public let supportedEfforts: [ForgeNativeReasoningEffort]

    public init(_ efforts: some Sequence<ForgeNativeReasoningEffort>) {
        supportedEfforts = Array(Set(efforts)).sorted()
    }

    public static let unavailable = Self([])

    public func strongestNotExceeding(
        _ requested: ForgeNativeReasoningEffort
    ) -> ForgeNativeReasoningEffort? {
        supportedEfforts.last(where: { $0 <= requested })
    }
}

public enum ForgeEffortRetrievalDepth: String, Codable, Comparable, Hashable, Sendable {
    case focused
    case standard
    case broad
    case maximumRelevant

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let rank: [Self: Int] = [
            .focused: 0,
            .standard: 1,
            .broad: 2,
            .maximumRelevant: 3,
        ]
        return rank[lhs, default: 0] < rank[rhs, default: 0]
    }
}

public enum ForgeEffortVerificationDepth: String, Codable, Comparable, Hashable, Sendable {
    case essential
    case standard
    case expanded
    case adversarial

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let rank: [Self: Int] = [
            .essential: 0,
            .standard: 1,
            .expanded: 2,
            .adversarial: 3,
        ]
        return rank[lhs, default: 0] < rank[rhs, default: 0]
    }
}

/// Deterministic host-owned work amplification. Counts are planning/review budgets, not
/// promises that a mission is complete and not evidence that any provider performed work.
public struct ForgeEffortHostStrategy: Codable, Equatable, Sendable {
    public let planningPasses: UInt8
    public let reviewerPasses: UInt8
    public let retrievalDepth: ForgeEffortRetrievalDepth
    public let verificationDepth: ForgeEffortVerificationDepth
    public let visualCritiquePasses: UInt8
    public let repairLoopBudget: UInt8

    public init(
        planningPasses: UInt8,
        reviewerPasses: UInt8,
        retrievalDepth: ForgeEffortRetrievalDepth,
        verificationDepth: ForgeEffortVerificationDepth,
        visualCritiquePasses: UInt8,
        repairLoopBudget: UInt8
    ) {
        self.planningPasses = planningPasses
        self.reviewerPasses = reviewerPasses
        self.retrievalDepth = retrievalDepth
        self.verificationDepth = verificationDepth
        self.visualCritiquePasses = visualCritiquePasses
        self.repairLoopBudget = repairLoopBudget
    }
}

public struct ForgeEffortResolution: Equatable, Sendable {
    public let requestedLevel: ForgeEffortLevel
    public let hostStrategy: ForgeEffortHostStrategy
    public let nativeReasoningEffort: ForgeNativeReasoningEffort?

    public var usesNativeReasoning: Bool { nativeReasoningEffort != nil }

    public init(
        requestedLevel: ForgeEffortLevel,
        hostStrategy: ForgeEffortHostStrategy,
        nativeReasoningEffort: ForgeNativeReasoningEffort?
    ) {
        self.requestedLevel = requestedLevel
        self.hostStrategy = hostStrategy
        self.nativeReasoningEffort = nativeReasoningEffort
    }
}

/// Resolves a friendly effort level without pretending every provider/model implements the
/// same native reasoning controls. Native projection uses only explicitly supplied support
/// and never substitutes a stronger level than the user requested.
public enum ForgeEffortResolver {
    public static func resolve(
        _ intent: ForgeEffortIntent,
        nativeSupport: ForgeNativeReasoningSupport = .unavailable
    ) -> ForgeEffortResolution {
        let desiredNative = desiredNativeEffort(for: intent.level)
        return ForgeEffortResolution(
            requestedLevel: intent.level,
            hostStrategy: hostStrategy(for: intent.level),
            nativeReasoningEffort: nativeSupport.strongestNotExceeding(desiredNative)
        )
    }

    public static func hostStrategy(for level: ForgeEffortLevel) -> ForgeEffortHostStrategy {
        switch level {
        case .fast:
            ForgeEffortHostStrategy(
                planningPasses: 1,
                reviewerPasses: 0,
                retrievalDepth: .focused,
                verificationDepth: .essential,
                visualCritiquePasses: 0,
                repairLoopBudget: 1
            )
        case .balanced:
            ForgeEffortHostStrategy(
                planningPasses: 1,
                reviewerPasses: 1,
                retrievalDepth: .standard,
                verificationDepth: .standard,
                visualCritiquePasses: 1,
                repairLoopBudget: 2
            )
        case .deep:
            ForgeEffortHostStrategy(
                planningPasses: 2,
                reviewerPasses: 1,
                retrievalDepth: .broad,
                verificationDepth: .expanded,
                visualCritiquePasses: 2,
                repairLoopBudget: 4
            )
        case .ultra:
            ForgeEffortHostStrategy(
                planningPasses: 3,
                reviewerPasses: 2,
                retrievalDepth: .maximumRelevant,
                verificationDepth: .adversarial,
                visualCritiquePasses: 3,
                repairLoopBudget: 8
            )
        }
    }

    public static func desiredNativeEffort(
        for level: ForgeEffortLevel
    ) -> ForgeNativeReasoningEffort {
        switch level {
        case .fast: .low
        case .balanced: .medium
        case .deep: .high
        case .ultra: .max
        }
    }
}
