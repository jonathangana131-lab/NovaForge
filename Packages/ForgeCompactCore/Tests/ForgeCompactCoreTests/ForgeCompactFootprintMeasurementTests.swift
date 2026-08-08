import XCTest
@testable import ForgeCompactCore

final class ForgeCompactFootprintMeasurementTests: XCTestCase {
    func testBuildAndMeasureDerivesReductionFromExactSourceSet() throws {
        let objective = try item(
            id: "objective",
            tier: .l0AlwaysResident,
            kind: .currentObjective,
            content: "Repair launch."
        )
        let optional = try item(
            id: "history",
            tier: .l3ColdArchive,
            kind: .workingNote,
            content: String(repeating: "old context ", count: 40),
            authoritative: false
        )

        let result = try ForgeCompactFootprintMeasurer.buildAndMeasure(
            authority: authority(),
            items: [optional, objective],
            budgetBytes: objective.renderedUTF8Bytes
        )
        let expectedBaseline = optional.renderedUTF8Bytes + 1 + objective.renderedUTF8Bytes

        XCTAssertEqual(result.capsule.selectedItems.map(\.id), ["objective"])
        XCTAssertEqual(result.footprint.fullSourceRenderedUTF8Bytes, expectedBaseline)
        XCTAssertEqual(result.footprint.capsuleRenderedUTF8Bytes, objective.renderedUTF8Bytes)
        XCTAssertEqual(result.footprint.savedRenderedUTF8Bytes, optional.renderedUTF8Bytes + 1)
        XCTAssertEqual(result.footprint.sourceItemCount, 2)
        XCTAssertEqual(result.footprint.selectedItemCount, 1)
        XCTAssertEqual(result.footprint.omittedItemCount, 1)
        XCTAssertGreaterThan(result.footprint.reductionBasisPoints, 0)
        XCTAssertLessThanOrEqual(result.footprint.reductionBasisPoints, 10_000)
    }

    func testAllSelectedReportsZeroByteReduction() throws {
        let items = try [
            item(id: "objective", tier: .l0AlwaysResident, kind: .currentObjective, content: "Build it."),
            item(id: "note", tier: .l2ProjectMemory, kind: .workingNote, content: "Useful context.", authoritative: false),
        ]
        let result = try ForgeCompactFootprintMeasurer.buildAndMeasure(
            authority: authority(),
            items: items,
            budgetBytes: 8_000
        )

        XCTAssertEqual(result.footprint.fullSourceRenderedUTF8Bytes, result.footprint.capsuleRenderedUTF8Bytes)
        XCTAssertEqual(result.footprint.savedRenderedUTF8Bytes, 0)
        XCTAssertEqual(result.footprint.reductionBasisPoints, 0)
        XCTAssertEqual(result.footprint.omittedItemCount, 0)
    }

    func testInputOrderCannotChangeMeasuredFootprint() throws {
        let values = try [
            item(id: "objective", tier: .l0AlwaysResident, kind: .currentObjective, content: "Build it."),
            item(id: "a", tier: .l2ProjectMemory, kind: .workingNote, content: String(repeating: "A", count: 100), authoritative: false),
            item(id: "b", tier: .l3ColdArchive, kind: .workingNote, content: String(repeating: "B", count: 100), authoritative: false),
        ]
        let budget = values[0].renderedUTF8Bytes + 1 + values[1].renderedUTF8Bytes
        let forward = try ForgeCompactFootprintMeasurer.buildAndMeasure(authority: authority(), items: values, budgetBytes: budget)
        let reverse = try ForgeCompactFootprintMeasurer.buildAndMeasure(authority: authority(), items: values.reversed(), budgetBytes: budget)

        XCTAssertEqual(forward.footprint, reverse.footprint)
        XCTAssertEqual(forward.capsule.renderedUTF8Bytes, reverse.capsule.renderedUTF8Bytes)
    }

    func testEmptySourceSetHasDefinedZeroReduction() throws {
        let result = try ForgeCompactFootprintMeasurer.buildAndMeasure(
            authority: authority(),
            items: [],
            budgetBytes: 0
        )

        XCTAssertEqual(result.footprint.fullSourceRenderedUTF8Bytes, 0)
        XCTAssertEqual(result.footprint.capsuleRenderedUTF8Bytes, 0)
        XCTAssertEqual(result.footprint.savedRenderedUTF8Bytes, 0)
        XCTAssertEqual(result.footprint.reductionBasisPoints, 0)
    }

    func testMeasurementCountsUTF8BytesRatherThanCharacters() throws {
        let value = try item(
            id: "emoji",
            tier: .l2ProjectMemory,
            kind: .workingNote,
            content: "🚗⚡️ 本地 AI",
            authoritative: false
        )
        let result = try ForgeCompactFootprintMeasurer.buildAndMeasure(
            authority: authority(),
            items: [value],
            budgetBytes: 0
        )

        XCTAssertEqual(result.footprint.fullSourceRenderedUTF8Bytes, value.renderedLine.utf8.count)
        XCTAssertGreaterThan(result.footprint.fullSourceRenderedUTF8Bytes, value.renderedLine.count)
        XCTAssertEqual(result.footprint.reductionBasisPoints, 10_000)
    }

    func testMandatoryTruthBudgetFailureDoesNotProduceMeasurement() throws {
        let value = try item(
            id: "privacy",
            tier: .l0AlwaysResident,
            kind: .privacyPolicy,
            content: "Local Only must remain local."
        )

        XCTAssertThrowsError(
            try ForgeCompactFootprintMeasurer.buildAndMeasure(
                authority: authority(),
                items: [value],
                budgetBytes: value.renderedUTF8Bytes - 1
            )
        ) { error in
            guard case ForgeCompactError.budgetCannotHoldMandatoryTruth = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testSourceRevisionMismatchStillFailsClosed() throws {
        let value = try item(
            id: "source",
            tier: .l2ProjectMemory,
            kind: .sourceLocation,
            content: "AgentPad/AppRoot.swift",
            authoritative: false,
            sourceRevision: "src-old"
        )

        XCTAssertThrowsError(
            try ForgeCompactFootprintMeasurer.buildAndMeasure(
                authority: authority(sourceRevision: "src-new"),
                items: [value],
                budgetBytes: 4_000
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .sourceRevisionMismatch(itemID: "source"))
        }
    }

    private func authority(sourceRevision: String = "src-1") throws -> ProjectCapsuleAuthority {
        try ProjectCapsuleAuthority(
            projectID: "project-1",
            missionID: "mission-1",
            sourceRevision: sourceRevision,
            missionRevision: 3,
            authorityEpoch: 2,
            capsuleRevision: 1
        )
    }

    private func item(
        id: String,
        tier: ForgeCompactContextTier,
        kind: ForgeCompactFactKind,
        content: String,
        authoritative: Bool = true,
        sourceRevision: String = "src-1"
    ) throws -> ForgeCompactContextItem {
        try ForgeCompactContextItem(
            id: id,
            sourceRevision: sourceRevision,
            tier: tier,
            kind: kind,
            priority: 50,
            content: content,
            provenance: ForgeCompactProvenance(kind: .source, reference: "ref-\(id)"),
            isAuthoritative: authoritative
        )
    }
}
