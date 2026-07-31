import AgentDomain
import CryptoKit
import Foundation

/// Credential and base-URL ownership remains outside the harness. A transport
/// receives only the adapter's credential-free envelope and route metadata.
public protocol ProviderTransport: Sendable {
    /// Performs one wire request only. Implementations must not retry, follow a
    /// provider redirect, or switch endpoints internally; V2 persists every
    /// retry/fallback as a new caller-owned attempt scope.
    func stream(
        request: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error>
}

/// Durable identity handed to the engine before one provider transport call.
/// Prompt/tool content is represented only by a canonical digest so the
/// journal barrier does not need to retain a second plaintext request copy.
public enum ProviderRequestDigestValidationError: Error, Equatable, Sendable {
    case invalidFormat(String)
}

public struct ProviderRequestDigest:
    Codable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == 71,
              rawValue.hasPrefix("sha256:"),
              rawValue.utf8.dropFirst(7).allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              })
        else { throw ProviderRequestDigestValidationError.invalidFormat(rawValue) }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct ProviderAttemptDispatch: Codable, Equatable, Sendable {
    public let scope: ProviderAttemptScope
    public let route: ProviderRoute
    public let method: ProviderHTTPMethod
    public let relativePath: String
    public let requestSHA256: ProviderRequestDigest

    init(
        scope: ProviderAttemptScope,
        route: ProviderRoute,
        method: ProviderHTTPMethod,
        relativePath: String,
        requestSHA256: ProviderRequestDigest
    ) {
        self.scope = scope
        self.route = route
        self.method = method
        self.relativePath = relativePath
        self.requestSHA256 = requestSHA256
    }

    /// Lossless credential-free bridge into the canonical v1.1 journal.
    public func journalMetadata(
        ordinal: UInt32,
        recoverySeed: UInt64
    ) throws -> ProviderAttemptJournalMetadata {
        .recordedV1_1(
            requestDigest: try AgentCanonicalSHA256Digest(
                requestSHA256.rawValue
            ),
            scope: try ProviderAttemptScopeReference(
                requestID: scope.requestID,
                attemptID: scope.attemptID.rawValue
            ),
            ordinal: ordinal,
            recoverySeed: recoverySeed
        )
    }
}

/// The V2 engine implements this by atomically claiming the exact scope plus
/// request digest and committing `modelRequestStarted`. It must reject a reused
/// scope and return only after the append is durable. Transport is never called
/// when the barrier throws or the task is cancelled before it returns.
public protocol ProviderAttemptDispatchBarrier: Sendable {
    func beforeDispatch(_ attempt: ProviderAttemptDispatch) async throws
}

public struct ProviderSingleAttemptInvocation: Sendable {
    public let request: CanonicalProviderRequest
    public let adapterID: ProviderAdapterID
    public let scope: ProviderAttemptScope
    public let barrier: any ProviderAttemptDispatchBarrier

    public init(
        request: CanonicalProviderRequest,
        adapterID: ProviderAdapterID,
        scope: ProviderAttemptScope,
        barrier: any ProviderAttemptDispatchBarrier
    ) {
        self.request = request
        self.adapterID = adapterID
        self.scope = scope
        self.barrier = barrier
    }
}

public struct ProviderGatewayInvocation: Sendable {
    public let request: CanonicalProviderRequest
    public let preferredAdapterIDs: [ProviderAdapterID]
    public let recoveryPolicy: ProviderRecoveryPolicy
    public let replaySafety: ProviderReplaySafety
    public let deterministicSeed: UInt64

    public init(
        request: CanonicalProviderRequest,
        preferredAdapterIDs: [ProviderAdapterID],
        recoveryPolicy: ProviderRecoveryPolicy = .hermesBaseline,
        replaySafety: ProviderReplaySafety = .uncommitted,
        deterministicSeed: UInt64
    ) {
        self.request = request
        self.preferredAdapterIDs = preferredAdapterIDs
        self.recoveryPolicy = recoveryPolicy
        self.replaySafety = replaySafety
        self.deterministicSeed = deterministicSeed
    }
}

public struct ProviderGatewayAttemptRecord: Codable, Equatable, Sendable {
    public let scope: ProviderAttemptScope
    public let route: ProviderRoute
    public let committed: Bool
    public let eventCount: UInt64
    public let observedUsage: ProviderUsage?
    public let failure: ProviderFailure?

    public init(
        scope: ProviderAttemptScope,
        route: ProviderRoute,
        committed: Bool,
        eventCount: UInt64,
        observedUsage: ProviderUsage?,
        failure: ProviderFailure?
    ) {
        self.scope = scope
        self.route = route
        self.committed = committed
        self.eventCount = eventCount
        self.observedUsage = observedUsage
        self.failure = failure
    }
}

public struct ProviderGatewayAttemptStart: Codable, Equatable, Sendable {
    public let scope: ProviderAttemptScope
    public let route: ProviderRoute

    public init(scope: ProviderAttemptScope, route: ProviderRoute) {
        self.scope = scope
        self.route = route
    }
}

public struct ProviderGatewayRetrySchedule: Codable, Equatable, Sendable {
    public let discardedScope: ProviderAttemptScope
    public let route: ProviderRoute
    public let afterMilliseconds: UInt64

    public init(discardedScope: ProviderAttemptScope, route: ProviderRoute, afterMilliseconds: UInt64) {
        self.discardedScope = discardedScope
        self.route = route
        self.afterMilliseconds = afterMilliseconds
    }
}

public struct ProviderGatewayFallbackSchedule: Codable, Equatable, Sendable {
    public let discardedScope: ProviderAttemptScope
    public let fromRoute: ProviderRoute
    public let toRoute: ProviderRoute
    public let afterMilliseconds: UInt64

    public init(
        discardedScope: ProviderAttemptScope,
        fromRoute: ProviderRoute,
        toRoute: ProviderRoute,
        afterMilliseconds: UInt64
    ) {
        self.discardedScope = discardedScope
        self.fromRoute = fromRoute
        self.toRoute = toRoute
        self.afterMilliseconds = afterMilliseconds
    }
}

public struct ProviderGatewayAttemptCommit: Codable, Equatable, Sendable {
    public let record: ProviderGatewayAttemptRecord
    public let finishReason: ModelFinishReason

    public init(record: ProviderGatewayAttemptRecord, finishReason: ModelFinishReason) {
        self.record = record
        self.finishReason = finishReason
    }
}

/// Live gateway contract. `provisional` values may be rendered immediately,
/// but are never final until the exact same scope receives `attemptCommitted`.
/// `attemptDiscarded` requires consumers to remove that scope atomically.
public enum ProviderGatewayStreamEvent: Codable, Equatable, Sendable {
    case attemptStarted(ProviderGatewayAttemptStart)
    case provisional(ProviderAttemptEvent)
    case attemptDiscarded(ProviderGatewayAttemptRecord)
    case retryScheduled(ProviderGatewayRetrySchedule)
    case fallbackScheduled(ProviderGatewayFallbackSchedule)
    case attemptCommitted(ProviderGatewayAttemptCommit)
}

public struct ProviderGatewayResult: Codable, Equatable, Sendable {
    public let committedScope: ProviderAttemptScope
    public let route: ProviderRoute
    /// Events from the winning attempt only. Failed-attempt content is never
    /// present in this result or in attempt diagnostics.
    public let events: [ProviderAttemptEvent]
    public let usage: ProviderUsage?
    public let finishReason: ModelFinishReason
    public let attempts: [ProviderGatewayAttemptRecord]

    public init(
        committedScope: ProviderAttemptScope,
        route: ProviderRoute,
        events: [ProviderAttemptEvent],
        usage: ProviderUsage?,
        finishReason: ModelFinishReason,
        attempts: [ProviderGatewayAttemptRecord]
    ) {
        self.committedScope = committedScope
        self.route = route
        self.events = events
        self.usage = usage
        self.finishReason = finishReason
        self.attempts = attempts
    }
}

public struct ProviderGatewayFailure: Error, Codable, Equatable, Sendable {
    public let cause: ProviderFailure
    public let stopReason: ProviderRecoveryStopReason
    public let attempts: [ProviderGatewayAttemptRecord]

    public init(
        cause: ProviderFailure,
        stopReason: ProviderRecoveryStopReason,
        attempts: [ProviderGatewayAttemptRecord]
    ) {
        self.cause = cause
        self.stopReason = stopReason
        self.attempts = attempts
    }
}

public enum ProviderGatewayContractFailure: Error, Equatable, Sendable {
    case streamEndedWithoutCommit
    case invalidAttemptScope
    case requestScopeMismatch
    case invalidEncodedRequestPath
    case encodedRequestPathMismatch
    case adapterDescriptorChanged
    case duplicateAttemptScope
    case attemptScopeCapacityExceeded
    case adapterSessionMismatch
    case consumerBackpressureExceeded
    case requestBudgetExceeded
    case encodedRequestBudgetExceeded
}

/// Provider-neutral, attempt-isolated generation gateway. Live consumers get
/// provisional events immediately and an explicit scope commit/discard marker;
/// collector consumers can use `generate` for an atomically committed result.
public actor ModelGateway {
    private static let maximumBufferedStreamEvents = 256
    private static let maximumActiveAttemptScopes = 1_024
    private static let maximumRecentAttemptScopes = 4_096

    private let catalog: ProviderAdapterCatalog
    private let transport: any ProviderTransport
    /// Process-local defense in depth. Active scopes are retained until their
    /// transport drains; completed scopes use a bounded FIFO. The durable
    /// barrier remains the authoritative dedupe across eviction and restart.
    private var activeAttemptScopes: Set<ProviderAttemptScope> = []
    private var recentAttemptScopes: Set<ProviderAttemptScope> = []
    private var recentAttemptScopeOrder: [ProviderAttemptScope] = []
    private var recentAttemptScopeCursor = 0

    public init(catalog: ProviderAdapterCatalog, transport: any ProviderTransport) {
        self.catalog = catalog
        self.transport = transport
    }

    /// Deterministic route negotiation for an engine that persists its own
    /// retry/fallback plan. No transport work is performed.
    public func negotiateRoutes(
        preferredAdapterIDs: [ProviderAdapterID],
        requirements: ProviderCapabilityRequirements
    ) throws -> [ProviderRoute] {
        try catalog.negotiate(
            preferredAdapterIDs: preferredAdapterIDs,
            requirements: requirements
        ).map(\.descriptor.route)
    }

    /// Executes exactly one caller-identified wire attempt. This primitive has
    /// no retry, fallback, backoff, attempt counter, or hidden route selection;
    /// V2 persists and owns all of those decisions in AgentEngine.
    public func streamAttempt(
        _ invocation: ProviderSingleAttemptInvocation
    ) -> AsyncThrowingStream<ProviderAttemptEvent, any Error> {
        AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedStreamEvents)
        ) { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: ProviderGatewayContractFailure.streamEndedWithoutCommit)
                    return
                }
                do {
                    try await self.runSingleAttempt(invocation, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func stream(
        _ invocation: ProviderGatewayInvocation
    ) -> AsyncThrowingStream<ProviderGatewayStreamEvent, any Error> {
        AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(Self.maximumBufferedStreamEvents)
        ) { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish(throwing: ProviderGatewayContractFailure.streamEndedWithoutCommit)
                    return
                }
                do {
                    try await self.runStreaming(invocation, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Convenience collector that commits only the scope named by the live
    /// stream's `attemptCommitted` boundary.
    func generate(_ invocation: ProviderGatewayInvocation) async throws -> ProviderGatewayResult {
        let live = stream(invocation)
        var buffers: [ProviderAttemptScope: [ProviderAttemptEvent]] = [:]
        var records: [ProviderGatewayAttemptRecord] = []
        var result: ProviderGatewayResult?

        for try await event in live {
            switch event {
            case let .attemptStarted(start):
                buffers[start.scope] = []
            case let .provisional(event):
                buffers[event.scope, default: []].append(event)
            case let .attemptDiscarded(record):
                records.append(record)
                buffers.removeValue(forKey: record.scope)
            case .retryScheduled, .fallbackScheduled:
                break
            case let .attemptCommitted(commit):
                records.append(commit.record)
                let events = buffers.removeValue(forKey: commit.record.scope) ?? []
                result = ProviderGatewayResult(
                    committedScope: commit.record.scope,
                    route: commit.record.route,
                    events: events,
                    usage: commit.record.observedUsage,
                    finishReason: commit.finishReason,
                    attempts: records
                )
            }
        }

        guard let result else { throw ProviderGatewayContractFailure.streamEndedWithoutCommit }
        return result
    }

    private func runStreaming(
        _ invocation: ProviderGatewayInvocation,
        continuation: AsyncThrowingStream<ProviderGatewayStreamEvent, any Error>.Continuation
    ) async throws {
        try Self.requireCanonicalRequestBudget(invocation.request)
        let candidates = try catalog.negotiate(
            preferredAdapterIDs: invocation.preferredAdapterIDs,
            requirements: invocation.request.capabilityRequirements
        )
        var current = candidates[0]
        var usedAdapterIDs: Set<ProviderAdapterID> = [current.descriptor.route.adapterID]
        var attemptOnCurrentRoute: UInt32 = 1
        var fallbacksUsed: UInt32 = 0
        var globalAttempt: UInt64 = 1
        var records: [ProviderGatewayAttemptRecord] = []

        while true {
            try Task.checkCancellation()
            let scope = ProviderAttemptScope(
                requestID: invocation.request.requestID,
                attemptID: ProviderAttemptID(
                    rawValue: "\(invocation.request.requestID):provider-attempt:\(globalAttempt)"
                )
            )
            let descriptor = current.descriptor
            let route = descriptor.route
            try Self.yield(
                .attemptStarted(.init(scope: scope, route: route)),
                to: continuation
            )
            let routedRequest = invocation.request.routed(to: route.modelID)
            var provisional: [ProviderAttemptEvent] = []
            var observedUsage: ProviderUsage?

            do {
                let encoded = try current.encode(routedRequest)
                try Self.requireEncodedRequestBudget(encoded)
                guard Self.isSafeRelativePath(encoded.relativePath) else {
                    throw ProviderGatewayContractFailure.invalidEncodedRequestPath
                }
                guard encoded.relativePath == descriptor.requestPath else {
                    throw ProviderGatewayContractFailure.encodedRequestPathMismatch
                }
                guard current.descriptor == descriptor else {
                    throw ProviderGatewayContractFailure.adapterDescriptorChanged
                }
                var session = ProviderStreamSession(
                    descriptor: descriptor,
                    scope: scope,
                    request: routedRequest
                )
                let frames = try await transport.stream(
                    request: encoded,
                    descriptor: descriptor,
                    scope: scope
                )
                for try await frame in frames {
                    try Task.checkCancellation()
                    let translated = try session.receive(frame)
                    for event in translated {
                        provisional.append(event)
                        if case let .usage(usage) = event.event { observedUsage = usage }
                        if case .cancelled = event.event {
                            throw ProviderFailureMapper.cancellation(
                                providerID: route.providerID,
                                adapterID: route.adapterID
                            )
                        }
                        try Self.yield(.provisional(event), to: continuation)
                    }
                }
                let tail = try session.finish()
                for event in tail {
                    provisional.append(event)
                    if case let .usage(usage) = event.event { observedUsage = usage }
                    if case .cancelled = event.event {
                        throw ProviderFailureMapper.cancellation(
                            providerID: route.providerID,
                            adapterID: route.adapterID
                        )
                    }
                    try Self.yield(.provisional(event), to: continuation)
                }
                guard let finishReason = provisional.finishReason else {
                    throw ProviderFailure(
                        category: .protocolViolation,
                        code: "provider_attempt_missing_terminal_event",
                        publicMessage: "The provider stream violated the adapter contract.",
                        providerID: route.providerID,
                        adapterID: route.adapterID
                    )
                }

                let record = ProviderGatewayAttemptRecord(
                    scope: scope,
                    route: route,
                    committed: true,
                    eventCount: UInt64(provisional.count),
                    observedUsage: observedUsage,
                    failure: nil
                )
                records.append(record)
                try Self.yield(
                    .attemptCommitted(.init(record: record, finishReason: finishReason)),
                    to: continuation
                )
                return
            } catch {
                if error is CancellationError { throw error }
                if let contract = error as? ProviderGatewayContractFailure { throw contract }
                let failure = Self.sanitizeFailure(error, descriptor: descriptor)
                let record = ProviderGatewayAttemptRecord(
                    scope: scope,
                    route: route,
                    committed: false,
                    eventCount: UInt64(provisional.count),
                    observedUsage: observedUsage,
                    failure: failure
                )
                records.append(record)
                try Self.yield(.attemptDiscarded(record), to: continuation)

                let remainingFallbacks = candidates
                    .map(\.descriptor.route)
                    .filter { !usedAdapterIDs.contains($0.adapterID) }
                let outputState: ProviderOutputCommitState
                if invocation.replaySafety.outputCommitState == .committed {
                    outputState = .committed
                } else if provisional.isEmpty {
                    outputState = invocation.replaySafety.outputCommitState
                } else {
                    outputState = .provisional
                }
                let decision = ProviderRecoveryPlanner.decide(
                    context: ProviderRecoveryContext(
                        currentRoute: route,
                        fallbackRoutes: remainingFallbacks,
                        requiredCapabilities: invocation.request.requiredCapabilities,
                        attemptOnCurrentRoute: attemptOnCurrentRoute,
                        fallbacksAlreadyUsed: fallbacksUsed,
                        failure: failure,
                        outputCommitState: outputState,
                        toolDispatchState: invocation.replaySafety.toolDispatchState,
                        deterministicSeed: invocation.deterministicSeed ^ globalAttempt
                    ),
                    policy: invocation.recoveryPolicy
                )

                switch decision {
                case let .retrySameRoute(delay):
                    try Self.yield(.retryScheduled(.init(
                        discardedScope: scope,
                        route: route,
                        afterMilliseconds: delay
                    )), to: continuation)
                    try await Self.delay(milliseconds: delay)
                    attemptOnCurrentRoute &+= 1
                case let .fallback(nextRoute, delay):
                    try Self.yield(.fallbackScheduled(.init(
                        discardedScope: scope,
                        fromRoute: route,
                        toRoute: nextRoute,
                        afterMilliseconds: delay
                    )), to: continuation)
                    try await Self.delay(milliseconds: delay)
                    current = try catalog.adapter(id: nextRoute.adapterID)
                    usedAdapterIDs.insert(nextRoute.adapterID)
                    fallbacksUsed &+= 1
                    attemptOnCurrentRoute = 1
                case let .stop(reason):
                    throw ProviderGatewayFailure(cause: failure, stopReason: reason, attempts: records)
                }
                globalAttempt &+= 1
            }
        }
    }

    private func runSingleAttempt(
        _ invocation: ProviderSingleAttemptInvocation,
        continuation: AsyncThrowingStream<ProviderAttemptEvent, any Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        try Self.requireCanonicalRequestBudget(invocation.request)
        guard invocation.scope.requestID == invocation.request.requestID else {
            throw ProviderGatewayContractFailure.requestScopeMismatch
        }
        guard Self.isSafeAttemptIdentity(invocation.scope.requestID),
              Self.isSafeAttemptIdentity(invocation.scope.attemptID.rawValue)
        else {
            throw ProviderGatewayContractFailure.invalidAttemptScope
        }
        let adapter = try catalog.adapter(id: invocation.adapterID)
        let descriptor = adapter.descriptor
        guard descriptor.route.adapterID == invocation.adapterID else {
            throw ProviderGatewayContractFailure.adapterDescriptorChanged
        }
        let route = descriptor.route
        let routedRequest = invocation.request.routed(to: route.modelID)
        let encoded = try adapter.encode(routedRequest)
        try Self.requireEncodedRequestBudget(encoded)
        guard Self.isSafeRelativePath(encoded.relativePath) else {
            throw ProviderGatewayContractFailure.invalidEncodedRequestPath
        }
        guard encoded.relativePath == descriptor.requestPath else {
            throw ProviderGatewayContractFailure.encodedRequestPathMismatch
        }
        var session = ProviderStreamSession(
            descriptor: descriptor,
            scope: invocation.scope,
            request: routedRequest
        )
        guard adapter.descriptor == descriptor else {
            throw ProviderGatewayContractFailure.adapterDescriptorChanged
        }
        guard session.descriptor == descriptor,
              session.scope == invocation.scope
        else { throw ProviderGatewayContractFailure.adapterSessionMismatch }
        let dispatch = try Self.makeDispatch(
            scope: invocation.scope,
            route: route,
            encoded: encoded
        )

        // This await is the durability boundary. Keep it outside provider
        // failure sanitization so a journal failure remains distinguishable
        // and, critically, transport has not run yet.
        try await invocation.barrier.beforeDispatch(dispatch)
        try claimProcessLocalScope(invocation.scope)
        defer { releaseProcessLocalScope(invocation.scope) }
        try Task.checkCancellation()

        do {
            let frames = try await transport.stream(
                request: encoded,
                descriptor: descriptor,
                scope: invocation.scope
            )
            var terminal: ProviderAttemptEvent?

            for try await frame in frames {
                try Task.checkCancellation()
                let translated = try session.receive(frame)
                for event in translated {
                    switch event.event {
                    case .responseCompleted:
                        guard terminal == nil else {
                            throw ProviderFailureMapper.protocolViolation(
                                "provider_attempt_duplicate_terminal_event",
                                descriptor: descriptor
                            )
                        }
                        terminal = event
                    case .cancelled:
                        throw ProviderFailureMapper.cancellation(
                            providerID: route.providerID,
                            adapterID: route.adapterID
                        )
                    default:
                        guard terminal == nil else {
                            throw ProviderFailureMapper.protocolViolation(
                                "provider_attempt_event_after_terminal",
                                descriptor: descriptor
                            )
                        }
                        try Self.yield(event, to: continuation)
                    }
                }
            }

            let tail = try session.finish()
            for event in tail {
                switch event.event {
                case .responseCompleted:
                    guard terminal == nil else {
                        throw ProviderFailureMapper.protocolViolation(
                            "provider_attempt_duplicate_terminal_event",
                            descriptor: descriptor
                        )
                    }
                    terminal = event
                case .cancelled:
                    throw ProviderFailureMapper.cancellation(
                        providerID: route.providerID,
                        adapterID: route.adapterID
                    )
                default:
                    guard terminal == nil else {
                        throw ProviderFailureMapper.protocolViolation(
                            "provider_attempt_event_after_terminal",
                            descriptor: descriptor
                        )
                    }
                    try Self.yield(event, to: continuation)
                }
            }

            guard let terminal else {
                throw ProviderFailure(
                    category: .protocolViolation,
                    code: "provider_attempt_missing_terminal_event",
                    publicMessage: "The provider stream violated the adapter contract.",
                    providerID: route.providerID,
                    adapterID: route.adapterID
                )
            }
            // A terminal is visible only after EOF and session validation. A
            // completion followed by an illegal frame can never be committed.
            try Self.yield(terminal, to: continuation)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let failure = error as? ProviderFailure { throw failure }
            if let contract = error as? ProviderGatewayContractFailure { throw contract }
            if error is CancellationError { throw CancellationError() }
            throw ProviderFailureMapper.transportFailure(
                providerID: route.providerID,
                adapterID: route.adapterID
            )
        }
    }

    private static func makeDispatch(
        scope: ProviderAttemptScope,
        route: ProviderRoute,
        encoded: ProviderEncodedRequest
    ) throws -> ProviderAttemptDispatch {
        let material = ProviderAttemptDispatchDigestMaterial(
            scheme: "novaforge-provider-attempt-request-v1",
            method: encoded.method,
            relativePath: encoded.relativePath,
            body: encoded.body
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(material))
            .map { String(format: "%02x", $0) }
            .joined()
        return ProviderAttemptDispatch(
            scope: scope,
            route: route,
            method: encoded.method,
            relativePath: encoded.relativePath,
            requestSHA256: try ProviderRequestDigest("sha256:" + digest)
        )
    }

    private static func requireCanonicalRequestBudget(
        _ request: CanonicalProviderRequest
    ) throws {
        do {
            try ProviderRequestBudget.validate(request)
        } catch {
            throw ProviderGatewayContractFailure.requestBudgetExceeded
        }
    }

    private static func requireEncodedRequestBudget(
        _ request: ProviderEncodedRequest
    ) throws {
        do {
            try ProviderRequestBudget.validateEncodedBody(request.body)
        } catch {
            throw ProviderGatewayContractFailure.encodedRequestBudgetExceeded
        }
    }

    private static func isSafeAttemptIdentity(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !value.hasPrefix("//"),
              !value.contains("://"), !value.contains("?"),
              !value.contains("#"), !value.contains("\\"),
              value.utf8.count <= 2_048
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    private func claimProcessLocalScope(_ scope: ProviderAttemptScope) throws {
        guard !activeAttemptScopes.contains(scope),
              !recentAttemptScopes.contains(scope)
        else { throw ProviderGatewayContractFailure.duplicateAttemptScope }
        guard activeAttemptScopes.count < Self.maximumActiveAttemptScopes else {
            throw ProviderGatewayContractFailure.attemptScopeCapacityExceeded
        }
        activeAttemptScopes.insert(scope)
    }

    private func releaseProcessLocalScope(_ scope: ProviderAttemptScope) {
        activeAttemptScopes.remove(scope)
        guard recentAttemptScopes.insert(scope).inserted else { return }
        if recentAttemptScopeOrder.count < Self.maximumRecentAttemptScopes {
            recentAttemptScopeOrder.append(scope)
        } else {
            let evicted = recentAttemptScopeOrder[recentAttemptScopeCursor]
            recentAttemptScopes.remove(evicted)
            recentAttemptScopeOrder[recentAttemptScopeCursor] = scope
            recentAttemptScopeCursor =
                (recentAttemptScopeCursor + 1) % Self.maximumRecentAttemptScopes
        }
    }

    private static func yield<Event: Sendable>(
        _ event: sending Event,
        to continuation: AsyncThrowingStream<Event, any Error>.Continuation
    ) throws {
        switch continuation.yield(event) {
        case .enqueued:
            return
        case .dropped:
            throw ProviderGatewayContractFailure.consumerBackpressureExceeded
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw ProviderGatewayContractFailure.consumerBackpressureExceeded
        }
    }

    private static func sanitizeFailure(
        _ error: any Error,
        descriptor: ProviderAdapterDescriptor
    ) -> ProviderFailure {
        if let failure = error as? ProviderFailure { return failure }
        if error is CancellationError {
            return ProviderFailureMapper.cancellation(
                providerID: descriptor.route.providerID,
                adapterID: descriptor.route.adapterID
            )
        }
        return ProviderFailureMapper.transportFailure(
            providerID: descriptor.route.providerID,
            adapterID: descriptor.route.adapterID
        )
    }

    private static func delay(milliseconds: UInt64) async throws {
        guard milliseconds > 0 else { return }
        let multiplied = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        let nanoseconds = multiplied.overflow ? UInt64.max : multiplied.partialValue
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

private struct ProviderAttemptDispatchDigestMaterial: Codable {
    let scheme: String
    let method: ProviderHTTPMethod
    let relativePath: String
    let body: JSONValue
}

private extension CanonicalProviderRequest {
    func routed(to model: ProviderModelID) -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: requestID,
            model: model,
            messages: messages,
            tools: tools,
            options: options,
            metadata: metadata
        )
    }
}

private extension Array where Element == ProviderAttemptEvent {
    var finishReason: ModelFinishReason? {
        reversed().compactMap { envelope in
            if case let .responseCompleted(completion) = envelope.event {
                completion.finishReason
            } else {
                nil
            }
        }.first
    }
}
