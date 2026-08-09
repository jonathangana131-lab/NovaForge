import XCTest
@testable import ForgeAccessibilityCore

final class ForgeAccessibilityEvaluatorTests: ForgeAccessibilityTestCase {
    func testAcceptsOnlyWhenEveryBaselineScenarioHasTrustedPassingEvidence() throws {
        let policy = try policy()
        let runs = try allPassingRuns(policy: policy)
        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: try trusts(runs)
        )

        XCTAssertEqual(evaluation.status, .accepted)
        XCTAssertTrue(evaluation.blockers.isEmpty)
        XCTAssertEqual(evaluation.acceptedProducerReceiptIDs, runs.map(\.producerReceiptID).sorted())
    }

    func testMissingScenarioBlocks() throws {
        let policy = try policy()
        var runs = try allPassingRuns(policy: policy)
        let missing = runs.removeLast()

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: try trusts(runs)
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertTrue(evaluation.blockers.contains(.missingScenario(scenarioID: missing.scenarioID)))
    }

    func testSelfDeclaredAuthorityDoesNotAuthorizeUntrustedReceipt() throws {
        let policy = try policy()
        let runs = try allPassingRuns(policy: policy)
        let withheld = runs[0]
        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: try trusts(Array(runs.dropFirst()))
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertTrue(evaluation.blockers.contains(.untrustedProducerReceipt(
            scenarioID: withheld.scenarioID,
            producerReceiptID: withheld.producerReceiptID
        )))
        XCTAssertFalse(evaluation.acceptedProducerReceiptIDs.contains(withheld.producerReceiptID))
    }

    func testTrustedReceiptMustMatchExactRunBinding() throws {
        let policy = try policy()
        let runs = try allPassingRuns(policy: policy)
        let first = runs[0]
        var trusted = try trusts(Array(runs.dropFirst()))
        let mismatchedRun = try ForgeAccessibilityRunEvidence(
            runID: "different-run",
            target: first.target,
            scenarioID: first.scenarioID,
            authority: first.authority,
            producerReceiptID: first.producerReceiptID,
            checkResults: first.checkResults
        )
        trusted.append(try trust(mismatchedRun))

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: trusted
        )

        XCTAssertTrue(evaluation.blockers.contains(.untrustedProducerReceipt(
            scenarioID: first.scenarioID,
            producerReceiptID: first.producerReceiptID
        )))
    }

    func testTrustedReceiptBindsCompleteCheckResultPayload() throws {
        let policy = try policy()
        let scenario = try XCTUnwrap(policy.scenarios.first { $0.id == "baseline-touch" })
        let failedResult = try ForgeAccessibilityCheckResult(
            kind: .touchTargetGeometry,
            outcome: .failed,
            inspectedElementCount: 12,
            failureCount: 1,
            note: "One target is below the accepted geometry"
        )
        let authenticatedFailedRun = try run(
            for: scenario,
            target: policy.target,
            checkResults: [failedResult]
        )
        let relabeledPassedRun = try ForgeAccessibilityRunEvidence(
            runID: authenticatedFailedRun.runID,
            target: authenticatedFailedRun.target,
            scenarioID: authenticatedFailedRun.scenarioID,
            authority: authenticatedFailedRun.authority,
            producerReceiptID: authenticatedFailedRun.producerReceiptID,
            checkResults: [try passed(.touchTargetGeometry)]
        )

        let otherRuns = try allPassingRuns(policy: policy)
            .filter { $0.scenarioID != scenario.id }
        var trusted = try trusts(otherRuns)
        trusted.append(try trust(authenticatedFailedRun))

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: otherRuns + [relabeledPassedRun],
            trustedProducerReceipts: trusted
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertTrue(evaluation.blockers.contains(.untrustedProducerReceipt(
            scenarioID: scenario.id,
            producerReceiptID: authenticatedFailedRun.producerReceiptID
        )))
        XCTAssertFalse(evaluation.acceptedProducerReceiptIDs.contains(authenticatedFailedRun.producerReceiptID))
    }

    func testDuplicateTrustedProducerReceiptIDFailsClosed() throws {
        let policy = try policy()
        let runs = try allPassingRuns(policy: policy)
        let first = runs[0]
        let firstTrust = try trust(first)
        let conflictingRun = try ForgeAccessibilityRunEvidence(
            runID: "different-run",
            target: first.target,
            scenarioID: first.scenarioID,
            authority: first.authority,
            producerReceiptID: first.producerReceiptID,
            checkResults: first.checkResults
        )
        let conflictingTrust = try trust(conflictingRun)

        XCTAssertThrowsError(try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: [firstTrust, conflictingTrust]
        )) { error in
            XCTAssertEqual(
                error as? ForgeAccessibilityError,
                .duplicateTrustedProducerReceiptID(first.producerReceiptID)
            )
        }
    }

    func testFailedRequiredCheckBlocks() throws {
        let policy = try policy()
        let voiceOver = try XCTUnwrap(policy.scenarios.first { $0.id == "voiceover" })
        let failed = try ForgeAccessibilityCheckResult(
            kind: .focusOrder,
            outcome: .failed,
            inspectedElementCount: 12,
            failureCount: 2,
            note: "Two controls are traversed out of logical order"
        )
        let otherChecks = try voiceOver.requiredChecks
            .filter { $0 != .focusOrder }
            .map { try passed($0) }
        let badRun = try run(for: voiceOver, target: policy.target, checkResults: otherChecks + [failed])
        var runs = try allPassingRuns(policy: policy).filter { $0.scenarioID != voiceOver.id }
        runs.append(badRun)

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: try trusts(runs)
        )

        XCTAssertTrue(evaluation.blockers.contains(.checkNotPassed(
            scenarioID: voiceOver.id,
            check: .focusOrder,
            outcome: .failed
        )))
    }

    func testInconclusiveRequiredCheckBlocks() throws {
        let policy = try policy()
        let scenario = try XCTUnwrap(policy.scenarios.first { $0.id == "dynamic-type" })
        let result = try ForgeAccessibilityCheckResult(
            kind: .dynamicTypeLayout,
            outcome: .inconclusive,
            inspectedElementCount: 0,
            failureCount: 0,
            note: "Layout probe did not reach the rendered screen"
        )
        let replacement = try run(for: scenario, target: policy.target, checkResults: [result])
        var runs = try allPassingRuns(policy: policy).filter { $0.scenarioID != scenario.id }
        runs.append(replacement)

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: try trusts(runs)
        )

        XCTAssertTrue(evaluation.blockers.contains(.checkNotPassed(
            scenarioID: scenario.id,
            check: .dynamicTypeLayout,
            outcome: .inconclusive
        )))
    }

    func testMissingRequiredCheckBlocks() throws {
        let policy = try policy()
        let scenario = try XCTUnwrap(policy.scenarios.first { $0.id == "voiceover" })
        let incomplete = try run(
            for: scenario,
            target: policy.target,
            checkResults: [try passed(.voiceOverReachability), try passed(.semanticNameRoleValue)]
        )
        var runs = try allPassingRuns(policy: policy).filter { $0.scenarioID != scenario.id }
        runs.append(incomplete)

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: try trusts(runs)
        )

        XCTAssertTrue(evaluation.blockers.contains(.missingRequiredCheck(
            scenarioID: scenario.id,
            check: .focusOrder
        )))
    }

    func testReportedOptionalFailureCannotBeHiddenByPolicy() throws {
        let policy = try policy()
        let scenario = try XCTUnwrap(policy.scenarios.first { $0.id == "baseline-touch" })
        let keyboardFailure = try ForgeAccessibilityCheckResult(
            kind: .keyboardFocus,
            outcome: .failed,
            inspectedElementCount: 8,
            failureCount: 1,
            note: "One interactive control cannot receive keyboard focus"
        )
        let replacement = try run(
            for: scenario,
            target: policy.target,
            checkResults: [try passed(.touchTargetGeometry), keyboardFailure]
        )
        var runs = try allPassingRuns(policy: policy).filter { $0.scenarioID != scenario.id }
        runs.append(replacement)

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: try trusts(runs)
        )

        XCTAssertTrue(evaluation.blockers.contains(.checkNotPassed(
            scenarioID: scenario.id,
            check: .keyboardFocus,
            outcome: .failed
        )))
    }

    func testCrossRevisionEvidenceFailsClosed() throws {
        let policy = try policy()
        let scenario = policy.scenarios[0]
        let staleTarget = try target(sourceRevision: "source-stale")
        let stale = try run(for: scenario, target: staleTarget)

        XCTAssertThrowsError(try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: [stale],
            trustedProducerReceipts: [try trust(stale)]
        )) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .targetMismatch("run:\(stale.runID)"))
        }
    }

    func testDuplicateScenarioEvidenceFailsClosed() throws {
        let policy = try policy()
        let scenario = policy.scenarios[0]
        let first = try run(for: scenario, target: policy.target, receiptID: "receipt-a")
        let second = try ForgeAccessibilityRunEvidence(
            runID: "run-second",
            target: policy.target,
            scenarioID: scenario.id,
            authority: .xctestHarness,
            producerReceiptID: "receipt-b",
            checkResults: scenario.requiredChecks.map { try passed($0) }
        )

        XCTAssertThrowsError(try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: [first, second],
            trustedProducerReceipts: [try trust(first), try trust(second)]
        )) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .duplicateScenarioEvidence(scenario.id))
        }
    }

    func testProducerReceiptCannotBeReusedAcrossRuns() throws {
        let policy = try policy()
        let first = try run(for: policy.scenarios[0], target: policy.target, receiptID: "shared-receipt")
        let second = try run(for: policy.scenarios[1], target: policy.target, receiptID: "shared-receipt")

        XCTAssertThrowsError(try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: [first, second],
            trustedProducerReceipts: [try trust(first)]
        )) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .duplicateProducerReceiptID("shared-receipt"))
        }
    }

}
