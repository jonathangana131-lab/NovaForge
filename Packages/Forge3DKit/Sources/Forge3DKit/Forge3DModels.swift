import Foundation

public enum Forge3DOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
    case auto
}

public enum Forge3DSemanticCapability: String, Codable, CaseIterable, Sendable {
    case localSave
    case controller
    case touch
    case keyboard
    /// The generated artifact exposes deterministic semantic targets for a host-authorized runtime bridge.
    /// This does not grant runtime authority or prove that an interaction was delivered.
    case semanticAutomation
}

public struct Forge3DSemanticActionDescriptor: Equatable, Sendable {
    public let targetID: String
    public let minimumValue: Double
    public let maximumValue: Double
    public let neutralValue: Double

    init(targetID: String, minimumValue: Double, maximumValue: Double, neutralValue: Double) {
        self.targetID = targetID
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.neutralValue = neutralValue
    }
}

/// Starter-owned discoverability metadata for semantic runtime automation.
///
/// These IDs/ranges describe generated project surfaces only. ForgeRuntimeKit remains responsible for
/// session authorization, source-revision binding, interaction budgets, dispatch, and trusted evidence.
public struct Forge3DSemanticAutomationDescriptor: Equatable, Sendable {
    public let pauseControlID: String
    public let throttleAction: Forge3DSemanticActionDescriptor
    public let steeringAction: Forge3DSemanticActionDescriptor

    init(
        pauseControlID: String,
        throttleAction: Forge3DSemanticActionDescriptor,
        steeringAction: Forge3DSemanticActionDescriptor
    ) {
        self.pauseControlID = pauseControlID
        self.throttleAction = throttleAction
        self.steeringAction = steeringAction
    }
}

enum Forge3DSemanticContract {
    static let pauseControlID = "scene.pause-toggle"
    static let throttleActionID = "drive.throttle"
    static let steeringActionID = "drive.steer"
    static let minimumActionValue = -1.0
    static let maximumActionValue = 1.0
    static let neutralActionValue = 0.0

    static let descriptor = Forge3DSemanticAutomationDescriptor(
        pauseControlID: pauseControlID,
        throttleAction: .init(
            targetID: throttleActionID,
            minimumValue: minimumActionValue,
            maximumValue: maximumActionValue,
            neutralValue: neutralActionValue
        ),
        steeringAction: .init(
            targetID: steeringActionID,
            minimumValue: minimumActionValue,
            maximumValue: maximumActionValue,
            neutralValue: neutralActionValue
        )
    )
}

public struct Forge3DBlueprint: Codable, Equatable, Sendable {
    public var name: String
    public var slug: String
    public var orientation: Forge3DOrientation
    public var fieldOfViewDegrees: Double
    public var worldHalfExtent: Double
    public var maximumDevicePixelRatio: Double
    public var topSpeed: Double
    public var acceleration: Double
    public var steeringRate: Double
    public var persistenceKey: String

    public init(
        name: String,
        slug: String,
        orientation: Forge3DOrientation = .landscape,
        fieldOfViewDegrees: Double = 62,
        worldHalfExtent: Double = 80,
        maximumDevicePixelRatio: Double = 1.5,
        topSpeed: Double = 24,
        acceleration: Double = 14,
        steeringRate: Double = 1.65,
        persistenceKey: String? = nil
    ) {
        self.name = name
        self.slug = slug
        self.orientation = orientation
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.worldHalfExtent = worldHalfExtent
        self.maximumDevicePixelRatio = maximumDevicePixelRatio
        self.topSpeed = topSpeed
        self.acceleration = acceleration
        self.steeringRate = steeringRate
        self.persistenceKey = persistenceKey ?? "novaforge.\(slug).3d.save.v1"
    }
}

public enum Forge3DBlueprintIssue: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidName
    case invalidSlug
    case invalidFieldOfView
    case invalidWorldExtent
    case invalidRenderBudget
    case invalidTopSpeed
    case invalidAcceleration
    case invalidSteeringRate
    case invalidPersistenceKey

    public var description: String {
        switch self {
        case .invalidName: "Name must contain 1–80 visible characters."
        case .invalidSlug: "Slug must be 1–48 lowercase ASCII letters, digits, or interior hyphens."
        case .invalidFieldOfView: "Field of view must be finite and between 35° and 90°."
        case .invalidWorldExtent: "World half-extent must be finite and between 20 and 500 units."
        case .invalidRenderBudget: "Maximum device pixel ratio must be finite and between 1.0 and 2.0."
        case .invalidTopSpeed: "Top speed must be finite and between 2 and 120 units/s."
        case .invalidAcceleration: "Acceleration must be finite and between 1 and 80 units/s²."
        case .invalidSteeringRate: "Steering rate must be finite and between 0.2 and 4 radians/s."
        case .invalidPersistenceKey: "Persistence key must be a bounded printable ASCII storage key."
        }
    }
}

public enum Forge3DBlueprintValidator {
    public static func validate(_ blueprint: Forge3DBlueprint) throws {
        let trimmedName = blueprint.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 80,
              trimmedName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw Forge3DBlueprintIssue.invalidName
        }
        guard isValidSlug(blueprint.slug) else { throw Forge3DBlueprintIssue.invalidSlug }
        guard blueprint.fieldOfViewDegrees.isFinite, (35...90).contains(blueprint.fieldOfViewDegrees) else {
            throw Forge3DBlueprintIssue.invalidFieldOfView
        }
        guard blueprint.worldHalfExtent.isFinite, (20...500).contains(blueprint.worldHalfExtent) else {
            throw Forge3DBlueprintIssue.invalidWorldExtent
        }
        guard blueprint.maximumDevicePixelRatio.isFinite, (1...2).contains(blueprint.maximumDevicePixelRatio) else {
            throw Forge3DBlueprintIssue.invalidRenderBudget
        }
        guard blueprint.topSpeed.isFinite, (2...120).contains(blueprint.topSpeed) else {
            throw Forge3DBlueprintIssue.invalidTopSpeed
        }
        guard blueprint.acceleration.isFinite, (1...80).contains(blueprint.acceleration) else {
            throw Forge3DBlueprintIssue.invalidAcceleration
        }
        guard blueprint.steeringRate.isFinite, (0.2...4).contains(blueprint.steeringRate) else {
            throw Forge3DBlueprintIssue.invalidSteeringRate
        }
        guard isValidPersistenceKey(blueprint.persistenceKey) else {
            throw Forge3DBlueprintIssue.invalidPersistenceKey
        }
    }

    private static func isValidSlug(_ slug: String) -> Bool {
        guard (1...48).contains(slug.count), slug.first != "-", slug.last != "-" else { return false }
        return slug.utf8.allSatisfy { byte in
            (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
        }
    }

    private static func isValidPersistenceKey(_ key: String) -> Bool {
        guard (1...96).contains(key.utf8.count) else { return false }
        return key.utf8.allSatisfy { byte in
            byte >= 33 && byte <= 126 && byte != 34 && byte != 39 && byte != 92
        }
    }
}

public struct Forge3DGeneratedFile: Equatable, Sendable {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

public struct Forge3DGeneratedProject: Equatable, Sendable {
    public let blueprint: Forge3DBlueprint
    public let entryPath: String
    public let files: [Forge3DGeneratedFile]
    public let semanticCapabilities: Set<Forge3DSemanticCapability>
    public let semanticAutomation: Forge3DSemanticAutomationDescriptor?

    public init(
        blueprint: Forge3DBlueprint,
        entryPath: String,
        files: [Forge3DGeneratedFile],
        semanticCapabilities: Set<Forge3DSemanticCapability>,
        semanticAutomation: Forge3DSemanticAutomationDescriptor? = nil
    ) {
        var normalizedCapabilities = semanticCapabilities
        if semanticAutomation == nil {
            normalizedCapabilities.remove(.semanticAutomation)
        } else {
            normalizedCapabilities.insert(.semanticAutomation)
        }

        self.blueprint = blueprint
        self.entryPath = entryPath
        self.files = files
        self.semanticCapabilities = normalizedCapabilities
        self.semanticAutomation = semanticAutomation
    }
}
