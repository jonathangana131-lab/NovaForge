import Foundation

/// Complete Design DNA subject that a host has authenticated as accepted project truth.
///
/// This type is intentionally non-Codable. Persisted `DesignDNA` remains durable evidence, but
/// restoring bytes must never restore a trusted bit. The host should construct this binding only
/// after authenticating the receipts/decisions that make the complete snapshot authoritative.
public struct DesignDNATrustBinding: Equatable, Sendable {
    public let schemaVersion: Int
    public let projectID: DesignProjectID
    public let revision: Int
    public let intentCore: IntentCore
    public let rules: [DesignRule]
    public let protectedComponents: [ProtectedDesignComponent]
    public let neverRules: [NeverRule]
    public let lastChangeReceiptID: DesignReceiptID
    public let updatedAt: Date

    /// Captures the complete subject of a Design DNA snapshot the host has already authenticated.
    /// Constructing this value does not itself authenticate the snapshot.
    public init(authenticatedSnapshot snapshot: DesignDNA) {
        schemaVersion = snapshot.schemaVersion
        projectID = snapshot.projectID
        revision = snapshot.revision
        intentCore = snapshot.intentCore
        rules = snapshot.rules
        protectedComponents = snapshot.protectedComponents
        neverRules = snapshot.neverRules
        lastChangeReceiptID = snapshot.lastChangeReceiptID
        updatedAt = snapshot.updatedAt
    }

    fileprivate func matches(_ snapshot: DesignDNA) -> Bool {
        schemaVersion == snapshot.schemaVersion
            && projectID == snapshot.projectID
            && revision == snapshot.revision
            && intentCore == snapshot.intentCore
            && rules == snapshot.rules
            && protectedComponents == snapshot.protectedComponents
            && neverRules == snapshot.neverRules
            && lastChangeReceiptID == snapshot.lastChangeReceiptID
            && updatedAt == snapshot.updatedAt
    }
}

public extension DesignDNA {
    /// Accepted project truth requires a host-authenticated binding for this complete snapshot.
    /// Structural provenance such as `.userDecision` is evidence metadata and cannot authorize
    /// itself merely because it was constructed or decoded from persisted/model-shaped bytes.
    func canSupportAcceptedDesignTruth(
        trustedSnapshots: [DesignDNATrustBinding]
    ) -> Bool {
        trustedSnapshots.contains { $0.matches(self) }
    }
}
