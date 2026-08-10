import Foundation
import Testing
@testable import LocalOnlyNetworkAuditCore

private func window(
    environment: LocalOnlyAuditEnvironment = .physicalDevice,
    scope: LocalOnlyAuditCaptureScope = .targetProcess,
    completeness: LocalOnlyAuditInstrumentationCompleteness = .completeForTargetProcess,
    generation: UInt64 = 9,
    lastConsumedGeneration: UInt64 = 8,
    armedBeforeLoad: Bool = true,
    throughFinalOutput: Bool = true,
    dropped: UInt64 = 0
) throws -> LocalOnlyNetworkAuditWindow {
    try .init(
        qualificationSubjectDigest: String(repeating: "a", count: 64),
        runID: "qualification-run-1",
        observerMechanismID: "target-process-network-observer",
        observerRevision: "observer-rev-1",
        environment: environment,
        captureScope: scope,
        instrumentationCompleteness: completeness,
        observationGeneration: generation,
        lastConsumedObservationGeneration: lastConsumedGeneration,
        captureBeganMonotonicNanoseconds: 1_000,
        captureEndedMonotonicNanoseconds: 10_000,
        observerArmedBeforeModelLoad: armedBeforeLoad,
        observerRemainedArmedThroughFinalOutput: throughFinalOutput,
        droppedObservationCount: dropped
    )
}

private func observation(
    sequence: UInt64 = 1,
    timestamp: UInt64 = 2_000,
    direction: LocalOnlyNetworkDirection = .outbound,
    destination: LocalOnlyNetworkDestinationScope = .publicNetwork,
    transport: LocalOnlyNetworkTransport = .https,
    outcome: LocalOnlyNetworkAttemptOutcome = .attempted
) throws -> LocalOnlyNetworkObservation {
    try .init(
        sequence: sequence,
        monotonicNanoseconds: timestamp,
        direction: direction,
        destinationScope: destination,
        transport: transport,
        outcome: outcome,
        subsystemID: "local-model-runtime"
    )
}

private func transcript(
    window resolvedWindow: LocalOnlyNetworkAuditWindow? = nil,
    observations: [LocalOnlyNetworkObservation] = []
) throws -> LocalOnlyNetworkAuditTranscript {
    try .init(window: resolvedWindow ?? window(), observations: observations)
}

@Test func completePhysicalCaptureCanOnlyProduceCleanCandidate() throws {
    let projection = LocalOnlyNetworkAuditEvaluator.project(try transcript())
    #expect(projection.disposition == .cleanCandidate)
    #expect(projection.reasons == [.noViolationInSuppliedCandidateTranscript])
    #expect(projection.projectionAuthority == .candidateOnly)
    #expect(!projection.authorizesQualification)
    #expect(projection.consumesObservationGeneration == 9)
}

@Test func cleanCandidateRemainsNonAuthorizingAfterCodableRoundTrip() throws {
    let original = LocalOnlyNetworkAuditEvaluator.project(try transcript())
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(LocalOnlyNetworkAuditProjection.self, from: data)
    #expect(decoded == original)
    #expect(decoded.disposition == .cleanCandidate)
    #expect(!decoded.authorizesQualification)
}

@Test func anyOffDeviceAttemptIsKnownViolationEvenWhenBlocked() throws {
    for outcome in [LocalOnlyNetworkAttemptOutcome.attempted, .blocked, .succeeded] {
        let projection = LocalOnlyNetworkAuditEvaluator.project(
            try transcript(observations: [observation(outcome: outcome)])
        )
        #expect(projection.disposition == .failed)
        #expect(projection.reasons == [.prohibitedNetworkAttemptObserved])
    }
}

@Test func loopbackTransportIsPermittedExceptDNS() throws {
    let loopback = try observation(destination: .loopback, transport: .tcp)
    let clean = LocalOnlyNetworkAuditEvaluator.project(try transcript(observations: [loopback]))
    #expect(clean.disposition == .cleanCandidate)

    let dns = try observation(destination: .loopback, transport: .dns)
    let failed = LocalOnlyNetworkAuditEvaluator.project(try transcript(observations: [dns]))
    #expect(failed.disposition == .failed)
}

@Test func simulatorCannotProjectPhysicalDeviceCleanliness() throws {
    let projection = LocalOnlyNetworkAuditEvaluator.project(
        try transcript(window: window(environment: .simulator))
    )
    #expect(projection.disposition == .inconclusive)
    #expect(projection.reasons == [.physicalDeviceRequired])
}

@Test func incompleteCaptureFailsClosedAsInconclusive() throws {
    let projection = LocalOnlyNetworkAuditEvaluator.project(
        try transcript(
            window: window(
                scope: .unknown,
                completeness: .partial,
                armedBeforeLoad: false,
                throughFinalOutput: false,
                dropped: 2
            )
        )
    )
    #expect(projection.disposition == .inconclusive)
    #expect(projection.reasons == [
        .targetProcessScopeRequired,
        .completeInstrumentationRequired,
        .observerWasNotArmedBeforeModelLoad,
        .observerDidNotCoverFinalOutput,
        .droppedObservations,
    ])
}

@Test func knownViolationOutranksIncompleteCapture() throws {
    let projection = LocalOnlyNetworkAuditEvaluator.project(
        try transcript(
            window: window(completeness: .unknown, dropped: 20),
            observations: [observation(destination: .privateNetwork, transport: .tcp)]
        )
    )
    #expect(projection.disposition == .failed)
    #expect(projection.reasons == [.prohibitedNetworkAttemptObserved])
}

@Test func observationGenerationRejectsReplayEqualAndZero() {
    #expect(throws: LocalOnlyNetworkAuditValidationError.invalidObservationGeneration) {
        _ = try window(generation: 8, lastConsumedGeneration: 8)
    }
    #expect(throws: LocalOnlyNetworkAuditValidationError.invalidObservationGeneration) {
        _ = try window(generation: 7, lastConsumedGeneration: 8)
    }
    #expect(throws: LocalOnlyNetworkAuditValidationError.invalidObservationGeneration) {
        _ = try window(generation: 0, lastConsumedGeneration: 0)
    }
}

@Test func exactQualificationDigestAndCanonicalIDsFailClosed() {
    #expect(throws: LocalOnlyNetworkAuditValidationError.invalidQualificationSubjectDigest) {
        _ = try LocalOnlyNetworkAuditWindow(
            qualificationSubjectDigest: String(repeating: "A", count: 64),
            runID: "run",
            observerMechanismID: "observer",
            observerRevision: "rev",
            environment: .physicalDevice,
            captureScope: .targetProcess,
            instrumentationCompleteness: .completeForTargetProcess,
            observationGeneration: 2,
            lastConsumedObservationGeneration: 1,
            captureBeganMonotonicNanoseconds: 1,
            captureEndedMonotonicNanoseconds: 2,
            observerArmedBeforeModelLoad: true,
            observerRemainedArmedThroughFinalOutput: true,
            droppedObservationCount: 0
        )
    }

    #expect(throws: LocalOnlyNetworkAuditValidationError.invalidField("runID")) {
        _ = try LocalOnlyNetworkAuditWindow(
            qualificationSubjectDigest: String(repeating: "a", count: 64),
            runID: " run ",
            observerMechanismID: "observer",
            observerRevision: "rev",
            environment: .physicalDevice,
            captureScope: .targetProcess,
            instrumentationCompleteness: .completeForTargetProcess,
            observationGeneration: 2,
            lastConsumedObservationGeneration: 1,
            captureBeganMonotonicNanoseconds: 1,
            captureEndedMonotonicNanoseconds: 2,
            observerArmedBeforeModelLoad: true,
            observerRemainedArmedThroughFinalOutput: true,
            droppedObservationCount: 0
        )
    }
}

@Test func captureWindowMustAdvance() {
    #expect(throws: LocalOnlyNetworkAuditValidationError.invalidCaptureWindow) {
        _ = try LocalOnlyNetworkAuditWindow(
            qualificationSubjectDigest: String(repeating: "a", count: 64),
            runID: "run",
            observerMechanismID: "observer",
            observerRevision: "rev",
            environment: .physicalDevice,
            captureScope: .targetProcess,
            instrumentationCompleteness: .completeForTargetProcess,
            observationGeneration: 2,
            lastConsumedObservationGeneration: 1,
            captureBeganMonotonicNanoseconds: 10,
            captureEndedMonotonicNanoseconds: 10,
            observerArmedBeforeModelLoad: true,
            observerRemainedArmedThroughFinalOutput: true,
            droppedObservationCount: 0
        )
    }
}

@Test func observationsMustBeStrictlyOrderedAndInsideWindow() throws {
    #expect(throws: LocalOnlyNetworkAuditValidationError.invalidObservationSequence) {
        _ = try transcript(observations: [
            observation(sequence: 2, timestamp: 2_000),
            observation(sequence: 2, timestamp: 3_000),
        ])
    }

    #expect(throws: LocalOnlyNetworkAuditValidationError.invalidObservationSequence) {
        _ = try transcript(observations: [
            observation(sequence: 1, timestamp: 3_000),
            observation(sequence: 2, timestamp: 2_000),
        ])
    }

    #expect(throws: LocalOnlyNetworkAuditValidationError.observationOutsideCaptureWindow) {
        _ = try transcript(observations: [observation(sequence: 1, timestamp: 20_000)])
    }
}

@Test func transcriptObservationCountIsBounded() throws {
    let observations = try (1...LocalOnlyNetworkAuditTranscript.maximumObservations + 1).map { index in
        try observation(sequence: UInt64(index), timestamp: 2_000)
    }
    #expect(throws: LocalOnlyNetworkAuditValidationError.tooManyObservations) {
        _ = try transcript(observations: observations)
    }
}

@Test func decodedWindowRevalidatesReplayAndCaptureBounds() throws {
    let original = try transcript()
    let data = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedWindow = try #require(object["window"] as? [String: Any])
    encodedWindow["lastConsumedObservationGeneration"] = encodedWindow["observationGeneration"]
    object["window"] = encodedWindow
    let replayed = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: LocalOnlyNetworkAuditValidationError.invalidObservationGeneration) {
        _ = try JSONDecoder().decode(LocalOnlyNetworkAuditTranscript.self, from: replayed)
    }
}

@Test func decodedProjectionCannotForgeCleanVerdict() throws {
    let failed = LocalOnlyNetworkAuditEvaluator.project(
        try transcript(observations: [observation(destination: .publicNetwork)])
    )
    let data = try JSONEncoder().encode(failed)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["disposition"] = "cleanCandidate"
    object["reasons"] = ["noViolationInSuppliedCandidateTranscript"]
    let forged = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: LocalOnlyNetworkAuditValidationError.forgedProjection) {
        _ = try JSONDecoder().decode(LocalOnlyNetworkAuditProjection.self, from: forged)
    }
}

@Test func decodedProjectionCannotForgeConsumedGeneration() throws {
    let clean = LocalOnlyNetworkAuditEvaluator.project(try transcript())
    let data = try JSONEncoder().encode(clean)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["consumesObservationGeneration"] = 99
    let forged = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: LocalOnlyNetworkAuditValidationError.forgedProjection) {
        _ = try JSONDecoder().decode(LocalOnlyNetworkAuditProjection.self, from: forged)
    }
}

@Test func unknownEnumValuesFailClosedDuringDecode() throws {
    let clean = LocalOnlyNetworkAuditEvaluator.project(try transcript())
    let data = try JSONEncoder().encode(clean)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var encodedTranscript = try #require(object["transcript"] as? [String: Any])
    var encodedWindow = try #require(encodedTranscript["window"] as? [String: Any])
    encodedWindow["instrumentationCompleteness"] = "magicallyPerfect"
    encodedTranscript["window"] = encodedWindow
    object["transcript"] = encodedTranscript
    let corrupted = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(LocalOnlyNetworkAuditProjection.self, from: corrupted)
    }
}
