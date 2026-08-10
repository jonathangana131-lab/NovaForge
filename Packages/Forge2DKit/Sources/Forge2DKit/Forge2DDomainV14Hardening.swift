import Foundation

private enum Forge2DVectorCodingKeys: String, CodingKey { case x, y }
private enum Forge2DRectCodingKeys: String, CodingKey { case min, max }
private enum Forge2DCollisionContactCodingKeys: String, CodingKey { case normal, penetration }
private enum Forge2DStepPlanCodingKeys: String, CodingKey {
    case stepCount, fixedStepDuration, interpolationAlpha, discardedFrameDuration
}
private enum Forge2DInputSnapshotCodingKeys: String, CodingKey { case source, values }
private enum Forge2DPerformanceSampleCodingKeys: String, CodingKey {
    case measuredFramesPerSecond, visibleSprites, physicsBodies, particles
}

extension Forge2DVector {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DVectorCodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        guard x.isFinite, y.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .x,
                in: container,
                debugDescription: "Forge2D vectors require finite coordinates"
            )
        }
        self.init(x: x, y: y)
    }
}

extension Forge2DRect {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DRectCodingKeys.self)
        let min = try container.decode(Forge2DVector.self, forKey: .min)
        let max = try container.decode(Forge2DVector.self, forKey: .max)
        guard min.x <= max.x, min.y <= max.y else {
            throw DecodingError.dataCorruptedError(
                forKey: .min,
                in: container,
                debugDescription: "Forge2D rectangle bounds must already be normalized"
            )
        }
        self.init(min: min, max: max)
    }
}

extension Forge2DCollisionContact {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DCollisionContactCodingKeys.self)
        let normal = try container.decode(Forge2DVector.self, forKey: .normal)
        let penetration = try container.decode(Double.self, forKey: .penetration)
        guard penetration.isFinite, penetration >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .penetration,
                in: container,
                debugDescription: "Forge2D collision penetration must be finite and nonnegative"
            )
        }
        self.init(normal: normal, penetration: penetration)
    }
}

extension Forge2DStepPlan {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DStepPlanCodingKeys.self)
        let stepCount = try container.decode(Int.self, forKey: .stepCount)
        let fixedStepDuration = try container.decode(Double.self, forKey: .fixedStepDuration)
        let interpolationAlpha = try container.decode(Double.self, forKey: .interpolationAlpha)
        let discardedFrameDuration = try container.decode(Double.self, forKey: .discardedFrameDuration)

        guard (0...16).contains(stepCount),
              fixedStepDuration.isFinite, fixedStepDuration > 0, fixedStepDuration <= 1,
              interpolationAlpha.isFinite, interpolationAlpha >= 0, interpolationAlpha < 1,
              discardedFrameDuration.isFinite, discardedFrameDuration >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .stepCount,
                in: container,
                debugDescription: "Invalid persisted Forge2D fixed-step plan"
            )
        }

        self.stepCount = stepCount
        self.fixedStepDuration = fixedStepDuration
        self.interpolationAlpha = interpolationAlpha
        self.discardedFrameDuration = discardedFrameDuration
    }
}

extension Forge2DInputSnapshot {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DInputSnapshotCodingKeys.self)
        let source = try container.decode(Forge2DInputSource.self, forKey: .source)
        let values = try container.decode([Forge2DActionID: Double].self, forKey: .values)

        guard values.count <= 256,
              values.values.allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .values,
                in: container,
                debugDescription: "Forge2D input values must be finite normalized actions"
            )
        }

        self.init(source: source, values: values)
    }
}

extension Forge2DPerformanceSample {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DPerformanceSampleCodingKeys.self)
        let measuredFramesPerSecond = try container.decodeIfPresent(Double.self, forKey: .measuredFramesPerSecond)
        let visibleSprites = try container.decode(Int.self, forKey: .visibleSprites)
        let physicsBodies = try container.decode(Int.self, forKey: .physicsBodies)
        let particles = try container.decode(Int.self, forKey: .particles)

        guard measuredFramesPerSecond.map({ $0.isFinite && $0 >= 0 }) ?? true,
              visibleSprites >= 0,
              physicsBodies >= 0,
              particles >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .measuredFramesPerSecond,
                in: container,
                debugDescription: "Invalid persisted Forge2D performance evidence"
            )
        }

        self.init(
            measuredFramesPerSecond: measuredFramesPerSecond,
            visibleSprites: visibleSprites,
            physicsBodies: physicsBodies,
            particles: particles
        )
    }
}
