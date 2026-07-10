import XCTest

final class HistoryWorkspacePresentationTests: XCTestCase {
    func testMissionProvenanceLineKeepsProjectWorkspaceAndToolOrder() {
        XCTAssertEqual(
            HistoryWorkspacePresentation.missionProvenanceLine(
                projectName: "NovaForge",
                workspaceName: "Default",
                toolName: "Run command"
            ),
            "NovaForge / Default / Run command"
        )
    }

    func testMissionProvenanceLineDropsEmptySegments() {
        XCTAssertEqual(
            HistoryWorkspacePresentation.missionProvenanceLine(
                projectName: "  NovaForge ",
                workspaceName: " ",
                toolName: " Read file "
            ),
            "NovaForge / Read file"
        )
    }

    func testWorkspaceProvenancePrefersRunThenTerminalThenEvent() {
        XCTAssertEqual(
            HistoryWorkspacePresentation.provenanceReference(
                toolRunID: "12345678-aaaa-bbbb-cccc-dddddddddddd",
                terminalCommandID: "terminal-id",
                eventID: "event-id"
            ),
            "Run 12345678"
        )
        XCTAssertEqual(
            HistoryWorkspacePresentation.provenanceReference(
                toolRunID: nil,
                terminalCommandID: "terminal-987654",
                eventID: "event-id"
            ),
            "Terminal terminal"
        )
        XCTAssertEqual(
            HistoryWorkspacePresentation.provenanceReference(
                toolRunID: " ",
                terminalCommandID: nil,
                eventID: "event-123456"
            ),
            "Event event-12"
        )
    }

    func testUnlinkedWorkspaceEvidenceUsesIndexedFallback() {
        XCTAssertEqual(
            HistoryWorkspacePresentation.provenanceReference(
                toolRunID: nil,
                terminalCommandID: nil,
                eventID: nil
            ),
            "Workspace indexed"
        )
        XCTAssertEqual(
            HistoryWorkspacePresentation.provenanceLabel(
                base: "Project artifact",
                toolRunID: nil,
                terminalCommandID: nil,
                eventID: nil
            ),
            "Project artifact"
        )
    }

    func testWorkspaceScopeLineNormalizesWhitespace() {
        XCTAssertEqual(
            HistoryWorkspacePresentation.workspaceScopeLine(
                projectName: " NovaForge ",
                workspaceName: " Default "
            ),
            "NovaForge / Default"
        )
    }

    func testGeneralEvidenceScopeDoesNotBorrowProjectEvidence() {
        let projectID = UUID()

        XCTAssertTrue(
            HistoryWorkspacePresentation.evidenceBelongsToScope(
                evidenceProjectID: nil,
                scopeProjectID: nil
            )
        )
        XCTAssertFalse(
            HistoryWorkspacePresentation.evidenceBelongsToScope(
                evidenceProjectID: projectID,
                scopeProjectID: nil
            )
        )
        XCTAssertFalse(
            HistoryWorkspacePresentation.evidenceBelongsToScope(
                evidenceProjectID: nil,
                scopeProjectID: projectID
            )
        )
        XCTAssertTrue(
            HistoryWorkspacePresentation.evidenceBelongsToScope(
                evidenceProjectID: projectID,
                scopeProjectID: projectID
            )
        )
    }
}
