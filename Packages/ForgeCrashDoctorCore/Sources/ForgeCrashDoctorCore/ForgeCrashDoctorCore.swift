import Foundation

public enum ForgeCrashValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case blankField(String)
    case fieldTooLong(field: String, maximum: Int)
    case invalidPositiveInteger(field: String)
    case invalidControlCharacter(field: String)
    case tooManyStackFrames(Int)
    case tooManyConsoleEntries(Int)
    case tooManyRecentActions(Int)
    case tooManyRepairAttempts(Int)
    case nonMonotonicSequence(field: String)
    case invalidArtifactIdentity
    case invalidControlIdentity
    case invalidRepeatKey
    case repairSubjectMismatch
}

private enum ForgeCrashLimits {
    static let identifier = 160
    static let message = 2_000
    static let symbol = 320
    static let file = 1_024
    static let consoleMessage = 2_000
    static let actionIntent = 320
    static let repeatFallbackMessage = 240
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

    static func optional(_ value: String?, field: String, maximum: Int) throws -> String? {
        guard let value else { return nil }
        return try required(value, field: field, maximum: maximum)
    }

    static func identity(_ value: String, field: String, maximum: Int) throws -> String {
        let normalized = try required(value, field: field, maximum: maximum)
        guard normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw ForgeCrashValidationError.invalidControlCharacter(field: field)
        }
        return normalized
    }

    static func optionalIdentity(_ value: String?, field: String, maximum: Int) throws -> String? {
        guard let value else { return nil }
        return try identity(value, field: field, maximum: maximum)
    }

    static func monotonic(_ values: [Int], field: String) throws {
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: field)
        }
        for pair in zip(values, values.dropFirst()) where pair.1 <= pair.0 {
            throw ForgeCrashValidationError.nonMonotonicSequence(field: field)
        }
    }

    static func canonicalDigestIdentity(_ value: String, error: ForgeCrashValidationError) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = Set("0123456789abcdef")
        guard normalized.count == 64, normalized.allSatisfy(allowed.contains) else {
            throw error
        }
        return normalized
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
        self.file = try ForgeCrashLimits.identity(file, field: "source.file", maximum: ForgeCrashLimits.file)
        if let line, line <= 0 {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "source.line")
        }
        if let column, column <= 0 {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "source.column")
        }
        self.line = line
        self.column = column
        self.symbol = try ForgeCrashLimits.optionalIdentity(symbol, field: "source.symbol", maximum: ForgeCrashLimits.symbol)
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
        self.symbol = try ForgeCrashLimits.identity(symbol, field: "stack.symbol", maximum: ForgeCrashLimits.symbol)
        self.file = try ForgeCrashLimits.optionalIdentity(file, field: "stack.file", maximum: ForgeCrashLimits.file)
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
        self.source = try ForgeCrashLimits.optionalIdentity(source, field: "console.source", maximum: ForgeCrashLimits.file)
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
        self.actionID = try ForgeCrashLimits.identity(actionID, field: "action.id", maximum: ForgeCrashLimits.identifier)
        self.intent = try ForgeCrashLimits.required(intent, field: "action.intent", maximum: ForgeCrashLimits.actionIntent)
        self.targetID = try ForgeCrashLimits.optionalIdentity(targetID, field: "action.target", maximum: ForgeCrashLimits.identifier)
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
        self.incidentID = try ForgeCrashLimits.identity(incidentID, field: "incident.id", maximum: ForgeCrashLimits.identifier)
        self.projectID = try ForgeCrashLimits.identity(projectID, field: "project.id", maximum: ForgeCrashLimits.identifier)
        self.checkpointID = try ForgeCrashLimits.identity(checkpointID, field: "checkpoint.id", maximum: ForgeCrashLimits.identifier)
        self.projectRevision = try ForgeCrashLimits.identity(projectRevision, field: "project.revision", maximum: ForgeCrashLimits.identifier)
        self.runtimeVersion = try ForgeCrashLimits.identity(runtimeVersion, field: "runtime.version", maximum: ForgeCrashLimits.identifier)
        self.runtimeSessionID = try ForgeCrashLimits.identity(runtimeSessionID, field: "runtime.session", maximum: ForgeCrashLimits.identifier)
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
/// A runtime adapter inside this module must validate a real capture artifact before constructing it.
public struct ForgeCrashTrustedIncident: Hashable, Sendable {
    private let authenticatedIncident: ForgeCrashIncident
    public let artifactIdentity: String

    init(authenticatedIncident: ForgeCrashIncident, artifactIdentity: String) throws {
        self.authenticatedIncident = authenticatedIncident
        self.artifactIdentity = try ForgeCrashLimits.canonicalDigestIdentity(
            artifactIdentity,
            error: .invalidArtifactIdentity
        )
    }

    public var incident: ForgeCrashIncident { authenticatedIncident }

    public func matches(_ candidate: ForgeCrashIncident) -> Bool {
        authenticatedIncident == candidate
    }
}

/// Exact runtime subject used to scope durable repair failures. A failure from another checkpoint,
/// project revision, runtime version, or runtime session cannot consume this subject's retry budget.
public struct ForgeCrashRepairSubject: Codable, Hashable, Sendable {
    public let projectID: String
    public let checkpointID: String
    public let projectRevision: String
    public let runtimeVersion: String
    public let runtimeSessionID: String

    public init(
        projectID: String,
        checkpointID: String,
        projectRevision: String,
        runtimeVersion: String,
        runtimeSessionID: String
    ) throws {
        self.projectID = try ForgeCrashLimits.identity(projectID, field: "repair.project", maximum: ForgeCrashLimits.identifier)
        self.checkpointID = try ForgeCrashLimits.identity(checkpointID, field: "repair.checkpoint", maximum: ForgeCrashLimits.identifier)
        self.projectRevision = try ForgeCrashLimits.identity(projectRevision, field: "repair.projectRevision", maximum: ForgeCrashLimits.identifier)
        self.runtimeVersion = try ForgeCrashLimits.identity(runtimeVersion, field: "repair.runtimeVersion", maximum: ForgeCrashLimits.identifier)
        self.runtimeSessionID = try ForgeCrashLimits.identity(runtimeSessionID, field: "repair.runtimeSession", maximum: ForgeCrashLimits.identifier)
    }

    public init(incident: ForgeCrashIncident) throws {
        try self.init(
            projectID: incident.projectID,
            checkpointID: incident.checkpointID,
            projectRevision: incident.projectRevision,
            runtimeVersion: incident.runtimeVersion,
            runtimeSessionID: incident.runtimeSessionID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case projectID, checkpointID, projectRevision, runtimeVersion, runtimeSessionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            checkpointID: container.decode(String.self, forKey: .checkpointID),
            projectRevision: container.decode(String.self, forKey: .projectRevision),
            runtimeVersion: container.decode(String.self, forKey: .runtimeVersion),
            runtimeSessionID: container.decode(String.self, forKey: .runtimeSessionID)
        )
    }
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
        let sourceFile = try ForgeCrashLimits.optionalIdentity(sourceFile, field: "repeat.sourceFile", maximum: ForgeCrashLimits.file)
        if let sourceLine, sourceLine <= 0 {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "repeat.sourceLine")
        }
        let topStackSymbol = try ForgeCrashLimits.optionalIdentity(
            topStackSymbol,
            field: "repeat.topStackSymbol",
            maximum: ForgeCrashLimits.symbol
        )
        let fallbackMessage = try ForgeCrashLimits.optional(
            fallbackMessage,
            field: "repeat.fallbackMessage",
            maximum: ForgeCrashLimits.repeatFallbackMessage
        )
        let hasStructuralLocation = sourceFile != nil || sourceLine != nil || topStackSymbol != nil
        guard hasStructuralLocation != (fallbackMessage != nil) else {
            throw ForgeCrashValidationError.invalidRepeatKey
        }

        self.kind = kind
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
        self.topStackSymbol = topStackSymbol
        self.fallbackMessage = fallbackMessage
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
        let withoutControls = String(
            message.unicodeScalars.map { scalar in
                CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
            }
        )
        let collapsed = withoutControls
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(ForgeCrashLimits.repeatFallbackMessage))
    }

    private enum CodingKeys: String, CodingKey {
        case kind, sourceFile, sourceLine, topStackSymbol, fallbackMessage
    }

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

/// Durable candidate record of a repair attempt that did not earn acceptance.
/// There is intentionally no `passed`/`resolved` case: success belongs to the owning verification/completion authority.
public struct ForgeCrashRepairAttempt: Codable, Hashable, Sendable {
    public let sequence: Int
    public let subject: ForgeCrashRepairSubject
    public let incidentID: String
    public let repeatKey: ForgeCrashRepeatKey
    public let failureKind: ForgeCrashRepairFailureKind

    public init(
        sequence: Int,
        subject: ForgeCrashRepairSubject,
        incidentID: String,
        repeatKey: ForgeCrashRepeatKey,
        failureKind: ForgeCrashRepairFailureKind
    ) throws {
        guard sequence > 0 else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "repair.sequence")
        }
        self.sequence = sequence
        self.subject = subject
        self.incidentID = try ForgeCrashLimits.identity(incidentID, field: "repair.incident", maximum: ForgeCrashLimits.identifier)
        self.repeatKey = repeatKey
        self.failureKind = failureKind
    }

    private enum CodingKeys: String, CodingKey { case sequence, subject, incidentID, repeatKey, failureKind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(Int.self, forKey: .sequence),
            subject: container.decode(ForgeCrashRepairSubject.self, forKey: .subject),
            incidentID: container.decode(String.self, forKey: .incidentID),
            repeatKey: container.decode(ForgeCrashRepeatKey.self, forKey: .repeatKey),
            failureKind: container.decode(ForgeCrashRepairFailureKind.self, forKey: .failureKind)
        )
    }
}

/// Ordered durable candidate history. It is deliberately Codable/public for persistence, but it is not
/// triage authority. A package-owned trusted repair-control value must authenticate the complete history.
public struct ForgeCrashRepairHistory: Codable, Hashable, Sendable {
    public let subject: ForgeCrashRepairSubject
    public let attempts: [ForgeCrashRepairAttempt]

    public init(subject: ForgeCrashRepairSubject, attempts: [ForgeCrashRepairAttempt] = []) throws {
        guard attempts.count <= ForgeCrashLimits.repairAttempts else {
            throw ForgeCrashValidationError.tooManyRepairAttempts(attempts.count)
        }
        try ForgeCrashLimits.monotonic(attempts.map(\.sequence), field: "repair.sequence")
        guard attempts.allSatisfy({ $0.subject == subject }) else {
            throw ForgeCrashValidationError.repairSubjectMismatch
        }
        self.subject = subject
        self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey { case subject, attempts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            subject: container.decode(ForgeCrashRepairSubject.self, forKey: .subject),
            attempts: container.decode([ForgeCrashRepairAttempt].self, forKey: .attempts)
        )
    }
}

/// Persistable candidate retry envelope. Public construction cannot authorize a live Crash Doctor decision.
/// The total ceiling is capped to the durable history capacity so a policy can always reach its blocker state.
public struct ForgeCrashRetryPolicy: Codable, Hashable, Sendable {
    public static let maximumDurableFailures = ForgeCrashLimits.repairAttempts

    public let maximumFocusedFailuresPerRepeatKey: Int
    public let maximumTotalFailuresBeforeBlocker: Int

    public init(
        maximumFocusedFailuresPerRepeatKey: Int = 2,
        maximumTotalFailuresBeforeBlocker: Int = 6
    ) throws {
        guard maximumFocusedFailuresPerRepeatKey > 0,
              maximumFocusedFailuresPerRepeatKey <= ForgeCrashRetryPolicy.maximumDurableFailures else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "policy.focusedFailures")
        }
        guard maximumTotalFailuresBeforeBlocker >= maximumFocusedFailuresPerRepeatKey,
              maximumTotalFailuresBeforeBlocker <= ForgeCrashRetryPolicy.maximumDurableFailures else {
            throw ForgeCrashValidationError.invalidPositiveInteger(field: "policy.totalFailures")
        }
        self.maximumFocusedFailuresPerRepeatKey = maximumFocusedFailuresPerRepeatKey
        self.maximumTotalFailuresBeforeBlocker = maximumTotalFailuresBeforeBlocker
    }

    private enum CodingKeys: String, CodingKey {
        case maximumFocusedFailuresPerRepeatKey, maximumTotalFailuresBeforeBlocker
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maximumFocusedFailuresPerRepeatKey: container.decode(Int.self, forKey: .maximumFocusedFailuresPerRepeatKey),
            maximumTotalFailuresBeforeBlocker: container.decode(Int.self, forKey: .maximumTotalFailuresBeforeBlocker)
        )
    }
}

/// Non-Codable package-owned authorization for one exact runtime repair subject. Persisted/model-authored
/// history and retry policy remain candidate data until a canonical host adapter authenticates the complete
/// history + policy subject and constructs this value inside ForgeCrashDoctorCore.
public struct ForgeCrashTrustedRepairControl: Hashable, Sendable {
    public let subject: ForgeCrashRepairSubject
    public let controlIdentity: String
    private let authenticatedHistory: ForgeCrashRepairHistory
    private let authenticatedPolicy: ForgeCrashRetryPolicy

    init(
        trustedIncident: ForgeCrashTrustedIncident,
        authenticatedHistory: ForgeCrashRepairHistory,
        authenticatedPolicy: ForgeCrashRetryPolicy,
        controlIdentity: String
    ) throws {
        let subject = try ForgeCrashRepairSubject(incident: trustedIncident.incident)
        guard authenticatedHistory.subject == subject else {
            throw ForgeCrashValidationError.repairSubjectMismatch
        }
        self.subject = subject
        self.controlIdentity = try ForgeCrashLimits.canonicalDigestIdentity(
            controlIdentity,
            error: .invalidControlIdentity
        )
        self.authenticatedHistory = authenticatedHistory
        self.authenticatedPolicy = authenticatedPolicy
    }

    func matches(_ trustedIncident: ForgeCrashTrustedIncident) -> Bool {
        (try? ForgeCrashRepairSubject(incident: trustedIncident.incident)) == subject
    }

    var history: ForgeCrashRepairHistory { authenticatedHistory }
    var policy: ForgeCrashRetryPolicy { authenticatedPolicy }
}

public enum ForgeCrashNextAction: Hashable, Sendable {
    case focusedRepair(attemptNumber: Int)
    case rootCauseAnalysis(repeatedFailures: Int)
    case surfaceBlocker(totalFailures: Int)
}

/// Non-Codable bounded repair submission. It can only be minted by package-authoritative triage from
/// a trusted runtime incident plus a trusted repair-control subject.
public struct ForgeCrashRepairSubmission: Hashable, Sendable {
    public let trustedIncident: ForgeCrashTrustedIncident
    public let repeatKey: ForgeCrashRepeatKey
    public let nextAction: ForgeCrashNextAction
    public let controlIdentity: String

    init(
        trustedIncident: ForgeCrashTrustedIncident,
        repeatKey: ForgeCrashRepeatKey,
        nextAction: ForgeCrashNextAction,
        controlIdentity: String
    ) {
        self.trustedIncident = trustedIncident
        self.repeatKey = repeatKey
        self.nextAction = nextAction
        self.controlIdentity = controlIdentity
    }
}

public enum ForgeCrashTriage {
    /// Authoritative triage remains module-internal until the canonical Runtime/Crash Doctor adapter
    /// authenticates the complete current repair-control subject. External imports cannot combine a real
    /// trusted incident with caller-shaped history/policy to mint a repair submission.
    static func makeSubmission(
        for trustedIncident: ForgeCrashTrustedIncident,
        control: ForgeCrashTrustedRepairControl
    ) throws -> ForgeCrashRepairSubmission {
        guard control.matches(trustedIncident) else {
            throw ForgeCrashValidationError.repairSubjectMismatch
        }
        let failedHistory = control.history
        let policy = control.policy
        let repeatKey = ForgeCrashRepeatKey.derive(from: trustedIncident.incident)
        let totalFailures = failedHistory.attempts.count
        let repeatedFailures = failedHistory.attempts.lazy.filter { $0.repeatKey == repeatKey }.count

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
            nextAction: nextAction,
            controlIdentity: control.controlIdentity
        )
    }
}
