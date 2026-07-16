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
        app.launchArguments = ["--reset-ui", "--debug-provider-list-ready", "--open-chat"]
        app.launch()
        let title = app.staticTexts["currentChatTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "New chat")

        app.buttons["New chat"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertNotEqual(title.label, "NovaForge Ready")

        app.terminate()
        app.launchArguments = ["--debug-provider-list-ready", "--open-chat"]
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "New chat", "Launch should reopen a fresh ready chat, not the same old working chat.")
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
        XCTAssertTrue(identifiedElement("firstRunPowerUp", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Power up NovaForge"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["firstRunPowerUpButton"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(identifiedElement("firstRunPowerUp", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Power up NovaForge"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["LOCAL SETUP"].waitForExistence(timeout: 5))
        let download = app.buttons["firstRunPowerUpButton"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(download, named: "Download local model")

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
        app.launchArguments = ["--reset-ui", "--debug-provider-list-ready", "--open-chat"]
        app.launch()
        let title = app.staticTexts["currentChatTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        waitForDebugProviderFixture(in: app)

        app.buttons["New chat"].tap()
        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("list files")
        tapReadySendButton(in: app)
        let completion = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Workspace scan finished")).firstMatch
        XCTAssertTrue(completion.waitForExistence(timeout: 8), "The deterministic run should finish with a durable assistant handoff.")
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "Completed work should not leave a second persistent Run complete bar above the composer.")
        XCTAssertFalse(runProgressToggle(in: app).exists, "Completed work belongs in the transcript and History, not a persistent bottom run control.")

        app.terminate()
        app.launchArguments = ["--debug-provider-list-ready", "--open-chat"]
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
        XCTAssertTrue(identifiedElement("firstRunPowerUp", in: app).waitForExistence(timeout: 8), "Cold launch should return to the local-first setup surface instead of reopening an interrupted draft.")
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
        composer.typeText("Show me your tools")
        assertNoFloatingActionsOverComposer(in: app)
        let keyboard = app.keyboards.firstMatch
        let keyboardVisible = keyboard.waitForExistence(timeout: 3)
        let sendButton = app.buttons["Send message"]
        let modelPicker = app.descendants(matching: .any)["composerModelNativeMenu"]
        if modelPicker.waitForExistence(timeout: 1) {
            XCTAssertTrue(modelPicker.label.localizedCaseInsensitiveContains("Choose model"), "The compact model icon should keep a complete VoiceOver label.")
            XCTAssertGreaterThanOrEqual(modelPicker.frame.width, 43.5, "The compact model icon should retain a reliable touch target.")
            XCTAssertGreaterThanOrEqual(modelPicker.frame.width, 120, "The idle model control should keep provider and model context readable.")
            XCTAssertLessThanOrEqual(modelPicker.frame.width, 180, "The idle model control should remain a compact pill instead of becoming a toolbar.")
        }
        let composerDock = composerDock(in: app)
        XCTAssertTrue(composerDock.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(composerDock.frame.height, 128, "A normal prompt should stay inside the compact unified composer.")
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

        tapReadySendButton(in: app)
        if keyboardVisible {
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3), "Sending from the focused composer should dismiss the keyboard cleanly.")
        }
        XCTAssertGreaterThanOrEqual(composerDock.frame.maxY, app.frame.maxY - 180, "After the keyboard dismisses, the composer should settle near the bottom instead of floating where the keyboard was.")
        let sentMessage = app.staticTexts["Show me your tools"].firstMatch
        XCTAssertTrue(sentMessage.waitForExistence(timeout: 3), "Sent prompt should remain visible in the transcript.")
        XCTAssertLessThanOrEqual(sentMessage.frame.maxY, composerDock.frame.minY - 8, "Latest messages should remain readable above the composer after sending.")
        XCTAssertFalse(
            runProgressToggle(in: app).exists,
            "A failed canonical run should stay in the transcript and recovery strip instead of adding a second persistent Run Control bar."
        )
        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
        let bottomAccessoryTop = bottomAccessory.frame.minY
        XCTAssertLessThanOrEqual(sentMessage.frame.maxY, bottomAccessoryTop - 8, "Sent prompt should clear the full run/action accessory, not only the composer.")
        let assistantMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "provider connection failed")).firstMatch
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5), "Assistant response should remain visible after Send.")
        XCTAssertLessThanOrEqual(assistantMessage.frame.maxY, bottomAccessoryTop - 8, "Assistant output should stay readable above the full bottom accessory stack.")
        XCTAssertFalse(app.otherElements["liveResponseField"].waitForExistence(timeout: 2), "Failed send should clear live response state.")
        sleep(1)
        capture("03-agent-typing", app: app)
    }

    func testForgeChatSendStreamsOneAssistantBubbleAndClearsRunningState() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-ui",
            "--debug-provider-send-ready",
            "--open-chat",
            "--ui-test-observable-stream",
            "--performance-mode"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))

        waitForDebugProviderFixture(in: app)

        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Yo")
        tapReadySendButton(in: app)

        let userText = app.staticTexts["Yo"].firstMatch
        XCTAssertTrue(userText.waitForExistence(timeout: 5), "User message should appear immediately after Send.")

        let liveField = app.otherElements["liveResponseField"]
        XCTAssertTrue(liveField.waitForExistence(timeout: 4), "Streaming response should render as one live typefield.")
        XCTAssertLessThanOrEqual(visibleElementCount(app.otherElements.matching(identifier: "liveResponseField")), 1, "Streaming should update one live field instead of adding duplicates.")
        let liveBottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(liveBottomAccessory.waitForExistence(timeout: 3), "Bottom accessory should be measurable while the live response is streaming.")
        // Geometry has dedicated long-lived layout coverage. This send-flow
        // fixture intentionally may finish between two XCTest snapshots, so
        // never dereference the transient live element after existence proof.
        capture("sev0-chat-send-stream-live", app: app)

        let assistantResponse = app.otherElements.matching(identifier: "chatAssistantResponse").firstMatch
        XCTAssertTrue(assistantResponse.waitForExistence(timeout: 35), "Final assistant response should replace the deliberately paced live stream in the transcript.")
        XCTAssertFalse(liveField.exists, "Live field should clear as soon as the final response is visible.")
        XCTAssertEqual(visibleElementCount(app.otherElements.matching(identifier: "chatAssistantResponse")), 1, "Assistant output should appear once, not as live plus final duplicates.")
        let assistantText = assistantResponse.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "Hey! I’m on it"))
            .firstMatch
        XCTAssertTrue(assistantText.waitForExistence(timeout: 2), "Completed assistant bubble should contain the provider response, not only live-stream text.")
        XCTAssertEqual(visibleStaticTextCount(in: app, containing: "Hey! I’m on it"), 1, "Provider text should not duplicate as a real assistant output and a live response.")

        let userBubble = app.otherElements.matching(identifier: "chatUserMessageBubble").firstMatch
        if userBubble.exists && !userBubble.frame.isEmpty {
            XCTAssertFalse(userBubble.frame.intersects(assistantResponse.frame), "User and assistant responses must not visually overlap when both remain in the rendered window.")
        }

        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(assistantResponse.frame.maxY, bottomAccessory.frame.minY - 4, "Auto-scroll should keep the latest response readable above the composer.")
        let assistantDockGap = bottomAccessory.frame.minY - assistantResponse.frame.maxY
        XCTAssertGreaterThanOrEqual(assistantDockGap, 4, "Auto-scroll should not tuck the latest assistant response under the composer.")
        XCTAssertLessThanOrEqual(assistantDockGap, 96, "Auto-scroll should land on the latest assistant response, not an invisible spacer below the transcript.")
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "Completed work should not leave a persistent Run complete bar above the composer.")
        XCTAssertFalse(runProgressToggle(in: app).exists, "Completed work should return Forge to its compact idle composer instead of retaining Run Control.")
        let completedDock = composerDock(in: app)
        XCTAssertTrue(completedDock.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(completedDock.frame.height, 128, "Completion should collapse back to the compact unified composer.")
        assertContained(completedDock, in: bottomAccessory, named: "completed composer dock")
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

        waitForDebugProviderFixture(in: app)

        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("Trigger a timeout")
        tapReadySendButton(in: app)

        let errorText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "provider connection failed")).firstMatch
        XCTAssertTrue(errorText.waitForExistence(timeout: 10), "Failed provider send should show a visible transcript error.")
        XCTAssertTrue(
            app.staticTexts["Trigger a timeout"].firstMatch.waitForExistence(timeout: 10),
            "Failed send should still keep the durable user bubble after the error is projected."
        )
        XCTAssertFalse(app.otherElements["liveResponseField"].waitForExistence(timeout: 2), "Failure should clear live streaming UI.")

        composer.tap()
        composer.typeText("Recover after timeout")
        XCTAssertTrue(app.buttons["sendMessageButton"].isEnabled, "Composer should re-enable after failure once the user types again.")
        capture("sev0-chat-send-failure-recovered", app: app)
    }

    func testChatComposerExpandsForLongTextAndStaysAboveKeyboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-chat", "--settings-local-model-ready"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))

        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["chatComposer"].exists, "Chat should start with the same multiline-capable text field it keeps for long drafts.")
        composer.tap()
        let singleLineHeight = composer.frame.height
        let longDraft = "Build me a smooth native iPhone app with a glassy chat composer that expands over multiple lines without jumping above the keyboard"
        composer.typeText(longDraft)
        assertNoFloatingActionsOverComposer(in: app)

        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 1) {
            composer.tap()
        }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields["chatComposer"].exists, "Expanding a draft must preserve the original text-field identity.")
        XCTAssertFalse(app.textViews["chatComposer"].exists, "Long drafts should not swap the focused text field for a TextEditor.")
        let expandedComposer = chatComposerInput(in: app)
        XCTAssertTrue(expandedComposer.waitForExistence(timeout: 3))
        XCTAssertEqual(expandedComposer.value as? String, longDraft, "The stable composer should preserve the exact long draft while its height changes.")
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
        app.launchArguments = ["--reset-ui", "--keyboard-multiline-draft-demo", "--settings-local-model-ready", "--open-chat"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))

        let composer = chatComposerInput(in: app)
        let initialDock = composerDock(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(initialDock.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        if !keyboard.waitForExistence(timeout: 1) {
            composer.tap()
        }
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
        let scopeMenu = identifiedElement("chatProjectScopeMenu", in: app)
        XCTAssertTrue(scopeMenu.waitForExistence(timeout: 5))
        scopeMenu.tap()
        let projectChoice = app.buttons["NovaForge Project"].firstMatch
        XCTAssertTrue(projectChoice.waitForExistence(timeout: 5), "The scope menu should expose the default project.")
        projectChoice.tap()
        let dossierShortcut = identifiedElement("missionDossierShortcut", in: app)
        XCTAssertTrue(dossierShortcut.waitForExistence(timeout: 5), "Forge should expose a direct Mission Dossier shortcut instead of forcing a slow scope menu round-trip.")
        dossierShortcut.tap()
        XCTAssertTrue(app.otherElements["projectDashboard"].waitForExistence(timeout: 2), "Mission Dossier shortcut should mount the dashboard quickly.")
        XCTAssertTrue(app.buttons["missionDossierClose"].waitForExistence(timeout: 2))
        app.buttons["missionDossierClose"].tap()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))
        capture("43-four-tab-open-project-forge-route", app: app)

        app.terminate()
        app.launchArguments = ["--reset-ui", "--open-project", "--open-mission-dossier-demo"]
        app.launch()

        XCTAssertTrue(app.otherElements["projectDashboard"].waitForExistence(timeout: 8), "Mission Dossier should mount the project dashboard when explicitly requested.")
        let dossierClose = app.buttons["missionDossierClose"]
        XCTAssertTrue(dossierClose.waitForExistence(timeout: 5), "Mission dossier should expose a stable close control.")
        assertMinimumTouchTarget(dossierClose, named: "Mission dossier close")
        let dossierActions = app.buttons["projectPinnedActionsMenu"]
        XCTAssertTrue(dossierActions.waitForExistence(timeout: 5), "Project actions should remain reachable inside the dossier.")
        XCTAssertFalse(
            dossierClose.frame.intersects(dossierActions.frame),
            "Mission dossier Close must reserve its own header space instead of overlapping Project actions."
        )
        capture("44-mission-dossier-explicit-route", app: app)
        dossierClose.tap()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5), "Closing Mission Dossier should reveal Forge.")
    }

    func testMissionDossierPinnedActionsStayCompactWhenIdle() throws {
        let app = launchMissionDossierForPinnedDock()
        assertCompactMissionDossierDock("Idle", in: app)
        let run = identifiedElement("projectPinnedRunButton", in: app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "projectPinnedRunButton").count, 1)
        assertMinimumTouchTarget(run, named: "Idle Run")
        XCTAssertFalse(app.buttons["projectAutoContinuePauseButton"].exists)
        XCTAssertFalse(app.buttons["projectApprovalApproveButton"].exists)
        capture("44b-mission-dossier-compact-idle-dock", app: app)
    }

    func testMissionDossierPinnedActionsStayCompactDuringCountdown() throws {
        let app = launchMissionDossierForPinnedDock(["--auto-continue-countdown-demo"])
        assertCompactMissionDossierDock("Countdown", in: app)
        let pause = identifiedElement("projectAutoContinuePauseButton", in: app)
        let cancel = identifiedElement("projectAutoContinueCancelButton", in: app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "projectAutoContinuePauseButton").count, 1, "Countdown should have one Pause owner.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "projectAutoContinueCancelButton").count, 1, "Countdown should have one Cancel owner.")
        assertMinimumTouchTarget(pause, named: "Countdown Pause")
        assertMinimumTouchTarget(cancel, named: "Countdown Cancel")
        capture("44c-mission-dossier-compact-countdown-dock", app: app)
    }

    func testMissionDossierPinnedActionsStayCompactDuringApproval() throws {
        let app = launchMissionDossierForPinnedDock(["--project-waiting-demo"])
        assertCompactMissionDossierDock("Approval", in: app)
        let approve = identifiedElement("projectApprovalApproveButton", in: app)
        let reject = identifiedElement("projectApprovalRejectButton", in: app)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "projectApprovalApproveButton").count, 1, "Approval should have one Approve owner.")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "projectApprovalRejectButton").count, 1, "Approval should have one Reject owner.")
        assertMinimumTouchTarget(approve, named: "Approval Approve")
        assertMinimumTouchTarget(reject, named: "Approval Reject")
        XCTAssertFalse(app.buttons["projectPinnedRunButton"].exists, "Approval should not reuse the idle Run identifier.")
        capture("44d-mission-dossier-compact-approval-dock", app: app)
    }

    private func launchMissionDossierForPinnedDock(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-project", "--open-mission-dossier-demo"] + arguments
        app.launch()
        XCTAssertTrue(app.otherElements["projectDashboard"].waitForExistence(timeout: 8))
        return app
    }

    private func assertCompactMissionDossierDock(_ state: String, in app: XCUIApplication) {
        let dock = identifiedElement("projectPinnedActionDock", in: app)
        XCTAssertTrue(dock.waitForExistence(timeout: 5), "\(state) should expose the pinned action dock.")
        XCTAssertLessThanOrEqual(dock.frame.height, 128, "\(state) dock should remain compact on iPhone 12.")

        for scope in ["review", "plan", "evidence", "timeline"] {
            let tab = app.buttons["projectDetailScope-\(scope)"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            XCTAssertFalse(tab.frame.intersects(dock.frame), "\(state) dock must not cover Mission Dossier scope controls.")
        }
    }

    func testProjectLiquidGlassPerformanceTraceFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-project", "--open-mission-dossier-demo", "--profile-frame-rate", "--profile-events", "--performance-mode"]
        app.launch()

        let projectHero = app.otherElements["projectOSControlCenter"]
        XCTAssertTrue(projectHero.waitForExistence(timeout: 8), "Project dashboard proof now lives inside the Mission Dossier cover, not a public Project tab.")
        XCTAssertTrue(app.buttons["missionDossierClose"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["missionOSPanel"].exists)
        XCTAssertFalse(app.otherElements["projectLatestEvidenceSection"].exists)

        sleep(8)
        app.swipeUp()
        sleep(2)
        app.swipeDown()
        sleep(2)
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
        app.launchArguments = ["--reset-ui", "--stress-streaming", "--open-chat", "--profile-frame-rate", "--profile-events", "--performance-mode"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        // The canonical projection can mount after the app title is already
        // visible. Keep a full sustained window after the probe's warmup so
        // the gate always receives at least four chat-frame samples.
        sleep(8)
    }

    func testFilesShowsSeedReadme() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))

        let filesTab = app.tabBars.buttons["Workspace"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()

        XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
        let fileCell = app.buttons["fileOpen-README-md"]
        XCTAssertTrue(fileCell.waitForExistence(timeout: 5))
        fileCell.tap()

        sleep(1)
        capture("04-files-readme", app: app)
    }

    func testFilesStressListAndSearch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-files"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        let filesTab = app.tabBars.buttons["Workspace"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()

        XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement("filesStressFixtureReady", in: app).waitForExistence(timeout: 90), "Stress files should finish every durable mutation before navigation begins.")
        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["filesGoUpButton"].exists, "Workspace root should not waste a primary toolbar slot on a disabled Go up action.")
        XCTAssertFalse(app.buttons["filesBreadcrumb-home"].exists, "Workspace root should not repeat Home as a redundant breadcrumb.")
        let sourcesRow = app.buttons["fileOpen-Sources"]
        XCTAssertTrue(sourcesRow.waitForExistence(timeout: 5))
        XCTAssertLessThan(sourcesRow.frame.maxY, app.tabBars.firstMatch.frame.minY, "Workspace should expose real files in the first viewport instead of leading with a duplicate evidence dashboard.")
        XCTAssertFalse(app.otherElements["filesEvidenceWorkbenchOverview"].exists, "Workspace should not repeat the latest file in a large evidence dashboard before the browser.")
        XCTAssertFalse(app.otherElements["filesProvenanceHandoff"].exists, "Workspace should keep handoff details in evidence inspection instead of duplicating the first file above the browser.")
        sourcesRow.tap()
        XCTAssertTrue(app.buttons["filesGoUpButton"].waitForExistence(timeout: 5), "Folder navigation should reveal Go up only when it can act.")
        assertMinimumTouchTarget(app.buttons["filesGoUpButton"], named: "Files Go up")
        XCTAssertTrue(app.buttons["filesBreadcrumb-home"].waitForExistence(timeout: 5), "Opening a folder should reveal the Home breadcrumb.")
        assertMinimumTouchTarget(app.buttons["filesBreadcrumb-home"], named: "Files Home breadcrumb")
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
        app.launchArguments = ["--reset-ui", "--stress-files"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        let filesTab = app.tabBars.buttons["Workspace"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()

        XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedElement("filesStressFixtureReady", in: app).waitForExistence(timeout: 90), "Search controls should wait for every durable fixture mutation before opening.")
        XCTAssertFalse(app.buttons["filesBreadcrumb-home"].exists, "Workspace root should not repeat Home as a redundant breadcrumb.")
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
            let bottomAccessory = bottomChatAccessory(in: app)
            XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
            assertContained(latestButton, in: bottomAccessory, named: "Jump to Latest")
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
                let stressCheckpoint = app.staticTexts.containing(
                    NSPredicate(
                        format: "label CONTAINS %@",
                        "Stress window checkpoint"
                    )
                ).firstMatch
                XCTAssertTrue(
                    stressCheckpoint.waitForExistence(timeout: 5),
                    "Returning to Forge should preserve the selected stress conversation and its transcript."
                )
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
        XCTAssertTrue(identifiedElement("terminalCommandDeck", in: app).waitForExistence(timeout: 8))
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

        XCTAssertTrue(identifiedElement("terminalCommandDeck", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["terminalCommandSafetyStrip"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["terminalCommandSafetyLabel"].label, "Changes files")
        XCTAssertTrue(app.staticTexts["terminalCommandSafetyDetail"].label.contains("ask before running"))
        XCTAssertTrue(app.textFields["terminalCommandInput"].waitForExistence(timeout: 5))
        capture("70-terminal-safety-draft", app: app)

        app.buttons["terminalRunButton"].tap()
        let approval = app.otherElements["agentPolicyApprovalView"]
        XCTAssertTrue(approval.waitForExistence(timeout: 8), "File-changing terminal commands should enter the shared policy review surface.")
        XCTAssertTrue(app.staticTexts["Review change"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "paused until you approve or reject")).firstMatch.waitForExistence(timeout: 5),
            "The policy review should explain that execution is paused before the exact mutation."
        )
        capture("71-terminal-safety-confirmation", app: app)

        let reject = app.buttons["agentPolicyRejectButton"]
        XCTAssertTrue(reject.waitForExistence(timeout: 5))
        reject.tap()
        XCTAssertTrue(approval.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.textFields["terminalCommandInput"].waitForExistence(timeout: 5))
        let rejectedRecord = app.otherElements["terminalOutputRecord"]
        XCTAssertTrue(rejectedRecord.waitForExistence(timeout: 8), "Rejecting a mutation should leave a failed command receipt instead of silently dropping the decision.")
        XCTAssertTrue(app.staticTexts["$ rm README.md"].waitForExistence(timeout: 5))
    }

    func testTerminalQuickChecksAndUnsupportedCommandGuardScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-terminal", "--terminal-unsupported-demo"]
        app.launch()

        XCTAssertTrue(identifiedElement("terminalCommandDeck", in: app).waitForExistence(timeout: 8))
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

        XCTAssertTrue(identifiedElement("terminalCommandDeck", in: app).waitForExistence(timeout: 8))
        app.buttons["terminalPreset-pwd"].tap()
        XCTAssertTrue(app.staticTexts["terminalCommandSafetyLabel"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["terminalCommandSafetyLabel"].label, "Read-only command")
        app.buttons["terminalRunButton"].tap()
        XCTAssertFalse(app.otherElements["agentPolicyApprovalView"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["$ pwd"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["terminalOutputRecord"].waitForExistence(timeout: 5))
        capture("72-terminal-readonly-ran", app: app)
    }

    func testTerminalShowsLiveAgentCreatedRecordWhileOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-terminal", "--terminal-live-record-demo"]
        app.launch()

        XCTAssertTrue(identifiedElement("terminalCommandDeck", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["$ pwd"].waitForExistence(timeout: 8), "Agent-created terminal records should appear without reopening Terminal.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "agent live terminal sync proof")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["terminalOutputRecord"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["terminalEmptyState"].exists)
        capture("78-terminal-live-agent-record", app: app)
    }

    func testRunsShowsLinkedTerminalProofForAgentCommand() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-runs", "--terminal-live-record-demo"]
        app.launch()

        XCTAssertTrue(app.otherElements["historyToolbar"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["runHistoryCard"].firstMatch.waitForExistence(timeout: 8), "Agent-created command runs should appear in History after the terminal proof fixture saves.")
        XCTAssertTrue(app.descendants(matching: .any)["runTerminalProofBadge"].waitForExistence(timeout: 5), "The filtered command run should advertise terminal proof.")
        XCTAssertTrue(app.descendants(matching: .any)["runTerminalProofInline"].waitForExistence(timeout: 5), "Command runs should expose terminal proof directly on the row.")

        XCTAssertTrue(app.staticTexts["$ pwd"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "agent live terminal sync proof")).firstMatch.waitForExistence(timeout: 5))
        let openTerminal = app.buttons["runOpenTerminalRecord"].firstMatch
        XCTAssertTrue(openTerminal.waitForExistence(timeout: 5), "Linked terminal proof should offer a direct Terminal context.")
        assertMinimumTouchTarget(openTerminal, named: "run open terminal record")
        assertMinimumTouchTarget(app.buttons["runCopyTerminalCommand"], named: "run copy terminal command")
        assertMinimumTouchTarget(app.buttons["runCopyTerminalOutput"], named: "run copy terminal output")
        capture("79-runs-linked-terminal-proof", app: app)

        openTerminal.tap()
        XCTAssertTrue(identifiedElement("terminalCommandDeck", in: app).waitForExistence(timeout: 5), "Opening a linked proof should present the Terminal surface.")
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

        XCTAssertTrue(app.otherElements["historyToolbar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))
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

    func testLegacyV1BatchedToolCallsRemainAvailableForMigrationInspection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--stress-tool-batch", "--legacy-v1-tool-ui"]
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

    func testLegacyV1RunningToolCallRemainsCompactForMigrationInspection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--running-tool-call-demo", "--legacy-v1-tool-ui", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let summary = app.staticTexts.matching(identifier: "toolActivitySummary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Running tool calls should appear as one compact inline activity summary.")
        XCTAssertTrue(summary.label.contains("Working on 1 action"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "toolActivityRow").firstMatch.exists, "Raw tool rows should stay collapsed by default.")
        let detailToggle = app.buttons["toolBatchToggle"]
        XCTAssertTrue(detailToggle.waitForExistence(timeout: 5), "Running work should expose details without making the raw tool record permanent chat chrome.")
        detailToggle.tap()
        let runningRow = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Reading files")).firstMatch
        XCTAssertTrue(runningRow.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "toolActivityRow").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Tool Center"].exists, "Running tool activity should not revive the old large debug panel.")
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists, "Running chat tool activity should stay in the transcript, not duplicate Run Control UI.")
        capture("14-tool-running-compact", app: app)
    }

    func testLegacyV1FailedToolCallRemainsInspectable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--failed-tool-call-demo", "--legacy-v1-tool-ui", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let failedSummary = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "1 failed")).firstMatch
        XCTAssertTrue(failedSummary.waitForExistence(timeout: 5), "A resolved failed tool call should collapse to a compact failed-action summary.")
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "was not found")).firstMatch.exists,
            "Raw failure output should stay hidden until the user expands details."
        )
        capture("12-tool-failure-collapsed", app: app)

        let detailToggle = app.buttons.matching(identifier: "toolBatchToggle").firstMatch
        XCTAssertTrue(detailToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(detailToggle.label.contains("Show action details"))
        detailToggle.tap()

        XCTAssertTrue(app.staticTexts["Read failed"].waitForExistence(timeout: 5))
        let resultDetail = app.staticTexts.matching(identifier: "toolResultDetail").firstMatch
        XCTAssertTrue(resultDetail.waitForExistence(timeout: 5))
        XCTAssertTrue(resultDetail.label.contains("Open History for diagnostics"))
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists, "Failed tool details should stay in the inline action disclosure, not a duplicate debug/status panel.")
        capture("13-tool-failure-expanded", app: app)
    }

    func testLegacyV1ArtifactHandoffRemainsInspectable() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--local-agent-boundary-test", "--legacy-v1-tool-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        let summary = app.staticTexts.matching(identifier: "toolActivitySummary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Artifact-producing tool batches should collapse to one compact handoff line in Chat.")
        XCTAssertTrue(summary.label.contains("3 actions completed"), "Artifact handoff should summarize the completed tool batch instead of replaying raw rows.")
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
        XCTAssertTrue(app.staticTexts["Qwen Coder 1.5B — iPhone 12"].waitForExistence(timeout: 5))
        capture("18-local-model-settings", app: app)
    }

    func testSettingsReadyCardUsesReadableProviderModelHierarchy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--settings-local-model-ready"]
        app.launch()

        XCTAssertTrue(app.otherElements["settingsRoot"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Ready to run"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.staticTexts["Local"].waitForExistence(timeout: 5), "Ready card should expose the selected provider plainly.")
        let modelDetail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Qwen Coder Q4 is installed and runs on-device")).firstMatch
        XCTAssertTrue(modelDetail.waitForExistence(timeout: 5), "Ready card should explain the installed on-device model in readable language.")
        XCTAssertGreaterThanOrEqual(modelDetail.frame.width, 120, "Model detail should remain visibly readable on compact iPhones.")
        XCTAssertTrue(app.staticTexts["Writes, commands, and deletes pause for approval."].waitForExistence(timeout: 3), "The current safety policy should remain visible beside provider readiness.")
        for providerID in ["openCodeZen", "local", "openAICodex", "openAI"] {
            let provider = app.buttons["settingsProvider-\(providerID)"]
            XCTAssertTrue(provider.waitForExistence(timeout: 3), "Settings should expose provider route \(providerID) without hidden horizontal scrolling.")
            XCTAssertGreaterThanOrEqual(provider.frame.minX, app.frame.minX + 15.5, "Provider route \(providerID) should stay inside the compact iPhone leading edge.")
            XCTAssertLessThanOrEqual(provider.frame.maxX, app.frame.maxX - 15.5, "Provider route \(providerID) should stay inside the compact iPhone trailing edge.")
            assertMinimumTouchTarget(provider, named: "settings provider \(providerID)")
        }
        capture("86-settings-ready-card-readable-hierarchy", app: app)
    }

    func testSettingsDiagnosticsShowsAppBuildForInstallVerification() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--open-settings"]
        app.launch()

        XCTAssertTrue(app.otherElements["settingsRoot"].waitForExistence(timeout: 8))
        let buildLabel = app.staticTexts.containing(NSPredicate(format: "label == %@", "APP BUILD")).firstMatch
        XCTAssertTrue(buildLabel.waitForExistence(timeout: 5), "The Control deck should expose the app build immediately so phone-update proof can be matched to the installed app.")
        let bundleLabel = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "com.joey.NovaForge")).firstMatch
        XCTAssertTrue(bundleLabel.waitForExistence(timeout: 3), "Build diagnostics should include the bundle ID used by devicectl install/launch.")
        XCTAssertGreaterThanOrEqual(buildLabel.frame.minY, app.frame.minY + 180, "Build label should sit in the visible top Control deck, not below the fold.")
        XCTAssertLessThanOrEqual(bundleLabel.frame.maxY, app.frame.maxY - 300, "Bundle build detail should be visible before scrolling.")
        capture("88-settings-diagnostics-app-build", app: app)
    }

    func testControlDoesNotOfferRoutesUnsupportedByAgentRuntime() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--settings-local-model-ready"]
        app.launch()

        XCTAssertTrue(app.otherElements["settingsRoot"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["settingsProvider-custom"].exists)
        XCTAssertFalse(app.buttons["settingsProvider-openRouter"].exists)
        XCTAssertTrue(app.buttons["settingsProvider-openCodeZen"].exists)
        XCTAssertTrue(app.buttons["settingsProvider-local"].exists)
        capture("87-settings-agent-routes-only", app: app)
    }

    func testLocalModelDestructiveActionsRequireConfirmation() throws {
        func openSettingsFixture(_ launchArgument: String) -> XCUIApplication {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-ui", launchArgument, "--open-settings"]
            app.launch()
            XCTAssertTrue(app.otherElements["settingsRoot"].waitForExistence(timeout: 8))
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

    func testNativeModelPickerAndChatGPTProviderScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let settingsTab = app.tabBars.buttons["Control"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        tapButtonOrCoordinate(
            settingsTab,
            in: app,
            normalizedOffset: CGVector(dx: 0.83, dy: 0.94)
        )

        let chatGPTProvider = app.buttons["settingsProvider-openAICodex"]
        XCTAssertTrue(chatGPTProvider.waitForExistence(timeout: 5))
        chatGPTProvider.tap()

        let pickerButton = app.buttons["modelPickerButton"]
        if !pickerButton.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(pickerButton.waitForExistence(timeout: 5))
        pickerButton.tap()

        XCTAssertTrue(app.staticTexts["Choose Model"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["GPT-5.6 Sol"].waitForExistence(timeout: 5))
        let settingsModelSearch = app.textFields["Search models"]
        XCTAssertTrue(settingsModelSearch.waitForExistence(timeout: 5))
        settingsModelSearch.tap()
        settingsModelSearch.typeText("5.6")
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
        XCTAssertTrue(
            app.staticTexts["Live ChatGPT models"].waitForExistence(timeout: 5),
            "ChatGPT model choices should expose the live subscription-backed catalog."
        )
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "OpenAI API key needed")).firstMatch.exists)
        capture("21-native-model-picker-chatgpt", app: app)
        app.buttons["Done"].tap()
    }

    func testChatGPTSubscriptionSignInReplacesSimulatedTerminal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let settingsTab = app.tabBars.buttons["Control"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let chatGPTProvider = app.staticTexts["ChatGPT"]
        XCTAssertTrue(chatGPTProvider.waitForExistence(timeout: 5))
        chatGPTProvider.tap()

        let subscriptionTitle = app.staticTexts["ChatGPT subscription"]
        let signInButton = app.buttons["Sign in with ChatGPT"]
        if !subscriptionTitle.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        if !subscriptionTitle.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(subscriptionTitle.waitForExistence(timeout: 5), "ChatGPT should present the real subscription sign-in flow.")
        XCTAssertTrue(signInButton.waitForExistence(timeout: 5), "ChatGPT should expose device-code sign-in instead of asking for an API key.")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "never asks for your ChatGPT password")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["OpenAI Key"].exists, "The ChatGPT subscription route should stay separate from the OpenAI API-key provider.")
        XCTAssertFalse(app.staticTexts["codex simulated terminal"].exists)
        capture("38-settings-chatgpt-subscription-sign-in", app: app)

        let chatTab = app.tabBars.buttons["Forge"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 5))
        chatTab.tap()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["codex simulated terminal"].exists, "Chat should never show the removed fake Codex terminal.")
        capture("39-chat-chatgpt-subscription-route", app: app)
    }

    func testComposerModelMenuUsesNativeGlassChooser() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        capture("22a-chat-dock-redesigned", app: app)

        let composerModelButton = composerModelControl(in: app)
        XCTAssertTrue(composerModelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(composerModelButton.label.localizedCaseInsensitiveContains("Choose model"), "Composer model control should describe its purpose before opening the native menu.")
        composerModelButton.tap()

        XCTAssertTrue(app.navigationBars["Model & provider"].waitForExistence(timeout: 5), "Composer should open the structured native glass chooser.")
        XCTAssertTrue(app.staticTexts["Choose where NovaForge thinks"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["composerProvider-local"].waitForExistence(timeout: 5), "Local should be a readable provider row, not a raw menu item.")
        XCTAssertTrue(app.buttons["composerProvider-openAI"].waitForExistence(timeout: 5), "OpenAI should remain available in the provider section.")
        app.buttons["composerProvider-local"].tap()
        XCTAssertTrue(app.buttons["composerModel-Qwen/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M"].waitForExistence(timeout: 5), "The local provider should reveal iPhone-safe local models in the same chooser.")
        XCTAssertTrue(app.staticTexts["On-device model"].waitForExistence(timeout: 5), "Local download readiness belongs directly beside local model selection.")
        XCTAssertFalse(app.buttons["composerModelSearchClearButton"].exists, "Search belongs in Settings; the composer menu should stay compact.")
        XCTAssertFalse(app.buttons["Refresh provider models"].exists, "Live model refresh belongs in Settings; the composer menu should stay focused on choosing.")
        capture("22b-composer-native-glass-chooser", app: app)
        app.buttons["Done"].tap()
    }

    func testComposerProviderSwitchingRepairsStaleModelInline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stale-openai-local-model"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let composerModelButton = composerModelControl(in: app)
        XCTAssertTrue(composerModelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(composerModelButton.label.contains("OpenAI"), "A stale local model under OpenAI should repair to OpenAI before the user sends.")
        XCTAssertFalse(composerModelButton.label.contains("Qwen Coder"), "Stale local model labels should not survive under the OpenAI provider.")
        composerModelButton.tap()

        XCTAssertTrue(
            app.buttons["composerModel-gpt-5.6-sol"].firstMatch.waitForExistence(timeout: 5),
            "Repaired OpenAI state should show the current default OpenAI model in the native composer menu."
        )
        XCTAssertFalse(app.staticTexts["Switch model"].exists, "Composer provider switching should not bring back the old custom model sheet.")

        let chatGPTProvider = app.buttons["composerProvider-openAICodex"].firstMatch
        XCTAssertTrue(chatGPTProvider.waitForExistence(timeout: 5))
        chatGPTProvider.tap()
        XCTAssertTrue(app.buttons["composerModel-gpt-5.6-sol"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(composerModelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(composerModelButton.label.contains("ChatGPT"), "Selecting ChatGPT should update the compact composer label immediately.")

        composerModelButton.tap()
        let localProvider = app.buttons["composerProvider-local"].firstMatch
        XCTAssertTrue(localProvider.waitForExistence(timeout: 5))
        localProvider.tap()
        XCTAssertTrue(app.buttons["composerModel-Qwen/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(composerModelButton.waitForExistence(timeout: 5))
        XCTAssertTrue(composerModelButton.label.contains("Local"), "Local should be selectable from the compact composer menu.")
        capture("09-composer-provider-switching-glass", app: app)
    }

    func testReasoningAndUltraCodePickerUsesExpandableLiquidGlassControl() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let composerModelButton = composerModelControl(in: app)
        XCTAssertTrue(composerModelButton.waitForExistence(timeout: 5))
        composerModelButton.tap()

        let chatGPTProvider = app.buttons["composerProvider-openAICodex"]
        XCTAssertTrue(chatGPTProvider.waitForExistence(timeout: 5))
        chatGPTProvider.tap()
        XCTAssertTrue(app.buttons["composerModel-gpt-5.6-sol"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        let reasoningButton = app.buttons["composerReasoningPickerButton"]
        XCTAssertTrue(reasoningButton.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(reasoningButton, named: "reasoning and agent mode")
        reasoningButton.tap()

        let reasoningPicker = app.descendants(matching: .any)
            .matching(identifier: "composerReasoningPicker").firstMatch
        XCTAssertTrue(
            reasoningPicker.waitForExistence(timeout: 5) ||
                app.staticTexts["Reasoning"].waitForExistence(timeout: 5)
        )
        let reasoningSlider = app.descendants(matching: .any)
            .matching(identifier: "reasoningEffortSlider").firstMatch
        XCTAssertTrue(reasoningSlider.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(reasoningSlider, named: "reasoning effort slider")
        XCTAssertFalse(app.staticTexts["Agent mode"].exists, "The composer should not reopen the old settings-style mode menu.")

        let dragStart = reasoningSlider.coordinate(
            withNormalizedOffset: CGVector(dx: 0.14, dy: 0.34)
        )
        let dragEnd = reasoningSlider.coordinate(
            withNormalizedOffset: CGVector(dx: 0.50, dy: 0.34)
        )
        dragStart.press(forDuration: 0.12, thenDragTo: dragEnd)
        XCTAssertEqual(
            reasoningSlider.value as? String,
            "High",
            "Dragging across the glass pill should move the reasoning thumb, not behave like a static menu."
        )

        reasoningSlider.coordinate(
            withNormalizedOffset: CGVector(dx: 0.90, dy: 0.34)
        ).tap()
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "workspace")
            ).firstMatch.waitForExistence(timeout: 5),
            "UltraCode should compactly explain its maximum-reasoning workspace behavior."
        )
        capture("23-reasoning-ultracode-liquid-glass", app: app)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.08)).tap()
        XCTAssertTrue(reasoningButton.waitForExistence(timeout: 5))
        XCTAssertTrue(
            reasoningButton.label.localizedCaseInsensitiveContains("UltraCode"),
            "The collapsed liquid-glass control should retain the selected UltraCode mode."
        )
    }

    func testStreamingKeepsBottomPinnedDuringLiveResponse() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-streaming"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let liveResponse = liveStreamingReadableContent(in: app)
        XCTAssertTrue(liveResponse.waitForExistence(timeout: 8))
        XCTAssertFalse(liveResponse.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Stress stream should expose readable live response text.")
        XCTAssertFalse(liveResponse.label.localizedCaseInsensitiveContains("word tree"))
        XCTAssertFalse(liveResponse.label.localizedCaseInsensitiveContains("queued"))
        XCTAssertFalse(liveResponse.label.localizedCaseInsensitiveContains("renderer"))
        XCTAssertFalse(liveResponse.label.localizedCaseInsensitiveContains("normalizing chunk"))
        let firstCharacterCount = liveStreamingCharacterCount(in: app)
        XCTAssertGreaterThan(firstCharacterCount, 0, "Live feed should reveal an initial readable frame.")
        let secondCharacterCount = waitForLiveStreamingCharacterGrowth(in: app, from: firstCharacterCount, timeout: 10)
        XCTAssertGreaterThan(secondCharacterCount, firstCharacterCount, "Live feed should advance in measured display-paced frames before layout proof.")
        assertNoLiveStreamingLineArtifacts(in: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        capture("31-liquid-motion-mid-reveal", app: app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        capture("32-liquid-motion-settled-reveal", app: app)
        XCTAssertFalse(jumpToLatestButton(in: app).exists, "Live streaming should stay pinned at the bottom without asking the user to manually jump to latest.")
        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.descendants(matching: .any)["forgeSessionStatus"].exists,
            "The run context should own live status instead of repeating Working in the header."
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["composerStatusPill"].exists,
            "The composer live rail should replace the old decorative Running pill."
        )
        let liveRunRail = app.descendants(matching: .any)["composerLiveRunRail"].firstMatch
        XCTAssertTrue(liveRunRail.waitForExistence(timeout: 3), "A chat-owned stream should fold live state into the composer instead of adding a second glass slab.")
        let composerStop = app.buttons["composerStopButton"]
        XCTAssertTrue(composerStop.waitForExistence(timeout: 3), "Stop should remain directly reachable from the live composer rail.")
        assertMinimumTouchTarget(composerStop, named: "Composer Stop")
        let streamingComposerDock = composerDock(in: app)
        XCTAssertTrue(streamingComposerDock.waitForExistence(timeout: 3))
        assertContained(liveRunRail, in: bottomAccessory, named: "live composer run rail")
        let liveField = app.otherElements["liveResponseField"]
        XCTAssertTrue(liveField.waitForExistence(timeout: 3))
        // TextRenderer display padding intentionally lets the materializing
        // phrase draw a few points outside its layout bounds. The response is
        // an open field, so the meaningful visual contract is clearance from
        // the bottom controls rather than containment in a nonexistent card.
        assertNoLiveStreamingLineArtifacts(in: app)
        XCTAssertLessThanOrEqual(liveResponse.frame.maxY, bottomAccessory.frame.minY - 4, "Pinned streaming output should stay readable above the run/composer stack.")
        XCTAssertLessThanOrEqual(liveField.frame.maxY, bottomAccessory.frame.minY - 4, "The live response field should not continue behind the run/composer stack.")
        capture("23-streaming-bottom-pinned", app: app)

        let progressToggle = runProgressToggle(in: app)
        XCTAssertTrue(progressToggle.waitForExistence(timeout: 5))
        progressToggle.tap()
        assertRunControlSheetPresented(in: app)
        XCTAssertTrue(app.otherElements["runControlDrawer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Run Control"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Running Tool"].waitForExistence(timeout: 5))
        let status = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Writing answer", "Catching up")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), "Live feed should expose human streaming status while preserving hidden metrics.")
        let activeToolDetail = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Organizing the response")).firstMatch
        XCTAssertTrue(activeToolDetail.waitForExistence(timeout: 5), "Expanded progress should expose the humanized live-response detail.")
        let latestTrace = app.staticTexts["latestTraceEventTitle"]
        XCTAssertTrue(latestTrace.waitForExistence(timeout: 5), "Expanded progress should expose a stable newest trace row for UI tests and VoiceOver.")
        XCTAssertFalse(latestTrace.label.localizedCaseInsensitiveContains("word-tree"), "Expanded progress should hide debug renderer labels; got '\(latestTrace.label)'.")
        XCTAssertTrue(latestTrace.label.contains("Writing answer") || latestTrace.label.contains("Live response"), "Expanded progress should show a human live-response trace; got '\(latestTrace.label)'.")
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
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3), "Chat should expose one bottom accessory for composer, run controls, and jump affordances.")
        let sendButton = app.buttons["sendMessageButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3))
        if keyboardVisible {
            assertKeyboardComposerChrome(in: app, keyboard: keyboard, sendButton: sendButton)
        } else {
            assertComposerDockAligned(in: app)
        }

        let liveField = app.otherElements["liveResponseField"]
        XCTAssertTrue(liveField.waitForExistence(timeout: 3))
        assertNoLiveStreamingLineArtifacts(in: app)
        XCTAssertLessThanOrEqual(liveResponse.frame.maxY, bottomAccessory.frame.minY - 4, "Pinned streaming output should stay readable above the full bottom accessory stack.")
        XCTAssertLessThanOrEqual(liveField.frame.maxY, bottomAccessory.frame.minY - 4, "The focused-composer live field should not flow under the bottom accessory stack.")
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
        let detachedDock = composerDock(in: app)
        XCTAssertTrue(detachedDock.waitForExistence(timeout: 3))
        assertContained(latestButton, in: bottomChatAccessory(in: app), named: "detached Jump to Latest")
        sleep(1)
        XCTAssertTrue(latestButton.exists, "Pending live-stream resize scrolls must not cancel an intentional user scroll-away.")

        latestButton.tap()
        XCTAssertFalse(jumpToLatestButton(in: app).waitForExistence(timeout: 2), "Tapping Jump to Latest should repin the live response and hide the jump button.")
        XCTAssertTrue(liveStreamingReadableContent(in: app).waitForExistence(timeout: 5))
        capture("26-streaming-jumped-back-latest", app: app)

        // A new gesture must cancel the single post-layout correction. The old
        // implementation kept forcing the bottom for roughly six seconds.
        pullStart.press(forDuration: 0.15, thenDragTo: pullEnd)
        let latestAfterRepin = jumpToLatestButton(in: app)
        XCTAssertTrue(latestAfterRepin.waitForExistence(timeout: 3), "A fresh drag after repinning should immediately detach again instead of being overridden by delayed scroll retries.")
        let repinnedDock = composerDock(in: app)
        XCTAssertTrue(repinnedDock.waitForExistence(timeout: 3))
        assertContained(latestAfterRepin, in: bottomChatAccessory(in: app), named: "repinned Jump to Latest")
        sleep(1)
        XCTAssertTrue(latestAfterRepin.exists, "No delayed repin correction should steal the user's second scroll-away.")
    }

    func testLegacyV1LocalNativeToolPlanMigrationScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--local-agent-boundary-test", "--legacy-v1-tool-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let summary = app.staticTexts.matching(identifier: "toolActivitySummary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Completed tool work should remain as one compact transcript receipt.")
        XCTAssertTrue(summary.label.contains("3 actions completed"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "toolActivityRow").firstMatch.exists, "Completed file operations should not replay raw action rows until requested.")
        let openArtifact = app.buttons["toolArtifactOpenButton"]
        XCTAssertTrue(openArtifact.waitForExistence(timeout: 5), "The transcript receipt should retain the artifact handoff.")
        assertMinimumTouchTarget(openArtifact, named: "inline artifact handoff")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Playable game ready")).firstMatch.waitForExistence(timeout: 8))
        capture("19-local-native-tool-plan", app: app)
        XCTAssertFalse(runProgressToggle(in: app).exists, "A completed tool plan should not leave a persistent Run Control toggle.")
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "A completed tool plan should not add a duplicate completion bar.")
        let idleDock = composerDock(in: app)
        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(idleDock.waitForExistence(timeout: 3))
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(idleDock.frame.height, 128, "Completed tool work should return to the compact idle composer.")
        assertContained(idleDock, in: bottomAccessory, named: "completed tool-plan composer")
        capture("37-completed-tool-plan-compact-dock", app: app)
    }

    func testToolBearingMarkdownCompletedRunDetachesToLatest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-chat", "--local-agent-boundary-test", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(
                format: "label CONTAINS %@",
                "I’ll build and verify the game in slither-arena.html with native tools."
            )).firstMatch.waitForExistence(timeout: 20),
            "Tool-bearing assistant prose should expose its unique cleaned sentence without raw Markdown delimiters."
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "**")).firstMatch.exists,
            "Settled tool prose should never expose provider Markdown delimiters."
        )
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "Completed work should not occupy a second persistent bottom bar.")
        XCTAssertFalse(runProgressToggle(in: app).exists, "Completed work should return Forge to its compact idle composer.")

        let dock = composerDock(in: app)
        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(dock.waitForExistence(timeout: 3))
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(dock.frame.height, 128, "The idle composer should remain a compact unified surface after tool work completes.")
        XCTAssertLessThanOrEqual(bottomAccessory.frame.height, 128, "Completed work should leave only the compact bottom composer accessory.")
        assertContained(dock, in: bottomAccessory, named: "completed tool Markdown composer")

        let chatScroll = app.scrollViews["chatTranscriptScroll"]
        XCTAssertTrue(chatScroll.waitForExistence(timeout: 5))
        let pullStart = chatScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let pullEnd = chatScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
        pullStart.press(forDuration: 0.15, thenDragTo: pullEnd)

        let latestButton = jumpToLatestButton(in: app)
        XCTAssertTrue(latestButton.waitForExistence(timeout: 4), "Scrolling away from a completed long transcript should surface Latest inside the composer.")
        let detachedAccessory = bottomChatAccessory(in: app)
        let detachedInput = chatComposerInput(in: app)
        let detachedSend = app.buttons["sendMessageButton"]
        assertContained(latestButton, in: detachedAccessory, named: "completed transcript Latest")
        XCTAssertTrue(detachedInput.exists)
        XCTAssertTrue(detachedSend.waitForExistence(timeout: 3))
        capture("34-tool-markdown-complete-latest", app: app)
        XCTAssertGreaterThanOrEqual(latestButton.frame.minX, detachedInput.frame.maxX - 1, "Latest should occupy the typing row immediately after the text lane.")
        XCTAssertLessThanOrEqual(latestButton.frame.maxX, detachedSend.frame.minX + 1, "Latest should remain before Send in the same typing row.")
        XCTAssertLessThanOrEqual(abs(latestButton.frame.midY - detachedSend.frame.midY), 1, "Latest and Send should share the same command-row center instead of forming separate floating shelves.")
    }

    func testCanonicalActivityApprovalIsAccessibleCompactAndLegacyFree() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-ui",
            "--canonical-activity-a11y-demo",
            "--theme-world=whiteGold",
            "--open-chat",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 10))
        let approvalView = app.descendants(matching: .any)
            .matching(identifier: "agentPolicyApprovalView").firstMatch
        XCTAssertTrue(
            approvalView.waitForExistence(timeout: 10),
            "The broker-owned redacted approval surface should present for the canonical fixture."
        )

        let exactTarget = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "approval-demo-with-a-deliberately-long-name.swift"
            )
        ).firstMatch
        XCTAssertTrue(
            exactTarget.waitForExistence(timeout: 5),
            "The exact reviewed target must remain available at the largest accessibility text size."
        )
        assertReadableLabel(exactTarget, named: "canonical approval target")

        let expiry = app.descendants(matching: .any)
            .matching(identifier: "agentPolicyApprovalExpiry").firstMatch
        XCTAssertTrue(expiry.waitForExistence(timeout: 5))
        assertReadableLabel(expiry, named: "approval expiry")

        let reject = app.buttons["agentPolicyRejectButton"]
        let approve = app.buttons["agentPolicyApproveButton"]
        scrollUntilHittable(reject, in: app)
        scrollUntilHittable(approve, in: app)
        assertMinimumTouchTarget(reject, named: "canonical reject")
        assertMinimumTouchTarget(approve, named: "canonical approve")
        XCTAssertFalse(
            reject.frame.intersects(approve.frame),
            "Accessibility-size approval actions must reflow without overlapping."
        )

        XCTAssertFalse(app.staticTexts["Review this action"].exists)
        XCTAssertFalse(app.buttons["Approve Change"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "toolActivityRow").firstMatch.exists,
            "The canonical fixture must never revive the legacy provider-JSON tool row."
        )
        capture("51-canonical-approval-accessibility-white-gold", app: app)

        reject.tap()
        XCTAssertTrue(
            approvalView.waitForNonExistence(timeout: 5),
            "Rejecting the exact fixture should dismiss the broker surface immediately."
        )

        let transcript = app.scrollViews["chatTranscriptScroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let activityGroups = app.otherElements.matching(identifier: "agentActivityGroup")
        for _ in 0 ..< 6 where activityGroups.count < 2 {
            transcript.swipeDown()
        }
        XCTAssertGreaterThanOrEqual(
            activityGroups.count,
            2,
            "Canonical activity should render as compact classified groups after the decision."
        )

        XCTAssertFalse(
            app.buttons.matching(identifier: "agentActivityOpenReceipt").firstMatch.exists,
            "Collapsed activity should stay one compact line; receipts live behind disclosure."
        )

        let stop = app.buttons["agentActivityStop"]
        for _ in 0 ..< 8 where !stop.exists {
            transcript.swipeDown()
        }
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(stop, named: "canonical stop")

        let summaries = app.descendants(matching: .any)
            .matching(identifier: "agentActivitySummary")
        var expandableSummary: XCUIElement?
        for attempt in 0 ..< 12 where expandableSummary == nil {
            expandableSummary = summaries.allElementsBoundByIndex.first(where: {
                $0.exists && $0.isHittable
            })
            guard expandableSummary == nil else { break }
            // At accessibility sizes, locating Stop can leave every group
            // summary just beyond either edge of the transcript viewport.
            // Sweep toward newer content first, then back toward older work.
            if attempt < 6 {
                transcript.swipeUp()
            } else {
                transcript.swipeDown()
            }
        }
        XCTAssertNotNil(
            expandableSummary,
            "A classified activity summary should remain reachable at AX-XXXL."
        )
        expandableSummary?.tap()
        XCTAssertTrue(
            app.otherElements["agentActivityItem"].waitForExistence(timeout: 5) ||
                app.otherElements["agentActivityModelWork"].waitForExistence(timeout: 5),
            "Expanded canonical activity should expose classified detail instead of a giant raw tool payload."
        )

        let retry = app.buttons["agentActivityRetry"]
        for _ in 0 ..< 10 where !retry.exists {
            transcript.swipeUp()
        }
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(retry, named: "canonical retry")
        XCTAssertTrue(
            app.otherElements["agentActivityArtifact"].waitForExistence(timeout: 5),
            "Canonical failed work should retain compact artifact handoffs."
        )
        XCTAssertTrue(
            identifiedElement(
                "agentActivityMoreArtifacts",
                in: app
            ).waitForExistence(timeout: 5),
            "Capped artifact detail should hand off to History instead of expanding the transcript indefinitely."
        )
        capture("52-canonical-activity-expanded-accessibility", app: app)
    }

    func testCompletedArtifactHandoffKeepsForgeDockCompact() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--artifact-dedupe-demo"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        let finalMessage = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Playable game ready")).firstMatch
        XCTAssertTrue(finalMessage.waitForExistence(timeout: 8))

        XCTAssertFalse(runProgressToggle(in: app).exists, "A completed artifact should not keep Run Control pinned over the transcript.")
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "The transcript handoff is the completion receipt; Forge should not repeat it in a bottom bar.")
        XCTAssertFalse(app.buttons["artifactPrimaryOpenButton"].exists, "Completed artifact actions should not survive inside an obsolete bottom drawer.")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "artifactSecondaryOpenButton").firstMatch.exists)

        let dock = composerDock(in: app)
        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(dock.waitForExistence(timeout: 3))
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(dock.frame.height, 128, "Completed artifact handoff should return to the compact composer.")
        assertContained(dock, in: bottomAccessory, named: "completed artifact composer")
        XCTAssertLessThanOrEqual(finalMessage.frame.maxY, bottomAccessory.frame.minY - 4, "The final artifact handoff should remain readable above the real bottom accessory.")

        capture("35-artifact-dedupe-compact-forge", app: app)
    }

    func testLegacyV1ArtifactPreviewStudioModes() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--local-agent-boundary-test", "--legacy-v1-tool-ui"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Playable game ready")).firstMatch.waitForExistence(timeout: 8))

        XCTAssertFalse(runProgressToggle(in: app).exists, "Completed artifact work should not require reopening an obsolete bottom drawer.")
        let inlineArtifactOpen = app.buttons["toolArtifactOpenButton"]
        XCTAssertTrue(inlineArtifactOpen.waitForExistence(timeout: 5), "Artifact preview should open from the compact transcript receipt.")
        assertMinimumTouchTarget(inlineArtifactOpen, named: "inline artifact preview")
        inlineArtifactOpen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        capture("42-artifact-button-tapped", app: app)
        let previewStudio = app.descendants(matching: .any).matching(identifier: "artifactPreviewStudio").firstMatch
        let normalPreviewLabel = app.staticTexts["Normal preview"]
        let swiftGamePreview = app.descendants(matching: .any).matching(identifier: "swiftGamePreviewPlayer").firstMatch
        let previewShareButton = identifiedElement("artifactShareButton", in: app)
        let addToHomeScreenButton = identifiedElement("artifactAddToHomeScreenButton", in: app)
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
        assertMinimumTouchTarget(addToHomeScreenButton, named: "artifact add to Home Screen")
        assertMinimumTouchTarget(previewFullScreenButton, named: "artifact preview full screen")
        assertMinimumTouchTarget(previewCloseButton, named: "artifact preview close")
        assertMinimumTouchTarget(previewReloadButton, named: "artifact preview reload")
        XCTAssertFalse(app.buttons["artifactViewportFit"].exists, "Release artifact viewer should not show a mode picker.")
        XCTAssertFalse(app.buttons["artifactViewportPortrait"].exists, "Release artifact viewer should not show a portrait mode button.")
        XCTAssertFalse(app.buttons["artifactViewportLandscape"].exists, "Release artifact viewer should not show a landscape mode button.")
        Thread.sleep(forTimeInterval: 1.0)
        capture("43-artifact-preview-normal", app: app)

        addToHomeScreenButton.tap()
        let homeScreenGuide = app.descendants(matching: .any)
            .matching(identifier: "artifactHomeScreenGuide").firstMatch
        XCTAssertTrue(
            homeScreenGuide.waitForExistence(timeout: 5) ||
                app.staticTexts["Add to Home Screen"].waitForExistence(timeout: 5),
            "A playable artifact should expose the real Shortcuts handoff needed to create a Home Screen icon."
        )
        XCTAssertTrue(app.staticTexts["Open Shortcuts below."].waitForExistence(timeout: 5))
        capture("45-artifact-home-screen-guide", app: app)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(previewFullScreenButton.waitForExistence(timeout: 5))

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
        let fixtureReady = app.descendants(matching: .any)
            .matching(identifier: "localWebArtifactFixtureReady").firstMatch
        XCTAssertTrue(
            fixtureReady.waitForExistence(timeout: 20),
            "The app should publish readiness only after the artifact, receipt, and transcript are durable."
        )
        let finalMessage = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Local web artifact ready")).firstMatch
        XCTAssertTrue(finalMessage.waitForExistence(timeout: 5))
        XCTAssertFalse(runProgressToggle(in: app).exists, "Completed web artifacts should not keep a Run Control bar above the composer.")
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "The assistant handoff should not be duplicated by persistent completion chrome.")
        let dock = composerDock(in: app)
        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(dock.waitForExistence(timeout: 3))
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(dock.frame.height, 128, "Completed web work should return to the compact idle composer.")
        assertContained(dock, in: bottomAccessory, named: "completed web-artifact composer")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertLessThanOrEqual(
            finalMessage.frame.maxY,
            bottomAccessory.frame.minY - 8,
            "The real bottom accessory should keep the final assistant handoff readable instead of covering it."
        )
        capture("70-local-web-artifact-run-complete", app: app)

        app.tabBars.buttons["Workspace"].tap()
        XCTAssertTrue(app.otherElements["filesProjectOverview"].waitForExistence(timeout: 5))
        let artifactEntry = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "cron-18-landing.html")
        ).firstMatch
        scrollUntilHittable(artifactEntry, in: app)
        XCTAssertTrue(artifactEntry.waitForExistence(timeout: 5), "Completed artifacts should remain reachable from Workspace after Forge drops completion chrome.")
        XCTAssertTrue(artifactEntry.isHittable)
        artifactEntry.tap()

        let previewStudio = app.descendants(matching: .any).matching(identifier: "artifactPreviewStudio").firstMatch
        let normalPreview = app.staticTexts["Normal preview"]
        if !previewStudio.waitForExistence(timeout: 2), !normalPreview.waitForExistence(timeout: 1) {
            let inspector = app.descendants(matching: .any).matching(identifier: "filesMemoryInspector").firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: 5), "Tapping Workspace evidence should either preview it directly or open its inspector.")
            let previewAction = app.buttons["Preview"].firstMatch
            XCTAssertTrue(previewAction.waitForExistence(timeout: 5))
            assertMinimumTouchTarget(previewAction, named: "Workspace artifact Preview")
            previewAction.tap()
        }

        XCTAssertTrue(previewStudio.waitForExistence(timeout: 8) || normalPreview.waitForExistence(timeout: 8))
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
        assertRunControlSheetPresented(in: app)
        XCTAssertTrue(app.otherElements["runControlDrawer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Run Control"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Retry"].waitForExistence(timeout: 5), "Run Control should keep the recovery action visible after suppressing duplicate Project Status.")
        capture("34-network-failure-state", app: app)
        let runSheet = runControlSheet(in: app)
        let closeRunSheet = app.buttons["runControlCloseButton"]
        XCTAssertTrue(closeRunSheet.waitForExistence(timeout: 3))
        closeRunSheet.tap()
        XCTAssertTrue(runSheet.waitForNonExistence(timeout: 3), "Run details should dismiss before the composer accepts a recovery prompt.")
        let composer = chatComposerInput(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        if app.buttons["composerProvider-local"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.12)).tap()
        }
        let resumedComposer = chatComposerInput(in: app)
        XCTAssertTrue(resumedComposer.waitForExistence(timeout: 5))
        resumedComposer.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        resumedComposer.typeText("list files")
        tapReadySendButton(in: app)
        XCTAssertFalse(app.staticTexts["Run failed"].waitForExistence(timeout: 2))
        let completedHandoff = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Workspace scan finished")).firstMatch
        XCTAssertTrue(completedHandoff.waitForExistence(timeout: 8), "Recovery should finish with a durable assistant handoff.")
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "Recovery completion should not leave persistent completion chrome.")
        XCTAssertFalse(runProgressToggle(in: app).exists, "Recovery completion should clear the actionable Run Control bar.")
        capture("35-network-recovery-complete", app: app)

        composer.tap()
        composer.typeText("next draft")
        XCTAssertFalse(app.staticTexts["Run complete"].exists, "A fresh draft should keep the already-idle bottom stack free of completion chrome.")
        XCTAssertFalse(self.runProgressToggle(in: app).exists, "A completed run should not crowd a focused composer draft.")
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

        if app.buttons["composerProvider-local"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.12)).tap()
        }
        let resumedComposer = chatComposerInput(in: app)
        XCTAssertTrue(resumedComposer.waitForExistence(timeout: 5))
        resumedComposer.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        resumedComposer.typeText("list files")
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
        XCTAssertTrue(identifiedElement("firstRunPowerUp", in: app).waitForExistence(timeout: 8), "A fresh install without local weights should lead with the actionable on-device setup surface.")
        XCTAssertTrue(app.buttons["firstRunPowerUpButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["firstRunProjectLauncher"].exists)
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists)
        capture("69-first-run-power-up", app: app)
    }

    func testGoalMatrixChatReadabilityAndThemeSwitchingScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--theme-world=matrixRain", "--canonical-activity-a11y-demo", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "agentPolicyApprovalView").firstMatch
                .waitForExistence(timeout: 8),
            "Matrix mode should keep the canonical approval surface readable over its ambient world."
        )
        XCTAssertTrue(
            app.buttons["agentPolicyApproveButton"].waitForExistence(timeout: 5),
            "Canonical approval controls should stay readable and tappable in Matrix mode."
        )
        XCTAssertFalse(app.buttons["Approve Change"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "toolActivityRow").firstMatch.exists
        )
        capture("goal-matrix-chat-readable", app: app)

        app.terminate()
        app.launchArguments = [
            "--reset-ui",
            "--theme-world=matrixRain",
            "--settings-local-model-ready",
            "--open-chat",
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Control"].tap()
        let midnightTheme = identifiedElement(
            "settingsThemeStudioCard-midnightBlack",
            in: app
        )
        scrollUntilHittable(midnightTheme, in: app)
        XCTAssertTrue(
            midnightTheme.isHittable,
            "Midnight theme studio card should be reachable from Control."
        )
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
        capture("goal-project-intake-filled", app: app)

        let intakeCreate = app.buttons["projectIntakeCreateButton"]
        XCTAssertTrue(intakeCreate.waitForExistence(timeout: 5))
        XCTAssertTrue(intakeCreate.isEnabled)
        intakeCreate.tap()
        XCTAssertTrue(app.otherElements["projectIntakeSheet"].waitForNonExistence(timeout: 15))
        let createdProjectName = identifiedElement("projectOSProjectName", in: app)
        let arcadeName = NSPredicate(format: "label CONTAINS[c] %@", "Arcade")
        expectation(for: arcadeName, evaluatedWith: createdProjectName)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(
            app.otherElements["projectOSControlCenter"].waitForExistence(timeout: 5),
            "Project creation should stay in the Mission Dossier instead of dumping a raw chat prompt."
        )

        app.buttons["Project actions"].tap()
        XCTAssertTrue(app.otherElements["projectActionsPopover"].waitForExistence(timeout: 12))
        let editProjectAction = app.buttons["projectEditAction"]
        XCTAssertTrue(editProjectAction.waitForExistence(timeout: 12))
        editProjectAction.tap()
        XCTAssertTrue(app.staticTexts["Edit Project"].waitForExistence(timeout: 5))
        XCTAssertTrue(identifiedTextInput("projectEditNameField", in: app).waitForExistence(timeout: 5))
        capture("goal-project-edit-sheet", app: app)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Edit Project"].waitForNonExistence(timeout: 5))

        app.buttons["Project actions"].tap()
        XCTAssertTrue(app.otherElements["projectActionsPopover"].waitForExistence(timeout: 12))
        let deleteProjectMenuAction = app.buttons["projectDeleteAction"]
        XCTAssertTrue(deleteProjectMenuAction.waitForExistence(timeout: 12))
        deleteProjectMenuAction.tap()
        XCTAssertTrue(app.buttons["Delete Project"].waitForExistence(timeout: 5))
        app.buttons["Delete Project"].tap()
        XCTAssertTrue(app.otherElements["projectOSControlCenter"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["forgeTopBar"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.otherElements["projectActionsPopover"].exists)
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

        XCTAssertTrue(app.otherElements["projectOSControlCenter"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.otherElements["projectOSIntelligenceTelemetry"].exists, "Mission Dossier should not repeat health/proof/gate telemetry before the scoped content.")
        XCTAssertFalse(app.otherElements["projectOSIntelligenceSignals"].exists, "Mission Dossier should not render a clipped duplicate signal grid above the real content.")
        XCTAssertFalse(app.descendants(matching: .any)["projectOSIntentMode"].exists, "Execution state should use one human status pill instead of conflicting Resume and Stopped labels.")
        for scope in ["review", "plan", "evidence", "timeline"] {
            let scopeButton = app.buttons["projectDetailScope-\(scope)"]
            XCTAssertTrue(scopeButton.waitForExistence(timeout: 5), "Project scope \(scope) should expose a stable control.")
            assertMinimumTouchTarget(scopeButton, named: "Project scope \(scope)")
        }
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
        XCTAssertTrue(app.otherElements["projectIntakeSheet"].waitForExistence(timeout: 5))
        let projectKind = identifiedTextInput("projectIntakeProjectKindField", in: app)
        XCTAssertTrue(projectKind.waitForExistence(timeout: 5))
        projectKind.tap()
        projectKind.typeText("Slither game")
        let intakeCreate = app.buttons["projectIntakeCreateButton"]
        XCTAssertTrue(intakeCreate.waitForExistence(timeout: 5))
        XCTAssertTrue(intakeCreate.isEnabled)
        intakeCreate.tap()
        XCTAssertTrue(app.otherElements["projectIntakeSheet"].waitForNonExistence(timeout: 15))
        let createdProjectName = identifiedElement("projectOSProjectName", in: app)
        let createdNamePredicate = NSPredicate(format: "label != %@", "NovaForge Project")
        expectation(for: createdNamePredicate, evaluatedWith: createdProjectName)
        waitForExpectations(timeout: 15)
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

        let planScope = app.buttons["projectDetailScope-plan"]
        for _ in 0..<6 where !planScope.isHittable {
            projectSwipeDown()
        }
        XCTAssertTrue(planScope.waitForExistence(timeout: 5))
        XCTAssertTrue(planScope.isHittable)
        planScope.tap()
        XCTAssertTrue(app.otherElements["projectOSPlanSurface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["missionOSPanel"].waitForExistence(timeout: 5), "Mission OS details should be available in the explicit Plan scope.")

        let proofScope = app.buttons["projectDetailScope-evidence"]
        XCTAssertTrue(proofScope.waitForExistence(timeout: 5))
        proofScope.tap()
        XCTAssertTrue(app.otherElements["projectOSProofSurface"].waitForExistence(timeout: 5), "Proof should have a first-class scope instead of a catch-all More panel.")
        XCTAssertFalse(app.otherElements["projectCommandMenu"].exists, "Scope navigation must not revive duplicate Chat/Files/Runs/Terminal action cards.")
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
        XCTAssertTrue(app.descendants(matching: .any)["projectOSExecutionStatePill"].waitForExistence(timeout: 5), "Project hero should show one compact execution-state pill.")
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
        XCTAssertTrue(app.otherElements["projectIntakeSheet"].waitForExistence(timeout: 5))
        let projectKind = identifiedTextInput("projectIntakeProjectKindField", in: app)
        XCTAssertTrue(projectKind.waitForExistence(timeout: 5))
        projectKind.tap()
        projectKind.typeText("Slither game")
        let intakeCreate = app.buttons["projectIntakeCreateButton"]
        XCTAssertTrue(intakeCreate.waitForExistence(timeout: 5))
        XCTAssertTrue(intakeCreate.isEnabled)
        intakeCreate.tap()
        XCTAssertTrue(app.otherElements["projectIntakeSheet"].waitForNonExistence(timeout: 15))
        let createdProjectName = identifiedElement("projectOSProjectName", in: app)
        let createdNamePredicate = NSPredicate(format: "label != %@", "NovaForge Project")
        expectation(for: createdNamePredicate, evaluatedWith: createdProjectName)
        waitForExpectations(timeout: 15)
        let createdName = createdProjectName.label
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
        let createdProjectRow = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "projectSwitcherRowName-", createdName)
        ).firstMatch
        XCTAssertTrue(createdProjectRow.waitForExistence(timeout: 5), "The created project should remain available after switching back to the default project.")
        createdProjectRow.tap()
        XCTAssertEqual(identifiedElement("projectOSProjectName", in: app).label, createdName)

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
        app.launchArguments = ["--reset-ui", "--debug-provider-list-ready", "--open-chat"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        waitForDebugProviderFixture(in: app)
        XCTAssertTrue(app.otherElements["cleanChatEmptyState"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["firstRunProjectLauncher"].exists)
        XCTAssertFalse(app.otherElements["projectStatusBoard"].exists)

        let headerTitle = app.staticTexts["currentChatTitle"].firstMatch
        assertHeaderAnchoredNearTop(headerTitle, in: app, message: "Header title should stay below the top safe area without drifting into the status bar.")
        let forgeTopBar = app.descendants(matching: .any)["forgeTopBar"].firstMatch
        XCTAssertTrue(forgeTopBar.waitForExistence(timeout: 5), "Forge should expose one stable compact navigation row.")
        XCTAssertLessThanOrEqual(forgeTopBar.frame.height, 64, "Forge navigation should stay one deck instead of rebuilding the old stacked menu card.")
        assertMinimumTouchTarget(app.buttons["Open chats"], named: "Open chats")
        assertMinimumTouchTarget(app.buttons["New chat"], named: "New chat")
        assertReadableLabel(app.buttons["Open chats"], named: "Open chats")
        assertReadableLabel(app.buttons["New chat"], named: "New chat")
        let scopeMenu = identifiedElement("chatProjectScopeMenu", in: app)
        XCTAssertTrue(scopeMenu.waitForExistence(timeout: 5), "Forge should expose the current project scope as a stable menu.")
        assertMinimumTouchTarget(scopeMenu, named: "Forge scope menu")
        let dossierShortcut = app.buttons["missionDossierShortcut"]
        XCTAssertFalse(dossierShortcut.exists, "General scope has no project dossier, so Forge should not expose a dead Mission Dossier control.")
        let headerStatus = app.descendants(matching: .any)["forgeSessionStatus"]
        XCTAssertFalse(headerStatus.exists, "Idle or setup status belongs to the content/composer, not permanent navigation chrome.")
        if app.otherElements["firstRunPowerUp"].exists {
            XCTAssertFalse(app.descendants(matching: .any)["forgeSignal-model"].exists, "The first-run setup card owns model setup; Forge should not repeat it as an icon-only header signal.")
        }

        let idleDock = composerDock(in: app)
        let bottomAccessory = bottomChatAccessory(in: app)
        XCTAssertTrue(idleDock.waitForExistence(timeout: 5), "Idle Forge should expose one compact composer row.")
        XCTAssertTrue(bottomAccessory.waitForExistence(timeout: 5), "Forge should expose the real bottom accessory container for layout proof.")
        XCTAssertLessThanOrEqual(idleDock.frame.height, 128, "Idle composer should remain one compact unified control instead of rebuilding the old oversized card.")
        assertContained(idleDock, in: bottomAccessory, named: "idle composer dock")
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(bottomAccessory.frame.maxY, tabBar.frame.minY + 1, "The chat bottom accessory should clear the four-tab dock instead of overlapping it.")

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
        XCTAssertFalse(app.buttons["filesGoUpButton"].exists, "Go up should stay hidden at the workspace root instead of looking enabled but doing nothing.")
        XCTAssertFalse(app.buttons["filesBreadcrumb-home"].exists, "Home should not repeat the current root location above the toolbar.")
        for identifier in ["filesLayoutToggle", "filesSearchButton", "filesWorkspaceMenu", "filesCreateFileButton"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.waitForExistence(timeout: 5), "\(identifier) should expose a stable accessibility identifier.")
            assertMinimumTouchTarget(control, named: identifier)
            assertReadableLabel(control, named: identifier)
        }
        XCTAssertEqual(app.buttons["filesCreateFileButton"].label, "New file or folder", "Workspace create should describe both choices in the sheet instead of pretending the plus only creates files.")
        XCTAssertFalse(app.otherElements["filesEvidenceWorkbenchOverview"].exists, "The Workspace first viewport should start with files, not a duplicate evidence dashboard.")
        XCTAssertFalse(app.otherElements["filesProvenanceHandoff"].exists, "The Workspace first viewport should not repeat the same file in a provenance card.")
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
        XCTAssertTrue(identifiedElement("terminalCommandDeck", in: app).waitForExistence(timeout: 8))
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
        XCTAssertTrue(app.tabBars.buttons["History"].isSelected)
        let historyMission = identifiedElement("forgeMissionStrip", in: app)
        XCTAssertTrue(historyMission.waitForExistence(timeout: 5), "History should reuse Forge's compact live mission strip while a run is active.")
        assertMinimumTouchTarget(historyMission, named: "History mission strip")
        let historyStop = app.buttons["missionStop"]
        XCTAssertTrue(historyStop.waitForExistence(timeout: 5))
        assertMinimumTouchTarget(historyStop, named: "History mission stop")
        capture("76-accessibility-workspace-status-strip-runs", app: app)

        app.tabBars.buttons["Forge"].tap()
        XCTAssertTrue(app.tabBars.buttons["Forge"].isSelected)
        let forgeProgress = runProgressToggle(in: app)
        XCTAssertTrue(forgeProgress.waitForExistence(timeout: 5), "Forge should move a selected chat's active run into the compact composer rail instead of duplicating History's mission strip.")
        assertMinimumTouchTarget(forgeProgress, named: "Forge composer run progress")
        let stopMission = app.buttons["composerStopButton"]
        XCTAssertTrue(stopMission.waitForExistence(timeout: 5), "A working Forge response should expose Stop beside its composer progress rail.")
        assertMinimumTouchTarget(stopMission, named: "Forge composer stop")
        capture("77-accessibility-workspace-status-strip-project", app: app)
    }

    func testRunsControlsKeepAccessibleHitAreas() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--stress-chat"]
        app.launch()
        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.otherElements["historyToolbar"].waitForExistence(timeout: 5))
        for label in ["All", "Writes", "Failures"] {
            let filter = app.buttons["runsFilter-\(label)"]
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
        XCTAssertTrue(app.otherElements["historyToolbar"].waitForExistence(timeout: 5), "Confirming run-log delete should return to History instead of leaving the sheet stuck.")
        XCTAssertTrue(app.buttons["runHistoryCard"].firstMatch.waitForExistence(timeout: 5), "Deleting one seeded log should keep the rest of the run history visible.")
        capture("72-accessibility-runs-targets", app: app)
    }

    func testFilesVisibleActionsDuplicateAndConfirmDelete() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-ui", "--files-actions-test"]
        app.launch()

        XCTAssertTrue(app.staticTexts["currentChatTitle"].waitForExistence(timeout: 8))
        app.tabBars.buttons["Workspace"].tap()
        XCTAssertTrue(app.buttons["fileOpen-Actions-notes-md"].waitForExistence(timeout: 15))
        capture("80-files-actions-before", app: app)

        let sourceOpen = app.buttons["fileOpen-Actions-notes-md"]
        XCTAssertTrue(sourceOpen.waitForExistence(timeout: 5), "Every file row should remain the visible primary action for opening or editing that item.")
        assertMinimumTouchTarget(sourceOpen, named: "notes.md row action")
        XCTAssertEqual(sourceOpen.label, "Preview notes.md")
        XCTAssertFalse(app.buttons["fileEdit-Actions-notes-md"].exists, "Workspace rows should not repeat the row action as a second oversized edit button.")
        XCTAssertFalse(app.buttons["fileDuplicate-Actions-notes-md"].exists, "Duplicate should live behind the row overflow so Files stays calm.")
        XCTAssertFalse(app.buttons["fileDelete-Actions-notes-md"].exists, "Delete should live behind the row overflow so destructive actions are not first-viewport clutter.")

        let sourceMoreActions = app.buttons["fileMoreActions-Actions-notes-md"]
        XCTAssertTrue(sourceMoreActions.waitForExistence(timeout: 5), "File rows should expose secondary actions through a visible overflow button.")
        assertMinimumTouchTarget(sourceMoreActions, named: "notes.md more actions")
        sourceMoreActions.tap()
        XCTAssertTrue(app.buttons["Duplicate"].waitForExistence(timeout: 5), "Overflow should still expose duplicate without hiding it in a context-only gesture.")
        app.buttons["Duplicate"].tap()
        approveCurrentPolicyMutation(in: app)
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
        approveCurrentPolicyMutation(in: app)
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
        var trailingColumnSamples = 0
        var trailingColumnsWithVisiblePixels = 0
        let step = 3
        let trailingLongAxisStart = width >= height ? width * 2 / 3 : height * 2 / 3
        for longAxisPosition in stride(from: 0, to: max(width, height), by: step) {
            var visiblePixelsInColumn = 0
            var pixelsInColumn = 0
            for shortAxisPosition in stride(from: 0, to: min(width, height), by: step) {
                let x = width >= height ? longAxisPosition : shortAxisPosition
                let y = width >= height ? shortAxisPosition : longAxisPosition
                let index = y * bytesPerRow + x * bytesPerPixel
                let brightestChannel = Swift.max(data[index], Swift.max(data[index + 1], data[index + 2]))
                let isNonBlack = brightestChannel > 25
                if isNonBlack {
                    nonBlackCount += 1
                    visiblePixelsInColumn += 1
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
                pixelsInColumn += 1
            }

            if longAxisPosition >= trailingLongAxisStart {
                trailingColumnSamples += 1
                // Dark games may intentionally reserve most of a column for a
                // near-black sky or HUD. A genuinely stale portrait-width webview
                // leaves the entire trailing column black, so a small visible slice
                // is the robust signal that content reached this column.
                if visiblePixelsInColumn >= max(2, pixelsInColumn / 20) {
                    trailingColumnsWithVisiblePixels += 1
                }
            }
        }

        XCTAssertGreaterThan(nonBlackCount, 0, "Fullscreen screenshot should contain visible game pixels.", file: file, line: line)
        let bboxLongSpan = width >= height ? (maxX - minX + 1) : (maxY - minY + 1)
        let longAxis = max(width, height)
        let bboxLongAxisCoverage = CGFloat(bboxLongSpan) / CGFloat(longAxis)
        let trailingColumnCoverage = CGFloat(trailingColumnsWithVisiblePixels) / CGFloat(max(1, trailingColumnSamples))
        XCTAssertGreaterThanOrEqual(
            bboxLongAxisCoverage,
            0.92,
            "Fullscreen game content should span most of the landscape long axis, not a portrait-width strip. coverage=\(bboxLongAxisCoverage)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            trailingColumnCoverage,
            0.90,
            "Fullscreen game content should reach nearly every column in the trailing landscape area, not leave a portrait-width black strip. coverage=\(trailingColumnCoverage)",
            file: file,
            line: line
        )
    }

    @discardableResult
    private func capture(_ name: String, app: XCUIApplication) -> UIImage {
        let environment = ProcessInfo.processInfo.environment
        let captureMode = environment["NOVAFORGE_CAPTURE_MODE"] ??
            environment["TEST_RUNNER_NOVAFORGE_CAPTURE_MODE"] ??
            "all"
        let needsPixelProof = name.localizedCaseInsensitiveContains("fullscreen")
        if captureMode == "off", !needsPixelProof {
            // Assertion lanes get automatic XCTest failure screenshots. Avoid
            // encoding and writing the 100+ visual-census PNGs unless the
            // explicit visual lane requested them.
            return UIImage()
        }
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

        // SwiftUI full-screen covers occasionally publish a transient zero AX
        // frame while their visual layout is already settled. Re-read briefly
        // so the gate measures the real control instead of the hand-off frame.
        let deadline = Date().addingTimeInterval(5)
        var measuredFrame = element.frame
        while (measuredFrame.width < minimumMeasuredTarget || measuredFrame.height < minimumMeasuredTarget),
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            measuredFrame = element.frame
        }

        XCTAssertGreaterThanOrEqual(measuredFrame.width, minimumMeasuredTarget, "\(name) should be about 44pt wide for reliable touch.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(measuredFrame.height, minimumMeasuredTarget, "\(name) should be about 44pt tall for reliable touch.", file: file, line: line)
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
        preferredIdentifiedElement("composerModelNativeMenu", in: app)
    }

    private func runProgressToggle(in app: XCUIApplication) -> XCUIElement {
        preferredIdentifiedElement("runProgressToggle", in: app)
    }

    private func runControlSheet(in app: XCUIApplication) -> XCUIElement {
        let direct = app.otherElements["runControlSheet"].firstMatch
        if direct.exists { return direct }
        return app.descendants(matching: .any).matching(identifier: "runControlSheet").firstMatch
    }

    private func assertRunControlSheetPresented(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sheet = runControlSheet(in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Run details should present in its own sheet.", file: file, line: line)
        let drawer = app.descendants(matching: .any).matching(identifier: "runControlDrawer").firstMatch
        XCTAssertTrue(drawer.waitForExistence(timeout: 5), "The Run Details sheet should contain the progress drawer.", file: file, line: line)
        let closeButton = app.buttons["runControlCloseButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 3), "Run Details should expose a stable close control.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(closeButton.frame.width, 42, "The native Run Details toolbar close control should retain its full tappable visual frame.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(closeButton.frame.height, 42, "The native Run Details toolbar close control should retain its full tappable visual frame.", file: file, line: line)
    }

    private func jumpToLatestButton(in app: XCUIApplication) -> XCUIElement {
        let identifiedElement = preferredIdentifiedElement("jumpToLatest", in: app)
        if identifiedElement.exists { return identifiedElement }
        return app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Latest")).firstMatch
    }

    private func liveStreamingReadableContent(in app: XCUIApplication) -> XCUIElement {
        liveStreamingTextReveal(in: app)
    }

    private func liveStreamingTextReveal(in app: XCUIApplication) -> XCUIElement {
        let direct = app.staticTexts["liveResponseTranscript"]
        if direct.exists { return direct }
        let identifiedText = app.descendants(matching: .staticText).matching(identifier: "liveResponseTranscript").firstMatch
        if identifiedText.exists { return identifiedText }
        return app.descendants(matching: .any).matching(identifier: "liveResponseTranscript").firstMatch
    }

    private func assertNoLiveStreamingLineArtifacts(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "liveStreamingStatusProgress").firstMatch.exists,
            "Live response fields should not render an under-text decorative progress line.",
            file: file,
            line: line
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "streamingCaret").firstMatch.exists,
            "Live response fields should not render a vertical caret/blue-line artifact.",
            file: file,
            line: line
        )
    }

    private func liveStreamingCharacterCount(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let response = liveStreamingTextReveal(in: app)
        XCTAssertTrue(
            response.waitForExistence(timeout: 3),
            "Live response text should exist before measuring visible growth.",
            file: file,
            line: line
        )
        // The new transcript intentionally keeps accessibilityValue semantic
        // ("Writing response" / "Response complete") and checkpoints its
        // readable label at phrase boundaries instead of publishing a noisy
        // changing number on every frame. Measure the exposed transcript.
        let transcript = response.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty, transcript != "Preparing response" else { return 0 }
        return transcript.count
    }

    private func waitForLiveStreamingCharacterGrowth(
        in app: XCUIApplication,
        from baseline: Int,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = baseline
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            latest = liveStreamingCharacterCount(in: app, file: file, line: line)
            if latest > baseline { return latest }
        }
        XCTFail("Live stream character count did not grow beyond \(baseline) within \(timeout)s; latest=\(latest).", file: file, line: line)
        return latest
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
        preferredIdentifiedElement("chatBottomAccessory", in: app)
    }

    private func assertContained(
        _ child: XCUIElement,
        in container: XCUIElement,
        named name: String,
        tolerance: CGFloat = 1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(child.exists, "\(name) should exist before containment is measured.", file: file, line: line)
        XCTAssertTrue(container.exists, "\(name) container should exist before containment is measured.", file: file, line: line)
        XCTAssertFalse(child.frame.isEmpty, "\(name) should expose a measurable frame.", file: file, line: line)
        XCTAssertFalse(container.frame.isEmpty, "\(name) container should expose a measurable frame.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(child.frame.minX, container.frame.minX - tolerance, "\(name) should stay inside the container's leading edge.", file: file, line: line)
        XCTAssertLessThanOrEqual(child.frame.maxX, container.frame.maxX + tolerance, "\(name) should stay inside the container's trailing edge.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(child.frame.minY, container.frame.minY - tolerance, "\(name) should stay inside the container's top edge.", file: file, line: line)
        XCTAssertLessThanOrEqual(child.frame.maxY, container.frame.maxY + tolerance, "\(name) should stay inside the container's bottom edge.", file: file, line: line)
    }

    private func chatComposerInput(in app: XCUIApplication) -> XCUIElement {
        let textField = app.textFields["chatComposer"]
        if textField.exists { return textField }
        return app.textViews["chatComposer"]
    }

    private func identifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        preferredIdentifiedElement(identifier, in: app)
    }

    private func preferredIdentifiedElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let query = app.descendants(matching: .any).matching(identifier: identifier)
        if let visible = query.allElementsBoundByIndex.filter({ element in
            guard element.exists, !element.frame.isEmpty else { return false }
            return element.frame.intersects(app.frame)
        }).max(by: { lhs, rhs in
            if lhs.frame.maxY != rhs.frame.maxY {
                return lhs.frame.maxY < rhs.frame.maxY
            }
            return lhs.frame.width < rhs.frame.width
        }) {
            return visible
        }
        return query.firstMatch
    }

    private func waitForDebugProviderFixture(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let modelControl = composerModelControl(in: app)
        XCTAssertTrue(
            modelControl.waitForExistence(timeout: 8),
            "The deterministic provider fixture should expose the composer model control.",
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(8)
        while !modelControl.label.localizedCaseInsensitiveContains("OpenAI"), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(
            modelControl.label.localizedCaseInsensitiveContains("OpenAI"),
            "The deterministic OpenAI fixture should be installed before Send is exercised; label='\(modelControl.label)'.",
            file: file,
            line: line
        )
    }

    private func tapReadySendButton(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let send = app.buttons["sendMessageButton"]
        XCTAssertTrue(
            send.waitForExistence(timeout: 5),
            "Send should exist after a non-empty draft.",
            file: file,
            line: line
        )
        let ready = NSPredicate(format: "enabled == true AND value BEGINSWITH %@", "ready")
        let expectation = XCTNSPredicateExpectation(
            predicate: ready,
            object: send
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 12),
            .completed,
            "Send should wait for the canonical runtime to become ready instead of accepting a silent no-op tap.",
            file: file,
            line: line
        )
        send.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        print("NovaForge Send disposition: \(String(describing: send.value))")
    }

    private func approveCurrentPolicyMutation(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let review = app.otherElements["agentPolicyApprovalView"]
        XCTAssertTrue(
            review.waitForExistence(timeout: 8),
            "Workspace writes should surface the exact policy-bound change for review.",
            file: file,
            line: line
        )
        let approve = app.buttons["agentPolicyApproveButton"]
        XCTAssertTrue(
            approve.waitForExistence(timeout: 5),
            "The policy review should expose its explicit approval action.",
            file: file,
            line: line
        )
        approve.tap()
        XCTAssertTrue(
            review.waitForNonExistence(timeout: 8),
            "Approval review should dismiss after the exact mutation is resolved.",
            file: file,
            line: line
        )
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
        let matchingDocks = app.descendants(matching: .any).matching(labeledPredicate)
        if let visibleDock = matchingDocks.allElementsBoundByIndex.first(where: { element in
            element.exists && !element.frame.isEmpty && element.frame.intersects(app.frame)
        }) {
            return visibleDock
        }
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
        let accessory = bottomChatAccessory(in: app)
        XCTAssertTrue(dock.waitForExistence(timeout: 3), "Composer dock should be visible while the keyboard is up.")
        XCTAssertTrue(accessory.waitForExistence(timeout: 3), "Bottom chat accessory should remain visible while the keyboard is up.")
        XCTAssertLessThanOrEqual(accessory.frame.maxY, keyboard.frame.minY + 1, "The complete composer accessory should clear the keyboard/predictive bar.")
        XCTAssertLessThanOrEqual(keyboard.frame.minY - accessory.frame.maxY, 64, "Keyboard should dock directly below the complete composer accessory with only the system safe-area allowance.")
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
