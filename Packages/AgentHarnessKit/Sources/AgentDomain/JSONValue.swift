import Foundation

/// A JSON number that retains integer width and, critically, remains distinct from Bool.
public enum JSONNumber: Codable, Hashable, Sendable {
    case integer(Int64)
    case unsignedInteger(UInt64)
    case floatingPoint(Double)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else {
            let value = try container.decode(Double.self)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "JSON numbers must be finite"
                )
            }
            self = .floatingPoint(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value):
            try container.encode(value)
        case let .unsignedInteger(value):
            try container.encode(value)
        case let .floatingPoint(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "JSON numbers must be finite"
                    )
                )
            }
            try container.encode(value)
        }
    }
}

/// Provider-neutral JSON preserving null, Boolean, numeric, array, and object types.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(keyed.allKeys.count)
            for key in keyed.allKeys {
                result[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(result)
            return
        }

        if var unkeyed = try? decoder.unkeyedContainer() {
            var result: [JSONValue] = []
            if let count = unkeyed.count {
                result.reserveCapacity(count)
            }
            while !unkeyed.isAtEnd {
                result.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(result)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(JSONNumber.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case let .object(values):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for key in values.keys.sorted() {
                try container.encode(values[key], forKey: DynamicCodingKey(key))
            }
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case let .bool(value):
            hasher.combine(1)
            hasher.combine(value)
        case let .number(value):
            hasher.combine(2)
            hasher.combine(value)
        case let .string(value):
            hasher.combine(3)
            hasher.combine(value)
        case let .array(values):
            hasher.combine(4)
            hasher.combine(values)
        case let .object(values):
            hasher.combine(5)
            for key in values.keys.sorted() {
                hasher.combine(key)
                hasher.combine(values[key])
            }
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
