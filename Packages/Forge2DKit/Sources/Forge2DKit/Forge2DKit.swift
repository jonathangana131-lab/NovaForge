import Foundation

public enum Forge2DContractError: Error, Equatable, Sendable {
    case invalidActionID
    case invalidLoopConfiguration
    case invalidTouchStick
    case invalidControllerBinding
    case invalidCameraPolicy
    case invalidPerformanceBudget
    case invalidSaveEnvelope
}

public struct Forge2DVector: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
    }

    public static let zero = Forge2DVector(x: 0, y: 0)

    public var lengthSquared: Double { x * x + y * y }
    public var length: Double { lengthSquared.squareRoot() }

    public func clampedLength(maximum: Double) -> Forge2DVector {
        guard maximum.isFinite, maximum > 0 else { return .zero }
        let currentLength = length
        guard currentLength > maximum, currentLength > 0 else { return self }
        let scale = maximum / currentLength
        return Forge2DVector(x: x * scale, y: y * scale)
    }

    public static func + (lhs: Forge2DVector, rhs: Forge2DVector) -> Forge2DVector {
        Forge2DVector(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    public static func - (lhs: Forge2DVector, rhs: Forge2DVector) -> Forge2DVector {
        Forge2DVector(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    public static func * (lhs: Forge2DVector, rhs: Double) -> Forge2DVector {
        guard rhs.isFinite else { return .zero }
        return Forge2DVector(x: lhs.x * rhs, y: lhs.y * rhs)
    }
}

public struct Forge2DRect: Codable, Hashable, Sendable {
    public var min: Forge2DVector
    public var max: Forge2DVector

    public init(min: Forge2DVector, max: Forge2DVector) {
        self.min = Forge2DVector(x: Swift.min(min.x, max.x), y: Swift.min(min.y, max.y))
        self.max = Forge2DVector(x: Swift.max(min.x, max.x), y: Swift.max(min.y, max.y))
    }

    public init(center: Forge2DVector, size: Forge2DVector) {
        let width = Swift.max(0, size.x.isFinite ? size.x : 0)
        let height = Swift.max(0, size.y.isFinite ? size.y : 0)
        let half = Forge2DVector(x: width / 2, y: height / 2)
        self.init(min: center - half, max: center + half)
    }

    public var width: Double { max.x - min.x }
    public var height: Double { max.y - min.y }
    public var center: Forge2DVector {
        Forge2DVector(x: (min.x + max.x) / 2, y: (min.y + max.y) / 2)
    }

    public func contains(_ point: Forge2DVector) -> Bool {
        point.x >= min.x && point.x <= max.x && point.y >= min.y && point.y <= max.y
    }
}

public struct Forge2DCollisionContact: Codable, Hashable, Sendable {
    public let normal: Forge2DVector
    public let penetration: Double

    public init(normal: Forge2DVector, penetration: Double) {
        self.normal = normal
        self.penetration = Swift.max(0, penetration.isFinite ? penetration : 0)
    }

    public var separation: Forge2DVector { normal * penetration }
}

public enum Forge2DCollision {
    /// Returns the minimum-axis contact needed to move `moving` out of `obstacle`.
    /// Edge-touching rectangles are not considered penetrating contacts.
    public static func contact(moving: Forge2DRect, obstacle: Forge2DRect) -> Forge2DCollisionContact? {
        let overlapX = Swift.min(moving.max.x, obstacle.max.x) - Swift.max(moving.min.x, obstacle.min.x)
        let overlapY = Swift.min(moving.max.y, obstacle.max.y) - Swift.max(moving.min.y, obstacle.min.y)
        guard overlapX > 0, overlapY > 0 else { return nil }

        let movingCenter = moving.center
        let obstacleCenter = obstacle.center
        if overlapX <= overlapY {
            let normalX = movingCenter.x < obstacleCenter.x ? -1.0 : 1.0
            return Forge2DCollisionContact(normal: Forge2DVector(x: normalX, y: 0), penetration: overlapX)
        }

        let normalY = movingCenter.y < obstacleCenter.y ? -1.0 : 1.0
        return Forge2DCollisionContact(normal: Forge2DVector(x: 0, y: normalY), penetration: overlapY)
    }
}

public struct Forge2DLoopConfiguration: Codable, Hashable, Sendable {
    public let simulationHz: Int
    public let maxCatchUpSteps: Int

    public init(simulationHz: Int = 60, maxCatchUpSteps: Int = 4) throws {
        guard (1...240).contains(simulationHz), (1...16).contains(maxCatchUpSteps) else {
            throw Forge2DContractError.invalidLoopConfiguration
        }
        self.simulationHz = simulationHz
        self.maxCatchUpSteps = maxCatchUpSteps
    }

    public var fixedStepDuration: Double { 1.0 / Double(simulationHz) }
    public var maximumAcceptedFrameDuration: Double { fixedStepDuration * Double(maxCatchUpSteps) }
}

public struct Forge2DStepPlan: Codable, Hashable, Sendable {
    public let stepCount: Int
    public let fixedStepDuration: Double
    public let interpolationAlpha: Double
    public let discardedFrameDuration: Double
}

public struct Forge2DFixedStepClock: Sendable {
    public let configuration: Forge2DLoopConfiguration
    private var accumulator: Double = 0

    public init(configuration: Forge2DLoopConfiguration) {
        self.configuration = configuration
    }

    public mutating func reset() {
        accumulator = 0
    }

    /// Converts render-frame time into a bounded deterministic simulation plan.
    /// Very long frames are intentionally truncated so foreground recovery cannot trigger a simulation spiral.
    public mutating func advance(frameDuration rawFrameDuration: Double) -> Forge2DStepPlan {
        let frameDuration = rawFrameDuration.isFinite ? Swift.max(0, rawFrameDuration) : 0
        let accepted = Swift.min(frameDuration, configuration.maximumAcceptedFrameDuration)
        let discarded = Swift.max(0, frameDuration - accepted)
        accumulator += accepted

        let step = configuration.fixedStepDuration
        var steps = Int((accumulator / step).rounded(.down))
        steps = Swift.min(steps, configuration.maxCatchUpSteps)
        accumulator -= Double(steps) * step

        // Floating-point noise should never expose an interpolation value outside [0, 1).
        if accumulator < 0 || !accumulator.isFinite { accumulator = 0 }
        if accumulator >= step { accumulator.formTruncatingRemainder(dividingBy: step) }
        let alpha = Swift.min(0.999_999_999, Swift.max(0, accumulator / step))

        return Forge2DStepPlan(
            stepCount: steps,
            fixedStepDuration: step,
            interpolationAlpha: alpha,
            discardedFrameDuration: discarded
        )
    }
}

public struct Forge2DActionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 64,
              trimmed == rawValue,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Forge2DContractError.invalidActionID
        }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Forge2D action identifier")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum Forge2DInputSource: String, Codable, CaseIterable, Sendable {
    case touch
    case controller
    case keyboard
    case automation
}

public struct Forge2DInputSnapshot: Codable, Equatable, Sendable {
    public let source: Forge2DInputSource
    public let values: [Forge2DActionID: Double]

    public init(source: Forge2DInputSource, values: [Forge2DActionID: Double]) {
        self.source = source
        self.values = values.reduce(into: [:]) { partialResult, element in
            let value = element.value.isFinite ? Swift.max(-1, Swift.min(1, element.value)) : 0
            if value != 0 { partialResult[element.key] = value }
        }
    }

    public func value(for action: Forge2DActionID) -> Double { values[action] ?? 0 }

    public func isPressed(_ action: Forge2DActionID, threshold: Double = 0.5) -> Bool {
        let safeThreshold = threshold.isFinite ? Swift.max(0, Swift.min(1, threshold)) : 0.5
        return abs(value(for: action)) >= safeThreshold
    }

    public func forSimulation(isPaused: Bool) -> Forge2DInputSnapshot {
        isPaused ? Forge2DInputSnapshot(source: source, values: [:]) : self
    }
}

public enum Forge2DInputCombiner {
    /// Combines simultaneous input sources without making event-order a hidden authority.
    /// The largest absolute magnitude wins. Equal-and-opposite input neutralizes to zero.
    public static func combine(_ snapshots: [Forge2DInputSnapshot]) -> Forge2DInputSnapshot {
        var combined: [Forge2DActionID: Double] = [:]
        let actions = Set(snapshots.flatMap { $0.values.keys })

        for action in actions {
            let candidates = snapshots.map { $0.value(for: action) }.filter { $0 != 0 }
            guard let maximumMagnitude = candidates.map({ abs($0) }).max() else { continue }
            let strongest = candidates.filter { abs($0) == maximumMagnitude }
            let hasPositive = strongest.contains { $0 > 0 }
            let hasNegative = strongest.contains { $0 < 0 }
            if hasPositive == hasNegative { continue }
            combined[action] = hasPositive ? maximumMagnitude : -maximumMagnitude
        }

        return Forge2DInputSnapshot(source: .automation, values: combined)
    }
}

public struct Forge2DTouchStick: Codable, Hashable, Sendable {
    public let center: Forge2DVector
    public let radius: Double
    public let deadZoneFraction: Double

    public init(center: Forge2DVector, radius: Double, deadZoneFraction: Double = 0.12) throws {
        guard radius.isFinite, radius > 0,
              deadZoneFraction.isFinite, deadZoneFraction >= 0, deadZoneFraction < 1 else {
            throw Forge2DContractError.invalidTouchStick
        }
        self.center = center
        self.radius = radius
        self.deadZoneFraction = deadZoneFraction
    }

    public func sample(touchPoint: Forge2DVector) -> Forge2DVector {
        let delta = touchPoint - center
        let normalized = (delta * (1 / radius)).clampedLength(maximum: 1)
        let magnitude = normalized.length
        guard magnitude > deadZoneFraction, magnitude > 0 else { return .zero }

        let remappedMagnitude = (magnitude - deadZoneFraction) / (1 - deadZoneFraction)
        return normalized * (remappedMagnitude / magnitude)
    }
}

public enum Forge2DControllerElement: String, Codable, CaseIterable, Sendable {
    case leftStickX
    case leftStickY
    case rightStickX
    case rightStickY
    case leftTrigger
    case rightTrigger
    case buttonSouth
    case buttonEast
    case buttonWest
    case buttonNorth
    case dpadX
    case dpadY
}

public struct Forge2DControllerBinding: Codable, Hashable, Sendable {
    public let element: Forge2DControllerElement
    public let action: Forge2DActionID
    public let scale: Double

    public init(element: Forge2DControllerElement, action: Forge2DActionID, scale: Double = 1) throws {
        guard scale.isFinite, scale >= -4, scale <= 4, scale != 0 else {
            throw Forge2DContractError.invalidControllerBinding
        }
        self.element = element
        self.action = action
        self.scale = scale
    }
}

public struct Forge2DControllerMap: Codable, Equatable, Sendable {
    public let bindings: [Forge2DControllerBinding]

    public init(bindings: [Forge2DControllerBinding]) {
        self.bindings = bindings
    }

    public func snapshot(elements: [Forge2DControllerElement: Double]) -> Forge2DInputSnapshot {
        var candidates: [Forge2DActionID: [Double]] = [:]
        for binding in bindings {
            let raw = elements[binding.element] ?? 0
            guard raw.isFinite else { continue }
            let mapped = Swift.max(-1, Swift.min(1, raw * binding.scale))
            if mapped != 0 { candidates[binding.action, default: []].append(mapped) }
        }

        var values: [Forge2DActionID: Double] = [:]
        for (action, actionCandidates) in candidates {
            guard let maximumMagnitude = actionCandidates.map({ abs($0) }).max() else { continue }
            let strongest = actionCandidates.filter { abs($0) == maximumMagnitude }
            let hasPositive = strongest.contains { $0 > 0 }
            let hasNegative = strongest.contains { $0 < 0 }
            if hasPositive == hasNegative { continue }
            values[action] = hasPositive ? maximumMagnitude : -maximumMagnitude
        }
        return Forge2DInputSnapshot(source: .controller, values: values)
    }
}

public struct Forge2DCameraPolicy: Codable, Hashable, Sendable {
    public let viewportSize: Forge2DVector
    public let deadZoneSize: Forge2DVector
    public let worldBounds: Forge2DRect?

    public init(viewportSize: Forge2DVector, deadZoneSize: Forge2DVector, worldBounds: Forge2DRect? = nil) throws {
        guard viewportSize.x > 0, viewportSize.y > 0,
              deadZoneSize.x >= 0, deadZoneSize.y >= 0,
              deadZoneSize.x <= viewportSize.x,
              deadZoneSize.y <= viewportSize.y else {
            throw Forge2DContractError.invalidCameraPolicy
        }
        self.viewportSize = viewportSize
        self.deadZoneSize = deadZoneSize
        self.worldBounds = worldBounds
    }

    public func follow(currentCenter: Forge2DVector, target: Forge2DVector) -> Forge2DVector {
        var next = currentCenter
        let halfDeadZone = Forge2DVector(x: deadZoneSize.x / 2, y: deadZoneSize.y / 2)

        if target.x < currentCenter.x - halfDeadZone.x {
            next.x = target.x + halfDeadZone.x
        } else if target.x > currentCenter.x + halfDeadZone.x {
            next.x = target.x - halfDeadZone.x
        }

        if target.y < currentCenter.y - halfDeadZone.y {
            next.y = target.y + halfDeadZone.y
        } else if target.y > currentCenter.y + halfDeadZone.y {
            next.y = target.y - halfDeadZone.y
        }

        guard let worldBounds else { return next }
        let halfViewport = Forge2DVector(x: viewportSize.x / 2, y: viewportSize.y / 2)

        if worldBounds.width <= viewportSize.x {
            next.x = worldBounds.center.x
        } else {
            next.x = Swift.max(worldBounds.min.x + halfViewport.x, Swift.min(worldBounds.max.x - halfViewport.x, next.x))
        }

        if worldBounds.height <= viewportSize.y {
            next.y = worldBounds.center.y
        } else {
            next.y = Swift.max(worldBounds.min.y + halfViewport.y, Swift.min(worldBounds.max.y - halfViewport.y, next.y))
        }

        return next
    }
}

public struct Forge2DPerformanceBudget: Codable, Hashable, Sendable {
    public let targetFramesPerSecond: Int
    public let maxVisibleSprites: Int
    public let maxPhysicsBodies: Int
    public let maxParticles: Int

    public init(
        targetFramesPerSecond: Int = 60,
        maxVisibleSprites: Int = 500,
        maxPhysicsBodies: Int = 200,
        maxParticles: Int = 1_000
    ) throws {
        guard (30...120).contains(targetFramesPerSecond),
              maxVisibleSprites >= 0,
              maxPhysicsBodies >= 0,
              maxParticles >= 0 else {
            throw Forge2DContractError.invalidPerformanceBudget
        }
        self.targetFramesPerSecond = targetFramesPerSecond
        self.maxVisibleSprites = maxVisibleSprites
        self.maxPhysicsBodies = maxPhysicsBodies
        self.maxParticles = maxParticles
    }

    public func evaluate(_ sample: Forge2DPerformanceSample) -> [Forge2DPerformanceViolation] {
        var violations: [Forge2DPerformanceViolation] = []
        if let measuredFramesPerSecond = sample.measuredFramesPerSecond, measuredFramesPerSecond < Double(targetFramesPerSecond) {
            violations.append(.frameRate(actual: measuredFramesPerSecond, target: targetFramesPerSecond))
        }
        if sample.visibleSprites > maxVisibleSprites { violations.append(.visibleSprites(actual: sample.visibleSprites, limit: maxVisibleSprites)) }
        if sample.physicsBodies > maxPhysicsBodies { violations.append(.physicsBodies(actual: sample.physicsBodies, limit: maxPhysicsBodies)) }
        if sample.particles > maxParticles { violations.append(.particles(actual: sample.particles, limit: maxParticles)) }
        return violations
    }
}

public struct Forge2DPerformanceSample: Codable, Hashable, Sendable {
    public let measuredFramesPerSecond: Double?
    public let visibleSprites: Int
    public let physicsBodies: Int
    public let particles: Int

    public init(measuredFramesPerSecond: Double? = nil, visibleSprites: Int, physicsBodies: Int, particles: Int) {
        if let measuredFramesPerSecond, measuredFramesPerSecond.isFinite, measuredFramesPerSecond >= 0 {
            self.measuredFramesPerSecond = measuredFramesPerSecond
        } else {
            self.measuredFramesPerSecond = nil
        }
        self.visibleSprites = Swift.max(0, visibleSprites)
        self.physicsBodies = Swift.max(0, physicsBodies)
        self.particles = Swift.max(0, particles)
    }
}

public enum Forge2DPerformanceViolation: Hashable, Sendable {
    case frameRate(actual: Double, target: Int)
    case visibleSprites(actual: Int, limit: Int)
    case physicsBodies(actual: Int, limit: Int)
    case particles(actual: Int, limit: Int)
}

public struct Forge2DSaveEnvelope: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let projectID: String
    public let slot: String
    public let payload: Data

    public init(projectID: String, slot: String, payload: Data, formatVersion: Int = currentFormatVersion) throws {
        let cleanProjectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSlot = slot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard formatVersion == Self.currentFormatVersion,
              !cleanProjectID.isEmpty, cleanProjectID == projectID, cleanProjectID.count <= 128,
              !cleanSlot.isEmpty, cleanSlot == slot, cleanSlot.count <= 64,
              payload.count <= 4 * 1_024 * 1_024 else {
            throw Forge2DContractError.invalidSaveEnvelope
        }
        self.formatVersion = formatVersion
        self.projectID = cleanProjectID
        self.slot = cleanSlot
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey { case formatVersion, projectID, slot, payload }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        let projectID = try container.decode(String.self, forKey: .projectID)
        let slot = try container.decode(String.self, forKey: .slot)
        let payload = try container.decode(Data.self, forKey: .payload)
        do {
            try self.init(projectID: projectID, slot: slot, payload: payload, formatVersion: formatVersion)
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: container, debugDescription: "Invalid Forge2D save envelope")
        }
    }
}
