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
}

public extension ForgePlaytestGateEvaluator {
    /// Public evidence gate for downstream runtime/mission integration.
    ///
    /// Every result that claims runtime execution must have one exact binding supplied by the
    /// canonical runtime adapter. The binding must point at the same execution evidence reference
    /// carried by the result and must reproduce the complete validated planned trace value.
    /// Results without runtime-execution evidence (for example, a pre-launch failed journey) must
    /// not be given a synthetic binding.
    static func evaluate(
        project: ForgePlaytestProjectRevision,
        policy: ForgePlaytestAcceptancePolicy,
        plans: [ForgePlaytestJourneyPlan],
        results: [ForgePlaytestJourneyResult],
        executionBindings: [ForgePlaytestExecutionBinding]
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
        for result in results {
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

        return try evaluate(
            project: project,
            policy: policy,
            plans: plans,
            results: results
        )
    }
}
