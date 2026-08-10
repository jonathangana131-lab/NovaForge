import XCTest
@testable import ForgeHomeCore

final class ForgeHomeCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCreationPromptMatchesFlagshipPrimaryQuestion() {
        XCTAssertEqual(ForgeHomeSnapshot.creationPrompt, "What do you want to make?")
    }

    func testEmptyCreationIntentDoesNotBecomeReady() {
        XCTAssertFalse(ForgeNewCreationIntent(rawText: "  \n ").isReadyToPlan)
        XCTAssertTrue(ForgeNewCreationIntent(rawText: "  Build a driving game  ").isReadyToPlan)
        XCTAssertEqual(
            ForgeNewCreationIntent(rawText: "  Build a driving game  ").normalizedText,
            "Build a driving game"
        )
    }

    func testPublicCandidateRuntimeClaimCannotAuthorizeRunWithoutHostTrust() {
        let record = ForgeCreationRecord(
            name: "Candidate only",
            lastChangedAt: now,
            currentSourceRevision: "rev",
            runtimeEvidence: runtimeEvidence(level: .physicalDeviceVerified)
        )

        let card = ForgeHomeProjector.makeCard(record)
        XCTAssertFalse(card.runState.isRunnable)
        XCTAssertFalse(card.actions.contains(.run))
    }

    func testTrustedRuntimeEvidenceBeyondGeneratedAuthorizesRun() {
        let generated = ForgeCreationRecord(
            name: "Generated only",
            lastChangedAt: now,
            currentSourceRevision: "rev",
            runtimeEvidence: runtimeEvidence(level: .generated)
        )
        let authorized = ForgeCreationRecord(
            name: "Runnable",
            lastChangedAt: now,
            currentSourceRevision: "rev",
            runtimeEvidence: runtimeEvidence(level: .launchAuthorized)
        )

        XCTAssertFalse(trustedCard(generated).actions.contains(.run))
        XCTAssertTrue(trustedCard(authorized).actions.contains(.run))
    }

    func testExternalNativeEvidenceNeverPretendsToRunInsideNovaForgeEvenWhenTrusted() {
        let record = ForgeCreationRecord(
            name: "Native project",
            lastChangedAt: now,
            currentSourceRevision: "abc",
            runtimeEvidence: ForgeRuntimeEvidence(
                artifactID: ForgeArtifactID(rawValue: "native-app"),
                runtimeKind: .externalNative,
                verificationLevel: .physicalDeviceVerified,
                sourceRevision: "abc",
                recordedAt: now
            )
        )

        let card = trustedCard(record)
        XCTAssertFalse(card.runState.isRunnable)
        XCTAssertFalse(card.actions.contains(.run))
    }

    func testImportedReferenceCannotBecomeActualProjectThumbnail() {
        let record = ForgeCreationRecord(
            name: "Reference-backed",
            lastChangedAt: now,
            currentSourceRevision: "r1",
            runtimeEvidence: runtimeEvidence(level: .runtimeTested, revision: "r1"),
            thumbnailEvidence: ForgeThumbnailEvidence(
                artifactID: ForgeArtifactID(rawValue: "reference-image"),
                kind: .importedReference,
                sourceRevision: "r1",
                recordedAt: now
            )
        )

        XCTAssertNil(trustedCard(record).actualThumbnail)
    }

    func testRuntimeScreenshotMustMatchRunnableSourceRevision() {
        let stale = ForgeCreationRecord(
            name: "Stale preview",
            lastChangedAt: now,
            currentSourceRevision: "r2",
            runtimeEvidence: runtimeEvidence(level: .runtimeTested, revision: "r2"),
            thumbnailEvidence: screenshot(revision: "r1")
        )
        let current = ForgeCreationRecord(
            name: "Current preview",
            lastChangedAt: now,
            currentSourceRevision: "r2",
            runtimeEvidence: runtimeEvidence(level: .runtimeTested, revision: "r2"),
            thumbnailEvidence: screenshot(revision: "r2")
        )

        XCTAssertNil(trustedCard(stale).actualThumbnail)
        XCTAssertNotNil(trustedCard(current).actualThumbnail)
    }

    func testGeneratedRuntimeCannotAuthorizeThumbnailPresentation() {
        let record = ForgeCreationRecord(
            name: "Not launched",
            lastChangedAt: now,
            currentSourceRevision: "r1",
            runtimeEvidence: runtimeEvidence(level: .generated, revision: "r1"),
            thumbnailEvidence: screenshot(revision: "r1")
        )

        XCTAssertNil(trustedCard(record).actualThumbnail)
    }

    func testActionAvailabilityRequiresWholeRecordHostTrust() {
        let record = ForgeCreationRecord(
            name: "Full project",
            lastChangedAt: now,
            currentSourceRevision: "rev",
            runtimeEvidence: runtimeEvidence(level: .runtimeTested),
            canEditSource: true,
            canDuplicate: true,
            canRemix: true,
            canExportSource: true
        )

        XCTAssertEqual(ForgeHomeProjector.makeCard(record).actions, [.details])
        XCTAssertEqual(
            trustedCard(record).actions,
            [.run, .edit, .duplicate, .remix, .export, .details]
        )
    }

    func testTrustedActiveMissionsSortBeforeIdleCreations() {
        let idle = ForgeCreationRecord(
            id: ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            name: "Idle newer project",
            lastChangedAt: now
        )
        let active = ForgeCreationRecord(
            id: ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            name: "Active older project",
            lastChangedAt: now.addingTimeInterval(-100),
            activeMission: mission(updatedAt: now.addingTimeInterval(-50))
        )

        let cards = ForgeHomeProjector.project(
            [idle, active],
            trustBindings: [trust(idle), trust(active)]
        ).cards
        XCTAssertEqual(cards.map(\.name), ["Active older project", "Idle newer project"])
    }

    func testUntrustedMissionClaimDoesNotBecomeHomeMissionState() {
        let claimedActive = ForgeCreationRecord(
            name: "Claimed active",
            lastChangedAt: now,
            activeMission: mission(updatedAt: now)
        )

        XCTAssertNil(ForgeHomeProjector.makeCard(claimedActive).activeMission)
        XCTAssertNotNil(trustedCard(claimedActive).activeMission)
    }

    func testActiveMissionOrderingUsesMissionRecencyThenProjectRecency() {
        let olderMission = ForgeCreationRecord(
            name: "Older mission",
            lastChangedAt: now,
            activeMission: mission(updatedAt: now.addingTimeInterval(-20))
        )
        let newerMission = ForgeCreationRecord(
            name: "Newer mission",
            lastChangedAt: now.addingTimeInterval(-100),
            activeMission: mission(updatedAt: now.addingTimeInterval(-5))
        )

        XCTAssertEqual(
            ForgeHomeProjector.project(
                [olderMission, newerMission],
                trustBindings: [trust(olderMission), trust(newerMission)]
            ).cards.map(\.name),
            ["Newer mission", "Older mission"]
        )
    }

    func testIdleCreationOrderingIsDeterministic() {
        let firstID = ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondID = ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let records = [
            ForgeCreationRecord(id: secondID, name: "Second", lastChangedAt: now),
            ForgeCreationRecord(id: firstID, name: "First", lastChangedAt: now),
        ]

        XCTAssertEqual(ForgeHomeProjector.project(records).cards.map(\.id), [firstID, secondID])
    }

    func testBlankPersistedNameGetsHumanFallback() {
        let card = ForgeHomeProjector.makeCard(
            ForgeCreationRecord(name: " \n ", lastChangedAt: now)
        )
        XCTAssertEqual(card.name, "Untitled Creation")
    }

    func testDurableRecordRoundTripDoesNotRestorePresentationAuthority() throws {
        let record = ForgeCreationRecord(
            name: "Neon Racer",
            lastChangedAt: now,
            currentSourceRevision: "rev-42",
            activeMission: mission(updatedAt: now),
            runtimeEvidence: runtimeEvidence(level: .simulatorVerified, revision: "rev-42"),
            thumbnailEvidence: screenshot(revision: "rev-42"),
            canEditSource: true
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ForgeCreationRecord.self, from: data)
        XCTAssertEqual(decoded, record)

        let untrustedCard = ForgeHomeProjector.makeCard(decoded)
        XCTAssertFalse(untrustedCard.runState.isRunnable)
        XCTAssertNil(untrustedCard.actualThumbnail)
        XCTAssertNil(untrustedCard.activeMission)
        XCTAssertEqual(untrustedCard.actions, [.details])

        let reacquired = ForgeHomeProjector.makeCard(decoded, trustBindings: [trust(decoded)])
        XCTAssertTrue(reacquired.runState.isRunnable)
        XCTAssertNotNil(reacquired.actualThumbnail)
        XCTAssertNotNil(reacquired.activeMission)
        XCTAssertEqual(reacquired.actions, [.run, .edit, .details])
    }

    private func trust(_ record: ForgeCreationRecord) -> ForgeHomeTrustBinding {
        ForgeHomeTrustBinding(authenticatedRecord: record)
    }

    private func trustedCard(_ record: ForgeCreationRecord) -> ForgeCreationCard {
        ForgeHomeProjector.makeCard(record, trustBindings: [trust(record)])
    }

    private func runtimeEvidence(
        level: ForgeRuntimeEvidence.VerificationLevel,
        revision: String = "rev"
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

    private func mission(updatedAt: Date) -> ForgeMissionReference {
        ForgeMissionReference(
            missionID: UUID(),
            state: .running,
            statusText: "Building project",
            updatedAt: updatedAt
        )
    }
}
