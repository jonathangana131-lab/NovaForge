import XCTest
@testable import ForgeAccessibilityCore

final class ForgeAccessibilityPolicyTrustTests: ForgeAccessibilityTestCase {
    func testExactTrustedPolicyCanReachAcceptedEvaluation() throws {
        let policy = try policy()
        let runs = try allPassingRuns(policy: policy)
        let trustedPolicy = ForgeAccessibilityTrustedPolicy(authenticatedPolicy: policy)

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: policy,
            runs: runs,
            trustedProducerReceipts: try trusts(runs),
            trustedPolicy: trustedPolicy
        )

        XCTAssertEqual(evaluation.status, .accepted)
        XCTAssertTrue(evaluation.blockers.isEmpty)
        XCTAssertEqual(evaluation.acceptedProducerReceiptIDs, runs.map(\.producerReceiptID).sorted())
    }

    func testCallerChangedPolicyCannotReuseTrustedPolicyAuthority() throws {
        let acceptedPolicy = try policy()
        let trustedPolicy = ForgeAccessibilityTrustedPolicy(authenticatedPolicy: acceptedPolicy)
        let callerChangedPolicy = try ForgeAccessibilityPolicy(
            target: acceptedPolicy.target,
            executionPolicy: ForgeAccessibilityExecutionPolicy(
                allowedKinds: [.physicalDevice, .simulator]
            ),
            scenarios: acceptedPolicy.scenarios
        )
        let runs = try allPassingRuns(policy: callerChangedPolicy)

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: callerChangedPolicy,
            runs: runs,
            trustedProducerReceipts: try trusts(runs),
            trustedPolicy: trustedPolicy
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertEqual(evaluation.blockers, [.untrustedPolicy])
        XCTAssertTrue(evaluation.acceptedProducerReceiptIDs.isEmpty)
    }

    func testTrustedPolicyBindsWholeScenarioRequirements() throws {
        let acceptedPolicy = try policy()
        let trustedPolicy = ForgeAccessibilityTrustedPolicy(authenticatedPolicy: acceptedPolicy)
        let originalScenario = try XCTUnwrap(
            acceptedPolicy.scenarios.first { $0.id == "baseline-touch" }
        )
        let strengthenedScenario = try ForgeAccessibilityScenario(
            id: originalScenario.id,
            environment: originalScenario.environment,
            requiredChecks: originalScenario.requiredChecks + [.keyboardFocus]
        )
        let changedScenarios = acceptedPolicy.scenarios.map { scenario in
            scenario.id == strengthenedScenario.id ? strengthenedScenario : scenario
        }
        let callerChangedPolicy = try ForgeAccessibilityPolicy(
            target: acceptedPolicy.target,
            executionPolicy: acceptedPolicy.executionPolicy,
            scenarios: changedScenarios
        )

        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: callerChangedPolicy,
            runs: [],
            trustedProducerReceipts: [],
            trustedPolicy: trustedPolicy
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertEqual(evaluation.blockers, [.untrustedPolicy])
        XCTAssertTrue(evaluation.acceptedProducerReceiptIDs.isEmpty)
    }

    func testDecodedEqualPolicyCanOnlyBeAcceptedWhenLiveTrustIsAlsoSupplied() throws {
        let acceptedPolicy = try policy()
        let archived = try JSONEncoder().encode(acceptedPolicy)
        let decoded = try JSONDecoder().decode(ForgeAccessibilityPolicy.self, from: archived)
        XCTAssertEqual(decoded, acceptedPolicy)

        let runs = try allPassingRuns(policy: decoded)
        let trustedPolicy = ForgeAccessibilityTrustedPolicy(authenticatedPolicy: acceptedPolicy)
        let evaluation = try ForgeAccessibilityEvaluator.evaluate(
            policy: decoded,
            runs: runs,
            trustedProducerReceipts: try trusts(runs),
            trustedPolicy: trustedPolicy
        )

        XCTAssertEqual(evaluation.status, .accepted)
    }
}
