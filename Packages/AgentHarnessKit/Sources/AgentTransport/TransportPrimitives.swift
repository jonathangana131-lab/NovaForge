import AgentDomain
import CryptoKit
import Foundation

/// Wire compatibility for the authenticated worker channel. Major versions are
/// intentionally strict; a newer minor version is accepted only when the
/// verifier explicitly advertises support for it.
public struct AgentTransportProtocolVersion:
    Codable,
    Comparable,
    Hashable,
    Sendable
{
    public static let v1 = Self(major: 1, minor: 0)
    public static let current = Self.v1

    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public func canBeDecoded(by supported: Self = .current) -> Bool {
        major == supported.major && minor <= supported.minor
    }
}

public struct TransportPairingID:
    RawRepresentable,
    Codable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum TransportPeerRole: String, Codable, Hashable, Sendable {
    case controller
    case worker
}

public enum TransportIdentityValidationError: Error, Equatable, Sendable {
    case invalidFingerprint
    case invalidPublicKey
    case invalidGeneration
    case invalidRole
    case collidingPeers
    case publicKeyFingerprintMismatch
}

/// A domain-separated SHA-256 fingerprint of a Curve25519 signing public key.
/// Errors never retain the rejected input.
public struct TransportPublicKeyFingerprint:
    Codable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init(rawValue: String) throws {
        guard rawValue.utf8.count == 71,
              rawValue.hasPrefix("sha256:"),
              rawValue.utf8.dropFirst(7).allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              })
        else { throw TransportIdentityValidationError.invalidFingerprint }
        self.rawValue = rawValue
    }

    public init(publicKey: TransportSigningPublicKey) {
        let domain = Data("novaforge-agent-transport-public-key-v1\u{0}".utf8)
        let digest = SHA256.hash(data: domain + publicKey.rawRepresentation)
        rawValue = "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Validated Curve25519 signing public-key material. This is public information,
/// not a private key or credential.
public struct TransportSigningPublicKey: Codable, Hashable, Sendable {
    public let rawRepresentation: Data

    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32,
              (try? Curve25519.Signing.PublicKey(
                  rawRepresentation: rawRepresentation
              )) != nil
        else { throw TransportIdentityValidationError.invalidPublicKey }
        self.rawRepresentation = rawRepresentation
    }

    public init(_ publicKey: Curve25519.Signing.PublicKey) throws {
        try self.init(rawRepresentation: publicKey.rawRepresentation)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(
            rawRepresentation: decoder.singleValueContainer().decode(Data.self)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawRepresentation)
    }

    func isValidSignature(_ signature: TransportSignature, for data: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(
            rawRepresentation: rawRepresentation
        ) else { return false }
        return key.isValidSignature(signature.rawRepresentation, for: data)
    }
}

public struct TransportPeerIdentity: Codable, Equatable, Hashable, Sendable {
    public let role: TransportPeerRole
    public let executionNodeID: ExecutionNodeID
    public let publicKeyFingerprint: TransportPublicKeyFingerprint

    public init(
        role: TransportPeerRole,
        executionNodeID: ExecutionNodeID,
        publicKeyFingerprint: TransportPublicKeyFingerprint
    ) {
        self.role = role
        self.executionNodeID = executionNodeID
        self.publicKeyFingerprint = publicKeyFingerprint
    }
}

/// Immutable pairing metadata. Rotating either peer or key requires a strictly
/// newer generation and therefore a new run channel.
public struct TransportPairingIdentity: Codable, Equatable, Hashable, Sendable {
    public let protocolVersion: AgentTransportProtocolVersion
    public let pairingID: TransportPairingID
    public let generation: UInt64
    public let controller: TransportPeerIdentity
    public let worker: TransportPeerIdentity

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case pairingID
        case generation
        case controller
        case worker
    }

    public init(
        protocolVersion: AgentTransportProtocolVersion = .current,
        pairingID: TransportPairingID,
        generation: UInt64,
        controller: TransportPeerIdentity,
        worker: TransportPeerIdentity
    ) throws {
        guard protocolVersion.canBeDecoded() else {
            throw TransportContractError.unsupportedProtocolVersion
        }
        guard generation > 0 else {
            throw TransportIdentityValidationError.invalidGeneration
        }
        guard controller.role == .controller, worker.role == .worker else {
            throw TransportIdentityValidationError.invalidRole
        }
        guard controller.executionNodeID != worker.executionNodeID,
              controller.publicKeyFingerprint != worker.publicKeyFingerprint
        else { throw TransportIdentityValidationError.collidingPeers }

        self.protocolVersion = protocolVersion
        self.pairingID = pairingID
        self.generation = generation
        self.controller = controller
        self.worker = worker
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: container.decode(
                AgentTransportProtocolVersion.self,
                forKey: .protocolVersion
            ),
            pairingID: container.decode(TransportPairingID.self, forKey: .pairingID),
            generation: container.decode(UInt64.self, forKey: .generation),
            controller: container.decode(TransportPeerIdentity.self, forKey: .controller),
            worker: container.decode(TransportPeerIdentity.self, forKey: .worker)
        )
    }
}

/// Trusted public keys are supplied out-of-band and must exactly match the
/// fingerprints committed by the pairing identity.
public struct TransportPairingPublicKeys: Sendable {
    public let controller: TransportSigningPublicKey
    public let worker: TransportSigningPublicKey

    public init(
        pairing: TransportPairingIdentity,
        controller: TransportSigningPublicKey,
        worker: TransportSigningPublicKey
    ) throws {
        guard TransportPublicKeyFingerprint(publicKey: controller)
                == pairing.controller.publicKeyFingerprint,
              TransportPublicKeyFingerprint(publicKey: worker)
                == pairing.worker.publicKeyFingerprint
        else { throw TransportIdentityValidationError.publicKeyFingerprintMismatch }
        self.controller = controller
        self.worker = worker
    }
}

public enum TransportSignatureValidationError: Error, Equatable, Sendable {
    case invalidLength
}

public struct TransportSignature: Codable, Equatable, Hashable, Sendable {
    public let rawRepresentation: Data

    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 64 else {
            throw TransportSignatureValidationError.invalidLength
        }
        self.rawRepresentation = rawRepresentation
    }

    public init(from decoder: any Decoder) throws {
        try self.init(
            rawRepresentation: decoder.singleValueContainer().decode(Data.self)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawRepresentation)
    }
}

enum TransportCanonicalDomain: String, Codable, Sendable {
    case request = "worker-request-v1"
    case event = "worker-event-v1"
    case revocation = "pairing-revocation-v1"
}

enum TransportCanonicalCodec {
    static let scheme = "novaforge-agent-transport-canonical-json-v1"

    static func signingData<Value: Encodable>(
        domain: TransportCanonicalDomain,
        value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(SigningMaterial(
            scheme: scheme,
            domain: domain,
            value: value
        ))
    }

    static func signature<Value: Encodable>(
        domain: TransportCanonicalDomain,
        value: Value,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> TransportSignature {
        try TransportSignature(rawRepresentation: privateKey.signature(
            for: signingData(domain: domain, value: value)
        ))
    }
}

private struct SigningMaterial<Value: Encodable>: Encodable {
    let scheme: String
    let domain: TransportCanonicalDomain
    let value: Value
}

enum TransportSigningAuthority {
    static func validate(
        privateKey: Curve25519.Signing.PrivateKey,
        fingerprint: TransportPublicKeyFingerprint
    ) throws {
        let publicKey = try TransportSigningPublicKey(privateKey.publicKey)
        guard TransportPublicKeyFingerprint(publicKey: publicKey) == fingerprint else {
            throw TransportContractError.signerMismatch
        }
    }
}
