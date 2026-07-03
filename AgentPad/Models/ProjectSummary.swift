//
//  ProjectSummary.swift
//  NovaForge
//
//  Mission OS derivation: intake/edit drafts, contracts, gates,
//  checkpoints, review builders, evidence freshness, and the summarizer.
//

import Foundation
import SwiftData

struct ProjectIntakeDraft: Equatable, Sendable {
    var workingTitle: String
    var projectKind: String
    var platform: String
    var style: String = ""
    var goal: String = ""
    var startingPriorities: String = ""
    var playerExperience: String
    var constraints: String

    static let empty = ProjectIntakeDraft(
        workingTitle: "",
        projectKind: "",
        platform: "",
        style: "",
        goal: "",
        startingPriorities: "",
        playerExperience: "",
        constraints: ""
    )

    var isEmpty: Bool {
        [workingTitle, projectKind, platform, style, goal, startingPriorities, playerExperience, constraints]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var seedPrompt: String {
        [
            ("Working title", workingTitle),
            ("Project type", projectKind),
            ("Platform", platform),
            ("Style", style),
            ("Goal", goal),
            ("Starting priorities", startingPriorities),
            ("Experience", playerExperience),
            ("Constraints", constraints)
        ]
        .compactMap { label, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "\(label): \(trimmed)"
        }
        .joined(separator: "\n")
    }

    var missionText: String {
        let kind = projectKind.trimmingCharacters(in: .whitespacesAndNewlines)
        let experience = playerExperience.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let constraints = constraints.trimmingCharacters(in: .whitespacesAndNewlines)

        var pieces: [String] = []
        if !kind.isEmpty {
            pieces.append("Build \(kind)")
        } else {
            pieces.append("Build and verify a focused project")
        }
        if !experience.isEmpty {
            pieces.append("that feels like \(experience)")
        }
        if !style.isEmpty {
            pieces.append("with a \(style) style")
        }
        if !platform.isEmpty {
            pieces.append("for \(platform)")
        }
        if !goal.isEmpty {
            pieces.append("so it can \(goal)")
        }
        if !constraints.isEmpty {
            pieces.append("while respecting \(constraints)")
        }
        return pieces.joined(separator: " ") + "."
    }

    var firstNextStep: String {
        if isGameProject {
            return "Define the core loop, first playable scene, controls, and proof check."
        }
        if isAppProject {
            return "Define the primary user flow, first screen, data needs, and proof check."
        }
        return "Turn the brief into the first concrete build task and proof check."
    }

    var initialAgentTasks: [String] {
        let platformText = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        let platformSuffix = platformText.isEmpty ? "" : " for \(platformText)"
        let goalText = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let styleText = style.trimmingCharacters(in: .whitespacesAndNewlines)
        let priorityTasks = startingPriorities
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { "Prioritize \($0)\(platformSuffix)." }
        if !priorityTasks.isEmpty {
            var tasks = Array(priorityTasks)
            if !goalText.isEmpty {
                tasks.append("Verify the first slice proves the goal: \(goalText).")
            } else {
                tasks.append("Run the fastest relevant proof check and record what changed.")
            }
            return tasks
        }
        if isGameProject {
            return [
                goalText.isEmpty ? "Lock the core loop and player objective\(platformSuffix)." : "Shape the core loop around the goal: \(goalText).",
                styleText.isEmpty ? "Build or outline the first playable scene, controls, and feedback." : "Make the first playable scene feel \(styleText) through controls, pacing, and feedback.",
                "Run the fastest proof check for feel, readability, and a screenshot or artifact."
            ]
        }
        if isAppProject {
            return [
                goalText.isEmpty ? "Map the primary user flow\(platformSuffix)." : "Map the primary user flow that proves: \(goalText).",
                styleText.isEmpty ? "Build or outline the first useful screen and data path." : "Build or outline the first useful screen with a \(styleText) interaction style.",
                "Run the fastest proof check for the flow, layout, and saved artifact."
            ]
        }
        return [
            "Turn the brief into one concrete build target\(platformSuffix).",
            "Create the smallest useful artifact or implementation step.",
            "Run the fastest relevant proof check and record what changed."
        ]
    }

    var initialTaskPreview: String {
        initialAgentTasks.joined(separator: " ")
    }

    var firstRunOperatorNote: String {
        "Use the project intake to choose the first tasks: \(initialAgentTasks.joined(separator: " "))"
    }

    private var isGameProject: Bool {
        let lower = projectKind.lowercased()
        return lower.contains("game") ||
            lower.contains("roguelite") ||
            lower.contains("platformer") ||
            lower.contains("arcade") ||
            lower.contains("puzzle") ||
            lower.contains("rpg") ||
            lower.contains("shooter")
    }

    private var isAppProject: Bool {
        let lower = projectKind.lowercased()
        return lower.contains("app") ||
            lower.contains("tool") ||
            lower.contains("dashboard") ||
            lower.contains("site") ||
            lower.contains("website")
    }
}

struct ProjectEditDraft: Equatable {
    var name: String
    var mission: String
    var workspaceName: String
    var nextStep: String
    var blocker: String
    var status: ProjectState

    init(
        name: String,
        mission: String,
        workspaceName: String,
        nextStep: String,
        blocker: String,
        status: ProjectState
    ) {
        self.name = name
        self.mission = mission
        self.workspaceName = workspaceName
        self.nextStep = nextStep
        self.blocker = blocker
        self.status = status
    }

    init(project: Project) {
        self.init(
            name: project.name,
            mission: project.mission,
            workspaceName: project.workspaceName,
            nextStep: project.nextStep,
            blocker: project.blocker,
            status: project.status
        )
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum MissionOSPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case contract
    case plan
    case act
    case verify
    case proof
    case decide

    var displayName: String {
        switch self {
        case .contract: "Contract"
        case .plan: "Plan"
        case .act: "Act"
        case .verify: "Verify"
        case .proof: "Proof"
        case .decide: "Decide"
        }
    }

    var symbolName: String {
        switch self {
        case .contract: "doc.text.magnifyingglass"
        case .plan: "list.bullet.clipboard.fill"
        case .act: "hammer.fill"
        case .verify: "checkmark.shield.fill"
        case .proof: "checkmark.seal.fill"
        case .decide: "arrow.triangle.branch"
        }
    }
}

enum MissionOSGateState: String, Codable, CaseIterable, Equatable, Sendable {
    case satisfied
    case waiting
    case blocked

    var displayName: String {
        switch self {
        case .satisfied: "Ready"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        }
    }

    var symbolName: String {
        switch self {
        case .satisfied: "checkmark.circle.fill"
        case .waiting: "hourglass"
        case .blocked: "exclamationmark.triangle.fill"
        }
    }
}

struct MissionOSGate: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var detail: String
    var state: MissionOSGateState
    var weight: Int

    var isBlocking: Bool { state == .blocked }
}

struct MissionOSContract: Equatable, Sendable {
    var headline: String
    var operatorDirective: String
    var phase: MissionOSPhase
    var recommendedIntent: ProjectCommandIntent
    var successCriteria: [String]
    var proofRequirement: String
    var nextAction: String
    var decisionLabel: String
    var readinessScore: Int
    var gates: [MissionOSGate]

    var blockingGates: [MissionOSGate] {
        gates.filter(\.isBlocking)
    }

    var gateSummary: String {
        let ready = gates.filter { $0.state == .satisfied }.count
        return "\(ready)/\(gates.count) gates ready"
    }
}

struct MissionOSCheckpoint: Equatable, Sendable {
    static let metadataKind = "missionOSCheckpoint"
    static let schemaVersion = "1"

    var phase: MissionOSPhase
    var readinessScore: Int
    var decisionLabel: String
    var recommendedIntent: ProjectCommandIntent
    var gateSummary: String
    var blockingGateIDs: [String]
    var proofRequirement: String
    var operatorDirective: String
    var nextAction: String
    var trigger: String

    init(contract: MissionOSContract, trigger: String) {
        self.phase = contract.phase
        self.readinessScore = contract.readinessScore
        self.decisionLabel = contract.decisionLabel
        self.recommendedIntent = contract.recommendedIntent
        self.gateSummary = contract.gateSummary
        self.blockingGateIDs = contract.blockingGates.map(\.id)
        self.proofRequirement = contract.proofRequirement
        self.operatorDirective = contract.operatorDirective
        self.nextAction = contract.nextAction
        self.trigger = trigger
    }

    init?(event: ProjectEvent) {
        guard event.kind == .missionCheckpoint else { return nil }
        let metadata = event.metadata
        guard metadata["kind"] == Self.metadataKind,
              metadata["schemaVersion"] == Self.schemaVersion,
              let phaseRaw = metadata["phase"],
              let phase = MissionOSPhase(rawValue: phaseRaw),
              let readinessRaw = metadata["readinessScore"],
              let readinessScore = Int(readinessRaw),
              let intentRaw = metadata["recommendedIntent"],
              let recommendedIntent = ProjectCommandIntent(rawValue: intentRaw) else {
            return nil
        }
        self.phase = phase
        self.readinessScore = readinessScore
        self.decisionLabel = metadata["decisionLabel"] ?? ""
        self.recommendedIntent = recommendedIntent
        self.gateSummary = metadata["gateSummary"] ?? ""
        self.blockingGateIDs = (metadata["blockingGateIDs"] ?? "")
            .split(separator: ",")
            .map(String.init)
        self.proofRequirement = metadata["proofRequirement"] ?? ""
        self.operatorDirective = metadata["operatorDirective"] ?? event.detail
        self.nextAction = metadata["nextAction"] ?? ""
        self.trigger = metadata["trigger"] ?? ""
    }

    var metadata: [String: String] {
        [
            "kind": Self.metadataKind,
            "schemaVersion": Self.schemaVersion,
            "phase": phase.rawValue,
            "readinessScore": "\(readinessScore)",
            "decisionLabel": decisionLabel,
            "recommendedIntent": recommendedIntent.rawValue,
            "gateSummary": gateSummary,
            "blockingGateIDs": blockingGateIDs.joined(separator: ","),
            "proofRequirement": proofRequirement,
            "operatorDirective": operatorDirective,
            "nextAction": nextAction,
            "trigger": trigger
        ]
    }

    var eventSeverity: ProjectEventSeverity {
        if !blockingGateIDs.isEmpty { return .warning }
        if readinessScore >= 85 { return .success }
        switch phase {
        case .plan, .act, .verify:
            return .running
        case .contract, .proof, .decide:
            return .info
        }
    }
}

struct ProjectRunLogCleanupResult: Equatable {
    var artifactLinksDetached = 0
    var terminalLinksDetached = 0
    var fileChangeLinksDetached = 0
    var eventLinksDetached = 0

    var totalDetachedLinks: Int {
        artifactLinksDetached + terminalLinksDetached + fileChangeLinksDetached + eventLinksDetached
    }
}

enum ProjectRunLogCleanup {
    @discardableResult
    static func detachDeletedRunProvenance(for run: ToolRun, context: ModelContext) throws -> ProjectRunLogCleanupResult {
        let sourceID = run.id.uuidString
        var result = ProjectRunLogCleanupResult()

        let artifacts = try context.fetch(FetchDescriptor<ProjectArtifact>())
        for artifact in artifacts where artifact.sourceToolRunIDString == sourceID {
            artifact.sourceToolRunIDString = nil
            result.artifactLinksDetached += 1
        }

        let terminalCommands = try context.fetch(FetchDescriptor<TerminalCommandRecord>())
        for command in terminalCommands where command.sourceToolRunIDString == sourceID {
            command.sourceToolRunIDString = nil
            result.terminalLinksDetached += 1
        }

        let fileChanges = try context.fetch(FetchDescriptor<ProjectFileChange>())
        for change in fileChanges where change.sourceToolRunIDString == sourceID {
            change.sourceToolRunIDString = nil
            result.fileChangeLinksDetached += 1
        }

        let events = try context.fetch(FetchDescriptor<ProjectEvent>())
        for event in events where event.sourceType == .toolRun && event.sourceIDString == sourceID {
            event.sourceType = nil
            event.sourceIDString = nil
            result.eventLinksDetached += 1
        }

        return result
    }
}

struct ProjectTimelineItem: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var kindTitle: String
    var createdAt: Date
    var severity: ProjectEventSeverity
    var sourceKind: ProjectEventKind?
}

struct ProjectProofItem: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var createdAt: Date
    var symbolName: String
    var sourcePath: String?
    var severity: ProjectEventSeverity = .success
}

struct ProjectWorkflowSpine: Equatable, Sendable {
    var currentTitle: String
    var currentDetail: String
    var changedTitle: String
    var changedDetail: String
    var proofTitle: String
    var proofDetail: String
    var blockerTitle: String
    var blockerDetail: String
    var nextActionTitle: String
    var nextActionDetail: String
    var iterationPrompt: String
    var latestArtifactPath: String?
    var latestChangedPath: String?
    var latestTerminalCommand: String?
}

enum ProjectReviewRecommendation: String, Codable, CaseIterable, Equatable, Sendable {
    case continueMission
    case verifyWork
    case askUser
    case fixBlocker
    case finalReview

    var displayName: String {
        switch self {
        case .continueMission: "Continue"
        case .verifyWork: "Verify"
        case .askUser: "Ask User"
        case .fixBlocker: "Fix Blocker"
        case .finalReview: "Final Review"
        }
    }

    var symbolName: String {
        switch self {
        case .continueMission: "arrow.triangle.2.circlepath"
        case .verifyWork: "checkmark.shield.fill"
        case .askUser: "person.crop.circle.badge.questionmark"
        case .fixBlocker: "wrench.and.screwdriver.fill"
        case .finalReview: "flag.checkered"
        }
    }
}

struct ProjectReviewFinding: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var detail: String
    var severity: ProjectEventSeverity
    var symbolName: String
}

struct ProjectReviewSummary: Equatable, Sendable {
    var headline: String
    var detail: String
    var recommendation: ProjectReviewRecommendation
    var healthScore: Int
    var proofFreshness: String
    var evidenceTrail: String
    var findings: [ProjectReviewFinding]

    var riskCount: Int {
        findings.filter { $0.severity == .warning || $0.severity == .failure }.count
    }

    var primaryFinding: ProjectReviewFinding? {
        findings.first { $0.severity == .failure } ??
            findings.first { $0.severity == .warning } ??
            findings.first
    }

    var hasWrongProjectRisk: Bool {
        findings.contains { $0.id == "wrong-project-risk" }
    }

    var hasStaleProof: Bool {
        findings.contains { $0.id == "stale-proof" }
    }

    var hasMissingEvidence: Bool {
        findings.contains { $0.id == "missing-evidence" || $0.id == "missing-verification" || $0.id == "missing-proof" }
    }
}

struct ProjectMissionSummary: Equatable {
    var status: ProjectState
    var statusKind: ProjectMissionStatusKind
    var statusText: String
    var missionText: String
    var conversationCount: Int
    var toolRunCount: Int
    var terminalCommandCount: Int
    var artifactCount: Int
    var fileChangeCount: Int
    var eventCount: Int
    var failureCount: Int
    var pendingApprovalCount: Int
    var lastEventTitle: String
    var lastEventDetail: String
    var nextStep: String
    var latestProofTitle: String
    var blocker: String
    var timelineItems: [ProjectTimelineItem]
    var proofItems: [ProjectProofItem]
    var missionContract: MissionOSContract
    var review: ProjectReviewSummary
    var workflowSpine: ProjectWorkflowSpine

    var trustText: String {
        if failureCount > 0 { return "\(failureCount) issue\(failureCount == 1 ? "" : "s") need review" }
        if pendingApprovalCount > 0 { return "\(pendingApprovalCount) approval\(pendingApprovalCount == 1 ? "" : "s") waiting" }
        if toolRunCount + terminalCommandCount + artifactCount + fileChangeCount == 0 { return "No project actions recorded yet" }
        return "Timeline is current"
    }
}

struct ProjectEvidenceFreshness: Equatable {
    var hasAnyProof: Bool
    var hasCurrentProof: Bool
    var hasAnyVerification: Bool
    var hasCurrentVerification: Bool
    var latestProofAt: Date?
    var latestVerificationAt: Date?
    var latestInvalidatingWorkAt: Date?

    static func make(
        proofItems: [ProjectProofItem],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent]
    ) -> ProjectEvidenceFreshness {
        let meaningfulProofItems = proofItems.filter { !$0.title.localizedCaseInsensitiveContains("Project created") }
        let latestProofAt = meaningfulProofItems
            .filter { $0.severity == .success || $0.severity == .info }
            .map(\.createdAt)
            .max()
        let verificationRuns = toolRuns.filter { $0.status == .completed && isVerificationToken($0.name) }
        let verificationRunIDs = Set(verificationRuns.map { $0.id.uuidString })
        let verificationDates = verificationRuns.map { $0.completedAt ?? $0.createdAt } +
            terminalCommands
                .filter { $0.status == .completed && isVerificationCommand($0.command) }
                .map(\.completedAt)
        let latestVerificationAt = verificationDates.max()
        let latestProofInvalidatingWorkAt = latestInvalidatingWorkDate(
            toolRuns: toolRuns,
            fileChanges: fileChanges,
            events: events,
            verificationRunIDsToIgnore: []
        )
        let latestVerificationInvalidatingWorkAt = latestInvalidatingWorkDate(
            toolRuns: toolRuns,
            fileChanges: fileChanges,
            events: events,
            verificationRunIDsToIgnore: verificationRunIDs
        )
        let hasAnyProof = latestProofAt != nil
        let hasAnyVerification = latestVerificationAt != nil
        return ProjectEvidenceFreshness(
            hasAnyProof: hasAnyProof,
            hasCurrentProof: hasAnyProof && isFresh(latestProofAt, against: latestProofInvalidatingWorkAt),
            hasAnyVerification: hasAnyVerification,
            hasCurrentVerification: hasAnyVerification && isFresh(latestVerificationAt, against: latestVerificationInvalidatingWorkAt),
            latestProofAt: latestProofAt,
            latestVerificationAt: latestVerificationAt,
            latestInvalidatingWorkAt: latestProofInvalidatingWorkAt
        )
    }

    private static func latestInvalidatingWorkDate(
        toolRuns: [ToolRun],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent],
        verificationRunIDsToIgnore: Set<String>
    ) -> Date? {
        var dates: [Date] = []
        dates += toolRuns.compactMap { run in
            guard run.isMutating, !verificationRunIDsToIgnore.contains(run.id.uuidString) else { return nil }
            return run.completedAt ?? run.createdAt
        }
        dates += fileChanges.compactMap { change in
            if let sourceID = change.sourceToolRunIDString,
               verificationRunIDsToIgnore.contains(sourceID) {
                return nil
            }
            return change.createdAt
        }
        dates += events.compactMap { event in
            switch event.kind {
            case .agentPlanCreated, .toolApprovalRequested, .workspaceChanged:
                return event.createdAt
            default:
                return nil
            }
        }
        return dates.max()
    }

    private static func isFresh(_ proofDate: Date?, against workDate: Date?) -> Bool {
        guard let proofDate else { return false }
        guard let workDate else { return true }
        return proofDate >= workDate.addingTimeInterval(-1)
    }

    private static func isVerificationToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("test") ||
            lower.contains("build") ||
            lower.contains("validate") ||
            lower.contains("check") ||
            lower.contains("proof") ||
            lower.contains("screenshot") ||
            lower.contains("smoke") ||
            lower.contains("tour") ||
            lower.contains("diff")
    }

    private static func isVerificationCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return isVerificationToken(lower) ||
            lower.contains("xcodebuild") ||
            lower.contains("swift test") ||
            lower.contains("npm test")
    }
}

enum MissionOSContractBuilder {
    static func make(
        project: Project,
        missionText: String,
        statusKind: ProjectMissionStatusKind,
        conversations: [Conversation],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent],
        failures: Int,
        pendingApprovals: Int,
        nextStep: String,
        proofItems: [ProjectProofItem],
        activeBlocker: String? = nil
    ) -> MissionOSContract {
        let blocker = (activeBlocker ?? project.blocker).trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFailure = failures > 0 || statusKind == .blocked || !blocker.isEmpty
        let hasPendingApproval = pendingApprovals > 0 || statusKind == .waiting
        let hasSpecificMission = !isGenericMission(missionText) || !ProjectNamingEngine.isGenericName(project.name)
        let meaningfulProofItems = proofItems.filter { !$0.title.localizedCaseInsensitiveContains("Project created") }
        let hasProjectWork = !toolRuns.isEmpty || !terminalCommands.isEmpty || !artifacts.isEmpty || !fileChanges.isEmpty
        let freshness = ProjectEvidenceFreshness.make(
            proofItems: proofItems,
            toolRuns: toolRuns,
            terminalCommands: terminalCommands,
            fileChanges: fileChanges,
            events: events
        )
        let hasProof = freshness.hasCurrentProof
        let hasVerification = freshness.hasCurrentVerification
        let hasPlanCheckpoint = events.contains { $0.kind == .agentPlanCreated }
        let hasProofCheckpoint = events.contains { $0.kind == .agentProofCreated }
        let hasCheckpointPair = hasPlanCheckpoint && hasProofCheckpoint
        let latestProof = meaningfulProofItems.first

        let contractGate = MissionOSGate(
            id: "contract",
            title: "Mission Contract",
            detail: hasSpecificMission ? compact(missionText, limit: 118) : "Name the outcome and success criteria before deep work.",
            state: hasSpecificMission ? .satisfied : .waiting,
            weight: 16
        )
        let actionGate = MissionOSGate(
            id: "action",
            title: "Action Trail",
            detail: hasProjectWork ? "\(toolRuns.count) run(s), \(terminalCommands.count) command(s), \(fileChanges.count) change(s)" : "No project-owned work has been recorded yet.",
            state: hasProjectWork ? .satisfied : .waiting,
            weight: 15
        )
        let checkpointGate = MissionOSGate(
            id: "checkpoints",
            title: "Run Checkpoints",
            detail: checkpointDetail(hasPlanCheckpoint: hasPlanCheckpoint, hasProofCheckpoint: hasProofCheckpoint, hasProjectWork: hasProjectWork),
            state: checkpointState(hasPlanCheckpoint: hasPlanCheckpoint, hasProofCheckpoint: hasProofCheckpoint, hasProjectWork: hasProjectWork, hasFailure: hasFailure),
            weight: 17
        )
        let safetyGate = MissionOSGate(
            id: "safety",
            title: "Safety",
            detail: safetyDetail(hasFailure: hasFailure, failures: failures, pendingApprovals: pendingApprovals, blocker: blocker),
            state: hasFailure ? .blocked : hasPendingApproval ? .waiting : .satisfied,
            weight: 20
        )
        let verificationGate = MissionOSGate(
            id: "verification",
            title: "Verification",
            detail: verificationDetail(
                hasVerification: hasVerification,
                hasAnyVerification: freshness.hasAnyVerification,
                hasProjectWork: hasProjectWork
            ),
            state: hasFailure ? .blocked : hasVerification ? .satisfied : .waiting,
            weight: 18
        )
        let proofGate = MissionOSGate(
            id: "proof",
            title: "Proof",
            detail: proofDetail(
                latestProof: latestProof,
                hasCurrentProof: hasProof,
                hasAnyProof: freshness.hasAnyProof
            ),
            state: hasFailure ? .blocked : hasProof ? .satisfied : .waiting,
            weight: 14
        )
        let gates = [contractGate, actionGate, checkpointGate, safetyGate, verificationGate, proofGate]
        let score = readinessScore(for: gates)
        let phase = phase(
            hasSpecificMission: hasSpecificMission,
            hasPlanCheckpoint: hasPlanCheckpoint,
            hasProofCheckpoint: hasProofCheckpoint,
            hasProjectWork: hasProjectWork,
            hasVerification: hasVerification,
            hasProof: hasProof,
            hasFailure: hasFailure,
            hasPendingApproval: hasPendingApproval,
            statusKind: statusKind
        )
        let recommendedIntent = recommendedIntent(
            hasSpecificMission: hasSpecificMission,
            hasPlanCheckpoint: hasPlanCheckpoint,
            hasProjectWork: hasProjectWork,
            hasVerification: hasVerification,
            hasProof: hasProof,
            hasAnyProof: freshness.hasAnyProof,
            hasFailure: hasFailure,
            hasPendingApproval: hasPendingApproval,
            nextStep: nextStep,
            artifactCount: artifacts.count
        )

        return MissionOSContract(
            headline: headline(phase: phase, score: score, hasFailure: hasFailure, hasPendingApproval: hasPendingApproval, hasCheckpointPair: hasCheckpointPair),
            operatorDirective: operatorDirective(phase: phase, recommendedIntent: recommendedIntent, nextStep: nextStep),
            phase: phase,
            recommendedIntent: recommendedIntent,
            successCriteria: successCriteria(missionText: missionText, hasSpecificMission: hasSpecificMission),
            proofRequirement: proofRequirement(
                hasVerification: hasVerification,
                hasProof: hasProof,
                hasAnyVerification: freshness.hasAnyVerification,
                hasAnyProof: freshness.hasAnyProof,
                hasCheckpointPair: hasCheckpointPair,
                latestProof: latestProof
            ),
            nextAction: compact(nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? recommendedIntent.instructionFocus : nextStep, limit: 180),
            decisionLabel: decisionLabel(score: score, hasFailure: hasFailure, hasPendingApproval: hasPendingApproval, hasVerification: hasVerification, hasProof: hasProof, hasCheckpointPair: hasCheckpointPair),
            readinessScore: score,
            gates: gates
        )
    }

    private static func phase(
        hasSpecificMission: Bool,
        hasPlanCheckpoint: Bool,
        hasProofCheckpoint: Bool,
        hasProjectWork: Bool,
        hasVerification: Bool,
        hasProof: Bool,
        hasFailure: Bool,
        hasPendingApproval: Bool,
        statusKind: ProjectMissionStatusKind
    ) -> MissionOSPhase {
        if hasFailure || hasPendingApproval || statusKind == .blocked || statusKind == .waiting { return .decide }
        if !hasSpecificMission { return .contract }
        if !hasPlanCheckpoint { return .plan }
        if !hasProjectWork { return .act }
        if !hasVerification { return .verify }
        if !hasProof || !hasProofCheckpoint { return .proof }
        return .decide
    }

    private static func recommendedIntent(
        hasSpecificMission: Bool,
        hasPlanCheckpoint: Bool,
        hasProjectWork: Bool,
        hasVerification: Bool,
        hasProof: Bool,
        hasAnyProof: Bool,
        hasFailure: Bool,
        hasPendingApproval: Bool,
        nextStep: String,
        artifactCount: Int
    ) -> ProjectCommandIntent {
        if hasFailure { return .fixBlocker }
        if hasPendingApproval { return .reviewEvidence }
        if !hasSpecificMission || !hasPlanCheckpoint { return .planNext }
        if !hasProjectWork { return .continueMission }
        if !hasVerification || !hasProof { return .verifyWork }
        if hasProof { return .reviewEvidence }
        let next = nextStep.lowercased()
        if artifactCount > 0, next.contains("proof") || next.contains("artifact") || next.contains("preview") {
            return .improveArtifact
        }
        return .continueMission
    }

    private static func readinessScore(for gates: [MissionOSGate]) -> Int {
        let possible = max(gates.map(\.weight).reduce(0, +), 1)
        let earned = gates.reduce(0) { total, gate in
            switch gate.state {
            case .satisfied:
                return total + gate.weight
            case .waiting:
                return total + max(0, gate.weight / 3)
            case .blocked:
                return total
            }
        }
        return min(100, max(0, Int((Double(earned) / Double(possible) * 100).rounded())))
    }

    private static func hasCompletedVerification(
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord]
    ) -> Bool {
        toolRuns.contains { run in
            run.status == .completed && isVerificationToken(run.name)
        } || terminalCommands.contains { command in
            command.status == .completed && isVerificationCommand(command.command)
        }
    }

    private static func isVerificationToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("test") ||
            lower.contains("build") ||
            lower.contains("validate") ||
            lower.contains("check") ||
            lower.contains("proof") ||
            lower.contains("screenshot") ||
            lower.contains("smoke") ||
            lower.contains("tour") ||
            lower.contains("diff")
    }

    private static func isVerificationCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return isVerificationToken(lower) ||
            lower.contains("xcodebuild") ||
            lower.contains("swift test") ||
            lower.contains("npm test")
    }

    private static func checkpointDetail(
        hasPlanCheckpoint: Bool,
        hasProofCheckpoint: Bool,
        hasProjectWork: Bool
    ) -> String {
        if hasPlanCheckpoint, hasProofCheckpoint {
            return "Agent Plan and Agent Proof are both recorded in the project ledger."
        }
        if hasPlanCheckpoint {
            return "Agent Plan is recorded; Agent Proof still needs to close the run."
        }
        if hasProofCheckpoint {
            return "Agent Proof exists, but the starting Agent Plan is missing."
        }
        if hasProjectWork {
            return "Work exists without a complete plan/proof checkpoint pair."
        }
        return "No agent run checkpoints have been recorded yet."
    }

    private static func checkpointState(
        hasPlanCheckpoint: Bool,
        hasProofCheckpoint: Bool,
        hasProjectWork: Bool,
        hasFailure: Bool
    ) -> MissionOSGateState {
        if hasPlanCheckpoint, hasProofCheckpoint { return .satisfied }
        if hasFailure, hasProjectWork { return .blocked }
        return .waiting
    }

    private static func safetyDetail(hasFailure: Bool, failures: Int, pendingApprovals: Int, blocker: String) -> String {
        if hasFailure {
            if !blocker.isEmpty { return compact(blocker, limit: 118) }
            return "\(max(failures, 1)) issue\(failures == 1 ? "" : "s") need review before more autonomous work."
        }
        if pendingApprovals > 0 {
            return "\(pendingApprovals) approval\(pendingApprovals == 1 ? "" : "s") waiting."
        }
        return "No blocker or failed evidence is currently active."
    }

    private static func verificationDetail(hasVerification: Bool, hasAnyVerification: Bool, hasProjectWork: Bool) -> String {
        if hasVerification { return "A completed check, build, test, validation, or proof command is recorded." }
        if hasAnyVerification { return "Verification exists, but newer project activity needs a fresh check." }
        if hasProjectWork { return "Project work exists; run a check before calling it done." }
        return "Verification starts after the first concrete action."
    }

    private static func proofDetail(
        latestProof: ProjectProofItem?,
        hasCurrentProof: Bool,
        hasAnyProof: Bool
    ) -> String {
        if hasCurrentProof {
            return latestProof.map { "\($0.title) · \($0.detail)" } ?? "Proof is current."
        }
        if hasAnyProof {
            return latestProof.map { "\($0.title) needs refresh for newer project activity." } ?? "Proof exists, but it needs refresh."
        }
        return "No openable proof item is ready yet."
    }

    private static func headline(phase: MissionOSPhase, score: Int, hasFailure: Bool, hasPendingApproval: Bool, hasCheckpointPair: Bool) -> String {
        if hasFailure { return "Blocked until failed evidence is resolved" }
        if hasPendingApproval { return "Waiting for review or approval" }
        if score >= 85, hasCheckpointPair { return "Ready for decision with proof" }
        return "\(phase.displayName) phase · \(score)% ready"
    }

    private static func operatorDirective(
        phase: MissionOSPhase,
        recommendedIntent: ProjectCommandIntent,
        nextStep: String
    ) -> String {
        let next = nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !next.isEmpty {
            return compact("\(recommendedIntent.displayName): \(next)", limit: 180)
        }
        switch phase {
        case .contract:
            return "Clarify the project contract before executing broad changes."
        case .plan:
            return "Inspect the workspace and choose one concrete next action."
        case .act:
            return "Make the smallest useful project-owned change."
        case .verify:
            return "Run checks and capture proof before declaring progress."
        case .proof:
            return "Attach or preview the strongest artifact/result."
        case .decide:
            return "Review evidence and choose continue, fix, or complete."
        }
    }

    private static func proofRequirement(
        hasVerification: Bool,
        hasProof: Bool,
        hasAnyVerification: Bool,
        hasAnyProof: Bool,
        hasCheckpointPair: Bool,
        latestProof: ProjectProofItem?
    ) -> String {
        if hasAnyVerification, !hasVerification {
            return "Re-run verification for the latest project change before review."
        }
        if hasAnyProof, !hasProof {
            return "Refresh proof for the latest iteration before review."
        }
        if hasVerification, hasProof, !hasCheckpointPair {
            return "Close the run with Agent Plan and Agent Proof checkpoints before review."
        }
        if hasVerification, hasProof {
            return latestProof.map { "Use \($0.title) as the current receipt." } ?? "Use the latest proof ledger item."
        }
        if !hasVerification, hasProof {
            return "Proof exists, but it still needs a check/build/test/validation receipt."
        }
        return "Create an openable artifact, changed file, completed run, terminal proof, or fast screenshot proof before review."
    }

    private static func decisionLabel(
        score: Int,
        hasFailure: Bool,
        hasPendingApproval: Bool,
        hasVerification: Bool,
        hasProof: Bool,
        hasCheckpointPair: Bool
    ) -> String {
        if hasFailure { return "Fix blocker" }
        if hasPendingApproval { return "Review approval" }
        if score >= 85 && hasVerification && hasProof && hasCheckpointPair { return "Ready to review" }
        if !hasCheckpointPair { return "Needs checkpoint" }
        if !hasVerification { return "Needs verification" }
        if !hasProof { return "Needs proof" }
        return "Continue mission"
    }

    private static func successCriteria(missionText: String, hasSpecificMission: Bool) -> [String] {
        let missionLine = hasSpecificMission ? "Outcome stays scoped to \(compact(missionText, limit: 96))." : "Outcome is named before broad execution."
        return [
            missionLine,
            "Every run starts with a concrete plan and ends with Agent Proof.",
            "Mutating work is tied to project-owned files, runs, or terminal records.",
            "A check, build, test, validation, or explicit proof review happens before done.",
            "The next action is clear: continue, verify, fix, review, or complete."
        ]
    }

    private static func isGenericMission(_ mission: String) -> Bool {
        let lower = mission.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return true }
        return lower == "build and verify useful work in novaforge." ||
            lower == "plan, build, and verify one focused outcome." ||
            lower == "send the first project request."
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(max(0, limit - 1))) + "…"
    }
}

enum ProjectReviewBuilder {
    static func make(
        project: Project,
        statusKind: ProjectMissionStatusKind,
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent],
        failures: Int,
        pendingApprovals: Int,
        activeBlocker: String,
        proofItems: [ProjectProofItem],
        missionContract: MissionOSContract
    ) -> ProjectReviewSummary {
        let meaningfulProofItems = proofItems.filter { !$0.title.localizedCaseInsensitiveContains("Project created") }
        let hasProjectWork = !toolRuns.isEmpty || !terminalCommands.isEmpty || !artifacts.isEmpty || !fileChanges.isEmpty
        let checkpointGate = missionContract.gates.first { $0.id == "checkpoints" }
        let verificationGate = missionContract.gates.first { $0.id == "verification" }
        let proofGate = missionContract.gates.first { $0.id == "proof" }
        let contractGate = missionContract.gates.first { $0.id == "contract" }
        let freshness = ProjectEvidenceFreshness.make(
            proofItems: proofItems,
            toolRuns: toolRuns,
            terminalCommands: terminalCommands,
            fileChanges: fileChanges,
            events: events
        )
        let staleProof = freshness.hasAnyProof && !freshness.hasCurrentProof
        let workspaceMismatches = terminalCommands.filter { command in
            !command.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                command.workspaceName != project.workspaceName
        }
        let blocker = activeBlocker.trimmingCharacters(in: .whitespacesAndNewlines)

        var findings: [ProjectReviewFinding] = []
        if !workspaceMismatches.isEmpty {
            findings.append(ProjectReviewFinding(
                id: "wrong-project-risk",
                title: "Wrong-project risk",
                detail: "\(workspaceMismatches.count) terminal record\(workspaceMismatches.count == 1 ? "" : "s") came from a different workspace.",
                severity: .failure,
                symbolName: "folder.badge.questionmark"
            ))
        }
        if failures > 0 || statusKind == .blocked || !blocker.isEmpty {
            findings.append(ProjectReviewFinding(
                id: "failed-evidence",
                title: "Failed evidence",
                detail: blocker.isEmpty ? "\(max(failures, 1)) failed item\(failures == 1 ? "" : "s") need recovery." : blocker,
                severity: .failure,
                symbolName: "exclamationmark.triangle.fill"
            ))
        }
        if pendingApprovals > 0 || statusKind == .waiting {
            findings.append(ProjectReviewFinding(
                id: "approval-waiting",
                title: "Approval waiting",
                detail: "\(max(pendingApprovals, 1)) approval\(pendingApprovals == 1 ? "" : "s") must be resolved before autonomous continuation.",
                severity: .warning,
                symbolName: "checkmark.shield.fill"
            ))
        }
        if contractGate?.state == .waiting {
            findings.append(ProjectReviewFinding(
                id: "ambiguous-mission",
                title: "Mission needs shape",
                detail: "Name the outcome and success criteria before broad autonomous work.",
                severity: .warning,
                symbolName: "doc.text.magnifyingglass"
            ))
        }
        if hasProjectWork, checkpointGate?.state != .satisfied {
            findings.append(ProjectReviewFinding(
                id: "incomplete-handoff",
                title: "Incomplete handoff",
                detail: checkpointGate?.detail ?? "Record Agent Plan and Agent Proof checkpoints around project work.",
                severity: .warning,
                symbolName: "point.3.connected.trianglepath.dotted"
            ))
        }
        if hasProjectWork, verificationGate?.state == .waiting {
            findings.append(ProjectReviewFinding(
                id: "missing-verification",
                title: "Verification missing",
                detail: verificationGate?.detail ?? "Run a build, test, check, validation, or proof command.",
                severity: .warning,
                symbolName: "checkmark.shield.fill"
            ))
        }
        if hasProjectWork, proofGate?.state == .waiting {
            findings.append(ProjectReviewFinding(
                id: "missing-proof",
                title: "Proof missing",
                detail: proofGate?.detail ?? "Capture a durable artifact, changed file, terminal receipt, or screenshot.",
                severity: .warning,
                symbolName: "checkmark.seal.fill"
            ))
        }
        if hasProjectWork, meaningfulProofItems.isEmpty {
            findings.append(ProjectReviewFinding(
                id: "missing-evidence",
                title: "Evidence trail thin",
                detail: "Project work exists, but no credible proof item is ready to inspect.",
                severity: .warning,
                symbolName: "tray.and.arrow.down.fill"
            ))
        }
        if staleProof {
            findings.append(ProjectReviewFinding(
                id: "stale-proof",
                title: "Proof may be stale",
                detail: "Newer project activity happened after the latest successful proof item.",
                severity: .warning,
                symbolName: "clock.badge.exclamationmark"
            ))
        }
        if !hasProjectWork {
            findings.append(ProjectReviewFinding(
                id: "no-project-work",
                title: "No project work yet",
                detail: "Start with a concrete project action, then capture proof.",
                severity: .info,
                symbolName: "sparkles"
            ))
        }
        if findings.isEmpty {
            findings.append(ProjectReviewFinding(
                id: "healthy-evidence",
                title: "Evidence is aligned",
                detail: "Plan, work, verification, and proof are coherent for the next decision.",
                severity: .success,
                symbolName: "checkmark.seal.fill"
            ))
        }

        let recommendation = recommendation(
            project: project,
            missionContract: missionContract,
            findings: findings,
            failures: failures,
            pendingApprovals: pendingApprovals,
            activeBlocker: blocker,
            staleProof: staleProof
        )
        let healthScore = healthScore(from: findings)
        let headline = headline(for: recommendation, findings: findings, missionContract: missionContract)
        let detail = detail(for: recommendation, findings: findings, missionContract: missionContract)
        let proofFreshness: String = {
            if staleProof { return "Stale proof" }
            if meaningfulProofItems.isEmpty { return "No proof yet" }
            return "Proof current"
        }()
        let evidenceTrail = "\(toolRuns.count) run\(toolRuns.count == 1 ? "" : "s") · \(terminalCommands.count) command\(terminalCommands.count == 1 ? "" : "s") · \(artifacts.count) artifact\(artifacts.count == 1 ? "" : "s") · \(fileChanges.count) change\(fileChanges.count == 1 ? "" : "s")"

        return ProjectReviewSummary(
            headline: headline,
            detail: detail,
            recommendation: recommendation,
            healthScore: healthScore,
            proofFreshness: proofFreshness,
            evidenceTrail: evidenceTrail,
            findings: findings
        )
    }

    private static func recommendation(
        project: Project,
        missionContract: MissionOSContract,
        findings: [ProjectReviewFinding],
        failures: Int,
        pendingApprovals: Int,
        activeBlocker: String,
        staleProof: Bool
    ) -> ProjectReviewRecommendation {
        if findings.contains(where: { $0.id == "wrong-project-risk" }) { return .askUser }
        if failures > 0 || !activeBlocker.isEmpty { return .fixBlocker }
        if pendingApprovals > 0 || findings.contains(where: { $0.id == "approval-waiting" }) { return .askUser }
        if project.status == .completed || missionContract.decisionLabel == "Ready to review" { return .finalReview }
        if missionContract.phase == .contract || findings.contains(where: { $0.id == "ambiguous-mission" }) { return .askUser }
        if staleProof ||
            findings.contains(where: { $0.id == "missing-verification" || $0.id == "missing-proof" || $0.id == "missing-evidence" }) {
            return .verifyWork
        }
        return .continueMission
    }

    private static func healthScore(from findings: [ProjectReviewFinding]) -> Int {
        let penalty = findings.reduce(0) { total, finding in
            switch finding.id {
            case "wrong-project-risk":
                return total + 32
            case "failed-evidence":
                return total + 36
            case "approval-waiting":
                return total + 20
            case "ambiguous-mission":
                return total + 22
            case "incomplete-handoff":
                return total + 12
            case "missing-verification":
                return total + 16
            case "missing-proof", "missing-evidence", "stale-proof":
                return total + 14
            case "no-project-work":
                return total + 10
            default:
                return total
            }
        }
        return min(100, max(0, 100 - penalty))
    }

    private static func headline(
        for recommendation: ProjectReviewRecommendation,
        findings: [ProjectReviewFinding],
        missionContract: MissionOSContract
    ) -> String {
        if let primary = findings.first(where: { $0.id == "wrong-project-risk" }) { return primary.title }
        switch recommendation {
        case .fixBlocker:
            return "Blocked until failed evidence is resolved"
        case .askUser:
            return findings.first(where: { $0.id == "approval-waiting" }) != nil ? "User review required" : "Clarify before autonomy"
        case .verifyWork:
            return "Verification should happen next"
        case .finalReview:
            return "Proof is ready for final review"
        case .continueMission:
            return missionContract.headline
        }
    }

    private static func detail(
        for recommendation: ProjectReviewRecommendation,
        findings: [ProjectReviewFinding],
        missionContract: MissionOSContract
    ) -> String {
        if recommendation == .finalReview {
            return "Review the proof ledger and decide whether to complete or continue."
        }
        if let primary = findings.first(where: { $0.severity == .failure }) ??
            findings.first(where: { $0.severity == .warning }) {
            return primary.detail
        }
        switch recommendation {
        case .finalReview:
            return "Review the proof ledger and decide whether to complete or continue."
        case .continueMission:
            return missionContract.operatorDirective
        case .verifyWork:
            return missionContract.proofRequirement
        case .askUser:
            return "A human decision is needed before NovaForge continues automatically."
        case .fixBlocker:
            return "Start from failed evidence, recover, then verify."
        }
    }
}

enum ProjectMissionSummarizer {
    private struct FailureEvidence {
        var id: String
        var title: String
        var createdAt: Date
    }

    static func summarize(project: Project, context: ModelContext) -> ProjectMissionSummary {
        summarize(
            project: project,
            conversations: (try? context.fetch(FetchDescriptor<Conversation>())) ?? [],
            toolRuns: (try? context.fetch(FetchDescriptor<ToolRun>())) ?? [],
            terminalCommands: (try? context.fetch(FetchDescriptor<TerminalCommandRecord>())) ?? [],
            artifacts: (try? context.fetch(FetchDescriptor<ProjectArtifact>())) ?? [],
            fileChanges: (try? context.fetch(FetchDescriptor<ProjectFileChange>())) ?? [],
            events: (try? context.fetch(FetchDescriptor<ProjectEvent>())) ?? []
        )
    }

    static func summarize(
        project: Project,
        conversations: [Conversation],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent]
    ) -> ProjectMissionSummary {
        let projectID = project.id
        let projectConversations = conversations.filter { $0.project?.id == projectID }
        let projectRuns = toolRuns.filter { $0.project?.id == projectID }
        let projectCommands = terminalCommands.filter { $0.project?.id == projectID }
        let projectArtifacts = artifacts.filter { $0.project?.id == projectID }
        let projectFileChanges = fileChanges.filter { $0.project?.id == projectID }
        let projectEvents = events.filter { $0.project?.id == projectID }
        let failedRuns = projectRuns.filter { $0.status == .failed || $0.status == .rejected }
        let failedCommands = projectCommands.filter { $0.status == .failed }
        let failedRunIDs = Set(
            failedRuns.map { $0.id.uuidString }
        )
        let failedCommandIDs = Set(
            failedCommands.map { $0.id.uuidString }
        )
        let independentFailureEvents = projectEvents.filter { event in
            guard event.severity == .failure else { return false }
            guard let sourceID = event.sourceIDString else { return true }
            switch event.sourceType {
            case .toolRun:
                return !failedRunIDs.contains(sourceID)
            case .terminalCommand:
                return !failedCommandIDs.contains(sourceID)
            default:
                return true
            }
        }
        let allFailures = makeFailureEvidence(
            failedRuns: failedRuns,
            failedCommands: failedCommands,
            independentFailureEvents: independentFailureEvents
        )
        let latestRecoveryAt = latestRecoveryDate(
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            events: projectEvents
        )
        let activeFailures = activeFailureEvidence(allFailures, latestRecoveryAt: latestRecoveryAt)
        let failures = activeFailures.count
        let pending = projectRuns.filter { $0.status == .pendingApproval }.count
        let hasApprovedRunningTool = projectRuns.contains { $0.status == .approved }
        let sortedEvents = projectEvents.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let timelineItems = makeTimelineItems(from: sortedEvents)
        let proofItems = makeProofItems(
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            events: sortedEvents
        )
        let lastEvent = timelineItems.first
        let activeBlocker = activeBlocker(
            project: project,
            activeFailures: activeFailures,
            latestRecoveryAt: latestRecoveryAt
        )
        let hasActiveWaitingEvent = hasActiveWaitingEvent(
            sortedEvents.first,
            latestRecoveryAt: latestRecoveryAt
        )
        let statusKind = missionStatusKind(
            project: project,
            failures: failures,
            pending: pending,
            activeBlocker: activeBlocker,
            hasActiveWaitingEvent: hasActiveWaitingEvent
        )
        let nextStep = recommendedNextStep(
            project: project,
            timelineItems: timelineItems,
            proofItems: proofItems,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            events: projectEvents,
            failures: failures,
            pending: pending,
            activeBlocker: activeBlocker,
            statusKind: statusKind
        )
        let effectiveStatus: ProjectState = {
            switch statusKind {
            case .active: return (project.status == .running || hasApprovedRunningTool) ? .running : .active
            case .waiting: return .needsReview
            case .blocked: return .blocked
            case .done: return .completed
            }
        }()
        let mission = project.mission.trimmingCharacters(in: .whitespacesAndNewlines)
        let missionText = mission.isEmpty ? "Build and verify useful work in NovaForge." : mission
        let missionContract = MissionOSContractBuilder.make(
            project: project,
            missionText: missionText,
            statusKind: statusKind,
            conversations: projectConversations,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            events: projectEvents,
            failures: failures,
            pendingApprovals: pending,
            nextStep: nextStep,
            proofItems: proofItems,
            activeBlocker: activeBlocker
        )
        let review = ProjectReviewBuilder.make(
            project: project,
            statusKind: statusKind,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            events: projectEvents,
            failures: failures,
            pendingApprovals: pending,
            activeBlocker: activeBlocker,
            proofItems: proofItems,
            missionContract: missionContract
        )
        let workflowSpine = makeWorkflowSpine(
            project: project,
            statusKind: statusKind,
            nextStep: nextStep,
            activeBlocker: activeBlocker,
            proofItems: proofItems,
            toolRuns: projectRuns,
            terminalCommands: projectCommands,
            artifacts: projectArtifacts,
            fileChanges: projectFileChanges,
            review: review
        )

        return ProjectMissionSummary(
            status: effectiveStatus,
            statusKind: statusKind,
            statusText: effectiveStatus.displayName,
            missionText: missionText,
            conversationCount: projectConversations.count,
            toolRunCount: projectRuns.count,
            terminalCommandCount: projectCommands.count,
            artifactCount: projectArtifacts.count,
            fileChangeCount: projectFileChanges.count,
            eventCount: projectEvents.count,
            failureCount: failures,
            pendingApprovalCount: pending,
            lastEventTitle: lastEvent?.title ?? "Project created",
            lastEventDetail: lastEvent?.detail ?? "Mission history is ready.",
            nextStep: nextStep,
            latestProofTitle: proofItems.first?.title ?? "No proof captured yet",
            blocker: activeBlocker,
            timelineItems: timelineItems,
            proofItems: proofItems,
            missionContract: missionContract,
            review: review,
            workflowSpine: workflowSpine
        )
    }

    private static func makeWorkflowSpine(
        project: Project,
        statusKind: ProjectMissionStatusKind,
        nextStep: String,
        activeBlocker: String,
        proofItems: [ProjectProofItem],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        review: ProjectReviewSummary
    ) -> ProjectWorkflowSpine {
        let latestArtifact = artifacts.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.path < rhs.path
        }.first
        let latestChange = fileChanges.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.path < rhs.path
        }.first
        let latestRun = toolRuns.sorted {
            let lhs = $0.completedAt ?? $0.createdAt
            let rhs = $1.completedAt ?? $1.createdAt
            if lhs != rhs { return lhs > rhs }
            return $0.id.uuidString < $1.id.uuidString
        }.first
        let latestTerminal = terminalCommands.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt > $1.completedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.first
        let meaningfulProof = proofItems.first {
            !$0.title.localizedCaseInsensitiveContains("Project created")
        }
        let latestArtifactPath = latestArtifact?.path
        let latestChangedPath: String?
        let changedTitle: String
        let changedDetail: String

        let artifactIsNewest = latestArtifact.map { artifact in
            latestChange.map { artifact.updatedAt >= $0.createdAt } ?? true
        } ?? false
        if artifactIsNewest, let latestArtifact {
            latestChangedPath = latestArtifact.path
            changedTitle = "Artifact ready"
            changedDetail = readablePath(latestArtifact.path)
        } else if let latestChange {
            latestChangedPath = latestChange.path
            changedTitle = latestChange.action.isEmpty ? "File changed" : latestChange.action
            changedDetail = readablePath(latestChange.path)
        } else if let latestRun {
            latestChangedPath = nil
            changedTitle = latestRun.status == .completed ? "Run finished" : toolRunStatusTitle(latestRun.status)
            changedDetail = toolRunDisplayName(latestRun.name)
        } else if let latestTerminal {
            latestChangedPath = nil
            changedTitle = latestTerminal.status == .completed ? "Command finished" : "Command failed"
            changedDetail = cleanDetail(latestTerminal.command)
        } else {
            latestChangedPath = nil
            changedTitle = "No project changes yet"
            changedDetail = "Ask for a concrete project artifact, file change, or verification run."
        }

        let proofTitle: String
        let proofDetail: String
        if review.hasStaleProof, let meaningfulProof {
            proofTitle = "Proof needs refresh"
            proofDetail = "\(meaningfulProof.title) is older than newer project activity."
        } else if let meaningfulProof {
            proofTitle = meaningfulProof.title
            proofDetail = meaningfulProof.detail
        } else {
            proofTitle = "No proof captured yet"
            proofDetail = "Run a check, open an artifact, or save Agent Proof for the latest work."
        }

        let blocker = activeBlocker.trimmingCharacters(in: .whitespacesAndNewlines)
        let blockerTitle: String
        let blockerDetail: String
        if !blocker.isEmpty {
            blockerTitle = "Blocker"
            blockerDetail = blocker
        } else if statusKind == .waiting {
            blockerTitle = "Waiting"
            blockerDetail = "Resolve the pending approval or review gate before continuing."
        } else {
            blockerTitle = "Clear"
            blockerDetail = "No active blocker is recorded."
        }

        let nextActionTitle: String
        switch review.recommendation {
        case .fixBlocker:
            nextActionTitle = "Recover"
        case .verifyWork:
            nextActionTitle = "Verify"
        case .askUser:
            nextActionTitle = "Review"
        case .finalReview:
            nextActionTitle = "Decide"
        case .continueMission:
            nextActionTitle = "Continue"
        }
        let nextActionDetail = nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? review.detail
            : nextStep
        let currentTitle: String
        let currentDetail: String
        switch statusKind {
        case .blocked:
            currentTitle = "Recovery needed"
            currentDetail = blockerDetail
        case .waiting:
            currentTitle = "Human decision needed"
            currentDetail = blockerDetail
        case .done:
            currentTitle = "Ready for review"
            currentDetail = proofDetail
        case .active:
            currentTitle = nextActionTitle
            currentDetail = nextActionDetail
        }

        let iterationTarget = latestArtifactPath ?? latestChangedPath
        let iterationPrompt: String
        if let iterationTarget {
            iterationPrompt = "Ask for the next change against \(readablePath(iterationTarget)), then verify and update proof."
        } else {
            iterationPrompt = "Ask for one concrete output, then inspect, verify, and capture proof."
        }

        return ProjectWorkflowSpine(
            currentTitle: currentTitle,
            currentDetail: cleanDetail(currentDetail),
            changedTitle: changedTitle,
            changedDetail: cleanDetail(changedDetail),
            proofTitle: proofTitle,
            proofDetail: cleanDetail(proofDetail),
            blockerTitle: blockerTitle,
            blockerDetail: cleanDetail(blockerDetail),
            nextActionTitle: nextActionTitle,
            nextActionDetail: cleanDetail(nextActionDetail),
            iterationPrompt: cleanDetail(iterationPrompt),
            latestArtifactPath: latestArtifactPath,
            latestChangedPath: latestChangedPath,
            latestTerminalCommand: latestTerminal.map { cleanDetail($0.command) }
        )
    }

    private static func makeFailureEvidence(
        failedRuns: [ToolRun],
        failedCommands: [TerminalCommandRecord],
        independentFailureEvents: [ProjectEvent]
    ) -> [FailureEvidence] {
        let runFailures = failedRuns.map { run in
            FailureEvidence(
                id: "run-\(run.id.uuidString)",
                title: run.status == .rejected ? "Run rejected" : "Run failed",
                createdAt: run.completedAt ?? run.createdAt
            )
        }
        let commandFailures = failedCommands.map { command in
            FailureEvidence(
                id: "terminal-\(command.id.uuidString)",
                title: "Command failed",
                createdAt: command.completedAt
            )
        }
        let eventFailures = independentFailureEvents.map { event in
            FailureEvidence(
                id: "event-\(event.id.uuidString)",
                title: event.title.isEmpty ? "Run failed" : event.title,
                createdAt: event.createdAt
            )
        }
        return (runFailures + commandFailures + eventFailures).sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }
    }

    private static func latestRecoveryDate(
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent]
    ) -> Date? {
        var dates: [Date] = []
        dates += toolRuns
            .filter { $0.status == .completed && ($0.isMutating || isVerificationToken($0.name)) }
            .compactMap { $0.completedAt ?? $0.createdAt }
        dates += terminalCommands
            .filter { $0.status == .completed && isVerificationCommand($0.command) }
            .map(\.completedAt)
        dates += artifacts.map(\.updatedAt)
        dates += fileChanges.map(\.createdAt)
        dates += events.compactMap { event in
            guard event.severity == .success, eventRepresentsRecovery(event) else { return nil }
            return event.createdAt
        }
        return dates.max()
    }

    private static func eventRepresentsRecovery(_ event: ProjectEvent) -> Bool {
        switch event.kind {
        case .runCompleted, .agentProofCreated, .artifactCreated, .fileChanged, .missionCheckpoint:
            return true
        default:
            return false
        }
    }

    private static func activeFailureEvidence(
        _ failures: [FailureEvidence],
        latestRecoveryAt: Date?
    ) -> [FailureEvidence] {
        guard let latestRecoveryAt else { return failures }
        return failures.filter { $0.createdAt > latestRecoveryAt }
    }

    private static func activeBlocker(
        project: Project,
        activeFailures: [FailureEvidence],
        latestRecoveryAt: Date?
    ) -> String {
        let persisted = project.blocker.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newestFailure = activeFailures.first {
            return persisted.isEmpty ? newestFailure.title : persisted
        }
        guard project.status == .blocked, latestRecoveryAt == nil else {
            return ""
        }
        return persisted
    }

    private static func hasActiveWaitingEvent(
        _ latestEvent: ProjectEvent?,
        latestRecoveryAt: Date?
    ) -> Bool {
        guard let latestEvent,
              latestEvent.severity == .warning || latestEvent.kind == .runPaused else {
            return false
        }
        guard let latestRecoveryAt else { return true }
        return latestEvent.createdAt > latestRecoveryAt
    }

    private static func makeTimelineItems(from events: [ProjectEvent]) -> [ProjectTimelineItem] {
        events.map { event in
            ProjectTimelineItem(
                id: event.id.uuidString,
                title: timelineTitle(for: event),
                detail: cleanDetail(event.detail),
                kindTitle: eventKindTitle(event.kind),
                createdAt: event.createdAt,
                severity: event.severity,
                sourceKind: event.kind
            )
        }
    }

    private static func makeProofItems(
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        events: [ProjectEvent]
    ) -> [ProjectProofItem] {
        var items: [ProjectProofItem] = []
        for artifact in artifacts.sorted(by: { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.path < rhs.path
        }).prefix(4) {
            items.append(ProjectProofItem(
                id: "artifact-\(artifact.id.uuidString)",
                title: artifact.title.isEmpty ? URL(fileURLWithPath: artifact.path).lastPathComponent : artifact.title,
                detail: "Artifact · \(cleanDetail(artifact.path))",
                createdAt: artifact.updatedAt,
                symbolName: artifact.kind == .web ? "play.rectangle.fill" : "shippingbox.fill",
                sourcePath: artifact.path,
                severity: .success
            ))
        }
        for change in fileChanges.sorted(by: { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.path < rhs.path
        }).prefix(3) {
            let filename = URL(fileURLWithPath: change.path).lastPathComponent
            items.append(ProjectProofItem(
                id: "file-\(change.id.uuidString)",
                title: "File changed: \(filename.isEmpty ? change.path : filename)",
                detail: cleanDetail(change.path),
                createdAt: change.createdAt,
                symbolName: "doc.text.fill",
                sourcePath: change.path,
                severity: .success
            ))
        }
        for run in toolRuns.filter({ $0.status == .completed }).sorted(by: {
            let lhs = $0.completedAt ?? $0.createdAt
            let rhs = $1.completedAt ?? $1.createdAt
            if lhs != rhs { return lhs > rhs }
            return $0.id.uuidString < $1.id.uuidString
        }).prefix(3) {
            items.append(ProjectProofItem(
                id: "run-\(run.id.uuidString)",
                title: "Run completed",
                detail: run.name,
                createdAt: run.completedAt ?? run.createdAt,
                symbolName: "checkmark.circle.fill",
                sourcePath: nil,
                severity: .success
            ))
        }
        for run in toolRuns.filter({ $0.status == .failed || $0.status == .rejected }).sorted(by: {
            let lhs = $0.completedAt ?? $0.createdAt
            let rhs = $1.completedAt ?? $1.createdAt
            if lhs != rhs { return lhs > rhs }
            return $0.id.uuidString < $1.id.uuidString
        }).prefix(2) {
            items.append(ProjectProofItem(
                id: "run-failure-\(run.id.uuidString)",
                title: run.status == .rejected ? "Run rejected" : "Run failed",
                detail: run.name,
                createdAt: run.completedAt ?? run.createdAt,
                symbolName: "exclamationmark.triangle.fill",
                sourcePath: nil,
                severity: .failure
            ))
        }
        for command in terminalCommands.filter({ $0.status == .completed }).sorted(by: { $0.completedAt > $1.completedAt }).prefix(2) {
            items.append(ProjectProofItem(
                id: "terminal-\(command.id.uuidString)",
                title: "Command completed",
                detail: cleanDetail(command.command),
                createdAt: command.completedAt,
                symbolName: "terminal.fill",
                sourcePath: nil,
                severity: .success
            ))
        }
        for command in terminalCommands.filter({ $0.status == .failed }).sorted(by: { $0.completedAt > $1.completedAt }).prefix(2) {
            items.append(ProjectProofItem(
                id: "terminal-failure-\(command.id.uuidString)",
                title: "Command failed",
                detail: cleanDetail(command.command),
                createdAt: command.completedAt,
                symbolName: "exclamationmark.triangle.fill",
                sourcePath: nil,
                severity: .failure
            ))
        }
        let proofWorthyEventKinds: Set<ProjectEventKind> = [
            .toolCompleted, .runCompleted, .artifactCreated, .artifactPreviewed,
            .fileChanged, .terminalCommand, .agentProofCreated, .missionCheckpoint
        ]
        for event in events.filter({ $0.severity == .success && proofWorthyEventKinds.contains($0.kind) }).prefix(3) {
            items.append(ProjectProofItem(
                id: "event-\(event.id.uuidString)",
                title: timelineTitle(for: event),
                detail: cleanDetail(event.detail),
                createdAt: event.createdAt,
                symbolName: "checkmark.seal.fill",
                sourcePath: nil,
                severity: event.severity
            ))
        }
        return Array(items.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }.prefix(8))
    }

    private static func recommendedNextStep(
        project: Project,
        timelineItems: [ProjectTimelineItem],
        proofItems: [ProjectProofItem],
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord],
        artifacts: [ProjectArtifact],
        fileChanges: [ProjectFileChange],
        events: [ProjectEvent],
        failures: Int,
        pending: Int,
        activeBlocker: String,
        statusKind: ProjectMissionStatusKind
    ) -> String {
        if project.status == .completed { return "Review final proof." }
        if failures > 0 || statusKind == .blocked || !activeBlocker.isEmpty {
            return "Review the failed evidence and retry the run."
        }
        if pending > 0 || statusKind == .waiting {
            return "Review the pending approval."
        }

        let hasProjectWork = !toolRuns.isEmpty || !terminalCommands.isEmpty || !artifacts.isEmpty || !fileChanges.isEmpty
        let freshness = ProjectEvidenceFreshness.make(
            proofItems: proofItems,
            toolRuns: toolRuns,
            terminalCommands: terminalCommands,
            fileChanges: fileChanges,
            events: events
        )
        let hasVerification = freshness.hasCurrentVerification
        let hasPlanCheckpoint = events.contains { $0.kind == .agentPlanCreated }
        let hasProofCheckpoint = events.contains { $0.kind == .agentProofCreated }
        let meaningfulProofItems = proofItems.filter { !$0.title.localizedCaseInsensitiveContains("Project created") }

        if !hasPlanCheckpoint {
            if hasProjectWork {
                return "Record an Agent Plan checkpoint, then continue from the latest evidence."
            }
            let meaningfulTimeline = meaningfulTimelineItems(timelineItems)
            if meaningfulTimeline.isEmpty { return "Send the first project request." }
            return "Plan the next concrete agent step from project evidence."
        }
        if !hasProjectWork {
            let persistedNextStep = project.nextStep.trimmingCharacters(in: .whitespacesAndNewlines)
            if !persistedNextStep.isEmpty,
               persistedNextStep.localizedCaseInsensitiveCompare("Send the first project request.") != .orderedSame {
                return persistedNextStep
            }
            return "Run the first concrete project action."
        }
        if !hasVerification {
            if freshness.hasAnyVerification {
                return "Re-run verification for the latest project change."
            }
            return "Run the fastest verification or screenshot proof check."
        }
        if meaningfulProofItems.isEmpty || !freshness.hasCurrentProof {
            if freshness.hasAnyProof {
                return "Refresh proof for the latest iteration."
            }
            return "Capture durable proof for the latest verified work."
        }
        if !hasProofCheckpoint {
            return "Save Agent Proof for the verified result."
        }
        if !meaningfulProofItems.isEmpty {
            return "Review the latest proof."
        }
        return project.nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Send the next project request." : project.nextStep
    }

    private static func missionStatusKind(
        project: Project,
        failures: Int,
        pending: Int,
        activeBlocker: String,
        hasActiveWaitingEvent: Bool
    ) -> ProjectMissionStatusKind {
        if project.status == .completed { return .done }
        if failures > 0 || !activeBlocker.isEmpty {
            return .blocked
        }
        if pending > 0 || hasActiveWaitingEvent {
            return .waiting
        }
        return .active
    }

    private static func meaningfulTimelineItems(_ timelineItems: [ProjectTimelineItem]) -> [ProjectTimelineItem] {
        timelineItems.filter { item in
            guard let sourceKind = item.sourceKind else { return true }
            return sourceKind != .projectCreated &&
                sourceKind != .projectSelected &&
                sourceKind != .conversationStarted &&
                sourceKind != .migrationLinked
        }
    }

    private static func hasCompletedVerification(
        toolRuns: [ToolRun],
        terminalCommands: [TerminalCommandRecord]
    ) -> Bool {
        toolRuns.contains { run in
            run.status == .completed && isVerificationToken(run.name)
        } || terminalCommands.contains { command in
            command.status == .completed && isVerificationCommand(command.command)
        }
    }

    private static func isVerificationToken(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("test") ||
            lower.contains("build") ||
            lower.contains("validate") ||
            lower.contains("check") ||
            lower.contains("proof") ||
            lower.contains("screenshot") ||
            lower.contains("smoke") ||
            lower.contains("tour") ||
            lower.contains("diff")
    }

    private static func isVerificationCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        return isVerificationToken(lower) ||
            lower.contains("xcodebuild") ||
            lower.contains("swift test") ||
            lower.contains("npm test")
    }

    private static func timelineTitle(for event: ProjectEvent) -> String {
        switch event.kind {
        case .projectCreated: return "Project created"
        case .projectSelected: return event.title.isEmpty ? "Project selected" : event.title
        case .projectRenamed: return event.title.isEmpty ? "Project renamed" : event.title
        case .conversationContinued: return event.title.isEmpty ? "Project continued" : event.title
        case .conversationStarted: return "Project chat ready"
        case .artifactCreated: return proofTitle(prefix: "Generated proof", detail: event.detail, fallback: event.title)
        case .artifactPreviewed: return "Opened artifact preview"
        case .fileChanged: return proofTitle(prefix: "File changed", detail: event.detail, fallback: event.title)
        case .agentPlanCreated: return event.title.isEmpty ? "Agent plan prepared" : event.title
        case .agentProofCreated: return event.title.isEmpty ? "Agent proof captured" : event.title
        case .missionCheckpoint: return event.title.isEmpty ? "Mission OS checkpoint" : event.title
        case .runCompleted: return "Run completed"
        case .runFailed, .toolFailed: return event.title.isEmpty ? "Run failed" : event.title
        case .toolApprovalRequested: return "Waiting on user"
        case .toolCompleted: return event.title.isEmpty ? "Tool completed" : event.title
        case .workspaceChanged: return "Workspace changed"
        case .settingsChanged: return "Settings changed"
        case .autoContinueEnabled: return "Auto-continue enabled"
        case .autoContinueDisabled: return "Auto-continue disabled"
        case .autoContinueScheduled: return event.title.isEmpty ? "Auto-continue scheduled" : event.title
        case .autoContinueStarted: return event.title.isEmpty ? "Auto-continued run started" : event.title
        case .autoContinuePaused: return event.title.isEmpty ? "Auto-continue paused" : event.title
        default: return event.title.isEmpty ? eventKindTitle(event.kind) : event.title
        }
    }

    private static func proofTitle(prefix: String, detail: String, fallback: String) -> String {
        let name = URL(fileURLWithPath: detail).lastPathComponent
        if !name.isEmpty { return "\(prefix): \(name)" }
        return fallback.isEmpty ? prefix : fallback
    }

    private static func eventKindTitle(_ kind: ProjectEventKind) -> String {
        kind.rawValue
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    private static func cleanDetail(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return "Project evidence recorded." }
        return oneLine.count > 160 ? String(oneLine.prefix(159)) + "…" : oneLine
    }

    private static func readablePath(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func toolRunDisplayName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                word.count <= 2 ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func toolRunStatusTitle(_ status: ToolRunStatus) -> String {
        switch status {
        case .pendingApproval:
            return "Approval pending"
        case .approved:
            return "Approved"
        case .rejected:
            return "Rejected"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }
}
