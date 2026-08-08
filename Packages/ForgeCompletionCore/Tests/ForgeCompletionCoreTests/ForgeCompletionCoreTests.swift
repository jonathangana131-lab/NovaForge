import Foundation
import XCTest
@testable import ForgeCompletionCore

final class ForgeCompletionCoreTests: XCTestCase {
    private func scope(projectRevision: UInt64 = 7, checkpoint: String = "cp-7") throws -> ForgeCompletionScope {
        try .init(projectID: "project", projectRevision: projectRevision, missionID: "mission", missionRevision: 4, checkpointID: checkpoint)
    }

    private func environment(_ kind: ForgeCompletionEnvironmentKind = .simulator, _ identity: String = "iPhone13,2/iOS27-sim") throws -> ForgeCompletionEvidenceEnvironment {
        try .init(kind: kind, identity: identity)
    }

    private func criterion(
        id: String,
        kind: ForgeCompletionCriterionKind,
        evidence: [ForgeCompletionEvidenceClass],
        environment: ForgeCompletionEnvironmentRequirement = .any
    ) throws -> ForgeCompletionCriterion {
        try .init(id: id, kind: kind, title: id, requiredEvidenceClasses: evidence, environmentRequirement: environment)
    }

    private func constitution(
        scope: ForgeCompletionScope? = nil,
        criteria: [ForgeCompletionCriterion]? = nil,
        allowsKnownLimitations: Bool = true
    ) throws -> ForgeCompletionConstitution {
        let scope = try scope ?? self.scope()
        let defaultCriteria = [
            try criterion(id: "build", kind: .build, evidence: [.buildReceipt]),
            try criterion(id: "defects", kind: .defectAudit, evidence: [.defectAudit]),
        ]
        return try .init(
            constitutionID: "done-v1",
            constitutionRevision: 1,
            scope: scope,
            criteria: criteria ?? defaultCriteria,
            allowsKnownLimitations: allowsKnownLimitations
        )
    }

    private func receipt(
        id: String,
        criterionID: String,
        evidenceClass: ForgeCompletionEvidenceClass,
        producer: ForgeCompletionEvidenceProducer,
        verdict: ForgeCompletionEvidenceVerdict = .passed,
        scope: ForgeCompletionScope? = nil,
        environment: ForgeCompletionEvidenceEnvironment? = nil
    ) throws -> ForgeCompletionEvidenceReceipt {
        try .init(
            receiptID: id,
            criterionID: criterionID,
            evidenceClass: evidenceClass,
            producer: producer,
            verdict: verdict,
            scope: try scope ?? self.scope(),
            environment: try environment ?? self.environment(),
            evidenceRevision: 1,
            summary: "evidence"
        )
    }

    private func passingArchive(scope: ForgeCompletionScope? = nil) throws -> ForgeCompletionEvidenceArchive {
        let s = try scope ?? self.scope()
        return try .init(receipts: [
            try receipt(id: "build-r", criterionID: "build", evidenceClass: .buildReceipt, producer: .buildSystem, scope: s),
            try receipt(id: "defect-r", criterionID: "defects", evidenceClass: .defectAudit, producer: .defectTracker, scope: s),
        ])
    }

    func testExactCurrentEvidenceCompletes() throws {
        let c = try constitution()
        let result = ForgeCompletionGate.assess(
            constitution: c,
            evidence: try passingArchive(),
            defects: try .init(defects: [], knownLimitations: [])
        )
        XCTAssertEqual(result.disposition, .completeWithEvidence)
        XCTAssertTrue(result.blockers.isEmpty)
    }

    func testModelAssertionCanNeverSatisfyCriterion() throws {
        XCTAssertThrowsError(try criterion(id: "fake", kind: .custom, evidence: [.modelAssertion])) {
            XCTAssertEqual($0 as? ForgeCompletionValidationError, .modelAssertionCannotBeRequired("fake"))
        }

        let c = try constitution()
        let model = try receipt(id: "model-done", criterionID: "build", evidenceClass: .modelAssertion, producer: .model, scope: c.scope, environment: environment(.modelOnly, "model"))
        let archive = try ForgeCompletionEvidenceArchive(receipts: [model])
        let result = ForgeCompletionGate.assess(constitution: c, evidence: archive, defects: try .init(defects: [], knownLimitations: []))
        XCTAssertEqual(result.disposition, .incomplete)
        XCTAssertEqual(result.ignoredModelAssertionReceiptIDs, ["model-done"])
    }

    func testStaleProjectRevisionEvidenceDoesNotCount() throws {
        let c = try constitution()
        let staleScope = try scope(projectRevision: 6, checkpoint: "cp-6")
        let result = ForgeCompletionGate.assess(
            constitution: c,
            evidence: try passingArchive(scope: staleScope),
            defects: try .init(defects: [], knownLimitations: [])
        )
        XCTAssertEqual(result.disposition, .incomplete)
        XCTAssertEqual(result.criteria.map(\.result), [.missingEvidence, .missingEvidence])
    }

    func testFailedEvidenceBlocksEvenWhenOtherCriteriaPass() throws {
        let c = try constitution()
        let archive = try ForgeCompletionEvidenceArchive(receipts: [
            try receipt(id: "build-r", criterionID: "build", evidenceClass: .buildReceipt, producer: .buildSystem, verdict: .failed),
            try receipt(id: "defect-r", criterionID: "defects", evidenceClass: .defectAudit, producer: .defectTracker),
        ])
        let result = ForgeCompletionGate.assess(constitution: c, evidence: archive, defects: try .init(defects: [], knownLimitations: []))
        XCTAssertEqual(result.disposition, .incomplete)
        XCTAssertTrue(result.blockers.contains(.criterion("build", .failedEvidence)))
    }

    func testPhysicalPerformanceCannotBeProvenBySimulator() throws {
        let criteria = [
            try criterion(id: "perf", kind: .performance, evidence: [.performanceMeasurement], environment: .physicalDevice),
            try criterion(id: "defects", kind: .defectAudit, evidence: [.defectAudit]),
        ]
        let c = try constitution(criteria: criteria)
        let archive = try ForgeCompletionEvidenceArchive(receipts: [
            try receipt(id: "perf-r", criterionID: "perf", evidenceClass: .performanceMeasurement, producer: .performanceHarness),
            try receipt(id: "defect-r", criterionID: "defects", evidenceClass: .defectAudit, producer: .defectTracker),
        ])
        let result = ForgeCompletionGate.assess(constitution: c, evidence: archive, defects: try .init(defects: [], knownLimitations: []))
        XCTAssertTrue(result.blockers.contains(.criterion("perf", .environmentMismatch)))
    }

    func testSimulatorVisualEvidenceCanBeAcceptedWhenConstitutionAllowsIt() throws {
        let criteria = [
            try criterion(id: "visual", kind: .visual, evidence: [.visualInspection], environment: .simulatorOrPhysical),
            try criterion(id: "defects", kind: .defectAudit, evidence: [.defectAudit]),
        ]
        let c = try constitution(criteria: criteria)
        let archive = try ForgeCompletionEvidenceArchive(receipts: [
            try receipt(id: "visual-r", criterionID: "visual", evidenceClass: .visualInspection, producer: .visualQA),
            try receipt(id: "defect-r", criterionID: "defects", evidenceClass: .defectAudit, producer: .defectTracker),
        ])
        XCTAssertEqual(ForgeCompletionGate.assess(constitution: c, evidence: archive, defects: try .init(defects: [], knownLimitations: [])).disposition, .completeWithEvidence)
    }

    func testHighDefectBlocksEvenWhenDisclosedAsLimitation() throws {
        let c = try constitution()
        let defect = try ForgeCompletionDefect(defectID: "crash", scope: c.scope, severity: .high, state: .deferred, summary: "crash")
        let limitation = try ForgeCompletionKnownLimitation(limitationID: "lim", relatedDefectID: "crash", summary: "known crash")
        let result = ForgeCompletionGate.assess(
            constitution: c,
            evidence: try passingArchive(),
            defects: try .init(defects: [defect], knownLimitations: [limitation])
        )
        XCTAssertEqual(result.disposition, .incomplete)
        XCTAssertTrue(result.blockers.contains(.unresolvedSevereDefect("crash")))
    }

    func testMediumDefectMustBeExplicitlyDisclosed() throws {
        let c = try constitution()
        let defect = try ForgeCompletionDefect(defectID: "spacing", scope: c.scope, severity: .medium, state: .open, summary: "spacing")
        let result = ForgeCompletionGate.assess(
            constitution: c,
            evidence: try passingArchive(),
            defects: try .init(defects: [defect], knownLimitations: [])
        )
        XCTAssertTrue(result.blockers.contains(.undisclosedDefect("spacing")))
    }

    func testAllowedKnownLimitationProducesExplicitCompletionState() throws {
        let c = try constitution(allowsKnownLimitations: true)
        let defect = try ForgeCompletionDefect(defectID: "spacing", scope: c.scope, severity: .low, state: .deferred, summary: "spacing")
        let limitation = try ForgeCompletionKnownLimitation(limitationID: "lim", relatedDefectID: "spacing", summary: "Minor spacing remains")
        let result = ForgeCompletionGate.assess(
            constitution: c,
            evidence: try passingArchive(),
            defects: try .init(defects: [defect], knownLimitations: [limitation])
        )
        XCTAssertEqual(result.disposition, .completeWithKnownLimitations)
    }

    func testKnownLimitationsCannotBypassConstitutionPolicy() throws {
        let c = try constitution(allowsKnownLimitations: false)
        let limitation = try ForgeCompletionKnownLimitation(limitationID: "lim", summary: "Unsupported optional export")
        let result = ForgeCompletionGate.assess(
            constitution: c,
            evidence: try passingArchive(),
            defects: try .init(defects: [], knownLimitations: [limitation])
        )
        XCTAssertEqual(result.disposition, .incomplete)
        XCTAssertTrue(result.blockers.contains(.knownLimitationsNotAllowed))
    }

    func testConflictingCurrentEvidenceFailsClosedAtArchiveBoundary() throws {
        let a = try receipt(id: "a", criterionID: "build", evidenceClass: .buildReceipt, producer: .buildSystem)
        let b = try receipt(id: "b", criterionID: "build", evidenceClass: .buildReceipt, producer: .buildSystem, verdict: .failed)
        XCTAssertThrowsError(try ForgeCompletionEvidenceArchive(receipts: [a, b])) {
            XCTAssertEqual($0 as? ForgeCompletionValidationError, .conflictingCurrentEvidence("build"))
        }
    }

    func testEvidenceClassMustMatchProducerAuthority() throws {
        XCTAssertThrowsError(
            try receipt(id: "spoof", criterionID: "perf", evidenceClass: .performanceMeasurement, producer: .model)
        ) {
            XCTAssertEqual($0 as? ForgeCompletionValidationError, .evidenceProducerMismatch)
        }
    }

    func testConstitutionRequiresDefectAudit() throws {
        let c = try criterion(id: "build", kind: .build, evidence: [.buildReceipt])
        XCTAssertThrowsError(
            try ForgeCompletionConstitution(constitutionID: "done", constitutionRevision: 1, scope: scope(), criteria: [c], allowsKnownLimitations: false)
        ) {
            XCTAssertEqual($0 as? ForgeCompletionValidationError, .missingDefectAuditCriterion)
        }
    }

    func testDuplicateCriterionFailsClosed() throws {
        let a = try criterion(id: "defects", kind: .defectAudit, evidence: [.defectAudit])
        let b = try criterion(id: "defects", kind: .custom, evidence: [.userAcceptance])
        XCTAssertThrowsError(
            try ForgeCompletionConstitution(constitutionID: "done", constitutionRevision: 1, scope: scope(), criteria: [a, b], allowsKnownLimitations: false)
        ) {
            XCTAssertEqual($0 as? ForgeCompletionValidationError, .duplicateCriterionID("defects"))
        }
    }

    func testDefectAuditCriterionMustRequireDefectEvidence() throws {
        XCTAssertThrowsError(
            try criterion(id: "defects", kind: .defectAudit, evidence: [.userAcceptance])
        ) {
            XCTAssertEqual($0 as? ForgeCompletionValidationError, .defectAuditMustRequireDefectEvidence("defects"))
        }
    }

    func testExactIdentityRejectsWhitespaceAliases() throws {
        XCTAssertThrowsError(
            try ForgeCompletionScope(projectID: " project", projectRevision: 1, missionID: "mission", missionRevision: 1, checkpointID: "cp")
        ) {
            XCTAssertEqual($0 as? ForgeCompletionValidationError, .nonCanonicalField("projectID"))
        }
    }

    func testConstitutionDecodeRevalidatesTamperedSchema() throws {
        let c = try constitution()
        let encoded = try JSONEncoder().encode(c)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 99
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompletionConstitution.self, from: tampered)) {
            XCTAssertEqual($0 as? ForgeCompletionValidationError, .unknownSchema(99))
        }
    }

    func testReceiptDecodeRevalidatesProducerClassPair() throws {
        let receipt = try self.receipt(id: "build", criterionID: "build", evidenceClass: .buildReceipt, producer: .buildSystem)
        let encoded = try JSONEncoder().encode(receipt)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["producer"] = ForgeCompletionEvidenceProducer.model.rawValue
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ForgeCompletionEvidenceReceipt.self, from: tampered)) {
            XCTAssertEqual($0 as? ForgeCompletionValidationError, .evidenceProducerMismatch)
        }
    }

    func testExactEnvironmentIdentityRejectsNearbyDeviceEvidence() throws {
        let exact = try environment(.physicalDevice, "iPhone13,2/iOS27/buildA")
        let nearby = try environment(.physicalDevice, "iPhone13,2/iOS27/buildB")
        let criteria = [
            try criterion(id: "perf", kind: .performance, evidence: [.performanceMeasurement], environment: .exact(exact)),
            try criterion(id: "defects", kind: .defectAudit, evidence: [.defectAudit]),
        ]
        let c = try constitution(criteria: criteria)
        let archive = try ForgeCompletionEvidenceArchive(receipts: [
            try receipt(id: "perf", criterionID: "perf", evidenceClass: .performanceMeasurement, producer: .performanceHarness, environment: nearby),
            try receipt(id: "defects", criterionID: "defects", evidenceClass: .defectAudit, producer: .defectTracker),
        ])
        let result = ForgeCompletionGate.assess(constitution: c, evidence: archive, defects: try .init(defects: [], knownLimitations: []))
        XCTAssertTrue(result.blockers.contains(.criterion("perf", .environmentMismatch)))
    }
}
