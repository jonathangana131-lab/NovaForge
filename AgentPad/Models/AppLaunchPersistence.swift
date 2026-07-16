//
//  AppLaunchPersistence.swift
//  NovaForge
//
//  Filesystem, root-tab, and settings persistence plus launch repair.
//

import Foundation
import SwiftData

enum FilesWorkspacePersistence {
    static func persistWorkspaceSelection(
        _ workspaceName: String,
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws {
        guard let settings else { return }

        let previousWorkspaceName = settings.activeWorkspaceName
        let previousUpdatedAt = settings.updatedAt
        settings.activeWorkspaceName = workspaceName
        settings.updatedAt = now

        do {
            try save()
        } catch {
            settings.activeWorkspaceName = previousWorkspaceName
            settings.updatedAt = previousUpdatedAt
            throw error
        }
    }

    static func persistProjectWorkspaceSelection(
        _ workspaceName: String,
        project: Project,
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws {
        let previousProjectWorkspaceName = project.workspaceName
        let previousSettings = settings.map(AgentSettingsPersistence.snapshot)

        project.workspaceName = workspaceName
        if let settings {
            settings.activeWorkspaceName = workspaceName
            settings.activeProjectID = project.id
            settings.updatedAt = now
        }

        do {
            try save()
        } catch {
            project.workspaceName = previousProjectWorkspaceName
            if let settings, let previousSettings {
                AgentSettingsPersistence.restore(previousSettings, to: settings)
            }
            throw error
        }
    }
}

enum AppRootPersistence {
    static func repairActiveWorkspaceName(
        _ workspaceName: String,
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws -> String {
        let safeName = SandboxWorkspace.sanitizedWorkspaceName(workspaceName)
        guard safeName != workspaceName else { return safeName }

        try FilesWorkspacePersistence.persistWorkspaceSelection(
            safeName,
            settings: settings,
            now: now,
            save: save
        )
        return safeName
    }

    static func persistActiveProjectSelection(
        _ project: Project,
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws -> String {
        let safeWorkspaceName = SandboxWorkspace.sanitizedWorkspaceName(project.workspaceName)
        let previousProjectWorkspaceName = project.workspaceName
        guard let settings else {
            project.workspaceName = safeWorkspaceName
            do {
                try save()
                return safeWorkspaceName
            } catch {
                project.workspaceName = previousProjectWorkspaceName
                throw error
            }
        }

        let previousSettings = AgentSettingsPersistence.snapshot(settings)
        project.workspaceName = safeWorkspaceName
        settings.activeProjectID = project.id
        settings.activeWorkspaceName = safeWorkspaceName
        settings.updatedAt = now

        do {
            try save()
            return safeWorkspaceName
        } catch {
            project.workspaceName = previousProjectWorkspaceName
            AgentSettingsPersistence.restore(previousSettings, to: settings)
            throw error
        }
    }

    @discardableResult
    static func repairStaleModelSelection(
        settings: AgentSettings?,
        now: Date = Date(),
        save: () throws -> Void
    ) throws -> Bool {
        guard let settings else { return false }

        let previous = AgentSettingsPersistence.snapshot(settings)
        let reportedChange = settings.repairStaleModelSelection()
        let repaired = AgentSettingsPersistence.snapshot(settings) != previous
        guard reportedChange || repaired else { return false }

        settings.updatedAt = now
        do {
            try save()
            return true
        } catch {
            AgentSettingsPersistence.restore(previous, to: settings)
            throw error
        }
    }
}

struct AppRootLaunchRepairResult {
    let settings: AgentSettings
    let project: Project
    let conversation: Conversation
    let createdSettings: Bool
    let createdConversation: Bool
}

enum AppRootLaunchRepairError: LocalizedError {
    case settingsUnavailable

    var errorDescription: String? {
        "The persisted NovaForge settings record is unavailable for launch repair."
    }
}

enum AppRootLaunchRepair {
    struct Fetches {
        var settings: (ModelContext) throws -> AgentSettings?
        var conversations: (ModelContext) throws -> [Conversation]
        var projectBootstrap: ProjectBootstrap.Fetches

        static var live: Fetches {
            Fetches(
                settings: { context in
                    var descriptor = FetchDescriptor<AgentSettings>()
                    descriptor.fetchLimit = 1
                    return try context.fetch(descriptor).first
                },
                conversations: { context in
                    let descriptor = FetchDescriptor<Conversation>(
                        sortBy: [SortDescriptor(\Conversation.updatedAt, order: .reverse)]
                    )
                    return try context.fetch(descriptor)
                },
                projectBootstrap: .live
            )
        }
    }

    static func ensureLaunchRecords(
        in context: ModelContext,
        settings suppliedSettings: AgentSettings?,
        selectedConversation: Conversation? = nil,
        selectedConversationID: UUID? = nil,
        now: Date = Date(),
        migrationStore: UserDefaults = .standard,
        fetches: Fetches = .live
    ) throws -> AppRootLaunchRepairResult {
        // Complete every launch read before inserting or repairing anything.
        // A fetch failure therefore cannot be mistaken for an empty store and
        // cannot leave behind a partially-created launch graph.
        let fetchedSettings: AgentSettings?
        if let suppliedSettings {
            fetchedSettings = suppliedSettings
        } else {
            fetchedSettings = try fetches.settings(context)
        }
        let existingConversations = try fetches.conversations(context)
        let projectRecords = try ProjectBootstrap.prefetchRecords(
            in: context,
            migrationStore: migrationStore,
            fetches: fetches.projectBootstrap
        )

        let settings: AgentSettings
        let createdSettings: Bool
        if let suppliedSettings {
            settings = suppliedSettings
            createdSettings = false
        } else if let existing = fetchedSettings {
            settings = existing
            createdSettings = false
        } else {
            let created = AgentSettings()
            context.insert(created)
            settings = created
            createdSettings = true
        }

        let project = ProjectBootstrap.ensureDefaultProject(
            in: context,
            settings: settings,
            now: now,
            prefetched: projectRecords
        )
        let launchCandidates = existingConversations.filter { conversation in
            guard let owner = conversation.project else { return true }
            return owner.id == project.id
        }
        let selectedLaunchConversation: Conversation? = {
            let requestedID = selectedConversation?.id ?? selectedConversationID
            guard let requestedID,
                  let selected = existingConversations.first(where: { $0.id == requestedID }) else {
                return nil
            }
            guard let owner = selected.project else { return selected }
            return owner.id == project.id ? selected : nil
        }()
        let readyConversation = launchCandidates.first {
            $0.project == nil &&
            $0.title == LaunchConversationSelection.safeStartTitle &&
            !$0.hasUserMessages
        } ?? launchCandidates.first {
            $0.title == LaunchConversationSelection.safeStartTitle && !$0.hasUserMessages
        }
        let restorableConversation = launchCandidates.first(where: LaunchConversationSelection.isLaunchRestorable)

        let conversation: Conversation
        let createdConversation: Bool
        if let selectedLaunchConversation {
            conversation = selectedLaunchConversation
            createdConversation = false
        } else if let readyConversation {
            conversation = readyConversation
            createdConversation = false
        } else if let restorableConversation {
            conversation = restorableConversation
            createdConversation = false
        } else {
            let created = Conversation(title: LaunchConversationSelection.safeStartTitle, project: nil)
            context.insert(created)
            conversation = created
            createdConversation = true
            ProjectEventRecorder.record(
                project: nil,
                kind: .conversationStarted,
                title: "Launch conversation ready",
                detail: created.title,
                severity: .info,
                sourceType: .conversation,
                sourceID: created.id,
                context: context,
                now: now
            )
        }

        if conversation.title == LaunchConversationSelection.safeStartTitle, !conversation.hasUserMessages {
            conversation.project = nil
        }
        if settings.activeProjectID != project.id {
            settings.activeProjectID = project.id
            settings.updatedAt = now
        }
        let repairedWorkspaceName = repairedActiveWorkspaceName(project: project, settings: settings)
        if project.workspaceName != repairedWorkspaceName {
            project.workspaceName = repairedWorkspaceName
        }
        if settings.activeWorkspaceName != repairedWorkspaceName {
            settings.activeWorkspaceName = repairedWorkspaceName
            settings.updatedAt = now
        }

        return AppRootLaunchRepairResult(
            settings: settings,
            project: project,
            conversation: conversation,
            createdSettings: createdSettings,
            createdConversation: createdConversation
        )
    }

    private static func repairedActiveWorkspaceName(project: Project, settings: AgentSettings) -> String {
        let projectWorkspace = project.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawWorkspaceName = projectWorkspace.isEmpty ? settings.activeWorkspaceName : project.workspaceName
        return SandboxWorkspace.sanitizedWorkspaceName(rawWorkspaceName)
    }
}

enum AgentSettingsPersistence {
    struct Snapshot: Equatable {
        let providerRawValue: String?
        let modelID: String
        let customChatCompletionsURL: String?
        let autoApproveWrites: Bool
        let activeWorkspaceName: String
        let activeProjectIDString: String?
        let temperature: Double
        let customSystemPrompt: String?
        let updatedAt: Date
    }

    static func snapshot(_ settings: AgentSettings) -> Snapshot {
        Snapshot(
            providerRawValue: settings.providerRawValue,
            modelID: settings.modelID,
            customChatCompletionsURL: settings.customChatCompletionsURL,
            autoApproveWrites: settings.autoApproveWrites,
            activeWorkspaceName: settings.activeWorkspaceName,
            activeProjectIDString: settings.activeProjectIDString,
            temperature: settings.temperature,
            customSystemPrompt: settings.customSystemPrompt,
            updatedAt: settings.updatedAt
        )
    }

    static func restore(_ snapshot: Snapshot, to settings: AgentSettings) {
        settings.providerRawValue = snapshot.providerRawValue
        settings.modelID = snapshot.modelID
        settings.customChatCompletionsURL = snapshot.customChatCompletionsURL
        settings.autoApproveWrites = snapshot.autoApproveWrites
        settings.activeWorkspaceName = snapshot.activeWorkspaceName
        settings.activeProjectIDString = snapshot.activeProjectIDString
        settings.temperature = snapshot.temperature
        settings.customSystemPrompt = snapshot.customSystemPrompt
        settings.updatedAt = snapshot.updatedAt
    }

    static func materialExecutionChangeDetails(from previous: Snapshot, to current: Snapshot) -> [String] {
        var details: [String] = []

        if previous.providerRawValue != current.providerRawValue {
            details.append("Provider: \(providerDisplayName(previous.providerRawValue)) -> \(providerDisplayName(current.providerRawValue))")
        }

        if previous.modelID != current.modelID {
            details.append("Model: \(displayModel(previous.modelID)) -> \(displayModel(current.modelID))")
        }

        if previous.customChatCompletionsURL != current.customChatCompletionsURL {
            let oldEndpoint = endpointDisplayName(previous.customChatCompletionsURL)
            let newEndpoint = endpointDisplayName(current.customChatCompletionsURL)
            details.append("Endpoint: \(oldEndpoint) -> \(newEndpoint)")
        }

        if previous.autoApproveWrites != current.autoApproveWrites {
            details.append(current.autoApproveWrites ? "Writes: auto-approve enabled" : "Writes: approval required")
        }

        if abs(previous.temperature - current.temperature) >= 0.001 {
            details.append(String(format: "Temperature: %.1f -> %.1f", previous.temperature, current.temperature))
        }

        if normalizedPromptState(previous.customSystemPrompt) != normalizedPromptState(current.customSystemPrompt) {
            details.append("System prompt: \(normalizedPromptState(current.customSystemPrompt))")
        }

        return details
    }

    static func materialExecutionChangeDetail(from previous: Snapshot, to current: Snapshot) -> String? {
        let details = materialExecutionChangeDetails(from: previous, to: current)
        guard !details.isEmpty else { return nil }
        return details.joined(separator: "; ")
    }

    static func persist(
        settings: AgentSettings,
        now: Date = Date(),
        mutate: (AgentSettings) -> Void,
        save: () throws -> Void
    ) throws {
        let previous = snapshot(settings)
        mutate(settings)
        settings.updatedAt = now

        do {
            try save()
        } catch {
            restore(previous, to: settings)
            throw error
        }
    }

    private static func providerDisplayName(_ rawValue: String?) -> String {
        (AIProvider(rawValue: rawValue ?? "") ?? .openAI).displayName
    }

    private static func displayModel(_ modelID: String) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Default" : trimmed
    }

    private static func endpointDisplayName(_ endpoint: String?) -> String {
        let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "default" }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
            return "custom"
        }
        return host
    }

    private static func normalizedPromptState(_ prompt: String?) -> String {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "default" : "custom"
    }
}
