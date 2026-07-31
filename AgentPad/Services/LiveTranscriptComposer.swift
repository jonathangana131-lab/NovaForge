import Foundation

/// Incrementally turns arbitrary provider deltas into phrase-paced transcript
/// snapshots. Provider chunks are parsed once as they arrive; snapshot
/// production only consumes the pending atom queue and never reparses the
/// complete response string.
struct LiveTranscriptComposer: Sendable {
    static let pendingBacklogCharacterTarget = 8_192
    static let pendingBacklogCharacterLimit = 12_288
    static let maximumActivePhraseCharacters = 96
    static let maximumProfileActivePhraseCharacters = 64
    /// Only this suffix of an unfinished paragraph is allowed to re-layout on
    /// every reveal. Older text is frozen into immutable renderer segments.
    static let maximumActiveSettledTailCharacters = 960
    /// Valid Markdown may temporarily exceed the preferred tail while waiting
    /// for its closing delimiter. Never let malformed or abandoned syntax keep
    /// that leaf growing forever, though: beyond this ceiling it is frozen as a
    /// stable literal segment and rendering work becomes bounded again.
    static let maximumEmergencyActiveSettledTailCharacters = 2_048
    private static let knownMarkdownClosureLookaheadCharacters = 1_024
    private static let preferredSettledSegmentCharacters = 720

    private enum AtomKind: Equatable, Sendable {
        case word
        case whitespace
        case punctuation
        case lineBreak
        case paragraphBreak
        case symbol
    }

    private struct Atom: Equatable, Sendable {
        var kind: AtomKind
        var text: String
    }

    private var responseID: UUID
    private var settledParagraphs: [LiveTranscriptSnapshot.Paragraph] = []
    private var activeParagraphOrdinal = 0
    private var activeSettledSegments: [LiveTranscriptSnapshot.SettledSegment] = []
    private var activeSettledTail = ""
    private var nextSettledSegmentOrdinal = 0
    private var activePhrase: LiveTranscriptSnapshot.Phrase?
    private var nextPhraseOrdinal = 0
    private var awaitsKnownMarkdownBoundary = false

    private var visibleCharacterCount = 0
    private var revision = 0
    private var lastPauseFrames = 0

    private var pendingAtoms: [Atom] = []
    private var pendingHead = 0
    private var pendingCharacterCount = 0
    private var partialWord = ""
    private var partialWordHoldFrames = 0
    private var pendingNewlineRun = ""
    private var newlineHoldFrames = 0

    private let maximumPartialWordCharacters = 24

    init(responseID: UUID = UUID()) {
        self.responseID = responseID
    }

    var hasPendingReveal: Bool {
        hasPendingAtoms || !partialWord.isEmpty || !pendingNewlineRun.isEmpty
    }

    var backlogCharacters: Int {
        pendingCharacterCount + partialWord.count + pendingNewlineRun.count
    }

    var retainedPendingAtomCount: Int {
        max(0, pendingAtoms.count - pendingHead)
    }

    mutating func reset(responseID: UUID) {
        self.responseID = responseID
        settledParagraphs.removeAll(keepingCapacity: true)
        activeParagraphOrdinal = 0
        activeSettledSegments.removeAll(keepingCapacity: true)
        activeSettledTail = ""
        nextSettledSegmentOrdinal = 0
        activePhrase = nil
        nextPhraseOrdinal = 0
        awaitsKnownMarkdownBoundary = false
        visibleCharacterCount = 0
        revision = 0
        lastPauseFrames = 0
        pendingAtoms.removeAll(keepingCapacity: true)
        pendingHead = 0
        pendingCharacterCount = 0
        partialWord = ""
        partialWordHoldFrames = 0
        pendingNewlineRun = ""
        newlineHoldFrames = 0
    }

    mutating func ingest(_ delta: String) {
        guard !delta.isEmpty else { return }
        for character in delta {
            ingest(character)
        }
        compactPendingBacklogIfNeeded()
    }

    mutating func revealNextSnapshot(
        forceMinimum: Bool,
        profileMode: Bool
    ) -> LiveTranscriptSnapshot? {
        prepareReveal(forceMinimum: forceMinimum)
        guard hasPendingAtoms else { return nil }

        let frameBudget = revealCharacterBudget(profileMode: profileMode)
        let phraseLimit = profileMode
            ? Self.maximumProfileActivePhraseCharacters
            : Self.maximumActivePhraseCharacters
        let allowsMultiplePhrases = profileMode || backlogCharacters > 240
        var revealedCharacters = 0
        var madeProgress = false
        var newestPhraseText = ""
        var endedAtParagraphBoundary = false

        while hasPendingAtoms {
            if firstPendingAtom?.kind == .paragraphBreak {
                guard revealedCharacters < frameBudget || !madeProgress else { break }
                guard let separator = consumeFirstPendingAtom()?.text else { break }
                commitParagraph(separator: separator)
                revealedCharacters += separator.count
                madeProgress = true
                newestPhraseText = ""
                endedAtParagraphBoundary = true
                continue
            }

            let remainingBudget = max(1, frameBudget - revealedCharacters)
            let extractionLimit = min(phraseLimit, remainingBudget)
            guard let phraseText = consumeNextPhrase(maxCharacters: extractionLimit),
                  !phraseText.isEmpty else {
                break
            }

            installActivePhrase(phraseText)
            revealedCharacters += phraseText.count
            madeProgress = true
            newestPhraseText = phraseText
            endedAtParagraphBoundary = false

            if !allowsMultiplePhrases || revealedCharacters >= frameBudget { break }
        }

        guard madeProgress else { return nil }
        revision += 1
        lastPauseFrames = endedAtParagraphBoundary
            ? 1
            : pauseFrames(after: newestPhraseText)
        compactPendingAtomsIfNeeded()
        return makeSnapshot(
            cadence: cadence(forBacklog: backlogCharacters),
            pauseFrames: lastPauseFrames
        )
    }

    /// Reveals every buffered character in one publication while retaining a
    /// bounded final active phrase. Earlier phrases are committed directly to
    /// the current paragraph, so completion never asks the renderer to animate
    /// a giant provider burst.
    mutating func flush() -> LiveTranscriptSnapshot? {
        sealNewlineRunIfNeeded()
        sealPartialWordIfNeeded()

        guard hasPendingAtoms else {
            guard visibleCharacterCount > 0 else { return nil }
            lastPauseFrames = 0
            return makeSnapshot(cadence: .idle, pauseFrames: 0)
        }

        var madeProgress = false
        while hasPendingAtoms {
            if firstPendingAtom?.kind == .paragraphBreak {
                guard let separator = consumeFirstPendingAtom()?.text else { break }
                commitParagraph(separator: separator)
                madeProgress = true
                continue
            }

            guard let phraseText = consumeNextPhrase(
                maxCharacters: Self.maximumActivePhraseCharacters
            ), !phraseText.isEmpty else {
                break
            }
            installActivePhrase(phraseText)
            madeProgress = true
        }

        guard madeProgress else {
            return visibleCharacterCount == 0
                ? nil
                : makeSnapshot(cadence: .idle, pauseFrames: 0)
        }

        revision += 1
        lastPauseFrames = 0
        compactPendingAtomsIfNeeded()
        return makeSnapshot(cadence: .idle, pauseFrames: 0)
    }

    func currentSnapshot(profileMode _: Bool = false) -> LiveTranscriptSnapshot {
        makeSnapshot(
            cadence: cadence(forBacklog: backlogCharacters),
            pauseFrames: lastPauseFrames
        )
    }

    private mutating func ingest(_ character: Character) {
        if character.isTranscriptNewline {
            sealPartialWordIfNeeded()
            pendingNewlineRun.append(character)
            newlineHoldFrames = 0
            return
        }

        sealNewlineRunIfNeeded()

        if character.isTranscriptWhitespace {
            sealPartialWordIfNeeded()
            appendAtom(kind: .whitespace, text: String(character))
        } else if character.isTranscriptPunctuation {
            sealPartialWordIfNeeded()
            appendAtom(kind: .punctuation, text: String(character))
        } else {
            partialWord.append(character)
            partialWordHoldFrames = 0
            if partialWord.count >= maximumPartialWordCharacters {
                sealPartialWordIfNeeded(kind: .symbol)
            }
        }
    }

    private mutating func prepareReveal(forceMinimum _: Bool) {
        if !pendingNewlineRun.isEmpty {
            // Give a provider one display tick to deliver the second half of
            // a ragged "\n\n" paragraph delimiter. Already-buffered words can
            // still reveal during that tick.
            if newlineHoldFrames >= 1 {
                sealNewlineRunIfNeeded()
            } else {
                newlineHoldFrames += 1
            }
        }

        guard !hasPendingAtoms, !partialWord.isEmpty else { return }
        // A provider that pauses after a complete undelimited word should not
        // leave the typefield blank for several display frames. New chunks
        // reset this hold immediately, so ragged half-words still join before
        // anything is published.
        if partialWord.count >= maximumPartialWordCharacters || partialWordHoldFrames >= 1 {
            sealPartialWordIfNeeded()
        } else {
            partialWordHoldFrames += 1
        }
    }

    private mutating func sealPartialWordIfNeeded(kind: AtomKind = .word) {
        guard !partialWord.isEmpty else { return }
        appendAtom(kind: kind, text: partialWord)
        partialWord = ""
        partialWordHoldFrames = 0
    }

    private mutating func sealNewlineRunIfNeeded() {
        guard !pendingNewlineRun.isEmpty else { return }
        let kind: AtomKind = pendingNewlineRun.count >= 2 ? .paragraphBreak : .lineBreak
        appendAtom(kind: kind, text: pendingNewlineRun)
        pendingNewlineRun = ""
        newlineHoldFrames = 0
    }

    private mutating func appendAtom(kind: AtomKind, text: String) {
        guard !text.isEmpty else { return }
        let characterCount = text.count
        if hasPendingAtoms,
           let lastIndex = pendingAtoms.indices.last,
           pendingAtoms[lastIndex].kind == kind,
           kind == .whitespace {
            pendingAtoms[lastIndex].text += text
            pendingCharacterCount += characterCount
            return
        }
        pendingAtoms.append(Atom(kind: kind, text: text))
        pendingCharacterCount += characterCount
    }

    private mutating func consumeNextPhrase(maxCharacters: Int) -> String? {
        guard maxCharacters > 0, hasPendingAtoms else { return nil }
        var phrase = ""
        var shouldStopAfterWhitespace = false

        while let atom = firstPendingAtom {
            if atom.kind == .paragraphBreak { break }

            let atomCharacterCount = atom.text.count
            let isWordLike = atom.kind == .word || atom.kind == .symbol
            if !phrase.isEmpty,
               isWordLike,
               phrase.count + atomCharacterCount > maxCharacters {
                break
            }

            guard let consumed = consumeFirstPendingAtom() else { break }
            phrase += consumed.text

            if consumed.kind == .lineBreak {
                break
            }

            if consumed.kind == .punctuation,
               consumed.text.last.map(Self.isSemanticPhrasePunctuation) == true {
                shouldStopAfterWhitespace = true
                if firstPendingAtom?.kind != .whitespace {
                    break
                }
                continue
            }

            if shouldStopAfterWhitespace {
                break
            }

            if phrase.count >= maxCharacters,
               consumed.kind == .word || consumed.kind == .symbol {
                if firstPendingAtom?.kind == .whitespace,
                   let trailingWhitespace = consumeFirstPendingAtom() {
                    phrase += trailingWhitespace.text
                }
                break
            }
        }

        return phrase.isEmpty ? nil : phrase
    }

    private mutating func installActivePhrase(_ text: String) {
        guard !text.isEmpty else { return }
        commitActivePhrase()
        let phrase = LiveTranscriptSnapshot.Phrase(
            id: .init(
                responseID: responseID,
                paragraphOrdinal: activeParagraphOrdinal,
                ordinal: nextPhraseOrdinal
            ),
            ordinal: nextPhraseOrdinal,
            text: text
        )
        nextPhraseOrdinal += 1
        activePhrase = phrase
        rebalanceOversizedMarkdownTailAcrossActivePhraseIfNeeded()
        visibleCharacterCount += text.count
    }

    /// A closing Markdown delimiter can arrive in the active phrase while the
    /// oversized opening construct lives in `activeSettledTail`. Once the
    /// construct becomes whole, move its stable prefix into one frozen segment
    /// and leave only the genuinely new readable suffix active for dust.
    private mutating func rebalanceOversizedMarkdownTailAcrossActivePhraseIfNeeded() {
        guard activeSettledTail.count > Self.maximumActiveSettledTailCharacters,
              let activePhrase else { return }
        let combined = activeSettledTail + activePhrase.text
        let settledEnd = combined.index(
            combined.startIndex,
            offsetBy: activeSettledTail.count
        )
        let cut = settledSegmentBoundary(
            in: combined,
            preferredCharacterCount: Self.preferredSettledSegmentCharacters
        )
        guard cut > settledEnd else { return }

        let segmentText = String(combined[..<cut])
        let remainingActiveText = String(combined[cut...])
        activeSettledSegments.append(
            LiveTranscriptSnapshot.SettledSegment(
                id: .init(
                    responseID: responseID,
                    paragraphOrdinal: activeParagraphOrdinal,
                    ordinal: nextSettledSegmentOrdinal
                ),
                ordinal: nextSettledSegmentOrdinal,
                text: segmentText
            )
        )
        nextSettledSegmentOrdinal += 1
        activeSettledTail = ""
        awaitsKnownMarkdownBoundary = false
        self.activePhrase = remainingActiveText.isEmpty
            ? nil
            : LiveTranscriptSnapshot.Phrase(
                id: activePhrase.id,
                ordinal: activePhrase.ordinal,
                text: remainingActiveText
            )
    }

    private mutating func appendSettledPhrase(_ text: String) {
        guard !text.isEmpty else { return }
        commitActivePhrase()
        activeSettledTail += text
        freezeSettledTailIfNeeded()
        nextPhraseOrdinal += 1
        visibleCharacterCount += text.count
    }

    private mutating func commitActivePhrase() {
        guard let activePhrase else { return }
        activeSettledTail += activePhrase.text
        self.activePhrase = nil
        freezeSettledTailIfNeeded()
    }

    private mutating func commitParagraph(separator: String) {
        commitActivePhrase()
        let paragraph = LiveTranscriptSnapshot.Paragraph(
            id: .init(responseID: responseID, ordinal: activeParagraphOrdinal),
            ordinal: activeParagraphOrdinal,
            text: completeActiveSettledText(),
            trailingSeparator: separator
        )
        settledParagraphs.append(paragraph)
        visibleCharacterCount += separator.count
        activeParagraphOrdinal += 1
        activeSettledSegments.removeAll(keepingCapacity: true)
        activeSettledTail = ""
        nextSettledSegmentOrdinal = 0
        activePhrase = nil
        nextPhraseOrdinal = 0
        awaitsKnownMarkdownBoundary = false
    }

    /// Moves an older, semantically complete prefix into an immutable segment.
    /// The live Text leaf therefore has a hard layout bound while every source
    /// character remains visible in a stable sibling view.
    private mutating func freezeSettledTailIfNeeded() {
        while activeSettledTail.count > Self.maximumActiveSettledTailCharacters {
            var cut = settledSegmentBoundary(
                in: activeSettledTail,
                preferredCharacterCount: Self.preferredSettledSegmentCharacters
            )
            var fallbackPresentationText: String?
            if cut == activeSettledTail.startIndex {
                guard activeSettledTail.count > Self.maximumEmergencyActiveSettledTailCharacters else {
                    break
                }
                if awaitsKnownMarkdownBoundary || hasKnownMarkdownBoundaryAhead() {
                    awaitsKnownMarkdownBoundary = true
                    break
                }
                cut = emergencySettledSegmentBoundary(
                    in: activeSettledTail,
                    preferredCharacterCount: Self.preferredSettledSegmentCharacters
                )
                let source = String(activeSettledTail[..<cut])
                fallbackPresentationText = Self.literalFallbackPresentation(for: source)
            }
            guard cut > activeSettledTail.startIndex else { break }
            awaitsKnownMarkdownBoundary = false

            let segmentText = String(activeSettledTail[..<cut])
            activeSettledTail = String(activeSettledTail[cut...])
            activeSettledSegments.append(
                LiveTranscriptSnapshot.SettledSegment(
                    id: .init(
                        responseID: responseID,
                        paragraphOrdinal: activeParagraphOrdinal,
                        ordinal: nextSettledSegmentOrdinal
                    ),
                    ordinal: nextSettledSegmentOrdinal,
                    text: segmentText,
                    fallbackPresentationText: fallbackPresentationText
                )
            )
            nextSettledSegmentOrdinal += 1
        }
    }

    /// When a closing delimiter is already buffered nearby, give the valid
    /// construct a short grace window so it can freeze semantically whole. The
    /// lookahead is bounded and memoized by `awaitsKnownMarkdownBoundary`; an
    /// absent or very distant closure still takes the literal hard-cap path.
    private func hasKnownMarkdownBoundaryAhead() -> Bool {
        let lookaheadLimit = Self.knownMarkdownClosureLookaheadCharacters
        var lookahead = ""
        lookahead.reserveCapacity(lookaheadLimit)

        var atomIndex = pendingHead
        while atomIndex < pendingAtoms.count, lookahead.count < lookaheadLimit {
            let remaining = lookaheadLimit - lookahead.count
            let atomText = pendingAtoms[atomIndex].text
            lookahead += atomText.count <= remaining
                ? atomText
                : String(atomText.prefix(remaining))
            atomIndex += 1
        }
        guard !lookahead.isEmpty else { return false }

        let preview = activeSettledTail + lookahead
        let activeTailEnd = preview.index(
            preview.startIndex,
            offsetBy: activeSettledTail.count
        )
        let boundary = settledSegmentBoundary(
            in: preview,
            preferredCharacterCount: Self.preferredSettledSegmentCharacters
        )
        return boundary > activeTailEnd
    }

    /// The malformed-Markdown escape hatch still prefers a word boundary, but
    /// unlike the semantic splitter it is deliberately independent of delimiter
    /// state. It runs only after the emergency ceiling has been crossed.
    private func emergencySettledSegmentBoundary(
        in text: String,
        preferredCharacterCount: Int
    ) -> String.Index {
        let preferredCount = min(max(1, preferredCharacterCount), text.count)
        let preferredIndex = text.index(text.startIndex, offsetBy: preferredCount)
        let searchStart = text.index(
            text.startIndex,
            offsetBy: max(1, preferredCount - 160)
        )
        var candidate = preferredIndex
        while candidate > searchStart {
            candidate = text.index(before: candidate)
            guard text[candidate].isTranscriptWhitespace else { continue }
            return text.index(after: candidate)
        }
        return preferredIndex
    }

    /// Broken Markdown is no longer reparsed forever, and its unmatched control
    /// punctuation should not become the most visually prominent part of a long
    /// answer. Keep the provider source in `SettledSegment.text`, but present the
    /// emergency segment as readable literal prose/code.
    private static func literalFallbackPresentation(for source: String) -> String {
        var presentation = source
        if presentation.hasPrefix("```") {
            if let firstLineEnd = presentation.firstIndex(of: "\n") {
                presentation.removeSubrange(presentation.startIndex...firstLineEnd)
            } else {
                presentation.removeFirst(min(3, presentation.count))
            }
        }
        presentation = presentation.replacingOccurrences(of: "```", with: "")
        presentation = presentation.replacingOccurrences(of: "`", with: "")
        presentation = presentation.replacingOccurrences(of: "**", with: "")
        presentation = presentation.replacingOccurrences(of: "__", with: "")
        return presentation
    }

    private func settledSegmentBoundary(
        in text: String,
        preferredCharacterCount: Int
    ) -> String.Index {
        let markdownNeutralBoundaries = Self.markdownNeutralBoundaries(in: text)
        let preferredCount = min(max(1, preferredCharacterCount), text.count)
        let preferredIndex = text.index(text.startIndex, offsetBy: preferredCount)
        let semanticSearchStart = text.index(
            text.startIndex,
            offsetBy: max(0, preferredCount / 2)
        )

        var candidate = preferredIndex
        while candidate > semanticSearchStart {
            candidate = text.index(before: candidate)
            guard Self.isSettledSegmentBoundary(text[candidate]) else { continue }
            var cut = text.index(after: candidate)
            while cut < text.endIndex, text[cut].isTranscriptWhitespace {
                cut = text.index(after: cut)
            }
            if markdownNeutralBoundaries.contains(cut) {
                return cut
            }
        }

        let whitespaceSearchStart = text.index(
            text.startIndex,
            offsetBy: max(0, preferredCount - 120)
        )
        candidate = preferredIndex
        while candidate > whitespaceSearchStart {
            candidate = text.index(before: candidate)
            guard text[candidate].isTranscriptWhitespace else { continue }
            let cut = text.index(after: candidate)
            if markdownNeutralBoundaries.contains(cut) {
                return cut
            }
        }

        // A valid construct can begin before the preferred cut and close after
        // it. Once that closing delimiter arrives, freeze the first safe
        // boundary after the target instead of keeping the entire paragraph
        // mutable forever.
        candidate = preferredIndex
        while candidate < text.endIndex {
            if Self.isSettledSegmentBoundary(text[candidate]) || text[candidate].isTranscriptWhitespace {
                var cut = text.index(after: candidate)
                while cut < text.endIndex, text[cut].isTranscriptWhitespace {
                    cut = text.index(after: cut)
                }
                if markdownNeutralBoundaries.contains(cut) {
                    return cut
                }
            }
            candidate = text.index(after: candidate)
        }

        // Never make an immutable renderer segment in the middle of inline
        // code, emphasis, a link, or a fenced block. A rare oversized construct
        // may temporarily exceed the normal tail bound, but it will recover as
        // soon as the closing delimiter arrives instead of remaining visually
        // malformed for the lifetime of the transcript.
        return text.startIndex
    }

    private static func markdownNeutralBoundaries(in text: String) -> Set<String.Index> {
        var boundaries: Set<String.Index> = [text.startIndex]
        var index = text.startIndex
        var escaped = false
        var openBacktickRun = 0
        var asteriskDelimiterRuns = 0
        var underscoreDelimiterRuns = 0
        var bracketDepth = 0
        var linkDestinationDepth = 0
        var justClosedBracket = false

        func recordBoundary(_ boundary: String.Index) {
            if !escaped,
               openBacktickRun == 0,
               asteriskDelimiterRuns.isMultiple(of: 2),
               underscoreDelimiterRuns.isMultiple(of: 2),
               bracketDepth == 0,
               linkDestinationDepth == 0,
               !justClosedBracket {
                boundaries.insert(boundary)
            }
        }

        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
                justClosedBracket = false
                index = text.index(after: index)
                recordBoundary(index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = text.index(after: index)
                continue
            }

            if character == "`" {
                var end = index
                var runLength = 0
                while end < text.endIndex, text[end] == "`" {
                    runLength += 1
                    end = text.index(after: end)
                }
                if openBacktickRun == 0 {
                    openBacktickRun = runLength
                } else if runLength == openBacktickRun {
                    openBacktickRun = 0
                }
                justClosedBracket = false
                index = end
                recordBoundary(index)
                continue
            }

            // Markdown inside code spans is literal. Do not let punctuation in
            // source code alter the surrounding delimiter state.
            if openBacktickRun > 0 {
                index = text.index(after: index)
                continue
            }

            if character == "*" || character == "_" {
                var end = index
                var runLength = 0
                while end < text.endIndex, text[end] == character {
                    runLength += 1
                    end = text.index(after: end)
                }
                if character == "*" {
                    asteriskDelimiterRuns += 1
                } else if runLength >= 2 {
                    // Single underscores are common in filenames and symbols;
                    // double underscores are a much stronger emphasis signal.
                    underscoreDelimiterRuns += 1
                }
                justClosedBracket = false
                index = end
                recordBoundary(index)
                continue
            }

            if character == "[" {
                bracketDepth += 1
                justClosedBracket = false
            } else if character == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                justClosedBracket = true
            } else if character == "(", justClosedBracket || linkDestinationDepth > 0 {
                linkDestinationDepth += 1
                justClosedBracket = false
            } else if character == ")", linkDestinationDepth > 0 {
                linkDestinationDepth -= 1
                justClosedBracket = false
            } else if !character.isTranscriptWhitespace {
                justClosedBracket = false
            }

            index = text.index(after: index)
            recordBoundary(index)
        }

        return boundaries
    }

    private func completeActiveSettledText() -> String {
        var text = activeSettledSegments.reduce(into: "") { partial, segment in
            partial += segment.text
        }
        text += activeSettledTail
        return text
    }

    private func makeSnapshot(
        cadence: LiveTranscriptSnapshot.Cadence,
        pauseFrames: Int
    ) -> LiveTranscriptSnapshot {
        LiveTranscriptSnapshot(
            responseID: responseID,
            settledParagraphs: settledParagraphs,
            activeParagraph: .init(
                id: .init(responseID: responseID, ordinal: activeParagraphOrdinal),
                ordinal: activeParagraphOrdinal,
                settledSegments: activeSettledSegments,
                settledTail: activeSettledTail,
                activePhrase: activePhrase
            ),
            characterCount: visibleCharacterCount,
            backlogCharacters: backlogCharacters,
            revision: revision,
            cadence: cadence,
            suggestedPauseFrames: pauseFrames
        )
    }

    private func revealCharacterBudget(profileMode: Bool) -> Int {
        if profileMode { return min(420, max(120, backlogCharacters)) }
        switch backlogCharacters {
        case 0...80:
            return 14
        case 81...240:
            return 24
        case 241...720:
            return 42
        case 721...1_800:
            return 72
        default:
            return 116
        }
    }

    private func cadence(forBacklog backlog: Int) -> LiveTranscriptSnapshot.Cadence {
        switch backlog {
        case 0:
            return .idle
        case 1...240:
            return .reading
        case 241...1_200:
            return .catchingUp
        default:
            return .burst
        }
    }

    private func pauseFrames(after phrase: String) -> Int {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else {
            return phrase.contains(where: { $0.isTranscriptNewline }) ? 1 : 0
        }
        if ".!?\u{2026}\u{3002}\u{FF01}\u{FF1F}".contains(last) { return 2 }
        if ",;:\u{2014}".contains(last) { return 1 }
        if phrase.last?.isTranscriptNewline == true { return 1 }
        return 0
    }

    private static func isSemanticPhrasePunctuation(_ character: Character) -> Bool {
        ",;:.!?\u{2014}\u{2026}\u{3002}\u{FF01}\u{FF1F}".contains(character)
    }

    private static func isSettledSegmentBoundary(_ character: Character) -> Bool {
        character.isTranscriptNewline || ".!?\u{2026}\u{3002}\u{FF01}\u{FF1F}".contains(character)
    }

    private var hasPendingAtoms: Bool {
        pendingHead < pendingAtoms.count
    }

    private var firstPendingAtom: Atom? {
        guard hasPendingAtoms else { return nil }
        return pendingAtoms[pendingHead]
    }

    @discardableResult
    private mutating func consumeFirstPendingAtom() -> Atom? {
        guard hasPendingAtoms else { return nil }
        let atom = pendingAtoms[pendingHead]
        pendingHead += 1
        pendingCharacterCount -= atom.text.count
        return atom
    }

    private mutating func compactPendingAtomsIfNeeded() {
        if pendingHead == pendingAtoms.count {
            pendingAtoms.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 256, pendingHead * 2 >= pendingAtoms.count {
            pendingAtoms = Array(pendingAtoms[pendingHead...])
            pendingHead = 0
        }
    }

    /// If a provider outruns the display clock, settle the oldest semantic
    /// phrases without animation. This keeps the unread queue bounded while
    /// reserving the newest phrase for the materialization renderer.
    private mutating func compactPendingBacklogIfNeeded() {
        guard backlogCharacters > Self.pendingBacklogCharacterLimit else { return }
        sealNewlineRunIfNeeded()
        sealPartialWordIfNeeded(kind: .symbol)

        var madeProgress = false
        while backlogCharacters > Self.pendingBacklogCharacterTarget, hasPendingAtoms {
            if firstPendingAtom?.kind == .paragraphBreak {
                guard let separator = consumeFirstPendingAtom()?.text else { break }
                commitParagraph(separator: separator)
                madeProgress = true
                continue
            }

            guard let phraseText = consumeNextPhrase(
                maxCharacters: Self.maximumActivePhraseCharacters
            ), !phraseText.isEmpty else {
                break
            }
            appendSettledPhrase(phraseText)
            madeProgress = true
        }

        if madeProgress {
            revision += 1
            lastPauseFrames = 0
        }
        compactPendingAtomsIfNeeded()
    }
}

private extension Character {
    var isTranscriptNewline: Bool {
        !unicodeScalars.isEmpty && unicodeScalars.allSatisfy { CharacterSet.newlines.contains($0) }
    }

    var isTranscriptWhitespace: Bool {
        !unicodeScalars.isEmpty && unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    var isTranscriptPunctuation: Bool {
        !unicodeScalars.isEmpty && unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }
}
