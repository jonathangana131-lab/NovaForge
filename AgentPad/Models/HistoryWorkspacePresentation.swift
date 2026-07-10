import Foundation

/// Small, deterministic formatting rules shared by History and Workspace.
///
/// Keeping these rules independent from SwiftUI lets the unit-test target
/// verify provenance wording without compiling either full screen hierarchy.
enum HistoryWorkspacePresentation {
    static func missionProvenanceLine(
        projectName: String,
        workspaceName: String,
        toolName: String
    ) -> String {
        [projectName, workspaceName, toolName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    static func provenanceReference(
        toolRunID: String?,
        terminalCommandID: String?,
        eventID: String?
    ) -> String {
        if let value = compactProvenanceID(toolRunID) {
            return "Run \(value)"
        }
        if let value = compactProvenanceID(terminalCommandID) {
            return "Terminal \(value)"
        }
        if let value = compactProvenanceID(eventID) {
            return "Event \(value)"
        }
        return "Workspace indexed"
    }

    static func provenanceLabel(
        base: String,
        toolRunID: String?,
        terminalCommandID: String?,
        eventID: String?
    ) -> String {
        let reference = provenanceReference(
            toolRunID: toolRunID,
            terminalCommandID: terminalCommandID,
            eventID: eventID
        )
        guard reference != "Workspace indexed" else { return base }
        return "\(base) · \(reference)"
    }

    static func workspaceScopeLine(projectName: String, workspaceName: String) -> String {
        [projectName, workspaceName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    /// General is a real evidence scope, represented by `nil`. Equality is
    /// deliberate here: neither direction is allowed to fall back to the
    /// currently selected physical workspace project.
    static func evidenceBelongsToScope(
        evidenceProjectID: UUID?,
        scopeProjectID: UUID?
    ) -> Bool {
        evidenceProjectID == scopeProjectID
    }

    private static func compactProvenanceID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(8))
    }
}
