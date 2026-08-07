import XCTest
@testable import ForgeRuntimeCore

final class ForgeRuntimeAuthorizationTests: XCTestCase {
    func testAuthorizationReturnsOnlyRequestedAndGrantedAuthority() throws {
        let manifest = makeManifest(
            capabilities: [.haptics],
            network: .allowlist(["https://api.example.com"]),
            orientation: .landscape,
            viewport: .edgeToEdge
        )
        let context = ForgeRuntimeAuthorizationContext(
            supportedCapabilities: [.haptics, .share],
            grantedCapabilities: [.haptics, .share],
            supportedOrientations: [.portrait, .landscape],
            supportedViewportLayouts: [.safeArea, .edgeToEdge],
            networkAccess: .allowlist(["https://api.example.com", "https://cdn.example.com"])
        )

        let authorization = try ForgeRuntimeLaunchAuthorizer().authorize(manifest, context: context)

        XCTAssertEqual(authorization.capabilities, [.haptics])
        XCTAssertEqual(authorization.networkPolicy, .allowlist(["https://api.example.com"]))
        XCTAssertEqual(authorization.orientation, .landscape)
        XCTAssertEqual(authorization.viewport.layout, .edgeToEdge)
    }

    func testUnsupportedAndUngrantableCapabilitiesFailClosed() {
        let manifest = makeManifest(capabilities: [.haptics])

        XCTAssertThrowsError(try ForgeRuntimeLaunchAuthorizer().authorize(
            manifest,
            context: .init(supportedCapabilities: [], grantedCapabilities: [])
        )) { error in
            XCTAssertEqual(error as? ForgeRuntimeAuthorizationIssue, .unsupportedCapability(.haptics))
        }

        XCTAssertThrowsError(try ForgeRuntimeLaunchAuthorizer().authorize(
            manifest,
            context: .init(supportedCapabilities: [.haptics], grantedCapabilities: [])
        )) { error in
            XCTAssertEqual(error as? ForgeRuntimeAuthorizationIssue, .capabilityNotGranted(.haptics))
        }
    }

    func testHostCannotAccidentallyGrantCapabilityItDoesNotSupport() {
        let manifest = makeManifest()
        let context = ForgeRuntimeAuthorizationContext(
            supportedCapabilities: [],
            grantedCapabilities: [.share]
        )

        XCTAssertThrowsError(try ForgeRuntimeLaunchAuthorizer().authorize(manifest, context: context)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeAuthorizationIssue,
                .hostPolicyGrantsUnsupportedCapability(.share)
            )
        }
    }

    func testPresentationMustBeSupportedByActualHost() {
        let mixed = makeManifest(orientation: .mixed)
        XCTAssertThrowsError(try ForgeRuntimeLaunchAuthorizer().authorize(mixed, context: .init())) { error in
            XCTAssertEqual(error as? ForgeRuntimeAuthorizationIssue, .unsupportedOrientation(.mixed))
        }

        let edgeToEdge = makeManifest(viewport: .edgeToEdge)
        XCTAssertThrowsError(try ForgeRuntimeLaunchAuthorizer().authorize(edgeToEdge, context: .init())) { error in
            XCTAssertEqual(error as? ForgeRuntimeAuthorizationIssue, .unsupportedViewportLayout(.edgeToEdge))
        }
    }

    func testProjectNetworkAllowlistCannotExceedHostGrant() {
        let manifest = makeManifest(network: .allowlist(["https://api.example.com"]))

        XCTAssertThrowsError(try ForgeRuntimeLaunchAuthorizer().authorize(manifest, context: .init())) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeAuthorizationIssue,
                .networkAccessNotGranted("https://api.example.com")
            )
        }

        let narrowerHost = ForgeRuntimeAuthorizationContext(
            networkAccess: .allowlist(["https://cdn.example.com"])
        )
        XCTAssertThrowsError(try ForgeRuntimeLaunchAuthorizer().authorize(manifest, context: narrowerHost)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeAuthorizationIssue,
                .networkAccessNotGranted("https://api.example.com")
            )
        }
    }

    func testInvalidManifestNeverReachesAuthorization() {
        var manifest = makeManifest()
        manifest.runtime.entryPoint = "../index.html"

        XCTAssertThrowsError(try ForgeRuntimeLaunchAuthorizer().authorize(manifest, context: .init())) { error in
            guard case let .invalidManifest(issues) = error as? ForgeRuntimeAuthorizationIssue else {
                return XCTFail("Expected invalid manifest, got \(error)")
            }
            XCTAssertTrue(issues.contains(.invalidEntryPoint("../index.html")))
        }
    }

    private func makeManifest(
        capabilities: [ForgeCapability] = [],
        network: ForgeNetworkPolicy = .offlineOnly,
        orientation: ForgeOrientationPolicy = .auto,
        viewport: ForgeViewportPolicy.Layout = .safeArea
    ) -> ForgeProjectManifest {
        ForgeProjectManifest(
            project: .init(id: "test-project", displayName: "Test Project"),
            runtime: .init(
                entryPoint: "web/index.html",
                orientation: orientation,
                viewport: .init(layout: viewport),
                requestedCapabilities: capabilities,
                network: network,
                storage: .init(namespace: "test-project")
            )
        )
    }
}
