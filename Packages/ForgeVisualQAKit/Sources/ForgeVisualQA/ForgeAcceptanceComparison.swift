import Foundation

public enum VisualAcceptanceComparisonMismatch: Equatable, Sendable {
    case differentProject
    case differentViewport
    case differentAccessibilityState
    case differentExecutionEnvironment
}

public enum VisualAcceptanceComparisonVerdict: Equatable, Sendable {
    case comparable
    case notComparable(VisualAcceptanceComparisonMismatch)
}

public enum VisualAcceptanceEvidenceComparator {
    public static func compare(
        baseline: VisualPerformanceReceipt,
        candidate: VisualPerformanceReceipt
    ) -> VisualAcceptanceComparisonVerdict {
        guard baseline.capture.project.projectID == candidate.capture.project.projectID else {
            return .notComparable(.differentProject)
        }
        guard baseline.capture.viewport == candidate.capture.viewport else {
            return .notComparable(.differentViewport)
        }
        guard baseline.capture.accessibility == candidate.capture.accessibility else {
            return .notComparable(.differentAccessibilityState)
        }
        guard baseline.environment == candidate.environment else {
            return .notComparable(.differentExecutionEnvironment)
        }
        return .comparable
    }
}
