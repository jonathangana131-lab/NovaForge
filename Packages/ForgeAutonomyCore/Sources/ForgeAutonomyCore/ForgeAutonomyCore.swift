import Foundation
import ForgePlanCore

public enum ForgeAutonomyPolicyError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidBudget
    case invalidPolicy
    case invalidRequest
    case invalidApproval
}

public enum ForgeActionRisk: Int, CaseIterable, Codable, Comparable, Sendable {
    case r0ReadOnly = 0
    case r1ReversibleState = 1
    case r2ProjectMutation = 2
    case r3SensitiveOrRemote = 3
    case r4Unavailable = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ForgeActionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case readOnlyInspection
    case reversibleProjectState
    case projectSourceMutation
    case destructiveProjectMutation
    case credentialUse
    case remoteMutation
    case publish
    case unsupportedHostAuthority

    public var risk: ForgeActionRisk {
        switch self {
        case .readOnlyInspection:
            .r0ReadOnly
        case .reversibleProjectState:
            .r1ReversibleState
        case .projectSourceMutation:
            .r2ProjectMutation
        case .destructiveProjectMutation, .credentialUse, .remoteMutation, .publish:
            .r3SensitiveOrRemote
        case .unsupportedHostAuthority:
            .r4Unavailable
        }
    }
}

public enum ForgePrivacyMode: String, Codable, Sendable {
    case localOnly
    case approvedProviders
}

public enum ForgeWorkerLocality: Hashable, Codable, Sendable {
    case onDevice
    case hostedProvider(providerID: String)
}

public enum ForgeThermalLoad: Int, CaseIterable, Codable, Comparable, Sendable {
    case low = 0
    case moderate = 1
    case high = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ForgeAutonomyBudget: Hashable, Sendable {
    public let maxMutationFiles: Int
    public let maxWallClockSeconds: Int
    public let maxThermalLoad: ForgeThermalLoad

    public init(
        maxMutationFiles: Int,
        maxWallClockSeconds: Int,
        maxThermalLoad: ForgeThermalLoad
    ) throws {
        guard (0...10_000).contains(maxMutationFiles),
              (1...86_400).contains(maxWallClockSeconds) else {
            throw ForgeAutonomyPolicyError.invalidBudget
        }
        self.maxMutationFiles = maxMutationFiles
        self.maxWallClockSeconds = maxWallClockSeconds
        self.maxThermalLoad = maxThermalLoad
    }
}

public enum ForgeDecisionDependency: Hashable, Codable, Sendable {
    case none
    case accepted(receiptID: String)
    case unresolvedMaterial(decisionID: String)
}

public struct ForgeAutonomyPolicy: Hashable, Sendable {
    public let policyID: String
    public let revision: String
    public let projectID: String
    public let missionID: String
    public let autonomy: ForgeAutonomy
    public let privacyMode: ForgePrivacyMode
    public let approvedProviderIDs: Set<String>
    public let approvableHighRiskActions: Set<ForgeActionKind>
    public let budget: ForgeAutonomyBudget

    public init(
        policyID: String,
        revision: String,
        projectID: String,
        missionID: String,
        autonomy: ForgeAutonomy,
        privacyMode: ForgePrivacyMode,
        approvedProviderIDs: Set<String> = [],
        approvableHighRiskActions: Set<ForgeActionKind> = [],
        budget: ForgeAutonomyBudget
    ) throws {
        guard Self.isOpaqueIdentifier(policyID),
              Self.isOpaqueIdentifier(revision),
              Self.isOpaqueIdentifier(projectID),
              Self.isOpaqueIdentifier(missionID),
              approvedProviderIDs.allSatisfy(Self.isOpaqueIdentifier) else {
            throw ForgeAutonomyPolicyError.invalidIdentifier(field: "policy")
        }
        guard privacyMode != .localOnly || approvedProviderIDs.isEmpty,
              approvableHighRiskActions.allSatisfy({ $0.risk == .r3SensitiveOrRemote }) else {
            throw ForgeAutonomyPolicyError.invalidPolicy
        }
        self.policyID = policyID
        self.revision = revision
        self.projectID = projectID
        self.missionID = missionID
        self.autonomy = autonomy
        self.privacyMode = privacyMode
        self.approvedProviderIDs = approvedProviderIDs
        self.approvableHighRiskActions = approvableHighRiskActions
        self.budget = budget
    }

    public var automaticRiskCeiling: ForgeActionRisk {
        switch autonomy {
        case .ask:
            .r0ReadOnly
        case .assist:
            .r1ReversibleState
        case .build, .autopilot:
            .r2ProjectMutation
        }
    }

    public var allowsContinuousExecution: Bool {
        autonomy == .autopilot
    }

    fileprivate static func isOpaqueIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 96 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                true
            default:
                false
            }
        }
    }
}

/// A host-constructed authorization request. Resource fields are requested hard
/// allotments, not model-estimated usage; runtime/tool adapters must enforce the
/// granted limits while executing.
public struct ForgeAutonomyRequest: Hashable, Sendable {
    public let requestID: String
    public let projectID: String
    public let missionID: String
    public let scopeID: String
    public let action: ForgeActionKind
    public let workerLocality: ForgeWorkerLocality
    public let mutationFileLimit: Int
    public let requestedWallClockSeconds: Int
    public let requestedThermalLoad: ForgeThermalLoad
    public let decisionDependency: ForgeDecisionDependency

    public init(
        requestID: String,
        projectID: String,
        missionID: String,
        scopeID: String,
        action: ForgeActionKind,
        workerLocality: ForgeWorkerLocality = .onDevice,
        mutationFileLimit: Int = 0,
        requestedWallClockSeconds: Int = 1,
        requestedThermalLoad: ForgeThermalLoad = .low,
        decisionDependency: ForgeDecisionDependency = .none
    ) throws {
        guard ForgeAutonomyPolicy.isOpaqueIdentifier(requestID),
              ForgeAutonomyPolicy.isOpaqueIdentifier(projectID),
              ForgeAutonomyPolicy.isOpaqueIdentifier(missionID),
              ForgeAutonomyPolicy.isOpaqueIdentifier(scopeID),
              mutationFileLimit >= 0,
              requestedWallClockSeconds > 0 else {
            throw ForgeAutonomyPolicyError.invalidRequest
        }
        if case let .hostedProvider(providerID) = workerLocality,
           !ForgeAutonomyPolicy.isOpaqueIdentifier(providerID) {
            throw ForgeAutonomyPolicyError.invalidRequest
        }
        switch decisionDependency {
        case .none:
            break
        case let .accepted(receiptID):
            guard ForgeAutonomyPolicy.isOpaqueIdentifier(receiptID) else {
                throw ForgeAutonomyPolicyError.invalidRequest
            }
        case let .unresolvedMaterial(decisionID):
            guard ForgeAutonomyPolicy.isOpaqueIdentifier(decisionID) else {
                throw ForgeAutonomyPolicyError.invalidRequest
            }
        }
        self.requestID = requestID
        self.projectID = projectID
        self.missionID = missionID
        self.scopeID = scopeID
        self.action = action
        self.workerLocality = workerLocality
        self.mutationFileLimit = mutationFileLimit
        self.requestedWallClockSeconds = requestedWallClockSeconds
        self.requestedThermalLoad = requestedThermalLoad
        self.decisionDependency = decisionDependency
    }
}

public struct ForgeExplicitApproval: Hashable, Sendable {
    public let grantID: String
    public let policyID: String
    public let policyRevision: String
    public let request: ForgeAutonomyRequest

    public init(
        grantID: String,
        policyID: String,
        policyRevision: String,
        request: ForgeAutonomyRequest
    ) throws {
        guard [grantID, policyID, policyRevision]
            .allSatisfy(ForgeAutonomyPolicy.isOpaqueIdentifier) else {
            throw ForgeAutonomyPolicyError.invalidApproval
        }
        self.grantID = grantID
        self.policyID = policyID
        self.policyRevision = policyRevision
        self.request = request
    }

    fileprivate func exactlyMatches(policy: ForgeAutonomyPolicy, request: ForgeAutonomyRequest) -> Bool {
        policyID == policy.policyID &&
        policyRevision == policy.revision &&
        self.request == request
    }
}

public enum ForgeAuthorizationMode: Hashable, Codable, Sendable {
    case automatic
    case explicitApproval(grantID: String)
}

/// Authorization evidence only. It proves that the exact request crossed the
/// host-owned autonomy policy boundary; it never proves execution or success.
public struct ForgeAuthorizationReceipt: Hashable, Sendable {
    public let policyID: String
    public let policyRevision: String
    public let requestID: String
    public let projectID: String
    public let missionID: String
    public let scopeID: String
    public let action: ForgeActionKind
    public let mode: ForgeAuthorizationMode
}

/// Secret-free persistence/presentation form. Decoding this value never restores
/// authorization by itself; callers must revalidate it against the current
/// host-owned policy, exact request, and explicit approval when applicable.
public struct ForgeAuthorizationReceiptProjection: Hashable, Codable, Sendable {
    public let policyID: String
    public let policyRevision: String
    public let requestID: String
    public let projectID: String
    public let missionID: String
    public let scopeID: String
    public let action: ForgeActionKind
    public let mode: ForgeAuthorizationMode

    public init(receipt: ForgeAuthorizationReceipt) {
        policyID = receipt.policyID
        policyRevision = receipt.policyRevision
        requestID = receipt.requestID
        projectID = receipt.projectID
        missionID = receipt.missionID
        scopeID = receipt.scopeID
        action = receipt.action
        mode = receipt.mode
    }
}

public extension ForgeAuthorizationReceipt {
    var projection: ForgeAuthorizationReceiptProjection {
        ForgeAuthorizationReceiptProjection(receipt: self)
    }
}

public enum ForgeAutonomyDenial: Hashable, Codable, Sendable {
    case authorityIdentityMismatch
    case hostedProviderDenied
    case providerNotApproved(providerID: String)
    case unresolvedMaterialDecision(decisionID: String)
    case mutationFileBudgetExceeded(limit: Int)
    case wallClockBudgetExceeded(limitSeconds: Int)
    case thermalBudgetExceeded(limit: ForgeThermalLoad)
    case actionUnavailable
    case highRiskActionNotEnabled
    case approvalRequired
    case approvalDoesNotMatchExactRequest
    case receiptProjectionMismatch
}

public enum ForgeAutonomyDecision: Hashable, Sendable {
    case allowed(ForgeAuthorizationReceipt)
    case denied(ForgeAutonomyDenial)
}

public enum ForgeAutonomyEvaluator {
    public static func evaluate(
        policy: ForgeAutonomyPolicy,
        request: ForgeAutonomyRequest,
        approval: ForgeExplicitApproval? = nil
    ) -> ForgeAutonomyDecision {
        guard request.projectID == policy.projectID, request.missionID == policy.missionID else {
            return .denied(.authorityIdentityMismatch)
        }

        switch request.workerLocality {
        case .onDevice:
            break
        case let .hostedProvider(providerID):
            guard policy.privacyMode != .localOnly else {
                return .denied(.hostedProviderDenied)
            }
            guard policy.approvedProviderIDs.contains(providerID) else {
                return .denied(.providerNotApproved(providerID: providerID))
            }
        }

        if case let .unresolvedMaterial(decisionID) = request.decisionDependency {
            return .denied(.unresolvedMaterialDecision(decisionID: decisionID))
        }

        guard request.mutationFileLimit <= policy.budget.maxMutationFiles else {
            return .denied(.mutationFileBudgetExceeded(limit: policy.budget.maxMutationFiles))
        }
        guard request.requestedWallClockSeconds <= policy.budget.maxWallClockSeconds else {
            return .denied(.wallClockBudgetExceeded(limitSeconds: policy.budget.maxWallClockSeconds))
        }
        guard request.requestedThermalLoad <= policy.budget.maxThermalLoad else {
            return .denied(.thermalBudgetExceeded(limit: policy.budget.maxThermalLoad))
        }

        let risk = request.action.risk
        guard risk != .r4Unavailable else {
            return .denied(.actionUnavailable)
        }

        if risk <= policy.automaticRiskCeiling {
            return .allowed(receipt(policy: policy, request: request, mode: .automatic))
        }

        guard risk == .r3SensitiveOrRemote else {
            return .denied(.approvalRequired)
        }
        guard policy.approvableHighRiskActions.contains(request.action) else {
            return .denied(.highRiskActionNotEnabled)
        }
        guard let approval else {
            return .denied(.approvalRequired)
        }
        guard approval.exactlyMatches(policy: policy, request: request) else {
            return .denied(.approvalDoesNotMatchExactRequest)
        }

        return .allowed(
            receipt(
                policy: policy,
                request: request,
                mode: .explicitApproval(grantID: approval.grantID)
            )
        )
    }

    public static func revalidate(
        projection: ForgeAuthorizationReceiptProjection,
        policy: ForgeAutonomyPolicy,
        request: ForgeAutonomyRequest,
        approval: ForgeExplicitApproval? = nil
    ) -> ForgeAutonomyDecision {
        let current = evaluate(policy: policy, request: request, approval: approval)
        guard case let .allowed(receipt) = current, receipt.projection == projection else {
            return .denied(.receiptProjectionMismatch)
        }
        return .allowed(receipt)
    }

    private static func receipt(
        policy: ForgeAutonomyPolicy,
        request: ForgeAutonomyRequest,
        mode: ForgeAuthorizationMode
    ) -> ForgeAuthorizationReceipt {
        ForgeAuthorizationReceipt(
            policyID: policy.policyID,
            policyRevision: policy.revision,
            requestID: request.requestID,
            projectID: request.projectID,
            missionID: request.missionID,
            scopeID: request.scopeID,
            action: request.action,
            mode: mode
        )
    }
}
