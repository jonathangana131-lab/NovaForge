import Foundation

/// A display-paced, word-tree renderer for live assistant text.
///
/// Provider streams arrive as arbitrary network chunks. Showing those chunks
/// directly makes SwiftUI reflow partial words and punctuation at unpredictable
/// points, which reads as jitter on iPhone. This engine normalizes raw deltas
/// into stable semantic atoms first, then publishes whole word/phrase frames on
/// a steady cadence. The UI gets a settled prefix plus a small active tail, so
/// only the currently spoken phrase feels live while earlier text stays calm.
struct ForgeLiveFeedFrame: Equatable, Sendable {
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
        let suffix = readableSuffix(maxCharacters: maxCharacters)
        let windowedText = "…\n" + suffix
        let windowedTail: String
        if !activeTail.isEmpty, windowedText.hasSuffix(activeTail) {
            windowedTail = activeTail
        } else if !activeTail.isEmpty, suffix.hasSuffix(activeTail) {
            windowedTail = activeTail
        } else if !activeTail.isEmpty {
            windowedTail = String(activeTail.suffix(min(activeTail.count, suffix.count)))
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

    private func readableSuffix(maxCharacters: Int) -> String {
        guard displayText.count > maxCharacters else { return displayText }
        let start = displayText.index(displayText.endIndex, offsetBy: -maxCharacters)
        var suffix = String(displayText[start...])
        guard start > displayText.startIndex else { return suffix }

        if let boundary = suffix.firstIndex(where: { character in
            character.isLiveFeedWhitespace || character.isLiveFeedPunctuation
        }) {
            let next = suffix.index(after: boundary)
            if next < suffix.endIndex {
                suffix = String(suffix[next...])
            }
        }

        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(displayText.suffix(maxCharacters)) : trimmed
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
        var id: Int
        var kind: AtomKind
        var text: String
    }

    private var visibleText = ""
    private var pendingAtoms: [Atom] = []
    private var partialWord = ""
    private var nextAtomID = 0
    private var visibleAtomCount = 0
    private var revision = 0
    private var lastActiveTail = ""
    private var lastPauseFrames = 0
    private var partialWordHoldFrames = 0

    private let maxPartialWordCharacters = 24
    private let activeTailCharacterLimit = 48

    var isEmpty: Bool {
        visibleText.isEmpty && pendingAtoms.isEmpty && partialWord.isEmpty
    }

    var hasPendingReveal: Bool {
        !pendingAtoms.isEmpty || !partialWord.isEmpty
    }

    var backlogCharacters: Int {
        pendingAtoms.reduce(partialWord.count) { total, atom in total + atom.text.count }
    }

    mutating func reset() {
        visibleText = ""
        pendingAtoms = []
        partialWord = ""
        nextAtomID = 0
        visibleAtomCount = 0
        revision = 0
        lastActiveTail = ""
        lastPauseFrames = 0
        partialWordHoldFrames = 0
    }

    mutating func ingest(_ delta: String) {
        guard !delta.isEmpty else { return }
        for character in delta {
            ingest(character)
        }
    }

    mutating func revealNextFrame(forceMinimum: Bool, profileMode: Bool) -> ForgeLiveFeedFrame? {
        prepareReveal(forceMinimum: forceMinimum)
        guard !pendingAtoms.isEmpty else { return nil }

        let targetBudget = revealCharacterBudget(profileMode: profileMode)
        var revealed = ""
        var lastKind: AtomKind = .word
        var revealedAtomCount = 0

        while !pendingAtoms.isEmpty {
            let atom = pendingAtoms[0]
            let wouldExceedBudget = !revealed.isEmpty && revealed.count + atom.text.count > targetBudget
            let shouldCarryTrailingSmallToken = atom.kind == .whitespace || atom.kind == .punctuation || atom.kind == .newline
            if wouldExceedBudget && !shouldCarryTrailingSmallToken { break }

            pendingAtoms.removeFirst()
            revealed += atom.text
            lastKind = atom.kind
            revealedAtomCount += 1

            if revealed.count >= targetBudget,
               atom.kind == .word || atom.kind == .newline {
                break
            }
        }

        guard !revealed.isEmpty else { return nil }
        visibleText += revealed
        visibleAtomCount += revealedAtomCount
        revision += 1
        lastActiveTail = Self.makeActiveTail(from: revealed, limit: activeTailCharacterLimit)
        lastPauseFrames = pauseFrames(after: lastKind, revealedText: revealed)
        return makeFrame(cadence: cadence(forBacklog: backlogCharacters), pauseFrames: lastPauseFrames, profileMode: profileMode)
    }

    mutating func flush() -> ForgeLiveFeedFrame? {
        sealPartialWordIfNeeded()
        guard !pendingAtoms.isEmpty else {
            return visibleText.isEmpty ? nil : makeFrame(cadence: .idle, pauseFrames: 0)
        }
        let revealed = pendingAtoms.map(\.text).joined()
        visibleText += revealed
        visibleAtomCount += pendingAtoms.count
        pendingAtoms.removeAll(keepingCapacity: true)
        partialWordHoldFrames = 0
        revision += 1
        lastActiveTail = Self.makeActiveTail(from: revealed, limit: activeTailCharacterLimit)
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
        if let last = pendingAtoms.indices.last,
           pendingAtoms[last].kind == kind,
           kind == .whitespace {
            pendingAtoms[last].text += text
            return
        }
        pendingAtoms.append(Atom(id: nextAtomID, kind: kind, text: text))
        nextAtomID += 1
    }

    private mutating func prepareReveal(forceMinimum _: Bool) {
        guard pendingAtoms.isEmpty, !partialWord.isEmpty else { return }
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

    private func makeFrame(cadence: ForgeLiveFeedFrame.Cadence, pauseFrames: Int, profileMode: Bool = false) -> ForgeLiveFeedFrame {
        let displayText = Self.liveDisplayWindow(visibleText, profileMode: profileMode)
        let activeTail = displayText.hasSuffix(lastActiveTail) ? lastActiveTail : ""
        return ForgeLiveFeedFrame(
            displayText: displayText,
            settledText: Self.settledPrefix(displayText: displayText, activeTail: activeTail),
            activeTail: activeTail,
            characterCount: visibleText.count,
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

    private static func liveDisplayWindow(_ text: String, profileMode: Bool) -> String {
        guard profileMode, text.count > 640 else { return text }
        return "…" + String(text.suffix(640))
    }

    private static func settledPrefix(displayText: String, activeTail: String) -> String {
        guard !activeTail.isEmpty, displayText.hasSuffix(activeTail) else { return displayText }
        let end = displayText.index(displayText.endIndex, offsetBy: -activeTail.count)
        return String(displayText[..<end])
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
