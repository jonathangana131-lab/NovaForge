import AgentDomain
import ProjectBrain
import XCTest

final class ProjectBrainTests: XCTestCase {
    func testSourceInvalidationPreservesStaleProvenance() throws {
        let projectID = ProjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let factID = ProjectBrainFactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let source = ProjectBrainFactSource.sourceFile(path: "Sources/App.swift", digest: "sha256:old")
        let fact = ProjectBrainFact(
            id: factID,
            key: "app.shell",
            value: "legacy",
            scope: .file("Sources/App.swift"),
            source: source,
            verifiedAt: AgentInstant(rawValue: 10)
        )
        let initial = ProjectBrainSnapshot(projectID: projectID)
        let inserted = try ProjectBrainReducer.upsert(fact, expectedRevision: .initial, into: initial)
        let invalidated = try ProjectBrainReducer.invalidate(
            source: source,
            at: AgentInstant(rawValue: 20),
            expectedRevision: inserted.revision,
            in: inserted
        )

        XCTAssertTrue(invalidated.currentFacts.isEmpty)
        XCTAssertEqual(invalidated.facts.count, 1)
        XCTAssertEqual(invalidated.facts[0].status, .stale)
        XCTAssertEqual(invalidated.facts[0].source, source)
        XCTAssertEqual(invalidated.facts[0].invalidatedAt, AgentInstant(rawValue: 20))
    }

    func testContextSliceExcludesStaleFactsAndCarriesBrainRevision() throws {
        let projectID = ProjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
        let current = ProjectBrainFact(
            id: ProjectBrainFactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!),
            key: "design",
            value: "touch-first",
            scope: .feature("forge"),
            source: .userDecision(decisionID: "design-1"),
            verifiedAt: AgentInstant(rawValue: 30)
        )
        let stale = ProjectBrainFact(
            id: ProjectBrainFactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!),
            key: "design",
            value: "desktop-first",
            scope: .feature("forge"),
            source: .acceptedSummary(checkpointID: "old"),
            verifiedAt: AgentInstant(rawValue: 10),
            status: .stale,
            invalidatedAt: AgentInstant(rawValue: 20)
        )
        let snapshot = ProjectBrainSnapshot(
            projectID: projectID,
            revision: ProjectBrainRevision(rawValue: 7),
            facts: [stale, current]
        )

        let slice = snapshot.contextSlice(for: ProjectBrainContextRequest(
            keys: ["design"],
            scopes: [.feature("forge")],
            maxFacts: 1
        ))

        XCTAssertEqual(slice.projectID, projectID)
        XCTAssertEqual(slice.brainRevision, ProjectBrainRevision(rawValue: 7))
        XCTAssertEqual(slice.facts, [current])
        XCTAssertFalse(slice.isTruncated)
    }

    func testStaleRevisionCannotOverwriteAcceptedBrainState() throws {
        let projectID = ProjectID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let initial = ProjectBrainSnapshot(projectID: projectID)
        let fact = ProjectBrainFact(
            key: "intent",
            value: "Build a game",
            scope: .project,
            source: .userDecision(decisionID: "intent-1"),
            verifiedAt: AgentInstant(rawValue: 1)
        )
        _ = try ProjectBrainReducer.upsert(fact, expectedRevision: initial.revision, into: initial)

        XCTAssertThrowsError(try ProjectBrainReducer.upsert(fact, expectedRevision: ProjectBrainRevision(rawValue: 1), into: initial)) { error in
            XCTAssertEqual(
                error as? ProjectBrainMutationError,
                .staleRevision(expected: ProjectBrainRevision(rawValue: 1), actual: .initial)
            )
        }
    }
}
