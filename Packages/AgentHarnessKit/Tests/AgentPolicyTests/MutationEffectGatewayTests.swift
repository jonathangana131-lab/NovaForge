import AgentDomain
@testable import AgentPolicy
import AgentTools
import XCTest

final class MutationEffectGatewayTests: XCTestCase {
    func testSuccessDerivesExactTypedOperationAndDurablySettlesEvidence() async throws {
        let context = try await MutationEffectTestContext.make(
            arguments: .object([
                "path": .string("notes.txt"),
                "contents": .string("exact new contents"),
            ])
        )
        let store = InMemoryMutationEffectLifecycleStore()
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let effectKey = permit.effectKeySHA256

        let receipt = try await gateway.apply(permit)

        XCTAssertEqual(receipt.effectKeySHA256, effectKey)
        XCTAssertEqual(applier.operations.count, 1)
        guard case let .writeFile(arguments) = applier.operations[0].body else {
            return XCTFail("gateway must derive write_file's typed operation")
        }
        XCTAssertEqual(arguments.path, "notes.txt")
        XCTAssertEqual(arguments.contents, "exact new contents")
        XCTAssertTrue(
            applier.operations[0].humanReadableChanges
                .contains(where: { $0.contains("exact new contents") })
        )
        XCTAssertTrue(
            applier.operations[0].exactArgumentsJSON
                .contains("exact new contents")
        )
        let durableValue = await store.record(effectKeySHA256: effectKey)
        let durable = try XCTUnwrap(durableValue)
        XCTAssertEqual(durable.phase, .evidence)
        XCTAssertEqual(durable.recordSHA256, receipt.finalRecordSHA256)
    }

    func testDuplicateClaimNeverDispatchesEffectAgain() async throws {
        let context = try await MutationEffectTestContext.make()
        let store = InMemoryMutationEffectLifecycleStore()
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let first = try await context.claimedPermit()
        _ = try await gateway.apply(first)

        let duplicate = try await context.claimedPermit()
        do {
            _ = try await gateway.apply(duplicate)
            XCTFail("duplicate application must be rejected")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .duplicateApplication
            )
        }
        XCTAssertEqual(applier.operations.count, 1)
    }

    func testCheckpointFailureLeavesNoPendingRecordAndNeverDispatches() async throws {
        let context = try await MutationEffectTestContext.make()
        let store = InMemoryMutationEffectLifecycleStore()
        let applier = RecordingMutationApplier()
        let checkpointer = try RecordingMutationCheckpointer(
            shouldFail: true
        )
        let gateway = try makeGateway(
            context: context,
            store: store,
            checkpointer: checkpointer,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("checkpoint failure must stop before pending")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .checkpointFailed
            )
        }
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertNil(durable)
        XCTAssertTrue(applier.operations.isEmpty)
    }

    func testCrashAfterPendingCommitMarksTerminalReconciliationWithoutEffect() async throws {
        let context = try await MutationEffectTestContext.make()
        let fault = OneShotMutationStoreFault(.afterPendingCommit)
        let store = try InMemoryMutationEffectLifecycleStore(
            faultInjector: { try fault.inject($0) }
        )
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("post-pending fault must return no success")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .pendingCommitFailed
            )
        }
        XCTAssertTrue(applier.operations.isEmpty)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .needsReconciliation)
    }

    func testEffectThrowAfterPendingRequiresReconciliation() async throws {
        let context = try await MutationEffectTestContext.make()
        let store = InMemoryMutationEffectLifecycleStore()
        let applier = RecordingMutationApplier(shouldFail: true)
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("throwing effect must not return success")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .effectFailed
            )
        }
        XCTAssertEqual(applier.operations.count, 1)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .needsReconciliation)
    }

    func testFaultBeforeApplicationCommitRunsEffectOnceThenReconciles() async throws {
        let context = try await MutationEffectTestContext.make()
        let fault = OneShotMutationStoreFault(.beforeAppliedCommit)
        let store = try InMemoryMutationEffectLifecycleStore(
            faultInjector: { try fault.inject($0) }
        )
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("application commit failure cannot report success")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .durableSettlementFailed
            )
        }
        XCTAssertEqual(applier.operations.count, 1)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .needsReconciliation)
    }

    func testFaultAfterApplicationCommitIsReadResolvedWithoutReapply() async throws {
        let context = try await MutationEffectTestContext.make()
        let fault = OneShotMutationStoreFault(.afterAppliedCommit)
        let store = try InMemoryMutationEffectLifecycleStore(
            faultInjector: { try fault.inject($0) }
        )
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        _ = try await gateway.apply(permit)

        XCTAssertEqual(applier.operations.count, 1)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .evidence)
    }

    func testFaultBeforeEvidenceCommitRecoversWithoutDispatchingAgain() async throws {
        let context = try await MutationEffectTestContext.make()
        let fault = OneShotMutationStoreFault(.beforeEvidenceCommit)
        let store = try InMemoryMutationEffectLifecycleStore(
            faultInjector: { try fault.inject($0) }
        )
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("missing evidence commit cannot report success")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .durableSettlementFailed
            )
        }
        XCTAssertEqual(applier.operations.count, 1)
        let durableApplied = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durableApplied?.phase, .applied)

        guard case .evidenceSettled = try await gateway.recover(
            effectKeySHA256: key
        ) else { return XCTFail("recovery must settle persisted evidence") }
        XCTAssertEqual(applier.operations.count, 1)
        let durableEvidence = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durableEvidence?.phase, .evidence)
    }

    func testPendingRecoveryNeverDispatchesAndBecomesReconciliation() async throws {
        let context = try await MutationEffectTestContext.make()
        let pending = try await context.pendingRecord()
        let store = InMemoryMutationEffectLifecycleStore()
        _ = try await store.insertPendingIfAbsent(pending)
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )

        guard case .reconciliationRequired = try await gateway.recover(
            effectKeySHA256: pending.effectKeySHA256
        ) else { return XCTFail("ambiguous pending must not become executable") }
        XCTAssertTrue(applier.operations.isEmpty)
        let durable = await store.record(
            effectKeySHA256: pending.effectKeySHA256
        )
        XCTAssertEqual(durable?.phase, .needsReconciliation)
    }

    func testExpiredClaimStopsBeforePendingAndEffect() async throws {
        let context = try await MutationEffectTestContext.make()
        let store = InMemoryMutationEffectLifecycleStore()
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            clock: LockedMutationEffectClock([10_000]),
            applier: applier
        )
        let permit = try await context.claimedPermit(expiresAt: 10_000)
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("expired claim must fail")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .expired
            )
        }
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertNil(durable)
        XCTAssertTrue(applier.operations.isEmpty)
    }

    func testFaultBeforePendingLeavesNoRecordAndNeverDispatches() async throws {
        let context = try await MutationEffectTestContext.make()
        let fault = OneShotMutationStoreFault(.beforePendingCommit)
        let store = try InMemoryMutationEffectLifecycleStore(
            faultInjector: { try fault.inject($0) }
        )
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("pre-pending fault must fail")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .pendingCommitFailed
            )
        }
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertNil(durable)
        XCTAssertTrue(applier.operations.isEmpty)
    }

    func testFaultAfterEvidenceCommitReadsBackSuccessfulReceipt() async throws {
        let context = try await MutationEffectTestContext.make()
        let fault = OneShotMutationStoreFault(.afterEvidenceCommit)
        let store = try InMemoryMutationEffectLifecycleStore(
            faultInjector: { try fault.inject($0) }
        )
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        let receipt = try await gateway.apply(permit)

        XCTAssertEqual(receipt.effectKeySHA256, key)
        XCTAssertEqual(applier.operations.count, 1)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .evidence)
    }

    func testFaultBeforeReconciliationLeavesPendingForSafeRecovery()
        async throws
    {
        let context = try await MutationEffectTestContext.make()
        let fault = OneShotMutationStoreFault(.beforeReconciliationCommit)
        let store = try InMemoryMutationEffectLifecycleStore(
            faultInjector: { try fault.inject($0) }
        )
        let applier = RecordingMutationApplier(shouldFail: true)
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("effect failure must surface")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .effectFailed
            )
        }
        let durablePending = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durablePending?.phase, .pending)

        let recoveryGateway = try makeGateway(
            context: context,
            store: store,
            applier: RecordingMutationApplier()
        )
        guard case .reconciliationRequired = try await recoveryGateway
            .recover(effectKeySHA256: key)
        else { return XCTFail("pending recovery must reconcile") }
        let durableReconciliation = await store.record(
            effectKeySHA256: key
        )
        XCTAssertEqual(
            durableReconciliation?.phase,
            .needsReconciliation
        )
    }

    func testFaultAfterReconciliationCommitReadsBackTerminalState()
        async throws
    {
        let context = try await MutationEffectTestContext.make()
        let fault = OneShotMutationStoreFault(.afterReconciliationCommit)
        let store = try InMemoryMutationEffectLifecycleStore(
            faultInjector: { try fault.inject($0) }
        )
        let applier = RecordingMutationApplier(shouldFail: true)
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("effect failure must surface")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .effectFailed
            )
        }
        XCTAssertEqual(applier.operations.count, 1)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .needsReconciliation)
    }

    func testInvalidEffectEvidenceNeverCommitsAppliedState() async throws {
        let context = try await MutationEffectTestContext.make()
        let store = InMemoryMutationEffectLifecycleStore()
        let applier = MissingTargetEvidenceMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("unbound evidence must fail before applied CAS")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .invalidEffectEvidence
            )
        }
        XCTAssertEqual(applier.applicationCount, 1)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .needsReconciliation)
    }

    func testEveryMutationToolRequiresItsExactTypedEvidenceSchema()
        async throws
    {
        let cases: [(String, JSONValue)] = [
            ("write_file", .object([
                "path": .string("notes.txt"),
                "contents": .string("hello"),
            ])),
            ("append_file", .object([
                "path": .string("notes.txt"),
                "contents": .string("hello"),
            ])),
            ("replace_text", .object([
                "path": .string("notes.txt"),
                "old": .string("before"),
                "new": .string("after"),
            ])),
            ("delete_path", .object([
                "path": .string("notes.txt"),
            ])),
            ("move_path", .object([
                "from": .string("before.txt"),
                "to": .string("after.txt"),
            ])),
            ("copy_path", .object([
                "from": .string("before.txt"),
                "to": .string("after.txt"),
            ])),
            ("make_directory", .object([
                "path": .string("folder"),
            ])),
            ("run_command", .object([
                "command": .string("touch notes.txt"),
            ])),
        ]

        for (tool, arguments) in cases {
            let context = try await MutationEffectTestContext.make(
                tool: tool,
                arguments: arguments,
                idempotencyKey: "evidence-\(tool)"
            )
            let permit = try await context.claimedPermit()
            let operation = try MutationEffectOperation.derive(
                borrowing: permit
            )
            let result = try validResult(
                for: operation,
                targets: context.request.resolvedTargets
            )
            XCTAssertNoThrow(try MutationEffectGateway.validateEvidence(
                result,
                for: operation,
                resolvedTargets: context.request.resolvedTargets
            ), tool)

            let missing = try MutationEffectApplicationResult(
                resultSHA256: result.resultSHA256,
                output: result.output,
                evidence: Array(result.evidence.dropLast())
            )
            XCTAssertThrowsError(try MutationEffectGateway.validateEvidence(
                missing,
                for: operation,
                resolvedTargets: context.request.resolvedTargets
            ), tool)
        }
    }

    func testWrongAndExtraEvidenceKindsAreRejected() async throws {
        let context = try await MutationEffectTestContext.make()
        let permit = try await context.claimedPermit()
        let operation = try MutationEffectOperation.derive(
            borrowing: permit
        )
        let targets = context.request.resolvedTargets
        let workspace = try MutationEffectEvidenceFact(
            kind: .workspaceAfter,
            digest: AgentPolicyTestFixture.digest("workspace")
        )
        let wrong = try MutationEffectApplicationResult(
            resultSHA256: AgentPolicyTestFixture.digest("wrong"),
            output: mutationEffectTestOutput(targets: targets),
            evidence: [
                workspace,
                try MutationEffectEvidenceFact(
                    kind: .deletedPath,
                    targets: targets,
                    digest: AgentPolicyTestFixture.digest("deleted")
                ),
            ]
        )
        XCTAssertThrowsError(try MutationEffectGateway.validateEvidence(
            wrong,
            for: operation,
            resolvedTargets: targets
        ))

        var extraFacts = try validResult(
            for: operation,
            targets: targets
        ).evidence
        extraFacts.append(try MutationEffectEvidenceFact(
            kind: .commandTranscript,
            digest: AgentPolicyTestFixture.digest("extra")
        ))
        let extra = try MutationEffectApplicationResult(
            resultSHA256: AgentPolicyTestFixture.digest("extra-result"),
            output: mutationEffectTestOutput(targets: targets),
            evidence: extraFacts
        )
        XCTAssertThrowsError(try MutationEffectGateway.validateEvidence(
            extra,
            for: operation,
            resolvedTargets: targets
        ))
    }

    func testSingleTargetWriteRejectsMultiTargetChangedPathEvidence()
        async throws
    {
        let context = try await MutationEffectTestContext.make()
        let permit = try await context.claimedPermit()
        let operation = try MutationEffectOperation.derive(
            borrowing: permit
        )
        let authorizedTargets = context.request.resolvedTargets
        let smuggledTargets = authorizedTargets + [
            try NormalizedToolTarget(
                path: "smuggled.txt",
                access: .write
            ),
        ]
        let result = try MutationEffectApplicationResult(
            resultSHA256: AgentPolicyTestFixture.digest("smuggled-result"),
            output: mutationEffectTestOutput(targets: authorizedTargets),
            evidence: [
                try MutationEffectEvidenceFact(
                    kind: .workspaceAfter,
                    digest: AgentPolicyTestFixture.digest("workspace-after")
                ),
                try MutationEffectEvidenceFact(
                    kind: .changedPath,
                    targets: smuggledTargets,
                    digest: AgentPolicyTestFixture.digest("smuggled-change")
                ),
            ]
        )

        XCTAssertThrowsError(try MutationEffectGateway.validateEvidence(
            result,
            for: operation,
            resolvedTargets: authorizedTargets
        ))
    }

    func testApprovalPreviewEscapesInvisibleUnicodeAndDescriptionsRedact()
        async throws
    {
        let raw = "secret\u{202E}rtl\u{2066}isolate\u{200B}zero"
        let context = try await MutationEffectTestContext.make(
            arguments: .object([
                "path": .string("notes.txt"),
                "contents": .string(raw),
            ])
        )
        let permit = try await context.claimedPermit()
        let operation = try MutationEffectOperation.derive(
            borrowing: permit
        )
        let visible = operation.humanReadableChanges.joined(separator: " ")

        XCTAssertTrue(visible.contains("\\u{202E}"))
        XCTAssertTrue(visible.contains("\\u{2066}"))
        XCTAssertTrue(visible.contains("\\u{200B}"))
        XCTAssertFalse(visible.contains("\u{202E}"))
        XCTAssertFalse(operation.description.contains("secret"))
        XCTAssertFalse(operation.approvalPreview.description.contains("secret"))
        XCTAssertEqual(
            mutationEffectVisibleText("dir/\u{202E}name; echo\u{2066}x"),
            "dir/\\u{202E}name; echo\\u{2066}x"
        )
    }

    func testRecoveryWaitsBehindLiveApplyAndDoesNotReexecute()
        async throws
    {
        let context = try await MutationEffectTestContext.make()
        let store = InMemoryMutationEffectLifecycleStore()
        let release = DispatchSemaphore(value: 0)
        let applier = RecordingMutationApplier { _ in release.wait() }
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let keyPermit = try await context.claimedPermit()
        let key = keyPermit.effectKeySHA256
        let applyTask = Task {
            let permit = try await context.claimedPermit()
            return try await gateway.apply(permit)
        }
        defer {
            release.signal()
            applyTask.cancel()
        }
        try await waitUntil { applier.operations.count == 1 }

        let recoveryTask = Task {
            try await gateway.recover(effectKeySHA256: key)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        let whileLive = await store.record(effectKeySHA256: key)
        XCTAssertEqual(whileLive?.phase, .pending)

        release.signal()
        _ = try await applyTask.value
        guard case .alreadySettled = try await recoveryTask.value else {
            return XCTFail("recovery must observe the settled live apply")
        }
        XCTAssertEqual(applier.operations.count, 1)
    }

    func testTwoGatewaysSerializeDifferentEffectKeysInSameWorkspace()
        async throws
    {
        let workspaceID = WorkspaceID()
        let firstContext = try await MutationEffectTestContext.make(
            workspaceID: workspaceID,
            idempotencyKey: "serialized-first"
        )
        let secondContext = try await MutationEffectTestContext.make(
            workspaceID: workspaceID,
            idempotencyKey: "serialized-second"
        )
        let store = InMemoryMutationEffectLifecycleStore()
        let release = DispatchSemaphore(value: 0)
        let firstApplier = RecordingMutationApplier { _ in release.wait() }
        let secondApplier = RecordingMutationApplier()
        let firstGateway = try makeGateway(
            context: firstContext,
            store: store,
            applier: firstApplier
        )
        let secondGateway = try makeGateway(
            context: secondContext,
            store: store,
            applier: secondApplier
        )
        let firstKeyPermit = try await firstContext.claimedPermit()
        let secondKeyPermit = try await secondContext.claimedPermit()
        XCTAssertNotEqual(
            firstKeyPermit.effectKeySHA256,
            secondKeyPermit.effectKeySHA256
        )

        let firstTask = Task {
            let permit = try await firstContext.claimedPermit()
            return try await firstGateway.apply(permit)
        }
        defer {
            release.signal()
            firstTask.cancel()
        }
        try await waitUntil { firstApplier.operations.count == 1 }
        let secondTask = Task {
            let permit = try await secondContext.claimedPermit()
            return try await secondGateway.apply(permit)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(secondApplier.operations.isEmpty)

        release.signal()
        _ = try await firstTask.value
        _ = try await secondTask.value
        XCTAssertEqual(firstApplier.operations.count, 1)
        XCTAssertEqual(secondApplier.operations.count, 1)
    }

    func testTrueChildProcessLaneBlocksRecoveryAndDifferentKeyApply()
        async throws
    {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FileMutationEffectLifecycleStore(
            fileURL: directory.appendingPathComponent("mutation-ledger.json"),
            lockTimeoutMilliseconds: 75
        )
        let workspaceID = WorkspaceID()
        let pendingContext = try await MutationEffectTestContext.make(
            workspaceID: workspaceID,
            idempotencyKey: "child-pending"
        )
        let pending = try await pendingContext.pendingRecord()
        _ = try await store.insertPendingIfAbsent(pending)
        let newContext = try await MutationEffectTestContext.make(
            workspaceID: workspaceID,
            idempotencyKey: "child-new-effect"
        )
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: newContext,
            store: store,
            applier: applier
        )

        let seedLease = try await store.workspaceProcessArbiter.acquire(
            workspaceID: workspaceID
        )
        seedLease.release()
        let child = try launchChildHoldingLock(
            store.workspaceProcessArbiter.lockURL(workspaceID: workspaceID)
        )
        defer { stop(child.process) }
        let signal = child.output.fileHandleForReading.availableData
        XCTAssertEqual(String(data: signal, encoding: .utf8), "locked\n")

        do {
            _ = try await gateway.recover(
                effectKeySHA256: pending.effectKeySHA256
            )
            XCTFail("child process must exclude recovery")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .coordinationFailed
            )
        }
        let newPermit = try await newContext.claimedPermit()
        let newKey = newPermit.effectKeySHA256
        do {
            _ = try await gateway.apply(newPermit)
            XCTFail("child process must exclude another effect key")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .coordinationFailed
            )
        }
        XCTAssertTrue(applier.operations.isEmpty)
        let stillPending = try await store.record(
            effectKeySHA256: pending.effectKeySHA256
        )
        let absentNewEffect = try await store.record(
            effectKeySHA256: newKey
        )
        XCTAssertEqual(stillPending?.phase, .pending)
        XCTAssertNil(absentNewEffect)
    }

    func testExpiryAfterFinalResolverReconcilesWithoutDispatch()
        async throws
    {
        let context = try await MutationEffectTestContext.make()
        let store = InMemoryMutationEffectLifecycleStore()
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            clock: LockedMutationEffectClock([30, 31, 10_000, 10_001]),
            applier: applier
        )
        let permit = try await context.claimedPermit(expiresAt: 10_000)
        let key = permit.effectKeySHA256

        do {
            _ = try await gateway.apply(permit)
            XCTFail("expiry at final dispatch must fail")
        } catch {
            XCTAssertEqual(error as? MutationEffectGatewayError, .expired)
        }
        XCTAssertTrue(applier.operations.isEmpty)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .needsReconciliation)
    }

    func testPolicyChangeDuringFinalResolverReconcilesWithoutDispatch()
        async throws
    {
        let context = try await MutationEffectTestContext.make()
        let permit = try await context.claimedPermit()
        let key = permit.effectKeySHA256
        let trigger = await context.backend.resolutionCount + 2
        let changed = try RiskPolicyConfiguration(
            administrative: PolicyRestrictionSet(
                deniedTools: [context.request.invocation.tool]
            )
        )
        let revisionAuthority = context.policyRevisionAuthority
        await context.backend.setResolutionHook { count in
            if count == trigger {
                _ = try? revisionAuthority.replaceCurrentConfiguration(
                    changed
                )
            }
        }
        let store = InMemoryMutationEffectLifecycleStore()
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )

        do {
            _ = try await gateway.apply(permit)
            XCTFail("a final-resolution policy change must fail")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .policyChanged
            )
        }
        XCTAssertTrue(applier.operations.isEmpty)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .needsReconciliation)
    }

    func testCancellationAfterPendingReconcilesWithoutDispatch()
        async throws
    {
        let context = try await MutationEffectTestContext.make()
        let gate = BlockingAfterPendingMutationStoreFault()
        let store = try InMemoryMutationEffectLifecycleStore(
            faultInjector: { gate.inject($0) }
        )
        let applier = RecordingMutationApplier()
        let gateway = try makeGateway(
            context: context,
            store: store,
            applier: applier
        )
        let keyPermit = try await context.claimedPermit()
        let key = keyPermit.effectKeySHA256
        let task = Task {
            let permit = try await context.claimedPermit()
            return try await gateway.apply(permit)
        }
        defer {
            gate.release()
            task.cancel()
        }
        try await waitUntil { gate.hasEntered }
        task.cancel()
        gate.release()

        do {
            _ = try await task.value
            XCTFail("cancelled mutation must not dispatch")
        } catch {
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .cancelledAfterPending
            )
        }
        XCTAssertTrue(applier.operations.isEmpty)
        let durable = await store.record(effectKeySHA256: key)
        XCTAssertEqual(durable?.phase, .needsReconciliation)
    }

    func testUnknownDurableStoreWithoutProcessArbiterFailsInitialization()
        async throws
    {
        let context = try await MutationEffectTestContext.make()
        let store = UnarbitratedMutationStore()
        XCTAssertThrowsError(try MutationEffectGateway(
            store: store,
            resolver: context.resolver,
            policyRevisionAuthority: context.policyRevisionAuthority,
            checkpointer: RecordingMutationCheckpointer(),
            applier: RecordingMutationApplier()
        )) { error in
            XCTAssertEqual(
                error as? MutationEffectGatewayError,
                .crossProcessArbiterUnavailable
            )
        }
    }

    func testSameTargetDifferentPayloadDerivesDifferentExactOperation() async throws {
        let workspaceID = WorkspaceID()
        let firstContext = try await MutationEffectTestContext.make(
            arguments: .object([
                "path": .string("same.txt"),
                "contents": .string("first payload"),
            ]),
            workspaceID: workspaceID,
            idempotencyKey: "first"
        )
        let secondContext = try await MutationEffectTestContext.make(
            arguments: .object([
                "path": .string("same.txt"),
                "contents": .string("second payload"),
            ]),
            workspaceID: workspaceID,
            idempotencyKey: "second"
        )
        let first = try await firstContext.claimedPermit()
        let second = try await secondContext.claimedPermit()
        let firstOperation = try MutationEffectOperation.derive(
            borrowing: first
        )
        let secondOperation = try MutationEffectOperation.derive(
            borrowing: second
        )

        XCTAssertNotEqual(
            firstOperation.operationPayloadSHA256,
            secondOperation.operationPayloadSHA256
        )
        XCTAssertNotEqual(firstOperation.body, secondOperation.body)
        XCTAssertEqual(
            firstOperation.exactArguments.objectValue?["path"],
            secondOperation.exactArguments.objectValue?["path"]
        )
    }

    private func makeGateway(
        context: MutationEffectTestContext,
        store: any DurableMutationEffectLifecycleStore,
        clock: any MutationEffectSynchronousClock =
            LockedMutationEffectClock(),
        checkpointer: (any MutationEffectCheckpointing)? = nil,
        applier: any MutationEffectApplying
    ) throws -> MutationEffectGateway {
        let resolvedCheckpointer: any MutationEffectCheckpointing
        if let checkpointer {
            resolvedCheckpointer = checkpointer
        } else {
            resolvedCheckpointer = try RecordingMutationCheckpointer()
        }
        return try MutationEffectGateway(
            store: store,
            resolver: context.resolver,
            policyRevisionAuthority: context.policyRevisionAuthority,
            clock: clock,
            checkpointer: resolvedCheckpointer,
            applier: applier
        )
    }

    private func validResult(
        for operation: MutationEffectOperation,
        targets: [NormalizedToolTarget]
    ) throws -> MutationEffectApplicationResult {
        let targetKind: MutationEffectEvidenceKind?
        let outputKind: MutationEffectOutputKind
        var facts = [
            try MutationEffectEvidenceFact(
                kind: .workspaceAfter,
                digest: AgentPolicyTestFixture.digest("workspace-after")
            ),
        ]
        switch operation.body {
        case .writeFile:
            targetKind = .changedPath
            outputKind = .writeFile
        case .appendFile:
            targetKind = .changedPath
            outputKind = .appendFile
        case .replaceText:
            targetKind = .changedPath
            outputKind = .replaceText
        case .deletePath:
            targetKind = .deletedPath
            outputKind = .deletePath
        case .movePath:
            targetKind = .movedPath
            outputKind = .movePath
        case .copyPath:
            targetKind = .copiedPath
            outputKind = .copyPath
        case .makeDirectory:
            targetKind = .createdDirectory
            outputKind = .makeDirectory
        case .runCommand:
            targetKind = nil
            outputKind = .runCommand
            facts.append(try MutationEffectEvidenceFact(
                kind: .commandTranscript,
                digest: AgentPolicyTestFixture.digest("transcript")
            ))
            facts.append(try MutationEffectEvidenceFact(
                kind: .commandExit,
                digest: AgentPolicyTestFixture.digest("exit")
            ))
        case .createFile:
            targetKind = .changedPath
            outputKind = .createFile
        case .touchFile:
            targetKind = .changedPath
            outputKind = .touchFile
        case .resetWorkspace:
            targetKind = .deletedPath
            outputKind = .resetWorkspace
        case .seedWorkspace:
            targetKind = .changedPath
            outputKind = .seedWorkspace
        }
        if let targetKind {
            facts.append(try MutationEffectEvidenceFact(
                kind: targetKind,
                targets: targets,
                digest: AgentPolicyTestFixture.digest("target-after")
            ))
        }
        return try MutationEffectApplicationResult(
            resultSHA256: AgentPolicyTestFixture.digest("valid-result"),
            output: mutationEffectTestOutput(
                kind: outputKind,
                targets: targets
            ),
            evidence: facts
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ predicate: () -> Bool
    ) async throws {
        let iterations = max(1, Int(timeoutNanoseconds / 2_000_000))
        for _ in 0..<iterations {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition did not become true before timeout")
    }

    private func launchChildHoldingLock(
        _ lockURL: URL
    ) throws -> (process: Process, output: Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f,fcntl.LOCK_EX); print('locked',flush=True); time.sleep(30)",
            lockURL.path,
        ]
        process.standardOutput = output
        try process.run()
        return (process, output)
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "novaforge-mutation-gateway-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }
}

private final class MissingTargetEvidenceMutationApplier:
    @unchecked Sendable,
    MutationEffectApplying
{
    private let lock = NSLock()
    private var count = 0

    func apply(
        _ operation: MutationEffectOperation,
        authorization: borrowing MutationEffectApplicationAuthorization
    ) throws -> MutationEffectApplicationResult {
        lock.lock()
        count += 1
        lock.unlock()
        return try MutationEffectApplicationResult(
            resultSHA256: AgentPolicyTestFixture.digest("invalid-evidence"),
            output: mutationEffectTestOutput(
                targets: authorization.resolvedTargets
            ),
            evidence: [
                try MutationEffectEvidenceFact(
                    kind: .workspaceAfter,
                    digest: AgentPolicyTestFixture.digest("workspace-after")
                ),
            ]
        )
    }

    var applicationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private actor UnarbitratedMutationStore:
    DurableMutationEffectLifecycleStore
{
    private let base = InMemoryMutationEffectLifecycleStore()

    func insertPendingIfAbsent(
        _ record: MutationEffectRecord
    ) async throws -> MutationEffectInsertDisposition {
        try await base.insertPendingIfAbsent(record)
    }

    func compareAndTransition(
        expectedRecordSHA256: SHA256Digest,
        to next: MutationEffectRecord
    ) async throws -> MutationEffectTransitionDisposition {
        try await base.compareAndTransition(
            expectedRecordSHA256: expectedRecordSHA256,
            to: next
        )
    }

    func record(
        effectKeySHA256: SHA256Digest
    ) async throws -> MutationEffectRecord? {
        await base.record(effectKeySHA256: effectKeySHA256)
    }

    func snapshot() async throws -> MutationEffectLedgerSnapshot {
        await base.snapshot()
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}
