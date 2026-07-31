import XCTest

final class SandboxToolExecutorTests: XCTestCase {
    private var root: URL!
    private var workspace: SandboxWorkspace!
    private var executor: SandboxToolExecutor!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeToolTests-\(UUID().uuidString)", isDirectory: true)
        workspace = SandboxWorkspace(rootURL: root, maxReadableBytes: 64)
        executor = SandboxToolExecutor(workspace: workspace)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testWriteAndReadTool() throws {
        let write = ToolRequest(
            id: "1",
            name: "write_file",
            arguments: ["path": "hello.txt", "contents": "hi"]
        )
        XCTAssertTrue(write.isMutating)
        XCTAssertTrue(try executor.testExecute(write).contains("Wrote"))

        let read = ToolRequest(id: "2", name: "read_file", arguments: ["path": "hello.txt"])
        XCTAssertFalse(read.isMutating)
        XCTAssertEqual(try executor.testExecute(read), "hi")
    }

    func testRunCommandTool() throws {
        let request = ToolRequest(
            id: "1",
            name: "run_command",
            arguments: ["command": "mkdir docs"]
        )
        XCTAssertTrue(request.isMutating)
        XCTAssertTrue(try executor.testExecute(request).contains("Created docs"))
    }

    func testMutatingToolCannotExecuteWithoutGatewayPermit() {
        let request = ToolRequest(
            id: "ungated-write",
            name: "write_file",
            arguments: ["path": "bypass.txt", "contents": "blocked"]
        )

        XCTAssertThrowsError(try executor.execute(request)) { error in
            XCTAssertEqual(error as? SandboxError, .workspaceMutationPermitRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bypass.txt").path))
    }

    func testValidateHTMLToolHandlesPathsWithSpaces() throws {
        try workspace.testWrite(
            "public/proof page.html",
            contents: """
            <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Proof</title></head><body><main><h1>Proof</h1></main></body></html>
            """
        )

        let request = ToolRequest(
            id: "html-space-path",
            name: "validate_html_file",
            arguments: ["path": "public/proof page.html", "profile": "page"]
        )

        let output = try executor.testExecute(request)
        XCTAssertTrue(output.contains("HTML validation for public/proof page.html"))
        XCTAssertTrue(output.contains("Result: ready for preview"))
    }

    func testMutatingFileToolsRejectMissingPayloadsWithoutChangingFiles() throws {
        let missingWritePayload = ToolRequest(
            id: "missing-write-payload",
            name: "write_file",
            arguments: ["path": "empty-created-by-bug.txt"]
        )
        XCTAssertThrowsError(try executor.testExecute(missingWritePayload)) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("empty-created-by-bug.txt").path),
            "write_file without contents must not silently create an empty file."
        )

        try workspace.testWrite("notes.txt", contents: "original")
        let missingAppendPayload = ToolRequest(
            id: "missing-append-payload",
            name: "append_file",
            arguments: ["path": "notes.txt"]
        )
        XCTAssertThrowsError(try executor.testExecute(missingAppendPayload)) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertEqual(try workspace.read("notes.txt"), "original")

        try workspace.testWrite("replace.txt", contents: "keep TARGET keep")
        let missingReplacementPayload = ToolRequest(
            id: "missing-replacement-payload",
            name: "replace_text",
            arguments: ["path": "replace.txt", "old": "TARGET"]
        )
        XCTAssertThrowsError(try executor.testExecute(missingReplacementPayload)) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertEqual(try workspace.read("replace.txt"), "keep TARGET keep")
    }

    func testReadOnlyRunCommandsDoNotRequireWriteApproval() throws {
        for command in ["pwd", "ls", "cat notes.txt", "grep needle notes.txt", "find Sources", "wc README.md", "head README.md", "validate_html index.html"] {
            let request = ToolRequest(id: command, name: "run_command", arguments: ["command": command])
            XCTAssertFalse(request.isMutating, "\(command) should be treated as read-only")
        }

        for command in ["mkdir docs", "  touch a.txt", "rm a.txt", "mv a b", "cp a b", "rm 'draft note.txt'"] {
            let request = ToolRequest(id: command, name: "run_command", arguments: ["command": command])
            XCTAssertTrue(request.isMutating, "\(command) should require write approval")
        }
    }

    func testReadRangeAndTailHandleOversizedFilesWithoutWholeRead() throws {
        let contents = (1...30)
            .map { "line-\($0)" }
            .joined(separator: "\n")
        try workspace.testWrite("Logs/big.log", contents: contents)
        XCTAssertThrowsError(try workspace.read("Logs/big.log")) { error in
            XCTAssertEqual(error as? SandboxError, .fileTooLarge)
        }

        let rangeRequest = ToolRequest(
            id: "range",
            name: "read_file_range",
            arguments: ["path": "Logs/big.log", "start_line": "10", "line_count": "3"]
        )
        XCTAssertEqual(
            try executor.testExecute(rangeRequest),
            "10|line-10\n11|line-11\n12|line-12"
        )

        let tailRequest = ToolRequest(
            id: "tail",
            name: "tail_file",
            arguments: ["path": "Logs/big.log", "line_count": "3"]
        )
        XCTAssertEqual(
            try executor.testExecute(tailRequest),
            "28|line-28\n29|line-29\n30|line-30"
        )
    }

    func testDiffHandlesOversizedFilesWithBoundedComparison() throws {
        let left = (1...40)
            .map { $0 == 30 ? "line-30-left" : "line-\($0)" }
            .joined(separator: "\n")
        let right = (1...40)
            .map { $0 == 30 ? "line-30-right" : "line-\($0)" }
            .joined(separator: "\n")
        try workspace.testWrite("Logs/left.log", contents: left)
        try workspace.testWrite("Logs/right.log", contents: right)
        XCTAssertThrowsError(try workspace.read("Logs/left.log"))

        let request = ToolRequest(
            id: "diff",
            name: "diff_files",
            arguments: ["left": "Logs/left.log", "right": "Logs/right.log"]
        )
        let output = try executor.testExecute(request)

        XCTAssertTrue(output.contains("--- Logs/left.log"))
        XCTAssertTrue(output.contains("+++ Logs/right.log"))
        XCTAssertTrue(output.contains("-30|line-30-left"))
        XCTAssertTrue(output.contains("+30|line-30-right"))
    }

    func testReplaceTextStreamsOversizedFileWithoutWholeRead() throws {
        let contents = (1...40)
            .map { $0 == 25 ? "line-25 TARGET" : "line-\($0)" }
            .joined(separator: "\n")
        try workspace.testWrite("Logs/replace.log", contents: contents)
        XCTAssertThrowsError(try workspace.read("Logs/replace.log"))

        let request = ToolRequest(
            id: "replace",
            name: "replace_text",
            arguments: [
                "path": "Logs/replace.log",
                "old": "line-25 TARGET",
                "new": "line-25 patched"
            ]
        )
        XCTAssertEqual(try executor.testExecute(request), "Replaced 1 occurrence(s) in Logs/replace.log.")

        let rangeRequest = ToolRequest(
            id: "range-after-replace",
            name: "read_file_range",
            arguments: ["path": "Logs/replace.log", "start_line": "24", "line_count": "3"]
        )
        XCTAssertEqual(
            try executor.testExecute(rangeRequest),
            "24|line-24\n25|line-25 patched\n26|line-26"
        )
    }

    func testValidateJSONAndOutlineHandleOversizedFilesWithoutWholeRead() throws {
        let oversizedJSON = "{\"items\":[" + (1...80).map(String.init).joined(separator: ",") + "]}"
        try workspace.testWrite("Data/large.json", contents: oversizedJSON)
        XCTAssertThrowsError(try workspace.read("Data/large.json")) { error in
            XCTAssertEqual(error as? SandboxError, .fileTooLarge)
        }

        let validateRequest = ToolRequest(
            id: "json",
            name: "validate_json",
            arguments: ["path": "Data/large.json"]
        )
        XCTAssertEqual(try executor.testExecute(validateRequest), "JSON validation for Data/large.json: ok")

        let source = (1...40)
            .map { index in
                switch index {
                case 8: "struct ReleaseAudit {"
                case 22: "    func verifyLargeFileHelpers() {}"
                case 36: "extension ReleaseAudit {}"
                default: "// filler line \(index) " + String(repeating: "x", count: 12)
                }
            }
            .joined(separator: "\n")
        try workspace.testWrite("Sources/Large.swift", contents: source)
        XCTAssertThrowsError(try workspace.read("Sources/Large.swift")) { error in
            XCTAssertEqual(error as? SandboxError, .fileTooLarge)
        }

        let outlineRequest = ToolRequest(
            id: "outline",
            name: "extract_outline",
            arguments: ["path": "Sources/Large.swift"]
        )
        let outline = try executor.testExecute(outlineRequest)
        XCTAssertTrue(outline.contains("8|struct ReleaseAudit {"), outline)
        XCTAssertTrue(outline.contains("22|func verifyLargeFileHelpers() {}"), outline)
        XCTAssertTrue(outline.contains("36|extension ReleaseAudit {}"), outline)
    }

    func testCopyToolRefusesToReplaceExistingFolder() throws {
        try workspace.testWrite("Drafts/keep.md", contents: "do not delete")
        try workspace.testWrite("proposal.md", contents: "replacement")

        let request = ToolRequest(
            id: "copy-over-folder",
            name: "copy_path",
            arguments: ["from": "proposal.md", "to": "Drafts"]
        )

        XCTAssertThrowsError(try executor.testExecute(request)) { error in
            XCTAssertEqual(error as? SandboxError, .directoryOverwriteDenied)
        }
        XCTAssertEqual(try workspace.read("Drafts/keep.md"), "do not delete")
        XCTAssertEqual(try workspace.read("proposal.md"), "replacement")
    }
}
