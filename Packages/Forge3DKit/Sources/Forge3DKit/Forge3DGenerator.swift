import Foundation

public enum Forge3DGenerator {
    public static func generate(_ blueprint: Forge3DBlueprint) throws -> Forge3DGeneratedProject {
        try Forge3DBlueprintValidator.validate(blueprint)

        return Forge3DGeneratedProject(
            blueprint: blueprint,
            entryPath: "index.html",
            files: [
                Forge3DGeneratedFile(path: "index.html", contents: html(for: blueprint)),
                Forge3DGeneratedFile(path: "styles.css", contents: Forge3DTemplate.styles),
                Forge3DGeneratedFile(path: "game.js", contents: Forge3DTemplate.script(for: blueprint)),
            ],
            semanticCapabilities: [.localSave, .controller, .touch, .keyboard]
        )
    }

    private static func html(for blueprint: Forge3DBlueprint) -> String {
        let safeTitle = escapeHTML(blueprint.name.trimmingCharacters(in: .whitespacesAndNewlines))
        return #"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
          <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'none'">
          <title>\#(safeTitle)</title>
          <link rel="stylesheet" href="styles.css">
        </head>
        <body>
          <main id="scene-shell" aria-label="\#(safeTitle)">
            <canvas id="scene" role="img" aria-label="Interactive 3D driving scene"></canvas>
            <div id="status" class="status" role="status" aria-live="polite">Starting 3D scene</div>
            <button id="pause" class="pause" type="button" aria-pressed="false" aria-label="Pause scene">Ⅱ</button>
            <div id="joystick" class="joystick" role="group" tabindex="0" aria-label="Drive joystick. Drag up or down for throttle and left or right to steer.">
              <div id="joystick-knob" class="joystick-knob" aria-hidden="true"></div>
            </div>
          </main>
          <script src="game.js" defer></script>
        </body>
        </html>
        """#
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
