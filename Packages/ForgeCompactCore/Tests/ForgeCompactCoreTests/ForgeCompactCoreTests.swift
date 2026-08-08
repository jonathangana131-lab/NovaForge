import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactCoreTests: XCTestCase {
    func testAlwaysResidentContextMustBeRequired() throws {
        XCTAssertThrowsError(
            try ForgeCompactContextItem(
                id: "mission-policy",
                tier: .alwaysResident,
                estimatedTokens: 40,
                required: false
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .alwaysResidentItemMustBeRequired("mission-policy")
            )
        }
    }

    func testContextPlannerRejectsDuplicateIdentity() throws {
        let first = try ForgeCompactContextItem(
            id: "active-source",
            tier: .activeWorkingSet,
            estimatedTokens: 80,
            required: false,
            relevancePriority: 10
        )
        let duplicate = try ForgeCompactContextItem(
            id: "active-source",
            tier: .projectMemory,
            estimatedTokens: 40,
            required: false,
            relevancePriority: 3
        )

        XCTAssertThrowsError(
            try ForgeCompactContextPlanner.select(
                [first, duplicate],
                budget: ForgeCompactContextBudget(maximumTokens: 500)
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .duplicateContextItem("active-source"))
        }
    }

    func testMandatoryTruthCannotBeSilentlyDroppedToFitBudget() throws {
        let mission = try ForgeCompactContextItem(
            id: "mission",
            tier: .alwaysResident,
            estimatedTokens: 120,
            required: true
        )
        let privacy = try ForgeCompactContextItem(
            id: "privacy",
            tier: .alwaysResident,
            estimatedTokens: 90,
            required: true
        )

        XCTAssertThrowsError(
            try ForgeCompactContextPlanner.select(
                [mission, privacy],
                budget: ForgeCompactContextBudget(maximumTokens: 200)
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .mandatoryContextExceedsBudget(required: 210, budget: 200)
            )
        }
    }

    func testContextPlannerUsesTierThenExplicitRelevancePriority() throws {
        let mission = try ForgeCompactContextItem(
            id: "mission",
            tier: .alwaysResident,
            estimatedTokens: 100,
            required: true
        )
        let currentFailure = try ForgeCompactContextItem(
            id: "current-failure",
            tier: .activeWorkingSet,
            estimatedTokens: 100,
            required: false,
            relevancePriority: 100
        )
        let currentSource = try ForgeCompactContextItem(
            id: "current-source",
            tier: .activeWorkingSet,
            estimatedTokens: 100,
            required: false,
            relevancePriority: 50
        )
        let oldDecision = try ForgeCompactContextItem(
            id: "old-decision",
            tier: .projectMemory,
            estimatedTokens: 50,
            required: false,
            relevancePriority: 999
        )

        let plan = try ForgeCompactContextPlanner.select(
            [oldDecision, currentSource, mission, currentFailure],
            budget: ForgeCompactContextBudget(maximumTokens: 300)
        )

        XCTAssertEqual(plan.selectedIDs, ["mission", "current-failure", "current-source"])
        XCTAssertEqual(plan.droppedIDs, ["old-decision"])
        XCTAssertEqual(plan.totalEstimatedTokens, 300)
    }

    func testCapsuleCanonicalizesReferencesWithoutDroppingTruth() throws {
        let capsule = try makeCapsule(
            acceptedDecisionIDs: ["decision-b", "decision-a"],
            unresolvedDecisionIDs: ["decision-c"],
            evidenceReceiptIDs: ["receipt-z", "receipt-a"],
            knownDefectIDs: ["defect-2", "defect-1"]
        )

        XCTAssertEqual(capsule.acceptedDecisionIDs, ["decision-a", "decision-b"])
        XCTAssertEqual(capsule.unresolvedDecisionIDs, ["decision-c"])
        XCTAssertEqual(capsule.evidenceReceiptIDs, ["receipt-a", "receipt-z"])
        XCTAssertEqual(capsule.knownDefectIDs, ["defect-1", "defect-2"])
    }

    func testCapsuleRejectsAcceptedDecisionThatIsStillUnresolved() throws {
        XCTAssertThrowsError(
            try makeCapsule(
                acceptedDecisionIDs: ["decision-a"],
                unresolvedDecisionIDs: ["decision-a"]
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .conflictingDecisionReference("decision-a")
            )
        }
    }

    func testCapsuleDecodeRevalidatesSchema() throws {
        let capsule = try makeCapsule()
        let encoded = try JSONEncoder().encode(capsule)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeProjectCapsule.self, from: corrupted)) {
            error in
            XCTAssertEqual(error as? ForgeCompactError, .unsupportedCapsuleSchema(99))
        }
    }

    func testCapsuleDecodeRevalidatesMissionRevision() throws {
        let capsule = try makeCapsule()
        let encoded = try JSONEncoder().encode(capsule)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["missionRevision"] = 0
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeProjectCapsule.self, from: corrupted)) {
            error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidMissionRevision)
        }
    }

    func testPrefixReuseRequiresExactRuntimeTokenizerTemplateAndToolsIdentity() throws {
        let baseline = try prefixIdentity()
        XCTAssertTrue(ForgeCompactPrefixReuse.canReuse(previous: baseline, current: baseline))

        let changedTools = try prefixIdentity(toolSchemaRevision: "tools-v2")
        XCTAssertFalse(
            ForgeCompactPrefixReuse.canReuse(previous: baseline, current: changedTools)
        )

        let changedTokenizer = try prefixIdentity(tokenizerID: "tokenizer-v2")
        XCTAssertFalse(
            ForgeCompactPrefixReuse.canReuse(previous: baseline, current: changedTokenizer)
        )
    }

    func testSourceResearchNeverBecomesQualifiedCompatibility() throws {
        let sourceOnly = try ForgeCompactTechniqueEvidence(kind: .sourceReported)

        XCTAssertEqual(
            ForgeCompactTechniqueGate.availability(
                evidence: sourceOnly,
                explicitResearchOptIn: false
            ),
            .unavailable
        )
        XCTAssertEqual(
            ForgeCompactTechniqueGate.availability(
                evidence: sourceOnly,
                explicitResearchOptIn: true
            ),
            .experimental
        )
    }

    func testRuntimeObservationNeedsExactIdentityAndSuccessfulQualificationForExperiment() throws {
        XCTAssertThrowsError(
            try ForgeCompactTechniqueEvidence(
                kind: .runtimeObserved,
                qualificationSucceeded: true
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .missingQualificationIdentity)
        }

        let failed = try ForgeCompactTechniqueEvidence(
            kind: .runtimeObserved,
            runtimeIdentity: runtimeIdentity(),
            qualificationSucceeded: false
        )
        XCTAssertEqual(
            ForgeCompactTechniqueGate.availability(
                evidence: failed,
                explicitResearchOptIn: true
            ),
            .unavailable
        )
    }

    func testExactDeviceMeasurementQualifiesOnlySuccessfulExactProfile() throws {
        let failed = try ForgeCompactTechniqueEvidence(
            kind: .exactDeviceMeasured,
            runtimeIdentity: runtimeIdentity(),
            qualificationSucceeded: false
        )
        let passed = try ForgeCompactTechniqueEvidence(
            kind: .exactDeviceMeasured,
            runtimeIdentity: runtimeIdentity(),
            qualificationSucceeded: true
        )

        XCTAssertEqual(
            ForgeCompactTechniqueGate.availability(
                evidence: failed,
                explicitResearchOptIn: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            ForgeCompactTechniqueGate.availability(
                evidence: passed,
                explicitResearchOptIn: false
            ),
            .qualified
        )
    }

    func testPressureGovernorDegradesBeforeDiscardingAlwaysResidentTruth() {
        let elevated = ForgeCompactPressureGovernor.policy(for: .elevated)
        XCTAssertEqual(elevated.contextMode, .reduced)
        XCTAssertFalse(elevated.permitsSpeculativeDecoding)
        XCTAssertFalse(elevated.permitsExperimentalBeyondRAMByPressure)
        XCTAssertTrue(elevated.preservesAlwaysResidentTruth)

        let critical = ForgeCompactPressureGovernor.policy(for: .critical)
        XCTAssertEqual(critical.contextMode, .minimal)
        XCTAssertFalse(critical.permitsDeepModelTier)
        XCTAssertFalse(critical.permitsSpeculativeDecoding)
        XCTAssertFalse(critical.permitsExperimentalBeyondRAMByPressure)
        XCTAssertTrue(critical.preservesAlwaysResidentTruth)
    }

    private func makeCapsule(
        acceptedDecisionIDs: [String] = [],
        unresolvedDecisionIDs: [String] = [],
        evidenceReceiptIDs: [String] = [],
        knownDefectIDs: [String] = []
    ) throws -> ForgeProjectCapsule {
        try ForgeProjectCapsule(
            projectID: "project-1",
            missionID: "mission-1",
            checkpointID: "checkpoint-4",
            sourceRevision: "source-9",
            missionRevision: 4,
            acceptedDecisionIDs: acceptedDecisionIDs,
            unresolvedDecisionIDs: unresolvedDecisionIDs,
            evidenceReceiptIDs: evidenceReceiptIDs,
            knownDefectIDs: knownDefectIDs,
            estimatedTokens: 320
        )
    }

    private func prefixIdentity(
        tokenizerID: String = "tokenizer-v1",
        toolSchemaRevision: String = "tools-v1"
    ) throws -> ForgeCompactPrefixIdentity {
        try ForgeCompactPrefixIdentity(
            modelID: "model-a",
            modelRevision: "model-rev-3",
            tokenizerID: tokenizerID,
            runtimeID: "runtime-a",
            runtimeRevision: "runtime-rev-8",
            promptTemplateRevision: "template-v4",
            toolSchemaRevision: toolSchemaRevision,
            stablePrefixDigest: "sha256-prefix"
        )
    }

    private func runtimeIdentity() throws -> ForgeCompactRuntimeIdentity {
        try ForgeCompactRuntimeIdentity(
            modelID: "model-a",
            modelRevision: "model-rev-3",
            tokenizerID: "tokenizer-v1",
            runtimeID: "runtime-a",
            runtimeRevision: "runtime-rev-8",
            quantization: "q4-profile",
            kvType: "q8",
            contextTokens: 4_096,
            deviceModel: "iPhone13,2",
            osVersion: "27.0"
        )
    }
}
