import XCTest
@testable import ForgeHomeCore

final class ForgeHomeCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCreationPromptMatchesV13PrimaryQuestion() {
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

    func testRunRequiresForgeRuntimeEvidenceBeyondGenerated() {
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

        XCTAssertFalse(ForgeHomeProjector.makeCard(generated).actions.contains(.run))
        XCTAssertTrue(ForgeHomeProjector.makeCard(authorized).actions.contains(.run))
    }

    func testExternalNativeEvidenceNeverPretendsToRunInsideNovaForge() {
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

        let card = ForgeHomeProjector.makeCard(record)
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

        XCTAssertNil(ForgeHomeProjector.makeCard(record).actualThumbnail)
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

        XCTAssertNil(ForgeHomeProjector.makeCard(stale).actualThumbnail)
        XCTAssertNotNil(ForgeHomeProjector.makeCard(current).actualThumbnail)
    }

    func testGeneratedRuntimeCannotAuthorizeThumbnailPresentation() {
        let record = ForgeCreationRecord(
            name: "Not launched",
            lastChangedAt: now,
            currentSourceRevision: "r1",
            runtimeEvidence: runtimeEvidence(level: .generated, revision: "r1"),
            thumbnailEvidence: screenshot(revision: "r1")
        )

        XCTAssertNil(ForgeHomeProjector.makeCard(record).actualThumbnail)
    }

    func testActionAvailabilityFollowsRealCapabilities() {
        let record = ForgeCreationRecord(
            name: "Read only",
            lastChangedAt: now,
            currentSourceRevision: "rev",
            runtimeEvidence: runtimeEvidence(level: .runtimeTested),
            canEditSource: false,
            canDuplicate: false,
            canRemix: false,
            canExportSource: false
        )

        XCTAssertEqual(ForgeHomeProjector.makeCard(record).actions, [.run, .details])
    }

    func testActiveMissionsSortBeforeIdleCreations() {
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

        let cards = ForgeHomeProjector.project([idle, active]).cards
        XCTAssertEqual(cards.map(\.name), ["Active older project", "Idle newer project"])
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
            ForgeHomeProjector.project([olderMission, newerMission]).cards.map(\.name),
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

    func testSnapshotRoundTripPreservesTruthProjection() throws {
        let record = ForgeCreationRecord(
            name: "Neon Racer",
            lastChangedAt: now,
            currentSourceRevision: "rev-42",
            activeMission: mission(updatedAt: now),
            runtimeEvidence: runtimeEvidence(level: .simulatorVerified, revision: "rev-42"),
            thumbnailEvidence: screenshot(revision: "rev-42")
        )
        let snapshot = ForgeHomeProjector.project([record])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ForgeHomeSnapshot.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(try XCTUnwrap(decoded.cards.first).actions.contains(.run))
        XCTAssertNotNil(decoded.cards.first?.actualThumbnail)
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
