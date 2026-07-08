import XCTest

final class LiveChatSessionReducerTests: XCTestCase {
    func testIdleHidesLiveRunCard() {
        let state = LiveChatSessionReducer.reduce(.init())

        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.primaryLine, "Ready")
        XCTAssertFalse(state.shouldShowLiveRunCard)
        XCTAssertTrue(state.actions.isEmpty)
    }

    func testRunningConnectionShowsOneHumanPrimaryLine() {
        let state = LiveChatSessionReducer.reduce(.init(
            runState: .running,
            isWorking: true,
            activityTitle: "Calling OpenAI",
            activityDetail: "Collecting files and recent messages for OpenAI.",
            providerDisplayName: "OpenAI",
            modelDisplayName: "GPT 5.5"
        ))

        XCTAssertEqual(state.phase, .connecting(provider: "GPT 5.5"))
        XCTAssertEqual(state.primaryLine, "Waiting for model")
        XCTAssertFalse(state.primaryLine.localizedCaseInsensitiveContains("calling openai"))
        XCTAssertEqual(state.actions.first?.kind, .addInstruction)
        XCTAssertTrue(state.shouldReserveComposerQueue)
    }

    func testStreamingUsesHumanWritingLabelInsteadOfWordTreeOrQueuedDebugText() {
        let input = LiveChatSessionInput(
            runState: .running,
            isWorking: true,
            activityTitle: "Word tree · Reading · 58 queued",
            activityDetail: "Normalizing chunk 396 of 1301",
            liveStream: LiveChatStreamSnapshot(
                displayText: "NovaForge is explaining the next step.",
                characterCount: 820,
                revealBacklog: 58,
                isShowingTail: true
            )
        )

        let state = LiveChatSessionReducer.reduce(input)

        XCTAssertEqual(state.phase, .streaming(summary: "Writing answer…"))
        XCTAssertEqual(state.primaryLine, "Writing answer…")
        XCTAssertFalse(state.primaryLine.localizedCaseInsensitiveContains("word tree"))
        XCTAssertFalse(state.primaryLine.localizedCaseInsensitiveContains("queued"))
        XCTAssertFalse((state.secondaryLine ?? "").localizedCaseInsensitiveContains("normalizing chunk"))
        XCTAssertEqual(input.liveStream.revealBacklog, 58, "Hidden/proof metrics stay available to tests without becoming visible user copy.")
    }

    func testActiveToolsMapIntoHumanVerbs() {
        let state = LiveChatSessionReducer.reduce(.init(
            runState: .running,
            isWorking: true,
            activityTitle: "Executing tool",
            activeToolName: "run_command",
            activeToolDetail: "xcodebuild test -only-testing:AgentPadTests/LiveChatSessionReducerTests"
        ))

        XCTAssertEqual(state.phase, .usingTool(name: "Running Xcode proof", target: nil))
        XCTAssertEqual(state.primaryLine, "Running Xcode proof")
        XCTAssertFalse(state.primaryLine.localizedCaseInsensitiveContains("run_command"))
    }

    func testInternalRendererToolMapsToWritingAnswer() {
        let state = LiveChatSessionReducer.reduce(.init(
            runState: .running,
            isWorking: true,
            activityTitle: "Executing tool",
            activeToolName: "response renderer",
            activeToolDetail: "Organizing the response"
        ))

        XCTAssertEqual(state.phase, .usingTool(name: "Writing answer…", target: "Organizing the response"))
        XCTAssertEqual(state.primaryLine, "Writing answer…")
        XCTAssertFalse(state.primaryLine.localizedCaseInsensitiveContains("renderer"))
    }

    func testPendingApprovalExposesApproveRejectFirst() {
        let request = ToolRequest(
            id: "tool-1",
            name: "write_file",
            arguments: ["path": "Reports/live-chat.md"]
        )

        let state = LiveChatSessionReducer.reduce(.init(
            runState: .waitingForApproval,
            isWorking: true,
            activityTitle: "Approval needed",
            pendingTool: request
        ))

        XCTAssertEqual(state.phase, .waitingForApproval(summary: "Writing file: Reports/live-chat.md"))
        XCTAssertEqual(state.actions.map(\.kind), [.approve, .reject])
        XCTAssertEqual(state.primaryLine, "Review this action")
        XCTAssertTrue(state.shouldReserveComposerQueue)
    }

    func testFailureExposesRecoveryActions() {
        let state = LiveChatSessionReducer.reduce(.init(
            runState: .failed("Provider timed out"),
            activityTitle: "Provider timed out"
        ))

        XCTAssertEqual(state.primaryLine, "Needs recovery")
        XCTAssertEqual(state.actions.map(\.kind), [.retry, .switchModel, .copyDetails])
        guard case .failed(let summary, let recovery) = state.phase else {
            return XCTFail("Expected failed phase")
        }
        XCTAssertEqual(summary, "Provider timed out")
        XCTAssertEqual(recovery.primaryAction, .retry)
    }

    func testCompletedArtifactExposesPrimaryHandoff() {
        let state = LiveChatSessionReducer.reduce(.init(
            runState: .completed,
            activityTitle: "Done",
            currentArtifacts: [WorkspaceArtifact(path: "Reports/live-chat-proof.md")]
        ))

        XCTAssertEqual(state.primaryLine, "Ready to review")
        XCTAssertEqual(state.artifactHandoffs.first?.title, "live-chat-proof.md")
        XCTAssertEqual(state.artifactHandoffs.first?.primaryActionTitle, "Preview")
        XCTAssertEqual(state.actions.first?.kind, .openArtifact)
    }
}
