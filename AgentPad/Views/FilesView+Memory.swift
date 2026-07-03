//
//  FilesView+Memory.swift
//  NovaForge
//
//  Project Memory workbench: grouped workspace intelligence, inspector,
//  memory rows.
//

import SwiftData
import SwiftUI
import UIKit

extension FilesView {
    var projectMemoryWorkbench: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project Memory")
                        .font(NovaType.title)
                        .foregroundStyle(AgentPalette.ink)
                    Text(projectMemorySubtitle)
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if memoryIsStale {
                    Label("Stale", systemImage: "clock.badge.exclamationmark")
                        .novaLabel(AgentPalette.warning)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .agentControlSurface(radius: 8, tint: AgentPalette.warning.opacity(0.12), selected: true)
                }
            }

            memoryMetricsRow
            workbenchLensBar

            if projectMemoryItems.isEmpty {
                AgentInlineStateView(
                    title: "No project memory yet",
                    detail: "Artifacts, screenshots, verification proof, and changed files will appear here as work lands.",
                    symbol: "tray",
                    tint: AgentPalette.secondaryText
                )
            } else if filteredProjectMemoryItems.isEmpty {
                AgentInlineStateView(
                    title: "No \(selectedWorkbenchLens.title.lowercased()) evidence",
                    detail: "Switch filters or create new proof from Chat.",
                    symbol: selectedWorkbenchLens.symbol,
                    tint: selectedWorkbenchLens.tint
                )
            } else {
                if let selectedMemoryItem {
                    memoryInspector(for: selectedMemoryItem)
                }

                if !artifactGalleryItems.isEmpty {
                    artifactGallery
                }

                memorySectionsList
            }
        }
        .padding(14)
        .agentSurface(radius: 22, tint: AgentPalette.green.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filesProjectMemoryWorkbench")
    }

    var projectMemorySubtitle: String {
        if projectMemoryItems.isEmpty {
            return "Waiting for generated outputs and file evidence"
        }
        var parts: [String] = []
        if changedFileCount > 0 { parts.append("\(changedFileCount) change\(changedFileCount == 1 ? "" : "s")") }
        if artifactCount > 0 { parts.append("\(artifactCount) artifact\(artifactCount == 1 ? "" : "s")") }
        if verificationCount > 0 { parts.append("\(verificationCount) proof item\(verificationCount == 1 ? "" : "s")") }
        if riskCount > 0 { parts.append("\(riskCount) needs review") }
        return parts.isEmpty ? "\(projectMemoryItems.count) workspace item\(projectMemoryItems.count == 1 ? "" : "s")" : parts.joined(separator: " · ")
    }

    var memoryMetricsRow: some View {
        NovaTelemetryStrip(items: [
            NovaTelemetryItem("Changes", "\(changedFileCount)", tint: AgentPalette.cyan),
            NovaTelemetryItem("Artifacts", "\(artifactCount)", tint: AgentPalette.green),
            NovaTelemetryItem("Proof", "\(verificationCount)", tint: AgentPalette.lilac),
            NovaTelemetryItem("Risk", "\(riskCount)", tint: AgentPalette.warning)
        ], compact: true)
        .padding(.vertical, 2)
    }

    var workbenchLensBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(FileWorkbenchLens.allCases) { lens in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        workbenchLensRawValue = lens.rawValue
                    } label: {
                        Label(lens.title, systemImage: lens.symbol)
                            .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .lineLimit(1)
                            .foregroundStyle(selectedWorkbenchLens == lens ? AgentPalette.ink : AgentPalette.secondaryText)
                            .padding(.horizontal, 9)
                            .frame(height: 34)
                            .agentControlSurface(
                                radius: 11,
                                tint: lens.tint.opacity(selectedWorkbenchLens == lens ? 0.15 : 0.06),
                                selected: selectedWorkbenchLens == lens
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filesMemoryLens-\(lens.rawValue)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    func memoryInspector(for item: ProjectMemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(item.tint)
                    .frame(width: 34, height: 34)
                    .agentControlSurface(radius: 12, tint: item.tint.opacity(0.12), selected: true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(AgentPalette.warning)
                        }
                        if item.isImportant {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .black))
                                .foregroundStyle(AgentPalette.warning)
                        }
                    }

                    Text(item.primaryPath)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Label(item.risk.title, systemImage: item.risk.symbol)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(item.risk.tint)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .agentControlSurface(radius: 8, tint: item.risk.tint.opacity(0.12), selected: true)
            }

            inspectorModePicker

            if selectedInspectorMode == .details {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    memoryMetadataCell(title: "Type", value: item.group.title, symbol: item.group.symbol, tint: item.group.tint)
                    memoryMetadataCell(title: "Status", value: item.status, symbol: "waveform.path.ecg", tint: item.tint)
                    memoryMetadataCell(title: "Updated", value: item.timestampText, symbol: "clock.fill", tint: AgentPalette.lilac)
                    memoryMetadataCell(title: "Origin", value: item.origin, symbol: "point.3.connected.trianglepath.dotted", tint: AgentPalette.cyan)
                    memoryMetadataCell(title: "Size", value: item.sizeText ?? "Unknown", symbol: "internaldrive.fill", tint: AgentPalette.storageAccent)
                    memoryMetadataCell(title: "Path", value: item.primaryPath, symbol: "folder.fill", tint: AgentPalette.secondaryText)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    AgentInlineStateView(
                        title: item.status,
                        detail: item.detail,
                        symbol: item.risk.symbol,
                        tint: item.risk.tint
                    )
                    HStack(spacing: 8) {
                        memoryTag("Risk \(item.risk.title)", symbol: item.risk.symbol, tint: item.risk.tint)
                        if item.hasRelatedContext {
                            memoryTag("Linked Run", symbol: "point.3.connected.trianglepath.dotted", tint: AgentPalette.cyan)
                        }
                        if item.comparisonPaths != nil {
                            memoryTag("Comparable", symbol: "arrow.left.arrow.right", tint: AgentPalette.lilac)
                        }
                    }
                }
            }

            memoryQuickActions(for: item)
        }
        .padding(12)
        .agentSurface(radius: 18, tint: item.tint.opacity(0.06))
        .accessibilityIdentifier("filesMemoryInspector")
    }

    var inspectorModePicker: some View {
        HStack(spacing: 7) {
            ForEach(FileInspectorMode.allCases) { mode in
                Button {
                    inspectorModeRawValue = mode.rawValue
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .foregroundStyle(selectedInspectorMode == mode ? AgentPalette.ink : AgentPalette.secondaryText)
                        .agentControlSurface(
                            radius: 11,
                            tint: AgentPalette.cyan.opacity(selectedInspectorMode == mode ? 0.14 : 0.05),
                            selected: selectedInspectorMode == mode
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filesInspectorMode-\(mode.rawValue)")
            }
        }
    }

    func memoryMetadataCell(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(AgentPalette.surfaceAlt.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func memoryQuickActions(for item: ProjectMemoryItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                memoryActionButton(title: primaryActionTitle(for: item), symbol: primaryActionSymbol(for: item), tint: item.tint) {
                    openMemoryItem(item)
                }

                memoryActionButton(title: "Copy Path", symbol: "doc.on.doc.fill", tint: AgentPalette.cyan) {
                    copyMemoryPath(item)
                }

                if item.hasRelatedContext {
                    memoryActionButton(title: "Related Run", symbol: "point.3.connected.trianglepath.dotted", tint: AgentPalette.lilac) {
                        revealRelatedContext(for: item)
                    }
                }

                if item.comparisonPaths != nil {
                    memoryActionButton(title: "Compare", symbol: "arrow.left.arrow.right", tint: AgentPalette.lilac) {
                        compareMemoryItem(item)
                    }
                }

                memoryActionButton(title: item.isImportant ? "Unmark" : "Important", symbol: item.isImportant ? "star.slash.fill" : "star.fill", tint: AgentPalette.warning) {
                    toggleImportant(item)
                }

                memoryActionButton(title: item.isPinned ? "Unpin" : "Pin", symbol: item.isPinned ? "pin.slash.fill" : "pin.fill", tint: AgentPalette.warning) {
                    togglePinned(item)
                }

                memoryActionButton(title: "Brief", symbol: "text.badge.plus", tint: AgentPalette.green) {
                    addToProjectBrief(item)
                }

                memoryActionButton(title: "Chat", symbol: "bubble.left.and.bubble.right.fill", tint: AgentPalette.cyan) {
                    openChat()
                }
            }
            .padding(.vertical, 1)
        }
    }

    func memoryActionButton(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .padding(.horizontal, 9)
                .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: 34)
                .agentControlSurface(radius: 11, tint: tint.opacity(0.10), selected: true)
        }
        .buttonStyle(.plain)
    }

    var artifactGallery: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(AgentPalette.green)
                Text("Artifact Gallery")
                    .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Spacer(minLength: 0)
                Text("\(artifactGalleryItems.count)")
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 8)], spacing: 8) {
                ForEach(artifactGalleryItems) { item in
                    projectMemoryGalleryCard(item)
                }
            }
        }
        .padding(10)
        .background(AgentPalette.surfaceAlt.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("filesArtifactGallery")
    }

    func projectMemoryGalleryCard(_ item: ProjectMemoryItem) -> some View {
        Button {
            selectedMemoryItemID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(item.tint)
                        .frame(width: 30, height: 30)
                        .agentControlSurface(radius: 10, tint: item.tint.opacity(0.12), selected: true)
                    Spacer(minLength: 0)
                    if item.isFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(AgentPalette.rose)
                    } else if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(AgentPalette.warning)
                    }
                }

                Text(item.title)
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text(item.status)
                    .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(10)
            .agentRowSurface(radius: 14, tint: item.tint.opacity(0.07), selected: selectedMemoryItemID == item.id)
        }
        .buttonStyle(.plain)
        .contextMenu {
            memoryContextMenu(for: item)
        }
    }

    var memorySectionsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(projectMemorySections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: section.group.symbol)
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(section.group.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.group.title)
                                .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                            Text(section.group.subtitle)
                                .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.tertiaryText)
                        }
                        Spacer(minLength: 0)
                        Text("\(section.items.count)")
                            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(section.items.prefix(5).enumerated()), id: \.element.id) { index, item in
                            projectMemoryRow(item)
                            if index < min(section.items.count, 5) - 1 {
                                Divider()
                                    .overlay(AgentPalette.border.opacity(0.36))
                                    .padding(.leading, 42)
                            }
                        }

                        if section.items.count > 5 {
                            Text("+\(section.items.count - 5) more")
                                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(section.group.tint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 7)
                        }
                    }
                }
                .padding(10)
                .background(section.group.tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    func projectMemoryRow(_ item: ProjectMemoryItem) -> some View {
        Button {
            selectedMemoryItemID = item.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(item.tint)
                    .frame(width: 32, height: 32)
                    .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.isImportant {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(AgentPalette.warning)
                        }
                    }
                    Text(item.metadata)
                        .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.detail)
                        .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(item.status)
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(item.tint)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .agentControlSurface(radius: 6, tint: item.tint.opacity(0.10), selected: true)

                    Image(systemName: selectedMemoryItemID == item.id ? "checkmark.circle.fill" : "info.circle")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(selectedMemoryItemID == item.id ? AgentPalette.green : AgentPalette.secondaryText)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            memoryContextMenu(for: item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title). \(item.status). \(item.detail)")
        .accessibilityIdentifier("filesMemoryRow-\(item.id)")
    }

    @ViewBuilder
    func memoryContextMenu(for item: ProjectMemoryItem) -> some View {
        Button {
            openMemoryItem(item)
        } label: {
            Label(primaryActionTitle(for: item), systemImage: primaryActionSymbol(for: item))
        }
        Button {
            copyMemoryPath(item)
        } label: {
            Label("Copy Path", systemImage: "doc.on.doc")
        }
        if item.hasRelatedContext {
            Button {
                revealRelatedContext(for: item)
            } label: {
                Label("Reveal Related Run", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        if item.comparisonPaths != nil {
            Button {
                compareMemoryItem(item)
            } label: {
                Label("Compare", systemImage: "arrow.left.arrow.right")
            }
        }
        Button {
            toggleImportant(item)
        } label: {
            Label(item.isImportant ? "Unmark Important" : "Mark Important", systemImage: item.isImportant ? "star.slash" : "star")
        }
        Button {
            togglePinned(item)
        } label: {
            Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
        }
    }

    func memoryTag(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .agentControlSurface(radius: 8, tint: tint.opacity(0.10), selected: true)
    }

}
