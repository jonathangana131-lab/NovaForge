import AgentDomain
import Foundation

public struct TransportReplayWindowLimits: Equatable, Sendable {
    public static let production = Self(
        maximumEventCount: 128,
        maximumEncodedBytes: 8_388_608
    )

    public let maximumEventCount: Int
    public let maximumEncodedBytes: Int

    public init(maximumEventCount: Int, maximumEncodedBytes: Int) {
        self.maximumEventCount = maximumEventCount
        self.maximumEncodedBytes = maximumEncodedBytes
    }
}

public struct TransportRequestAdmission: Equatable, Sendable {
    public let acceptedSequence: UInt64
    public let replayedEvents: [WorkerEventEnvelope]

    public init(
        acceptedSequence: UInt64,
        replayedEvents: [WorkerEventEnvelope]
    ) {
        self.acceptedSequence = acceptedSequence
        self.replayedEvents = replayedEvents
    }
}

public struct TransportRunChannelSnapshot: Equatable, Sendable {
    public let pairingID: TransportPairingID
    public let pairingGeneration: UInt64
    public let runID: RunID
    public let ownerExecutionNodeID: ExecutionNodeID
    public let highestAcceptedRequestSequence: UInt64
    public let highestAcceptedEventSequence: UInt64
    public let highestAcknowledgedRequestSequence: UInt64
    public let highestAcknowledgedEventSequence: UInt64
    public let retainedReplayEventCount: Int
    public let isRevoked: Bool
}

/// Stateful, in-memory admission authority for one run. The execution owner,
/// pairing generation, and peer keys are frozen at initialization. Persistence
/// and real network/process I/O intentionally live outside this M10 contract.
public actor TransportRunChannel {
    public nonisolated let pairing: TransportPairingIdentity
    public nonisolated let runID: RunID
    public nonisolated let ownerExecutionNodeID: ExecutionNodeID

    private let publicKeys: TransportPairingPublicKeys
    private let replayLimits: TransportReplayWindowLimits
    private var highestRequestSequence: UInt64 = 0
    private var highestEventSequence: UInt64 = 0
    private var highestAcknowledgedRequestSequence: UInt64 = 0
    private var highestAcknowledgedEventSequence: UInt64 = 0
    private var replayWindow: [(envelope: WorkerEventEnvelope, byteCount: Int)] = []
    private var replayWindowByteCount = 0
    private var revoked = false

    public init(
        pairing: TransportPairingIdentity,
        publicKeys: TransportPairingPublicKeys,
        runID: RunID,
        ownerExecutionNodeID: ExecutionNodeID,
        replayLimits: TransportReplayWindowLimits = .production
    ) throws {
        guard ownerExecutionNodeID == pairing.worker.executionNodeID else {
            throw TransportContractError.ownershipMismatch
        }
        guard replayLimits.maximumEventCount > 0,
              replayLimits.maximumEncodedBytes > 0
        else { throw TransportContractError.invalidPairing }
        self.pairing = pairing
        self.publicKeys = publicKeys
        self.runID = runID
        self.ownerExecutionNodeID = ownerExecutionNodeID
        self.replayLimits = replayLimits
    }

    public func admit(
        _ request: WorkerRequestEnvelope
    ) throws -> TransportRequestAdmission {
        guard !revoked else { throw TransportContractError.pairingRevoked }
        try validateCommon(
            protocolVersion: request.protocolVersion,
            pairingID: request.pairingID,
            pairingGeneration: request.pairingGeneration,
            runID: request.runID,
            executionNodeID: request.executionNodeID
        )
        guard request.signer == pairing.controller.publicKeyFingerprint else {
            throw TransportContractError.signerMismatch
        }
        try request.verify(using: publicKeys.controller)

        let expected = try nextSequence(after: highestRequestSequence)
        if request.sequence.rawValue < expected {
            throw TransportContractError.duplicateRequest(
                sequence: request.sequence.rawValue
            )
        }
        guard request.sequence.rawValue == expected else {
            throw TransportContractError.requestGap(
                expected: expected,
                received: request.sequence.rawValue
            )
        }

        try validate(request.reconnectCursor)
        let acknowledged = request.reconnectCursor.lastAcceptedEventSequence
        guard acknowledged >= highestAcknowledgedEventSequence else {
            throw TransportContractError.acknowledgementRegression(
                previous: highestAcknowledgedEventSequence,
                received: acknowledged
            )
        }
        guard acknowledged <= highestEventSequence else {
            throw TransportContractError.acknowledgementAhead(
                maximum: highestEventSequence,
                received: acknowledged
            )
        }

        let replay = try replayEvents(after: acknowledged)
        highestRequestSequence = request.sequence.rawValue
        highestAcknowledgedEventSequence = acknowledged
        return TransportRequestAdmission(
            acceptedSequence: request.sequence.rawValue,
            replayedEvents: replay
        )
    }

    public func admit(_ event: WorkerEventEnvelope) throws {
        guard !revoked else { throw TransportContractError.pairingRevoked }
        try validateCommon(
            protocolVersion: event.protocolVersion,
            pairingID: event.pairingID,
            pairingGeneration: event.pairingGeneration,
            runID: event.runID,
            executionNodeID: event.executionNodeID
        )
        guard event.signer == pairing.worker.publicKeyFingerprint else {
            throw TransportContractError.signerMismatch
        }
        try event.verify(using: publicKeys.worker)

        let expected = try nextSequence(after: highestEventSequence)
        if event.sequence.rawValue < expected {
            throw TransportContractError.duplicateEvent(
                sequence: event.sequence.rawValue
            )
        }
        guard event.sequence.rawValue == expected else {
            throw TransportContractError.eventGap(
                expected: expected,
                received: event.sequence.rawValue
            )
        }

        let acknowledged = event.acknowledgesRequestThrough
        guard acknowledged >= highestAcknowledgedRequestSequence else {
            throw TransportContractError.acknowledgementRegression(
                previous: highestAcknowledgedRequestSequence,
                received: acknowledged
            )
        }
        guard acknowledged <= highestRequestSequence else {
            throw TransportContractError.acknowledgementAhead(
                maximum: highestRequestSequence,
                received: acknowledged
            )
        }

        let byteCount = try TransportWireCodec.encode(event).count
        guard byteCount <= replayLimits.maximumEncodedBytes else {
            throw TransportContractError.replayEventTooLarge(
                maximum: replayLimits.maximumEncodedBytes,
                actual: byteCount
            )
        }

        replayWindow.append((event, byteCount))
        replayWindowByteCount += byteCount
        while replayWindow.count > replayLimits.maximumEventCount
            || replayWindowByteCount > replayLimits.maximumEncodedBytes
        {
            let removed = replayWindow.removeFirst()
            replayWindowByteCount -= removed.byteCount
        }
        highestEventSequence = event.sequence.rawValue
        highestAcknowledgedRequestSequence = acknowledged
    }

    public func revoke(_ revocation: TransportPairingRevocation) throws {
        guard !revoked else { throw TransportContractError.duplicateRevocation }
        guard revocation.protocolVersion == pairing.protocolVersion,
              revocation.pairingID == pairing.pairingID,
              revocation.pairingGeneration == pairing.generation,
              revocation.revocationSequence == 1,
              revocation.issuer == pairing.controller.publicKeyFingerprint
        else { throw TransportContractError.invalidRevocation }
        try revocation.verify(using: publicKeys.controller)
        revoked = true
    }

    public func snapshot() -> TransportRunChannelSnapshot {
        TransportRunChannelSnapshot(
            pairingID: pairing.pairingID,
            pairingGeneration: pairing.generation,
            runID: runID,
            ownerExecutionNodeID: ownerExecutionNodeID,
            highestAcceptedRequestSequence: highestRequestSequence,
            highestAcceptedEventSequence: highestEventSequence,
            highestAcknowledgedRequestSequence: highestAcknowledgedRequestSequence,
            highestAcknowledgedEventSequence: highestAcknowledgedEventSequence,
            retainedReplayEventCount: replayWindow.count,
            isRevoked: revoked
        )
    }

    private func validateCommon(
        protocolVersion: AgentTransportProtocolVersion,
        pairingID: TransportPairingID,
        pairingGeneration: UInt64,
        runID: RunID,
        executionNodeID: ExecutionNodeID
    ) throws {
        guard protocolVersion == pairing.protocolVersion,
              pairingID == pairing.pairingID,
              pairingGeneration == pairing.generation
        else { throw TransportContractError.invalidPairing }
        guard runID == self.runID else { throw TransportContractError.runMismatch }
        guard executionNodeID == ownerExecutionNodeID else {
            throw TransportContractError.ownershipMismatch
        }
    }

    private func validate(_ cursor: TransportReconnectCursor) throws {
        guard cursor.protocolVersion == pairing.protocolVersion,
              cursor.pairingID == pairing.pairingID,
              cursor.pairingGeneration == pairing.generation,
              cursor.runID == runID,
              cursor.executionNodeID == ownerExecutionNodeID
        else { throw TransportContractError.invalidCursor }
    }

    private func nextSequence(after highest: UInt64) throws -> UInt64 {
        guard highest < UInt64.max else {
            throw TransportContractError.sequenceExhausted
        }
        return highest + 1
    }

    private func replayEvents(after acknowledged: UInt64) throws
        -> [WorkerEventEnvelope]
    {
        guard acknowledged < highestEventSequence else { return [] }
        let required = acknowledged + 1
        guard let earliest = replayWindow.first?.envelope.sequence.rawValue,
              earliest <= required
        else {
            throw TransportContractError.replayWindowExceeded(
                earliestAvailable: replayWindow.first?.envelope.sequence.rawValue
                    ?? highestEventSequence
            )
        }
        return replayWindow.compactMap { entry in
            entry.envelope.sequence.rawValue > acknowledged
                ? entry.envelope
                : nil
        }
    }
}
