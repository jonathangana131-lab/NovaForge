import Foundation

/// Exact subject the host authenticated for one accounting measurement.
///
/// This type is intentionally non-Codable. Durable `ForgeCompactAccountingReceipt` bytes remain
/// evidence candidates, not trusted state. Only a canonical producer inside ForgeCompactCore may
/// construct a binding after authenticating the complete external measurement subject.
public struct ForgeCompactAccountingTrustBinding: Hashable, Sendable {
    /// Keep the complete validated receipt as the authenticated subject so future receipt fields
    /// automatically participate in equality/matching instead of depending on a hand-maintained
    /// trust-field checklist.
    private let authenticatedReceipt: ForgeCompactAccountingReceipt

    // Preserve the inspection surface introduced by the original trust binding without making these
    // projections the authorization comparison. The complete receipt above remains authoritative.
    public var schemaVersion: Int { authenticatedReceipt.schemaVersion }
    public var measurementReceiptID: String { authenticatedReceipt.measurementReceiptID }
    public var authority: ProjectCapsuleAuthority { authenticatedReceipt.authority }
    public var selectedItemIDs: [String] { authenticatedReceipt.selectedItemIDs }
    public var baselineIdentity: ForgeCompactAccountingBaselineIdentity { authenticatedReceipt.baselineIdentity }
    public var basis: ForgeCompactAccountingBasis { authenticatedReceipt.basis }
    public var provenance: ForgeCompactAccountingProvenance { authenticatedReceipt.provenance }
    public var baselineUTF8Bytes: UInt64 { authenticatedReceipt.baselineUTF8Bytes }
    public var capsuleUTF8Bytes: UInt64 { authenticatedReceipt.capsuleUTF8Bytes }
    public var baselineUnits: UInt64 { authenticatedReceipt.baselineUnits }
    public var capsuleUnits: UInt64 { authenticatedReceipt.capsuleUnits }

    /// Package-owned producer seam. Constructing this value is intentionally unavailable to ordinary
    /// imports because caller-shaped/Codable accounting receipts are candidate data, not authentication.
    init(authenticatedReceipt receipt: ForgeCompactAccountingReceipt) {
        authenticatedReceipt = receipt
    }

    public static func == (
        lhs: ForgeCompactAccountingTrustBinding,
        rhs: ForgeCompactAccountingTrustBinding
    ) -> Bool {
        lhs.authenticatedReceipt == rhs.authenticatedReceipt
    }

    public func hash(into hasher: inout Hasher) {
        // Hashing is only a Set indexing aid; authorization is always whole-receipt equality.
        // A deliberately sparse hash means future receipt fields cannot be accidentally omitted
        // from trust semantics. Distinct same-ID subjects may collide, but Set equality keeps them
        // distinct and `matches` still compares the complete authenticated receipt.
        hasher.combine(authenticatedReceipt.schemaVersion)
        hasher.combine(authenticatedReceipt.measurementReceiptID)
    }

    fileprivate func matches(_ receipt: ForgeCompactAccountingReceipt) -> Bool {
        authenticatedReceipt == receipt
    }
}

public extension ForgeCompactAccountingReceipt {
    /// Product-facing exact-token claims require both structurally exact tokenizer provenance and
    /// a host-authenticated binding for this complete receipt subject. A trusted receipt ID alone is
    /// insufficient because IDs can be copied onto a different decoded receipt.
    func canSupportExactTokenCountClaim(
        trustedMeasurements: Set<ForgeCompactAccountingTrustBinding>
    ) -> Bool {
        hasExactTokenizerProvenance
            && trustedMeasurements.contains { $0.matches(self) }
    }

    @available(
        *,
        unavailable,
        message: "Bare receipt IDs do not bind the authenticated accounting subject. Use canSupportExactTokenCountClaim(trustedMeasurements:) with ForgeCompactAccountingTrustBinding."
    )
    func canSupportExactTokenCountClaim(
        trustedMeasurementReceiptIDs: Set<String>
    ) -> Bool {
        false
    }
}
