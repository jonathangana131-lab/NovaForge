import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeWebSemanticAutomationTests: XCTestCase {
    func testBootstrapDefinesStableSemanticDOMContract() {
        let script = ForgeRuntimeWebSemanticAutomationAdapter.bootstrapJavaScript

        XCTAssertTrue(script.contains(ForgeRuntimeWebSemanticContract.controlAttribute))
        XCTAssertTrue(script.contains(ForgeRuntimeWebSemanticContract.textInputAttribute))
        XCTAssertTrue(script.contains(ForgeRuntimeWebSemanticContract.actionAttribute))
        XCTAssertTrue(script.contains(ForgeRuntimeWebSemanticContract.gestureAttribute))
        XCTAssertTrue(script.contains(ForgeRuntimeWebSemanticContract.actionEventName))
        XCTAssertTrue(script.contains(ForgeRuntimeWebSemanticContract.gestureEventName))
        XCTAssertTrue(script.contains("configurable: false"))
        XCTAssertTrue(script.contains("writable: false"))
    }

    func testDispatchPlanBase64EncodesTextInsteadOfInterpolatingPageScript() throws {
        let maliciousText = "\"; window.pwned = true; //\n</script>🚗"
        let authorized = try authorize(
            kind: .enterText,
            targetID: "profile/name",
            text: maliciousText,
            capabilities: [.enterText]
        )
        let adapter = ForgeRuntimeWebSemanticAutomationAdapter()

        let first = try adapter.makeDispatchPlan(for: authorized)
        let second = try adapter.makeDispatchPlan(for: authorized)

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.javaScript.contains(maliciousText))
        let command = try decodedCommand(from: first.javaScript)
        XCTAssertEqual(command["requestID"] as? String, authorized.request.requestID)
        XCTAssertEqual(command["sessionID"] as? String, authorized.request.sessionID)
        XCTAssertEqual(command["projectID"] as? String, authorized.request.projectID)
        XCTAssertEqual(command["checkpointID"] as? String, authorized.request.checkpointID)
        XCTAssertEqual(command["kind"] as? String, "text.enter")
        XCTAssertEqual(command["targetID"] as? String, "profile/name")
        XCTAssertEqual(command["text"] as? String, maliciousText)
    }

    func testRestartNeverBecomesPageJavaScript() throws {
        let authorized = try authorize(kind: .restartRuntime, capabilities: [.restartRuntime])
        let adapter = ForgeRuntimeWebSemanticAutomationAdapter()

        XCTAssertThrowsError(try adapter.makeDispatchPlan(for: authorized)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeWebSemanticAutomationError,
                .hostLifecycleInteractionRequired
            )
        }
    }

    func testBridgeResultMapsOnlyPageLevelDeliveryDispositions() throws {
        let authorized = try authorize(
            kind: .activateControl,
            targetID: "menu/play",
            capabilities: [.activateControl]
        )
        let adapter = ForgeRuntimeWebSemanticAutomationAdapter()

        for (raw, expected) in [
            ("delivered", ForgeRuntimeSemanticInteractionDisposition.delivered),
            ("targetUnavailable", .targetUnavailable),
            ("unsupportedByProject", .unsupportedByProject),
        ] {
            let json = try bridgeResultJSON(for: authorized, disposition: raw)
            let receipt = try adapter.receipt(for: authorized, bridgeResultJSON: json)
            XCTAssertEqual(receipt.disposition, expected)
            XCTAssertEqual(receipt.requestID, authorized.request.requestID)
            XCTAssertEqual(receipt.sequence, authorized.request.sequence)
        }
    }

    func testBridgeCannotManufactureHostRuntimeUnavailableDisposition() throws {
        let authorized = try authorize(
            kind: .activateControl,
            targetID: "menu/play",
            capabilities: [.activateControl]
        )
        let adapter = ForgeRuntimeWebSemanticAutomationAdapter()
        let json = try bridgeResultJSON(for: authorized, disposition: "runtimeUnavailable")

        XCTAssertThrowsError(try adapter.receipt(for: authorized, bridgeResultJSON: json)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeWebSemanticAutomationError,
                .unsupportedDisposition("runtimeUnavailable")
            )
        }
    }

    func testStaleOrRetargetedBridgeResultCannotAttachToAuthorizedRequest() throws {
        let authorized = try authorize(
            kind: .setActionValue,
            targetID: "drive/steer",
            value: 0.75,
            capabilities: [.setActionValue]
        )
        let adapter = ForgeRuntimeWebSemanticAutomationAdapter()

        let mutations: [(String, Any)] = [
            ("protocolVersion", 99),
            ("requestID", "other-request"),
            ("sessionID", "other-session"),
            ("projectID", "other-project"),
            ("checkpointID", "checkpoint:stale"),
            ("sequence", 7),
            ("kind", "gesture.perform"),
        ]

        for (key, value) in mutations {
            var object = try bridgeResultObject(for: authorized, disposition: "delivered")
            object[key] = value
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertThrowsError(try adapter.receipt(for: authorized, bridgeResultJSON: json)) { error in
                XCTAssertEqual(
                    error as? ForgeRuntimeWebSemanticAutomationError,
                    .resultIdentityMismatch,
                    "mutation key: \(key)"
                )
            }
        }
    }

    func testMissingOrInvalidBridgeResponseFailsClosed() throws {
        let authorized = try authorize(
            kind: .activateControl,
            targetID: "menu/play",
            capabilities: [.activateControl]
        )
        let adapter = ForgeRuntimeWebSemanticAutomationAdapter()

        XCTAssertThrowsError(
            try adapter.receipt(
                for: authorized,
                bridgeResultJSON: "__NOVAFORGE_SEMANTIC_BRIDGE_UNAVAILABLE__"
            )
        ) { error in
            XCTAssertEqual(error as? ForgeRuntimeWebSemanticAutomationError, .bridgeUnavailable)
        }

        for invalid in ["__NOVAFORGE_INVALID_SEMANTIC_COMMAND__", "not-json", "{}"] {
            XCTAssertThrowsError(try adapter.receipt(for: authorized, bridgeResultJSON: invalid)) { error in
                XCTAssertEqual(error as? ForgeRuntimeWebSemanticAutomationError, .invalidBridgeResult)
            }
        }
    }

    func testOversizedBridgeResultFailsBeforeDecode() throws {
        let authorized = try authorize(
            kind: .activateControl,
            targetID: "menu/play",
            capabilities: [.activateControl]
        )
        let adapter = ForgeRuntimeWebSemanticAutomationAdapter()
        let oversized = String(
            repeating: "x",
            count: ForgeRuntimeWebSemanticAutomationAdapter.maximumBridgeResultUTF8Bytes + 1
        )

        XCTAssertThrowsError(try adapter.receipt(for: authorized, bridgeResultJSON: oversized)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeWebSemanticAutomationError,
                .resultTooLarge(
                    actualBytes: ForgeRuntimeWebSemanticAutomationAdapter.maximumBridgeResultUTF8Bytes + 1,
                    maximumBytes: ForgeRuntimeWebSemanticAutomationAdapter.maximumBridgeResultUTF8Bytes
                )
            )
        }
    }

    func testActionAndGesturePayloadsRetainValidatedSemanticFields() throws {
        let adapter = ForgeRuntimeWebSemanticAutomationAdapter()
        let action = try authorize(
            requestID: "req-action",
            kind: .setActionValue,
            targetID: "drive/throttle",
            value: 0.625,
            capabilities: [.setActionValue]
        )
        let gesture = try authorize(
            requestID: "req-gesture",
            kind: .performGesture,
            targetID: "world/camera",
            gestureID: "swipe.left",
            durationMilliseconds: 240,
            capabilities: [.performGesture]
        )

        let actionCommand = try decodedCommand(from: adapter.makeDispatchPlan(for: action).javaScript)
        XCTAssertEqual(actionCommand["targetID"] as? String, "drive/throttle")
        XCTAssertEqual(actionCommand["value"] as? Double, 0.625)

        let gestureCommand = try decodedCommand(from: adapter.makeDispatchPlan(for: gesture).javaScript)
        XCTAssertEqual(gestureCommand["targetID"] as? String, "world/camera")
        XCTAssertEqual(gestureCommand["gestureID"] as? String, "swipe.left")
        XCTAssertEqual(gestureCommand["durationMilliseconds"] as? Int, 240)
    }

    private func authorize(
        requestID: String = "req-1",
        kind: ForgeRuntimeSemanticInteractionKind,
        targetID: String? = nil,
        value: Double? = nil,
        text: String? = nil,
        gestureID: String? = nil,
        durationMilliseconds: Int? = nil,
        capabilities: Set<ForgeRuntimeAutomationCapability>
    ) throws -> ForgeRuntimeAuthorizedSemanticInteraction {
        let policy = try ForgeRuntimeAutomationPolicy(allowedCapabilities: capabilities)
        let session = try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: launchAuthorization(),
            sessionID: "session-1",
            checkpointID: "checkpoint:abc123",
            requestedCapabilities: capabilities,
            policy: policy
        )
        let envelope = ForgeRuntimeSemanticInteractionEnvelope(
            requestID: requestID,
            sessionID: session.sessionID,
            projectID: session.projectID,
            checkpointID: session.checkpointID,
            sequence: 0,
            kind: kind.rawValue,
            targetID: targetID,
            value: value,
            text: text,
            gestureID: gestureID,
            durationMilliseconds: durationMilliseconds
        )
        let data = try JSONEncoder().encode(envelope)
        var gate = ForgeRuntimeSemanticInteractionGate(session: session)
        return try gate.authorize(data)
    }

    private func launchAuthorization() -> ForgeRuntimeLaunchAuthorization {
        ForgeRuntimeLaunchAuthorization(
            projectID: "neon-racer",
            runtimeVersion: .init(major: 1, minor: 0),
            entryPoint: "index.html",
            presentation: .init(),
            storage: .init(namespace: "neon-racer", schemaVersion: 1, quotaBytes: 1_048_576),
            grantedCapabilityIDs: [],
            network: .init(mode: .denied, allowedHosts: []),
            modules: []
        )
    }

    private func decodedCommand(from script: String) throws -> [String: Any] {
        let prefix = "return bridge.dispatchEncoded('"
        let suffix = "');"
        let prefixRange = try XCTUnwrap(script.range(of: prefix))
        let searchRange = prefixRange.upperBound..<script.endIndex
        let suffixRange = try XCTUnwrap(script.range(of: suffix, range: searchRange))
        let base64 = String(script[prefixRange.upperBound..<suffixRange.lowerBound])
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func bridgeResultObject(
        for authorized: ForgeRuntimeAuthorizedSemanticInteraction,
        disposition: String
    ) throws -> [String: Any] {
        let request = authorized.request
        return [
            "protocolVersion": request.protocolVersion,
            "requestID": request.requestID,
            "sessionID": request.sessionID,
            "projectID": request.projectID,
            "checkpointID": request.checkpointID,
            "sequence": request.sequence,
            "kind": request.interaction.kind.rawValue,
            "disposition": disposition,
        ]
    }

    private func bridgeResultJSON(
        for authorized: ForgeRuntimeAuthorizedSemanticInteraction,
        disposition: String
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: bridgeResultObject(for: authorized, disposition: disposition),
            options: [.sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
