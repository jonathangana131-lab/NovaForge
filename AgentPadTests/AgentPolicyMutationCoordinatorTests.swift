import AgentDomain
import AgentPolicy
import AgentTools
import Foundation
import XCTest
@testable import NovaForge

final class AgentPolicyMutationCoordinatorTests: XCTestCase {
    func testFailClosedDefaultHasNoAmbientAuthorizationGrant() throws {
        let configuration = try AgentPolicyMutationCoordinator
            .failClosedConfiguration()

        XCTAssertTrue(configuration.grants.isEmpty)
        XCTAssertTrue(configuration.user.allowedProjectIDs.isEmpty)
        XCTAssertTrue(configuration.user.allowedWorkspaceIDs.isEmpty)
        XCTAssertEqual(configuration.advisoryTimeoutMilliseconds, 1_000)
    }

    func testStableCallerIdentityBuildsExactTypedContextsAndReceipt()
        async throws
    {
        let prompt = CoordinatorTestApprovalPrompt()
        let probe = CoordinatorSystemFactoryProbe(expectedPrompt: prompt)
        let coordinator = try makeCoordinator(prompt: prompt, probe: probe)
        let operationID = UUID(
            uuidString: "10000000-0000-4000-8000-000000000001"
        )!
        let runID = RunID(rawValue: UUID(
            uuidString: "20000000-0000-4000-8000-000000000002"
        )!)
        let attemptID = AttemptID(rawValue: UUID(
            uuidString: "30000000-0000-4000-8000-000000000003"
        )!)
        let conversationID = ConversationID(rawValue: UUID(
            uuidString: "40000000-0000-4000-8000-000000000004"
        )!)
        let projectID = ProjectID(rawValue: UUID(
            uuidString: "50000000-0000-4000-8000-000000000005"
        )!)
        let executionNodeID = ExecutionNodeID(rawValue: UUID(
            uuidString: "60000000-0000-4000-8000-000000000006"
        )!)
        let cancellationScopeID = CancellationScopeID(rawValue: UUID(
            uuidString: "70000000-0000-4000-8000-000000000007"
        )!)
        let acceptedAt = AgentInstant(rawValue: 1_900_000_000_123)
        let context = try AgentPolicyMutationExecutionContext(
            workspace: workspace("stable-identity"),
            operationID: operationID,
            idempotencyKey: "editor-save:stable-identity:v1",
            lineage: .root(runID),
            operationAttemptID: attemptID,
            conversationID: conversationID,
            projectID: projectID,
            executionNodeID: executionNodeID,
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["policy-mutation-v2"]),
            cancellation: CancellationLineage(
                scopeID: cancellationScopeID
            ),
            sessionID: "session-stable-identity",
            backend: .onDevice
        )

        let receipt = try await coordinator.performEditor(
            context: context,
            operation: .writeFile(.init(
                path: "Sources/App.swift",
                contents: "private source"
            ))
        )

        let system = try XCTUnwrap(probe.systemsSnapshot().first)
        let recordedMutations = await system.recordsSnapshot()
        let record = try XCTUnwrap(recordedMutations.first)
        XCTAssertEqual(record.tag, .editorCanonical)
        XCTAssertEqual(record.scope.runContext.schemaVersion, .current)
        XCTAssertEqual(record.scope.runContext.lineage, .root(runID))
        XCTAssertEqual(record.scope.runContext.conversationID, conversationID)
        XCTAssertEqual(record.scope.runContext.projectID, projectID)
        XCTAssertEqual(
            record.scope.runContext.executionNodeID,
            executionNodeID
        )
        XCTAssertEqual(record.scope.runContext.acceptedAt, acceptedAt)
        XCTAssertEqual(
            record.scope.runContext.engineVersion,
            .agentHarnessV2
        )
        XCTAssertEqual(
            record.scope.runContext.cancellation.scopeID,
            cancellationScopeID
        )
        XCTAssertEqual(record.scope.sessionID, "session-stable-identity")
        XCTAssertEqual(record.callID, context.callID)
        XCTAssertNotEqual(record.callID.rawValue, operationID)
        XCTAssertEqual(record.operationAttemptID, attemptID)
        XCTAssertEqual(
            record.idempotencyKey,
            "editor-save:stable-identity:v1"
        )

        XCTAssertEqual(receipt.operationID, operationID)
        XCTAssertEqual(receipt.runID, runID)
        XCTAssertEqual(receipt.conversationID, conversationID)
        XCTAssertEqual(receipt.projectID, projectID)
        XCTAssertEqual(receipt.callID, context.callID)
        XCTAssertNotEqual(receipt.callID.rawValue, operationID)
        XCTAssertEqual(receipt.operationAttemptID, attemptID)
        XCTAssertEqual(receipt.origin, .editor)
    }

    func testDefaultTypedIdentitiesAreStableAndDomainSeparated() throws {
        let operationID = deterministicUUID(51)
        let first = try makeContext(
            workspace: workspace("domain-separated-identities"),
            operationID: operationID,
            idempotencyKey: "domain-separated:v1"
        )
        let second = try makeContext(
            workspace: workspace("domain-separated-identities"),
            operationID: operationID,
            idempotencyKey: "domain-separated:v1"
        )
        let firstIDs = [
            first.lineage.runID.rawValue,
            first.callID.rawValue,
            first.operationAttemptID.rawValue,
            first.cancellation.scopeID.rawValue,
        ]
        let secondIDs = [
            second.lineage.runID.rawValue,
            second.callID.rawValue,
            second.operationAttemptID.rawValue,
            second.cancellation.scopeID.rawValue,
        ]

        XCTAssertEqual(firstIDs, secondIDs)
        XCTAssertEqual(Set(firstIDs).count, firstIDs.count)
        XCTAssertFalse(firstIDs.contains(operationID))
        XCTAssertTrue(firstIDs.allSatisfy { uuid in
            let groups = uuid.uuidString.split(separator: "-")
            guard groups.count == 5,
                  groups[2].first == "8",
                  let variant = groups[3].first
            else { return false }
            return "89AB".contains(variant)
        })
    }

    func testExplicitProviderCallIDIsPreservedAndAccepted() async throws {
        let prompt = CoordinatorTestApprovalPrompt()
        let probe = CoordinatorSystemFactoryProbe(expectedPrompt: prompt)
        let coordinator = try makeCoordinator(prompt: prompt, probe: probe)
        let explicitCallID = ToolCallID(rawValue: deterministicUUID(61))
        let context = try makeContext(
            workspace: workspace("explicit-provider-call-id"),
            operationID: deterministicUUID(62),
            idempotencyKey: "explicit-provider-call-id:v1",
            callID: explicitCallID
        )
        let provider = try providerMutation(for: context)

        let receipt = try await coordinator.performAgentV2(
            context: context,
            descriptor: provider.descriptor,
            invocation: provider.invocation
        )

        XCTAssertEqual(context.callID, explicitCallID)
        XCTAssertEqual(receipt.callID, explicitCallID)
        let system = try XCTUnwrap(probe.systemsSnapshot().first)
        let records = await system.recordsSnapshot()
        XCTAssertEqual(records.first?.callID, explicitCallID)
    }

    func testConcurrentFirstUseConstructsExactlyOneSystemForWorkspace()
        async throws
    {
        let prompt = CoordinatorTestApprovalPrompt()
        let probe = CoordinatorSystemFactoryProbe(expectedPrompt: prompt)
        let coordinator = try makeCoordinator(prompt: prompt, probe: probe)
        let root = workspace("concurrent-singleton")
        let contexts = try (0 ..< 96).map { index in
            try makeContext(
                workspace: root,
                operationID: deterministicUUID(index + 1),
                idempotencyKey: "files-create:\(index):v1"
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for context in contexts {
                group.addTask { [coordinator, context] in
                    _ = try await coordinator.performFiles(
                        context: context,
                        operation: .makeDirectory(.init(path: "Folder"))
                    )
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(probe.constructionCount, 1)
        let cachedWorkspaceCount = await coordinator.cachedWorkspaceCount
        XCTAssertEqual(cachedWorkspaceCount, 1)
        let system = try XCTUnwrap(probe.systemsSnapshot().first)
        let recordedMutationCount = await system.recordsSnapshot().count
        XCTAssertEqual(recordedMutationCount, 96)
    }

    func testCanonicalRootAliasReusesCacheWhileDistinctRootsRemainIsolated()
        async throws
    {
        let prompt = CoordinatorTestApprovalPrompt()
        let probe = CoordinatorSystemFactoryProbe(expectedPrompt: prompt)
        let configuration = try AgentPolicyMutationCoordinator
            .failClosedConfiguration()
        let coordinator = AgentPolicyMutationCoordinator(
            configuration: configuration,
            approvalPrompt: prompt,
            systemFactory: { configuration, binding, approvalPrompt in
                probe.make(
                    configuration: configuration,
                    binding: binding,
                    approvalPrompt: approvalPrompt
                )
            }
        )
        let canonical = workspace("canonical-cache")
        let alias = SandboxWorkspace(rootURL: URL(
            fileURLWithPath:
                "/tmp/novaforge-policy-coordinator/canonical-cache/../canonical-cache",
            isDirectory: true
        ))
        let distinct = workspace("canonical-cache-distinct")

        _ = try await coordinator.performFiles(
            context: makeContext(
                workspace: canonical,
                operationID: deterministicUUID(101),
                idempotencyKey: "canonical:v1"
            ),
            operation: .touchFile(.init(path: "a.txt"))
        )
        _ = try await coordinator.performFiles(
            context: makeContext(
                workspace: alias,
                operationID: deterministicUUID(102),
                idempotencyKey: "alias:v1"
            ),
            operation: .touchFile(.init(path: "b.txt"))
        )
        _ = try await coordinator.performFiles(
            context: makeContext(
                workspace: distinct,
                operationID: deterministicUUID(103),
                idempotencyKey: "distinct:v1"
            ),
            operation: .touchFile(.init(path: "c.txt"))
        )

        XCTAssertEqual(probe.constructionCount, 2)
        let cachedWorkspaceCount = await coordinator.cachedWorkspaceCount
        XCTAssertEqual(cachedWorkspaceCount, 2)
        XCTAssertTrue(probe.everyPromptWasExpected)
        XCTAssertEqual(
            probe.configurationsSnapshot(),
            [configuration, configuration]
        )
    }

    func testForeignBindingAndForeignSystemFailBeforeDispatch() async throws {
        let prompt = CoordinatorTestApprovalPrompt()
        let configuration = try AgentPolicyMutationCoordinator
            .failClosedConfiguration()
        let requestedWorkspace = workspace("requested-binding")
        let foreignWorkspace = workspace("foreign-binding")
        let foreignBinding = try AgentPolicyWorkspaceBinding(
            workspace: foreignWorkspace
        )
        let untouchedProbe = CoordinatorSystemFactoryProbe(
            expectedPrompt: prompt
        )
        let foreignBindingCoordinator = AgentPolicyMutationCoordinator(
            configuration: configuration,
            approvalPrompt: prompt,
            systemFactory: { configuration, binding, approvalPrompt in
                untouchedProbe.make(
                    configuration: configuration,
                    binding: binding,
                    approvalPrompt: approvalPrompt
                )
            },
            bindingFactory: { _ in foreignBinding }
        )
        let context = try makeContext(
            workspace: requestedWorkspace,
            operationID: deterministicUUID(201),
            idempotencyKey: "foreign-binding:v1"
        )

        await expectCoordinatorError(.workspaceBindingMismatch) {
            try await foreignBindingCoordinator.performFiles(
                context: context,
                operation: .touchFile(.init(path: "blocked.txt"))
            )
        }
        XCTAssertEqual(untouchedProbe.constructionCount, 0)

        let requestedBinding = try AgentPolicyWorkspaceBinding(
            workspace: requestedWorkspace
        )
        let foreignSystemCoordinator = AgentPolicyMutationCoordinator(
            configuration: configuration,
            approvalPrompt: prompt,
            systemFactory: { _, _, _ in
                CoordinatorRecordingMutationSystem(
                    workspaceBinding: foreignBinding
                )
            },
            bindingFactory: { _ in requestedBinding }
        )
        await expectCoordinatorError(.systemBindingMismatch) {
            try await foreignSystemCoordinator.performFiles(
                context: context,
                operation: .touchFile(.init(path: "blocked.txt"))
            )
        }
    }

    func testEveryFacadeBindsItsExactOriginAndV1V2EngineVersion()
        async throws
    {
        let prompt = CoordinatorTestApprovalPrompt()
        let probe = CoordinatorSystemFactoryProbe(expectedPrompt: prompt)
        let coordinator = try makeCoordinator(prompt: prompt, probe: probe)
        let context = try makeContext(
            workspace: workspace("fixed-origins"),
            operationID: deterministicUUID(301),
            idempotencyKey: "fixed-origins:v1"
        )
        let provider = try providerMutation(for: context)

        var receipts: [AgentPolicyMutationReceipt] = []
        receipts.append(try await coordinator.performAgentV2(
            context: context,
            descriptor: provider.descriptor,
            invocation: provider.invocation
        ))
        receipts.append(try await coordinator.performV1Fallback(
            context: context,
            descriptor: provider.descriptor,
            invocation: provider.invocation
        ))
        receipts.append(try await coordinator.performEditor(
            context: context,
            operation: .writeFile(.init(path: "a", contents: "a"))
        ))
        receipts.append(try await coordinator.performEditor(
            context: context,
            operation: .createFile(.init(path: "b"))
        ))
        receipts.append(try await coordinator.performFiles(
            context: context,
            operation: .copyPath(.init(from: "a", to: "c"))
        ))
        receipts.append(try await coordinator.performFiles(
            context: context,
            operation: .touchFile(.init(path: "d"))
        ))
        receipts.append(try await coordinator.performTerminal(
            context: context,
            operation: .runCommand(.init(command: "mkdir e"))
        ))
        receipts.append(try await coordinator.performArtifact(
            context: context,
            operation: .appendFile(.init(path: "f", contents: "f"))
        ))
        receipts.append(try await coordinator.performControl(
            context: context,
            operation: .resetWorkspace(.init())
        ))
        receipts.append(try await coordinator.performProjectOS(
            context: context,
            operation: .replaceText(.init(
                path: "g",
                old: "old",
                new: "new"
            ))
        ))
        receipts.append(try await coordinator.performProjectOS(
            context: context,
            operation: .seedWorkspace(.init(entries: [
                .init(path: "h", contents: "h"),
            ]))
        ))
        receipts.append(try await coordinator.performTrustedSystem(
            context: context,
            operation: .makeDirectory(.init(path: "i"))
        ))
        receipts.append(try await coordinator.performTrustedSystem(
            context: context,
            operation: .createFile(.init(path: "j"))
        ))

        let expectedOrigins: [MutationOrigin] = [
            .agentV2,
            .v1Fallback,
            .editor,
            .editor,
            .files,
            .files,
            .terminal,
            .artifact,
            .control,
            .projectOS,
            .projectOS,
            .trustedSystem,
            .trustedSystem,
        ]
        XCTAssertEqual(receipts.map(\.origin), expectedOrigins)

        let system = try XCTUnwrap(probe.systemsSnapshot().first)
        let records = await system.recordsSnapshot()
        XCTAssertEqual(records.map(\.origin), expectedOrigins)
        XCTAssertEqual(
            records.map(\.tag),
            CoordinatorMutationCallTag.allCases
        )
        XCTAssertEqual(
            records.map { $0.scope.runContext.engineVersion },
            [
                .agentHarnessV2,
                .agentHarnessV1,
                .agentHarnessV2,
                .agentHarnessV2,
                .agentHarnessV2,
                .agentHarnessV2,
                .agentHarnessV2,
                .agentHarnessV2,
                .agentHarnessV2,
                .agentHarnessV2,
                .agentHarnessV2,
                .agentHarnessV2,
                .agentHarnessV2,
            ]
        )
    }

    func testProviderIdentityMismatchAndForgedReceiptOriginFailClosed()
        async throws
    {
        let prompt = CoordinatorTestApprovalPrompt()
        let probe = CoordinatorSystemFactoryProbe(expectedPrompt: prompt)
        let coordinator = try makeCoordinator(prompt: prompt, probe: probe)
        let context = try makeContext(
            workspace: workspace("provider-identity"),
            operationID: deterministicUUID(401),
            idempotencyKey: "provider-identity:v1"
        )
        let provider = try providerMutation(
            for: context,
            callID: ToolCallID()
        )

        await expectCoordinatorError(.providerInvocationIdentityMismatch) {
            try await coordinator.performAgentV2(
                context: context,
                descriptor: provider.descriptor,
                invocation: provider.invocation
            )
        }
        XCTAssertEqual(probe.constructionCount, 0)

        let forgedProbe = CoordinatorSystemFactoryProbe(
            expectedPrompt: prompt,
            forcedResultOrigin: .control
        )
        let forgedCoordinator = try makeCoordinator(
            prompt: prompt,
            probe: forgedProbe
        )
        await expectCoordinatorError(.receiptOriginMismatch) {
            try await forgedCoordinator.performEditor(
                context: context,
                operation: .createFile(.init(path: "never-public.txt"))
            )
        }
    }

    func testSanitizedReceiptCannotEncodeUnclassifiedContentOrEvidence()
        async throws
    {
        let prompt = CoordinatorTestApprovalPrompt()
        let probe = CoordinatorSystemFactoryProbe(expectedPrompt: prompt)
        let coordinator = try makeCoordinator(prompt: prompt, probe: probe)
        let context = try makeContext(
            workspace: workspace("receipt-sanitizer"),
            operationID: deterministicUUID(501),
            idempotencyKey: "receipt-sanitizer:v1"
        )

        let receipt = try await coordinator.performTerminal(
            context: context,
            operation: .runCommand(.init(command: "touch private.txt"))
        )
        let encoded = try JSONEncoder().encode(receipt)
        let publicCopy = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(publicCopy.contains(CoordinatorSecrets.summary))
        XCTAssertFalse(publicCopy.contains(CoordinatorSecrets.commandOutput))
        XCTAssertFalse(publicCopy.contains(CoordinatorSecrets.path))
        XCTAssertFalse(publicCopy.contains("touch private.txt"))
        XCTAssertEqual(receipt.origin, .terminal)
    }

    private func makeCoordinator(
        prompt: CoordinatorTestApprovalPrompt,
        probe: CoordinatorSystemFactoryProbe
    ) throws -> AgentPolicyMutationCoordinator {
        AgentPolicyMutationCoordinator(
            configuration: try AgentPolicyMutationCoordinator
                .failClosedConfiguration(),
            approvalPrompt: prompt,
            systemFactory: { configuration, binding, approvalPrompt in
                probe.make(
                    configuration: configuration,
                    binding: binding,
                    approvalPrompt: approvalPrompt
                )
            }
        )
    }

    private func expectCoordinatorError<T: Sendable>(
        _ expected: AgentPolicyMutationCoordinatorError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected coordinator rejection", file: file, line: line)
        } catch let error as AgentPolicyMutationCoordinatorError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func makeContext(
        workspace: SandboxWorkspace,
        operationID: UUID,
        idempotencyKey: String,
        callID: ToolCallID? = nil
    ) throws -> AgentPolicyMutationExecutionContext {
        try AgentPolicyMutationExecutionContext(
            workspace: workspace,
            operationID: operationID,
            idempotencyKey: idempotencyKey,
            callID: callID,
            conversationID: ConversationID(rawValue: deterministicUUID(901)),
            projectID: ProjectID(rawValue: deterministicUUID(902)),
            executionNodeID: ExecutionNodeID(
                rawValue: deterministicUUID(903)
            ),
            acceptedAt: AgentInstant(rawValue: 1_900_000_000_000)
        )
    }

    private func providerMutation(
        for context: AgentPolicyMutationExecutionContext,
        callID: ToolCallID? = nil
    ) throws -> (descriptor: ToolDescriptor, invocation: ToolInvocation) {
        let descriptor = WriteFileTool.descriptor
        let arguments = JSONValue.object([
            "contents": .string("provider private contents"),
            "path": .string("Sources/Provider.swift"),
        ])
        return (
            descriptor,
            ToolInvocation(
                callID: callID ?? context.callID,
                providerCallID: "provider-call-stays-private",
                modelAttemptID: context.operationAttemptID,
                tool: descriptor.identity,
                arguments: arguments,
                canonicalArgumentDigest:
                    try descriptor.canonicalArgumentDigest(for: arguments),
                idempotencyKey: context.idempotencyKey,
                effectClass: descriptor.effectClass,
                locality: .onDevice
            )
        )
    }

    private func workspace(_ name: String) -> SandboxWorkspace {
        SandboxWorkspace(rootURL: URL(
            fileURLWithPath: "/tmp/novaforge-policy-coordinator/\(name)",
            isDirectory: true
        ))
    }

    private func deterministicUUID(_ seed: Int) -> UUID {
        let suffix = String(format: "%012x", seed)
        return UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-\(suffix)")!
    }
}

private actor CoordinatorTestApprovalPrompt: ApprovalDecisionPrompting {
    func requestDecision(
        for context: DurableApprovalPromptContext
    ) async throws -> ApprovalDecision {
        .rejected
    }
}

private enum CoordinatorSecrets {
    static let summary = "TOP-SECRET-SUMMARY"
    static let commandOutput = "TOKEN=super-secret-command-output"
    static let path = "Secrets/private-token.txt"
}

private enum CoordinatorMutationCallTag: Int, CaseIterable, Sendable {
    case agentV2
    case v1Fallback
    case editorCanonical
    case editorPolicy
    case filesCanonical
    case filesPolicy
    case terminal
    case artifact
    case control
    case projectOSCanonical
    case projectOSPolicy
    case trustedSystemCanonical
    case trustedSystemPolicy
}

private struct CoordinatorRecordedMutation: Sendable {
    let tag: CoordinatorMutationCallTag
    let origin: MutationOrigin
    let scope: AgentPolicyMutationScope
    let callID: ToolCallID
    let operationAttemptID: AttemptID
    let idempotencyKey: String
}

private actor CoordinatorRecordingMutationSystem:
    AgentPolicyMutationSystemServing
{
    nonisolated let workspaceBinding: AgentPolicyWorkspaceBinding
    private let forcedResultOrigin: MutationOrigin?
    private var records: [CoordinatorRecordedMutation] = []

    init(
        workspaceBinding: AgentPolicyWorkspaceBinding,
        forcedResultOrigin: MutationOrigin? = nil
    ) {
        self.workspaceBinding = workspaceBinding
        self.forcedResultOrigin = forcedResultOrigin
    }

    func recordsSnapshot() -> [CoordinatorRecordedMutation] { records }

    func performAgentV2(
        scope: AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(
            .agentV2,
            origin: .agentV2,
            scope: scope,
            callID: invocation.callID,
            attemptID: invocation.modelAttemptID,
            idempotencyKey: invocation.idempotencyKey
        )
    }

    func performV1Fallback(
        scope: AgentPolicyMutationScope,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(
            .v1Fallback,
            origin: .v1Fallback,
            scope: scope,
            callID: invocation.callID,
            attemptID: invocation.modelAttemptID,
            idempotencyKey: invocation.idempotencyKey
        )
    }

    func performEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(.editorCanonical, origin: .editor, context: context)
    }

    func performEditor(
        context: AgentPolicyLocalMutationContext,
        operation: EditorPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(.editorPolicy, origin: .editor, context: context)
    }

    func performFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(.filesCanonical, origin: .files, context: context)
    }

    func performFiles(
        context: AgentPolicyLocalMutationContext,
        operation: FilesPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(.filesPolicy, origin: .files, context: context)
    }

    func performTerminal(
        context: AgentPolicyLocalMutationContext,
        operation: TerminalCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(.terminal, origin: .terminal, context: context)
    }

    func performArtifact(
        context: AgentPolicyLocalMutationContext,
        operation: ArtifactCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(.artifact, origin: .artifact, context: context)
    }

    func performControl(
        context: AgentPolicyLocalMutationContext,
        operation: ControlPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(.control, origin: .control, context: context)
    }

    func performProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(
            .projectOSCanonical,
            origin: .projectOS,
            context: context
        )
    }

    func performProjectOS(
        context: AgentPolicyLocalMutationContext,
        operation: ProjectOSPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(.projectOSPolicy, origin: .projectOS, context: context)
    }

    func performTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemCanonicalMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(
            .trustedSystemCanonical,
            origin: .trustedSystem,
            context: context
        )
    }

    func performTrustedSystem(
        context: AgentPolicyLocalMutationContext,
        operation: TrustedSystemPolicyMutationOperation
    ) async throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(
            .trustedSystemPolicy,
            origin: .trustedSystem,
            context: context
        )
    }

    private func record(
        _ tag: CoordinatorMutationCallTag,
        origin: MutationOrigin,
        context: AgentPolicyLocalMutationContext
    ) throws -> AgentPolicyCoordinatorUnclassifiedResult {
        try record(
            tag,
            origin: origin,
            scope: context.scope,
            callID: context.callID,
            attemptID: context.operationAttemptID,
            idempotencyKey: context.idempotencyKey
        )
    }

    private func record(
        _ tag: CoordinatorMutationCallTag,
        origin: MutationOrigin,
        scope: AgentPolicyMutationScope,
        callID: ToolCallID,
        attemptID: AttemptID,
        idempotencyKey: String
    ) throws -> AgentPolicyCoordinatorUnclassifiedResult {
        records.append(CoordinatorRecordedMutation(
            tag: tag,
            origin: origin,
            scope: scope,
            callID: callID,
            operationAttemptID: attemptID,
            idempotencyKey: idempotencyKey
        ))
        return try Self.unclassifiedResult(
            origin: forcedResultOrigin ?? origin
        )
    }

    nonisolated private static func unclassifiedResult(
        origin: MutationOrigin
    ) throws -> AgentPolicyCoordinatorUnclassifiedResult {
        let digest = try SHA256Digest(
            "sha256:" + String(repeating: "a", count: 64)
        )
        let target = try NormalizedToolTarget(
            path: CoordinatorSecrets.path,
            access: .write
        )
        let output = try MutationEffectOutput(
            kind: .runCommand,
            summary: CoordinatorSecrets.summary,
            targets: [target],
            text: CoordinatorSecrets.commandOutput,
            commandExitCode: 0
        )
        let evidence = try MutationEffectEvidenceFact(
            kind: .changedPath,
            targets: [target],
            digest: digest
        )
        return AgentPolicyCoordinatorUnclassifiedResult(
            origin: origin,
            effectKeySHA256: digest,
            applicationSHA256: digest,
            evidenceSHA256: digest,
            finalRecordSHA256: digest,
            receiptSHA256: digest,
            unclassifiedOutput: output,
            unclassifiedEvidence: [evidence]
        )
    }
}

private final class CoordinatorSystemFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedPrompt: CoordinatorTestApprovalPrompt
    private let forcedResultOrigin: MutationOrigin?
    private var systems: [CoordinatorRecordingMutationSystem] = []
    private var configurations: [RiskPolicyConfiguration] = []
    private var promptMatches: [Bool] = []

    init(
        expectedPrompt: CoordinatorTestApprovalPrompt,
        forcedResultOrigin: MutationOrigin? = nil
    ) {
        self.expectedPrompt = expectedPrompt
        self.forcedResultOrigin = forcedResultOrigin
    }

    func make(
        configuration: RiskPolicyConfiguration,
        binding: AgentPolicyWorkspaceBinding,
        approvalPrompt: any ApprovalDecisionPrompting
    ) -> any AgentPolicyMutationSystemServing {
        let system = CoordinatorRecordingMutationSystem(
            workspaceBinding: binding,
            forcedResultOrigin: forcedResultOrigin
        )
        let promptWasExpected = (approvalPrompt as? CoordinatorTestApprovalPrompt)
            .map { $0 === expectedPrompt } ?? false
        lock.lock()
        systems.append(system)
        configurations.append(configuration)
        promptMatches.append(promptWasExpected)
        lock.unlock()
        return system
    }

    var constructionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return systems.count
    }

    var everyPromptWasExpected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !promptMatches.isEmpty && promptMatches.allSatisfy { $0 }
    }

    func systemsSnapshot() -> [CoordinatorRecordingMutationSystem] {
        lock.lock()
        defer { lock.unlock() }
        return systems
    }

    func configurationsSnapshot() -> [RiskPolicyConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurations
    }
}
