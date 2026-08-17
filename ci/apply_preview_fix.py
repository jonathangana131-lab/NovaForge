#!/usr/bin/env python3
from pathlib import Path

path = Path('AgentPad/Views/ArtifactPreviewSheet.swift')
text = path.read_text()

old_viewport = '''        func authoritativeViewportDidChange(in webView: WKWebView, size: CGSize) {
            guard size.width > 1, size.height > 1 else { return }
            let sizeChanged = !viewportMatches(currentViewportSize, size)
            currentViewportSize = size

            guard sizeChanged else {
'''
new_viewport = '''        func authoritativeViewportDidChange(in webView: WKWebView, size: CGSize) {
            guard size.width > 1, size.height > 1 else { return }
            let sizeChanged = !viewportMatches(currentViewportSize, size)
            currentViewportSize = size

            // Normal portrait previews do not need the expensive two-frame
            // compositor proof used to guard fullscreen rotation. Requiring that
            // handshake for every workspace HTML artifact can strand an otherwise
            // loaded page behind the loading cover on newer WebKit builds. Keep
            // normal previews responsive: resize them immediately and publish
            // readiness once main-frame navigation has completed. Full-bleed game
            // mode retains the strict viewport-keyed compositor handshake below.
            if !fullBleedGameMode {
                dispatchViewportResize(in: webView, explicitSize: size)
                if navigationFinished,
                   activeReloadToken != nil,
                   onLoadStateChange != nil {
                    renderAttempt = nil
                    failedViewportSize = nil
                    readyViewportSize = size
                    loadingPublication = nil
                    onLoadStateChange?(.ready)
                }
                return
            }

            guard sizeChanged else {
'''
if text.count(old_viewport) != 1:
    raise SystemExit(f'viewport marker count={text.count(old_viewport)}')
text = text.replace(old_viewport, new_viewport)

old_finish = '''            guard let reloadToken = activeReloadToken,
                  let viewportSize,
                  viewportSize.width > 1,
                  viewportSize.height > 1,
                  onLoadStateChange != nil else {
                dispatchViewportResize(in: webView, explicitSize: viewportSize)
                return
            }
            startRenderHandshake(
                in: webView,
                navigation: navigation,
                reloadToken: reloadToken,
                viewportSize: viewportSize
            )
'''
new_finish = '''            guard let reloadToken = activeReloadToken,
                  let viewportSize,
                  viewportSize.width > 1,
                  viewportSize.height > 1,
                  onLoadStateChange != nil else {
                dispatchViewportResize(in: webView, explicitSize: viewportSize)
                return
            }

            if !fullBleedGameMode {
                // WKNavigation.didFinish is the correct readiness boundary for a
                // normal embedded file preview. Apply NovaForge's authoritative
                // viewport first, then reveal the page. The stricter two-frame
                // render proof is reserved for fullscreen/rotation where backing-
                // store dimensions are correctness-critical.
                dispatchViewportResize(in: webView, explicitSize: viewportSize) { [weak self] error in
                    guard let self,
                          self.activeReloadToken == reloadToken,
                          self.isActive(navigation),
                          self.viewportMatches(self.currentViewportSize, viewportSize)
                    else { return }
                    self.renderAttempt = nil
                    self.loadingPublication = nil
                    if let error {
                        self.readyViewportSize = nil
                        self.failedViewportSize = viewportSize
                        self.onLoadStateChange?(.failed("The preview could not apply its viewport. \\(error.localizedDescription)"))
                    } else {
                        self.readyViewportSize = viewportSize
                        self.failedViewportSize = nil
                        self.onLoadStateChange?(.ready)
                    }
                }
                return
            }

            startRenderHandshake(
                in: webView,
                navigation: navigation,
                reloadToken: reloadToken,
                viewportSize: viewportSize
            )
'''
if text.count(old_finish) != 1:
    raise SystemExit(f'didFinish marker count={text.count(old_finish)}')
text = text.replace(old_finish, new_finish)
path.write_text(text)
print('patched ArtifactPreviewSheet.swift')
