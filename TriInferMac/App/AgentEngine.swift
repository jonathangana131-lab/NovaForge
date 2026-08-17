import Foundation

actor AgentEngine {
    enum Update: Sendable {
        case text(String)
        case event(AppModel.AgentEvent)
        case todos([AppModel.Todo])
        case metrics(AppModel.RuntimeMetrics)
    }

    private struct ToolCall: Decodable, Sendable {
        let name: String
        let path: String?
        let destination: String?
        let query: String?
        let content: String?
        let old: String?
        let replacement: String?
        let title: String?
        let state: String?
        let text: String?
        let source: String?
        let reason: String?
    }

    enum AgentError: LocalizedError {
        case cancelled, repeatedLoop, stepLimit, malformedTool, planMutation(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: "The agent run was cancelled."
            case .repeatedLoop: "The agent repeated the same tool call too many times, so the runaway loop was stopped."
            case .stepLimit: "The agent reached the guarded 128-step run limit."
            case .malformedTool: "The model emitted a malformed tool call."
            case .planMutation(let name): "Plan mode blocked the mutating tool ‘\(name)’."
            }
        }
    }

    private let workspace: WorkspaceManager
    private let context: ContextEngine
    private let runtime: LlamaRuntime
    private var cancelled = false
    private let maxSteps = 128

    init(workspace: WorkspaceManager, context: ContextEngine, runtime: LlamaRuntime) {
        self.workspace = workspace; self.context = context; self.runtime = runtime
    }

    func cancel() async { cancelled = true; await runtime.cancel() }

    func run(userText: String, history: [AppModel.ChatMessage], mode: AppModel.AgentMode, todos: [AppModel.Todo]) async throws -> AsyncThrowingStream<Update, Error> {
        guard await runtime.isLoaded() else { throw LlamaRuntime.RuntimeError.noModel }
        cancelled = false
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.loop(userText: userText, history: history, mode: mode, initialTodos: todos, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func loop(userText: String, history: [AppModel.ChatMessage], mode: AppModel.AgentMode, initialTodos: [AppModel.Todo], continuation: AsyncThrowingStream<Update, Error>.Continuation) async throws {
        var todos = initialTodos
        var conversation = history
        var toolTail = ""
        var signatures: [String: Int] = [:]
        let retrieved = await retrieval(for: userText)
        var allEvents: [AppModel.AgentEvent] = []

        for step in 1...maxSteps {
            if cancelled { throw AgentError.cancelled }
            let prefix = await context.stablePrefix(mode: mode, todos: todos)
            let hot = await context.prepareConversation(messages: conversation, retrieved: retrieved, toolTail: toolTail)
            let prompt = prefix + "\n\n" + compactToolContract + "\n\n" + hot + "\n\nContinue the task. If complete, call finish."

            let modelStream = try await runtime.stream(prompt: prompt, maxTokens: mode == .plan ? 700 : 950)
            var response = ""
            var metrics = AppModel.RuntimeMetrics()
            for try await event in modelStream {
                if cancelled { throw AgentError.cancelled }
                switch event {
                case .text(let chunk): response += chunk
                case .metrics(let m):
                    metrics.tokensPerSecond = m.tokensPerSecond
                    metrics.timeToFirstTokenMS = m.timeToFirstTokenMS
                    metrics.outputTokens = m.outputTokens
                    metrics.promptTokens = m.promptTokens
                    metrics.cachedPrefixTokens = m.cachedPrefixTokens
                    metrics.contextTokens = await context.estimateTokens(prompt)
                    metrics.contextBudget = 4096
                    metrics.thermal = thermalName()
                    metrics.backend = m.backend
                    continuation.yield(.metrics(metrics))
                }
            }

            if let call = try parseTool(response) {
                let signature = normalizedSignature(call)
                signatures[signature, default: 0] += 1
                if signatures[signature, default: 0] >= 4 { throw AgentError.repeatedLoop }
                if call.name == "finish" {
                    let final = call.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let final, !final.isEmpty { continuation.yield(.text(final)) }
                    let event = AppModel.AgentEvent(kind: .success, title: "Run complete", detail: "Finished after \(step) agent step\(step == 1 ? "" : "s").")
                    continuation.yield(.event(event)); return
                }
                let result = try await execute(call, mode: mode, todos: &todos)
                toolTail = compressToolResult(result, call: call)
                let event = AppModel.AgentEvent(kind: .tool, title: call.name, detail: toolTail)
                allEvents.append(event); continuation.yield(.event(event)); continuation.yield(.todos(todos))
                conversation.append(.init(role: .system, text: "TOOL_RESULT \(call.name): \(toolTail)"))
                if step % 4 == 0 {
                    try await context.compact(messages: conversation, toolEvents: allEvents)
                    let compactEvent = AppModel.AgentEvent(kind: .memory, title: "Context compacted", detail: "Old observations were removed from the hot prompt; durable project state remains in files/memory.")
                    allEvents.append(compactEvent); continuation.yield(.event(compactEvent))
                }
                let checkpoint = AppModel.AgentEvent(kind: .checkpoint, title: "Checkpoint \(step)", detail: "Agent state persisted after tool execution.")
                allEvents.append(checkpoint); continuation.yield(.event(checkpoint))
                continue
            }

            let clean = stripToolEnvelope(response).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                for chunk in chunkForUI(clean) { continuation.yield(.text(chunk)) }
                return
            }
        }
        throw AgentError.stepLimit
    }

    private var compactToolContract: String {
        """
        TOOLS (one per turn):
        read {path}; search {query}; write {path,content}; patch {path,old,replacement}; mkdir {path}; delete {path}; move {path,destination}; undo {}; todo {title,state}; remember {text,source}; finish {reason}.
        Emit only: <tool_call>{\"name\":\"read\",\"path\":\"src/main.js\"}</tool_call>
        Use read/search before editing. Prefer exact patch for small changes. Keep modules small and testable.
        """
    }

    private func retrieval(for userText: String) async -> String {
        var lines: [String] = []
        if let entries = try? await workspace.entries() {
            let paths = entries.prefix(70).map { ($0.isDirectory ? "[dir] " : "") + $0.relativePath }
            lines.append("PROJECT TREE\n" + paths.joined(separator: "\n"))
        }
        let keywords = userText.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 }.uniqued().prefix(6)
        for keyword in keywords {
            if let hits = try? await workspace.search(keyword, maxHits: 8), !hits.isEmpty {
                lines.append("MATCHES ‘\(keyword)’\n" + hits.map { "\($0.path):\($0.line) \($0.text)" }.joined(separator: "\n"))
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private func execute(_ call: ToolCall, mode: AppModel.AgentMode, todos: inout [AppModel.Todo]) async throws -> String {
        let mutating = ["write", "patch", "mkdir", "delete", "move", "undo"]
        if mode == .plan && mutating.contains(call.name) { throw AgentError.planMutation(call.name) }
        switch call.name {
        case "read": return try await workspace.read(require(call.path))
        case "search":
            let hits = try await workspace.search(require(call.query), maxHits: 30)
            return hits.isEmpty ? "No matches." : hits.map { "\($0.path):\($0.line) \($0.text)" }.joined(separator: "\n")
        case "write": try await workspace.write(require(call.path), content: require(call.content)); return "Wrote \(require(call.path))."
        case "patch": try await workspace.patch(require(call.path), exact: require(call.old), replacement: require(call.replacement)); return "Patched \(require(call.path)) by one exact match."
        case "mkdir": try await workspace.makeDirectory(require(call.path)); return "Created \(require(call.path))."
        case "delete": try await workspace.delete(require(call.path)); return "Deleted \(require(call.path))."
        case "move": try await workspace.move(require(call.path), to: require(call.destination)); return "Moved \(require(call.path)) → \(require(call.destination))."
        case "undo": return try await workspace.undo()
        case "todo":
            let title = require(call.title); let state = AppModel.Todo.State(rawValue: call.state ?? "pending") ?? .pending
            if let index = todos.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) { todos[index].state = state }
            else { todos.append(.init(title: title, state: state)) }
            return "TODO ‘\(title)’ is \(state.rawValue)."
        case "remember": try await context.remember(require(call.text), source: call.source ?? "agent"); return "Saved durable project memory."
        default: throw AgentError.malformedTool
        }
    }

    private func parseTool(_ text: String) throws -> ToolCall? {
        guard let start = text.range(of: "<tool_call>") else { return nil }
        guard let end = text.range(of: "</tool_call>", range: start.upperBound..<text.endIndex) else { throw AgentError.malformedTool }
        let json = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8), let call = try? JSONDecoder().decode(ToolCall.self, from: data) else { throw AgentError.malformedTool }
        return call
    }

    private func normalizedSignature(_ call: ToolCall) -> String {
        [call.name, call.path, call.destination, call.query, call.old, call.title, call.state, call.text].compactMap { $0 }.joined(separator: "|").lowercased()
    }

    private func stripToolEnvelope(_ text: String) -> String {
        guard let start = text.range(of: "<tool_call>"), let end = text.range(of: "</tool_call>", range: start.upperBound..<text.endIndex) else { return text }
        var copy = text; copy.removeSubrange(start.lowerBound..<end.upperBound); return copy
    }

    private func compressToolResult(_ result: String, call: ToolCall) -> String {
        let maxChars = call.name == "read" || call.name == "search" ? 5_000 : 1_200
        if result.count <= maxChars { return result }
        return String(result.prefix(maxChars)) + "\n[…tool output elided…]"
    }

    private func chunkForUI(_ text: String) -> [String] {
        var result: [String] = []; var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 72, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[index..<end])); index = end
        }
        return result
    }

    private func require(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw AgentError.malformedTool }; return value
    }

    private func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

private extension Sequence where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>(); return filter { seen.insert($0).inserted }
    }
}
