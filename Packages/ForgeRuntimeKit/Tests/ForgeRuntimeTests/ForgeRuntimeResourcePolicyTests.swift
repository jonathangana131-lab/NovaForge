import Foundation
import XCTest
@testable import ForgeRuntime

final class ForgeRuntimeResourcePolicyTests: XCTestCase {
    func testLocalProjectFileIsAllowedAfterSandboxResolution() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        try fixture.write("pages/index.html", "ok")
        let policy = try makePolicy(root: fixture.root)
        let url = fixture.root.appendingPathComponent("pages/index.html")

        XCTAssertEqual(
            policy.decide(url),
            .allow(.localProjectFile(url.standardizedFileURL))
        )
    }

    func testLocalFileOutsideProjectRootIsDenied() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        let outside = fixture.parent.appendingPathComponent("outside.html")
        try Data("outside".utf8).write(to: outside)
        let policy = try makePolicy(root: fixture.root)

        XCTAssertEqual(
            policy.decide(outside),
            .deny(.localFileRejected(.escapedSandbox))
        )
    }

    func testLocalSymlinkAliasIsDeniedEvenWhenTargetStaysInsideRoot() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        try fixture.write("real.html", "ok")
        let alias = fixture.root.appendingPathComponent("alias.html")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: fixture.root.appendingPathComponent("real.html")
        )
        let policy = try makePolicy(root: fixture.root)

        XCTAssertEqual(
            policy.decide(alias),
            .deny(.localFileRejected(.symbolicLinkNotAllowed))
        )
    }

    func testDeniedNetworkRejectsHTTPSEvenForPlausibleHost() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        let policy = try makePolicy(root: fixture.root, network: .init(mode: .denied))

        XCTAssertEqual(
            policy.decide(try XCTUnwrap(URL(string: "https://api.example.com/data"))),
            .deny(.externalNetworkDenied)
        )
    }

    func testExactAllowListedHTTPSHostIsAllowedCaseInsensitively() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        let policy = try makePolicy(
            root: fixture.root,
            network: .init(mode: .allowListedHTTPS, allowedHosts: ["API.Example.com"])
        )

        XCTAssertEqual(
            policy.decide(try XCTUnwrap(URL(string: "https://api.example.com/data"))),
            .allow(.externalHTTPS(host: "api.example.com"))
        )
    }

    func testSubdomainDoesNotInheritExactHostAuthority() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        let policy = try makePolicy(
            root: fixture.root,
            network: .init(mode: .allowListedHTTPS, allowedHosts: ["example.com"])
        )

        XCTAssertEqual(
            policy.decide(try XCTUnwrap(URL(string: "https://api.example.com/data"))),
            .deny(.externalHostNotAllowed("api.example.com"))
        )
    }

    func testHTTPAndOtherSchemesAreDeniedEvenForAllowListedHost() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        let policy = try makePolicy(
            root: fixture.root,
            network: .init(mode: .allowListedHTTPS, allowedHosts: ["api.example.com"])
        )

        XCTAssertEqual(
            policy.decide(try XCTUnwrap(URL(string: "http://api.example.com/data"))),
            .deny(.unsupportedScheme("http"))
        )
        XCTAssertEqual(
            policy.decide(try XCTUnwrap(URL(string: "javascript:alert(1)"))),
            .deny(.unsupportedScheme("javascript"))
        )
    }

    func testHTTPSCredentialsAndNonDefaultPortsAreDenied() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        let policy = try makePolicy(
            root: fixture.root,
            network: .init(mode: .allowListedHTTPS, allowedHosts: ["api.example.com"])
        )

        XCTAssertEqual(
            policy.decide(try XCTUnwrap(URL(string: "https://user:pass@api.example.com/data"))),
            .deny(.credentialsNotAllowed)
        )
        XCTAssertEqual(
            policy.decide(try XCTUnwrap(URL(string: "https://api.example.com:8443/data"))),
            .deny(.externalPortNotAllowed(8443))
        )
        XCTAssertTrue(
            policy.decide(try XCTUnwrap(URL(string: "https://api.example.com:443/data"))).isAllowed
        )
    }

    func testFileURLFragmentDoesNotChangeResolvedProjectFileIdentity() throws {
        let fixture = try ResourceFixture()
        defer { fixture.remove() }
        try fixture.write("index.html", "ok")
        let policy = try makePolicy(root: fixture.root)
        var components = URLComponents(url: fixture.root.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)
        components?.fragment = "garage"
        let url = try XCTUnwrap(components?.url)

        XCTAssertEqual(
            policy.decide(url),
            .allow(.localProjectFile(fixture.root.appendingPathComponent("index.html").standardizedFileURL))
        )
    }

    private func makePolicy(
        root: URL,
        network: ForgeNetworkPolicy = .init()
    ) throws -> ForgeRuntimeResourcePolicy {
        let manifest = ForgeProjectManifest(
            projectID: "neon-racer",
            projectVersion: "1.0.0",
            display: .init(name: "Neon Racer"),
            storage: .init(namespace: "neon-racer", quotaBytes: 1_048_576),
            network: network
        )
        let authorization = try ForgeRuntimeManifestValidator().authorize(
            manifest,
            expectedProjectID: "neon-racer",
            host: .init()
        )
        return ForgeRuntimeResourcePolicy(
            authorization: authorization,
            projectRootURL: root
        )
    }

    private struct ResourceFixture {
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

        func remove() {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
