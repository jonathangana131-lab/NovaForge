import SwiftUI
import UIKit
import WebKit

struct ArtifactPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let artifact: WorkspaceArtifact
    var workspace: SandboxWorkspace
    var openLandscapeFullScreen: ((WorkspaceArtifact) -> Void)? = nil
    var iterationPrompt: String? = nil
    var openChat: (() -> Void)? = nil

    @State private var content = ""
    @State private var fileURL: URL?
    @State private var fileSizeText = ""
    @State private var errorMessage: String?
    @State private var gameManifest: SwiftGameManifest?
    @State private var shareError: String?
    @State private var viewportMode: ArtifactViewportMode = .fit
    @State private var isFullScreenPresented = false
    @State private var isOpeningExternalFullScreen = false
    @State private var isRestoringPortrait = false
    @State private var reloadToken = UUID()

    var body: some View {
        ArtifactPreviewStudio(
            artifact: artifact,
            workspace: workspace,
            content: content,
            fileURL: fileURL,
            fileSizeText: fileSizeText,
            errorMessage: errorMessage,
            gameManifest: gameManifest,
            viewportMode: $viewportMode,
            reloadToken: reloadToken,
            isFullScreen: isFullScreenPresented,
            iterationPrompt: iterationPrompt,
            share: shareArtifact,
            reload: reloadPreview,
            openFullScreen: presentGameFullScreen,
            openChat: openChat,
            close: {
                if isFullScreenPresented {
                    exitGameFullScreen()
                } else {
                    dismiss()
                    ArtifactOrientationController.request(.portrait)
                }
            }
        )
        .task(id: artifact.path) {
            loadArtifact()
        }
        .onAppear {
            ArtifactOrientationController.allowAutoRotation()
            if UIDevice.current.orientation.isLandscape {
                presentGameFullScreen()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            if UIDevice.current.orientation.isPortrait {
                isRestoringPortrait = false
            }
            guard UIDevice.current.orientation.isLandscape, !isRestoringPortrait else { return }
            presentGameFullScreen()
        }
        .onDisappear {
            if !isFullScreenPresented && !isOpeningExternalFullScreen {
                ArtifactOrientationController.request(.portrait)
            }
        }
        .alert(
            "Share Failed",
            isPresented: Binding(
                get: { shareError != nil },
                set: { if !$0 { shareError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "NovaForge could not share this artifact.")
        }
    }

    private func loadArtifact() {
        do {
            let resolved = try workspace.resolve(artifact.path)
            fileURL = resolved
            fileSizeText = ArtifactPreviewSheet.byteText(for: resolved)
            gameManifest = nil
            if artifact.isWebPage {
                content = ""
            } else if artifact.isImageArtifact || artifact.isPDFArtifact {
                content = ""
            } else if artifact.isSwiftGameArtifact {
                content = try workspace.read(artifact.path)
                gameManifest = try JSONDecoder().decode(SwiftGameManifest.self, from: Data(content.utf8))
            } else {
                content = try workspace.read(artifact.path)
            }
            errorMessage = nil
        } catch {
            fileURL = nil
            fileSizeText = ""
            gameManifest = nil
            errorMessage = error.localizedDescription
        }
    }

    private func reloadPreview() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        loadArtifact()
        reloadToken = UUID()
    }

    private func presentGameFullScreen() {
        guard (artifact.isWebPage || artifact.isSwiftGameArtifact), !isOpeningExternalFullScreen, !isRestoringPortrait else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        viewportMode = .fit
        if let openLandscapeFullScreen {
            isOpeningExternalFullScreen = true
            isFullScreenPresented = false
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                openLandscapeFullScreen(artifact)
            }
            return
        }
        isFullScreenPresented = true
        ArtifactOrientationController.request(.landscapeRight)
        reloadToken = UUID()
    }

    private func exitGameFullScreen() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isRestoringPortrait = true
        isFullScreenPresented = false
        ArtifactOrientationController.request(.portrait)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if !UIDevice.current.orientation.isLandscape {
                isRestoringPortrait = false
            }
        }
    }

    private func shareArtifact() {
        let url: URL
        do {
            url = try workspace.resolve(artifact.path)
        } catch {
            shareError = "Could not find \(artifact.path): \(error.localizedDescription)"
            return
        }
        let viewController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            viewController.popoverPresentationController?.sourceView = rootViewController.view
            rootViewController.present(viewController, animated: true)
        } else {
            shareError = "No active window is available for sharing right now."
        }
    }

    private static func byteText(for url: URL) -> String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct ArtifactLandscapeGameModalPresenter: UIViewControllerRepresentable {
    let artifact: WorkspaceArtifact?
    let workspace: SandboxWorkspace
    let close: () -> Void

    final class PresenterViewController: UIViewController {
        var currentArtifactID: String?
        var gameController: UIViewController?
        var isDismissingGameController = false

        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
        override var shouldAutorotate: Bool { true }
    }

    final class LandscapeGameHostingController<Content: View>: UIHostingController<Content> {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
        override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
        override var shouldAutorotate: Bool { true }
    }

    func makeUIViewController(context: Context) -> PresenterViewController {
        PresenterViewController()
    }

    func updateUIViewController(_ presenter: PresenterViewController, context: Context) {
        guard let artifact else {
            dismissPresentedGame(from: presenter, restorePortrait: true, notifyRoot: false)
            return
        }

        guard !presenter.isDismissingGameController else { return }
        guard presenter.currentArtifactID != artifact.id || presenter.gameController == nil else { return }
        presenter.currentArtifactID = artifact.id

        DispatchQueue.main.async {
            if let previous = presenter.gameController {
                previous.dismiss(animated: false)
                presenter.gameController = nil
            }

            let gameView = ArtifactGameFullScreenCover(
                artifact: artifact,
                workspace: workspace,
                close: { [weak presenter] in
                    guard let presenter else {
                        close()
                        ArtifactOrientationController.request(.portrait)
                        return
                    }
                    dismissPresentedGame(from: presenter, restorePortrait: true, notifyRoot: true)
                }
            )
            let controller = LandscapeGameHostingController(rootView: gameView)
            controller.modalPresentationStyle = .fullScreen
            controller.modalTransitionStyle = .crossDissolve
            controller.isModalInPresentation = true
            controller.view.backgroundColor = .black
            presenter.gameController = controller
            presenter.setNeedsUpdateOfSupportedInterfaceOrientations()
            presenter.present(controller, animated: false)
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            ArtifactOrientationController.request(.landscapeRight)
         }
     }

    private func dismissPresentedGame(
        from presenter: PresenterViewController,
        restorePortrait: Bool,
        notifyRoot: Bool
    ) {
        guard !presenter.isDismissingGameController else { return }
        presenter.isDismissingGameController = true
        presenter.currentArtifactID = nil

        let finish: () -> Void = {
            presenter.gameController = nil
            presenter.isDismissingGameController = false
            if notifyRoot {
                close()
            }
            if restorePortrait {
                ArtifactOrientationController.request(.portrait)
            }
        }

        guard let gameController = presenter.gameController else {
            finish()
            return
        }

        // Tear the hosted WKWebView down before rotating back. Otherwise a
        // requestAnimationFrame-heavy game can keep XCTest waiting for app idle after
        // the X button is tapped, even though the visual app should have returned.
        gameController.view.isHidden = true
        gameController.dismiss(animated: false, completion: finish)
    }
}

struct ArtifactGameFullScreenCover: View {
    @Environment(\.dismiss) private var dismissFullScreen

    let artifact: WorkspaceArtifact
    let workspace: SandboxWorkspace
    let close: () -> Void

    @State private var fileURL: URL?
    @State private var errorMessage: String?
    @State private var gameManifest: SwiftGameManifest?
    @State private var reloadToken = UUID()
    @State private var hasReachedLandscapeSize = false
    @State private var lastReloadSize: CGSize = .zero
    @State private var isDismissing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black
                    .ignoresSafeArea()

                gameContent(size: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .ignoresSafeArea()

                Button {
                    dismissAndRestorePortrait()
                } label: {
                    ZStack {
                        Color.clear
                        Circle()
                            .fill(Color.black.opacity(0.24))
                            .frame(width: 30, height: 30)
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                            .frame(width: 30, height: 30)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Exit Full Screen")
                .accessibilityIdentifier("artifactExitFullScreenButton")
                .padding(.top, max(8, proxy.safeAreaInsets.top + 6))
                .padding(.leading, max(8, proxy.safeAreaInsets.leading + 8))
                .zIndex(5)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(ArtifactSizeReporter(label: "root-fullscreen", size: proxy.size))
            .onAppear {
                loadArtifact()
                handleSize(proxy.size)
            }
            .onChange(of: proxy.size.width) { _, _ in
                handleSize(proxy.size)
            }
            .onChange(of: proxy.size.height) { _, _ in
                handleSize(proxy.size)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("artifactGameFullScreen")
    }

    private func dismissAndRestorePortrait() {
        guard !isDismissing else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isDismissing = true
        reloadToken = UUID()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            close()
        }
    }

    @ViewBuilder
    private func gameContent(size: CGSize) -> some View {
        if isDismissing {
            Color.black
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ArtifactErrorCard(message: errorMessage, isFullScreen: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else if artifact.isSwiftGameArtifact, let gameManifest {
            SwiftGameArtifactPlayer(manifest: gameManifest, isFullScreen: true)
                .frame(width: max(1, size.width), height: max(1, size.height))
                .background(Color.black)
        } else if artifact.isWebPage, let fileURL {
            WebArtifactView(
                fileURL: fileURL,
                readAccessURL: workspace.rootURL,
                reloadToken: reloadToken,
                viewportSize: size,
                fullBleedGameMode: true
            )
            .id(reloadToken)
            .frame(width: max(1, size.width), height: max(1, size.height))
            .background(Color.black)
        } else if artifact.isSwiftGameArtifact {
            ArtifactErrorCard(message: "NovaForge could not decode this Swift game manifest.", isFullScreen: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else {
            ProgressView("Loading artifact…")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }

    private func loadArtifact() {
        do {
            let resolved = try workspace.resolve(artifact.path)
            fileURL = resolved
            if artifact.isSwiftGameArtifact {
                let content = try workspace.read(artifact.path)
                gameManifest = try JSONDecoder().decode(SwiftGameManifest.self, from: Data(content.utf8))
            } else {
                gameManifest = nil
            }
            errorMessage = nil
        } catch {
            fileURL = nil
            gameManifest = nil
            errorMessage = error.localizedDescription
        }
    }

    private func handleSize(_ size: CGSize) {
        #if DEBUG
        print("NF_ARTIFACT_ROOT_FULLSCREEN_SIZE view=\(Int(size.width))x\(Int(size.height))")
        #endif
        guard size.width > 10, size.height > 10 else { return }
        if size.width > size.height * 1.05 {
            // Record that we have settled into a landscape frame so the close button
            // insets and proof state are correct, but do NOT bump reloadToken here.
            // The onAppear reload + the WebArtifactView's autoresize + JS viewport
            // dispatch already reflow the game to the landscape bounds; bumping the
            // token reset the whole webview identity mid-rotation and left a black
            // right third (BUG-001).
            hasReachedLandscapeSize = true
            lastReloadSize = size
        }
    }
}

@MainActor
enum ArtifactOrientationController {
    private static var lastRequestMask: UIInterfaceOrientationMask?
    private static var lastRequestAt: Date = .distantPast

    static var currentInterfaceIsLandscape: Bool {
        guard let windowScene = activeWindowScene else { return false }

        let sceneLandscape = windowScene.effectiveGeometry.interfaceOrientation.isLandscape
        let windowSize = windowScene.windows.first(where: { $0.isKeyWindow })?.bounds.size
        let windowLandscape = windowSize.map { $0.width > $0.height } ?? false
        return sceneLandscape || windowLandscape
    }

    static func allowAutoRotation() {
        activeWindowScene?.windows
            .first(where: { $0.isKeyWindow })?
            .rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    static func request(_ mask: UIInterfaceOrientationMask) {
        let geometryMask: UIInterfaceOrientationMask = mask == .portrait ? .portrait : .landscapeRight
        let now = Date()
        if lastRequestMask == geometryMask, now.timeIntervalSince(lastRequestAt) < 1.2 {
            return
        }
        lastRequestMask = geometryMask
        lastRequestAt = now

        guard let windowScene = activeWindowScene else { return }
        let alreadyLandscape = windowScene.effectiveGeometry.interfaceOrientation.isLandscape || (windowScene.windows.first(where: { $0.isKeyWindow })?.bounds.size).map { $0.width > $0.height } == true
        let alreadyPortrait = windowScene.effectiveGeometry.interfaceOrientation == .portrait || (windowScene.windows.first(where: { $0.isKeyWindow })?.bounds.size).map { $0.height > $0.width } == true
        if (geometryMask == .landscapeRight && alreadyLandscape) || (geometryMask == .portrait && alreadyPortrait) {
            windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            return
        }

        let rootViewController = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

        if #available(iOS 16.0, *) {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: geometryMask)) { error in
                #if DEBUG
                print("NovaForge orientation request failed: \(error.localizedDescription)")
                #endif
            }
        } else {
            let targetOrientation: UIInterfaceOrientation = geometryMask == .portrait ? .portrait : .landscapeRight
            UIDevice.current.setValue(targetOrientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }

        rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

private enum ArtifactViewportMode: String, CaseIterable, Identifiable {
    case fit
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: "Fit"
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        }
    }

    var symbol: String {
        switch self {
        case .fit: "rectangle.dashed"
        case .portrait: "iphone"
        case .landscape: "rectangle"
        }
    }

    var accessibilityID: String {
        switch self {
        case .fit: "artifactViewportFit"
        case .portrait: "artifactViewportPortrait"
        case .landscape: "artifactViewportLandscape"
        }
    }

    var aspectRatio: CGFloat? {
        switch self {
        case .fit: nil
        case .portrait: 9.0 / 16.0
        case .landscape: 16.0 / 9.0
        }
    }
}

private struct ArtifactPreviewStudio: View {
    let artifact: WorkspaceArtifact
    let workspace: SandboxWorkspace
    let content: String
    let fileURL: URL?
    let fileSizeText: String
    let errorMessage: String?
    let gameManifest: SwiftGameManifest?
    @Binding var viewportMode: ArtifactViewportMode
    let reloadToken: UUID
    let isFullScreen: Bool
    let iterationPrompt: String?
    let share: () -> Void
    let reload: () -> Void
    let openFullScreen: (() -> Void)?
    let openChat: (() -> Void)?
    let close: () -> Void
    @State private var deviceIsLandscape = false

    private var statusText: String {
        if artifact.isSwiftGameArtifact { return "Native Game" }
        if artifact.isImageArtifact { return artifact.path.lowercased().contains("screenshot") ? "Screenshot" : "Image" }
        if artifact.isPDFArtifact { return "Report" }
        if artifact.isMarkdownArtifact { return "Markdown" }
        if artifact.isLogArtifact { return "Log" }
        return artifact.isWebPage ? "Live HTML" : "Source Preview"
    }

    private var fileKindText: String {
        if artifact.isSwiftGameArtifact { return "SWIFT GAME" }
        let ext = (artifact.path as NSString).pathExtension.uppercased()
        if ext.isEmpty { return artifact.isWebPage ? "HTML" : "FILE" }
        return ext
    }

    private var previewHintTitle: String {
        if artifact.isSwiftGameArtifact { return "Native game ready" }
        if artifact.isWebPage { return "Artifact ready" }
        if artifact.isImageArtifact { return artifact.path.lowercased().contains("screenshot") ? "Screenshot evidence" : "Image artifact" }
        if artifact.isPDFArtifact { return "Report artifact" }
        if artifact.isLogArtifact { return "Log evidence" }
        if artifact.isMarkdownArtifact || artifact.isReportArtifact { return "Readable report" }
        return "Source artifact ready"
    }

    private var previewHintDetail: String {
        let prompt = iterationPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty { return prompt }
        if artifact.isSwiftGameArtifact { return "Play here, rotate sideways, or return to Chat for the next change." }
        if artifact.isWebPage { return "Inspect here, rotate for landscape, or return to Chat for the next change." }
        if artifact.isImageArtifact { return "Inspect the visual evidence, then return to Chat for the next change." }
        if artifact.isPDFArtifact { return "Review the report output without leaving the workspace." }
        if artifact.isLogArtifact { return "Scan the log evidence and copy the path when it matters." }
        if artifact.isMarkdownArtifact || artifact.isReportArtifact { return "Read the generated report and continue from the strongest evidence." }
        return "Read this output, then return to Chat for the next change."
    }

    private var background: some View {
        ZStack {
            if isFullScreen {
                LinearGradient(
                    colors: [Color(red: 0.035, green: 0.045, blue: 0.065), Color(red: 0.08, green: 0.085, blue: 0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            } else {
                AgentBackground()
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let effectiveFullScreen = isFullScreen
            ZStack {
                if effectiveFullScreen {
                    fullScreenBackdrop
                } else {
                    background
                }

                if effectiveFullScreen {
                    fullScreenGameLayer
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    VStack(spacing: 12) {
                        header
                            .padding(.horizontal, 16)
                            .padding(.top, 14)

                        previewHintBar
                            .padding(.horizontal, 16)

                        controlDeck
                            .padding(.horizontal, 16)

                        previewStage
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                    }
                }

                ArtifactAccessibilityMarker(
                    identifier: effectiveFullScreen ? "artifactGameFullScreen" : "artifactPreviewStudio",
                    label: effectiveFullScreen ? "Artifact full screen game" : "Artifact preview studio"
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(ArtifactSizeReporter(label: effectiveFullScreen ? "fullscreen" : "preview", size: proxy.size))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(effectiveFullScreen ? "Artifact full screen game" : "Artifact preview studio")
            .accessibilityIdentifier(effectiveFullScreen ? "artifactGameFullScreen" : "artifactPreviewStudio")
        }
        .ignoresSafeArea(edges: isFullScreen ? .all : [])
    }

    private var fullScreenGameLayer: some View {
        GeometryReader { proxy in
            fullScreenGameSurface(size: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("artifactGameFullScreen")
    }

    private func fullScreenGameSurface(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            fullBleedPreviewContent(size: size)
                .id("full-bleed-\(reloadToken.uuidString)-\(Int(size.width))x\(Int(size.height))")
                .frame(width: size.width, height: size.height)
                .ignoresSafeArea()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                close()
            } label: {
                ZStack {
                    Color.clear
                    Circle()
                        .fill(Color.black.opacity(0.24))
                        .frame(width: 30, height: 30)
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        .frame(width: 30, height: 30)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit Full Screen")
            .accessibilityIdentifier("artifactExitFullScreenButton")
            .zIndex(5)
            .padding(.top, 8)
            .padding(.leading, 8)
        }
        .frame(width: size.width, height: size.height)
    }

    private var fullScreenBackdrop: some View {
        LinearGradient(
            colors: [Color(red: 0.015, green: 0.09, blue: 0.065), Color(red: 0.01, green: 0.02, blue: 0.016)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: artifact.isWebPage || artifact.isSwiftGameArtifact ? artifact.handoffSymbol : artifact.symbol)
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.lilac)
                .frame(width: 42, height: 42)
                .agentControlSurface(radius: 16, tint: artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green.opacity(0.16) : AgentPalette.lilac, selected: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(artifact.title)
                        .font(.system(size: isFullScreen ? 18 : 16, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(isFullScreen ? .white : AgentPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .layoutPriority(1)
                    Text(statusText)
                        .fixedSize()
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.cyan)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .agentControlSurface(radius: 8, tint: (artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.cyan).opacity(0.12), selected: true)
                }

                Text(artifact.path)
                    .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(isFullScreen ? .white.opacity(0.62) : AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            headerButton(symbol: "square.and.arrow.up", label: "Share Artifact", action: share)
                .accessibilityIdentifier("artifactShareButton")

            if let openFullScreen {
                headerButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Full Screen", action: openFullScreen)
                    .accessibilityIdentifier("artifactFullScreenButton")
            }

            headerButton(symbol: isFullScreen ? "xmark.circle.fill" : "xmark", label: isFullScreen ? "Exit Full Screen" : "Close Preview", action: close)
                .accessibilityIdentifier(isFullScreen ? "artifactExitFullScreenButton" : "artifactCloseButton")
        }
    }

    private func headerButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(isFullScreen ? .white : AgentPalette.ink)
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
        }
        .buttonStyle(.plain)
        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
        .contentShape(Rectangle())
        .agentControlSurface(radius: 14, tint: isFullScreen ? Color.white.opacity(0.14) : AgentPalette.primaryAccent.opacity(0.10), selected: true)
        .accessibilityLabel(label)
    }

    private var controlDeck: some View {
        VStack(spacing: 10) {
            ArtifactMetadataStrip(
                fileKindText: fileKindText,
                fileSizeText: fileSizeText,
                isFullScreen: isFullScreen
            )
        }
        .padding(10)
        .agentSurface(radius: 18, tint: isFullScreen ? Color.white.opacity(0.04) : AgentPalette.primaryAccent.opacity(0.05))
    }

    private var previewHintBar: some View {
        HStack(spacing: 9) {
            Image(systemName: artifact.isWebPage || artifact.isSwiftGameArtifact ? "rotate.right.fill" : "doc.text.magnifyingglass")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.cyan)
                .frame(width: 28, height: 28)
                .agentControlSurface(
                    radius: 11,
                    tint: (artifact.isWebPage || artifact.isSwiftGameArtifact ? AgentPalette.green : AgentPalette.cyan).opacity(0.10),
                    selected: true
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(previewHintTitle)
                    .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text(previewHintDetail)
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)

            if artifact.isWebPage || artifact.isSwiftGameArtifact {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(AgentPalette.ink)
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 12, tint: AgentPalette.green.opacity(0.10), selected: true)
                }
                .buttonStyle(.plain)
                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                .contentShape(Rectangle())
                .accessibilityLabel("Reload Artifact")
                .accessibilityIdentifier("artifactReloadButton")
            }

            if let openChat {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        openChat()
                    }
                } label: {
                    Label("Iterate", systemImage: "sparkles")
                        .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .padding(.horizontal, 10)
                        .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 12, tint: AgentPalette.cyan.opacity(0.10), selected: true)
                }
                .buttonStyle(.plain)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .contentShape(Rectangle())
                .accessibilityLabel("Iterate in Chat")
                .accessibilityIdentifier("artifactIterateInChatButton")
            }
        }
        .padding(10)
        .agentSurface(radius: 18, tint: AgentPalette.primaryAccent.opacity(0.04))
    }

    private var previewStage: some View {
        GeometryReader { proxy in
            let availableSize = proxy.size
            let footerGap: CGFloat = isFullScreen ? 0 : 8
            let footerHeight: CGFloat = isFullScreen ? 0 : 34
            VStack(spacing: footerGap) {
                ZStack(alignment: isFullScreen ? .top : .center) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(isFullScreen ? Color.black.opacity(0.44) : AgentPalette.surfaceAlt.opacity(0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(isFullScreen ? Color.white.opacity(0.14) : AgentPalette.glassStroke.opacity(0.46), lineWidth: 1)
                        )

                    ArtifactViewportFrame(
                        mode: viewportMode,
                        availableSize: CGSize(
                            width: availableSize.width,
                            height: max(1, availableSize.height - footerHeight - footerGap)
                        ),
                        isFullScreen: isFullScreen
                    ) {
                        previewContent
                    }
                    .padding(10)
                    .padding(.top, isFullScreen ? 10 : 0)
                }
                .frame(
                    width: availableSize.width,
                    height: max(1, availableSize.height - footerHeight - footerGap)
                )

                if !isFullScreen {
                    footer
                        .frame(height: footerHeight)
                }
            }
            .frame(width: availableSize.width, height: availableSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var previewContent: some View {
        if let errorMessage {
            ArtifactErrorCard(message: errorMessage, isFullScreen: isFullScreen)
        } else if artifact.isSwiftGameArtifact, let gameManifest {
            SwiftGameArtifactPlayer(manifest: gameManifest, isFullScreen: false)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if artifact.isWebPage, let fileURL {
            GeometryReader { proxy in
                WebArtifactView(
                    fileURL: fileURL,
                    readAccessURL: workspace.rootURL,
                    reloadToken: reloadToken,
                    viewportSize: proxy.size
                )
                .frame(width: max(1, proxy.size.width), height: max(1, proxy.size.height))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else if artifact.isImageArtifact, let fileURL {
            ArtifactImagePreview(fileURL: fileURL, isFullScreen: isFullScreen)
        } else if artifact.isPDFArtifact, let fileURL {
            GeometryReader { proxy in
                WebArtifactView(
                    fileURL: fileURL,
                    readAccessURL: workspace.rootURL,
                    reloadToken: reloadToken,
                    viewportSize: proxy.size
                )
                .frame(width: max(1, proxy.size.width), height: max(1, proxy.size.height))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else if !artifact.isWebPage {
            ArtifactTextPreview(artifact: artifact, content: content, isFullScreen: isFullScreen)
        } else {
            ArtifactLoadingCard(isFullScreen: isFullScreen)
        }
    }

    @ViewBuilder
    private func fullBleedPreviewContent(size: CGSize) -> some View {
        if let errorMessage {
            ArtifactErrorCard(message: errorMessage, isFullScreen: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else if artifact.isSwiftGameArtifact, let gameManifest {
            SwiftGameArtifactPlayer(manifest: gameManifest, isFullScreen: true)
                .frame(width: max(1, size.width), height: max(1, size.height))
                .background(Color.black)
        } else if artifact.isWebPage, let fileURL {
            WebArtifactView(
                fileURL: fileURL,
                readAccessURL: workspace.rootURL,
                reloadToken: reloadToken,
                viewportSize: size,
                fullBleedGameMode: true
            )
            .frame(width: max(1, size.width), height: max(1, size.height))
            .background(fullScreenBackdrop)
        } else if artifact.isImageArtifact, let fileURL {
            ArtifactImagePreview(fileURL: fileURL, isFullScreen: true)
                .frame(width: max(1, size.width), height: max(1, size.height))
                .background(Color.black)
        } else if artifact.isPDFArtifact, let fileURL {
            WebArtifactView(
                fileURL: fileURL,
                readAccessURL: workspace.rootURL,
                reloadToken: reloadToken,
                viewportSize: size
            )
            .frame(width: max(1, size.width), height: max(1, size.height))
            .background(Color.black)
        } else if !artifact.isWebPage {
            ArtifactTextPreview(artifact: artifact, content: content, isFullScreen: true)
                .background(Color.black)
        } else {
            ProgressView("Loading artifact…")
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: viewportMode == .fit ? "rectangle.dashed" : viewportMode.symbol)
                .font(.system(size: 10, weight: .black))
            Text(footerText)
                .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isFullScreen ? .white.opacity(0.82) : AgentPalette.ink)
        .padding(.horizontal, 10)
        .frame(minHeight: 30)
        .background(
            isFullScreen ? Color.black.opacity(0.36) : AgentPalette.surface.opacity(0.92),
            in: Capsule(style: .continuous)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder((isFullScreen ? Color.white : AgentPalette.glassStroke).opacity(0.46), lineWidth: 1)
        )
    }

    private var footerText: String {
        if artifact.isSwiftGameArtifact { return "Native game ready · rotate for handheld landscape mode." }
        return artifact.isWebPage ? "Preview ready · rotate the phone for fullscreen landscape." : "Source preview ready."
    }
}

private struct ArtifactAccessibilityMarker: UIViewRepresentable {
    let identifier: String
    let label: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 44, height: 44)))
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = label
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = label
    }
}

private enum SwiftGamePlayState: Equatable {
    case playing
    case won
    case lost
}

private struct SwiftGameArtifactPlayer: View {
    let manifest: SwiftGameManifest
    let isFullScreen: Bool

    @State private var playerPosition: CGPoint = .zero
    @State private var collectedIDs: Set<String> = []
    @State private var score = 0
    @State private var lives = 3
    @State private var isPaused = false
    @State private var playState: SwiftGamePlayState = .playing
    @State private var tickTime = Date().timeIntervalSinceReferenceDate
    @State private var hitCooldownUntil: TimeInterval = 0
    @State private var lastDirection = CGVector(dx: 1, dy: 0)

    private var worldSize: CGSize {
        CGSize(
            width: CGFloat(max(1, manifest.world.size.width)),
            height: CGFloat(max(1, manifest.world.size.height))
        )
    }

    private var boardAspectRatio: CGFloat {
        CGFloat(max(0.2, manifest.resolvedAspectRatio))
    }

    private var remainingCollectibles: [SwiftGameEntity] {
        manifest.collectibles.filter { !collectedIDs.contains($0.id) }
    }

    private var progressText: String {
        "\(collectedIDs.count)/\(manifest.collectibles.count)"
    }

    var body: some View {
        GeometryReader { proxy in
            let landscape = isFullScreen && proxy.size.width > proxy.size.height
            ZStack {
                gameBackdrop

                if landscape {
                    landscapeLayout(proxy: proxy)
                } else {
                    portraitLayout(proxy: proxy)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onAppear(perform: resetGame)
            .onChange(of: manifest.id) { _, _ in
                resetGame()
            }
            .task(id: manifest.id) {
                await runGameClock()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(isFullScreen ? "swiftGameLandscapePlayer" : "swiftGamePreviewPlayer")
        }
    }

    private var gameBackdrop: some View {
        ZStack {
            Color(hex: manifest.world.backgroundColor)
            RadialGradient(
                colors: [Color(hex: manifest.player.color).opacity(0.28), Color.clear],
                center: .topLeading,
                startRadius: 24,
                endRadius: 520
            )
            RadialGradient(
                colors: [AgentPalette.cyan.opacity(0.18), Color.clear],
                center: .bottomTrailing,
                startRadius: 18,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    private func landscapeLayout(proxy: GeometryProxy) -> some View {
        let sideWidth = min(max(proxy.size.width * 0.18, 128), 190)
        return HStack(spacing: 0) {
            movementZone
                .frame(width: sideWidth)
                .padding(.leading, max(10, proxy.safeAreaInsets.leading + 8))

            gameBoard
                .aspectRatio(boardAspectRatio, contentMode: .fit)
                .frame(maxWidth: proxy.size.width - sideWidth * 2 - proxy.safeAreaInsets.leading - proxy.safeAreaInsets.trailing - 20)
                .frame(maxHeight: proxy.size.height - max(18, proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom))
                .padding(.vertical, max(8, proxy.safeAreaInsets.top * 0.35))

            actionZone
                .frame(width: sideWidth)
                .padding(.trailing, max(10, proxy.safeAreaInsets.trailing + 8))
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
    }

    private func portraitLayout(proxy: GeometryProxy) -> some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: WorkspaceArtifactType.swiftGame.symbolName)
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(AgentPalette.green)
                        .frame(width: 34, height: 34)
                        .background(AgentPalette.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(manifest.title)
                            .font(.system(size: 16, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(manifest.scenes.first?.objective ?? manifest.description)
                            .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(.white.opacity(0.68))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)
                    compactHUD
                }
            }
            .padding(12)
            .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7)
            )

            gameBoard
                .aspectRatio(boardAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: proxy.size.height * 0.62)

            HStack(spacing: 10) {
                movementZone
                actionZone
            }
            .frame(minHeight: 120, maxHeight: 152)
        }
        .padding(12)
        .frame(width: proxy.size.width, height: proxy.size.height)
    }

    private var gameBoard: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    drawGame(in: &context, size: size)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            movePlayer(to: worldPoint(from: value.location, canvasSize: proxy.size))
                        }
                )

                VStack {
                    HStack {
                        compactHUD
                        Spacer(minLength: 0)
                        Button {
                            isPaused.toggle()
                        } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 11, weight: .black))
                                .frame(width: 34, height: 34)
                                .background(Color.black.opacity(0.30), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .accessibilityLabel(isPaused ? "Resume game" : "Pause game")
                    }
                    .padding(10)
                    Spacer(minLength: 0)
                }

                if playState != .playing {
                    outcomeOverlay
                } else if isPaused {
                    pauseOverlay
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 20 : 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: isFullScreen ? 20 : 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isFullScreen ? 0.30 : 0.18), radius: isFullScreen ? 18 : 10, x: 0, y: 8)
            .accessibilityIdentifier("swiftGameCanvas")
        }
    }

    private var compactHUD: some View {
        HStack(spacing: 8) {
            hudPill(symbol: "star.fill", value: "\(score)")
            hudPill(symbol: "heart.fill", value: "\(lives)")
            hudPill(symbol: "scope", value: progressText)
        }
    }

    private func hudPill(symbol: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
            Text(value)
                .font(.system(size: 10, weight: .black, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.black.opacity(0.34), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    private var movementZone: some View {
        VStack(spacing: 10) {
            Text("Move")
                .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(.white.opacity(0.64))
                .textCase(.uppercase)
            VStack(spacing: 8) {
                controlButton(symbol: "chevron.up") { movePlayerBy(dx: 0, dy: -1) }
                HStack(spacing: 8) {
                    controlButton(symbol: "chevron.left") { movePlayerBy(dx: -1, dy: 0) }
                    controlButton(symbol: "circle.fill", size: 44) {}
                        .opacity(0.55)
                    controlButton(symbol: "chevron.right") { movePlayerBy(dx: 1, dy: 0) }
                }
                controlButton(symbol: "chevron.down") { movePlayerBy(dx: 0, dy: 1) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.black.opacity(isFullScreen ? 0.12 : 0.18), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("swiftGameMovementZone")
    }

    private var actionZone: some View {
        VStack(spacing: 10) {
            Text("Action")
                .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(.white.opacity(0.64))
                .textCase(.uppercase)

            Button {
                dash()
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 19, weight: .black))
                    .frame(width: 68, height: 68)
                    .background(AgentPalette.green.opacity(0.22), in: Circle())
                    .overlay(Circle().strokeBorder(AgentPalette.green.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityLabel("Dash")
            .accessibilityIdentifier("swiftGameDashButton")

            Button {
                isPaused.toggle()
            } label: {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityIdentifier("swiftGamePauseButton")

            Button {
                resetGame()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .frame(maxWidth: .infinity, minHeight: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityIdentifier("swiftGameRestartButton")

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.black.opacity(isFullScreen ? 0.12 : 0.18), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("swiftGameActionZone")
    }

    private func controlButton(symbol: String, size: CGFloat = 50, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .black))
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.09), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .contentShape(Circle())
    }

    private var pauseOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 34, weight: .black))
            Text("Paused")
                .font(.system(size: 20, weight: .black, design: AgentPalette.interfaceFontDesign))
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(Color.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var outcomeOverlay: some View {
        let won = playState == .won
        return VStack(spacing: 12) {
            Image(systemName: won ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(won ? AgentPalette.green : AgentPalette.rose)
            Text(won ? manifest.winCondition.message : manifest.lossCondition.message)
                .font(.system(size: 19, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Score \(score)")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
            Button {
                resetGame()
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background((won ? AgentPalette.green : AgentPalette.rose).opacity(0.20), in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .accessibilityIdentifier("swiftGameOutcomeRestartButton")
        }
        .padding(24)
        .frame(maxWidth: 320)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
        )
    }

    private func drawGame(in context: inout GraphicsContext, size: CGSize) {
        let frame = boardFrame(in: size)
        var background = Path()
        background.addRect(CGRect(origin: .zero, size: size))
        context.fill(background, with: .color(Color(hex: manifest.world.backgroundColor)))
        context.fill(Path(roundedRect: frame, cornerRadius: 24), with: .color(Color.white.opacity(0.035)))

        drawGrid(in: &context, frame: frame)
        drawEntities(manifest.obstacles, in: &context, frame: frame, time: tickTime)
        drawEntities(remainingCollectibles, in: &context, frame: frame, time: tickTime)
        drawEntities(manifest.enemies, in: &context, frame: frame, time: tickTime)
        drawPlayer(in: &context, frame: frame)
    }

    private func drawGrid(in context: inout GraphicsContext, frame: CGRect) {
        let columns = 12
        let rows = 7
        var grid = Path()
        for index in 1..<columns {
            let x = frame.minX + frame.width * CGFloat(index) / CGFloat(columns)
            grid.move(to: CGPoint(x: x, y: frame.minY))
            grid.addLine(to: CGPoint(x: x, y: frame.maxY))
        }
        for index in 1..<rows {
            let y = frame.minY + frame.height * CGFloat(index) / CGFloat(rows)
            grid.move(to: CGPoint(x: frame.minX, y: y))
            grid.addLine(to: CGPoint(x: frame.maxX, y: y))
        }
        context.stroke(grid, with: .color(Color.white.opacity(0.045)), lineWidth: 1)
    }

    private func drawEntities(_ entities: [SwiftGameEntity], in context: inout GraphicsContext, frame: CGRect, time: TimeInterval) {
        for entity in entities {
            let rect = entityRect(entity, frame: frame, time: time)
            let path = shapePath(entity.shape, rect: rect)
            context.fill(path, with: .color(Color(hex: entity.color).opacity(entity.kind == .obstacle ? 0.62 : 0.92)))
            if let stroke = entity.strokeColor {
                context.stroke(path, with: .color(Color(hex: stroke).opacity(0.55)), lineWidth: entity.kind == .obstacle ? 1.2 : 2)
            }
        }
    }

    private func drawPlayer(in context: inout GraphicsContext, frame: CGRect) {
        let rect = worldRect(center: playerPosition, size: entitySize(manifest.player), frame: frame)
        let path = shapePath(manifest.player.shape, rect: rect)
        let invulnerable = tickTime < hitCooldownUntil
        context.fill(path, with: .color(Color(hex: manifest.player.color).opacity(invulnerable ? 0.50 : 0.96)))
        context.stroke(path, with: .color(Color(hex: manifest.player.strokeColor ?? "#FFFFFF").opacity(0.78)), lineWidth: 2.2)
    }

    private func shapePath(_ shape: SwiftGameShape, rect: CGRect) -> Path {
        switch shape {
        case .circle:
            return Path(ellipseIn: rect)
        case .roundedRect:
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.28)
        case .capsule:
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.5)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }

    private func resetGame() {
        let start = manifest.player.position
        playerPosition = CGPoint(x: CGFloat(start.x), y: CGFloat(start.y))
        collectedIDs = []
        score = 0
        lives = max(1, manifest.scoring.startingLives)
        isPaused = false
        playState = .playing
        hitCooldownUntil = 0
        lastDirection = CGVector(dx: 1, dy: 0)
        tickTime = Date().timeIntervalSinceReferenceDate
    }

    private func runGameClock() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            tickTime = Date().timeIntervalSinceReferenceDate
            guard !isPaused, playState == .playing else { continue }
            checkEnemyCollisions()
            checkCollectibles()
        }
    }

    private func movePlayerBy(dx: CGFloat, dy: CGFloat) {
        guard playState == .playing, !isPaused else { return }
        let speed = CGFloat(max(12, manifest.player.speed))
        lastDirection = CGVector(dx: dx, dy: dy)
        movePlayer(to: CGPoint(x: playerPosition.x + dx * speed, y: playerPosition.y + dy * speed))
    }

    private func dash() {
        guard playState == .playing, !isPaused else { return }
        let dx = lastDirection.dx == 0 && lastDirection.dy == 0 ? 1 : lastDirection.dx
        let dy = lastDirection.dx == 0 && lastDirection.dy == 0 ? 0 : lastDirection.dy
        let length = max(0.1, sqrt(dx * dx + dy * dy))
        let distance = CGFloat(max(72, manifest.player.speed * 2.4))
        movePlayer(to: CGPoint(
            x: playerPosition.x + dx / length * distance,
            y: playerPosition.y + dy / length * distance
        ))
    }

    private func movePlayer(to rawPoint: CGPoint) {
        guard playState == .playing, !isPaused else { return }
        let point = clamped(rawPoint)
        let playerRect = CGRect(
            x: point.x - entitySize(manifest.player).width / 2,
            y: point.y - entitySize(manifest.player).height / 2,
            width: entitySize(manifest.player).width,
            height: entitySize(manifest.player).height
        )
        let hitsObstacle = manifest.obstacles.contains { obstacle in
            playerRect.intersects(worldEntityRect(obstacle, time: tickTime))
        }
        guard !hitsObstacle else { return }
        if point != playerPosition {
            let delta = CGVector(dx: point.x - playerPosition.x, dy: point.y - playerPosition.y)
            if abs(delta.dx) + abs(delta.dy) > 0.1 {
                lastDirection = delta
            }
        }
        playerPosition = point
        checkCollectibles()
    }

    private func checkCollectibles() {
        for collectible in manifest.collectibles where !collectedIDs.contains(collectible.id) {
            if intersectsPlayer(collectible, time: tickTime) {
                collectedIDs.insert(collectible.id)
                score += max(1, collectible.points == 0 ? manifest.scoring.scorePerCollectible : collectible.points)
            }
        }
        if !manifest.collectibles.isEmpty, collectedIDs.count == manifest.collectibles.count {
            playState = .won
            isPaused = false
        } else if score >= manifest.scoring.targetScore, manifest.scoring.targetScore > 0 {
            playState = .won
            isPaused = false
        }
    }

    private func checkEnemyCollisions() {
        guard tickTime >= hitCooldownUntil else { return }
        guard manifest.enemies.contains(where: { intersectsPlayer($0, time: tickTime) }) else { return }
        lives -= 1
        hitCooldownUntil = tickTime + 1.0
        if lives <= 0 {
            playState = .lost
            isPaused = false
        } else {
            let start = manifest.player.position
            playerPosition = CGPoint(x: CGFloat(start.x), y: CGFloat(start.y))
        }
    }

    private func intersectsPlayer(_ entity: SwiftGameEntity, time: TimeInterval) -> Bool {
        worldEntityRect(entity, time: time).intersects(
            CGRect(
                x: playerPosition.x - entitySize(manifest.player).width / 2,
                y: playerPosition.y - entitySize(manifest.player).height / 2,
                width: entitySize(manifest.player).width,
                height: entitySize(manifest.player).height
            )
        )
    }

    private func boardFrame(in size: CGSize) -> CGRect {
        let aspect = boardAspectRatio
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func worldPoint(from location: CGPoint, canvasSize: CGSize) -> CGPoint {
        let frame = boardFrame(in: canvasSize)
        let x = (location.x - frame.minX) / max(1, frame.width) * worldSize.width
        let y = (location.y - frame.minY) / max(1, frame.height) * worldSize.height
        return clamped(CGPoint(x: x, y: y))
    }

    private func worldRect(center: CGPoint, size: CGSize, frame: CGRect) -> CGRect {
        let x = frame.minX + (center.x - size.width / 2) / worldSize.width * frame.width
        let y = frame.minY + (center.y - size.height / 2) / worldSize.height * frame.height
        return CGRect(
            x: x,
            y: y,
            width: size.width / worldSize.width * frame.width,
            height: size.height / worldSize.height * frame.height
        )
    }

    private func entityRect(_ entity: SwiftGameEntity, frame: CGRect, time: TimeInterval) -> CGRect {
        worldRect(center: animatedPosition(for: entity, time: time), size: entitySize(entity), frame: frame)
    }

    private func worldEntityRect(_ entity: SwiftGameEntity, time: TimeInterval) -> CGRect {
        let size = entitySize(entity)
        let center = animatedPosition(for: entity, time: time)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    private func animatedPosition(for entity: SwiftGameEntity, time: TimeInterval) -> CGPoint {
        guard let movement = entity.movement else {
            return CGPoint(x: CGFloat(entity.position.x), y: CGFloat(entity.position.y))
        }
        let offset = CGFloat(sin(time * movement.speed + movement.phase) * movement.amplitude)
        switch movement.axis {
        case .horizontal:
            return clamped(CGPoint(x: CGFloat(entity.position.x) + offset, y: CGFloat(entity.position.y)), inset: entitySize(entity))
        case .vertical:
            return clamped(CGPoint(x: CGFloat(entity.position.x), y: CGFloat(entity.position.y) + offset), inset: entitySize(entity))
        }
    }

    private func entitySize(_ entity: SwiftGameEntity) -> CGSize {
        CGSize(width: CGFloat(max(1, entity.size.width)), height: CGFloat(max(1, entity.size.height)))
    }

    private func clamped(_ point: CGPoint, inset: CGSize? = nil) -> CGPoint {
        let size = inset ?? entitySize(manifest.player)
        let halfW = size.width / 2
        let halfH = size.height / 2
        return CGPoint(
            x: min(worldSize.width - halfW, max(halfW, point.x)),
            y: min(worldSize.height - halfH, max(halfH, point.y))
        )
    }
}

private extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        switch sanitized.count {
        case 8:
            red = Double((value & 0xFF00_0000) >> 24) / 255
            green = Double((value & 0x00FF_0000) >> 16) / 255
            blue = Double((value & 0x0000_FF00) >> 8) / 255
            alpha = Double(value & 0x0000_00FF) / 255
        case 6:
            red = Double((value & 0xFF0000) >> 16) / 255
            green = Double((value & 0x00FF00) >> 8) / 255
            blue = Double(value & 0x0000FF) / 255
            alpha = 1
        default:
            red = 0.1
            green = 0.14
            blue = 0.18
            alpha = 1
        }
        self.init(red: red, green: green, blue: blue, opacity: alpha)
    }
}

private struct ArtifactModeSelector: View {
    @Binding var selectedMode: ArtifactViewportMode
    let showReload: Bool
    let isFullScreen: Bool
    let reload: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ArtifactViewportMode.allCases) { mode in
                modeButton(mode)
            }

            if showReload {
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(isFullScreen ? .white : AgentPalette.ink)
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 12, tint: AgentPalette.green.opacity(0.12), selected: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload Artifact")
                .accessibilityIdentifier("artifactReloadButton")
            }
        }
    }

    private func modeButton(_ mode: ArtifactViewportMode) -> some View {
        let selected = selectedMode == mode
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            selectedMode = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 11, weight: .black))
                Text(mode.title)
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
            }
            .foregroundStyle(selected ? AgentPalette.ink : (isFullScreen ? .white.opacity(0.72) : AgentPalette.secondaryText))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .agentControlSurface(
                radius: 12,
                tint: selected ? AgentPalette.primaryAccent.opacity(0.16) : (isFullScreen ? Color.white.opacity(0.08) : AgentPalette.surfaceAlt.opacity(0.12)),
                selected: selected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityIdentifier(mode.accessibilityID)
        .accessibilityAddTraits(.isButton)
    }
}

private struct ArtifactMetadataStrip: View {
    let fileKindText: String
    let fileSizeText: String
    let isFullScreen: Bool

    var body: some View {
        HStack(spacing: 8) {
            ArtifactInfoPill(title: fileKindText, symbol: "doc.fill", tint: AgentPalette.cyan, isFullScreen: isFullScreen)
            if !fileSizeText.isEmpty {
                ArtifactInfoPill(title: fileSizeText, symbol: "externaldrive.fill", tint: AgentPalette.lilac, isFullScreen: isFullScreen)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ArtifactImagePreview: View {
    let fileURL: URL
    let isFullScreen: Bool

    private var image: UIImage? {
        UIImage(contentsOfFile: fileURL.path)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                (isFullScreen ? Color.black : AgentPalette.surface.opacity(0.58))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .padding(12)
                        .accessibilityIdentifier("artifactImagePreview")
                } else {
                    ArtifactErrorCard(
                        message: "NovaForge could not decode this image file.",
                        isFullScreen: isFullScreen
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ArtifactTextPreview: View {
    let artifact: WorkspaceArtifact
    let content: String
    let isFullScreen: Bool

    private var kindTitle: String {
        if artifact.isMarkdownArtifact { return "Markdown report" }
        if artifact.isLogArtifact { return "Log output" }
        if artifact.isReportArtifact { return "Verification report" }
        return artifact.fileExtension.isEmpty ? "Text output" : "\(artifact.fileExtension.uppercased()) output"
    }

    private var lineCountText: String {
        let count = content.isEmpty ? 0 : content.components(separatedBy: .newlines).count
        return "\(count) line\(count == 1 ? "" : "s")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: artifact.symbol)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(artifact.isLogArtifact ? AgentPalette.indigo : AgentPalette.cyan)
                        .frame(width: 30, height: 30)
                        .agentControlSurface(
                            radius: 10,
                            tint: (artifact.isLogArtifact ? AgentPalette.indigo : AgentPalette.cyan).opacity(0.12),
                            selected: true
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(kindTitle)
                            .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(isFullScreen ? .white : AgentPalette.ink)
                        Text(lineCountText)
                            .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(isFullScreen ? .white.opacity(0.58) : AgentPalette.tertiaryText)
                    }

                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(
                    isFullScreen ? Color.white.opacity(0.06) : AgentPalette.surfaceAlt.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

                Text(content.isEmpty ? "This artifact is empty." : content)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(isFullScreen ? .white.opacity(0.9) : AgentPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
        }
        .background(isFullScreen ? Color.black.opacity(0.24) : AgentPalette.surface.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("artifactTextPreview")
    }
}

private struct ArtifactInfoPill: View {
    let title: String
    let symbol: String
    let tint: Color
    let isFullScreen: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
            .lineLimit(1)
            .foregroundStyle(isFullScreen ? .white.opacity(0.82) : AgentPalette.ink)
            .padding(.horizontal, 8)
            .frame(height: 25)
            .agentControlSurface(radius: 9, tint: tint.opacity(0.10), selected: true)
    }
}

private struct ArtifactViewportFrame<Content: View>: View {
    let mode: ArtifactViewportMode
    let availableSize: CGSize
    let isFullScreen: Bool
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            if mode.aspectRatio != nil {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(isFullScreen ? Color.white.opacity(0.08) : AgentPalette.surfaceAlt.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(isFullScreen ? Color.white.opacity(0.18) : AgentPalette.glassStroke.opacity(0.42), lineWidth: 1)
                    )

                content
                    .padding(6)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                content
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
    }

    private var frameSize: CGSize {
        guard let aspectRatio = mode.aspectRatio else {
            return CGSize(width: max(1, availableSize.width - 20), height: max(1, availableSize.height - 20))
        }

        let maxWidth = max(1, availableSize.width - 28)
        let maxHeight = max(1, availableSize.height - 28)
        var width = maxWidth
        var height = width / aspectRatio
        if height > maxHeight {
            height = maxHeight
            width = height * aspectRatio
        }
        return CGSize(width: width, height: height)
    }
}

private struct ArtifactLoadingCard: View {
    let isFullScreen: Bool

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(isFullScreen ? .white : AgentPalette.primaryAccent)
                .scaleEffect(1.15)

            VStack(spacing: 3) {
                Text("Loading artifact")
                    .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(isFullScreen ? .white : AgentPalette.ink)
                Text("Resolving the workspace file and preparing the preview surface.")
                    .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(isFullScreen ? .white.opacity(0.62) : AgentPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(22)
        .frame(maxWidth: 320)
        .agentSurface(radius: 22, tint: AgentPalette.primaryAccent.opacity(0.08))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading artifact. Resolving the workspace file and preparing the preview surface.")
    }
}

private struct ArtifactErrorCard: View {
    let message: String
    let isFullScreen: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .black))
                .foregroundStyle(AgentPalette.rose)
            Text("Preview unavailable")
                .font(.system(size: 17, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(isFullScreen ? .white : AgentPalette.ink)
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .multilineTextAlignment(.center)
                .foregroundStyle(isFullScreen ? .white.opacity(0.62) : AgentPalette.secondaryText)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .agentSurface(radius: 22, tint: AgentPalette.rose.opacity(0.08))
    }
}

private struct ArtifactSizeReporter: View {
    let label: String
    let size: CGSize

    var body: some View {
        Color.clear
            .onAppear { report() }
            .onChange(of: size.width) { _, _ in report() }
            .onChange(of: size.height) { _, _ in report() }
            .onChange(of: label) { _, _ in report() }
    }

    private func report() {
        #if DEBUG
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            print("NF_ARTIFACT_SWIFTUI_SIZE label=\(label) viewSize=\(Int(size.width))x\(Int(size.height)) scene=0x0 window=0x0 orientation=-1")
            return
        }
        let sceneBounds = windowScene.effectiveGeometry.coordinateSpace.bounds
        let windowBounds = windowScene.windows.first(where: { $0.isKeyWindow })?.bounds
        let orientation = windowScene.effectiveGeometry.interfaceOrientation
        print("NF_ARTIFACT_SWIFTUI_SIZE label=\(label) viewSize=\(Int(size.width))x\(Int(size.height)) scene=\(Int(sceneBounds.width))x\(Int(sceneBounds.height)) window=\(Int(windowBounds?.width ?? 0))x\(Int(windowBounds?.height ?? 0)) orientation=\(orientation.rawValue)")
        #endif
    }
}

private struct WebArtifactView: UIViewRepresentable {
    let fileURL: URL
    let readAccessURL: URL
    let reloadToken: UUID
    var viewportSize: CGSize = .zero
    var fullBleedGameMode = false

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedFileURL: URL?
        var loadedReadAccessURL: URL?
        var loadedReloadToken: UUID?
        var lastViewportSize: CGSize = .zero
        var fullBleedGameMode = false
        /// The most recent authoritative viewport size reported by SwiftUI. Used to
        /// pin the DOM dimensions during the portrait -> landscape rotation window
        /// so the canvas never commits a portrait-width backing store (BUG-001).
        var currentViewportSize: CGSize = .zero

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            dispatchViewportResize(in: webView, explicitSize: currentViewportSize.width > 1 ? currentViewportSize : nil)
        }

        func dispatchViewportResize(in webView: WKWebView, explicitSize: CGSize? = nil) {
            // Use the authoritative Swift-provided pixel size when available so the
            // DOM sizing never depends on a stale webview viewport (e.g. during the
            // portrait -> landscape rotation window, where 100vw could still report
            // the portrait width and leave a black right third — BUG-001).
            let cssWidth: String
            let cssHeight: String
            if let size = explicitSize, size.width > 1, size.height > 1 {
                cssWidth = "\(Int(size.width))px"
                cssHeight = "\(Int(size.height))px"
            } else {
                cssWidth = "100vw"
                cssHeight = "100svh"
            }
            let fullBleedScript = fullBleedGameMode ? """
              const styleID = 'novaforge-fullscreen-game-style';
              let style = document.getElementById(styleID);
              if (!style) {
                style = document.createElement('style');
                style.id = styleID;
                document.head.appendChild(style);
              }
              style.textContent = `
                html, body {
                  width: \(cssWidth) !important;
                  height: \(cssHeight) !important;
                  min-height: \(cssHeight) !important;
                  margin: 0 !important;
                  padding: 0 !important;
                  overflow: hidden !important;
                  background: #06100c !important;
                  border-radius: 0 !important;
                }
                main {
                  position: fixed !important;
                  inset: 0 !important;
                  width: \(cssWidth) !important;
                  height: \(cssHeight) !important;
                  min-height: \(cssHeight) !important;
                  margin: 0 !important;
                  padding: 0 !important;
                  display: block !important;
                  overflow: hidden !important;
                  background: #06100c !important;
                  border-radius: 0 !important;
                }
                * {
                  box-shadow: none !important;
                }
                header { display: none !important; }
                .game-wrap,
                canvas {
                  position: fixed !important;
                  inset: 0 !important;
                  width: \(cssWidth) !important;
                  height: \(cssHeight) !important;
                  max-width: none !important;
                  max-height: none !important;
                  margin: 0 !important;
                  padding: 0 !important;
                  border: 0 !important;
                  border-radius: 0 !important;
                  box-shadow: none !important;
                  touch-action: none !important;
                }
                canvas { display: block !important; object-fit: fill !important; }
              `;
            """ : """
              const existingFullscreenStyle = document.getElementById('novaforge-fullscreen-game-style');
              if (existingFullscreenStyle) existingFullscreenStyle.remove();
            """
            let script = """
            (() => {
              document.documentElement.style.width = '\(cssWidth)';
              document.documentElement.style.height = '\(cssHeight)';
              document.body.style.width = '\(cssWidth)';
              document.body.style.height = '\(cssHeight)';
            \(fullBleedScript)
              window.dispatchEvent(new Event('resize'));
              console.log('NF_ARTIFACT_DOM_SIZE', window.innerWidth, window.innerHeight, document.documentElement.clientWidth, document.documentElement.clientHeight, document.body.clientWidth, document.body.clientHeight);
            })();
            """
            webView.evaluateJavaScript(script)
            #if DEBUG
            let frame = webView.frame
            let bounds = webView.bounds
            print("NF_ARTIFACT_WEBVIEW_SIZE frame=\(Int(frame.width))x\(Int(frame.height)) bounds=\(Int(bounds.width))x\(Int(bounds.height))")
            #endif
        }
    }

    final class WebContainerView: UIView {
        let webView: WKWebView
        weak var coordinator: Coordinator?
        private var lastLaidOutSize: CGSize = .zero

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            self.webView = WKWebView(frame: .zero, configuration: configuration)
            super.init(frame: .zero)
            backgroundColor = .black
            isOpaque = true
            webView.navigationDelegate = coordinator
            webView.isOpaque = false
            webView.backgroundColor = .clear
            webView.scrollView.backgroundColor = .clear
            webView.scrollView.contentInset = .zero
            webView.scrollView.scrollIndicatorInsets = .zero
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.scrollView.isScrollEnabled = false
            webView.allowsBackForwardNavigationGestures = true
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if #available(iOS 16.4, *) {
                webView.isInspectable = true
            }
            addSubview(webView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            Task { @MainActor [webView] in
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Sync the webview frame synchronously so the first landscape frame is
            // correct (no black strip), then reflow the DOM shortly after.
            webView.frame = bounds
            webView.scrollView.frame = bounds
            webView.scrollView.contentInset = .zero
            webView.scrollView.scrollIndicatorInsets = .zero
            let size = bounds.size
            guard size.width > 1, size.height > 1 else { return }
            if abs(size.width - lastLaidOutSize.width) > 1 || abs(size.height - lastLaidOutSize.height) > 1 {
                let previousSize = lastLaidOutSize
                lastLaidOutSize = size
                // Keep the coordinator's authoritative size in sync with the real
                // container bounds so dispatches pin the DOM to the landscape frame.
                coordinator?.currentViewportSize = size
                // Force an immediate reflow so the canvas resizes before any proof
                // capture, then re-dispatch once the layout settles for HTML that
                // listens to window resize events.
                coordinator?.dispatchViewportResize(in: webView, explicitSize: size)
                if previousSize.width > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        guard let self else { return }
                        self.coordinator?.dispatchViewportResize(in: self.webView, explicitSize: self.bounds.size)
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WebContainerView {
        WebContainerView(coordinator: context.coordinator)
    }

    func updateUIView(_ container: WebContainerView, context: Context) {
        context.coordinator.fullBleedGameMode = fullBleedGameMode
        let webView = container.webView
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        if viewportSize.width > 1, viewportSize.height > 1 {
            let viewportFrame = CGRect(origin: .zero, size: viewportSize)
            container.frame = viewportFrame
            container.bounds = viewportFrame
            // Record the authoritative size so every viewport-resize dispatch can pin
            // the DOM to it instead of trusting a stale webview viewport during the
            // portrait -> landscape rotation window (BUG-001).
            context.coordinator.currentViewportSize = viewportSize
            container.setNeedsLayout()
            container.layoutIfNeeded()
        }

        let shouldReload = context.coordinator.loadedFileURL != fileURL ||
            context.coordinator.loadedReadAccessURL != readAccessURL ||
            context.coordinator.loadedReloadToken != reloadToken
        let sizeChanged = abs(context.coordinator.lastViewportSize.width - viewportSize.width) > 1 ||
            abs(context.coordinator.lastViewportSize.height - viewportSize.height) > 1

        context.coordinator.lastViewportSize = viewportSize
        let explicitSize = viewportSize.width > 1 ? viewportSize : nil

        if shouldReload {
            context.coordinator.loadedFileURL = fileURL
            context.coordinator.loadedReadAccessURL = readAccessURL
            context.coordinator.loadedReloadToken = reloadToken
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                context.coordinator.dispatchViewportResize(in: webView, explicitSize: explicitSize)
            }
        } else if sizeChanged {
            // The webview already resizes via autoresizingMask in layoutSubviews; only
            // re-dispatch the viewport-resize JS so the canvas/game reflows to the new
            // landscape frame. Reloading the whole file here left a black right third
            // mid-reload (BUG-001). Keep the layer live and just reflow the DOM, pinned
            // to the authoritative Swift viewport size.
            DispatchQueue.main.async {
                context.coordinator.dispatchViewportResize(in: webView, explicitSize: explicitSize)
            }
            // The WKWebView layout viewport can lag the rotation; re-pin once more after
            // the layout settles so the canvas backing store matches the landscape frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                context.coordinator.dispatchViewportResize(in: webView, explicitSize: explicitSize)
            }
        }
    }
}
