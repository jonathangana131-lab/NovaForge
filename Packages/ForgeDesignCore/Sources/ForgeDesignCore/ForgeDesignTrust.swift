import Foundation

/// Complete Design DNA subject that a host has authenticated as accepted project truth.
///
/// This type is intentionally non-Codable. Persisted `DesignDNA` remains durable evidence, but
/// restoring bytes must never restore a trusted bit. Only package-owned authenticated adapters may
/// construct a binding; external consumers cannot mint accepted Design DNA authority from candidate
/// bytes merely by calling an initializer.
public struct DesignDNATrustBinding: Equatable, Sendable {
    private let authenticatedSnapshot: DesignDNA

    /// Inspection projections only. Authorization always compares `authenticatedSnapshot` as a
    /// whole value so future semantically relevant `DesignDNA` fields automatically participate.
    public var schemaVersion: Int { authenticatedSnapshot.schemaVersion }
    public var projectID: DesignProjectID { authenticatedSnapshot.projectID }
    public var revision: Int { authenticatedSnapshot.revision }
    public var intentCore: IntentCore { authenticatedSnapshot.intentCore }
    public var rules: [DesignRule] { authenticatedSnapshot.rules }
    public var protectedComponents: [ProtectedDesignComponent] { authenticatedSnapshot.protectedComponents }
    public var neverRules: [NeverRule] { authenticatedSnapshot.neverRules }
    public var lastChangeReceiptID: DesignReceiptID { authenticatedSnapshot.lastChangeReceiptID }
    public var updatedAt: Date { authenticatedSnapshot.updatedAt }

    /// Package-owned construction seam for a snapshot already authenticated by a canonical host
    /// adapter. Keeping this initializer internal prevents ordinary external callers from turning
    /// serialized/model-authored candidate state into accepted truth by assertion alone.
    init(authenticatedSnapshot snapshot: DesignDNA) {
        authenticatedSnapshot = snapshot
    }

    fileprivate func matches(_ snapshot: DesignDNA) -> Bool {
        authenticatedSnapshot == snapshot
    }
}

public extension DesignDNA {
    /// Accepted project truth requires a package-owned host-authenticated binding for this complete
    /// snapshot. Structural provenance such as `.userDecision` is evidence metadata and cannot
    /// authorize itself merely because it was constructed or decoded from persisted/model-shaped bytes.
    func canSupportAcceptedDesignTruth(
        trustedSnapshots: [DesignDNATrustBinding]
    ) -> Bool {
        trustedSnapshots.contains { $0.matches(self) }
    }
}
