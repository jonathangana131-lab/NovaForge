import Foundation

private enum DesignProvenanceCodingKeys: String, CodingKey { case kind, receiptID, recordedAt }
private enum IntentCoreCodingKeys: String, CodingKey { case productPromise, traits }
private enum DesignRuleCodingKeys: String, CodingKey { case id, category, statement, protection, provenance }
private enum ProtectedDesignComponentCodingKeys: String, CodingKey { case id, name, stableSourceIdentity, reason, provenance }
private enum NeverRuleCodingKeys: String, CodingKey { case id, instruction, scope, provenance }

public extension DesignProvenance {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DesignProvenanceCodingKeys.self)
        try self.init(
            kind: container.decode(DesignProvenanceKind.self, forKey: .kind),
            receiptID: container.decode(DesignReceiptID.self, forKey: .receiptID),
            recordedAt: container.decode(Date.self, forKey: .recordedAt)
        )
    }
}

public extension IntentCore {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: IntentCoreCodingKeys.self)
        try self.init(
            productPromise: container.decode(String.self, forKey: .productPromise),
            traits: container.decode([String].self, forKey: .traits)
        )
    }
}

public extension DesignRule {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DesignRuleCodingKeys.self)
        try self.init(
            id: container.decode(DesignRuleID.self, forKey: .id),
            category: container.decode(DesignRuleCategory.self, forKey: .category),
            statement: container.decode(String.self, forKey: .statement),
            protection: container.decode(DesignRuleProtection.self, forKey: .protection),
            provenance: container.decode(DesignProvenance.self, forKey: .provenance)
        )
    }
}

public extension ProtectedDesignComponent {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ProtectedDesignComponentCodingKeys.self)
        try self.init(
            id: container.decode(ProtectedDesignComponentID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            stableSourceIdentity: container.decode(String.self, forKey: .stableSourceIdentity),
            reason: container.decode(String.self, forKey: .reason),
            provenance: container.decode(DesignProvenance.self, forKey: .provenance)
        )
    }
}

public extension NeverRule {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NeverRuleCodingKeys.self)
        try self.init(
            id: container.decode(NeverRuleID.self, forKey: .id),
            instruction: container.decode(String.self, forKey: .instruction),
            scope: container.decode(NeverRuleScope.self, forKey: .scope),
            provenance: container.decode(DesignProvenance.self, forKey: .provenance)
        )
    }
}
