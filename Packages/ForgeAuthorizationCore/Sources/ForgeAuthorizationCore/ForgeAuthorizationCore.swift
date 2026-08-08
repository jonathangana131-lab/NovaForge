import Foundation
import ForgePlanCore

public enum ForgeAuthorizationError: Error, Equatable, Sendable {
    case invalidIdentifier(field: String)
    case invalidResourceLimits
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

public enum ForgeAuthorizationActionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case readOnlyInspection
    case reversibleProjectState
    case runtimeSemanticInteraction
    case runtimeRestart
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
        case .reversibleProjectState, .runtimeSemanticInteraction, .runtimeRestart:
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

public enum ForgeAuthorizationPrivacyMode: String, Codable, Sendable {
    case localOnly
    case approvedProviders
}

public enum ForgeWorkerLocality: Hashable, Codable, Sendable {
    case onDevice
    case hostedProvider(providerID: String)
}

public enum ForgeAuthorizationThermalLoad: Int, CaseIterable, Codable, Comparable, Sendable {
    case low = 0
    case moderate = 1
    case high = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Opaque projection of the canonical Mission Engine authority. This value does not mint mission state.
public struct ForgeAuthorizationAuthority: Hashable, Sendable {
    public let projectID: String
    public let missionID: String
    public let checkpointID: String
    public let missionRevision: UInt64
    public let authorityEpoch: UInt64

    public init(
        projectID: String,
        missionID: String,
        checkpointID: String,
        missionRevision: UInt64,
        authorityEpoch: UInt64
    ) throws {
        guard Self.isOpaqueIdentifier(projectID),
              Self.isOpaqueIdentifier(missionID),
              Self.isOpaqueIdentifier(checkpointID) else {
            throw ForgeAuthorizationError.invalidIdentifier(field: "authority")
        }
        self.projectID = projectID
        self.missionID = missionID
        self.checkpointID = checkpointID
        self.missionRevision = missionRevision
        self.authorityEpoch = authorityEpoch
    }

    fileprivate static func isOpaqueIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
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

/// Per-action host-enforced resource allotments. These are authorization caps, not measured usage claims.
public struct ForgeActionResourceLimits: Hashable, Sendable {
    public let maxMutationFiles: Int
    public let maxWallClockSeconds: Int
    public let maxThermalLoad: ForgeAuthorizationThermalLoad

    public init(
        maxMutationFiles: Int,
        maxWallClockSeconds: Int,
        maxThermalLoad: ForgeAuthorizationThermalLoad
    ) throws {
        guard (0...10_000).contains(maxMutationFiles),
              (1...86_400).contains(maxWallClockSeconds) else {
            throw ForgeAuthorizationError.invalidResourceLimits
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

/// Host-owned policy projected from accepted mission/user policy. `ForgeAutonomy` remains user intent;
/// this type is the separate authorization boundary that turns that intent into bounded permissions.
public struct ForgeAuthorizationPolicy: Hashable, Sendable {
    public let policyID: String
    public let revision: String
    public let authority: ForgeAuthorizationAuthority
    public let autonomy: ForgeAutonomy
    public let privacyMode: ForgeAuthorizationPrivacyMode
    public let approvedProviderIDs: Set<String>
    public let approvableHighRiskActions: Set<ForgeAuthorizationActionKind>
    public let resourceLimits: ForgeActionResourceLimits

    public init(
        policyID: String,
        revision: String,
        authority: ForgeAuthorizationAuthority,
        autonomy: ForgeAutonomy,
        privacyMode: ForgeAuthorizationPrivacyMode,
        approvedProviderIDs: Set<String> = [],
        approvableHighRiskActions: Set<ForgeAuthorizationActionKind> = [],
        resourceLimits: ForgeActionResourceLimits
    ) throws {
        guard ForgeAuthorizationAuthority.isOpaqueIdentifier(policyID),
              ForgeAuthorizationAuthority.isOpaqueIdentifier(revision),
              approvedProviderIDs.allSatisfy(ForgeAuthorizationAuthority.isOpaqueIdentifier) else {
            throw ForgeAuthorizationError.invalidIdentifier(field: "policy")
        }
        guard privacyMode != .localOnly || approvedProviderIDs.isEmpty,
              approvableHighRiskActions.allSatisfy({ $0.risk == .r3SensitiveOrRemote }) else {
            throw ForgeAuthorizationError.invalidPolicy
        }
        self.policyID = policyID
        self.revision = revision
        self.authority = authority
        self.autonomy = autonomy
        self.privacyMode = privacyMode
        self.approvedProviderIDs = approvedProviderIDs
        self.approvableHighRiskActions = approvableHighRiskActions
        self.resourceLimits = resourceLimits
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

    public var allowsContinuousExecutionIntent: Bool {
        autonomy == .autopilot
    }
}

/// Host-constructed authorization request. Resource fields are requested hard allotments; adapters
/// must enforce the granted limits while executing and must not reinterpret them as observed usage.
public struct ForgeAuthorizationRequest: Hashable, Sendable {
    public let requestID: String
    public let authority: ForgeAuthorizationAuthority
    public let scopeID: String
    public let action: ForgeAuthorizationActionKind
    public let workerLocality: ForgeWorkerLocality
    public let mutationFileLimit: Int
    public let requestedWallClockSeconds: Int
    public let requestedThermalLoad: ForgeAuthorizationThermalLoad
    public let decisionDependency: ForgeDecisionDependency

    public init(
        requestID: String,
        authority: ForgeAuthorizationAuthority,
        scopeID: String,
        action: ForgeAuthorizationActionKind,
        workerLocality: ForgeWorkerLocality = .onDevice,
        mutationFileLimit: Int = 0,
        requestedWallClockSeconds: Int = 1,
        requestedThermalLoad: ForgeAuthorizationThermalLoad = .low,
        decisionDependency: ForgeDecisionDependency = .none
    ) throws {
        guard ForgeAuthorizationAuthority.isOpaqueIdentifier(requestID),
              ForgeAuthorizationAuthority.isOpaqueIdentifier(scopeID),
              mutationFileLimit >= 0,
              requestedWallClockSeconds > 0 else {
            throw ForgeAuthorizationError.invalidRequest
        }
        if case let .hostedProvider(providerID) = workerLocality,
           !ForgeAuthorizationAuthority.isOpaqueIdentifier(providerID) {
            throw ForgeAuthorizationError.invalidRequest
        }
        switch decisionDependency {
        case .none:
            break
        case let .accepted(receiptID):
            guard ForgeAuthorizationAuthority.isOpaqueIdentifier(receiptID) else {
                throw ForgeAuthorizationError.invalidRequest
            }
        case let .unresolvedMaterial(decisionID):
            guard ForgeAuthorizationAuthority.isOpaqueIdentifier(decisionID) else {
                throw ForgeAuthorizationError.invalidRequest
            }
        }
        self.requestID = requestID
        self.authority = authority
        self.scopeID = scopeID
        self.action = action
        self.workerLocality = workerLocality
        self.mutationFileLimit = mutationFileLimit
        self.requestedWallClockSeconds = requestedWallClockSeconds
        self.requestedThermalLoad = requestedThermalLoad
        self.decisionDependency = decisionDependency
    }
}

/// Projection of an approval already authenticated by the canonical host approval authority.
/// This package deliberately does not verify UI signatures/Keychain secrets and cannot mint approval truth.
public struct ForgeAcceptedApproval: Hashable, Sendable {
    public let approvalReceiptID: String
    public let policyID: String
    public let policyRevision: String
    public let request: ForgeAuthorizationRequest

    public init(
        approvalReceiptID: String,
        policyID: String,
        policyRevision: String,
        request: ForgeAuthorizationRequest
    ) throws {
        guard [approvalReceiptID, policyID, policyRevision]
            .allSatisfy(ForgeAuthorizationAuthority.isOpaqueIdentifier) else {
            throw ForgeAuthorizationError.invalidApproval
        }
        self.approvalReceiptID = approvalReceiptID
        self.policyID = policyID
        self.policyRevision = policyRevision
        self.request = request
    }

    fileprivate func exactlyMatches(policy: ForgeAuthorizationPolicy, request: ForgeAuthorizationRequest) -> Bool {
        policyID == policy.policyID &&
        policyRevision == policy.revision &&
        self.request == request
    }
}

public enum ForgeAuthorizationMode: Hashable, Codable, Sendable {
    case automatic
    case acceptedApproval(receiptID: String)
}

/// Authorization evidence only. It proves that the exact request crossed the host-owned policy boundary;
/// it never proves execution, correctness, test success, or mission completion.
public struct ForgeAuthorizationReceipt: Hashable, Sendable {
    public let policyID: String
    public let policyRevision: String
    public let requestID: String
    public let authority: ForgeAuthorizationAuthority
    public let scopeID: String
    public let action: ForgeAuthorizationActionKind
    public let mode: ForgeAuthorizationMode
}

/// Secret-free persistence/presentation form. Decoding this value never restores authorization by itself;
/// callers must revalidate it against current host policy, exact authority/request, and accepted approval.
public struct ForgeAuthorizationReceiptProjection: Hashable, Codable, Sendable {
    public let policyID: String
    public let policyRevision: String
    public let requestID: String
    public let projectID: String
    public let missionID: String
    public let checkpointID: String
    public let missionRevision: UInt64
    public let authorityEpoch: UInt64
    public let scopeID: String
    public let action: ForgeAuthorizationActionKind
    public let mode: ForgeAuthorizationMode

    public init(receipt: ForgeAuthorizationReceipt) {
        policyID = receipt.policyID
        policyRevision = receipt.policyRevision
        requestID = receipt.requestID
        projectID = receipt.authority.projectID
        missionID = receipt.authority.missionID
        checkpointID = receipt.authority.checkpointID
        missionRevision = receipt.authority.missionRevision
        authorityEpoch = receipt.authority.authorityEpoch
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

public enum ForgeAuthorizationDenial: Hashable, Codable, Sendable {
    case authorityIdentityMismatch
    case hostedProviderDenied
    case providerNotApproved(providerID: String)
    case unresolvedMaterialDecision(decisionID: String)
    case mutationFileBudgetExceeded(limit: Int)
    case wallClockBudgetExceeded(limitSeconds: Int)
    case thermalBudgetExceeded(limit: ForgeAuthorizationThermalLoad)
    case actionUnavailable
    case highRiskActionNotEnabled
    case approvalRequired
    case approvalDoesNotMatchExactRequest
    case receiptProjectionMismatch
}

public enum ForgeAuthorizationDecision: Hashable, Sendable {
    case allowed(ForgeAuthorizationReceipt)
    case denied(ForgeAuthorizationDenial)
}

public enum ForgeAuthorizationEvaluator {
    public static func evaluate(
        policy: ForgeAuthorizationPolicy,
        request: ForgeAuthorizationRequest,
        approval: ForgeAcceptedApproval? = nil
    ) -> ForgeAuthorizationDecision {
        guard request.authority == policy.authority else {
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

        guard request.mutationFileLimit <= policy.resourceLimits.maxMutationFiles else {
            return .denied(.mutationFileBudgetExceeded(limit: policy.resourceLimits.maxMutationFiles))
        }
        guard request.requestedWallClockSeconds <= policy.resourceLimits.maxWallClockSeconds else {
            return .denied(.wallClockBudgetExceeded(limitSeconds: policy.resourceLimits.maxWallClockSeconds))
        }
        guard request.requestedThermalLoad <= policy.resourceLimits.maxThermalLoad else {
            return .denied(.thermalBudgetExceeded(limit: policy.resourceLimits.maxThermalLoad))
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
                mode: .acceptedApproval(receiptID: approval.approvalReceiptID)
            )
        )
    }

    public static func revalidate(
        projection: ForgeAuthorizationReceiptProjection,
        policy: ForgeAuthorizationPolicy,
        request: ForgeAuthorizationRequest,
        approval: ForgeAcceptedApproval? = nil
    ) -> ForgeAuthorizationDecision {
        let current = evaluate(policy: policy, request: request, approval: approval)
        guard case let .allowed(receipt) = current, receipt.projection == projection else {
            return .denied(.receiptProjectionMismatch)
        }
        return .allowed(receipt)
    }

    private static func receipt(
        policy: ForgeAuthorizationPolicy,
        request: ForgeAuthorizationRequest,
        mode: ForgeAuthorizationMode
    ) -> ForgeAuthorizationReceipt {
        ForgeAuthorizationReceipt(
            policyID: policy.policyID,
            policyRevision: policy.revision,
            requestID: request.requestID,
            authority: request.authority,
            scopeID: request.scopeID,
            action: request.action,
            mode: mode
        )
    }
}
