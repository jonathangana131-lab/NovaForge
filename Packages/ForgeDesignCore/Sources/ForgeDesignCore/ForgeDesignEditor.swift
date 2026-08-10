import Foundation

public struct DesignDNAEditor: Sendable {
    public init() {}

    public func applying(
        _ change: DesignDNAChange,
        to current: DesignDNA,
        projectID: DesignProjectID,
        changeReceiptID: DesignReceiptID,
        acceptedAt: Date,
        userAuthority: DesignDNAUserMutationAuthority? = nil
    ) throws -> DesignDNA {
        let candidate = try candidateApplying(
            change,
            to: current,
            projectID: projectID,
            changeReceiptID: changeReceiptID,
            acceptedAt: acceptedAt
        )
        if let purpose = candidate.requiredUserAuthority {
            guard let userAuthority,
                  userAuthority.authorizes(
                    before: current,
                    after: candidate.snapshot,
                    record: candidate.changeRecord,
                    purpose: purpose
                  ) else {
                throw ForgeDesignValidationError.authenticatedUserAuthorityRequired(purpose.errorLabel)
            }
        }
        return candidate.snapshot
    }

    func candidateApplying(
        _ change: DesignDNAChange,
        to current: DesignDNA,
        projectID: DesignProjectID,
        changeReceiptID: DesignReceiptID,
        acceptedAt: Date
    ) throws -> (
        snapshot: DesignDNA,
        changeRecord: DesignDNAChangeRecord,
        requiredUserAuthority: DesignDNAUserMutationPurpose?
    ) {
        let validatedProjectID = try validatedIdentifier(projectID, field: "projectID")
        guard current.projectID == validatedProjectID else {
            throw ForgeDesignValidationError.projectIdentityMismatch
        }
        let receiptID = try validatedIdentifier(changeReceiptID, field: "changeReceiptID")
        let acceptedAt = try validatedDate(acceptedAt, field: "acceptedAt")
        guard acceptedAt >= current.updatedAt else {
            throw ForgeDesignValidationError.invalidArchiveTransition("transition timestamp moved backwards")
        }
        guard receiptID != current.lastChangeReceiptID else {
            throw ForgeDesignValidationError.invalidArchiveTransition("transition must carry a distinct change receipt")
        }
        let (nextRevision, overflow) = current.revision.addingReportingOverflow(1)
        guard !overflow else { throw ForgeDesignValidationError.revisionOverflow }

        var intentCore = current.intentCore
        var rules = current.rules
        var protectedComponents = current.protectedComponents
        var neverRules = current.neverRules
        var required: DesignDNAUserMutationPurpose?
        let recordProvenance: DesignProvenance

        switch change {
        case .replaceIntentCore(let replacement, let provenance):
            guard provenance.kind.isUserAuthority || provenance.kind == .acceptedSourceCheckpoint else {
                throw ForgeDesignValidationError.userAuthorityRequired("replaceIntentCore")
            }
            guard replacement != current.intentCore else {
                throw ForgeDesignValidationError.invalidArchiveTransition("replaceIntentCore must change durable intent")
            }
            if provenance.kind.isUserAuthority { required = .replaceIntentCore }
            intentCore = replacement
            recordProvenance = provenance

        case .upsertRule(let rule):
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                guard rules[index] != rule else {
                    throw ForgeDesignValidationError.invalidArchiveTransition("upsertRule must change durable rule")
                }
                if rules[index].protection == .protected {
                    guard rule.provenance.kind.isUserAuthority else {
                        throw ForgeDesignValidationError.protectedRuleMutationRequiresUserAuthority(rule.id)
                    }
                    required = .mutateProtectedRule(rule.id)
                } else if rule.protection == .protected && rule.provenance.kind.isUserAuthority {
                    required = .protectRule(rule.id)
                }
                rules[index] = rule
            } else {
                if rule.protection == .protected && rule.provenance.kind.isUserAuthority {
                    required = .protectRule(rule.id)
                }
                rules.append(rule)
            }
            recordProvenance = rule.provenance

        case .removeRule(let rawID, let authorization):
            guard authorization.kind.isUserAuthority else {
                throw ForgeDesignValidationError.userAuthorityRequired("removeRule")
            }
            let id = try validatedIdentifier(rawID, field: "removeRule.id")
            guard rules.contains(where: { $0.id == id }) else {
                throw ForgeDesignValidationError.invalidArchiveTransition("removeRule must remove an existing rule")
            }
            rules.removeAll { $0.id == id }
            required = .removeRule(id)
            recordProvenance = authorization

        case .protectComponent(let component):
            if let index = protectedComponents.firstIndex(where: { $0.id == component.id }) {
                guard protectedComponents[index] != component else {
                    throw ForgeDesignValidationError.invalidArchiveTransition("protectComponent must change durable component")
                }
                guard component.provenance.kind.isUserAuthority else {
                    throw ForgeDesignValidationError.protectedComponentMutationRequiresUserAuthority(component.id)
                }
                protectedComponents[index] = component
                required = .mutateProtectedComponent(component.id)
            } else {
                protectedComponents.append(component)
                if component.provenance.kind.isUserAuthority {
                    required = .protectComponent(component.id)
                }
            }
            recordProvenance = component.provenance

        case .unprotectComponent(let rawID, let authorization):
            guard authorization.kind.isUserAuthority else {
                throw ForgeDesignValidationError.userAuthorityRequired("unprotectComponent")
            }
            let id = try validatedIdentifier(rawID, field: "unprotectComponent.id")
            guard protectedComponents.contains(where: { $0.id == id }) else {
                throw ForgeDesignValidationError.invalidArchiveTransition("unprotectComponent must remove an existing component")
            }
            protectedComponents.removeAll { $0.id == id }
            required = .unprotectComponent(id)
            recordProvenance = authorization

        case .addNeverRule(let rule):
            if let index = neverRules.firstIndex(where: { $0.id == rule.id }) {
                guard neverRules[index] != rule else {
                    throw ForgeDesignValidationError.invalidArchiveTransition("addNeverRule must change durable rule")
                }
                neverRules[index] = rule
                required = .mutateNeverRule(rule.id)
            } else {
                neverRules.append(rule)
                required = .addNeverRule(rule.id)
            }
            recordProvenance = rule.provenance

        case .removeNeverRule(let rawID, let authorization):
            guard authorization.kind.isUserAuthority else {
                throw ForgeDesignValidationError.userAuthorityRequired("removeNeverRule")
            }
            let id = try validatedIdentifier(rawID, field: "removeNeverRule.id")
            guard neverRules.contains(where: { $0.id == id }) else {
                throw ForgeDesignValidationError.invalidArchiveTransition("removeNeverRule must remove an existing rule")
            }
            neverRules.removeAll { $0.id == id }
            required = .removeNeverRule(id)
            recordProvenance = authorization
        }

        let snapshot = try DesignDNA(
            projectID: current.projectID,
            revision: nextRevision,
            intentCore: intentCore,
            rules: rules,
            protectedComponents: protectedComponents,
            neverRules: neverRules,
            lastChangeReceiptID: receiptID,
            updatedAt: acceptedAt
        )
        let kind = try DesignDNAArchive.validatedTransitionKind(from: current, to: snapshot)
        let record = try DesignDNAChangeRecord(
            projectID: current.projectID,
            fromRevision: current.revision,
            toRevision: snapshot.revision,
            kind: kind,
            changeReceiptID: receiptID,
            provenance: recordProvenance,
            acceptedAt: acceptedAt
        )
        try DesignDNAArchive.validateTransitionRecord(record, from: current, to: snapshot)
        return (snapshot, record, required)
    }
}
