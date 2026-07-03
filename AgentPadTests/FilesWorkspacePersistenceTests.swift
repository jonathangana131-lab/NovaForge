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
}
