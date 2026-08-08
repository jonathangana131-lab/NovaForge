public enum ForgeCompactPrivacyPolicy: String, Codable, Hashable, Sendable {
    case localOnly
    case hostedAllowed
}

public enum ForgeCompactModelTier: Int, Codable, Comparable, Hashable, Sendable {
    case instant = 0
    case core = 1
    case deep = 2
    case experimentalBeyondRAM = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ForgeCompactExecutionKind: String, Codable, Hashable, Sendable {
    case local
    case hosted
}

public struct ForgeCompactRuntimeCandidate: Hashable, Sendable {
    public let id: String
    public let tier: ForgeCompactModelTier
    public let executionKind: ForgeCompactExecutionKind
    public let qualifiedLocalProfile: QualifiedLocalRuntimeProfile?

    public init(
        id: String,
        tier: ForgeCompactModelTier,
        executionKind: ForgeCompactExecutionKind,
        qualifiedLocalProfile: QualifiedLocalRuntimeProfile? = nil
    ) throws {
        self.id = try validatedText(id, field: "candidate.id")
        self.tier = tier
        self.executionKind = executionKind
        self.qualifiedLocalProfile = qualifiedLocalProfile
        if executionKind == .local, qualifiedLocalProfile == nil {
            throw ForgeCompactValidationError.invalidQualification("local candidate lacks accepted qualification evidence")
        }
        if executionKind == .hosted, qualifiedLocalProfile != nil {
            throw ForgeCompactValidationError.invalidQualification("hosted candidate cannot carry local qualification evidence")
        }
    }
}

public struct ForgeCompactResourceSnapshot: Hashable, Sendable {
    public let availableMemoryBytes: UInt64
    public let thermalState: ForgeCompactThermalState
    public let isForeground: Bool

    public init(availableMemoryBytes: UInt64, thermalState: ForgeCompactThermalState, isForeground: Bool) {
        self.availableMemoryBytes = availableMemoryBytes
        self.thermalState = thermalState
        self.isForeground = isForeground
    }
}

public struct ForgeCompactGovernorPolicy: Hashable, Sendable {
    public let privacyPolicy: ForgeCompactPrivacyPolicy
    public let maximumTier: ForgeCompactModelTier
    public let allowExperimentalBeyondRAM: Bool
    public let minimumMemoryHeadroomBytes: UInt64

    public init(
        privacyPolicy: ForgeCompactPrivacyPolicy,
        maximumTier: ForgeCompactModelTier,
        allowExperimentalBeyondRAM: Bool,
        minimumMemoryHeadroomBytes: UInt64
    ) {
        self.privacyPolicy = privacyPolicy
        self.maximumTier = maximumTier
        self.allowExperimentalBeyondRAM = allowExperimentalBeyondRAM
        self.minimumMemoryHeadroomBytes = minimumMemoryHeadroomBytes
    }
}

public enum ForgeCompactGovernorDecision: Hashable, Sendable {
    case select(candidateID: String)
    case checkpointAndUnload(reason: String)
    case blocked(reason: String)
}

public enum ForgeCompactGovernor {
    public static func decide(
        candidates: [ForgeCompactRuntimeCandidate],
        resources: ForgeCompactResourceSnapshot,
        policy: ForgeCompactGovernorPolicy
    ) -> ForgeCompactGovernorDecision {
        if resources.thermalState == .critical {
            return .checkpointAndUnload(reason: "critical thermal state")
        }
        if resources.thermalState == .unknown {
            return .blocked(reason: "thermal state is unknown")
        }
        if !resources.isForeground {
            return .checkpointAndUnload(reason: "foreground execution authority is unavailable")
        }

        let eligible = candidates.filter { candidate in
            guard candidate.tier <= policy.maximumTier else { return false }
            if candidate.tier == .experimentalBeyondRAM && !policy.allowExperimentalBeyondRAM {
                return false
            }
            if policy.privacyPolicy == .localOnly && candidate.executionKind != .local {
                return false
            }
            if candidate.executionKind == .local {
                guard let evidence = candidate.qualifiedLocalProfile?.evidence else { return false }
                let peak = evidence.peakResidentMemoryBytes
                guard resources.availableMemoryBytes >= peak else { return false }
                guard resources.availableMemoryBytes - peak >= policy.minimumMemoryHeadroomBytes else { return false }
                if resources.thermalState == .serious && candidate.tier > .instant { return false }
            }
            return true
        }

        let selected = eligible.sorted { lhs, rhs in
            if lhs.tier == rhs.tier { return lhs.id < rhs.id }
            return lhs.tier > rhs.tier
        }.first

        if let selected {
            return .select(candidateID: selected.id)
        }
        return .blocked(reason: "no runtime candidate satisfies current privacy, qualification, memory, thermal, and tier policy")
    }
}
