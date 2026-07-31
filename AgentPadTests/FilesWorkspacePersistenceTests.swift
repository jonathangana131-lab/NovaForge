import SwiftData
import XCTest

@MainActor
final class FilesWorkspacePersistenceTests: XCTestCase {
    private enum SaveFailure: LocalizedError {
        case diskFull

        var errorDescription: String? { "simulated disk full" }
    }

    func testWorkspaceSelectionRollsBackWhenSaveFails() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AgentSettings(activeWorkspaceName: "Default")
        settings.updatedAt = originalDate

        XCTAssertThrowsError(
            try FilesWorkspacePersistence.persistWorkspaceSelection(
                "ClientDemo",
                settings: settings,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                save: { throw SaveFailure.diskFull }
            )
        )

        XCTAssertEqual(settings.activeWorkspaceName, "Default")
        XCTAssertEqual(settings.updatedAt, originalDate)
    }

    func testWorkspaceSelectionPersistsAfterSuccessfulSave() throws {
        let settings = AgentSettings(activeWorkspaceName: "Default")
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var saveCallCount = 0

        try FilesWorkspacePersistence.persistWorkspaceSelection(
            "ClientDemo",
            settings: settings,
            now: savedAt,
            save: { saveCallCount += 1 }
        )

        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(settings.activeWorkspaceName, "ClientDemo")
        XCTAssertEqual(settings.updatedAt, savedAt)
    }

    func testProjectWorkspaceSelectionPersistsProjectSettingsAndActiveProjectTogether() throws {
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previousProjectID = UUID()
        let project = Project(name: "Client Demo", workspaceName: "Default")
        let settings = AgentSettings(
            activeWorkspaceName: "Default",
            activeProjectID: previousProjectID
        )
        var saveCallCount = 0

        try FilesWorkspacePersistence.persistProjectWorkspaceSelection(
            "ClientDemo",
            project: project,
            settings: settings,
            now: savedAt,
            save: { saveCallCount += 1 }
        )

        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(project.workspaceName, "ClientDemo")
        XCTAssertEqual(settings.activeWorkspaceName, "ClientDemo")
        XCTAssertEqual(settings.activeProjectID, project.id)
        XCTAssertEqual(settings.updatedAt, savedAt)
    }

    func testProjectWorkspaceSelectionPersistsProjectWhenSettingsAreMissing() throws {
        let project = Project(name: "Client Demo", workspaceName: "Default")
        var saveCallCount = 0

        try FilesWorkspacePersistence.persistProjectWorkspaceSelection(
            "ClientDemo",
            project: project,
            settings: nil,
            save: { saveCallCount += 1 }
        )

        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(project.workspaceName, "ClientDemo")
    }

    func testProjectWorkspaceSelectionRollsBackProjectAndSettingsWhenSaveFails() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let originalProjectID = UUID()
        let project = Project(name: "Client Demo", workspaceName: "Default")
        let settings = AgentSettings(
            activeWorkspaceName: "Default",
            activeProjectID: originalProjectID
        )
        settings.updatedAt = originalDate

        XCTAssertThrowsError(
            try FilesWorkspacePersistence.persistProjectWorkspaceSelection(
                "ClientDemo",
                project: project,
                settings: settings,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                save: { throw SaveFailure.diskFull }
            )
        )

        XCTAssertEqual(project.workspaceName, "Default")
        XCTAssertEqual(settings.activeWorkspaceName, "Default")
        XCTAssertEqual(settings.activeProjectID, originalProjectID)
        XCTAssertEqual(settings.updatedAt, originalDate)
    }

    func testProviderModelSelectionRollsBackWhenSaveFails() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AgentSettings(provider: .openAI, modelID: "gpt-5.5-preview-manual")
        settings.customChatCompletionsURL = "https://api.example.test/v1/chat/completions"
        settings.temperature = 0.7
        settings.customSystemPrompt = "ship safely"
        settings.updatedAt = originalDate

        XCTAssertThrowsError(
            try AgentSettingsPersistence.persist(
                settings: settings,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                mutate: { settings in
                    settings.switchProvider(to: .local)
                    settings.modelID = LocalModelCatalog.defaultVariant.id
                    settings.temperature = 0.1
                    settings.customSystemPrompt = nil
                },
                save: { throw SaveFailure.diskFull }
            )
        )

        XCTAssertEqual(settings.provider, .openAI)
        XCTAssertEqual(settings.modelID, "gpt-5.5-preview-manual")
        XCTAssertEqual(settings.customChatCompletionsURL, "https://api.example.test/v1/chat/completions")
        XCTAssertEqual(settings.temperature, 0.7)
        XCTAssertEqual(settings.customSystemPrompt, "ship safely")
        XCTAssertEqual(settings.updatedAt, originalDate)
    }

    func testProviderModelSelectionPersistsAfterSuccessfulSave() throws {
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = AgentSettings(provider: .openAI, modelID: "gpt-4.1")
        var saveCallCount = 0

        try AgentSettingsPersistence.persist(
            settings: settings,
            now: savedAt,
            mutate: { settings in
                settings.switchProvider(to: .local)
                settings.modelID = LocalModelCatalog.defaultVariant.id
            },
            save: { saveCallCount += 1 }
        )

        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(settings.provider, .local)
        XCTAssertEqual(settings.modelID, LocalModelCatalog.defaultVariant.id)
        XCTAssertEqual(settings.updatedAt, savedAt)
    }

    func testComposerProviderModelSelectionRollsBackAndCommitsAtomically()
        throws
    {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AgentSettings(
            provider: .openAI,
            modelID: AIProvider.openAI.defaultModel
        )
        settings.updatedAt = originalDate

        XCTAssertThrowsError(
            try AgentSettingsPersistence.persistProviderModelSelection(
                provider: .local,
                modelID: AIProvider.local.defaultModel,
                settings: settings,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                save: { throw SaveFailure.diskFull }
            )
        )
        XCTAssertEqual(settings.provider, .openAI)
        XCTAssertEqual(settings.modelID, AIProvider.openAI.defaultModel)
        XCTAssertEqual(settings.updatedAt, originalDate)

        var saveCallCount = 0
        let savedAt = Date(timeIntervalSince1970: 1_900_000_000)
        try AgentSettingsPersistence.persistProviderModelSelection(
            provider: .openAICodex,
            modelID: AIProvider.openAICodex.defaultModel,
            settings: settings,
            now: savedAt,
            save: { saveCallCount += 1 }
        )

        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(settings.provider, .openAICodex)
        XCTAssertEqual(
            settings.modelID,
            AIProvider.openAICodex.defaultModel
        )
        XCTAssertEqual(settings.updatedAt, savedAt)
    }

    func testComposerProviderModelSelectionRejectsCrossProviderModelBeforeSave()
        throws
    {
        let settings = AgentSettings(
            provider: .openAI,
            modelID: AIProvider.openAI.defaultModel
        )
        let previous = AgentSettingsPersistence.snapshot(settings)
        var saveCallCount = 0

        XCTAssertThrowsError(
            try AgentSettingsPersistence.persistProviderModelSelection(
                provider: .local,
                modelID: AIProvider.openAI.defaultModel,
                settings: settings,
                save: { saveCallCount += 1 }
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentSettingsPersistence
                    .ProviderModelSelectionError,
                .unsupportedModel
            )
        }

        XCTAssertEqual(saveCallCount, 0)
        XCTAssertEqual(AgentSettingsPersistence.snapshot(settings), previous)
    }

    func testInvalidProviderRepairPersistsCoherentLocalSelectionAcceptedByFactory()
        throws
    {
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = AgentSettings(
            provider: .openAI,
            modelID: AIProvider.openAI.defaultModel
        )
        settings.providerRawValue = "removed-legacy-provider"
        XCTAssertEqual(
            settings.provider,
            .local,
            "The UI fallback must match the persisted repair default."
        )

        var saveCallCount = 0
        XCTAssertTrue(
            try AppRootPersistence.repairStaleModelSelection(
                settings: settings,
                now: savedAt,
                save: { saveCallCount += 1 }
            )
        )
        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(settings.providerRawValue, AIProvider.local.rawValue)
        XCTAssertEqual(settings.provider, .local)
        XCTAssertEqual(settings.modelID, AIProvider.local.defaultModel)
        XCTAssertEqual(settings.updatedAt, savedAt)

        let workspaceName = "Settings-Repair-\(UUID().uuidString)"
        let workspace = SandboxWorkspace(name: workspaceName)
        try FileManager.default.createDirectory(
            at: workspace.rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let project = Project(
            name: "Settings Repair",
            workspaceName: workspaceName
        )
        let conversation = Conversation(
            title: "Settings Repair",
            project: project
        )

        _ = try AgentSystemFreshRunRequestFactory.make(
            prompt: "Prove the repaired settings are runnable.",
            conversation: conversation,
            project: project,
            workspace: workspace,
            settings: settings
        )
    }

    func testLaunchRepairKeepsNewestSettingsAndDeletesOlderDuplicates()
        throws
    {
        let suiteName = "NovaForge-Duplicate-Settings-\(UUID().uuidString)"
        let migrationStore = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { migrationStore.removePersistentDomain(forName: suiteName) }
        let container = try ModelContainer(
            for: TestModelSchema.projectFoundation,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let older = AgentSettings(
            provider: .local,
            customSystemPrompt: "older instruction"
        )
        older.updatedAt = Date(timeIntervalSince1970: 100)
        let newest = AgentSettings(
            provider: .openAI,
            modelID: AIProvider.openAI.defaultModel,
            customSystemPrompt: "newest user instruction"
        )
        newest.updatedAt = Date(timeIntervalSince1970: 200)
        context.insert(older)
        context.insert(newest)
        try context.save()

        let result = try AppRootLaunchRepair.ensureLaunchRecords(
            in: context,
            settings: older,
            now: Date(timeIntervalSince1970: 300),
            migrationStore: migrationStore
        )
        try context.save()

        let persisted = try context.fetch(FetchDescriptor<AgentSettings>())
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(result.settings.id, newest.id)
        XCTAssertEqual(persisted.first?.id, newest.id)
        XCTAssertEqual(
            persisted.first?.customSystemPrompt,
            "newest user instruction"
        )
        XCTAssertEqual(persisted.first?.provider, .openAI)
        XCTAssertEqual(
            persisted.first?.modelID,
            AIProvider.openAI.defaultModel
        )
    }

    func testSettingsCanonicalSelectionUsesStableIDTieBreakAndRejectsOverflow()
        throws
    {
        let timestamp = Date(timeIntervalSince1970: 100)
        let lowerID = AgentSettings()
        lowerID.id = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        lowerID.updatedAt = timestamp
        let higherID = AgentSettings()
        higherID.id = try XCTUnwrap(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        higherID.updatedAt = timestamp

        XCTAssertEqual(
            try AgentSettingsRecordSelection.canonical(
                from: [higherID, lowerID]
            )?.id,
            lowerID.id
        )

        XCTAssertThrowsError(
            try AgentSettingsRecordSelection.canonical(
                from: Array(
                    repeating: lowerID,
                    count: AgentSettingsRecordSelection
                        .maximumCandidateCount + 1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AppRootLaunchRepairError,
                .settingsCandidateLimitExceeded
            )
        }
    }

    func testRootWorkspaceRepairRollsBackWhenSaveFails() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = AgentSettings(activeWorkspaceName: "Default")
        settings.updatedAt = originalDate
        let unsafeName = "Client Demo/../../Bad"

        XCTAssertThrowsError(
            try AppRootPersistence.repairActiveWorkspaceName(
                unsafeName,
                settings: settings,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                save: { throw SaveFailure.diskFull }
            )
        )

        XCTAssertEqual(settings.activeWorkspaceName, "Default")
        XCTAssertEqual(settings.updatedAt, originalDate)
    }

    func testRootWorkspaceRepairReturnsPersistedSafeNameAfterSuccessfulSave() throws {
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = AgentSettings(activeWorkspaceName: "Default")
        let unsafeName = "Client Demo/../../Bad"
        let expectedSafeName = SandboxWorkspace.sanitizedWorkspaceName(unsafeName)
        var saveCallCount = 0

        let repairedName = try AppRootPersistence.repairActiveWorkspaceName(
            unsafeName,
            settings: settings,
            now: savedAt,
            save: { saveCallCount += 1 }
        )

        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(repairedName, expectedSafeName)
        XCTAssertEqual(settings.activeWorkspaceName, expectedSafeName)
        XCTAssertEqual(settings.updatedAt, savedAt)
    }

    func testRootProjectSelectionPersistsProjectAndWorkspaceTogether() throws {
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previousProjectID = UUID()
        let project = Project(name: "Client Demo", workspaceName: "Client Demo/../../Bad")
        let settings = AgentSettings(
            activeWorkspaceName: "OriginalWorkspace",
            activeProjectID: previousProjectID
        )
        let expectedWorkspaceName = SandboxWorkspace.sanitizedWorkspaceName(project.workspaceName)
        var saveCallCount = 0

        let persistedWorkspaceName = try AppRootPersistence.persistActiveProjectSelection(
            project,
            settings: settings,
            now: savedAt,
            save: { saveCallCount += 1 }
        )

        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(persistedWorkspaceName, expectedWorkspaceName)
        XCTAssertEqual(project.workspaceName, expectedWorkspaceName)
        XCTAssertEqual(settings.activeWorkspaceName, expectedWorkspaceName)
        XCTAssertEqual(settings.activeProjectID, project.id)
        XCTAssertEqual(settings.updatedAt, savedAt)
    }

    func testRootProjectSelectionRollsBackProjectAndWorkspaceWhenSaveFails() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let originalProjectID = UUID()
        let unsafeWorkspaceName = "Client Demo/../../Bad"
        let project = Project(name: "Client Demo", workspaceName: unsafeWorkspaceName)
        let settings = AgentSettings(
            activeWorkspaceName: "OriginalWorkspace",
            activeProjectID: originalProjectID
        )
        settings.updatedAt = originalDate

        XCTAssertThrowsError(
            try AppRootPersistence.persistActiveProjectSelection(
                project,
                settings: settings,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                save: { throw SaveFailure.diskFull }
            )
        )

        XCTAssertEqual(project.workspaceName, unsafeWorkspaceName)
        XCTAssertEqual(settings.activeWorkspaceName, "OriginalWorkspace")
        XCTAssertEqual(settings.activeProjectID, originalProjectID)
        XCTAssertEqual(settings.updatedAt, originalDate)
    }

    func testRootProjectSelectionPersistsProjectWhenSettingsAreMissing() throws {
        let unsafeWorkspaceName = "Client Demo/../../Bad"
        let project = Project(name: "Client Demo", workspaceName: unsafeWorkspaceName)
        let expectedWorkspaceName = SandboxWorkspace.sanitizedWorkspaceName(unsafeWorkspaceName)
        var saveCallCount = 0

        let persistedWorkspaceName = try AppRootPersistence.persistActiveProjectSelection(
            project,
            settings: nil,
            save: { saveCallCount += 1 }
        )

        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(persistedWorkspaceName, expectedWorkspaceName)
        XCTAssertEqual(project.workspaceName, expectedWorkspaceName)
    }

    func testRootProjectSelectionRollsBackProjectWhenSettingsAreMissingAndSaveFails() throws {
        let unsafeWorkspaceName = "Client Demo/../../Bad"
        let project = Project(name: "Client Demo", workspaceName: unsafeWorkspaceName)

        XCTAssertThrowsError(
            try AppRootPersistence.persistActiveProjectSelection(
                project,
                settings: nil,
                save: { throw SaveFailure.diskFull }
            )
        )

        XCTAssertEqual(project.workspaceName, unsafeWorkspaceName)
    }

    func testRootStaleModelRepairRollsBackWhenSaveFails() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let staleModel = LocalModelCatalog.defaultVariant.id
        let settings = AgentSettings(provider: .openAI, modelID: staleModel)
        settings.temperature = 0.7
        settings.updatedAt = originalDate

        XCTAssertThrowsError(
            try AppRootPersistence.repairStaleModelSelection(
                settings: settings,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                save: { throw SaveFailure.diskFull }
            )
        )

        XCTAssertEqual(settings.provider, .openAI)
        XCTAssertEqual(settings.modelID, staleModel)
        XCTAssertEqual(settings.temperature, 0.7)
        XCTAssertEqual(settings.updatedAt, originalDate)
    }

    func testRootStaleModelRepairPersistsTrimmedModelSelection() throws {
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let settings = AgentSettings(provider: .openAI, modelID: "  gpt-4.1  ")
        var saveCallCount = 0

        let repaired = try AppRootPersistence.repairStaleModelSelection(
            settings: settings,
            now: savedAt,
            save: { saveCallCount += 1 }
        )

        XCTAssertTrue(repaired)
        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(settings.provider, .openAI)
        XCTAssertEqual(settings.modelID, "gpt-4.1")
        XCTAssertEqual(settings.updatedAt, savedAt)
    }

    func testWorkspaceMutationUIRequestUsesTypedTargetsAndHumanAuthorizationWithoutPayloads() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaforge-files-ui-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspace = SandboxWorkspace(rootURL: rootURL)
        let projectID = UUID()
        let conversationID = UUID()
        let request = try WorkspaceMutationUIRequest.make(
            workspace: workspace,
            operation: .copyPath(from: "Drafts/brief.md", to: "Drafts/brief_copy.md"),
            projectID: projectID,
            conversationID: conversationID,
            source: .files,
            ownerDescription: "Files duplicate file"
        )

        XCTAssertEqual(request.operation.targetPaths, ["Drafts/brief.md", "Drafts/brief_copy.md"])
        XCTAssertEqual(request.context.projectID, projectID)
        XCTAssertEqual(request.context.conversationID, conversationID)
        XCTAssertEqual(request.context.source, .files)
        XCTAssertEqual(request.context.authorization, .userInitiated)
        XCTAssertEqual(request.journalArgumentsJSON, "{}")
        XCTAssertFalse(request.journalArgumentsJSON.contains(rootURL.path))
        XCTAssertTrue(request.workspaceIdentity.resourceKey.hasPrefix("workspace:sha256:"))
        XCTAssertFalse(request.workspaceIdentity.resourceKey.contains(rootURL.path))
    }

    func testWorkspaceMutationUIFailureMessageSuppressesSafeCancellationButSurfacesAmbiguity() {
        let operationID = UUID()
        XCTAssertNil(
            WorkspaceMutationUIRequest.failureMessage(
                action: "Failed to save",
                error: WorkspaceMutationGatewayError.cancelledBeforeExecution(
                    operationID: operationID
                )
            )
        )

        let mayHaveApplied = WorkspaceMutationGatewayError.effectMayHaveApplied(
            operationID: operationID,
            message: "The filesystem result is uncertain."
        )
        let effectMessage = WorkspaceMutationUIRequest.failureMessage(
            action: "Failed to save",
            error: mayHaveApplied
        )
        XCTAssertTrue(effectMessage?.contains("may have applied") == true)
        XCTAssertTrue(effectMessage?.contains("before retrying") == true)

        let durableFailure = WorkspaceMutationGatewayError.durableSettlementFailed(
            operationID: operationID,
            lastDurablePhase: .applied,
            message: "The completion receipt could not commit."
        )
        let durableMessage = WorkspaceMutationUIRequest.failureMessage(
            action: "Could not duplicate file",
            error: durableFailure
        )
        XCTAssertTrue(durableMessage?.contains("ambiguously") == true)
        XCTAssertTrue(durableMessage?.contains("applied") == true)
    }
}
