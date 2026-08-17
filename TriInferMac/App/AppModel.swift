import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    enum Tab: String, CaseIterable, Identifiable {
        case chat, workspace, models, activity, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .chat: "Chat"
            case .workspace: "Workspace"
            case .models: "Models"
            case .activity: "Activity"
            case .settings: "Settings"
            }
        }
        var symbol: String {
            switch self {
            case .chat: "bubble.left.and.text.bubble.right"
            case .workspace: "folder"
            case .models: "shippingbox"
            case .activity: "waveform.path.ecg"
            case .settings: "gearshape"
            }
        }
    }

    enum AgentMode: String, CaseIterable, Codable, Identifiable {
        case build = "Build"
        case plan = "Plan"
        var id: String { rawValue }
        var symbol: String { self == .build ? "hammer" : "list.bullet.rectangle.portrait" }
    }

    struct ChatMessage: Identifiable, Codable, Hashable {
        enum Role: String, Codable { case user, assistant, system }
        var id = UUID()
        var role: Role
        var text: String
        var timestamp = Date()
    }

    struct Todo: Identifiable, Codable, Hashable {
        enum State: String, Codable { case pending, active, done }
        var id = UUID()
        var title: String
        var state: State
    }

    struct AgentEvent: Identifiable, Codable, Hashable {
        enum Kind: String, Codable { case thinking, tool, checkpoint, memory, warning, success }
        var id = UUID()
        var kind: Kind
        var title: String
        var detail: String
        var timestamp = Date()
    }

    struct RuntimeMetrics: Codable, Hashable {
        var tokensPerSecond: Double = 0
        var timeToFirstTokenMS: Double = 0
        var outputTokens: Int = 0
        var promptTokens: Int = 0
        var cachedPrefixTokens: Int = 0
        var memoryMB: Double = 0
        var contextTokens: Int = 0
        var contextBudget: Int = 4096
        var thermal: String = "Nominal"
        var backend: String = "No model loaded"
    }

    var selectedTab: Tab = .chat
    var agentMode: AgentMode = .build
    var messages: [ChatMessage] = []
    var todos: [Todo] = []
    var events: [AgentEvent] = []
    var draft = ""
    var isGenerating = false
    var showTasks = false
    var showContext = false
    var showPerformance = false
    var showHistory = false
    var alertMessage: String?
    var runtimeMetrics = RuntimeMetrics()
    var workspaceTitle = "Nebula Runner"
    var currentModelName = "No model loaded"

    let workspace = WorkspaceManager()
    let models = ModelManager()
    let context = ContextEngine()
    private let runtime = LlamaRuntime()
    private lazy var agent = AgentEngine(workspace: workspace, context: context, runtime: runtime)

    func bootstrap() async {
        await workspace.bootstrap()
        await models.bootstrap()
        seedShowcaseIfRequested()
        if messages.isEmpty {
            messages = [
                .init(role: .assistant, text: "TriInfer is ready. Open a workspace, load a local GGUF, then give me a coding task. I keep goals, TODOs, checkpoints, retrieval memory, and old tool output outside the hot prompt so long jobs stay responsive.")
            ]
        }
        if todos.isEmpty {
            todos = [
                .init(title: "Inspect the current project", state: .active),
                .init(title: "Implement the next milestone", state: .pending),
                .init(title: "Run checks and preview the artifact", state: .pending)
            ]
        }
        await refreshModelState()
    }

    func refreshModelState() async {
        let state = await models.stateSnapshot()
        currentModelName = state.loadedName ?? "No model loaded"
        runtimeMetrics.backend = state.loadedName.map { "llama.cpp • Metal/CPU • \($0)" } ?? "No model loaded"
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        draft = ""
        messages.append(.init(role: .user, text: text))
        events.append(.init(kind: .thinking, title: "New task", detail: text))
        isGenerating = true
        Task { await runAgent(userText: text) }
    }

    func stop() {
        Task { await agent.cancel() }
        isGenerating = false
        events.append(.init(kind: .warning, title: "Run stopped", detail: "Generation and tool execution were cancelled."))
    }

    private func runAgent(userText: String) async {
        do {
            let mode = agentMode
            let history = messages
            let todosSnapshot = todos
            let stream = try await agent.run(userText: userText, history: history, mode: mode, todos: todosSnapshot)
            var assistant = ChatMessage(role: .assistant, text: "")
            messages.append(assistant)
            let index = messages.count - 1
            for try await update in stream {
                switch update {
                case .text(let text):
                    assistant.text += text
                    messages[index] = assistant
                case .event(let event):
                    events.append(event)
                case .todos(let updated):
                    todos = updated
                case .metrics(let metrics):
                    runtimeMetrics = metrics
                }
            }
        } catch {
            alertMessage = error.localizedDescription
            events.append(.init(kind: .warning, title: "Agent error", detail: error.localizedDescription))
        }
        isGenerating = false
        await refreshModelState()
    }

    func clearChat() {
        messages.removeAll()
        events.removeAll()
        Task { await context.resetConversation() }
    }

    func loadModel(_ model: ModelManager.InstalledModel) {
        isGenerating = true
        Task {
            do {
                let profile = await models.profile(for: model)
                try await runtime.load(modelURL: model.url, profile: profile)
                await models.markLoaded(model)
                events.append(.init(kind: .success, title: "Model loaded", detail: model.name))
                await refreshModelState()
            } catch {
                alertMessage = "Could not load \(model.name): \(error.localizedDescription)"
            }
            isGenerating = false
        }
    }

    private func seedShowcaseIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--ui-showcase"), args.indices.contains(flag + 1) else { return }
        let route = args[flag + 1]
        messages = [
            .init(role: .user, text: "Build the drifting physics and checkpoint system for the browser game, then test the project."),
            .init(role: .assistant, text: "I split the work into physics, race state, and HUD modules. The current checkpoint is green; next I’m tightening drift recovery without touching the renderer."),
        ]
        todos = [
            .init(title: "Refactor vehicle physics module", state: .done),
            .init(title: "Add checkpoint / lap state", state: .active),
            .init(title: "Wire HUD to race state", state: .pending),
            .init(title: "Run browser smoke test", state: .pending),
        ]
        events = [
            .init(kind: .tool, title: "Searched project", detail: "Retrieved 6 relevant files from src/ without loading the full workspace into context."),
            .init(kind: .checkpoint, title: "Checkpoint 18", detail: "Workspace journal saved after physics refactor."),
            .init(kind: .memory, title: "Context compacted", detail: "Older tool output elided; stable project decisions kept with provenance."),
            .init(kind: .success, title: "Build passed", detail: "Modular browser artifact is ready for preview."),
        ]
        runtimeMetrics = .init(tokensPerSecond: 3.8, timeToFirstTokenMS: 412, outputTokens: 684, promptTokens: 1210, cachedPrefixTokens: 846, memoryMB: 2850, contextTokens: 1860, contextBudget: 4096, thermal: "Nominal", backend: "Qwen3.8-27B • simulator preview")
        currentModelName = "Qwen3.8-27B IQ2"
        switch route {
        case "models": selectedTab = .models
        case "workspace": selectedTab = .workspace
        case "activity": selectedTab = .activity
        case "settings": selectedTab = .settings
        case "context": selectedTab = .chat; showContext = true
        case "performance": selectedTab = .chat; showPerformance = true
        default: selectedTab = .chat
        }
    }
}
