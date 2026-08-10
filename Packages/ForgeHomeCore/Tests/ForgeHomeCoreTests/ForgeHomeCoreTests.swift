import Foundation
import XCTest
@testable import ForgeHomeCore

final class ForgeHomeCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let creationID = ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
    private let otherCreationID = ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!)

    func testCreationPromptAndNewIntentRemainCreationFirst() {
        XCTAssertEqual(ForgeHomeSnapshot.creationPrompt, "What do you want to make?")
        XCTAssertFalse(ForgeNewCreationIntent(rawText: "  \n ").isReadyToPlan)
        XCTAssertEqual(
            ForgeNewCreationIntent(rawText: "  Build a driving game  ").normalizedText,
            "Build a driving game"
        )
    }

    func testCandidateRuntimeMetadataCannotAuthorizeRunByItself() throws {
        let record = try creationRecord()
        _ = try runtimeEvidence()

        let card = ForgeHomeProjector.makeCard(record)
        XCTAssertFalse(card.runState.isRunnable)
        XCTAssertEqual(card.actions, [.details])
    }

    func testAuthenticatedRuntimeForExactCreationRevisionAuthorizesRun() throws {
        let record = try creationRecord()
        let runtime = try ForgeTrustedRuntimeEvidence(authenticatedCandidate: runtimeEvidence())

        let card = ForgeHomeProjector.makeCard(
            ForgeHomeProjectionInput(record: record, runtimeEvidence: runtime)
        )

        XCTAssertTrue(card.runState.isRunnable)
        XCTAssertEqual(card.actions, [.run, .details])
    }

    func testGeneratedAndExternalRuntimeClaimsCannotBecomeTrusted() throws {
        XCTAssertThrowsError(
            try ForgeTrustedRuntimeEvidence(
                authenticatedCandidate: runtimeEvidence(level: .generated)
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHomeInvariantError, .runtimeEvidenceCannotBeTrusted)
        }
        XCTAssertThrowsError(
            try ForgeTrustedRuntimeEvidence(
                authenticatedCandidate: runtimeEvidence(kind: .externalNative, level: .physicalDeviceVerified)
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHomeInvariantError, .runtimeEvidenceCannotBeTrusted)
        }
    }

    func testTrustedRuntimeFailsClosedAcrossRevisionOrCreationIdentity() throws {
        let record = try creationRecord(revision: "r2")
        let stale = try ForgeTrustedRuntimeEvidence(
            authenticatedCandidate: runtimeEvidence(revision: "r1")
        )
        let foreign = try ForgeTrustedRuntimeEvidence(
            authenticatedCandidate: runtimeEvidence(creationID: otherCreationID, revision: "r2")
        )

        for runtime in [stale, foreign] {
            let card = ForgeHomeProjector.makeCard(
                ForgeHomeProjectionInput(record: record, runtimeEvidence: runtime)
            )
            XCTAssertFalse(card.runState.isRunnable)
            XCTAssertFalse(card.actions.contains(.run))
        }
    }

    func testActualThumbnailRequiresTrustedRuntimeAndTrustedScreenshotOnExactIdentity() throws {
        let record = try creationRecord()
        let runtime = try ForgeTrustedRuntimeEvidence(authenticatedCandidate: runtimeEvidence())
        let screenshot = try ForgeTrustedThumbnailEvidence(authenticatedCandidate: thumbnailEvidence())

        XCTAssertNil(
            ForgeHomeProjector.makeCard(
                ForgeHomeProjectionInput(record: record, thumbnailEvidence: screenshot)
            ).actualThumbnail
        )

        let card = ForgeHomeProjector.makeCard(
            ForgeHomeProjectionInput(
                record: record,
                runtimeEvidence: runtime,
                thumbnailEvidence: screenshot
            )
        )
        XCTAssertEqual(card.actualThumbnail, screenshot)
    }

    func testImportedReferenceCannotBecomeTrustedActualThumbnail() throws {
        XCTAssertThrowsError(
            try ForgeTrustedThumbnailEvidence(
                authenticatedCandidate: thumbnailEvidence(kind: .importedReference)
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHomeInvariantError, .thumbnailEvidenceCannotBeTrusted)
        }
    }

    func testThumbnailRejectsNonCanonicalDigest() throws {
        XCTAssertThrowsError(
            try ForgeThumbnailEvidence(
                creationID: creationID,
                artifactID: ForgeArtifactID(rawValue: "shot-r1"),
                artifactSHA256: String(repeating: "A", count: 64),
                kind: .runtimeScreenshot,
                sourceRevision: "r1",
                recordedAt: now,
                producerReceiptID: "visual-receipt-1"
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHomeInvariantError, .invalidArtifactDigest)
        }
    }

    func testTrustedCapabilitiesAreExactRevisionBoundAndUseStableOrder() throws {
        let record = try creationRecord()
        let claim = try ForgeCapabilityClaim(
            creationID: creationID,
            sourceRevision: "r1",
            capabilities: [.share, .export, .duplicate, .edit, .remix],
            producerReceiptID: "capability-receipt-1"
        )
        let trusted = ForgeTrustedCapabilityClaim(authenticatedCandidate: claim)

        let card = ForgeHomeProjector.makeCard(
            ForgeHomeProjectionInput(record: record, capabilityClaim: trusted)
        )
        XCTAssertEqual(card.actions, [.edit, .duplicate, .remix, .export, .share, .details])

        let staleRecord = try creationRecord(revision: "r2")
        XCTAssertEqual(
            ForgeHomeProjector.makeCard(
                ForgeHomeProjectionInput(record: staleRecord, capabilityClaim: trusted)
            ).actions,
            [.details]
        )
    }

    func testDuplicateCapabilityClaimFailsClosedIncludingAfterDecode() throws {
        XCTAssertThrowsError(
            try ForgeCapabilityClaim(
                creationID: creationID,
                sourceRevision: "r1",
                capabilities: [.edit, .edit],
                producerReceiptID: "capability-receipt-1"
            )
        ) { error in
            XCTAssertEqual(error as? ForgeHomeInvariantError, .duplicateCapability)
        }

        let valid = try ForgeCapabilityClaim(
            creationID: creationID,
            sourceRevision: "r1",
            capabilities: [.edit, .share],
            producerReceiptID: "capability-receipt-1"
        )
        let data = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["capabilities"] = ["edit", "edit"]
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCapabilityClaim.self, from: tampered))
    }

    func testTrustedMissionReferenceDrivesActiveOrderingOnlyWhenExact() throws {
        let activeRecord = try ForgeCreationRecord(
            id: creationID,
            name: "Active older",
            lastChangedAt: now.addingTimeInterval(-100),
            currentSourceRevision: "r1"
        )
        let idleRecord = try ForgeCreationRecord(
            id: otherCreationID,
            name: "Idle newer",
            lastChangedAt: now,
            currentSourceRevision: "r2"
        )
        let trustedMission = ForgeTrustedMissionReference(
            authenticatedCandidate: try missionReference(updatedAt: now.addingTimeInterval(-50))
        )

        let cards = ForgeHomeProjector.project([
            ForgeHomeProjectionInput(record: idleRecord),
            ForgeHomeProjectionInput(record: activeRecord, activeMission: trustedMission),
        ]).cards
        XCTAssertEqual(cards.map(\.name), ["Active older", "Idle newer"])

        let foreignMission = ForgeTrustedMissionReference(
            authenticatedCandidate: try missionReference(creationID: otherCreationID)
        )
        let noAuthorityCards = ForgeHomeProjector.project([
            ForgeHomeProjectionInput(record: idleRecord),
            ForgeHomeProjectionInput(record: activeRecord, activeMission: foreignMission),
        ]).cards
        XCTAssertEqual(noAuthorityCards.map(\.name), ["Idle newer", "Active older"])
    }

    func testMissingCurrentRevisionFailsClosed() throws {
        let record = try ForgeCreationRecord(
            id: creationID,
            name: "Unbound",
            lastChangedAt: now,
            currentSourceRevision: nil
        )
        let runtime = try ForgeTrustedRuntimeEvidence(authenticatedCandidate: runtimeEvidence())
        let capabilities = ForgeTrustedCapabilityClaim(
            authenticatedCandidate: try capabilityClaim()
        )

        let card = ForgeHomeProjector.makeCard(
            ForgeHomeProjectionInput(
                record: record,
                runtimeEvidence: runtime,
                capabilityClaim: capabilities
            )
        )
        XCTAssertEqual(card.actions, [.details])
        XCTAssertFalse(card.runState.isRunnable)
    }

    func testCreationRecordRejectsAliasRevisionOnConstructionAndDecode() throws {
        XCTAssertThrowsError(
            try ForgeCreationRecord(name: "Alias", lastChangedAt: now, currentSourceRevision: " r1 ")
        ) { error in
            XCTAssertEqual(error as? ForgeHomeInvariantError, .invalidSourceRevision)
        }

        let record = try creationRecord()
        let data = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["currentSourceRevision"] = " r1 "
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCreationRecord.self, from: tampered))
    }

    func testLegacyV13AuthorityFieldsAreIgnoredRatherThanRestored() throws {
        let record = try creationRecord()
        let data = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["runtimeEvidence"] = [
            "runtimeKind": "forgeWeb",
            "verificationLevel": "physicalDeviceVerified",
            "sourceRevision": "r1",
        ]
        object["thumbnailEvidence"] = ["kind": "runtimeScreenshot", "sourceRevision": "r1"]
        object["canEditSource"] = true
        object["canDuplicate"] = true
        object["canRemix"] = true
        object["canExportSource"] = true

        let legacyBytes = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ForgeCreationRecord.self, from: legacyBytes)
        XCTAssertEqual(decoded.currentSourceRevision, "r1")
        XCTAssertEqual(ForgeHomeProjector.makeCard(decoded).actions, [.details])
    }

    func testCandidateRuntimeRoundTripStillRequiresFreshHostTrust() throws {
        let candidate = try runtimeEvidence()
        let data = try JSONEncoder().encode(candidate)
        let restored = try JSONDecoder().decode(ForgeRuntimeEvidence.self, from: data)
        XCTAssertEqual(restored, candidate)

        let record = try creationRecord()
        XCTAssertEqual(ForgeHomeProjector.makeCard(record).actions, [.details])
        let reacquired = try ForgeTrustedRuntimeEvidence(authenticatedCandidate: restored)
        XCTAssertEqual(
            ForgeHomeProjector.makeCard(
                ForgeHomeProjectionInput(record: record, runtimeEvidence: reacquired)
            ).actions,
            [.run, .details]
        )
    }

    func testBlankNameGetsHumanFallbackAndIdleOrderingIsDeterministic() throws {
        let firstID = ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondID = ForgeCreationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let records = [
            try ForgeCreationRecord(id: secondID, name: "Second", lastChangedAt: now),
            try ForgeCreationRecord(id: firstID, name: " \n ", lastChangedAt: now),
        ]

        let cards = ForgeHomeProjector.project(records).cards
        XCTAssertEqual(cards.map(\.id), [firstID, secondID])
        XCTAssertEqual(cards.first?.name, "Untitled Creation")
    }

    private func creationRecord(revision: String = "r1") throws -> ForgeCreationRecord {
        try ForgeCreationRecord(
            id: creationID,
            name: "Neon Racer",
            lastChangedAt: now,
            currentSourceRevision: revision
        )
    }

    private func runtimeEvidence(
        creationID: ForgeCreationID? = nil,
        kind: ForgeRuntimeEvidence.RuntimeKind = .forgeWeb,
        level: ForgeRuntimeEvidence.VerificationLevel = .runtimeTested,
        revision: String = "r1"
    ) throws -> ForgeRuntimeEvidence {
        try ForgeRuntimeEvidence(
            creationID: creationID ?? self.creationID,
            artifactID: ForgeArtifactID(rawValue: "runtime-\(revision)"),
            runtimeKind: kind,
            verificationLevel: level,
            sourceRevision: revision,
            recordedAt: now,
            producerReceiptID: "runtime-receipt-1"
        )
    }

    private func thumbnailEvidence(
        kind: ForgeThumbnailEvidence.Kind = .runtimeScreenshot,
        revision: String = "r1"
    ) throws -> ForgeThumbnailEvidence {
        try ForgeThumbnailEvidence(
            creationID: creationID,
            artifactID: ForgeArtifactID(rawValue: "screenshot-\(revision)"),
            artifactSHA256: String(repeating: "a", count: 64),
            kind: kind,
            sourceRevision: revision,
            recordedAt: now,
            producerReceiptID: "visual-receipt-1"
        )
    }

    private func capabilityClaim() throws -> ForgeCapabilityClaim {
        try ForgeCapabilityClaim(
            creationID: creationID,
            sourceRevision: "r1",
            capabilities: [.edit, .duplicate, .share],
            producerReceiptID: "capability-receipt-1"
        )
    }

    private func missionReference(
        creationID: ForgeCreationID? = nil,
        updatedAt: Date? = nil
    ) throws -> ForgeMissionReference {
        try ForgeMissionReference(
            creationID: creationID ?? self.creationID,
            missionID: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
            sourceRevision: "r1",
            state: .running,
            statusText: "Building project",
            updatedAt: updatedAt ?? now,
            producerReceiptID: "mission-receipt-1"
        )
    }
}
