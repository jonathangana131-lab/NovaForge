import Foundation
import XCTest
@testable import ProjectBrainRetrievalCore

final class ProjectBrainRetrievalCoreTests: XCTestCase {
    func testL0ContextIsAlwaysResidentEvenWhenNotExplicitlyRequired() throws {
        let plan = try ProjectBrainRetrievalPlanner.plan(
            request: request(maximumItems: 2, maximumBytes: 128),
            candidates: [
                try candidate("working", tier: .l1ActiveWorkingSet, priority: 100, text: "working"),
                try candidate("policy", tier: .l0AlwaysResident, priority: 0, text: "policy"),
                try candidate("memory", tier: .l2ProjectMemory, priority: 100, text: "memory"),
            ]
        )

        XCTAssertEqual(plan.selected.map(\.factID), ["policy", "working"])
        XCTAssertEqual(plan.omissions, [.init(factID: "memory", reason: .itemBudget)])
    }

    func testRequiredContextFailsClosedInsteadOfBeingTruncatedByByteBudget() throws {
        let request = try ProjectBrainRetrievalRequest(
            requestID: "req",
            projectID: "project",
            sourceRevisionID: "rev-1",
            requiredFactIDs: ["must-keep"],
            budget: try .init(maximumItems: 4, maximumUTF8Bytes: 4)
        )

        XCTAssertThrowsError(
            try ProjectBrainRetrievalPlanner.plan(
                request: request,
                candidates: [try candidate("must-keep", tier: .l2ProjectMemory, text: "12345")]
            )
        ) { error in
            XCTAssertEqual(error as? ProjectBrainRetrievalError, .requiredContextExceedsByteBudget)
        }
    }

    func testRequiredContextFailsClosedInsteadOfBeingTruncatedByItemBudget() throws {
        let request = try ProjectBrainRetrievalRequest(
            requestID: "req",
            projectID: "project",
            sourceRevisionID: "rev-1",
            requiredFactIDs: ["a", "b"],
            budget: try .init(maximumItems: 1, maximumUTF8Bytes: 128)
        )

        XCTAssertThrowsError(
            try ProjectBrainRetrievalPlanner.plan(
                request: request,
                candidates: [
                    try candidate("a", tier: .l1ActiveWorkingSet),
                    try candidate("b", tier: .l2ProjectMemory),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? ProjectBrainRetrievalError, .requiredContextExceedsItemBudget)
        }
    }

    func testColdArchiveRequiresExplicitRetrieval() throws {
        let cold = try candidate("cold", tier: .l3ColdArchive, priority: 100, text: "old log")
        let ordinaryRequest = request(maximumItems: 2, maximumBytes: 128)
        let ordinaryPlan = try ProjectBrainRetrievalPlanner.plan(
            request: ordinaryRequest,
            candidates: [cold]
        )

        XCTAssertTrue(ordinaryPlan.selected.isEmpty)
        XCTAssertEqual(
            ordinaryPlan.omissions,
            [.init(factID: "cold", reason: .coldArchiveNotRequested)]
        )

        let explicitRequest = try ProjectBrainRetrievalRequest(
            requestID: "req",
            projectID: "project",
            sourceRevisionID: "rev-1",
            explicitlyRequestedColdFactIDs: ["cold"],
            budget: try .init(maximumItems: 2, maximumUTF8Bytes: 128)
        )
        let explicitPlan = try ProjectBrainRetrievalPlanner.plan(
            request: explicitRequest,
            candidates: [cold]
        )
        XCTAssertEqual(explicitPlan.selected.map(\.factID), ["cold"])
    }

    func testExplicitColdRequestDoesNotInventMissingFact() throws {
        let request = try ProjectBrainRetrievalRequest(
            requestID: "req",
            projectID: "project",
            sourceRevisionID: "rev-1",
            explicitlyRequestedColdFactIDs: ["not-present"],
            budget: try .init(maximumItems: 2, maximumUTF8Bytes: 128)
        )

        let plan = try ProjectBrainRetrievalPlanner.plan(request: request, candidates: [])
        XCTAssertTrue(plan.selected.isEmpty)
        XCTAssertEqual(
            plan.omissions,
            [.init(factID: "not-present", reason: .requestedColdFactUnavailable)]
        )
    }

    func testExplicitColdRequestRejectsNonColdCandidateTier() throws {
        let request = try ProjectBrainRetrievalRequest(
            requestID: "req",
            projectID: "project",
            sourceRevisionID: "rev-1",
            explicitlyRequestedColdFactIDs: ["fact"],
            budget: try .init(maximumItems: 2, maximumUTF8Bytes: 128)
        )

        XCTAssertThrowsError(
            try ProjectBrainRetrievalPlanner.plan(
                request: request,
                candidates: [try candidate("fact", tier: .l2ProjectMemory)]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainRetrievalError,
                .explicitColdRequestTierMismatch(factID: "fact")
            )
        }
    }

    func testRequiredStaleFactCannotBeEvictedByFresherOptionalContext() throws {
        let request = try ProjectBrainRetrievalRequest(
            requestID: "req",
            projectID: "project",
            sourceRevisionID: "rev-1",
            requiredFactIDs: ["stale-blocker"],
            budget: try .init(maximumItems: 1, maximumUTF8Bytes: 128)
        )

        let plan = try ProjectBrainRetrievalPlanner.plan(
            request: request,
            candidates: [
                try candidate(
                    "stale-blocker",
                    tier: .l2ProjectMemory,
                    freshness: .stale,
                    priority: 0,
                    text: "stale but required blocker"
                ),
                try candidate(
                    "fresh-optional",
                    tier: .l1ActiveWorkingSet,
                    freshness: .current,
                    priority: .max,
                    text: "fresh optional"
                ),
            ]
        )

        XCTAssertEqual(plan.selected.map(\.factID), ["stale-blocker"])
        XCTAssertEqual(
            plan.omissions,
            [.init(factID: "fresh-optional", reason: .itemBudget)]
        )
    }

    func testCurrentFactsPrecedeUnknownAndStaleWithinSameTier() throws {
        let plan = try ProjectBrainRetrievalPlanner.plan(
            request: request(maximumItems: 3, maximumBytes: 128),
            candidates: [
                try candidate("stale", tier: .l1ActiveWorkingSet, freshness: .stale, priority: 500),
                try candidate("unknown", tier: .l1ActiveWorkingSet, freshness: .unknown, priority: 0),
                try candidate("current", tier: .l1ActiveWorkingSet, freshness: .current, priority: 0),
            ]
        )
        XCTAssertEqual(plan.selected.map(\.factID), ["current", "unknown", "stale"])
    }

    func testActiveWorkingSetPrecedesProjectMemoryRegardlessOfPriority() throws {
        let plan = try ProjectBrainRetrievalPlanner.plan(
            request: request(maximumItems: 1, maximumBytes: 128),
            candidates: [
                try candidate("memory", tier: .l2ProjectMemory, priority: .max),
                try candidate("active", tier: .l1ActiveWorkingSet, priority: 0),
            ]
        )
        XCTAssertEqual(plan.selected.map(\.factID), ["active"])
    }

    func testByteBudgetCountsExactRenderedFragmentsAndNewlineSeparator() throws {
        let exactPlan = try ProjectBrainRetrievalPlanner.plan(
            request: request(maximumItems: 3, maximumBytes: 7),
            candidates: [
                try candidate("a", tier: .l1ActiveWorkingSet, priority: 2, text: "abc"),
                try candidate("b", tier: .l1ActiveWorkingSet, priority: 1, text: "def"),
            ]
        )
        XCTAssertEqual(exactPlan.renderedContext, "abc\ndef")
        XCTAssertEqual(exactPlan.renderedUTF8ByteCount, 7)

        let tightPlan = try ProjectBrainRetrievalPlanner.plan(
            request: request(maximumItems: 3, maximumBytes: 6),
            candidates: [
                try candidate("a", tier: .l1ActiveWorkingSet, priority: 2, text: "abc"),
                try candidate("b", tier: .l1ActiveWorkingSet, priority: 1, text: "def"),
            ]
        )
        XCTAssertEqual(tightPlan.selected.map(\.factID), ["a"])
        XCTAssertEqual(tightPlan.omissions, [.init(factID: "b", reason: .byteBudget)])
    }

    func testPlannerSkipsOversizedOptionalAndCanUseLaterSmallerCandidate() throws {
        let plan = try ProjectBrainRetrievalPlanner.plan(
            request: request(maximumItems: 3, maximumBytes: 5),
            candidates: [
                try candidate("large", tier: .l1ActiveWorkingSet, priority: 2, text: "123456"),
                try candidate("small", tier: .l1ActiveWorkingSet, priority: 1, text: "12345"),
            ]
        )
        XCTAssertEqual(plan.selected.map(\.factID), ["small"])
        XCTAssertEqual(plan.omissions, [.init(factID: "large", reason: .byteBudget)])
    }

    func testMixedProjectAndSourceRevisionFailClosed() throws {
        XCTAssertThrowsError(
            try ProjectBrainRetrievalPlanner.plan(
                request: request(maximumItems: 3, maximumBytes: 128),
                candidates: [try candidate("wrong-project", projectID: "other")]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainRetrievalError,
                .projectMismatch(factID: "wrong-project")
            )
        }

        XCTAssertThrowsError(
            try ProjectBrainRetrievalPlanner.plan(
                request: request(maximumItems: 3, maximumBytes: 128),
                candidates: [try candidate("wrong-rev", sourceRevisionID: "rev-2")]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainRetrievalError,
                .sourceRevisionMismatch(factID: "wrong-rev")
            )
        }
    }

    func testMissionScopedCandidateCannotLeakAcrossMissions() throws {
        let missionRequest = try ProjectBrainRetrievalRequest(
            requestID: "req",
            projectID: "project",
            sourceRevisionID: "rev-1",
            missionID: "mission-a",
            budget: try .init(maximumItems: 3, maximumUTF8Bytes: 128)
        )

        XCTAssertThrowsError(
            try ProjectBrainRetrievalPlanner.plan(
                request: missionRequest,
                candidates: [try candidate("other-mission", missionID: "mission-b")]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainRetrievalError,
                .missionMismatch(factID: "other-mission")
            )
        }

        let projectWide = try candidate("project-wide", missionID: nil)
        let plan = try ProjectBrainRetrievalPlanner.plan(
            request: missionRequest,
            candidates: [projectWide]
        )
        XCTAssertEqual(plan.selected.map(\.factID), ["project-wide"])
    }

    func testDuplicateCandidatesAndMissingRequiredFactsFailClosed() throws {
        let duplicate = try candidate("dup")
        XCTAssertThrowsError(
            try ProjectBrainRetrievalPlanner.plan(
                request: request(maximumItems: 3, maximumBytes: 128),
                candidates: [duplicate, duplicate]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainRetrievalError,
                .duplicateCandidateFactID("dup")
            )
        }

        let requiredRequest = try ProjectBrainRetrievalRequest(
            requestID: "req",
            projectID: "project",
            sourceRevisionID: "rev-1",
            requiredFactIDs: ["missing"],
            budget: try .init(maximumItems: 3, maximumUTF8Bytes: 128)
        )
        XCTAssertThrowsError(
            try ProjectBrainRetrievalPlanner.plan(request: requiredRequest, candidates: [])
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainRetrievalError,
                .missingRequiredFact("missing")
            )
        }
    }

    func testSelectionIsDeterministicAcrossCandidateInputOrder() throws {
        let candidates = [
            try candidate("c", tier: .l2ProjectMemory, priority: 10, relevance: 2),
            try candidate("a", tier: .l1ActiveWorkingSet, priority: 10, relevance: 1),
            try candidate("b", tier: .l1ActiveWorkingSet, priority: 10, relevance: 2),
        ]
        let request = request(maximumItems: 3, maximumBytes: 128)
        let first = try ProjectBrainRetrievalPlanner.plan(request: request, candidates: candidates)
        let second = try ProjectBrainRetrievalPlanner.plan(request: request, candidates: candidates.reversed())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.selected.map(\.factID), ["b", "a", "c"])
    }

    func testCandidateAndRequestDecodeReenterValidation() throws {
        let validCandidate = try candidate("fact")
        let candidateData = try JSONEncoder().encode(validCandidate)
        var candidateJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: candidateData) as? [String: Any]
        )
        candidateJSON["factID"] = " fact"
        let tamperedCandidateData = try JSONSerialization.data(withJSONObject: candidateJSON)
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectBrainRetrievalCandidate.self, from: tamperedCandidateData))

        let validRequest = request(maximumItems: 3, maximumBytes: 128)
        let requestData = try JSONEncoder().encode(validRequest)
        var requestJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        requestJSON["requiredFactIDs"] = ["x", "x"]
        let tamperedRequestData = try JSONSerialization.data(withJSONObject: requestJSON)
        XCTAssertThrowsError(try JSONDecoder().decode(ProjectBrainRetrievalRequest.self, from: tamperedRequestData))
    }

    func testInvalidIdentityAndBudgetBoundsAreRejected() throws {
        XCTAssertThrowsError(
            try ProjectBrainRetrievalCandidate(
                factID: "fact\nother",
                projectID: "project",
                sourceRevisionID: "rev-1",
                tier: .l1ActiveWorkingSet,
                freshness: .current,
                renderedContext: "context"
            )
        )
        XCTAssertThrowsError(
            try ProjectBrainRetrievalBudget(maximumItems: 0, maximumUTF8Bytes: 100)
        )
        XCTAssertThrowsError(
            try ProjectBrainRetrievalBudget(
                maximumItems: ProjectBrainRetrievalLimits.maximumSelectedItems + 1,
                maximumUTF8Bytes: 100
            )
        )
        XCTAssertThrowsError(
            try ProjectBrainRetrievalBudget(
                maximumItems: 1,
                maximumUTF8Bytes: ProjectBrainRetrievalLimits.maximumContextUTF8Bytes + 1
            )
        )
        XCTAssertThrowsError(
            try ProjectBrainRetrievalRequest(
                requestID: "req",
                projectID: "project",
                sourceRevisionID: "rev-1",
                requiredFactIDs: Array(
                    repeating: "same",
                    count: ProjectBrainRetrievalLimits.maximumSelectedItems + 1
                ),
                budget: try .init(maximumItems: 1, maximumUTF8Bytes: 128)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectBrainRetrievalError,
                .tooManyRequestedFactIDs
            )
        }
    }

    private func request(maximumItems: Int, maximumBytes: Int) -> ProjectBrainRetrievalRequest {
        try! ProjectBrainRetrievalRequest(
            requestID: "req",
            projectID: "project",
            sourceRevisionID: "rev-1",
            budget: try! .init(maximumItems: maximumItems, maximumUTF8Bytes: maximumBytes)
        )
    }

    private func candidate(
        _ factID: String,
        projectID: String = "project",
        sourceRevisionID: String = "rev-1",
        missionID: String? = nil,
        tier: ProjectBrainContextTier = .l1ActiveWorkingSet,
        freshness: ProjectBrainRetrievalFreshness = .current,
        priority: UInt16 = 0,
        relevance: UInt16 = 0,
        text: String = "context"
    ) throws -> ProjectBrainRetrievalCandidate {
        try ProjectBrainRetrievalCandidate(
            factID: factID,
            projectID: projectID,
            sourceRevisionID: sourceRevisionID,
            missionID: missionID,
            tier: tier,
            freshness: freshness,
            priority: priority,
            relevance: relevance,
            renderedContext: text
        )
    }
}
