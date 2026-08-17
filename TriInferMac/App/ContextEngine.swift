import Foundation

actor ContextEngine {
    struct Fact: Codable, Hashable, Sendable, Identifiable {
        var id = UUID()
        var text: String
        var source: String
        var timestamp = Date()
    }

    struct Snapshot: Codable, Hashable, Sendable {
        var summary: String
        var facts: [Fact]
        var compressedTurns: Int
        var estimatedTokens: Int
        var cachedPrefixEstimate: Int
        var lastCompaction: Date?
    }

    private struct Persisted: Codable {
        var summary = ""
        var facts: [Fact] = []
        var compressedTurns = 0
        var lastCompaction: Date?
    }

    private var state = Persisted()
    private var url: URL?
    private let hotBudget = 2_600
    private let stablePrefixBudget = 900

    func bootstrap() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("AgentState", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("context.json")
        if let url, let data = try? Data(contentsOf: url), let restored = try? JSONDecoder().decode(Persisted.self, from: data) {
            state = restored
        }
    }

    func remember(_ text: String, source: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if !state.facts.contains(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) {
            state.facts.append(.init(text: clean, source: source))
            if state.facts.count > 48 { state.facts.removeFirst(state.facts.count - 48) }
            try persist()
        }
    }

    func stablePrefix(mode: AppModel.AgentMode, todos: [AppModel.Todo]) -> String {
        let permission = mode == .build
            ? "BUILD mode: may inspect and mutate only the selected sandboxed workspace through tools."
            : "PLAN mode: inspect/search only; do not mutate workspace files."
        let active = todos.filter { $0.state != .done }.prefix(8).map { "- [\($0.state.rawValue)] \($0.title)" }.joined(separator: "\n")
        let facts = state.facts.suffix(18).map { "- \($0.text) [\($0.source)]" }.joined(separator: "\n")
        let summary = state.summary.isEmpty ? "No compacted history yet." : state.summary
        return """
        You are TriInfer, a fast local coding agent. Be concise in chat and do work through tools. Keep projects modular; never collapse a multi-file project into one giant file. Stop when the task is complete or blocked.
        \(permission)
        Tool calls must be exactly one JSON object inside <tool_call>...</tool_call>. Never show tool JSON to the user.

        GOALS/TODOS
        \(active.isEmpty ? "- No active TODOs." : active)

        DURABLE PROJECT FACTS
        \(facts.isEmpty ? "- None yet." : facts)

        COMPACTED HISTORY
        \(summary)
        """
    }

    func prepareConversation(messages: [AppModel.ChatMessage], retrieved: String, toolTail: String) -> String {
        let recent = messages.suffix(10).map { message in
            let role = message.role == .user ? "USER" : message.role == .assistant ? "ASSISTANT" : "SYSTEM"
            return "\(role): \(trim(message.text, chars: 4_500))"
        }.joined(separator: "\n\n")
        var block = """
        RELEVANT WORKSPACE RETRIEVAL
        \(retrieved.isEmpty ? "No project slices retrieved." : trim(retrieved, chars: 12_000))

        RECENT CONVERSATION
        \(recent)
        """
        if !toolTail.isEmpty { block += "\n\nRECENT TOOL RESULTS\n" + trim(toolTail, chars: 5_000) }
        return trimToEstimatedTokens(block, maxTokens: hotBudget)
    }

    func compact(messages: [AppModel.ChatMessage], toolEvents: [AppModel.AgentEvent]) throws {
        guard messages.count > 12 else { return }
        let older = messages.dropLast(8)
        let userGoals = older.filter { $0.role == .user }.suffix(6).map { trim($0.text, chars: 480) }
        let assistantOutcomes = older.filter { $0.role == .assistant }.suffix(6).map { trim($0.text, chars: 620) }
        let noteworthy = toolEvents.filter { [.checkpoint, .memory, .success, .warning].contains($0.kind) }.suffix(8).map { "\($0.title): \($0.detail)" }
        state.summary = trim("""
        Prior user goals:
        \(userGoals.map { "- \($0)" }.joined(separator: "\n"))
        Prior completed/outcome notes:
        \(assistantOutcomes.map { "- \($0)" }.joined(separator: "\n"))
        Verified agent events:
        \(noteworthy.map { "- \($0)" }.joined(separator: "\n"))
        """, chars: stablePrefixBudget * 4)
        state.compressedTurns += older.count
        state.lastCompaction = Date()
        try persist()
    }

    func snapshot(messages: [AppModel.ChatMessage]) -> Snapshot {
        let prefix = stablePrefix(mode: .build, todos: [])
        return .init(summary: state.summary, facts: state.facts, compressedTurns: state.compressedTurns, estimatedTokens: estimateTokens(messages.map(\.text).joined(separator: "\n")), cachedPrefixEstimate: estimateTokens(prefix), lastCompaction: state.lastCompaction)
    }

    func resetConversation() throws {
        state.summary = ""
        state.compressedTurns = 0
        state.lastCompaction = nil
        try persist()
    }

    func estimateTokens(_ text: String) -> Int { max(1, text.utf8.count / 4) }

    private func trimToEstimatedTokens(_ text: String, maxTokens: Int) -> String {
        let maxBytes = maxTokens * 4
        guard text.utf8.count > maxBytes else { return text }
        return trim(text, chars: maxBytes) + "\n[…context elided; authoritative state remains in workspace/memory…]"
    }

    private func trim(_ text: String, chars: Int) -> String {
        guard text.count > chars else { return text }
        return String(text.prefix(chars)) + "…"
    }

    private func persist() throws {
        guard let url else { return }
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }
}
