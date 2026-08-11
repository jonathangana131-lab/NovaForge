import Foundation
import XCTest

final class PreviewLegacyRuntimeReachabilitySourceTests: XCTestCase {
    func testAskShortcutStagesComposerDraftWithoutOwningAgentRuntime() throws {
        let source = try repositorySource("AgentPad/App/NovaForgeShortcuts.swift")

        XCTAssertTrue(source.contains("storePendingCommand(.askPrompt(prompt))"))
        XCTAssertTrue(source.contains("name: NovaForgeIntentSignal.askPrompt"))
        XCTAssertFalse(
            source.contains("AgentRuntime("),
            "App Intent handoff must not create or run the legacy AgentRuntime"
        )
    }

    func testProjectDispatchUsesCanonicalAgentSystemInsteadOfLegacyRuntime() throws {
        let source = try repositorySource("AgentPad/Views/AppRootView.swift")

        XCTAssertTrue(
            source.contains("agentSystemPresentation.start("),
            "Project command dispatch must keep entering the canonical AgentSystem presentation boundary"
        )
        for forbidden in [
            "projectRuntime.send(",
            "projectRuntime.start(",
            "projectRuntime.run(",
            "projectRuntime.retryLastPrompt(",
            "projectRuntime.continueAfterInterruption(",
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "Project routing must not add a direct legacy run entry point: \(forbidden)"
            )
        }
    }

    func testKnownLegacyChatRunControlsCannotExpand() throws {
        let source = try repositorySource("AgentPad/Views/ChatView.swift")

        XCTAssertLessThanOrEqual(
            occurrences(of: "runtime.retryLastPrompt(", in: source),
            2,
            "Preview compatibility retry entry points expanded; route new retries through AgentSystem instead"
        )
        XCTAssertLessThanOrEqual(
            occurrences(of: "runtime.continueAfterInterruption(", in: source),
            2,
            "Preview compatibility continue entry points expanded; route new continuation through AgentSystem instead"
        )
        for forbidden in [
            "runtime.send(",
            "runtime.start(",
            "runtime.run(",
        ] {
            XCTAssertFalse(
                source.contains(forbidden),
                "ChatView must not add a new direct legacy run-start entry point: \(forbidden)"
            )
        }
    }

    func testLegacyReadOnlyFallbackCannotExpandBeyondSingleBridge() throws {
        let runtime = try repositorySource("AgentPad/Services/AgentRuntime.swift")
        let canonicalExecutor = try repositorySource(
            "AgentPad/Services/AgentSandboxReadOnlyToolExecutor.swift"
        )
        let canonicalBackend = try repositorySource(
            "AgentPad/Services/POSIXWorkspaceReadBackend.swift"
        )

        XCTAssertLessThanOrEqual(
            occurrences(of: "SandboxToolExecutor(workspace: workspace)", in: runtime),
            1,
            "Legacy AgentRuntime gained another path-based read-only sandbox bridge"
        )
        XCTAssertTrue(canonicalExecutor.contains("AgentReadOnlyWorkspaceBackend"))
        XCTAssertTrue(canonicalBackend.contains("openat"))
        XCTAssertTrue(canonicalBackend.contains("O_NOFOLLOW"))
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }
}
