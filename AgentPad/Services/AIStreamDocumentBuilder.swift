import Foundation

struct AIStreamDocumentBuilder: Sendable {
    private(set) var completeText: String = ""
    private(set) var document: AIStreamDocument = .empty

    private var status: AIStreamStatus = .idle
    private var artifacts: [LiveChatArtifactHandoff] = []
    private var completed = false
    private let maxVisibleParagraphs: Int

    init(maxVisibleParagraphs: Int = 3) {
        self.maxVisibleParagraphs = max(1, maxVisibleParagraphs)
    }

    @discardableResult
    mutating func apply(_ event: AIStreamEvent) -> AIStreamDocument {
        switch event.kind {
        case .connecting(let provider, let model):
            status = .connecting(Self.connectionLabel(provider: provider, model: model))
            completed = false
        case .responseStarted:
            status = .composing
            completed = false
        case .textDelta(let delta):
            append(delta)
            if !completed { status = .composing }
        case .sentenceCompleted(let sentence):
            appendSentenceIfNeeded(sentence)
            if !completed { status = .composing }
        case .paragraphCompleted(let paragraph):
            appendParagraphIfNeeded(paragraph)
            if !completed { status = .composing }
        case .toolStarted(let name, _):
            status = .usingTool(Self.humanToolName(name))
        case .toolFinished:
            status = .composing
        case .artifactReady(let title, let path, let typeName):
            upsertArtifact(title: title, path: path, typeName: typeName)
            if !completed { status = completeText.isEmpty ? .idle : .composing }
        case .waitingForApproval(let summary):
            status = .waitingApproval(Self.humanFailureOrSummary(summary))
        case .completed:
            completed = true
            status = .complete
        case .failed(let message):
            completed = false
            status = .failed(Self.humanFailureOrSummary(message))
        }
        document = makeDocument()
        return document
    }

    mutating func reset() {
        completeText = ""
        document = .empty
        status = .idle
        artifacts.removeAll(keepingCapacity: true)
        completed = false
    }

    private mutating func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        completeText += delta
    }

    private mutating func appendSentenceIfNeeded(_ sentence: String) {
        let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if completeText.hasSuffix(clean) { return }
        if !completeText.isEmpty, !completeText.hasSuffix(" "), !completeText.hasSuffix("\n") {
            completeText += " "
        }
        completeText += clean
    }

    private mutating func appendParagraphIfNeeded(_ paragraph: String) {
        let clean = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if completeText.hasSuffix(clean) { return }
        if !completeText.isEmpty, !completeText.hasSuffix("\n\n") {
            completeText += "\n\n"
        }
        completeText += clean
    }

    private mutating func upsertArtifact(title: String, path: String, typeName: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Artifact ready" : title
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanType = typeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Artifact" : typeName
        guard !cleanPath.isEmpty else { return }
        let handoff = LiveChatArtifactHandoff(
            id: cleanPath,
            title: cleanTitle,
            subtitle: "\(cleanType) ready in Workspace",
            path: cleanPath,
            typeName: cleanType,
            primaryActionTitle: Self.primaryArtifactAction(for: cleanType)
        )
        if let index = artifacts.firstIndex(where: { $0.id == cleanPath }) {
            artifacts[index] = handoff
        } else {
            artifacts.append(handoff)
        }
    }

    private func makeDocument() -> AIStreamDocument {
        let layout = Self.layout(for: completeText, maxVisibleParagraphs: maxVisibleParagraphs)
        return AIStreamDocument(
            title: nil,
            visibleParagraphs: layout.paragraphs,
            activeFragment: layout.activeFragment,
            status: status,
            artifacts: artifacts,
            characterCount: completeText.count,
            isComplete: completed
        )
    }

    private static func layout(for text: String, maxVisibleParagraphs: Int) -> (paragraphs: [AIStreamParagraph], activeFragment: String) {
        let rawParagraphs = text
            .components(separatedBy: blankLineSeparator)
            .map { normalizeWhitespace($0) }
            .filter { !$0.isEmpty }

        guard !rawParagraphs.isEmpty else { return ([], "") }

        var settled: [String] = []
        var active = ""

        for (index, paragraph) in rawParagraphs.enumerated() {
            let isLast = index == rawParagraphs.indices.last
            if isLast {
                let split = splitSettledPrefix(from: paragraph)
                if !split.settled.isEmpty { settled.append(split.settled) }
                active = split.active
            } else {
                settled.append(paragraph)
            }
        }

        let visible = settled.suffix(maxVisibleParagraphs)
        let paragraphs = visible.map { text in
            AIStreamParagraph(id: stableParagraphID(for: text), text: text, state: .settled)
        }
        return (paragraphs, active)
    }

    private static var blankLineSeparator: CharacterSet {
        CharacterSet.newlines
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        let collapsedLines = text
            .split(whereSeparator: { $0.isNewline })
            .map { line in line.split(separator: " ").joined(separator: " ") }
            .joined(separator: " ")
        return collapsedLines.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitSettledPrefix(from paragraph: String) -> (settled: String, active: String) {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }
        guard let boundary = lastSentenceBoundary(in: trimmed) else {
            return ("", trimmed)
        }
        let end = trimmed.index(after: boundary)
        let settled = String(trimmed[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let active = String(trimmed[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (settled, active)
    }

    private static func lastSentenceBoundary(in text: String) -> String.Index? {
        var last: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isAIStreamSentenceTerminator {
                let next = text.index(after: index)
                if next == text.endIndex || text[next].isWhitespace {
                    last = index
                }
            }
            index = text.index(after: index)
        }
        return last
    }

    private static func stableParagraphID(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func connectionLabel(provider: String, model: String?) -> String {
        let cleanProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanModel, !cleanModel.isEmpty {
            return "\(cleanProvider.isEmpty ? "Model" : cleanProvider) · \(cleanModel)"
        }
        return cleanProvider.isEmpty ? "Model" : cleanProvider
    }

    private static func humanToolName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("read") || lower.contains("file") || lower.contains("search") || lower.contains("workspace") {
            return "Using Files"
        }
        if lower.contains("xcode") || lower.contains("test") || lower.contains("command") || lower.contains("run") {
            return "Running checks"
        }
        if lower.contains("artifact") || lower.contains("preview") {
            return "Preparing preview"
        }
        if lower.contains("approval") {
            return "Waiting for approval"
        }
        return "Using tool"
    }

    private static func humanFailureOrSummary(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The response paused before finishing." }
        let lower = trimmed.lowercased()
        if lower.contains("normalizing chunk") || lower.contains("word tree") || lower.contains("renderer") {
            if lower.contains("timeout") { return "Provider timeout while preparing the response." }
            return "Preparing the response."
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private static func primaryArtifactAction(for typeName: String) -> String {
        let lower = typeName.lowercased()
        if lower.contains("html") || lower.contains("image") || lower.contains("video") || lower.contains("preview") {
            return "Preview"
        }
        return "Open"
    }
}

private extension Character {
    var isAIStreamSentenceTerminator: Bool {
        self == "." || self == "!" || self == "?" || self == "…"
    }
}
