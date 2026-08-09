import Foundation

public enum ForgeAccessibilityEvidenceAuthority: String, Codable, CaseIterable, Sendable {
    case hostRuntimeHarness
    case xctestHarness
}

public enum ForgeAccessibilityCheckOutcome: String, Codable, CaseIterable, Sendable {
    case passed
    case failed
    case inconclusive
}

public struct ForgeAccessibilityCheckResult: Codable, Equatable, Sendable {
    public let kind: ForgeAccessibilityCheckKind
    public let outcome: ForgeAccessibilityCheckOutcome
    public let inspectedElementCount: Int
    public let failureCount: Int
    public let note: String?

    public init(
        kind: ForgeAccessibilityCheckKind,
        outcome: ForgeAccessibilityCheckOutcome,
        inspectedElementCount: Int,
        failureCount: Int,
        note: String? = nil
    ) throws {
        guard (0...100_000).contains(inspectedElementCount),
              (0...100_000).contains(failureCount),
              failureCount <= inspectedElementCount else {
            throw ForgeAccessibilityError.invalidCheckResult(kind.rawValue)
        }

        let normalizedNote: String?
        if let note {
            normalizedNote = try ForgeAccessibilityValidation.text(
                note,
                field: "check.note",
                maximumLength: 4_096
            )
        } else {
            normalizedNote = nil
        }

        switch outcome {
        case .passed:
            guard inspectedElementCount > 0, failureCount == 0 else {
                throw ForgeAccessibilityError.invalidCheckResult(kind.rawValue)
            }
        case .failed:
            guard inspectedElementCount > 0, failureCount > 0 else {
                throw ForgeAccessibilityError.invalidCheckResult(kind.rawValue)
            }
        case .inconclusive:
            guard failureCount == 0, normalizedNote != nil else {
                throw ForgeAccessibilityError.invalidCheckResult(kind.rawValue)
            }
        }

        self.kind = kind
        self.outcome = outcome
        self.inspectedElementCount = inspectedElementCount
        self.failureCount = failureCount
        self.note = normalizedNote
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case outcome
        case inspectedElementCount
        case failureCount
        case note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ForgeAccessibilityCheckKind.self, forKey: .kind),
            outcome: container.decode(ForgeAccessibilityCheckOutcome.self, forKey: .outcome),
            inspectedElementCount: container.decode(Int.self, forKey: .inspectedElementCount),
            failureCount: container.decode(Int.self, forKey: .failureCount),
            note: container.decodeIfPresent(String.self, forKey: .note)
        )
    }
}

/// Producer evidence is structurally validated, but the `authority` field cannot authorize itself.
/// Acceptance separately requires `producerReceiptID` to be present in the caller's host-trusted set.
public struct ForgeAccessibilityRunEvidence: Codable, Equatable, Sendable {
    public static let maximumCheckResults = 32

    public let runID: String
    public let target: ForgeAccessibilityTarget
    public let executionContext: ForgeAccessibilityExecutionContext
    public let scenarioID: String
    public let authority: ForgeAccessibilityEvidenceAuthority
    public let producerReceiptID: String
    public let checkResults: [ForgeAccessibilityCheckResult]

    public init(
        runID: String,
        target: ForgeAccessibilityTarget,
        executionContext: ForgeAccessibilityExecutionContext,
        scenarioID: String,
        authority: ForgeAccessibilityEvidenceAuthority,
        producerReceiptID: String,
        checkResults: [ForgeAccessibilityCheckResult]
    ) throws {
        self.runID = try ForgeAccessibilityValidation.identifier(
            runID,
            field: "run.runID",
            maximumLength: 256
        )
        self.target = target
        self.executionContext = executionContext
        self.scenarioID = try ForgeAccessibilityValidation.identifier(
            scenarioID,
            field: "run.scenarioID",
            maximumLength: 256
        )
        self.authority = authority
        self.producerReceiptID = try ForgeAccessibilityValidation.identifier(
            producerReceiptID,
            field: "run.producerReceiptID",
            maximumLength: 512
        )
        guard !checkResults.isEmpty else {
            throw ForgeAccessibilityError.invalidCheckResult("run:\(self.runID):checkResults")
        }
        try ForgeAccessibilityValidation.maximumCount(
            checkResults.count,
            field: "run.checkResults",
            maximum: Self.maximumCheckResults
        )

        var seen = Set<ForgeAccessibilityCheckKind>()
        for result in checkResults {
            guard seen.insert(result.kind).inserted else {
                throw ForgeAccessibilityError.duplicateCheckKind(runID: self.runID, check: result.kind)
            }
        }
        self.checkResults = checkResults.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private enum CodingKeys: String, CodingKey {
        case runID
        case target
        case executionContext
        case scenarioID
        case authority
        case producerReceiptID
        case checkResults
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            runID: container.decode(String.self, forKey: .runID),
            target: container.decode(ForgeAccessibilityTarget.self, forKey: .target),
            executionContext: container.decode(ForgeAccessibilityExecutionContext.self, forKey: .executionContext),
            scenarioID: container.decode(String.self, forKey: .scenarioID),
            authority: container.decode(ForgeAccessibilityEvidenceAuthority.self, forKey: .authority),
            producerReceiptID: container.decode(String.self, forKey: .producerReceiptID),
            checkResults: container.decode([ForgeAccessibilityCheckResult].self, forKey: .checkResults)
        )
    }
}

/// Exact host-trust binding for one producer receipt. This is intentionally non-Codable:
/// callers must rebuild trusted bindings from the current host authority rather than restoring
/// a serialized "trusted" bit.
public struct ForgeAccessibilityTrustedProducerReceipt: Equatable, Hashable, Sendable {
    public let runID: String
    public let target: ForgeAccessibilityTarget
    public let executionContext: ForgeAccessibilityExecutionContext
    public let scenarioID: String
    public let authority: ForgeAccessibilityEvidenceAuthority
    public let producerReceiptID: String

    public init(
        runID: String,
        target: ForgeAccessibilityTarget,
        executionContext: ForgeAccessibilityExecutionContext,
        scenarioID: String,
        authority: ForgeAccessibilityEvidenceAuthority,
        producerReceiptID: String
    ) throws {
        self.runID = try ForgeAccessibilityValidation.identifier(
            runID,
            field: "trustedReceipt.runID",
            maximumLength: 256
        )
        self.target = target
        self.executionContext = executionContext
        self.scenarioID = try ForgeAccessibilityValidation.identifier(
            scenarioID,
            field: "trustedReceipt.scenarioID",
            maximumLength: 256
        )
        self.authority = authority
        self.producerReceiptID = try ForgeAccessibilityValidation.identifier(
            producerReceiptID,
            field: "trustedReceipt.producerReceiptID",
            maximumLength: 512
        )
    }

    func exactlyMatches(_ run: ForgeAccessibilityRunEvidence) -> Bool {
        runID == run.runID
            && target == run.target
            && executionContext == run.executionContext
            && scenarioID == run.scenarioID
            && authority == run.authority
            && producerReceiptID == run.producerReceiptID
    }
}
