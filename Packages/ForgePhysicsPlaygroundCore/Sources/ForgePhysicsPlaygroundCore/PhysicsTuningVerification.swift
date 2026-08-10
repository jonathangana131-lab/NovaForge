import Foundation

/// Caller-provided evidence that a downstream mutation path has been followed by a fresh
/// observation. The authority verifies coherence; it does not independently attest the host's
/// `evidenceID` or turn Simulator evidence into physical-device proof.
public struct PhysicsTuningPostconditionObservation: Codable, Hashable, Sendable {
    public let requestID: String
    public let sourceProjectRevision: PhysicsProjectRevision
    public let resultProjectRevision: PhysicsProjectRevision
    public let targetID: String
    public let catalogRevision: String
    public let parameterID: String
    public let source: PhysicsSnapshotSource
    public let evidenceID: String
    public let observedValue: Double

    public init(
        requestID: String,
        sourceProjectRevision: PhysicsProjectRevision,
        resultProjectRevision: PhysicsProjectRevision,
        targetID: String,
        catalogRevision: String,
        parameterID: String,
        source: PhysicsSnapshotSource,
        evidenceID: String,
        observedValue: Double
    ) throws {
        self.requestID = try PhysicsOpaqueID.validating(requestID, field: "requestID")
        self.sourceProjectRevision = sourceProjectRevision
        self.resultProjectRevision = resultProjectRevision
        self.targetID = try PhysicsOpaqueID.validating(targetID, field: "targetID")
        self.catalogRevision = try PhysicsOpaqueID.validating(catalogRevision, field: "catalogRevision")
        self.parameterID = try PhysicsOpaqueID.validating(parameterID, field: "parameterID")
        self.source = source
        self.evidenceID = try PhysicsOpaqueID.validating(evidenceID, field: "evidenceID")
        guard observedValue.isFinite else {
            throw PhysicsTuningPostconditionValidationError.nonFiniteObservedValue(
                parameterID: self.parameterID,
                value: observedValue
            )
        }
        self.observedValue = observedValue
    }
}

public enum PhysicsTuningPostconditionValidationError: Error, Equatable, Sendable {
    case nonFiniteObservedValue(parameterID: String, value: Double)
}

/// Coherence receipt emitted only after a commit authorization is matched to a fresh observed
/// postcondition. This proves the values/identities supplied to this package agree; it is not a
/// cryptographic or device attestation of the underlying evidence.
public struct PhysicsTuningVerificationReceipt: Codable, Hashable, Sendable {
    public let authorization: PhysicsTuningAuthorization
    public let resultProjectRevision: PhysicsProjectRevision
    public let verificationSource: PhysicsSnapshotSource
    public let verificationEvidenceID: String
    public let observedValue: Double

    public var postconditionObserved: Bool { true }
    public var runtimePostconditionObserved: Bool { verificationSource == .runtimeObservation }
}

public enum PhysicsTuningVerificationRejection: Error, Equatable, Sendable {
    case previewCannotProduceCommitReceipt
    case requestMismatch
    case sourceProjectRevisionMismatch
    case resultProjectMismatch
    case targetMismatch
    case catalogRevisionMismatch
    case parameterMismatch
    case observedValueMismatch(expected: Double, observed: Double)
}

public extension PhysicsTuningAuthority {
    static func verifyPostcondition(
        for authorization: PhysicsTuningAuthorization,
        observation: PhysicsTuningPostconditionObservation
    ) throws -> PhysicsTuningVerificationReceipt {
        guard authorization.operation == .commit,
              authorization.effect == .runtimeMutationRequired else {
            throw PhysicsTuningVerificationRejection.previewCannotProduceCommitReceipt
        }
        guard observation.requestID == authorization.requestID else {
            throw PhysicsTuningVerificationRejection.requestMismatch
        }
        guard observation.sourceProjectRevision == authorization.projectRevision else {
            throw PhysicsTuningVerificationRejection.sourceProjectRevisionMismatch
        }
        guard observation.resultProjectRevision.projectID == authorization.projectRevision.projectID else {
            throw PhysicsTuningVerificationRejection.resultProjectMismatch
        }
        guard observation.targetID == authorization.targetID else {
            throw PhysicsTuningVerificationRejection.targetMismatch
        }
        guard observation.catalogRevision == authorization.catalogRevision else {
            throw PhysicsTuningVerificationRejection.catalogRevisionMismatch
        }
        guard observation.parameterID == authorization.parameterID else {
            throw PhysicsTuningVerificationRejection.parameterMismatch
        }
        guard observation.observedValue == authorization.proposedValue else {
            throw PhysicsTuningVerificationRejection.observedValueMismatch(
                expected: authorization.proposedValue,
                observed: observation.observedValue
            )
        }

        return PhysicsTuningVerificationReceipt(
            authorization: authorization,
            resultProjectRevision: observation.resultProjectRevision,
            verificationSource: observation.source,
            verificationEvidenceID: observation.evidenceID,
            observedValue: observation.observedValue
        )
    }
}
