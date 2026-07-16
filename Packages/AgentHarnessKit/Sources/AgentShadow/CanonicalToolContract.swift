import AgentDomain
import AgentTools
import Foundation

enum CanonicalToolContract {
    static func sha256(_ descriptor: ToolDescriptor) throws -> String {
        try CanonicalShadowDigest.sha256(
            domain: .toolContract,
            Material(descriptor: descriptor)
        )
    }

    private struct Material: Codable {
        let identity: ToolIdentity
        let aliases: [String]
        let toolset: String
        let description: String
        let argumentSchema: JSONValue
        let availability: Availability
        let effectClass: ToolEffectClass
        let approvalClass: ToolApprovalClass
        let targetStrategy: TargetStrategy
        let parallelSafety: ToolParallelSafety
        let concurrencyKey: String?
        let limits: Limits
        let redaction: Redaction
        let legacyAdapter: LegacyAdapter?
        let receipt: Receipt
        let evidence: ToolEvidenceMapping
        let ui: UI

        init(descriptor: ToolDescriptor) {
            identity = descriptor.identity
            aliases = descriptor.aliases.sorted()
            toolset = descriptor.toolset
            description = descriptor.description
            argumentSchema = descriptor.argumentSchema.providerValue
            availability = Availability(descriptor.availability)
            effectClass = descriptor.effectClass
            approvalClass = descriptor.approvalClass
            targetStrategy = TargetStrategy(descriptor.targetStrategy)
            parallelSafety = descriptor.parallelSafety
            concurrencyKey = descriptor.concurrencyKey
            limits = Limits(descriptor.limits)
            redaction = Redaction(descriptor.redaction)
            legacyAdapter = descriptor.legacyAdapter.map(LegacyAdapter.init)
            receipt = Receipt(descriptor.receipt)
            evidence = descriptor.evidence
            ui = UI(descriptor.ui)
        }
    }

    private struct Availability: Codable {
        let allowedLocalities: [ToolExecutionLocality]
        let requiredCapabilities: [ToolCapability]
        let requiresWorkspace: Bool

        init(_ value: ToolAvailabilityRequirement) {
            allowedLocalities = value.allowedLocalities.sorted { $0.rawValue < $1.rawValue }
            requiredCapabilities = value.requiredCapabilities.sorted { $0.rawValue < $1.rawValue }
            requiresWorkspace = value.requiresWorkspace
        }
    }

    private enum TargetStrategy: Codable {
        case workspaceRoot(ToolTargetAccess)
        case argumentPaths([TargetRule])
        case arrayArgumentPaths([String], [TargetRule])
        case legacyCommandParserRequired

        init(_ value: ToolTargetStrategy) {
            switch value {
            case let .workspaceRoot(access): self = .workspaceRoot(access)
            case let .argumentPaths(rules): self = .argumentPaths(rules.map(TargetRule.init))
            case let .arrayArgumentPaths(path, rules):
                self = .arrayArgumentPaths(path, rules.map(TargetRule.init))
            case .legacyCommandParserRequired: self = .legacyCommandParserRequired
            }
        }
    }

    private struct TargetRule: Codable {
        let argumentPath: [String]
        let access: ToolTargetAccess
        let optional: Bool
        let defaultValue: String?

        init(_ value: ToolTargetRule) {
            argumentPath = value.argumentPath
            access = value.access
            optional = value.optional
            defaultValue = value.defaultValue
        }
    }

    private struct Limits: Codable {
        let timeoutMilliseconds: Int
        let maximumArgumentBytes: Int
        let maximumOutputBytes: Int

        init(_ value: ToolLimits) {
            timeoutMilliseconds = value.timeoutMilliseconds
            maximumArgumentBytes = value.maximumArgumentBytes
            maximumOutputBytes = value.maximumOutputBytes
        }
    }

    private struct Redaction: Codable {
        let argumentRules: [RedactionRule]
        let output: OutputRedaction

        init(_ value: ToolRedactionPolicy) {
            argumentRules = value.argumentRules.map(RedactionRule.init)
            output = OutputRedaction(value.output)
        }
    }

    private struct RedactionRule: Codable {
        let path: [String]
        let replacement: JSONValue

        init(_ value: ToolArgumentRedactionRule) {
            path = value.path
            replacement = value.replacement
        }
    }

    private enum OutputRedaction: Codable {
        case none
        case replace(JSONValue)

        init(_ value: ToolOutputRedaction) {
            switch value {
            case .none: self = .none
            case let .replace(replacement): self = .replace(replacement)
            }
        }
    }

    private struct LegacyAdapter: Codable {
        let executorName: String
        let supportedMajorVersion: Int
        let fieldMappings: [LegacyMapping]

        init(_ value: LegacySandboxToolAdapterContract) {
            executorName = value.executorName
            supportedMajorVersion = value.supportedMajorVersion
            fieldMappings = value.fieldMappings.map(LegacyMapping.init)
        }
    }

    private struct LegacyMapping: Codable {
        let argumentName: String
        let encoding: LegacyArgumentEncoding
        let omitIfNull: Bool

        init(_ value: LegacyArgumentMapping) {
            argumentName = value.argumentName
            encoding = value.encoding
            omitIfNull = value.omitIfNull
        }
    }

    private struct Receipt: Codable {
        let actionVerb: String
        let successSummary: String

        init(_ value: ToolReceiptMetadata) {
            actionVerb = value.actionVerb
            successSummary = value.successSummary
        }
    }

    private struct UI: Codable {
        let title: String
        let systemImageName: String
        let category: ToolUICategory
        let resultPresentation: ToolUIResultPresentation

        init(_ value: ToolUIMetadata) {
            title = value.title
            systemImageName = value.systemImageName
            category = value.category
            resultPresentation = value.resultPresentation
        }
    }
}
