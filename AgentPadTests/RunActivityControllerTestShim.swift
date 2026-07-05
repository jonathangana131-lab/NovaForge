import Foundation

@MainActor
final class RunActivityController {
    static let shared = RunActivityController()

    func runStarted(projectName: String, statusLine: String) {}
    func runProgressed(phase: String, statusLine: String) {}
    func runEnded(statusLine: String, success: Bool) {}
    func syncWidgetSnapshot(projectName: String, statusHeadline: String, journeyPhase: String, proofCount: Int) {}
}
