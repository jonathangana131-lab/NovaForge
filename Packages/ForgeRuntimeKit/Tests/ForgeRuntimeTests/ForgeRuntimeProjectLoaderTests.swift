import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeProjectLoaderTests: XCTestCase {
    func testLoadsAuthorizedProjectWithCanonicalEntryPointAndAssets() throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        try fixture.write("index.html", "<html></html>")
        try fixture.write("assets/car.glb", "car")
        try fixture.writeManifest(manifest(
            capabilities: [.init(id: "haptics")],
            bundledAssets: ["assets/car.glb"]
        ))

        let request = try ForgeRuntimeProjectLoader().load(
            projectRootURL: fixture.root,
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertEqual(request.authorization.projectID, "neon-racer")
        XCTAssertEqual(request.authorization.grantedCapabilityIDs, ["haptics"])
        XCTAssertEqual(request.entryPointURL.path, fixture.root.appendingPathComponent("index.html").path)
        XCTAssertEqual(
            request.assetURLs["assets/car.glb"]?.path,
            fixture.root.appendingPathComponent("assets/car.glb").path
        )
    }

    func testOversizedManifestIsRejectedByBoundedFileRead() throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        try fixture.write("novaforge.runtime.json", String(repeating: " ", count: 65))
        let loader = ForgeRuntimeProjectLoader(
            manifestDecoder: .init(maximumManifestBytes: 64)
        )

        XCTAssertThrowsError(
            try loader.load(
                projectRootURL: fixture.root,
                expectedProjectID: "neon-racer",
                host: hostSupport()
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeProjectLoadingError,
                .manifestDecode(.manifestTooLarge(actualBytes: 65, maximumBytes: 64))
            )
        }
    }

    func testManifestSymlinkCannotEscapeProjectRoot() throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        let outsideManifest = fixture.parent.appendingPathComponent("outside.json")
        let data = try JSONEncoder().encode(manifest())
        try data.write(to: outsideManifest)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("novaforge.runtime.json"),
            withDestinationURL: outsideManifest
        )

        XCTAssertThrowsError(
            try ForgeRuntimeProjectLoader().load(
                projectRootURL: fixture.root,
                expectedProjectID: "neon-racer",
                host: hostSupport()
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeProjectLoadingError,
                .manifestFile(.escapedSandbox)
            )
        }
    }

    func testEntryPointSymlinkCannotEscapeProjectRoot() throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        let outside = fixture.parent.appendingPathComponent("outside.html")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("index.html"),
            withDestinationURL: outside
        )
        try fixture.writeManifest(manifest())

        XCTAssertThrowsError(
            try ForgeRuntimeProjectLoader().load(
                projectRootURL: fixture.root,
                expectedProjectID: "neon-racer",
                host: hostSupport()
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeProjectLoadingError,
                .entryPoint(.escapedSandbox)
            )
        }
    }

    func testMissingBundledAssetBlocksLaunchRequest() throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        try fixture.write("index.html", "ok")
        try fixture.writeManifest(manifest(bundledAssets: ["assets/missing.png"]))

        XCTAssertThrowsError(
            try ForgeRuntimeProjectLoader().load(
                projectRootURL: fixture.root,
                expectedProjectID: "neon-racer",
                host: hostSupport()
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeProjectLoadingError,
                .asset(path: "assets/missing.png", error: .fileNotFound)
            )
        }
    }

    func testMalformedManifestMapsToBoundedDecodeFailure() throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        try fixture.write("novaforge.runtime.json", "{")

        XCTAssertThrowsError(
            try ForgeRuntimeProjectLoader().load(
                projectRootURL: fixture.root,
                expectedProjectID: "neon-racer",
                host: hostSupport()
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeProjectLoadingError,
                .manifestDecode(.invalidJSON)
            )
        }
    }

    func testAuthorizationFailureStopsBeforeEntryPointResolution() throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        try fixture.writeManifest(manifest(capabilities: [.init(id: "camera")]))

        XCTAssertThrowsError(
            try ForgeRuntimeProjectLoader().load(
                projectRootURL: fixture.root,
                expectedProjectID: "neon-racer",
                host: hostSupport(supportedCapabilityIDs: [])
            )
        ) { error in
            guard case let ForgeRuntimeProjectLoadingError.authorization(.manifestRejected(report)) = error else {
                return XCTFail("Expected authorization rejection, got \(error)")
            }
            XCTAssertEqual(report.errors.map(\.code), [.unsupportedRequiredCapability])
        }
    }

    private func manifest(
        capabilities: [ForgeCapabilityRequest] = [],
        bundledAssets: [String] = []
    ) -> ForgeProjectManifest {
        .init(
            projectID: "neon-racer",
            projectVersion: "1.0.0",
            display: .init(name: "Neon Racer"),
            storage: .init(namespace: "neon-racer", quotaBytes: 1_048_576),
            capabilities: capabilities,
            bundledAssets: bundledAssets
        )
    }

    private func hostSupport(
        supportedCapabilityIDs: Set<String> = ["haptics"]
    ) -> ForgeRuntimeHostSupport {
        .init(supportedCapabilityIDs: supportedCapabilityIDs)
    }

    private struct ProjectFixture {
        let parent: URL
        let root: URL

        init() throws {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            root = parent.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ relativePath: String, _ contents: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }

        func writeManifest(_ manifest: ForgeProjectManifest) throws {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: root.appendingPathComponent("novaforge.runtime.json"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
