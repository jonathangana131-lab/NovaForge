/// A byte-level context-footprint measurement derived from the exact source set used to build a
/// Project Capsule. This intentionally says UTF-8 bytes, not tokens: tokenizer-aware prompt cost is
/// a separate measurement that requires an exact tokenizer/runtime identity.
public enum ForgeCompactFootprintBasis: String, Hashable, Sendable {
    case renderedUTF8BytesV1
}

public struct ForgeCompactFootprintMeasurement: Hashable, Sendable {
    public let basis: ForgeCompactFootprintBasis
    public let authority: ProjectCapsuleAuthority
    public let budgetBytes: Int
    public let sourceItemCount: Int
    public let selectedItemCount: Int
    public let omittedItemCount: Int
    public let fullSourceRenderedUTF8Bytes: Int
    public let capsuleRenderedUTF8Bytes: Int
    public let savedRenderedUTF8Bytes: Int
    /// Integer percentage precision: 10_000 basis points == 100%. Derived from UTF-8 bytes only.
    public let reductionBasisPoints: Int

    fileprivate init(
        basis: ForgeCompactFootprintBasis,
        authority: ProjectCapsuleAuthority,
        budgetBytes: Int,
        sourceItemCount: Int,
        selectedItemCount: Int,
        omittedItemCount: Int,
        fullSourceRenderedUTF8Bytes: Int,
        capsuleRenderedUTF8Bytes: Int,
        savedRenderedUTF8Bytes: Int,
        reductionBasisPoints: Int
    ) {
        self.basis = basis
        self.authority = authority
        self.budgetBytes = budgetBytes
        self.sourceItemCount = sourceItemCount
        self.selectedItemCount = selectedItemCount
        self.omittedItemCount = omittedItemCount
        self.fullSourceRenderedUTF8Bytes = fullSourceRenderedUTF8Bytes
        self.capsuleRenderedUTF8Bytes = capsuleRenderedUTF8Bytes
        self.savedRenderedUTF8Bytes = savedRenderedUTF8Bytes
        self.reductionBasisPoints = reductionBasisPoints
    }
}

/// Couples the accepted capsule bytes to the measurement derived during the same build operation.
/// It is intentionally not Codable: persisted benchmark evidence must retain its own accepted source
/// set identity rather than treating a serialized derived percentage as authority.
public struct ForgeCompactMeasuredCapsule: Hashable, Sendable {
    public let capsule: ProjectCapsule
    public let footprint: ForgeCompactFootprintMeasurement

    fileprivate init(capsule: ProjectCapsule, footprint: ForgeCompactFootprintMeasurement) {
        self.capsule = capsule
        self.footprint = footprint
    }
}

public enum ForgeCompactFootprintMeasurementError: Error, Equatable, Sendable {
    case arithmeticOverflow
    case capsuleExceedsSourceFootprint
    case inconsistentSourceItemCount
}

public enum ForgeCompactFootprintMeasurer {
    /// Builds the capsule and derives its byte-level reduction from the exact same source item set.
    /// Callers cannot supply a baseline byte count or an already-built capsule, preventing a stale or
    /// substituted omitted payload from inflating the reported reduction.
    public static func buildAndMeasure(
        authority: ProjectCapsuleAuthority,
        items: [ForgeCompactContextItem],
        budgetBytes: Int
    ) throws -> ForgeCompactMeasuredCapsule {
        let fullSourceBytes = try renderedUTF8Bytes(for: items)
        let capsule = try ProjectCapsuleBuilder.build(
            authority: authority,
            items: items,
            budgetBytes: budgetBytes
        )

        guard capsule.sourceItemCount == items.count,
              capsule.selectedItems.count + capsule.omittedItems.count == items.count
        else {
            throw ForgeCompactFootprintMeasurementError.inconsistentSourceItemCount
        }
        guard capsule.renderedUTF8Bytes <= fullSourceBytes else {
            throw ForgeCompactFootprintMeasurementError.capsuleExceedsSourceFootprint
        }

        let savedBytes = fullSourceBytes - capsule.renderedUTF8Bytes
        let basisPoints = reductionBasisPoints(savedBytes: savedBytes, baselineBytes: fullSourceBytes)
        let footprint = ForgeCompactFootprintMeasurement(
            basis: .renderedUTF8BytesV1,
            authority: capsule.authority,
            budgetBytes: capsule.budgetBytes,
            sourceItemCount: capsule.sourceItemCount,
            selectedItemCount: capsule.selectedItems.count,
            omittedItemCount: capsule.omittedItems.count,
            fullSourceRenderedUTF8Bytes: fullSourceBytes,
            capsuleRenderedUTF8Bytes: capsule.renderedUTF8Bytes,
            savedRenderedUTF8Bytes: savedBytes,
            reductionBasisPoints: basisPoints
        )
        return ForgeCompactMeasuredCapsule(capsule: capsule, footprint: footprint)
    }

    private static func renderedUTF8Bytes(for items: [ForgeCompactContextItem]) throws -> Int {
        var total = 0
        for (index, item) in items.enumerated() {
            if index > 0 {
                let (next, overflow) = total.addingReportingOverflow(1)
                guard !overflow else { throw ForgeCompactFootprintMeasurementError.arithmeticOverflow }
                total = next
            }
            let (next, overflow) = total.addingReportingOverflow(item.renderedUTF8Bytes)
            guard !overflow else { throw ForgeCompactFootprintMeasurementError.arithmeticOverflow }
            total = next
        }
        return total
    }

    private static func reductionBasisPoints(savedBytes: Int, baselineBytes: Int) -> Int {
        guard baselineBytes > 0 else { return 0 }
        guard savedBytes < baselineBytes else { return 10_000 }

        // Use a 128-bit intermediate so a very large valid source footprint cannot overflow merely
        // while deriving the display-safe integer ratio.
        let dividend = UInt64(savedBytes).multipliedFullWidth(by: 10_000)
        let quotient = UInt64(baselineBytes).dividingFullWidth(dividend).quotient
        return Int(quotient)
    }
}
