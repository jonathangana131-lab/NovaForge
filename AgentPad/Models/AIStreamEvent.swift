import Foundation

enum AIStreamEventKind: Equatable, Sendable {
    case connecting(provider: String, model: String?)
    case responseStarted
    case textDelta(String)
    case sentenceCompleted(String)
    case paragraphCompleted(String)
    case toolStarted(name: String, target: String?)
    case toolFinished(name: String, summary: String?)
    case artifactReady(title: String, path: String, typeName: String)
    case waitingForApproval(summary: String)
    case completed
    case failed(String)
}

struct AIStreamEvent: Identifiable, Equatable, Sendable {
    var id: UUID
    var date: Date
    var kind: AIStreamEventKind

    init(id: UUID = UUID(), date: Date = Date(), kind: AIStreamEventKind) {
        self.id = id
        self.date = date
        self.kind = kind
    }
}

struct AIStreamDocument: Equatable, Sendable {
    var title: String?
    var visibleParagraphs: [AIStreamParagraph]
    var activeFragment: String
    var status: AIStreamStatus
    var artifacts: [LiveChatArtifactHandoff]
    var characterCount: Int
    var isComplete: Bool

    static let empty = AIStreamDocument(
        title: nil,
        visibleParagraphs: [],
        activeFragment: "",
        status: .idle,
        artifacts: [],
        characterCount: 0,
        isComplete: false
    )

    var visibleText: String {
        (visibleParagraphs.map(\.text) + ([activeFragment].filter { !$0.isEmpty })).joined(separator: "\n\n")
    }

    var isEmpty: Bool {
        visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && artifacts.isEmpty && status == .idle
    }

    var stageStatusLine: String {
        switch status {
        case .idle:
            return "Ready"
        case .connecting(let label):
            return "Connecting to \(label)"
        case .composing:
            return "Writing answer"
        case .usingTool(let label):
            return label
        case .waitingApproval:
            return "Waiting for approval"
        case .finalizing:
            return "Finishing response"
        case .complete:
            return "Ready to review"
        case .failed:
            return "Needs recovery"
        }
    }
}

struct AIStreamParagraph: Identifiable, Equatable, Sendable {
    var id: String
    var text: String
    var state: State

    enum State: String, Equatable, Sendable {
        case settled
        case active
    }
}

enum AIStreamStatus: Equatable, Sendable {
    case idle
    case connecting(String)
    case composing
    case usingTool(String)
    case waitingApproval(String)
    case finalizing
    case complete
    case failed(String)
}
