import SwiftUI
import SwiftData

struct ChatDrawerOverlay: View {
    @Environment(\.modelContext) private var modelContext
    let project: Project
    let conversations: [Conversation]
    let selectedConversationID: UUID
    let protectedConversationID: UUID?
    let settings: AgentSettings
    let selectConversation: (Conversation) -> Void
    let newChat: () -> Void
    let close: () -> Void

    @State private var searchText = ""
    @State private var showingRenameAlert = false
    @State private var showingDeleteConfirmation = false
    @State private var conversationToRename: Conversation? = nil
    @State private var conversationPendingDelete: Conversation? = nil
    @State private var renameText = ""
    @State private var animateContent = false
    @State private var allRows: [ChatListRowData] = []
    @State private var visibleRows: [ChatListRowData] = []
    @State private var drawerError: String?

    private let renderRowsLimit = 120

    private var renderedRows: ArraySlice<ChatListRowData> {
        visibleRows.prefix(renderRowsLimit)
    }

    private var pinnedSearchRows: ArraySlice<ChatListRowData> {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? visibleRows.prefix(0) : visibleRows.prefix(1)
    }

    private var renderedScrollableRows: ArraySlice<ChatListRowData> {
        let rows = visibleRows.prefix(renderRowsLimit)
        return pinnedSearchRows.isEmpty ? rows : rows.dropFirst(pinnedSearchRows.count)
    }

    private var hiddenRenderedRowCount: Int {
        max(visibleRows.count - renderRowsLimit, 0)
    }

    private var listIdentity: [ChatListIdentity] {
        conversations.map {
            ChatListIdentity(
                id: $0.id,
                title: $0.title,
                updatedAt: $0.updatedAt,
                messageCount: $0.messageCount,
                lastMessagePreview: $0.lastMessagePreview
            )
        }
    }

    private var drawerSummaryText: String {
        let total = conversations.count
        let base = "\(total) chat\(total == 1 ? "" : "s")"
        guard visibleRows.count != total else { return base }
        return "\(base) · \(visibleRows.count) shown"
    }

    private func rebuildRows() {
        allRows = conversations.map(ChatListRowData.init)
        filterRows()
    }

    private func filterRows() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = query.normalizedForChatSearch
        visibleRows = query.isEmpty
            ? allRows
            : allRows.filter { row in
                row.normalizedSearchText.contains(normalizedQuery)
            }
    }

    var body: some View {
        GeometryReader { proxy in
            let preferredPanelWidth = max(280, proxy.size.width * 0.86)
            let panelWidth = min(336, preferredPanelWidth, max(280, proxy.size.width - 16))
            let topPadding = max(76, proxy.safeAreaInsets.top + 28)
            let bottomPadding = max(18, proxy.safeAreaInsets.bottom + 12)
            let panelShape = UnevenRoundedRectangle(bottomTrailingRadius: 26, topTrailingRadius: 26)

            ZStack(alignment: .leading) {
                AgentPalette.pearl.opacity(animateContent ? 0.58 : 0.0)
                    .ignoresSafeArea()
                    .onTapGesture(perform: dismiss)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(settings.provider.tint)
                            .frame(width: 32, height: 32)
                            .agentSurface(radius: 10, tint: settings.provider.tint.opacity(0.12))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chats")
                                .font(.system(size: 17, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                                .accessibilityIdentifier("chatDrawerTitle")
                            Text(drawerSummaryText)
                                .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.secondaryText)
                                .accessibilityIdentifier("chatDrawerSummary")
                        }

                        Spacer()

                        Button(action: dismiss) {
                            ZStack {
                                Color.clear
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close chats")
                        .accessibilityIdentifier("chatDrawerClose")
                        .agentSurface(radius: 13)
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        newChat()
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(settings.provider.tint)
                            Text("New Chat")
                                .font(.system(size: 12, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: AgentDesign.minimumTouchTarget)
                        .agentControlSurface(radius: 12, tint: settings.provider.tint, selected: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New chat")
                    .accessibilityIdentifier("chatDrawerNewChat")

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AgentPalette.tertiaryText)
                        TextField("Search chats...", text: $searchText)
                            .font(.system(size: 13, design: AgentPalette.interfaceFontDesign))
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.none)
                            .accessibilityIdentifier("chatSearch")
                        
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                ZStack {
                                    Color.clear
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(AgentPalette.tertiaryText)
                                }
                                .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear chat search")
                            .accessibilityIdentifier("chatDrawerSearchClear")
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: AgentDesign.minimumTouchTarget)
                    .agentControlSurface(radius: 12)

                    if !pinnedSearchRows.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Best match")
                                .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(settings.provider.tint)
                                .textCase(.uppercase)
                                .padding(.horizontal, 4)
                            ForEach(pinnedSearchRows) { row in
                                drawerRow(row)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityIdentifier("chatDrawerPinnedSearchResult")
                    }

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 8) {
                            if visibleRows.isEmpty {
                                Text(searchText.isEmpty ? "No chat history" : "No matching chats")
                                    .font(.caption)
                                    .foregroundStyle(AgentPalette.tertiaryText)
                                    .padding(.top, 24)
                            } else {
                                ForEach(renderedScrollableRows) { row in
                                    drawerRow(row)
                                }

                                if hiddenRenderedRowCount > 0 {
                                    Text("Showing newest \(renderRowsLimit). Search to narrow \(hiddenRenderedRowCount) more chats.")
                                        .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                        .foregroundStyle(AgentPalette.tertiaryText)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                }
                            }
                        }
                        .padding(.top, 2)
                        .padding(.bottom, 18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                }
                .padding(.top, topPadding)
                .padding(.horizontal, 12)
                .padding(.bottom, bottomPadding)
                .frame(width: panelWidth, height: proxy.size.height, alignment: .topLeading)
                .background {
                    ZStack {
                        panelShape
                            .fill(AgentPalette.pearl.opacity(0.98))
                        panelShape
                            .fill(AgentPalette.surface.opacity(0.94))
                    }
                }
                .clipShape(panelShape)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(AgentPalette.blue.opacity(0.14))
                        .frame(width: 0.8)
                }
                .overlay {
                    panelShape
                        .stroke(AgentPalette.border, lineWidth: 0.8)
                }
                .shadow(color: AgentPalette.shadow.opacity(0.55), radius: 12, x: 6, y: 0)
                .offset(x: animateContent ? 0 : -panelWidth)
            }
        }
        .onAppear {
            rebuildRows()
            withAnimation(.smooth(duration: 0.24)) {
                animateContent = true
            }
        }
        .onChange(of: listIdentity) {
            rebuildRows()
        }
        .onChange(of: searchText) {
            filterRows()
        }
        .alert("Rename Chat", isPresented: $showingRenameAlert) {
            TextField("Chat Title", text: $renameText)
                .textInputAutocapitalization(.sentences)
            Button("Save") {
                if let conversation = conversationToRename {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let previousTitle = conversation.title.isEmpty ? "NovaForge Session" : conversation.title
                        conversation.title = trimmed
                        conversation.updatedAt = Date()
                        ProjectEventRecorder.record(
                            project: project,
                            kind: .conversationRenamed,
                            title: "Chat renamed",
                            detail: "\(previousTitle) -> \(trimmed)",
                            severity: .info,
                            sourceType: .conversation,
                            sourceID: conversation.id,
                            context: modelContext
                        )
                        saveDrawerContext("Could not rename this chat.")
                    }
                }
                conversationToRename = nil
                renameText = ""
            }
            Button("Cancel", role: .cancel) {
                conversationToRename = nil
                renameText = ""
            }
        }
        .alert("Delete Chat?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                conversationPendingDelete = nil
            }
            Button("Delete Chat", role: .destructive) {
                if let conversation = conversationPendingDelete {
                    deleteConversation(conversation.id)
                }
                conversationPendingDelete = nil
            }
        } message: {
            if let conversation = conversationPendingDelete {
                Text("Delete \"\(conversation.title.isEmpty ? "NovaForge Session" : conversation.title)\" from chat history? This cannot be undone.")
            } else {
                Text("Delete this chat from history? This cannot be undone.")
            }
        }
        .alert(
            "Chat Drawer Error",
            isPresented: Binding(
                get: { drawerError != nil },
                set: { if !$0 { drawerError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { drawerError = nil }
        } message: {
            Text(drawerError ?? "NovaForge could not save that chat change.")
        }
    }

    @ViewBuilder
    private func drawerRow(_ row: ChatListRowData) -> some View {
        ChatDrawerRow(
            row: row,
            isSelected: row.id == selectedConversationID,
            isDeleteProtected: row.id == protectedConversationID,
            activeColor: settings.provider.tint,
            deleteAction: {
                requestDeleteConversation(row.id)
            },
            renameAction: {
                prepareRename(row.id)
            }
        ) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let conversation = conversations.first(where: { $0.id == row.id }) {
                selectConversation(conversation)
                dismiss()
            }
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.22)) {
            animateContent = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            close()
        }
    }

    private func prepareRename(_ conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        conversationToRename = conversation
        renameText = conversation.title
        showingRenameAlert = true
    }

    private func requestDeleteConversation(_ conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        conversationPendingDelete = conversation
        showingDeleteConfirmation = true
    }

    private func deleteConversation(_ conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let impact = UINotificationFeedbackGenerator()
        impact.notificationOccurred(.success)
        let title = conversation.title.isEmpty ? "NovaForge Session" : conversation.title
        ProjectEventRecorder.record(
            project: project,
            kind: .conversationDeleted,
            title: "Chat deleted",
            detail: title,
            severity: .info,
            sourceType: .conversation,
            sourceID: conversation.id,
            context: modelContext
        )
        modelContext.delete(conversation)
        guard saveDrawerContext("Could not delete this chat.") else { return }

        if conversationID == selectedConversationID {
            let remaining = conversations.filter { $0.id != conversationID }
            if let first = remaining.first {
                selectConversation(first)
            } else {
                newChat()
            }
        }
    }
    @discardableResult
    private func saveDrawerContext(_ message: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            drawerError = "\(message) \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }
    }
}

private extension String {
    var normalizedForChatSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ChatListIdentity: Equatable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let messageCount: Int
    let lastMessagePreview: String
}

private struct ChatListRowData: Identifiable, Equatable {
    let id: UUID
    let title: String
    let preview: String
    let messageCount: Int
    let relativeDate: String
    let normalizedSearchText: String

    init(_ conversation: Conversation) {
        id = conversation.id
        title = conversation.title.isEmpty ? "NovaForge Session" : conversation.title
        messageCount = conversation.messageCount
        let storedPreview = conversation.lastMessagePreview.trimmingCharacters(in: .whitespacesAndNewlines)
        preview = storedPreview.isEmpty ? "No messages yet" : storedPreview
        normalizedSearchText = "\(title) \(preview)".normalizedForChatSearch
        relativeDate = Self.relativeDateFormatter.localizedString(
            for: conversation.updatedAt,
            relativeTo: Date()
        )
    }

    nonisolated(unsafe) private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct ChatDrawerRow: View {
    let row: ChatListRowData
    let isSelected: Bool
    let isDeleteProtected: Bool
    let activeColor: Color
    let deleteAction: () -> Void
    let renameAction: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "bubble.left.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isSelected ? activeColor : AgentPalette.cyan)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill((isSelected ? activeColor : AgentPalette.cyan).opacity(0.09))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(.system(size: 13, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .minimumScaleFactor(0.82)
                            Spacer(minLength: 0)
                            Text(row.messageCount > 0 ? "\(row.relativeDate) · \(row.messageCount)" : row.relativeDate)
                                .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.tertiaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .layoutPriority(1)
                        }
                        Text(row.preview)
                            .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.82)
                    }
                    .layoutPriority(1)
                }
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Menu {
                Button(action: renameAction) {
                    Label("Rename", systemImage: "pencil")
                }
                if isDeleteProtected {
                    Label("Finish or pause the active run before deleting", systemImage: "lock.fill")
                } else {
                    Button(role: .destructive, action: deleteAction) {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                    .background(.white.opacity(0.01))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chat actions for \(row.title)")
            .accessibilityIdentifier("chatDrawerRowActions-\(row.id.uuidString)")
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .agentRowSurface(radius: 14, tint: isSelected ? activeColor : AgentPalette.cyan, selected: isSelected)
        .contextMenu {
            Button(action: renameAction) {
                Label("Rename", systemImage: "pencil")
            }
            if isDeleteProtected {
                Label("Finish or pause the active run before deleting", systemImage: "lock.fill")
            } else {
                Button(role: .destructive, action: deleteAction) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
