import ForgeAccessibilityCore
import Foundation
import XCTest

final class AccessibilityEvaluationTests: XCTestCase {
    func testAcceptedAssessmentRequiresAuthenticatedEvidenceForEveryRequirement() throws {
        let fixture = try Fixture()
        let observations = try fixture.completePassingObservations()
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: fixture.policy,
            observations: observations
        )
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: Set(observations))
        )

        XCTAssertEqual(evaluation.verdict, .accepted)
        XCTAssertEqual(evaluation.contributingObservationIDs.count, fixture.policy.requirements.count)
        XCTAssertEqual(evaluation.contributingEvidenceReceiptIDs.count, fixture.policy.requirements.count)
        XCTAssertTrue(evaluation.blockers.isEmpty)
    }

    func testMissingRequirementFailsClosed() throws {
        let fixture = try Fixture()
        let observations = try fixture.completePassingObservations()
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: fixture.policy,
            observations: Array(observations.dropLast())
        )
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: Set(observations))
        )

        XCTAssertEqual(evaluation.verdict, .blocked)
        XCTAssertEqual(
            evaluation.blockers,
            [.missingObservation(requirementID: fixture.policy.requirements.last!.id)]
        )
    }

    func testPassedButUnauthenticatedObservationCannotBecomeEvidence() throws {
        let fixture = try Fixture()
        let observations = try fixture.completePassingObservations()
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: fixture.policy,
            observations: observations
        )
        let trusted = Set(observations.dropLast())
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: trusted)
        )

        XCTAssertEqual(evaluation.verdict, .blocked)
        XCTAssertEqual(
            evaluation.blockers,
            [.unauthenticatedObservation(observationID: observations.last!.id)]
        )
    }

    func testTrustBindsCompleteObservationNotBareReceiptID() throws {
        let fixture = try Fixture()
        let original = try fixture.observation(for: fixture.voiceOverRequirement)
        let changedEnvironment = try fixture.environment(
            profile: .voiceOver,
            orientation: .landscape
        )
        let replay = try ForgeAccessibilityObservation(
            id: original.id,
            target: original.target,
            requirementID: original.requirementID,
            category: original.category,
            environment: changedEnvironment,
            outcome: original.outcome,
            producer: original.producer,
            evidenceReceiptID: original.evidenceReceiptID,
            findings: original.findings
        )
        let oneRequirementPolicy = try fixture.policy(for: [fixture.voiceOverRequirement])
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: oneRequirementPolicy,
            observations: [replay]
        )
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: [original])
        )

        XCTAssertEqual(evaluation.verdict, .blocked)
        XCTAssertEqual(
            evaluation.blockers,
            [.unauthenticatedObservation(observationID: replay.id)]
        )
    }

    func testVoiceOverRequirementRejectsEnvironmentWithoutVoiceOver() throws {
        let fixture = try Fixture()
        let environment = try fixture.environment(profile: .defaultPresentation)
        let observation = try fixture.observation(
            for: fixture.voiceOverRequirement,
            environment: environment
        )
        let policy = try fixture.policy(for: [fixture.voiceOverRequirement])
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: policy,
            observations: [observation]
        )
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: [observation])
        )

        XCTAssertEqual(
            evaluation.blockers,
            [.environmentMismatch(requirementID: fixture.voiceOverRequirement.id, observationID: observation.id)]
        )
    }

    func testDynamicTypeXXXLAcceptsAccessibilitySizes() throws {
        let fixture = try Fixture()
        let requirement = ForgeAccessibilityRequirement(
            id: try id("dynamic"),
            category: .dynamicType,
            environmentProfile: .dynamicTypeXXXL
        )
        let environment = try fixture.environment(
            profile: .defaultPresentation,
            contentSize: .accessibilityExtraExtraExtraLarge
        )
        let observation = try fixture.observation(for: requirement, environment: environment)
        let policy = try fixture.policy(for: [requirement])
        let assessment = try ForgeAccessibilityAssessment(
            target: fixture.target,
            policy: policy,
            observations: [observation]
        )
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: [observation])
        )

        XCTAssertTrue(evaluation.isAccepted)
    }

    func testHighAndCriticalFindingsAlwaysBlockEvenWhenObservationSaysPassed() throws {
        let fixture = try Fixture()
        let requirement = fixture.voiceOverRequirement
        let high = try finding("high", category: requirement.category, severity: .high)
        let observation = try fixture.observation(for: requirement, findings: [high])
        let policy = try fixture.policy(for: [requirement], blocksMedium: false, blocksLow: false)
        let assessment = try ForgeAccessibilityAssessment(target: fixture.target, policy: policy, observations: [observation])
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: [observation])
        )

        XCTAssertEqual(evaluation.verdict, .blocked)
        XCTAssertEqual(evaluation.blockers, [.blockingFinding(findingID: high.id, severity: .high)])
        XCTAssertTrue(evaluation.contributingObservationIDs.isEmpty)
    }

    func testMediumAndLowFindingsFollowPolicyWithoutWeakeningHighFloor() throws {
        let fixture = try Fixture()
        let requirement = fixture.voiceOverRequirement
        let medium = try finding("medium", category: requirement.category, severity: .medium)
        let low = try finding("low", category: requirement.category, severity: .low)
        let observation = try fixture.observation(for: requirement, findings: [medium, low])

        let lenientPolicy = try fixture.policy(for: [requirement])
        let lenient = try ForgeAccessibilityAssessment(target: fixture.target, policy: lenientPolicy, observations: [observation])
        let lenientEvaluation = ForgeAccessibilityEvaluator.evaluate(
            lenient,
            authenticator: ExactAuthenticator(accepted: [observation])
        )
        XCTAssertTrue(lenientEvaluation.isAccepted)
        XCTAssertEqual(Set(lenientEvaluation.nonBlockingFindingIDs), [medium.id, low.id])

        let strictPolicy = try fixture.policy(for: [requirement], blocksMedium: true, blocksLow: true)
        let strict = try ForgeAccessibilityAssessment(target: fixture.target, policy: strictPolicy, observations: [observation])
        let strictEvaluation = ForgeAccessibilityEvaluator.evaluate(
            strict,
            authenticator: ExactAuthenticator(accepted: [observation])
        )
        XCTAssertEqual(strictEvaluation.verdict, .blocked)
        XCTAssertEqual(Set(strictEvaluation.blockers), [
            .blockingFinding(findingID: medium.id, severity: .medium),
            .blockingFinding(findingID: low.id, severity: .low),
        ])
    }

    func testFailedObservationRequiresFindingAndBlocks() throws {
        let fixture = try Fixture()
        let requirement = fixture.voiceOverRequirement
        XCTAssertThrowsError(
            try fixture.observation(for: requirement, outcome: .failed)
        ) { error in
            XCTAssertEqual(
                error as? ForgeAccessibilityError,
                .failedObservationRequiresFinding("obs-voiceover")
            )
        }

        let defect = try finding("voiceover-stuck", category: requirement.category, severity: .high)
        let observation = try fixture.observation(for: requirement, outcome: .failed, findings: [defect])
        let policy = try fixture.policy(for: [requirement])
        let assessment = try ForgeAccessibilityAssessment(target: fixture.target, policy: policy, observations: [observation])
        let evaluation = ForgeAccessibilityEvaluator.evaluate(
            assessment,
            authenticator: ExactAuthenticator(accepted: [observation])
        )
        XCTAssertTrue(evaluation.blockers.contains(.failedObservation(observationID: observation.id)))
        XCTAssertTrue(evaluation.blockers.contains(.blockingFinding(findingID: defect.id, severity: .high)))
    }

}
