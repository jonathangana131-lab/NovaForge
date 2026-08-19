import Foundation

extension Forge3DBlueprint {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: V14CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let slug = try container.decode(String.self, forKey: .slug)
        let orientation = try container.decode(Forge3DOrientation.self, forKey: .orientation)
        let fieldOfViewDegrees = try container.decode(Double.self, forKey: .fieldOfViewDegrees)
        let worldHalfExtent = try container.decode(Double.self, forKey: .worldHalfExtent)
        let maximumDevicePixelRatio = try container.decode(Double.self, forKey: .maximumDevicePixelRatio)
        let topSpeed = try container.decode(Double.self, forKey: .topSpeed)
        let acceleration = try container.decode(Double.self, forKey: .acceleration)
        let steeringRate = try container.decode(Double.self, forKey: .steeringRate)
        let persistenceKey = try container.decodeIfPresent(String.self, forKey: .persistenceKey)

        self.init(
            name: name,
            slug: slug,
            orientation: orientation,
            fieldOfViewDegrees: fieldOfViewDegrees,
            worldHalfExtent: worldHalfExtent,
            maximumDevicePixelRatio: maximumDevicePixelRatio,
            topSpeed: topSpeed,
            acceleration: acceleration,
            steeringRate: steeringRate,
            persistenceKey: persistenceKey
        )

        do {
            try Forge3DBlueprintValidator.validate(self)
        } catch let issue as Forge3DBlueprintIssue {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Forge3D blueprint: \(issue.description)",
                    underlyingError: issue
                )
            )
        }
    }

    private enum V14CodingKeys: String, CodingKey {
        case name
        case slug
        case orientation
        case fieldOfViewDegrees
        case worldHalfExtent
        case maximumDevicePixelRatio
        case topSpeed
        case acceleration
        case steeringRate
        case persistenceKey
    }
}
