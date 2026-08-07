import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeLaunchAuthorizationTests: XCTestCase {
    private let validator = ForgeRuntimeManifestValidator()

    func testAuthorizationDerivesOnlyHostGrantedAuthority() throws {
        let candidate = manifest(
            capabilities: [
                .init(id: "haptics"),
                .init(id: "future.depth-sensor", requirement: .optional),
            ],
            network: .init(
                mode: .allowListedHTTPS,
                allowedHosts: ["API.Example.com", "api.example.com"]
            ),
            modules: [
                .init(id: "three", version: "0.180.0"),
                .init(id: "future", version: "1.0.0", requirement: .optional),
            ]
        )
        let host = hostSupport(
            supportedCapabilityIDs: ["haptics"],
            curatedModuleVersions: ["three": ["0.180.0"]]
        )

        let authorization = try validator.authorize(
            candidate,
            expectedProjectID: "neon-racer",
            host: host
        )

        XCTAssertEqual(authorization.projectID, "neon-racer")
        XCTAssertEqual(authorization.grantedCapabilityIDs, ["haptics"])
        XCTAssertEqual(authorization.network.allowedHosts, ["api.example.com"])
        XCTAssertEqual(authorization.modules, [.init(id: "three", version: "0.180.0")])
    }

    func testAuthorizationRejectsManifestWithRequiredUnsupportedAuthority() {
        let candidate = manifest(capabilities: [.init(id: "camera")])

        XCTAssertThrowsError(
            try validator.authorize(
                candidate,
                expectedProjectID: "neon-racer",
                host: hostSupport(supportedCapabilityIDs: [])
            )
        ) { error in
            guard case let ForgeRuntimeLaunchAuthorizationError.manifestRejected(report) = error else {
                return XCTFail("Expected manifest rejection, got \(error)")
            }
            XCTAssertEqual(report.errors.map(\.code), [.unsupportedRequiredCapability])
        }
    }

    func testDeniedNetworkAuthorizationAlwaysCarriesNoHosts() throws {
        let authorization = try validator.authorize(
            manifest(network: .init(mode: .denied)),
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertEqual(authorization.network.mode, .denied)
        XCTAssertTrue(authorization.network.allowedHosts.isEmpty)
    }

    func testSandboxResolvesExistingDescendantFile() throws {
        let fixture = try SandboxFixture()
        defer { fixture.remove() }
        try fixture.write("index.html", contents: "<html></html>")

        let resolved = try ForgeProjectSandbox(rootURL: fixture.root)
            .resolveExistingFile(relativePath: "index.html")

        XCTAssertEqual(resolved.path, fixture.root.appendingPathComponent("index.html").path)
    }

    func testSandboxRejectsLexicalAndURLAmbiguousPathsBeforeFilesystemLookup() throws {
        let fixture = try SandboxFixture()
        defer { fixture.remove() }
        let sandbox = ForgeProjectSandbox(rootURL: fixture.root)

        for path in ["../secret", "/tmp/secret", "assets/%2e%2e/secret", "index.html?raw=1"] {
            XCTAssertThrowsError(try sandbox.resolveExistingFile(relativePath: path)) { error in
                XCTAssertEqual(error as? ForgeProjectSandboxError, .invalidRelativePath)
            }
        }
    }

    func testSandboxRejectsSymlinkThatEscapesProjectRoot() throws {
        let fixture = try SandboxFixture()
        defer { fixture.remove() }
        let outside = fixture.parent.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("escape.txt"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try ForgeProjectSandbox(rootURL: fixture.root)
                .resolveExistingFile(relativePath: "escape.txt")
        ) { error in
            XCTAssertEqual(error as? ForgeProjectSandboxError, .escapedSandbox)
        }
    }

    func testSandboxRejectsMissingFileAndDirectory() throws {
        let fixture = try SandboxFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("folder"),
            withIntermediateDirectories: false
        )
        let sandbox = ForgeProjectSandbox(rootURL: fixture.root)

        XCTAssertThrowsError(try sandbox.resolveExistingFile(relativePath: "missing.html")) { error in
            XCTAssertEqual(error as? ForgeProjectSandboxError, .fileNotFound)
        }
        XCTAssertThrowsError(try sandbox.resolveExistingFile(relativePath: "folder")) { error in
            XCTAssertEqual(error as? ForgeProjectSandboxError, .directoryNotAllowed)
        }
    }

    private func manifest(
        capabilities: [ForgeCapabilityRequest] = [],
        network: ForgeNetworkPolicy = .init(),
        modules: [ForgeCuratedModuleRequirement] = []
    ) -> ForgeProjectManifest {
        .init(
            projectID: "neon-racer",
            projectVersion: "1.0.0",
            display: .init(name: "Neon Racer", iconPath: "assets/icon.png"),
            storage: .init(namespace: "neon-racer", quotaBytes: 1_048_576),
            capabilities: capabilities,
            network: network,
            modules: modules
        )
    }

    private func hostSupport(
        supportedCapabilityIDs: Set<String> = ["haptics", "share", "controller", "storage"],
        curatedModuleVersions: [String: Set<String>] = ["three": ["0.180.0"]]
    ) -> ForgeRuntimeHostSupport {
        .init(
            supportedCapabilityIDs: supportedCapabilityIDs,
            curatedModuleVersions: curatedModuleVersions
        )
    }

    private struct SandboxFixture {
        let parent: URL
        let root: URL

        init() throws {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            root = parent.appendingPathComponent("project", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ relativePath: String, contents: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }

        func remove() {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
