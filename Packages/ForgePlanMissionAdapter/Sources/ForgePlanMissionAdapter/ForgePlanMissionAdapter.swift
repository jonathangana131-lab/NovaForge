import Foundation
import AgentDomain
import ForgePlanCore

public enum ForgePlanMissionHandoffError: Error, Equatable, Sendable {
    case invalidContext(String)
    case invalidSourceBinding(String)
    case invalidSummary(String)
    case duplicateDecisionID(String)
    case invalidDecision(String)
    case missingAcceptanceJourneys
    case missingExpectedEvidence
    case invalidConstitution(MissionConstitutionValidationError)
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

/// Host-supplied Mission identity used to build a candidate constitution projection.
/// `planAcceptanceReceiptID` is an opaque reference only; this public value does not authenticate it.
public struct ForgePlanMissionContext: Sendable {
    public let missionID: MissionID
    public let projectID: ProjectID
    public let constitutionRevision: UInt64
    public let projectedAcceptedAt: AgentInstant
    public let planAcceptanceReceiptID: String

    public init(
        missionID: MissionID,
        projectID: ProjectID,
        constitutionRevision: UInt64,
        projectedAcceptedAt: AgentInstant,
        planAcceptanceReceiptID: String
    ) throws {
        guard constitutionRevision > 0 else {
            throw ForgePlanMissionHandoffError.invalidContext("constitutionRevision")
        }
        self.missionID = missionID
        self.projectID = projectID
        self.constitutionRevision = constitutionRevision
        self.projectedAcceptedAt = projectedAcceptedAt
        self.planAcceptanceReceiptID = try canonicalOpaqueID(
            planAcceptanceReceiptID,
            field: "planAcceptanceReceiptID",
            error: ForgePlanMissionHandoffError.invalidContext
        )
    }
}

/// Revision identity that lets the eventual Composer/Mission integration reject a stale Plan Space
/// result after the user edits either the source Composer draft or the reviewed plan.
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

/// Mission fields that cannot be inferred safely from the Plan Space control profile itself.
/// Privacy/locality is deliberately absent: V14 Composer privacy remains the single authority.
public struct ForgePlanMissionSupplement: Sendable {
    public var projectType: String
    public var designIntent: String?
    public var orientationTarget: String?
    public var deviceTargets: MissionStringSet
    public var requiredCapabilities: MissionStringSet
    public var explicitNonGoals: MissionStringSet
    public var constraints: MissionStringSet
    public var performanceTarget: String?
    public var accessibilityTarget: String?
    public var persistenceExpectations: String?
    public var acceptanceJourneys: MissionStringSet
    public var expectedEvidence: MissionEvidenceSet

    public init(
        projectType: String,
        designIntent: String? = nil,
        orientationTarget: String? = nil,
        deviceTargets: MissionStringSet = MissionStringSet([]),
        requiredCapabilities: MissionStringSet = MissionStringSet([]),
        explicitNonGoals: MissionStringSet = MissionStringSet([]),
        constraints: MissionStringSet = MissionStringSet([]),
        performanceTarget: String? = nil,
        accessibilityTarget: String? = nil,
        persistenceExpectations: String? = nil,
        acceptanceJourneys: MissionStringSet,
        expectedEvidence: MissionEvidenceSet
    ) {
        self.projectType = projectType
        self.designIntent = designIntent
        self.orientationTarget = orientationTarget
        self.deviceTargets = deviceTargets
        self.requiredCapabilities = requiredCapabilities
        self.explicitNonGoals = explicitNonGoals
        self.constraints = constraints
        self.performanceTarget = performanceTarget
        self.accessibilityTarget = accessibilityTarget
        self.persistenceExpectations = persistenceExpectations
        self.acceptanceJourneys = acceptanceJourneys
        self.expectedEvidence = expectedEvidence
    }
}

/// Every case is a requirement for a canonical host/Mission router to verify or enforce.
/// None of these values self-certifies that its requirement has already been satisfied.
public enum ForgePlanMissionExecutionPrecondition: Hashable, Sendable {
    case sourceRevisionMatch(binding: ForgePlanMissionSourceBinding)
    case planAcceptanceVerification(receiptID: String)
    case localOnlyRouting
    case providerAllowlistEnforcement(providerIDs: [String])
    case autonomyPolicyResolution(intent: ForgeComposerAutonomyIntent)
    case explicitModelQualification(referenceID: String)
    case delegatedDecisionResolution(decisionID: String)
}

/// A candidate typed projection from Plan Space toward Mission. It intentionally retains the exact
/// V14 Composer control profile instead of flattening privacy/model/autonomy into prompt prose.
/// This value is not accepted execution authority: its receipt/source identities are references and
/// every security/policy-sensitive requirement is emitted as an unresolved execution precondition.
public struct ForgePlanMissionHandoff: Sendable {
    public let constitution: MissionConstitution
    public let planAcceptanceReceiptID: String
    public let planDecisions: [PlanResolvedDecision]
    public let controlProfile: ForgeComposerV14ControlProfile
    public let sourceBinding: ForgePlanMissionSourceBinding
    public let executionPreconditions: [ForgePlanMissionExecutionPrecondition]

    fileprivate init(
        constitution: MissionConstitution,
        planAcceptanceReceiptID: String,
        planDecisions: [PlanResolvedDecision],
        controlProfile: ForgeComposerV14ControlProfile,
        sourceBinding: ForgePlanMissionSourceBinding,
        executionPreconditions: [ForgePlanMissionExecutionPrecondition]
    ) {
        self.constitution = constitution
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
        sourceBinding: ForgePlanMissionSourceBinding,
        supplement: ForgePlanMissionSupplement
    ) throws -> ForgePlanMissionHandoff {
        try validate(summary: summary)
        guard !supplement.acceptanceJourneys.values.isEmpty else {
            throw ForgePlanMissionHandoffError.missingAcceptanceJourneys
        }
        guard !supplement.expectedEvidence.values.isEmpty else {
            throw ForgePlanMissionHandoffError.missingExpectedEvidence
        }

        let controls = summary.controls
        let constitution = MissionConstitution(
            missionID: context.missionID,
            projectID: context.projectID,
            revision: context.constitutionRevision,
            acceptedAt: context.projectedAcceptedAt,
            productGoal: summary.intentSummary,
            projectType: supplement.projectType,
            designIntent: supplement.designIntent,
            orientationTarget: supplement.orientationTarget,
            deviceTargets: supplement.deviceTargets,
            requiredCapabilities: supplement.requiredCapabilities,
            explicitNonGoals: supplement.explicitNonGoals,
            constraints: supplement.constraints,
            buildDepth: map(controls.buildDepth),
            creativity: mapCreativity(controls.creativity.value),
            refactorRisk: mapRefactorRisk(controls.refactorRisk.value),
            localityPreference: controls.privacy.isLocalOnly ? .localOnly : .unspecified,
            performanceTarget: supplement.performanceTarget,
            accessibilityTarget: supplement.accessibilityTarget,
            persistenceExpectations: supplement.persistenceExpectations,
            acceptanceJourneys: supplement.acceptanceJourneys,
            expectedEvidence: supplement.expectedEvidence
        )
        if let error = constitution.validationError {
            throw ForgePlanMissionHandoffError.invalidConstitution(error)
        }

        let canonicalDecisions = summary.decisions.sorted { lhs, rhs in
            lhs.id == rhs.id ? lhs.prompt < rhs.prompt : lhs.id < rhs.id
        }

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
            constitution: constitution,
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

    private static func map(_ value: ForgeComposerBuildDepthIntent) -> MissionBuildDepth {
        switch value {
        case .quick: .prototype
        case .complete: .polished
        case .obsessive: .obsessive
        }
    }

    private static func mapCreativity(_ value: Double) -> MissionCreativity {
        if value < (1.0 / 3.0) { return .faithful }
        if value >= (2.0 / 3.0) { return .inventive }
        return .balanced
    }

    private static func mapRefactorRisk(_ value: Double) -> MissionRefactorRisk {
        if value < (1.0 / 3.0) { return .preserve }
        if value >= (2.0 / 3.0) { return .rebuild }
        return .balanced
    }
}
