import Foundation

actor SessionStore {
    struct Snapshot: Codable, Sendable {
        var messages: [AppModel.ChatMessage]
        var todos: [AppModel.Todo]
        var events: [AppModel.AgentEvent]
        var mode: AppModel.AgentMode
        var updated: Date
    }

    struct HistoryItem: Identifiable, Codable, Sendable, Hashable {
        var id: String
        var title: String
        var updated: Date
        var messageCount: Int
        var todoCount: Int
    }

    private var directory: URL?
    private var currentURL: URL?

    func bootstrap() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        currentURL = dir.appendingPathComponent("current.json")
    }

    func restore() -> Snapshot? {
        guard let currentURL, let data = try? Data(contentsOf: currentURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func restoreHistory(_ id: String) -> Snapshot? {
        guard let directory else { return nil }
        let safe = URL(fileURLWithPath: id).lastPathComponent
        guard safe == id else { return nil }
        let url = directory.appendingPathComponent(safe)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(
        messages: [AppModel.ChatMessage],
        todos: [AppModel.Todo],
        events: [AppModel.AgentEvent],
        mode: AppModel.AgentMode
    ) throws {
        guard let currentURL else { return }
        let snapshot = makeSnapshot(messages: messages, todos: todos, events: events, mode: mode)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: currentURL, options: .atomic)
    }

    func checkpoint(
        title: String,
        messages: [AppModel.ChatMessage],
        todos: [AppModel.Todo],
        events: [AppModel.AgentEvent],
        mode: AppModel.AgentMode
    ) throws {
        guard let directory else { return }
        let clean = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let short = String(clean.prefix(42))
        let filename = "\(Int(Date().timeIntervalSince1970))-\(short)-\(UUID().uuidString.prefix(8)).json"
        let snapshot = makeSnapshot(messages: messages, todos: todos, events: events, mode: mode)
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent(filename), options: .atomic)
        try prune()
    }

    func history() -> [HistoryItem] {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        return urls
            .filter { $0.lastPathComponent != "current.json" && $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
                let userTitle = snapshot.messages.last(where: { $0.role == .user })?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = userTitle?.isEmpty == false ? String(userTitle!.prefix(72)) : "Agent checkpoint"
                return HistoryItem(
                    id: url.lastPathComponent,
                    title: title,
                    updated: snapshot.updated,
                    messageCount: snapshot.messages.count,
                    todoCount: snapshot.todos.filter { $0.state != .done }.count
                )
            }
            .sorted { $0.updated > $1.updated }
    }

    func deleteHistory(_ id: String) {
        guard let directory else { return }
        let safe = URL(fileURLWithPath: id).lastPathComponent
        guard safe == id else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(safe))
    }

    func clearCurrent() {
        if let currentURL { try? FileManager.default.removeItem(at: currentURL) }
    }

    private func makeSnapshot(
        messages: [AppModel.ChatMessage],
        todos: [AppModel.Todo],
        events: [AppModel.AgentEvent],
        mode: AppModel.AgentMode
    ) -> Snapshot {
        Snapshot(
            messages: Array(messages.suffix(80)),
            todos: todos,
            events: Array(events.suffix(160)),
            mode: mode,
            updated: Date()
        )
    }

    private func prune() throws {
        guard let directory else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent != "current.json" && $0.pathExtension == "json" }

        let dated: [(URL, Date)] = urls.map { url in
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (url, date ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(40) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
