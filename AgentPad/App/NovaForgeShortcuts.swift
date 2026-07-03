import AppIntents

struct OpenNovaForgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open NovaForge"
    static let description = IntentDescription("Open NovaForge to the chat workspace.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct NovaForgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNovaForgeIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Start \(.applicationName)",
                "Open chat in \(.applicationName)"
            ],
            shortTitle: "Open NovaForge",
            systemImageName: "sparkles"
        )
    }
}
