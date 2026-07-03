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
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
            Text(diff.isNewFile ? "New file" : "Review changes")
                .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            if diff.insertions > 0 {
                Text("+\(diff.insertions)")
                    .font(.system(size: 10.5, weight: .black, design: .monospaced))
                    .foregroundStyle(AgentPalette.green)
            }
            if diff.deletions > 0 {
                Text("−\(diff.deletions)")
                    .font(.system(size: 10.5, weight: .black, design: .monospaced))
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
                    .font(.system(size: 8, weight: .black))
                Text("\(count) unchanged line\(count == 1 ? "" : "s")")
                    .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
            }
            .foregroundStyle(AgentPalette.tertiaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 3)
        case .context, .insertion, .deletion:
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldNumber.map(String.init) ?? "")
                    .frame(width: 30, alignment: .trailing)
                Text(line.newNumber.map(String.init) ?? "")
                    .frame(width: 30, alignment: .trailing)
                Text(marker(for: line.kind))
                    .frame(width: 14, alignment: .center)
                    .foregroundStyle(markerColor(for: line.kind))
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(textColor(for: line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(AgentPalette.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(rowBackground(for: line.kind))
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
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
}
