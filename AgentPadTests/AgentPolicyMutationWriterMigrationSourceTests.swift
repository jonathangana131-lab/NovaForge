import Foundation
import XCTest

final class AgentPolicyMutationWriterMigrationSourceTests: XCTestCase {
    func testEditorAndFilesWritersHaveNoLegacyMutationEscapeHatch()
        throws
    {
        for source in try assignedSources() {
            for forbidden in [
                "WorkspaceMutationGateway",
                "WorkspaceMutationPermit",
                "WorkspaceMutationRequest",
                "WorkspaceMutationEffect",
            ] {
                XCTAssertFalse(
                    source.contents.contains(forbidden),
                    "\(source.name) still references \(forbidden)"
                )
            }

            let directWriter = try NSRegularExpression(
                pattern: #"(?i)\b[a-z_][a-z0-9_]*workspace\.(write|delete|copy|move|createNewFile|createNewDirectory)\s*\("#
            )
            let range = NSRange(
                source.contents.startIndex..<source.contents.endIndex,
                in: source.contents
            )
            XCTAssertNil(
                directWriter.firstMatch(
                    in: source.contents,
                    range: range
                ),
                "\(source.name) still performs a direct SandboxWorkspace write"
            )
        }
    }

    func testEditorUsesExactTypedPolicyContextAndCanonicalWrite()
        throws
    {
        let source = try source(named: "CodeEditorView.swift")

        assertContainsAll(
            source,
            [
                "import AgentPolicy",
                "import AgentTools",
                "let operationID = UUID()",
                "policyRuntime.makeExecutionContext(",
                "conversationID: conversationID",
                "projectID: projectID",
                "coordinator.performEditor(",
                "EditorCanonicalMutationOperation.writeFile(",
                "WriteFileArguments(",
                "sessionID: \"editor\"",
            ]
        )
        XCTAssertEqual(
            source.components(separatedBy: "let operationID = UUID()").count - 1,
            1
        )

        let receiptBoundary = try XCTUnwrap(
            source.range(of: "coordinator.performEditor(")
        )
        let successBoundary = try XCTUnwrap(
            source.range(of: "lastSavedText = textToSave")
        )
        XCTAssertLessThan(
            receiptBoundary.lowerBound,
            successBoundary.lowerBound,
            "Editor success state must follow the awaited digest receipt"
        )
    }

    func testFilesUsesOnlyFixedOriginCanonicalAndPolicyOperations()
        throws
    {
        let files = try source(named: "FilesView.swift")
        let browser = try source(named: "FilesView+Browser.swift")

        assertContainsAll(
            files,
            [
                "import AgentPolicy",
                "import AgentTools",
                "operation: FilesCanonicalMutationOperation",
                "operation: FilesPolicyMutationOperation",
                "policyRuntime.makeExecutionContext(",
                "conversationID: scopeConversationID",
                "projectID: project.id",
                "policyRuntime.coordinator().performFiles(",
                "FilesCanonicalMutationOperation.makeDirectory(",
                "FilesPolicyMutationOperation.createFile(",
                "CreateFileMutationArguments(path: path)",
                "PathArguments(path: path)",
                "sessionID: \"files\"",
            ]
        )
        assertContainsAll(
            browser,
            [
                "import AgentPolicy",
                "import AgentTools",
                "FilesCanonicalMutationOperation.deletePath(",
                "PathArguments(path: deletedPath)",
                "FilesCanonicalMutationOperation.copyPath(",
                "MovePathArguments(from: path, to: destination)",
            ]
        )
        XCTAssertEqual(
            files.components(separatedBy: "let operationID = UUID()").count - 1,
            1,
            "Create file/folder must share one identity per submit action"
        )
        XCTAssertEqual(
            browser.components(separatedBy: "let operationID = UUID()").count - 1,
            2,
            "Delete and duplicate must each create one action identity"
        )
    }

    func testMutationCancellationIsQuietAndFailClosed() throws {
        let editor = try source(named: "CodeEditorView.swift")
        let files = try source(named: "FilesView.swift")

        for source in [editor, files] {
            assertContainsAll(
                source,
                [
                    "error is CancellationError",
                    "AgentPolicyMutationServiceError",
                    ".cancelled",
                ]
            )
        }
    }

    private func assignedSources() throws -> [(name: String, contents: String)] {
        try [
            "CodeEditorView.swift",
            "FilesView.swift",
            "FilesView+Browser.swift",
        ].map { name in
            (name: name, contents: try source(named: name))
        }
    }

    private func source(named name: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("AgentPad/Views", isDirectory: true)
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func assertContainsAll(
        _ source: String,
        _ requiredFragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for fragment in requiredFragments {
            XCTAssertTrue(
                source.contains(fragment),
                "Missing required source fragment: \(fragment)",
                file: file,
                line: line
            )
        }
    }
}
