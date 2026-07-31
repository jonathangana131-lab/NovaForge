import Foundation
import XCTest

final class AgentPolicyMutationAppRootChatWriterMigrationSourceTests:
    XCTestCase
{
    func testAssignedSourcesHaveNoLegacyOrDirectMutationEscapeHatch()
        throws
    {
        for source in try assignedSources() {
            for forbidden in [
                "WorkspaceMutationGateway",
                "WorkspaceMutationPermit",
                "WorkspaceMutationRequest",
                "WorkspaceMutationEffect",
                "WorkspaceMutationOperation",
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

    func testAppRootFixturesUseFixedTrustedSystemAndProjectOSOrigins()
        throws
    {
        let source = try source(named: "AppRootView.swift")
        assertContainsAll(
            source,
            [
                "import AgentPolicy",
                "import AgentTools",
                "let operationID = UUID()",
                "policyRuntime.makeExecutionContext(",
                "conversationID: conversationID",
                "projectID: projectID",
                "sessionID: \"debug-fixture:\\(ownerDescription)\"",
                "app-root.debug-fixture.v1:",
                "SeedWorkspaceEntry(path: path, contents: contents)",
                "coordinator.performTrustedSystem(",
                "TrustedSystemPolicyMutationOperation.seedWorkspace(",
                "coordinator.performProjectOS(",
                "ProjectOSPolicyMutationOperation.seedWorkspace(",
                "SeedWorkspaceMutationArguments(entries: entries)",
            ]
        )
        XCTAssertEqual(
            source.components(separatedBy: "origin: .projectOS").count - 1,
            2,
            "Only the two ProjectOS proof fixtures should use ProjectOS origin"
        )
        XCTAssertTrue(
            source.components(separatedBy: "try await installDebugWorkspaceFixture(").count - 1 == 5,
            "Every debug workspace fixture call must await its digest receipt"
        )
    }

    func testChatArtifactSaveCarriesExactAvailableScopeAndStableRetryIdentity()
        throws
    {
        let source = try source(named: "ChatMessages.swift")
        assertContainsAll(
            source,
            [
                "import AgentPolicy",
                "import AgentTools",
                "ChatMutationScope(actionScopeID: actionScopeID)",
                "@Environment(\\.chatMutationConversationID) private var conversationID",
                "@Environment(\\.chatMutationProjectID) private var projectID",
                "pendingSaveOperation.name == name",
                "operationID: operation.operationID",
                "artifact.chat-code-block.write-file.v1:",
                "conversationID: conversationID",
                "projectID: projectID",
                "sessionID: \"chat-code-artifact\"",
                "coordinator.performArtifact(",
                "ArtifactCanonicalMutationOperation.writeFile(",
                "WriteFileArguments(",
                "try Task.checkCancellation()",
                "AgentPolicyMutationServiceError",
                ".cancelled",
            ]
        )

        let receipt = try XCTUnwrap(
            source.range(of: "_ = try await coordinator.performArtifact(")
        )
        let success = try XCTUnwrap(
            source.range(of: "saveStatusMessage = \"Saved \\(name).\"")
        )
        XCTAssertLessThan(
            receipt.lowerBound,
            success.lowerBound,
            "Chat must publish save success only after the awaited digest receipt"
        )
    }

    func testProductionRunInitiationUsesSharedAgentSystemOwner() throws {
        let appRoot = try source(named: "AppRootView.swift")
        XCTAssertFalse(
            appRoot.contains("projectRuntime.send("),
            "Project execution must not fork a second legacy runtime owner"
        )
        XCTAssertEqual(
            appRoot.components(
                separatedBy: "agentSystemPresentation.start("
            ).count - 1,
            3,
            "Device smoke, manual project runs, and auto-continue must share AgentSystem"
        )
        assertContainsAll(
            appRoot,
            [
                "intent: .manual",
                "intent: .autoContinued",
                "agentSystemPresentation.hasBlockingActivity",
            ]
        )

        XCTAssertEqual(
            appRoot.components(separatedBy: "runtime.send(").count - 1,
            0,
            "AppRoot must not retain a legacy runtime send path"
        )
        let smokeStart = try XCTUnwrap(
            appRoot.range(of: "agentSystemPresentation.start(")
        )
        let prefix = appRoot[..<smokeStart.lowerBound]
        let activeConditions = activeCompilationConditions(in: prefix)
        XCTAssertTrue(
            activeConditions.contains {
                $0.contains("DEBUG") ||
                $0.contains("targetEnvironment(simulator)")
            },
            "The local smoke start escaped its debug-only block. " +
            "Active conditions: \(activeConditions)"
        )

        let chat = try source(named: "ChatView.swift")
        assertContainsAll(
            chat,
            [
                "agentSystemPresentation.startConfigured(",
                "agentSystemPresentation.retry(",
            ]
        )
    }

    private func assignedSources() throws
        -> [(name: String, contents: String)]
    {
        try ["AppRootView.swift", "ChatMessages.swift"].map { name in
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

    private func activeCompilationConditions(
        in sourcePrefix: Substring
    ) -> [String] {
        var stack: [String] = []
        for rawLine in sourcePrefix.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if ") {
                stack.append(String(line.dropFirst(4)))
            } else if line.hasPrefix("#elseif "), !stack.isEmpty {
                stack[stack.count - 1] = String(line.dropFirst(8))
            } else if line == "#else", !stack.isEmpty {
                stack[stack.count - 1] = "else(\(stack[stack.count - 1]))"
            } else if line == "#endif", !stack.isEmpty {
                stack.removeLast()
            }
        }
        return stack
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
