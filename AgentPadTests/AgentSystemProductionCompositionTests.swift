import AgentDomain
import AgentProviders
import Foundation
import SwiftData
import XCTest
@testable import NovaForge

@MainActor
final class AgentSystemProductionCompositionTests: XCTestCase {
    func testFreshEnvironmentUsesExactProjectWorkspaceAndCurrentInstruction()
        async throws
    {
        let container = try makeContainer()
        let context = container.mainContext
        let settings = AgentSettings(
            provider: .local,
            activeWorkspaceName: "Wrong Current Workspace",
            customSystemPrompt: "project-safe instruction"
        )
        let project = Project(
            name: "Resolver Project",
            workspaceName: "Resolver Project Workspace"
        )
        context.insert(settings)
        context.insert(project)
        try context.save()

        let workspace = SandboxWorkspace(name: project.workspaceName)
        let runContext = makeRunContext(
            projectID: ProjectID(rawValue: project.id),
            workspace: workspace
        )
        let route = try localRoute()
        let resolver = SwiftDataAgentSystemRunEnvironmentResolver(
            container: container
        )

        let resolved = try await resolver.resolveFreshEnvironment(
            context: runContext,
            providerRoute: route
        )
        XCTAssertEqual(
            resolved.workspace.workspaceName,
            "Resolver Project Workspace"
        )
        XCTAssertEqual(
            resolved.systemInstruction,
            "project-safe instruction"
        )
        XCTAssertNil(resolved.developerInstruction)
        XCTAssertNil(resolved.hostedCredential)
    }

    func testFreshEnvironmentRejectsWorkspaceIdentitySubstitution()
        async throws
    {
        let container = try makeContainer()
        let context = container.mainContext
        let settings = AgentSettings(
            provider: .local,
            activeWorkspaceName: "Expected Workspace"
        )
        context.insert(settings)
        try context.save()
        let wrongWorkspace = SandboxWorkspace(name: "Different Workspace")
        let runContext = makeRunContext(
            projectID: nil,
            workspace: wrongWorkspace
        )
        let resolver = SwiftDataAgentSystemRunEnvironmentResolver(
            container: container
        )

        do {
            _ = try await resolver.resolveFreshEnvironment(
                context: runContext,
                providerRoute: localRoute()
            )
            XCTFail("Expected workspace substitution to fail closed")
        } catch {
            XCTAssertEqual(
                error as? AgentSystemProductionCompositionError,
                .workspaceIdentityMismatch
            )
        }
    }

    func testRecoveryUsesAcceptedRunWorkspaceInsteadOfCurrentSelection()
        async throws
    {
        let container = try makeContainer()
        let context = container.mainContext
        let acceptedWorkspace = SandboxWorkspace(
            name: "Accepted Recovery Workspace"
        )
        let runContext = makeRunContext(
            projectID: nil,
            workspace: acceptedWorkspace
        )
        context.insert(AgentSettings(
            provider: .local,
            activeWorkspaceName: "New Current Workspace",
            customSystemPrompt: "unchanged instruction"
        ))
        context.insert(AgentRunRecord(
            id: runContext.lineage.runID.rawValue,
            status: .running,
            conversationID: runContext.conversationID.rawValue,
            workspaceID: runContext.workspaceID.rawValue,
            workspaceName: acceptedWorkspace.workspaceName,
            provider: .local,
            modelID: LocalModelCatalog.all[0].id
        ))
        try context.save()
        let resolver = SwiftDataAgentSystemRunEnvironmentResolver(
            container: container
        )

        let resolved = try await resolver.resolveRecoveryEnvironment(
            context: runContext,
            providerRoute: localRoute()
        )
        XCTAssertEqual(
            resolved.workspace.workspaceName,
            acceptedWorkspace.workspaceName
        )
        XCTAssertEqual(resolved.systemInstruction, "unchanged instruction")
    }

    func testRecoveryWithoutExactLegacyRunProjectionFailsClosed()
        async throws
    {
        let container = try makeContainer()
        let context = container.mainContext
        let workspace = SandboxWorkspace(name: "Missing Projection")
        let runContext = makeRunContext(
            projectID: nil,
            workspace: workspace
        )
        context.insert(AgentSettings(provider: .local))
        try context.save()
        let resolver = SwiftDataAgentSystemRunEnvironmentResolver(
            container: container
        )

        do {
            _ = try await resolver.resolveRecoveryEnvironment(
                context: runContext,
                providerRoute: localRoute()
            )
            XCTFail("Expected missing accepted-run projection to fail")
        } catch {
            XCTAssertEqual(
                error as? AgentSystemProductionCompositionError,
                .runProjectionUnavailable
            )
        }
    }

    func testLegacyProjectionPersistsTypedOriginAndPublicSummary()
        throws
    {
        let workspace = SandboxWorkspace(name: "Typed Projection Workspace")
        let runContext = makeRunContext(
            projectID: nil,
            workspace: workspace
        )
        let identity = AgentFreshSendCommandIdentity(
            commandID: CommandID(rawValue: UUID()),
            runID: runContext.lineage.runID,
            userItemID: ModelItemID(rawValue: UUID()),
            correlationID: CorrelationID(rawValue: UUID()),
            cancellationScopeID: runContext.cancellation.scopeID
        )
        let enginePrompt = "Exact engine-only retry request with private detail."
        let command = try AgentSystemCommandFactory.send(
            AgentFreshSendCommandRequest(
                identity: identity,
                conversationID: runContext.conversationID,
                projectID: runContext.projectID,
                workspaceID: runContext.workspaceID,
                executionNodeID: runContext.executionNodeID,
                prompt: enginePrompt,
                acceptedAt: runContext.acceptedAt,
                features: runContext.features,
                budget: runContext.initialBudget,
                lineage: runContext.lineage
            )
        )
        let environment = AgentSystemResolvedRunEnvironment(
            workspace: workspace,
            systemInstruction: nil,
            developerInstruction: nil,
            hostedCredential: nil
        )
        let route = try localRoute()

        let summarized = try AgentSystemProductionEngineBuilder
            .legacyProjection(
                command: command,
                environment: environment,
                providerRoute: route,
                origin: .retry,
                publicRequestSummary: "Retry the previous request."
            )
        XCTAssertEqual(summarized.runID, identity.runID.rawValue)
        XCTAssertEqual(summarized.requestMessageID, identity.userItemID.rawValue)
        XCTAssertEqual(summarized.acceptedRequestText, enginePrompt)
        XCTAssertEqual(summarized.requestText, "Retry the previous request.")
        XCTAssertNotEqual(summarized.requestText, enginePrompt)
        XCTAssertEqual(summarized.origin, .retry)
        XCTAssertEqual(summarized.providerRawValue, AIProvider.local.rawValue)

        let exact = try AgentSystemProductionEngineBuilder.legacyProjection(
            command: command,
            environment: environment,
            providerRoute: route,
            origin: .user,
            publicRequestSummary: nil
        )
        XCTAssertEqual(exact.acceptedRequestText, enginePrompt)
        XCTAssertEqual(exact.requestText, enginePrompt)
        XCTAssertEqual(exact.origin, .user)
    }

    func testLegacyProjectionMapsCanonicalProviderAuthoritiesToAppProviderIDs()
        throws
    {
        let routes: [(ProviderRoute, AIProvider)] = [
            (
                try AgentProductionProviderRouteSelection
                    .hostedOpenAIChatCompletions(
                        modelID: ProviderModelID(
                            rawValue: AIProvider.openAI.defaultModel
                        )
                    ).declaredDescriptor.route,
                .openAI
            ),
            (
                try AgentProductionProviderRouteSelection
                    .hostedOpenCodeZenChatCompletions(
                        modelID: ProviderModelID(
                            rawValue: AIProvider.openCodeZen.defaultModel
                        )
                    ).declaredDescriptor.route,
                .openCodeZen
            ),
            (
                try AgentProductionProviderRouteSelection
                    .hostedOpenAICodexResponses(
                        modelID: ProviderModelID(
                            rawValue: AIProvider.openAICodex.defaultModel
                        )
                    ).declaredDescriptor.route,
                .openAICodex
            ),
            (try localRoute(), .local),
        ]

        for (route, provider) in routes {
            XCTAssertEqual(
                try AgentSystemProductionEngineBuilder
                    .legacyProviderRawValue(for: route),
                provider.rawValue
            )
        }
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV4.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func localRoute() throws -> ProviderRoute {
        try AgentProductionProviderRouteSelection.localSingleCallTools(
            modelID: ProviderModelID(rawValue: LocalModelCatalog.all[0].id)
        ).declaredDescriptor.route
    }

    private func makeRunContext(
        projectID: ProjectID?,
        workspace: SandboxWorkspace
    ) -> AgentRunContext {
        let identity = try! WorkspaceResourceIdentity(workspace: workspace)
        return AgentRunContext(
            lineage: .root(RunID(rawValue: UUID())),
            conversationID: ConversationID(rawValue: UUID()),
            projectID: projectID,
            workspaceID: WorkspaceID(rawValue: identity.persistentID),
            executionNodeID: ExecutionNodeID(rawValue: UUID()),
            engineVersion: .agentHarnessV2,
            acceptedAt: AgentInstant(Date()),
            features: AgentFeatureSet([]),
            cancellation: CancellationLineage(
                scopeID: CancellationScopeID(rawValue: UUID())
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
    }
}
