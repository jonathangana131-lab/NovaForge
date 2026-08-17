import Foundation

actor ContextEngine {
    struct Fact: Codable, Hashable, Sendable, Identifiable { var id = UUID(); var text: String; var source: String; var timestamp = Date() }
    struct Snapshot: Codable, Hashable, Sendable { var summary: String; var facts: [Fact]; var compressedTurns: Int; var estimatedTokens: Int; var cachedPrefixEstimate: Int; var lastCompaction: Date? }
    private struct Persisted: Codable { var summary = ""; var facts: [Fact] = []; var compressedTurns = 0; var lastCompaction: Date? }
    private var state = Persisted(); private var url: URL?
    private let hotBudget = 1_600
    private let summaryBudget = 620

    func bootstrap() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("AgentState", isDirectory: true); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("context.json")
        if let url, let data = try? Data(contentsOf: url), let restored = try? JSONDecoder().decode(Persisted.self, from: data) { state = restored }
    }

    func remember(_ text: String, source: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        if !state.facts.contains(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) { state.facts.append(.init(text: clean, source: source)); if state.facts.count > 40 { state.facts.removeFirst(state.facts.count - 40) }; try persist() }
    }

    // This block intentionally changes very rarely so llama.cpp can reuse its KV prefix.
    func stablePrefix(mode: AppModel.AgentMode, todos: [AppModel.Todo]) -> String {
        let permission = mode == .build ? "BUILD mode: workspace mutation is allowed only through sandboxed tools." : "PLAN mode: workspace mutation is forbidden; inspect/search only."
        return """
        You are TriInfer, a fast local coding agent. Be concise in chat and do concrete work through tools. Keep real projects modular: separate files/folders/modules/assets instead of giant single files. Inspect before editing. Stop when complete or blocked.
        \(permission)
        Never reveal internal tool JSON. Never invent tool results. Treat workspace files and structured state as authoritative over old prose.
        """
    }

    func dynamicState(todos: [AppModel.Todo]) -> String {
        let active = todos.filter { $0.state != .done }.prefix(8).map { "- [\($0.state.rawValue)] \($0.title)" }.joined(separator: "\n")
        let facts = state.facts.suffix(14).map { "- \($0.text) [\($0.source)]" }.joined(separator: "\n")
        return """
        CURRENT GOALS / TODOS
        \(active.isEmpty ? "- No active TODOs." : active)

        DURABLE PROJECT FACTS
        \(facts.isEmpty ? "- None pinned." : facts)

        COMPACTED HISTORY
        \(state.summary.isEmpty ? "No compacted history yet." : state.summary)
        """
    }

    func prepareConversation(messages: [AppModel.ChatMessage], retrieved: String, toolTail: String) -> String {
        let recent = messages.suffix(8).map { m in "\(m.role == .user ? "USER" : m.role == .assistant ? "ASSISTANT" : "SYSTEM"): \(trim(m.text, chars: 3_200))" }.joined(separator: "\n\n")
        var block = "RELEVANT WORKSPACE SLICES\n\(retrieved.isEmpty ? "No project slices retrieved." : trim(retrieved, chars: 8_000))\n\nRECENT CONVERSATION\n\(recent)"
        if !toolTail.isEmpty { block += "\n\nLATEST TOOL RESULT\n" + trim(toolTail, chars: 4_000) }
        return trimToTokens(block, max: hotBudget)
    }

    func compact(messages: [AppModel.ChatMessage], toolEvents: [AppModel.AgentEvent]) throws {
        guard messages.count > 10 else { return }
        let older = messages.dropLast(7)
        let goals = older.filter { $0.role == .user }.suffix(5).map { trim($0.text, chars: 420) }
        let outcomes = older.filter { $0.role == .assistant }.suffix(5).map { trim($0.text, chars: 520) }
        let verified = toolEvents.filter { [.checkpoint, .memory, .success, .warning].contains($0.kind) }.suffix(7).map { "\($0.title): \($0.detail)" }
        let summary = "Prior goals:\n\(goals.map { "- \($0)" }.joined(separator: "\n"))\nVerified outcomes:\n\(outcomes.map { "- \($0)" }.joined(separator: "\n"))\nAgent checkpoints:\n\(verified.map { "- \($0)" }.joined(separator: "\n"))"
        state.summary = trimToTokens(summary, max: summaryBudget); state.compressedTurns += older.count; state.lastCompaction = Date(); try persist()
    }

    func snapshot(messages: [AppModel.ChatMessage]) -> Snapshot { let prefix = stablePrefix(mode: .build, todos: []); return .init(summary: state.summary, facts: state.facts, compressedTurns: state.compressedTurns, estimatedTokens: estimateTokens(messages.map(\.text).joined(separator: "\n")), cachedPrefixEstimate: estimateTokens(prefix), lastCompaction: state.lastCompaction) }
    func resetConversation() throws { state.summary = ""; state.compressedTurns = 0; state.lastCompaction = nil; try persist() }
    func estimateTokens(_ text: String) -> Int { max(1, text.utf8.count / 4) }
    private func trimToTokens(_ text: String, max: Int) -> String { let maxChars = max * 4; guard text.utf8.count > maxChars else { return text }; return trim(text, chars: maxChars) + "\n[…hot context elided; authoritative state stays in project memory/files…]" }
    private func trim(_ text: String, chars: Int) -> String { text.count <= chars ? text : String(text.prefix(chars)) + "…" }
    private func persist() throws { guard let url else { return }; try JSONEncoder().encode(state).write(to: url, options: .atomic) }
}
