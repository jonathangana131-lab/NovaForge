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
        XCTAssertEqual(first.semanticCapabilities, [.localSave, .controller, .touch, .keyboard, .automation])
        XCTAssertEqual(first.semanticTargets, Forge3DSemanticTargetCatalog.all)
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
        XCTAssertTrue(js.contains("input.keyThrottle + input.touchThrottle + input.accessibleThrottle + automationInput.throttle + input.padThrottle"))
        XCTAssertTrue(js.contains("input.keySteer + input.touchSteer + input.accessibleSteer + automationInput.steering + input.padSteer"))
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
        XCTAssertTrue(html.contains("id=\"accessible-throttle\" data-novaforge-action=\"drive.throttle\" type=\"range\""))
        XCTAssertTrue(html.contains("id=\"accessible-steer\" data-novaforge-action=\"drive.steering\" type=\"range\""))
        XCTAssertTrue(css.contains("env(safe-area-inset-left)"))
        XCTAssertTrue(css.contains("env(safe-area-inset-bottom)"))
        XCTAssertTrue(css.contains("prefers-reduced-transparency"))
        XCTAssertTrue(css.contains(".assistive-driving"))
    }

    func testGeneratedProjectExposesCanonicalSemanticSelfPlayTargets() throws {
        let project = try Forge3DGenerator.generate(blueprint)
        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        let js = try XCTUnwrap(project.files.first(where: { $0.path == "game.js" })?.contents)

        XCTAssertEqual(project.semanticTargets.map(\.id), ["scene.pause", "drive.throttle", "drive.steering"])
        XCTAssertEqual(Forge3DSemanticTargetCatalog.pause.kind, .control)
        XCTAssertNil(Forge3DSemanticTargetCatalog.pause.minimumValue)
        XCTAssertEqual(Forge3DSemanticTargetCatalog.throttle.kind, .action)
        XCTAssertEqual(Forge3DSemanticTargetCatalog.throttle.minimumValue, -1)
        XCTAssertEqual(Forge3DSemanticTargetCatalog.throttle.maximumValue, 1)
        XCTAssertEqual(Forge3DSemanticTargetCatalog.throttle.neutralValue, 0)
        XCTAssertEqual(Forge3DSemanticTargetCatalog.steering.minimumValue, -1)
        XCTAssertEqual(Forge3DSemanticTargetCatalog.steering.maximumValue, 1)
        XCTAssertEqual(Forge3DSemanticTargetCatalog.steering.neutralValue, 0)

        XCTAssertTrue(html.contains("data-novaforge-control=\"scene.pause\""))
        XCTAssertTrue(html.contains("data-novaforge-action=\"drive.throttle\""))
        XCTAssertTrue(html.contains("data-novaforge-action=\"drive.steering\""))
        XCTAssertTrue(js.contains("semanticActionEventName: \"novaforge:action\""))
        XCTAssertTrue(js.contains("semanticThrottleActionID: \"drive.throttle\""))
        XCTAssertTrue(js.contains("semanticSteeringActionID: \"drive.steering\""))
        XCTAssertTrue(js.contains("bindAutomationAction(accessibleThrottle, CONFIG.semanticThrottleActionID, \"throttle\")"))
        XCTAssertTrue(js.contains("bindAutomationAction(accessibleSteer, CONFIG.semanticSteeringActionID, \"steering\")"))
        XCTAssertTrue(js.contains("Number.isFinite(detail.value)"))
        XCTAssertTrue(js.contains("automationInput[inputChannel] = clamp(detail.value, -1, 1)"))
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
