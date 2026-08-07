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

    func testGeneratedTouchControlsAreAccessibleAndLarge() throws {
        let project = try Forge2DGenerator.generate(blueprint)
        let html = try XCTUnwrap(project.files.first(where: { $0.path == "index.html" })?.contents)
        let css = try XCTUnwrap(project.files.first(where: { $0.path == "styles.css" })?.contents)

        XCTAssertTrue(html.contains("aria-label=\"Move left\""))
        XCTAssertTrue(html.contains("aria-label=\"Move right\""))
        XCTAssertTrue(html.contains("aria-label=\"Jump\""))
        XCTAssertTrue(html.contains("aria-live=\"polite\""))
        XCTAssertTrue(css.contains("width: 68px; height: 68px"))
        XCTAssertTrue(css.contains("prefers-reduced-transparency"))
        XCTAssertTrue(css.contains("prefers-reduced-motion"))
        XCTAssertTrue(css.contains("top: max(14px, env(safe-area-inset-top))"))
        XCTAssertTrue(css.contains("right: max(14px, env(safe-area-inset-right))"))
        XCTAssertFalse(css.contains("body { padding: env(safe-area-inset-top)"))
    }

    func testBlueprintRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(blueprint)
        XCTAssertEqual(try JSONDecoder().decode(Forge2DBlueprint.self, from: data), blueprint)
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
