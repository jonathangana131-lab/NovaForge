import AgentDomain
import AgentTools
import CryptoKit
import Foundation

public enum ApprovalNonceValidationError: Error, Equatable, Sendable {
    case invalid
}

public struct ApprovalNonce:
    Codable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              rawValue.utf8.count <= 512,
              rawValue.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && $0.properties.generalCategory != .format
              })
        else { throw ApprovalNonceValidationError.invalid }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Stable identity for registration retries across a crash boundary. Random
/// request IDs, nonces, and timestamps are deliberately excluded.
public struct DurableApprovalRegistrationIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let runID: RunID
    public let callID: ToolCallID
    public let idempotencyKey: String
    public let keySHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let runID: RunID
        let callID: ToolCallID
        let idempotencyKey: String
    }

    static func make(
        runID: RunID,
        callID: ToolCallID,
        idempotencyKey: String
    ) throws -> Self {
        let material = DigestMaterial(
            runID: runID,
            callID: callID,
            idempotencyKey: try validatedIdempotencyKey(idempotencyKey)
        )
        return Self(
            material: material,
            keySHA256: try PolicyCanonicalDigest.sha256(
                domain: .approvalRegistration,
                material
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rebuilt = try Self.make(
            runID: container.decode(RunID.self, forKey: .runID),
            callID: container.decode(ToolCallID.self, forKey: .callID),
            idempotencyKey: container.decode(
                String.self,
                forKey: .idempotencyKey
            )
        )
        guard rebuilt.keySHA256 == (try container.decode(
            SHA256Digest.self,
            forKey: .keySHA256
        )) else { throw DurableApprovalValidationError.invalidEvidence }
        self = rebuilt
    }

    private init(material: DigestMaterial, keySHA256: SHA256Digest) {
        runID = material.runID
        callID = material.callID
        idempotencyKey = material.idempotencyKey
        self.keySHA256 = keySHA256
    }

    func isCanonical() -> Bool {
        (try? Self.make(
            runID: runID,
            callID: callID,
            idempotencyKey: idempotencyKey
        )) == self
    }

    private static func validatedIdempotencyKey(
        _ value: String
    ) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && $0.properties.generalCategory != .format
              })
        else {
            throw DurableApprovalValidationError.invalidToken(.idempotencyKey)
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case callID
        case idempotencyKey
        case keySHA256
    }
}

public struct DurableApprovalBinding: Codable, Equatable, Sendable {
    public let origin: MutationOrigin
    public let runID: RunID
    public let callID: ToolCallID
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let canonicalArgumentDigest: String
    public let workspaceID: WorkspaceID
    public let argumentSHA256: SHA256Digest
    public let operationPreviewSHA256: SHA256Digest
    public let requestSHA256: SHA256Digest
    public let idempotencyKey: String
    public let logicalTargets: [NormalizedToolTarget]
    public let resolvedTargets: [NormalizedToolTarget]
    public let preconditions: [ApprovalPrecondition]
    public let workspaceRevision: String
    public let targetAttestationSHA256: SHA256Digest
    public let policySHA256: SHA256Digest
    public let issuedAt: AgentInstant
    public let expiresAt: AgentInstant
    public let nonce: ApprovalNonce
    public let bindingSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let origin: MutationOrigin
        let runID: RunID
        let callID: ToolCallID
        let tool: ToolIdentity
        let effectClass: ToolEffectClass
        let canonicalArgumentDigest: String
        let workspaceID: WorkspaceID
        let argumentSHA256: SHA256Digest
        let operationPreviewSHA256: SHA256Digest
        let requestSHA256: SHA256Digest
        let idempotencyKey: String
        let logicalTargets: [NormalizedToolTarget]
        let resolvedTargets: [NormalizedToolTarget]
        let preconditions: [ApprovalPrecondition]
        let workspaceRevision: String
        let targetAttestationSHA256: SHA256Digest
        let policySHA256: SHA256Digest
        let issuedAt: AgentInstant
        let expiresAt: AgentInstant
        let nonce: ApprovalNonce
    }

    static func make(
        request: RiskPolicyRequest,
        policySHA256: SHA256Digest,
        issuedAt: AgentInstant,
        expiresAt: AgentInstant,
        nonce: ApprovalNonce
    ) throws -> Self {
        guard issuedAt < expiresAt else {
            throw DurableApprovalValidationError.invalidExpiry
        }
        guard let operationPreviewSHA256 = request.operationPreviewSHA256
        else {
            throw DurableApprovalValidationError.invalidEvidence
        }
        let operationKey = try validatedToken(
            request.invocation.idempotencyKey,
            field: .idempotencyKey
        )
        let revision = try validatedToken(
            request.targetAttestation.workspaceRevision,
            field: .workspaceRevision
        )
        let logical = try NormalizedToolTarget.canonicalize(
            request.logicalTargets
        )
        let resolved = try NormalizedToolTarget.canonicalize(
            request.resolvedTargets
        )
        let conditions = try canonicalPreconditions(
            request.targetAttestation.preconditions
        )
        guard conditions.map(\.resolution.target) == logical else {
            throw DurableApprovalValidationError.preconditionTargetMismatch
        }
        guard conditions.allSatisfy({
            $0.resolution.workspaceID == request.workspaceID
        }) else {
            throw DurableApprovalValidationError.preconditionWorkspaceMismatch
        }
        let material = DigestMaterial(
            origin: request.origin,
            runID: request.runID,
            callID: request.invocation.callID,
            tool: request.invocation.tool,
            effectClass: request.invocation.effectClass,
            canonicalArgumentDigest:
                request.invocation.canonicalArgumentDigest,
            workspaceID: request.workspaceID,
            argumentSHA256: request.argumentSHA256,
            operationPreviewSHA256: operationPreviewSHA256,
            requestSHA256: request.requestSHA256,
            idempotencyKey: operationKey,
            logicalTargets: logical,
            resolvedTargets: resolved,
            preconditions: conditions,
            workspaceRevision: revision,
            targetAttestationSHA256: request.targetAttestationSHA256,
            policySHA256: policySHA256,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            nonce: nonce
        )
        return Self(
            material: material,
            bindingSHA256: try PolicyCanonicalDigest.sha256(
                domain: .approvalBinding,
                material
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let material = DigestMaterial(
            origin: try container.decode(MutationOrigin.self, forKey: .origin),
            runID: try container.decode(RunID.self, forKey: .runID),
            callID: try container.decode(ToolCallID.self, forKey: .callID),
            tool: try container.decode(ToolIdentity.self, forKey: .tool),
            effectClass: try container.decode(
                ToolEffectClass.self,
                forKey: .effectClass
            ),
            canonicalArgumentDigest: try container.decode(
                String.self,
                forKey: .canonicalArgumentDigest
            ),
            workspaceID: try container.decode(WorkspaceID.self, forKey: .workspaceID),
            argumentSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .argumentSHA256
            ),
            operationPreviewSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .operationPreviewSHA256
            ),
            requestSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .requestSHA256
            ),
            idempotencyKey: try Self.validatedToken(
                container.decode(String.self, forKey: .idempotencyKey),
                field: .idempotencyKey
            ),
            logicalTargets: try NormalizedToolTarget.canonicalize(
                container.decode(
                    [NormalizedToolTarget].self,
                    forKey: .logicalTargets
                )
            ),
            resolvedTargets: try NormalizedToolTarget.canonicalize(
                container.decode(
                    [NormalizedToolTarget].self,
                    forKey: .resolvedTargets
                )
            ),
            preconditions: try Self.canonicalPreconditions(
                container.decode(
                    [ApprovalPrecondition].self,
                    forKey: .preconditions
                )
            ),
            workspaceRevision: try Self.validatedToken(
                container.decode(String.self, forKey: .workspaceRevision),
                field: .workspaceRevision
            ),
            targetAttestationSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .targetAttestationSHA256
            ),
            policySHA256: try container.decode(
                SHA256Digest.self,
                forKey: .policySHA256
            ),
            issuedAt: try container.decode(AgentInstant.self, forKey: .issuedAt),
            expiresAt: try container.decode(AgentInstant.self, forKey: .expiresAt),
            nonce: try container.decode(ApprovalNonce.self, forKey: .nonce)
        )
        guard material.issuedAt < material.expiresAt,
              material.canonicalArgumentDigest
                == material.argumentSHA256.rawValue,
              material.preconditions.map(\.resolution.target)
                == material.logicalTargets,
              material.preconditions.allSatisfy({
                  $0.resolution.workspaceID == material.workspaceID
              })
        else {
            throw DurableApprovalValidationError.invalidEvidence
        }
        let digest = try PolicyCanonicalDigest.sha256(
            domain: .approvalBinding,
            material
        )
        guard digest == (try container.decode(
            SHA256Digest.self,
            forKey: .bindingSHA256
        )) else {
            throw DurableApprovalValidationError.bindingDigestMismatch
        }
        self.init(material: material, bindingSHA256: digest)
    }

    private init(material: DigestMaterial, bindingSHA256: SHA256Digest) {
        origin = material.origin
        runID = material.runID
        callID = material.callID
        tool = material.tool
        effectClass = material.effectClass
        canonicalArgumentDigest = material.canonicalArgumentDigest
        workspaceID = material.workspaceID
        argumentSHA256 = material.argumentSHA256
        operationPreviewSHA256 = material.operationPreviewSHA256
        requestSHA256 = material.requestSHA256
        idempotencyKey = material.idempotencyKey
        logicalTargets = material.logicalTargets
        resolvedTargets = material.resolvedTargets
        preconditions = material.preconditions
        workspaceRevision = material.workspaceRevision
        targetAttestationSHA256 = material.targetAttestationSHA256
        policySHA256 = material.policySHA256
        issuedAt = material.issuedAt
        expiresAt = material.expiresAt
        nonce = material.nonce
        self.bindingSHA256 = bindingSHA256
    }

    func isCanonical() -> Bool {
        guard issuedAt < expiresAt,
              canonicalArgumentDigest == argumentSHA256.rawValue,
              logicalTargets == (try? NormalizedToolTarget.canonicalize(
                  logicalTargets
              )),
              resolvedTargets == (try? NormalizedToolTarget.canonicalize(
                  resolvedTargets
              )),
              preconditions == (try? Self.canonicalPreconditions(preconditions)),
              preconditions.map(\.resolution.target) == logicalTargets,
              preconditions.allSatisfy({
                  $0.resolution.workspaceID == workspaceID
                      && $0.resolution.isCanonical()
              })
        else { return false }
        let material = DigestMaterial(
            origin: origin,
            runID: runID,
            callID: callID,
            tool: tool,
            effectClass: effectClass,
            canonicalArgumentDigest: canonicalArgumentDigest,
            workspaceID: workspaceID,
            argumentSHA256: argumentSHA256,
            operationPreviewSHA256: operationPreviewSHA256,
            requestSHA256: requestSHA256,
            idempotencyKey: idempotencyKey,
            logicalTargets: logicalTargets,
            resolvedTargets: resolvedTargets,
            preconditions: preconditions,
            workspaceRevision: workspaceRevision,
            targetAttestationSHA256: targetAttestationSHA256,
            policySHA256: policySHA256,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            nonce: nonce
        )
        return (try? PolicyCanonicalDigest.sha256(
            domain: .approvalBinding,
            material
        )) == bindingSHA256
    }

    private static func canonicalPreconditions(
        _ preconditions: [ApprovalPrecondition]
    ) throws -> [ApprovalPrecondition] {
        let ordered = preconditions.sorted {
            NormalizedToolTarget.canonicalOrder(
                $0.resolution.target,
                $1.resolution.target
            )
        }
        for pair in zip(ordered, ordered.dropFirst())
        where pair.0.resolution.target == pair.1.resolution.target {
            throw DurableApprovalValidationError.duplicatePrecondition(
                pair.0.resolution.target
            )
        }
        return ordered
    }

    private static func validatedToken(
        _ value: String,
        field: DurableApprovalTokenField
    ) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 1_024,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && $0.properties.generalCategory != .format
              })
        else { throw DurableApprovalValidationError.invalidToken(field) }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case origin
        case runID
        case callID
        case tool
        case effectClass
        case canonicalArgumentDigest
        case workspaceID
        case argumentSHA256
        case operationPreviewSHA256
        case requestSHA256
        case idempotencyKey
        case logicalTargets
        case resolvedTargets
        case preconditions
        case workspaceRevision
        case targetAttestationSHA256
        case policySHA256
        case issuedAt
        case expiresAt
        case nonce
        case bindingSHA256
    }
}

public enum DurableApprovalTokenField: String, Codable, Sendable {
    case idempotencyKey
    case workspaceRevision
    case authorityID
}

public enum DurableApprovalValidationError: Error, Equatable, Sendable {
    case invalidExpiry
    case invalidLifetime
    case invalidToken(DurableApprovalTokenField)
    case duplicatePrecondition(NormalizedToolTarget)
    case preconditionTargetMismatch
    case preconditionWorkspaceMismatch
    case bindingDigestMismatch
    case resolutionDigestMismatch
    case consumptionDigestMismatch
    case invalidEvidence
}

public struct DurableApprovalRequest: Codable, Equatable, Sendable {
    public let requestID: ApprovalRequestID
    public let registrationIdentity: DurableApprovalRegistrationIdentity
    public let binding: DurableApprovalBinding

    init(
        requestID: ApprovalRequestID,
        registrationIdentity: DurableApprovalRegistrationIdentity,
        binding: DurableApprovalBinding
    ) throws {
        guard registrationIdentity.isCanonical(),
              binding.isCanonical(),
              registrationIdentity.runID == binding.runID,
              registrationIdentity.callID == binding.callID,
              registrationIdentity.idempotencyKey == binding.idempotencyKey
        else {
            throw DurableApprovalValidationError.bindingDigestMismatch
        }
        self.requestID = requestID
        self.registrationIdentity = registrationIdentity
        self.binding = binding
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(
                ApprovalRequestID.self,
                forKey: .requestID
            ),
            registrationIdentity: container.decode(
                DurableApprovalRegistrationIdentity.self,
                forKey: .registrationIdentity
            ),
            binding: container.decode(
                DurableApprovalBinding.self,
                forKey: .binding
            )
        )
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case registrationIdentity
        case binding
    }
}

public enum ApprovalDecisionMACValidationError: Error, Equatable, Sendable {
    case invalidFormat
}

public struct ApprovalDecisionMAC:
    Codable,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let prefix = "hmac-sha256:"
        guard rawValue.hasPrefix(prefix) else {
            throw ApprovalDecisionMACValidationError.invalidFormat
        }
        let hexadecimal = rawValue.dropFirst(prefix.count)
        guard hexadecimal.utf8.count == 64,
              hexadecimal.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              })
        else { throw ApprovalDecisionMACValidationError.invalidFormat }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct DurableApprovalResolution: Codable, Equatable, Sendable {
    public let requestID: ApprovalRequestID
    public let bindingSHA256: SHA256Digest
    public let decision: ApprovalDecision
    public let resolvedAt: AgentInstant
    public let authorityID: String
    public let resolutionSHA256: SHA256Digest
    public let decisionMAC: ApprovalDecisionMAC

    fileprivate struct DigestMaterial: Codable {
        let requestID: ApprovalRequestID
        let bindingSHA256: SHA256Digest
        let decision: ApprovalDecision
        let resolvedAt: AgentInstant
        let authorityID: String
    }

    static func unsigned(
        request: DurableApprovalRequest,
        decision: ApprovalDecision,
        resolvedAt: AgentInstant,
        authorityID: String
    ) throws -> UnsignedResolution {
        let normalizedAuthority = try validatedAuthorityID(authorityID)
        let material = DigestMaterial(
            requestID: request.requestID,
            bindingSHA256: request.binding.bindingSHA256,
            decision: decision,
            resolvedAt: resolvedAt,
            authorityID: normalizedAuthority
        )
        return UnsignedResolution(
            material: material,
            digest: try PolicyCanonicalDigest.sha256(
                domain: .approvalResolution,
                material
            )
        )
    }

    static func signed(
        _ unsigned: UnsignedResolution,
        mac: ApprovalDecisionMAC
    ) -> Self {
        Self(
            requestID: unsigned.material.requestID,
            bindingSHA256: unsigned.material.bindingSHA256,
            decision: unsigned.material.decision,
            resolvedAt: unsigned.material.resolvedAt,
            authorityID: unsigned.material.authorityID,
            resolutionSHA256: unsigned.digest,
            decisionMAC: mac
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let material = DigestMaterial(
            requestID: try container.decode(
                ApprovalRequestID.self,
                forKey: .requestID
            ),
            bindingSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .bindingSHA256
            ),
            decision: try container.decode(
                ApprovalDecision.self,
                forKey: .decision
            ),
            resolvedAt: try container.decode(
                AgentInstant.self,
                forKey: .resolvedAt
            ),
            authorityID: try Self.validatedAuthorityID(
                container.decode(String.self, forKey: .authorityID)
            )
        )
        let digest = try PolicyCanonicalDigest.sha256(
            domain: .approvalResolution,
            material
        )
        guard digest == (try container.decode(
            SHA256Digest.self,
            forKey: .resolutionSHA256
        )) else {
            throw DurableApprovalValidationError.resolutionDigestMismatch
        }
        self.init(
            requestID: material.requestID,
            bindingSHA256: material.bindingSHA256,
            decision: material.decision,
            resolvedAt: material.resolvedAt,
            authorityID: material.authorityID,
            resolutionSHA256: digest,
            decisionMAC: try container.decode(
                ApprovalDecisionMAC.self,
                forKey: .decisionMAC
            )
        )
    }

    private init(
        requestID: ApprovalRequestID,
        bindingSHA256: SHA256Digest,
        decision: ApprovalDecision,
        resolvedAt: AgentInstant,
        authorityID: String,
        resolutionSHA256: SHA256Digest,
        decisionMAC: ApprovalDecisionMAC
    ) {
        self.requestID = requestID
        self.bindingSHA256 = bindingSHA256
        self.decision = decision
        self.resolvedAt = resolvedAt
        self.authorityID = authorityID
        self.resolutionSHA256 = resolutionSHA256
        self.decisionMAC = decisionMAC
    }

    func isCanonical() -> Bool {
        guard let authority = try? Self.validatedAuthorityID(authorityID) else {
            return false
        }
        let material = DigestMaterial(
            requestID: requestID,
            bindingSHA256: bindingSHA256,
            decision: decision,
            resolvedAt: resolvedAt,
            authorityID: authority
        )
        return (try? PolicyCanonicalDigest.sha256(
            domain: .approvalResolution,
            material
        )) == resolutionSHA256
    }

    private static func validatedAuthorityID(_ value: String) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && $0.properties.generalCategory != .format
              })
        else {
            throw DurableApprovalValidationError.invalidToken(.authorityID)
        }
        return value
    }

    struct UnsignedResolution: Sendable {
        fileprivate let material: DigestMaterial
        let digest: SHA256Digest

        fileprivate init(material: DigestMaterial, digest: SHA256Digest) {
            self.material = material
            self.digest = digest
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case bindingSHA256
        case decision
        case resolvedAt
        case authorityID
        case resolutionSHA256
        case decisionMAC
    }
}

/// Ephemeral, non-Codable UI input. Exact operation arguments are deliberately
/// available only while a live sealed policy request is being resolved; the
/// durable ledger stores only `operationPreviewSHA256`.
public struct DurableApprovalPromptContext: Sendable {
    public let approvalRequest: DurableApprovalRequest
    public let operationPreview: MutationEffectApprovalPreview

    init(
        approvalRequest: DurableApprovalRequest,
        operationPreview: MutationEffectApprovalPreview
    ) {
        self.approvalRequest = approvalRequest
        self.operationPreview = operationPreview
    }
}

public protocol ApprovalDecisionPrompting: Sendable {
    func requestDecision(
        for context: DurableApprovalPromptContext
    ) async throws -> ApprovalDecision
}

public enum TrustedApprovalUIAuthorityError: Error, Equatable, Sendable {
    case signingKeyTooShort
    case untrustedDecision
    case decisionOutsideValidityWindow
    case clockUnavailable
}

/// The app creates one instance from keychain-held signing material and a real
/// UI prompt. Public Codable resolution records are evidence only; the opaque
/// token below can only be minted and verified by this configured authority.
public final actor TrustedApprovalUIAuthority {
    private let authorityID: String
    private let key: SymmetricKey
    private let prompt: any ApprovalDecisionPrompting
    private let clock: any PolicyClock
    private let seal = UUID()

    public init(
        signingKey: Data,
        prompt: any ApprovalDecisionPrompting,
        clock: any PolicyClock
    ) throws {
        guard signingKey.count >= 32 else {
            throw TrustedApprovalUIAuthorityError.signingKeyTooShort
        }
        let trustedKey = SymmetricKey(data: signingKey)
        let authorityCode = HMAC<SHA256>.authenticationCode(
            for: Data("novaforge-trusted-approval-ui-authority-v1".utf8),
            using: trustedKey
        )
        authorityID = "trusted-ui-hmac-sha256:" + authorityCode.map {
            String(format: "%02x", $0)
        }.joined()
        key = trustedKey
        self.prompt = prompt
        self.clock = clock
    }

    public func decide(
        _ context: DurableApprovalPromptContext
    ) async throws -> TrustedApprovalDecision {
        let request = context.approvalRequest
        let decision = try await prompt.requestDecision(for: context)
        let now: AgentInstant
        do {
            now = try await clock.currentInstant()
        } catch {
            throw TrustedApprovalUIAuthorityError.clockUnavailable
        }
        guard now >= request.binding.issuedAt,
              now < request.binding.expiresAt
        else {
            throw TrustedApprovalUIAuthorityError.decisionOutsideValidityWindow
        }
        let unsigned = try DurableApprovalResolution.unsigned(
            request: request,
            decision: decision,
            resolvedAt: now,
            authorityID: authorityID
        )
        let mac = try Self.mac(for: unsigned.digest, key: key)
        return TrustedApprovalDecision(
            resolution: .signed(unsigned, mac: mac),
            authoritySeal: seal
        )
    }

    func validate(_ decision: TrustedApprovalDecision) -> Bool {
        decision.authoritySeal == seal && validate(decision.resolution)
    }

    func validate(_ resolution: DurableApprovalResolution) -> Bool {
        guard resolution.authorityID == authorityID,
              resolution.isCanonical(),
              let provided = Self.macBytes(resolution.decisionMAC)
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            provided,
            authenticating: Data(resolution.resolutionSHA256.rawValue.utf8),
            using: key
        )
    }

    private static func mac(
        for digest: SHA256Digest,
        key: SymmetricKey
    ) throws -> ApprovalDecisionMAC {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(digest.rawValue.utf8),
            using: key
        )
        let hex = code.map { String(format: "%02x", $0) }.joined()
        return try ApprovalDecisionMAC("hmac-sha256:" + hex)
    }

    private static func macBytes(_ mac: ApprovalDecisionMAC) -> Data? {
        let hex = mac.rawValue.dropFirst("hmac-sha256:".count)
        var data = Data()
        data.reserveCapacity(32)
        var index = hex.startIndex
        for _ in 0 ..< 32 {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

}

public struct TrustedApprovalDecision: Sendable {
    public let resolution: DurableApprovalResolution
    fileprivate let authoritySeal: UUID

    fileprivate init(
        resolution: DurableApprovalResolution,
        authoritySeal: UUID
    ) {
        self.resolution = resolution
        self.authoritySeal = authoritySeal
    }
}

public struct DurableApprovalConsumptionRecord: Codable, Equatable, Sendable {
    public let requestID: ApprovalRequestID
    public let bindingSHA256: SHA256Digest
    public let resolutionSHA256: SHA256Digest
    public let targetAttestationSHA256: SHA256Digest
    public let nonce: ApprovalNonce
    public let idempotencyKey: String
    public let authorizedAt: AgentInstant
    public let expiresAt: AgentInstant
    public let consumptionSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let requestID: ApprovalRequestID
        let bindingSHA256: SHA256Digest
        let resolutionSHA256: SHA256Digest
        let targetAttestationSHA256: SHA256Digest
        let nonce: ApprovalNonce
        let idempotencyKey: String
        let authorizedAt: AgentInstant
        let expiresAt: AgentInstant
    }

    static func make(
        request: DurableApprovalRequest,
        resolution: DurableApprovalResolution,
        authorizedAt: AgentInstant
    ) throws -> Self {
        let material = DigestMaterial(
            requestID: request.requestID,
            bindingSHA256: request.binding.bindingSHA256,
            resolutionSHA256: resolution.resolutionSHA256,
            targetAttestationSHA256: request.binding.targetAttestationSHA256,
            nonce: request.binding.nonce,
            idempotencyKey: request.binding.idempotencyKey,
            authorizedAt: authorizedAt,
            expiresAt: request.binding.expiresAt
        )
        return Self(
            material: material,
            consumptionSHA256: try PolicyCanonicalDigest.sha256(
                domain: .approvalConsumption,
                material
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let material = DigestMaterial(
            requestID: try container.decode(
                ApprovalRequestID.self,
                forKey: .requestID
            ),
            bindingSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .bindingSHA256
            ),
            resolutionSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .resolutionSHA256
            ),
            targetAttestationSHA256: try container.decode(
                SHA256Digest.self,
                forKey: .targetAttestationSHA256
            ),
            nonce: try container.decode(ApprovalNonce.self, forKey: .nonce),
            idempotencyKey: try container.decode(
                String.self,
                forKey: .idempotencyKey
            ),
            authorizedAt: try container.decode(
                AgentInstant.self,
                forKey: .authorizedAt
            ),
            expiresAt: try container.decode(
                AgentInstant.self,
                forKey: .expiresAt
            )
        )
        let digest = try PolicyCanonicalDigest.sha256(
            domain: .approvalConsumption,
            material
        )
        guard digest == (try container.decode(
            SHA256Digest.self,
            forKey: .consumptionSHA256
        )) else {
            throw DurableApprovalValidationError.consumptionDigestMismatch
        }
        self.init(material: material, consumptionSHA256: digest)
    }

    private init(material: DigestMaterial, consumptionSHA256: SHA256Digest) {
        requestID = material.requestID
        bindingSHA256 = material.bindingSHA256
        resolutionSHA256 = material.resolutionSHA256
        targetAttestationSHA256 = material.targetAttestationSHA256
        nonce = material.nonce
        idempotencyKey = material.idempotencyKey
        authorizedAt = material.authorizedAt
        expiresAt = material.expiresAt
        self.consumptionSHA256 = consumptionSHA256
    }

    func isCanonical() -> Bool {
        let material = DigestMaterial(
            requestID: requestID,
            bindingSHA256: bindingSHA256,
            resolutionSHA256: resolutionSHA256,
            targetAttestationSHA256: targetAttestationSHA256,
            nonce: nonce,
            idempotencyKey: idempotencyKey,
            authorizedAt: authorizedAt,
            expiresAt: expiresAt
        )
        return (try? PolicyCanonicalDigest.sha256(
            domain: .approvalConsumption,
            material
        )) == consumptionSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case bindingSHA256
        case resolutionSHA256
        case targetAttestationSHA256
        case nonce
        case idempotencyKey
        case authorizedAt
        case expiresAt
        case consumptionSHA256
    }
}

public struct DurableApprovalLease: Sendable {
    public let request: DurableApprovalRequest
    public let resolution: DurableApprovalResolution
    public let consumption: DurableApprovalConsumptionRecord
    public let isRecovery: Bool

    let targetAttestation: ResolvedInvocationTargets
    let descriptor: ToolDescriptor
    let invocation: ToolInvocation
    let policyRevision: TrustedPolicyRevision
    let finalizationGate: SingleUsePolicyAuthorityGate

    init(
        request: DurableApprovalRequest,
        resolution: DurableApprovalResolution,
        consumption: DurableApprovalConsumptionRecord,
        targetAttestation: ResolvedInvocationTargets,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        policyRevision: TrustedPolicyRevision,
        isRecovery: Bool
    ) {
        self.request = request
        self.resolution = resolution
        self.consumption = consumption
        self.targetAttestation = targetAttestation
        self.descriptor = descriptor
        self.invocation = invocation
        self.policyRevision = policyRevision
        self.isRecovery = isRecovery
        finalizationGate = SingleUsePolicyAuthorityGate()
    }
}

public enum ApprovalRegistrationDisposition: Equatable, Sendable {
    case registered
    case alreadyRegistered(DurableApprovalRequest)
}

public enum ApprovalResolutionDisposition: Equatable, Sendable {
    case resolved
    case alreadyResolved(DurableApprovalResolution)
}

public enum ApprovalConsumptionDisposition: Equatable, Sendable {
    case consumed
    case alreadyConsumed(DurableApprovalConsumptionRecord)
}

public struct DurableApprovalState: Codable, Equatable, Sendable {
    public let request: DurableApprovalRequest
    public let resolution: DurableApprovalResolution?
    public let consumption: DurableApprovalConsumptionRecord?

    public init(
        request: DurableApprovalRequest,
        resolution: DurableApprovalResolution?,
        consumption: DurableApprovalConsumptionRecord?
    ) {
        self.request = request
        self.resolution = resolution
        self.consumption = consumption
    }
}

public struct DurableApprovalLedgerSnapshot: Codable, Equatable, Sendable {
    public let states: [DurableApprovalState]
    public init(states: [DurableApprovalState]) { self.states = states }
}

public enum DurableApprovalStoreError: Error, Equatable, Sendable {
    case corruptEvidence
    case requestConflict(ApprovalRequestID)
    case requestNotFound(ApprovalRequestID)
    case resolutionConflict(ApprovalRequestID)
    case consumptionConflict(ApprovalRequestID)
    case nonceConflict(ApprovalNonce)
    case registrationConflict(SHA256Digest)
}

/// Production implementations must make each compare-and-insert transaction
/// durable before returning success. All executable authority is minted only
/// after these methods return `.registered`, `.resolved`, or `.consumed`.
public protocol DurableApprovalStore: Sendable {
    func registerIfAbsent(
        _ request: DurableApprovalRequest
    ) async throws -> ApprovalRegistrationDisposition
    func resolveIfPending(
        _ resolution: DurableApprovalResolution
    ) async throws -> ApprovalResolutionDisposition
    func consumeIfUnconsumed(
        _ consumption: DurableApprovalConsumptionRecord
    ) async throws -> ApprovalConsumptionDisposition
    func state(
        requestID: ApprovalRequestID
    ) async throws -> DurableApprovalState?
    func state(
        registrationKeySHA256: SHA256Digest
    ) async throws -> DurableApprovalState?
}

public actor InMemoryDurableApprovalStore: DurableApprovalStore {
    private var states: [ApprovalRequestID: DurableApprovalState]
    private var requestIDByNonce: [ApprovalNonce: ApprovalRequestID]
    private var requestIDByRegistrationKey: [
        SHA256Digest: ApprovalRequestID
    ]

    public init() {
        states = [:]
        requestIDByNonce = [:]
        requestIDByRegistrationKey = [:]
    }

    public init(restoring snapshot: DurableApprovalLedgerSnapshot) throws {
        var restored: [ApprovalRequestID: DurableApprovalState] = [:]
        var nonces: [ApprovalNonce: ApprovalRequestID] = [:]
        var registrations: [SHA256Digest: ApprovalRequestID] = [:]
        for state in snapshot.states {
            try Self.validate(state)
            guard restored[state.request.requestID] == nil,
                  nonces[state.request.binding.nonce] == nil,
                  registrations[
                    state.request.registrationIdentity.keySHA256
                  ] == nil
            else { throw DurableApprovalStoreError.corruptEvidence }
            restored[state.request.requestID] = state
            nonces[state.request.binding.nonce] = state.request.requestID
            registrations[state.request.registrationIdentity.keySHA256] =
                state.request.requestID
        }
        states = restored
        requestIDByNonce = nonces
        requestIDByRegistrationKey = registrations
    }

    public func registerIfAbsent(
        _ request: DurableApprovalRequest
    ) throws -> ApprovalRegistrationDisposition {
        guard request.registrationIdentity.isCanonical(),
              request.binding.isCanonical(),
              request.registrationIdentity.runID == request.binding.runID,
              request.registrationIdentity.callID == request.binding.callID,
              request.registrationIdentity.idempotencyKey
                == request.binding.idempotencyKey
        else {
            throw DurableApprovalStoreError.corruptEvidence
        }
        if let existing = states[request.requestID] {
            guard existing.request == request else {
                throw DurableApprovalStoreError.requestConflict(
                    request.requestID
                )
            }
            return .alreadyRegistered(existing.request)
        }
        if let existingID = requestIDByRegistrationKey[
            request.registrationIdentity.keySHA256
        ], let existing = states[existingID] {
            return .alreadyRegistered(existing.request)
        }
        if let existingID = requestIDByNonce[request.binding.nonce] {
            throw DurableApprovalStoreError.nonceConflict(
                states[existingID]?.request.binding.nonce
                    ?? request.binding.nonce
            )
        }
        states[request.requestID] = DurableApprovalState(
            request: request,
            resolution: nil,
            consumption: nil
        )
        requestIDByNonce[request.binding.nonce] = request.requestID
        requestIDByRegistrationKey[
            request.registrationIdentity.keySHA256
        ] = request.requestID
        return .registered
    }

    public func resolveIfPending(
        _ resolution: DurableApprovalResolution
    ) throws -> ApprovalResolutionDisposition {
        guard var state = states[resolution.requestID] else {
            throw DurableApprovalStoreError.requestNotFound(
                resolution.requestID
            )
        }
        guard resolution.isCanonical(),
              resolution.bindingSHA256 == state.request.binding.bindingSHA256,
              resolution.resolvedAt >= state.request.binding.issuedAt,
              resolution.resolvedAt < state.request.binding.expiresAt
        else { throw DurableApprovalStoreError.corruptEvidence }
        if let existing = state.resolution {
            guard existing == resolution else {
                throw DurableApprovalStoreError.resolutionConflict(
                    resolution.requestID
                )
            }
            return .alreadyResolved(existing)
        }
        state = DurableApprovalState(
            request: state.request,
            resolution: resolution,
            consumption: nil
        )
        states[resolution.requestID] = state
        return .resolved
    }

    public func consumeIfUnconsumed(
        _ consumption: DurableApprovalConsumptionRecord
    ) throws -> ApprovalConsumptionDisposition {
        guard var state = states[consumption.requestID],
              let resolution = state.resolution
        else {
            throw DurableApprovalStoreError.requestNotFound(
                consumption.requestID
            )
        }
        guard consumption.isCanonical(),
              resolution.decision == .approved,
              consumption.bindingSHA256 == state.request.binding.bindingSHA256,
              consumption.resolutionSHA256 == resolution.resolutionSHA256,
              consumption.targetAttestationSHA256
                == state.request.binding.targetAttestationSHA256,
              consumption.nonce == state.request.binding.nonce,
              consumption.idempotencyKey == state.request.binding.idempotencyKey,
              consumption.authorizedAt >= resolution.resolvedAt,
              consumption.authorizedAt >= state.request.binding.issuedAt,
              consumption.authorizedAt < state.request.binding.expiresAt,
              consumption.expiresAt == state.request.binding.expiresAt
        else { throw DurableApprovalStoreError.corruptEvidence }
        if let existing = state.consumption {
            return .alreadyConsumed(existing)
        }
        state = DurableApprovalState(
            request: state.request,
            resolution: resolution,
            consumption: consumption
        )
        states[consumption.requestID] = state
        return .consumed
    }

    public func state(
        requestID: ApprovalRequestID
    ) -> DurableApprovalState? {
        states[requestID]
    }

    public func state(
        registrationKeySHA256: SHA256Digest
    ) -> DurableApprovalState? {
        guard let requestID = requestIDByRegistrationKey[
            registrationKeySHA256
        ] else { return nil }
        return states[requestID]
    }

    public func snapshot() -> DurableApprovalLedgerSnapshot {
        DurableApprovalLedgerSnapshot(states: states.values.sorted {
            $0.request.requestID.description < $1.request.requestID.description
        })
    }

    static func validate(_ state: DurableApprovalState) throws {
        let request = state.request
        guard request.registrationIdentity.isCanonical(),
              request.binding.isCanonical(),
              request.registrationIdentity.runID == request.binding.runID,
              request.registrationIdentity.callID == request.binding.callID,
              request.registrationIdentity.idempotencyKey
                == request.binding.idempotencyKey
        else {
            throw DurableApprovalStoreError.corruptEvidence
        }
        if let resolution = state.resolution {
            guard resolution.isCanonical(),
                  resolution.requestID == request.requestID,
                  resolution.bindingSHA256 == request.binding.bindingSHA256,
                  resolution.resolvedAt >= request.binding.issuedAt,
                  resolution.resolvedAt < request.binding.expiresAt
            else { throw DurableApprovalStoreError.corruptEvidence }
        } else if state.consumption != nil {
            throw DurableApprovalStoreError.corruptEvidence
        }
        if let consumption = state.consumption,
           let resolution = state.resolution {
            guard resolution.decision == .approved,
                  consumption.isCanonical(),
                  consumption.requestID == request.requestID,
                  consumption.bindingSHA256 == request.binding.bindingSHA256,
                  consumption.resolutionSHA256 == resolution.resolutionSHA256,
                  consumption.targetAttestationSHA256
                    == request.binding.targetAttestationSHA256,
                  consumption.nonce == request.binding.nonce,
                  consumption.idempotencyKey == request.binding.idempotencyKey,
                  consumption.authorizedAt >= resolution.resolvedAt,
                  consumption.authorizedAt < request.binding.expiresAt,
                  consumption.expiresAt == request.binding.expiresAt
            else { throw DurableApprovalStoreError.corruptEvidence }
        }
    }
}

public enum DurableApprovalAuthorityError: Error, Equatable, Sendable {
    case authorizationAlreadyFinalized
    case invalidLifetime
    case policyDidNotRequireApproval
    case policyChanged
    case clockUnavailable
    case requestNotFound
    case approvalPending
    case approvalRejected
    case expired
    case untrustedResolution
    case bindingChanged
    case targetRevalidationFailed
    case replayedConsumption
    case durableCommitFailed
    case incompleteRecoveryState
}

public final actor DurableApprovalAuthority {
    private let store: any DurableApprovalStore
    private let clock: any PolicyClock
    private let resolver: WorkspaceTargetResolverAuthority
    private let uiAuthority: TrustedApprovalUIAuthority
    private let policyRevisionAuthority: PolicyRevisionAuthority

    public init(
        store: any DurableApprovalStore,
        clock: any PolicyClock,
        resolver: WorkspaceTargetResolverAuthority,
        uiAuthority: TrustedApprovalUIAuthority,
        policyRevisionAuthority: PolicyRevisionAuthority
    ) {
        self.store = store
        self.clock = clock
        self.resolver = resolver
        self.uiAuthority = uiAuthority
        self.policyRevisionAuthority = policyRevisionAuthority
    }

    public func register(
        for policyRequest: RiskPolicyRequest,
        evaluation: RiskPolicyEvaluation,
        lifetimeMilliseconds: UInt64
    ) async throws -> DurableApprovalRequest {
        let revision = policyRevisionAuthority.currentRevision()
        guard evaluation.requestSHA256 == policyRequest.requestSHA256,
              case nil = evaluation.executionPermit,
              case .requiresApproval = evaluation.decision
        else {
            throw DurableApprovalAuthorityError.policyDidNotRequireApproval
        }
        guard evaluation.policySHA256 == revision.policySHA256,
              evaluation.policyRevision == revision
        else { throw DurableApprovalAuthorityError.policyChanged }
        guard (1 ... 86_400_000).contains(lifetimeMilliseconds),
              lifetimeMilliseconds <= UInt64(Int64.max)
        else { throw DurableApprovalAuthorityError.invalidLifetime }

        let registrationIdentity = try DurableApprovalRegistrationIdentity.make(
            runID: policyRequest.runID,
            callID: policyRequest.invocation.callID,
            idempotencyKey: policyRequest.invocation.idempotencyKey
        )
        guard policyRevisionAuthority.bindApprovalRevision(
            registrationKeySHA256: registrationIdentity.keySHA256,
            revision: revision
        ) else { throw DurableApprovalAuthorityError.policyChanged }

        let existing: DurableApprovalState?
        do {
            existing = try await store.state(
                registrationKeySHA256: registrationIdentity.keySHA256
            )
        } catch {
            throw DurableApprovalAuthorityError.durableCommitFailed
        }
        try requireCurrentPolicy(revision)

        do {
            // An opaque `requiresApproval` evaluation is necessary but not
            // sufficient: it may have been paired with a request minted by a
            // different resolver authority, or its preview may already be
            // stale. Never persist or display that request as approvable.
            _ = try await resolver.revalidate(
                policyRequest.targetAttestation
            )
        } catch {
            throw DurableApprovalAuthorityError.targetRevalidationFailed
        }
        try requireCurrentPolicy(revision)

        if let existing {
            try validateRegistrationRetry(
                existing.request,
                registrationIdentity: registrationIdentity,
                policyRequest: policyRequest,
                policyRevision: revision,
                lifetimeMilliseconds: lifetimeMilliseconds
            )
            return existing.request
        }

        let now = try await trustedNow()
        try requireCurrentPolicy(revision)
        let duration = Int64(lifetimeMilliseconds)
        guard now.rawValue <= Int64.max - duration else {
            throw DurableApprovalAuthorityError.invalidLifetime
        }
        let binding = try DurableApprovalBinding.make(
            request: policyRequest,
            policySHA256: revision.policySHA256,
            issuedAt: now,
            expiresAt: AgentInstant(rawValue: now.rawValue + duration),
            nonce: ApprovalNonce(UUID().uuidString.lowercased())
        )
        let request = try DurableApprovalRequest(
            requestID: ApprovalRequestID(),
            registrationIdentity: registrationIdentity,
            binding: binding
        )
        do {
            switch try await store.registerIfAbsent(request) {
            case .registered:
                try requireCurrentPolicy(revision)
                return request
            case let .alreadyRegistered(existing):
                try validateRegistrationRetry(
                    existing,
                    registrationIdentity: registrationIdentity,
                    policyRequest: policyRequest,
                    policyRevision: revision,
                    lifetimeMilliseconds: lifetimeMilliseconds
                )
                try requireCurrentPolicy(revision)
                return existing
            }
        } catch let error as DurableApprovalAuthorityError {
            throw error
        } catch {
            throw DurableApprovalAuthorityError.durableCommitFailed
        }
    }

    public func resolve(
        requestID: ApprovalRequestID,
        for policyRequest: RiskPolicyRequest
    ) async throws -> DurableApprovalResolution {
        guard let state = try await store.state(requestID: requestID) else {
            throw DurableApprovalAuthorityError.requestNotFound
        }
        let binding = state.request.binding
        guard state.request.registrationIdentity.isCanonical(),
              bindingMatches(binding, policyRequest: policyRequest),
              let preview = try? MutationEffectApprovalPreview.derive(
                  origin: policyRequest.origin,
                  descriptor: policyRequest.descriptor,
                  invocation: policyRequest.invocation
              ),
              preview.previewSHA256 == binding.operationPreviewSHA256
        else { throw DurableApprovalAuthorityError.bindingChanged }
        guard let revision = policyRevisionAuthority
            .revisionForDurableApproval(
                registrationKeySHA256:
                    state.request.registrationIdentity.keySHA256,
                policySHA256: binding.policySHA256
            )
        else { throw DurableApprovalAuthorityError.policyChanged }
        try requireCurrentPolicy(revision)
        do {
            _ = try await resolver.revalidate(
                policyRequest.targetAttestation
            )
        } catch {
            throw DurableApprovalAuthorityError.targetRevalidationFailed
        }
        try requireCurrentPolicy(revision)
        if let existing = state.resolution {
            guard await uiAuthority.validate(existing) else {
                throw DurableApprovalAuthorityError.untrustedResolution
            }
            return existing
        }
        let decision = try await uiAuthority.decide(
            DurableApprovalPromptContext(
                approvalRequest: state.request,
                operationPreview: preview
            )
        )
        guard await uiAuthority.validate(decision) else {
            throw DurableApprovalAuthorityError.untrustedResolution
        }
        try requireCurrentPolicy(revision)
        do {
            switch try await store.resolveIfPending(decision.resolution) {
            case .resolved:
                return decision.resolution
            case let .alreadyResolved(existing):
                guard await uiAuthority.validate(existing) else {
                    throw DurableApprovalAuthorityError.untrustedResolution
                }
                return existing
            }
        } catch let error as DurableApprovalAuthorityError {
            throw error
        } catch {
            throw DurableApprovalAuthorityError.durableCommitFailed
        }
    }

    public func authorize(
        requestID: ApprovalRequestID,
        for policyRequest: RiskPolicyRequest
    ) async throws -> DurableApprovalLease {
        let validated = try await validatedState(
            requestID: requestID,
            policyRequest: policyRequest,
            requireConsumption: false
        )
        let state = validated.state
        guard state.consumption == nil else {
            throw DurableApprovalAuthorityError.replayedConsumption
        }
        guard let resolution = state.resolution else {
            throw DurableApprovalAuthorityError.approvalPending
        }

        _ = try await trustedNow()
        do {
            _ = try await resolver.revalidate(
                policyRequest.targetAttestation
            )
        } catch {
            throw DurableApprovalAuthorityError.targetRevalidationFailed
        }
        // A second trusted read happens after potentially slow resolution and
        // immediately before the durable consume transaction / lease mint.
        let authorizedAt = try await trustedNow()
        guard authorizedAt >= resolution.resolvedAt,
              authorizedAt >= state.request.binding.issuedAt,
              authorizedAt < state.request.binding.expiresAt
        else { throw DurableApprovalAuthorityError.expired }
        try requireCurrentPolicy(validated.policyRevision)

        let consumption = try DurableApprovalConsumptionRecord.make(
            request: state.request,
            resolution: resolution,
            authorizedAt: authorizedAt
        )
        do {
            switch try await store.consumeIfUnconsumed(consumption) {
            case .consumed:
                try requireCurrentPolicy(validated.policyRevision)
                return DurableApprovalLease(
                    request: state.request,
                    resolution: resolution,
                    consumption: consumption,
                    targetAttestation: policyRequest.targetAttestation,
                    descriptor: policyRequest.descriptor,
                    invocation: policyRequest.invocation,
                    policyRevision: validated.policyRevision,
                    isRecovery: false
                )
            case .alreadyConsumed:
                throw DurableApprovalAuthorityError.replayedConsumption
            }
        } catch let error as DurableApprovalAuthorityError {
            throw error
        } catch {
            throw DurableApprovalAuthorityError.durableCommitFailed
        }
    }

    /// Recovery accepts only an ID and re-reads the configured durable store.
    /// It never accepts a caller-provided Codable snapshot. Every digest, UI
    /// MAC, clock window, request binding, preview, path, and revision is
    /// revalidated before a recovery lease is minted.
    public func recoverLease(
        requestID: ApprovalRequestID,
        for policyRequest: RiskPolicyRequest
    ) async throws -> DurableApprovalLease {
        let validated = try await validatedState(
            requestID: requestID,
            policyRequest: policyRequest,
            requireConsumption: true
        )
        let state = validated.state
        guard let resolution = state.resolution,
              let consumption = state.consumption
        else { throw DurableApprovalAuthorityError.incompleteRecoveryState }
        _ = try await trustedNow()
        do {
            _ = try await resolver.revalidate(
                policyRequest.targetAttestation
            )
        } catch {
            throw DurableApprovalAuthorityError.targetRevalidationFailed
        }
        let now = try await trustedNow()
        guard now >= consumption.authorizedAt,
              now < consumption.expiresAt
        else { throw DurableApprovalAuthorityError.expired }
        try requireCurrentPolicy(validated.policyRevision)
        return DurableApprovalLease(
            request: state.request,
            resolution: resolution,
            consumption: consumption,
            targetAttestation: policyRequest.targetAttestation,
            descriptor: policyRequest.descriptor,
            invocation: policyRequest.invocation,
            policyRevision: validated.policyRevision,
            isRecovery: true
        )
    }

    /// Performs the required final resolver pass immediately before an effect.
    /// App executors must accept only `ToolEffectPermit`, never this preliminary
    /// durable lease.
    public func finalizeForExecution(
        _ lease: DurableApprovalLease
    ) async throws -> ToolEffectPermit {
        guard await lease.finalizationGate.claim() else {
            throw DurableApprovalAuthorityError.authorizationAlreadyFinalized
        }
        try requireCurrentPolicy(lease.policyRevision)
        guard let state = try await store.state(
            requestID: lease.request.requestID
        ),
            state.request == lease.request,
            state.resolution == lease.resolution,
            state.consumption == lease.consumption,
            await uiAuthority.validate(lease.resolution)
        else {
            throw DurableApprovalAuthorityError.incompleteRecoveryState
        }
        try requireCurrentPolicy(lease.policyRevision)
        let workspaceLease: WorkspaceExecutionLease
        do {
            workspaceLease = try await resolver.revalidate(
                lease.targetAttestation
            )
        } catch {
            throw DurableApprovalAuthorityError.targetRevalidationFailed
        }
        let now = try await trustedNow()
        guard now >= lease.consumption.authorizedAt,
              now < lease.consumption.expiresAt
        else { throw DurableApprovalAuthorityError.expired }
        try requireCurrentPolicy(lease.policyRevision)
        guard let preview = try? MutationEffectApprovalPreview.derive(
            origin: lease.request.binding.origin,
            descriptor: lease.descriptor,
            invocation: lease.invocation
        ),
            preview.previewSHA256
                == lease.request.binding.operationPreviewSHA256
        else { throw DurableApprovalAuthorityError.bindingChanged }
        return try ToolEffectPermit(
            origin: lease.request.binding.origin,
            requestSHA256: lease.request.binding.requestSHA256,
            policyRevision: lease.policyRevision,
            tool: lease.request.binding.tool,
            effectClass: lease.request.binding.effectClass,
            canonicalArgumentDigest:
                lease.request.binding.canonicalArgumentDigest,
            operationPayloadSHA256: lease.request.binding.argumentSHA256,
            operationPreviewSHA256:
                lease.request.binding.operationPreviewSHA256,
            callID: lease.request.binding.callID,
            idempotencyKey: lease.request.binding.idempotencyKey,
            authorizedAt: now,
            expiresAt: lease.request.binding.expiresAt,
            source: .durableApproval(
                requestID: lease.request.requestID,
                consumptionSHA256: lease.consumption.consumptionSHA256,
                recovery: lease.isRecovery
            ),
            descriptor: lease.descriptor,
            invocation: lease.invocation,
            workspaceLease: workspaceLease,
            targetAttestation: lease.targetAttestation
        )
    }

    private func validatedState(
        requestID: ApprovalRequestID,
        policyRequest: RiskPolicyRequest,
        requireConsumption: Bool
    ) async throws -> ValidatedApprovalState {
        guard let state = try await store.state(requestID: requestID) else {
            throw DurableApprovalAuthorityError.requestNotFound
        }
        let binding = state.request.binding
        guard state.request.registrationIdentity.isCanonical(),
              bindingMatches(binding, policyRequest: policyRequest)
        else { throw DurableApprovalAuthorityError.bindingChanged }
        guard let revision = policyRevisionAuthority
            .revisionForDurableApproval(
                registrationKeySHA256:
                    state.request.registrationIdentity.keySHA256,
                policySHA256: binding.policySHA256
            )
        else { throw DurableApprovalAuthorityError.policyChanged }
        guard let resolution = state.resolution else {
            if requireConsumption {
                throw DurableApprovalAuthorityError.incompleteRecoveryState
            }
            throw DurableApprovalAuthorityError.approvalPending
        }
        guard await uiAuthority.validate(resolution),
              resolution.requestID == requestID,
              resolution.bindingSHA256 == binding.bindingSHA256
        else { throw DurableApprovalAuthorityError.untrustedResolution }
        guard resolution.decision == .approved else {
            throw DurableApprovalAuthorityError.approvalRejected
        }
        if let consumption = state.consumption {
            guard consumption.isCanonical(),
                  consumption.requestID == requestID,
                  consumption.bindingSHA256 == binding.bindingSHA256,
                  consumption.resolutionSHA256 == resolution.resolutionSHA256,
                  consumption.targetAttestationSHA256
                    == binding.targetAttestationSHA256,
                  consumption.nonce == binding.nonce,
                  consumption.idempotencyKey == binding.idempotencyKey,
                  consumption.expiresAt == binding.expiresAt
            else { throw DurableApprovalAuthorityError.incompleteRecoveryState }
        } else if requireConsumption {
            throw DurableApprovalAuthorityError.incompleteRecoveryState
        }
        try requireCurrentPolicy(revision)
        return ValidatedApprovalState(
            state: state,
            policyRevision: revision
        )
    }

    private func validateRegistrationRetry(
        _ existing: DurableApprovalRequest,
        registrationIdentity: DurableApprovalRegistrationIdentity,
        policyRequest: RiskPolicyRequest,
        policyRevision: TrustedPolicyRevision,
        lifetimeMilliseconds: UInt64
    ) throws {
        let binding = existing.binding
        guard existing.registrationIdentity == registrationIdentity,
              bindingMatches(binding, policyRequest: policyRequest),
              binding.policySHA256 == policyRevision.policySHA256,
              binding.expiresAt.rawValue > binding.issuedAt.rawValue,
              UInt64(
                binding.expiresAt.rawValue - binding.issuedAt.rawValue
              ) == lifetimeMilliseconds
        else { throw DurableApprovalAuthorityError.bindingChanged }
        try requireCurrentPolicy(policyRevision)
    }

    private func bindingMatches(
        _ binding: DurableApprovalBinding,
        policyRequest: RiskPolicyRequest
    ) -> Bool {
        binding.isCanonical()
            && binding.origin == policyRequest.origin
            && binding.runID == policyRequest.runID
            && binding.callID == policyRequest.invocation.callID
            && binding.tool == policyRequest.invocation.tool
            && binding.effectClass == policyRequest.invocation.effectClass
            && binding.canonicalArgumentDigest
                == policyRequest.invocation.canonicalArgumentDigest
            && binding.workspaceID == policyRequest.workspaceID
            && binding.argumentSHA256 == policyRequest.argumentSHA256
            && binding.operationPreviewSHA256
                == policyRequest.operationPreviewSHA256
            && binding.requestSHA256 == policyRequest.requestSHA256
            && binding.idempotencyKey
                == policyRequest.invocation.idempotencyKey
            && binding.logicalTargets == policyRequest.logicalTargets
            && binding.resolvedTargets == policyRequest.resolvedTargets
            && binding.preconditions
                == policyRequest.targetAttestation.preconditions
            && binding.workspaceRevision
                == policyRequest.targetAttestation.workspaceRevision
            && binding.targetAttestationSHA256
                == policyRequest.targetAttestationSHA256
    }

    private func requireCurrentPolicy(
        _ revision: TrustedPolicyRevision
    ) throws {
        guard policyRevisionAuthority.currentRevision() == revision else {
            throw DurableApprovalAuthorityError.policyChanged
        }
    }

    private func trustedNow() async throws -> AgentInstant {
        do {
            return try await clock.currentInstant()
        } catch {
            throw DurableApprovalAuthorityError.clockUnavailable
        }
    }

    private struct ValidatedApprovalState: Sendable {
        let state: DurableApprovalState
        let policyRevision: TrustedPolicyRevision
    }
}
