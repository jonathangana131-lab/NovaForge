import XCTest
@testable import ForgeCompactCore

final class ForgeCompactAccountingTrustTests: XCTestCase {
    func testExactTokenizerClaimRequiresTrustedMeasurementReceipt() throws {
        let receipt = try makeReceipt(provenance: .runtimeTokenizer)

        XCTAssertFalse(
            receipt.canSupportExactTokenCountClaim(trustedMeasurementReceiptIDs: [])
        )
        XCTAssertTrue(
            receipt.canSupportExactTokenCountClaim(
                trustedMeasurementReceiptIDs: ["measurement-001"]
            )
        )
    }

    func testModelReportedExactTokenizerValueCannotClaimExactTokensEvenWhenReceiptIDIsTrusted() throws {
        let receipt = try makeReceipt(provenance: .modelReported)

        XCTAssertFalse(
            receipt.canSupportExactTokenCountClaim(
                trustedMeasurementReceiptIDs: ["measurement-001"]
            )
        )
    }

    func testHeuristicCannotClaimExactTokensEvenWhenReceiptIDIsTrusted() throws {
        let capsule = try makeCapsule()
        let counter = HeuristicCounter()
        let receipt = try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE raw context",
            baselineIdentity: try baselineIdentity(),
            capsule: capsule,
            counter: counter
        )

        XCTAssertFalse(
            receipt.canSupportExactTokenCountClaim(
                trustedMeasurementReceiptIDs: ["measurement-heuristic"]
            )
        )
    }

    private func makeReceipt(
        provenance: ForgeCompactAccountingProvenance
    ) throws -> ForgeCompactAccountingReceipt {
        let capsule = try makeCapsule()
        let counter = ExactCounter(provenance: provenance)
        return try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE raw context",
            baselineIdentity: try baselineIdentity(),
            capsule: capsule,
            counter: counter
        )
    }

    private func baselineIdentity() throws -> ForgeCompactAccountingBaselineIdentity {
        try .init(contextID: "raw-history", contextRevision: "history-r1")
    }

    private func makeCapsule() throws -> ProjectCapsule {
        let authority = try ProjectCapsuleAuthority(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-r1",
            missionRevision: 1,
            authorityEpoch: 1,
            capsuleRevision: 1
        )
        let item = try ForgeCompactContextItem(
            id: "objective",
            sourceRevision: "source-r1",
            tier: .l0AlwaysResident,
            kind: .currentObjective,
            priority: 100,
            content: "Keep accounting truth explicit.",
            provenance: ForgeCompactProvenance(kind: .source, reference: "mission/objective"),
            isAuthoritative: true
        )
        return try ProjectCapsuleBuilder.build(
            authority: authority,
            items: [item],
            budgetBytes: 4_096
        )
    }
}

private struct ExactCounter: ForgeCompactContextCounter {
    let provenance: ForgeCompactAccountingProvenance
    let measurementReceiptID = "measurement-001"
    let basis = try! ForgeCompactAccountingBasis.exactTokenizer(
        tokenizerID: "tokenizer-a",
        tokenizerRevision: "rev-1"
    )

    func countUnits(in text: String) throws -> UInt64 {
        text.contains("BASELINE") ? 20 : 8
    }
}

private struct HeuristicCounter: ForgeCompactContextCounter {
    let provenance: ForgeCompactAccountingProvenance = .heuristicEstimator
    let measurementReceiptID = "measurement-heuristic"
    let basis = try! ForgeCompactAccountingBasis.heuristic(
        estimatorID: "chars-div-4",
        estimatorRevision: "v1"
    )

    func countUnits(in text: String) throws -> UInt64 {
        text.contains("BASELINE") ? 18 : 7
    }
}
