import Foundation

extension WorkspaceManager {
    /// Static integrity check for modular browser projects. It verifies index.html, local HTML
    /// scripts/styles/assets, JS module imports, and CSS url() references without executing
    /// untrusted workspace code inside the agent process.
    func validateBrowserProject() throws -> String {
        let all = try entries()
        let files = Set(all.filter { !$0.isDirectory }.map(\.relativePath))
        guard files.contains("index.html") else {
            return "FAIL: index.html is missing. A browser artifact needs an entry document."
        }

        struct Reference: Hashable {
            let source: String
            let target: String
            let kind: String
        }

        var refs: [Reference] = []
        var parseWarnings: [String] = []

        for entry in all where !entry.isDirectory && entry.size <= 1_000_000 {
            let lower = entry.relativePath.lowercased()
            guard lower.hasSuffix(".html") || lower.hasSuffix(".js") || lower.hasSuffix(".mjs") || lower.hasSuffix(".css") else { continue }
            guard let text = try? read(entry.relativePath, maxBytes: 1_000_000) else { continue }

            if lower.hasSuffix(".html") {
                refs += references(
                    pattern: #"(?:src|href)\s*=\s*[\"']([^\"'#]+)[\"']"#,
                    text: text,
                    source: entry.relativePath,
                    kind: "HTML asset"
                )
            }
            if lower.hasSuffix(".js") || lower.hasSuffix(".mjs") {
                refs += references(
                    pattern: #"(?:from\s+|import\s*\()\s*[\"']([^\"']+)[\"']"#,
                    text: text,
                    source: entry.relativePath,
                    kind: "JS module"
                )
                if text.contains("import ") && !text.contains("from ") && !text.contains("import(") && !text.contains("import '") && !text.contains("import \"") {
                    parseWarnings.append("\(entry.relativePath): contains import syntax that the static validator could not fully classify.")
                }
            }
            if lower.hasSuffix(".css") {
                refs += references(
                    pattern: #"url\(\s*[\"']?([^\"')]+)[\"']?\s*\)"#,
                    text: text,
                    source: entry.relativePath,
                    kind: "CSS asset"
                )
            }
        }

        var missing: [String] = []
        var invalid: [String] = []
        var checked = 0
        for ref in Set(refs) {
            guard let resolved = normalizedLocalReference(ref.target, relativeTo: ref.source) else { continue }
            checked += 1
            if resolved.hasPrefix("../") || resolved == ".." || resolved.hasPrefix("/") {
                invalid.append("\(ref.source) → \(ref.target) escapes the project root")
            } else if !files.contains(resolved) {
                missing.append("\(ref.source) → \(resolved) (\(ref.kind))")
            }
        }

        let htmlCount = files.filter { $0.lowercased().hasSuffix(".html") }.count
        let jsCount = files.filter { $0.lowercased().hasSuffix(".js") || $0.lowercased().hasSuffix(".mjs") }.count
        let cssCount = files.filter { $0.lowercased().hasSuffix(".css") }.count
        let assetCount = max(0, files.count - htmlCount - jsCount - cssCount)

        if !invalid.isEmpty || !missing.isEmpty {
            var output = "FAIL: browser project integrity check found problems."
            if !invalid.isEmpty { output += "\nEscaping references:\n" + invalid.prefix(20).map { "- \($0)" }.joined(separator: "\n") }
            if !missing.isEmpty { output += "\nMissing local references:\n" + missing.prefix(30).map { "- \($0)" }.joined(separator: "\n") }
            if !parseWarnings.isEmpty { output += "\nWarnings:\n" + parseWarnings.prefix(10).map { "- \($0)" }.joined(separator: "\n") }
            return output
        }

        var output = "PASS: modular browser project references are internally consistent."
        output += "\nFiles: \(files.count) • HTML: \(htmlCount) • JS modules: \(jsCount) • CSS: \(cssCount) • other/assets: \(assetCount) • local references checked: \(checked)."
        if !parseWarnings.isEmpty { output += "\nWarnings:\n" + parseWarnings.prefix(10).map { "- \($0)" }.joined(separator: "\n") }
        output += "\nThis is a static integrity gate; use the in-app WebKit Preview for runtime rendering/interaction validation."
        return output
    }

    private func references(pattern: String, text: String, source: String, kind: String) -> [ReferenceShim] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
            let value = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return ReferenceShim(source: source, target: value, kind: kind)
        }
    }

    private struct ReferenceShim: Hashable {
        let source: String
        let target: String
        let kind: String
    }

    private func normalizedLocalReference(_ raw: String, relativeTo source: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") || lower.hasPrefix("blob:") || lower.hasPrefix("mailto:") || lower.hasPrefix("javascript:") || lower.hasPrefix("#") { return nil }
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        guard !value.isEmpty else { return nil }

        let sourceDir = (source as NSString).deletingLastPathComponent
        let joined = sourceDir.isEmpty ? value : (sourceDir as NSString).appendingPathComponent(value)
        return (joined as NSString).standardizingPath.replacingOccurrences(of: "\\", with: "/")
    }
}
