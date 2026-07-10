import Foundation

/// A display-paced, word-tree renderer for live assistant text.
///
/// Provider streams arrive as arbitrary network chunks. Showing those chunks
/// directly makes SwiftUI reflow partial words and punctuation at unpredictable
/// points, which reads as jitter on iPhone. This engine normalizes raw deltas
/// into stable semantic atoms first, then publishes whole word/phrase frames on
/// a steady cadence. The UI gets a stable opening, an explicit middle omission,
/// and a small active tail, so the answer remains readable without continually
/// laying out the complete in-flight transcript.
struct ForgeLiveFeedFrame: Equatable, Sendable {
    static let middleOmissionMarker = "\n\n⋯ middle omitted while response streams ⋯\n\n"

    enum Cadence: String, Sendable {
        case idle
        case reading
        case catchingUp
        case burst

        var label: String {
            switch self {
            case .idle: "Idle"
            case .reading: "Reading"
            case .catchingUp: "Catching up"
            case .burst: "Burst sync"
            }
        }
    }

    static let empty = ForgeLiveFeedFrame(
        displayText: "",
        settledText: "",
        activeTail: "",
        characterCount: 0,
        visibleAtomCount: 0,
        backlogCharacters: 0,
        revision: 0,
        cadence: .idle,
        suggestedPauseFrames: 0,
        isShowingTail: false
    )

    var displayText: String
    var settledText: String
    var activeTail: String
    var characterCount: Int
    var visibleAtomCount: Int
    var backlogCharacters: Int
    var revision: Int
    var cadence: Cadence
    var suggestedPauseFrames: Int
    var isShowingTail: Bool

    var statusLine: String {
        switch cadence {
        case .idle:
            "Preparing response"
        case .reading:
            "Writing answer…"
        case .catchingUp, .burst:
            "Catching up…"
        }
    }

    func windowed(maxCharacters: Int) -> ForgeLiveFeedFrame {
        guard maxCharacters > 0, displayText.count > maxCharacters else { return self }
        let marker = Self.middleOmissionMarker
        let windowedText: String

        if maxCharacters > marker.count + 2 {
            let contentBudget = maxCharacters - marker.count
            let targetPrefixBudget = max(1, contentBudget * 2 / 5)
            let prefix = readablePrefix(maxCharacters: targetPrefixBudget)
            let tailBudget = max(1, contentBudget - prefix.count)
            let suffix = readableSuffix(
                maxCharacters: tailBudget,
                protectingSuffixCharacters: min(activeTail.count, tailBudget)
            )
            windowedText = prefix + marker + suffix
        } else {
            // Degenerate callers still get a hard bound and the newest text.
            // Product surfaces use budgets large enough for the descriptive
            // marker and both readable sides.
            let suffixBudget = max(0, maxCharacters - 1)
            windowedText = "…" + String(displayText.suffix(suffixBudget))
        }

        let windowedTail: String
        if !activeTail.isEmpty, windowedText.hasSuffix(activeTail) {
            windowedTail = activeTail
        } else if !activeTail.isEmpty {
            let matchingTail = String(activeTail.suffix(min(activeTail.count, windowedText.count)))
            windowedTail = windowedText.hasSuffix(matchingTail) ? matchingTail : ""
        } else {
            windowedTail = ""
        }
        let settledEnd = windowedText.index(windowedText.endIndex, offsetBy: -windowedTail.count, limitedBy: windowedText.startIndex) ?? windowedText.endIndex
        return ForgeLiveFeedFrame(
            displayText: windowedText,
            settledText: String(windowedText[..<settledEnd]),
            activeTail: windowedTail,
            characterCount: characterCount,
            visibleAtomCount: visibleAtomCount,
            backlogCharacters: backlogCharacters,
            revision: revision,
            cadence: cadence,
            suggestedPauseFrames: suggestedPauseFrames,
            isShowingTail: true
        )
    }

    private func readablePrefix(maxCharacters: Int) -> String {
        guard displayText.count > maxCharacters else { return displayText }
        var prefix = String(displayText.prefix(maxCharacters))

        // Prefer a nearby complete word/sentence without sacrificing a large
        // part of the stable opening merely because it contains short words.
        let boundarySearchCount = min(48, max(0, prefix.count / 3))
        guard boundarySearchCount > 0 else { return prefix }
        let searchStart = prefix.index(prefix.endIndex, offsetBy: -boundarySearchCount)
        if let boundary = prefix[searchStart...].lastIndex(where: { character in
            character.isLiveFeedWhitespace || character.isLiveFeedPunctuation
        }) {
            prefix = String(prefix[...boundary])
        }
        return prefix
    }

    private func readableSuffix(maxCharacters: Int, protectingSuffixCharacters: Int = 0) -> String {
        guard displayText.count > maxCharacters else { return displayText }
        let start = displayText.index(displayText.endIndex, offsetBy: -maxCharacters)
        var suffix = String(displayText[start...])
        guard start > displayText.startIndex else { return suffix }

        let removableCount = max(0, suffix.count - protectingSuffixCharacters)
        let boundarySearchCount = min(48, removableCount)
        let searchEnd = suffix.index(suffix.startIndex, offsetBy: boundarySearchCount)
        if let boundary = suffix[..<searchEnd].firstIndex(where: { character in
            character.isLiveFeedWhitespace || character.isLiveFeedPunctuation
        }) {
            let next = suffix.index(after: boundary)
            if next < suffix.endIndex {
                suffix = String(suffix[next...])
            }
        }

        // Do not trim the trailing edge: it may be part of `activeTail`, and
        // preserving that exact suffix keeps the calm/active attributed split
        // coherent even when a reveal frame lands on whitespace.
        return suffix
    }
}

struct ForgeLiveFeedEngine: Sendable {
    private enum AtomKind: Sendable {
        case word
        case whitespace
        case punctuation
        case newline
        case symbol
    }

    private struct Atom: Equatable, Sendable {
        var kind: AtomKind
        var text: String
    }

    private var visibleText = ""
    private var retainedVisibleCharacterCount = 0
    private var didTrimVisibleText = false
    private var pendingAtoms: [Atom] = []
    private var pendingHead = 0
    private var pendingCharacterCount = 0
    private var partialWord = ""
    private var visibleCharacterCount = 0
    private var visibleAtomCount = 0
    private var revision = 0
    private var lastActiveTail = ""
    private var lastPauseFrames = 0
    private var partialWordHoldFrames = 0
    private var retainedStablePrefix = ""
    private var retainedStablePrefixCharacterCount = 0

    private let maxPartialWordCharacters = 24
    private let activeTailCharacterLimit = 48
    /// The durable assistant message owns the full transcript. The live feed
    /// keeps a stable opening plus a generous recent tail. Both are bounded;
    /// trimming happens in chunks to avoid copying an ever-growing transcript
    /// on every display frame.
    private let retainedStablePrefixLimit = 1_536
    private let retainedVisibleCharacterTarget = 8_192
    private let retainedVisibleCharacterLimit = 12_288
    /// Network delivery can outrun the display cadence by many seconds. Keep
    /// the unread word tree bounded too, then fast-forward its oldest portion
    /// into the same stable-prefix + recent-tail representation used on screen.
    static let pendingBacklogCharacterTarget = 8_192
    static let pendingBacklogCharacterLimit = 12_288

    var retainedPendingAtomCount: Int {
        max(0, pendingAtoms.count - pendingHead)
    }

    var isEmpty: Bool {
        visibleCharacterCount == 0 && !hasPendingAtoms && partialWord.isEmpty
    }

    var hasPendingReveal: Bool {
        hasPendingAtoms || !partialWord.isEmpty
    }

    var backlogCharacters: Int {
        pendingCharacterCount + partialWord.count
    }

    mutating func reset() {
        visibleText = ""
        retainedVisibleCharacterCount = 0
        didTrimVisibleText = false
        pendingAtoms = []
        pendingHead = 0
        pendingCharacterCount = 0
        partialWord = ""
        visibleCharacterCount = 0
        visibleAtomCount = 0
        revision = 0
        lastActiveTail = ""
        lastPauseFrames = 0
        partialWordHoldFrames = 0
        retainedStablePrefix = ""
        retainedStablePrefixCharacterCount = 0
    }

    mutating func ingest(_ delta: String) {
        guard !delta.isEmpty else { return }
        for character in delta {
            ingest(character)
        }
        compactPendingBacklogIfNeeded()
    }

    mutating func revealNextFrame(forceMinimum: Bool, profileMode: Bool) -> ForgeLiveFeedFrame? {
        prepareReveal(forceMinimum: forceMinimum)
        guard hasPendingAtoms else { return nil }

        let targetBudget = revealCharacterBudget(profileMode: profileMode)
        var revealed = ""
        var revealedCharacterCount = 0
        var lastKind: AtomKind = .word
        var revealedAtomCount = 0

        while let atom = firstPendingAtom {
            let atomCharacterCount = atom.text.count
            let wouldExceedBudget = !revealed.isEmpty && revealedCharacterCount + atomCharacterCount > targetBudget
            let shouldCarryTrailingSmallToken = atom.kind == .whitespace || atom.kind == .punctuation || atom.kind == .newline
            if wouldExceedBudget && !shouldCarryTrailingSmallToken { break }

            consumeFirstPendingAtom(characterCount: atomCharacterCount)
            revealed += atom.text
            revealedCharacterCount += atomCharacterCount
            lastKind = atom.kind
            revealedAtomCount += 1

            if revealedCharacterCount >= targetBudget,
               atom.kind == .word || atom.kind == .newline {
                break
            }
        }

        guard !revealed.isEmpty else { return nil }
        appendVisibleText(revealed, characterCount: revealedCharacterCount)
        visibleCharacterCount += revealedCharacterCount
        visibleAtomCount += revealedAtomCount
        revision += 1
        lastActiveTail = Self.makeActiveTail(from: revealed, limit: activeTailCharacterLimit)
        lastPauseFrames = pauseFrames(after: lastKind, revealedText: revealed)
        compactPendingAtomsIfNeeded()
        return makeFrame(cadence: cadence(forBacklog: backlogCharacters), pauseFrames: lastPauseFrames, profileMode: profileMode)
    }

    mutating func flush() -> ForgeLiveFeedFrame? {
        sealPartialWordIfNeeded()
        guard hasPendingAtoms else {
            return visibleCharacterCount == 0 ? nil : makeFrame(cadence: .idle, pauseFrames: 0)
        }
        let revealedAtomCount = pendingAtoms.count - pendingHead
        let revealedCharacterCount = pendingCharacterCount
        var revealedTail = ""
        for atom in pendingAtoms[pendingHead...] {
            let atomCharacterCount = atom.text.count
            appendVisibleText(atom.text, characterCount: atomCharacterCount)
            revealedTail += atom.text
            if revealedTail.count > activeTailCharacterLimit * 2 {
                revealedTail = String(revealedTail.suffix(activeTailCharacterLimit))
            }
        }
        visibleCharacterCount += revealedCharacterCount
        visibleAtomCount += revealedAtomCount
        pendingAtoms.removeAll(keepingCapacity: true)
        pendingHead = 0
        pendingCharacterCount = 0
        partialWordHoldFrames = 0
        revision += 1
        lastActiveTail = Self.makeActiveTail(from: revealedTail, limit: activeTailCharacterLimit)
        lastPauseFrames = 0
        return makeFrame(cadence: .idle, pauseFrames: 0)
    }

    func currentFrame(profileMode: Bool = false) -> ForgeLiveFeedFrame {
        makeFrame(cadence: cadence(forBacklog: backlogCharacters), pauseFrames: lastPauseFrames, profileMode: profileMode)
    }

    private mutating func ingest(_ character: Character) {
        if character.isLiveFeedNewline {
            sealPartialWordIfNeeded()
            appendAtom(kind: .newline, text: "\n")
        } else if character.isLiveFeedWhitespace {
            sealPartialWordIfNeeded()
            appendAtom(kind: .whitespace, text: String(character))
        } else if character.isLiveFeedPunctuation {
            sealPartialWordIfNeeded()
            appendAtom(kind: .punctuation, text: String(character))
        } else {
            partialWord.append(character)
            partialWordHoldFrames = 0
            if partialWord.count >= maxPartialWordCharacters {
                sealPartialWordIfNeeded(kind: .symbol)
            }
        }
    }

    private mutating func appendAtom(kind: AtomKind, text: String) {
        guard !text.isEmpty else { return }
        let characterCount = text.count
        if hasPendingAtoms,
           let last = pendingAtoms.indices.last,
           pendingAtoms[last].kind == kind,
           kind == .whitespace {
            pendingAtoms[last].text += text
            pendingCharacterCount += characterCount
            return
        }
        pendingAtoms.append(Atom(kind: kind, text: text))
        pendingCharacterCount += characterCount
    }

    private mutating func prepareReveal(forceMinimum _: Bool) {
        guard !hasPendingAtoms, !partialWord.isEmpty else { return }
        if partialWord.count >= maxPartialWordCharacters || partialWordHoldFrames >= 3 {
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

    private mutating func appendVisibleText(_ text: String, characterCount: Int) {
        guard !text.isEmpty else { return }
        if retainedStablePrefixCharacterCount < retainedStablePrefixLimit {
            let remaining = retainedStablePrefixLimit - retainedStablePrefixCharacterCount
            let stableAddition = String(text.prefix(remaining))
            retainedStablePrefix += stableAddition
            retainedStablePrefixCharacterCount += stableAddition.count
        }
        visibleText += text
        retainedVisibleCharacterCount += characterCount
        guard retainedVisibleCharacterCount > retainedVisibleCharacterLimit else { return }
        visibleText = String(visibleText.suffix(retainedVisibleCharacterTarget))
        retainedVisibleCharacterCount = retainedVisibleCharacterTarget
        didTrimVisibleText = true
    }

    private func makeFrame(cadence: ForgeLiveFeedFrame.Cadence, pauseFrames: Int, profileMode _: Bool = false) -> ForgeLiveFeedFrame {
        let displayText = didTrimVisibleText
            ? retainedStablePrefix + ForgeLiveFeedFrame.middleOmissionMarker + visibleText
            : visibleText
        let activeTail = displayText.hasSuffix(lastActiveTail) ? lastActiveTail : ""
        return ForgeLiveFeedFrame(
            displayText: displayText,
            settledText: Self.settledPrefix(displayText: displayText, activeTail: activeTail),
            activeTail: activeTail,
            characterCount: visibleCharacterCount,
            visibleAtomCount: visibleAtomCount,
            backlogCharacters: backlogCharacters,
            revision: revision,
            cadence: cadence,
            suggestedPauseFrames: pauseFrames,
            isShowingTail: false
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

    private func cadence(forBacklog backlog: Int) -> ForgeLiveFeedFrame.Cadence {
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

    private func pauseFrames(after kind: AtomKind, revealedText: String) -> Int {
        guard let last = revealedText.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return kind == .newline ? 1 : 0
        }
        if kind == .newline { return 1 }
        if ",;:".contains(last) { return 1 }
        if ".!?".contains(last) { return 2 }
        return 0
    }

    private static func makeActiveTail(from text: String, limit: Int) -> String {
        let trimmedTrailingNewline = text.trimmingCharacters(in: .newlines)
        guard !trimmedTrailingNewline.isEmpty else { return "" }
        if trimmedTrailingNewline.count <= limit { return trimmedTrailingNewline }
        return String(trimmedTrailingNewline.suffix(limit))
    }

    private static func settledPrefix(displayText: String, activeTail: String) -> String {
        guard !activeTail.isEmpty, displayText.hasSuffix(activeTail) else { return displayText }
        let end = displayText.index(displayText.endIndex, offsetBy: -activeTail.count)
        return String(displayText[..<end])
    }

    private var hasPendingAtoms: Bool {
        pendingHead < pendingAtoms.count
    }

    private var firstPendingAtom: Atom? {
        guard hasPendingAtoms else { return nil }
        return pendingAtoms[pendingHead]
    }

    private mutating func consumeFirstPendingAtom(characterCount: Int) {
        pendingHead += 1
        pendingCharacterCount -= characterCount
    }

    /// Keep queue consumption O(1) per atom. Occasionally copy only the live
    /// suffix so a long response does not retain an ever-growing consumed
    /// prefix; this makes total compaction work amortized linear.
    private mutating func compactPendingAtomsIfNeeded() {
        if pendingHead == pendingAtoms.count {
            pendingAtoms.removeAll(keepingCapacity: true)
            pendingHead = 0
        } else if pendingHead >= 256, pendingHead * 2 >= pendingAtoms.count {
            pendingAtoms = Array(pendingAtoms[pendingHead...])
            pendingHead = 0
        }
    }

    /// Fast-forward a bounded chunk of unread atoms when a provider delivers
    /// faster than the frame clock. This preserves exact character accounting
    /// and a readable opening/tail without allocating an unbounded pending
    /// word tree or forcing a giant final-frame flush on the MainActor.
    private mutating func compactPendingBacklogIfNeeded() {
        guard backlogCharacters > Self.pendingBacklogCharacterLimit else { return }
        sealPartialWordIfNeeded()
        guard pendingCharacterCount > Self.pendingBacklogCharacterLimit else { return }

        var compactedParts: [String] = []
        var compactedCharacters = 0
        var compactedAtoms = 0
        while pendingCharacterCount > Self.pendingBacklogCharacterTarget,
              let atom = firstPendingAtom {
            let characterCount = atom.text.count
            consumeFirstPendingAtom(characterCount: characterCount)
            compactedParts.append(atom.text)
            compactedCharacters += characterCount
            compactedAtoms += 1
        }
        guard compactedCharacters > 0 else { return }

        let compactedText = compactedParts.joined()
        appendVisibleText(compactedText, characterCount: compactedCharacters)
        visibleCharacterCount += compactedCharacters
        visibleAtomCount += compactedAtoms
        revision += 1
        lastActiveTail = Self.makeActiveTail(from: compactedText, limit: activeTailCharacterLimit)
        lastPauseFrames = 0
        compactPendingAtomsIfNeeded()
    }
}

private extension Character {
    var isLiveFeedNewline: Bool {
        unicodeScalars.allSatisfy { CharacterSet.newlines.contains($0) }
    }

    var isLiveFeedWhitespace: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }

    var isLiveFeedPunctuation: Bool {
        guard unicodeScalars.count == 1, let scalar = unicodeScalars.first else { return false }
        if CharacterSet.punctuationCharacters.contains(scalar) { return true }
        return "—–…•·".unicodeScalars.contains(scalar)
    }
}
