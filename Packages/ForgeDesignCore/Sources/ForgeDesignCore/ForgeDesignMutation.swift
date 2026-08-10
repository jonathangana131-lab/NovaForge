import Foundation

public enum DesignDNAChange: Sendable {
    case replaceIntentCore(IntentCore, provenance: DesignProvenance)
    case upsertRule(DesignRule)
    case removeRule(DesignRuleID, authorization: DesignProvenance)
    case protectComponent(ProtectedDesignComponent)
    case unprotectComponent(ProtectedDesignComponentID, authorization: DesignProvenance)
    case addNeverRule(NeverRule)
    case removeNeverRule(NeverRuleID, authorization: DesignProvenance)
}

public enum DesignDNAUserMutationPurpose: Equatable, Sendable {
    case replaceIntentCore
    case protectRule(DesignRuleID)
    case mutateProtectedRule(DesignRuleID)
    case removeRule(DesignRuleID)
    case protectComponent(ProtectedDesignComponentID)
    case mutateProtectedComponent(ProtectedDesignComponentID)
    case unprotectComponent(ProtectedDesignComponentID)
    case addNeverRule(NeverRuleID)
    case mutateNeverRule(NeverRuleID)
    case removeNeverRule(NeverRuleID)

    var errorLabel: String {
        switch self {
        case .replaceIntentCore: "replaceIntentCore"
        case .protectRule: "protectRule"
        case .mutateProtectedRule: "mutateProtectedRule"
        case .removeRule: "removeRule"
        case .protectComponent: "protectComponent"
        case .mutateProtectedComponent: "mutateProtectedComponent"
        case .unprotectComponent: "unprotectComponent"
        case .addNeverRule: "addNeverRule"
        case .mutateNeverRule: "mutateNeverRule"
        case .removeNeverRule: "removeNeverRule"
        }
    }
}

public enum DesignDNATransitionKind: Codable, Equatable, Sendable {
    case replaceIntentCore
    case addRule(DesignRuleID)
    case updateRule(DesignRuleID)
    case removeRule(DesignRuleID)
    case addProtectedComponent(ProtectedDesignComponentID)
    case updateProtectedComponent(ProtectedDesignComponentID)
    case removeProtectedComponent(ProtectedDesignComponentID)
    case addNeverRule(NeverRuleID)
    case updateNeverRule(NeverRuleID)
    case removeNeverRule(NeverRuleID)

    func validated() throws -> Self {
        switch self {
        case .replaceIntentCore:
            self
        case .addRule(let id):
            .addRule(try validatedIdentifier(id, field: "changeRecord.kind.ruleID"))
        case .updateRule(let id):
            .updateRule(try validatedIdentifier(id, field: "changeRecord.kind.ruleID"))
        case .removeRule(let id):
            .removeRule(try validatedIdentifier(id, field: "changeRecord.kind.ruleID"))
        case .addProtectedComponent(let id):
            .addProtectedComponent(try validatedIdentifier(id, field: "changeRecord.kind.componentID"))
        case .updateProtectedComponent(let id):
            .updateProtectedComponent(try validatedIdentifier(id, field: "changeRecord.kind.componentID"))
        case .removeProtectedComponent(let id):
            .removeProtectedComponent(try validatedIdentifier(id, field: "changeRecord.kind.componentID"))
        case .addNeverRule(let id):
            .addNeverRule(try validatedIdentifier(id, field: "changeRecord.kind.neverRuleID"))
        case .updateNeverRule(let id):
            .updateNeverRule(try validatedIdentifier(id, field: "changeRecord.kind.neverRuleID"))
        case .removeNeverRule(let id):
            .removeNeverRule(try validatedIdentifier(id, field: "changeRecord.kind.neverRuleID"))
        }
    }
}

/// Durable, replayable description of one Design DNA revision transition.
///
/// This record is intentionally Codable: it survives relaunch and carries the exact change kind,
/// target, receipt and structural provenance that may disappear from the resulting snapshot (for
/// example, a removal). It is evidence metadata, not self-authenticating authority; accepted history
/// still requires a non-Codable `DesignDNATransitionTrustBinding` over this exact record and snapshots.
public struct DesignDNAChangeRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectID: DesignProjectID
    public let fromRevision: Int
    public let toRevision: Int
    public let kind: DesignDNATransitionKind
    public let changeReceiptID: DesignReceiptID
    public let provenance: DesignProvenance
    public let acceptedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        projectID: DesignProjectID,
        fromRevision: Int,
        toRevision: Int,
        kind: DesignDNATransitionKind,
        changeReceiptID: DesignReceiptID,
        provenance: DesignProvenance,
        acceptedAt: Date
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeDesignValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard fromRevision > 0 else { throw ForgeDesignValidationError.invalidRevision(fromRevision) }
        let (expectedRevision, overflow) = fromRevision.addingReportingOverflow(1)
        guard !overflow else { throw ForgeDesignValidationError.revisionOverflow }
        guard toRevision == expectedRevision else { throw ForgeDesignValidationError.revisionMustAdvance }

        self.schemaVersion = schemaVersion
        self.projectID = try validatedIdentifier(projectID, field: "changeRecord.projectID")
        self.fromRevision = fromRevision
        self.toRevision = toRevision
        self.kind = try kind.validated()
        self.changeReceiptID = try validatedIdentifier(changeReceiptID, field: "changeRecord.changeReceiptID")
        self.provenance = provenance
        self.acceptedAt = try validatedDate(acceptedAt, field: "changeRecord.acceptedAt")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            projectID: container.decode(DesignProjectID.self, forKey: .projectID),
            fromRevision: container.decode(Int.self, forKey: .fromRevision),
            toRevision: container.decode(Int.self, forKey: .toRevision),
            kind: container.decode(DesignDNATransitionKind.self, forKey: .kind),
            changeReceiptID: container.decode(DesignReceiptID.self, forKey: .changeReceiptID),
            provenance: container.decode(DesignProvenance.self, forKey: .provenance),
            acceptedAt: container.decode(Date.self, forKey: .acceptedAt)
        )
    }
}
