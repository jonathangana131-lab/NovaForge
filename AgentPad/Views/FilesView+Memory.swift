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
    /// First-glance Workspace control surface: the latest generated output,
    /// proof health, recent file changes, terminal receipts, and remaining
    /// artifact shelf in one scanable pass.
    @ViewBuilder
    var evidenceWorkbenchOverview: some View {
        if projectMemoryItems.isEmpty && recentTerminalRecords.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    NovaSectionMark(
                        title: "Evidence Workbench",
                        detail: workbenchStatusLine,
                        tint: failedTerminalProofCount > 0 || riskCount > 0 ? AgentPalette.warning : AgentPalette.green
                    )

                    Spacer(minLength: 0)

                    Label("Trust", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.green)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .agentControlSurface(radius: 8, tint: AgentPalette.green.opacity(0.10), selected: true)
                }

                if let primaryWorkbenchItem {
                    featuredEvidencePanel(primaryWorkbenchItem)
                }

                workbenchMetricStrip

                if !recentChangeItems.isEmpty || !recentTerminalRecords.isEmpty {
                    Divider()
                        .overlay(AgentPalette.border.opacity(0.42))

                    VStack(alignment: .leading, spacing: 10) {
                        if !recentChangeItems.isEmpty {
                            workbenchChangeLane
                        }

                        if !recentChangeItems.isEmpty && !recentTerminalRecords.isEmpty {
                            Divider()
                                .overlay(AgentPalette.border.opacity(0.34))
                        }

                        if !recentTerminalRecords.isEmpty {
                            workbenchTerminalLane
                        }
                    }
                }

                if artifactGalleryItems.count > 1 {
                    Divider()
                        .overlay(AgentPalette.border.opacity(0.34))
                    artifactShelf
                }
            }
            .padding(12)
            .agentSurface(radius: 22, tint: AgentPalette.green.opacity(0.10))
            .overlay(NovaCornerTicks(tint: AgentPalette.green.opacity(0.30), length: 9, thickness: 1.1, inset: 7))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("filesEvidenceWorkbenchOverview")
        }
    }

    /// Grouped workspace evidence, rendered directly on the background
    /// below the browser. The old "Project Memory" mega-card (title +
    /// four-stat telemetry + always-open inspector) is gone: the browser
    /// is the surface, evidence supports it, and the inspector opens as a
    /// sheet only when a row is tapped.
    @ViewBuilder
    var evidenceSection: some View {
        if !projectMemoryItems.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                NovaSectionMark(
                    title: "Evidence",
                    detail: memoryIsStale ? "Stale" : projectMemorySubtitle,
                    tint: memoryIsStale ? AgentPalette.warning : AgentPalette.green
                )

                if projectMemoryItems.count >= 6 {
                    workbenchLensBar
                }

                if filteredProjectMemoryItems.isEmpty {
                    AgentInlineStateView(
                        title: "No \(selectedWorkbenchLens.title.lowercased()) evidence",
                        detail: "Switch filters or create new proof from Forge.",
                        symbol: selectedWorkbenchLens.symbol,
                        tint: selectedWorkbenchLens.tint
                    )
                } else {
                    memorySectionsList
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("filesProjectMemoryWorkbench")
        }
    }

    /// What the agent made, as a compact horizontal shelf above the
    /// browser — the most valuable outputs get the first glance.
    var artifactShelf: some View {
        VStack(alignment: .leading, spacing: 9) {
            NovaSectionMark(
                title: "Artifacts",
                detail: "\(artifactGalleryItems.count) generated",
                tint: AgentPalette.green
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(artifactGalleryItems) { item in
                        projectMemoryGalleryCard(item)
                            .frame(width: 188)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filesArtifactShelf")
    }

    var workbenchStatusLine: String {
        var parts: [String] = []
        if artifactCount > 0 { parts.append("\(artifactCount) artifact\(artifactCount == 1 ? "" : "s")") }
        if changedFileCount > 0 { parts.append("\(changedFileCount) change\(changedFileCount == 1 ? "" : "s")") }
        if terminalProofCount > 0 { parts.append("\(terminalProofCount) terminal") }
        if verificationCount > 0 { parts.append("\(verificationCount) proof") }
        if riskCount > 0 { parts.append("\(riskCount) review") }
        return parts.isEmpty ? "Waiting for proof" : parts.joined(separator: " / ")
    }

    var workbenchMetricStrip: some View {
        HStack(alignment: .top, spacing: 8) {
            workbenchMetric(
                value: "\(artifactCount)",
                label: "Artifacts",
                detail: "Generated outputs",
                symbol: "shippingbox.fill",
                tint: AgentPalette.green
            )
            workbenchMetric(
                value: "\(changedFileCount)",
                label: "Changes",
                detail: "Files touched",
                symbol: "plus.forwardslash.minus",
                tint: AgentPalette.cyan
            )
            workbenchMetric(
                value: "\(terminalProofCount)",
                label: "Terminal",
                detail: failedTerminalProofCount == 0 ? "Command proof" : "\(failedTerminalProofCount) failed",
                symbol: "terminal.fill",
                tint: failedTerminalProofCount == 0 ? AgentPalette.lilac : AgentPalette.rose
            )
            workbenchMetric(
                value: "\(riskCount)",
                label: "Review",
                detail: riskCount == 0 ? "No flags" : "Needs eyes",
                symbol: riskCount == 0 ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                tint: riskCount == 0 ? AgentPalette.green : AgentPalette.warning
            )
        }
    }

    func workbenchMetric(value: String, label: String, detail: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 18, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(label)
                .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .textCase(.uppercase)
                .lineLimit(1)

            Text(detail)
                .font(.system(size: 8, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value), \(detail)")
    }

    func featuredEvidencePanel(_ item: ProjectMemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(item.tint)
                    .frame(width: 42, height: 42)
                    .agentControlSurface(radius: 14, tint: item.tint.opacity(0.14), selected: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.group == .changed ? "Latest change" : "Latest artifact")
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(item.tint)
                        .textCase(.uppercase)
                        .tracking(0.8)
                    Text(item.title)
                        .font(.system(size: 17, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(item.primaryPath)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 5) {
                    Label(item.status, systemImage: item.isFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(item.isFailed ? AgentPalette.rose : item.tint)
                        .lineLimit(1)
                    Text(item.timestampText)
                        .font(.system(size: 8.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                }
            }

            Text(item.detail)
                .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(2)

            HStack(spacing: 8) {
                workbenchActionButton(
                    title: primaryActionTitle(for: item),
                    symbol: primaryActionSymbol(for: item),
                    tint: item.tint
                ) {
                    openMemoryItem(item)
                }

                workbenchActionButton(title: "Inspect", symbol: "doc.text.magnifyingglass", tint: AgentPalette.lilac) {
                    selectedMemoryItemID = item.id
                }

                if item.hasRelatedContext {
                    workbenchActionButton(title: "Source", symbol: "point.3.connected.trianglepath.dotted", tint: AgentPalette.cyan) {
                        revealRelatedContext(for: item)
                    }
                }
            }
        }
        .padding(12)
        .background(item.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(item.tint.opacity(0.20), lineWidth: 0.7)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("filesFeaturedEvidence")
    }

    func workbenchActionButton(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 9.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, 9)
                .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: 34)
                .agentControlSurface(radius: 11, tint: tint.opacity(0.12), selected: true)
        }
        .buttonStyle(.plain)
    }

    var workbenchChangeLane: some View {
        VStack(alignment: .leading, spacing: 7) {
            workbenchLaneHeader(title: "Changes", detail: "\(changedFileCount) recorded", symbol: "plus.forwardslash.minus", tint: AgentPalette.cyan)

            ForEach(recentChangeItems) { item in
                Button {
                    selectedMemoryItemID = item.id
                } label: {
                    workbenchEvidenceRow(item)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    memoryContextMenu(for: item)
                }
            }
        }
    }

    var workbenchTerminalLane: some View {
        VStack(alignment: .leading, spacing: 7) {
            workbenchLaneHeader(
                title: "Terminal",
                detail: failedTerminalProofCount == 0 ? "\(terminalProofCount) receipts" : "\(failedTerminalProofCount) failed",
                symbol: "terminal.fill",
                tint: failedTerminalProofCount == 0 ? AgentPalette.lilac : AgentPalette.rose
            )

            ForEach(recentTerminalRecords, id: \.id) { record in
                workbenchTerminalRow(record)
            }
        }
    }

    func workbenchLaneHeader(title: String, detail: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
            Spacer(minLength: 0)
            Text(detail)
                .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
        }
    }

    func workbenchEvidenceRow(_ item: ProjectMemoryItem) -> some View {
        HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(item.tint)
                .frame(width: 26, height: 26)
                .background(item.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.metadata)
                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Text(item.risk.title)
                .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(item.risk.tint)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.status), \(item.detail)")
    }

    func workbenchTerminalRow(_ record: TerminalCommandRecord) -> some View {
        HStack(spacing: 9) {
            Image(systemName: record.status == .failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(record.status == .failed ? AgentPalette.rose : AgentPalette.green)
                .frame(width: 26, height: 26)
                .background((record.status == .failed ? AgentPalette.rose : AgentPalette.green).opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("$ \(record.command)")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(record.workspaceName) / \(dateText(record.completedAt)) / \(String(format: "%.0fms", record.durationMs))")
                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal \(record.status.rawValue), \(record.command)")
    }

    /// The full spec sheet for one evidence item, presented modally.
    func memoryInspectorSheet(for item: ProjectMemoryItem) -> some View {
        ScrollView {
            memoryInspector(for: item)
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationBackground(.thinMaterial)
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

    /// Spec-sheet line: accent tick + label + value. The deboxed replacement
    /// for the old icon-tile metadata cells.
    func memoryMetadataCell(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(tint.opacity(0.75))
                .frame(width: 2.5, height: 9)
                .offset(y: -0.5)

            Text(title)
                .novaLabel(AgentPalette.tertiaryText)
                .layoutPriority(1)

            Text(value)
                .font(NovaType.caption)
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
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

                memoryActionButton(title: "Dossier", symbol: "text.badge.plus", tint: AgentPalette.green) {
                    addToProjectBrief(item)
                }

                memoryActionButton(title: "Open in Forge", symbol: "sparkles", tint: AgentPalette.cyan) {
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

    func projectMemoryGalleryCard(_ item: ProjectMemoryItem) -> some View {
        Button {
            selectedMemoryItemID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(item.tint)
                        .frame(width: 32, height: 32)
                        .agentControlSurface(radius: 10, tint: item.tint.opacity(0.12), selected: true)
                    Spacer(minLength: 0)
                    Label(item.isFailed ? "Failed" : item.status, systemImage: item.isFailed ? "xmark.octagon.fill" : "sparkles")
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(item.isFailed ? AgentPalette.rose : item.tint)
                        .lineLimit(1)
                        .labelStyle(.titleAndIcon)
                }

                Text(item.title)
                    .font(.system(size: 12.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text(item.primaryPath)
                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if item.isPreviewable {
                        Label("Preview", systemImage: "play.fill")
                            .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.green)
                            .lineLimit(1)
                    }
                    Text(item.timestampText)
                        .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .padding(11)
            .agentRowSurface(radius: 16, tint: item.tint.opacity(0.08), selected: selectedMemoryItemID == item.id || item.isGenerated)
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
