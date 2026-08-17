#!/usr/bin/env python3
from pathlib import Path

path = Path('AgentPad/Views/ArtifactPreviewSheet.swift')
text = path.read_text()

old = '''            guard let reloadToken = activeReloadToken,
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

new = '''            guard let reloadToken = activeReloadToken,
                  onLoadStateChange != nil else {
                dispatchViewportResize(in: webView, explicitSize: viewportSize)
                return
            }

            if !fullBleedGameMode {
                // For a normal embedded local-file preview, main-frame navigation
                // completion is the authoritative readiness boundary. Do not keep
                // a visibly loaded page hidden behind "Loading preview" while
                // waiting for evaluateJavaScript's completion callback: WebKit on
                // iOS 27 can defer that callback even though didFinish has fired.
                // Viewport adjustment is presentation-only here, so publish ready
                // first and apply the authoritative size best-effort afterward.
                renderAttempt = nil
                failedViewportSize = nil
                loadingPublication = nil
                if let viewportSize,
                   viewportSize.width > 1,
                   viewportSize.height > 1 {
                    readyViewportSize = viewportSize
                } else {
                    readyViewportSize = nil
                }
                onLoadStateChange?(.ready)

                dispatchViewportResize(in: webView, explicitSize: viewportSize) { [weak self] error in
                    guard let self,
                          self.activeReloadToken == reloadToken,
                          self.isActive(navigation)
                    else { return }
                    #if DEBUG
                    if let error {
                        print("NF_ARTIFACT_NORMAL_VIEWPORT_RESIZE_WARNING \\(error.localizedDescription)")
                    }
                    #endif
                }
                return
            }

            guard let viewportSize,
                  viewportSize.width > 1,
                  viewportSize.height > 1 else {
                // Full-bleed game mode still requires an authoritative viewport
                // before its compositor proof can begin.
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

if text.count(old) != 1:
    raise SystemExit(f'expected exactly one didFinish normal-preview block, found {text.count(old)}')
text = text.replace(old, new)
path.write_text(text)
print('PASS: staged iOS 27 normal artifact preview readiness repair')
