import Foundation

/// Speculative decoding is an optimization attempt, not a capability or performance claim.
/// These contracts make the exact trial configuration and comparison evidence explicit so
/// callers can fail closed instead of assuming a drafter/verifier pair is beneficial.
public enum SpeculativeExecutionLocality: String, Codable, CaseIterable, Hashable, Sendable {
    case onDevice
    case hosted
}

public enum SpeculativeMechanismKind: String, Codable, CaseIterable, Hashable, Sendable {
    case draftModel
    case modelNative
    case ngram
}

/// Opaque identity supplied by the canonical model-qualification/runtime layer.
/// `tokenSemanticsSHA256` must change whenever tokenizer vocabulary, special-token mapping,
/// or other token-ID semantics change in a way that could invalidate target verification.
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
/// This declaration can authorize a trial, but it can never promote a performance claim.
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

public enum SpeculativePrivacyPolicy: String, Codable, Hashable, Sendable {
    case localOnly
    case networkAllowed
}

/// Exact candidate configuration that must be preserved in every comparison receipt.
public struct SpeculativeDecodingConfiguration: Codable, Equatable, Hashable, Sendable {
    public let verifier: SpeculativeParticipantIdentity
    public let drafter: SpeculativeParticipantIdentity?
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
        self.mechanismID = mechanismID
        self.capabilityDeclarationRevision = capabilityDeclarationRevision
        self.kind = kind
        self.maximumDraftTokens = maximumDraftTokens
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
    case incompatibleTokenSemantics
    case invalidContext
    case invalidDraftLimit
    case draftLimitExceeded
    case localOnlyViolation
}

public struct SpeculativeTrialEligibility: Codable, Equatable, Sendable {
    public let isEligible: Bool
    public let rejections: [SpeculativeTrialRejection]

    public init(isEligible: Bool, rejections: [SpeculativeTrialRejection]) {
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
        if requiredStrings.contains(where: isBlank) {
            append(.incompleteIdentity, to: &rejections)
        }

        guard isCanonicalSHA256(configuration.verifier.tokenSemanticsSHA256),
              isCanonicalSHA256(configuration.promptContractSHA256)
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
                break
            }
            let drafterRequiredStrings = [
                drafter.qualificationProfileID,
                drafter.runtimeID,
                drafter.runtimeRevision,
            ]
            if drafterRequiredStrings.contains(where: isBlank) {
                append(.incompleteIdentity, to: &rejections)
            }
            if drafter.runtimeID != configuration.verifier.runtimeID
                || drafter.runtimeRevision != configuration.verifier.runtimeRevision {
                append(.drafterRuntimeMismatch, to: &rejections)
            }
            if !isCanonicalSHA256(drafter.tokenSemanticsSHA256) {
                append(.malformedFingerprint, to: &rejections)
            } else if drafter.tokenSemanticsSHA256 != configuration.verifier.tokenSemanticsSHA256 {
                append(.incompatibleTokenSemantics, to: &rejections)
            }
        case .modelNative, .ngram:
            if configuration.drafter != nil {
                append(.unexpectedDrafter, to: &rejections)
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

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

/// Exact baseline-vs-speculative observation for the same bounded workload suite.
/// Durations are wall-clock nanoseconds measured by the caller; this package does not
/// synthesize throughput or device-performance measurements.
public struct SpeculativeComparisonReceipt: Codable, Equatable, Sendable {
    public let configuration: SpeculativeDecodingConfiguration
    public let workloadSuiteID: String
    public let workloadRevision: String
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
    public let measurementEnvironmentID: String

    public init(
        configuration: SpeculativeDecodingConfiguration,
        workloadSuiteID: String,
        workloadRevision: String,
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
        measurementEnvironmentID: String
    ) {
        self.configuration = configuration
        self.workloadSuiteID = workloadSuiteID
        self.workloadRevision = workloadRevision
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
        self.measurementEnvironmentID = measurementEnvironmentID
    }
}

/// Promotion evidence is intentionally not Codable and has no public initializer.
/// A future canonical benchmark/runtime adapter in this module must authenticate the
/// comparison subject before it can construct this value. Caller-shaped or persisted
/// comparison receipts therefore remain candidate data only.
public struct SpeculativeTrustedPromotionEvidence: Equatable, Sendable {
    public let configuration: SpeculativeDecodingConfiguration
    public let declaration: SpeculativeRuntimeCapabilityDeclaration
    public let receipt: SpeculativeComparisonReceipt

    init(
        configuration: SpeculativeDecodingConfiguration,
        declaration: SpeculativeRuntimeCapabilityDeclaration,
        receipt: SpeculativeComparisonReceipt
    ) {
        self.configuration = configuration
        self.declaration = declaration
        self.receipt = receipt
    }
}

public struct SpeculativePromotionPolicy: Codable, Equatable, Sendable {
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

    public static let conservativeV1 = SpeculativePromotionPolicy()

    public var isValid: Bool {
        minimumSuccessfulCases > 0
            && minimumSpeedupRatio.isFinite
            && minimumSpeedupRatio >= 1
    }
}

public enum SpeculativePromotionRejection: String, Codable, CaseIterable, Hashable, Sendable {
    case trialIneligible
    case comparisonProfileMismatch
    case evidenceIdentityIncomplete
    case malformedOutputDigest
    case invalidMeasurement
    case invalidPolicy
    case outputDiverged
    case insufficientSuccessfulCases
    case failuresObserved
    case slowerThanBaseline
    case insufficientSpeedup
}

/// Promotion output is readable outside the module but cannot be decoded or directly minted.
public struct SpeculativePromotionResult: Equatable, Sendable {
    public let isPromotable: Bool
    public let rejections: [SpeculativePromotionRejection]
    public let measuredSpeedupRatio: Double?

    init(
        isPromotable: Bool,
        rejections: [SpeculativePromotionRejection],
        measuredSpeedupRatio: Double?
    ) {
        self.isPromotable = isPromotable
        self.rejections = rejections
        self.measuredSpeedupRatio = measuredSpeedupRatio
    }
}

public enum SpeculativePromotionEvaluator {
    /// Public promotion authority consumes only module-owned trusted evidence and uses the
    /// package-owned conservative policy. Ordinary callers cannot lower the threshold or
    /// turn a Codable comparison receipt into promotion evidence.
    public static func evaluate(
        evidence: SpeculativeTrustedPromotionEvidence
    ) -> SpeculativePromotionResult {
        evaluate(
            configuration: evidence.configuration,
            declaration: evidence.declaration,
            receipt: evidence.receipt,
            policy: .conservativeV1
        )
    }

    /// Package-internal structural evaluator retained for exhaustive contract tests and for
    /// the future canonical evidence producer. It is deliberately unavailable to ordinary
    /// package consumers because all of its inputs are caller-shaped candidate values.
    static func evaluate(
        configuration: SpeculativeDecodingConfiguration,
        declaration: SpeculativeRuntimeCapabilityDeclaration,
        receipt: SpeculativeComparisonReceipt,
        policy: SpeculativePromotionPolicy = .conservativeV1
    ) -> SpeculativePromotionResult {
        let trial = SpeculativeTrialValidator.evaluate(
            configuration: configuration,
            declaration: declaration
        )
        guard trial.isEligible else {
            return .init(
                isPromotable: false,
                rejections: [.trialIneligible],
                measuredSpeedupRatio: nil
            )
        }

        guard receipt.configuration == configuration else {
            return .init(
                isPromotable: false,
                rejections: [.comparisonProfileMismatch],
                measuredSpeedupRatio: nil
            )
        }

        let requiredReceiptStrings = [
            receipt.workloadSuiteID,
            receipt.workloadRevision,
            receipt.baselineRunID,
            receipt.speculativeRunID,
            receipt.measurementEnvironmentID,
        ]
        guard !requiredReceiptStrings.contains(where: isBlank) else {
            return .init(
                isPromotable: false,
                rejections: [.evidenceIdentityIncomplete],
                measuredSpeedupRatio: nil
            )
        }

        guard isCanonicalSHA256(receipt.baselineOutputSHA256),
              isCanonicalSHA256(receipt.speculativeOutputSHA256)
        else {
            return .init(
                isPromotable: false,
                rejections: [.malformedOutputDigest],
                measuredSpeedupRatio: nil
            )
        }

        guard receipt.baselineDurationNanoseconds > 0,
              receipt.speculativeDurationNanoseconds > 0,
              receipt.proposedDraftTokens > 0,
              receipt.acceptedDraftTokens > 0,
              receipt.acceptedDraftTokens <= receipt.proposedDraftTokens,
              receipt.baselineRunID != receipt.speculativeRunID,
              receipt.successfulCases > 0 || receipt.failedCases > 0
        else {
            return .init(
                isPromotable: false,
                rejections: [.invalidMeasurement],
                measuredSpeedupRatio: nil
            )
        }

        guard policy.isValid else {
            return .init(
                isPromotable: false,
                rejections: [.invalidPolicy],
                measuredSpeedupRatio: nil
            )
        }

        var rejections: [SpeculativePromotionRejection] = []
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
            isPromotable: rejections.isEmpty,
            rejections: rejections,
            measuredSpeedupRatio: speedupRatio
        )
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}
