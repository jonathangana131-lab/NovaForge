import Foundation
import ForgeRuntime
import WebKit

public enum ForgeRuntimeWebKitSemanticHostError: Error, Equatable, Sendable {
    case webViewReleased
    case navigationNotReady
    case staleNavigation
    case webContentProcessTerminated
    case nonStringBridgeResult
}

/// Host-observed result for one semantic dispatch evaluated by the exact bound `WKWebView`
/// navigation generation.
///
/// Construction is package-owned and this value is intentionally non-Codable. It is stronger than
/// page-authored JSON because the host proves which WebKit navigation evaluated the command, but it
/// is still *dispatch observation*, not gameplay/Completion proof. Downstream runtime evidence must
/// bind the whole authorized interaction plus the appropriate app/game state evidence.
public struct ForgeRuntimeWebKitSemanticHostObservation: Equatable, Sendable {
    public let navigationGenerationID: UUID
    public let authorizationReceipt: ForgeRuntimeSemanticInteractionAuthorizationReceipt
    public let pageObservation: ForgeRuntimeWebSemanticDispatchObservation

    init(
        navigationGenerationID: UUID,
        authorizationReceipt: ForgeRuntimeSemanticInteractionAuthorizationReceipt,
        pageObservation: ForgeRuntimeWebSemanticDispatchObservation
    ) {
        self.navigationGenerationID = navigationGenerationID
        self.authorizationReceipt = authorizationReceipt
        self.pageObservation = pageObservation
    }
}

/// Apple-platform host adapter for the package-owned semantic automation contract.
///
/// The app keeps its existing `WKNavigationDelegate`; that delegate forwards start/finish/failure
/// and process-termination callbacks into this object. The host then permits semantic evaluation
/// only while the exact most-recent navigation object is still current and finished. A new
/// navigation, a failure, or a WebKit process termination invalidates the generation immediately.
///
/// The semantic bootstrap is injected at document start into a named isolated `WKContentWorld`.
/// Generated page JavaScript cannot call this native Swift API or construct host observations.
@MainActor
public final class ForgeRuntimeWebKitSemanticHost {
    public static let contentWorldName = "NovaForge.SemanticAutomation.v1"

    private static let contentWorld = WKContentWorld.world(name: contentWorldName)

    private weak var webView: WKWebView?
    private let adapter: ForgeRuntimeWebSemanticAutomationAdapter
    private var activeNavigation: WKNavigation?
    private var readyNavigation: WKNavigation?
    private var navigationGenerationID = UUID()
    private var processTerminated = false

    /// Installs the semantic bootstrap for subsequent documents in `webView` and binds this host to
    /// that exact WebKit instance. Call before the target artifact navigation begins.
    public init(
        webView: WKWebView,
        adapter: ForgeRuntimeWebSemanticAutomationAdapter = .init()
    ) {
        self.webView = webView
        self.adapter = adapter
        let script = WKUserScript(
            source: ForgeRuntimeWebSemanticAutomationAdapter.bootstrapJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: Self.contentWorld
        )
        webView.configuration.userContentController.addUserScript(script)
    }

    public func navigationDidStart(_ navigation: WKNavigation, in candidateWebView: WKWebView) {
        guard candidateWebView === webView else { return }
        activeNavigation = navigation
        readyNavigation = nil
        processTerminated = false
        navigationGenerationID = UUID()
    }

    public func navigationDidFinish(_ navigation: WKNavigation, in candidateWebView: WKWebView) {
        guard candidateWebView === webView, navigation === activeNavigation else { return }
        readyNavigation = navigation
    }

    public func navigationDidFail(_ navigation: WKNavigation?, in candidateWebView: WKWebView) {
        guard candidateWebView === webView else { return }
        guard navigation == nil || navigation === activeNavigation else { return }
        readyNavigation = nil
        activeNavigation = nil
        navigationGenerationID = UUID()
    }

    public func webContentProcessDidTerminate(in candidateWebView: WKWebView) {
        guard candidateWebView === webView else { return }
        processTerminated = true
        readyNavigation = nil
        activeNavigation = nil
        navigationGenerationID = UUID()
    }

    /// Evaluates one package-authorized semantic interaction in the isolated automation world.
    ///
    /// The navigation generation is captured before evaluation and revalidated after WebKit returns,
    /// so a navigation/reload/process change racing the JavaScript call fails closed instead of
    /// attaching an old page result to a new artifact generation.
    public func execute(
        _ authorized: ForgeRuntimeAuthorizedSemanticInteraction
    ) async throws -> ForgeRuntimeWebKitSemanticHostObservation {
        guard let webView else {
            throw ForgeRuntimeWebKitSemanticHostError.webViewReleased
        }
        guard !processTerminated else {
            throw ForgeRuntimeWebKitSemanticHostError.webContentProcessTerminated
        }
        guard let activeNavigation, let readyNavigation, activeNavigation === readyNavigation else {
            throw ForgeRuntimeWebKitSemanticHostError.navigationNotReady
        }

        let capturedNavigation = activeNavigation
        let capturedGenerationID = navigationGenerationID
        let plan = try adapter.makeDispatchPlan(for: authorized)
        let value = try await webView.evaluateJavaScript(
            plan.javaScript,
            in: nil,
            contentWorld: Self.contentWorld
        )

        guard !processTerminated,
              capturedGenerationID == navigationGenerationID,
              capturedNavigation === self.activeNavigation,
              capturedNavigation === self.readyNavigation else {
            throw ForgeRuntimeWebKitSemanticHostError.staleNavigation
        }
        guard let bridgeResultJSON = value as? String else {
            throw ForgeRuntimeWebKitSemanticHostError.nonStringBridgeResult
        }

        let pageObservation = try adapter.observeDispatchResult(
            for: authorized,
            bridgeResultJSON: bridgeResultJSON
        )
        return ForgeRuntimeWebKitSemanticHostObservation(
            navigationGenerationID: capturedGenerationID,
            authorizationReceipt: authorized.authorizationReceipt(),
            pageObservation: pageObservation
        )
    }
}
