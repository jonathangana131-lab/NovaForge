import Foundation
import XCTest
@testable import ForgeRuntimeCore

final class ForgeManifestValidationTests: XCTestCase {
    func testValidOfflineManifestRoundTripsAndValidates() throws {
        let manifest = makeManifest()
        try ForgeManifestValidator().validate(manifest)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let decoded = try JSONDecoder().decode(ForgeProjectManifest.self, from: data)

        XCTAssertEqual(decoded, manifest)
    }

    func testUnknownCapabilityFailsClosedAtDecodeBoundary() throws {
        let data = Data(validManifestJSON.replacingOccurrences(
            of: "\"requestedCapabilities\":[]",
            with: "\"requestedCapabilities\":[\"arbitraryNativeAccess\"]"
        ).utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ForgeProjectManifest.self, from: data))
    }

    func testUnsupportedFutureRuntimeIsRejected() {
        var manifest = makeManifest()
        manifest.runtime.version = ForgeRuntimeVersion(1, 1, 0)

        assertIssues(manifest) { issues in
            XCTAssertTrue(issues.contains(.unsupportedRuntimeVersion(
                found: ForgeRuntimeVersion(1, 1, 0),
                supported: ForgeRuntimeSupport.currentRuntime
            )))
        }
    }

    func testSandboxTraversalAndPercentEncodingAreRejected() {
        for path in ["../index.html", "assets/../index.html", "/index.html", "assets/%2e%2e/index.html", "assets//index.html", "file:https://evil.test"] {
            XCTAssertFalse(ForgeSandboxPath.isCanonical(path), path)
        }

        XCTAssertTrue(ForgeSandboxPath.isCanonical("web/index.html"))
        XCTAssertTrue(ForgeSandboxPath.isCanonical("assets/icons/app.png"))
    }

    func testOfflinePolicyCannotSmuggleOrigins() {
        var manifest = makeManifest()
        manifest.runtime.network = ForgeNetworkPolicy(mode: .offlineOnly, allowedOrigins: ["https://example.com"])

        assertIssues(manifest) { issues in
            XCTAssertTrue(issues.contains(.offlinePolicyContainsOrigins))
        }
    }

    func testAllowlistAcceptsCanonicalHTTPSOriginsAndRejectsUnsafeForms() throws {
        var manifest = makeManifest()
        manifest.runtime.network = .allowlist(["https://api.example.com", "https://cdn.example.com:8443"])
        try ForgeManifestValidator().validate(manifest)

        for origin in [
            "http://api.example.com",
            "https://*.example.com",
            "https://user:pass@example.com",
            "https://example.com/path",
            "https://example.com?token=nope",
            " HTTPS://EXAMPLE.COM",
        ] {
            var invalid = makeManifest()
            invalid.runtime.network = .allowlist([origin])
            assertIssues(invalid) { issues in
                XCTAssertTrue(issues.contains(.invalidNetworkOrigin(origin)), origin)
            }
        }
    }

    func testDuplicateCapabilitiesAssetsOriginsAndModulesAreRejected() {
        var manifest = makeManifest()
        manifest.runtime.requestedCapabilities = [.haptics, .haptics]
        manifest.assets = ["assets/a.png", "assets/a.png"]
        manifest.runtime.network = .allowlist(["https://example.com", "https://example.com"])
        manifest.modules = [
            .init(id: "three", version: "1.0.0"),
            .init(id: "three", version: "1.0.0"),
        ]

        let validator = ForgeManifestValidator(moduleCatalog: .init(versionsByModule: ["three": ["1.0.0"]]))
        assertIssues(manifest, validator: validator) { issues in
            XCTAssertTrue(issues.contains(.duplicateCapability(.haptics)))
            XCTAssertTrue(issues.contains(.duplicateAsset("assets/a.png")))
            XCTAssertTrue(issues.contains(.duplicateNetworkOrigin("https://example.com")))
            XCTAssertTrue(issues.contains(.duplicateModule("three")))
        }
    }

    func testCuratedModulesRequireExactCatalogMatch() throws {
        var manifest = makeManifest()
        manifest.modules = [.init(id: "three", version: "1.2.3")]

        assertIssues(manifest) { issues in
            XCTAssertTrue(issues.contains(.unsupportedModule(id: "three", version: "1.2.3")))
        }

        let catalog = ForgeCuratedModuleCatalog(versionsByModule: ["three": ["1.2.3"]])
        try ForgeManifestValidator(moduleCatalog: catalog).validate(manifest)
    }

    func testInvalidIdentityStorageAndIconAreRejectedTogether() {
        var manifest = makeManifest()
        manifest.project.id = "Bad ID"
        manifest.project.version = 0
        manifest.project.iconPath = "../secret.png"
        manifest.runtime.storage = .init(namespace: "Bad Namespace", schemaVersion: 0)

        assertIssues(manifest) { issues in
            XCTAssertTrue(issues.contains(.invalidProjectID("Bad ID")))
            XCTAssertTrue(issues.contains(.invalidProjectVersion(0)))
            XCTAssertTrue(issues.contains(.invalidIconPath("../secret.png")))
            XCTAssertTrue(issues.contains(.invalidStorageNamespace("Bad Namespace")))
            XCTAssertTrue(issues.contains(.invalidStorageSchemaVersion(0)))
        }
    }

    func testFixtureDecodesAndValidates() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "minimal-offline-v1", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(ForgeProjectManifest.self, from: data)
        try ForgeManifestValidator().validate(manifest)

        XCTAssertEqual(manifest.project.id, "neon-racer")
        XCTAssertEqual(manifest.runtime.entryPoint, "web/index.html")
        XCTAssertEqual(manifest.runtime.network, .offlineOnly)
    }

    private func makeManifest() -> ForgeProjectManifest {
        ForgeProjectManifest(
            project: .init(id: "neon-racer", displayName: "Neon Racer", iconPath: "assets/icon.png"),
            runtime: .init(
                entryPoint: "web/index.html",
                orientation: .landscape,
                viewport: .init(layout: .edgeToEdge),
                requestedCapabilities: [.localStorage, .haptics],
                network: .offlineOnly,
                storage: .init(namespace: "neon-racer")
            ),
            assets: ["assets/icon.png", "web/game.js"],
            launch: .init(title: "Neon Racer", subtitle: "Ready")
        )
    }

    private func assertIssues(
        _ manifest: ForgeProjectManifest,
        validator: ForgeManifestValidator = .init(),
        _ body: ([ForgeManifestIssue]) -> Void
    ) {
        do {
            try validator.validate(manifest)
            XCTFail("Expected validation to fail")
        } catch let error as ForgeManifestValidationError {
            body(error.issues)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private var validManifestJSON: String {
        #"{"schemaVersion":1,"project":{"id":"neon-racer","version":1,"displayName":"Neon Racer"},"runtime":{"version":{"major":1,"minor":0,"patch":0},"kind":"web","entryPoint":"web/index.html","orientation":"auto","viewport":{"layout":"safeArea","allowsUserScaling":false},"requestedCapabilities":[],"network":{"mode":"offlineOnly","allowedOrigins":[]},"storage":{"namespace":"neon-racer","schemaVersion":1}},"assets":[],"modules":[]}"#
    }
}
