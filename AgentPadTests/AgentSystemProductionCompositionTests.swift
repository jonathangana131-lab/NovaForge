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

    func testFreshAcceptedLocalRouteIgnoresCurrentHostedProviderSelection()
        async throws
    {
        let container = try makeContainer()
        let context = container.mainContext
        let project = Project(
            name: "Local Route Drift Project",
            workspaceName: "Local Route Drift Workspace"
        )
        context.insert(AgentSettings(
            provider: .openAI,
            customSystemPrompt: "accepted-local instruction"
        ))
        context.insert(project)
        try context.save()

        let workspace = SandboxWorkspace(name: project.workspaceName)
        let resolver = SwiftDataAgentSystemRunEnvironmentResolver(
            container: container
        )
        let resolved = try await resolver.resolveFreshEnvironment(
            context: makeRunContext(
                projectID: ProjectID(rawValue: project.id),
                workspace: workspace
            ),
            providerRoute: localRoute()
        )

        XCTAssertEqual(resolved.systemInstruction, "accepted-local instruction")
        XCTAssertNil(
            resolved.hostedCredential,
            "An accepted Local route must never resolve hosted credentials from current settings."
        )
        XCTAssertNil(
            resolved.hostedAccountID,
            "An accepted Local route must never inherit hosted account authority from current settings."
        )
    }

    func testFreshEnvironmentUsesNewestDuplicateSettingsBeforeLaunchCleanup()
        async throws
    {
        let container = try makeContainer()
        let context = container.mainContext
        let workspaceName = "Resolver-Duplicate-\(UUID().uuidString)"
        let workspace = SandboxWorkspace(name: workspaceName)
        try FileManager.default.createDirectory(
            at: workspace.rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let project = Project(
            name: "Duplicate Settings Resolver",
            workspaceName: workspaceName
        )
        let older = AgentSettings(
            provider: .local,
            customSystemPrompt: "stale instruction"
        )
        older.updatedAt = Date(timeIntervalSince1970: 100)
        let newest = AgentSettings(
            provider: .local,
            customSystemPrompt: "newest instruction"
        )
        newest.updatedAt = Date(timeIntervalSince1970: 200)
        context.insert(project)
        context.insert(older)
        context.insert(newest)
        try context.save()

        let resolver = SwiftDataAgentSystemRunEnvironmentResolver(
            container: container
        )
        let resolved = try await resolver.resolveFreshEnvironment(
            context: makeRunContext(
                projectID: ProjectID(rawValue: project.id),
                workspace: workspace
            ),
            providerRoute: localRoute()
        )

        XCTAssertEqual(resolved.systemInstruction, "newest instruction")
        XCTAssertNil(resolved.hostedCredential)
        XCTAssertNil(resolved.hostedAccountID)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AgentSettings>()).count,
            2,
            "Resolver selection must not depend on launch cleanup running first."
        )
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

    func testFreshGeneralEnvironmentUsesAcceptedDefaultInsteadOfActiveProjectWorkspace()
        async throws
    {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(AgentSettings(
            provider: .local,
            activeWorkspaceName: "Active Project Workspace"
        ))
        try context.save()

        let workspace = SandboxWorkspace(
            name: AgentRunWorkspaceScope.generalWorkspaceName
        )
        let runContext = makeRunContext(
            projectID: nil,
            workspace: workspace
        )
        let resolver = SwiftDataAgentSystemRunEnvironmentResolver(
            container: container
        )

        let resolved = try await resolver.resolveFreshEnvironment(
            context: runContext,
            providerRoute: localRoute()
        )

        XCTAssertEqual(resolved.workspace.workspaceName, "Default")
    }

    func testFreshSystemWorkerEnvironmentUsesAcceptedIsolatedWorkspace()
        async throws
    {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(AgentSettings(
            provider: .local,
            activeWorkspaceName: "Active Project Workspace"
        ))
        try context.save()

        let workspaceName = "UltraCode-Isolated-\(UUID().uuidString)"
        let workspace = SandboxWorkspace(name: workspaceName)
        try FileManager.default.createDirectory(
            at: workspace.rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let runContext = makeRunContext(
            projectID: nil,
            workspace: workspace
        )
        let resolver = SwiftDataAgentSystemRunEnvironmentResolver(
            container: container
        )

        let resolved = try await resolver.resolveFreshEnvironment(
            context: runContext,
            providerRoute: localRoute()
        )

        XCTAssertEqual(
            resolved.workspace.workspaceName,
            workspaceName
        )
    }

    func testWorkspaceCatalogRejectsUnknownAcceptedIdentity() throws {
        let known = SandboxWorkspace(name: "Known-Catalog-Workspace")
        let unknown = SandboxWorkspace(name: "Unknown-Catalog-Workspace")
        let unknownIdentity = try WorkspaceResourceIdentity(
            workspace: unknown
        )

        XCTAssertThrowsError(
            try AgentSystemWorkspaceCatalog.resolve(
                WorkspaceID(rawValue: unknownIdentity.persistentID),
                candidates: [known]
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentSystemProductionCompositionError,
                .workspaceIdentityMismatch
            )
        }
    }

    func testWorkspaceCatalogRejectsAmbiguousIdentityCollision() throws {
        let workspace = SandboxWorkspace(name: "Duplicate-Catalog-Workspace")
        let identity = try WorkspaceResourceIdentity(workspace: workspace)

        XCTAssertThrowsError(
            try AgentSystemWorkspaceCatalog.resolve(
                WorkspaceID(rawValue: identity.persistentID),
                candidates: [workspace, workspace]
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentSystemProductionCompositionError,
                .workspaceIdentityMismatch
            )
        }
    }

    func testWorkspaceCatalogRejectsAnUnboundedCandidateSet() throws {
        let workspace = SandboxWorkspace(name: "Bounded-Catalog-Workspace")
        let identity = try WorkspaceResourceIdentity(workspace: workspace)
        let candidates = Array(
            repeating: workspace,
            count: AgentSystemWorkspaceCatalog.maximumCandidateCount + 1
        )

        XCTAssertThrowsError(
            try AgentSystemWorkspaceCatalog.resolve(
                WorkspaceID(rawValue: identity.persistentID),
                candidates: candidates
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentSystemProductionCompositionError,
                .workspaceUnavailable
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

    func testRecoveryAcceptedLocalRouteIgnoresCurrentHostedProviderSelection()
        async throws
    {
        let container = try makeContainer()
        let context = container.mainContext
        let acceptedWorkspace = SandboxWorkspace(
            name: "Local Route Recovery Drift Workspace"
        )
        let runContext = makeRunContext(
            projectID: nil,
            workspace: acceptedWorkspace
        )
        context.insert(AgentSettings(
            provider: .openAI,
            activeWorkspaceName: "Hosted Current Workspace",
            customSystemPrompt: "recovered-local instruction"
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
        XCTAssertEqual(resolved.systemInstruction, "recovered-local instruction")
        XCTAssertNil(
            resolved.hostedCredential,
            "A recovered Local route must not resolve credentials from the user's later hosted provider selection."
        )
        XCTAssertNil(
            resolved.hostedAccountID,
            "A recovered Local route must not inherit hosted account authority from later settings."
        )
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
            hostedCredential: nil,
            hostedAccountID: nil
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
