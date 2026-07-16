import AgentDomain
import AgentProviders
import AgentTools
import Foundation
import XCTest
@testable import NovaForge

@MainActor
final class AgentSystemFreshRunRequestFactoryTests: XCTestCase {
    private var previousReasoningEffort: ProviderReasoningEffort?
    private var previousOrchestrationMode: AgentOrchestrationMode?

    override func setUp() {
        super.setUp()
        let preferences = AgentRunPreferenceStore.shared
        previousReasoningEffort = preferences.reasoningEffort
        previousOrchestrationMode = preferences.orchestrationMode
        preferences.reasoningEffort = .medium
        preferences.orchestrationMode = .standard
    }

    override func tearDown() {
        let preferences = AgentRunPreferenceStore.shared
        if let previousReasoningEffort {
            preferences.reasoningEffort = previousReasoningEffort
        }
        if let previousOrchestrationMode {
            preferences.orchestrationMode = previousOrchestrationMode
        }
        previousReasoningEffort = nil
        previousOrchestrationMode = nil
        super.tearDown()
    }

    func testChatGPTReasoningEffortIsBoundAndUltraCodeUsesMaximumSupportedEffort() throws {
        let preferences = AgentRunPreferenceStore.shared
        let previousEffort = preferences.reasoningEffort
        let previousMode = preferences.orchestrationMode
        defer {
            preferences.reasoningEffort = previousEffort
            preferences.orchestrationMode = previousMode
        }

        let conversation = Conversation(title: "Reasoning")
        let settings = AgentSettings(
            provider: .openAICodex,
            modelID: "gpt-5.5",
            activeWorkspaceName: "ReasoningFactory",
            temperature: 1.7
        )
        let workspace = SandboxWorkspace(name: settings.activeWorkspaceName)

        preferences.orchestrationMode = .standard
        preferences.reasoningEffort = .xhigh
        let standard = try AgentSystemFreshRunRequestFactory.make(
            prompt: "Bind the exact effort.",
            conversation: conversation,
            project: nil,
            workspace: workspace,
            settings: settings
        )
        XCTAssertNil(standard.plan.providerOptions.temperature)
        XCTAssertEqual(standard.plan.providerOptions.reasoningEffort, .xhigh)
        XCTAssertEqual(standard.plan.providerOptions.reasoningSummary, true)
        guard case let .send(standardSend) = standard.command.payload else {
            return XCTFail("Expected send")
        }
        XCTAssertFalse(
            standardSend.context.features.contains("v2UltraCodeOrchestration")
        )

        preferences.orchestrationMode = .ultraCode
        let ultraCode = try AgentSystemFreshRunRequestFactory.make(
            prompt: "Escalate this run.",
            conversation: conversation,
            project: nil,
            workspace: workspace,
            settings: settings
        )
        XCTAssertEqual(
            ultraCode.plan.providerOptions.reasoningEffort,
            .xhigh,
            "UltraCode should use the live model's deepest supported effort instead of sending an invalid max value."
        )
        guard case let .send(ultraSend) = ultraCode.command.payload else {
            return XCTFail("Expected send")
        }
        XCTAssertTrue(
            ultraSend.context.features.contains("v2UltraCodeOrchestration")
        )
        XCTAssertTrue(
            ultraSend.context.features.contains("v2IsolatedAgentWorkspaces")
        )
    }

    func testHostedRequestBindsExactProductionAuthorities() throws {
        let project = Project(
            name: "Factory Hosted",
            workspaceName: "FactoryHosted"
        )
        project.id = uuid(10)
        let conversation = Conversation(project: project)
        conversation.id = uuid(11)
        let settings = AgentSettings(
            provider: .openAI,
            modelID: "gpt-4.1",
            activeWorkspaceName: "IgnoredForProject",
            temperature: 0.35,
            customSystemPrompt: "Preserve this exact system instruction."
        )
        let identity = AgentFreshSendCommandIdentity(
            commandID: CommandID(rawValue: uuid(20)),
            runID: RunID(rawValue: uuid(21)),
            userItemID: ModelItemID(rawValue: uuid(22)),
            correlationID: CorrelationID(rawValue: uuid(23)),
            cancellationScopeID: CancellationScopeID(rawValue: uuid(24))
        )
        let acceptedAt = AgentInstant(rawValue: 25)
        let workspace = SandboxWorkspace(name: project.workspaceName)

        let request = try AgentSystemFreshRunRequestFactory.make(
            prompt: "  Keep the user prompt exact.\n",
            conversation: conversation,
            project: project,
            workspace: workspace,
            settings: settings,
            publicRequestSummary: "Continue the hosted project safely.",
            identity: identity,
            origin: .autoContinue,
            acceptedAt: acceptedAt
        )

        XCTAssertEqual(request.command.header.commandID, identity.commandID)
        XCTAssertEqual(request.command.header.runID, identity.runID)
        XCTAssertEqual(request.command.header.correlationID, identity.correlationID)
        XCTAssertEqual(request.command.header.issuedAt, acceptedAt)
        guard case let .send(send) = request.command.payload else {
            return XCTFail("Expected one send command")
        }
        XCTAssertEqual(send.context.lineage, .root(identity.runID))
        XCTAssertEqual(send.context.conversationID.rawValue, conversation.id)
        XCTAssertEqual(send.context.projectID?.rawValue, project.id)
        XCTAssertEqual(
            send.context.workspaceID.rawValue,
            try WorkspaceResourceIdentity(workspace: workspace).persistentID
        )
        XCTAssertEqual(
            send.context.executionNodeID,
            AgentPolicyMutationRuntime.shared.executionNodeID
        )
        XCTAssertEqual(send.context.features, AgentSystemFreshRunRequestFactory.hostedStandardFeatures)
        XCTAssertEqual(send.context.initialBudget, AgentSystemFreshRunRequestFactory.standardBudget)
        XCTAssertEqual(send.context.acceptedAt, acceptedAt)
        XCTAssertEqual(send.context.cancellation.scopeID, identity.cancellationScopeID)
        XCTAssertEqual(send.userItem.id, identity.userItemID)
        XCTAssertEqual(
            send.userItem.payload,
            .message(ModelMessage(
                role: .user,
                content: [.text("  Keep the user prompt exact.\n")]
            ))
        )

        let authoritative = try AgentProductionProviderRouteSelection
            .hostedOpenAIChatCompletions(
                modelID: ProviderModelID(rawValue: settings.modelID)
            )
        XCTAssertEqual(
            request.plan.providerRoute,
            authoritative.declaredDescriptor.route
        )
        XCTAssertEqual(
            request.plan.providerOptions,
            ProviderGenerationOptions(
                maximumOutputTokens: 4_096,
                temperature: settings.temperature,
                parallelToolCalls: false,
                toolChoice: .auto,
                reasoningSummary: nil,
                promptCacheKey: nil,
                previousResponseID: nil,
                minimumContextWindowTokens: 128_000
            )
        )
        let registry = try SandboxToolCatalog.canonicalRegistry()
        XCTAssertEqual(registry.descriptors.count, 20)
        XCTAssertEqual(
            request.plan.toolLocalities,
            Dictionary(uniqueKeysWithValues: registry.descriptors.map {
                ($0.name, ToolExecutionLocality.onDevice)
            })
        )
        XCTAssertEqual(
            request.plan.systemInstruction,
            settings.customSystemPrompt
        )
        XCTAssertNil(request.plan.developerInstruction)
        XCTAssertEqual(
            request.plan.policyVersion,
            AgentPolicyEngineMutationAdapter.policyVersion
        )
        XCTAssertEqual(
            request.plan.contextPreparationVersion,
            AgentCanonicalContextPreparer.version
        )
        XCTAssertEqual(
            request.plan.publicRequestSummary,
            "Continue the hosted project safely."
        )
        XCTAssertEqual(request.plan.origin, .autoContinue)
    }

    func testLocalRequestHasBuiltInTextOnlyRouteAndZeroTools() throws {
        let conversation = Conversation(title: "Local")
        conversation.id = uuid(30)
        let variant = LocalModelCatalog.all[0]
        let settings = AgentSettings(
            provider: .local,
            modelID: variant.id,
            activeWorkspaceName: "FactoryLocal",
            temperature: 0.05
        )
        let workspace = SandboxWorkspace(name: settings.activeWorkspaceName)

        let request = try AgentSystemFreshRunRequestFactory.make(
            prompt: "Answer on device.",
            conversation: conversation,
            project: nil,
            workspace: workspace,
            settings: settings,
            acceptedAt: AgentInstant(rawValue: 31)
        )

        let authoritative = try AgentProductionProviderRouteSelection
            .localSingleCallTools(
                modelID: ProviderModelID(rawValue: variant.id)
            )
        XCTAssertEqual(
            request.plan.providerRoute,
            authoritative.declaredDescriptor.route
        )
        XCTAssertEqual(
            request.plan.providerRoute.provenance,
            .builtInLocalModel
        )
        XCTAssertEqual(request.plan.providerRoute.deployment, .onDevice)
        XCTAssertEqual(
            request.plan.providerRoute.capabilities.maximumToolDefinitions,
            UInt32(SandboxToolCatalog.localAgentTools.count)
        )
        XCTAssertEqual(
            request.plan.providerRoute.capabilities.maximumToolCallsPerTurn,
            1
        )
        XCTAssertTrue(
            request.plan.providerRoute.capabilities.features.contains(.tools)
        )
        XCTAssertEqual(
            Set(request.plan.toolLocalities.keys),
            Set(try SandboxToolCatalog.localAgentRegistry().descriptors.map(\.name))
        )
        XCTAssertTrue(request.plan.toolLocalities.values.allSatisfy {
            $0 == .onDevice
        })
        XCTAssertEqual(request.plan.providerOptions.toolChoice, .auto)
        XCTAssertEqual(request.plan.providerOptions.parallelToolCalls, false)
        XCTAssertEqual(
            request.plan.providerOptions.maximumOutputTokens,
            UInt64(variant.maxNewTokens)
        )
        XCTAssertEqual(
            request.plan.providerOptions.minimumContextWindowTokens,
            UInt64(variant.contextTokens)
        )
        XCTAssertNil(request.plan.systemInstruction)
        guard case let .send(send) = request.command.payload else {
            return XCTFail("Expected one send command")
        }
        XCTAssertNil(send.context.projectID)
        XCTAssertEqual(
            send.context.features,
            AgentSystemFreshRunRequestFactory.localAgentStandardFeatures
        )
        XCTAssertEqual(
            send.context.executionNodeID,
            AgentPolicyMutationRuntime.shared.executionNodeID
        )
    }

    func testEveryZenCatalogChoiceMintsTheCanonicalChatAgentRoute() throws {
        let fixture = makeFixture()
        fixture.settings.provider = .openCodeZen

        for modelID in AIProvider.openCodeZen.modelOptions {
            fixture.settings.modelID = modelID
            let request = try fixture.make(prompt: "Use the Zen agent route.")

            XCTAssertEqual(
                request.plan.providerRoute.providerID.rawValue,
                "opencode-zen",
                modelID
            )
            XCTAssertEqual(
                request.plan.providerRoute.modelID.rawValue,
                modelID,
                modelID
            )
            XCTAssertEqual(
                request.plan.providerRoute.provenance,
                .builtInOpenCodeZenChatCompletions,
                modelID
            )
            XCTAssertEqual(request.plan.toolLocalities.count, 20, modelID)
        }
    }

    func testZenCatalogRejectsModelsThatRequireAnotherWireDialect() throws {
        let fixture = makeFixture()
        fixture.settings.provider = .openCodeZen

        for unsupported in [
            "gpt-5.4", "claude-sonnet-4-6", "gemini-3-flash",
            "qwen3.6-plus",
        ] {
            fixture.settings.modelID = unsupported
            XCTAssertFactoryError(
                .unsupportedModel,
                try fixture.make(prompt: "Do not route the wrong dialect."),
                line: #line
            )
        }
    }

    func testPromptValidationUsesCanonicalCommandFactoryLimits() throws {
        let fixture = makeFixture()
        XCTAssertThrowsError(
            try fixture.make(prompt: " \n\t ")
        ) {
            XCTAssertEqual(
                $0 as? AgentSystemCommandFactoryError,
                .emptyPrompt
            )
        }
        XCTAssertThrowsError(
            try fixture.make(prompt: "before\0after")
        ) {
            XCTAssertEqual(
                $0 as? AgentSystemCommandFactoryError,
                .promptContainsNull
            )
        }

        let oversized = String(
            repeating: "x",
            count: AgentSystemCommandFactory.maximumPromptBytes + 1
        )
        XCTAssertThrowsError(try fixture.make(prompt: oversized)) {
            XCTAssertEqual(
                $0 as? AgentSystemCommandFactoryError,
                .promptTooLarge(
                    actualBytes: oversized.utf8.count,
                    maximumBytes:
                        AgentSystemCommandFactory.maximumPromptBytes
                )
            )
        }
    }

    func testUnsupportedProvidersModelsAndFallbackRawValueFailClosed() throws {
        let fixture = makeFixture()
        fixture.settings.provider = .custom
        XCTAssertFactoryError(
            .unsupportedProvider,
            try fixture.make(prompt: "hello")
        )

        fixture.settings.provider = .openAI
        fixture.settings.modelID = "caller/substituted-model"
        XCTAssertFactoryError(
            .unsupportedModel,
            try fixture.make(prompt: "hello")
        )

        fixture.settings.modelID = AIProvider.openAI.defaultModel
        fixture.settings.providerRawValue = nil
        XCTAssertFactoryError(
            .unsupportedProvider,
            try fixture.make(prompt: "hello")
        )
    }

    func testConversationProjectAndWorkspaceSubstitutionFailClosed() throws {
        let fixture = makeFixture()
        let otherProject = Project(
            name: "Other",
            workspaceName: fixture.project.workspaceName
        )
        XCTAssertFactoryError(
            .conversationProjectMismatch,
            try AgentSystemFreshRunRequestFactory.make(
                prompt: "hello",
                conversation: fixture.conversation,
                project: otherProject,
                workspace: fixture.workspace,
                settings: fixture.settings
            )
        )

        let wrongWorkspace = SandboxWorkspace(name: "DifferentWorkspace")
        XCTAssertFactoryError(
            .invalidWorkspaceSelection,
            try AgentSystemFreshRunRequestFactory.make(
                prompt: "hello",
                conversation: fixture.conversation,
                project: fixture.project,
                workspace: wrongWorkspace,
                settings: fixture.settings
            )
        )

        let substitutedRoot = SandboxWorkspace(rootURL:
            FileManager.default.temporaryDirectory
                .appendingPathComponent("FactoryFixture", isDirectory: true)
        )
        XCTAssertEqual(
            substitutedRoot.workspaceName,
            fixture.project.workspaceName
        )
        XCTAssertFactoryError(
            .workspaceIdentityMismatch,
            try AgentSystemFreshRunRequestFactory.make(
                prompt: "hello",
                conversation: fixture.conversation,
                project: fixture.project,
                workspace: substitutedRoot,
                settings: fixture.settings
            )
        )
    }

    func testInvalidTemperatureAndSystemInstructionFailClosed() throws {
        let fixture = makeFixture()
        fixture.settings.temperature = .nan
        XCTAssertFactoryError(
            .invalidTemperature,
            try fixture.make(prompt: "hello")
        )

        fixture.settings.temperature = 0.2
        fixture.settings.customSystemPrompt = "unsafe\0instruction"
        XCTAssertFactoryError(
            .invalidSystemInstruction,
            try fixture.make(prompt: "hello")
        )
    }
}

@MainActor
private struct FreshRunFixture {
    let project: Project
    let conversation: Conversation
    let settings: AgentSettings
    let workspace: SandboxWorkspace

    func make(prompt: String) throws -> AgentSystemFreshRunRequest {
        try AgentSystemFreshRunRequestFactory.make(
            prompt: prompt,
            conversation: conversation,
            project: project,
            workspace: workspace,
            settings: settings,
            acceptedAt: AgentInstant(rawValue: 90)
        )
    }
}

@MainActor
private func makeFixture() -> FreshRunFixture {
    let project = Project(
        name: "Factory Fixture",
        workspaceName: "FactoryFixture"
    )
    project.id = uuid(80)
    let conversation = Conversation(project: project)
    conversation.id = uuid(81)
    let settings = AgentSettings(
        provider: .openAI,
        modelID: AIProvider.openAI.defaultModel,
        activeWorkspaceName: "GeneralIgnored",
        temperature: 0.2
    )
    return FreshRunFixture(
        project: project,
        conversation: conversation,
        settings: settings,
        workspace: SandboxWorkspace(name: project.workspaceName)
    )
}

@MainActor
private func XCTAssertFactoryError<T>(
    _ expected: AgentSystemFreshRunRequestFactoryError,
    _ expression: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertEqual(
            error as? AgentSystemFreshRunRequestFactoryError,
            expected,
            file: file,
            line: line
        )
    }
}

private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (
        value, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    ))
}
