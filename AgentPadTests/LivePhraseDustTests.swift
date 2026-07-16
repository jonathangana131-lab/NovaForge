import XCTest

final class LivePhraseDustTests: XCTestCase {
    func testPhraseSeedIsStableAndChangesWithPhraseOrdinal() {
        let responseID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let first = LivePhraseDustGeometry.phraseSeed(
            responseID: responseID,
            paragraphOrdinal: 2,
            phraseOrdinal: 7
        )
        let repeated = LivePhraseDustGeometry.phraseSeed(
            responseID: responseID,
            paragraphOrdinal: 2,
            phraseOrdinal: 7
        )
        let nextPhrase = LivePhraseDustGeometry.phraseSeed(
            responseID: responseID,
            paragraphOrdinal: 2,
            phraseOrdinal: 8
        )

        XCTAssertEqual(first, 5_859_054_519_282_676_219)
        XCTAssertEqual(repeated, first)
        XCTAssertNotEqual(nextPhrase, first)

        let bounds = CGRect(x: 10, y: 20, width: 12, height: 18)
        XCTAssertEqual(
            LivePhraseDustGeometry.particle(
                seed: first,
                particleOrdinal: 3,
                targetBounds: bounds,
                progress: 0.35
            ),
            LivePhraseDustGeometry.particle(
                seed: repeated,
                particleOrdinal: 3,
                targetBounds: bounds,
                progress: 0.35
            )
        )
    }

    func testParticleCountAndGlyphSamplingStayBounded() {
        XCTAssertEqual(LivePhraseDustGeometry.particleCount(requested: -8), 0)
        XCTAssertEqual(LivePhraseDustGeometry.particleCount(requested: 0), 0)
        XCTAssertEqual(LivePhraseDustGeometry.particleCount(requested: 7), 7)
        XCTAssertEqual(
            LivePhraseDustGeometry.particleCount(requested: 500),
            LivePhraseDustGeometry.maximumParticleCount
        )

        let sampled = (0..<12).map {
            LivePhraseDustGeometry.sampledGlyphIndex(
                particleOrdinal: $0,
                glyphCount: 4,
                particleCount: 12
            )
        }
        XCTAssertEqual(sampled, [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3])
    }

    func testDustEnvelopeClampsAndFullySettles() {
        let beforeStart = LivePhraseDustGeometry.phase(progress: -10)
        let start = LivePhraseDustGeometry.phase(progress: 0)
        let middle = LivePhraseDustGeometry.phase(progress: 0.45)
        let complete = LivePhraseDustGeometry.phase(progress: 1)
        let afterComplete = LivePhraseDustGeometry.phase(progress: 8)

        XCTAssertEqual(beforeStart, start)
        XCTAssertGreaterThan(middle.dustOpacity, 0)
        XCTAssertGreaterThan(middle.textOpacity, start.textOpacity)
        XCTAssertLessThan(middle.blurRadius, start.blurRadius)
        XCTAssertEqual(complete.textOpacity, 1, accuracy: 0.000_001)
        XCTAssertEqual(complete.dustOpacity, 0)
        XCTAssertEqual(complete.blurRadius, 0, accuracy: 0.000_001)
        XCTAssertEqual(complete.verticalOffset, 0, accuracy: 0.000_001)
        XCTAssertTrue(complete.isSettled)
        XCTAssertEqual(afterComplete, complete)
    }

    func testAccessibilityAndConservativePoliciesSuppressDust() {
        let normal = LivePhraseEffectPolicy.mode(
            prefersReducedVisualEffects: false,
            usesMatrixTheme: false,
            usesConservativeRendering: false,
            reduceMotion: false,
            reduceTransparency: false
        )
        XCTAssertEqual(normal, .dustMaterialize)

        XCTAssertEqual(
            LivePhraseEffectPolicy.mode(
                prefersReducedVisualEffects: false,
                usesMatrixTheme: false,
                usesConservativeRendering: false,
                reduceMotion: true,
                reduceTransparency: false
            ),
            .fadeOnly
        )
        XCTAssertEqual(
            LivePhraseEffectPolicy.mode(
                prefersReducedVisualEffects: false,
                usesMatrixTheme: false,
                usesConservativeRendering: false,
                reduceMotion: false,
                reduceTransparency: true
            ),
            .fadeOnly
        )
        XCTAssertEqual(
            LivePhraseEffectPolicy.mode(
                prefersReducedVisualEffects: true,
                usesMatrixTheme: false,
                usesConservativeRendering: false,
                reduceMotion: false,
                reduceTransparency: false
            ),
            .none
        )
    }
}
