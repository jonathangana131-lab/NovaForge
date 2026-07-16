import AgentDomain
import AgentEngine
import Foundation
import Observation
import SwiftData

struct AgentSystemPresentationScope: Hashable, Sendable {
    let projectID: ProjectID?
    let conversationID: ConversationID

    init(projectID: ProjectID?, conversationID: ConversationID) {
        self.projectID = projectID
        self.conversationID = conversationID
    }

    init(project: Project?, conversation: Conversation) {
        projectID = project.map { ProjectID(rawValue: $0.id) }
        conversationID = ConversationID(rawValue: conversation.id)
    }

    var projectionScope: AgentActivityProjectionScope {
        AgentActivityProjectionScope(
            projectID: projectID,
            conversationID: conversationID
        )
    }
}

enum AgentSystemPresentationFailure: String, Equatable, Sendable {
    case startupUnavailable
    case requestInvalid
    case providerUnsupported
    case workspaceBusy
    case projectionUnavailable
    case conflictingActiveRuns
    case commandUnavailable
    case runtimeUnavailable

    var userMessage: String {
        switch self {
        case .startupUnavailable:
            "NovaForge is still restoring the agent runtime."
        case .requestInvalid:
            "This request could not be accepted safely."
        case .providerUnsupported:
            "This provider or model is not available for agent runs. Choose OpenCode Zen, OpenAI, ChatGPT, or Local in Control."
        case .workspaceBusy:
            "Another run already owns this workspace. Stop or finish it before sending again."
        case .projectionUnavailable:
            "NovaForge saved the run, but its activity view needs recovery. Open History for the durable receipt."
        case .conflictingActiveRuns:
            "NovaForge found conflicting active runs in this chat and stopped new commands safely."
        case .commandUnavailable:
            "That activity control is stale. Refresh the run from History."
        case .runtimeUnavailable:
            "NovaForge could not continue the agent run. Its durable receipt remains in History."
        }
    }
}

enum AgentSystemPresentationStorePhase: String, Equatable, Sendable {
    case idle
    case binding
    case ready
    case failed
}

struct AgentSystemLiveTextSnapshot: Equatable, Sendable {
    let runID: RunID
    let attemptID: AttemptID
    let revision: UInt64
    let text: String
}

/// Process-owned, bounded collector for the classified text-only engine sink.
/// It cannot receive reasoning, tool payloads, provider frames, or authority.
actor AgentSystemLiveOutputCenter: AgentLiveOutputSink {
    static let shared = AgentSystemLiveOutputCenter()

    private struct Buffer: Sendable {
        let attemptID: AttemptID
        var lastEventSequence: UInt64
        var textByOutputIndex: [Int: String]
        var outputOrder: [Int]
        var utf8ByteCount: Int
        var revision: UInt64

        var text: String {
            outputOrder.compactMap { textByOutputIndex[$0] }.joined()
        }
    }

    static let maximumRetainedRuns = 128
    static let maximumTextUTF8BytesPerRun = 1_048_576
    private var buffers: [RunID: Buffer] = [:]
    private var retentionOrder: [RunID] = []

    func receive(_ delta: AgentLiveTextDelta) {
        guard delta.outputIndex >= 0,
              !delta.text.isEmpty,
              delta.text.utf8.count <= Self.maximumTextUTF8BytesPerRun
        else { return }

        var buffer: Buffer
        if let existing = buffers[delta.runID],
           existing.attemptID == delta.attemptID {
            guard delta.eventSequence > existing.lastEventSequence else {
                return
            }
            buffer = existing
        } else {
            buffer = Buffer(
                attemptID: delta.attemptID,
                lastEventSequence: delta.eventSequence,
                textByOutputIndex: [:],
                outputOrder: [],
                utf8ByteCount: 0,
                revision: 0
            )
            retentionOrder.removeAll { $0 == delta.runID }
            retentionOrder.append(delta.runID)
        }

        let deltaByteCount = delta.text.utf8.count
        guard buffer.utf8ByteCount + deltaByteCount <=
                Self.maximumTextUTF8BytesPerRun
        else { return }
        if buffer.textByOutputIndex[delta.outputIndex] == nil {
            buffer.outputOrder.append(delta.outputIndex)
        }
        buffer.textByOutputIndex[delta.outputIndex, default: ""] += delta.text
        buffer.utf8ByteCount += deltaByteCount
        buffer.lastEventSequence = delta.eventSequence
        if buffer.revision < UInt64.max { buffer.revision += 1 }
        buffers[delta.runID] = buffer
        trimIfNeeded()
    }

    func snapshot(for runID: RunID) -> AgentSystemLiveTextSnapshot? {
        guard let buffer = buffers[runID] else { return nil }
        return AgentSystemLiveTextSnapshot(
            runID: runID,
            attemptID: buffer.attemptID,
            revision: buffer.revision,
            text: buffer.text
        )
    }

    func clear(runID: RunID) {
        buffers.removeValue(forKey: runID)
        retentionOrder.removeAll { $0 == runID }
    }

    private func trimIfNeeded() {
        while buffers.count > Self.maximumRetainedRuns,
              let oldest = retentionOrder.first {
            retentionOrder.removeFirst()
            buffers.removeValue(forKey: oldest)
        }
    }
}

actor AgentSystemMaterializationCoordinator {
    private let legacyProjector: LegacyRunProjector
    private let projectOSProjector: ProjectOSProjector

    init(store: SwiftDataAgentStore) {
        legacyProjector = LegacyRunProjector(store: store)
        projectOSProjector = ProjectOSProjector(store: store)
    }

    func projectAvailableEvents() async throws {
        _ = try await legacyProjector.projectAvailableEvents()
        _ = try await projectOSProjector.projectAvailableEvents()
    }
}

struct AgentSystemScopePresentation: Equatable, Sendable {
    let scope: AgentSystemPresentationScope
    let activeGroup: AgentActivityGroup?
    let liveText: AgentSystemLiveTextSnapshot?
    let isAccepting: Bool
    let isSynchronizing: Bool
    let failure: AgentSystemPresentationFailure?

    var isWorking: Bool {
        guard let state = activeGroup?.state else {
            return isAccepting || isSynchronizing
        }
        return switch state {
        case .pending, .queued, .running, .retrying, .cancelling:
            true
        case .awaitingApproval, .succeeded, .failed, .rejected, .cancelled,
             .interrupted:
            false
        }
    }

    var blocksCommand: Bool {
        isAccepting || isSynchronizing ||
            (activeGroup.map { !$0.state.isTerminal } ?? false)
    }

    var pendingApproval: AgentActivityApproval? {
        activeGroup?.pendingApproval
    }

    static func idle(_ scope: AgentSystemPresentationScope) -> Self {
        Self(
            scope: scope,
            activeGroup: nil,
            liveText: nil,
            isAccepting: false,
            isSynchronizing: false,
            failure: nil
        )
    }
}

enum AgentSystemPresentationStartDisposition: Equatable, Sendable {
    case accepted(RunID)
    case busy
    case rejected(AgentSystemPresentationFailure)

    var wasAccepted: Bool {
        if case .accepted = self { true } else { false }
    }
}

/// Typed initiation semantics for every new run accepted by the shared
/// AgentSystem owner. UI text is never inspected to infer lineage or origin.
enum AgentSystemPresentationStartIntent: Equatable, Sendable {
    case manual
    case autoContinued
    case continuation(parentRunID: RunID)
    case retry(previousRunID: RunID)
}

enum AgentOrchestrationPhase: String, Equatable, Sendable {
    case preparing
    case delegating
    case integrating
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .preparing, .delegating, .integrating: false
        }
    }
}

struct AgentOrchestrationWorkerPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    var status: String
    var isComplete: Bool
}

struct AgentOrchestrationPresentation: Equatable, Sendable {
    let id: UUID
    let mode: AgentOrchestrationMode
    var phase: AgentOrchestrationPhase
    var headline: String
    var workers: [AgentOrchestrationWorkerPresentation]
    var runIDs: [RunID]

    var isActive: Bool { !phase.isTerminal }
}

private struct AgentOrchestrationWorkerSpec: Sendable {
    let id: String
    let title: String
    let symbol: String
    let instruction: String
}

private enum AgentOrchestrationError: Error, Sendable {
    case containerUnavailable
    case workspaceCloneFailed
    case workerRejected
    case workerTimedOut
    case integrationRejected
}

enum AgentSystemPresentationStoreError: Error, Equatable, Sendable {
    case containerIdentityConflict
    case hostNotReady
    case bindFailed
}

@MainActor
struct AgentSystemPresentationBoundDependencies {
    let materialize: @MainActor () async throws -> Void
    let loadGroups: @MainActor (AgentActivityProjectionScope) async throws
        -> [AgentActivityGroup]
    let route: @MainActor (AgentActivityCommand) async throws
        -> AgentSystemActivityCommandResult
    let liveSnapshot: @MainActor (RunID) async -> AgentSystemLiveTextSnapshot?
    let clearLive: @MainActor (RunID) async -> Void
}

@MainActor
struct AgentSystemPresentationStoreDependencies {
    let hostIsReady: @MainActor () -> Bool
    let registeredHandles: @MainActor () async throws
        -> [AgentSystemRunHandle]
    let start: @MainActor (AgentCommand, AgentSystemFreshRunPlan) async throws
        -> AgentSystemRunHandle
    let snapshot: @MainActor (AgentSystemRunHandle) async throws
        -> AgentDomain.AgentRunState
    let makeBound: @MainActor (ModelContainer)
        -> AgentSystemPresentationBoundDependencies

    static let production = Self(
        hostIsReady: {
            AgentSystemProductionHost.shared.status.phase == .ready
        },
        registeredHandles: {
            await AgentSystem.shared.registeredHandles()
        },
        start: { command, plan in
            try await AgentSystem.shared.start(command, plan: plan)
        },
        snapshot: { handle in
            try await AgentSystem.shared.snapshot(for: handle)
        },
        makeBound: { container in
            let store = SwiftDataAgentStore(container: container)
            let materializer = AgentSystemMaterializationCoordinator(
                store: store
            )
            let repository = AgentCanonicalActivityRepository(
                container: container
            )
            let router = AgentSystemActivityCommandRouter.production(
                container: container
            )
            return AgentSystemPresentationBoundDependencies(
                materialize: {
                    try await materializer.projectAvailableEvents()
                },
                loadGroups: { scope in
                    try await repository.groups(in: scope)
                },
                route: { command in
                    try await router.route(command)
                },
                liveSnapshot: { runID in
                    await AgentSystemLiveOutputCenter.shared.snapshot(
                        for: runID
                    )
                },
                clearLive: { runID in
                    await AgentSystemLiveOutputCenter.shared.clear(runID: runID)
                }
            )
        }
    )
}

/// MainActor presentation facade over the single process-owned AgentSystem.
/// It observes and materializes package-engine state; it owns no provider,
/// tool loop, approval authority, recovery queue, or second execution engine.
@MainActor
@Observable
final class AgentSystemPresentationStore {
    static let shared = AgentSystemPresentationStore()

    private struct Entry {
        let handle: AgentSystemRunHandle
        var state: AgentDomain.AgentRunState
        var group: AgentActivityGroup
        var liveText: AgentSystemLiveTextSnapshot?
    }

    private(set) var phase: AgentSystemPresentationStorePhase = .idle
    private(set) var revision: UInt64 = 0
    private(set) var globalFailure: AgentSystemPresentationFailure?
    #if DEBUG
    private(set) var debugLastStartError = "none"
    #endif

    var hasBlockingActivity: Bool {
        _ = revision
        return !acceptingWorkspaces.isEmpty ||
            orchestrations.values.contains(where: \.isActive) ||
            !synchronizingHandles.isEmpty ||
            entries.values.contains { !$0.state.phase.isTerminal }
    }

    @ObservationIgnored private let dependencies:
        AgentSystemPresentationStoreDependencies
    @ObservationIgnored private var boundContainer: ModelContainer?
    @ObservationIgnored private var boundContainerIdentity: ObjectIdentifier?
    @ObservationIgnored private var bound:
        AgentSystemPresentationBoundDependencies?
    @ObservationIgnored private var bindTask: Task<Void, any Error>?
    @ObservationIgnored private var entries: [RunID: Entry] = [:]
    @ObservationIgnored private var monitorTasks: [RunID: Task<Void, Never>] = [:]
    /// Handles accepted by the sole AgentSystem owner whose presentation has
    /// not materialized yet. They still reserve their workspace so a UI read
    /// failure can never make a second run look safe to start.
    @ObservationIgnored private var synchronizingHandles:
        [RunID: AgentSystemRunHandle] = [:]
    @ObservationIgnored private var acceptingScopes:
        Set<AgentSystemPresentationScope> = []
    @ObservationIgnored private var acceptingWorkspaces: Set<WorkspaceID> = []
    @ObservationIgnored private var failures:
        [AgentSystemPresentationScope: AgentSystemPresentationFailure] = [:]
    @ObservationIgnored private var orchestrations:
        [AgentSystemPresentationScope: AgentOrchestrationPresentation] = [:]
    @ObservationIgnored private var orchestrationTasks:
        [AgentSystemPresentationScope: Task<Void, Never>] = [:]

    init(
        dependencies: AgentSystemPresentationStoreDependencies = .production
    ) {
        self.dependencies = dependencies
    }

    func bind(container: ModelContainer) async throws {
        let identity = ObjectIdentifier(container)
        if let existing = boundContainerIdentity {
            guard existing == identity, boundContainer === container else {
                throw AgentSystemPresentationStoreError
                    .containerIdentityConflict
            }
            if phase == .ready { return }
            if let bindTask {
                return try await bindTask.value
            }
        } else {
            guard dependencies.hostIsReady() else {
                throw AgentSystemPresentationStoreError.hostNotReady
            }
            boundContainer = container
            boundContainerIdentity = identity
            bound = dependencies.makeBound(container)
        }

        phase = .binding
        publishRevision()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.performBind()
        }
        bindTask = task
        do {
            try await task.value
            bindTask = nil
            phase = .ready
            globalFailure = nil
            publishRevision()
        } catch {
            bindTask = nil
            phase = .failed
            globalFailure = .startupUnavailable
            publishRevision()
            throw AgentSystemPresentationStoreError.bindFailed
        }
    }

    func presentation(
        for scope: AgentSystemPresentationScope
    ) -> AgentSystemScopePresentation {
        _ = revision
        let scopedEntries = entries.values.filter {
            Self.scope(for: $0.handle) == scope
        }
        let active = scopedEntries.filter { !$0.state.phase.isTerminal }
        let synchronizing = synchronizingHandles.values.filter {
            Self.scope(for: $0) == scope
        }
        if active.count + synchronizing.count > 1 {
            return AgentSystemScopePresentation(
                scope: scope,
                activeGroup: nil,
                liveText: nil,
                isAccepting: acceptingScopes.contains(scope),
                isSynchronizing: !synchronizing.isEmpty,
                failure: .conflictingActiveRuns
            )
        }
        let entry = active.first ?? scopedEntries
            .filter { $0.state.phase.isTerminal }
            .max { lhs, rhs in
                if lhs.group.span.endedAt != rhs.group.span.endedAt {
                    return lhs.group.span.endedAt < rhs.group.span.endedAt
                }
                return lhs.handle.runID.rawValue.uuidString <
                    rhs.handle.runID.rawValue.uuidString
            }
        let orchestrationActive = orchestrations[scope]?.isActive == true
        return AgentSystemScopePresentation(
            scope: scope,
            activeGroup: entry?.group,
            liveText: entry?.liveText,
            isAccepting: acceptingScopes.contains(scope) || orchestrationActive,
            isSynchronizing: !synchronizing.isEmpty,
            failure: failures[scope] ??
                (synchronizing.isEmpty ? globalFailure : .projectionUnavailable)
        )
    }

    func orchestrationPresentation(
        for scope: AgentSystemPresentationScope
    ) -> AgentOrchestrationPresentation? {
        _ = revision
        return orchestrations[scope]
    }

    func activePresentation(
        in workspaceID: WorkspaceID
    ) -> AgentSystemScopePresentation? {
        _ = revision
        let active = entries.values.filter {
            $0.handle.identity.workspaceID == workspaceID &&
                !$0.state.phase.isTerminal
        }
        let synchronizing = synchronizingHandles.values.filter {
            $0.identity.workspaceID == workspaceID
        }
        guard active.count + synchronizing.count == 1 else { return nil }
        if let handle = synchronizing.first {
            let scope = Self.scope(for: handle)
            return AgentSystemScopePresentation(
                scope: scope,
                activeGroup: nil,
                liveText: nil,
                isAccepting: false,
                isSynchronizing: true,
                failure: failures[scope] ?? .projectionUnavailable
            )
        }
        guard let entry = active.first else { return nil }
        let scope = Self.scope(for: entry.handle)
        return AgentSystemScopePresentation(
            scope: scope,
            activeGroup: entry.group,
            liveText: entry.liveText,
            isAccepting: false,
            isSynchronizing: false,
            failure: failures[scope]
        )
    }

    func start(
        prompt: String,
        conversation: Conversation,
        project: Project?,
        workspace: SandboxWorkspace,
        settings: AgentSettings,
        publicRequestSummary: String? = nil,
        intent: AgentSystemPresentationStartIntent = .manual
    ) async -> AgentSystemPresentationStartDisposition {
        guard phase == .ready, bound != nil else {
            return .rejected(.startupUnavailable)
        }
        let scope = AgentSystemPresentationScope(
            project: project,
            conversation: conversation
        )
        let identity = AgentFreshSendCommandIdentity.fresh()
        let initiation: ResolvedInitiation
        do {
            initiation = try resolveInitiation(
                intent,
                scope: scope,
                newRunID: identity.runID
            )
        } catch {
            failures[scope] = .requestInvalid
            publishRevision()
            return .rejected(.requestInvalid)
        }
        return await startExplicit(
            prompt: prompt,
            conversation: conversation,
            project: project,
            workspace: workspace,
            settings: settings,
            publicRequestSummary: publicRequestSummary,
            identity: identity,
            lineage: initiation.lineage,
            origin: initiation.origin,
            expectedWorkspaceID: initiation.expectedWorkspaceID
        )
    }

    private func startExplicit(
        prompt: String,
        conversation: Conversation,
        project: Project?,
        workspace: SandboxWorkspace,
        settings: AgentSettings,
        publicRequestSummary: String?,
        identity: AgentFreshSendCommandIdentity,
        lineage: AgentRunLineage,
        origin: AgentRunRecordOrigin,
        expectedWorkspaceID: WorkspaceID? = nil
    ) async -> AgentSystemPresentationStartDisposition {
        let scope = AgentSystemPresentationScope(
            project: project,
            conversation: conversation
        )
        let request: AgentSystemFreshRunRequest
        do {
            request = try AgentSystemFreshRunRequestFactory.make(
                prompt: prompt,
                conversation: conversation,
                project: project,
                workspace: workspace,
                settings: settings,
                publicRequestSummary: publicRequestSummary,
                identity: identity,
                lineage: lineage,
                origin: origin
            )
        } catch let error as AgentSystemFreshRunRequestFactoryError {
            let failure: AgentSystemPresentationFailure = switch error {
            case .unsupportedProvider, .unsupportedModel:
                .providerUnsupported
            default:
                .requestInvalid
            }
            failures[scope] = failure
            publishRevision()
            return .rejected(failure)
        } catch {
            failures[scope] = .requestInvalid
            publishRevision()
            return .rejected(.requestInvalid)
        }

        guard case let .send(send) = request.command.payload else {
            failures[scope] = .requestInvalid
            publishRevision()
            return .rejected(.requestInvalid)
        }
        let workspaceID = send.context.workspaceID
        guard expectedWorkspaceID == nil || expectedWorkspaceID == workspaceID else {
            failures[scope] = .requestInvalid
            publishRevision()
            return .rejected(.requestInvalid)
        }
        guard !acceptingWorkspaces.contains(workspaceID),
              !entries.values.contains(where: {
                  $0.handle.identity.workspaceID == workspaceID &&
                      !$0.state.phase.isTerminal
              }),
              !synchronizingHandles.values.contains(where: {
                  $0.identity.workspaceID == workspaceID
              })
        else {
            failures[scope] = .workspaceBusy
            publishRevision()
            return .busy
        }

        acceptingScopes.insert(scope)
        acceptingWorkspaces.insert(workspaceID)
        failures.removeValue(forKey: scope)
        publishRevision()
        defer {
            acceptingScopes.remove(scope)
            acceptingWorkspaces.remove(workspaceID)
            publishRevision()
        }

        do {
            let handle = try await dependencies.start(
                request.command,
                request.plan
            )
            do {
                try await attach(handle)
            } catch {
                retainForSynchronization(handle)
            }
            return .accepted(handle.runID)
        } catch {
            #if DEBUG
            debugLastStartError = String(reflecting: error)
            #endif
            failures[scope] = .runtimeUnavailable
            return .rejected(.runtimeUnavailable)
        }
    }

    func startConfigured(
        prompt: String,
        conversation: Conversation,
        project: Project?,
        workspace: SandboxWorkspace,
        settings: AgentSettings,
        publicRequestSummary: String? = nil
    ) async -> AgentSystemPresentationStartDisposition {
        let mode = AgentRunPreferenceStore.shared.orchestrationMode
        guard mode != .standard else {
            return await start(
                prompt: prompt,
                conversation: conversation,
                project: project,
                workspace: workspace,
                settings: settings,
                publicRequestSummary: publicRequestSummary
            )
        }
        return await startOrchestration(
            mode: mode,
            prompt: prompt,
            conversation: conversation,
            project: project,
            workspace: workspace,
            settings: settings,
            publicRequestSummary: publicRequestSummary
        )
    }

    private func startOrchestration(
        mode: AgentOrchestrationMode,
        prompt: String,
        conversation: Conversation,
        project: Project?,
        workspace: SandboxWorkspace,
        settings: AgentSettings,
        publicRequestSummary: String?
    ) async -> AgentSystemPresentationStartDisposition {
        guard phase == .ready, bound != nil else {
            return .rejected(.startupUnavailable)
        }
        let scope = AgentSystemPresentationScope(
            project: project,
            conversation: conversation
        )
        guard orchestrations[scope]?.isActive != true else { return .busy }

        let orchestrationID = UUID()
        let specs = Self.workerSpecs(for: mode)
        orchestrations[scope] = AgentOrchestrationPresentation(
            id: orchestrationID,
            mode: mode,
            phase: .preparing,
            headline: "Preparing isolated agent workspaces",
            workers: specs.map {
                AgentOrchestrationWorkerPresentation(
                    id: $0.id,
                    title: $0.title,
                    symbol: $0.symbol,
                    status: "Preparing",
                    isComplete: false
                )
            },
            runIDs: []
        )
        publishRevision()

        do {
            let scratchNames = specs.map {
                Self.scratchWorkspaceName(
                    orchestrationID: orchestrationID,
                    workerID: $0.id
                )
            }
            let scratchWorkspaces = try await Self.cloneWorkspaces(
                from: workspace,
                names: scratchNames
            )
            let workerConversations = try makeWorkerConversations(
                specs: specs,
                orchestrationID: orchestrationID
            )
            let rootIdentity = AgentFreshSendCommandIdentity.fresh()
            let rootLineage = AgentRunLineage.root(rootIdentity.runID)
            let rootSettings = Self.workerSettings(
                from: settings,
                workspaceName: scratchWorkspaces[0].workspaceName
            )
            let rootDisposition = await startExplicit(
                prompt: Self.workerPrompt(
                    spec: specs[0],
                    originalPrompt: prompt,
                    mode: mode
                ),
                conversation: workerConversations[0],
                project: nil,
                workspace: scratchWorkspaces[0],
                settings: rootSettings,
                publicRequestSummary: "\(mode.title) · \(specs[0].title)",
                identity: rootIdentity,
                lineage: rootLineage,
                origin: .system
            )
            guard case let .accepted(rootRunID) = rootDisposition else {
                throw AgentOrchestrationError.workerRejected
            }
            updateOrchestration(scope) { state in
                state.phase = .delegating
                state.headline = "Independent agents are investigating"
                state.runIDs.append(rootRunID)
                Self.updateWorker(
                    specs[0].id,
                    status: "Working",
                    complete: false,
                    in: &state
                )
            }

            orchestrationTasks[scope]?.cancel()
            orchestrationTasks[scope] = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.continueOrchestration(
                    scope: scope,
                    orchestrationID: orchestrationID,
                    mode: mode,
                    originalPrompt: prompt,
                    visibleSummary: publicRequestSummary,
                    conversation: conversation,
                    project: project,
                    workspace: workspace,
                    settings: settings,
                    specs: specs,
                    workerConversations: workerConversations,
                    scratchWorkspaces: scratchWorkspaces,
                    rootLineage: rootLineage,
                    rootRunID: rootRunID
                )
            }
            return .accepted(rootRunID)
        } catch {
            updateOrchestration(scope) { state in
                state.phase = .failed
                state.headline = "Could not prepare isolated agents"
            }
            failures[scope] = .runtimeUnavailable
            publishRevision()
            return .rejected(.runtimeUnavailable)
        }
    }

    private func continueOrchestration(
        scope: AgentSystemPresentationScope,
        orchestrationID: UUID,
        mode: AgentOrchestrationMode,
        originalPrompt: String,
        visibleSummary: String?,
        conversation: Conversation,
        project: Project?,
        workspace: SandboxWorkspace,
        settings: AgentSettings,
        specs: [AgentOrchestrationWorkerSpec],
        workerConversations: [Conversation],
        scratchWorkspaces: [SandboxWorkspace],
        rootLineage: AgentRunLineage,
        rootRunID: RunID
    ) async {
        do {
            var workerRuns: [(AgentOrchestrationWorkerSpec, RunID)] = [
                (specs[0], rootRunID),
            ]
            for index in specs.indices.dropFirst() {
                try Task.checkCancellation()
                let identity = AgentFreshSendCommandIdentity.fresh()
                let childSettings = Self.workerSettings(
                    from: settings,
                    workspaceName: scratchWorkspaces[index].workspaceName
                )
                let disposition = await startExplicit(
                    prompt: Self.workerPrompt(
                        spec: specs[index],
                        originalPrompt: originalPrompt,
                        mode: mode
                    ),
                    conversation: workerConversations[index],
                    project: nil,
                    workspace: scratchWorkspaces[index],
                    settings: childSettings,
                    publicRequestSummary: "\(mode.title) · \(specs[index].title)",
                    identity: identity,
                    lineage: .child(identity.runID, of: rootLineage),
                    origin: .system
                )
                guard case let .accepted(runID) = disposition else {
                    throw AgentOrchestrationError.workerRejected
                }
                workerRuns.append((specs[index], runID))
                updateOrchestration(scope) { state in
                    state.runIDs.append(runID)
                    Self.updateWorker(
                        specs[index].id,
                        status: "Working",
                        complete: false,
                        in: &state
                    )
                }
            }

            let reports = try await waitForWorkerReports(
                workerRuns,
                scope: scope
            )
            try Task.checkCancellation()
            updateOrchestration(scope) { state in
                state.phase = .integrating
                state.headline = "Lead agent is integrating and verifying"
            }

            let integratorIdentity = AgentFreshSendCommandIdentity.fresh()
            let integratorPrompt = Self.integratorPrompt(
                originalPrompt: originalPrompt,
                reports: reports,
                mode: mode
            )
            let disposition = await startExplicit(
                prompt: integratorPrompt,
                conversation: conversation,
                project: project,
                workspace: workspace,
                settings: settings,
                publicRequestSummary: Self.visibleOrchestrationSummary(
                    explicit: visibleSummary,
                    originalPrompt: originalPrompt,
                    mode: mode
                ),
                identity: integratorIdentity,
                lineage: .child(integratorIdentity.runID, of: rootLineage),
                origin: .system
            )
            guard case let .accepted(integratorRunID) = disposition else {
                throw AgentOrchestrationError.integrationRejected
            }
            updateOrchestration(scope) { state in
                state.runIDs.append(integratorRunID)
            }
            let final = try await waitForTerminalState(
                runID: integratorRunID,
                timeout: .seconds(900),
                workerID: nil,
                scope: scope
            )
            updateOrchestration(scope) { state in
                if final.phase == .completed {
                    state.phase = .completed
                    state.headline = "\(mode.title) completed with integrated proof"
                } else {
                    state.phase = .failed
                    state.headline = "Lead integration did not complete"
                }
            }
        } catch is CancellationError {
            await cancelOrchestration(scope: scope, markCancelled: true)
        } catch {
            updateOrchestration(scope) { state in
                state.phase = .failed
                state.headline = "One or more delegated agents could not finish"
            }
            failures[scope] = .runtimeUnavailable
            publishRevision()
        }
        orchestrationTasks.removeValue(forKey: scope)
    }

    func cancelOrchestration(
        scope: AgentSystemPresentationScope,
        markCancelled: Bool = true
    ) async {
        orchestrationTasks[scope]?.cancel()
        orchestrationTasks.removeValue(forKey: scope)
        let runIDs = orchestrations[scope]?.runIDs ?? []
        for runID in runIDs {
            guard let entry = entries[runID],
                  !entry.state.phase.isTerminal,
                  entry.group.accepts(entry.group.cancelCommand)
            else { continue }
            _ = try? await route(entry.group.cancelCommand)
        }
        if markCancelled {
            updateOrchestration(scope) { state in
                state.phase = .cancelled
                state.headline = "Delegated agents stopped safely"
            }
        }
    }

    private func waitForWorkerReports(
        _ workerRuns: [(AgentOrchestrationWorkerSpec, RunID)],
        scope: AgentSystemPresentationScope
    ) async throws -> [(String, String)] {
        var reports: [(String, String)] = []
        for (spec, runID) in workerRuns {
            let state = try await waitForTerminalState(
                runID: runID,
                timeout: .seconds(720),
                workerID: spec.id,
                scope: scope
            )
            let output = Self.assistantReport(from: state)
            reports.append((spec.title, output))
            updateOrchestration(scope) { presentation in
                Self.updateWorker(
                    spec.id,
                    status: state.phase == .completed ? "Complete" : "Reviewed",
                    complete: true,
                    in: &presentation
                )
            }
        }
        return reports
    }

    private func waitForTerminalState(
        runID: RunID,
        timeout: Duration,
        workerID: String?,
        scope: AgentSystemPresentationScope
    ) async throws -> AgentDomain.AgentRunState {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let entry = entries[runID] {
                if let workerID {
                    updateOrchestration(scope) { state in
                        Self.updateWorker(
                            workerID,
                            status: Self.workerStatus(entry.state.phase),
                            complete: entry.state.phase.isTerminal,
                            in: &state
                        )
                    }
                }
                if entry.state.phase == .awaitingApproval {
                    if entry.group.accepts(entry.group.cancelCommand) {
                        _ = try? await route(entry.group.cancelCommand)
                    }
                    return entry.state
                }
                if entry.state.phase.isTerminal { return entry.state }
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        throw AgentOrchestrationError.workerTimedOut
    }

    private func makeWorkerConversations(
        specs: [AgentOrchestrationWorkerSpec],
        orchestrationID: UUID
    ) throws -> [Conversation] {
        guard let boundContainer else {
            throw AgentOrchestrationError.containerUnavailable
        }
        let context = ModelContext(boundContainer)
        let conversations = specs.map { spec in
            Conversation(
                title: "\(Conversation.orchestrationTitlePrefix)\(orchestrationID.uuidString.prefix(8)) · \(spec.title)"
            )
        }
        for conversation in conversations { context.insert(conversation) }
        try context.save()
        return conversations
    }

    private func updateOrchestration(
        _ scope: AgentSystemPresentationScope,
        mutate: (inout AgentOrchestrationPresentation) -> Void
    ) {
        guard var value = orchestrations[scope] else { return }
        mutate(&value)
        orchestrations[scope] = value
        publishRevision()
    }

    private static func updateWorker(
        _ id: String,
        status: String,
        complete: Bool,
        in presentation: inout AgentOrchestrationPresentation
    ) {
        guard let index = presentation.workers.firstIndex(where: { $0.id == id })
        else { return }
        presentation.workers[index].status = status
        presentation.workers[index].isComplete = complete
    }

    private static func workerStatus(_ phase: AgentRunPhase) -> String {
        switch phase {
        case .uninitialized, .accepted, .queued: "Queued"
        case .running: "Investigating"
        case .awaitingApproval: "Handing off safely"
        case .cancelling: "Stopping"
        case .completed: "Complete"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .interrupted: "Interrupted"
        }
    }

    private static func assistantReport(
        from state: AgentDomain.AgentRunState
    ) -> String {
        let text = state.modelItems.compactMap { item -> String? in
            guard case let .message(message) = item.payload,
                  message.role == .assistant else { return nil }
            let parts = message.content.compactMap { part -> String? in
                guard case let .text(value) = part else { return nil }
                return value
            }
            return parts.joined()
        }.joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No textual report was produced; independently verify this area." }
        return String(trimmed.prefix(16_000))
    }

    private static func workerSpecs(
        for mode: AgentOrchestrationMode
    ) -> [AgentOrchestrationWorkerSpec] {
        switch mode {
        case .standard:
            return []
        case .ultra:
            return [
                .init(
                    id: "strategist",
                    title: "Strategist",
                    symbol: "map.fill",
                    instruction: "Decompose the request, inspect relevant files, identify dependencies and the safest high-quality execution plan."
                ),
                .init(
                    id: "critic",
                    title: "Critical reviewer",
                    symbol: "checkmark.seal.fill",
                    instruction: "Independently inspect the request and workspace. Find hidden risks, missing requirements, regressions, and verification gates."
                ),
            ]
        case .ultraCode:
            return [
                .init(
                    id: "explorer",
                    title: "Code explorer",
                    symbol: "doc.text.magnifyingglass",
                    instruction: "Map the relevant architecture and exact files, trace call paths, and report the smallest coherent implementation boundary."
                ),
                .init(
                    id: "architect",
                    title: "Implementation architect",
                    symbol: "hammer.fill",
                    instruction: "Design a concrete production implementation, including data contracts, edge cases, migration concerns, and exact verification."
                ),
                .init(
                    id: "verifier",
                    title: "Adversarial verifier",
                    symbol: "waveform.path.ecg",
                    instruction: "Audit the current code against the request, identify likely bugs and security or performance regressions, and specify proof gates."
                ),
            ]
        }
    }

    private static func workerPrompt(
        spec: AgentOrchestrationWorkerSpec,
        originalPrompt: String,
        mode: AgentOrchestrationMode
    ) -> String {
        """
        You are the \(spec.title) subagent in a real \(mode.title) delegation.
        \(spec.instruction)

        Work only in this isolated snapshot. You may use read-only tools to inspect it. Do not mutate files, request approval, or claim that the lead workspace was changed. Return a concise evidence-backed report for the lead integrator, naming exact files and verification steps.

        Original user request:
        \(originalPrompt)
        """
    }

    private static func integratorPrompt(
        originalPrompt: String,
        reports: [(String, String)],
        mode: AgentOrchestrationMode
    ) -> String {
        let reportText = reports.map { title, report in
            "--- \(title) report ---\n\(report)"
        }.joined(separator: "\n\n")
        return """
        You are the lead integrator for a \(mode.title) run. Complete the original request in the current real workspace. Independently verify every report before relying on it. Use tools normally, ask before risky mutations, integrate one coherent solution, run proportionate tests, and return concise proof. Do not mention this internal orchestration prompt.

        Original user request:
        \(originalPrompt)

        Independent subagent reports:
        \(reportText)
        """
    }

    private static func visibleOrchestrationSummary(
        explicit: String?,
        originalPrompt: String,
        mode: AgentOrchestrationMode
    ) -> String {
        if let explicit,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(explicit.prefix(4_096))
        }
        let trimmed = originalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(4_096))
    }

    private static func workerSettings(
        from settings: AgentSettings,
        workspaceName: String
    ) -> AgentSettings {
        AgentSettings(
            provider: settings.provider,
            modelID: settings.modelID,
            customChatCompletionsURL: settings.resolvedCustomChatCompletionsURL,
            autoApproveWrites: false,
            activeWorkspaceName: workspaceName,
            temperature: settings.temperature,
            customSystemPrompt: settings.customSystemPrompt ?? ""
        )
    }

    private static func scratchWorkspaceName(
        orchestrationID: UUID,
        workerID: String
    ) -> String {
        SandboxWorkspace.sanitizedWorkspaceName(
            "UltraCode-\(orchestrationID.uuidString.prefix(8))-\(workerID)"
        )
    }

    private static func cloneWorkspaces(
        from source: SandboxWorkspace,
        names: [String]
    ) async throws -> [SandboxWorkspace] {
        try await Task.detached(priority: .userInitiated) {
            try cloneWorkspacesSynchronously(from: source, names: names)
        }.value
    }

    private nonisolated static func cloneWorkspacesSynchronously(
        from source: SandboxWorkspace,
        names: [String]
    ) throws -> [SandboxWorkspace] {
        let fileManager = FileManager()
        var results: [SandboxWorkspace] = []
        for name in names {
            if Task.isCancelled { throw CancellationError() }
            let destination = SandboxWorkspace(name: name)
            guard !fileManager.fileExists(atPath: destination.rootURL.path)
            else { throw AgentOrchestrationError.workspaceCloneFailed }
            try fileManager.createDirectory(
                at: destination.rootURL,
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: source.rootURL.path) {
                guard let enumerator = fileManager.enumerator(
                    at: source.rootURL,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                    ],
                    options: [.skipsHiddenFiles]
                ) else { throw AgentOrchestrationError.workspaceCloneFailed }
                var fileCount = 0
                var byteCount: Int64 = 0
                while let itemURL = enumerator.nextObject() as? URL {
                    if Task.isCancelled { throw CancellationError() }
                    fileCount += 1
                    guard fileCount <= 20_000 else {
                        throw AgentOrchestrationError.workspaceCloneFailed
                    }
                    let values = try itemURL.resourceValues(forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                    ])
                    if values.isSymbolicLink == true {
                        enumerator.skipDescendants()
                        continue
                    }
                    let relative = itemURL.path.replacingOccurrences(
                        of: source.rootURL.path + "/",
                        with: ""
                    )
                    guard !relative.isEmpty,
                          !relative.hasPrefix("../"),
                          !relative.contains("/../")
                    else { throw AgentOrchestrationError.workspaceCloneFailed }
                    let target = destination.rootURL.appendingPathComponent(relative)
                    if values.isDirectory == true {
                        try fileManager.createDirectory(
                            at: target,
                            withIntermediateDirectories: true
                        )
                    } else {
                        byteCount += Int64(values.fileSize ?? 0)
                        guard byteCount <= 512 * 1_024 * 1_024 else {
                            throw AgentOrchestrationError.workspaceCloneFailed
                        }
                        try fileManager.createDirectory(
                            at: target.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.copyItem(at: itemURL, to: target)
                    }
                }
            }
            results.append(destination)
        }
        return results
    }

    func retry(
        _ retry: AgentActivityRetryCommand,
        conversation: Conversation,
        project: Project?,
        workspace: SandboxWorkspace,
        settings: AgentSettings
    ) async -> AgentSystemPresentationStartDisposition {
        let scope = AgentSystemPresentationScope(
            project: project,
            conversation: conversation
        )
        guard retry.run.projectID == scope.projectID,
              retry.run.conversationID == scope.conversationID,
              let entry = entries[retry.run.runID],
              entry.group.identity == retry.run,
              entry.group.accepts(.retry(retry)),
              let prompt = Self.acceptedPrompt(from: entry.state)
        else {
            failures[scope] = .requestInvalid
            publishRevision()
            return .rejected(.requestInvalid)
        }
        return await start(
            prompt: prompt,
            conversation: conversation,
            project: project,
            workspace: workspace,
            settings: settings,
            intent: .retry(previousRunID: retry.run.runID)
        )
    }

    @discardableResult
    func route(
        _ command: AgentActivityCommand
    ) async throws -> AgentSystemActivityCommandResult {
        guard let bound else {
            throw AgentSystemActivityCommandRouterError.dispatchUnavailable
        }
        do {
            let result = try await bound.route(command)
            if case .executed = result,
               let entry = entries[command.run.runID] {
                do {
                    try await refresh(
                        entry.handle,
                        forceMaterialization: true
                    )
                } catch {
                    failures[Self.scope(for: entry.handle)] =
                        .projectionUnavailable
                    startMonitorIfNeeded(entry.handle)
                    publishRevision()
                }
            }
            return result
        } catch {
            failures[AgentSystemPresentationScope(
                projectID: command.run.projectID,
                conversationID: command.run.conversationID
            )] = .commandUnavailable
            publishRevision()
            if let finite = error as? AgentSystemActivityCommandRouterError {
                throw finite
            }
            throw AgentSystemActivityCommandRouterError.dispatchUnavailable
        }
    }

    func acknowledgeLiveHandoff(runID: RunID) async {
        if let bound {
            await bound.clearLive(runID)
        }
        if var entry = entries[runID], entry.state.phase.isTerminal {
            entry.liveText = nil
            entries[runID] = entry
            publishRevision()
        }
    }

    private func performBind() async throws {
        guard let bound else {
            throw AgentSystemPresentationStoreError.bindFailed
        }
        try await bound.materialize()
        let handles = try await dependencies.registeredHandles()
        guard Set(handles.map(\.runID)).count == handles.count else {
            throw AgentSystemPresentationStoreError.bindFailed
        }
        for handle in handles {
            do {
                try await attach(handle)
            } catch {
                retainForSynchronization(handle)
            }
        }
    }

    private func attach(_ handle: AgentSystemRunHandle) async throws {
        if let existing = entries[handle.runID] {
            guard existing.handle == handle else {
                throw AgentSystemPresentationStoreError.bindFailed
            }
            if !existing.state.phase.isTerminal {
                startMonitorIfNeeded(handle)
            }
            return
        }
        try await refresh(handle, forceMaterialization: true)
        if entries[handle.runID]?.state.phase.isTerminal == false {
            startMonitorIfNeeded(handle)
        }
    }

    private func refresh(
        _ handle: AgentSystemRunHandle,
        forceMaterialization: Bool
    ) async throws {
        guard let bound else {
            throw AgentSystemPresentationStoreError.bindFailed
        }
        let state = try await dependencies.snapshot(handle)
        guard let context = state.context,
              AgentSystemRunIdentity(context: context) == handle.identity
        else { throw AgentSystemPresentationStoreError.bindFailed }

        if let existing = entries[handle.runID],
           let previous = existing.state.lastSequence,
           let next = state.lastSequence,
           next < previous {
            return
        }
        let sequenceChanged = entries[handle.runID]?.state.lastSequence !=
            state.lastSequence
        if !forceMaterialization,
           !sequenceChanged,
           var existing = entries[handle.runID] {
            var live = await bound.liveSnapshot(handle.runID)
            if state.phase == .failed || state.phase == .cancelled ||
                state.phase == .interrupted {
                await bound.clearLive(handle.runID)
                live = nil
            }
            let failureCleared = failures.removeValue(
                forKey: Self.scope(for: handle)
            ) != nil
            guard existing.liveText != live || failureCleared else { return }
            existing.liveText = live
            entries[handle.runID] = existing
            publishRevision()
            return
        }
        if forceMaterialization || sequenceChanged {
            try await bound.materialize()
        }
        let scope = AgentActivityProjectionScope(
            projectID: handle.identity.projectID,
            conversationID: handle.identity.conversationID,
            runID: handle.runID
        )
        let groups = try await bound.loadGroups(scope)
        guard groups.count == 1,
              let group = groups.first,
              group.identity.runID == handle.runID,
              group.identity.projectID == handle.identity.projectID,
              group.identity.conversationID == handle.identity.conversationID,
              group.identity.workspaceID == handle.identity.workspaceID
        else { throw AgentSystemPresentationStoreError.bindFailed }

        var live = await bound.liveSnapshot(handle.runID)
        if state.phase == .failed || state.phase == .cancelled ||
            state.phase == .interrupted {
            await bound.clearLive(handle.runID)
            live = nil
        }
        let next = Entry(
            handle: handle,
            state: state,
            group: group,
            liveText: live
        )
        let synchronizationFinished = synchronizingHandles.removeValue(
            forKey: handle.runID
        ) != nil
        let failureCleared = failures.removeValue(
            forKey: Self.scope(for: handle)
        ) != nil
        let entryChanged = entries[handle.runID]?.state != next.state ||
            entries[handle.runID]?.group != next.group ||
            entries[handle.runID]?.liveText != next.liveText
        if entryChanged {
            entries[handle.runID] = next
        }
        if entryChanged || synchronizationFinished || failureCleared {
            publishRevision()
        }
    }

    private func startMonitorIfNeeded(_ handle: AgentSystemRunHandle) {
        guard monitorTasks[handle.runID] == nil else { return }
        monitorTasks[handle.runID] = Task { @MainActor [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(80))
                    try Task.checkCancellation()
                    try await self.refresh(
                        handle,
                        forceMaterialization: false
                    )
                    consecutiveFailures = 0
                    if self.entries[handle.runID]?.state.phase.isTerminal ==
                        true {
                        break
                    }
                } catch is CancellationError {
                    break
                } catch {
                    self.failures[Self.scope(for: handle)] =
                        .projectionUnavailable
                    self.publishRevision()
                    consecutiveFailures += 1
                    if consecutiveFailures >= 8 { break }
                }
            }
            self.monitorTasks.removeValue(forKey: handle.runID)
        }
    }

    private func retainForSynchronization(_ handle: AgentSystemRunHandle) {
        synchronizingHandles[handle.runID] = handle
        failures[Self.scope(for: handle)] = .projectionUnavailable
        startMonitorIfNeeded(handle)
        publishRevision()
    }

    private struct ResolvedInitiation {
        let lineage: AgentRunLineage
        let origin: AgentRunRecordOrigin
        let expectedWorkspaceID: WorkspaceID?
    }

    private func resolveInitiation(
        _ intent: AgentSystemPresentationStartIntent,
        scope: AgentSystemPresentationScope,
        newRunID: RunID
    ) throws -> ResolvedInitiation {
        switch intent {
        case .manual:
            return ResolvedInitiation(
                lineage: .root(newRunID),
                origin: .user,
                expectedWorkspaceID: nil
            )
        case .autoContinued:
            guard let parent = latestTerminalEntry(in: scope) else {
                return ResolvedInitiation(
                    lineage: .root(newRunID),
                    origin: .autoContinue,
                    expectedWorkspaceID: nil
                )
            }
            guard let parentContext = parent.state.context else {
                throw AgentSystemPresentationStoreError.bindFailed
            }
            return ResolvedInitiation(
                lineage: .child(newRunID, of: parentContext.lineage),
                origin: .autoContinue,
                expectedWorkspaceID: parent.handle.identity.workspaceID
            )
        case let .continuation(parentRunID):
            guard let parent = entries[parentRunID],
                  parent.state.phase.isTerminal,
                  Self.scope(for: parent.handle) == scope,
                  let parentContext = parent.state.context else {
                throw AgentSystemPresentationStoreError.bindFailed
            }
            return ResolvedInitiation(
                lineage: .child(newRunID, of: parentContext.lineage),
                origin: .continuation,
                expectedWorkspaceID: parent.handle.identity.workspaceID
            )
        case let .retry(previousRunID):
            guard let previous = entries[previousRunID],
                  previous.state.phase.isTerminal,
                  Self.scope(for: previous.handle) == scope,
                  let previousContext = previous.state.context else {
                throw AgentSystemPresentationStoreError.bindFailed
            }
            return ResolvedInitiation(
                lineage: .retry(newRunID, of: previousContext.lineage),
                origin: .retry,
                expectedWorkspaceID: previous.handle.identity.workspaceID
            )
        }
    }

    private func latestTerminalEntry(
        in scope: AgentSystemPresentationScope
    ) -> Entry? {
        entries.values
            .filter {
                $0.state.phase.isTerminal && Self.scope(for: $0.handle) == scope
            }
            .max { lhs, rhs in
                let lhsEnd = lhs.group.span.endedAt
                let rhsEnd = rhs.group.span.endedAt
                if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
                return lhs.handle.runID.rawValue.uuidString <
                    rhs.handle.runID.rawValue.uuidString
            }
    }

    private static func acceptedPrompt(
        from state: AgentDomain.AgentRunState
    ) -> String? {
        for item in state.modelItems.sorted(by: {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }) {
            guard case let .message(message) = item.payload,
                  message.role == .user,
                  message.content.count == 1,
                  case let .text(prompt) = message.content[0],
                  !prompt.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty else { continue }
            return prompt
        }
        return nil
    }

    private static func scope(
        for handle: AgentSystemRunHandle
    ) -> AgentSystemPresentationScope {
        AgentSystemPresentationScope(
            projectID: handle.identity.projectID,
            conversationID: handle.identity.conversationID
        )
    }

    private func publishRevision() {
        if revision < UInt64.max { revision += 1 }
    }
}
