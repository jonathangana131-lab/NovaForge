import ForgeRuntime
@testable import ForgeRuntimeWebKitHost
import WebKit
import XCTest

@MainActor
final class ForgeRuntimeWebKitSemanticHostTests: XCTestCase {
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

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            host.navigationDidFail(navigation, in: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            host.webContentProcessDidTerminate(in: webView)
        }
    }

    private struct ProjectFixture {
        let rootURL: URL
        let launchRequest: ForgeRuntimeLaunchRequest
    }

    func testHostInstallsDocumentStartSemanticBootstrap() {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        _ = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let scripts = webView.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts[0].injectionTime, .atDocumentStart)
        XCTAssertTrue(scripts[0].isForMainFrameOnly)
        XCTAssertTrue(scripts[0].source.contains("__novaForgeHostSemanticAutomationV1"))
    }

    func testExecuteFailsBeforeValidatedArtifactNavigationIsReady() async throws {
        let webView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let fixture = try makeProjectFixture(projectID: "project-a", revision: "rev-123")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let session = try makeSession(for: fixture.launchRequest, sessionID: "session-1")
        do {
            _ = try await host.execute(makeAuthorizedControl(session: session))
            XCTFail("Expected navigation readiness failure")
        } catch let error as ForgeRuntimeWebKitSemanticHostError {
            XCTAssertEqual(error, .navigationNotReady)
        }
    }

    func testLoadRejectsLaunchRequestFromDifferentAutomationSession() throws {
        let first = try makeProjectFixture(projectID: "project-a", revision: "rev-a")
        let second = try makeProjectFixture(projectID: "project-b", revision: "rev-b")
        defer {
            try? FileManager.default.removeItem(at: first.rootURL)
            try? FileManager.default.removeItem(at: second.rootURL)
        }
        let mismatchedSession = try makeSession(for: second.launchRequest, sessionID: "session-b")
        let webView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        XCTAssertThrowsError(try host.load(first.launchRequest, for: mismatchedSession)) { error in
            XCTAssertEqual(error as? ForgeRuntimeWebKitSemanticHostError, .loadIdentityMismatch)
        }
    }

    func testRealWebKitDispatchClicksControlInValidatedArtifactNavigation() async throws {
        let fixture = try makeProjectFixture(
            projectID: "project-a",
            revision: "rev-123",
            html: """
            <!doctype html>
            <html><body>
              <button data-novaforge-control="play"
                      onclick="document.body.dataset.clicked='yes'">Play</button>
            </body></html>
            """
        )
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let session = try makeSession(for: fixture.launchRequest, sessionID: "session-1")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 640), configuration: configuration)
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let delegate = ForwardingNavigationDelegate(host: host)
        let didFinish = expectation(description: "validated artifact navigation finished")
        delegate.didFinishExpectation = didFinish
        webView.navigationDelegate = delegate
        _ = try host.load(fixture.launchRequest, for: session)
        await fulfillment(of: [didFinish], timeout: 8)

        let observation = try await host.execute(makeAuthorizedControl(session: session))
        XCTAssertEqual(observation.pageObservation.candidateDisposition, .delivered)
        XCTAssertEqual(observation.loadSubject.sessionID, "session-1")
        XCTAssertEqual(observation.loadSubject.projectID, "project-a")
        XCTAssertEqual(observation.loadSubject.sourceRevision, "rev-123")
        XCTAssertEqual(observation.loadSubject.runtimeVersion, fixture.launchRequest.authorization.runtimeVersion)
        XCTAssertEqual(observation.loadSubject.entryPointURL, fixture.launchRequest.entryPointURL)
        XCTAssertEqual(observation.authorizationReceipt.authorization.sourceRevision, "rev-123")
        XCTAssertEqual(observation.authorizationReceipt.runtimeVersion, session.runtimeVersion)
        let clicked = try await webView.evaluateJavaScript("document.body.dataset.clicked") as? String
        XCTAssertEqual(clicked, "yes")
        withExtendedLifetime(delegate) {}
    }

    func testAuthorizedInteractionCannotReplayAgainstDifferentValidatedArtifact() async throws {
        let authorizedFixture = try makeProjectFixture(projectID: "project-a", revision: "rev-a")
        let loadedFixture = try makeProjectFixture(projectID: "project-b", revision: "rev-b")
        defer {
            try? FileManager.default.removeItem(at: authorizedFixture.rootURL)
            try? FileManager.default.removeItem(at: loadedFixture.rootURL)
        }
        let authorizedSession = try makeSession(for: authorizedFixture.launchRequest, sessionID: "session-a")
        let loadedSession = try makeSession(for: loadedFixture.launchRequest, sessionID: "session-b")
        let webView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let delegate = ForwardingNavigationDelegate(host: host)
        let didFinish = expectation(description: "different artifact navigation finished")
        delegate.didFinishExpectation = didFinish
        webView.navigationDelegate = delegate
        _ = try host.load(loadedFixture.launchRequest, for: loadedSession)
        await fulfillment(of: [didFinish], timeout: 8)
        do {
            _ = try await host.execute(makeAuthorizedControl(session: authorizedSession))
            XCTFail("Expected cross-artifact semantic replay to fail closed")
        } catch let error as ForgeRuntimeWebKitSemanticHostError {
            XCTAssertEqual(error, .artifactIdentityMismatch)
        }
        withExtendedLifetime(delegate) {}
    }

    func testAuthorizedInteractionCannotReplayAcrossRuntimeVersions() async throws {
        let runtimeV1 = ForgeRuntimeVersion(major: 1, minor: 0)
        let runtimeV2 = ForgeRuntimeVersion(major: 2, minor: 0)
        let loadedFixture = try makeProjectFixture(
            projectID: "project-a",
            revision: "rev-123",
            runtimeVersion: runtimeV1
        )
        let authorizedFixture = try makeProjectFixture(
            projectID: "project-a",
            revision: "rev-123",
            runtimeVersion: runtimeV2
        )
        defer {
            try? FileManager.default.removeItem(at: loadedFixture.rootURL)
            try? FileManager.default.removeItem(at: authorizedFixture.rootURL)
        }
        let loadedSession = try makeSession(for: loadedFixture.launchRequest, sessionID: "shared-session")
        let authorizedSession = try makeSession(for: authorizedFixture.launchRequest, sessionID: "shared-session")
        let webView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let delegate = ForwardingNavigationDelegate(host: host)
        let didFinish = expectation(description: "validated navigation finished")
        delegate.didFinishExpectation = didFinish
        webView.navigationDelegate = delegate
        _ = try host.load(loadedFixture.launchRequest, for: loadedSession)
        await fulfillment(of: [didFinish], timeout: 8)
        do {
            _ = try await host.execute(makeAuthorizedControl(session: authorizedSession))
            XCTFail("Expected cross-runtime semantic replay to fail closed")
        } catch let error as ForgeRuntimeWebKitSemanticHostError {
            XCTAssertEqual(error, .artifactIdentityMismatch)
        }
        withExtendedLifetime(delegate) {}
    }

    func testUnboundNewNavigationInvalidatesFinishedArtifactGeneration() async throws {
        let fixture = try makeProjectFixture(projectID: "project-a", revision: "rev-123")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let session = try makeSession(for: fixture.launchRequest, sessionID: "session-1")
        let webView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let delegate = ForwardingNavigationDelegate(host: host)
        let firstFinish = expectation(description: "validated navigation finished")
        delegate.didFinishExpectation = firstFinish
        webView.navigationDelegate = delegate
        _ = try host.load(fixture.launchRequest, for: session)
        await fulfillment(of: [firstFinish], timeout: 8)
        let secondNavigation = try XCTUnwrap(webView.loadHTMLString("<p>unbound generation</p>", baseURL: nil))
        host.navigationDidStart(secondNavigation, in: webView)
        do {
            _ = try await host.execute(makeAuthorizedControl(session: session))
            XCTFail("Expected an unbound navigation to invalidate semantic readiness")
        } catch let error as ForgeRuntimeWebKitSemanticHostError {
            XCTAssertEqual(error, .navigationNotReady)
        }
        withExtendedLifetime(delegate) {}
    }

    func testProcessTerminationInvalidatesBoundArtifactNavigation() async throws {
        let fixture = try makeProjectFixture(projectID: "project-a", revision: "rev-123")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let session = try makeSession(for: fixture.launchRequest, sessionID: "session-1")
        let webView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let delegate = ForwardingNavigationDelegate(host: host)
        let didFinish = expectation(description: "validated navigation finished")
        delegate.didFinishExpectation = didFinish
        webView.navigationDelegate = delegate
        _ = try host.load(fixture.launchRequest, for: session)
        await fulfillment(of: [didFinish], timeout: 8)
        host.webContentProcessDidTerminate(in: webView)
        do {
            _ = try await host.execute(makeAuthorizedControl(session: session))
            XCTFail("Expected terminated WebKit process to invalidate execution")
        } catch let error as ForgeRuntimeWebKitSemanticHostError {
            XCTAssertEqual(error, .webContentProcessTerminated)
        }
        withExtendedLifetime(delegate) {}
    }

    func testCallbacksFromAnotherWebViewCannotAuthorizeBoundHost() async throws {
        let boundWebView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: boundWebView)
        let otherWebView = WKWebView(frame: .zero, configuration: .init())
        let navigation = try XCTUnwrap(otherWebView.loadHTMLString("<button data-novaforge-control='play'>Play</button>", baseURL: nil))
        host.navigationDidStart(navigation, in: otherWebView)
        host.navigationDidFinish(navigation, in: otherWebView)
        let fixture = try makeProjectFixture(projectID: "project-a", revision: "rev-123")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let session = try makeSession(for: fixture.launchRequest, sessionID: "session-1")
        do {
            _ = try await host.execute(makeAuthorizedControl(session: session))
            XCTFail("Expected callbacks from an unbound WebKit instance to be ignored")
        } catch let error as ForgeRuntimeWebKitSemanticHostError {
            XCTAssertEqual(error, .navigationNotReady)
        }
    }

    private func makeProjectFixture(
        projectID: String,
        revision: String,
        runtimeVersion: ForgeRuntimeVersion = .init(major: 1, minor: 0),
        html: String = "<button data-novaforge-control='play'>Play</button>"
    ) throws -> ProjectFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("novaforge-webkit-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let entryPointURL = rootURL.appendingPathComponent("index.html")
        try html.write(to: entryPointURL, atomically: true, encoding: .utf8)
        let manifest = ForgeProjectManifest(
            projectID: projectID,
            projectVersion: revision,
            runtimeVersion: runtimeVersion,
            display: .init(name: projectID),
            storage: .init(namespace: projectID, quotaBytes: 1_048_576)
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(
            to: rootURL.appendingPathComponent(ForgeRuntimeProjectLoader.defaultManifestPath),
            options: .atomic
        )
        let host = ForgeRuntimeHostSupport(
            maximumFormatVersion: .init(major: 1, minor: 0),
            runtimeVersion: runtimeVersion,
            supportedCapabilityIDs: [],
            maximumStorageQuotaBytes: 8 * 1_048_576,
            curatedModuleVersions: [:]
        )
        let request = try ForgeRuntimeProjectLoader().load(
            projectRootURL: rootURL,
            expectedProjectID: projectID,
            host: host
        )
        return ProjectFixture(rootURL: rootURL, launchRequest: request)
    }

    private func makeSession(
        for launchRequest: ForgeRuntimeLaunchRequest,
        sessionID: String
    ) throws -> ForgeRuntimeAutomationSession {
        let policy = try ForgeRuntimeAutomationPolicy(
            allowedCapabilities: [.activateControl],
            maximumInteractions: 4
        )
        return try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: launchRequest.authorization,
            sessionID: sessionID,
            expectedSourceRevision: launchRequest.authorization.projectVersion,
            requestedCapabilities: [.activateControl],
            policy: policy
        )
    }

    private func makeAuthorizedControl(
        session: ForgeRuntimeAutomationSession
    ) throws -> ForgeRuntimeSessionBoundAuthorizedSemanticInteraction {
        let envelope = ForgeRuntimeSemanticInteractionEnvelope(
            requestID: "request-1",
            sessionID: session.sessionID,
            projectID: session.projectID,
            sourceRevision: session.sourceRevision,
            sequence: 0,
            kind: ForgeRuntimeSemanticInteractionKind.activateControl.rawValue,
            targetID: "play"
        )
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session)
        return try gate.authorizeSessionBound(JSONEncoder().encode(envelope))
    }
}
