import Combine
import Foundation
import SwiftUI

enum VoltlineMissionKind: String, Codable, CaseIterable {
    case route
    case distance
    case speed
    case cleanDistance
    case deposits
    case photos
    case upgrade
}

struct MissionCheckpoint: Identifiable, Codable, Hashable {
    let id: String
    let x: Double
    let z: Double
    let radiusMeters: Double
    let title: String
}

struct VoltlineMission: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let reward: Double
    let kind: VoltlineMissionKind
    let target: Double
    let checkpoints: [MissionCheckpoint]

    static let catalog: [VoltlineMission] = [
        VoltlineMission(
            id: "tunnel-line",
            title: "Tunnel Line",
            detail: "Hit the boulevard, tunnel entrance, and north exit checkpoints in order.",
            symbol: "point.topleft.down.to.point.bottomright.curvepath",
            reward: 325,
            kind: .route,
            target: 3,
            checkpoints: [
                MissionCheckpoint(id: "boulevard", x: 0, z: 42, radiusMeters: 13, title: "Boulevard Gate"),
                MissionCheckpoint(id: "tunnel", x: 0, z: 119, radiusMeters: 15, title: "Tunnel Entrance"),
                MissionCheckpoint(id: "exit", x: 0, z: 178, radiusMeters: 16, title: "North Exit")
            ]
        ),
        VoltlineMission(
            id: "half-mile-charge",
            title: "Half-Mile Charge",
            detail: "Ride 0.5 mile on any surface. Progress comes from the physics odometer.",
            symbol: "road.lanes",
            reward: 180,
            kind: .distance,
            target: 804.672,
            checkpoints: []
        ),
        VoltlineMission(
            id: "twenty-club",
            title: "Twenty Club",
            detail: "Reach a true simulated 20 mph without triggering a controller cutoff.",
            symbol: "speedometer",
            reward: 220,
            kind: .speed,
            target: 20,
            checkpoints: []
        ),
        VoltlineMission(
            id: "clean-mile",
            title: "Clean Mile",
            detail: "Ride one full mile without crashing. A crash restarts mission distance.",
            symbol: "checkmark.shield.fill",
            reward: 450,
            kind: .cleanDistance,
            target: 1_609.344,
            checkpoints: []
        ),
        VoltlineMission(
            id: "payday",
            title: "Payday",
            detail: "Earn one new $100 drive deposit after starting this objective.",
            symbol: "banknote.fill",
            reward: 160,
            kind: .deposits,
            target: 1,
            checkpoints: []
        ),
        VoltlineMission(
            id: "street-photographer",
            title: "Street Photographer",
            detail: "Capture three new in-game ride photos.",
            symbol: "camera.fill",
            reward: 140,
            kind: .photos,
            target: 3,
            checkpoints: []
        ),
        VoltlineMission(
            id: "smart-controller",
            title: "Smart Controller",
            detail: "Install the 75/100 Smart FOC Controller in the Maxshot build.",
            symbol: "slider.horizontal.3",
            reward: 500,
            kind: .upgrade,
            target: 1,
            checkpoints: []
        )
    ]
}

struct MissionCompletion: Identifiable, Equatable {
    let id = UUID()
    let missionTitle: String
    let reward: Double
}

@MainActor
final class MissionDirector: ObservableObject {
    static let shared = MissionDirector()

    @Published private(set) var activeMissionID: String?
    @Published private(set) var completedMissionIDs: Set<String> = []
    @Published private(set) var progress: Double = 0
    @Published private(set) var checkpointIndex = 0
    @Published var isBoardPresented = false
    @Published var recentCompletion: MissionCompletion?

    private struct StoredState: Codable {
        var activeMissionID: String?
        var completedMissionIDs: Set<String>
        var checkpointIndex: Int
        var baselineOdometer: Double
        var baselineDeposits: Int
        var baselinePhotos: Int
        var cleanStartOdometer: Double
    }

    private let defaultsKey = "Voltline.Missions.v1"
    private var baselineOdometer: Double = 0
    private var baselineDeposits = 0
    private var baselinePhotos = 0
    private var cleanStartOdometer: Double = 0
    private var completionDismissTask: Task<Void, Never>?

    private init() {
        restore()
    }

    deinit {
        completionDismissTask?.cancel()
    }

    var activeMission: VoltlineMission? {
        VoltlineMission.catalog.first { $0.id == activeMissionID }
    }

    var completionCount: Int {
        completedMissionIDs.count
    }

    var completionFraction: Double {
        guard !VoltlineMission.catalog.isEmpty else { return 0 }
        return Double(completionCount) / Double(VoltlineMission.catalog.count)
    }

    func isCompleted(_ mission: VoltlineMission) -> Bool {
        completedMissionIDs.contains(mission.id)
    }

    func activate(_ mission: VoltlineMission, session: GameSession) {
        guard !isCompleted(mission) else { return }
        activeMissionID = mission.id
        progress = 0
        checkpointIndex = 0
        baselineOdometer = session.odometerMeters
        baselineDeposits = session.deposits.count
        baselinePhotos = session.photos.count
        cleanStartOdometer = session.odometerMeters
        isBoardPresented = false
        persist()
    }

    func abandonActiveMission() {
        activeMissionID = nil
        progress = 0
        checkpointIndex = 0
        persist()
    }

    func update(session: GameSession) {
        guard let mission = activeMission else { return }

        switch mission.kind {
        case .route:
            updateRoute(mission: mission, session: session)
        case .distance:
            progress = normalized(session.odometerMeters - baselineOdometer, target: mission.target)
        case .speed:
            progress = normalized(session.speedMPH, target: mission.target)
        case .cleanDistance:
            if session.isCrashed {
                cleanStartOdometer = session.odometerMeters
                progress = 0
            } else {
                progress = normalized(session.odometerMeters - cleanStartOdometer, target: mission.target)
            }
        case .deposits:
            progress = normalized(Double(max(0, session.deposits.count - baselineDeposits)), target: mission.target)
        case .photos:
            progress = normalized(Double(max(0, session.photos.count - baselinePhotos)), target: mission.target)
        case .upgrade:
            progress = session.installedItemIDs.contains("vesc-75-100") ? 1 : 0
        }

        if progress >= 1 {
            complete(mission, session: session)
        }
    }

    func distanceToNextCheckpoint(session: GameSession) -> Double? {
        guard let mission = activeMission,
              mission.kind == .route,
              checkpointIndex < mission.checkpoints.count else { return nil }
        let checkpoint = mission.checkpoints[checkpointIndex]
        let snapshot = session.renderSnapshot
        return hypot(checkpoint.x - snapshot.playerX, checkpoint.z - snapshot.playerZ)
    }

    func bearingToNextCheckpoint(session: GameSession) -> Double? {
        guard let mission = activeMission,
              mission.kind == .route,
              checkpointIndex < mission.checkpoints.count else { return nil }
        let checkpoint = mission.checkpoints[checkpointIndex]
        let snapshot = session.renderSnapshot
        let absoluteBearing = atan2(checkpoint.x - snapshot.playerX, checkpoint.z - snapshot.playerZ)
        return atan2(
            sin(absoluteBearing - snapshot.yawRadians),
            cos(absoluteBearing - snapshot.yawRadians)
        )
    }

    func progressLabel(session: GameSession) -> String {
        guard let mission = activeMission else { return "Choose an objective" }

        switch mission.kind {
        case .route:
            guard checkpointIndex < mission.checkpoints.count else { return "Route complete" }
            let checkpoint = mission.checkpoints[checkpointIndex]
            let distance = distanceToNextCheckpoint(session: session) ?? 0
            return "\(checkpoint.title) · \(Int(distance.rounded())) m"
        case .distance, .cleanDistance:
            let meters = progress * mission.target
            return String(
                format: "%.2f / %.2f mi",
                meters / 1_609.344,
                mission.target / 1_609.344
            )
        case .speed:
            return "\(Int(session.speedMPH.rounded())) / \(Int(mission.target)) mph"
        case .deposits:
            let count = max(0, session.deposits.count - baselineDeposits)
            return "\(count) / \(Int(mission.target)) deposit"
        case .photos:
            let count = max(0, session.photos.count - baselinePhotos)
            return "\(count) / \(Int(mission.target)) photos"
        case .upgrade:
            return session.installedItemIDs.contains("vesc-75-100")
                ? "Installed"
                : "Controller not installed"
        }
    }

    func dismissCompletion() {
        completionDismissTask?.cancel()
        recentCompletion = nil
    }

    static func routeProgress(
        positionX: Double,
        positionZ: Double,
        checkpoints: [MissionCheckpoint],
        startingIndex: Int
    ) -> Int {
        var index = max(0, min(startingIndex, checkpoints.count))
        while index < checkpoints.count {
            let checkpoint = checkpoints[index]
            let distance = hypot(checkpoint.x - positionX, checkpoint.z - positionZ)
            guard distance <= checkpoint.radiusMeters else { break }
            index += 1
        }
        return index
    }

    private func updateRoute(mission: VoltlineMission, session: GameSession) {
        let snapshot = session.renderSnapshot
        checkpointIndex = Self.routeProgress(
            positionX: snapshot.playerX,
            positionZ: snapshot.playerZ,
            checkpoints: mission.checkpoints,
            startingIndex: checkpointIndex
        )
        progress = mission.checkpoints.isEmpty
            ? 1
            : Double(checkpointIndex) / Double(mission.checkpoints.count)
    }

    private func complete(_ mission: VoltlineMission, session: GameSession) {
        guard completedMissionIDs.insert(mission.id).inserted else { return }
        activeMissionID = nil
        progress = 0
        checkpointIndex = 0
        session.grantMissionReward(title: mission.title, amount: mission.reward)
        recentCompletion = MissionCompletion(missionTitle: mission.title, reward: mission.reward)
        persist()

        completionDismissTask?.cancel()
        let completionID = recentCompletion?.id
        completionDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled,
                  self?.recentCompletion?.id == completionID else { return }
            self?.recentCompletion = nil
        }
    }

    private func normalized(_ value: Double, target: Double) -> Double {
        guard target > 0 else { return 1 }
        return min(1, max(0, value / target))
    }

    private func persist() {
        let stored = StoredState(
            activeMissionID: activeMissionID,
            completedMissionIDs: completedMissionIDs,
            checkpointIndex: checkpointIndex,
            baselineOdometer: baselineOdometer,
            baselineDeposits: baselineDeposits,
            baselinePhotos: baselinePhotos,
            cleanStartOdometer: cleanStartOdometer
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(StoredState.self, from: data) else { return }
        activeMissionID = stored.activeMissionID
        completedMissionIDs = stored.completedMissionIDs
        checkpointIndex = stored.checkpointIndex
        baselineOdometer = stored.baselineOdometer
        baselineDeposits = stored.baselineDeposits
        baselinePhotos = stored.baselinePhotos
        cleanStartOdometer = stored.cleanStartOdometer
    }
}

@MainActor
extension GameSession {
    func grantMissionReward(title: String, amount: Double) {
        bankBalance += amount
        let rewardText = amount.formatted(
            .currency(code: "USD").precision(.fractionLength(0))
        )
        let toast = GameToast(
            title: "Objective complete",
            detail: "\(title) paid \(rewardText).",
            symbol: "checkmark.seal.fill"
        )
        currentToast = toast

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.8))
            guard !Task.isCancelled,
                  self?.currentToast?.id == toast.id else { return }
            self?.currentToast = nil
        }
    }
}
