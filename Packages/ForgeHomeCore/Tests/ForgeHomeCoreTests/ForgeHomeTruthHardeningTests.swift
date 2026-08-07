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
            currentSourceRevision: "rev",
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
            currentSourceRevision: "rev",
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

    func testStaleEvidenceCannotAuthorizeCurrentCreationRunOrThumbnail() {
        let record = ForgeCreationRecord(
            name: "Changed after proof",
            lastChangedAt: now,
            currentSourceRevision: "r2",
            runtimeEvidence: ForgeRuntimeEvidence(
                artifactID: ForgeArtifactID(rawValue: "runtime-r1"),
                runtimeKind: .forgeWeb,
                verificationLevel: .runtimeTested,
                sourceRevision: "r1",
                recordedAt: now.addingTimeInterval(-20)
            ),
            thumbnailEvidence: ForgeThumbnailEvidence(
                artifactID: ForgeArtifactID(rawValue: "screenshot-r1"),
                kind: .runtimeScreenshot,
                sourceRevision: "r1",
                recordedAt: now.addingTimeInterval(-20)
            )
        )

        let card = ForgeHomeProjector.makeCard(record)
        XCTAssertFalse(card.runState.isRunnable)
        XCTAssertFalse(card.actions.contains(.run))
        XCTAssertNil(card.actualThumbnail)
    }

    func testMissingOrBlankCurrentRevisionFailsClosed() {
        let runtime = ForgeRuntimeEvidence(
            artifactID: ForgeArtifactID(rawValue: "runtime-r1"),
            runtimeKind: .forgeWeb,
            verificationLevel: .runtimeTested,
            sourceRevision: "r1",
            recordedAt: now
        )
        let thumbnail = ForgeThumbnailEvidence(
            artifactID: ForgeArtifactID(rawValue: "screenshot-r1"),
            kind: .runtimeScreenshot,
            sourceRevision: "r1",
            recordedAt: now
        )

        for revision in [nil, "", "  \n"] as [String?] {
            let card = ForgeHomeProjector.makeCard(
                ForgeCreationRecord(
                    name: "Unknown current revision",
                    lastChangedAt: now,
                    currentSourceRevision: revision,
                    runtimeEvidence: runtime,
                    thumbnailEvidence: thumbnail
                )
            )
            XCTAssertFalse(card.runState.isRunnable)
            XCTAssertNil(card.actualThumbnail)
        }
    }

    func testMissingRevisionFieldRoundTripsAsNilAndFailsClosed() throws {
        let record = ForgeCreationRecord(
            name: "Pre-revision record",
            lastChangedAt: now,
            runtimeEvidence: ForgeRuntimeEvidence(
                artifactID: ForgeArtifactID(rawValue: "runtime-r1"),
                runtimeKind: .forgeWeb,
                verificationLevel: .runtimeTested,
                sourceRevision: "r1",
                recordedAt: now
            )
        )

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("currentSourceRevision"))

        let decoded = try JSONDecoder().decode(ForgeCreationRecord.self, from: data)
        XCTAssertNil(decoded.currentSourceRevision)
        XCTAssertFalse(ForgeHomeProjector.makeCard(decoded).runState.isRunnable)
    }
}
