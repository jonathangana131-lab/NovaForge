import RealityKit
import SwiftUI
import UIKit

struct GameWorldView: View {
    @ObservedObject var session: GameSession
    @StateObject private var renderer = WorldRenderer()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.025, green: 0.08, blue: 0.14), Color(red: 0.0, green: 0.015, blue: 0.035)],
                startPoint: .top,
                endPoint: .bottom
            )

            RealityView { content in
                renderer.configure(content: &content)
            } update: { content in
                renderer.apply(session.renderSnapshot, selectedScooter: session.selectedScooter)
            } placeholder: {
                ZStack {
                    Color.black
                    ProgressView("Building Voltline world…")
                        .tint(.cyan)
                        .foregroundStyle(.white)
                }
            }
        }
        .ignoresSafeArea()
    }
}

@MainActor
final class WorldRenderer: ObservableObject {
    private let sceneRoot = Entity()
    private let worldRoot = Entity()
    private let scooterRoot = Entity()
    private let riderRoot = Entity()
    private let cameraEntity = Entity()
    private let handlebarRoot = Entity()
    private let frontWheelRoot = Entity()
    private let rearWheelRoot = Entity()
    private var trafficEntities: [UUID: Entity] = [:]
    private var scooterRiderEntities: [UUID: Entity] = [:]
    private var configured = false
    private var renderedScooterID = ""

    func configure(content: inout RealityViewCameraContent) {
        guard !configured else { return }
        configured = true
        content.camera = .virtual
        sceneRoot.name = "VoltlineScene"
        worldRoot.name = "World"
        scooterRoot.name = "PlayerScooter"
        riderRoot.name = "Rider"
        cameraEntity.name = "GameCamera"

        sceneRoot.addChild(worldRoot)
        sceneRoot.addChild(scooterRoot)
        sceneRoot.addChild(cameraEntity)
        content.add(sceneRoot)

        cameraEntity.components.set(PerspectiveCameraComponent(
            near: 0.025,
            far: 700,
            fieldOfViewInDegrees: 72
        ))

        buildLighting()
        buildEnvironment()
        buildScooter(for: .maxshot)
    }

    func apply(_ snapshot: RenderSnapshot, selectedScooter: ScooterCatalogItem) {
        guard configured else { return }
        if renderedScooterID != selectedScooter.id {
            buildScooter(for: selectedScooter)
        }

        let x = Float(snapshot.playerX)
        let z = Float(snapshot.playerZ)
        let yaw = Float(snapshot.yawRadians)
        let roll = Float(snapshot.rollRadians)
        let pitch = Float(snapshot.pitchRadians)

        scooterRoot.position = SIMD3<Float>(x, 0.13, z)
        scooterRoot.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
            * simd_quatf(angle: roll, axis: [0, 0, 1])

        handlebarRoot.orientation = simd_quatf(angle: Float(snapshot.steeringRadians), axis: [0, 1, 0])
        let wheelRotation = Float((snapshot.playerZ + snapshot.playerX) / max(0.08, selectedScooter.hardware.chassis.wheelRadiusMeters))
        frontWheelRoot.orientation = simd_quatf(angle: wheelRotation, axis: [1, 0, 0])
        rearWheelRoot.orientation = simd_quatf(angle: wheelRotation, axis: [1, 0, 0])

        applyRiderPose(snapshot)
        syncTraffic(snapshot.traffic)
        syncScooterRiders(snapshot.scooterRiders)
        updateCamera(snapshot)
    }

    private func buildLighting() {
        let moon = DirectionalLight()
        moon.name = "Moon"
        moon.light.color = UIColor(red: 0.65, green: 0.78, blue: 1.0, alpha: 1)
        moon.light.intensity = 18_000
        moon.orientation = simd_quatf(angle: -.pi / 3.2, axis: [1, 0.25, 0])
        sceneRoot.addChild(moon)

        let fill = PointLight()
        fill.light.color = UIColor(red: 0.15, green: 0.72, blue: 1.0, alpha: 1)
        fill.light.intensity = 4_500
        fill.light.attenuationRadius = 28
        fill.position = [0, 8, -8]
        sceneRoot.addChild(fill)
    }

    private func buildEnvironment() {
        let asphalt = material(.init(red: 0.055, green: 0.065, blue: 0.078, alpha: 1), roughness: 0.92)
        let concrete = material(.init(red: 0.28, green: 0.30, blue: 0.32, alpha: 1), roughness: 0.88)
        let lane = material(.init(white: 0.9, alpha: 1), roughness: 0.6)
        let dark = material(.init(red: 0.04, green: 0.045, blue: 0.06, alpha: 1), roughness: 0.76)
        let glass = material(.init(red: 0.06, green: 0.28, blue: 0.40, alpha: 1), roughness: 0.18, metallic: true)

        worldRoot.addChild(box(width: 18, height: 0.12, depth: 800, color: asphalt, position: [0, -0.08, 0]))
        worldRoot.addChild(box(width: 5.5, height: 0.22, depth: 800, color: concrete, position: [-11.75, 0, 0]))
        worldRoot.addChild(box(width: 5.5, height: 0.22, depth: 800, color: concrete, position: [11.75, 0, 0]))

        for index in -34...34 {
            let z = Float(index) * 12
            worldRoot.addChild(box(width: 0.18, height: 0.025, depth: 5.4, color: lane, position: [0, 0.002, z]))
        }

        for side in [-1.0 as Float, 1.0 as Float] {
            for index in -16...16 {
                let z = Float(index) * 23
                let width = Float(7 + abs(index % 4))
                let height = Float(8 + abs((index * 7) % 16))
                let building = box(
                    width: width,
                    height: height,
                    depth: 13,
                    color: dark,
                    position: [side * (18 + width * 0.5), height * 0.5, z]
                )
                worldRoot.addChild(building)

                for floor in stride(from: 2.5 as Float, to: height - 1, by: 3.2) {
                    let windows = box(
                        width: width * 0.72,
                        height: 0.55,
                        depth: 0.06,
                        color: glass,
                        position: [side * (18 + width * 0.5 - side * (width * 0.5 + 0.04)), floor, z]
                    )
                    worldRoot.addChild(windows)
                }
            }
        }

        for side in [-1.0 as Float, 1.0 as Float] {
            for index in -22...22 {
                let z = Float(index) * 17.5
                let pole = box(width: 0.08, height: 4.8, depth: 0.08, color: concrete, position: [side * 8.7, 2.4, z])
                worldRoot.addChild(pole)
                let lamp = ModelEntity(mesh: .generateSphere(radius: 0.12), materials: [material(.init(red: 0.72, green: 0.88, blue: 1, alpha: 1), roughness: 0.1)])
                lamp.position = [side * 8.35, 4.72, z]
                worldRoot.addChild(lamp)
            }
        }

        // Tunnel portal and slalom area give the first map memorable landmarks.
        let tunnel = box(width: 17, height: 7.5, depth: 18, color: dark, position: [0, 3.75, 125])
        worldRoot.addChild(tunnel)
        let tunnelCut = box(width: 13.5, height: 5.6, depth: 19, color: asphalt, position: [0, 2.7, 125])
        worldRoot.addChild(tunnelCut)

        let coneMaterial = material(.init(red: 1.0, green: 0.35, blue: 0.04, alpha: 1), roughness: 0.7)
        for index in 0..<12 {
            let cone = ModelEntity(mesh: .generateCone(height: 0.65, radius: 0.22), materials: [coneMaterial])
            cone.position = [Float(index.isMultiple(of: 2) ? -2.6 : 2.6), 0.32, Float(-45 + index * 7)]
            worldRoot.addChild(cone)
        }
    }

    private func buildScooter(for scooter: ScooterCatalogItem) {
        renderedScooterID = scooter.id
        scooterRoot.children.removeAll()
        handlebarRoot.children.removeAll()
        riderRoot.children.removeAll()
        frontWheelRoot.children.removeAll()
        rearWheelRoot.children.removeAll()

        let wheelRadius = Float(scooter.hardware.chassis.wheelRadiusMeters)
        let wheelbase = Float(scooter.hardware.chassis.wheelbaseMeters)
        let half = wheelbase * 0.5
        let frame = material(.init(red: 0.025, green: 0.03, blue: 0.04, alpha: 1), roughness: 0.58, metallic: true)
        let rubber = material(.init(white: 0.018, alpha: 1), roughness: 1)
        let metal = material(.init(white: 0.48, alpha: 1), roughness: 0.28, metallic: true)
        let accentColor: UIColor = scooter.id == ScooterCatalogItem.maxshot.id
            ? .init(red: 0.04, green: 0.76, blue: 0.98, alpha: 1)
            : scooter.id == ScooterCatalogItem.kukirin.id
                ? .init(red: 0.95, green: 0.58, blue: 0.04, alpha: 1)
                : .init(red: 0.25, green: 0.88, blue: 0.50, alpha: 1)
        let accent = material(accentColor, roughness: 0.35, metallic: true)

        let deckLength = min(0.80 as Float, max(0.58, wheelbase * 0.58))
        let deckWidth: Float = scooter.id == ScooterCatalogItem.maxshot.id ? 0.19 : 0.26
        let deck = box(width: deckWidth, height: 0.095, depth: deckLength, color: frame, position: [0, wheelRadius + 0.02, -0.03])
        scooterRoot.addChild(deck)
        let deckAccent = box(width: deckWidth * 0.92, height: 0.012, depth: deckLength * 0.78, color: accent, position: [0, wheelRadius + 0.074, -0.03])
        scooterRoot.addChild(deckAccent)

        addWheel(to: frontWheelRoot, radius: wheelRadius, rubber: rubber, metal: metal, powered: scooter.hardware.drivenWheel != .rear, accent: accent)
        addWheel(to: rearWheelRoot, radius: wheelRadius, rubber: rubber, metal: metal, powered: scooter.hardware.drivenWheel != .front, accent: accent)
        frontWheelRoot.position = [0, wheelRadius, half]
        rearWheelRoot.position = [0, wheelRadius, -half]
        scooterRoot.addChild(frontWheelRoot)
        scooterRoot.addChild(rearWheelRoot)

        let stemHeight: Float = scooter.id == ScooterCatalogItem.maxshot.id ? 1.03 : 1.10
        let stem = box(width: 0.055, height: stemHeight, depth: 0.065, color: frame, position: [0, wheelRadius + stemHeight * 0.5, half - 0.08])
        stem.orientation = simd_quatf(angle: -0.10, axis: [1, 0, 0])
        scooterRoot.addChild(stem)

        let neck = box(width: 0.13, height: 0.10, depth: 0.15, color: accent, position: [0, wheelRadius + 0.13, half - 0.10])
        scooterRoot.addChild(neck)

        handlebarRoot.position = [0, wheelRadius + stemHeight, half - 0.18]
        let bar = box(width: 0.62, height: 0.035, depth: 0.035, color: metal, position: .zero)
        handlebarRoot.addChild(bar)
        handlebarRoot.addChild(box(width: 0.13, height: 0.055, depth: 0.055, color: rubber, position: [-0.30, 0, 0]))
        handlebarRoot.addChild(box(width: 0.13, height: 0.055, depth: 0.055, color: rubber, position: [0.30, 0, 0]))
        handlebarRoot.addChild(box(width: 0.13, height: 0.055, depth: 0.10, color: frame, position: [0, -0.025, -0.025]))
        handlebarRoot.addChild(box(width: 0.052, height: 0.025, depth: 0.065, color: accent, position: [0.22, -0.045, 0.01]))
        scooterRoot.addChild(handlebarRoot)

        if scooter.id == ScooterCatalogItem.maxshot.id {
            for x in [-0.075 as Float, 0.075 as Float] {
                scooterRoot.addChild(box(width: 0.026, height: 0.38, depth: 0.026, color: accent, position: [x, wheelRadius + 0.18, half - 0.03]))
                scooterRoot.addChild(box(width: 0.026, height: 0.28, depth: 0.026, color: accent, position: [x, wheelRadius + 0.14, -half + 0.04]))
            }
        }

        buildRider(frame: frame, accent: accent)
        scooterRoot.addChild(riderRoot)
    }

    private func addWheel(to root: Entity, radius: Float, rubber: Material, metal: Material, powered: Bool, accent: Material) {
        let tire = ModelEntity(mesh: .generateCylinder(height: 0.075, radius: radius), materials: [rubber])
        tire.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        root.addChild(tire)
        let hubRadius = powered ? radius * 0.47 : radius * 0.27
        let hub = ModelEntity(mesh: .generateCylinder(height: 0.082, radius: hubRadius), materials: [powered ? accent : metal])
        hub.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        root.addChild(hub)
    }

    private func buildRider(frame: Material, accent: Material) {
        let skin = material(.init(red: 0.55, green: 0.34, blue: 0.24, alpha: 1), roughness: 0.84)
        let shirt = material(.init(red: 0.08, green: 0.16, blue: 0.27, alpha: 1), roughness: 0.82)
        let pants = material(.init(red: 0.035, green: 0.045, blue: 0.07, alpha: 1), roughness: 0.9)

        riderRoot.addChild(box(width: 0.31, height: 0.46, depth: 0.19, color: shirt, position: [0, 1.20, -0.04]))
        let head = ModelEntity(mesh: .generateSphere(radius: 0.13), materials: [skin])
        head.position = [0, 1.56, 0.05]
        riderRoot.addChild(head)

        riderRoot.addChild(limb(from: [-0.11, 1.05, -0.03], to: [-0.10, 0.63, -0.17], radius: 0.055, material: pants))
        riderRoot.addChild(limb(from: [0.11, 1.05, -0.03], to: [0.10, 0.63, 0.17], radius: 0.055, material: pants))
        riderRoot.addChild(limb(from: [-0.13, 1.37, 0.01], to: [-0.29, 1.19, 0.40], radius: 0.045, material: shirt))
        riderRoot.addChild(limb(from: [0.13, 1.37, 0.01], to: [0.29, 1.19, 0.40], radius: 0.045, material: shirt))

        let leftHand = ModelEntity(mesh: .generateSphere(radius: 0.055), materials: [skin])
        leftHand.position = [-0.29, 1.18, 0.40]
        riderRoot.addChild(leftHand)
        let rightHand = ModelEntity(mesh: .generateSphere(radius: 0.055), materials: [skin])
        rightHand.position = [0.29, 1.18, 0.40]
        riderRoot.addChild(rightHand)

        // Helmet makes the first rider readable at mobile resolution.
        let helmet = ModelEntity(mesh: .generateSphere(radius: 0.139), materials: [accent])
        helmet.position = [0, 1.585, 0.04]
        helmet.scale = [1.02, 0.68, 1.03]
        riderRoot.addChild(helmet)
    }

    private func applyRiderPose(_ snapshot: RenderSnapshot) {
        if snapshot.crashed {
            riderRoot.position = [Float(snapshot.crashSeconds * 1.15), max(0.10, 0.62 - Float(snapshot.crashSeconds * 0.32)), -Float(snapshot.crashSeconds * 0.75)]
            riderRoot.orientation = simd_quatf(angle: Float(snapshot.crashSeconds * 2.3), axis: [0.55, 0.18, 0.82])
        } else {
            riderRoot.position = .zero
            let counterLean = Float(snapshot.rollRadians * -0.30)
            riderRoot.orientation = simd_quatf(angle: counterLean, axis: [0, 0, 1])
        }
    }

    private func syncTraffic(_ agents: [TrafficAgent]) {
        let ids = Set(agents.map(\.id))
        for (id, entity) in trafficEntities where !ids.contains(id) {
            entity.removeFromParent()
            trafficEntities.removeValue(forKey: id)
        }
        for agent in agents {
            let entity: Entity
            if let existing = trafficEntities[agent.id] {
                entity = existing
            } else {
                entity = buildTrafficCar(hue: agent.bodyHue)
                worldRoot.addChild(entity)
                trafficEntities[agent.id] = entity
            }
            entity.position = [Float(agent.laneX), 0.34, Float(agent.z)]
            entity.orientation = simd_quatf(angle: agent.direction > 0 ? 0 : .pi, axis: [0, 1, 0])
        }
    }

    private func syncScooterRiders(_ riders: [ScooterRiderAgent]) {
        let ids = Set(riders.map(\.id))
        for (id, entity) in scooterRiderEntities where !ids.contains(id) {
            entity.removeFromParent()
            scooterRiderEntities.removeValue(forKey: id)
        }
        for rider in riders {
            let entity: Entity
            if let existing = scooterRiderEntities[rider.id] {
                entity = existing
            } else {
                entity = buildAIScooter(hue: rider.scooterHue)
                worldRoot.addChild(entity)
                scooterRiderEntities[rider.id] = entity
            }
            entity.position = [Float(rider.x), 0.11, Float(rider.z)]
            entity.orientation = simd_quatf(angle: rider.direction > 0 ? 0 : .pi, axis: [0, 1, 0])
        }
    }

    private func buildTrafficCar(hue: Double) -> Entity {
        let root = Entity()
        let bodyColor = UIColor(hue: hue, saturation: 0.62, brightness: 0.76, alpha: 1)
        let body = material(bodyColor, roughness: 0.36, metallic: true)
        let glass = material(.init(red: 0.03, green: 0.13, blue: 0.20, alpha: 1), roughness: 0.15, metallic: true)
        let rubber = material(.init(white: 0.02, alpha: 1), roughness: 1)
        root.addChild(box(width: 1.75, height: 0.48, depth: 3.65, color: body, position: [0, 0.30, 0]))
        root.addChild(box(width: 1.48, height: 0.52, depth: 1.75, color: glass, position: [0, 0.72, -0.15]))
        for x in [-0.74 as Float, 0.74 as Float] {
            for z in [-1.18 as Float, 1.18 as Float] {
                let wheel = ModelEntity(mesh: .generateCylinder(height: 0.16, radius: 0.31), materials: [rubber])
                wheel.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
                wheel.position = [x, 0.02, z]
                root.addChild(wheel)
            }
        }
        return root
    }

    private func buildAIScooter(hue: Double) -> Entity {
        let root = Entity()
        let accent = material(UIColor(hue: hue, saturation: 0.75, brightness: 0.92, alpha: 1), roughness: 0.35, metallic: true)
        let dark = material(.init(white: 0.035, alpha: 1), roughness: 0.68, metallic: true)
        let rubber = material(.init(white: 0.02, alpha: 1), roughness: 1)
        root.addChild(box(width: 0.16, height: 0.07, depth: 0.62, color: dark, position: [0, 0.20, 0]))
        for z in [-0.42 as Float, 0.42 as Float] {
            let wheel = ModelEntity(mesh: .generateCylinder(height: 0.07, radius: 0.12), materials: [rubber])
            wheel.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            wheel.position = [0, 0.12, z]
            root.addChild(wheel)
        }
        root.addChild(box(width: 0.035, height: 0.92, depth: 0.04, color: accent, position: [0, 0.66, 0.34]))
        root.addChild(box(width: 0.48, height: 0.025, depth: 0.025, color: dark, position: [0, 1.11, 0.34]))
        root.addChild(box(width: 0.25, height: 0.42, depth: 0.16, color: accent, position: [0, 1.18, -0.04]))
        return root
    }

    private func updateCamera(_ snapshot: RenderSnapshot) {
        let yaw = Float(snapshot.yawRadians)
        let forward = SIMD3<Float>(sin(yaw), 0, cos(yaw))
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        let base = SIMD3<Float>(Float(snapshot.playerX), 0, Float(snapshot.playerZ))
        let speed = Float(snapshot.speedMetersPerSecond)

        let position: SIMD3<Float>
        let target: SIMD3<Float>
        let fov: Float
        switch snapshot.camera {
        case .chase:
            position = base - forward * (4.8 + min(1.4, speed * 0.035)) + SIMD3<Float>(0, 2.45, 0) + right * Float(snapshot.cameraYawOffset)
            target = base + forward * 1.9 + SIMD3<Float>(0, 0.95, 0)
            fov = 68 + min(8, speed * 0.35)
        case .close:
            position = base - forward * 2.55 + SIMD3<Float>(0, 1.62, 0) + right * Float(snapshot.cameraYawOffset * 0.6)
            target = base + forward * 2.4 + SIMD3<Float>(0, 1.02, 0)
            fov = 72 + min(10, speed * 0.42)
        case .pov:
            let head = base + SIMD3<Float>(0, 1.66, 0) + forward * 0.08
            let lookYaw = yaw + Float(snapshot.cameraYawOffset)
            let lookForward = SIMD3<Float>(sin(lookYaw), Float(snapshot.cameraPitchOffset), cos(lookYaw))
            position = head
            target = head + lookForward * 8
            fov = 78 + min(18, speed * 0.75)
        }
        cameraEntity.look(at: target, from: position, relativeTo: nil)
        if var camera = cameraEntity.components[PerspectiveCameraComponent.self] {
            camera.fieldOfViewInDegrees = fov
            cameraEntity.components.set(camera)
        }
    }

    private func box(width: Float, height: Float, depth: Float, color: Material, position: SIMD3<Float>) -> ModelEntity {
        let entity = ModelEntity(
            mesh: .generateBox(width: width, height: height, depth: depth, cornerRadius: min(width, min(height, depth)) * 0.08),
            materials: [color]
        )
        entity.position = position
        return entity
    }

    private func limb(from: SIMD3<Float>, to: SIMD3<Float>, radius: Float, material: Material) -> ModelEntity {
        let vector = to - from
        let length = simd_length(vector)
        let entity = ModelEntity(mesh: .generateCylinder(height: length, radius: radius), materials: [material])
        entity.position = (from + to) * 0.5
        entity.look(at: to, from: entity.position, relativeTo: riderRoot)
        entity.orientation *= simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        return entity
    }

    private func material(_ color: UIColor, roughness: Float, metallic: Bool = false) -> Material {
        SimpleMaterial(color: color, roughness: roughness, isMetallic: metallic)
    }
}
