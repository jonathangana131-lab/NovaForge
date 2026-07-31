import AgentDomain
import AgentTools
import Foundation
import XCTest

final class LocalAgentPlannerTests: XCTestCase {
    private var root: URL!
    private var workspace: SandboxWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgePlannerTests-\(UUID().uuidString)", isDirectory: true)
        workspace = SandboxWorkspace(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testGameCreationProducesValidatedOfflineArtifact() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "Make a slither game as an HTML file.",
            workspace: workspace
        ))

        XCTAssertEqual(
            plan.toolCalls.map(\.function.name),
            ["write_file", "validate_html_file", "file_info"]
        )
        XCTAssertTrue(plan.toolCalls[0].function.arguments.contains("slither-arena.html"))
        XCTAssertTrue(plan.toolCalls[0].function.arguments.contains("<canvas"))
    }

    func testGeneratedGameIsLandscapeReady() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "Build a responsive snake browser game",
            workspace: workspace
        ))

        XCTAssertTrue(plan.toolCalls[0].function.arguments.contains("orientation: landscape"))
        XCTAssertTrue(plan.completion.contains("rotate sideways"))
    }

    func testFlappyRequestBuildsFlappyMechanicsInsteadOfSnake() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "Build a Flappy Bird game for my phone",
            workspace: workspace
        ))
        let arguments = plan.toolCalls[0].function.arguments

        XCTAssertTrue(arguments.contains("flappy-flight.html"))
        XCTAssertTrue(arguments.contains("function flap"))
        XCTAssertTrue(arguments.contains("pipes"))
        XCTAssertFalse(arguments.contains("let snake"))
    }

    func testTetrisRequestBuildsFallingBlockMechanicsInsteadOfSnake() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "Create a Tetris game that works in landscape",
            workspace: workspace
        ))
        let arguments = plan.toolCalls[0].function.arguments

        XCTAssertTrue(arguments.contains("falling-blocks.html"))
        XCTAssertTrue(arguments.contains("const shapes"))
        XCTAssertTrue(arguments.contains("function clear"))
        XCTAssertFalse(arguments.contains("let snake"))
    }

    func testReadsExplicitFilePath() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(prompt: "open snake.html", workspace: workspace))

        XCTAssertEqual(plan.toolCalls.first?.function.name, "read_file")
        XCTAssertTrue(plan.toolCalls.first?.function.arguments.contains("snake.html") == true)
    }

    func testReadsQuotedUnicodePathWithSpacesAndModernExtension() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "read \"Sources/Étoile Feature.tsx\"",
            workspace: workspace
        ))

        XCTAssertEqual(plan.toolCalls.first?.function.name, "read_file")
        XCTAssertTrue(
            plan.toolCalls.first?.function.arguments
                .contains("Sources/Étoile Feature.tsx") == true
        )
    }

    func testReadsExplicitExtensionlessFilename() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "read file Makefile",
            workspace: workspace
        ))

        XCTAssertEqual(plan.toolCalls.first?.function.name, "read_file")
        XCTAssertTrue(plan.toolCalls.first?.function.arguments.contains("Makefile") == true)
    }

    func testQuotedSearchSeparatesQueryFromDirectoryFilter() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "search for \"needle value\" in \"Sources/Feature Widgets\"",
            workspace: workspace
        ))
        let call = try XCTUnwrap(plan.toolCalls.first)
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(call.function.arguments.utf8)
        )
        guard case let .object(arguments) = value else {
            return XCTFail("Expected object arguments")
        }

        XCTAssertEqual(call.function.name, "search_text")
        XCTAssertEqual(arguments["query"], .string("needle value"))
        XCTAssertEqual(arguments["path"], .string("Sources/Feature Widgets"))
    }

    func testListsWorkspaceFiles() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(prompt: "list files", workspace: workspace))

        XCTAssertEqual(plan.toolCalls.first?.function.name, "list_directory")
    }

    func testImprovesExistingGameFileInPlace() throws {
        try workspace.testWrite("arcade/slither.html", contents: "<html></html>")

        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "improve the slither game speed",
            workspace: workspace
        ))

        XCTAssertTrue(plan.toolCalls[0].function.arguments.contains("arcade/slither.html"))
    }

    func testLandingPagePromptProducesValidatedArtifact() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "Build a landing page for my robotics startup",
            workspace: workspace
        ))

        XCTAssertEqual(
            plan.toolCalls.map(\.function.name),
            ["write_file", "validate_html_file", "file_info"]
        )
        XCTAssertTrue(plan.toolCalls[0].function.arguments.contains("landing-page.html"))
    }

    func testWebsitePromptHonorsSafeExplicitPath() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "Create website demos/launch.html",
            workspace: workspace
        ))

        XCTAssertTrue(plan.toolCalls[0].function.arguments.contains("demos/launch.html"))
    }

    func testPortfolioPromptAvoidsOverwritingDefaultPath() throws {
        try workspace.testWrite("portfolio.html", contents: "existing")

        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "Make a portfolio web page",
            workspace: workspace
        ))

        XCTAssertTrue(plan.toolCalls[0].function.arguments.contains("portfolio-2.html"))
    }

    func testUnsafeExplicitWebPathFallsBackInsideWorkspace() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: "Build a dashboard page ../escape.html",
            workspace: workspace
        ))

        XCTAssertFalse(plan.toolCalls[0].function.arguments.contains("../"))
        XCTAssertTrue(plan.toolCalls[0].function.arguments.contains("dashboard.html"))
    }

    func testEveryDeterministicArtifactCallMatchesTheCompactLocalToolSchemas() throws {
        let registry = try SandboxToolCatalog.localAgentRegistry()
        let prompts = [
            "Build a responsive snake browser game",
            "Build a landing page for my robotics startup",
            "Create website demos/launch.html"
        ]

        for prompt in prompts {
            let plan = try XCTUnwrap(LocalAgentPlanner.plan(prompt: prompt, workspace: workspace))
            for call in plan.toolCalls {
                let arguments = try JSONDecoder().decode(
                    JSONValue.self,
                    from: Data(call.function.arguments.utf8)
                )
                XCTAssertNoThrow(
                    try registry.decode(name: call.function.name, arguments: arguments),
                    "\(call.function.name) emitted invalid arguments for prompt: \(prompt)"
                )
            }
        }
    }

    func testGrammarConstrainedDecisionsCompileToEverySupportedToolSchema() throws {
        let registry = try SandboxToolCatalog.localAgentRegistry()
        let decisions: [LocalAgentModelDecision] = [
            .init(action: "list_directory", path: "Sources", value: "", replacement: "", response: "Inspecting Sources."),
            .init(action: "list_tree", path: "", value: "", replacement: "", response: "Inspecting the tree."),
            .init(action: "workspace_summary", path: "", value: "", replacement: "", response: "Summarizing the workspace."),
            .init(action: "file_info", path: "README.md", value: "", replacement: "", response: "Checking the file."),
            .init(action: "read_file", path: "README.md", value: "", replacement: "", response: "Reading the file."),
            .init(action: "read_file_range", path: "README.md", value: "401,200", replacement: "", response: "Reading the matching range."),
            .init(action: "tail_file", path: "README.md", value: "120", replacement: "", response: "Reading the file tail."),
            .init(action: "search_text", path: "Sources", value: "TODO", replacement: "", response: "Searching the project."),
            .init(action: "write_file", path: "notes/proof.txt", value: "proof\n", replacement: "", response: "Preparing the file."),
            .init(action: "append_file", path: "notes/proof.txt", value: "more proof\n", replacement: "", response: "Preparing the next chunk."),
            .init(action: "replace_text", path: "README.md", value: "old", replacement: "new", response: "Preparing the edit."),
            .init(action: "validate_html_file", path: "game.html", value: "game", replacement: "", response: "Validating the game."),
            .init(action: "run_command", path: "", value: "pwd", replacement: "", response: "Preparing the command."),
        ]

        for decision in decisions {
            guard case let .tool(_, call) = try LocalAgentModelGrammar.compile(decision) else {
                XCTFail("Expected a tool for \(decision.action)")
                continue
            }
            let arguments = try JSONDecoder().decode(
                JSONValue.self,
                from: Data(call.function.arguments.utf8)
            )
            XCTAssertNoThrow(
                try registry.decode(
                    name: call.function.name,
                    arguments: arguments
                ),
                "Grammar compiler emitted invalid \(decision.action) arguments"
            )
        }
    }

    func testGrammarCompilerRejectsEscapingPathsBeforeToolPublication() {
        let unsafe = LocalAgentModelDecision(
            action: "write_file",
            path: "../outside.txt",
            value: "nope",
            replacement: "",
            response: "Writing."
        )
        XCTAssertThrowsError(try LocalAgentModelGrammar.compile(unsafe)) {
            XCTAssertEqual(
                $0 as? LocalAgentModelDecisionError,
                .invalidPath
            )
        }
    }

    func testGrammarCompilerKeepsConversationAsTextOnly() throws {
        let decision = LocalAgentModelDecision(
            action: "respond",
            path: "",
            value: "",
            replacement: "",
            response: "A closure captures behavior and the values it needs."
        )
        XCTAssertEqual(
            try LocalAgentModelGrammar.compile(decision),
            .respond("A closure captures behavior and the values it needs.")
        )
    }

    func testCompactGrammarDecisionDefaultsUnusedFields() throws {
        let responseData = Data(
            #"{"action":"respond","response":"Four comes after three."}"#.utf8
        )
        let response = try JSONDecoder().decode(
            LocalAgentModelDecision.self,
            from: responseData
        )
        XCTAssertEqual(
            try LocalAgentModelGrammar.compile(response),
            .respond("Four comes after three.")
        )

        let toolData = Data(
            #"{"action":"read_file","path":"Sources/App.swift"}"#.utf8
        )
        let tool = try JSONDecoder().decode(
            LocalAgentModelDecision.self,
            from: toolData
        )
        guard case let .tool(preface, call) = try LocalAgentModelGrammar
            .compile(tool) else {
            return XCTFail("Expected a compact tool decision")
        }
        XCTAssertEqual(preface, "I’ll read that file.")
        XCTAssertEqual(call.function.name, "read_file")
        let arguments = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(call.function.arguments.utf8)
        )
        XCTAssertEqual(
            arguments,
            .object(["path": .string("Sources/App.swift")])
        )
    }

    func testLocalAgentGrammarBindsTheFullActionSet() {
        for action in [
            "respond", "list_directory", "list_tree", "workspace_summary",
            "file_info", "read_file", "read_file_range", "tail_file",
            "search_text", "write_file", "append_file", "replace_text",
            "validate_html_file", "run_command",
        ] {
            XCTAssertTrue(LocalAgentModelGrammar.gbnf.contains("\\\"\(action)\\\""))
        }
        XCTAssertEqual(LocalAgentModelGrammar.compilerVersion, "3.3.0")
    }

    func testProjectContinuationChoosesProofInspectionWhenProofExists() throws {
        try workspace.testWrite(
            "proof.html",
            contents: """
            <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Proof</title></head><body><main><h1>Proof</h1></main></body></html>
            """
        )

        let plan = try XCTUnwrap(LocalAgentPlanner.plan(
            prompt: """
            NovaForge Project Continuation
            Project: Proof OS
            Mission: Verify the proof loop.
            Latest proof: proof.html — Artifact · proof.html
            Recommended next step: Review the latest proof.
            """,
            workspace: workspace
        ))

        let toolNames = plan.toolCalls.map(\.function.name)
        XCTAssertEqual(toolNames, ["workspace_summary", "file_info", "validate_html_file"])
        XCTAssertTrue(plan.intro.contains("Agent Plan:"))
        XCTAssertTrue(plan.completion.contains("Agent Proof: checked proof.html"))
    }

    func testProjectCommandIntentInstructionIncludesFocusAndOperatorNote() throws {
        let project = Project(name: "Artifact Polish", mission: "Make generated artifacts easier to use.")
        let summary = ProjectMissionSummarizer.summarize(
            project: project,
            conversations: [],
            toolRuns: [],
            terminalCommands: [],
            artifacts: [],
            fileChanges: [],
            events: []
        )

        let instruction = ProjectContinuationInstructionBuilder.makeInstruction(
            project: project,
            summary: summary,
            intent: .improveArtifact,
            operatorNote: "Focus on proof.html and make the preview more interactive."
        )

        XCTAssertTrue(instruction.contains("Project command: Improve Artifact"))
        XCTAssertTrue(instruction.contains("Command focus: Inspect the latest artifact"))
        XCTAssertTrue(instruction.contains("Operator note: Focus on proof.html"))
        XCTAssertTrue(instruction.contains("Intent Handling:"))
        XCTAssertTrue(instruction.contains("Fast Proof:"))
    }
}
