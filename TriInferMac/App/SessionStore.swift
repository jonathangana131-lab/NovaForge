import Foundation

actor SessionStore {
    struct Snapshot: Codable, Sendable {
        var messages: [AppModel.ChatMessage]
        var todos: [AppModel.Todo]
        var events: [AppModel.AgentEvent]
        var mode: AppModel.AgentMode
        var updated: Date
    }

    struct HistoryItem: Identifiable, Codable, Sendable {
        var id: UUID
        var title: String
        var updated: Date
        var messageCount: Int
    }

    private var directory: URL?
    private var currentURL: URL?

    func bootstrap() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        currentURL = dir.appendingPathComponent("current.json")
    }

    func restore() -> Snapshot? {
        guard let currentURL, let data = try? Data(contentsOf: currentURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(messages: [AppModel.ChatMessage], todos: [AppModel.Todo], events: [AppModel.AgentEvent], mode: AppModel.AgentMode) throws {
        guard let currentURL else { return }
        let snapshot = Snapshot(messages: Array(messages.suffix(80)), todos: todos, events: Array(events.suffix(160)), mode: mode, updated: Date())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: currentURL, options: .atomic)
    }

    func checkpoint(title: String, messages: [AppModel.ChatMessage], todos: [AppModel.Todo], events: [AppModel.AgentEvent], mode: AppModel.AgentMode) throws {
        guard let directory else { return }
        let id = UUID()
        let snapshot = Snapshot(messages: Array(messages.suffix(80)), todos: todos, events: Array(events.suffix(160)), mode: mode, updated: Date())
        let safe = title.replacingOccurrences(of: "/", with: "-").prefix(48)
        let url = directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(safe)-\(id.uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        try prune()
    }

    func history() -> [HistoryItem] {
        guard let directory, let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.lastPathComponent != "current.json" && $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
            return HistoryItem(id: UUID(), title: url.deletingPathExtension().lastPathComponent, updated: snapshot.updated, messageCount: snapshot.messages.count)
        }.sorted { $0.updated > $1.updated }
    }

    func clearCurrent() throws {
        if let currentURL { try? FileManager.default.removeItem(at: currentURL) }
    }

    private func prune() throws {
        guard let directory else { return }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]).filter { $0.lastPathComponent != "current.json" && $0.pathExtension == "json" }
        let sorted = urls.sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        for old in sorted.dropFirst(30) { try? FileManager.default.removeItem(at: old) }
    }
}
