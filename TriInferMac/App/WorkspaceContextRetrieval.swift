import Foundation

extension WorkspaceManager {
    /// Builds a compact, deterministic code context pack without invoking another model.
    /// It favors exact path/name matches, declarations/imports, call sites, branches, and
    /// small neighborhoods around lexical hits. Every excerpt keeps path:line provenance
    /// so the agent can request the full source through `read` before editing.
    func contextPack(for query: String, maxCharacters: Int = 7_200) throws -> String {
        let terms = Self.contextTerms(query)
        let allEntries = try entries()
        let files = allEntries.filter { !$0.isDirectory && $0.size > 0 && $0.size <= 768_000 }

        struct Slice {
            var path: String
            var line: Int
            var score: Int
            var text: String
        }

        var rankedFiles: [(Entry, Int)] = []
        rankedFiles.reserveCapacity(files.count)
        for entry in files {
            let lowerPath = entry.relativePath.lowercased()
            var score = Self.languagePriority(lowerPath)
            for term in terms {
                if lowerPath == term { score += 80 }
                if lowerPath.contains(term) { score += 32 }
                if entry.name.lowercased().contains(term) { score += 28 }
            }
            rankedFiles.append((entry, score))
        }
        rankedFiles.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.relativePath.localizedStandardCompare($1.0.relativePath) == .orderedAscending
        }

        var slices: [Slice] = []
        var seen = Set<String>()

        for (entry, pathScore) in rankedFiles.prefix(42) {
            guard let source = try? read(entry.relativePath, maxBytes: 768_000) else { continue }
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard !lines.isEmpty else { continue }

            for index in lines.indices {
                let line = lines[index]
                let lower = line.lowercased()
                let structural = Self.structuralScore(line)
                var lexical = 0
                for term in terms where lower.contains(term) { lexical += 18 }
                guard lexical > 0 || (pathScore > 10 && structural > 0) else { continue }

                let score = pathScore + lexical + structural
                let start = max(0, index - (lexical > 0 ? 2 : 0))
                let end = min(lines.count - 1, index + (lexical > 0 ? 3 : 0))
                let key = "\(entry.relativePath):\(start):\(end)"
                guard seen.insert(key).inserted else { continue }

                var excerpt: [String] = []
                for lineIndex in start...end {
                    excerpt.append("\(lineIndex + 1)│ \(String(lines[lineIndex].prefix(360)))")
                }
                slices.append(.init(path: entry.relativePath, line: index + 1, score: score, text: excerpt.joined(separator: "\n")))
            }
        }

        slices.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.line < $1.line
        }

        let tree = allEntries.prefix(96).map { ($0.isDirectory ? "[dir] " : "") + $0.relativePath }.joined(separator: "\n")
        var output = "PROJECT MAP\n" + tree
        if !slices.isEmpty { output += "\n\nSTRUCTURAL CODE SLICES" }

        for slice in slices.prefix(24) {
            let block = "\n\n[\(slice.path):\(slice.line)]\n\(slice.text)"
            if output.count + block.count > maxCharacters {
                let remaining = max(0, maxCharacters - output.count)
                if remaining > 80 { output += String(block.prefix(remaining)) }
                break
            }
            output += block
        }

        if output.count > maxCharacters { output = String(output.prefix(maxCharacters)) }
        return output
    }

    private static func contextTerms(_ text: String) -> [String] {
        var seen = Set<String>()
        let stop: Set<String> = [
            "this", "that", "with", "from", "into", "then", "than", "have", "make", "build",
            "code", "file", "project", "please", "need", "want", "when", "where", "what", "using"
        ]
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" && $0 != "." && $0 != "/" }
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) && seen.insert($0).inserted }
            .prefix(10)
            .map { $0 }
    }

    private static func languagePriority(_ path: String) -> Int {
        if path.hasSuffix(".swift") || path.hasSuffix(".js") || path.hasSuffix(".ts") || path.hasSuffix(".tsx") || path.hasSuffix(".jsx") { return 9 }
        if path.hasSuffix(".html") || path.hasSuffix(".css") || path.hasSuffix(".json") || path.hasSuffix(".md") { return 6 }
        return 1
    }

    private static func structuralScore(_ line: String) -> Int {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return 0 }
        let lower = t.lowercased()

        let declarationPrefixes = [
            "func ", "class ", "struct ", "enum ", "protocol ", "actor ", "extension ",
            "function ", "export function ", "export class ", "export const ", "const ", "let ", "var ",
            "import ", "export ", "type ", "interface "
        ]
        if declarationPrefixes.contains(where: { lower.hasPrefix($0) }) { return 16 }
        if lower.contains("=>") || lower.contains(" addEventListener".lowercased()) { return 11 }
        if lower.hasPrefix("if ") || lower.hasPrefix("if(") || lower.hasPrefix("guard ") || lower.hasPrefix("switch ") || lower.hasPrefix("for ") || lower.hasPrefix("while ") { return 8 }
        if lower.contains("<script") || lower.contains("<link") || lower.contains(" id=") || lower.contains(" class=") { return 9 }
        if lower.hasPrefix("@") || lower.contains("async ") || lower.contains("await ") || lower.contains("throw") { return 6 }
        return 0
    }
}
