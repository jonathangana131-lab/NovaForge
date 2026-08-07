import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeProjectGrantAdversarialTests: XCTestCase {
    private let validator = ForgeRuntimeManifestValidator()

    func testInvalidGrantedNetworkHostFailsClosedEvenWhenManifestDeniesNetwork() {
        let grant = ForgeRuntimeProjectGrant(
            projectID: "neon-racer",
            allowedHTTPSHosts: ["*.example.com"]
        )

        XCTAssertThrowsError(
            try validator.authorize(
                manifest(network: .init(mode: .denied)),
                expectedProjectID: "neon-racer",
                host: .init(),
                projectGrant: grant
            )
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeLaunchAuthorizationError,
                .invalidProjectGrant(.invalidGrantedNetworkHost("*.example.com"))
            )
        }
    }

    func testGrantedNetworkHostNormalizationDoesNotWidenAuthority() throws {
        let authorization = try validator.authorize(
            manifest(network: .init(
                mode: .allowListedHTTPS,
                allowedHosts: ["api.example.com"]
            )),
            expectedProjectID: "neon-racer",
            host: .init(),
            projectGrant: .init(
                projectID: "neon-racer",
                allowedHTTPSHosts: ["API.Example.COM", "unused.example.com"]
            )
        )

        XCTAssertEqual(authorization.network.allowedHosts, ["api.example.com"])
    }

    private func manifest(network: ForgeNetworkPolicy) -> ForgeProjectManifest {
        .init(
            projectID: "neon-racer",
            projectVersion: "1.0.0",
            display: .init(name: "Neon Racer"),
            storage: .init(namespace: "neon-racer", quotaBytes: 1_048_576),
            network: network
        )
    }
}
