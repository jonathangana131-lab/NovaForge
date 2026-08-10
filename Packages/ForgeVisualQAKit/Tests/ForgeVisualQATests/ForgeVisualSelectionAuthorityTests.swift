import Foundation
import XCTest
@testable import ForgeVisualQA

final class ForgeVisualSelectionAuthorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let artifactDigest = String(repeating: "c", count: 64)

    func testTrustedSelectionBindsExactCaptureArtifactFrameAndMapping() throws {
        let capture = try trustedCapture(frame: 42)
        let selection = try validSelection(capture: capture)
        let trusted = try VisualTrustedSelection(
            authenticatedCapture: capture,
            authenticatedSelection: selection,
            producerReceiptID: "visual-picker-receipt-42"
        )

        XCTAssertEqual(trusted.capture, capture)
        XCTAssertEqual(trusted.capture.artifactSHA256, artifactDigest)
        XCTAssertEqual(trusted.capture.frameOrdinal, 42)
        XCTAssertEqual(trusted.selection, selection)
        XCTAssertEqual(trusted.selection.runtimeNodeID, "button:start")
        XCTAssertEqual(trusted.selection.source.path, "src/App.js")
        XCTAssertEqual(trusted.producerReceiptID, "visual-picker-receipt-42")
    }

    func testTrustedSelectionRejectsDifferentCaptureSubject() throws {
        let capture = try trustedCapture(session: "session-1")
        let otherCapture = try trustedCapture(session: "session-2", digestByte: "d")
        let selection = try validSelection(capture: capture)

        XCTAssertThrowsError(
            try VisualTrustedSelection(
                authenticatedCapture: otherCapture,
                authenticatedSelection: selection,
                producerReceiptID: "visual-picker-receipt"
            )
        ) { error in
            XCTAssertEqual(error as? VisualSelectionAuthorityError, .selectionCaptureMismatch)
        }
    }

    func testTrustedSelectionRejectsNonCanonicalProducerReceipt() throws {
        let capture = try trustedCapture()
        let selection = try validSelection(capture: capture)

        for receipt in ["", " receipt", "receipt ", "receipt\nother"] {
            XCTAssertThrowsError(
                try VisualTrustedSelection(
                    authenticatedCapture: capture,
                    authenticatedSelection: selection,
                    producerReceiptID: receipt
                )
            ) { error in
                XCTAssertEqual(error as? VisualSelectionAuthorityError, .invalidProducerReceipt)
            }
        }
    }

    func testDecodedMalformedCaptureCannotBePromotedToTrustedCapture() throws {
        let candidate = try capture()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any]
        )
        object["runtimeSessionID"] = "   "
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VisualCaptureReceipt.self, from: tamperedData)
        XCTAssertEqual(decoded.runtimeSessionID, "   ")

        XCTAssertThrowsError(
            try VisualTrustedCapture(
                authenticatedCapture: decoded,
                artifactSHA256: artifactDigest
            )
        ) { error in
            XCTAssertEqual(error as? VisualQAInvariantError, .invalidRuntimeSession)
        }
    }

    func testDecodedMalformedViewportCannotBePromotedToTrustedCapture() throws {
        let candidate = try capture()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any]
        )
        var viewport = try XCTUnwrap(object["viewport"] as? [String: Any])
        viewport["width"] = 0
        object["viewport"] = viewport
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VisualCaptureReceipt.self, from: tamperedData)
        XCTAssertFalse(decoded.viewport.isValid)

        XCTAssertThrowsError(
            try VisualTrustedCapture(
                authenticatedCapture: decoded,
                artifactSHA256: artifactDigest
            )
        ) { error in
            XCTAssertEqual(error as? VisualQAInvariantError, .invalidViewport)
        }
    }

    func testDecodedMalformedSelectionCannotBePromotedToTrustedSelection() throws {
        let capture = try trustedCapture()
        let candidate = try validSelection(capture: capture)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any]
        )
        object["runtimeNodeID"] = ""
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VisualSelectionIdentity.self, from: tamperedData)
        XCTAssertEqual(decoded.runtimeNodeID, "")
        XCTAssertFalse(decoded.isValid(for: capture))

        XCTAssertThrowsError(
            try VisualTrustedSelection(
                authenticatedCapture: capture,
                authenticatedSelection: decoded,
                producerReceiptID: "visual-picker-receipt"
            )
        ) { error in
            XCTAssertEqual(error as? VisualSelectionAuthorityError, .selectionCaptureMismatch)
        }
    }

    private func capture(
        projectID: String = "project-1",
        revision: String = "r1",
        session: String = "session-1",
        frame: UInt64 = 0
    ) throws -> VisualCaptureReceipt {
        try VisualCaptureReceipt(
            project: .init(projectID: projectID, sourceRevision: revision),
            runtimeSessionID: session,
            frameOrdinal: frame,
            viewport: VisualViewport(
                width: 390,
                height: 844,
                scale: 3,
                orientation: .portrait,
                safeArea: .init(top: 47, leading: 0, bottom: 34, trailing: 0)
            ),
            accessibility: VisualAccessibilityState(
                reduceMotion: false,
                reduceTransparency: false,
                increaseContrast: false,
                differentiateWithoutColor: false,
                dynamicTypeCategory: "large"
            ),
            evidenceKind: .runtimeScreenshot,
            capturedAt: now
        )
    }

    private func trustedCapture(
        projectID: String = "project-1",
        revision: String = "r1",
        session: String = "session-1",
        frame: UInt64 = 0,
        digestByte: String = "c"
    ) throws -> VisualTrustedCapture {
        try VisualTrustedCapture(
            authenticatedCapture: capture(
                projectID: projectID,
                revision: revision,
                session: session,
                frame: frame
            ),
            artifactSHA256: String(repeating: digestByte, count: 64)
        )
    }

    private func validSelection(capture: VisualTrustedCapture) throws -> VisualSelectionIdentity {
        try VisualSelectionIdentity(
            kind: .domElement,
            project: capture.project,
            runtimeSessionID: capture.runtimeSessionID,
            runtimeNodeID: "button:start",
            source: .init(path: "src/App.js", symbol: "startButton")
        )
    }
}
