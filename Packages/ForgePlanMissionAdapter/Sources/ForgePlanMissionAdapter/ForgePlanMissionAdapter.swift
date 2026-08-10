import Foundation
import AgentDomain
import ForgePlanCore

public enum ForgePlanMissionHandoffError: Error, Equatable, Sendable {
    case invalidAuthority(String)
    case invalidSummary(String)
    case duplicateDecisionID(String)
    case invalidDecision(String)
    case missingAcceptanceJourneys
    case missingExpectedEvidence
    case invalidConstitution(MissionConstitutionValidationError)
}

private func canonicalOpaqueID(_ value: String, field: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value == trimmed,
          !value.isEmpty,
          value.utf8.count <= 512,
          value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
        throw ForgePlanMissionHandoffError.invalidAuthority(field)
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

public struct ForgePlanMissionAuthority: Sendable {
    public let missionID: MissionID
    public let projectID: ProjectID
    public let constitutionRevision: UInt64
    public let acceptedAt: AgentInstant
    public let planAcceptanceReceiptID: String

    public init(
        missionID: MissionID,
        projectID: ProjectID,
        constitutionRevision: UInt64,
        acceptedAt: AgentInstant,
        planAcceptanceReceiptID: String
    ) throws {
        guard constitutionRevision > 0 else {
            throw ForgePlanMissionHandoffError.invalidAuthority("constitutionRevision")
        }
        self.missionID = missionID
        self.projectID = projectID
        self.constitutionRevision = constitutionRevision
        self.acceptedAt = acceptedAt
        self.planAcceptanceReceiptID = try canonicalOpaqueID(
            planAcceptanceReceiptID,
            field: "planAcceptanceReceiptID"
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

/// Preconditions exposed to the owning Mission/start router. These are requirements, never proof
/// that the requirement has already been satisfied.
public enum ForgePlanMissionExecutionPrecondition: Hashable, Sendable {
    case explicitModelQualification(referenceID: String)
    case delegatedDecisionResolution(decisionID: String)
}

/// Evaluator-produced handoff. It intentionally retains the exact V14 Composer control profile
/// instead of projecting privacy/model/autonomy into prose or a second parallel control format.
/// The type is non-Codable and its initializer is not public, so archived/model-authored bytes
/// cannot manufacture an accepted Plan -> Mission projection by themselves.
public struct ForgePlanMissionHandoff: Sendable {
    public let constitution: MissionConstitution
    public let planAcceptanceReceiptID: String
    public let acceptedPlanDecisions: [PlanResolvedDecision]
    public let controlProfile: ForgeComposerV14ControlProfile
    public let executionPreconditions: [ForgePlanMissionExecutionPrecondition]

    fileprivate init(
        constitution: MissionConstitution,
        planAcceptanceReceiptID: String,
        acceptedPlanDecisions: [PlanResolvedDecision],
        controlProfile: ForgeComposerV14ControlProfile,
        executionPreconditions: [ForgePlanMissionExecutionPrecondition]
    ) {
        self.constitution = constitution
        self.planAcceptanceReceiptID = planAcceptanceReceiptID
        self.acceptedPlanDecisions = acceptedPlanDecisions
        self.controlProfile = controlProfile
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

    /// Persistent routing requirement. Local Only remains structurally distinct from provider
    /// permission and must be enforced by the owning router; this package never grants a route.
    public var privacyIntent: ForgeComposerPrivacyIntent { controlProfile.privacy }

    /// User autonomy intent survives Plan Space as typed truth, but remains a permission request;
    /// actual stage/action authority still belongs to Mission policy and receipts.
    public var autonomyIntent: ForgeComposerAutonomyIntent { controlProfile.autonomy }
}

public enum ForgePlanMissionAdapter {
    public static func makeHandoff(
        summary: ReadyToForgeSummary,
        authority: ForgePlanMissionAuthority,
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
            missionID: authority.missionID,
            projectID: authority.projectID,
            revision: authority.constitutionRevision,
            acceptedAt: authority.acceptedAt,
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

        var preconditions: [ForgePlanMissionExecutionPrecondition] = []
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
            planAcceptanceReceiptID: authority.planAcceptanceReceiptID,
            acceptedPlanDecisions: canonicalDecisions,
            controlProfile: controls,
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
