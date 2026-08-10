/// Exact execution binding supplied by the canonical runtime adapter.
///
/// The binding carries the full validated trace value rather than only a human-readable trace ID,
/// so a result from an older/different trace cannot be replayed against a plan that reused the ID.
/// The referenced receipt is still opaque here: only a producer-owned runtime adapter may treat it
/// as authentic dispatch/execution evidence.
public struct ForgePlaytestExecutionBinding: Hashable, Sendable {
    public let executionEvidence: ForgePlaytestEvidenceReference
    public let trace: ForgePlaytestTrace

    public init(
        executionEvidence: ForgePlaytestEvidenceReference,
        trace: ForgePlaytestTrace
    ) throws {
        guard executionEvidence.kind == .runtimeExecution else {
            throw ForgePlaytestExecutionGateError.nonExecutionEvidence(
                executionEvidence.receiptID
            )
        }
        self.executionEvidence = executionEvidence
        self.trace = trace
    }
}

public enum ForgePlaytestExecutionGateError: Error, Equatable, Sendable {
    case nonExecutionEvidence(String)
    case duplicateBinding(String)
    case bindingProjectMismatch(String)
    case bindingSourceRevisionMismatch(String)
    case missingBinding(String)
    case unexpectedBinding(String)
    case ambiguousExecutionEvidence(String)
    case executionEvidenceMismatch(String)
    case executionTraceMismatch(String)
    case duplicateDefectEvidenceBinding(journeyID: String, defectID: String)
    case defectEvidenceBindingProjectMismatch(journeyID: String, defectID: String)
    case defectEvidenceBindingSourceRevisionMismatch(journeyID: String, defectID: String)
    case defectEvidenceBindingJourneyMismatch(journeyID: String, defectID: String)
    case defectEvidenceBindingDefectMismatch(journeyID: String, defectID: String)
    case defectEvidenceBindingEvidenceMismatch(journeyID: String, defectID: String)
    case missingDefectEvidenceBinding(journeyID: String, defectID: String)
    case unexpectedDefectEvidenceBinding(journeyID: String, defectID: String)
}

/// Non-Codable producer-authenticated handoff for one complete defect subject.
///
/// Ordinary package consumers cannot construct this value: its initializer is module-internal.
/// A future canonical crash/runtime/visual/accessibility/performance adapter inside this module must
/// create it only after authenticating the producer artifact(s) that back the exact defect. Keeping
/// the whole defect plus all referenced evidence in the binding prevents a trusted receipt from
/// being replayed onto caller-rewritten severity/category/summary or another project revision.
public struct ForgePlaytestAuthenticatedDefectBinding: Hashable, Sendable {
    public let project: ForgePlaytestProjectRevision
    public let journeyID: String
    public let defect: ForgePlaytestDefect
    public let supportingEvidence: [ForgePlaytestEvidenceReference]

    init(
        project: ForgePlaytestProjectRevision,
        journeyID: String,
        defect: ForgePlaytestDefect,
        supportingEvidence: [ForgePlaytestEvidenceReference]
    ) throws {
        let normalizedJourneyID = try ForgePlaytestValidation.stableValue(
            journeyID,
            field: "defectBinding.journeyID",
            maximum: 160
        )
        var receiptIDs = Set<String>()
        for reference in supportingEvidence {
            guard reference.project.projectID == project.projectID else {
                throw ForgePlaytestExecutionGateError.defectEvidenceBindingProjectMismatch(
                    journeyID: normalizedJourneyID,
                    defectID: defect.defectID
                )
            }
            guard reference.project.sourceRevision == project.sourceRevision else {
                throw ForgePlaytestExecutionGateError.defectEvidenceBindingSourceRevisionMismatch(
                    journeyID: normalizedJourneyID,
                    defectID: defect.defectID
                )
            }
            guard reference.journeyID == normalizedJourneyID else {
                throw ForgePlaytestExecutionGateError.defectEvidenceBindingJourneyMismatch(
                    journeyID: normalizedJourneyID,
                    defectID: defect.defectID
                )
            }
            guard receiptIDs.insert(reference.receiptID).inserted else {
                throw ForgePlaytestExecutionGateError.defectEvidenceBindingEvidenceMismatch(
                    journeyID: normalizedJourneyID,
                    defectID: defect.defectID
                )
            }
        }
        guard receiptIDs == defect.evidenceReceiptIDs else {
            throw ForgePlaytestExecutionGateError.defectEvidenceBindingEvidenceMismatch(
                journeyID: normalizedJourneyID,
                defectID: defect.defectID
            )
        }

        self.project = project
        self.journeyID = normalizedJourneyID
        self.defect = defect
        self.supportingEvidence = supportingEvidence.sorted { $0.receiptID < $1.receiptID }
    }
}

private struct ForgePlaytestDefectBindingKey: Hashable {
    let journeyID: String
    let defectID: String
}

public extension ForgePlaytestGateEvaluator {
    /// Public evidence gate for downstream runtime/mission integration.
    ///
    /// Every result that claims runtime execution must have one exact binding supplied by the
    /// canonical runtime adapter. The binding must point at the same execution evidence reference
    /// carried by the result and must reproduce the complete validated planned trace value.
    /// Results without runtime-execution evidence (for example, a pre-launch failed journey) must
    /// not be given a synthetic execution binding.
    ///
    /// Every high/critical defect that can steer `.repairRequired` must also carry one exact,
    /// non-forgeable `ForgePlaytestAuthenticatedDefectBinding`. Opaque receipt IDs and public defect
    /// metadata alone therefore fail closed instead of becoming autonomous repair authority.
    static func evaluate(
        project: ForgePlaytestProjectRevision,
        policy: ForgePlaytestAcceptancePolicy,
        plans: [ForgePlaytestJourneyPlan],
        results: [ForgePlaytestJourneyResult],
        executionBindings: [ForgePlaytestExecutionBinding],
        defectEvidenceBindings: [ForgePlaytestAuthenticatedDefectBinding] = []
    ) throws -> ForgePlaytestGateVerdict {
        var plansByJourneyID: [String: ForgePlaytestJourneyPlan] = [:]
        for plan in plans {
            plansByJourneyID[plan.journeyID] = plan
        }

        var bindingsByJourneyID: [String: ForgePlaytestExecutionBinding] = [:]
        for binding in executionBindings {
            let journeyID = binding.executionEvidence.journeyID
            guard binding.executionEvidence.project.projectID == project.projectID else {
                throw ForgePlaytestExecutionGateError.bindingProjectMismatch(journeyID)
            }
            guard binding.executionEvidence.project.sourceRevision == project.sourceRevision else {
                throw ForgePlaytestExecutionGateError.bindingSourceRevisionMismatch(journeyID)
            }
            guard bindingsByJourneyID.updateValue(binding, forKey: journeyID) == nil else {
                throw ForgePlaytestExecutionGateError.duplicateBinding(journeyID)
            }
        }

        var consumedBindings = Set<String>()
        var globalReceiptIDs = Set<String>()
        for result in results {
            for reference in result.evidence {
                guard globalReceiptIDs.insert(reference.receiptID).inserted else {
                    throw ForgePlaytestError.duplicateReceiptID(reference.receiptID)
                }
            }
            let executionEvidence = result.evidence.filter { $0.kind == .runtimeExecution }
            if executionEvidence.isEmpty {
                if bindingsByJourneyID[result.journeyID] != nil {
                    throw ForgePlaytestExecutionGateError.unexpectedBinding(result.journeyID)
                }
                continue
            }
            guard executionEvidence.count == 1 else {
                throw ForgePlaytestExecutionGateError.ambiguousExecutionEvidence(result.journeyID)
            }
            guard let binding = bindingsByJourneyID[result.journeyID] else {
                throw ForgePlaytestExecutionGateError.missingBinding(result.journeyID)
            }
            guard binding.executionEvidence == executionEvidence[0] else {
                throw ForgePlaytestExecutionGateError.executionEvidenceMismatch(result.journeyID)
            }
            guard let plan = plansByJourneyID[result.journeyID], binding.trace == plan.trace else {
                throw ForgePlaytestExecutionGateError.executionTraceMismatch(result.journeyID)
            }
            consumedBindings.insert(result.journeyID)
        }

        if let unexpected = bindingsByJourneyID.keys
            .filter({ !consumedBindings.contains($0) })
            .sorted()
            .first {
            throw ForgePlaytestExecutionGateError.unexpectedBinding(unexpected)
        }

        var defectBindingsByKey: [ForgePlaytestDefectBindingKey: ForgePlaytestAuthenticatedDefectBinding] = [:]
        for binding in defectEvidenceBindings {
            let key = ForgePlaytestDefectBindingKey(
                journeyID: binding.journeyID,
                defectID: binding.defect.defectID
            )
            guard binding.project.projectID == project.projectID else {
                throw ForgePlaytestExecutionGateError.defectEvidenceBindingProjectMismatch(
                    journeyID: key.journeyID,
                    defectID: key.defectID
                )
            }
            guard binding.project.sourceRevision == project.sourceRevision else {
                throw ForgePlaytestExecutionGateError.defectEvidenceBindingSourceRevisionMismatch(
                    journeyID: key.journeyID,
                    defectID: key.defectID
                )
            }
            guard defectBindingsByKey.updateValue(binding, forKey: key) == nil else {
                throw ForgePlaytestExecutionGateError.duplicateDefectEvidenceBinding(
                    journeyID: key.journeyID,
                    defectID: key.defectID
                )
            }

            guard let result = results.first(where: { $0.journeyID == key.journeyID }),
                  let defect = result.defects.first(where: { $0.defectID == key.defectID }),
                  defect == binding.defect
            else {
                throw ForgePlaytestExecutionGateError.defectEvidenceBindingDefectMismatch(
                    journeyID: key.journeyID,
                    defectID: key.defectID
                )
            }
            let expectedSupportingEvidence = Set(result.evidence.filter {
                defect.evidenceReceiptIDs.contains($0.receiptID)
            })
            guard expectedSupportingEvidence == Set(binding.supportingEvidence) else {
                throw ForgePlaytestExecutionGateError.defectEvidenceBindingEvidenceMismatch(
                    journeyID: key.journeyID,
                    defectID: key.defectID
                )
            }
        }

        var consumedDefectBindings = Set<ForgePlaytestDefectBindingKey>()
        for result in results {
            for defect in result.defects where defect.severity >= policy.repairThreshold {
                let key = ForgePlaytestDefectBindingKey(
                    journeyID: result.journeyID,
                    defectID: defect.defectID
                )
                guard defectBindingsByKey[key] != nil else {
                    throw ForgePlaytestExecutionGateError.missingDefectEvidenceBinding(
                        journeyID: key.journeyID,
                        defectID: key.defectID
                    )
                }
                consumedDefectBindings.insert(key)
            }
        }

        if let unexpected = defectBindingsByKey.keys
            .filter({ !consumedDefectBindings.contains($0) })
            .sorted(by: {
                if $0.journeyID != $1.journeyID { return $0.journeyID < $1.journeyID }
                return $0.defectID < $1.defectID
            })
            .first {
            throw ForgePlaytestExecutionGateError.unexpectedDefectEvidenceBinding(
                journeyID: unexpected.journeyID,
                defectID: unexpected.defectID
            )
        }

        return try evaluate(
            project: project,
            policy: policy,
            plans: plans,
            results: results
        )
    }
}
