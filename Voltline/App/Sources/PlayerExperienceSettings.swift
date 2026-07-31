import Combine
import Foundation
import QuartzCore
import SwiftUI
import UIKit

enum VoltlinePerformanceMode: String, CaseIterable, Codable, Identifiable {
    case batterySaver = "Battery Saver"
    case balanced = "Balanced"
    case highFrameRate = "High Frame Rate"

    var id: String { rawValue }

    var preferredFramesPerSecond: Int {
        switch self {
        case .batterySaver: return 30
        case .balanced: return 60
        case .highFrameRate: return 120
        }
    }

    var detail: String {
        switch self {
        case .batterySaver:
            return "30 FPS update loop for lower heat and battery use."
        case .balanced:
            return "60 FPS target for iPhone 12 and most supported devices."
        case .highFrameRate:
            return "Up to 120 FPS on ProMotion devices; falls back to the display limit."
        }
    }

    var symbol: String {
        switch self {
        case .batterySaver: return "battery.100percent"
        case .balanced: return "gauge.with.dots.needle.50percent"
        case .highFrameRate: return "bolt.fill"
        }
    }
}

@MainActor
final class PlayerExperienceSettings: ObservableObject {
    static let shared = PlayerExperienceSettings()

    @Published var performanceMode: VoltlinePerformanceMode {
        didSet { persist() }
    }
    @Published var automaticThermalProtection: Bool {
        didSet { persist() }
    }
    @Published var rideAudioEnabled: Bool {
        didSet { persist() }
    }
    @Published var hapticsEnabled: Bool {
        didSet { persist() }
    }
    @Published var reduceMotion: Bool {
        didSet { persist() }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { persist() }
    }
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    private struct Stored: Codable {
        var performanceMode: VoltlinePerformanceMode
        var automaticThermalProtection: Bool
        var rideAudioEnabled: Bool
        var hapticsEnabled: Bool
        var reduceMotion: Bool
        var hasCompletedOnboarding: Bool
    }

    private let defaultsKey = "Voltline.PlayerExperience.v1"
    private var thermalObserver: NSObjectProtocol?

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let forceOnboarding = arguments.contains("--qa-onboarding")
        let qaLaunch = arguments.contains { $0.hasPrefix("--qa-") } && !forceOnboarding

        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            performanceMode = stored.performanceMode
            automaticThermalProtection = stored.automaticThermalProtection
            rideAudioEnabled = stored.rideAudioEnabled
            hapticsEnabled = stored.hapticsEnabled
            reduceMotion = stored.reduceMotion
            hasCompletedOnboarding = forceOnboarding ? false : (qaLaunch || stored.hasCompletedOnboarding)
        } else {
            performanceMode = .balanced
            automaticThermalProtection = true
            rideAudioEnabled = true
            hapticsEnabled = true
            reduceMotion = UIAccessibility.isReduceMotionEnabled
            hasCompletedOnboarding = qaLaunch
        }

        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalState = ProcessInfo.processInfo.thermalState
            }
        }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }

    var effectiveFramesPerSecond: Int {
        guard automaticThermalProtection else {
            return performanceMode.preferredFramesPerSecond
        }
        switch thermalState {
        case .serious, .critical:
            return min(30, performanceMode.preferredFramesPerSecond)
        case .fair:
            return min(60, performanceMode.preferredFramesPerSecond)
        case .nominal:
            return performanceMode.preferredFramesPerSecond
        @unknown default:
            return min(60, performanceMode.preferredFramesPerSecond)
        }
    }

    var thermalLabel: String {
        switch thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    func finishOnboarding() {
        hasCompletedOnboarding = true
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
    }

    private func persist() {
        let stored = Stored(
            performanceMode: performanceMode,
            automaticThermalProtection: automaticThermalProtection,
            rideAudioEnabled: rideAudioEnabled,
            hapticsEnabled: hapticsEnabled,
            reduceMotion: reduceMotion,
            hasCompletedOnboarding: hasCompletedOnboarding
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

@MainActor
final class VoltlineFrameDriver: NSObject, ObservableObject {
    @Published private(set) var activeFramesPerSecond = 0

    private weak var session: GameSession?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    func start(session: GameSession, framesPerSecond: Int) {
        self.session = session
        session.stop()
        configure(framesPerSecond: framesPerSecond)
    }

    func configure(framesPerSecond: Int) {
        let requested = max(20, min(120, framesPerSecond))
        let screenMaximum = max(20, UIScreen.main.maximumFramesPerSecond)
        let actual = min(requested, screenMaximum)
        activeFramesPerSecond = actual

        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: Float(min(20, actual)),
            maximum: Float(screenMaximum),
            preferred: Float(actual)
        )
        lastTimestamp = nil
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        activeFramesPerSecond = 0
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let session else { return }
        guard !session.isPaused else {
            lastTimestamp = link.timestamp
            return
        }
        guard let lastTimestamp else {
            self.lastTimestamp = link.timestamp
            return
        }
        let delta = min(0.05, max(0, link.timestamp - lastTimestamp))
        self.lastTimestamp = link.timestamp
        session.advance(frameSeconds: delta)
    }
}
