import Foundation

public enum ContinuityActivityState: String, Codable, Hashable, Sendable { case working, paused, needsDecision, blocked, complete }
public struct ContinuityActivityPresentation: Codable, Hashable, Sendable {
    public let state: ContinuityActivityState
    public let executionMode: ContinuityExecutionMode?
    public let isActivelyExecuting: Bool
}

public enum ContinuityPresentation {
    public static func activity(for snapshot: ContinuitySnapshot) throws -> ContinuityActivityPresentation {
        try ContinuityReducer.validate(snapshot)
        return switch snapshot.state {
        case let .executing(mode): .init(state: .working, executionMode: mode, isActivelyExecuting: true)
        case .ready, .suspended: .init(state: .paused, executionMode: nil, isActivelyExecuting: false)
        case .needsDecision: .init(state: .needsDecision, executionMode: nil, isActivelyExecuting: false)
        case .blocked: .init(state: .blocked, executionMode: nil, isActivelyExecuting: false)
        case .completed: .init(state: .complete, executionMode: nil, isActivelyExecuting: false)
        }
    }
}

public enum ContinuityNotificationEvent: String, Codable, Hashable, Sendable { case progressTick, routineStageChange, decisionNeeded, blocked, requestedMilestone, completed, requestedDownloadReady }
public enum ContinuityNotificationDisposition: String, Codable, Hashable, Sendable { case suppress, deliver }
public enum ContinuityNotificationPolicy {
    public static func disposition(for event: ContinuityNotificationEvent) -> ContinuityNotificationDisposition {
        switch event {
        case .progressTick, .routineStageChange: .suppress
        case .decisionNeeded, .blocked, .requestedMilestone, .completed, .requestedDownloadReady: .deliver
        }
    }
}
