import AgentDomain
import AgentTools
import Foundation

public struct NormalizedToolTarget: Codable, Hashable, Sendable {
    public let path: String
    public let access: ToolTargetAccess

    public init(path: String, access: ToolTargetAccess) throws {
        self.path = try Self.normalize(path)
        self.access = access
    }

    public init(_ target: ToolTarget) throws {
        try self.init(path: target.value, access: target.access)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedPath = try container.decode(String.self, forKey: .path)
        let access = try container.decode(ToolTargetAccess.self, forKey: .access)
        let rebuilt = try Self(path: encodedPath, access: access)
        guard rebuilt.path == encodedPath else {
            throw NormalizedToolTargetError.nonCanonicalEncoding(encodedPath)
        }
        self = rebuilt
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(access, forKey: .access)
    }

    public func isWithin(prefix: String) -> Bool {
        isWithinAuthorizationPrefix(prefix)
    }

    func isWithinAuthorizationPrefix(_ prefix: String) -> Bool {
        guard let normalizedPrefix = try? Self.normalize(prefix) else {
            return false
        }
        // The policy layer has no trusted proof of the workspace volume's case
        // semantics. Exact NFC spelling is therefore required. This is correct
        // on case-sensitive volumes and safely under-authorizes on a
        // case-insensitive volume instead of allowing a case-folded prefix to
        // reach a distinct object on a case-sensitive one.
        if normalizedPrefix.isEmpty { return true }
        return path == normalizedPrefix
            || path.hasPrefix(normalizedPrefix + "/")
    }

    func isWithinDeniedPrefix(_ prefix: String) -> Bool {
        guard let normalizedPrefix = try? Self.normalize(prefix) else {
            return true
        }
        let targetKey = Self.comparisonKey(path)
        let prefixKey = Self.comparisonKey(normalizedPrefix)
        if prefixKey.isEmpty { return true }
        return targetKey == prefixKey
            || targetKey.hasPrefix(prefixKey + "/")
    }

    public static func canonicalize(
        _ targets: [ToolTarget]
    ) throws -> [NormalizedToolTarget] {
        try canonicalize(targets.map(NormalizedToolTarget.init))
    }

    public static func canonicalize(
        _ targets: [NormalizedToolTarget]
    ) throws -> [NormalizedToolTarget] {
        let ordered = targets.sorted(by: canonicalOrder)
        for pair in zip(ordered, ordered.dropFirst()) {
            let lhsKey = comparisonKey(pair.0.path)
            let rhsKey = comparisonKey(pair.1.path)
            guard lhsKey == rhsKey else { continue }
            if pair.0.path != pair.1.path {
                throw NormalizedToolTargetError.ambiguousCaseCollision(
                    pair.0.path,
                    pair.1.path
                )
            }
            if pair.0.access == pair.1.access {
                throw NormalizedToolTargetError.duplicate(pair.0)
            }
        }
        return ordered
    }

    static func canonicalOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsKey = comparisonKey(lhs.path)
        let rhsKey = comparisonKey(rhs.path)
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.access.rawValue < rhs.access.rawValue
    }

    static func comparisonKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func normalize(_ raw: String) throws -> String {
        guard raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw NormalizedToolTargetError.surroundingWhitespace
        }
        guard raw.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
                && $0.properties.generalCategory != .format
        }) else {
            throw NormalizedToolTargetError.controlCharacter
        }

        let replaced = raw
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\", with: "/")
        // Validate after separator normalization as well. Otherwise a
        // Windows-style rooted path such as `\\private\\secret` loses its
        // leading separator when the components are joined and is mistaken
        // for a workspace-relative path.
        guard !replaced.hasPrefix("/") else {
            throw NormalizedToolTargetError.absolutePath
        }
        if replaced.utf8.count >= 2 {
            let bytes = Array(replaced.utf8.prefix(2))
            let isDriveLetter = (65 ... 90).contains(bytes[0])
                || (97 ... 122).contains(bytes[0])
            if isDriveLetter, bytes[1] == 58 {
                throw NormalizedToolTargetError.absolutePath
            }
        }

        var components: [String] = []
        for substring in replaced.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            let component = String(substring)
            guard component == component.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) else {
                throw NormalizedToolTargetError.componentWhitespace(component)
            }
            guard component != "." else {
                throw NormalizedToolTargetError.currentDirectoryComponent
            }
            guard component != ".." else {
                throw NormalizedToolTargetError.parentTraversal
            }
            components.append(component)
        }
        return components.joined(separator: "/")
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case access
    }

    static func canonicalizePrefixes(_ values: [String]) throws -> [String] {
        let unique = Set(try values.map {
            try NormalizedToolTarget(path: $0, access: .inspect)
        })
        return try canonicalize(Array(unique)).map(\.path)
    }
}

public enum NormalizedToolTargetError: Error, Equatable, Sendable {
    case controlCharacter
    case surroundingWhitespace
    case componentWhitespace(String)
    case absolutePath
    case currentDirectoryComponent
    case parentTraversal
    case duplicate(NormalizedToolTarget)
    case ambiguousCaseCollision(String, String)
    case nonCanonicalEncoding(String)
}

public enum TargetResolutionDisposition: String, Codable, Sendable {
    case existingObject
    case creatableDestination
}

/// Object type observed from an already-opened descriptor. Device, inode, and
/// link count below must come from the same `fstat` result; path text alone is
/// not trusted object identity.
public enum ResolvedTargetObjectKind: String, Codable, Sendable {
    case regularFile
    case directory
    case other
    case absent
}

/// Durable diagnostic evidence. This value is deliberately not executable
/// authority; only `ResolvedInvocationTargets` and `WorkspaceExecutionLease`
/// can cross the policy/executor boundary.
public struct ResolvedToolTargetSnapshot: Codable, Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let target: NormalizedToolTarget
    public let resolvedRelativePath: String
    public let disposition: TargetResolutionDisposition
    public let workspaceRootIdentity: String
    public let containmentIdentity: String
    public let objectKind: ResolvedTargetObjectKind
    public let objectDevice: UInt64?
    public let objectInode: UInt64?
    public let objectLinkCount: UInt64?
    public let resolutionRevision: String
    public let traversedSymlink: Bool
    public let resolutionSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let workspaceID: WorkspaceID
        let target: NormalizedToolTarget
        let resolvedRelativePath: String
        let disposition: TargetResolutionDisposition
        let workspaceRootIdentity: String
        let containmentIdentity: String
        let objectKind: ResolvedTargetObjectKind
        let objectDevice: UInt64?
        let objectInode: UInt64?
        let objectLinkCount: UInt64?
        let resolutionRevision: String
        let traversedSymlink: Bool
    }

    public static func make(
        workspaceID: WorkspaceID,
        target: NormalizedToolTarget,
        resolvedRelativePath: String,
        disposition: TargetResolutionDisposition,
        workspaceRootIdentity: String,
        containmentIdentity: String,
        objectKind: ResolvedTargetObjectKind,
        objectDevice: UInt64?,
        objectInode: UInt64?,
        objectLinkCount: UInt64?,
        resolutionRevision: String,
        traversedSymlink: Bool
    ) throws -> Self {
        let resolved = try NormalizedToolTarget(
            path: resolvedRelativePath,
            access: target.access
        ).path
        let root = try validatedToken(
            workspaceRootIdentity,
            field: .workspaceRootIdentity
        )
        let containment = try validatedToken(
            containmentIdentity,
            field: .containmentIdentity
        )
        let revision = try validatedToken(
            resolutionRevision,
            field: .resolutionRevision
        )
        switch disposition {
        case .existingObject:
            guard objectKind != .absent,
                  objectDevice != nil,
                  objectInode != nil,
                  let objectLinkCount,
                  objectLinkCount > 0
            else {
                throw ResolvedToolTargetValidationError.invalidObjectEvidence
            }
            guard objectKind != .regularFile || objectLinkCount == 1 else {
                throw ResolvedToolTargetValidationError.multiplyLinkedRegularFile
            }
        case .creatableDestination:
            guard objectKind == .absent,
                  objectDevice == nil,
                  objectInode == nil,
                  objectLinkCount == nil
            else {
                throw ResolvedToolTargetValidationError.invalidObjectEvidence
            }
        }
        let material = DigestMaterial(
            workspaceID: workspaceID,
            target: target,
            resolvedRelativePath: resolved,
            disposition: disposition,
            workspaceRootIdentity: root,
            containmentIdentity: containment,
            objectKind: objectKind,
            objectDevice: objectDevice,
            objectInode: objectInode,
            objectLinkCount: objectLinkCount,
            resolutionRevision: revision,
            traversedSymlink: traversedSymlink
        )
        return Self(
            workspaceID: workspaceID,
            target: target,
            resolvedRelativePath: resolved,
            disposition: disposition,
            workspaceRootIdentity: root,
            containmentIdentity: containment,
            objectKind: objectKind,
            objectDevice: objectDevice,
            objectInode: objectInode,
            objectLinkCount: objectLinkCount,
            resolutionRevision: revision,
            traversedSymlink: traversedSymlink,
            resolutionSHA256: try PolicyCanonicalDigest.sha256(
                domain: .targetResolution,
                material
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rebuilt = try Self.make(
            workspaceID: container.decode(WorkspaceID.self, forKey: .workspaceID),
            target: container.decode(NormalizedToolTarget.self, forKey: .target),
            resolvedRelativePath: container.decode(
                String.self,
                forKey: .resolvedRelativePath
            ),
            disposition: container.decode(
                TargetResolutionDisposition.self,
                forKey: .disposition
            ),
            workspaceRootIdentity: container.decode(
                String.self,
                forKey: .workspaceRootIdentity
            ),
            containmentIdentity: container.decode(
                String.self,
                forKey: .containmentIdentity
            ),
            objectKind: container.decode(
                ResolvedTargetObjectKind.self,
                forKey: .objectKind
            ),
            objectDevice: container.decodeIfPresent(
                UInt64.self,
                forKey: .objectDevice
            ),
            objectInode: container.decodeIfPresent(
                UInt64.self,
                forKey: .objectInode
            ),
            objectLinkCount: container.decodeIfPresent(
                UInt64.self,
                forKey: .objectLinkCount
            ),
            resolutionRevision: container.decode(
                String.self,
                forKey: .resolutionRevision
            ),
            traversedSymlink: container.decode(
                Bool.self,
                forKey: .traversedSymlink
            )
        )
        guard rebuilt.resolutionSHA256 == (try container.decode(
            SHA256Digest.self,
            forKey: .resolutionSHA256
        )) else {
            throw ResolvedToolTargetValidationError.digestMismatch
        }
        self = rebuilt
    }

    private init(
        workspaceID: WorkspaceID,
        target: NormalizedToolTarget,
        resolvedRelativePath: String,
        disposition: TargetResolutionDisposition,
        workspaceRootIdentity: String,
        containmentIdentity: String,
        objectKind: ResolvedTargetObjectKind,
        objectDevice: UInt64?,
        objectInode: UInt64?,
        objectLinkCount: UInt64?,
        resolutionRevision: String,
        traversedSymlink: Bool,
        resolutionSHA256: SHA256Digest
    ) {
        self.workspaceID = workspaceID
        self.target = target
        self.resolvedRelativePath = resolvedRelativePath
        self.disposition = disposition
        self.workspaceRootIdentity = workspaceRootIdentity
        self.containmentIdentity = containmentIdentity
        self.objectKind = objectKind
        self.objectDevice = objectDevice
        self.objectInode = objectInode
        self.objectLinkCount = objectLinkCount
        self.resolutionRevision = resolutionRevision
        self.traversedSymlink = traversedSymlink
        self.resolutionSHA256 = resolutionSHA256
    }

    func isCanonical() -> Bool {
        (try? Self.make(
            workspaceID: workspaceID,
            target: target,
            resolvedRelativePath: resolvedRelativePath,
            disposition: disposition,
            workspaceRootIdentity: workspaceRootIdentity,
            containmentIdentity: containmentIdentity,
            objectKind: objectKind,
            objectDevice: objectDevice,
            objectInode: objectInode,
            objectLinkCount: objectLinkCount,
            resolutionRevision: resolutionRevision,
            traversedSymlink: traversedSymlink
        )) == self
    }

    private static func validatedToken(
        _ value: String,
        field: ResolvedToolTargetTokenField
    ) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 1_024,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && $0.properties.generalCategory != .format
              })
        else {
            throw ResolvedToolTargetValidationError.invalidToken(field)
        }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceID
        case target
        case resolvedRelativePath
        case disposition
        case workspaceRootIdentity
        case containmentIdentity
        case objectKind
        case objectDevice
        case objectInode
        case objectLinkCount
        case resolutionRevision
        case traversedSymlink
        case resolutionSHA256
    }
}

public enum ResolvedToolTargetTokenField: String, Codable, Sendable {
    case workspaceRootIdentity
    case containmentIdentity
    case resolutionRevision
    case workspaceRevision
}

public enum ResolvedToolTargetValidationError: Error, Equatable, Sendable {
    case invalidToken(ResolvedToolTargetTokenField)
    case invalidObjectEvidence
    case multiplyLinkedRegularFile
    case digestMismatch
}

public struct ApprovalPrecondition: Codable, Equatable, Sendable {
    public let resolution: ResolvedToolTargetSnapshot
    public let previewSHA256: SHA256Digest

    public init(
        resolution: ResolvedToolTargetSnapshot,
        previewSHA256: SHA256Digest
    ) {
        self.resolution = resolution
        self.previewSHA256 = previewSHA256
    }
}

/// The only caller-extensible filesystem boundary. The application installs
/// one trusted backend in its composition root. Request callers never supply
/// paths, command parse results, previews, or revisions to policy APIs.
public protocol WorkspaceTargetResolutionBackend: Sendable {
    func resolveTargets(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        workspaceID: WorkspaceID
    ) async throws -> WorkspaceResolutionCandidate
}

public struct WorkspaceResolutionCandidate: Equatable, Sendable {
    public let preconditions: [ApprovalPrecondition]
    public let workspaceRevision: String

    public init(
        preconditions: [ApprovalPrecondition],
        workspaceRevision: String
    ) throws {
        let revision = try Self.validatedRevision(workspaceRevision)
        let ordered = preconditions.sorted {
            NormalizedToolTarget.canonicalOrder(
                $0.resolution.target,
                $1.resolution.target
            )
        }
        for condition in ordered where !condition.resolution.isCanonical() {
            throw WorkspaceTargetAuthorityError.invalidResolutionEvidence
        }
        for pair in zip(ordered, ordered.dropFirst())
        where pair.0.resolution.target == pair.1.resolution.target {
            throw WorkspaceTargetAuthorityError.duplicateTarget(
                pair.0.resolution.target
            )
        }
        var containmentOwners: [String: NormalizedToolTarget] = [:]
        var objectOwners: [ResolvedObjectIdentity: NormalizedToolTarget] = [:]
        for condition in ordered {
            let snapshot = condition.resolution
            if let owner = containmentOwners[snapshot.containmentIdentity],
               owner != snapshot.target {
                throw WorkspaceTargetAuthorityError.resolvedObjectCollision
            }
            containmentOwners[snapshot.containmentIdentity] = snapshot.target
            if let device = snapshot.objectDevice,
               let inode = snapshot.objectInode {
                let identity = ResolvedObjectIdentity(
                    device: device,
                    inode: inode
                )
                if let owner = objectOwners[identity], owner != snapshot.target {
                    throw WorkspaceTargetAuthorityError.resolvedObjectCollision
                }
                objectOwners[identity] = snapshot.target
            }
        }
        self.preconditions = ordered
        self.workspaceRevision = revision
    }

    private static func validatedRevision(_ value: String) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 1_024,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && $0.properties.generalCategory != .format
              })
        else {
            throw ResolvedToolTargetValidationError.invalidToken(
                .workspaceRevision
            )
        }
        return value
    }
}

private struct ResolvedObjectIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

/// Opaque, non-Codable authority over one resolver-produced target set.
public struct ResolvedInvocationTargets: Sendable {
    public let workspaceID: WorkspaceID
    public let logicalTargets: [NormalizedToolTarget]
    public let resolvedTargets: [NormalizedToolTarget]
    public let preconditions: [ApprovalPrecondition]
    public let workspaceRevision: String
    public let requestBindingSHA256: SHA256Digest
    public let attestationSHA256: SHA256Digest

    fileprivate let authorityID: UUID
    fileprivate let descriptor: ToolDescriptor
    fileprivate let invocation: ToolInvocation

    fileprivate init(
        workspaceID: WorkspaceID,
        logicalTargets: [NormalizedToolTarget],
        resolvedTargets: [NormalizedToolTarget],
        preconditions: [ApprovalPrecondition],
        workspaceRevision: String,
        requestBindingSHA256: SHA256Digest,
        attestationSHA256: SHA256Digest,
        authorityID: UUID,
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) {
        self.workspaceID = workspaceID
        self.logicalTargets = logicalTargets
        self.resolvedTargets = resolvedTargets
        self.preconditions = preconditions
        self.workspaceRevision = workspaceRevision
        self.requestBindingSHA256 = requestBindingSHA256
        self.attestationSHA256 = attestationSHA256
        self.authorityID = authorityID
        self.descriptor = descriptor
        self.invocation = invocation
    }
}

/// Fresh opaque proof returned only after the configured resolver reproduced
/// the exact attested paths, symlink containment, previews, and revision.
public struct WorkspaceExecutionLease: Sendable {
    public let workspaceID: WorkspaceID
    public let resolvedTargets: [NormalizedToolTarget]
    public let resolutionAttestationSHA256: SHA256Digest
    public let workspaceRevision: String

    fileprivate let authorityID: UUID

    fileprivate init(attestation: ResolvedInvocationTargets) {
        workspaceID = attestation.workspaceID
        resolvedTargets = attestation.resolvedTargets
        resolutionAttestationSHA256 = attestation.attestationSHA256
        workspaceRevision = attestation.workspaceRevision
        authorityID = attestation.authorityID
    }
}

public enum WorkspaceTargetAuthorityError: Error, Equatable, Sendable {
    case untrustedDescriptor(ToolIdentity)
    case descriptorInvocationMismatch
    case argumentDigestMismatch
    case invalidResolutionEvidence
    case workspaceMismatch
    case declaredTargetMismatch
    case commandTargetsMissing
    case duplicateTarget(NormalizedToolTarget)
    case resolvedTargetCollision
    case resolvedObjectCollision
    case wrongAuthority
    case staleResolutionOrPreview
}

public final actor WorkspaceTargetResolverAuthority {
    private struct RequestBinding: Codable {
        let workspaceID: WorkspaceID
        let callID: ToolCallID
        let modelAttemptID: AttemptID
        let tool: ToolIdentity
        let argumentSHA256: SHA256Digest
        let idempotencyKey: String
    }

    private struct AttestationMaterial: Codable {
        let requestBindingSHA256: SHA256Digest
        let logicalTargets: [NormalizedToolTarget]
        let resolvedTargets: [NormalizedToolTarget]
        let preconditions: [ApprovalPrecondition]
        let workspaceRevision: String
    }

    private let backend: any WorkspaceTargetResolutionBackend
    private let authorityID = UUID()

    public init(trustedBackend: any WorkspaceTargetResolutionBackend) {
        backend = trustedBackend
    }

    public func resolve(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        workspaceID: WorkspaceID
    ) async throws -> ResolvedInvocationTargets {
        guard MutationEffectContractCatalog.canonicalDescriptor(
            for: descriptor.identity
        ) == descriptor else {
            throw WorkspaceTargetAuthorityError.untrustedDescriptor(
                descriptor.identity
            )
        }
        guard descriptor.identity == invocation.tool,
              descriptor.effectClass == invocation.effectClass
        else {
            throw WorkspaceTargetAuthorityError.descriptorInvocationMismatch
        }
        let canonicalArgumentDigest = try descriptor.canonicalArgumentDigest(
            for: invocation.arguments
        )
        guard canonicalArgumentDigest == invocation.canonicalArgumentDigest,
              let argumentSHA256 = try? SHA256Digest(canonicalArgumentDigest)
        else {
            throw WorkspaceTargetAuthorityError.argumentDigestMismatch
        }

        let declared: [NormalizedToolTarget]?
        switch descriptor.targetStrategy {
        case .legacyCommandParserRequired:
            declared = nil
        case .workspaceRoot, .argumentPaths, .arrayArgumentPaths:
            declared = try NormalizedToolTarget.canonicalize(
                descriptor.extractTargets(from: invocation.arguments)
            )
        }

        let candidate = try await backend.resolveTargets(
            descriptor: descriptor,
            invocation: invocation,
            workspaceID: workspaceID
        )
        let logical = candidate.preconditions.map(\.resolution.target)
        guard candidate.preconditions.allSatisfy({
            $0.resolution.workspaceID == workspaceID
        }) else {
            throw WorkspaceTargetAuthorityError.workspaceMismatch
        }
        if let declared {
            guard logical == declared else {
                throw WorkspaceTargetAuthorityError.declaredTargetMismatch
            }
        } else if logical.isEmpty {
            throw WorkspaceTargetAuthorityError.commandTargetsMissing
        }

        let resolvedCandidates = try candidate.preconditions.map {
            try NormalizedToolTarget(
                path: $0.resolution.resolvedRelativePath,
                access: $0.resolution.target.access
            )
        }
        let resolved = try NormalizedToolTarget.canonicalize(
            resolvedCandidates
        )
        let resolvedPathKeys = Set(resolved.map {
            NormalizedToolTarget.comparisonKey($0.path)
        })
        guard resolvedPathKeys.count == resolved.count else {
            throw WorkspaceTargetAuthorityError.resolvedTargetCollision
        }

        let requestBinding = try PolicyCanonicalDigest.sha256(
            domain: .targetResolutionRequest,
            RequestBinding(
                workspaceID: workspaceID,
                callID: invocation.callID,
                modelAttemptID: invocation.modelAttemptID,
                tool: invocation.tool,
                argumentSHA256: argumentSHA256,
                idempotencyKey: invocation.idempotencyKey
            )
        )
        let attestationDigest = try PolicyCanonicalDigest.sha256(
            domain: .targetResolutionAttestation,
            AttestationMaterial(
                requestBindingSHA256: requestBinding,
                logicalTargets: logical,
                resolvedTargets: resolved,
                preconditions: candidate.preconditions,
                workspaceRevision: candidate.workspaceRevision
            )
        )
        return ResolvedInvocationTargets(
            workspaceID: workspaceID,
            logicalTargets: logical,
            resolvedTargets: resolved,
            preconditions: candidate.preconditions,
            workspaceRevision: candidate.workspaceRevision,
            requestBindingSHA256: requestBinding,
            attestationSHA256: attestationDigest,
            authorityID: authorityID,
            descriptor: descriptor,
            invocation: invocation
        )
    }

    public func revalidate(
        _ attestation: ResolvedInvocationTargets
    ) async throws -> WorkspaceExecutionLease {
        guard attestation.authorityID == authorityID else {
            throw WorkspaceTargetAuthorityError.wrongAuthority
        }
        let fresh = try await resolve(
            descriptor: attestation.descriptor,
            invocation: attestation.invocation,
            workspaceID: attestation.workspaceID
        )
        guard fresh.requestBindingSHA256 == attestation.requestBindingSHA256,
              fresh.attestationSHA256 == attestation.attestationSHA256,
              fresh.logicalTargets == attestation.logicalTargets,
              fresh.resolvedTargets == attestation.resolvedTargets,
              fresh.preconditions == attestation.preconditions,
              fresh.workspaceRevision == attestation.workspaceRevision
        else {
            throw WorkspaceTargetAuthorityError.staleResolutionOrPreview
        }
        return WorkspaceExecutionLease(attestation: fresh)
    }

    public func revalidateForExecution(
        _ lease: WorkspaceExecutionLease,
        against attestation: ResolvedInvocationTargets
    ) async throws -> WorkspaceExecutionLease {
        guard lease.authorityID == authorityID,
              attestation.authorityID == authorityID,
              lease.resolutionAttestationSHA256 == attestation.attestationSHA256
        else {
            throw WorkspaceTargetAuthorityError.wrongAuthority
        }
        return try await revalidate(attestation)
    }
}
