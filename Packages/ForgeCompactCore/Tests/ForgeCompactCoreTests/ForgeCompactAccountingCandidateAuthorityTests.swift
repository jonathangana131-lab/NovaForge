import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactAccountingCandidateAuthorityTests: XCTestCase {
    func testDecodedExactTokenizerReceiptCannotSelfAuthorizeExactTokenClaim() throws {
        let capsule = try makeCapsule()
        let receipt = try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE candidate context",
            baselineIdentity: try .init(
                contextID: "raw-history",
                contextRevision: "history-r1"
            ),
            capsule: capsule,
            counter: CandidateExactCounter()
        )
        let decoded = try JSONDecoder().decode(
            ForgeCompactAccountingReceipt.self,
            from: JSONEncoder().encode(receipt)
        )

        XCTAssertTrue(decoded.hasExactTokenizerProvenance)
        XCTAssertFalse(
            decoded.canSupportExactTokenCountClaim(trustedMeasurements: []),
            "Decoded candidate evidence must not authorize an exact-token claim without package-owned trust"
        )
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
            content: "Keep decoded accounting evidence candidate-only.",
            provenance: ForgeCompactProvenance(
                kind: .source,
                reference: "mission/objective"
            ),
            isAuthoritative: true
        )
        return try ProjectCapsuleBuilder.build(
            authority: authority,
            items: [item],
            budgetBytes: 4_096
        )
    }
}

private struct CandidateExactCounter: ForgeCompactContextCounter {
    let provenance: ForgeCompactAccountingProvenance = .runtimeTokenizer
    let measurementReceiptID = "candidate-measurement-001"
    let basis = try! ForgeCompactAccountingBasis.exactTokenizer(
        tokenizerID: "tokenizer-a",
        tokenizerRevision: "rev-1"
    )

    func countUnits(in text: String) throws -> UInt64 {
        text.contains("BASELINE") ? 20 : 8
    }
}
