import Foundation

@MainActor
extension GameSession {
    /// Re-applies only presentation state for deterministic simulator fixtures.
    /// Normal player launches are unchanged because this is a no-op unless an
    /// explicit --qa-* launch argument is present.
    func applyQAPresentationFixture() {
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("--qa-cockpit-maxshot") {
            prepareCockpitFixture(scooterID: ScooterCatalogItem.maxshot.id, mode: .eco)
            return
        }

        if arguments.contains("--qa-cockpit-kukirin") {
            prepareCockpitFixture(scooterID: ScooterCatalogItem.kukirin.id, mode: .sport)
            return
        }

        if arguments.contains("--qa-cockpit-dualtron") {
            prepareCockpitFixture(scooterID: ScooterCatalogItem.dualtron.id, mode: .sport)
            return
        }

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

    private func prepareCockpitFixture(scooterID: String, mode: DriveMode) {
        ownedScooterIDs.insert(scooterID)
        selectedScooterID = scooterID
        driveMode = mode
        camera = .pov
        showPhone = false
        showGarage = false
        isPaused = false
        releaseQATouchControls()
    }

    private func releaseQATouchControls() {
        touchThrottle = 0
        touchBrake = 0
        touchSteering = 0
    }
}
