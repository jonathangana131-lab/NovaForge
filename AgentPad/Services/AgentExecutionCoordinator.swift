import Foundation

/// Serializes scarce or state-changing agent work across every runtime that
/// participates in the same app session.
///
/// NovaForge intentionally keeps chat and project runtimes separate so each
/// surface can retain its own transient presentation state. They still share
/// the same on-device model process and may target the same workspace, so the
/// expensive and mutating parts of a run need one arbitration point.
actor AgentExecutionCoordinator {
    struct Lease: Hashable, Sendable {
        enum Resource: Hashable, Sendable {
            case localInference
            case workspaceMutation(String)
        }

        let id: UUID
        let resource: Resource
        let runID: UUID
        let ownerDescription: String
        let acquiredAt: Date
    }

    struct Snapshot: Equatable, Sendable {
        let activeLocalInferenceOwner: String?
        let activeMutationOwnersByWorkspace: [String: String]
        let queuedLocalInferenceCount: Int
        let queuedMutationCountsByWorkspace: [String: Int]

        var hasActiveWork: Bool {
            activeLocalInferenceOwner != nil || !activeMutationOwnersByWorkspace.isEmpty
        }

        var hasQueuedWork: Bool {
            queuedLocalInferenceCount > 0 || !queuedMutationCountsByWorkspace.isEmpty
        }
    }

    private struct Waiter {
        let id: UUID
        let resource: Lease.Resource
        let runID: UUID
        let ownerDescription: String
        let continuation: CheckedContinuation<Lease, Error>
    }

    private var activeLeases: [Lease.Resource: Lease] = [:]
    private var waiters: [Lease.Resource: [Waiter]] = [:]

    /// `pollInterval` remains source-compatible with the V1 initializer while
    /// callers migrate. Arbitration is continuation-driven and never polls.
    init(pollInterval _: Duration = .milliseconds(70)) {}

    func acquireLocalInference(
        runID: UUID,
        ownerDescription: String
    ) async throws -> Lease {
        try await acquire(
            resource: .localInference,
            runID: runID,
            ownerDescription: ownerDescription
        )
    }

    func acquireMutation(
        workspaceName: String,
        runID: UUID,
        ownerDescription: String
    ) async throws -> Lease {
        try await acquireMutation(
            workspaceID: nil,
            workspaceName: workspaceName,
            runID: runID,
            ownerDescription: ownerDescription
        )
    }

    func acquireMutation(
        workspaceID: UUID?,
        workspaceName: String,
        runID: UUID,
        ownerDescription: String
    ) async throws -> Lease {
        try await acquire(
            resource: .workspaceMutation(
                Self.workspaceKey(id: workspaceID, name: workspaceName)
            ),
            runID: runID,
            ownerDescription: ownerDescription
        )
    }

    func release(_ lease: Lease) {
        guard activeLeases[lease.resource]?.id == lease.id else { return }
        activeLeases[lease.resource] = nil
        grantNextWaiter(for: lease.resource)
    }

    func snapshot() -> Snapshot {
        var activeLocalInferenceOwner: String?
        var activeMutationOwnersByWorkspace: [String: String] = [:]
        for (resource, lease) in activeLeases {
            switch resource {
            case .localInference:
                activeLocalInferenceOwner = lease.ownerDescription
            case .workspaceMutation(let workspaceKey):
                activeMutationOwnersByWorkspace[workspaceKey] = lease.ownerDescription
            }
        }

        var queuedLocalInferenceCount = 0
        var queuedMutationCountsByWorkspace: [String: Int] = [:]
        for (resource, resourceWaiters) in waiters where !resourceWaiters.isEmpty {
            switch resource {
            case .localInference:
                queuedLocalInferenceCount = resourceWaiters.count
            case .workspaceMutation(let workspaceKey):
                queuedMutationCountsByWorkspace[workspaceKey] = resourceWaiters.count
            }
        }

        return Snapshot(
            activeLocalInferenceOwner: activeLocalInferenceOwner,
            activeMutationOwnersByWorkspace: activeMutationOwnersByWorkspace,
            queuedLocalInferenceCount: queuedLocalInferenceCount,
            queuedMutationCountsByWorkspace: queuedMutationCountsByWorkspace
        )
    }

    private func acquire(
        resource: Lease.Resource,
        runID: UUID,
        ownerDescription: String
    ) async throws -> Lease {
        try Task.checkCancellation()
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            let lease = try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    Waiter(
                        id: waiterID,
                        resource: resource,
                        runID: runID,
                        ownerDescription: ownerDescription,
                        continuation: continuation
                    )
                )
            }

            do {
                // Cancellation can race the handoff. Never return an owned lease
                // to a task that was cancelled while its continuation resumed.
                try Task.checkCancellation()
                return lease
            } catch {
                release(lease)
                throw error
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID, for: resource)
            }
        }
    }

    private func enqueue(_ waiter: Waiter) {
        waiters[waiter.resource, default: []].append(waiter)
        grantNextWaiter(for: waiter.resource)
    }

    private func cancelWaiter(id: UUID, for resource: Lease.Resource) {
        if activeLeases[resource]?.id == id {
            activeLeases[resource] = nil
            grantNextWaiter(for: resource)
            return
        }

        guard var resourceWaiters = waiters[resource],
              let index = resourceWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = resourceWaiters.remove(at: index)
        waiters[resource] = resourceWaiters.isEmpty ? nil : resourceWaiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func grantNextWaiter(for resource: Lease.Resource) {
        guard activeLeases[resource] == nil,
              var resourceWaiters = waiters[resource],
              !resourceWaiters.isEmpty else {
            return
        }

        let waiter = resourceWaiters.removeFirst()
        waiters[resource] = resourceWaiters.isEmpty ? nil : resourceWaiters
        let lease = Lease(
            id: waiter.id,
            resource: waiter.resource,
            runID: waiter.runID,
            ownerDescription: waiter.ownerDescription,
            acquiredAt: Date()
        )
        activeLeases[resource] = lease
        waiter.continuation.resume(returning: lease)
    }

    static func workspaceKey(id: UUID?, name workspaceName: String) -> String {
        if let id {
            return "id:\(id.uuidString.lowercased())"
        }
        let trimmed = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "default" : trimmed).lowercased()
    }
}
