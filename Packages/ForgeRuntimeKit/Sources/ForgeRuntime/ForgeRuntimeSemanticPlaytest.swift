import Foundation

/// Host-driven playtest personas. These are test intents, not permissions granted to project code.
public enum ForgeRuntimePlaytestPersona: String, Codable, CaseIterable, Sendable {
    case goalRunner
    case explorer
    case chaosTester
    case newPlayer
    case persistenceTester
    case visualReviewer
    case performanceRunner
    case accessibilityRunner
}

/// Semantic controls the host may inject into a supported generated runtime during an authorized playtest.
public enum ForgeRuntimeSemanticControl: String, Codable, CaseIterable, Sendable {
    case move
    case look
    case primaryAction
    case secondaryAction
    case jump
    case brake
    case interact
    case pause
    case restart
    case menu
}

public enum ForgeRuntimeMenuAction: String, Codable, CaseIterable, Sendable {
    case up
    case down
    case left
    case right
    case confirm
    case cancel
}

public enum ForgeRuntimePlaytestValidationError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidVector
    case invalidAmount
    case invalidPayload(control: ForgeRuntimeSemanticControl)
    case unsupportedProtocolVersion(Int)
    case tooManyFrames(actual: Int, maximum: Int)
    case invalidFrameLimit(Int)
    case invalidSequence(expected: UInt64, actual: UInt64)
    case virtualTimeMovedBackward(previous: UInt64, actual: UInt64)
    case contextMismatch(field: String)
    case controlNotGranted(ForgeRuntimeSemanticControl)
    case missingEvidenceForPass
    case invalidEvidenceIdentifier
}

public struct ForgeRuntimeSemanticVector2: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (-1.0 ... 1.0).contains(x), (-1.0 ... 1.0).contains(y) else {
            throw ForgeRuntimePlaytestValidationError.invalidVector
        }
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        try self.init(x: x, y: y)
    }
}

/// One deterministic semantic input frame. Payload shape is validated per control and revalidated on decode.
public struct ForgeRuntimeSemanticInputFrame: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let sequence: UInt64
    public let virtualTimeMilliseconds: UInt64
    public let control: ForgeRuntimeSemanticControl
    public let vector: ForgeRuntimeSemanticVector2?
    public let amount: Double?
    public let isPressed: Bool?
    public let menuAction: ForgeRuntimeMenuAction?

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        sequence: UInt64,
        virtualTimeMilliseconds: UInt64,
        control: ForgeRuntimeSemanticControl,
        vector: ForgeRuntimeSemanticVector2? = nil,
        amount: Double? = nil,
        isPressed: Bool? = nil,
        menuAction: ForgeRuntimeMenuAction? = nil
    ) throws {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw ForgeRuntimePlaytestValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        try Self.validatePayload(
            control: control,
            vector: vector,
            amount: amount,
            isPressed: isPressed,
            menuAction: menuAction
        )

        self.protocolVersion = protocolVersion
        self.sequence = sequence
        self.virtualTimeMilliseconds = virtualTimeMilliseconds
        self.control = control
        self.vector = vector
        self.amount = amount
        self.isPressed = isPressed
        self.menuAction = menuAction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: container.decode(Int.self, forKey: .protocolVersion),
            sequence: container.decode(UInt64.self, forKey: .sequence),
            virtualTimeMilliseconds: container.decode(UInt64.self, forKey: .virtualTimeMilliseconds),
            control: container.decode(ForgeRuntimeSemanticControl.self, forKey: .control),
            vector: container.decodeIfPresent(ForgeRuntimeSemanticVector2.self, forKey: .vector),
            amount: container.decodeIfPresent(Double.self, forKey: .amount),
            isPressed: container.decodeIfPresent(Bool.self, forKey: .isPressed),
            menuAction: container.decodeIfPresent(ForgeRuntimeMenuAction.self, forKey: .menuAction)
        )
    }

    private static func validatePayload(
        control: ForgeRuntimeSemanticControl,
        vector: ForgeRuntimeSemanticVector2?,
        amount: Double?,
        isPressed: Bool?,
        menuAction: ForgeRuntimeMenuAction?
    ) throws {
        switch control {
        case .move, .look:
            guard vector != nil, amount == nil, isPressed == nil, menuAction == nil else {
                throw ForgeRuntimePlaytestValidationError.invalidPayload(control: control)
            }
        case .brake:
            guard vector == nil, isPressed == nil, menuAction == nil, let amount,
                  amount.isFinite, (0.0 ... 1.0).contains(amount) else {
                if let amount, (!amount.isFinite || !(0.0 ... 1.0).contains(amount)) {
                    throw ForgeRuntimePlaytestValidationError.invalidAmount
                }
                throw ForgeRuntimePlaytestValidationError.invalidPayload(control: control)
            }
        case .primaryAction, .secondaryAction, .jump, .interact, .pause, .restart:
            guard vector == nil, amount == nil, isPressed != nil, menuAction == nil else {
                throw ForgeRuntimePlaytestValidationError.invalidPayload(control: control)
            }
        case .menu:
            guard vector == nil, amount == nil, isPressed == nil, menuAction != nil else {
                throw ForgeRuntimePlaytestValidationError.invalidPayload(control: control)
            }
        }
    }
}

/// Identity carried by every trace so replay/evidence cannot silently cross project revisions or runtime sessions.
public struct ForgeRuntimePlaytestTraceHeader: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let traceID: String
    public let projectID: String
    public let projectRevisionID: String
    public let runtimeSessionID: String
    public let journeyID: String
    public let persona: ForgeRuntimePlaytestPersona
    public let deterministicSeed: UInt64

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        traceID: String,
        projectID: String,
        projectRevisionID: String,
        runtimeSessionID: String,
        journeyID: String,
        persona: ForgeRuntimePlaytestPersona,
        deterministicSeed: UInt64
    ) throws {
        guard protocolVersion == Self.currentProtocolVersion else {
            throw ForgeRuntimePlaytestValidationError.unsupportedProtocolVersion(protocolVersion)
        }
        try Self.validateIdentifier(traceID, field: "traceID")
        try Self.validateIdentifier(projectID, field: "projectID")
        try Self.validateIdentifier(projectRevisionID, field: "projectRevisionID")
        try Self.validateIdentifier(runtimeSessionID, field: "runtimeSessionID")
        try Self.validateIdentifier(journeyID, field: "journeyID")

        self.protocolVersion = protocolVersion
        self.traceID = traceID
        self.projectID = projectID
        self.projectRevisionID = projectRevisionID
        self.runtimeSessionID = runtimeSessionID
        self.journeyID = journeyID
        self.persona = persona
        self.deterministicSeed = deterministicSeed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: container.decode(Int.self, forKey: .protocolVersion),
            traceID: container.decode(String.self, forKey: .traceID),
            projectID: container.decode(String.self, forKey: .projectID),
            projectRevisionID: container.decode(String.self, forKey: .projectRevisionID),
            runtimeSessionID: container.decode(String.self, forKey: .runtimeSessionID),
            journeyID: container.decode(String.self, forKey: .journeyID),
            persona: container.decode(ForgeRuntimePlaytestPersona.self, forKey: .persona),
            deterministicSeed: container.decode(UInt64.self, forKey: .deterministicSeed)
        )
    }

    static func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            throw ForgeRuntimePlaytestValidationError.invalidIdentifier(field: field)
        }
        let valid = value.unicodeScalars.allSatisfy { scalar in
            let isUpper = scalar.value >= 65 && scalar.value <= 90
            let isLower = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            return isUpper || isLower || isDigit || scalar == "-" || scalar == "_" || scalar == "." || scalar == ":"
        }
        guard valid else {
            throw ForgeRuntimePlaytestValidationError.invalidIdentifier(field: field)
        }
    }
}

public struct ForgeRuntimePlaytestTrace: Codable, Equatable, Sendable {
    public static let defaultMaximumFrames = 20_000

    public let header: ForgeRuntimePlaytestTraceHeader
    public let frames: [ForgeRuntimeSemanticInputFrame]

    public init(
        header: ForgeRuntimePlaytestTraceHeader,
        frames: [ForgeRuntimeSemanticInputFrame],
        maximumFrames: Int = Self.defaultMaximumFrames
    ) throws {
        guard frames.count <= maximumFrames else {
            throw ForgeRuntimePlaytestValidationError.tooManyFrames(actual: frames.count, maximum: maximumFrames)
        }

        var previousVirtualTime: UInt64 = 0
        for (index, frame) in frames.enumerated() {
            let expected = UInt64(index)
            guard frame.sequence == expected else {
                throw ForgeRuntimePlaytestValidationError.invalidSequence(expected: expected, actual: frame.sequence)
            }
            if index > 0, frame.virtualTimeMilliseconds < previousVirtualTime {
                throw ForgeRuntimePlaytestValidationError.virtualTimeMovedBackward(
                    previous: previousVirtualTime,
                    actual: frame.virtualTimeMilliseconds
                )
            }
            previousVirtualTime = frame.virtualTimeMilliseconds
        }

        self.header = header
        self.frames = frames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            header: container.decode(ForgeRuntimePlaytestTraceHeader.self, forKey: .header),
            frames: container.decode([ForgeRuntimeSemanticInputFrame].self, forKey: .frames)
        )
    }
}

/// Host-owned ceiling for an autonomous playtest. A generated project cannot widen this grant by changing its own manifest.
public struct ForgeRuntimePlaytestInputGrant: Codable, Equatable, Sendable {
    public let projectID: String
    public let projectRevisionID: String
    public let runtimeSessionID: String
    public let allowedControls: Set<ForgeRuntimeSemanticControl>
    public let maximumFrames: Int

    public init(
        projectID: String,
        projectRevisionID: String,
        runtimeSessionID: String,
        allowedControls: Set<ForgeRuntimeSemanticControl>,
        maximumFrames: Int = ForgeRuntimePlaytestTrace.defaultMaximumFrames
    ) throws {
        try ForgeRuntimePlaytestTraceHeader.validateIdentifier(projectID, field: "projectID")
        try ForgeRuntimePlaytestTraceHeader.validateIdentifier(projectRevisionID, field: "projectRevisionID")
        try ForgeRuntimePlaytestTraceHeader.validateIdentifier(runtimeSessionID, field: "runtimeSessionID")
        guard maximumFrames >= 0 else {
            throw ForgeRuntimePlaytestValidationError.invalidFrameLimit(maximumFrames)
        }
        self.projectID = projectID
        self.projectRevisionID = projectRevisionID
        self.runtimeSessionID = runtimeSessionID
        self.allowedControls = allowedControls
        self.maximumFrames = maximumFrames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            projectRevisionID: container.decode(String.self, forKey: .projectRevisionID),
            runtimeSessionID: container.decode(String.self, forKey: .runtimeSessionID),
            allowedControls: container.decode(Set<ForgeRuntimeSemanticControl>.self, forKey: .allowedControls),
            maximumFrames: container.decode(Int.self, forKey: .maximumFrames)
        )
    }

    public func authorize(_ trace: ForgeRuntimePlaytestTrace) throws {
        guard trace.header.projectID == projectID else {
            throw ForgeRuntimePlaytestValidationError.contextMismatch(field: "projectID")
        }
        guard trace.header.projectRevisionID == projectRevisionID else {
            throw ForgeRuntimePlaytestValidationError.contextMismatch(field: "projectRevisionID")
        }
        guard trace.header.runtimeSessionID == runtimeSessionID else {
            throw ForgeRuntimePlaytestValidationError.contextMismatch(field: "runtimeSessionID")
        }
        guard trace.frames.count <= maximumFrames else {
            throw ForgeRuntimePlaytestValidationError.tooManyFrames(actual: trace.frames.count, maximum: maximumFrames)
        }
        if let denied = trace.frames.first(where: { !allowedControls.contains($0.control) }) {
            throw ForgeRuntimePlaytestValidationError.controlNotGranted(denied.control)
        }
    }
}

public enum ForgeRuntimePlaytestEvidenceKind: String, Codable, CaseIterable, Sendable {
    case runtimeEvent
    case stateMilestone
    case screenshot
    case saveReloadReceipt
    case performanceSample
    case accessibilityObservation
}

public struct ForgeRuntimePlaytestEvidenceReference: Codable, Equatable, Sendable {
    public let kind: ForgeRuntimePlaytestEvidenceKind
    public let evidenceID: String

    public init(kind: ForgeRuntimePlaytestEvidenceKind, evidenceID: String) throws {
        do {
            try ForgeRuntimePlaytestTraceHeader.validateIdentifier(evidenceID, field: "evidenceID")
        } catch {
            throw ForgeRuntimePlaytestValidationError.invalidEvidenceIdentifier
        }
        self.kind = kind
        self.evidenceID = evidenceID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ForgeRuntimePlaytestEvidenceKind.self, forKey: .kind),
            evidenceID: container.decode(String.self, forKey: .evidenceID)
        )
    }
}

/// Outcome of one playtest journey. `passed` means the journey passed its own checks, not that the mission is complete.
public struct ForgeRuntimePlaytestReceipt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        case passed
        case failed
        case blocked
        case crashed
        case cancelled
    }

    public let traceID: String
    public let projectID: String
    public let projectRevisionID: String
    public let runtimeSessionID: String
    public let journeyID: String
    public let outcome: Outcome
    public let evidence: [ForgeRuntimePlaytestEvidenceReference]

    public init(
        traceHeader: ForgeRuntimePlaytestTraceHeader,
        outcome: Outcome,
        evidence: [ForgeRuntimePlaytestEvidenceReference]
    ) throws {
        if outcome == .passed, evidence.isEmpty {
            throw ForgeRuntimePlaytestValidationError.missingEvidenceForPass
        }
        self.traceID = traceHeader.traceID
        self.projectID = traceHeader.projectID
        self.projectRevisionID = traceHeader.projectRevisionID
        self.runtimeSessionID = traceHeader.runtimeSessionID
        self.journeyID = traceHeader.journeyID
        self.outcome = outcome
        self.evidence = evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let traceHeader = try ForgeRuntimePlaytestTraceHeader(
            traceID: container.decode(String.self, forKey: .traceID),
            projectID: container.decode(String.self, forKey: .projectID),
            projectRevisionID: container.decode(String.self, forKey: .projectRevisionID),
            runtimeSessionID: container.decode(String.self, forKey: .runtimeSessionID),
            journeyID: container.decode(String.self, forKey: .journeyID),
            persona: .goalRunner,
            deterministicSeed: 0
        )
        try self.init(
            traceHeader: traceHeader,
            outcome: container.decode(Outcome.self, forKey: .outcome),
            evidence: container.decode([ForgeRuntimePlaytestEvidenceReference].self, forKey: .evidence)
        )
    }
}
