import Foundation

public enum ProviderToolDispatchState: String, Codable, Hashable, Sendable {
    /// The failed attempt did not dispatch any tool.
    case none
    /// Only read-only tools completed and their results are durably recorded.
    case readOnlyConfirmed
    /// At least one mutating or externally side-effecting tool was dispatched.
    case mutatingConfirmed
    /// Dispatch may have crossed the effect boundary, but completion is not known.
    case ambiguous
}

public enum ProviderOutputCommitState: String, Codable, Hashable, Sendable {
    /// Attempt-scoped output exists only in a discardable provisional buffer.
    case provisional
    /// No output from the failed attempt has been exposed or persisted.
    case none
    /// Output from the failed attempt was durably committed or exposed as final.
    case committed
}

public struct ProviderReplaySafety: Codable, Equatable, Sendable {
    public let outputCommitState: ProviderOutputCommitState
    public let toolDispatchState: ProviderToolDispatchState

    public init(
        outputCommitState: ProviderOutputCommitState = .none,
        toolDispatchState: ProviderToolDispatchState = .none
    ) {
        self.outputCommitState = outputCommitState
        self.toolDispatchState = toolDispatchState
    }

    public static let uncommitted = ProviderReplaySafety()
}

public struct ProviderRecoveryPolicy: Codable, Equatable, Sendable {
    public let maximumAttemptsPerRoute: UInt32
    public let maximumFallbacks: UInt32
    public let baseBackoffMilliseconds: UInt64
    public let maximumBackoffMilliseconds: UInt64
    public let jitterBasisPoints: UInt16
    public let allowReplayAfterReadOnlyDispatch: Bool

    public init(
        maximumAttemptsPerRoute: UInt32 = 3,
        maximumFallbacks: UInt32 = 2,
        baseBackoffMilliseconds: UInt64 = 500,
        maximumBackoffMilliseconds: UInt64 = 30_000,
        jitterBasisPoints: UInt16 = 1_000,
        allowReplayAfterReadOnlyDispatch: Bool = true
    ) {
        self.maximumAttemptsPerRoute = maximumAttemptsPerRoute
        self.maximumFallbacks = maximumFallbacks
        self.baseBackoffMilliseconds = baseBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.jitterBasisPoints = min(jitterBasisPoints, 10_000)
        self.allowReplayAfterReadOnlyDispatch = allowReplayAfterReadOnlyDispatch
    }

    public static let hermesBaseline = ProviderRecoveryPolicy()
}

public struct ProviderRecoveryContext: Codable, Equatable, Sendable {
    public let currentRoute: ProviderRoute
    /// Ordered by host preference. The current route may be present and will be ignored.
    public let fallbackRoutes: [ProviderRoute]
    public let requiredCapabilities: ProviderCapabilitySet
    /// One-based count of attempts already made on the current route.
    public let attemptOnCurrentRoute: UInt32
    public let fallbacksAlreadyUsed: UInt32
    public let failure: ProviderFailure
    public let outputCommitState: ProviderOutputCommitState
    public let toolDispatchState: ProviderToolDispatchState
    /// Stable seed recorded with the attempt, never wall-clock randomness.
    public let deterministicSeed: UInt64

    public init(
        currentRoute: ProviderRoute,
        fallbackRoutes: [ProviderRoute],
        requiredCapabilities: ProviderCapabilitySet,
        attemptOnCurrentRoute: UInt32,
        fallbacksAlreadyUsed: UInt32,
        failure: ProviderFailure,
        outputCommitState: ProviderOutputCommitState = .none,
        toolDispatchState: ProviderToolDispatchState,
        deterministicSeed: UInt64
    ) {
        self.currentRoute = currentRoute
        self.fallbackRoutes = fallbackRoutes
        self.requiredCapabilities = requiredCapabilities
        self.attemptOnCurrentRoute = attemptOnCurrentRoute
        self.fallbacksAlreadyUsed = fallbacksAlreadyUsed
        self.failure = failure
        self.outputCommitState = outputCommitState
        self.toolDispatchState = toolDispatchState
        self.deterministicSeed = deterministicSeed
    }
}

public enum ProviderRecoveryStopReason: String, Codable, Hashable, Sendable {
    case cancelled
    case outputAlreadyCommitted
    case sideEffectsMayHaveOccurred
    case nonRecoverableFailure
    case attemptsExhausted
    case fallbacksExhausted
    case noCompatibleFallback
}

public enum ProviderRecoveryDecision: Codable, Equatable, Sendable {
    case retrySameRoute(afterMilliseconds: UInt64)
    case fallback(to: ProviderRoute, afterMilliseconds: UInt64)
    case stop(ProviderRecoveryStopReason)

    private enum CodingKeys: String, CodingKey { case kind, route, delay, reason }
    private enum Kind: String, Codable { case retrySameRoute, fallback, stop }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .retrySameRoute:
            self = .retrySameRoute(afterMilliseconds: try container.decode(UInt64.self, forKey: .delay))
        case .fallback:
            self = .fallback(
                to: try container.decode(ProviderRoute.self, forKey: .route),
                afterMilliseconds: try container.decode(UInt64.self, forKey: .delay)
            )
        case .stop:
            self = .stop(try container.decode(ProviderRecoveryStopReason.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .retrySameRoute(delay):
            try container.encode(Kind.retrySameRoute, forKey: .kind)
            try container.encode(delay, forKey: .delay)
        case let .fallback(route, delay):
            try container.encode(Kind.fallback, forKey: .kind)
            try container.encode(route, forKey: .route)
            try container.encode(delay, forKey: .delay)
        case let .stop(reason):
            try container.encode(Kind.stop, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// Pure replay/fallback policy. Its inputs and decision can be persisted verbatim.
public enum ProviderRecoveryPlanner {
    public static func decide(
        context: ProviderRecoveryContext,
        policy: ProviderRecoveryPolicy = .hermesBaseline
    ) -> ProviderRecoveryDecision {
        if context.failure.category == .cancelled {
            return .stop(.cancelled)
        }

        if context.outputCommitState == .committed {
            return .stop(.outputAlreadyCommitted)
        }

        switch context.toolDispatchState {
        case .mutatingConfirmed, .ambiguous:
            // Replaying either the same provider or a fallback could duplicate an effect.
            return .stop(.sideEffectsMayHaveOccurred)
        case .readOnlyConfirmed where !policy.allowReplayAfterReadOnlyDispatch:
            return .stop(.sideEffectsMayHaveOccurred)
        case .none, .readOnlyConfirmed:
            break
        }

        let delay = deterministicBackoff(
            attempt: context.attemptOnCurrentRoute,
            seed: context.deterministicSeed,
            providerDelay: context.failure.retryAfterMilliseconds,
            policy: policy
        )

        if context.failure.retryableOnSameRoute,
           context.attemptOnCurrentRoute < policy.maximumAttemptsPerRoute {
            return .retrySameRoute(afterMilliseconds: delay)
        }

        guard context.failure.recoverableByFallback else {
            return .stop(.nonRecoverableFailure)
        }
        guard context.fallbacksAlreadyUsed < policy.maximumFallbacks else {
            return .stop(.fallbacksExhausted)
        }

        let route = context.fallbackRoutes.first { candidate in
            (candidate.providerID != context.currentRoute.providerID ||
                candidate.modelID != context.currentRoute.modelID ||
                candidate.adapterID != context.currentRoute.adapterID) &&
                candidate.capabilities.features.isSuperset(of: context.requiredCapabilities)
        }

        guard let route else {
            return .stop(.noCompatibleFallback)
        }
        return .fallback(to: route, afterMilliseconds: delay)
    }

    public static func deterministicBackoff(
        attempt: UInt32,
        seed: UInt64,
        providerDelay: UInt64?,
        policy: ProviderRecoveryPolicy = .hermesBaseline
    ) -> UInt64 {
        let shift = min(attempt > 0 ? attempt - 1 : 0, 62)
        let exponential: UInt64
        if policy.baseBackoffMilliseconds > (UInt64.max >> shift) {
            exponential = policy.maximumBackoffMilliseconds
        } else {
            exponential = min(
                policy.baseBackoffMilliseconds << shift,
                policy.maximumBackoffMilliseconds
            )
        }

        let span = multipliedDivided(
            exponential,
            UInt64(policy.jitterBasisPoints),
            10_000
        )
        let lower = exponential >= span ? exponential - span : 0
        let width = span > (UInt64.max - 1) / 2 ? UInt64.max : span * 2 + 1
        let sample = width == 0 ? 0 : mixed(seed ^ UInt64(attempt)) % width
        let jittered = lower.addingReportingOverflow(sample).overflow
            ? policy.maximumBackoffMilliseconds
            : min(lower + sample, policy.maximumBackoffMilliseconds)

        // Retry-After is authoritative and may intentionally exceed the local backoff cap.
        return max(jittered, providerDelay ?? 0)
    }

    private static func mixed(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private static func multipliedDivided(_ lhs: UInt64, _ rhs: UInt64, _ divisor: UInt64) -> UInt64 {
        let product = lhs.multipliedFullWidth(by: rhs)
        return divisor.dividingFullWidth(product).quotient
    }
}
