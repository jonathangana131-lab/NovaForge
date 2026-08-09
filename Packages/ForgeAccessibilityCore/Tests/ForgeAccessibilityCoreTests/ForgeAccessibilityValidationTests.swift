import XCTest
@testable import ForgeAccessibilityCore

final class ForgeAccessibilityValidationTests: ForgeAccessibilityTestCase {
    func testPassedCheckRequiresConcreteObservation() {
        XCTAssertThrowsError(try ForgeAccessibilityCheckResult(
            kind: .contrast,
            outcome: .passed,
            inspectedElementCount: 0,
            failureCount: 0
        )) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .invalidCheckResult("contrast"))
        }
    }

    func testFailedCheckRequiresConcreteFailureCount() {
        XCTAssertThrowsError(try ForgeAccessibilityCheckResult(
            kind: .touchTargetGeometry,
            outcome: .failed,
            inspectedElementCount: 10,
            failureCount: 0,
            note: "claimed failure without a counted violation"
        )) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .invalidCheckResult("touchTargetGeometry"))
        }
    }

    func testDuplicateCheckKindFailsClosed() throws {
        let scenario = try baselineScenarios()[0]
        XCTAssertThrowsError(try ForgeAccessibilityRunEvidence(
            runID: "duplicate-check",
            target: target(),
            executionContext: try executionContext(),
            scenarioID: scenario.id,
            authority: .hostRuntimeHarness,
            producerReceiptID: "receipt-1",
            checkResults: [try passed(.touchTargetGeometry), try passed(.touchTargetGeometry)]
        )) { error in
            XCTAssertEqual(
                error as? ForgeAccessibilityError,
                .duplicateCheckKind(runID: "duplicate-check", check: .touchTargetGeometry)
            )
        }
    }

    func testPolicyRejectsVoiceOverChecksWithoutVoiceOverEnvironment() throws {
        var scenarios = try baselineScenarios()
        let index = try XCTUnwrap(scenarios.firstIndex { $0.id == "voiceover" })
        scenarios[index] = try ForgeAccessibilityScenario(
            id: "voiceover",
            environment: environment(assistiveTechnology: .none),
            requiredChecks: [.voiceOverReachability, .semanticNameRoleValue, .focusOrder]
        )

        XCTAssertThrowsError(try ForgeAccessibilityPolicy(target: target(), executionPolicy: executionPolicy(), scenarios: scenarios)) { error in
            XCTAssertEqual(
                error as? ForgeAccessibilityError,
                .insufficientBaselineCoverage("voiceOverEnvironment")
            )
        }
    }

    func testPolicyRejectsReduceMotionCheckWithoutReducedMotionEnvironment() throws {
        var scenarios = try baselineScenarios()
        let index = try XCTUnwrap(scenarios.firstIndex { $0.id == "reduce-motion" })
        scenarios[index] = try ForgeAccessibilityScenario(
            id: "reduce-motion",
            environment: environment(reduceMotion: false),
            requiredChecks: [.reduceMotionBehavior]
        )

        XCTAssertThrowsError(try ForgeAccessibilityPolicy(target: target(), executionPolicy: executionPolicy(), scenarios: scenarios)) { error in
            XCTAssertEqual(
                error as? ForgeAccessibilityError,
                .insufficientBaselineCoverage("reduceMotionEnvironment")
            )
        }
    }

    func testPolicyRejectsMissingBaselineCheckKind() throws {
        let scenarios = try baselineScenarios().filter { $0.id != "baseline-touch" }

        XCTAssertThrowsError(try ForgeAccessibilityPolicy(target: target(), executionPolicy: executionPolicy(), scenarios: scenarios)) { error in
            XCTAssertEqual(
                error as? ForgeAccessibilityError,
                .insufficientBaselineCoverage("missing:touchTargetGeometry")
            )
        }
    }

    func testUnknownScenarioEvidenceFailsClosed() throws {
        let policy = try policy()
        let evidence = try ForgeAccessibilityRunEvidence(
            runID: "unknown-run",
            target: policy.target,
            executionContext: try executionContext(),
            scenarioID: "not-in-policy",
            authority: .hostRuntimeHarness,
            producerReceiptID: "unknown-receipt",
            checkResults: [try passed(.contrast)]
        )

        XCTAssertThrowsError(try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: [evidence],
            trustedProducerReceipts: [try trust(evidence)]
        )) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .unknownScenario("not-in-policy"))
        }
    }

    func testPolicyDecodeRejectsUnknownSchema() throws {
        let policy = try policy()
        let encoded = try JSONEncoder().encode(policy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 99
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeAccessibilityPolicy.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .unsupportedSchema(99))
        }
    }

    func testRunDecodeRevalidatesCheckInvariants() throws {
        let policy = try policy()
        let run = try allPassingRuns(policy: policy)[0]
        let encoded = try JSONEncoder().encode(run)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var checks = try XCTUnwrap(object["checkResults"] as? [[String: Any]])
        checks[0]["inspectedElementCount"] = 0
        object["checkResults"] = checks
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeAccessibilityRunEvidence.self, from: tampered))
    }

    func testControlCharacterIdentifiersAreRejected() {
        XCTAssertThrowsError(try ForgeAccessibilityTarget(
            projectID: "project\nspoof",
            sourceRevision: "source",
            checkpointID: "checkpoint",
            runtimeVersion: "runtime"
        )) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .invalidIdentifier("target.projectID"))
        }
    }
    func testExecutionPolicyRejectsDuplicateKinds() {
        XCTAssertThrowsError(try ForgeAccessibilityExecutionPolicy(
            allowedKinds: [.simulator, .simulator]
        )) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .duplicateExecutionKind(.simulator))
        }
    }

    func testExecutionContextDecodeRevalidatesIdentity() throws {
        let context = try executionContext()
        let encoded = try JSONEncoder().encode(context)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["osBuild"] = "\n"
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeAccessibilityExecutionContext.self, from: tampered))
    }

}
