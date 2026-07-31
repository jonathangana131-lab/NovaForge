import AVFoundation
import Combine
import SwiftUI
import UIKit
import VoltlineSim

/// Keeps audio-render-thread state isolated from SwiftUI and the simulation loop.
private final class RideAudioParameters: @unchecked Sendable {
    struct Snapshot {
        var motorRPM: Float = 0
        var speedMetersPerSecond: Float = 0
        var electricalPowerWatts: Float = 0
        var brakingCurrentAmps: Float = 0
        var crashed = false
        var paused = false
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()

    func update(_ newValue: Snapshot) {
        lock.lock()
        snapshot = newValue
        lock.unlock()
    }

    func read() -> Snapshot {
        lock.lock()
        let value = snapshot
        lock.unlock()
        return value
    }
}

@MainActor
final class RideFeedbackController: ObservableObject {
    private let engine = AVAudioEngine()
    private let parameters = RideAudioParameters()
    private var sourceNode: AVAudioSourceNode?
    private var isRunning = false

    private let crashNotification = UINotificationFeedbackGenerator()
    private let crashImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let modeImpact = UIImpactFeedbackGenerator(style: .medium)

    func start() {
        guard PlayerExperienceSettings.shared.rideAudioEnabled else { return }
        guard !isRunning else { return }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            // The game remains playable if another system audio session blocks startup.
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: 44_100,
            channels: 2
        ) else { return }

        let sharedParameters = parameters
        var phase: Float = 0
        var secondaryPhase: Float = 0
        var noiseState: UInt32 = 0x51A7_2026
        let twoPi = Float.pi * 2

        let source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            let current = sharedParameters.read()
            let sampleRate = Float(format.sampleRate)
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

            let powerLoad = min(1, abs(current.electricalPowerWatts) / 1_800)
            let speedLoad = min(1, current.speedMetersPerSecond / 18)
            let rpmFrequency = max(44, min(920, 46 + current.motorRPM / 24))
            let baseAmplitude: Float
            if current.paused {
                baseAmplitude = 0
            } else if current.crashed {
                baseAmplitude = 0.018
            } else {
                baseAmplitude = 0.018 + powerLoad * 0.105 + speedLoad * 0.035
            }
            let windAmplitude = current.paused ? 0 : max(0, speedLoad - 0.12) * 0.055
            let brakeAmplitude = current.paused ? 0 : min(0.035, current.brakingCurrentAmps * 0.0018)

            for frame in 0..<Int(frameCount) {
                phase += twoPi * rpmFrequency / sampleRate
                secondaryPhase += twoPi * (rpmFrequency * 2.013) / sampleRate
                if phase >= twoPi { phase -= twoPi }
                if secondaryPhase >= twoPi { secondaryPhase -= twoPi }

                noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
                let signedNoise = Float(Int32(bitPattern: noiseState)) / Float(Int32.max)

                let motor = sin(phase) * baseAmplitude
                    + sin(secondaryPhase) * baseAmplitude * 0.24
                let wind = signedNoise * windAmplitude
                let brakeWhine = sin(secondaryPhase * 1.71) * brakeAmplitude
                let sample = max(-0.32, min(0.32, motor + wind + brakeWhine))

                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let channelCount = max(1, Int(buffer.mNumberChannels))
                    for channel in 0..<channelCount {
                        samples[frame * channelCount + channel] = sample
                    }
                }
            }

            isSilence.pointee = ObjCBool(baseAmplitude == 0 && windAmplitude == 0 && brakeAmplitude == 0)
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.72

        do {
            try engine.start()
            sourceNode = source
            isRunning = true
            prepareHaptics()
        } catch {
            engine.detach(source)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        sourceNode = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func update(state: SimulationState, crashed: Bool, paused: Bool) {
        guard PlayerExperienceSettings.shared.rideAudioEnabled else {
            stop()
            return
        }
        if !isRunning { start() }
        parameters.update(.init(
            motorRPM: Float(state.motorRPM),
            speedMetersPerSecond: Float(state.speedMetersPerSecond),
            electricalPowerWatts: Float(state.electricalPowerWatts),
            brakingCurrentAmps: Float(max(0, -state.batteryCurrentAmps)),
            crashed: crashed,
            paused: paused
        ))
    }

    func playCrashFeedback() {
        guard PlayerExperienceSettings.shared.hapticsEnabled else { return }
        crashImpact.impactOccurred(intensity: 1)
        crashNotification.notificationOccurred(.error)
        prepareHaptics()
    }

    func playModeFeedback() {
        guard PlayerExperienceSettings.shared.hapticsEnabled else { return }
        modeImpact.impactOccurred(intensity: 0.72)
        modeImpact.prepare()
    }

    private func prepareHaptics() {
        guard PlayerExperienceSettings.shared.hapticsEnabled else { return }
        crashNotification.prepare()
        crashImpact.prepare()
        modeImpact.prepare()
    }
}

/// A zero-size bridge that follows the live simulation without owning gameplay state.
struct GameFeedbackBridge: View {
    @ObservedObject var session: GameSession
    @ObservedObject private var settings = PlayerExperienceSettings.shared
    @StateObject private var feedback = RideFeedbackController()
    @State private var wasCrashed = false

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                feedback.start()
                feedback.update(
                    state: session.simulationState,
                    crashed: session.isCrashed,
                    paused: session.isPaused
                )
            }
            .onDisappear {
                feedback.stop()
            }
            .onReceive(session.$simulationState) { state in
                feedback.update(
                    state: state,
                    crashed: session.isCrashed,
                    paused: session.isPaused
                )
            }
            .onReceive(session.$isPaused) { paused in
                feedback.update(
                    state: session.simulationState,
                    crashed: session.isCrashed,
                    paused: paused
                )
            }
            .onReceive(session.$isCrashed) { crashed in
                if crashed && !wasCrashed {
                    feedback.playCrashFeedback()
                }
                wasCrashed = crashed
            }
            .onReceive(session.$driveMode.dropFirst()) { _ in
                feedback.playModeFeedback()
            }
            .onReceive(settings.$rideAudioEnabled) { enabled in
                if enabled {
                    feedback.update(
                        state: session.simulationState,
                        crashed: session.isCrashed,
                        paused: session.isPaused
                    )
                } else {
                    feedback.stop()
                }
            }
    }
}
