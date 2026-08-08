import Foundation

public extension ForgeCompactAccountingReceipt {
    /// Product-facing exact-token claims require both structurally exact tokenizer provenance and
    /// a measurement receipt authenticated by the host. Decoding a well-shaped receipt is never
    /// sufficient by itself to enter the trusted set.
    func canSupportExactTokenCountClaim(
        trustedMeasurementReceiptIDs: Set<String>
    ) -> Bool {
        hasExactTokenizerProvenance
            && trustedMeasurementReceiptIDs.contains(measurementReceiptID)
    }
}
