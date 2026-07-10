import SwiftData
import SwiftUI
import UIKit

@MainActor
@main
struct NovaForgeMainApp: App {
    @UIApplicationDelegateAdaptor(NovaForgeAppDelegate.self) private var appDelegate
    let container: ModelContainer
    private static let safeStartTitle = LaunchConversationSelection.safeStartTitle
    @AppStorage(AgentTheme.storageKey) private var selectedThemeRawValue = AgentTheme.defaultTheme.rawValue

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if let launchTheme = AgentTheme.launchOverride(from: arguments) {
            UserDefaults.standard.set(launchTheme.rawValue, forKey: AgentTheme.storageKey)
            AgentPalette.refreshThemeCache(launchTheme)
        } else {
            AgentPalette.refreshThemeCache(AgentTheme.normalizeStoredTheme())
        }
        AgentThemeUIKit.apply(AgentTheme.current)
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let supportURL {
            try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        }

        let schema = Schema(versionedSchema: NovaForgeSchemaV1.self)

        let storeURL = supportURL?.appendingPathComponent("NovaForge.store") ?? FileManager.default.temporaryDirectory.appendingPathComponent("NovaForge.store")
        let config = ModelConfiguration(url: storeURL)

        #if DEBUG || targetEnvironment(simulator)
        if arguments.contains("--reset-ui") {
            Self.resetPersistentStore(at: supportURL)
            UserDefaults.standard.set(AgentTheme.defaultTheme.rawValue, forKey: AgentTheme.storageKey)
            if let launchTheme = AgentTheme.launchOverride(from: arguments) {
                UserDefaults.standard.set(launchTheme.rawValue, forKey: AgentTheme.storageKey)
            }
            AgentPalette.refreshThemeCache(AgentTheme.current)
            AgentThemeUIKit.apply(AgentTheme.current)
            UserDefaults.standard.removeObject(forKey: LaunchConversationSelection.persistedSelectionKey)
        }
        #endif

        container = Self.makeContainer(schema: schema, config: config, supportURL: supportURL)

        let context = container.mainContext
        var settingsFetch = FetchDescriptor<AgentSettings>()
        settingsFetch.fetchLimit = 1
        let existingSettings = try? context.fetch(settingsFetch)
        let settings: AgentSettings
        if let existing = existingSettings?.first {
            settings = existing
            if settings.provider == .openAI,
               settings.modelID == "gpt-5.5" {
                settings.provider = .local
                settings.modelID = AIProvider.local.defaultModel
                settings.updatedAt = Date()
            } else if settings.provider == .local,
                      let selectedVariant = LocalModelCatalog.variant(for: settings.modelID),
                      LocalModelCatalog.compatibilityMessage(for: selectedVariant) != nil {
                settings.modelID = LocalModelCatalog.defaultVariant.id
                settings.updatedAt = Date()
            }
        } else {
            let created = AgentSettings()
            context.insert(created)
            settings = created
        }

        let activeProject = ProjectBootstrap.ensureDefaultProject(in: context, settings: settings)

        let convsFetch = FetchDescriptor<Conversation>()
        let existingConvs = try? context.fetch(convsFetch)
        if existingConvs?.isEmpty ?? true {
            insertReadyConversation(in: context, project: activeProject)
        } else {
            normalizeConversationMetadata(existingConvs ?? [])
            ensureFreshLaunchConversation(in: context, project: activeProject)
        }

        PersistentLaunchRecovery.recoverInterruptedToolRuns(in: context)
        ProjectBootstrap.ensureDefaultProject(in: context, settings: settings)

        if Self.hasLaunchFlag("--stress-chat", in: arguments),
           let stressConversation = seedStressConversation(in: context, project: activeProject) {
            UserDefaults.standard.set(
                stressConversation.id.uuidString,
                forKey: LaunchConversationSelection.persistedSelectionKey
            )
        }
        #if DEBUG || targetEnvironment(simulator)
        if arguments.contains("--stress-tool-batch") {
            if let batchConversation = seedToolBatchConversation(in: context, project: activeProject) {
                UserDefaults.standard.set(
                    batchConversation.id.uuidString,
                    forKey: LaunchConversationSelection.persistedSelectionKey
                )
            }
        }
        if arguments.contains("--running-tool-call-demo") {
            if let runningConversation = seedRunningToolCallConversation(in: context, project: activeProject) {
                UserDefaults.standard.set(
                    runningConversation.id.uuidString,
                    forKey: LaunchConversationSelection.persistedSelectionKey
                )
            }
        }
        if arguments.contains("--failed-tool-call-demo") {
            if let failedConversation = seedFailedToolCallConversation(in: context, project: activeProject) {
                UserDefaults.standard.set(
                    failedConversation.id.uuidString,
                    forKey: LaunchConversationSelection.persistedSelectionKey
                )
            }
        }
        if arguments.contains("--code-block-demo") {
            if let codeBlockConversation = seedCodeBlockConversation(in: context, project: activeProject) {
                UserDefaults.standard.set(
                    codeBlockConversation.id.uuidString,
                    forKey: LaunchConversationSelection.persistedSelectionKey
                )
            }
        }
        #endif

        do {
            try context.save()
            ProjectBootstrap.markLegacyOwnershipMigrationComplete()
        } catch {
            // Leave the marker unset: a later launch can safely retry the
            // legacy ownership migration after storage recovers.
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .modelContainer(container)
                .agentThemeTypography(selectedTheme)
                .preferredColorScheme(selectedTheme.preferredColorScheme)
        }
    }

    private var selectedTheme: AgentTheme {
        AgentTheme.resolved(from: selectedThemeRawValue)
    }

    // MARK: - Static Helpers

    private static func hasLaunchFlag(_ flag: String, in arguments: [String]) -> Bool {
        arguments.contains(flag) ||
            arguments.joined(separator: " ").contains(flag) ||
            arguments.contains { argument in
                argument == flag ||
                    argument.hasPrefix("\(flag)=") ||
                    argument.split(whereSeparator: { $0.isWhitespace }).contains(Substring(flag))
            }
    }

    private static func makeContainer(
        schema: Schema,
        config: ModelConfiguration,
        supportURL: URL?
    ) -> ModelContainer {
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: NovaForgeSchemaMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            quarantinePersistentStore(at: supportURL, reason: error)
        }

        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: NovaForgeSchemaMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            assertionFailure("NovaForge SwiftData store could not be created after recovering the damaged store: \(error)")
        }

        do {
            let fallbackURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("NovaForge-Recovered-\(UUID().uuidString).store")
            return try ModelContainer(
                for: schema,
                migrationPlan: NovaForgeSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(url: fallbackURL)]
            )
        } catch {
            assertionFailure("NovaForge could not start a recovered SwiftData store on disk; falling back to an in-memory launch store: \(error)")
        }

        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: NovaForgeSchemaMigrationPlan.self,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
        } catch {
            fatalError("NovaForge could not start even with an in-memory SwiftData store: \(error)")
        }
    }

    private static func resetPersistentStore(at supportURL: URL?) {
        guard let supportURL else { return }
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: supportURL.appendingPathComponent("NovaForge.store\(suffix)"))
        }
    }

    private static func quarantinePersistentStore(at supportURL: URL?, reason: Error) {
        guard let supportURL else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let recoveryDirectory = supportURL.appendingPathComponent("RecoveredStores", isDirectory: true)
        try? FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)

        for suffix in ["", "-shm", "-wal"] {
            let source = supportURL.appendingPathComponent("NovaForge.store\(suffix)")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = recoveryDirectory.appendingPathComponent("NovaForge.store.\(stamp)\(suffix)")
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                try? FileManager.default.copyItem(at: source, to: destination)
                try? FileManager.default.removeItem(at: source)
            }
        }

        let note = """
        NovaForge recovered from a SwiftData open failure at \(Date()).
        Original error: \(reason)
        The damaged store files were moved here instead of being destructively deleted.
        """
        try? note.write(to: recoveryDirectory.appendingPathComponent("NovaForge.store.\(stamp).recovery.txt"), atomically: true, encoding: .utf8)
    }

    private static func configureTabBarAppearance() {
        AgentThemeUIKit.apply(AgentTheme.current)
    }

    // MARK: - Instance Helpers

    private func ensureFreshLaunchConversation(in context: ModelContext, project: Project) {
        let title = Self.safeStartTitle
        let descriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.title == title }
        )
        let readyConversations = (try? context.fetch(descriptor)) ?? []

        if let unusedReady = readyConversations.first(where: { !$0.hasUserMessages }) {
            unusedReady.project = nil
            for message in unusedReady.messages {
                context.delete(message)
            }
            unusedReady.messages.removeAll()
            unusedReady.refreshMessageMetadata(updateTimestamp: Date())
        } else {
            insertReadyConversation(in: context, project: project)
        }
    }

    private func normalizeConversationMetadata(_ conversations: [Conversation]) {
        for conversation in conversations {
            conversation.refreshMessageMetadata()
        }
    }

    private func insertReadyConversation(in context: ModelContext, project: Project) {
        let conversation = Conversation(title: Self.safeStartTitle, project: nil)
        context.insert(conversation)
        ProjectEventRecorder.record(
            project: nil,
            kind: .conversationStarted,
            title: "Launch conversation ready",
            detail: conversation.title,
            severity: .info,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: context
        )
    }

    @discardableResult
    private func seedStressConversation(in context: ModelContext, project: Project) -> Conversation? {
        let marker = "NovaForge Stress — 200 messages / 66 tools"
        let legacyMarker = "NovaForge Stress — 60 messages / 20 tools"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { conversation in
            conversation.title == marker || conversation.title == legacyMarker || conversation.title == "NovaForge Stress — 61 messages / 20 tools"
        })
        if let existing = try? context.fetch(descriptor).first {
            existing.title = marker
            existing.project = project
            ensureStressConversationHasLongHistory(existing, context: context)
            existing.refreshMessageMetadata(updateTimestamp: Date())
            seedStressToolRuns(in: context, project: project)
            return existing
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)
        ensureStressConversationHasLongHistory(conversation, context: context)
        conversation.refreshMessageMetadata(updateTimestamp: Date())
        seedStressToolRuns(in: context, project: project)
        return conversation
    }

    private func ensureStressConversationHasLongHistory(_ conversation: Conversation, context: ModelContext) {
        let existingStressMessages = conversation.messages.filter { message in
            message.content.hasPrefix("Stress message ") ||
            message.content.hasPrefix("I'll inspect that file.") ||
            message.content.hasPrefix("Read Sources/File")
        }
        let seededExchangeCount = min(Self.stressExchangeCount, existingStressMessages.count / 3)
        if seededExchangeCount < Self.stressExchangeCount {
            for index in (seededExchangeCount + 1)...Self.stressExchangeCount {
                appendStressExchange(index, to: conversation, context: context)
            }
        }

        if !conversation.messages.contains(where: { $0.content == Self.stressCompletionText }) {
            appendStressCompletion(to: conversation, context: context)
        }
        if !conversation.messages.contains(where: { $0.content == Self.stressFinalCheckpointText }) {
            let checkpoint = ChatMessage(
                role: .assistant,
                content: Self.stressFinalCheckpointText,
                conversation: conversation
            )
            conversation.appendMessage(checkpoint)
            context.insert(checkpoint)
        }
    }

    private func appendStressExchange(_ index: Int, to conversation: Conversation, context: ModelContext) {
        let user = ChatMessage(
            role: .user,
            content: "Stress message \(index): inspect Sources/File\(index).swift and summarize it.",
            conversation: conversation
        )
        let call = APIToolCall(
            id: "stress-call-\(index)",
            type: "function",
            function: APIFunctionCall(name: "read_file", arguments: "{\"path\":\"Sources/File\(index).swift\"}")
        )
        let callJSON = (try? JSONEncoder().encode([call])).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: "I'll inspect that file.",
            toolCallsJSON: callJSON,
            conversation: conversation
        )
        let tool = ChatMessage(
            role: .tool,
            content: "Read Sources/File\(index).swift\n" + String(repeating: "fixture output ", count: 42),
            toolCallID: call.id,
            conversation: conversation
        )
        conversation.appendMessages([user, assistant, tool])
        context.insert(user)
        context.insert(assistant)
        context.insert(tool)
    }

    private func appendStressCompletion(to conversation: Conversation, context: ModelContext) {
        let completion = ChatMessage(
            role: .assistant,
            content: Self.stressCompletionText,
            conversation: conversation
        )
        conversation.appendMessage(completion)
        context.insert(completion)
    }

    private static let stressExchangeCount = 66
    private static let stressCompletionText = "Stress navigation fixture ready: 66 file reads completed, drawer rows and tab switching are ready to verify."
    private static let stressFinalCheckpointText = "Stress window checkpoint: this conversation intentionally contains 200 messages so long-history rendering, jump-to-latest, and tab transitions can be verified."

    private func seedStressToolRuns(in context: ModelContext, project: Project) {
        for index in 1...66 {
            let name = "stress_read_file_\(index)"
            var descriptor = FetchDescriptor<ToolRun>(
                predicate: #Predicate { $0.name == name }
            )
            descriptor.fetchLimit = 1
            if let existing = try? context.fetch(descriptor).first {
                existing.project = project
                continue
            }

            let run = ToolRun(
                name: name,
                argumentsJSON: "{\"path\":\"Sources/File\(index).swift\"}",
                output: "Read Sources/File\(index).swift\n" + String(repeating: "fixture output ", count: 90),
                status: index.isMultiple(of: 9) ? .failed : .completed,
                requiresApproval: false,
                isMutating: false,
                project: project
            )
            run.createdAt = Date().addingTimeInterval(-Double(index) * 45)
            run.completedAt = run.createdAt.addingTimeInterval(Double(90 + index * 12) / 1000.0)
            context.insert(run)
        }
    }

    #if DEBUG || targetEnvironment(simulator)
    @discardableResult
    private func seedToolBatchConversation(in context: ModelContext, project: Project) -> Conversation? {
        let marker = "NovaForge Batch — 14 resolved actions"
        let legacyMarker = "NovaForge Stress — batched tool calls"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == marker })
        if let existing = try? context.fetch(descriptor).first {
            existing.project = project
            ensureToolBatchConversationCompletesWithAssistant(existing, context: context)
            existing.refreshMessageMetadata(updateTimestamp: Date())
            return existing
        }
        let legacyDescriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == legacyMarker })
        if let legacy = try? context.fetch(legacyDescriptor).first {
            legacy.title = marker
            legacy.project = project
            ensureToolBatchConversationCompletesWithAssistant(legacy, context: context)
            legacy.refreshMessageMetadata(updateTimestamp: Date())
            return legacy
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)

        let user = ChatMessage(
            role: .user,
            content: "Inspect this generated module map and queue the useful file reads.",
            conversation: conversation
        )
        let calls = (1...14).map { index in
            APIToolCall(
                id: "batch-read-\(index)",
                type: "function",
                function: APIFunctionCall(
                    name: "read_file",
                    arguments: "{\"path\":\"Sources/Generated/Module\(index).swift\"}"
                )
            )
        }
        let callJSON = (try? JSONEncoder().encode(calls)).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: "I'll inspect the generated modules in a single batch.",
            toolCallsJSON: callJSON,
            conversation: conversation
        )
        let toolMessages = calls.enumerated().map { offset, call in
            let index = offset + 1
            let failed = index.isMultiple(of: 6)
            return ChatMessage(
                role: .tool,
                content: failed
                    ? "Error: Sources/Generated/Module\(index).swift was not found."
                    : "Read Sources/Generated/Module\(index).swift\n" + String(repeating: "validated symbol map ", count: 36),
                toolCallID: call.id,
                conversation: conversation
            )
        }

        conversation.appendMessages([user, assistant] + toolMessages)
        context.insert(user)
        context.insert(assistant)
        toolMessages.forEach(context.insert)
        appendToolBatchCompletion(to: conversation, context: context)
        conversation.refreshMessageMetadata(updateTimestamp: Date())
        return conversation
    }

    private static let toolBatchCompletionText = "Batch fixture complete: 14 actions resolved with completed and failed labels ready to inspect."

    private func ensureToolBatchConversationCompletesWithAssistant(_ conversation: Conversation, context: ModelContext) {
        let ordered = conversation.messages.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard ordered.last?.content != Self.toolBatchCompletionText else { return }
        appendToolBatchCompletion(to: conversation, context: context)
    }

    private func appendToolBatchCompletion(to conversation: Conversation, context: ModelContext) {
        let completion = ChatMessage(
            role: .assistant,
            content: Self.toolBatchCompletionText,
            conversation: conversation
        )
        conversation.appendMessage(completion)
        context.insert(completion)
    }

    @discardableResult
    private func seedRunningToolCallConversation(in context: ModelContext, project: Project) -> Conversation? {
        let marker = "NovaForge Running Action — compact fixture"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == marker })
        if let existing = try? context.fetch(descriptor).first {
            existing.project = project
            existing.refreshMessageMetadata(updateTimestamp: Date())
            return existing
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)
        let user = ChatMessage(
            role: .user,
            content: "Read the config file and keep the activity visible while it runs.",
            conversation: conversation
        )
        let call = APIToolCall(
            id: "running-read-config",
            type: "function",
            function: APIFunctionCall(
                name: "read_file",
                arguments: #"{"path":"Sources/Generated/Config.swift"}"#
            )
        )
        let callJSON = (try? JSONEncoder().encode([call])).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: "I'll read that file and keep the activity visible while it runs.",
            toolCallsJSON: callJSON,
            conversation: conversation
        )

        conversation.appendMessages([user, assistant], updateTimestamp: Date())
        context.insert(user)
        context.insert(assistant)
        return conversation
    }

    @discardableResult
    private func seedFailedToolCallConversation(in context: ModelContext, project: Project) -> Conversation? {
        let marker = "NovaForge Failed Action — compact fixture"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == marker })
        if let existing = try? context.fetch(descriptor).first {
            existing.project = project
            existing.refreshMessageMetadata(updateTimestamp: Date())
            return existing
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)
        let user = ChatMessage(
            role: .user,
            content: "Read the missing config file and tell me what happened.",
            conversation: conversation
        )
        let call = APIToolCall(
            id: "failed-read-config",
            type: "function",
            function: APIFunctionCall(
                name: "read_file",
                arguments: #"{"path":"Sources/Missing/Config.swift"}"#
            )
        )
        let callJSON = (try? JSONEncoder().encode([call])).flatMap { String(data: $0, encoding: .utf8) }
        let assistant = ChatMessage(
            role: .assistant,
            content: "I'll check that file quietly and surface the result.",
            toolCallsJSON: callJSON,
            conversation: conversation
        )
        let tool = ChatMessage(
            role: .tool,
            content: "Error: Sources/Missing/Config.swift was not found. Check the path or create the file before retrying.",
            toolCallID: call.id,
            conversation: conversation
        )
        let completion = ChatMessage(
            role: .assistant,
            content: "I could not read Config.swift. The file is missing, so create it or update the path before retrying.",
            conversation: conversation
        )

        conversation.appendMessages([user, assistant, tool, completion], updateTimestamp: Date())
        context.insert(user)
        context.insert(assistant)
        context.insert(tool)
        context.insert(completion)
        return conversation
    }

    @discardableResult
    private func seedCodeBlockConversation(in context: ModelContext, project: Project) -> Conversation? {
        let marker = "NovaForge Code Block — actions fixture"
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.title == marker })
        if let existing = try? context.fetch(descriptor).first {
            existing.project = project
            existing.refreshMessageMetadata(updateTimestamp: Date())
            return existing
        }

        let conversation = Conversation(title: marker, project: project)
        context.insert(conversation)
        let user = ChatMessage(
            role: .user,
            content: "Generate a small Swift helper and make it easy to copy or save.",
            conversation: conversation
        )
        let helperSource = (1...36)
            .map { "    func generatedStep\($0)() -> String { \"step-\($0)\" }" }
            .joined(separator: "\n")
        let assistant = ChatMessage(
            role: .assistant,
            content: """
            Here is the generated helper:

            ```swift
            struct GeneratedHelper {
                let name: String

            \(helperSource)
            }
            ```
            """,
            conversation: conversation
        )
        conversation.appendMessages([user, assistant], updateTimestamp: Date())
        context.insert(user)
        context.insert(assistant)
        return conversation
    }
    #endif
}

@MainActor
final class NovaForgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .allButUpsideDown
    }
}
