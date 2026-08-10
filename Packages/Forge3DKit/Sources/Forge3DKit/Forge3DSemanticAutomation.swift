import Foundation

enum Forge3DSemanticAutomationIssue: Error, Equatable, Sendable {
    case templateContractMismatch(String)
}

/// Keeps the generated Forge3D starter aligned with Forge Runtime's canonical semantic-web
/// vocabulary while leaving authorization, session ownership, dispatch receipts, and completion
/// authority entirely in ForgeRuntimeKit.
///
/// Patching is exact-once and fail-closed: template drift must surface as a generation error rather
/// than silently advertising an automation target that no longer controls the scene.
enum Forge3DSemanticAutomation {
    static let actionEventName = "novaforge:action"

    static func patch(_ baseScript: String) throws -> String {
        var script = baseScript

        script = try replacingExactlyOnce(
            in: script,
            anchor: "const input = { keyThrottle: 0, keySteer: 0, touchThrottle: 0, touchSteer: 0, accessibleThrottle: 0, accessibleSteer: 0, padThrottle: 0, padSteer: 0, padPauseWasDown: false };",
            replacement: "const input = { keyThrottle: 0, keySteer: 0, touchThrottle: 0, touchSteer: 0, accessibleThrottle: 0, accessibleSteer: 0, padThrottle: 0, padSteer: 0, automationThrottle: 0, automationSteer: 0, padPauseWasDown: false };"
        )

        script = try replacingExactlyOnce(
            in: script,
            anchor: "function updateKeyboard() {",
            replacement: """
            const semanticThrottleTarget = document.querySelector('[data-novaforge-action="\(Forge3DSelfPlayContract.throttleTargetID)"]');
            const semanticSteerTarget = document.querySelector('[data-novaforge-action="\(Forge3DSelfPlayContract.steerTargetID)"]');
            if (semanticThrottleTarget) {
              semanticThrottleTarget.addEventListener("\(actionEventName)", event => {
                const detail = event.detail;
                if (!detail || detail.actionID !== "\(Forge3DSelfPlayContract.throttleTargetID)" || !Number.isFinite(detail.value)) return;
                input.automationThrottle = clamp(detail.value, -1, 1);
              });
            }
            if (semanticSteerTarget) {
              semanticSteerTarget.addEventListener("\(actionEventName)", event => {
                const detail = event.detail;
                if (!detail || detail.actionID !== "\(Forge3DSelfPlayContract.steerTargetID)" || !Number.isFinite(detail.value)) return;
                input.automationSteer = clamp(detail.value, -1, 1);
              });
            }

            function updateKeyboard() {
            """
        )

        script = try replacingExactlyOnce(
            in: script,
            anchor: "const throttle = clamp(input.keyThrottle + input.touchThrottle + input.accessibleThrottle + input.padThrottle, -1, 1);",
            replacement: "const throttle = clamp(input.keyThrottle + input.touchThrottle + input.accessibleThrottle + input.padThrottle + input.automationThrottle, -1, 1);"
        )

        script = try replacingExactlyOnce(
            in: script,
            anchor: "const steer = clamp(input.keySteer + input.touchSteer + input.accessibleSteer + input.padSteer, -1, 1);",
            replacement: "const steer = clamp(input.keySteer + input.touchSteer + input.accessibleSteer + input.padSteer + input.automationSteer, -1, 1);"
        )

        return script
    }

    private static func replacingExactlyOnce(
        in source: String,
        anchor: String,
        replacement: String
    ) throws -> String {
        guard let range = source.range(of: anchor) else {
            throw Forge3DSemanticAutomationIssue.templateContractMismatch(anchor)
        }
        guard source[range.upperBound...].range(of: anchor) == nil else {
            throw Forge3DSemanticAutomationIssue.templateContractMismatch(anchor)
        }

        var result = source
        result.replaceSubrange(range, with: replacement)
        return result
    }
}
