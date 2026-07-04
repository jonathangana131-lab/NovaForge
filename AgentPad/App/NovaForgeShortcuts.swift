//
//  NovaForgeShortcuts.swift
//  NovaForge
//
//  Siri / Shortcuts surface: open any workspace tab by voice and hand
//  NovaForge a prompt from anywhere. Intents run in-process (openAppWhenRun)
//  and hand off through NotificationCenter so AppRootView / ChatView react
//  without new global state.
//

import AppIntents
import Foundation

// MARK: - Intent → app handoff

enum NovaForgeIntentSignal {
    static let openTab = Notification.Name("NovaForgeIntentOpenTab")
    static let askPrompt = Notification.Name("NovaForgeIntentAskPrompt")
    static let tabKey = "tab"
    static let promptKey = "prompt"
}

// MARK: - Tab vocabulary

enum NovaForgeTab: String, AppEnum {
    // The four-tab architecture. Legacy five-tab raw values stay decodable
    // so previously saved shortcuts keep working — AppRootView's resolver
    // routes both vocabularies onto the new tabs.
    case forge, workspace, history, control
    case project, files, chat, runs, settings

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "NovaForge Tab")

    static let caseDisplayRepresentations: [NovaForgeTab: DisplayRepresentation] = [
        .forge: DisplayRepresentation(title: "Forge", image: .init(systemName: "sparkles")),
        .workspace: DisplayRepresentation(title: "Workspace", image: .init(systemName: "folder.fill")),
        .history: DisplayRepresentation(title: "History", image: .init(systemName: "waveform.path.ecg")),
        .control: DisplayRepresentation(title: "Control", image: .init(systemName: "slider.horizontal.3")),
        .project: DisplayRepresentation(title: "Project (opens Forge)", image: .init(systemName: "scope")),
        .files: DisplayRepresentation(title: "Files (opens Workspace)", image: .init(systemName: "folder.fill")),
        .chat: DisplayRepresentation(title: "Chat (opens Forge)", image: .init(systemName: "sparkles")),
        .runs: DisplayRepresentation(title: "Runs (opens History)", image: .init(systemName: "waveform.path.ecg")),
        .settings: DisplayRepresentation(title: "Settings (opens Control)", image: .init(systemName: "gearshape.fill"))
    ]
}

// MARK: - Intents

struct OpenNovaForgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Open NovaForge"
    static let description = IntentDescription("Open NovaForge to the chat workspace.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: NovaForgeIntentSignal.openTab,
            object: nil,
            userInfo: [NovaForgeIntentSignal.tabKey: NovaForgeTab.forge.rawValue]
        )
        return .result()
    }
}

struct OpenNovaForgeTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Open NovaForge Tab"
    static let description = IntentDescription("Jump straight to a NovaForge workspace tab.")
    static let openAppWhenRun = true

    @Parameter(title: "Tab", default: .forge)
    var tab: NovaForgeTab

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$tab) in NovaForge")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: NovaForgeIntentSignal.openTab,
            object: nil,
            userInfo: [NovaForgeIntentSignal.tabKey: tab.rawValue]
        )
        return .result()
    }
}

struct AskNovaForgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask NovaForge"
    static let description = IntentDescription("Open the chat composer with your prompt ready to send.")
    static let openAppWhenRun = true

    @Parameter(title: "Prompt")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask NovaForge \(\.$prompt)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: NovaForgeIntentSignal.askPrompt,
            object: nil,
            userInfo: [NovaForgeIntentSignal.promptKey: prompt]
        )
        return .result()
    }
}

// MARK: - Shortcuts catalog

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
        AppShortcut(
            intent: OpenNovaForgeTabIntent(),
            phrases: [
                "Open a tab in \(.applicationName)",
                "Show my \(.applicationName) project",
                "Show runs in \(.applicationName)"
            ],
            shortTitle: "Open Tab",
            systemImageName: "square.grid.2x2.fill"
        )
        AppShortcut(
            intent: AskNovaForgeIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Tell \(.applicationName) to build something"
            ],
            shortTitle: "Ask NovaForge",
            systemImageName: "text.bubble.fill"
        )
    }
}
