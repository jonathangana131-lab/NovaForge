import AgentDomain
import Foundation

/// The JSON Schema subset accepted at the model/tool boundary.
///
/// The representation is intentionally provider-neutral. Provider adapters serialize
/// `providerValue` instead of maintaining their own parameter tables.
public indirect enum JSONSchema: Hashable, Sendable {
    case null(description: String? = nil)
    case boolean(description: String? = nil)
    case integer(description: String? = nil, minimum: Int64? = nil, maximum: Int64? = nil)
    case number(description: String? = nil, minimum: Double? = nil, maximum: Double? = nil)
    case string(
        description: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        allowedValues: [String]? = nil
    )
    case array(
        description: String? = nil,
        items: JSONSchema,
        minItems: Int? = nil,
        maxItems: Int? = nil
    )
    case object(
        description: String? = nil,
        properties: [String: JSONSchema],
        required: [String],
        additionalProperties: Bool = false
    )
    case oneOf(description: String? = nil, schemas: [JSONSchema])

    public static func nullable(_ schema: JSONSchema, description: String? = nil) -> JSONSchema {
        .oneOf(description: description, schemas: [schema, .null()])
    }

    public var providerValue: JSONValue {
        providerValue(requireAllObjectProperties: false)
    }

    /// Provider representation for strict function calling. Optional typed fields are
    /// nullable in their schemas and appear in `required`, as required by strict adapters.
    public var strictProviderValue: JSONValue {
        providerValue(requireAllObjectProperties: true)
    }

    private func providerValue(requireAllObjectProperties: Bool) -> JSONValue {
        switch self {
        case let .null(description):
            return primitiveProviderValue(type: "null", description: description)

        case let .boolean(description):
            return primitiveProviderValue(type: "boolean", description: description)

        case let .integer(description, minimum, maximum):
            var object = primitiveProviderObject(type: "integer", description: description)
            if let minimum {
                object["minimum"] = .number(.integer(minimum))
            }
            if let maximum {
                object["maximum"] = .number(.integer(maximum))
            }
            return .object(object)

        case let .number(description, minimum, maximum):
            var object = primitiveProviderObject(type: "number", description: description)
            if let minimum {
                object["minimum"] = .number(.floatingPoint(minimum))
            }
            if let maximum {
                object["maximum"] = .number(.floatingPoint(maximum))
            }
            return .object(object)

        case let .string(description, minLength, maxLength, allowedValues):
            var object = primitiveProviderObject(type: "string", description: description)
            if let minLength {
                object["minLength"] = .number(.integer(Int64(minLength)))
            }
            if let maxLength {
                object["maxLength"] = .number(.integer(Int64(maxLength)))
            }
            if let allowedValues {
                object["enum"] = .array(allowedValues.sorted().map(JSONValue.string))
            }
            return .object(object)

        case let .array(description, items, minItems, maxItems):
            var object = primitiveProviderObject(type: "array", description: description)
            object["items"] = items.providerValue(
                requireAllObjectProperties: requireAllObjectProperties
            )
            if let minItems {
                object["minItems"] = .number(.integer(Int64(minItems)))
            }
            if let maxItems {
                object["maxItems"] = .number(.integer(Int64(maxItems)))
            }
            return .object(object)

        case let .object(description, properties, required, additionalProperties):
            var object = primitiveProviderObject(type: "object", description: description)
            object["properties"] = .object(
                properties.mapValues {
                    $0.providerValue(requireAllObjectProperties: requireAllObjectProperties)
                }
            )
            let providerRequired = requireAllObjectProperties ? Array(properties.keys) : required
            object["required"] = .array(providerRequired.sorted().map(JSONValue.string))
            object["additionalProperties"] = .bool(additionalProperties)
            return .object(object)

        case let .oneOf(description, schemas):
            var object: [String: JSONValue] = [
                "anyOf": .array(schemas.map {
                    $0.providerValue(requireAllObjectProperties: requireAllObjectProperties)
                }),
            ]
            if let description {
                object["description"] = .string(description)
            }
            return .object(object)
        }
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    public var acceptsNull: Bool {
        switch self {
        case .null:
            return true
        case let .oneOf(_, schemas):
            return schemas.contains { $0.acceptsNull }
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case let .null(description):
            hasher.combine(0)
            hasher.combine(description)
        case let .boolean(description):
            hasher.combine(1)
            hasher.combine(description)
        case let .integer(description, minimum, maximum):
            hasher.combine(2)
            hasher.combine(description)
            hasher.combine(minimum)
            hasher.combine(maximum)
        case let .number(description, minimum, maximum):
            hasher.combine(3)
            hasher.combine(description)
            hasher.combine(minimum)
            hasher.combine(maximum)
        case let .string(description, minimum, maximum, allowedValues):
            hasher.combine(4)
            hasher.combine(description)
            hasher.combine(minimum)
            hasher.combine(maximum)
            hasher.combine(allowedValues)
        case let .array(description, items, minimum, maximum):
            hasher.combine(5)
            hasher.combine(description)
            hasher.combine(items)
            hasher.combine(minimum)
            hasher.combine(maximum)
        case let .object(description, properties, required, additionalProperties):
            hasher.combine(6)
            hasher.combine(description)
            for key in properties.keys.sorted() {
                hasher.combine(key)
                hasher.combine(properties[key])
            }
            hasher.combine(required)
            hasher.combine(additionalProperties)
        case let .oneOf(description, schemas):
            hasher.combine(7)
            hasher.combine(description)
            hasher.combine(schemas)
        }
    }

    private func primitiveProviderValue(type: String, description: String?) -> JSONValue {
        .object(primitiveProviderObject(type: type, description: description))
    }

    private func primitiveProviderObject(type: String, description: String?) -> [String: JSONValue] {
        var object: [String: JSONValue] = ["type": .string(type)]
        if let description {
            object["description"] = .string(description)
        }
        return object
    }
}

public enum ToolValidationCode: String, Codable, CaseIterable, Hashable, Sendable {
    case typeMismatch
    case missingRequiredField
    case unknownField
    case belowMinimum
    case aboveMaximum
    case tooShort
    case tooLong
    case disallowedValue
    case invalidSchema
    case typedDecodingFailed
}

public struct ToolValidationIssue: Error, Equatable, Sendable {
    public let code: ToolValidationCode
    public let path: [String]
    public let message: String

    public init(code: ToolValidationCode, path: [String], message: String) {
        self.code = code
        self.path = path
        self.message = message
    }

    public var displayPath: String {
        path.isEmpty ? "$" : "$." + path.joined(separator: ".")
    }
}

public struct ToolArgumentValidationError: Error, Equatable, Sendable {
    public let issues: [ToolValidationIssue]

    public init(issues: [ToolValidationIssue]) {
        self.issues = issues
    }
}

public enum ToolArgumentValidator {
    public static func validate(_ value: JSONValue, against schema: JSONSchema) throws {
        let issues = validate(value, against: schema, path: [])
        guard issues.isEmpty else {
            throw ToolArgumentValidationError(issues: issues)
        }
    }

    private static func validate(
        _ value: JSONValue,
        against schema: JSONSchema,
        path: [String]
    ) -> [ToolValidationIssue] {
        switch schema {
        case .null:
            guard case .null = value else { return [typeMismatch("null", path: path)] }
            return []

        case .boolean:
            guard case .bool = value else { return [typeMismatch("boolean", path: path)] }
            return []

        case let .integer(_, minimum, maximum):
            let integer: IntegerValue
            switch value {
            case let .number(.integer(number)):
                integer = .signed(number)
            case let .number(.unsignedInteger(number)):
                integer = .unsigned(number)
            default:
                return [typeMismatch("integer", path: path)]
            }
            return integerBounds(integer, minimum: minimum, maximum: maximum, path: path)

        case let .number(_, minimum, maximum):
            let number: Double
            switch value {
            case let .number(.integer(value)):
                number = Double(value)
            case let .number(.unsignedInteger(value)):
                number = Double(value)
            case let .number(.floatingPoint(value)):
                number = value
            default:
                return [typeMismatch("number", path: path)]
            }
            guard number.isFinite else {
                return [typeMismatch("finite number", path: path)]
            }
            var issues: [ToolValidationIssue] = []
            if let minimum, number < minimum {
                issues.append(.init(code: .belowMinimum, path: path, message: "Number is below the minimum."))
            }
            if let maximum, number > maximum {
                issues.append(.init(code: .aboveMaximum, path: path, message: "Number is above the maximum."))
            }
            return issues

        case let .string(_, minLength, maxLength, allowedValues):
            guard case let .string(string) = value else {
                return [typeMismatch("string", path: path)]
            }
            var issues: [ToolValidationIssue] = []
            if let minLength, string.count < minLength {
                issues.append(.init(code: .tooShort, path: path, message: "String is shorter than allowed."))
            }
            if let maxLength, string.count > maxLength {
                issues.append(.init(code: .tooLong, path: path, message: "String is longer than allowed."))
            }
            if let allowedValues, !allowedValues.contains(string) {
                issues.append(.init(code: .disallowedValue, path: path, message: "String is not an allowed value."))
            }
            return issues

        case let .array(_, items, minItems, maxItems):
            guard case let .array(values) = value else {
                return [typeMismatch("array", path: path)]
            }
            var issues: [ToolValidationIssue] = []
            if let minItems, values.count < minItems {
                issues.append(.init(code: .belowMinimum, path: path, message: "Array contains too few items."))
            }
            if let maxItems, values.count > maxItems {
                issues.append(.init(code: .aboveMaximum, path: path, message: "Array contains too many items."))
            }
            for (index, item) in values.enumerated() {
                issues.append(contentsOf: validate(item, against: items, path: path + [String(index)]))
            }
            return issues

        case let .object(_, properties, required, additionalProperties):
            guard case let .object(object) = value else {
                return [typeMismatch("object", path: path)]
            }
            var issues: [ToolValidationIssue] = []
            for key in required.sorted() where object[key] == nil {
                issues.append(.init(
                    code: .missingRequiredField,
                    path: path + [key],
                    message: "Required field is missing."
                ))
            }
            for key in object.keys.sorted() {
                guard let propertyValue = object[key] else { continue }
                guard let propertySchema = properties[key] else {
                    if !additionalProperties {
                        issues.append(.init(
                            code: .unknownField,
                            path: path + [key],
                            message: "Unknown field is not allowed."
                        ))
                    }
                    continue
                }
                issues.append(contentsOf: validate(propertyValue, against: propertySchema, path: path + [key]))
            }
            return issues

        case let .oneOf(_, schemas):
            guard !schemas.isEmpty else {
                return [.init(code: .invalidSchema, path: path, message: "Union schema has no alternatives.")]
            }
            let attempts = schemas.map { validate(value, against: $0, path: path) }
            let matchingCount = attempts.filter(\.isEmpty).count
            if matchingCount == 1 { return [] }
            let informativeFailures = attempts.filter { issues in
                issues.contains { $0.code != .typeMismatch }
            }
            if matchingCount == 0, informativeFailures.count == 1 {
                return informativeFailures[0]
            }
            return [typeMismatch("exactly one allowed schema", path: path)]
        }
    }

    private static func typeMismatch(_ expected: String, path: [String]) -> ToolValidationIssue {
        .init(code: .typeMismatch, path: path, message: "Expected \(expected).")
    }

    private enum IntegerValue {
        case signed(Int64)
        case unsigned(UInt64)
    }

    private static func integerBounds(
        _ value: IntegerValue,
        minimum: Int64?,
        maximum: Int64?,
        path: [String]
    ) -> [ToolValidationIssue] {
        var issues: [ToolValidationIssue] = []
        if let minimum {
            let isBelow: Bool
            switch value {
            case let .signed(value): isBelow = value < minimum
            case let .unsigned(value): isBelow = minimum > 0 && value < UInt64(minimum)
            }
            if isBelow {
                issues.append(.init(code: .belowMinimum, path: path, message: "Integer is below the minimum."))
            }
        }
        if let maximum {
            let isAbove: Bool
            switch value {
            case let .signed(value): isAbove = value > maximum
            case let .unsigned(value): isAbove = maximum < 0 || value > UInt64(maximum)
            }
            if isAbove {
                issues.append(.init(code: .aboveMaximum, path: path, message: "Integer is above the maximum."))
            }
        }
        return issues
    }
}

public enum AgentToolJSON {
    public static func data(for value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func string(for value: JSONValue) throws -> String {
        let data = try data(for: value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToolValidationIssue(
                code: .typedDecodingFailed,
                path: [],
                message: "Canonical JSON was not UTF-8."
            )
        }
        return string
    }
}
