import Foundation

/// Exact host-authenticated binding for one complete qualification evidence value.
///
/// Public/Codable `LocalModelQualificationEvidence` remains candidate data. This receipt is intentionally
/// non-Codable and its initializer is module-internal so persisted/model-shaped values cannot promote
/// themselves merely by spelling `physicalDevice`, `deterministicHarness`, and `passed`.
/// A canonical producer adapter inside this module must mint the receipt only after independently
/// authenticating the complete evidence subject.
public struct LocalModelTrustedEvidenceReceipt: Hashable, Sendable {
    fileprivate let authenticatedEvidence: LocalModelQualificationEvidence

    public var evidenceID: String { authenticatedEvidence.evidenceID }
    public var subject: LocalModelQualificationSubject { authenticatedEvidence.subject }
    public var evidenceClass: LocalModelEvidenceClass { authenticatedEvidence.evidenceClass }
    public var source: LocalModelEvidenceSource { authenticatedEvidence.source }
    public var authority: LocalModelEvidenceAuthority { authenticatedEvidence.authority }
    public var status: LocalModelEvidenceStatus { authenticatedEvidence.status }

    init(authenticatedEvidence: LocalModelQualificationEvidence) {
        self.authenticatedEvidence = authenticatedEvidence
    }

    fileprivate func exactlyMatches(_ evidence: LocalModelQualificationEvidence) -> Bool {
        authenticatedEvidence == evidence
    }
}

/// Unforgeable promotion result for one exact record revision and claim.
///
/// This is the authority downstream mission routing should consume. It is deliberately non-Codable and
/// has no public initializer. `LocalModelQualificationReadiness` remains useful diagnostic output, but a
/// Boolean readiness value alone is not qualification authority.
public struct LocalModelQualifiedClaimReceipt: Equatable, Sendable {
    public let claim: LocalModelQualificationClaim
    public let subject: LocalModelQualificationSubject
    public let recordRevision: Int
    public let authenticatedEvidenceIDs: [String]

    fileprivate init(
        claim: LocalModelQualificationClaim,
        subject: LocalModelQualificationSubject,
        recordRevision: Int,
        authenticatedEvidenceIDs: [String]
    ) {
        self.claim = claim
        self.subject = subject
        self.recordRevision = recordRevision
        self.authenticatedEvidenceIDs = authenticatedEvidenceIDs
    }
}

/// Diagnostic readiness plus optional opaque promotion authority.
/// External callers may inspect this value, but cannot construct an accepted claim receipt themselves.
public struct LocalModelQualificationTrustDecision: Equatable, Sendable {
    public let readiness: LocalModelQualificationReadiness
    public let acceptedClaim: LocalModelQualifiedClaimReceipt?

    fileprivate init(
        readiness: LocalModelQualificationReadiness,
        acceptedClaim: LocalModelQualifiedClaimReceipt?
    ) {
        self.readiness = readiness
        self.acceptedClaim = acceptedClaim
    }
}

public extension LocalModelQualificationRecord {
    /// Evaluates qualification against opaque host-authenticated evidence bindings.
    ///
    /// Only `acceptedClaim` is promotion authority. A caller-shaped public evidence set cannot reach this
    /// path because it cannot mint `LocalModelTrustedEvidenceReceipt` values outside this module.
    func trustDecision(
        for claim: LocalModelQualificationClaim,
        authenticatedEvidence: Set<LocalModelTrustedEvidenceReceipt>
    ) -> LocalModelQualificationTrustDecision {
        let trustedValues = Set(
            authenticatedEvidence.map { $0.authenticatedEvidence }
        )
        let readiness = readiness(for: claim, trustedEvidence: trustedValues)

        guard readiness.isQualified else {
            return .init(readiness: readiness, acceptedClaim: nil)
        }

        let matchedIDs = evidence.compactMap { candidate -> String? in
            authenticatedEvidence.contains(where: { $0.exactlyMatches(candidate) })
                ? candidate.evidenceID
                : nil
        }.sorted()

        return .init(
            readiness: readiness,
            acceptedClaim: .init(
                claim: claim,
                subject: subject,
                recordRevision: revision,
                authenticatedEvidenceIDs: matchedIDs
            )
        )
    }
}
