//
//  CodeHighlighter.swift
//  NovaForge
//
//  Fast, dependency-free syntax highlighting for chat code blocks.
//  One regex pass per token class over the whole block, claims tracked in a
//  UTF-16 mask so comments beat strings beat keywords. Results cache by
//  (theme, language, content) so scroll re-renders are free.
//

import Foundation
import SwiftUI

enum CodeSyntaxHighlighter {

    // MARK: - Public

    /// Returns an attributed rendering of `code`. Falls back to plain text
    /// for unknown languages or oversized blocks so cost stays bounded.
    static func highlighted(_ code: String, language: String?) -> AttributedString {
        guard code.utf16.count <= maxHighlightableUTF16 else {
            return AttributedString(code)
        }
        let family = LanguageFamily(alias: language)
        guard family != .plain else {
            return AttributedString(code)
        }

        let key = cacheKey(code: code, family: family)
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let rendered = render(code, family: family)

        cacheLock.lock()
        if cache.count >= maxCacheEntries {
            // Wholesale reset beats LRU bookkeeping here: the cache refills in
            // a handful of frames and the hot path stays branch-light.
            cache.removeAll(keepingCapacity: true)
            cacheOrder.removeAll(keepingCapacity: true)
        }
        cache[key] = rendered
        cacheOrder.append(key)
        cacheLock.unlock()
        return rendered
    }

    /// Theme switches invalidate every cached run (colors are baked in).
    static func themeDidChange() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        cacheLock.unlock()
    }

    // MARK: - Language families

    private enum LanguageFamily: String {
        case swift, cLike, python, script, json, markup, css, sql, plain

        init(alias raw: String?) {
            switch (raw ?? "").lowercased() {
            case "swift":
                self = .swift
            case "js", "jsx", "javascript", "ts", "tsx", "typescript",
                 "java", "kotlin", "kt", "c", "cpp", "c++", "objc",
                 "objective-c", "objectivec", "rust", "rs", "go", "golang",
                 "scala", "dart", "cs", "csharp", "php":
                self = .cLike
            case "py", "python", "python3":
                self = .python
            case "sh", "bash", "zsh", "shell", "console", "terminal",
                 "ruby", "rb", "perl", "yaml", "yml", "toml", "ini",
                 "dockerfile", "makefile":
                self = .script
            case "json", "jsonc":
                self = .json
            case "html", "htm", "xml", "svg", "plist":
                self = .markup
            case "css", "scss", "less":
                self = .css
            case "sql", "sqlite", "postgres", "mysql":
                self = .sql
            default:
                self = .plain
            }
        }

        var lineComment: String? {
            switch self {
            case .swift, .cLike, .css: return "//"
            case .python, .script: return "#"
            case .sql: return "--"
            case .json, .markup, .plain: return nil
            }
        }

        var hasBlockComments: Bool {
            switch self {
            case .swift, .cLike, .css: return true
            case .markup: return true // <!-- -->
            default: return false
            }
        }

        var keywords: Set<String> {
            switch self {
            case .swift:
                return ["func", "let", "var", "if", "else", "guard", "return", "struct",
                        "class", "enum", "extension", "protocol", "actor", "import",
                        "private", "fileprivate", "internal", "public", "static", "final",
                        "case", "switch", "default", "for", "while", "repeat", "in", "where",
                        "do", "try", "catch", "throw", "throws", "async", "await", "defer",
                        "init", "deinit", "self", "Self", "super", "nil", "true", "false",
                        "some", "any", "typealias", "associatedtype", "mutating",
                        "nonisolated", "lazy", "weak", "unowned", "override", "required",
                        "convenience", "subscript", "willSet", "didSet", "get", "set",
                        "break", "continue", "fallthrough", "as", "is", "inout"]
            case .cLike:
                return ["function", "const", "let", "var", "if", "else", "return", "class",
                        "struct", "enum", "interface", "import", "export", "from", "public",
                        "private", "protected", "static", "final", "void", "int", "long",
                        "double", "float", "bool", "boolean", "char", "new", "delete",
                        "for", "while", "do", "switch", "case", "default", "break",
                        "continue", "try", "catch", "finally", "throw", "throws", "async",
                        "await", "yield", "this", "super", "null", "nil", "undefined",
                        "true", "false", "typeof", "instanceof", "in", "of", "extends",
                        "implements", "abstract", "override", "fn", "impl", "pub", "mut",
                        "match", "loop", "mod", "use", "crate", "go", "chan", "defer",
                        "package", "type", "map", "range", "func"]
            case .python:
                return ["def", "class", "import", "from", "as", "if", "elif", "else",
                        "return", "yield", "for", "while", "in", "not", "and", "or",
                        "is", "None", "True", "False", "try", "except", "finally",
                        "raise", "with", "lambda", "pass", "break", "continue", "global",
                        "nonlocal", "assert", "del", "async", "await", "match", "case"]
            case .script:
                return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done",
                        "case", "esac", "function", "return", "local", "export", "source",
                        "echo", "exit", "set", "shift", "true", "false", "in", "def",
                        "end", "require", "module", "begin", "rescue", "ensure", "puts"]
            case .json:
                return ["true", "false", "null"]
            case .sql:
                return ["select", "from", "where", "insert", "into", "values", "update",
                        "set", "delete", "create", "table", "index", "drop", "alter",
                        "join", "left", "right", "inner", "outer", "on", "group", "by",
                        "order", "having", "limit", "offset", "union", "all", "distinct",
                        "as", "and", "or", "not", "null", "primary", "key", "foreign",
                        "references", "SELECT", "FROM", "WHERE", "INSERT", "INTO",
                        "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "JOIN",
                        "LEFT", "RIGHT", "INNER", "ON", "GROUP", "BY", "ORDER", "HAVING",
                        "LIMIT", "AND", "OR", "NOT", "NULL", "AS"]
            case .markup, .css, .plain:
                return []
            }
        }

        var highlightsTypes: Bool {
            switch self {
            case .swift, .cLike: return true
            default: return false
            }
        }
    }

    // MARK: - Rendering

    private static func render(_ code: String, family: LanguageFamily) -> AttributedString {
        var attributed = AttributedString(code)
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)
        var claimed = [Bool](repeating: false, count: ns.length)

        func colorize(_ r: NSRange, _ color: Color) {
            guard let sr = Range(r, in: code),
                  let lower = AttributedString.Index(sr.lowerBound, within: attributed),
                  let upper = AttributedString.Index(sr.upperBound, within: attributed),
                  lower < upper else { return }
            attributed[lower..<upper].foregroundColor = color
        }

        func apply(_ regex: NSRegularExpression?, color: Color) {
            guard let regex else { return }
            regex.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let match else { return }
                let r = match.range
                guard r.location != NSNotFound, r.length > 0 else { return }
                // skip if already claimed by a higher-priority class
                if claimed[r.location] { return }
                colorize(r, color)
                for i in r.location..<min(r.location + r.length, claimed.count) {
                    claimed[i] = true
                }
            }
        }

        // 1. Comments (highest priority)
        if family.hasBlockComments {
            apply(Self.regexBlockComment(for: family), color: AgentPalette.codeComment)
        }
        if let marker = family.lineComment {
            apply(Self.regexLineComment(marker: marker), color: AgentPalette.codeComment)
        }

        // 2. Strings
        apply(Self.regexString, color: AgentPalette.codeString)

        // 3. Numbers
        apply(Self.regexNumber, color: AgentPalette.codeCursor)

        // 4. Keywords
        let keywords = family.keywords
        if !keywords.isEmpty {
            Self.regexWord?.enumerateMatches(in: code, options: [], range: full) { match, _, _ in
                guard let match else { return }
                let r = match.range
                guard r.location != NSNotFound, !claimed[r.location] else { return }
                let word = ns.substring(with: r)
                let isKeyword = keywords.contains(word)
                let isType = !isKeyword && family.highlightsTypes
                    && word.first?.isUppercase == true && word.count > 1
                guard isKeyword || isType else { return }
                colorize(r, isKeyword ? AgentPalette.codeKeyword : AgentPalette.codeType)
                for i in r.location..<min(r.location + r.length, claimed.count) {
                    claimed[i] = true
                }
            }
        }

        return attributed
    }

    // MARK: - Regexes (compiled once)

    private static let regexString: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\"\"\"[\\s\\S]*?\"\"\"|\"(?:[^\"\\\\\\n]|\\\\.)*\"|'(?:[^'\\\\\\n]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`")

    private static let regexNumber: NSRegularExpression? =
        try? NSRegularExpression(pattern: "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.[\\d_]+)?(?:[eE][+-]?\\d+)?)\\b")

    private static let regexWord: NSRegularExpression? =
        try? NSRegularExpression(pattern: "[A-Za-z_][A-Za-z0-9_]*")

    nonisolated(unsafe) private static var blockCommentCache: [String: NSRegularExpression] = [:]

    private static func regexBlockComment(for family: LanguageFamily) -> NSRegularExpression? {
        let pattern = family == .markup ? "<!--[\\s\\S]*?-->" : "/\\*[\\s\\S]*?\\*/"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = blockCommentCache[pattern] { return hit }
        let rx = try? NSRegularExpression(pattern: pattern)
        if let rx { blockCommentCache[pattern] = rx }
        return rx
    }

    nonisolated(unsafe) private static var lineCommentCache: [String: NSRegularExpression] = [:]

    private static func regexLineComment(marker: String) -> NSRegularExpression? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let hit = lineCommentCache[marker] { return hit }
        let escaped = NSRegularExpression.escapedPattern(for: marker)
        let rx = try? NSRegularExpression(pattern: escaped + "[^\\n]*")
        if let rx { lineCommentCache[marker] = rx }
        return rx
    }

    // MARK: - Cache

    private static let maxHighlightableUTF16 = 30_000
    private static let maxCacheEntries = 96
    nonisolated(unsafe) private static var cache: [String: AttributedString] = [:]
    nonisolated(unsafe) private static var cacheOrder: [String] = []
    private static let cacheLock = NSLock()

    private static func cacheKey(code: String, family: LanguageFamily) -> String {
        "\(AgentTheme.current.rawValue)|\(family.rawValue)|\(code.count)|\(code.hashValue)"
    }
}
