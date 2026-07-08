import XCTest

final class AIStreamDocumentBuilderTests: XCTestCase {
    func testRawDeltasAccumulateIntoDurableResponseText() {
        var builder = AIStreamDocumentBuilder()

        _ = builder.apply(AIStreamEvent(kind: .responseStarted))
        let first = builder.apply(AIStreamEvent(kind: .textDelta("NovaForge")))
        let second = builder.apply(AIStreamEvent(kind: .textDelta(" writes cleanly.")))

        XCTAssertEqual(builder.completeText, "NovaForge writes cleanly.")
        XCTAssertEqual(second.characterCount, "NovaForge writes cleanly.".count)
        XCTAssertEqual(first.status, .composing)
        XCTAssertEqual(second.visibleText, "NovaForge writes cleanly.")
    }

    func testSentenceBoundariesBecomeSettledParagraphsWithActiveFragment() {
        var builder = AIStreamDocumentBuilder()

        _ = builder.apply(AIStreamEvent(kind: .textDelta("First sentence lands cleanly. Second sentence is still")))
        let document = builder.apply(AIStreamEvent(kind: .textDelta(" forming")))

        XCTAssertEqual(document.visibleParagraphs.map(\.text), ["First sentence lands cleanly."])
        XCTAssertEqual(document.visibleParagraphs.map(\.state), [.settled])
        XCTAssertEqual(document.activeFragment, "Second sentence is still forming")
        XCTAssertFalse(document.visibleText.hasPrefix("entence"), "Visible streaming text should never start mid-word.")
    }

    func testVisibleParagraphsAreCappedAtSemanticBoundaries() {
        var builder = AIStreamDocumentBuilder(maxVisibleParagraphs: 3)
        let text = "One is complete.\n\nTwo is complete.\n\nThree is complete.\n\nFour is complete.\n\nFive is active"

        let document = builder.apply(AIStreamEvent(kind: .textDelta(text)))

        XCTAssertEqual(document.visibleParagraphs.map(\.text), [
            "Two is complete.",
            "Three is complete.",
            "Four is complete."
        ])
        XCTAssertEqual(document.activeFragment, "Five is active")
        XCTAssertFalse(document.visibleText.contains("One is complete."))
    }

    func testToolEventsBecomeHumanStatusWithoutDebugTerms() {
        var builder = AIStreamDocumentBuilder()

        let started = builder.apply(AIStreamEvent(kind: .toolStarted(name: "read_file", target: "AgentPad/Views/ChatView.swift")))
        let finished = builder.apply(AIStreamEvent(kind: .toolFinished(name: "normalizing chunk renderer", summary: "word tree queued")))

        XCTAssertEqual(started.status, .usingTool("Using Files"))
        XCTAssertEqual(finished.status, .composing)
        XCTAssertFalse(finished.visibleText.localizedCaseInsensitiveContains("word tree"))
        XCTAssertFalse(finished.visibleText.localizedCaseInsensitiveContains("normalizing chunk"))
    }

    func testArtifactEventsBecomeInlineHandoffs() {
        var builder = AIStreamDocumentBuilder()

        let document = builder.apply(AIStreamEvent(kind: .artifactReady(title: "Demo Preview", path: "Artifacts/demo.html", typeName: "HTML")))

        XCTAssertEqual(document.artifacts, [
            LiveChatArtifactHandoff(
                id: "Artifacts/demo.html",
                title: "Demo Preview",
                subtitle: "HTML ready in Workspace",
                path: "Artifacts/demo.html",
                typeName: "HTML",
                primaryActionTitle: "Preview"
            )
        ])
    }

    func testFailureEventProducesRecoveryState() {
        var builder = AIStreamDocumentBuilder()
        _ = builder.apply(AIStreamEvent(kind: .textDelta("Partial answer remains readable.")))

        let failed = builder.apply(AIStreamEvent(kind: .failed("provider timeout while normalizing chunk")))

        XCTAssertEqual(failed.status, .failed("Provider timeout while preparing the response."))
        XCTAssertFalse(failed.isComplete)
        XCTAssertEqual(builder.completeText, "Partial answer remains readable.")
    }
}
