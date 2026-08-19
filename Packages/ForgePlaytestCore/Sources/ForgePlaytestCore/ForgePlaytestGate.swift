import Foundation

public struct ForgePlaytestPersonaRequirement: Hashable, Sendable {
    public static let maximumRequiredMilestoneIDs = 128

    public let persona: ForgePlaytestPersona
    public let minimumCompletedJourneys: Int
    public let requiredEvidenceKinds: Set<ForgePlaytestEvidenceKind>
    public let requiredMilestoneIDs: Set<String>

    public init(
        persona: ForgePlaytestPersona,
        minimumCompletedJourneys: Int = 1,
        requiredEvidenceKinds: Set<ForgePlaytestEvidenceKind> = [.runtimeExecution],
        requiredMilestoneIDs: Set<String> = []
    ) throws {
        guard minimumCompletedJourneys > 0, minimumCompletedJourneys <= 32 else {
            throw ForgePlaytestError.invalidMinimumJourneys
        }
        guard requiredEvidenceKinds.contains(.runtimeExecution) else {
            // Every accepted journey must bind to proof that a runtime execution happened.
            throw ForgePlaytestError.invalidEvidenceRequirement
        }
        try ForgePlaytestValidation.maximumCount(
            requiredMilestoneIDs.count,
            field: "personaRequirement.requiredMilestoneIDs",
            maximum: Self.maximumRequiredMilestoneIDs
        )
        var normalizedMilestones = Set<String>()
        for milestoneID in requiredMilestoneIDs {
            let normalized = try ForgePlaytestValidation.stableValue(
                milestoneID,
                field: "requiredMilestoneID",
                maximum: 160
            )
            guard normalizedMilestones.insert(normalized).inserted else {
                throw ForgePlaytestError.duplicateMilestoneID(normalized)
            }
        }
        self.persona = persona
        self.minimumCompletedJourneys = minimumCompletedJourneys
        self.requiredEvidenceKinds = requiredEvidenceKinds
        self.requiredMilestoneIDs = normalizedMilestones
    }
}

public struct ForgePlaytestAcceptancePolicy: Hashable, Sendable {
    public let requirements: [ForgePlaytestPersonaRequirement]
    public let repairThreshold: ForgePlaytestDefectSeverity

    public init(
        requirements: [ForgePlaytestPersonaRequirement],
        repairThreshold: ForgePlaytestDefectSeverity = .high
    ) throws {
        guard !requirements.isEmpty else { throw ForgePlaytestError.emptyRequirements }
        guard repairThreshold <= .high else { throw ForgePlaytestError.repairThresholdTooWeak }
        var personas = Set<ForgePlaytestPersona>()
        for requirement in requirements {
            guard personas.insert(requirement.persona).inserted else {
                throw ForgePlaytestError.conflictingPersonaRequirement(requirement.persona.rawValue)
            }
        }
        self.requirements = requirements.sorted { $0.persona.rawValue < $1.persona.rawValue }
        self.repairThreshold = repairThreshold
    }
}

public enum ForgePlaytestBlocker: Hashable, Sendable {
    case missingCompletedJourneys(persona: ForgePlaytestPersona, required: Int, actual: Int)
    case insufficientQualifiedJourneys(persona: ForgePlaytestPersona, required: Int, actual: Int)
    case missingEvidence(persona: ForgePlaytestPersona, kind: ForgePlaytestEvidenceKind)
    case missingMilestone(persona: ForgePlaytestPersona, milestoneID: String)
}

public struct ForgePlaytestRepairItem: Hashable, Sendable {
    public let journeyID: String
    public let persona: ForgePlaytestPersona
    public let defect: ForgePlaytestDefect
}

public struct ForgePlaytestAcceptedProjection: Hashable, Sendable {
    public let project: ForgePlaytestProjectRevision
    public let acceptedJourneyIDs: [String]
    public let contributingReceiptIDs: [String]

    fileprivate init(
        project: ForgePlaytestProjectRevision,
        acceptedJourneyIDs: [String],
        contributingReceiptIDs: [String]
    ) {
        self.project = project
        self.acceptedJourneyIDs = acceptedJourneyIDs
        self.contributingReceiptIDs = contributingReceiptIDs
    }
}

/// Playtest-only verdict. `.accepted` is evidence suitable for the Mission Engine to consume;
/// it is not itself mission completion.
public enum ForgePlaytestGateVerdict: Hashable, Sendable {
    case blocked([ForgePlaytestBlocker])
    case repairRequired([ForgePlaytestRepairItem])
    case accepted(ForgePlaytestAcceptedProjection)
}

public enum ForgePlaytestGateEvaluator {
    public static let maximumJourneyPlans = 256
    public static let maximumJourneyResults = 256

    static func evaluate(
        project: ForgePlaytestProjectRevision,
        policy: ForgePlaytestAcceptancePolicy,
        plans: [ForgePlaytestJourneyPlan],
        results: [ForgePlaytestJourneyResult]
    ) throws -> ForgePlaytestGateVerdict {
        try ForgePlaytestValidation.maximumCount(
            plans.count,
            field: "playtest.plans",
            maximum: Self.maximumJourneyPlans
        )
        try ForgePlaytestValidation.maximumCount(
            results.count,
            field: "playtest.results",
            maximum: Self.maximumJourneyResults
        )

        var plansByJourneyID: [String: ForgePlaytestJourneyPlan] = [:]
        for plan in plans {
            guard plan.project.projectID == project.projectID else {
                throw ForgePlaytestError.projectMismatch
            }
            guard plan.project.sourceRevision == project.sourceRevision else {
                throw ForgePlaytestError.sourceRevisionMismatch
            }
            guard plansByJourneyID.updateValue(plan, forKey: plan.journeyID) == nil else {
                throw ForgePlaytestError.duplicateJourneyID(plan.journeyID)
            }
        }

        var journeyIDs = Set<String>()
        for result in results {
            guard journeyIDs.insert(result.journeyID).inserted else {
                throw ForgePlaytestError.duplicateJourneyID(result.journeyID)
            }
            guard result.project.projectID == project.projectID else {
                throw ForgePlaytestError.projectMismatch
            }
            guard result.project.sourceRevision == project.sourceRevision else {
                throw ForgePlaytestError.sourceRevisionMismatch
            }
            guard let plan = plansByJourneyID[result.journeyID] else {
                throw ForgePlaytestError.unknownJourneyPlan(result.journeyID)
            }
            guard plan.persona == result.persona else {
                throw ForgePlaytestError.personaMismatch
            }
            guard plan.trace.traceID == result.traceID else {
                throw ForgePlaytestError.traceMismatch
            }
        }

        let completed = results.filter { $0.status == .completed }
        var blockers: [ForgePlaytestBlocker] = []
        var acceptedJourneys = Set<String>()

        for requirement in policy.requirements {
            let personaResults = completed
                .filter { $0.persona == requirement.persona }
                .sorted { $0.journeyID < $1.journeyID }

            if personaResults.count < requirement.minimumCompletedJourneys {
                blockers.append(.missingCompletedJourneys(
                    persona: requirement.persona,
                    required: requirement.minimumCompletedJourneys,
                    actual: personaResults.count
                ))
                continue
            }

            let qualified = personaResults.filter { result in
                guard let plan = plansByJourneyID[result.journeyID] else { return false }
                return requirement.requiredEvidenceKinds.isSubset(of: result.evidenceKinds)
                    && requirement.requiredMilestoneIDs.isSubset(of: result.milestoneIDs)
                    && plan.expectedMilestoneIDs.isSubset(of: result.milestoneIDs)
            }

            if qualified.count < requirement.minimumCompletedJourneys {
                var addedSpecificBlocker = false

                for kind in requirement.requiredEvidenceKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                    let matchingCount = personaResults.filter { $0.evidenceKinds.contains(kind) }.count
                    if matchingCount < requirement.minimumCompletedJourneys {
                        blockers.append(.missingEvidence(persona: requirement.persona, kind: kind))
                        addedSpecificBlocker = true
                    }
                }

                for milestoneID in requirement.requiredMilestoneIDs.sorted() {
                    let matchingCount = personaResults.filter { $0.milestoneIDs.contains(milestoneID) }.count
                    if matchingCount < requirement.minimumCompletedJourneys {
                        blockers.append(.missingMilestone(persona: requirement.persona, milestoneID: milestoneID))
                        addedSpecificBlocker = true
                    }
                }

                let plannedMissingMilestones = Set(personaResults.flatMap { result -> [String] in
                    guard let plan = plansByJourneyID[result.journeyID] else { return [] }
                    return plan.expectedMilestoneIDs.subtracting(result.milestoneIDs).map { $0 }
                }).sorted()
                for milestoneID in plannedMissingMilestones {
                    blockers.append(.missingMilestone(persona: requirement.persona, milestoneID: milestoneID))
                    addedSpecificBlocker = true
                }

                if !addedSpecificBlocker {
                    blockers.append(.insufficientQualifiedJourneys(
                        persona: requirement.persona,
                        required: requirement.minimumCompletedJourneys,
                        actual: qualified.count
                    ))
                }
                continue
            }

            qualified.prefix(requirement.minimumCompletedJourneys).forEach {
                acceptedJourneys.insert($0.journeyID)
            }
        }

        // This module-internal primitive preserves severe defects as repair candidates ahead of
        // generic evidence blockers. The public evidence gate is responsible for authenticating
        // every repair-threshold defect before delegating here. Completed-only qualification above
        // remains unchanged.
        let repairItems = results.flatMap { result in
            result.defects.compactMap { defect -> ForgePlaytestRepairItem? in
                guard defect.severity >= policy.repairThreshold else { return nil }
                return ForgePlaytestRepairItem(
                    journeyID: result.journeyID,
                    persona: result.persona,
                    defect: defect
                )
            }
        }.sorted {
            if $0.defect.severity != $1.defect.severity {
                return $0.defect.severity > $1.defect.severity
            }
            if $0.journeyID != $1.journeyID { return $0.journeyID < $1.journeyID }
            return $0.defect.defectID < $1.defect.defectID
        }

        if !repairItems.isEmpty {
            return .repairRequired(repairItems)
        }

        if !blockers.isEmpty {
            return .blocked(blockers)
        }

        let contributingResults = completed.filter { acceptedJourneys.contains($0.journeyID) }
        let requirementsByPersona = Dictionary(
            uniqueKeysWithValues: policy.requirements.map { ($0.persona, $0) }
        )
        var contributingReceiptIDs = Set<String>()

        for result in contributingResults {
            guard let requirement = requirementsByPersona[result.persona],
                  let plan = plansByJourneyID[result.journeyID]
            else { continue }

            for kind in requirement.requiredEvidenceKinds {
                if let receiptID = result.evidence
                    .filter({ $0.kind == kind })
                    .map(\.receiptID)
                    .sorted()
                    .first {
                    contributingReceiptIDs.insert(receiptID)
                }
            }

            let requiredMilestoneIDs = requirement.requiredMilestoneIDs
                .union(plan.expectedMilestoneIDs)
            for milestone in result.milestones
            where requiredMilestoneIDs.contains(milestone.milestoneID) {
                contributingReceiptIDs.formUnion(milestone.evidenceReceiptIDs)
            }
        }

        return .accepted(ForgePlaytestAcceptedProjection(
            project: project,
            acceptedJourneyIDs: acceptedJourneys.sorted(),
            contributingReceiptIDs: contributingReceiptIDs.sorted()
        ))
    }
}
