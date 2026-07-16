#if DEBUG
import AgentDomain
import AgentProviders
import AgentStore
import AgentTools
import CryptoKit
import Foundation
import Observation
import SwiftData

enum AgentHostedTextCanaryLivePhase: Equatable, Sendable {
    case idle
    case accepting
    case running
    case stopping
    case blockedRecovery

    var locksWorkspaceRouting: Bool { self != .idle }
}

enum AgentHostedTextCanaryLiveNotice: Equatable, Sendable {
    case routeUnavailable
    case credentialMissing
    case credentialInvalid
    case requestInvalid
    case runFailed
    case cancelled
    case recoveryRequired

    var userMessage: String {
        switch self {
        case .routeUnavailable:
            "The hosted-text canary route is not available for this request."
        case .credentialMissing:
            "Add an OpenAI API key in Control before using the hosted-text canary."
        case .credentialInvalid:
            "The saved OpenAI API key is invalid. Replace it in Control and try again."
        case .requestInvalid:
            "This request does not satisfy the hosted-text canary contract."
        case .runFailed:
            "The hosted-text run ended without a response. Its durable receipt is available in History."
        case .cancelled:
            "The hosted-text run was stopped."
        case .recoveryRequired:
            "NovaForge saved durable run state but could not finish its materialized view. Recovery must complete before another run starts."
        }
    }
}

enum AgentHostedTextCanaryLiveSubmissionDisposition: Equatable, Sendable {
    case reserved
    case busy
    case blockedRecovery

    var wasReserved: Bool { self == .reserved }
}

enum AgentHostedTextCanaryLiveFactoryError: Error, Equatable, Sendable {
    case routeMismatch
    case providerMismatch
    case missingCredential
    case invalidCredential
    case invalidModel
    case invalidTemperature
    case emptyPrompt
    case toolBearingHistory
    case contextNotRepresentable
}

enum AgentHostedTextCanaryDraftPersistenceResolution: Equatable, Sendable {
    case removeAndClearVisible
    case replacePersistedWithVisible
    case removePersistedOnly
    case preservePersisted
}

private enum AgentHostedTextCanaryLiveInvariantError: Error, Sendable {
    case preparedDraftIdentityMismatch
    case operationReturnedBeforeAcceptance
}

/// The exact editor state whose text became durable. Chat owns both draft
/// stores: it always clears the persisted entry for `conversationID`, while
/// `matchesVisibleDraft` prevents a late acceptance from erasing newer text.
struct AgentHostedTextCanaryAcceptedDraftIdentity: Equatable, Sendable {
    let conversationID: UUID
    let requestMessageID: UUID
    let draftToken: UUID
    let text: String

    func matchesVisibleDraft(
        conversationID: UUID,
        draftToken: UUID,
        text: String
    ) -> Bool {
        self.conversationID == conversationID &&
            self.draftToken == draftToken &&
        self.text == text
    }

    func persistenceResolution(
        visibleConversationID: UUID,
        visibleDraftToken: UUID,
        visibleText: String,
        persistedText: String?
    ) -> AgentHostedTextCanaryDraftPersistenceResolution {
        if conversationID == visibleConversationID {
            return matchesVisibleDraft(
                conversationID: visibleConversationID,
                draftToken: visibleDraftToken,
                text: visibleText
            ) ? .removeAndClearVisible : .replacePersistedWithVisible
        }
        return persistedText == text
            ? .removePersistedOnly
            : .preservePersisted
    }
}

/// Immutable, text-only provider context captured on MainActor before the
/// canary task is reserved. The digest is not provider metadata; it lets the
/// coordinator prove that the request it dispatches is the exact sanitized
/// transcript whose final user turn became the durable acceptance item.
struct AgentHostedTextCanaryCapturedContext: Equatable, Sendable {
    let providerMessages: [ProviderMessage]
    let acceptedUserMessageIndex: Int
    let acceptedUserItemID: UUID
    let acceptedUserOriginalText: String
    let digest: String

    /// Exact sanitized system instruction used by the provider request. The
    /// execution composition hashes this transient value and never persists
    /// its plaintext.
    var systemInstruction: String? {
        guard let first = providerMessages.first,
              first.role == .system
        else { return nil }
        return Self.text(from: first)
    }

    static func capture(
        history: [ProviderMessageInput],
        currentUser: ProviderMessageInput,
        customSystemPrompt: String?,
        workspaceSummary: String,
        budget: ProviderContextWindow.Budget = .hosted
    ) throws -> Self {
        let completeHistory = history + [currentUser]
        let selected = ProviderContextWindow.select(
            completeHistory,
            budget: budget
        )
        guard selected.last?.id == currentUser.id,
              selected.contains(where: { $0.id == currentUser.id }) else {
            throw AgentHostedTextCanaryLiveFactoryError
                .contextNotRepresentable
        }
        guard !selected.contains(where: isToolBearing) else {
            throw AgentHostedTextCanaryLiveFactoryError.toolBearingHistory
        }

        let transcript: SanitizedProviderTranscript
        do {
            transcript = try ProviderContextWindow.prepareHostedTranscript(
                history: completeHistory,
                customSystemPrompt: customSystemPrompt,
                workspaceSummary: workspaceSummary,
                budget: budget
            )
        } catch {
            throw AgentHostedTextCanaryLiveFactoryError
                .contextNotRepresentable
        }
        let providerMessages = try canonicalMessages(from: transcript)
        guard let acceptedUserMessageIndex = providerMessages.indices.last,
              providerMessages[acceptedUserMessageIndex].role == .user else {
            throw AgentHostedTextCanaryLiveFactoryError
                .contextNotRepresentable
        }

        return try makeValidated(
            providerMessages: providerMessages,
            acceptedUserMessageIndex: acceptedUserMessageIndex,
            acceptedUserItemID: currentUser.id,
            acceptedUserOriginalText: currentUser.content
        )
    }

    static func acceptanceOnly(
        providerMessages: [ProviderMessage],
        acceptedUserItemID: UUID,
        acceptedUserOriginalText: String
    ) throws -> Self {
        guard let index = providerMessages.indices.last else {
            throw AgentHostedTextCanaryLiveFactoryError
                .contextNotRepresentable
        }
        return try makeValidated(
            providerMessages: providerMessages,
            acceptedUserMessageIndex: index,
            acceptedUserItemID: acceptedUserItemID,
            acceptedUserOriginalText: acceptedUserOriginalText
        )
    }

    func validates(
        providerMessages candidateMessages: [ProviderMessage],
        acceptedUserItemID candidateItemID: UUID,
        acceptedUserOriginalText candidateOriginalText: String
    ) -> Bool {
        providerMessages == candidateMessages &&
            acceptedUserItemID == candidateItemID &&
            acceptedUserOriginalText == candidateOriginalText &&
            Self.isCanonicalTextSequence(providerMessages) &&
            providerMessages.indices.contains(acceptedUserMessageIndex) &&
            acceptedUserMessageIndex == providerMessages.index(before: providerMessages.endIndex) &&
            providerMessages[acceptedUserMessageIndex].role == .user &&
            Self.text(from: providerMessages[acceptedUserMessageIndex]) ==
                Self.canonicalAcceptedUserText(
                    itemID: acceptedUserItemID,
                    originalText: acceptedUserOriginalText
                ) &&
            digest == Self.digest(
                providerMessages: providerMessages,
                acceptedUserMessageIndex: acceptedUserMessageIndex,
                acceptedUserItemID: acceptedUserItemID,
                acceptedUserOriginalText: acceptedUserOriginalText
            )
    }

    private static func makeValidated(
        providerMessages: [ProviderMessage],
        acceptedUserMessageIndex: Int,
        acceptedUserItemID: UUID,
        acceptedUserOriginalText: String
    ) throws -> Self {
        guard isCanonicalTextSequence(providerMessages),
              providerMessages.indices.contains(acceptedUserMessageIndex),
              acceptedUserMessageIndex == providerMessages.index(
                  before: providerMessages.endIndex
              ),
              providerMessages[acceptedUserMessageIndex].role == .user,
              text(from: providerMessages[acceptedUserMessageIndex]) ==
                  canonicalAcceptedUserText(
                      itemID: acceptedUserItemID,
                      originalText: acceptedUserOriginalText
                  ),
              !acceptedUserOriginalText.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            throw AgentHostedTextCanaryLiveFactoryError
                .contextNotRepresentable
        }
        return Self(
            providerMessages: providerMessages,
            acceptedUserMessageIndex: acceptedUserMessageIndex,
            acceptedUserItemID: acceptedUserItemID,
            acceptedUserOriginalText: acceptedUserOriginalText,
            digest: digest(
                providerMessages: providerMessages,
                acceptedUserMessageIndex: acceptedUserMessageIndex,
                acceptedUserItemID: acceptedUserItemID,
                acceptedUserOriginalText: acceptedUserOriginalText
            )
        )
    }

    private static func canonicalMessages(
        from transcript: SanitizedProviderTranscript
    ) throws -> [ProviderMessage] {
        try transcript.messages.map { message in
            let role: ProviderMessageRole
            switch message.role {
            case "system": role = .system
            case "user": role = .user
            case "assistant": role = .assistant
            default:
                throw AgentHostedTextCanaryLiveFactoryError
                    .contextNotRepresentable
            }
            guard message.toolCallID == nil,
                  message.toolCalls?.isEmpty != false,
                  let content = message.content,
                  !content.isEmpty else {
                throw AgentHostedTextCanaryLiveFactoryError
                    .contextNotRepresentable
            }
            return ProviderMessage(role: role, content: [.text(content)])
        }
    }

    private static func isToolBearing(_ message: ProviderMessageInput) -> Bool {
        message.role == .tool ||
            message.toolCallID != nil ||
            !message.toolCalls.isEmpty
    }

    private static func isCanonicalTextSequence(
        _ messages: [ProviderMessage]
    ) -> Bool {
        guard messages.first?.role == .system,
              !messages.dropFirst().contains(where: { $0.role == .system })
        else { return false }
        return messages.allSatisfy { message in
            guard message.role == .system || message.role == .user ||
                    message.role == .assistant,
                  message.toolCallID == nil,
                  message.name == nil,
                  message.content.count == 1,
                  case let .text(text) = message.content[0]
            else { return false }
            return !text.isEmpty
        }
    }

    private static func canonicalAcceptedUserText(
        itemID: UUID,
        originalText: String
    ) -> String? {
        let transcript = ProviderMessageSanitizer.sanitize(
            systemPrompt: "NovaForge hosted-text acceptance binding.",
            history: [ProviderMessageInput(
                id: itemID,
                role: .user,
                content: originalText,
                createdAt: Date(timeIntervalSinceReferenceDate: 0),
                toolCallID: nil,
                toolCalls: []
            )]
        )
        guard let message = transcript.messages.last,
              message.role == "user" else { return nil }
        return message.content
    }

    private static func text(from message: ProviderMessage) -> String? {
        guard message.content.count == 1,
              case let .text(text) = message.content[0] else { return nil }
        return text
    }

    private static func digest(
        providerMessages: [ProviderMessage],
        acceptedUserMessageIndex: Int,
        acceptedUserItemID: UUID,
        acceptedUserOriginalText: String
    ) -> String {
        var material = "m5-hosted-text-context-v1"
        append(String(acceptedUserMessageIndex), to: &material)
        append(acceptedUserItemID.uuidString.lowercased(), to: &material)
        append(acceptedUserOriginalText, to: &material)
        for message in providerMessages {
            append(message.role.rawValue, to: &material)
            for part in message.content {
                if case let .text(text) = part {
                    append(text, to: &material)
                }
            }
        }
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func append(_ value: String, to material: inout String) {
        material += "\u{0}\(value.utf8.count):\(value)"
    }
}

/// Scalar input captured by Chat at the send boundary. It intentionally owns
/// no ModelContainer or SwiftData model reference, so it can cross the task
/// boundary without letting mutable model objects escape MainActor.
struct AgentHostedTextCanaryLiveRequest: Sendable {
    let routing: AgentRunRoutingMetadata
    let selectedProvider: AIProvider
    let modelID: String
    let temperature: Double
    let prompt: String
    let conversationID: UUID
    let projectID: UUID?
    let workspaceIdentity: WorkspaceResourceIdentity
    let workspaceName: String
    let workspace: SandboxWorkspace
    let requestMessageID: UUID
    let draftToken: UUID
    let capturedContext: AgentHostedTextCanaryCapturedContext

    init(
        routing: AgentRunRoutingMetadata,
        selectedProvider: AIProvider,
        modelID: String,
        temperature: Double,
        prompt: String,
        conversationID: UUID,
        projectID: UUID?,
        workspace: SandboxWorkspace,
        history: [ProviderMessageInput] = [],
        customSystemPrompt: String? = nil,
        workspaceSummary: String? = nil,
        capturedAt: Date = Date(),
        requestMessageID: UUID,
        draftToken: UUID
    ) throws {
        self.routing = routing
        self.selectedProvider = selectedProvider
        self.modelID = modelID
        self.temperature = temperature
        self.prompt = prompt
        self.conversationID = conversationID
        self.projectID = projectID
        workspaceIdentity = try WorkspaceResourceIdentity(workspace: workspace)
        workspaceName = workspace.workspaceName
        self.workspace = workspace
        self.requestMessageID = requestMessageID
        self.draftToken = draftToken
        let newestHistoryDate = history.map(\.createdAt).max() ?? .distantPast
        let currentUserDate = max(
            capturedAt,
            newestHistoryDate.addingTimeInterval(0.000_001)
        )
        capturedContext = try AgentHostedTextCanaryCapturedContext.capture(
            history: history,
            currentUser: ProviderMessageInput(
                id: requestMessageID,
                role: .user,
                content: prompt,
                createdAt: currentUserDate,
                toolCallID: nil,
                toolCalls: []
            ),
            customSystemPrompt: customSystemPrompt,
            workspaceSummary: workspaceSummary ?? ProviderContextWindow
                .workspaceSummary(for: workspace, provider: selectedProvider)
        )
    }

    var draftIdentity: AgentHostedTextCanaryAcceptedDraftIdentity {
        AgentHostedTextCanaryAcceptedDraftIdentity(
            conversationID: conversationID,
            requestMessageID: requestMessageID,
            draftToken: draftToken,
            text: prompt
        )
    }
}

/// Non-secret output of the factory's preflight. Tests can assert the complete
/// canonical request and acceptance shape without constructing a store or
/// permitting network access.
struct AgentHostedTextCanaryLiveBlueprint: Sendable {
    let draftIdentity: AgentHostedTextCanaryAcceptedDraftIdentity
    let acceptance: AgentRunAcceptance
    let executionComposition: AgentRunExecutionComposition
    let providerRequest: CanonicalProviderRequest
    let capturedContext: AgentHostedTextCanaryCapturedContext
    let legacyAcceptanceProjection: SwiftDataLegacyAcceptanceProjection

    var runID: RunID { acceptance.metadata.runID }
}

struct AgentHostedTextCanaryPreparedRun: Sendable {
    typealias DidAccept = @Sendable () async -> Void
    typealias Operation = @Sendable (
        _ didAccept: @escaping DidAccept
    ) async throws -> Void

    let blueprint: AgentHostedTextCanaryLiveBlueprint
    let operation: Operation

    var draftIdentity: AgentHostedTextCanaryAcceptedDraftIdentity {
        blueprint.draftIdentity
    }
}

enum AgentHostedCanaryScorecardSinkError: Error, Equatable, Sendable {
    case invalidRoute
    case invalidPairID
    case invalidMetric
    case invalidDigest
    case duplicateSample
    case incompletePairs
}

/// Content-free M5 measurement schema consumed directly by
/// `scripts/codex-m5-scorecard.py`. There is deliberately no initializer field
/// for prompts, paths, provider text, tool output, or request/response bodies.
actor AgentHostedCanaryScorecardSink {
    enum Engine: String, Codable, Sendable {
        case v1
        case v2
    }

    struct Route: Codable, Equatable, Sendable {
        let provider: String
        let model: String
        let temperature: Double
        let maxOutputTokens: Int
        let sampleTarget: Int

        init(
            provider: String,
            model: String,
            temperature: Double,
            maxOutputTokens: Int,
            sampleTarget: Int = 100
        ) throws {
            guard Self.safeIdentity(provider), Self.safeIdentity(model),
                  temperature.isFinite, temperature >= 0,
                  maxOutputTokens > 0, sampleTarget == 100 else {
                throw AgentHostedCanaryScorecardSinkError.invalidRoute
            }
            self.provider = provider
            self.model = model
            self.temperature = temperature
            self.maxOutputTokens = maxOutputTokens
            self.sampleTarget = sampleTarget
        }

        private static func safeIdentity(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 256 &&
                value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct Digests: Codable, Equatable, Sendable {
        let contextSHA256: String
        let transcriptSHA256: String
        let evidenceSHA256: String
        let workspaceBeforeSHA256: String
        let workspaceAfterSHA256: String

        init(
            contextSHA256: String,
            transcriptSHA256: String,
            evidenceSHA256: String,
            workspaceBeforeSHA256: String,
            workspaceAfterSHA256: String
        ) throws {
            let values = [
                contextSHA256, transcriptSHA256, evidenceSHA256,
                workspaceBeforeSHA256, workspaceAfterSHA256,
            ]
            guard values.allSatisfy(Self.isSHA256) else {
                throw AgentHostedCanaryScorecardSinkError.invalidDigest
            }
            self.contextSHA256 = contextSHA256
            self.transcriptSHA256 = transcriptSHA256
            self.evidenceSHA256 = evidenceSHA256
            self.workspaceBeforeSHA256 = workspaceBeforeSHA256
            self.workspaceAfterSHA256 = workspaceAfterSHA256
        }

        private static func isSHA256(_ value: String) -> Bool {
            guard value.count == 71, value.hasPrefix("sha256:") else {
                return false
            }
            return value.dropFirst(7).utf8.allSatisfy {
                (48 ... 57).contains($0) || (97 ... 102).contains($0)
            }
        }
    }

    struct Timing: Codable, Equatable, Sendable {
        let acceptanceMs: Double
        let ttftMs: Double
        let totalMs: Double

        init(acceptanceMs: Double, ttftMs: Double, totalMs: Double) throws {
            guard [acceptanceMs, ttftMs, totalMs].allSatisfy({
                $0.isFinite && $0 >= 0
            }) else {
                throw AgentHostedCanaryScorecardSinkError.invalidMetric
            }
            self.acceptanceMs = acceptanceMs
            self.ttftMs = ttftMs
            self.totalMs = totalMs
        }
    }

    private struct Sample: Codable, Sendable {
        let pairID: String
        let engine: Engine
        let success: Bool
        let acceptanceMs: Double
        let ttftMs: Double
        let totalMs: Double
        let contextSHA256: String
        let transcriptSHA256: String
        let evidenceSHA256: String
        let workspaceBeforeSHA256: String
        let workspaceAfterSHA256: String
        let errorCategory: AgentErrorCategory?
    }

    private struct Payload: Codable, Sendable {
        let schemaVersion: Int
        let route: Route
        let samples: [Sample]
    }

    private let route: Route
    private var samples: [String: [Engine: Sample]] = [:]

    init(route: Route) {
        self.route = route
    }

    func record(
        pairID: String,
        engine: Engine,
        success: Bool,
        timing: Timing,
        digests: Digests,
        errorCategory: AgentErrorCategory? = nil
    ) throws {
        guard !pairID.isEmpty, pairID.utf8.count <= 128,
              !pairID.contains(where: \.isWhitespace) else {
            throw AgentHostedCanaryScorecardSinkError.invalidPairID
        }
        guard samples[pairID]?[engine] == nil else {
            throw AgentHostedCanaryScorecardSinkError.duplicateSample
        }
        samples[pairID, default: [:]][engine] = Sample(
            pairID: pairID,
            engine: engine,
            success: success,
            acceptanceMs: timing.acceptanceMs,
            ttftMs: timing.ttftMs,
            totalMs: timing.totalMs,
            contextSHA256: digests.contextSHA256,
            transcriptSHA256: digests.transcriptSHA256,
            evidenceSHA256: digests.evidenceSHA256,
            workspaceBeforeSHA256: digests.workspaceBeforeSHA256,
            workspaceAfterSHA256: digests.workspaceAfterSHA256,
            errorCategory: errorCategory
        )
    }

    func encodedMatched100PairPayload() throws -> Data {
        guard samples.count == route.sampleTarget,
              samples.values.allSatisfy({
                  Set($0.keys) == Set([Engine.v1, Engine.v2])
              }) else {
            throw AgentHostedCanaryScorecardSinkError.incompletePairs
        }
        let ordered = samples.keys.sorted().flatMap { pairID in
            [Engine.v1, .v2].compactMap { samples[pairID]?[$0] }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Payload(
            schemaVersion: 1,
            route: route,
            samples: ordered
        ))
    }
}

/// Builds the exact M5 OpenAI Chat Completions canary. Credential authority is
/// read only while preparing a newly reserved submission; it is never placed
/// in a blueprint, observable state, canonical event, or projection.
struct AgentHostedTextCanaryLiveFactory: Sendable {
    typealias CredentialReader = @Sendable () throws -> String?
    typealias Clock = @Sendable () -> AgentInstant

    private struct AuthorizedBlueprint {
        let blueprint: AgentHostedTextCanaryLiveBlueprint
        let credential: String
    }

    private let readCredential: CredentialReader
    private let now: Clock

    init(
        readCredential: @escaping CredentialReader = {
            try KeychainStore().read(AIProvider.openAI.apiKeyAccount)
        },
        now: @escaping Clock = { AgentInstant(Date()) }
    ) {
        self.readCredential = readCredential
        self.now = now
    }

    /// A no-I/O-beyond-credential-read seam for focused route, identity, and
    /// request-shape tests. Production uses `prepare`, which performs this same
    /// authorization once and keeps the credential private.
    func makeBlueprint(
        for request: AgentHostedTextCanaryLiveRequest
    ) throws -> AgentHostedTextCanaryLiveBlueprint {
        try authorize(request).blueprint
    }

    @MainActor
    func prepare(
        _ request: AgentHostedTextCanaryLiveRequest,
        container: ModelContainer
    ) throws -> AgentHostedTextCanaryPreparedRun {
        let authorized = try authorize(request)
        let blueprint = authorized.blueprint
        let store = SwiftDataAgentStore(container: container)
        let journal = try SwiftDataProjectedRunJournal(
            store: store,
            legacyAcceptanceProjection: blueprint.legacyAcceptanceProjection,
            executionComposition: blueprint.executionComposition
        )
        let projection: AgentHostedTextCanaryRunExecutor.Projection = { _ in
            _ = try await LegacyRunProjector(store: store)
                .projectAvailableEvents()
            _ = try await ProjectOSProjector(store: store)
                .projectAvailableEvents()
        }
        let executor: AgentHostedTextCanaryRunExecutor
        if request.routing.enabledFeatures.contains(.v2ReadTools) {
            let provider = try AgentHostedReadOnlyCanaryProvider
                .openAIChatCompletions(model: blueprint.providerRequest.model)
            let transport = AgentHostedProviderTransport(
                credential: authorized.credential,
                readOnlyToolsCapability: provider.capability
            )
            let backend = try AgentHostedReadOnlyCanaryBackend(
                workspace: request.workspace,
                workspaceIdentity: request.workspaceIdentity
            )
            executor = try AgentHostedTextCanaryRunExecutor(
                journal: journal,
                readOnlyProvider: provider,
                transport: transport,
                backend: backend,
                boundWorkspaceID: WorkspaceID(
                    rawValue: request.workspaceIdentity.persistentID
                ),
                projection: projection
            )
        } else {
            let provider = try AgentHostedTextCanaryProvider
                .openAIChatCompletions(model: blueprint.providerRequest.model)
            let transport = AgentHostedProviderTransport(
                credential: authorized.credential,
                capability: provider.capability
            )
            executor = AgentHostedTextCanaryRunExecutor(
                journal: journal,
                provider: provider,
                transport: transport,
                projection: projection
            )
        }

        return AgentHostedTextCanaryPreparedRun(
            blueprint: blueprint,
            operation: { didAccept in
                _ = try await executor.execute(
                    acceptance: blueprint.acceptance,
                    request: blueprint.providerRequest,
                    capturedContext: blueprint.capturedContext,
                    didAccept: didAccept
                )
            }
        )
    }

    private func authorize(
        _ request: AgentHostedTextCanaryLiveRequest
    ) throws -> AuthorizedBlueprint {
        try Self.validateRoute(request)
        try Self.validateRequest(request)

        let credential: String
        do {
            guard let value = try readCredential() else {
                throw AgentHostedTextCanaryLiveFactoryError.missingCredential
            }
            credential = value
        } catch let error as AgentHostedTextCanaryLiveFactoryError {
            throw error
        } catch {
            // Keychain status and storage details must not cross the canary's
            // user-facing failure boundary.
            throw AgentHostedTextCanaryLiveFactoryError.invalidCredential
        }
        guard Self.isValidCredential(credential) else {
            throw AgentHostedTextCanaryLiveFactoryError.invalidCredential
        }

        let acceptedAt = now()
        let identities = DeterministicIdentities(request: request)
        let readToolsEnabled = request.routing.enabledFeatures.contains(
            .v2ReadTools
        )
        let featureSet = readToolsEnabled
            ? AgentHostedReadOnlyCanaryCoordinator.featureSet
            : AgentHostedTextCanaryCoordinator.featureSet
        let context = AgentRunContext(
            schemaVersion: .v1_1,
            lineage: .root(identities.runID),
            conversationID: ConversationID(rawValue: request.conversationID),
            projectID: request.projectID.map(ProjectID.init(rawValue:)),
            workspaceID: WorkspaceID(
                rawValue: request.workspaceIdentity.persistentID
            ),
            executionNodeID: Self.onDeviceExecutionNodeID,
            engineVersion: AgentHostedTextCanaryCoordinator.engineVersion,
            acceptedAt: acceptedAt,
            features: featureSet,
            cancellation: CancellationLineage(
                scopeID: identities.cancellationScopeID
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
        let item = ModelItem(
            id: ModelItemID(rawValue: request.requestMessageID),
            createdAt: acceptedAt,
            payload: .message(ModelMessage(
                role: .user,
                content: [.text(request.prompt)]
            ))
        )
        let event = AgentEvent(
            header: AgentEventHeader(
                eventID: identities.acceptanceEventID,
                schemaVersion: context.schemaVersion,
                context: context,
                sequence: .first,
                timestamp: acceptedAt,
                causationID: nil,
                correlationID: identities.correlationID
            ),
            payload: .runAccepted(RunAcceptedEvent(
                context: context,
                acceptedEngineVersion: context.engineVersion,
                initialItems: [item]
            ))
        )
        let writerID = AgentEventWriterID(runID: identities.runID)
        let acceptance = AgentRunAcceptance(
            metadata: AgentRunMetadataRecord(
                context: context,
                acceptedEngineVersion: context.engineVersion,
                writerID: writerID,
                acceptanceCommandID: identities.acceptanceCommandID,
                acceptanceEventID: identities.acceptanceEventID
            ),
            envelope: AgentEventEnvelope(
                writerID: writerID,
                writerSequence: .first,
                idempotencyKey: "m5-live:accept:v1:\(identities.runID.description)",
                event: event
            )
        )
        let model = ProviderModelID(rawValue: request.modelID)
        let activeTools = readToolsEnabled
            ? SandboxToolCatalog.all.filter {
                $0.descriptor.effectClass == .readOnlyLocal
            }
            : []
        let toolRegistry = try ToolRegistry(tools: activeTools)
        let readOnlyDescriptors = toolRegistry.descriptors
        let readOnlyTools = readOnlyDescriptors.map {
            AgentHostedReadOnlyCanaryCoordinator.providerDefinition(
                for: $0
            )
        }
        let providerRequest = CanonicalProviderRequest(
            requestID: "m5-live:\(identities.runID.description):request",
            model: model,
            messages: request.capturedContext.providerMessages,
            tools: readOnlyTools,
            options: ProviderGenerationOptions(
                maximumOutputTokens: 4_096,
                temperature: request.temperature,
                parallelToolCalls: readToolsEnabled ? false : nil,
                toolChoice: readToolsEnabled ? .auto : .none,
                reasoningSummary: nil,
                promptCacheKey: nil,
                previousResponseID: nil,
                minimumContextWindowTokens: nil
            )
        )
        let providerRoute: ProviderRoute
        if readToolsEnabled {
            providerRoute = try AgentHostedReadOnlyCanaryProvider
                .openAIChatCompletions(model: model).route
        } else {
            providerRoute = try AgentHostedTextCanaryProvider
                .openAIChatCompletions(model: model).route
        }
        let executionComposition = try AgentRunExecutionComposition(
            context: context,
            providerRoute: providerRoute,
            providerOptions: providerRequest.options,
            toolRegistry: toolRegistry,
            toolLocalities: Dictionary(
                uniqueKeysWithValues: readOnlyDescriptors.map {
                    ($0.name, ToolExecutionLocality.onDevice)
                }
            ),
            policyVersion: readToolsEnabled
                ? "novaforge-policy-read-only-canary-v1"
                : "novaforge-policy-no-tools-v1",
            contextPreparationVersion: "provider-context-window-hosted-v1",
            systemInstruction: request.capturedContext.systemInstruction,
            developerInstruction: nil
        )
        let legacyProjection = SwiftDataLegacyAcceptanceProjection(
            runID: identities.runID.rawValue,
            conversationID: request.conversationID,
            projectID: request.projectID,
            workspaceID: request.workspaceIdentity.persistentID,
            workspaceName: request.workspaceName,
            requestMessageID: request.requestMessageID,
            requestText: request.prompt,
            origin: .user,
            providerRawValue: AIProvider.openAI.rawValue,
            modelID: request.modelID
        )

        return AuthorizedBlueprint(
            blueprint: AgentHostedTextCanaryLiveBlueprint(
                draftIdentity: request.draftIdentity,
                acceptance: acceptance,
                executionComposition: executionComposition,
                providerRequest: providerRequest,
                capturedContext: request.capturedContext,
                legacyAcceptanceProjection: legacyProjection
            ),
            credential: credential
        )
    }

    private static func validateRoute(
        _ request: AgentHostedTextCanaryLiveRequest
    ) throws {
        let textRoute = AgentRunRoutingMetadata(
            engineVersion: .v2,
            enabledFeatures: [.v2DarkReplay, .v2HostedText],
            executionNode: .onDevice,
            shadowMode: true
        )
        let readToolsRoute = AgentRunRoutingMetadata(
            engineVersion: .v2,
            enabledFeatures: [
                .v2DarkReplay,
                .v2HostedText,
                .v2ReadTools,
            ],
            executionNode: .onDevice,
            shadowMode: true
        )
        guard request.routing == textRoute ||
                request.routing == readToolsRoute else {
            throw AgentHostedTextCanaryLiveFactoryError.routeMismatch
        }
        guard request.selectedProvider == .openAI else {
            throw AgentHostedTextCanaryLiveFactoryError.providerMismatch
        }
    }

    private static func validateRequest(
        _ request: AgentHostedTextCanaryLiveRequest
    ) throws {
        guard !request.prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw AgentHostedTextCanaryLiveFactoryError.emptyPrompt
        }
        guard isSafeIdentity(request.modelID, maximumUTF8Count: 256) else {
            throw AgentHostedTextCanaryLiveFactoryError.invalidModel
        }
        guard request.temperature.isFinite,
              (0 ... 2).contains(request.temperature) else {
            throw AgentHostedTextCanaryLiveFactoryError.invalidTemperature
        }
    }

    private static func isValidCredential(_ credential: String) -> Bool {
        (1 ... 4_096).contains(credential.utf8.count) &&
            credential.unicodeScalars.allSatisfy {
                (0x21 ... 0x7e).contains($0.value)
            }
    }

    private static func isSafeIdentity(
        _ value: String,
        maximumUTF8Count: Int
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Count,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                !CharacterSet.controlCharacters.contains(scalar) &&
                scalar.properties.generalCategory != .format
        }
    }

    /// A fixed node identifies this process class, not one request. Run-scoped
    /// ownership remains in AgentEventWriterID and every other identity below.
    private static let onDeviceExecutionNodeID = ExecutionNodeID(
        rawValue: deterministicUUID(
            material: "novaforge-m5-live/on-device-execution-node/v1"
        )
    )

    private struct DeterministicIdentities {
        let runID: RunID
        let acceptanceCommandID: CommandID
        let acceptanceEventID: EventID
        let correlationID: CorrelationID
        let cancellationScopeID: CancellationScopeID

        init(request: AgentHostedTextCanaryLiveRequest) {
            let project = request.projectID?.uuidString.lowercased() ?? "general"
            let material = [
                "novaforge-m5-live-identity-v1",
                request.requestMessageID.uuidString.lowercased(),
                request.conversationID.uuidString.lowercased(),
                project,
                request.workspaceIdentity.persistentID.uuidString.lowercased(),
            ].joined(separator: "|")
            runID = RunID(rawValue: deterministicUUID(
                material: material + "|run"
            ))
            acceptanceCommandID = CommandID(rawValue: deterministicUUID(
                material: material + "|acceptance-command"
            ))
            acceptanceEventID = EventID(rawValue: deterministicUUID(
                material: material + "|acceptance-event"
            ))
            correlationID = CorrelationID(rawValue: deterministicUUID(
                material: material + "|correlation"
            ))
            cancellationScopeID = CancellationScopeID(rawValue: deterministicUUID(
                material: material + "|cancellation-scope"
            ))
        }
    }

    private static func deterministicUUID(material: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Root-owned lifecycle for the live canary. It publishes no provisional
/// provider text; Chat refreshes only the durable projections written by the
/// prepared operation.
@MainActor
@Observable
final class AgentHostedTextCanaryLiveSession {
    typealias Prepare = @MainActor () throws -> AgentHostedTextCanaryPreparedRun
    typealias DidAccept = @MainActor @Sendable (
        AgentHostedTextCanaryAcceptedDraftIdentity
    ) -> Void

    private(set) var phase: AgentHostedTextCanaryLivePhase = .idle
    private(set) var revision: UInt64 = 0
    private(set) var activeDraftIdentity: AgentHostedTextCanaryAcceptedDraftIdentity?
    private(set) var acceptedDraftIdentity: AgentHostedTextCanaryAcceptedDraftIdentity?
    private(set) var activeRunID: UUID?
    private(set) var lastNotice: AgentHostedTextCanaryLiveNotice?

    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var operationToken: UUID?

    var locksWorkspaceRouting: Bool { phase.locksWorkspaceRouting }
    /// Kept fail-closed for existing root predicates that spell their routing
    /// guard as `isBusy`. Recovery is not active work, but it still owns the
    /// exclusive run lane until reconciliation succeeds.
    var isBusy: Bool { locksWorkspaceRouting }

    @discardableResult
    func submit(
        request: AgentHostedTextCanaryLiveRequest,
        container: ModelContainer,
        factory: AgentHostedTextCanaryLiveFactory = .init(),
        didAccept: @escaping DidAccept = { _ in }
    ) -> AgentHostedTextCanaryLiveSubmissionDisposition {
        submit(
            draftIdentity: request.draftIdentity,
            prepare: { try factory.prepare(request, container: container) },
            didAccept: didAccept
        )
    }

    /// Dependency-injected entry used by tests and future recovery adapters.
    /// The phase flips before this method returns, so two sends in the same
    /// MainActor turn cannot both reach preparation or acceptance.
    @discardableResult
    func submit(
        draftIdentity: AgentHostedTextCanaryAcceptedDraftIdentity,
        prepare: @escaping Prepare,
        didAccept: @escaping DidAccept = { _ in }
    ) -> AgentHostedTextCanaryLiveSubmissionDisposition {
        if phase == .blockedRecovery { return .blockedRecovery }
        guard phase == .idle, currentTask == nil else { return .busy }

        let token = UUID()
        operationToken = token
        activeDraftIdentity = draftIdentity
        acceptedDraftIdentity = nil
        activeRunID = nil
        lastNotice = nil
        transition(to: .accepting)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let prepared = try prepare()
                guard prepared.draftIdentity == draftIdentity else {
                    throw AgentHostedTextCanaryLiveInvariantError
                        .preparedDraftIdentityMismatch
                }
                guard operationToken == token else { return }
                try Task.checkCancellation()
                activeRunID = prepared.blueprint.runID.rawValue
                revision &+= 1

                try await prepared.operation { [weak self] in
                    await self?.recordAccepted(
                        draftIdentity,
                        operationToken: token,
                        didAccept: didAccept
                    )
                }
                guard operationToken == token else { return }
                guard acceptedDraftIdentity != nil else {
                    throw AgentHostedTextCanaryLiveInvariantError
                        .operationReturnedBeforeAcceptance
                }
                finishUnlocked(
                    token: token,
                    notice: phase == .stopping ? .cancelled : nil
                )
            } catch {
                finish(token: token, error: error)
            }
        }
        currentTask = task
        return .reserved
    }

    func stop() {
        guard phase != .blockedRecovery, let currentTask else { return }
        if phase != .stopping { transition(to: .stopping) }
        currentTask.cancel()
    }

    /// Call only after launch/runtime recovery has reconciled the canonical
    /// journal and both projections. A UI dismissal alone must not unlock it.
    func markRecoveryCompleted() {
        guard phase == .blockedRecovery else { return }
        operationToken = nil
        currentTask = nil
        activeDraftIdentity = nil
        acceptedDraftIdentity = nil
        activeRunID = nil
        lastNotice = nil
        transition(to: .idle)
    }

    private func recordAccepted(
        _ identity: AgentHostedTextCanaryAcceptedDraftIdentity,
        operationToken token: UUID,
        didAccept: DidAccept
    ) {
        guard operationToken == token,
              acceptedDraftIdentity == nil,
              phase == .accepting || phase == .stopping else { return }
        acceptedDraftIdentity = identity
        if phase == .stopping {
            revision &+= 1
        } else {
            transition(to: .running)
        }
        didAccept(identity)
    }

    private func finish(token: UUID, error: Error) {
        guard operationToken == token else { return }
        if Self.requiresRecoveryBlock(error) ||
            (acceptedDraftIdentity != nil && !Self.isDurableTerminal(error)) {
            currentTask = nil
            lastNotice = .recoveryRequired
            transition(to: .blockedRecovery)
            return
        }

        let notice: AgentHostedTextCanaryLiveNotice?
        switch error {
        case let factoryError as AgentHostedTextCanaryLiveFactoryError:
            notice = Self.notice(for: factoryError)
        case is CancellationError:
            notice = phase == .stopping ? .cancelled : nil
        case let executorError as AgentHostedTextCanaryRunExecutorError:
            switch executorError {
            case .runCancelled:
                notice = .cancelled
            case .runFailed:
                notice = .runFailed
            case .acceptanceFailed, .duplicateAcceptance, .settlementFailed,
                 .projectionFailed:
                notice = .recoveryRequired
            }
        default:
            notice = .requestInvalid
        }
        finishUnlocked(token: token, notice: notice)
    }

    private func finishUnlocked(
        token: UUID,
        notice: AgentHostedTextCanaryLiveNotice?
    ) {
        guard operationToken == token else { return }
        operationToken = nil
        currentTask = nil
        activeDraftIdentity = nil
        acceptedDraftIdentity = nil
        activeRunID = nil
        lastNotice = notice
        transition(to: .idle)
    }

    private func transition(to next: AgentHostedTextCanaryLivePhase) {
        if phase != next { phase = next }
        revision &+= 1
    }

    private static func requiresRecoveryBlock(_ error: Error) -> Bool {
        guard let error = error as? AgentHostedTextCanaryRunExecutorError else {
            return error is AgentHostedTextCanaryLiveInvariantError
        }
        switch error {
        case .acceptanceFailed, .duplicateAcceptance, .settlementFailed,
             .projectionFailed:
            return true
        case .runFailed, .runCancelled:
            return false
        }
    }

    private static func isDurableTerminal(_ error: Error) -> Bool {
        guard let error = error as? AgentHostedTextCanaryRunExecutorError else {
            return false
        }
        switch error {
        case .runFailed, .runCancelled:
            return true
        case .acceptanceFailed, .duplicateAcceptance, .settlementFailed,
             .projectionFailed:
            return false
        }
    }

    private static func notice(
        for error: AgentHostedTextCanaryLiveFactoryError
    ) -> AgentHostedTextCanaryLiveNotice {
        switch error {
        case .routeMismatch, .providerMismatch:
            .routeUnavailable
        case .missingCredential:
            .credentialMissing
        case .invalidCredential:
            .credentialInvalid
        case .invalidModel, .invalidTemperature, .emptyPrompt,
             .toolBearingHistory, .contextNotRepresentable:
            .requestInvalid
        }
    }
}
#else
import Observation

/// Keeps AppRoot and Chat's stored input shape identical in Release while the
/// developer canary implementation and every activation route remain absent.
@MainActor
@Observable
final class AgentHostedTextCanaryLiveSession {}
#endif
