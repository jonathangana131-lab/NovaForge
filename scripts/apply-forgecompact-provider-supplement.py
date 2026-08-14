#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one anchor, found {count}: {old[:80]!r}")
    path.write_text(text.replace(old, new, 1))


preparer = Path("AgentPad/Services/AgentCanonicalContextPreparer.swift")
replace_once(
    preparer,
    "import Foundation\n",
    "import Foundation\nimport ForgeCompactCore\n",
)
replace_once(
    preparer,
    '    static let version = "canonical-context-v1"\n',
    '    static let version = "canonical-context-v1"\n'
    '    static let projectMemorySupplementBudgetBytes = 64 * 1_024\n'
    '    private static let projectMemoryCapsuleHeaderReserveBytes = 1 * 1_024\n',
)
replace_once(
    preparer,
    "            let text = try canonicalJSONString(supplement)\n",
    "            let text = try projectMemorySupplementText(supplement)\n",
)
helper = r'''private extension AgentCanonicalContextPreparer {
    func projectMemorySupplementText(
        _ supplement: AgentCanonicalContextSupplement
    ) throws -> String {
        let rawText = try canonicalJSONString(supplement)
        guard rawText.utf8.count > Self.projectMemorySupplementBudgetBytes else {
            return rawText
        }

        do {
            let sourceRevision = forgeCompactSourceRevision(rawText)
            let authority = try ProjectCapsuleAuthority(
                projectID: configuration.context.projectID?.description
                    ?? configuration.context.workspaceID.description,
                missionID: configuration.context.lineage.runID.description,
                sourceRevision: sourceRevision,
                missionRevision: 0,
                authorityEpoch: 0,
                capsuleRevision: 0
            )
            var items: [ForgeCompactContextItem] = []
            items.reserveCapacity(supplement.artifacts.count + supplement.checkpoints.count)

            for artifact in supplement.artifacts {
                let content = try canonicalJSONString(
                    AgentForgeCompactArtifactPayload(artifact: artifact)
                )
                items.append(try ForgeCompactContextItem(
                    id: "artifact:" + forgeCompactContentID(content),
                    sourceRevision: sourceRevision,
                    tier: .l2ProjectMemory,
                    kind: .sourceLocation,
                    priority: 60,
                    content: content,
                    provenance: ForgeCompactProvenance(
                        kind: .source,
                        reference: "artifact:" + artifact.artifactID.description
                    ),
                    isAuthoritative: true
                ))
            }
            for checkpoint in supplement.checkpoints {
                let content = try canonicalJSONString(
                    AgentForgeCompactCheckpointPayload(checkpoint: checkpoint)
                )
                items.append(try ForgeCompactContextItem(
                    id: "checkpoint:" + forgeCompactContentID(content),
                    sourceRevision: sourceRevision,
                    tier: .l2ProjectMemory,
                    kind: .workingNote,
                    priority: 80,
                    content: content,
                    provenance: ForgeCompactProvenance(
                        kind: .checkpoint,
                        reference: "checkpoint:" + checkpoint.checkpointID.description
                    ),
                    isAuthoritative: true
                ))
            }

            let capsuleBudget = Self.projectMemorySupplementBudgetBytes
                - Self.projectMemoryCapsuleHeaderReserveBytes
            let capsule = try ProjectCapsuleBuilder.build(
                authority: authority,
                items: items,
                budgetBytes: capsuleBudget
            )
            guard !capsule.selectedItems.isEmpty else { return rawText }

            let header = "[NOVAFORGE_PROJECT_MEMORY_CAPSULE_V1]"
                + "[source_revision=\(sourceRevision)]"
                + "[source_items=\(capsule.sourceItemCount)]"
                + "[selected=\(capsule.selectedItems.count)]"
                + "[omitted=\(capsule.omittedItems.count)]"
            let candidate = header + "\n" + capsule.renderedContext
            guard candidate.utf8.count <= Self.projectMemorySupplementBudgetBytes,
                  candidate.utf8.count < rawText.utf8.count
            else {
                return rawText
            }
            return candidate
        } catch {
            // Forge Compact is an optimization layer. The canonical raw supplement
            // remains the source-faithful fallback and must never block a valid turn.
            return rawText
        }
    }

    func forgeCompactSourceRevision(_ text: String) -> String {
        "sha256:" + forgeCompactContentID(text)
    }

    func forgeCompactContentID(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct AgentForgeCompactArtifactPayload: Encodable {
    let kind = "artifact_reference"
    let artifact: ArtifactReference
}

private struct AgentForgeCompactCheckpointPayload: Encodable {
    let kind = "context_checkpoint_reference"
    let checkpoint: ContextCheckpointReference
}

'''
replace_once(
    preparer,
    "private struct AgentCanonicalContextSupplement: Encodable {\n",
    helper + "private struct AgentCanonicalContextSupplement: Encodable {\n",
)


tests = Path("AgentPadTests/AgentCanonicalContextPreparerTests.swift")
new_test = r'''    func testLargeProjectMemorySupplementCompactsWithoutTouchingCanonicalTranscript() async throws {
        let fixture = CanonicalContextFixture(seed: 81)
        let itemID: ModelItemID = canonicalTagged(8_101)
        let items = [fixture.userItem(id: itemID)]
        let artifacts: [ArtifactReference] = (0..<400).map { index in
            ArtifactReference(
                artifactID: canonicalTagged(81_000 + index),
                mediaType: "text/plain",
                contentDigest: canonicalDigest(character: "f"),
                displayName: "memory-\(index)-" + String(repeating: "x", count: 220)
            )
        }
        let state = fixture.state(modelItems: items, artifacts: artifacts)
        let baselineState = fixture.state(modelItems: items)
        let preparer = try fixture.preparer()

        let first = try await preparer.prepareProviderTurn(state: state, tools: [])
        let second = try await preparer.prepareProviderTurn(state: state, tools: [])
        let baseline = try await preparer.prepareProviderTurn(state: baselineState, tools: [])

        XCTAssertEqual(first.request, second.request)
        XCTAssertEqual(first.contextDigest, second.contextDigest)
        XCTAssertEqual(first.itemIDs, baseline.itemIDs)
        XCTAssertEqual(first.itemIDs, [itemID])
        XCTAssertEqual(
            Array(first.request.messages.dropFirst(3)),
            Array(baseline.request.messages.dropFirst(2)),
            "Forge Compact may replace only the project-memory supplement; canonical transcript messages must remain byte-for-byte equivalent"
        )

        let supplement = try text(from: first.request.messages[2])
        XCTAssertTrue(supplement.hasPrefix("[NOVAFORGE_PROJECT_MEMORY_CAPSULE_V1]"))
        XCTAssertTrue(supplement.contains("[source_items=400]"))
        XCTAssertFalse(supplement.contains("[omitted=0]"))
        XCTAssertTrue(supplement.contains("[L2][sourceLocation][truth][current]"))
        XCTAssertFalse(supplement.contains("novaforge_context_supplement_v1"))
        XCTAssertLessThanOrEqual(
            supplement.utf8.count,
            AgentCanonicalContextPreparer.projectMemorySupplementBudgetBytes
        )
    }

'''
replace_once(
    tests,
    "    func testSingleToolEnvelopeUsesExactProviderCallIDAndLosslessResult() async throws {\n",
    new_test + "    func testSingleToolEnvelopeUsesExactProviderCallIDAndLosslessResult() async throws {\n",
)


project = Path("AgentPad.xcodeproj/project.pbxproj")
replace_once(
    project,
    "\t\tD42000000000000000000103 /* AgentStore in Frameworks */ = {isa = PBXBuildFile; productRef = D42000000000000000001603 /* AgentStore */; };\n",
    "\t\tD42000000000000000000103 /* AgentStore in Frameworks */ = {isa = PBXBuildFile; productRef = D42000000000000000001603 /* AgentStore */; };\n"
    "\t\tFC4100000000000000000101 /* ForgeCompactCore in Frameworks */ = {isa = PBXBuildFile; productRef = FC4100000000000000001601 /* ForgeCompactCore */; };\n"
    "\t\tFC4200000000000000000101 /* ForgeCompactCore in Frameworks */ = {isa = PBXBuildFile; productRef = FC4200000000000000001601 /* ForgeCompactCore */; };\n",
)
replace_once(
    project,
    "\t\t\t\tD41000000000000000000106 /* AgentTools in Frameworks */,\n",
    "\t\t\t\tD41000000000000000000106 /* AgentTools in Frameworks */,\n"
    "\t\t\t\tFC4100000000000000000101 /* ForgeCompactCore in Frameworks */,\n",
)
replace_once(
    project,
    "\t\t\t\tD42000000000000000000106 /* AgentTools in Frameworks */,\n",
    "\t\t\t\tD42000000000000000000106 /* AgentTools in Frameworks */,\n"
    "\t\t\t\tFC4200000000000000000101 /* ForgeCompactCore in Frameworks */,\n",
)
replace_once(
    project,
    "\t\t\t\tD41000000000000000001606 /* AgentTools */,\n",
    "\t\t\t\tD41000000000000000001606 /* AgentTools */,\n"
    "\t\t\t\tFC4100000000000000001601 /* ForgeCompactCore */,\n",
)
replace_once(
    project,
    "\t\t\t\tD42000000000000000001606 /* AgentTools */,\n",
    "\t\t\t\tD42000000000000000001606 /* AgentTools */,\n"
    "\t\t\t\tFC4200000000000000001601 /* ForgeCompactCore */,\n",
)
replace_once(
    project,
    "\t\t\t\tD40000000000000000001601 /* XCLocalSwiftPackageReference \"Packages/AgentHarnessKit\" */,\n",
    "\t\t\t\tD40000000000000000001601 /* XCLocalSwiftPackageReference \"Packages/AgentHarnessKit\" */,\n"
    "\t\t\t\tFC4000000000000000001601 /* XCLocalSwiftPackageReference \"Packages/ForgeCompactCore\" */,\n",
)
replace_once(
    project,
    "\t\tD40000000000000000001601 /* XCLocalSwiftPackageReference \"Packages/AgentHarnessKit\" */ = {\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = Packages/AgentHarnessKit;\n\t\t};\n",
    "\t\tD40000000000000000001601 /* XCLocalSwiftPackageReference \"Packages/AgentHarnessKit\" */ = {\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = Packages/AgentHarnessKit;\n\t\t};\n"
    "\t\tFC4000000000000000001601 /* XCLocalSwiftPackageReference \"Packages/ForgeCompactCore\" */ = {\n"
    "\t\t\tisa = XCLocalSwiftPackageReference;\n"
    "\t\t\trelativePath = Packages/ForgeCompactCore;\n"
    "\t\t};\n",
)
replace_once(
    project,
    "/* End XCSwiftPackageProductDependency section */\n",
    "\t\tFC4100000000000000001601 /* ForgeCompactCore */ = {\n"
    "\t\t\tisa = XCSwiftPackageProductDependency;\n"
    "\t\t\tpackage = FC4000000000000000001601 /* XCLocalSwiftPackageReference \"Packages/ForgeCompactCore\" */;\n"
    "\t\t\tproductName = ForgeCompactCore;\n"
    "\t\t};\n"
    "\t\tFC4200000000000000001601 /* ForgeCompactCore */ = {\n"
    "\t\t\tisa = XCSwiftPackageProductDependency;\n"
    "\t\t\tpackage = FC4000000000000000001601 /* XCLocalSwiftPackageReference \"Packages/ForgeCompactCore\" */;\n"
    "\t\t\tproductName = ForgeCompactCore;\n"
    "\t\t};\n"
    "/* End XCSwiftPackageProductDependency section */\n",
)

print("Applied Forge Compact provider-supplement integration")
