import Foundation

public enum ContinuityActivityState: String, Codable, Hashable, Sendable {
    case working
    case paused
    case needsDecision
    case blocked
    case complete
}

public struct ContinuityActivityPresentation: Codable, Hashable, Sendable {
    public let state: ContinuityActivityState
    public let executionMode: ContinuityExecutionMode?
    public let isActivelyExecuting: Bool

    public init(
        state: ContinuityActivityState,
        executionMode: ContinuityExecutionMode?,
        isActivelyExecuting: Bool
    ) {
        self.state = state
        self.executionMode = executionMode
        self.isActivelyExecuting = isActivelyExecuting
    }
}

public enum ContinuityPresentation {
    /// A Live Activity may say “working” only while a structurally valid real execution lease exists.
    public static func activity(for snapshot: ContinuitySnapshot) throws -> ContinuityActivityPresentation {
        try ContinuityReducer.validate(snapshot)
        switch snapshot.state {
        case let .executing(mode):
            return ContinuityActivityPresentation(
                state: .working,
                executionMode: mode,
                isActivelyExecuting: true
            )
        case .ready, .suspended:
            return ContinuityActivityPresentation(
                state: .paused,
                executionMode: nil,
                isActivelyExecuting: false
            )
        case .needsDecision:
            return ContinuityActivityPresentation(
                state: .needsDecision,
                executionMode: nil,
                isActivelyExecuting: false
            )
        case .blocked:
            return ContinuityActivityPresentation(
                state: .blocked,
                executionMode: nil,
                isActivelyExecuting: false
            )
        case .completed:
            return ContinuityActivityPresentation(
                state: .complete,
                executionMode: nil,
                isActivelyExecuting: false
            )
        }
    }
}

public enum ContinuityNotificationEvent: String, Codable, Hashable, Sendable {
    case progressTick
    case routineStageChange
    case decisionNeeded
    case blocked
    case requestedMilestone
    case completed
    case requestedDownloadReady
}

public enum ContinuityNotificationDisposition: String, Codable, Hashable, Sendable {
    case suppress
    case deliver
}

public enum ContinuityNotificationPolicy {
    public static func disposition(for event: ContinuityNotificationEvent) -> ContinuityNotificationDisposition {
        switch event {
        case .progressTick, .routineStageChange:
            .suppress
        case .decisionNeeded, .blocked, .requestedMilestone, .completed, .requestedDownloadReady:
            .deliver
        }
    }
}
