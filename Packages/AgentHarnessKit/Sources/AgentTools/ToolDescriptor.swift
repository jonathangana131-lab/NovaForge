import AgentDomain
import Foundation

public struct ToolVersion: Codable, Comparable, CustomStringConvertible, Hashable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: ToolVersion, rhs: ToolVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

public enum ToolApprovalClass: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case implicitUserAuthorizationEligible
    case explicit
    case alwaysDenied
}

public enum ToolParallelSafety: String, Codable, CaseIterable, Hashable, Sendable {
    case parallelRead
    case workspaceSerialized
    case globallySerialized
    case denied
}

public enum ToolCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case workspaceRead
    case workspaceWrite
    case sandboxCommand
    case htmlValidation
}

public struct ToolAvailabilityRequirement: Hashable, Sendable {
    public let allowedLocalities: [ToolExecutionLocality]
    public let requiredCapabilities: [ToolCapability]
    public let requiresWorkspace: Bool

    public init(
        allowedLocalities: [ToolExecutionLocality],
        requiredCapabilities: [ToolCapability],
        requiresWorkspace: Bool
    ) {
        self.allowedLocalities = allowedLocalities
        self.requiredCapabilities = requiredCapabilities
        self.requiresWorkspace = requiresWorkspace
    }

    public func evaluate(in context: ToolAvailabilityContext) -> ToolAvailabilityDecision {
        var failures: [ToolAvailabilityFailure] = []
        if !allowedLocalities.contains(.either), !allowedLocalities.contains(context.locality) {
            failures.append(.unsupportedLocality)
        }
        if requiresWorkspace, !context.hasWorkspace {
            failures.append(.workspaceUnavailable)
        }
        for capability in requiredCapabilities.sorted(by: { $0.rawValue < $1.rawValue })
        where !context.capabilities.contains(capability) {
            failures.append(.missingCapability(capability))
        }
        return failures.isEmpty ? .available : .unavailable(failures)
    }
}

public struct ToolAvailabilityContext: Sendable {
    public let locality: ToolExecutionLocality
    public let capabilities: Set<ToolCapability>
    public let hasWorkspace: Bool

    public init(
        locality: ToolExecutionLocality,
        capabilities: Set<ToolCapability>,
        hasWorkspace: Bool
    ) {
        self.locality = locality
        self.capabilities = capabilities
        self.hasWorkspace = hasWorkspace
    }
}

public enum ToolAvailabilityFailure: Equatable, Sendable {
    case unsupportedLocality
    case workspaceUnavailable
    case missingCapability(ToolCapability)
}

public enum ToolAvailabilityDecision: Equatable, Sendable {
    case available
    case unavailable([ToolAvailabilityFailure])

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

public enum ToolTargetAccess: String, Codable, CaseIterable, Hashable, Sendable {
    case inspect
    case read
    case write
    case delete
    case source
    case destination
}

public struct ToolTargetRule: Hashable, Sendable {
    public let argumentPath: [String]
    public let access: ToolTargetAccess
    public let optional: Bool
    public let defaultValue: String?

    public init(
        argumentPath: [String],
        access: ToolTargetAccess,
        optional: Bool = false,
        defaultValue: String? = nil
    ) {
        self.argumentPath = argumentPath
        self.access = access
        self.optional = optional
        self.defaultValue = defaultValue
    }
}

public enum ToolTargetStrategy: Hashable, Sendable {
    case workspaceRoot(access: ToolTargetAccess)
    case argumentPaths([ToolTargetRule])
    case arrayArgumentPaths(
        arrayPath: [String],
        elementRules: [ToolTargetRule]
    )
    case legacyCommandParserRequired
}

public struct ToolTarget: Equatable, Sendable {
    public let value: String
    public let access: ToolTargetAccess

    public init(value: String, access: ToolTargetAccess) {
        self.value = value
        self.access = access
    }
}

public enum ToolTargetExtractionError: Error, Equatable, Sendable {
    case missingTarget([String])
    case nonStringTarget([String])
    case nonArrayTarget([String])
    case requiresLegacyCommandParser
}

public struct ToolLimits: Hashable, Sendable {
    public let timeoutMilliseconds: Int
    public let maximumArgumentBytes: Int
    public let maximumOutputBytes: Int

    public init(
        timeoutMilliseconds: Int,
        maximumArgumentBytes: Int,
        maximumOutputBytes: Int
    ) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumArgumentBytes = maximumArgumentBytes
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public enum ToolUICategory: String, Codable, CaseIterable, Hashable, Sendable {
    case inspect
    case edit
    case organize
    case validate
    case command
}

public enum ToolUIResultPresentation: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case fileContent
    case directory
    case diff
    case validation
    case commandOutput
}

public struct ToolUIMetadata: Hashable, Sendable {
    public let title: String
    public let systemImageName: String
    public let category: ToolUICategory
    public let resultPresentation: ToolUIResultPresentation

    public init(
        title: String,
        systemImageName: String,
        category: ToolUICategory,
        resultPresentation: ToolUIResultPresentation
    ) {
        self.title = title
        self.systemImageName = systemImageName
        self.category = category
        self.resultPresentation = resultPresentation
    }
}

/// A UI-facing projection generated from the same descriptor used for providers and dispatch.
public struct ToolUIDefinition: Hashable, Sendable {
    public let identity: ToolIdentity
    public let metadata: ToolUIMetadata
    public let effectClass: ToolEffectClass
    public let approvalClass: ToolApprovalClass
    public let isAvailable: Bool

    public init(descriptor: ToolDescriptor, isAvailable: Bool) {
        identity = descriptor.identity
        metadata = descriptor.ui
        effectClass = descriptor.effectClass
        approvalClass = descriptor.approvalClass
        self.isAvailable = isAvailable
    }
}

public struct ToolReceiptMetadata: Hashable, Sendable {
    public let actionVerb: String
    public let successSummary: String

    public init(actionVerb: String, successSummary: String) {
        self.actionVerb = actionVerb
        self.successSummary = successSummary
    }
}

public enum ToolEvidenceMapping: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case inspectedPath
    case changedPath
    case deletedPath
    case movedPath
    case copiedPath
    case validationReport
    case commandTranscript
}

public struct ToolArgumentRedactionRule: Hashable, Sendable {
    /// Object keys, numeric array indexes, or `*` for every array element.
    public let path: [String]
    public let replacement: JSONValue

    public init(path: [String], replacement: JSONValue = .string("<redacted>")) {
        self.path = path
        self.replacement = replacement
    }
}

public enum ToolOutputRedaction: Hashable, Sendable {
    case none
    case replace(JSONValue)
}

public struct ToolRedactionPolicy: Hashable, Sendable {
    public let argumentRules: [ToolArgumentRedactionRule]
    public let output: ToolOutputRedaction

    public init(argumentRules: [ToolArgumentRedactionRule], output: ToolOutputRedaction) {
        self.argumentRules = argumentRules
        self.output = output
    }

    public func redact(arguments: JSONValue) -> JSONValue {
        argumentRules.reduce(arguments) { value, rule in
            Self.replacing(value, at: rule.path[...], with: rule.replacement)
        }
    }

    public func redact(output value: JSONValue) -> JSONValue {
        switch output {
        case .none:
            return value
        case let .replace(replacement):
            return replacement
        }
    }

    private static func replacing(
        _ value: JSONValue,
        at path: ArraySlice<String>,
        with replacement: JSONValue
    ) -> JSONValue {
        guard let component = path.first else { return replacement }
        let remainder = path.dropFirst()
        switch value {
        case .object(var object):
            guard let child = object[component] else { return value }
            object[component] = replacing(child, at: remainder, with: replacement)
            return .object(object)

        case let .array(array) where component == "*":
            return .array(array.map { replacing($0, at: remainder, with: replacement) })

        case .array(var array):
            guard let index = Int(component), array.indices.contains(index) else { return value }
            array[index] = replacing(array[index], at: remainder, with: replacement)
            return .array(array)

        default:
            return value
        }
    }
}

public struct LegacySandboxAdapterMetadata: Hashable, Sendable {
    public let executorName: String
    public let supportedMajorVersion: Int

    public init(executorName: String, supportedMajorVersion: Int) {
        self.executorName = executorName
        self.supportedMajorVersion = supportedMajorVersion
    }
}

public enum LegacyArgumentEncoding: String, Codable, CaseIterable, Hashable, Sendable {
    case string
    case booleanString
    case integerString
    case numberString
    case canonicalJSON

    static func inferred(from schema: JSONSchema) -> LegacyArgumentEncoding {
        switch schema {
        case .string: return .string
        case .boolean: return .booleanString
        case .integer: return .integerString
        case .number: return .numberString
        case let .oneOf(_, schemas):
            let nonNull = schemas.filter {
                if case .null = $0 { return false }
                return true
            }
            return nonNull.count == 1 ? inferred(from: nonNull[0]) : .canonicalJSON
        case .null, .array, .object:
            return .canonicalJSON
        }
    }
}

public struct LegacyArgumentMapping: Hashable, Sendable {
    public let argumentName: String
    public let encoding: LegacyArgumentEncoding
    public let omitIfNull: Bool

    public init(argumentName: String, encoding: LegacyArgumentEncoding, omitIfNull: Bool = true) {
        self.argumentName = argumentName
        self.encoding = encoding
        self.omitIfNull = omitIfNull
    }
}

public struct LegacySandboxToolAdapterContract: Hashable, Sendable {
    public let executorName: String
    public let supportedMajorVersion: Int
    public let fieldMappings: [LegacyArgumentMapping]

    init(metadata: LegacySandboxAdapterMetadata, argumentSchema: JSONSchema) {
        executorName = metadata.executorName
        supportedMajorVersion = metadata.supportedMajorVersion
        if case let .object(_, properties, _, _) = argumentSchema {
            fieldMappings = properties.keys.sorted().compactMap { name in
                properties[name].map {
                    LegacyArgumentMapping(
                        argumentName: name,
                        encoding: .inferred(from: $0),
                        omitIfNull: true
                    )
                }
            }
        } else {
            fieldMappings = []
        }
    }
}

public struct ToolDescriptorMetadata: Hashable, Sendable {
    public let name: String
    public let version: ToolVersion
    public let aliases: [String]
    public let toolset: String
    public let description: String
    public let availability: ToolAvailabilityRequirement
    public let effectClass: ToolEffectClass
    public let approvalClass: ToolApprovalClass
    public let targetStrategy: ToolTargetStrategy
    public let parallelSafety: ToolParallelSafety
    public let concurrencyKey: String?
    public let limits: ToolLimits
    public let redaction: ToolRedactionPolicy
    public let legacyAdapter: LegacySandboxAdapterMetadata?
    public let receipt: ToolReceiptMetadata
    public let evidence: ToolEvidenceMapping
    public let ui: ToolUIMetadata

    public init(
        name: String,
        version: ToolVersion,
        aliases: [String] = [],
        toolset: String,
        description: String,
        availability: ToolAvailabilityRequirement,
        effectClass: ToolEffectClass,
        approvalClass: ToolApprovalClass,
        targetStrategy: ToolTargetStrategy,
        parallelSafety: ToolParallelSafety,
        concurrencyKey: String?,
        limits: ToolLimits,
        redaction: ToolRedactionPolicy,
        legacyAdapter: LegacySandboxAdapterMetadata?,
        receipt: ToolReceiptMetadata,
        evidence: ToolEvidenceMapping,
        ui: ToolUIMetadata
    ) {
        self.name = name
        self.version = version
        self.aliases = aliases
        self.toolset = toolset
        self.description = description
        self.availability = availability
        self.effectClass = effectClass
        self.approvalClass = approvalClass
        self.targetStrategy = targetStrategy
        self.parallelSafety = parallelSafety
        self.concurrencyKey = concurrencyKey
        self.limits = limits
        self.redaction = redaction
        self.legacyAdapter = legacyAdapter
        self.receipt = receipt
        self.evidence = evidence
        self.ui = ui
    }
}

public struct ToolDescriptor: Hashable, Sendable {
    public let name: String
    public let version: ToolVersion
    public let aliases: [String]
    public let toolset: String
    public let description: String
    public let argumentSchema: JSONSchema
    public let availability: ToolAvailabilityRequirement
    public let effectClass: ToolEffectClass
    public let approvalClass: ToolApprovalClass
    public let targetStrategy: ToolTargetStrategy
    public let parallelSafety: ToolParallelSafety
    public let concurrencyKey: String?
    public let limits: ToolLimits
    public let redaction: ToolRedactionPolicy
    public let legacyAdapter: LegacySandboxToolAdapterContract?
    public let receipt: ToolReceiptMetadata
    public let evidence: ToolEvidenceMapping
    public let ui: ToolUIMetadata

    public init(metadata: ToolDescriptorMetadata, argumentSchema: JSONSchema) {
        name = metadata.name
        version = metadata.version
        aliases = metadata.aliases
        toolset = metadata.toolset
        description = metadata.description
        self.argumentSchema = argumentSchema
        availability = metadata.availability
        effectClass = metadata.effectClass
        approvalClass = metadata.approvalClass
        targetStrategy = metadata.targetStrategy
        parallelSafety = metadata.parallelSafety
        concurrencyKey = metadata.concurrencyKey
        limits = metadata.limits
        redaction = metadata.redaction
        legacyAdapter = metadata.legacyAdapter.map {
            LegacySandboxToolAdapterContract(metadata: $0, argumentSchema: argumentSchema)
        }
        receipt = metadata.receipt
        evidence = metadata.evidence
        ui = metadata.ui
    }

    public var identity: ToolIdentity {
        .init(name: name, version: version.description)
    }

    public func extractTargets(from arguments: JSONValue) throws -> [ToolTarget] {
        try ToolArgumentValidator.validate(arguments, against: argumentSchema)
        switch targetStrategy {
        case let .workspaceRoot(access):
            return [.init(value: "", access: access)]

        case .legacyCommandParserRequired:
            throw ToolTargetExtractionError.requiresLegacyCommandParser

        case let .argumentPaths(rules):
            return try extractTargets(rules: rules, from: arguments)

        case let .arrayArgumentPaths(arrayPath, elementRules):
            guard let value = value(at: arrayPath[...], in: arguments) else {
                throw ToolTargetExtractionError.missingTarget(arrayPath)
            }
            guard case let .array(elements) = value else {
                throw ToolTargetExtractionError.nonArrayTarget(arrayPath)
            }
            return try elements.flatMap {
                try extractTargets(rules: elementRules, from: $0)
            }
        }
    }

    private func extractTargets(
        rules: [ToolTargetRule],
        from arguments: JSONValue
    ) throws -> [ToolTarget] {
        try rules.compactMap { rule in
            guard let value = value(
                at: rule.argumentPath[...],
                in: arguments
            ) else {
                if let defaultValue = rule.defaultValue {
                    return ToolTarget(value: defaultValue, access: rule.access)
                }
                if rule.optional { return nil }
                throw ToolTargetExtractionError.missingTarget(rule.argumentPath)
            }
            if case .null = value {
                if let defaultValue = rule.defaultValue {
                    return ToolTarget(value: defaultValue, access: rule.access)
                }
                if rule.optional { return nil }
            }
            guard case let .string(target) = value else {
                throw ToolTargetExtractionError.nonStringTarget(
                    rule.argumentPath
                )
            }
            return ToolTarget(value: target, access: rule.access)
        }
    }

    private func value(at path: ArraySlice<String>, in value: JSONValue) -> JSONValue? {
        guard let component = path.first else { return value }
        guard case let .object(object) = value, let child = object[component] else { return nil }
        return self.value(at: path.dropFirst(), in: child)
    }
}

public struct ProviderToolDefinition: Codable, Equatable, Sendable {
    public struct Function: Codable, Equatable, Sendable {
        public let name: String
        public let description: String
        public let parameters: JSONValue
        public let strict: Bool
    }

    public let type: String
    public let function: Function

    public init(descriptor: ToolDescriptor) {
        type = "function"
        function = .init(
            name: descriptor.name,
            description: descriptor.description,
            parameters: descriptor.argumentSchema.strictProviderValue,
            strict: true
        )
    }
}
