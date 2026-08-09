import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeURLAccessPolicyTests: XCTestCase {
    private let evaluator = ForgeRuntimeURLAccessEvaluator()

    func testDeniedNetworkModeRejectsHTTPSEvenForHostNamedInAuthorization() throws {
        let authorization = launchAuthorization(mode: .denied, allowedHosts: [])
        let decision = evaluator.evaluate(
            try XCTUnwrap(URL(string: "https://api.example.com/v1/data")),
            launchAuthorization: authorization,
            projectRootURL: makeRootURL()
        )

        XCTAssertEqual(decision, .deny(.networkDenied))
        XCTAssertFalse(decision.isAllowed)
    }

    func testAllowListedHTTPSRequiresExactCaseInsensitiveHostname() throws {
        let authorization = launchAuthorization(
            mode: .allowListedHTTPS,
            allowedHosts: ["api.example.com"]
        )
        let root = makeRootURL()

        XCTAssertEqual(
            evaluator.evaluate(
                try XCTUnwrap(URL(string: "https://API.EXAMPLE.COM/v1/data?x=1#result")),
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .allowHTTPS(host: "api.example.com")
        )
        XCTAssertEqual(
            evaluator.evaluate(
                try XCTUnwrap(URL(string: "https://sub.api.example.com/v1/data")),
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.hostNotAllowListed)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                try XCTUnwrap(URL(string: "https://api.example.com./v1/data")),
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.hostNotAllowListed)
        )
    }

    func testRemoteAuthorityRejectsSchemeCredentialsExplicitPortAndHostlessHTTPS() throws {
        let authorization = launchAuthorization(
            mode: .allowListedHTTPS,
            allowedHosts: ["api.example.com"]
        )
        let root = makeRootURL()

        XCTAssertEqual(
            evaluator.evaluate(
                try XCTUnwrap(URL(string: "http://api.example.com/v1/data")),
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.unsupportedRemoteScheme)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                try XCTUnwrap(URL(string: "https://user:secret@api.example.com/v1/data")),
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.credentialsNotAllowed)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                try XCTUnwrap(URL(string: "https://api.example.com:443/v1/data")),
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.explicitPortNotAllowed)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                try XCTUnwrap(URL(string: "https:///v1/data")),
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.invalidRemoteURL)
        )
    }

    func testProjectFileInsideRootMustExistAndBeRegular() throws {
        let root = makeRootURL()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("assets/sprite.png", isDirectory: false)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("sprite".utf8).write(to: file)

        XCTAssertEqual(
            evaluator.evaluate(
                file,
                launchAuthorization: launchAuthorization(mode: .denied, allowedHosts: []),
                projectRootURL: root
            ),
            .allowProjectFile
        )
    }

    func testMissingProjectFileAndDirectoryFailClosed() throws {
        let root = makeRootURL()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let authorization = launchAuthorization(mode: .denied, allowedHosts: [])

        XCTAssertEqual(
            evaluator.evaluate(
                directory.appendingPathComponent("missing.png"),
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.projectFileNotFound)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                directory,
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.projectDirectoryNotAllowed)
        )
    }

    func testProjectFileSymlinkComponentFailsClosedEvenWhenTargetExists() throws {
        let root = makeRootURL()
        let fixtureRoot = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let outside = fixtureRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertEqual(
            evaluator.evaluate(
                link.appendingPathComponent("secret.txt"),
                launchAuthorization: launchAuthorization(mode: .denied, allowedHosts: []),
                projectRootURL: root
            ),
            .deny(.projectSymbolicLinkNotAllowed)
        )
    }

    func testProjectFileEscapeRootAndTraversalFailClosed() throws {
        let root = makeRootURL()
        let fixtureRoot = root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = fixtureRoot.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let authorization = launchAuthorization(mode: .denied, allowedHosts: [])

        XCTAssertEqual(
            evaluator.evaluate(
                outside,
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.projectFileOutsideSandbox)
        )
        let traversal = try XCTUnwrap(
            URL(string: root.appendingPathComponent("assets/../../outside.txt").absoluteString)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                traversal,
                launchAuthorization: authorization,
                projectRootURL: root
            ),
            .deny(.projectFileOutsideSandbox)
        )
    }

    func testNonFileProjectRootFailsClosed() throws {
        let file = makeRootURL().appendingPathComponent("index.html", isDirectory: false)
        let remoteRoot = try XCTUnwrap(URL(string: "https://example.com/project/"))

        XCTAssertEqual(
            evaluator.evaluate(
                file,
                launchAuthorization: launchAuthorization(mode: .denied, allowedHosts: []),
                projectRootURL: remoteRoot
            ),
            .deny(.invalidProjectRoot)
        )
    }

    private func makeRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("novaforge-url-policy-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
    }

    private func launchAuthorization(
        mode: ForgeNetworkMode,
        allowedHosts: [String]
    ) -> ForgeRuntimeLaunchAuthorization {
        ForgeRuntimeLaunchAuthorization(
            projectID: "network-fixture",
            runtimeVersion: .init(major: 1, minor: 0),
            entryPoint: "index.html",
            presentation: .init(),
            storage: .init(namespace: "network-fixture", schemaVersion: 1, quotaBytes: 1_048_576),
            grantedCapabilityIDs: [],
            network: .init(mode: mode, allowedHosts: allowedHosts),
            modules: []
        )
    }
}
