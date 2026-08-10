#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
canonical = root / "AgentPad/Services/AgentCanonicalContextPreparer.swift"
tests = root / "AgentPadTests/AgentCanonicalContextPreparerTests.swift"

source = canonical.read_text()

transcript_marker = '''        let transcript = try validateTranscript(
            state: state,
            tools: tools,
            jsonNodeCount: &jsonNodeCount
        )
        try Task.checkCancellation()

        var messages: [ProviderMessage] = []
'''
transcript_replacement = '''        let transcript = try validateTranscript(
            state: state,
            tools: tools,
            jsonNodeCount: &jsonNodeCount
        )
        try Task.checkCancellation()

        // Forge Compact never mutates the authoritative reducer state. After
        // the full transcript/checkpoint proof has passed, it may authorize
        // replacing one old plain-text prefix with its durable checkpoint.
        // Provider-owned reasoning/tool envelopes and the protected recent
        // tail therefore remain byte-for-byte on the canonical replay path.
        let forgeCompactPlan = AgentForgeCompactCheckpointPlanner.plan(
            modelItems: state.modelItems,
            projectID: configuration.context.projectID?.description
                ?? configuration.context.conversationID.description,
            missionID: configuration.context.lineage.runID.description
        )
        let compactedSourceItemIDs = Set(
            forgeCompactPlan.compactedSourceItemIDs
        )

        var messages: [ProviderMessage] = []
'''
if source.count(transcript_marker) != 1:
    raise SystemExit("canonical transcript seam drifted; refusing patch")
source = source.replace(transcript_marker, transcript_replacement, 1)

loop_marker = '''        while itemIndex < state.modelItems.count {
            try Task.checkCancellation()
            let item = state.modelItems[itemIndex]
            let message: ProviderMessage
'''
loop_replacement = '''        while itemIndex < state.modelItems.count {
            try Task.checkCancellation()
            let item = state.modelItems[itemIndex]
            if compactedSourceItemIDs.contains(item.id) {
                itemIndex += 1
                continue
            }
            let message: ProviderMessage
'''
if source.count(loop_marker) != 1:
    raise SystemExit("canonical model replay loop drifted; refusing patch")
source = source.replace(loop_marker, loop_replacement, 1)

ids_marker = '''        let itemIDs = state.modelItems.map(\\.id)
        let digestMaterial = AgentCanonicalContextDigestMaterial(
'''
ids_replacement = '''        let itemIDs = state.modelItems.compactMap { item in
            compactedSourceItemIDs.contains(item.id) ? nil : item.id
        }
        let digestMaterial = AgentCanonicalContextDigestMaterial(
'''
if source.count(ids_marker) != 1:
    raise SystemExit("canonical prepared item ID seam drifted; refusing patch")
source = source.replace(ids_marker, ids_replacement, 1)
canonical.write_text(source)

test_source = tests.read_text()
insert_before = '''    func testPreCancelledPreparationPropagatesCancellation() async throws {
'''
new_tests = r'''    func testForgeCompactCheckpointReplacesOnlyEligibleHistoricalPrefix() async throws {
        let fixture = CanonicalContextFixture(seed: 11)
        let historicalIDs: [ModelItemID] = (0..<8).map {
            canonicalTagged(11_100 + UInt64($0))
        }
        let historicalItems = historicalIDs.enumerated().map { index, id in
            fixture.userItem(
                id: id,
                text: "historical-marker-\(index)-" + String(
                    repeating: "durable project context ",
                    count: 160
                )
            )
        }
        let checkpointItemID: ModelItemID = canonicalTagged(11_200)
        let checkpoint = ContextCheckpointReference(
            checkpointID: canonicalTagged(11_201),
            schemaVersion: .current,
            summary: "Durable checkpoint: preserve the accepted project direction.",
            sourceItemIDs: historicalIDs,
            sourceDigest: canonicalDigest(character: "1")
        )
        let checkpointItem = ModelItem(
            id: checkpointItemID,
            createdAt: AgentInstant(rawValue: 11_200),
            payload: .contextCheckpoint(checkpoint)
        )
        let tailIDs: [ModelItemID] = (0..<6).map {
            canonicalTagged(11_300 + UInt64($0))
        }
        let tailItems = tailIDs.enumerated().map { index, id in
            fixture.userItem(id: id, text: "recent-tail-\(index)")
        }
        let preparer = try fixture.preparer()

        let uncompacted = try await preparer.prepareProviderTurn(
            state: fixture.state(modelItems: historicalItems + tailItems),
            tools: []
        )
        let state = fixture.state(
            modelItems: historicalItems + [checkpointItem] + tailItems,
            checkpoints: [checkpoint]
        )
        let first = try await preparer.prepareProviderTurn(state: state, tools: [])
        let second = try await preparer.prepareProviderTurn(state: state, tools: [])

        XCTAssertEqual(first.request, second.request)
        XCTAssertEqual(first.contextDigest, second.contextDigest)
        XCTAssertEqual(first.itemIDs, [checkpointItemID] + tailIDs)
        XCTAssertEqual(first.request.messages.count, 10)
        XCTAssertLessThan(first.estimatedTokens, uncompacted.estimatedTokens)
        XCTAssertGreaterThan(
            uncompacted.estimatedTokens - first.estimatedTokens,
            8_000
        )

        let encoded = String(
            decoding: try JSONEncoder().encode(first.request),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains("historical-marker-0"))
        XCTAssertFalse(encoded.contains("historical-marker-7"))
        XCTAssertTrue(encoded.contains("Durable checkpoint"))
        XCTAssertTrue(encoded.contains("recent-tail-0"))
        XCTAssertTrue(encoded.contains("recent-tail-5"))
    }

    func testForgeCompactLowSavingsCheckpointLeavesCanonicalReplayUntouched() async throws {
        let fixture = CanonicalContextFixture(seed: 12)
        let historicalIDs: [ModelItemID] = (0..<8).map {
            canonicalTagged(12_100 + UInt64($0))
        }
        let historicalItems = historicalIDs.enumerated().map { index, id in
            fixture.userItem(id: id, text: "h\(index)")
        }
        let checkpointItemID: ModelItemID = canonicalTagged(12_200)
        let checkpoint = ContextCheckpointReference(
            checkpointID: canonicalTagged(12_201),
            schemaVersion: .current,
            summary: "small summary",
            sourceItemIDs: historicalIDs,
            sourceDigest: canonicalDigest(character: "2")
        )
        let checkpointItem = ModelItem(
            id: checkpointItemID,
            createdAt: AgentInstant(rawValue: 12_200),
            payload: .contextCheckpoint(checkpoint)
        )
        let tailIDs: [ModelItemID] = (0..<6).map {
            canonicalTagged(12_300 + UInt64($0))
        }
        let tailItems = tailIDs.map {
            fixture.userItem(id: $0, text: "tail")
        }
        let state = fixture.state(
            modelItems: historicalItems + [checkpointItem] + tailItems,
            checkpoints: [checkpoint]
        )

        let prepared = try await fixture.preparer().prepareProviderTurn(
            state: state,
            tools: []
        )

        XCTAssertEqual(
            prepared.itemIDs,
            historicalIDs + [checkpointItemID] + tailIDs
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(prepared.request),
            as: UTF8.self
        )
        XCTAssertTrue(encoded.contains("h0"))
        XCTAssertTrue(encoded.contains("h7"))
        XCTAssertTrue(encoded.contains("small summary"))
    }

'''
if test_source.count(insert_before) != 1:
    raise SystemExit("canonical test insertion seam drifted; refusing patch")
test_source = test_source.replace(insert_before, new_tests + insert_before, 1)
tests.write_text(test_source)

checks = {
    canonical: [
        "let forgeCompactPlan = AgentForgeCompactCheckpointPlanner.plan(",
        "if compactedSourceItemIDs.contains(item.id)",
        "let itemIDs = state.modelItems.compactMap { item in",
        "state: state,",
        "request: request,",
    ],
    tests: [
        "testForgeCompactCheckpointReplacesOnlyEligibleHistoricalPrefix",
        "XCTAssertLessThan(first.estimatedTokens, uncompacted.estimatedTokens)",
        "testForgeCompactLowSavingsCheckpointLeavesCanonicalReplayUntouched",
    ],
}
for path, needles in checks.items():
    text = path.read_text()
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"missing provider-send integration contract in {path}: {needle}")

print("Preview Forge Compact provider-send patch applied safely")
