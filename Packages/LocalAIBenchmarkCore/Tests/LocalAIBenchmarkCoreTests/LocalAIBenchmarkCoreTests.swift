import XCTest
@testable import LocalAIBenchmarkCore

final class LocalAIBenchmarkCoreTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)
    private let digestC = String(repeating: "c", count: 64)
    private let digestD = String(repeating: "d", count: 64)

    func testSuiteRejectsDuplicateTaskIDs() throws {
        let task = makeTask(id: "route", category: .intentRouting, digest: digestA)
        XCTAssertThrowsError(try LocalAIBenchmarkSuite(
            id: "general-agent", version: 1,
            requiredCategories: [.intentRouting], tasks: [task, task]
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .duplicateTaskID("route"))
        }
    }

    func testSuiteRejectsMissingRequiredCategory() throws {
        let task = makeTask(id: "route", category: .intentRouting, digest: digestA)
        XCTAssertThrowsError(try LocalAIBenchmarkSuite(
            id: "general-agent", version: 1,
            requiredCategories: [.intentRouting, .codeRepair], tasks: [task]
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .requiredCategoryMissingTask(.codeRepair))
        }
    }

    func testSuiteRejectsOptionalOnlyRequiredCategory() throws {
        let task = LocalAIBenchmarkTask(
            id: "route", revision: 1, category: .intentRouting,
            weight: 1, isRequired: false, fixtureDigest: digestA
        )
        XCTAssertThrowsError(try LocalAIBenchmarkSuite(
            id: "general-agent", version: 1,
            requiredCategories: [.intentRouting], tasks: [task]
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError,
                           .requiredCategoryMissingRequiredTask(.intentRouting))
        }
    }

    func testSuiteRejectsNonCanonicalFixtureDigest() throws {
        let task = makeTask(
            id: "route", category: .intentRouting,
            digest: String(repeating: "A", count: 64)
        )
        XCTAssertThrowsError(try LocalAIBenchmarkSuite(
            id: "general-agent", version: 1,
            requiredCategories: [.intentRouting], tasks: [task]
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .invalidFixtureDigest("route"))
        }
    }

    func testMissingTasksStayInDenominatorAndPreventComparisonEligibility() throws {
        let suite = try makeSuite()
        let score = try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite,
            observations: [
                observation(id: "route", outcome: .passed, digest: digestA),
                observation(id: "tool", outcome: .passed, digest: digestB),
            ]
        )
        XCTAssertEqual(score.weightedSuccess, 0.5, accuracy: 0.0001)
        XCTAssertEqual(score.completedCoverage, 0.5, accuracy: 0.0001)
        XCTAssertFalse(score.isComplete)
        XCTAssertFalse(score.requiredTasksPassed)
        XCTAssertFalse(score.requiredCategoryCoverage)
        XCTAssertEqual(score.notRunTaskIDs, ["repair", "continue"])
        XCTAssertFalse(score.eligibleForExactComparison)
    }

    func testFailedTasksRemainCompletedEvidenceButDoNotCountAsSuccess() throws {
        let suite = try makeSuite()
        let score = try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite,
            observations: [
                observation(id: "route", outcome: .passed, digest: digestA),
                observation(id: "tool", outcome: .failed, digest: digestB),
                observation(id: "repair", outcome: .passed, digest: digestC),
                observation(id: "continue", outcome: .passed, digest: digestD),
            ]
        )
        XCTAssertEqual(score.completedCoverage, 1, accuracy: 0.0001)
        XCTAssertEqual(score.weightedSuccess, 0.75, accuracy: 0.0001)
        XCTAssertTrue(score.isComplete)
        XCTAssertTrue(score.requiredCategoryCoverage)
        XCTAssertFalse(score.requiredTasksPassed)
        XCTAssertEqual(score.failedTaskIDs, ["tool"])
        XCTAssertTrue(score.eligibleForExactComparison)
    }

    func testNotRunCannotCarryEvidence() throws {
        let suite = try makeSuite()
        XCTAssertThrowsError(try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite,
            observations: [.init(
                taskID: "route", taskRevision: 1,
                outcome: .notRun, evidenceDigest: digestA
            )]
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .notRunCannotCarryEvidence("route"))
        }
    }

    func testPassedAndFailedRequireEvidenceDigest() throws {
        let suite = try makeSuite()
        for outcome in [LocalAIBenchmarkOutcome.passed, .failed] {
            XCTAssertThrowsError(try LocalAIBenchmarkEvaluator.evaluate(
                suite: suite,
                observations: [.init(
                    taskID: "route", taskRevision: 1,
                    outcome: outcome, evidenceDigest: nil
                )]
            )) { error in
                XCTAssertEqual(error as? LocalAIBenchmarkError,
                               .missingOrInvalidEvidenceDigest("route"))
            }
        }
    }

    func testEvaluatorRejectsUnknownDuplicateAndRevisionMismatch() throws {
        let suite = try makeSuite()
        XCTAssertThrowsError(try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite,
            observations: [observation(id: "unknown", outcome: .passed, digest: digestA)]
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .unknownTaskID("unknown"))
        }

        let duplicate = observation(id: "route", outcome: .passed, digest: digestA)
        XCTAssertThrowsError(try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite, observations: [duplicate, duplicate]
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .duplicateObservation("route"))
        }

        XCTAssertThrowsError(try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite,
            observations: [.init(
                taskID: "route", taskRevision: 2,
                outcome: .passed, evidenceDigest: digestA
            )]
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError,
                           .taskRevisionMismatch(taskID: "route", expected: 1, actual: 2))
        }
    }

    func testCategoryScoresPreserveWeightedSemantics() throws {
        let suite = try LocalAIBenchmarkSuite(
            id: "weighted", version: 1, requiredCategories: [.codeRepair],
            tasks: [
                .init(id: "small", revision: 1, category: .codeRepair,
                      weight: 1, fixtureDigest: digestA),
                .init(id: "large", revision: 1, category: .codeRepair,
                      weight: 3, fixtureDigest: digestB),
            ]
        )
        let score = try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite,
            observations: [
                observation(id: "small", outcome: .passed, digest: digestC),
                observation(id: "large", outcome: .failed, digest: digestD),
            ]
        )
        XCTAssertEqual(score.weightedSuccess, 0.25, accuracy: 0.0001)
        XCTAssertEqual(score.categoryScores[0].weightedSuccess, 0.25, accuracy: 0.0001)
        XCTAssertEqual(score.categoryScores[0].completedCoverage, 1, accuracy: 0.0001)
    }

    func testExactComparisonRequiresSameCompleteSuiteIdentity() throws {
        let suite = try makeSuite()
        let baseline = try receipt(suite: suite, failedTaskID: "repair")
        let candidate = try receipt(suite: suite, failedTaskID: nil)
        let comparison = try LocalAIBenchmarkEvaluator.compare(
            baseline: baseline, candidate: candidate
        )
        XCTAssertEqual(comparison.weightedSuccessDelta, 0.25, accuracy: 0.0001)

        let other = try LocalAIBenchmarkSuite(
            id: suite.id, version: 2,
            requiredCategories: suite.requiredCategories, tasks: suite.tasks
        )
        XCTAssertThrowsError(try LocalAIBenchmarkEvaluator.compare(
            baseline: baseline, candidate: try receipt(suite: other, failedTaskID: nil)
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .suiteVersionMismatch)
        }
    }

    func testSameVersionDifferentSuiteDefinitionCannotBeCompared() throws {
        let suite = try makeSuite()
        var changedTasks = suite.tasks
        changedTasks[0] = makeTask(
            id: "route", category: .intentRouting,
            digest: String(repeating: "e", count: 64)
        )
        let changedSuite = try LocalAIBenchmarkSuite(
            id: suite.id, version: suite.version,
            requiredCategories: suite.requiredCategories, tasks: changedTasks
        )
        XCTAssertThrowsError(try LocalAIBenchmarkEvaluator.compare(
            baseline: receipt(suite: suite, failedTaskID: nil),
            candidate: receipt(suite: changedSuite, failedTaskID: nil)
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .suiteDefinitionMismatch)
        }
    }

    func testIncompleteScoreCannotBeCompared() throws {
        let suite = try makeSuite()
        let complete = try receipt(suite: suite, failedTaskID: nil)
        let partial = try LocalAIBenchmarkRunReceipt(
            suite: suite,
            observations: [observation(id: "route", outcome: .passed, digest: digestA)]
        )
        XCTAssertThrowsError(try LocalAIBenchmarkEvaluator.compare(
            baseline: complete, candidate: partial
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .incompleteComparison)
        }
    }

    func testReferenceTaxonomyCoversCoreLocalAgentResponsibilities() {
        XCTAssertEqual(
            LocalAIBenchmarkReferenceTaxonomy.generalAgentRequiredCategories,
            [.intentRouting, .structuredToolUse, .repositoryNavigation,
             .codeRepair, .contextCompaction, .continuationRecovery]
        )
    }

    func testScoreRoundTripsWithoutLosingFailuresOrCoverage() throws {
        let original = try score(suite: makeSuite(), failedTaskID: "tool")
        let decoded = try JSONDecoder().decode(
            LocalAIBenchmarkScore.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.failedTaskIDs, ["tool"])
        XCTAssertEqual(decoded.completedCoverage, 1, accuracy: 0.0001)
    }

    func testDecodedSuiteRevalidatesPersistedShape() throws {
        let malformed = #"{"id":"general-agent","version":1,"requiredCategories":["intentRouting"],"tasks":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            LocalAIBenchmarkSuite.self, from: Data(malformed.utf8)
        ))
    }

    func testRunReceiptRoundTripsAndRecomputesScore() throws {
        let original = try receipt(suite: makeSuite(), failedTaskID: "repair")
        let decoded = try JSONDecoder().decode(
            LocalAIBenchmarkRunReceipt.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.score.failedTaskIDs, ["repair"])
    }

    func testRunReceiptRejectsTamperedPersistedAggregate() throws {
        let original = try receipt(suite: makeSuite(), failedTaskID: "repair")
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var score = try XCTUnwrap(object["score"] as? [String: Any])
        score["weightedSuccess"] = 0.125
        object["score"] = score
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(
            LocalAIBenchmarkRunReceipt.self, from: tampered
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .invalidPersistedReceipt)
        }
    }

    func testDecodedScoreRejectsImpossiblePersistedMetrics() throws {
        let malformed = #"{"suiteID":"general-agent","suiteVersion":1,"weightedSuccess":1.25,"completedCoverage":1,"requiredTasksPassed":true,"requiredCategoryCoverage":true,"isComplete":true,"categoryScores":[],"passedTaskIDs":["route"],"failedTaskIDs":[],"notRunTaskIDs":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(
            LocalAIBenchmarkScore.self, from: Data(malformed.utf8)
        )) { error in
            XCTAssertEqual(error as? LocalAIBenchmarkError, .invalidPersistedScore)
        }
    }

    private func makeSuite() throws -> LocalAIBenchmarkSuite {
        try LocalAIBenchmarkSuite(
            id: "general-agent", version: 1,
            requiredCategories: [.intentRouting, .structuredToolUse,
                                 .codeRepair, .continuationRecovery],
            tasks: [
                makeTask(id: "route", category: .intentRouting, digest: digestA),
                makeTask(id: "tool", category: .structuredToolUse, digest: digestB),
                makeTask(id: "repair", category: .codeRepair, digest: digestC),
                makeTask(id: "continue", category: .continuationRecovery, digest: digestD),
            ]
        )
    }

    private func makeTask(id: String, category: LocalAIBenchmarkCategory,
                          digest: String) -> LocalAIBenchmarkTask {
        .init(id: id, revision: 1, category: category,
              weight: 1, isRequired: true, fixtureDigest: digest)
    }

    private func observation(id: String, outcome: LocalAIBenchmarkOutcome,
                             digest: String?) -> LocalAIBenchmarkObservation {
        .init(taskID: id, taskRevision: 1, outcome: outcome,
              evidenceDigest: outcome == .notRun ? nil : digest)
    }

    private func receipt(suite: LocalAIBenchmarkSuite,
                         failedTaskID: String?) throws -> LocalAIBenchmarkRunReceipt {
        let evidence = [digestA, digestB, digestC, digestD]
        return try LocalAIBenchmarkRunReceipt(
            suite: suite,
            observations: suite.tasks.enumerated().map { index, task in
                .init(taskID: task.id, taskRevision: task.revision,
                      outcome: task.id == failedTaskID ? .failed : .passed,
                      evidenceDigest: evidence[index % evidence.count])
            }
        )
    }

    private func score(suite: LocalAIBenchmarkSuite,
                       failedTaskID: String?) throws -> LocalAIBenchmarkScore {
        let evidence = [digestA, digestB, digestC, digestD]
        return try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite,
            observations: suite.tasks.enumerated().map { index, task in
                .init(taskID: task.id, taskRevision: task.revision,
                      outcome: task.id == failedTaskID ? .failed : .passed,
                      evidenceDigest: evidence[index % evidence.count])
            }
        )
    }
}
