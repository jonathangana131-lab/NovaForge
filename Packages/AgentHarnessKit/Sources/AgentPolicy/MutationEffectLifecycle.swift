import AgentDomain
import Foundation

/// Durable lifecycle phases for one claimed mutation effect.
///
/// `pending` is intentionally ambiguous after process loss: the effect may
/// have crossed its external side-effect boundary before the application
/// receipt was committed. Recovery must never turn it back into executable
/// work. `needsReconciliation` is therefore terminal for this authority; a
/// later, separately authorized reconciliation system may record a new fact,
/// but this package never remints execution authority from it.
public enum MutationEffectPhase: String, Codable, CaseIterable, Sendable {
    case pending
    case applied
    case evidence
    case needsReconciliation
}

public enum MutationEffectReconciliationReason: String, Codable, Sendable {
    case ambiguousPendingAfterRecovery
    case effectThrewAfterPending
    case effectCancelledAfterPending
    case applicationCommitFailed
    case evidenceCommitFailed
    case clockUnavailableAfterPending
    case targetRevalidationFailedAfterPending
    case corruptOrConflictingState
}

public enum MutationEffectLifecycleError: Error, Equatable, Sendable {
    case invalidPermitBinding
    case invalidToken
    case emptyEvidence
    case duplicateEvidence
    case invalidEvidenceSchema
    case corruptEvidence
    case invalidOutputSchema
    case outputTooLarge
    case recordNotFound(SHA256Digest)
    case recordConflict(SHA256Digest)
    case staleRecord(expected: SHA256Digest, actual: SHA256Digest)
    case invalidInitialPhase(MutationEffectPhase)
    case invalidTransition(from: MutationEffectPhase, to: MutationEffectPhase)
    case duplicateApplication
    case duplicateEvidenceSettlement
    case reconciliationRequired
    case transitionFailed
}

public enum MutationEffectOutputKind: String, Codable, CaseIterable, Sendable {
    case writeFile = "write_file"
    case appendFile = "append_file"
    case replaceText = "replace_text"
    case deletePath = "delete_path"
    case movePath = "move_path"
    case copyPath = "copy_path"
    case makeDirectory = "make_directory"
    case runCommand = "run_command"
    case createFile = "create_file"
    case touchFile = "touch_file"
    case resetWorkspace = "reset_workspace"
    case seedWorkspace = "seed_workspace"
}

public enum MutationEffectOutputPresentationClassification:
    String, Codable, Sendable
{
    case unclassified
}

/// Durable, unclassified result returned by the trusted effect backend.
/// Bounds, structural escaping, and digest verification provide storage
/// integrity only: summary/text may still contain paths, command output,
/// credentials, or other secrets. Never send this value directly to UI or
/// accessibility; first cross a separate sanitizer/public-copy boundary.
public struct MutationEffectOutput: Codable, Equatable, Sendable {
    public static let presentationClassification:
        MutationEffectOutputPresentationClassification = .unclassified
    public static let maximumSummaryUTF8Bytes = 1_024
    public static let maximumTextUTF8Bytes = 30_000
    public static let maximumTargets = 128
    public static let maximumEncodedUTF8Bytes = 65_536

    public let kind: MutationEffectOutputKind
    public let summary: String
    public let originalSummaryUTF8ByteCount: Int
    public let summaryWasTruncated: Bool
    public let targets: [NormalizedToolTarget]
    public let text: String?
    public let originalTextUTF8ByteCount: Int
    public let textWasTruncated: Bool
    public let commandExitCode: Int?
    public let outputSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let kind: MutationEffectOutputKind
        let summary: String
        let originalSummaryUTF8ByteCount: Int
        let summaryWasTruncated: Bool
        let targets: [NormalizedToolTarget]
        let text: String?
        let originalTextUTF8ByteCount: Int
        let textWasTruncated: Bool
        let commandExitCode: Int?
    }

    public init(
        kind: MutationEffectOutputKind,
        summary: String,
        targets: [NormalizedToolTarget] = [],
        text: String? = nil,
        commandExitCode: Int? = nil
    ) throws {
        let boundedSummary = Self.boundedVisibleText(
            summary,
            maximumUTF8Bytes: Self.maximumSummaryUTF8Bytes
        )
        let boundedText = text.map {
            Self.boundedVisibleText(
                $0,
                maximumUTF8Bytes: Self.maximumTextUTF8Bytes
            )
        }
        let material = try Self.material(
            kind: kind,
            summary: boundedSummary.value,
            originalSummaryUTF8ByteCount: boundedSummary.originalUTF8Bytes,
            summaryWasTruncated: boundedSummary.wasTruncated,
            targets: targets,
            text: boundedText?.value,
            originalTextUTF8ByteCount: boundedText?.originalUTF8Bytes ?? 0,
            textWasTruncated: boundedText?.wasTruncated ?? false,
            commandExitCode: commandExitCode
        )
        self.init(
            material: material,
            outputSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationOutput,
                material
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let material = try Self.material(
            kind: container.decode(MutationEffectOutputKind.self, forKey: .kind),
            summary: container.decode(String.self, forKey: .summary),
            originalSummaryUTF8ByteCount: container.decode(
                Int.self,
                forKey: .originalSummaryUTF8ByteCount
            ),
            summaryWasTruncated: container.decode(
                Bool.self,
                forKey: .summaryWasTruncated
            ),
            targets: container.decode(
                [NormalizedToolTarget].self,
                forKey: .targets
            ),
            text: container.decodeIfPresent(String.self, forKey: .text),
            originalTextUTF8ByteCount: container.decode(
                Int.self,
                forKey: .originalTextUTF8ByteCount
            ),
            textWasTruncated: container.decode(
                Bool.self,
                forKey: .textWasTruncated
            ),
            commandExitCode: container.decodeIfPresent(
                Int.self,
                forKey: .commandExitCode
            )
        )
        let digest = try PolicyCanonicalDigest.sha256(
            domain: .mutationOutput,
            material
        )
        guard digest == (try container.decode(
            SHA256Digest.self,
            forKey: .outputSHA256
        )) else { throw MutationEffectLifecycleError.corruptEvidence }
        self.init(material: material, outputSHA256: digest)
    }

    private static func material(
        kind: MutationEffectOutputKind,
        summary: String,
        originalSummaryUTF8ByteCount: Int,
        summaryWasTruncated: Bool,
        targets: [NormalizedToolTarget],
        text: String?,
        originalTextUTF8ByteCount: Int,
        textWasTruncated: Bool,
        commandExitCode: Int?
    ) throws -> DigestMaterial {
        let canonicalTargets = try NormalizedToolTarget.canonicalize(targets)
        guard canonicalTargets.count <= maximumTargets,
              !summary.isEmpty,
              summary.utf8.count <= maximumSummaryUTF8Bytes,
              isStructurallyVisible(summary),
              originalSummaryUTF8ByteCount >= summary.utf8.count,
              summaryWasTruncated
                == (originalSummaryUTF8ByteCount > summary.utf8.count),
              text?.utf8.count ?? 0 <= maximumTextUTF8Bytes,
              text.map(isStructurallyVisible) ?? true,
              originalTextUTF8ByteCount >= (text?.utf8.count ?? 0),
              textWasTruncated
                == (originalTextUTF8ByteCount > (text?.utf8.count ?? 0)),
              (text != nil || originalTextUTF8ByteCount == 0),
              (kind == .runCommand) == (commandExitCode != nil)
        else { throw MutationEffectLifecycleError.invalidOutputSchema }
        let material = DigestMaterial(
            kind: kind,
            summary: summary,
            originalSummaryUTF8ByteCount: originalSummaryUTF8ByteCount,
            summaryWasTruncated: summaryWasTruncated,
            targets: canonicalTargets,
            text: text,
            originalTextUTF8ByteCount: originalTextUTF8ByteCount,
            textWasTruncated: textWasTruncated,
            commandExitCode: commandExitCode
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(material).count <= maximumEncodedUTF8Bytes
        else { throw MutationEffectLifecycleError.outputTooLarge }
        return material
    }

    private static func boundedVisibleText(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> (value: String, originalUTF8Bytes: Int, wasTruncated: Bool) {
        var escaped = ""
        for scalar in value.unicodeScalars {
            let category = scalar.properties.generalCategory
            if category == .format
                || category == .control
                || category == .lineSeparator
                || category == .paragraphSeparator {
                escaped += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else if scalar == "\\" {
                escaped += "\\\\"
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        let originalCount = escaped.utf8.count
        guard originalCount > maximumUTF8Bytes else {
            return (escaped, originalCount, false)
        }
        var bounded = ""
        for scalar in escaped.unicodeScalars {
            let candidate = String(scalar)
            guard bounded.utf8.count + candidate.utf8.count
                    <= maximumUTF8Bytes
            else { break }
            bounded.unicodeScalars.append(scalar)
        }
        return (bounded, originalCount, true)
    }

    private static func isStructurallyVisible(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            let category = scalar.properties.generalCategory
            return category != .format
                && category != .control
                && category != .lineSeparator
                && category != .paragraphSeparator
        }
    }

    private init(material: DigestMaterial, outputSHA256: SHA256Digest) {
        kind = material.kind
        summary = material.summary
        originalSummaryUTF8ByteCount = material.originalSummaryUTF8ByteCount
        summaryWasTruncated = material.summaryWasTruncated
        targets = material.targets
        text = material.text
        originalTextUTF8ByteCount = material.originalTextUTF8ByteCount
        textWasTruncated = material.textWasTruncated
        commandExitCode = material.commandExitCode
        self.outputSHA256 = outputSHA256
    }
}

/// Immutable identity copied from a package-minted claimed permit. This is
/// evidence, not authority: decoding or constructing an identical value can
/// never invoke an effect. The executor still requires the move-only claimed
/// permit itself.
public struct MutationEffectBinding: Codable, Equatable, Sendable {
    public let origin: MutationOrigin
    public let effectKeySHA256: SHA256Digest
    public let requestSHA256: SHA256Digest
    public let policySHA256: SHA256Digest
    public let claimSHA256: SHA256Digest
    public let tool: ToolIdentity
    public let effectClass: ToolEffectClass
    public let canonicalArgumentDigest: String
    public let operationPayloadSHA256: SHA256Digest
    public let operationPreviewSHA256: SHA256Digest
    public let callID: ToolCallID
    public let idempotencyKey: String
    public let workspaceID: WorkspaceID
    public let resolutionAttestationSHA256: SHA256Digest
    public let resolvedTargets: [NormalizedToolTarget]
    public let authorizedAt: AgentInstant
    public let expiresAt: AgentInstant
    public let claimedAt: AgentInstant
    public let bindingSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let origin: MutationOrigin
        let effectKeySHA256: SHA256Digest
        let requestSHA256: SHA256Digest
        let policySHA256: SHA256Digest
        let claimSHA256: SHA256Digest
        let tool: ToolIdentity
        let effectClass: ToolEffectClass
        let canonicalArgumentDigest: String
        let operationPayloadSHA256: SHA256Digest
        let operationPreviewSHA256: SHA256Digest
        let callID: ToolCallID
        let idempotencyKey: String
        let workspaceID: WorkspaceID
        let resolutionAttestationSHA256: SHA256Digest
        let resolvedTargets: [NormalizedToolTarget]
        let authorizedAt: AgentInstant
        let expiresAt: AgentInstant
        let claimedAt: AgentInstant
    }

    static func make(
        borrowing permit: borrowing ClaimedToolEffectPermit
    ) throws -> Self {
        let claim = permit.claim
        guard claim.isCanonical(),
              permit.origin == claim.origin,
              permit.effectKeySHA256 == claim.effectKeySHA256,
              permit.requestSHA256 == claim.requestSHA256,
              permit.policySHA256 == claim.policySHA256,
              permit.tool == claim.tool,
              permit.effectClass == claim.effectClass,
              permit.canonicalArgumentDigest
                == claim.canonicalArgumentDigest,
              permit.operationPayloadSHA256
                == claim.operationPayloadSHA256,
              let operationPreviewSHA256 = permit.operationPreviewSHA256,
              operationPreviewSHA256 == claim.operationPreviewSHA256,
              permit.callID == claim.callID,
              permit.idempotencyKey == claim.idempotencyKey,
              permit.workspaceID == claim.workspaceID,
              permit.authorizedAt <= permit.claimedAt,
              permit.claimedAt == claim.claimedAt,
              permit.claimedAt < permit.expiresAt,
              !permit.resolvedTargets.isEmpty,
              permit.resolvedTargets == (try? NormalizedToolTarget.canonicalize(
                  permit.resolvedTargets
              ))
        else { throw MutationEffectLifecycleError.invalidPermitBinding }
        return try make(
            origin: permit.origin,
            effectKeySHA256: permit.effectKeySHA256,
            requestSHA256: claim.requestSHA256,
            policySHA256: claim.policySHA256,
            claimSHA256: claim.claimSHA256,
            tool: permit.tool,
            effectClass: permit.effectClass,
            canonicalArgumentDigest: permit.canonicalArgumentDigest,
            operationPayloadSHA256: permit.operationPayloadSHA256,
            operationPreviewSHA256: operationPreviewSHA256,
            callID: permit.callID,
            idempotencyKey: permit.idempotencyKey,
            workspaceID: permit.workspaceID,
            resolutionAttestationSHA256:
                claim.resolutionAttestationSHA256,
            resolvedTargets: permit.resolvedTargets,
            authorizedAt: permit.authorizedAt,
            expiresAt: permit.expiresAt,
            claimedAt: permit.claimedAt
        )
    }

    private static func make(
        origin: MutationOrigin,
        effectKeySHA256: SHA256Digest,
        requestSHA256: SHA256Digest,
        policySHA256: SHA256Digest,
        claimSHA256: SHA256Digest,
        tool: ToolIdentity,
        effectClass: ToolEffectClass,
        canonicalArgumentDigest: String,
        operationPayloadSHA256: SHA256Digest,
        operationPreviewSHA256: SHA256Digest,
        callID: ToolCallID,
        idempotencyKey: String,
        workspaceID: WorkspaceID,
        resolutionAttestationSHA256: SHA256Digest,
        resolvedTargets: [NormalizedToolTarget],
        authorizedAt: AgentInstant,
        expiresAt: AgentInstant,
        claimedAt: AgentInstant
    ) throws -> Self {
        let token = try validatedToken(idempotencyKey)
        let argumentDigest = try validatedDigestToken(
            canonicalArgumentDigest
        )
        let targets = try NormalizedToolTarget.canonicalize(resolvedTargets)
        guard !targets.isEmpty,
              authorizedAt <= claimedAt,
              claimedAt < expiresAt
        else {
            throw MutationEffectLifecycleError.invalidPermitBinding
        }
        let material = DigestMaterial(
            origin: origin,
            effectKeySHA256: effectKeySHA256,
            requestSHA256: requestSHA256,
            policySHA256: policySHA256,
            claimSHA256: claimSHA256,
            tool: tool,
            effectClass: effectClass,
            canonicalArgumentDigest: argumentDigest,
            operationPayloadSHA256: operationPayloadSHA256,
            operationPreviewSHA256: operationPreviewSHA256,
            callID: callID,
            idempotencyKey: token,
            workspaceID: workspaceID,
            resolutionAttestationSHA256: resolutionAttestationSHA256,
            resolvedTargets: targets,
            authorizedAt: authorizedAt,
            expiresAt: expiresAt,
            claimedAt: claimedAt
        )
        return Self(
            material: material,
            bindingSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationBinding,
                material
            )
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rebuilt = try Self.make(
            origin: container.decode(MutationOrigin.self, forKey: .origin),
            effectKeySHA256: container.decode(
                SHA256Digest.self,
                forKey: .effectKeySHA256
            ),
            requestSHA256: container.decode(
                SHA256Digest.self,
                forKey: .requestSHA256
            ),
            policySHA256: container.decode(
                SHA256Digest.self,
                forKey: .policySHA256
            ),
            claimSHA256: container.decode(
                SHA256Digest.self,
                forKey: .claimSHA256
            ),
            tool: container.decode(ToolIdentity.self, forKey: .tool),
            effectClass: container.decode(
                ToolEffectClass.self,
                forKey: .effectClass
            ),
            canonicalArgumentDigest: container.decode(
                String.self,
                forKey: .canonicalArgumentDigest
            ),
            operationPayloadSHA256: container.decode(
                SHA256Digest.self,
                forKey: .operationPayloadSHA256
            ),
            operationPreviewSHA256: container.decode(
                SHA256Digest.self,
                forKey: .operationPreviewSHA256
            ),
            callID: container.decode(ToolCallID.self, forKey: .callID),
            idempotencyKey: container.decode(
                String.self,
                forKey: .idempotencyKey
            ),
            workspaceID: container.decode(
                WorkspaceID.self,
                forKey: .workspaceID
            ),
            resolutionAttestationSHA256: container.decode(
                SHA256Digest.self,
                forKey: .resolutionAttestationSHA256
            ),
            resolvedTargets: container.decode(
                [NormalizedToolTarget].self,
                forKey: .resolvedTargets
            ),
            authorizedAt: container.decode(
                AgentInstant.self,
                forKey: .authorizedAt
            ),
            expiresAt: container.decode(
                AgentInstant.self,
                forKey: .expiresAt
            ),
            claimedAt: container.decode(
                AgentInstant.self,
                forKey: .claimedAt
            )
        )
        guard rebuilt.bindingSHA256 == (try container.decode(
            SHA256Digest.self,
            forKey: .bindingSHA256
        )) else { throw MutationEffectLifecycleError.corruptEvidence }
        self = rebuilt
    }

    private init(material: DigestMaterial, bindingSHA256: SHA256Digest) {
        origin = material.origin
        effectKeySHA256 = material.effectKeySHA256
        requestSHA256 = material.requestSHA256
        policySHA256 = material.policySHA256
        claimSHA256 = material.claimSHA256
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
        resolvedTargets = material.resolvedTargets
        authorizedAt = material.authorizedAt
        expiresAt = material.expiresAt
        claimedAt = material.claimedAt
        self.bindingSHA256 = bindingSHA256
    }

    func isCanonical() -> Bool {
        guard let rebuilt = try? Self.make(
            origin: origin,
            effectKeySHA256: effectKeySHA256,
            requestSHA256: requestSHA256,
            policySHA256: policySHA256,
            claimSHA256: claimSHA256,
            tool: tool,
            effectClass: effectClass,
            canonicalArgumentDigest: canonicalArgumentDigest,
            operationPayloadSHA256: operationPayloadSHA256,
            operationPreviewSHA256: operationPreviewSHA256,
            callID: callID,
            idempotencyKey: idempotencyKey,
            workspaceID: workspaceID,
            resolutionAttestationSHA256: resolutionAttestationSHA256,
            resolvedTargets: resolvedTargets,
            authorizedAt: authorizedAt,
            expiresAt: expiresAt,
            claimedAt: claimedAt
        ) else { return false }
        return rebuilt == self
    }

    private static func validatedToken(_ value: String) throws -> String {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 1_024,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && $0.properties.generalCategory != .format
              })
        else { throw MutationEffectLifecycleError.invalidToken }
        return value
    }

    private static func validatedDigestToken(_ value: String) throws -> String {
        guard let digest = try? SHA256Digest(value),
              digest.rawValue == value
        else { throw MutationEffectLifecycleError.invalidPermitBinding }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case origin
        case effectKeySHA256
        case requestSHA256
        case policySHA256
        case claimSHA256
        case tool
        case effectClass
        case canonicalArgumentDigest
        case operationPayloadSHA256
        case operationPreviewSHA256
        case callID
        case idempotencyKey
        case workspaceID
        case resolutionAttestationSHA256
        case resolvedTargets
        case authorizedAt
        case expiresAt
        case claimedAt
        case bindingSHA256
    }
}

public enum MutationEffectEvidenceKind: String, Codable, CaseIterable, Sendable {
    case workspaceAfter = "workspace_after"
    case changedPath = "changed_path"
    case deletedPath = "deleted_path"
    case movedPath = "moved_path"
    case copiedPath = "copied_path"
    case createdDirectory = "created_directory"
    case commandTranscript = "command_transcript"
    case commandExit = "command_exit"
}

public struct MutationEffectEvidenceFact: Codable, Equatable, Sendable {
    public let kind: MutationEffectEvidenceKind
    public let targets: [NormalizedToolTarget]
    public let digest: SHA256Digest

    public init(
        kind: MutationEffectEvidenceKind,
        targets: [NormalizedToolTarget] = [],
        digest: SHA256Digest
    ) throws {
        let canonicalTargets = try NormalizedToolTarget.canonicalize(targets)
        let validTargetCount: Bool
        switch kind {
        case .workspaceAfter, .commandTranscript, .commandExit:
            validTargetCount = canonicalTargets.isEmpty
        case .changedPath:
            validTargetCount = (1 ... MutationEffectOutput.maximumTargets)
                .contains(canonicalTargets.count)
        case .deletedPath, .createdDirectory:
            validTargetCount = canonicalTargets.count == 1
        case .movedPath, .copiedPath:
            validTargetCount = canonicalTargets.count == 2
        }
        guard validTargetCount else {
            throw MutationEffectLifecycleError.invalidEvidenceSchema
        }
        self.kind = kind
        self.targets = canonicalTargets
        self.digest = digest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(
                MutationEffectEvidenceKind.self,
                forKey: .kind
            ),
            targets: container.decode(
                [NormalizedToolTarget].self,
                forKey: .targets
            ),
            digest: container.decode(SHA256Digest.self, forKey: .digest)
        )
    }

    private enum CodingKeys: String, CodingKey { case kind, targets, digest }
}

/// The only copyable value an effect implementation returns. It conveys no
/// authority and contains only content-addressed result/evidence facts.
public struct MutationEffectApplicationResult: Equatable, Sendable {
    public let resultSHA256: SHA256Digest
    public let output: MutationEffectOutput
    public let evidence: [MutationEffectEvidenceFact]

    public init(
        resultSHA256: SHA256Digest,
        output: MutationEffectOutput,
        evidence: [MutationEffectEvidenceFact]
    ) throws {
        self.resultSHA256 = resultSHA256
        self.output = output
        self.evidence = try Self.canonicalEvidence(evidence)
    }

    static func canonicalEvidence(
        _ values: [MutationEffectEvidenceFact]
    ) throws -> [MutationEffectEvidenceFact] {
        guard !values.isEmpty else {
            throw MutationEffectLifecycleError.emptyEvidence
        }
        let ordered = values.sorted {
            ($0.kind.rawValue, $0.digest.rawValue)
                < ($1.kind.rawValue, $1.digest.rawValue)
        }
        for pair in zip(ordered, ordered.dropFirst())
        where pair.0.kind == pair.1.kind {
            throw MutationEffectLifecycleError.duplicateEvidence
        }
        return ordered
    }
}

/// Content-addressed output from the trusted checkpoint authority. Both
/// digests must be captured before the durable `pending` barrier is inserted.
/// A checkpoint implementation may describe an irreversible external effect
/// with a reconciliation plan instead of an executable rollback, but it must
/// still bind a concrete plan digest.
public struct MutationEffectCheckpointResult: Equatable, Sendable {
    public let beforeStateSHA256: SHA256Digest
    public let rollbackOrReconciliationPlanSHA256: SHA256Digest

    public init(
        beforeStateSHA256: SHA256Digest,
        rollbackOrReconciliationPlanSHA256: SHA256Digest
    ) {
        self.beforeStateSHA256 = beforeStateSHA256
        self.rollbackOrReconciliationPlanSHA256 =
            rollbackOrReconciliationPlanSHA256
    }
}

public struct MutationEffectPendingRecord: Codable, Equatable, Sendable {
    public let bindingSHA256: SHA256Digest
    public let beforeStateSHA256: SHA256Digest
    public let rollbackOrReconciliationPlanSHA256: SHA256Digest
    public let preparedAt: AgentInstant
    public let pendingSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let bindingSHA256: SHA256Digest
        let beforeStateSHA256: SHA256Digest
        let rollbackOrReconciliationPlanSHA256: SHA256Digest
        let preparedAt: AgentInstant
    }

    static func make(
        binding: MutationEffectBinding,
        checkpoint: MutationEffectCheckpointResult,
        preparedAt: AgentInstant
    ) throws -> Self {
        let material = DigestMaterial(
            bindingSHA256: binding.bindingSHA256,
            beforeStateSHA256: checkpoint.beforeStateSHA256,
            rollbackOrReconciliationPlanSHA256:
                checkpoint.rollbackOrReconciliationPlanSHA256,
            preparedAt: preparedAt
        )
        return Self(
            bindingSHA256: material.bindingSHA256,
            beforeStateSHA256: material.beforeStateSHA256,
            rollbackOrReconciliationPlanSHA256:
                material.rollbackOrReconciliationPlanSHA256,
            preparedAt: material.preparedAt,
            pendingSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationPending,
                material
            )
        )
    }

    func isCanonical(binding: MutationEffectBinding) -> Bool {
        guard bindingSHA256 == binding.bindingSHA256 else { return false }
        return (try? Self.make(
            binding: binding,
            checkpoint: MutationEffectCheckpointResult(
                beforeStateSHA256: beforeStateSHA256,
                rollbackOrReconciliationPlanSHA256:
                    rollbackOrReconciliationPlanSHA256
            ),
            preparedAt: preparedAt
        )) == self
    }
}

public struct MutationEffectApplicationRecord: Codable, Equatable, Sendable {
    public let pendingSHA256: SHA256Digest
    public let resultSHA256: SHA256Digest
    public let output: MutationEffectOutput
    public let proposedEvidence: [MutationEffectEvidenceFact]
    public let appliedAt: AgentInstant
    public let applicationSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let pendingSHA256: SHA256Digest
        let resultSHA256: SHA256Digest
        let output: MutationEffectOutput
        let proposedEvidence: [MutationEffectEvidenceFact]
        let appliedAt: AgentInstant
    }

    static func make(
        pending: MutationEffectPendingRecord,
        result: MutationEffectApplicationResult,
        appliedAt: AgentInstant
    ) throws -> Self {
        let facts = try MutationEffectApplicationResult.canonicalEvidence(
            result.evidence
        )
        let material = DigestMaterial(
            pendingSHA256: pending.pendingSHA256,
            resultSHA256: result.resultSHA256,
            output: result.output,
            proposedEvidence: facts,
            appliedAt: appliedAt
        )
        return Self(
            pendingSHA256: material.pendingSHA256,
            resultSHA256: material.resultSHA256,
            output: material.output,
            proposedEvidence: material.proposedEvidence,
            appliedAt: material.appliedAt,
            applicationSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationApplication,
                material
            )
        )
    }

    func isCanonical(pending: MutationEffectPendingRecord) -> Bool {
        guard pendingSHA256 == pending.pendingSHA256,
              let result = try? MutationEffectApplicationResult(
                  resultSHA256: resultSHA256,
                  output: output,
                  evidence: proposedEvidence
              )
        else { return false }
        return (try? Self.make(
            pending: pending,
            result: result,
            appliedAt: appliedAt
        )) == self
    }
}

public struct MutationEffectEvidenceRecord: Codable, Equatable, Sendable {
    public let applicationSHA256: SHA256Digest
    public let facts: [MutationEffectEvidenceFact]
    public let recordedAt: AgentInstant
    public let evidenceSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let applicationSHA256: SHA256Digest
        let facts: [MutationEffectEvidenceFact]
        let recordedAt: AgentInstant
    }

    static func make(
        application: MutationEffectApplicationRecord,
        recordedAt: AgentInstant
    ) throws -> Self {
        let facts = try MutationEffectApplicationResult.canonicalEvidence(
            application.proposedEvidence
        )
        let material = DigestMaterial(
            applicationSHA256: application.applicationSHA256,
            facts: facts,
            recordedAt: recordedAt
        )
        return Self(
            applicationSHA256: material.applicationSHA256,
            facts: material.facts,
            recordedAt: material.recordedAt,
            evidenceSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationEvidence,
                material
            )
        )
    }

    func isCanonical(application: MutationEffectApplicationRecord) -> Bool {
        guard applicationSHA256 == application.applicationSHA256,
              facts == application.proposedEvidence
        else { return false }
        return (try? Self.make(
            application: application,
            recordedAt: recordedAt
        )) == self
    }
}

public struct MutationEffectReconciliationRecord:
    Codable,
    Equatable,
    Sendable
{
    public let priorRecordSHA256: SHA256Digest
    public let reason: MutationEffectReconciliationReason
    public let markedAt: AgentInstant
    public let reconciliationSHA256: SHA256Digest

    private struct DigestMaterial: Codable {
        let priorRecordSHA256: SHA256Digest
        let reason: MutationEffectReconciliationReason
        let markedAt: AgentInstant
    }

    static func make(
        priorRecordSHA256: SHA256Digest,
        reason: MutationEffectReconciliationReason,
        markedAt: AgentInstant
    ) throws -> Self {
        let material = DigestMaterial(
            priorRecordSHA256: priorRecordSHA256,
            reason: reason,
            markedAt: markedAt
        )
        return Self(
            priorRecordSHA256: priorRecordSHA256,
            reason: reason,
            markedAt: markedAt,
            reconciliationSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationReconciliation,
                material
            )
        )
    }

    func isCanonical() -> Bool {
        (try? Self.make(
            priorRecordSHA256: priorRecordSHA256,
            reason: reason,
            markedAt: markedAt
        )) == self
    }
}

public enum MutationEffectState: Codable, Equatable, Sendable {
    case pending(MutationEffectPendingRecord)
    case applied(
        pending: MutationEffectPendingRecord,
        application: MutationEffectApplicationRecord
    )
    case evidence(
        pending: MutationEffectPendingRecord,
        application: MutationEffectApplicationRecord,
        evidence: MutationEffectEvidenceRecord
    )
    case needsReconciliation(
        pending: MutationEffectPendingRecord,
        application: MutationEffectApplicationRecord?,
        reconciliation: MutationEffectReconciliationRecord
    )

    public var phase: MutationEffectPhase {
        switch self {
        case .pending: .pending
        case .applied: .applied
        case .evidence: .evidence
        case .needsReconciliation: .needsReconciliation
        }
    }
}

public struct MutationEffectRecord: Codable, Equatable, Sendable {
    public let binding: MutationEffectBinding
    public let revision: UInt64
    public let state: MutationEffectState
    public let recordSHA256: SHA256Digest

    public var effectKeySHA256: SHA256Digest {
        binding.effectKeySHA256
    }

    public var phase: MutationEffectPhase { state.phase }

    private struct DigestMaterial: Codable {
        let binding: MutationEffectBinding
        let revision: UInt64
        let state: MutationEffectState
    }

    static func pending(
        binding: MutationEffectBinding,
        checkpoint: MutationEffectCheckpointResult,
        preparedAt: AgentInstant
    ) throws -> Self {
        try make(
            binding: binding,
            revision: 1,
            state: .pending(try MutationEffectPendingRecord.make(
                binding: binding,
                checkpoint: checkpoint,
                preparedAt: preparedAt
            ))
        )
    }

    func applying(
        _ result: MutationEffectApplicationResult,
        at appliedAt: AgentInstant
    ) throws -> Self {
        guard case let .pending(pending) = state else {
            if phase == .applied || phase == .evidence {
                throw MutationEffectLifecycleError.duplicateApplication
            }
            throw MutationEffectLifecycleError.invalidTransition(
                from: phase,
                to: .applied
            )
        }
        return try next(.applied(
            pending: pending,
            application: try MutationEffectApplicationRecord.make(
                pending: pending,
                result: result,
                appliedAt: appliedAt
            )
        ))
    }

    func settlingEvidence(at recordedAt: AgentInstant) throws -> Self {
        guard case let .applied(pending, application) = state else {
            if phase == .evidence {
                throw MutationEffectLifecycleError.duplicateEvidenceSettlement
            }
            throw MutationEffectLifecycleError.invalidTransition(
                from: phase,
                to: .evidence
            )
        }
        return try next(.evidence(
            pending: pending,
            application: application,
            evidence: try MutationEffectEvidenceRecord.make(
                application: application,
                recordedAt: recordedAt
            )
        ))
    }

    func requiringReconciliation(
        _ reason: MutationEffectReconciliationReason,
        at markedAt: AgentInstant
    ) throws -> Self {
        let pending: MutationEffectPendingRecord
        let application: MutationEffectApplicationRecord?
        switch state {
        case let .pending(value):
            pending = value
            application = nil
        case let .applied(value, applied):
            pending = value
            application = applied
        case .evidence:
            throw MutationEffectLifecycleError.invalidTransition(
                from: .evidence,
                to: .needsReconciliation
            )
        case .needsReconciliation:
            throw MutationEffectLifecycleError.reconciliationRequired
        }
        return try next(.needsReconciliation(
            pending: pending,
            application: application,
            reconciliation: try MutationEffectReconciliationRecord.make(
                priorRecordSHA256: recordSHA256,
                reason: reason,
                markedAt: markedAt
            )
        ))
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rebuilt = try Self.make(
            binding: container.decode(
                MutationEffectBinding.self,
                forKey: .binding
            ),
            revision: container.decode(UInt64.self, forKey: .revision),
            state: container.decode(MutationEffectState.self, forKey: .state)
        )
        guard rebuilt.recordSHA256 == (try container.decode(
            SHA256Digest.self,
            forKey: .recordSHA256
        )) else { throw MutationEffectLifecycleError.corruptEvidence }
        self = rebuilt
    }

    func isCanonical() -> Bool {
        guard let rebuilt = try? Self.make(
            binding: binding,
            revision: revision,
            state: state
        ) else { return false }
        return rebuilt == self
    }

    static func validateTransition(
        from current: Self,
        to next: Self
    ) throws {
        guard current.isCanonical(), next.isCanonical() else {
            throw MutationEffectLifecycleError.corruptEvidence
        }
        guard current.binding == next.binding else {
            throw MutationEffectLifecycleError.recordConflict(
                current.effectKeySHA256
            )
        }
        guard current.revision < UInt64.max,
              next.revision == current.revision + 1
        else {
            throw MutationEffectLifecycleError.invalidTransition(
                from: current.phase,
                to: next.phase
            )
        }
        let preservesExactLineage: Bool
        switch (current.state, next.state) {
        case let (
            .pending(currentPending),
            .applied(nextPending, _)
        ):
            preservesExactLineage = nextPending == currentPending
        case let (
            .pending(currentPending),
            .needsReconciliation(nextPending, nextApplication, reconciliation)
        ):
            preservesExactLineage = nextPending == currentPending
                && nextApplication == nil
                && reconciliation.priorRecordSHA256 == current.recordSHA256
        case let (
            .applied(currentPending, currentApplication),
            .evidence(nextPending, nextApplication, _)
        ):
            preservesExactLineage = nextPending == currentPending
                && nextApplication == currentApplication
        case let (
            .applied(currentPending, currentApplication),
            .needsReconciliation(
                nextPending,
                nextApplication,
                reconciliation
            )
        ):
            preservesExactLineage = nextPending == currentPending
                && nextApplication == currentApplication
                && reconciliation.priorRecordSHA256 == current.recordSHA256
        default:
            preservesExactLineage = false
        }
        guard preservesExactLineage else {
            throw MutationEffectLifecycleError.invalidTransition(
                from: current.phase,
                to: next.phase
            )
        }
    }

    private func next(_ state: MutationEffectState) throws -> Self {
        guard revision < UInt64.max else {
            throw MutationEffectLifecycleError.corruptEvidence
        }
        return try Self.make(
            binding: binding,
            revision: revision + 1,
            state: state
        )
    }

    private static func make(
        binding: MutationEffectBinding,
        revision: UInt64,
        state: MutationEffectState
    ) throws -> Self {
        guard binding.isCanonical(), revision > 0 else {
            throw MutationEffectLifecycleError.corruptEvidence
        }
        try validateState(state, binding: binding, revision: revision)
        let material = DigestMaterial(
            binding: binding,
            revision: revision,
            state: state
        )
        return Self(
            binding: binding,
            revision: revision,
            state: state,
            recordSHA256: try PolicyCanonicalDigest.sha256(
                domain: .mutationRecord,
                material
            )
        )
    }

    private static func validateState(
        _ state: MutationEffectState,
        binding: MutationEffectBinding,
        revision: UInt64
    ) throws {
        switch state {
        case let .pending(pending):
            guard revision == 1,
                  pending.isCanonical(binding: binding),
                  pending.preparedAt >= binding.claimedAt,
                  pending.preparedAt < binding.expiresAt
            else {
                throw MutationEffectLifecycleError.corruptEvidence
            }
        case let .applied(pending, application):
            guard revision == 2,
                  pending.isCanonical(binding: binding),
                  pending.preparedAt >= binding.claimedAt,
                  pending.preparedAt < binding.expiresAt,
                  application.isCanonical(pending: pending),
                  application.appliedAt >= pending.preparedAt
            else { throw MutationEffectLifecycleError.corruptEvidence }
        case let .evidence(pending, application, evidence):
            guard revision == 3,
                  pending.isCanonical(binding: binding),
                  pending.preparedAt >= binding.claimedAt,
                  pending.preparedAt < binding.expiresAt,
                  application.isCanonical(pending: pending),
                  application.appliedAt >= pending.preparedAt,
                  evidence.isCanonical(application: application),
                  evidence.recordedAt >= application.appliedAt
            else { throw MutationEffectLifecycleError.corruptEvidence }
        case let .needsReconciliation(pending, application, reconciliation):
            let expectedRevision: UInt64 = application == nil ? 2 : 3
            guard revision == expectedRevision,
                  pending.isCanonical(binding: binding),
                  pending.preparedAt >= binding.claimedAt,
                  pending.preparedAt < binding.expiresAt,
                  application?.isCanonical(pending: pending) != false,
                  application?.appliedAt ?? pending.preparedAt
                      >= pending.preparedAt,
                  reconciliation.isCanonical(),
                  reconciliation.markedAt
                      >= (application?.appliedAt ?? pending.preparedAt)
            else { throw MutationEffectLifecycleError.corruptEvidence }

            let prior = try application.map {
                try Self.make(
                    binding: binding,
                    revision: 2,
                    state: .applied(pending: pending, application: $0)
                )
            } ?? Self.make(
                binding: binding,
                revision: 1,
                state: .pending(pending)
            )
            guard reconciliation.priorRecordSHA256 == prior.recordSHA256 else {
                throw MutationEffectLifecycleError.corruptEvidence
            }
        }
    }

    private init(
        binding: MutationEffectBinding,
        revision: UInt64,
        state: MutationEffectState,
        recordSHA256: SHA256Digest
    ) {
        self.binding = binding
        self.revision = revision
        self.state = state
        self.recordSHA256 = recordSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case binding, revision, state, recordSHA256
    }
}

public struct MutationEffectLedgerSnapshot: Codable, Equatable, Sendable {
    public let records: [MutationEffectRecord]

    public init(records: [MutationEffectRecord]) {
        self.records = records
    }
}

public enum MutationEffectInsertDisposition: Equatable, Sendable {
    case inserted(MutationEffectRecord)
    case alreadyPresent(MutationEffectRecord)
}

public enum MutationEffectTransitionDisposition: Equatable, Sendable {
    case committed(MutationEffectRecord)
    case alreadyCommitted(MutationEffectRecord)
}

public protocol DurableMutationEffectLifecycleStore: Sendable {
    /// Compare-and-insert. The store must durably commit before returning
    /// `.inserted`; an existing key is never overwritten.
    func insertPendingIfAbsent(
        _ record: MutationEffectRecord
    ) async throws -> MutationEffectInsertDisposition

    /// Exact digest compare-and-swap. Implementations must validate the full
    /// transition and make it durable before returning `.committed`.
    func compareAndTransition(
        expectedRecordSHA256: SHA256Digest,
        to next: MutationEffectRecord
    ) async throws -> MutationEffectTransitionDisposition

    func record(
        effectKeySHA256: SHA256Digest
    ) async throws -> MutationEffectRecord?

    func snapshot() async throws -> MutationEffectLedgerSnapshot
}

enum MutationEffectStoreFaultPoint: Equatable, Sendable {
    case beforePendingCommit
    case afterPendingCommit
    case beforeAppliedCommit
    case afterAppliedCommit
    case beforeEvidenceCommit
    case afterEvidenceCommit
    case beforeReconciliationCommit
    case afterReconciliationCommit
}

typealias MutationEffectStoreFaultInjector =
    @Sendable (MutationEffectStoreFaultPoint) throws -> Void

public actor InMemoryMutationEffectLifecycleStore:
    DurableMutationEffectLifecycleStore
{
    private var records: [SHA256Digest: MutationEffectRecord]
    private let faultInjector: MutationEffectStoreFaultInjector?

    public init() {
        records = [:]
        faultInjector = nil
    }

    public init(restoring snapshot: MutationEffectLedgerSnapshot) throws {
        records = try Self.validatedMap(snapshot.records)
        faultInjector = nil
    }

    init(
        restoring snapshot: MutationEffectLedgerSnapshot = .init(records: []),
        faultInjector: @escaping MutationEffectStoreFaultInjector
    ) throws {
        records = try Self.validatedMap(snapshot.records)
        self.faultInjector = faultInjector
    }

    public func insertPendingIfAbsent(
        _ record: MutationEffectRecord
    ) throws -> MutationEffectInsertDisposition {
        guard record.isCanonical(), record.phase == .pending else {
            throw MutationEffectLifecycleError.invalidInitialPhase(record.phase)
        }
        if let existing = records[record.effectKeySHA256] {
            guard existing.binding == record.binding else {
                throw MutationEffectLifecycleError.recordConflict(
                    record.effectKeySHA256
                )
            }
            return .alreadyPresent(existing)
        }
        try faultInjector?(.beforePendingCommit)
        records[record.effectKeySHA256] = record
        try faultInjector?(.afterPendingCommit)
        return .inserted(record)
    }

    public func compareAndTransition(
        expectedRecordSHA256: SHA256Digest,
        to next: MutationEffectRecord
    ) throws -> MutationEffectTransitionDisposition {
        guard let current = records[next.effectKeySHA256] else {
            throw MutationEffectLifecycleError.recordNotFound(
                next.effectKeySHA256
            )
        }
        if current == next {
            return .alreadyCommitted(current)
        }
        guard current.recordSHA256 == expectedRecordSHA256 else {
            throw MutationEffectLifecycleError.staleRecord(
                expected: expectedRecordSHA256,
                actual: current.recordSHA256
            )
        }
        try MutationEffectRecord.validateTransition(from: current, to: next)
        let points = Self.faultPoints(for: next.phase)
        try faultInjector?(points.before)
        records[next.effectKeySHA256] = next
        try faultInjector?(points.after)
        return .committed(next)
    }

    public func record(
        effectKeySHA256: SHA256Digest
    ) -> MutationEffectRecord? {
        records[effectKeySHA256]
    }

    public func snapshot() -> MutationEffectLedgerSnapshot {
        MutationEffectLedgerSnapshot(records: records.values.sorted {
            $0.effectKeySHA256.rawValue < $1.effectKeySHA256.rawValue
        })
    }

    static func validatedMap(
        _ values: [MutationEffectRecord]
    ) throws -> [SHA256Digest: MutationEffectRecord] {
        var result: [SHA256Digest: MutationEffectRecord] = [:]
        for record in values {
            guard record.isCanonical(),
                  result[record.effectKeySHA256] == nil
            else { throw MutationEffectLifecycleError.corruptEvidence }
            result[record.effectKeySHA256] = record
        }
        return result
    }

    static func faultPoints(
        for phase: MutationEffectPhase
    ) -> (
        before: MutationEffectStoreFaultPoint,
        after: MutationEffectStoreFaultPoint
    ) {
        switch phase {
        case .pending:
            (.beforePendingCommit, .afterPendingCommit)
        case .applied:
            (.beforeAppliedCommit, .afterAppliedCommit)
        case .evidence:
            (.beforeEvidenceCommit, .afterEvidenceCommit)
        case .needsReconciliation:
            (.beforeReconciliationCommit, .afterReconciliationCommit)
        }
    }
}
