import SwiftData
import SwiftUI
import UIKit
import XCTest

enum TestModelSchema {
    static var projectFoundation: Schema {
        Schema([
            Project.self,
            ProjectEvent.self,
            ProjectArtifact.self,
            TerminalCommandRecord.self,
            ProjectFileChange.self,
            ProjectOSRun.self,
            ProjectOSStep.self,
            Conversation.self,
            ChatMessage.self,
            ToolRun.self,
            AgentRunRecord.self,
            ToolOperationRecord.self,
            AgentSettings.self
        ])
    }
}

@MainActor
final class AgentRuntimeLifecycleTests: XCTestCase {
    func testLiveStreamBufferRevealsLargeChunksGradually() async throws {
        let stream = LiveStreamBuffer()
        let text = String(repeating: "NovaForge should flow like a native chat response instead of spawning a full provider batch. ", count: 24)

        stream.append(text)

        XCTAssertFalse(stream.displayText.isEmpty)
        XCTAssertLessThan(stream.displayText.count, text.count, "The first display update should reveal only the start of a large provider batch.")
        XCTAssertGreaterThan(stream.revealBacklog, 0)

        let initialCount = stream.displayText.count
        try await Task.sleep(for: .milliseconds(140))
        XCTAssertGreaterThan(stream.displayText.count, initialCount, "The display-paced reveal loop should keep flowing after the first glyph.")
        XCTAssertLessThan(stream.displayText.count, text.count, "The reveal loop should not dump the entire backlog in one UI update.")

        stream.flushPending()
        XCTAssertEqual(stream.characterCount, text.count, "The underlying live frame should still retain the complete provider response for durable handoff.")
        XCTAssertLessThan(stream.displayText.count, text.count, "The live bubble should remain a compact rolling window even after backlog is flushed.")
        XCTAssertLessThanOrEqual(stream.displayText.count, 1_200, "The normal live window should have a strict layout budget.")
        XCTAssertTrue(stream.displayText.hasPrefix("NovaForge should flow"), "The stable opening should remain readable instead of being replaced by a rolling suffix.")
        XCTAssertTrue(stream.displayText.contains(ForgeLiveFeedFrame.middleOmissionMarker), "Windowed live text should clearly mark its omitted middle.")
        XCTAssertTrue(stream.displayText.hasSuffix(String(text.suffix(48))), "The newest active response tail should remain visible.")
        XCTAssertEqual(stream.revealBacklog, 0)
    }

    func testLiveStreamHandoffWaitsForRevealBeforeClearingLiveBubble() {
        let stream = LiveStreamBuffer()
        let messageID = UUID()
        let text = String(repeating: "handoff should wait for the live reveal to catch up before final text replaces it. ", count: 6)

        stream.append(text)
        stream.finishHandoff(to: messageID)
        stream.clearHandoffIfRendered(messageID: messageID)

        XCTAssertTrue(stream.isHandoffActive, "Final message rendering should not clear the live island while reveal backlog remains.")
        XCTAssertGreaterThan(stream.revealBacklog, 0)

        stream.flushPending()
        XCTAssertTrue(stream.isEmpty)
        XCTAssertNil(stream.handoffMessageID)
    }

    func testRuntimeFixtureExposesStructuredProjectProgressInputs() {
        let runtime = AgentRuntime()
        runtime.debugSimulateActiveStatusStripRun()

        XCTAssertTrue(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .running)
        XCTAssertEqual(runtime.activityTitle, "Release check running")
        XCTAssertEqual(runtime.activeToolName, "release check")
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Running command/check" && $0.status == .executing })
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Inspecting files/evidence" && $0.status == .thinking })
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Reading project state" && $0.status == .planning })
    }

    func testActiveResponseStaysAttachedToOriginalConversation() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Ownership", workspaceName: "Ownership")
        let settings = AgentSettings()
        let running = Conversation(title: "Running Chat", project: project)
        let other = Conversation(title: "Other Chat", project: project)
        context.insert(project)
        context.insert(settings)
        context.insert(running)
        context.insert(other)
        try context.save()

        let runtime = AgentRuntime()
        runtime.debugSimulateActiveStatusStripRun(conversation: running)
        let disposition = runtime.send(
            prompt: "queue this in the wrong chat",
            conversation: other,
            settings: settings,
            context: context,
            project: project
        )

        XCTAssertEqual(runtime.activeConversationID, running.id)
        XCTAssertEqual(runtime.queuedPromptCount, 0)
        XCTAssertEqual(disposition, .rejected(.anotherConversationIsActive(title: "Running Chat")))
        XCTAssertTrue(other.messages.isEmpty)
        XCTAssertTrue(runtime.toasts.contains { $0.message.contains("Running Chat") })
    }

    func testAutoContinuePolicySchedulesOnlyAfterEnabledCleanCompletion() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Momentum", mission: "Build a durable workspace command center.", workspaceName: "Default")
        project.autoContinueEnabled = true
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        let conversation = Conversation(title: "Momentum", project: project)
        context.insert(project)
        context.insert(settings)
        context.insert(conversation)
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Initial command-center pass completed.",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 100)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let sourceEventID = try XCTUnwrap(project.events.first { $0.kind == .runCompleted }?.id.uuidString)
        let evaluation = ProjectAutoContinuePolicy.evaluate(
            project: project,
            summary: summary,
            settings: settings,
            runtimeIsWorking: false,
            hasPendingRuntimeApproval: false,
            runCompleted: true,
            runFailedOrPaused: false,
            hasUsableProviderCredential: true,
            latestRunEventID: sourceEventID
        )

        XCTAssertEqual(evaluation.action, .schedule)
        XCTAssertEqual(evaluation.sourceEventID, sourceEventID)
    }

    func testAutoContinuePolicyDoesNotScheduleWhenDisabledOrApprovalWaiting() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Approval Gate", mission: "Continue safely only after review.", workspaceName: "Default")
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        let conversation = Conversation(title: "Approval Gate", project: project)
        let pendingRun = ToolRun(
            name: "write_file",
            argumentsJSON: #"{"path":"index.html"}"#,
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true,
            project: project
        )
        context.insert(project)
        context.insert(settings)
        context.insert(conversation)
        context.insert(pendingRun)
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
        try context.save()

        let sourceEventID = try XCTUnwrap(project.events.first { $0.kind == .runCompleted }?.id.uuidString)
        let disabledSummary = ProjectMissionSummarizer.summarize(project: project, context: context)
        XCTAssertEqual(
            ProjectAutoContinuePolicy.evaluate(
                project: project,
                summary: disabledSummary,
                settings: settings,
                runtimeIsWorking: false,
                hasPendingRuntimeApproval: false,
                runCompleted: true,
                runFailedOrPaused: false,
                hasUsableProviderCredential: true,
                latestRunEventID: sourceEventID
            ).action,
            .disabled
        )

        project.autoContinueEnabled = true
        let approvalSummary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let evaluation = ProjectAutoContinuePolicy.evaluate(
            project: project,
            summary: approvalSummary,
            settings: settings,
            runtimeIsWorking: false,
            hasPendingRuntimeApproval: false,
            runCompleted: true,
            runFailedOrPaused: false,
            hasUsableProviderCredential: true,
            latestRunEventID: sourceEventID
        )

        XCTAssertEqual(evaluation.action, .stop)
        XCTAssertEqual(evaluation.title, "Approval needed")
    }

    func testAutoContinuePolicyStopsForBlockerMissingCredentialsAndFinalReview() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Guard Rails", mission: "Ship with explicit proof gates.", workspaceName: "Default")
        project.autoContinueEnabled = true
        let settings = AgentSettings(provider: .openAI, activeProjectID: project.id)
        context.insert(project)
        context.insert(settings)
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            severity: .success,
            sourceType: .conversation,
            context: context,
            now: Date(timeIntervalSince1970: 200)
        )
        try context.save()
        let sourceEventID = try XCTUnwrap(project.events.first { $0.kind == .runCompleted }?.id.uuidString)

        var summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        var evaluation = ProjectAutoContinuePolicy.evaluate(
            project: project,
            summary: summary,
            settings: settings,
            runtimeIsWorking: false,
            hasPendingRuntimeApproval: false,
            runCompleted: true,
            runFailedOrPaused: false,
            hasUsableProviderCredential: false,
            latestRunEventID: sourceEventID
        )
        XCTAssertEqual(evaluation.action, .stop)
        XCTAssertEqual(evaluation.title, "Provider setup needed")

        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Verification failed",
            detail: "Screenshot proof failed.",
            severity: .failure,
            sourceType: .conversation,
            context: context,
            now: Date(timeIntervalSince1970: 201)
        )
        summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        evaluation = ProjectAutoContinuePolicy.evaluate(
            project: project,
            summary: summary,
            settings: settings,
            runtimeIsWorking: false,
            hasPendingRuntimeApproval: false,
            runCompleted: true,
            runFailedOrPaused: false,
            hasUsableProviderCredential: true,
            latestRunEventID: sourceEventID
        )
        XCTAssertEqual(evaluation.action, .stop)
        XCTAssertEqual(evaluation.title, "Blocked by evidence")

        project.status = .completed
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Recovery completed",
            detail: "Final proof reviewed.",
            severity: .success,
            sourceType: .conversation,
            context: context,
            now: Date(timeIntervalSince1970: 300)
        )
        summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        evaluation = ProjectAutoContinuePolicy.evaluate(
            project: project,
            summary: summary,
            settings: settings,
            runtimeIsWorking: false,
            hasPendingRuntimeApproval: false,
            runCompleted: true,
            runFailedOrPaused: false,
            hasUsableProviderCredential: true,
            latestRunEventID: sourceEventID
        )
        XCTAssertEqual(evaluation.action, .stop)
        XCTAssertEqual(evaluation.title, "Final review reached")
    }

    func testAutoContinuedRunForcesMutatingApprovalAndDurableRecords() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeAutoContinueApproval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let project = Project(name: "Auto Approval", mission: "Prove auto-continued runs pause before writes.", workspaceName: "Default")
        let conversation = Conversation(title: "Auto Approval", project: project)
        let settings = AgentSettings(provider: .openAI, autoApproveWrites: true, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        runtime.debugInstallProviderResponses([
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(
                    role: "assistant",
                    content: "Auto-continued plan: write the proof file.",
                    tool_calls: [
                        APIToolCall(
                            id: "call_auto_write",
                            type: "function",
                            function: APIFunctionCall(
                                name: "write_file",
                                arguments: #"{"path":"auto-proof.txt","contents":"proof"}"#
                            )
                        )
                    ]
                ),
                roleLog: "debug auto-continued mutating tool"
            )
        ])
        runtime.send(
            prompt: "Auto-continued run: create proof.",
            conversation: conversation,
            settings: settings,
            context: context,
            project: project,
            origin: .autoContinued
        )

        let deadline = Date().addingTimeInterval(3)
        while runtime.runState != .waitingForApproval && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(runtime.runState, .waitingForApproval)
        XCTAssertNotNil(runtime.pendingTool)
        XCTAssertNil(try? runtime.workspace.read("auto-proof.txt"))

        let runs = try context.fetch(FetchDescriptor<ToolRun>())
        let run = try XCTUnwrap(runs.first { $0.name == "write_file" })
        XCTAssertEqual(run.status, .pendingApproval)
        XCTAssertTrue(run.requiresApproval)
        XCTAssertEqual(run.project?.id, project.id)

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertTrue(events.contains { $0.kind == .promptQueued && $0.title == "Auto-continued prompt queued" })
        XCTAssertTrue(events.contains { $0.kind == .toolApprovalRequested && $0.sourceIDString == run.id.uuidString })
    }

    func testHostedMultiCallPlanCompletesEnvelopeThroughFirstApprovalAndDefersLaterCalls() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeHostedApprovalEnvelope-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try "source context".write(
            to: workspaceRoot.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let project = Project(name: "Hosted Envelope", workspaceName: "Default")
        let conversation = Conversation(title: "Hosted Envelope", project: project)
        let settings = AgentSettings(provider: .openAI, autoApproveWrites: false, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let readCall = APIToolCall(
            id: "call_read_before_write",
            type: "function",
            function: APIFunctionCall(name: "read_file", arguments: #"{"path":"README.md"}"#)
        )
        let writeCall = APIToolCall(
            id: "call_write_boundary",
            type: "function",
            function: APIFunctionCall(name: "write_file", arguments: #"{"path":"hosted-proof.txt","contents":"approved"}"#)
        )
        let laterCall = APIToolCall(
            id: "call_after_boundary",
            type: "function",
            function: APIFunctionCall(name: "list_directory", arguments: #"{"path":"."}"#)
        )

        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        runtime.debugInstallProviderResponses([
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(
                    role: "assistant",
                    content: "Read, then request the write, then inspect later.",
                    tool_calls: [readCall, writeCall, laterCall]
                ),
                roleLog: "debug hosted multi-call plan"
            ),
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(
                    role: "assistant",
                    content: "The approved boundary is complete.",
                    tool_calls: nil
                ),
                roleLog: "debug hosted completion"
            )
        ])

        XCTAssertEqual(
            runtime.send(
                prompt: "Use the hosted read/write plan safely.",
                conversation: conversation,
                settings: settings,
                context: context,
                project: project
            ),
            .started
        )

        let approvalDeadline = Date().addingTimeInterval(4)
        while runtime.runState != .waitingForApproval && Date() < approvalDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertEqual(runtime.runState, .waitingForApproval)
        XCTAssertEqual(runtime.pendingTool?.id, writeCall.id)
        XCTAssertNil(try? runtime.workspace.read("hosted-proof.txt"))

        let planMessage = try XCTUnwrap(conversation.messages.first { $0.role == .assistant && $0.toolCalls?.isEmpty == false })
        XCTAssertEqual(planMessage.toolCalls?.map(\.id), [readCall.id, writeCall.id])
        XCTAssertFalse(planMessage.toolCalls?.contains(where: { $0.id == laterCall.id }) == true)
        XCTAssertEqual(conversation.messages.filter { $0.role == .tool }.compactMap(\.toolCallID), [readCall.id])

        let contextWhileWaiting = ProviderContextWindow.select(
            conversation.messages.map(\.providerInput),
            budget: .hosted
        )
        XCTAssertFalse(
            contextWhileWaiting.contains { $0.id == planMessage.id || $0.role == .tool },
            "A partial read/write envelope must stay out of provider context until approval adds the missing write result."
        )

        runtime.approvePendingTool(
            conversation: conversation,
            settings: settings,
            context: context,
            project: project
        )

        let completionDeadline = Date().addingTimeInterval(5)
        while (runtime.isWorking || runtime.pendingTool != nil) && Date() < completionDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertEqual(try runtime.workspace.read("hosted-proof.txt"), "approved")
        XCTAssertEqual(
            Set(conversation.messages.filter { $0.role == .tool }.compactMap(\.toolCallID)),
            Set([readCall.id, writeCall.id])
        )
        XCTAssertFalse(conversation.messages.contains { $0.toolCallID == laterCall.id })
        XCTAssertFalse(try context.fetch(FetchDescriptor<ToolRun>()).contains { $0.name == laterCall.function.name })

        let completedContext = ProviderContextWindow.select(
            conversation.messages.map(\.providerInput),
            budget: .hosted
        )
        XCTAssertTrue(completedContext.contains { $0.id == planMessage.id })
        XCTAssertEqual(
            Set(completedContext.filter { $0.role == .tool }.compactMap(\.toolCallID)),
            Set([readCall.id, writeCall.id])
        )
    }

    func testLaunchRecoveryPausesInterruptedAutoContinueCountdown() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Recovered Countdown", mission: "Recover countdowns clearly.", workspaceName: "Default")
        project.autoContinueEnabled = true
        project.autoContinueState = .countdown
        project.autoContinueDecision = "Start the next verification pass."
        context.insert(project)
        try context.save()

        PersistentLaunchRecovery.recoverInterruptedToolRuns(in: context, now: Date(timeIntervalSince1970: 900))

        XCTAssertTrue(project.autoContinuePaused)
        XCTAssertEqual(project.autoContinueState, .paused)
        XCTAssertTrue(project.events.contains { $0.kind == .autoContinuePaused && $0.title == "Auto-continue paused after relaunch" })
    }

    func testLaunchSelectionPrefersFreshReadyChatOnColdLaunch() throws {
        let ready = Conversation(title: LaunchConversationSelection.safeStartTitle)

        let completed = Conversation(title: "Persist me")
        let user = ChatMessage(role: .user, content: "list files", conversation: completed)
        let assistant = ChatMessage(role: .assistant, content: "README.md", conversation: completed)
        completed.appendMessages([user, assistant])

        let failed = Conversation(title: "Broken old chat")
        let failedUser = ChatMessage(role: .user, content: "call provider", conversation: failed)
        let failedAssistant = ChatMessage(role: .assistant, content: "I hit an error: Network unavailable. Tap Retry.", conversation: failed)
        failed.appendMessages([failedUser, failedAssistant])

        let interrupted = Conversation(title: "Interrupted old chat")
        let interruptedUser = ChatMessage(role: .user, content: "write a file", conversation: interrupted)
        interrupted.appendMessage(interruptedUser)

        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: [ready, completed],
                sessionID: nil,
                persistedIDString: completed.id.uuidString
            )?.id,
            ready.id
        )

        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: [failed, ready],
                sessionID: nil,
                persistedIDString: failed.id.uuidString
            )?.id,
            ready.id
        )

        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: [interrupted, ready],
                sessionID: nil,
                persistedIDString: interrupted.id.uuidString
            )?.id,
            ready.id
        )
    }

    func testLaunchSelectionUsesNewestMessageWithoutSortingEntireThread() throws {
        let ready = Conversation(title: LaunchConversationSelection.safeStartTitle)
        let conversation = Conversation(title: "Long restored thread")
        let oldAssistant = ChatMessage(role: .assistant, content: "old settled answer", conversation: conversation)
        oldAssistant.createdAt = Date(timeIntervalSince1970: 100)
        let user = ChatMessage(role: .user, content: "new unfinished prompt", conversation: conversation)
        user.createdAt = Date(timeIntervalSince1970: 300)
        let middleAssistant = ChatMessage(role: .assistant, content: "middle answer", conversation: conversation)
        middleAssistant.createdAt = Date(timeIntervalSince1970: 200)
        conversation.appendMessages([oldAssistant, user, middleAssistant])

        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: [conversation, ready],
                sessionID: nil,
                persistedIDString: conversation.id.uuidString
            )?.id,
            ready.id,
            "Restore should check the newest message by date, not array insertion order."
        )
    }

    func testLaunchRecoveryClearsStalePendingAndApprovedToolRuns() throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let pending = ToolRun(
            name: "write_file",
            argumentsJSON: "{}",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true
        )
        let approved = ToolRun(
            name: "delete_file",
            argumentsJSON: "{}",
            status: .approved,
            requiresApproval: true,
            isMutating: true
        )
        let completed = ToolRun(name: "read_file", argumentsJSON: "{}", status: .completed)
        context.insert(pending)
        context.insert(approved)
        context.insert(completed)
        try context.save()

        let recoveryDate = Date(timeIntervalSince1970: 1_234)
        PersistentLaunchRecovery.recoverInterruptedToolRuns(in: context, now: recoveryDate)

        XCTAssertEqual(pending.status, .rejected)
        XCTAssertEqual(approved.status, .failed)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(pending.completedAt, recoveryDate)
        XCTAssertEqual(approved.completedAt, recoveryDate)
        XCTAssertTrue(pending.output.contains("stale approval"))
        XCTAssertTrue(approved.output.contains("did not finish"))
    }

    func testPersistedToolPayloadsAreCompactedBeforeSavingHistory() throws {
        let hugeOutput = "OUTPUT-START\n" + String(repeating: "tool output line that would bloat SwiftData history\n", count: 900) + "OUTPUT-END"
        let hugeCommand = "python3 - <<'PY'\n" + String(repeating: "print('history bloat guard')\n", count: 700) + "PY"
        let argumentsData = try JSONSerialization.data(withJSONObject: [
            "command": hugeCommand,
            "cwd": "/workspace"
        ], options: [.sortedKeys])
        let argumentsJSON = try XCTUnwrap(String(data: argumentsData, encoding: .utf8))

        let message = ChatMessage(role: .tool, content: hugeOutput, toolCallID: "call_big")
        let run = ToolRun(name: "run_command", argumentsJSON: argumentsJSON, output: hugeOutput, status: .completed)

        XCTAssertLessThan(message.content.count, hugeOutput.count)
        XCTAssertTrue(message.content.contains("OUTPUT-START"))
        XCTAssertTrue(message.content.contains("OUTPUT-END"))
        XCTAssertTrue(message.content.contains("compacted this persisted tool message"))
        XCTAssertLessThanOrEqual(message.content.count, PersistedPayloadBudget.maxToolMessageContentCharacters)

        XCTAssertLessThan(run.output.count, hugeOutput.count)
        XCTAssertTrue(run.output.contains("OUTPUT-START"))
        XCTAssertTrue(run.output.contains("OUTPUT-END"))
        XCTAssertTrue(run.output.contains("compacted this persisted tool output"))
        XCTAssertLessThanOrEqual(run.output.count, PersistedPayloadBudget.maxToolRunOutputCharacters)

        XCTAssertLessThan(run.argumentsJSON.count, argumentsJSON.count)
        XCTAssertLessThanOrEqual(run.argumentsJSON.count, PersistedPayloadBudget.maxToolRunArgumentsCharacters)
        XCTAssertTrue(run.argumentsJSON.contains("compacted this persisted tool arguments.command") || run.argumentsJSON.contains("__novaforge_compacted"))
    }

    func testPersistedAssistantToolCallsCompactHugeArgumentsButRemainDecodable() throws {
        let hugeContents = "BEGIN-CONTENTS\n" + String(repeating: "generated source line\n", count: 900) + "END-CONTENTS"
        let argumentsData = try JSONSerialization.data(withJSONObject: [
            "path": "Sources/App.swift",
            "contents": hugeContents
        ], options: [.sortedKeys])
        let argumentsJSON = try XCTUnwrap(String(data: argumentsData, encoding: .utf8))
        let call = APIToolCall(
            id: "call_write",
            type: "function",
            function: APIFunctionCall(name: "write_file", arguments: argumentsJSON)
        )
        let callsJSON = try XCTUnwrap(String(data: JSONEncoder().encode([call]), encoding: .utf8))

        let message = ChatMessage(role: .assistant, content: "I will write the file.", toolCallsJSON: callsJSON)

        let persistedJSON = try XCTUnwrap(message.toolCallsJSON)
        let persistedCalls = try JSONDecoder().decode([APIToolCall].self, from: XCTUnwrap(persistedJSON.data(using: .utf8)))
        XCTAssertEqual(persistedCalls.count, 1)
        XCTAssertEqual(persistedCalls[0].id, "call_write")
        XCTAssertEqual(persistedCalls[0].function.name, "write_file")
        XCTAssertLessThan(persistedCalls[0].function.arguments.count, argumentsJSON.count)
        XCTAssertLessThanOrEqual(persistedCalls[0].function.arguments.count, PersistedPayloadBudget.maxToolCallArgumentsCharacters)
        XCTAssertTrue(persistedCalls[0].function.arguments.contains("Sources/App.swift"))
        XCTAssertTrue(persistedCalls[0].function.arguments.contains("compacted this persisted write_file arguments.contents") || persistedCalls[0].function.arguments.contains("__novaforge_compacted"))
    }

    func testPersistedPayloadBudgetsApplyBeforeSavingDirectModelMutations() throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let hugeOutput = "MUTATION-START\n" + String(repeating: "mutation output line that would bloat launch history\n", count: 900) + "MUTATION-END"
        let hugeCommand = "python3 - <<'PY'\n" + String(repeating: "print('direct mutation bloat guard')\n", count: 700) + "PY"
        let argumentsData = try JSONSerialization.data(withJSONObject: [
            "command": hugeCommand,
            "cwd": "/workspace"
        ], options: [.sortedKeys])
        let argumentsJSON = try XCTUnwrap(String(data: argumentsData, encoding: .utf8))
        let run = ToolRun(name: "run_command", argumentsJSON: argumentsJSON, output: hugeOutput, status: .approved)
        context.insert(run)

        let toolMessage = ChatMessage(role: .tool, content: hugeOutput, toolCallID: "call_mutation")
        context.insert(toolMessage)

        let hugeContents = "BEGIN-MUTATED-CONTENTS\n" + String(repeating: "generated source line\n", count: 900) + "END-MUTATED-CONTENTS"
        let writeArgumentsData = try JSONSerialization.data(withJSONObject: [
            "path": "Sources/Mutated.swift",
            "contents": hugeContents
        ], options: [.sortedKeys])
        let writeArgumentsJSON = try XCTUnwrap(String(data: writeArgumentsData, encoding: .utf8))
        let call = APIToolCall(
            id: "call_mutated_write",
            type: "function",
            function: APIFunctionCall(name: "write_file", arguments: writeArgumentsJSON)
        )
        let callsJSON = try XCTUnwrap(String(data: JSONEncoder().encode([call]), encoding: .utf8))
        let assistantMessage = ChatMessage(role: .assistant, content: "small", toolCallsJSON: callsJSON)
        context.insert(assistantMessage)
        try context.save()

        XCTAssertLessThan(run.argumentsJSON.count, argumentsJSON.count)
        XCTAssertLessThanOrEqual(run.argumentsJSON.count, PersistedPayloadBudget.maxToolRunArgumentsCharacters)
        XCTAssertTrue(run.argumentsJSON.contains("compacted this persisted tool arguments.command") || run.argumentsJSON.contains("__novaforge_compacted"))
        XCTAssertLessThan(run.output.count, hugeOutput.count)
        XCTAssertLessThanOrEqual(run.output.count, PersistedPayloadBudget.maxToolRunOutputCharacters)
        XCTAssertTrue(run.output.contains("MUTATION-START"))
        XCTAssertTrue(run.output.contains("MUTATION-END"))

        XCTAssertLessThan(toolMessage.content.count, hugeOutput.count)
        XCTAssertLessThanOrEqual(toolMessage.content.count, PersistedPayloadBudget.maxToolMessageContentCharacters)
        XCTAssertTrue(toolMessage.content.contains("compacted this persisted tool message"))

        let persistedJSON = try XCTUnwrap(assistantMessage.toolCallsJSON)
        let persistedCalls = try JSONDecoder().decode([APIToolCall].self, from: XCTUnwrap(persistedJSON.data(using: .utf8)))
        XCTAssertEqual(persistedCalls[0].id, "call_mutated_write")
        XCTAssertLessThan(persistedCalls[0].function.arguments.count, writeArgumentsJSON.count)
        XCTAssertLessThanOrEqual(persistedCalls[0].function.arguments.count, PersistedPayloadBudget.maxToolCallArgumentsCharacters)
        XCTAssertTrue(persistedCalls[0].function.arguments.contains("Sources/Mutated.swift"))
    }

    func testFreshPromptAfterRecoverableFailureCompletesLocalToolRun() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeRecovery-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let conversation = Conversation(title: "Recovery")
        let settings = AgentSettings(provider: .local)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.simulateRecoverableFailure()
        runtime.send(prompt: "list files", conversation: conversation, settings: settings, context: context)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertNil(runtime.lastError)
        XCTAssertNil(runtime.lastFailedPrompt)
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Local run complete" })
    }

    func testSendPersistsAssistantResponseThroughProviderRuntimePath() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Send Proof", mission: "Prove Send saves the assistant response.", workspaceName: "Default")
        let conversation = Conversation(title: "Send Proof", project: project)
        let settings = AgentSettings(provider: .openAI, modelID: AIProvider.openAI.defaultModel, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime()
        runtime.debugInstallProviderResponses([
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(
                    role: "assistant",
                    content: "I can inspect files, plan changes, run builds, and capture proof screenshots.",
                    tool_calls: nil
                ),
                roleLog: "debug provider send proof"
            )
        ])

        runtime.send(
            prompt: "Show me what tools you can use",
            conversation: conversation,
            settings: settings,
            context: context,
            project: project
        )

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertNil(runtime.lastError)
        XCTAssertNil(runtime.lastFailedPrompt)
        XCTAssertEqual(conversation.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(conversation.messages.first?.content, "Show me what tools you can use")
        XCTAssertEqual(conversation.messages.last?.content, "I can inspect files, plan changes, run builds, and capture proof screenshots.")
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Response complete" })

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertTrue(events.contains { $0.kind == .promptQueued && $0.detail == "Show me what tools you can use" })
        XCTAssertTrue(events.contains { $0.kind == .responseSaved && $0.detail.contains("inspect files") })
        XCTAssertTrue(events.contains { $0.kind == .runCompleted && $0.title == "Run completed" })
        XCTAssertTrue(events.contains { $0.kind == .agentProofCreated && $0.title == "Agent proof captured" })
    }

    func testLocalDeterministicWriteHonorsReviewFirstBeforeMutation() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeLocalReviewFirst-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        let conversation = Conversation(title: "Review local write")
        let settings = AgentSettings(provider: .local, autoApproveWrites: false)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.send(
            prompt: "create file review-first.txt with approved content",
            conversation: conversation,
            settings: settings,
            context: context
        )

        let approvalDeadline = Date().addingTimeInterval(3)
        while runtime.runState != .waitingForApproval && Date() < approvalDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertEqual(runtime.runState, .waitingForApproval)
        XCTAssertEqual(runtime.pendingTool?.name, "write_file")
        XCTAssertThrowsError(try runtime.workspace.read("review-first.txt"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<ToolOperationRecord>()).isEmpty)

        runtime.approvePendingTool(conversation: conversation, settings: settings, context: context)
        let completionDeadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < completionDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertEqual(try runtime.workspace.read("review-first.txt"), "approved content")
        let reviewedReceipt = try XCTUnwrap(try context.fetch(FetchDescriptor<ToolOperationRecord>()).first)
        XCTAssertEqual(reviewedReceipt.phase, .completed)
        XCTAssertEqual(reviewedReceipt.targetPaths, ["review-first.txt"])
    }

    func testApprovalPausedRunKeepsItsCapturedWorkspaceUntilMutationSettles() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeWorkspaceLease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let startingWorkspace = SandboxWorkspace(rootURL: workspaceRoot)
        let runtime = AgentRuntime(workspace: startingWorkspace)
        let conversation = Conversation(title: "Workspace lease")
        let settings = AgentSettings(provider: .local, autoApproveWrites: false)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.send(
            prompt: "create file captured-root.txt with immutable workspace proof",
            conversation: conversation,
            settings: settings,
            context: context
        )

        let approvalDeadline = Date().addingTimeInterval(3)
        while runtime.runState != .waitingForApproval && Date() < approvalDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertEqual(runtime.runState, .waitingForApproval)
        let redirectedWorkspaceName = "Redirected-\(UUID().uuidString)"
        XCTAssertFalse(runtime.switchWorkspace(to: redirectedWorkspaceName))
        XCTAssertEqual(runtime.workspace.rootURL.standardizedFileURL, workspaceRoot.standardizedFileURL)

        runtime.approvePendingTool(
            conversation: conversation,
            settings: settings,
            context: context
        )
        let completionDeadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < completionDeadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertEqual(
            try startingWorkspace.read("captured-root.txt"),
            "immutable workspace proof"
        )
        let receipt = try XCTUnwrap(try context.fetch(FetchDescriptor<ToolOperationRecord>()).first)
        XCTAssertEqual(receipt.workspaceName, startingWorkspace.workspaceName)

        XCTAssertTrue(runtime.switchWorkspace(to: redirectedWorkspaceName))
        XCTAssertEqual(runtime.workspace.workspaceName, redirectedWorkspaceName)
        try? FileManager.default.removeItem(at: runtime.workspace.rootURL)
    }

    func testLocalNativePlanDoesNotCompleteAfterHistorySaveFailure() async throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated history save failure" }
        }

        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeSaveFailure-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let conversation = Conversation(title: "Local save failure")
        let settings = AgentSettings(provider: .local)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        var saveAttempts = 0
        runtime.debugInstallCompactedSaveOverride { saveContext in
            saveAttempts += 1
            guard saveAttempts != 4 else { throw SaveFailure.diskFull }
            try saveContext.save()
        }

        runtime.send(prompt: "list files", conversation: conversation, settings: settings, context: context)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        if case .failed(let message) = runtime.runState {
            XCTAssertTrue(message.contains("simulated history save failure"), "Actual message: \(message)")
        } else {
            XCTFail("A local/native plan must fail visibly after a history save failure. State: \(runtime.runState)")
        }
        XCTAssertTrue(
            ["Something needs attention", "Error Not Saved"].contains(runtime.activityTitle),
            "A failed history write must leave a visible recovery state."
        )
        XCTAssertFalse(runtime.traceEvents.contains { $0.title == "Local run complete" })
        XCTAssertGreaterThanOrEqual(saveAttempts, 4)
    }

    func testFinalAndErrorMessagesRollbackWhenTranscriptSaveFails() async throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated transcript save failure" }
        }

        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeTranscriptSaveFailure-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let project = Project(name: "Local transcript rollback", workspaceName: "Default")
        let conversation = Conversation(title: "Transcript save failure", project: project)
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        var saveAttempts = 0
        runtime.debugInstallCompactedSaveOverride { saveContext in
            saveAttempts += 1
            guard saveAttempts != 2 && saveAttempts != 3 else { throw SaveFailure.diskFull }
            try saveContext.save()
        }

        runtime.send(prompt: "local model is working", conversation: conversation, settings: settings, context: context)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertGreaterThanOrEqual(saveAttempts, 3)
        XCTAssertTrue(
            conversation.messages.filter { $0.role == .assistant }.isEmpty,
            "Failed final/error transcript saves should not leave unsaved assistant bubbles visible in the restored conversation."
        )
        XCTAssertEqual(runtime.activityTitle, "Error Not Saved")
        XCTAssertTrue(runtime.lastError?.contains("simulated transcript save failure") == true)
        if case .failed(let message) = runtime.runState {
            XCTAssertTrue(message.contains("simulated transcript save failure"), "Actual message: \(message)")
        } else {
            XCTFail("Transcript save failure should fail the run visibly. State: \(runtime.runState)")
        }
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Error transcript not saved" })

        // A later settings save must not commit the failed local response's
        // responseSaved/runCompleted evidence.
        settings.temperature = 0.35
        try context.save()
        let projectEvents = try context.fetch(FetchDescriptor<ProjectEvent>())
            .filter { $0.project?.id == project.id }
        XCTAssertFalse(projectEvents.contains { $0.kind == .responseSaved && $0.severity == .success })
        XCTAssertFalse(projectEvents.contains { $0.kind == .runCompleted && $0.severity == .success })
    }

    func testProviderToolTranscriptRollsBackWhenHistorySaveFails() async throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated provider tool transcript save failure" }
        }

        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeProviderToolSaveFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try "hello".write(to: workspaceRoot.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        try? runtime.saveAPIKey("unit-test-key", for: .openAI)
        let conversation = Conversation(title: "Provider tool save failure")
        let settings = AgentSettings(provider: .openAI, modelID: AIProvider.openAI.defaultModel)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let toolCall = APIToolCall(
            id: "call_list",
            type: "function",
            function: APIFunctionCall(name: "list_directory", arguments: "{}")
        )
        let toolMessage = try StreamingResponseValidator.makeMessage(
            content: "",
            toolCalls: [toolCall],
            sawDataPayload: true,
            malformedPayloadCount: 0
        )
        runtime.debugInstallProviderResponses([
            ProviderResponse(message: toolMessage, roleLog: "debug tool response")
        ])

        var saveAttempts = 0
        runtime.debugInstallCompactedSaveOverride { saveContext in
            saveAttempts += 1
            guard saveAttempts != 3 else { throw SaveFailure.diskFull }
            try saveContext.save()
        }

        runtime.send(prompt: "inspect the workspace", conversation: conversation, settings: settings, context: context)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertGreaterThanOrEqual(saveAttempts, 3)
        XCTAssertEqual(runtime.activityTitle, "Tool Results Not Saved")
        // SwiftData relationship ordering is not a transcript ordering
        // contract. The committed plan stays visible, but the unsaved tool
        // result must not survive the failed history transaction.
        XCTAssertEqual(conversation.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(conversation.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertTrue(conversation.messages.filter { $0.role == .tool }.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ToolRun>()).isEmpty)
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Tool results not saved" })
        if case .failed(let message) = runtime.runState {
            XCTAssertTrue(message.contains("simulated provider tool transcript save failure"), "Actual message: \(message)")
        } else {
            XCTFail("Provider tool transcript save failure should fail visibly. State: \(runtime.runState)")
        }
    }

    func testProviderMultiToolHistoryFailureDoesNotLeakProjectProofIntoLaterSave() async throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated multi-tool history save failure" }
        }

        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeMultiToolRollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        let project = Project(name: "Multi-tool rollback", workspaceName: "Default")
        let conversation = Conversation(title: "Multi-tool rollback", project: project)
        let settings = AgentSettings(
            provider: .openAI,
            modelID: AIProvider.openAI.defaultModel,
            autoApproveWrites: true,
            activeProjectID: project.id
        )
        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let toolCalls = [
            APIToolCall(
                id: "call_write_project_proof",
                type: "function",
                function: APIFunctionCall(
                    name: "write_file",
                    arguments: #"{"path":"proof.md","contents":"durable proof"}"#
                )
            ),
            APIToolCall(
                id: "call_terminal_project_proof",
                type: "function",
                function: APIFunctionCall(
                    name: "run_command",
                    arguments: #"{"command":"touch terminal-proof.txt"}"#
                )
            )
        ]
        let toolPlan = try StreamingResponseValidator.makeMessage(
            content: "I will create the requested proof files.",
            toolCalls: toolCalls,
            sawDataPayload: true,
            malformedPayloadCount: 0
        )
        runtime.debugInstallProviderResponses([
            ProviderResponse(message: toolPlan, roleLog: "debug multi-tool response")
        ])

        var saveAttempts = 0
        runtime.debugInstallCompactedSaveOverride { saveContext in
            saveAttempts += 1
            guard saveAttempts != 3 else { throw SaveFailure.diskFull }
            try saveContext.save()
        }

        runtime.send(
            prompt: "Create project proof through files and the terminal.",
            conversation: conversation,
            settings: settings,
            context: context,
            project: project
        )

        let deadline = Date().addingTimeInterval(4)
        while (runtime.isWorking || runtime.debugHasTrackedTask) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertFalse(runtime.debugHasTrackedTask)
        XCTAssertGreaterThanOrEqual(saveAttempts, 3)
        XCTAssertEqual(runtime.activityTitle, "Tool Results Not Saved")
        if case .failed(let message) = runtime.runState {
            XCTAssertTrue(message.contains("simulated multi-tool history save failure"), "Actual message: \(message)")
        } else {
            XCTFail("The failed multi-tool transcript must leave a failed recovery state. State: \(runtime.runState)")
        }
        XCTAssertEqual(try runtime.workspace.read("proof.md"), "durable proof")
        XCTAssertEqual(try runtime.workspace.read("terminal-proof.txt"), "")

        // This intentionally unrelated write simulates a later UI/settings save.
        // It must not resurrect any stale success evidence from the failed
        // transcript transaction.
        settings.temperature = 0.35
        try context.save()

        let toolRuns = try context.fetch(FetchDescriptor<ToolRun>())
        let artifacts = try context.fetch(FetchDescriptor<ProjectArtifact>())
        let fileChanges = try context.fetch(FetchDescriptor<ProjectFileChange>())
        let terminalCommands = try context.fetch(FetchDescriptor<TerminalCommandRecord>())
        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        let operationReceipts = try context.fetch(FetchDescriptor<ToolOperationRecord>())
        let runRecords = try context.fetch(FetchDescriptor<AgentRunRecord>())

        XCTAssertTrue(toolRuns.isEmpty, "No unsaved ToolRun may survive a later unrelated save.")
        XCTAssertTrue(artifacts.isEmpty, "No unsaved artifact may survive a later unrelated save.")
        XCTAssertTrue(fileChanges.isEmpty, "No unsaved file change may survive a later unrelated save.")
        XCTAssertTrue(terminalCommands.isEmpty, "No unsaved terminal receipt may survive a later unrelated save.")
        XCTAssertTrue(
            events.filter { $0.project?.id == project.id && $0.severity == .success }.isEmpty,
            "The failed transcript must not leave project success evidence behind."
        )
        XCTAssertEqual(conversation.messages.filter { $0.role == .tool }.count, 0)
        XCTAssertEqual(operationReceipts.count, 2, "Write-ahead operation receipts remain durable because both workspace mutations really ran.")
        XCTAssertTrue(operationReceipts.allSatisfy { $0.phase == .completed })
        XCTAssertEqual(runRecords.last?.status, .failed)
    }

    func testProviderSwitchResetsStaleModelsButRepairKeepsManualExactAPIModel() throws {
        let settings = AgentSettings(provider: .openAI, modelID: "gpt-5.5-preview-manual")

        XCTAssertFalse(settings.repairStaleModelSelection(), "Manual exact API model IDs should stay valid within the same provider.")
        XCTAssertEqual(settings.modelID, "gpt-5.5-preview-manual")

        XCTAssertTrue(settings.switchProvider(to: .openAICodex))
        XCTAssertEqual(settings.provider, .openAICodex)
        XCTAssertEqual(settings.modelID, AIProvider.openAICodex.defaultModel)

        settings.modelID = AIProvider.local.defaultModel
        XCTAssertTrue(settings.switchProvider(to: .openAI))
        XCTAssertEqual(settings.provider, .openAI)
        XCTAssertEqual(settings.modelID, AIProvider.openAI.defaultModel)
    }

    func testRuntimeRepairsStaleProviderModelBeforeMissingKeyFailure() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeProviderRepair-\(UUID().uuidString)", isDirectory: true)
            )
        )
        try? runtime.saveAPIKey("", for: .custom)
        let conversation = Conversation(title: "Provider repair")
        let settings = AgentSettings(provider: .custom, modelID: AIProvider.local.defaultModel)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.send(prompt: "Call the configured provider", conversation: conversation, settings: settings, context: context)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(settings.modelID, AIProvider.custom.defaultModel)
        if case .failed(let message) = runtime.runState {
            XCTAssertTrue(message.contains("Add the API key"))
            XCTAssertTrue(message.contains("NovaForge did not fake a provider response"))
        } else {
            XCTFail("Missing custom-provider key should fail cleanly after model repair. State: \(runtime.runState)")
        }
    }

    func testRuntimeStaleModelRepairRollsBackAfterSaveFailure() async throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated stale model repair save failure" }
        }

        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeRepairRollback-\(UUID().uuidString)", isDirectory: true)
            )
        )
        try? runtime.saveAPIKey("", for: .custom)
        let conversation = Conversation(title: "Provider repair rollback")
        let staleModelID = AIProvider.local.defaultModel
        let settings = AgentSettings(provider: .custom, modelID: staleModelID)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        var saveAttempts = 0
        runtime.debugInstallCompactedSaveOverride { saveContext in
            saveAttempts += 1
            guard saveAttempts != 2 else { throw SaveFailure.diskFull }
            try saveContext.save()
        }

        runtime.send(prompt: "Call the configured provider", conversation: conversation, settings: settings, context: context)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertGreaterThanOrEqual(saveAttempts, 2)
        XCTAssertEqual(settings.modelID, staleModelID, "Failed stale-model repair must restore the user's previous provider/model state.")
        if case .failed(let message) = runtime.runState {
            XCTAssertTrue(message.contains("simulated stale model repair save failure"), "Actual message: \(message)")
            XCTAssertFalse(message.contains("Add the API key"), "A failed repair must stop before provider setup/network work. Actual message: \(message)")
        } else {
            XCTFail("Stale model repair save failure should fail the run visibly. State: \(runtime.runState)")
        }
        XCTAssertEqual(runtime.activityTitle, "Something needs attention")
    }

    func testAcceptedQueuedFollowUpSurvivesProviderFailureWithoutAutoRunning() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeFailedQueue-\(UUID().uuidString)", isDirectory: true)
            )
        )
        try? runtime.saveAPIKey("", for: .custom)
        let conversation = Conversation(title: "Failed provider queue")
        let settings = AgentSettings(provider: .custom, modelID: AIProvider.custom.defaultModel)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.send(prompt: "Call the custom provider", conversation: conversation, settings: settings, context: context)
        runtime.send(prompt: "queued follow-up should not auto-run", conversation: conversation, settings: settings, context: context)
        XCTAssertEqual(runtime.queuedPromptCount, 1)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        if case .failed(let message) = runtime.runState {
            XCTAssertTrue(message.contains("Add the API key"))
        } else {
            XCTFail("Provider setup failure should leave the original run failed, not auto-drain queued follow-ups. State: \(runtime.runState)")
        }
        XCTAssertEqual(runtime.queuedPromptCount, 0)
        let queuedMessage = try XCTUnwrap(conversation.messages.first { $0.content == "queued follow-up should not auto-run" })
        let queuedReceipt = try XCTUnwrap(
            try context.fetch(FetchDescriptor<AgentRunRecord>()).first { $0.id == queuedMessage.runID }
        )
        XCTAssertEqual(queuedMessage.runStatus, .interrupted)
        XCTAssertEqual(queuedReceipt.status, .interrupted)
        XCTAssertNil(queuedReceipt.startedAt, "The queued follow-up was never allowed to execute after the predecessor failed.")
        XCTAssertEqual(conversation.messages.filter { $0.content == queuedMessage.content }.count, 1)
    }

    func testFreshPromptDropsStaleQueuedFollowUpBeforeRunStarts() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeStaleQueue-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let conversation = Conversation(title: "Stale queue")
        let settings = AgentSettings(provider: .openAI)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.simulateRecoverableFailure()
        runtime.debugInstallProviderResponses([
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(role: "assistant", content: "Recovered.", tool_calls: nil),
                roleLog: "stale-queue-fresh-prompt"
            )
        ])
        runtime.debugQueueFollowUp("stale queued prompt", conversation: conversation)
        XCTAssertEqual(runtime.queuedPromptCount, 1)

        runtime.send(prompt: "list files", conversation: conversation, settings: settings, context: context)
        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertEqual(runtime.queuedPromptCount, 0)
        XCTAssertFalse(conversation.messages.contains { $0.content == "stale queued prompt" })
    }

    func testRetryAfterRecoverableFailureClearsErrorAndStaleQueue() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeRetryRecovery-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let conversation = Conversation(title: "Retry recovery")
        let settings = AgentSettings(provider: .openAI)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.simulateRecoverableFailure(failedPrompt: "list files")
        runtime.debugInstallProviderResponses([
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(role: "assistant", content: "Retried.", tool_calls: nil),
                roleLog: "stale-queue-retry"
            )
        ])
        runtime.debugQueueFollowUp("stale queued retry prompt", conversation: conversation)
        XCTAssertEqual(runtime.queuedPromptCount, 1)

        runtime.retryLastPrompt(conversation: conversation, settings: settings, context: context)
        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertNil(runtime.lastError)
        XCTAssertNil(runtime.lastFailedPrompt)
        XCTAssertEqual(runtime.queuedPromptCount, 0)
        XCTAssertFalse(conversation.messages.contains { $0.content == "stale queued retry prompt" })
    }

    func testContinueAfterRecoverableFailureClearsErrorAndStaleQueue() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeContinueRecovery-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let conversation = Conversation(title: "Continue recovery")
        let settings = AgentSettings(provider: .openAI)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.simulateRecoverableFailure(failedPrompt: "list files")
        runtime.debugInstallProviderResponses([
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(role: "assistant", content: "Continued.", tool_calls: nil),
                roleLog: "stale-queue-continue"
            )
        ])
        runtime.debugQueueFollowUp("stale queued continue prompt", conversation: conversation)
        XCTAssertEqual(runtime.queuedPromptCount, 1)

        runtime.continueAfterInterruption(conversation: conversation, settings: settings, context: context)
        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertNil(runtime.lastError)
        XCTAssertNil(runtime.lastFailedPrompt)
        XCTAssertEqual(runtime.queuedPromptCount, 0)
        XCTAssertFalse(conversation.messages.contains { $0.content == "stale queued continue prompt" })
    }

    func testStopGeneratingActiveRunClearsQueuedFollowUpsAndWorkingState() throws {
        let runtime = AgentRuntime()
        let conversation = Conversation(title: "Cancel queued follow-up")

        runtime.simulateStreamingStress()
        runtime.debugQueueFollowUp("queued prompt should be discarded on stop", conversation: conversation)
        XCTAssertTrue(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .running)
        XCTAssertEqual(runtime.queuedPromptCount, 1)

        runtime.stopGenerating()

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .cancelled)
        XCTAssertEqual(runtime.queuedPromptCount, 0)
        XCTAssertTrue(runtime.wasInterrupted)
        XCTAssertNil(runtime.pendingTool)
    }

    func testQueuedFollowUpsAreCappedDuringActiveRun() throws {
        let schema = TestModelSchema.projectFoundation
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let runtime = AgentRuntime()
        let conversation = Conversation(title: "Queue cap")
        let settings = AgentSettings(provider: .local)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.simulateStreamingStress()
        let dispositions = (1...5).map { index in
            runtime.send(prompt: "queued follow-up \(index)", conversation: conversation, settings: settings, context: context)
        }

        XCTAssertEqual(runtime.queuedPromptCount, 3)
        XCTAssertEqual(
            dispositions,
            [
                .queued(position: 1),
                .queued(position: 2),
                .queued(position: 3),
                .rejected(.followUpQueueFull(limit: 3)),
                .rejected(.followUpQueueFull(limit: 3))
            ]
        )
        XCTAssertEqual(runtime.activityTitle, "Follow-up queue full")
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Follow-up not queued" })

        runtime.stopGenerating()
    }

    func testInitialSendRejectsSynchronouslyWhenAcceptanceReceiptCannotBeSaved() throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated send acceptance failure" }
        }

        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Acceptance Boundary")
        let conversation = Conversation(title: "Acceptance Boundary", project: project)
        let settings = AgentSettings(provider: .openAI, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime()
        runtime.debugInstallProviderResponses([
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(role: "assistant", content: "must not start", tool_calls: nil),
                roleLog: "must remain unused"
            )
        ])
        runtime.debugInstallCompactedSaveOverride { _ in throw SaveFailure.diskFull }

        let originalUpdatedAt = conversation.updatedAt
        let disposition = runtime.send(
            prompt: "keep this exact draft",
            conversation: conversation,
            settings: settings,
            context: context,
            project: project
        )

        guard case .rejected(.persistenceFailed(let detail)) = disposition else {
            return XCTFail("A failed acceptance transaction must reject synchronously. Got \(disposition)")
        }
        XCTAssertTrue(detail.contains("simulated send acceptance failure"))
        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .idle)
        XCTAssertFalse(runtime.debugHasTrackedTask, "Provider/tool work must not start before the acceptance receipt commits.")
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertEqual(conversation.messageCount, 0)
        XCTAssertEqual(conversation.updatedAt, originalUpdatedAt)
        XCTAssertTrue(project.events.isEmpty, "A rejected send must not leave an unsaved prompt event behind.")
        XCTAssertTrue(try context.fetch(FetchDescriptor<ChatMessage>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AgentRunRecord>()).isEmpty)
    }

    func testAcceptedUserRequestPreservesItsFullDurableText() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let conversation = Conversation(title: "Full request")
        let settings = AgentSettings(provider: .openAI)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let request = "REQUEST-HEAD\n" +
            String(repeating: "durable request body ", count: 1_800) +
            "\nREQUEST-UNIQUE-MIDDLE\n" +
            String(repeating: "after middle ", count: 1_800) +
            "\nREQUEST-TAIL"
        XCTAssertGreaterThan(request.count, PersistedPayloadBudget.maxMessageContentCharacters)

        let runtime = AgentRuntime()
        runtime.debugInstallProviderResponses([
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(role: "assistant", content: "Acknowledged.", tool_calls: nil),
                roleLog: "full-request-test"
            )
        ])

        XCTAssertEqual(
            runtime.send(prompt: request, conversation: conversation, settings: settings, context: context),
            .started
        )
        let persistedUserMessage = try XCTUnwrap(conversation.messages.first { $0.role == .user })
        XCTAssertEqual(persistedUserMessage.content, request)
        XCTAssertTrue(persistedUserMessage.content.contains("REQUEST-UNIQUE-MIDDLE"))
        XCTAssertTrue(persistedUserMessage.content.hasSuffix("REQUEST-TAIL"))
        runtime.stopGenerating(context: context)
    }

    func testRunOnlyRecoveryProducesVisibleOperatorFeedback() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        context.insert(AgentRunRecord(status: .running))
        try context.save()

        let runtime = AgentRuntime()
        XCTAssertEqual(runtime.reconcileInterruptedDurableWork(context: context), 1)
        XCTAssertTrue(
            runtime.toasts.contains { $0.message.contains("Recovered 1 interrupted run") },
            "Run recovery must not stay silent when there are no workspace-operation receipts."
        )
    }

    func testGeneralSnapshotDoesNotBorrowProjectEvidence() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Proof-rich project", workspaceName: "Project")
        let projectConversation = Conversation(title: "Project", project: project)
        let generalConversation = Conversation(title: "General")
        let projectRun = ToolRun(
            name: "write_file",
            argumentsJSON: #"{"path":"project.html"}"#,
            output: "Wrote project.html",
            status: .completed,
            project: project
        )
        let projectArtifact = ProjectArtifact(project: project, path: "project.html", sourceToolRunID: projectRun.id)
        let projectTerminal = TerminalCommandRecord(
            project: project,
            command: "validate_html project.html",
            output: "ok",
            status: .completed,
            workspaceName: "Project",
            durationMs: 1,
            sourceToolRunID: projectRun.id
        )
        context.insert(project)
        context.insert(projectConversation)
        context.insert(generalConversation)
        context.insert(projectRun)
        context.insert(projectArtifact)
        context.insert(projectTerminal)
        try context.save()

        let general = ChatDurableRunSnapshot.make(project: nil, conversation: generalConversation, context: context)
        let scoped = ChatDurableRunSnapshot.make(project: project, conversation: projectConversation, context: context)

        XCTAssertTrue(general.artifacts.isEmpty)
        XCTAssertTrue(general.traceEvents.isEmpty)
        XCTAssertNil(general.latestProof)
        XCTAssertNil(general.latestTerminalProof)
        XCTAssertNil(general.projectOSRun)
        XCTAssertFalse(scoped.artifacts.isEmpty)
        XCTAssertNotNil(scoped.latestTerminalProof)
    }

    func testDurableSnapshotRebuildsWhenConversationMovesToGeneral() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Scoped evidence", workspaceName: "Scoped")
        let conversation = Conversation(title: "Movable scope", project: project)
        let run = ToolRun(
            name: "write_file",
            argumentsJSON: #"{"path":"scoped.html"}"#,
            output: "Wrote scoped.html",
            status: .completed,
            project: project
        )
        let artifact = ProjectArtifact(project: project, path: "scoped.html", sourceToolRunID: run.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(run)
        context.insert(artifact)
        try context.save()

        let projectSnapshot = ChatDurableRunSnapshot.make(
            project: conversation.project,
            conversation: conversation,
            context: context
        )
        conversation.project = nil
        let generalSnapshot = ChatDurableRunSnapshot.make(
            project: conversation.project,
            conversation: conversation,
            context: context
        )

        XCTAssertFalse(projectSnapshot.artifacts.isEmpty)
        XCTAssertFalse(projectSnapshot.traceEvents.isEmpty)
        XCTAssertTrue(generalSnapshot.artifacts.isEmpty)
        XCTAssertTrue(generalSnapshot.traceEvents.isEmpty)
        XCTAssertNil(generalSnapshot.latestTerminalProof)
    }

    func testQueuedFollowUpRejectsAndRollsBackWhenItsVisibleMessageCannotBeSaved() throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated queued message failure" }
        }

        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let conversation = Conversation(title: "Queue Acceptance")
        let settings = AgentSettings(provider: .local)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime()
        runtime.debugSimulateActiveStatusStripRun(conversation: conversation)
        runtime.debugInstallCompactedSaveOverride { _ in throw SaveFailure.diskFull }
        let originalUpdatedAt = conversation.updatedAt

        let disposition = runtime.send(
            prompt: "do not lose this queued draft",
            conversation: conversation,
            settings: settings,
            context: context
        )

        guard case .rejected(.persistenceFailed(let detail)) = disposition else {
            return XCTFail("An unsaved follow-up must remain a draft. Got \(disposition)")
        }
        XCTAssertTrue(detail.contains("simulated queued message failure"))
        XCTAssertEqual(runtime.queuedPromptCount, 0)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertEqual(conversation.updatedAt, originalUpdatedAt)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ChatMessage>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AgentRunRecord>()).isEmpty)
    }

    func testQueuedFollowUpAcceptanceCommitsMessageAndReceiptTogether() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Queue Scope", workspaceName: "QueueScope")
        let conversation = Conversation(title: "Queue Scope", project: project)
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        settings.autoApproveWrites = true
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime()
        runtime.debugSimulateActiveStatusStripRun(conversation: conversation)
        XCTAssertEqual(
            runtime.send(
                prompt: "Keep this accepted follow-up exactly once.",
                conversation: conversation,
                settings: settings,
                context: context,
                project: project
            ),
            .queued(position: 1)
        )

        let message = try XCTUnwrap(conversation.messages.first)
        let receipt = try XCTUnwrap(
            try context.fetch(FetchDescriptor<AgentRunRecord>()).first { $0.id == message.runID }
        )
        XCTAssertEqual(message.runStatus, .queued)
        XCTAssertEqual(receipt.status, .queued)
        XCTAssertNil(receipt.startedAt)
        XCTAssertEqual(receipt.requestMessageID, message.id)
        XCTAssertEqual(receipt.conversationID, conversation.id)
        XCTAssertEqual(receipt.projectID, project.id)
        XCTAssertEqual(receipt.provider, settings.provider)
    }

    func testDrainKeepsPersistedQueuedMessageWhenStartingItsRunReceiptFails() async throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated queued run receipt failure" }
        }

        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let conversation = Conversation(title: "Durable Queue Drain")
        let settings = AgentSettings(provider: .openAI)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime()
        runtime.debugInstallProviderResponses([
            ProviderResponse(
                message: ChatCompletionsResponse.Choice.Message(
                    role: "assistant",
                    content: String(repeating: "finish the active response before draining. ", count: 4),
                    tool_calls: nil
                ),
                roleLog: "debug queue drain completion"
            )
        ])

        XCTAssertEqual(
            runtime.send(prompt: "finish first", conversation: conversation, settings: settings, context: context),
            .started
        )
        XCTAssertEqual(
            runtime.send(prompt: "persist me through a failed drain", conversation: conversation, settings: settings, context: context),
            .queued(position: 1)
        )

        var saveAttempts = 0
        var rejectedQueuedRunReceipt = false
        runtime.debugInstallCompactedSaveOverride { saveContext in
            saveAttempts += 1
            let queuedMessageIsPromoting = conversation.messages.contains { message in
                message.content == "persist me through a failed drain" &&
                    message.runID != nil &&
                    message.runStatus == .running
            }
            if queuedMessageIsPromoting {
                rejectedQueuedRunReceipt = true
                throw SaveFailure.diskFull
            }
            try saveContext.save()
        }

        let deadline = Date().addingTimeInterval(4)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertGreaterThanOrEqual(saveAttempts, 1)
        XCTAssertTrue(rejectedQueuedRunReceipt)
        XCTAssertEqual(runtime.queuedPromptCount, 1, "Failed run-receipt creation must leave the durable queue item available for retry.")
        let queued = try XCTUnwrap(conversation.messages.first { $0.content == "persist me through a failed drain" })
        XCTAssertNotNil(queued.runID)
        XCTAssertEqual(queued.runStatus, .queued)
        let queuedReceipt = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentRunRecord>()).first { $0.id == queued.runID })
        XCTAssertEqual(queuedReceipt.status, .queued)
        XCTAssertNil(queuedReceipt.startedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<AgentRunRecord>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChatMessage>()).filter { $0.content == queued.content }.count, 1)
    }

    func testOversizedFollowUpIsRejectedWhileRunIsActive() throws {
        let schema = TestModelSchema.projectFoundation
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let runtime = AgentRuntime()
        let conversation = Conversation(title: "Oversized queue")
        let settings = AgentSettings(provider: .local)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.simulateStreamingStress()
        let disposition = runtime.send(
            prompt: String(repeating: "large prompt ", count: 500),
            conversation: conversation,
            settings: settings,
            context: context
        )

        XCTAssertEqual(runtime.queuedPromptCount, 0)
        XCTAssertEqual(disposition, .rejected(.followUpTooLong(limit: 4_000)))
        XCTAssertEqual(runtime.activityTitle, "Follow-up too long")
        XCTAssertTrue(runtime.traceEvents.contains { event in
            event.title == "Follow-up not queued" && event.detail.contains("over 4000 characters")
        })

        runtime.stopGenerating()
    }

    func testCancelledStaleTaskCannotUntrackFreshStreamingRun() async throws {
        let runtime = AgentRuntime()

        runtime.simulateStreamingStress()
        XCTAssertTrue(runtime.debugHasTrackedTask)
        runtime.stopGenerating()
        XCTAssertFalse(runtime.debugHasTrackedTask)

        runtime.simulateStreamingStress()
        XCTAssertTrue(runtime.debugHasTrackedTask)
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertTrue(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .running)
        XCTAssertTrue(runtime.debugHasTrackedTask, "A cancelled stale task must not clear the fresh run's tracked task handle.")

        runtime.stopGenerating()
    }

    func testStaleAsyncCompletionCannotOverwriteFreshRunState() async throws {
        let runtime = AgentRuntime()

        runtime.debugSimulateDelayedCompletionForActiveRun(delayMilliseconds: 140)
        XCTAssertTrue(runtime.debugHasTrackedTask)
        runtime.stopGenerating()
        XCTAssertFalse(runtime.debugHasTrackedTask)

        runtime.simulateStreamingStress()
        XCTAssertTrue(runtime.debugHasTrackedTask)
        try await Task.sleep(for: .milliseconds(260))

        XCTAssertTrue(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .running)
        XCTAssertNotEqual(runtime.activityTitle, "Stale completion applied")
        XCTAssertFalse(runtime.traceEvents.contains { $0.title == "Delayed completion applied" })

        runtime.stopGenerating()
    }

    func testWorkspaceSwitchWaitsForActivelyExecutingRunToSettle() async throws {
        let runtime = AgentRuntime()
        let startingWorkspaceName = runtime.workspace.workspaceName
        let nextWorkspaceName = "AfterActiveRun-\(UUID().uuidString)"

        runtime.debugSimulateDelayedCompletionForActiveRun(delayMilliseconds: 120)
        XCTAssertTrue(runtime.isWorking)
        XCTAssertFalse(runtime.switchWorkspace(to: nextWorkspaceName))
        XCTAssertEqual(runtime.workspace.workspaceName, startingWorkspaceName)

        let deadline = Date().addingTimeInterval(2)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }

        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertTrue(runtime.switchWorkspace(to: nextWorkspaceName))
        XCTAssertEqual(runtime.workspace.workspaceName, nextWorkspaceName)
        try? FileManager.default.removeItem(at: runtime.workspace.rootURL)
    }

    func testClearFailureStateDropsRetryMetadataAndQueuedFollowUps() throws {
        let runtime = AgentRuntime()
        let conversation = Conversation(title: "Clear failure")

        runtime.simulateRecoverableFailure()
        runtime.debugQueueFollowUp("queued prompt to clear", conversation: conversation)
        XCTAssertNotNil(runtime.lastError)
        XCTAssertNotNil(runtime.lastFailedPrompt)
        XCTAssertEqual(runtime.queuedPromptCount, 1)

        runtime.clearCurrentRunState(keepLastFailure: false)

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .idle)
        XCTAssertNil(runtime.lastError)
        XCTAssertNil(runtime.lastFailedPrompt)
        XCTAssertEqual(runtime.queuedPromptCount, 0)
        XCTAssertFalse(runtime.wasInterrupted)
    }

    func testStopGeneratingRejectsPendingApprovalRun() throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let runtime = AgentRuntime()
        let request = ToolRequest(
            id: "pending-write",
            name: "write_file",
            arguments: ["path": "index.html", "contents": "hi"]
        )
        let run = ToolRun(
            name: request.name,
            argumentsJSON: "{}",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true
        )
        context.insert(run)
        try context.save()

        runtime.debugInstallPendingApproval(request: request, run: run)
        runtime.stopGenerating(context: context)

        XCTAssertNil(runtime.pendingTool)
        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(run.status, ToolRunStatus.rejected)
        XCTAssertEqual(run.output, "Cancelled while waiting for approval.")
        XCTAssertNotNil(run.completedAt)
    }

    func testStopGeneratingKeepsPendingApprovalVisibleAfterSaveFailure() throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated cancellation save failure" }
        }

        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let runtime = AgentRuntime()
        let request = ToolRequest(
            id: "pending-cancel-save-failure",
            name: "write_file",
            arguments: ["path": "index.html", "contents": "hi"]
        )
        let run = ToolRun(
            name: request.name,
            argumentsJSON: request.argumentsJSON,
            output: "Waiting for approval.",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true
        )
        context.insert(run)
        try context.save()

        runtime.debugInstallPendingApproval(request: request, run: run)
        runtime.debugInstallCompactedSaveOverride { _ in throw SaveFailure.diskFull }

        runtime.stopGenerating(context: context)

        XCTAssertEqual(runtime.pendingTool?.id, request.id)
        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .waitingForApproval)
        XCTAssertEqual(run.status, .pendingApproval)
        XCTAssertEqual(run.output, "Waiting for approval.")
        XCTAssertNil(run.completedAt)
        XCTAssertEqual(runtime.activityTitle, "Cancellation Not Saved")
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Cancellation not saved" })
    }

    func testPendingApprovalFixtureUsesWaitingStateInsteadOfWorkingSpinner() throws {
        let runtime = AgentRuntime()
        let request = ToolRequest(
            id: "pending-write",
            name: "write_file",
            arguments: ["path": "approval-demo.html", "contents": "demo"]
        )
        let run = ToolRun(
            name: request.name,
            argumentsJSON: request.argumentsJSON,
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true
        )

        runtime.debugInstallPendingApproval(request: request, run: run)

        XCTAssertEqual(runtime.pendingTool?.id, request.id)
        XCTAssertFalse(runtime.isWorking, "Waiting for approval should not look like a stuck live run.")
        XCTAssertEqual(runtime.runState, .waitingForApproval)
        XCTAssertEqual(runtime.activeToolName, "write_file")
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Approval needed" })
    }

    func testApprovingPendingToolMarksRunApprovedBeforeExecutionFinishes() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let conversation = Conversation(title: "Approval transition")
        let settings = AgentSettings(provider: .custom, modelID: AIProvider.custom.defaultModel)
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeApproval-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let request = ToolRequest(
            id: "pending-write",
            name: "write_file",
            arguments: ["path": "approved-transition.txt", "contents": "approved"]
        )
        let run = ToolRun(
            name: request.name,
            argumentsJSON: request.argumentsJSON,
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true
        )
        context.insert(conversation)
        context.insert(settings)
        context.insert(run)
        try context.save()

        runtime.debugInstallPendingApproval(request: request, run: run)
        runtime.approvePendingTool(conversation: conversation, settings: settings, context: context)

        XCTAssertEqual(run.status, .approved)
        XCTAssertEqual(run.output, "Approved by user; execution started.")
        XCTAssertNil(runtime.pendingTool)
        XCTAssertEqual(runtime.runState, .running)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(runtime.isWorking)
    }

    func testApprovedMutatingToolRecordsProjectFileChange() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let project = Project(name: "Tool File Changes", workspaceName: "Default")
        let conversation = Conversation(title: "Approval file change", project: project)
        let settings = AgentSettings(
            provider: .custom,
            modelID: AIProvider.custom.defaultModel,
            activeProjectID: project.id
        )
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeRuntimeToolFileChange-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        let request = ToolRequest(
            id: "pending-write-file-change",
            name: "write_file",
            arguments: ["path": "approved-file-change.txt", "contents": "approved"]
        )
        let run = ToolRun(
            name: request.name,
            argumentsJSON: request.argumentsJSON,
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true,
            project: project
        )
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        context.insert(run)
        try context.save()

        runtime.debugInstallPendingApproval(request: request, run: run)
        runtime.approvePendingTool(conversation: conversation, settings: settings, context: context, project: project)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let changes = try context.fetch(FetchDescriptor<ProjectFileChange>())
        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.project?.id, project.id)
        XCTAssertEqual(changes.first?.sourceToolRunIDString, run.id.uuidString)
        XCTAssertEqual(changes.first?.action, "Wrote file")
        XCTAssertEqual(changes.first?.path, "approved-file-change.txt")
        XCTAssertTrue(events.contains { event in
            event.kind == .fileChanged &&
            event.sourceIDString == changes.first?.id.uuidString &&
            event.detail == "approved-file-change.txt"
        })
        XCTAssertEqual(run.status, .completed)
    }

    func testLocalNativeWriteCreatesLinkedDurableProofRecords() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let project = Project(name: "Local Proof Chain", workspaceName: "Default")
        let conversation = Conversation(title: "Local proof chain", project: project)
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        settings.autoApproveWrites = true
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeLocalProofChain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))

        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        runtime.send(
            prompt: "create file chat-proof.html with <!doctype html><html><body><h1>Chat proof</h1></body></html>",
            conversation: conversation,
            settings: settings,
            context: context,
            project: project
        )

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertEqual(try runtime.workspace.read("chat-proof.html"), "<!doctype html><html><body><h1>Chat proof</h1></body></html>")

        let runs = try context.fetch(FetchDescriptor<ToolRun>())
        let run = try XCTUnwrap(runs.first { $0.name == "write_file" })
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.project?.id, project.id)
        XCTAssertEqual(run.output, "Wrote chat-proof.html")

        let artifacts = try context.fetch(FetchDescriptor<ProjectArtifact>())
        let artifact = try XCTUnwrap(artifacts.first { $0.path == "chat-proof.html" })
        XCTAssertEqual(artifact.project?.id, project.id)
        XCTAssertEqual(artifact.sourceToolRunIDString, run.id.uuidString)

        let changes = try context.fetch(FetchDescriptor<ProjectFileChange>())
        let change = try XCTUnwrap(changes.first { $0.path == "chat-proof.html" })
        XCTAssertEqual(change.action, "Wrote file")
        XCTAssertEqual(change.project?.id, project.id)
        XCTAssertEqual(change.sourceToolRunIDString, run.id.uuidString)

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertTrue(events.contains { event in
            event.kind == .toolCompleted &&
            event.sourceType == .toolRun &&
            event.sourceIDString == run.id.uuidString
        })
        XCTAssertTrue(events.contains { event in
            event.kind == .artifactCreated &&
            event.sourceType == .artifact &&
            event.sourceIDString == artifact.id.uuidString &&
            event.metadata["path"] == "chat-proof.html"
        })
        XCTAssertTrue(events.contains { event in
            event.kind == .fileChanged &&
            event.sourceIDString == change.id.uuidString &&
            event.metadata["action"] == "Wrote file"
        })
        XCTAssertTrue(events.contains { event in
            event.kind == .runCompleted &&
            event.sourceType == .conversation &&
            event.sourceIDString == conversation.id.uuidString
        })
        XCTAssertTrue(events.contains { event in
            event.kind == .agentProofCreated &&
            event.sourceType == .conversation &&
            event.sourceIDString == conversation.id.uuidString
        })
    }

    func testGeneralLocalNativeWritePersistsUnscopedDurableEvidence() async throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let unrelatedProject = Project(name: "Unrelated Project", workspaceName: "Project")
        let conversation = Conversation(title: "General proof chain")
        let settings = AgentSettings(provider: .local, autoApproveWrites: true)
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeGeneralProofChain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }
        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))

        context.insert(unrelatedProject)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        XCTAssertEqual(
            runtime.send(
                prompt: "create file general-proof.html with <!doctype html><html><body><h1>General proof</h1></body></html>",
                conversation: conversation,
                settings: settings,
                context: context,
                project: nil
            ),
            .started
        )

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertEqual(
            try runtime.workspace.read("general-proof.html"),
            "<!doctype html><html><body><h1>General proof</h1></body></html>"
        )

        let canonicalRun = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentRunRecord>()).first)
        XCTAssertEqual(canonicalRun.status, .completed)
        XCTAssertEqual(canonicalRun.conversationID, conversation.id)
        XCTAssertNil(canonicalRun.projectID)

        let toolRun = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ToolRun>()).first { $0.name == "write_file" }
        )
        XCTAssertEqual(toolRun.status, .completed)
        XCTAssertNil(toolRun.project)
        XCTAssertEqual(toolRun.runID, canonicalRun.id)

        let operation = try XCTUnwrap(try context.fetch(FetchDescriptor<ToolOperationRecord>()).first)
        XCTAssertEqual(operation.phase, .completed)
        XCTAssertEqual(operation.runID, canonicalRun.id)
        XCTAssertEqual(operation.conversationID, conversation.id)
        XCTAssertNil(operation.projectID)
        XCTAssertEqual(operation.targetPaths, ["general-proof.html"])

        let artifact = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ProjectArtifact>()).first { $0.path == "general-proof.html" }
        )
        XCTAssertNil(artifact.project)
        XCTAssertEqual(artifact.sourceToolRunIDString, toolRun.id.uuidString)

        let change = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ProjectFileChange>()).first { $0.path == "general-proof.html" }
        )
        XCTAssertNil(change.project)
        XCTAssertNil(change.sourceEventIDString)
        XCTAssertEqual(change.sourceToolRunIDString, toolRun.id.uuidString)

        XCTAssertTrue(try context.fetch(FetchDescriptor<ProjectEvent>()).isEmpty)
        XCTAssertTrue(unrelatedProject.events.isEmpty)
    }

    func testApprovePendingToolKeepsApprovalVisibleAfterSaveFailure() throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated approval save failure" }
        }

        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let project = Project(name: "Approval save failure", workspaceName: "Default")
        let conversation = Conversation(title: "Approval save failure", project: project)
        let settings = AgentSettings(provider: .custom, modelID: AIProvider.custom.defaultModel, activeProjectID: project.id)
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeApprovalSaveFailure-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let request = ToolRequest(
            id: "pending-write-save-failure",
            name: "write_file",
            arguments: ["path": "should-not-run.txt", "contents": "blocked"]
        )
        let run = ToolRun(
            name: request.name,
            argumentsJSON: request.argumentsJSON,
            output: "Waiting for approval.",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true,
            project: project
        )
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        context.insert(run)
        try context.save()

        runtime.debugInstallPendingApproval(request: request, run: run)
        runtime.debugInstallCompactedSaveOverride { _ in throw SaveFailure.diskFull }

        runtime.approvePendingTool(conversation: conversation, settings: settings, context: context)

        XCTAssertEqual(runtime.pendingTool?.id, request.id)
        XCTAssertEqual(run.status, .pendingApproval)
        XCTAssertEqual(run.output, "Waiting for approval.")
        XCTAssertNil(run.completedAt)
        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .waitingForApproval)
        XCTAssertFalse(runtime.debugHasTrackedTask)
        XCTAssertEqual(runtime.activityTitle, "Approval Not Saved")
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Approval not saved" })
        settings.temperature = 0.3
        try context.save()
        XCTAssertFalse(try context.fetch(FetchDescriptor<ProjectEvent>()).contains { $0.kind == .toolApproved })
    }

    func testRejectPendingToolKeepsApprovalVisibleAfterSaveFailure() async throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated rejection save failure" }
        }

        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let project = Project(name: "Rejection save failure", workspaceName: "Default")
        let conversation = Conversation(title: "Rejection save failure", project: project)
        let settings = AgentSettings(provider: .custom, modelID: AIProvider.custom.defaultModel, activeProjectID: project.id)
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeRejectionSaveFailure-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let request = ToolRequest(
            id: "pending-reject-save-failure",
            name: "write_file",
            arguments: ["path": "should-not-run.txt", "contents": "blocked"]
        )
        let run = ToolRun(
            name: request.name,
            argumentsJSON: request.argumentsJSON,
            output: "Waiting for approval.",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true,
            project: project
        )
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        context.insert(run)
        try context.save()

        runtime.debugInstallPendingApproval(request: request, run: run)
        runtime.debugInstallCompactedSaveOverride { _ in throw SaveFailure.diskFull }

        runtime.rejectPendingTool(conversation: conversation, settings: settings, context: context)

        let deadline = Date().addingTimeInterval(3)
        while runtime.debugHasTrackedTask && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(runtime.pendingTool?.id, request.id)
        XCTAssertEqual(run.status, .pendingApproval)
        XCTAssertEqual(run.output, "Waiting for approval.")
        XCTAssertNil(run.completedAt)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .waitingForApproval)
        XCTAssertFalse(runtime.debugHasTrackedTask)
        XCTAssertEqual(runtime.activityTitle, "Rejection Not Saved")
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Rejection not saved" })
        settings.temperature = 0.3
        try context.save()
        XCTAssertFalse(try context.fetch(FetchDescriptor<ProjectEvent>()).contains { $0.kind == .toolRejected })
    }

    func testApprovedToolResultRollsBackWhenHistorySaveFails() async throws {
        enum SaveFailure: LocalizedError {
            case diskFull

            var errorDescription: String? { "simulated approved tool result save failure" }
        }

        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let project = Project(name: "Approved Save Failure", workspaceName: "Default")
        let conversation = Conversation(title: "Approved tool save failure", project: project)
        let settings = AgentSettings(
            provider: .custom,
            modelID: AIProvider.custom.defaultModel,
            activeProjectID: project.id
        )
        let runtime = AgentRuntime(
            workspace: SandboxWorkspace(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("NovaForgeRuntimeApprovedToolSaveFailure-\(UUID().uuidString)", isDirectory: true)
            )
        )
        let request = ToolRequest(
            id: "pending-approved-result-save-failure",
            name: "write_file",
            arguments: ["path": "approved-tool-output.txt", "contents": "already ran"]
        )
        let run = ToolRun(
            name: request.name,
            argumentsJSON: request.argumentsJSON,
            output: "Waiting for approval.",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true,
            project: project
        )
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        context.insert(run)
        try context.save()

        var saveAttempts = 0
        runtime.debugInstallPendingApproval(request: request, run: run)
        runtime.debugInstallCompactedSaveOverride { saveContext in
            saveAttempts += 1
            guard saveAttempts != 2 else { throw SaveFailure.diskFull }
            try saveContext.save()
        }

        runtime.approvePendingTool(conversation: conversation, settings: settings, context: context, project: project)

        let deadline = Date().addingTimeInterval(3)
        while runtime.debugHasTrackedTask && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertGreaterThanOrEqual(saveAttempts, 2)
        XCTAssertNil(runtime.pendingTool)
        XCTAssertEqual(run.status, .approved)
        XCTAssertEqual(run.output, "Approved by user; execution started.")
        XCTAssertNil(run.completedAt)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertFalse(runtime.isWorking)
        if case .failed(let message) = runtime.runState {
            XCTAssertTrue(message.contains("simulated approved tool result save failure"), "Actual message: \(message)")
        } else {
            XCTFail("Approved tool result save failure should fail visibly. State: \(runtime.runState)")
        }
        XCTAssertEqual(runtime.activityTitle, "Tool Result Not Saved")
        XCTAssertTrue(runtime.traceEvents.contains { $0.title == "Tool result not saved" })
        XCTAssertFalse(runtime.debugHasTrackedTask)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ProjectFileChange>()).isEmpty)
        XCTAssertFalse(try context.fetch(FetchDescriptor<ProjectEvent>()).contains { $0.kind == .fileChanged })
    }

    func testLaunchSelectionPrefersReadyChatOverSettledColdLaunchSelection() throws {
        let ready = Conversation(title: LaunchConversationSelection.safeStartTitle)
        let settled = Conversation(title: "Kept Chat")
        appendMessages(to: settled, rolesAndContents: [
            (.user, "Build a calculator"),
            (.assistant, "Done — the calculator is ready.")
        ])

        let interrupted = Conversation(title: "Interrupted Chat")
        appendMessages(to: interrupted, rolesAndContents: [
            (.user, "Keep working on the risky edit")
        ])

        let failed = Conversation(title: "Failed Chat")
        appendMessages(to: failed, rolesAndContents: [
            (.user, "Call the provider"),
            (.assistant, "I hit an error: provider setup needed")
        ])

        let toolRequest = APIToolCall(
            id: "call-1",
            type: "function",
            function: APIFunctionCall(name: "write_file", arguments: "{}")
        )
        let toolCallJSON = String(data: try JSONEncoder().encode([toolRequest]), encoding: .utf8)
        let awaitingApproval = Conversation(title: "Approval Chat")
        let user = ChatMessage(role: .user, content: "Write a file", conversation: awaitingApproval)
        let assistant = ChatMessage(
            role: .assistant,
            content: "I need to write a file.",
            toolCallsJSON: toolCallJSON,
            conversation: awaitingApproval
        )
        awaitingApproval.appendMessages([user, assistant])

        let conversations = [interrupted, failed, awaitingApproval, ready, settled]
        XCTAssertTrue(LaunchConversationSelection.isLaunchRestorable(settled))
        XCTAssertFalse(LaunchConversationSelection.isLaunchRestorable(interrupted))
        XCTAssertFalse(LaunchConversationSelection.isLaunchRestorable(failed))
        XCTAssertFalse(LaunchConversationSelection.isLaunchRestorable(awaitingApproval))

        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: conversations,
                sessionID: nil,
                persistedIDString: settled.id.uuidString
            )?.id,
            ready.id,
            "Cold launch should prefer a fresh ready chat even when a settled chat was previously selected."
        )
        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: conversations,
                sessionID: nil,
                persistedIDString: interrupted.id.uuidString
            )?.id,
            ready.id,
            "Interrupted/stuck chats should not be restored on launch."
        )
        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: conversations,
                sessionID: nil,
                persistedIDString: failed.id.uuidString
            )?.id,
            ready.id,
            "Failed setup/error chats should fall back to the safe ready chat."
        )
        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: conversations,
                sessionID: interrupted.id,
                persistedIDString: settled.id.uuidString
            )?.id,
            interrupted.id,
            "In-session taps should still select the requested chat; only cold launch persistence is filtered."
        )
    }

    func testLaunchSelectionRejectsBlankAndRecoveryLikeAssistantMessages() throws {
        let ready = Conversation(title: LaunchConversationSelection.safeStartTitle)

        let blankAssistant = Conversation(title: "Blank assistant")
        appendMessages(to: blankAssistant, rolesAndContents: [
            (.user, "Generate the app"),
            (.assistant, "   \n  ")
        ])

        let pausedAssistant = Conversation(title: "Paused assistant")
        appendMessages(to: pausedAssistant, rolesAndContents: [
            (.user, "Write a file"),
            (.assistant, "Run paused before the final response was saved.")
        ])

        let cancelledApproval = Conversation(title: "Cancelled approval")
        appendMessages(to: cancelledApproval, rolesAndContents: [
            (.user, "Patch a file"),
            (.assistant, "Cancelled while waiting for approval.")
        ])

        XCTAssertFalse(LaunchConversationSelection.isLaunchRestorable(blankAssistant))
        XCTAssertFalse(LaunchConversationSelection.isLaunchRestorable(pausedAssistant))
        XCTAssertFalse(LaunchConversationSelection.isLaunchRestorable(cancelledApproval))

        for unsafe in [blankAssistant, pausedAssistant, cancelledApproval] {
            XCTAssertEqual(
                LaunchConversationSelection.preferredConversation(
                    from: [unsafe, ready],
                    sessionID: nil,
                    persistedIDString: unsafe.id.uuidString
                )?.id,
                ready.id,
                "Launch should fall back to the safe ready chat instead of restoring \(unsafe.title)."
            )
        }
    }

    func testPersistentLaunchRecoveryClosesInterruptedToolRuns() throws {
        let schema = TestModelSchema.projectFoundation
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let pending = ToolRun(
            name: "write_file",
            argumentsJSON: "{}",
            output: "waiting for approval",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true
        )
        let approved = ToolRun(
            name: "patch_file",
            argumentsJSON: "{}",
            status: .approved,
            requiresApproval: true,
            isMutating: true
        )
        let completed = ToolRun(
            name: "read_file",
            argumentsJSON: "{}",
            output: "README.md",
            status: .completed,
            requiresApproval: false,
            isMutating: false
        )
        context.insert(pending)
        context.insert(approved)
        context.insert(completed)
        try context.save()

        PersistentLaunchRecovery.recoverInterruptedToolRuns(in: context, now: now)

        XCTAssertEqual(pending.status, .rejected)
        XCTAssertTrue(pending.output.contains("waiting for approval"))
        XCTAssertTrue(pending.output.contains("cancelled this stale approval"))
        XCTAssertEqual(pending.completedAt, now)

        XCTAssertEqual(approved.status, .failed)
        XCTAssertTrue(approved.output.contains("marked it failed"))
        XCTAssertEqual(approved.completedAt, now)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.output, "README.md")
        XCTAssertNil(completed.completedAt)
    }

    func testThemeWorldPalettesExposeRequiredReadableTokens() throws {
        XCTAssertEqual(
            AgentTheme.allCases.map(\.title),
            ["Matrix Rain", "Midnight Black", "White Gold", "Arctic Glass", "Ember Core"]
        )
        XCTAssertEqual(AgentTheme.allCases.count, 5)
        XCTAssertEqual(AgentTheme.defaultTheme, .midnightBlack)
        XCTAssertEqual(AgentTheme.theme(matching: "aurora"), .arcticGlass)
        XCTAssertEqual(AgentTheme.launchOverride(from: ["--theme-world=white-gold"]), .whiteGold)
        XCTAssertEqual(AgentTheme.launchOverride(from: ["--theme", "matrix"]), .matrixRain)

        for theme in AgentTheme.allCases {
            let palette = theme.palette
            let background = rgba(palette.backgroundA)
            let surface = blend(rgba(palette.surface), over: background)
            let elevatedSurface = blend(rgba(palette.surfaceElevated), over: background)
            let row = blend(rgba(palette.row), over: background)
            let selectedRow = blend(rgba(palette.rowSelected), over: background)
            let controlFill = blend(rgba(palette.controlFill), over: background)
            let terminalBackground = rgba(palette.terminalBackground)
            let codeBackground = rgba(palette.codeBackground)
            let primary = rgba(palette.textPrimary)
            let secondary = rgba(palette.textSecondary)

            assertContrast(primary, surface, minimum: 7.0, theme: theme, label: "primary text on cards")
            assertContrast(primary, elevatedSurface, minimum: 7.0, theme: theme, label: "primary text on elevated cards")
            assertContrast(primary, row, minimum: 7.0, theme: theme, label: "primary text on rows")
            assertContrast(primary, selectedRow, minimum: 4.5, theme: theme, label: "selected-chip labels")
            assertContrast(secondary, surface, minimum: 4.5, theme: theme, label: "secondary text on cards")
            assertContrast(primary, controlFill, minimum: 4.5, theme: theme, label: "control labels")

            let statusTokens = [
                ("success", palette.semanticSuccess),
                ("warning", palette.semanticWarning),
                ("error", palette.semanticError),
                ("info", palette.semanticInfo),
                ("approval", palette.semanticApproval),
                ("running", palette.semanticRunning),
                ("blocked", palette.semanticBlocked)
            ]
            for (name, color) in statusTokens {
                assertContrast(rgba(color), surface, minimum: 3.0, theme: theme, label: "\(name) status token")
            }

            let terminalTokens = [
                ("terminal text", palette.terminalText),
                ("terminal prompt", palette.terminalPrompt),
                ("terminal command", palette.terminalCommand),
                ("terminal output", palette.terminalOutput),
                ("terminal warning", palette.terminalWarning),
                ("terminal error", palette.terminalError)
            ]
            for (name, color) in terminalTokens {
                assertContrast(rgba(color), terminalBackground, minimum: 4.5, theme: theme, label: name)
            }

            let codeTokens = [
                ("code text", palette.codeText),
                ("code keyword", palette.codeKeyword),
                ("code string", palette.codeString),
                ("code comment", palette.codeComment),
                ("code type", palette.codeType),
                ("code cursor", palette.codeCursor)
            ]
            for (name, color) in codeTokens {
                assertContrast(rgba(color), codeBackground, minimum: name == "code comment" ? 3.0 : 4.5, theme: theme, label: name)
            }

            let maximumMotionOpacity = theme == .matrixRain ? 0.92 : 0.65
            XCTAssertTrue((0...maximumMotionOpacity).contains(palette.backgroundMotionOpacity), "\(theme.title) background motion should stay readable.")
            XCTAssertGreaterThanOrEqual(palette.glowRadius, 8, "\(theme.title) should define an intentional glow radius.")
            if theme == .matrixRain {
                XCTAssertEqual(palette.typography.interfaceDesign, .monospaced)
                XCTAssertEqual(palette.typography.displayDesign, .monospaced)
                XCTAssertEqual(palette.typography.codeDesign, .monospaced)
            }
        }
    }

    func testProjectIntakeDraftCreatesSpecificMissionAndFirstStep() {
        let draft = ProjectIntakeDraft(
            workingTitle: "Neon Runner",
            projectKind: "mobile arcade game",
            platform: "iPhone",
            playerExperience: "fast one-thumb dodging with short runs",
            constraints: "offline prototype first"
        )

        XCTAssertFalse(draft.isEmpty)
        XCTAssertTrue(draft.seedPrompt.contains("Working title: Neon Runner"))
        XCTAssertTrue(draft.seedPrompt.contains("Project type: mobile arcade game"))
        XCTAssertEqual(
            draft.missionText,
            "Build mobile arcade game that feels like fast one-thumb dodging with short runs for iPhone while respecting offline prototype first."
        )
        XCTAssertEqual(
            draft.firstNextStep,
            "Define the core loop, first playable scene, controls, and proof check."
        )
        XCTAssertEqual(draft.initialAgentTasks.count, 3)
        XCTAssertTrue(draft.initialAgentTasks[0].contains("core loop"))
        XCTAssertTrue(draft.initialTaskPreview.contains("first playable scene"))
        XCTAssertTrue(draft.firstRunOperatorNote.contains("project intake"))
    }

    func testProjectRunProgressUsesAgentChosenIntentSteps() {
        let runtime = AgentRuntime()
        let project = Project(
            name: "Playable Slice",
            mission: "Ship the first playable scene and verify it.",
            workspaceName: "PlayableSlice"
        )
        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [],
            terminalCommands: [],
            artifacts: [],
            fileChanges: [],
            events: []
        )

        runtime.primeProjectRunProgress(
            project: project,
            summary: summary,
            intent: .verifyWork,
            operatorNote: "Run the fastest proof for the playable scene."
        )

        XCTAssertEqual(
            runtime.plannedProgressSteps.map(\.title),
            ["Verify Work", "Read project context", "Run verification", "Report risks", "Capture proof"]
        )
        XCTAssertFalse(runtime.plannedProgressSteps.contains { $0.title == "Deciding next step" })

        XCTAssertEqual(runtime.activityTitle, "Starting Verify")
        XCTAssertTrue(runtime.activityDetail.contains("Run the fastest"))
    }

    func testPrimedProjectRunProgressCanBeClearedBeforeStart() {
        let runtime = AgentRuntime()
        let project = Project(
            name: "Playable Slice",
            mission: "Ship the first playable scene and verify it.",
            workspaceName: "PlayableSlice"
        )
        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [],
            terminalCommands: [],
            artifacts: [],
            fileChanges: [],
            events: []
        )

        runtime.primeProjectRunProgress(
            project: project,
            summary: summary,
            intent: .continueMission,
            operatorNote: ""
        )

        XCTAssertFalse(runtime.plannedProgressSteps.isEmpty)
        XCTAssertEqual(runtime.activityTitle, "Starting Continue")

        runtime.clearPrimedProjectRunProgress()

        XCTAssertTrue(runtime.plannedProgressSteps.isEmpty)
        XCTAssertEqual(runtime.activityTitle, "Ready")
    }

    private typealias RGBA = (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)

    private func assertContrast(
        _ foreground: RGBA,
        _ background: RGBA,
        minimum: CGFloat,
        theme: AgentTheme,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            contrastRatio(foreground, background),
            minimum,
            "\(theme.title) \(label) should be readable.",
            file: file,
            line: line
        )
    }

    private func rgba(_ color: Color) -> RGBA {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    private func blend(_ foreground: RGBA, over background: RGBA) -> RGBA {
        let alpha = foreground.alpha + background.alpha * (1 - foreground.alpha)
        guard alpha > 0 else { return (0, 0, 0, 0) }
        return (
            (foreground.red * foreground.alpha + background.red * background.alpha * (1 - foreground.alpha)) / alpha,
            (foreground.green * foreground.alpha + background.green * background.alpha * (1 - foreground.alpha)) / alpha,
            (foreground.blue * foreground.alpha + background.blue * background.alpha * (1 - foreground.alpha)) / alpha,
            alpha
        )
    }

    private func contrastRatio(_ first: RGBA, _ second: RGBA) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05) / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func relativeLuminance(_ color: RGBA) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    private func appendMessages(
        to conversation: Conversation,
        rolesAndContents: [(ChatRole, String)]
    ) {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let messages = rolesAndContents.enumerated().map { index, pair in
            let message = ChatMessage(role: pair.0, content: pair.1, conversation: conversation)
            message.createdAt = baseDate.addingTimeInterval(TimeInterval(index))
            return message
        }
        conversation.appendMessages(messages, updateTimestamp: baseDate.addingTimeInterval(TimeInterval(messages.count)))
    }
}

final class StreamingResponseValidatorTests: XCTestCase {
    func testRejectsCompletelyEmptyProviderStream() {
        XCTAssertThrowsError(
            try StreamingResponseValidator.makeMessage(
                content: "",
                toolCalls: [],
                sawDataPayload: false,
                malformedPayloadCount: 0
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("stream was empty"))
        }
    }

    func testRejectsMalformedProviderStreamWithoutUsableContent() {
        XCTAssertThrowsError(
            try StreamingResponseValidator.makeMessage(
                content: "",
                toolCalls: [],
                sawDataPayload: true,
                malformedPayloadCount: 2
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("malformed data"))
        }
    }

    func testAcceptsToolOnlyProviderStream() throws {
        let tool = APIToolCall(
            id: "tool-1",
            type: "function",
            function: APIFunctionCall(name: "list_directory", arguments: "{}")
        )
        let message = try StreamingResponseValidator.makeMessage(
            content: "",
            toolCalls: [tool],
            sawDataPayload: true,
            malformedPayloadCount: 0
        )

        XCTAssertEqual(message.role, "assistant")
        XCTAssertNil(message.content)
        XCTAssertEqual(message.tool_calls, [tool])
    }
}

final class LocalModelDownloadPreservationTests: XCTestCase {
    func testDownloadCompletionRequiresMinimumUsableBytes() throws {
        let variant = makeTinyVariant(expectedBytes: 100)

        XCTAssertThrowsError(try LocalModelDownloader.validateCompleteDownload(variant: variant, receivedBytes: 97)) { error in
            XCTAssertTrue(String(describing: error).contains("downloadFailed"))
        }
        XCTAssertNoThrow(try LocalModelDownloader.validateCompleteDownload(variant: variant, receivedBytes: 98))
    }

    @MainActor
    func testLocalFileURLRejectsUndersizedFinalModel() throws {
        let variant = makeTinyVariant(expectedBytes: 100)
        let finalURL = try LocalModelCatalog.fileURL(for: variant)
        let partialURL = LocalModelDownloader.temporaryURL(for: finalURL)
        try? FileManager.default.removeItem(at: finalURL)
        try? FileManager.default.removeItem(at: partialURL)
        defer {
            try? FileManager.default.removeItem(at: finalURL)
            try? FileManager.default.removeItem(at: partialURL)
        }
        try writeBytes(97, to: finalURL)

        let manager = LocalModelManager()

        XCTAssertThrowsError(try manager.localFileURL(for: variant)) { error in
            guard case LocalModelRuntimeError.modelNotDownloaded = error else {
                return XCTFail("Expected undersized final model to be treated as not downloaded, got \(error)")
            }
        }
    }

    #if DEBUG
    @MainActor
    func testDebugLocalModelStatusOverrideSurvivesStatusRefresh() {
        let manager = LocalModelManager()
        let receivedBytes = LocalModelCatalog.defaultVariant.expectedBytes / 3

        manager.debugOverrideStatusForUITest(.partial, receivedBytes: receivedBytes)
        manager.refreshStatus()

        XCTAssertTrue(manager.isPartial, "DEBUG local-model fixtures should survive scene-active/status refreshes so destructive-action UI proofs stay deterministic.")
        XCTAssertEqual(manager.downloadedBytes, receivedBytes)
        XCTAssertEqual(manager.progress.receivedBytes, receivedBytes)
    }
    #endif

    func testPreservesLargerExistingPartialWhenFinalFileIsSmaller() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let finalURL = directory.appendingPathComponent("model.gguf")
        let partialURL = LocalModelDownloader.temporaryURL(for: finalURL)
        try writeBytes(8, to: finalURL)
        try writeBytes(20, to: partialURL)

        let preserved = LocalModelDownloader.preserveLargestPartialDownload(finalURL: finalURL, partialURL: partialURL)

        XCTAssertEqual(preserved, 20)
        XCTAssertEqual(fileSize(at: partialURL), 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path), "A smaller undersized final file should be removed so Resume keeps the larger partial download.")
    }

    func testPromotesLargerUndersizedFinalFileWhenPartialIsSmaller() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let finalURL = directory.appendingPathComponent("model.gguf")
        let partialURL = LocalModelDownloader.temporaryURL(for: finalURL)
        try writeBytes(20, to: finalURL)
        try writeBytes(8, to: partialURL)

        let preserved = LocalModelDownloader.preserveLargestPartialDownload(finalURL: finalURL, partialURL: partialURL)

        XCTAssertEqual(preserved, 20)
        XCTAssertEqual(fileSize(at: partialURL), 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path), "A larger undersized final file should become the resumable partial download.")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelDownloadPreservationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeBytes(_ count: Int, to url: URL) throws {
        try Data(repeating: 0x7A, count: count).write(to: url, options: .atomic)
    }

    private func fileSize(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func makeTinyVariant(expectedBytes: Int64) -> LocalModelVariant {
        .init(
            id: "test/tiny-\(UUID().uuidString)",
            displayName: "Tiny Test Model",
            shortName: "TinyTest",
            quantization: "TEST",
            filename: "tiny-test-\(UUID().uuidString).gguf",
            downloadURL: URL(string: "https://example.com/tiny-test.gguf")!,
            expectedBytes: expectedBytes,
            minimumPhysicalMemoryBytes: 1,
            recommendedFreeDiskBytes: expectedBytes,
            contextTokens: 8,
            batchTokens: 1,
            maxNewTokens: 1,
            maxGenerationSeconds: 1,
            useGPU: false,
            gpuLayerCount: 0,
            generationThreadCount: 1,
            batchThreadCount: 1,
            isIPhone12SafeDefault: false,
            details: "Unit-test-only local model variant."
        )
    }
}

@MainActor
final class ProjectFoundationTests: XCTestCase {
    func testProjectOSRunStartsWithDynamicAgentPlanSteps() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "ProjectOS Runtime", mission: "Build a native project runtime with visible proof.", workspaceName: "ProjectOS")
        let conversation = Conversation(title: "ProjectOS Runtime", project: project)
        context.insert(project)
        context.insert(conversation)

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let run = ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .verifyWork,
            operatorNote: "Run the fastest proof check for ProjectOS.",
            sourceConversationID: conversation.id,
            origin: .manual,
            context: context,
            now: Date(timeIntervalSince1970: 1_000)
        )
        try context.save()

        let persistedRuns = try context.fetch(FetchDescriptor<ProjectOSRun>())
        XCTAssertEqual(persistedRuns.count, 1)
        XCTAssertEqual(run.status, .planning)
        XCTAssertEqual(run.sourceConversationIDString, conversation.id.uuidString)
        XCTAssertEqual(run.project?.id, project.id)

        let stepTitles = run.steps.sorted { $0.orderIndex < $1.orderIndex }.map(\.title)
        XCTAssertEqual(stepTitles, ["Read project context", "Create agent plan", "Run verification", "Report risks", "Capture proof"])
        XCTAssertFalse(stepTitles.contains("Deciding next step"))
        XCTAssertFalse(run.steps.contains { $0.detail.contains("NovaForge Project Continuation") })
    }

    func testProjectOSRunAdvancesFromRuntimeEventsAndCapturesProof() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Proof Runtime", mission: "Capture ProjectOS proof from real events.", workspaceName: "Default")
        let conversation = Conversation(title: "Proof Runtime", project: project)
        context.insert(project)
        context.insert(conversation)
        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let run = ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .continueMission,
            operatorNote: "",
            sourceConversationID: conversation.id,
            origin: .manual,
            context: context,
            now: Date(timeIntervalSince1970: 1_100)
        )

        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Inspect ProjectOS state, run a proof check, and capture results.",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_101)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: "Focused ProjectOS tests passed",
            detail: "xcodebuild test -only-testing:AgentPadTests/ProjectFoundationTests",
            severity: .success,
            sourceType: .terminalCommand,
            metadata: ["command": "xcodebuild test -only-testing:AgentPadTests/ProjectFoundationTests"],
            context: context,
            now: Date(timeIntervalSince1970: 1_102)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Focused ProjectOS tests passed with run history persisted.",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_103)
        )
        try context.save()

        XCTAssertEqual(run.status, .completed)
        XCTAssertTrue(run.proofSummary.contains("Focused ProjectOS tests passed"))
        XCTAssertTrue(run.currentCommand.contains("xcodebuild test"))
        XCTAssertTrue(run.steps.allSatisfy { $0.status.isTerminal })
        XCTAssertTrue(run.steps.contains { $0.key == "proof" && $0.status == .completed })
    }

    func testProjectOSRunRepresentsWaitingAndFailedStates() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Approval Runtime", mission: "Represent blockers honestly.", workspaceName: "Default")
        let conversation = Conversation(title: "Approval Runtime", project: project)
        context.insert(project)
        context.insert(conversation)
        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let run = ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .fixBlocker,
            operatorNote: "",
            sourceConversationID: conversation.id,
            origin: .manual,
            context: context,
            now: Date(timeIntervalSince1970: 1_200)
        )

        ProjectEventRecorder.record(
            project: project,
            kind: .toolApprovalRequested,
            title: "Approval needed for write_file",
            detail: #"{"path":"ProjectOS.swift"}"#,
            severity: .warning,
            sourceType: .toolRun,
            context: context,
            now: Date(timeIntervalSince1970: 1_201)
        )
        XCTAssertEqual(run.status, .waiting)
        XCTAssertTrue(run.waitingReason.contains("ProjectOS.swift"))
        XCTAssertTrue(run.steps.contains { $0.status == .waiting })

        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Run failed",
            detail: "The write was rejected before proof.",
            severity: .failure,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_202)
        )
        try context.save()

        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.blockerReason, "The write was rejected before proof.")
        XCTAssertTrue(run.steps.contains { $0.status == .failed })
    }

    func testProjectOSIntentDerivesModesObjectsAndHistoryFromRuntimeEvents() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Adaptive Intent", mission: "Expose ProjectOS intent from real runtime events.", workspaceName: "Default")
        let conversation = Conversation(title: "Adaptive Intent", project: project)
        context.insert(project)
        context.insert(conversation)
        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let run = ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .continueMission,
            operatorNote: "Inspect, edit, verify, then prove the adaptive surface.",
            sourceConversationID: conversation.id,
            origin: .manual,
            context: context,
            now: Date(timeIntervalSince1970: 1_250)
        )

        XCTAssertEqual(run.currentIntent.mode, .readingContext)
        XCTAssertEqual(run.currentIntent.objectKind, .project)

        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Edited file",
            path: "AgentPad/Views/ProjectDashboardView.swift",
            context: context,
            now: Date(timeIntervalSince1970: 1_251)
        )
        XCTAssertEqual(run.currentIntent.mode, .editingCode)
        XCTAssertEqual(run.currentIntent.objectKind, .file)
        XCTAssertEqual(run.currentIntent.filePath, "AgentPad/Views/ProjectDashboardView.swift")

        ProjectEventRecorder.record(
            project: project,
            kind: .terminalCommand,
            title: "Focused tests passed",
            detail: "xcodebuild test -only-testing:AgentPadTests/ProjectFoundationTests",
            severity: .success,
            sourceType: .terminalCommand,
            metadata: ["command": "xcodebuild test -only-testing:AgentPadTests/ProjectFoundationTests"],
            context: context,
            now: Date(timeIntervalSince1970: 1_252)
        )
        XCTAssertEqual(run.currentIntent.mode, .runningTests)
        XCTAssertEqual(run.currentIntent.objectKind, .testBuildGate)
        XCTAssertTrue(run.currentIntent.command.contains("xcodebuild test"))

        ProjectEventRecorder.record(
            project: project,
            kind: .toolApprovalRequested,
            title: "Approval needed for write_file",
            detail: #"{"path":"AgentPad/Models/Models.swift","tool":"write_file"}"#,
            severity: .warning,
            sourceType: .toolRun,
            context: context,
            now: Date(timeIntervalSince1970: 1_253)
        )
        XCTAssertEqual(run.currentIntent.mode, .waitingApproval)
        XCTAssertEqual(run.currentIntent.objectKind, .approval)
        XCTAssertEqual(run.currentIntent.toolName, "write_file")
        XCTAssertEqual(run.currentIntent.filePath, "AgentPad/Models/Models.swift")

        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Focused tests and screenshots passed.",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_254)
        )
        try context.save()

        XCTAssertEqual(run.currentIntent.mode, .completedProof)
        XCTAssertTrue(run.currentIntent.proof.contains("Focused tests"))
        let modes = run.intentHistory.map(\.mode)
        XCTAssertTrue(modes.contains(.readingContext))
        XCTAssertTrue(modes.contains(.editingCode))
        XCTAssertTrue(modes.contains(.runningTests))
        XCTAssertTrue(modes.contains(.waitingApproval))
        XCTAssertTrue(modes.contains(.completedProof))
    }

    func testProjectOSIntentSurfaceAndStoppedRecoveryPersistWithRun() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Intent Recovery", mission: "Restore adaptive ProjectOS state after relaunch.", workspaceName: "Default")
        context.insert(project)
        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let run = ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .verifyWork,
            operatorNote: "Capture proof after relaunch.",
            sourceConversationID: nil,
            origin: .manual,
            context: context,
            now: Date(timeIntervalSince1970: 1_260)
        )
        run.selectedAdaptiveSurface = .proof
        run.status = .running
        try context.save()

        let persisted = try XCTUnwrap(try context.fetch(FetchDescriptor<ProjectOSRun>()).first)
        XCTAssertEqual(persisted.selectedAdaptiveSurface, .proof)

        PersistentLaunchRecovery.recoverInterruptedToolRuns(in: context, now: Date(timeIntervalSince1970: 1_261))
        try context.save()

        XCTAssertEqual(run.status, .stopped)
        XCTAssertEqual(run.currentIntent.mode, .stoppedResumable)
        XCTAssertEqual(run.currentIntent.source, .recovery)
        XCTAssertTrue(run.intentHistory.contains { $0.mode == .stoppedResumable })
    }

    func testChatProjectSeparationShowsEveryScopeButKeepsGeneralLaunchPreference() {
        let project = Project(name: "Project Run", mission: "Run inside ProjectOS.", workspaceName: "Default")
        let projectConversation = Conversation(title: "Project Run", project: project)
        let ready = Conversation(title: LaunchConversationSelection.safeStartTitle, project: nil)
        let general = Conversation(title: "General Chat", project: nil)
        let visible = ChatProjectSeparation.visibleChatConversations(from: [projectConversation, ready, general])

        XCTAssertEqual(Set(visible.map(\.id)), Set([projectConversation.id, ready.id, general.id]))
        XCTAssertEqual(
            ChatProjectSeparation.preferredGeneralConversation(
                from: [projectConversation, ready, general],
                selectedID: projectConversation.id,
                persistedIDString: projectConversation.id.uuidString
            )?.id,
            ready.id
        )
        XCTAssertEqual(
            ChatProjectSeparation.preferredGeneralConversation(
                from: [projectConversation],
                selectedID: projectConversation.id,
                persistedIDString: ""
            )?.id,
            projectConversation.id
        )
    }

    func testProjectOSRunRecoveryStopsInterruptedRunsOnRelaunch() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Recovered Runtime", mission: "Recover interrupted ProjectOS runs.", workspaceName: "Default")
        context.insert(project)
        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let run = ProjectOSRunLedger.startRun(
            project: project,
            summary: summary,
            intent: .continueMission,
            operatorNote: "",
            sourceConversationID: nil,
            origin: .manual,
            context: context,
            now: Date(timeIntervalSince1970: 1_300)
        )
        run.status = .running
        try context.save()

        PersistentLaunchRecovery.recoverInterruptedToolRuns(in: context, now: Date(timeIntervalSince1970: 1_400))
        try context.save()

        XCTAssertEqual(run.status, .stopped)
        XCTAssertTrue(run.resumeState.contains("Stopped after relaunch"))
        XCTAssertTrue(run.steps.allSatisfy { $0.status.isTerminal })
    }

    func testLaunchRepairCreatesVisibleRootRecordsFromEmptyStore() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext

        let result = try AppRootLaunchRepair.ensureLaunchRecords(
            in: context,
            settings: nil,
            selectedConversation: nil,
            now: Date(timeIntervalSince1970: 90)
        )
        try context.save()

        let settings = try context.fetch(FetchDescriptor<AgentSettings>())
        let projects = try context.fetch(FetchDescriptor<Project>())
        let conversations = try context.fetch(FetchDescriptor<Conversation>())

        XCTAssertTrue(result.createdSettings)
        XCTAssertTrue(result.createdConversation)
        XCTAssertEqual(settings.count, 1)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(result.settings.activeProjectID, result.project.id)
        XCTAssertEqual(result.conversation.title, LaunchConversationSelection.safeStartTitle)
        XCTAssertNil(result.conversation.project)
        XCTAssertFalse(result.project.events.contains { $0.kind == .conversationStarted })
    }

    func testLaunchRepairKeepsActiveProjectWorkspaceAsSourceOfTruth() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let activeProject = Project(name: "Active Project", workspaceName: "Active Workspace")
        let settings = AgentSettings(activeWorkspaceName: "Stale Workspace", activeProjectID: activeProject.id)
        context.insert(activeProject)
        context.insert(settings)
        try context.save()

        let result = try AppRootLaunchRepair.ensureLaunchRecords(
            in: context,
            settings: settings,
            selectedConversation: nil,
            now: Date(timeIntervalSince1970: 96)
        )
        try context.save()

        XCTAssertEqual(result.project.id, activeProject.id)
        XCTAssertEqual(result.settings.activeWorkspaceName, "Active Workspace")
        XCTAssertEqual(activeProject.workspaceName, "Active Workspace")
        XCTAssertNil(result.conversation.project)
    }

    func testLaunchSelectionStaysScopedToActiveProject() throws {
        let activeProject = Project(name: "Active Foundation", workspaceName: "Active")
        let otherProject = Project(name: "Other Foundation", workspaceName: "Other")
        let activeReady = Conversation(title: LaunchConversationSelection.safeStartTitle, project: activeProject)
        let otherSettled = Conversation(title: "Other Project Chat", project: otherProject)
        let user = ChatMessage(role: .user, content: "Build something elsewhere", conversation: otherSettled)
        user.createdAt = Date(timeIntervalSince1970: 10)
        let assistant = ChatMessage(role: .assistant, content: "The other project is settled.", conversation: otherSettled)
        assistant.createdAt = Date(timeIntervalSince1970: 11)
        otherSettled.appendMessages([user, assistant])

        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: [otherSettled, activeReady],
                sessionID: nil,
                persistedIDString: otherSettled.id.uuidString,
                project: activeProject
            )?.id,
            activeReady.id,
            "Cold launch should not restore a chat from another project into the active Project OS."
        )

        XCTAssertEqual(
            LaunchConversationSelection.preferredConversation(
                from: [otherSettled, activeReady],
                sessionID: otherSettled.id,
                persistedIDString: "",
                project: activeProject
            )?.id,
            activeReady.id,
            "In-session selection should still be constrained by the current active project."
        )
    }

    func testLaunchRepairCreatesGeneralReadyChatInsteadOfStealingAnotherProjectChat() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let activeProject = Project(name: "Active Project", workspaceName: "Active")
        let otherProject = Project(name: "Other Project", workspaceName: "Other")
        let otherReady = Conversation(title: LaunchConversationSelection.safeStartTitle, project: otherProject)
        let settings = AgentSettings(activeWorkspaceName: "Active", activeProjectID: activeProject.id)
        context.insert(activeProject)
        context.insert(otherProject)
        context.insert(otherReady)
        context.insert(settings)
        try context.save()

        let result = try AppRootLaunchRepair.ensureLaunchRecords(
            in: context,
            settings: settings,
            selectedConversation: nil,
            now: Date(timeIntervalSince1970: 95)
        )
        try context.save()

        XCTAssertTrue(result.createdConversation)
        XCTAssertEqual(result.project.id, activeProject.id)
        XCTAssertNil(result.conversation.project)
        XCTAssertEqual(otherReady.project?.id, otherProject.id)

        let conversations = try context.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(conversations.filter { $0.project?.id == activeProject.id }.count, 0)
        XCTAssertEqual(conversations.filter { $0.project?.id == otherProject.id }.count, 1)
        XCTAssertEqual(conversations.filter { $0.project == nil }.count, 1)
    }

    func testDefaultProjectMigrationLeavesGeneralConversationsUnscopedButOwnsRuns() throws {
        let suiteName = "NovaForgeProjectMigration-\(UUID().uuidString)"
        let migrationStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { migrationStore.removePersistentDomain(forName: suiteName) }
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let settings = AgentSettings(activeWorkspaceName: "LegacyWorkspace")
        let conversation = Conversation(title: "Legacy chat")
        let run = ToolRun(name: "read_file", argumentsJSON: "{\"path\":\"README.md\"}", status: .completed)
        context.insert(settings)
        context.insert(conversation)
        context.insert(run)
        try context.save()

        let project = ProjectBootstrap.ensureDefaultProject(
            in: context,
            settings: settings,
            now: Date(timeIntervalSince1970: 100),
            migrationStore: migrationStore
        )
        try context.save()

        XCTAssertEqual(settings.activeProjectID, project.id)
        XCTAssertEqual(project.workspaceName, "LegacyWorkspace")
        XCTAssertNil(conversation.project)
        XCTAssertEqual(run.project?.id, project.id)
        XCTAssertTrue(project.events.contains { $0.kind == .migrationLinked })
    }

    func testDefaultProjectMigrationRunsOnceAndKeepsNewGeneralEvidenceUnscoped() throws {
        let suiteName = "NovaForgeProjectMigration-\(UUID().uuidString)"
        let migrationStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { migrationStore.removePersistentDomain(forName: suiteName) }
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let settings = AgentSettings(activeWorkspaceName: "General")
        let legacyRun = ToolRun(name: "legacy", argumentsJSON: "{}", status: .completed)
        context.insert(settings)
        context.insert(legacyRun)
        try context.save()

        let project = ProjectBootstrap.ensureDefaultProject(
            in: context,
            settings: settings,
            now: Date(timeIntervalSince1970: 140),
            migrationStore: migrationStore
        )
        try context.save()
        XCTAssertEqual(legacyRun.project?.id, project.id)
        ProjectBootstrap.markLegacyOwnershipMigrationComplete(in: migrationStore)

        let generalConversation = Conversation(title: "General")
        let generalReceipt = AgentRunRecord(
            status: .completed,
            conversationID: generalConversation.id,
            projectID: nil,
            workspaceName: "General"
        )
        let generalTool = ToolRun(
            name: "read_file",
            argumentsJSON: #"{"path":"README.md"}"#,
            status: .completed,
            runID: generalReceipt.id
        )
        let terminal = TerminalCommandRecord(
            project: nil,
            command: "pwd",
            output: "General",
            status: .completed,
            workspaceName: "General",
            durationMs: 1,
            sourceToolRunID: generalTool.id
        )
        let artifact = ProjectArtifact(project: nil, path: "general.html", sourceToolRunID: generalTool.id)
        let change = ProjectFileChange(project: nil, action: "Wrote file", path: "general.html", sourceToolRunID: generalTool.id)
        context.insert(generalConversation)
        context.insert(generalReceipt)
        context.insert(generalTool)
        context.insert(terminal)
        context.insert(artifact)
        context.insert(change)
        try context.save()

        _ = ProjectBootstrap.ensureDefaultProject(
            in: context,
            settings: settings,
            now: Date(timeIntervalSince1970: 141),
            migrationStore: migrationStore
        )
        try context.save()

        XCTAssertNil(generalReceipt.projectID)
        XCTAssertNil(generalTool.project)
        XCTAssertNil(terminal.project)
        XCTAssertNil(artifact.project)
        XCTAssertNil(change.project)
    }

    func testDefaultProjectMigrationRecognizesLowercaseGeneralRunLinks() throws {
        let suiteName = "NovaForgeProjectMigration-\(UUID().uuidString)"
        let migrationStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { migrationStore.removePersistentDomain(forName: suiteName) }
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let settings = AgentSettings(activeWorkspaceName: "General")
        let conversation = Conversation(title: "General")
        let generalReceipt = AgentRunRecord(
            status: .completed,
            conversationID: conversation.id,
            projectID: nil,
            workspaceName: "General"
        )
        let generalTool = ToolRun(
            name: "write_file",
            argumentsJSON: #"{"path":"general-proof.html"}"#,
            output: "Wrote general-proof.html",
            status: .completed
        )
        // Older stores have used a lowercase UUID representation here.
        generalTool.runIDString = generalReceipt.id.uuidString.lowercased()
        let artifact = ProjectArtifact(
            project: nil,
            path: "general-proof.html",
            sourceToolRunID: generalTool.id
        )
        let change = ProjectFileChange(
            project: nil,
            action: "Wrote file",
            path: "general-proof.html",
            sourceToolRunID: generalTool.id
        )
        context.insert(settings)
        context.insert(conversation)
        context.insert(generalReceipt)
        context.insert(generalTool)
        context.insert(artifact)
        context.insert(change)
        try context.save()

        _ = ProjectBootstrap.ensureDefaultProject(
            in: context,
            settings: settings,
            now: Date(timeIntervalSince1970: 142),
            migrationStore: migrationStore
        )
        try context.save()

        XCTAssertNil(generalTool.project)
        XCTAssertNil(artifact.project)
        XCTAssertNil(change.project)
    }

    func testProjectDeletionRescopesCanonicalReceiptsToGeneral() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Disposable", workspaceName: "Disposable")
        let conversation = Conversation(title: "Disposable", project: project)
        let receipt = AgentRunRecord(
            status: .completed,
            conversationID: conversation.id,
            projectID: project.id,
            workspaceName: "Disposable"
        )
        let operation = ToolOperationRecord(
            runID: receipt.id,
            projectID: project.id,
            conversationID: conversation.id,
            workspaceName: "Disposable",
            toolName: "read_file",
            argumentsJSON: #"{"path":"README.md"}"#,
            phase: .completed
        )
        let toolRun = ToolRun(name: "read_file", argumentsJSON: "{}", status: .completed, project: project, runID: receipt.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(receipt)
        context.insert(operation)
        context.insert(toolRun)
        try context.save()

        ProjectDeletionRetention.clearScalarProjectLinks(projectID: project.id, context: context)
        context.delete(project)
        try context.save()

        XCTAssertNil(receipt.projectID)
        XCTAssertNil(operation.projectID)
        XCTAssertNil(conversation.project)
        XCTAssertNil(toolRun.project)
    }

    func testPersistentLaunchRecoveryRecordsProjectTimelineEvents() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_100_000)
        let project = Project(name: "Recovered Project", workspaceName: "Default")
        let pending = ToolRun(
            name: "write_file",
            argumentsJSON: "{}",
            output: "waiting",
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true,
            project: project
        )
        let approved = ToolRun(
            name: "patch_file",
            argumentsJSON: "{}",
            output: "started",
            status: .approved,
            requiresApproval: true,
            isMutating: true,
            project: project
        )
        context.insert(project)
        context.insert(pending)
        context.insert(approved)
        try context.save()

        PersistentLaunchRecovery.recoverInterruptedToolRuns(in: context, now: now)
        try context.save()

        XCTAssertEqual(pending.status, .rejected)
        XCTAssertEqual(approved.status, .failed)

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertTrue(events.contains { event in
            event.project?.id == project.id &&
            event.kind == .toolRejected &&
            event.sourceIDString == pending.id.uuidString
        })
        XCTAssertTrue(events.contains { event in
            event.project?.id == project.id &&
            event.kind == .toolFailed &&
            event.sourceIDString == approved.id.uuidString
        })

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [pending, approved],
            terminalCommands: [],
            artifacts: [],
            fileChanges: [],
            events: events
        )
        XCTAssertEqual(summary.status, .blocked)
        XCTAssertEqual(summary.failureCount, 2)
    }

    func testProjectSummaryTreatsApprovedRunAsRunningNotPendingApproval() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Approved Tool", mission: "Run an approved workspace edit.", workspaceName: "Default")
        let run = ToolRun(
            name: "write_file",
            argumentsJSON: #"{"path":"approved.txt"}"#,
            output: "Approved by user; execution started.",
            status: .approved,
            requiresApproval: true,
            isMutating: true,
            project: project
        )
        context.insert(project)
        context.insert(run)
        ProjectEventRecorder.record(
            project: project,
            kind: .toolApproved,
            title: "Approved write_file",
            detail: run.argumentsJSON,
            severity: .running,
            sourceType: .toolRun,
            sourceID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_800_200_000)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [run],
            terminalCommands: [],
            artifacts: [],
            fileChanges: [],
            events: try context.fetch(FetchDescriptor<ProjectEvent>())
        )

        XCTAssertEqual(summary.pendingApprovalCount, 0)
        XCTAssertEqual(summary.status, .running)
        XCTAssertEqual(summary.statusText, "Running")
        XCTAssertEqual(summary.statusKind, .active)
        XCTAssertEqual(summary.trustText, "Timeline is current")
        let safetyGate = try XCTUnwrap(summary.missionContract.gates.first { $0.id == "safety" })
        XCTAssertEqual(safetyGate.state, .satisfied)
        XCTAssertFalse(safetyGate.detail.contains("approval"))
    }

    func testDefaultProjectMigrationOwnsTerminalCommandsAndArtifacts() throws {
        let suiteName = "NovaForgeProjectMigration-\(UUID().uuidString)"
        let migrationStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { migrationStore.removePersistentDomain(forName: suiteName) }
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let settings = AgentSettings(activeWorkspaceName: "LegacyWorkspace")
        let terminal = TerminalCommandRecord(
            project: nil,
            command: "npm test",
            output: "ok",
            status: .completed,
            workspaceName: "LegacyWorkspace",
            durationMs: 120
        )
        let artifact = ProjectArtifact(project: nil, path: "index.html", kind: .web)
        let fileChange = ProjectFileChange(project: nil, action: "Created file", path: "index.html")
        context.insert(settings)
        context.insert(terminal)
        context.insert(artifact)
        context.insert(fileChange)
        try context.save()

        let project = ProjectBootstrap.ensureDefaultProject(
            in: context,
            settings: settings,
            now: Date(timeIntervalSince1970: 120),
            migrationStore: migrationStore
        )
        try context.save()

        XCTAssertEqual(terminal.project?.id, project.id)
        XCTAssertEqual(artifact.project?.id, project.id)
        XCTAssertEqual(fileChange.project?.id, project.id)
        XCTAssertEqual(project.workspaceName, "LegacyWorkspace")
        XCTAssertTrue(project.events.contains { event in
            event.kind == .migrationLinked &&
            event.detail.contains("3 existing records")
        })
    }

    func testDefaultProjectMigrationOwnsExistingTimelineEvents() throws {
        let suiteName = "NovaForgeProjectMigration-\(UUID().uuidString)"
        let migrationStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { migrationStore.removePersistentDomain(forName: suiteName) }
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let settings = AgentSettings(activeWorkspaceName: "LegacyWorkspace")
        let orphanEvent = ProjectEvent(
            project: nil,
            kind: .toolFailed,
            title: "Legacy tool failed",
            detail: "A pre-project timeline event still needs ownership.",
            severity: .failure,
            sourceType: .system,
            createdAt: Date(timeIntervalSince1970: 110)
        )
        context.insert(settings)
        context.insert(orphanEvent)
        try context.save()

        let project = ProjectBootstrap.ensureDefaultProject(
            in: context,
            settings: settings,
            now: Date(timeIntervalSince1970: 130),
            migrationStore: migrationStore
        )
        try context.save()

        XCTAssertEqual(orphanEvent.project?.id, project.id)
        XCTAssertTrue(project.events.contains { $0.id == orphanEvent.id })
        XCTAssertTrue(project.events.contains { event in
            event.kind == .migrationLinked &&
            event.detail.contains("1 existing records")
        })

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [],
            terminalCommands: [],
            artifacts: [],
            fileChanges: [],
            events: project.events
        )
        XCTAssertEqual(summary.failureCount, 1)
        XCTAssertEqual(summary.status, .blocked)
    }

    func testProjectEventsDriveMissionSummaryAndBlockers() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Foundation", workspaceName: "Default")
        let conversation = Conversation(title: "Build Project OS", project: project)
        let terminal = TerminalCommandRecord(
            project: project,
            command: "validate_html index.html",
            output: "Error: invalid markup",
            status: .failed,
            workspaceName: "Default",
            durationMs: 42
        )
        context.insert(project)
        context.insert(conversation)
        context.insert(terminal)
        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Run failed",
            detail: "Provider timed out",
            severity: .failure,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [conversation],
            toolRuns: [],
            terminalCommands: [terminal],
            artifacts: [],
            fileChanges: [],
            events: project.events
        )

        XCTAssertEqual(summary.status, .blocked)
        XCTAssertEqual(summary.conversationCount, 1)
        XCTAssertEqual(summary.terminalCommandCount, 1)
        XCTAssertEqual(summary.failureCount, 2)
        XCTAssertEqual(summary.blocker, "Run failed")
        XCTAssertTrue(summary.trustText.contains("issues need review"))
    }

    func testProjectLatestProofPrefersNewerFailedRunOverOlderArtifact() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Chronological Proof", workspaceName: "Default")
        let artifact = ProjectArtifact(
            project: project,
            path: "public/index.html",
            kind: .web,
            now: Date(timeIntervalSince1970: 100)
        )
        let failedRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"public/index.html"}"#,
            output: "Error: invalid markup",
            status: .failed,
            project: project
        )
        failedRun.createdAt = Date(timeIntervalSince1970: 200)
        failedRun.completedAt = Date(timeIntervalSince1970: 210)
        context.insert(project)
        context.insert(artifact)
        context.insert(failedRun)
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [failedRun],
            terminalCommands: [],
            artifacts: [artifact],
            fileChanges: [],
            events: []
        )

        XCTAssertEqual(summary.status, .blocked)
        XCTAssertEqual(summary.latestProofTitle, "Run failed")
        XCTAssertEqual(summary.proofItems.first?.id, "run-failure-\(failedRun.id.uuidString)")
        XCTAssertEqual(summary.proofItems.first?.severity, .failure)
        XCTAssertEqual(summary.nextStep, "Review the failed evidence and retry the run.")
    }

    func testArtifactPreviewLinksArtifactAndTimelineToProject() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Artifact Project", workspaceName: "Default")
        context.insert(project)

        ProjectEventRecorder.noteArtifactPreview(
            WorkspaceArtifact(path: "index.html"),
            project: project,
            context: context,
            now: Date(timeIntervalSince1970: 200)
        )
        try context.save()

        let artifacts = try context.fetch(FetchDescriptor<ProjectArtifact>())
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(artifacts.first?.project?.id, project.id)
        XCTAssertEqual(artifacts.first?.path, "index.html")
        XCTAssertTrue(project.events.contains { $0.kind == .artifactPreviewed && $0.detail == "index.html" })

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [],
            terminalCommands: [],
            artifacts: artifacts,
            fileChanges: [],
            events: project.events
        )
        XCTAssertEqual(summary.artifactCount, 1)
        XCTAssertEqual(summary.lastEventTitle, "Opened artifact preview")
    }

    func testFileChangeRecorderCreatesProjectOwnedChangeAndTimelineEvent() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Files Project", workspaceName: "Default")
        context.insert(project)

        let change = ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Saved file",
            path: "Sources/App.swift",
            context: context,
            now: Date(timeIntervalSince1970: 250)
        )
        try context.save()

        let changes = try context.fetch(FetchDescriptor<ProjectFileChange>())
        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.id, change?.id)
        XCTAssertEqual(changes.first?.project?.id, project.id)
        XCTAssertEqual(changes.first?.action, "Saved file")
        XCTAssertEqual(changes.first?.path, "Sources/App.swift")
        XCTAssertTrue(events.contains { event in
            event.kind == .fileChanged &&
            event.sourceIDString == change?.id.uuidString &&
            event.detail == "Sources/App.swift"
        })
        XCTAssertEqual(change?.sourceEventIDString, events.first { $0.kind == .fileChanged }?.id.uuidString)

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [],
            terminalCommands: [],
            artifacts: [],
            fileChanges: changes,
            events: events
        )
        XCTAssertEqual(summary.fileChangeCount, 1)
        XCTAssertEqual(summary.trustText, "Timeline is current")
    }

    func testTerminalMutationFileChangeLinksToTerminalCommand() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Terminal Project", workspaceName: "Default")
        let terminal = TerminalCommandRecord(
            project: project,
            command: "touch notes.txt",
            output: "",
            status: .completed,
            workspaceName: "Default",
            durationMs: 18
        )
        context.insert(project)
        context.insert(terminal)

        let change = ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Ran terminal mutation",
            path: terminal.command,
            sourceTerminalCommandID: terminal.id,
            context: context,
            now: Date(timeIntervalSince1970: 275)
        )
        try context.save()

        let changes = try context.fetch(FetchDescriptor<ProjectFileChange>())
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.id, change?.id)
        XCTAssertEqual(changes.first?.project?.id, project.id)
        XCTAssertEqual(changes.first?.sourceTerminalCommandIDString, terminal.id.uuidString)
        XCTAssertEqual(changes.first?.sourceToolRunIDString, nil)
        XCTAssertTrue(project.events.contains { event in
            event.kind == .fileChanged &&
            event.sourceIDString == change?.id.uuidString &&
            event.detail == "touch notes.txt"
        })

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [],
            terminalCommands: [terminal],
            artifacts: [],
            fileChanges: changes,
            events: project.events
        )
        XCTAssertEqual(summary.terminalCommandCount, 1)
        XCTAssertEqual(summary.fileChangeCount, 1)
        XCTAssertEqual(summary.trustText, "Timeline is current")
    }

    func testUserVisibleMaintenanceActionsAreProjectTimelineEvents() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Timeline Maintenance", workspaceName: "Default")
        let conversation = Conversation(title: "Original chat", project: project)
        let run = ToolRun(
            name: "write_file",
            argumentsJSON: #"{"path":"index.html"}"#,
            status: .completed,
            project: project
        )
        context.insert(project)
        context.insert(conversation)
        context.insert(run)

        ProjectEventRecorder.record(
            project: project,
            kind: .conversationRenamed,
            title: "Chat renamed",
            detail: "Original chat -> Project OS notes",
            severity: .info,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 300)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .conversationDeleted,
            title: "Chat deleted",
            detail: "Project OS notes",
            severity: .info,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 301)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runLogDeleted,
            title: "Run log deleted",
            detail: run.name,
            severity: .info,
            sourceType: .toolRun,
            sourceID: run.id,
            metadata: ["status": run.status.rawValue],
            context: context,
            now: Date(timeIntervalSince1970: 302)
        )
        try context.save()

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertEqual(events.filter { $0.project?.id == project.id }.count, 3)
        XCTAssertTrue(events.contains { $0.kind == .conversationRenamed && $0.sourceIDString == conversation.id.uuidString })
        XCTAssertTrue(events.contains { $0.kind == .conversationDeleted && $0.sourceIDString == conversation.id.uuidString })
        XCTAssertTrue(events.contains { $0.kind == .runLogDeleted && $0.metadataJSON?.contains(#""status":"completed""#) == true })

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [conversation],
            toolRuns: [run],
            terminalCommands: [],
            artifacts: [],
            fileChanges: [],
            events: events
        )
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.lastEventTitle, "Run log deleted")
    }

    func testMissionSummaryUsesOnlyActiveProjectRecords() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let activeProject = Project(name: "Active OS", workspaceName: "Active")
        let otherProject = Project(name: "Other OS", workspaceName: "Other")
        let activeConversation = Conversation(title: "Active Chat", project: activeProject)
        let otherConversation = Conversation(title: "Other Chat", project: otherProject)
        let activeRun = ToolRun(name: "write_file", argumentsJSON: #"{"path":"active.html"}"#, status: .completed, project: activeProject)
        let otherRun = ToolRun(name: "write_file", argumentsJSON: #"{"path":"other.html"}"#, status: .failed, project: otherProject)
        let activeTerminal = TerminalCommandRecord(project: activeProject, command: "touch active.txt", output: "", status: .completed, workspaceName: "Active", durationMs: 12)
        let otherTerminal = TerminalCommandRecord(project: otherProject, command: "touch other.txt", output: "", status: .completed, workspaceName: "Other", durationMs: 12)
        let activeArtifact = ProjectArtifact(project: activeProject, path: "active.html", kind: .web)
        let otherArtifact = ProjectArtifact(project: otherProject, path: "other.html", kind: .web)
        let activeChange = ProjectFileChange(project: activeProject, action: "Created file", path: "active.html")
        let otherChange = ProjectFileChange(project: otherProject, action: "Created file", path: "other.html")
        context.insert(activeProject)
        context.insert(otherProject)
        context.insert(activeConversation)
        context.insert(otherConversation)
        context.insert(activeRun)
        context.insert(otherRun)
        context.insert(activeTerminal)
        context.insert(otherTerminal)
        context.insert(activeArtifact)
        context.insert(otherArtifact)
        context.insert(activeChange)
        context.insert(otherChange)

        ProjectEventRecorder.record(
            project: activeProject,
            kind: .projectSelected,
            title: "Project selected",
            detail: "Active OS is active.",
            sourceType: .system,
            context: context
        )
        ProjectEventRecorder.record(
            project: otherProject,
            kind: .toolFailed,
            title: "Other failed",
            detail: "This should not leak.",
            severity: .failure,
            sourceType: .toolRun,
            sourceID: otherRun.id,
            context: context
        )
        try context.save()

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        let summary = ProjectMissionSummarizer.summarize(
            project: activeProject,
            conversations: [activeConversation, otherConversation],
            toolRuns: [activeRun, otherRun],
            terminalCommands: [activeTerminal, otherTerminal],
            artifacts: [activeArtifact, otherArtifact],
            fileChanges: [activeChange, otherChange],
            events: events
        )

        XCTAssertEqual(summary.conversationCount, 1)
        XCTAssertEqual(summary.toolRunCount, 1)
        XCTAssertEqual(summary.terminalCommandCount, 1)
        XCTAssertEqual(summary.artifactCount, 1)
        XCTAssertEqual(summary.fileChangeCount, 1)
        XCTAssertEqual(summary.failureCount, 0)
        XCTAssertTrue(summary.proofItems.contains { $0.detail.contains("active.html") || $0.title.contains("active") })
        XCTAssertFalse(summary.timelineItems.contains { $0.detail.contains("leak") || $0.title.contains("Other") })
        XCTAssertFalse(summary.proofItems.contains { $0.detail.contains("other.html") || $0.title.contains("other") })
    }

    func testProofLedgerDerivesFromArtifactsRunsFilesTerminalAndEvents() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Proof OS", workspaceName: "Default")
        let run = ToolRun(name: "validate_html_file", argumentsJSON: #"{"path":"proof.html"}"#, output: "passed", status: .completed, project: project)
        run.completedAt = Date(timeIntervalSince1970: 500)
        let command = TerminalCommandRecord(
            project: project,
            command: "validate_html proof.html",
            output: "ok",
            status: .completed,
            workspaceName: "Default",
            completedAt: Date(timeIntervalSince1970: 501),
            durationMs: 20
        )
        context.insert(project)
        context.insert(run)
        context.insert(command)
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            sourceToolRunID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 502)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Saved file",
            path: "proof.html",
            sourceToolRunID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 503)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Validated proof.html",
            severity: .success,
            sourceType: .toolRun,
            sourceID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 504)
        )
        try context.save()

        let artifacts = try context.fetch(FetchDescriptor<ProjectArtifact>())
        let changes = try context.fetch(FetchDescriptor<ProjectFileChange>())
        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [run],
            terminalCommands: [command],
            artifacts: artifacts,
            fileChanges: changes,
            events: events
        )

        XCTAssertTrue(summary.proofItems.contains { $0.id.hasPrefix("artifact-") && $0.detail.contains("proof.html") })
        XCTAssertTrue(summary.proofItems.contains { $0.id.hasPrefix("file-") && $0.detail.contains("proof.html") })
        XCTAssertTrue(summary.proofItems.contains { $0.id.hasPrefix("run-") && $0.detail == "validate_html_file" })
        XCTAssertTrue(summary.proofItems.contains { $0.id.hasPrefix("terminal-") && $0.detail == "validate_html proof.html" })
        XCTAssertTrue(summary.proofItems.contains { $0.id.hasPrefix("event-") && $0.title == "Run completed" })
    }

    func testDeletingRunLogDetachesProofProvenanceWithoutDeletingProof() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Run Cleanup", workspaceName: "Default")
        let run = ToolRun(name: "write_file", argumentsJSON: #"{"path":"proof.html"}"#, output: "Wrote proof.html", status: .completed, project: project)
        let otherRun = ToolRun(name: "write_file", argumentsJSON: #"{"path":"other.html"}"#, output: "Wrote other.html", status: .completed, project: project)
        let terminal = TerminalCommandRecord(
            project: project,
            command: "validate_html proof.html",
            output: "ok",
            status: .completed,
            workspaceName: "Default",
            durationMs: 12,
            sourceToolRunID: run.id
        )
        let fileChange = ProjectFileChange(project: project, action: "Saved proof", path: "proof.html", sourceToolRunID: run.id)
        let runEvent = ProjectEvent(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Wrote proof.html",
            severity: .success,
            sourceType: .toolRun,
            sourceID: run.id
        )
        context.insert(project)
        context.insert(run)
        context.insert(otherRun)
        context.insert(terminal)
        context.insert(fileChange)
        context.insert(runEvent)
        let artifact = ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            sourceToolRunID: run.id,
            context: context
        )
        let otherArtifact = ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "other.html"),
            project: project,
            sourceToolRunID: otherRun.id,
            context: context
        )
        try context.save()

        let cleanup = try ProjectRunLogCleanup.detachDeletedRunProvenance(for: run, context: context)
        context.delete(run)
        try context.save()

        XCTAssertEqual(cleanup.artifactLinksDetached, 1)
        XCTAssertEqual(cleanup.terminalLinksDetached, 1)
        XCTAssertEqual(cleanup.fileChangeLinksDetached, 1)
        XCTAssertEqual(cleanup.eventLinksDetached, 1)
        XCTAssertNil(artifact?.sourceToolRunIDString)
        XCTAssertNil(terminal.sourceToolRunIDString)
        XCTAssertNil(fileChange.sourceToolRunIDString)
        XCTAssertNil(runEvent.sourceType)
        XCTAssertNil(runEvent.sourceIDString)
        XCTAssertEqual(otherArtifact?.sourceToolRunIDString, otherRun.id.uuidString)
        let remainingRunIDs = Set(try context.fetch(FetchDescriptor<ToolRun>()).map(\.id))
        XCTAssertEqual(remainingRunIDs, [otherRun.id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ProjectArtifact>()).count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TerminalCommandRecord>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ProjectFileChange>()).count, 1)
    }

    func testMissionOSContractMarksVerifiedProofReadyForReview() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Mission OS", mission: "Build a trusted plan act verify proof loop.", workspaceName: "Default")
        let conversation = Conversation(title: "Mission loop", project: project)
        let userMessage = ChatMessage(role: .user, content: "Ship the verified mission loop.", conversation: conversation)
        conversation.appendMessage(userMessage, updateTimestamp: Date(timeIntervalSince1970: 700))
        let run = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            output: "passed",
            status: .completed,
            project: project
        )
        run.completedAt = Date(timeIntervalSince1970: 701)
        context.insert(project)
        context.insert(conversation)
        context.insert(userMessage)
        context.insert(run)
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "validate_html_file",
            severity: .running,
            sourceType: .message,
            sourceID: userMessage.id,
            context: context,
            now: Date(timeIntervalSince1970: 700.5)
        )
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            sourceToolRunID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 702)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Saved proof",
            path: "proof.html",
            sourceToolRunID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 703)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Validated proof.html",
            severity: .success,
            sourceType: .toolRun,
            sourceID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 704)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Validated proof.html",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 705)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [conversation],
            toolRuns: [run],
            terminalCommands: [],
            artifacts: try context.fetch(FetchDescriptor<ProjectArtifact>()),
            fileChanges: try context.fetch(FetchDescriptor<ProjectFileChange>()),
            events: try context.fetch(FetchDescriptor<ProjectEvent>())
        )

        XCTAssertEqual(summary.missionContract.phase, .decide)
        XCTAssertEqual(summary.missionContract.recommendedIntent, .reviewEvidence)
        XCTAssertEqual(summary.missionContract.decisionLabel, "Ready to review")
        XCTAssertGreaterThanOrEqual(summary.missionContract.readinessScore, 85)
        XCTAssertTrue(summary.missionContract.gates.allSatisfy { $0.state == .satisfied })
        XCTAssertTrue(summary.missionContract.proofRequirement.contains("current receipt"))
        XCTAssertEqual(summary.review.recommendation, .finalReview)
        XCTAssertTrue(summary.review.detail.contains("Review the proof ledger"))
    }

    func testMissionOSCheckpointPersistsStructuredContractMetadata() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Mission Checkpoint", mission: "Persist reliable mission receipts.", workspaceName: "Default")
        let conversation = Conversation(title: "Mission Checkpoint", project: project)
        let run = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"receipt.html"}"#,
            output: "passed",
            status: .completed,
            project: project
        )
        run.completedAt = Date(timeIntervalSince1970: 721)
        context.insert(project)
        context.insert(conversation)
        context.insert(run)
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "validate_html_file",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 720)
        )
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "receipt.html"),
            project: project,
            sourceToolRunID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 722)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Saved receipt",
            path: "receipt.html",
            sourceToolRunID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 723)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Validated receipt.html",
            severity: .success,
            sourceType: .toolRun,
            sourceID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 724)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Validated receipt.html",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 725)
        )

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let checkpointEvent = ProjectEventRecorder.recordMissionCheckpoint(
            project: project,
            contract: summary.missionContract,
            trigger: "unit-test-proof",
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 726)
        )
        try context.save()

        let checkpoint = try XCTUnwrap(checkpointEvent?.missionOSCheckpoint)
        XCTAssertEqual(checkpoint.phase, .decide)
        XCTAssertEqual(checkpoint.recommendedIntent, .reviewEvidence)
        XCTAssertEqual(checkpoint.decisionLabel, "Ready to review")
        XCTAssertGreaterThanOrEqual(checkpoint.readinessScore, 85)
        XCTAssertTrue(checkpoint.blockingGateIDs.isEmpty)
        XCTAssertEqual(checkpoint.trigger, "unit-test-proof")
        XCTAssertEqual(checkpointEvent?.metadata["schemaVersion"], MissionOSCheckpoint.schemaVersion)

        let refreshed = ProjectMissionSummarizer.summarize(project: project, context: context)
        XCTAssertTrue(refreshed.timelineItems.contains { $0.sourceKind == .missionCheckpoint })
        XCTAssertTrue(refreshed.proofItems.contains { $0.title.contains("Mission OS checkpoint") })
    }

    func testMissionOSContractRequiresRunCheckpointsBeforeReadyDecision() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Checkpoint Gate", mission: "Do not call output done without lifecycle receipts.", workspaceName: "Default")
        let run = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            output: "passed",
            status: .completed,
            project: project
        )
        run.completedAt = Date(timeIntervalSince1970: 731)
        context.insert(project)
        context.insert(run)
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            sourceToolRunID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 732)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Saved proof",
            path: "proof.html",
            sourceToolRunID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 733)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Validated proof.html",
            severity: .success,
            sourceType: .toolRun,
            sourceID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 734)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let checkpointGate = try XCTUnwrap(summary.missionContract.gates.first { $0.id == "checkpoints" })

        XCTAssertEqual(checkpointGate.state, .waiting)
        XCTAssertEqual(summary.missionContract.phase, .plan)
        XCTAssertEqual(summary.missionContract.decisionLabel, "Needs checkpoint")
        XCTAssertNotEqual(summary.missionContract.recommendedIntent, .reviewEvidence)
        XCTAssertTrue(summary.missionContract.proofRequirement.contains("Agent Plan and Agent Proof"))
    }

    func testMissionOSContractDoesNotShowFixBlockerForVerificationGap() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Verification Gap", mission: "Verify project runs before review.", workspaceName: "Default")
        let conversation = Conversation(title: "Verification Gap", project: project)
        context.insert(project)
        context.insert(conversation)
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Inspect files and run the fastest proof check.",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 740)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Updated Project OS copy",
            path: "AgentPad/Views/ProjectDashboardView.swift",
            context: context,
            now: Date(timeIntervalSince1970: 741)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)

        XCTAssertEqual(summary.status, .active)
        XCTAssertEqual(summary.missionContract.recommendedIntent, .verifyWork)
        XCTAssertNotEqual(summary.missionContract.decisionLabel, "Fix blocker")
        XCTAssertTrue(summary.missionContract.blockingGates.isEmpty)
        XCTAssertTrue(summary.missionContract.proofRequirement.lowercased().contains("proof"))
    }

    func testProjectReviewFlagsStaleProofAndRecommendsVerification() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Proof Freshness", mission: "Keep project proof aligned with the latest plan.", workspaceName: "Default")
        context.insert(project)
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            context: context,
            now: Date(timeIntervalSince1970: 800)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Change the project dashboard after proof was captured.",
            severity: .running,
            sourceType: .system,
            context: context,
            now: Date(timeIntervalSince1970: 820)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)

        XCTAssertTrue(summary.review.hasStaleProof)
        XCTAssertEqual(summary.review.proofFreshness, "Stale proof")
        XCTAssertEqual(summary.review.recommendation, .verifyWork)
        XCTAssertTrue(summary.review.findings.contains { $0.id == "stale-proof" })
    }

    func testWorkflowSpinePrefersNewestChangedOutput() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Spine Changes", mission: "Keep newest work easy to resume.", workspaceName: "Default")
        context.insert(project)
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            context: context,
            now: Date(timeIntervalSince1970: 900)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Update ProjectDashboardView.swift and verify it.",
            severity: .running,
            sourceType: .system,
            context: context,
            now: Date(timeIntervalSince1970: 910)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Updated source",
            path: "AgentPad/Views/ProjectDashboardView.swift",
            context: context,
            now: Date(timeIntervalSince1970: 920)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)

        XCTAssertEqual(summary.workflowSpine.changedTitle, "Updated source")
        XCTAssertEqual(summary.workflowSpine.changedDetail, "ProjectDashboardView.swift")
        XCTAssertEqual(summary.workflowSpine.latestChangedPath, "AgentPad/Views/ProjectDashboardView.swift")
        XCTAssertEqual(summary.workflowSpine.latestArtifactPath, "proof.html")
        XCTAssertTrue(summary.workflowSpine.nextActionDetail.contains("Run the fastest verification"))
    }

    func testWorkflowSpineSurfacesStaleProofAsRefreshWork() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Spine Proof", mission: "Keep proof current after each iteration.", workspaceName: "Default")
        context.insert(project)
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            context: context,
            now: Date(timeIntervalSince1970: 930)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Make one more iteration after proof was captured.",
            severity: .running,
            sourceType: .system,
            context: context,
            now: Date(timeIntervalSince1970: 950)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)

        XCTAssertTrue(summary.review.hasStaleProof)
        XCTAssertEqual(summary.workflowSpine.proofTitle, "Proof needs refresh")
        XCTAssertTrue(summary.workflowSpine.proofDetail.contains("proof.html"))
        XCTAssertEqual(summary.workflowSpine.nextActionTitle, "Verify")
    }

    func testMissionOSContractTreatsStaleProofAsWaitingGate() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Stale Gate", mission: "Refresh proof after each project iteration.", workspaceName: "Default")
        context.insert(project)
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            context: context,
            now: Date(timeIntervalSince1970: 1_000)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Make a second iteration after the first proof.",
            severity: .running,
            sourceType: .system,
            context: context,
            now: Date(timeIntervalSince1970: 1_020)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)
        let proofGate = try XCTUnwrap(summary.missionContract.gates.first { $0.id == "proof" })

        XCTAssertEqual(proofGate.state, .waiting)
        XCTAssertTrue(proofGate.detail.contains("needs refresh"))
        XCTAssertEqual(summary.missionContract.recommendedIntent, .verifyWork)
        XCTAssertTrue(summary.missionContract.proofRequirement.contains("Refresh proof"))
        XCTAssertTrue(summary.review.hasStaleProof)
    }

    func testArtifactPreviewRefreshesIterationProofWithoutDuplicateArtifact() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Preview Loop", mission: "Open artifacts, inspect them, and keep proof current.", workspaceName: "Default")
        context.insert(project)
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            context: context,
            now: Date(timeIntervalSince1970: 1_100)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Inspect proof.html and decide the next iteration.",
            severity: .running,
            sourceType: .system,
            context: context,
            now: Date(timeIntervalSince1970: 1_110)
        )
        ProjectEventRecorder.noteArtifactPreview(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            context: context,
            now: Date(timeIntervalSince1970: 1_130)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)

        XCTAssertEqual(project.artifacts.filter { $0.path == "proof.html" }.count, 1)
        XCTAssertFalse(summary.review.hasStaleProof)
        XCTAssertEqual(summary.workflowSpine.latestArtifactPath, "proof.html")
        XCTAssertTrue(summary.workflowSpine.iterationPrompt.contains("proof.html"))
        XCTAssertEqual(summary.missionContract.gates.first { $0.id == "proof" }?.state, .satisfied)
    }

    func testWorkflowSpineExplainsApprovalAndRecoveryStates() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let approvalProject = Project(name: "Approval Spine", mission: "Pause safely before mutating files.", workspaceName: "Default")
        let approvalRun = ToolRun(
            name: "write_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            status: .pendingApproval,
            requiresApproval: true,
            isMutating: true,
            project: approvalProject
        )
        context.insert(approvalProject)
        context.insert(approvalRun)
        ProjectEventRecorder.record(
            project: approvalProject,
            kind: .toolApprovalRequested,
            title: "Approval needed for write_file",
            detail: #"{"path":"proof.html"}"#,
            severity: .warning,
            sourceType: .toolRun,
            sourceID: approvalRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_200)
        )

        let failedProject = Project(name: "Recovery Spine", mission: "Recover cleanly from failed proof.", workspaceName: "Default")
        let failedRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            output: "Error: invalid markup",
            status: .failed,
            project: failedProject
        )
        failedRun.completedAt = Date(timeIntervalSince1970: 1_210)
        context.insert(failedProject)
        context.insert(failedRun)
        ProjectEventRecorder.record(
            project: failedProject,
            kind: .runFailed,
            title: "Validation failed",
            detail: "proof.html has invalid markup.",
            severity: .failure,
            sourceType: .toolRun,
            sourceID: failedRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_211)
        )
        try context.save()

        let approvalSummary = ProjectMissionSummarizer.summarize(project: approvalProject, context: context)
        let recoverySummary = ProjectMissionSummarizer.summarize(project: failedProject, context: context)

        XCTAssertEqual(approvalSummary.workflowSpine.currentTitle, "Human decision needed")
        XCTAssertEqual(approvalSummary.workflowSpine.blockerTitle, "Waiting")
        XCTAssertEqual(approvalSummary.workflowSpine.nextActionTitle, "Review")
        XCTAssertTrue(approvalSummary.workflowSpine.nextActionDetail.contains("approval"))

        XCTAssertEqual(recoverySummary.workflowSpine.currentTitle, "Recovery needed")
        XCTAssertEqual(recoverySummary.workflowSpine.nextActionTitle, "Recover")
        XCTAssertTrue(recoverySummary.workflowSpine.blockerDetail.contains("Validation failed"))
        XCTAssertEqual(recoverySummary.missionContract.recommendedIntent, .fixBlocker)
    }

    func testProjectLoopMultipleIterationsKeepsLatestProofCurrentAndDeduped() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Full Loop", mission: "Ask, build, inspect, iterate, and prove one artifact.", workspaceName: "Default")
        let conversation = Conversation(title: "Full Loop", project: project)
        context.insert(project)
        context.insert(conversation)

        let firstRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            output: "HTML validation passed for proof.html",
            status: .completed,
            project: project
        )
        firstRun.createdAt = Date(timeIntervalSince1970: 1_300)
        firstRun.completedAt = Date(timeIntervalSince1970: 1_301)
        context.insert(firstRun)
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Create proof.html and validate it.",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_299)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Wrote artifact",
            path: "proof.html",
            sourceToolRunID: firstRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_300)
        )
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            sourceToolRunID: firstRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_301)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Validated proof.html",
            severity: .success,
            sourceType: .toolRun,
            sourceID: firstRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_302)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Validated proof.html",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_303)
        )

        let secondRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            output: "HTML validation passed for updated proof.html",
            status: .completed,
            project: project
        )
        secondRun.createdAt = Date(timeIntervalSince1970: 1_320)
        secondRun.completedAt = Date(timeIntervalSince1970: 1_323)
        context.insert(secondRun)
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Improve proof.html and re-run validation.",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_319)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Improved artifact",
            path: "proof.html",
            sourceToolRunID: secondRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_321)
        )
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            sourceToolRunID: secondRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_322)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Validated updated proof.html",
            severity: .success,
            sourceType: .toolRun,
            sourceID: secondRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_324)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Validated updated proof.html",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 1_325)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)

        XCTAssertEqual(project.artifacts.filter { $0.path == "proof.html" }.count, 1)
        XCTAssertFalse(summary.review.hasStaleProof)
        XCTAssertEqual(summary.workflowSpine.latestArtifactPath, "proof.html")
        XCTAssertEqual(summary.workflowSpine.latestChangedPath, "proof.html")
        XCTAssertEqual(summary.nextStep, "Review the latest proof.")
        XCTAssertEqual(summary.missionContract.decisionLabel, "Ready to review")
        XCTAssertEqual(summary.missionContract.gates.first { $0.id == "proof" }?.state, .satisfied)
        XCTAssertEqual(summary.missionContract.gates.first { $0.id == "verification" }?.state, .satisfied)
    }

    func testProjectReviewStopsAutoContinueForWrongProjectRisk() throws {
        let project = Project(name: "Workspace Guard", mission: "Keep autonomous continuation scoped to the active workspace.", workspaceName: "Default")
        project.autoContinueEnabled = true
        let command = TerminalCommandRecord(
            project: project,
            command: "xcodebuild test",
            output: "ok",
            status: .completed,
            workspaceName: "Other Workspace",
            completedAt: Date(timeIntervalSince1970: 830),
            durationMs: 42
        )
        let event = ProjectEvent(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "xcodebuild test passed",
            severity: .success,
            sourceType: .terminalCommand,
            sourceID: command.id,
            createdAt: Date(timeIntervalSince1970: 831)
        )

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [],
            terminalCommands: [command],
            artifacts: [],
            fileChanges: [],
            events: [event]
        )

        XCTAssertTrue(summary.review.hasWrongProjectRisk)
        XCTAssertEqual(summary.review.recommendation, .askUser)

        let evaluation = ProjectAutoContinuePolicy.evaluate(
            project: project,
            summary: summary,
            settings: nil,
            runtimeIsWorking: false,
            hasPendingRuntimeApproval: false,
            runCompleted: true,
            runFailedOrPaused: false,
            hasUsableProviderCredential: true,
            latestRunEventID: event.id.uuidString
        )
        XCTAssertEqual(evaluation.action, .stop)
        XCTAssertEqual(evaluation.title, "Wrong-project risk")
    }

    func testMissionOSContractBlocksAutonomyWhenFailureEvidenceExists() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Mission OS Failure", mission: "Recover safely from failed runs.", workspaceName: "Default")
        let run = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            output: "Error: invalid markup",
            status: .failed,
            project: project
        )
        run.completedAt = Date(timeIntervalSince1970: 710)
        context.insert(project)
        context.insert(run)
        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Validation failed",
            detail: "proof.html still has invalid markup.",
            severity: .failure,
            sourceType: .toolRun,
            sourceID: run.id,
            context: context,
            now: Date(timeIntervalSince1970: 711)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [run],
            terminalCommands: [],
            artifacts: [],
            fileChanges: [],
            events: try context.fetch(FetchDescriptor<ProjectEvent>())
        )

        XCTAssertEqual(summary.status, .blocked)
        XCTAssertEqual(summary.missionContract.recommendedIntent, .fixBlocker)
        XCTAssertEqual(summary.missionContract.decisionLabel, "Fix blocker")
        XCTAssertTrue(summary.missionContract.blockingGates.contains { $0.id == "safety" })
        XCTAssertTrue(summary.missionContract.blockingGates.contains { $0.id == "verification" })
        XCTAssertLessThan(summary.missionContract.readinessScore, 70)
    }

    func testMissionOSContractClearsStaleFailureAfterNewerVerifiedProof() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Recovered Mission", mission: "Recover from a failed proof and keep going.", workspaceName: "Default")
        let conversation = Conversation(title: "Recovered Mission", project: project)
        let failedRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            output: "Error: invalid markup",
            status: .failed,
            project: project
        )
        failedRun.completedAt = Date(timeIntervalSince1970: 800)
        let recoveredRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            output: "passed",
            status: .completed,
            project: project
        )
        recoveredRun.completedAt = Date(timeIntervalSince1970: 805)
        context.insert(project)
        context.insert(conversation)
        context.insert(failedRun)
        context.insert(recoveredRun)
        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Validation failed",
            detail: "proof.html was invalid.",
            severity: .failure,
            sourceType: .toolRun,
            sourceID: failedRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 801)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Fix proof.html and run fast validation.",
            severity: .running,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 802)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Fixed proof markup",
            path: "proof.html",
            sourceToolRunID: recoveredRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 804)
        )
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: project,
            sourceToolRunID: recoveredRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 806)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runCompleted,
            title: "Run completed",
            detail: "Validated proof.html",
            severity: .success,
            sourceType: .toolRun,
            sourceID: recoveredRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 807)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentProofCreated,
            title: "Agent proof captured",
            detail: "Validated proof.html",
            severity: .success,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 808)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)

        XCTAssertEqual(summary.failureCount, 0)
        XCTAssertEqual(summary.status, .active)
        XCTAssertEqual(summary.blocker, "")
        XCTAssertEqual(summary.missionContract.recommendedIntent, .reviewEvidence)
        XCTAssertFalse(summary.missionContract.blockingGates.contains { $0.id == "safety" })
        XCTAssertEqual(summary.nextStep, "Review the latest proof.")
    }

    func testMissionOSContractRoutesRecoveryEditToVerificationNotFixBlocker() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Recovery Edit", mission: "Patch failed work, then verify the patch.", workspaceName: "Default")
        let failedRun = ToolRun(
            name: "validate_html_file",
            argumentsJSON: #"{"path":"proof.html"}"#,
            output: "Error: invalid markup",
            status: .failed,
            project: project
        )
        failedRun.completedAt = Date(timeIntervalSince1970: 820)
        context.insert(project)
        context.insert(failedRun)
        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Validation failed",
            detail: "proof.html was invalid.",
            severity: .failure,
            sourceType: .toolRun,
            sourceID: failedRun.id,
            context: context,
            now: Date(timeIntervalSince1970: 821)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .agentPlanCreated,
            title: "Agent plan prepared",
            detail: "Patch the invalid proof and run the fastest check.",
            severity: .running,
            sourceType: .system,
            context: context,
            now: Date(timeIntervalSince1970: 822)
        )
        ProjectEventRecorder.recordFileChange(
            project: project,
            action: "Patched proof markup",
            path: "proof.html",
            context: context,
            now: Date(timeIntervalSince1970: 823)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(project: project, context: context)

        XCTAssertEqual(summary.failureCount, 0)
        XCTAssertEqual(summary.status, .active)
        XCTAssertEqual(summary.blocker, "")
        XCTAssertEqual(summary.missionContract.recommendedIntent, .verifyWork)
        XCTAssertNotEqual(summary.missionContract.decisionLabel, "Fix blocker")
        XCTAssertTrue(summary.missionContract.blockingGates.isEmpty)
        XCTAssertEqual(summary.nextStep, "Run the fastest verification or screenshot proof check.")
    }

    func testContinuationInstructionIncludesMissionProofBlockerAndNextStep() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Continue OS", mission: "Ship the project loop.", workspaceName: "Default")
        project.blocker = "Need simulator proof"
        context.insert(project)
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "Screens/mission-control.png"),
            project: project,
            context: context,
            now: Date(timeIntervalSince1970: 600)
        )
        ProjectEventRecorder.record(
            project: project,
            kind: .runFailed,
            title: "Simulator proof missing",
            detail: "Launch verification has not run.",
            severity: .failure,
            sourceType: .system,
            context: context,
            now: Date(timeIntervalSince1970: 601)
        )
        try context.save()

        let artifacts = try context.fetch(FetchDescriptor<ProjectArtifact>())
        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [],
            terminalCommands: [],
            artifacts: artifacts,
            fileChanges: [],
            events: events
        )
        let instruction = ProjectContinuationInstructionBuilder.makeInstruction(project: project, summary: summary)

        XCTAssertTrue(instruction.contains("NovaForge Project Continuation"))
        XCTAssertTrue(instruction.contains("Continue the active project as an agent run"))
        XCTAssertTrue(instruction.contains("Mission: Ship the project loop."))
        XCTAssertTrue(instruction.contains("Latest proof:"))
        XCTAssertTrue(instruction.contains("mission-control.png"))
        XCTAssertTrue(instruction.contains("Blocker: Simulator proof missing"))
        XCTAssertTrue(instruction.contains("Latest timeline event: Simulator proof missing"))
        XCTAssertTrue(instruction.contains("Recommended next step: Review the failed evidence and retry the run."))
        XCTAssertTrue(instruction.contains("Mission OS Contract:"))
        XCTAssertTrue(instruction.contains("Quality gates:"))
        XCTAssertTrue(instruction.contains("Success criteria:"))
        XCTAssertTrue(instruction.contains("Mission OS recommends: Fix Blocker"))
        XCTAssertTrue(instruction.contains("Agent Plan:"))
        XCTAssertTrue(instruction.contains("Agent Proof:"))
    }

    func testProjectContinuationRuntimeCreatesActiveProjectEvidenceOnly() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeProjectContinuation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let activeProject = Project(name: "Continue Runtime", mission: "Inspect and continue the project.", workspaceName: "Active")
        let otherProject = Project(name: "Other Runtime", mission: "Do not touch this.", workspaceName: "Other")
        let activeConversation = Conversation(title: "Active continuation", project: activeProject)
        let otherConversation = Conversation(title: "Other continuation", project: otherProject)
        let settings = AgentSettings(provider: .local, activeProjectID: activeProject.id)
        context.insert(activeProject)
        context.insert(otherProject)
        context.insert(activeConversation)
        context.insert(otherConversation)
        context.insert(settings)
        ProjectEventRecorder.ensureArtifact(
            WorkspaceArtifact(path: "proof.html"),
            project: activeProject,
            context: context,
            now: Date(timeIntervalSince1970: 800)
        )
        ProjectEventRecorder.record(
            project: activeProject,
            kind: .conversationContinued,
            title: "Agent continued \(activeProject.name)",
            detail: "Queued autonomous continuation. Next: Continue with a focused workspace inspection.",
            severity: .info,
            sourceType: .conversation,
            sourceID: activeConversation.id,
            context: context,
            now: Date(timeIntervalSince1970: 801)
        )
        try context.save()

        let summary = ProjectMissionSummarizer.summarize(
            project: activeProject,
            conversations: [activeConversation, otherConversation],
            toolRuns: [],
            terminalCommands: [],
            artifacts: try context.fetch(FetchDescriptor<ProjectArtifact>()),
            fileChanges: [],
            events: try context.fetch(FetchDescriptor<ProjectEvent>())
        )
        let instruction = ProjectContinuationInstructionBuilder.makeInstruction(project: activeProject, summary: summary)
        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        runtime.ensureSeedWorkspace()
        try runtime.workspace.write(
            "proof.html",
            contents: """
            <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Proof</title></head><body><main><h1>Proof</h1></main></body></html>
            """
        )
        runtime.send(prompt: instruction, conversation: activeConversation, settings: settings, context: context, project: activeProject)

        let deadline = Date().addingTimeInterval(5)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)

        let runs = try context.fetch(FetchDescriptor<ToolRun>())
        XCTAssertEqual(Set(runs.map(\.name)), ["workspace_summary", "file_info", "validate_html_file"])
        XCTAssertTrue(runs.allSatisfy { $0.project?.id == activeProject.id })
        XCTAssertTrue(runs.allSatisfy { $0.status == .completed })
        let runIDs = Set(runs.map { $0.id.uuidString })

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertTrue(events.contains { $0.project?.id == activeProject.id && $0.kind == .conversationContinued })
        XCTAssertTrue(events.contains { $0.project?.id == activeProject.id && $0.kind == .promptQueued })
        XCTAssertTrue(events.contains { $0.project?.id == activeProject.id && $0.kind == .agentPlanCreated })
        XCTAssertTrue(events.contains { $0.project?.id == activeProject.id && $0.kind == .agentProofCreated })
        let completedToolEventIDs = Set(events.filter {
            $0.project?.id == activeProject.id && $0.kind == .toolCompleted && $0.sourceType == .toolRun
        }.compactMap(\.sourceIDString))
        XCTAssertTrue(completedToolEventIDs.isSuperset(of: runIDs))
        XCTAssertTrue(events.contains { $0.project?.id == activeProject.id && $0.kind == .runCompleted })
        XCTAssertFalse(events.contains { $0.project?.id == otherProject.id })

        XCTAssertTrue(activeConversation.messages.contains { $0.role == .user && $0.content.contains("NovaForge Project Continuation") })
        XCTAssertTrue(activeConversation.messages.contains { $0.role == .assistant && $0.content.contains("Agent Plan:") })
        XCTAssertTrue(activeConversation.messages.contains { $0.role == .assistant && $0.content.contains("Agent Proof:") })
        XCTAssertEqual(otherConversation.messageCount, 0)
    }

    func testGenericProjectRenamesFromFirstAgentActionIntent() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeProjectRename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let project = Project(name: "Mission Draft 2", mission: "Plan, build, and verify one focused outcome.", workspaceName: "Default")
        let conversation = Conversation(title: "Mission Draft 2", project: project)
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        runtime.ensureSeedWorkspace()
        runtime.send(
            prompt: "list files for robotics dashboard",
            conversation: conversation,
            settings: settings,
            context: context,
            project: project
        )

        let deadline = Date().addingTimeInterval(5)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)
        XCTAssertEqual(project.name, "Dashboard Build")
        XCTAssertEqual(conversation.title, "Dashboard Build")
        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertTrue(events.contains { event in
            event.project?.id == project.id &&
            event.kind == .projectRenamed &&
            event.detail == "Mission Draft 2 -> Dashboard Build"
        })
    }

    func testAgentRunCommandCreatesProjectTerminalEvidence() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeAgentCommand-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let project = Project(name: "Command Evidence", workspaceName: "Default")
        let conversation = Conversation(title: "Command Evidence", project: project)
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        runtime.ensureSeedWorkspace()
        runtime.send(
            prompt: "run command pwd",
            conversation: conversation,
            settings: settings,
            context: context,
            project: project
        )

        let deadline = Date().addingTimeInterval(5)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)

        let runs = try context.fetch(FetchDescriptor<ToolRun>())
        let run = try XCTUnwrap(runs.first { $0.name == "run_command" })
        XCTAssertEqual(run.project?.id, project.id)
        XCTAssertEqual(run.status, .completed)

        let commands = try context.fetch(FetchDescriptor<TerminalCommandRecord>())
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.project?.id, project.id)
        XCTAssertEqual(command.command, "pwd")
        XCTAssertEqual(command.status, .completed)
        XCTAssertEqual(command.sourceToolRunIDString, run.id.uuidString)

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertTrue(events.contains { event in
            event.project?.id == project.id &&
            event.kind == .terminalCommand &&
            event.sourceIDString == command.id.uuidString
        })

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [conversation],
            toolRuns: runs,
            terminalCommands: commands,
            artifacts: [],
            fileChanges: [],
            events: events
        )
        XCTAssertEqual(summary.terminalCommandCount, 1)
        XCTAssertTrue(summary.proofItems.contains { $0.id.hasPrefix("terminal-") && $0.detail == "pwd" })
    }

    func testAgentCommandFailureCreatesUsefulProjectTimelineEvidence() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeAgentCommandFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let project = Project(name: "Command Failure", workspaceName: "Default")
        let conversation = Conversation(title: "Command Failure", project: project)
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        runtime.ensureSeedWorkspace()
        runtime.send(
            prompt: "run command unknown_tool",
            conversation: conversation,
            settings: settings,
            context: context,
            project: project
        )

        let deadline = Date().addingTimeInterval(5)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        if case .failed(let message) = runtime.runState {
            XCTAssertTrue(message.contains("unsupported") || message.contains("Error"))
        } else {
            XCTFail("Expected failed run state, got \(runtime.runState)")
        }

        let runs = try context.fetch(FetchDescriptor<ToolRun>())
        let run = try XCTUnwrap(runs.first { $0.name == "run_command" })
        XCTAssertEqual(run.status, .failed)

        let commands = try context.fetch(FetchDescriptor<TerminalCommandRecord>())
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(command.status, .failed)
        XCTAssertEqual(command.sourceToolRunIDString, run.id.uuidString)

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertTrue(events.contains { $0.project?.id == project.id && $0.kind == .runFailed })
        XCTAssertTrue(events.contains { $0.project?.id == project.id && $0.kind == .agentProofCreated && $0.severity == .failure })

        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [conversation],
            toolRuns: runs,
            terminalCommands: commands,
            artifacts: [],
            fileChanges: [],
            events: events
        )
        XCTAssertEqual(summary.status, .blocked)
        XCTAssertTrue(summary.nextStep.contains("retry"))
        XCTAssertTrue(summary.proofItems.contains { $0.id.hasPrefix("terminal-failure-") && $0.detail == "unknown_tool" })
    }

    func testProjectNamingEngineSuggestsSpecificIdentityForGenericProjects() throws {
        let suggestion = try XCTUnwrap(
            ProjectNamingEngine.suggestedIdentity(
                prompt: "Build a liquid glass project switching command center with smoother project menus.",
                currentProjectName: "Project 2",
                currentMission: "Plan, build, and verify one focused outcome.",
                existingProjectNames: ["NovaForge Project"]
            )
        )

        XCTAssertEqual(suggestion.name, "Liquid Glass Project Menu")
        XCTAssertTrue(suggestion.mission.contains("liquid glass project switching command center"))
        XCTAssertNil(
            ProjectNamingEngine.suggestedIdentity(
                prompt: "Project 2",
                currentProjectName: "Project 2",
                currentMission: "Plan, build, and verify one focused outcome.",
                existingProjectNames: []
            )
        )
        XCTAssertNil(
            ProjectNamingEngine.suggestedIdentity(
                prompt: "Build a snake game",
                currentProjectName: "Arcade Polish",
                currentMission: "Ship arcade polish.",
                existingProjectNames: []
            )
        )
    }

    func testSettingsChangesCreateMaterialProjectTimelineEvents() throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Settings OS", workspaceName: "Default")
        let settings = AgentSettings(provider: .openAI, modelID: "gpt-4.1", autoApproveWrites: false, temperature: 0.2)
        let previous = AgentSettingsPersistence.snapshot(settings)
        settings.switchProvider(to: .local)
        settings.modelID = LocalModelCatalog.defaultVariant.id
        settings.autoApproveWrites = true
        settings.temperature = 0.7
        settings.customSystemPrompt = "Use project OS context."
        let current = AgentSettingsPersistence.snapshot(settings)
        context.insert(project)
        context.insert(settings)

        let detail = try XCTUnwrap(AgentSettingsPersistence.materialExecutionChangeDetail(from: previous, to: current))
        ProjectEventRecorder.recordSettingsChange(
            project: project,
            detail: detail,
            context: context,
            now: Date(timeIntervalSince1970: 700)
        )
        try context.save()

        XCTAssertTrue(detail.contains("Provider:"))
        XCTAssertTrue(detail.contains("Model:"))
        XCTAssertTrue(detail.contains("Writes: auto-approve enabled"))
        XCTAssertTrue(detail.contains("Temperature: 0.2 -> 0.7"))
        XCTAssertTrue(detail.contains("System prompt: custom"))
        XCTAssertFalse(detail.contains("Use project OS context."))

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        XCTAssertTrue(events.contains { event in
            event.project?.id == project.id &&
            event.kind == .settingsChanged &&
            event.sourceType == .settings &&
            event.detail == detail
        })

        let timestampOnly = AgentSettingsPersistence.Snapshot(
            providerRawValue: current.providerRawValue,
            modelID: current.modelID,
            customChatCompletionsURL: current.customChatCompletionsURL,
            autoApproveWrites: current.autoApproveWrites,
            activeWorkspaceName: current.activeWorkspaceName,
            activeProjectIDString: current.activeProjectIDString,
            temperature: current.temperature,
            customSystemPrompt: current.customSystemPrompt,
            updatedAt: Date(timeIntervalSince1970: 999)
        )
        XCTAssertNil(AgentSettingsPersistence.materialExecutionChangeDetail(from: current, to: timestampOnly))
    }

    func testSettingsPersistenceRestoresWorkspaceAndProjectAfterSaveFailure() throws {
        enum SaveFailure: LocalizedError {
            case diskFull
        }

        let originalProjectID = UUID()
        let attemptedProjectID = UUID()
        let settings = AgentSettings(
            activeWorkspaceName: "OriginalWorkspace",
            activeProjectID: originalProjectID
        )

        XCTAssertThrowsError(
            try AgentSettingsPersistence.persist(
                settings: settings,
                mutate: { settings in
                    settings.activeWorkspaceName = "AttemptedWorkspace"
                    settings.activeProjectID = attemptedProjectID
                },
                save: { throw SaveFailure.diskFull }
            )
        )

        XCTAssertEqual(settings.activeWorkspaceName, "OriginalWorkspace")
        XCTAssertEqual(settings.activeProjectID, originalProjectID)
    }

    func testLocalRuntimePersistsProjectOwnedToolRunsAndEvents() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeProjectRuntime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let project = Project(name: "Runtime Ownership", workspaceName: "Default")
        let conversation = Conversation(title: "Runtime", project: project)
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        runtime.ensureSeedWorkspace()
        runtime.send(prompt: "list files", conversation: conversation, settings: settings, context: context, project: project)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(runtime.isWorking)
        XCTAssertEqual(runtime.runState, .completed)

        let runs = try context.fetch(FetchDescriptor<ToolRun>())
        XCTAssertFalse(runs.isEmpty)
        XCTAssertTrue(runs.allSatisfy { $0.project?.id == project.id })
        XCTAssertTrue(project.events.contains { $0.kind == .promptQueued })
        XCTAssertTrue(project.events.contains { $0.kind == .toolCompleted })
        XCTAssertTrue(project.events.contains { $0.kind == .runCompleted })
    }

    func testRuntimePersistsCanonicalRunReceiptAndLinksTranscript() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeCanonicalRun-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let project = Project(name: "Canonical Run", workspaceName: "Default")
        let conversation = Conversation(title: "Canonical Run", project: project)
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        runtime.ensureSeedWorkspace()
        runtime.send(prompt: "list files", conversation: conversation, settings: settings, context: context, project: project)

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(40))
        }

        let receipt = try XCTUnwrap(try context.fetch(FetchDescriptor<AgentRunRecord>()).first)
        XCTAssertEqual(receipt.status, .completed)
        XCTAssertEqual(receipt.conversationID, conversation.id)
        XCTAssertEqual(receipt.projectID, project.id)
        XCTAssertNotNil(receipt.requestMessageID)
        XCTAssertNotNil(receipt.responseMessageID)
        XCTAssertTrue(conversation.messages.allSatisfy { $0.runID == receipt.id && $0.runStatus == .completed })
        XCTAssertTrue(try context.fetch(FetchDescriptor<ToolRun>()).allSatisfy { $0.runID == receipt.id })
    }

    func testRuntimeRenamesGenericProjectFromFirstAgentPrompt() async throws {
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let workspaceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeProjectRename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspaceRoot) }

        let project = Project(name: "Project 2", workspaceName: "Default")
        let conversation = Conversation(title: "Project 2", project: project)
        let settings = AgentSettings(provider: .local, activeProjectID: project.id)
        context.insert(project)
        context.insert(conversation)
        context.insert(settings)
        try context.save()

        let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
        runtime.ensureSeedWorkspace()
        runtime.send(prompt: "Build a snake game, then list files.", conversation: conversation, settings: settings, context: context, project: project)

        XCTAssertEqual(project.name, "Snake Game")
        XCTAssertEqual(conversation.title, "Snake Game")
        XCTAssertTrue(project.events.contains { $0.kind == .projectRenamed && $0.detail == "Project 2 -> Snake Game" })

        let deadline = Date().addingTimeInterval(3)
        while runtime.isWorking && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(runtime.isWorking)
    }
}
