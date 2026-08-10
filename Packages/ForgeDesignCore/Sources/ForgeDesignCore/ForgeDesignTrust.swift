import Foundation

/// Complete Design DNA subject that a host has authenticated as accepted project truth.
/// This type is intentionally non-Codable; decoded bytes never restore their own trusted bit.
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
/// Structural `.userDecision` provenance is durable metadata, not this capability.
public struct DesignDNAUserMutationAuthority: Equatable, Sendable {
    private let authenticatedBefore: DesignDNA
    private let authenticatedAfter: DesignDNA
    private let authenticatedRecord: DesignDNAChangeRecord
    private let authenticatedPurpose: DesignDNAUserMutationPurpose

    init(
        authenticatedBefore: DesignDNA,
        authenticatedAfter: DesignDNA,
        authenticatedRecord: DesignDNAChangeRecord,
        purpose: DesignDNAUserMutationPurpose
    ) {
        self.authenticatedBefore = authenticatedBefore
        self.authenticatedAfter = authenticatedAfter
        self.authenticatedRecord = authenticatedRecord
        self.authenticatedPurpose = purpose
    }

    func authorizes(
        before: DesignDNA,
        after: DesignDNA,
        record: DesignDNAChangeRecord,
        purpose: DesignDNAUserMutationPurpose
    ) -> Bool {
        authenticatedBefore == before
            && authenticatedAfter == after
            && authenticatedRecord == record
            && authenticatedPurpose == purpose
    }
}

/// Non-Codable host authentication of one durable change record and its exact snapshots.
public struct DesignDNATransitionTrustBinding: Equatable, Sendable {
    private let authenticatedBefore: DesignDNA
    private let authenticatedAfter: DesignDNA
    private let authenticatedRecord: DesignDNAChangeRecord

    init(
        authenticatedBefore: DesignDNA,
        authenticatedAfter: DesignDNA,
        authenticatedRecord: DesignDNAChangeRecord
    ) throws {
        try DesignDNAArchive.validateTransitionRecord(
            authenticatedRecord,
            from: authenticatedBefore,
            to: authenticatedAfter
        )
        self.authenticatedBefore = authenticatedBefore
        self.authenticatedAfter = authenticatedAfter
        self.authenticatedRecord = authenticatedRecord
    }

    func matches(
        before: DesignDNA,
        after: DesignDNA,
        record: DesignDNAChangeRecord
    ) -> Bool {
        authenticatedBefore == before
            && authenticatedAfter == after
            && authenticatedRecord == record
    }
}

public extension DesignDNA {
    func canSupportAcceptedDesignTruth(
        trustedSnapshots: [DesignDNATrustBinding]
    ) -> Bool {
        trustedSnapshots.contains { $0.matches(self) }
    }
}

public extension DesignDNAArchive {
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

        for index in changeRecords.indices {
            let before = snapshots[index]
            let after = snapshots[index + 1]
            let record = changeRecords[index]
            guard trustedTransitions.contains(where: {
                $0.matches(before: before, after: after, record: record)
            }) else {
                return false
            }
        }
        return true
    }
}
