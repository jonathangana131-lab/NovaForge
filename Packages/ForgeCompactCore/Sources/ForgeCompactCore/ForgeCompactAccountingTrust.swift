import Foundation

public extension ForgeCompactAccountingReceipt {
    /// Product-facing exact-token claims require both structurally exact tokenizer provenance and
    /// exact equality with a measurement receipt already authenticated by the host. A receipt ID
    /// is only a label: it cannot authorize a different tokenizer, baseline, capsule, or count.
    /// Decoding a well-shaped receipt is never sufficient by itself to enter the trusted set.
    func canSupportExactTokenCountClaim(
        trustedMeasurementReceipts: [ForgeCompactAccountingReceipt]
    ) -> Bool {
        hasExactTokenizerProvenance
            && trustedMeasurementReceipts.contains(self)
    }
}
