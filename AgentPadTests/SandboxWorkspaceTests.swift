import XCTest

final class SandboxWorkspaceTests: XCTestCase {
    private var root: URL!
    private var workspace: SandboxWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaForgeTests-\(UUID().uuidString)", isDirectory: true)
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

    func testFileToolsStayInsideWorkspace() throws {
        try workspace.write("notes/today.md", contents: "hello")
        XCTAssertEqual(try workspace.read("notes/today.md"), "hello")

        let items = try workspace.list("notes")
        XCTAssertEqual(items.map(\.name), ["today.md"])
    }

    func testListThrowsForMissingOrNondirectoryPaths() throws {
        XCTAssertThrowsError(try workspace.list("missing"))

        try workspace.write("notes.txt", contents: "hello")
        XCTAssertThrowsError(try workspace.list("notes.txt"))
    }

    func testOversizedReadsAreRejected() throws {
        try workspace.write("large.txt", contents: String(repeating: "x", count: 100))
        XCTAssertThrowsError(try workspace.read("large.txt")) { error in
            XCTAssertEqual(error as? SandboxError, .fileTooLarge)
        }
    }

    func testCopyDoesNotNeedReadableFileSize() throws {
        let contents = String(repeating: "x", count: 100)
        try workspace.write("large.txt", contents: contents)

        try workspace.copy(from: "large.txt", to: "large_copy.txt")

        let copied = try String(contentsOf: root.appendingPathComponent("large_copy.txt"), encoding: .utf8)
        XCTAssertEqual(copied, contents)
    }

    func testManualCreateFileDoesNotOverwriteExistingFiles() throws {
        try workspace.write("Drafts/plan.md", contents: "keep this")

        XCTAssertThrowsError(try workspace.createNewFile("Drafts/plan.md")) { error in
            XCTAssertEqual(error as? SandboxError, .pathAlreadyExists)
        }
        XCTAssertEqual(try workspace.read("Drafts/plan.md"), "keep this")
    }

    func testManualCreateDirectoryRejectsExistingPaths() throws {
        try workspace.makeDirectory("Drafts")

        XCTAssertThrowsError(try workspace.createNewDirectory("Drafts")) { error in
            XCTAssertEqual(error as? SandboxError, .pathAlreadyExists)
        }
    }

    func testManualCreateHelpersRejectWorkspaceRoot() throws {
        for rootPath in ["", ".", "./"] {
            XCTAssertThrowsError(try workspace.createNewFile(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.createNewDirectory(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
        }
    }

    func testManifestIncludesNestedFilesAndCapsDepth() throws {
        try workspace.write("Sources/App/Main.swift", contents: "print(1)")
        try workspace.write("Sources/App/Deep/Nested/TooDeep.swift", contents: "print(2)")
        try workspace.write("README.md", contents: "hello")

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
        try workspace.write("safe/inside.txt", contents: "Needle inside")
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
        try workspace.write("safe/inside.txt", contents: "Needle inside")
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
        try workspace.write("notes/today.txt", contents: "Needle inside")

        let report = try workspace.searchMatches(query: "Needle", maxFilesScanned: 10, maxDirectories: 10, maxMatches: 10)

        let match = try XCTUnwrap(report.matches.first)
        XCTAssertEqual(match.id, "notes/today.txt:1:Needle inside")
    }

    func testSearchMatchesCapsLargeWorkspacesAndFindsPaths() throws {
        for index in 1...8 {
            try workspace.write("Sources/Generated/Module\(index).swift", contents: "struct Module\(index) { let text = \"Needle \(index)\" }")
        }
        try workspace.write("Logs/huge.log", contents: String(repeating: "Needle in a huge generated log\n", count: 20))

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
        try workspace.write("keep.txt", contents: "safe")

        for rootPath in ["", ".", "./"] {
            XCTAssertThrowsError(try workspace.write(rootPath, contents: "oops")) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.append(rootPath, contents: "oops")) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.touch(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.makeDirectory(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.delete(rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.move(from: rootPath, to: "moved-root")) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
            XCTAssertThrowsError(try workspace.copy(from: "keep.txt", to: rootPath)) { error in
                XCTAssertEqual(error as? SandboxError, .workspaceRootMutationDenied)
            }
        }

        XCTAssertEqual(try workspace.read("keep.txt"), "safe")
    }

    func testCopyAndMoveRejectSameSourceAndDestination() throws {
        try workspace.write("notes/today.md", contents: "original")

        XCTAssertThrowsError(try workspace.copy(from: "notes/today.md", to: "notes/today.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertEqual(try workspace.read("notes/today.md"), "original")

        XCTAssertThrowsError(try workspace.move(from: "notes/today.md", to: "notes/today.md")) { error in
            XCTAssertEqual(error as? SandboxError, .invalidArguments)
        }
        XCTAssertEqual(try workspace.read("notes/today.md"), "original")
    }

    func testCopyAndMoveRejectFolderIntoOwnDescendant() throws {
        try workspace.write("Project/Sources/App.swift", contents: "print(1)")

        XCTAssertThrowsError(try workspace.copy(from: "Project", to: "Project/Sources/ProjectCopy")) { error in
            XCTAssertEqual(error as? SandboxError, .recursiveWorkspaceMutationDenied)
        }
        XCTAssertEqual(try workspace.read("Project/Sources/App.swift"), "print(1)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Project/Sources/ProjectCopy").path))

        XCTAssertThrowsError(try workspace.move(from: "Project", to: "Project/Sources/ProjectMoved")) { error in
            XCTAssertEqual(error as? SandboxError, .recursiveWorkspaceMutationDenied)
        }
        XCTAssertEqual(try workspace.read("Project/Sources/App.swift"), "print(1)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Project/Sources/ProjectMoved").path))
    }

    func testCopyAndMoveDoNotReplaceExistingDirectories() throws {
        try workspace.write("safe/keep.txt", contents: "keep")
        try workspace.write("source.txt", contents: "new")

        XCTAssertThrowsError(try workspace.copy(from: "source.txt", to: "safe")) { error in
            XCTAssertEqual(error as? SandboxError, .directoryOverwriteDenied)
        }
        XCTAssertEqual(try workspace.read("safe/keep.txt"), "keep")
        XCTAssertEqual(try workspace.read("source.txt"), "new")

        XCTAssertThrowsError(try workspace.move(from: "source.txt", to: "safe")) { error in
            XCTAssertEqual(error as? SandboxError, .directoryOverwriteDenied)
        }
        XCTAssertEqual(try workspace.read("safe/keep.txt"), "keep")
        XCTAssertEqual(try workspace.read("source.txt"), "new")
    }
}
