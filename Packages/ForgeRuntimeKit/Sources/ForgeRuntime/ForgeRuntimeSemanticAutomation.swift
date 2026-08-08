import Foundation

/// Host-owned capability classes for autonomous runtime interaction.
///
/// These are intentionally separate from generated-project manifest capabilities: generated code
/// cannot grant NovaForge automation authority to itself. The host creates a bounded session from an
/// already-authorized launch plus its own automation policy.
public enum ForgeRuntimeAutomationCapability: String, Codable, CaseIterable, Comparable, Sendable {
    case activateControl = "control.activate"
    case enterText = "text.enter"
    case setActionValue = "action.set-value"
    case performGesture = "gesture.perform"
    case restartRuntime = "runtime.restart"

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ForgeRuntimeAutomationPolicyError: Error, Equatable, Sendable {
    case invalidMaximumTextUTF8Bytes
    case invalidMaximumGestureDurationMilliseconds
}

/// Trusted host policy bounding one semantic automation session.
public struct ForgeRuntimeAutomationPolicy: Equatable, Sendable {
    public static let hardMaximumTextUTF8Bytes = 16 * 1024
    public static let hardMaximumGestureDurationMilliseconds = 30_000

    public let allowedCapabilities: Set<ForgeRuntimeAutomationCapability>
    public let maximumTextUTF8Bytes: Int
    public let maximumGestureDurationMilliseconds: Int

    public init(
        allowedCapabilities: Set<ForgeRuntimeAutomationCapability>,
        maximumTextUTF8Bytes: Int = 4 * 1024,
        maximumGestureDurationMilliseconds: Int = 10_000
    ) throws {
        guard (1...Self.hardMaximumTextUTF8Bytes).contains(maximumTextUTF8Bytes) else {
            throw ForgeRuntimeAutomationPolicyError.invalidMaximumTextUTF8Bytes
        }
        guard (1...Self.hardMaximumGestureDurationMilliseconds).contains(maximumGestureDurationMilliseconds) else {
            throw ForgeRuntimeAutomationPolicyError.invalidMaximumGestureDurationMilliseconds
        }

        self.allowedCapabilities = allowedCapabilities
        self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        self.maximumGestureDurationMilliseconds = maximumGestureDurationMilliseconds
    }
}

/// Exact host-created authority for autonomous interaction with one launched project checkpoint.
///
/// The initializer is intentionally internal. App/runtime code obtains this through
/// `ForgeRuntimeAutomationSessionAuthorizer`, which binds the session to the host-owned launch
/// authorization rather than trusting IDs supplied by a model or generated project.
public struct ForgeRuntimeAutomationSession: Equatable, Sendable {
    public let sessionID: String
    public let projectID: String
    public let checkpointID: String
    public let runtimeVersion: ForgeRuntimeVersion
    public let grantedCapabilities: Set<ForgeRuntimeAutomationCapability>
    public let maximumTextUTF8Bytes: Int
    public let maximumGestureDurationMilliseconds: Int

    init(
        sessionID: String,
        projectID: String,
        checkpointID: String,
        runtimeVersion: ForgeRuntimeVersion,
        grantedCapabilities: Set<ForgeRuntimeAutomationCapability>,
        maximumTextUTF8Bytes: Int,
        maximumGestureDurationMilliseconds: Int
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.checkpointID = checkpointID
        self.runtimeVersion = runtimeVersion
        self.grantedCapabilities = grantedCapabilities
        self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        self.maximumGestureDurationMilliseconds = maximumGestureDurationMilliseconds
    }
}

public enum ForgeRuntimeAutomationSessionAuthorizationError: Error, Equatable, Sendable {
    case invalidSessionID
    case invalidCheckpointID
    case noCapabilitiesRequested
    case capabilitiesNotAllowed([ForgeRuntimeAutomationCapability])
}

public struct ForgeRuntimeAutomationSessionAuthorizer: Sendable {
    public init() {}

    public func authorize(
        launchAuthorization: ForgeRuntimeLaunchAuthorization,
        sessionID: String,
        checkpointID: String,
        requestedCapabilities: Set<ForgeRuntimeAutomationCapability>,
        policy: ForgeRuntimeAutomationPolicy
    ) throws -> ForgeRuntimeAutomationSession {
        guard Self.isValidOpaqueID(sessionID, maximumUTF8Bytes: 96) else {
            throw ForgeRuntimeAutomationSessionAuthorizationError.invalidSessionID
        }
        guard Self.isValidOpaqueID(checkpointID, maximumUTF8Bytes: 160) else {
            throw ForgeRuntimeAutomationSessionAuthorizationError.invalidCheckpointID
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
            checkpointID: checkpointID,
            runtimeVersion: launchAuthorization.runtimeVersion,
            grantedCapabilities: requestedCapabilities,
            maximumTextUTF8Bytes: policy.maximumTextUTF8Bytes,
            maximumGestureDurationMilliseconds: policy.maximumGestureDurationMilliseconds
        )
    }

    private static func isValidOpaqueID(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let isUpper = scalar.value >= 65 && scalar.value <= 90
            let isLower = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            return isUpper || isLower || isDigit || scalar == "-" || scalar == "_" || scalar == "." || scalar == ":"
        }
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

/// Untyped wire envelope produced by an agent/test planner before fail-closed validation.
///
/// The payload is deliberately semantic: stable control/action/gesture identifiers are preferred
/// over raw screen coordinates so replay remains meaningful across layout changes.
public struct ForgeRuntimeSemanticInteractionEnvelope: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let sessionID: String
    public let projectID: String
    public let checkpointID: String
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
        checkpointID: String,
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
        self.checkpointID = checkpointID
        self.sequence = sequence
        self.kind = kind
        self.targetID = targetID
        self.value = value
        self.text = text
        self.gestureID = gestureID
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Validated semantic interaction. Only the decoder in this file constructs this value publicly.
public struct ForgeRuntimeSemanticInteraction: Codable, Equatable, Sendable {
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
    public let requestID: String
    public let sessionID: String
    public let projectID: String
    public let checkpointID: String
    public let sequence: Int
    public let interaction: ForgeRuntimeSemanticInteraction

    init(
        requestID: String,
        sessionID: String,
        projectID: String,
        checkpointID: String,
        sequence: Int,
        interaction: ForgeRuntimeSemanticInteraction
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.projectID = projectID
        self.checkpointID = checkpointID
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
    case checkpointMismatch
    case invalidSequence
    case unknownKind(String)
    case invalidTargetID
    case invalidText
    case invalidActionValue
    case invalidGestureID
    case invalidGestureDuration
    case unexpectedPayload
    case sequenceMismatch(expected: Int, actual: Int)
    case capabilityNotAuthorized(ForgeRuntimeAutomationCapability)
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
        guard Self.isValidSemanticID(envelope.requestID, maximumUTF8Bytes: 96) else {
            throw ForgeRuntimeSemanticInteractionError.invalidRequestID
        }
        guard envelope.sessionID == session.sessionID else {
            throw ForgeRuntimeSemanticInteractionError.sessionMismatch
        }
        guard envelope.projectID == session.projectID else {
            throw ForgeRuntimeSemanticInteractionError.projectMismatch
        }
        guard envelope.checkpointID == session.checkpointID else {
            throw ForgeRuntimeSemanticInteractionError.checkpointMismatch
        }
        guard envelope.sequence >= 0 else {
            throw ForgeRuntimeSemanticInteractionError.invalidSequence
        }
        guard let kind = ForgeRuntimeSemanticInteractionKind(rawValue: envelope.kind) else {
            throw ForgeRuntimeSemanticInteractionError.unknownKind(envelope.kind)
        }

        let interaction = try validatePayload(envelope, kind: kind, session: session)
        return ForgeRuntimeSemanticInteractionRequest(
            requestID: envelope.requestID,
            sessionID: envelope.sessionID,
            projectID: envelope.projectID,
            checkpointID: envelope.checkpointID,
            sequence: envelope.sequence,
            interaction: interaction
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
            guard envelope.value == nil,
                  envelope.text == nil,
                  envelope.gestureID == nil,
                  envelope.durationMilliseconds == nil else {
                throw ForgeRuntimeSemanticInteractionError.unexpectedPayload
            }
            return ForgeRuntimeSemanticInteraction(kind: kind, targetID: targetID)

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
            guard envelope.value == nil,
                  envelope.gestureID == nil,
                  envelope.durationMilliseconds == nil else {
                throw ForgeRuntimeSemanticInteractionError.unexpectedPayload
            }
            return ForgeRuntimeSemanticInteraction(kind: kind, targetID: targetID, text: text)

        case .setActionValue:
            guard let targetID = envelope.targetID,
                  Self.isValidSemanticID(targetID, maximumUTF8Bytes: 160) else {
                throw ForgeRuntimeSemanticInteractionError.invalidTargetID
            }
            guard let value = envelope.value, value.isFinite, (-1.0...1.0).contains(value) else {
                throw ForgeRuntimeSemanticInteractionError.invalidActionValue
            }
            guard envelope.text == nil,
                  envelope.gestureID == nil,
                  envelope.durationMilliseconds == nil else {
                throw ForgeRuntimeSemanticInteractionError.unexpectedPayload
            }
            return ForgeRuntimeSemanticInteraction(kind: kind, targetID: targetID, value: value)

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
            return ForgeRuntimeSemanticInteraction(
                kind: kind,
                targetID: targetID,
                gestureID: gestureID,
                durationMilliseconds: duration
            )

        case .restartRuntime:
            guard envelope.targetID == nil,
                  envelope.value == nil,
                  envelope.text == nil,
                  envelope.gestureID == nil,
                  envelope.durationMilliseconds == nil else {
                throw ForgeRuntimeSemanticInteractionError.unexpectedPayload
            }
            return ForgeRuntimeSemanticInteraction(kind: kind)
        }
    }

    private static func isValidSemanticID(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumUTF8Bytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let isUpper = scalar.value >= 65 && scalar.value <= 90
            let isLower = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            return isUpper || isLower || isDigit || scalar == "-" || scalar == "_" || scalar == "." || scalar == ":" || scalar == "/"
        }
    }
}

/// One serial gate for a host-owned automation session.
///
/// Sequence state advances only after identity, payload and capability checks all succeed. This
/// rejects replay/out-of-order model output without consuming the expected sequence on a denied
/// request, so a corrected request can still occupy that deterministic slot.
public struct ForgeRuntimeSemanticInteractionGate: Sendable {
    public let session: ForgeRuntimeAutomationSession
    public private(set) var nextExpectedSequence: Int
    private let decoder: ForgeRuntimeSemanticInteractionDecoder

    public init(
        session: ForgeRuntimeAutomationSession,
        startingSequence: Int = 0,
        decoder: ForgeRuntimeSemanticInteractionDecoder = .init()
    ) {
        self.session = session
        self.nextExpectedSequence = max(0, startingSequence)
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

        nextExpectedSequence += 1
        return ForgeRuntimeAuthorizedSemanticInteraction(request: request)
    }
}

/// Host-authorized interaction ready for runtime delivery. Authorization is not execution proof.
public struct ForgeRuntimeAuthorizedSemanticInteraction: Equatable, Sendable {
    public let request: ForgeRuntimeSemanticInteractionRequest

    init(request: ForgeRuntimeSemanticInteractionRequest) {
        self.request = request
    }

    public func receipt(
        disposition: ForgeRuntimeSemanticInteractionDisposition
    ) -> ForgeRuntimeSemanticInteractionReceipt {
        ForgeRuntimeSemanticInteractionReceipt(
            protocolVersion: 1,
            requestID: request.requestID,
            sessionID: request.sessionID,
            projectID: request.projectID,
            checkpointID: request.checkpointID,
            sequence: request.sequence,
            interaction: request.interaction,
            disposition: disposition
        )
    }
}

/// Runtime delivery outcome only. Even `.delivered` does not mean the gameplay goal, visual bar,
/// performance target, accessibility target, or Mission Constitution passed.
public enum ForgeRuntimeSemanticInteractionDisposition: String, Codable, CaseIterable, Sendable {
    case delivered
    case targetUnavailable
    case unsupportedByProject
    case runtimeUnavailable
}

/// Deterministic receipt for one semantic automation attempt.
///
/// No wall-clock timestamp is embedded so identical deterministic runs can compare receipt streams.
/// A higher-level evidence store may attach observation time, screenshots, state assertions and
/// performance samples without changing this replay identity.
public struct ForgeRuntimeSemanticInteractionReceipt: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let sessionID: String
    public let projectID: String
    public let checkpointID: String
    public let sequence: Int
    public let interaction: ForgeRuntimeSemanticInteraction
    public let disposition: ForgeRuntimeSemanticInteractionDisposition

    public init(
        protocolVersion: Int = 1,
        requestID: String,
        sessionID: String,
        projectID: String,
        checkpointID: String,
        sequence: Int,
        interaction: ForgeRuntimeSemanticInteraction,
        disposition: ForgeRuntimeSemanticInteractionDisposition
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.sessionID = sessionID
        self.projectID = projectID
        self.checkpointID = checkpointID
        self.sequence = sequence
        self.interaction = interaction
        self.disposition = disposition
    }
}
