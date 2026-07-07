import XCTest

final class ForgeLiveFeedEngineTests: XCTestCase {
    func testRaggedProviderChunksRevealWholeWordsOnly() {
        var engine = ForgeLiveFeedEngine()
        engine.ingest("Hel")
        XCTAssertNil(
            engine.revealNextFrame(forceMinimum: true, profileMode: false),
            "A half-word provider chunk should stay buffered instead of making the bubble visibly jitter."
        )

        engine.ingest("lo ")
        let frame = engine.revealNextFrame(forceMinimum: true, profileMode: false)
        XCTAssertEqual(frame?.displayText, "Hello ")
        XCTAssertEqual(frame?.settledText, "")
        XCTAssertEqual(frame?.activeTail, "Hello ")
    }

    func testWordTreeKeepsBacklogAndAdvancesInStableFrames() {
        var engine = ForgeLiveFeedEngine()
        engine.ingest(String(repeating: "NovaForge speaks in smooth semantic phrases. ", count: 8))

        let first = engine.revealNextFrame(forceMinimum: true, profileMode: false)
        XCTAssertNotNil(first)
        XCTAssertLessThan(first?.displayText.count ?? 0, 100)
        XCTAssertGreaterThan(first?.backlogCharacters ?? 0, 0)
        XCTAssertEqual(first?.displayText.last, " ", "Frames should land on a word boundary when possible.")

        let second = engine.revealNextFrame(forceMinimum: false, profileMode: false)
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(second?.characterCount ?? 0, first?.characterCount ?? 0)
        XCTAssertGreaterThan(second?.revision ?? 0, first?.revision ?? 0)
    }

    func testWindowedFramePreservesReadableTail() {
        var engine = ForgeLiveFeedEngine()
        engine.ingest(String(repeating: "calm stable live feed ", count: 90))
        let full = tryUnwrap(engine.flush())
        let windowed = full.windowed(maxCharacters: 160)

        XCTAssertLessThanOrEqual(windowed.displayText.count, 162)
        XCTAssertTrue(windowed.displayText.hasPrefix("…\n"))
        XCTAssertFalse(windowed.activeTail.isEmpty)
        XCTAssertTrue(windowed.displayText.hasSuffix(windowed.activeTail))
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Expected non-nil value")
        }
        return value
    }
}
