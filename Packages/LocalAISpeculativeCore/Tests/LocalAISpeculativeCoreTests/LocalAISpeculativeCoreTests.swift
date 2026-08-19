import XCTest
@testable import LocalAISpeculativeCore

final class SpeculativeDecodingTruthTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)
    private let outputDigest = String(repeating: "c", count: 64)

    func testValidLocalDraftPairIsEligibleForTrial() {
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

    func testDraftModelRequiresDrafter() {
        let result = SpeculativeTrialValidator.evaluate(
            configuration: configuration(includeDrafter: false),
            declaration: declaration()
        )

        XCTAssertFalse(result.isEligible)
        XCTAssertEqual(result.rejections, [.missingDrafter])
    }

    func testDraftlessMechanismRejectsUnexpectedDrafter() {
        let config = SpeculativeDecodingConfiguration(
            verifier: participant(profile: "target-profile"),
            drafter: participant(profile: "draft-profile"),
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
        XCTAssertEqual(result.rejections, [.unexpectedDrafter])
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
        let config = SpeculativeDecodingConfiguration(
            verifier: participant(profile: "target-profile"),
            drafter: participant(profile: "draft-profile"),
            mechanismID: "draft-simple",
            capabilityDeclarationRevision: "source-rev-stale",
            kind: .draftModel,
            maximumDraftTokens: 4,
            contextTokens: 4_096,
            promptContractSHA256: digestB,
            privacyPolicy: .localOnly
        )

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

    func testPromotionRejectsReceiptFromDifferentConfiguration() {
        let expected = configuration()
        let observed = configuration(contextTokens: 8_192)
        let result = SpeculativePromotionEvaluator.evaluate(
            configuration: expected,
            declaration: declaration(),
            receipt: receipt(configuration: observed)
        )

        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.rejections, [.comparisonProfileMismatch])
        XCTAssertNil(result.measuredSpeedupRatio)
    }

    func testStrictPromotionRejectsOutputDivergence() {
        let result = SpeculativePromotionEvaluator.evaluate(
            configuration: configuration(),
            declaration: declaration(),
            receipt: receipt(speculativeOutputSHA256: digestA)
        )

        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.rejections, [.outputDiverged])
        XCTAssertEqual(result.measuredSpeedupRatio ?? .nan, 1.25, accuracy: 0.000_001)
    }

    func testPromotionRejectsSlowdownEvenWithPassingCases() {
        let result = SpeculativePromotionEvaluator.evaluate(
            configuration: configuration(),
            declaration: declaration(),
            receipt: receipt(
                baselineDurationNanoseconds: 800,
                speculativeDurationNanoseconds: 1_000
            )
        )

        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.rejections, [.slowerThanBaseline])
        XCTAssertEqual(result.measuredSpeedupRatio ?? .nan, 0.8, accuracy: 0.000_001)
    }

    func testPromotionRejectsObservedFailures() {
        let result = SpeculativePromotionEvaluator.evaluate(
            configuration: configuration(),
            declaration: declaration(),
            receipt: receipt(successfulCases: 3, failedCases: 1)
        )

        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.rejections, [.failuresObserved])
    }

    func testPromotionRejectsInvalidAcceptedDraftCount() {
        let result = SpeculativePromotionEvaluator.evaluate(
            configuration: configuration(),
            declaration: declaration(),
            receipt: receipt(proposedDraftTokens: 4, acceptedDraftTokens: 5)
        )

        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.rejections, [.invalidMeasurement])
        XCTAssertNil(result.measuredSpeedupRatio)
    }

    func testPromotionRejectsReceiptThatAcceptsNoDraftTokens() {
        let result = SpeculativePromotionEvaluator.evaluate(
            configuration: configuration(),
            declaration: declaration(),
            receipt: receipt(proposedDraftTokens: 4, acceptedDraftTokens: 0)
        )

        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.rejections, [.invalidMeasurement])
        XCTAssertNil(result.measuredSpeedupRatio)
    }

    func testPromotionRejectsReceiptThatNeverProposedDraftTokens() {
        let result = SpeculativePromotionEvaluator.evaluate(
            configuration: configuration(),
            declaration: declaration(),
            receipt: receipt(proposedDraftTokens: 0, acceptedDraftTokens: 0)
        )

        XCTAssertFalse(result.isPromotable)
        XCTAssertEqual(result.rejections, [.invalidMeasurement])
        XCTAssertNil(result.measuredSpeedupRatio)
    }

    func testExactMeasuredComparisonCanBecomePromotable() {
        let result = SpeculativePromotionEvaluator.evaluate(
            configuration: configuration(),
            declaration: declaration(),
            receipt: receipt()
        )

        XCTAssertTrue(result.isPromotable)
        XCTAssertTrue(result.rejections.isEmpty)
        XCTAssertEqual(result.measuredSpeedupRatio ?? .nan, 1.25, accuracy: 0.000_001)
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
        maximumDraftTokens: UInt16 = 4,
        contextTokens: UInt64 = 4_096
    ) -> SpeculativeDecodingConfiguration {
        let resolvedDrafter = includeDrafter
            ? (drafter ?? participant(profile: "draft-profile"))
            : nil

        return SpeculativeDecodingConfiguration(
            verifier: participant(profile: "target-profile"),
            drafter: resolvedDrafter,
            mechanismID: "draft-simple",
            capabilityDeclarationRevision: "source-rev-1",
            kind: .draftModel,
            maximumDraftTokens: maximumDraftTokens,
            contextTokens: contextTokens,
            promptContractSHA256: digestB,
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
        speculativeOutputSHA256: String? = nil,
        baselineDurationNanoseconds: UInt64 = 1_000,
        speculativeDurationNanoseconds: UInt64 = 800,
        proposedDraftTokens: UInt64 = 100,
        acceptedDraftTokens: UInt64 = 70,
        successfulCases: UInt32 = 3,
        failedCases: UInt32 = 0
    ) -> SpeculativeComparisonReceipt {
        SpeculativeComparisonReceipt(
            configuration: configuration ?? self.configuration(),
            workloadSuiteID: "nova-coding-smoke",
            workloadRevision: "suite-rev-1",
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
            measurementEnvironmentID: "iphone13,2-ios27-runtime-rev1"
        )
    }
}
