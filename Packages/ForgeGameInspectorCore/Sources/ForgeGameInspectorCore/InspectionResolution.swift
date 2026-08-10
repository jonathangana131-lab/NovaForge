import Foundation

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
        guard proposedValue.isFinite else { throw ForgeGameInspectorError.nonFiniteNumber }
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
        guard selection.target == snapshot.target else { throw ForgeGameInspectorError.selectionTargetMismatch }
        guard let entity = snapshot.entities.first(where: { $0.id == selection.entityID }) else {
            throw ForgeGameInspectorError.entityNotFound(selection.entityID)
        }
        return entity
    }

    public static func resolve(
        tuning proposal: ForgePhysicsTuningProposalCandidate,
        in snapshot: ForgeGameInspectionSnapshotCandidate
    ) throws -> ForgePhysicsTunableCandidate {
        guard proposal.target == snapshot.target else { throw ForgeGameInspectorError.selectionTargetMismatch }
        guard let entity = snapshot.entities.first(where: { $0.id == proposal.entityID }) else {
            throw ForgeGameInspectorError.entityNotFound(proposal.entityID)
        }
        guard let tunable = entity.tunables.first(where: { $0.id == proposal.tunableID }) else {
            throw ForgeGameInspectorError.tunableNotFound(proposal.tunableID)
        }
        guard proposal.proposedValue >= tunable.minimumValue,
              proposal.proposedValue <= tunable.maximumValue
        else { throw ForgeGameInspectorError.tuningOutOfRange }
        return tunable
    }
}
