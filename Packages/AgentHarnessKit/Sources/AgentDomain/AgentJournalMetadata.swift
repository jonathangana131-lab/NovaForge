import Foundation

public enum AgentCanonicalSHA256DigestValidationError: Error, Equatable, Sendable {
    case invalidFormat
}

/// A credential-free, canonical lowercase SHA-256 reference stored in the
/// semantic journal. The digest identifies external immutable material; it
/// never stores that material or a credential used to obtain it.
public struct AgentCanonicalSHA256Digest:
    Codable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.utf8.count == 71,
              rawValue.hasPrefix("sha256:"),
              rawValue.utf8.dropFirst(7).allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              })
        else { throw AgentCanonicalSHA256DigestValidationError.invalidFormat }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public enum ProviderAttemptScopeReferenceValidationError: Error, Equatable, Sendable {
    case invalidRequestID
    case invalidAttemptID
}

/// Provider-neutral copy of the exact caller-owned wire-attempt scope. It is
/// kept in AgentDomain so replay does not import a provider implementation.
public struct ProviderAttemptScopeReference: Codable, Equatable, Hashable, Sendable {
    public let requestID: String
    public let attemptID: String

    private enum CodingKeys: String, CodingKey {
        case requestID
        case attemptID
    }

    public init(requestID: String, attemptID: String) throws {
        guard Self.isCanonicalIdentity(requestID) else {
            throw ProviderAttemptScopeReferenceValidationError.invalidRequestID
        }
        guard Self.isCanonicalIdentity(attemptID) else {
            throw ProviderAttemptScopeReferenceValidationError.invalidAttemptID
        }
        self.requestID = requestID
        self.attemptID = attemptID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(String.self, forKey: .requestID),
            attemptID: container.decode(String.self, forKey: .attemptID)
        )
    }

    private static func isCanonicalIdentity(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

/// Versioned dispatch facts for one provider attempt. Historical v1.0 events
/// did not persist these values and decode to the explicit `.legacyV1` case;
/// they are never reconstructed from mutable provider state during replay.
public enum ProviderAttemptJournalMetadata: Codable, Equatable, Sendable {
    case legacyV1
    case recordedV1_1(
        requestDigest: AgentCanonicalSHA256Digest,
        scope: ProviderAttemptScopeReference,
        ordinal: UInt32,
        recoverySeed: UInt64
    )

    private enum CodingKeys: String, CodingKey {
        case kind
        case requestDigest
        case scope
        case ordinal
        case recoverySeed
    }

    private enum Kind: String, Codable {
        case legacyV1
        case recordedV1_1
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .legacyV1:
            guard !container.contains(.requestDigest),
                  !container.contains(.scope),
                  !container.contains(.ordinal),
                  !container.contains(.recoverySeed)
            else { throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Legacy provider metadata cannot carry v1.1 fields."
            ) }
            self = .legacyV1
        case .recordedV1_1:
            self = .recordedV1_1(
                requestDigest: try container.decode(
                    AgentCanonicalSHA256Digest.self,
                    forKey: .requestDigest
                ),
                scope: try container.decode(
                    ProviderAttemptScopeReference.self,
                    forKey: .scope
                ),
                ordinal: try container.decode(UInt32.self, forKey: .ordinal),
                recoverySeed: try container.decode(UInt64.self, forKey: .recoverySeed)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .legacyV1:
            try container.encode(Kind.legacyV1, forKey: .kind)
        case let .recordedV1_1(requestDigest, scope, ordinal, recoverySeed):
            try container.encode(Kind.recordedV1_1, forKey: .kind)
            try container.encode(requestDigest, forKey: .requestDigest)
            try container.encode(scope, forKey: .scope)
            try container.encode(ordinal, forKey: .ordinal)
            try container.encode(recoverySeed, forKey: .recoverySeed)
        }
    }

    public var isLegacyV1: Bool {
        if case .legacyV1 = self { return true }
        return false
    }
}

/// M6 authority identity committed before a mutation may start.
public struct ToolEffectKeyReference: Codable, Equatable, Hashable, Sendable {
    public let effectKeySHA256: AgentCanonicalSHA256Digest

    public init(effectKeySHA256: AgentCanonicalSHA256Digest) {
        self.effectKeySHA256 = effectKeySHA256
    }
}

/// Content-addressed proof returned after the M6 gateway has applied and
/// durably settled one mutation. These values deliberately exclude tool output.
public struct ToolEffectReceiptReference: Codable, Equatable, Hashable, Sendable {
    public let effectKeySHA256: AgentCanonicalSHA256Digest
    public let applicationSHA256: AgentCanonicalSHA256Digest
    public let evidenceSHA256: AgentCanonicalSHA256Digest
    public let finalRecordSHA256: AgentCanonicalSHA256Digest

    public init(
        effectKeySHA256: AgentCanonicalSHA256Digest,
        applicationSHA256: AgentCanonicalSHA256Digest,
        evidenceSHA256: AgentCanonicalSHA256Digest,
        finalRecordSHA256: AgentCanonicalSHA256Digest
    ) {
        self.effectKeySHA256 = effectKeySHA256
        self.applicationSHA256 = applicationSHA256
        self.evidenceSHA256 = evidenceSHA256
        self.finalRecordSHA256 = finalRecordSHA256
    }

    public var effectKey: ToolEffectKeyReference {
        ToolEffectKeyReference(effectKeySHA256: effectKeySHA256)
    }
}
