import Foundation

public enum ForgeCrashValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case blankField(String)
    case fieldTooLong(field: String, maximum: Int)
    case invalidPositiveInteger(field: String)
    case invalidIdentity(field: String)
    case tooManyStackFrames(Int)
    case tooManyConsoleEntries(Int)
    case tooManyRecentActions(Int)
    case tooManyRepairAttempts(Int)
    case nonMonotonicSequence(field: String)
    case invalidArtifactIdentity
    case repairScopeMismatch
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
    static let repairAttempts = 128

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

    static func identity(_ value: String, field: String) throws -> String {
        let normalized = try required(value, field: field, maximum: identifier)
        guard normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              normalized.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ForgeCrashValidationError.invalidIdentity(field: field)
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
        if let line, line <= 0 { throw ForgeCrashValidationError.invalidPositiveInteger(field: "source.line") }
        if let column, column <= 0 { throw ForgeCrashValidationError.invalidPositiveInteger(field: "source.column") }
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
        if let line, line <= 0 { throw ForgeCrashValidationError.invalidPositiveInteger(field: "stack.line") }
        if let column, column <= 0 { throw ForgeCrashValidationError.invalidPositiveInteger(field: "stack.column") }
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
        guard sequence >= 0 else { throw ForgeCrashValidationError.invalidPositiveInteger(field: "console.sequence") }
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
        guard sequence >= 0 else { throw ForgeCrashValidationError.invalidPositiveInteger(field: "action.sequence") }
        self.sequence = sequence
        self.actionID = try ForgeCrashLimits.identity(actionID, field: "action.id")
        self.intent = try ForgeCrashLimits.required(intent, field: "action.intent", maximum: ForgeCrashLimits.actionIntent)
        self.targetID = try targetID.map { try ForgeCrashLimits.identity($0, field: "action.target") }
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

/// Durable crash metadata. Codable incident bytes are candidate evidence only.
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
        guard schemaVersion == ForgeCrashIncident.currentSchemaVersion else { throw ForgeCrashValidationError.unsupportedSchema(schemaVersion) }
        guard stackFrames.count <= ForgeCrashLimits.stackFrames else { throw ForgeCrashValidationError.tooManyStackFrames(stackFrames.count) }
        guard consoleEntries.count <= ForgeCrashLimits.consoleEntries else { throw ForgeCrashValidationError.tooManyConsoleEntries(consoleEntries.count) }
        guard recentActions.count <= ForgeCrashLimits.recentActions else { throw ForgeCrashValidationError.tooManyRecentActions(recentActions.count) }
        try ForgeCrashLimits.monotonic(consoleEntries.map(\.sequence), field: "console.sequence")
        try ForgeCrashLimits.monotonic(recentActions.map(\.sequence), field: "action.sequence")

        self.schemaVersion = schemaVersion
        self.incidentID = try ForgeCrashLimits.identity(incidentID, field: "incident.id")
        self.projectID = try ForgeCrashLimits.identity(projectID, field: "project.id")
        self.checkpointID = try ForgeCrashLimits.identity(checkpointID, field: "checkpoint.id")
        self.projectRevision = try ForgeCrashLimits.identity(projectRevision, field: "project.revision")
        self.runtimeVersion = try ForgeCrashLimits.identity(runtimeVersion, field: "runtime.version")
        self.runtimeSessionID = try ForgeCrashLimits.identity(runtimeSessionID, field: "runtime.session")
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

/// Non-Codable host-authenticated incident authority. Construction stays module-internal.
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
    public func matches(_ candidate: ForgeCrashIncident) -> Bool { authenticatedIncident == candidate }
}

public struct ForgeCrashRepeatKey: Codable, Hashable, Sendable {
    public let kind: ForgeCrashIncidentKind
    public let sourceFile: String?
    public let sourceLine: Int?
    public let topStackSymbol: String?
    public let fallbackMessage: String?

    private init(
        kind: ForgeCrashIncidentKind,
        sourceFile: String?,
        sourceLine: Int?,
        topStackSymbol: String?,
        fallbackMessage: String?
    ) throws {
        if let sourceLine, sourceLine <= 0 {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "repeat.sourceLine")
        }
        self.kind = kind
        self.sourceFile = try ForgeCrashLimits.optional(sourceFile, field: "repeat.sourceFile", maximum: ForgeCrashLimits.file)
        self.sourceLine = sourceLine
        self.topStackSymbol = try ForgeCrashLimits.optional(topStackSymbol, field: "repeat.topStackSymbol", maximum: ForgeCrashLimits.symbol)
        self.fallbackMessage = try ForgeCrashLimits.optional(fallbackMessage, field: "repeat.fallbackMessage", maximum: 240)
    }

    public static func derive(from incident: ForgeCrashIncident) -> ForgeCrashRepeatKey {
        let topFrame = incident.stackFrames.first
        let sourceFile = incident.sourceLocation?.file ?? topFrame?.file
        let sourceLine = incident.sourceLocation?.line ?? topFrame?.line
        let topStackSymbol = incident.sourceLocation?.symbol ?? topFrame?.symbol
        let hasStructuralLocation = sourceFile != nil || sourceLine != nil || topStackSymbol != nil
        return try! ForgeCrashRepeatKey(
            kind: incident.kind,
            sourceFile: sourceFile,
            sourceLine: sourceLine,
            topStackSymbol: topStackSymbol,
            fallbackMessage: hasStructuralLocation ? nil : normalizeFallbackMessage(incident.message)
        )
    }

    private static func normalizeFallbackMessage(_ message: String) -> String {
        let collapsed = message.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(240))
    }

    private enum CodingKeys: String, CodingKey { case kind, sourceFile, sourceLine, topStackSymbol, fallbackMessage }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ForgeCrashIncidentKind.self, forKey: .kind),
            sourceFile: container.decodeIfPresent(String.self, forKey: .sourceFile),
            sourceLine: container.decodeIfPresent(Int.self, forKey: .sourceLine),
            topStackSymbol: container.decodeIfPresent(String.self, forKey: .topStackSymbol),
            fallbackMessage: container.decodeIfPresent(String.self, forKey: .fallbackMessage)
        )
    }
}

public enum ForgeCrashRepairFailureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case sameCrashReturned
    case focusedVerificationFailed
    case verificationInterrupted
}

/// Durable candidate record only. It cannot control privileged triage directly.
public struct ForgeCrashRepairAttempt: Codable, Hashable, Sendable {
    public let sequence: Int
    public let incidentID: String
    public let repeatKey: ForgeCrashRepeatKey
    public let failureKind: ForgeCrashRepairFailureKind

    public init(sequence: Int, incidentID: String, repeatKey: ForgeCrashRepeatKey, failureKind: ForgeCrashRepairFailureKind) throws {
        guard sequence > 0 else { throw ForgeCrashValidationError.invalidPositiveInteger(field: "repair.sequence") }
        self.sequence = sequence
        self.incidentID = try ForgeCrashLimits.identity(incidentID, field: "repair.incident")
        self.repeatKey = repeatKey
        self.failureKind = failureKind
    }

    private enum CodingKeys: String, CodingKey { case sequence, incidentID, repeatKey, failureKind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(Int.self, forKey: .sequence),
            incidentID: container.decode(String.self, forKey: .incidentID),
            repeatKey: container.decode(ForgeCrashRepeatKey.self, forKey: .repeatKey),
            failureKind: container.decode(ForgeCrashRepairFailureKind.self, forKey: .failureKind)
        )
    }
}

/// Durable candidate history. It remains transport/state only and cannot mint the next autonomous action.
public struct ForgeCrashRepairHistory: Codable, Hashable, Sendable {
    public let attempts: [ForgeCrashRepairAttempt]

    public init(attempts: [ForgeCrashRepairAttempt] = []) throws {
        guard attempts.count <= ForgeCrashLimits.repairAttempts else { throw ForgeCrashValidationError.tooManyRepairAttempts(attempts.count) }
        try ForgeCrashLimits.monotonic(attempts.map(\.sequence), field: "repair.sequence")
        self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey { case attempts }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(attempts: container.decode([ForgeCrashRepairAttempt].self, forKey: .attempts))
    }
}

/// Candidate retry policy. Only a module-owned trusted wrapper may drive privileged triage.
public struct ForgeCrashRetryPolicy: Codable, Hashable, Sendable {
    public let maximumFocusedFailuresPerRepeatKey: Int
    public let maximumTotalFailuresBeforeBlocker: Int

    public init(maximumFocusedFailuresPerRepeatKey: Int = 2, maximumTotalFailuresBeforeBlocker: Int = 6) throws {
        guard maximumFocusedFailuresPerRepeatKey > 0 else { throw ForgeCrashValidationError.invalidPositiveInteger(field: "policy.focusedFailures") }
        guard maximumTotalFailuresBeforeBlocker >= maximumFocusedFailuresPerRepeatKey,
              maximumTotalFailuresBeforeBlocker <= ForgeCrashLimits.repairAttempts else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "policy.totalFailures")
        }
        self.maximumFocusedFailuresPerRepeatKey = maximumFocusedFailuresPerRepeatKey
        self.maximumTotalFailuresBeforeBlocker = maximumTotalFailuresBeforeBlocker
    }

    private enum CodingKeys: String, CodingKey { case maximumFocusedFailuresPerRepeatKey, maximumTotalFailuresBeforeBlocker }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumFocusedFailuresPerRepeatKey: container.decode(Int.self, forKey: .maximumFocusedFailuresPerRepeatKey),
            maximumTotalFailuresBeforeBlocker: container.decode(Int.self, forKey: .maximumTotalFailuresBeforeBlocker)
        )
    }
}

/// Host-owned policy trust. A public/Codable policy can never obtain this authority itself.
public struct ForgeCrashTrustedRetryPolicy: Hashable, Sendable {
    private let authenticatedPolicy: ForgeCrashRetryPolicy
    public let policyRevision: String

    init(authenticatedPolicy: ForgeCrashRetryPolicy, policyRevision: String) throws {
        self.authenticatedPolicy = authenticatedPolicy
        self.policyRevision = try ForgeCrashLimits.identity(policyRevision, field: "policy.revision")
    }

    public var policy: ForgeCrashRetryPolicy { authenticatedPolicy }
}

/// Authenticated failed repair attempt. Repeat identity is always re-derived from the trusted incident.
public struct ForgeCrashTrustedFailedAttempt: Hashable, Sendable {
    public let sequence: Int
    public let trustedIncident: ForgeCrashTrustedIncident
    public let failureKind: ForgeCrashRepairFailureKind

    init(sequence: Int, trustedIncident: ForgeCrashTrustedIncident, failureKind: ForgeCrashRepairFailureKind) throws {
        guard sequence > 0 else { throw ForgeCrashValidationError.invalidPositiveInteger(field: "trustedRepair.sequence") }
        self.sequence = sequence
        self.trustedIncident = trustedIncident
        self.failureKind = failureKind
    }

    public var repeatKey: ForgeCrashRepeatKey { ForgeCrashRepeatKey.derive(from: trustedIncident.incident) }
}

/// Exact repair epoch identity. Runtime session is intentionally excluded: a relaunch in the same exact
/// project/checkpoint/revision/runtime keeps consuming the same bounded retry budget instead of resetting it.
public struct ForgeCrashRepairScope: Hashable, Sendable {
    public let projectID: String
    public let checkpointID: String
    public let projectRevision: String
    public let runtimeVersion: String

    init(incident: ForgeCrashIncident) {
        projectID = incident.projectID
        checkpointID = incident.checkpointID
        projectRevision = incident.projectRevision
        runtimeVersion = incident.runtimeVersion
    }

    func matches(_ incident: ForgeCrashIncident) -> Bool {
        projectID == incident.projectID
            && checkpointID == incident.checkpointID
            && projectRevision == incident.projectRevision
            && runtimeVersion == incident.runtimeVersion
    }
}

/// Non-Codable host-owned repair control. Candidate history and policy bytes never mint this subject.
public struct ForgeCrashTrustedRepairControl: Hashable, Sendable {
    public let scope: ForgeCrashRepairScope
    public let failedAttempts: [ForgeCrashTrustedFailedAttempt]
    public let trustedPolicy: ForgeCrashTrustedRetryPolicy

    init(
        currentIncident: ForgeCrashTrustedIncident,
        failedAttempts: [ForgeCrashTrustedFailedAttempt],
        trustedPolicy: ForgeCrashTrustedRetryPolicy
    ) throws {
        guard failedAttempts.count <= ForgeCrashLimits.repairAttempts else {
            throw ForgeCrashValidationError.tooManyRepairAttempts(failedAttempts.count)
        }
        try ForgeCrashLimits.monotonic(failedAttempts.map(\.sequence), field: "trustedRepair.sequence")
        let scope = ForgeCrashRepairScope(incident: currentIncident.incident)
        guard failedAttempts.allSatisfy({ scope.matches($0.trustedIncident.incident) }) else {
            throw ForgeCrashValidationError.repairScopeMismatch
        }
        self.scope = scope
        self.failedAttempts = failedAttempts
        self.trustedPolicy = trustedPolicy
    }
}

public enum ForgeCrashNextAction: Hashable, Sendable {
    case focusedRepair(attemptNumber: Int)
    case rootCauseAnalysis(repeatedFailures: Int)
    case surfaceBlocker(totalFailures: Int)
}

public struct ForgeCrashRepairSubmission: Hashable, Sendable {
    public let trustedIncident: ForgeCrashTrustedIncident
    public let repeatKey: ForgeCrashRepeatKey
    public let nextAction: ForgeCrashNextAction
}

/// Privileged triage is module-internal. A canonical Runtime/Mission adapter must authenticate both crash
/// evidence and repair-control truth before this can drive Full Forge.
public enum ForgeCrashTriage {
    static func makeSubmission(
        for trustedIncident: ForgeCrashTrustedIncident,
        trustedControl: ForgeCrashTrustedRepairControl
    ) throws -> ForgeCrashRepairSubmission {
        guard trustedControl.scope.matches(trustedIncident.incident) else {
            throw ForgeCrashValidationError.repairScopeMismatch
        }
        let repeatKey = ForgeCrashRepeatKey.derive(from: trustedIncident.incident)
        let totalFailures = trustedControl.failedAttempts.count
        let repeatedFailures = trustedControl.failedAttempts.lazy.filter { $0.repeatKey == repeatKey }.count
        let policy = trustedControl.trustedPolicy.policy

        let nextAction: ForgeCrashNextAction
        if totalFailures >= policy.maximumTotalFailuresBeforeBlocker {
            nextAction = .surfaceBlocker(totalFailures: totalFailures)
        } else if repeatedFailures >= policy.maximumFocusedFailuresPerRepeatKey {
            nextAction = .rootCauseAnalysis(repeatedFailures: repeatedFailures)
        } else {
            nextAction = .focusedRepair(attemptNumber: repeatedFailures + 1)
        }

        return ForgeCrashRepairSubmission(trustedIncident: trustedIncident, repeatKey: repeatKey, nextAction: nextAction)
    }
}
