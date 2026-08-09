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

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            if let navigation {
                host.navigationDidStart(navigation, in: webView)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let navigation {
                host.navigationDidFinish(navigation, in: webView)
            }
            didFinishExpectation?.fulfill()
            didFinishExpectation = nil
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            host.navigationDidFail(navigation, in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            host.navigationDidFail(navigation, in: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            host.webContentProcessDidTerminate(in: webView)
        }
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

    func testExecuteFailsBeforeNavigationIsReady() async throws {
        let webView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let authorized = try makeAuthorizedControl()

        do {
            _ = try await host.execute(authorized)
            XCTFail("Expected navigation readiness failure")
        } catch let error as ForgeRuntimeWebKitSemanticHostError {
            XCTAssertEqual(error, .navigationNotReady)
        }
    }

    func testRealWebKitDispatchClicksSemanticControlInBoundNavigation() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: .init(x: 0, y: 0, width: 320, height: 640),
            configuration: configuration
        )
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let delegate = ForwardingNavigationDelegate(host: host)
        let didFinish = expectation(description: "artifact navigation finished")
        delegate.didFinishExpectation = didFinish
        webView.navigationDelegate = delegate

        webView.loadHTMLString(
            """
            <!doctype html>
            <html><body>
              <button data-novaforge-control="play"
                      onclick="document.body.dataset.clicked='yes'">Play</button>
            </body></html>
            """,
            baseURL: nil
        )
        await fulfillment(of: [didFinish], timeout: 8)

        let observation = try await host.execute(makeAuthorizedControl())
        XCTAssertEqual(observation.pageObservation.candidateDisposition, .delivered)
        XCTAssertEqual(observation.pageObservation.sourceRevision, "rev-123")
        XCTAssertEqual(observation.authorizationReceipt.sourceRevision, "rev-123")

        let clicked = try await webView.evaluateJavaScript("document.body.dataset.clicked") as? String
        XCTAssertEqual(clicked, "yes")
        withExtendedLifetime(delegate) {}
    }

    func testNewNavigationInvalidatesFinishedGenerationBeforeDispatch() async throws {
        let webView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let delegate = ForwardingNavigationDelegate(host: host)
        let firstFinish = expectation(description: "first navigation finished")
        delegate.didFinishExpectation = firstFinish
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            "<button data-novaforge-control='play'>Play</button>",
            baseURL: nil
        )
        await fulfillment(of: [firstFinish], timeout: 8)

        let secondNavigation = try XCTUnwrap(
            webView.loadHTMLString("<p>new generation</p>", baseURL: nil)
        )
        host.navigationDidStart(secondNavigation, in: webView)

        do {
            _ = try await host.execute(makeAuthorizedControl())
            XCTFail("Expected the in-flight navigation to invalidate readiness")
        } catch let error as ForgeRuntimeWebKitSemanticHostError {
            XCTAssertEqual(error, .navigationNotReady)
        }
        withExtendedLifetime(delegate) {}
    }

    func testProcessTerminationInvalidatesReadyNavigation() async throws {
        let webView = WKWebView(frame: .zero, configuration: .init())
        let host = ForgeRuntimeWebKitSemanticHost(webView: webView)
        let delegate = ForwardingNavigationDelegate(host: host)
        let didFinish = expectation(description: "navigation finished")
        delegate.didFinishExpectation = didFinish
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            "<button data-novaforge-control='play'>Play</button>",
            baseURL: nil
        )
        await fulfillment(of: [didFinish], timeout: 8)

        host.webContentProcessDidTerminate(in: webView)

        do {
            _ = try await host.execute(makeAuthorizedControl())
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
        let navigation = try XCTUnwrap(
            otherWebView.loadHTMLString(
                "<button data-novaforge-control='play'>Play</button>",
                baseURL: nil
            )
        )
        host.navigationDidStart(navigation, in: otherWebView)
        host.navigationDidFinish(navigation, in: otherWebView)

        do {
            _ = try await host.execute(makeAuthorizedControl())
            XCTFail("Expected callbacks from an unbound WebKit instance to be ignored")
        } catch let error as ForgeRuntimeWebKitSemanticHostError {
            XCTAssertEqual(error, .navigationNotReady)
        }
    }

    private func makeAuthorizedControl() throws -> ForgeRuntimeAuthorizedSemanticInteraction {
        let manifest = ForgeProjectManifest(
            projectID: "project-a",
            projectVersion: "rev-123",
            display: .init(name: "Project A"),
            storage: .init(namespace: "project-a", quotaBytes: 1_048_576)
        )
        let launch = try ForgeRuntimeManifestValidator().authorize(
            manifest,
            expectedProjectID: "project-a",
            host: .init()
        )
        let policy = try ForgeRuntimeAutomationPolicy(
            allowedCapabilities: [.activateControl],
            maximumInteractions: 4
        )
        let session = try ForgeRuntimeAutomationSessionAuthorizer().authorize(
            launchAuthorization: launch,
            sessionID: "session-1",
            expectedSourceRevision: "rev-123",
            requestedCapabilities: [.activateControl],
            policy: policy
        )
        let envelope = ForgeRuntimeSemanticInteractionEnvelope(
            requestID: "request-1",
            sessionID: "session-1",
            projectID: "project-a",
            sourceRevision: "rev-123",
            sequence: 0,
            kind: ForgeRuntimeSemanticInteractionKind.activateControl.rawValue,
            targetID: "play"
        )
        var gate = try ForgeRuntimeSemanticInteractionGate(session: session)
        return try gate.authorize(JSONEncoder().encode(envelope))
    }
}
