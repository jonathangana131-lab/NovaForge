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

    func testWorkspaceProvenanceLabelNormalizesBaseWhitespace() {
        XCTAssertEqual(
            HistoryWorkspacePresentation.provenanceLabel(
                base: "  Project artifact \n",
                toolRunID: "12345678-aaaa-bbbb-cccc-dddddddddddd",
                terminalCommandID: nil,
                eventID: nil
            ),
            "Project artifact · Run 12345678"
        )
    }

    func testWorkspaceProvenanceLabelDropsBlankBaseWithoutDanglingSeparator() {
        XCTAssertEqual(
            HistoryWorkspacePresentation.provenanceLabel(
                base: " \n ",
                toolRunID: "12345678-aaaa-bbbb-cccc-dddddddddddd",
                terminalCommandID: nil,
                eventID: nil
            ),
            "Run 12345678"
        )
        XCTAssertEqual(
            HistoryWorkspacePresentation.provenanceLabel(
                base: " \n ",
                toolRunID: nil,
                terminalCommandID: nil,
                eventID: nil
            ),
            ""
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

    func testHistoryToolRunCacheSignatureChangesForInPlaceLifecycleMutation() {
        let run = ToolRun(
            name: "run_command",
            argumentsJSON: #"{"command":"swift test"}"#,
            status: .approved,
            isMutating: false
        )
        let active = HistoryToolRunCacheSignature(run)

        run.output = "All tests passed"
        run.status = .completed
        run.completedAt = Date()

        XCTAssertNotEqual(active, HistoryToolRunCacheSignature(run))
    }

    func testHistoryTerminalCacheSignatureChangesForInPlaceOutputMutation() {
        let record = TerminalCommandRecord(
            project: nil,
            command: "swift test",
            output: "running",
            status: .completed,
            workspaceName: "Default",
            durationMs: 10
        )
        let initial = HistoryTerminalRecordCacheSignature(record)

        record.output = "All tests passed"
        record.durationMs = 20

        XCTAssertNotEqual(initial, HistoryTerminalRecordCacheSignature(record))
    }
}
