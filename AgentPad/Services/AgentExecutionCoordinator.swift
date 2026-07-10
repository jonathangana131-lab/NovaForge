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

        var hasActiveWork: Bool {
            activeLocalInferenceOwner != nil || !activeMutationOwnersByWorkspace.isEmpty
        }
    }

    private var activeLocalInferenceLease: Lease?
    private var activeMutationLeases: [String: Lease] = [:]
    private let pollInterval: Duration

    init(pollInterval: Duration = .milliseconds(70)) {
        self.pollInterval = pollInterval
    }

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
        try await acquire(
            resource: .workspaceMutation(Self.workspaceKey(workspaceName)),
            runID: runID,
            ownerDescription: ownerDescription
        )
    }

    func release(_ lease: Lease) {
        switch lease.resource {
        case .localInference:
            guard activeLocalInferenceLease?.id == lease.id else { return }
            activeLocalInferenceLease = nil
        case .workspaceMutation(let workspaceKey):
            guard activeMutationLeases[workspaceKey]?.id == lease.id else { return }
            activeMutationLeases[workspaceKey] = nil
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            activeLocalInferenceOwner: activeLocalInferenceLease?.ownerDescription,
            activeMutationOwnersByWorkspace: activeMutationLeases.mapValues(\.ownerDescription)
        )
    }

    private func acquire(
        resource: Lease.Resource,
        runID: UUID,
        ownerDescription: String
    ) async throws -> Lease {
        while lease(for: resource) != nil {
            try Task.checkCancellation()
            try await Task.sleep(for: pollInterval)
        }

        try Task.checkCancellation()
        let lease = Lease(
            id: UUID(),
            resource: resource,
            runID: runID,
            ownerDescription: ownerDescription,
            acquiredAt: Date()
        )
        install(lease)
        return lease
    }

    private func lease(for resource: Lease.Resource) -> Lease? {
        switch resource {
        case .localInference:
            activeLocalInferenceLease
        case .workspaceMutation(let workspaceKey):
            activeMutationLeases[workspaceKey]
        }
    }

    private func install(_ lease: Lease) {
        switch lease.resource {
        case .localInference:
            activeLocalInferenceLease = lease
        case .workspaceMutation(let workspaceKey):
            activeMutationLeases[workspaceKey] = lease
        }
    }

    private static func workspaceKey(_ workspaceName: String) -> String {
        let trimmed = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "default" : trimmed).lowercased()
    }
}
