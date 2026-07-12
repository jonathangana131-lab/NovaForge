import XCTest

final class LiveTranscriptComposerTests: XCTestCase {
    func testRaggedChunksNeverExposeAHalfWord() {
        let responseID = UUID()
        var composer = LiveTranscriptComposer(responseID: responseID)

        composer.ingest("Hel")
        XCTAssertNil(composer.revealNextSnapshot(forceMinimum: true, profileMode: false))

        composer.ingest("lo ")
        let first = tryUnwrap(
            composer.revealNextSnapshot(forceMinimum: true, profileMode: false)
        )
        XCTAssertEqual(first.responseID, responseID)
        XCTAssertEqual(first.visibleText, "Hello ")
        XCTAssertEqual(first.activeParagraph.settledPrefix, "")
        XCTAssertEqual(first.activeParagraph.activePhrase?.text, "Hello ")

        composer.ingest("wor")
        XCTAssertNil(composer.revealNextSnapshot(forceMinimum: false, profileMode: false))

        composer.ingest("ld.")
        let second = tryUnwrap(
            composer.revealNextSnapshot(forceMinimum: false, profileMode: false)
        )
        XCTAssertEqual(second.visibleText, "Hello world.")
        XCTAssertEqual(second.activeParagraph.settledPrefix, "Hello ")
        XCTAssertEqual(second.activeParagraph.activePhrase?.text, "world.")
    }

    func testParagraphAndPhraseIDsRemainOrdinalAndStable() {
        let responseID = UUID()
        var composer = LiveTranscriptComposer(responseID: responseID)
        composer.ingest("One phrase. Two phrase.")

        let first = tryUnwrap(
            composer.revealNextSnapshot(forceMinimum: true, profileMode: false)
        )
        let firstParagraphID = first.activeParagraph.id
        XCTAssertEqual(firstParagraphID.responseID, responseID)
        XCTAssertEqual(firstParagraphID.ordinal, 0)
        XCTAssertEqual(first.activeParagraph.activePhrase?.id.paragraphOrdinal, 0)
        XCTAssertEqual(first.activeParagraph.activePhrase?.id.ordinal, 0)

        let second = tryUnwrap(
            composer.revealNextSnapshot(forceMinimum: false, profileMode: false)
        )
        XCTAssertEqual(second.activeParagraph.id, firstParagraphID)
        XCTAssertEqual(second.activeParagraph.activePhrase?.id.responseID, responseID)
        XCTAssertEqual(second.activeParagraph.activePhrase?.id.paragraphOrdinal, 0)
        XCTAssertEqual(second.activeParagraph.activePhrase?.id.ordinal, 1)
        XCTAssertEqual(second.activeParagraph.settledPrefix, "One phrase. ")
    }

    func testBlankLineCommitsAnImmutableParagraph() {
        let responseID = UUID()
        var composer = LiveTranscriptComposer(responseID: responseID)
        composer.ingest("First paragraph.\n")
        let firstFrame = tryUnwrap(
            composer.revealNextSnapshot(forceMinimum: true, profileMode: false)
        )
        XCTAssertTrue(firstFrame.visibleText.hasPrefix("First"))
        XCTAssertFalse(firstFrame.visibleText.contains("\n"))

        // The provider splits the paragraph delimiter across chunks. The
        // first newline must remain joinable instead of being misclassified
        // as a permanent single-line break.
        composer.ingest("\nSecond paragraph.")

        let snapshot = tryUnwrap(composer.flush())

        XCTAssertEqual(snapshot.visibleText, "First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(snapshot.settledParagraphs.count, 1)
        XCTAssertEqual(snapshot.settledParagraphs[0].id.responseID, responseID)
        XCTAssertEqual(snapshot.settledParagraphs[0].id.ordinal, 0)
        XCTAssertEqual(snapshot.settledParagraphs[0].text, "First paragraph.")
        XCTAssertEqual(snapshot.settledParagraphs[0].trailingSeparator, "\n\n")
        XCTAssertEqual(snapshot.activeParagraph.id.ordinal, 1)
        XCTAssertEqual(snapshot.activeParagraph.activePhrase?.id.paragraphOrdinal, 1)
        XCTAssertEqual(snapshot.activeParagraph.visibleText, "Second paragraph.")
    }

    func testUnicodeGraphemeCountsAndTranscriptStayExact() {
        let source = "Café 👩🏽‍💻 ships — smoothly. こんにちは世界！\nNext ✨ line"
        var composer = LiveTranscriptComposer(responseID: UUID())
        for chunk in ["Caf", "é 👩🏽‍💻 sh", "ips — smoothly.", " こんにちは", "世界！\n", "Next ✨ line"] {
            composer.ingest(chunk)
        }

        let snapshot = tryUnwrap(composer.flush())

        XCTAssertEqual(snapshot.visibleText, source)
        XCTAssertEqual(snapshot.characterCount, source.count)
        XCTAssertEqual(snapshot.backlogCharacters, 0)
        XCTAssertLessThanOrEqual(
            snapshot.activeParagraph.activePhrase?.text.count ?? 0,
            LiveTranscriptComposer.maximumActivePhraseCharacters
        )
    }

    func testProviderBurstBoundsBacklogAndUsesCatchUpCadence() {
        let opening = "A stable opening remains readable. "
        let middle = String(
            repeating: "The provider can outrun the display clock without growing an unbounded phrase queue. ",
            count: 1_400
        )
        let ending = "FINAL-UNICODE-TAIL-✨"
        let source = opening + middle + ending
        var composer = LiveTranscriptComposer(responseID: UUID())

        composer.ingest(source)

        XCTAssertLessThanOrEqual(
            composer.backlogCharacters,
            LiveTranscriptComposer.pendingBacklogCharacterLimit
        )
        XCTAssertLessThan(composer.retainedPendingAtomCount, 3_000)

        let first = tryUnwrap(
            composer.revealNextSnapshot(forceMinimum: true, profileMode: false)
        )
        XCTAssertEqual(first.cadence, .burst)
        XCTAssertTrue(first.visibleText.hasPrefix(opening))
        XCTAssertLessThanOrEqual(
            first.activeParagraph.activePhrase?.text.count ?? 0,
            LiveTranscriptComposer.maximumActivePhraseCharacters
        )
        XCTAssertLessThanOrEqual(
            first.activeParagraph.settledTail.count,
            LiveTranscriptComposer.maximumActiveSettledTailCharacters
        )

        let final = tryUnwrap(composer.flush())
        XCTAssertEqual(final.visibleText, source)
        XCTAssertEqual(final.characterCount, source.count)
        XCTAssertEqual(final.backlogCharacters, 0)
        XCTAssertFalse(composer.hasPendingReveal)
        XCTAssertTrue(final.visibleText.hasSuffix(ending))
    }

    func testFlushSealsAnUndelimitedTailAndResetRekeysIDs() {
        let firstID = UUID()
        let secondID = UUID()
        var composer = LiveTranscriptComposer(responseID: firstID)
        composer.ingest("Final ragged tail")

        let flushed = tryUnwrap(composer.flush())
        XCTAssertEqual(flushed.visibleText, "Final ragged tail")
        XCTAssertEqual(flushed.characterCount, "Final ragged tail".count)
        XCTAssertEqual(flushed.backlogCharacters, 0)
        XCTAssertFalse(composer.hasPendingReveal)

        composer.reset(responseID: secondID)
        let empty = composer.currentSnapshot()
        XCTAssertEqual(empty, LiveTranscriptSnapshot.empty(responseID: secondID))

        composer.ingest("New response.")
        let newSnapshot = tryUnwrap(composer.flush())
        XCTAssertEqual(newSnapshot.responseID, secondID)
        XCTAssertEqual(newSnapshot.activeParagraph.activePhrase?.id.responseID, secondID)
        XCTAssertEqual(newSnapshot.activeParagraph.activePhrase?.id.ordinal, 0)
        XCTAssertEqual(newSnapshot.revision, 1)
    }

    func testLongActiveParagraphFreezesStableSegmentsWithoutHidingText() {
        let sentence = "A calm semantic sentence remains visible while only the newest bounded tail is allowed to re-layout. "
        let source = String(repeating: sentence, count: 42) + "Final exact tail ✨"
        var composer = LiveTranscriptComposer(responseID: UUID())

        composer.ingest(source)
        let snapshot = tryUnwrap(composer.flush())

        XCTAssertEqual(snapshot.visibleText, source)
        XCTAssertEqual(snapshot.activeParagraph.visibleText, source)
        XCTAssertFalse(snapshot.activeParagraph.settledSegments.isEmpty)
        XCTAssertLessThanOrEqual(
            snapshot.activeParagraph.settledTail.count,
            LiveTranscriptComposer.maximumActiveSettledTailCharacters
        )
        XCTAssertEqual(
            snapshot.activeParagraph.settledSegments.map(\.ordinal),
            Array(snapshot.activeParagraph.settledSegments.indices)
        )

        let reconstructed = snapshot.activeParagraph.settledSegments.map(\.text).joined()
            + snapshot.activeParagraph.settledTail
            + (snapshot.activeParagraph.activePhrase?.text ?? "")
        XCTAssertEqual(reconstructed, source)
    }

    func testFrozenSegmentsKeepIdentityAndCommitBackToExactParagraphText() {
        let responseID = UUID()
        let opening = String(
            repeating: "Stable segment identity prevents settled text from replaying during the next phrase. ",
            count: 34
        )
        let continuation = String(
            repeating: "Additional streamed text extends the same paragraph without mutating old segments. ",
            count: 18
        )
        var composer = LiveTranscriptComposer(responseID: responseID)

        composer.ingest(opening)
        let first = tryUnwrap(composer.flush())
        let frozen = first.activeParagraph.settledSegments
        XCTAssertFalse(frozen.isEmpty)

        composer.ingest(continuation)
        let extended = tryUnwrap(composer.flush())
        XCTAssertEqual(Array(extended.activeParagraph.settledSegments.prefix(frozen.count)), frozen)
        XCTAssertEqual(extended.activeParagraph.visibleText, opening + continuation)

        composer.ingest("\n\nNext paragraph.")
        let committed = tryUnwrap(composer.flush())
        XCTAssertEqual(committed.settledParagraphs.first?.text, opening + continuation)
        XCTAssertEqual(committed.activeParagraph.visibleText, "Next paragraph.")
        XCTAssertTrue(committed.activeParagraph.settledSegments.isEmpty)
    }

    private func tryUnwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Expected non-nil value")
        }
        return value
    }
}
