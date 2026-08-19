import Foundation

public enum LocalAIBenchmarkCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case intentRouting, structuredExtraction, structuredToolUse, repositoryNavigation
    case codeRepair, multiFileChange, contextCompaction, continuationRecovery
}

public struct LocalAIBenchmarkTask: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let revision: Int
    public let category: LocalAIBenchmarkCategory
    public let weight: Double
    public let isRequired: Bool
    /// SHA-256 of the exact prompt/files/expected-output fixture assembled by the harness.
    public let fixtureDigest: String

    public init(id: String, revision: Int, category: LocalAIBenchmarkCategory,
                weight: Double = 1, isRequired: Bool = true, fixtureDigest: String) {
        self.id = id
        self.revision = revision
        self.category = category
        self.weight = weight
        self.isRequired = isRequired
        self.fixtureDigest = fixtureDigest
    }
}

/// Versioned suite identity. This describes evaluation semantics only; model,
/// runtime, device, thermal, memory, and energy identity belong to qualification.
public struct LocalAIBenchmarkSuite: Codable, Equatable, Sendable {
    public let id: String
    public let version: Int
    public let requiredCategories: Set<LocalAIBenchmarkCategory>
    public let tasks: [LocalAIBenchmarkTask]

    public init(id: String, version: Int,
                requiredCategories: Set<LocalAIBenchmarkCategory>,
                tasks: [LocalAIBenchmarkTask]) throws {
        try Self.validate(id: id, version: version,
                          requiredCategories: requiredCategories, tasks: tasks)
        self.id = id
        self.version = version
        self.requiredCategories = requiredCategories
        self.tasks = tasks
    }

    private enum CodingKeys: String, CodingKey { case id, version, requiredCategories, tasks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            version: c.decode(Int.self, forKey: .version),
            requiredCategories: c.decode(Set<LocalAIBenchmarkCategory>.self, forKey: .requiredCategories),
            tasks: c.decode([LocalAIBenchmarkTask].self, forKey: .tasks)
        )
    }

    private static func validate(id: String, version: Int,
                                 requiredCategories: Set<LocalAIBenchmarkCategory>,
                                 tasks: [LocalAIBenchmarkTask]) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIBenchmarkError.invalidSuiteID
        }
        guard version > 0 else { throw LocalAIBenchmarkError.invalidSuiteVersion }
        guard !tasks.isEmpty else { throw LocalAIBenchmarkError.emptySuite }
        guard !requiredCategories.isEmpty else { throw LocalAIBenchmarkError.missingRequiredCategories }

        var ids = Set<String>()
        for task in tasks {
            guard !task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalAIBenchmarkError.invalidTaskID
            }
            guard ids.insert(task.id).inserted else { throw LocalAIBenchmarkError.duplicateTaskID(task.id) }
            guard task.revision > 0 else { throw LocalAIBenchmarkError.invalidTaskRevision(task.id) }
            guard task.weight.isFinite, task.weight > 0 else { throw LocalAIBenchmarkError.invalidTaskWeight(task.id) }
            guard Digest.isSHA256(task.fixtureDigest) else { throw LocalAIBenchmarkError.invalidFixtureDigest(task.id) }
        }

        let categories = Set(tasks.map(\.category))
        for category in requiredCategories where !categories.contains(category) {
            throw LocalAIBenchmarkError.requiredCategoryMissingTask(category)
        }
        for category in requiredCategories where !tasks.contains(where: { $0.category == category && $0.isRequired }) {
            throw LocalAIBenchmarkError.requiredCategoryMissingRequiredTask(category)
        }
    }
}

public enum LocalAIBenchmarkOutcome: String, Codable, Equatable, Sendable {
    case passed, failed, notRun
}

public struct LocalAIBenchmarkObservation: Codable, Equatable, Sendable {
    public let taskID: String
    public let taskRevision: Int
    public let outcome: LocalAIBenchmarkOutcome
    /// Required for pass/fail; forbidden for notRun. This keeps failures as evidence.
    public let evidenceDigest: String?

    public init(taskID: String, taskRevision: Int, outcome: LocalAIBenchmarkOutcome,
                evidenceDigest: String? = nil) {
        self.taskID = taskID
        self.taskRevision = taskRevision
        self.outcome = outcome
        self.evidenceDigest = evidenceDigest
    }
}

public struct LocalAIBenchmarkCategoryScore: Codable, Equatable, Sendable {
    public let category: LocalAIBenchmarkCategory
    public let weightedSuccess: Double
    public let completedCoverage: Double
    public let taskCount: Int

    public init(category: LocalAIBenchmarkCategory, weightedSuccess: Double,
                completedCoverage: Double, taskCount: Int) {
        self.category = category
        self.weightedSuccess = weightedSuccess
        self.completedCoverage = completedCoverage
        self.taskCount = taskCount
    }
}

/// Missing/notRun tasks remain in the denominator so partial runs cannot inflate success.
public struct LocalAIBenchmarkScore: Codable, Equatable, Sendable {
    public let suiteID: String
    public let suiteVersion: Int
    public let weightedSuccess: Double
    public let completedCoverage: Double
    public let requiredTasksPassed: Bool
    public let requiredCategoryCoverage: Bool
    public let isComplete: Bool
    public let categoryScores: [LocalAIBenchmarkCategoryScore]
    public let passedTaskIDs: [String]
    public let failedTaskIDs: [String]
    public let notRunTaskIDs: [String]

    public var eligibleForExactComparison: Bool { isComplete && requiredCategoryCoverage }

    init(suiteID: String, suiteVersion: Int, weightedSuccess: Double,
         completedCoverage: Double, requiredTasksPassed: Bool,
         requiredCategoryCoverage: Bool, isComplete: Bool,
         categoryScores: [LocalAIBenchmarkCategoryScore], passedTaskIDs: [String],
         failedTaskIDs: [String], notRunTaskIDs: [String]) throws {
        try Self.validatePersistedShape(
            suiteID: suiteID, suiteVersion: suiteVersion, weightedSuccess: weightedSuccess,
            completedCoverage: completedCoverage, isComplete: isComplete,
            categoryScores: categoryScores, passedTaskIDs: passedTaskIDs,
            failedTaskIDs: failedTaskIDs, notRunTaskIDs: notRunTaskIDs
        )
        self.suiteID = suiteID
        self.suiteVersion = suiteVersion
        self.weightedSuccess = weightedSuccess
        self.completedCoverage = completedCoverage
        self.requiredTasksPassed = requiredTasksPassed
        self.requiredCategoryCoverage = requiredCategoryCoverage
        self.isComplete = isComplete
        self.categoryScores = categoryScores
        self.passedTaskIDs = passedTaskIDs
        self.failedTaskIDs = failedTaskIDs
        self.notRunTaskIDs = notRunTaskIDs
    }

    private enum CodingKeys: String, CodingKey {
        case suiteID, suiteVersion, weightedSuccess, completedCoverage, requiredTasksPassed
        case requiredCategoryCoverage, isComplete, categoryScores
        case passedTaskIDs, failedTaskIDs, notRunTaskIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            suiteID: c.decode(String.self, forKey: .suiteID),
            suiteVersion: c.decode(Int.self, forKey: .suiteVersion),
            weightedSuccess: c.decode(Double.self, forKey: .weightedSuccess),
            completedCoverage: c.decode(Double.self, forKey: .completedCoverage),
            requiredTasksPassed: c.decode(Bool.self, forKey: .requiredTasksPassed),
            requiredCategoryCoverage: c.decode(Bool.self, forKey: .requiredCategoryCoverage),
            isComplete: c.decode(Bool.self, forKey: .isComplete),
            categoryScores: c.decode([LocalAIBenchmarkCategoryScore].self, forKey: .categoryScores),
            passedTaskIDs: c.decode([String].self, forKey: .passedTaskIDs),
            failedTaskIDs: c.decode([String].self, forKey: .failedTaskIDs),
            notRunTaskIDs: c.decode([String].self, forKey: .notRunTaskIDs)
        )
    }

    private static func validatePersistedShape(
        suiteID: String, suiteVersion: Int, weightedSuccess: Double,
        completedCoverage: Double, isComplete: Bool,
        categoryScores: [LocalAIBenchmarkCategoryScore], passedTaskIDs: [String],
        failedTaskIDs: [String], notRunTaskIDs: [String]
    ) throws {
        guard !suiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              suiteVersion > 0, weightedSuccess.isFinite, (0...1).contains(weightedSuccess),
              completedCoverage.isFinite, (0...1).contains(completedCoverage) else {
            throw LocalAIBenchmarkError.invalidPersistedScore
        }
        var categories = Set<LocalAIBenchmarkCategory>()
        for score in categoryScores {
            guard categories.insert(score.category).inserted,
                  score.weightedSuccess.isFinite, (0...1).contains(score.weightedSuccess),
                  score.completedCoverage.isFinite, (0...1).contains(score.completedCoverage),
                  score.taskCount > 0 else { throw LocalAIBenchmarkError.invalidPersistedScore }
        }
        var ids = Set<String>()
        for taskID in passedTaskIDs + failedTaskIDs + notRunTaskIDs {
            guard !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(taskID).inserted else { throw LocalAIBenchmarkError.invalidPersistedScore }
        }
        if isComplete && (completedCoverage != 1 || !notRunTaskIDs.isEmpty) {
            throw LocalAIBenchmarkError.invalidPersistedScore
        }
    }
}

/// Durable benchmark evidence. Decode recomputes the score from the exact suite
/// and observations so persisted/tampered aggregates cannot become authority.
public struct LocalAIBenchmarkRunReceipt: Codable, Equatable, Sendable {
    public let suite: LocalAIBenchmarkSuite
    public let observations: [LocalAIBenchmarkObservation]
    public let score: LocalAIBenchmarkScore

    public init(suite: LocalAIBenchmarkSuite,
                observations: [LocalAIBenchmarkObservation]) throws {
        self.suite = suite
        self.observations = observations
        self.score = try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite, observations: observations
        )
    }

    private enum CodingKeys: String, CodingKey { case suite, observations, score }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let suite = try c.decode(LocalAIBenchmarkSuite.self, forKey: .suite)
        let observations = try c.decode([LocalAIBenchmarkObservation].self, forKey: .observations)
        let persistedScore = try c.decode(LocalAIBenchmarkScore.self, forKey: .score)
        let recomputed = try LocalAIBenchmarkEvaluator.evaluate(
            suite: suite, observations: observations
        )
        guard persistedScore == recomputed else {
            throw LocalAIBenchmarkError.invalidPersistedReceipt
        }
        self.suite = suite
        self.observations = observations
        self.score = recomputed
    }
}

public struct LocalAIBenchmarkComparison: Codable, Equatable, Sendable {
    public let suiteID: String
    public let suiteVersion: Int
    public let baselineWeightedSuccess: Double
    public let candidateWeightedSuccess: Double
    public let weightedSuccessDelta: Double
}

public enum LocalAIBenchmarkEvaluator {
    public static func evaluate(suite: LocalAIBenchmarkSuite,
                                observations: [LocalAIBenchmarkObservation]) throws -> LocalAIBenchmarkScore {
        let tasksByID = Dictionary(uniqueKeysWithValues: suite.tasks.map { ($0.id, $0) })
        var byID: [String: LocalAIBenchmarkObservation] = [:]
        for observation in observations {
            guard let task = tasksByID[observation.taskID] else { throw LocalAIBenchmarkError.unknownTaskID(observation.taskID) }
            guard byID[observation.taskID] == nil else { throw LocalAIBenchmarkError.duplicateObservation(observation.taskID) }
            guard observation.taskRevision == task.revision else {
                throw LocalAIBenchmarkError.taskRevisionMismatch(taskID: observation.taskID,
                                                                  expected: task.revision,
                                                                  actual: observation.taskRevision)
            }
            switch observation.outcome {
            case .passed, .failed:
                guard let digest = observation.evidenceDigest, Digest.isSHA256(digest) else {
                    throw LocalAIBenchmarkError.missingOrInvalidEvidenceDigest(observation.taskID)
                }
            case .notRun:
                guard observation.evidenceDigest == nil else { throw LocalAIBenchmarkError.notRunCannotCarryEvidence(observation.taskID) }
            }
            byID[observation.taskID] = observation
        }

        let totalWeight = suite.tasks.reduce(0) { $0 + $1.weight }
        var passedWeight = 0.0, completedWeight = 0.0
        var passed: [String] = [], failed: [String] = [], notRun: [String] = []
        for task in suite.tasks {
            switch byID[task.id]?.outcome ?? .notRun {
            case .passed: passedWeight += task.weight; completedWeight += task.weight; passed.append(task.id)
            case .failed: completedWeight += task.weight; failed.append(task.id)
            case .notRun: notRun.append(task.id)
            }
        }

        let categoryScores = LocalAIBenchmarkCategory.allCases.compactMap { category -> LocalAIBenchmarkCategoryScore? in
            let tasks = suite.tasks.filter { $0.category == category }
            guard !tasks.isEmpty else { return nil }
            let weight = tasks.reduce(0) { $0 + $1.weight }
            let success = tasks.reduce(0.0) { $0 + (byID[$1.id]?.outcome == .passed ? $1.weight : 0) }
            let complete = tasks.reduce(0.0) { $0 + ((byID[$1.id]?.outcome ?? .notRun) == .notRun ? 0 : $1.weight) }
            return .init(category: category, weightedSuccess: success / weight,
                         completedCoverage: complete / weight, taskCount: tasks.count)
        }
        let requiredCoverage = suite.requiredCategories.allSatisfy { category in
            categoryScores.first(where: { $0.category == category })?.completedCoverage == 1
        }
        let requiredPassed = suite.tasks.filter(\.isRequired).allSatisfy { byID[$0.id]?.outcome == .passed }
        let complete = byID.count == suite.tasks.count && !byID.values.contains(where: { $0.outcome == .notRun })

        return try LocalAIBenchmarkScore(
            suiteID: suite.id, suiteVersion: suite.version,
            weightedSuccess: passedWeight / totalWeight, completedCoverage: completedWeight / totalWeight,
            requiredTasksPassed: requiredPassed, requiredCategoryCoverage: requiredCoverage,
            isComplete: complete, categoryScores: categoryScores,
            passedTaskIDs: passed, failedTaskIDs: failed, notRunTaskIDs: notRun
        )
    }

    /// Exact-suite comparison only. Full suite equality protects against two
    /// different fixture definitions accidentally reusing the same ID/version.
    /// A positive delta is not a latency/memory/energy claim.
    public static func compare(baseline: LocalAIBenchmarkRunReceipt,
                               candidate: LocalAIBenchmarkRunReceipt) throws -> LocalAIBenchmarkComparison {
        guard baseline.suite.id == candidate.suite.id else { throw LocalAIBenchmarkError.suiteIDMismatch }
        guard baseline.suite.version == candidate.suite.version else { throw LocalAIBenchmarkError.suiteVersionMismatch }
        guard baseline.suite == candidate.suite else { throw LocalAIBenchmarkError.suiteDefinitionMismatch }
        guard baseline.score.eligibleForExactComparison, candidate.score.eligibleForExactComparison else {
            throw LocalAIBenchmarkError.incompleteComparison
        }
        return .init(
            suiteID: baseline.suite.id, suiteVersion: baseline.suite.version,
            baselineWeightedSuccess: baseline.score.weightedSuccess,
            candidateWeightedSuccess: candidate.score.weightedSuccess,
            weightedSuccessDelta: candidate.score.weightedSuccess - baseline.score.weightedSuccess
        )
    }
}

public enum LocalAIBenchmarkReferenceTaxonomy {
    /// Minimum semantic coverage for a general local agent suite; no model is implied to pass it.
    public static let generalAgentRequiredCategories: Set<LocalAIBenchmarkCategory> = [
        .intentRouting, .structuredToolUse, .repositoryNavigation,
        .codeRepair, .contextCompaction, .continuationRecovery,
    ]
}

public enum LocalAIBenchmarkError: Error, Equatable, Sendable {
    case invalidSuiteID, invalidSuiteVersion, emptySuite, missingRequiredCategories, invalidTaskID
    case duplicateTaskID(String), invalidTaskRevision(String), invalidTaskWeight(String), invalidFixtureDigest(String)
    case requiredCategoryMissingTask(LocalAIBenchmarkCategory)
    case requiredCategoryMissingRequiredTask(LocalAIBenchmarkCategory)
    case unknownTaskID(String), duplicateObservation(String)
    case taskRevisionMismatch(taskID: String, expected: Int, actual: Int)
    case missingOrInvalidEvidenceDigest(String), notRunCannotCarryEvidence(String)
    case suiteIDMismatch, suiteVersionMismatch, suiteDefinitionMismatch, incompleteComparison
    case invalidPersistedScore, invalidPersistedReceipt
}

private enum Digest {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}
