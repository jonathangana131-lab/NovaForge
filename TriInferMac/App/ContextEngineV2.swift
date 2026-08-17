import Foundation

/// Long-horizon context manager inspired by 2026 external-experience memory systems: the hot
/// model prompt stays small while full-fidelity observations live in an indexed local store.
actor ContextEngine {
    struct Fact: Codable, Hashable, Sendable, Identifiable {
        var id = UUID()
        var text: String
        var source: String
        var timestamp = Date()
    }

    struct Experience: Codable, Hashable, Sendable, Identifiable {
        var id: String
        var kind: String
        var title: String
        var body: String
        var paths: [String]
        var keywords: [String]
        var importance: Int
        var timestamp: Date
        var fingerprint: String
    }

    struct Snapshot: Codable, Hashable, Sendable {
        var summary: String
        var facts: [Fact]
        var compressedTurns: Int
        var estimatedTokens: Int
        var cachedPrefixEstimate: Int
        var lastCompaction: Date?
        var experienceCount: Int
        var externalMemoryBytes: Int
        var recentExperiences: [Experience]
    }

    private struct Persisted: Codable {
        var summary = ""
        var facts: [Fact] = []
        var experiences: [Experience] = []
        var compressedTurns = 0
        var lastCompaction: Date?
    }

    private var state = Persisted()
    private var url: URL?
    private let hotBudget = 1_520
    private let summaryBudget = 520
    private let maxExperiences = 520

    func bootstrap() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("AgentState", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("context-v3.json")
        if let url,
           let data = try? Data(contentsOf: url),
           let restored = try? JSONDecoder().decode(Persisted.self, from: data) {
            state = restored
        }
    }

    func remember(_ text: String, source: String) throws {
        let clean = normalized(text)
        guard !clean.isEmpty else { return }
        if let index = state.facts.firstIndex(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) {
            state.facts[index].source = source
            state.facts[index].timestamp = Date()
        } else {
            state.facts.append(.init(text: clean, source: source))
        }
        if state.facts.count > 64 { state.facts.removeFirst(state.facts.count - 64) }
        try persist()
    }

    /// Archives the complete observation and returns a stable short ID. The caller can put only the
    /// ID + tiny preview in the model prompt and recall the full evidence later.
    @discardableResult
    func archive(
        kind: String,
        title: String,
        body: String,
        paths: [String] = [],
        importance: Int = 1
    ) throws -> String {
        let cleanBody = normalized(body)
        guard !cleanBody.isEmpty else { return "" }
        let fingerprint = stableHash(kind + "|" + title + "|" + cleanBody)
        if let existing = state.experiences.first(where: { $0.fingerprint == fingerprint }) {
            return existing.id
        }
        let item = Experience(
            id: "E" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9),
            kind: kind,
            title: normalized(title),
            body: cleanBody,
            paths: Array(Set(paths.filter { !$0.isEmpty })).sorted(),
            keywords: keywords(in: title + " " + cleanBody + " " + paths.joined(separator: " ")),
            importance: Swift.max(0, Swift.min(5, importance)),
            timestamp: Date(),
            fingerprint: fingerprint
        )
        state.experiences.append(item)
        pruneExperiences()
        try persist()
        return item.id
    }

    /// Lightweight lexical retrieval is intentionally deterministic and local. It avoids another
    /// expensive 27B inference just to decide what context the 27B model should see.
    func recall(_ query: String, maxCharacters: Int = 5_200) -> String {
        let terms = keywords(in: query)
        let ranked = state.experiences.map { item -> (Experience, Int) in
            let haystack = (item.title + " " + item.body + " " + item.paths.joined(separator: " ")).lowercased()
            var score = item.importance * 2
            for term in terms where haystack.contains(term) { score += 12 }
            for term in terms where item.title.lowercased().contains(term) { score += 6 }
            if item.paths.contains(where: { path in terms.contains(where: { path.lowercased().contains($0) }) }) { score += 8 }
            return (item, score)
        }
        .filter { terms.isEmpty ? true : $0.1 > 0 }
        .sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.timestamp > $1.0.timestamp
        }
        .prefix(6)

        var output = ""
        for (item, _) in ranked {
            let pathText = item.paths.isEmpty ? "" : " [" + item.paths.joined(separator: ", ") + "]"
            let block = "[\(item.id)] \(item.title)\(pathText)\n" + trim(item.body, chars: 1_700)
            if !output.isEmpty { output += "\n\n" }
            if output.count + block.count > maxCharacters {
                let remaining = Swift.max(0, maxCharacters - output.count)
                output += String(block.prefix(remaining))
                break
            }
            output += block
        }
        return output
    }

    func readExperience(_ id: String) -> String? {
        guard let item = state.experiences.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else { return nil }
        let paths = item.paths.isEmpty ? "" : "\nPaths: " + item.paths.joined(separator: ", ")
        return "[\(item.id)] \(item.title)\(paths)\n\(item.body)"
    }

    // This block is deliberately tiny and nearly immutable so llama.cpp can retain a long common KV prefix.
    func stablePrefix(mode: AppModel.AgentMode, todos: [AppModel.Todo]) -> String {
        let permission = mode == .build
            ? "BUILD: workspace mutation is allowed only through sandboxed tools."
            : "PLAN: workspace mutation is forbidden; inspect/search/recall only."
        return """
        You are TriInfer, a fast local coding agent. Do concrete work through tools and keep chat concise. Keep projects modular: folders, modules, assets, tests; never collapse a real project into one giant file. Inspect before editing. Stop when complete or blocked.
        \(permission)
        Workspace paths are project-root relative. Never reveal internal tool JSON. Never invent tool results. Files, TODOs, facts, checkpoints, and indexed experience memory are authoritative over old chat prose.
        """
    }

    func dynamicState(todos: [AppModel.Todo]) -> String {
        let active = todos.filter { $0.state != .done }.prefix(9).map { "- [\($0.state.rawValue)] \($0.title)" }.joined(separator: "\n")
        let facts = state.facts.suffix(16).map { "- \($0.text) [\($0.source)]" }.joined(separator: "\n")
        let refs = state.experiences.suffix(10).reversed().map { "- [\($0.id)] \($0.title)" }.joined(separator: "\n")
        return """
        CURRENT TODO STATE
        \(active.isEmpty ? "- No active TODOs." : active)

        PINNED PROJECT FACTS
        \(facts.isEmpty ? "- None pinned." : facts)

        COMPACTED WORKING SUMMARY
        \(state.summary.isEmpty ? "No compacted history yet." : state.summary)

        RECENT EXTERNAL MEMORY IDS
        \(refs.isEmpty ? "- None yet." : refs)
        """
    }

    func prepareConversation(
        messages: [AppModel.ChatMessage],
        retrieved: String,
        recalled: String,
        toolTail: String
    ) -> String {
        let recent = messages.suffix(7).map { message in
            let role = message.role == .user ? "USER" : message.role == .assistant ? "ASSISTANT" : "SYSTEM"
            return "\(role): \(trim(message.text, chars: 2_600))"
        }.joined(separator: "\n\n")

        var pieces: [String] = []
        if !retrieved.isEmpty { pieces.append("RELEVANT WORKSPACE SLICES\n" + trim(retrieved, chars: 6_600)) }
        if !recalled.isEmpty { pieces.append("RECALLED EXACT EXPERIENCE\n" + trim(recalled, chars: 5_200)) }
        if !recent.isEmpty { pieces.append("RECENT CONVERSATION\n" + recent) }
        if !toolTail.isEmpty { pieces.append("LATEST TOOL RESULT\n" + trim(toolTail, chars: 1_700)) }
        return trimToTokens(pieces.joined(separator: "\n\n"), maxTokens: hotBudget)
    }

    func compact(messages: [AppModel.ChatMessage], toolEvents: [AppModel.AgentEvent]) throws {
        guard messages.count > 10 else { return }
        let older = Array(messages.dropLast(7))

        // Preserve full-fidelity old turns outside the prompt before shrinking their representation.
        for message in older.suffix(16) {
            let role = message.role == .user ? "User request" : message.role == .assistant ? "Agent response" : "System observation"
            _ = try archiveWithoutPersist(kind: "conversation", title: role, body: message.text, paths: [], importance: message.role == .user ? 2 : 1)
        }
        for event in toolEvents.suffix(14) where event.kind != .thinking {
            _ = try archiveWithoutPersist(kind: "event", title: event.title, body: event.detail, paths: [], importance: event.kind == .success || event.kind == .checkpoint ? 2 : 1)
        }

        let goals = older.filter { $0.role == .user }.suffix(4).map { trim($0.text, chars: 360) }
        let outcomes = older.filter { $0.role == .assistant }.suffix(4).map { trim($0.text, chars: 420) }
        let verified = toolEvents.filter { [.checkpoint, .memory, .success, .warning].contains($0.kind) }.suffix(6).map { "\($0.title): \($0.detail)" }
        let summary = """
        Prior goals:
        \(goals.map { "- \($0)" }.joined(separator: "\n"))
        Verified outcomes / decisions:
        \(outcomes.map { "- \($0)" }.joined(separator: "\n"))
        Recent checkpoints:
        \(verified.map { "- \($0)" }.joined(separator: "\n"))
        """
        state.summary = trimToTokens(summary, maxTokens: summaryBudget)
        state.compressedTurns += older.count
        state.lastCompaction = Date()
        pruneExperiences()
        try persist()
    }

    func snapshot(messages: [AppModel.ChatMessage]) -> Snapshot {
        let prefix = stablePrefix(mode: .build, todos: [])
        let bytes = (try? JSONEncoder().encode(state.experiences).count) ?? 0
        return .init(
            summary: state.summary,
            facts: state.facts,
            compressedTurns: state.compressedTurns,
            estimatedTokens: estimateTokens(messages.map(\.text).joined(separator: "\n")),
            cachedPrefixEstimate: estimateTokens(prefix),
            lastCompaction: state.lastCompaction,
            experienceCount: state.experiences.count,
            externalMemoryBytes: bytes,
            recentExperiences: Array(state.experiences.suffix(8).reversed())
        )
    }

    func resetConversation() throws {
        state.summary = ""
        state.compressedTurns = 0
        state.lastCompaction = nil
        try persist()
    }

    func estimateTokens(_ text: String) -> Int { Swift.max(1, text.utf8.count / 4) }

    private func archiveWithoutPersist(kind: String, title: String, body: String, paths: [String], importance: Int) throws -> String {
        let cleanBody = normalized(body)
        guard !cleanBody.isEmpty else { return "" }
        let fingerprint = stableHash(kind + "|" + title + "|" + cleanBody)
        if let existing = state.experiences.first(where: { $0.fingerprint == fingerprint }) { return existing.id }
        let item = Experience(
            id: "E" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(9),
            kind: kind,
            title: normalized(title),
            body: cleanBody,
            paths: Array(Set(paths.filter { !$0.isEmpty })).sorted(),
            keywords: keywords(in: title + " " + cleanBody),
            importance: Swift.max(0, Swift.min(5, importance)),
            timestamp: Date(),
            fingerprint: fingerprint
        )
        state.experiences.append(item)
        return item.id
    }

    private func pruneExperiences() {
        guard state.experiences.count > maxExperiences else { return }
        // Keep high-importance evidence plus recent evidence; remove oldest low-value records first.
        state.experiences.sort {
            if $0.importance != $1.importance { return $0.importance < $1.importance }
            return $0.timestamp < $1.timestamp
        }
        state.experiences.removeFirst(state.experiences.count - maxExperiences)
        state.experiences.sort { $0.timestamp < $1.timestamp }
    }

    private func keywords(in text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .map(String.init)
            .filter { $0.count >= 3 && seen.insert($0).inserted }
            .prefix(40)
            .map { $0 }
    }

    private func trimToTokens(_ text: String, maxTokens: Int) -> String {
        let maxChars = maxTokens * 4
        guard text.utf8.count > maxChars else { return text }
        return trim(text, chars: maxChars) + "\n[…hot context elided; exact evidence remains recallable by memory ID…]"
    }

    private func trim(_ text: String, chars: Int) -> String {
        text.count <= chars ? text : String(text.prefix(chars)) + "…"
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private func persist() throws {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
