import Foundation

actor AgentEngine {
    enum Update: Sendable { case text(String), event(AppModel.AgentEvent), todos([AppModel.Todo]), metrics(AppModel.RuntimeMetrics) }
    private struct ToolCall: Decodable, Sendable { let name: String; let path: String?; let destination: String?; let query: String?; let content: String?; let old: String?; let replacement: String?; let title: String?; let state: String?; let text: String?; let source: String?; let reason: String? }
    enum AgentError: LocalizedError {
        case cancelled, repeatedLoop, stepLimit, malformedTool, planMutation(String)
        var errorDescription: String? { switch self { case .cancelled: "The agent run was cancelled."; case .repeatedLoop: "The agent repeated the same tool call too many times, so the runaway loop was stopped."; case .stepLimit: "The agent reached the guarded 128-step run limit."; case .malformedTool: "The model emitted a malformed tool call."; case .planMutation(let n): "Plan mode blocked the mutating tool ‘\(n)’." } }
    }

    private let workspace: WorkspaceManager; private let context: ContextEngine; private let runtime: LlamaRuntime
    private var cancelled = false; private let maxSteps = 128
    init(workspace: WorkspaceManager, context: ContextEngine, runtime: LlamaRuntime) { self.workspace = workspace; self.context = context; self.runtime = runtime }
    func cancel() async { cancelled = true; await runtime.cancel() }

    func run(userText: String, history: [AppModel.ChatMessage], mode: AppModel.AgentMode, todos: [AppModel.Todo]) async throws -> AsyncThrowingStream<Update, Error> {
        guard await runtime.isLoaded() else { throw LlamaRuntime.RuntimeError.noModel }; cancelled = false
        return AsyncThrowingStream { continuation in Task { do { try await self.loop(userText: userText, history: history, mode: mode, initialTodos: todos, continuation: continuation); continuation.finish() } catch { continuation.finish(throwing: error) } } }
    }

    private func loop(userText: String, history: [AppModel.ChatMessage], mode: AppModel.AgentMode, initialTodos: [AppModel.Todo], continuation: AsyncThrowingStream<Update, Error>.Continuation) async throws {
        var todos = initialTodos, conversation = history, toolTail = ""; var signatures: [String:Int] = [:]; var allEvents: [AppModel.AgentEvent] = []
        let retrieved = await retrieval(for: userText)
        let stable = await context.stablePrefix(mode: mode, todos: []) + "\n\n" + compactToolContract
        for step in 1...maxSteps {
            if cancelled { throw AgentError.cancelled }
            let state = await context.dynamicState(todos: todos)
            let hot = await context.prepareConversation(messages: conversation, retrieved: retrieved, toolTail: toolTail)
            let prompt = stable + "\n\n" + state + "\n\n" + hot + "\n\nContinue the task. If complete, call finish."
            let modelStream = try await runtime.stream(prompt: prompt, maxTokens: mode == .plan ? 650 : 850)
            var response = ""; var latest = AppModel.RuntimeMetrics()
            for try await event in modelStream {
                if cancelled { throw AgentError.cancelled }
                switch event {
                case .text(let chunk): response += chunk
                case .metrics(let m):
                    latest.tokensPerSecond = m.tokensPerSecond; latest.timeToFirstTokenMS = m.timeToFirstTokenMS; latest.outputTokens = m.outputTokens; latest.promptTokens = m.promptTokens; latest.cachedPrefixTokens = m.cachedPrefixTokens; latest.contextTokens = await context.estimateTokens(prompt); latest.contextBudget = 4096; latest.thermal = thermalName(); latest.backend = m.backend; continuation.yield(.metrics(latest))
                }
            }
            if let call = try parseTool(response) {
                let sig = signature(call); signatures[sig, default: 0] += 1; if signatures[sig, default: 0] >= 4 { throw AgentError.repeatedLoop }
                if call.name == "finish" { if let reason = call.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty { continuation.yield(.text(reason)) }; continuation.yield(.event(.init(kind: .success, title: "Run complete", detail: "Finished after \(step) agent step\(step == 1 ? "" : "s")."))); return }
                let result = try await execute(call, mode: mode, todos: &todos); toolTail = compressToolResult(result, call: call)
                let toolEvent = AppModel.AgentEvent(kind: .tool, title: call.name, detail: toolTail); allEvents.append(toolEvent); continuation.yield(.event(toolEvent)); continuation.yield(.todos(todos)); conversation.append(.init(role: .system, text: "TOOL_RESULT \(call.name): \(toolTail)"))
                if step % 6 == 0 { try await context.compact(messages: conversation, toolEvents: allEvents); let compact = AppModel.AgentEvent(kind: .memory, title: "Context compacted", detail: "Old observations left the hot prompt; durable state stayed in project memory/files."); allEvents.append(compact); continuation.yield(.event(compact)) }
                let checkpoint = AppModel.AgentEvent(kind: .checkpoint, title: "Checkpoint \(step)", detail: "Agent state persisted after tool execution."); allEvents.append(checkpoint); continuation.yield(.event(checkpoint)); continue
            }
            let clean = stripToolEnvelope(response).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { for chunk in chunkForUI(clean) { continuation.yield(.text(chunk)) }; return }
        }
        throw AgentError.stepLimit
    }

    private var compactToolContract: String { """
    TOOLS — exactly one per model turn:
    read {path}; search {query}; write {path,content}; patch {path,old,replacement}; mkdir {path}; delete {path}; move {path,destination}; undo {}; todo {title,state}; remember {text,source}; finish {reason}.
    Emit only one compact envelope when using a tool: <tool_call>{\"name\":\"read\",\"path\":\"src/main.js\"}</tool_call>
    Read/search before editing. Prefer exact patch for small changes. Keep modules small and testable.
    """ }

    private func retrieval(for userText: String) async -> String {
        var lines: [String] = []
        if let entries = try? await workspace.entries() { lines.append("PROJECT TREE\n" + entries.prefix(70).map { ($0.isDirectory ? "[dir] " : "") + $0.relativePath }.joined(separator: "\n")) }
        let words = userText.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 }.uniqued().prefix(5)
        for word in words { if let hits = try? await workspace.search(word, maxHits: 6), !hits.isEmpty { lines.append("MATCHES ‘\(word)’\n" + hits.map { "\($0.path):\($0.line) \($0.text)" }.joined(separator: "\n")) } }
        return lines.joined(separator: "\n\n")
    }

    private func execute(_ call: ToolCall, mode: AppModel.AgentMode, todos: inout [AppModel.Todo]) async throws -> String {
        if mode == .plan && ["write","patch","mkdir","delete","move","undo"].contains(call.name) { throw AgentError.planMutation(call.name) }
        switch call.name {
        case "read": return try await workspace.read(require(call.path))
        case "search": let hits = try await workspace.search(require(call.query), maxHits: 30); return hits.isEmpty ? "No matches." : hits.map { "\($0.path):\($0.line) \($0.text)" }.joined(separator: "\n")
        case "write": let p = try require(call.path); try await workspace.write(p, content: require(call.content)); return "Wrote \(p)."
        case "patch": let p = try require(call.path); try await workspace.patch(p, exact: require(call.old), replacement: require(call.replacement)); return "Patched \(p) by one exact match."
        case "mkdir": let p = try require(call.path); try await workspace.makeDirectory(p); return "Created \(p)."
        case "delete": let p = try require(call.path); try await workspace.delete(p); return "Deleted \(p)."
        case "move": let p = try require(call.path), d = try require(call.destination); try await workspace.move(p, to: d); return "Moved \(p) → \(d)."
        case "undo": return try await workspace.undo()
        case "todo": let title = try require(call.title), state = AppModel.Todo.State(rawValue: call.state ?? "pending") ?? .pending; if let i = todos.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) { todos[i].state = state } else { todos.append(.init(title: title, state: state)) }; return "TODO ‘\(title)’ is \(state.rawValue)."
        case "remember": try await context.remember(require(call.text), source: call.source ?? "agent"); return "Saved durable project memory."
        default: throw AgentError.malformedTool
        }
    }

    private func parseTool(_ text: String) throws -> ToolCall? { guard let start = text.range(of: "<tool_call>") else { return nil }; guard let end = text.range(of: "</tool_call>", range: start.upperBound..<text.endIndex) else { throw AgentError.malformedTool }; let json = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines); guard let data = json.data(using: .utf8), let call = try? JSONDecoder().decode(ToolCall.self, from: data) else { throw AgentError.malformedTool }; return call }
    private func signature(_ c: ToolCall) -> String { [c.name,c.path,c.destination,c.query,c.old,c.title,c.state,c.text].compactMap { $0 }.joined(separator: "|").lowercased() }
    private func stripToolEnvelope(_ text: String) -> String { guard let start = text.range(of: "<tool_call>"), let end = text.range(of: "</tool_call>", range: start.upperBound..<text.endIndex) else { return text }; var copy = text; copy.removeSubrange(start.lowerBound..<end.upperBound); return copy }
    private func compressToolResult(_ result: String, call: ToolCall) -> String { let limit = call.name == "read" || call.name == "search" ? 4_000 : 1_100; return result.count <= limit ? result : String(result.prefix(limit)) + "\n[…tool output elided…]" }
    private func chunkForUI(_ text: String) -> [String] { var out:[String]=[], i=text.startIndex; while i<text.endIndex { let e=text.index(i,offsetBy:72,limitedBy:text.endIndex) ?? text.endIndex; out.append(String(text[i..<e])); i=e }; return out }
    private func require(_ value: String?) throws -> String { guard let value, !value.isEmpty else { throw AgentError.malformedTool }; return value }
    private func thermalName() -> String { switch ProcessInfo.processInfo.thermalState { case .nominal: "Nominal"; case .fair: "Fair"; case .serious: "Serious"; case .critical: "Critical"; @unknown default: "Unknown" } }
}

private extension Sequence where Element == String { func uniqued() -> [String] { var seen=Set<String>(); return filter { seen.insert($0).inserted } } }
