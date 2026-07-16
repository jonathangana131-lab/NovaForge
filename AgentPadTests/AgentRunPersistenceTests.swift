import Foundation
import SwiftData
import XCTest

@MainActor
final class AgentRunPersistenceTests: XCTestCase {
    func testRunAndWriteAheadOperationRoundTripThroughVersionedStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("NovaForge.store")
        let runID = UUID()
        let retryID = UUID()
        let workspaceID = UUID()
        let projectID = UUID()
        let conversationID = UUID()
        let requestID = UUID()
        let responseID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let completedAt = startedAt.addingTimeInterval(8)

        do {
            let container = try makeContainer(storeURL: storeURL)
            let context = container.mainContext
            let record = AgentRunRecord(
                id: runID,
                status: .running,
                origin: .retry,
                conversationID: conversationID,
                projectID: projectID,
                workspaceID: workspaceID,
                workspaceName: "Default",
                requestMessageID: requestID,
                responseMessageID: responseID,
                provider: .openAI,
                modelID: "gpt-5.1",
                retryOfRunID: retryID,
                now: startedAt
            )
            record.transition(to: .completed, at: completedAt)

            let operation = ToolOperationRecord(
                runID: runID,
                projectID: projectID,
                conversationID: conversationID,
                workspaceID: workspaceID,
                workspaceName: "Default",
                toolCallID: "call_write_readme",
                toolName: "write_file",
                argumentsJSON: #"{"path":"README.md","content":"verified"}"#,
                targetPaths: ["README.md"],
                now: startedAt
            )
            operation.transition(to: .executing, at: startedAt.addingTimeInterval(1))
            operation.transition(to: .applied, at: startedAt.addingTimeInterval(2))
            operation.transition(to: .completed, at: completedAt, resultSummary: "Wrote README.md")

            let message = ChatMessage(
                id: responseID,
                role: .assistant,
                content: "README updated and verified.",
                runID: runID,
                runSequence: 3,
                runStatus: .completed
            )
            let toolRun = ToolRun(
                name: "write_file",
                argumentsJSON: #"{"path":"README.md"}"#,
                output: "Wrote README.md",
                status: .completed,
                isMutating: true,
                runID: runID,
                runSequence: 2,
                runStatus: .completed
            )

            context.insert(record)
            context.insert(operation)
            context.insert(message)
            context.insert(toolRun)
            try context.save()
        }

        do {
            let container = try makeContainer(storeURL: storeURL)
            let context = container.mainContext
            let records = try context.fetch(FetchDescriptor<AgentRunRecord>())
            let operations = try context.fetch(FetchDescriptor<ToolOperationRecord>())
            let messages = try context.fetch(FetchDescriptor<ChatMessage>())
            let toolRuns = try context.fetch(FetchDescriptor<ToolRun>())

            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.id, runID)
            XCTAssertEqual(record.status, .completed)
            XCTAssertEqual(record.origin, .retry)
            XCTAssertEqual(record.conversationID, conversationID)
            XCTAssertEqual(record.projectID, projectID)
            XCTAssertEqual(record.workspaceID, workspaceID)
            XCTAssertEqual(record.workspaceName, "Default")
            XCTAssertEqual(record.requestMessageID, requestID)
            XCTAssertEqual(record.responseMessageID, responseID)
            XCTAssertEqual(record.provider, .openAI)
            XCTAssertEqual(record.modelID, "gpt-5.1")
            XCTAssertEqual(record.retryOfRunID, retryID)
            XCTAssertEqual(record.startedAt, startedAt)
            XCTAssertEqual(record.completedAt, completedAt)

            let operation = try XCTUnwrap(operations.first)
            XCTAssertEqual(operation.runID, runID)
            XCTAssertEqual(operation.phase, .completed)
            XCTAssertEqual(operation.toolCallID, "call_write_readme")
            XCTAssertEqual(operation.toolName, "write_file")
            XCTAssertEqual(operation.targetPaths, ["README.md"])
            XCTAssertEqual(operation.argumentsHash.count, 64)
            XCTAssertEqual(operation.resultSummary, "Wrote README.md")
            XCTAssertEqual(operation.startedAt, startedAt.addingTimeInterval(1))
            XCTAssertEqual(operation.appliedAt, startedAt.addingTimeInterval(2))
            XCTAssertEqual(operation.completedAt, completedAt)

            let message = try XCTUnwrap(messages.first)
            XCTAssertEqual(message.runID, runID)
            XCTAssertEqual(message.runSequence, 3)
            XCTAssertEqual(message.runStatus, .completed)

            let toolRun = try XCTUnwrap(toolRuns.first)
            XCTAssertEqual(toolRun.runID, runID)
            XCTAssertEqual(toolRun.runSequence, 2)
            XCTAssertEqual(toolRun.runStatus, .completed)
        }
    }

    func testLegacyInitializersRemainSourceCompatibleAndDefaultRunLinksToNil() throws {
        let container = try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV1.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext
        let project = Project(name: "Legacy", workspaceName: "Default")
        let conversation = Conversation(title: "Existing conversation", project: project)
        let message = ChatMessage(role: .user, content: "Existing message", conversation: conversation)
        let toolRun = ToolRun(
            name: "read_file",
            argumentsJSON: #"{"path":"README.md"}"#,
            output: "Existing output",
            status: .completed,
            project: project
        )
        let settings = AgentSettings()

        context.insert(project)
        context.insert(conversation)
        context.insert(message)
        context.insert(toolRun)
        context.insert(settings)
        try context.save()

        XCTAssertNil(message.runIDString)
        XCTAssertNil(message.runSequence)
        XCTAssertNil(message.runStatusRawValue)
        XCTAssertNil(toolRun.runIDString)
        XCTAssertNil(toolRun.runSequence)
        XCTAssertNil(toolRun.runStatusRawValue)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentSettings>()), 1)
    }

    func testRuntimeReconcilesOnlyInterruptedWorkAndPropagatesLinkedStatuses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let workspaceRoot = directory.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("NovaForge.store")
        let queuedRunID = UUID()
        let runningRunID = UUID()
        let completedRunID = UUID()
        let scheduledOperationID = UUID()
        let executingOperationID = UUID()
        let appliedOperationID = UUID()
        let completedOperationID = UUID()
        let recoveryDate = Date(timeIntervalSince1970: 1_760_000_000)

        do {
            let container = try makeContainer(storeURL: storeURL)
            let context = container.mainContext

            let queuedRun = AgentRunRecord(id: queuedRunID, status: .queued)
            let runningRun = AgentRunRecord(id: runningRunID, status: .running)
            let completedRun = AgentRunRecord(id: completedRunID, status: .completed)
            let queuedMessage = ChatMessage(
                role: .user,
                content: "Queued request",
                runID: queuedRunID,
                runSequence: 0,
                runStatus: .queued
            )
            let runningMessage = ChatMessage(
                role: .assistant,
                content: "Partial response",
                runID: runningRunID,
                runSequence: 1,
                runStatus: .running
            )
            let completedMessage = ChatMessage(
                role: .assistant,
                content: "Finished response",
                runID: completedRunID,
                runSequence: 1,
                runStatus: .completed
            )
            let runningTool = ToolRun(
                name: "read_file",
                argumentsJSON: #"{"path":"README.md"}"#,
                status: .completed,
                runID: runningRunID,
                runSequence: 2,
                runStatus: .running
            )
            let completedTool = ToolRun(
                name: "read_file",
                argumentsJSON: #"{"path":"DONE.md"}"#,
                status: .completed,
                runID: completedRunID,
                runSequence: 2,
                runStatus: .completed
            )

            let scheduledOperation = ToolOperationRecord(
                id: scheduledOperationID,
                runID: runningRunID,
                toolName: "write_file",
                argumentsJSON: #"{"path":"scheduled.txt"}"#,
                phase: .scheduled
            )
            let executingOperation = ToolOperationRecord(
                id: executingOperationID,
                runID: runningRunID,
                toolName: "write_file",
                argumentsJSON: #"{"path":"executing.txt"}"#,
                phase: .executing
            )
            let appliedOperation = ToolOperationRecord(
                id: appliedOperationID,
                runID: runningRunID,
                toolName: "write_file",
                argumentsJSON: #"{"path":"applied.txt"}"#,
                phase: .applied
            )
            let completedOperation = ToolOperationRecord(
                id: completedOperationID,
                runID: completedRunID,
                toolName: "write_file",
                argumentsJSON: #"{"path":"complete.txt"}"#,
                phase: .completed,
                resultSummary: "Wrote complete.txt"
            )

            [queuedRun, runningRun, completedRun].forEach { context.insert($0) }
            [queuedMessage, runningMessage, completedMessage].forEach { context.insert($0) }
            [runningTool, completedTool].forEach { context.insert($0) }
            [scheduledOperation, executingOperation, appliedOperation, completedOperation].forEach { context.insert($0) }
            try context.save()

            let runtime = AgentRuntime(workspace: SandboxWorkspace(rootURL: workspaceRoot))
            let repairedCount = try runtime.reconcileInterruptedDurableWork(
                context: context,
                now: recoveryDate
            )

            XCTAssertEqual(repairedCount, 5)
            XCTAssertTrue(runtime.toasts.contains { $0.message.contains("Recovered 3 interrupted workspace receipts") })
        }

        do {
            let container = try makeContainer(storeURL: storeURL)
            let context = container.mainContext
            let runs = try context.fetch(FetchDescriptor<AgentRunRecord>())
            let messages = try context.fetch(FetchDescriptor<ChatMessage>())
            let tools = try context.fetch(FetchDescriptor<ToolRun>())
            let operations = try context.fetch(FetchDescriptor<ToolOperationRecord>())

            let queuedRun = try XCTUnwrap(runs.first { $0.id == queuedRunID })
            XCTAssertEqual(queuedRun.status, .interrupted)
            XCTAssertEqual(queuedRun.errorKind, .interrupted)
            XCTAssertNil(queuedRun.startedAt, "A queued run must not be rewritten as having started.")
            XCTAssertEqual(queuedRun.completedAt, recoveryDate)

            let runningRun = try XCTUnwrap(runs.first { $0.id == runningRunID })
            XCTAssertEqual(runningRun.status, .interrupted)
            XCTAssertEqual(runningRun.errorKind, .interrupted)
            XCTAssertEqual(runningRun.completedAt, recoveryDate)

            let completedRun = try XCTUnwrap(runs.first { $0.id == completedRunID })
            XCTAssertEqual(completedRun.status, .completed)
            XCTAssertNil(completedRun.errorKind)
            XCTAssertNotEqual(completedRun.completedAt, recoveryDate)

            XCTAssertEqual(messages.first { $0.runID == queuedRunID }?.runStatus, .interrupted)
            XCTAssertEqual(messages.first { $0.runID == runningRunID }?.runStatus, .interrupted)
            XCTAssertEqual(messages.first { $0.runID == completedRunID }?.runStatus, .completed)
            XCTAssertEqual(tools.first { $0.runID == runningRunID }?.runStatus, .interrupted)
            XCTAssertEqual(tools.first { $0.runID == completedRunID }?.runStatus, .completed)
            let runningMessageSequence = try XCTUnwrap(messages.first { $0.runID == runningRunID }?.runSequence)
            let runningToolSequence = try XCTUnwrap(tools.first { $0.runID == runningRunID }?.runSequence)
            XCTAssertNotEqual(runningMessageSequence, runningToolSequence)

            let scheduled = try XCTUnwrap(operations.first { $0.id == scheduledOperationID })
            XCTAssertEqual(scheduled.phase, .interrupted)
            XCTAssertNil(scheduled.startedAt, "A scheduled operation must remain provably not started.")
            XCTAssertEqual(scheduled.completedAt, recoveryDate)
            XCTAssertTrue(scheduled.errorMessage?.contains("before the workspace mutation started") == true)

            let executing = try XCTUnwrap(operations.first { $0.id == executingOperationID })
            XCTAssertEqual(executing.phase, .interrupted)
            XCTAssertNotNil(executing.startedAt)
            XCTAssertTrue(executing.errorMessage?.contains("while this mutation was executing") == true)

            let applied = try XCTUnwrap(operations.first { $0.id == appliedOperationID })
            XCTAssertEqual(applied.phase, .interrupted)
            XCTAssertNotNil(applied.appliedAt)
            XCTAssertTrue(applied.errorMessage?.contains("final receipt was interrupted") == true)

            let completed = try XCTUnwrap(operations.first { $0.id == completedOperationID })
            XCTAssertEqual(completed.phase, .completed)
            XCTAssertEqual(completed.resultSummary, "Wrote complete.txt")
        }
    }

    private func makeContainer(storeURL: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV1.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(url: storeURL)]
        )
    }
}
