import XCTest
@testable import AgentDomain

final class ProjectBrainContextV14TruthTests: XCTestCase {
    func testRequiredKindsOnlyAddToMissionCriticalFloor() throws {
        let projectID = ProjectID()
        let accepted = fact(
            projectID: projectID,
            kind: .acceptedDecision,
            statement: "Accepted truth",
            verifiedAt: 1
        )
        let feature = fact(
            projectID: projectID,
            kind: .feature,
            statement: "Required feature",
            verifiedAt: 2
        )

        let request = ProjectBrainContextRequest(
            projectID: projectID,
            requiredKinds: [.feature],
            maxFacts: 1,
            maxCharacters: 100_000
        )

        XCTAssertThrowsError(try ProjectBrainContextSelector.select(
            from: [feature, accepted],
            request: request
        )) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .requiredFactsExceedFactBudget(required: 2, maximum: 1)
            )
        }
    }

    func testMissionCriticalKindCannotBeRepeatedAsAdditionalRequirement() {
        let request = ProjectBrainContextRequest(
            projectID: ProjectID(),
            requiredKinds: [.acceptedDecision]
        )
        XCTAssertEqual(request.validationError, .duplicateRequiredKind)
    }

    func testForeignFactsDoNotConsumeRelevantCandidateLimit() throws {
        let projectID = ProjectID()
        let foreignProjectID = ProjectID()
        let relevant = fact(
            projectID: projectID,
            kind: .feature,
            statement: "Relevant",
            verifiedAt: 1
        )
        let foreign = (0...ProjectBrainContextSelector.maximumCandidateFacts).map { value in
            fact(
                projectID: foreignProjectID,
                kind: .feature,
                statement: "Foreign \(value)",
                verifiedAt: Int64(value)
            )
        }

        let slice = try ProjectBrainContextSelector.select(
            from: foreign + [relevant],
            request: .init(projectID: projectID)
        )

        XCTAssertEqual(slice.facts, [relevant])
        XCTAssertEqual(slice.matchedFactCount, 1)
    }

    func testMissionCriticalUnknownFreshnessFailsClosed() {
        let projectID = ProjectID()
        let decision = fact(
            projectID: projectID,
            kind: .acceptedDecision,
            statement: "Decision needing refresh",
            verifiedAt: 1,
            freshness: .unknown
        )

        XCTAssertThrowsError(try ProjectBrainContextSelector.select(
            from: [decision],
            request: .init(projectID: projectID, freshnessPolicy: .currentOnly)
        )) { error in
            XCTAssertEqual(
                error as? ProjectBrainContextSelectionError,
                .requiredFactExcludedByFreshness(decision.factID, .unknown)
            )
        }
    }

    private func fact(
        projectID: ProjectID,
        kind: ProjectBrainFactKind,
        statement: String,
        verifiedAt: Int64,
        freshness: ProjectBrainFreshness = .current
    ) -> ProjectBrainFact {
        ProjectBrainFact(
            factID: ProjectBrainFactID(),
            projectID: projectID,
            kind: kind,
            statement: statement,
            scope: .init(kind: .project),
            provenance: [
                .init(
                    kind: .sourceFile,
                    reference: "Project.swift",
                    capturedAt: .init(rawValue: verifiedAt),
                    contentDigest: "sha256:\(verifiedAt)"
                ),
            ],
            lastVerifiedAt: .init(rawValue: verifiedAt),
            freshness: freshness
        )
    }
}
