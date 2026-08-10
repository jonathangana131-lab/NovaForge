import Foundation

/// Speculative decoding is an optimization experiment, not a capability, support, routing,
/// qualification, or performance claim. This package can identify a bounded latency candidate;
/// product promotion must be decided later by non-mintable qualification/benchmark/resource truth.
public enum SpeculativeExecutionLocality: String, Codable, CaseIterable, Hashable, Sendable {
    case onDevice
    case hosted
}

public enum SpeculativeMechanismKind: String, Codable, CaseIterable, Hashable, Sendable {
    case draftModel
    case modelNative
    case ngram
}

public enum SpeculativePrivacyPolicy: String, Codable, Hashable, Sendable {
    case localOnly
    case networkAllowed
}

private enum SpeculativeValidation {
    static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isBoundedText(_ value: String, maximumUTF8Bytes: Int = 192) -> Bool {
        let bytes = value.utf8
        return !isBlank(value)
            && bytes.count <= maximumUTF8Bytes
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

/// Opaque candidate identity supplied by a future canonical model-qualification/runtime adapter.
/// The fields are intentionally not treated as proof by this package because ordinary callers can
/// construct them. `tokenSemanticsSHA256` must change when token-ID semantics change.
public struct SpeculativeParticipantIdentity: Codable, Equatable, Hashable, Sendable {
    public let qualificationProfileID: String
    public let runtimeID: String
    public let runtimeRevision: String
    public let tokenSemanticsSHA256: String
    public let executionLocality: SpeculativeExecutionLocality

    public init(
        qualificationProfileID: String,
        runtimeID: String,
        runtimeRevision: String,
        tokenSemanticsSHA256: String,
        executionLocality: SpeculativeExecutionLocality
    ) {
        self.qualificationProfileID = qualificationProfileID
        self.runtimeID = runtimeID
        self.runtimeRevision = runtimeRevision
        self.tokenSemanticsSHA256 = tokenSemanticsSHA256
        self.executionLocality = executionLocality
    }
}

/// Source/runtime-declared ability to attempt one speculative mechanism.
/// This is candidate metadata only and can never authorize runtime use or a product performance claim.
public struct SpeculativeRuntimeCapabilityDeclaration: Codable, Equatable, Hashable, Sendable {
    public let runtimeID: String
    public let runtimeRevision: String
    public let mechanismID: String
    public let kind: SpeculativeMechanismKind
    public let maximumDraftTokens: UInt16
    public let declarationRevision: String

    public init(
        runtimeID: String,
        runtimeRevision: String,
        mechanismID: String,
        kind: SpeculativeMechanismKind,
        maximumDraftTokens: UInt16,
        declarationRevision: String
    ) {
        self.runtimeID = runtimeID
        self.runtimeRevision = runtimeRevision
        self.mechanismID = mechanismID
        self.kind = kind
        self.maximumDraftTokens = maximumDraftTokens
        self.declarationRevision = declarationRevision
    }
}

/// Exact candidate speculative execution configuration.
/// Runtime configuration digests are opaque hashes over the host's canonical execution descriptor;
/// this domain deliberately does not duplicate backend-specific flags owned by the runtime layer.
public struct SpeculativeDecodingConfiguration: Codable, Equatable, Hashable, Sendable {
    public let verifier: SpeculativeParticipantIdentity
    public let drafter: SpeculativeParticipantIdentity?
    public let verifierRuntimeConfigurationSHA256: String
    public let drafterRuntimeConfigurationSHA256: String?
    public let mechanismID: String
    public let capabilityDeclarationRevision: String
    public let kind: SpeculativeMechanismKind
    public let maximumDraftTokens: UInt16
    public let contextTokens: UInt64
    public let promptContractSHA256: String
    public let privacyPolicy: SpeculativePrivacyPolicy

    public init(
        verifier: SpeculativeParticipantIdentity,
        drafter: SpeculativeParticipantIdentity?,
        verifierRuntimeConfigurationSHA256: String,
        drafterRuntimeConfigurationSHA256: String?,
        mechanismID: String,
        capabilityDeclarationRevision: String,
        kind: SpeculativeMechanismKind,
        maximumDraftTokens: UInt16,
        contextTokens: UInt64,
        promptContractSHA256: String,
        privacyPolicy: SpeculativePrivacyPolicy
    ) {
        self.verifier = verifier
        self.drafter = drafter
        self.verifierRuntimeConfigurationSHA256 = verifierRuntimeConfigurationSHA256
        self.drafterRuntimeConfigurationSHA256 = drafterRuntimeConfigurationSHA256
        self.mechanismID = mechanismID
        self.capabilityDeclarationRevision = capabilityDeclarationRevision
        self.kind = kind
        self.maximumDraftTokens = maximumDraftTokens
        self.contextTokens = contextTokens
        self.promptContractSHA256 = promptContractSHA256
        self.privacyPolicy = privacyPolicy
    }
}

/// Exact non-speculative verifier execution expected for the comparison baseline.
public struct SpeculativeBaselineConfiguration: Codable, Equatable, Hashable, Sendable {
    public let verifier: SpeculativeParticipantIdentity
    public let verifierRuntimeConfigurationSHA256: String
    public let contextTokens: UInt64
    public let promptContractSHA256: String
    public let privacyPolicy: SpeculativePrivacyPolicy

    public init(
        verifier: SpeculativeParticipantIdentity,
        verifierRuntimeConfigurationSHA256: String,
        contextTokens: UInt64,
        promptContractSHA256: String,
        privacyPolicy: SpeculativePrivacyPolicy
    ) {
        self.verifier = verifier
        self.verifierRuntimeConfigurationSHA256 = verifierRuntimeConfigurationSHA256
        self.contextTokens = contextTokens
        self.promptContractSHA256 = promptContractSHA256
        self.privacyPolicy = privacyPolicy
    }
}

public enum SpeculativeTrialRejection: String, Codable, CaseIterable, Hashable, Sendable {
    case incompleteIdentity
    case malformedFingerprint
    case runtimeMismatch
    case drafterRuntimeMismatch
    case mechanismMismatch
    case declarationRevisionMismatch
    case missingDrafter
    case unexpectedDrafter
    case missingDrafterRuntimeConfiguration
    case unexpectedDrafterRuntimeConfiguration
    case incompatibleTokenSemantics
    case invalidContext
    case invalidDraftLimit
    case draftLimitExceeded
    case localOnlyViolation
}

/// Derived structural assessment only. It is intentionally non-Codable and has no public initializer.
/// A true result means the candidate is well-shaped enough for a host-authorized experiment; it does
/// not authorize execution by itself.
public struct SpeculativeTrialEligibility: Equatable, Sendable {
    public let isEligible: Bool
    public let rejections: [SpeculativeTrialRejection]

    fileprivate init(isEligible: Bool, rejections: [SpeculativeTrialRejection]) {
        self.isEligible = isEligible
        self.rejections = rejections
    }
}

public enum SpeculativeTrialValidator {
    public static func evaluate(
        configuration: SpeculativeDecodingConfiguration,
        declaration: SpeculativeRuntimeCapabilityDeclaration
    ) -> SpeculativeTrialEligibility {
        var rejections: [SpeculativeTrialRejection] = []

        let requiredStrings = [
            configuration.verifier.qualificationProfileID,
            configuration.verifier.runtimeID,
            configuration.verifier.runtimeRevision,
            configuration.mechanismID,
            configuration.capabilityDeclarationRevision,
            declaration.runtimeID,
            declaration.runtimeRevision,
            declaration.mechanismID,
            declaration.declarationRevision,
        ]
        if requiredStrings.contains(where: { !SpeculativeValidation.isBoundedText($0) }) {
            append(.incompleteIdentity, to: &rejections)
        }

        guard SpeculativeValidation.isCanonicalSHA256(configuration.verifier.tokenSemanticsSHA256),
              SpeculativeValidation.isCanonicalSHA256(configuration.promptContractSHA256),
              SpeculativeValidation.isCanonicalSHA256(configuration.verifierRuntimeConfigurationSHA256)
        else {
            append(.malformedFingerprint, to: &rejections)
            return .init(isEligible: false, rejections: rejections)
        }

        if configuration.verifier.runtimeID != declaration.runtimeID
            || configuration.verifier.runtimeRevision != declaration.runtimeRevision {
            append(.runtimeMismatch, to: &rejections)
        }

        if configuration.mechanismID != declaration.mechanismID
            || configuration.kind != declaration.kind {
            append(.mechanismMismatch, to: &rejections)
        }

        if configuration.capabilityDeclarationRevision != declaration.declarationRevision {
            append(.declarationRevisionMismatch, to: &rejections)
        }

        if configuration.contextTokens == 0 {
            append(.invalidContext, to: &rejections)
        }

        if configuration.maximumDraftTokens == 0 || declaration.maximumDraftTokens == 0 {
            append(.invalidDraftLimit, to: &rejections)
        } else if configuration.maximumDraftTokens > declaration.maximumDraftTokens {
            append(.draftLimitExceeded, to: &rejections)
        }

        switch configuration.kind {
        case .draftModel:
            guard let drafter = configuration.drafter else {
                append(.missingDrafter, to: &rejections)
                if configuration.drafterRuntimeConfigurationSHA256 != nil {
                    append(.unexpectedDrafterRuntimeConfiguration, to: &rejections)
                }
                break
            }
            let drafterRequiredStrings = [
                drafter.qualificationProfileID,
                drafter.runtimeID,
                drafter.runtimeRevision,
            ]
            if drafterRequiredStrings.contains(where: { !SpeculativeValidation.isBoundedText($0) }) {
                append(.incompleteIdentity, to: &rejections)
            }
            if drafter.runtimeID != configuration.verifier.runtimeID
                || drafter.runtimeRevision != configuration.verifier.runtimeRevision {
                append(.drafterRuntimeMismatch, to: &rejections)
            }
            if !SpeculativeValidation.isCanonicalSHA256(drafter.tokenSemanticsSHA256) {
                append(.malformedFingerprint, to: &rejections)
            } else if drafter.tokenSemanticsSHA256 != configuration.verifier.tokenSemanticsSHA256 {
                append(.incompatibleTokenSemantics, to: &rejections)
            }
            guard let drafterRuntimeConfigurationSHA256 = configuration.drafterRuntimeConfigurationSHA256 else {
                append(.missingDrafterRuntimeConfiguration, to: &rejections)
                break
            }
            if !SpeculativeValidation.isCanonicalSHA256(drafterRuntimeConfigurationSHA256) {
                append(.malformedFingerprint, to: &rejections)
            }

        case .modelNative, .ngram:
            if configuration.drafter != nil {
                append(.unexpectedDrafter, to: &rejections)
            }
            if configuration.drafterRuntimeConfigurationSHA256 != nil {
                append(.unexpectedDrafterRuntimeConfiguration, to: &rejections)
            }
        }

        if configuration.privacyPolicy == .localOnly {
            if configuration.verifier.executionLocality != .onDevice
                || configuration.drafter?.executionLocality == .hosted {
                append(.localOnlyViolation, to: &rejections)
            }
        }

        return .init(isEligible: rejections.isEmpty, rejections: rejections)
    }

    private static func append(
        _ rejection: SpeculativeTrialRejection,
        to rejections: inout [SpeculativeTrialRejection]
    ) {
        if !rejections.contains(rejection) {
            rejections.append(rejection)
        }
    }
}

/// Baseline-vs-speculative candidate observation for the same bounded workload.
/// Every field is still caller-supplied candidate evidence. `measurementEnvironmentSHA256` is an
/// opaque digest over a host-owned environment descriptor; this package does not interpret it as
/// physical-device qualification. `workloadManifestSHA256` binds the exact compared case set but is
/// not a substitute for the canonical Local AI benchmark authority.
public struct SpeculativeComparisonReceipt: Codable, Equatable, Sendable {
    public let configuration: SpeculativeDecodingConfiguration
    public let baselineConfiguration: SpeculativeBaselineConfiguration
    public let workloadSuiteID: String
    public let workloadRevision: String
    public let workloadManifestSHA256: String
    public let baselineRunID: String
    public let speculativeRunID: String
    public let baselineOutputSHA256: String
    public let speculativeOutputSHA256: String
    public let baselineDurationNanoseconds: UInt64
    public let speculativeDurationNanoseconds: UInt64
    public let proposedDraftTokens: UInt64
    public let acceptedDraftTokens: UInt64
    public let successfulCases: UInt32
    public let failedCases: UInt32
    public let measurementEnvironmentSHA256: String

    public init(
        configuration: SpeculativeDecodingConfiguration,
        baselineConfiguration: SpeculativeBaselineConfiguration,
        workloadSuiteID: String,
        workloadRevision: String,
        workloadManifestSHA256: String,
        baselineRunID: String,
        speculativeRunID: String,
        baselineOutputSHA256: String,
        speculativeOutputSHA256: String,
        baselineDurationNanoseconds: UInt64,
        speculativeDurationNanoseconds: UInt64,
        proposedDraftTokens: UInt64,
        acceptedDraftTokens: UInt64,
        successfulCases: UInt32,
        failedCases: UInt32,
        measurementEnvironmentSHA256: String
    ) {
        self.configuration = configuration
        self.baselineConfiguration = baselineConfiguration
        self.workloadSuiteID = workloadSuiteID
        self.workloadRevision = workloadRevision
        self.workloadManifestSHA256 = workloadManifestSHA256
        self.baselineRunID = baselineRunID
        self.speculativeRunID = speculativeRunID
        self.baselineOutputSHA256 = baselineOutputSHA256
        self.speculativeOutputSHA256 = speculativeOutputSHA256
        self.baselineDurationNanoseconds = baselineDurationNanoseconds
        self.speculativeDurationNanoseconds = speculativeDurationNanoseconds
        self.proposedDraftTokens = proposedDraftTokens
        self.acceptedDraftTokens = acceptedDraftTokens
        self.successfulCases = successfulCases
        self.failedCases = failedCases
        self.measurementEnvironmentSHA256 = measurementEnvironmentSHA256
    }
}

/// Research-only latency comparison policy. Callers may make experiments stricter or looser, but
/// no choice of this public policy can create product promotion authority.
public struct SpeculativeComparisonPolicy: Codable, Equatable, Sendable {
    public let minimumSuccessfulCases: UInt32
    public let maximumFailedCases: UInt32
    public let minimumSpeedupRatio: Double
    public let requiresExactOutputParity: Bool

    public init(
        minimumSuccessfulCases: UInt32 = 3,
        maximumFailedCases: UInt32 = 0,
        minimumSpeedupRatio: Double = 1.05,
        requiresExactOutputParity: Bool = true
    ) {
        self.minimumSuccessfulCases = minimumSuccessfulCases
        self.maximumFailedCases = maximumFailedCases
        self.minimumSpeedupRatio = minimumSpeedupRatio
        self.requiresExactOutputParity = requiresExactOutputParity
    }

    public static let conservativeV1 = SpeculativeComparisonPolicy()

    public var isValid: Bool {
        minimumSuccessfulCases > 0
            && minimumSpeedupRatio.isFinite
            && minimumSpeedupRatio >= 1
    }
}

public enum SpeculativeComparisonRejection: String, Codable, CaseIterable, Hashable, Sendable {
    case trialIneligible
    case comparisonProfileMismatch
    case baselineProfileMismatch
    case evidenceIdentityIncomplete
    case malformedFingerprint
    case invalidMeasurement
    case invalidPolicy
    case outputDiverged
    case insufficientSuccessfulCases
    case failuresObserved
    case slowerThanBaseline
    case insufficientSpeedup
}

public enum SpeculativeAssessmentAuthority: String, Sendable {
    /// A bounded research observation only. Never authorizes routing, qualification, badges, or support.
    case researchLatencyCandidateOnly
}

/// Derived, transient research assessment. It is intentionally non-Codable and cannot be publicly
/// initialized. Even a fully passing assessment is never product-promotable in this package.
public struct SpeculativeComparisonAssessment: Equatable, Sendable {
    public let isLatencyCandidate: Bool
    public let rejections: [SpeculativeComparisonRejection]
    public let measuredSpeedupRatio: Double?
    public let authority: SpeculativeAssessmentAuthority

    /// Compatibility guard for any pre-repair caller that still checks promotion semantics.
    /// This package no longer has enough authority to promote speculative decoding.
    public var isPromotable: Bool { false }

    fileprivate init(
        isLatencyCandidate: Bool,
        rejections: [SpeculativeComparisonRejection],
        measuredSpeedupRatio: Double?
    ) {
        self.isLatencyCandidate = isLatencyCandidate
        self.rejections = rejections
        self.measuredSpeedupRatio = measuredSpeedupRatio
        self.authority = .researchLatencyCandidateOnly
    }
}

public enum SpeculativeComparisonEvaluator {
    public static func evaluate(
        configuration: SpeculativeDecodingConfiguration,
        baselineConfiguration: SpeculativeBaselineConfiguration,
        declaration: SpeculativeRuntimeCapabilityDeclaration,
        receipt: SpeculativeComparisonReceipt,
        policy: SpeculativeComparisonPolicy = .conservativeV1
    ) -> SpeculativeComparisonAssessment {
        let trial = SpeculativeTrialValidator.evaluate(
            configuration: configuration,
            declaration: declaration
        )
        guard trial.isEligible else {
            return .init(
                isLatencyCandidate: false,
                rejections: [.trialIneligible],
                measuredSpeedupRatio: nil
            )
        }

        guard receipt.configuration == configuration else {
            return .init(
                isLatencyCandidate: false,
                rejections: [.comparisonProfileMismatch],
                measuredSpeedupRatio: nil
            )
        }

        guard receipt.baselineConfiguration == baselineConfiguration,
              baselineMatchesCandidateWorkload(
                baselineConfiguration,
                candidate: configuration
              )
        else {
            return .init(
                isLatencyCandidate: false,
                rejections: [.baselineProfileMismatch],
                measuredSpeedupRatio: nil
            )
        }

        let requiredReceiptStrings = [
            receipt.workloadSuiteID,
            receipt.workloadRevision,
            receipt.baselineRunID,
            receipt.speculativeRunID,
        ]
        guard requiredReceiptStrings.allSatisfy({ SpeculativeValidation.isBoundedText($0) }) else {
            return .init(
                isLatencyCandidate: false,
                rejections: [.evidenceIdentityIncomplete],
                measuredSpeedupRatio: nil
            )
        }

        guard SpeculativeValidation.isCanonicalSHA256(receipt.workloadManifestSHA256),
              SpeculativeValidation.isCanonicalSHA256(receipt.measurementEnvironmentSHA256),
              SpeculativeValidation.isCanonicalSHA256(receipt.baselineOutputSHA256),
              SpeculativeValidation.isCanonicalSHA256(receipt.speculativeOutputSHA256),
              SpeculativeValidation.isCanonicalSHA256(baselineConfiguration.verifierRuntimeConfigurationSHA256),
              SpeculativeValidation.isCanonicalSHA256(baselineConfiguration.promptContractSHA256),
              SpeculativeValidation.isCanonicalSHA256(baselineConfiguration.verifier.tokenSemanticsSHA256)
        else {
            return .init(
                isLatencyCandidate: false,
                rejections: [.malformedFingerprint],
                measuredSpeedupRatio: nil
            )
        }

        guard baselineConfiguration.contextTokens > 0,
              receipt.baselineDurationNanoseconds > 0,
              receipt.speculativeDurationNanoseconds > 0,
              receipt.proposedDraftTokens > 0,
              receipt.acceptedDraftTokens <= receipt.proposedDraftTokens,
              receipt.baselineRunID != receipt.speculativeRunID,
              receipt.successfulCases > 0 || receipt.failedCases > 0
        else {
            return .init(
                isLatencyCandidate: false,
                rejections: [.invalidMeasurement],
                measuredSpeedupRatio: nil
            )
        }

        guard policy.isValid else {
            return .init(
                isLatencyCandidate: false,
                rejections: [.invalidPolicy],
                measuredSpeedupRatio: nil
            )
        }

        var rejections: [SpeculativeComparisonRejection] = []
        if policy.requiresExactOutputParity,
           receipt.baselineOutputSHA256 != receipt.speculativeOutputSHA256 {
            rejections.append(.outputDiverged)
        }
        if receipt.successfulCases < policy.minimumSuccessfulCases {
            rejections.append(.insufficientSuccessfulCases)
        }
        if receipt.failedCases > policy.maximumFailedCases {
            rejections.append(.failuresObserved)
        }

        let speedupRatio = Double(receipt.baselineDurationNanoseconds)
            / Double(receipt.speculativeDurationNanoseconds)
        if speedupRatio < 1 {
            rejections.append(.slowerThanBaseline)
        } else if speedupRatio < policy.minimumSpeedupRatio {
            rejections.append(.insufficientSpeedup)
        }

        return .init(
            isLatencyCandidate: rejections.isEmpty,
            rejections: rejections,
            measuredSpeedupRatio: speedupRatio
        )
    }

    private static func baselineMatchesCandidateWorkload(
        _ baseline: SpeculativeBaselineConfiguration,
        candidate: SpeculativeDecodingConfiguration
    ) -> Bool {
        baseline.verifier == candidate.verifier
            && baseline.contextTokens == candidate.contextTokens
            && baseline.promptContractSHA256 == candidate.promptContractSHA256
            && baseline.privacyPolicy == candidate.privacyPolicy
    }
}

/// Compatibility aliases keep source-level migration small while deliberately removing the old
/// authority semantics. `SpeculativePromotionResult.isPromotable` is always false.
public typealias SpeculativePromotionPolicy = SpeculativeComparisonPolicy
public typealias SpeculativePromotionRejection = SpeculativeComparisonRejection
public typealias SpeculativePromotionResult = SpeculativeComparisonAssessment

public enum SpeculativePromotionEvaluator {
    public static func evaluate(
        configuration: SpeculativeDecodingConfiguration,
        baselineConfiguration: SpeculativeBaselineConfiguration,
        declaration: SpeculativeRuntimeCapabilityDeclaration,
        receipt: SpeculativeComparisonReceipt,
        policy: SpeculativeComparisonPolicy = .conservativeV1
    ) -> SpeculativeComparisonAssessment {
        SpeculativeComparisonEvaluator.evaluate(
            configuration: configuration,
            baselineConfiguration: baselineConfiguration,
            declaration: declaration,
            receipt: receipt,
            policy: policy
        )
    }
}
