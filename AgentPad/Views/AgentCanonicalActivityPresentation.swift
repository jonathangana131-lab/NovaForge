import Foundation

/// Pure, bounded presentation policy for the canonical activity projection.
///
/// The SwiftUI layer receives already-classified values from
/// `AgentCanonicalActivityProjector`. This type deliberately does not inspect
/// summaries, targets, provider names, or any serialized payload to infer
/// behavior. Selection is driven only by canonical kinds, states, and stable
/// identities.
struct AgentCanonicalActivityPresentation: Equatable {
    static let expandedItemLimit = 12
    static let expandedAttemptLimit = 4
    static let artifactLimit = 2

    let stateLabel: String
    let durationLabel: String
    let visibleItems: [AgentActivityItem]
    let hiddenItemCount: Int
    let coalescedSuccessfulItemCount: Int
    let visibleAttempts: [AgentActivityAttempt]
    let hiddenAttemptCount: Int
    let visibleArtifacts: [AgentActivityArtifact]
    let hiddenArtifactCount: Int
    let showsModelWork: Bool
    let primarySummary: String
    let primarySymbol: String

    init(group: AgentActivityGroup, isExpanded: Bool) {
        let presentableItems = group.items.filter(Self.isPresentableItem)
        let selectedItems = Self.selectedItems(
            from: presentableItems,
            groupState: group.state,
            isExpanded: isExpanded
        )
        let selectedAttempts = isExpanded
            ? Array(group.attempts.suffix(Self.expandedAttemptLimit))
            : []

        stateLabel = Self.stateLabel(for: group.state)
        durationLabel = Self.durationLabel(
            milliseconds: group.span.durationMilliseconds
        )
        visibleItems = selectedItems
        hiddenItemCount = max(0, presentableItems.count - selectedItems.count)
        coalescedSuccessfulItemCount = Self.coalescedSuccessfulItemCount(
            all: presentableItems,
            visible: selectedItems
        )
        visibleAttempts = selectedAttempts
        hiddenAttemptCount = max(0, group.attempts.count - selectedAttempts.count)
        visibleArtifacts = Array(group.artifacts.prefix(Self.artifactLimit))
        hiddenArtifactCount = max(0, group.artifacts.count - Self.artifactLimit)
        showsModelWork = !group.attempts.isEmpty && (
            isExpanded ||
                (!group.state.isTerminal && (
                    selectedItems.isEmpty || group.state == .retrying
                ))
        )
        primarySummary = Self.primarySummary(for: group)
        primarySymbol = Self.primarySymbol(for: group)
    }

    static func stateLabel(for state: AgentActivityState) -> String {
        switch state {
        case .pending: "Preparing"
        case .queued: "Queued"
        case .running: "Running"
        case .awaitingApproval: "Awaiting approval"
        case .retrying: "Retrying"
        case .succeeded: "Complete"
        case .failed: "Failed"
        case .rejected: "Rejected"
        case .cancelling: "Stopping"
        case .cancelled: "Stopped"
        case .interrupted: "Interrupted"
        }
    }

    static func durationLabel(milliseconds: Int64) -> String {
        let clamped = max(0, milliseconds)
        if clamped < 1_000 {
            return clamped == 0 ? "Less than 1s" : "\(clamped)ms"
        }

        let totalSeconds = clamped / 1_000
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }

    static func accessibilitySummary(for group: AgentActivityGroup) -> String {
        let duration = durationLabel(milliseconds: group.span.durationMilliseconds)
        let state = stateLabel(for: group.state)
        return "\(group.summary). \(state). \(duration)."
    }

    static func accessibilitySummary(for item: AgentActivityItem) -> String {
        var components = [item.summary]
        if let target = item.target, !target.isEmpty {
            components.append(target)
        }
        components.append(stateLabel(for: item.state))
        components.append(durationLabel(milliseconds: item.span.durationMilliseconds))
        return components.joined(separator: ". ") + "."
    }

    static func approvalAction(
        in group: AgentActivityGroup,
        approval: AgentActivityApproval
    ) -> AgentActivityItem? {
        group.items.first {
            $0.kind == .tool && $0.toolCallID == approval.callID
        }
    }

    static func attemptSummary(count: Int) -> String {
        count == 1 ? "Model work" : "Model work · \(count) attempts"
    }

    static func activityLabel(for item: AgentActivityItem) -> String {
        guard item.kind == .tool, !item.state.isTerminal else {
            return item.summary
        }

        return switch item.summary {
        case "Directory inspected": "Inspecting folder"
        case "Workspace tree inspected": "Scanning workspace"
        case "Workspace summarized": "Summarizing workspace"
        case "File metadata inspected": "Inspecting file"
        case "File read", "File range read", "File tail read": "Reading file"
        case "File written": "Creating file"
        case "File appended", "Text replaced": "Editing file"
        case "Path deleted": "Deleting path"
        case "Path moved": "Moving file"
        case "Path copied": "Copying file"
        case "Directory created": "Creating folder"
        case "Workspace searched": "Searching files"
        case "Files compared": "Comparing files"
        case "JSON validated": "Checking JSON"
        case "HTML validated": "Checking HTML"
        case "Outline extracted": "Reading document outline"
        case "Sandbox command completed": "Running command"
        default:
            switch item.state {
            case .pending, .queued: "Preparing action"
            case .running: "Working"
            case .awaitingApproval: "Waiting for approval"
            case .retrying: "Retrying action"
            case .cancelling: "Stopping action"
            case .succeeded, .failed, .rejected, .cancelled, .interrupted:
                item.summary
            }
        }
    }

    static func activitySymbol(for item: AgentActivityItem) -> String {
        guard item.kind == .tool else {
            return semanticSymbol(for: item.kind)
        }
        return switch item.summary {
        case "Directory inspected", "Directory created": "folder"
        case "Workspace tree inspected": "list.bullet.indent"
        case "Workspace summarized": "chart.bar.doc.horizontal"
        case "File metadata inspected": "info.circle"
        case "File read", "File range read", "File tail read": "doc.text"
        case "File written", "File appended", "Text replaced": "square.and.pencil"
        case "Path deleted": "trash"
        case "Path moved": "arrow.right.square"
        case "Path copied": "doc.on.doc"
        case "Workspace searched": "magnifyingglass"
        case "Files compared": "arrow.left.arrow.right"
        case "JSON validated", "HTML validated": "checkmark.seal"
        case "Outline extracted": "list.bullet.rectangle"
        case "Sandbox command completed": "terminal"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Pure summary policy for provider-backed V1 messages that predate the
/// canonical journal. It is deliberately count/state based so the fallback
/// never determines lifecycle state by searching output text.
struct LegacyToolActivityBatchPresentation: Equatable {
    enum Phase: Equatable {
        case running
        case awaitingApproval
        case succeeded
        case failed
    }

    let phase: Phase
    let summary: String
    let symbol: String

    init(
        totalCount: Int,
        completedCount: Int,
        failedCount: Int,
        pendingApprovalCount: Int,
        primaryTarget: String?
    ) {
        let total = max(0, totalCount)
        let completed = min(max(0, completedCount), total)
        let failed = min(max(0, failedCount), total)
        let pendingApproval = min(max(0, pendingApprovalCount), total)
        let target = primaryTarget.map { " · \($0)" } ?? ""

        if failed > 0 {
            phase = .failed
            let completedSuffix = completed > 0 ? " · \(completed) completed" : ""
            summary = "\(failed) failed\(completedSuffix)\(target)"
            symbol = "exclamationmark.triangle.fill"
        } else if pendingApproval > 0 {
            phase = .awaitingApproval
            let countPrefix = pendingApproval == 1
                ? "Approval needed"
                : "\(pendingApproval) approvals needed"
            summary = "\(countPrefix)\(target)"
            symbol = "checkmark.shield.fill"
        } else if total > 0 && completed == total {
            phase = .succeeded
            let noun = total == 1 ? "action" : "actions"
            summary = "\(total) \(noun) completed\(target)"
            symbol = "checkmark.circle.fill"
        } else {
            phase = .running
            let noun = total == 1 ? "action" : "actions"
            let progress = completed > 0 ? " · \(completed)/\(total) complete" : ""
            summary = "Working on \(total) \(noun)\(progress)\(target)"
            symbol = "waveform"
        }
    }
}

enum LegacyToolActivityPolicy {
    static func requiresApproval(_ toolName: String) -> Bool {
        [
            "write_file",
            "append_file",
            "replace_text",
            "run_command",
            "make_directory",
            "delete_path",
            "move_path",
            "copy_path",
        ].contains(toolName)
    }
}

private extension AgentCanonicalActivityPresentation {
    static func primarySummary(for group: AgentActivityGroup) -> String {
        if let active = group.items.last(where: { !$0.state.isTerminal }) {
            return activityLabel(for: active)
        }
        if group.state == .running,
           let latestTool = group.items.last(where: { $0.kind == .tool }) {
            return activityLabel(for: latestTool)
        }
        if group.state == .running, !group.attempts.isEmpty {
            return "Thinking"
        }
        if group.state == .succeeded {
            let duration = durationLabel(milliseconds: group.span.durationMilliseconds)
            return "Worked for \(duration.prefix(1).lowercased())\(duration.dropFirst())"
        }
        return group.summary
    }

    static func primarySymbol(for group: AgentActivityGroup) -> String {
        if let active = group.items.last(where: { !$0.state.isTerminal }) {
            return activitySymbol(for: active)
        }
        if group.state == .running, !group.attempts.isEmpty {
            return "brain.head.profile"
        }
        return stateSymbol(for: group.state)
    }

    private static func semanticSymbol(
        for kind: AgentActivitySemanticKind
    ) -> String {
        switch kind {
        case .modelAttempt: "brain.head.profile"
        case .plan: "checklist"
        case .tool: "wrench.and.screwdriver"
        case .approval: "checkmark.shield"
        case .retry: "arrow.clockwise"
        case .routeChange: "arrow.triangle.branch"
        case .checkpoint: "archivebox"
        case .cancellation: "stop.circle"
        case .failure: "exclamationmark.triangle"
        }
    }

    private static func stateSymbol(for state: AgentActivityState) -> String {
        switch state {
        case .pending: "hourglass"
        case .queued: "clock"
        case .running: "waveform"
        case .awaitingApproval: "checkmark.shield"
        case .retrying: "arrow.clockwise"
        case .succeeded: "checkmark"
        case .failed: "xmark"
        case .rejected: "hand.raised"
        case .cancelling: "stop"
        case .cancelled: "stop.fill"
        case .interrupted: "bolt.slash"
        }
    }

    static func isPresentableItem(_ item: AgentActivityItem) -> Bool {
        switch item.kind {
        case .modelAttempt, .retry, .routeChange, .approval:
            // Attempts/retries are nested under one model-work row. Pending
            // approvals use the dedicated exact-identity decision seam.
            false
        case .plan, .tool, .checkpoint, .cancellation, .failure:
            true
        }
    }

    static func selectedItems(
        from items: [AgentActivityItem],
        groupState: AgentActivityState,
        isExpanded: Bool
    ) -> [AgentActivityItem] {
        guard !items.isEmpty else { return [] }
        if isExpanded {
            return Array(items.suffix(expandedItemLimit))
        }

        switch groupState {
        case .succeeded, .rejected, .cancelled:
            return []
        case .failed, .interrupted:
            if let failed = items.last(where: {
                $0.state == .failed || $0.state == .interrupted
            }) {
                return [failed]
            }
            return Array(items.suffix(1))
        case .pending, .queued, .running, .awaitingApproval, .retrying,
             .cancelling:
            let focusIndex = items.lastIndex(where: { !$0.state.isTerminal })
                ?? items.index(before: items.endIndex)
            let lowerBound = max(items.startIndex, focusIndex - 1)
            return Array(items[lowerBound ... focusIndex])
        }
    }

    static func coalescedSuccessfulItemCount(
        all: [AgentActivityItem],
        visible: [AgentActivityItem]
    ) -> Int {
        let visibleIDs = Set(visible.map(\.id))
        return all.lazy.filter {
            $0.state == .succeeded && !visibleIDs.contains($0.id)
        }.count
    }
}
