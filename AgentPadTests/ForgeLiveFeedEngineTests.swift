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
        XCTAssertTrue(
            ["Writing answer…", "Catching up…"].contains(first?.statusLine ?? ""),
            "Visible streaming status should be human-facing while backlog metrics remain hidden for tests; got '\(first?.statusLine ?? "nil")'."
        )
    }

    func testWindowedFramePreservesStableOpeningMarkerAndActiveTailWithinExactBound() {
        var engine = ForgeLiveFeedEngine()
        let opening = "Opening paragraph anchors the response for the reader.\n\n"
        let middle = String(repeating: "middle details stay durable without continuously relaying out the bubble. ", count: 40)
        let ending = "\n\nFinal active paragraph remains visible as the response arrives."
        engine.ingest(opening + middle + ending)
        let full = tryUnwrap(engine.flush())
        let windowed = full.windowed(maxCharacters: 160)

        XCTAssertLessThanOrEqual(windowed.displayText.count, 160)
        XCTAssertTrue(windowed.displayText.hasPrefix("Opening paragraph anchors"))
        XCTAssertTrue(windowed.displayText.contains(ForgeLiveFeedFrame.middleOmissionMarker))
        XCTAssertFalse(windowed.activeTail.isEmpty)
        XCTAssertTrue(windowed.displayText.hasSuffix(windowed.activeTail))
        XCTAssertEqual(windowed.settledText + windowed.activeTail, windowed.displayText)
    }

    func testNormalAndProfilingWindowsKeepReadablePrefixAndTailAtTheirBudgets() {
        var engine = ForgeLiveFeedEngine()
        let opening = "A stable first paragraph explains the answer before any details move.\n\n"
        let body = String(repeating: "A distinct middle sentence provides enough content to exercise bounded layout. ", count: 80)
        let ending = "\n\nThe active ending stays readable while the provider continues streaming."
        engine.ingest(opening + body + ending)
        let full = tryUnwrap(engine.flush())

        let normal = full.windowed(maxCharacters: 1_200)
        let profiling = full.windowed(maxCharacters: 540)

        for (frame, limit) in [(normal, 1_200), (profiling, 540)] {
            XCTAssertLessThanOrEqual(frame.displayText.count, limit)
            XCTAssertGreaterThan(frame.displayText.count, limit - 80)
            XCTAssertTrue(frame.displayText.hasPrefix("A stable first paragraph"))
            XCTAssertTrue(frame.displayText.contains(ForgeLiveFeedFrame.middleOmissionMarker))
            XCTAssertTrue(frame.displayText.hasSuffix(frame.activeTail))
        }
    }

    func testLongFeedDrainsWithoutLosingAtomsOrBacklogAccounting() {
        let source = String(repeating: "calm words, stable frames.\n", count: 1_000)
        var engine = ForgeLiveFeedEngine()
        engine.ingest(source)

        var lastBacklog = engine.backlogCharacters
        var frame: ForgeLiveFeedFrame?
        while engine.hasPendingReveal {
            guard let next = engine.revealNextFrame(forceMinimum: true, profileMode: false) else {
                XCTFail("A fully delimited feed should always make reveal progress.")
                return
            }
            XCTAssertLessThan(next.backlogCharacters, lastBacklog)
            lastBacklog = next.backlogCharacters
            frame = next
        }

        XCTAssertTrue(frame?.displayText.hasPrefix(String(source.prefix(128))) == true)
        XCTAssertTrue(frame?.displayText.contains(ForgeLiveFeedFrame.middleOmissionMarker) == true)
        XCTAssertTrue(frame?.displayText.hasSuffix(String(source.suffix(512))) == true)
        XCTAssertLessThanOrEqual(frame?.displayText.count ?? Int.max, 13_900)
        XCTAssertEqual(frame?.characterCount, source.count)
        XCTAssertEqual(frame?.backlogCharacters, 0)
    }

    func testFeedAcceptsMoreChunksAfterQueueCompaction() {
        let initial = String(repeating: "one two three four five six ", count: 600)
        let lateDelta = "and the late provider chunk remains intact."
        var engine = ForgeLiveFeedEngine()
        engine.ingest(initial)

        for _ in 0..<80 {
            XCTAssertNotNil(engine.revealNextFrame(forceMinimum: true, profileMode: false))
        }
        XCTAssertTrue(engine.hasPendingReveal)

        engine.ingest(lateDelta)
        let final = tryUnwrap(engine.flush())
        XCTAssertTrue(final.displayText.hasPrefix(String(initial.prefix(128))))
        XCTAssertTrue(final.displayText.contains(ForgeLiveFeedFrame.middleOmissionMarker))
        XCTAssertTrue(final.displayText.hasSuffix(lateDelta))
        XCTAssertLessThanOrEqual(final.displayText.count, 13_900)
        XCTAssertEqual(final.characterCount, (initial + lateDelta).count)
        XCTAssertEqual(final.backlogCharacters, 0)
    }

    func testPendingBacklogIsBoundedBeforeTheRevealLoopCatchesUp() {
        let opening = "The opening remains readable even when a provider sends a huge burst. "
        let middle = String(repeating: "this unread provider text is compacted into a stable live window without a terminal hitch. ", count: 1_400)
        let ending = "FINAL-TAIL-IS-EXACT"
        let source = opening + middle + ending
        var engine = ForgeLiveFeedEngine()

        engine.ingest(source)

        XCTAssertLessThanOrEqual(engine.backlogCharacters, ForgeLiveFeedEngine.pendingBacklogCharacterLimit)
        XCTAssertGreaterThan(engine.retainedPendingAtomCount, 0)
        XCTAssertLessThan(engine.retainedPendingAtomCount, 3_000, "The renderer must not retain one atom per entire provider burst.")

        var frame = engine.currentFrame()
        while engine.hasPendingReveal {
            frame = tryUnwrap(engine.revealNextFrame(forceMinimum: true, profileMode: false))
        }

        XCTAssertEqual(frame.characterCount, source.count)
        XCTAssertEqual(frame.backlogCharacters, 0)
        XCTAssertTrue(frame.displayText.hasPrefix("The opening remains readable"))
        XCTAssertTrue(frame.displayText.contains(ForgeLiveFeedFrame.middleOmissionMarker))
        XCTAssertTrue(frame.displayText.hasSuffix(ending))
    }

    func testExplicitStageArgumentsHaveDeterministicPrecedence() {
        XCTAssertTrue(
            AIStreamFeatureFlags.resolveResponseStageEnabled(
                launchFlags: [AIStreamFeatureFlags.responseStageLaunchArgument],
                persistedOverride: false
            ),
            "An explicit positive launch argument must override stale persisted state."
        )
        XCTAssertFalse(
            AIStreamFeatureFlags.resolveResponseStageEnabled(
                launchFlags: [
                    AIStreamFeatureFlags.responseStageLaunchArgument,
                    AIStreamFeatureFlags.legacyResponseLaunchArgument
                ],
                persistedOverride: true
            ),
            "The explicit legacy escape hatch wins if contradictory flags are supplied."
        )
        XCTAssertFalse(
            AIStreamFeatureFlags.resolveResponseStageEnabled(
                launchFlags: [],
                persistedOverride: false
            )
        )
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Expected non-nil value")
        }
        return value
    }
}
