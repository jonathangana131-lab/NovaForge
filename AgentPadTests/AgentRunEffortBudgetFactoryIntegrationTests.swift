import AgentDomain
import AgentProviders
import XCTest
@testable import NovaForge

@MainActor
final class AgentRunEffortBudgetFactoryIntegrationTests: XCTestCase {
    private var previousReasoningEffort: ProviderReasoningEffort?
    private var previousOrchestrationMode: AgentOrchestrationMode?

    override func setUp() async throws {
        try await super.setUp()
        let preferences = AgentRunPreferenceStore.shared
        previousReasoningEffort = preferences.reasoningEffort
        previousOrchestrationMode = preferences.orchestrationMode
    }

    override func tearDown() async throws {
        let preferences = AgentRunPreferenceStore.shared
        if let previousReasoningEffort {
            preferences.reasoningEffort = previousReasoningEffort
        }
        if let previousOrchestrationMode {
            preferences.orchestrationMode = previousOrchestrationMode
        }
        previousReasoningEffort = nil
        previousOrchestrationMode = nil
        try await super.tearDown()
    }

    func testLocalFreshRunFreezesEveryComposerEffortStopIntoAcceptedBudget()
        throws
    {
        let preferences = AgentRunPreferenceStore.shared
        let cases: [(ProviderReasoningEffort, AgentOrchestrationMode, UInt64)] = [
            (.low, .standard, 8),
            (.medium, .standard, 32),
            (.high, .standard, 48),
            (.xhigh, .standard, 64),
            (.max, .ultraCode, 128),
        ]

        for (effort, mode, expectedIterations) in cases {
            preferences.reasoningEffort = effort
            preferences.orchestrationMode = mode

            let request = try makeLocalRequest(
                prompt: "Freeze \(effort.rawValue) into this accepted run."
            )
            guard case let .send(send) = request.command.payload else {
                return XCTFail("Expected send command")
            }

            XCTAssertEqual(
                send.context.initialBudget.limits.iterations,
                expectedIterations,
                "\(effort.rawValue) / \(mode.rawValue)"
            )
            XCTAssertEqual(
                send.context.initialBudget,
                AgentRunEffortBudgetPolicy.budget(
                    reasoningEffort: effort,
                    orchestrationMode: mode
                )
            )
        }
    }

    func testLocalEffortStillHasNoFabricatedProviderNativeReasoningOption()
        throws
    {
        let preferences = AgentRunPreferenceStore.shared
        preferences.reasoningEffort = .high
        preferences.orchestrationMode = .standard

        let request = try makeLocalRequest(
            prompt: "Use the real local work budget only."
        )
        guard case let .send(send) = request.command.payload else {
            return XCTFail("Expected send command")
        }

        XCTAssertNil(request.plan.providerOptions.reasoningEffort)
        XCTAssertEqual(send.context.initialBudget.limits.iterations, 48)
    }

    func testUltraFreezesStrongestBudgetAndExistingOrchestrationFeatures()
        throws
    {
        let preferences = AgentRunPreferenceStore.shared
        preferences.reasoningEffort = .max
        preferences.orchestrationMode = .ultraCode

        let request = try makeLocalRequest(
            prompt: "Use the strongest bounded Preview effort."
        )
        guard case let .send(send) = request.command.payload else {
            return XCTFail("Expected send command")
        }

        XCTAssertEqual(send.context.initialBudget.limits.iterations, 128)
        XCTAssertEqual(send.context.initialBudget.limits.toolInvocations, 256)
        XCTAssertTrue(send.context.features.contains("v2UltraCodeOrchestration"))
        XCTAssertTrue(send.context.features.contains("v2IsolatedAgentWorkspaces"))
    }

    private func makeLocalRequest(
        prompt: String
    ) throws -> AgentSystemFreshRunRequest {
        let conversation = Conversation(title: "Preview effort")
        let variant = LocalModelCatalog.defaultVariant
        let settings = AgentSettings(
            provider: .local,
            modelID: variant.id,
            activeWorkspaceName: AgentRunWorkspaceScope.generalWorkspaceName,
            temperature: 0.2
        )
        return try AgentSystemFreshRunRequestFactory.make(
            prompt: prompt,
            conversation: conversation,
            project: nil,
            workspace: SandboxWorkspace(
                name: AgentRunWorkspaceScope.generalWorkspaceName
            ),
            settings: settings
        )
    }
}
