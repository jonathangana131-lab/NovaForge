import Foundation
import ForgePlanCore

public enum ForgePlanMissionHandoffError: Error, Equatable, Sendable {
    case invalidContext(String)
    case invalidSourceBinding(String)
    case invalidSummary(String)
    case duplicateDecisionID(String)
    case invalidDecision(String)
}

private func canonicalOpaqueID(
    _ value: String,
    field: String,
    error: (String) -> ForgePlanMissionHandoffError
) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value == trimmed,
          !value.isEmpty,
          value.utf8.count <= 512,
          value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
        throw error(field)
    }
    return value
}

private func validText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
        && value.utf8.count <= maximumUTF8Bytes
        && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" || $0 == "\r"
        }
}

/// Host-supplied identity for this Plan -> Mission handoff candidate.
/// The acceptance receipt is only an opaque reference; this type does not authenticate it.
public struct ForgePlanMissionContext: Hashable, Sendable {
    public let handoffRevision: UInt64
    public let planAcceptanceReceiptID: String

    public init(
        handoffRevision: UInt64,
        planAcceptanceReceiptID: String
    ) throws {
        guard handoffRevision > 0 else {
            throw ForgePlanMissionHandoffError.invalidContext("handoffRevision")
        }
        self.handoffRevision = handoffRevision
        self.planAcceptanceReceiptID = try canonicalOpaqueID(
            planAcceptanceReceiptID,
            field: "planAcceptanceReceiptID",
            error: ForgePlanMissionHandoffError.invalidContext
        )
    }
}

/// Revision identity that lets Composer/Mission integration reject a stale Plan Space result after
/// the user edits either the source Composer draft or the reviewed plan.
public struct ForgePlanMissionSourceBinding: Hashable, Sendable {
    public let composerDraftRevision: UInt64
    public let planRevision: UInt64
    public let planReferenceID: String

    public init(
        composerDraftRevision: UInt64,
        planRevision: UInt64,
        planReferenceID: String
    ) throws {
        guard composerDraftRevision > 0 else {
            throw ForgePlanMissionHandoffError.invalidSourceBinding("composerDraftRevision")
        }
        guard planRevision > 0 else {
            throw ForgePlanMissionHandoffError.invalidSourceBinding("planRevision")
        }
        self.composerDraftRevision = composerDraftRevision
        self.planRevision = planRevision
        self.planReferenceID = try canonicalOpaqueID(
            planReferenceID,
            field: "planReferenceID",
            error: ForgePlanMissionHandoffError.invalidSourceBinding
        )
    }
}

/// Requirements for the eventual host/Mission router. These values are never evidence that the
/// requirement has already been satisfied.
public enum ForgePlanMissionExecutionPrecondition: Hashable, Sendable {
    case sourceRevisionMatch(binding: ForgePlanMissionSourceBinding)
    case planAcceptanceVerification(receiptID: String)
    case localOnlyRouting
    case providerAllowlistEnforcement(providerIDs: [String])
    case autonomyPolicyResolution(intent: ForgeComposerAutonomyIntent)
    case explicitModelQualification(referenceID: String)
    case delegatedDecisionResolution(decisionID: String)
}

/// Typed Plan Space output that can survive the presentation boundary without flattening privacy,
/// model selection, autonomy, build-depth, creativity, refactor risk, or decisions into prompt prose.
///
/// This is intentionally *not* a Mission Constitution or execution authority. Canonical Mission
/// types are owned by the Mission Engine lineage; after that authority lands, a separate adapter can
/// consume this envelope without inventing a parallel Mission domain.
public struct ForgePlanMissionHandoff: Sendable {
    public let revision: UInt64
    public let intentSummary: String
    public let planAcceptanceReceiptID: String
    public let planDecisions: [PlanResolvedDecision]
    public let controlProfile: ForgeComposerV14ControlProfile
    public let sourceBinding: ForgePlanMissionSourceBinding
    public let executionPreconditions: [ForgePlanMissionExecutionPrecondition]

    fileprivate init(
        revision: UInt64,
        intentSummary: String,
        planAcceptanceReceiptID: String,
        planDecisions: [PlanResolvedDecision],
        controlProfile: ForgeComposerV14ControlProfile,
        sourceBinding: ForgePlanMissionSourceBinding,
        executionPreconditions: [ForgePlanMissionExecutionPrecondition]
    ) {
        self.revision = revision
        self.intentSummary = intentSummary
        self.planAcceptanceReceiptID = planAcceptanceReceiptID
        self.planDecisions = planDecisions
        self.controlProfile = controlProfile
        self.sourceBinding = sourceBinding
        self.executionPreconditions = executionPreconditions
    }

    public var delegatedDecisionIDs: [String] {
        executionPreconditions.compactMap { precondition in
            guard case .delegatedDecisionResolution(let decisionID) = precondition else { return nil }
            return decisionID
        }
    }

    public var requiresDelegatedDecisionResolution: Bool {
        !delegatedDecisionIDs.isEmpty
    }

    public var requiresExternalModelQualification: Bool {
        executionPreconditions.contains { precondition in
            if case .explicitModelQualification = precondition { return true }
            return false
        }
    }

    public var requestedExplicitModelReferenceID: String? {
        executionPreconditions.compactMap { precondition -> String? in
            guard case .explicitModelQualification(let referenceID) = precondition else { return nil }
            return referenceID
        }.first
    }

    public var privacyIntent: ForgeComposerPrivacyIntent { controlProfile.privacy }
    public var autonomyIntent: ForgeComposerAutonomyIntent { controlProfile.autonomy }
}

public enum ForgePlanMissionAdapter {
    public static func makeHandoff(
        summary: ReadyToForgeSummary,
        context: ForgePlanMissionContext,
        sourceBinding: ForgePlanMissionSourceBinding
    ) throws -> ForgePlanMissionHandoff {
        try validate(summary: summary)

        let canonicalDecisions = summary.decisions.sorted { lhs, rhs in
            lhs.id == rhs.id ? lhs.prompt < rhs.prompt : lhs.id < rhs.id
        }
        let controls = summary.controls

        var preconditions: [ForgePlanMissionExecutionPrecondition] = [
            .sourceRevisionMatch(binding: sourceBinding),
            .planAcceptanceVerification(receiptID: context.planAcceptanceReceiptID),
        ]

        switch controls.privacy {
        case .localOnly:
            preconditions.append(.localOnlyRouting)
        case .providerAllowlist(let providerIDs):
            preconditions.append(.providerAllowlistEnforcement(providerIDs: providerIDs))
        }

        preconditions.append(.autonomyPolicyResolution(intent: controls.autonomy))

        if case .explicitModel(let referenceID) = controls.intelligence {
            preconditions.append(.explicitModelQualification(referenceID: referenceID))
        }

        preconditions.append(contentsOf: canonicalDecisions.compactMap { decision in
            decision.value == .delegatedToNovaForge
                ? .delegatedDecisionResolution(decisionID: decision.id)
                : nil
        })

        return ForgePlanMissionHandoff(
            revision: context.handoffRevision,
            intentSummary: summary.intentSummary,
            planAcceptanceReceiptID: context.planAcceptanceReceiptID,
            planDecisions: canonicalDecisions,
            controlProfile: controls,
            sourceBinding: sourceBinding,
            executionPreconditions: preconditions
        )
    }

    private static func validate(summary: ReadyToForgeSummary) throws {
        guard validText(summary.intentSummary, maximumUTF8Bytes: 16_384) else {
            throw ForgePlanMissionHandoffError.invalidSummary("intentSummary")
        }
        guard summary.decisions.count <= 128 else {
            throw ForgePlanMissionHandoffError.invalidSummary("tooManyDecisions")
        }

        var ids = Set<String>()
        for decision in summary.decisions {
            let id = decision.id
            guard id == id.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  id.utf8.count <= 512,
                  id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else {
                throw ForgePlanMissionHandoffError.invalidDecision(id)
            }
            guard ids.insert(id).inserted else {
                throw ForgePlanMissionHandoffError.duplicateDecisionID(id)
            }
            guard validText(decision.prompt, maximumUTF8Bytes: 4_096) else {
                throw ForgePlanMissionHandoffError.invalidDecision(id)
            }

            switch decision.value {
            case .selected(let optionID, let label):
                guard optionID == optionID.trimmingCharacters(in: .whitespacesAndNewlines),
                      !optionID.isEmpty,
                      optionID.utf8.count <= 512,
                      optionID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                      validText(label, maximumUTF8Bytes: 4_096)
                else {
                    throw ForgePlanMissionHandoffError.invalidDecision(id)
                }
            case .scalar(let value):
                guard value.isFinite else {
                    throw ForgePlanMissionHandoffError.invalidDecision(id)
                }
            case .interval(let lower, let upper):
                guard lower.isFinite, upper.isFinite, lower <= upper else {
                    throw ForgePlanMissionHandoffError.invalidDecision(id)
                }
            case .text(let value):
                guard validText(value, maximumUTF8Bytes: 8_192) else {
                    throw ForgePlanMissionHandoffError.invalidDecision(id)
                }
            case .delegatedToNovaForge:
                break
            }
        }
    }
}
