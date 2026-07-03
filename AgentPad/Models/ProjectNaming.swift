//
//  ProjectNaming.swift
//  NovaForge
//
//  Identity and continuity: naming engine, continuation instructions,
//  launch conversation selection, and persistent launch recovery.
//

import Foundation
import SwiftData

struct ProjectIdentitySuggestion: Equatable {
    var name: String
    var mission: String
}

enum ProjectNamingEngine {
    static func shouldRename(_ project: Project) -> Bool {
        isGenericProjectName(project.name)
    }

    static func isGenericName(_ name: String) -> Bool {
        isGenericProjectName(name)
    }

    static func suggestedIdentity(
        prompt: String,
        currentProjectName: String,
        currentMission: String,
        existingProjectNames: Set<String>
    ) -> ProjectIdentitySuggestion? {
        guard isGenericProjectName(currentProjectName) else { return nil }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMission = currentMission.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = bestNamingSource(prompt: trimmedPrompt, mission: trimmedMission)
        let lower = source.lowercased()
        guard !source.isEmpty else { return nil }
        guard !isGenericProjectName(source) else { return nil }
        guard !isContinuationEnvelope(lower) || !isGenericMission(trimmedMission) else { return nil }

        let baseName = preferredName(from: lower, source: source)
        let uniqueName = uniqueProjectName(baseName, existingProjectNames: existingProjectNames)
        let mission = preferredMission(from: trimmedPrompt, currentMission: trimmedMission, name: uniqueName)
        return ProjectIdentitySuggestion(name: uniqueName, mission: mission)
    }

    static func identitySeed(from conversation: Conversation?) -> String? {
        guard let conversation else { return nil }
        if let prompt = conversation.messages
            .filter({ $0.role == .user })
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first?
            .content
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            return prompt
        }
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == LaunchConversationSelection.safeStartTitle { return nil }
        if isGenericProjectName(title) { return nil }
        return title
    }

    private static func isGenericProjectName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.isEmpty { return true }
        if lower == ProjectBootstrap.defaultProjectName.lowercased() { return true }
        if lower == "new project" || lower == "untitled project" { return true }
        if lower.range(of: #"^project\s+\d+$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^mission\s+draft\s+\d+$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^build\s+space\s+\d+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func bestNamingSource(prompt: String, mission: String) -> String {
        if !isGenericMission(mission) { return mission }
        return prompt
    }

    private static func isGenericMission(_ mission: String) -> Bool {
        let lower = mission.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return true }
        return lower == "build and verify useful work in novaforge." ||
            lower == "plan, build, and verify one focused outcome." ||
            lower == "send the first project request."
    }

    private static func isContinuationEnvelope(_ lower: String) -> Bool {
        lower.contains("novaforge project continuation") ||
            lower.contains("continue the active project")
    }

    private static func preferredName(from lower: String, source: String) -> String {
        if lower.contains("project os") && lower.contains("execution loop") {
            return "Project OS Execution Loop"
        }
        if lower.contains("autonomous") && lower.contains("builder") {
            return "Autonomous Builder Loop"
        }
        if lower.contains("agent") && lower.contains("proof") {
            return "Agent Proof Loop"
        }
        if lower.contains("project os") {
            return "Project OS"
        }
        if lower.contains("mission control") && lower.contains("project") {
            return "Mission Control"
        }
        if lower.contains("liquid glass") && lower.contains("project") {
            return "Liquid Glass Project Menu"
        }
        if lower.contains("slither") {
            return "Slither Game"
        }
        if lower.contains("snake") {
            return "Snake Game"
        }
        if lower.contains("game") {
            return "Game Build"
        }
        if lower.contains("dashboard") {
            return "Dashboard Build"
        }
        if lower.contains("landing page") || lower.contains("website") || lower.contains("web page") {
            return "Website Build"
        }
        if lower.contains("app") {
            return "App Build"
        }

        let words = source
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { word in
                word.count > 2 && !stopWords.contains(word) && Int(word) == nil
            }
            .prefix(4)
        let title = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return title.isEmpty ? "Project Build" : title
    }

    private static func preferredMission(from prompt: String, currentMission: String, name: String) -> String {
        if !isGenericMission(currentMission) { return currentMission }
        let compactPrompt = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compactPrompt.count > 24, !isContinuationEnvelope(compactPrompt.lowercased()) {
            let end = compactPrompt.index(compactPrompt.startIndex, offsetBy: min(compactPrompt.count, 140))
            return String(compactPrompt[..<end])
        }
        return "Build and verify \(name.lowercased())."
    }

    private static func uniqueProjectName(_ name: String, existingProjectNames: Set<String>) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Project Build" : cleaned
        let existing = Set(existingProjectNames.map { $0.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        for index in 2...99 {
            let candidate = "\(base) \(index)"
            if !existing.contains(candidate.lowercased()) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(4))"
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "into", "make",
        "build", "create", "continue", "project", "please", "should", "would",
        "your", "nova", "novaforge", "active", "latest", "next", "step"
    ]
}

enum ProjectContinuationInstructionBuilder {
    static func makeInstruction(
        project: Project,
        summary: ProjectMissionSummary,
        intent: ProjectCommandIntent = .continueMission,
        operatorNote: String = ""
    ) -> String {
        var lines = [
            "NovaForge Project Continuation",
            "Continue the active project as an agent run. Do not merely restate this brief or ask the user to paste it again.",
            "Project: \(project.name)",
            "Mission: \(summary.missionText)",
            "Evidence totals: \(summary.toolRunCount) tool run(s), \(summary.terminalCommandCount) command(s), \(summary.artifactCount) artifact(s), \(summary.fileChangeCount) file change(s), \(summary.failureCount) issue(s).",
            "Project command: \(intent.displayName)",
            "Command focus: \(intent.instructionFocus)"
        ]

        if let latestProof = summary.proofItems.first,
           !latestProof.title.localizedCaseInsensitiveContains("Project created") {
            lines.append("Latest proof: \(latestProof.title) — \(latestProof.detail)")
        }

        let blocker = summary.blocker.trimmingCharacters(in: .whitespacesAndNewlines)
        if !blocker.isEmpty {
            lines.append("Blocker: \(blocker)")
        }

        let note = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            lines.append("Operator note: \(note)")
        }

        lines.append("Latest timeline event: \(summary.lastEventTitle) — \(summary.lastEventDetail)")
        lines.append("Recommended next step: \(summary.nextStep)")
        lines.append("Mission OS Contract:")
        lines.append("Phase: \(summary.missionContract.phase.displayName)")
        lines.append("Readiness: \(summary.missionContract.readinessScore)/100 (\(summary.missionContract.gateSummary))")
        lines.append("Mission OS recommends: \(summary.missionContract.recommendedIntent.displayName)")
        lines.append("Operator directive: \(summary.missionContract.operatorDirective)")
        lines.append("Proof requirement: \(summary.missionContract.proofRequirement)")
        lines.append("Decision state: \(summary.missionContract.decisionLabel)")
        lines.append("Quality gates:")
        for gate in summary.missionContract.gates {
            lines.append("- \(gate.state.displayName): \(gate.title) — \(gate.detail)")
        }
        lines.append("Success criteria:")
        for criterion in summary.missionContract.successCriteria {
            lines.append("- \(criterion)")
        }
        lines.append("Intent Handling: follow the selected project command first, but override it if the evidence shows a more urgent blocker, approval, or verification gap.")
        lines.append("Fast Proof: for UI proof, prefer the existing fast screenshot/proof commands and reuse a fresh binary; run a full Xcode build only when source changes require it.")
        lines.append("Agent Plan: first state the concrete next action you are taking and why. Choose from the mission, proof, blocker, latest run, changed files, and workspace state.")
        lines.append("Agent Work: inspect files, edit code, run safe commands/checks, or ask one clarifying question only if the next action is genuinely ambiguous. Respect approval requirements for mutating tools.")
        lines.append("Agent Proof: finish with a concise status plus files changed, commands/checks run, artifacts created or previewed, and any remaining blocker or next step.")
        lines.append("If the project still has a generic name, decide a concise project name from the mission/request and state it in the response.")
        return lines.joined(separator: "\n")
    }
}

enum LaunchConversationSelection {
    static let persistedSelectionKey = "novaForgeSelectedConversationID"
    static let safeStartTitle = "NovaForge Ready"

    static func preferredConversation(
        from conversations: [Conversation],
        sessionID: UUID?,
        persistedIDString: String
    ) -> Conversation? {
        if let sessionID,
           let match = conversations.first(where: { $0.id == sessionID }) {
            return match
        }

        if let ready = conversations.first(where: { $0.title == safeStartTitle && !$0.hasUserMessages }) {
            return ready
        }

        if let persistedID = UUID(uuidString: persistedIDString),
           let persisted = conversations.first(where: { $0.id == persistedID }),
           isLaunchRestorable(persisted) {
            return persisted
        }

        return conversations.first
    }

    static func preferredConversation(
        from conversations: [Conversation],
        sessionID: UUID?,
        persistedIDString: String,
        project: Project?
    ) -> Conversation? {
        guard let project else {
            return preferredConversation(
                from: conversations,
                sessionID: sessionID,
                persistedIDString: persistedIDString
            )
        }
        let projectConversations = conversations.filter { $0.project?.id == project.id }
        return preferredConversation(
            from: projectConversations,
            sessionID: sessionID,
            persistedIDString: persistedIDString
        )
    }

    static func isLaunchRestorable(_ conversation: Conversation) -> Bool {
        guard conversation.hasUserMessages else { return false }
        guard let latest = conversation.messages.max(by: messageAscending) else { return false }

        // A launch restore should land on a settled chat. If the last persisted
        // item is a user prompt, tool output, or assistant tool request, the app
        // likely closed mid-run; start safe instead of showing a stuck old chat.
        guard latest.role == .assistant else { return false }
        if let toolCalls = latest.toolCalls, !toolCalls.isEmpty { return false }

        let trimmedContent = latest.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }

        let lowercased = trimmedContent.lowercased()
        if lowercased.hasPrefix("i hit an error:") { return false }
        if lowercased.contains("tap retry") || lowercased.contains("provider setup needed") { return false }
        if lowercased.contains("run paused") || lowercased.contains("cancelled while waiting for approval") { return false }
        return true
    }

    private static func messageAscending(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum ChatProjectSeparation {
    static func visibleChatConversations(from conversations: [Conversation]) -> [Conversation] {
        let general = conversations.filter { $0.project == nil }
        return general.isEmpty ? conversations : general
    }

    static func preferredGeneralConversation(
        from conversations: [Conversation],
        selectedID: UUID?,
        persistedIDString: String
    ) -> Conversation? {
        let general = visibleChatConversations(from: conversations)
        if let ready = general.first(where: { $0.title == LaunchConversationSelection.safeStartTitle && !$0.hasUserMessages }) {
            return ready
        }
        if let selectedID,
           let selected = general.first(where: { $0.id == selectedID }) {
            return selected
        }
        if let persistedID = UUID(uuidString: persistedIDString),
           let persisted = general.first(where: { $0.id == persistedID }),
           LaunchConversationSelection.isLaunchRestorable(persisted) {
            return persisted
        }
        if let restorable = general.first(where: LaunchConversationSelection.isLaunchRestorable) {
            return restorable
        }
        return general.first
    }
}

enum PersistentLaunchRecovery {
    static func recoverInterruptedToolRuns(in context: ModelContext, now: Date = Date()) {
        let pending = ToolRunStatus.pendingApproval.rawValue
        let approved = ToolRunStatus.approved.rawValue
        let descriptor = FetchDescriptor<ToolRun>(
            predicate: #Predicate<ToolRun> { run in
                run.statusRawValue == pending || run.statusRawValue == approved
            }
        )

        guard let interruptedRuns = try? context.fetch(descriptor) else { return }
        for run in interruptedRuns {
            switch run.status {
            case .pendingApproval:
                run.status = .rejected
                run.output = PersistedPayloadBudget.compactToolRunOutput(recoveryOutput(
                    existingOutput: run.output,
                    message: "Recovered after app restart: NovaForge cancelled this stale approval before launch so the Runs view cannot stay pending forever. Re-run the request when ready."
                ))
                ProjectEventRecorder.record(
                    project: run.project,
                    kind: .toolRejected,
                    title: "Recovered stale approval",
                    detail: run.name,
                    severity: .warning,
                    sourceType: .toolRun,
                    sourceID: run.id,
                    context: context,
                    now: now
                )
            case .approved:
                run.status = .failed
                run.output = PersistedPayloadBudget.compactToolRunOutput(recoveryOutput(
                    existingOutput: run.output,
                    message: "Recovered after app restart: this approved tool did not finish before the app closed, so NovaForge marked it failed instead of leaving it in progress."
                ))
                ProjectEventRecorder.record(
                    project: run.project,
                    kind: .toolFailed,
                    title: "Recovered unfinished tool",
                    detail: run.name,
                    severity: .failure,
                    sourceType: .toolRun,
                    sourceID: run.id,
                    context: context,
                    now: now
                )
            default:
                continue
            }
            run.completedAt = now
        }

        recoverInterruptedProjectOSRuns(in: context, now: now)
        recoverInterruptedAutoContinue(in: context, now: now)
    }

    private static func recoverInterruptedProjectOSRuns(in context: ModelContext, now: Date) {
        let planning = ProjectOSRunStatus.planning.rawValue
        let running = ProjectOSRunStatus.running.rawValue
        let descriptor = FetchDescriptor<ProjectOSRun>(
            predicate: #Predicate<ProjectOSRun> { run in
                run.statusRawValue == planning || run.statusRawValue == running
            }
        )
        guard let runs = try? context.fetch(descriptor) else { return }
        for run in runs {
            run.status = .stopped
            run.resumeState = "Stopped after relaunch. Start or retry the mission from ProjectOS when ready."
            run.currentAction = "Run stopped after relaunch"
            run.updatedAt = now
            run.completedAt = now
            run.applyIntent(ProjectOSIntentDeriver.makeRecoveryIntent(run: run, now: now))
            for step in run.steps where !step.status.isTerminal {
                step.status = .stopped
                step.resultSummary = run.resumeState
                step.updatedAt = now
                step.completedAt = now
            }
        }
    }

    private static func recoverInterruptedAutoContinue(in context: ModelContext, now: Date) {
        let countdown = ProjectAutoContinueState.countdown.rawValue
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate<Project> { project in
                project.autoContinueStateRawValue == countdown
            }
        )
        guard let projects = try? context.fetch(descriptor) else { return }
        for project in projects {
            project.autoContinuePaused = true
            project.autoContinueState = .paused
            project.autoContinueDecision = "Paused after relaunch before starting the next automatic step."
            project.autoContinueUpdatedAt = now
            ProjectEventRecorder.record(
                project: project,
                kind: .autoContinuePaused,
                title: "Auto-continue paused after relaunch",
                detail: project.autoContinueDecision ?? "",
                severity: .warning,
                sourceType: .system,
                context: context,
                now: now
            )
        }
    }

    private static func recoveryOutput(existingOutput: String, message: String) -> String {
        let trimmed = existingOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return message }
        return "\(trimmed)\n\n\(message)"
    }
}
