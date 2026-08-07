/// Result of probing the primary project store before NovaForge chooses which
/// durable branch owns launch-time user state.
public enum ProjectStorePrimaryAvailability: Sendable, Equatable {
    case readable
    case unreadable
}

/// Minimal facts needed to choose the authoritative project-store branch.
///
/// This deliberately excludes error text, SwiftData/Core Data types, and
/// presentation state so the selection rule can be reused by future ProjectStore
/// adapters without importing the legacy app shell.
public struct ProjectStoreAuthorityProbe: Sendable, Equatable {
    public let primary: ProjectStorePrimaryAvailability
    public let compatibilityWasActive: Bool
    public let compatibilityStoreExists: Bool

    public init(
        primary: ProjectStorePrimaryAvailability,
        compatibilityWasActive: Bool,
        compatibilityStoreExists: Bool
    ) {
        self.primary = primary
        self.compatibilityWasActive = compatibilityWasActive
        self.compatibilityStoreExists = compatibilityStoreExists
    }
}

/// A side-effect-free launch authority decision.
///
/// Callers remain responsible for atomically opening/creating stores and
/// committing/clearing the durable compatibility guard. This type decides only
/// which branch is allowed to become authoritative.
public enum ProjectStoreAuthorityDecision: Sendable, Equatable {
    /// Primary is readable and no active compatibility branch owns newer state.
    case servePrimary

    /// An existing compatibility branch is still authoritative and must be
    /// served until explicit identity-aware reconciliation clears it.
    case resumeCompatibility

    /// The active marker is stale because its compatibility store no longer
    /// exists. The marker may be durably cleared before serving readable primary.
    case clearStaleCompatibilityGuardAndServePrimary

    /// Primary is unreadable and no branch is currently active. The caller may
    /// establish a compatibility store/guard before performing recovery work.
    case establishCompatibility

    /// The durable active marker says compatibility owns state, but its store is
    /// missing and primary is unreadable. Never manufacture an empty replacement.
    case failClosedMissingActiveCompatibility
}

/// Canonical branch-selection policy for the V13 ProjectStore compatibility seam.
///
/// The critical invariant is that readability of primary does not supersede an
/// existing active compatibility store: it may contain newer projects, chats, or
/// receipts. Only explicit reconciliation can make primary authoritative again.
public enum ProjectStoreAuthorityPolicy {
    public static func decide(
        _ probe: ProjectStoreAuthorityProbe
    ) -> ProjectStoreAuthorityDecision {
        if probe.compatibilityWasActive {
            if probe.compatibilityStoreExists {
                return .resumeCompatibility
            }

            switch probe.primary {
            case .readable:
                return .clearStaleCompatibilityGuardAndServePrimary
            case .unreadable:
                return .failClosedMissingActiveCompatibility
            }
        }

        switch probe.primary {
        case .readable:
            return .servePrimary
        case .unreadable:
            return .establishCompatibility
        }
    }
}
