import AgentDomain
import AgentTools
import Foundation

actor SingleUsePolicyAuthorityGate {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

public enum ToolEffectAuthorizationSource: Sendable {
    case policy(PolicyAuthorizationSource)
    case durableApproval(
        requestID: ApprovalRequestID,
        consumptionSHA256: SHA256Digest,
        recovery: Bool
    )
}

/// Fresh revalidation intent. It is still copyable and therefore is not the
/// capability accepted by an executor. It must first pass through
/// `ToolEffectClaimAuthority`, whose durable compare-insert returns the only
/// executor-facing `ClaimedToolEffectPermit`.
public struct ToolEffectPermit: Sendable {
    public let origin: MutationOrigin
    public let requestSHA256: SHA256Digest
    public let policySHA256: SHA256Digest
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let canonicalArgumentDigest: String
    public let operationPayloadSHA256: SHA256Digest
    public let operationPreviewSHA256: SHA256Digest?
    public let callID: ToolCallID
    public let idempotencyKey: String
    public let workspaceID: WorkspaceID
    public let resolvedTargets: [NormalizedToolTarget]
    public let resolutionAttestationSHA256: SHA256Digest
    public let authorizedAt: AgentInstant
    public let expiresAt: AgentInstant
    public let effectKeySHA256: SHA256Digest
    public let source: ToolEffectAuthorizationSource

    let workspaceLease: WorkspaceExecutionLease
    let targetAttestation: ResolvedInvocationTargets
    let policyRevision: TrustedPolicyRevision
    let descriptor: ToolDescriptor
    let invocation: ToolInvocation

    private struct EffectKeyMaterial: Codable {
        let origin: MutationOrigin
        let requestSHA256: SHA256Digest
        let policySHA256: SHA256Digest
        let tool: ToolIdentity
        let effectClass: ToolEffectClass
        let canonicalArgumentDigest: String
        let operationPayloadSHA256: SHA256Digest
        let operationPreviewSHA256: SHA256Digest?
        let callID: ToolCallID
        let idempotencyKey: String
        let workspaceID: WorkspaceID
        let resolutionAttestationSHA256: SHA256Digest
    }

    init(
        origin: MutationOrigin,
        requestSHA256: SHA256Digest,
        policyRevision: TrustedPolicyRevision,
        tool: ToolIdentity,
        effectClass: ToolEffectClass,
        canonicalArgumentDigest: String,
        operationPayloadSHA256: SHA256Digest,
        operationPreviewSHA256: SHA256Digest?,
        callID: ToolCallID,
        idempotencyKey: String,
        authorizedAt: AgentInstant,
        expiresAt: AgentInstant,
        source: ToolEffectAuthorizationSource,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        workspaceLease: WorkspaceExecutionLease,
        targetAttestation: ResolvedInvocationTargets
    ) throws {
        guard authorizedAt < expiresAt else {
            throw ToolEffectClaimError.expired
        }
        let derivedPreview = try? MutationEffectApprovalPreview.derive(
            origin: origin,
            descriptor: descriptor,
            invocation: invocation
        )
        guard descriptor.identity == tool,
              descriptor.effectClass == effectClass,
              invocation.tool == tool,
              invocation.effectClass == effectClass,
              invocation.callID == callID,
              invocation.idempotencyKey == idempotencyKey,
              invocation.canonicalArgumentDigest == canonicalArgumentDigest,
              operationPayloadSHA256
                == (try? SHA256Digest(canonicalArgumentDigest)),
              (try? descriptor.canonicalArgumentDigest(
                for: invocation.arguments
              )) == canonicalArgumentDigest,
              (effectClass == .readOnlyLocal
                ? operationPreviewSHA256 == nil
                : operationPreviewSHA256 == derivedPreview?.previewSHA256)
        else { throw ToolEffectClaimError.invalidOperationBinding }
        self.origin = origin
        self.requestSHA256 = requestSHA256
        policySHA256 = policyRevision.policySHA256
        self.tool = tool
        self.effectClass = effectClass
        self.canonicalArgumentDigest = canonicalArgumentDigest
        self.operationPayloadSHA256 = operationPayloadSHA256
        self.operationPreviewSHA256 = operationPreviewSHA256
        self.callID = callID
        self.idempotencyKey = idempotencyKey
        workspaceID = workspaceLease.workspaceID
        resolvedTargets = workspaceLease.resolvedTargets
        resolutionAttestationSHA256 =
            workspaceLease.resolutionAttestationSHA256
        self.authorizedAt = authorizedAt
        self.expiresAt = expiresAt
        effectKeySHA256 = try PolicyCanonicalDigest.sha256(
            domain: .toolEffectKey,
            EffectKeyMaterial(
                origin: origin,
                requestSHA256: requestSHA256,
                policySHA256: policyRevision.policySHA256,
                tool: tool,
                effectClass: effectClass,
                canonicalArgumentDigest: canonicalArgumentDigest,
                operationPayloadSHA256: operationPayloadSHA256,
                operationPreviewSHA256: operationPreviewSHA256,
                callID: callID,
                idempotencyKey: idempotencyKey,
                workspaceID: workspaceLease.workspaceID,
                resolutionAttestationSHA256:
                    workspaceLease.resolutionAttestationSHA256
            )
        )
        self.source = source
        self.descriptor = descriptor
        self.invocation = invocation
        self.workspaceLease = workspaceLease
        self.targetAttestation = targetAttestation
        self.policyRevision = policyRevision
    }
}

public struct ToolEffectClaimRecord: Codable, Equatable, Sendable {
    public let origin: MutationOrigin
    public let effectKeySHA256: SHA256Digest
    public let requestSHA256: SHA256Digest
    public let policySHA256: SHA256Digest
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let canonicalArgumentDigest: String
    public let operationPayloadSHA256: SHA256Digest
    public let operationPreviewSHA256: SHA256Digest?
    public let callID: ToolCallID
    public let idempotencyKey: String
    public let workspaceID: WorkspaceID
    public let resolutionAttestationSHA256: SHA256Digest
    public let claimedAt: AgentInstant
    public let claimSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let origin: MutationOrigin
        let effectKeySHA256: SHA256Digest
        let requestSHA256: SHA256Digest
        let policySHA256: SHA256Digest
        let tool: ToolIdentity
        let effectClass: ToolEffectClass
        let canonicalArgumentDigest: String
        let operationPayloadSHA256: SHA256Digest
        let operationPreviewSHA256: SHA256Digest?
        let callID: ToolCallID
        let idempotencyKey: String
        let workspaceID: WorkspaceID
        let resolutionAttestationSHA256: SHA256Digest
        let claimedAt: AgentInstant
    }

    static func make(
        permit: ToolEffectPermit,
        claimedAt: AgentInstant
    ) throws -> Self {
        let material = DigestMaterial(
            origin: permit.origin,
            effectKeySHA256: permit.effectKeySHA256,
            requestSHA256: permit.requestSHA256,
            policySHA256: permit.policySHA256,
            tool: permit.tool,
            effectClass: permit.effectClass,
            canonicalArgumentDigest: permit.canonicalArgumentDigest,
            operationPayloadSHA256: permit.operationPayloadSHA256,
            operationPreviewSHA256: permit.operationPreviewSHA256,
            callID: permit.callID,
            idempotencyKey: permit.idempotencyKey,
            workspaceID: permit.workspaceID,
            resolutionAttestationSHA256:
                permit.resolutionAttestationSHA256,
            claimedAt: claimedAt
        )
        return Self(
            material: material,
            claimSHA256: try PolicyCanonicalDigest.sha256(
                domain: .toolEffectClaim,
                material
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let material = DigestMaterial(
            origin: try container.decode(MutationOrigin.self, forKey: .origin),
            effectKeySHA256: try container.decode(
                SHA256Digest.self,
                forKey: .effectKeySHA256
            ),
            requestSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .requestSHA256
            ),
            policySHA256: try container.decode(
                SHA256Digest.self,
                forKey: .policySHA256
            ),
            tool: try container.decode(ToolIdentity.self, forKey: .tool),
            effectClass: try container.decode(
                ToolEffectClass.self,
                forKey: .effectClass
            ),
            canonicalArgumentDigest: try container.decode(
                String.self,
                forKey: .canonicalArgumentDigest
            ),
            operationPayloadSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .operationPayloadSHA256
            ),
            operationPreviewSHA256: try container.decode(
                SHA256Digest?.self,
                forKey: .operationPreviewSHA256
            ),
            callID: try container.decode(ToolCallID.self, forKey: .callID),
            idempotencyKey: try container.decode(
                String.self,
                forKey: .idempotencyKey
            ),
            workspaceID: try container.decode(
                WorkspaceID.self,
                forKey: .workspaceID
            ),
            resolutionAttestationSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .resolutionAttestationSHA256
            ),
            claimedAt: try container.decode(
                AgentInstant.self,
                forKey: .claimedAt
            )
        )
        let digest = try PolicyCanonicalDigest.sha256(
            domain: .toolEffectClaim,
            material
        )
        guard digest == (try container.decode(
            SHA256Digest.self,
            forKey: .claimSHA256
        )) else { throw ToolEffectClaimError.corruptEvidence }
        self.init(material: material, claimSHA256: digest)
    }

    private init(material: DigestMaterial, claimSHA256: SHA256Digest) {
        origin = material.origin
        effectKeySHA256 = material.effectKeySHA256
        requestSHA256 = material.requestSHA256
        policySHA256 = material.policySHA256
        tool = material.tool
        effectClass = material.effectClass
        canonicalArgumentDigest = material.canonicalArgumentDigest
        operationPayloadSHA256 = material.operationPayloadSHA256
        operationPreviewSHA256 = material.operationPreviewSHA256
        callID = material.callID
        idempotencyKey = material.idempotencyKey
        workspaceID = material.workspaceID
        resolutionAttestationSHA256 =
            material.resolutionAttestationSHA256
        claimedAt = material.claimedAt
        self.claimSHA256 = claimSHA256
    }

    func isCanonical() -> Bool {
        let material = DigestMaterial(
            origin: origin,
            effectKeySHA256: effectKeySHA256,
            requestSHA256: requestSHA256,
            policySHA256: policySHA256,
            tool: tool,
            effectClass: effectClass,
            canonicalArgumentDigest: canonicalArgumentDigest,
            operationPayloadSHA256: operationPayloadSHA256,
            operationPreviewSHA256: operationPreviewSHA256,
            callID: callID,
            idempotencyKey: idempotencyKey,
            workspaceID: workspaceID,
            resolutionAttestationSHA256: resolutionAttestationSHA256,
            claimedAt: claimedAt
        )
        return (try? PolicyCanonicalDigest.sha256(
            domain: .toolEffectClaim,
            material
        )) == claimSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case origin
        case effectKeySHA256
        case requestSHA256
        case policySHA256
        case tool
        case effectClass
        case canonicalArgumentDigest
        case operationPayloadSHA256
        case operationPreviewSHA256
        case callID
        case idempotencyKey
        case workspaceID
        case resolutionAttestationSHA256
        case claimedAt
        case claimSHA256
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(origin, forKey: .origin)
        try container.encode(effectKeySHA256, forKey: .effectKeySHA256)
        try container.encode(requestSHA256, forKey: .requestSHA256)
        try container.encode(policySHA256, forKey: .policySHA256)
        try container.encode(tool, forKey: .tool)
        try container.encode(effectClass, forKey: .effectClass)
        try container.encode(
            canonicalArgumentDigest,
            forKey: .canonicalArgumentDigest
        )
        try container.encode(
            operationPayloadSHA256,
            forKey: .operationPayloadSHA256
        )
        try container.encode(
            operationPreviewSHA256,
            forKey: .operationPreviewSHA256
        )
        try container.encode(callID, forKey: .callID)
        try container.encode(idempotencyKey, forKey: .idempotencyKey)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(
            resolutionAttestationSHA256,
            forKey: .resolutionAttestationSHA256
        )
        try container.encode(claimedAt, forKey: .claimedAt)
        try container.encode(claimSHA256, forKey: .claimSHA256)
    }
}

public enum ToolEffectClaimDisposition: Equatable, Sendable {
    case committed
    case alreadyPresent(ToolEffectClaimRecord)
}

public protocol DurableToolEffectClaimStore: Sendable {
    /// Must make compare-and-insert durable before returning `.committed`.
    func commitIfAbsent(
        _ record: ToolEffectClaimRecord
    ) async throws -> ToolEffectClaimDisposition
    func claim(
        effectKeySHA256: SHA256Digest
    ) async throws -> ToolEffectClaimRecord?
}

public struct ToolEffectClaimSnapshot: Codable, Equatable, Sendable {
    public let claims: [ToolEffectClaimRecord]
    public init(claims: [ToolEffectClaimRecord]) { self.claims = claims }
}

public actor InMemoryToolEffectClaimStore: DurableToolEffectClaimStore {
    private var claims: [SHA256Digest: ToolEffectClaimRecord]

    public init() { claims = [:] }

    public init(restoring snapshot: ToolEffectClaimSnapshot) throws {
        var restored: [SHA256Digest: ToolEffectClaimRecord] = [:]
        for claim in snapshot.claims {
            guard claim.isCanonical(), restored[claim.effectKeySHA256] == nil else {
                throw ToolEffectClaimError.corruptEvidence
            }
            restored[claim.effectKeySHA256] = claim
        }
        claims = restored
    }

    public func commitIfAbsent(
        _ record: ToolEffectClaimRecord
    ) throws -> ToolEffectClaimDisposition {
        guard record.isCanonical() else {
            throw ToolEffectClaimError.corruptEvidence
        }
        if let existing = claims[record.effectKeySHA256] {
            return .alreadyPresent(existing)
        }
        claims[record.effectKeySHA256] = record
        return .committed
    }

    public func claim(
        effectKeySHA256: SHA256Digest
    ) -> ToolEffectClaimRecord? {
        claims[effectKeySHA256]
    }

    public func snapshot() -> ToolEffectClaimSnapshot {
        ToolEffectClaimSnapshot(claims: claims.values.sorted {
            $0.effectKeySHA256.rawValue < $1.effectKeySHA256.rawValue
        })
    }
}

/// The sole AgentPolicy value intended for the mutation/tool executor. M7 must
/// compare `effectKeySHA256` in its own idempotent mutation journal before
/// applying an effect and write the completion receipt under the same key.
/// Move-only so an executor cannot accidentally duplicate this capability in
/// memory. The eventual M7 mutation gateway must accept it as a `consuming`
/// parameter and still use `effectKeySHA256` in its durable effect journal;
/// move-only ownership cannot by itself settle crash ambiguity.
public struct ClaimedToolEffectPermit: ~Copyable, Sendable {
    public let origin: MutationOrigin
    public let effectKeySHA256: SHA256Digest
    public let requestSHA256: SHA256Digest
    public let policySHA256: SHA256Digest
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let canonicalArgumentDigest: String
    public let operationPayloadSHA256: SHA256Digest
    public let operationPreviewSHA256: SHA256Digest?
    public let callID: ToolCallID
    public let idempotencyKey: String
    public let claim: ToolEffectClaimRecord
    public let isRecovery: Bool
    public let workspaceID: WorkspaceID
    public let resolvedTargets: [NormalizedToolTarget]
    public let resolutionAttestationSHA256: SHA256Digest
    public let authorizedAt: AgentInstant
    public let expiresAt: AgentInstant
    public let claimedAt: AgentInstant

    let effectPermit: ToolEffectPermit
    let workspaceLease: WorkspaceExecutionLease

    init(
        effectPermit: ToolEffectPermit,
        claim: ToolEffectClaimRecord,
        workspaceLease: WorkspaceExecutionLease,
        isRecovery: Bool
    ) {
        origin = effectPermit.origin
        effectKeySHA256 = effectPermit.effectKeySHA256
        requestSHA256 = effectPermit.requestSHA256
        policySHA256 = effectPermit.policySHA256
        tool = effectPermit.tool
        effectClass = effectPermit.effectClass
        canonicalArgumentDigest = effectPermit.canonicalArgumentDigest
        operationPayloadSHA256 = effectPermit.operationPayloadSHA256
        operationPreviewSHA256 = effectPermit.operationPreviewSHA256
        callID = effectPermit.callID
        idempotencyKey = effectPermit.idempotencyKey
        self.effectPermit = effectPermit
        self.claim = claim
        self.workspaceLease = workspaceLease
        workspaceID = workspaceLease.workspaceID
        resolvedTargets = workspaceLease.resolvedTargets
        resolutionAttestationSHA256 =
            workspaceLease.resolutionAttestationSHA256
        authorizedAt = effectPermit.authorizedAt
        expiresAt = effectPermit.expiresAt
        claimedAt = claim.claimedAt
        self.isRecovery = isRecovery
    }
}

public enum ToolEffectClaimError: Error, Equatable, Sendable {
    case invalidOperationBinding
    case targetRevalidationFailed
    case policyChanged
    case clockUnavailable
    case expired
    case durableCommitFailed
    case alreadyClaimed
    case claimMissing
    case claimMismatch
    case corruptEvidence
}

public final actor ToolEffectClaimAuthority {
    private let store: any DurableToolEffectClaimStore
    private let clock: any PolicyClock
    private let resolver: WorkspaceTargetResolverAuthority
    private let policyRevisionAuthority: PolicyRevisionAuthority

    public init(
        store: any DurableToolEffectClaimStore,
        clock: any PolicyClock,
        resolver: WorkspaceTargetResolverAuthority,
        policyRevisionAuthority: PolicyRevisionAuthority
    ) {
        self.store = store
        self.clock = clock
        self.resolver = resolver
        self.policyRevisionAuthority = policyRevisionAuthority
    }

    public func claim(
        _ permit: ToolEffectPermit
    ) async throws -> ClaimedToolEffectPermit {
        try requireCurrentPolicy(for: permit)
        // Reject an already-stale intent before consuming its durable key.
        _ = try await revalidate(permit)
        try requireCurrentPolicy(for: permit)
        let now = try await trustedNow()
        guard now >= permit.authorizedAt, now < permit.expiresAt else {
            throw ToolEffectClaimError.expired
        }
        let record = try ToolEffectClaimRecord.make(
            permit: permit,
            claimedAt: now
        )
        do {
            switch try await store.commitIfAbsent(record) {
            case .committed:
                // The durable transaction can block and the workspace can
                // change while it runs. Make target resolution the final slow
                // operation, then recheck time and policy immediately before
                // returning the executor-facing capability.
                let workspaceLease = try await revalidate(permit)
                let finalNow = try await trustedNow()
                guard finalNow >= record.claimedAt,
                      finalNow < permit.expiresAt
                else { throw ToolEffectClaimError.expired }
                try requireCurrentPolicy(for: permit)
                return ClaimedToolEffectPermit(
                    effectPermit: permit,
                    claim: record,
                    workspaceLease: workspaceLease,
                    isRecovery: false
                )
            case .alreadyPresent:
                throw ToolEffectClaimError.alreadyClaimed
            }
        } catch let error as ToolEffectClaimError {
            throw error
        } catch {
            throw ToolEffectClaimError.durableCommitFailed
        }
    }

    /// Explicit crash recovery for a durable claim. It remints the exact same
    /// effect key only; the executor must use that key in its idempotent
    /// mutation journal so recovery cannot duplicate an already-applied effect.
    public func recoverPendingClaim(
        _ permit: ToolEffectPermit
    ) async throws -> ClaimedToolEffectPermit {
        try requireCurrentPolicy(for: permit)
        guard let record = try await store.claim(
            effectKeySHA256: permit.effectKeySHA256
        ) else { throw ToolEffectClaimError.claimMissing }
        guard record.isCanonical(),
              record.origin == permit.origin,
              record.effectKeySHA256 == permit.effectKeySHA256,
              record.requestSHA256 == permit.requestSHA256,
              record.policySHA256 == permit.policySHA256,
              record.tool == permit.tool,
              record.effectClass == permit.effectClass,
              record.canonicalArgumentDigest
                == permit.canonicalArgumentDigest,
              record.operationPayloadSHA256
                == permit.operationPayloadSHA256,
              record.operationPreviewSHA256
                == permit.operationPreviewSHA256,
              record.callID == permit.callID,
              record.idempotencyKey == permit.idempotencyKey,
              record.workspaceID == permit.workspaceID,
              record.resolutionAttestationSHA256
                == permit.resolutionAttestationSHA256,
              record.claimedAt < permit.expiresAt
        else { throw ToolEffectClaimError.claimMismatch }
        let now = try await trustedNow()
        guard now >= record.claimedAt, now < permit.expiresAt else {
            throw ToolEffectClaimError.expired
        }
        let workspaceLease = try await revalidate(permit)
        let finalNow = try await trustedNow()
        guard finalNow >= record.claimedAt,
              finalNow < permit.expiresAt
        else { throw ToolEffectClaimError.expired }
        try requireCurrentPolicy(for: permit)
        return ClaimedToolEffectPermit(
            effectPermit: permit,
            claim: record,
            workspaceLease: workspaceLease,
            isRecovery: true
        )
    }

    private func revalidate(
        _ permit: ToolEffectPermit
    ) async throws -> WorkspaceExecutionLease {
        do {
            return try await resolver.revalidateForExecution(
                permit.workspaceLease,
                against: permit.targetAttestation
            )
        } catch {
            throw ToolEffectClaimError.targetRevalidationFailed
        }
    }

    private func trustedNow() async throws -> AgentInstant {
        do {
            return try await clock.currentInstant()
        } catch {
            throw ToolEffectClaimError.clockUnavailable
        }
    }

    private func requireCurrentPolicy(
        for permit: ToolEffectPermit
    ) throws {
        guard permit.policyRevision
                == policyRevisionAuthority.currentRevision()
        else { throw ToolEffectClaimError.policyChanged }
    }
}
