import Foundation
import GameController

@MainActor
final class ControllerManager: ObservableObject {
    static let shared = ControllerManager()

    struct Snapshot: Equatable {
        var throttle: Double = 0
        var brake: Double = 0
        var steering: Double = 0
        var cameraX: Double = 0
        var cameraY: Double = 0
        var connectedName: String?
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var isConnected = false

    var onCycleCamera: (() -> Void)?
    var onResetRide: (() -> Void)?
    var onTogglePhone: (() -> Void)?
    var onToggleGarage: (() -> Void)?
    var onCycleDriveMode: (() -> Void)?
    var onHorn: (() -> Void)?

    private var controller: GCController?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.attach(controller) }
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.detach(controller) }
        })

        if let existing = GCController.controllers().first {
            attach(existing)
        } else {
            GCController.startWirelessControllerDiscovery(completionHandler: nil)
        }
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func attach(_ controller: GCController) {
        self.controller = controller
        isConnected = true
        snapshot.connectedName = controller.vendorName ?? "Game Controller"
        controller.playerIndex = .index1

        if let gamepad = controller.extendedGamepad {
            gamepad.valueChangedHandler = { [weak self] pad, _ in
                let next = Snapshot(
                    throttle: Double(pad.rightTrigger.value),
                    brake: Double(pad.leftTrigger.value),
                    steering: Double(pad.leftThumbstick.xAxis.value),
                    cameraX: Double(pad.rightThumbstick.xAxis.value),
                    cameraY: Double(pad.rightThumbstick.yAxis.value),
                    connectedName: controller.vendorName ?? "Game Controller"
                )
                Task { @MainActor in self?.snapshot = next }
            }

            gamepad.rightThumbstickButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.onCycleCamera?() }
            }
            gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.onCycleDriveMode?() }
            }
            gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.onResetRide?() }
            }
            gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.onHorn?() }
            }
            gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.onTogglePhone?() }
            }
            gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.onToggleGarage?() }
            }
            gamepad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                Task { @MainActor in self?.onCycleCamera?() }
            }
        }

        controller.controllerPausedHandler = { [weak self] _ in
            Task { @MainActor in self?.onToggleGarage?() }
        }
    }

    private func detach(_ disconnected: GCController) {
        guard controller === disconnected else { return }
        controller = nil
        isConnected = false
        snapshot = Snapshot()
    }
}
