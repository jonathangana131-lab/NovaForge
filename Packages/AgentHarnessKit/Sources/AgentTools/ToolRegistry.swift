import AgentDomain
import Foundation

public enum ToolRegistryError: Error, Equatable, Sendable {
    case invalidName(String)
    case invalidVersion(name: String, version: ToolVersion)
    case duplicateCanonicalName(String)
    case aliasCollision(String)
    case nonObjectArguments(String)
    case invalidRequiredField(tool: String, field: String)
    case duplicateRequiredField(tool: String, field: String)
    case strictOptionalMustAcceptNull(tool: String, field: String)
    case invalidBounds(tool: String)
    case invalidLimits(tool: String)
    case invalidRedactionPath(tool: String, path: [String])
    case invalidTargetPath(tool: String, path: [String])
    case legacyMajorVersionMismatch(tool: String, descriptorMajor: Int, adapterMajor: Int)
    case incompleteLegacyMapping(tool: String)
    case incompatibleApproval(tool: String)
    case unknownTool(String)
    case unsupportedVersion(tool: String, requested: String, available: String)
}

/// An immutable registry of the active executable tool versions.
///
/// Exactly one version may execute for a canonical name. Historical `ToolIdentity` values
/// remain replayable ledger data, but are never dispatched through this registry; resuming
/// an old contract requires an explicit, audited migration into the active version.
public struct ToolRegistry: Sendable {
    private let toolsByCanonicalName: [String: AnyAgentTool]
    private let canonicalNameByAlias: [String: String]
    public let descriptors: [ToolDescriptor]

    public init(tools: [AnyAgentTool]) throws {
        var byName: [String: AnyAgentTool] = [:]
        var aliases: [String: String] = [:]

        for tool in tools {
            try Self.validate(tool.descriptor)
            let name = tool.descriptor.name
            guard byName[name] == nil else {
                throw ToolRegistryError.duplicateCanonicalName(name)
            }
            byName[name] = tool
        }

        let canonicalNames = Set(byName.keys)
        for tool in tools.sorted(by: { $0.descriptor.name < $1.descriptor.name }) {
            for alias in tool.descriptor.aliases.sorted() {
                guard !canonicalNames.contains(alias), aliases[alias] == nil else {
                    throw ToolRegistryError.aliasCollision(alias)
                }
                aliases[alias] = tool.descriptor.name
            }
        }

        toolsByCanonicalName = byName
        canonicalNameByAlias = aliases
        descriptors = tools.map(\.descriptor).sorted { lhs, rhs in
            if lhs.name == rhs.name { return lhs.version < rhs.version }
            return lhs.name < rhs.name
        }
    }

    public func descriptor(named nameOrAlias: String) throws -> ToolDescriptor {
        try resolve(nameOrAlias).descriptor
    }

    public func resolve(_ nameOrAlias: String, version: String? = nil) throws -> AnyAgentTool {
        let canonicalName = canonicalNameByAlias[nameOrAlias] ?? nameOrAlias
        guard let tool = toolsByCanonicalName[canonicalName] else {
            throw ToolRegistryError.unknownTool(nameOrAlias)
        }
        if let version, version != tool.descriptor.version.description {
            throw ToolRegistryError.unsupportedVersion(
                tool: tool.descriptor.name,
                requested: version,
                available: tool.descriptor.version.description
            )
        }
        return tool
    }

    public func decode(
        name nameOrAlias: String,
        version: String? = nil,
        arguments: JSONValue
    ) throws -> DecodedToolArguments {
        let tool = try resolve(nameOrAlias, version: version)
        try ToolArgumentValidator.validate(arguments, against: tool.descriptor.argumentSchema)
        try validateArgumentSize(arguments, descriptor: tool.descriptor)
        return try tool.decodeArguments(arguments)
    }

    public func providerDefinitions(
        availableIn context: ToolAvailabilityContext? = nil
    ) -> [ProviderToolDefinition] {
        descriptors
            .filter { descriptor in
                guard let context else { return true }
                return descriptor.availability.evaluate(in: context).isAvailable
            }
            .map(ProviderToolDefinition.init(descriptor:))
    }

    public func providerDefinitionsData(
        availableIn context: ToolAvailabilityContext? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(providerDefinitions(availableIn: context))
    }

    public func uiDefinitions(
        availability context: ToolAvailabilityContext? = nil
    ) -> [ToolUIDefinition] {
        descriptors.map { descriptor in
            ToolUIDefinition(
                descriptor: descriptor,
                isAvailable: context.map { descriptor.availability.evaluate(in: $0).isAvailable } ?? true
            )
        }
    }

    public func legacyRequest(
        name nameOrAlias: String,
        version: String? = nil,
        arguments: JSONValue
    ) throws -> LegacySandboxToolRequest {
        let tool = try resolve(nameOrAlias, version: version)
        try ToolArgumentValidator.validate(arguments, against: tool.descriptor.argumentSchema)
        try validateArgumentSize(arguments, descriptor: tool.descriptor)
        return try LegacySandboxToolAdapter.makeRequest(
            descriptor: tool.descriptor,
            arguments: arguments
        )
    }

    private func validateArgumentSize(
        _ arguments: JSONValue,
        descriptor: ToolDescriptor
    ) throws {
        let byteCount = try AgentToolJSON.data(for: arguments).count
        guard byteCount <= descriptor.limits.maximumArgumentBytes else {
            throw ToolArgumentValidationError(issues: [
                .init(
                    code: .tooLong,
                    path: [],
                    message: "Tool arguments exceed the descriptor's byte limit."
                ),
            ])
        }
    }

    private static func validate(_ descriptor: ToolDescriptor) throws {
        guard validToolName(descriptor.name) else {
            throw ToolRegistryError.invalidName(descriptor.name)
        }
        for alias in descriptor.aliases where !validToolName(alias) {
            throw ToolRegistryError.invalidName(alias)
        }
        guard descriptor.version.major > 0,
              descriptor.version.minor >= 0,
              descriptor.version.patch >= 0 else {
            throw ToolRegistryError.invalidVersion(name: descriptor.name, version: descriptor.version)
        }
        guard case let .object(_, properties, required, _) = descriptor.argumentSchema else {
            throw ToolRegistryError.nonObjectArguments(descriptor.name)
        }
        var seenRequired: Set<String> = []
        for field in required {
            guard properties[field] != nil else {
                throw ToolRegistryError.invalidRequiredField(tool: descriptor.name, field: field)
            }
            guard seenRequired.insert(field).inserted else {
                throw ToolRegistryError.duplicateRequiredField(tool: descriptor.name, field: field)
            }
        }
        for field in properties.keys where !seenRequired.contains(field) {
            guard properties[field]?.acceptsNull == true else {
                throw ToolRegistryError.strictOptionalMustAcceptNull(tool: descriptor.name, field: field)
            }
        }
        guard validBounds(in: descriptor.argumentSchema) else {
            throw ToolRegistryError.invalidBounds(tool: descriptor.name)
        }
        guard descriptor.limits.timeoutMilliseconds > 0,
              descriptor.limits.maximumArgumentBytes > 0,
              descriptor.limits.maximumOutputBytes > 0 else {
            throw ToolRegistryError.invalidLimits(tool: descriptor.name)
        }
        for rule in descriptor.redaction.argumentRules {
            guard !rule.path.isEmpty,
                  schema(
                    at: rule.path[...],
                    in: descriptor.argumentSchema,
                    allowArrayTraversal: true
                  ) != nil else {
                throw ToolRegistryError.invalidRedactionPath(tool: descriptor.name, path: rule.path)
            }
        }
        if case let .argumentPaths(rules) = descriptor.targetStrategy {
            for rule in rules {
                guard !rule.argumentPath.isEmpty,
                      let targetSchema = schema(
                        at: rule.argumentPath[...],
                        in: descriptor.argumentSchema,
                        allowArrayTraversal: false
                      ),
                      isStringTargetSchema(targetSchema) else {
                    throw ToolRegistryError.invalidTargetPath(
                        tool: descriptor.name,
                        path: rule.argumentPath
                    )
                }
            }
        }
        if descriptor.effectClass == .unrecoverableDenied,
           descriptor.approvalClass != .alwaysDenied {
            throw ToolRegistryError.incompatibleApproval(tool: descriptor.name)
        }
        if let legacy = descriptor.legacyAdapter {
            guard legacy.supportedMajorVersion == descriptor.version.major else {
                throw ToolRegistryError.legacyMajorVersionMismatch(
                    tool: descriptor.name,
                    descriptorMajor: descriptor.version.major,
                    adapterMajor: legacy.supportedMajorVersion
                )
            }
            guard Set(legacy.fieldMappings.map(\.argumentName)) == Set(properties.keys),
                  legacy.fieldMappings.count == properties.count else {
                throw ToolRegistryError.incompleteLegacyMapping(tool: descriptor.name)
            }
        }
    }

    private static func validToolName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count <= 64,
              let first = bytes.first,
              (97...122).contains(first) else { return false }
        return bytes.allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 95
        }
    }

    private static func schema(
        at path: ArraySlice<String>,
        in schema: JSONSchema,
        allowArrayTraversal: Bool
    ) -> JSONSchema? {
        guard let component = path.first else { return schema }
        let remainder = path.dropFirst()
        switch schema {
        case let .object(_, properties, _, _):
            guard let child = properties[component] else { return nil }
            return self.schema(
                at: remainder,
                in: child,
                allowArrayTraversal: allowArrayTraversal
            )
        case let .array(_, items, _, _) where allowArrayTraversal:
            let isNonnegativeIndex = Int(component).map { $0 >= 0 } ?? false
            guard component == "*" || isNonnegativeIndex else { return nil }
            return self.schema(
                at: remainder,
                in: items,
                allowArrayTraversal: allowArrayTraversal
            )
        case let .oneOf(_, schemas):
            let matches = schemas.compactMap {
                self.schema(
                    at: path,
                    in: $0,
                    allowArrayTraversal: allowArrayTraversal
                )
            }
            return matches.count == 1 ? matches[0] : nil
        default:
            return nil
        }
    }

    private static func isStringTargetSchema(_ schema: JSONSchema) -> Bool {
        switch schema {
        case .string:
            return true
        case let .oneOf(_, schemas):
            let nonNull = schemas.filter {
                if case .null = $0 { return false }
                return true
            }
            return nonNull.count == 1 && isStringTargetSchema(nonNull[0])
        default:
            return false
        }
    }

    private static func validBounds(in schema: JSONSchema) -> Bool {
        switch schema {
        case let .integer(_, minimum, maximum):
            return minimum == nil || maximum == nil || minimum! <= maximum!
        case let .number(_, minimum, maximum):
            let finite = [minimum, maximum].compactMap { $0 }.allSatisfy { $0.isFinite }
            return finite && (minimum == nil || maximum == nil || minimum! <= maximum!)
        case let .string(_, minimum, maximum, allowedValues):
            let validRange = (minimum ?? 0) >= 0
                && (maximum ?? 0) >= 0
                && (minimum == nil || maximum == nil || minimum! <= maximum!)
            let uniqueValues = allowedValues.map { !$0.isEmpty && Set($0).count == $0.count } ?? true
            return validRange && uniqueValues
        case let .array(_, items, minimum, maximum):
            return (minimum ?? 0) >= 0
                && (maximum ?? 0) >= 0
                && (minimum == nil || maximum == nil || minimum! <= maximum!)
                && validBounds(in: items)
        case let .object(_, properties, required, additionalProperties):
            let requiredSet = Set(required)
            return !additionalProperties
                && requiredSet.count == required.count
                && required.allSatisfy { properties[$0] != nil }
                && properties.allSatisfy { entry in
                    requiredSet.contains(entry.key) || entry.value.acceptsNull
                }
                && properties.values.allSatisfy { validBounds(in: $0) }
        case let .oneOf(_, schemas):
            return !schemas.isEmpty
                && Set(schemas).count == schemas.count
                && unionBranchesAreDisjoint(schemas)
                && schemas.allSatisfy { validBounds(in: $0) }
        case .null, .boolean:
            return true
        }
    }

    private enum JSONKind: Hashable {
        case null
        case boolean
        case integer
        case floatingPoint
        case string
        case array
        case object
    }

    private static func unionBranchesAreDisjoint(_ schemas: [JSONSchema]) -> Bool {
        var seen: Set<JSONKind> = []
        for schema in schemas {
            let kinds = acceptedKinds(for: schema)
            guard !kinds.isEmpty, seen.isDisjoint(with: kinds) else { return false }
            seen.formUnion(kinds)
        }
        return true
    }

    private static func acceptedKinds(for schema: JSONSchema) -> Set<JSONKind> {
        switch schema {
        case .null: return [.null]
        case .boolean: return [.boolean]
        case .integer: return [.integer]
        case .number: return [.integer, .floatingPoint]
        case .string: return [.string]
        case .array: return [.array]
        case .object: return [.object]
        case let .oneOf(_, schemas):
            return schemas.reduce(into: Set<JSONKind>()) { result, schema in
                result.formUnion(acceptedKinds(for: schema))
            }
        }
    }
}

public struct LegacySandboxToolRequest: Equatable, Sendable {
    public let name: String
    public let arguments: [String: String]

    public init(name: String, arguments: [String: String]) {
        self.name = name
        self.arguments = arguments
    }
}

public enum LegacySandboxAdapterError: Error, Equatable, Sendable {
    case unavailable(tool: String)
    case argumentsMustBeObject
    case missingArgument(String)
    case incompatibleArgument(name: String, encoding: LegacyArgumentEncoding)
}

public enum LegacySandboxToolAdapter {
    public static func makeRequest(
        descriptor: ToolDescriptor,
        arguments: JSONValue
    ) throws -> LegacySandboxToolRequest {
        guard let contract = descriptor.legacyAdapter else {
            throw LegacySandboxAdapterError.unavailable(tool: descriptor.name)
        }
        guard case let .object(object) = arguments else {
            throw LegacySandboxAdapterError.argumentsMustBeObject
        }
        var legacyArguments: [String: String] = [:]
        for mapping in contract.fieldMappings {
            guard let value = object[mapping.argumentName] else { continue }
            if case .null = value, mapping.omitIfNull { continue }
            legacyArguments[mapping.argumentName] = try encode(value, mapping: mapping)
        }
        return .init(name: contract.executorName, arguments: legacyArguments)
    }

    private static func encode(
        _ value: JSONValue,
        mapping: LegacyArgumentMapping
    ) throws -> String {
        switch (mapping.encoding, value) {
        case let (.string, .string(value)):
            return value
        case let (.booleanString, .bool(value)):
            return value ? "true" : "false"
        case let (.integerString, .number(.integer(value))):
            return String(value)
        case let (.integerString, .number(.unsignedInteger(value))):
            return String(value)
        case let (.numberString, .number(.integer(value))):
            return String(value)
        case let (.numberString, .number(.unsignedInteger(value))):
            return String(value)
        case let (.numberString, .number(.floatingPoint(value))):
            return try AgentToolJSON.string(for: .number(.floatingPoint(value)))
        case (.canonicalJSON, _):
            return try AgentToolJSON.string(for: value)
        default:
            throw LegacySandboxAdapterError.incompatibleArgument(
                name: mapping.argumentName,
                encoding: mapping.encoding
            )
        }
    }
}
