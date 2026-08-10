#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
canonical = root / "AgentPad/Services/AgentCanonicalContextPreparer.swift"
tests = root / "Packages/AgentHarnessKit/Tests/AgentEngineTests/AgentForgeCompactSupplementProjectorTests.swift"

source = canonical.read_text()
old_block = '''        if !state.artifacts.isEmpty || !state.checkpoints.isEmpty {
            let supplement = AgentCanonicalContextSupplement(
                kind: "novaforge_context_supplement_v1",
                artifacts: state.artifacts,
                checkpoints: state.checkpoints
            )
            let text = try canonicalJSONString(supplement)
            try enforceUTF8Limit(
                text,
                kind: .textPartUTF8Bytes,
                limit: configuration.limits.maximumTextPartUTF8Bytes
            )
            messages.append(ProviderMessage(
                role: .developer,
                content: [.text(text)]
            ))
        }
'''
new_block = '''        if !state.artifacts.isEmpty || !state.checkpoints.isEmpty {
            let text = try supplementalContextText(state: state)
            try enforceUTF8Limit(
                text,
                kind: .textPartUTF8Bytes,
                limit: configuration.limits.maximumTextPartUTF8Bytes
            )
            messages.append(ProviderMessage(
                role: .developer,
                content: [.text(text)]
            ))
        }
'''
if source.count(old_block) != 1:
    raise SystemExit("canonical supplement block drifted; refusing patch")
source = source.replace(old_block, new_block, 1)

marker = "\n// MARK: - Static configuration validation\n"
helper = r'''

// MARK: - Forge Compact supplemental context

private extension AgentCanonicalContextPreparer {
    /// The reducer-backed model-item transcript remains the canonical replay.
    /// Forge Compact is used only for the redundant global artifact/checkpoint
    /// supplement, and only when it produces a strictly smaller representation.
    func supplementalContextText(state: AgentDomain.AgentRunState) throws -> String {
        let legacy = try canonicalJSONString(AgentCanonicalContextSupplement(
            kind: "novaforge_context_supplement_v1",
            artifacts: state.artifacts,
            checkpoints: state.checkpoints
        ))
        let legacyBytes = legacy.utf8.count

        // Small supplements stay byte-for-byte on the established path. This
        // keeps compaction overhead out of ordinary turns and makes the Preview
        // integration an actual reduction path rather than a format rewrite.
        guard legacyBytes >= 4 * 1_024,
              let lastSequence = state.lastSequence,
              let lastEventID = state.lastEventID
        else { return legacy }

        let sourceRevision = "event:\(lastSequence.rawValue):\(lastEventID.description)"
        let twoThirds = (legacyBytes / 3) * 2
        let budgetBytes = min(48 * 1_024, max(2 * 1_024, twoThirds))

        guard let projection = try? AgentForgeCompactSupplementProjector.project(
            context: configuration.context,
            sourceRevision: sourceRevision,
            artifacts: state.artifacts,
            checkpoints: state.checkpoints,
            budgetBytes: budgetBytes
        ), projection.selectedItemCount > 0,
           projection.omittedItemCount > 0
        else { return legacy }

        let compact = AgentCanonicalForgeCompactSupplement(
            kind: "novaforge_forge_compact_supplement_v1",
            sourceRevision: sourceRevision,
            sourceItemCount: projection.sourceItemCount,
            selectedItemCount: projection.selectedItemCount,
            omittedItemCount: projection.omittedItemCount,
            renderedContext: projection.renderedContext
        )
        guard let compactText = try? canonicalJSONString(compact),
              compactText.utf8.count < legacyBytes
        else { return legacy }
        return compactText
    }
}
'''
if source.count(marker) != 1:
    raise SystemExit("static-validation marker drifted; refusing helper insertion")
source = source.replace(marker, helper + marker, 1)

supplement_marker = "private struct AgentCanonicalContextSupplement: Encodable {\n"
wrapper = '''private struct AgentCanonicalForgeCompactSupplement: Encodable {
    let kind: String
    let sourceRevision: String
    let sourceItemCount: Int
    let selectedItemCount: Int
    let omittedItemCount: Int
    let renderedContext: String
}

'''
if source.count(supplement_marker) != 1:
    raise SystemExit("supplement type marker drifted; refusing wrapper insertion")
source = source.replace(supplement_marker, wrapper + supplement_marker, 1)
canonical.write_text(source)

# The projector test should use the package's canonical standard budget fixture;
# keep this replacement one-shot so the committed test stays ordinary Swift.
test_source = tests.read_text()
old_budget = '''            initialBudget: try AgentBudget(
                wallClockLimit: .seconds(60),
                modelAttemptLimit: 8,
                toolInvocationLimit: 32,
                outputTokenLimit: 16_384
            )
'''
new_budget = '''            initialBudget: AgentBudget(limits: .standard)
'''
if old_budget not in test_source:
    raise SystemExit("projector test budget fixture drifted; refusing patch")
tests.write_text(test_source.replace(old_budget, new_budget, 1))

# Fail closed if any of the key integration truths vanished during patching.
checks = {
    canonical: [
        "let text = try supplementalContextText(state: state)",
        'kind: "novaforge_forge_compact_supplement_v1"',
        "compactText.utf8.count < legacyBytes",
        "projection.omittedItemCount > 0",
        "while itemIndex < state.modelItems.count",
    ],
    tests: [
        "[L1][workingNote][advisory]",
        "[L2][sourceLocation][truth]",
        "XCTAssertGreaterThan(first.omittedItemCount, 0)",
    ],
}
for path, needles in checks.items():
    text = path.read_text()
    for needle in needles:
        if needle not in text:
            raise SystemExit(f"missing integration contract in {path}: {needle}")

print("Preview Forge Compact canonical supplement patch applied safely")
