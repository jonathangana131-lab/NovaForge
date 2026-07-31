import AgentDomain
import AgentTransport
import CryptoKit
import Foundation
import XCTest

final class AgentTransportContractTests: XCTestCase {
    func testPairingBindsDistinctNodesAndPublicKeyFingerprints() throws {
        let fixture = try Fixture()

        XCTAssertEqual(
            TransportPublicKeyFingerprint(publicKey: fixture.controllerPublicKey),
            fixture.pairing.controller.publicKeyFingerprint
        )
        XCTAssertThrowsError(try TransportPublicKeyFingerprint(
            rawValue: "sha256:" + String(repeating: "A", count: 64)
        ))
        XCTAssertThrowsError(try TransportPairingPublicKeys(
            pairing: fixture.pairing,
            controller: fixture.workerPublicKey,
            worker: fixture.controllerPublicKey
        ))

        let collidingWorker = TransportPeerIdentity(
            role: .worker,
            executionNodeID: fixture.controllerNodeID,
            publicKeyFingerprint: fixture.pairing.worker.publicKeyFingerprint
        )
        XCTAssertThrowsError(try TransportPairingIdentity(
            pairingID: fixture.pairing.pairingID,
            generation: 1,
            controller: fixture.pairing.controller,
            worker: collidingWorker
        ))
    }

    func testCanonicalRequestRoundTripsAndTamperingInvalidatesSignature() async throws {
        let fixture = try Fixture()
        let request = try fixture.request(sequence: 1, cursor: 0)
        let encoded = try TransportWireCodec.encode(request)
        let decoded = try TransportWireCodec.decodeRequest(encoded)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(try TransportWireCodec.encode(decoded), encoded)

        let tampered = try WorkerRequestEnvelope(
            protocolVersion: request.protocolVersion,
            pairingID: request.pairingID,
            pairingGeneration: request.pairingGeneration,
            runID: request.runID,
            commandID: request.commandID,
            executionNodeID: request.executionNodeID,
            signer: request.signer,
            sequence: request.sequence,
            reconnectCursor: request.reconnectCursor,
            issuedAt: request.issuedAt,
            payload: try BoundedTransportPayload(.object(["kind": .string("changed")])),
            signature: request.signature
        )
        let channel = try fixture.channel()
        await assertThrows(
            try await channel.admit(tampered),
            equals: TransportContractError.signatureInvalid
        )

        XCTAssertThrowsError(try WorkerRequestEnvelope.signed(
            pairing: fixture.pairing,
            runID: fixture.runID,
            commandID: CommandID(rawValue: fixture.uuid(40)),
            sequence: try TransportMessageSequence(rawValue: 1),
            reconnectCursor: try fixture.cursor(0),
            issuedAt: fixture.instant,
            payload: fixture.payload,
            privateKey: fixture.workerPrivateKey
        )) { error in
            XCTAssertEqual(error as? TransportContractError, .signerMismatch)
        }
    }

    func testMonotonicSequencesRejectDuplicatesGapsAndInvalidAcknowledgements() async throws {
        let fixture = try Fixture()
        let channel = try fixture.channel()
        _ = try await channel.admit(fixture.request(sequence: 1, cursor: 0))

        await assertThrows(
            try await channel.admit(fixture.request(sequence: 1, cursor: 0)),
            equals: TransportContractError.duplicateRequest(sequence: 1)
        )
        await assertThrows(
            try await channel.admit(fixture.request(sequence: 3, cursor: 0)),
            equals: TransportContractError.requestGap(expected: 2, received: 3)
        )

        try await channel.admit(fixture.event(sequence: 1, acknowledgesRequest: 1))
        await assertThrows(
            try await channel.admit(fixture.event(sequence: 1, acknowledgesRequest: 1)),
            equals: TransportContractError.duplicateEvent(sequence: 1)
        )
        await assertThrows(
            try await channel.admit(fixture.event(sequence: 3, acknowledgesRequest: 1)),
            equals: TransportContractError.eventGap(expected: 2, received: 3)
        )
        await assertThrows(
            try await channel.admit(fixture.event(sequence: 2, acknowledgesRequest: 0)),
            equals: TransportContractError.acknowledgementRegression(
                previous: 1,
                received: 0
            )
        )
        await assertThrows(
            try await channel.admit(fixture.request(sequence: 2, cursor: 2)),
            equals: TransportContractError.acknowledgementAhead(
                maximum: 1,
                received: 2
            )
        )

        let accepted = try await channel.admit(fixture.request(sequence: 2, cursor: 1))
        XCTAssertTrue(accepted.replayedEvents.isEmpty)
        let snapshot = await channel.snapshot()
        XCTAssertEqual(snapshot.highestAcceptedRequestSequence, 2)
        XCTAssertEqual(snapshot.highestAcceptedEventSequence, 1)
        XCTAssertEqual(snapshot.highestAcknowledgedEventSequence, 1)
    }

    func testReconnectCursorReplaysRetainedEventsAndFailsWhenWindowExpired() async throws {
        let fixture = try Fixture()
        let replayLimits = TransportReplayWindowLimits(
            maximumEventCount: 2,
            maximumEncodedBytes: 2_000_000
        )
        let channel = try fixture.channel(replayLimits: replayLimits)
        _ = try await channel.admit(fixture.request(sequence: 1, cursor: 0))
        try await channel.admit(fixture.event(sequence: 1, acknowledgesRequest: 1))
        try await channel.admit(fixture.event(sequence: 2, acknowledgesRequest: 1))
        try await channel.admit(fixture.event(sequence: 3, acknowledgesRequest: 1))

        let replay = try await channel.admit(fixture.request(sequence: 2, cursor: 1))
        XCTAssertEqual(replay.replayedEvents.map(\.sequence.rawValue), [2, 3])

        let expired = try fixture.channel(replayLimits: replayLimits)
        _ = try await expired.admit(fixture.request(sequence: 1, cursor: 0))
        try await expired.admit(fixture.event(sequence: 1, acknowledgesRequest: 1))
        try await expired.admit(fixture.event(sequence: 2, acknowledgesRequest: 1))
        try await expired.admit(fixture.event(sequence: 3, acknowledgesRequest: 1))
        await assertThrows(
            try await expired.admit(fixture.request(sequence: 2, cursor: 0)),
            equals: TransportContractError.replayWindowExceeded(
                earliestAvailable: 2
            )
        )
    }

    func testRunAndExecutionOwnershipAreFrozen() async throws {
        let fixture = try Fixture()
        let request = try fixture.request(sequence: 1, cursor: 0)

        let wrongOwner = try WorkerRequestEnvelope(
            protocolVersion: request.protocolVersion,
            pairingID: request.pairingID,
            pairingGeneration: request.pairingGeneration,
            runID: request.runID,
            commandID: request.commandID,
            executionNodeID: ExecutionNodeID(rawValue: fixture.uuid(99)),
            signer: request.signer,
            sequence: request.sequence,
            reconnectCursor: request.reconnectCursor,
            issuedAt: request.issuedAt,
            payload: request.payload,
            signature: request.signature
        )
        await assertThrows(
            try await fixture.channel().admit(wrongOwner),
            equals: TransportContractError.ownershipMismatch
        )

        let wrongRun = try WorkerRequestEnvelope(
            protocolVersion: request.protocolVersion,
            pairingID: request.pairingID,
            pairingGeneration: request.pairingGeneration,
            runID: RunID(rawValue: fixture.uuid(98)),
            commandID: request.commandID,
            executionNodeID: request.executionNodeID,
            signer: request.signer,
            sequence: request.sequence,
            reconnectCursor: request.reconnectCursor,
            issuedAt: request.issuedAt,
            payload: request.payload,
            signature: request.signature
        )
        await assertThrows(
            try await fixture.channel().admit(wrongRun),
            equals: TransportContractError.runMismatch
        )
    }

    func testControllerSignedRevocationPermanentlyClosesChannel() async throws {
        let fixture = try Fixture()
        let channel = try fixture.channel()
        let revocation = try TransportPairingRevocation.signed(
            pairing: fixture.pairing,
            issuedAt: fixture.instant,
            reason: .userRequested,
            privateKey: fixture.controllerPrivateKey
        )
        try await channel.revoke(revocation)
        let snapshot = await channel.snapshot()
        XCTAssertTrue(snapshot.isRevoked)

        await assertThrows(
            try await channel.admit(fixture.request(sequence: 1, cursor: 0)),
            equals: TransportContractError.pairingRevoked
        )
        await assertThrows(
            try await channel.revoke(revocation),
            equals: TransportContractError.duplicateRevocation
        )
    }

    func testPayloadAndWireBoundsFailWithoutLeakingRejectedContent() throws {
        let secret = "api-key-secret/Users/private/workspace"
        let limits = TransportPayloadLimits(
            maximumEncodedBytes: 64,
            maximumNodeCount: 4,
            maximumContainerDepth: 2,
            maximumObjectEntryCount: 2,
            maximumArrayElementCount: 2,
            maximumStringBytes: 8,
            maximumObjectKeyBytes: 8
        )
        XCTAssertThrowsError(try BoundedTransportPayload(
            .string(secret),
            limits: limits
        )) { error in
            XCTAssertEqual(
                error as? TransportPayloadValidationError,
                .limitExceeded(limit: .stringBytes, maximum: 8, actual: 38)
            )
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
        }

        let deeplyNested = JSONValue.array([.array([.array([.null])])])
        XCTAssertThrowsError(try BoundedTransportPayload(
            deeplyNested,
            limits: limits
        )) { error in
            XCTAssertEqual(
                error as? TransportPayloadValidationError,
                .limitExceeded(limit: .containerDepth, maximum: 2, actual: 3)
            )
        }

        let hostileWire = Data(String(repeating: "[", count: 41).utf8)
            + Data(String(repeating: "]", count: 41).utf8)
        XCTAssertThrowsError(try TransportWireCodec.decodeEvent(hostileWire)) { error in
            XCTAssertEqual(
                error as? TransportWireValidationError,
                .structuralDepthExceeded(maximum: 40)
            )
        }
    }
}

private struct Fixture {
    let controllerPrivateKey: Curve25519.Signing.PrivateKey
    let workerPrivateKey: Curve25519.Signing.PrivateKey
    let controllerPublicKey: TransportSigningPublicKey
    let workerPublicKey: TransportSigningPublicKey
    let controllerNodeID: ExecutionNodeID
    let workerNodeID: ExecutionNodeID
    let pairing: TransportPairingIdentity
    let publicKeys: TransportPairingPublicKeys
    let runID: RunID
    let instant = AgentInstant(rawValue: 1_752_500_000_000)
    let payload: BoundedTransportPayload

    init() throws {
        controllerPrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x11, count: 32)
        )
        workerPrivateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x22, count: 32)
        )
        controllerPublicKey = try TransportSigningPublicKey(
            controllerPrivateKey.publicKey
        )
        workerPublicKey = try TransportSigningPublicKey(workerPrivateKey.publicKey)
        controllerNodeID = ExecutionNodeID(rawValue: Self.uuid(1))
        workerNodeID = ExecutionNodeID(rawValue: Self.uuid(2))
        pairing = try TransportPairingIdentity(
            pairingID: TransportPairingID(rawValue: Self.uuid(3)),
            generation: 7,
            controller: TransportPeerIdentity(
                role: .controller,
                executionNodeID: controllerNodeID,
                publicKeyFingerprint: TransportPublicKeyFingerprint(
                    publicKey: controllerPublicKey
                )
            ),
            worker: TransportPeerIdentity(
                role: .worker,
                executionNodeID: workerNodeID,
                publicKeyFingerprint: TransportPublicKeyFingerprint(
                    publicKey: workerPublicKey
                )
            )
        )
        publicKeys = try TransportPairingPublicKeys(
            pairing: pairing,
            controller: controllerPublicKey,
            worker: workerPublicKey
        )
        runID = RunID(rawValue: Self.uuid(4))
        payload = try BoundedTransportPayload(.object([
            "kind": .string("execute"),
            "value": .number(.integer(1)),
        ]))
    }

    func channel(
        replayLimits: TransportReplayWindowLimits = .production
    ) throws -> TransportRunChannel {
        try TransportRunChannel(
            pairing: pairing,
            publicKeys: publicKeys,
            runID: runID,
            ownerExecutionNodeID: workerNodeID,
            replayLimits: replayLimits
        )
    }

    func cursor(_ sequence: UInt64) throws -> TransportReconnectCursor {
        try TransportReconnectCursor(
            protocolVersion: pairing.protocolVersion,
            pairingID: pairing.pairingID,
            pairingGeneration: pairing.generation,
            runID: runID,
            executionNodeID: workerNodeID,
            lastAcceptedEventSequence: sequence
        )
    }

    func request(sequence: UInt64, cursor: UInt64) throws -> WorkerRequestEnvelope {
        try WorkerRequestEnvelope.signed(
            pairing: pairing,
            runID: runID,
            commandID: CommandID(rawValue: uuid(10 + sequence)),
            sequence: TransportMessageSequence(rawValue: sequence),
            reconnectCursor: self.cursor(cursor),
            issuedAt: instant,
            payload: payload,
            privateKey: controllerPrivateKey
        )
    }

    func event(
        sequence: UInt64,
        acknowledgesRequest: UInt64
    ) throws -> WorkerEventEnvelope {
        try WorkerEventEnvelope.signed(
            pairing: pairing,
            runID: runID,
            eventID: EventID(rawValue: uuid(20 + sequence)),
            sequence: TransportMessageSequence(rawValue: sequence),
            acknowledgesRequestThrough: acknowledgesRequest,
            emittedAt: instant,
            payload: payload,
            privateKey: workerPrivateKey
        )
    }

    func uuid(_ suffix: UInt64) -> UUID { Self.uuid(suffix) }

    static func uuid(_ suffix: UInt64) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", suffix))!
    }
}

private extension XCTestCase {
    func assertThrows<T: Equatable>(
        _ expression: @autoclosure () async throws -> Any,
        equals expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? T, expected, file: file, line: line)
        }
    }
}
