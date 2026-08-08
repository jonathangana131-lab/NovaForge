import XCTest
@testable import ForgeCompactCore

final class ForgeCompactGovernorTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    func testKeepsActiveMeasuredLocalEnvelopeWhenStillEligible() {
        let active = envelope(id: "balanced", context: 8_192, peak: 2 * gib)
        let larger = envelope(id: "deeper", context: 16_384, peak: 3 * gib)

        let receipt = decide(activeEnvelopeID: active.id, envelopes: [larger, active])

        XCTAssertEqual(receipt.action, .keep(envelopeID: active.id))
        XCTAssertEqual(receipt.selectedEnvelope, active)
        XCTAssertTrue(receipt.candidateVerdicts.allSatisfy(\.isEligible))
    }

    func testSwitchesToHighestContextEnvelopeThatFitsMeasuredHeadroom() {
        let tooLarge = envelope(id: "16k", context: 16_384, peak: 4 * gib)
        let fits = envelope(id: "8k", context: 8_192, peak: 2 * gib)
        let smaller = envelope(id: "4k", context: 4_096, peak: 1 * gib)

        let receipt = decide(
            memoryBudget: 3 * gib,
            nominalReserve: gib / 2,
            envelopes: [smaller, tooLarge, fits]
        )

        XCTAssertEqual(receipt.action, .switchTo(envelopeID: fits.id))
        XCTAssertEqual(receipt.selectedEnvelope, fits)
        XCTAssertEqual(
            verdict(for: tooLarge.id, in: receipt)?.rejectionReasons,
            [.insufficientMeasuredHeadroom]
        )
    }

    func testWarningReserveCanForceLowerFootprintEnvelopeWithoutMagicThresholds() {
        let active = envelope(id: "active-8k", context: 8_192, peak: 2_700_000_000)
        let compact = envelope(id: "compact-4k", context: 4_096, peak: 1_800_000_000)

        let receipt = decide(
            memoryBudget: 3_200_000_000,
            memoryPressure: .warning,
            activeEnvelopeID: active.id,
            nominalReserve: 200_000_000,
            warningReserve: 800_000_000,
            envelopes: [active, compact]
        )

        XCTAssertEqual(receipt.action, .switchTo(envelopeID: compact.id))
        XCTAssertEqual(receipt.selectedEnvelope, compact)
        XCTAssertEqual(
            verdict(for: active.id, in: receipt)?.rejectionReasons,
            [.insufficientMeasuredHeadroom]
        )
    }

    func testCriticalMemoryPressureSuspendsBeforeSelection() {
        let receipt = decide(memoryPressure: .critical, envelopes: [envelope(id: "safe")])

        XCTAssertEqual(receipt.action, .suspend(reason: .memoryPressureThresholdReached))
        XCTAssertNil(receipt.selectedEnvelope)
        XCTAssertTrue(receipt.candidateVerdicts.isEmpty)
    }

    func testConfiguredSeriousThermalThresholdSuspends() {
        let receipt = decide(
            thermalPressure: .serious,
            suspendAtThermalPressure: .serious,
            envelopes: [envelope(id: "safe")]
        )

        XCTAssertEqual(receipt.action, .suspend(reason: .thermalPressureThresholdReached))
        XCTAssertNil(receipt.selectedEnvelope)
    }

    func testRemoteEnvelopeIsNeverSelected() {
        let remote = envelope(id: "hosted", location: .remote)

        let receipt = decide(envelopes: [remote])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertNil(receipt.selectedEnvelope)
        XCTAssertEqual(verdict(for: remote.id, in: receipt)?.rejectionReasons, [.nonLocalCompute])
    }

    func testProductionRejectsExperimentalEnvelope() {
        let experimental = envelope(
            id: "flash-paging-lab",
            evidence: .experimentalExactDeviceMeasured
        )

        let receipt = decide(envelopes: [experimental])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(
            verdict(for: experimental.id, in: receipt)?.rejectionReasons,
            [.experimentalDisallowed]
        )
    }

    func testResearchModeCanAdmitExactDeviceExperimentalEnvelope() {
        let experimental = envelope(
            id: "flash-paging-lab",
            evidence: .experimentalExactDeviceMeasured
        )

        let receipt = decide(mode: .research, envelopes: [experimental])

        XCTAssertEqual(receipt.action, .switchTo(envelopeID: experimental.id))
        XCTAssertEqual(receipt.selectedEnvelope, experimental)
        XCTAssertTrue(verdict(for: experimental.id, in: receipt)?.isEligible == true)
    }

    func testUnverifiedEnvelopeFailsClosedEvenInResearchMode() {
        let unverified = envelope(id: "paper-only", evidence: .unverified)

        let receipt = decide(mode: .research, envelopes: [unverified])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(
            verdict(for: unverified.id, in: receipt)?.rejectionReasons,
            [.unverifiedEvidence]
        )
    }

    func testMeasuredEnvelopeCannotSelfAuthorizeWithoutQualificationGrant() {
        let measured = envelope(id: "self-asserted")

        let receipt = decide(trustEvidence: false, envelopes: [measured])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertNil(receipt.selectedEnvelope)
        XCTAssertEqual(
            verdict(for: measured.id, in: receipt)?.rejectionReasons,
            [.qualificationGrantMissing]
        )
    }

    func testQualificationGrantMustMatchExactConfigurationBinding() throws {
        let measured = envelope(id: "qualified")
        let wrongGrant = try ForgeCompactQualificationGrant(
            profileID: measured.profileID,
            configurationBindingID: "different-binding",
            deviceProfileID: measured.deviceProfileID,
            evidenceReceiptID: measured.evidenceReceiptID
        )

        let receipt = decide(
            explicitGrants: [wrongGrant],
            envelopes: [measured]
        )

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(
            verdict(for: measured.id, in: receipt)?.rejectionReasons,
            [.qualificationGrantMissing]
        )
    }

    func testExactDeviceBindingMismatchIsRejected() {
        let otherDevice = envelope(id: "other-device", deviceProfileID: "iphone17,1-ios27")

        let receipt = decide(envelopes: [otherDevice])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(
            verdict(for: otherDevice.id, in: receipt)?.rejectionReasons,
            [.deviceProfileMismatch]
        )
    }

    func testContextNeverDropsBelowMissionMinimum() {
        let tooSmall = envelope(id: "2k", context: 2_048, peak: gib)

        let receipt = decide(
            requestedContext: 8_192,
            minimumContext: 4_096,
            envelopes: [tooSmall]
        )

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(
            verdict(for: tooSmall.id, in: receipt)?.rejectionReasons,
            [.contextBelowMissionMinimum]
        )
    }

    func testEnvelopeAboveRequestedContextIsRejectedInsteadOfSilentlyExpanding() {
        let tooWide = envelope(id: "32k", context: 32_768)

        let receipt = decide(requestedContext: 16_384, envelopes: [tooWide])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(
            verdict(for: tooWide.id, in: receipt)?.rejectionReasons,
            [.contextExceedsRequest]
        )
    }

    func testMissingPeakMeasurementCannotDriveMemoryDecision() {
        let invalid = envelope(id: "no-peak", peak: 0)

        let receipt = decide(envelopes: [invalid])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(
            verdict(for: invalid.id, in: receipt)?.rejectionReasons,
            [.invalidPeakMemoryMeasurement]
        )
    }

    func testEmptyEvidenceIdentityIsRejected() {
        let invalid = envelope(id: "bad-receipt", evidenceReceiptID: "   ")

        let receipt = decide(envelopes: [invalid])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(
            verdict(for: invalid.id, in: receipt)?.rejectionReasons,
            [.invalidIdentity, .qualificationGrantMissing]
        )
    }

    func testWhitespacePaddedEnvelopeIdentityIsRejectedInsteadOfNormalizedSilently() {
        let invalid = envelope(id: " padded-id ")

        let receipt = decide(envelopes: [invalid])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(verdict(for: invalid.id, in: receipt)?.rejectionReasons, [.invalidIdentity])
    }

    func testControlCharacterEnvelopeIdentityIsRejected() {
        let invalid = envelope(id: "bad\u{0000}id")

        let receipt = decide(envelopes: [invalid])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(verdict(for: invalid.id, in: receipt)?.rejectionReasons, [.invalidIdentity])
    }

    func testWhitespacePaddedActiveIdentityMakesSnapshotInvalid() {
        let receipt = decide(
            activeEnvelopeID: " active ",
            envelopes: [envelope(id: "active")]
        )

        XCTAssertEqual(receipt.action, .block(reason: .invalidRuntimeSnapshot))
        XCTAssertNil(receipt.selectedEnvelope)
        XCTAssertTrue(receipt.candidateVerdicts.isEmpty)
    }

    func testDuplicateEnvelopeIDsAreRejectedDeterministically() {
        let first = envelope(id: "duplicate", context: 4_096)
        let second = envelope(id: "duplicate", context: 8_192)

        let receipt = decide(envelopes: [first, second])

        XCTAssertEqual(receipt.action, .block(reason: .noEligibleLocalEnvelope))
        XCTAssertEqual(receipt.candidateVerdicts.count, 2)
        XCTAssertTrue(receipt.candidateVerdicts.allSatisfy {
            $0.rejectionReasons == [.duplicateEnvelopeID]
        })
    }

    func testStableSelectionPrefersLowerMeasuredPeakWhenContextMatches() {
        let larger = envelope(id: "same-context-larger", context: 8_192, peak: 2 * gib)
        let smaller = envelope(id: "same-context-smaller", context: 8_192, peak: gib)

        let receipt = decide(envelopes: [larger, smaller])

        XCTAssertEqual(receipt.action, .switchTo(envelopeID: smaller.id))
        XCTAssertEqual(receipt.selectedEnvelope, smaller)
    }

    func testStableSelectionUsesEnvelopeIDAsFinalTieBreaker() {
        let z = envelope(id: "z-profile", context: 8_192, peak: gib)
        let a = envelope(id: "a-profile", context: 8_192, peak: gib)

        let receipt = decide(envelopes: [z, a])

        XCTAssertEqual(receipt.action, .switchTo(envelopeID: a.id))
        XCTAssertEqual(receipt.selectedEnvelope, a)
    }

    func testInvalidSnapshotBlocksBeforeEvaluatingCandidates() {
        let receipt = decide(
            requestedContext: 2_048,
            minimumContext: 4_096,
            envelopes: [envelope(id: "safe")]
        )

        XCTAssertEqual(receipt.action, .block(reason: .invalidRuntimeSnapshot))
        XCTAssertNil(receipt.selectedEnvelope)
        XCTAssertTrue(receipt.candidateVerdicts.isEmpty)
    }

    func testInvalidReservePolicyBlocksBeforeEvaluatingCandidates() {
        let receipt = decide(
            nominalReserve: gib,
            warningReserve: gib / 2,
            envelopes: [envelope(id: "safe")]
        )

        XCTAssertEqual(receipt.action, .block(reason: .invalidPolicy))
        XCTAssertNil(receipt.selectedEnvelope)
        XCTAssertTrue(receipt.candidateVerdicts.isEmpty)
    }

    func testDecisionReceiptPreservesSelectedQualifiedEnvelope() {
        let measured = envelope(id: "measured")
        let receipt = decide(envelopes: [measured])

        XCTAssertEqual(receipt.action, .switchTo(envelopeID: measured.id))
        XCTAssertEqual(receipt.selectedEnvelope, measured)
        XCTAssertEqual(receipt.selectedEnvelope?.evidenceReceiptID, measured.evidenceReceiptID)
        XCTAssertEqual(receipt.selectedEnvelope?.configurationBindingID, measured.configurationBindingID)
    }

    private func envelope(
        id: String,
        deviceProfileID: String = "iphone13,2-ios27",
        evidenceReceiptID: String = "receipt-001",
        location: ForgeCompactComputeLocation = .local,
        evidence: ForgeCompactEvidenceStatus = .exactDeviceMeasured,
        context: UInt64 = 8_192,
        peak: UInt64? = nil
    ) -> ForgeCompactExecutionEnvelope {
        ForgeCompactExecutionEnvelope(
            id: id,
            profileID: "local-agent-q4",
            configurationBindingID: "binding-default",
            deviceProfileID: deviceProfileID,
            evidenceReceiptID: evidenceReceiptID,
            computeLocation: location,
            evidenceStatus: evidence,
            contextTokens: context,
            observedPeakResidentBytes: peak ?? 2 * gib
        )
    }

    private func grant(for envelope: ForgeCompactExecutionEnvelope) -> ForgeCompactQualificationGrant? {
        try? ForgeCompactQualificationGrant(
            profileID: envelope.profileID,
            configurationBindingID: envelope.configurationBindingID,
            deviceProfileID: envelope.deviceProfileID,
            evidenceReceiptID: envelope.evidenceReceiptID
        )
    }

    private func decide(
        memoryBudget: UInt64? = nil,
        requestedContext: UInt64 = 16_384,
        minimumContext: UInt64 = 4_096,
        memoryPressure: ForgeCompactMemoryPressure = .nominal,
        thermalPressure: ForgeCompactThermalPressure = .nominal,
        activeEnvelopeID: String? = nil,
        mode: ForgeCompactOperatingMode = .production,
        nominalReserve: UInt64? = nil,
        warningReserve: UInt64? = nil,
        suspendAtThermalPressure: ForgeCompactThermalPressure = .critical,
        trustEvidence: Bool = true,
        explicitGrants: Set<ForgeCompactQualificationGrant>? = nil,
        envelopes: [ForgeCompactExecutionEnvelope]
    ) -> ForgeCompactDecisionReceipt {
        let snapshot = ForgeCompactRuntimeSnapshot(
            deviceProfileID: "iphone13,2-ios27",
            requestedContextTokens: requestedContext,
            minimumMissionContextTokens: minimumContext,
            memoryBudgetBytes: memoryBudget ?? 4 * gib,
            activeEnvelopeID: activeEnvelopeID,
            memoryPressure: memoryPressure,
            thermalPressure: thermalPressure
        )
        let policy = ForgeCompactGovernorPolicy(
            operatingMode: mode,
            nominalReserveBytes: nominalReserve ?? gib / 4,
            warningReserveBytes: warningReserve ?? gib / 2,
            suspendAtMemoryPressure: .critical,
            suspendAtThermalPressure: suspendAtThermalPressure
        )
        let grants: Set<ForgeCompactQualificationGrant>
        if let explicitGrants {
            grants = explicitGrants
        } else if trustEvidence {
            grants = Set(envelopes.compactMap { grant(for: $0) })
        } else {
            grants = []
        }
        return ForgeCompactGovernor.decide(
            snapshot: snapshot,
            policy: policy,
            envelopes: envelopes,
            qualificationGrants: grants
        )
    }

    private func verdict(
        for id: String,
        in receipt: ForgeCompactDecisionReceipt
    ) -> ForgeCompactCandidateVerdict? {
        receipt.candidateVerdicts.first(where: { $0.envelopeID == id })
    }
}
