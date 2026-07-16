import AgentDomain
import AgentPolicy
import AgentTools
import Foundation
import XCTest
@testable import NovaForge

final class AgentPolicyMutationServiceTests: XCTestCase {
    func testFacadeBindsEveryEntryPointToItsExactOriginAndOperationFamily()
        async throws
    {
        let authority = try makeAuthority()
        let pipeline = RecordingAgentPolicyMutationPipeline(
            policyRevisionAuthority: authority,
            failure: .requestRejected
        )
        let scope = try makeScope()
        let service = try AgentPolicyMutationService(
            policyRevisionAuthority: authority,
            workspaceBinding: scope.workspaceBinding,
            pipeline: pipeline
        )
        let context = AgentPolicyLocalMutationContext(
            scope: scope,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "surface-operation-1"
        )
        let provider = try makeProviderMutation()

        await expect(.requestRejected) {
            try await service.performAgentV2(
                scope: scope,
                descriptor: provider.descriptor,
                invocation: provider.invocation
            )
        }
        await expect(.requestRejected) {
            try await service.performV1Fallback(
                scope: scope,
                descriptor: provider.descriptor,
                invocation: provider.invocation
            )
        }
        await expect(.requestRejected) {
            try await service.performEditor(
                context: context,
                operation: .writeFile(.init(
                    path: "Sources/App.swift",
                    contents: "editor"
                ))
            )
        }
        await expect(.requestRejected) {
            try await service.performEditor(
                context: context,
                operation: .createFile(.init(path: "Notes/editor.md"))
            )
        }
        await expect(.requestRejected) {
            try await service.performFiles(
                context: context,
                operation: .movePath(.init(
                    from: "Notes/a.md",
                    to: "Notes/b.md"
                ))
            )
        }
        await expect(.requestRejected) {
            try await service.performFiles(
                context: context,
                operation: .touchFile(.init(path: "Notes/touched.md"))
            )
        }
        await expect(.requestRejected) {
            try await service.performTerminal(
                context: context,
                operation: .runCommand(.init(command: "mkdir Notes"))
            )
        }
        await expect(.requestRejected) {
            try await service.performArtifact(
                context: context,
                operation: .appendFile(.init(
                    path: "Artifacts/result.md",
                    contents: "artifact"
                ))
            )
        }
        await expect(.requestRejected) {
            try await service.performControl(
                context: context,
                operation: .resetWorkspace(.init())
            )
        }
        await expect(.requestRejected) {
            try await service.performProjectOS(
                context: context,
                operation: .replaceText(.init(
                    path: "Project/plan.md",
                    old: "old",
                    new: "new"
                ))
            )
        }
        await expect(.requestRejected) {
            try await service.performProjectOS(
                context: context,
                operation: .seedWorkspace(.init(entries: [
                    .init(path: "Project/seed.md", contents: "seed"),
                ]))
            )
        }
        await expect(.requestRejected) {
            try await service.performTrustedSystem(
                context: context,
                operation: .makeDirectory(.init(path: "System"))
            )
        }
        await expect(.requestRejected) {
            try await service.performTrustedSystem(
                context: context,
                operation: .resetWorkspace(.init())
            )
        }

        let records = await pipeline.records()
        XCTAssertEqual(
            records.map(\.tag),
            [
                .agentV2,
                .v1Fallback,
                .editorCanonical,
                .editorPolicy,
                .filesCanonical,
                .filesPolicy,
                .terminal,
                .artifact,
                .control,
                .projectOSCanonical,
                .projectOSPolicy,
                .trustedSystemCanonical,
                .trustedSystemPolicy,
            ]
        )
        XCTAssertEqual(
            records.map(\.origin),
            [
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
        )
        XCTAssertEqual(
            records.map(\.family),
            [
                .providerCanonical,
                .providerCanonical,
                .surfaceCanonical,
                .policyOnly,
                .surfaceCanonical,
                .policyOnly,
                .surfaceCanonical,
                .surfaceCanonical,
                .policyOnly,
                .surfaceCanonical,
                .policyOnly,
                .surfaceCanonical,
                .policyOnly,
            ]
        )
    }

    func testAgentV2FailureNeverFallsBackToV1() async throws {
        let authority = try makeAuthority()
        let pipeline = RecordingAgentPolicyMutationPipeline(
            policyRevisionAuthority: authority,
            failure: .requestRejected
        )
        let scope = try makeScope()
        let service = try AgentPolicyMutationService(
            policyRevisionAuthority: authority,
            workspaceBinding: scope.workspaceBinding,
            pipeline: pipeline
        )
        let provider = try makeProviderMutation()

        await expect(.requestRejected) {
            try await service.performAgentV2(
                scope: scope,
                descriptor: provider.descriptor,
                invocation: provider.invocation
            )
        }

        let records = await pipeline.records()
        XCTAssertEqual(records.map(\.tag), [.agentV2])
        XCTAssertFalse(records.contains { $0.tag == .v1Fallback })
    }

    func testFacadeRequiresTheExactSharedPolicyAuthorityInstance() throws {
        let expected = try makeAuthority()
        let foreign = try makeAuthority()
        let mismatched = RecordingAgentPolicyMutationPipeline(
            policyRevisionAuthority: foreign,
            failure: .requestRejected
        )
        let binding = try makeScope().workspaceBinding

        XCTAssertThrowsError(
            try AgentPolicyMutationService(
                policyRevisionAuthority: expected,
                workspaceBinding: binding,
                pipeline: mismatched
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentPolicyMutationServiceError,
                .invalidComposition
            )
        }

        let shared = RecordingAgentPolicyMutationPipeline(
            policyRevisionAuthority: expected,
            failure: .requestRejected
        )
        let service = try AgentPolicyMutationService(
            policyRevisionAuthority: expected,
            workspaceBinding: binding,
            pipeline: shared
        )
        XCTAssertTrue(service.isBound(to: expected))
        XCTAssertEqual(
            service.policyRevisionAuthorityIdentity,
            ObjectIdentifier(expected)
        )
        XCTAssertNotEqual(
            service.policyRevisionAuthorityIdentity,
            ObjectIdentifier(foreign)
        )
    }

    func testForeignWorkspaceScopeIsRejectedBeforePipelineDispatch()
        async throws
    {
        let authority = try makeAuthority()
        let expectedScope = try makeScope(rootName: "bound-root")
        let foreignScope = try makeScope(rootName: "foreign-root")
        let pipeline = RecordingAgentPolicyMutationPipeline(
            policyRevisionAuthority: authority,
            failure: .effectFailed
        )
        let service = try AgentPolicyMutationService(
            policyRevisionAuthority: authority,
            workspaceBinding: expectedScope.workspaceBinding,
            pipeline: pipeline
        )
        let provider = try makeProviderMutation()

        await expect(.requestRejected) {
            try await service.performAgentV2(
                scope: foreignScope,
                descriptor: provider.descriptor,
                invocation: provider.invocation
            )
        }

        let records = await pipeline.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testWorkspaceIDCanOnlyComeFromFrozenWorkspaceIdentity() throws {
        let first = try AgentPolicyWorkspaceBinding(workspace: SandboxWorkspace(
            rootURL: URL(fileURLWithPath: "/tmp/novaforge-policy-root-a")
        ))
        let second = try AgentPolicyWorkspaceBinding(workspace: SandboxWorkspace(
            rootURL: URL(fileURLWithPath: "/tmp/novaforge-policy-root-b")
        ))

        XCTAssertEqual(
            first.workspaceID.rawValue,
            first.resourceIdentity.persistentID
        )
        XCTAssertEqual(
            second.workspaceID.rawValue,
            second.resourceIdentity.persistentID
        )
        XCTAssertNotEqual(first.workspaceID, second.workspaceID)
        XCTAssertNotEqual(first.resourceIdentity, second.resourceIdentity)
    }

    func testRunContextCannotClaimAWorkspaceDifferentFromItsBinding() throws {
        let expected = try AgentPolicyWorkspaceBinding(
            workspace: SandboxWorkspace(rootURL: URL(
                fileURLWithPath: "/tmp/novaforge-policy-context-a"
            ))
        )
        let foreign = try AgentPolicyWorkspaceBinding(
            workspace: SandboxWorkspace(rootURL: URL(
                fileURLWithPath: "/tmp/novaforge-policy-context-b"
            ))
        )

        XCTAssertThrowsError(try AgentPolicyMutationScope(
            runContext: makeRunContext(workspaceID: foreign.workspaceID),
            workspaceBinding: expected,
            sessionID: "cross-workspace-context",
            backend: .onDevice
        )) { error in
            XCTAssertEqual(
                error as? AgentPolicyMutationServiceError,
                .requestRejected
            )
        }
    }

    private func makeAuthority() throws -> PolicyRevisionAuthority {
        try PolicyRevisionAuthority(configuration: RiskPolicyConfiguration())
    }

    private func makeScope(
        rootName: String = "service"
    ) throws -> AgentPolicyMutationScope {
        let binding = try AgentPolicyWorkspaceBinding(
            workspace: SandboxWorkspace(
                rootURL: URL(
                    fileURLWithPath: "/tmp/novaforge-policy-\(rootName)"
                )
            )
        )
        return try AgentPolicyMutationScope(
            runContext: makeRunContext(workspaceID: binding.workspaceID),
            workspaceBinding: binding,
            sessionID: "mutation-service-tests",
            backend: .onDevice
        )
    }

    private func makeRunContext(workspaceID: WorkspaceID) -> AgentRunContext {
        let runID = RunID()
        return AgentRunContext(
            lineage: .root(runID),
            conversationID: ConversationID(),
            projectID: ProjectID(),
            workspaceID: workspaceID,
            executionNodeID: ExecutionNodeID(),
            engineVersion: .agentHarnessV1,
            acceptedAt: AgentInstant(rawValue: 1),
            features: AgentFeatureSet([]),
            cancellation: CancellationLineage(
                scopeID: CancellationScopeID()
            ),
            initialBudget: AgentBudget(limits: .standard)
        )
    }

    private func makeProviderMutation() throws -> (
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) {
        let descriptor = WriteFileTool.descriptor
        let arguments: JSONValue = .object([
            "contents": .string("provider"),
            "path": .string("Sources/Provider.swift"),
        ])
        return (
            descriptor,
            ToolInvocation(
                callID: ToolCallID(),
                modelAttemptID: AttemptID(),
                tool: descriptor.identity,
                arguments: arguments,
                canonicalArgumentDigest:
                    try descriptor.canonicalArgumentDigest(for: arguments),
                idempotencyKey: "provider-operation-1",
                effectClass: descriptor.effectClass,
                locality: .onDevice
            )
        )
    }

    private func expect(
        _ expected: AgentPolicyMutationServiceError,
        operation: () async throws -> AgentPolicyUnclassifiedMutationResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected mutation facade failure", file: file, line: line)
        } catch let error as AgentPolicyMutationServiceError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }
}

private enum RecordedMutationTag: Equatable, Sendable {
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

private struct RecordedBoundMutation: Equatable, Sendable {
    let tag: RecordedMutationTag
    let origin: MutationOrigin
    let family: AgentPolicyMutationOperationFamily

    init(_ request: AgentPolicyBoundMutationRequest) {
        switch request {
        case .agentV2: tag = .agentV2
        case .v1Fallback: tag = .v1Fallback
        case .editorCanonical: tag = .editorCanonical
        case .editorPolicy: tag = .editorPolicy
        case .filesCanonical: tag = .filesCanonical
        case .filesPolicy: tag = .filesPolicy
        case .terminal: tag = .terminal
        case .artifact: tag = .artifact
        case .control: tag = .control
        case .projectOSCanonical: tag = .projectOSCanonical
        case .projectOSPolicy: tag = .projectOSPolicy
        case .trustedSystemCanonical: tag = .trustedSystemCanonical
        case .trustedSystemPolicy: tag = .trustedSystemPolicy
        }
        origin = request.fixedOrigin
        family = request.operationFamily
    }
}

private actor RecordingAgentPolicyMutationPipeline:
    AgentPolicyMutationPipeline
{
    nonisolated let policyRevisionAuthority: PolicyRevisionAuthority
    private let failure: AgentPolicyMutationServiceError
    private var recorded: [RecordedBoundMutation] = []

    init(
        policyRevisionAuthority: PolicyRevisionAuthority,
        failure: AgentPolicyMutationServiceError
    ) {
        self.policyRevisionAuthority = policyRevisionAuthority
        self.failure = failure
    }

    func execute(
        _ request: AgentPolicyBoundMutationRequest
    ) async throws -> AgentPolicyUnclassifiedMutationResult {
        recorded.append(RecordedBoundMutation(request))
        throw failure
    }

    func records() -> [RecordedBoundMutation] { recorded }
}
