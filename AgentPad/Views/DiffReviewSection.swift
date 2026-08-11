//
//  DiffReviewSection.swift
//  NovaForge
//
//  Inline diff review for file-write approvals: what the workspace looks
//  like after saying yes, before saying yes.
//

import SwiftUI

struct DiffReviewSection: View {
    let diff: FileDiff
    let path: String

    private static let maxRenderedRows = 320

    @ScaledMetric(relativeTo: .caption2) private var lineNumberWidth: CGFloat = 30
    @ScaledMetric(relativeTo: .caption2) private var markerWidth: CGFloat = 14

    private var visibleLines: ArraySlice<FileDiff.Line> {
        diff.lines.prefix(Self.maxRenderedRows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .overlay(AgentPalette.divider)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleLines) { line in
                    row(line)
                }
                if diff.lines.count > Self.maxRenderedRows {
                    footnote("Showing first \(Self.maxRenderedRows) rows")
                }
                if diff.isTruncated {
                    footnote("Large file — diff truncated")
                }
            }
            .padding(.vertical, 4)
        }
        .background(AgentPalette.codeBackground.opacity(0.94), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AgentPalette.glassStroke.opacity(0.5), lineWidth: 0.55)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Change review for \(path): \(diff.insertions) additions, \(diff.deletions) deletions")
        .accessibilityIdentifier("approvalDiffReview")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.forwardslash.minus")
                .font(.caption.weight(.black))
                .foregroundStyle(AgentPalette.cyan)
                .accessibilityHidden(true)
            Text(diff.isNewFile ? "New file" : "Review changes")
                .font(.system(.caption, design: AgentPalette.interfaceFontDesign, weight: .black))
                .foregroundStyle(AgentPalette.ink)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if diff.insertions > 0 {
                Text("+\(diff.insertions)")
                    .font(.system(.caption2, design: .monospaced, weight: .black))
                    .foregroundStyle(AgentPalette.green)
            }
            if diff.deletions > 0 {
                Text("−\(diff.deletions)")
                    .font(.system(.caption2, design: .monospaced, weight: .black))
                    .foregroundStyle(AgentPalette.rose)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func row(_ line: FileDiff.Line) -> some View {
        switch line.kind {
        case .collapsed(let count):
            HStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.caption2.weight(.black))
                    .accessibilityHidden(true)
                Text("\(count) unchanged line\(count == 1 ? "" : "s")")
                    .font(.system(.caption2, design: AgentPalette.interfaceFontDesign, weight: .bold))
            }
            .foregroundStyle(AgentPalette.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) unchanged line\(count == 1 ? "" : "s")")
        case .context, .insertion, .deletion:
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: lineNumberWidth, alignment: .trailing)
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: lineNumberWidth, alignment: .trailing)
                Text(marker(for: line.kind))
                    .frame(width: markerWidth, alignment: .center)
                    .foregroundStyle(markerColor(for: line.kind))
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(textColor(for: line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(AgentPalette.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(rowBackground(for: line.kind))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: line))
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: AgentPalette.interfaceFontDesign, weight: .bold))
            .foregroundStyle(AgentPalette.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 5)
    }

    private func marker(for kind: FileDiff.LineKind) -> String {
        switch kind {
        case .insertion: "+"
        case .deletion: "−"
        default: ""
        }
    }

    private func markerColor(for kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .insertion: AgentPalette.green
        case .deletion: AgentPalette.rose
        default: AgentPalette.tertiaryText
        }
    }

    private func textColor(for kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .insertion, .deletion: AgentPalette.codeText
        default: AgentPalette.codeText.opacity(0.62)
        }
    }

    private func rowBackground(for kind: FileDiff.LineKind) -> Color {
        switch kind {
        case .insertion: AgentPalette.green.opacity(0.13)
        case .deletion: AgentPalette.rose.opacity(0.12)
        default: .clear
        }
    }

    private func accessibilityLabel(for line: FileDiff.Line) -> String {
        let text = line.text.isEmpty ? "blank line" : line.text

        switch line.kind {
        case .insertion:
            return "Added line \(line.newNumber.map(String.init) ?? "unknown"): \(text)"
        case .deletion:
            return "Deleted line \(line.oldNumber.map(String.init) ?? "unknown"): \(text)"
        case .context:
            let number = line.newNumber ?? line.oldNumber
            return "Context line \(number.map(String.init) ?? "unknown"): \(text)"
        case .collapsed(let count):
            return "\(count) unchanged line\(count == 1 ? "" : "s")"
        }
    }
}
