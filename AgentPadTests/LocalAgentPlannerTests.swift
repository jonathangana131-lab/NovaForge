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

    func testGameCreationPromptsReachModelInsteadOfCannedHTML() throws {
        let plan = LocalAgentPlanner.plan(prompt: "Make a slither game as an HTML file.", workspace: workspace)

        XCTAssertNil(plan, "Creative game prompts should reach the model instead of returning canned local HTML.")
    }

    func testGeneratedGamePromptsReachModelInsteadOfCannedToolPlan() throws {
        let plan = LocalAgentPlanner.plan(prompt: "Build a responsive snake browser game", workspace: workspace)

        XCTAssertNil(plan, "Creative browser-game prompts should be handled by the selected model.")
    }

    func testReadsExplicitFilePath() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(prompt: "open snake.html", workspace: workspace))

        XCTAssertEqual(plan.toolCalls.first?.function.name, "read_file")
        XCTAssertTrue(plan.toolCalls.first?.function.arguments.contains("snake.html") == true)
    }

    func testListsWorkspaceFiles() throws {
        let plan = try XCTUnwrap(LocalAgentPlanner.plan(prompt: "list files", workspace: workspace))

        XCTAssertEqual(plan.toolCalls.first?.function.name, "list_directory")
    }

    func testImprovesExistingGameFileReachesModel() throws {
        try workspace.write("arcade/slither.html", contents: "<html></html>")

        let plan = LocalAgentPlanner.plan(prompt: "improve the slither game speed", workspace: workspace)

        XCTAssertNil(plan, "Creative edits to existing HTML should reach the model instead of overwriting with canned output.")
    }

    func testLandingPagePromptReachesModelInsteadOfCannedHTML() throws {
        let plan = LocalAgentPlanner.plan(prompt: "Build a landing page for my robotics startup", workspace: workspace)

        XCTAssertNil(plan, "Creative web prompts should reach the model instead of returning canned local HTML.")
    }

    func testWebsitePromptWithExplicitPathReachesModel() throws {
        let plan = LocalAgentPlanner.plan(prompt: "Create website demos/launch.html", workspace: workspace)

        XCTAssertNil(plan, "Explicit creative web paths should be planned by the model, not by canned HTML.")
    }

    func testPortfolioPromptReachesModelEvenWhenDefaultPathExists() throws {
        try workspace.write("portfolio.html", contents: "existing")

        let plan = LocalAgentPlanner.plan(prompt: "Make a portfolio web page", workspace: workspace)

        XCTAssertNil(plan, "The model should decide how to update or avoid overwriting creative web artifacts.")
    }

    func testUnsafeExplicitWebPathStillReachesModel() throws {
        let plan = LocalAgentPlanner.plan(prompt: "Build a dashboard page ../escape.html", workspace: workspace)

        XCTAssertNil(plan, "Unsafe creative paths should not be converted into a deterministic local write.")
    }

    func testProjectContinuationChoosesProofInspectionWhenProofExists() throws {
        try workspace.write(
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
