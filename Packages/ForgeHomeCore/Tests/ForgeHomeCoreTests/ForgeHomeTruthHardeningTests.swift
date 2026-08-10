import XCTest
@testable import ForgeHomeCore

final class ForgeHomeTruthHardeningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCapabilitiesFailClosedByDefaultEvenWhenCandidateClaimsAreTrue() {
        let record = ForgeCreationRecord(
            name: "Untrusted capabilities",
            lastChangedAt: now,
            canEditSource: true,
            canDuplicate: true,
            canRemix: true,
            canExportSource: true
        )

        XCTAssertEqual(ForgeHomeProjector.makeCard(record).actions, [.details])
    }

    func testWholeRecordTrustRejectsSameIDAfterAuthorityBearingMutation() {
        let id = ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)
        let original = ForgeCreationRecord(
            id: id,
            name: "Trusted",
            lastChangedAt: now,
            currentSourceRevision: "r1",
            runtimeEvidence: runtimeEvidence(level: .runtimeTested, revision: "r1"),
            canEditSource: true
        )
        var tampered = original
        tampered.canExportSource = true

        let binding = ForgeHomeTrustBinding(authenticatedRecord: original)
        XCTAssertTrue(binding.exactlyMatches(original))
        XCTAssertFalse(binding.exactlyMatches(tampered))
        XCTAssertEqual(
            ForgeHomeProjector.makeCard(tampered, trustBindings: [binding]).actions,
            [.details]
        )
    }

    func testWholeRecordTrustRejectsSameIDsWithRewrittenRuntimeVerification() {
        let original = ForgeCreationRecord(
            name: "Runtime candidate",
            lastChangedAt: now,
            currentSourceRevision: "r1",
            runtimeEvidence: runtimeEvidence(level: .launchAuthorized, revision: "r1")
        )
        let forged = ForgeCreationRecord(
            id: original.id,
            name: original.name,
            lastChangedAt: original.lastChangedAt,
            currentSourceRevision: original.currentSourceRevision,
            activeMission: original.activeMission,
            runtimeEvidence: runtimeEvidence(level: .physicalDeviceVerified, revision: "r1"),
            thumbnailEvidence: original.thumbnailEvidence,
            canEditSource: original.canEditSource,
            canDuplicate: original.canDuplicate,
            canRemix: original.canRemix,
            canExportSource: original.canExportSource
        )

        let binding = ForgeHomeTrustBinding(authenticatedRecord: original)
        XCTAssertFalse(binding.exactlyMatches(forged))
        XCTAssertFalse(
            ForgeHomeProjector.makeCard(forged, trustBindings: [binding]).runState.isRunnable
        )
    }

    func testBlankEvidenceProvenanceNeverAuthorizesRunOrThumbnailEvenWhenTrusted() {
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
        let card = trustedCard(record)
        XCTAssertFalse(card.runState.isRunnable)
        XCTAssertFalse(card.actions.contains(.run))
        XCTAssertNil(card.actualThumbnail)
    }

    func testStaleEvidenceCannotAuthorizeCurrentCreationRunOrThumbnail() {
        let record = ForgeCreationRecord(
            name: "Changed after proof",
            lastChangedAt: now,
            currentSourceRevision: "r2",
            runtimeEvidence: runtimeEvidence(level: .runtimeTested, revision: "r1"),
            thumbnailEvidence: screenshot(revision: "r1")
        )

        let card = trustedCard(record)
        XCTAssertFalse(card.runState.isRunnable)
        XCTAssertNil(card.actualThumbnail)
    }

    func testMissingOrBlankCurrentRevisionFailsClosed() {
        let runtime = runtimeEvidence(level: .runtimeTested, revision: "r1")
        let thumbnail = screenshot(revision: "r1")

        for revision in [nil, "", "  \n"] as [String?] {
            let record = ForgeCreationRecord(
                name: "Unknown current revision",
                lastChangedAt: now,
                currentSourceRevision: revision,
                runtimeEvidence: runtime,
                thumbnailEvidence: thumbnail
            )
            let card = trustedCard(record)
            XCTAssertFalse(card.runState.isRunnable)
            XCTAssertNil(card.actualThumbnail)
        }
    }

    func testWhitespaceAliasRevisionFailsClosedInsteadOfNormalizingAuthorityIdentity() {
        let record = ForgeCreationRecord(
            name: "Aliased revision",
            lastChangedAt: now,
            currentSourceRevision: "r1",
            runtimeEvidence: runtimeEvidence(level: .runtimeTested, revision: " r1 "),
            thumbnailEvidence: screenshot(revision: "r1")
        )

        let card = trustedCard(record)
        XCTAssertFalse(card.runState.isRunnable)
        XCTAssertNil(card.actualThumbnail)
    }

    func testControlCharacterArtifactAndRevisionIdentitiesFailClosed() {
        let record = ForgeCreationRecord(
            name: "Malformed identity",
            lastChangedAt: now,
            currentSourceRevision: "r1",
            runtimeEvidence: ForgeRuntimeEvidence(
                artifactID: ForgeArtifactID(rawValue: "runtime\u{0000}id"),
                runtimeKind: .forgeWeb,
                verificationLevel: .runtimeTested,
                sourceRevision: "r1",
                recordedAt: now
            )
        )
        XCTAssertFalse(trustedCard(record).runState.isRunnable)

        let badRevision = ForgeCreationRecord(
            name: "Malformed revision",
            lastChangedAt: now,
            currentSourceRevision: "r1\u{0007}",
            runtimeEvidence: runtimeEvidence(level: .runtimeTested, revision: "r1\u{0007}")
        )
        XCTAssertFalse(trustedCard(badRevision).runState.isRunnable)
    }

    func testMissingRevisionFieldRoundTripsAsNilAndFailsClosedAfterTrustReacquisition() throws {
        let record = ForgeCreationRecord(
            name: "Pre-revision record",
            lastChangedAt: now,
            runtimeEvidence: runtimeEvidence(level: .runtimeTested, revision: "r1")
        )

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("currentSourceRevision"))

        let decoded = try JSONDecoder().decode(ForgeCreationRecord.self, from: data)
        XCTAssertNil(decoded.currentSourceRevision)
        XCTAssertFalse(trustedCard(decoded).runState.isRunnable)
    }

    private func trustedCard(_ record: ForgeCreationRecord) -> ForgeCreationCard {
        let binding = ForgeHomeTrustBinding(authenticatedRecord: record)
        return ForgeHomeProjector.makeCard(record, trustBindings: [binding])
    }

    private func runtimeEvidence(
        level: ForgeRuntimeEvidence.VerificationLevel,
        revision: String
    ) -> ForgeRuntimeEvidence {
        ForgeRuntimeEvidence(
            artifactID: ForgeArtifactID(rawValue: "runtime-\(revision)"),
            runtimeKind: .forgeWeb,
            verificationLevel: level,
            sourceRevision: revision,
            recordedAt: now
        )
    }

    private func screenshot(revision: String) -> ForgeThumbnailEvidence {
        ForgeThumbnailEvidence(
            artifactID: ForgeArtifactID(rawValue: "screenshot-\(revision)"),
            kind: .runtimeScreenshot,
            sourceRevision: revision,
            recordedAt: now
        )
    }
}
