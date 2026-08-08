import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactAccountingTrustTests: XCTestCase {
    func testExactTokenizerClaimRequiresExactTrustedMeasurementBinding() throws {
        let receipt = try makeReceipt(provenance: .runtimeTokenizer)
        let binding = ForgeCompactAccountingTrustBinding(authenticatedReceipt: receipt)

        XCTAssertFalse(
            receipt.canSupportExactTokenCountClaim(trustedMeasurements: [])
        )
        XCTAssertTrue(
            receipt.canSupportExactTokenCountClaim(trustedMeasurements: [binding])
        )
    }

    func testSameTrustedReceiptIDCannotAuthorizeTamperedTokenCounts() throws {
        let receipt = try makeReceipt(provenance: .runtimeTokenizer)
        let binding = ForgeCompactAccountingTrustBinding(authenticatedReceipt: receipt)
        let tampered = try tamperedReceipt(receipt) { object in
            object["baselineUnits"] = 9_999
            object["capsuleUnits"] = 1
        }

        XCTAssertEqual(tampered.measurementReceiptID, receipt.measurementReceiptID)
        XCTAssertTrue(tampered.hasExactTokenizerProvenance)
        XCTAssertFalse(
            tampered.canSupportExactTokenCountClaim(trustedMeasurements: [binding])
        )
    }

    func testSameTrustedReceiptIDCannotAuthorizeDifferentTokenizerSubject() throws {
        let receipt = try makeReceipt(provenance: .runtimeTokenizer)
        let binding = ForgeCompactAccountingTrustBinding(authenticatedReceipt: receipt)
        let tampered = try tamperedReceipt(receipt) { object in
            var basis = try XCTUnwrap(object["basis"] as? [String: Any])
            basis["counterRevision"] = "rev-2"
            object["basis"] = basis
        }

        XCTAssertEqual(tampered.measurementReceiptID, receipt.measurementReceiptID)
        XCTAssertTrue(tampered.hasExactTokenizerProvenance)
        XCTAssertFalse(
            tampered.canSupportExactTokenCountClaim(trustedMeasurements: [binding])
        )
    }

    func testSameTrustedReceiptIDCannotAuthorizeDifferentCapsuleAuthority() throws {
        let receipt = try makeReceipt(provenance: .runtimeTokenizer)
        let binding = ForgeCompactAccountingTrustBinding(authenticatedReceipt: receipt)
        let tampered = try tamperedReceipt(receipt) { object in
            var authority = try XCTUnwrap(object["authority"] as? [String: Any])
            authority["capsuleRevision"] = 2
            object["authority"] = authority
        }

        XCTAssertEqual(tampered.measurementReceiptID, receipt.measurementReceiptID)
        XCTAssertTrue(tampered.hasExactTokenizerProvenance)
        XCTAssertFalse(
            tampered.canSupportExactTokenCountClaim(trustedMeasurements: [binding])
        )
    }

    func testSameTrustedReceiptIDCannotAuthorizeDifferentBaselineSnapshot() throws {
        let receipt = try makeReceipt(provenance: .runtimeTokenizer)
        let binding = ForgeCompactAccountingTrustBinding(authenticatedReceipt: receipt)
        let tampered = try tamperedReceipt(receipt) { object in
            var baseline = try XCTUnwrap(object["baselineIdentity"] as? [String: Any])
            baseline["contextRevision"] = "history-r2"
            object["baselineIdentity"] = baseline
        }

        XCTAssertEqual(tampered.measurementReceiptID, receipt.measurementReceiptID)
        XCTAssertTrue(tampered.hasExactTokenizerProvenance)
        XCTAssertFalse(
            tampered.canSupportExactTokenCountClaim(trustedMeasurements: [binding])
        )
    }

    func testModelReportedExactTokenizerValueCannotClaimExactTokensEvenWhenExactSubjectIsTrusted() throws {
        let receipt = try makeReceipt(provenance: .modelReported)
        let binding = ForgeCompactAccountingTrustBinding(authenticatedReceipt: receipt)

        XCTAssertFalse(
            receipt.canSupportExactTokenCountClaim(trustedMeasurements: [binding])
        )
    }

    func testHeuristicCannotClaimExactTokensEvenWhenExactSubjectIsTrusted() throws {
        let capsule = try makeCapsule()
        let counter = HeuristicCounter()
        let receipt = try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE raw context",
            baselineIdentity: try baselineIdentity(),
            capsule: capsule,
            counter: counter
        )
        let binding = ForgeCompactAccountingTrustBinding(authenticatedReceipt: receipt)

        XCTAssertFalse(
            receipt.canSupportExactTokenCountClaim(trustedMeasurements: [binding])
        )
    }

    private func tamperedReceipt(
        _ receipt: ForgeCompactAccountingReceipt,
        mutation: (inout [String: Any]) throws -> Void
    ) throws -> ForgeCompactAccountingReceipt {
        let encoded = try JSONEncoder().encode(receipt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        try mutation(&object)
        return try JSONDecoder().decode(
            ForgeCompactAccountingReceipt.self,
            from: JSONSerialization.data(withJSONObject: object)
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
