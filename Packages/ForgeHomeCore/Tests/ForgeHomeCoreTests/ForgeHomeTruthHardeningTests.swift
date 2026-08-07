import XCTest
@testable import ForgeHomeCore

final class ForgeHomeTruthHardeningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCapabilitiesFailClosedByDefault() {
        let card = ForgeHomeProjector.makeCard(
            ForgeCreationRecord(name: "Unknown capabilities", lastChangedAt: now)
        )
        XCTAssertEqual(card.actions, [.details])
    }

    func testActionsHaveStableUserFacingOrder() {
        let record = ForgeCreationRecord(
            name: "Full project",
            lastChangedAt: now,
            runtimeEvidence: ForgeRuntimeEvidence(
                artifactID: ForgeArtifactID(rawValue: "runtime-rev"),
                runtimeKind: .forgeWeb,
                verificationLevel: .runtimeTested,
                sourceRevision: "rev",
                recordedAt: now
            ),
            canEditSource: true,
            canDuplicate: true,
            canRemix: true,
            canExportSource: true
        )
        XCTAssertEqual(
            ForgeHomeProjector.makeCard(record).actions,
            [.run, .edit, .duplicate, .remix, .export, .details]
        )
    }

    func testBlankEvidenceProvenanceNeverAuthorizesRunOrThumbnail() {
        let record = ForgeCreationRecord(
            name: "Missing provenance",
            lastChangedAt: now,
            runtimeEvidence: ForgeRuntimeEvidence(
                artifactID: ForgeArtifactID(rawValue: " "),
                runtimeKind: .forgeWeb,
                verificationLevel: .runtimeTested,
                sourceRevision: "",
                recordedAt: now
            ),
            thumbnailEvidence: ForgeThumbnailEvidence(
                artifactID: ForgeArtifactID(rawValue: "shot"),
                kind: .runtimeScreenshot,
                sourceRevision: "",
                recordedAt: now
            )
        )
        let card = ForgeHomeProjector.makeCard(record)
        XCTAssertFalse(card.runState.isRunnable)
        XCTAssertFalse(card.actions.contains(.run))
        XCTAssertNil(card.actualThumbnail)
    }
}
