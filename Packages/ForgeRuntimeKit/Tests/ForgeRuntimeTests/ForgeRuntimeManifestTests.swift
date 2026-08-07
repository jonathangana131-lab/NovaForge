import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeManifestTests: XCTestCase {
    private let validator = ForgeRuntimeManifestValidator()

    func testMinimalSupportedManifestIsLaunchable() {
        let report = validator.validate(
            manifest(),
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertTrue(report.isLaunchable)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testManifestRoundTripsThroughBoundedDecoder() throws {
        let expected = manifest(
            capabilities: [
                .init(id: "haptics"),
                .init(id: "controller", requirement: .optional),
            ],
            network: .init(mode: .allowListedHTTPS, allowedHosts: ["api.example.com"]),
            bundledAssets: ["assets/car.glb", "audio/motor.mp3"],
            modules: [.init(id: "three", version: "0.180.0")]
        )

        let data = try JSONEncoder().encode(expected)
        let decoded = try ForgeRuntimeManifestDecoder().decode(data)

        XCTAssertEqual(decoded, expected)
    }

    func testOversizedManifestFailsBeforeJSONDecode() {
        let decoder = ForgeRuntimeManifestDecoder(maximumManifestBytes: 16)
        let data = Data(repeating: 0x20, count: 17)

        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeManifestLoadingError,
                .manifestTooLarge(actualBytes: 17, maximumBytes: 16)
            )
        }
    }

    func testMalformedJSONReturnsBoundedLoadingError() {
        XCTAssertThrowsError(try ForgeRuntimeManifestDecoder().decode(Data("{".utf8))) { error in
            XCTAssertEqual(error as? ForgeRuntimeManifestLoadingError, .invalidJSON)
        }
    }

    func testProjectAndStorageIdentityAreBoundToHostSelectedProject() {
        let candidate = manifest(
            projectID: "other-project",
            storage: .init(namespace: "victim-project", quotaBytes: 1_048_576)
        )
        let report = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertEqual(
            Set(report.errors.map(\.code)),
            [.projectIdentityMismatch, .storageNamespaceMismatch]
        )
    }

    func testPathTraversalAndAbsolutePathsAreRejected() {
        let candidate = manifest(
            entryPoint: "../index.html",
            display: .init(name: "Neon Racer", iconPath: "/private/icon.png"),
            bundledAssets: ["assets/car.glb", "assets/../../secret.txt", "assets\\windows.txt", "assets/%2e%2e/secret.txt", "assets/icon.png?raw=1"]
        )
        let report = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertTrue(report.errors.contains { $0.code == .invalidEntryPoint })
        XCTAssertTrue(report.errors.contains { $0.code == .invalidIconPath })
        XCTAssertEqual(report.errors.filter { $0.code == .invalidAssetPath }.count, 4)
    }

    func testEntryPointMustBeHTML() {
        let report = validator.validate(
            manifest(entryPoint: "main.js"),
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertEqual(report.errors.map(\.code), [.invalidEntryPoint])
    }

    func testUnsupportedRequiredCapabilityBlocksButOptionalOnlyWarns() {
        let candidate = manifest(capabilities: [
            .init(id: "camera", requirement: .required),
            .init(id: "future.depth-sensor", requirement: .optional),
        ])
        let report = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport(supportedCapabilityIDs: ["haptics", "share"])
        )

        XCTAssertFalse(report.isLaunchable)
        XCTAssertEqual(report.errors.map(\.code), [.unsupportedRequiredCapability])
        XCTAssertEqual(report.warnings.map(\.code), [.unsupportedOptionalCapability])
    }

    func testInvalidAndDuplicateCapabilityRequestsFailClosed() {
        let candidate = manifest(capabilities: [
            .init(id: "Haptics"),
            .init(id: "haptics"),
            .init(id: "haptics", requirement: .optional),
        ])
        let report = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport(supportedCapabilityIDs: ["haptics"])
        )

        XCTAssertTrue(report.errors.contains { $0.code == .invalidCapabilityID })
        XCTAssertTrue(report.errors.contains { $0.code == .duplicateCapability })
    }

    func testDeniedNetworkCannotSmuggleAllowList() {
        let report = validator.validate(
            manifest(network: .init(mode: .denied, allowedHosts: ["api.example.com"])),
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertEqual(report.errors.map(\.code), [.networkHostsNotAllowed])
    }

    func testHTTPSAllowListRejectsURLWildcardPortAndCredentials() {
        let candidate = manifest(network: .init(
            mode: .allowListedHTTPS,
            allowedHosts: [
                "https://example.com",
                "*.example.com",
                "example.com:443",
                "user@example.com",
                "api.example.com",
            ]
        ))
        let report = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertEqual(report.errors.filter { $0.code == .invalidNetworkHost }.count, 4)
    }

    func testDuplicateNetworkHostWarnsCaseInsensitivelyWithoutWideningAuthority() {
        let report = validator.validate(
            manifest(network: .init(
                mode: .allowListedHTTPS,
                allowedHosts: ["API.Example.com", "api.example.com"]
            )),
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertTrue(report.isLaunchable)
        XCTAssertEqual(report.warnings.map(\.code), [.duplicateNetworkHost])
    }

    func testAllowListModeRequiresAtLeastOneHost() {
        let report = validator.validate(
            manifest(network: .init(mode: .allowListedHTTPS, allowedHosts: [])),
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )

        XCTAssertEqual(report.errors.map(\.code), [.networkAllowListEmpty])
    }

    func testMixedOrientationRequiresExplicitHostSupport() {
        let candidate = manifest(
            presentation: .init(orientation: .mixed, viewport: .edgeToEdge)
        )

        let unsupported = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport(supportsMixedOrientation: false)
        )
        XCTAssertEqual(unsupported.errors.map(\.code), [.unsupportedOrientation])

        let supported = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport(supportsMixedOrientation: true)
        )
        XCTAssertTrue(supported.isLaunchable)
    }

    func testStorageQuotaCannotExceedHostLimit() {
        let candidate = manifest(
            storage: .init(namespace: "neon-racer", quotaBytes: 8 * 1024 * 1024)
        )
        let report = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport(maximumStorageQuotaBytes: 4 * 1024 * 1024)
        )

        XCTAssertEqual(report.errors.map(\.code), [.invalidStorageQuota])
    }

    func testRequiredModuleMustMatchCuratedIDAndVersion() {
        let candidate = manifest(modules: [
            .init(id: "three", version: "0.181.0", requirement: .required),
            .init(id: "physics", version: "future", requirement: .optional),
        ])
        let report = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport(curatedModuleVersions: ["three": ["0.180.0"]])
        )

        XCTAssertEqual(report.errors.map(\.code), [.unsupportedRequiredModule])
        XCTAssertEqual(report.warnings.map(\.code), [.unsupportedOptionalModule])
    }

    func testDuplicateModuleIDFailsClosed() {
        let candidate = manifest(modules: [
            .init(id: "three", version: "0.180.0"),
            .init(id: "three", version: "0.180.0", requirement: .optional),
        ])
        let report = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: hostSupport(curatedModuleVersions: ["three": ["0.180.0"]])
        )

        XCTAssertEqual(report.errors.map(\.code), [.duplicateModule])
    }

    func testNewerManifestOrRuntimeVersionIsRejected() {
        var report = validator.validate(
            manifest(formatVersion: .init(major: 2, minor: 0)),
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )
        XCTAssertEqual(report.errors.map(\.code), [.unsupportedManifestVersion])

        report = validator.validate(
            manifest(runtimeVersion: .init(major: 1, minor: 1)),
            expectedProjectID: "neon-racer",
            host: hostSupport()
        )
        XCTAssertEqual(report.errors.map(\.code), [.unsupportedRuntimeVersion])
    }

    func testManifestCollectionLimitsAreFailClosed() {
        let candidate = manifest(
            capabilities: [.init(id: "haptics"), .init(id: "share")],
            network: .init(mode: .allowListedHTTPS, allowedHosts: ["a.example.com", "b.example.com"]),
            bundledAssets: ["a.png", "b.png"],
            modules: [
                .init(id: "three", version: "0.180.0"),
                .init(id: "physics", version: "1.0.0"),
            ]
        )
        let host = ForgeRuntimeHostSupport(
            supportedCapabilityIDs: ["haptics", "share"],
            curatedModuleVersions: [
                "three": ["0.180.0"],
                "physics": ["1.0.0"],
            ],
            maximumAssets: 1,
            maximumCapabilityRequests: 1,
            maximumModules: 1,
            maximumNetworkHosts: 1
        )
        let report = validator.validate(
            candidate,
            expectedProjectID: "neon-racer",
            host: host
        )

        XCTAssertEqual(
            Set(report.errors.map(\.code)),
            [.capabilityRequestLimitExceeded, .networkHostLimitExceeded, .assetLimitExceeded, .moduleLimitExceeded]
        )
    }

    private func manifest(
        formatVersion: ForgeManifestFormatVersion = .init(major: 1, minor: 0),
        projectID: String = "neon-racer",
        projectVersion: String = "1.0.0",
        runtimeVersion: ForgeRuntimeVersion = .init(major: 1, minor: 0),
        entryPoint: String = "index.html",
        display: ForgeProjectDisplayMetadata = .init(name: "Neon Racer", iconPath: "assets/icon.png"),
        presentation: ForgePresentationPolicy = .init(),
        storage: ForgeStoragePolicy = .init(namespace: "neon-racer", quotaBytes: 1_048_576),
        capabilities: [ForgeCapabilityRequest] = [],
        network: ForgeNetworkPolicy = .init(),
        bundledAssets: [String] = [],
        modules: [ForgeCuratedModuleRequirement] = []
    ) -> ForgeProjectManifest {
        ForgeProjectManifest(
            formatVersion: formatVersion,
            projectID: projectID,
            projectVersion: projectVersion,
            runtimeVersion: runtimeVersion,
            entryPoint: entryPoint,
            display: display,
            presentation: presentation,
            storage: storage,
            capabilities: capabilities,
            network: network,
            bundledAssets: bundledAssets,
            modules: modules
        )
    }

    private func hostSupport(
        supportedCapabilityIDs: Set<String> = ["haptics", "share", "controller", "storage"],
        curatedModuleVersions: [String: Set<String>] = ["three": ["0.180.0"]],
        supportsMixedOrientation: Bool = false,
        maximumStorageQuotaBytes: Int = 64 * 1024 * 1024
    ) -> ForgeRuntimeHostSupport {
        .init(
            supportedCapabilityIDs: supportedCapabilityIDs,
            curatedModuleVersions: curatedModuleVersions,
            supportsMixedOrientation: supportsMixedOrientation,
            maximumStorageQuotaBytes: maximumStorageQuotaBytes
        )
    }
}
