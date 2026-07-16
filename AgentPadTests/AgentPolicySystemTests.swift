import AgentPolicy
import Foundation
import XCTest
@testable import NovaForge

final class AgentPolicySystemTests: XCTestCase {
    func testExecutionAndRecoveryRequireTheIdenticalGatewayAuthority() {
        let shared = NSObject()
        XCTAssertNoThrow(try AgentPolicyGatewayComposition.validate(
            executionIdentity: ObjectIdentifier(shared),
            recoveryIdentity: ObjectIdentifier(shared)
        ))

        let foreign = NSObject()
        do {
            try AgentPolicyGatewayComposition.validate(
                executionIdentity: ObjectIdentifier(shared),
                recoveryIdentity: ObjectIdentifier(foreign)
            )
            XCTFail("Expected split execution/recovery gateways to fail")
        } catch let error as AgentPolicySystemError {
            XCTAssertEqual(error, .invalidComposition)
        } catch {
            XCTFail("Unexpected error type")
        }
    }

    func testWorkspaceCompositionAcceptsOnlyOneFrozenIdentityAndPreparedDirectory()
        throws
    {
        let binding = try makeBinding("shared")
        let protectedDirectory = URL(
            fileURLWithPath: "/tmp/AgentPolicy/v1/checkpoints/../checkpoints",
            isDirectory: true
        )

        XCTAssertNoThrow(try AgentPolicyWorkspaceComposition.validate(
            binding: binding,
            targetIdentity: binding.resourceIdentity,
            checkpointIdentity: binding.resourceIdentity,
            checkpointDirectory: protectedDirectory,
            applierIdentity: binding.resourceIdentity,
            protectedCheckpointDirectory: URL(
                fileURLWithPath: "/tmp/AgentPolicy/v1/checkpoints",
                isDirectory: true
            )
        ))
    }

    func testForeignTargetBackendIdentityFailsClosed() throws {
        let expected = try makeBinding("expected-target")
        let foreign = try makeBinding("foreign-target")

        assertInvalidComposition {
            try validate(
                binding: expected,
                target: foreign.resourceIdentity,
                checkpoint: expected.resourceIdentity,
                applier: expected.resourceIdentity
            )
        }
    }

    func testForeignCheckpointIdentityFailsClosed() throws {
        let expected = try makeBinding("expected-checkpoint")
        let foreign = try makeBinding("foreign-checkpoint")

        assertInvalidComposition {
            try validate(
                binding: expected,
                target: expected.resourceIdentity,
                checkpoint: foreign.resourceIdentity,
                applier: expected.resourceIdentity
            )
        }
    }

    func testForeignEffectApplierIdentityFailsClosed() throws {
        let expected = try makeBinding("expected-applier")
        let foreign = try makeBinding("foreign-applier")

        assertInvalidComposition {
            try validate(
                binding: expected,
                target: expected.resourceIdentity,
                checkpoint: expected.resourceIdentity,
                applier: foreign.resourceIdentity
            )
        }
    }

    func testUncheckedCheckpointChildDirectoryFailsClosed() throws {
        let expected = try makeBinding("expected-directory")
        let prepared = URL(
            fileURLWithPath: "/tmp/AgentPolicy/v1/checkpoints",
            isDirectory: true
        )

        assertInvalidComposition {
            try AgentPolicyWorkspaceComposition.validate(
                binding: expected,
                targetIdentity: expected.resourceIdentity,
                checkpointIdentity: expected.resourceIdentity,
                checkpointDirectory: prepared.appendingPathComponent(
                    "unchecked-child",
                    isDirectory: true
                ),
                applierIdentity: expected.resourceIdentity,
                protectedCheckpointDirectory: prepared
            )
        }
    }

    func testWorkspaceBindingCannotBeRelabeledWithAnotherRootID() throws {
        let first = try makeBinding("binding-a")
        let second = try makeBinding("binding-b")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            first.workspaceID.rawValue,
            first.resourceIdentity.persistentID
        )
        XCTAssertEqual(
            second.workspaceID.rawValue,
            second.resourceIdentity.persistentID
        )
    }

    func testMissingSeedRootGetsStableIdentityWithoutBeingCreated() throws {
        let root = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(
            "novaforge-policy-missing-\(UUID().uuidString)",
            isDirectory: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let workspace = SandboxWorkspace(rootURL: root)
        let first = try AgentPolicyWorkspaceBinding(workspace: workspace)
        let second = try AgentPolicyWorkspaceBinding(workspace: workspace)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.workspaceID, second.workspaceID)
        XCTAssertEqual(
            first.workspaceID.rawValue,
            first.resourceIdentity.persistentID
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    private func validate(
        binding: AgentPolicyWorkspaceBinding,
        target: WorkspaceResourceIdentity,
        checkpoint: WorkspaceResourceIdentity,
        applier: WorkspaceResourceIdentity
    ) throws {
        let directory = URL(
            fileURLWithPath: "/tmp/AgentPolicy/v1/checkpoints",
            isDirectory: true
        )
        try AgentPolicyWorkspaceComposition.validate(
            binding: binding,
            targetIdentity: target,
            checkpointIdentity: checkpoint,
            checkpointDirectory: directory,
            applierIdentity: applier,
            protectedCheckpointDirectory: directory
        )
    }

    private func makeBinding(
        _ name: String
    ) throws -> AgentPolicyWorkspaceBinding {
        try AgentPolicyWorkspaceBinding(workspace: SandboxWorkspace(
            rootURL: URL(
                fileURLWithPath: "/tmp/novaforge-policy-system-\(name)",
                isDirectory: true
            )
        ))
    }

    private func assertInvalidComposition(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try operation()
            XCTFail("Expected composition rejection", file: file, line: line)
        } catch let error as AgentPolicySystemError {
            XCTAssertEqual(
                error,
                .invalidWorkspaceComposition,
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error type", file: file, line: line)
        }
    }
}
