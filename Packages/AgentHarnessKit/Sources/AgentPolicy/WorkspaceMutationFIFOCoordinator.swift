import AgentDomain
import Foundation

public enum WorkspaceMutationFIFOError: Error, Equatable, Sendable {
    case invalidLease
}

/// Move-only ownership of one workspace's mutation lane. The holder must
/// consume it through `WorkspaceMutationFIFOCoordinator.release(_:)`.
public struct WorkspaceMutationQueueLease: ~Copyable, Sendable {
    public let workspaceID: WorkspaceID

    fileprivate let coordinatorID: UUID
    fileprivate let tokenID: UUID

    fileprivate init(
        workspaceID: WorkspaceID,
        coordinatorID: UUID,
        tokenID: UUID
    ) {
        self.workspaceID = workspaceID
        self.coordinatorID = coordinatorID
        self.tokenID = tokenID
    }
}

public struct WorkspaceMutationFIFOStatus: Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let isActive: Bool
    public let waitingCount: Int

    public init(
        workspaceID: WorkspaceID,
        isActive: Bool,
        waitingCount: Int
    ) {
        self.workspaceID = workspaceID
        self.isActive = isActive
        self.waitingCount = waitingCount
    }
}

/// Strict FIFO within a workspace, while independent workspace lanes proceed
/// concurrently. Cancellation removes queued waiters and safely advances a
/// grant that was issued but not yet handed to its caller.
public actor WorkspaceMutationFIFOCoordinator {
    private struct GrantedToken: Sendable {
        let workspaceID: WorkspaceID
        let tokenID: UUID
    }

    private struct Waiter {
        let tokenID: UUID
        let continuation: CheckedContinuation<GrantedToken, any Error>
    }

    private enum GrantStatus {
        case provisional
        case handedOff
    }

    private struct ActiveGrant {
        let tokenID: UUID
        var status: GrantStatus
    }

    private struct Lane {
        var active: ActiveGrant?
        var waiters: [Waiter]

        init(active: ActiveGrant? = nil, waiters: [Waiter] = []) {
            self.active = active
            self.waiters = waiters
        }
    }

    private let coordinatorID = UUID()
    private var lanes: [WorkspaceID: Lane] = [:]

    public init() {}

    public func acquire(
        workspaceID: WorkspaceID
    ) async throws -> WorkspaceMutationQueueLease {
        let tokenID = UUID()
        let token: GrantedToken = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                continuation in
                enqueue(
                    workspaceID: workspaceID,
                    tokenID: tokenID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancel(workspaceID: workspaceID, tokenID: tokenID) }
        }
        return try finalize(token)
    }

    public func release(
        _ lease: consuming WorkspaceMutationQueueLease
    ) throws {
        guard lease.coordinatorID == coordinatorID,
              var lane = lanes[lease.workspaceID],
              let active = lane.active,
              active.tokenID == lease.tokenID,
              active.status == .handedOff
        else { throw WorkspaceMutationFIFOError.invalidLease }
        lane.active = nil
        lanes[lease.workspaceID] = lane
        grantNext(workspaceID: lease.workspaceID)
        removeLaneIfIdle(workspaceID: lease.workspaceID)
    }

    public func status(
        workspaceID: WorkspaceID
    ) -> WorkspaceMutationFIFOStatus {
        let lane = lanes[workspaceID]
        return WorkspaceMutationFIFOStatus(
            workspaceID: workspaceID,
            isActive: lane?.active != nil,
            waitingCount: lane?.waiters.count ?? 0
        )
    }

    private func enqueue(
        workspaceID: WorkspaceID,
        tokenID: UUID,
        continuation: CheckedContinuation<GrantedToken, any Error>
    ) {
        var lane = lanes[workspaceID] ?? Lane()
        if lane.active == nil {
            lane.active = ActiveGrant(
                tokenID: tokenID,
                status: .provisional
            )
            lanes[workspaceID] = lane
            continuation.resume(returning: GrantedToken(
                workspaceID: workspaceID,
                tokenID: tokenID
            ))
        } else {
            lane.waiters.append(Waiter(
                tokenID: tokenID,
                continuation: continuation
            ))
            lanes[workspaceID] = lane
        }
    }

    private func finalize(
        _ token: GrantedToken
    ) throws -> WorkspaceMutationQueueLease {
        guard !Task.isCancelled,
              var lane = lanes[token.workspaceID],
              let active = lane.active,
              active.tokenID == token.tokenID,
              active.status == .provisional
        else {
            cancel(workspaceID: token.workspaceID, tokenID: token.tokenID)
            throw CancellationError()
        }
        lane.active?.status = .handedOff
        lanes[token.workspaceID] = lane
        return WorkspaceMutationQueueLease(
            workspaceID: token.workspaceID,
            coordinatorID: coordinatorID,
            tokenID: token.tokenID
        )
    }

    private func cancel(workspaceID: WorkspaceID, tokenID: UUID) {
        guard var lane = lanes[workspaceID] else { return }
        if let active = lane.active,
           active.tokenID == tokenID {
            // Once handed off, ownership belongs to the caller. Releasing it
            // here would make a concurrently returned lease invalid.
            guard active.status == .provisional else { return }
            lane.active = nil
            lanes[workspaceID] = lane
            grantNext(workspaceID: workspaceID)
            removeLaneIfIdle(workspaceID: workspaceID)
            return
        }
        guard let index = lane.waiters.firstIndex(where: {
            $0.tokenID == tokenID
        }) else { return }
        let waiter = lane.waiters.remove(at: index)
        lanes[workspaceID] = lane
        waiter.continuation.resume(throwing: CancellationError())
        removeLaneIfIdle(workspaceID: workspaceID)
    }

    private func grantNext(workspaceID: WorkspaceID) {
        guard var lane = lanes[workspaceID],
              lane.active == nil,
              !lane.waiters.isEmpty
        else { return }
        let waiter = lane.waiters.removeFirst()
        lane.active = ActiveGrant(
            tokenID: waiter.tokenID,
            status: .provisional
        )
        lanes[workspaceID] = lane
        waiter.continuation.resume(returning: GrantedToken(
            workspaceID: workspaceID,
            tokenID: waiter.tokenID
        ))
    }

    private func removeLaneIfIdle(workspaceID: WorkspaceID) {
        guard let lane = lanes[workspaceID],
              lane.active == nil,
              lane.waiters.isEmpty
        else { return }
        lanes[workspaceID] = nil
    }
}
