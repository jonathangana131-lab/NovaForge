import XCTest

final class AIStreamDisplayEngineTests: XCTestCase {
    func testRapidDeltasDoNotEmitAUIUpdatePerCharacter() {
        var engine = AIStreamDisplayEngine(
            configuration: .init(minimumUpdateInterval: 0.05)
        )
        let start = Date(timeIntervalSince1970: 1_000)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var emitted: [AIStreamDisplayUpdate] = []

        if let update = engine.consume(AIStreamEvent(date: start, kind: .responseStarted), at: start) {
            emitted.append(update)
        }
        for (index, letter) in letters.enumerated() {
            let now = start.addingTimeInterval(Double(index) * 0.001)
            if let update = engine.consume(AIStreamEvent(date: now, kind: .textDelta(String(letter))), at: now) {
                emitted.append(update)
            }
        }

        XCTAssertLessThan(emitted.count, letters.count / 2)
        XCTAssertGreaterThan(engine.metrics.suppressedUpdateCount, 10)
        XCTAssertEqual(engine.durableText, String(letters))
    }

    func testBacklogDrainsAtBoundedCadence() {
        var engine = AIStreamDisplayEngine(
            configuration: .init(minimumUpdateInterval: 0.08)
        )
        let start = Date(timeIntervalSince1970: 2_000)

        _ = engine.consume(AIStreamEvent(date: start, kind: .responseStarted), at: start)
        XCTAssertNil(engine.consume(AIStreamEvent(date: start, kind: .textDelta("This is cached")), at: start.addingTimeInterval(0.01)))
        XCTAssertNil(engine.tick(at: start.addingTimeInterval(0.04)))

        let update = engine.tick(at: start.addingTimeInterval(0.09))
        XCTAssertEqual(update?.document.activeFragment, "This is cached")
        XCTAssertFalse(engine.hasPendingUIUpdate)
        XCTAssertEqual(engine.metrics.emittedSnapshotCount, 2)
    }

    func testFinalDocumentContainsCompleteAnswerDespiteSuppressedDeltas() {
        var engine = AIStreamDisplayEngine(
            configuration: .init(minimumUpdateInterval: 10)
        )
        let start = Date(timeIntervalSince1970: 3_000)
        let chunks = ["Nova", "Forge ", "keeps ", "the complete ", "answer."]

        _ = engine.consume(AIStreamEvent(date: start, kind: .responseStarted), at: start)
        for chunk in chunks {
            _ = engine.consume(AIStreamEvent(kind: .textDelta(chunk)), at: start.addingTimeInterval(0.01))
        }
        let final = engine.consume(AIStreamEvent(kind: .completed), at: start.addingTimeInterval(0.02))

        XCTAssertEqual(engine.durableText, chunks.joined())
        XCTAssertEqual(final?.document.characterCount, chunks.joined().count)
        XCTAssertEqual(final?.document.status, .complete)
        XCTAssertEqual(final?.reason, .terminal)
    }

    func testReducedMotionAndPerformanceFlagsDoNotChangeDurableText() {
        let events: [AIStreamEvent] = [
            AIStreamEvent(kind: .responseStarted),
            AIStreamEvent(kind: .textDelta("Premium text ")),
            AIStreamEvent(kind: .textDelta("still accumulates.")),
            AIStreamEvent(kind: .completed)
        ]
        var normal = AIStreamDisplayEngine(configuration: .init(reducedMotion: false, performanceMode: false))
        var constrained = AIStreamDisplayEngine(configuration: .init(reducedMotion: true, performanceMode: true))
        let start = Date(timeIntervalSince1970: 4_000)

        for (index, event) in events.enumerated() {
            let now = start.addingTimeInterval(Double(index) * 0.1)
            _ = normal.consume(event, at: now)
            _ = constrained.consume(event, at: now)
        }

        XCTAssertEqual(normal.durableText, constrained.durableText)
        XCTAssertEqual(normal.currentDocument.characterCount, constrained.currentDocument.characterCount)
        XCTAssertTrue(constrained.configuration.reducedMotion)
        XCTAssertTrue(constrained.configuration.performanceMode)
    }

    func testFailureAndCancellationClearLiveDocumentSafely() {
        var engine = AIStreamDisplayEngine(configuration: .init(minimumUpdateInterval: 0.05))
        let start = Date(timeIntervalSince1970: 5_000)

        _ = engine.consume(AIStreamEvent(kind: .textDelta("Partial answer")), at: start)
        let failed = engine.consume(AIStreamEvent(kind: .failed("timeout in renderer")), at: start.addingTimeInterval(0.01))

        XCTAssertEqual(failed?.document.status, .failed("Provider timeout while preparing the response."))
        XCTAssertEqual(engine.durableText, "Partial answer")

        let cancelled = engine.cancel()
        XCTAssertEqual(cancelled.document, .empty)
        XCTAssertEqual(engine.durableText, "")
        XCTAssertFalse(engine.hasPendingUIUpdate)
    }
}
