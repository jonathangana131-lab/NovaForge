import Foundation

/// Host-owned capability classes for autonomous runtime interaction.
/// Generated project code may expose semantic controls, but it cannot grant these capabilities.
public enum ForgeRuntimeAutomationCapability: String, Codable, CaseIterable, Comparable, Sendable {
    case activateControl = "control.activate"
    case enterText = "text.enter"
    case setActionValue = "action.set-value"
    case performGesture = "gesture.perform"
    case restartRuntime = "runtime.restart"

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ForgeRuntimeAutomationPolicyError: Error, Equatable, Sendable {
    case invalidMaximumTextUTF8Bytes
    case invalidMaximumGestureDurationMilliseconds
    case invalidMaximumInteractions
}

/// Trusted host budget for one bounded semantic automation session.
public struct ForgeRuntimeAutomationPolicy: Equatable, Sendable {
    public static let hardMaximumTextUTF8Bytes = 16 * 1024
    public static let hardMaximumGestureDurationMilliseconds = 30_000
    public static let hardMaximumInteractions = 4_096

    public let allowedCapabilities: Set<ForgeRuntimeAutomationCapability>
    public let maximumTextUTF8Bytes: Int
    public let maximumGestureDurationMilliseconds: Int
    public let maximumInteractions: Int

    public init(
        allowedCapabilities: Set<ForgeRuntimeAutomationCapability>,
        maximumTextUTF8Bytes: Int = 4 * 1024,
        maximumGestureDurationMilliseconds: Int = 10_000,
        maximumInteractions: Int = 512
    ) throws {
        guard (1...Self.hardMaximumTextUTF8Bytes).contains(maximumTextUTF8Bytes) else {
            throw ForgeRuntimeAutomationPolicyError.invalidMaximumTextUTF8Bytes
        }
        guard (1...Self.hardMaximumGestureDurationMilliseconds).contains(maximumGestureDurationMilliseconds) else {
            throw ForgeRuntimeAutomationPolicyError.invalidMaximumGestureDurationMilliseconds
        }
        guard (1...Self.hardMaximumInteractions).contains(maximumInteractions) else {
            throw ForgeRuntimeAutomationPolicyError.invalidMaximumInteractions
        }
        self.allowedCapabilities = allowedCapabilities
        self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        self.maximumGestureDurationMilliseconds = maximumGestureDurationMilliseconds
        self.maximumInteractions = maximumInteractions
    }
}

/// Exact host-created authority for autonomous interaction with one accepted project revision.
/// Construction remains package-owned; callers obtain sessions through the authorizer below.
public struct ForgeRuntimeAutomationSession: Equatable, Sendable {
    public let sessionID: String
    public let projectID: String
    public let sourceRevision: String
    public let runtimeVersion: ForgeRuntimeVersion
    public let grantedCapabilities: Set<ForgeRuntimeAutomationCapability>
    public let maximumTextUTF8Bytes: Int
    public let maximumGestureDurationMilliseconds: Int
    public let maximumInteractions: Int

    init(
        sessionID: String,
        projectID: String,
        sourceRevision: String,
        runtimeVersion: ForgeRuntimeVersion,
        grantedCapabilities: Set<ForgeRuntimeAutomationCapability>,
        maximumTextUTF8Bytes: Int,
        maximumGestureDurationMilliseconds: Int,
        maximumInteractions: Int
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.runtimeVersion = runtimeVersion
        self.grantedCapabilities = grantedCapabilities
        self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        self.maximumGestureDurationMilliseconds = maximumGestureDurationMilliseconds
        self.maximumInteractions = maximumInteractions
    }
}

public enum ForgeRuntimeAutomationSessionAuthorizationError: Error, Equatable, Sendable {
    case invalidSessionID
    case invalidExpectedSourceRevision
    case sourceRevisionMismatch(expected: String, actual: String)
    case noCapabilitiesRequested
    case capabilitiesNotAllowed([ForgeRuntimeAutomationCapability])
}

public struct ForgeRuntimeAutomationSessionAuthorizer: Sendable {
    public init() {}

    /// Binds semantic automation to the exact source revision selected by the trusted host.
    /// `launchAuthorization.projectVersion` is derived from an already validated manifest; the host
    /// must supply the accepted source revision independently and equality is fail-closed here.
    public func authorize(
        launchAuthorization: ForgeRuntimeLaunchAuthorization,
        sessionID: String,
        expectedSourceRevision: String,
        requestedCapabilities: Set<ForgeRuntimeAutomationCapability>,
        policy: ForgeRuntimeAutomationPolicy
    ) throws -> ForgeRuntimeAutomationSession {
        guard Self.isValidOpaqueID(sessionID, maximumUTF8Bytes: 96) else {
            throw ForgeRuntimeAutomationSessionAuthorizationError.invalidSessionID
        }
        guard Self.isCanonicalSourceRevision(expectedSourceRevision) else {
            throw ForgeRuntimeAutomationSessionAuthorizationError.invalidExpectedSourceRevision
        }
        guard launchAuthorization.projectVersion == expectedSourceRevision else {
            throw ForgeRuntimeAutomationSessionAuthorizationError.sourceRevisionMismatch(
                expected: expectedSourceRevision,
                actual: launchAuthorization.projectVersion
            )
        }
        guard !requestedCapabilities.isEmpty else {
            throw ForgeRuntimeAutomationSessionAuthorizationError.noCapabilitiesRequested
        }
        let denied = requestedCapabilities.subtracting(policy.allowedCapabilities).sorted()
        guard denied.isEmpty else {
            throw ForgeRuntimeAutomationSessionAuthorizationError.capabilitiesNotAllowed(denied)
        }

        return ForgeRuntimeAutomationSession(
            sessionID: sessionID,
            projectID: launchAuthorization.projectID,
            sourceRevision: launchAuthorization.projectVersion,
            runtimeVersion: launchAuthorization.runtimeVersion,
            grantedCapabilities: requestedCapabilities,
            maximumTextUTF8Bytes: policy.maximumTextUTF8Bytes,
            maximumGestureDurationMilliseconds: policy.maximumGestureDurationMilliseconds,
            maximumInteractions: policy.maximumInteractions
        )
    }

    private static func isValidOpaqueID(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (65...90).contains(v) || (97...122).contains(v) || (48...57).contains(v)
                || scalar == "-" || scalar == "_" || scalar == "." || scalar == ":"
        }
    }

    private static func isCanonicalSourceRevision(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ForgeRuntimeSemanticInteractionKind: String, Codable, CaseIterable, Sendable {
    case activateControl = "control.activate"
    case enterText = "text.enter"
    case setActionValue = "action.set-value"
    case performGesture = "gesture.perform"
    case restartRuntime = "runtime.restart"

    public var requiredCapability: ForgeRuntimeAutomationCapability {
        switch self {
        case .activateControl: .activateControl
        case .enterText: .enterText
        case .setActionValue: .setActionValue
        case .performGesture: .performGesture
        case .restartRuntime: .restartRuntime
        }
    }
}

/// Untrusted wire envelope emitted by an agent/test planner before host validation.
public struct ForgeRuntimeSemanticInteractionEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let sessionID: String
    public let projectID: String
    public let sourceRevision: String
    public let sequence: Int
    public let kind: String
    public let targetID: String?
    public let value: Double?
    public let text: String?
    public let gestureID: String?
    public let durationMilliseconds: Int?

    public init(
        protocolVersion: Int = 1,
        requestID: String,
        sessionID: String,
        projectID: String,
        sourceRevision: String,
        sequence: Int,
        kind: String,
        targetID: String? = nil,
        value: Double? = nil,
        text: String? = nil,
        gestureID: String? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.sequence = sequence
        self.kind = kind
        self.targetID = targetID
        self.value = value
        self.text = text
        self.gestureID = gestureID
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Validated semantic interaction. It is Encodable for deterministic authorization receipts but is
/// intentionally not Decodable, so persisted bytes cannot bypass payload validation.
public struct ForgeRuntimeSemanticInteraction: Encodable, Equatable, Sendable {
    public let kind: ForgeRuntimeSemanticInteractionKind
    public let targetID: String?
    public let value: Double?
    public let text: String?
    public let gestureID: String?
    public let durationMilliseconds: Int?

    init(
        kind: ForgeRuntimeSemanticInteractionKind,
        targetID: String? = nil,
        value: Double? = nil,
        text: String? = nil,
        gestureID: String? = nil,
        durationMilliseconds: Int? = nil
    ) {
        self.kind = kind
        self.targetID = targetID
        self.value = value
        self.text = text
        self.gestureID = gestureID
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct ForgeRuntimeSemanticInteractionRequest: Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let sessionID: String
    public let projectID: String
    public let sourceRevision: String
    public let sequence: Int
    public let interaction: ForgeRuntimeSemanticInteraction

    init(
        protocolVersion: Int,
        requestID: String,
        sessionID: String,
        projectID: String,
        sourceRevision: String,
        sequence: Int,
        interaction: ForgeRuntimeSemanticInteraction
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.sequence = sequence
        self.interaction = interaction
    }
}

public enum ForgeRuntimeSemanticInteractionError: Error, Equatable, Sendable {
    case requestTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidJSON
    case unsupportedProtocolVersion(Int)
    case invalidRequestID
    case sessionMismatch
    case projectMismatch
    case sourceRevisionMismatch
    case invalidSequence
    case unknownKind(String)
    case invalidTargetID
    case invalidText
    case invalidActionValue
    case invalidGestureID
    case invalidGestureDuration
    case unexpectedPayload
    case sequenceMismatch(expected: Int, actual: Int)
    case invalidStartingSequence
    case capabilityNotAuthorized(ForgeRuntimeAutomationCapability)
    case interactionBudgetExhausted(maximum: Int)
    case sequenceExhausted
}

public struct ForgeRuntimeSemanticInteractionDecoder: Sendable {
    public let supportedProtocolVersion: Int
    public let maximumRequestBytes: Int

    public init(supportedProtocolVersion: Int = 1, maximumRequestBytes: Int = 32 * 1024) {
        self.supportedProtocolVersion = supportedProtocolVersion
        self.maximumRequestBytes = maximumRequestBytes
    }

    public func decode(
        _ data: Data,
        session: ForgeRuntimeAutomationSession
    ) throws -> ForgeRuntimeSemanticInteractionRequest {
        guard data.count <= maximumRequestBytes else {
            throw ForgeRuntimeSemanticInteractionError.requestTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumRequestBytes
            )
        }

        let envelope: ForgeRuntimeSemanticInteractionEnvelope
        do {
            envelope = try JSONDecoder().decode(ForgeRuntimeSemanticInteractionEnvelope.self, from: data)
        } catch {
            throw ForgeRuntimeSemanticInteractionError.invalidJSON
        }

        guard envelope.protocolVersion == supportedProtocolVersion else {
            throw ForgeRuntimeSemanticInteractionError.unsupportedProtocolVersion(envelope.protocolVersion)
        }
        guard Self.isValidRequestID(envelope.requestID) else {
            throw ForgeRuntimeSemanticInteractionError.invalidRequestID
        }
        guard envelope.sessionID == session.sessionID else {
            throw ForgeRuntimeSemanticInteractionError.sessionMismatch
        }
        guard envelope.projectID == session.projectID else {
            throw ForgeRuntimeSemanticInteractionError.projectMismatch
        }
        guard envelope.sourceRevision == session.sourceRevision else {
            throw ForgeRuntimeSemanticInteractionError.sourceRevisionMismatch
        }
        guard envelope.sequence >= 0 else {
            throw ForgeRuntimeSemanticInteractionError.invalidSequence
        }
        guard let kind = ForgeRuntimeSemanticInteractionKind(rawValue: envelope.kind) else {
            throw ForgeRuntimeSemanticInteractionError.unknownKind(envelope.kind)
        }

        return ForgeRuntimeSemanticInteractionRequest(
            protocolVersion: envelope.protocolVersion,
            requestID: envelope.requestID,
            sessionID: envelope.sessionID,
            projectID: envelope.projectID,
            sourceRevision: envelope.sourceRevision,
            sequence: envelope.sequence,
            interaction: try validatePayload(envelope, kind: kind, session: session)
        )
    }

    private func validatePayload(
        _ envelope: ForgeRuntimeSemanticInteractionEnvelope,
        kind: ForgeRuntimeSemanticInteractionKind,
        session: ForgeRuntimeAutomationSession
    ) throws -> ForgeRuntimeSemanticInteraction {
        switch kind {
        case .activateControl:
            guard let targetID = envelope.targetID,
                  Self.isValidSemanticID(targetID, maximumUTF8Bytes: 160) else {
                throw ForgeRuntimeSemanticInteractionError.invalidTargetID
            }
            guard envelope.value == nil, envelope.text == nil,
                  envelope.gestureID == nil, envelope.durationMilliseconds == nil else {
                throw ForgeRuntimeSemanticInteractionError.unexpectedPayload
            }
            return .init(kind: kind, targetID: targetID)

        case .enterText:
            guard let targetID = envelope.targetID,
                  Self.isValidSemanticID(targetID, maximumUTF8Bytes: 160) else {
                throw ForgeRuntimeSemanticInteractionError.invalidTargetID
            }
            guard let text = envelope.text,
                  text.utf8.count <= session.maximumTextUTF8Bytes,
                  !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw ForgeRuntimeSemanticInteractionError.invalidText
            }
            guard envelope.value == nil, envelope.gestureID == nil,
                  envelope.durationMilliseconds == nil else {
                throw ForgeRuntimeSemanticInteractionError.unexpectedPayload
            }
            return .init(kind: kind, targetID: targetID, text: text)

        case .setActionValue:
            guard let targetID = envelope.targetID,
                  Self.isValidSemanticID(targetID, maximumUTF8Bytes: 160) else {
                throw ForgeRuntimeSemanticInteractionError.invalidTargetID
            }
            guard let value = envelope.value, value.isFinite, (-1.0...1.0).contains(value) else {
                throw ForgeRuntimeSemanticInteractionError.invalidActionValue
            }
            guard envelope.text == nil, envelope.gestureID == nil,
                  envelope.durationMilliseconds == nil else {
                throw ForgeRuntimeSemanticInteractionError.unexpectedPayload
            }
            return .init(kind: kind, targetID: targetID, value: value)

        case .performGesture:
            guard let targetID = envelope.targetID,
                  Self.isValidSemanticID(targetID, maximumUTF8Bytes: 160) else {
                throw ForgeRuntimeSemanticInteractionError.invalidTargetID
            }
            guard let gestureID = envelope.gestureID,
                  Self.isValidSemanticID(gestureID, maximumUTF8Bytes: 96) else {
                throw ForgeRuntimeSemanticInteractionError.invalidGestureID
            }
            guard let duration = envelope.durationMilliseconds,
                  (1...session.maximumGestureDurationMilliseconds).contains(duration) else {
                throw ForgeRuntimeSemanticInteractionError.invalidGestureDuration
            }
            guard envelope.value == nil, envelope.text == nil else {
                throw ForgeRuntimeSemanticInteractionError.unexpectedPayload
            }
            return .init(
                kind: kind,
                targetID: targetID,
                gestureID: gestureID,
                durationMilliseconds: duration
            )

        case .restartRuntime:
            guard envelope.targetID == nil, envelope.value == nil, envelope.text == nil,
                  envelope.gestureID == nil, envelope.durationMilliseconds == nil else {
                throw ForgeRuntimeSemanticInteractionError.unexpectedPayload
            }
            return .init(kind: kind)
        }
    }

    private static func isValidRequestID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 96 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (65...90).contains(v) || (97...122).contains(v) || (48...57).contains(v)
                || scalar == "-" || scalar == "_" || scalar == "."
        }
    }

    private static func isValidSemanticID(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (65...90).contains(v) || (97...122).contains(v) || (48...57).contains(v)
                || scalar == "-" || scalar == "_" || scalar == "." || scalar == ":" || scalar == "/"
        }
    }
}

/// Serial gate for one host-owned session. Invalid/denied requests consume neither sequence nor
/// interaction budget. Exhaustion checks happen before integer state mutation.
public struct ForgeRuntimeSemanticInteractionGate: Sendable {
    public let session: ForgeRuntimeAutomationSession
    public private(set) var nextExpectedSequence: Int
    public private(set) var authorizedInteractionCount: Int
    private let decoder: ForgeRuntimeSemanticInteractionDecoder

    public init(
        session: ForgeRuntimeAutomationSession,
        startingSequence: Int = 0,
        decoder: ForgeRuntimeSemanticInteractionDecoder = .init()
    ) throws {
        guard startingSequence >= 0 else {
            throw ForgeRuntimeSemanticInteractionError.invalidStartingSequence
        }
        self.session = session
        self.nextExpectedSequence = startingSequence
        self.authorizedInteractionCount = 0
        self.decoder = decoder
    }

    public mutating func authorize(_ data: Data) throws -> ForgeRuntimeAuthorizedSemanticInteraction {
        let request = try decoder.decode(data, session: session)
        guard request.sequence == nextExpectedSequence else {
            throw ForgeRuntimeSemanticInteractionError.sequenceMismatch(
                expected: nextExpectedSequence,
                actual: request.sequence
            )
        }
        let required = request.interaction.kind.requiredCapability
        guard session.grantedCapabilities.contains(required) else {
            throw ForgeRuntimeSemanticInteractionError.capabilityNotAuthorized(required)
        }
        guard authorizedInteractionCount < session.maximumInteractions else {
            throw ForgeRuntimeSemanticInteractionError.interactionBudgetExhausted(
                maximum: session.maximumInteractions
            )
        }
        guard nextExpectedSequence < Int.max else {
            throw ForgeRuntimeSemanticInteractionError.sequenceExhausted
        }

        authorizedInteractionCount += 1
        nextExpectedSequence += 1
        return ForgeRuntimeAuthorizedSemanticInteraction(request: request)
    }
}

/// Gate-authorized interaction ready for a real runtime host to dispatch. Authorization is not
/// execution proof and this value intentionally exposes no API that can mint a delivery-success receipt.
public struct ForgeRuntimeAuthorizedSemanticInteraction: Equatable, Sendable {
    public let request: ForgeRuntimeSemanticInteractionRequest
    init(request: ForgeRuntimeSemanticInteractionRequest) { self.request = request }

    public func authorizationReceipt() -> ForgeRuntimeSemanticInteractionAuthorizationReceipt {
        .init(request: request)
    }
}

/// Deterministic proof only that an exact interaction crossed the host automation gate.
/// Encodable-only and package-constructed; it is explicitly not runtime-delivery evidence.
public struct ForgeRuntimeSemanticInteractionAuthorizationReceipt: Encodable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let sessionID: String
    public let projectID: String
    public let sourceRevision: String
    public let sequence: Int
    public let interaction: ForgeRuntimeSemanticInteraction

    init(request: ForgeRuntimeSemanticInteractionRequest) {
        self.protocolVersion = request.protocolVersion
        self.requestID = request.requestID
        self.sessionID = request.sessionID
        self.projectID = request.projectID
        self.sourceRevision = request.sourceRevision
        self.sequence = request.sequence
        self.interaction = request.interaction
    }
}
