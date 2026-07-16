import AgentDomain
import AgentEngine
import AgentPolicy
import AgentProviders
import AgentStore
import AgentTools
import Foundation
import SwiftData

enum AgentSystemProductionCompositionError: Error, Equatable, Sendable {
    case invalidFreshRequest
    case missingFreshRunPlan
    case runContextMismatch
    case unsupportedProviderRoute
    case providerRouteMismatch
    case providerOptionsMismatch
    case toolRegistryMismatch
    case toolLocalityMismatch
    case workspaceUnavailable
    case workspaceIdentityMismatch
    case settingsUnavailable
    case projectUnavailable
    case runProjectionUnavailable
    case instructionConfigurationMismatch
    case credentialUnavailable
    case policyCompositionUnavailable
    case recoveryCompositionUnavailable
}

/// Non-authorizing runtime values that cannot be reconstructed from the
/// credential-free acceptance composition alone. The resolver never supplies a
/// route, tool catalog, policy version, or execution owner; those authorities
/// are rebuilt and checked by the production engine builder.
struct AgentSystemResolvedRunEnvironment: Sendable {
    let workspace: SandboxWorkspace
    let systemInstruction: String?
    let developerInstruction: String?
    let hostedCredential: String?
}

protocol AgentSystemRunEnvironmentResolving: Sendable {
    func resolveFreshEnvironment(
        context: AgentRunContext,
        providerRoute: ProviderRoute
    ) async throws -> AgentSystemResolvedRunEnvironment

    func resolveRecoveryEnvironment(
        context: AgentRunContext,
        providerRoute: ProviderRoute
    ) async throws -> AgentSystemResolvedRunEnvironment
}

/// SwiftData/Keychain implementation used by the iOS process. Every method
/// creates a private non-autosaving context and returns only copyable values.
/// Recovery resolves the accepted workspace name from the immutable legacy run
/// receipt rather than from the user's current workspace selection.
actor SwiftDataAgentSystemRunEnvironmentResolver:
    AgentSystemRunEnvironmentResolving
{
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func resolveFreshEnvironment(
        context: AgentRunContext,
        providerRoute: ProviderRoute
    ) throws -> AgentSystemResolvedRunEnvironment {
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        let settings = try requireSettings(in: modelContext)
        let workspaceName: String
        if let projectID = context.projectID?.rawValue {
            var descriptor = FetchDescriptor<Project>(
                predicate: #Predicate { $0.id == projectID }
            )
            descriptor.fetchLimit = 2
            let projects = try modelContext.fetch(descriptor)
            guard projects.count == 1 else {
                throw AgentSystemProductionCompositionError
                    .projectUnavailable
            }
            workspaceName = projects[0].workspaceName
        } else {
            workspaceName = settings.activeWorkspaceName
        }
        return try makeEnvironment(
            workspaceName: workspaceName,
            context: context,
            providerRoute: providerRoute,
            settings: settings
        )
    }

    func resolveRecoveryEnvironment(
        context: AgentRunContext,
        providerRoute: ProviderRoute
    ) throws -> AgentSystemResolvedRunEnvironment {
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        let settings = try requireSettings(in: modelContext)
        let runUUID = context.lineage.runID.rawValue
        var descriptor = FetchDescriptor<AgentRunRecord>(
            predicate: #Predicate { $0.id == runUUID }
        )
        descriptor.fetchLimit = 2
        let runs = try modelContext.fetch(descriptor)
        guard runs.count == 1,
              let workspaceName = runs[0].workspaceName,
              !workspaceName.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            throw AgentSystemProductionCompositionError
                .runProjectionUnavailable
        }
        return try makeEnvironment(
            workspaceName: workspaceName,
            context: context,
            providerRoute: providerRoute,
            settings: settings
        )
    }

    private func requireSettings(
        in context: ModelContext
    ) throws -> AgentSettings {
        var descriptor = FetchDescriptor<AgentSettings>()
        descriptor.fetchLimit = 2
        let settings = try context.fetch(descriptor)
        guard settings.count == 1 else {
            throw AgentSystemProductionCompositionError.settingsUnavailable
        }
        return settings[0]
    }

    private func makeEnvironment(
        workspaceName: String,
        context: AgentRunContext,
        providerRoute: ProviderRoute,
        settings: AgentSettings
    ) throws -> AgentSystemResolvedRunEnvironment {
        let workspace = SandboxWorkspace(name: workspaceName)
        let identity: WorkspaceResourceIdentity
        do {
            identity = try WorkspaceResourceIdentity(workspace: workspace)
        } catch {
            throw AgentSystemProductionCompositionError.workspaceUnavailable
        }
        guard WorkspaceID(rawValue: identity.persistentID) ==
                context.workspaceID
        else {
            throw AgentSystemProductionCompositionError
                .workspaceIdentityMismatch
        }

        let credential: String?
        switch providerRoute.provenance {
        case .builtInOpenAIChatCompletions:
            #if DEBUG
            let launchArguments = ProcessInfo.processInfo.arguments
            if launchArguments.contains("--debug-provider-send-ready") ||
                launchArguments.contains("--debug-provider-send-fails") ||
                launchArguments.contains("--debug-provider-list-ready") ||
                launchArguments.contains("--simulate-network-failure") {
                // The canonical UI-test transport is process-local and never
                // sends this value over the network. Avoid making its startup
                // depend on simulator Keychain entitlement timing while still
                // exercising the real accepted-run composition and route.
                credential = "debug-provider-key"
                break
            }
            #endif
            do {
                credential = try KeychainStore().read(
                    AIProvider.openAI.apiKeyAccount
                )
            } catch {
                throw AgentSystemProductionCompositionError
                    .credentialUnavailable
            }
        case .builtInOpenCodeZenChatCompletions:
            do {
                credential = try KeychainStore().read(
                    AIProvider.openCodeZen.apiKeyAccount
                )
            } catch {
                throw AgentSystemProductionCompositionError
                    .credentialUnavailable
            }
        case .builtInOpenAICodexResponses:
            do {
                credential = try KeychainStore().read(
                    AIProvider.openAICodex.apiKeyAccount
                )
            } catch {
                throw AgentSystemProductionCompositionError
                    .credentialUnavailable
            }
        case .builtInLocalModel:
            credential = nil
        default:
            throw AgentSystemProductionCompositionError
                .unsupportedProviderRoute
        }

        return AgentSystemResolvedRunEnvironment(
            workspace: workspace,
            systemInstruction: settings.customSystemPrompt,
            developerInstruction: nil,
            hostedCredential: credential
        )
    }
}

/// Builds exactly one package engine for one `AgentSystem` registry entry. The
/// shared store/index are process authorities; every other dependency is
/// rebuilt from immutable run identity and checked against acceptance state.
struct AgentSystemProductionEngineBuilder: Sendable {
    let store: SwiftDataAgentStore
    let runIndex: DurableAgentEngineRunIndex
    let environmentResolver: any AgentSystemRunEnvironmentResolving
    let liveOutputSink: any AgentLiveOutputSink

    init(
        store: SwiftDataAgentStore,
        runIndex: DurableAgentEngineRunIndex,
        environmentResolver: any AgentSystemRunEnvironmentResolving,
        liveOutputSink: any AgentLiveOutputSink = NoopAgentLiveOutputSink()
    ) {
        self.store = store
        self.runIndex = runIndex
        self.environmentResolver = environmentResolver
        self.liveOutputSink = liveOutputSink
    }

    func makeEngine(
        for request: AgentSystemEngineBuildRequest
    ) async throws -> AgentEngine {
        switch request {
        case let .fresh(context, command, plan):
            guard let plan else {
                throw AgentSystemProductionCompositionError
                    .missingFreshRunPlan
            }
            return try await makeFreshEngine(
                context: context,
                command: command,
                plan: plan
            )
        case let .recovery(runID):
            return try await makeRecoveryEngine(runID: runID)
        }
    }

    private func makeFreshEngine(
        context: AgentRunContext,
        command: AgentCommand,
        plan: AgentSystemFreshRunPlan
    ) async throws -> AgentEngine {
        guard command.header.runID == context.lineage.runID,
              command.header.schemaVersion == context.schemaVersion,
              case let .send(send) = command.payload,
              send.context == context,
              context.engineVersion == .agentHarnessV2
        else {
            throw AgentSystemProductionCompositionError.invalidFreshRequest
        }

        let environment = try await environmentResolver
            .resolveFreshEnvironment(
                context: context,
                providerRoute: plan.providerRoute
            )
        guard environment.systemInstruction == plan.systemInstruction,
              environment.developerInstruction == plan.developerInstruction
        else {
            throw AgentSystemProductionCompositionError
                .instructionConfigurationMismatch
        }

        let runtime = try await makeRuntime(
            context: context,
            providerRoute: plan.providerRoute,
            providerOptions: plan.providerOptions,
            requestedToolLocalities: plan.toolLocalities,
            policyVersion: plan.policyVersion,
            contextPreparationVersion: plan.contextPreparationVersion,
            environment: environment
        )
        let composition = try AgentRunExecutionComposition(
            context: context,
            providerRoute: plan.providerRoute,
            providerOptions: plan.providerOptions,
            toolRegistry: runtime.toolRegistry,
            toolLocalities: runtime.toolLocalities,
            policyVersion: plan.policyVersion,
            contextPreparationVersion: plan.contextPreparationVersion,
            systemInstruction: plan.systemInstruction,
            developerInstruction: plan.developerInstruction
        )
        let projection = try Self.legacyProjection(
            command: command,
            environment: environment,
            providerRoute: plan.providerRoute,
            origin: plan.origin,
            publicRequestSummary: plan.publicRequestSummary
        )
        let journal = try SwiftDataProjectedRunJournal(
            store: store,
            legacyAcceptanceProjection: projection,
            executionComposition: composition
        )
        return makeEngine(journal: journal, runtime: runtime)
    }

    private func makeRecoveryEngine(runID: RunID) async throws -> AgentEngine {
        guard let record = try await store.acceptedRunRecoveryRecord(
            for: runID
        ) else {
            throw AgentSystemProductionCompositionError
                .recoveryCompositionUnavailable
        }
        let context = record.metadata.context
        let composition = record.executionComposition
        guard context.lineage.runID == runID,
              composition.runID == runID
        else {
            throw AgentSystemProductionCompositionError.runContextMismatch
        }
        let options = composition.providerOptions.providerGenerationOptions
        let environment = try await environmentResolver
            .resolveRecoveryEnvironment(
                context: context,
                providerRoute: composition.providerRoute
            )
        let runtime = try await makeRuntime(
            context: context,
            providerRoute: composition.providerRoute,
            providerOptions: options,
            requestedToolLocalities: nil,
            policyVersion: AgentPolicyEngineMutationAdapter.policyVersion,
            contextPreparationVersion: AgentCanonicalContextPreparer.version,
            environment: environment
        )
        let binding = AgentRunExecutionRuntimeBinding(
            providerRoute: composition.providerRoute,
            providerOptions: options,
            toolRegistry: runtime.toolRegistry,
            toolLocalities: runtime.toolLocalities,
            policyVersion: AgentPolicyEngineMutationAdapter.policyVersion,
            contextPreparationVersion: AgentCanonicalContextPreparer.version,
            systemInstruction: environment.systemInstruction,
            developerInstruction: environment.developerInstruction
        )
        let journal = try await SwiftDataProjectedRunJournal.recovering(
            store: store,
            runID: runID,
            runtimeBinding: binding
        )
        return makeEngine(journal: journal, runtime: runtime)
    }

    private struct Runtime: Sendable {
        let providerGateway: ModelGateway
        let toolRegistry: ToolRegistry
        let toolLocalities: [String: ToolExecutionLocality]
        let contextPreparer: AgentCanonicalContextPreparer
        let readExecutor: AgentSandboxReadOnlyToolExecutor
        let mutationAdapter: AgentPolicyEngineMutationAdapter
    }

    private func makeRuntime(
        context: AgentRunContext,
        providerRoute: ProviderRoute,
        providerOptions: ProviderGenerationOptions,
        requestedToolLocalities: [String: ToolExecutionLocality]?,
        policyVersion: String,
        contextPreparationVersion: String,
        environment: AgentSystemResolvedRunEnvironment
    ) async throws -> Runtime {
        guard policyVersion == AgentPolicyEngineMutationAdapter.policyVersion,
              contextPreparationVersion ==
                AgentCanonicalContextPreparer.version
        else {
            throw AgentSystemProductionCompositionError
                .runContextMismatch
        }

        let provider = try Self.providerGateway(
            route: providerRoute,
            hostedCredential: environment.hostedCredential,
            workspace: environment.workspace
        )
        let toolRegistry: ToolRegistry
        switch provider.selection.lane {
        case .hostedOpenAIChatCompletions, .hostedOpenAICodexResponses,
             .hostedOpenCodeZenChatCompletions:
            toolRegistry = try SandboxToolCatalog.canonicalRegistry()
        case .localSingleCallTools:
            toolRegistry = try SandboxToolCatalog.localAgentRegistry()
        case .localTextOnly:
            toolRegistry = try ToolRegistry(tools: [])
        }
        let currentLocalities = try Self.currentToolLocalities(
            for: toolRegistry
        )
        let localities = requestedToolLocalities ?? currentLocalities
        guard localities == currentLocalities else {
            throw AgentSystemProductionCompositionError
                .toolLocalityMismatch
        }

        let contextPreparer = try AgentCanonicalContextPreparer(
            configuration: AgentCanonicalContextConfiguration(
                context: context,
                providerID: providerRoute.providerID,
                model: providerRoute.modelID,
                preferredAdapterIDs: [providerRoute.adapterID],
                options: providerOptions,
                systemInstruction: environment.systemInstruction,
                developerInstruction: environment.developerInstruction,
                toolLocalities: localities
            )
        )
        let readExecutor = try AgentSandboxReadOnlyToolExecutor(
            workspace: environment.workspace,
            projectID: context.projectID
        )

        let workspaceBinding = try AgentPolicyWorkspaceBinding(
            workspace: environment.workspace
        )
        guard workspaceBinding.workspaceID == context.workspaceID else {
            throw AgentSystemProductionCompositionError
                .workspaceIdentityMismatch
        }
        let promptCenter = await MainActor.run {
            AgentApprovalPromptCenter.shared
        }
        let policySystem: AgentPolicySystem
        do {
            policySystem = try AgentPolicySystem.productionPOSIX(
                configuration: AgentPolicyMutationCoordinator
                    .failClosedConfiguration(),
                workspaceBinding: workspaceBinding,
                approvalPrompt: promptCenter
            )
        } catch {
            throw AgentSystemProductionCompositionError
                .policyCompositionUnavailable
        }
        let mutationAdapter: AgentPolicyEngineMutationAdapter
        do {
            mutationAdapter = try await MainActor.run {
                try AgentPolicyEngineMutationAdapter.production(
                    system: policySystem,
                    promptCenter: promptCenter
                )
            }
        } catch {
            throw AgentSystemProductionCompositionError
                .policyCompositionUnavailable
        }

        return Runtime(
            providerGateway: try provider.modelGateway(
                for: provider.selection
            ),
            toolRegistry: toolRegistry,
            toolLocalities: localities,
            contextPreparer: contextPreparer,
            readExecutor: readExecutor,
            mutationAdapter: mutationAdapter
        )
    }

    private func makeEngine(
        journal: SwiftDataProjectedRunJournal,
        runtime: Runtime
    ) -> AgentEngine {
        AgentEngine(
            journal: journal,
            providerGateway: runtime.providerGateway,
            toolRegistry: runtime.toolRegistry,
            contextPreparer: runtime.contextPreparer,
            readOnlyExecutor: runtime.readExecutor,
            mutationExecutor: runtime.mutationAdapter,
            approvalResolver: runtime.mutationAdapter,
            runIndex: runIndex,
            liveOutputSink: liveOutputSink
        )
    }

    private static func providerGateway(
        route: ProviderRoute,
        hostedCredential: String?,
        workspace: SandboxWorkspace
    ) throws -> AgentProductionProviderGatewayBundle {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let usesCanonicalDebugTransport =
            arguments.contains("--debug-provider-send-ready") ||
            arguments.contains("--debug-provider-send-fails") ||
            arguments.contains("--debug-provider-list-ready") ||
            arguments.contains("--simulate-network-failure")
        if route.provenance == .builtInOpenAIChatCompletions,
           usesCanonicalDebugTransport {
            let selection = try AgentProductionProviderRouteSelection
                .hostedOpenAIChatCompletions(modelID: route.modelID)
            guard selection.declaredDescriptor.route == route else {
                throw AgentSystemProductionCompositionError
                    .providerRouteMismatch
            }
            return try AgentProductionProviderGatewayFactory
                .debugHostedOpenAIChatCompletions(
                    selection: selection,
                    transport: AgentCanonicalDebugProviderTransport(
                        shouldFail: arguments.contains(
                            "--debug-provider-send-fails"
                        ),
                        responseChunks: (
                            arguments.contains("--debug-provider-list-ready") ||
                            arguments.contains("--simulate-network-failure")
                        ) ? ["Workspace scan finished."] : nil
                    )
                )
        }
        #endif
        switch route.provenance {
        case .builtInOpenAIChatCompletions:
            let selection = try AgentProductionProviderRouteSelection
                .hostedOpenAIChatCompletions(modelID: route.modelID)
            guard selection.declaredDescriptor.route == route,
                  let hostedCredential
            else {
                throw AgentSystemProductionCompositionError
                    .providerRouteMismatch
            }
            return try AgentProductionProviderGatewayFactory
                .hostedOpenAIChatCompletions(
                    selection: selection,
                    credential: hostedCredential
                )
        case .builtInOpenCodeZenChatCompletions:
            let selection = try AgentProductionProviderRouteSelection
                .hostedOpenCodeZenChatCompletions(modelID: route.modelID)
            guard selection.declaredDescriptor.route == route,
                  let hostedCredential
            else {
                throw AgentSystemProductionCompositionError
                    .providerRouteMismatch
            }
            return try AgentProductionProviderGatewayFactory
                .hostedOpenCodeZenChatCompletions(
                    selection: selection,
                    credential: hostedCredential
                )
        case .builtInOpenAICodexResponses:
            let selection = try AgentProductionProviderRouteSelection
                .hostedOpenAICodexResponses(modelID: route.modelID)
            guard selection.declaredDescriptor.route == route,
                  let hostedCredential
            else {
                throw AgentSystemProductionCompositionError
                    .providerRouteMismatch
            }
            return try AgentProductionProviderGatewayFactory
                .hostedOpenAICodexResponses(
                    selection: selection,
                    credential: hostedCredential
                )
        case .builtInLocalModel:
            let selection = try AgentProductionProviderRouteSelection
                .localSingleCallTools(modelID: route.modelID)
            guard selection.declaredDescriptor.route == route else {
                throw AgentSystemProductionCompositionError
                    .providerRouteMismatch
            }
            return try AgentProductionProviderGatewayFactory
                .localSingleCallTools(
                    selection: selection,
                    workspace: workspace
                )
        default:
            throw AgentSystemProductionCompositionError
                .unsupportedProviderRoute
        }
    }

    private static func currentToolLocalities(
        for registry: ToolRegistry
    ) throws -> [String: ToolExecutionLocality] {
        var result: [String: ToolExecutionLocality] = [:]
        for descriptor in registry.descriptors {
            guard descriptor.availability.allowedLocalities.contains(
                .onDevice
            ) || descriptor.availability.allowedLocalities.contains(.either)
            else {
                throw AgentSystemProductionCompositionError
                    .toolRegistryMismatch
            }
            guard result.updateValue(.onDevice, forKey: descriptor.name) == nil
            else {
                throw AgentSystemProductionCompositionError
                    .toolRegistryMismatch
            }
        }
        return result
    }

    /// Pure acceptance mapper kept internal so the composition boundary can be
    /// regression-tested without constructing a provider or policy runtime.
    static func legacyProjection(
        command: AgentCommand,
        environment: AgentSystemResolvedRunEnvironment,
        providerRoute: ProviderRoute,
        origin: AgentRunRecordOrigin,
        publicRequestSummary: String?
    ) throws -> SwiftDataLegacyAcceptanceProjection {
        guard case let .send(send) = command.payload,
              case let .message(message) = send.userItem.payload,
              message.role == .user,
              message.content.count == 1,
              case let .text(text) = message.content[0]
        else {
            throw AgentSystemProductionCompositionError.invalidFreshRequest
        }
        return SwiftDataLegacyAcceptanceProjection(
            runID: send.context.lineage.runID.rawValue,
            conversationID: send.context.conversationID.rawValue,
            projectID: send.context.projectID?.rawValue,
            workspaceID: send.context.workspaceID.rawValue,
            workspaceName: environment.workspace.workspaceName,
            requestMessageID: send.userItem.id.rawValue,
            acceptedRequestText: text,
            requestText: publicRequestSummary ?? text,
            origin: origin,
            providerRawValue: try legacyProviderRawValue(
                for: providerRoute
            ),
            modelID: providerRoute.modelID.rawValue
        )
    }

    /// Canonical provider IDs are transport authorities, not persistence/UI
    /// enum raw values. Keep the translation explicit so a valid Local, Zen,
    /// or ChatGPT subscription run cannot be rejected by the legacy receipt
    /// projection before the provider is ever invoked.
    static func legacyProviderRawValue(
        for route: ProviderRoute
    ) throws -> String {
        switch route.provenance {
        case .builtInOpenAIChatCompletions:
            return AIProvider.openAI.rawValue
        case .builtInOpenCodeZenChatCompletions:
            return AIProvider.openCodeZen.rawValue
        case .builtInOpenAICodexResponses:
            return AIProvider.openAICodex.rawValue
        case .builtInLocalModel:
            return AIProvider.local.rawValue
        default:
            throw AgentSystemProductionCompositionError
                .unsupportedProviderRoute
        }
    }
}

#if DEBUG
/// Deterministic transport for end-to-end UI proof of the canonical engine.
/// It never ships in release builds and it cannot replace route authority.
private actor AgentCanonicalDebugProviderTransport: ProviderTransport {
    private let shouldFail: Bool
    private let responseChunks: [String]?

    init(shouldFail: Bool, responseChunks: [String]? = nil) {
        self.shouldFail = shouldFail
        self.responseChunks = responseChunks
    }

    func stream(
        request _: ProviderEncodedRequest,
        descriptor: ProviderAdapterDescriptor,
        scope _: ProviderAttemptScope
    ) async throws -> AsyncThrowingStream<ProviderWireFrame, any Error> {
        if shouldFail {
            throw ProviderFailureMapper.transportFailure(
                providerID: descriptor.route.providerID,
                adapterID: descriptor.route.adapterID
            )
        }
        let model = descriptor.route.modelID.rawValue
        let defaultChunks = [
            "Hey! I’m on it. ",
            "I can inspect the workspace, read the relevant files, ",
            "make a focused change, run the checks, and return proof. ",
            "This response is streaming through one stable assistant turn ",
            "so the settled text stays calm while the live edge moves. ",
            "The activity rail stays compact while work is live, ",
            "the composer remains usable and readable below it, ",
            "and the final handoff replaces this live surface exactly once.",
        ]
        let chunks = responseChunks ?? defaultChunks
        return AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in chunks {
                    guard !Task.isCancelled else {
                        continuation.finish()
                        return
                    }
                    continuation.yield(Self.chatFrame(
                        model: model,
                        content: chunk,
                        finishReason: nil
                    ))
                    try? await Task.sleep(for: .milliseconds(400))
                }
                continuation.yield(Self.chatFrame(
                    model: model,
                    content: nil,
                    finishReason: "stop"
                ))
                continuation.yield(.json(.object([
                    "id": .string("novaforge-ui-fixture"),
                    "model": .string(model),
                    "choices": .array([]),
                    "usage": .object([
                        "prompt_tokens": .number(.integer(12)),
                        "completion_tokens": .number(.integer(42)),
                    ]),
                ])))
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func chatFrame(
        model: String,
        content: String?,
        finishReason: String?
    ) -> ProviderWireFrame {
        var delta: [String: JSONValue] = [:]
        if let content { delta["content"] = .string(content) }
        return .json(.object([
            "id": .string("novaforge-ui-fixture"),
            "model": .string(model),
            "choices": .array([.object([
                "index": .number(.integer(0)),
                "delta": .object(delta),
                "finish_reason": finishReason.map(JSONValue.string) ?? .null,
            ])]),
        ]))
    }
}
#endif

private extension AgentRunProviderOptions {
    var providerGenerationOptions: ProviderGenerationOptions {
        ProviderGenerationOptions(
            maximumOutputTokens: maximumOutputTokens,
            temperature: temperature,
            parallelToolCalls: parallelToolCalls,
            toolChoice: toolChoice,
            reasoningSummary: reasoningSummary,
            reasoningEffort: reasoningEffort,
            promptCacheKey: nil,
            previousResponseID: nil,
            minimumContextWindowTokens: minimumContextWindowTokens
        )
    }
}

enum AgentSystemProductionCompositionFactory {
    @MainActor
    static func make(
        container: ModelContainer
    ) async throws -> AgentSystemProductionComposition {
        let store = SwiftDataAgentStore(container: container)
        let runIndex = try DurableAgentEngineRunIndex.production()
        let leadership = try await ProductionAgentRecoveryLeadershipLeaseAcquirer()
            .acquireProcessLifetimeLease()
        let scanner = try AgentAcceptedRunRecoveryScanner(
            swiftDataStore: store
        )
        let reconciler = AgentRunRecoveryReconciler(
            scanner: scanner,
            index: runIndex,
            recoveryOwnerID: UUID(),
            leadershipLease: leadership
        )
        let builder = AgentSystemProductionEngineBuilder(
            store: store,
            runIndex: runIndex,
            environmentResolver:
                SwiftDataAgentSystemRunEnvironmentResolver(
                    container: container
                ),
            liveOutputSink: AgentSystemLiveOutputCenter.shared
        )
        return AgentSystemProductionComposition(
            id: UUID(),
            engineFactory: AgentSystemEngineFactory(
                buildAgentEngine: { request in
                    try await builder.makeEngine(for: request)
                }
            ),
            recoveryQueuePreparer: reconciler
        )
    }
}
