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
        let id: String?
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
        case cancelled
        case repeatedLoop
        case stepLimit
        case malformedTool
        case planMutation(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "The agent run was cancelled."
            case .repeatedLoop: "The agent repeated the same tool call too many times, so the runaway loop was stopped."
            case .stepLimit: "The agent reached the guarded 256-step run limit. The session is checkpointed and can continue."
            case .malformedTool: "The model emitted a malformed tool call."
            case .planMutation(let name): "Plan mode blocked the mutating tool ‘\(name)’."
            }
        }
    }

    private let workspace: WorkspaceManager
    private let context: ContextEngine
    private let runtime: LlamaRuntime
    private var cancelled = false
    private let maxSteps = 256

    init(workspace: WorkspaceManager, context: ContextEngine, runtime: LlamaRuntime) {
        self.workspace = workspace
        self.context = context
        self.runtime = runtime
    }

    func cancel() async {
        cancelled = true
        await runtime.cancel()
    }

    func run(
        userText: String,
        history: [AppModel.ChatMessage],
        mode: AppModel.AgentMode,
        todos: [AppModel.Todo]
    ) async throws -> AsyncThrowingStream<Update, Error> {
        guard await runtime.isLoaded() else { throw LlamaRuntime.RuntimeError.noModel }
        cancelled = false
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.loop(
                        userText: userText,
                        history: history,
                        mode: mode,
                        initialTodos: todos,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func loop(
        userText: String,
        history: [AppModel.ChatMessage],
        mode: AppModel.AgentMode,
        initialTodos: [AppModel.Todo],
        continuation: AsyncThrowingStream<Update, Error>.Continuation
    ) async throws {
        var todos = initialTodos
        var conversation = history
        var toolTail = ""
        var signatures: [String: Int] = [:]
        var allEvents: [AppModel.AgentEvent] = []

        let retrieved = await retrieval(for: userText)
        let stable = await context.stablePrefix(mode: mode, todos: []) + "\n\n" + compactToolContract

        for step in 1...maxSteps {
            if cancelled { throw AgentError.cancelled }

            let state = await context.dynamicState(todos: todos)
            let recallQuery = [userText, toolTail].filter { !$0.isEmpty }.joined(separator: " ")
            let recalled = await context.recall(recallQuery, maxCharacters: 4_600)
            let hot = await context.prepareConversation(
                messages: conversation,
                retrieved: step == 1 ? retrieved : "",
                recalled: recalled,
                toolTail: toolTail
            )
            let prompt = stable + "\n\n" + state + "\n\n" + hot + "\n\nContinue the task. If complete, call finish."

            let modelStream = try await runtime.stream(prompt: prompt, maxTokens: mode == .plan ? 650 : 850)
            var response = ""
            var latest = AppModel.RuntimeMetrics()

            for try await event in modelStream {
                if cancelled { throw AgentError.cancelled }
                switch event {
                case .text(let chunk):
                    response += chunk
                case .metrics(let metrics):
                    latest.tokensPerSecond = metrics.tokensPerSecond
                    latest.timeToFirstTokenMS = metrics.timeToFirstTokenMS
                    latest.outputTokens = metrics.outputTokens
                    latest.promptTokens = metrics.promptTokens
                    latest.cachedPrefixTokens = metrics.cachedPrefixTokens
                    latest.contextTokens = await context.estimateTokens(prompt)
                    latest.contextBudget = metrics.contextCapacity
                    latest.memoryMB = metrics.residentMemoryMB
                    latest.thermal = thermalName()
                    latest.backend = metrics.backend
                    continuation.yield(.metrics(latest))
                }
            }

            let parsed: ToolCall?
            do {
                parsed = try parseTool(response)
            } catch {
                let warning = AppModel.AgentEvent(
                    kind: .warning,
                    title: "Tool call repaired",
                    detail: "The model emitted malformed tool syntax. TriInfer kept the run alive and requested one clean tool call."
                )
                allEvents.append(warning)
                continuation.yield(.event(warning))
                toolTail = "Your last tool envelope was malformed. Emit exactly one valid <tool_call>{...}</tool_call> and no surrounding prose."
                conversation.append(.init(role: .system, text: toolTail))
                continue
            }

            if let call = parsed {
                let signature = normalizedSignature(call)
                signatures[signature, default: 0] += 1
                if signatures[signature, default: 0] >= 4 { throw AgentError.repeatedLoop }

                if call.name == "finish" {
                    let final = call.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let final, !final.isEmpty { continuation.yield(.text(final)) }
                    let event = AppModel.AgentEvent(
                        kind: .success,
                        title: "Run complete",
                        detail: "Finished after \(step) agent step\(step == 1 ? "" : "s")."
                    )
                    continuation.yield(.event(event))
                    return
                }

                let result = try await execute(call, mode: mode, todos: &todos)
                let paths = [call.path, call.destination].compactMap { $0 }
                let memoryID = (try? await context.archive(
                    kind: "tool",
                    title: "\(call.name) result",
                    body: result,
                    paths: paths,
                    importance: isMutation(call.name) ? 2 : 1
                )) ?? ""
                toolTail = compactToolResult(result, call: call, memoryID: memoryID)

                let toolEvent = AppModel.AgentEvent(
                    kind: .tool,
                    title: call.name,
                    detail: toolTail
                )
                allEvents.append(toolEvent)
                continuation.yield(.event(toolEvent))
                continuation.yield(.todos(todos))
                conversation.append(.init(
                    role: .system,
                    text: "TOOL_RESULT \(memoryID.isEmpty ? "" : "[\(memoryID)] ")\(toolTail)"
                ))

                if step % 8 == 0 {
                    try await context.compact(messages: conversation, toolEvents: allEvents)
                    let compact = AppModel.AgentEvent(
                        kind: .memory,
                        title: "Experience memory compacted",
                        detail: "Old observations left the hot KV context; exact evidence remains indexed by memory ID."
                    )
                    allEvents.append(compact)
                    continuation.yield(.event(compact))
                }

                let checkpoint = AppModel.AgentEvent(
                    kind: .checkpoint,
                    title: "Checkpoint \(step)",
                    detail: "Agent/task state persisted after the tool step."
                )
                allEvents.append(checkpoint)
                continuation.yield(.event(checkpoint))
                continue
            }

            let clean = stripToolEnvelope(response).trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                _ = try? await context.archive(
                    kind: "assistant",
                    title: "Agent response",
                    body: clean,
                    paths: [],
                    importance: 1
                )
                for chunk in chunkForUI(clean) { continuation.yield(.text(chunk)) }
                return
            }

            toolTail = "No actionable output was produced. Inspect state and either use one tool or call finish."
        }

        throw AgentError.stepLimit
    }

    private var compactToolContract: String {
        """
        TOOLS — at most one per model turn:
        read {path}; search {query}; recall {query}; memory_read {id}; write {path,content}; patch {path,old,replacement}; mkdir {path}; delete {path}; move {path,destination}; undo {}; todo {title,state}; remember {text,source}; finish {reason}.
        Tool syntax: <tool_call>{\"name\":\"read\",\"path\":\"src/main.js\"}</tool_call>
        When using a tool emit only the envelope, no prose. Read/search/recall before guessing. Use project-root-relative paths. Prefer exact patch for small changes. Keep files modular and testable.
        """
    }

    private func retrieval(for userText: String) async -> String {
        var sections: [String] = []
        if let entries = try? await workspace.entries() {
            let paths = entries.prefix(80).map { ($0.isDirectory ? "[dir] " : "") + $0.relativePath }
            sections.append("PROJECT TREE\n" + paths.joined(separator: "\n"))
        }

        let words = userText.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 }
            .uniqued()
            .prefix(6)

        for word in words {
            if let hits = try? await workspace.search(word, maxHits: 7), !hits.isEmpty {
                sections.append("MATCHES ‘\(word)’\n" + hits.map {
                    "\($0.path):\($0.line) \($0.text)"
                }.joined(separator: "\n"))
            }
        }
        return sections.joined(separator: "\n\n")
    }

    private func execute(
        _ call: ToolCall,
        mode: AppModel.AgentMode,
        todos: inout [AppModel.Todo]
    ) async throws -> String {
        if mode == .plan && isMutation(call.name) { throw AgentError.planMutation(call.name) }

        switch call.name {
        case "read":
            return try await workspace.read(require(call.path))
        case "search":
            let hits = try await workspace.search(require(call.query), maxHits: 36)
            return hits.isEmpty ? "No matches." : hits.map {
                "\($0.path):\($0.line) \($0.text)"
            }.joined(separator: "\n")
        case "recall":
            let query = try require(call.query)
            let result = await context.recall(query, maxCharacters: 7_000)
            return result.isEmpty ? "No matching external memory." : result
        case "memory_read":
            let id = try require(call.id)
            return await context.readExperience(id) ?? "Memory ID not found."
        case "write":
            let path = try require(call.path)
            try await workspace.write(path, content: require(call.content))
            return "Wrote \(path)."
        case "patch":
            let path = try require(call.path)
            try await workspace.patch(path, exact: require(call.old), replacement: require(call.replacement))
            return "Patched \(path) by one exact match."
        case "mkdir":
            let path = try require(call.path)
            try await workspace.makeDirectory(path)
            return "Created \(path)."
        case "delete":
            let path = try require(call.path)
            try await workspace.delete(path)
            return "Deleted \(path)."
        case "move":
            let path = try require(call.path)
            let destination = try require(call.destination)
            try await workspace.move(path, to: destination)
            return "Moved \(path) → \(destination)."
        case "undo":
            return try await workspace.undo()
        case "todo":
            let title = try require(call.title)
            let state = AppModel.Todo.State(rawValue: call.state ?? "pending") ?? .pending
            if let index = todos.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                todos[index].state = state
            } else {
                todos.append(.init(title: title, state: state))
            }
            return "TODO ‘\(title)’ is \(state.rawValue)."
        case "remember":
            try await context.remember(require(call.text), source: call.source ?? "agent")
            return "Saved durable project memory."
        default:
            throw AgentError.malformedTool
        }
    }

    private func parseTool(_ text: String) throws -> ToolCall? {
        if let start = text.range(of: "<tool_call>") {
            let payload: String
            if let end = text.range(of: "</tool_call>", range: start.upperBound..<text.endIndex) {
                payload = String(text[start.upperBound..<end.lowerBound])
            } else {
                payload = String(text[start.upperBound...])
            }
            return try decodeToolJSON(payload)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && trimmed.contains("\"name\"") {
            return try decodeToolJSON(trimmed)
        }
        return nil
    }

    private func decodeToolJSON(_ raw: String) throws -> ToolCall {
        var payload = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.hasPrefix("```json") { payload.removeFirst(7) }
        if payload.hasPrefix("```") { payload.removeFirst(3) }
        if payload.hasSuffix("```") { payload.removeLast(3) }
        payload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = payload.firstIndex(of: "{"), let last = payload.lastIndex(of: "}") else {
            throw AgentError.malformedTool
        }
        let json = String(payload[first...last])
        guard let data = json.data(using: .utf8),
              let call = try? JSONDecoder().decode(ToolCall.self, from: data) else {
            throw AgentError.malformedTool
        }
        return call
    }

    private func normalizedSignature(_ call: ToolCall) -> String {
        [call.name, call.path, call.destination, call.query, call.id, call.old, call.title, call.state, call.text]
            .compactMap { $0 }
            .joined(separator: "|")
            .lowercased()
    }

    private func stripToolEnvelope(_ text: String) -> String {
        guard let start = text.range(of: "<tool_call>"),
              let end = text.range(of: "</tool_call>", range: start.upperBound..<text.endIndex) else {
            return text
        }
        var copy = text
        copy.removeSubrange(start.lowerBound..<end.upperBound)
        return copy
    }

    private func compactToolResult(_ result: String, call: ToolCall, memoryID: String) -> String {
        let previewLimit = call.name == "read" || call.name == "search" || call.name == "recall" ? 1_450 : 720
        let preview = result.count <= previewLimit ? result : String(result.prefix(previewLimit)) + "…"
        guard !memoryID.isEmpty else { return preview }
        return "[\(memoryID)] \(preview)\nFull result archived; use memory_read if exact old evidence is needed."
    }

    private func chunkForUI(_ text: String) -> [String] {
        var output: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 72, limitedBy: text.endIndex) ?? text.endIndex
            output.append(String(text[index..<end]))
            index = end
        }
        return output
    }

    private func isMutation(_ name: String) -> Bool {
        ["write", "patch", "mkdir", "delete", "move", "undo"].contains(name)
    }

    private func require(_ value: String?) throws -> String {
        guard let value, !value.isEmpty else { throw AgentError.malformedTool }
        return value
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
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
