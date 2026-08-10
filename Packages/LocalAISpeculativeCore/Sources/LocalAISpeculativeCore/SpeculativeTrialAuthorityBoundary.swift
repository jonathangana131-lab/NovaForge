/// Structural candidate-shape information only. This type never represents host/runtime authority.
public enum SpeculativeTrialAssessmentAuthority: String, Sendable {
    case researchCandidateShapeOnly
}

public extension SpeculativeTrialEligibility {
    /// Preferred name for the legacy `isEligible` value: the result is only structural candidate shape.
    var isStructurallyEligible: Bool { isEligible }

    /// Public candidate metadata can never authorize speculative execution by itself.
    var authorizesExecution: Bool { false }

    /// Makes the structural-only authority class explicit to downstream callers.
    var authority: SpeculativeTrialAssessmentAuthority { .researchCandidateShapeOnly }
}
