import XCTest
@testable import ForgeCompactCore

final class ForgeCompactAccountingTrustTests: XCTestCase {
    func testExactTokenizerClaimRequiresExactTrustedMeasurementReceipt() throws {
        let receipt = try makeReceipt(provenance: .runtimeTokenizer)

        XCTAssertFalse(
            receipt.canSupportExactTokenCountClaim(trustedMeasurementReceipts: [])
        )
        XCTAssertTrue(
            receipt.canSupportExactTokenCountClaim(trustedMeasurementReceipts: [receipt])
        )
    }

    func testSameTrustedReceiptIDCannotAuthorizeDifferentTokenizerRevision() throws {
        let trusted = try makeReceipt(
            provenance: .runtimeTokenizer,
            counter: ExactCounter(provenance: .runtimeTokenizer, tokenizerRevision: "rev-1")
        )
        let replay = try makeReceipt(
            provenance: .runtimeTokenizer,
            counter: ExactCounter(provenance: .runtimeTokenizer, tokenizerRevision: "rev-2")
        )

        XCTAssertEqual(trusted.measurementReceiptID, replay.measurementReceiptID)
        XCTAssertNotEqual(trusted.basis, replay.basis)
        XCTAssertFalse(
            replay.canSupportExactTokenCountClaim(trustedMeasurementReceipts: [trusted])
        )
    }

    func testSameTrustedReceiptIDCannotAuthorizeDifferentBaselineRevision() throws {
        let trusted = try makeReceipt(
            provenance: .runtimeTokenizer,
            baselineIdentity: .init(contextID: "raw-history", contextRevision: "history-r1")
        )
        let replay = try makeReceipt(
            provenance: .runtimeTokenizer,
            baselineIdentity: .init(contextID: "raw-history", contextRevision: "history-r2")
        )

        XCTAssertEqual(trusted.measurementReceiptID, replay.measurementReceiptID)
        XCTAssertNotEqual(trusted.baselineIdentity, replay.baselineIdentity)
        XCTAssertFalse(
            replay.canSupportExactTokenCountClaim(trustedMeasurementReceipts: [trusted])
        )
    }

    func testSameTrustedReceiptIDCannotAuthorizeDifferentCounts() throws {
        let trusted = try makeReceipt(
            provenance: .runtimeTokenizer,
            counter: ExactCounter(provenance: .runtimeTokenizer, baselineUnits: 20, capsuleUnits: 8)
        )
        let replay = try makeReceipt(
            provenance: .runtimeTokenizer,
            counter: ExactCounter(provenance: .runtimeTokenizer, baselineUnits: 200, capsuleUnits: 1)
        )

        XCTAssertEqual(trusted.measurementReceiptID, replay.measurementReceiptID)
        XCTAssertNotEqual(trusted.baselineUnits, replay.baselineUnits)
        XCTAssertNotEqual(trusted.capsuleUnits, replay.capsuleUnits)
        XCTAssertFalse(
            replay.canSupportExactTokenCountClaim(trustedMeasurementReceipts: [trusted])
        )
    }

    func testModelReportedExactTokenizerValueCannotClaimExactTokensEvenWhenExactReceiptIsTrusted() throws {
        let receipt = try makeReceipt(provenance: .modelReported)

        XCTAssertFalse(
            receipt.canSupportExactTokenCountClaim(trustedMeasurementReceipts: [receipt])
        )
    }

    func testHeuristicCannotClaimExactTokensEvenWhenExactReceiptIsTrusted() throws {
        let capsule = try makeCapsule()
        let counter = HeuristicCounter()
        let receipt = try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE raw context",
            baselineIdentity: try baselineIdentity(),
            capsule: capsule,
            counter: counter
        )

        XCTAssertFalse(
            receipt.canSupportExactTokenCountClaim(trustedMeasurementReceipts: [receipt])
        )
    }

    private func makeReceipt(
        provenance: ForgeCompactAccountingProvenance,
        baselineIdentity: ForgeCompactAccountingBaselineIdentity? = nil,
        counter: ExactCounter? = nil
    ) throws -> ForgeCompactAccountingReceipt {
        let capsule = try makeCapsule()
        let selectedCounter = counter ?? ExactCounter(provenance: provenance)
        let selectedBaselineIdentity: ForgeCompactAccountingBaselineIdentity
        if let baselineIdentity {
            selectedBaselineIdentity = baselineIdentity
        } else {
            selectedBaselineIdentity = try self.baselineIdentity()
        }

        return try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE raw context",
            baselineIdentity: selectedBaselineIdentity,
            capsule: capsule,
            counter: selectedCounter
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
    let measurementReceiptID: String
    let tokenizerID: String
    let tokenizerRevision: String
    let baselineUnits: UInt64
    let capsuleUnits: UInt64

    init(
        provenance: ForgeCompactAccountingProvenance,
        measurementReceiptID: String = "measurement-001",
        tokenizerID: String = "tokenizer-a",
        tokenizerRevision: String = "rev-1",
        baselineUnits: UInt64 = 20,
        capsuleUnits: UInt64 = 8
    ) {
        self.provenance = provenance
        self.measurementReceiptID = measurementReceiptID
        self.tokenizerID = tokenizerID
        self.tokenizerRevision = tokenizerRevision
        self.baselineUnits = baselineUnits
        self.capsuleUnits = capsuleUnits
    }

    var basis: ForgeCompactAccountingBasis {
        try! ForgeCompactAccountingBasis.exactTokenizer(
            tokenizerID: tokenizerID,
            tokenizerRevision: tokenizerRevision
        )
    }

    func countUnits(in text: String) throws -> UInt64 {
        text.contains("BASELINE") ? baselineUnits : capsuleUnits
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
