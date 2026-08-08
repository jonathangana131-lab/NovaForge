import Foundation
import Testing
@testable import ForgeCompactCore

private func provenance(_ id: String, kind: ProjectCapsuleProvenanceKind = .sourceRevision) throws -> [ProjectCapsuleProvenance] {
    [try ProjectCapsuleProvenance(kind: kind, stableID: id)]
}

private func identity() throws -> ProjectCapsuleIdentity {
    try ProjectCapsuleIdentity(
        projectID: "project-1",
        missionID: "mission-1",
        sourceRevision: "abc123",
        missionRevision: 7,
        authorityEpoch: 3
    )
}

private func budget(_ available: Int, maxFactCount: Int = 256) throws -> ProjectCapsuleBudget {
    try ProjectCapsuleBudget(
        contextWindowTokens: available + 1_000,
        reservedSystemToolTokens: 500,
        reservedGenerationTokens: 500,
        maxCapsuleTokens: available,
        maxFactCount: maxFactCount
    )
}

private func fact(
    _ id: String,
    kind: ProjectCapsuleFactKind,
    layer: ProjectCapsuleLayer,
    tokens: Int,
    relevance: Int,
    freshness: ProjectCapsuleFreshness = .current
) throws -> ProjectCapsuleFact {
    try ProjectCapsuleFact(
        id: id,
        kind: kind,
        layer: layer,
        summary: "summary for \(id)",
        estimatedTokens: tokens,
        relevance: relevance,
        freshness: freshness,
        provenance: provenance("source-\(id)")
    )
}

@Test func protectedTruthCannotBeCompactedAway() throws {
    let facts = [
        try fact("privacy", kind: .privacyPolicy, layer: .l0AlwaysResident, tokens: 40, relevance: 1_000),
        try fact("decision", kind: .unresolvedDecision, layer: .l0AlwaysResident, tokens: 50, relevance: 900),
        try fact("history", kind: .historicalContext, layer: .l2ProjectMemory, tokens: 100, relevance: 100)
    ]

    let capsule = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(90), candidates: facts)
    #expect(capsule.facts.map(\.id) == ["privacy", "decision"])
    #expect(capsule.omissions.map(\.id) == ["history"])
    #expect(capsule.estimatedTokens == 90)
}

@Test func plannerFailsClosedWhenProtectedTruthDoesNotFit() throws {
    let facts = [
        try fact("requirement", kind: .requirement, layer: .l0AlwaysResident, tokens: 70, relevance: 1_000),
        try fact("failure", kind: .activeFailure, layer: .l0AlwaysResident, tokens: 50, relevance: 1_000)
    ]

    #expect(throws: ForgeCompactError.requiredTruthExceedsBudget(required: 120, available: 100)) {
        _ = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(100), candidates: facts)
    }
}

@Test func selectionIsDeterministicAcrossCandidateOrder() throws {
    let candidates = [
        try fact("b", kind: .knownDefect, layer: .l1ActiveWorkingSet, tokens: 20, relevance: 800),
        try fact("a", kind: .knownDefect, layer: .l1ActiveWorkingSet, tokens: 20, relevance: 800),
        try fact("c", kind: .recentChange, layer: .l2ProjectMemory, tokens: 20, relevance: 900)
    ]

    let forward = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(60), candidates: candidates)
    let reverse = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(60), candidates: candidates.reversed())
    #expect(forward == reverse)
    #expect(forward.facts.map(\.id) == ["a", "b", "c"])
}

@Test func layerAndRelevanceDriveOptionalSelection() throws {
    let candidates = [
        try fact("active-high", kind: .knownDefect, layer: .l1ActiveWorkingSet, tokens: 40, relevance: 900),
        try fact("active-low", kind: .knownDefect, layer: .l1ActiveWorkingSet, tokens: 40, relevance: 100),
        try fact("memory-high", kind: .sourceReference, layer: .l2ProjectMemory, tokens: 40, relevance: 1_000)
    ]

    let capsule = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(80), candidates: candidates)
    #expect(capsule.facts.map(\.id) == ["active-high", "active-low"])
    #expect(capsule.omissions.map(\.id) == ["memory-high"])
}

@Test func zeroRelevanceProjectMemoryIsColdArchived() throws {
    let cold = try fact("cold", kind: .historicalContext, layer: .l2ProjectMemory, tokens: 10, relevance: 0)
    let capsule = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(100), candidates: [cold])
    #expect(capsule.facts.isEmpty)
    #expect(capsule.omissions == [try ProjectCapsuleOmission(id: "cold", kind: .historicalContext, estimatedTokens: 10, reason: .coldArchive)])
}

@Test func duplicateFactIDsFailClosed() throws {
    let one = try fact("same", kind: .recentChange, layer: .l1ActiveWorkingSet, tokens: 10, relevance: 10)
    let two = try fact("same", kind: .knownDefect, layer: .l1ActiveWorkingSet, tokens: 10, relevance: 20)
    #expect(throws: ForgeCompactError.duplicateFactID("same")) {
        _ = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(100), candidates: [one, two])
    }
}

@Test func staleProtectedTruthIsRejectedAtConstruction() throws {
    #expect(throws: ForgeCompactError.staleProtectedTruth("privacy")) {
        _ = try fact("privacy", kind: .privacyPolicy, layer: .l0AlwaysResident, tokens: 10, relevance: 1_000, freshness: .stale)
    }
}

@Test func archiveRoundTripRevalidatesCanonicalCapsule() throws {
    let candidates = [
        try fact("identity", kind: .missionIdentity, layer: .l0AlwaysResident, tokens: 20, relevance: 1_000),
        try fact("test", kind: .testReceipt, layer: .l1ActiveWorkingSet, tokens: 30, relevance: 800)
    ]
    let capsule = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(100), candidates: candidates)
    let data = try JSONEncoder().encode(capsule)
    let decoded = try JSONDecoder().decode(ProjectCapsule.self, from: data)
    #expect(decoded == capsule)
}

@Test func tamperedArchiveCannotOmitProtectedTruth() throws {
    let json = """
    {
      "schemaVersion": 1,
      "identity": {
        "projectID": "project-1",
        "missionID": "mission-1",
        "sourceRevision": "abc123",
        "missionRevision": 7,
        "authorityEpoch": 3
      },
      "budget": {
        "contextWindowTokens": 1100,
        "reservedSystemToolTokens": 500,
        "reservedGenerationTokens": 500,
        "maxCapsuleTokens": 100,
        "maxFactCount": 256
      },
      "facts": [],
      "omissions": [
        {"id":"decision","kind":"unresolvedDecision","estimatedTokens":10,"reason":"tokenBudget"}
      ],
      "estimatedTokens": 0
    }
    """.data(using: .utf8)!

    #expect(throws: ForgeCompactError.archiveOmittedProtectedTruth("decision")) {
        _ = try JSONDecoder().decode(ProjectCapsule.self, from: json)
    }
}

@Test func tamperedArchiveRejectsNonCanonicalFactOrder() throws {
    let candidates = [
        try fact("z", kind: .testReceipt, layer: .l1ActiveWorkingSet, tokens: 10, relevance: 100),
        try fact("a", kind: .testReceipt, layer: .l1ActiveWorkingSet, tokens: 10, relevance: 900)
    ]
    let capsule = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(100), candidates: candidates)
    let encoder = JSONEncoder()
    var object = try JSONSerialization.jsonObject(with: encoder.encode(capsule)) as! [String: Any]
    object["facts"] = Array((object["facts"] as! [[String: Any]]).reversed())
    let tampered = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: ForgeCompactError.archiveSelectionOrder) {
        _ = try JSONDecoder().decode(ProjectCapsule.self, from: tampered)
    }
}

@Test func budgetReservesSystemToolsAndGenerationTokens() throws {
    let value = try ProjectCapsuleBudget(
        contextWindowTokens: 4_096,
        reservedSystemToolTokens: 1_000,
        reservedGenerationTokens: 1_500,
        maxCapsuleTokens: 2_000
    )
    #expect(value.availableCapsuleTokens == 1_596)
}

@Test func factCountBudgetCannotEvictProtectedTruth() throws {
    let first = try fact("req", kind: .requirement, layer: .l0AlwaysResident, tokens: 10, relevance: 1_000)
    let second = try fact("privacy", kind: .privacyPolicy, layer: .l0AlwaysResident, tokens: 10, relevance: 1_000)
    #expect(throws: ForgeCompactError.requiredTruthExceedsFactCount(required: 2, available: 1)) {
        _ = try ProjectCapsulePlanner.build(identity: identity(), budget: budget(100, maxFactCount: 1), candidates: [first, second])
    }
}

@Test func decodedFactRevalidatesProtectedFreshness() throws {
    let json = """
    {
      "id":"privacy",
      "kind":"privacyPolicy",
      "layer":0,
      "summary":"Local only",
      "estimatedTokens":10,
      "relevance":1000,
      "freshness":"stale",
      "provenance":[{"kind":"policy","stableID":"policy-1"}]
    }
    """.data(using: .utf8)!

    #expect(throws: ForgeCompactError.staleProtectedTruth("privacy")) {
        _ = try JSONDecoder().decode(ProjectCapsuleFact.self, from: json)
    }
}

@Test func decodedBudgetRevalidatesReservedCapacity() throws {
    let json = """
    {
      "contextWindowTokens":100,
      "reservedSystemToolTokens":60,
      "reservedGenerationTokens":40,
      "maxCapsuleTokens":100,
      "maxFactCount":10
    }
    """.data(using: .utf8)!

    #expect(throws: ForgeCompactError.invalidBudget) {
        _ = try JSONDecoder().decode(ProjectCapsuleBudget.self, from: json)
    }
}
