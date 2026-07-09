import Foundation

struct AIStreamDisplayEngine: Sendable {
    private var builder: AIStreamDocumentBuilder
    private(set) var currentDocument: AIStreamDocument
    private(set) var metrics: Metrics
    let configuration: Configuration

    private var lastEmissionDate: Date?
    private(set) var hasPendingUIUpdate: Bool

    var durableText: String { builder.completeText }

    init(configuration: Configuration = .init(), builder: AIStreamDocumentBuilder = AIStreamDocumentBuilder()) {
        self.configuration = configuration.normalized
        self.builder = builder
        self.currentDocument = builder.document
        self.metrics = Metrics()
        self.lastEmissionDate = nil
        self.hasPendingUIUpdate = false
    }

    @discardableResult
    mutating func consume(_ event: AIStreamEvent, at date: Date? = nil) -> AIStreamDisplayUpdate? {
        metrics.acceptedEventCount += 1
        let now = date ?? event.date
        currentDocument = builder.apply(event)
        metrics.durableCharacterCount = builder.completeText.count

        let reason = Self.reason(for: event.kind)
        if reason.isTerminal || reason == .started {
            return emit(at: now, reason: reason)
        }

        return emitIfCadenceAllows(at: now, reason: reason)
    }

    @discardableResult
    mutating func tick(at date: Date = Date()) -> AIStreamDisplayUpdate? {
        guard hasPendingUIUpdate else { return nil }
        return emitIfCadenceAllows(at: date, reason: .cadence)
    }

    @discardableResult
    mutating func flush(at date: Date = Date()) -> AIStreamDisplayUpdate? {
        guard hasPendingUIUpdate else { return nil }
        return emit(at: date, reason: .flush)
    }

    @discardableResult
    mutating func cancel() -> AIStreamDisplayUpdate {
        builder.reset()
        currentDocument = .empty
        hasPendingUIUpdate = false
        lastEmissionDate = nil
        metrics = Metrics()
        return AIStreamDisplayUpdate(document: currentDocument, date: Date(), reason: .cancelled, metrics: metrics)
    }

    private mutating func emitIfCadenceAllows(at date: Date, reason: AIStreamDisplayUpdateReason) -> AIStreamDisplayUpdate? {
        if shouldEmit(at: date) {
            return emit(at: date, reason: reason)
        }
        hasPendingUIUpdate = true
        metrics.suppressedUpdateCount += 1
        metrics.pendingChangeCount += 1
        return nil
    }

    private func shouldEmit(at date: Date) -> Bool {
        guard let lastEmissionDate else { return true }
        return date.timeIntervalSince(lastEmissionDate) >= configuration.minimumUpdateInterval
    }

    private mutating func emit(at date: Date, reason: AIStreamDisplayUpdateReason) -> AIStreamDisplayUpdate {
        let previousEmissionDate = lastEmissionDate
        lastEmissionDate = date
        hasPendingUIUpdate = false
        metrics.pendingChangeCount = 0
        metrics.emittedSnapshotCount += 1
        metrics.lastEmissionInterval = previousEmissionDate.map { date.timeIntervalSince($0) }
        let update = AIStreamDisplayUpdate(document: currentDocument, date: date, reason: reason, metrics: metrics)
        return update
    }

    private static func reason(for kind: AIStreamEventKind) -> AIStreamDisplayUpdateReason {
        switch kind {
        case .connecting:
            return .started
        case .responseStarted:
            return .started
        case .completed, .failed:
            return .terminal
        case .waitingForApproval:
            return .status
        case .toolStarted, .toolFinished, .artifactReady:
            return .status
        case .textDelta, .sentenceCompleted, .paragraphCompleted:
            return .text
        }
    }
}

extension AIStreamDisplayEngine {
    struct Configuration: Equatable, Sendable {
        var minimumUpdateInterval: TimeInterval = 1.0 / 18.0
        var reducedMotion: Bool = false
        var performanceMode: Bool = false
        var maxAnimatedGlyphs: Int = 96

        var normalized: Configuration {
            var copy = self
            if copy.minimumUpdateInterval < 0 { copy.minimumUpdateInterval = 0 }
            if copy.performanceMode {
                copy.maxAnimatedGlyphs = min(copy.maxAnimatedGlyphs, 64)
            }
            if copy.reducedMotion {
                copy.maxAnimatedGlyphs = 0
            }
            return copy
        }
    }

    struct Metrics: Equatable, Sendable {
        var acceptedEventCount = 0
        var emittedSnapshotCount = 0
        var suppressedUpdateCount = 0
        var pendingChangeCount = 0
        var durableCharacterCount = 0
        var lastEmissionInterval: TimeInterval?
    }
}

struct AIStreamDisplayUpdate: Equatable, Sendable {
    var document: AIStreamDocument
    var date: Date
    var reason: AIStreamDisplayUpdateReason
    var metrics: AIStreamDisplayEngine.Metrics
}

enum AIStreamDisplayUpdateReason: Equatable, Sendable {
    case started
    case text
    case status
    case cadence
    case flush
    case terminal
    case cancelled

    var isTerminal: Bool {
        self == .terminal || self == .cancelled
    }
}
