import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeManifestTests: XCTestCase {
    func testValidOfflineWebManifestProducesDeterministicLaunchPlan() throws {
        let manifest = ForgeProjectManifest(
            projectID: "neon-racer.1",
            displayName: "  Neon Racer  ",
            entryPoint: "game/index.html",
            orientation: .landscape,
            capabilities: [.share, .localStorage, .haptics],
            network: .offlineOnly
        )

        let plan = try ForgeRuntimeManifestValidator.makeLaunchPlan(for: manifest)

        XCTAssertEqual(plan.projectID, "neon-racer.1")
        XCTAssertEqual(plan.displayName, "Neon Racer")
        XCTAssertEqual(plan.runtime, .webV1)
        XCTAssertEqual(plan.entryPointRelativePath, "game/index.html")
        XCTAssertEqual(plan.orientation, .landscape)
        XCTAssertEqual(plan.capabilities, [.haptics, .localStorage, .share])
        XCTAssertEqual(plan.network, .offlineOnly)
    }

    func testRejectsNativeSwiftEntrypoint() {
        assertManifestError(
            .unsupportedEntryPoint("Sources/App.swift"),
            manifest: ForgeProjectManifest(projectID: "native-app", displayName: "Native App", entryPoint: "Sources/App.swift")
        )
    }

    func testRejectsSandboxTraversalAndEncodedTraversal() {
        for path in ["../index.html", "web/../index.html", "web/%2e%2e/index.html", "web\\index.html", "/index.html", "web//index.html"] {
            assertManifestError(
                .invalidEntryPoint(path),
                manifest: ForgeProjectManifest(projectID: "safe-app", displayName: "Safe App", entryPoint: path)
            )
        }
    }

    func testRejectsUnsupportedSchemaVersion() {
        assertManifestError(
            .unsupportedSchemaVersion(2),
            manifest: ForgeProjectManifest(schemaVersion: 2, projectID: "demo", displayName: "Demo")
        )
    }

    func testRejectsMalformedProjectIdentifiers() {
        for projectID in ["", "Uppercase", "-leading", "trailing-", "has space", "double..dot"] {
            assertManifestError(
                .invalidProjectID(projectID),
                manifest: ForgeProjectManifest(projectID: projectID, displayName: "Demo")
            )
        }
    }

    func testRejectsDuplicateCapabilities() {
        assertManifestError(
            .duplicateCapability(.haptics),
            manifest: ForgeProjectManifest(
                projectID: "demo",
                displayName: "Demo",
                capabilities: [.haptics, .localStorage, .haptics]
            )
        )
    }

    func testOfflineAndDenyAllPoliciesRejectHosts() {
        for mode in [ForgeRuntimeNetworkPolicy.Mode.offlineOnly, .denyAll] {
            assertManifestError(
                .networkHostsNotAllowed(mode),
                manifest: ForgeProjectManifest(
                    projectID: "demo",
                    displayName: "Demo",
                    network: .init(mode: mode, allowedHosts: ["example.com"])
                )
            )
        }
    }

    func testAllowlistRequiresValidUniqueCanonicalHostsAndSortsThem() throws {
        let manifest = ForgeProjectManifest(
            projectID: "network-demo",
            displayName: "Network Demo",
            network: .allowlisted(["cdn.example.com", "api.example.com"])
        )

        let plan = try ForgeRuntimeManifestValidator.makeLaunchPlan(for: manifest)
        XCTAssertEqual(plan.network, .allowlisted(["api.example.com", "cdn.example.com"]))

        assertManifestError(
            .emptyNetworkAllowlist,
            manifest: ForgeProjectManifest(
                projectID: "network-demo",
                displayName: "Network Demo",
                network: .allowlisted([])
            )
        )

        assertManifestError(
            .duplicateNetworkHost("api.example.com"),
            manifest: ForgeProjectManifest(
                projectID: "network-demo",
                displayName: "Network Demo",
                network: .allowlisted(["api.example.com", "api.example.com"])
            )
        )

        for host in ["HTTPS://example.com", "https://example.com", "*.example.com", "example.com:443", "example.com/path", "bad..example.com", "-bad.example.com"] {
            assertManifestError(
                .invalidNetworkHost(host),
                manifest: ForgeProjectManifest(
                    projectID: "network-demo",
                    displayName: "Network Demo",
                    network: .allowlisted([host])
                )
            )
        }
    }

    func testManifestRoundTripsThroughJSON() throws {
        let manifest = ForgeProjectManifest(
            projectID: "calculator",
            displayName: "Calculator",
            orientation: .portrait,
            capabilities: [.localStorage, .haptics],
            network: .denyAll
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ForgeProjectManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertNoThrow(try ForgeRuntimeManifestValidator.makeLaunchPlan(for: decoded))
    }

    private func assertManifestError(
        _ expected: ForgeRuntimeManifestError,
        manifest: ForgeProjectManifest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ForgeRuntimeManifestValidator.makeLaunchPlan(for: manifest), file: file, line: line) { error in
            XCTAssertEqual(error as? ForgeRuntimeManifestError, expected, file: file, line: line)
        }
    }
}
