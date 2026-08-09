import ForgeAccessibilityCore
import Foundation
import XCTest

final class AccessibilityAssessmentTests: XCTestCase {
    func testDuplicateObservationForRequirementAndReceiptReplayFailClosed() throws {
        let fixture = try Fixture()
        let requirement = fixture.voiceOverRequirement
        let first = try fixture.observation(for: requirement)
        let second = try ForgeAccessibilityObservation(
            id: id("obs-second"),
            target: fixture.target,
            requirementID: requirement.id,
            category: requirement.category,
            environment: try fixture.environment(profile: requirement.environmentProfile),
            outcome: .passed,
            producer: .runtimeHost,
            evidenceReceiptID: id("receipt-second")
        )
        let policy = try fixture.policy(for: [requirement])
        XCTAssertThrowsError(
            try ForgeAccessibilityAssessment(target: fixture.target, policy: policy, observations: [first, second])
        ) { error in
            XCTAssertEqual(
                error as? ForgeAccessibilityError,
                .duplicateObservationForRequirement(requirement.id.rawValue)
            )
        }

        let otherRequirement = ForgeAccessibilityRequirement(
            id: try id("other"),
            category: .touchTargets,
            environmentProfile: .defaultPresentation
        )
        let replay = try ForgeAccessibilityObservation(
            id: id("obs-other"),
            target: fixture.target,
            requirementID: otherRequirement.id,
            category: otherRequirement.category,
            environment: try fixture.environment(profile: .defaultPresentation),
            outcome: .passed,
            producer: .runtimeHost,
            evidenceReceiptID: first.evidenceReceiptID
        )
        let twoPolicy = try fixture.policy(for: [requirement, otherRequirement])
        XCTAssertThrowsError(
            try ForgeAccessibilityAssessment(target: fixture.target, policy: twoPolicy, observations: [first, replay])
        ) { error in
            XCTAssertEqual(
                error as? ForgeAccessibilityError,
                .duplicateEvidenceReceiptID(first.evidenceReceiptID.rawValue)
            )
        }
    }

    func testCrossRevisionObservationCannotEnterAssessment() throws {
        let fixture = try Fixture()
        let requirement = fixture.voiceOverRequirement
        let otherTarget = ForgeAccessibilityTarget(
            projectID: fixture.target.projectID,
            sourceRevision: try id("rev-2"),
            journeyID: fixture.target.journeyID
        )
        let observation = try ForgeAccessibilityObservation(
            id: id("obs-cross"),
            target: otherTarget,
            requirementID: requirement.id,
            category: requirement.category,
            environment: try fixture.environment(profile: .voiceOver),
            outcome: .passed,
            producer: .xctest,
            evidenceReceiptID: id("receipt-cross")
        )
        let policy = try fixture.policy(for: [requirement])
        XCTAssertThrowsError(
            try ForgeAccessibilityAssessment(target: fixture.target, policy: policy, observations: [observation])
        ) { error in
            XCTAssertEqual(
                error as? ForgeAccessibilityError,
                .observationTargetMismatch(observation.id.rawValue)
            )
        }
    }

    func testRequiredDeviceAndOSBuildAreExactAcceptanceInputs() throws {
        let fixture = try Fixture()
        let requirement = fixture.voiceOverRequirement
        let observation = try fixture.observation(for: requirement)
        let wrongDevicePolicy = try fixture.policy(
            for: [requirement],
            requiredDevice: "different-device"
        )
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: wrongDevicePolicy,
            observations: [observation]
        )
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: [observation])
        )
        XCTAssertEqual(
            evaluation.blockers,
            [.environmentMismatch(requirementID: requirement.id, observationID: observation.id)]
        )

        let wrongBuildPolicy = try fixture.policy(
            for: [requirement],
            requiredBuild: "different-build"
        )
        let secondAssessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: wrongBuildPolicy,
            observations: [observation]
        )
        XCTAssertEqual(
            ForgeAccessibilityEvaluator.evaluate(
                secondAssessment,
                authenticator: ExactAuthenticator(accepted: [observation])
            ).verdict,
            .blocked
        )
    }

    func testSimulatorAndPhysicalDeviceAreDistinctPolicyInputs() throws {
        let fixture = try Fixture()
        let requirement = fixture.voiceOverRequirement
        let observation = try fixture.observation(for: requirement)
        let physicalOnly = try ForgeAccessibilityAcceptancePolicy(
            requirements: [requirement],
            allowedExecutionKinds: [.physicalDevice]
        )
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: physicalOnly,
            observations: [observation]
        )
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: [observation])
        )
        XCTAssertEqual(evaluation.verdict, .blocked)
    }

    func testDuplicateFindingIdentityAcrossObservationsFailsClosed() throws {
        let fixture = try Fixture()
        let firstRequirement = fixture.voiceOverRequirement
        let secondRequirement = ForgeAccessibilityRequirement(
            id: try id("touch"),
            category: .touchTargets,
            environmentProfile: .defaultPresentation
        )
        let duplicateID = try id("shared-finding")
        let firstFinding = try ForgeAccessibilityFinding(
            id: duplicateID,
            category: firstRequirement.category,
            severity: .low,
            summary: "First warning"
        )
        let secondFinding = try ForgeAccessibilityFinding(
            id: duplicateID,
            category: secondRequirement.category,
            severity: .low,
            summary: "Second warning"
        )
        let first = try fixture.observation(for: firstRequirement, findings: [firstFinding])
        let second = try fixture.observation(for: secondRequirement, findings: [secondFinding])
        let policy = try fixture.policy(for: [firstRequirement, secondRequirement])
        XCTAssertThrowsError(
            try ForgeAccessibilityAssessment(target: fixture.target, policy: policy, observations: [first, second])
        ) { error in
            XCTAssertEqual(error as? ForgeAccessibilityError, .duplicateFindingID(duplicateID.rawValue))
        }
    }

}
