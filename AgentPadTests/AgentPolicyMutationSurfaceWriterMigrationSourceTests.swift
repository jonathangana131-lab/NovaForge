import Foundation
import XCTest

final class AgentPolicyMutationSurfaceWriterMigrationSourceTests: XCTestCase {
    func testAssignedSurfacesHaveNoLegacyOrDirectMutationEscapeHatch()
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
                pattern: #"(?i)\b[a-z_][a-z0-9_]*workspace\.(write|delete|copy|move|createNewFile|createNewDirectory|makeDirectory|touch|reset)\s*\("#
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

    func testTerminalUsesOneTypedTerminalIdentityAndPublishesAfterReceipt()
        throws
    {
        let source = try source(named: "TerminalConsoleView.swift")
        assertContainsAll(
            source,
            [
                "import AgentPolicy",
                "import AgentTools",
                "let mutationOperationID = isMutating ? UUID() : nil",
                "policyRuntime.makeExecutionContext(",
                "conversationID: conversationID",
                "projectID: projectID",
                "sessionID: \"terminal\"",
                "terminal.run-command.v1:",
                ".performTerminal(",
                "TerminalCanonicalMutationOperation",
                ".runCommand(RunCommandArguments(command: cmd))",
            ]
        )

        let receipt = try XCTUnwrap(
            source.range(of: "let receipt = try await mutationDispatch.coordinator")
        )
        let successOutput = try XCTUnwrap(
            source.range(of: "output: draft.completedMutationSummary")
        )
        XCTAssertLessThan(receipt.lowerBound, successOutput.lowerBound)
        XCTAssertEqual(
            source.components(
                separatedBy: "let mutationOperationID = isMutating ? UUID() : nil"
            ).count - 1,
            1
        )
    }

    func testControlResetUsesTypedLineageAndPublishesAfterReceipt()
        throws
    {
        let source = try source(named: "SettingsView.swift")
        assertContainsAll(
            source,
            [
                "import AgentPolicy",
                "import AgentTools",
                "let conversationID = runtime.activeConversationID",
                "let operationID = UUID()",
                "policyRuntime.makeExecutionContext(",
                "conversationID: conversationID",
                "projectID: projectID",
                "sessionID: \"control\"",
                "control.reset-workspace.v1:",
                "policyRuntime.coordinator().performControl(",
                "ControlPolicyMutationOperation.resetWorkspace(",
                "ResetWorkspaceMutationArguments()",
            ]
        )

        let receipt = try XCTUnwrap(
            source.range(of: "policyRuntime.coordinator().performControl(")
        )
        let success = try XCTUnwrap(
            source.range(of: "runtime.noteWorkspaceChanged()")
        )
        XCTAssertLessThan(receipt.lowerBound, success.lowerBound)
    }

    func testSearchFixturesUseFilesOriginAndExactFilesScope() throws {
        let search = try source(named: "FilesView+Search.swift")
        let files = try source(named: "FilesView.swift")
        assertContainsAll(
            search,
            [
                "import AgentPolicy",
                "import AgentTools",
                "private func performSearchFixtureMutation(",
                "let operationID = UUID()",
                "return try await performFilesMutation(",
                ".makeDirectory(PathArguments(",
                ".writeFile(WriteFileArguments(",
                ".deletePath(PathArguments(",
                "try Task.checkCancellation()",
            ]
        )
        assertContainsAll(
            files,
            [
                "policyRuntime.makeExecutionContext(",
                "conversationID: scopeConversationID",
                "projectID: project.id",
                "policyRuntime.coordinator().performFiles(",
                "sessionID: \"files\"",
            ]
        )

        let receipt = try XCTUnwrap(
            search.range(of: "try await seedFileStressFixture()")
        )
        let success = try XCTUnwrap(
            search.range(of: "didSeedFileStress = true")
        )
        XCTAssertLessThan(receipt.lowerBound, success.lowerBound)
    }

    func testCancellationIsQuietAcrossTerminalControlAndFiles() throws {
        for name in [
            "TerminalConsoleView.swift",
            "SettingsView.swift",
            "FilesView+Search.swift",
        ] {
            let source = try source(named: name)
            XCTAssertTrue(
                source.contains("Task") &&
                    (source.contains("CancellationError") ||
                     source.contains("checkCancellation")),
                "\(name) does not retain an explicit cancellation path"
            )
        }
    }

    private func assignedSources() throws
        -> [(name: String, contents: String)]
    {
        try [
            "TerminalConsoleView.swift",
            "SettingsView.swift",
            "FilesView+Search.swift",
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
