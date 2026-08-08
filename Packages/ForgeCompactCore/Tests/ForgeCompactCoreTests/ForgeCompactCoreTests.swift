import Foundation
import Testing
@testable import ForgeCompactCore

struct ForgeCompactCoreTests {
    private func source(
        kind: ForgeCompactSourceReference.Kind = .repositoryFile,
        revision: String = "rev-1"
    ) throws -> ForgeCompactSourceReference {
        try .init(kind: kind, locator: "AgentPad/Views/Forge.swift", revision: revision)
    }

    private func cost(_ units: Int, exact: Bool = true) throws -> ForgeCompactContextCost {
        if exact {
            return try .init(
                units: units,
                basis: .exactTokenizer(tokenizerID: "tok", tokenizerRevision: "r1")
            )
        }
        return try .init(units: units, basis: .heuristic(name: "chars-div-4"))
    }

    private func entry(
        _ id: String,
        projectID: String = "project-1",
        kind: ForgeCompactEntryKind = .relevantSource,
        priority: ForgeCompactPriority = .normal,
        inclusion: ForgeCompactInclusion = .optional,
        freshness: ForgeCompactFreshness = .current,
        authority: ForgeCompactAuthority = .sourceBacked,
        units: Int = 10,
        exactCost: Bool = true
    ) throws -> ForgeCompactEntry {
        try .init(
            id: id,
            projectID: projectID,
            kind: kind,
            text: "Accepted context for \(id)",
            priority: priority,
            inclusion: inclusion,
            freshness: freshness,
            authority: authority,
            source: source(),
            cost: cost(units, exact: exactCost)
        )
    }

    @Test func requiredTruthIsNeverSilentlyDropped() throws {
        let required = try entry("required", inclusion: .required, units: 15)
        let optional = try entry("optional", priority: .critical, units: 10)
        let capsule = try ForgeCompactPlanner.build(
            projectID: "project-1",
            missionID: "mission-1",
            authorityRevision: 4,
            entries: [optional, required],
            policy: try .init(maximumUnits: 20)
        )

        #expect(capsule.entries.map(\.id) == ["required"])
        #expect(capsule.receipt.selectedUnits == 15)
        #expect(capsule.receipt.omissions == [.init(entryID: "optional", reason: .budget)])
    }

    @Test func requiredBudgetOverflowFailsClosed() throws {
        let a = try entry("a", inclusion: .required, units: 12)
        let b = try entry("b", inclusion: .required, units: 9)
        #expect(throws: ForgeCompactError.requiredBudgetExceeded(requiredUnits: 21, maximumUnits: 20)) {
            try ForgeCompactPlanner.build(
                projectID: "project-1",
                missionID: "mission-1",
                authorityRevision: 1,
                entries: [a, b],
                policy: try .init(maximumUnits: 20)
            )
        }
    }

    @Test func requiredCostOverflowFailsClosed() throws {
        let huge = try entry("huge", inclusion: .required, units: .max)
        let one = try entry("one", inclusion: .required, units: 1)
        #expect(throws: ForgeCompactError.invalidCost) {
            try ForgeCompactPlanner.build(
                projectID: "project-1",
                missionID: "mission-1",
                authorityRevision: 1,
                entries: [huge, one],
                policy: try .init(maximumUnits: .max)
            )
        }
    }

    @Test func staleRequiredTruthFailsClosed() throws {
        let stale = try entry("stale", inclusion: .required, freshness: .stale)
        #expect(throws: ForgeCompactError.requiredEntryIneligible(entryID: "stale", reason: .stale)) {
            try ForgeCompactPlanner.build(
                projectID: "project-1",
                missionID: "mission-1",
                authorityRevision: 1,
                entries: [stale],
                policy: try .init(maximumUnits: 100)
            )
        }
    }

    @Test func modelObservationCannotBecomeAcceptedCapsuleTruth() throws {
        let model = try entry("model", authority: .modelObservation)
        let accepted = try entry("accepted", authority: .testEvidence)
        let capsule = try ForgeCompactPlanner.build(
            projectID: "project-1",
            missionID: "mission-1",
            authorityRevision: 2,
            entries: [model, accepted],
            policy: try .init(maximumUnits: 100)
        )
        #expect(capsule.entries.map(\.id) == ["accepted"])
        #expect(capsule.receipt.omissions == [.init(entryID: "model", reason: .nonAuthoritative)])
    }

    @Test func crossProjectInputIsRejected() throws {
        let foreign = try entry("foreign", projectID: "project-2")
        #expect(throws: ForgeCompactError.crossProjectEntry(entryID: "foreign")) {
            try ForgeCompactPlanner.build(
                projectID: "project-1",
                missionID: "mission-1",
                authorityRevision: 1,
                entries: [foreign],
                policy: try .init(maximumUnits: 100)
            )
        }
    }

    @Test func duplicateEntryIDsAreRejected() throws {
        let first = try entry("same")
        let second = try entry("same", kind: .knownDefect)
        #expect(throws: ForgeCompactError.duplicateEntryID("same")) {
            try ForgeCompactPlanner.build(
                projectID: "project-1",
                missionID: "mission-1",
                authorityRevision: 1,
                entries: [first, second],
                policy: try .init(maximumUnits: 100)
            )
        }
    }

    @Test func exactCostPolicyExcludesEstimatedOptionalEntries() throws {
        let exact = try entry("exact", units: 9)
        let estimated = try entry("estimated", priority: .critical, units: 2, exactCost: false)
        let capsule = try ForgeCompactPlanner.build(
            projectID: "project-1",
            missionID: "mission-1",
            authorityRevision: 1,
            entries: [estimated, exact],
            policy: try .init(maximumUnits: 100, requireExactCost: true)
        )
        #expect(capsule.entries.map(\.id) == ["exact"])
        #expect(capsule.receipt.costTruth == .exact)
        #expect(capsule.receipt.omissions == [.init(entryID: "estimated", reason: .estimatedCostDisallowed)])
    }

    @Test func heuristicCostRemainsExplicitInReceipt() throws {
        let estimated = try entry("estimated", units: 2, exactCost: false)
        let capsule = try ForgeCompactPlanner.build(
            projectID: "project-1",
            missionID: "mission-1",
            authorityRevision: 1,
            entries: [estimated],
            policy: try .init(maximumUnits: 100)
        )
        #expect(capsule.receipt.costTruth == .includesEstimates)
    }

    @Test func selectionIsDeterministicAndPrefersHighValueLowCostContext() throws {
        let low = try entry("low", priority: .low, units: 2)
        let expensiveHigh = try entry("expensive", priority: .high, units: 10)
        let cheapHigh = try entry("cheap", priority: .high, units: 4)
        let preferred = try entry("preferred", priority: .low, inclusion: .preferred, units: 8)

        let capsule = try ForgeCompactPlanner.build(
            projectID: "project-1",
            missionID: "mission-1",
            authorityRevision: 1,
            entries: [low, expensiveHigh, cheapHigh, preferred],
            policy: try .init(maximumUnits: 14)
        )

        #expect(capsule.entries.map(\.id) == ["preferred", "cheap", "low"])
        #expect(capsule.receipt.selectedUnits == 14)
        #expect(capsule.receipt.omissions == [.init(entryID: "expensive", reason: .budget)])
    }

    @Test func archiveDecodeRevalidatesNestedEntryCost() throws {
        let selected = try entry("selected", inclusion: .required)
        let capsule = try ForgeCompactPlanner.build(
            projectID: "project-1",
            missionID: "mission-1",
            authorityRevision: 1,
            entries: [selected],
            policy: try .init(maximumUnits: 100)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(capsule)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try #require(json["entries"] as? [[String: Any]])
        var cost = try #require(entries[0]["cost"] as? [String: Any])
        cost["units"] = 0
        entries[0]["cost"] = cost
        json["entries"] = entries
        let tampered = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        #expect(throws: ForgeCompactError.invalidCost) {
            try JSONDecoder().decode(ProjectCapsule.self, from: tampered)
        }
    }

    @Test func archiveDecodeRejectsInvalidOmissionIdentity() throws {
        let optional = try entry("optional", units: 50)
        let capsule = try ForgeCompactPlanner.build(
            projectID: "project-1",
            missionID: "mission-1",
            authorityRevision: 1,
            entries: [optional],
            policy: try .init(maximumUnits: 10)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(capsule)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var receipt = try #require(json["receipt"] as? [String: Any])
        var omissions = try #require(receipt["omissions"] as? [[String: Any]])
        omissions[0]["entryID"] = "bad id"
        receipt["omissions"] = omissions
        json["receipt"] = receipt
        let tampered = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        #expect(throws: ForgeCompactError.invalidIdentifier("bad id")) {
            try JSONDecoder().decode(ProjectCapsule.self, from: tampered)
        }
    }

    @Test func archiveDecodeRevalidatesProjectIdentity() throws {
        let selected = try entry("selected", inclusion: .required)
        let capsule = try ForgeCompactPlanner.build(
            projectID: "project-1",
            missionID: "mission-1",
            authorityRevision: 1,
            entries: [selected],
            policy: try .init(maximumUnits: 100)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(capsule)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var entries = try #require(json["entries"] as? [[String: Any]])
        entries[0]["projectID"] = "project-2"
        json["entries"] = entries
        let tampered = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        #expect(throws: ForgeCompactError.crossProjectEntry(entryID: "selected")) {
            try JSONDecoder().decode(ProjectCapsule.self, from: tampered)
        }
    }
}
