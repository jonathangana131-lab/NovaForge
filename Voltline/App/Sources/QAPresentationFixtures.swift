import Foundation

@MainActor
extension GameSession {
    /// Re-applies only presentation state for deterministic simulator fixtures.
    /// Normal player launches are unchanged because this is a no-op unless an
    /// explicit --qa-* launch argument is present.
    func applyQAPresentationFixture() {
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("--qa-garage") {
            showPhone = false
            showGarage = true
            isPaused = true
            releaseQATouchControls()
            return
        }

        if arguments.contains("--qa-bank") {
            showGarage = false
            selectedPhoneApp = .bank
            showPhone = true
            isPaused = true
            releaseQATouchControls()
            return
        }

        if arguments.contains("--qa-vesc") {
            showGarage = false
            selectedPhoneApp = .vesc
            showPhone = true
            isPaused = true
            releaseQATouchControls()
        }
    }

    private func releaseQATouchControls() {
        touchThrottle = 0
        touchBrake = 0
        touchSteering = 0
    }
}
