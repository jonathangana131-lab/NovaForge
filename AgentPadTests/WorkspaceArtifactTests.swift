import XCTest

final class WorkspaceArtifactTests: XCTestCase {
    func testDetectsWritableWebArtifacts() {
        let artifact = WorkspaceArtifact.fromToolOutput("Wrote games/pong.html")

        XCTAssertEqual(artifact?.path, "games/pong.html")
        XCTAssertEqual(artifact?.title, "pong.html")
        XCTAssertTrue(artifact?.isWebPage == true)
        XCTAssertTrue(artifact?.isPlayableWebArtifact == true)
        XCTAssertEqual(artifact?.handoffTitle, "Ready to play")
    }

    func testDistinguishesPlayableGamesFromRegularWebPages() {
        let landingPage = WorkspaceArtifact(path: "cron-18-landing.html")
        let game = WorkspaceArtifact(path: "slither-arena.html")

        XCTAssertTrue(landingPage.isWebPage)
        XCTAssertFalse(landingPage.isPlayableWebArtifact)
        XCTAssertEqual(landingPage.handoffTitle, "Ready to open")
        XCTAssertEqual(landingPage.handoffSymbol, "safari.fill")
        XCTAssertTrue(game.isPlayableWebArtifact)
        XCTAssertEqual(game.handoffTitle, "Ready to play")
        XCTAssertEqual(game.handoffSymbol, "play.rectangle.fill")
    }

    func testDetectsNativeSwiftGameArtifacts() {
        let artifact = WorkspaceArtifact.fromToolOutput("Wrote NativeSwiftGames/StarfieldSprint.nf-game.json")

        XCTAssertEqual(artifact?.path, "NativeSwiftGames/StarfieldSprint.nf-game.json")
        XCTAssertEqual(artifact?.artifactType, .swiftGame)
        XCTAssertEqual(artifact?.previewMode, .nativeGame)
        XCTAssertTrue(artifact?.isSwiftGameArtifact == true)
        XCTAssertEqual(artifact?.handoffTitle, "Ready to play")
        XCTAssertEqual(artifact?.handoffSymbol, "gamecontroller.fill")
    }

    func testSampleSwiftGameManifestExportsSwiftSource() throws {
        let data = Data(SwiftGameArtifactFactory.sampleManifestJSON().utf8)
        let manifest = try JSONDecoder().decode(SwiftGameManifest.self, from: data)

        XCTAssertEqual(manifest.type, .swiftGame)
        XCTAssertEqual(manifest.preferredOrientation, .landscape)
        XCTAssertFalse(manifest.collectibles.isEmpty)
        XCTAssertTrue(SwiftGameArtifactFactory.exportSource(for: manifest).contains("struct StarfieldSprintGame"))
    }

    func testDetectsMovedAndCopiedArtifacts() {
        XCTAssertEqual(WorkspaceArtifact.fromToolOutput("Moved draft.html to games/final.html")?.path, "games/final.html")
        XCTAssertEqual(WorkspaceArtifact.fromToolOutput("Copied game.html to exports/game.html")?.path, "exports/game.html")
    }

    func testIgnoresFoldersAndUnsupportedOutputs() {
        XCTAssertNil(WorkspaceArtifact.fromToolOutput("Created folder games"))
        XCTAssertNil(WorkspaceArtifact.fromToolOutput("Deleted games/pong.html"))
    }

    func testDetectsImageArtifacts() {
        let artifact = WorkspaceArtifact.fromToolOutput("Wrote image.png")

        XCTAssertEqual(artifact?.path, "image.png")
        XCTAssertEqual(artifact?.artifactType, .assetPack)
        XCTAssertEqual(artifact?.previewMode, .files)
        XCTAssertTrue(artifact?.isImageArtifact == true)
        XCTAssertTrue(artifact?.isReadablePreviewArtifact == true)
    }

    func testRejectsUnsafeArtifactPaths() {
        XCTAssertNil(WorkspaceArtifact.fromToolOutput("Wrote ../escape.html"))
        XCTAssertNil(WorkspaceArtifact.fromToolOutput("Wrote /tmp/escape.html"))
        XCTAssertNil(WorkspaceArtifact.fromToolOutput("Moved draft.html to games/../../escape.html"))
    }

    func testScansLargeToolOutputsWithABoundedPrefix() {
        let noisyPrefix = (1...40).map { "fixture output line \($0)" }.joined(separator: "\n")
        let output = noisyPrefix + "\nWrote reports/performance.html\n" + String(repeating: "debug log\n", count: 2_000)

        XCTAssertEqual(WorkspaceArtifact.fromToolOutput(output)?.path, "reports/performance.html")
    }

    // MARK: - Qwen 3.8 27B product contract

    func testProductCatalogPresentsOnlyQwen38_27BTarget() {
        let presented = LocalModelCatalog.presentationOrder
        XCTAssertEqual(presented.count, 1)
        let target = presented[0]
        let identity = "\(target.id) \(target.displayName) \(target.shortName)".lowercased()
        XCTAssertTrue(identity.contains("qwen3.8") || identity.contains("qwen 3.8") || identity.contains("qwen38"))
        XCTAssertTrue(identity.contains("27b"))
        XCTAssertFalse(identity.contains("qwen3.6"))
        XCTAssertFalse(identity.contains("qwen 3.6"))
        XCTAssertFalse(identity.contains("qwen3.5"))
        XCTAssertFalse(identity.contains("qwen 3.5"))
    }

    func testLegacyQwen36AndQwen35IDsCannotResolveAsProductModels() {
        XCTAssertNil(LocalModelCatalog.variant(for: "qwen3.6-27b-ud-iq2-xxs"))
        XCTAssertNil(LocalModelCatalog.variant(for: "Qwen/Qwen3.5-27B-GGUF"))
        XCTAssertNil(LocalModelCatalog.variant(for: "Qwen/Qwen3.6-27B-GGUF"))
    }

    func testUnreleasedQwen38SentinelIsNeverDownloadCompatible() {
        let sentinel = Qwen38ReleaseDiscovery.unavailableVariant
        XCTAssertEqual(sentinel.expectedBytes, 0)
        XCTAssertNotNil(LocalModelCatalog.compatibilityMessage(for: sentinel))
        XCTAssertEqual(LocalModelCatalog.presentationOrder.count, 1)
    }
}