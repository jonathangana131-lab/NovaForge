import Foundation

struct LocalAgentPlan: Sendable {
    let intro: String
    let toolCalls: [APIToolCall]
    let completion: String
}

enum LocalAgentPlanner {
    static func plan(prompt: String, workspace: SandboxWorkspace) -> LocalAgentPlan? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()

        if isProjectContinuation(lower) {
            let context = continuationContext(from: trimmed, workspace: workspace)
            return plan(
                intro: context.intro,
                requests: context.requests,
                completion: context.completion
            )
        }

        if let command = commandIntent(from: trimmed, lower: lower) {
            return plan(
                intro: "I can run that in the sandbox.",
                requests: [ToolRequest(id: id("local-command"), name: "run_command", arguments: ["command": command])],
                completion: "Command finished. I kept the output compact in the run card."
            )
        }

        if lower.contains("list files") || lower.contains("show files") || lower == "files" || lower.contains("what files") {
            return plan(
                intro: "I’ll list the workspace files.",
                requests: [ToolRequest(id: id("local-list"), name: "list_directory", arguments: ["path": ""])],
                completion: "Workspace scan finished."
            )
        }

        if let query = searchIntent(from: trimmed, lower: lower) {
            return plan(
                intro: "I’ll search the workspace for that.",
                requests: [ToolRequest(id: id("local-search"), name: "search_text", arguments: ["query": query])],
                completion: "Search finished. Open the result details if you want the matching lines."
            )
        }

        if let path = readIntent(from: trimmed, lower: lower) {
            return plan(
                intro: "I’ll read that file.",
                requests: [ToolRequest(id: id("local-read"), name: "read_file", arguments: ["path": path])],
                completion: "File read complete."
            )
        }

        if wantsSampleNativeSwiftGame(lower) {
            return plan(
                intro: "I’ll create a native Swift game artifact manifest with exportable SwiftUI source.",
                requests: [
                    ToolRequest(
                        id: id("local-swift-game-manifest"),
                        name: "write_file",
                        arguments: [
                            "path": SwiftGameArtifactFactory.sampleManifestPath,
                            "contents": SwiftGameArtifactFactory.sampleManifestJSON()
                        ]
                    ),
                    ToolRequest(
                        id: id("local-swift-game-source"),
                        name: "write_file",
                        arguments: [
                            "path": SwiftGameArtifactFactory.sampleSourcePath,
                            "contents": SwiftGameArtifactFactory.exportSource()
                        ]
                    ),
                    ToolRequest(
                        id: id("local-swift-game-readme"),
                        name: "write_file",
                        arguments: [
                            "path": SwiftGameArtifactFactory.sampleReadmePath,
                            "contents": SwiftGameArtifactFactory.readme()
                        ]
                    ),
                    ToolRequest(
                        id: id("local-swift-game-info"),
                        name: "file_info",
                        arguments: ["path": SwiftGameArtifactFactory.sampleManifestPath]
                    )
                ],
                completion: "Native Swift game artifact ready. Open StarfieldSprint.nf-game.json to play it, rotate sideways for handheld mode, or inspect the export files."
            )
        }

        // NOTE: "build/make me a game" and "make a web page" used to be intercepted
        // here by hardcoded HTML generators (wantsGeneratedGame /
        // wantsGeneratedWebArtifact), which meant the on-device model never actually
        // generated anything for the most common creative prompts. Those shortcuts
        // are removed so generation prompts fall through to `nil` and reach the real
        // model. Only explicit, safe sandbox operations (run command, list/search/
        // read/write files) keep their deterministic scripted plans, since those are
        // correct and faster than model round-trips.

        if let write = writeIntent(from: trimmed, lower: lower) {
            return plan(
                intro: "I’ll write that file in the sandbox.",
                requests: [
                    ToolRequest(
                        id: id("local-write"),
                        name: "write_file",
                        arguments: ["path": write.path, "contents": write.contents]
                    )
                ],
                completion: "File written."
            )
        }

        return nil
    }

    private static func wantsSampleNativeSwiftGame(_ lower: String) -> Bool {
        let mentionsSwiftGame = lower.contains("swift game") ||
            lower.contains("native game") ||
            lower.contains("native swift") ||
            lower.contains("swift-game") ||
            lower.contains("swiftgame")
        let asksForSample = lower.contains("sample") ||
            lower.contains("demo") ||
            lower.contains("seed") ||
            lower.contains("artifact mode") ||
            lower.contains("game artifact")
        let asksToCreate = ["make", "build", "create", "write", "generate", "prototype"]
            .contains { lower.contains($0) }
        return mentionsSwiftGame && (asksForSample || asksToCreate)
    }

    private static func plan(intro: String, requests: [ToolRequest], completion: String) -> LocalAgentPlan {
        let calls = requests.map { request in
            APIToolCall(
                id: request.id,
                type: "function",
                function: APIFunctionCall(name: request.name, arguments: request.argumentsJSON)
            )
        }
        return LocalAgentPlan(intro: intro, toolCalls: calls, completion: completion)
    }

    private static func id(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    private static func isProjectContinuation(_ lower: String) -> Bool {
        lower.contains("novaforge project continuation") ||
            (lower.contains("continue the active project") && lower.contains("recommended next step"))
    }

    private struct ContinuationContext {
        let intro: String
        let requests: [ToolRequest]
        let completion: String
    }

    private static func continuationContext(from prompt: String, workspace: SandboxWorkspace) -> ContinuationContext {
        let project = lineValue(prefix: "Project:", in: prompt) ?? "active project"
        let mission = lineValue(prefix: "Mission:", in: prompt) ?? "the project mission"
        let nextStep = lineValue(prefix: "Recommended next step:", in: prompt) ?? "choose the next useful project step"
        let blocker = lineValue(prefix: "Blocker:", in: prompt)
        let latestProofLine = lineValue(prefix: "Latest proof:", in: prompt)
        let proofPath = latestProofLine
            .flatMap { firstPath(in: $0) }
            .flatMap { workspaceFileExists($0, workspace: workspace) ? $0 : nil }

        var requests: [ToolRequest] = [
            ToolRequest(
                id: id("local-project-summary"),
                name: "workspace_summary",
                arguments: ["max_items": "1000"]
            )
        ]

        if let proofPath {
            requests.append(
                ToolRequest(
                    id: id("local-proof-info"),
                    name: "file_info",
                    arguments: ["path": proofPath]
                )
            )
            if proofPath.lowercased().hasSuffix(".html") || proofPath.lowercased().hasSuffix(".htm") {
                requests.append(
                    ToolRequest(
                        id: id("local-proof-validate"),
                        name: "validate_html_file",
                        arguments: ["path": proofPath, "profile": "auto"]
                    )
                )
            }
        } else {
            requests.append(
                ToolRequest(
                    id: id("local-project-tree"),
                    name: "list_tree",
                    arguments: ["max_depth": "4", "max_items": "250"]
                )
            )
        }

        if blocker != nil, proofPath == nil {
            requests.append(
                ToolRequest(
                    id: id("local-blocker-search"),
                    name: "search_text",
                    arguments: ["query": "TODO"]
                )
            )
        }

        let action = blocker == nil ? nextStep : "review the blocker before changing work"
        let proofDetail = proofPath.map { "checked \($0)" } ?? "captured a workspace summary and project tree"
        return ContinuationContext(
            intro: "Agent Plan: I’ll inspect \(project) against its mission, then choose the next concrete action. Mission focus: \(compactSentence(mission)). Next: \(compactSentence(action)).",
            requests: uniquedRequests(requests),
            completion: "Agent Proof: \(proofDetail). No workspace mutation was made during this continuation scan. Next step: \(compactSentence(nextStep))."
        )
    }

    private static func lineValue(prefix: String, in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let value = String(line)
            guard value.hasPrefix(prefix) else { continue }
            let trimmed = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func uniquedRequests(_ requests: [ToolRequest]) -> [ToolRequest] {
        var seen = Set<String>()
        return requests.filter { request in
            let key = "\(request.name):\(request.argumentsJSON)"
            return seen.insert(key).inserted
        }
    }

    private static func compactSentence(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > 150 else { return oneLine }
        return String(oneLine.prefix(149)) + "…"
    }

    private static func commandIntent(from prompt: String, lower: String) -> String? {
        for prefix in ["run command ", "run terminal ", "terminal "] {
            if lower.hasPrefix(prefix) {
                return String(prompt.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func searchIntent(from prompt: String, lower: String) -> String? {
        guard lower.contains("search") || lower.contains("find text") else { return nil }
        let separators = ["search for ", "search ", "find text "]
        for separator in separators {
            if let range = lower.range(of: separator) {
                let start = prompt.index(prompt.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                let query = String(prompt[start...]).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
                return query.isEmpty ? nil : query
            }
        }
        return nil
    }

    private static func readIntent(from prompt: String, lower: String) -> String? {
        guard lower.contains("read") || lower.contains("open") || lower.contains("show") else { return nil }
        return firstPath(in: prompt)
    }

    private static func writeIntent(from prompt: String, lower: String) -> (path: String, contents: String)? {
        guard lower.contains("write file") || lower.contains("create file") else { return nil }
        let path = firstPath(in: prompt) ?? "notes/local-note.txt"
        let contentSeparators = [" with ", " containing ", " content "]
        for separator in contentSeparators {
            if let range = lower.range(of: separator) {
                let start = prompt.index(prompt.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                let contents = String(prompt[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return (path, contents.isEmpty ? "Created by NovaForge Local.\n" : contents)
            }
        }
        return (path, "Created by NovaForge Local.\n")
    }

    private static func wantsGeneratedGame(_ lower: String) -> Bool {
        let action = [
            "make", "build", "create", "write", "improve", "fix", "optimize",
            "tune", "refine", "continue", "update"
        ].contains { lower.contains($0) }
        let game = lower.contains("game") || lower.contains("snake") || lower.contains("slither")
        let web = lower.contains("html") || lower.contains("canvas") || lower.contains("browser") || game
        return action && game && web
    }

    private static func preferredHTMLPath(from prompt: String, lower: String, workspace: SandboxWorkspace) -> String {
        if let path = firstPath(in: prompt), path.lowercased().hasSuffix(".html") {
            return path
        }
        let shouldContinueExisting = ["continue", "improve", "fix", "optimize", "tune", "refine", "update"]
            .contains { lower.contains($0) }
        if shouldContinueExisting, let existing = existingHTMLArtifact(in: workspace) {
            return existing.relativePath
        }
        if lower.contains("slither") { return "slither-arena.html" }
        if lower.contains("snake") { return "snake.html" }
        return "novaforge-arcade.html"
    }

    private static func existingHTMLArtifact(in workspace: SandboxWorkspace) -> FileItem? {
        // Keep local planning instant on older iPhones: a prompt like "continue the game"
        // should not recursively scan thousands of workspace files on the main actor.
        var newest: FileItem?
        var pendingDirectories = [""]
        var visitedDirectories = 0
        var visitedFiles = 0
        let maxDirectories = 40
        let maxFiles = 500

        while let directory = pendingDirectories.popLast() {
            if Task.isCancelled { return newest }
            guard visitedDirectories < maxDirectories, visitedFiles < maxFiles else { break }
            visitedDirectories += 1
            guard let items = try? workspace.list(directory) else { continue }
            for item in items {
                if Task.isCancelled { return newest }
                if item.isDirectory {
                    if pendingDirectories.count < maxDirectories {
                        pendingDirectories.append(item.relativePath)
                    }
                } else {
                    visitedFiles += 1
                    if item.relativePath.lowercased().hasSuffix(".html"),
                       (item.modifiedAt ?? .distantPast) > (newest?.modifiedAt ?? .distantPast) {
                        newest = item
                    }
                    if visitedFiles >= maxFiles { break }
                }
            }
        }

        return newest
    }

    private static func firstPath(in prompt: String) -> String? {
        let pattern = #"[A-Za-z0-9_\-./]+\.(html|css|js|swift|md|txt|json|log)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        guard let match = regex.firstMatch(in: prompt, range: range),
              let swiftRange = Range(match.range, in: prompt) else { return nil }
        let path = String(prompt[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'` "))
        if path.hasPrefix("/") || path.contains("..") { return nil }
        return path
    }

    private static func gameTitle(from prompt: String) -> String {
        let lower = prompt.lowercased()
        if lower.contains("slither") { return "Slither Arena" }
        if lower.contains("snake") { return "Snake Arena" }
        return "NovaForge Arcade"
    }

    private static func wantsGeneratedWebArtifact(_ lower: String) -> Bool {
        let action = [
            "make", "build", "create", "write", "design", "prototype", "mock up", "mockup", "generate"
        ].contains { lower.contains($0) }
        let artifact = [
            "web page", "webpage", "website", "landing page", "portfolio", "dashboard", "html page",
            "single page", "web app", "microsite", "page"
        ].contains { lower.contains($0) }
        return action && artifact && !wantsGeneratedGame(lower)
    }

    private static func preferredWebArtifactPath(from prompt: String, lower: String, workspace: SandboxWorkspace) -> String {
        if let path = firstPath(in: prompt), path.lowercased().hasSuffix(".html") {
            return path
        }
        let base: String
        if lower.contains("dashboard") {
            base = "dashboard"
        } else if lower.contains("portfolio") {
            base = "portfolio"
        } else if lower.contains("landing") {
            base = "landing-page"
        } else if lower.contains("website") || lower.contains("web page") || lower.contains("webpage") {
            base = "website"
        } else {
            base = "novaforge-page"
        }
        return firstAvailableHTMLPath(base: base, workspace: workspace)
    }

    private static func firstAvailableHTMLPath(base: String, workspace: SandboxWorkspace) -> String {
        let sanitizedBase = base
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let candidateBase = sanitizedBase.isEmpty ? "novaforge-page" : sanitizedBase
        for index in 0..<100 {
            let path = index == 0 ? "\(candidateBase).html" : "\(candidateBase)-\(index + 1).html"
            if !workspaceFileExists(path, workspace: workspace) {
                return path
            }
        }
        return "\(candidateBase)-\(UUID().uuidString.prefix(8)).html"
    }

    private static func workspaceFileExists(_ path: String, workspace: SandboxWorkspace) -> Bool {
        guard let url = try? workspace.resolve(path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func webArtifactTitle(from prompt: String, lower: String) -> String {
        if lower.contains("portfolio") { return "NovaForge Portfolio" }
        if lower.contains("dashboard") { return "Launch Dashboard" }
        if lower.contains("landing") { return "Launch Landing Page" }
        if lower.contains("website") { return "NovaForge Website" }
        if let path = firstPath(in: prompt) {
            return path
                .split(separator: "/")
                .last?
                .replacingOccurrences(of: ".html", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized ?? "NovaForge Page"
        }
        return "NovaForge Page"
    }

    private static func validatedHTMLRequests(path: String, contents: String, idPrefix: String, profile: String) -> [ToolRequest] {
        [
            ToolRequest(
                id: id("\(idPrefix)-write"),
                name: "write_file",
                arguments: ["path": path, "contents": contents]
            ),
            ToolRequest(
                id: id("\(idPrefix)-validate"),
                name: "validate_html_file",
                arguments: ["path": path, "profile": profile]
            ),
            ToolRequest(
                id: id("\(idPrefix)-info"),
                name: "file_info",
                arguments: ["path": path]
            )
        ]
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func webArtifactHTML(title: String, lower: String) -> String {
        let eyebrow = lower.contains("portfolio") ? "PORTFOLIO" : lower.contains("dashboard") ? "DASHBOARD" : "LAUNCH PAGE"
        let primary = lower.contains("portfolio") ? "View Work" : lower.contains("dashboard") ? "Review Metrics" : "Start Project"
        let secondary = lower.contains("portfolio") ? "Book Joey" : lower.contains("dashboard") ? "Open Roadmap" : "See Demo"
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>\(title)</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif; }
            * { box-sizing: border-box; }
            html, body { min-height: 100%; margin: 0; background: #071018; color: #f4fbff; }
            body { overflow-x: hidden; background: radial-gradient(circle at 12% 8%, #1b6c84 0, transparent 34%), radial-gradient(circle at 86% 12%, #6c3dff66 0, transparent 32%), linear-gradient(135deg, #071018 0%, #0b1624 52%, #071018 100%); }
            main { min-height: 100svh; padding: max(22px, env(safe-area-inset-top)) max(18px, env(safe-area-inset-right)) max(22px, env(safe-area-inset-bottom)) max(18px, env(safe-area-inset-left)); display: grid; grid-template-rows: auto 1fr auto; gap: clamp(18px, 3vw, 34px); }
            nav, .hero, .metric, .panel, footer { border: 1px solid #ffffff24; background: linear-gradient(145deg, #ffffff18, #ffffff09); box-shadow: 0 24px 90px #0008, inset 0 1px 0 #ffffff2e; backdrop-filter: blur(22px); }
            nav { display: flex; align-items: center; justify-content: space-between; gap: 12px; border-radius: 22px; padding: 12px 14px; }
            .brand { display: flex; align-items: center; gap: 10px; font-weight: 900; letter-spacing: -.03em; }
            .logo { width: 36px; height: 36px; border-radius: 13px; display: grid; place-items: center; background: linear-gradient(135deg, #39e7ff, #8affc1); color: #061018; }
            .nav-actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
            .pill, button { border: 1px solid #ffffff24; border-radius: 999px; padding: 9px 12px; background: #07101899; color: #f4fbff; font-weight: 800; }
            .stage { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(260px, .9fr); align-items: stretch; gap: clamp(16px, 3vw, 28px); }
            .hero { border-radius: clamp(24px, 4vw, 42px); padding: clamp(22px, 5vw, 56px); display: grid; align-content: center; gap: 18px; min-height: min(620px, 62svh); }
            .eyebrow { color: #8affc1; font-size: 12px; font-weight: 1000; letter-spacing: .18em; }
            h1 { margin: 0; max-width: 11ch; font-size: clamp(48px, 12vw, 118px); line-height: .86; letter-spacing: -.075em; }
            p { margin: 0; color: #c9d7e1; font-size: clamp(16px, 2.2vw, 22px); line-height: 1.35; max-width: 58ch; }
            .cta { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 4px; }
            .cta button:first-child { background: linear-gradient(135deg, #39e7ff, #8affc1); color: #061018; }
            .side { display: grid; gap: 14px; grid-template-rows: repeat(3, minmax(0, 1fr)); }
            .metric, .panel { border-radius: 26px; padding: clamp(18px, 3vw, 28px); display: grid; gap: 10px; align-content: center; min-width: 0; }
            .number { font-size: clamp(34px, 8vw, 74px); line-height: .9; font-weight: 1000; letter-spacing: -.06em; color: #8affc1; }
            .panel strong, .metric strong { font-size: clamp(17px, 2vw, 24px); }
            footer { border-radius: 20px; padding: 12px 14px; display: flex; justify-content: space-between; gap: 12px; color: #9bb3c7; font-size: 13px; font-weight: 700; }
            @media (max-width: 760px) {
              main { gap: 14px; }
              nav, footer { border-radius: 18px; }
              .stage { grid-template-columns: 1fr; }
              .hero { min-height: auto; }
              h1 { max-width: 9ch; }
              .side { grid-template-rows: none; }
            }
            @media (orientation: landscape) and (max-height: 520px) {
              main { min-height: 100vh; gap: 10px; padding: 10px max(12px, env(safe-area-inset-right)) 10px max(12px, env(safe-area-inset-left)); }
              nav, footer { padding: 8px 10px; }
              .stage { grid-template-columns: minmax(0, 1fr) minmax(280px, .9fr); gap: 10px; }
              .hero, .metric, .panel { border-radius: 22px; padding: 18px; }
              .hero { min-height: 0; }
              h1 { font-size: clamp(34px, 11vh, 62px); max-width: 12ch; }
              p { font-size: 14px; }
              .number { font-size: clamp(30px, 10vh, 54px); }
            }
          </style>
        </head>
        <body>
          <main>
            <nav aria-label="Artifact navigation"><div class="brand"><span class="logo">✦</span><span>\(title)</span></div><div class="nav-actions"><span class="pill">Responsive</span><span class="pill">Local HTML</span></div></nav>
            <section class="stage">
              <article class="hero">
                <div class="eyebrow">\(eyebrow)</div>
                <h1>Ship a beautiful idea.</h1>
                <p>A polished, self-contained NovaForge artifact with safe-area spacing, readable landscape layout, glass cards, and live-preview friendly CSS.</p>
                <div class="cta"><button>\(primary)</button><button>\(secondary)</button></div>
              </article>
              <aside class="side" aria-label="Highlights">
                <div class="metric"><span class="number">3×</span><strong>Faster first draft</strong><p>Starts with real files instead of a chat-only mockup.</p></div>
                <div class="panel"><strong>Landscape-ready</strong><p>Uses fluid grids and compact landscape rules so previews stay useful on iPhone.</p></div>
                <div class="panel"><strong>Offline artifact</strong><p>No CDN, no network, and no hidden dependency: everything is inside this HTML file.</p></div>
              </aside>
            </section>
            <footer><span>Generated by NovaForge Local</span><span>Open · Share · Iterate</span></footer>
          </main>
        </body>
        </html>
        """
    }

    private static func snakeGameHTML(title: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <title>\(title)</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; }
            * { box-sizing: border-box; }
            html, body { width: 100%; height: 100%; min-height: 100%; background: #06100c; overflow: hidden; }
            body { margin: 0; background: radial-gradient(circle at 22% 12%, #123a2a, #06100c 56%); color: #effff5; }
            main { width: 100%; height: 100%; padding: max(10px, env(safe-area-inset-top)) max(10px, env(safe-area-inset-right)) max(10px, env(safe-area-inset-bottom)) max(10px, env(safe-area-inset-left)); display: grid; grid-template-columns: minmax(170px, .34fr) minmax(0, .66fr); align-items: stretch; overflow: hidden; gap: clamp(10px, 2vw, 24px); }
            header { display: grid; gap: clamp(8px, 1.5vmin, 14px); align-content: center; min-width: 0; }
            h1 { margin: 0; font-size: clamp(22px, 5vmin, 52px); line-height: .94; letter-spacing: -.045em; }
            p { margin: 0; max-width: 30rem; color: #b5d6c4; font-size: clamp(12px, 2vmin, 18px); line-height: 1.22; }
            .score { width: fit-content; display: grid; gap: 1px; font-weight: 900; color: #8fffc1; font-size: clamp(15px, 2.6vmin, 26px); padding: 10px 13px; border: 1px solid #2d6c50; border-radius: 16px; background: #0a1d15cc; }
            .score span { font-size: 1.15em; }
            .game-wrap { width: 100%; height: 100%; min-width: 0; min-height: 0; justify-self: stretch; align-self: stretch; }
            canvas { display: block; width: 100%; height: 100%; background: radial-gradient(circle at 30% 20%, #163c2d, #08130f 58%); border: 1px solid #255540; border-radius: clamp(14px, 3vmin, 26px); box-shadow: inset 0 0 22px #58ffa314; touch-action: none; }
            .bar { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 4px; }
            button { appearance: none; border: 1px solid #37634e; background: #13221acc; color: #effff5; border-radius: 12px; padding: 9px 12px; font-weight: 800; }
            @media (orientation: landscape) {
              main { grid-template-columns: minmax(150px, .30fr) minmax(0, .70fr); }
              .game-wrap { width: 100%; height: 100%; }
            }
            @media (orientation: landscape) and (max-height: 360px), (orientation: landscape) and (max-width: 720px) {
              main { position: relative; display: block; padding: 0; overflow: hidden; }
              header { position: absolute; inset: 8px auto auto 8px; z-index: 2; display: flex; align-items: center; gap: 8px; pointer-events: none; }
              header > div:first-child { min-width: 0; }
              h1 { font-size: clamp(16px, 5vmin, 24px); max-width: 11rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; text-shadow: 0 2px 8px #000b; }
              p, .bar { display: none; }
              .score { font-size: clamp(12px, 4vmin, 18px); padding: 7px 9px; background: #07140ee8; }
              .game-wrap { position: absolute; inset: 0; width: 100%; height: 100%; }
              canvas { border-radius: 18px; }
            }
            @media (orientation: portrait) {
              main { grid-template-columns: 1fr; grid-template-rows: auto minmax(0, 1fr); align-content: stretch; overflow: hidden; gap: 10px; }
              header { grid-template-columns: minmax(0, 1fr) auto; gap: 8px 12px; align-items: start; align-content: start; }
              header > div:first-child { min-width: 0; }
              h1 { font-size: clamp(24px, 7vw, 38px); }
              p { font-size: clamp(12px, 3.4vw, 16px); max-width: none; }
              .score { grid-row: 1 / span 2; grid-column: 2; }
              .bar { grid-column: 1 / -1; margin-top: 0; }
              .game-wrap { width: 100%; height: 100%; min-height: 0; justify-self: stretch; align-self: stretch; }
            }
          </style>
        </head>
        <body>
          <main>
            <header>
              <div>
                <h1>\(title)</h1>
                <p>Arrow keys, WASD, or swipe. Eat, grow, and avoid yourself.</p>
              </div>
              <div class="score">Score <span id="score">0</span></div>
              <div class="bar"><button id="restart">Restart</button><button id="pause">Pause</button></div>
            </header>
            <section class="game-wrap" aria-label="Game board">
              <canvas id="game" width="720" height="720"></canvas>
            </section>
          </main>
          <script>
            const canvas = document.querySelector("#game");
            const ctx = canvas.getContext("2d");
            const scoreEl = document.querySelector("#score");
            let cols = 24, rows = 24, cell = 1, boardX = 0, boardY = 0, pixelRatio = 1, resizeFrame = 0;
            let snake, dir, nextDir, food, score, paused, over, last, acc;
            function resizeCanvas() {
              const rect = canvas.getBoundingClientRect();
              pixelRatio = Math.max(1, Math.min(3, window.devicePixelRatio || 1));
              canvas.width = Math.max(1, Math.floor(rect.width * pixelRatio));
              canvas.height = Math.max(1, Math.floor(rect.height * pixelRatio));
              const targetCell = Math.max(18 * pixelRatio, Math.min(canvas.width / 34, canvas.height / 18));
              cols = Math.max(18, Math.floor(canvas.width / targetCell));
              rows = Math.max(12, Math.floor(canvas.height / targetCell));
              cell = Math.min(canvas.width / cols, canvas.height / rows);
              boardX = (canvas.width - cols * cell) / 2;
              boardY = (canvas.height - rows * cell) / 2;
              ensureSnakeInBounds();
              draw();
            }
            function requestResize() {
              cancelAnimationFrame(resizeFrame);
              resizeFrame = requestAnimationFrame(resizeCanvas);
            }
            function reset() {
              resizeCanvas();
              const midX = Math.floor(cols / 2), midY = Math.floor(rows / 2);
              snake = [{x: midX, y: midY}, {x: midX - 1, y: midY}, {x: midX - 2, y: midY}];
              dir = {x: 1, y: 0}; nextDir = dir; score = 0; paused = false; over = false; last = 0; acc = 0;
              placeFood(); scoreEl.textContent = score; draw();
            }
            function clampCell(value, max) { return Math.max(0, Math.min(max - 1, value)); }
            function ensureSnakeInBounds() {
              if (!Array.isArray(snake) || snake.length === 0) return;
              const seen = new Set();
              snake = snake.map(p => ({x: clampCell(p.x, cols), y: clampCell(p.y, rows)})).filter(p => {
                const key = `${p.x},${p.y}`;
                if (seen.has(key)) return false;
                seen.add(key);
                return true;
              });
              if (!food || food.x < 0 || food.y < 0 || food.x >= cols || food.y >= rows || snake.some(p => p.x === food.x && p.y === food.y)) placeFood();
            }
            function placeFood() {
              for (let attempt = 0; attempt < 200; attempt++) {
                const candidate = {x: Math.floor(Math.random() * cols), y: Math.floor(Math.random() * rows)};
                if (!Array.isArray(snake) || !snake.some(p => p.x === candidate.x && p.y === candidate.y)) { food = candidate; return; }
              }
              food = {x: 0, y: 0};
            }
            function setDir(x, y) { if (dir.x + x !== 0 || dir.y + y !== 0) nextDir = {x, y}; }
            function step() {
              if (paused || over) return;
              dir = nextDir;
              const head = {x: (snake[0].x + dir.x + cols) % cols, y: (snake[0].y + dir.y + rows) % rows};
              if (snake.some(p => p.x === head.x && p.y === head.y)) over = true;
              if (over) return;
              snake.unshift(head);
              if (head.x === food.x && head.y === food.y) { score += 10; scoreEl.textContent = score; placeFood(); } else snake.pop();
            }
            function draw() {
              if (!Array.isArray(snake) || !food) return;
              ctx.clearRect(0, 0, canvas.width, canvas.height);
              ctx.fillStyle = "#07130f"; ctx.fillRect(0, 0, canvas.width, canvas.height);
              ctx.save(); ctx.translate(boardX, boardY);
              const boardW = cols * cell, boardH = rows * cell;
              ctx.fillStyle = "#0b1f17"; ctx.fillRect(0, 0, boardW, boardH);
              ctx.fillStyle = "#ff5f87"; ctx.beginPath(); ctx.arc((food.x + .5) * cell, (food.y + .5) * cell, cell * .32, 0, Math.PI * 2); ctx.fill();
              snake.forEach((p, i) => { ctx.fillStyle = i ? "#4ef2a0" : "#b7ffd3"; roundRect(p.x * cell + 3 * pixelRatio, p.y * cell + 3 * pixelRatio, cell - 6 * pixelRatio, cell - 6 * pixelRatio, 9 * pixelRatio); });
              if (over) { ctx.fillStyle = "#000b"; ctx.fillRect(0, 0, boardW, boardH); ctx.fillStyle = "#effff5"; ctx.font = `800 ${Math.max(30, boardH * .12)}px system-ui`; ctx.textAlign = "center"; ctx.fillText("Game Over", boardW / 2, boardH / 2); }
              ctx.restore();
            }
            function roundRect(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, Math.max(1, w), Math.max(1, h), Math.max(1, r)); ctx.fill(); }
            function loop(t) { acc += t - last; last = t; while (acc > 112) { step(); acc -= 112; } draw(); requestAnimationFrame(loop); }
            addEventListener("keydown", e => { if (e.key === "ArrowUp" || e.key === "w") setDir(0,-1); if (e.key === "ArrowDown" || e.key === "s") setDir(0,1); if (e.key === "ArrowLeft" || e.key === "a") setDir(-1,0); if (e.key === "ArrowRight" || e.key === "d") setDir(1,0); if (e.key === " ") paused = !paused; });
            let start; canvas.addEventListener("touchstart", e => start = e.touches[0], {passive: true}); canvas.addEventListener("touchmove", e => { if (!start) return; const t = e.touches[0], dx = t.clientX - start.clientX, dy = t.clientY - start.clientY; if (Math.max(Math.abs(dx), Math.abs(dy)) < 24) return; e.preventDefault(); Math.abs(dx) > Math.abs(dy) ? setDir(Math.sign(dx), 0) : setDir(0, Math.sign(dy)); start = t; }, {passive: false});
            document.querySelector("#restart").onclick = reset; document.querySelector("#pause").onclick = () => paused = !paused;
            addEventListener("resize", requestResize);
            window.visualViewport?.addEventListener("resize", requestResize);
            document.addEventListener("visibilitychange", requestResize);
            reset(); requestAnimationFrame(loop);
          </script>
        </body>
        </html>
        """
    }
}
