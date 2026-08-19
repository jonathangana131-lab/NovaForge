import Foundation

/// Transient proof that one complete repair campaign was authenticated by canonical product owners.
///
/// The trusted subject deliberately includes the whole campaign: defect identity/evidence, known-good
/// checkpoint, repair policy, every before/after scorecard, candidate/source revision, and verification
/// receipt IDs. Its initializer is module-owned and the type is non-Codable, so persisted/model-shaped
/// campaign data cannot promote itself into repair execution authority after relaunch.
public struct ForgeRepairTrustedCampaign: Equatable, Sendable {
    public let campaign: RepairCampaign

    init(authenticatedCampaign: RepairCampaign) {
        self.campaign = authenticatedCampaign
    }
}

/// Authoritative next-step projection derived only from a trusted complete campaign.
/// This value is non-Codable and has no public initializer. It still does not mutate a project,
/// authenticate receipts, or transition the canonical Mission by itself.
public struct ForgeRepairTrustedAssessment: Equatable, Sendable {
    public let campaign: RepairCampaign
    public let assessment: RepairAssessment

    public var nextAction: RepairNextAction {
        assessment.nextAction
    }

    public var candidateRevisionID: RepairRevisionID? {
        assessment.candidateRevisionID
    }

    init(campaign: RepairCampaign) {
        self.campaign = campaign
        self.assessment = campaign.assess()
    }
}

/// Public consumption boundary for canonical adapters after they have authenticated and minted a
/// `ForgeRepairTrustedCampaign` inside the package trust boundary. Ordinary imports cannot create
/// that input from candidate/archive values alone.
public enum ForgeRepairAuthority {
    public static func assess(
        _ trustedCampaign: ForgeRepairTrustedCampaign
    ) -> ForgeRepairTrustedAssessment {
        ForgeRepairTrustedAssessment(campaign: trustedCampaign.campaign)
    }
}
