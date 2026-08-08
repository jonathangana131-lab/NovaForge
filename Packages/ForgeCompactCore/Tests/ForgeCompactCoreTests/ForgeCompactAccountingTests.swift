import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactAccountingTests: XCTestCase {
    func testExactTokenizerMeasurementPreservesIdentityAndCanSupportExactTokenTruth() throws {
        let capsule = try makeCapsule()
        let counter = MarkerCounter(
            basis: try .exactTokenizer(tokenizerID: "tokenizer-a", tokenizerRevision: "rev-7"),
            provenance: .runtimeTokenizer,
            measurementReceiptID: "receipt-tokenizer-001",
            baselineUnits: 40,
            capsuleUnits: 11
        )

        let receipt = try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE raw project context",
            capsule: capsule,
            counter: counter
        )

        XCTAssertEqual(receipt.basis, try .exactTokenizer(tokenizerID: "tokenizer-a", tokenizerRevision: "rev-7"))
        XCTAssertEqual(receipt.truth, .exactTokenizerTokens)
        XCTAssertTrue(receipt.hasExactTokenizerProvenance)
        XCTAssertEqual(receipt.change, .reduced(units: 29))
        XCTAssertTrue(receipt.matches(capsule: capsule))
        XCTAssertEqual(receipt.capsuleUTF8Bytes, UInt64(capsule.renderedContext.utf8.count))
    }

    func testHeuristicMeasurementStaysEstimatedAndCannotBecomeExactTokenTruth() throws {
        let capsule = try makeCapsule()
        let counter = MarkerCounter(
            basis: try .heuristic(estimatorID: "chars-div-4", estimatorRevision: "v1"),
            provenance: .heuristicEstimator,
            measurementReceiptID: "receipt-estimate-001",
            baselineUnits: 20,
            capsuleUnits: 8
        )

        let receipt = try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE estimated context",
            capsule: capsule,
            counter: counter
        )

        XCTAssertEqual(receipt.truth, .estimatedUnits)
        XCTAssertFalse(receipt.hasExactTokenizerProvenance)
        XCTAssertEqual(receipt.change, .reduced(units: 12))
    }

    func testModelReportedExactTokenizerValueRemainsUntrusted() throws {
        let capsule = try makeCapsule()
        let counter = MarkerCounter(
            basis: try .exactTokenizer(tokenizerID: "tokenizer-a", tokenizerRevision: "rev-7"),
            provenance: .modelReported,
            measurementReceiptID: "receipt-model-001",
            baselineUnits: 40,
            capsuleUnits: 10
        )

        let receipt = try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE model reported context",
            capsule: capsule,
            counter: counter
        )

        XCTAssertEqual(receipt.truth, .untrustedReportedUnits)
        XCTAssertFalse(receipt.hasExactTokenizerProvenance)
    }

    func testIncompatibleCounterProvenanceFailsClosed() throws {
        let capsule = try makeCapsule()
        let counter = MarkerCounter(
            basis: try .exactTokenizer(tokenizerID: "tokenizer-a", tokenizerRevision: "rev-7"),
            provenance: .heuristicEstimator,
            measurementReceiptID: "receipt-bad-provenance",
            baselineUnits: 40,
            capsuleUnits: 10
        )

        XCTAssertThrowsError(
            try ForgeCompactAccounting.measure(
                baselineContext: "BASELINE context",
                capsule: capsule,
                counter: counter
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactAccountingError, .invalidProvenanceForBasis)
        }
    }

    func testUTF8CounterCannotLieAboutByteUnits() throws {
        let capsule = try makeCapsule()
        let counter = MarkerCounter(
            basis: .utf8Bytes,
            provenance: .deterministicHarness,
            measurementReceiptID: "receipt-bytes-bad",
            baselineUnits: 1,
            capsuleUnits: 1
        )

        XCTAssertThrowsError(
            try ForgeCompactAccounting.measure(
                baselineContext: "BASELINE definitely more than one byte",
                capsule: capsule,
                counter: counter
            )
        ) { error in
            guard case .utf8ByteCountMismatch = error as? ForgeCompactAccountingError else {
                return XCTFail("Expected UTF-8 byte mismatch, got \(error)")
            }
        }
    }

    func testDirectUTF8MeasurementIsExactBytesNotTokens() throws {
        let capsule = try makeCapsule()
        let baseline = "raw 🧠 context"

        let receipt = try ForgeCompactAccounting.measureUTF8Bytes(
            baselineContext: baseline,
            capsule: capsule,
            measurementReceiptID: "receipt-bytes-001"
        )

        XCTAssertEqual(receipt.truth, .exactUTF8Bytes)
        XCTAssertFalse(receipt.hasExactTokenizerProvenance)
        XCTAssertEqual(receipt.baselineUnits, UInt64(baseline.utf8.count))
        XCTAssertEqual(receipt.capsuleUnits, UInt64(capsule.renderedContext.utf8.count))
    }

    func testAccountingBasisRejectsNonCanonicalTokenizerIdentity() {
        XCTAssertThrowsError(
            try ForgeCompactAccountingBasis.exactTokenizer(
                tokenizerID: " tokenizer-a",
                tokenizerRevision: "rev-1"
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactAccountingError, .invalidBasis)
        }
    }

    func testCounterFailureDoesNotLeakArbitraryErrorIntoDomain() throws {
        let capsule = try makeCapsule()
        let counter = ThrowingCounter(
            basis: try .exactTokenizer(tokenizerID: "tokenizer-a", tokenizerRevision: "rev-1")
        )

        XCTAssertThrowsError(
            try ForgeCompactAccounting.measure(
                baselineContext: "BASELINE",
                capsule: capsule,
                counter: counter
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactAccountingError, .counterFailed)
        }
    }

    func testReceiptDecodeRevalidatesBasisIdentity() throws {
        let receipt = try exactReceipt()
        var json = try jsonObject(receipt)
        var basis = try XCTUnwrap(json["basis"] as? [String: Any])
        basis["counterID"] = " tokenizer-a"
        json["basis"] = basis

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForgeCompactAccountingReceipt.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
        )
    }

    func testReceiptDecodeRejectsDuplicateSelectedItemIDs() throws {
        let receipt = try exactReceipt()
        var json = try jsonObject(receipt)
        let selected = try XCTUnwrap(json["selectedItemIDs"] as? [String])
        json["selectedItemIDs"] = [selected[0], selected[0]]

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForgeCompactAccountingReceipt.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactAccountingError,
                .duplicateSelectedItemID(selected[0])
            )
        }
    }

    func testReceiptDecodeRejectsByteUnitTampering() throws {
        let capsule = try makeCapsule()
        let receipt = try ForgeCompactAccounting.measureUTF8Bytes(
            baselineContext: "baseline",
            capsule: capsule,
            measurementReceiptID: "receipt-bytes-002"
        )
        var json = try jsonObject(receipt)
        json["capsuleUnits"] = receipt.capsuleUnits + 1

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ForgeCompactAccountingReceipt.self,
                from: JSONSerialization.data(withJSONObject: json)
            )
        )
    }

    func testReceiptMustBeMatchedBackToExactCapsuleAuthorityAndSelection() throws {
        let capsule = try makeCapsule(capsuleRevision: 1)
        let receipt = try ForgeCompactAccounting.measureUTF8Bytes(
            baselineContext: "baseline",
            capsule: capsule,
            measurementReceiptID: "receipt-bytes-003"
        )
        let newerCapsule = try makeCapsule(capsuleRevision: 2)

        XCTAssertTrue(receipt.matches(capsule: capsule))
        XCTAssertFalse(receipt.matches(capsule: newerCapsule))
    }

    func testReceiptRoundTripPreservesAccountingTruth() throws {
        let receipt = try exactReceipt()
        let data = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(ForgeCompactAccountingReceipt.self, from: data)

        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(decoded.truth, .exactTokenizerTokens)
    }

    private func exactReceipt() throws -> ForgeCompactAccountingReceipt {
        let capsule = try makeCapsule()
        let counter = MarkerCounter(
            basis: try .exactTokenizer(tokenizerID: "tokenizer-a", tokenizerRevision: "rev-7"),
            provenance: .deterministicHarness,
            measurementReceiptID: "receipt-tokenizer-roundtrip",
            baselineUnits: 30,
            capsuleUnits: 9
        )
        return try ForgeCompactAccounting.measure(
            baselineContext: "BASELINE round trip",
            capsule: capsule,
            counter: counter
        )
    }

    private func makeCapsule(capsuleRevision: Int = 1) throws -> ProjectCapsule {
        let authority = try ProjectCapsuleAuthority(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: "source-r1",
            missionRevision: 2,
            authorityEpoch: 3,
            capsuleRevision: capsuleRevision
        )
        let item = try ForgeCompactContextItem(
            id: "objective",
            sourceRevision: "source-r1",
            tier: .l0AlwaysResident,
            kind: .currentObjective,
            priority: 100,
            content: "Repair the local launch path.",
            provenance: ForgeCompactProvenance(kind: .source, reference: "mission/objective"),
            isAuthoritative: true
        )
        return try ProjectCapsuleBuilder.build(
            authority: authority,
            items: [item],
            budgetBytes: 4_096
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private struct MarkerCounter: ForgeCompactContextCounter {
    let basis: ForgeCompactAccountingBasis
    let provenance: ForgeCompactAccountingProvenance
    let measurementReceiptID: String
    let baselineUnits: UInt64
    let capsuleUnits: UInt64

    func countUnits(in text: String) throws -> UInt64 {
        text.contains("BASELINE") ? baselineUnits : capsuleUnits
    }
}

private struct ThrowingCounter: ForgeCompactContextCounter {
    struct ExpectedFailure: Error {}

    let basis: ForgeCompactAccountingBasis
    let provenance: ForgeCompactAccountingProvenance = .runtimeTokenizer
    let measurementReceiptID = "receipt-throws"

    func countUnits(in text: String) throws -> UInt64 {
        throw ExpectedFailure()
    }
}
