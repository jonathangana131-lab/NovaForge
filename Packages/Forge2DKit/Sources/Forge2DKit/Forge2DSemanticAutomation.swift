import Foundation

enum Forge2DSemanticAutomationIssue: Error, Equatable, Sendable {
    case templateContractMismatch(String)
}

/// Keeps the standalone Forge2D starter aligned with Forge Runtime's canonical semantic-web
/// vocabulary without importing or duplicating Runtime authorization/session/evidence authority.
///
/// These transformations are deliberately fail-closed. If the generated game template changes in
/// a way that invalidates one of the expected input seams, generation throws instead of silently
/// advertising automation that no longer drives the game.
enum Forge2DSemanticAutomation {
    static let controlAttribute = "data-novaforge-control"
    static let actionAttribute = "data-novaforge-action"
    static let actionEventName = "novaforge:action"

    static func patch(_ baseScript: String) throws -> String {
        var script = baseScript

        script = try replacingExactlyOnce(
            in: script,
            anchor: "const input = { keyboardLeft: false, keyboardRight: false, touchLeft: false, touchRight: false, gamepadAxis: 0, jumpQueued: false, gamepadJumpWasDown: false, gamepadPauseWasDown: false };",
            replacement: "const input = { keyboardLeft: false, keyboardRight: false, touchLeft: false, touchRight: false, gamepadAxis: 0, automationAxis: 0, jumpQueued: false, gamepadJumpWasDown: false, gamepadPauseWasDown: false };"
        )

        script = try replacingExactlyOnce(
            in: script,
            anchor: "controls.jump.addEventListener(\"pointercancel\", () => { controls.jump.dataset.active = \"false\"; });",
            replacement: """
            controls.jump.addEventListener("pointercancel", () => { controls.jump.dataset.active = "false"; });
            // Forge Runtime `control.activate` uses HTMLElement.click(); keep that semantic path
            // separate from pointer state while sharing the same bounded jump queue.
            controls.jump.addEventListener("click", queueJump);
            """
        )

        script = try replacingExactlyOnce(
            in: script,
            anchor: "window.addEventListener(\"keydown\", event => {",
            replacement: """
            const semanticMoveTarget = document.querySelector('[data-novaforge-action="\(Forge2DSelfPlayContract.moveXTargetID)"]');
            if (semanticMoveTarget) {
              semanticMoveTarget.addEventListener("\(actionEventName)", event => {
                const detail = event.detail;
                if (!detail || detail.actionID !== "\(Forge2DSelfPlayContract.moveXTargetID)" || !Number.isFinite(detail.value)) return;
                input.automationAxis = bounded(detail.value, -1, 1);
              });
            }

            window.addEventListener("keydown", event => {
            """
        )

        script = try replacingExactlyOnce(
            in: script,
            anchor: "const horizontal = (rightDown ? 1 : 0) - (leftDown ? 1 : 0);",
            replacement: """
            const humanHorizontal = (rightDown ? 1 : 0) - (leftDown ? 1 : 0);
            const horizontal = bounded(humanHorizontal + input.automationAxis, -1, 1);
            """
        )

        return script
    }

    private static func replacingExactlyOnce(
        in source: String,
        anchor: String,
        replacement: String
    ) throws -> String {
        guard let range = source.range(of: anchor) else {
            throw Forge2DSemanticAutomationIssue.templateContractMismatch(anchor)
        }
        guard source[range.upperBound...].range(of: anchor) == nil else {
            throw Forge2DSemanticAutomationIssue.templateContractMismatch(anchor)
        }

        var result = source
        result.replaceSubrange(range, with: replacement)
        return result
    }
}
