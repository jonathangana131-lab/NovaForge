import Foundation

private enum Forge2DLoopCodingKeys: String, CodingKey { case simulationHz, maxCatchUpSteps }
private enum Forge2DTouchStickCodingKeys: String, CodingKey { case center, radius, deadZoneFraction }
private enum Forge2DControllerBindingCodingKeys: String, CodingKey { case element, action, scale }
private enum Forge2DCameraPolicyCodingKeys: String, CodingKey { case viewportSize, deadZoneSize, worldBounds }
private enum Forge2DPerformanceBudgetCodingKeys: String, CodingKey {
    case targetFramesPerSecond, maxVisibleSprites, maxPhysicsBodies, maxParticles
}

extension Forge2DLoopConfiguration {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DLoopCodingKeys.self)
        do {
            try self.init(
                simulationHz: container.decode(Int.self, forKey: .simulationHz),
                maxCatchUpSteps: container.decode(Int.self, forKey: .maxCatchUpSteps)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .simulationHz, in: container, debugDescription: "Invalid Forge2D loop configuration")
        }
    }
}

extension Forge2DTouchStick {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DTouchStickCodingKeys.self)
        do {
            try self.init(
                center: container.decode(Forge2DVector.self, forKey: .center),
                radius: container.decode(Double.self, forKey: .radius),
                deadZoneFraction: container.decode(Double.self, forKey: .deadZoneFraction)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .radius, in: container, debugDescription: "Invalid Forge2D touch stick")
        }
    }
}

extension Forge2DControllerBinding {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DControllerBindingCodingKeys.self)
        do {
            try self.init(
                element: container.decode(Forge2DControllerElement.self, forKey: .element),
                action: container.decode(Forge2DActionID.self, forKey: .action),
                scale: container.decode(Double.self, forKey: .scale)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .scale, in: container, debugDescription: "Invalid Forge2D controller binding")
        }
    }
}

extension Forge2DCameraPolicy {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DCameraPolicyCodingKeys.self)
        do {
            try self.init(
                viewportSize: container.decode(Forge2DVector.self, forKey: .viewportSize),
                deadZoneSize: container.decode(Forge2DVector.self, forKey: .deadZoneSize),
                worldBounds: container.decodeIfPresent(Forge2DRect.self, forKey: .worldBounds)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .viewportSize, in: container, debugDescription: "Invalid Forge2D camera policy")
        }
    }
}

extension Forge2DPerformanceBudget {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Forge2DPerformanceBudgetCodingKeys.self)
        do {
            try self.init(
                targetFramesPerSecond: container.decode(Int.self, forKey: .targetFramesPerSecond),
                maxVisibleSprites: container.decode(Int.self, forKey: .maxVisibleSprites),
                maxPhysicsBodies: container.decode(Int.self, forKey: .maxPhysicsBodies),
                maxParticles: container.decode(Int.self, forKey: .maxParticles)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .targetFramesPerSecond, in: container, debugDescription: "Invalid Forge2D performance budget")
        }
    }
}
