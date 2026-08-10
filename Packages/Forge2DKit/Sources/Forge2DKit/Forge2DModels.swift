import Foundation

public enum Forge2DOrientation: String, Codable, CaseIterable, Sendable {
    case portrait
    case landscape
    case auto
}

public enum Forge2DSemanticCapability: String, Codable, CaseIterable, Sendable {
    case localSave
    case audio
    case controller
    case touch
    case keyboard
    case automation
}

/// Starter-owned description of the canonical Runtime semantic interaction needed to drive a
/// generated target. This is discovery metadata only; it grants no Runtime authorization and is
/// not execution/completion evidence.
public enum Forge2DSemanticInteractionKind: String, Codable, CaseIterable, Sendable {
    case controlActivate = "control.activate"
    case actionSetValue = "action.set-value"
}

public struct Forge2DSemanticTarget: Codable, Equatable, Sendable {
    public let id: String
    public let interactionKind: Forge2DSemanticInteractionKind
    public let minimumValue: Double?
    public let neutralValue: Double?
    public let maximumValue: Double?

    public init(
        id: String,
        interactionKind: Forge2DSemanticInteractionKind,
        minimumValue: Double? = nil,
        neutralValue: Double? = nil,
        maximumValue: Double? = nil
    ) {
        self.id = id
        self.interactionKind = interactionKind
        self.minimumValue = minimumValue
        self.neutralValue = neutralValue
        self.maximumValue = maximumValue
    }
}

/// Stable target IDs emitted into generated markup and consumed through Forge Runtime's canonical
/// `data-novaforge-*` contract. Values are intentionally bounded and deterministic so autonomous
/// personas can discover the starter's controls without guessing DOM IDs.
public enum Forge2DSelfPlayContract {
    public static let pauseTargetID = "pause"
    public static let jumpTargetID = "jump"
    public static let moveXTargetID = "move-x"

    public static let targets: [Forge2DSemanticTarget] = [
        .init(id: pauseTargetID, interactionKind: .controlActivate),
        .init(id: jumpTargetID, interactionKind: .controlActivate),
        .init(
            id: moveXTargetID,
            interactionKind: .actionSetValue,
            minimumValue: -1,
            neutralValue: 0,
            maximumValue: 1
        ),
    ]
}

public struct Forge2DBlueprint: Codable, Equatable, Sendable {
    public var name: String
    public var slug: String
    public var orientation: Forge2DOrientation
    public var viewportWidth: Int
    public var viewportHeight: Int
    public var worldWidth: Int
    public var worldHeight: Int
    public var gravity: Double
    public var persistenceKey: String

    public init(
        name: String,
        slug: String,
        orientation: Forge2DOrientation = .landscape,
        viewportWidth: Int = 960,
        viewportHeight: Int = 540,
        worldWidth: Int = 2400,
        worldHeight: Int = 1080,
        gravity: Double = 1_650,
        persistenceKey: String? = nil
    ) {
        self.name = name
        self.slug = slug
        self.orientation = orientation
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.worldWidth = worldWidth
        self.worldHeight = worldHeight
        self.gravity = gravity
        self.persistenceKey = persistenceKey ?? "novaforge.\(slug).save.v1"
    }
}

public enum Forge2DBlueprintIssue: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidName
    case invalidSlug
    case invalidViewport
    case invalidWorld
    case worldSmallerThanViewport
    case invalidGravity
    case invalidPersistenceKey

    public var description: String {
        switch self {
        case .invalidName: "Name must contain 1–80 visible characters."
        case .invalidSlug: "Slug must be 1–48 lowercase ASCII letters, digits, or interior hyphens."
        case .invalidViewport: "Viewport must be between 240×240 and 2,048×2,048."
        case .invalidWorld: "World must be between 320×320 and 16,384×16,384."
        case .worldSmallerThanViewport: "World cannot be smaller than the logical viewport."
        case .invalidGravity: "Gravity must be finite and between 0 and 8,000 points/s²."
        case .invalidPersistenceKey: "Persistence key must be a bounded printable ASCII storage key."
        }
    }
}

public enum Forge2DBlueprintValidator {
    public static func validate(_ blueprint: Forge2DBlueprint) throws {
        let trimmedName = blueprint.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 80,
              trimmedName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw Forge2DBlueprintIssue.invalidName
        }

        guard isValidSlug(blueprint.slug) else { throw Forge2DBlueprintIssue.invalidSlug }
        guard (240...2_048).contains(blueprint.viewportWidth),
              (240...2_048).contains(blueprint.viewportHeight) else {
            throw Forge2DBlueprintIssue.invalidViewport
        }
        guard (320...16_384).contains(blueprint.worldWidth),
              (320...16_384).contains(blueprint.worldHeight) else {
            throw Forge2DBlueprintIssue.invalidWorld
        }
        guard blueprint.worldWidth >= blueprint.viewportWidth,
              blueprint.worldHeight >= blueprint.viewportHeight else {
            throw Forge2DBlueprintIssue.worldSmallerThanViewport
        }
        guard blueprint.gravity.isFinite, (0...8_000).contains(blueprint.gravity) else {
            throw Forge2DBlueprintIssue.invalidGravity
        }
        guard isValidPersistenceKey(blueprint.persistenceKey) else {
            throw Forge2DBlueprintIssue.invalidPersistenceKey
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

public struct Forge2DGeneratedFile: Equatable, Sendable {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

public struct Forge2DGeneratedProject: Equatable, Sendable {
    public let blueprint: Forge2DBlueprint
    public let entryPath: String
    public let files: [Forge2DGeneratedFile]
    public let semanticCapabilities: Set<Forge2DSemanticCapability>
    public let semanticTargets: [Forge2DSemanticTarget]

    public init(
        blueprint: Forge2DBlueprint,
        entryPath: String,
        files: [Forge2DGeneratedFile],
        semanticCapabilities: Set<Forge2DSemanticCapability>,
        semanticTargets: [Forge2DSemanticTarget] = []
    ) {
        self.blueprint = blueprint
        self.entryPath = entryPath
        self.files = files
        self.semanticCapabilities = semanticCapabilities
        self.semanticTargets = semanticTargets
    }
}
