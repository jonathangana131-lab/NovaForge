import AgentDomain
import AgentTools
import Foundation

public protocol PolicyClock: Sendable {
    func currentInstant() async throws -> AgentInstant
}

public struct SystemPolicyClock: PolicyClock {
    public init() {}
    public func currentInstant() async -> AgentInstant { AgentInstant(Date()) }
}

/// Process-local proof that a policy decision came from the exact configured
/// policy revision authority. The digest is durable; the seal and generation
/// deliberately are not. A freshly composed process may rebind durable records
/// by digest, while any in-process policy replacement invalidates old permits.
struct TrustedPolicyRevision: Equatable, Sendable {
    let policySHA256: SHA256Digest
    let generation: UInt64
    fileprivate let authoritySeal: UUID
}

private struct TrustedPolicyComposition: Sendable {
    let configuration: RiskPolicyConfiguration
    let revision: TrustedPolicyRevision
}

/// The single trusted source of policy configuration and revision freshness.
/// Evaluators obtain their configuration from this authority rather than from
/// an independently supplied value. Approval and effect authorities must share
/// the same instance; there is intentionally no default or optional source.
public final class PolicyRevisionAuthority: @unchecked Sendable {
    private static let hardFloorVersion = "nova-hard-floor-v3"

    private let lock = NSLock()
    private let authoritySeal = UUID()
    private var configuration: RiskPolicyConfiguration
    private var policySHA256: SHA256Digest
    private var generation: UInt64 = 1
    private var approvalRevisionByRegistrationKey: [
        SHA256Digest: TrustedPolicyRevision
    ] = [:]

    public init(configuration: RiskPolicyConfiguration) throws {
        self.configuration = configuration
        policySHA256 = try Self.digest(for: configuration)
    }

    /// Replaces the complete composed policy. Reinstalling an identical value
    /// is a no-op; every actual change advances the sealed process generation,
    /// including a later change back to an earlier configuration.
    @discardableResult
    public func replaceCurrentConfiguration(
        _ configuration: RiskPolicyConfiguration
    ) throws -> SHA256Digest {
        let digest = try Self.digest(for: configuration)
        lock.lock()
        defer { lock.unlock() }
        guard configuration != self.configuration else { return policySHA256 }
        guard generation < UInt64.max else {
            throw RiskPolicyConfigurationError.policyRevisionExhausted
        }
        self.configuration = configuration
        policySHA256 = digest
        generation += 1
        return digest
    }

    public func currentPolicySHA256() -> SHA256Digest {
        lock.lock()
        defer { lock.unlock() }
        return policySHA256
    }

    fileprivate func composition() -> TrustedPolicyComposition {
        lock.lock()
        defer { lock.unlock() }
        return TrustedPolicyComposition(
            configuration: configuration,
            revision: currentRevisionWhileLocked()
        )
    }

    func currentRevision() -> TrustedPolicyRevision {
        lock.lock()
        defer { lock.unlock() }
        return currentRevisionWhileLocked()
    }

    /// Binds a durable approval's stable registration identity to the process
    /// revision that registered it. This catches A -> B -> A policy changes even
    /// though the durable digest for A is stable.
    func bindApprovalRevision(
        registrationKeySHA256: SHA256Digest,
        revision: TrustedPolicyRevision
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == currentRevisionWhileLocked() else { return false }
        if let existing = approvalRevisionByRegistrationKey[
            registrationKeySHA256
        ] {
            return existing == revision
        }
        approvalRevisionByRegistrationKey[registrationKeySHA256] = revision
        return true
    }

    /// A fresh process has no sealed registration map, so an exact durable
    /// digest may rebind to the new process revision. Once rebound, any policy
    /// change in that process invalidates the approval even if a later policy
    /// happens to restore the same configuration digest.
    func revisionForDurableApproval(
        registrationKeySHA256: SHA256Digest,
        policySHA256: SHA256Digest
    ) -> TrustedPolicyRevision? {
        lock.lock()
        defer { lock.unlock() }
        let current = currentRevisionWhileLocked()
        guard current.policySHA256 == policySHA256 else { return nil }
        if let existing = approvalRevisionByRegistrationKey[
            registrationKeySHA256
        ] {
            return existing == current ? current : nil
        }
        approvalRevisionByRegistrationKey[registrationKeySHA256] = current
        return current
    }

    private func currentRevisionWhileLocked() -> TrustedPolicyRevision {
        TrustedPolicyRevision(
            policySHA256: policySHA256,
            generation: generation,
            authoritySeal: authoritySeal
        )
    }

    private static func digest(
        for configuration: RiskPolicyConfiguration
    ) throws -> SHA256Digest {
        try PolicyCanonicalDigest.sha256(
            domain: .configuration,
            PolicyDigestMaterial(
                hardFloorVersion: hardFloorVersion,
                configuration: configuration
            )
        )
    }
}

public enum PolicyBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case onDevice
    case hosted
    case worker
}

public struct PolicyRestrictionSet: Codable, Equatable, Sendable {
    public let deniedBackends: [PolicyBackend]
    public let deniedTools: [ToolIdentity]
    public let deniedCapabilities: [ToolCapability]
    public let deniedEffectClasses: [ToolEffectClass]

    public init(
        deniedBackends: [PolicyBackend] = [],
        deniedTools: [ToolIdentity] = [],
        deniedCapabilities: [ToolCapability] = [],
        deniedEffectClasses: [ToolEffectClass] = []
    ) {
        self.deniedBackends = Array(Set(deniedBackends)).sorted {
            $0.rawValue < $1.rawValue
        }
        self.deniedTools = Array(Set(deniedTools)).sorted {
            ($0.name, $0.version) < ($1.name, $1.version)
        }
        self.deniedCapabilities = Array(Set(deniedCapabilities)).sorted {
            $0.rawValue < $1.rawValue
        }
        self.deniedEffectClasses = Array(Set(deniedEffectClasses)).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            deniedBackends: try container.decode(
                [PolicyBackend].self,
                forKey: .deniedBackends
            ),
            deniedTools: try container.decode(
                [ToolIdentity].self,
                forKey: .deniedTools
            ),
            deniedCapabilities: try container.decode(
                [ToolCapability].self,
                forKey: .deniedCapabilities
            ),
            deniedEffectClasses: try container.decode(
                [ToolEffectClass].self,
                forKey: .deniedEffectClasses
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case deniedBackends
        case deniedTools
        case deniedCapabilities
        case deniedEffectClasses
    }
}

public struct UserPolicyRestrictions: Codable, Equatable, Sendable {
    public let restrictions: PolicyRestrictionSet
    public let allowedProjectIDs: [ProjectID]
    public let allowedWorkspaceIDs: [WorkspaceID]
    /// Prefixes are matched against trusted resolved relative paths, never the
    /// raw argument spelling supplied by a model or command parser caller.
    public let allowedTargetPrefixes: [String]
    public let deniedTargetPrefixes: [String]

    public init(
        restrictions: PolicyRestrictionSet = PolicyRestrictionSet(),
        allowedProjectIDs: [ProjectID] = [],
        allowedWorkspaceIDs: [WorkspaceID] = [],
        allowedTargetPrefixes: [String] = [],
        deniedTargetPrefixes: [String] = []
    ) throws {
        self.restrictions = restrictions
        self.allowedProjectIDs = Array(Set(allowedProjectIDs)).sorted {
            $0.description < $1.description
        }
        self.allowedWorkspaceIDs = Array(Set(allowedWorkspaceIDs)).sorted {
            $0.description < $1.description
        }
        self.allowedTargetPrefixes = try Self.normalizePrefixes(
            allowedTargetPrefixes
        )
        self.deniedTargetPrefixes = try Self.normalizePrefixes(
            deniedTargetPrefixes
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            restrictions: container.decode(
                PolicyRestrictionSet.self,
                forKey: .restrictions
            ),
            allowedProjectIDs: container.decode(
                [ProjectID].self,
                forKey: .allowedProjectIDs
            ),
            allowedWorkspaceIDs: container.decode(
                [WorkspaceID].self,
                forKey: .allowedWorkspaceIDs
            ),
            allowedTargetPrefixes: container.decode(
                [String].self,
                forKey: .allowedTargetPrefixes
            ),
            deniedTargetPrefixes: container.decode(
                [String].self,
                forKey: .deniedTargetPrefixes
            )
        )
    }

    private static func normalizePrefixes(_ values: [String]) throws -> [String] {
        try NormalizedToolTarget.canonicalizePrefixes(values)
    }

    private enum CodingKeys: String, CodingKey {
        case restrictions
        case allowedProjectIDs
        case allowedWorkspaceIDs
        case allowedTargetPrefixes
        case deniedTargetPrefixes
    }
}

public enum PolicyGrantScope: Codable, Equatable, Sendable {
    case oneTime(nonce: String)
    case session(sessionID: String)
    case project(ProjectID)
}

public struct PolicyGrant: Codable, Equatable, Sendable {
    public let grantID: String
    public let scope: PolicyGrantScope
    public let tool: ToolIdentity
    public let targetPrefixes: [String]
    public let expiresAt: AgentInstant

    public init(
        grantID: String,
        scope: PolicyGrantScope,
        tool: ToolIdentity,
        targetPrefixes: [String],
        expiresAt: AgentInstant
    ) throws {
        self.grantID = try Self.validatedToken(grantID, error: .emptyGrantID)
        switch scope {
        case let .oneTime(nonce):
            self.scope = .oneTime(nonce: try Self.validatedToken(
                nonce,
                error: .emptyGrantNonce
            ))
        case let .session(sessionID):
            self.scope = .session(sessionID: try Self.validatedToken(
                sessionID,
                error: .emptySessionID
            ))
        case .project:
            self.scope = scope
        }
        self.tool = tool
        self.targetPrefixes = try NormalizedToolTarget.canonicalizePrefixes(
            targetPrefixes
        )
        self.expiresAt = expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            grantID: container.decode(String.self, forKey: .grantID),
            scope: container.decode(PolicyGrantScope.self, forKey: .scope),
            tool: container.decode(ToolIdentity.self, forKey: .tool),
            targetPrefixes: container.decode(
                [String].self,
                forKey: .targetPrefixes
            ),
            expiresAt: container.decode(AgentInstant.self, forKey: .expiresAt)
        )
    }

    private static func validatedToken(
        _ value: String,
        error: RiskPolicyConfigurationError
    ) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && $0.properties.generalCategory != .format
              })
        else { throw error }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case grantID
        case scope
        case tool
        case targetPrefixes
        case expiresAt
    }
}

public struct RiskPolicyConfiguration: Codable, Equatable, Sendable {
    public let administrative: PolicyRestrictionSet
    public let user: UserPolicyRestrictions
    public let grants: [PolicyGrant]
    public let advisoryTimeoutMilliseconds: UInt64

    public init(
        administrative: PolicyRestrictionSet = PolicyRestrictionSet(),
        user: UserPolicyRestrictions = try! UserPolicyRestrictions(),
        grants: [PolicyGrant] = [],
        advisoryTimeoutMilliseconds: UInt64 = 1_000
    ) throws {
        guard (1 ... 60_000).contains(advisoryTimeoutMilliseconds) else {
            throw RiskPolicyConfigurationError.invalidAdvisoryTimeout
        }
        var grantIDs = Set<String>()
        for grant in grants where !grantIDs.insert(grant.grantID).inserted {
            throw RiskPolicyConfigurationError.duplicateGrantID(grant.grantID)
        }
        self.administrative = administrative
        self.user = user
        self.grants = grants.sorted { $0.grantID < $1.grantID }
        self.advisoryTimeoutMilliseconds = advisoryTimeoutMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            administrative: container.decode(
                PolicyRestrictionSet.self,
                forKey: .administrative
            ),
            user: container.decode(UserPolicyRestrictions.self, forKey: .user),
            grants: container.decode([PolicyGrant].self, forKey: .grants),
            advisoryTimeoutMilliseconds: container.decode(
                UInt64.self,
                forKey: .advisoryTimeoutMilliseconds
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case administrative
        case user
        case grants
        case advisoryTimeoutMilliseconds
    }
}

public enum RiskPolicyConfigurationError: Error, Equatable, Sendable {
    case invalidAdvisoryTimeout
    case emptyGrantID
    case emptyGrantNonce
    case emptySessionID
    case duplicateGrantID(String)
    case policyRevisionExhausted
}

/// Opaque request assembled from the canonical tool catalog and the configured
/// target resolver. There is no command-target or timestamp parameter for a
/// caller to spoof.
public struct RiskPolicyRequest: Sendable {
    private enum ContractFamily {
        case provider
        case nonProvider
    }

    public let origin: MutationOrigin
    public let runID: RunID
    public let projectID: ProjectID?
    public let workspaceID: WorkspaceID
    public let sessionID: String?
    public let backend: PolicyBackend
    public let descriptor: ToolDescriptor
    public let invocation: ToolInvocation
    public let logicalTargets: [NormalizedToolTarget]
    public let resolvedTargets: [NormalizedToolTarget]
    public let capabilities: [ToolCapability]
    public let argumentSHA256: SHA256Digest
    public let operationPreviewSHA256: SHA256Digest?
    public let requestSHA256: SHA256Digest
    public let targetAttestationSHA256: SHA256Digest

    let targetAttestation: ResolvedInvocationTargets

    private struct DigestMaterial: Codable {
        let origin: MutationOrigin
        let runID: RunID
        let projectID: ProjectID?
        let workspaceID: WorkspaceID
        let sessionID: String?
        let backend: PolicyBackend
        let callID: ToolCallID
        let modelAttemptID: AttemptID
        let tool: ToolIdentity
        let argumentSHA256: SHA256Digest
        let operationPreviewSHA256: SHA256Digest?
        let idempotencyKey: String
        let effectClass: ToolEffectClass
        let locality: ToolExecutionLocality
        let logicalTargets: [NormalizedToolTarget]
        let resolvedTargets: [NormalizedToolTarget]
        let targetAttestationSHA256: SHA256Digest
        let capabilities: [ToolCapability]
    }

    public static func resolveAgentV2(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveBound(
            origin: .agentV2,
            contractFamily: .provider,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            descriptor: descriptor,
            invocation: invocation,
            using: resolver
        )
    }

    public static func resolveV1Fallback(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveBound(
            origin: .v1Fallback,
            contractFamily: .provider,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            descriptor: descriptor,
            invocation: invocation,
            using: resolver
        )
    }

    private static func resolveBound(
        origin: MutationOrigin,
        contractFamily: ContractFamily,
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        switch contractFamily {
        case .provider:
            if origin.isProviderAgent,
               MutationEffectContractCatalog.canonicalNonProviderDescriptor(
                   for: descriptor.identity
               ) == descriptor {
                throw RiskPolicyRequestError.originOperationMismatch
            }
            guard MutationEffectContractCatalog.canonicalProviderDescriptor(
                for: descriptor.identity
            ) == descriptor else {
                throw RiskPolicyRequestError.untrustedDescriptor(
                    descriptor.identity
                )
            }
        case .nonProvider:
            guard !origin.isProviderAgent else {
                throw RiskPolicyRequestError.originOperationMismatch
            }
            guard MutationEffectContractCatalog
                .canonicalNonProviderDescriptor(for: descriptor.identity)
                == descriptor else {
                throw RiskPolicyRequestError.untrustedDescriptor(
                    descriptor.identity
                )
            }
        }
        guard descriptor.identity == invocation.tool,
              descriptor.effectClass == invocation.effectClass
        else {
            throw RiskPolicyRequestError.descriptorInvocationMismatch
        }
        guard descriptor.availability.allowedLocalities.contains(.either)
                || descriptor.availability.allowedLocalities.contains(
                    invocation.locality
                )
        else {
            throw RiskPolicyRequestError.descriptorLocalityMismatch
        }
        do {
            try ToolArgumentValidator.validate(
                invocation.arguments,
                against: descriptor.argumentSchema
            )
        } catch {
            throw RiskPolicyRequestError.invalidArguments
        }
        guard invocation.idempotencyKey
            == invocation.idempotencyKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !invocation.idempotencyKey.isEmpty,
            invocation.idempotencyKey.utf8.count <= 512,
            invocation.idempotencyKey.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
                    && $0.properties.generalCategory != .format
            })
        else {
            throw RiskPolicyRequestError.invalidIdempotencyKey
        }
        let canonicalDigest = try descriptor.canonicalArgumentDigest(
            for: invocation.arguments
        )
        guard canonicalDigest == invocation.canonicalArgumentDigest else {
            throw RiskPolicyRequestError.argumentDigestMismatch
        }
        guard try AgentToolJSON.data(for: invocation.arguments).count
                <= descriptor.limits.maximumArgumentBytes
        else { throw RiskPolicyRequestError.argumentTooLarge }
        let argumentSHA256 = try SHA256Digest(canonicalDigest)
        let operationPreviewSHA256: SHA256Digest?
        switch invocation.effectClass {
        case .readOnlyLocal, .credentialBearingOrPrivileged,
             .unrecoverableDenied:
            operationPreviewSHA256 = nil
        case .scopedReversibleWrite, .broadOrDestructiveWrite,
             .externalSideEffect:
            do {
                operationPreviewSHA256 = try MutationEffectApprovalPreview
                    .derive(
                        origin: origin,
                        descriptor: descriptor,
                        invocation: invocation
                    ).previewSHA256
            } catch {
                throw RiskPolicyRequestError.operationPreviewUnavailable
            }
        }
        let normalizedSession = try sessionID.map { value in
            guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  value.utf8.count <= 512,
                  value.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                          && $0.properties.generalCategory != .format
                  })
            else { throw RiskPolicyRequestError.invalidSessionID }
            return value
        }
        let targetAttestation = try await resolver.resolve(
            descriptor: descriptor,
            invocation: invocation,
            workspaceID: workspaceID
        )
        let capabilities = Array(Set(
            descriptor.availability.requiredCapabilities
        )).sorted { $0.rawValue < $1.rawValue }
        let requestSHA256 = try PolicyCanonicalDigest.sha256(
            domain: .request,
            DigestMaterial(
                origin: origin,
                runID: runID,
                projectID: projectID,
                workspaceID: workspaceID,
                sessionID: normalizedSession,
                backend: backend,
                callID: invocation.callID,
                modelAttemptID: invocation.modelAttemptID,
                tool: invocation.tool,
                argumentSHA256: argumentSHA256,
                operationPreviewSHA256: operationPreviewSHA256,
                idempotencyKey: invocation.idempotencyKey,
                effectClass: invocation.effectClass,
                locality: invocation.locality,
                logicalTargets: targetAttestation.logicalTargets,
                resolvedTargets: targetAttestation.resolvedTargets,
                targetAttestationSHA256: targetAttestation.attestationSHA256,
                capabilities: capabilities
            )
        )
        return Self(
            origin: origin,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: normalizedSession,
            backend: backend,
            descriptor: descriptor,
            invocation: invocation,
            logicalTargets: targetAttestation.logicalTargets,
            resolvedTargets: targetAttestation.resolvedTargets,
            capabilities: capabilities,
            argumentSHA256: argumentSHA256,
            operationPreviewSHA256: operationPreviewSHA256,
            requestSHA256: requestSHA256,
            targetAttestationSHA256: targetAttestation.attestationSHA256,
            targetAttestation: targetAttestation
        )
    }

    public static func resolveEditor(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: EditorCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveCanonicalProviderBound(
            origin: .editor,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.canonicalProviderOperation,
            using: resolver
        )
    }

    public static func resolveFiles(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: FilesCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveCanonicalProviderBound(
            origin: .files,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.canonicalProviderOperation,
            using: resolver
        )
    }

    public static func resolveTerminal(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: TerminalCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveCanonicalProviderBound(
            origin: .terminal,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.canonicalProviderOperation,
            using: resolver
        )
    }

    public static func resolveArtifact(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: ArtifactCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveCanonicalProviderBound(
            origin: .artifact,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.canonicalProviderOperation,
            using: resolver
        )
    }

    public static func resolveProjectOS(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: ProjectOSCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveCanonicalProviderBound(
            origin: .projectOS,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.canonicalProviderOperation,
            using: resolver
        )
    }

    public static func resolveTrustedSystem(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: TrustedSystemCanonicalMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveCanonicalProviderBound(
            origin: .trustedSystem,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.canonicalProviderOperation,
            using: resolver
        )
    }

    private static func resolveCanonicalProviderBound(
        origin: MutationOrigin,
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: CanonicalProviderMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        guard !origin.isProviderAgent else {
            throw RiskPolicyRequestError.originOperationMismatch
        }
        guard MutationOriginOperationPolicy.allows(
            origin: origin,
            operation: operation
        ) else {
            throw RiskPolicyRequestError.originOperationMismatch
        }
        let descriptor = MutationEffectContractCatalog.canonicalDescriptor(
            for: operation
        )
        let arguments = MutationEffectContractCatalog.arguments(for: operation)
        let canonicalArgumentDigest: String
        do {
            canonicalArgumentDigest = try descriptor.canonicalArgumentDigest(
                for: arguments
            )
        } catch {
            throw RiskPolicyRequestError.invalidArguments
        }
        let invocation = ToolInvocation(
            callID: callID,
            modelAttemptID: operationAttemptID,
            tool: descriptor.identity,
            arguments: arguments,
            canonicalArgumentDigest: canonicalArgumentDigest,
            idempotencyKey: idempotencyKey,
            effectClass: descriptor.effectClass,
            locality: .onDevice
        )
        return try await resolveBound(
            origin: origin,
            contractFamily: .provider,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            descriptor: descriptor,
            invocation: invocation,
            using: resolver
        )
    }

    public static func resolveEditor(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: EditorPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveNonProviderBound(
            origin: .editor,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.nonProviderOperation,
            using: resolver
        )
    }

    public static func resolveFiles(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: FilesPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveNonProviderBound(
            origin: .files,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.nonProviderOperation,
            using: resolver
        )
    }

    public static func resolveControl(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: ControlPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveNonProviderBound(
            origin: .control,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.nonProviderOperation,
            using: resolver
        )
    }

    public static func resolveProjectOS(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: ProjectOSPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveNonProviderBound(
            origin: .projectOS,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.nonProviderOperation,
            using: resolver
        )
    }

    public static func resolveTrustedSystem(
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: TrustedSystemPolicyMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        try await resolveNonProviderBound(
            origin: .trustedSystem,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            callID: callID,
            operationAttemptID: operationAttemptID,
            idempotencyKey: idempotencyKey,
            operation: operation.nonProviderOperation,
            using: resolver
        )
    }

    private static func resolveNonProviderBound(
        origin: MutationOrigin,
        runID: RunID,
        projectID: ProjectID?,
        workspaceID: WorkspaceID,
        sessionID: String?,
        backend: PolicyBackend,
        callID: ToolCallID,
        operationAttemptID: AttemptID,
        idempotencyKey: String,
        operation: NonProviderMutationOperation,
        using resolver: WorkspaceTargetResolverAuthority
    ) async throws -> Self {
        guard !origin.isProviderAgent else {
            throw RiskPolicyRequestError.originOperationMismatch
        }
        guard MutationOriginOperationPolicy.allows(
            origin: origin,
            operation: operation
        ) else {
            throw RiskPolicyRequestError.originOperationMismatch
        }
        let descriptor = MutationEffectContractCatalog.canonicalDescriptor(
            for: operation
        )
        let arguments = MutationEffectContractCatalog.arguments(for: operation)
        let canonicalArgumentDigest: String
        do {
            canonicalArgumentDigest = try descriptor.canonicalArgumentDigest(
                for: arguments
            )
        } catch {
            throw RiskPolicyRequestError.invalidArguments
        }
        let invocation = ToolInvocation(
            callID: callID,
            modelAttemptID: operationAttemptID,
            tool: descriptor.identity,
            arguments: arguments,
            canonicalArgumentDigest: canonicalArgumentDigest,
            idempotencyKey: idempotencyKey,
            effectClass: descriptor.effectClass,
            locality: .onDevice
        )
        return try await resolveBound(
            origin: origin,
            contractFamily: .nonProvider,
            runID: runID,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            backend: backend,
            descriptor: descriptor,
            invocation: invocation,
            using: resolver
        )
    }
}

public enum RiskPolicyRequestError: Error, Equatable, Sendable {
    case untrustedDescriptor(ToolIdentity)
    case descriptorInvocationMismatch
    case descriptorLocalityMismatch
    case invalidArguments
    case argumentDigestMismatch
    case argumentTooLarge
    case operationPreviewUnavailable
    case invalidIdempotencyKey
    case invalidSessionID
    case originOperationMismatch
}

public enum PolicyReason: Codable, Equatable, Sendable {
    case hardDeniedEffect(ToolEffectClass)
    case hardDeniedApprovalClass
    case hardDeniedParallelSafety
    case backendDenied(PolicyBackend)
    case localityMismatch
    case toolDenied(ToolIdentity)
    case capabilityDenied(ToolCapability)
    case effectDenied(ToolEffectClass)
    case projectOutOfScope
    case workspaceOutOfScope
    case targetOutOfScope(String)
    case targetExplicitlyDenied(String)
    case explicitApprovalRequired
    case mutatingEffectRequiresApproval(ToolEffectClass)
    case advisory(String)
}

public enum PolicyAuthorizationSource: Codable, Equatable, Sendable {
    case baseline
    case grant(grantID: String, scope: PolicyGrantScope)
}

public struct PolicyAuthorization: Codable, Equatable, Sendable {
    public let source: PolicyAuthorizationSource
    public init(source: PolicyAuthorizationSource) { self.source = source }
}

public enum PolicyIndeterminateReason: Codable, Equatable, Sendable {
    case trustedClockUnavailable
    case policyRevisionChanged
    case targetRevalidationFailed
    case advisoryTimeout
    case advisoryFailure
    case advisoryCancelled
    case advisoryIndeterminate(String)
    case grantStoreUnavailable(String)
    case grantRedemptionConflict(String)
}

public enum RiskPolicyDecision: Codable, Equatable, Sendable {
    case allow(PolicyAuthorization)
    case requiresApproval([PolicyReason])
    case deny([PolicyReason])
    case indeterminate(PolicyIndeterminateReason)

    public var authorizesExecution: Bool {
        if case .allow = self { return true }
        return false
    }

    public var isFailClosed: Bool { !authorizesExecution }
}

public struct PolicyAdvisoryInput: Codable, Equatable, Sendable {
    public let origin: MutationOrigin
    public let runID: RunID
    public let projectID: ProjectID?
    public let workspaceID: WorkspaceID
    public let backend: PolicyBackend
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let resolvedTargets: [NormalizedToolTarget]
    public let policySHA256: SHA256Digest
    public let requestSHA256: SHA256Digest
}

public enum PolicyAdvisoryDecision: Codable, Equatable, Sendable {
    case noAdditionalRestriction
    case requireApproval(String)
    case deny(String)
    case indeterminate(String)
}

public enum PolicyAdvisoryTransportResult: Sendable {
    case decision(PolicyAdvisoryDecision)
    case failure
}

public protocol PolicyAdvisoryOperation: Sendable {
    /// May be hostile and block forever. The evaluator always invokes it on a
    /// detached thread and never waits for it. If this method returns, the
    /// transport guarantees that its completion closure can never run again.
    func cancelAndDrain()
}

public protocol RiskPolicyAdvisoryTransport: Sendable {
    /// May be hostile and block forever. The evaluator never calls this on its
    /// cooperative task or actor executor.
    func start(
        _ input: PolicyAdvisoryInput,
        completion: @escaping @Sendable (PolicyAdvisoryTransportResult) -> Void
    ) throws -> any PolicyAdvisoryOperation
}

public enum PolicyAdvisoryIsolationLimits {
    /// One reservation covers the entire hostile `start` -> `cancelAndDrain`
    /// lifecycle. A transport can therefore strand at most this many foreign
    /// calls process-wide; further evaluations fail closed without creating a
    /// thread, task, operation, or retained callback.
    public static let maximumOutstandingForeignOperations = 4
}

public struct PolicyGrantRedemptionRecord: Codable, Equatable, Sendable {
    public let grantID: String
    public let nonce: String
    public let requestSHA256: SHA256Digest
    public let policySHA256: SHA256Digest
    public let redeemedAt: AgentInstant
    public let redemptionSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let grantID: String
        let nonce: String
        let requestSHA256: SHA256Digest
        let policySHA256: SHA256Digest
        let redeemedAt: AgentInstant
    }

    static func make(
        grantID: String,
        nonce: String,
        requestSHA256: SHA256Digest,
        policySHA256: SHA256Digest,
        redeemedAt: AgentInstant
    ) throws -> Self {
        let material = DigestMaterial(
            grantID: grantID,
            nonce: nonce,
            requestSHA256: requestSHA256,
            policySHA256: policySHA256,
            redeemedAt: redeemedAt
        )
        return Self(
            grantID: grantID,
            nonce: nonce,
            requestSHA256: requestSHA256,
            policySHA256: policySHA256,
            redeemedAt: redeemedAt,
            redemptionSHA256: try PolicyCanonicalDigest.sha256(
                domain: .grantRedemption,
                material
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rebuilt = try Self.make(
            grantID: container.decode(String.self, forKey: .grantID),
            nonce: container.decode(String.self, forKey: .nonce),
            requestSHA256: container.decode(
                SHA256Digest.self,
                forKey: .requestSHA256
            ),
            policySHA256: container.decode(
                SHA256Digest.self,
                forKey: .policySHA256
            ),
            redeemedAt: container.decode(AgentInstant.self, forKey: .redeemedAt)
        )
        guard rebuilt.redemptionSHA256 == (try container.decode(
            SHA256Digest.self,
            forKey: .redemptionSHA256
        )) else {
            throw PolicyGrantStoreError.corruptEvidence
        }
        self = rebuilt
    }

    private init(
        grantID: String,
        nonce: String,
        requestSHA256: SHA256Digest,
        policySHA256: SHA256Digest,
        redeemedAt: AgentInstant,
        redemptionSHA256: SHA256Digest
    ) {
        self.grantID = grantID
        self.nonce = nonce
        self.requestSHA256 = requestSHA256
        self.policySHA256 = policySHA256
        self.redeemedAt = redeemedAt
        self.redemptionSHA256 = redemptionSHA256
    }

    func isCanonical() -> Bool {
        (try? Self.make(
            grantID: grantID,
            nonce: nonce,
            requestSHA256: requestSHA256,
            policySHA256: policySHA256,
            redeemedAt: redeemedAt
        )) == self
    }

    private enum CodingKeys: String, CodingKey {
        case grantID
        case nonce
        case requestSHA256
        case policySHA256
        case redeemedAt
        case redemptionSHA256
    }
}

public struct PolicyGrantLedgerSnapshot: Codable, Equatable, Sendable {
    public let redemptions: [PolicyGrantRedemptionRecord]
    public init(redemptions: [PolicyGrantRedemptionRecord]) {
        self.redemptions = redemptions
    }
}

public enum PolicyGrantCommitDisposition: Equatable, Sendable {
    case committed
    case alreadyPresent(PolicyGrantRedemptionRecord)
}

public enum PolicyGrantStoreError: Error, Equatable, Sendable {
    case corruptEvidence
    case duplicateRedemption(grantID: String, nonce: String)
}

/// Implementations must commit compare-and-insert transactionally to durable
/// storage before returning `.committed`. Returning success before fsync/save
/// is a contract violation and must never be used by the app composition root.
public protocol DurablePolicyGrantRedemptionStore: Sendable {
    func commitIfAbsent(
        _ record: PolicyGrantRedemptionRecord
    ) async throws -> PolicyGrantCommitDisposition
    func redemption(
        grantID: String,
        nonce: String
    ) async throws -> PolicyGrantRedemptionRecord?
}

/// Deterministic test/development store. Production integration supplies a
/// SwiftData-backed `DurablePolicyGrantRedemptionStore`.
public actor InMemoryPolicyGrantRedemptionStore:
    DurablePolicyGrantRedemptionStore
{
    private struct Key: Hashable {
        let grantID: String
        let nonce: String
    }

    private var records: [Key: PolicyGrantRedemptionRecord]

    public init() { records = [:] }

    public init(restoring snapshot: PolicyGrantLedgerSnapshot) throws {
        var restored: [Key: PolicyGrantRedemptionRecord] = [:]
        for record in snapshot.redemptions {
            let key = Key(grantID: record.grantID, nonce: record.nonce)
            guard record.isCanonical(), restored[key] == nil else {
                throw PolicyGrantStoreError.duplicateRedemption(
                    grantID: record.grantID,
                    nonce: record.nonce
                )
            }
            restored[key] = record
        }
        records = restored
    }

    public func commitIfAbsent(
        _ record: PolicyGrantRedemptionRecord
    ) throws -> PolicyGrantCommitDisposition {
        guard record.isCanonical() else {
            throw PolicyGrantStoreError.corruptEvidence
        }
        let key = Key(grantID: record.grantID, nonce: record.nonce)
        if let existing = records[key] {
            return .alreadyPresent(existing)
        }
        records[key] = record
        return .committed
    }

    public func redemption(
        grantID: String,
        nonce: String
    ) -> PolicyGrantRedemptionRecord? {
        records[Key(grantID: grantID, nonce: nonce)]
    }

    public func snapshot() -> PolicyGrantLedgerSnapshot {
        PolicyGrantLedgerSnapshot(redemptions: records.values.sorted {
            ($0.grantID, $0.nonce) < ($1.grantID, $1.nonce)
        })
    }
}

/// Opaque, non-Codable authority for exactly one real tool invocation. It is
/// intentionally unrelated to AgentProviders' hosted zero-tool capability;
/// a text-only provider token cannot be converted into this type.
public struct PolicyExecutionPermit: Sendable {
    public let origin: MutationOrigin
    public let requestSHA256: SHA256Digest
    public let policySHA256: SHA256Digest
    public let callID: ToolCallID
    public let idempotencyKey: String
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let canonicalArgumentDigest: String
    public let operationPayloadSHA256: SHA256Digest
    public let operationPreviewSHA256: SHA256Digest?
    public let source: PolicyAuthorizationSource
    public let oneTimeRedemption: PolicyGrantRedemptionRecord?
    let descriptor: ToolDescriptor
    let invocation: ToolInvocation
    let targetAttestation: ResolvedInvocationTargets
    let grantExpiresAt: AgentInstant?
    let finalizationGate: SingleUsePolicyAuthorityGate
    let policyRevision: TrustedPolicyRevision

    init(
        origin: MutationOrigin,
        requestSHA256: SHA256Digest,
        policySHA256: SHA256Digest,
        callID: ToolCallID,
        idempotencyKey: String,
        tool: ToolIdentity,
        effectClass: ToolEffectClass,
        canonicalArgumentDigest: String,
        operationPayloadSHA256: SHA256Digest,
        operationPreviewSHA256: SHA256Digest?,
        source: PolicyAuthorizationSource,
        oneTimeRedemption: PolicyGrantRedemptionRecord?,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        targetAttestation: ResolvedInvocationTargets,
        grantExpiresAt: AgentInstant?,
        policyRevision: TrustedPolicyRevision
    ) {
        self.origin = origin
        self.requestSHA256 = requestSHA256
        self.policySHA256 = policySHA256
        self.callID = callID
        self.idempotencyKey = idempotencyKey
        self.tool = tool
        self.effectClass = effectClass
        self.canonicalArgumentDigest = canonicalArgumentDigest
        self.operationPayloadSHA256 = operationPayloadSHA256
        self.operationPreviewSHA256 = operationPreviewSHA256
        self.source = source
        self.oneTimeRedemption = oneTimeRedemption
        self.descriptor = descriptor
        self.invocation = invocation
        self.targetAttestation = targetAttestation
        self.grantExpiresAt = grantExpiresAt
        self.policyRevision = policyRevision
        finalizationGate = SingleUsePolicyAuthorityGate()
    }
}

public struct RiskPolicyEvaluation: Sendable {
    public let decision: RiskPolicyDecision
    public let policySHA256: SHA256Digest
    public let requestSHA256: SHA256Digest
    public let executionPermit: PolicyExecutionPermit?
    let policyRevision: TrustedPolicyRevision

    init(
        decision: RiskPolicyDecision,
        policySHA256: SHA256Digest,
        requestSHA256: SHA256Digest,
        executionPermit: PolicyExecutionPermit?,
        policyRevision: TrustedPolicyRevision
    ) {
        self.decision = decision
        self.policySHA256 = policySHA256
        self.requestSHA256 = requestSHA256
        self.executionPermit = executionPermit
        self.policyRevision = policyRevision
    }
}

public struct LayeredRiskPolicyEvaluator: Sendable {
    private let configuration: RiskPolicyConfiguration
    private let policySHA256: SHA256Digest
    private let policyRevision: TrustedPolicyRevision
    let policyRevisionAuthority: PolicyRevisionAuthority
    private let clock: any PolicyClock
    private let resolver: WorkspaceTargetResolverAuthority
    private let grantStore: (any DurablePolicyGrantRedemptionStore)?
    private let advisory: (any RiskPolicyAdvisoryTransport)?

    public init(
        policyRevisionAuthority: PolicyRevisionAuthority,
        clock: any PolicyClock,
        resolver: WorkspaceTargetResolverAuthority,
        grantStore: (any DurablePolicyGrantRedemptionStore)? = nil,
        advisory: (any RiskPolicyAdvisoryTransport)? = nil
    ) throws {
        let composition = policyRevisionAuthority.composition()
        configuration = composition.configuration
        policySHA256 = composition.revision.policySHA256
        policyRevision = composition.revision
        self.policyRevisionAuthority = policyRevisionAuthority
        self.clock = clock
        self.resolver = resolver
        self.grantStore = grantStore
        self.advisory = advisory
    }

    public func evaluate(
        _ request: RiskPolicyRequest
    ) async -> RiskPolicyEvaluation {
        guard policyIsCurrent else {
            return evaluation(
                decision: .indeterminate(.policyRevisionChanged),
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }
        let initialNow: AgentInstant
        do {
            initialNow = try await clock.currentInstant()
        } catch {
            return evaluation(
                decision: .indeterminate(.trustedClockUnavailable),
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }

        let candidate = baseCandidate(for: request, now: initialNow)
        if case .deny = candidate.decision {
            return evaluation(
                decision: candidate.decision,
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }

        let tightened: RiskPolicyDecision
        if let advisory {
            let input = PolicyAdvisoryInput(
                origin: request.origin,
                runID: request.runID,
                projectID: request.projectID,
                workspaceID: request.workspaceID,
                backend: request.backend,
                tool: request.invocation.tool,
                effectClass: request.invocation.effectClass,
                resolvedTargets: request.resolvedTargets,
                policySHA256: policySHA256,
                requestSHA256: request.requestSHA256
            )
            tightened = applying(
                await timedAdvisory(advisory, input: input),
                to: candidate.decision
            )
        } else {
            tightened = candidate.decision
        }

        guard case let .allow(authorization) = tightened else {
            return evaluation(
                decision: tightened,
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }

        let authorizationNow: AgentInstant
        do {
            authorizationNow = try await clock.currentInstant()
        } catch {
            return evaluation(
                decision: .indeterminate(.trustedClockUnavailable),
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }
        if let grant = candidate.grant,
           !Self.grantMatches(grant, request: request, now: authorizationNow) {
            return evaluation(
                decision: .indeterminate(
                    .grantRedemptionConflict(grant.grantID)
                ),
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }

        let workspaceLease: WorkspaceExecutionLease
        do {
            workspaceLease = try await resolver.revalidate(
                request.targetAttestation
            )
        } catch {
            return evaluation(
                decision: .indeterminate(.targetRevalidationFailed),
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }

        guard policyIsCurrent else {
            return evaluation(
                decision: .indeterminate(.policyRevisionChanged),
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }

        let permitNow: AgentInstant
        do {
            // This read occurs after re-resolution and immediately before any
            // durable redemption / executable permit is minted.
            permitNow = try await clock.currentInstant()
        } catch {
            return evaluation(
                decision: .indeterminate(.trustedClockUnavailable),
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }
        if let grant = candidate.grant,
           !Self.grantMatches(grant, request: request, now: permitNow) {
            return evaluation(
                decision: .indeterminate(
                    .grantRedemptionConflict(grant.grantID)
                ),
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }

        if let grant = candidate.grant,
           case let .oneTime(nonce) = grant.scope {
            guard let grantStore else {
                return evaluation(
                    decision: .indeterminate(
                        .grantStoreUnavailable(grant.grantID)
                    ),
                    request: request,
                    workspaceLease: nil,
                    redemption: nil
                )
            }
            do {
                let record = try PolicyGrantRedemptionRecord.make(
                    grantID: grant.grantID,
                    nonce: nonce,
                    requestSHA256: request.requestSHA256,
                    policySHA256: policySHA256,
                    redeemedAt: permitNow
                )
                switch try await grantStore.commitIfAbsent(record) {
                case .committed:
                    guard policyIsCurrent else {
                        return evaluation(
                            decision: .indeterminate(.policyRevisionChanged),
                            request: request,
                            workspaceLease: nil,
                            redemption: nil
                        )
                    }
                    return evaluation(
                        decision: tightened,
                        request: request,
                        workspaceLease: workspaceLease,
                        redemption: record,
                        grantExpiresAt: grant.expiresAt
                    )
                case .alreadyPresent:
                    return evaluation(
                        decision: .indeterminate(
                            .grantRedemptionConflict(grant.grantID)
                        ),
                        request: request,
                        workspaceLease: nil,
                        redemption: nil
                    )
                }
            } catch {
                return evaluation(
                    decision: .indeterminate(
                        .grantStoreUnavailable(grant.grantID)
                    ),
                    request: request,
                    workspaceLease: nil,
                    redemption: nil
                )
            }
        }

        guard policyIsCurrent else {
            return evaluation(
                decision: .indeterminate(.policyRevisionChanged),
                request: request,
                workspaceLease: nil,
                redemption: nil
            )
        }

        return RiskPolicyEvaluation(
            decision: tightened,
            policySHA256: policySHA256,
            requestSHA256: request.requestSHA256,
            executionPermit: PolicyExecutionPermit(
                origin: request.origin,
                requestSHA256: request.requestSHA256,
                policySHA256: policySHA256,
                callID: request.invocation.callID,
                idempotencyKey: request.invocation.idempotencyKey,
                tool: request.invocation.tool,
                effectClass: request.invocation.effectClass,
                canonicalArgumentDigest:
                    request.invocation.canonicalArgumentDigest,
                operationPayloadSHA256: request.argumentSHA256,
                operationPreviewSHA256:
                    request.operationPreviewSHA256,
                source: authorization.source,
                oneTimeRedemption: nil,
                descriptor: request.descriptor,
                invocation: request.invocation,
                targetAttestation: request.targetAttestation,
                grantExpiresAt: candidate.grant?.expiresAt,
                policyRevision: policyRevision
            ),
            policyRevision: policyRevision
        )
    }

    /// Performs the second/final resolution pass. Tool executors must require
    /// the returned `ToolEffectPermit`; `PolicyExecutionPermit` is not an
    /// execution capability and deliberately exposes no workspace lease.
    public func finalizeForExecution(
        _ permit: PolicyExecutionPermit
    ) async throws -> ToolEffectPermit {
        guard await permit.finalizationGate.claim() else {
            throw PolicyEffectFinalizationError.authorizationAlreadyFinalized
        }
        guard permit.policySHA256 == policySHA256,
              permit.policyRevision == policyRevision,
              policyIsCurrent
        else {
            throw PolicyEffectFinalizationError.policyChanged
        }
        if let redemption = permit.oneTimeRedemption {
            guard let grantStore,
                  let persisted = try await grantStore.redemption(
                      grantID: redemption.grantID,
                      nonce: redemption.nonce
                  ),
                  persisted == redemption
            else {
                throw PolicyEffectFinalizationError.redemptionMissing
            }
        }
        let workspaceLease: WorkspaceExecutionLease
        do {
            workspaceLease = try await resolver.revalidate(
                permit.targetAttestation
            )
        } catch {
            throw PolicyEffectFinalizationError.targetRevalidationFailed
        }
        guard policyIsCurrent else {
            throw PolicyEffectFinalizationError.policyChanged
        }
        let now: AgentInstant
        do {
            now = try await clock.currentInstant()
        } catch {
            throw PolicyEffectFinalizationError.clockUnavailable
        }
        if let expiresAt = permit.grantExpiresAt, now >= expiresAt {
            throw PolicyEffectFinalizationError.grantExpired
        }
        guard policyIsCurrent else {
            throw PolicyEffectFinalizationError.policyChanged
        }
        let fallbackExpiry = AgentInstant(
            rawValue: now.rawValue > Int64.max - 5_000
                ? Int64.max
                : now.rawValue + 5_000
        )
        return try ToolEffectPermit(
            origin: permit.origin,
            requestSHA256: permit.requestSHA256,
            policyRevision: permit.policyRevision,
            tool: permit.tool,
            effectClass: permit.effectClass,
            canonicalArgumentDigest: permit.canonicalArgumentDigest,
            operationPayloadSHA256: permit.operationPayloadSHA256,
            operationPreviewSHA256: permit.operationPreviewSHA256,
            callID: permit.callID,
            idempotencyKey: permit.idempotencyKey,
            authorizedAt: now,
            expiresAt: permit.grantExpiresAt ?? fallbackExpiry,
            source: .policy(permit.source),
            descriptor: permit.descriptor,
            invocation: permit.invocation,
            workspaceLease: workspaceLease,
            targetAttestation: permit.targetAttestation
        )
    }

    private func evaluation(
        decision: RiskPolicyDecision,
        request: RiskPolicyRequest,
        workspaceLease: WorkspaceExecutionLease?,
        redemption: PolicyGrantRedemptionRecord?,
        grantExpiresAt: AgentInstant? = nil
    ) -> RiskPolicyEvaluation {
        let permit: PolicyExecutionPermit?
        if case let .allow(authorization) = decision,
           workspaceLease != nil {
            permit = PolicyExecutionPermit(
                origin: request.origin,
                requestSHA256: request.requestSHA256,
                policySHA256: policySHA256,
                callID: request.invocation.callID,
                idempotencyKey: request.invocation.idempotencyKey,
                tool: request.invocation.tool,
                effectClass: request.invocation.effectClass,
                canonicalArgumentDigest:
                    request.invocation.canonicalArgumentDigest,
                operationPayloadSHA256: request.argumentSHA256,
                operationPreviewSHA256:
                    request.operationPreviewSHA256,
                source: authorization.source,
                oneTimeRedemption: redemption,
                descriptor: request.descriptor,
                invocation: request.invocation,
                targetAttestation: request.targetAttestation,
                grantExpiresAt: grantExpiresAt,
                policyRevision: policyRevision
            )
        } else {
            permit = nil
        }
        return RiskPolicyEvaluation(
            decision: decision,
            policySHA256: policySHA256,
            requestSHA256: request.requestSHA256,
            executionPermit: permit,
            policyRevision: policyRevision
        )
    }

    private var policyIsCurrent: Bool {
        policyRevisionAuthority.currentRevision() == policyRevision
    }

    private func baseCandidate(
        for request: RiskPolicyRequest,
        now: AgentInstant
    ) -> BaseCandidate {
        if request.invocation.effectClass == .credentialBearingOrPrivileged
            || request.invocation.effectClass == .unrecoverableDenied {
            return BaseCandidate(decision: .deny([
                .hardDeniedEffect(request.invocation.effectClass),
            ]))
        }
        if request.descriptor.approvalClass == .alwaysDenied {
            return BaseCandidate(decision: .deny([.hardDeniedApprovalClass]))
        }
        if request.descriptor.parallelSafety == .denied {
            return BaseCandidate(decision: .deny([.hardDeniedParallelSafety]))
        }
        if !localityMatches(request) {
            return BaseCandidate(decision: .deny([.localityMismatch]))
        }
        let administrativeReasons = restrictionReasons(
            configuration.administrative,
            request: request
        )
        if !administrativeReasons.isEmpty {
            return BaseCandidate(decision: .deny(administrativeReasons))
        }
        let userReasons = restrictionReasons(
            configuration.user.restrictions,
            request: request
        ) + scopeReasons(configuration.user, request: request)
        if !userReasons.isEmpty {
            return BaseCandidate(decision: .deny(userReasons))
        }

        // A target-prefix grant does not bind the executable/argv of a legacy
        // parsed command. Treating it as authorization would turn a
        // narrow-looking workspace prefix into a broad command capability.
        if case .legacyCommandParserRequired = request.descriptor.targetStrategy {
            return BaseCandidate(decision: .requiresApproval([
                .explicitApprovalRequired,
            ]))
        }

        if let grant = configuration.grants.first(where: {
            Self.grantMatches($0, request: request, now: now)
        }) {
            return BaseCandidate(
                decision: .allow(PolicyAuthorization(source: .grant(
                    grantID: grant.grantID,
                    scope: grant.scope
                ))),
                grant: grant
            )
        }
        if request.descriptor.approvalClass == .explicit {
            return BaseCandidate(decision: .requiresApproval([
                .explicitApprovalRequired,
            ]))
        }
        if request.invocation.effectClass != .readOnlyLocal {
            return BaseCandidate(decision: .requiresApproval([
                .mutatingEffectRequiresApproval(request.invocation.effectClass),
            ]))
        }
        return BaseCandidate(decision: .allow(
            PolicyAuthorization(source: .baseline)
        ))
    }

    static func grantMatches(
        _ grant: PolicyGrant,
        request: RiskPolicyRequest,
        now: AgentInstant
    ) -> Bool {
        guard grant.tool == request.invocation.tool,
              now < grant.expiresAt,
              request.resolvedTargets.allSatisfy({ target in
                  grant.targetPrefixes.contains(
                    where: target.isWithinAuthorizationPrefix
                  )
              })
        else { return false }
        switch grant.scope {
        case .oneTime:
            return true
        case let .session(sessionID):
            return request.sessionID == sessionID
        case let .project(projectID):
            return request.projectID == projectID
        }
    }

    private func restrictionReasons(
        _ restrictions: PolicyRestrictionSet,
        request: RiskPolicyRequest
    ) -> [PolicyReason] {
        var reasons: [PolicyReason] = []
        if restrictions.deniedBackends.contains(request.backend) {
            reasons.append(.backendDenied(request.backend))
        }
        if restrictions.deniedTools.contains(request.invocation.tool) {
            reasons.append(.toolDenied(request.invocation.tool))
        }
        reasons.append(contentsOf: request.capabilities.compactMap {
            restrictions.deniedCapabilities.contains($0)
                ? .capabilityDenied($0)
                : nil
        })
        if restrictions.deniedEffectClasses.contains(
            request.invocation.effectClass
        ) {
            reasons.append(.effectDenied(request.invocation.effectClass))
        }
        return reasons
    }

    private func scopeReasons(
        _ user: UserPolicyRestrictions,
        request: RiskPolicyRequest
    ) -> [PolicyReason] {
        var reasons: [PolicyReason] = []
        if !user.allowedProjectIDs.isEmpty,
           request.projectID.map({ user.allowedProjectIDs.contains($0) }) != true {
            reasons.append(.projectOutOfScope)
        }
        if !user.allowedWorkspaceIDs.isEmpty,
           !user.allowedWorkspaceIDs.contains(request.workspaceID) {
            reasons.append(.workspaceOutOfScope)
        }
        for target in request.resolvedTargets {
            if !user.allowedTargetPrefixes.isEmpty,
               !user.allowedTargetPrefixes.contains(
                where: target.isWithinAuthorizationPrefix
               ) {
                reasons.append(.targetOutOfScope(target.path))
            }
            if user.deniedTargetPrefixes.contains(
                where: target.isWithinDeniedPrefix
            ) {
                reasons.append(.targetExplicitlyDenied(target.path))
            }
        }
        return reasons
    }

    private func localityMatches(_ request: RiskPolicyRequest) -> Bool {
        switch request.invocation.locality {
        case .either:
            true
        case .onDevice:
            request.backend == .onDevice
        case .worker:
            request.backend == .worker
        }
    }

    private func timedAdvisory(
        _ advisory: any RiskPolicyAdvisoryTransport,
        input: PolicyAdvisoryInput
    ) async -> TimedAdvisoryResult {
        let race = AdvisoryCompletionRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation: continuation)
                if Task.isCancelled {
                    race.resolve(.cancelled, drain: true)
                    return
                }
                race.startTimeout(
                    milliseconds: configuration.advisoryTimeoutMilliseconds
                )
                guard let reservation = HostileAdvisoryIsolationPool.shared
                    .reserve()
                else {
                    race.resolve(.failure, drain: true)
                    return
                }
                reservation.launchStart {
                    do {
                        let operation = try advisory.start(input) { result in
                            race.receive(result)
                        }
                        race.install(
                            operation: operation,
                            reservation: reservation
                        )
                    } catch {
                        reservation.releaseWithoutOperation()
                        race.resolve(.failure, drain: true)
                    }
                }
            }
        } onCancel: {
            race.resolve(.cancelled, drain: true)
        }
    }

    private func applying(
        _ advisory: TimedAdvisoryResult,
        to base: RiskPolicyDecision
    ) -> RiskPolicyDecision {
        switch advisory {
        case .timeout:
            return .indeterminate(.advisoryTimeout)
        case .failure:
            return .indeterminate(.advisoryFailure)
        case .cancelled:
            return .indeterminate(.advisoryCancelled)
        case let .decision(.indeterminate(reason)):
            return .indeterminate(.advisoryIndeterminate(reason))
        case .decision(.noAdditionalRestriction):
            return base
        case let .decision(.requireApproval(reason)):
            switch base {
            case .allow:
                return .requiresApproval([.advisory(reason)])
            case let .requiresApproval(reasons):
                return .requiresApproval(reasons + [.advisory(reason)])
            case .deny, .indeterminate:
                return base
            }
        case let .decision(.deny(reason)):
            switch base {
            case let .requiresApproval(reasons), let .deny(reasons):
                return .deny(reasons + [.advisory(reason)])
            case .allow:
                return .deny([.advisory(reason)])
            case .indeterminate:
                return base
            }
        }
    }
}

public enum PolicyEffectFinalizationError: Error, Equatable, Sendable {
    case authorizationAlreadyFinalized
    case policyChanged
    case redemptionMissing
    case targetRevalidationFailed
    case clockUnavailable
    case grantExpired
}

private struct BaseCandidate: Sendable {
    let decision: RiskPolicyDecision
    let grant: PolicyGrant?

    init(decision: RiskPolicyDecision, grant: PolicyGrant? = nil) {
        self.decision = decision
        self.grant = grant
    }
}

private enum TimedAdvisoryResult: Sendable {
    case decision(PolicyAdvisoryDecision)
    case timeout
    case failure
    case cancelled
}

private final class AdvisoryCompletionRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TimedAdvisoryResult, Never>?
    private var operation: (any PolicyAdvisoryOperation)?
    private var reservation: HostileAdvisoryReservation?
    private var result: TimedAdvisoryResult?
    private var pendingTransportResult: TimedAdvisoryResult?
    private var drainStarted = false

    func install(
        continuation: CheckedContinuation<TimedAdvisoryResult, Never>
    ) {
        let resolved: TimedAdvisoryResult?
        lock.lock()
        precondition(self.continuation == nil)
        resolved = result
        if resolved == nil { self.continuation = continuation }
        lock.unlock()
        if let resolved { continuation.resume(returning: resolved) }
    }

    func install(
        operation: any PolicyAdvisoryOperation,
        reservation: HostileAdvisoryReservation
    ) {
        let shouldDrain: Bool
        lock.lock()
        if result != nil {
            shouldDrain = true
        } else if let pendingTransportResult {
            // A callback is provisional until cancellation/drain proves the
            // transport cannot deliver another conflicting callback.
            _ = pendingTransportResult
            self.operation = operation
            self.reservation = reservation
            drainStarted = true
            shouldDrain = true
        } else {
            shouldDrain = false
            self.operation = operation
            self.reservation = reservation
        }
        lock.unlock()
        if shouldDrain {
            reservation.drain(operation) { [weak self] in
                self?.drainCompleted()
            }
        }
    }

    /// A transport is not considered successfully started until it returns
    /// the operation that can be cancelled and drained. Synchronous callbacks
    /// are buffered so callback-then-throw cannot win the completion race.
    func receive(_ transportResult: PolicyAdvisoryTransportResult) {
        let value: TimedAdvisoryResult
        switch transportResult {
        case let .decision(decision):
            value = .decision(decision)
        case .failure:
            value = .failure
        }

        let drain: (
            operation: any PolicyAdvisoryOperation,
            reservation: HostileAdvisoryReservation
        )?
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        guard operation != nil else {
            if pendingTransportResult == nil {
                pendingTransportResult = value
            } else {
                // The completion contract is single-shot. Multiple callbacks
                // before a successful `start` are ambiguous and fail closed.
                pendingTransportResult = .failure
            }
            lock.unlock()
            return
        }
        if pendingTransportResult == nil {
            pendingTransportResult = value
        } else {
            // Multiple callbacks before the operation becomes quiescent are
            // ambiguous regardless of whether they carry equal decisions.
            pendingTransportResult = .failure
        }
        if !drainStarted,
           let operation,
           let reservation {
            drainStarted = true
            drain = (operation, reservation)
        } else {
            drain = nil
        }
        lock.unlock()
        if let drain {
            drain.reservation.drain(drain.operation) { [weak self] in
                self?.drainCompleted()
            }
        }
    }

    func startTimeout(milliseconds: UInt64) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(Int(milliseconds))
        ) { [weak self] in
            self?.resolve(.timeout, drain: true)
        }
    }

    func resolve(_ value: TimedAdvisoryResult, drain: Bool) {
        let continuation: CheckedContinuation<TimedAdvisoryResult, Never>?
        let pendingDrain: (
            operation: any PolicyAdvisoryOperation,
            reservation: HostileAdvisoryReservation
        )?
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        continuation = self.continuation
        if drain,
           !drainStarted,
           let operation,
           let reservation {
            drainStarted = true
            pendingDrain = (operation, reservation)
        } else {
            pendingDrain = nil
        }
        self.continuation = nil
        pendingTransportResult = nil
        lock.unlock()

        if let pendingDrain {
            pendingDrain.reservation.drain(pendingDrain.operation) {}
        }
        continuation?.resume(returning: value)
    }

    private func drainCompleted() {
        let continuation: CheckedContinuation<TimedAdvisoryResult, Never>?
        let completed: TimedAdvisoryResult
        lock.lock()
        guard result == nil, drainStarted else {
            lock.unlock()
            return
        }
        // `cancelAndDrain` returning is the transport's explicit postcondition
        // that no future callback can occur. Only now is the single buffered
        // callback safe to commit.
        completed = pendingTransportResult ?? .failure
        result = completed
        continuation = self.continuation
        self.continuation = nil
        operation = nil
        reservation = nil
        pendingTransportResult = nil
        lock.unlock()
        continuation?.resume(returning: completed)
    }
}

private final class HostileAdvisoryIsolationPool: @unchecked Sendable {
    static let shared = HostileAdvisoryIsolationPool()

    private let lock = NSLock()
    private var outstanding = 0

    func reserve() -> HostileAdvisoryReservation? {
        lock.lock()
        guard outstanding
            < PolicyAdvisoryIsolationLimits.maximumOutstandingForeignOperations
        else {
            lock.unlock()
            return nil
        }
        outstanding += 1
        lock.unlock()
        return HostileAdvisoryReservation(pool: self)
    }

    fileprivate func release() {
        lock.lock()
        precondition(outstanding > 0)
        outstanding -= 1
        lock.unlock()
    }
}

/// A single global reservation owns every foreign call for one advisory.
/// Capacity is released only after `cancelAndDrain` returns (or `start`
/// throws), so a hostile implementation cannot turn repeated evaluations into
/// an unbounded collection of blocked start/drain threads.
private final class HostileAdvisoryReservation: @unchecked Sendable {
    private let pool: HostileAdvisoryIsolationPool
    private let lock = NSLock()
    private var released = false

    init(pool: HostileAdvisoryIsolationPool) { self.pool = pool }

    func launchStart(_ operation: @escaping @Sendable () -> Void) {
        Thread.detachNewThread(operation)
    }

    func drain(
        _ operation: any PolicyAdvisoryOperation,
        onDrained: @escaping @Sendable () -> Void
    ) {
        Thread.detachNewThread { [self] in
            operation.cancelAndDrain()
            releaseOnce()
            onDrained()
        }
    }

    func releaseWithoutOperation() { releaseOnce() }

    private func releaseOnce() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        pool.release()
    }
}

private struct PolicyDigestMaterial: Codable {
    let hardFloorVersion: String
    let configuration: RiskPolicyConfiguration
}
