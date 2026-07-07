import XCTest
import UIKit

@MainActor
final class AgentPadUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    func testLaunchShowsNovaForge() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))
    }

    func testLaunchStartsOnFreshReadyChatInsteadOfOldChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        let title = app.staticTexts["currentChatTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "NovaForge")

        app.buttons["New chat"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertNotEqual(title.label, "NovaForge Ready")

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "NovaForge", "Launch should reopen a fresh ready chat, not the same old working chat.")
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["firstRunProjectLauncher"].exists)
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists)
        capture("40-clean-default-chat", app: app)
    }

    func testBigPictureFirstRunMissionBriefingScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Launch a project"].exists)
        XCTAssertFalse(app.otherElements["firstRunProjectLauncher"].exists)
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists)
        capture("50-clean-chat-no-project-launcher", app: app)
    }

    func testFirstRunLocalMissingBlocksStarterMissionsAndShowsDownloadsSetup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--first-run-local-model-missing"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Local model not downloaded"].exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Starter missions are blocked")).firstMatch.exists)
        XCTAssertFalse(app.buttons["firstRunSetupDownload"].exists)

        for identifier in ["missionStarter-build", "missionStarter-fix", "missionStarter-audit", "missionStarter-ship"] {
            XCTAssertFalse(app.buttons[identifier].exists, "\(identifier) should not appear as a dead button while setup blocks starters.")
        }

        capture("80-first-run-local-missing-blocked", app: app)
    }

    func testReadyFirstMissionStarterPrefillsComposer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--settings-local-model-ready", "--open-chat"]
        app.launch()

        let starter = app.buttons["firstMissionStarter-prototype"]
        XCTAssertTrue(starter.waitForExistence(timeout: 8), "Ready first-run chat should expose starter missions.")
        starter.tap()

        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let value = (composer.value as? String) ?? composer.label
        XCTAssertTrue(value.contains("Build a small polished prototype"), "Starter should prefill the composer with the chosen mission prompt.")
        XCTAssertTrue(app.buttons["sendMessageButton"].isEnabled, "A ready starter prompt should be sendable.")
        capture("goal-ready-first-mission-starter-prefilled", app: app)
    }

    func testLaunchRestoresCompletedSelectedChatButNotInterruptedDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        let title = app.staticTexts["currentChatTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))

        app.buttons["New chat"].tap()
        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("list files")
        app.buttons["sendMessageButton"].tap()
        XCTAssertTrue(app.staticTexts["Run complete"].waitForExistence(timeout: 8))

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5), "Cold launch should start in a fresh chat.")
        XCTAssertFalse(app.staticTexts["list files"].exists, "Cold launch should not reopen the previous completed chat by default.")
        XCTAssertFalse(app.staticTexts["Launch a project"].exists)
        capture("47-cold-launch-fresh-chat", app: app)

        app.buttons["New chat"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("unfinished draft")

        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5), "An empty/interrupted chat should not become the launch chat.")
        XCTAssertFalse(app.staticTexts["unfinished draft"].exists)
        capture("48-interrupted-chat-falls-back-ready", app: app)
    }

    func testChatComposerKeyboardAndResponseScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--debug-provider-send-fails"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))
        let headerTitle = app.staticTexts["currentChatTitle"].firstMatch
        assertHeaderAnchoredNearTop(headerTitle, in: app, message: "Chat header should stay anchored near the top safe area.")

        capture("01-chat", app: app)

        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Show me what tools you can use")
        assertNoFloatingActionsOverComposer(in: app)
        let keyboard = app.keyboards.firstMatch
        let keyboardVisible = keyboard.waitForExistence(timeout: 3)
        let sendButton = app.buttons["Send message"]
        let modelPicker = app.descendants(matching: .any)["composerModelNativeMenu"]
        if modelPicker.waitForExistence(timeout: 1) {
            XCTAssertTrue(modelPicker.label.localizedCaseInsensitiveContains("Choose model"), "Composer model rail should advertise model selection, not read as a mystery chip.")
            XCTAssertGreaterThanOrEqual(modelPicker.frame.width, 120, "Composer model rail should have room for a compact provider and model label, not a cryptic tiny chip.")
            XCTAssertLessThanOrEqual(modelPicker.frame.width, 180, "Composer model rail should stay compact so the typing field remains the primary surface.")
        }
        let composerDock = composerDock(in: app)
        XCTAssertTrue(composerDock.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(composerDock.frame.height, 180, "A normal one-line prompt should be a compact two-row card, not the giant old composer sheet.")
        XCTAssertTrue(sendButton.isEnabled, "The typed prompt should enable Send even when a hardware keyboard prevents a software keyboard frame.")
        if keyboardVisible {
            let composerKeyboardGap = keyboard.frame.minY - sendButton.frame.maxY
            XCTAssertGreaterThanOrEqual(composerKeyboardGap, 8, "Composer should clear the keyboard/predictive bar instead of touching or overlapping it.")
            XCTAssertLessThanOrEqual(composerKeyboardGap, 80, "Composer should sit directly above the keyboard without a dead spacer.")
            assertKeyboardComposerChrome(in: app, keyboard: keyboard, sendButton: sendButton)
        } else {
            XCTAssertTrue(sendButton.isEnabled, "With a hardware keyboard attached, the typed prompt should still enable Send.")
        }
        assertComposerDockAligned(in: app)
        capture("02-keyboard-composer", app: app)

        app.buttons["Send message"].tap()
        if keyboardVisible {
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3), "Sending from the focused composer should dismiss the keyboard cleanly.")
        }
        XCTAssertGreaterThanOrEqual(composerDock.frame.maxY, app.frame.maxY - 180, "After the keyboard dismisses, the composer should settle near the bottom instead of floating where the keyboard was.")
        let sentMessage = app.staticTexts["Show me what tools you can use"].firstMatch
        XCTAssertTrue(sentMessage.waitForExistence(timeout: 3), "Sent prompt should remain visible in the transcript.")
        XCTAssertLessThanOrEqual(sentMessage.frame.maxY, composerDock.frame.minY - 8, "Latest messages should remain readable above the composer after sending.")
        let runAccessory = runProgressToggle(in: app)
        XCTAssertTrue(runAccessory.waitForExistence(timeout: 3), "Run/action accessory should be visible after a failed local send.")
        let bottomAccessoryTop = min(runAccessory.frame.minY, composerDock.frame.minY)
        XCTAssertLessThanOrEqual(sentMessage.frame.maxY, bottomAccessoryTop - 8, "Sent prompt should clear the full run/action accessory, not only the composer.")
        let assistantMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "request timed out")).firstMatch
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5), "Assistant response should remain visible after Send.")
        XCTAssertLessThanOrEqual(assistantMessage.frame.maxY, bottomAccessoryTop - 8, "Assistant output should stay readable above the full bottom accessory stack.")
        XCTAssertFalse(app.otherElements["liveStreamingBubble"].waitForExistence(timeout: 2), "Failed send should clear live response state.")
        sleep(1)
        capture("03-agent-typing", app: app)
    }

    func testForgeChatSendStreamsOneAssistantBubbleAndClearsRunningState() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--debug-provider-send-ready", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))

        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Yo")
        app.buttons["sendMessageButton"].tap()

        let userText = app.staticTexts["Yo"].firstMatch
        XCTAssertTrue(userText.waitForExistence(timeout: 2), "User message should appear immediately after Send.")

        let liveBubble = app.otherElements["liveStreamingBubble"]
        XCTAssertTrue(liveBubble.waitForExistence(timeout: 4), "Streaming response should render as one live assistant bubble.")
        XCTAssertLessThanOrEqual(visibleElementCount(app.otherElements.matching(identifier: "liveStreamingBubble")), 1, "Streaming should update one live bubble instead of adding duplicates.")

        let assistantText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hey! What can I do")).firstMatch
        XCTAssertTrue(assistantText.waitForExistence(timeout: 8), "Final assistant response should replace the live stream in the transcript.")
        XCTAssertFalse(liveBubble.waitForExistence(timeout: 2), "Live bubble should clear after final response is visible.")
        XCTAssertEqual(visibleElementCount(app.otherElements.matching(identifier: "chatAssistantMessageBubble")), 1, "Welcome-style assistant output should appear once, not as live plus final duplicates.")
        XCTAssertEqual(visibleStaticTextCount(in: app, containing: "Hey! What can I do"), 1, "Welcome text should not duplicate as a real assistant output and a live response.")

        let userBubble = app.otherElements.matching(identifier: "chatUserMessageBubble").firstMatch
        let assistantBubble = app.otherElements.matching(identifier: "chatAssistantMessageBubble").firstMatch
        XCTAssertTrue(userBubble.waitForExistence(timeout: 2))
        XCTAssertTrue(assistantBubble.waitForExistence(timeout: 2))
        XCTAssertFalse(userBubble.frame.intersects(assistantBubble.frame), "User and assistant bubbles must not visually overlap.")

        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(assistantBubble.frame.maxY, bottomAccessory.frame.minY - 4, "Auto-scroll should keep the latest response readable above the composer.")
        let assistantDockGap = bottomAccessory.frame.minY - assistantBubble.frame.maxY
        XCTAssertGreaterThanOrEqual(assistantDockGap, 4, "Auto-scroll should not tuck the latest assistant response under the composer.")
        XCTAssertLessThanOrEqual(assistantDockGap, 96, "Auto-scroll should land on the latest assistant response, not an invisible spacer below the transcript.")
        XCTAssertTrue(app.staticTexts["Run complete"].waitForExistence(timeout: 4), "Running/Calling state should clear after a valid response.")
        capture("sev0-chat-send-stream-visible-before-followup", app: app)

        composer.tap()
        composer.typeText("Follow-up ready")
        XCTAssertTrue(app.buttons["sendMessageButton"].isEnabled, "Composer should recover for the next prompt after completion.")
        capture("sev0-chat-send-stream-final", app: app)
    }

    func testForgeChatFailedSendShowsTranscriptErrorAndRecoversComposer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--debug-provider-send-fails", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))

        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Trigger a timeout")
        app.buttons["sendMessageButton"].tap()

        XCTAssertTrue(app.staticTexts["Trigger a timeout"].firstMatch.waitForExistence(timeout: 2), "Failed send should still keep the user bubble.")
        let errorText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "request timed out")).firstMatch
        XCTAssertTrue(errorText.waitForExistence(timeout: 8), "Failed provider send should show a visible transcript error.")
        XCTAssertFalse(app.otherElements["liveStreamingBubble"].waitForExistence(timeout: 2), "Failure should clear live streaming UI.")

        composer.tap()
        composer.typeText("Recover after timeout")
        XCTAssertTrue(app.buttons["sendMessageButton"].isEnabled, "Composer should re-enable after failure once the user types again.")
        capture("sev0-chat-send-failure-recovered", app: app)
    }

    func testChatComposerExpandsForLongTextAndStaysAboveKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))

        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        let singleLineHeight = composer.frame.height
        composer.typeText("Build me a smooth native iPhone app with a glassy chat composer that expands over multiple lines without jumping above the keyboard")
        assertNoFloatingActionsOverComposer(in: app)

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        let expandedComposer = chatComposerInput(in: app)
        XCTAssertTrue(expandedComposer.waitForExistence(timeout: 3))
        let expandedHeight = expandedComposer.frame.height
        XCTAssertGreaterThan(expandedHeight, singleLineHeight + 8, "Composer text field should grow for multi-line prompts.")
        XCTAssertLessThanOrEqual(expandedHeight, 150, "Composer should cap growth instead of taking over the screen.")
        let sendButton = app.buttons["Send message"]
        let modelPicker = app.descendants(matching: .any)["composerModelNativeMenu"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 3), "Expanded composer should keep the compact model rail available.")
        XCTAssertTrue(modelPicker.label.localizedCaseInsensitiveContains("Choose model"), "Expanded composer model rail should remain clearly identifiable as model selection.")
        XCTAssertGreaterThanOrEqual(modelPicker.frame.width, 120, "Expanded composer model rail should keep the provider and model label readable.")
        XCTAssertLessThanOrEqual(modelPicker.frame.width, 180, "Expanded composer model rail should not grow into a toolbar while drafting long prompts.")
        XCTAssertLessThanOrEqual(modelPicker.frame.maxY, expandedComposer.frame.minY + 4, "Expanded composer model rail should stay above draft text, not inside the typing lane.")
        let expandedDock = composerDock(in: app)
        XCTAssertTrue(expandedDock.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(expandedDock.frame.height, 164, "Expanded composer should make room for long drafts without turning into a bottom sheet.")
        let composerKeyboardGap = keyboard.frame.minY - sendButton.frame.maxY
        XCTAssertGreaterThanOrEqual(composerKeyboardGap, 8, "Expanded composer should clear the keyboard/predictive bar instead of touching or overlapping it.")
        XCTAssertLessThanOrEqual(composerKeyboardGap, 80, "Expanded composer should stay docked to the keyboard without a dead spacer.")
        assertKeyboardComposerChrome(in: app, keyboard: keyboard, sendButton: sendButton)
        assertComposerDockAligned(in: app)
        capture("20-long-composer-expanded", app: app)
    }

    func testChatComposerPreservesDraftAndSurvivesScrollAndNewChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--keyboard-multiline-draft-demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))

        let composer = chatComposerInput(in: app)
        let initialDock = composerDock(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(initialDock.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        let sendButton = app.buttons["Send message"]
        assertKeyboardComposerChrome(in: app, keyboard: keyboard, sendButton: sendButton)
        assertComposerDockAligned(in: app)
        let draftValue = (composer.value as? String) ?? ""
        XCTAssertTrue(draftValue.contains("First line of a preserved draft"), "Prefilled first line should remain in the composer draft.")
        XCTAssertTrue(draftValue.contains("Second line stays in the composer"), "Newline text should remain a draft instead of being auto-sent or dropped.")
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "A multiline draft should not auto-send just because it contains a newline.")
        XCTAssertFalse(app.buttons["composerFilesDockButton"].exists, "Files should not clutter the typing dock.")
        XCTAssertFalse(app.buttons["composerTerminalDockButton"].exists, "Terminal should not clutter the typing dock.")
        capture("23-multiline-draft-preserved", app: app)

        app.staticTexts["currentChatTitle"].tap()
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(initialDock.waitForExistence(timeout: 3), "Composer dock should remain pinned after scrolling the chat.")
        XCTAssertGreaterThan(initialDock.frame.maxY, 0, "Composer dock should not disappear above the screen after scrolling.")
        XCTAssertLessThan(initialDock.frame.minY, app.frame.maxY, "Composer dock should not disappear below the screen after scrolling.")
        capture("24-composer-survives-scroll", app: app)

        app.buttons["New chat"].tap()
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))
        let restoredDock = composerDock(in: app)
        let restoredComposer = chatComposerInput(in: app)
        XCTAssertTrue(restoredDock.waitForExistence(timeout: 5), "Starting a new chat should restore the typing dock if scroll/keyboard state got stale.")
        XCTAssertTrue(restoredComposer.waitForExistence(timeout: 5), "Starting a new chat should restore the text input.")
        capture("25-composer-restored-after-new-chat", app: app)
    }

    func testBottomMenuStaysAlignedBeforeAndAfterTabLoads() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        let startingFrame = tabBar.frame
        capture("41-bottom-menu-before-loading-tabs", app: app)

        for tab in ["Forge", "Workspace", "History", "Control"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let beforeFrame = button.frame
            button.tap()
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let afterFrame = button.frame
            XCTAssertLessThan(abs(afterFrame.midY - beforeFrame.midY), 10, "\(tab) tab should not jump vertically after it loads.")
            XCTAssertLessThan(abs(tabBar.frame.height - startingFrame.height), 8, "Tab bar height should remain stable while loading \(tab).")
        }

        capture("42-bottom-menu-after-all-tabs-loaded", app: app)
    }

    func testFourTabDockAndMissionDossierRouteSemantics() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-project"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8), "Legacy --open-project should route to Forge instead of reviving a Project dock tab.")
        for tab in ["Forge", "Workspace", "History", "Control"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 5), "Four-tab dock should expose \(tab).")
        }
        for oldTab in ["Project", "Files", "Chat", "Runs", "Settings"] {
            XCTAssertFalse(app.tabBars.buttons[oldTab].exists, "Legacy dock tab should stay removed: \(oldTab).")
        }
        XCTAssertFalse(app.otherElements["projectDashboard"].exists, "Project dashboard should not be a public tab surface for --open-project.")
        capture("43-four-tab-open-project-forge-route", app: app)

        app.terminate()
        app.launchArguments = ["--reset-ui", "--open-project", "--open-mission-dossier-demo"]
        app.launch()

        XCTAssertTrue(app.otherElements["projectDashboard"].waitForExistence(timeout: 8), "Mission Dossier should mount the project dashboard when explicitly requested.")
        let close = app.buttons["missionDossierClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Mission Dossier should expose a stable close control.")
        assertMinimumTouchTarget(close, named: "Mission Dossier close")
        capture("44-mission-dossier-explicit-route", app: app)
        close.tap()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5), "Closing Mission Dossier should reveal Forge.")
    }

    func testProjectLiquidGlassPerformanceTraceFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-project", "--open-mission-dossier-demo", "--profile-frame-rate", "--profile-events", "--auto-project-scroll"]
        app.launch()

        let projectHero = app.otherElements["projectOSControlCenter"]
        XCTAssertTrue(projectHero.waitForExistence(timeout: 8), "Project dashboard proof now lives inside the Mission Dossier cover, not a public Project tab.")
        XCTAssertTrue(app.buttons["missionDossierClose"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["missionOSPanel"].exists)
        XCTAssertFalse(app.otherElements["projectLatestEvidenceSection"].exists)

        sleep(5)
        app.swipeUp()
        app.swipeDown()
        capture("43-mission-dossier-performance-scroll", app: app)
        app.buttons["missionDossierClose"].tap()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))

        for tab in ["Workspace", "Forge", "History", "Control", "Forge"] {
            let tabButton = app.tabBars.buttons[tab]
            XCTAssertTrue(tabButton.waitForExistence(timeout: 5))
            tabButton.tap()
        }
        XCTAssertFalse(app.tabBars.buttons["Project"].exists, "Project should not return as a public tab; the dashboard is the Mission Dossier.")

        app.terminate()
        app.launchArguments = ["--reset-ui", "--stress-streaming", "--open-chat", "--profile-frame-rate", "--profile-events"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        sleep(3)
    }

    func testFilesShowsSeedReadme() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))

        let filesTab = app.tabBars.buttons["Workspace"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()

        XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
        let fileCell = app.staticTexts["README.md"]
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5))
        fileCell.tap()

        sleep(1)
        capture("04-files-readme", app: app)
    }

    func testFilesStressListAndSearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--stress-files"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        let filesTab = app.tabBars.buttons["Workspace"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()

        XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 5))
        assertMinimumTouchTarget(app.buttons["filesBreadcrumb-home"], named: "Files Home breadcrumb")
        app.staticTexts["Sources"].tap()
        let sourcesBreadcrumb = app.buttons["filesBreadcrumb-0-Sources"]
        XCTAssertTrue(sourcesBreadcrumb.waitForExistence(timeout: 5), "Opening Sources should expose a stable breadcrumb button.")
        assertMinimumTouchTarget(sourcesBreadcrumb, named: "Files Sources breadcrumb")
        capture("15-files-stress-list", app: app)

        app.buttons["Toggle file layout"].tap()
        usleep(400_000)
        capture("30-files-stress-grid", app: app)
        app.buttons["Toggle file layout"].tap()
        usleep(400_000)
        capture("31-files-stress-list-return", app: app)

        app.buttons["Search files"].tap()
        let searchField = app.textFields["filesSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(searchField, named: "Files search field")
        searchField.tap()
        searchField.typeText("Fixture symbol 12")
        let filesSearchKeyboard = app.keyboards.firstMatch
        XCTAssertTrue(filesSearchKeyboard.waitForExistence(timeout: 3), "Files search should use the normal iPhone keyboard while editing.")
        let runSearch = app.buttons["filesSearchRun"]
        XCTAssertTrue(runSearch.waitForExistence(timeout: 5), "Files search should expose a stable run button.")
        assertMinimumTouchTarget(runSearch, named: "Files search run")
        runSearch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "Running Files search should dismiss the keyboard so results are not hidden behind it.")

        let summary = app.staticTexts["filesSearchSummary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("Fixture symbol 12"))
        let detail = app.staticTexts["filesSearchDetail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertTrue(detail.label.contains("files scanned"))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Files search result screenshots should not keep the keyboard over the result list.")
        assertMinimumTouchTarget(app.buttons["filesSearchClose"], named: "Files search Close")
        XCTAssertTrue(app.staticTexts["Module12.swift"].waitForExistence(timeout: 5))
        capture("16-files-search-results", app: app)

        app.staticTexts["Module12.swift"].tap()
        let editorTitle = app.staticTexts["codeEditorFileName"]
        XCTAssertTrue(editorTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(editorTitle.label, "Module12.swift")

        assertMinimumTouchTarget(app.buttons["codeEditorCancelButton"], named: "code editor Cancel")
        assertMinimumTouchTarget(app.buttons["codeEditorSaveButton"], named: "code editor Save")
        let themePicker = app.buttons["codeEditorThemePicker"].exists ? app.buttons["codeEditorThemePicker"] : app.otherElements["codeEditorThemePicker"]
        XCTAssertTrue(themePicker.waitForExistence(timeout: 5), "Code editor theme picker should expose a stable, testable control.")
        assertMinimumTouchTarget(themePicker, named: "code editor Theme picker")
        assertMinimumTouchTarget(app.buttons["codeEditorDecreaseFont"], named: "code editor decrease font")
        assertMinimumTouchTarget(app.buttons["codeEditorIncreaseFont"], named: "code editor increase font")
        assertMinimumTouchTarget(app.buttons["codeEditorFindToggle"], named: "code editor find toggle")
        assertMinimumTouchTarget(app.buttons["codeEditorHelper-leftBrace"], named: "code editor keyboard helper left brace")

        app.buttons["codeEditorFindToggle"].tap()
        XCTAssertTrue(app.textFields["codeEditorFindField"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["codeEditorReplaceField"].waitForExistence(timeout: 3))
        assertMinimumTouchTarget(app.buttons["codeEditorFindNext"], named: "code editor Find Next")
        assertMinimumTouchTarget(app.buttons["codeEditorReplace"], named: "code editor Replace")
        assertMinimumTouchTarget(app.buttons["codeEditorReplaceAll"], named: "code editor Replace All")
        capture("32-files-generated-module-open", app: app)
    }

    func testFilesSearchControlsExposePhoneSizedTargets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--stress-files"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        let filesTab = app.tabBars.buttons["Workspace"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()

        XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
        assertMinimumTouchTarget(app.buttons["filesBreadcrumb-home"], named: "Files Home breadcrumb")
        app.buttons["Search files"].tap()

        let searchField = app.textFields["filesSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(searchField, named: "Files search field")
        searchField.tap()
        searchField.typeText("Fixture symbol")

        let runSearch = app.buttons["filesSearchRun"]
        XCTAssertTrue(runSearch.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(runSearch, named: "Files search run")
        assertMinimumTouchTarget(app.buttons["filesSearchClose"], named: "Files search Close")
        capture("67-files-search-controls", app: app)
    }

    func testLongToolHeavyChatSidebarAndTabs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-chat"]
        app.launch()

        let title = app.staticTexts["currentChatTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertTrue(title.label.contains("Stress"), "Stress launch should select the seeded tool-heavy conversation instead of falling back to the empty launcher.")

        let chatScroll = app.scrollViews.firstMatch
        XCTAssertTrue(chatScroll.exists)
        chatScroll.swipeDown()
        let latestButton = jumpToLatestButton(in: app)
        if latestButton.waitForExistence(timeout: 1) {
            capture("12-jump-to-latest-visible", app: app)
            if app.buttons["Load older messages"].waitForExistence(timeout: 2) {
                app.buttons["Load older messages"].tap()
                XCTAssertTrue(app.buttons["Collapse earlier messages"].waitForExistence(timeout: 5) || app.buttons["Load older messages"].waitForExistence(timeout: 1))
                capture("27-chat-thread-window-expanded", app: app)
                if app.buttons["Collapse earlier messages"].exists {
                    app.buttons["Collapse earlier messages"].tap()
                }
                capture("28-chat-thread-window-collapsed", app: app)
            }
            latestButton.tap()
        } else {
            capture("12-long-chat-scroll-optimized", app: app)
        }
        chatScroll.swipeUp()

        app.buttons["Open chats"].tap()
        let search = app.textFields["chatSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let drawerTitle = app.staticTexts["chatDrawerTitle"]
        XCTAssertTrue(drawerTitle.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(drawerTitle.frame.minY, 58, "Drawer title should clear the status bar while the long chat is selected.")
        search.tap()
        search.typeText("200 messages")
        let filteredCount = app.staticTexts["chatDrawerSummary"]
        XCTAssertTrue(filteredCount.waitForExistence(timeout: 5))
        XCTAssertTrue(filteredCount.label.contains("1 shown"))
        capture("26-chat-drawer-filtered", app: app)
        app.buttons["chatDrawerClose"].tap()

        for tab in ["Workspace", "History", "Control", "Forge"] {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            let tabBarBefore = app.tabBars.firstMatch.frame
            button.tap()
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertLessThan(abs(app.tabBars.firstMatch.frame.midY - tabBarBefore.midY), 8, "Tab bar should not jump while switching to \(tab).")

            switch tab {
            case "Workspace":
                XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
                capture("05-workspace-tab", app: app)
            case "History":
                XCTAssertTrue(app.otherElements["historyVaultSummaryPanel"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))
                let shownSummary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'shown'")).firstMatch
                XCTAssertTrue(shownSummary.waitForExistence(timeout: 5))
                capture("07-history-stress-runs", app: app)
            case "Control":
                XCTAssertTrue(app.otherElements["settingsRoot"].waitForExistence(timeout: 5))
                capture("08-control-tab", app: app)
            case "Forge":
                XCTAssertTrue(chatComposerInput(in: app).waitForExistence(timeout: 5))
                XCTAssertTrue(title.label.contains("Stress"), "Returning to Forge should preserve the selected stress conversation.")
                capture("09-forge-return", app: app)
            default:
                break
            }
        }
    }

    func testCodeBlockActionsExposePhoneSizedTargets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--code-block-demo"]
        app.launch()

        let title = app.staticTexts["currentChatTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertEqual(title.label, "NovaForge Code Block — actions fixture")

        let previewToggle = app.buttons["codeBlockPreviewToggle"]
        XCTAssertTrue(previewToggle.waitForExistence(timeout: 5), "Large code blocks should expose a Preview/Collapse target.")
        assertMinimumTouchTarget(previewToggle, named: "code block Preview")

        let codeCopy = app.buttons["codeBlockCopyButton"]
        XCTAssertTrue(codeCopy.waitForExistence(timeout: 5), "Code block should expose Copy for generated code handoff.")
        assertMinimumTouchTarget(codeCopy, named: "code block Copy")

        let codeSave = app.buttons["codeBlockSaveButton"]
        XCTAssertTrue(codeSave.waitForExistence(timeout: 5), "Code block should expose Save for generated code handoff.")
        assertMinimumTouchTarget(codeSave, named: "code block Save")
        previewToggle.tap()
        XCTAssertTrue(previewToggle.waitForExistence(timeout: 2), "Preview control should remain available as Collapse after expanding.")
        assertMinimumTouchTarget(previewToggle, named: "code block Collapse")
        capture("33-code-block-actions", app: app)
    }

    func testTerminalLongOutputDisclosureControlsScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-terminal", "--stress-terminal"]
        app.launch()

        XCTAssertFalse(app.tabBars.buttons["More"].exists)
        XCTAssertFalse(app.tabBars.buttons["Term"].exists)
        XCTAssertTrue(app.otherElements["terminalCommandDeck"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["terminalCommandComposer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["140 lines"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["terminalCopyOutput"].waitForExistence(timeout: 5))
        let expand = app.buttons["terminalOutputExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        capture("60-terminal-long-output-collapsed", app: app)

        expand.tap()
        XCTAssertTrue(app.buttons["terminalOutputCollapse"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["terminalCopyOutput"].waitForExistence(timeout: 5), "Copy output should remain reachable at the top of expanded long output.")
        let composerDock = app.otherElements["terminalCommandComposer"]
        let collapseButton = app.buttons["terminalOutputCollapse"]
        let copyButton = app.buttons["terminalCopyOutput"]
        XCTAssertLessThan(collapseButton.frame.maxY, composerDock.frame.minY, "Expanded output controls should stay above the terminal composer instead of being covered by the dock.")
        XCTAssertLessThan(copyButton.frame.maxY, composerDock.frame.minY, "Copy output should stay above the terminal composer instead of being covered by the dock.")
        let cappedMessage = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "hidden for smooth scrolling")).firstMatch
        XCTAssertTrue(cappedMessage.waitForExistence(timeout: 5))
        capture("61-terminal-long-output-expanded", app: app)

        app.buttons["terminalOutputCollapse"].tap()
        XCTAssertTrue(app.buttons["terminalOutputExpand"].waitForExistence(timeout: 5))
        capture("62-terminal-long-output-recollapsed", app: app)
    }

    func testTerminalMutatingCommandSafetyConfirmationScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-terminal", "--terminal-safety-demo"]
        app.launch()

        XCTAssertTrue(app.otherElements["terminalCommandDeck"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["terminalCommandSafetyStrip"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["terminalCommandSafetyLabel"].label, "Changes files")
        XCTAssertTrue(app.staticTexts["terminalCommandSafetyDetail"].label.contains("ask before running"))
        XCTAssertTrue(app.textFields["terminalCommandInput"].waitForExistence(timeout: 5))
        capture("70-terminal-safety-draft", app: app)

        app.buttons["terminalRunButton"].tap()
        XCTAssertTrue(app.staticTexts["Run file-changing command?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "create, move, copy, or delete files")).firstMatch.waitForExistence(timeout: 5))
        capture("71-terminal-safety-confirmation", app: app)

        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["terminalCommandInput"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["terminalCommandSafetyLabel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["terminalCommandSafetyLabel"].label, "Changes files")
    }

    func testTerminalQuickChecksAndUnsupportedCommandGuardScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-terminal", "--terminal-unsupported-demo"]
        app.launch()

        XCTAssertTrue(app.otherElements["terminalCommandDeck"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["terminalQuickChecks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["terminalCommandSafetyLabel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["terminalCommandSafetyLabel"].label, "Unsupported command")
        XCTAssertFalse(app.buttons["terminalRunButton"].isEnabled, "Unsupported shell/network commands should not be runnable from the safe iPhone terminal.")
        capture("76-terminal-unsupported-guard", app: app)

        let quickCheck = app.buttons["terminalQuickCheck-head-README.md"]
        XCTAssertTrue(quickCheck.waitForExistence(timeout: 5), "High-value read-only quick checks should be visible in the command deck.")
        quickCheck.tap()
        XCTAssertEqual(app.staticTexts["terminalCommandSafetyLabel"].label, "Read-only command")
        XCTAssertTrue(app.buttons["terminalRunButton"].isEnabled)
        capture("77-terminal-quick-check-ready", app: app)
    }

    func testTerminalReadOnlyPresetRunsWithoutConfirmationScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-terminal"]
        app.launch()

        XCTAssertTrue(app.otherElements["terminalCommandDeck"].waitForExistence(timeout: 8))
        app.buttons["terminalPreset-pwd"].tap()
        XCTAssertTrue(app.staticTexts["terminalCommandSafetyLabel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["terminalCommandSafetyLabel"].label, "Read-only command")
        app.buttons["terminalRunButton"].tap()
        XCTAssertFalse(app.staticTexts["Run file-changing command?"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["$ pwd"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OK"].waitForExistence(timeout: 5))
        capture("72-terminal-readonly-ran", app: app)
    }

    func testTerminalShowsLiveAgentCreatedRecordWhileOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-terminal", "--terminal-live-record-demo"]
        app.launch()

        XCTAssertTrue(app.otherElements["terminalCommandDeck"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["$ pwd"].waitForExistence(timeout: 8), "Agent-created terminal records should appear without reopening Terminal.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "agent live terminal sync proof")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["OK"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["terminalEmptyState"].exists)
        capture("78-terminal-live-agent-record", app: app)
    }

    func testRunsShowsLinkedTerminalProofForAgentCommand() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-runs", "--terminal-live-record-demo"]
        app.launch()

        XCTAssertTrue(app.otherElements["runsAuditDashboard"].waitForExistence(timeout: 8))
        let searchField = app.textFields["runsSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("agent live terminal sync proof")
        if app.keyboards.firstMatch.exists {
            searchField.typeText("\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "Runs search keyboard should dismiss before opening a filtered proof row.")
        }

        XCTAssertTrue(app.staticTexts["1 shown"].waitForExistence(timeout: 5), "Runs search should settle on the injected terminal proof run.")
        XCTAssertTrue(app.descendants(matching: .any)["runTerminalProofBadge"].waitForExistence(timeout: 5), "The filtered command run should advertise terminal proof.")
        XCTAssertTrue(app.descendants(matching: .any)["runTerminalProofInline"].waitForExistence(timeout: 5), "Command runs should expose terminal proof directly on the row.")

        XCTAssertTrue(app.buttons["runHistoryCard"].firstMatch.waitForExistence(timeout: 8), "Agent-created command runs should appear in Runs after the terminal proof fixture saves.")
        XCTAssertTrue(app.staticTexts["$ pwd"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "agent live terminal sync proof")).firstMatch.waitForExistence(timeout: 5))
        let openTerminal = app.buttons["runOpenTerminalRecord"].firstMatch
        XCTAssertTrue(openTerminal.waitForExistence(timeout: 5), "Linked terminal proof should offer a direct Terminal context.")
        assertMinimumTouchTarget(openTerminal, named: "run open terminal record")
        assertMinimumTouchTarget(app.buttons["runCopyTerminalCommand"], named: "run copy terminal command")
        assertMinimumTouchTarget(app.buttons["runCopyTerminalOutput"], named: "run copy terminal output")
        capture("79-runs-linked-terminal-proof", app: app)

        openTerminal.tap()
        XCTAssertTrue(app.otherElements["terminalCommandDeck"].waitForExistence(timeout: 5), "Opening a linked proof should present the Terminal surface.")
        let terminalSearch = app.textFields["terminalConsoleSearchField"]
        XCTAssertTrue(terminalSearch.waitForExistence(timeout: 5), "Terminal should open with search visible for the linked proof.")
        let terminalSearchValue = terminalSearch.value as? String ?? ""
        XCTAssertTrue(terminalSearchValue.localizedCaseInsensitiveContains("agent live terminal sync proof"), "Terminal search should focus the linked proof output.")
        XCTAssertTrue(app.staticTexts["$ pwd"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "agent live terminal sync proof")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["terminalCloseButton"].waitForExistence(timeout: 5), "Private Terminal presentation should be dismissible.")
        capture("80-runs-open-terminal-proof-context", app: app)
    }

    func testRunsHistoryDisclosureControlsScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let runsTab = app.tabBars.buttons["History"]
        XCTAssertTrue(runsTab.waitForExistence(timeout: 5))
        runsTab.tap()

        XCTAssertTrue(app.otherElements["runsAuditDashboard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Run Audit"].waitForExistence(timeout: 5))
        let shownSummary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "shown")).firstMatch
        XCTAssertTrue(shownSummary.waitForExistence(timeout: 5))
        capture("63-runs-history-collapsed", app: app)

        let searchField = app.textFields["runsSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Runs search should expose a stable field identifier for release QA.")
        searchField.tap()
        searchField.typeText("read")
        let runsSearchKeyboard = app.keyboards.firstMatch
        XCTAssertTrue(runsSearchKeyboard.waitForExistence(timeout: 3), "Runs search should use the normal iPhone keyboard while editing.")
        let searchClear = app.buttons["runsSearchClearButton"]
        XCTAssertTrue(searchClear.waitForExistence(timeout: 5), "Runs search should expose a visible clear control after typing.")
        assertMinimumTouchTarget(searchClear, named: "runs search clear")
        searchClear.tap()
        XCTAssertFalse(searchClear.waitForExistence(timeout: 1), "Runs search clear should disappear after emptying the query.")
        XCTAssertTrue(runsSearchKeyboard.waitForNonExistence(timeout: 3), "Clearing Runs search should dismiss the keyboard so run details are not hidden behind it.")
        let clearedValue = searchField.value as? String ?? ""
        XCTAssertTrue(clearedValue.isEmpty || clearedValue == "Search tool, status, path, or command", "Runs search clear should empty the query without forcing users to backspace.")
        capture("66-runs-search-clear", app: app)

        let firstRun = app.buttons.matching(identifier: "runHistoryCard").firstMatch
        XCTAssertTrue(firstRun.waitForExistence(timeout: 5))
        firstRun.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Opening a run card should leave the keyboard dismissed so audit controls remain visible.")
        XCTAssertTrue(app.buttons["runToggleArguments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["runCopyArguments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["runToggleOutput"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["runCopyOutput"].waitForExistence(timeout: 5))
        assertMinimumTouchTarget(app.buttons["runToggleOutput"], named: "run output disclosure")
        assertMinimumTouchTarget(app.buttons["runCopyOutput"], named: "run output copy")
        XCTAssertTrue(app.buttons["runDeleteLogButton"].waitForExistence(timeout: 5), "Expanded run cards should expose visible delete controls instead of hiding deletion behind a context menu only.")
        assertMinimumTouchTarget(app.buttons["runDeleteLogButton"], named: "run delete log")
        capture("64-runs-history-expanded-controls", app: app)

        app.buttons["runToggleOutput"].tap()
        let outputText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "fixture output")).firstMatch
        XCTAssertTrue(outputText.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["runOutputPreview"].waitForExistence(timeout: 5))
        let capNotice = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Preview capped for smooth scrolling")).firstMatch
        XCTAssertTrue(capNotice.waitForExistence(timeout: 5))
        capture("65-runs-history-output-open", app: app)
    }

    func testBatchedToolCallsCollapseAndExpand() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--stress-tool-batch"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let batchSummary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'actions'")).firstMatch
        XCTAssertTrue(batchSummary.waitForExistence(timeout: 5))

        let moreButton = app.buttons.matching(identifier: "toolBatchToggle").firstMatch
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        XCTAssertTrue(moreButton.label.contains("Show action details"))
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "toolActivityRow").firstMatch.exists,
            "Resolved tool batches should default to one compact action line, not stacked transcript cards."
        )
        capture("10-tool-batch-collapsed", app: app)

        moreButton.tap()
        let fewerPredicate = NSPredicate(format: "label CONTAINS %@", "Hide action details")
        expectation(for: fewerPredicate, evaluatedWith: app.buttons.matching(identifier: "toolBatchToggle").firstMatch)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "toolActivityRow").firstMatch.waitForExistence(timeout: 5),
            "Expanded action details should remain available on demand."
        )
        XCTAssertFalse(app.buttons["quickAction-inspect"].exists, "Tool-heavy completion transcripts should not show quick-action chips over the expanded tool activity strip.")
        capture("11-tool-batch-expanded", app: app)
    }

    func testRunningToolCallStaysInlineAndCompact() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--running-tool-call-demo", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let runningRow = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Reading Config.swift")).firstMatch
        XCTAssertTrue(runningRow.waitForExistence(timeout: 5), "Running tool calls should appear as a compact inline activity row.")
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 5), "The running strip should expose a small plain-language status label.")
        let activityRow = app.descendants(matching: .any).matching(identifier: "toolActivityRow").firstMatch
        XCTAssertTrue(activityRow.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(activityRow.frame.height, 44, "Running tool activity should stay close to one compact line.")
        XCTAssertFalse(app.buttons["toolBatchToggle"].exists, "A single running tool should not render a large batch/details control.")
        XCTAssertFalse(app.staticTexts["Tool Center"].exists, "Running tool activity should not revive the old large debug panel.")
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists, "Running chat tool activity should stay in the transcript, not duplicate Run Control UI.")
        capture("14-tool-running-compact", app: app)
    }

    func testFailedToolCallStaysCompactAndExpandable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--failed-tool-call-demo", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let failedSummary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "1 failed")).firstMatch
        XCTAssertTrue(failedSummary.waitForExistence(timeout: 5), "A resolved failed tool call should collapse to a compact failed-action summary.")
        XCTAssertTrue(failedSummary.label.contains("Config.swift"), "The compact failure summary should name the actionable target.")
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "was not found")).firstMatch.exists,
            "Raw failure output should stay hidden until the user expands details."
        )
        capture("12-tool-failure-collapsed", app: app)

        let detailToggle = app.buttons.matching(identifier: "toolBatchToggle").firstMatch
        XCTAssertTrue(detailToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(detailToggle.label.contains("Show action details"))
        detailToggle.tap()

        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Could not read Config.swift")).firstMatch.waitForExistence(timeout: 5))
        let resultDetail = app.staticTexts.matching(identifier: "toolResultDetail").firstMatch
        XCTAssertTrue(resultDetail.waitForExistence(timeout: 5))
        XCTAssertTrue(resultDetail.label.contains("was not found"))
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists, "Failed tool details should stay in the inline action disclosure, not a duplicate debug/status panel.")
        capture("13-tool-failure-expanded", app: app)
    }

    func testArtifactToolCallHandoffStaysCompactAndOpenableFromChat() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--local-agent-boundary-test", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "build and verify the game")).firstMatch.waitForExistence(timeout: 5))

        let summary = app.staticTexts.matching(identifier: "toolActivitySummary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Artifact-producing tool batches should collapse to one compact handoff line in Chat.")
        XCTAssertTrue(summary.label.contains("3 actions completed"), "Artifact handoff should summarize the completed tool batch instead of replaying raw rows.")
        XCTAssertTrue(summary.label.contains("slither-arena.html"), "Artifact handoff should name the generated file.")
        XCTAssertLessThanOrEqual(summary.frame.height, 32, "Artifact tool handoff should stay visually compact.")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "toolActivityRow").firstMatch.exists,
            "Resolved artifact tool calls should not show stacked detail rows by default."
        )
        XCTAssertFalse(app.staticTexts["Tool Center"].exists, "Artifact handoff should not revive the old debug-panel label.")

        let openArtifact = app.buttons["toolArtifactOpenButton"]
        XCTAssertTrue(openArtifact.waitForExistence(timeout: 5), "Compact artifact handoff should still expose an inline open action.")
        XCTAssertFalse(openArtifact.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Artifact open action should keep a VoiceOver label.")
        capture("15-tool-artifact-handoff-compact", app: app)

        openArtifact.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let previewStudio = app.descendants(matching: .any).matching(identifier: "artifactPreviewStudio").firstMatch
        let normalPreviewLabel = app.staticTexts["Normal preview"]
        let swiftGamePreview = app.descendants(matching: .any).matching(identifier: "swiftGamePreviewPlayer").firstMatch
        let previewShareButton = identifiedElement("artifactShareButton", in: app)
        XCTAssertTrue(
            previewStudio.waitForExistence(timeout: 4) ||
                normalPreviewLabel.waitForExistence(timeout: 8) ||
                swiftGamePreview.waitForExistence(timeout: 8) ||
                previewShareButton.waitForExistence(timeout: 8),
            "Opening the compact artifact handoff should present the preview studio."
        )
        XCTAssertTrue(previewStudio.exists || normalPreviewLabel.waitForExistence(timeout: 5) || swiftGamePreview.waitForExistence(timeout: 5) || previewShareButton.exists)
        capture("16-tool-artifact-opened-from-chat", app: app)
    }

    func testChatDrawerScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--stress-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        app.buttons["Open chats"].tap()

        let search = app.textFields["chatSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let drawerTitle = app.staticTexts["chatDrawerTitle"]
        XCTAssertTrue(drawerTitle.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(drawerTitle.frame.minY, 58, "Drawer title should clear the status bar instead of overlapping the clock/notch area.")
        XCTAssertGreaterThan(search.frame.minY, drawerTitle.frame.maxY + 70, "Drawer search should sit below the header and New Chat control.")
        capture("17-chat-drawer", app: app)
    }

    func testLocalModelSettingsScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        let settingsTab = app.tabBars.buttons["Control"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        if !app.staticTexts["On-Device Model"].waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["On-Device Model"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["VibeThinker-3B iPhone 12"].waitForExistence(timeout: 5))
        capture("18-local-model-settings", app: app)
    }

    func testSettingsReadyCardUsesReadableProviderModelHierarchy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--settings-local-model-ready"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Ready to run"].waitForExistence(timeout: 5))

        let providerModelText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Local", "VibeThinker Q2")).firstMatch
        XCTAssertTrue(providerModelText.waitForExistence(timeout: 5), "Ready card should show provider and readable model name in one visible line.")
        XCTAssertGreaterThanOrEqual(providerModelText.frame.width, 120, "Provider/model text should remain visibly readable on compact iPhones.")
        XCTAssertTrue(app.staticTexts["Ask before writes"].waitForExistence(timeout: 3), "Writes policy pill should remain visible after provider/model is promoted.")
        XCTAssertTrue(app.staticTexts["Terminal Noir"].waitForExistence(timeout: 3), "Theme pill should remain visible after provider/model is promoted.")
        for providerID in ["local", "openAI", "openAICodex", "openRouter", "openCodeZen", "custom"] {
            let provider = app.buttons["settingsProvider-\(providerID)"]
            XCTAssertTrue(provider.waitForExistence(timeout: 3), "Settings should expose provider route \(providerID) without hidden horizontal scrolling.")
            XCTAssertGreaterThanOrEqual(provider.frame.minX, app.frame.minX + 24, "Provider route \(providerID) should stay inside the compact iPhone leading edge.")
            XCTAssertLessThanOrEqual(provider.frame.maxX, app.frame.maxX - 24, "Provider route \(providerID) should stay inside the compact iPhone trailing edge.")
            assertMinimumTouchTarget(provider, named: "settings provider \(providerID)")
        }
        capture("86-settings-ready-card-readable-hierarchy", app: app)
    }

    func testCustomProviderInvalidEndpointShowsInlineValidationScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--settings-local-model-ready"]
        app.launch()

        XCTAssertTrue(app.otherElements["settingsRoot"].waitForExistence(timeout: 8))
        let customProvider = app.buttons["settingsProvider-custom"]
        if !customProvider.waitForExistence(timeout: 2) {
            app.swipeDown()
        }
        XCTAssertTrue(customProvider.waitForExistence(timeout: 5))
        customProvider.tap()

        let endpointField = app.textFields["Custom endpoint URL"]
        if !endpointField.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(endpointField.waitForExistence(timeout: 5))
        endpointField.tap()
        endpointField.typeText("file:///tmp/not-a-provider")

        let validation = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Use a valid http:// or https:// endpoint")).firstMatch
        XCTAssertTrue(validation.waitForExistence(timeout: 5), "Custom providers should explain invalid URLs before a run fails.")
        capture("87-settings-custom-endpoint-validation", app: app)
    }

    func testLocalModelDestructiveActionsRequireConfirmation() throws {
        func openSettingsFixture(_ launchArgument: String) -> XCUIApplication {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-ui", launchArgument, "--open-settings"]
            app.launch()
            XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 8))
            if !app.staticTexts["On-Device Model"].waitForExistence(timeout: 2) {
                app.swipeUp()
            }
            XCTAssertTrue(app.staticTexts["On-Device Model"].waitForExistence(timeout: 5))
            return app
        }

        var app = openSettingsFixture("--settings-local-model-ready")
        let removeButton = app.buttons["settingsLocalModelRemoveButton"]
        for _ in 0..<4 where !removeButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(removeButton.waitForExistence(timeout: 5), "Installed local model settings should expose Remove as a stable button.")
        assertMinimumTouchTarget(removeButton, named: "settings local model Remove")
        removeButton.tap()
        XCTAssertTrue(app.staticTexts["Remove local model?"].waitForExistence(timeout: 5), "Removing an installed local model must require confirmation before deleting bytes.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "deletes the installed model")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove Model"].waitForExistence(timeout: 5), "Confirmation should expose an explicit destructive Remove Model action.")
        capture("84-settings-local-model-remove-confirm", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(removeButton.waitForExistence(timeout: 5), "Canceling Remove should keep the installed model action visible instead of deleting immediately.")
        app.terminate()

        app = openSettingsFixture("--settings-local-model-partial")
        let restartButton = app.buttons["settingsLocalModelRestartButton"]
        for _ in 0..<4 where !restartButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(restartButton.waitForExistence(timeout: 5), "Partial local model settings should expose Restart as a stable button.")
        assertMinimumTouchTarget(restartButton, named: "settings local model Restart")
        restartButton.tap()
        XCTAssertTrue(app.staticTexts["Restart local model download?"].waitForExistence(timeout: 5), "Restarting a partial local model must require confirmation before discarding downloaded bytes.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Resume keeps existing bytes")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Restart Download"].waitForExistence(timeout: 5), "Confirmation should expose an explicit destructive Restart Download action.")
        capture("85-settings-local-model-restart-confirm", app: app)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(restartButton.waitForExistence(timeout: 5), "Canceling Restart should keep the partial download resumable.")
    }

    func testNativeModelPickerAndCodexProviderScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let settingsTab = app.tabBars.buttons["Control"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let codexProvider = app.staticTexts["OpenAI Codex"]
        XCTAssertTrue(codexProvider.waitForExistence(timeout: 5))
        codexProvider.tap()

        let pickerButton = app.buttons["modelPickerButton"]
        if !pickerButton.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(pickerButton.waitForExistence(timeout: 5))
        pickerButton.tap()

        XCTAssertTrue(app.staticTexts["Choose Model"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["gpt-5.1-codex"].waitForExistence(timeout: 5))
        let settingsModelSearch = app.textFields["Search models"]
        XCTAssertTrue(settingsModelSearch.waitForExistence(timeout: 5))
        settingsModelSearch.tap()
        settingsModelSearch.typeText("codex")
        let settingsClear = app.buttons["settingsModelSearchClearButton"]
        XCTAssertTrue(settingsClear.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(settingsClear, named: "settings model search clear")
        let revealButton = app.buttons["settingsAPIKeyRevealButton"]
        if revealButton.waitForExistence(timeout: 3) {
            assertMinimumTouchTarget(revealButton, named: "settings API key reveal")
        }
        assertMinimumTouchTarget(app.buttons["modelPickerDone"], named: "model picker Done")
        if app.buttons["modelRefreshButton"].waitForExistence(timeout: 2) {
            assertMinimumTouchTarget(app.buttons["modelRefreshButton"], named: "model refresh card")
        }
        let missingKeyMessage = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "OpenAI API key needed")).firstMatch
        XCTAssertTrue(missingKeyMessage.waitForExistence(timeout: 5))
        let exampleOnlyMessage = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Built-in model IDs are examples only")).firstMatch
        XCTAssertTrue(exampleOnlyMessage.waitForExistence(timeout: 5), "Provider defaults must be framed as example IDs, not runnable no-key models.")
        capture("21-native-model-picker-codex", app: app)
        app.buttons["Done"].tap()
    }

    func testCodexTerminalDemoIsHiddenInNormalProviderFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let settingsTab = app.tabBars.buttons["Control"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let codexProvider = app.staticTexts["OpenAI Codex"]
        XCTAssertTrue(codexProvider.waitForExistence(timeout: 5))
        codexProvider.tap()

        let openAIKeyTitle = app.staticTexts["OpenAI Key"]
        let openAIKeyHelp = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Uses your OpenAI API key for Codex-compatible model IDs")).firstMatch
        let apiKeyField = app.secureTextFields["sk-..."]
        if !openAIKeyTitle.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        if !openAIKeyTitle.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(openAIKeyTitle.waitForExistence(timeout: 5), "Codex should present the real OpenAI API-key section in normal app flow.")
        XCTAssertTrue(openAIKeyHelp.waitForExistence(timeout: 5), "Codex credential copy should explain that ChatGPT/Codex subscription tokens are not available to iOS apps.")
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 5), "Codex should expose the OpenAI API key field instead of a simulated terminal setup.")
        XCTAssertFalse(app.otherElements["codexTerminalSection"].exists, "Simulated Codex terminal must not appear in normal Settings flow.")
        XCTAssertFalse(app.staticTexts["codex simulated terminal"].exists, "Simulated terminal copy must be hidden unless a debug demo flag is passed.")
        capture("38-settings-codex-key-required-no-terminal", app: app)

        let chatTab = app.tabBars.buttons["Forge"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 5))
        chatTab.tap()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["codexChatTerminalCard"].exists, "Chat should not show a fake Codex terminal card in normal provider flow.")
        XCTAssertFalse(app.staticTexts["Open Codex Terminal"].exists)
        capture("39-chat-codex-no-terminal-card", app: app)
    }

    func testComposerModelMenuUsesNativePopup() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        capture("22a-chat-dock-redesigned", app: app)

        let composerModelButton = composerModelControl(in: app)
        XCTAssertTrue(composerModelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(composerModelButton.label.localizedCaseInsensitiveContains("Choose model"), "Composer model control should describe its purpose before opening the native menu.")
        composerModelButton.tap()

        XCTAssertTrue(app.buttons["Local"].firstMatch.waitForExistence(timeout: 5), "Composer menu should expose provider switching as native menu actions.")
        XCTAssertTrue(app.buttons["OpenAI"].firstMatch.waitForExistence(timeout: 5), "Composer menu should keep hosted providers reachable without a second sheet.")
        XCTAssertTrue(app.buttons["VibeThinker Q2"].firstMatch.waitForExistence(timeout: 5), "Composer menu should show the current local model in-place.")
        XCTAssertFalse(app.staticTexts["Switch model"].exists, "Composer should not open the removed custom model sheet.")
        XCTAssertFalse(app.buttons["composerModelSearchClearButton"].exists, "Search belongs in Settings; the composer menu should stay compact.")
        XCTAssertFalse(app.buttons["Refresh provider models"].exists, "Live model refresh belongs in Settings; the composer menu should stay focused on choosing.")
        XCTAssertFalse(app.navigationBars["Models"].exists, "Composer picker should use the compact native menu, not the old List navigation sheet.")
        capture("22b-composer-native-model-menu", app: app)
    }

    func testComposerProviderSwitchingRepairsStaleModelInline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stale-openai-local-model"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let composerModelButton = composerModelControl(in: app)
        XCTAssertTrue(composerModelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(composerModelButton.label.contains("OpenAI"), "A stale local model under OpenAI should repair to OpenAI before the user sends.")
        XCTAssertFalse(composerModelButton.label.contains("VibeThinker"), "Stale local model labels should not survive under the OpenAI provider.")
        composerModelButton.tap()

        XCTAssertTrue(app.buttons["gpt-5.5"].firstMatch.waitForExistence(timeout: 5), "Repaired OpenAI state should show the default OpenAI model in the native composer menu.")
        XCTAssertFalse(app.staticTexts["Switch model"].exists, "Composer provider switching should not bring back the old custom model sheet.")

        let codexProvider = app.buttons["OpenAI Codex"].firstMatch
        XCTAssertTrue(codexProvider.waitForExistence(timeout: 5))
        codexProvider.tap()
        XCTAssertTrue(composerModelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(composerModelButton.label.contains("OpenAI Codex"), "Selecting Codex should update the compact composer label immediately.")
        XCTAssertTrue(composerModelButton.label.contains("gpt-5.1-codex"), "Provider switching should repair to the selected provider's default model.")

        composerModelButton.tap()
        let localProvider = app.buttons["Local"].firstMatch
        XCTAssertTrue(localProvider.waitForExistence(timeout: 5))
        localProvider.tap()
        XCTAssertTrue(composerModelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(composerModelButton.label.contains("Local"), "Local should be selectable from the compact composer menu.")
        XCTAssertTrue(composerModelButton.label.contains("VibeThinker"), "Switching back to Local should restore the safe local default.")
        capture("09-composer-provider-switching-native", app: app)
    }

    func testStreamingKeepsBottomPinnedDuringLiveResponse() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-streaming"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let liveResponse = liveStreamingReadableContent(in: app)
        XCTAssertTrue(liveResponse.waitForExistence(timeout: 8))
        sleep(2)
        XCTAssertFalse(jumpToLatestButton(in: app).exists, "Live streaming should stay pinned at the bottom without asking the user to manually jump to latest.")
        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
        let liveBubble = app.otherElements["liveStreamingBubble"]
        XCTAssertTrue(liveBubble.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(liveResponse.frame.maxY, bottomAccessory.frame.minY - 4, "Pinned streaming output should stay readable above the run/composer stack.")
        XCTAssertLessThanOrEqual(liveBubble.frame.maxY, bottomAccessory.frame.minY - 4, "The live bubble itself should not continue behind the run/composer stack.")
        capture("23-streaming-bottom-pinned", app: app)

        let progressToggle = runProgressToggle(in: app)
        XCTAssertTrue(progressToggle.waitForExistence(timeout: 5))
        progressToggle.tap()
        XCTAssertTrue(app.otherElements["runControlDrawer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Run Control"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Running Tool"].waitForExistence(timeout: 5))
        let activeToolDetail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Rendering batch'")).firstMatch
        XCTAssertTrue(activeToolDetail.waitForExistence(timeout: 5), "Expanded progress should resize with and expose the current streaming/tool detail.")
        let latestTrace = app.staticTexts["latestTraceEventTitle"]
        XCTAssertTrue(latestTrace.waitForExistence(timeout: 5), "Expanded progress should expose a stable newest trace row for UI tests and VoiceOver.")
        XCTAssertTrue(latestTrace.label.contains("Stream batch"), "Expanded progress should show the growing stream/tool trace as the newest row; got '\(latestTrace.label)'.")
        capture("24-streaming-tool-trace-growth", app: app)
    }

    func testChatLayoutContractKeepsStreamingReadableWithFocusedComposer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-streaming", "--keyboard-long-composer-demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let liveResponse = liveStreamingReadableContent(in: app)
        XCTAssertTrue(liveResponse.waitForExistence(timeout: 8))

        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        let keyboardVisible = keyboard.waitForExistence(timeout: 4)

        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3), "Chat should expose one measured bottom accessory for composer, run controls, and jump affordances.")
        let sendButton = app.buttons["sendMessageButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3))
        if keyboardVisible {
            assertKeyboardComposerChrome(in: app, keyboard: keyboard, sendButton: sendButton)
        } else {
            assertComposerDockAligned(in: app)
        }

        let liveBubble = app.otherElements["liveStreamingBubble"]
        XCTAssertTrue(liveBubble.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(liveResponse.frame.maxY, bottomAccessory.frame.minY - 4, "Pinned streaming output should stay readable above the full bottom accessory stack.")
        XCTAssertLessThanOrEqual(liveBubble.frame.maxY, bottomAccessory.frame.minY - 4, "The focused-composer live bubble should not flow under the bottom accessory stack.")
        XCTAssertFalse(jumpToLatestButton(in: app).exists, "A focused composer should not show Jump to Latest while the transcript remains pinned.")
        capture("29-chat-layout-contract-keyboard-streaming", app: app)
    }

    func testStreamingAllowsIntentionalScrollAwayAndJumpBackToLatest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-streaming"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(liveStreamingReadableContent(in: app).waitForExistence(timeout: 8))
        let chatScroll = app.scrollViews["chatTranscriptScroll"]
        XCTAssertTrue(chatScroll.waitForExistence(timeout: 5))

        let pullStart = chatScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let pullEnd = chatScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        pullStart.press(forDuration: 0.15, thenDragTo: pullEnd)
        let latestButton = jumpToLatestButton(in: app)
        let latestAppeared = latestButton.waitForExistence(timeout: 4)
        capture("25-streaming-user-scroll-detached", app: app)
        XCTAssertTrue(latestAppeared, "A deliberate user scroll away from a live response should reveal Jump to Latest instead of being auto-forced back down.")
        sleep(1)
        XCTAssertTrue(latestButton.exists, "Pending live-stream resize scrolls must not cancel an intentional user scroll-away.")

        latestButton.tap()
        XCTAssertFalse(jumpToLatestButton(in: app).waitForExistence(timeout: 2), "Tapping Jump to Latest should repin the live response and hide the jump button.")
        XCTAssertTrue(liveStreamingReadableContent(in: app).waitForExistence(timeout: 5))
        capture("26-streaming-jumped-back-latest", app: app)
    }

    func testLocalNativeToolPlanScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--local-agent-boundary-test"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "3 visible steps")).firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Write File"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Validate HTML"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["File Info"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Playable game ready")).firstMatch.waitForExistence(timeout: 8))
        capture("19-local-native-tool-plan", app: app)

        let progressToggle = runProgressToggle(in: app)
        XCTAssertTrue(progressToggle.waitForExistence(timeout: 5))
        progressToggle.tap()
        XCTAssertTrue(app.otherElements["runControlDrawer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Run Control"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Progress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Workspace"].waitForExistence(timeout: 5))
        assertMinimumTouchTarget(app.buttons["progressFilesButton"], named: "Run Control Files shortcut")
        assertMinimumTouchTarget(app.buttons["progressRunsButton"], named: "Run Control Runs shortcut")
        XCTAssertFalse(app.buttons["progressTerminalButton"].exists, "Run Control should keep Terminal agent-only instead of surfacing it as a user shortcut.")
        let runControlTitle = app.staticTexts["Run Control"]
        XCTAssertTrue(runControlTitle.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(runControlTitle.frame.minY, 58, "Expanded progress drawer should not overlap the iPhone status bar/clock.")
        capture("37-run-progress-expanded", app: app)
    }

    func testPendingApprovalApproveClearsSheetAndCompletesRun() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--pending-approval-demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Review this action"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["approval-demo.html"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Approval needed: Write File"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["approvalHumanReadableFields"].waitForExistence(timeout: 5), "Approval sheets should summarize tool, risk, affected target, and reason before raw arguments.")
        XCTAssertTrue(app.buttons["Reject Change"].waitForExistence(timeout: 5), "Approval sheet should use a specific user-facing Reject action.")
        let approvalRowText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Waiting approval to edit approval-demo.html")).firstMatch
        XCTAssertTrue(approvalRowText.waitForExistence(timeout: 5), "Approval tool calls should appear as compact inline activity, not only as a modal prompt.")
        XCTAssertTrue(app.staticTexts["Approval"].waitForExistence(timeout: 5), "The approval strip should expose a small plain-language status label.")
        let approvalActivityRow = app.descendants(matching: .any).matching(identifier: "toolActivityRow").firstMatch
        XCTAssertTrue(approvalActivityRow.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(approvalActivityRow.frame.height, 44, "Pending approval activity should stay close to one compact line.")
        XCTAssertFalse(app.staticTexts["Tool Center"].exists, "Approval state should not revive the old large debug panel.")
        capture("51-pending-approval-sheet", app: app)

        app.buttons["Approve Change"].tap()
        XCTAssertFalse(app.staticTexts["Review this action"].waitForExistence(timeout: 2), "Approval sheet should dismiss immediately after approve.")
        XCTAssertTrue(app.staticTexts["Run complete"].waitForExistence(timeout: 10), "Approved local tool run should complete instead of leaving pending approval stuck.")
        XCTAssertFalse(app.staticTexts["Approval needed: Write File"].waitForExistence(timeout: 1), "Pending approval label should clear after approve.")

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.otherElements["runsAuditDashboard"].waitForExistence(timeout: 5))
        let searchField = app.textFields["runsSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("approval-demo.html")
        if app.keyboards.firstMatch.exists {
            searchField.typeText("\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "Runs search keyboard should dismiss before inspecting approval proof.")
        }
        XCTAssertTrue(app.staticTexts["1 shown"].waitForExistence(timeout: 5), "Approved write should leave one searchable durable run proof.")
        XCTAssertTrue(app.staticTexts["Wrote file"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "approval-demo.html")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 5), "Approved write run should finish as durable completed proof.")

        let approvedRun = app.buttons["runHistoryCard"].firstMatch
        XCTAssertTrue(approvedRun.waitForExistence(timeout: 5))
        approvedRun.tap()
        XCTAssertTrue(app.buttons["runToggleArguments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["runToggleOutput"].waitForExistence(timeout: 5))
        app.buttons["runToggleOutput"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Wrote approval-demo.html")).firstMatch.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(app.buttons["runToggleArguments"], named: "approval run arguments disclosure")
        assertMinimumTouchTarget(app.buttons["runToggleOutput"], named: "approval run output disclosure")
        capture("53-approved-tool-run-complete", app: app)
    }

    func testRunControlShowsSinglePrimaryArtifactHandoff() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--artifact-dedupe-demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Playable game ready")).firstMatch.waitForExistence(timeout: 8))

        let progressToggle = runProgressToggle(in: app)
        XCTAssertTrue(progressToggle.waitForExistence(timeout: 5))
        progressToggle.tap()
        XCTAssertTrue(app.otherElements["runControlDrawer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready to play"].waitForExistence(timeout: 5))

        let primaryOpen = app.buttons["artifactPrimaryOpenButton"]
        XCTAssertTrue(primaryOpen.waitForExistence(timeout: 5), "Single-artifact runs should expose the generated file as the primary Open action.")
        let duplicateStripButton = app.descendants(matching: .any).matching(identifier: "artifactSecondaryOpenButton").firstMatch
        XCTAssertFalse(duplicateStripButton.exists, "A single generated artifact should not also appear in a secondary Changed strip.")
        XCTAssertFalse(app.staticTexts["Changed"].exists, "The drawer should not show an empty or duplicate Changed section for one artifact.")

        capture("35-artifact-dedupe-drawer", app: app)
    }

    func testArtifactPreviewStudioModes() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--local-agent-boundary-test"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Playable game ready")).firstMatch.waitForExistence(timeout: 8))

        let progressToggle = runProgressToggle(in: app)
        XCTAssertTrue(progressToggle.waitForExistence(timeout: 5))
        progressToggle.tap()
        XCTAssertTrue(app.otherElements["runControlDrawer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready to play"].waitForExistence(timeout: 5), "Completed artifact runs should have a clear primary handoff section, not only raw tool rows.")
        let primaryArtifactOpen = app.buttons["artifactPrimaryOpenButton"]
        XCTAssertTrue(primaryArtifactOpen.waitForExistence(timeout: 5), "Run Control should expose a large Open button for the generated artifact.")
        let duplicateArtifactStripButton = app.descendants(matching: .any).matching(identifier: "artifactSecondaryOpenButton").firstMatch
        XCTAssertFalse(duplicateArtifactStripButton.exists, "A single generated artifact should not appear twice as both the primary handoff and a Changed strip chip.")

        if primaryArtifactOpen.isHittable {
            primaryArtifactOpen.tap()
        } else {
            // Xcode 26 can report this SwiftUI button as a PopUpButton in the legacy
            // accessibility snapshot even though it is visible and tappable. Keep the
            // focused visual test moving by tapping the stable primary handoff location.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.26)).tap()
        }
        capture("42-artifact-button-tapped", app: app)
        let previewStudio = app.descendants(matching: .any).matching(identifier: "artifactPreviewStudio").firstMatch
        let normalPreviewLabel = app.staticTexts["Normal preview"]
        let swiftGamePreview = app.descendants(matching: .any).matching(identifier: "swiftGamePreviewPlayer").firstMatch
        let previewShareButton = identifiedElement("artifactShareButton", in: app)
        let previewFullScreenButton = identifiedElement("artifactFullScreenButton", in: app)
        let previewCloseButton = identifiedElement("artifactCloseButton", in: app)
        let previewReloadButton = identifiedElement("artifactReloadButton", in: app)
        XCTAssertTrue(
            previewStudio.waitForExistence(timeout: 4) ||
                normalPreviewLabel.waitForExistence(timeout: 8) ||
                swiftGamePreview.waitForExistence(timeout: 8) ||
                previewShareButton.waitForExistence(timeout: 8),
            "Artifact preview studio should be visible after opening the artifact. On iOS 26 fullScreenCover can expose the visible SwiftUI container under a non-Other accessibility type, so the visible Normal preview label is the fallback proof."
        )
        XCTAssertTrue(previewStudio.exists || normalPreviewLabel.waitForExistence(timeout: 5) || swiftGamePreview.waitForExistence(timeout: 5) || previewShareButton.exists)
        assertMinimumTouchTarget(previewShareButton, named: "artifact preview share")
        assertMinimumTouchTarget(previewFullScreenButton, named: "artifact preview full screen")
        assertMinimumTouchTarget(previewCloseButton, named: "artifact preview close")
        assertMinimumTouchTarget(previewReloadButton, named: "artifact preview reload")
        XCTAssertFalse(app.buttons["artifactViewportFit"].exists, "Release artifact viewer should not show a mode picker.")
        XCTAssertFalse(app.buttons["artifactViewportPortrait"].exists, "Release artifact viewer should not show a portrait mode button.")
        XCTAssertFalse(app.buttons["artifactViewportLandscape"].exists, "Release artifact viewer should not show a landscape mode button.")
        Thread.sleep(forTimeInterval: 1.0)
        capture("43-artifact-preview-normal", app: app)

        app.buttons["artifactFullScreenButton"].tap()
        let fullScreenSurface = app.descendants(matching: .any).matching(identifier: "artifactGameFullScreen").firstMatch
        XCTAssertTrue(fullScreenSurface.waitForExistence(timeout: 12), "Fullscreen container should appear")
        XCUIDevice.shared.orientation = .landscapeRight
        Thread.sleep(forTimeInterval: 0.8)
        let fullscreenFrame = fullScreenSurface.frame
        let screenFrame = app.frame
        XCTAssertGreaterThan(fullscreenFrame.width, fullscreenFrame.height, "Artifact fullscreen should be physically wider than tall after landscape reload.")
        XCTAssertGreaterThan(screenFrame.width, screenFrame.height, "App window should report a landscape frame before fullscreen proof captures.")
        XCTAssertEqual(fullscreenFrame.width, screenFrame.width, accuracy: 2.0, "Artifact fullscreen should fill the landscape window width.")
        XCTAssertEqual(fullscreenFrame.height, screenFrame.height, accuracy: 2.0, "Artifact fullscreen should fill the landscape window height.")
        Thread.sleep(forTimeInterval: 1.0)
        let fullscreenProof = capture("46-artifact-preview-studio-fullscreen", app: app)
        assertFullBleedLandscapeScreenshot(fullscreenProof)
        XCTAssertFalse(app.buttons["artifactFullScreenButton"].waitForExistence(timeout: 1), "Fullscreen should not leave the preview header/chrome visible above the game.")
        XCTAssertFalse(app.buttons["artifactViewportFit"].exists, "Fullscreen should hide fit/portrait/landscape preview controls.")
        if app.buttons["artifactExitFullScreenButton"].exists {
            assertMinimumTouchTarget(app.buttons["artifactExitFullScreenButton"], named: "artifact fullscreen exit")
        }

        let exitButtons = app.buttons.matching(identifier: "artifactExitFullScreenButton")
        if exitButtons.count > 0 {
            exitButtons.firstMatch.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.045, dy: 0.10)).tap()
        }
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertGreaterThan(app.frame.height, app.frame.width, "Exiting artifact fullscreen should restore the portrait app frame.")
        let restoredFullScreenSurface = app.descendants(matching: .any).matching(identifier: "artifactGameFullScreen").firstMatch
        XCTAssertFalse(restoredFullScreenSurface.waitForExistence(timeout: 1), "Landscape fullscreen surface should be gone after tapping the X.")
        capture("46c-artifact-preview-studio-exit-restored-portrait", app: app)
        app.terminate()
    }

    func testLocalWebArtifactCreatesPreviewableLandingPage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--local-web-artifact-test"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Local web artifact ready")).firstMatch.waitForExistence(timeout: 8))
        let finalMessage = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Local web artifact ready")).firstMatch
        let progressSummary = runProgressToggle(in: app)
        XCTAssertTrue(finalMessage.waitForExistence(timeout: 5))
        XCTAssertTrue(progressSummary.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertLessThanOrEqual(
            finalMessage.frame.maxY,
            progressSummary.frame.minY - 8,
            "Completed-run summary should keep the final assistant handoff readable above the composer/progress dock instead of covering it."
        )
        capture("70-local-web-artifact-run-complete", app: app)

        progressSummary.tap()
        XCTAssertTrue(app.otherElements["runControlDrawer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready to open"].waitForExistence(timeout: 5), "Landing-page artifacts should be framed as preview/open handoffs, not playable game handoffs.")
        XCTAssertFalse(app.staticTexts["Ready to play"].exists, "Landing-page artifacts should not be mislabeled as games.")

        let primaryArtifactOpen = app.buttons["artifactPrimaryOpenButton"]
        XCTAssertTrue(primaryArtifactOpen.waitForExistence(timeout: 5), "Single web-page artifacts should open from the primary Run Control handoff.")
        let secondaryArtifactOpen = app.descendants(matching: .any).matching(identifier: "artifactSecondaryOpenButton").firstMatch
        XCTAssertFalse(secondaryArtifactOpen.exists, "A single web-page artifact should not also appear in the secondary artifact strip.")
        if primaryArtifactOpen.isHittable {
            primaryArtifactOpen.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.26)).tap()
        }

        XCTAssertTrue(app.otherElements["artifactPreviewStudio"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["cron-18-landing.html"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Normal preview"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["artifactViewportLandscape"].exists, "Local web artifact preview should no longer expose confusing landscape mode controls.")
        capture("71-local-web-artifact-normal-preview", app: app)
    }

    func testTerminalLongOutputProgressiveDisclosure() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-terminal", "--stress-terminal"]
        app.launch()

        XCTAssertFalse(app.tabBars.buttons["More"].exists)
        XCTAssertFalse(app.tabBars.buttons["Term"].exists)
        let expandButton = app.buttons["terminalOutputExpand"].firstMatch
        XCTAssertTrue(expandButton.waitForExistence(timeout: 5))
        capture("13-terminal-long-output-collapsed", app: app)

        expandButton.tap()
        XCTAssertTrue(app.buttons["terminalOutputCollapse"].firstMatch.waitForExistence(timeout: 5))
        capture("14-terminal-long-output-expanded", app: app)
        app.scrollViews.firstMatch.swipeUp()
        capture("36-terminal-expanded-scrolled", app: app)
    }

    func testNetworkFailureResetsForNextMessage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--simulate-network-failure"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Run failed"].waitForExistence(timeout: 6))
        let failedRunProgressToggle = runProgressToggle(in: app)
        XCTAssertTrue(failedRunProgressToggle.waitForExistence(timeout: 5), "Chat should expose failed-run recovery in the bottom Run Control bar.")
        assertMinimumTouchTarget(failedRunProgressToggle, named: "Run Control failed-run toggle")
        XCTAssertFalse(app.otherElements["projectStatusBoard"].waitForExistence(timeout: 1), "Chat should not show a duplicate Project Status board when Run Control already owns the failed runtime state.")
        failedRunProgressToggle.tap()
        XCTAssertTrue(app.otherElements["runControlDrawer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Run Control"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Retry"].waitForExistence(timeout: 5), "Run Control should keep the recovery action visible after suppressing duplicate Project Status.")
        capture("34-network-failure-state", app: app)
        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("list files")
        app.buttons["sendMessageButton"].tap()
        XCTAssertFalse(app.staticTexts["Run failed"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Run complete"].waitForExistence(timeout: 8))
        capture("35-network-recovery-complete", app: app)

        composer.tap()
        composer.typeText("next draft")
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "Completed-run chrome should clear out while the user starts a fresh draft in the composer.")
        XCTAssertFalse(self.runProgressToggle(in: app).exists, "Completed-run progress toggle should not crowd a focused composer draft.")
    }

    func testNetworkFailureFocusKeepsRetryUntilFreshDraftStarts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--simulate-network-failure"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Run failed"].waitForExistence(timeout: 6))
        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        XCTAssertTrue(app.staticTexts["Run failed"].waitForExistence(timeout: 2), "Focusing the composer should not erase Retry/Clear recovery state before the user starts a new draft.")
        capture("36-network-failure-focus-keeps-retry", app: app)

        composer.typeText("list files")
        XCTAssertFalse(app.staticTexts["Run failed"].waitForExistence(timeout: 2), "Starting a fresh draft should clear the stale failure banner before send.")
    }

    func testNewChatClearsRecoveredFailureBanner() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--simulate-network-failure"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Run failed"].waitForExistence(timeout: 12))
        app.buttons["New chat"].tap()

        let title = app.staticTexts["currentChatTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Run failed"].waitForExistence(timeout: 1), "A recovered failure banner should not bleed into a newly selected chat.")
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))
        capture("49-new-chat-clears-failure-banner", app: app)
    }

    func testNewChatDuringActiveResponseDoesNotHijackOutput() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--active-status-strip", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let runningTitle = app.staticTexts["currentChatTitle"].label
        XCTAssertTrue(app.staticTexts["Release check running"].waitForExistence(timeout: 5))

        app.buttons["New chat"].tap()

        XCTAssertNotEqual(app.staticTexts["currentChatTitle"].label, runningTitle, "Creating a new chat should switch selection without moving the active response.")
        let activeElsewhereDock = app.buttons["activeResponseElsewhereDock"]
        XCTAssertTrue(activeElsewhereDock.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["activeResponseElsewhereCard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Active response"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Running in")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sendMessageButton"].isEnabled, "A new selected chat should not queue prompts into a different chat's active response.")
        capture("52-active-response-owned-by-original-chat", app: app)

        activeElsewhereDock.tap()

        XCTAssertTrue(app.staticTexts["Release check running"].waitForExistence(timeout: 5), "Opening the running chat should return to the original active response instead of moving it.")
        XCTAssertEqual(app.staticTexts["currentChatTitle"].label, runningTitle)
        XCTAssertFalse(app.otherElements["activeResponseElsewhereCard"].exists)
        capture("52b-active-response-returned-original-chat", app: app)
    }

    func testFirstRunChatIsCleanScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["firstRunProjectLauncher"].exists)
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists)
        capture("69-clean-first-run-chat", app: app)
    }

    func testGoalMatrixChatReadabilityAndThemeSwitchingScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--theme-world=matrixRain", "--pending-approval-demo", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let assistantApproval = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "I need approval before writing"))
            .firstMatch
        XCTAssertTrue(assistantApproval.waitForExistence(timeout: 8), "Matrix chat should keep assistant bubbles readable over the rain backdrop.")
        XCTAssertTrue(app.buttons["Approve Change"].waitForExistence(timeout: 5), "Approval controls should stay readable and tappable in Matrix mode.")
        capture("goal-matrix-chat-readable", app: app)

        app.terminate()
        app.launchArguments = ["--reset-ui", "--theme-world=matrixRain"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Control"].tap()
        let midnightTheme = identifiedElement("settingsThemeRow-midnightBlack", in: app)
        scrollUntilHittable(midnightTheme, in: app)
        XCTAssertTrue(midnightTheme.isHittable, "Midnight theme row should be reachable from Settings.")
        midnightTheme.tap()
        capture("goal-theme-switched-midnight-settings", app: app)

        app.tabBars.buttons["Forge"].tap()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5), "Chat should return as a readable clean surface after leaving Matrix.")
        capture("goal-theme-switched-midnight-chat", app: app)
    }

    func testGoalProjectControlCenterCreateEditDeleteAndRunFeedbackScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-project", "--open-mission-dossier-demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["NovaForge Project"].waitForExistence(timeout: 8), "Project should open to the active project control center.")
        capture("goal-project-control-center-idle", app: app)

        app.terminate()
        app.launchArguments = ["--reset-ui", "--open-project", "--open-mission-dossier-demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["NovaForge Project"].waitForExistence(timeout: 8))
        identifiedElement("projectPinnedSwitcherButton", in: app).tap()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 5))
        if identifiedElement("projectNewButton", in: app).waitForExistence(timeout: 2), identifiedElement("projectNewButton", in: app).isHittable {
            identifiedElement("projectNewButton", in: app).tap()
        } else {
            app.staticTexts["Create Project"].tap()
        }

        let kindField = identifiedTextInput("projectIntakeProjectKindField", in: app)
        XCTAssertTrue(kindField.waitForExistence(timeout: 5))
        kindField.tap()
        kindField.typeText("Arcade Memory Lab")
        let platformField = identifiedTextInput("projectIntakePlatformField", in: app)
        XCTAssertTrue(platformField.waitForExistence(timeout: 5))
        platformField.tap()
        platformField.typeText("iPhone")
        capture("goal-project-intake-filled", app: app)

        app.buttons["Create"].tap()
        let createdProjectName = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "Arcade Memory Lab"))
            .firstMatch
        XCTAssertTrue(createdProjectName.waitForExistence(timeout: 8), "Creating a project should select the project built from the intake brief.")
        XCTAssertFalse(app.staticTexts["Arcade Memory Lab"].exists && app.tabBars.buttons["Forge"].isSelected, "Project creation should stay in Project instead of dumping a raw chat prompt.")

        app.buttons["Project actions"].tap()
        XCTAssertTrue(app.buttons["Edit Project"].waitForExistence(timeout: 5))
        app.buttons["Edit Project"].tap()
        XCTAssertTrue(app.staticTexts["Edit Project"].waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedTextInput("projectEditNameField", in: app).waitForExistence(timeout: 5))
        capture("goal-project-edit-sheet", app: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Edit Project"].waitForNonExistence(timeout: 5))

        app.buttons["Project actions"].tap()
        XCTAssertTrue(app.buttons["Delete Project"].waitForExistence(timeout: 5))
        app.buttons["Delete Project"].tap()
        XCTAssertTrue(app.buttons["Delete Project"].waitForExistence(timeout: 5))
        app.buttons["Delete Project"].tap()
        let activeName = identifiedElement("projectOSProjectName", in: app)
        XCTAssertTrue(activeName.waitForExistence(timeout: 8))
        XCTAssertFalse(activeName.label.contains("Arcade Memory Lab"), "Deleting the active project should fall back to a safe remaining project.")
        capture("goal-project-delete-fallback", app: app)
    }

    func testProjectCreationAndSingleActionSurfaceScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-project", "--open-mission-dossier-demo"]
        app.launch()

        func projectSwipeUp() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        func dismissProjectSwitcherSheet() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.90))
            start.press(forDuration: 0.05, thenDragTo: end)
            if app.staticTexts["Projects"].exists {
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }

        XCTAssertTrue(app.otherElements["projectOSControlCenter"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.otherElements["missionOSPanel"].exists, "Mission OS details should stay behind More so Project opens clean.")
        XCTAssertFalse(app.otherElements["projectLatestEvidenceSection"].exists, "Empty proof should not clutter the first Project viewport.")
        XCTAssertTrue(app.buttons["projectPinnedSwitcherButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projectPinnedRunButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["projectNextStepReason"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["projectExpectedProof"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["projectApprovalExpectation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["projectHeroDraftButton"].exists, "Project OS should expose one primary Run action, not a competing Draft action.")
        assertMinimumTouchTarget(app.buttons["projectPinnedSwitcherButton"], named: "Project switcher sheet")
        XCTAssertFalse(app.otherElements["projectSwitcherPanel"].exists, "Project switcher should live in the glass sheet, not the main Project scroll.")
        XCTAssertFalse(app.otherElements["projectCommandCenter"].exists, "Project OS should not expose a manual command chooser on first load.")
        XCTAssertFalse(app.descendants(matching: .any)["projectMetricGrid"].exists, "Metrics should not make the initial Project tab visually busy.")
        XCTAssertFalse(app.otherElements["projectCommandMenu"].exists, "Project screen should not duplicate bottom-tab route actions in a second command menu.")
        for identifier in ["projectMenuButton-Chat", "projectMenuButton-Files", "projectMenuButton-Runs"] {
            XCTAssertFalse(app.buttons[identifier].exists, "Duplicate route action should be removed: \(identifier)")
        }
        capture("90-project-creation-single-action", app: app)

        app.buttons["projectPinnedSwitcherButton"].tap()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Create Project"].waitForExistence(timeout: 5), "Project creation should read like an intentional SwiftUI mission card, not a random tiny plus row.")
        let newProjectButton = app.descendants(matching: .any)["projectNewButton"]
        if newProjectButton.waitForExistence(timeout: 2) {
            assertMinimumTouchTarget(newProjectButton, named: "Polished Create Project card")
        }
        capture("90b-project-switcher-sheet", app: app)

        if newProjectButton.exists && newProjectButton.isHittable {
            newProjectButton.tap()
        } else {
            app.staticTexts["Create Project"].tap()
        }
        XCTAssertTrue(app.staticTexts["Project 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["projectOSControlCenter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projectPinnedRunButton"].waitForExistence(timeout: 5), "Project hero should keep the single primary run action available after creating a project.")
        XCTAssertFalse(app.buttons["projectContinueButton"].exists, "The old Continue Project action should not reappear alongside the new hero action.")
        XCTAssertFalse(app.otherElements["projectCommandMenu"].exists, "Command Menu should stay removed after creating a project.")
        capture("91-project2-created-single-action-switcher", app: app)

        app.buttons["projectPinnedSwitcherButton"].tap()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 5))
        let activeProjectRow = app.descendants(matching: .any)["projectSwitcherActiveRow"]
        XCTAssertTrue(activeProjectRow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["projectSwitcherActiveRow"].exists, "The selected project row should be a read-only selected state, not a no-op button.")
        dismissProjectSwitcherSheet()
        XCTAssertTrue(app.staticTexts["Projects"].waitForNonExistence(timeout: 3))

        let moreButton = app.buttons["projectMoreButton"]
        if !moreButton.isHittable {
            projectSwipeUp()
        }
        XCTAssertTrue(moreButton.waitForExistence(timeout: 5))
        moreButton.tap()
        XCTAssertTrue(app.otherElements["projectMoreDetails"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["missionOSPanel"].waitForExistence(timeout: 5), "Mission OS details should be available inside More.")
        XCTAssertTrue(app.otherElements["projectLatestEvidenceSection"].waitForExistence(timeout: 5), "Proof details should be available inside More.")
        XCTAssertFalse(app.otherElements["projectCommandCenter"].exists, "More should reveal evidence and gates, not manual command choices.")
        XCTAssertTrue(app.descendants(matching: .any)["projectMetricGrid"].waitForExistence(timeout: 5), "Metrics should remain available in More without crowding the initial Project tab.")
        XCTAssertFalse(app.otherElements["projectCommandMenu"].exists, "Scrolling should not reveal duplicate Chat/Files/Runs/Terminal action cards.")
        capture("92-project-no-duplicate-command-menu", app: app)
    }

    func testProjectTabCreatesAndSwitchesProjectsScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-project", "--open-mission-dossier-demo"]
        app.launch()

        func projectSwipeDown() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            start.press(forDuration: 0.05, thenDragTo: end)
        }

        func dismissProjectSwitcherSheet() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.90))
            start.press(forDuration: 0.05, thenDragTo: end)
            if app.staticTexts["Projects"].exists {
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }

        func openProjectSwitcher() {
            let switcherButton = app.buttons["projectPinnedSwitcherButton"]
            for _ in 0..<5 where !switcherButton.isHittable {
                projectSwipeDown()
            }
            XCTAssertTrue(switcherButton.waitForExistence(timeout: 5))
            XCTAssertTrue(switcherButton.isHittable, "Project switcher control should be reachable from the Project hero.")
            switcherButton.tap()
            XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 5))
        }

        XCTAssertTrue(app.otherElements["projectOSControlCenter"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.otherElements["missionOSPanel"].exists, "Project tab should keep deeper Mission OS detail collapsed by default.")
        XCTAssertFalse(app.otherElements["projectLatestEvidenceSection"].exists, "Project tab should not show empty proof cards on first load.")
        XCTAssertTrue(app.descendants(matching: .any)["projectStatusPill"].waitForExistence(timeout: 5), "Project hero should show a compact project status pill.")
        XCTAssertFalse(app.otherElements["projectSwitcherPanel"].exists, "Project switcher should not sit inside the main scroll.")
        XCTAssertFalse(app.otherElements["projectTimelineSection"].exists, "Full timeline should stay collapsed until More is opened.")
        capture("82-project-briefing-default", app: app)

        openProjectSwitcher()
        let newProjectButton = app.descendants(matching: .any)["projectNewButton"]
        if newProjectButton.waitForExistence(timeout: 2) {
            assertMinimumTouchTarget(newProjectButton, named: "New Project")
        }

        if newProjectButton.exists && newProjectButton.isHittable {
            newProjectButton.tap()
        } else {
            app.staticTexts["Create Project"].tap()
        }
        XCTAssertTrue(app.staticTexts["Project 2"].waitForExistence(timeout: 5), "Creating a project should immediately select and show the new project.")
        openProjectSwitcher()
        let selectedProjectRow = app.descendants(matching: .any)["projectSwitcherActiveRow"]
        XCTAssertTrue(selectedProjectRow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["projectSwitcherActiveRow"].exists, "The selected project row should not remain tappable after creating a project.")
        dismissProjectSwitcherSheet()
        XCTAssertTrue(app.staticTexts["Projects"].waitForNonExistence(timeout: 3))

        capture("83-project-created-switcher", app: app)
        openProjectSwitcher()
        let defaultProjectRow = app.staticTexts["projectSwitcherRowName-Default"]
        XCTAssertTrue(defaultProjectRow.waitForExistence(timeout: 5), "The original default project should remain available to switch back to.")
        capture("83-project-created-switcher", app: app)

        defaultProjectRow.tap()
        XCTAssertTrue(app.staticTexts["NovaForge Project"].waitForExistence(timeout: 5), "Switching projects should restore the selected project header.")
        capture("84-project-switched-default", app: app)

        openProjectSwitcher()
        let projectTwoRow = app.staticTexts["projectSwitcherRowName-Project-2"]
        XCTAssertTrue(projectTwoRow.waitForExistence(timeout: 5), "Project 2 should remain available after switching back to the default project.")
        projectTwoRow.tap()
        XCTAssertTrue(app.staticTexts["Project 2"].waitForExistence(timeout: 5))

        let runButton = app.buttons["projectPinnedRunButton"]
        for _ in 0..<5 where !runButton.isHittable {
            projectSwipeDown()
        }
        XCTAssertTrue(runButton.waitForExistence(timeout: 5), "Project hero should expose the primary run action.")
        XCTAssertTrue(runButton.isHittable, "Project hero run should be reachable after returning to the top of Project.")
        capture("85-project-continue-action", app: app)
        runButton.tap()

        XCTAssertTrue(app.otherElements["projectDashboard"].waitForExistence(timeout: 5), "Project Run should keep Project OS as the execution surface.")
        XCTAssertTrue(app.otherElements["projectOSControlCenter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["projectPinnedRunButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 1), "Project Run should not force a hidden chat handoff.")
        XCTAssertFalse(app.buttons["projectHeroDraftButton"].exists, "Project OS should continue to expose one primary Run action after execution starts.")
        capture("86-project-run-stays-on-project-os", app: app)
    }

    func testAccessibilityLayoutTouchTargetsAndCompactLabels() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["firstRunProjectLauncher"].exists)
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists)

        let headerTitle = app.staticTexts["currentChatTitle"].firstMatch
        assertHeaderAnchoredNearTop(headerTitle, in: app, message: "Header title should stay below the top safe area without drifting into the status bar.")
        assertMinimumTouchTarget(app.buttons["Open chats"], named: "Open chats")
        assertMinimumTouchTarget(app.buttons["New chat"], named: "New chat")
        assertReadableLabel(app.buttons["Open chats"], named: "Open chats")
        assertReadableLabel(app.buttons["New chat"], named: "New chat")

        for tab in ["Forge", "Workspace", "History", "Control"] {
            let tabButton = app.tabBars.buttons[tab]
            XCTAssertTrue(tabButton.waitForExistence(timeout: 5), "\(tab) tab should keep its compact label visible on iPhone 12 before the keyboard intentionally hides the tab dock.")
            assertMinimumTouchTarget(tabButton, named: "\(tab) tab")
            XCTAssertFalse(tabButton.label.contains("..."), "\(tab) tab label should be intentionally compact, not ellipsized.")
        }
        XCTAssertFalse(app.tabBars.buttons["More"].exists, "The bottom dock should not collapse Settings and Terminal into a cheap More tab.")
        XCTAssertFalse(app.tabBars.buttons["Term"].exists, "Terminal should be agent-only instead of taking a public dock slot.")

        app.buttons["Open chats"].tap()
        let drawerTitle = app.staticTexts["chatDrawerTitle"]
        XCTAssertTrue(drawerTitle.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(drawerTitle.frame.minY, 58, "Chat drawer should clear the iPhone 12 status bar/notch area.")
        assertMinimumTouchTarget(app.buttons["chatDrawerClose"], named: "chat drawer close")
        assertMinimumTouchTarget(app.buttons["chatDrawerNewChat"], named: "chat drawer new chat")
        let rowActions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chatDrawerRowActions-")).firstMatch
        XCTAssertTrue(rowActions.waitForExistence(timeout: 5), "Chat drawer rows should expose a stable actions button for Rename/Delete proof.")
        assertMinimumTouchTarget(rowActions, named: "chat drawer row actions")
        assertReadableLabel(rowActions, named: "chat drawer row actions")
        rowActions.tap()
        let deleteMenuItem = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 5), "Chat row Delete should be reachable from the stable actions menu.")
        deleteMenuItem.tap()
        XCTAssertTrue(app.staticTexts["Delete Chat?"].waitForExistence(timeout: 5), "Deleting a chat should require confirmation instead of removing history immediately.")
        XCTAssertTrue(app.buttons["Delete Chat"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(rowActions.waitForExistence(timeout: 5), "Canceling chat delete should keep the drawer and row actions visible.")
        capture("73-accessibility-chat-drawer-controls", app: app)
        app.buttons["chatDrawerClose"].tap()

        app.tabBars.buttons["Workspace"].tap()
        XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
        for identifier in ["filesGoUpButton", "filesLayoutToggle", "filesSearchButton", "filesWorkspaceMenu", "filesCreateFileButton"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 5), "\(identifier) should expose a stable accessibility identifier.")
            assertMinimumTouchTarget(control, named: identifier)
            assertReadableLabel(control, named: identifier)
        }
        capture("74-accessibility-files-action-bar", app: app)

        app.tabBars.buttons["Forge"].tap()
        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(composerModelControl(in: app), named: "composer model picker")
        XCTAssertFalse(app.buttons["composerFilesDockButton"].exists, "Files should stay out of the composer dock; the tab bar and progress shortcuts own that navigation.")
        XCTAssertFalse(app.buttons["composerTerminalDockButton"].exists, "Terminal should stay agent-only instead of cluttering the composer dock.")

        composer.tap()
        composer.typeText("accessibility target proof")
        assertMinimumTouchTarget(app.buttons["sendMessageButton"], named: "Send message")
        capture("70-accessibility-touch-targets-chat", app: app)
    }

    func testTerminalAndRunsControlsKeepAccessibleHitAreas() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-terminal", "--stress-terminal"]
        app.launch()

        XCTAssertFalse(app.tabBars.buttons["More"].exists)
        XCTAssertFalse(app.tabBars.buttons["Term"].exists)
        XCTAssertTrue(app.otherElements["terminalCommandDeck"].waitForExistence(timeout: 5))
        for (command, identifier) in [("ls", "terminalPreset-ls"), ("pwd", "terminalPreset-pwd"), ("find .", "terminalPreset-find-.")] {
            let preset = app.buttons[identifier]
            XCTAssertTrue(preset.waitForExistence(timeout: 5), "Terminal preset \(command) should be visible.")
            assertMinimumTouchTarget(preset, named: "terminal preset \(command)")
        }
        assertMinimumTouchTarget(app.buttons["terminalOutputExpand"], named: "terminal output expand")
        assertMinimumTouchTarget(app.buttons["terminalCopyOutput"], named: "terminal copy output")
        assertMinimumTouchTarget(app.buttons["terminalHistoryButton"], named: "terminal history")
        assertMinimumTouchTarget(app.buttons["terminalRunButton"], named: "terminal run")
        assertMinimumTouchTarget(app.buttons["terminalClearConsoleButton"], named: "terminal clear console")

        let searchToggle = app.buttons["terminalSearchToggle"]
        XCTAssertTrue(searchToggle.waitForExistence(timeout: 5), "Terminal search toggle should expose a stable accessibility identifier.")
        assertMinimumTouchTarget(searchToggle, named: "terminal search toggle")
        searchToggle.tap()
        let searchField = app.textFields["terminalConsoleSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Expanded terminal search should expose a stable text field.")
        assertMinimumTouchTarget(searchField, named: "terminal search field")

        let commandInput = app.textFields["terminalCommandInput"]
        XCTAssertTrue(commandInput.waitForExistence(timeout: 5))
        commandInput.tap()
        commandInput.typeText("p")
        let autocomplete = app.buttons["terminalAutocomplete-pwd"]
        XCTAssertTrue(autocomplete.waitForExistence(timeout: 5), "Typing a command prefix should expose a phone-sized autocomplete suggestion.")
        assertMinimumTouchTarget(autocomplete, named: "terminal autocomplete pwd")
        assertReadableLabel(autocomplete, named: "terminal autocomplete pwd")
        capture("71-accessibility-terminal-targets", app: app)
    }

    func testWorkspaceStatusStripControlsExposePhoneSizedTargets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--active-status-strip"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        func assertWorkspaceStatusControls(on surface: String) {
            XCTAssertTrue(app.otherElements["workspaceStatusStrip"].waitForExistence(timeout: 5), "Workspace status should be visible on \(surface) while a run is active.")

            let pauseButton = app.buttons["workspaceStatusPauseButton"]
            XCTAssertTrue(pauseButton.waitForExistence(timeout: 5), "Active workspace status should expose a stable pause control on \(surface).")
            assertMinimumTouchTarget(pauseButton, named: "workspace status pause on \(surface)")
            assertReadableLabel(pauseButton, named: "workspace status pause on \(surface)")

            let openChatButton = app.buttons["workspaceStatusOpenChatButton"]
            XCTAssertTrue(openChatButton.waitForExistence(timeout: 5), "Workspace status should expose a stable return-to-chat control on \(surface).")
            assertMinimumTouchTarget(openChatButton, named: "workspace status open chat on \(surface)")
            assertReadableLabel(openChatButton, named: "workspace status open chat on \(surface)")
        }

        app.tabBars.buttons["Workspace"].tap()
        XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
        assertWorkspaceStatusControls(on: "Files")
        capture("75-accessibility-workspace-status-strip-files", app: app)

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.otherElements["runsAuditDashboard"].waitForExistence(timeout: 5))
        assertWorkspaceStatusControls(on: "Runs")
        capture("76-accessibility-workspace-status-strip-runs", app: app)

        app.tabBars.buttons["Forge"].tap()
        XCTAssertTrue(app.otherElements["projectOSControlCenter"].waitForExistence(timeout: 5))
        assertWorkspaceStatusControls(on: "Project")
        capture("77-accessibility-workspace-status-strip-project", app: app)
    }

    func testRunsControlsKeepAccessibleHitAreas() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-chat"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.otherElements["runsAuditDashboard"].waitForExistence(timeout: 5))
        for label in ["All", "Writes", "Failures"] {
            let filter = app.buttons[label]
            XCTAssertTrue(filter.waitForExistence(timeout: 5), "Runs filter \(label) should be visible.")
            assertMinimumTouchTarget(filter, named: "runs filter \(label)")
        }

        let firstRunCard = app.buttons["runHistoryCard"].firstMatch
        XCTAssertTrue(firstRunCard.waitForExistence(timeout: 5), "Seeded run history should expose a tappable run card.")
        firstRunCard.tap()

        let deleteLog = app.buttons["runDeleteLogButton"]
        XCTAssertTrue(deleteLog.waitForExistence(timeout: 5), "Expanded run cards should expose a visible delete action.")
        assertMinimumTouchTarget(deleteLog, named: "run delete log")
        deleteLog.tap()
        XCTAssertTrue(app.staticTexts["Delete this run log?"].waitForExistence(timeout: 5), "Run log deletion should require confirmation instead of removing audit history immediately.")
        let confirmDeleteLog = app.buttons["Delete Log"].firstMatch
        XCTAssertTrue(confirmDeleteLog.waitForExistence(timeout: 5), "The confirmation sheet should expose an explicit destructive Delete Log action.")
        confirmDeleteLog.tap()
        XCTAssertTrue(app.otherElements["runsAuditDashboard"].waitForExistence(timeout: 5), "Confirming run-log delete should return to the Runs dashboard instead of leaving the sheet stuck.")
        XCTAssertTrue(app.buttons["runHistoryCard"].firstMatch.waitForExistence(timeout: 5), "Deleting one seeded log should keep the rest of the run history visible.")
        capture("72-accessibility-runs-targets", app: app)
    }

    func testFilesVisibleActionsDuplicateAndConfirmDelete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--files-actions-test"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Workspace"].tap()
        XCTAssertTrue(app.staticTexts["notes.md"].waitForExistence(timeout: 8))
        capture("80-files-actions-before", app: app)

        let sourceEdit = app.buttons["fileEdit-Actions-notes-md"]
        XCTAssertTrue(sourceEdit.waitForExistence(timeout: 5), "Every file row should keep one visible primary action for the safest next step.")
        assertMinimumTouchTarget(sourceEdit, named: "notes.md edit action")
        XCTAssertFalse(app.buttons["fileDuplicate-Actions-notes-md"].exists, "Duplicate should live behind the row overflow so Files stays calm.")
        XCTAssertFalse(app.buttons["fileDelete-Actions-notes-md"].exists, "Delete should live behind the row overflow so destructive actions are not first-viewport clutter.")

        let sourceMoreActions = app.buttons["fileMoreActions-Actions-notes-md"]
        XCTAssertTrue(sourceMoreActions.waitForExistence(timeout: 5), "File rows should expose secondary actions through a visible overflow button.")
        assertMinimumTouchTarget(sourceMoreActions, named: "notes.md more actions")
        sourceMoreActions.tap()
        XCTAssertTrue(app.buttons["Duplicate"].waitForExistence(timeout: 5), "Overflow should still expose duplicate without hiding it in a context-only gesture.")
        app.buttons["Duplicate"].tap()
        XCTAssertTrue(app.staticTexts["notes_copy.md"].waitForExistence(timeout: 8), "Duplicate should create a non-destructive unique copy next to the source file.")
        capture("81-files-actions-duplicated", app: app)

        let copyMoreActions = app.buttons["fileMoreActions-Actions-notes_copy-md"]
        XCTAssertTrue(copyMoreActions.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(copyMoreActions, named: "notes_copy.md more actions")
        copyMoreActions.tap()
        XCTAssertTrue(app.buttons["Delete File"].waitForExistence(timeout: 5), "Overflow should still expose delete after an explicit secondary-action tap.")
        app.buttons["Delete File"].tap()
        XCTAssertTrue(app.staticTexts["Delete notes_copy.md?"].waitForExistence(timeout: 5), "Delete should require confirmation before removing a workspace file.")
        capture("82-files-actions-delete-confirm", app: app)
        let confirmDeleteFile = app.buttons.matching(identifier: "confirmDeleteFileButton").firstMatch
        XCTAssertTrue(confirmDeleteFile.waitForExistence(timeout: 5), "The confirmation dialog should expose a stable destructive confirmation action.")
        confirmDeleteFile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["fileMoreActions-Actions-notes_copy-md"].waitForNonExistence(timeout: 8), "Confirmed delete should remove only the duplicate file row.")
        XCTAssertTrue(app.staticTexts["notes.md"].exists, "Deleting the copy must not remove the original file.")
        capture("83-files-actions-after-delete", app: app)
    }

    private func assertFullBleedLandscapeScreenshot(
        _ image: UIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let proofImage = normalizedForProof(image)
        guard let cgImage = proofImage.cgImage else {
            XCTFail("Could not read fullscreen screenshot pixels.", file: file, line: line)
            return
        }

        let width = cgImage.width
        let height = cgImage.height
        XCTAssertGreaterThan(width, height, "Fullscreen proof screenshot should be written and analyzed as a real landscape image, not a portrait-oriented PNG.", file: file, line: line)

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Could not create pixel context for fullscreen screenshot.", file: file, line: line)
            return
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var nonBlackCount = 0
        var trailingSamples = 0
        var trailingNonBlack = 0
        let step = 3
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let index = y * bytesPerRow + x * bytesPerPixel
                let brightestChannel = Swift.max(data[index], Swift.max(data[index + 1], data[index + 2]))
                let isNonBlack = brightestChannel > 25
                if isNonBlack {
                    nonBlackCount += 1
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }

                let isTrailingLongAxis = width >= height ? x >= (width * 2 / 3) : y >= (height * 2 / 3)
                if isTrailingLongAxis {
                    trailingSamples += 1
                    if isNonBlack { trailingNonBlack += 1 }
                }
            }
        }

        XCTAssertGreaterThan(nonBlackCount, 0, "Fullscreen screenshot should contain visible game pixels.", file: file, line: line)
        let bboxLongSpan = width >= height ? (maxX - minX + 1) : (maxY - minY + 1)
        let longAxis = max(width, height)
        let bboxLongAxisCoverage = CGFloat(bboxLongSpan) / CGFloat(longAxis)
        let trailingCoverage = CGFloat(trailingNonBlack) / CGFloat(max(1, trailingSamples))
        XCTAssertGreaterThanOrEqual(
            bboxLongAxisCoverage,
            0.92,
            "Fullscreen game content should span most of the landscape long axis, not a portrait-width strip. coverage=\(bboxLongAxisCoverage)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            trailingCoverage,
            0.70,
            "Fullscreen game content should reach the visual right third/trailing landscape area, not leave it black. coverage=\(trailingCoverage)",
            file: file,
            line: line
        )
    }

    @discardableResult
    private func capture(_ name: String, app: XCUIApplication) -> UIImage {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["NOVAFORGE_SCREENSHOT_DIR"] ??
            environment["TEST_RUNNER_NOVAFORGE_SCREENSHOT_DIR"] ??
            fallbackScreenshotDirectory()

        guard !directory.isEmpty else {
            let screenshot = app.screenshot()
            let image = normalizedForProof(screenshot.image)
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return image
        }

        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(sanitizedDeviceName())-\(name).png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let screenshot = XCUIScreen.main.screenshot()
        let normalized = normalizedForProof(screenshot.image)
        if let pngData = normalized.pngData() {
            try? pngData.write(to: url)
        } else {
            try? screenshot.pngRepresentation.write(to: url)
        }

        let metadataURL = url.deletingPathExtension().appendingPathExtension("txt")
        let shouldProbeFullscreen = name.localizedCaseInsensitiveContains("fullscreen") ||
            name.localizedCaseInsensitiveContains("exit-restored")
        let fullScreenMetadata: String
        if shouldProbeFullscreen {
            let fullScreen = app.otherElements["artifactGameFullScreen"]
            let exit = app.buttons["artifactExitFullScreenButton"]
            fullScreenMetadata = """
            artifactGameFullScreen.exists=\(fullScreen.exists)
            artifactGameFullScreen.frame=\(fullScreen.exists ? String(describing: fullScreen.frame) : "missing")
            artifactExitFullScreenButton.exists=\(exit.exists)
            artifactExitFullScreenButton.frame=\(exit.exists ? String(describing: exit.frame) : "missing")
            """
        } else {
            fullScreenMetadata = "artifact fullscreen probes skipped for non-fullscreen capture\n"
        }
        let metadata = """
        app.frame=\(app.frame)
        firstWindow.frame=\(app.windows.firstMatch.frame)
        \(fullScreenMetadata)orientation=\(UIDevice.current.orientation.rawValue)
        screen=\(normalized.size)
        """
        try? metadata.write(to: metadataURL, atomically: true, encoding: .utf8)
        return normalized
    }

    private func normalizedForProof(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func tapButtonOrCoordinate(
        _ button: XCUIElement,
        in app: XCUIApplication,
        normalizedOffset: CGVector,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if button.waitForExistence(timeout: 2), button.isHittable {
            button.tap()
        } else {
            app.coordinate(withNormalizedOffset: normalizedOffset).tap()
        }
    }

    private func assertMinimumTouchTarget(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let minimumMeasuredTarget: CGFloat = 43.5
        XCTAssertTrue(element.waitForExistence(timeout: 3), "\(name) should exist before measuring its hit area.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.width, minimumMeasuredTarget, "\(name) should be about 44pt wide for reliable touch.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, minimumMeasuredTarget, "\(name) should be about 44pt tall for reliable touch.", file: file, line: line)
    }

    private func assertReadableLabel(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(name) should keep a VoiceOver label.", file: file, line: line)
        XCTAssertFalse(element.label.contains("..."), "\(name) label should not be visibly ellipsized.", file: file, line: line)
    }

    private func assertHeaderAnchoredNearTop(
        _ headerTitle: XCUIElement,
        in app: XCUIApplication,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let maxHeaderMinY = min(max(app.frame.height * 0.10, 104), 140)
        XCTAssertLessThan(headerTitle.frame.minY, maxHeaderMinY, message, file: file, line: line)
    }

    private func composerModelControl(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["composerModelNativeMenu"]
        if button.exists { return button }
        return app.descendants(matching: .any)["composerModelNativeMenu"]
    }

    private func runProgressToggle(in app: XCUIApplication) -> XCUIElement {
        let identifiedElement = app.descendants(matching: .any).matching(identifier: "runProgressToggle").firstMatch
        if identifiedElement.exists { return identifiedElement }
        return app.buttons["runProgressToggle"].firstMatch
    }

    private func jumpToLatestButton(in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons["jumpToLatest"]
        if button.exists { return button }
        let identifiedElement = app.descendants(matching: .any).matching(identifier: "jumpToLatest").firstMatch
        if identifiedElement.exists { return identifiedElement }
        return app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Latest")).firstMatch
    }

    private func liveStreamingReadableContent(in app: XCUIApplication) -> XCUIElement {
        let statusText = app.staticTexts["liveStreamingStatusText"]
        if statusText.exists { return statusText }
        let identifiedStatus = app.descendants(matching: .staticText).matching(identifier: "liveStreamingStatusText").firstMatch
        if identifiedStatus.exists { return identifiedStatus }
        return app.staticTexts
            .containing(NSPredicate(format: "label == %@ OR label == %@", "Showing latest", "Responding"))
            .firstMatch
    }

    private func visibleElementCount(_ query: XCUIElementQuery) -> Int {
        query.allElementsBoundByIndex.filter { element in
            element.exists && !element.frame.isEmpty
        }.count
    }

    private func visibleStaticTextCount(in app: XCUIApplication, containing text: String) -> Int {
        app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", text))
            .allElementsBoundByIndex
            .filter { element in
                element.exists && !element.frame.isEmpty
            }
            .count
    }

    private func bottomChatAccessory(in app: XCUIApplication) -> XCUIElement {
        let matches = app.descendants(matching: .any)
            .matching(identifier: "chatBottomAccessory")
            .allElementsBoundByIndex
            .filter { $0.exists && !$0.frame.isEmpty }
        return matches.min { $0.frame.minY < $1.frame.minY } ?? app.otherElements["chatBottomAccessory"].firstMatch
    }

    private func chatComposerInput(in app: XCUIApplication) -> XCUIElement {
        let textField = app.textFields["chatComposer"]
        if textField.exists { return textField }
        return app.textViews["chatComposer"]
    }

    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let directButton = app.buttons[identifier]
        if directButton.exists { return directButton }
        let directOther = app.otherElements[identifier]
        if directOther.exists { return directOther }
        let directStaticText = app.staticTexts[identifier]
        if directStaticText.exists { return directStaticText }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func identifiedTextInput(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let textField = app.textFields[identifier]
        if textField.exists { return textField }
        let textView = app.textViews[identifier]
        if textView.exists { return textView }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        for _ in 0..<maxSwipes where !element.isHittable {
            app.swipeUp()
        }
    }

    private func composerDock(in app: XCUIApplication) -> XCUIElement {
        let labeledPredicate = NSPredicate(
            format: "identifier == %@ AND label == %@",
            "chatComposerDock",
            "Chat composer dock"
        )
        let dock = app.otherElements.matching(labeledPredicate).firstMatch
        if dock.exists { return dock }
        let anyDock = app.descendants(matching: .any).matching(labeledPredicate).firstMatch
        if anyDock.exists { return anyDock }
        let fallbackDock = app.otherElements.matching(identifier: "chatComposerDock").element(boundBy: 0)
        if fallbackDock.exists { return fallbackDock }
        return chatComposerInput(in: app)
    }

    private func hasComposerDockContainer(in app: XCUIApplication) -> Bool {
        let labeledPredicate = NSPredicate(
            format: "identifier == %@ AND label == %@",
            "chatComposerDock",
            "Chat composer dock"
        )
        return app.otherElements.matching(labeledPredicate).firstMatch.exists ||
        app.descendants(matching: .any).matching(labeledPredicate).firstMatch.exists ||
        app.otherElements.matching(identifier: "chatComposerDock").element(boundBy: 0).exists
    }

    private func assertComposerDockAligned(in app: XCUIApplication) {
        let hasDockContainer = hasComposerDockContainer(in: app)
        let dock = composerDock(in: app)
        XCTAssertTrue(dock.waitForExistence(timeout: 3), "Composer dock should expose a stable geometry container for keyboard/safe-area checks.")
        let send = app.buttons["sendMessageButton"]
        XCTAssertTrue(send.waitForExistence(timeout: 3), "Send button should stay visible in the composer dock.")
        XCTAssertGreaterThanOrEqual(send.frame.width, 44, "Send should keep a reliable tap target even when visually quiet.")
        XCTAssertGreaterThanOrEqual(send.frame.height, 44, "Send should keep a reliable tap target even when visually quiet.")
        XCTAssertLessThanOrEqual(send.frame.width, 54, "Send should stay an icon-sized command, not grow into a toolbar button.")
        XCTAssertLessThanOrEqual(send.frame.height, 54, "Send should stay visually compact inside the typing lane.")
        XCTAssertFalse(app.buttons["composerFilesDockButton"].exists, "Files should not clutter the typing dock.")
        XCTAssertFalse(app.buttons["composerTerminalDockButton"].exists, "Terminal should not clutter the typing dock.")

        let dockFrame = dock.frame
        let dockFrameIsFinite = dockFrame.minX.isFinite &&
            dockFrame.maxX.isFinite &&
            dockFrame.width.isFinite &&
            dockFrame.minX > -app.frame.maxX &&
            dockFrame.maxX < app.frame.maxX * 2 &&
            dockFrame.width > 0
        if dockFrameIsFinite {
            XCTAssertGreaterThanOrEqual(dockFrame.minX, 12, "Composer dock should stay inside the compact iPhone leading safe edge.")
            XCTAssertLessThanOrEqual(dockFrame.maxX, app.frame.maxX - 12, "Composer dock should stay inside the compact iPhone trailing edge.")
        }
        if hasDockContainer, dockFrameIsFinite {
            XCTAssertLessThanOrEqual(send.frame.maxX, dockFrame.maxX - 6, "Send button should remain inside the composer safe trailing edge.")
        } else {
            XCTAssertLessThanOrEqual(send.frame.maxX, app.frame.maxX - 12, "Send button should remain inside the screen safe trailing edge.")
        }
    }

    private func assertNoFloatingActionsOverComposer(in app: XCUIApplication) {
        XCTAssertFalse(app.buttons["quickAction-inspect"].exists, "Inspect quick action should not compete with the focused composer.")
        XCTAssertFalse(app.buttons["quickAction-plan"].exists, "Plan quick action should not compete with the focused composer.")
        XCTAssertFalse(app.buttons["quickAction-search"].exists, "Search quick action should not compete with the focused composer.")
        XCTAssertFalse(jumpToLatestButton(in: app).exists, "Jump to Latest should not compete with the focused composer.")
    }

    private func assertKeyboardComposerChrome(in app: XCUIApplication, keyboard: XCUIElement, sendButton: XCUIElement) {
        let hasDockContainer = hasComposerDockContainer(in: app)
        let dock = composerDock(in: app)
        XCTAssertTrue(dock.waitForExistence(timeout: 3), "Composer dock should be visible while the keyboard is up.")
        XCTAssertLessThanOrEqual(dock.frame.maxY, keyboard.frame.minY - 8, "The whole composer dock, not only the text field, should clear the keyboard/predictive bar.")
        XCTAssertLessThanOrEqual(keyboard.frame.minY - dock.frame.maxY, 88, "Keyboard should not leave a large dead spacer below the composer dock.")
        XCTAssertGreaterThanOrEqual(sendButton.frame.minX, dock.frame.midX, "Send button should stay in the right half of the compact composer.")
        if hasDockContainer {
            XCTAssertLessThanOrEqual(sendButton.frame.maxX, dock.frame.maxX - 6, "Send button should stay inside the composer safe trailing edge.")
        } else {
            XCTAssertLessThanOrEqual(sendButton.frame.maxX, app.frame.maxX - 12, "Send button should stay inside the screen safe trailing edge.")
        }

        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            XCTAssertFalse(tabBar.isHittable, "Bottom tab bar should not remain tappable over the keyboard/composer stack.")
        }
    }

    private func fallbackScreenshotDirectory() -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NovaForgeScreenshots", isDirectory: true)
            .appendingPathComponent("ui-tests", isDirectory: true)
            .path
    }

    private func sanitizedDeviceName() -> String {
        let allowed = CharacterSet.alphanumerics
        return UIDevice.current.name.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
    }
}
