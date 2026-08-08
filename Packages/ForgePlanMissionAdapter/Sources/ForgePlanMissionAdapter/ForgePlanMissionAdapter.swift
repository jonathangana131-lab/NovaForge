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
    guard value == trimmed, !value.isEmpty, value.utf8.count <= 512,
          value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
        throw ForgePlanMissionHandoffError.invalidAuthority(field)
    }
    return value
}

private func validText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && value.utf8.count <= maximumUTF8Bytes &&
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }
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
        self.planAcceptanceReceiptID = try canonicalOpaqueID(planAcceptanceReceiptID, field: "planAcceptanceReceiptID")
    }
}

public struct ForgePlanMissionSupplement: Sendable {
    public var projectType: String
    public var designIntent: String?
    public var orientationTarget: String?
    public var deviceTargets: MissionStringSet
    public var requiredCapabilities: MissionStringSet
    public var explicitNonGoals: MissionStringSet
    public var constraints: MissionStringSet
    public var localityPreference: MissionLocalityPreference
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
        localityPreference: MissionLocalityPreference = .unspecified,
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
        self.localityPreference = localityPreference
        self.performanceTarget = performanceTarget
        self.accessibilityTarget = accessibilityTarget
        self.persistenceExpectations = persistenceExpectations
        self.acceptanceJourneys = acceptanceJourneys
        self.expectedEvidence = expectedEvidence
    }
}

/// Plan controls that matter to orchestration but are not Mission Constitution authority.
/// In particular, Local Compute / Cloud Resource do not grant locality or provider permission.
public struct ForgePlanMissionOrchestrationIntent: Equatable, Sendable {
    public let intelligence: ForgeIntelligence
    public let autonomy: ForgeAutonomy
    public let localCompute: Double
    public let cloudResource: Double
}

/// Evaluator-produced handoff. It is intentionally non-Codable and its initializer is not public:
/// persisted bytes cannot manufacture a Plan -> Mission acceptance projection.
public struct ForgePlanMissionHandoff: Sendable {
    public let constitution: MissionConstitution
    public let planAcceptanceReceiptID: String
    public let acceptedPlanDecisions: [PlanResolvedDecision]
    public let delegatedDecisionIDs: [String]
    public let orchestrationIntent: ForgePlanMissionOrchestrationIntent

    fileprivate init(
        constitution: MissionConstitution,
        planAcceptanceReceiptID: String,
        acceptedPlanDecisions: [PlanResolvedDecision],
        delegatedDecisionIDs: [String],
        orchestrationIntent: ForgePlanMissionOrchestrationIntent
    ) {
        self.constitution = constitution
        self.planAcceptanceReceiptID = planAcceptanceReceiptID
        self.acceptedPlanDecisions = acceptedPlanDecisions
        self.delegatedDecisionIDs = delegatedDecisionIDs
        self.orchestrationIntent = orchestrationIntent
    }

    /// A pending delegated decision is a pre-execution truth gate. This is not an execution grant.
    public var requiresDelegatedDecisionResolution: Bool { !delegatedDecisionIDs.isEmpty }
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
            localityPreference: supplement.localityPreference,
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
        let delegatedIDs = canonicalDecisions.compactMap { decision in
            decision.value == .delegatedToNovaForge ? decision.id : nil
        }

        return ForgePlanMissionHandoff(
            constitution: constitution,
            planAcceptanceReceiptID: authority.planAcceptanceReceiptID,
            acceptedPlanDecisions: canonicalDecisions,
            delegatedDecisionIDs: delegatedIDs,
            orchestrationIntent: .init(
                intelligence: controls.intelligence,
                autonomy: controls.autonomy,
                localCompute: controls.localCompute.value,
                cloudResource: controls.cloudResource.value
            )
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
                  !id.isEmpty, id.utf8.count <= 512,
                  id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
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
                      !optionID.isEmpty, optionID.utf8.count <= 512,
                      optionID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                      validText(label, maximumUTF8Bytes: 4_096) else {
                    throw ForgePlanMissionHandoffError.invalidDecision(id)
                }
            case .scalar(let value):
                guard value.isFinite else { throw ForgePlanMissionHandoffError.invalidDecision(id) }
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

    private static func map(_ value: ForgeBuildDepth) -> MissionBuildDepth {
        switch value {
        case .prototype: .prototype
        case .polished: .polished
        case .obsessive: .obsessive
        }
    }

    /// Canonical thirds convert Plan Space's normalized intent into the Mission domain's buckets.
    private static func mapCreativity(_ value: Double) -> MissionCreativity {
        if value < (1.0 / 3.0) { return .faithful }
        if value >= (2.0 / 3.0) { return .inventive }
        return .balanced
    }

    /// Canonical thirds convert Plan Space's normalized refactor-risk intent into Mission buckets.
    private static func mapRefactorRisk(_ value: Double) -> MissionRefactorRisk {
        if value < (1.0 / 3.0) { return .preserve }
        if value >= (2.0 / 3.0) { return .rebuild }
        return .balanced
    }
}
