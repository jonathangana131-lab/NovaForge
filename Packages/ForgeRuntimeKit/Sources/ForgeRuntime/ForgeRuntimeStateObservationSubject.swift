import Foundation

/// Structural failures that prevent an issued state request and a reported snapshot from forming
/// one exact observation subject.
public enum ForgeRuntimeStateObservationSubjectError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case requestMismatch
    case targetMismatch
    case sequenceMismatch
    case causalReceiptMismatch
}

/// The complete candidate subject that a canonical Runtime host must authenticate.
///
/// `ForgeRuntimeStateSnapshot` and `ForgeRuntimeStateRequest` are both public/Codable candidate
/// values. Authenticating a snapshot by itself is therefore insufficient: a caller could reuse its
/// public `requestID` with weaker predicates. This value binds the *whole issued request* to the
/// *whole reported snapshot* before any later host adapter may promote runtime-state evidence.
///
/// This type is also public/Codable and deliberately mints no authority. A decoded or caller-built
/// subject is still only candidate data. Future Playtest/Completion integration must authenticate
/// the complete `ForgeRuntimeStateObservationSubject` (or an equivalent host-owned exact mapping),
/// never a snapshot alone.
public struct ForgeRuntimeStateObservationSubject: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let request: ForgeRuntimeStateRequest
    public let snapshot: ForgeRuntimeStateSnapshot

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        request: ForgeRuntimeStateRequest,
        snapshot: ForgeRuntimeStateSnapshot
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeRuntimeStateObservationSubjectError.unsupportedSchema(schemaVersion)
        }
        guard request.requestID == snapshot.requestID else {
            throw ForgeRuntimeStateObservationSubjectError.requestMismatch
        }
        guard request.target == snapshot.target else {
            throw ForgeRuntimeStateObservationSubjectError.targetMismatch
        }
        guard request.expectedSnapshotSequence == snapshot.sequence else {
            throw ForgeRuntimeStateObservationSubjectError.sequenceMismatch
        }
        guard request.afterDeliveryReceiptID == snapshot.causalDeliveryReceiptID else {
            throw ForgeRuntimeStateObservationSubjectError.causalReceiptMismatch
        }

        self.schemaVersion = schemaVersion
        self.request = request
        self.snapshot = snapshot
    }

    /// Fresh structural evaluation of the exact request/snapshot pair retained by this subject.
    /// A `.satisfied` verdict remains candidate-only and is not evidence authentication.
    public var candidateEvaluation: ForgeRuntimeStateCandidateEvaluation {
        ForgeRuntimeStateCandidateEvaluator.evaluate(request: request, snapshot: snapshot)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, request, snapshot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            request: container.decode(ForgeRuntimeStateRequest.self, forKey: .request),
            snapshot: container.decode(ForgeRuntimeStateSnapshot.self, forKey: .snapshot)
        )
    }
}
