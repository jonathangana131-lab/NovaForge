import Foundation
import XCTest
@testable import Forge2DKit

final class Forge2DKitTests: XCTestCase {
    private let blueprint = Forge2DBlueprint(name: "Neon Runner", slug: "neon-runner")

    func testDefaultBlueprintGeneratesDeterministicSelfContainedProject() throws {
        let first = try Forge2DGenerator.generate(blueprint)
        let second = try Forge2DGenerator.generate(blueprint)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.entryPath, "index.html")
        XCTAssertEqual(first.files.map(\.path), ["index.html", "styles.css", "game.js"])
        XCTAssertEqual(first.semanticCapabilities, [.localSave, .audio, .controller, .touch, .keyboard])
    }

    func testGeneratedProjectHasNoRemoteImportsOrNetworkAuthority() throws {
        let project = try Forge2DGenerator.generate(blueprint)
        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        let js = try XCTUnwrap(project.files.first(where: { $0.path == "game.js" })?.contents)

        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("src=\"game.js\""))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("user-scalable=no"))
        XCTAssertFalse(js.contains("fetch("))
        XCTAssertFalse(js.contains("XMLHttpRequest"))
        XCTAssertFalse(js.contains("WebSocket"))
        XCTAssertFalse(js.contains("import("))
    }

    func testGeneratedGameIncludesDeterministicFixedStepAndExpectedInteractionSystems() throws {
        let js = try XCTUnwrap(try Forge2DGenerator.generate(blueprint).files.first(where: { $0.path == "game.js" })?.contents)

        XCTAssertTrue(js.contains("step: 1 / 60"))
        XCTAssertTrue(js.contains("while (state.accumulator >= CONFIG.step)"))
        XCTAssertTrue(js.contains("navigator.getGamepads"))
        XCTAssertTrue(js.contains("localStorage.setItem"))
        XCTAssertTrue(js.contains("AudioContext"))
        XCTAssertTrue(js.contains("camera.x"))
        XCTAssertTrue(js.contains("particles.push"))
        XCTAssertTrue(js.contains("setPaused"))
        XCTAssertFalse(js.contains("Math.random"))
    }

    #if os(macOS) || os(Linux)
    func testGeneratedJavaScriptPassesNodeSyntaxCheckWhenNodeIsAvailable() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["node", "--version"]
        probe.standardOutput = Pipe()
        probe.standardError = Pipe()
        try probe.run()
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else {
            throw XCTSkip("Node is unavailable on this SwiftPM host")
        }

        let js = try XCTUnwrap(try Forge2DGenerator.generate(blueprint).files.first(where: { $0.path == "game.js" })?.contents)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaforge-forge2d-\(UUID().uuidString)")
            .appendingPathExtension("js")
        try js.write(to: temporaryURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let check = Process()
        let output = Pipe()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["node", "--check", temporaryURL.path]
        check.standardOutput = output
        check.standardError = output
        try check.run()
        check.waitUntilExit()

        if check.terminationStatus != 0 {
            let diagnostic = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Node syntax check failed"
            XCTFail(diagnostic)
        }
    }
    #endif

    func testGeneratedTouchControlsAreAccessibleLargeAndAssistiveActivatable() throws {
        let project = try Forge2DGenerator.generate(blueprint)
        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        let css = try XCTUnwrap(project.files.first(where: { $0.path == "styles.css" })?.contents)
        let js = try XCTUnwrap(project.files.first(where: { $0.path == "game.js" })?.contents)

        XCTAssertTrue(html.contains("aria-label=\"Move left\""))
        XCTAssertTrue(html.contains("aria-label=\"Move right\""))
        XCTAssertTrue(html.contains("aria-label=\"Jump\""))
        XCTAssertTrue(html.contains("aria-live=\"polite\""))
        XCTAssertTrue(css.contains("width: 68px; height: 68px"))
        XCTAssertTrue(css.contains("prefers-reduced-transparency"))
        XCTAssertTrue(css.contains("prefers-reduced-motion"))
        XCTAssertTrue(css.contains(".controls button:focus-visible"))
        XCTAssertTrue(css.contains("outline-offset: 3px"))
        XCTAssertTrue(css.contains("top: max(14px, env(safe-area-inset-top))"))
        XCTAssertTrue(css.contains("right: max(14px, env(safe-area-inset-right))"))
        XCTAssertFalse(css.contains("body { padding: env(safe-area-inset-top)"))

        XCTAssertTrue(js.contains("const pointerActivationControls = new Set()"))
        XCTAssertTrue(js.contains("button.addEventListener(\"pointerdown\""))
        XCTAssertTrue(js.contains("button.addEventListener(\"pointercancel\""))
        XCTAssertTrue(js.contains("if (pointerActivationControls.delete(button.id)) return"))
        XCTAssertTrue(js.contains("registerAssistiveActivation(controls.left"))
        XCTAssertTrue(js.contains("registerAssistiveActivation(controls.right"))
        XCTAssertTrue(js.contains("registerAssistiveActivation(controls.jump, queueJump)"))
        XCTAssertTrue(js.contains("pulseAssistiveDirection(\"keyboardLeft\", \"left\")"))
        XCTAssertTrue(js.contains("pulseAssistiveDirection(\"keyboardRight\", \"right\")"))
        XCTAssertTrue(js.contains("window.setTimeout"))
        XCTAssertFalse(js.contains("event.detail === 0"))
    }

    func testGeneratedControlsKeepStableRuntimeAutomationSelectors() throws {
        let html = try XCTUnwrap(try Forge2DGenerator.generate(blueprint).files.first(where: { $0.path == "index.html" })?.contents)

        XCTAssertTrue(html.contains("id=\"left\""))
        XCTAssertTrue(html.contains("id=\"right\""))
        XCTAssertTrue(html.contains("id=\"jump\""))
        XCTAssertTrue(html.contains("id=\"pause\""))
    }

    func testBlueprintRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(blueprint)
        XCTAssertEqual(try JSONDecoder().decode(Forge2DBlueprint.self, from: data), blueprint)
    }

    func testDecodedBlueprintReentersValidation() throws {
        let data = try JSONEncoder().encode(blueprint)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["viewportWidth"] = 120
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(Forge2DBlueprint.self, from: tampered)) { error in
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

        let decoded = try JSONDecoder().decode(Forge2DBlueprint.self, from: legacyCompatible)
        XCTAssertEqual(decoded.persistenceKey, "novaforge.neon-runner.save.v1")
        try Forge2DBlueprintValidator.validate(decoded)
    }

    func testRejectsUnsafeOrNonsensicalBlueprints() {
        assertInvalid(Forge2DBlueprint(name: " ", slug: "valid"), .invalidName)
        assertInvalid(Forge2DBlueprint(name: "Game", slug: "Bad_Slug"), .invalidSlug)
        assertInvalid(Forge2DBlueprint(name: "Game", slug: "game", viewportWidth: 200), .invalidViewport)
        assertInvalid(Forge2DBlueprint(name: "Game", slug: "game", worldWidth: 300), .invalidWorld)
        assertInvalid(Forge2DBlueprint(name: "Game", slug: "game", viewportWidth: 1_000, worldWidth: 900), .worldSmallerThanViewport)
        assertInvalid(Forge2DBlueprint(name: "Game", slug: "game", gravity: .infinity), .invalidGravity)
        assertInvalid(Forge2DBlueprint(name: "Game", slug: "game", persistenceKey: "bad key with spaces"), .invalidPersistenceKey)
    }

    func testEscapesUserVisibleTitle() throws {
        let project = try Forge2DGenerator.generate(Forge2DBlueprint(name: "<Race & Run>", slug: "race-run"))
        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        XCTAssertTrue(html.contains("&lt;Race &amp; Run&gt;"))
        XCTAssertFalse(html.contains("<title><Race & Run></title>"))
    }

    private func assertInvalid(_ blueprint: Forge2DBlueprint, _ expected: Forge2DBlueprintIssue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Forge2DBlueprintValidator.validate(blueprint), file: file, line: line) { error in
            XCTAssertEqual(error as? Forge2DBlueprintIssue, expected, file: file, line: line)
        }
    }
}
