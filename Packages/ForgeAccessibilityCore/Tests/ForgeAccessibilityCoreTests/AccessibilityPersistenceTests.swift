import ForgeAccessibilityCore
import Foundation
import XCTest

final class AccessibilityPersistenceTests: XCTestCase {
    func testFindingCategoryMustMatchObservationCategory() throws {
        let fixture = try Fixture()
        let wrongFinding = try finding("wrong", category: .touchTargets, severity: .low)
        XCTAssertThrowsError(
            try fixture.observation(for: fixture.voiceOverRequirement, findings: [wrongFinding])
        ) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .findingCategoryMismatch(wrongFinding.id.rawValue))
        }
    }

    func testCodableRoundTripRevalidatesAssessment() throws {
        let fixture = try Fixture()
        let observations = try fixture.completePassingObservations()
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: fixture.policy,
            observations: observations
        )
        let data = try JSONEncoder().encode(assessment)
        let decoded = try JSONDecoder().decode(ForgeAccessibilityAssessment.self, from: data)
        XCTAssertEqual(decoded, assessment)
    }

    func testPersistedTargetTamperFailsClosedOnDecode() throws {
        let fixture = try Fixture()
        let observation = try fixture.observation(for: fixture.voiceOverRequirement)
        let policy = try fixture.policy(for: [fixture.voiceOverRequirement])
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: policy,
            observations: [observation]
        )
        let encoded = try JSONEncoder().encode(assessment)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var observations = try XCTUnwrap(object["observations"] as? [[String: Any]])
        var target = try XCTUnwrap(observations[0]["target"] as? [String: Any])
        target["sourceRevision"] = "rev-tampered"
        observations[0]["target"] = target
        object["observations"] = observations
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(ForgeAccessibilityAssessment.self, from: tampered)
        )
    }

    func testUnknownSchemaFailsClosed() throws {
        let fixture = try Fixture()
        XCTAssertThrowsError(
            try ForgeAccessibilityAssessment(
                schemaVersion: 99,
                target: fixture.target,
                policy: fixture.policy,
                observations: []
            )
        ) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .unsupportedSchema(99))
        }
    }

    func testIdentifiersAndHumanTextRejectControlOrNonCanonicalValues() throws {
        XCTAssertThrowsError(try id(" project"))
        XCTAssertThrowsError(try id("project id"))
        XCTAssertThrowsError(try id("project\n"))
        XCTAssertThrowsError(
            try ForgeAccessibilityFinding(
                id: id("finding"),
                category: .touchTargets,
                severity: .low,
                summary: "bad\nsummary"
            )
        )
    }

    func testPolicyRejectsDuplicateKindsAndRequirements() throws {
        let requirement = ForgeAccessibilityRequirement(
            id: try id("required"),
            category: .touchTargets,
            environmentProfile: .defaultPresentation
        )
        XCTAssertThrowsError(
            try ForgeAccessibilityAcceptancePolicy(
                requirements: [requirement, requirement],
                allowedExecutionKinds: [.simulator]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .duplicateRequirementID("required"))
        }
        XCTAssertThrowsError(
            try ForgeAccessibilityAcceptancePolicy(
                requirements: [requirement],
                allowedExecutionKinds: [.simulator, .simulator]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .duplicateExecutionKind("simulator"))
        }
    }

    func testInconclusiveAndNotRunRemainDistinctBlockers() throws {
        let fixture = try Fixture()
        let first = fixture.voiceOverRequirement
        let second = ForgeAccessibilityRequirement(
            id: try id("touch"),
            category: .touchTargets,
            environmentProfile: .defaultPresentation
        )
        let inconclusive = try fixture.observation(for: first, outcome: .inconclusive)
        let notRun = try fixture.observation(for: second, outcome: .notRun)
        let policy = try fixture.policy(for: [first, second])
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: policy,
            observations: [inconclusive, notRun]
        )
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: [inconclusive, notRun])
        )
        XCTAssertEqual(Set(evaluation.blockers), [
            .inconclusiveObservation(observationID: inconclusive.id),
            .notRunObservation(observationID: notRun.id),
        ])
    }

}
