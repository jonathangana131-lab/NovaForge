import Foundation
import XCTest
@testable import ForgeCompletionCore

final class ForgeCompletionCoreTests: XCTestCase {
    private func target(
        missionID: String = "mission-1",
        sourceRevision: String = "source-abc",
        constitutionRevision: Int = 4,
        constitutionReceiptID: String = "constitution-receipt-4"
    ) throws -> ForgeCompletionTarget {
        try ForgeCompletionTarget(
            missionID: missionID,
            projectID: "project-1",
            sourceRevision: sourceRevision,
            constitutionRevision: constitutionRevision,
            constitutionReceiptID: constitutionReceiptID
        )
    }

    private func criterion(
        _ id: String,
        kind: ForgeCompletionCriterionKind,
        evidenceClasses: [ForgeCompletionEvidenceClass],
        journeys: [String] = [],
        requirement: ForgeCompletionRequirement = .required
    ) throws -> ForgeCompletionCriterion {
        try ForgeCompletionCriterion(
            id: id,
            kind: kind,
            title: "Criterion \(id)",
            requirement: requirement,
            requiredEvidenceClasses: evidenceClasses,
            journeyIDs: journeys
        )
    }

    private func constitution(_ criteria: [ForgeCompletionCriterion]) throws -> ForgeCompletionConstitution {
        try ForgeCompletionConstitution(target: target(), criteria: criteria)
    }

    private func authority(for evidenceClass: ForgeCompletionEvidenceClass) -> ForgeCompletionEvidenceAuthority {
        switch evidenceClass {
        case .buildReceipt:
            return .buildSystem
        case .launchReceipt, .runtimeJourney:
            return .runtimeHarness
        case .semanticPlaytest:
            return .playtestHarness
        case .persistenceReceipt:
            return .persistenceHarness
        case .visualQAReceipt:
            return .visualQA
        case .accessibilityReceipt:
            return .accessibilityHarness
        case .performanceReceipt:
            return .performanceHarness
        case .testReceipt:
            return .testHarness
        case .acceptedExternalReceipt:
            return .acceptedExternal
        }
    }

    private func evidence(
        _ id: String,
        criterionID: String,
        evidenceClass: ForgeCompletionEvidenceClass,
        journeyID: String? = nil,
        outcome: ForgeCompletionEvidenceOutcome = .passed,
        target: ForgeCompletionTarget? = nil,
        authority: ForgeCompletionEvidenceAuthority? = nil
    ) throws -> ForgeCompletionEvidence {
        try ForgeCompletionEvidence(
            id: id,
            target: target ?? self.target(),
            criterionID: criterionID,
            evidenceClass: evidenceClass,
            journeyID: journeyID,
            authority: authority ?? self.authority(for: evidenceClass),
            authorityReceiptID: "authority-\(id)",
            outcome: outcome
        )
    }

    private func emptyInventory(target: ForgeCompletionTarget? = nil) throws -> ForgeCompletionDefectInventory {
        try ForgeCompletionDefectInventory(
            target: target ?? self.target(),
            authorityReceiptID: "defect-scan-1",
            defects: []
        )
    }

    func testMissingRequiredEvidenceBlocksCompletion() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let runtime = try criterion(
            "runtime",
            kind: .runtimeStability,
            evidenceClasses: [.runtimeJourney],
            journeys: ["journey-main"]
        )
        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution([build, runtime]),
            evidence: [try evidence("build-pass", criterionID: "build", evidenceClass: .buildReceipt)],
            defectInventory: emptyInventory()
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertTrue(evaluation.blockers.contains(.missingEvidence(
            criterionID: "runtime",
            evidenceClass: .runtimeJourney,
            journeyID: "journey-main"
        )))
    }

    func testAllRequiredEvidenceAndCleanDefectInventorySatisfyAcceptance() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let launch = try criterion("launch", kind: .launch, evidenceClasses: [.launchReceipt])
        let play = try criterion(
            "play",
            kind: .goalPath,
            evidenceClasses: [.semanticPlaytest, .runtimeJourney],
            journeys: ["win", "restart"]
        )
        let items = [
            try evidence("build", criterionID: "build", evidenceClass: .buildReceipt),
            try evidence("launch", criterionID: "launch", evidenceClass: .launchReceipt),
            try evidence("play-win", criterionID: "play", evidenceClass: .semanticPlaytest, journeyID: "win"),
            try evidence("runtime-win", criterionID: "play", evidenceClass: .runtimeJourney, journeyID: "win"),
            try evidence("play-restart", criterionID: "play", evidenceClass: .semanticPlaytest, journeyID: "restart"),
            try evidence("runtime-restart", criterionID: "play", evidenceClass: .runtimeJourney, journeyID: "restart"),
        ]

        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution([play, launch, build]),
            evidence: items,
            defectInventory: emptyInventory()
        )

        XCTAssertEqual(evaluation.status, .satisfied)
        XCTAssertTrue(evaluation.blockers.isEmpty)
        XCTAssertEqual(Set(evaluation.acceptedEvidenceIDs), Set(items.map(\.id)))
    }

    func testFailedEvidenceCannotMasqueradeAsDone() throws {
        let visual = try criterion("visual", kind: .visualAcceptance, evidenceClasses: [.visualQAReceipt])
        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution([visual]),
            evidence: [try evidence(
                "visual-fail",
                criterionID: "visual",
                evidenceClass: .visualQAReceipt,
                outcome: .failed
            )],
            defectInventory: emptyInventory()
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertTrue(evaluation.blockers.contains(.evidenceNotPassed(
            criterionID: "visual",
            evidenceClass: .visualQAReceipt,
            journeyID: nil,
            outcome: .failed
        )))
    }

    func testEveryDeclaredJourneyNeedsItsOwnProof() throws {
        let controls = try criterion(
            "controls",
            kind: .controls,
            evidenceClasses: [.semanticPlaytest],
            journeys: ["new-player", "chaos"]
        )
        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution([controls]),
            evidence: [try evidence(
                "new-player-pass",
                criterionID: "controls",
                evidenceClass: .semanticPlaytest,
                journeyID: "new-player"
            )],
            defectInventory: emptyInventory()
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertTrue(evaluation.blockers.contains(.missingEvidence(
            criterionID: "controls",
            evidenceClass: .semanticPlaytest,
            journeyID: "chaos"
        )))
    }

    func testEvidenceFromAnotherSourceRevisionFailsClosed() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let staleTarget = try target(sourceRevision: "source-old")

        XCTAssertThrowsError(
            try ForgeCompletionEvaluator.evaluate(
                constitution: constitution([build]),
                evidence: [try evidence(
                    "stale-build",
                    criterionID: "build",
                    evidenceClass: .buildReceipt,
                    target: staleTarget
                )],
                defectInventory: emptyInventory()
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .targetMismatch("evidence:stale-build"))
        }
    }

    func testEvidenceFromAnotherMissionFailsClosed() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let otherMission = try target(missionID: "mission-2")

        XCTAssertThrowsError(
            try ForgeCompletionEvaluator.evaluate(
                constitution: constitution([build]),
                evidence: [try evidence(
                    "other-mission-build",
                    criterionID: "build",
                    evidenceClass: .buildReceipt,
                    target: otherMission
                )],
                defectInventory: emptyInventory()
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .targetMismatch("evidence:other-mission-build"))
        }
    }

    func testEvidenceFromAnotherConstitutionReceiptFailsClosed() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let otherConstitution = try target(constitutionReceiptID: "constitution-receipt-other")

        XCTAssertThrowsError(
            try ForgeCompletionEvaluator.evaluate(
                constitution: constitution([build]),
                evidence: [try evidence(
                    "other-constitution-build",
                    criterionID: "build",
                    evidenceClass: .buildReceipt,
                    target: otherConstitution
                )],
                defectInventory: emptyInventory()
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .targetMismatch("evidence:other-constitution-build"))
        }
    }

    func testDuplicateEvidenceSlotIsRejectedRatherThanChoosingConvenientResult() throws {
        let launch = try criterion("launch", kind: .launch, evidenceClasses: [.launchReceipt])
        XCTAssertThrowsError(
            try ForgeCompletionEvaluator.evaluate(
                constitution: constitution([launch]),
                evidence: [
                    try evidence("launch-pass", criterionID: "launch", evidenceClass: .launchReceipt),
                    try evidence("launch-fail", criterionID: "launch", evidenceClass: .launchReceipt, outcome: .failed),
                ],
                defectInventory: emptyInventory()
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompletionError,
                .duplicateEvidenceSlot("launch|launchReceipt|-")
            )
        }
    }

    func testEvidenceAuthorityMustMatchEvidenceClass() throws {
        XCTAssertThrowsError(
            try evidence(
                "fake-visual",
                criterionID: "visual",
                evidenceClass: .visualQAReceipt,
                authority: .testHarness
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .invalidEvidenceAuthority("fake-visual"))
        }
    }

    func testNoDefectInventoryMeansAcceptanceIsNotComplete() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution([build]),
            evidence: [try evidence("build", criterionID: "build", evidenceClass: .buildReceipt)],
            defectInventory: nil
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertTrue(evaluation.blockers.contains(.missingDefectInventory))
    }

    func testOpenHighAndCriticalDefectsAlwaysBlock() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let inventory = try ForgeCompletionDefectInventory(
            target: target(),
            authorityReceiptID: "defect-scan",
            defects: [
                try ForgeCompletionDefect(id: "high", severity: .high, status: .open, summary: "Save corrupts state"),
                try ForgeCompletionDefect(id: "critical", severity: .critical, status: .open, summary: "Launch crash"),
            ]
        )
        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution([build]),
            evidence: [try evidence("build", criterionID: "build", evidenceClass: .buildReceipt)],
            defectInventory: inventory
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertTrue(evaluation.blockers.contains(.unresolvedSevereDefect(defectID: "high", severity: .high)))
        XCTAssertTrue(evaluation.blockers.contains(.unresolvedSevereDefect(defectID: "critical", severity: .critical)))
    }

    func testOpenLowerSeverityDefectMustBeExplicitKnownLimitation() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let inventory = try ForgeCompletionDefectInventory(
            target: target(),
            authorityReceiptID: "defect-scan",
            defects: [try ForgeCompletionDefect(
                id: "minor",
                severity: .medium,
                status: .open,
                summary: "Minor visual mismatch"
            )]
        )

        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution([build]),
            evidence: [try evidence("build", criterionID: "build", evidenceClass: .buildReceipt)],
            defectInventory: inventory
        )

        XCTAssertEqual(evaluation.status, .blocked)
        XCTAssertTrue(evaluation.blockers.contains(.undocumentedKnownDefect(defectID: "minor")))
    }

    func testAcceptedKnownLimitationCanDiscloseLowerSeverityOpenDefect() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let inventory = try ForgeCompletionDefectInventory(
            target: target(),
            authorityReceiptID: "defect-scan",
            defects: [try ForgeCompletionDefect(
                id: "minor",
                severity: .low,
                status: .open,
                summary: "Cosmetic edge case"
            )]
        )
        let limitation = try ForgeCompletionKnownLimitation(
            id: "limitation-minor",
            target: target(),
            text: "Cosmetic edge case remains visible in the disclosed fallback state.",
            coveredDefectIDs: ["minor"],
            authorityReceiptID: "accepted-limitation-1"
        )

        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution([build]),
            evidence: [try evidence("build", criterionID: "build", evidenceClass: .buildReceipt)],
            defectInventory: inventory,
            knownLimitations: [limitation]
        )

        XCTAssertEqual(evaluation.status, .satisfiedWithKnownLimitations)
        XCTAssertTrue(evaluation.blockers.isEmpty)
        XCTAssertEqual(evaluation.knownLimitationIDs, ["limitation-minor"])
    }

    func testLimitationCannotHideSevereDefect() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let inventory = try ForgeCompletionDefectInventory(
            target: target(),
            authorityReceiptID: "defect-scan",
            defects: [try ForgeCompletionDefect(
                id: "severe",
                severity: .high,
                status: .open,
                summary: "Broken primary control"
            )]
        )
        let limitation = try ForgeCompletionKnownLimitation(
            id: "bad-waiver",
            target: target(),
            text: "Attempt to disclose instead of fix.",
            coveredDefectIDs: ["severe"],
            authorityReceiptID: "limitation-receipt"
        )

        XCTAssertThrowsError(
            try ForgeCompletionEvaluator.evaluate(
                constitution: constitution([build]),
                evidence: [try evidence("build", criterionID: "build", evidenceClass: .buildReceipt)],
                defectInventory: inventory,
                knownLimitations: [limitation]
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .invalidLimitationDefectReference("severe"))
        }
    }

    func testExplicitWaiverIsReceiptBoundAndNeverNeedsFakePassingEvidence() throws {
        let waiver = try ForgeCompletionWaiver(
            explanation: "Accessibility criterion is explicitly out of scope for this accepted experiment.",
            authorityReceiptID: "waiver-authority-1"
        )
        let accessibility = try criterion(
            "a11y",
            kind: .accessibility,
            evidenceClasses: [.accessibilityReceipt],
            requirement: .waived(waiver)
        )
        let evaluation = try ForgeCompletionEvaluator.evaluate(
            constitution: constitution([accessibility]),
            evidence: [],
            defectInventory: emptyInventory()
        )

        XCTAssertEqual(evaluation.status, .satisfiedWithKnownLimitations)
        XCTAssertEqual(evaluation.waivedCriterionIDs, ["a11y"])
    }

    func testEvidenceForWaivedCriterionIsRejectedInsteadOfMintingSuccess() throws {
        let waiver = try ForgeCompletionWaiver(
            explanation: "Explicitly waived.",
            authorityReceiptID: "waiver-receipt"
        )
        let performance = try criterion(
            "perf",
            kind: .performance,
            evidenceClasses: [.performanceReceipt],
            requirement: .waived(waiver)
        )

        XCTAssertThrowsError(
            try ForgeCompletionEvaluator.evaluate(
                constitution: constitution([performance]),
                evidence: [try evidence("fake", criterionID: "perf", evidenceClass: .performanceReceipt)],
                defectInventory: emptyInventory()
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .evidenceForWaivedCriterion("perf"))
        }
    }

    func testNestedTargetDecodeRevalidatesConstitutionRevision() throws {
        let item = try evidence("build", criterionID: "build", evidenceClass: .buildReceipt)
        let data = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var nestedTarget = try XCTUnwrap(object["target"] as? [String: Any])
        nestedTarget["constitutionRevision"] = -1
        object["target"] = nestedTarget
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompletionEvidence.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .invalidRevision("target.constitutionRevision"))
        }
    }

    func testCriterionDecodeCannotBypassRequiredEvidenceValidation() throws {
        let item = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let data = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["requiredEvidenceClasses"] = []
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompletionCriterion.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .invalidCriterion("build"))
        }
    }

    func testConstitutionRejectsUnknownArchiveSchema() throws {
        let build = try criterion("build", kind: .build, evidenceClasses: [.buildReceipt])
        let value = try constitution([build])
        let data = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompletionConstitution.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .unsupportedSchema(99))
        }
    }

    func testModelObservationIsNotAValidCompletionEvidenceAuthority() throws {
        let item = try evidence("build", criterionID: "build", evidenceClass: .buildReceipt)
        let data = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["authority"] = "modelObservation"
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompletionEvidence.self, from: tampered))
    }

    func testTargetRejectsControlCharactersInAuthorityIdentity() throws {
        XCTAssertThrowsError(
            try ForgeCompletionTarget(
                missionID: "mission\u{0000}bad",
                projectID: "project",
                sourceRevision: "source",
                constitutionRevision: 1,
                constitutionReceiptID: "receipt"
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompletionError, .invalidIdentifier("target.missionID"))
        }
    }
}
