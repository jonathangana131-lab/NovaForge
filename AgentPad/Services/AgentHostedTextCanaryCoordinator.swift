#if DEBUG
import AgentDomain
import AgentEngine
import AgentProviders
import AgentShadow
import AgentStore
import AgentTools
import CryptoKit
import Foundation

enum AgentHostedTextCanaryCoordinatorError: Error, Equatable, Sendable {
    case invalidAcceptance
    case invalidCanaryFeatures
    case nonCanonicalTextHistory
    case toolBearingHistory
    case invalidTextOnlyOptions
    case invalidRequestIdentity
    case requestModelMismatch
    case nonOpenAIRoute
    case routeMismatch
    case unexpectedProviderEvent
    case eventIdentityMismatch
    case missingProviderUsage
    case duplicateProviderDispatch
    case attemptTerminalAlreadyCommitted
    case attemptFailed(AgentErrorInfo)
}

/// A package-minted OpenAI route plus the exact ordinary catalog used for the
/// wire attempt. The declared route is cross-checked so a caller-configured or
/// lookalike OpenAI-compatible endpoint cannot borrow the trusted capability.
struct AgentHostedTextCanaryProvider: Sendable {
    let route: ProviderRoute
    let adapterID: ProviderAdapterID
    let capability: HostedTextOnlyProviderCapability
    let catalog: ProviderAdapterCatalog

    init(
        trustedCatalog: TrustedHostedProviderCatalog,
        declaredRoute: ProviderRoute? = nil
    ) throws {
        let catalog = try trustedCatalog.providerCatalog()
        let adapterID = trustedCatalog.adapterID
        let actualRoute = try catalog.adapter(id: adapterID).descriptor.route
        let route = declaredRoute ?? actualRoute

        guard route.providerID.rawValue == "openai",
              route.deployment == .hostedService,
              route.provenance == .builtInOpenAIChatCompletions ||
                  route.provenance == .builtInOpenAIResponses
        else {
            throw AgentHostedTextCanaryCoordinatorError.nonOpenAIRoute
        }
        guard route == actualRoute else {
            throw AgentHostedTextCanaryCoordinatorError.routeMismatch
        }

        let capability = try trustedCatalog.hostedTextOnlyCapability(
            adapterID: adapterID
        )
        let snapshot = capability.snapshot
        guard snapshot.providerID == route.providerID,
              snapshot.modelID == route.modelID,
              snapshot.adapterID == route.adapterID,
              snapshot.capabilities == route.capabilities,
              snapshot.deployment == route.deployment,
              snapshot.provenance == route.provenance,
              snapshot.toolDispatchDisabled
        else {
            throw AgentHostedTextCanaryCoordinatorError.routeMismatch
        }

        self.route = route
        self.adapterID = adapterID
        self.capability = capability
        self.catalog = catalog
    }

    static func openAIChatCompletions(
        model: ProviderModelID
    ) throws -> Self {
        try Self(trustedCatalog: .openAIChatCompletions(model: model))
    }

    static func openAIResponses(
        model: ProviderModelID
    ) throws -> Self {
        try Self(trustedCatalog: .openAIResponses(model: model))
    }
}

struct AgentHostedTextCanaryResult: Equatable, Sendable {
    let scope: ProviderAttemptScope
    let attemptID: AttemptID
    let items: [ModelItem]
    let usage: ModelUsage
    let finishReason: ModelFinishReason
    let terminalCommit: AgentJournalCommit
}

/// M5's deliberately narrow execution seam. It accepts no tool authority and
/// calls only ModelGateway's no-retry single-attempt primitive.
struct AgentHostedTextCanaryCoordinator: Sendable {
    static let engineVersion = EngineVersion(
        rawValue: "agent-harness-v2-canary"
    )
    static let featureSet = AgentFeatureSet([
        "v2DarkReplay",
        "v2HostedText",
    ])

    private let journal: any AgentEventJournal
    private let provider: AgentHostedTextCanaryProvider
    private let gateway: ModelGateway

    init(
        journal: any AgentEventJournal,
        provider: AgentHostedTextCanaryProvider,
        transport: any ProviderTransport
    ) {
        self.journal = journal
        self.provider = provider
        gateway = ModelGateway(catalog: provider.catalog, transport: transport)
    }

    func execute(
        acceptedRun acceptance: AgentRunAcceptance,
        request: CanonicalProviderRequest,
        capturedContext: AgentHostedTextCanaryCapturedContext? = nil
    ) async throws -> AgentHostedTextCanaryResult {
        try Task.checkCancellation()
        try validateAcceptedRun(
            acceptance,
            request: request,
            capturedContext: capturedContext
        )

        let runID = acceptance.metadata.runID
        let wireRequest = Self.runBoundRequest(request, runID: runID)
        let attestation = try await DarkReplayEngine(reader: journal).attest(runID)
        let frozenPolicy = try await DeveloperCanaryPolicy.freeze(
            for: attestation,
            hostedTextCapability: provider.capability,
            tools: []
        )
        try frozenPolicy.validateFrozenInputs(
            runID: runID,
            hostedTextCapability: provider.capability,
            features: acceptance.metadata.context.features
        )
        try await verifyDurableAcceptance(acceptance)
        try Task.checkCancellation()

        _ = try await appendRunStarted(acceptance)

        let scope = Self.scope(for: wireRequest.requestID)
        let attemptID = Self.attemptID(for: scope, runID: runID)
        let dispatchState = ProviderDispatchCommitState()
        let barrier = DurableProviderAttemptBarrier(
            journal: journal,
            acceptance: acceptance,
            expectedScope: scope,
            expectedRoute: provider.route,
            expectedRequestPath: provider.capability.snapshot.requestPath,
            attemptID: attemptID,
            state: dispatchState
        )

        do {
            let collected = try await collectProvisionalAttempt(
                request: wireRequest,
                scope: scope,
                barrier: barrier
            )
            try Task.checkCancellation()
            let timestamp = Self.eventTimestamp(
                acceptance,
                sequence: EventSequence(rawValue: 4)
            )
            let items = Self.committedItems(
                text: collected.text,
                scope: scope,
                runID: runID,
                timestamp: timestamp
            )
            let envelope = Self.envelope(
                acceptance: acceptance,
                sequence: EventSequence(rawValue: 4),
                idempotencyKey: Self.terminalIdempotencyKey(
                    scope: scope,
                    outcome: "response"
                ),
                eventDomain: "m5-hosted-text-response",
                eventMaterial: runID.description + "|" +
                    scope.attemptID.rawValue,
                timestamp: timestamp,
                causationEventID: Self.requestStartedEventID(
                    scope: scope,
                    runID: runID,
                    requestDigest: await dispatchState.requestDigest()
                ),
                payload: .modelResponseCommitted(ModelResponseCommittedEvent(
                    attemptID: attemptID,
                    items: items,
                    usage: collected.usage.modelUsage,
                    finishReason: collected.finishReason
                ))
            )
            try Task.checkCancellation()
            let commit = try await appendAttemptTerminal(envelope)
            return AgentHostedTextCanaryResult(
                scope: scope,
                attemptID: attemptID,
                items: items,
                usage: collected.usage.modelUsage,
                finishReason: collected.finishReason,
                terminalCommit: commit
            )
        } catch {
            guard await dispatchState.wasCommitted() else { throw error }

            let failure = Self.sanitizedFailure(error)
            let envelope = Self.envelope(
                acceptance: acceptance,
                sequence: EventSequence(rawValue: 4),
                idempotencyKey: Self.terminalIdempotencyKey(
                    scope: scope,
                    outcome: "failure"
                ),
                eventDomain: "m5-hosted-text-failure",
                eventMaterial: runID.description + "|" +
                    scope.attemptID.rawValue,
                timestamp: Self.eventTimestamp(
                    acceptance,
                    sequence: EventSequence(rawValue: 4)
                ),
                causationEventID: Self.requestStartedEventID(
                    scope: scope,
                    runID: runID,
                    requestDigest: await dispatchState.requestDigest()
                ),
                payload: .modelRequestFailed(ModelRequestFailedEvent(
                    attemptID: attemptID,
                    error: failure,
                    outputWasCommitted: false
                ))
            )
            let commit = try await appendAttemptFailure(envelope)
            _ = commit
            throw AgentHostedTextCanaryCoordinatorError.attemptFailed(failure)
        }
    }

    private func validateAcceptedRun(
        _ acceptance: AgentRunAcceptance,
        request: CanonicalProviderRequest,
        capturedContext: AgentHostedTextCanaryCapturedContext?
    ) throws {
        do {
            _ = try AgentJournalValidation.validateAcceptance(acceptance)
        } catch {
            throw AgentHostedTextCanaryCoordinatorError.invalidAcceptance
        }

        let context = acceptance.metadata.context
        guard context.schemaVersion == .v1_1,
              context.engineVersion == Self.engineVersion,
              context.features == Self.featureSet
        else {
            throw AgentHostedTextCanaryCoordinatorError.invalidCanaryFeatures
        }
        guard request.model == provider.route.modelID else {
            throw AgentHostedTextCanaryCoordinatorError.requestModelMismatch
        }
        guard Self.isSafeRequestIdentity(request.requestID) else {
            throw AgentHostedTextCanaryCoordinatorError.invalidRequestIdentity
        }
        guard request.tools.isEmpty,
              !request.messages.contains(where: Self.isToolBearing)
        else {
            throw AgentHostedTextCanaryCoordinatorError.toolBearingHistory
        }
        guard request.messages.allSatisfy(Self.isCanonicalTextMessage) else {
            throw AgentHostedTextCanaryCoordinatorError
                .nonCanonicalTextHistory
        }
        guard request.options.toolChoice == .none,
              request.options.parallelToolCalls != true,
              request.options.reasoningSummary != true,
              request.options.previousResponseID == nil
        else {
            throw AgentHostedTextCanaryCoordinatorError.invalidTextOnlyOptions
        }
        guard let acceptedUser = Self.acceptedUser(from: acceptance) else {
            throw AgentHostedTextCanaryCoordinatorError
                .nonCanonicalTextHistory
        }
        if let capturedContext {
            guard capturedContext.validates(
                providerMessages: request.messages,
                acceptedUserItemID: acceptedUser.itemID,
                acceptedUserOriginalText: acceptedUser.text
            ) else {
                throw AgentHostedTextCanaryCoordinatorError
                    .nonCanonicalTextHistory
            }
        } else {
            guard case let .runAccepted(payload) =
                    acceptance.envelope.event.payload,
                  request.messages == Self.providerMessages(
                      from: payload.initialItems
                  ) else {
                throw AgentHostedTextCanaryCoordinatorError
                    .nonCanonicalTextHistory
            }
        }
    }

    private func verifyDurableAcceptance(
        _ acceptance: AgentRunAcceptance
    ) async throws {
        guard let durableMetadata = try await journal.metadata(
            for: acceptance.metadata.runID
        ), durableMetadata == acceptance.metadata else {
            throw AgentHostedTextCanaryCoordinatorError.invalidAcceptance
        }
        let durableEvents = try await journal.events(
            for: acceptance.metadata.runID,
            after: nil
        )
        guard durableEvents.first?.envelope == acceptance.envelope else {
            throw AgentHostedTextCanaryCoordinatorError.invalidAcceptance
        }
    }

    private func appendRunStarted(
        _ acceptance: AgentRunAcceptance
    ) async throws -> AgentJournalCommit {
        let envelope = Self.envelope(
            acceptance: acceptance,
            sequence: EventSequence(rawValue: 2),
            idempotencyKey: "m5-canary:run-started:v1",
            eventDomain: "m5-hosted-text-run-started",
            eventMaterial: acceptance.metadata.runID.description,
            timestamp: Self.eventTimestamp(
                acceptance,
                sequence: EventSequence(rawValue: 2)
            ),
            causationEventID: acceptance.metadata.acceptanceEventID,
            payload: .runStarted(RunStartedEvent())
        )
        return try await journal.append(envelope)
    }

    /// Attempt settlement never inherits caller cancellation. A terminal may
    /// have committed immediately before the journal surfaced an error, so the
    /// fresh task also performs exact-envelope recovery before deciding that
    /// persistence failed.
    private func appendAttemptTerminal(
        _ envelope: AgentEventEnvelope
    ) async throws -> AgentJournalCommit {
        let journal = journal
        return try await Task.detached {
            try await Self.appendOrRecover(envelope, journal: journal)
        }.value
    }

    private func appendAttemptFailure(
        _ envelope: AgentEventEnvelope
    ) async throws -> AgentJournalCommit {
        let journal = journal
        return try await Task.detached {
            try await Self.appendOrRecover(envelope, journal: journal)
        }.value
    }

    private static func appendOrRecover(
        _ envelope: AgentEventEnvelope,
        journal: any AgentEventJournal
    ) async throws -> AgentJournalCommit {
        do {
            let commit = try await journal.append(envelope)
            guard commit.record.envelope == envelope else {
                throw AgentHostedTextCanaryCoordinatorError
                    .eventIdentityMismatch
            }
            return commit
        } catch {
            let records = try await journal.events(
                for: envelope.runID,
                after: nil
            )
            guard let existing = records.first(where: {
                $0.event.header.eventID == envelope.event.header.eventID
            }), existing.envelope == envelope else {
                throw error
            }
            return AgentJournalCommit(
                disposition: .alreadyCommitted,
                record: existing
            )
        }
    }

    private func collectProvisionalAttempt(
        request: CanonicalProviderRequest,
        scope: ProviderAttemptScope,
        barrier: DurableProviderAttemptBarrier
    ) async throws -> CollectedProviderAttempt {
        let stream = await gateway.streamAttempt(ProviderSingleAttemptInvocation(
            request: request,
            adapterID: provider.adapterID,
            scope: scope,
            barrier: barrier
        ))
        var text = ""
        var usage: ProviderUsage?
        var finishReason: ModelFinishReason?

        for try await envelope in stream {
            guard envelope.scope == scope else {
                throw AgentHostedTextCanaryCoordinatorError
                    .unexpectedProviderEvent
            }
            switch envelope.event {
            case .responseStarted:
                break
            case let .textDelta(delta):
                guard delta.outputIndex == 0 else {
                    throw AgentHostedTextCanaryCoordinatorError
                        .unexpectedProviderEvent
                }
                text.append(delta.text)
            case let .usage(value):
                guard usage == nil else {
                    throw AgentHostedTextCanaryCoordinatorError
                        .unexpectedProviderEvent
                }
                usage = value
            case let .responseCompleted(completion):
                guard finishReason == nil,
                      completion.finishReason != .toolCalls,
                      completion.finishReason != .cancelled
                else {
                    throw AgentHostedTextCanaryCoordinatorError
                        .unexpectedProviderEvent
                }
                finishReason = completion.finishReason
            case .reasoningDelta,
                 .toolCallStarted,
                 .toolCallArgumentsDelta,
                 .toolCallCompleted,
                 .cancelled:
                throw AgentHostedTextCanaryCoordinatorError
                    .unexpectedProviderEvent
            }
        }

        guard let usage else {
            throw AgentHostedTextCanaryCoordinatorError.missingProviderUsage
        }
        guard let finishReason else {
            throw AgentHostedTextCanaryCoordinatorError
                .unexpectedProviderEvent
        }
        return CollectedProviderAttempt(
            text: text,
            usage: usage,
            finishReason: finishReason
        )
    }

    private static func scope(for requestID: String) -> ProviderAttemptScope {
        ProviderAttemptScope(
            requestID: requestID,
            attemptID: ProviderAttemptID(
                rawValue: "\(requestID):provider-attempt:1"
            )
        )
    }

    static func attemptID(
        for scope: ProviderAttemptScope,
        runID: RunID
    ) -> AttemptID {
        AttemptID(rawValue: stableUUID(
            domain: "m5-provider-attempt-id",
            material: runID.description + "\u{0}" + scope.requestID +
                "\u{0}" + scope.attemptID.rawValue
        ))
    }

    static func runBoundRequestID(
        _ requestID: String,
        runID: RunID
    ) -> String {
        let digest = SHA256.hash(data: Data(
            (runID.description + "\u{0}" + requestID).utf8
        )).map { String(format: "%02x", $0) }.joined()
        return "m5-run-\(digest)"
    }

    private static func runBoundRequest(
        _ request: CanonicalProviderRequest,
        runID: RunID
    ) -> CanonicalProviderRequest {
        CanonicalProviderRequest(
            requestID: runBoundRequestID(request.requestID, runID: runID),
            model: request.model,
            messages: request.messages,
            tools: request.tools,
            options: request.options,
            metadata: request.metadata
        )
    }

    private static func providerMessages(
        from items: [ModelItem]
    ) -> [ProviderMessage]? {
        var messages: [ProviderMessage] = []
        for item in items {
            guard case let .message(message) = item.payload else { return nil }
            let role: ProviderMessageRole
            switch message.role {
            case .user: role = .user
            case .assistant: role = .assistant
            }
            var content: [ProviderContentPart] = []
            for part in message.content {
                guard case let .text(text) = part else { return nil }
                content.append(.text(text))
            }
            messages.append(ProviderMessage(role: role, content: content))
        }
        return messages
    }

    private static func acceptedUser(
        from acceptance: AgentRunAcceptance
    ) -> (itemID: UUID, text: String)? {
        guard case let .runAccepted(payload) =
                acceptance.envelope.event.payload,
              payload.initialItems.count == 1,
              let item = payload.initialItems.first,
              case let .message(message) = item.payload,
              message.role == .user,
              message.content.count == 1,
              case let .text(text) = message.content[0],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (item.id.rawValue, text)
    }

    private static func isToolBearing(_ message: ProviderMessage) -> Bool {
        if message.role == .tool || message.toolCallID != nil {
            return true
        }
        return message.content.contains {
            if case .toolCall = $0 { return true }
            return false
        }
    }

    private static func isCanonicalTextMessage(
        _ message: ProviderMessage
    ) -> Bool {
        guard message.role == .system || message.role == .user ||
                message.role == .assistant,
              message.toolCallID == nil,
              message.name == nil,
              message.content.count == 1,
              case let .text(text) = message.content[0]
        else { return false }
        return !text.isEmpty
    }

    private static func isSafeRequestIdentity(_ value: String) -> Bool {
        let attemptSuffix = ":provider-attempt:1"
        guard !value.isEmpty,
              value.utf8.count + attemptSuffix.utf8.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    private static func committedItems(
        text: String,
        scope: ProviderAttemptScope,
        runID: RunID,
        timestamp: AgentInstant
    ) -> [ModelItem] {
        guard !text.isEmpty else { return [] }
        return [ModelItem(
            id: ModelItemID(rawValue: stableUUID(
                domain: "m5-provider-response-item",
                material: runID.description + "\u{0}" +
                    scope.attemptID.rawValue
            )),
            createdAt: timestamp,
            payload: .message(ModelMessage(
                role: .assistant,
                content: [.text(text)]
            ))
        )]
    }

    static func envelope(
        acceptance: AgentRunAcceptance,
        sequence: EventSequence,
        idempotencyKey: String,
        eventDomain: String,
        eventMaterial: String,
        timestamp: AgentInstant,
        causationEventID: EventID,
        payload: AgentEventPayload
    ) -> AgentEventEnvelope {
        let context = acceptance.metadata.context
        return AgentEventEnvelope(
            writerID: acceptance.metadata.writerID,
            writerSequence: sequence,
            idempotencyKey: idempotencyKey,
            event: AgentEvent(
                header: AgentEventHeader(
                    eventID: EventID(rawValue: stableUUID(
                        domain: eventDomain,
                        material: eventMaterial
                    )),
                    schemaVersion: context.schemaVersion,
                    context: context,
                    sequence: sequence,
                    timestamp: timestamp,
                    causationID: CausationID(
                        rawValue: causationEventID.rawValue
                    ),
                    correlationID: acceptance.envelope.event.header
                        .correlationID
                ),
                payload: payload
            )
        )
    }

    fileprivate static func requestStartedEventID(
        scope: ProviderAttemptScope,
        runID: RunID,
        requestDigest: ProviderRequestDigest?
    ) -> EventID {
        EventID(rawValue: stableUUID(
            domain: "m5-hosted-text-request-started",
            material: runID.description + "|" +
                scope.attemptID.rawValue + "|" +
                (requestDigest?.rawValue ?? "missing-digest")
        ))
    }

    fileprivate static func requestStartedIdempotencyKey(
        scope: ProviderAttemptScope,
        requestDigest: ProviderRequestDigest
    ) -> String {
        let scopeDigest = SHA256.hash(
            data: Data((scope.requestID + "\u{0}" +
                scope.attemptID.rawValue).utf8)
        ).map { String(format: "%02x", $0) }.joined()
        return "m5-canary:request-started:\(scopeDigest):" +
            String(requestDigest.rawValue.dropFirst(7))
    }

    private static func terminalIdempotencyKey(
        scope: ProviderAttemptScope,
        outcome: String
    ) -> String {
        let digest = SHA256.hash(
            data: Data(scope.attemptID.rawValue.utf8)
        ).map { String(format: "%02x", $0) }.joined()
        return "m5-canary:attempt-\(outcome):\(digest)"
    }

    static func eventTimestamp(
        _ acceptance: AgentRunAcceptance,
        sequence: EventSequence
    ) -> AgentInstant {
        let delta = Int64(clamping: sequence.rawValue - 1)
        let addition = acceptance.metadata.context.acceptedAt.rawValue
            .addingReportingOverflow(delta)
        return AgentInstant(
            rawValue: addition.overflow ? Int64.max : addition.partialValue
        )
    }

    /// Stable provider recovery entropy derived only from canonical identities.
    /// Prompt bytes, tool arguments, credentials, and provider output never
    /// participate in this value, so a relaunch reconstructs it exactly.
    static func providerRecoverySeed(
        runID: RunID,
        scope: ProviderAttemptScope,
        ordinal: UInt32
    ) -> UInt64 {
        let material = [
            runID.description,
            scope.requestID,
            scope.attemptID.rawValue,
            String(ordinal),
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(
            ("novaforge-provider-recovery-seed-v1\u{0}" + material).utf8
        )).prefix(8).reduce(UInt64.zero) { value, byte in
            (value << 8) | UInt64(byte)
        }
    }

    private static func stableUUID(
        domain: String,
        material: String
    ) -> UUID {
        var bytes = Array(SHA256.hash(
            data: Data((domain + "\u{0}" + material).utf8)
        ).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func sanitizedFailure(_ error: Error) -> AgentErrorInfo {
        if Task.isCancelled || error is CancellationError {
            return AgentErrorInfo(
                category: .cancelled,
                code: "hosted_text_attempt_cancelled",
                publicMessage: "The hosted text attempt was cancelled.",
                retryable: false
            )
        }
        if let providerFailure = error as? ProviderFailure {
            let category = agentCategory(providerFailure.category)
            return AgentErrorInfo(
                category: category,
                code: fixedProviderFailureCode(category),
                publicMessage: fixedProviderFailureMessage(category),
                retryable: false
            )
        }
        return AgentErrorInfo(
            category: .invariantViolation,
            code: "hosted_text_attempt_contract_failed",
            publicMessage: "The hosted text attempt failed a safety contract.",
            retryable: false
        )
    }

    private static func agentCategory(
        _ category: ProviderFailureCategory
    ) -> AgentErrorCategory {
        switch category {
        case .cancelled: .cancelled
        case .timeout: .timeout
        case .authentication: .authentication
        case .authorization: .authorization
        case .invalidRequest: .invalidInput
        case .rateLimited: .rateLimited
        case .contextLimit: .contextLimit
        case .unavailable: .unavailable
        case .transport: .transport
        case .malformedEvent, .protocolViolation, .contentFiltered,
             .providerInternal: .provider
        case .unknown: .unknown
        }
    }

    private static func fixedProviderFailureCode(
        _ category: AgentErrorCategory
    ) -> String {
        "hosted_text_provider_\(category.rawValue)"
    }

    private static func fixedProviderFailureMessage(
        _ category: AgentErrorCategory
    ) -> String {
        switch category {
        case .cancelled:
            "The hosted text attempt was cancelled."
        case .authentication, .authorization:
            "The hosted provider rejected its configured access."
        case .rateLimited:
            "The hosted provider is temporarily rate limited."
        case .contextLimit, .invalidInput:
            "The hosted provider rejected the bounded request."
        case .timeout, .transport, .unavailable:
            "The hosted provider could not be reached safely."
        case .provider, .unknown, .invariantViolation, .persistence, .tool:
            "The hosted provider attempt failed safely."
        }
    }
}

/// M5's distinct hosted read-tools coordinator. Provider responses are first
/// committed as canonical model items; only then may the package gateway move
/// the one invocation through proposed → scheduled → started → completed.
/// Tool application events are impossible on this route.
private struct CollectedProviderAttempt: Sendable {
    let text: String
    let usage: ProviderUsage
    let finishReason: ModelFinishReason
}

private actor ProviderDispatchCommitState {
    private var committed = false
    private var digest: ProviderRequestDigest?

    func recordCommitted(requestDigest: ProviderRequestDigest) {
        committed = true
        digest = requestDigest
    }

    func wasCommitted() -> Bool { committed }
    func requestDigest() -> ProviderRequestDigest? { digest }
}

private struct DurableProviderAttemptBarrier:
    ProviderAttemptDispatchBarrier,
    Sendable
{
    let journal: any AgentEventJournal
    let acceptance: AgentRunAcceptance
    let expectedScope: ProviderAttemptScope
    let expectedRoute: ProviderRoute
    let expectedRequestPath: String
    let attemptID: AttemptID
    let state: ProviderDispatchCommitState

    func beforeDispatch(_ dispatch: ProviderAttemptDispatch) async throws {
        try Task.checkCancellation()
        guard dispatch.scope == expectedScope,
              dispatch.route == expectedRoute,
              dispatch.method == .post,
              dispatch.relativePath == expectedRequestPath
        else {
            throw AgentHostedTextCanaryCoordinatorError.routeMismatch
        }

        let ordinal: UInt32 = 1
        let providerAttempt = try dispatch.journalMetadata(
            ordinal: ordinal,
            recoverySeed: AgentHostedTextCanaryCoordinator
                .providerRecoverySeed(
                    runID: acceptance.metadata.runID,
                    scope: expectedScope,
                    ordinal: ordinal
                )
        )

        let eventID = AgentHostedTextCanaryCoordinator.requestStartedEventID(
            scope: expectedScope,
            runID: acceptance.metadata.runID,
            requestDigest: dispatch.requestSHA256
        )
        let envelope = AgentHostedTextCanaryCoordinator.envelope(
            acceptance: acceptance,
            sequence: EventSequence(rawValue: 3),
            idempotencyKey: AgentHostedTextCanaryCoordinator
                .requestStartedIdempotencyKey(
                    scope: expectedScope,
                    requestDigest: dispatch.requestSHA256
            ),
            eventDomain: "m5-hosted-text-request-started",
            eventMaterial: acceptance.metadata.runID.description + "|" +
                expectedScope.attemptID.rawValue + "|" +
                dispatch.requestSHA256.rawValue,
            timestamp: AgentHostedTextCanaryCoordinator.eventTimestamp(
                acceptance,
                sequence: EventSequence(rawValue: 3)
            ),
            causationEventID: EventID(rawValue: AgentHostedTextCanaryCoordinator
                .stableRunStartedUUID(acceptance.metadata.runID)),
            payload: .modelRequestStarted(ModelRequestStartedEvent(
                attemptID: attemptID,
                route: ModelRoute(
                    provider: dispatch.route.providerID.rawValue,
                    model: dispatch.route.modelID.rawValue,
                    adapter: dispatch.route.adapterID.rawValue
                ),
                providerAttempt: providerAttempt
            ))
        )
        guard envelope.event.header.eventID == eventID else {
            throw AgentHostedTextCanaryCoordinatorError.eventIdentityMismatch
        }

        let commit = try await journal.append(envelope)
        guard commit.disposition == .committed else {
            throw AgentHostedTextCanaryCoordinatorError
                .duplicateProviderDispatch
        }
        await state.recordCommitted(requestDigest: dispatch.requestSHA256)
        try Task.checkCancellation()
    }
}

private extension AgentHostedTextCanaryCoordinator {
    static func stableRunStartedUUID(_ runID: RunID) -> UUID {
        stableUUID(
            domain: "m5-hosted-text-run-started",
            material: runID.description
        )
    }
}
#endif
