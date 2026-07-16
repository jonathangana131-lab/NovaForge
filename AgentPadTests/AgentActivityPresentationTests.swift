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
}

@MainActor
final class NovaForgeArtifactShortcutTests: XCTestCase {
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
