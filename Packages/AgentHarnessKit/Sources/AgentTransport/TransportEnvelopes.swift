import AgentDomain
import CryptoKit
import Foundation

public enum TransportContractError: Error, Equatable, Sendable {
    case unsupportedProtocolVersion
    case invalidPairing
    case invalidSequence
    case invalidCursor
    case signerMismatch
    case signatureInvalid
    case runMismatch
    case ownershipMismatch
    case pairingRevoked
    case duplicateRequest(sequence: UInt64)
    case requestGap(expected: UInt64, received: UInt64)
    case duplicateEvent(sequence: UInt64)
    case eventGap(expected: UInt64, received: UInt64)
    case acknowledgementRegression(previous: UInt64, received: UInt64)
    case acknowledgementAhead(maximum: UInt64, received: UInt64)
    case replayWindowExceeded(earliestAvailable: UInt64)
    case replayEventTooLarge(maximum: Int, actual: Int)
    case sequenceExhausted
    case duplicateRevocation
    case invalidRevocation
}

public struct TransportMessageSequence:
    Codable,
    Comparable,
    Hashable,
    Sendable
{
    public static let first = try! Self(rawValue: 1)

    public let rawValue: UInt64

    public init(rawValue: UInt64) throws {
        guard rawValue > 0 else { throw TransportContractError.invalidSequence }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(UInt64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The last event durably accepted by the controller. Zero means the origin
/// before event sequence one.
public struct TransportReconnectCursor: Codable, Equatable, Hashable, Sendable {
    public let protocolVersion: AgentTransportProtocolVersion
    public let pairingID: TransportPairingID
    public let pairingGeneration: UInt64
    public let runID: RunID
    public let executionNodeID: ExecutionNodeID
    public let lastAcceptedEventSequence: UInt64

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case pairingID
        case pairingGeneration
        case runID
        case executionNodeID
        case lastAcceptedEventSequence
    }

    public init(
        protocolVersion: AgentTransportProtocolVersion = .current,
        pairingID: TransportPairingID,
        pairingGeneration: UInt64,
        runID: RunID,
        executionNodeID: ExecutionNodeID,
        lastAcceptedEventSequence: UInt64
    ) throws {
        guard protocolVersion.canBeDecoded() else {
            throw TransportContractError.unsupportedProtocolVersion
        }
        guard pairingGeneration > 0 else {
            throw TransportContractError.invalidCursor
        }
        self.protocolVersion = protocolVersion
        self.pairingID = pairingID
        self.pairingGeneration = pairingGeneration
        self.runID = runID
        self.executionNodeID = executionNodeID
        self.lastAcceptedEventSequence = lastAcceptedEventSequence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: container.decode(
                AgentTransportProtocolVersion.self,
                forKey: .protocolVersion
            ),
            pairingID: container.decode(TransportPairingID.self, forKey: .pairingID),
            pairingGeneration: container.decode(UInt64.self, forKey: .pairingGeneration),
            runID: container.decode(RunID.self, forKey: .runID),
            executionNodeID: container.decode(
                ExecutionNodeID.self,
                forKey: .executionNodeID
            ),
            lastAcceptedEventSequence: container.decode(
                UInt64.self,
                forKey: .lastAcceptedEventSequence
            )
        )
    }

    public static func origin(
        pairing: TransportPairingIdentity,
        runID: RunID
    ) throws -> Self {
        try Self(
            protocolVersion: pairing.protocolVersion,
            pairingID: pairing.pairingID,
            pairingGeneration: pairing.generation,
            runID: runID,
            executionNodeID: pairing.worker.executionNodeID,
            lastAcceptedEventSequence: 0
        )
    }
}

public struct WorkerRequestEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: AgentTransportProtocolVersion
    public let pairingID: TransportPairingID
    public let pairingGeneration: UInt64
    public let runID: RunID
    public let commandID: CommandID
    public let executionNodeID: ExecutionNodeID
    public let signer: TransportPublicKeyFingerprint
    public let sequence: TransportMessageSequence
    public let reconnectCursor: TransportReconnectCursor
    public let issuedAt: AgentInstant
    public let payload: BoundedTransportPayload
    public let signature: TransportSignature

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case pairingID
        case pairingGeneration
        case runID
        case commandID
        case executionNodeID
        case signer
        case sequence
        case reconnectCursor
        case issuedAt
        case payload
        case signature
    }

    public init(
        protocolVersion: AgentTransportProtocolVersion = .current,
        pairingID: TransportPairingID,
        pairingGeneration: UInt64,
        runID: RunID,
        commandID: CommandID,
        executionNodeID: ExecutionNodeID,
        signer: TransportPublicKeyFingerprint,
        sequence: TransportMessageSequence,
        reconnectCursor: TransportReconnectCursor,
        issuedAt: AgentInstant,
        payload: BoundedTransportPayload,
        signature: TransportSignature
    ) throws {
        guard protocolVersion.canBeDecoded() else {
            throw TransportContractError.unsupportedProtocolVersion
        }
        guard pairingGeneration > 0 else {
            throw TransportContractError.invalidPairing
        }
        try payload.validate()
        self.protocolVersion = protocolVersion
        self.pairingID = pairingID
        self.pairingGeneration = pairingGeneration
        self.runID = runID
        self.commandID = commandID
        self.executionNodeID = executionNodeID
        self.signer = signer
        self.sequence = sequence
        self.reconnectCursor = reconnectCursor
        self.issuedAt = issuedAt
        self.payload = payload
        self.signature = signature
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: container.decode(
                AgentTransportProtocolVersion.self,
                forKey: .protocolVersion
            ),
            pairingID: container.decode(TransportPairingID.self, forKey: .pairingID),
            pairingGeneration: container.decode(UInt64.self, forKey: .pairingGeneration),
            runID: container.decode(RunID.self, forKey: .runID),
            commandID: container.decode(CommandID.self, forKey: .commandID),
            executionNodeID: container.decode(
                ExecutionNodeID.self,
                forKey: .executionNodeID
            ),
            signer: container.decode(
                TransportPublicKeyFingerprint.self,
                forKey: .signer
            ),
            sequence: container.decode(TransportMessageSequence.self, forKey: .sequence),
            reconnectCursor: container.decode(
                TransportReconnectCursor.self,
                forKey: .reconnectCursor
            ),
            issuedAt: container.decode(AgentInstant.self, forKey: .issuedAt),
            payload: container.decode(BoundedTransportPayload.self, forKey: .payload),
            signature: container.decode(TransportSignature.self, forKey: .signature)
        )
    }

    public static func signed(
        pairing: TransportPairingIdentity,
        runID: RunID,
        commandID: CommandID,
        sequence: TransportMessageSequence,
        reconnectCursor: TransportReconnectCursor,
        issuedAt: AgentInstant,
        payload: BoundedTransportPayload,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Self {
        try TransportSigningAuthority.validate(
            privateKey: privateKey,
            fingerprint: pairing.controller.publicKeyFingerprint
        )
        try payload.validate()
        let body = RequestSigningBody(
            protocolVersion: pairing.protocolVersion,
            pairingID: pairing.pairingID,
            pairingGeneration: pairing.generation,
            runID: runID,
            commandID: commandID,
            executionNodeID: pairing.worker.executionNodeID,
            signer: pairing.controller.publicKeyFingerprint,
            sequence: sequence,
            reconnectCursor: reconnectCursor,
            issuedAt: issuedAt,
            payload: payload
        )
        return try Self(
            body: body,
            signature: TransportCanonicalCodec.signature(
                domain: .request,
                value: body,
                privateKey: privateKey
            )
        )
    }

    func verify(using publicKey: TransportSigningPublicKey) throws {
        let data = try TransportCanonicalCodec.signingData(
            domain: .request,
            value: signingBody
        )
        guard publicKey.isValidSignature(signature, for: data) else {
            throw TransportContractError.signatureInvalid
        }
    }

    private init(body: RequestSigningBody, signature: TransportSignature) throws {
        try self.init(
            protocolVersion: body.protocolVersion,
            pairingID: body.pairingID,
            pairingGeneration: body.pairingGeneration,
            runID: body.runID,
            commandID: body.commandID,
            executionNodeID: body.executionNodeID,
            signer: body.signer,
            sequence: body.sequence,
            reconnectCursor: body.reconnectCursor,
            issuedAt: body.issuedAt,
            payload: body.payload,
            signature: signature
        )
    }

    private var signingBody: RequestSigningBody {
        RequestSigningBody(
            protocolVersion: protocolVersion,
            pairingID: pairingID,
            pairingGeneration: pairingGeneration,
            runID: runID,
            commandID: commandID,
            executionNodeID: executionNodeID,
            signer: signer,
            sequence: sequence,
            reconnectCursor: reconnectCursor,
            issuedAt: issuedAt,
            payload: payload
        )
    }
}

private struct RequestSigningBody: Codable {
    let protocolVersion: AgentTransportProtocolVersion
    let pairingID: TransportPairingID
    let pairingGeneration: UInt64
    let runID: RunID
    let commandID: CommandID
    let executionNodeID: ExecutionNodeID
    let signer: TransportPublicKeyFingerprint
    let sequence: TransportMessageSequence
    let reconnectCursor: TransportReconnectCursor
    let issuedAt: AgentInstant
    let payload: BoundedTransportPayload
}

public struct WorkerEventEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: AgentTransportProtocolVersion
    public let pairingID: TransportPairingID
    public let pairingGeneration: UInt64
    public let runID: RunID
    public let eventID: EventID
    public let executionNodeID: ExecutionNodeID
    public let signer: TransportPublicKeyFingerprint
    public let sequence: TransportMessageSequence
    public let acknowledgesRequestThrough: UInt64
    public let emittedAt: AgentInstant
    public let payload: BoundedTransportPayload
    public let signature: TransportSignature

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case pairingID
        case pairingGeneration
        case runID
        case eventID
        case executionNodeID
        case signer
        case sequence
        case acknowledgesRequestThrough
        case emittedAt
        case payload
        case signature
    }

    public init(
        protocolVersion: AgentTransportProtocolVersion = .current,
        pairingID: TransportPairingID,
        pairingGeneration: UInt64,
        runID: RunID,
        eventID: EventID,
        executionNodeID: ExecutionNodeID,
        signer: TransportPublicKeyFingerprint,
        sequence: TransportMessageSequence,
        acknowledgesRequestThrough: UInt64,
        emittedAt: AgentInstant,
        payload: BoundedTransportPayload,
        signature: TransportSignature
    ) throws {
        guard protocolVersion.canBeDecoded() else {
            throw TransportContractError.unsupportedProtocolVersion
        }
        guard pairingGeneration > 0 else {
            throw TransportContractError.invalidPairing
        }
        try payload.validate()
        self.protocolVersion = protocolVersion
        self.pairingID = pairingID
        self.pairingGeneration = pairingGeneration
        self.runID = runID
        self.eventID = eventID
        self.executionNodeID = executionNodeID
        self.signer = signer
        self.sequence = sequence
        self.acknowledgesRequestThrough = acknowledgesRequestThrough
        self.emittedAt = emittedAt
        self.payload = payload
        self.signature = signature
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: container.decode(
                AgentTransportProtocolVersion.self,
                forKey: .protocolVersion
            ),
            pairingID: container.decode(TransportPairingID.self, forKey: .pairingID),
            pairingGeneration: container.decode(UInt64.self, forKey: .pairingGeneration),
            runID: container.decode(RunID.self, forKey: .runID),
            eventID: container.decode(EventID.self, forKey: .eventID),
            executionNodeID: container.decode(
                ExecutionNodeID.self,
                forKey: .executionNodeID
            ),
            signer: container.decode(
                TransportPublicKeyFingerprint.self,
                forKey: .signer
            ),
            sequence: container.decode(TransportMessageSequence.self, forKey: .sequence),
            acknowledgesRequestThrough: container.decode(
                UInt64.self,
                forKey: .acknowledgesRequestThrough
            ),
            emittedAt: container.decode(AgentInstant.self, forKey: .emittedAt),
            payload: container.decode(BoundedTransportPayload.self, forKey: .payload),
            signature: container.decode(TransportSignature.self, forKey: .signature)
        )
    }

    public static func signed(
        pairing: TransportPairingIdentity,
        runID: RunID,
        eventID: EventID,
        sequence: TransportMessageSequence,
        acknowledgesRequestThrough: UInt64,
        emittedAt: AgentInstant,
        payload: BoundedTransportPayload,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Self {
        try TransportSigningAuthority.validate(
            privateKey: privateKey,
            fingerprint: pairing.worker.publicKeyFingerprint
        )
        try payload.validate()
        let body = EventSigningBody(
            protocolVersion: pairing.protocolVersion,
            pairingID: pairing.pairingID,
            pairingGeneration: pairing.generation,
            runID: runID,
            eventID: eventID,
            executionNodeID: pairing.worker.executionNodeID,
            signer: pairing.worker.publicKeyFingerprint,
            sequence: sequence,
            acknowledgesRequestThrough: acknowledgesRequestThrough,
            emittedAt: emittedAt,
            payload: payload
        )
        return try Self(
            body: body,
            signature: TransportCanonicalCodec.signature(
                domain: .event,
                value: body,
                privateKey: privateKey
            )
        )
    }

    func verify(using publicKey: TransportSigningPublicKey) throws {
        let data = try TransportCanonicalCodec.signingData(
            domain: .event,
            value: signingBody
        )
        guard publicKey.isValidSignature(signature, for: data) else {
            throw TransportContractError.signatureInvalid
        }
    }

    private init(body: EventSigningBody, signature: TransportSignature) throws {
        try self.init(
            protocolVersion: body.protocolVersion,
            pairingID: body.pairingID,
            pairingGeneration: body.pairingGeneration,
            runID: body.runID,
            eventID: body.eventID,
            executionNodeID: body.executionNodeID,
            signer: body.signer,
            sequence: body.sequence,
            acknowledgesRequestThrough: body.acknowledgesRequestThrough,
            emittedAt: body.emittedAt,
            payload: body.payload,
            signature: signature
        )
    }

    private var signingBody: EventSigningBody {
        EventSigningBody(
            protocolVersion: protocolVersion,
            pairingID: pairingID,
            pairingGeneration: pairingGeneration,
            runID: runID,
            eventID: eventID,
            executionNodeID: executionNodeID,
            signer: signer,
            sequence: sequence,
            acknowledgesRequestThrough: acknowledgesRequestThrough,
            emittedAt: emittedAt,
            payload: payload
        )
    }
}

private struct EventSigningBody: Codable {
    let protocolVersion: AgentTransportProtocolVersion
    let pairingID: TransportPairingID
    let pairingGeneration: UInt64
    let runID: RunID
    let eventID: EventID
    let executionNodeID: ExecutionNodeID
    let signer: TransportPublicKeyFingerprint
    let sequence: TransportMessageSequence
    let acknowledgesRequestThrough: UInt64
    let emittedAt: AgentInstant
    let payload: BoundedTransportPayload
}

public enum TransportRevocationReason: String, Codable, Equatable, Sendable {
    case keyCompromised
    case pairingRotated
    case userRequested
    case policy
}

public struct TransportPairingRevocation: Codable, Equatable, Sendable {
    public let protocolVersion: AgentTransportProtocolVersion
    public let pairingID: TransportPairingID
    public let pairingGeneration: UInt64
    public let revocationSequence: UInt64
    public let issuer: TransportPublicKeyFingerprint
    public let issuedAt: AgentInstant
    public let reason: TransportRevocationReason
    public let signature: TransportSignature

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case pairingID
        case pairingGeneration
        case revocationSequence
        case issuer
        case issuedAt
        case reason
        case signature
    }

    public init(
        protocolVersion: AgentTransportProtocolVersion = .current,
        pairingID: TransportPairingID,
        pairingGeneration: UInt64,
        revocationSequence: UInt64,
        issuer: TransportPublicKeyFingerprint,
        issuedAt: AgentInstant,
        reason: TransportRevocationReason,
        signature: TransportSignature
    ) throws {
        guard protocolVersion.canBeDecoded() else {
            throw TransportContractError.unsupportedProtocolVersion
        }
        guard pairingGeneration > 0, revocationSequence > 0 else {
            throw TransportContractError.invalidRevocation
        }
        self.protocolVersion = protocolVersion
        self.pairingID = pairingID
        self.pairingGeneration = pairingGeneration
        self.revocationSequence = revocationSequence
        self.issuer = issuer
        self.issuedAt = issuedAt
        self.reason = reason
        self.signature = signature
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: container.decode(
                AgentTransportProtocolVersion.self,
                forKey: .protocolVersion
            ),
            pairingID: container.decode(TransportPairingID.self, forKey: .pairingID),
            pairingGeneration: container.decode(UInt64.self, forKey: .pairingGeneration),
            revocationSequence: container.decode(UInt64.self, forKey: .revocationSequence),
            issuer: container.decode(TransportPublicKeyFingerprint.self, forKey: .issuer),
            issuedAt: container.decode(AgentInstant.self, forKey: .issuedAt),
            reason: container.decode(TransportRevocationReason.self, forKey: .reason),
            signature: container.decode(TransportSignature.self, forKey: .signature)
        )
    }

    public static func signed(
        pairing: TransportPairingIdentity,
        revocationSequence: UInt64 = 1,
        issuedAt: AgentInstant,
        reason: TransportRevocationReason,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Self {
        guard revocationSequence > 0 else {
            throw TransportContractError.invalidRevocation
        }
        try TransportSigningAuthority.validate(
            privateKey: privateKey,
            fingerprint: pairing.controller.publicKeyFingerprint
        )
        let body = RevocationSigningBody(
            protocolVersion: pairing.protocolVersion,
            pairingID: pairing.pairingID,
            pairingGeneration: pairing.generation,
            revocationSequence: revocationSequence,
            issuer: pairing.controller.publicKeyFingerprint,
            issuedAt: issuedAt,
            reason: reason
        )
        return try Self(
            protocolVersion: body.protocolVersion,
            pairingID: body.pairingID,
            pairingGeneration: body.pairingGeneration,
            revocationSequence: body.revocationSequence,
            issuer: body.issuer,
            issuedAt: body.issuedAt,
            reason: body.reason,
            signature: TransportCanonicalCodec.signature(
                domain: .revocation,
                value: body,
                privateKey: privateKey
            )
        )
    }

    func verify(using publicKey: TransportSigningPublicKey) throws {
        let data = try TransportCanonicalCodec.signingData(
            domain: .revocation,
            value: signingBody
        )
        guard publicKey.isValidSignature(signature, for: data) else {
            throw TransportContractError.signatureInvalid
        }
    }

    private var signingBody: RevocationSigningBody {
        RevocationSigningBody(
            protocolVersion: protocolVersion,
            pairingID: pairingID,
            pairingGeneration: pairingGeneration,
            revocationSequence: revocationSequence,
            issuer: issuer,
            issuedAt: issuedAt,
            reason: reason
        )
    }
}

private struct RevocationSigningBody: Codable {
    let protocolVersion: AgentTransportProtocolVersion
    let pairingID: TransportPairingID
    let pairingGeneration: UInt64
    let revocationSequence: UInt64
    let issuer: TransportPublicKeyFingerprint
    let issuedAt: AgentInstant
    let reason: TransportRevocationReason
}

public struct TransportWireLimits: Equatable, Sendable {
    public static let production = Self(
        maximumEnvelopeBytes: 1_179_648,
        maximumStructuralDepth: 40,
        maximumContainerCount: 20_000
    )

    public let maximumEnvelopeBytes: Int
    public let maximumStructuralDepth: Int
    public let maximumContainerCount: Int

    public init(
        maximumEnvelopeBytes: Int,
        maximumStructuralDepth: Int,
        maximumContainerCount: Int
    ) {
        self.maximumEnvelopeBytes = maximumEnvelopeBytes
        self.maximumStructuralDepth = maximumStructuralDepth
        self.maximumContainerCount = maximumContainerCount
    }
}

public enum TransportWireValidationError: Error, Equatable, Sendable {
    case invalidLimits
    case envelopeTooLarge(maximum: Int, actual: Int)
    case structuralDepthExceeded(maximum: Int)
    case containerCountExceeded(maximum: Int)
    case malformedEnvelope
}

/// Bounded canonical wire encoding. The structural preflight runs before
/// JSONDecoder so hostile nesting cannot reach recursive model decoding.
public enum TransportWireCodec {
    public static func encode<Value: Encodable>(
        _ value: Value,
        limits: TransportWireLimits = .production
    ) throws -> Data {
        try validate(limits)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try preflight(data, limits: limits)
        return data
    }

    public static func decodeRequest(
        _ data: Data,
        limits: TransportWireLimits = .production
    ) throws -> WorkerRequestEnvelope {
        try decode(WorkerRequestEnvelope.self, from: data, limits: limits)
    }

    public static func decodeEvent(
        _ data: Data,
        limits: TransportWireLimits = .production
    ) throws -> WorkerEventEnvelope {
        try decode(WorkerEventEnvelope.self, from: data, limits: limits)
    }

    public static func decodeRevocation(
        _ data: Data,
        limits: TransportWireLimits = .production
    ) throws -> TransportPairingRevocation {
        try decode(TransportPairingRevocation.self, from: data, limits: limits)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        limits: TransportWireLimits
    ) throws -> Value {
        try validate(limits)
        try preflight(data, limits: limits)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as TransportContractError {
            throw error
        } catch let error as TransportPayloadValidationError {
            throw error
        } catch let error as TransportIdentityValidationError {
            throw error
        } catch let error as TransportSignatureValidationError {
            throw error
        } catch {
            throw TransportWireValidationError.malformedEnvelope
        }
    }

    private static func validate(_ limits: TransportWireLimits) throws {
        guard limits.maximumEnvelopeBytes > 0,
              limits.maximumStructuralDepth > 0,
              limits.maximumContainerCount > 0
        else { throw TransportWireValidationError.invalidLimits }
    }

    private static func preflight(
        _ data: Data,
        limits: TransportWireLimits
    ) throws {
        guard data.count <= limits.maximumEnvelopeBytes else {
            throw TransportWireValidationError.envelopeTooLarge(
                maximum: limits.maximumEnvelopeBytes,
                actual: data.count
            )
        }

        var depth = 0
        var count = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7b || byte == 0x5b {
                depth += 1
                count += 1
                guard depth <= limits.maximumStructuralDepth else {
                    throw TransportWireValidationError.structuralDepthExceeded(
                        maximum: limits.maximumStructuralDepth
                    )
                }
                guard count <= limits.maximumContainerCount else {
                    throw TransportWireValidationError.containerCountExceeded(
                        maximum: limits.maximumContainerCount
                    )
                }
            } else if byte == 0x7d || byte == 0x5d {
                depth -= 1
                guard depth >= 0 else {
                    throw TransportWireValidationError.malformedEnvelope
                }
            }
        }
        guard !inString, depth == 0 else {
            throw TransportWireValidationError.malformedEnvelope
        }
    }
}
