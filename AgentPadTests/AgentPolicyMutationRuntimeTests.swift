import AgentDomain
import Foundation
import XCTest
@testable import NovaForge

@MainActor
final class AgentPolicyMutationRuntimeTests: XCTestCase {
    func testSharedCompositionBuildsStableDomainSeparatedContext() throws {
        let runtime = AgentPolicyMutationRuntime.shared
        let operationID = UUID(
            uuidString: "11000000-0000-4000-8000-000000000001"
        )!
        let workspace = SandboxWorkspace(rootURL: URL(
            fileURLWithPath: "/tmp/novaforge-policy-runtime-tests",
            isDirectory: true
        ))

        let first = try runtime.makeExecutionContext(
            workspace: workspace,
            operationID: operationID,
            idempotencyKey: "runtime-composition:stable:v1"
        )
        let second = try runtime.makeExecutionContext(
            workspace: workspace,
            operationID: operationID,
            idempotencyKey: "runtime-composition:stable:v1"
        )

        XCTAssertEqual(first.lineage, second.lineage)
        XCTAssertEqual(first.callID, second.callID)
        XCTAssertEqual(first.operationAttemptID, second.operationAttemptID)
        XCTAssertEqual(first.cancellation, second.cancellation)
        XCTAssertEqual(first.conversationID, second.conversationID)
        XCTAssertEqual(first.executionNodeID, runtime.executionNodeID)
        XCTAssertEqual(second.executionNodeID, runtime.executionNodeID)

        let derivedIDs = [
            first.lineage.runID.rawValue,
            first.callID.rawValue,
            first.operationAttemptID.rawValue,
            first.cancellation.scopeID.rawValue,
            first.conversationID.rawValue,
        ]
        XCTAssertEqual(Set(derivedIDs).count, derivedIDs.count)
        XCTAssertFalse(derivedIDs.contains(operationID))
        XCTAssertNoThrow(try runtime.coordinator())
    }

    func testExplicitDurableLineageIsPreserved() throws {
        let runtime = AgentPolicyMutationRuntime.shared
        let workspace = SandboxWorkspace(rootURL: URL(
            fileURLWithPath: "/tmp/novaforge-policy-runtime-explicit",
            isDirectory: true
        ))
        let runID = UUID(uuidString: "22000000-0000-4000-8000-000000000002")!
        let callID = UUID(uuidString: "33000000-0000-4000-8000-000000000003")!
        let attemptID = UUID(uuidString: "44000000-0000-4000-8000-000000000004")!
        let conversationID = UUID(
            uuidString: "55000000-0000-4000-8000-000000000005"
        )!
        let projectID = UUID(
            uuidString: "66000000-0000-4000-8000-000000000006"
        )!

        let context = try runtime.makeExecutionContext(
            workspace: workspace,
            operationID: UUID(
                uuidString: "77000000-0000-4000-8000-000000000007"
            )!,
            idempotencyKey: "runtime-composition:explicit:v1",
            runID: runID,
            callID: callID,
            operationAttemptID: attemptID,
            conversationID: conversationID,
            projectID: projectID,
            sessionID: "session-explicit-v1"
        )

        XCTAssertEqual(context.lineage, .root(RunID(rawValue: runID)))
        XCTAssertEqual(context.callID, ToolCallID(rawValue: callID))
        XCTAssertEqual(
            context.operationAttemptID,
            AttemptID(rawValue: attemptID)
        )
        XCTAssertEqual(
            context.conversationID,
            ConversationID(rawValue: conversationID)
        )
        XCTAssertEqual(context.projectID, ProjectID(rawValue: projectID))
        XCTAssertEqual(context.sessionID, "session-explicit-v1")
    }
}
