import Foundation

public enum ForgeGameInspectorError: Error, Equatable, Sendable {
    case invalidIdentity(String)
    case invalidSourceAssociation
    case invalidBounds
    case duplicateEntityID(String)
    case duplicateTunableID(String)
    case tooManyEntities
    case tooManyTunables
    case invalidTunableRange
    case nonFiniteNumber
    case selectionTargetMismatch
    case entityNotFound(String)
    case tunableNotFound(String)
    case tuningOutOfRange
}

public struct ForgeGameInspectionTarget: Codable, Equatable, Hashable, Sendable {
    public let projectID: String
    public let sourceRevision: String
    public let runtimeSessionID: String
    public let runtimeVersion: String
    public let captureID: String
    public let frameSequence: UInt64

    public init(
        projectID: String,
        sourceRevision: String,
        runtimeSessionID: String,
        runtimeVersion: String,
        captureID: String,
        frameSequence: UInt64
    ) throws {
        try Self.validateIdentity(projectID, field: "projectID")
        try Self.validateIdentity(sourceRevision, field: "sourceRevision")
        try Self.validateIdentity(runtimeSessionID, field: "runtimeSessionID")
        try Self.validateIdentity(runtimeVersion, field: "runtimeVersion")
        try Self.validateIdentity(captureID, field: "captureID")

        self.projectID = projectID
        self.sourceRevision = sourceRevision
        self.runtimeSessionID = runtimeSessionID
        self.runtimeVersion = runtimeVersion
        self.captureID = captureID
        self.frameSequence = frameSequence
    }

    private enum CodingKeys: String, CodingKey {
        case projectID
        case sourceRevision
        case runtimeSessionID
        case runtimeVersion
        case captureID
        case frameSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            projectID: container.decode(String.self, forKey: .projectID),
            sourceRevision: container.decode(String.self, forKey: .sourceRevision),
            runtimeSessionID: container.decode(String.self, forKey: .runtimeSessionID),
            runtimeVersion: container.decode(String.self, forKey: .runtimeVersion),
            captureID: container.decode(String.self, forKey: .captureID),
            frameSequence: container.decode(UInt64.self, forKey: .frameSequence)
        )
    }

    static func validateIdentity(_ value: String, field: String) throws {
        guard !value.isEmpty,
              value.count <= 160,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeGameInspectorError.invalidIdentity(field)
        }
    }
}

public struct ForgeGameNormalizedRect: Codable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite) else {
            throw ForgeGameInspectorError.nonFiniteNumber
        }
        guard x >= 0, y >= 0, width >= 0, height >= 0,
              x <= 1, y <= 1, width <= 1, height <= 1,
              x + width <= 1.000_001,
              y + height <= 1.000_001
        else {
            throw ForgeGameInspectorError.invalidBounds
        }

        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y),
            width: container.decode(Double.self, forKey: .width),
            height: container.decode(Double.self, forKey: .height)
        )
    }
}

public struct ForgeGameSourceAssociation: Codable, Equatable, Hashable, Sendable {
    public let relativeFilePath: String
    public let symbolID: String?
    public let configKey: String?

    public init(relativeFilePath: String, symbolID: String? = nil, configKey: String? = nil) throws {
        guard Self.isSafeRelativePath(relativeFilePath) else {
            throw ForgeGameInspectorError.invalidSourceAssociation
        }
        if let symbolID {
            try ForgeGameInspectionTarget.validateIdentity(symbolID, field: "symbolID")
        }
        if let configKey {
            try ForgeGameInspectionTarget.validateIdentity(configKey, field: "configKey")
        }

        self.relativeFilePath = relativeFilePath
        self.symbolID = symbolID
        self.configKey = configKey
    }

    private enum CodingKeys: String, CodingKey { case relativeFilePath, symbolID, configKey }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relativeFilePath: container.decode(String.self, forKey: .relativeFilePath),
            symbolID: container.decodeIfPresent(String.self, forKey: .symbolID),
            configKey: container.decodeIfPresent(String.self, forKey: .configKey)
        )
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 512,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}

public enum ForgeGameEntityKind: String, Codable, CaseIterable, Sendable {
    case sceneObject
    case hud
    case control
    case camera
    case light
    case collider
    case physicsBody
    case particleEmitter
    case audioEmitter
    case other
}

public enum ForgePhysicsTunableKind: String, Codable, CaseIterable, Sendable {
    case gravity
    case mass
    case friction
    case restitution
    case linearDamping
    case angularDamping
    case steeringRate
    case driveTorque
    case brakeForce
    case suspensionStiffness
    case suspensionDamping
    case cameraFOV
    case custom
}

public struct ForgePhysicsTunableCandidate: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: ForgePhysicsTunableKind
    public let label: String
    public let unit: String?
    public let currentValue: Double
    public let minimumValue: Double
    public let maximumValue: Double
    public let step: Double?
    public let source: ForgeGameSourceAssociation

    public init(
        id: String,
        kind: ForgePhysicsTunableKind,
        label: String,
        unit: String? = nil,
        currentValue: Double,
        minimumValue: Double,
        maximumValue: Double,
        step: Double? = nil,
        source: ForgeGameSourceAssociation
    ) throws {
        try ForgeGameInspectionTarget.validateIdentity(id, field: "tunableID")
        try ForgeGameInspectionTarget.validateIdentity(label, field: "tunableLabel")
        if let unit {
            try ForgeGameInspectionTarget.validateIdentity(unit, field: "tunableUnit")
        }
        let values = [currentValue, minimumValue, maximumValue] + (step.map { [$0] } ?? [])
        guard values.allSatisfy(\.isFinite) else {
            throw ForgeGameInspectorError.nonFiniteNumber
        }
        guard minimumValue <= currentValue,
              currentValue <= maximumValue,
              minimumValue < maximumValue,
              step.map({ $0 > 0 && $0 <= (maximumValue - minimumValue) }) ?? true
        else {
            throw ForgeGameInspectorError.invalidTunableRange
        }

        self.id = id
        self.kind = kind
        self.label = label
        self.unit = unit
        self.currentValue = currentValue
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.step = step
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, unit, currentValue, minimumValue, maximumValue, step, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            kind: container.decode(ForgePhysicsTunableKind.self, forKey: .kind),
            label: container.decode(String.self, forKey: .label),
            unit: container.decodeIfPresent(String.self, forKey: .unit),
            currentValue: container.decode(Double.self, forKey: .currentValue),
            minimumValue: container.decode(Double.self, forKey: .minimumValue),
            maximumValue: container.decode(Double.self, forKey: .maximumValue),
            step: container.decodeIfPresent(Double.self, forKey: .step),
            source: container.decode(ForgeGameSourceAssociation.self, forKey: .source)
        )
    }
}

public struct ForgeGameEntityCandidate: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let parentID: String?
    public let kind: ForgeGameEntityKind
    public let displayName: String
    public let normalizedBounds: ForgeGameNormalizedRect?
    public let source: ForgeGameSourceAssociation
    public let tunables: [ForgePhysicsTunableCandidate]

    public init(
        id: String,
        parentID: String? = nil,
        kind: ForgeGameEntityKind,
        displayName: String,
        normalizedBounds: ForgeGameNormalizedRect? = nil,
        source: ForgeGameSourceAssociation,
        tunables: [ForgePhysicsTunableCandidate] = []
    ) throws {
        try ForgeGameInspectionTarget.validateIdentity(id, field: "entityID")
        if let parentID {
            try ForgeGameInspectionTarget.validateIdentity(parentID, field: "parentEntityID")
            guard parentID != id else {
                throw ForgeGameInspectorError.invalidIdentity("parentEntityID")
            }
        }
        try ForgeGameInspectionTarget.validateIdentity(displayName, field: "entityDisplayName")
        guard tunables.count <= 64 else {
            throw ForgeGameInspectorError.tooManyTunables
        }
        let duplicateTunable = Dictionary(grouping: tunables, by: \.id).first { $0.value.count > 1 }?.key
        if let duplicateTunable {
            throw ForgeGameInspectorError.duplicateTunableID(duplicateTunable)
        }

        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.displayName = displayName
        self.normalizedBounds = normalizedBounds
        self.source = source
        self.tunables = tunables
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentID, kind, displayName, normalizedBounds, source, tunables
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            parentID: container.decodeIfPresent(String.self, forKey: .parentID),
            kind: container.decode(ForgeGameEntityKind.self, forKey: .kind),
            displayName: container.decode(String.self, forKey: .displayName),
            normalizedBounds: container.decodeIfPresent(ForgeGameNormalizedRect.self, forKey: .normalizedBounds),
            source: container.decode(ForgeGameSourceAssociation.self, forKey: .source),
            tunables: container.decode([ForgePhysicsTunableCandidate].self, forKey: .tunables)
        )
    }
}

public struct ForgeGameInspectionSnapshotCandidate: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumEntityCount = 2_048

    public let schemaVersion: Int
    public let target: ForgeGameInspectionTarget
    public let entities: [ForgeGameEntityCandidate]
    public let reportedProducer: String?
    public let reportedProducerReceiptID: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        target: ForgeGameInspectionTarget,
        entities: [ForgeGameEntityCandidate],
        reportedProducer: String? = nil,
        reportedProducerReceiptID: String? = nil
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeGameInspectorError.invalidIdentity("schemaVersion")
        }
        guard entities.count <= Self.maximumEntityCount else {
            throw ForgeGameInspectorError.tooManyEntities
        }
        if let reportedProducer {
            try ForgeGameInspectionTarget.validateIdentity(reportedProducer, field: "reportedProducer")
        }
        if let reportedProducerReceiptID {
            try ForgeGameInspectionTarget.validateIdentity(reportedProducerReceiptID, field: "reportedProducerReceiptID")
        }

        let grouped = Dictionary(grouping: entities, by: \.id)
        if let duplicate = grouped.first(where: { $0.value.count > 1 })?.key {
            throw ForgeGameInspectorError.duplicateEntityID(duplicate)
        }
        let ids = Set(entities.map(\.id))
        for entity in entities {
            if let parentID = entity.parentID, !ids.contains(parentID) {
                throw ForgeGameInspectorError.entityNotFound(parentID)
            }
        }
        try Self.validateAcyclicHierarchy(entities)

        self.schemaVersion = schemaVersion
        self.target = target
        self.entities = entities
        self.reportedProducer = reportedProducer
        self.reportedProducerReceiptID = reportedProducerReceiptID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, target, entities, reportedProducer, reportedProducerReceiptID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            target: container.decode(ForgeGameInspectionTarget.self, forKey: .target),
            entities: container.decode([ForgeGameEntityCandidate].self, forKey: .entities),
            reportedProducer: container.decodeIfPresent(String.self, forKey: .reportedProducer),
            reportedProducerReceiptID: container.decodeIfPresent(String.self, forKey: .reportedProducerReceiptID)
        )
    }

    private static func validateAcyclicHierarchy(_ entities: [ForgeGameEntityCandidate]) throws {
        let parentByID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0.parentID) })
        var fullyVisited = Set<String>()

        for entity in entities where !fullyVisited.contains(entity.id) {
            var currentID: String? = entity.id
            var path = Set<String>()

            while let nodeID = currentID, !fullyVisited.contains(nodeID) {
                guard path.insert(nodeID).inserted else {
                    throw ForgeGameInspectorError.invalidIdentity("entityHierarchyCycle")
                }
                currentID = parentByID[nodeID] ?? nil
            }

            fullyVisited.formUnion(path)
        }
    }
}

public struct ForgeGameEntitySelectionCandidate: Codable, Equatable, Hashable, Sendable {
    public let target: ForgeGameInspectionTarget
    public let entityID: String

    public init(target: ForgeGameInspectionTarget, entityID: String) throws {
        try ForgeGameInspectionTarget.validateIdentity(entityID, field: "entityID")
        self.target = target
        self.entityID = entityID
    }

    private enum CodingKeys: String, CodingKey { case target, entityID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            target: container.decode(ForgeGameInspectionTarget.self, forKey: .target),
            entityID: container.decode(String.self, forKey: .entityID)
        )
    }
}

public struct ForgePhysicsTuningProposalCandidate: Codable, Equatable, Sendable {
    public let target: ForgeGameInspectionTarget
    public let entityID: String
    public let tunableID: String
    public let proposedValue: Double

    public init(
        target: ForgeGameInspectionTarget,
        entityID: String,
        tunableID: String,
        proposedValue: Double
    ) throws {
        try ForgeGameInspectionTarget.validateIdentity(entityID, field: "entityID")
        try ForgeGameInspectionTarget.validateIdentity(tunableID, field: "tunableID")
        guard proposedValue.isFinite else {
            throw ForgeGameInspectorError.nonFiniteNumber
        }
        self.target = target
        self.entityID = entityID
        self.tunableID = tunableID
        self.proposedValue = proposedValue
    }

    private enum CodingKeys: String, CodingKey { case target, entityID, tunableID, proposedValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            target: container.decode(ForgeGameInspectionTarget.self, forKey: .target),
            entityID: container.decode(String.self, forKey: .entityID),
            tunableID: container.decode(String.self, forKey: .tunableID),
            proposedValue: container.decode(Double.self, forKey: .proposedValue)
        )
    }
}

public enum ForgeGameInspectorCandidateResolver {
    public static func resolve(
        selection: ForgeGameEntitySelectionCandidate,
        in snapshot: ForgeGameInspectionSnapshotCandidate
    ) throws -> ForgeGameEntityCandidate {
        guard selection.target == snapshot.target else {
            throw ForgeGameInspectorError.selectionTargetMismatch
        }
        guard let entity = snapshot.entities.first(where: { $0.id == selection.entityID }) else {
            throw ForgeGameInspectorError.entityNotFound(selection.entityID)
        }
        return entity
    }

    public static func resolve(
        tuning proposal: ForgePhysicsTuningProposalCandidate,
        in snapshot: ForgeGameInspectionSnapshotCandidate
    ) throws -> ForgePhysicsTunableCandidate {
        guard proposal.target == snapshot.target else {
            throw ForgeGameInspectorError.selectionTargetMismatch
        }
        guard let entity = snapshot.entities.first(where: { $0.id == proposal.entityID }) else {
            throw ForgeGameInspectorError.entityNotFound(proposal.entityID)
        }
        guard let tunable = entity.tunables.first(where: { $0.id == proposal.tunableID }) else {
            throw ForgeGameInspectorError.tunableNotFound(proposal.tunableID)
        }
        guard proposal.proposedValue >= tunable.minimumValue,
              proposal.proposedValue <= tunable.maximumValue
        else {
            throw ForgeGameInspectorError.tuningOutOfRange
        }
        return tunable
    }
}
