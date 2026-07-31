import Foundation

/// An immutable, renderer-ready view of a response that is still arriving.
///
/// Settled paragraphs never change after they enter `settledParagraphs`. The
/// current paragraph keeps older text in immutable `settledSegments`, a bounded
/// suffix in `settledTail`, and the one phrase allowed to animate in
/// `activePhrase`.
struct LiveTranscriptSnapshot: Equatable, Sendable {
    struct Paragraph: Identifiable, Equatable, Sendable {
        struct ID: Hashable, Sendable {
            let responseID: UUID
            let ordinal: Int
        }

        let id: ID
        let ordinal: Int
        let text: String

        /// The exact blank-line delimiter that committed this paragraph.
        /// Keeping it separate lets a paragraph view stay immutable while
        /// `visibleText` still preserves the provider's transcript verbatim.
        let trailingSeparator: String

        var visibleText: String { text + trailingSeparator }
    }

    struct Phrase: Identifiable, Equatable, Sendable {
        struct ID: Hashable, Sendable {
            let responseID: UUID
            let paragraphOrdinal: Int
            let ordinal: Int
        }

        let id: ID
        let ordinal: Int
        let text: String
    }

    /// An immutable slice of the paragraph that is still being written.
    ///
    /// Long provider paragraphs can run for thousands of characters without a
    /// blank line. Freezing their older text into stable segments keeps the
    /// mutable Text leaf bounded without hiding any of the transcript.
    struct SettledSegment: Identifiable, Equatable, Sendable {
        struct ID: Hashable, Sendable {
            let responseID: UUID
            let paragraphOrdinal: Int
            let ordinal: Int
        }

        let id: ID
        let ordinal: Int
        let text: String
        /// An emergency literal presentation for malformed Markdown that never
        /// reaches a neutral split point. `text` always preserves the exact
        /// provider source; this value only keeps broken syntax from leaking
        /// into the visual layer after the mutable tail is hard-capped.
        let fallbackPresentationText: String?

        init(
            id: ID,
            ordinal: Int,
            text: String,
            fallbackPresentationText: String? = nil
        ) {
            self.id = id
            self.ordinal = ordinal
            self.text = text
            self.fallbackPresentationText = fallbackPresentationText
        }
    }

    struct ActiveParagraph: Identifiable, Equatable, Sendable {
        let id: Paragraph.ID
        let ordinal: Int
        let settledSegments: [SettledSegment]
        /// The bounded, still-mutable suffix after `settledSegments`.
        let settledTail: String
        let activePhrase: Phrase?

        var settledPrefix: String {
            var text = settledSegments.reduce(into: "") { partial, segment in
                partial += segment.text
            }
            text += settledTail
            return text
        }

        var visibleText: String {
            settledPrefix + (activePhrase?.text ?? "")
        }
    }

    enum Cadence: String, Equatable, Sendable {
        case idle
        case reading
        case catchingUp
        case burst

        var statusLine: String {
            switch self {
            case .idle:
                "Preparing response"
            case .reading:
                "Writing response"
            case .catchingUp, .burst:
                "Catching up"
            }
        }
    }

    let responseID: UUID
    let settledParagraphs: [Paragraph]
    let activeParagraph: ActiveParagraph
    let characterCount: Int
    let backlogCharacters: Int
    let revision: Int
    let cadence: Cadence
    let suggestedPauseFrames: Int

    /// Reconstruct the exact provider prefix only for clients that actually need
    /// the whole document (accessibility checkpoints, copy, and handoff tests).
    /// Keeping a cumulative String inside every published snapshot made each
    /// phrase append retain/copy the response-so-far. The visual renderer already
    /// consumes the paragraph/segment fields directly, so ordinary reveal ticks
    /// now stay chunked and bounded.
    var visibleText: String {
        var text = settledParagraphs.reduce(into: "") { partial, paragraph in
            partial += paragraph.visibleText
        }
        text += activeParagraph.visibleText
        return text
    }

    var isEmpty: Bool { characterCount == 0 }

    static func empty(responseID: UUID) -> LiveTranscriptSnapshot {
        LiveTranscriptSnapshot(
            responseID: responseID,
            settledParagraphs: [],
            activeParagraph: ActiveParagraph(
                id: Paragraph.ID(responseID: responseID, ordinal: 0),
                ordinal: 0,
                settledSegments: [],
                settledTail: "",
                activePhrase: nil
            ),
            characterCount: 0,
            backlogCharacters: 0,
            revision: 0,
            cadence: .idle,
            suggestedPauseFrames: 0
        )
    }
}
