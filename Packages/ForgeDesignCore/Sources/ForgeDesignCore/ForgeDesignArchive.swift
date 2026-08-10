import Foundation

public struct DesignDNAArchive: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let snapshots: [DesignDNA]
    public let changeRecords: [DesignDNAChangeRecord]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        snapshots: [DesignDNA],
        changeRecords: [DesignDNAChangeRecord] = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeDesignValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard snapshots.count <= ForgeDesignLimits.maximumArchiveSnapshots else {
            throw ForgeDesignValidationError.archiveTooLarge(snapshots.count)
        }
        let expectedRecordCount = max(0, snapshots.count - 1)
        guard changeRecords.count == expectedRecordCount else {
            throw ForgeDesignValidationError.invalidArchiveTransition(
                "archive requires exactly one durable change record per adjacent snapshot"
            )
        }

        self.schemaVersion = schemaVersion
        guard let first = snapshots.first else {
            self.snapshots = []
            self.changeRecords = []
            return
        }

        for snapshot in snapshots where snapshot.projectID != first.projectID {
            throw ForgeDesignValidationError.projectIdentityMismatch
        }
        for index in changeRecords.indices {
            try Self.validateTransitionRecord(
                changeRecords[index],
                from: snapshots[index],
                to: snapshots[index + 1]
            )
        }
        self.snapshots = snapshots
        self.changeRecords = changeRecords
    }

    static func validatedTransitionKind(
        from before: DesignDNA,
        to after: DesignDNA
    ) throws -> DesignDNATransitionKind {
        guard before.projectID == after.projectID else {
            throw ForgeDesignValidationError.projectIdentityMismatch
        }
        let (expectedRevision, overflow) = before.revision.addingReportingOverflow(1)
        guard !overflow else { throw ForgeDesignValidationError.revisionOverflow }
        guard after.revision == expectedRevision else {
            throw ForgeDesignValidationError.revisionMustAdvance
        }
        guard after.updatedAt >= before.updatedAt else {
            throw ForgeDesignValidationError.invalidArchiveTransition("transition timestamp moved backwards")
        }
        guard after.lastChangeReceiptID != before.lastChangeReceiptID else {
            throw ForgeDesignValidationError.invalidArchiveTransition("transition must carry a distinct change receipt")
        }

        var changes: [DesignDNATransitionKind] = []
        if before.intentCore != after.intentCore { changes.append(.replaceIntentCore) }

        func collect<ID: Hashable & Sendable, Value: Equatable>(
            before: [ID: Value],
            after: [ID: Value],
            add: (ID) -> DesignDNATransitionKind,
            update: (ID) -> DesignDNATransitionKind,
            remove: (ID) -> DesignDNATransitionKind
        ) {
            let keys = Set(before.keys).union(after.keys)
            for key in keys {
                switch (before[key], after[key]) {
                case (nil, .some): changes.append(add(key))
                case (.some, nil): changes.append(remove(key))
                case let (.some(lhs), .some(rhs)) where lhs != rhs: changes.append(update(key))
                default: break
                }
            }
        }

        collect(
            before: Dictionary(uniqueKeysWithValues: before.rules.map { ($0.id, $0) }),
            after: Dictionary(uniqueKeysWithValues: after.rules.map { ($0.id, $0) }),
            add: DesignDNATransitionKind.addRule,
            update: DesignDNATransitionKind.updateRule,
            remove: DesignDNATransitionKind.removeRule
        )
        collect(
            before: Dictionary(uniqueKeysWithValues: before.protectedComponents.map { ($0.id, $0) }),
            after: Dictionary(uniqueKeysWithValues: after.protectedComponents.map { ($0.id, $0) }),
            add: DesignDNATransitionKind.addProtectedComponent,
            update: DesignDNATransitionKind.updateProtectedComponent,
            remove: DesignDNATransitionKind.removeProtectedComponent
        )
        collect(
            before: Dictionary(uniqueKeysWithValues: before.neverRules.map { ($0.id, $0) }),
            after: Dictionary(uniqueKeysWithValues: after.neverRules.map { ($0.id, $0) }),
            add: DesignDNATransitionKind.addNeverRule,
            update: DesignDNATransitionKind.updateNeverRule,
            remove: DesignDNATransitionKind.removeNeverRule
        )
        guard changes.count == 1, let change = changes.first else {
            throw ForgeDesignValidationError.invalidArchiveTransition(
                "expected exactly one durable semantic change, found \(changes.count)"
            )
        }
        return change
    }

    static func validateTransitionRecord(
        _ record: DesignDNAChangeRecord,
        from before: DesignDNA,
        to after: DesignDNA
    ) throws {
        guard record.projectID == before.projectID, after.projectID == before.projectID else {
            throw ForgeDesignValidationError.projectIdentityMismatch
        }
        guard record.fromRevision == before.revision,
              record.toRevision == after.revision else {
            throw ForgeDesignValidationError.invalidArchiveTransition(
                "change record revision subject does not match adjacent snapshots"
            )
        }
        guard record.changeReceiptID == after.lastChangeReceiptID else {
            throw ForgeDesignValidationError.invalidArchiveTransition(
                "change record receipt does not match resulting snapshot"
            )
        }
        guard record.acceptedAt == after.updatedAt else {
            throw ForgeDesignValidationError.invalidArchiveTransition(
                "change record timestamp does not match resulting snapshot"
            )
        }

        let actualKind = try validatedTransitionKind(from: before, to: after)
        guard record.kind == actualKind else {
            throw ForgeDesignValidationError.invalidArchiveTransition(
                "change record kind/target does not match adjacent snapshots"
            )
        }

        switch actualKind {
        case .replaceIntentCore:
            guard record.provenance.kind.isUserAuthority
                    || record.provenance.kind == .acceptedSourceCheckpoint else {
                throw ForgeDesignValidationError.userAuthorityRequired("replaceIntentCore")
            }

        case .addRule(let id):
            guard let rule = after.rules.first(where: { $0.id == id }),
                  record.provenance == rule.provenance else {
                throw ForgeDesignValidationError.invalidArchiveTransition(
                    "rule change record provenance does not match resulting rule"
                )
            }

        case .updateRule(let id):
            guard let prior = before.rules.first(where: { $0.id == id }),
                  let replacement = after.rules.first(where: { $0.id == id }),
                  record.provenance == replacement.provenance else {
                throw ForgeDesignValidationError.invalidArchiveTransition(
                    "rule update record does not match adjacent snapshots"
                )
            }
            if prior.protection == .protected && !record.provenance.kind.isUserAuthority {
                throw ForgeDesignValidationError.protectedRuleMutationRequiresUserAuthority(id)
            }

        case .removeRule(let id):
            guard record.provenance.kind.isUserAuthority else {
                throw ForgeDesignValidationError.userAuthorityRequired("removeRule")
            }
            guard before.rules.contains(where: { $0.id == id }) else {
                throw ForgeDesignValidationError.invalidArchiveTransition("removed rule is absent from prior snapshot")
            }

        case .addProtectedComponent(let id):
            guard let component = after.protectedComponents.first(where: { $0.id == id }),
                  record.provenance == component.provenance else {
                throw ForgeDesignValidationError.invalidArchiveTransition(
                    "component change record provenance does not match resulting component"
                )
            }

        case .updateProtectedComponent(let id):
            guard let component = after.protectedComponents.first(where: { $0.id == id }),
                  record.provenance == component.provenance else {
                throw ForgeDesignValidationError.invalidArchiveTransition(
                    "component update record does not match resulting component"
                )
            }
            guard record.provenance.kind.isUserAuthority else {
                throw ForgeDesignValidationError.protectedComponentMutationRequiresUserAuthority(id)
            }

        case .removeProtectedComponent(let id):
            guard record.provenance.kind.isUserAuthority else {
                throw ForgeDesignValidationError.userAuthorityRequired("unprotectComponent")
            }
            guard before.protectedComponents.contains(where: { $0.id == id }) else {
                throw ForgeDesignValidationError.invalidArchiveTransition("removed component is absent from prior snapshot")
            }

        case .addNeverRule(let id), .updateNeverRule(let id):
            guard let rule = after.neverRules.first(where: { $0.id == id }),
                  record.provenance == rule.provenance,
                  record.provenance.kind.isUserAuthority else {
                throw ForgeDesignValidationError.neverRuleRequiresUserDecision(id)
            }

        case .removeNeverRule(let id):
            guard record.provenance.kind.isUserAuthority else {
                throw ForgeDesignValidationError.userAuthorityRequired("removeNeverRule")
            }
            guard before.neverRules.contains(where: { $0.id == id }) else {
                throw ForgeDesignValidationError.invalidArchiveTransition("removed Never rule is absent from prior snapshot")
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            snapshots: container.decode([DesignDNA].self, forKey: .snapshots),
            changeRecords: container.decodeIfPresent([DesignDNAChangeRecord].self, forKey: .changeRecords) ?? []
        )
    }
}
