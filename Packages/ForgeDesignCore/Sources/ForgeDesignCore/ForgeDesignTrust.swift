import Foundation

/// Complete Design DNA subject that a host has authenticated as accepted project truth.
///
/// This type is intentionally non-Codable. Persisted `DesignDNA` remains durable evidence, but
/// restoring bytes must never restore a trusted bit. Only package-owned authenticated adapters may
/// construct a binding; external consumers cannot mint accepted Design DNA authority from candidate
/// bytes merely by calling an initializer.
public struct DesignDNATrustBinding: Equatable, Sendable {
    private let authenticatedSnapshot: DesignDNA

    public var schemaVersion: Int { authenticatedSnapshot.schemaVersion }
    public var projectID: DesignProjectID { authenticatedSnapshot.projectID }
    public var revision: Int { authenticatedSnapshot.revision }
    public var intentCore: IntentCore { authenticatedSnapshot.intentCore }
    public var rules: [DesignRule] { authenticatedSnapshot.rules }
    public var protectedComponents: [ProtectedDesignComponent] { authenticatedSnapshot.protectedComponents }
    public var neverRules: [NeverRule] { authenticatedSnapshot.neverRules }
    public var lastChangeReceiptID: DesignReceiptID { authenticatedSnapshot.lastChangeReceiptID }
    public var updatedAt: Date { authenticatedSnapshot.updatedAt }

    init(authenticatedSnapshot snapshot: DesignDNA) {
        authenticatedSnapshot = snapshot
    }

    func matches(_ snapshot: DesignDNA) -> Bool {
        authenticatedSnapshot == snapshot
    }
}

/// Purpose-bound user authority for one exact Design DNA transition.
///
/// Persisted/user-authored `.userDecision` provenance is metadata, not permission. This type is
/// intentionally non-Codable and its initializer is package-internal so ordinary consumers cannot
/// mint authority from an arbitrary receipt string. A future canonical host adapter inside this
/// package must authenticate the user decision before constructing it.
public struct DesignDNAUserMutationAuthority: Equatable, Sendable {
    private let authenticatedBefore: DesignDNA
    private let authenticatedAfter: DesignDNA
    private let authenticatedPurpose: DesignDNAUserMutationPurpose

    init(
        authenticatedBefore: DesignDNA,
        authenticatedAfter: DesignDNA,
        purpose: DesignDNAUserMutationPurpose
    ) {
        self.authenticatedBefore = authenticatedBefore
        self.authenticatedAfter = authenticatedAfter
        self.authenticatedPurpose = purpose
    }

    func authorizes(
        before: DesignDNA,
        after: DesignDNA,
        purpose: DesignDNAUserMutationPurpose
    ) -> Bool {
        authenticatedBefore == before
            && authenticatedAfter == after
            && authenticatedPurpose == purpose
    }
}

/// Authenticated link between two exact consecutive accepted Design DNA snapshots.
///
/// Durable archives remain candidate evidence after decode. Accepted history requires both whole-
/// snapshot bindings and one of these non-Codable links for every adjacent transition, preventing a
/// forged archive from replacing/downgrading/removing protected design while only increasing a
/// revision number.
public struct DesignDNATransitionTrustBinding: Equatable, Sendable {
    private let authenticatedBefore: DesignDNA
    private let authenticatedAfter: DesignDNA
    private let authenticatedKind: DesignDNATransitionKind

    init(
        authenticatedBefore: DesignDNA,
        authenticatedAfter: DesignDNA,
        kind: DesignDNATransitionKind
    ) throws {
        let validatedKind = try DesignDNAArchive.validatedTransitionKind(
            from: authenticatedBefore,
            to: authenticatedAfter
        )
        guard validatedKind == kind else {
            throw ForgeDesignValidationError.invalidArchiveTransition(
                "trusted transition kind does not match exact before/after snapshots"
            )
        }
        self.authenticatedBefore = authenticatedBefore
        self.authenticatedAfter = authenticatedAfter
        self.authenticatedKind = kind
    }

    func matches(
        before: DesignDNA,
        after: DesignDNA,
        kind: DesignDNATransitionKind
    ) -> Bool {
        authenticatedBefore == before
            && authenticatedAfter == after
            && authenticatedKind == kind
    }
}

public extension DesignDNA {
    /// Structural provenance never self-authorizes accepted truth. A whole-snapshot package-owned
    /// binding must match exactly.
    func canSupportAcceptedDesignTruth(
        trustedSnapshots: [DesignDNATrustBinding]
    ) -> Bool {
        trustedSnapshots.contains { $0.matches(self) }
    }
}

public extension DesignDNAArchive {
    /// Accepted history fails closed after relaunch unless every exact snapshot and every exact
    /// adjacent transition has been re-authenticated by the host.
    func canSupportAcceptedDesignHistory(
        trustedSnapshots: [DesignDNATrustBinding],
        trustedTransitions: [DesignDNATransitionTrustBinding]
    ) -> Bool {
        guard !snapshots.isEmpty else { return false }
        guard snapshots.allSatisfy({ snapshot in
            trustedSnapshots.contains { $0.matches(snapshot) }
        }) else {
            return false
        }

        for index in snapshots.indices.dropFirst() {
            let before = snapshots[index - 1]
            let after = snapshots[index]
            guard let kind = try? Self.validatedTransitionKind(from: before, to: after) else {
                return false
            }
            guard trustedTransitions.contains(where: {
                $0.matches(before: before, after: after, kind: kind)
            }) else {
                return false
            }
        }
        return true
    }
}
