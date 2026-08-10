/// Transient module-owned authentication of one complete qualification evidence value.
///
/// Raw `LocalModelQualificationEvidence` remains Codable candidate transport. This binding is intentionally
/// non-Codable, retains the whole evidence value, and has no public initializer, so ordinary module consumers
/// cannot turn persisted/model-authored evidence into qualification authority.
public struct LocalModelQualificationTrustBinding: Hashable, Sendable {
    let authenticatedEvidence: LocalModelQualificationEvidence

    init(authenticatedEvidence: LocalModelQualificationEvidence) {
        self.authenticatedEvidence = authenticatedEvidence
    }
}

public extension LocalModelQualificationRecord {
    /// Evaluates qualification only from module-owned bindings over exact whole-evidence values.
    /// A binding for the same evidence ID with any changed subject/source/authority/status/payload does not match.
    func readiness(
        for claim: LocalModelQualificationClaim,
        trustedBindings: Set<LocalModelQualificationTrustBinding>
    ) -> LocalModelQualificationReadiness {
        let authenticatedEvidence = Set(trustedBindings.map(\.authenticatedEvidence))
        return readiness(for: claim, trustedEvidence: authenticatedEvidence)
    }
}
