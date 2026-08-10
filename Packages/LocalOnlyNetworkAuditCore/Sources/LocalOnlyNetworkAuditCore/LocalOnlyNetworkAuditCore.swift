import Foundation

public enum LocalOnlyNetworkAuditValidationError: Error, Equatable, Sendable {
    case invalidField(String)
    case invalidQualificationSubjectDigest
    case invalidCaptureWindow
    case invalidObservationGeneration
    case tooManyObservations
    case invalidObservationSequence
    case observationOutsideCaptureWindow
    case forgedProjection
}

private enum AuditValidation {
    static func canonicalText(_ value: String, field: String, maxUTF8Bytes: Int = 192) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= maxUTF8Bytes,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw LocalOnlyNetworkAuditValidationError.invalidField(field)
        }
        return value
    }

    static func sha256(_ value: String) throws -> String {
        guard value.utf8.count == 64,
              value == value.lowercased(),
              value.unicodeScalars.allSatisfy({ scalar in
                  ("0"..."9").contains(Character(scalar)) || ("a"..."f").contains(Character(scalar))
              })
        else {
            throw LocalOnlyNetworkAuditValidationError.invalidQualificationSubjectDigest
        }
        return value
    }
}

public enum LocalOnlyAuditEnvironment: String, Codable, Hashable, Sendable {
    case physicalDevice
    case simulator
}

public enum LocalOnlyAuditCaptureScope: String, Codable, Hashable, Sendable {
    /// Observations are attributed to the exact target process being qualified.
    case targetProcess
    /// Scope is not strong enough to support a clean candidate verdict.
    case unknown
}

public enum LocalOnlyAuditInstrumentationCompleteness: String, Codable, Hashable, Sendable {
    /// Candidate metadata claims all target-process network attempts in the capture window are observable.
    /// A future trusted host producer must authenticate this claim; this enum value is not proof by itself.
    case completeForTargetProcess
    case partial
    case unknown
}

/// Candidate identity for one exact Local Only qualification observation window.
///
/// `qualificationSubjectDigest` is intended to bind the complete canonical qualification subject owned by
/// LocalModelQualificationCore (model/tokenizer/runtime/quant/KV/context/device/OS). It is an opaque identity,
/// not authentication. Every field in this type is public/Codable and therefore caller-mintable.
public struct LocalOnlyNetworkAuditWindow: Codable, Hashable, Sendable {
    public let qualificationSubjectDigest: String
    public let runID: String
    public let observerMechanismID: String
    public let observerRevision: String
    public let environment: LocalOnlyAuditEnvironment
    public let captureScope: LocalOnlyAuditCaptureScope
    public let instrumentationCompleteness: LocalOnlyAuditInstrumentationCompleteness
    public let observationGeneration: UInt64
    public let lastConsumedObservationGeneration: UInt64
    public let captureBeganMonotonicNanoseconds: UInt64
    public let captureEndedMonotonicNanoseconds: UInt64
    public let observerArmedBeforeModelLoad: Bool
    public let observerRemainedArmedThroughFinalOutput: Bool
    public let droppedObservationCount: UInt64

    public init(
        qualificationSubjectDigest: String,
        runID: String,
        observerMechanismID: String,
        observerRevision: String,
        environment: LocalOnlyAuditEnvironment,
        captureScope: LocalOnlyAuditCaptureScope,
        instrumentationCompleteness: LocalOnlyAuditInstrumentationCompleteness,
        observationGeneration: UInt64,
        lastConsumedObservationGeneration: UInt64,
        captureBeganMonotonicNanoseconds: UInt64,
        captureEndedMonotonicNanoseconds: UInt64,
        observerArmedBeforeModelLoad: Bool,
        observerRemainedArmedThroughFinalOutput: Bool,
        droppedObservationCount: UInt64
    ) throws {
        self.qualificationSubjectDigest = try AuditValidation.sha256(qualificationSubjectDigest)
        self.runID = try AuditValidation.canonicalText(runID, field: "runID", maxUTF8Bytes: 128)
        self.observerMechanismID = try AuditValidation.canonicalText(
            observerMechanismID,
            field: "observerMechanismID",
            maxUTF8Bytes: 128
        )
        self.observerRevision = try AuditValidation.canonicalText(
            observerRevision,
            field: "observerRevision",
            maxUTF8Bytes: 128
        )
        guard observationGeneration > 0,
              observationGeneration > lastConsumedObservationGeneration else {
            throw LocalOnlyNetworkAuditValidationError.invalidObservationGeneration
        }
        guard captureEndedMonotonicNanoseconds > captureBeganMonotonicNanoseconds else {
            throw LocalOnlyNetworkAuditValidationError.invalidCaptureWindow
        }

        self.environment = environment
        self.captureScope = captureScope
        self.instrumentationCompleteness = instrumentationCompleteness
        self.observationGeneration = observationGeneration
        self.lastConsumedObservationGeneration = lastConsumedObservationGeneration
        self.captureBeganMonotonicNanoseconds = captureBeganMonotonicNanoseconds
        self.captureEndedMonotonicNanoseconds = captureEndedMonotonicNanoseconds
        self.observerArmedBeforeModelLoad = observerArmedBeforeModelLoad
        self.observerRemainedArmedThroughFinalOutput = observerRemainedArmedThroughFinalOutput
        self.droppedObservationCount = droppedObservationCount
    }

    private enum CodingKeys: String, CodingKey {
        case qualificationSubjectDigest, runID, observerMechanismID, observerRevision
        case environment, captureScope, instrumentationCompleteness
        case observationGeneration, lastConsumedObservationGeneration
        case captureBeganMonotonicNanoseconds, captureEndedMonotonicNanoseconds
        case observerArmedBeforeModelLoad, observerRemainedArmedThroughFinalOutput
        case droppedObservationCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            qualificationSubjectDigest: container.decode(String.self, forKey: .qualificationSubjectDigest),
            runID: container.decode(String.self, forKey: .runID),
            observerMechanismID: container.decode(String.self, forKey: .observerMechanismID),
            observerRevision: container.decode(String.self, forKey: .observerRevision),
            environment: container.decode(LocalOnlyAuditEnvironment.self, forKey: .environment),
            captureScope: container.decode(LocalOnlyAuditCaptureScope.self, forKey: .captureScope),
            instrumentationCompleteness: container.decode(LocalOnlyAuditInstrumentationCompleteness.self, forKey: .instrumentationCompleteness),
            observationGeneration: container.decode(UInt64.self, forKey: .observationGeneration),
            lastConsumedObservationGeneration: container.decode(UInt64.self, forKey: .lastConsumedObservationGeneration),
            captureBeganMonotonicNanoseconds: container.decode(UInt64.self, forKey: .captureBeganMonotonicNanoseconds),
            captureEndedMonotonicNanoseconds: container.decode(UInt64.self, forKey: .captureEndedMonotonicNanoseconds),
            observerArmedBeforeModelLoad: container.decode(Bool.self, forKey: .observerArmedBeforeModelLoad),
            observerRemainedArmedThroughFinalOutput: container.decode(Bool.self, forKey: .observerRemainedArmedThroughFinalOutput),
            droppedObservationCount: container.decode(UInt64.self, forKey: .droppedObservationCount)
        )
    }
}

public enum LocalOnlyNetworkDirection: String, Codable, Hashable, Sendable {
    case inbound
    case outbound
}

public enum LocalOnlyNetworkDestinationScope: String, Codable, Hashable, Sendable {
    /// Traffic cannot leave the device through this destination class.
    case loopback
    case linkLocal
    case privateNetwork
    case publicNetwork
    case unknown
}

public enum LocalOnlyNetworkTransport: String, Codable, Hashable, Sendable {
    case dns
    case tcp
    case udp
    case http
    case https
    case webSocket
    case other
}

public enum LocalOnlyNetworkAttemptOutcome: String, Codable, Hashable, Sendable {
    case attempted
    case blocked
    case succeeded
}

/// Privacy-preserving observation of a target-process network attempt.
///
/// The contract intentionally stores a destination class rather than raw URLs/IP addresses. A future producer may
/// keep richer private diagnostics elsewhere, but qualification truth only needs to know whether traffic could leave
/// the device. Any non-loopback target-process network attempt is a Local Only violation, even if it was blocked.
/// DNS is treated as a violation even when its immediate destination is loopback because it requests off-device name
/// resolution semantics unless a future, separately reviewed contract can prove otherwise.
public struct LocalOnlyNetworkObservation: Codable, Hashable, Sendable {
    public let sequence: UInt64
    public let monotonicNanoseconds: UInt64
    public let direction: LocalOnlyNetworkDirection
    public let destinationScope: LocalOnlyNetworkDestinationScope
    public let transport: LocalOnlyNetworkTransport
    public let outcome: LocalOnlyNetworkAttemptOutcome
    public let subsystemID: String

    public init(
        sequence: UInt64,
        monotonicNanoseconds: UInt64,
        direction: LocalOnlyNetworkDirection,
        destinationScope: LocalOnlyNetworkDestinationScope,
        transport: LocalOnlyNetworkTransport,
        outcome: LocalOnlyNetworkAttemptOutcome,
        subsystemID: String
    ) throws {
        guard sequence > 0 else {
            throw LocalOnlyNetworkAuditValidationError.invalidObservationSequence
        }
        self.sequence = sequence
        self.monotonicNanoseconds = monotonicNanoseconds
        self.direction = direction
        self.destinationScope = destinationScope
        self.transport = transport
        self.outcome = outcome
        self.subsystemID = try AuditValidation.canonicalText(subsystemID, field: "subsystemID", maxUTF8Bytes: 128)
    }

    public var violatesLocalOnly: Bool {
        transport == .dns || destinationScope != .loopback
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, monotonicNanoseconds, direction, destinationScope, transport, outcome, subsystemID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sequence: container.decode(UInt64.self, forKey: .sequence),
            monotonicNanoseconds: container.decode(UInt64.self, forKey: .monotonicNanoseconds),
            direction: container.decode(LocalOnlyNetworkDirection.self, forKey: .direction),
            destinationScope: container.decode(LocalOnlyNetworkDestinationScope.self, forKey: .destinationScope),
            transport: container.decode(LocalOnlyNetworkTransport.self, forKey: .transport),
            outcome: container.decode(LocalOnlyNetworkAttemptOutcome.self, forKey: .outcome),
            subsystemID: container.decode(String.self, forKey: .subsystemID)
        )
    }
}

/// Bounded candidate transcript. It proves only that the supplied candidate fields are structurally coherent.
public struct LocalOnlyNetworkAuditTranscript: Codable, Hashable, Sendable {
    public static let maximumObservations = 4_096

    public let window: LocalOnlyNetworkAuditWindow
    public let observations: [LocalOnlyNetworkObservation]

    public init(
        window: LocalOnlyNetworkAuditWindow,
        observations: [LocalOnlyNetworkObservation]
    ) throws {
        guard observations.count <= Self.maximumObservations else {
            throw LocalOnlyNetworkAuditValidationError.tooManyObservations
        }

        var previousSequence: UInt64 = 0
        var previousTimestamp = window.captureBeganMonotonicNanoseconds
        for observation in observations {
            guard observation.sequence > previousSequence else {
                throw LocalOnlyNetworkAuditValidationError.invalidObservationSequence
            }
            guard observation.monotonicNanoseconds >= window.captureBeganMonotonicNanoseconds,
                  observation.monotonicNanoseconds <= window.captureEndedMonotonicNanoseconds else {
                throw LocalOnlyNetworkAuditValidationError.observationOutsideCaptureWindow
            }
            guard observation.monotonicNanoseconds >= previousTimestamp else {
                throw LocalOnlyNetworkAuditValidationError.invalidObservationSequence
            }
            previousSequence = observation.sequence
            previousTimestamp = observation.monotonicNanoseconds
        }

        self.window = window
        self.observations = observations
    }

    private enum CodingKeys: String, CodingKey {
        case window, observations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            window: container.decode(LocalOnlyNetworkAuditWindow.self, forKey: .window),
            observations: container.decode([LocalOnlyNetworkObservation].self, forKey: .observations)
        )
    }
}

public enum LocalOnlyNetworkAuditDisposition: String, Codable, Hashable, Sendable {
    /// Candidate transcript contains a known Local Only violation.
    case failed
    /// Candidate transcript lacks enough trustworthy-looking coverage to even project a clean candidate.
    case inconclusive
    /// Supplied candidate data contains no Local Only violation and claims complete physical-device coverage.
    /// This is still not qualification authority.
    case cleanCandidate
}

public enum LocalOnlyNetworkAuditReason: String, Codable, CaseIterable, Hashable, Sendable {
    case prohibitedNetworkAttemptObserved
    case physicalDeviceRequired
    case targetProcessScopeRequired
    case completeInstrumentationRequired
    case observerWasNotArmedBeforeModelLoad
    case observerDidNotCoverFinalOutput
    case droppedObservations
    case noViolationInSuppliedCandidateTranscript
}

public enum LocalOnlyNetworkAuditProjectionAuthority: String, Codable, Hashable, Sendable {
    case candidateOnly
}

/// Deterministic candidate-only projection.
///
/// A clean projection is useful for a trusted physical-device producer to inspect, but it is never sufficient to
/// qualify a model. The future host adapter must authenticate the exact qualification subject, observer mechanism,
/// capture lifecycle, observation completeness, and generation freshness before minting/trusting #101 evidence.
public struct LocalOnlyNetworkAuditProjection: Codable, Hashable, Sendable {
    public let transcript: LocalOnlyNetworkAuditTranscript
    public let disposition: LocalOnlyNetworkAuditDisposition
    public let reasons: [LocalOnlyNetworkAuditReason]
    public let consumesObservationGeneration: UInt64
    public let projectionAuthority: LocalOnlyNetworkAuditProjectionAuthority

    public var authorizesQualification: Bool { false }

    fileprivate init(
        transcript: LocalOnlyNetworkAuditTranscript,
        disposition: LocalOnlyNetworkAuditDisposition,
        reasons: [LocalOnlyNetworkAuditReason]
    ) {
        self.transcript = transcript
        self.disposition = disposition
        self.reasons = reasons
        self.consumesObservationGeneration = transcript.window.observationGeneration
        self.projectionAuthority = .candidateOnly
    }

    private enum CodingKeys: String, CodingKey {
        case transcript, disposition, reasons, consumesObservationGeneration, projectionAuthority
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let transcript = try container.decode(LocalOnlyNetworkAuditTranscript.self, forKey: .transcript)
        let disposition = try container.decode(LocalOnlyNetworkAuditDisposition.self, forKey: .disposition)
        let reasons = try container.decode([LocalOnlyNetworkAuditReason].self, forKey: .reasons)
        let consumesObservationGeneration = try container.decode(UInt64.self, forKey: .consumesObservationGeneration)
        let projectionAuthority = try container.decode(LocalOnlyNetworkAuditProjectionAuthority.self, forKey: .projectionAuthority)

        let expected = LocalOnlyNetworkAuditEvaluator.project(transcript)
        guard disposition == expected.disposition,
              reasons == expected.reasons,
              consumesObservationGeneration == expected.consumesObservationGeneration,
              projectionAuthority == .candidateOnly else {
            throw LocalOnlyNetworkAuditValidationError.forgedProjection
        }
        self = expected
    }
}

public enum LocalOnlyNetworkAuditEvaluator {
    public static func project(_ transcript: LocalOnlyNetworkAuditTranscript) -> LocalOnlyNetworkAuditProjection {
        let window = transcript.window

        if transcript.observations.contains(where: \.violatesLocalOnly) {
            return .init(
                transcript: transcript,
                disposition: .failed,
                reasons: [.prohibitedNetworkAttemptObserved]
            )
        }

        var blockers: [LocalOnlyNetworkAuditReason] = []
        if window.environment != .physicalDevice {
            blockers.append(.physicalDeviceRequired)
        }
        if window.captureScope != .targetProcess {
            blockers.append(.targetProcessScopeRequired)
        }
        if window.instrumentationCompleteness != .completeForTargetProcess {
            blockers.append(.completeInstrumentationRequired)
        }
        if !window.observerArmedBeforeModelLoad {
            blockers.append(.observerWasNotArmedBeforeModelLoad)
        }
        if !window.observerRemainedArmedThroughFinalOutput {
            blockers.append(.observerDidNotCoverFinalOutput)
        }
        if window.droppedObservationCount > 0 {
            blockers.append(.droppedObservations)
        }

        if !blockers.isEmpty {
            return .init(transcript: transcript, disposition: .inconclusive, reasons: blockers)
        }

        return .init(
            transcript: transcript,
            disposition: .cleanCandidate,
            reasons: [.noViolationInSuppliedCandidateTranscript]
        )
    }
}
