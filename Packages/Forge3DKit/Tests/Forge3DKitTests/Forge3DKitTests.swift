import XCTest
@testable import Forge3DKit

final class Forge3DKitTests: XCTestCase {
    private let blueprint = Forge3DBlueprint(name: "Road Lab", slug: "road-lab")

    func testDefaultBlueprintGeneratesDeterministicSelfContainedProject() throws {
        let first = try Forge3DGenerator.generate(blueprint)
        let second = try Forge3DGenerator.generate(blueprint)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.entryPath, "index.html")
        XCTAssertEqual(first.files.map(\.path), ["index.html", "styles.css", "game.js"])
        XCTAssertEqual(first.semanticCapabilities, [.localSave, .controller, .touch, .keyboard, .semanticAutomation])
        XCTAssertEqual(first.semanticAutomation, Forge3DSemanticContract.descriptor)
    }

    func testGeneratedProjectDeniesNetworkAndUsesOnlyLocalAssets() throws {
        let project = try Forge3DGenerator.generate(blueprint)
        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        let js = try XCTUnwrap(project.files.first(where: { $0.path == "game.js" })?.contents)
        XCTAssertTrue(html.contains("connect-src 'none'"))
        XCTAssertTrue(html.contains("src=\"game.js\""))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(js.contains("fetch("))
        XCTAssertFalse(js.contains("WebSocket"))
        XCTAssertFalse(js.contains("import("))
    }

    func testGeneratedSceneIncludesBoundedFixedStepWebGLAndInputSystems() throws {
        let js = try XCTUnwrap(try Forge3DGenerator.generate(blueprint).files.first(where: { $0.path == "game.js" })?.contents)
        XCTAssertTrue(js.contains("canvas.getContext(\"webgl\""))
        XCTAssertTrue(js.contains("step: 1 / 60"))
        XCTAssertTrue(js.contains("while (state.accumulator >= CONFIG.step)"))
        XCTAssertTrue(js.contains("Math.min(window.devicePixelRatio || 1, CONFIG.maxDPR)"))
        XCTAssertTrue(js.contains("navigator.getGamepads"))
        XCTAssertTrue(js.contains("updateJoystick"))
        XCTAssertTrue(js.contains("localStorage.setItem"))
        XCTAssertTrue(js.contains("webglcontextlost"))
        XCTAssertTrue(js.contains("maximumMarkers: 40"))
        XCTAssertTrue(js.contains("input.keyThrottle + input.touchThrottle + input.accessibleThrottle + input.padThrottle"))
        XCTAssertTrue(js.contains("accessible-throttle"))
        XCTAssertTrue(js.contains("accessible-steer"))
        XCTAssertFalse(js.contains("powerPreference: \"high-performance\""))
        XCTAssertFalse(js.contains("Math.random"))
    }

    func testGeneratedControlsRespectSafeAreasAndAccessibilitySemantics() throws {
        let project = try Forge3DGenerator.generate(blueprint)
        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        let css = try XCTUnwrap(project.files.first(where: { $0.path == "styles.css" })?.contents)
        XCTAssertTrue(html.contains("aria-live=\"polite\""))
        XCTAssertTrue(html.contains("aria-label=\"Drive joystick."))
        XCTAssertTrue(html.contains("aria-label=\"Pause scene\""))
        XCTAssertTrue(html.contains("id=\"accessible-throttle\" type=\"range\""))
        XCTAssertTrue(html.contains("id=\"accessible-steer\" type=\"range\""))
        XCTAssertTrue(css.contains("env(safe-area-inset-left)"))
        XCTAssertTrue(css.contains("env(safe-area-inset-bottom)"))
        XCTAssertTrue(css.contains("prefers-reduced-transparency"))
        XCTAssertTrue(css.contains(".assistive-driving"))
    }

    func testGeneratedControlsOptIntoCanonicalRuntimeSemanticAutomation() throws {
        let project = try Forge3DGenerator.generate(blueprint)
        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        let js = try XCTUnwrap(project.files.first(where: { $0.path == "game.js" })?.contents)
        let automation = try XCTUnwrap(project.semanticAutomation)

        XCTAssertEqual(automation.pauseControlID, "scene.pause-toggle")
        XCTAssertEqual(automation.throttleAction.targetID, "drive.throttle")
        XCTAssertEqual(automation.throttleAction.minimumValue, -1)
        XCTAssertEqual(automation.throttleAction.maximumValue, 1)
        XCTAssertEqual(automation.throttleAction.neutralValue, 0)
        XCTAssertEqual(automation.steeringAction.targetID, "drive.steer")
        XCTAssertEqual(automation.steeringAction.minimumValue, -1)
        XCTAssertEqual(automation.steeringAction.maximumValue, 1)
        XCTAssertEqual(automation.steeringAction.neutralValue, 0)

        XCTAssertTrue(html.contains("data-novaforge-control=\"scene.pause-toggle\""))
        XCTAssertTrue(html.contains("data-novaforge-action=\"drive.throttle\""))
        XCTAssertTrue(html.contains("data-novaforge-action=\"drive.steer\""))
        XCTAssertTrue(html.contains("min=\"-1.0\" max=\"1.0\" step=\"0.1\" value=\"0.0\""))
        XCTAssertTrue(js.contains("addEventListener(\"novaforge:action\""))
        XCTAssertTrue(js.contains("event.detail?.actionID !== actionID"))
        XCTAssertTrue(js.contains("bindActionValue(accessibleThrottle, \"drive.throttle\", \"accessibleThrottle\")"))
        XCTAssertTrue(js.contains("bindActionValue(accessibleSteer, \"drive.steer\", \"accessibleSteer\")"))
        XCTAssertTrue(js.contains("Number.isFinite(value) ? clamp(value, -1.0, 1.0) : 0.0"))
    }

    func testSemanticAutomationCapabilityMintingFailsClosedWithoutExactGeneratedContract() throws {
        let generated = try Forge3DGenerator.generate(blueprint)

        let publicConstruction = Forge3DGeneratedProject(
            blueprint: blueprint,
            entryPath: generated.entryPath,
            files: generated.files,
            semanticCapabilities: [.localSave, .semanticAutomation]
        )
        XCTAssertEqual(publicConstruction.semanticCapabilities, [.localSave])
        XCTAssertNil(publicConstruction.semanticAutomation)

        let missingContract = Forge3DGeneratedProject(
            blueprint: blueprint,
            entryPath: "index.html",
            files: [],
            semanticCapabilities: [.localSave, .semanticAutomation],
            semanticAutomation: Forge3DSemanticContract.descriptor
        )
        XCTAssertEqual(missingContract.semanticCapabilities, [.localSave])
        XCTAssertNil(missingContract.semanticAutomation)

        let tamperedFiles = generated.files.map { file in
            guard file.path == "game.js" else { return file }
            return Forge3DGeneratedFile(
                path: file.path,
                contents: file.contents.replacingOccurrences(of: "novaforge:action", with: "tampered:action")
            )
        }
        let tamperedContract = Forge3DGeneratedProject(
            blueprint: blueprint,
            entryPath: generated.entryPath,
            files: tamperedFiles,
            semanticCapabilities: generated.semanticCapabilities,
            semanticAutomation: Forge3DSemanticContract.descriptor
        )
        XCTAssertFalse(tamperedContract.semanticCapabilities.contains(.semanticAutomation))
        XCTAssertNil(tamperedContract.semanticAutomation)
    }

    func testBlueprintRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(blueprint)
        XCTAssertEqual(try JSONDecoder().decode(Forge3DBlueprint.self, from: data), blueprint)
    }

    func testRejectsUnsafeOrOutOfBudgetBlueprints() {
        assertInvalid(Forge3DBlueprint(name: " ", slug: "road"), .invalidName)
        assertInvalid(Forge3DBlueprint(name: "Road", slug: "BAD_slug"), .invalidSlug)
        assertInvalid(Forge3DBlueprint(name: "Road", slug: "road", fieldOfViewDegrees: 120), .invalidFieldOfView)
        assertInvalid(Forge3DBlueprint(name: "Road", slug: "road", worldHalfExtent: 10), .invalidWorldExtent)
        assertInvalid(Forge3DBlueprint(name: "Road", slug: "road", maximumDevicePixelRatio: 3), .invalidRenderBudget)
        assertInvalid(Forge3DBlueprint(name: "Road", slug: "road", topSpeed: .infinity), .invalidTopSpeed)
        assertInvalid(Forge3DBlueprint(name: "Road", slug: "road", acceleration: 0), .invalidAcceleration)
        assertInvalid(Forge3DBlueprint(name: "Road", slug: "road", steeringRate: 5), .invalidSteeringRate)
        assertInvalid(Forge3DBlueprint(name: "Road", slug: "road", persistenceKey: "bad key"), .invalidPersistenceKey)
    }

    func testEscapesUserVisibleTitleAndJavaScriptStorageKeyIsBounded() throws {
        let project = try Forge3DGenerator.generate(Forge3DBlueprint(name: "<Road & Lab>", slug: "road-lab", persistenceKey: "novaforge.road-lab.3d"))
        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        let js = try XCTUnwrap(project.files.first(where: { $0.path == "game.js" })?.contents)
        XCTAssertTrue(html.contains("&lt;Road &amp; Lab&gt;"))
        XCTAssertTrue(js.contains("saveKey: \"novaforge.road-lab.3d\""))
    }

    private func assertInvalid(_ blueprint: Forge3DBlueprint, _ expected: Forge3DBlueprintIssue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Forge3DBlueprintValidator.validate(blueprint), file: file, line: line) { error in
            XCTAssertEqual(error as? Forge3DBlueprintIssue, expected, file: file, line: line)
        }
    }
}
