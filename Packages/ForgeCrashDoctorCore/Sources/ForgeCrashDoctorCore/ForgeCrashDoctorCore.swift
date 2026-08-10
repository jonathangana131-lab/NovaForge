import Foundation

public enum ForgeCrashValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case blankField(String)
    case fieldTooLong(field: String, maximum: Int)
    case invalidPositiveInteger(field: String)
    case tooManyStackFrames(Int)
    case tooManyConsoleEntries(Int)
    case tooManyRecentActions(Int)
    case nonMonotonicSequence(field: String)
    case invalidArtifactIdentity
}

private enum ForgeCrashLimits {
    static let identifier = 160
    static let message = 2_000
    static let symbol = 320
    static let file = 1_024
    static let consoleMessage = 2_000
    static let actionIntent = 320
    static let stackFrames = 64
    static let consoleEntries = 100
    static let recentActions = 32

    static func required(_ value: String, field: String, maximum: Int) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ForgeCrashValidationError.blankField(field)
        }
        guard normalized.count <= maximum else {
            throw ForgeCrashValidationError.fieldTooLong(field: field, maximum: maximum)
        }
        return normalized
    }

    static func optional(_ value: String?, field: String, maximum: Int) throws -> String? {
        guard let value else { return nil }
        return try required(value, field: field, maximum: maximum)
    }

    static func monotonic(_ values: [Int], field: String) throws {
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: field)
        }
        for pair in zip(values, values.dropFirst()) where pair.1 <= pair.0 {
            throw ForgeCrashValidationError.nonMonotonicSequence(field: field)
        }
    }
}

public enum ForgeCrashIncidentKind: String, Codable, CaseIterable, Hashable, Sendable {
    case runtimeException
    case unhandledPromiseRejection
    case fatalScriptError
    case contentProcessTermination
    case resourceLoadFailure
}

public struct ForgeCrashSourceLocation: Codable, Hashable, Sendable {
    public let file: String
    public let line: Int?
    public let column: Int?
    public let symbol: String?

    public init(file: String, line: Int? = nil, column: Int? = nil, symbol: String? = nil) throws {
        self.file = try ForgeCrashLimits.required(file, field: "source.file", maximum: ForgeCrashLimits.file)
        if let line, line <= 0 {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "source.line")
        }
        if let column, column <= 0 {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "source.column")
        }
        self.line = line
        self.column = column
        self.symbol = try ForgeCrashLimits.optional(symbol, field: "source.symbol", maximum: ForgeCrashLimits.symbol)
    }

    private enum CodingKeys: String, CodingKey { case file, line, column, symbol }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            file: container.decode(String.self, forKey: .file),
            line: container.decodeIfPresent(Int.self, forKey: .line),
            column: container.decodeIfPresent(Int.self, forKey: .column),
            symbol: container.decodeIfPresent(String.self, forKey: .symbol)
        )
    }
}

public struct ForgeCrashStackFrame: Codable, Hashable, Sendable {
    public let symbol: String
    public let file: String?
    public let line: Int?
    public let column: Int?

    public init(symbol: String, file: String? = nil, line: Int? = nil, column: Int? = nil) throws {
        self.symbol = try ForgeCrashLimits.required(symbol, field: "stack.symbol", maximum: ForgeCrashLimits.symbol)
        self.file = try ForgeCrashLimits.optional(file, field: "stack.file", maximum: ForgeCrashLimits.file)
        if let line, line <= 0 {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "stack.line")
        }
        if let column, column <= 0 {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "stack.column")
        }
        self.line = line
        self.column = column
    }

    private enum CodingKeys: String, CodingKey { case symbol, file, line, column }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            symbol: container.decode(String.self, forKey: .symbol),
            file: container.decodeIfPresent(String.self, forKey: .file),
            line: container.decodeIfPresent(Int.self, forKey: .line),
            column: container.decodeIfPresent(Int.self, forKey: .column)
        )
    }
}

public enum ForgeCrashConsoleLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct ForgeCrashConsoleEntry: Codable, Hashable, Sendable {
    public let sequence: Int
    public let level: ForgeCrashConsoleLevel
    public let message: String
    public let source: String?

    public init(sequence: Int, level: ForgeCrashConsoleLevel, message: String, source: String? = nil) throws {
        guard sequence >= 0 else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "console.sequence")
        }
        self.sequence = sequence
        self.level = level
        self.message = try ForgeCrashLimits.required(message, field: "console.message", maximum: ForgeCrashLimits.consoleMessage)
        self.source = try ForgeCrashLimits.optional(source, field: "console.source", maximum: ForgeCrashLimits.file)
    }

    private enum CodingKeys: String, CodingKey { case sequence, level, message, source }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(Int.self, forKey: .sequence),
            level: container.decode(ForgeCrashConsoleLevel.self, forKey: .level),
            message: container.decode(String.self, forKey: .message),
            source: container.decodeIfPresent(String.self, forKey: .source)
        )
    }
}

public struct ForgeCrashSemanticAction: Codable, Hashable, Sendable {
    public let sequence: Int
    public let actionID: String
    public let intent: String
    public let targetID: String?

    public init(sequence: Int, actionID: String, intent: String, targetID: String? = nil) throws {
        guard sequence >= 0 else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "action.sequence")
        }
        self.sequence = sequence
        self.actionID = try ForgeCrashLimits.required(actionID, field: "action.id", maximum: ForgeCrashLimits.identifier)
        self.intent = try ForgeCrashLimits.required(intent, field: "action.intent", maximum: ForgeCrashLimits.actionIntent)
        self.targetID = try ForgeCrashLimits.optional(targetID, field: "action.target", maximum: ForgeCrashLimits.identifier)
    }

    private enum CodingKeys: String, CodingKey { case sequence, actionID, intent, targetID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(Int.self, forKey: .sequence),
            actionID: container.decode(String.self, forKey: .actionID),
            intent: container.decode(String.self, forKey: .intent),
            targetID: container.decodeIfPresent(String.self, forKey: .targetID)
        )
    }
}

/// Durable crash metadata. This value is intentionally Codable because incidents must survive relaunch.
/// Codable incident bytes are candidate evidence only; they do not prove that a trusted runtime captured them.
public struct ForgeCrashIncident: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let incidentID: String
    public let projectID: String
    public let checkpointID: String
    public let projectRevision: String
    public let runtimeVersion: String
    public let runtimeSessionID: String
    public let occurredAt: Date
    public let kind: ForgeCrashIncidentKind
    public let message: String
    public let sourceLocation: ForgeCrashSourceLocation?
    public let stackFrames: [ForgeCrashStackFrame]
    public let consoleEntries: [ForgeCrashConsoleEntry]
    public let recentActions: [ForgeCrashSemanticAction]

    public init(
        schemaVersion: Int = ForgeCrashIncident.currentSchemaVersion,
        incidentID: String,
        projectID: String,
        checkpointID: String,
        projectRevision: String,
        runtimeVersion: String,
        runtimeSessionID: String,
        occurredAt: Date,
        kind: ForgeCrashIncidentKind,
        message: String,
        sourceLocation: ForgeCrashSourceLocation? = nil,
        stackFrames: [ForgeCrashStackFrame] = [],
        consoleEntries: [ForgeCrashConsoleEntry] = [],
        recentActions: [ForgeCrashSemanticAction] = []
    ) throws {
        guard schemaVersion == ForgeCrashIncident.currentSchemaVersion else {
            throw ForgeCrashValidationError.unsupportedSchema(schemaVersion)
        }
        guard stackFrames.count <= ForgeCrashLimits.stackFrames else {
            throw ForgeCrashValidationError.tooManyStackFrames(stackFrames.count)
        }
        guard consoleEntries.count <= ForgeCrashLimits.consoleEntries else {
            throw ForgeCrashValidationError.tooManyConsoleEntries(consoleEntries.count)
        }
        guard recentActions.count <= ForgeCrashLimits.recentActions else {
            throw ForgeCrashValidationError.tooManyRecentActions(recentActions.count)
        }
        try ForgeCrashLimits.monotonic(consoleEntries.map(\.sequence), field: "console.sequence")
        try ForgeCrashLimits.monotonic(recentActions.map(\.sequence), field: "action.sequence")

        self.schemaVersion = schemaVersion
        self.incidentID = try ForgeCrashLimits.required(incidentID, field: "incident.id", maximum: ForgeCrashLimits.identifier)
        self.projectID = try ForgeCrashLimits.required(projectID, field: "project.id", maximum: ForgeCrashLimits.identifier)
        self.checkpointID = try ForgeCrashLimits.required(checkpointID, field: "checkpoint.id", maximum: ForgeCrashLimits.identifier)
        self.projectRevision = try ForgeCrashLimits.required(projectRevision, field: "project.revision", maximum: ForgeCrashLimits.identifier)
        self.runtimeVersion = try ForgeCrashLimits.required(runtimeVersion, field: "runtime.version", maximum: ForgeCrashLimits.identifier)
        self.runtimeSessionID = try ForgeCrashLimits.required(runtimeSessionID, field: "runtime.session", maximum: ForgeCrashLimits.identifier)
        self.occurredAt = occurredAt
        self.kind = kind
        self.message = try ForgeCrashLimits.required(message, field: "incident.message", maximum: ForgeCrashLimits.message)
        self.sourceLocation = sourceLocation
        self.stackFrames = stackFrames
        self.consoleEntries = consoleEntries
        self.recentActions = recentActions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, incidentID, projectID, checkpointID, projectRevision
        case runtimeVersion, runtimeSessionID, occurredAt, kind, message, sourceLocation
        case stackFrames, consoleEntries, recentActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            incidentID: container.decode(String.self, forKey: .incidentID),
            projectID: container.decode(String.self, forKey: .projectID),
            checkpointID: container.decode(String.self, forKey: .checkpointID),
            projectRevision: container.decode(String.self, forKey: .projectRevision),
            runtimeVersion: container.decode(String.self, forKey: .runtimeVersion),
            runtimeSessionID: container.decode(String.self, forKey: .runtimeSessionID),
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            kind: container.decode(ForgeCrashIncidentKind.self, forKey: .kind),
            message: container.decode(String.self, forKey: .message),
            sourceLocation: container.decodeIfPresent(ForgeCrashSourceLocation.self, forKey: .sourceLocation),
            stackFrames: container.decode([ForgeCrashStackFrame].self, forKey: .stackFrames),
            consoleEntries: container.decode([ForgeCrashConsoleEntry].self, forKey: .consoleEntries),
            recentActions: container.decode([ForgeCrashSemanticAction].self, forKey: .recentActions)
        )
    }
}

/// Non-Codable host-authenticated authority. Persisted/model-authored incident metadata cannot mint this type.
/// A runtime adapter inside this module must eventually validate a real capture artifact before constructing it.
public struct ForgeCrashTrustedIncident: Hashable, Sendable {
    private let authenticatedIncident: ForgeCrashIncident
    public let artifactIdentity: String

    init(authenticatedIncident: ForgeCrashIncident, artifactIdentity: String) throws {
        let normalized = artifactIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set("0123456789abcdef")
        guard normalized.count == 64, normalized.allSatisfy(allowed.contains) else {
            throw ForgeCrashValidationError.invalidArtifactIdentity
        }
        self.authenticatedIncident = authenticatedIncident
        self.artifactIdentity = normalized
    }

    public var incident: ForgeCrashIncident { authenticatedIncident }

    public func matches(_ candidate: ForgeCrashIncident) -> Bool {
        authenticatedIncident == candidate
    }
}

public struct ForgeCrashRepeatKey: Codable, Hashable, Sendable {
    public let kind: ForgeCrashIncidentKind
    public let sourceFile: String?
    public let sourceLine: Int?
    public let topStackSymbol: String?
    public let fallbackMessage: String?

    public static func derive(from incident: ForgeCrashIncident) -> ForgeCrashRepeatKey {
        let topFrame = incident.stackFrames.first
        let sourceFile = incident.sourceLocation?.file ?? topFrame?.file
        let sourceLine = incident.sourceLocation?.line ?? topFrame?.line
        let topStackSymbol = incident.sourceLocation?.symbol ?? topFrame?.symbol
        let hasStructuralLocation = sourceFile != nil || sourceLine != nil || topStackSymbol != nil

        return ForgeCrashRepeatKey(
            kind: incident.kind,
            sourceFile: sourceFile?.lowercased(),
            sourceLine: sourceLine,
            topStackSymbol: topStackSymbol?.lowercased(),
            fallbackMessage: hasStructuralLocation ? nil : normalizeFallbackMessage(incident.message)
        )
    }

    private static func normalizeFallbackMessage(_ message: String) -> String {
        let collapsed = message
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(240))
    }
}

public enum ForgeCrashRepairFailureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sameCrashReturned
    case focusedVerificationFailed
    case verificationInterrupted
}

/// Durable record of a repair attempt that did not earn acceptance.
/// There is intentionally no `passed`/`resolved` case: success belongs to the owning verification/completion authority.
public struct ForgeCrashRepairAttempt: Codable, Hashable, Sendable {
    public let sequence: Int
    public let incidentID: String
    public let repeatKey: ForgeCrashRepeatKey
    public let failureKind: ForgeCrashRepairFailureKind

    public init(
        sequence: Int,
        incidentID: String,
        repeatKey: ForgeCrashRepeatKey,
        failureKind: ForgeCrashRepairFailureKind
    ) throws {
        guard sequence > 0 else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "repair.sequence")
        }
        self.sequence = sequence
        self.incidentID = try ForgeCrashLimits.required(incidentID, field: "repair.incident", maximum: ForgeCrashLimits.identifier)
        self.repeatKey = repeatKey
        self.failureKind = failureKind
    }
}

public struct ForgeCrashRetryPolicy: Codable, Hashable, Sendable {
    public let maximumFocusedFailuresPerRepeatKey: Int
    public let maximumTotalFailuresBeforeBlocker: Int

    public init(
        maximumFocusedFailuresPerRepeatKey: Int = 2,
        maximumTotalFailuresBeforeBlocker: Int = 6
    ) throws {
        guard maximumFocusedFailuresPerRepeatKey > 0 else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "policy.focusedFailures")
        }
        guard maximumTotalFailuresBeforeBlocker >= maximumFocusedFailuresPerRepeatKey else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "policy.totalFailures")
        }
        self.maximumFocusedFailuresPerRepeatKey = maximumFocusedFailuresPerRepeatKey
        self.maximumTotalFailuresBeforeBlocker = maximumTotalFailuresBeforeBlocker
    }
}

public enum ForgeCrashNextAction: Hashable, Sendable {
    case focusedRepair(attemptNumber: Int)
    case rootCauseAnalysis(repeatedFailures: Int)
    case surfaceBlocker(totalFailures: Int)
}

/// Non-Codable bounded repair submission. It retains the trusted runtime incident so a model cannot
/// detach a repair request from the runtime evidence that caused it.
public struct ForgeCrashRepairSubmission: Hashable, Sendable {
    public let trustedIncident: ForgeCrashTrustedIncident
    public let repeatKey: ForgeCrashRepeatKey
    public let nextAction: ForgeCrashNextAction
}

public enum ForgeCrashTriage {
    public static func makeSubmission(
        for trustedIncident: ForgeCrashTrustedIncident,
        failedAttempts: [ForgeCrashRepairAttempt],
        policy: ForgeCrashRetryPolicy
    ) -> ForgeCrashRepairSubmission {
        let repeatKey = ForgeCrashRepeatKey.derive(from: trustedIncident.incident)
        let totalFailures = failedAttempts.count
        let repeatedFailures = failedAttempts.lazy.filter { $0.repeatKey == repeatKey }.count

        let nextAction: ForgeCrashNextAction
        if totalFailures >= policy.maximumTotalFailuresBeforeBlocker {
            nextAction = .surfaceBlocker(totalFailures: totalFailures)
        } else if repeatedFailures >= policy.maximumFocusedFailuresPerRepeatKey {
            nextAction = .rootCauseAnalysis(repeatedFailures: repeatedFailures)
        } else {
            nextAction = .focusedRepair(attemptNumber: repeatedFailures + 1)
        }

        return ForgeCrashRepairSubmission(
            trustedIncident: trustedIncident,
            repeatKey: repeatKey,
            nextAction: nextAction
        )
    }
}
