import AgentDomain
@testable import AgentPolicy
import XCTest

final class MutationEffectLifecycleTests: XCTestCase {
    func testCanonicalLifecyclePreservesCheckpointAndEvidenceLineage() async throws {
        let context = try await MutationEffectTestContext.make()
        let pending = try await context.pendingRecord()
        let result = try MutationEffectApplicationResult(
            resultSHA256: AgentPolicyTestFixture.digest("result-a"),
            output: mutationEffectTestOutput(),
            evidence: [
                MutationEffectEvidenceFact(
                    kind: .workspaceAfter,
                    digest: AgentPolicyTestFixture.digest("after-a")
                ),
            ]
        )
        let applied = try pending.applying(
            result,
            at: AgentInstant(rawValue: 31)
        )
        let evidence = try applied.settlingEvidence(
            at: AgentInstant(rawValue: 32)
        )

        XCTAssertEqual(pending.phase, .pending)
        XCTAssertEqual(applied.phase, .applied)
        XCTAssertEqual(evidence.phase, .evidence)
        XCTAssertTrue(pending.isCanonical())
        XCTAssertTrue(applied.isCanonical())
        XCTAssertTrue(evidence.isCanonical())
        XCTAssertNoThrow(
            try MutationEffectRecord.validateTransition(
                from: pending,
                to: applied
            )
        )
        XCTAssertNoThrow(
            try MutationEffectRecord.validateTransition(
                from: applied,
                to: evidence
            )
        )
    }

    func testTransitionRejectsCanonicalRecordWithReplacedEmbeddedHistory() async throws {
        let context = try await MutationEffectTestContext.make()
        let first = try await context.pendingRecord(checkpointSeed: "first")
        let replaced = try await context.pendingRecord(
            checkpointSeed: "replacement"
        )
        XCTAssertEqual(first.binding, replaced.binding)
        XCTAssertNotEqual(first.state, replaced.state)

        let appliedFromReplacement = try replaced.applying(
            MutationEffectApplicationResult(
                resultSHA256: AgentPolicyTestFixture.digest("result"),
                output: mutationEffectTestOutput(),
                evidence: [
                    MutationEffectEvidenceFact(
                        kind: .workspaceAfter,
                        digest: AgentPolicyTestFixture.digest("after")
                    ),
                ]
            ),
            at: AgentInstant(rawValue: 31)
        )
        XCTAssertThrowsError(
            try MutationEffectRecord.validateTransition(
                from: first,
                to: appliedFromReplacement
            )
        ) { error in
            XCTAssertEqual(
                error as? MutationEffectLifecycleError,
                .invalidTransition(from: .pending, to: .applied)
            )
        }
    }

    func testReconciliationBindsExactPriorRecordDigestAndIsTerminal() async throws {
        let context = try await MutationEffectTestContext.make()
        let pending = try await context.pendingRecord()
        let reconciled = try pending.requiringReconciliation(
            .ambiguousPendingAfterRecovery,
            at: AgentInstant(rawValue: 31)
        )
        try MutationEffectRecord.validateTransition(
            from: pending,
            to: reconciled
        )
        guard case let .needsReconciliation(
            storedPending,
            application,
            reconciliation
        ) = reconciled.state else {
            return XCTFail("expected terminal reconciliation")
        }
        XCTAssertEqual(storedPending, pendingState(in: pending))
        XCTAssertNil(application)
        XCTAssertEqual(
            reconciliation.priorRecordSHA256,
            pending.recordSHA256
        )
        XCTAssertThrowsError(
            try reconciled.requiringReconciliation(
                .corruptOrConflictingState,
                at: AgentInstant(rawValue: 32)
            )
        )
    }

    func testMonotonicTimesAndClaimLifetimeFailClosed() async throws {
        let context = try await MutationEffectTestContext.make()
        let pending = try await context.pendingRecord(preparedAt: 30)
        XCTAssertThrowsError(
            try pending.applying(
                MutationEffectApplicationResult(
                    resultSHA256: AgentPolicyTestFixture.digest("result"),
                    output: mutationEffectTestOutput(),
                    evidence: [
                        MutationEffectEvidenceFact(
                            kind: .workspaceAfter,
                            digest: AgentPolicyTestFixture.digest("after")
                        ),
                    ]
                ),
                at: AgentInstant(rawValue: 29)
            )
        )

        let permit = try await context.claimedPermit(expiresAt: 30)
        let binding = try MutationEffectBinding.make(borrowing: permit)
        XCTAssertThrowsError(
            try MutationEffectRecord.pending(
                binding: binding,
                checkpoint: MutationEffectCheckpointResult(
                    beforeStateSHA256: AgentPolicyTestFixture.digest("before"),
                    rollbackOrReconciliationPlanSHA256:
                        AgentPolicyTestFixture.digest("rollback")
                ),
                preparedAt: AgentInstant(rawValue: 30)
            )
        )
    }

    func testEvidenceKindsAreCanonicalAndUniqueByKind() throws {
        XCTAssertThrowsError(try MutationEffectEvidenceFact(
            kind: .changedPath,
            digest: AgentPolicyTestFixture.digest("a")
        ))
        XCTAssertThrowsError(
            try MutationEffectApplicationResult(
                resultSHA256: AgentPolicyTestFixture.digest("result"),
                output: mutationEffectTestOutput(),
                evidence: [
                    MutationEffectEvidenceFact(
                        kind: .workspaceAfter,
                        digest: AgentPolicyTestFixture.digest("a")
                    ),
                    MutationEffectEvidenceFact(
                        kind: .workspaceAfter,
                        digest: AgentPolicyTestFixture.digest("b")
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? MutationEffectLifecycleError,
                .duplicateEvidence
            )
        }
    }

    func testChangedPathEvidenceAcceptsBoundedCanonicalTargetSet() throws {
        let targets = try [
            NormalizedToolTarget(path: "Sources/App.swift", access: .write),
            NormalizedToolTarget(path: "Tests/AppTests.swift", access: .write),
        ]
        let fact = try MutationEffectEvidenceFact(
            kind: .changedPath,
            targets: Array(targets.reversed()),
            digest: AgentPolicyTestFixture.digest("multi-target-change")
        )

        XCTAssertEqual(
            fact.targets,
            try NormalizedToolTarget.canonicalize(targets)
        )
        XCTAssertThrowsError(try MutationEffectEvidenceFact(
            kind: .changedPath,
            targets: [],
            digest: AgentPolicyTestFixture.digest("empty-change")
        ))
        XCTAssertThrowsError(try MutationEffectEvidenceFact(
            kind: .changedPath,
            targets: try (0 ... MutationEffectOutput.maximumTargets).map {
                try NormalizedToolTarget(
                    path: "Generated/file-\($0).txt",
                    access: .write
                )
            },
            digest: AgentPolicyTestFixture.digest("oversized-change")
        ))
    }

    func testInMemoryStoreUsesExactCASAndIdempotentPostCommitReadback() async throws {
        let context = try await MutationEffectTestContext.make()
        let pending = try await context.pendingRecord()
        let store = InMemoryMutationEffectLifecycleStore()
        guard case .inserted = try await store.insertPendingIfAbsent(pending)
        else { return XCTFail("expected insert") }

        let applied = try pending.applying(
            MutationEffectApplicationResult(
                resultSHA256: AgentPolicyTestFixture.digest("result"),
                output: mutationEffectTestOutput(),
                evidence: [
                    MutationEffectEvidenceFact(
                        kind: .workspaceAfter,
                        digest: AgentPolicyTestFixture.digest("after")
                    ),
                ]
            ),
            at: AgentInstant(rawValue: 31)
        )
        do {
            _ = try await store.compareAndTransition(
                expectedRecordSHA256: AgentPolicyTestFixture.digest("wrong"),
                to: applied
            )
            XCTFail("stale digest must fail")
        } catch let error as MutationEffectLifecycleError {
            guard case .staleRecord = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        guard case .committed = try await store.compareAndTransition(
            expectedRecordSHA256: pending.recordSHA256,
            to: applied
        ) else { return XCTFail("expected commit") }
        guard case .alreadyCommitted = try await store.compareAndTransition(
            expectedRecordSHA256: pending.recordSHA256,
            to: applied
        ) else { return XCTFail("expected idempotent readback") }
    }

    func testStrictDecodeRejectsEveryOmittedBindingSecurityField() async throws {
        let context = try await MutationEffectTestContext.make()
        let pending = try await context.pendingRecord()
        let encoded = try JSONEncoder().encode(pending)
        let securityFields = [
            "origin",
            "effectKeySHA256",
            "requestSHA256",
            "policySHA256",
            "claimSHA256",
            "tool",
            "effectClass",
            "canonicalArgumentDigest",
            "operationPayloadSHA256",
            "operationPreviewSHA256",
            "callID",
            "idempotencyKey",
            "workspaceID",
            "resolutionAttestationSHA256",
            "resolvedTargets",
            "authorizedAt",
            "expiresAt",
            "claimedAt",
            "bindingSHA256",
        ]

        for field in securityFields {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded)
                    as? [String: Any]
            )
            var binding = try XCTUnwrap(
                object["binding"] as? [String: Any]
            )
            binding.removeValue(forKey: field)
            object["binding"] = binding
            let downgraded = try JSONSerialization.data(
                withJSONObject: object
            )
            XCTAssertThrowsError(try JSONDecoder().decode(
                MutationEffectRecord.self,
                from: downgraded
            ), field)
        }
    }

    private func pendingState(
        in record: MutationEffectRecord
    ) -> MutationEffectPendingRecord? {
        guard case let .pending(pending) = record.state else { return nil }
        return pending
    }
}
