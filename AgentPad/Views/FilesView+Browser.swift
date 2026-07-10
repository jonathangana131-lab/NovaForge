//
//  FilesView+Browser.swift
//  NovaForge
//
//  Browser chrome: action bar, grid/list layouts, file action menus.
//

import SwiftData
import SwiftUI
import UIKit

extension FilesView {
    var actionBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 8) {
            IconGlassButton(
                symbol: "chevron.up",
                accessibilityLabel: "Go up",
                accessibilityIdentifier: "filesGoUpButton",
                glassID: "workspace-up",
                glassNamespace: workspaceGlassNamespace
            ) {
                goUp()
            }
            .disabled(currentPath.isEmpty)

            IconGlassButton(
                symbol: isGridLayout ? "list.bullet" : "square.grid.2x2",
                accessibilityLabel: "Toggle file layout",
                accessibilityIdentifier: "filesLayoutToggle",
                glassID: "workspace-layout",
                glassNamespace: workspaceGlassNamespace
            ) {
                let impact = UIImpactFeedbackGenerator(style: .light)
                impact.impactOccurred()
                let toggle = {
                    isGridLayout.toggle()
                }
                if items.count > 120 {
                    toggle()
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
                        toggle()
                    }
                }
            }

            IconGlassButton(
                symbol: "magnifyingglass",
                accessibilityLabel: "Search files",
                accessibilityIdentifier: "filesSearchButton",
                glassID: "workspace-search",
                glassNamespace: workspaceGlassNamespace
            ) {
                showingSearch = true
            }

            Menu {
                ForEach(workspaces, id: \.self) { ws in
                    Button {
                        switchWorkspace(to: ws)
                    } label: {
                        HStack {
                            Text(ws)
                            if ws == runtime.workspace.workspaceName {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button {
                    showingCreateWorkspace = true
                } label: {
                    Label("New Workspace...", systemImage: "plus.rectangle.on.folder")
                }

                Button {
                    exportWorkspace()
                } label: {
                    Label("Export Workspace (ZIP)", systemImage: "square.and.arrow.up")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AgentPalette.cyan)
                    Text(runtime.workspace.workspaceName)
                        .font(NovaType.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AgentPalette.quaternaryText)
                }
                .foregroundStyle(AgentPalette.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: AgentDesign.minimumTouchTarget)
                .contentShape(Capsule())
            }
            .agentInteractiveGlassButtonStyle(
                radius: AgentDesign.minimumTouchTarget / 2,
                tint: AgentPalette.cyan,
                selected: true,
                glassID: "workspace-selector",
                in: workspaceGlassNamespace
            )
            .accessibilityLabel("Switch workspace, \(runtime.workspace.workspaceName)")
            .accessibilityIdentifier("filesWorkspaceMenu")

            Spacer(minLength: 0)

            IconGlassButton(
                symbol: "plus",
                accessibilityLabel: "Create file",
                accessibilityIdentifier: "filesCreateFileButton",
                tint: AgentPalette.green,
                glassID: "workspace-create",
                glassNamespace: workspaceGlassNamespace
            ) {
                showingCreate = true
            }
            }
        }
    }

    var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    currentPath = ""
                    reload()
                } label: {
                    Text("Home")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(currentPath.isEmpty ? AgentPalette.cyan : AgentPalette.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: AgentDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("filesBreadcrumb-home")
                
                let parts = currentPath.components(separatedBy: "/").filter { !$0.isEmpty }
                ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(AgentPalette.tertiaryText)
                    
                    Button {
                        let targetPath = parts.prefix(idx + 1).joined(separator: "/")
                        currentPath = targetPath
                        reload()
                    } label: {
                        Text(part)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(idx == parts.count - 1 ? AgentPalette.cyan : AgentPalette.secondaryText)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: AgentDesign.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("filesBreadcrumb-\(idx)-\(part)")
                }
                
                if !items.isEmpty {
                    Spacer()
                    Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .agentControlSurface(radius: 6)
                }
            }
            .padding(.horizontal)
        }
    }

    var listLayout: some View {
        LazyVStack(spacing: 8) {
            ForEach(items) { row in
                HStack(spacing: 10) {
                    Button {
                        open(row.item)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: row.visualKind.symbolName)
                                .font(.title3)
                                .foregroundStyle(row.visualKind.tint)
                                .frame(width: 36, height: 36)
                                .agentSurface(radius: 10, tint: row.visualKind.tint.opacity(0.12))

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(row.item.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AgentPalette.ink)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    if row.isRecent {
                                        Circle()
                                            .fill(AgentPalette.cyan)
                                            .frame(width: 6, height: 6)
                                            .shadow(color: AgentPalette.cyan, radius: 3)
                                    }
                                }

                                HStack(spacing: 6) {
                                    Text(row.kindText)
                                        .font(.caption2)
                                        .foregroundStyle(AgentPalette.secondaryText)
                                        .lineLimit(1)

                                    Text(row.modifiedText)
                                        .font(.caption2)
                                        .foregroundStyle(AgentPalette.tertiaryText)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    if let extensionText = row.extensionText {
                                        Text(extensionText)
                                            .font(.system(size: 7, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                            .foregroundStyle(row.visualKind.tint)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .agentControlSurface(radius: 4, tint: row.visualKind.tint, selected: true)
                                    }

                                    if row.isPreviewable {
                                        Label("Preview", systemImage: "play.fill")
                                            .font(.system(size: 7, weight: .black, design: AgentPalette.interfaceFontDesign))
                                            .foregroundStyle(AgentPalette.green)
                                            .labelStyle(.titleAndIcon)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .padding(.horizontal, 5)
                                            .frame(height: 16)
                                            .agentControlSurface(radius: 5, tint: AgentPalette.green.opacity(0.12), selected: true)
                                    }

                                    fileEvidenceBadge(for: row.item)
                                }
                            }

                            Spacer(minLength: 8)

                            Image(systemName: row.item.isDirectory ? "chevron.right" : "square.and.pencil")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(AgentPalette.secondaryText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    fileActionMenu(for: row.item)
                }
                .padding(12)
                .agentRowSurface(radius: 16, tint: row.visualKind.tint)
                .contextMenu {
                    contextMenuActions(for: row.item)
                }
            }
        }
        .padding(.horizontal)
    }

    var fileBrowserSectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            NovaSectionMark(
                title: "Files",
                detail: browserSectionDetail,
                tint: AgentPalette.cyan
            )

            Spacer(minLength: 0)

            if cachedStats.previewableCount > 0 {
                Label("\(cachedStats.previewableCount) previews", systemImage: "play.rectangle.fill")
                    .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.green)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .agentControlSurface(radius: 8, tint: AgentPalette.green.opacity(0.10), selected: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("filesBrowserSectionHeader")
    }

    var browserSectionDetail: String {
        var parts: [String] = []
        parts.append("\(items.count) item\(items.count == 1 ? "" : "s")")
        if cachedStats.recentCount > 0 {
            parts.append("\(cachedStats.recentCount) fresh")
        }
        if !currentPath.isEmpty {
            parts.append(currentPath)
        }
        return parts.joined(separator: " / ")
    }

    var gridLayout: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 12)], spacing: 12) {
            ForEach(items) { row in
                Button {
                    open(row.item)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: row.visualKind.symbolName)
                            .font(.title2)
                            .foregroundStyle(row.visualKind.tint)
                            .frame(width: 44, height: 44)
                            .agentSurface(radius: 13, tint: row.visualKind.tint.opacity(0.12))
                        
                        HStack(spacing: 4) {
                            Text(row.item.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AgentPalette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            
                            if row.isRecent {
                                Circle()
                                    .fill(AgentPalette.cyan)
                                    .frame(width: 5, height: 5)
                                    .shadow(color: AgentPalette.cyan, radius: 2)
                            }
                        }
                        
                        Text(row.kindText)
                            .font(.system(size: 9))
                            .foregroundStyle(AgentPalette.secondaryText)

                        if row.isPreviewable || row.isRecent {
                            Label(row.isPreviewable ? "Previewable" : "Fresh", systemImage: row.isPreviewable ? "play.fill" : "sparkle")
                                .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(row.isPreviewable ? AgentPalette.green : AgentPalette.cyan)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .agentControlSurface(radius: 6, tint: (row.isPreviewable ? AgentPalette.green : AgentPalette.cyan).opacity(0.12), selected: true)
                        }

                        fileEvidenceBadge(for: row.item)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .agentRowSurface(radius: 18, tint: row.visualKind.tint)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .topTrailing) {
                    fileActionMenu(for: row.item)
                        .padding(6)
                }
                .contextMenu {
                    contextMenuActions(for: row.item)
                }
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    func fileEvidenceBadge(for item: FileItem) -> some View {
        if let badge = fileEvidenceBadgeData(for: item) {
            Label(badge.title, systemImage: badge.symbol)
                .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(badge.tint)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .agentControlSurface(radius: 5, tint: badge.tint.opacity(0.12), selected: true)
        }
    }

    func fileEvidenceBadgeData(for item: FileItem) -> (title: String, symbol: String, tint: Color)? {
        let path = item.relativePath
        if scopedFileChangeRecords.contains(where: { change in
            change.path == path || change.path.components(separatedBy: " -> ").contains(path)
        }) {
            return ("Changed", "plus.forwardslash.minus", AgentPalette.cyan)
        }
        if scopedArtifactRecords.contains(where: { $0.path == path }) || isGeneratedPath(path) {
            return ("Artifact", "shippingbox.fill", AgentPalette.green)
        }
        if isVerificationPath(path) || isScreenshotPath(path) {
            return ("Proof", "checkmark.seal.fill", AgentPalette.green)
        }
        return nil
    }

    func fileActionMenu(for item: FileItem) -> some View {
        HStack(spacing: 4) {
            if canPreview(item) {
                filePrimaryActionButton(
                    symbol: "play.rectangle.fill",
                    label: "Preview \(item.name)",
                    identifier: fileActionIdentifier(prefix: "filePreview", relativePath: item.relativePath),
                    tint: AgentPalette.green
                ) {
                    preview(item)
                }
            } else if !item.isDirectory {
                filePrimaryActionButton(
                    symbol: "square.and.pencil",
                    label: "Edit \(item.name)",
                    identifier: fileActionIdentifier(prefix: "fileEdit", relativePath: item.relativePath),
                    tint: AgentPalette.cyan
                ) {
                    editFile(item)
                }
            }

            Menu {
                if canPreview(item) {
                    Button {
                        preview(item)
                    } label: {
                        Label("Preview", systemImage: "play.rectangle.fill")
                    }
                }

                if !item.isDirectory {
                    Button {
                        editFile(item)
                    } label: {
                        Label("Edit", systemImage: "square.and.pencil")
                    }
                }

                if !item.isDirectory {
                    Button {
                        duplicateFile(item)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                }

                Button(role: .destructive) {
                    pendingDeleteItem = item
                } label: {
                    Label(item.isDirectory ? "Delete Folder" : "Delete File", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.black))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .frame(width: 44, height: 44)
                    .agentControlSurface(radius: 13, tint: AgentPalette.secondaryText.opacity(0.05), selected: false)
            }
            .accessibilityLabel("More actions for \(item.name)")
            .accessibilityIdentifier(fileActionIdentifier(prefix: "fileMoreActions", relativePath: item.relativePath))
            .disabled(fileActionTask != nil)
            .opacity(fileActionTask == nil ? 1 : 0.42)
        }
    }

    func filePrimaryActionButton(
        symbol: String,
        label: String,
        identifier: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.black))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .agentControlSurface(radius: 13, tint: tint.opacity(0.12), selected: true)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .disabled(fileActionTask != nil)
        .opacity(fileActionTask == nil ? 1 : 0.42)
    }

    @ViewBuilder
    func contextMenuActions(for item: FileItem) -> some View {
        if canPreview(item) {
            Button {
                preview(item)
            } label: {
                Label("Preview Artifact", systemImage: "play.rectangle")
            }
        }

        if !item.isDirectory {
            Button {
                editFile(item)
            } label: {
                Label("Edit", systemImage: "square.and.pencil")
            }

            Button {
                duplicateFile(item)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }

        Button(role: .destructive) {
            pendingDeleteItem = item
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    func primaryActionTitle(for item: ProjectMemoryItem) -> String {
        if item.isDirectory { return "Open" }
        if item.isPreviewable { return "Preview" }
        if item.isEditable { return "Edit" }
        return "Open"
    }

    func primaryActionSymbol(for item: ProjectMemoryItem) -> String {
        if item.isDirectory { return "folder.fill" }
        if item.isPreviewable { return "play.rectangle.fill" }
        if item.isEditable { return "square.and.pencil" }
        return "arrow.up.right.square.fill"
    }

    func openMemoryItem(_ item: ProjectMemoryItem) {
        selectedMemoryItemID = item.id
        openWorkspaceEvidencePath(item.primaryPath)
    }

    func copyMemoryPath(_ item: ProjectMemoryItem) {
        UIPasteboard.general.string = item.primaryPath
        showTransientNotice("Copied \(readableEvidencePath(item.primaryPath))")
    }

    func toggleImportant(_ item: ProjectMemoryItem) {
        let key = item.primaryPath
        if importantMemoryPaths.contains(key) {
            importantMemoryPaths.remove(key)
            showTransientNotice("Unmarked important")
        } else {
            importantMemoryPaths.insert(key)
            showTransientNotice("Marked important")
        }
        saveMemoryFlags()
    }

    func togglePinned(_ item: ProjectMemoryItem) {
        let key = item.primaryPath
        if pinnedMemoryPaths.contains(key) {
            pinnedMemoryPaths.remove(key)
            showTransientNotice("Unpinned")
        } else {
            pinnedMemoryPaths.insert(key)
            showTransientNotice("Pinned to memory")
        }
        saveMemoryFlags()
    }

    func loadMemoryFlags() {
        importantMemoryPaths = Self.loadPathSet(key: "\(memoryPreferencePrefix).important")
        pinnedMemoryPaths = Self.loadPathSet(key: "\(memoryPreferencePrefix).pinned")
    }

    func saveMemoryFlags() {
        Self.savePathSet(importantMemoryPaths, key: "\(memoryPreferencePrefix).important")
        Self.savePathSet(pinnedMemoryPaths, key: "\(memoryPreferencePrefix).pinned")
    }

    static func loadPathSet(key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    static func savePathSet(_ values: Set<String>, key: String) {
        guard let data = try? JSONEncoder().encode(values.sorted()) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func addToProjectBrief(_ item: ProjectMemoryItem) {
        guard let scopeProject else {
            showTransientNotice("Choose a project scope to update its brief")
            return
        }
        let path = item.primaryPath
        guard !scopeProject.mission.localizedCaseInsensitiveContains(path) else {
            showTransientNotice("Already in project brief")
            return
        }

        let line = "- \(item.title) (\(path)): \(item.detail)"
        let trimmedMission = scopeProject.mission.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMission.localizedCaseInsensitiveContains("Project Memory:") {
            scopeProject.mission = "\(trimmedMission)\n\(line)"
        } else if trimmedMission.isEmpty {
            scopeProject.mission = "Project Memory:\n\(line)"
        } else {
            scopeProject.mission = "\(trimmedMission)\n\nProject Memory:\n\(line)"
        }
        scopeProject.updatedAt = Date()
        scopeProject.lastActivityAt = Date()
        ProjectEventRecorder.record(
            project: scopeProject,
            kind: .agentProofCreated,
            title: "Project brief updated",
            detail: path,
            severity: .info,
            sourceType: .workspace,
            metadata: ["path": path, "source": "filesWorkbench"],
            context: modelContext
        )
        if saveFileEvidence(failureMessage: "Added \(readableEvidencePath(path)) to the project brief, but NovaForge could not save it") {
            showTransientNotice("Added to project brief")
        }
    }

    func compareMemoryItem(_ item: ProjectMemoryItem) {
        guard let paths = item.comparisonPaths else { return }
        do {
            let source = try runtime.workspace.read(paths.source)
            let destination = try runtime.workspace.read(paths.destination)
            let comparison = Self.lineDiff(source: source, destination: destination)
            comparisonDraft = FileComparisonDraft(
                title: item.title,
                sourcePath: paths.source,
                destinationPath: paths.destination,
                summary: comparison.summary,
                diffText: comparison.diffText
            )
        } catch {
            comparisonDraft = FileComparisonDraft(
                title: item.title,
                sourcePath: paths.source,
                destinationPath: paths.destination,
                summary: "Comparison unavailable",
                diffText: error.localizedDescription
            )
        }
    }

    static func lineDiff(source: String, destination: String) -> (summary: String, diffText: String) {
        let sourceLines = source.components(separatedBy: .newlines)
        let destinationLines = destination.components(separatedBy: .newlines)
        let maxCount = max(sourceLines.count, destinationLines.count)
        var changed = 0
        var rows: [String] = []
        let cap = 140

        for index in 0..<maxCount {
            let left = index < sourceLines.count ? sourceLines[index] : nil
            let right = index < destinationLines.count ? destinationLines[index] : nil
            guard left != right else { continue }
            changed += 1
            if rows.count < cap {
                rows.append("@@ line \(index + 1)")
                if let left { rows.append("- \(left)") }
                if let right { rows.append("+ \(right)") }
            }
        }

        if changed == 0 {
            return ("No textual differences", "The compared files match.")
        }
        if changed > cap / 3 {
            rows.append("... diff capped after \(cap) lines. Open both files for full review.")
        }
        return ("\(changed) changed line\(changed == 1 ? "" : "s")", rows.joined(separator: "\n"))
    }

    func revealRelatedContext(for item: ProjectMemoryItem) {
        if let idString = item.sourceToolRunIDString,
           let id = UUID(uuidString: idString),
           let run = scopedToolRunRecords.first(where: { $0.id == id }) {
            relatedContextDraft = FileRelatedContextDraft(
                title: run.name,
                subtitle: "Tool run · \(run.status.rawValue)",
                detail: Self.compactDetail(run.output.isEmpty ? run.argumentsJSON : run.output),
                symbol: run.status == .failed ? "xmark.octagon.fill" : "wrench.and.screwdriver.fill",
                tint: run.status == .failed ? AgentPalette.rose : AgentPalette.cyan
            )
            return
        }

        if let idString = item.sourceTerminalCommandIDString,
           let id = UUID(uuidString: idString),
           let command = scopedTerminalCommandRecords.first(where: { $0.id == id }) {
            relatedContextDraft = FileRelatedContextDraft(
                title: command.command,
                subtitle: "Terminal command · \(command.status.rawValue)",
                detail: Self.compactDetail(command.output),
                symbol: "terminal.fill",
                tint: command.status == .failed ? AgentPalette.rose : AgentPalette.indigo
            )
            return
        }

        if let idString = item.sourceEventIDString,
           let id = UUID(uuidString: idString),
           let event = scopedEventRecords.first(where: { $0.id == id }) {
            relatedContextDraft = FileRelatedContextDraft(
                title: event.title,
                subtitle: "Project event · \(event.severity.rawValue)",
                detail: event.detail.isEmpty ? "No additional event detail." : event.detail,
                symbol: "timeline.selection",
                tint: AgentPalette.green
            )
            return
        }

        relatedContextDraft = FileRelatedContextDraft(
            title: item.title,
            subtitle: "Related context unavailable",
            detail: "The originating run or event was not found in this workspace scope.",
            symbol: "questionmark.folder.fill",
            tint: AgentPalette.secondaryText
        )
    }

    static func compactDetail(_ text: String, limit: Int = 1_800) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No output captured." }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)) + "..."
    }

    func showTransientNotice(_ message: String) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.78)) {
            transientNotice = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard transientNotice == message else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                transientNotice = nil
            }
        }
    }

    func deleteFile(_ item: FileItem) {
        guard beginFileAction("Deleting \(item.name)…") else { return }
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        let workspace = runtime.workspace
        let deletedKind = item.isDirectory ? "folder" : "file"
        let deletedPath = item.relativePath
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.16)) {
            items.removeAll { $0.item.relativePath == deletedPath }
        }
        fileActionTask = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try workspace.delete(deletedPath)
                try Task.checkCancellation()
            } catch {
                await MainActor.run {
                    if !(error is CancellationError) {
                        fileActionError = "Could not delete \(deletedKind) \(item.name): \(error.localizedDescription)"
                    }
                    finishFileAction()
                    reload()
                }
                return
            }
            await MainActor.run {
                guard !Task.isCancelled else {
                    finishFileAction()
                    return
                }
                runtime.noteWorkspaceChanged()
                ProjectEventRecorder.recordFileChange(
                    project: scopeProject,
                    action: item.isDirectory ? "Deleted folder" : "Deleted file",
                    path: item.relativePath,
                    context: modelContext
                )
                saveFileEvidence(
                    failureMessage: "Deleted \(deletedKind) \(item.name), but NovaForge could not save the project proof record"
                )
                finishFileAction()
                reload()
            }
        }
    }

    func duplicateFile(_ item: FileItem) {
        guard !item.isDirectory else { return }
        guard beginFileAction("Duplicating \(item.name)…") else { return }
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
        let workspace = runtime.workspace
        let path = item.relativePath
        let name = item.name
        fileActionTask = Task.detached(priority: .userInitiated) {
            let destination: String
            do {
                try Task.checkCancellation()
                destination = try Self.nextDuplicatePath(for: item, in: workspace)
                try workspace.copy(from: path, to: destination)
                try Task.checkCancellation()
            } catch {
                await MainActor.run {
                    if !(error is CancellationError) {
                        fileActionError = "Could not duplicate \(name): \(error.localizedDescription)"
                    }
                    finishFileAction()
                }
                return
            }
            await MainActor.run {
                guard !Task.isCancelled else {
                    finishFileAction()
                    return
                }
                runtime.noteWorkspaceChanged()
                ProjectEventRecorder.recordFileChange(
                    project: scopeProject,
                    action: "Duplicated file",
                    path: "\(path) -> \(destination)",
                    context: modelContext
                )
                saveFileEvidence(
                    failureMessage: "Duplicated \(name), but NovaForge could not save the project proof record"
                )
                finishFileAction()
                reload()
            }
        }
    }

    func beginFileAction(_ status: String) -> Bool {
        guard fileActionTask == nil else {
            fileActionError = "Finish the current file action before starting another one."
            return false
        }
        fileActionStatus = status
        return true
    }

    func finishFileAction() {
        fileActionTask = nil
        fileActionStatus = nil
    }

    @discardableResult
    func saveFileEvidence(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            fileActionError = "\(failureMessage): \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }

    func fileActionIdentifier(prefix: String, relativePath: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = relativePath.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return "\(prefix)-\(sanitized)"
    }

    func deleteConfirmationDetail(for item: FileItem) -> String {
        if item.isDirectory {
            return "\(item.relativePath) and everything inside it will be removed from the NovaForge workspace. This keeps accidental menu taps from destroying work."
        }
        return "\(item.relativePath) will be removed from the NovaForge workspace. This keeps accidental menu taps from destroying work."
    }

    nonisolated private static func nextDuplicatePath(for item: FileItem, in workspace: SandboxWorkspace) throws -> String {
        let sourcePath = item.relativePath
        let parts = sourcePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let parent = parts.dropLast().joined(separator: "/")
        let parentPrefix = parent.isEmpty ? "" : "\(parent)/"
        let sourceURL = URL(fileURLWithPath: item.name)
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        for index in 1...99 {
            let suffix = index == 1 ? "_copy" : "_copy \(index)"
            let newName = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            let candidate = "\(parentPrefix)\(newName)"
            if !FileManager.default.fileExists(atPath: (try workspace.resolve(candidate)).path) {
                return candidate
            }
        }

        throw SandboxError.invalidArguments
    }

    nonisolated static func byteCountString(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024.0
        return String(format: "%.1f MB", mb)
    }
}
