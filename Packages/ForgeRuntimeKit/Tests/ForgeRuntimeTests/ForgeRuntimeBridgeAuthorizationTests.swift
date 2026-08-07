import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeBridgeAuthorizationTests: XCTestCase {
    func testKnownOperationMapsToHostOwnedCapabilityAndAuthorizesWhenGranted() throws {
        let request = try decode(.init(requestID: "req-1", operation: "haptics.perform"))
        let authorization = try launchAuthorization(capabilities: [.init(id: "haptics")])

        XCTAssertEqual(request.operation, .performHaptic)
        XCTAssertEqual(request.operation.requiredCapabilityID, "haptics")
        XCTAssertNoThrow(
            try ForgeRuntimeBridgeAuthorizer().authorize(
                request,
                launchAuthorization: authorization
            )
        )
    }

    func testBridgeCannotUseOperationWhenRequiredCapabilityWasNotGranted() throws {
        let request = try decode(.init(requestID: "req-2", operation: "share.present"))
        let authorization = try launchAuthorization(capabilities: [])

        XCTAssertThrowsError(
            try ForgeRuntimeBridgeAuthorizer().authorize(
                request,
                launchAuthorization: authorization
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeBridgeAuthorizationError,
                .capabilityNotGranted(requiredCapabilityID: "share")
            )
        }
    }

    func testStorageReadAndWriteShareSameStorageCapability() {
        XCTAssertEqual(ForgeRuntimeBridgeOperation.readStorage.requiredCapabilityID, "storage")
        XCTAssertEqual(ForgeRuntimeBridgeOperation.writeStorage.requiredCapabilityID, "storage")
    }

    func testUnknownOperationFailsClosedBeforeAuthorization() throws {
        XCTAssertThrowsError(
            try decode(.init(requestID: "req-3", operation: "system.shell"))
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeBridgeRequestError,
                .unknownOperation("system.shell")
            )
        }
    }

    func testUnsupportedBridgeProtocolVersionFailsClosed() throws {
        XCTAssertThrowsError(
            try decode(.init(protocolVersion: 2, requestID: "req-4", operation: "haptics.perform"))
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeBridgeRequestError,
                .unsupportedProtocolVersion(2)
            )
        }
    }

    func testInvalidRequestIDIsRejected() throws {
        for requestID in ["", "has spaces", "../../escape", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(
                try decode(.init(requestID: requestID, operation: "haptics.perform"))
            ) { error in
                XCTAssertEqual(error as? ForgeRuntimeBridgeRequestError, .invalidRequestID)
            }
        }
    }

    func testOversizedBridgeEnvelopeFailsBeforeJSONDecode() {
        let decoder = ForgeRuntimeBridgeRequestDecoder(maximumRequestBytes: 8)
        let data = Data(repeating: 0x20, count: 9)

        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeBridgeRequestError,
                .requestTooLarge(actualBytes: 9, maximumBytes: 8)
            )
        }
    }

    func testMalformedBridgeEnvelopeReturnsSanitizedFailure() {
        XCTAssertThrowsError(try ForgeRuntimeBridgeRequestDecoder().decode(Data("{".utf8))) { error in
            XCTAssertEqual(error as? ForgeRuntimeBridgeRequestError, .invalidJSON)
        }
    }

    private func decode(_ envelope: ForgeRuntimeBridgeRequestEnvelope) throws -> ForgeRuntimeBridgeRequest {
        let data = try JSONEncoder().encode(envelope)
        return try ForgeRuntimeBridgeRequestDecoder().decode(data)
    }

    private func launchAuthorization(
        capabilities: [ForgeCapabilityRequest]
    ) throws -> ForgeRuntimeLaunchAuthorization {
        let manifest = ForgeProjectManifest(
            projectID: "neon-racer",
            projectVersion: "1.0.0",
            display: .init(name: "Neon Racer"),
            storage: .init(namespace: "neon-racer", quotaBytes: 1_048_576),
            capabilities: capabilities
        )
        let requested = Set(capabilities.map(\.id))
        return try ForgeRuntimeManifestValidator().authorize(
            manifest,
            expectedProjectID: "neon-racer",
            host: .init(supportedCapabilityIDs: ["haptics", "share", "storage", "controller"]),
            projectGrant: .init(projectID: "neon-racer", grantedCapabilityIDs: requested)
        )
    }
}
