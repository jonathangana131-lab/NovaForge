import AgentDomain
import AgentProviders
import AgentTools
import Foundation

/// The complete immutable input handed to `AgentSystem` for one newly
/// accepted run. Keeping the command and plan together prevents a caller from
/// independently constructing identities and then pairing them with a
/// different provider/tool configuration.
struct AgentSystemFreshRunRequest: Equatable, Sendable {
    let command: AgentCommand
    let plan: AgentSystemFreshRunPlan
}

enum AgentSystemFreshRunRequestFactoryError: Error, Equatable, Sendable {
    case conversationProjectMismatch
    case invalidWorkspaceSelection
    case workspaceIdentityUnavailable
    case workspaceIdentityMismatch
    case unsupportedProvider
    case unsupportedModel
    case invalidTemperature
    case providerAuthorityUnavailable
    case toolRegistryUnavailable
    case toolRegistryMismatch
    case invalidSystemInstruction
    case invalidPublicRequestSummary
    case invalidGenerationConfiguration
    case commandConstructionMismatch
}

/// The only production constructor for a fresh V2 command/plan pair.
///
/// Callers supply user and UI scope values, but no provider descriptor, tool
/// registry, tool locality, feature set, execution node, policy version, or
/// context-preparation version. Those authorities are rebuilt here from the
/// app/package-owned catalogs and bound into one immutable result.
@MainActor
enum AgentSystemFreshRunRequestFactory {
    static let hostedStandardFeatures = AgentFeatureSet([
        "v2HostedText",
        "v2MutationTools",
        "v2ReadTools",
    ])
    static let localAgentStandardFeatures = AgentFeatureSet([
        "v2Local",
        "v2MutationTools",
        "v2ReadTools",
    ])
    // Source-compatible name for persisted/test fixtures from the text-only
    // rollout. Its value now describes the production local agent lane.
    static let localTextOnlyStandardFeatures = localAgentStandardFeatures
    static let standardBudget = AgentBudget(limits: .standard)

    static func make(
        prompt: String,
        conversation: Conversation,
        project: Project?,
        workspace: SandboxWorkspace,
        settings: AgentSettings,
        publicRequestSummary: String? = nil,
        identity: AgentFreshSendCommandIdentity = .fresh(),
        lineage: AgentRunLineage? = nil,
        origin: AgentRunRecordOrigin = .user,
        acceptedAt: AgentInstant = AgentInstant(Date())
    ) throws -> AgentSystemFreshRunRequest {
        try validateProjectScope(conversation: conversation, project: project)
        let workspaceIdentity = try validatedWorkspaceIdentity(
            workspace: workspace,
            expectedName: project?.workspaceName ?? settings.activeWorkspaceName
        )
        let provider = try validatedProvider(settings)
        let selection = try providerSelection(
            provider: provider,
            modelID: settings.modelID
        )
        let route = selection.declaredDescriptor.route
        let toolLocalities = try canonicalToolLocalities(
            provider: provider,
            route: route
        )
        let preferences = AgentRunPreferenceStore.shared
        let orchestrationMode = preferences.orchestrationMode
        let reasoningEffort = preferences.effectiveReasoningEffort(
            provider: provider,
            modelID: settings.modelID
        )
        let options = try generationOptions(
            provider: provider,
            route: route,
            temperature: settings.temperature,
            reasoningEffort: reasoningEffort
        )
        let providerFeatures = switch provider {
        case .openAI, .openAICodex, .openCodeZen:
            hostedStandardFeatures
        case .local:
            localAgentStandardFeatures
        default:
            // `validatedProvider` rejects every other case before authority is
            // reconstructed. Keep the switch exhaustive and fail closed if a
            // future edit accidentally bypasses that boundary.
            throw AgentSystemFreshRunRequestFactoryError.unsupportedProvider
        }
        let orchestrationFeatures: [String] = switch orchestrationMode {
        case .standard: []
        case .ultra: ["v2UltraOrchestration"]
        case .ultraCode: ["v2UltraCodeOrchestration", "v2IsolatedAgentWorkspaces"]
        }
        let features = AgentFeatureSet(
            providerFeatures.values + orchestrationFeatures
        )
        if let publicRequestSummary {
            guard !publicRequestSummary.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
                publicRequestSummary.utf8.count <= 4_096,
                !publicRequestSummary.utf8.contains(0) else {
                throw AgentSystemFreshRunRequestFactoryError
                    .invalidPublicRequestSummary
            }
        }

        let command = try AgentSystemCommandFactory.send(
            AgentFreshSendCommandRequest(
                identity: identity,
                conversationID: ConversationID(rawValue: conversation.id),
                projectID: project.map { ProjectID(rawValue: $0.id) },
                workspaceID: WorkspaceID(
                    rawValue: workspaceIdentity.persistentID
                ),
                executionNodeID:
                    AgentPolicyMutationRuntime.shared.executionNodeID,
                prompt: prompt,
                acceptedAt: acceptedAt,
                features: features,
                budget: standardBudget,
                lineage: lineage
            )
        )
        guard case let .send(send) = command.payload,
              command.header.runID == send.context.lineage.runID
        else {
            throw AgentSystemFreshRunRequestFactoryError
                .commandConstructionMismatch
        }

        let plan = AgentSystemFreshRunPlan(
            providerRoute: route,
            providerOptions: options,
            systemInstruction: settings.customSystemPrompt,
            developerInstruction: nil,
            publicRequestSummary: publicRequestSummary,
            toolLocalities: toolLocalities,
            policyVersion: AgentPolicyEngineMutationAdapter.policyVersion,
            contextPreparationVersion: AgentCanonicalContextPreparer.version,
            origin: origin
        )
        try validateCanonicalConfiguration(
            context: send.context,
            plan: plan
        )
        return AgentSystemFreshRunRequest(command: command, plan: plan)
    }
}

private extension AgentSystemFreshRunRequestFactory {
    static func validateProjectScope(
        conversation: Conversation,
        project: Project?
    ) throws {
        switch (conversation.project, project) {
        case (nil, nil):
            return
        case let (conversationProject?, requestedProject?)
        where conversationProject.id == requestedProject.id &&
            conversationProject.workspaceName == requestedProject.workspaceName:
            return
        default:
            throw AgentSystemFreshRunRequestFactoryError
                .conversationProjectMismatch
        }
    }

    static func validatedWorkspaceIdentity(
        workspace: SandboxWorkspace,
        expectedName: String
    ) throws -> WorkspaceResourceIdentity {
        guard !expectedName.isEmpty,
              expectedName == SandboxWorkspace.sanitizedWorkspaceName(
                  expectedName
              ),
              workspace.workspaceName == expectedName
        else {
            throw AgentSystemFreshRunRequestFactoryError
                .invalidWorkspaceSelection
        }

        let suppliedIdentity: WorkspaceResourceIdentity
        let expectedIdentity: WorkspaceResourceIdentity
        do {
            suppliedIdentity = try WorkspaceResourceIdentity(
                workspace: workspace
            )
            expectedIdentity = try WorkspaceResourceIdentity(
                workspace: SandboxWorkspace(name: expectedName)
            )
        } catch {
            throw AgentSystemFreshRunRequestFactoryError
                .workspaceIdentityUnavailable
        }
        guard suppliedIdentity == expectedIdentity else {
            throw AgentSystemFreshRunRequestFactoryError
                .workspaceIdentityMismatch
        }
        return suppliedIdentity
    }

    static func validatedProvider(
        _ settings: AgentSettings
    ) throws -> AIProvider {
        guard let rawProvider = settings.providerRawValue,
              let provider = AIProvider(rawValue: rawProvider),
              provider.rawValue == rawProvider,
              AIProvider.agentRuntimeProviders.contains(provider)
        else {
            throw AgentSystemFreshRunRequestFactoryError.unsupportedProvider
        }
        return provider
    }

    static func providerSelection(
        provider: AIProvider,
        modelID: String
    ) throws -> AgentProductionProviderRouteSelection {
        guard !modelID.isEmpty,
              modelID == modelID.trimmingCharacters(
                  in: .whitespacesAndNewlines
              )
        else {
            throw AgentSystemFreshRunRequestFactoryError.unsupportedModel
        }

        do {
            switch provider {
            case .openAI:
                guard AIProvider.openAI.modelOptions.contains(modelID) else {
                    throw AgentSystemFreshRunRequestFactoryError
                        .unsupportedModel
                }
                return try .hostedOpenAIChatCompletions(
                    modelID: ProviderModelID(rawValue: modelID)
                )
            case .openCodeZen:
                guard AIProvider.openCodeZen.modelOptions.contains(modelID) else {
                    throw AgentSystemFreshRunRequestFactoryError
                        .unsupportedModel
                }
                return try .hostedOpenCodeZenChatCompletions(
                    modelID: ProviderModelID(rawValue: modelID)
                )
            case .openAICodex:
                guard AIProvider.openAICodex.modelOptions.contains(modelID) else {
                    throw AgentSystemFreshRunRequestFactoryError
                        .unsupportedModel
                }
                return try .hostedOpenAICodexResponses(
                    modelID: ProviderModelID(rawValue: modelID)
                )
            case .local:
                guard AIProvider.local.modelOptions.contains(modelID),
                      LocalModelCatalog.variant(for: modelID) != nil
                else {
                    throw AgentSystemFreshRunRequestFactoryError
                        .unsupportedModel
                }
                return try .localSingleCallTools(
                    modelID: ProviderModelID(rawValue: modelID)
                )
            default:
                throw AgentSystemFreshRunRequestFactoryError
                    .unsupportedProvider
            }
        } catch let error as AgentSystemFreshRunRequestFactoryError {
            throw error
        } catch {
            throw AgentSystemFreshRunRequestFactoryError
                .providerAuthorityUnavailable
        }
    }

    static func canonicalToolLocalities(
        provider: AIProvider,
        route: ProviderRoute
    ) throws -> [String: ToolExecutionLocality] {
        switch provider {
        case .openAI, .openAICodex, .openCodeZen:
            let registry: ToolRegistry
            do {
                registry = try SandboxToolCatalog.canonicalRegistry()
            } catch {
                throw AgentSystemFreshRunRequestFactoryError
                    .toolRegistryUnavailable
            }
            let expectedProvenance: ProviderRouteProvenance = switch provider {
            case .openAI: .builtInOpenAIChatCompletions
            case .openAICodex: .builtInOpenAICodexResponses
            case .openCodeZen: .builtInOpenCodeZenChatCompletions
            default:
                throw AgentSystemFreshRunRequestFactoryError
                    .unsupportedProvider
            }
            let expectedCapabilities: ProviderModelCapabilities =
                provider == .openAICodex
                    ? .hostedResponsesSingleCallToolsBaseline
                    : .hostedChatSingleCallToolsBaseline
            guard route.provenance == expectedProvenance,
                  route.deployment == .hostedService,
                  route.capabilities == expectedCapabilities,
                  route.capabilities.features.contains(.tools),
                  registry.descriptors.count == SandboxToolCatalog.all.count,
                  registry.descriptors.count == Int(
                      route.capabilities.maximumToolDefinitions
                  )
            else {
                throw AgentSystemFreshRunRequestFactoryError
                    .toolRegistryMismatch
            }

            var localities: [String: ToolExecutionLocality] = [:]
            for descriptor in registry.descriptors {
                guard descriptor.availability.allowedLocalities.contains(
                    .onDevice
                ) || descriptor.availability.allowedLocalities.contains(.either),
                    localities.updateValue(
                        .onDevice,
                        forKey: descriptor.name
                    ) == nil
                else {
                    throw AgentSystemFreshRunRequestFactoryError
                        .toolRegistryMismatch
                }
            }
            guard localities.count == registry.descriptors.count else {
                throw AgentSystemFreshRunRequestFactoryError
                    .toolRegistryMismatch
            }
            return localities

        case .local:
            let registry: ToolRegistry
            do {
                registry = try SandboxToolCatalog.localAgentRegistry()
            } catch {
                throw AgentSystemFreshRunRequestFactoryError
                    .toolRegistryUnavailable
            }
            guard route.provenance == .builtInLocalModel,
                  route.deployment == .onDevice,
                  route.capabilities.features.contains(.tools),
                  route.capabilities.features.contains(.typedToolArguments),
                  route.capabilities.features.contains(.strictToolSchema),
                  !route.capabilities.features.contains(.parallelToolCalls),
                  route.capabilities.maximumToolDefinitions ==
                    UInt32(registry.descriptors.count),
                  route.capabilities.maximumToolCallsPerTurn == 1
            else {
                throw AgentSystemFreshRunRequestFactoryError
                    .toolRegistryMismatch
            }
            var localities: [String: ToolExecutionLocality] = [:]
            for descriptor in registry.descriptors {
                guard descriptor.availability.allowedLocalities.contains(
                    .onDevice
                ) || descriptor.availability.allowedLocalities.contains(.either),
                    localities.updateValue(
                        .onDevice,
                        forKey: descriptor.name
                    ) == nil
                else {
                    throw AgentSystemFreshRunRequestFactoryError
                        .toolRegistryMismatch
                }
            }
            return localities

        default:
            throw AgentSystemFreshRunRequestFactoryError.unsupportedProvider
        }
    }

    static func generationOptions(
        provider: AIProvider,
        route: ProviderRoute,
        temperature: Double,
        reasoningEffort: ProviderReasoningEffort? = nil
    ) throws -> ProviderGenerationOptions {
        guard temperature.isFinite, (0 ... 2).contains(temperature) else {
            throw AgentSystemFreshRunRequestFactoryError.invalidTemperature
        }
        let maximumOutputTokens: UInt64
        let toolChoice: ProviderToolChoice
        switch provider {
        case .openAI, .openAICodex, .openCodeZen:
            maximumOutputTokens = min(
                4_096,
                route.capabilities.maximumOutputTokens
            )
            toolChoice = .auto
        case .local:
            maximumOutputTokens = route.capabilities.maximumOutputTokens
            toolChoice = .auto
        default:
            throw AgentSystemFreshRunRequestFactoryError.unsupportedProvider
        }
        let resolvedTemperature: Double? = provider == .openAICodex
            ? nil : temperature
        guard maximumOutputTokens > 0,
              route.capabilities.contextWindowTokens >= maximumOutputTokens,
              resolvedTemperature == nil ||
                route.capabilities.features.contains(.temperature),
              !route.capabilities.features.contains(.parallelToolCalls)
        else {
            throw AgentSystemFreshRunRequestFactoryError
                .providerAuthorityUnavailable
        }
        guard provider == .openAICodex || reasoningEffort == nil,
              reasoningEffort == nil ||
                route.capabilities.features.contains(.reasoning)
        else {
            throw AgentSystemFreshRunRequestFactoryError
                .providerAuthorityUnavailable
        }
        return ProviderGenerationOptions(
            maximumOutputTokens: maximumOutputTokens,
            temperature: resolvedTemperature,
            parallelToolCalls: false,
            toolChoice: toolChoice,
            reasoningSummary: reasoningEffort.map { $0 != .none },
            reasoningEffort: reasoningEffort,
            promptCacheKey: nil,
            previousResponseID: nil,
            minimumContextWindowTokens:
                route.capabilities.contextWindowTokens
        )
    }

    static func validateCanonicalConfiguration(
        context: AgentRunContext,
        plan: AgentSystemFreshRunPlan
    ) throws {
        do {
            _ = try AgentCanonicalContextPreparer(
                configuration: AgentCanonicalContextConfiguration(
                    context: context,
                    providerID: plan.providerRoute.providerID,
                    model: plan.providerRoute.modelID,
                    preferredAdapterIDs: [plan.providerRoute.adapterID],
                    options: plan.providerOptions,
                    systemInstruction: plan.systemInstruction,
                    developerInstruction: plan.developerInstruction,
                    toolLocalities: plan.toolLocalities
                )
            )
        } catch let error as AgentCanonicalContextPreparerError {
            switch error {
            case .invalidInstruction:
                throw AgentSystemFreshRunRequestFactoryError
                    .invalidSystemInstruction
            case .invalidGenerationOptions:
                throw AgentSystemFreshRunRequestFactoryError
                    .invalidGenerationConfiguration
            default:
                throw AgentSystemFreshRunRequestFactoryError
                    .invalidGenerationConfiguration
            }
        } catch {
            throw AgentSystemFreshRunRequestFactoryError
                .invalidGenerationConfiguration
        }
    }
}
