import XCTest

final class CommandRunnerTests: XCTestCase {
    private struct TestTerminalLine: TerminalConsoleLineRepresenting, Equatable {
        let id: UUID
        let command: String
        let timestamp: Date
        let durationMs: Double
    }

    private struct SearchableTerminalLine: TerminalConsoleSearchableLineRepresenting, Equatable {
        let id: UUID
        let command: String
        let output: String
        let timestamp: Date
    }

    private var root: URL!
    private var workspace: SandboxWorkspace!
    private var runner: CommandRunner!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeCommandTests-\(UUID().uuidString)", isDirectory: true)
        workspace = SandboxWorkspace(rootURL: root)
        runner = CommandRunner(workspace: workspace)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSupportedCommands() throws {
        XCTAssertEqual(try runner.run("mkdir notes"), "Created notes")
        XCTAssertEqual(try runner.run("touch notes/a.md"), "Touched notes/a.md")
        XCTAssertTrue(try runner.run("ls notes").contains("a.md"))
        XCTAssertTrue(try runner.run("find").contains("notes/a.md"))
    }

    func testTouchAndMkdirRejectWorkspaceRoot() throws {
        try workspace.write("keep.txt", contents: "safe")

        for rootPath in [".", "./"] {
            XCTAssertThrowsError(try runner.run("touch \(rootPath)")) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try runner.run("mkdir \(rootPath)")) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
        }

        XCTAssertEqual(try workspace.read("keep.txt"), "safe")
    }

    func testRejectsShellOperators() throws {
        XCTAssertThrowsError(try runner.run("cat README.md | grep hi"))
        XCTAssertThrowsError(try runner.run("touch a && rm a"))
        XCTAssertThrowsError(try runner.run("cat a > b"))
    }

    func testQuotedOperatorCharactersAreSearchableText() throws {
        try workspace.write(
            "site/index page.html",
            contents: """
            <main>Alpha</main>
            copy a | b
            value > 1
            """
        )

        XCTAssertTrue(try runner.run("grep '<main>' \"site/index page.html\"").contains("site/index page.html:1"))
        XCTAssertTrue(try runner.run("grep \"a | b\" \"site/index page.html\"").contains("site/index page.html:2"))
        XCTAssertTrue(try runner.run("grep 'value > 1' \"site/index page.html\"").contains("site/index page.html:3"))

        let draft = TerminalCommandDraft("grep '<main>' \"site/index page.html\"")
        XCTAssertTrue(draft.canRun)
        XCTAssertNil(draft.argumentIssue)
    }

    func testUnquotedShellOperatorsStillBlockTerminalCommands() throws {
        let unsafeDraft = TerminalCommandDraft("grep main site/index.html > out.txt")
        XCTAssertFalse(unsafeDraft.canRun)
        XCTAssertEqual(unsafeDraft.argumentIssue, "Shell operators are not available in the safe iPhone terminal.")

        XCTAssertThrowsError(try runner.run("grep main site/index.html > out.txt")) { error in
            XCTAssertEqual(error as? SandboxError, .unsupportedCommand("shell operators are not available"))
        }
        XCTAssertThrowsError(try runner.run("grep main site/index.html | cat")) { error in
            XCTAssertEqual(error as? SandboxError, .unsupportedCommand("shell operators are not available"))
        }

        let unclosedQuoteDraft = TerminalCommandDraft("grep \"main site/index.html")
        XCTAssertFalse(unclosedQuoteDraft.canRun)
        XCTAssertEqual(unclosedQuoteDraft.argumentIssue, "Close the quoted argument before running.")
        XCTAssertThrowsError(try runner.run("grep \"main site/index.html")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
    }

    func testRejectsAmbiguousExtraArgumentsAndDeleteFlags() throws {
        try workspace.write("notes/a.md", contents: "keep")
        try workspace.write("notes/b.md", contents: "other")

        XCTAssertThrowsError(try runner.run("rm -rf notes/a.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertEqual(try workspace.read("notes/a.md"), "keep")

        XCTAssertThrowsError(try runner.run("pwd notes")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertThrowsError(try runner.run("ls notes extra")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertThrowsError(try runner.run("cat notes/a.md notes/b.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertThrowsError(try runner.run("grep keep notes extra")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertThrowsError(try runner.run("find notes extra")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertThrowsError(try runner.run("wc -l notes/a.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertThrowsError(try runner.run("head notes/a.md notes/b.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertThrowsError(try runner.run("head -n notes/a.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertThrowsError(try runner.run("head --bytes notes/a.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
    }

    func testGrepSearchesText() throws {
        try workspace.write("notes/a.md", contents: "alpha\nbeta\n")
        XCTAssertTrue(try runner.run("grep beta notes").contains("notes/a.md:2"))
    }

    func testTerminalCommandDraftMirrorsRunnerArgumentValidation() throws {
        let validSearch = TerminalCommandDraft("grep TODO .")
        XCTAssertTrue(validSearch.canRun)
        XCTAssertEqual(validSearch.commandName, "grep")
        XCTAssertNil(validSearch.argumentIssue)
        XCTAssertTrue(validSearch.guidance.contains("Searches matching lines"))

        let missingSearchPath = TerminalCommandDraft("grep TODO")
        XCTAssertFalse(missingSearchPath.canRun)
        XCTAssertEqual(missingSearchPath.argumentIssue, "grep needs a query and path, for example grep TODO .")
        XCTAssertEqual(missingSearchPath.guidance, missingSearchPath.argumentIssue)

        let extraPwdArgument = TerminalCommandDraft("pwd README.md")
        XCTAssertFalse(extraPwdArgument.canRun)
        XCTAssertEqual(extraPwdArgument.argumentIssue, "pwd does not take a path.")

        let mutatingDraft = TerminalCommandDraft("rm README.md")
        XCTAssertTrue(mutatingDraft.canRun)
        XCTAssertTrue(mutatingDraft.isMutating)
        XCTAssertTrue(mutatingDraft.guidance.contains("ask before running"))

        let badHeadDraft = TerminalCommandDraft("head -n README.md")
        XCTAssertFalse(badHeadDraft.canRun)
        XCTAssertEqual(badHeadDraft.argumentIssue, "head -n needs a numeric line count.")
    }

    func testTerminalConsoleMergeAddsExternalRecordsWithoutDuplicatingLocalRuns() throws {
        let firstTimestamp = Date(timeIntervalSince1970: 100)
        let localID = UUID()
        let localLine = TestTerminalLine(
            id: localID,
            command: "pwd",
            timestamp: firstTimestamp,
            durationMs: 7
        )
        let persistedLocalLine = TestTerminalLine(
            id: localID,
            command: "pwd",
            timestamp: firstTimestamp,
            durationMs: 8
        )
        let externalRecordLine = TestTerminalLine(
            id: UUID(),
            command: "ls",
            timestamp: Date(timeIntervalSince1970: 101),
            durationMs: 12
        )

        let merged = TerminalConsoleState.mergeLines(
            current: [localLine],
            recordLines: [persistedLocalLine, externalRecordLine],
            maxCount: 80
        )

        XCTAssertEqual(merged.map(\.id), [localID, externalRecordLine.id])
        XCTAssertEqual(merged.first?.durationMs, 8, "The persisted record should replace the optimistic local line with the same ID.")
        XCTAssertEqual(TerminalConsoleState.commandHistory(from: merged, maxCount: 80), ["pwd", "ls"])
    }

    func testTerminalConsoleFilteringMatchesCommandsAndBoundedOutput() throws {
        let commandMatch = SearchableTerminalLine(
            id: UUID(),
            command: "grep TODO .",
            output: "no matches",
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let outputMatch = SearchableTerminalLine(
            id: UUID(),
            command: "pwd",
            output: "/\nagent live terminal sync proof",
            timestamp: Date(timeIntervalSince1970: 101)
        )
        let boundedOutput = SearchableTerminalLine(
            id: UUID(),
            command: "cat long.log",
            output: String(repeating: "x", count: 24) + " delayed proof",
            timestamp: Date(timeIntervalSince1970: 102)
        )
        let lines = [commandMatch, outputMatch, boundedOutput]

        XCTAssertEqual(
            TerminalConsoleState.filteredLines(from: lines, query: "todo", outputLimit: 80).map(\.id),
            [commandMatch.id]
        )
        XCTAssertEqual(
            TerminalConsoleState.filteredLines(from: lines, query: "sync proof", outputLimit: 80).map(\.id),
            [outputMatch.id]
        )
        XCTAssertEqual(
            TerminalConsoleState.filteredLines(from: lines, query: "delayed proof", outputLimit: 10).map(\.id),
            []
        )
        XCTAssertEqual(
            TerminalConsoleState.filteredLines(from: lines, query: "delayed proof", outputLimit: 80).map(\.id),
            [boundedOutput.id]
        )
        XCTAssertEqual(
            TerminalConsoleState.filteredLines(from: lines, query: "   ", outputLimit: 80),
            lines
        )
    }

    func testCpAndMvKeepExistingFoldersSafe() throws {
        try workspace.write("Folder/keep.txt", contents: "keep")
        try workspace.write("source.txt", contents: "source")

        XCTAssertThrowsError(try runner.run("cp source.txt Folder")) { error in
            XCTAssertEqual(error as? SandboxError, .directoryOverwriteDenied)
        }
        XCTAssertEqual(try workspace.read("Folder/keep.txt"), "keep")

        XCTAssertThrowsError(try runner.run("mv source.txt Folder")) { error in
            XCTAssertEqual(error as? SandboxError, .directoryOverwriteDenied)
        }
        XCTAssertEqual(try workspace.read("Folder/keep.txt"), "keep")
        XCTAssertEqual(try workspace.read("source.txt"), "source")
    }

    func testHTMLValidationProfilesPagesAndGamesSeparately() throws {
        try workspace.write(
            "landing.html",
            contents: """
            <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Landing</title></head><body><main><h1>Ship</h1></main></body></html>
            """
        )
        let pageResult = try runner.run("validate_html --profile page landing.html")
        XCTAssertTrue(pageResult.contains("Profile: responsive page"))
        XCTAssertTrue(pageResult.contains("Result: ready for preview"))
        XCTAssertFalse(pageResult.contains("missing: script tag"), "Normal pages should not be falsely treated as broken games.")

        try workspace.write(
            "game.html",
            contents: """
            <!doctype html><html><head><meta name="viewport" content="width=device-width"></head><body><canvas id="game"></canvas><script>requestAnimationFrame(()=>{}); addEventListener('keydown', () => {});</script></body></html>
            """
        )
        let gameResult = try runner.run("validate_html --profile game game.html")
        XCTAssertTrue(gameResult.contains("Profile: playable game"))
        XCTAssertTrue(gameResult.contains("Result: ready for preview"))

        XCTAssertThrowsError(try runner.run("validate_html landing.html game.html")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
    }

    func testReadOnlyCommandsHandleFilesBeyondWorkspaceReadLimit() throws {
        workspace = SandboxWorkspace(rootURL: root, maxReadableBytes: 64)
        runner = CommandRunner(workspace: workspace)

        let body = (1...120).map { "line\($0) word" }.joined(separator: "\n")
        try workspace.write("large.txt", contents: body)
        XCTAssertThrowsError(try workspace.read("large.txt")) { error in
            XCTAssertEqual(error as? SandboxError, .fileTooLarge)
        }

        let head = try runner.run("head -n 3 large.txt")
        XCTAssertTrue(head.contains("line1 word"))
        XCTAssertTrue(head.contains("line2 word"))
        XCTAssertTrue(head.contains("line3 word"))
        XCTAssertTrue(head.contains("truncated"), "Head should be explicit when it returns only a safe prefix.")

        let wc = try runner.run("wc large.txt")
        XCTAssertTrue(wc.hasPrefix("120 240 "), wc)
        XCTAssertTrue(wc.hasSuffix(" large.txt"), wc)
    }

    func testHTMLValidationUsesBoundedPrefixForLargeFiles() throws {
        workspace = SandboxWorkspace(rootURL: root, maxReadableBytes: 64)
        runner = CommandRunner(workspace: workspace)

        let oversizedPage = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Landing</title></head><body><main><h1>Ship</h1></main></body></html>
        """ + String(repeating: "\n<!-- padding -->", count: 200)
        try workspace.write("large.html", contents: oversizedPage)
        XCTAssertThrowsError(try workspace.read("large.html")) { error in
            XCTAssertEqual(error as? SandboxError, .fileTooLarge)
        }

        let result = try runner.run("validate_html --profile page large.html")
        XCTAssertTrue(result.contains("Profile: responsive page"))
        XCTAssertTrue(result.contains("Result: ready for preview"))
    }
}
