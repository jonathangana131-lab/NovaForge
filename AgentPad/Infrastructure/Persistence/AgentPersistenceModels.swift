import AgentDomain
import AgentProviders
import AgentTools
import CryptoKit
import Foundation
import SwiftData

enum AgentRunExecutionCompositionError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt16)
    case unsupportedContextSchema(AgentSchemaVersion)
    case unsafeIdentity(field: String)
    case rawHostPath(field: String)
    case attemptScopedProviderOption(String)
    case invalidProviderOptions
    case nonCanonicalCapabilities
    case duplicateTool(String)
    case toolLocalitySetMismatch
    case invalidToolLocality(String)
    case nonCanonicalTools
    case unknownNamedTool(String)
    case digestMismatch(field: String)
    case runtimeBindingMismatch
}

/// Provider knobs that remain fixed for the complete run.
///
/// Provider continuation IDs and prompt-cache keys are deliberately absent:
/// those values belong to individual durable attempts and may carry opaque
/// provider state. Refusing them here prevents an acceptance record from
/// becoming an accidental credential or request-history side channel.
struct AgentRunProviderOptions: Codable, Equatable, Sendable {
    let maximumOutputTokens: UInt64?
    let temperature: Double?
    let parallelToolCalls: Bool?
    let toolChoice: ProviderToolChoice
    let reasoningSummary: Bool?
    let reasoningEffort: ProviderReasoningEffort?
    let minimumContextWindowTokens: UInt64?

    init(_ options: ProviderGenerationOptions) throws {
        guard options.promptCacheKey == nil else {
            throw AgentRunExecutionCompositionError
                .attemptScopedProviderOption("promptCacheKey")
        }
        guard options.previousResponseID == nil else {
            throw AgentRunExecutionCompositionError
                .attemptScopedProviderOption("previousResponseID")
        }
        maximumOutputTokens = options.maximumOutputTokens
        temperature = options.temperature
        parallelToolCalls = options.parallelToolCalls
        toolChoice = options.toolChoice
        reasoningSummary = options.reasoningSummary
        reasoningEffort = options.reasoningEffort
        minimumContextWindowTokens = options.minimumContextWindowTokens
        try validate()
    }

    fileprivate func validate() throws {
        guard maximumOutputTokens.map({ $0 > 0 }) ?? true,
              minimumContextWindowTokens.map({ $0 > 0 }) ?? true,
              temperature.map({ $0.isFinite && (0 ... 2).contains($0) }) ?? true
        else {
            throw AgentRunExecutionCompositionError.invalidProviderOptions
        }
    }
}

/// One canonical executable tool contract and the locality selected for this
/// run. Tool order is normalized before persistence and is part of the
/// registry digest, so a locality change is a different composition.
struct AgentRunToolExecutionBinding: Codable, Equatable, Sendable {
    let tool: ToolIdentity
    let locality: ToolExecutionLocality

    init(tool: ToolIdentity, locality: ToolExecutionLocality) {
        self.tool = tool
        self.locality = locality
    }
}

/// Current executable dependencies proposed when rebuilding a durable run.
/// This value is never persisted: recovery compares its canonical projection
/// to the immutable acceptance composition before an engine may be created.
struct AgentRunExecutionRuntimeBinding: Sendable {
    let providerRoute: ProviderRoute
    let providerOptions: ProviderGenerationOptions
    let toolRegistry: ToolRegistry
    let toolLocalities: [String: ToolExecutionLocality]
    let policyVersion: String
    let contextPreparationVersion: String
    /// Ephemeral plaintext used only to recompute the acceptance digests.
    /// Neither value is encoded into the durable execution composition.
    let systemInstruction: String?
    let developerInstruction: String?

    init(
        providerRoute: ProviderRoute,
        providerOptions: ProviderGenerationOptions,
        toolRegistry: ToolRegistry,
        toolLocalities: [String: ToolExecutionLocality],
        policyVersion: String,
        contextPreparationVersion: String,
        systemInstruction: String?,
        developerInstruction: String?
    ) {
        self.providerRoute = providerRoute
        self.providerOptions = providerOptions
        self.toolRegistry = toolRegistry
        self.toolLocalities = toolLocalities
        self.policyVersion = policyVersion
        self.contextPreparationVersion = contextPreparationVersion
        self.systemInstruction = systemInstruction
        self.developerInstruction = developerInstruction
    }
}

/// Immutable, credential-free execution inputs accepted for exactly one run.
///
/// The full run context is bound by `runContextDigest` while duplicated typed
/// identities make recovery queries cheap and fail closed if either the
/// context or an indexed column is changed. The route has no endpoint URL or
/// credential field, and the initializer rejects values shaped like raw host
/// paths before any bytes can reach SwiftData.
struct AgentRunExecutionComposition: Codable, Equatable, Sendable {
    static let currentSchemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let runContextSchemaVersion: AgentSchemaVersion
    let runID: RunID
    let conversationID: ConversationID
    let projectID: ProjectID?
    let workspaceID: WorkspaceID
    let executionNodeID: ExecutionNodeID
    let runContextDigest: String
    let providerRoute: ProviderRoute
    let providerOptions: AgentRunProviderOptions
    let tools: [AgentRunToolExecutionBinding]
    let toolRegistryDigest: String
    let toolLocalitiesDigest: String
    let policyVersion: String
    let contextPreparationVersion: String
    /// Optional digests preserve the semantic difference between no
    /// instruction (`nil`) and an explicitly empty instruction (SHA-256 of
    /// empty bytes). Plaintext is accepted transiently by the initializer and
    /// is never retained by this Codable value.
    let systemInstructionDigest: String?
    let developerInstructionDigest: String?

    init(
        context: AgentRunContext,
        providerRoute: ProviderRoute,
        providerOptions: ProviderGenerationOptions,
        toolRegistry: ToolRegistry,
        toolLocalities: [String: ToolExecutionLocality],
        policyVersion: String,
        contextPreparationVersion: String,
        systemInstruction: String?,
        developerInstruction: String?
    ) throws {
        let descriptorNames = Set(toolRegistry.descriptors.map(\.name))
        guard descriptorNames == Set(toolLocalities.keys) else {
            throw AgentRunExecutionCompositionError.toolLocalitySetMismatch
        }
        let canonicalTools = Self.canonicalTools(
            try toolRegistry.descriptors.map { descriptor in
                guard let locality = toolLocalities[descriptor.name] else {
                    throw AgentRunExecutionCompositionError
                        .toolLocalitySetMismatch
                }
                guard descriptor.availability.allowedLocalities.contains(.either) ||
                        descriptor.availability.allowedLocalities.contains(locality)
                else {
                    throw AgentRunExecutionCompositionError
                        .invalidToolLocality(descriptor.name)
                }
                return AgentRunToolExecutionBinding(
                    tool: ToolIdentity(
                        name: descriptor.name,
                        version: descriptor.version.description
                    ),
                    locality: locality
                )
            }
        )
        schemaVersion = Self.currentSchemaVersion
        runContextSchemaVersion = context.schemaVersion
        runID = context.lineage.runID
        conversationID = context.conversationID
        projectID = context.projectID
        workspaceID = context.workspaceID
        executionNodeID = context.executionNodeID
        runContextDigest = try Self.digest(
            context,
            domain: "novaforge-agent-run-context-v1"
        )
        self.providerRoute = providerRoute
        self.providerOptions = try AgentRunProviderOptions(providerOptions)
        self.tools = canonicalTools
        toolRegistryDigest = Self.digestData(
            try toolRegistry.providerDefinitionsData(),
            domain: "novaforge-agent-tool-registry-v1"
        )
        toolLocalitiesDigest = try Self.digest(
            canonicalTools,
            domain: "novaforge-agent-tool-registry-localities-v1"
        )
        self.policyVersion = policyVersion
        self.contextPreparationVersion = contextPreparationVersion
        systemInstructionDigest = systemInstruction.map {
            Self.digestData(
                Data($0.utf8),
                domain: "novaforge-agent-system-instruction-v1"
            )
        }
        developerInstructionDigest = developerInstruction.map {
            Self.digestData(
                Data($0.utf8),
                domain: "novaforge-agent-developer-instruction-v1"
            )
        }
        try validate()
    }

    func validate(matching context: AgentRunContext? = nil) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AgentRunExecutionCompositionError
                .unsupportedSchemaVersion(schemaVersion)
        }
        guard runContextSchemaVersion.canBeDecoded() else {
            throw AgentRunExecutionCompositionError
                .unsupportedContextSchema(runContextSchemaVersion)
        }
        try Self.validateIdentity(
            providerRoute.providerID.rawValue,
            field: "providerID"
        )
        try Self.validateIdentity(
            providerRoute.modelID.rawValue,
            field: "modelID"
        )
        try Self.validateIdentity(
            providerRoute.adapterID.rawValue,
            field: "adapterID"
        )
        try Self.validateIdentity(policyVersion, field: "policyVersion")
        try Self.validateIdentity(
            contextPreparationVersion,
            field: "contextPreparationVersion"
        )
        let capabilities = providerRoute.capabilities.features.values
        guard capabilities == Array(Set(capabilities)).sorted() else {
            throw AgentRunExecutionCompositionError.nonCanonicalCapabilities
        }
        guard providerRoute.capabilities.contextWindowTokens > 0,
              providerRoute.capabilities.maximumOutputTokens > 0
        else {
            throw AgentRunExecutionCompositionError.invalidProviderOptions
        }
        try providerOptions.validate()
        guard providerOptions.maximumOutputTokens.map({
                  $0 <= providerRoute.capabilities.maximumOutputTokens
              }) ?? true,
              providerOptions.minimumContextWindowTokens.map({
                  $0 <= providerRoute.capabilities.contextWindowTokens
              }) ?? true,
              providerOptions.temperature == nil ||
                  providerRoute.capabilities.features.contains(.temperature),
              providerOptions.parallelToolCalls != true ||
                  providerRoute.capabilities.features.contains(.parallelToolCalls),
              providerOptions.reasoningSummary != true ||
                  providerRoute.capabilities.features.contains(.reasoning),
              tools.count <= Int(providerRoute.capabilities.maximumToolDefinitions),
              tools.isEmpty || providerRoute.capabilities.features.contains(.tools)
        else {
            throw AgentRunExecutionCompositionError.invalidProviderOptions
        }

        for binding in tools {
            try Self.validateIdentity(binding.tool.name, field: "tool.name")
            try Self.validateIdentity(binding.tool.version, field: "tool.version")
        }
        let canonicalTools = Self.canonicalTools(tools)
        guard tools == canonicalTools else {
            throw AgentRunExecutionCompositionError.nonCanonicalTools
        }
        for pair in zip(canonicalTools, canonicalTools.dropFirst())
        where pair.0.tool.name == pair.1.tool.name {
            throw AgentRunExecutionCompositionError
                .duplicateTool(pair.0.tool.name)
        }
        guard Self.isSHA256(toolRegistryDigest) else {
            throw AgentRunExecutionCompositionError
                .digestMismatch(field: "toolRegistryDigest")
        }
        let expectedLocalitiesDigest = try Self.digest(
            canonicalTools,
            domain: "novaforge-agent-tool-registry-localities-v1"
        )
        guard toolLocalitiesDigest == expectedLocalitiesDigest else {
            throw AgentRunExecutionCompositionError
                .digestMismatch(field: "toolLocalitiesDigest")
        }
        guard Self.isSHA256(runContextDigest) else {
            throw AgentRunExecutionCompositionError
                .digestMismatch(field: "runContextDigest")
        }
        if let systemInstructionDigest,
           !Self.isSHA256(systemInstructionDigest) {
            throw AgentRunExecutionCompositionError
                .digestMismatch(field: "systemInstructionDigest")
        }
        if let developerInstructionDigest,
           !Self.isSHA256(developerInstructionDigest) {
            throw AgentRunExecutionCompositionError
                .digestMismatch(field: "developerInstructionDigest")
        }
        if case let .named(name) = providerOptions.toolChoice,
           !canonicalTools.contains(where: { $0.tool.name == name }) {
            throw AgentRunExecutionCompositionError.unknownNamedTool(name)
        }

        if let context {
            guard runContextSchemaVersion == context.schemaVersion,
                  runID == context.lineage.runID,
                  conversationID == context.conversationID,
                  projectID == context.projectID,
                  workspaceID == context.workspaceID,
                  executionNodeID == context.executionNodeID,
                  runContextDigest == (try Self.digest(
                      context,
                      domain: "novaforge-agent-run-context-v1"
                  ))
            else {
                throw AgentRunExecutionCompositionError
                    .digestMismatch(field: "runContextDigest")
            }
        }
    }

    /// Proves that the current route, options, registry definitions,
    /// localities, policy, and context-preparation implementation are exactly
    /// the ones accepted for this run. Any drift is one fail-closed recovery
    /// error; callers never receive a partially compatible binding.
    func validateRuntimeBinding(
        _ binding: AgentRunExecutionRuntimeBinding,
        matching context: AgentRunContext
    ) throws {
        let candidate: AgentRunExecutionComposition
        do {
            candidate = try AgentRunExecutionComposition(
                context: context,
                providerRoute: binding.providerRoute,
                providerOptions: binding.providerOptions,
                toolRegistry: binding.toolRegistry,
                toolLocalities: binding.toolLocalities,
                policyVersion: binding.policyVersion,
                contextPreparationVersion: binding.contextPreparationVersion,
                systemInstruction: binding.systemInstruction,
                developerInstruction: binding.developerInstruction
            )
        } catch {
            throw AgentRunExecutionCompositionError.runtimeBindingMismatch
        }
        guard candidate == self else {
            throw AgentRunExecutionCompositionError.runtimeBindingMismatch
        }
    }

    fileprivate static func canonicalData<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    fileprivate static func digest<Value: Encodable>(
        _ value: Value,
        domain: String
    ) throws -> String {
        var material = Data(domain.utf8)
        material.append(0)
        material.append(try canonicalData(value))
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    fileprivate static func digestData(
        _ data: Data,
        domain: String
    ) -> String {
        var material = Data(domain.utf8)
        material.append(0)
        material.append(data)
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func canonicalTools(
        _ tools: [AgentRunToolExecutionBinding]
    ) -> [AgentRunToolExecutionBinding] {
        tools.sorted { lhs, rhs in
            if lhs.tool.name != rhs.tool.name {
                return lhs.tool.name < rhs.tool.name
            }
            if lhs.tool.version != rhs.tool.version {
                return lhs.tool.version < rhs.tool.version
            }
            return lhs.locality.rawValue < rhs.locality.rawValue
        }
    }

    private static func validateIdentity(
        _ value: String,
        field: String
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= 256,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw AgentRunExecutionCompositionError.unsafeIdentity(field: field)
        }
        let lowercased = value.lowercased()
        let scalars = Array(value.unicodeScalars)
        let isWindowsAbsolutePath = scalars.count >= 3 &&
            CharacterSet.letters.contains(scalars[0]) &&
            scalars[1] == ":" && (scalars[2] == "/" || scalars[2] == "\\")
        guard !value.hasPrefix("/"),
              !value.hasPrefix("~/"),
              !value.hasPrefix("../"),
              !value.hasPrefix("./"),
              !value.contains("\\"),
              !lowercased.hasPrefix("file:"),
              !isWindowsAbsolutePath
        else {
            throw AgentRunExecutionCompositionError.rawHostPath(field: field)
        }
    }
}

/// Append-only storage for one canonical Agent Harness event.
///
/// `encodedEvent` is deliberately opaque to SwiftData. Header values are
/// duplicated into scalar columns so recovery and projection queries never
/// need to decode every payload just to locate a run or resume from a cursor.
@Model
final class AgentEventRecord {
    @Attribute(.unique) var journalOffsetValue: Int64
    @Attribute(.unique) var eventIDString: String
    @Attribute(.unique) var runSequenceKey: String
    @Attribute(.unique) var writerSequenceKey: String
    @Attribute(.unique) var writerIdempotencyKey: String
    var writerIDString: String
    var writerSequenceValue: Int64
    var idempotencyKey: String
    var runIDString: String
    var rootRunIDString: String
    var parentRunIDString: String?
    var sequenceValue: Int64
    var timestampMilliseconds: Int64
    var executionNodeIDString: String
    var conversationIDString: String
    var projectIDString: String?
    var workspaceIDString: String
    var causationIDString: String?
    var correlationIDString: String
    var schemaMajor: Int
    var schemaMinor: Int
    var engineVersion: String
    var eventKind: String
    var encodingName: String
    var encodingVersion: Int
    var encodedEvent: Data
    var payloadDigest: String
    var committedAtMilliseconds: Int64
    var insertedAt: Date

    init(
        journalOffsetValue: Int64,
        eventIDString: String,
        writerIDString: String,
        writerSequenceValue: Int64,
        idempotencyKey: String,
        runIDString: String,
        rootRunIDString: String,
        parentRunIDString: String?,
        sequenceValue: Int64,
        timestampMilliseconds: Int64,
        executionNodeIDString: String,
        conversationIDString: String,
        projectIDString: String?,
        workspaceIDString: String,
        causationIDString: String?,
        correlationIDString: String,
        schemaMajor: Int,
        schemaMinor: Int,
        engineVersion: String,
        eventKind: String,
        encodingName: String,
        encodingVersion: Int,
        encodedEvent: Data,
        payloadDigest: String,
        committedAtMilliseconds: Int64,
        insertedAt: Date
    ) {
        self.journalOffsetValue = journalOffsetValue
        self.eventIDString = eventIDString
        self.runSequenceKey = Self.makeRunSequenceKey(
            runIDString: runIDString,
            sequenceValue: sequenceValue
        )
        self.writerSequenceKey = Self.makeWriterSequenceKey(
            runIDString: runIDString,
            writerIDString: writerIDString,
            writerSequenceValue: writerSequenceValue
        )
        self.writerIdempotencyKey = Self.makeWriterIdempotencyKey(
            runIDString: runIDString,
            writerIDString: writerIDString,
            idempotencyKey: idempotencyKey
        )
        self.writerIDString = writerIDString
        self.writerSequenceValue = writerSequenceValue
        self.idempotencyKey = idempotencyKey
        self.runIDString = runIDString
        self.rootRunIDString = rootRunIDString
        self.parentRunIDString = parentRunIDString
        self.sequenceValue = sequenceValue
        self.timestampMilliseconds = timestampMilliseconds
        self.executionNodeIDString = executionNodeIDString
        self.conversationIDString = conversationIDString
        self.projectIDString = projectIDString
        self.workspaceIDString = workspaceIDString
        self.causationIDString = causationIDString
        self.correlationIDString = correlationIDString
        self.schemaMajor = schemaMajor
        self.schemaMinor = schemaMinor
        self.engineVersion = engineVersion
        self.eventKind = eventKind
        self.encodingName = encodingName
        self.encodingVersion = encodingVersion
        self.encodedEvent = encodedEvent
        self.payloadDigest = payloadDigest
        self.committedAtMilliseconds = committedAtMilliseconds
        self.insertedAt = insertedAt
    }

    static func makeRunSequenceKey(runIDString: String, sequenceValue: Int64) -> String {
        "\(runIDString.lowercased()):\(sequenceValue)"
    }

    static func makeWriterSequenceKey(
        runIDString: String,
        writerIDString: String,
        writerSequenceValue: Int64
    ) -> String {
        "\(runIDString.lowercased()):\(writerIDString.lowercased()):\(writerSequenceValue)"
    }

    static func makeWriterIdempotencyKey(
        runIDString: String,
        writerIDString: String,
        idempotencyKey: String
    ) -> String {
        "\(runIDString.lowercased()):\(writerIDString.lowercased()):\(idempotencyKey)"
    }
}

/// V2-only metadata frozen when a run is durably accepted.
@Model
final class PersistedAgentRunMetadataRecord {
    @Attribute(.unique) var runIDString: String
    var rootRunIDString: String
    var parentRunIDString: String?
    var writerIDString: String
    @Attribute(.unique) var acceptanceCommandIDString: String
    var engineVersion: String
    var enabledFeaturesJSON: Data
    var executionNodeIDString: String
    var conversationIDString: String
    var projectIDString: String?
    var workspaceIDString: String
    var acceptedEventIDString: String
    var acceptedAtMilliseconds: Int64
    var encodingName: String
    var encodingVersion: Int
    var encodedMetadata: Data
    var metadataDigest: String
    var createdAt: Date

    init(
        runIDString: String,
        rootRunIDString: String,
        parentRunIDString: String?,
        writerIDString: String,
        acceptanceCommandIDString: String,
        engineVersion: String,
        enabledFeaturesJSON: Data,
        executionNodeIDString: String,
        conversationIDString: String,
        projectIDString: String?,
        workspaceIDString: String,
        acceptedEventIDString: String,
        acceptedAtMilliseconds: Int64,
        encodingName: String,
        encodingVersion: Int,
        encodedMetadata: Data,
        metadataDigest: String,
        createdAt: Date
    ) {
        self.runIDString = runIDString
        self.rootRunIDString = rootRunIDString
        self.parentRunIDString = parentRunIDString
        self.writerIDString = writerIDString
        self.acceptanceCommandIDString = acceptanceCommandIDString
        self.engineVersion = engineVersion
        self.enabledFeaturesJSON = enabledFeaturesJSON
        self.executionNodeIDString = executionNodeIDString
        self.conversationIDString = conversationIDString
        self.projectIDString = projectIDString
        self.workspaceIDString = workspaceIDString
        self.acceptedEventIDString = acceptedEventIDString
        self.acceptedAtMilliseconds = acceptedAtMilliseconds
        self.encodingName = encodingName
        self.encodingVersion = encodingVersion
        self.encodedMetadata = encodedMetadata
        self.metadataDigest = metadataDigest
        self.createdAt = createdAt
    }
}

/// Immutable V4 execution composition committed in the same SwiftData save as
/// metadata, `runAccepted`, and the legacy acceptance projection.
@Model
final class PersistedAgentRunExecutionCompositionRecord {
    @Attribute(.unique) var runIDString: String
    var conversationIDString: String
    var projectIDString: String?
    var workspaceIDString: String
    var executionNodeIDString: String
    var runContextDigest: String
    var providerID: String
    var modelID: String
    var adapterID: String
    var toolRegistryDigest: String
    var toolLocalitiesDigest: String
    var policyVersion: String
    var contextPreparationVersion: String
    var systemInstructionDigest: String?
    var developerInstructionDigest: String?
    var encodingName: String
    var encodingVersion: Int
    var encodedComposition: Data
    var compositionDigest: String
    var createdAt: Date

    init(
        runIDString: String,
        conversationIDString: String,
        projectIDString: String?,
        workspaceIDString: String,
        executionNodeIDString: String,
        runContextDigest: String,
        providerID: String,
        modelID: String,
        adapterID: String,
        toolRegistryDigest: String,
        toolLocalitiesDigest: String,
        policyVersion: String,
        contextPreparationVersion: String,
        systemInstructionDigest: String?,
        developerInstructionDigest: String?,
        encodingName: String,
        encodingVersion: Int,
        encodedComposition: Data,
        compositionDigest: String,
        createdAt: Date
    ) {
        self.runIDString = runIDString
        self.conversationIDString = conversationIDString
        self.projectIDString = projectIDString
        self.workspaceIDString = workspaceIDString
        self.executionNodeIDString = executionNodeIDString
        self.runContextDigest = runContextDigest
        self.providerID = providerID
        self.modelID = modelID
        self.adapterID = adapterID
        self.toolRegistryDigest = toolRegistryDigest
        self.toolLocalitiesDigest = toolLocalitiesDigest
        self.policyVersion = policyVersion
        self.contextPreparationVersion = contextPreparationVersion
        self.systemInstructionDigest = systemInstructionDigest
        self.developerInstructionDigest = developerInstructionDigest
        self.encodingName = encodingName
        self.encodingVersion = encodingVersion
        self.encodedComposition = encodedComposition
        self.compositionDigest = compositionDigest
        self.createdAt = createdAt
    }
}

/// Durable approval projection. The canonical event stream remains the source
/// of truth; this record exists for efficient relaunch and pending-work UI.
@Model
final class ApprovalRequestRecord {
    @Attribute(.unique) var approvalRequestIDString: String
    var runIDString: String
    var toolCallIDString: String
    var workspaceIDString: String
    var requestedEventIDString: String
    var resolvedEventIDString: String?
    var statusRawValue: String
    var encodedRequest: Data
    var encodedResolution: Data?
    var requestedAtMilliseconds: Int64
    var resolvedAtMilliseconds: Int64?
    var updatedAt: Date

    init(
        approvalRequestIDString: String,
        runIDString: String,
        toolCallIDString: String,
        workspaceIDString: String,
        requestedEventIDString: String,
        resolvedEventIDString: String? = nil,
        statusRawValue: String,
        encodedRequest: Data,
        encodedResolution: Data? = nil,
        requestedAtMilliseconds: Int64,
        resolvedAtMilliseconds: Int64? = nil,
        updatedAt: Date
    ) {
        self.approvalRequestIDString = approvalRequestIDString
        self.runIDString = runIDString
        self.toolCallIDString = toolCallIDString
        self.workspaceIDString = workspaceIDString
        self.requestedEventIDString = requestedEventIDString
        self.resolvedEventIDString = resolvedEventIDString
        self.statusRawValue = statusRawValue
        self.encodedRequest = encodedRequest
        self.encodedResolution = encodedResolution
        self.requestedAtMilliseconds = requestedAtMilliseconds
        self.resolvedAtMilliseconds = resolvedAtMilliseconds
        self.updatedAt = updatedAt
    }
}

/// Durable, queryable proof that a mutation reached the applied boundary.
@Model
final class ToolEffectEvidenceRecord {
    @Attribute(.unique) var evidenceKey: String
    var runIDString: String
    var toolCallIDString: String
    var appliedEventIDString: String
    var workspaceIDString: String
    var evidenceKind: String
    var encodedEvidence: Data
    var evidenceDigest: String
    var appliedAtMilliseconds: Int64
    var createdAt: Date

    init(
        runIDString: String,
        toolCallIDString: String,
        appliedEventIDString: String,
        workspaceIDString: String,
        evidenceKind: String,
        encodedEvidence: Data,
        evidenceDigest: String,
        appliedAtMilliseconds: Int64,
        createdAt: Date
    ) {
        self.evidenceKey = Self.makeEvidenceKey(
            appliedEventIDString: appliedEventIDString,
            evidenceDigest: evidenceDigest
        )
        self.runIDString = runIDString
        self.toolCallIDString = toolCallIDString
        self.appliedEventIDString = appliedEventIDString
        self.workspaceIDString = workspaceIDString
        self.evidenceKind = evidenceKind
        self.encodedEvidence = encodedEvidence
        self.evidenceDigest = evidenceDigest
        self.appliedAtMilliseconds = appliedAtMilliseconds
        self.createdAt = createdAt
    }

    static func makeEvidenceKey(appliedEventIDString: String, evidenceDigest: String) -> String {
        // Event IDs are UUIDs and may be normalized safely. Evidence digests
        // are opaque caller-declared identities; case folding would merge two
        // distinct declarations (for example `ABC` and `abc`).
        "\(appliedEventIDString.lowercased()):\(evidenceDigest)"
    }
}

/// Canonical artifact materialization that does not pretend a display name is
/// a filesystem location. Legacy `ProjectArtifact` rows require a trustworthy
/// workspace-relative path, which is not part of `ArtifactReference` yet, so
/// V2 keeps the complete typed reference and its event/tool provenance here.
@Model
final class AgentArtifactProjectionRecord {
    @Attribute(.unique) var artifactProjectionKey: String
    var artifactIDString: String
    var eventIDString: String
    var runIDString: String
    var projectIDString: String?
    var workspaceIDString: String
    var toolCallIDString: String?
    var sourceKind: String
    var mediaType: String
    var displayName: String
    var encodingName: String
    var encodingVersion: Int
    var encodedArtifact: Data
    /// Digest declared by the canonical `ArtifactReference`.
    var artifactDigest: String
    /// Integrity digest for the encoded reference envelope itself.
    var encodedArtifactSHA256: String
    var occurredAtMilliseconds: Int64
    var createdAt: Date

    init(
        artifactIDString: String,
        eventIDString: String,
        runIDString: String,
        projectIDString: String?,
        workspaceIDString: String,
        toolCallIDString: String?,
        sourceKind: String,
        mediaType: String,
        displayName: String,
        encodingName: String,
        encodingVersion: Int,
        encodedArtifact: Data,
        artifactDigest: String,
        encodedArtifactSHA256: String,
        occurredAtMilliseconds: Int64,
        createdAt: Date
    ) {
        self.artifactProjectionKey = Self.makeArtifactProjectionKey(
            artifactIDString: artifactIDString,
            eventIDString: eventIDString
        )
        self.artifactIDString = artifactIDString
        self.eventIDString = eventIDString
        self.runIDString = runIDString
        self.projectIDString = projectIDString
        self.workspaceIDString = workspaceIDString
        self.toolCallIDString = toolCallIDString
        self.sourceKind = sourceKind
        self.mediaType = mediaType
        self.displayName = displayName
        self.encodingName = encodingName
        self.encodingVersion = encodingVersion
        self.encodedArtifact = encodedArtifact
        self.artifactDigest = artifactDigest
        self.encodedArtifactSHA256 = encodedArtifactSHA256
        self.occurredAtMilliseconds = occurredAtMilliseconds
        self.createdAt = createdAt
    }

    static func makeArtifactProjectionKey(
        artifactIDString: String,
        eventIDString: String
    ) -> String {
        "\(eventIDString.lowercased()):\(artifactIDString.lowercased())"
    }
}

/// Last global journal offset successfully applied by one named projection.
@Model
final class ProjectionCursorRecord {
    @Attribute(.unique) var cursorKey: String
    var projectionIDString: String
    var throughOffsetValue: Int64
    var updatedAtMilliseconds: Int64
    var updatedAt: Date

    init(
        projectionIDString: String,
        throughOffsetValue: Int64,
        updatedAtMilliseconds: Int64,
        updatedAt: Date
    ) {
        self.cursorKey = Self.makeCursorKey(projectionIDString: projectionIDString)
        self.projectionIDString = projectionIDString
        self.throughOffsetValue = throughOffsetValue
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.updatedAt = updatedAt
    }

    static func makeCursorKey(projectionIDString: String) -> String {
        projectionIDString
    }
}

/// Optional materialized reducer state. Events remain authoritative; snapshots
/// are admitted only when canonical replay exactly reproduces their boundary.
@Model
final class ProjectionSnapshotRecord {
    @Attribute(.unique) var snapshotKey: String
    var projectionName: String
    var projectionVersion: Int
    var runIDString: String
    var throughSequenceValue: Int64
    var throughEventIDString: String
    var stateEncodingName: String
    var stateEncodingVersion: Int
    var encodedState: Data
    var stateDigest: String
    var createdAt: Date

    init(
        projectionName: String,
        projectionVersion: Int,
        runIDString: String,
        throughSequenceValue: Int64,
        throughEventIDString: String,
        stateEncodingName: String,
        stateEncodingVersion: Int,
        encodedState: Data,
        stateDigest: String,
        createdAt: Date
    ) {
        self.snapshotKey = Self.makeSnapshotKey(
            projectionName: projectionName,
            projectionVersion: projectionVersion,
            runIDString: runIDString,
            throughSequenceValue: throughSequenceValue
        )
        self.projectionName = projectionName
        self.projectionVersion = projectionVersion
        self.runIDString = runIDString
        self.throughSequenceValue = throughSequenceValue
        self.throughEventIDString = throughEventIDString
        self.stateEncodingName = stateEncodingName
        self.stateEncodingVersion = stateEncodingVersion
        self.encodedState = encodedState
        self.stateDigest = stateDigest
        self.createdAt = createdAt
    }

    static func makeSnapshotKey(
        projectionName: String,
        projectionVersion: Int,
        runIDString: String,
        throughSequenceValue: Int64
    ) -> String {
        "\(projectionName):v\(projectionVersion):\(runIDString.lowercased()):\(throughSequenceValue)"
    }
}

/// Registered execution owner advertised to recovery and worker routing.
@Model
final class ExecutionNodeRecord {
    @Attribute(.unique) var executionNodeIDString: String
    var kindRawValue: String
    var displayName: String
    var capabilityManifest: Data
    var manifestDigest: String
    var isRevoked: Bool
    var lastSeenAtMilliseconds: Int64
    var updatedAt: Date

    init(
        executionNodeIDString: String,
        kindRawValue: String,
        displayName: String,
        capabilityManifest: Data,
        manifestDigest: String,
        isRevoked: Bool = false,
        lastSeenAtMilliseconds: Int64,
        updatedAt: Date
    ) {
        self.executionNodeIDString = executionNodeIDString
        self.kindRawValue = kindRawValue
        self.displayName = displayName
        self.capabilityManifest = capabilityManifest
        self.manifestDigest = manifestDigest
        self.isRevoked = isRevoked
        self.lastSeenAtMilliseconds = lastSeenAtMilliseconds
        self.updatedAt = updatedAt
    }
}

/// Monotonic invalidation for project-scoped materialized evidence.
///
/// This is a companion record rather than a stored `Project` property so the
/// released V1 model shape and the additive V2 ledger schema remain immutable.
/// Projectors advance it in the same transaction as their rows and cursor.
@Model
final class ProjectMaterializedEvidenceRevisionRecord {
    @Attribute(.unique) var projectID: UUID
    var revision: Int64

    init(projectID: UUID, revision: Int64 = 0) {
        self.projectID = projectID
        self.revision = revision
    }
}

enum AgentMaterializationDispositionScopeKind: String, Codable, Sendable {
    case conversation
    case project
}

enum AgentMaterializationDispositionAction: String, Codable, Sendable {
    case suppressChat
    case rehomeToGeneral
}

/// Durable user intent for how canonical history may be materialized after a
/// destructive UI action. Canonical events and acceptance headers never
/// change; projectors consume this companion policy when rebuilding views.
@Model
final class AgentMaterializationDispositionRecord {
    @Attribute(.unique) var dispositionKey: String
    var scopeKindRawValue: String
    var scopeID: UUID
    var actionRawValue: String
    var createdAtMilliseconds: Int64
    var createdAt: Date

    init(
        scopeKind: AgentMaterializationDispositionScopeKind,
        scopeID: UUID,
        action: AgentMaterializationDispositionAction,
        createdAtMilliseconds: Int64,
        createdAt: Date
    ) {
        self.dispositionKey = Self.makeKey(scopeKind: scopeKind, scopeID: scopeID)
        self.scopeKindRawValue = scopeKind.rawValue
        self.scopeID = scopeID
        self.actionRawValue = action.rawValue
        self.createdAtMilliseconds = createdAtMilliseconds
        self.createdAt = createdAt
    }

    static func makeKey(
        scopeKind: AgentMaterializationDispositionScopeKind,
        scopeID: UUID
    ) -> String {
        "\(scopeKind.rawValue):\(scopeID.uuidString.lowercased())"
    }
}

/// Scalar render identity shared by the app and persistence tests. Keeping the
/// evidence revision here ensures UI Equatable boundaries never need to fault
/// project relationships to observe a committed projection.
struct ProjectDashboardSnapshotKey: Equatable {
    let projectID: UUID
    let materializedEvidenceRevision: Int64
    let projectUpdatedAt: Date
    let projectLastActivityAt: Date
    let activeProjectOSRunID: UUID?
    let activeProjectOSRunUpdatedAt: Date?
    let activeProjectOSRunStatusRawValue: String?
}
