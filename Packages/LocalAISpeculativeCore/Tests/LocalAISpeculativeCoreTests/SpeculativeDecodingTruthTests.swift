import XCTest
@testable import LocalAISpeculativeCore

final class SpeculativeDecodingTruthTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)
    private let digestC = String(repeating: "c", count: 64)
    private let digestD = String(repeating: "d", count: 64)
    private let digestE = String(repeating: "e", count: 64)
    private let outputDigest = String(repeating: "f", count: 64)

    func testValidLocalDraftPairIsStructurallyEligibleForTrial() {
        let result = SpeculativeTrialValidator.evaluate(
            configuration: configuration(),
            declaration: declaration()
        )

        XCTAssertTrue(result.isEligible)
        XCTAssertTrue(result.rejections.isEmpty)
    }

    func testDraftPairRejectsMismatchedTokenSemantics() {
        let result = SpeculativeTrialValidator.evaluate(
            configuration: configuration(
                drafter: participant(
                    profile: "draft-profile",
                    tokenDigest: digestB
                )
            ),
            declaration: declaration()
        )

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.rejections, [.incompatibleTokenSemantics])
    }

    func testLocalOnlyRejectsHostedDrafter() {
        let result = SpeculativeTrialValidator.evaluate(
            configuration: configuration(
                drafter: participant(
                    profile: "draft-profile",
                    locality: .hosted
                )
            ),
            declaration: declaration()
        )

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.rejections, [.localOnlyViolation])
    }

    func testDraftModelRequiresDrafterAndDrafterRuntimeConfiguration() {
        let missingDrafter = SpeculativeTrialValidator.evaluate(
            configuration: configuration(includeDrafter: false),
            declaration: declaration()
        )
        XCTAssertFalse(missingDrafter.isEligible)
        XCTAssertEqual(missingDrafter.rejections, [.missingDrafter])

        let missingRuntimeConfig = SpeculativeTrialValidator.evaluate(
            configuration: configuration(drafterRuntimeConfigurationSHA256: nil),
            declaration: declaration()
        )
        XCTAssertFalse(missingRuntimeConfig.isEligible)
        XCTAssertEqual(missingRuntimeConfig.rejections, [.missingDrafterRuntimeConfiguration])
    }

    func testDraftlessMechanismRejectsUnexpectedDrafterAndRuntimeConfiguration() {
        let config = SpeculativeDecodingConfiguration(
            verifier: participant(profile: "target-profile"),
            drafter: participant(profile: "draft-profile"),
            verifierRuntimeConfigurationSHA256: digestC,
            drafterRuntimeConfigurationSHA256: digestD,
            mechanismID: "ngram-simple",
            capabilityDeclarationRevision: "source-rev-1",
            kind: .ngram,
            maximumDraftTokens: 3,
            contextTokens: 4_096,
            promptContractSHA256: digestB,
            privacyPolicy: .localOnly
        )
        let runtime = SpeculativeRuntimeCapabilityDeclaration(
            runtimeID: "llama.cpp",
            runtimeRevision: "rev-1",
            mechanismID: "ngram-simple",
            kind: .ngram,
            maximumDraftTokens: 8,
            declarationRevision: "source-rev-1"
        )

        let result = SpeculativeTrialValidator.evaluate(
            configuration: config,
            declaration: runtime
        )

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.rejections, [.unexpectedDrafter, .unexpectedDrafterRuntimeConfiguration])
    }

    func testExactRuntimeRevisionMustMatchDeclaration() {
        let runtime = SpeculativeRuntimeCapabilityDeclaration(
            runtimeID: "llama.cpp",
            runtimeRevision: "rev-2",
            mechanismID: "draft-simple",
            kind: .draftModel,
            maximumDraftTokens: 8,
            declarationRevision: "source-rev-1"
        )

        let result = SpeculativeTrialValidator.evaluate(
            configuration: configuration(),
            declaration: runtime
        )

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.rejections, [.runtimeMismatch])
    }

    func testConfigurationMustBindExactCapabilityDeclarationRevision() {
        let config = configuration(capabilityDeclarationRevision: "source-rev-stale")
        let result = SpeculativeTrialValidator.evaluate(
            configuration: config,
            declaration: declaration()
        )

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.rejections, [.declarationRevisionMismatch])
    }

    func testDraftPairRejectsDifferentRuntimeRevision() {
        let staleDrafter = SpeculativeParticipantIdentity(
            qualificationProfileID: "draft-profile",
            runtimeID: "llama.cpp",
            runtimeRevision: "rev-stale",
            tokenSemanticsSHA256: digestA,
            executionLocality: .onDevice
        )
        let result = SpeculativeTrialValidator.evaluate(
            configuration: configuration(drafter: staleDrafter),
            declaration: declaration()
        )

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.rejections, [.drafterRuntimeMismatch])
    }

    func testDraftLimitCannotExceedRuntimeDeclaration() {
        let result = SpeculativeTrialValidator.evaluate(
            configuration: configuration(maximumDraftTokens: 9),
            declaration: declaration(maximumDraftTokens: 8)
        )

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.rejections, [.draftLimitExceeded])
    }

    func testTrialRejectsMalformedExactRuntimeConfigurationFingerprint() {
        let result = SpeculativeTrialValidator.evaluate(
            configuration: configuration(verifierRuntimeConfigurationSHA256: "not-a-digest"),
            declaration: declaration()
        )

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.rejections, [.malformedFingerprint])
    }

    func testComparisonRejectsReceiptFromDifferentCandidateConfiguration() {
        let expected = configuration()
        let observed = configuration(contextTokens: 8_192)
        let result = SpeculativeComparisonEvaluator.evaluate(
            configuration: expected,
            baselineConfiguration: baseline(),
            declaration: declaration(),
            receipt: receipt(configuration: observed)
        )

        XCTAssertFalse(result.isLatencyCandidate)
        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.rejections, [.comparisonProfileMismatch])
        XCTAssertNil(result.measuredSpeedupRatio)
    }

    func testComparisonRejectsReceiptFromDifferentExpectedBaselineConfiguration() {
        let expectedBaseline = baseline()
        let observedBaseline = baseline(verifierRuntimeConfigurationSHA256: digestA)
        let result = SpeculativeComparisonEvaluator.evaluate(
            configuration: configuration(),
            baselineConfiguration: expectedBaseline,
            declaration: declaration(),
            receipt: receipt(baselineConfiguration: observedBaseline)
        )

        XCTAssertFalse(result.isLatencyCandidate)
        XCTAssertEqual(result.rejections, [.baselineProfileMismatch])
        XCTAssertNil(result.measuredSpeedupRatio)
    }

    func testComparisonRejectsBaselineThatChangesTargetOrPromptWorkload() {
        let mismatchedBaseline = baseline(
            verifier: participant(profile: "different-target"),
            promptContractSHA256: digestE
        )
        let result = SpeculativeComparisonEvaluator.evaluate(
            configuration: configuration(),
            baselineConfiguration: mismatchedBaseline,
            declaration: declaration(),
            receipt: receipt(baselineConfiguration: mismatchedBaseline)
        )

        XCTAssertFalse(result.isLatencyCandidate)
        XCTAssertEqual(result.rejections, [.baselineProfileMismatch])
    }

    func testStrictComparisonRejectsOutputDivergence() {
        let result = assessment(
            receipt: receipt(speculativeOutputSHA256: digestA)
        )

        XCTAssertFalse(result.isLatencyCandidate)
        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.rejections, [.outputDiverged])
        XCTAssertEqual(result.measuredSpeedupRatio ?? .nan, 1.25, accuracy: 0.000_001)
    }

    func testComparisonRejectsSlowdownEvenWithPassingCases() {
        let result = assessment(
            receipt: receipt(
                baselineDurationNanoseconds: 800,
                speculativeDurationNanoseconds: 1_000
            )
        )

        XCTAssertFalse(result.isLatencyCandidate)
        XCTAssertEqual(result.rejections, [.slowerThanBaseline])
        XCTAssertEqual(result.measuredSpeedupRatio ?? .nan, 0.8, accuracy: 0.000_001)
    }

    func testComparisonRejectsObservedFailures() {
        let result = assessment(
            receipt: receipt(successfulCases: 3, failedCases: 1)
        )

        XCTAssertFalse(result.isLatencyCandidate)
        XCTAssertEqual(result.rejections, [.failuresObserved])
    }

    func testComparisonRejectsInvalidAcceptedDraftCount() {
        let result = assessment(
            receipt: receipt(proposedDraftTokens: 4, acceptedDraftTokens: 5)
        )

        XCTAssertFalse(result.isLatencyCandidate)
        XCTAssertEqual(result.rejections, [.invalidMeasurement])
        XCTAssertNil(result.measuredSpeedupRatio)
    }

    func testComparisonRejectsReceiptThatNeverProposedDraftTokens() {
        let result = assessment(
            receipt: receipt(proposedDraftTokens: 0, acceptedDraftTokens: 0)
        )

        XCTAssertFalse(result.isLatencyCandidate)
        XCTAssertEqual(result.rejections, [.invalidMeasurement])
        XCTAssertNil(result.measuredSpeedupRatio)
    }

    func testComparisonRequiresExactWorkloadAndEnvironmentFingerprints() {
        let malformedWorkload = assessment(
            receipt: receipt(workloadManifestSHA256: "suite-label")
        )
        XCTAssertFalse(malformedWorkload.isLatencyCandidate)
        XCTAssertEqual(malformedWorkload.rejections, [.malformedFingerprint])

        let malformedEnvironment = assessment(
            receipt: receipt(measurementEnvironmentSHA256: "iphone13,2-ios27")
        )
        XCTAssertFalse(malformedEnvironment.isLatencyCandidate)
        XCTAssertEqual(malformedEnvironment.rejections, [.malformedFingerprint])
    }

    func testExactMeasuredComparisonIsOnlyResearchLatencyCandidate() {
        let result = assessment(receipt: receipt())

        XCTAssertTrue(result.isLatencyCandidate)
        XCTAssertFalse(result.isPromotable)
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertEqual(result.authority, .researchLatencyCandidateOnly)
        XCTAssertEqual(result.measuredSpeedupRatio ?? .nan, 1.25, accuracy: 0.000_001)
    }

    func testCallerWeakenedPolicyCanNeverCreatePromotionAuthority() {
        let permissive = SpeculativeComparisonPolicy(
            minimumSuccessfulCases: 1,
            maximumFailedCases: .max,
            minimumSpeedupRatio: 1,
            requiresExactOutputParity: false
        )
        let result = assessment(
            receipt: receipt(successfulCases: 1, failedCases: 2),
            policy: permissive
        )

        XCTAssertTrue(result.isLatencyCandidate)
        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.authority, .researchLatencyCandidateOnly)
    }

    func testLegacyPromotionEvaluatorAlsoFailsClosedForProductPromotion() {
        let result = SpeculativePromotionEvaluator.evaluate(
            configuration: configuration(),
            baselineConfiguration: baseline(),
            declaration: declaration(),
            receipt: receipt()
        )

        XCTAssertTrue(result.isLatencyCandidate)
        XCTAssertFalse(result.isPromotable)
    }

    private func participant(
        profile: String,
        tokenDigest: String? = nil,
        locality: SpeculativeExecutionLocality = .onDevice
    ) -> SpeculativeParticipantIdentity {
        SpeculativeParticipantIdentity(
            qualificationProfileID: profile,
            runtimeID: "llama.cpp",
            runtimeRevision: "rev-1",
            tokenSemanticsSHA256: tokenDigest ?? digestA,
            executionLocality: locality
        )
    }

    private func configuration(
        drafter: SpeculativeParticipantIdentity? = nil,
        includeDrafter: Bool = true,
        verifierRuntimeConfigurationSHA256: String? = nil,
        drafterRuntimeConfigurationSHA256: String?? = .some(nil),
        capabilityDeclarationRevision: String = "source-rev-1",
        maximumDraftTokens: UInt16 = 4,
        contextTokens: UInt64 = 4_096
    ) -> SpeculativeDecodingConfiguration {
        let resolvedDrafter = includeDrafter
            ? (drafter ?? participant(profile: "draft-profile"))
            : nil
        let resolvedDrafterRuntimeConfiguration: String?
        switch drafterRuntimeConfigurationSHA256 {
        case .some(.some(let explicit)):
            resolvedDrafterRuntimeConfiguration = explicit
        case .some(.none):
            resolvedDrafterRuntimeConfiguration = includeDrafter ? digestD : nil
        case .none:
            resolvedDrafterRuntimeConfiguration = nil
        }

        return SpeculativeDecodingConfiguration(
            verifier: participant(profile: "target-profile"),
            drafter: resolvedDrafter,
            verifierRuntimeConfigurationSHA256: verifierRuntimeConfigurationSHA256 ?? digestC,
            drafterRuntimeConfigurationSHA256: resolvedDrafterRuntimeConfiguration,
            mechanismID: "draft-simple",
            capabilityDeclarationRevision: capabilityDeclarationRevision,
            kind: .draftModel,
            maximumDraftTokens: maximumDraftTokens,
            contextTokens: contextTokens,
            promptContractSHA256: digestB,
            privacyPolicy: .localOnly
        )
    }

    private func baseline(
        verifier: SpeculativeParticipantIdentity? = nil,
        verifierRuntimeConfigurationSHA256: String? = nil,
        contextTokens: UInt64 = 4_096,
        promptContractSHA256: String? = nil
    ) -> SpeculativeBaselineConfiguration {
        SpeculativeBaselineConfiguration(
            verifier: verifier ?? participant(profile: "target-profile"),
            verifierRuntimeConfigurationSHA256: verifierRuntimeConfigurationSHA256 ?? digestE,
            contextTokens: contextTokens,
            promptContractSHA256: promptContractSHA256 ?? digestB,
            privacyPolicy: .localOnly
        )
    }

    private func declaration(
        maximumDraftTokens: UInt16 = 8
    ) -> SpeculativeRuntimeCapabilityDeclaration {
        SpeculativeRuntimeCapabilityDeclaration(
            runtimeID: "llama.cpp",
            runtimeRevision: "rev-1",
            mechanismID: "draft-simple",
            kind: .draftModel,
            maximumDraftTokens: maximumDraftTokens,
            declarationRevision: "source-rev-1"
        )
    }

    private func receipt(
        configuration: SpeculativeDecodingConfiguration? = nil,
        baselineConfiguration: SpeculativeBaselineConfiguration? = nil,
        workloadManifestSHA256: String? = nil,
        speculativeOutputSHA256: String? = nil,
        baselineDurationNanoseconds: UInt64 = 1_000,
        speculativeDurationNanoseconds: UInt64 = 800,
        proposedDraftTokens: UInt64 = 100,
        acceptedDraftTokens: UInt64 = 70,
        successfulCases: UInt32 = 3,
        failedCases: UInt32 = 0,
        measurementEnvironmentSHA256: String? = nil
    ) -> SpeculativeComparisonReceipt {
        SpeculativeComparisonReceipt(
            configuration: configuration ?? self.configuration(),
            baselineConfiguration: baselineConfiguration ?? baseline(),
            workloadSuiteID: "nova-coding-smoke",
            workloadRevision: "suite-rev-1",
            workloadManifestSHA256: workloadManifestSHA256 ?? digestC,
            baselineRunID: "baseline-1",
            speculativeRunID: "spec-1",
            baselineOutputSHA256: outputDigest,
            speculativeOutputSHA256: speculativeOutputSHA256 ?? outputDigest,
            baselineDurationNanoseconds: baselineDurationNanoseconds,
            speculativeDurationNanoseconds: speculativeDurationNanoseconds,
            proposedDraftTokens: proposedDraftTokens,
            acceptedDraftTokens: acceptedDraftTokens,
            successfulCases: successfulCases,
            failedCases: failedCases,
            measurementEnvironmentSHA256: measurementEnvironmentSHA256 ?? digestD
        )
    }

    private func assessment(
        receipt: SpeculativeComparisonReceipt,
        policy: SpeculativeComparisonPolicy = .conservativeV1
    ) -> SpeculativeComparisonAssessment {
        SpeculativeComparisonEvaluator.evaluate(
            configuration: configuration(),
            baselineConfiguration: baseline(),
            declaration: declaration(),
            receipt: receipt,
            policy: policy
        )
    }
}
