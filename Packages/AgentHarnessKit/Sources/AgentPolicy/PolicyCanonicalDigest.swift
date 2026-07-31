import CryptoKit
import Foundation

public enum SHA256DigestValidationError: Error, Equatable, Sendable {
    case invalidFormat(String)
}

/// A canonical lowercase SHA-256 value. Decoding always revalidates the exact
/// `sha256:` prefix and 64 lowercase ASCII hexadecimal digits.
public struct SHA256Digest:
    Codable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let prefix = "sha256:"
        guard rawValue.hasPrefix(prefix) else {
            throw SHA256DigestValidationError.invalidFormat(rawValue)
        }
        let hexadecimal = rawValue.dropFirst(prefix.count)
        guard hexadecimal.utf8.count == 64,
              hexadecimal.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              })
        else {
            throw SHA256DigestValidationError.invalidFormat(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

enum PolicyDigestDomain: String, Codable, Sendable {
    case configuration = "risk-policy-configuration-v1"
    case request = "risk-policy-request-v1"
    case grantRedemption = "policy-grant-redemption-v1"
    case targetResolutionRequest = "workspace-target-resolution-request-v1"
    case targetResolution = "workspace-target-resolution-v1"
    case targetResolutionAttestation = "workspace-target-resolution-attestation-v1"
    case approvalRegistration = "durable-approval-registration-v1"
    case approvalBinding = "durable-approval-binding-v1"
    case approvalResolution = "durable-approval-resolution-v1"
    case approvalConsumption = "durable-approval-consumption-v1"
    case toolEffectKey = "tool-effect-key-v1"
    case toolEffectClaim = "tool-effect-claim-v1"
    case policyAuthorityLedgerEnvelope = "policy-authority-ledger-envelope-v1"
    case mutationCheckpoint = "mutation-checkpoint-v1"
    case mutationApprovalPreview = "mutation-approval-preview-v1"
    case mutationBinding = "mutation-binding-v1"
    case mutationPending = "mutation-pending-v1"
    case mutationApplication = "mutation-application-v1"
    case mutationOutput = "mutation-output-v1"
    case mutationEvidence = "mutation-evidence-v1"
    case mutationReconciliation = "mutation-reconciliation-v1"
    case mutationRecord = "mutation-record-v1"
    case mutationReceipt = "mutation-receipt-v1"
    case mutationLedgerEnvelope = "mutation-ledger-envelope-v1"
}

enum PolicyCanonicalDigest {
    static let scheme = "novaforge-policy-canonical-json-v1"

    static func sha256<Value: Encodable>(
        domain: PolicyDigestDomain,
        _ value: Value
    ) throws -> SHA256Digest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(DigestEnvelope(
            scheme: scheme,
            domain: domain,
            value: value
        ))
        let hexadecimal = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return try SHA256Digest("sha256:" + hexadecimal)
    }
}

private struct DigestEnvelope<Value: Encodable>: Encodable {
    let scheme: String
    let domain: PolicyDigestDomain
    let value: Value
}
