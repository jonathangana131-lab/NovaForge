import Foundation
import XCTest
@testable import Forge3DKit

final class Forge3DV14HardeningTests: XCTestCase {
    private let blueprint = Forge3DBlueprint(name: "Road Lab", slug: "road-lab")

    func testDecodedBlueprintReentersValidation() throws {
        let data = try JSONEncoder().encode(blueprint)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["fieldOfViewDegrees"] = 120
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(Forge3DBlueprint.self, from: tampered)) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
    }

    func testDecodedBlueprintCanRecoverDefaultPersistenceKeyWhenFieldIsAbsent() throws {
        let data = try JSONEncoder().encode(blueprint)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "persistenceKey")
        let legacyCompatible = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(Forge3DBlueprint.self, from: legacyCompatible)
        XCTAssertEqual(decoded.persistenceKey, "novaforge.road-lab.3d.save.v1")
        try Forge3DBlueprintValidator.validate(decoded)
    }

    func testGeneratedProjectDeclaresCanonicalSemanticAutomationSurface() throws {
        let project = try Forge3DGenerator.generate(blueprint)
        XCTAssertEqual(project.semanticAutomationCapabilities, [.activateControl, .setActionValue])

        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        XCTAssertTrue(html.contains("data-novaforge-control=\"pause\""))
        XCTAssertTrue(html.contains("data-novaforge-action=\"drive-throttle\""))
        XCTAssertTrue(html.contains("data-novaforge-action=\"drive-steering\""))
    }

    func testGeneratedKeyboardHandlerProtectsNativeAssistiveRanges() throws {
        let js = try generatedJavaScript()
        XCTAssertTrue(js.contains("function isNativeDrivingControl(target)"))
        XCTAssertTrue(js.contains("if (isNativeDrivingControl(event.target)) return"))
        XCTAssertTrue(js.contains("accessibleThrottle.addEventListener(\"novaforge:action\""))
        XCTAssertTrue(js.contains("accessibleSteer.addEventListener(\"novaforge:action\""))
        XCTAssertTrue(js.contains("detail.actionID !== expectedActionID"))
        XCTAssertTrue(js.contains("!Number.isFinite(detail.value)"))
        XCTAssertTrue(js.contains("return clamp(detail.value, -1, 1)"))
    }

    #if os(macOS) || os(Linux)
    func testGeneratedJavaScriptPassesNodeSyntaxCheckWhenNodeIsAvailable() throws {
        try requireNode()
        let url = try writeTemporaryJavaScript(try generatedJavaScript(), label: "syntax")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try runNode(arguments: ["--check", url.path])
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testGeneratedInputScriptPassesDeterministicNodeSemanticSmokeWhenNodeIsAvailable() throws {
        try requireNode()
        let harness = #"""
        const __windowListeners = {};
        const __documentListeners = {};

        function makeElement(id) {
          const listeners = {};
          return {
            id,
            type: "",
            value: "0",
            hidden: false,
            disabled: false,
            textContent: "",
            width: 960,
            height: 540,
            clientWidth: 960,
            clientHeight: 540,
            style: {},
            addEventListener(type, callback) { (listeners[type] ||= []).push(callback); },
            setAttribute() {},
            setPointerCapture() {},
            getBoundingClientRect() { return { left: 0, top: 0, width: 132, height: 132 }; },
            __listeners: listeners
          };
        }

        const __gl = {
          VERTEX_SHADER: 1,
          FRAGMENT_SHADER: 2,
          COMPILE_STATUS: 3,
          LINK_STATUS: 4,
          ARRAY_BUFFER: 5,
          STATIC_DRAW: 6,
          createShader() { return {}; },
          shaderSource() {},
          compileShader() {},
          getShaderParameter() { return true; },
          getShaderInfoLog() { return ""; },
          deleteShader() {},
          createProgram() { return {}; },
          attachShader() {},
          linkProgram() {},
          deleteProgram() {},
          getProgramParameter() { return true; },
          getProgramInfoLog() { return ""; },
          getAttribLocation() { return 0; },
          getUniformLocation() { return {}; },
          createBuffer() { return {}; },
          bindBuffer() {},
          bufferData() {}
        };

        const __elements = Object.fromEntries(
          ["scene", "status", "pause", "joystick", "joystick-knob", "accessible-throttle", "accessible-steer"]
            .map(id => [id, makeElement(id)])
        );
        __elements.scene.getContext = () => __gl;
        __elements["accessible-throttle"].type = "range";
        __elements["accessible-steer"].type = "range";

        globalThis.document = {
          hidden: false,
          getElementById(id) { return __elements[id]; },
          addEventListener(type, callback) { (__documentListeners[type] ||= []).push(callback); }
        };
        globalThis.localStorage = { getItem() { return null; }, setItem() {} };
        globalThis.navigator = { getGamepads() { return []; } };
        globalThis.location = { reload() {} };
        globalThis.requestAnimationFrame = () => 1;
        globalThis.window = {
          devicePixelRatio: 1,
          matchMedia() { return { matches: false }; },
          addEventListener(type, callback) { (__windowListeners[type] ||= []).push(callback); }
        };

        function __emitElement(element, type, event = {}) {
          for (const callback of element.__listeners[type] || []) callback(event);
        }
        function __emitWindow(type, event = {}) {
          for (const callback of __windowListeners[type] || []) callback(event);
        }
        """#
        let assertions = #"""
        let prevented = false;
        __emitWindow("keydown", {
          target: accessibleThrottle,
          code: "ArrowUp",
          repeat: false,
          preventDefault() { prevented = true; }
        });
        if (prevented) throw new Error("Assistive range Arrow key was prevented by global driving shortcuts");
        if (input.keyThrottle !== 0) throw new Error("Assistive range Arrow key leaked into game throttle");

        accessibleThrottle.value = "0.7";
        __emitElement(accessibleThrottle, "input");
        if (Math.abs(input.accessibleThrottle - 0.7) > 0.0001) {
          throw new Error("Native assistive throttle input did not update semantic throttle");
        }

        __emitElement(accessibleThrottle, "novaforge:action", {
          detail: { actionID: "drive-throttle", value: 3 }
        });
        if (input.accessibleThrottle !== 1 || accessibleThrottle.value !== "1") {
          throw new Error("Canonical throttle action was not clamped into the shared input state");
        }

        __emitElement(accessibleSteer, "novaforge:action", {
          detail: { actionID: "drive-steering", value: -0.65 }
        });
        if (Math.abs(input.accessibleSteer + 0.65) > 0.0001 || accessibleSteer.value !== "-0.65") {
          throw new Error("Canonical steering action did not update the shared input state");
        }

        const throttleBeforeInvalid = input.accessibleThrottle;
        __emitElement(accessibleThrottle, "novaforge:action", {
          detail: { actionID: "wrong-target", value: -1 }
        });
        if (input.accessibleThrottle !== throttleBeforeInvalid) {
          throw new Error("Mismatched semantic action ID mutated throttle");
        }
        __emitElement(accessibleThrottle, "novaforge:action", {
          detail: { actionID: "drive-throttle", value: NaN }
        });
        if (input.accessibleThrottle !== throttleBeforeInvalid) {
          throw new Error("Non-finite semantic value mutated throttle");
        }

        prevented = false;
        __emitWindow("keydown", {
          target: {},
          code: "ArrowUp",
          repeat: false,
          preventDefault() { prevented = true; }
        });
        if (!prevented) throw new Error("Game Arrow key did not retain page-scroll suppression");
        if (input.keyThrottle !== 1) throw new Error("Game Arrow key did not drive keyboard throttle");
        __emitWindow("keyup", { target: {}, code: "ArrowUp" });
        if (input.keyThrottle !== 0) throw new Error("Game Arrow key release did not clear keyboard throttle");

        console.log("forge3d-semantic-smoke-ok");
        """#

        let url = try writeTemporaryJavaScript(harness + "\n" + (try generatedJavaScript()) + "\n" + assertions, label: "semantic")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try runNode(arguments: [url.path])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("forge3d-semantic-smoke-ok"), result.output)
    }
    #endif

    private func generatedJavaScript() throws -> String {
        try XCTUnwrap(
            Forge3DGenerator.generate(blueprint).files.first(where: { $0.path == "game.js" })?.contents
        )
    }

    #if os(macOS) || os(Linux)
    private func requireNode() throws {
        let result = try runNode(arguments: ["--version"])
        guard result.status == 0 else { throw XCTSkip("Node is unavailable on this SwiftPM host") }
    }

    private func writeTemporaryJavaScript(_ contents: String, label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaforge-forge3d-\(label)-\(UUID().uuidString)")
            .appendingPathExtension("js")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runNode(arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node"] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }
    #endif
}
