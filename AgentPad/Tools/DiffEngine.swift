//
//  DiffEngine.swift
//  NovaForge
//
//  Line diff for file-write approvals: LCS-based, bounded, with unchanged
//  runs collapsed so the approval sheet shows exactly what changes.
//

import Foundation

struct FileDiff: Equatable {
    enum LineKind: Equatable {
        case context
        case insertion
        case deletion
        case collapsed(count: Int)
    }

    struct Line: Identifiable, Equatable {
        let id: Int
        let kind: LineKind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?
    }

    let lines: [Line]
    let insertions: Int
    let deletions: Int
    let isNewFile: Bool
    let isTruncated: Bool

    var isEmpty: Bool { insertions == 0 && deletions == 0 }

    var badge: String {
        var parts: [String] = []
        if insertions > 0 { parts.append("+\(insertions)") }
        if deletions > 0 { parts.append("−\(deletions)") }
        return parts.isEmpty ? "no changes" : parts.joined(separator: " ")
    }
}

enum DiffEngine {

    /// Maximum lines per side fed to the LCS table. Beyond this the diff is
    /// truncated (approvals for generated files can be huge; the sheet only
    /// needs to communicate the shape of the change).
    static let maxDiffableLines = 1_200

    /// Unchanged runs longer than this collapse to a "⋯ N unchanged" row.
    static let contextRadius = 2

    static func diff(old: String?, new: String) -> FileDiff {
        let isNewFile = old == nil
        var oldLines = (old ?? "").isEmpty ? [] : (old ?? "").components(separatedBy: "\n")
        var newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var truncated = false
        if oldLines.count > maxDiffableLines {
            oldLines = Array(oldLines.prefix(maxDiffableLines))
            truncated = true
        }
        if newLines.count > maxDiffableLines {
            newLines = Array(newLines.prefix(maxDiffableLines))
            truncated = true
        }

        let ops = lcsOps(oldLines, newLines)
        var raw: [FileDiff.Line] = []
        raw.reserveCapacity(ops.count)
        var oldNum = 0
        var newNum = 0
        var insertions = 0
        var deletions = 0
        var nextID = 0

        for op in ops {
            switch op {
            case .keep(let text):
                oldNum += 1; newNum += 1
                raw.append(FileDiff.Line(id: nextID, kind: .context, text: text, oldNumber: oldNum, newNumber: newNum))
            case .delete(let text):
                oldNum += 1; deletions += 1
                raw.append(FileDiff.Line(id: nextID, kind: .deletion, text: text, oldNumber: oldNum, newNumber: nil))
            case .insert(let text):
                newNum += 1; insertions += 1
                raw.append(FileDiff.Line(id: nextID, kind: .insertion, text: text, oldNumber: nil, newNumber: newNum))
            }
            nextID += 1
        }

        return FileDiff(
            lines: collapseContext(raw, radius: contextRadius, totalChanges: insertions + deletions),
            insertions: insertions,
            deletions: deletions,
            isNewFile: isNewFile,
            isTruncated: truncated
        )
    }

    /// Derives the post-approval content for a mutating file tool, so the
    /// sheet can preview it. Returns nil when the tool doesn't map to a
    /// deterministic content change.
    static func proposedContent(toolName: String, arguments: [String: String], existing: String?) -> String? {
        switch toolName {
        case "write_file":
            return arguments["contents"] ?? arguments["content"]
        case "append_file":
            guard let addition = arguments["contents"] ?? arguments["content"] else { return nil }
            guard let existing, !existing.isEmpty else { return addition }
            return existing.hasSuffix("\n") ? existing + addition : existing + "\n" + addition
        case "replace_text":
            guard let find = arguments["find"] ?? arguments["search"],
                  let replacement = arguments["replace"] ?? arguments["replacement"],
                  let existing, !find.isEmpty else { return nil }
            guard existing.contains(find) else { return nil }
            return existing.replacingOccurrences(of: find, with: replacement)
        default:
            return nil
        }
    }

    // MARK: - LCS

    private enum Op {
        case keep(String)
        case delete(String)
        case insert(String)
    }

    private static func lcsOps(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count
        let m = b.count
        if n == 0 { return b.map { .insert($0) } }
        if m == 0 { return a.map { .delete($0) } }

        // Trim common prefix/suffix first — typical file edits touch a small
        // region, and this collapses the DP table dramatically.
        var start = 0
        while start < n, start < m, a[start] == b[start] { start += 1 }
        var endA = n
        var endB = m
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
            endA -= 1; endB -= 1
        }

        let coreA = Array(a[start..<endA])
        let coreB = Array(b[start..<endB])
        var ops: [Op] = a[0..<start].map { .keep($0) }

        if !coreA.isEmpty || !coreB.isEmpty {
            let ca = coreA.count
            let cb = coreB.count
            var table = [Int](repeating: 0, count: (ca + 1) * (cb + 1))
            @inline(__always) func idx(_ i: Int, _ j: Int) -> Int { i * (cb + 1) + j }
            if ca > 0, cb > 0 {
                for i in stride(from: ca - 1, through: 0, by: -1) {
                    for j in stride(from: cb - 1, through: 0, by: -1) {
                        table[idx(i, j)] = coreA[i] == coreB[j]
                            ? table[idx(i + 1, j + 1)] + 1
                            : max(table[idx(i + 1, j)], table[idx(i, j + 1)])
                    }
                }
            }
            var i = 0
            var j = 0
            while i < ca, j < cb {
                if coreA[i] == coreB[j] {
                    ops.append(.keep(coreA[i])); i += 1; j += 1
                } else if table[idx(i + 1, j)] >= table[idx(i, j + 1)] {
                    ops.append(.delete(coreA[i])); i += 1
                } else {
                    ops.append(.insert(coreB[j])); j += 1
                }
            }
            while i < ca { ops.append(.delete(coreA[i])); i += 1 }
            while j < cb { ops.append(.insert(coreB[j])); j += 1 }
        }

        ops.append(contentsOf: a[endA..<n].map { .keep($0) })
        return ops
    }

    // MARK: - Context collapsing

    private static func collapseContext(_ lines: [FileDiff.Line], radius: Int, totalChanges: Int) -> [FileDiff.Line] {
        guard totalChanges > 0 else {
            // No changes: single collapsed row keeps the sheet honest.
            if lines.isEmpty { return [] }
            return [FileDiff.Line(id: -1, kind: .collapsed(count: lines.count), text: "", oldNumber: nil, newNumber: nil)]
        }

        var keep = [Bool](repeating: false, count: lines.count)
        for (i, line) in lines.enumerated() where line.kind != .context {
            let lower = max(0, i - radius)
            let upper = min(lines.count - 1, i + radius)
            for k in lower...upper { keep[k] = true }
        }

        var result: [FileDiff.Line] = []
        var syntheticID = -1
        var i = 0
        while i < lines.count {
            if keep[i] {
                result.append(lines[i])
                i += 1
            } else {
                var run = 0
                let runStart = i
                while i < lines.count, !keep[i] { run += 1; i += 1 }
                if run <= 2 {
                    // Collapsing 1-2 lines reads worse than showing them.
                    result.append(contentsOf: lines[runStart..<runStart + run])
                } else {
                    result.append(FileDiff.Line(id: syntheticID, kind: .collapsed(count: run), text: "", oldNumber: nil, newNumber: nil))
                    syntheticID -= 1
                }
            }
        }
        return result
    }
}
