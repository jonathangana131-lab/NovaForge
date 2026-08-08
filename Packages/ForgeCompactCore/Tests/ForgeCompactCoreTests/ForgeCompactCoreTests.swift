import Foundation
import XCTest
@testable import ForgeCompactCore

final class ForgeCompactCoreTests: XCTestCase {
    private func makeCore() throws -> ForgeCompactCoreContext {
        try ForgeCompactCoreContext(
            missionID: "mission-42",
            projectID: "project-9",
            missionRevision: 12,
            authorityEpoch: 4,
            sourceAuthorityRevision: "checkpoint-sha-abc",
            currentObjective: "Repair the failing save/reload journey",
            currentStageID: "verify-save-reload",
            privacyPolicyReference: "policy-local-only-v3",
            localityPolicyReference: "local-only"
        )
    }

    private func binding(_ suffix: String) throws -> ForgeCompactSourceBinding {
        try ForgeCompactSourceBinding(
            authorityID: "source-\(suffix)",
            revision: "rev-\(suffix)"
        )
    }

    private func record(
        _ id: String,
        layer: ForgeCompactLayer = .activeWorkingSet,
        kind: ForgeCompactRecordKind = .sourceFact,
        provenance: ForgeCompactProvenance = .source,
        freshness: ForgeCompactFreshness = .current,
        priority: Int = 50,
        value: String? = nil
    ) throws -> ForgeCompactRecord {
        try ForgeCompactRecord(
            id: id,
            layer: layer,
            kind: kind,
            provenance: provenance,
            freshness: freshness,
            priority: priority,
            value: value ?? "value-\(id)",
            sourceBinding: binding(id)
        )
    }

    func testProtectedTruthIsSelectedBeforeOrdinaryRecordsRegardlessOfPriority() throws {
        let core = try makeCore()
        let requirement = try record(
            "requirement",
            layer: .projectMemory,
            kind: .acceptedRequirement,
            provenance: .user,
            priority: 1
        )
        let ordinary = try record("ordinary", priority: 100)
        let budget = core.promptByteCost + requirement.promptByteCost

        let capsule = try ForgeCompactBuilder.build(
            core: core,
            records: [ordinary, requirement],
            maximumActiveContextBytes: budget
        )

        XCTAssertEqual(capsule.selectedRecords.map(\.id), ["requirement"])
        XCTAssertEqual(capsule.omittedRecordIDs, ["ordinary"])
        XCTAssertEqual(capsule.coldReferences.first?.reason, .activeContextBudget)
    }

    func testCriticalTruthOverflowFailsClosedInsteadOfDroppingProtectedRecord() throws {
        let core = try makeCore()
        let failingTest = try record(
            "failing-test",
            kind: .failingTest,
            provenance: .testReceipt,
            priority: 0,
            value: "Save then reload loses the accepted project state."
        )
        let requiredBytes = core.promptByteCost + failingTest.promptByteCost

        XCTAssertThrowsError(
            try ForgeCompactBuilder.build(
                core: core,
                records: [failingTest],
                maximumActiveContextBytes: requiredBytes - 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .criticalTruthExceedsBudget(required: requiredBytes, budget: requiredBytes - 1)
            )
        }
    }

    func testModelSuggestionCannotBecomeProtectedTruth() throws {
        XCTAssertThrowsError(
            try record(
                "suggested-requirement",
                kind: .acceptedRequirement,
                provenance: .modelSuggestion
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .protectedRecordRequiresAuthoritativeProvenance("suggested-requirement")
            )
        }
    }

    func testProtectedTruthMustBeCurrent() throws {
        XCTAssertThrowsError(
            try record(
                "stale-decision",
                kind: .unresolvedDecision,
                provenance: .checkpoint,
                freshness: .stale
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .protectedRecordMustBeCurrent("stale-decision")
            )
        }
    }

    func testStaleOrdinaryMemoryMovesToColdReferenceEvenWhenBudgetIsLarge() throws {
        let core = try makeCore()
        let stale = try record(
            "stale-symbol-map",
            layer: .projectMemory,
            kind: .fileOrSymbol,
            freshness: .stale,
            priority: 100
        )

        let capsule = try ForgeCompactBuilder.build(
            core: core,
            records: [stale],
            maximumActiveContextBytes: core.promptByteCost + stale.promptByteCost + 10_000
        )

        XCTAssertTrue(capsule.selectedRecords.isEmpty)
        XCTAssertEqual(capsule.omittedRecordIDs, ["stale-symbol-map"])
        XCTAssertEqual(capsule.coldReferences.first?.reason, .notCurrent)
        XCTAssertEqual(capsule.coldReferences.first?.freshness, .stale)
    }

    func testBudgetSelectionIsDeterministicAcrossInputOrder() throws {
        let core = try makeCore()
        let highActive = try record("high-active", priority: 90, value: String(repeating: "a", count: 80))
        let lowActive = try record("low-active", priority: 10, value: String(repeating: "b", count: 80))
        let highMemory = try record(
            "high-memory",
            layer: .projectMemory,
            priority: 100,
            value: String(repeating: "c", count: 80)
        )
        let budget = core.promptByteCost + highActive.promptByteCost + 8

        let first = try ForgeCompactBuilder.build(
            core: core,
            records: [lowActive, highMemory, highActive],
            maximumActiveContextBytes: budget
        )
        let second = try ForgeCompactBuilder.build(
            core: core,
            records: [highActive, lowActive, highMemory],
            maximumActiveContextBytes: budget
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.selectedRecords.map(\.id), ["high-active"])
        XCTAssertEqual(first.omittedRecordIDs, ["high-memory", "low-active"])
    }

    func testDuplicateRecordIdentityFailsClosed() throws {
        let core = try makeCore()
        let first = try record("duplicate", priority: 90)
        let second = try record("duplicate", priority: 10)

        XCTAssertThrowsError(
            try ForgeCompactBuilder.build(
                core: core,
                records: [first, second],
                maximumActiveContextBytes: 100_000
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .duplicateRecordID("duplicate"))
        }
    }

    func testCapsuleRoundTripRevalidatesCanonicalTruth() throws {
        let core = try makeCore()
        let requirement = try record(
            "requirement",
            kind: .acceptedRequirement,
            provenance: .user,
            priority: 10
        )
        let summary = try record(
            "summary",
            layer: .projectMemory,
            kind: .compactSummary,
            provenance: .modelSuggestion,
            priority: 30
        )
        let capsule = try ForgeCompactBuilder.build(
            core: core,
            records: [summary, requirement],
            maximumActiveContextBytes: 100_000
        )

        let data = try JSONEncoder().encode(capsule)
        let decoded = try JSONDecoder().decode(ForgeProjectCapsule.self, from: data)

        XCTAssertEqual(decoded, capsule)
        XCTAssertEqual(decoded.schemaVersion, ForgeProjectCapsule.currentSchemaVersion)
        XCTAssertEqual(decoded.selectedRecords.map(\.id), ["requirement", "summary"])
    }

    func testDecodeRejectsOldSchema() throws {
        let capsule = try ForgeCompactBuilder.build(
            core: makeCore(),
            records: [],
            maximumActiveContextBytes: 100_000
        )
        let encoded = try JSONEncoder().encode(capsule)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 0
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeProjectCapsule.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .unsupportedSchema(0))
        }
    }

    func testDecodeRejectsUsedByteCountTampering() throws {
        let capsule = try ForgeCompactBuilder.build(
            core: makeCore(),
            records: [record("fact")],
            maximumActiveContextBytes: 100_000
        )
        let encoded = try JSONEncoder().encode(capsule)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let actual = try XCTUnwrap(object["usedActiveContextBytes"] as? Int)
        object["usedActiveContextBytes"] = actual + 1
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeProjectCapsule.self, from: tampered)) { error in
            XCTAssertEqual(
                error as? ForgeCompactError,
                .inconsistentUsedByteCount(expected: actual, actual: actual + 1)
            )
        }
    }

    func testDecodeRejectsSelectedRecordMadeStale() throws {
        let capsule = try ForgeCompactBuilder.build(
            core: makeCore(),
            records: [record("fact")],
            maximumActiveContextBytes: 100_000
        )
        let encoded = try JSONEncoder().encode(capsule)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var selected = try XCTUnwrap(object["selectedRecords"] as? [[String: Any]])
        selected[0]["freshness"] = ForgeCompactFreshness.stale.rawValue
        object["selectedRecords"] = selected
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeProjectCapsule.self, from: tampered)) { error in
            XCTAssertEqual(error as? ForgeCompactError, .selectedRecordMustBeCurrent("fact"))
        }
    }

    func testColdReferenceCannotContainProtectedKind() throws {
        XCTAssertThrowsError(
            try ForgeCompactColdReference(
                recordID: "critical",
                kind: .policyConstraint,
                freshness: .current,
                sourceBinding: binding("critical"),
                reason: .activeContextBudget
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .protectedRecordCannotBeCold("critical"))
        }
    }

    func testEncodedCapsuleDoesNotRetainOmittedValueInColdArchiveReceipt() throws {
        let core = try makeCore()
        let secretPayload = "large-omitted-payload-should-not-be-copied-into-L3"
        let ordinary = try record(
            "omitted",
            priority: 1,
            value: secretPayload
        )
        let capsule = try ForgeCompactBuilder.build(
            core: core,
            records: [ordinary],
            maximumActiveContextBytes: core.promptByteCost
        )

        let encoded = try JSONEncoder().encode(capsule)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertEqual(capsule.omittedRecordIDs, ["omitted"])
        XCTAssertFalse(text.contains(secretPayload))
        XCTAssertTrue(text.contains("source-omitted"))
        XCTAssertTrue(text.contains("rev-omitted"))
    }

    func testCoreRejectsNegativeAuthorityIdentityRevisions() throws {
        XCTAssertThrowsError(
            try ForgeCompactCoreContext(
                missionID: "mission",
                projectID: "project",
                missionRevision: -1,
                authorityEpoch: 0,
                sourceAuthorityRevision: "source-rev",
                currentObjective: "objective",
                currentStageID: "stage",
                privacyPolicyReference: "privacy",
                localityPolicyReference: "local"
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .invalidRevision("missionRevision"))
        }
    }

    func testEmptyIdentityAndRecordPayloadFailClosed() throws {
        XCTAssertThrowsError(try ForgeCompactSourceBinding(authorityID: "   ", revision: "1")) { error in
            XCTAssertEqual(error as? ForgeCompactError, .emptyField("authorityID"))
        }

        XCTAssertThrowsError(
            try ForgeCompactRecord(
                id: "fact",
                layer: .activeWorkingSet,
                kind: .sourceFact,
                provenance: .source,
                freshness: .current,
                priority: 50,
                value: "\n\t",
                sourceBinding: binding("fact")
            )
        ) { error in
            XCTAssertEqual(error as? ForgeCompactError, .emptyField("record.value"))
        }
    }
}
