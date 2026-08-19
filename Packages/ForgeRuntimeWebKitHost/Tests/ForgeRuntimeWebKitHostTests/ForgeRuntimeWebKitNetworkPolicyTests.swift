import Foundation
import ForgeRuntime
@testable import ForgeRuntimeWebKitHost
import WebKit
import XCTest

@MainActor
final class ForgeRuntimeWebKitNetworkPolicyTests: XCTestCase {
    private struct ProjectFixture {
        let rootURL: URL
        let launchRequest: ForgeRuntimeLaunchRequest
    }

    private final class ForwardingNavigationDelegate: NSObject, WKNavigationDelegate {
        let host: ForgeRuntimeWebKitSemanticHost
        var didFinishExpectation: XCTestExpectation?

        init(host: ForgeRuntimeWebKitSemanticHost) {
            self.host = host
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if let navigation { host.navigationDidStart(navigation, in: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let navigation { host.navigationDidFinish(navigation, in: webView) }
            didFinishExpectation?.fulfill()
            didFinishExpectation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            host.navigationDidFail(navigation, in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            host.navigationDidFail(navigation, in: webView)
        }
    }

    func testDeniedAuthorityBlocksCommonExternalNetworkSchemesForEveryResourceType() throws {
        let fixture = try makeProjectFixture(network: .init())
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let rules = try decodedRules(for: fixture.launchRequest.authorization.network)
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(
            rules.compactMap { trigger(in: $0)["url-filter"] as? String },
            ["^http://", "^https://", "^ws://", "^wss://"]
        )
        XCTAssertTrue(rules.allSatisfy { action(in: $0)["type"] as? String == "block" })
        XCTAssertTrue(
            rules.allSatisfy { trigger(in: $0)["resource-type"] == nil },
            "Network blocking must cover every WebKit resource type, including fetch and WebSocket"
        )
    }

    func testAllowListReopensOnlyExactHTTPSResourceHostsFromFileDocuments() throws {
        let fixture = try makeProjectFixture(
            network: .init(
                mode: .allowListedHTTPS,
                allowedHosts: ["assets.example.com", "api.example.com"]
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let rules = try decodedRules(for: fixture.launchRequest.authorization.network)
        XCTAssertEqual(rules.count, 6)
        XCTAssertTrue(rules.prefix(4).allSatisfy { action(in: $0)["type"] as? String == "block" })

        let reopenRules = Array(rules.suffix(2))
        XCTAssertEqual(
            reopenRules.compactMap { action(in: $0)["type"] as? String },
            ["ignore-previous-rules", "ignore-previous-rules"]
        )
        XCTAssertEqual(
            reopenRules.compactMap { trigger(in: $0)["url-filter"] as? String },
            [
                "^https://api\\.example\\.com(:443)?/",
                "^https://assets\\.example\\.com(:443)?/",
            ]
        )
        XCTAssertTrue(
            reopenRules.allSatisfy { trigger(in: $0)["if-domain"] == nil },
            "Forge launches file:// documents; document-domain conditions must not suppress exact resource allowlists"
        )
        XCTAssertTrue(
            reopenRules.allSatisfy { trigger(in: $0)["resource-type"] == nil },
            "The exact-host reopen must cover every otherwise-authorized WebKit resource type"
        )
        XCTAssertFalse(
            reopenRules.contains { (trigger(in: $0)["url-filter"] as? String)?.hasPrefix("^http://") == true },
            "HTTPS authority must never reopen cleartext HTTP"
        )
    }

    func testWebKitCompilerAcceptsDeniedAndExactHostPolicies() async throws {
        let denied = try makeProjectFixture(network: .init())
        let allowed = try makeProjectFixture(
            network: .init(mode: .allowListedHTTPS, allowedHosts: ["api.example.com"])
        )
        defer {
            try? FileManager.default.removeItem(at: denied.rootURL)
            try? FileManager.default.removeItem(at: allowed.rootURL)
        }

        let compiler = ForgeRuntimeWebKitNetworkPolicyCompiler()
        let deniedReceipt = try await compiler.compile(denied.launchRequest.authorization.network)
        let allowedReceipt = try await compiler.compile(allowed.launchRequest.authorization.network)
        XCTAssertEqual(deniedReceipt.policy, denied.launchRequest.authorization.network)
        XCTAssertEqual(allowedReceipt.policy, allowed.launchRequest.authorization.network)
    }

    func testReceiptBoundInternalConstructorRejectsPersistentDefaultWebsiteDataStore() async throws {
        let fixture = try makeProjectFixture(network: .init())
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let receipt = try await ForgeRuntimeWebKitNetworkPolicyCompiler()
            .compile(fixture.launchRequest.authorization.network)
        let webView = WKWebView(frame: .zero, configuration: .init())
        XCTAssertTrue(webView.configuration.websiteDataStore.isPersistent)

        XCTAssertThrowsError(
            try ForgeRuntimeWebKitSemanticHost(webView: webView, networkPolicyReceipt: receipt)
        ) { error in
            XCTAssertEqual(
                error as? ForgeRuntimeWebKitSemanticHostError,
                .persistentWebsiteDataStoreNotAllowed
            )
        }
    }

    func testProductionFactoryCreatesFreshEphemeralWebsiteDataStorePerContext() async throws {
        let fixture = try makeProjectFixture(network: .init())
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let receipt = try await ForgeRuntimeWebKitNetworkPolicyCompiler()
            .compile(fixture.launchRequest.authorization.network)

        let first = try ForgeRuntimeWebKitSemanticHost.makeIsolatedContext(
            networkPolicyReceipt: receipt
        )
        let second = try ForgeRuntimeWebKitSemanticHost.makeIsolatedContext(
            networkPolicyReceipt: receipt
        )
        let firstStore = first.webView.configuration.websiteDataStore
        let secondStore = second.webView.configuration.websiteDataStore

        XCTAssertFalse(firstStore.isPersistent)
        XCTAssertFalse(secondStore.isPersistent)
        XCTAssertFalse(
            firstStore === secondStore,
            "Every production runtime context must own a distinct in-memory WebKit data store"
        )
    }

    func testProductionFactoryRejectsReceiptFromDifferentNetworkAuthorityBeforeLoad() async throws {
        let denied = try makeProjectFixture(network: .init())
        let allowed = try makeProjectFixture(
            network: .init(mode: .allowListedHTTPS, allowedHosts: ["api.example.com"])
        )
        defer {
            try? FileManager.default.removeItem(at: denied.rootURL)
            try? FileManager.default.removeItem(at: allowed.rootURL)
        }

        let receipt = try await ForgeRuntimeWebKitNetworkPolicyCompiler()
            .compile(denied.launchRequest.authorization.network)
        let context = try ForgeRuntimeWebKitSemanticHost.makeIsolatedContext(
            networkPolicyReceipt: receipt
        )
        let session = try makeSession(for: allowed.launchRequest, sessionID: "session-network-mismatch")

        XCTAssertThrowsError(try context.host.load(allowed.launchRequest, for: session)) { error in
            XCTAssertEqual(error as? ForgeRuntimeWebKitSemanticHostError, .networkPolicyMismatch)
        }
        XCTAssertNil(context.webView.url, "A mismatched network receipt must fail before WebKit navigation")
    }

    func testProductionFactoryStillLoadsLocalGeneratedArtifact() async throws {
        let fixture = try makeProjectFixture(network: .init())
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let receipt = try await ForgeRuntimeWebKitNetworkPolicyCompiler()
            .compile(fixture.launchRequest.authorization.network)
        let context = try ForgeRuntimeWebKitSemanticHost.makeIsolatedContext(
            networkPolicyReceipt: receipt
        )
        XCTAssertFalse(context.webView.configuration.websiteDataStore.isPersistent)
        let delegate = ForwardingNavigationDelegate(host: context.host)
        let didFinish = expectation(description: "isolated local artifact finished")
        delegate.didFinishExpectation = didFinish
        context.webView.navigationDelegate = delegate
        let session = try makeSession(for: fixture.launchRequest, sessionID: "session-denied-network")

        _ = try context.host.load(fixture.launchRequest, for: session)
        await fulfillment(of: [didFinish], timeout: 8)
        XCTAssertEqual(
            context.webView.url?.standardizedFileURL,
            fixture.launchRequest.entryPointURL.standardizedFileURL
        )
        withExtendedLifetime(delegate) {}
    }

    func testOrdinaryImportCannotConstructUnfilteredHost() throws {
        let diagnostics = try typecheckExternalConsumer(
            source: """
            import ForgeRuntimeWebKitHost
            import WebKit

            let webView = WKWebView(frame: .zero, configuration: .init())
            _ = ForgeRuntimeWebKitSemanticHost(webView: webView)
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("extra argument")
                || diagnostics.localizedCaseInsensitiveContains("initializer"),
            "Expected ordinary import to reject the unfiltered initializer, got: \(diagnostics)"
        )
    }

    func testOrdinaryImportCannotInjectCallerOwnedWebViewEvenWithReceipt() throws {
        let diagnostics = try typecheckExternalConsumer(
            source: """
            import ForgeRuntimeWebKitHost
            import WebKit

            func forge(
                _ webView: WKWebView,
                _ receipt: ForgeRuntimeWebKitNetworkPolicyReceipt
            ) throws {
                _ = try ForgeRuntimeWebKitSemanticHost(
                    webView: webView,
                    networkPolicyReceipt: receipt
                )
            }
            """
        )

        XCTAssertTrue(
            diagnostics.localizedCaseInsensitiveContains("inaccessible")
                || diagnostics.localizedCaseInsensitiveContains("initializer"),
            "Expected ordinary import to reject caller-owned receipt-bound WebView injection, got: \(diagnostics)"
        )
    }

    private func decodedRules(for policy: ForgeAuthorizedNetworkPolicy) throws -> [[String: Any]] {
        let source = try ForgeRuntimeWebKitNetworkRuleSource.encoded(for: policy)
        let object = try JSONSerialization.jsonObject(with: Data(source.utf8))
        return try XCTUnwrap(object as? [[String: Any]])
    }

    private func trigger(in rule: [String: Any]) -> [String: Any] {
        rule["trigger"] as? [String: Any] ?? [:]
    }

    private func action(in rule: [String: Any]) -> [String: Any] {
        rule["action"] as? [String: Any] ?? [:]
    }

    private func makeProjectFixture(network: ForgeNetworkPolicy) throws -> ProjectFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaforge-webkit-network-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let entryPointURL = rootURL.appendingPathComponent("index.html")
        try "<p>network policy fixture</p>".write(
            to: entryPointURL,
            atomically: true,
            encoding: .utf8
        )
        let projectID = "network-policy-project"
        let manifest = ForgeProjectManifest(
            projectID: projectID,
            projectVersion: "rev-network",
            runtimeVersion: .init(major: 1, minor: 0),
            display: .init(name: "Network Policy Fixture"),
            storage: .init(namespace: projectID, quotaBytes: 1_048_576),
            network: network
        )
        try JSONEncoder().encode(manifest).write(
            to: rootURL.appendingPathComponent(ForgeRuntimeProjectLoader.defaultManifestPath),
            options: .atomic
        )
        let hostSupport = ForgeRuntimeHostSupport(
            supportedManifestMajor: 1,
            maximumManifestMinor: 0,
            supportedRuntimeMajor: 1,
            maximumRuntimeMinor: 0,
            supportedCapabilityIDs: [],
            curatedModuleVersions: [:],
            supportsMixedOrientation: false,
            maximumStorageQuotaBytes: 8 * 1_048_576
        )
        let request = try ForgeRuntimeProjectLoader().load(
            projectRootURL: rootURL,
            expectedProjectID: projectID,
            host: hostSupport
        )
        return ProjectFixture(rootURL: rootURL, launchRequest: request)
    }

    private func makeSession(
        for launchRequest: ForgeRuntimeLaunchRequest,
        sessionID: String
    ) throws -> ForgeRuntimeAutomationSession {
        let policy = try ForgeRuntimeAutomationPolicy(
            allowedCapabilities: [.activateControl],
            maximumInteractions: 2
        )
        return try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: launchRequest.authorization,
            sessionID: sessionID,
            expectedSourceRevision: launchRequest.authorization.projectVersion,
            requestedCapabilities: [.activateControl],
            policy: policy
        )
    }

    private func typecheckExternalConsumer(source: String) throws -> String {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaforge-webkit-network-static-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("ExternalConsumer.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "swiftc",
            "-typecheck",
            "-swift-version",
            "6",
            "-I",
            try activeModulesURL().path,
            sourceURL.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertNotEqual(process.terminationStatus, 0, "Unsafe external WebKit host construction unexpectedly compiled")
        XCTAssertFalse(
            diagnostics.localizedCaseInsensitiveContains("no such module 'forgeruntimewebkithost'"),
            "Static probe failed before reaching the host API: \(diagnostics)"
        )
        return diagnostics
    }

    private func activeModulesURL() throws -> URL {
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<10 {
            let modulesURL = directory.appendingPathComponent("Modules", isDirectory: true)
            let moduleURL = modulesURL.appendingPathComponent("ForgeRuntimeWebKitHost.swiftmodule")
            if FileManager.default.fileExists(atPath: moduleURL.path) {
                return modulesURL
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        throw NSError(
            domain: "ForgeRuntimeWebKitNetworkPolicyTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "ForgeRuntimeWebKitHost module missing from test ancestry"]
        )
    }
}
