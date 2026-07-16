import AgentDomain
import Foundation

public struct TransportPayloadLimits: Equatable, Sendable {
    public static let production = Self(
        maximumEncodedBytes: 1_048_576,
        maximumNodeCount: 16_384,
        maximumContainerDepth: 32,
        maximumObjectEntryCount: 4_096,
        maximumArrayElementCount: 4_096,
        maximumStringBytes: 262_144,
        maximumObjectKeyBytes: 1_024
    )

    public let maximumEncodedBytes: Int
    public let maximumNodeCount: Int
    public let maximumContainerDepth: Int
    public let maximumObjectEntryCount: Int
    public let maximumArrayElementCount: Int
    public let maximumStringBytes: Int
    public let maximumObjectKeyBytes: Int

    public init(
        maximumEncodedBytes: Int,
        maximumNodeCount: Int,
        maximumContainerDepth: Int,
        maximumObjectEntryCount: Int,
        maximumArrayElementCount: Int,
        maximumStringBytes: Int,
        maximumObjectKeyBytes: Int
    ) {
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumNodeCount = maximumNodeCount
        self.maximumContainerDepth = maximumContainerDepth
        self.maximumObjectEntryCount = maximumObjectEntryCount
        self.maximumArrayElementCount = maximumArrayElementCount
        self.maximumStringBytes = maximumStringBytes
        self.maximumObjectKeyBytes = maximumObjectKeyBytes
    }
}

public enum TransportPayloadLimit: String, Equatable, Sendable {
    case encodedBytes
    case nodeCount
    case containerDepth
    case objectEntryCount
    case arrayElementCount
    case stringBytes
    case objectKeyBytes
}

/// Carries only limit identity and numeric observations. Rejected payload text,
/// credentials, and workspace paths are never retained in an error.
public enum TransportPayloadValidationError: Error, Equatable, Sendable {
    case invalidLimits
    case limitExceeded(
        limit: TransportPayloadLimit,
        maximum: Int,
        actual: Int
    )
}

public struct BoundedTransportPayload: Codable, Equatable, Hashable, Sendable {
    public let value: JSONValue

    public init(
        _ value: JSONValue,
        limits: TransportPayloadLimits = .production
    ) throws {
        self.value = value
        try validate(limits: limits)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(JSONValue.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public func validate(
        limits: TransportPayloadLimits = .production
    ) throws {
        guard limits.maximumEncodedBytes > 0,
              limits.maximumNodeCount > 0,
              limits.maximumContainerDepth > 0,
              limits.maximumObjectEntryCount > 0,
              limits.maximumArrayElementCount > 0,
              limits.maximumStringBytes > 0,
              limits.maximumObjectKeyBytes > 0
        else { throw TransportPayloadValidationError.invalidLimits }

        var nodeCount = 0
        try Self.validate(
            value,
            depth: 1,
            nodeCount: &nodeCount,
            limits: limits
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedByteCount = try encoder.encode(value).count
        guard encodedByteCount <= limits.maximumEncodedBytes else {
            throw TransportPayloadValidationError.limitExceeded(
                limit: .encodedBytes,
                maximum: limits.maximumEncodedBytes,
                actual: encodedByteCount
            )
        }
    }

    private static func validate(
        _ value: JSONValue,
        depth: Int,
        nodeCount: inout Int,
        limits: TransportPayloadLimits
    ) throws {
        nodeCount += 1
        guard nodeCount <= limits.maximumNodeCount else {
            throw TransportPayloadValidationError.limitExceeded(
                limit: .nodeCount,
                maximum: limits.maximumNodeCount,
                actual: nodeCount
            )
        }
        guard depth <= limits.maximumContainerDepth else {
            throw TransportPayloadValidationError.limitExceeded(
                limit: .containerDepth,
                maximum: limits.maximumContainerDepth,
                actual: depth
            )
        }

        switch value {
        case .null, .bool, .number:
            return
        case let .string(string):
            let count = string.utf8.count
            guard count <= limits.maximumStringBytes else {
                throw TransportPayloadValidationError.limitExceeded(
                    limit: .stringBytes,
                    maximum: limits.maximumStringBytes,
                    actual: count
                )
            }
        case let .array(values):
            guard values.count <= limits.maximumArrayElementCount else {
                throw TransportPayloadValidationError.limitExceeded(
                    limit: .arrayElementCount,
                    maximum: limits.maximumArrayElementCount,
                    actual: values.count
                )
            }
            for child in values {
                try validate(
                    child,
                    depth: depth + 1,
                    nodeCount: &nodeCount,
                    limits: limits
                )
            }
        case let .object(object):
            guard object.count <= limits.maximumObjectEntryCount else {
                throw TransportPayloadValidationError.limitExceeded(
                    limit: .objectEntryCount,
                    maximum: limits.maximumObjectEntryCount,
                    actual: object.count
                )
            }
            for key in object.keys.sorted() {
                let keyByteCount = key.utf8.count
                guard keyByteCount <= limits.maximumObjectKeyBytes else {
                    throw TransportPayloadValidationError.limitExceeded(
                        limit: .objectKeyBytes,
                        maximum: limits.maximumObjectKeyBytes,
                        actual: keyByteCount
                    )
                }
                if let child = object[key] {
                    try validate(
                        child,
                        depth: depth + 1,
                        nodeCount: &nodeCount,
                        limits: limits
                    )
                }
            }
        }
    }
}
