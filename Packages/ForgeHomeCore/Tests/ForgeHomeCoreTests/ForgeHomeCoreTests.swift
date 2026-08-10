import XCTest
@testable import ForgeHomeCore

final class ForgeHomeCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCreationPromptMatchesProductQuestion() {
        XCTAssertEqual(ForgeHomeSnapshot.creationPrompt, "What do you want to make?")
    }

    func testEmptyCreationIntentDoesNotBecomeReady() {
        XCTAssertFalse(ForgeNewCreationIntent(rawText: "  \n ").isReadyToPlan)
        XCTAssertEqual(ForgeNewCreationIntent(rawText: "  Build a driving game  ").normalizedText, "Build a driving game")
    }

    func testCandidateRuntimeMetadataCannotAuthorizeRunByItself() {
        let record = runnableRecord()
        let card = ForgeHomeProjector.makeCard(record)
        XCTAssertFalse(card.runState.isRunnable)
        XCTAssertEqual(card.actions, [.details])
    }

    func testTrustedExactRecordCanAuthorizeRun() throws {
        let record = runnableRecord()
        let binding = try ForgeHomeTrustBinding(authenticatedRecord: record)
        let card = ForgeHomeProjector.makeCard(record, trustedBindings: [binding])
        XCTAssertTrue(card.runState.isRunnable)
        XCTAssertEqual(card.actions, [.run, .details])
    }

    func testGeneratedRuntimeCannotAuthorizeRunEvenWhenRecordTrusted() throws {
        var record = runnableRecord(level: .generated)
        record.thumbnailEvidence = nil
        let binding = try ForgeHomeTrustBinding(authenticatedRecord: record)
        XCTAssertFalse(ForgeHomeProjector.makeCard(record, trustedBindings: [binding]).runState.isRunnable)
    }

    func testExternalNativeCannotPretendToRunInsideNovaForge() throws {
        var record = runnableRecord(kind: .externalNative, level: .physicalDeviceVerified)
        record.thumbnailEvidence = nil
        let binding = try ForgeHomeTrustBinding(authenticatedRecord: record)
        XCTAssertFalse(ForgeHomeProjector.makeCard(record, trustedBindings: [binding]).runState.isRunnable)
    }

    func testRuntimeScreenshotRequiresFreshTrustedRuntimeAtSameRevision() throws {
        let current = runnableRecord(revision: "r2")
        let currentBinding = try ForgeHomeTrustBinding(authenticatedRecord: current)
        XCTAssertNotNil(ForgeHomeProjector.makeCard(current, trustedBindings: [currentBinding]).actualThumbnail)

        var stale = current
        stale.runtimeEvidence = runtimeEvidence(level: .runtimeTested, revision: "r1")
        stale.thumbnailEvidence = screenshot(revision: "r1")
        let staleBinding = try ForgeHomeTrustBinding(authenticatedRecord: stale)
        let staleCard = ForgeHomeProjector.makeCard(stale, trustedBindings: [staleBinding])
        XCTAssertFalse(staleCard.runState.isRunnable)
        XCTAssertNil(staleCard.actualThumbnail)
    }

    func testImportedReferenceCannotBecomeActualThumbnail() throws {
        var record = runnableRecord()
        record.thumbnailEvidence = ForgeThumbnailEvidence(
            artifactID: ForgeArtifactID(rawValue: "reference-image"),
            kind: .importedReference,
            sourceRevision: "rev",
            recordedAt: now
        )
        let binding = try ForgeHomeTrustBinding(authenticatedRecord: record)
        XCTAssertNil(ForgeHomeProjector.makeCard(record, trustedBindings: [binding]).actualThumbnail)
    }

    func testCapabilitiesRequireWholeRecordTrust() throws {
        var record = runnableRecord()
        record.canEditSource = true
        record.canDuplicate = true
        record.canRemix = true
        record.canExportSource = true

        XCTAssertEqual(ForgeHomeProjector.makeCard(record).actions, [.details])
        let binding = try ForgeHomeTrustBinding(authenticatedRecord: record)
        XCTAssertEqual(
            ForgeHomeProjector.makeCard(record, trustedBindings: [binding]).actions,
            [.run, .edit, .duplicate, .remix, .export, .details]
        )
    }

    func testWholeRecordBindingRejectsSameIdentityAfterCapabilityMutation() throws {
        let original = runnableRecord()
        let binding = try ForgeHomeTrustBinding(authenticatedRecord: original)
        var changed = original
        changed.canExportSource = true
        let card = ForgeHomeProjector.makeCard(changed, trustedBindings: [binding])
        XCTAssertEqual(card.actions, [.details])
        XCTAssertFalse(card.runState.isRunnable)
    }

    func testWholeRecordBindingRejectsSameIdentityAfterEvidenceMutation() throws {
        let original = runnableRecord()
        let binding = try ForgeHomeTrustBinding(authenticatedRecord: original)
        var changed = original
        changed.runtimeEvidence = runtimeEvidence(level: .physicalDeviceVerified, revision: "rev")
        XCTAssertFalse(ForgeHomeProjector.makeCard(changed, trustedBindings: [binding]).runState.isRunnable)
    }

    func testCandidatePersistenceDoesNotRestoreTrust() throws {
        let original = runnableRecord()
        let binding = try ForgeHomeTrustBinding(authenticatedRecord: original)
        XCTAssertTrue(ForgeHomeProjector.makeCard(original, trustedBindings: [binding]).runState.isRunnable)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ForgeCreationRecord.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(ForgeHomeProjector.makeCard(decoded).runState.isRunnable)
    }

    func testUntrustedMissionCannotManipulateLibraryPriority() {
        let idle = ForgeCreationRecord(
            id: ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            name: "Idle newer project",
            lastChangedAt: now
        )
        let claimedActive = ForgeCreationRecord(
            id: ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            name: "Claimed active older project",
            lastChangedAt: now.addingTimeInterval(-100),
            activeMission: mission(updatedAt: now.addingTimeInterval(100))
        )
        XCTAssertEqual(ForgeHomeProjector.project([idle, claimedActive]).cards.map(\.name), ["Idle newer project", "Claimed active older project"])
    }

    func testTrustedMissionSortsBeforeIdleCreation() throws {
        let idle = ForgeCreationRecord(name: "Idle", lastChangedAt: now)
        let active = ForgeCreationRecord(name: "Active", lastChangedAt: now.addingTimeInterval(-100), activeMission: mission(updatedAt: now))
        let activeBinding = try ForgeHomeTrustBinding(authenticatedRecord: active)
        XCTAssertEqual(ForgeHomeProjector.project([idle, active], trustedBindings: [activeBinding]).cards.map(\.name), ["Active", "Idle"])
    }

    func testIdleOrderingIsDeterministic() {
        let firstID = ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondID = ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let records = [
            ForgeCreationRecord(id: secondID, name: "Second", lastChangedAt: now),
            ForgeCreationRecord(id: firstID, name: "First", lastChangedAt: now),
        ]
        XCTAssertEqual(ForgeHomeProjector.project(records).cards.map(\.id), [firstID, secondID])
    }

    func testBlankPersistedNameGetsHumanFallback() {
        XCTAssertEqual(ForgeHomeProjector.makeCard(ForgeCreationRecord(name: " \n ", lastChangedAt: now)).name, "Untitled Creation")
    }

    func testTrustBindingRejectsWhitespaceAliasRevision() {
        var record = runnableRecord()
        record.currentSourceRevision = " rev "
        XCTAssertThrowsError(try ForgeHomeTrustBinding(authenticatedRecord: record)) { error in
            XCTAssertEqual(error as? ForgeHomeTrustError, .nonCanonicalCurrentSourceRevision)
        }
    }

    func testTrustBindingRejectsControlCharacterRuntimeIdentity() {
        var record = runnableRecord()
        record.runtimeEvidence = ForgeRuntimeEvidence(
            artifactID: ForgeArtifactID(rawValue: "runtime\nrev"),
            runtimeKind: .forgeWeb,
            verificationLevel: .runtimeTested,
            sourceRevision: "rev",
            recordedAt: now
        )
        XCTAssertThrowsError(try ForgeHomeTrustBinding(authenticatedRecord: record)) { error in
            XCTAssertEqual(error as? ForgeHomeTrustError, .nonCanonicalRuntimeArtifact)
        }
    }

    func testTrustBindingRejectsBlankMissionStatus() {
        let record = ForgeCreationRecord(name: "Mission", lastChangedAt: now, activeMission: ForgeMissionReference(missionID: UUID(), state: .running, statusText: "  ", updatedAt: now))
        XCTAssertThrowsError(try ForgeHomeTrustBinding(authenticatedRecord: record)) { error in
            XCTAssertEqual(error as? ForgeHomeTrustError, .invalidMissionStatus)
        }
    }

    private func runnableRecord(
        revision: String = "rev",
        kind: ForgeRuntimeEvidence.RuntimeKind = .forgeWeb,
        level: ForgeRuntimeEvidence.VerificationLevel = .runtimeTested
    ) -> ForgeCreationRecord {
        ForgeCreationRecord(
            id: ForgeCreationID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
            name: "Neon Racer",
            lastChangedAt: now,
            currentSourceRevision: revision,
            runtimeEvidence: ForgeRuntimeEvidence(
                artifactID: ForgeArtifactID(rawValue: "runtime-\(revision)"),
                runtimeKind: kind,
                verificationLevel: level,
                sourceRevision: revision,
                recordedAt: now
            ),
            thumbnailEvidence: screenshot(revision: revision)
        )
    }

    private func runtimeEvidence(level: ForgeRuntimeEvidence.VerificationLevel, revision: String) -> ForgeRuntimeEvidence {
        ForgeRuntimeEvidence(artifactID: ForgeArtifactID(rawValue: "runtime-\(revision)"), runtimeKind: .forgeWeb, verificationLevel: level, sourceRevision: revision, recordedAt: now)
    }

    private func screenshot(revision: String) -> ForgeThumbnailEvidence {
        ForgeThumbnailEvidence(artifactID: ForgeArtifactID(rawValue: "screenshot-\(revision)"), kind: .runtimeScreenshot, sourceRevision: revision, recordedAt: now)
    }

    private func mission(updatedAt: Date) -> ForgeMissionReference {
        ForgeMissionReference(missionID: UUID(), state: .running, statusText: "Building project", updatedAt: updatedAt)
    }
}
