import AgentDomain
import Foundation

enum ProviderJSONSchemaValidationError: Error, Equatable, Sendable {
    case invalidSchema
    case mismatch
    case limitExceeded
}

/// Bounded validator for the provider-facing JSON Schema subset emitted by
/// AgentTools. Provider output is always checked again before it becomes a
/// canonical typed tool call, even when a backend claims constrained decoding.
enum ProviderJSONSchemaValidator {
    private static let maximumDepth = 64
    private static let maximumNodes = 100_000
    private static let maximumMatchingWorkUnits = 100_000
    private static let supportedKeywords: Set<String> = [
        "type", "enum", "const", "allOf", "anyOf", "oneOf",
        "properties", "required", "additionalProperties",
        "minProperties", "maxProperties", "items", "minItems",
        "maxItems", "uniqueItems", "minLength", "maxLength",
        "minimum", "maximum", "description", "title", "default",
        "examples",
    ]
    private static let supportedTypes: Set<String> = [
        "null", "boolean", "object", "array", "number", "integer", "string",
    ]

    /// Validates the complete schema independently of any instance data.
    ///
    /// This must run before a request is dispatched as well as before provider
    /// output is accepted. In particular, dormant branches and schemas under
    /// absent properties are still traversed and rejected when malformed.
    static func validateSchema(_ schema: JSONValue) throws {
        var remaining = maximumNodes
        try preflightSchema(schema, depth: 0, remaining: &remaining)
    }

    static func validate(_ value: JSONValue, against schema: JSONValue) throws {
        try validateSchema(schema)

        // Provider-neutral JSONValue can be constructed directly, so enforce
        // finite numbers and bounded input trees even when no schema keyword
        // would otherwise visit a nested instance value.
        var valueRemaining = maximumNodes
        try validateJSONValue(
            value,
            depth: 0,
            remaining: &valueRemaining,
            invalidError: .mismatch
        )

        // Branch evaluation and every recursive semantic-key visit share this
        // single budget. A bounded schema can therefore not multiply a bounded
        // instance into unbounded work through allOf/anyOf/oneOf.
        var matchingRemaining = maximumMatchingWorkUnits
        guard try matches(
            value,
            schema: schema,
            depth: 0,
            remaining: &matchingRemaining
        ) else {
            throw ProviderJSONSchemaValidationError.mismatch
        }
    }

    private static func preflightSchema(
        _ schema: JSONValue,
        depth: Int,
        remaining: inout Int
    ) throws {
        try consumeNode(depth: depth, remaining: &remaining)

        if case .bool = schema { return }
        guard case let .object(object) = schema else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }
        guard object.keys.allSatisfy(supportedKeywords.contains) else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }

        if let typeValue = object["type"] {
            try validateJSONValue(
                typeValue,
                depth: depth + 1,
                remaining: &remaining,
                invalidError: .invalidSchema
            )
            let types = try schemaTypes(typeValue)
            guard !types.isEmpty,
                  Set(types).count == types.count,
                  types.allSatisfy(supportedTypes.contains)
            else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
        }

        if let constant = object["const"] {
            try validateJSONValue(
                constant,
                depth: depth + 1,
                remaining: &remaining,
                invalidError: .invalidSchema
            )
        }
        if let enumeration = object["enum"] {
            try validateJSONValue(
                enumeration,
                depth: depth + 1,
                remaining: &remaining,
                invalidError: .invalidSchema
            )
            guard case let .array(values) = enumeration, !values.isEmpty else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
            var keys: [SemanticJSONKey] = []
            keys.reserveCapacity(values.count)
            for value in values {
                keys.append(try semanticKey(value, remaining: &remaining))
            }
            guard Set(keys).count == keys.count else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
        }

        for keyword in ["allOf", "anyOf", "oneOf"] {
            if let branches = object[keyword] {
                try preflightSchemaArray(
                    branches,
                    depth: depth + 1,
                    remaining: &remaining
                )
            }
        }

        if let rawProperties = object["properties"] {
            try consumeNode(depth: depth + 1, remaining: &remaining)
            guard case let .object(properties) = rawProperties else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
            for key in properties.keys.sorted() {
                guard let propertySchema = properties[key] else { continue }
                try preflightSchema(
                    propertySchema,
                    depth: depth + 2,
                    remaining: &remaining
                )
            }
        }

        if let required = object["required"] {
            try validateJSONValue(
                required,
                depth: depth + 1,
                remaining: &remaining,
                invalidError: .invalidSchema
            )
            let names = try stringArray(required)
            guard Set(names).count == names.count else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
        }

        if let additionalProperties = object["additionalProperties"] {
            try preflightSchema(
                additionalProperties,
                depth: depth + 1,
                remaining: &remaining
            )
        }
        if let items = object["items"] {
            try preflightSchema(items, depth: depth + 1, remaining: &remaining)
        }

        for keyword in [
            "minProperties", "maxProperties", "minItems", "maxItems",
            "minLength", "maxLength",
        ] {
            if let bound = object[keyword] {
                try validateJSONValue(
                    bound,
                    depth: depth + 1,
                    remaining: &remaining,
                    invalidError: .invalidSchema
                )
                _ = try nonnegativeInt(bound)
            }
        }
        try validateIntegerBounds(
            minimum: object["minProperties"],
            maximum: object["maxProperties"]
        )
        try validateIntegerBounds(
            minimum: object["minItems"],
            maximum: object["maxItems"]
        )
        try validateIntegerBounds(
            minimum: object["minLength"],
            maximum: object["maxLength"]
        )

        if let uniqueItems = object["uniqueItems"] {
            try validateJSONValue(
                uniqueItems,
                depth: depth + 1,
                remaining: &remaining,
                invalidError: .invalidSchema
            )
            guard case .bool = uniqueItems else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
        }

        for keyword in ["minimum", "maximum"] {
            if let bound = object[keyword] {
                try validateJSONValue(
                    bound,
                    depth: depth + 1,
                    remaining: &remaining,
                    invalidError: .invalidSchema
                )
                _ = try schemaNumber(bound)
            }
        }
        if let minimumValue = object["minimum"],
           let maximumValue = object["maximum"] {
            let minimum = try schemaNumber(minimumValue)
            let maximum = try schemaNumber(maximumValue)
            guard compare(minimum, maximum) != .greater else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
        }

        for keyword in ["description", "title"] {
            if let annotation = object[keyword] {
                try validateJSONValue(
                    annotation,
                    depth: depth + 1,
                    remaining: &remaining,
                    invalidError: .invalidSchema
                )
                guard case .string = annotation else {
                    throw ProviderJSONSchemaValidationError.invalidSchema
                }
            }
        }
        if let defaultValue = object["default"] {
            try validateJSONValue(
                defaultValue,
                depth: depth + 1,
                remaining: &remaining,
                invalidError: .invalidSchema
            )
        }
        if let examples = object["examples"] {
            try validateJSONValue(
                examples,
                depth: depth + 1,
                remaining: &remaining,
                invalidError: .invalidSchema
            )
            guard case .array = examples else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
        }
    }

    private static func preflightSchemaArray(
        _ value: JSONValue,
        depth: Int,
        remaining: inout Int
    ) throws {
        try consumeNode(depth: depth, remaining: &remaining)
        guard case let .array(schemas) = value, !schemas.isEmpty else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }
        for schema in schemas {
            try preflightSchema(schema, depth: depth + 1, remaining: &remaining)
        }
    }

    private static func validateIntegerBounds(
        minimum: JSONValue?,
        maximum: JSONValue?
    ) throws {
        guard let minimum, let maximum else { return }
        let parsedMinimum = try nonnegativeInt(minimum)
        let parsedMaximum = try nonnegativeInt(maximum)
        guard parsedMinimum <= parsedMaximum else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }
    }

    private static func validateJSONValue(
        _ value: JSONValue,
        depth: Int,
        remaining: inout Int,
        invalidError: ProviderJSONSchemaValidationError
    ) throws {
        try consumeNode(depth: depth, remaining: &remaining)
        switch value {
        case .null, .bool, .string:
            return
        case let .number(number):
            guard isFinite(number) else { throw invalidError }
        case let .array(values):
            for value in values {
                try validateJSONValue(
                    value,
                    depth: depth + 1,
                    remaining: &remaining,
                    invalidError: invalidError
                )
            }
        case let .object(values):
            for key in values.keys.sorted() {
                guard let value = values[key] else { continue }
                try validateJSONValue(
                    value,
                    depth: depth + 1,
                    remaining: &remaining,
                    invalidError: invalidError
                )
            }
        }
    }

    private static func consumeNode(depth: Int, remaining: inout Int) throws {
        guard depth <= maximumDepth, remaining > 0 else {
            throw ProviderJSONSchemaValidationError.limitExceeded
        }
        remaining -= 1
    }

    private static func consumeWorkUnit(remaining: inout Int) throws {
        guard remaining > 0 else {
            throw ProviderJSONSchemaValidationError.limitExceeded
        }
        remaining -= 1
    }

    private static func matches(
        _ value: JSONValue,
        schema: JSONValue,
        depth: Int,
        remaining: inout Int
    ) throws -> Bool {
        try consumeNode(depth: depth, remaining: &remaining)

        if case let .bool(allowed) = schema { return allowed }
        guard case let .object(object) = schema else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }

        if let constant = object["const"] {
            let constantKey = try semanticKey(constant, remaining: &remaining)
            let instanceKey = try semanticKey(value, remaining: &remaining)
            if constantKey != instanceKey { return false }
        }
        if let enumeration = object["enum"] {
            let values = try schemaArray(enumeration)
            let instanceKey = try semanticKey(value, remaining: &remaining)
            var found = false
            for candidate in values {
                let candidateKey = try semanticKey(candidate, remaining: &remaining)
                if candidateKey == instanceKey {
                    found = true
                    break
                }
            }
            if !found { return false }
        }

        if let allOf = object["allOf"] {
            for nested in try schemaArray(allOf) {
                if try matches(
                    value,
                    schema: nested,
                    depth: depth + 1,
                    remaining: &remaining
                ) == false {
                    return false
                }
            }
        }
        if let anyOf = object["anyOf"] {
            var didMatch = false
            for nested in try schemaArray(anyOf) {
                if try matches(
                    value,
                    schema: nested,
                    depth: depth + 1,
                    remaining: &remaining
                ) {
                    didMatch = true
                    break
                }
            }
            if !didMatch { return false }
        }
        if let oneOf = object["oneOf"] {
            var matchCount = 0
            for nested in try schemaArray(oneOf) {
                if try matches(
                    value,
                    schema: nested,
                    depth: depth + 1,
                    remaining: &remaining
                ) {
                    matchCount += 1
                    if matchCount > 1 { return false }
                }
            }
            if matchCount != 1 { return false }
        }

        if let typeValue = object["type"] {
            let accepted = try schemaTypes(typeValue)
            if !accepted.contains(where: { typeMatches(value, type: $0) }) {
                return false
            }
        }

        switch value {
        case let .object(arguments):
            return try matchesObject(
                arguments,
                schema: object,
                depth: depth,
                remaining: &remaining
            )
        case let .array(values):
            return try matchesArray(
                values,
                schema: object,
                depth: depth,
                remaining: &remaining
            )
        case let .string(string):
            return try matchesString(string, schema: object)
        case let .number(number):
            return try matchesNumber(number, schema: object)
        case .null, .bool:
            return true
        }
    }

    private static func matchesObject(
        _ value: [String: JSONValue],
        schema: [String: JSONValue],
        depth: Int,
        remaining: inout Int
    ) throws -> Bool {
        let properties: [String: JSONValue]
        if let raw = schema["properties"] {
            guard case let .object(parsed) = raw else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
            properties = parsed
        } else {
            properties = [:]
        }
        if let rawRequired = schema["required"] {
            let required = try stringArray(rawRequired)
            if required.contains(where: { value[$0] == nil }) { return false }
        }
        if let minimum = try optionalNonnegativeInt(schema["minProperties"]),
           value.count < minimum {
            return false
        }
        if let maximum = try optionalNonnegativeInt(schema["maxProperties"]),
           value.count > maximum {
            return false
        }

        for key in value.keys.sorted() {
            guard let child = value[key] else { continue }
            if let childSchema = properties[key] {
                if try matches(
                    child,
                    schema: childSchema,
                    depth: depth + 1,
                    remaining: &remaining
                ) == false {
                    return false
                }
                continue
            }
            switch schema["additionalProperties"] {
            case .none, .some(.bool(true)):
                continue
            case .some(.bool(false)):
                return false
            case let .some(additionalSchema):
                if try matches(
                    child,
                    schema: additionalSchema,
                    depth: depth + 1,
                    remaining: &remaining
                ) == false {
                    return false
                }
            }
        }
        return true
    }

    private static func matchesArray(
        _ values: [JSONValue],
        schema: [String: JSONValue],
        depth: Int,
        remaining: inout Int
    ) throws -> Bool {
        if let minimum = try optionalNonnegativeInt(schema["minItems"]),
           values.count < minimum {
            return false
        }
        if let maximum = try optionalNonnegativeInt(schema["maxItems"]),
           values.count > maximum {
            return false
        }
        if schema["uniqueItems"] == .bool(true) {
            var keys: [SemanticJSONKey] = []
            keys.reserveCapacity(values.count)
            for value in values {
                keys.append(try semanticKey(value, remaining: &remaining))
            }
            if Set(keys).count != keys.count { return false }
        }
        guard let itemSchema = schema["items"] else { return true }
        for value in values {
            if try matches(
                value,
                schema: itemSchema,
                depth: depth + 1,
                remaining: &remaining
            ) == false {
                return false
            }
        }
        return true
    }

    private static func matchesString(
        _ value: String,
        schema: [String: JSONValue]
    ) throws -> Bool {
        if let minimum = try optionalNonnegativeInt(schema["minLength"]),
           value.unicodeScalars.count < minimum {
            return false
        }
        if let maximum = try optionalNonnegativeInt(schema["maxLength"]),
           value.unicodeScalars.count > maximum {
            return false
        }
        return true
    }

    private static func matchesNumber(
        _ value: JSONNumber,
        schema: [String: JSONValue]
    ) throws -> Bool {
        if let minimumValue = schema["minimum"] {
            let minimum = try schemaNumber(minimumValue)
            guard compare(value, minimum) != .less else { return false }
        }
        if let maximumValue = schema["maximum"] {
            let maximum = try schemaNumber(maximumValue)
            guard compare(value, maximum) != .greater else { return false }
        }
        return true
    }

    private static func schemaArray(_ value: JSONValue) throws -> [JSONValue] {
        guard case let .array(values) = value, !values.isEmpty else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }
        return values
    }

    private static func schemaTypes(_ value: JSONValue) throws -> [String] {
        switch value {
        case let .string(type):
            return [type]
        case .array:
            let values = try stringArray(value)
            guard !values.isEmpty else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
            return values
        default:
            throw ProviderJSONSchemaValidationError.invalidSchema
        }
    }

    private static func stringArray(_ value: JSONValue) throws -> [String] {
        guard case let .array(values) = value else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }
        return try values.map { value in
            guard case let .string(string) = value else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
            return string
        }
    }

    private static func optionalNonnegativeInt(_ value: JSONValue?) throws -> Int? {
        guard let value else { return nil }
        return try nonnegativeInt(value)
    }

    private static func nonnegativeInt(_ value: JSONValue) throws -> Int {
        guard case let .number(number) = value else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }
        let parsed: Int?
        switch number {
        case let .integer(value):
            parsed = Int(exactly: value)
        case let .unsignedInteger(value):
            parsed = Int(exactly: value)
        case let .floatingPoint(value):
            parsed = value.isFinite && value.rounded(.towardZero) == value
                ? Int(exactly: value)
                : nil
        }
        guard let parsed, parsed >= 0 else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }
        return parsed
    }

    private static func schemaNumber(_ value: JSONValue) throws -> JSONNumber {
        guard case let .number(number) = value, isFinite(number) else {
            throw ProviderJSONSchemaValidationError.invalidSchema
        }
        return number
    }

    private static func isFinite(_ number: JSONNumber) -> Bool {
        switch number {
        case .integer, .unsignedInteger:
            return true
        case let .floatingPoint(value):
            return value.isFinite
        }
    }

    private static func typeMatches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string),
             ("array", .array), ("object", .object), ("number", .number):
            return true
        case ("integer", .number(.integer)), ("integer", .number(.unsignedInteger)):
            return true
        case let ("integer", .number(.floatingPoint(number))):
            return number.isFinite && number.rounded(.towardZero) == number
        default:
            return false
        }
    }

    private enum NumericOrdering: Equatable {
        case less
        case equal
        case greater

        var inverted: NumericOrdering {
            switch self {
            case .less: .greater
            case .equal: .equal
            case .greater: .less
            }
        }
    }

    /// Compares the mathematical JSON-number values without first converting
    /// 64-bit integers to Double. That preserves UInt64.max and Int64 edges.
    private static func compare(
        _ lhs: JSONNumber,
        _ rhs: JSONNumber
    ) -> NumericOrdering {
        switch (lhs, rhs) {
        case let (.integer(left), .integer(right)):
            return ordering(left, right)
        case let (.unsignedInteger(left), .unsignedInteger(right)):
            return ordering(left, right)
        case let (.integer(left), .unsignedInteger(right)):
            guard left >= 0 else { return .less }
            return ordering(UInt64(left), right)
        case let (.unsignedInteger(left), .integer(right)):
            guard right >= 0 else { return .greater }
            return ordering(left, UInt64(right))
        case let (.integer(left), .floatingPoint(right)):
            return compare(left, to: right)
        case let (.floatingPoint(left), .integer(right)):
            return compare(right, to: left).inverted
        case let (.unsignedInteger(left), .floatingPoint(right)):
            return compare(left, to: right)
        case let (.floatingPoint(left), .unsignedInteger(right)):
            return compare(right, to: left).inverted
        case let (.floatingPoint(left), .floatingPoint(right)):
            return ordering(left, right)
        }
    }

    private static func compare(_ lhs: Int64, to rhs: Double) -> NumericOrdering {
        // Schema and instance preflight reject non-finite values before here.
        let lowerBound = -9_223_372_036_854_775_808.0
        let upperBound = 9_223_372_036_854_775_808.0
        if rhs < lowerBound { return .greater }
        if rhs >= upperBound { return .less }

        let truncated = Int64(rhs)
        let integerOrdering = ordering(lhs, truncated)
        guard integerOrdering == .equal else { return integerOrdering }
        let exactInteger = Double(truncated)
        if rhs == exactInteger { return .equal }
        return rhs > exactInteger ? .less : .greater
    }

    private static func compare(_ lhs: UInt64, to rhs: Double) -> NumericOrdering {
        // 2^64 is exactly representable; every UInt64 value is below it.
        let upperBound = 18_446_744_073_709_551_616.0
        if rhs < 0 { return .greater }
        if rhs >= upperBound { return .less }

        let truncated = UInt64(rhs)
        let integerOrdering = ordering(lhs, truncated)
        guard integerOrdering == .equal else { return integerOrdering }
        let exactInteger = Double(truncated)
        if rhs == exactInteger { return .equal }
        return .less
    }

    private static func ordering<T: Comparable>(_ lhs: T, _ rhs: T) -> NumericOrdering {
        if lhs < rhs { return .less }
        if lhs > rhs { return .greater }
        return .equal
    }

    private indirect enum SemanticJSONKey: Hashable {
        case null
        case bool(Bool)
        case number(SemanticNumberKey)
        case string(String)
        case array([SemanticJSONKey])
        case object([SemanticObjectEntry])
    }

    private enum SemanticNumberKey: Hashable {
        case negativeInteger(UInt64)
        case nonnegativeInteger(UInt64)
        case floatingPoint(UInt64)
    }

    private struct SemanticObjectEntry: Hashable {
        let key: String
        let value: SemanticJSONKey
    }

    /// Produces a canonical equality key where numerically equal signed,
    /// unsigned, and exactly-integral Double representations are identical.
    private static func semanticKey(
        _ value: JSONValue,
        remaining: inout Int
    ) throws -> SemanticJSONKey {
        try consumeWorkUnit(remaining: &remaining)
        switch value {
        case .null:
            return .null
        case let .bool(value):
            return .bool(value)
        case let .number(value):
            return .number(try semanticNumberKey(value))
        case let .string(value):
            return .string(value)
        case let .array(values):
            var result: [SemanticJSONKey] = []
            result.reserveCapacity(values.count)
            for value in values {
                result.append(try semanticKey(value, remaining: &remaining))
            }
            return .array(result)
        case let .object(values):
            var result: [SemanticObjectEntry] = []
            result.reserveCapacity(values.count)
            for key in values.keys.sorted() {
                guard let value = values[key] else {
                    throw ProviderJSONSchemaValidationError.invalidSchema
                }
                result.append(SemanticObjectEntry(
                    key: key,
                    value: try semanticKey(value, remaining: &remaining)
                ))
            }
            return .object(result)
        }
    }

    private static func semanticNumberKey(
        _ number: JSONNumber
    ) throws -> SemanticNumberKey {
        switch number {
        case let .integer(value):
            if value < 0 { return .negativeInteger(value.magnitude) }
            return .nonnegativeInteger(UInt64(value))
        case let .unsignedInteger(value):
            return .nonnegativeInteger(value)
        case let .floatingPoint(value):
            guard value.isFinite else {
                throw ProviderJSONSchemaValidationError.invalidSchema
            }
            if let signed = Int64(exactly: value) {
                if signed < 0 { return .negativeInteger(signed.magnitude) }
                return .nonnegativeInteger(UInt64(signed))
            }
            if let unsigned = UInt64(exactly: value) {
                return .nonnegativeInteger(unsigned)
            }
            // Equal finite Double values have the same bit pattern except
            // signed zero, which the integral cases above canonicalize to 0.
            return .floatingPoint(value.bitPattern)
        }
    }
}
