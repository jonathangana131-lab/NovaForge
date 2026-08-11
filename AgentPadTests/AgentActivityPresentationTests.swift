import XCTest
@testable import NovaForge

final class AgentActivityPresentationTests: XCTestCase {
    func testToolNamesMapToStableHumanCopy() {
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "read_file",
                arguments: ["path": "Sources/App.swift"]
            ).title,
            "Reading file"
        )
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "response renderer",
                detail: "Organizing the response"
            ).title,
            "Writing answer…"
        )
    }

    func testMutatingAndDiscoveryToolsUseGranularLiveVerbs() {
        let expectations = [
            ("write_file", "Creating file"),
            ("append_file", "Editing file"),
            ("make_directory", "Creating folder"),
            ("list_directory", "Browsing files"),
            ("search_text", "Searching files"),
        ]

        for (tool, expected) in expectations {
            XCTAssertEqual(
                AgentActivityPresentation.presentation(forToolName: tool).title,
                expected
            )
        }
    }

    func testCommandPresentationRecognizesProofWork() {
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "run_command",
                arguments: ["command": "xcodebuild -scheme AgentPad test"]
            ).title,
            "Running Xcode proof"
        )
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "run_command",
                arguments: ["command": "xcrun simctl io booted screenshot proof.png"]
            ).title,
            "Capturing proof"
        )
    }

    func testInternalDetailsDoNotLeakIntoVisibleCopy() {
        XCTAssertEqual(
            AgentActivityPresentation.humanizedVisibleText(
                "normalizing chunk 42",
                fallback: "Working"
            ),
            "Organizing the response"
        )
        XCTAssertEqual(
            AgentActivityPresentation.humanizedVisibleDetail("{\"debug\":true}"),
            "Details saved in History."
        )
        XCTAssertEqual(
            AgentActivityPresentation.humanizedVisibleText(
                "Forge live response",
                fallback: "Working"
            ),
            "Writing answer…"
        )
    }

    func testToolTargetsUseTheVisibleDetailRedactionBoundary() {
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "read_file",
                arguments: ["path": "Sources/App.swift"]
            ).target,
            "Sources/App.swift"
        )
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "read_file",
                arguments: ["path": "  {\"internal\":true}  "]
            ).target,
            "Details saved in History."
        )
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "read_file",
                arguments: [
                    "path": "   ",
                    "file": "Sources/Fallback.swift",
                ]
            ).target,
            "Sources/Fallback.swift"
        )
    }
}

@MainActor
final class NovaForgeArtifactShortcutTests: XCTestCase {
    private func makeIntentDefaults() throws -> (
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "NovaForgeIntentSignalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func testPlayableArtifactRegistryKeepsExactWorkspaceIdentity() throws {
        let suffix = UUID().uuidString
        let workspaceName = "HomeScreen-\(suffix)"
        let path = "games/arcade-\(suffix).html"

        NovaForgeArtifactShortcutRegistry.register(
            workspaceName: workspaceName,
            path: path,
            title: "Arcade Proof"
        )

        let entity = try XCTUnwrap(
            NovaForgeArtifactShortcutRegistry.all.first {
                $0.workspaceName == workspaceName && $0.path == path
            }
        )
        XCTAssertEqual(entity.id, "\(workspaceName)::\(path)")
        XCTAssertEqual(entity.title, "Arcade Proof")
    }

    func testPlayArtifactIntentHandoffIsConsumedExactlyOnce() {
        let entity = NovaForgeArtifactEntity(
            workspaceName: "Home Screen",
            path: "games/proof.html",
            title: "Proof Game"
        )

        NovaForgeIntentSignal.storePendingArtifact(entity)

        XCTAssertEqual(NovaForgeIntentSignal.takePendingArtifact(), entity)
        XCTAssertNil(NovaForgeIntentSignal.takePendingArtifact())
    }

    func testColdLaunchTabCommandIsConsumedExactlyOnce() throws {
        let fixture = try makeIntentDefaults()
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
        }
        NovaForgeIntentSignal.storePendingCommand(
            .openTab(NovaForgeTab.history.rawValue),
            defaults: fixture.defaults
        )

        XCTAssertEqual(
            NovaForgeIntentSignal.takePendingCommand(
                defaults: fixture.defaults
            ),
            .openTab(NovaForgeTab.history.rawValue)
        )
        XCTAssertNil(
            NovaForgeIntentSignal.takePendingCommand(
                defaults: fixture.defaults
            )
        )
    }

    func testColdLaunchAskCommandPreservesPromptAndWinsOverOlderTab()
        throws
    {
        let fixture = try makeIntentDefaults()
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
        }
        let prompt = "  Build the proof\nwithout losing this spacing.  "
        NovaForgeIntentSignal.storePendingCommand(
            .openTab(NovaForgeTab.control.rawValue),
            defaults: fixture.defaults
        )
        NovaForgeIntentSignal.storePendingCommand(
            .askPrompt(prompt),
            defaults: fixture.defaults
        )

        XCTAssertEqual(
            NovaForgeIntentSignal.takePendingCommand(
                defaults: fixture.defaults
            ),
            .askPrompt(prompt)
        )
    }

    func testLiveAcknowledgementCannotClearANewerPendingCommand() throws {
        let fixture = try makeIntentDefaults()
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
        }
        let newer = NovaForgeIntentSignal.PendingCommand.askPrompt(
            "Keep the newer command"
        )
        NovaForgeIntentSignal.storePendingCommand(
            newer,
            defaults: fixture.defaults
        )

        NovaForgeIntentSignal.acknowledgePendingCommand(
            .openTab(NovaForgeTab.forge.rawValue),
            defaults: fixture.defaults
        )
        XCTAssertEqual(
            NovaForgeIntentSignal.takePendingCommand(
                defaults: fixture.defaults
            ),
            newer
        )

        NovaForgeIntentSignal.storePendingCommand(
            newer,
            defaults: fixture.defaults
        )
        NovaForgeIntentSignal.acknowledgePendingCommand(
            newer,
            defaults: fixture.defaults
        )
        XCTAssertNil(
            NovaForgeIntentSignal.takePendingCommand(
                defaults: fixture.defaults
            )
        )
    }

    func testConsumedComposerHandoffCannotReappearAfterTabRoundTrip()
        throws
    {
        let pending = NovaForgeComposerDraftHandoff(
            prompt: "Build the proof",
            revision: 41
        )
        XCTAssertTrue(pending.shouldApply)
        XCTAssertNil(pending.consuming(revision: 40))

        let consumed = try XCTUnwrap(pending.consuming(revision: 41))
        XCTAssertEqual(consumed.prompt, "")
        XCTAssertEqual(consumed.revision, 42)
        XCTAssertFalse(consumed.shouldApply)

        // A tab round trip evaluates the retained handoff again. The cleared
        // value is inert, and its new revision invalidates the old render key.
        let afterTabRoundTrip = consumed
        XCTAssertFalse(afterTabRoundTrip.shouldApply)
        XCTAssertNil(afterTabRoundTrip.consuming(revision: 41))
    }
}

final class SettingsProviderReadinessModelResolverTests: XCTestCase {
    func testSelectedZenCardUsesItsPaidModelInsteadOfFreeDefault() {
        let modelID = SettingsProviderReadinessModelResolver.modelID(
            for: .openCodeZen,
            selectedProvider: .openCodeZen,
            selectedModelID: "glm-5.1"
        )

        XCTAssertEqual(modelID, "glm-5.1")
        XCTAssertTrue(AIProvider.openCodeZen.requiresCredential(for: modelID))
    }

    func testUnselectedZenCardUsesItsFreeDefaultSummary() {
        let modelID = SettingsProviderReadinessModelResolver.modelID(
            for: .openCodeZen,
            selectedProvider: .openAI,
            selectedModelID: AIProvider.exactGPT56SolModelID
        )

        XCTAssertEqual(modelID, AIProvider.openCodeZen.defaultModel)
        XCTAssertFalse(AIProvider.openCodeZen.requiresCredential(for: modelID))
    }
}

final class ForgeExperiencePresentationTests: XCTestCase {
    func testAssistantMarkdownRemovesSyntaxAndKeepsSemanticEmphasis() {
        let presentation = assistantMarkdownPresentation(
            """
            Here's what's in your sandbox:

            - **`game.html`** — game page
            - **`README.md`** — docs
            """
        )
        let visible = String(presentation.attributedText.characters)

        XCTAssertTrue(visible.contains("• game.html — game page"))
        XCTAssertTrue(visible.contains("• README.md — docs"))
        XCTAssertFalse(visible.contains("**"))
        XCTAssertFalse(visible.contains("`"))
        XCTAssertEqual(presentation.accessibilityText, visible)

        let intents = presentation.attributedText.runs.compactMap(\.inlinePresentationIntent)
        XCTAssertTrue(intents.contains { $0.contains(.stronglyEmphasized) })
        XCTAssertTrue(intents.contains { $0.contains(.code) })
    }

    func testLiveMarkdownKeepsSplitInlineFilenameCoherent() {
        let settled = "I inspected **`game."
        let active = "html`** and it is ready."
        let presentation = assistantLiveMarkdownPresentation(settled + active)
        let visible = String(presentation.attributedText.characters)

        XCTAssertEqual(visible, "I inspected game.html and it is ready.")
        XCTAssertFalse(visible.contains("**"))
        XCTAssertFalse(visible.contains("`"))
        XCTAssertTrue(
            presentation.attributedText.runs.contains {
                $0.inlinePresentationIntent?.contains(.code) == true
            }
        )
        XCTAssertTrue(
            presentation.attributedText.runs.contains {
                $0.markdownSourcePosition != nil
            }
        )
    }

    func testPlainAssistantProseKeepsInternalHyphensLiteral() {
        let source = "A display-paced answer stays readable without half-words or sudden jumps."

        XCTAssertFalse(assistantMarkdownRequiresParsing(source))
        XCTAssertEqual(
            String(assistantMarkdownPresentation(source).attributedText.characters),
            source
        )
        XCTAssertEqual(
            String(assistantLiveMarkdownPresentation(source).attributedText.characters),
            source
        )
    }

    func testAssistantMarkdownFastPathStillDefersRealMarkdownToParser() {
        let source = "Use **strong text** and `inline code`."

        XCTAssertTrue(assistantMarkdownRequiresParsing(source))
        let presentation = assistantLiveMarkdownPresentation(source)
        XCTAssertEqual(
            String(presentation.attributedText.characters),
            "Use strong text and inline code."
        )
        XCTAssertTrue(
            presentation.attributedText.runs.contains {
                $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }
        )
        XCTAssertTrue(
            presentation.attributedText.runs.contains {
                $0.inlinePresentationIntent?.contains(.code) == true
            }
        )
    }

    func testForgeConversationTitleHidesGeneratedTimestamp() {
        XCTAssertEqual(
            ForgeConversationTitle.displayTitle("NovaForge Jul 12, 9:44 PM"),
            "New chat"
        )
        XCTAssertEqual(
            ForgeConversationTitle.displayTitle("Game Build"),
            "Game Build"
        )
    }

    func testFirstPromptProducesUsefulConversationTitle() {
        XCTAssertEqual(
            ProjectNamingEngine.suggestedConversationTitle(
                prompt: "Build a smooth 3D driving game for iPhone"
            ),
            "Game Build"
        )
        XCTAssertTrue(ProjectNamingEngine.shouldRenameConversation("New chat"))
    }
}
