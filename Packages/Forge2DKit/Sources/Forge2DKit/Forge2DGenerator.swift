import Foundation

public enum Forge2DGenerator {
    public static func generate(_ blueprint: Forge2DBlueprint) throws -> Forge2DGeneratedProject {
        try Forge2DBlueprintValidator.validate(blueprint)

        let files = [
            Forge2DGeneratedFile(path: "index.html", contents: html(for: blueprint)),
            Forge2DGeneratedFile(
                path: "styles.css",
                contents: Forge2DTemplate.styles + "\n" + Forge2DV14Hardening.styles
            ),
            Forge2DGeneratedFile(
                path: "game.js",
                contents: Forge2DTemplate.script(for: blueprint) + "\n" + Forge2DV14Hardening.script
            ),
        ]

        return Forge2DGeneratedProject(
            blueprint: blueprint,
            entryPath: "index.html",
            files: files,
            semanticCapabilities: [.localSave, .audio, .controller, .touch, .keyboard]
        )
    }

    private static func html(for blueprint: Forge2DBlueprint) -> String {
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
          <main id="game-shell" aria-label="\#(safeTitle)">
            <canvas id="game" role="img" aria-label="Playable 2D game canvas"></canvas>
            <div id="status" class="status" role="status" aria-live="polite">Ready</div>
            <button id="pause" class="pause" type="button" aria-pressed="false" aria-label="Pause game">Ⅱ</button>
            <div class="controls controls-left" aria-label="Movement controls">
              <button id="left" type="button" aria-label="Move left">◀</button>
              <button id="right" type="button" aria-label="Move right">▶</button>
            </div>
            <div class="controls controls-right" aria-label="Action controls">
              <button id="jump" type="button" aria-label="Jump">↑</button>
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
