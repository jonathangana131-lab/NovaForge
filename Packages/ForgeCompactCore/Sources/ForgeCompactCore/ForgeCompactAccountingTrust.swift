import Foundation

/// Exact subject the host authenticated for one accounting measurement.
///
/// This type is intentionally non-Codable. Durable `ForgeCompactAccountingReceipt` bytes remain
/// evidence candidates, not trusted state. A host should create/store a binding only after it has
/// authenticated the external measurement that produced the receipt.
public struct ForgeCompactAccountingTrustBinding: Hashable, Sendable {
    public let schemaVersion: Int
    public let measurementReceiptID: String
    public let authority: ProjectCapsuleAuthority
    public let selectedItemIDs: [String]
    public let baselineIdentity: ForgeCompactAccountingBaselineIdentity
    public let basis: ForgeCompactAccountingBasis
    public let provenance: ForgeCompactAccountingProvenance
    public let baselineUTF8Bytes: UInt64
    public let capsuleUTF8Bytes: UInt64
    public let baselineUnits: UInt64
    public let capsuleUnits: UInt64

    /// Captures the complete subject of a receipt the host has already authenticated.
    /// Constructing this value does not itself authenticate the receipt.
    public init(authenticatedReceipt receipt: ForgeCompactAccountingReceipt) {
        schemaVersion = receipt.schemaVersion
        measurementReceiptID = receipt.measurementReceiptID
        authority = receipt.authority
        selectedItemIDs = receipt.selectedItemIDs
        baselineIdentity = receipt.baselineIdentity
        basis = receipt.basis
        provenance = receipt.provenance
        baselineUTF8Bytes = receipt.baselineUTF8Bytes
        capsuleUTF8Bytes = receipt.capsuleUTF8Bytes
        baselineUnits = receipt.baselineUnits
        capsuleUnits = receipt.capsuleUnits
    }

    fileprivate func matches(_ receipt: ForgeCompactAccountingReceipt) -> Bool {
        schemaVersion == receipt.schemaVersion
            && measurementReceiptID == receipt.measurementReceiptID
            && authority == receipt.authority
            && selectedItemIDs == receipt.selectedItemIDs
            && baselineIdentity == receipt.baselineIdentity
            && basis == receipt.basis
            && provenance == receipt.provenance
            && baselineUTF8Bytes == receipt.baselineUTF8Bytes
            && capsuleUTF8Bytes == receipt.capsuleUTF8Bytes
            && baselineUnits == receipt.baselineUnits
            && capsuleUnits == receipt.capsuleUnits
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
