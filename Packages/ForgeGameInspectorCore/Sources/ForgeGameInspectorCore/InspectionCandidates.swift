import Foundation

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
        if let unit { try ForgeGameInspectionTarget.validateIdentity(unit, field: "tunableUnit") }
        let values = [currentValue, minimumValue, maximumValue] + (step.map { [$0] } ?? [])
        guard values.allSatisfy(\.isFinite) else { throw ForgeGameInspectorError.nonFiniteNumber }
        guard minimumValue <= currentValue,
              currentValue <= maximumValue,
              minimumValue < maximumValue,
              step.map({ $0 > 0 && $0 <= (maximumValue - minimumValue) }) ?? true
        else { throw ForgeGameInspectorError.invalidTunableRange }

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
    public static let maximumTunableCount = 64

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
            guard parentID != id else { throw ForgeGameInspectorError.invalidIdentity("parentEntityID") }
        }
        try ForgeGameInspectionTarget.validateIdentity(displayName, field: "entityDisplayName")
        guard tunables.count <= Self.maximumTunableCount else { throw ForgeGameInspectorError.tooManyTunables }
        let duplicateTunable = Dictionary(grouping: tunables, by: \.id).first { $0.value.count > 1 }?.key
        if let duplicateTunable { throw ForgeGameInspectorError.duplicateTunableID(duplicateTunable) }

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
        var tunablesContainer = try container.nestedUnkeyedContainer(forKey: .tunables)
        var decodedTunables: [ForgePhysicsTunableCandidate] = []
        decodedTunables.reserveCapacity(min(tunablesContainer.count ?? 0, Self.maximumTunableCount))
        while !tunablesContainer.isAtEnd {
            guard decodedTunables.count < Self.maximumTunableCount else { throw ForgeGameInspectorError.tooManyTunables }
            decodedTunables.append(try tunablesContainer.decode(ForgePhysicsTunableCandidate.self))
        }

        try self.init(
            id: container.decode(String.self, forKey: .id),
            parentID: container.decodeIfPresent(String.self, forKey: .parentID),
            kind: container.decode(ForgeGameEntityKind.self, forKey: .kind),
            displayName: container.decode(String.self, forKey: .displayName),
            normalizedBounds: container.decodeIfPresent(ForgeGameNormalizedRect.self, forKey: .normalizedBounds),
            source: container.decode(ForgeGameSourceAssociation.self, forKey: .source),
            tunables: decodedTunables
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
        guard schemaVersion == Self.currentSchemaVersion else { throw ForgeGameInspectorError.invalidIdentity("schemaVersion") }
        guard entities.count <= Self.maximumEntityCount else { throw ForgeGameInspectorError.tooManyEntities }
        guard (reportedProducer == nil) == (reportedProducerReceiptID == nil) else {
            throw ForgeGameInspectorError.incompleteReportedProducerMetadata
        }
        if let reportedProducer { try ForgeGameInspectionTarget.validateIdentity(reportedProducer, field: "reportedProducer") }
        if let reportedProducerReceiptID {
            try ForgeGameInspectionTarget.validateIdentity(reportedProducerReceiptID, field: "reportedProducerReceiptID")
        }

        let grouped = Dictionary(grouping: entities, by: \.id)
        if let duplicate = grouped.first(where: { $0.value.count > 1 })?.key {
            throw ForgeGameInspectorError.duplicateEntityID(duplicate)
        }
        let ids = Set(entities.map(\.id))
        for entity in entities {
            if let parentID = entity.parentID, !ids.contains(parentID) { throw ForgeGameInspectorError.entityNotFound(parentID) }
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
        var entitiesContainer = try container.nestedUnkeyedContainer(forKey: .entities)
        var decodedEntities: [ForgeGameEntityCandidate] = []
        decodedEntities.reserveCapacity(min(entitiesContainer.count ?? 0, Self.maximumEntityCount))
        while !entitiesContainer.isAtEnd {
            guard decodedEntities.count < Self.maximumEntityCount else { throw ForgeGameInspectorError.tooManyEntities }
            decodedEntities.append(try entitiesContainer.decode(ForgeGameEntityCandidate.self))
        }

        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            target: container.decode(ForgeGameInspectionTarget.self, forKey: .target),
            entities: decodedEntities,
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
