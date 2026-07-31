import AgentDomain
@testable import AgentPolicy
import AgentTools
import Foundation
import XCTest

final class MutationOriginAndOutputSecurityTests: XCTestCase {
    func testNamedOriginsCannotBeRelabeledAndBindDifferentDigests()
        async throws
    {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let (descriptor, invocation) = try AgentPolicyTestFixture.invocation(
            "write_file",
            arguments: .object([
                "path": .string("notes.txt"),
                "contents": .string("hello"),
            ])
        )
        let runID = RunID()
        let workspaceID = WorkspaceID()
        let v2 = try await RiskPolicyRequest.resolveAgentV2(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            descriptor: descriptor,
            invocation: invocation,
            using: resolver
        )
        let fallback = try await RiskPolicyRequest.resolveV1Fallback(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            descriptor: descriptor,
            invocation: invocation,
            using: resolver
        )

        XCTAssertEqual(v2.origin, .agentV2)
        XCTAssertEqual(fallback.origin, .v1Fallback)
        XCTAssertNotEqual(v2.requestSHA256, fallback.requestSHA256)
        XCTAssertNotEqual(
            try MutationEffectApprovalPreview.derive(
                origin: v2.origin,
                descriptor: descriptor,
                invocation: invocation
            ).previewSHA256,
            try MutationEffectApprovalPreview.derive(
                origin: fallback.origin,
                descriptor: descriptor,
                invocation: invocation
            ).previewSHA256
        )
    }

    func testNamedHumanAndSystemCanonicalResolversBindCatalogContracts()
        async throws
    {
        let backend = MutableResolutionBackend()
        await backend.configure(commandTargets: [
            try NormalizedToolTarget(
                path: "Terminal/remove.txt",
                access: .delete
            ),
        ])
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let runID = RunID()
        let workspaceID = WorkspaceID()

        let editor = try await RiskPolicyRequest.resolveEditor(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "editor-write",
            operation: .writeFile(.init(
                path: "Editor/note.txt",
                contents: "hello"
            )),
            using: resolver
        )
        let files = try await RiskPolicyRequest.resolveFiles(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "files-move",
            operation: .movePath(.init(
                from: "Files/old.txt",
                to: "Files/new.txt"
            )),
            using: resolver
        )
        let terminal = try await RiskPolicyRequest.resolveTerminal(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "terminal-command",
            operation: .runCommand(.init(command: "rm Terminal/remove.txt")),
            using: resolver
        )
        let artifact = try await RiskPolicyRequest.resolveArtifact(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "artifact-append",
            operation: .appendFile(.init(
                path: "Artifacts/report.md",
                contents: "result"
            )),
            using: resolver
        )
        let projectOS = try await RiskPolicyRequest.resolveProjectOS(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "project-replace",
            operation: .replaceText(.init(
                path: "Project/plan.md",
                old: "old",
                new: "new"
            )),
            using: resolver
        )
        let trusted = try await RiskPolicyRequest.resolveTrustedSystem(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "system-directory",
            operation: .makeDirectory(.init(path: "System/Generated")),
            using: resolver
        )

        let expected: [(RiskPolicyRequest, MutationOrigin, String)] = [
            (editor, .editor, "write_file"),
            (files, .files, "move_path"),
            (terminal, .terminal, "run_command"),
            (artifact, .artifact, "append_file"),
            (projectOS, .projectOS, "replace_text"),
            (trusted, .trustedSystem, "make_directory"),
        ]
        for (request, origin, toolName) in expected {
            XCTAssertEqual(request.origin, origin)
            XCTAssertEqual(request.descriptor.name, toolName)
            XCTAssertEqual(
                request.descriptor,
                try AgentPolicyTestFixture.descriptor(toolName)
            )
            XCTAssertEqual(request.invocation.tool, request.descriptor.identity)
        }
    }

    func testControlResetHasTruthfulOriginAndDistinctDigest() async throws {
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )
        let runID = RunID()
        let workspaceID = WorkspaceID()
        let callID = ToolCallID()
        let attemptID = AttemptID()
        let control = try await RiskPolicyRequest.resolveControl(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: callID,
            operationAttemptID: attemptID,
            idempotencyKey: "same-reset",
            operation: .resetWorkspace(.init()),
            using: resolver
        )
        let projectOS = try await RiskPolicyRequest.resolveProjectOS(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: callID,
            operationAttemptID: attemptID,
            idempotencyKey: "same-reset",
            operation: .resetWorkspace(.init()),
            using: resolver
        )

        XCTAssertEqual(control.origin, .control)
        XCTAssertEqual(control.descriptor.name, "reset_workspace")
        XCTAssertEqual(control.descriptor, projectOS.descriptor)
        XCTAssertNotEqual(control.requestSHA256, projectOS.requestSHA256)
        XCTAssertNotEqual(
            control.operationPreviewSHA256,
            projectOS.operationPreviewSHA256
        )
    }

    func testControlOriginPropagatesIntoClaimAndLifecycleBinding()
        async throws
    {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await RiskPolicyRequest.resolveControl(
            runID: RunID(),
            projectID: nil,
            workspaceID: WorkspaceID(),
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "control-lifecycle",
            operation: .resetWorkspace(.init()),
            using: resolver
        )
        let context = MutationEffectTestContext(
            backend: backend,
            resolver: resolver,
            policyRevisionAuthority: try PolicyRevisionAuthority(
                configuration: RiskPolicyConfiguration()
            ),
            request: request
        )
        let permit = try await context.claimedPermit()
        XCTAssertEqual(permit.origin, .control)
        XCTAssertEqual(permit.claim.origin, .control)
        let binding = try MutationEffectBinding.make(borrowing: permit)
        XCTAssertEqual(binding.origin, .control)
        let pending = try MutationEffectRecord.pending(
            binding: binding,
            checkpoint: MutationEffectCheckpointResult(
                beforeStateSHA256: try AgentPolicyTestFixture.digest("before"),
                rollbackOrReconciliationPlanSHA256:
                    try AgentPolicyTestFixture.digest("rollback")
            ),
            preparedAt: AgentInstant(rawValue: 30)
        )
        XCTAssertEqual(pending.binding.origin, .control)
    }

    func testOriginOperationContractFamiliesUseExplicitAllowlists() {
        let allowedCanonical: [
            (MutationOrigin, CanonicalProviderMutationOperation, String)
        ] = [
            (
                .editor,
                EditorCanonicalMutationOperation.writeFile(
                    .init(path: "a", contents: "")
                ).canonicalProviderOperation,
                "write_file"
            ),
            (
                .editor,
                EditorCanonicalMutationOperation.replaceText(
                    .init(path: "a", old: "x", new: "y")
                ).canonicalProviderOperation,
                "replace_text"
            ),
            (
                .files,
                FilesCanonicalMutationOperation.writeFile(
                    .init(path: "a", contents: "")
                ).canonicalProviderOperation,
                "write_file"
            ),
            (
                .files,
                FilesCanonicalMutationOperation.deletePath(
                    .init(path: "a")
                ).canonicalProviderOperation,
                "delete_path"
            ),
            (
                .files,
                FilesCanonicalMutationOperation.movePath(
                    .init(from: "a", to: "b")
                ).canonicalProviderOperation,
                "move_path"
            ),
            (
                .files,
                FilesCanonicalMutationOperation.copyPath(
                    .init(from: "a", to: "b")
                ).canonicalProviderOperation,
                "copy_path"
            ),
            (
                .files,
                FilesCanonicalMutationOperation.makeDirectory(
                    .init(path: "a")
                ).canonicalProviderOperation,
                "make_directory"
            ),
            (
                .terminal,
                TerminalCanonicalMutationOperation.runCommand(
                    .init(command: "touch a")
                ).canonicalProviderOperation,
                "run_command"
            ),
            (
                .artifact,
                ArtifactCanonicalMutationOperation.writeFile(
                    .init(path: "a", contents: "")
                ).canonicalProviderOperation,
                "write_file"
            ),
            (
                .artifact,
                ArtifactCanonicalMutationOperation.appendFile(
                    .init(path: "a", contents: "")
                ).canonicalProviderOperation,
                "append_file"
            ),
            (
                .projectOS,
                ProjectOSCanonicalMutationOperation.writeFile(
                    .init(path: "a", contents: "")
                ).canonicalProviderOperation,
                "write_file"
            ),
            (
                .projectOS,
                ProjectOSCanonicalMutationOperation.appendFile(
                    .init(path: "a", contents: "")
                ).canonicalProviderOperation,
                "append_file"
            ),
            (
                .projectOS,
                ProjectOSCanonicalMutationOperation.replaceText(
                    .init(path: "a", old: "x", new: "y")
                ).canonicalProviderOperation,
                "replace_text"
            ),
            (
                .trustedSystem,
                TrustedSystemCanonicalMutationOperation.runCommand(
                    .init(command: "touch a")
                ).canonicalProviderOperation,
                "run_command"
            ),
        ]
        for (origin, operation, toolName) in allowedCanonical {
            XCTAssertTrue(MutationOriginOperationPolicy.allows(
                origin: origin,
                operation: operation
            ))
            let descriptor = MutationEffectContractCatalog.canonicalDescriptor(
                for: operation
            )
            XCTAssertEqual(descriptor.name, toolName)
            XCTAssertEqual(
                MutationEffectContractCatalog.canonicalProviderDescriptor(
                    for: descriptor.identity
                ),
                descriptor
            )
            XCTAssertNil(
                MutationEffectContractCatalog.canonicalNonProviderDescriptor(
                    for: descriptor.identity
                )
            )
        }

        let allowedPolicy: [
            (MutationOrigin, NonProviderMutationOperation, String)
        ] = [
            (
                .editor,
                EditorPolicyMutationOperation.createFile(
                    .init(path: "a")
                ).nonProviderOperation,
                "create_file"
            ),
            (
                .files,
                FilesPolicyMutationOperation.createFile(
                    .init(path: "a")
                ).nonProviderOperation,
                "create_file"
            ),
            (
                .files,
                FilesPolicyMutationOperation.touchFile(
                    .init(path: "a")
                ).nonProviderOperation,
                "touch_file"
            ),
            (
                .control,
                ControlPolicyMutationOperation.resetWorkspace(
                    .init()
                ).nonProviderOperation,
                "reset_workspace"
            ),
            (
                .projectOS,
                ProjectOSPolicyMutationOperation.seedWorkspace(
                    .init(entries: [.init(path: "a", contents: "")])
                ).nonProviderOperation,
                "seed_workspace"
            ),
            (
                .trustedSystem,
                TrustedSystemPolicyMutationOperation.resetWorkspace(
                    .init()
                ).nonProviderOperation,
                "reset_workspace"
            ),
        ]
        for (origin, operation, toolName) in allowedPolicy {
            XCTAssertTrue(MutationOriginOperationPolicy.allows(
                origin: origin,
                operation: operation
            ))
            let descriptor = MutationEffectContractCatalog.canonicalDescriptor(
                for: operation
            )
            XCTAssertEqual(descriptor.name, toolName)
            XCTAssertEqual(
                MutationEffectContractCatalog.canonicalNonProviderDescriptor(
                    for: descriptor.identity
                ),
                descriptor
            )
            XCTAssertNil(
                MutationEffectContractCatalog.canonicalProviderDescriptor(
                    for: descriptor.identity
                )
            )
        }

        let forbiddenCanonical: [
            (MutationOrigin, CanonicalProviderMutationOperation)
        ] = [
            (.editor, .runCommand(.init(command: "touch a"))),
            (.files, .replaceText(.init(path: "a", old: "x", new: "y"))),
            (.terminal, .writeFile(.init(path: "a", contents: ""))),
            (.artifact, .deletePath(.init(path: "a"))),
            (.control, .writeFile(.init(path: "a", contents: ""))),
            (.projectOS, .deletePath(.init(path: "a"))),
        ]
        for (origin, operation) in forbiddenCanonical {
            XCTAssertFalse(MutationOriginOperationPolicy.allows(
                origin: origin,
                operation: operation
            ))
        }

        let forbiddenPolicy: [(MutationOrigin, NonProviderMutationOperation)] = [
            (.editor, .resetWorkspace(.init())),
            (.files, .seedWorkspace(.init(entries: [.init(path: "a", contents: "")]))),
            (.terminal, .touchFile(.init(path: "a"))),
            (.artifact, .createFile(.init(path: "a"))),
            (.control, .seedWorkspace(.init(entries: [.init(path: "a", contents: "")]))),
            (.projectOS, .createFile(.init(path: "a"))),
            (.agentV2, .resetWorkspace(.init())),
            (.v1Fallback, .seedWorkspace(.init(entries: [.init(path: "a", contents: "")]))),
        ]
        for (origin, operation) in forbiddenPolicy {
            XCTAssertFalse(MutationOriginOperationPolicy.allows(
                origin: origin,
                operation: operation
            ))
        }
    }

    func testTypedCanonicalResolverRejectsSchemaInvalidArgumentsBeforeResolution()
        async throws
    {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        do {
            _ = try await RiskPolicyRequest.resolveFiles(
                runID: RunID(),
                projectID: nil,
                workspaceID: WorkspaceID(),
                sessionID: nil,
                backend: .onDevice,
                callID: ToolCallID(),
                operationAttemptID: AttemptID(),
                idempotencyKey: "invalid-typed-path",
                operation: .writeFile(.init(path: "", contents: "data")),
                using: resolver
            )
            XCTFail("typed operation arguments must still satisfy the schema")
        } catch let error as RiskPolicyRequestError {
            XCTAssertEqual(error, .invalidArguments)
        }
        let resolutionCount = await backend.resolutionCount
        XCTAssertEqual(resolutionCount, 0)
    }

    func testAgentEntryPointRejectsPolicyOnlyOperation() async throws {
        let operation = NonProviderMutationOperation.createFile(
            CreateFileMutationArguments(path: "notes.txt")
        )
        let descriptor = MutationEffectContractCatalog.canonicalDescriptor(
            for: operation
        )
        let arguments = MutationEffectContractCatalog.arguments(for: operation)
        let invocation = ToolInvocation(
            callID: ToolCallID(),
            modelAttemptID: AttemptID(),
            tool: descriptor.identity,
            arguments: arguments,
            canonicalArgumentDigest: try descriptor.canonicalArgumentDigest(
                for: arguments
            ),
            idempotencyKey: "unsupported-agent-operation",
            effectClass: descriptor.effectClass,
            locality: .onDevice
        )
        let resolver = WorkspaceTargetResolverAuthority(
            trustedBackend: MutableResolutionBackend()
        )

        do {
            _ = try await RiskPolicyRequest.resolveAgentV2(
                runID: RunID(),
                projectID: nil,
                workspaceID: WorkspaceID(),
                sessionID: nil,
                backend: .onDevice,
                descriptor: descriptor,
                invocation: invocation,
                using: resolver
            )
            XCTFail("agent origin must not invoke policy-only contracts")
        } catch let error as RiskPolicyRequestError {
            XCTAssertEqual(error, .originOperationMismatch)
        }
    }

    func testCreateTouchResetAndSeedResolveThroughSealedCatalog()
        async throws
    {
        let backend = MutableResolutionBackend()
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let workspaceID = WorkspaceID()
        let runID = RunID()
        let common = (
            callID: ToolCallID(),
            attemptID: AttemptID()
        )
        let create = try await RiskPolicyRequest.resolveEditor(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: common.callID,
            operationAttemptID: common.attemptID,
            idempotencyKey: "editor-create",
            operation: .createFile(.init(path: "Drafts/new.txt")),
            using: resolver
        )
        let touch = try await RiskPolicyRequest.resolveFiles(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "files-touch",
            operation: .touchFile(.init(path: "Drafts/existing.txt")),
            using: resolver
        )
        let reset = try await RiskPolicyRequest.resolveProjectOS(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "project-reset",
            operation: .resetWorkspace(.init()),
            using: resolver
        )
        let seed = try await RiskPolicyRequest.resolveTrustedSystem(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "system-seed",
            operation: .seedWorkspace(.init(entries: [
                .init(path: "README.md", contents: "hello"),
                .init(path: "Sources/App.swift", contents: "print(1)"),
            ])),
            using: resolver
        )

        XCTAssertEqual(create.origin, .editor)
        XCTAssertEqual(create.invocation.tool.name, "create_file")
        XCTAssertEqual(create.logicalTargets.map(\.path), ["Drafts/new.txt"])
        XCTAssertEqual(touch.origin, .files)
        XCTAssertEqual(touch.invocation.tool.name, "touch_file")
        XCTAssertEqual(reset.origin, .projectOS)
        XCTAssertEqual(reset.invocation.tool.name, "reset_workspace")
        XCTAssertEqual(seed.origin, .trustedSystem)
        XCTAssertEqual(seed.invocation.tool.name, "seed_workspace")
        XCTAssertEqual(
            seed.logicalTargets.map(\.path),
            ["README.md", "Sources/App.swift"]
        )
        XCTAssertEqual(seed.targetAttestation.preconditions.count, 2)
    }

    func testSeedPolicyScopesAndRevalidatesEveryEntry() async throws {
        let backend = MutableResolutionBackend()
        await backend.configure(resolvedPathOverrides: [
            "Allowed/a.txt": "Resolved/a.txt",
            "Denied/b.txt": "Resolved/b.txt",
        ])
        let resolver = WorkspaceTargetResolverAuthority(trustedBackend: backend)
        let request = try await RiskPolicyRequest.resolveTrustedSystem(
            runID: RunID(),
            projectID: nil,
            workspaceID: WorkspaceID(),
            sessionID: nil,
            backend: .onDevice,
            callID: ToolCallID(),
            operationAttemptID: AttemptID(),
            idempotencyKey: "seed-scope",
            operation: .seedWorkspace(.init(entries: [
                .init(path: "Allowed/a.txt", contents: "a"),
                .init(path: "Denied/b.txt", contents: "b"),
            ])),
            using: resolver
        )
        XCTAssertEqual(
            request.resolvedTargets.map(\.path),
            ["Resolved/a.txt", "Resolved/b.txt"]
        )
        XCTAssertTrue(request.targetAttestation.preconditions.allSatisfy {
            $0.resolution.traversedSymlink
        })

        let configuration = try RiskPolicyConfiguration(
            user: UserPolicyRestrictions(
                allowedTargetPrefixes: ["Resolved/a.txt"]
            )
        )
        let evaluator = try LayeredRiskPolicyEvaluator(
            configuration: configuration,
            clock: SequencePolicyClock([10]),
            resolver: resolver
        )
        let evaluation = await evaluator.evaluate(request)
        guard case let .deny(reasons) = evaluation.decision else {
            return XCTFail("one out-of-scope seed entry must deny the request")
        }
        XCTAssertTrue(reasons.contains(.targetOutOfScope("Resolved/b.txt")))

        await backend.configure(resolvedPathOverrides: [
            "Allowed/a.txt": "Resolved/a.txt",
            "Denied/b.txt": "Changed/b.txt",
        ])
        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.revalidate(request.targetAttestation)
        }
    }

    func testOriginTamperAndMissingSecurityFieldsFailClosed() async throws {
        let context = try await MutationEffectTestContext.make()
        let permit = try await context.claimedPermit()
        let claim = permit.claim
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(claim)
            ) as? [String: Any]
        )
        object["origin"] = MutationOrigin.files.rawValue
        XCTAssertThrowsError(try JSONDecoder().decode(
            ToolEffectClaimRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))

        let pending = try await context.pendingRecord()
        var pendingObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(pending)
            ) as? [String: Any]
        )
        var binding = try XCTUnwrap(
            pendingObject["binding"] as? [String: Any]
        )
        binding.removeValue(forKey: "origin")
        pendingObject["binding"] = binding
        XCTAssertThrowsError(try JSONDecoder().decode(
            MutationEffectRecord.self,
            from: JSONSerialization.data(withJSONObject: pendingObject)
        ))
    }

    func testBoundedOutputAndReceiptRejectTampering() throws {
        let unclassified = try MutationEffectOutput(
            kind: .writeFile,
            summary: "token=top-secret"
        )
        XCTAssertEqual(
            MutationEffectOutput.presentationClassification,
            .unclassified
        )
        XCTAssertTrue(unclassified.summary.contains("top-secret"))

        let raw = String(repeating: "x", count:
            MutationEffectOutput.maximumTextUTF8Bytes + 2_000)
        let output = try MutationEffectOutput(
            kind: .runCommand,
            summary: "done\nsecret",
            text: raw,
            commandExitCode: 0
        )
        XCTAssertEqual(
            output.text?.utf8.count,
            MutationEffectOutput.maximumTextUTF8Bytes
        )
        XCTAssertTrue(output.textWasTruncated)
        XCTAssertEqual(output.originalTextUTF8ByteCount, raw.utf8.count)
        XCTAssertFalse(output.summary.contains("\n"))

        let tooManyTargets = try (0...MutationEffectOutput.maximumTargets).map {
            try NormalizedToolTarget(path: "file-\($0)", access: .write)
        }
        XCTAssertThrowsError(try MutationEffectOutput(
            kind: .writeFile,
            summary: "done",
            targets: tooManyTargets
        ))
        let oversizedTargets = try (0..<20).map {
            try NormalizedToolTarget(
                path: String(repeating: "p", count: 4_000) + "-\($0)",
                access: .write
            )
        }
        XCTAssertThrowsError(try MutationEffectOutput(
            kind: .writeFile,
            summary: "done",
            targets: oversizedTargets
        )) { error in
            XCTAssertEqual(
                error as? MutationEffectLifecycleError,
                .outputTooLarge
            )
        }

        let evidence = [try MutationEffectEvidenceFact(
            kind: .workspaceAfter,
            digest: AgentPolicyTestFixture.digest("workspace")
        )]
        let receipt = try MutationEffectExecutionReceipt.make(
            origin: .control,
            effectKeySHA256: AgentPolicyTestFixture.digest("effect"),
            applicationSHA256: AgentPolicyTestFixture.digest("application"),
            evidenceSHA256: AgentPolicyTestFixture.digest("evidence"),
            finalRecordSHA256: AgentPolicyTestFixture.digest("record"),
            output: output,
            evidence: evidence
        )
        let encoded = try JSONEncoder().encode(receipt)
        XCTAssertEqual(
            try JSONDecoder().decode(
                MutationEffectExecutionReceipt.self,
                from: encoded
            ),
            receipt
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["origin"] = MutationOrigin.editor.rawValue
        XCTAssertThrowsError(try JSONDecoder().decode(
            MutationEffectExecutionReceipt.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "output")
        XCTAssertThrowsError(try JSONDecoder().decode(
            MutationEffectExecutionReceipt.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("expected expression to throw", file: file, line: line)
        } catch {}
    }
}
