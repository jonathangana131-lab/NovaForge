import Combine
import Foundation
import SwiftUI
import UIKit
import VoltlineSim

@MainActor
final class GameSession: ObservableObject {
    @Published private(set) var simulationState = SimulationState()
    @Published private(set) var renderSnapshot = RenderSnapshot()

    @Published var bankBalance: Double = 250
    @Published var pendingDriveEarnings: Double = 0
    @Published var lifetimeEarnings: Double = 0
    @Published var odometerMeters: Double = 0
    @Published var tripMeters: Double = 0
    @Published var driveMode: DriveMode = .sport
    @Published var surface: RideSurface = .dryAsphalt
    @Published var camera: RideCamera = .chase
    @Published var showPhone = false
    @Published var showGarage = false
    @Published var selectedPhoneApp: PhoneApp = .home
    @Published var phoneOffset: CGSize = .zero
    @Published var currentToast: GameToast?
    @Published var isPaused = false
    @Published var isCrashed = false
    @Published var controllerName: String?
    @Published var selectedScooterID = ScooterCatalogItem.maxshot.id
    @Published var ownedScooterIDs: Set<String> = [ScooterCatalogItem.maxshot.id]
    @Published var inventoryItemIDs: Set<String> = []
    @Published var installedItemIDs: Set<String> = []
    @Published var orders: [DeliveryOrder] = []
    @Published var deposits: [DepositRecord] = []
    @Published var vescConfiguration = VESCConfiguration()
    @Published var messages: [ChatLine] = []
    @Published var photos: [CapturedPhoto] = []
    @Published var gameSeconds: Double = 0

    @Published var touchThrottle: Double = 0
    @Published var touchBrake: Double = 0
    @Published var touchSteering: Double = 0

    private var simulation = ScooterSimulation(hardware: .joeyMaxshotV1SPro)
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var accumulator: Double = 0
    private var saveAccumulator: Double = 0
    private var lastDistanceMeters: Double = 0
    private var worldX: Double = 0
    private var worldZ: Double = 0
    private var yawRadians: Double = 0
    private var rollRadians: Double = 0
    private var pitchRadians: Double = 0
    private var steeringRadians: Double = 0
    private var cameraYawOffset: Double = 0
    private var cameraPitchOffset: Double = 0
    private var filteredThrottle: Double = 0
    private var crashSeconds: Double = 0
    private var toastTask: Task<Void, Never>?
    private var traffic: [TrafficAgent] = []
    private var scooterRiders: [ScooterRiderAgent] = []

    private let controller = ControllerManager.shared
    private let saveKey = "Voltline.Save.v1"

    init(startLoop: Bool = true) {
        restoreSave()
        rebuildSimulation(preservingState: false)
        buildTraffic()
        installControllerCallbacks()
        applyQALaunchArguments()
        publishRenderSnapshot()
        if startLoop { start() }
    }

    deinit {
        displayLink?.invalidate()
        toastTask?.cancel()
    }

    var selectedScooter: ScooterCatalogItem {
        ScooterCatalogItem.all.first(where: { $0.id == selectedScooterID }) ?? .maxshot
    }

    var speedMPH: Double { simulationState.speedMetersPerSecond * 2.236_936_292_1 }
    var speedKPH: Double { simulationState.speedMetersPerSecond * 3.6 }
    var odometerMiles: Double { odometerMeters / 1_609.344 }
    var tripMiles: Double { tripMeters / 1_609.344 }
    var bankDisplay: String { bankBalance.formatted(.currency(code: "USD").precision(.fractionLength(0))) }
    var pendingDisplay: String { pendingDriveEarnings.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
    var hasVESC: Bool { installedItemIDs.contains("vesc-75-100") }

    var batteryBars: Int {
        let soc = simulationState.batteryStateOfCharge
        switch soc {
        case 0.80...: return 5
        case 0.60..<0.80: return 4
        case 0.40..<0.60: return 3
        case 0.20..<0.40: return 2
        default: return 1
        }
    }

    var isCriticalBatteryVisible: Bool {
        simulationState.batteryStateOfCharge <= 0.08 && Int(gameSeconds * 2).isMultiple(of: 2)
    }

    var deliveredItemIDs: Set<String> {
        Set(orders.filter(\.delivered).map(\.itemID))
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard !isPaused else {
            lastTimestamp = link.timestamp
            return
        }
        guard let lastTimestamp else {
            self.lastTimestamp = link.timestamp
            return
        }
        let frameDelta = min(0.05, max(0, link.timestamp - lastTimestamp))
        self.lastTimestamp = link.timestamp
        advance(frameSeconds: frameDelta)
    }

    func advance(frameSeconds: Double) {
        accumulator += frameSeconds
        let fixedStep = simulation.fixedTimeStep
        var stepCount = 0
        while accumulator >= fixedStep && stepCount < 8 {
            fixedStepUpdate(dt: fixedStep)
            accumulator -= fixedStep
            stepCount += 1
        }
        if stepCount == 8 { accumulator = 0 }
        publishRenderSnapshot()
    }

    func stepForTesting(seconds: Double) {
        let steps = Int((seconds / simulation.fixedTimeStep).rounded(.down))
        for _ in 0..<steps { fixedStepUpdate(dt: simulation.fixedTimeStep) }
        publishRenderSnapshot()
    }

    private func fixedStepUpdate(dt: Double) {
        gameSeconds += dt
        saveAccumulator += dt
        controllerName = controller.snapshot.connectedName

        let controllerInput = controller.snapshot
        let rawThrottle = max(touchThrottle, controllerInput.throttle)
        let rawBrake = max(touchBrake, controllerInput.brake)
        let rawSteering = abs(controllerInput.steering) > abs(touchSteering)
            ? controllerInput.steering
            : touchSteering

        cameraYawOffset = damp(cameraYawOffset, toward: controllerInput.cameraX * 0.50, response: 8, dt: dt)
        cameraPitchOffset = damp(cameraPitchOffset, toward: -controllerInput.cameraY * 0.25, response: 8, dt: dt)

        if isCrashed {
            crashSeconds += dt
            _ = simulation.step(input: SimulationInput(throttle: 0, brake: min(1, 0.25 + crashSeconds * 0.08)))
            rollRadians += 1.9 * dt
            pitchRadians = damp(pitchRadians, toward: -0.55, response: 2.0, dt: dt)
            applyProgression(distanceDelta: max(0, simulation.state.distanceMeters - lastDistanceMeters))
            lastDistanceMeters = simulation.state.distanceMeters
            simulationState = simulation.state
            return
        }

        let speedLimit = driveMode.speedLimitMetersPerSecond
        let limiterWindow = 1.5
        let limiterScale = min(1, max(0, (speedLimit - simulation.state.speedMetersPerSecond) / limiterWindow))
        let throttleCommand = rawThrottle * driveMode.throttleScale * limiterScale

        let ramp = hasVESC ? max(0.08, vescConfiguration.rampSeconds) : 0.42
        let rampResponse = 1 - exp(-dt / ramp)
        filteredThrottle += (throttleCommand - filteredThrottle) * rampResponse
        if hasVESC {
            let exponent = 1 + max(-0.6, min(0.8, vescConfiguration.throttleExpo))
            filteredThrottle = pow(max(0, filteredThrottle), exponent)
        }
        if rawBrake > 0.04 { filteredThrottle = 0 }

        let state = simulation.step(input: SimulationInput(
            throttle: filteredThrottle,
            brake: rawBrake,
            ambientCelsius: ambientTemperatureCelsius
        ))
        simulationState = state

        let speedSteeringScale = 1 / (1 + max(0, state.speedMetersPerSecond - 3) * 0.075)
        let maxSteering = degreesToRadians(31) * speedSteeringScale
        steeringRadians = damp(
            steeringRadians,
            toward: rawSteering * maxSteering,
            response: 11,
            dt: dt
        )

        let wheelbase = selectedScooter.hardware.chassis.wheelbaseMeters
        let yawRate = state.speedMetersPerSecond / max(0.3, wheelbase) * tan(steeringRadians)
        yawRadians += yawRate * dt
        worldX += sin(yawRadians) * state.speedMetersPerSecond * dt
        worldZ += cos(yawRadians) * state.speedMetersPerSecond * dt

        let lateralAcceleration = state.speedMetersPerSecond * yawRate
        let targetRoll = -atan2(lateralAcceleration, 9.80665)
        rollRadians = damp(rollRadians, toward: max(-0.62, min(0.62, targetRoll)), response: 7, dt: dt)
        pitchRadians = damp(
            pitchRadians,
            toward: max(-0.18, min(0.16, -state.accelerationMetersPerSecondSquared * 0.035)),
            response: 9,
            dt: dt
        )

        let gripAcceleration = surface.frictionCoefficient * 9.80665
        if abs(lateralAcceleration) > gripAcceleration * 1.06 && state.speedMetersPerSecond > 3.2 {
            triggerCrash(reason: "The tires exceeded the available \(surface.rawValue.lowercased()) grip.")
        }

        updateTraffic(dt: dt)
        detectTrafficCollisions()

        let distanceDelta = max(0, state.distanceMeters - lastDistanceMeters)
        lastDistanceMeters = state.distanceMeters
        applyProgression(distanceDelta: distanceDelta)

        if saveAccumulator >= 5 {
            saveAccumulator = 0
            save()
        }
    }

    private func applyProgression(distanceDelta: Double) {
        guard distanceDelta > 0 else {
            updateDeliveries()
            return
        }
        odometerMeters += distanceDelta
        tripMeters += distanceDelta

        // $40 per mile makes the first $100 deposit arrive after roughly 2.5 miles.
        let earned = distanceDelta * (40 / 1_609.344)
        pendingDriveEarnings += earned
        lifetimeEarnings += earned

        while pendingDriveEarnings >= 100 {
            pendingDriveEarnings -= 100
            bankBalance += 100
            let deposit = DepositRecord(
                id: UUID(),
                amount: 100,
                odometerMeters: odometerMeters,
                gameSeconds: gameSeconds
            )
            deposits.insert(deposit, at: 0)
            if deposits.count > 24 { deposits.removeLast(deposits.count - 24) }
            showToast(title: "$100 deposited", detail: "Drive earnings reached your next payout.", symbol: "banknote.fill")
        }
        updateDeliveries()
    }

    private func updateDeliveries() {
        for index in orders.indices where !orders[index].delivered {
            if orders[index].progress(currentOdometerMeters: odometerMeters) >= 1 {
                orders[index].delivered = true
                inventoryItemIDs.insert(orders[index].itemID)
                let itemName = StoreItem.catalog.first(where: { $0.id == orders[index].itemID })?.name ?? "Part"
                showToast(title: "Package delivered", detail: "\(itemName) is ready in your garage.", symbol: "shippingbox.fill")
            }
        }
    }

    func cycleDriveMode() {
        let values = DriveMode.allCases
        let index = values.firstIndex(of: driveMode) ?? 0
        driveMode = values[(index + 1) % values.count]
        showToast(title: "Mode \(driveMode.rawValue)", detail: "Speed and throttle limits updated.", symbol: "gauge.with.dots.needle.50percent")
        save()
    }

    func cycleCamera() {
        camera.cycle()
        showToast(title: camera.rawValue, detail: camera == .pov ? "First-person speed FOV enabled." : "Camera changed.", symbol: "camera.fill")
    }

    func togglePhone() {
        showPhone.toggle()
        if showPhone { showGarage = false }
    }

    func toggleGarage() {
        showGarage.toggle()
        if showGarage { showPhone = false }
    }

    func resetRide() {
        isCrashed = false
        crashSeconds = 0
        rollRadians = 0
        pitchRadians = 0
        filteredThrottle = 0
        touchThrottle = 0
        touchBrake = 0
        showToast(title: "Ride reset", detail: "Scooter and rider returned upright.", symbol: "arrow.counterclockwise")
    }

    func resetTrip() {
        tripMeters = 0
        save()
    }

    func triggerCrash(reason: String) {
        guard !isCrashed else { return }
        isCrashed = true
        crashSeconds = 0
        showToast(title: "You went down", detail: reason, symbol: "exclamationmark.triangle.fill")
    }

    func buyScooter(_ scooter: ScooterCatalogItem) {
        guard !ownedScooterIDs.contains(scooter.id) else {
            selectScooter(scooter.id)
            return
        }
        guard bankBalance >= scooter.price else {
            showToast(title: "Not enough money", detail: "Keep driving to build your bank balance.", symbol: "dollarsign.circle")
            return
        }
        bankBalance -= scooter.price
        ownedScooterIDs.insert(scooter.id)
        selectedScooterID = scooter.id
        rebuildSimulation(preservingState: false)
        showToast(title: "New scooter", detail: "\(scooter.name) is now in your garage.", symbol: "scooter")
        save()
    }

    func selectScooter(_ id: String) {
        guard ownedScooterIDs.contains(id), id != selectedScooterID else { return }
        selectedScooterID = id
        tripMeters = 0
        worldX = 0
        worldZ = 0
        yawRadians = 0
        rebuildSimulation(preservingState: false)
        showToast(title: selectedScooter.name, detail: "Hardware profile and dashboard switched.", symbol: "scooter")
        save()
    }

    func purchase(_ item: StoreItem) {
        guard item.compatibleScooterIDs.contains(selectedScooterID) else {
            showToast(title: "Not compatible", detail: "This part does not fit the selected scooter.", symbol: "xmark.octagon.fill")
            return
        }
        guard !orders.contains(where: { $0.itemID == item.id }) && !inventoryItemIDs.contains(item.id) && !installedItemIDs.contains(item.id) else {
            showToast(title: "Already owned", detail: "That part is already ordered or in your garage.", symbol: "checkmark.circle.fill")
            return
        }
        guard bankBalance >= item.price else {
            showToast(title: "Not enough money", detail: "You need \((item.price - bankBalance).formatted(.currency(code: "USD"))) more.", symbol: "dollarsign.circle")
            return
        }
        bankBalance -= item.price
        orders.append(DeliveryOrder(
            id: UUID(),
            itemID: item.id,
            orderedAtOdometerMeters: odometerMeters,
            requiredDistanceMeters: item.deliveryDistanceMeters,
            delivered: false
        ))
        showToast(title: "Order placed", detail: "Delivery progresses while you drive—no fake countdown timer.", symbol: "shippingbox.fill")
        save()
    }

    func installItem(_ itemID: String) {
        guard inventoryItemIDs.contains(itemID) else { return }
        inventoryItemIDs.remove(itemID)
        installedItemIDs.insert(itemID)
        rebuildSimulation(preservingState: true)
        let itemName = StoreItem.catalog.first(where: { $0.id == itemID })?.name ?? "Part"
        showToast(title: "Installed", detail: "\(itemName) is active in the simulation.", symbol: "wrench.and.screwdriver.fill")
        save()
    }

    func applyVESCConfiguration() {
        guard hasVESC else {
            showToast(title: "VESC required", detail: "Install the smart FOC controller before tuning it.", symbol: "lock.fill")
            return
        }
        vescConfiguration.batteryCurrentLimitAmps = min(35, max(5, vescConfiguration.batteryCurrentLimitAmps))
        vescConfiguration.motorCurrentLimitAmps = min(100, max(10, vescConfiguration.motorCurrentLimitAmps))
        vescConfiguration.regenCurrentLimitAmps = min(25, max(0, vescConfiguration.regenCurrentLimitAmps))
        rebuildSimulation(preservingState: true)
        showToast(title: "Configuration written", detail: "Current, ramp and thermal limits now control the simulated hardware.", symbol: "checkmark.seal.fill")
        save()
    }

    func sendMessage(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        messages.append(ChatLine(id: UUID(), sender: .player, text: cleaned))
        let response: ChatLine
        let lower = cleaned.lowercased()
        if lower.contains("battery") || lower.contains("range") {
            response = ChatLine(id: UUID(), sender: .partsBot, text: "Loaded voltage is \(simulationState.batteryVoltage.formatted(.number.precision(.fractionLength(1)))) V and the pack is at \(Int(simulationState.batteryStateOfCharge * 100))%. Heat and voltage sag are simulated live.")
        } else if lower.contains("race") || lower.contains("fast") {
            response = ChatLine(id: UUID(), sender: .ridingCrew, text: "Meet by the tunnel after sunset. Check tire temperature and charge first—wet paint gets sketchy.")
        } else if lower.contains("money") || lower.contains("bank") {
            response = ChatLine(id: UUID(), sender: .max, text: "Drive earnings collect smoothly and deposit in $100 chunks. You have \(pendingDisplay) pending right now.")
        } else {
            response = ChatLine(id: UUID(), sender: .max, text: "I saw that. The map is clear for a few blocks—send it, but keep enough grip to save a slide.")
        }
        messages.append(response)
        if messages.count > 80 { messages.removeFirst(messages.count - 80) }
        save()
    }

    func capturePhoto() {
        let photo = CapturedPhoto(
            id: UUID(),
            title: camera == .pov ? "POV ride" : "Street ride",
            odometerMeters: odometerMeters,
            speedMPH: speedMPH,
            gameSeconds: gameSeconds
        )
        photos.insert(photo, at: 0)
        if photos.count > 30 { photos.removeLast(photos.count - 30) }
        showToast(title: "Photo saved", detail: "Added to the in-game Photos app.", symbol: "camera.fill")
        save()
    }

    func setPhoneOffset(_ offset: CGSize) {
        phoneOffset = CGSize(
            width: min(290, max(-290, offset.width)),
            height: min(120, max(-120, offset.height))
        )
    }

    private var ambientTemperatureCelsius: Double {
        18 + 5 * sin(gameSeconds / 300)
    }

    private func rebuildSimulation(preservingState: Bool) {
        var hardware = selectedScooter.hardware

        if installedItemIDs.contains("maxshot-10s-15ah") {
            hardware.battery.capacityAmpHours = 15
            hardware.battery.maximumDischargeAmps = 35
            hardware.battery.packResistanceOhms = 0.125
        }
        if installedItemIDs.contains("maxshot-500w-hub") {
            hardware.motor.kvRPMPerVolt = 14.5
            hardware.motor.phaseResistanceOhms = 0.40
        }
        if installedItemIDs.contains("vesc-75-100") {
            hardware.controller.batteryCurrentLimitAmps = min(
                hardware.battery.maximumDischargeAmps,
                vescConfiguration.batteryCurrentLimitAmps
            )
            hardware.controller.motorCurrentLimitAmps = vescConfiguration.motorCurrentLimitAmps
            hardware.controller.shutdownCelsius = vescConfiguration.controllerTemperatureCutoffCelsius
            hardware.motor.shutdownCelsius = vescConfiguration.motorTemperatureCutoffCelsius
        }
        if installedItemIDs.contains("street-tire-soft") {
            hardware.chassis.tireFrictionCoefficient = 0.94
            hardware.chassis.rollingResistanceCoefficient *= 1.08
        }

        let oldState = preservingState ? simulation.state : nil
        simulation = ScooterSimulation(hardware: hardware, initialState: oldState)
        simulationState = simulation.state
        lastDistanceMeters = simulation.state.distanceMeters
    }

    private func buildTraffic() {
    var builtTraffic: [TrafficAgent] = []
    builtTraffic.reserveCapacity(10)
    for index in 0..<10 {
        let evenLane = index.isMultiple(of: 2)
        let laneX: Double = evenLane ? -3.4 : 3.4
        let z: Double = Double(index * 34 - 130)
        let speed: Double = Double(7 + index % 4)
        let desiredSpeed: Double = Double(8 + index % 5)
        let direction: Double = evenLane ? 1.0 : -1.0
        let hue: Double = Double(index) / 10.0
        let agent = TrafficAgent(
            id: UUID(),
            laneX: laneX,
            z: z,
            speedMetersPerSecond: speed,
            desiredSpeedMetersPerSecond: desiredSpeed,
            direction: direction,
            bodyHue: hue
        )
        builtTraffic.append(agent)
    }
    traffic = builtTraffic

    var builtRiders: [ScooterRiderAgent] = []
    builtRiders.reserveCapacity(4)
    for index in 0..<4 {
        let evenSide = index.isMultiple(of: 2)
        let x: Double = evenSide ? -5.6 : 5.6
        let z: Double = Double(index * 55 - 80)
        let speed: Double = Double(5 + index)
        let direction: Double = evenSide ? 1.0 : -1.0
        let hue: Double = 0.12 + Double(index) * 0.18
        let rider = ScooterRiderAgent(
            id: UUID(),
            x: x,
            z: z,
            speedMetersPerSecond: speed,
            direction: direction,
            scooterHue: hue
        )
        builtRiders.append(rider)
    }
    scooterRiders = builtRiders
}

private func updateTraffic(dt: Double) {
        for index in traffic.indices {
            var agent = traffic[index]
            let relativeZ = (worldZ - agent.z) * agent.direction
            let sameLane = abs(worldX - agent.laneX) < 2.2
            let playerAhead = relativeZ > 0 && relativeZ < 28 && sameLane
            let target = playerAhead
                ? min(agent.desiredSpeedMetersPerSecond, max(0, simulationState.speedMetersPerSecond - 1.2))
                : agent.desiredSpeedMetersPerSecond
            agent.speedMetersPerSecond = damp(agent.speedMetersPerSecond, toward: target, response: playerAhead ? 3.5 : 0.6, dt: dt)
            agent.z += agent.direction * agent.speedMetersPerSecond * dt
            if agent.z > worldZ + 190 { agent.z = worldZ - 190 }
            if agent.z < worldZ - 190 { agent.z = worldZ + 190 }
            traffic[index] = agent
        }

        for index in scooterRiders.indices {
            scooterRiders[index].z += scooterRiders[index].direction * scooterRiders[index].speedMetersPerSecond * dt
            if scooterRiders[index].z > worldZ + 150 { scooterRiders[index].z = worldZ - 150 }
            if scooterRiders[index].z < worldZ - 150 { scooterRiders[index].z = worldZ + 150 }
        }
    }

    private func detectTrafficCollisions() {
        guard simulationState.speedMetersPerSecond > 1 else { return }
        for agent in traffic {
            let dx = agent.laneX - worldX
            let dz = agent.z - worldZ
            if abs(dx) < 1.25 && abs(dz) < 2.2 {
                triggerCrash(reason: "You collided with traffic at \(speedMPH.formatted(.number.precision(.fractionLength(0)))) mph.")
                return
            }
        }
        for rider in scooterRiders {
            let dx = rider.x - worldX
            let dz = rider.z - worldZ
            if abs(dx) < 0.9 && abs(dz) < 1.4 {
                triggerCrash(reason: "You clipped another scooter rider.")
                return
            }
        }
    }

    private func publishRenderSnapshot() {
        renderSnapshot = RenderSnapshot(
            playerX: worldX,
            playerZ: worldZ,
            yawRadians: yawRadians,
            rollRadians: rollRadians,
            pitchRadians: pitchRadians,
            steeringRadians: steeringRadians,
            speedMetersPerSecond: simulationState.speedMetersPerSecond,
            camera: camera,
            cameraYawOffset: cameraYawOffset,
            cameraPitchOffset: cameraPitchOffset,
            crashed: isCrashed,
            crashSeconds: crashSeconds,
            traffic: traffic,
            scooterRiders: scooterRiders
        )
    }

    private func installControllerCallbacks() {
        controller.onCycleCamera = { [weak self] in self?.cycleCamera() }
        controller.onResetRide = { [weak self] in self?.resetRide() }
        controller.onTogglePhone = { [weak self] in self?.togglePhone() }
        controller.onToggleGarage = { [weak self] in self?.toggleGarage() }
        controller.onCycleDriveMode = { [weak self] in self?.cycleDriveMode() }
        controller.onHorn = { [weak self] in
            self?.showToast(title: "Horn", detail: "Nearby traffic has been alerted.", symbol: "speaker.wave.3.fill")
        }
    }

    private func showToast(title: String, detail: String, symbol: String) {
        toastTask?.cancel()
        let toast = GameToast(title: title, detail: detail, symbol: symbol)
        currentToast = toast
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled, self?.currentToast?.id == toast.id else { return }
            self?.currentToast = nil
        }
    }

    private func save() {
        let save = VoltlineSave(
            bankBalance: bankBalance,
            pendingDriveEarnings: pendingDriveEarnings,
            lifetimeEarnings: lifetimeEarnings,
            selectedScooterID: selectedScooterID,
            ownedScooterIDs: ownedScooterIDs,
            installedItemIDs: installedItemIDs,
            inventoryItemIDs: inventoryItemIDs,
            orders: orders,
            deposits: deposits,
            odometerMeters: odometerMeters,
            tripMeters: tripMeters,
            driveMode: driveMode,
            surface: surface,
            vescConfiguration: vescConfiguration,
            photos: photos,
            messages: messages
        )
        guard let data = try? JSONEncoder().encode(save) else { return }
        UserDefaults.standard.set(data, forKey: saveKey)
    }

    private func restoreSave() {
        guard let data = UserDefaults.standard.data(forKey: saveKey),
              let save = try? JSONDecoder().decode(VoltlineSave.self, from: data) else {
            messages = [
                ChatLine(id: UUID(), sender: .max, text: "Your Maxshot is charged. Drive earnings deposit every $100."),
                ChatLine(id: UUID(), sender: .ridingCrew, text: "The tunnel route is open. Watch the painted lines if it gets wet.")
            ]
            return
        }
        bankBalance = save.bankBalance
        pendingDriveEarnings = save.pendingDriveEarnings
        lifetimeEarnings = save.lifetimeEarnings
        selectedScooterID = save.selectedScooterID
        ownedScooterIDs = save.ownedScooterIDs
        installedItemIDs = save.installedItemIDs
        inventoryItemIDs = save.inventoryItemIDs
        orders = save.orders
        deposits = save.deposits
        odometerMeters = save.odometerMeters
        tripMeters = save.tripMeters
        driveMode = save.driveMode
        surface = save.surface
        vescConfiguration = save.vescConfiguration
        photos = save.photos
        messages = save.messages
    }

    private func applyQALaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--qa-rich") { bankBalance = 9_500 }
        if arguments.contains("--qa-garage") { showGarage = true }
        if arguments.contains("--qa-phone") { showPhone = true; selectedPhoneApp = .home }
        if arguments.contains("--qa-bank") { showPhone = true; selectedPhoneApp = .bank }
        if arguments.contains("--qa-vesc") {
            bankBalance = max(bankBalance, 9_500)
            installedItemIDs.insert("vesc-75-100")
            showPhone = true
            selectedPhoneApp = .vesc
            rebuildSimulation(preservingState: true)
        }
        if arguments.contains("--qa-crash") { triggerCrash(reason: "QA crash fixture") }
    }

    private func damp(_ current: Double, toward target: Double, response: Double, dt: Double) -> Double {
        current + (target - current) * (1 - exp(-response * dt))
    }

    private func degreesToRadians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
