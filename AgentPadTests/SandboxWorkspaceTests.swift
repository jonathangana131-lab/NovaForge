import XCTest

final class SandboxWorkspaceTests: XCTestCase {
    private var root: URL!
    private var workspace: SandboxWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = SandboxWorkspace(rootURL: root, maxReadableBytes: 64)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPathEscapesAreRejected() throws {
        XCTAssertThrowsError(try workspace.resolve("../outside.txt")) { error in
            XCTAssertEqual(error as? SandboxError, .pathEscapesWorkspace)
        }
        XCTAssertThrowsError(try workspace.resolve("/tmp/outside.txt")) { error in
            XCTAssertEqual(error as? SandboxError, .pathEscapesWorkspace)
        }
    }

    func testWorkspaceInitializationDoesNotCreateDirectories() {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeInitProof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: missingRoot) }

        _ = SandboxWorkspace(rootURL: missingRoot)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingRoot.path),
            "Constructing a workspace must stay read-only; the journaled seed/reset boundary owns root creation."
        )
    }

    func testFileToolsStayInsideWorkspace() throws {
        try workspace.testWrite("notes/today.md", contents: "hello")
        XCTAssertEqual(try workspace.read("notes/today.md"), "hello")

        let items = try workspace.list("notes")
        XCTAssertEqual(items.map(\.name), ["today.md"])
    }

    func testListThrowsForMissingOrNondirectoryPaths() throws {
        XCTAssertThrowsError(try workspace.list("missing"))

        try workspace.testWrite("notes.txt", contents: "hello")
        XCTAssertThrowsError(try workspace.list("notes.txt"))
    }

    func testOversizedReadsAreRejected() throws {
        try workspace.testWrite("large.txt", contents: String(repeating: "x", count: 100))
        XCTAssertThrowsError(try workspace.read("large.txt")) { error in
            XCTAssertEqual(error as? SandboxError, .fileTooLarge)
        }
    }

    func testCopyDoesNotNeedReadableFileSize() throws {
        let contents = String(repeating: "x", count: 100)
        try workspace.testWrite("large.txt", contents: contents)

        try workspace.testCopy(from: "large.txt", to: "large_copy.txt")

        let copied = try String(contentsOf: root.appendingPathComponent("large_copy.txt"), encoding: .utf8)
        XCTAssertEqual(copied, contents)
    }

    func testManualCreateFileDoesNotOverwriteExistingFiles() throws {
        try workspace.testWrite("Drafts/plan.md", contents: "keep this")

        XCTAssertThrowsError(try workspace.testCreateNewFile("Drafts/plan.md")) { error in
            XCTAssertEqual(error as? SandboxError, .pathAlreadyExists)
        }
        XCTAssertEqual(try workspace.read("Drafts/plan.md"), "keep this")
    }

    func testManualCreateDirectoryRejectsExistingPaths() throws {
        try workspace.testMakeDirectory("Drafts")

        XCTAssertThrowsError(try workspace.testCreateNewDirectory("Drafts")) { error in
            XCTAssertEqual(error as? SandboxError, .pathAlreadyExists)
        }
    }

    func testManualCreateHelpersRejectWorkspaceRoot() throws {
        for rootPath in ["", ".", "./"] {
            XCTAssertThrowsError(try workspace.testCreateNewFile(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.testCreateNewDirectory(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
        }
    }

    func testManifestIncludesNestedFilesAndCapsDepth() throws {
        try workspace.testWrite("Sources/App/Main.swift", contents: "print(1)")
        try workspace.testWrite("Sources/App/Deep/Nested/TooDeep.swift", contents: "print(2)")
        try workspace.testWrite("README.md", contents: "hello")

        let manifest = try workspace.manifest(maxItems: 20, maxDepth: 3).map(\.relativePath)

        XCTAssertTrue(manifest.contains("Sources/App/Main.swift"))
        XCTAssertTrue(manifest.contains("README.md"))
        XCTAssertFalse(manifest.contains("Sources/App/Deep/Nested/TooDeep.swift"))
    }

    func testSymlinkEscapesAreRejected() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try workspace.read("escape/secret.txt")) { error in
            XCTAssertEqual(error as? SandboxError, .pathEscapesWorkspace)
        }
    }

    func testDirectoryViewsSkipSymlinkEscapes() throws {
        try workspace.testWrite("safe/inside.txt", contents: "Needle inside")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "secret Needle".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        let rootList = try workspace.list().map(\.relativePath)
        XCTAssertTrue(rootList.contains("safe"))
        XCTAssertFalse(rootList.contains("escape"), "Files UI should not show links that resolve outside the workspace sandbox.")

        let manifest = try workspace.manifest(maxItems: 20, maxDepth: 4).map(\.relativePath)
        XCTAssertTrue(manifest.contains("safe/inside.txt"))
        XCTAssertFalse(manifest.contains { $0.hasPrefix("escape") }, "Provider workspace context must not include symlink-escaped files.")
    }

    func testSearchSkipsSymlinkEscapesWithoutReadingOutsideFiles() throws {
        try workspace.testWrite("safe/inside.txt", contents: "Needle inside")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try "Needle secret outside".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        let report = try workspace.searchMatches(query: "Needle", maxFilesScanned: 20, maxDirectories: 20, maxMatches: 20)

        XCTAssertEqual(report.matches.map(\.relativePath), ["safe/inside.txt"])
        XCTAssertEqual(report.skippedUnsafePaths, 1)
        XCTAssertFalse(report.capped, "Skipping an unsafe symlink is a security guard, not a smoothness cap.")
    }

    func testSearchMatchIDIsStableAndContentBased() throws {
        try workspace.testWrite("notes/today.txt", contents: "Needle inside")

        let report = try workspace.searchMatches(query: "Needle", maxFilesScanned: 10, maxDirectories: 10, maxMatches: 10)

        let match = try XCTUnwrap(report.matches.first)
        XCTAssertEqual(match.id, "notes/today.txt:1:Needle inside")
    }

    func testSearchMatchesCapsLargeWorkspacesAndFindsPaths() throws {
        for index in 1...8 {
            try workspace.testWrite("Sources/Generated/Module\(index).swift", contents: "struct Module\(index) { let text = \"Needle \(index)\" }")
        }
        try workspace.testWrite("Logs/huge.log", contents: String(repeating: "Needle in a huge generated log\n", count: 20))

        let report = try workspace.searchMatches(
            query: "Module3",
            maxFilesScanned: 4,
            maxDirectories: 8,
            maxMatches: 10,
            maxReadableFileBytes: 1_000
        )

        XCTAssertTrue(report.filesScanned <= 4)
        XCTAssertTrue(report.capped)
        XCTAssertTrue(report.matches.contains { $0.relativePath == "Sources/Generated/Module3.swift" })
    }

    func testRootMutationsAreRejected() throws {
        try workspace.testWrite("keep.txt", contents: "safe")

        for rootPath in ["", ".", "./"] {
            XCTAssertThrowsError(try workspace.testWrite(rootPath, contents: "oops")) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.testAppend(rootPath, contents: "oops")) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.testTouch(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.testMakeDirectory(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.testDelete(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.testMove(from: rootPath, to: "moved-root")) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.testCopy(from: "keep.txt", to: rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
        }

        XCTAssertEqual(try workspace.read("keep.txt"), "safe")
    }

    func testCopyAndMoveRejectSameSourceAndDestination() throws {
        try workspace.testWrite("notes/today.md", contents: "original")

        XCTAssertThrowsError(try workspace.testCopy(from: "notes/today.md", to: "notes/today.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertEqual(try workspace.read("notes/today.md"), "original")

        XCTAssertThrowsError(try workspace.testMove(from: "notes/today.md", to: "notes/today.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertEqual(try workspace.read("notes/today.md"), "original")
    }

    func testCopyAndMoveRejectFolderIntoOwnDescendant() throws {
        try workspace.testWrite("Project/Sources/App.swift", contents: "print(1)")

        XCTAssertThrowsError(try workspace.testCopy(from: "Project", to: "Project/Sources/ProjectCopy")) { error in
            XCTAssertEqual(error as? SandboxError, .recursiveWorkspaceMutationDenied)
        }
        XCTAssertEqual(try workspace.read("Project/Sources/App.swift"), "print(1)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Project/Sources/ProjectCopy").path))

        XCTAssertThrowsError(try workspace.testMove(from: "Project", to: "Project/Sources/ProjectMoved")) { error in
            XCTAssertEqual(error as? SandboxError, .recursiveWorkspaceMutationDenied)
        }
        XCTAssertEqual(try workspace.read("Project/Sources/App.swift"), "print(1)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Project/Sources/ProjectMoved").path))
    }

    func testCopyAndMoveDoNotReplaceExistingDirectories() throws {
        try workspace.testWrite("safe/keep.txt", contents: "keep")
        try workspace.testWrite("source.txt", contents: "new")

        XCTAssertThrowsError(try workspace.testCopy(from: "source.txt", to: "safe")) { error in
            XCTAssertEqual(error as? SandboxError, .directoryOverwriteDenied)
        }
        XCTAssertEqual(try workspace.read("safe/keep.txt"), "keep")
        XCTAssertEqual(try workspace.read("source.txt"), "new")

        XCTAssertThrowsError(try workspace.testMove(from: "source.txt", to: "safe")) { error in
            XCTAssertEqual(error as? SandboxError, .directoryOverwriteDenied)
        }
        XCTAssertEqual(try workspace.read("safe/keep.txt"), "keep")
        XCTAssertEqual(try workspace.read("source.txt"), "new")
    }
}

private actor TestWorkspaceMutationJournal: WorkspaceMutationJournaling {
    private var entries: [UUID: WorkspaceMutationJournalEntry] = [:]
    private var phases: [UUID: ToolOperationPhase] = [:]
    private var summaries: [UUID: String] = [:]
    private var errors: [UUID: String] = [:]

    func schedule(_ entry: WorkspaceMutationJournalEntry) async throws {
        if let existing = entries[entry.operationID], existing != entry {
            throw WorkspaceMutationJournalError.operationConflict(entry.operationID)
        }
        entries[entry.operationID] = entry
        phases[entry.operationID] = phases[entry.operationID] ?? .scheduled
    }

    func snapshot(operationID: UUID) async throws -> WorkspaceMutationJournalSnapshot? {
        guard let entry = entries[operationID], let phase = phases[operationID] else { return nil }
        return WorkspaceMutationJournalSnapshot(
            operationID: operationID,
            phase: phase,
            workspacePersistentID: entry.workspacePersistentID,
            workspaceName: entry.workspaceName,
            operationName: entry.operationName,
            argumentsHash: "test-journal",
            argumentsJSON: entry.argumentsJSON,
            targetPaths: entry.targetPaths,
            runID: entry.runID,
            projectID: entry.projectID,
            conversationID: entry.conversationID,
            toolCallID: entry.toolCallID,
            sourceRawValue: entry.source.rawValue,
            authorizationKind: entry.authorization.journalKind,
            authorizationDetail: entry.authorization.journalDetail,
            ownerDescription: entry.ownerDescription,
            riskRawValue: entry.risk.rawValue,
            resultSummary: summaries[operationID],
            errorMessage: errors[operationID],
            scheduledAt: entry.requestedAt,
            startedAt: nil,
            appliedAt: nil,
            completedAt: phase == .completed ? Date() : nil
        )
    }

    func transition(
        operationID: UUID,
        to phase: ToolOperationPhase,
        resultSummary: String?,
        errorMessage: String?,
        at timestamp: Date
    ) async throws {
        guard phases[operationID] != nil else {
            throw WorkspaceMutationJournalError.missingOperation(operationID)
        }
        phases[operationID] = phase
        if let resultSummary { summaries[operationID] = resultSummary }
        if let errorMessage { errors[operationID] = errorMessage }
    }
}

private enum WorkspaceMutationTestHarnessError: Error {
    case timedOut
    case missingResult
}

private final class WorkspaceMutationTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum WorkspaceMutationTestHarness {
    static func perform<Value: Sendable>(
        workspace: SandboxWorkspace,
        operation: WorkspaceMutationOperation,
        body: @escaping @Sendable (WorkspaceMutationPermit) throws -> Value
    ) throws -> Value {
        let completion = DispatchSemaphore(value: 0)
        let resultBox = WorkspaceMutationTestBox<Result<Value, Error>>()
        let bodyErrorBox = WorkspaceMutationTestBox<Error>()

        Task.detached {
            do {
                let request = try WorkspaceMutationRequest(
                    workspace: workspace,
                    operation: operation,
                    context: WorkspaceMutationContext(
                        source: .debugFixture,
                        authorization: .debugFixture,
                        ownerDescription: "unit-test mutation"
                    )
                )
                let valueBox = WorkspaceMutationTestBox<Value>()
                let gateway = WorkspaceMutationGateway.testing(
                    coordinator: AgentExecutionCoordinator(),
                    journal: TestWorkspaceMutationJournal()
                )
                _ = try await gateway.perform(request) { permit in
                    do {
                        let value = try body(permit)
                        valueBox.store(value)
                        return WorkspaceMutationEffect(
                            summary: "unit-test mutation",
                            changedPaths: operation.targetPaths
                        )
                    } catch {
                        bodyErrorBox.store(error)
                        throw error
                    }
                }
                guard let value = valueBox.load() else {
                    throw WorkspaceMutationTestHarnessError.missingResult
                }
                resultBox.store(.success(value))
            } catch {
                resultBox.store(.failure(bodyErrorBox.load() ?? error))
            }
            completion.signal()
        }

        guard completion.wait(timeout: .now() + 5) == .success else {
            throw WorkspaceMutationTestHarnessError.timedOut
        }
        guard let result = resultBox.load() else {
            throw WorkspaceMutationTestHarnessError.missingResult
        }
        return try result.get()
    }
}

extension SandboxWorkspace {
    func testWrite(_ path: String, contents: String) throws {
        try WorkspaceMutationTestHarness.perform(
            workspace: self,
            operation: .writeFile(path: path)
        ) { permit in
            try write(path, contents: contents, permit: permit)
        }
    }

    func testCreateNewFile(_ path: String, contents: String = "") throws {
        try WorkspaceMutationTestHarness.perform(
            workspace: self,
            operation: .createFile(path: path)
        ) { permit in
            try createNewFile(path, contents: contents, permit: permit)
        }
    }

    func testAppend(_ path: String, contents: String) throws {
        try WorkspaceMutationTestHarness.perform(
            workspace: self,
            operation: .appendFile(path: path)
        ) { permit in
            try append(path, contents: contents, permit: permit)
        }
    }

    func testTouch(_ path: String) throws {
        try WorkspaceMutationTestHarness.perform(
            workspace: self,
            operation: .touchFile(path: path)
        ) { permit in
            try touch(path, permit: permit)
        }
    }

    func testMakeDirectory(_ path: String) throws {
        try WorkspaceMutationTestHarness.perform(
            workspace: self,
            operation: .createDirectory(path: path)
        ) { permit in
            try makeDirectory(path, permit: permit)
        }
    }

    func testCreateNewDirectory(_ path: String) throws {
        try WorkspaceMutationTestHarness.perform(
            workspace: self,
            operation: .createDirectory(path: path)
        ) { permit in
            try createNewDirectory(path, permit: permit)
        }
    }

    func testDelete(_ path: String) throws {
        try WorkspaceMutationTestHarness.perform(
            workspace: self,
            operation: .deletePath(path: path)
        ) { permit in
            try delete(path, permit: permit)
        }
    }

    func testMove(from: String, to: String) throws {
        try WorkspaceMutationTestHarness.perform(
            workspace: self,
            operation: .movePath(from: from, to: to)
        ) { permit in
            try move(from: from, to: to, permit: permit)
        }
    }

    func testCopy(from: String, to: String) throws {
        try WorkspaceMutationTestHarness.perform(
            workspace: self,
            operation: .copyPath(from: from, to: to)
        ) { permit in
            try copy(from: from, to: to, permit: permit)
        }
    }
}

extension SandboxToolExecutor {
    func testExecute(_ request: ToolRequest) throws -> String {
        guard request.isMutating else { return try execute(request) }
        return try WorkspaceMutationTestHarness.perform(
            workspace: workspace,
            operation: testMutationOperation(for: request)
        ) { permit in
            try execute(request, permit: permit)
        }
    }

    private func testMutationOperation(for request: ToolRequest) -> WorkspaceMutationOperation {
        switch request.name {
        case "write_file":
            .writeFile(path: request.arguments["path"] ?? "")
        case "append_file":
            .appendFile(path: request.arguments["path"] ?? "")
        case "delete_path":
            .deletePath(path: request.arguments["path"] ?? "")
        case "move_path":
            .movePath(
                from: request.arguments["from"] ?? "",
                to: request.arguments["to"] ?? ""
            )
        case "copy_path":
            .copyPath(
                from: request.arguments["from"] ?? "",
                to: request.arguments["to"] ?? ""
            )
        case "make_directory":
            .createDirectory(path: request.arguments["path"] ?? "")
        case "run_command":
            .terminalCommand(
                command: request.arguments["command"] ?? "",
                targetPaths: []
            )
        default:
            .agentTool(
                name: request.name,
                targetPaths: ["path", "from", "to"]
                    .compactMap { request.arguments[$0] }
                    .filter { !$0.isEmpty }
            )
        }
    }
}

extension CommandRunner {
    func testRun(_ command: String) throws -> String {
        guard TerminalCommandDraft(command).isMutating else { return try run(command) }
        return try WorkspaceMutationTestHarness.perform(
            workspace: workspace,
            operation: .terminalCommand(command: command, targetPaths: [])
        ) { permit in
            try run(command, permit: permit)
        }
    }
}
