import XCTest
@testable import NovaForge

final class AgentActivityPresentationTests: XCTestCase {
    func testToolNamesMapToStableHumanCopy() {
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "read_file",
                arguments: ["path": "Sources/App.swift"]
            ).title,
            "Inspecting file"
        )
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "response renderer",
                detail: "Organizing the response"
            ).title,
            "Writing answer…"
        )
    }

    func testCommandPresentationRecognizesProofWork() {
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "run_command",
                arguments: ["command": "xcodebuild -scheme AgentPad test"]
            ).title,
            "Running Xcode proof"
        )
        XCTAssertEqual(
            AgentActivityPresentation.presentation(
                forToolName: "run_command",
                arguments: ["command": "xcrun simctl io booted screenshot proof.png"]
            ).title,
            "Capturing proof"
        )
    }

    func testInternalDetailsDoNotLeakIntoVisibleCopy() {
        XCTAssertEqual(
            AgentActivityPresentation.humanizedVisibleText(
                "normalizing chunk 42",
                fallback: "Working"
            ),
            "Organizing the response"
        )
        XCTAssertEqual(
            AgentActivityPresentation.humanizedVisibleDetail("{\"debug\":true}"),
            "Details saved in History."
        )
    }
}
