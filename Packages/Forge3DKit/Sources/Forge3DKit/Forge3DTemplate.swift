import Foundation

enum Forge3DTemplate {
    static let styles = #"""
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; background: #080b0f; }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; overscroll-behavior: none; background: #080b0f; }
    #scene-shell { position: relative; width: 100%; height: 100%; min-height: 100dvh; overflow: hidden; touch-action: none; }
    #scene { width: 100%; height: 100%; display: block; background: #0b1118; }
    .status { position: absolute; top: max(14px, env(safe-area-inset-top)); left: 50%; transform: translateX(-50%); min-height: 44px; max-width: min(72vw, 420px); padding: 10px 14px; border-radius: 16px; background: rgba(9,13,18,.78); color: #f6f8fa; font-weight: 650; text-align: center; backdrop-filter: blur(18px); }
    .pause { position: absolute; top: max(14px, env(safe-area-inset-top)); right: max(14px, env(safe-area-inset-right)); width: 48px; height: 48px; border-radius: 16px; border: 1px solid rgba(255,255,255,.18); background: rgba(9,13,18,.82); color: #fff; font: inherit; font-size: 20px; }
    .joystick { position: absolute; left: max(20px, env(safe-area-inset-left)); bottom: max(20px, env(safe-area-inset-bottom)); width: 132px; height: 132px; border-radius: 50%; border: 1px solid rgba(255,255,255,.18); background: rgba(12,18,25,.68); backdrop-filter: blur(18px); touch-action: none; outline: none; }
    .joystick:focus-visible { box-shadow: 0 0 0 3px rgba(255,255,255,.82); }
    .joystick-knob { position: absolute; left: 50%; top: 50%; width: 58px; height: 58px; margin: -29px; border-radius: 50%; background: rgba(229,242,252,.92); box-shadow: 0 4px 18px rgba(0,0,0,.28); transform: translate3d(0,0,0); }
    .assistive-driving { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); clip-path: inset(50%); white-space: nowrap; border: 0; }
    @media (prefers-reduced-transparency: reduce) { .status, .pause, .joystick { backdrop-filter: none; background: #151c25; } }
    @media (max-width: 500px) and (orientation: portrait) { .joystick { width: 116px; height: 116px; } }
    """#

    static func script(for blueprint: Forge3DBlueprint) -> String {
        scriptHeader(for: blueprint) + scriptCoreA + scriptCoreB + scriptCoreC
    }

    private static func scriptHeader(for blueprint: Forge3DBlueprint) -> String {
        #"""
        "use strict";

        const CONFIG = Object.freeze({
          fovDegrees: \#(format(blueprint.fieldOfViewDegrees)),
          worldHalfExtent: \#(format(blueprint.worldHalfExtent)),
          maxDPR: \#(format(blueprint.maximumDevicePixelRatio)),
          topSpeed: \#(format(blueprint.topSpeed)),
          acceleration: \#(format(blueprint.acceleration)),
          steeringRate: \#(format(blueprint.steeringRate)),
          saveKey: "\#(escapeJavaScript(blueprint.persistenceKey))",
          step: 1 / 60,
          maxFrameDelta: 0.2,
          maximumMarkers: 40
        });

        """#
    }

    private static func escapeJavaScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
