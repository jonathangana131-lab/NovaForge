import XCTest
@testable import AgentDomain

final class ProjectBrainContextTests: XCTestCase {
    func testExactScopeRanksBeforeProjectFallbackAndOtherScopesAreExcluded() throws {
        let projectID = ProjectID()
        let target = fact(
            projectID: projectID,
            statement: "Target file owns the renderer",
            scope: .init(kind: .file, reference: "Sources/Renderer.swift"),
            verifiedAt: 10
        )
        let project = fact(
            projectID: projectID,
            statement: "Project uses a renderer service",
            scope: .init(kind: .project),
            verifiedAt: 30
        )
        let unrelated = fact(
            projectID: projectID,
            statement: "Settings file owns preferences",
            scope: .init(kind: .file, reference: "Sources/Settings.swift"),
            verifiedAt: 40
        )

        let slice = try ProjectBrainContextSelector.select(
            from: [project, unrelated, target],
            request: .init(
                projectID: projectID,
                scopes: [.init(kind: .file, reference: "Sources/Renderer.swift")]
            )
        )

        XCTAssertEqual(slice.facts.map(\.factID), [target.factID, project.factID])
        XCTAssertEqual(slice.matchedFactCount, 2)
    }

    func testMissionNeighborhoodIncludesProjectFactsButExcludesOtherMissions() throws {
        let projectID = ProjectID()
        let missionID = MissionID()
        let otherMissionID = MissionID()
        let project = fact(
            projectID: projectID,
            statement: "Global design DNA",
            scope: .init(kind: .project),
            verifiedAt: 100
        )
        let mission = fact(
            projectID: projectID,
            missionID: missionID,
            statement: "Mission accepted landscape orientation",
            scope: .init(kind: .mission, reference: "mission-current"),
            verifiedAt: 20
        )
        let other = fact(
            projectID: projectID,
            missionID: otherMissionID,
            statement: "Other mission chose portrait",
            scope: .init(kind: .mission, reference: "mission-other"),
            verifiedAt: 200
        )

        let slice = try ProjectBrainContextSelector.select(
            from: [project, other, mission],
            request: .init(projectID: projectID, missionID: missionID)
        )

        XCTAssertEqual(slice.facts.map(\.factID), [mission.factID, project.factID])
        XCTAssertFalse(slice.facts.contains(where: { $0.factID == other.factID }))
    }

    func testFreshnessPolicyIsExplicitAndIncludedStaleFactsRankLast() throws {
        let projectID = ProjectID()
        let current = fact(
            projectID: projectID,
            statement: "Current source fact",
            scope: .init(kind: .project),
            verifiedAt: 1,
            freshness: .current
        )
        let unknown = fact(
            projectID: projectID,
            statement: "Unknown freshness fact",
            scope: .init(kind: .project),
            verifiedAt: 100,
            freshness: .unknown
        )
        let stale = fact(
            projectID: projectID,
            statement: "Old source fact",
            scope: .init(kind: .project),
            verifiedAt: 200,
            freshness: .stale,
            staleReason: "Source changed"
        )

        let currentOnly = try ProjectBrainContextSelector.select(
            from: [stale, unknown, current],
            request: .init(projectID: projectID, freshnessPolicy: .currentOnly)
        )
        XCTAssertEqual(currentOnly.facts.map(\.factID), [current.factID])

        let currentAndUnknown = try ProjectBrainContextSelector.select(
            from: [stale, unknown, current],
            request: .init(projectID: projectID, freshnessPolicy: .currentAndUnknown)
        )
        XCTAssertEqual(currentAndUnknown.facts.map(\.factID), [current.factID, unknown.factID])

        let all = try ProjectBrainContextSelector.select(
            from: [stale, unknown, current],
            request: .init(projectID: projectID, freshnessPolicy: .includeStale)
        )
        XCTAssertEqual(all.facts.map(\.factID), [current.factID, unknown.factID, stale.factID])
        XCTAssertEqual(all.facts.last?.staleReason, "Source changed")
    }

    func testPreferredKindOrderingIsDeterministic() throws {
        let projectID = ProjectID()
        let architecture = fact(
            projectID: projectID,
            kind: .architecture,
            statement: "Architecture fact",
            scope: .init(kind: .project),
            verifiedAt: 1
        )
        let feature = fact(
            projectID: projectID,
            kind: .feature,
            statement: "Feature fact",
            scope: .init(kind: .project),
            verifiedAt: 100
        )

        let slice = try ProjectBrainContextSelector.select(
            from: [feature, architecture],
            request: .init(
                projectID: projectID,
                preferredKinds: [.architecture, .feature]
            )
        )
        XCTAssertEqual(slice.facts.map(\.factID), [architecture.factID, feature.factID])
    }

    func testCharacterBudgetCompactsWithoutRewritingFacts() throws {
        let projectID = ProjectID()
        let first = fact(
            projectID: projectID,
            statement: "First accepted architecture fact",
            scope: .init(kind: .project),
            verifiedAt: 20
        )
        let second = fact(
            projectID: projectID,
            statement: "Second accepted architecture fact",
            scope: .init(kind: .project),
            verifiedAt: 10
        )
        let firstCost = ProjectBrainContextSelector.estimatedCharacterCount(of: first)

        let slice = try ProjectBrainContextSelector.select(
            from: [second, first],
            request: .init(
                projectID: projectID,
                maxFacts: 10,
                maxCharacters: firstCost
            )
        )

        XCTAssertEqual(slice.facts, [first])
        XCTAssertEqual(slice.budgetOmittedFactIDs, [second.factID])
        XCTAssertEqual(slice.matchedFactCount, 2)
        XCTAssertEqual(slice.estimatedCharacterCount, firstCost)
        XCTAssertTrue(slice.isCompacted)
        XCTAssertEqual(slice.facts[0].provenance, first.provenance)
    }

    func testFactBudgetReportsEveryMatchedFactOmittedByCompaction() throws {
        let projectID = ProjectID()
        let first = fact(projectID: projectID, statement: "A", scope: .init(kind: .project), verifiedAt: 3)
        let second = fact(projectID: projectID, statement: "B", scope: .init(kind: .project), verifiedAt: 2)
        let third = fact(projectID: projectID, statement: "C", scope: .init(kind: .project), verifiedAt: 1)

        let slice = try ProjectBrainContextSelector.select(
            from: [third, second, first],
            request: .init(projectID: projectID, maxFacts: 1, maxCharacters: 100_000)
        )

        XCTAssertEqual(slice.facts.map(\.factID), [first.factID])
        XCTAssertEqual(slice.budgetOmittedFactIDs, [second.factID, third.factID])
        XCTAssertEqual(slice.matchedFactCount, 3)
    }

    func testRelevantInvalidFactFailsClosedButForeignInvalidFactCannotPoisonRequest() throws {
        let projectID = ProjectID()
        let foreignProjectID = ProjectID()
        let valid = fact(
            projectID: projectID,
            statement: "Valid source-backed fact",
            scope: .init(kind: .project),
            verifiedAt: 1
        )
        let invalidRelevant = ProjectBrainFact(
            factID: ProjectBrainFactID(),
            projectID: projectID,
            kind: .feature,
            statement: "Derived only",
            scope: .init(kind: .project),
            provenance: [
                .init(kind: .modelObservation, reference: "model:guess", capturedAt: instant(2)),
            ],
            lastVerifiedAt: instant(2)
        )
        let invalidForeign = ProjectBrainFact(
            factID: ProjectBrainFactID(),
            projectID: foreignProjectID,
            kind: .feature,
            statement: "Foreign derived only",
            scope: .init(kind: .project),
            provenance: [
                .init(kind: .modelObservation, reference: "model:foreign", capturedAt: instant(3)),
            ],
            lastVerifiedAt: instant(3)
        )

        XCTAssertThrowsError(try ProjectBrainContextSelector.select(
            from: [valid, invalidRelevant],
            request: .init(projectID: projectID)
        )) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .invalidFact(invalidRelevant.factID, .derivedOnlyProvenance)
            )
        }

        let safe = try ProjectBrainContextSelector.select(
            from: [invalidForeign, valid],
            request: .init(projectID: projectID)
        )
        XCTAssertEqual(safe.facts, [valid])
    }

    func testInvalidRequestsFailBeforeFactSelection() throws {
        let projectID = ProjectID()
        XCTAssertThrowsError(try ProjectBrainContextSelector.select(
            from: [],
            request: .init(projectID: projectID, maxFacts: 0)
        )) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .invalidRequest(.emptyFactBudget)
            )
        }

        XCTAssertThrowsError(try ProjectBrainContextSelector.select(
            from: [],
            request: .init(projectID: projectID, maxCharacters: 0)
        )) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .invalidRequest(.emptyCharacterBudget)
            )
        }

        XCTAssertThrowsError(try ProjectBrainContextSelector.select(
            from: [],
            request: .init(projectID: projectID, preferredKinds: [.feature, .feature])
        )) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .invalidRequest(.duplicatePreferredKind)
            )
        }

        let duplicateScope = ProjectBrainScope(kind: .file, reference: "A.swift")
        XCTAssertThrowsError(try ProjectBrainContextSelector.select(
            from: [],
            request: .init(projectID: projectID, scopes: [duplicateScope, duplicateScope])
        )) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .invalidRequest(.duplicateScope)
            )
        }
    }

    func testSelectionIsStableAcrossInputOrder() throws {
        let projectID = ProjectID()
        let facts = [
            fact(projectID: projectID, kind: .feature, statement: "Feature", scope: .init(kind: .project), verifiedAt: 2),
            fact(projectID: projectID, kind: .architecture, statement: "Architecture", scope: .init(kind: .project), verifiedAt: 2),
            fact(projectID: projectID, kind: .runtimeCapability, statement: "Runtime", scope: .init(kind: .project), verifiedAt: 1),
        ]
        let request = ProjectBrainContextRequest(
            projectID: projectID,
            preferredKinds: [.architecture]
        )

        let forward = try ProjectBrainContextSelector.select(from: facts, request: request)
        let reversed = try ProjectBrainContextSelector.select(from: facts.reversed(), request: request)
        XCTAssertEqual(forward, reversed)
    }

    private func fact(
        projectID: ProjectID,
        missionID: MissionID? = nil,
        kind: ProjectBrainFactKind = .feature,
        statement: String,
        scope: ProjectBrainScope,
        verifiedAt: Int64,
        freshness: ProjectBrainFreshness = .current,
        staleReason: String? = nil
    ) -> ProjectBrainFact {
        ProjectBrainFact(
            factID: ProjectBrainFactID(),
            projectID: projectID,
            missionID: missionID,
            kind: kind,
            statement: statement,
            scope: scope,
            provenance: [
                .init(
                    kind: .sourceFile,
                    reference: scope.reference ?? "Project.swift",
                    capturedAt: instant(verifiedAt),
                    contentDigest: "sha256:\(verifiedAt)"
                ),
            ],
            lastVerifiedAt: instant(verifiedAt),
            freshness: freshness,
            staleReason: staleReason
        )
    }

    private func instant(_ value: Int64) -> AgentInstant {
        AgentInstant(rawValue: value)
    }
}
