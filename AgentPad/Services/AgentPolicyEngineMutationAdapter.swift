import AgentDomain
import AgentEngine
import AgentPolicy
import AgentTools
import struct CryptoKit.SHA256
import Foundation

enum AgentPolicyEngineMutationAdapterError: Error, Equatable, Sendable {
    case invalidComposition
    case invalidContext
    case unsupportedEngine
    case readOnlyInvocation
    case preparationConflict
    case preparationNotFound
    case preparationBindingMismatch
    case staleEngineSeal
    case approvalNotPending
    case approvalBindingMismatch
    case decisionDeliveryFailed
    case unclassifiedResultRejected
    case numericValueOutOfRange
    case durableStoreUnavailable
    case durableStoreCorrupt
}

enum AgentPolicyEnginePreparationAuthorization: Codable, Equatable, Sendable {
    case durableApproval(
        requestID: ApprovalRequestID,
        bindingSHA256: SHA256Digest
    )
    case reevaluablePolicy
}

/// Content-addressed, argument-free durable binding between M7's engine seal
/// and M6's policy/effect authorities. Exact arguments remain in the canonical
/// engine event log; their canonical digest and the policy request digest are
/// sufficient to reject any substituted payload here.
struct AgentPolicyEnginePreparationRecord: Codable, Equatable, Sendable {
    static let tokenPrefix = "m7-policy-preparation-v1:"

    let origin: MutationOrigin
    let runID: RunID
    let workspaceID: WorkspaceID
    let callID: ToolCallID
    let modelAttemptID: AttemptID
    let tool: ToolIdentity
    let canonicalArgumentDigest: String
    let idempotencyKey: String
    let effectClass: ToolEffectClass
    let locality: ToolExecutionLocality
    let requestSHA256: SHA256Digest
    let policySHA256: SHA256Digest
    let targetAttestationSHA256: SHA256Digest
    let workspaceRevision: String
    let effectKeySHA256: SHA256Digest
    let authorization: AgentPolicyEnginePreparationAuthorization
    let authorityToken: String
    let recordSHA256: SHA256Digest

    private struct Material: Codable {
        let origin: MutationOrigin
        let runID: RunID
        let workspaceID: WorkspaceID
        let callID: ToolCallID
        let modelAttemptID: AttemptID
        let tool: ToolIdentity
        let canonicalArgumentDigest: String
        let idempotencyKey: String
        let effectClass: ToolEffectClass
        let locality: ToolExecutionLocality
        let requestSHA256: SHA256Digest
        let policySHA256: SHA256Digest
        let targetAttestationSHA256: SHA256Digest
        let workspaceRevision: String
        let effectKeySHA256: SHA256Digest
        let authorization: AgentPolicyEnginePreparationAuthorization
    }

    private struct Envelope<Value: Encodable>: Encodable {
        let scheme: String
        let domain: String
        let value: Value
    }

    static func make(
        _ prepared: AgentPolicyStagedAgentV2Mutation
    ) throws -> Self {
        let request = prepared.request
        let authorization: AgentPolicyEnginePreparationAuthorization
        switch prepared.authorization {
        case let .durableApproval(durable, domain):
            guard durable.requestID == domain.requestID,
                  durable.binding.runID == domain.binding.runID,
                  durable.binding.callID == domain.binding.callID,
                  durable.binding.workspaceID == domain.binding.workspaceID,
                  durable.binding.canonicalArgumentDigest
                    == domain.binding.canonicalArgumentDigest
            else {
                throw AgentPolicyEngineMutationAdapterError
                    .approvalBindingMismatch
            }
            authorization = .durableApproval(
                requestID: durable.requestID,
                bindingSHA256: durable.binding.bindingSHA256
            )
        case .reevaluablePolicy:
            authorization = .reevaluablePolicy
        }

        return try makeBinding(
            origin: request.origin,
            runID: request.runID,
            workspaceID: request.workspaceID,
            callID: request.invocation.callID,
            modelAttemptID: request.invocation.modelAttemptID,
            tool: request.invocation.tool,
            canonicalArgumentDigest:
                request.invocation.canonicalArgumentDigest,
            idempotencyKey: request.invocation.idempotencyKey,
            effectClass: request.invocation.effectClass,
            locality: request.invocation.locality,
            requestSHA256: request.requestSHA256,
            policySHA256: prepared.policySHA256,
            targetAttestationSHA256: request.targetAttestationSHA256,
            workspaceRevision: prepared.approvalRequest?.binding
                .workspaceRevision ?? request.targetAttestationSHA256.rawValue,
            effectKeySHA256: prepared.effectKeySHA256,
            authorization: authorization
        )
    }

    /// Non-authorizing construction seam used by durable-store tests and by
    /// the staged M6 projection above. The resulting value cannot execute an
    /// effect; apply still requires the live engine seal and M6 authorities.
    static func makeBinding(
        origin: MutationOrigin,
        runID: RunID,
        workspaceID: WorkspaceID,
        callID: ToolCallID,
        modelAttemptID: AttemptID,
        tool: ToolIdentity,
        canonicalArgumentDigest: String,
        idempotencyKey: String,
        effectClass: ToolEffectClass,
        locality: ToolExecutionLocality,
        requestSHA256: SHA256Digest,
        policySHA256: SHA256Digest,
        targetAttestationSHA256: SHA256Digest,
        workspaceRevision: String,
        effectKeySHA256: SHA256Digest,
        authorization: AgentPolicyEnginePreparationAuthorization
    ) throws -> Self {
        try make(Material(
            origin: origin,
            runID: runID,
            workspaceID: workspaceID,
            callID: callID,
            modelAttemptID: modelAttemptID,
            tool: tool,
            canonicalArgumentDigest: canonicalArgumentDigest,
            idempotencyKey: idempotencyKey,
            effectClass: effectClass,
            locality: locality,
            requestSHA256: requestSHA256,
            policySHA256: policySHA256,
            targetAttestationSHA256: targetAttestationSHA256,
            workspaceRevision: workspaceRevision,
            effectKeySHA256: effectKeySHA256,
            authorization: authorization
        ))
    }

    func matches(
        context: AgentRunContext,
        invocation: ToolInvocation,
        preparation: AgentMutationPreparation? = nil
    ) -> Bool {
        guard origin == .agentV2,
              runID == context.lineage.runID,
              workspaceID == context.workspaceID,
              callID == invocation.callID,
              modelAttemptID == invocation.modelAttemptID,
              tool == invocation.tool,
              canonicalArgumentDigest
                == invocation.canonicalArgumentDigest,
              idempotencyKey == invocation.idempotencyKey,
              effectClass == invocation.effectClass,
              locality == invocation.locality
        else { return false }
        guard let preparation else { return true }
        return preparation.runID == runID
            && preparation.workspaceID == workspaceID
            && preparation.callID == callID
            && preparation.canonicalArgumentDigest
                == canonicalArgumentDigest
            && preparation.authorityToken == authorityToken
            && preparation.effectKeySHA256 == effectKeySHA256
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let material = Material(
            origin: try container.decode(MutationOrigin.self, forKey: .origin),
            runID: try container.decode(RunID.self, forKey: .runID),
            workspaceID: try container.decode(
                WorkspaceID.self,
                forKey: .workspaceID
            ),
            callID: try container.decode(ToolCallID.self, forKey: .callID),
            modelAttemptID: try container.decode(
                AttemptID.self,
                forKey: .modelAttemptID
            ),
            tool: try container.decode(ToolIdentity.self, forKey: .tool),
            canonicalArgumentDigest: try container.decode(
                String.self,
                forKey: .canonicalArgumentDigest
            ),
            idempotencyKey: try container.decode(
                String.self,
                forKey: .idempotencyKey
            ),
            effectClass: try container.decode(
                ToolEffectClass.self,
                forKey: .effectClass
            ),
            locality: try container.decode(
                ToolExecutionLocality.self,
                forKey: .locality
            ),
            requestSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .requestSHA256
            ),
            policySHA256: try container.decode(
                SHA256Digest.self,
                forKey: .policySHA256
            ),
            targetAttestationSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .targetAttestationSHA256
            ),
            workspaceRevision: try container.decode(
                String.self,
                forKey: .workspaceRevision
            ),
            effectKeySHA256: try container.decode(
                SHA256Digest.self,
                forKey: .effectKeySHA256
            ),
            authorization: try container.decode(
                AgentPolicyEnginePreparationAuthorization.self,
                forKey: .authorization
            )
        )
        let rebuilt = try Self.make(material)
        guard rebuilt.authorityToken == (try container.decode(
            String.self,
            forKey: .authorityToken
        )), rebuilt.recordSHA256 == (try container.decode(
            SHA256Digest.self,
            forKey: .recordSHA256
        )) else {
            throw AgentPolicyEngineMutationAdapterError.durableStoreCorrupt
        }
        self = rebuilt
    }

    private static func make(_ material: Material) throws -> Self {
        guard material.origin == .agentV2,
              !material.canonicalArgumentDigest.isEmpty,
              material.canonicalArgumentDigest.utf8.count <= 512,
              !material.idempotencyKey.isEmpty,
              material.idempotencyKey.utf8.count <= 512,
              !material.workspaceRevision.isEmpty,
              material.workspaceRevision.utf8.count <= 1_024
        else {
            throw AgentPolicyEngineMutationAdapterError
                .preparationBindingMismatch
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(
            scheme: "novaforge-agent-policy-engine-preparation-v1",
            domain: "agent-policy-engine-preparation-record-v1",
            value: material
        ))
        let hexadecimal = SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
        let digest = try SHA256Digest("sha256:" + hexadecimal)
        return Self(
            origin: material.origin,
            runID: material.runID,
            workspaceID: material.workspaceID,
            callID: material.callID,
            modelAttemptID: material.modelAttemptID,
            tool: material.tool,
            canonicalArgumentDigest: material.canonicalArgumentDigest,
            idempotencyKey: material.idempotencyKey,
            effectClass: material.effectClass,
            locality: material.locality,
            requestSHA256: material.requestSHA256,
            policySHA256: material.policySHA256,
            targetAttestationSHA256: material.targetAttestationSHA256,
            workspaceRevision: material.workspaceRevision,
            effectKeySHA256: material.effectKeySHA256,
            authorization: material.authorization,
            authorityToken: tokenPrefix + digest.rawValue,
            recordSHA256: digest
        )
    }

    private init(
        origin: MutationOrigin,
        runID: RunID,
        workspaceID: WorkspaceID,
        callID: ToolCallID,
        modelAttemptID: AttemptID,
        tool: ToolIdentity,
        canonicalArgumentDigest: String,
        idempotencyKey: String,
        effectClass: ToolEffectClass,
        locality: ToolExecutionLocality,
        requestSHA256: SHA256Digest,
        policySHA256: SHA256Digest,
        targetAttestationSHA256: SHA256Digest,
        workspaceRevision: String,
        effectKeySHA256: SHA256Digest,
        authorization: AgentPolicyEnginePreparationAuthorization,
        authorityToken: String,
        recordSHA256: SHA256Digest
    ) {
        self.origin = origin
        self.runID = runID
        self.workspaceID = workspaceID
        self.callID = callID
        self.modelAttemptID = modelAttemptID
        self.tool = tool
        self.canonicalArgumentDigest = canonicalArgumentDigest
        self.idempotencyKey = idempotencyKey
        self.effectClass = effectClass
        self.locality = locality
        self.requestSHA256 = requestSHA256
        self.policySHA256 = policySHA256
        self.targetAttestationSHA256 = targetAttestationSHA256
        self.workspaceRevision = workspaceRevision
        self.effectKeySHA256 = effectKeySHA256
        self.authorization = authorization
        self.authorityToken = authorityToken
        self.recordSHA256 = recordSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case origin
        case runID
        case workspaceID
        case callID
        case modelAttemptID
        case tool
        case canonicalArgumentDigest
        case idempotencyKey
        case effectClass
        case locality
        case requestSHA256
        case policySHA256
        case targetAttestationSHA256
        case workspaceRevision
        case effectKeySHA256
        case authorization
        case authorityToken
        case recordSHA256
    }
}

enum AgentPolicyEnginePreparationCommitDisposition: Equatable, Sendable {
    case committed
    case alreadyPresent
}

protocol AgentPolicyEnginePreparationStoring: Sendable {
    func commitIfAbsent(
        _ record: AgentPolicyEnginePreparationRecord
    ) async throws -> AgentPolicyEnginePreparationCommitDisposition

    func record(
        authorityToken: String
    ) async throws -> AgentPolicyEnginePreparationRecord?

    func record(
        effectKeySHA256: SHA256Digest
    ) async throws -> AgentPolicyEnginePreparationRecord?
}

actor InMemoryAgentPolicyEnginePreparationStore:
    AgentPolicyEnginePreparationStoring
{
    private var records: [String: AgentPolicyEnginePreparationRecord] = [:]

    init() {}

    init(restoring values: [AgentPolicyEnginePreparationRecord]) throws {
        for value in values {
            guard records[value.authorityToken] == nil,
                  !records.values.contains(where: {
                      $0.effectKeySHA256 == value.effectKeySHA256
                        && $0 != value
                  })
            else {
                throw AgentPolicyEngineMutationAdapterError
                    .durableStoreCorrupt
            }
            records[value.authorityToken] = value
        }
    }

    func commitIfAbsent(
        _ record: AgentPolicyEnginePreparationRecord
    ) throws -> AgentPolicyEnginePreparationCommitDisposition {
        if let existing = records[record.authorityToken] {
            guard existing == record else {
                throw AgentPolicyEngineMutationAdapterError
                    .preparationConflict
            }
            return .alreadyPresent
        }
        guard !records.values.contains(where: {
            $0.effectKeySHA256 == record.effectKeySHA256
        }) else {
            throw AgentPolicyEngineMutationAdapterError.preparationConflict
        }
        records[record.authorityToken] = record
        return .committed
    }

    func record(
        authorityToken: String
    ) -> AgentPolicyEnginePreparationRecord? {
        records[authorityToken]
    }

    func record(
        effectKeySHA256: SHA256Digest
    ) -> AgentPolicyEnginePreparationRecord? {
        records.values.first { $0.effectKeySHA256 == effectKeySHA256 }
    }

    func snapshot() -> [AgentPolicyEnginePreparationRecord] {
        records.values.sorted { $0.authorityToken < $1.authorityToken }
    }
}

/// Crash-durable app preparation ledger. A process-wide coordinator serializes
/// every instance targeting the same protected file, while atomic replacement
/// prevents a crash from exposing a partially encoded ledger.
actor FileAgentPolicyEnginePreparationStore:
    AgentPolicyEnginePreparationStoring
{
    private let fileURL: URL

    init(fileURL: URL) throws {
        guard fileURL.isFileURL,
              fileURL.path.hasPrefix("/"),
              fileURL.standardizedFileURL.path != "/"
        else {
            throw AgentPolicyEngineMutationAdapterError
                .durableStoreUnavailable
        }
        self.fileURL = fileURL.standardizedFileURL
    }

    func commitIfAbsent(
        _ record: AgentPolicyEnginePreparationRecord
    ) async throws -> AgentPolicyEnginePreparationCommitDisposition {
        try await AgentPolicyEnginePreparationFileCoordinator.shared
            .commitIfAbsent(record, fileURL: fileURL)
    }

    func record(
        authorityToken: String
    ) async throws -> AgentPolicyEnginePreparationRecord? {
        try await AgentPolicyEnginePreparationFileCoordinator.shared.record(
            authorityToken: authorityToken,
            fileURL: fileURL
        )
    }

    func record(
        effectKeySHA256: SHA256Digest
    ) async throws -> AgentPolicyEnginePreparationRecord? {
        try await AgentPolicyEnginePreparationFileCoordinator.shared.record(
            effectKeySHA256: effectKeySHA256,
            fileURL: fileURL
        )
    }
}

private actor AgentPolicyEnginePreparationFileCoordinator {
    private struct Ledger: Codable {
        let schemaVersion: Int
        let records: [AgentPolicyEnginePreparationRecord]
    }

    static let shared = AgentPolicyEnginePreparationFileCoordinator()

    func commitIfAbsent(
        _ record: AgentPolicyEnginePreparationRecord,
        fileURL: URL
    ) throws -> AgentPolicyEnginePreparationCommitDisposition {
        var values = try load(fileURL)
        if let existing = values.first(where: {
            $0.authorityToken == record.authorityToken
        }) {
            guard existing == record else {
                throw AgentPolicyEngineMutationAdapterError
                    .preparationConflict
            }
            return .alreadyPresent
        }
        guard !values.contains(where: {
            $0.effectKeySHA256 == record.effectKeySHA256
        }) else {
            throw AgentPolicyEngineMutationAdapterError.preparationConflict
        }
        values.append(record)
        values.sort { $0.authorityToken < $1.authorityToken }
        try write(values, fileURL: fileURL)
        return .committed
    }

    func record(
        authorityToken: String,
        fileURL: URL
    ) throws -> AgentPolicyEnginePreparationRecord? {
        try load(fileURL).first { $0.authorityToken == authorityToken }
    }

    func record(
        effectKeySHA256: SHA256Digest,
        fileURL: URL
    ) throws -> AgentPolicyEnginePreparationRecord? {
        try load(fileURL).first { $0.effectKeySHA256 == effectKeySHA256 }
    }

    private func load(
        _ fileURL: URL
    ) throws -> [AgentPolicyEnginePreparationRecord] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else { return [] }
        let attributes = try manager.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AgentPolicyEngineMutationAdapterError.durableStoreCorrupt
        }
        let ledger: Ledger
        do {
            ledger = try JSONDecoder().decode(
                Ledger.self,
                from: Data(contentsOf: fileURL, options: [.mappedIfSafe])
            )
        } catch {
            throw AgentPolicyEngineMutationAdapterError.durableStoreCorrupt
        }
        guard ledger.schemaVersion == 1,
              Set(ledger.records.map(\.authorityToken)).count
                == ledger.records.count,
              Set(ledger.records.map(\.effectKeySHA256)).count
                == ledger.records.count
        else {
            throw AgentPolicyEngineMutationAdapterError.durableStoreCorrupt
        }
        return ledger.records
    }

    private func write(
        _ records: [AgentPolicyEnginePreparationRecord],
        fileURL: URL
    ) throws {
        let manager = FileManager.default
        let parent = fileURL.deletingLastPathComponent()
        let attributes = try manager.attributesOfItem(atPath: parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw AgentPolicyEngineMutationAdapterError
                .durableStoreUnavailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(Ledger(
                schemaVersion: 1,
                records: records
            )).write(to: fileURL, options: [.atomic])
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: fileURL.path
            )
#endif
            var mutable = fileURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutable.setResourceValues(resourceValues)
        } catch {
            throw AgentPolicyEngineMutationAdapterError
                .durableStoreUnavailable
        }
    }
}

protocol AgentPolicyApprovalDecisionDelivering: Sendable {
    func deliver(
        decision: ApprovalDecision,
        requestID: ApprovalRequestID
    ) async throws
}

extension AgentApprovalPromptCenter: AgentPolicyApprovalDecisionDelivering {
    func deliver(
        decision: ApprovalDecision,
        requestID: ApprovalRequestID
    ) async throws {
        guard submit(decision, for: requestID) == .accepted else {
            throw AgentPolicyEngineMutationAdapterError
                .decisionDeliveryFailed
        }
    }
}

/// Exact M7 bridge into the M6 authority. It also implements the request-bound
/// approval broker so the engine can journal `approvalRequested` before the
/// one trusted policy prompt suspends execution.
actor AgentPolicyEngineMutationAdapter:
    AgentMutationPolicyExecuting,
    AgentApprovalResolving
{
    static let policyVersion = "agent-policy-m6-v1"

    private struct LivePreparation: Sendable {
        let staged: AgentPolicyStagedAgentV2Mutation
        let record: AgentPolicyEnginePreparationRecord
        let sealed: AgentMutationPreparation
    }

    private let system: AgentPolicySystem
    private let preparationStore: any AgentPolicyEnginePreparationStoring
    private let decisionDeliverer: any AgentPolicyApprovalDecisionDelivering
    private let sessionID: String?
    private let backend: PolicyBackend
    private var live: [String: LivePreparation] = [:]
    private var approvalTokens: [ApprovalRequestID: String] = [:]

    init(
        system: AgentPolicySystem,
        preparationStore: any AgentPolicyEnginePreparationStoring,
        decisionDeliverer: any AgentPolicyApprovalDecisionDelivering,
        sessionID: String? = nil,
        backend: PolicyBackend = .onDevice
    ) {
        self.system = system
        self.preparationStore = preparationStore
        self.decisionDeliverer = decisionDeliverer
        self.sessionID = sessionID
        self.backend = backend
    }

    @MainActor
    static func production(
        system: AgentPolicySystem,
        promptCenter: AgentApprovalPromptCenter = .shared,
        sessionID: String? = nil,
        backend: PolicyBackend = .onDevice
    ) throws -> AgentPolicyEngineMutationAdapter {
        let ledger = system.storePaths.versionDirectory.appendingPathComponent(
            "engine-mutation-preparations.ledger",
            isDirectory: false
        )
        return AgentPolicyEngineMutationAdapter(
            system: system,
            preparationStore: try FileAgentPolicyEnginePreparationStore(
                fileURL: ledger
            ),
            decisionDeliverer: promptCenter,
            sessionID: sessionID,
            backend: backend
        )
    }

    func prepareMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        descriptor: ToolDescriptor,
        sealer: AgentMutationPreparationSealer
    ) async throws -> AgentMutationPreparation {
        try validate(context: context, invocation: invocation)
        guard descriptor.effectClass != .readOnlyLocal else {
            throw AgentPolicyEngineMutationAdapterError.readOnlyInvocation
        }
        let scope = try AgentPolicyMutationScope(
            runContext: context,
            workspaceBinding: system.workspaceBinding,
            sessionID: sessionID,
            backend: backend
        )
        let staged = try await system.mutationService.prepareAgentV2(
            scope: scope,
            descriptor: descriptor,
            invocation: invocation
        )
        let record = try AgentPolicyEnginePreparationRecord.make(staged)
        _ = try await preparationStore.commitIfAbsent(record)

        let sealed = sealer.seal(
            runID: record.runID,
            workspaceID: record.workspaceID,
            callID: record.callID,
            canonicalArgumentDigest: record.canonicalArgumentDigest,
            authorityToken: record.authorityToken,
            effectKeySHA256: record.effectKeySHA256,
            approvalRequest: staged.approvalRequest
        )
        if let existing = live[record.authorityToken],
           existing.sealed != sealed {
            throw AgentPolicyEngineMutationAdapterError.staleEngineSeal
        }
        let value = LivePreparation(
            staged: staged,
            record: record,
            sealed: sealed
        )
        live[record.authorityToken] = value
        if let requestID = staged.approvalRequest?.requestID {
            if let existing = approvalTokens[requestID],
               existing != record.authorityToken {
                throw AgentPolicyEngineMutationAdapterError
                    .approvalBindingMismatch
            }
            approvalTokens[requestID] = record.authorityToken
        }
        return sealed
    }

    func applyMutation(
        preparation: AgentMutationPreparation,
        approval: ApprovalResolution?
    ) async throws -> AgentMutationToolOutput {
        guard let current = live[preparation.authorityToken] else {
            throw AgentPolicyEngineMutationAdapterError.preparationNotFound
        }
        // Equality includes AgentEngine's module-private seal. The adapter
        // cannot forge or inspect that seal, but can require the exact value it
        // returned from the engine-supplied sealer.
        guard current.sealed == preparation else {
            throw AgentPolicyEngineMutationAdapterError.staleEngineSeal
        }
        guard let durable = try await preparationStore.record(
            authorityToken: preparation.authorityToken
        ), durable == current.record,
            preparation.runID == durable.runID,
            preparation.workspaceID == durable.workspaceID,
            preparation.callID == durable.callID,
            preparation.canonicalArgumentDigest
                == durable.canonicalArgumentDigest,
            preparation.effectKeySHA256 == durable.effectKeySHA256
        else {
            throw AgentPolicyEngineMutationAdapterError
                .preparationBindingMismatch
        }

        let result = try await system.mutationService.applyAgentV2(
            current.staged,
            approval: approval
        )
        let output = try Self.classifiedOutput(result)
        live.removeValue(forKey: preparation.authorityToken)
        if let requestID = current.staged.approvalRequest?.requestID {
            approvalTokens.removeValue(forKey: requestID)
        }
        return output
    }

    func recoverMutation(
        context: AgentRunContext,
        invocation: ToolInvocation,
        effectKeySHA256: SHA256Digest
    ) async throws -> AgentMutationRecoveryDisposition {
        try validate(context: context, invocation: invocation)
        guard let durable = try await preparationStore.record(
            effectKeySHA256: effectKeySHA256
        ) else { return .noDurableRecord }
        guard durable.effectKeySHA256 == effectKeySHA256,
              durable.matches(context: context, invocation: invocation)
        else {
            throw AgentPolicyEngineMutationAdapterError
                .preparationBindingMismatch
        }
        switch try await system.recoverMutation(
            effectKeySHA256: effectKeySHA256
        ) {
        case let .evidenceSettled(result), let .alreadySettled(result):
            return .settled(try Self.classifiedOutput(result))
        case let .reconciliationRequired(digest):
            return .reconciliationRequired(digest)
        case .noDurableRecord:
            return .noDurableRecord
        }
    }

    func resolveApproval(
        _ request: ApprovalRequest
    ) async throws -> ApprovalResolution {
        guard let token = approvalTokens[request.requestID],
              let current = live[token],
              current.staged.approvalRequest == request
        else {
            throw AgentPolicyEngineMutationAdapterError.approvalNotPending
        }
        let resolution = try await system.mutationService.resolveApproval(
            for: current.staged
        )
        guard resolution.requestID == request.requestID,
              resolution.callID == request.binding.callID
        else {
            throw AgentPolicyEngineMutationAdapterError
                .approvalBindingMismatch
        }
        return resolution
    }

    func deliverApprovalDecision(
        _ command: ApprovalDecisionCommand,
        for request: ApprovalRequest
    ) async throws {
        guard command.requestID == request.requestID,
              command.callID == request.binding.callID,
              let token = approvalTokens[request.requestID],
              live[token]?.staged.approvalRequest == request
        else {
            throw AgentPolicyEngineMutationAdapterError
                .approvalBindingMismatch
        }
        try await decisionDeliverer.deliver(
            decision: command.decision,
            requestID: command.requestID
        )
    }

    private func validate(
        context: AgentRunContext,
        invocation: ToolInvocation
    ) throws {
        guard context.lineage.validationError == nil,
              context.workspaceID == system.workspaceBinding.workspaceID
        else {
            throw AgentPolicyEngineMutationAdapterError.invalidContext
        }
        guard context.engineVersion == .agentHarnessV2 else {
            throw AgentPolicyEngineMutationAdapterError.unsupportedEngine
        }
    }

    private static func classifiedOutput(
        _ result: AgentPolicyUnclassifiedMutationResult
    ) throws -> AgentMutationToolOutput {
        guard result.origin == .agentV2,
              MutationEffectOutput.presentationClassification == .unclassified
        else {
            throw AgentPolicyEngineMutationAdapterError
                .unclassifiedResultRejected
        }
        let raw = result.unclassifiedOutput
        let evidence = try result.unclassifiedEvidence.map { fact in
            ToolEvidence(
                kind: fact.kind.rawValue,
                digest: fact.digest.rawValue,
                metadata: .object([
                    "target_count": try canonicalNonnegativeJSONInteger(
                        fact.targets.count
                    ),
                ])
            )
        }
        var warnings: [String] = []
        if raw.summaryWasTruncated { warnings.append("summary_truncated") }
        if raw.textWasTruncated { warnings.append("output_truncated") }
        var providerOutput: [String: JSONValue] = [
            "status": .string("committed"),
            "operation": .string(raw.kind.rawValue),
            "output_sha256": .string(raw.outputSHA256.rawValue),
            "target_count": try canonicalNonnegativeJSONInteger(
                raw.targets.count
            ),
            "original_text_utf8_bytes": try canonicalNonnegativeJSONInteger(
                raw.originalTextUTF8ByteCount
            ),
            "text_truncated": .bool(raw.textWasTruncated),
        ]
        if let exit = raw.commandExitCode {
            providerOutput["command_exit_code"] = .number(.integer(
                Int64(exit)
            ))
        }
        return AgentMutationToolOutput(
            receipt: AgentMutationReceipt(
                effectKeySHA256: result.effectKeySHA256,
                applicationSHA256: result.applicationSHA256,
                evidenceSHA256: result.evidenceSHA256,
                finalRecordSHA256: result.finalRecordSHA256,
                receiptSHA256: result.receiptSHA256
            ),
            output: .object(providerOutput),
            artifacts: [],
            evidence: evidence,
            warnings: warnings
        )
    }

    /// Event bodies are encoded as ordinary JSON. Positive JSON integers do
    /// not retain whether Swift originally supplied an `Int64` or `UInt64`,
    /// and `JSONNumber` deliberately decodes in the signed range first. Keep
    /// nonnegative receipt metadata in that canonical signed range so the
    /// journal's exact append-receipt equality check survives encode/decode.
    static func canonicalNonnegativeJSONInteger(
        _ value: Int
    ) throws -> JSONValue {
        guard value >= 0, let exact = Int64(exactly: value) else {
            throw AgentPolicyEngineMutationAdapterError.numericValueOutOfRange
        }
        return .number(.integer(exact))
    }
}
