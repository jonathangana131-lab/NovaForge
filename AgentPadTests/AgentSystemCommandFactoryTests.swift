import AgentDomain
import Foundation
import XCTest
@testable import NovaForge

final class AgentSystemCommandFactoryTests: XCTestCase {
    func testSendPreservesExactPromptAndBindsEveryIdentity() throws {
        let identity = AgentFreshSendCommandIdentity(
            commandID: commandID(1),
            runID: runID(2),
            userItemID: itemID(3),
            correlationID: correlationID(4),
            cancellationScopeID: cancellationID(5)
        )
        let request = AgentFreshSendCommandRequest(
            identity: identity,
            conversationID: conversationID(6),
            projectID: projectID(7),
            workspaceID: workspaceID(8),
            executionNodeID: executionNodeID(9),
            prompt: "  preserve this prompt exactly\n",
            acceptedAt: AgentInstant(rawValue: 10),
            features: AgentFeatureSet(["canonical-tools", "v2"]),
            budget: AgentBudget(limits: .standard)
        )

        let command = try AgentSystemCommandFactory.send(request)
        XCTAssertEqual(command.header.commandID, identity.commandID)
        XCTAssertEqual(command.header.runID, identity.runID)
        XCTAssertEqual(command.header.correlationID, identity.correlationID)
        XCTAssertEqual(command.header.issuedAt, request.acceptedAt)
        guard case let .send(send) = command.payload else {
            return XCTFail("Expected send command")
        }
        XCTAssertEqual(send.context.lineage, .root(identity.runID))
        XCTAssertEqual(send.context.conversationID, request.conversationID)
        XCTAssertEqual(send.context.projectID, request.projectID)
        XCTAssertEqual(send.context.workspaceID, request.workspaceID)
        XCTAssertEqual(send.context.executionNodeID, request.executionNodeID)
        XCTAssertEqual(send.context.engineVersion, .agentHarnessV2)
        XCTAssertEqual(
            send.context.cancellation.scopeID,
            identity.cancellationScopeID
        )
        XCTAssertEqual(send.userItem.id, identity.userItemID)
        XCTAssertEqual(send.userItem.createdAt, request.acceptedAt)
        XCTAssertEqual(
            send.userItem.payload,
            .message(ModelMessage(
                role: .user,
                content: [.text(request.prompt)]
            ))
        )
    }

    func testSendRejectsBlankNullAndOversizedPrompt() {
        XCTAssertThrowsError(try makeSend(prompt: "  \n")) { error in
            XCTAssertEqual(
                error as? AgentSystemCommandFactoryError,
                .emptyPrompt
            )
        }
        XCTAssertThrowsError(try makeSend(prompt: "a\0b")) { error in
            XCTAssertEqual(
                error as? AgentSystemCommandFactoryError,
                .promptContainsNull
            )
        }
        let oversized = String(
            repeating: "x",
            count: AgentSystemCommandFactory.maximumPromptBytes + 1
        )
        XCTAssertThrowsError(try makeSend(prompt: oversized)) { error in
            XCTAssertEqual(
                error as? AgentSystemCommandFactoryError,
                .promptTooLarge(
                    actualBytes: oversized.utf8.count,
                    maximumBytes:
                        AgentSystemCommandFactory.maximumPromptBytes
                )
            )
        }
    }

    func testSendRejectsCrossDomainRawIdentityCollision() {
        let shared = uuid(70)
        let request = AgentFreshSendCommandRequest(
            identity: AgentFreshSendCommandIdentity(
                commandID: CommandID(rawValue: shared),
                runID: RunID(rawValue: shared),
                userItemID: itemID(71),
                correlationID: correlationID(72),
                cancellationScopeID: cancellationID(73)
            ),
            conversationID: conversationID(74),
            projectID: nil,
            workspaceID: workspaceID(75),
            executionNodeID: executionNodeID(76),
            prompt: "hello",
            acceptedAt: AgentInstant(rawValue: 77),
            features: AgentFeatureSet([]),
            budget: AgentBudget(limits: .standard)
        )
        XCTAssertThrowsError(try AgentSystemCommandFactory.send(request)) {
            XCTAssertEqual(
                $0 as? AgentSystemCommandFactoryError,
                .identityCollision
            )
        }
    }

    func testSendPreservesTypedContinuationAndRejectsMismatchedLineage()
        throws
    {
        let identity = AgentFreshSendCommandIdentity(
            commandID: commandID(80),
            runID: runID(81),
            userItemID: itemID(82),
            correlationID: correlationID(83),
            cancellationScopeID: cancellationID(84)
        )
        let parent = AgentRunLineage.root(runID(85))
        let lineage = AgentRunLineage.child(identity.runID, of: parent)
        let request = AgentFreshSendCommandRequest(
            identity: identity,
            conversationID: conversationID(86),
            projectID: projectID(87),
            workspaceID: workspaceID(88),
            executionNodeID: executionNodeID(89),
            prompt: "Continue exact work.",
            acceptedAt: AgentInstant(rawValue: 90),
            features: AgentFeatureSet([]),
            budget: AgentBudget(limits: .standard),
            lineage: lineage
        )
        let command = try AgentSystemCommandFactory.send(request)
        guard case let .send(send) = command.payload else {
            return XCTFail("Expected send command")
        }
        XCTAssertEqual(send.context.lineage, lineage)

        let mismatched = AgentFreshSendCommandRequest(
            identity: identity,
            conversationID: conversationID(86),
            projectID: projectID(87),
            workspaceID: workspaceID(88),
            executionNodeID: executionNodeID(89),
            prompt: "Reject mismatched lineage.",
            acceptedAt: AgentInstant(rawValue: 91),
            features: AgentFeatureSet([]),
            budget: AgentBudget(limits: .standard),
            lineage: .root(runID(92))
        )
        XCTAssertThrowsError(try AgentSystemCommandFactory.send(mismatched)) {
            XCTAssertEqual(
                $0 as? AgentSystemCommandFactoryError,
                .invalidLineage
            )
        }
    }

    func testCancelAndApprovalCommandsRemainExactRunBound() {
        let cancel = AgentSystemCommandFactory.cancel(
            commandID: commandID(20),
            runID: runID(21),
            issuedAt: AgentInstant(rawValue: 22),
            correlationID: correlationID(23),
            causationID: causationID(24)
        )
        XCTAssertEqual(cancel.header.runID, runID(21))
        guard case let .cancel(payload) = cancel.payload else {
            return XCTFail("Expected cancel command")
        }
        XCTAssertEqual(payload.reason, .userRequested)
        XCTAssertTrue(payload.propagateToDescendants)

        let approval = AgentSystemCommandFactory.approvalDecision(
            commandID: commandID(30),
            runID: runID(31),
            correlationID: correlationID(32),
            causationID: causationID(33),
            requestID: approvalID(34),
            callID: callID(35),
            decision: .approved,
            decidedAt: AgentInstant(rawValue: 36),
            rationale: "User approved exact request"
        )
        XCTAssertEqual(approval.header.runID, runID(31))
        guard case let .approvalDecision(payload) = approval.payload else {
            return XCTFail("Expected approval command")
        }
        XCTAssertEqual(payload.requestID, approvalID(34))
        XCTAssertEqual(payload.callID, callID(35))
        XCTAssertEqual(payload.decision, .approved)
    }
}

private func makeSend(prompt: String) throws -> AgentCommand {
    try AgentSystemCommandFactory.send(AgentFreshSendCommandRequest(
        identity: AgentFreshSendCommandIdentity(
            commandID: commandID(40),
            runID: runID(41),
            userItemID: itemID(42),
            correlationID: correlationID(43),
            cancellationScopeID: cancellationID(44)
        ),
        conversationID: conversationID(45),
        projectID: nil,
        workspaceID: workspaceID(46),
        executionNodeID: executionNodeID(47),
        prompt: prompt,
        acceptedAt: AgentInstant(rawValue: 48),
        features: AgentFeatureSet([]),
        budget: AgentBudget(limits: .standard)
    ))
}

private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

private func commandID(_ value: UInt8) -> CommandID {
    CommandID(rawValue: uuid(value))
}
private func runID(_ value: UInt8) -> RunID { RunID(rawValue: uuid(value)) }
private func itemID(_ value: UInt8) -> ModelItemID {
    ModelItemID(rawValue: uuid(value))
}
private func correlationID(_ value: UInt8) -> CorrelationID {
    CorrelationID(rawValue: uuid(value))
}
private func causationID(_ value: UInt8) -> CausationID {
    CausationID(rawValue: uuid(value))
}
private func cancellationID(_ value: UInt8) -> CancellationScopeID {
    CancellationScopeID(rawValue: uuid(value))
}
private func conversationID(_ value: UInt8) -> ConversationID {
    ConversationID(rawValue: uuid(value))
}
private func projectID(_ value: UInt8) -> ProjectID {
    ProjectID(rawValue: uuid(value))
}
private func workspaceID(_ value: UInt8) -> WorkspaceID {
    WorkspaceID(rawValue: uuid(value))
}
private func executionNodeID(_ value: UInt8) -> ExecutionNodeID {
    ExecutionNodeID(rawValue: uuid(value))
}
private func approvalID(_ value: UInt8) -> ApprovalRequestID {
    ApprovalRequestID(rawValue: uuid(value))
}
private func callID(_ value: UInt8) -> ToolCallID {
    ToolCallID(rawValue: uuid(value))
}
