import Foundation
import ForgeRuntime
import WebKit

public enum ForgeRuntimeWebKitSemanticHostError: Error, Equatable, Sendable {
    case webViewReleased
    case persistentWebsiteDataStoreNotAllowed
    case loadIdentityMismatch
    case networkPolicyMismatch
    case loadFailed
    case navigationNotReady
    case artifactIdentityMismatch
    case staleNavigation
    case webContentProcessTerminated
    case nonStringBridgeResult
}

/// Exact generated-artifact identity attached by the host to the `WKNavigation` it initiates.
///
/// Construction remains package-owned and non-Codable. The subject is derived from a validated
/// `ForgeRuntimeLaunchRequest` plus its matching automation session; page JavaScript cannot mint or
/// rewrite it.
public struct ForgeRuntimeWebKitArtifactLoadSubject: Equatable, Sendable {
    public let sessionID: String
    public let projectID: String
    public let sourceRevision: String
    public let runtimeVersion: ForgeRuntimeVersion
    public let entryPointURL: URL

    init(
        sessionID: String,
        projectID: String,
        sourceRevision: String,
        runtimeVersion: ForgeRuntimeVersion,
        entryPointURL: URL
    ) {
        self.sessionID = sessionID
        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.runtimeVersion = runtimeVersion
        self.entryPointURL = entryPointURL
    }
}

/// Host-observed result for one semantic dispatch evaluated by the exact bound generated-artifact
/// navigation generation.
///
/// Construction is package-owned and this value is intentionally non-Codable. It is stronger than
/// page-authored JSON because the host proves both which validated artifact load and which WebKit
/// navigation evaluated the command. It is still *dispatch observation*, not gameplay/Completion
/// proof; downstream evidence must bind post-action app/game state.
public struct ForgeRuntimeWebKitSemanticHostObservation: Equatable, Sendable {
    public let navigationGenerationID: UUID
    public let loadSubject: ForgeRuntimeWebKitArtifactLoadSubject
    public let authorizationReceipt: ForgeRuntimeSessionBoundSemanticInteractionAuthorizationReceipt
    public let pageObservation: ForgeRuntimeWebSemanticDispatchObservation

    init(
        navigationGenerationID: UUID,
        loadSubject: ForgeRuntimeWebKitArtifactLoadSubject,
        authorizationReceipt: ForgeRuntimeSessionBoundSemanticInteractionAuthorizationReceipt,
        pageObservation: ForgeRuntimeWebSemanticDispatchObservation
    ) {
        self.navigationGenerationID = navigationGenerationID
        self.loadSubject = loadSubject
        self.authorizationReceipt = authorizationReceipt
        self.pageObservation = pageObservation
    }
}

/// Production-owned pair for one isolated generated-artifact WebKit runtime.
///
/// A fresh nonpersistent `WKWebsiteDataStore` is created for every context, so product wiring does
/// not accidentally reuse cookies, local storage, IndexedDB, cache, or other browser-owned state
/// across generated projects. Keep this context alive for as long as its WebView is presented.
@MainActor
public struct ForgeRuntimeWebKitSemanticHostContext {
    public let webView: WKWebView
    public let host: ForgeRuntimeWebKitSemanticHost

    init(webView: WKWebView, host: ForgeRuntimeWebKitSemanticHost) {
        self.webView = webView
        self.host = host
    }
}

/// Apple-platform host adapter for the package-owned semantic automation contract.
///
/// The app keeps its existing `WKNavigationDelegate`; that delegate forwards start/finish/failure
/// and process-termination callbacks into this object. Semantic readiness is possible only for a
/// navigation initiated through `load(_:for:)`, which binds a validated launch request to its exact
/// automation session before the page can become ready. A page-initiated/unbound navigation,
/// failure, or WebKit process termination invalidates semantic execution immediately.
///
/// Production construction is package-owned through `makeIsolatedContext(...)`. Every call creates
/// a new `WKWebViewConfiguration`, a new nonpersistent website data store, and a new WebView before
/// installing the package-issued network-policy receipt. This prevents accidental cross-project
/// sharing of browser-owned state and keeps durable project persistence in the separately
/// authorized Forge storage layer and its namespace/quota policy.
///
/// The semantic bootstrap is injected at document start into a named isolated `WKContentWorld`.
/// Generated page JavaScript cannot call this native Swift API or construct host observations.
@MainActor
public final class ForgeRuntimeWebKitSemanticHost {
    public static let contentWorldName = "NovaForge.SemanticAutomation.v1"

    private static let contentWorld = WKContentWorld.world(name: contentWorldName)

    private weak var webView: WKWebView?
    private let adapter: ForgeRuntimeWebSemanticAutomationAdapter
    private let preparedNetworkPolicy: ForgeAuthorizedNetworkPolicy?
    private let bypassesNetworkPolicyForPackageTests: Bool
    private var activeNavigation: WKNavigation?
    private var readyNavigation: WKNavigation?
    private var activeLoadSubject: ForgeRuntimeWebKitArtifactLoadSubject?
    private var navigationGenerationID = UUID()
    private var processTerminated = false

    /// Creates the only public production WebKit context.
    ///
    /// The factory owns creation of the WebView and calls `WKWebsiteDataStore.nonPersistent()` for
    /// every context rather than trusting a caller-supplied configuration. A package-issued network
    /// receipt is installed before generated content can load.
    public static func makeIsolatedContext(
        networkPolicyReceipt: ForgeRuntimeWebKitNetworkPolicyReceipt,
        adapter: ForgeRuntimeWebSemanticAutomationAdapter = .init()
    ) throws -> ForgeRuntimeWebKitSemanticHostContext {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let host = try ForgeRuntimeWebKitSemanticHost(
            webView: webView,
            networkPolicyReceipt: networkPolicyReceipt,
            adapter: adapter
        )
        return ForgeRuntimeWebKitSemanticHostContext(webView: webView, host: host)
    }

    /// Package-only receipt-bound constructor used by the production factory and focused tests.
    /// Ordinary imports cannot pass an existing WebView, preventing product wiring from accidentally
    /// sharing one nonpersistent data-store object across generated projects.
    init(
        webView: WKWebView,
        networkPolicyReceipt: ForgeRuntimeWebKitNetworkPolicyReceipt,
        adapter: ForgeRuntimeWebSemanticAutomationAdapter = .init()
    ) throws {
        guard !webView.configuration.websiteDataStore.isPersistent else {
            throw ForgeRuntimeWebKitSemanticHostError.persistentWebsiteDataStoreNotAllowed
        }
        self.webView = webView
        self.adapter = adapter
        self.preparedNetworkPolicy = networkPolicyReceipt.policy
        self.bypassesNetworkPolicyForPackageTests = false
        webView.configuration.userContentController.add(networkPolicyReceipt.ruleList)
        Self.installSemanticBootstrap(in: webView)
    }

    /// Package-only constructor retained for behavioral tests that isolate semantic/navigation
    /// logic from content-rule compilation and WebKit storage policy. Ordinary imports cannot
    /// access this unfiltered path.
    init(
        webView: WKWebView,
        adapter: ForgeRuntimeWebSemanticAutomationAdapter = .init()
    ) {
        self.webView = webView
        self.adapter = adapter
        self.preparedNetworkPolicy = nil
        self.bypassesNetworkPolicyForPackageTests = true
        Self.installSemanticBootstrap(in: webView)
    }

    /// Initiates the exact generated artifact navigation that semantic automation may target.
    ///
    /// `ForgeRuntimeLaunchRequest` is package-created by the validated project loader. The supplied
    /// automation session must match the same project, source revision and runtime version before
    /// any WebKit load starts. Production hosts additionally require the precompiled WebKit network
    /// policy to equal the exact launch authority. Read access is reduced to the least common
    /// directory required by the validated entry point and declared assets instead of accepting an
    /// arbitrary caller root.
    @discardableResult
    public func load(
        _ launchRequest: ForgeRuntimeLaunchRequest,
        for session: ForgeRuntimeAutomationSession
    ) throws -> WKNavigation {
        guard let webView else {
            throw ForgeRuntimeWebKitSemanticHostError.webViewReleased
        }
        let authorization = launchRequest.authorization
        guard authorization.projectID == session.projectID,
              authorization.projectVersion == session.sourceRevision,
              authorization.runtimeVersion == session.runtimeVersion else {
            throw ForgeRuntimeWebKitSemanticHostError.loadIdentityMismatch
        }
        if !bypassesNetworkPolicyForPackageTests {
            guard preparedNetworkPolicy == authorization.network else {
                throw ForgeRuntimeWebKitSemanticHostError.networkPolicyMismatch
            }
        }

        let subject = ForgeRuntimeWebKitArtifactLoadSubject(
            sessionID: session.sessionID,
            projectID: session.projectID,
            sourceRevision: session.sourceRevision,
            runtimeVersion: session.runtimeVersion,
            entryPointURL: launchRequest.entryPointURL
        )
        guard let navigation = webView.loadFileURL(
            launchRequest.entryPointURL,
            allowingReadAccessTo: Self.minimumReadAccessURL(for: launchRequest)
        ) else {
            throw ForgeRuntimeWebKitSemanticHostError.loadFailed
        }

        activeNavigation = navigation
        readyNavigation = nil
        activeLoadSubject = subject
        processTerminated = false
        navigationGenerationID = UUID()
        return navigation
    }

    public func navigationDidStart(_ navigation: WKNavigation, in candidateWebView: WKWebView) {
        guard candidateWebView === webView else { return }
        guard navigation === activeNavigation, activeLoadSubject != nil else {
            activeNavigation = navigation
            readyNavigation = nil
            activeLoadSubject = nil
            processTerminated = false
            navigationGenerationID = UUID()
            return
        }
        readyNavigation = nil
        processTerminated = false
    }

    public func navigationDidFinish(_ navigation: WKNavigation, in candidateWebView: WKWebView) {
        guard candidateWebView === webView,
              navigation === activeNavigation,
              activeLoadSubject != nil else { return }
        readyNavigation = navigation
    }

    public func navigationDidFail(_ navigation: WKNavigation?, in candidateWebView: WKWebView) {
        guard candidateWebView === webView else { return }
        guard navigation == nil || navigation === activeNavigation else { return }
        invalidateActiveLoad(processTerminated: false)
    }

    public func webContentProcessDidTerminate(in candidateWebView: WKWebView) {
        guard candidateWebView === webView else { return }
        invalidateActiveLoad(processTerminated: true)
    }

    /// Evaluates one package-authorized semantic interaction in the isolated automation world.
    ///
    /// The interaction must match the exact session/project/source/runtime identity that initiated
    /// the current generated-artifact load. The navigation generation and load subject are captured
    /// before evaluation and revalidated afterward so reload/navigation/process races fail closed.
    public func execute(
        _ authorized: ForgeRuntimeSessionBoundAuthorizedSemanticInteraction
    ) async throws -> ForgeRuntimeWebKitSemanticHostObservation {
        guard let webView else {
            throw ForgeRuntimeWebKitSemanticHostError.webViewReleased
        }
        guard !processTerminated else {
            throw ForgeRuntimeWebKitSemanticHostError.webContentProcessTerminated
        }
        guard let activeNavigation,
              let readyNavigation,
              let activeLoadSubject,
              activeNavigation === readyNavigation else {
            throw ForgeRuntimeWebKitSemanticHostError.navigationNotReady
        }

        let request = authorized.request
        guard request.sessionID == activeLoadSubject.sessionID,
              request.projectID == activeLoadSubject.projectID,
              request.sourceRevision == activeLoadSubject.sourceRevision,
              authorized.runtimeVersion == activeLoadSubject.runtimeVersion else {
            throw ForgeRuntimeWebKitSemanticHostError.artifactIdentityMismatch
        }

        let capturedNavigation = activeNavigation
        let capturedLoadSubject = activeLoadSubject
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
              capturedNavigation === self.readyNavigation,
              capturedLoadSubject == self.activeLoadSubject else {
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
            loadSubject: capturedLoadSubject,
            authorizationReceipt: authorized.authorizationReceipt(),
            pageObservation: pageObservation
        )
    }

    private func invalidateActiveLoad(processTerminated: Bool) {
        self.processTerminated = processTerminated
        readyNavigation = nil
        activeNavigation = nil
        activeLoadSubject = nil
        navigationGenerationID = UUID()
    }

    private static func installSemanticBootstrap(in webView: WKWebView) {
        let script = WKUserScript(
            source: ForgeRuntimeWebSemanticAutomationAdapter.bootstrapJavaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: contentWorld
        )
        webView.configuration.userContentController.addUserScript(script)
    }

    private static func minimumReadAccessURL(for request: ForgeRuntimeLaunchRequest) -> URL {
        let directories = ([request.entryPointURL] + Array(request.assetURLs.values)).map {
            $0.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        }
        guard var commonComponents = directories.first?.pathComponents else {
            return request.entryPointURL.deletingLastPathComponent()
        }

        for directory in directories.dropFirst() {
            let candidate = directory.pathComponents
            let count = min(commonComponents.count, candidate.count)
            var sharedCount = 0
            while sharedCount < count && commonComponents[sharedCount] == candidate[sharedCount] {
                sharedCount += 1
            }
            commonComponents = Array(commonComponents.prefix(sharedCount))
        }

        let path = NSString.path(withComponents: commonComponents)
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
