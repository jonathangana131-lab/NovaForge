//
//  ChatMessages.swift
//  Chat message rendering: bubbles, markdown/code blocks, snapshots,
//  and the tool-approval sheet. Extracted from ChatView.swift; all structs
//  take explicit parameters and hold no ChatView-private state.
//

import SwiftUI

struct ChatMessageSource: Sendable {
    let id: UUID
    let role: ChatRole
    let content: String
    let createdAt: Date
    let toolCallID: String?
    let toolCallsJSON: String?

    init(_ message: ChatMessage) {
        id = message.id
        role = message.role
        content = message.content
        createdAt = message.createdAt
        toolCallID = message.toolCallID
        toolCallsJSON = message.toolCallsJSON
    }
}

struct ToolCallSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let resultDetail: String
    let isComplete: Bool
    let isError: Bool
    let artifact: WorkspaceArtifact?

    fileprivate init(call: APIToolCall, result: ChatMessageSource?) {
        id = call.id
        name = call.function.name
        detail = Self.shortDetail(from: call.function.arguments)
        let firstLine = result?.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        resultDetail = firstLine.count > 100 ? String(firstLine.prefix(100)) + "…" : firstLine
        isComplete = result != nil
        isError = result?.content.localizedCaseInsensitiveContains("error") == true
        artifact = result.flatMap { WorkspaceArtifact.fromToolOutput($0.content) }
    }

    private static func shortDetail(from json: String) -> String {
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        let value = ["path", "from", "to", "query", "command"]
            .compactMap { values[$0] as? String }
            .first ?? ""
        let singleLine = value.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 100 ? String(singleLine.prefix(100)) + "…" : singleLine
    }
}

enum MessageReferenceTone: String, Equatable, Sendable {
    case file
    case artifact
    case proof
    case log
    case approval
    case screenshot
    case issue

    var tint: Color {
        switch self {
        case .file: AgentPalette.indigo
        case .artifact: AgentPalette.green
        case .proof: AgentPalette.lilac
        case .log: AgentPalette.cyan
        case .approval: AgentPalette.cyan
        case .screenshot: AgentPalette.green
        case .issue: AgentPalette.rose
        }
    }
}

struct MessageReferenceHint: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tone: MessageReferenceTone

    static func make(
        role: ChatRole,
        content: String,
        toolName: String?,
        toolCalls: [ToolCallSnapshot],
        artifact: WorkspaceArtifact?
    ) -> [MessageReferenceHint] {
        guard role == .assistant || role == .tool else { return [] }
        var hints: [MessageReferenceHint] = []
        var seen = Set<String>()

        func append(_ hint: MessageReferenceHint) {
            guard seen.insert(hint.id).inserted else { return }
            hints.append(hint)
        }

        if let artifact {
            append(MessageReferenceHint(
                id: "artifact-\(artifact.path)",
                title: artifact.isPlayableWebArtifact || artifact.isSwiftGameArtifact ? "Playable" : "Artifact",
                detail: artifact.title,
                symbol: artifact.handoffSymbol,
                tone: .artifact
            ))
        }

        let lower = content.lowercased()
        if lower.contains("approval") || toolCalls.contains(where: { !$0.isComplete && isMutatingTool($0.name) }) {
            append(MessageReferenceHint(
                id: "approval",
                title: "Approval",
                detail: "Needs a decision",
                symbol: "checkmark.shield.fill",
                tone: .approval
            ))
        }
        if lower.contains("screenshot") {
            append(MessageReferenceHint(
                id: "screenshot",
                title: "Screenshot",
                detail: "Visual proof",
                symbol: "camera.viewfinder",
                tone: .screenshot
            ))
        }
        if lower.contains("proof") || lower.contains("validated") || lower.contains("verification") || toolName == "validate_html_file" || toolName == "validate_json" {
            append(MessageReferenceHint(
                id: "proof",
                title: "Proof",
                detail: "Evidence captured",
                symbol: "checkmark.seal.fill",
                tone: .proof
            ))
        }
        if lower.contains("terminal") || lower.contains(" log") || lower.contains("$ ") || toolName == "run_command" {
            append(MessageReferenceHint(
                id: "log",
                title: "Log",
                detail: "Run output",
                symbol: "terminal.fill",
                tone: .log
            ))
        }
        if let path = firstReferencedPath(in: content) {
            append(MessageReferenceHint(
                id: "file-\(path)",
                title: "File",
                detail: compact(path),
                symbol: "doc.text.fill",
                tone: WorkspaceArtifact(path: path).isWebPage ? .artifact : .file
            ))
        }
        if lower.contains("failed") || lower.contains("error") || lower.contains("blocked") {
            append(MessageReferenceHint(
                id: "issue",
                title: "Review",
                detail: "Attention needed",
                symbol: "exclamationmark.triangle.fill",
                tone: .issue
            ))
        }

        return Array(hints.prefix(4))
    }

    private static func isMutatingTool(_ name: String) -> Bool {
        [
            "write_file",
            "append_file",
            "replace_text",
            "run_command",
            "make_directory",
            "delete_path",
            "move_path",
            "copy_path"
        ].contains(name)
    }

    private static func firstReferencedPath(in content: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`()[]{}<>"))
        let extensions: Set<String> = ["swift", "html", "htm", "json", "md", "txt", "css", "js", "png", "jpg", "jpeg", "svg", "log", "sh", "py"]
        for rawToken in content.components(separatedBy: separators) {
            let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
            guard token.contains(".") else { continue }
            let artifact = WorkspaceArtifact(path: token)
            guard extensions.contains(artifact.fileExtension) else { continue }
            guard !token.hasPrefix("http://"), !token.hasPrefix("https://") else { continue }
            return token
        }
        return nil
    }

    private static func compact(_ text: String) -> String {
        let name = URL(fileURLWithPath: text).lastPathComponent
        let display = name.isEmpty ? text : name
        guard display.count > 38 else { return display }
        return String(display.prefix(35)) + "..."
    }
}

struct ChatMessageSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: ChatRole
    let content: String
    let createdAt: Date
    let toolName: String?
    let toolDetail: String
    let toolCalls: [ToolCallSnapshot]
    let blocks: [MarkdownBlock]
    let isToolError: Bool
    let artifact: WorkspaceArtifact?
    let referenceHints: [MessageReferenceHint]

    static func make(
        from sources: [ChatMessageSource],
        parseAllMessages: Bool = true,
        parseWindowSize: Int = 80
    ) -> [ChatMessageSnapshot] {
        let signpostID = AgentPerformance.begin("Chat Snapshot Build")
        defer {
            AgentPerformance.value("Chat Snapshot Source Count", Double(sources.count))
            AgentPerformance.end("Chat Snapshot Build", id: signpostID)
        }
        var namesByCallID: [String: String] = [:]
        var decodedCallsByMessageID: [UUID: [APIToolCall]] = [:]
        var resultsByCallID: [String: ChatMessageSource] = [:]
        let parsedMessageIDs = parseAllMessages
            ? nil
            : Set(sources.suffix(parseWindowSize).map(\.id))

        for source in sources where source.role == .assistant {
            guard let json = source.toolCallsJSON,
                  let data = json.data(using: .utf8),
                  let calls = try? JSONDecoder().decode([APIToolCall].self, from: data) else { continue }
            decodedCallsByMessageID[source.id] = calls
            for call in calls { namesByCallID[call.id] = call.function.name }
        }

        for source in sources where source.role == .tool {
            if let callID = source.toolCallID {
                resultsByCallID[callID] = source
            }
        }

        return sources.compactMap { source in
            let calls = decodedCallsByMessageID[source.id] ?? []
            let toolName = source.toolCallID.flatMap { namesByCallID[$0] }
            let isTool = source.role == .tool
            if isTool, let callID = source.toolCallID, namesByCallID[callID] != nil {
                return nil
            }
            let firstLine = source.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "Tool completed."
            let detail = isTool
                ? (firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : firstLine)
                : ""
            let shouldParseMarkdown = source.role == .assistant &&
                calls.isEmpty &&
                (parsedMessageIDs == nil || parsedMessageIDs?.contains(source.id) == true)
            let assistantBlocks: [MarkdownBlock]
            if shouldParseMarkdown {
                assistantBlocks = parseMarkdown(source.content)
            } else if source.role == .assistant && calls.isEmpty {
                assistantBlocks = [makeMarkdownBlock(isCode: false, language: nil, content: source.content, index: 0)]
            } else {
                assistantBlocks = []
            }
            return ChatMessageSnapshot(
                id: source.id,
                role: source.role,
                content: isTool ? "" : source.content,
                createdAt: source.createdAt,
                toolName: toolName,
                toolDetail: detail,
                toolCalls: calls.map { ToolCallSnapshot(call: $0, result: resultsByCallID[$0.id]) },
                blocks: assistantBlocks,
                isToolError: isTool && source.content.localizedCaseInsensitiveContains("error"),
                artifact: isTool ? WorkspaceArtifact.fromToolOutput(source.content) : nil,
                referenceHints: MessageReferenceHint.make(
                    role: source.role,
                    content: source.content,
                    toolName: toolName,
                    toolCalls: calls.map { ToolCallSnapshot(call: $0, result: resultsByCallID[$0.id]) },
                    artifact: isTool ? WorkspaceArtifact.fromToolOutput(source.content) : nil
                )
            )
        }
    }
}

struct MessageBubble: View, Equatable {
    let message: ChatMessageSnapshot
    var workspace: SandboxWorkspace
    let tint: Color
    let tintID: String
    let openArtifact: (WorkspaceArtifact) -> Void

    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message &&
            lhs.workspace.rootURL == rhs.workspace.rootURL &&
            lhs.workspace.maxReadableBytes == rhs.workspace.maxReadableBytes &&
            lhs.tintID == rhs.tintID
    }

    var body: some View {
        let _ = AgentPerformance.bodyEvaluation("Chat Message Bubble Body")
        Group {
            switch message.role {
            case .user:
                UserMessageBubble(content: message.content)
            case .assistant:
                if !message.toolCalls.isEmpty {
                    AssistantToolCallBubble(
                        content: message.content,
                        toolCalls: message.toolCalls,
                        openArtifact: openArtifact
                    )
                } else {
                    AssistantMessageBubble(
                        blocks: message.blocks,
                        references: message.referenceHints,
                        workspace: workspace,
                        tint: tint
                    )
                }
            case .tool:
                ToolMessageBubble(message: message, workspace: workspace, openArtifact: openArtifact)
            case .system:
                EmptyView()
            }
        }
    }
}

struct UserMessageBubble: View {
    let content: String

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            Text(content)
                .font(.system(size: 15.5, weight: .regular, design: AgentPalette.interfaceFontDesign))
                .lineSpacing(3)
                .foregroundStyle(AgentPalette.ink)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .frame(maxWidth: 324, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [
                            AgentPalette.accent.opacity(0.18),
                            AgentPalette.lilac.opacity(0.11),
                            AgentPalette.surface
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                )
                .overlay(alignment: .topLeading) {
                    Capsule()
                        .fill(AgentPalette.glassStroke.opacity(0.45))
                        .frame(width: 46, height: 1)
                        .padding(.leading, 16)
                        .padding(.top, 1)
                }
                .agentSurface(radius: 22, tint: AgentPalette.accent.opacity(0.08))
        }
        .padding(.horizontal, 18)
    }
}

struct AssistantMessageBubble: View {
    let blocks: [MarkdownBlock]
    let references: [MessageReferenceHint]
    var workspace: SandboxWorkspace
    let tint: Color

    var body: some View {
        HStack {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .agentControlSurface(radius: 9, tint: tint.opacity(0.10), selected: true)

                VStack(alignment: .leading, spacing: 10) {
                    if blocks.isEmpty {
                        AssistantTextBlockView(content: "")
                    } else {
                        ForEach(blocks) { block in
                            if block.isCode {
                                CodeBlockView(block: block, workspace: workspace)
                            } else {
                                AssistantTextBlockView(content: block.content)
                            }
                        }
                    }

                    if !references.isEmpty {
                        MessageReferenceHintRail(references: references)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .assistantResponseSurface(tint: tint)
            Spacer(minLength: 44)
        }
        .padding(.horizontal, 18)
    }
}

struct MessageReferenceHintRail: View {
    let references: [MessageReferenceHint]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(references) { reference in
                    HStack(spacing: 5) {
                        Image(systemName: reference.symbol)
                            .font(.system(size: 8, weight: .black))
                        Text(reference.title)
                            .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .textCase(.uppercase)
                        Text(reference.detail)
                            .font(.system(size: 9.5, weight: .bold, design: AgentPalette.interfaceFontDesign))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(reference.tone.tint)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .frame(maxWidth: 170)
                    .agentControlSurface(radius: 9, tint: reference.tone.tint.opacity(0.09), selected: false)
                    .accessibilityLabel("\(reference.title): \(reference.detail)")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messageReferenceHints")
    }
}

struct AssistantTextBlockView: View {
    let content: String
    private let previewContent: String
    private let isLong: Bool
    private let hiddenCharacterCount: Int
    @State private var expanded = false

    private static let previewCharacterLimit = 3_600

    init(content: String) {
        self.content = content
        if content.count > Self.previewCharacterLimit {
            let index = content.index(content.startIndex, offsetBy: Self.previewCharacterLimit)
            let preview = String(content[..<index])
            self.previewContent = preview
            self.isLong = true
            self.hiddenCharacterCount = max(content.count - preview.count, 0)
        } else {
            self.previewContent = content
            self.isLong = false
            self.hiddenCharacterCount = 0
        }
    }

    private var renderedContent: String {
        expanded ? content : previewContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if renderedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(" ")
                    .font(.system(size: 16, weight: .regular, design: AgentPalette.interfaceFontDesign))
                    .frame(height: 10)
                    .accessibilityHidden(true)
            } else {
                renderedText
                    .font(.system(size: 16, weight: .regular, design: AgentPalette.interfaceFontDesign))
                    .lineSpacing(5)
                    .foregroundStyle(AgentPalette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 2)
            }

            if isLong {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.smooth(duration: 0.2)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.up" : "text.append")
                            .font(.system(size: 10, weight: .bold))
                        Text(expanded ? "Collapse long response" : "Show full response")
                            .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        Spacer(minLength: 0)
                        if !expanded {
                            Text("\(hiddenCharacterCount) chars hidden")
                                .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.tertiaryText)
                        }
                    }
                    .foregroundStyle(AgentPalette.cyan)
                    .padding(.horizontal, 10)
                    .frame(height: AgentDesign.minimumTouchTarget)
                    .agentSurface(radius: 11, tint: AgentPalette.cyan.opacity(0.06))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var renderedText: some View {
        Text(renderedContent)
    }
}

struct AssistantResponseSurfaceModifier: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let isLight = AgentPalette.isLight
        let topSurfaceOpacity = isLight ? 0.96 : 0.82
        let bottomSurfaceOpacity = isLight ? 0.98 : 0.88
        let tintOpacity = isLight ? 0.08 : 0.035
        content
            .background {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                AgentPalette.surfaceElevated.opacity(topSurfaceOpacity),
                                AgentPalette.surface.opacity(bottomSurfaceOpacity),
                                tint.opacity(tintOpacity)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                AgentPalette.glassStroke.opacity(isLight ? 0.42 : 0.34),
                                tint.opacity(isLight ? 0.20 : 0.14),
                                AgentPalette.border.opacity(isLight ? 0.42 : 0.36)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: AgentPalette.shadow.opacity(0.08), radius: 8, x: 0, y: 3)
    }
}

extension View {
    func assistantResponseSurface(tint: Color = AgentPalette.cyan) -> some View {
        modifier(AssistantResponseSurfaceModifier(tint: tint))
    }
}

struct MarkdownBlock: Identifiable, Hashable, Sendable {
    let id: String
    let isCode: Bool
    let language: String?
    let content: String
    let lineCount: Int
    let isLargeBlock: Bool
    let collapsedContent: String
    let hiddenSummary: String
}

func parseMarkdown(_ text: String) -> [MarkdownBlock] {
    let signpostID = AgentPerformance.begin("Markdown Parse")
    defer {
        AgentPerformance.value("Markdown Parse Characters", Double(text.count))
        AgentPerformance.end("Markdown Parse", id: signpostID)
    }
    var blocks: [MarkdownBlock] = []
    var currentBlock: [String] = []
    var insideCodeBlock = false
    var codeLanguage: String? = nil

    func finishBlock(isCode: Bool, language: String?, allowEmpty: Bool = false) {
        guard allowEmpty || !currentBlock.isEmpty else { return }
        let blockContent = currentBlock.joined(separator: "\n")
        blocks.append(makeMarkdownBlock(isCode: isCode, language: language, content: blockContent, index: blocks.count))
        currentBlock.removeAll(keepingCapacity: true)
    }

    text.enumerateLines { line, _ in
        if line.hasPrefix("```") {
            if insideCodeBlock {
                finishBlock(isCode: true, language: codeLanguage, allowEmpty: true)
                insideCodeBlock = false
                codeLanguage = nil
            } else {
                finishBlock(isCode: false, language: nil)
                insideCodeBlock = true
                codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if codeLanguage?.isEmpty == true {
                    codeLanguage = nil
                }
            }
        } else {
            currentBlock.append(line)
        }
    }
    
    finishBlock(isCode: insideCodeBlock, language: codeLanguage)
    
    return blocks
}

private func makeMarkdownBlock(isCode: Bool, language: String?, content: String, index: Int) -> MarkdownBlock {
    let kind = isCode ? "code" : "text"
    let previewLineLimit = 28
    let previewCharacterLimit = 2_800
    var resolvedLineCount = 0
    var previewLines: [String] = []
    if isCode {
        previewLines.reserveCapacity(previewLineLimit)
        content.enumerateLines { line, _ in
            resolvedLineCount += 1
            if previewLines.count < previewLineLimit {
                previewLines.append(line)
            }
        }
        if content.hasSuffix("\n") {
            resolvedLineCount += 1
            if previewLines.count < previewLineLimit {
                previewLines.append("")
            }
        }
        if resolvedLineCount == 0, !content.isEmpty {
            resolvedLineCount = 1
            previewLines = [content]
        }
    }
    let large = isCode && (resolvedLineCount > previewLineLimit || content.count > previewCharacterLimit)
    let collapsed: String
    let summary: String
    if large {
        let linePreview = previewLines.joined(separator: "\n")
        if linePreview.count <= previewCharacterLimit {
            collapsed = linePreview
        } else {
            let end = linePreview.index(linePreview.startIndex, offsetBy: previewCharacterLimit)
            collapsed = String(linePreview[..<end])
        }
        let hiddenLines = max(resolvedLineCount - previewLineLimit, 0)
        let hiddenCharacters = max(content.count - collapsed.count, 0)
        summary = hiddenLines > 0 ? "\(hiddenLines) more lines hidden" : "\(hiddenCharacters) more characters hidden"
    } else {
        collapsed = content
        summary = ""
    }
    return MarkdownBlock(
        id: "\(index)-\(kind)-\(language ?? "plain")-\(content.hashValue)",
        isCode: isCode,
        language: language,
        content: content,
        lineCount: resolvedLineCount,
        isLargeBlock: large,
        collapsedContent: collapsed,
        hiddenSummary: summary
    )
}

struct CodeBlockView: View {
    let language: String?
    let content: String
    var workspace: SandboxWorkspace
    private let lineCount: Int
    private let isLargeBlock: Bool
    private let collapsedContent: String
    private let hiddenSummary: String
    
    @State private var copied = false
    @State private var expanded = false
    @State private var showingSaveAlert = false
    @State private var showingSaveStatus = false
    @State private var saveFileName = ""
    @State private var saveStatusMessage = ""

    private static let previewLineLimit = 28
    private static let previewCharacterLimit = 2_800

    init(block: MarkdownBlock, workspace: SandboxWorkspace) {
        self.language = block.language
        self.content = block.content
        self.workspace = workspace
        self.lineCount = block.lineCount
        self.isLargeBlock = block.isLargeBlock
        self.collapsedContent = block.collapsedContent
        self.hiddenSummary = block.hiddenSummary
    }

    private var renderedContent: String {
        expanded ? content : collapsedContent
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language?.uppercased() ?? "CODE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(AgentPalette.secondaryText)
                    Text("\(lineCount) \(lineCount == 1 ? "line" : "lines")")
                        .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .agentGlass(radius: 8, tint: AgentPalette.codeCursor.opacity(0.08))
                
                Spacer()

                if isLargeBlock {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.smooth(duration: 0.2)) {
                            expanded.toggle()
                        }
                    } label: {
                        ZStack {
                            Color.clear
                            HStack(spacing: 4) {
                                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                Text(expanded ? "Collapse" : "Preview")
                            }
                        }
                        .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: AgentDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AgentPalette.cyan)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("codeBlockPreviewToggle")
                    .padding(.trailing, 8)
                }
                
                Button {
                    UIPasteboard.general.string = content
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { copied = true }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation { copied = false }
                    }
                } label: {
                    ZStack {
                        Color.clear
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            Text(copied ? "Copied" : "Copy")
                        }
                    }
                    .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: AgentDesign.minimumTouchTarget)
                    .contentShape(Rectangle())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(copied ? AgentPalette.green : AgentPalette.secondaryText)
                    .scaleEffect(copied ? 1.08 : 1.0)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("codeBlockCopyButton")
                .padding(.trailing, 8)

                Button {
                    showingSaveAlert = true
                } label: {
                    ZStack {
                        Color.clear
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Save")
                        }
                    }
                    .frame(minWidth: AgentDesign.minimumTouchTarget, minHeight: AgentDesign.minimumTouchTarget)
                    .contentShape(Rectangle())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AgentPalette.cyan)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("codeBlockSaveButton")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AgentPalette.surfaceAlt.opacity(0.20))
            .overlay(
                Rectangle()
                    .frame(height: 0.8)
                    .foregroundStyle(AgentPalette.quaternaryText),
                alignment: .bottom
            )
            
            if isLargeBlock, !expanded {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AgentPalette.cyan)
                    Text("Large code block collapsed")
                        .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                    Spacer(minLength: 0)
                    Text(hiddenSummary)
                        .font(.system(size: 10, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(renderedContent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AgentPalette.codeText)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(AgentPalette.codeBackground.opacity(0.92))
        }
        .agentGlass(radius: 16, tint: AgentPalette.codeCursor.opacity(0.05))
        .alert("Save Code Block", isPresented: $showingSaveAlert) {
            TextField("filename.swift", text: $saveFileName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save") {
                saveBlock()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a filename to save this code block into the current active workspace directory.")
        }
        .alert("Code Block Save", isPresented: $showingSaveStatus) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveStatusMessage)
        }
    }
    
    private func saveBlock() {
        let name = saveFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            saveStatusMessage = "Enter a file name before saving."
            showingSaveStatus = true
            return
        }
        do {
            try workspace.write(name, contents: content)
            saveStatusMessage = "Saved \(name)."
            saveFileName = ""
        } catch {
            saveStatusMessage = "Could not save \(name): \(error.localizedDescription)"
        }
        showingSaveStatus = true
    }
}

struct ToolMessageBubble: View {
    let message: ChatMessageSnapshot
    var workspace: SandboxWorkspace
    let openArtifact: (WorkspaceArtifact) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(statusTint)
                        .frame(width: 28, height: 28)
                        .agentSurface(radius: 9, tint: statusTint.opacity(0.10))
                    
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(message.isToolError ? "Tool needs review" : "Tool finished")
                                .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.ink)
                            Text(toolDisplayName)
                                .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(statusTint)
                                .textCase(.uppercase)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .agentControlSurface(radius: 7, tint: statusTint.opacity(0.10), selected: true)
                        }

                        if !message.toolDetail.isEmpty {
                            Text(message.toolDetail)
                                .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.secondaryText)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    
                    Spacer(minLength: 0)

                    Text(message.createdAt, style: .time)
                        .font(.system(size: 9, weight: .bold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .padding(.top, 3)
                }
                
                if !message.referenceHints.isEmpty {
                    MessageReferenceHintRail(references: message.referenceHints)
                }

                if let artifact = message.artifact {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        openArtifact(artifact)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: artifact.isWebPage ? "play.rectangle.fill" : artifact.symbol)
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(artifact.isWebPage ? AgentPalette.green : AgentPalette.cyan)
                                .frame(width: 30, height: 30)
                                .agentControlSurface(radius: 10, tint: (artifact.isWebPage ? AgentPalette.green : AgentPalette.cyan).opacity(0.12), selected: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artifact.isWebPage ? "Open live artifact" : "Open artifact")
                                    .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                                Text(artifact.path)
                                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(AgentPalette.ink)
                        .padding(10)
                        .agentRowSurface(radius: 14, tint: artifact.isWebPage ? AgentPalette.green : AgentPalette.cyan, selected: true)
                    }
                    .buttonStyle(.plain)
                }

            }
            .padding(11)
            .agentRowSurface(radius: 16, tint: statusTint.opacity(0.08), selected: message.isToolError)
            Spacer(minLength: 44)
        }
        .padding(.horizontal)
    }

    private var statusTint: Color {
        message.isToolError ? AgentPalette.rose : AgentPalette.green
    }

    private var statusSymbol: String {
        message.isToolError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var toolDisplayName: String {
        guard let toolName = message.toolName else { return "Completed" }
        return plainToolName(toolName)
    }
}

struct ApprovalSheet: View {
    let request: ToolRequest
    let approve: () -> Void
    let reject: () -> Void
    @State private var showingArguments = false

    var body: some View {
        ZStack(alignment: .top) {
            AgentBackground()
            VStack(alignment: .leading, spacing: 16) {
                HeaderView(title: "Approval Needed", subtitle: plainToolName(request.name), symbol: "checkmark.shield", tint: AgentPalette.cyan)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: request.isMutating ? "pencil.and.outline" : "eye.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(request.isMutating ? AgentPalette.cyan : AgentPalette.cyan)
                                .frame(width: 34, height: 34)
                                .agentControlSurface(radius: 11, tint: request.isMutating ? AgentPalette.cyan : AgentPalette.cyan, selected: true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(request.isMutating ? "This tool can change files or run commands." : "This tool will inspect the workspace.")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(AgentPalette.ink)
                                Text(argumentSummary)
                                    .font(.caption)
                                    .foregroundStyle(AgentPalette.secondaryText)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }

                        approvalFieldList

                        Button {
                            withAnimation(.smooth(duration: 0.2)) {
                                showingArguments.toggle()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .rotationEffect(.degrees(showingArguments ? 90 : 0))
                                Text(showingArguments ? "Hide arguments" : "Show arguments")
                                    .font(.caption.weight(.bold))
                                Spacer()
                            }
                            .foregroundStyle(AgentPalette.ink)
                            .padding(10)
                            .agentSurface(radius: 12, tint: AgentPalette.cyan.opacity(0.08))
                        }
                        .buttonStyle(.plain)

                        if showingArguments {
                            Text(request.argumentsJSON)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(AgentPalette.codeText)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AgentPalette.codeBackground.opacity(0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(AgentPalette.codeCursor.opacity(0.16), lineWidth: 0.55)
                                )
                                .transition(.opacity)
                        }
                    }
                    .padding(12)
                    .agentSurface(radius: 18, tint: AgentPalette.cyan.opacity(0.10))
                }
                .scrollBounceBehavior(.basedOnSize)

                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        reject()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.rose)
                            .frame(maxWidth: .infinity)
                            .frame(height: AgentDesign.minimumTouchTarget)
                            .contentShape(Rectangle())
                            .agentControlSurface(radius: 14, tint: AgentPalette.rose.opacity(0.14), selected: true)
                    }
                    .buttonStyle(.plain)

                    Button {
                        approve()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                            .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: AgentDesign.minimumTouchTarget)
                            .contentShape(Rectangle())
                            .agentGlass(radius: 14, interactive: true, tint: AgentPalette.green.opacity(0.18))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 24)
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private var approvalFieldList: some View {
        VStack(spacing: 7) {
            approvalField(title: "Tool", value: plainToolName(request.name), symbol: "wrench.and.screwdriver.fill", tint: AgentPalette.cyan)
            approvalField(title: "Risk", value: riskSummary, symbol: request.isMutating ? "exclamationmark.triangle.fill" : "checkmark.shield.fill", tint: request.isMutating ? AgentPalette.rose : AgentPalette.green)
            approvalField(title: "Affected", value: affectedSummary, symbol: "scope", tint: AgentPalette.lilac)
            approvalField(title: "Reason", value: reasonSummary, symbol: "text.bubble.fill", tint: AgentPalette.cyan)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approvalHumanReadableFields")
    }

    private func approvalField(title: String, value: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(AgentPalette.row.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private var argumentSummary: String {
        let keys = ["path", "from", "to", "query", "command"]
        if let value = keys.compactMap({ request.arguments[$0] }).first {
            let singleLine = oneLine(value)
            return singleLine.count > 120 ? String(singleLine.prefix(120)) + "..." : singleLine
        }
        return "\(request.arguments.count) argument\(request.arguments.count == 1 ? "" : "s") ready to review."
    }

    private var riskSummary: String {
        request.isMutating ? "Can change workspace files, run a command, or alter project state." : "Read-only workspace inspection."
    }

    private var affectedSummary: String {
        let from = request.arguments["from"].map { oneLine($0) } ?? ""
        let to = request.arguments["to"].map { oneLine($0) } ?? ""
        if !from.isEmpty && !to.isEmpty { return "\(from) -> \(to)" }
        for key in ["path", "command", "query"] {
            guard let value = request.arguments[key].map({ oneLine($0) }), !value.isEmpty else { continue }
            return value.count > 140 ? String(value.prefix(140)) + "..." : value
        }
        return request.isMutating ? "Workspace target not specified." : "Current workspace context."
    }

    private var reasonSummary: String {
        for key in ["reason", "description", "purpose"] {
            guard let value = request.arguments[key].map({ oneLine($0) }), !value.isEmpty else { continue }
            return value.count > 140 ? String(value.prefix(140)) + "..." : value
        }
        return request.isMutating ? "Needed to continue the current run; review the target before approving." : "Needed to gather context for the current run."
    }

    private func oneLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension View {
    @ViewBuilder
    func glassIDIfAvailable(_ id: String, namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

/// Human-readable name for a sandbox tool, shared by chat messages and the
/// progress drawer. Module-scope so both ChatView and ChatMessages can call it.
func plainToolName(_ toolName: String) -> String {
    switch toolName {
    case "read_file": return "Read File"
    case "read_file_range": return "Read Range"
    case "tail_file": return "Tail File"
    case "write_file": return "Write File"
    case "append_file": return "Append File"
    case "replace_text": return "Replace Text"
    case "list_directory": return "List Folder"
    case "list_tree": return "List Tree"
    case "workspace_summary": return "Workspace Summary"
    case "file_info": return "File Info"
    case "search_text": return "Search"
    case "diff_files": return "Diff Files"
    case "validate_json": return "Validate JSON"
    case "validate_html_file": return "Validate HTML"
    case "extract_outline": return "Outline"
    case "run_command": return "Run Command"
    case "make_directory": return "Create Folder"
    case "delete_path": return "Delete"
    case "move_path": return "Move"
    case "copy_path": return "Copy"
    default:
        return toolName
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
