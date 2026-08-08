import Foundation

public enum ForgeComposerIntentError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidIntentSummary
    case invalidIdentifier
    case invalidProviderAllowlist
    case invalidUnitInterval
}

private enum ForgeComposerIntentValidation {
    static let schemaVersion = 1
    static let maxIntentBytes = 16_384
    static let maxIdentifierBytes = 256
    static let maxProviderCount = 16

    static func intentSummary(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maxIntentBytes,
              !value.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
                      && scalar.value != 0x09
                      && scalar.value != 0x0A
                      && scalar.value != 0x0D
              })
        else {
            throw ForgeComposerIntentError.invalidIntentSummary
        }
        return value
    }

    static func identifier(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == raw,
              !raw.isEmpty,
              raw.utf8.count <= maxIdentifierBytes,
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ForgeComposerIntentError.invalidIdentifier
        }
        return raw
    }
}

/// V14 user intent for how NovaForge should collaborate. This is never execution authorization.
public enum ForgeComposerAutonomyIntent: String, CaseIterable, Codable, Hashable, Sendable {
    case guideMe
    case collaborate
    case fullForge
}

/// V14 product-depth vocabulary. Exact stage graphs and completion criteria remain Mission authority.
public enum ForgeComposerBuildDepthIntent: String, CaseIterable, Codable, Hashable, Sendable {
    case quick
    case complete
    case obsessive
}

/// A bounded user preference. It is not a measured device/runtime capability claim.
public struct ForgeComposerUnitInterval: Hashable, Codable, Sendable {
    public let value: Double

    public init(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw ForgeComposerIntentError.invalidUnitInterval
        }
        self.value = value
    }

    private init(validatedValue value: Double) {
        self.value = value
    }

    public static let standardCreativity = Self(validatedValue: 0.45)
    public static let cautiousRefactorRisk = Self(validatedValue: 0.25)

    private enum CodingKeys: String, CodingKey { case value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(container.decode(Double.self, forKey: .value))
    }
}

/// Intelligence is a routing preference only. An explicit reference must still be accepted by the
/// canonical Local Model Fabric / provider qualification authority before execution can use it.
public enum ForgeComposerIntelligenceIntent: Hashable, Codable, Sendable {
    case automatic
    case explicitModel(referenceID: String)

    public var requiresExternalQualification: Bool {
        if case .explicitModel = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey { case kind, referenceID }
    private enum Kind: String, Codable { case automatic, explicitModel }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .automatic:
            self = .automatic
        case .explicitModel:
            let referenceID = try ForgeComposerIntentValidation.identifier(
                container.decode(String.self, forKey: .referenceID)
            )
            self = .explicitModel(referenceID: referenceID)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode(Kind.automatic, forKey: .kind)
        case .explicitModel(let referenceID):
            try container.encode(Kind.explicitModel, forKey: .kind)
            try container.encode(
                ForgeComposerIntentValidation.identifier(referenceID),
                forKey: .referenceID
            )
        }
    }

    public static func explicit(referenceID: String) throws -> Self {
        .explicitModel(referenceID: try ForgeComposerIntentValidation.identifier(referenceID))
    }
}

/// Local Only is structurally distinct from provider permission. There is no implicit cloud fallback.
public enum ForgeComposerPrivacyIntent: Hashable, Codable, Sendable {
    case localOnly
    case providerAllowlist([String])

    public var isLocalOnly: Bool {
        if case .localOnly = self { return true }
        return false
    }

    public func allowsProvider(_ providerID: String) -> Bool {
        guard case .providerAllowlist(let providerIDs) = self else { return false }
        return providerIDs.contains(providerID)
    }

    private enum CodingKeys: String, CodingKey { case kind, providerIDs }
    private enum Kind: String, Codable { case localOnly, providerAllowlist }

    public static func providers(_ providerIDs: [String]) throws -> Self {
        let validated = try validateProviders(providerIDs)
        return .providerAllowlist(validated)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .localOnly:
            self = .localOnly
        case .providerAllowlist:
            self = .providerAllowlist(
                try Self.validateProviders(container.decode([String].self, forKey: .providerIDs))
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localOnly:
            try container.encode(Kind.localOnly, forKey: .kind)
        case .providerAllowlist(let providerIDs):
            try container.encode(Kind.providerAllowlist, forKey: .kind)
            try container.encode(Self.validateProviders(providerIDs), forKey: .providerIDs)
        }
    }

    private static func validateProviders(_ providerIDs: [String]) throws -> [String] {
        guard !providerIDs.isEmpty,
              providerIDs.count <= ForgeComposerIntentValidation.maxProviderCount
        else {
            throw ForgeComposerIntentError.invalidProviderAllowlist
        }

        let validated = try providerIDs.map(ForgeComposerIntentValidation.identifier)
        guard Set(validated).count == validated.count else {
            throw ForgeComposerIntentError.invalidProviderAllowlist
        }
        return validated.sorted()
    }
}

/// The one V14 control authority shared by the Composer and Plan Space. The profile is immutable;
/// custom profiles can only be created through `validated(...)`, so direct associated enum cases
/// cannot smuggle malformed model/provider identities into a ready Plan Space summary.
public struct ForgeComposerV14ControlProfile: Hashable, Codable, Sendable {
    public let intelligence: ForgeComposerIntelligenceIntent
    public let buildDepth: ForgeComposerBuildDepthIntent
    public let creativity: ForgeComposerUnitInterval
    public let refactorRisk: ForgeComposerUnitInterval
    public let autonomy: ForgeComposerAutonomyIntent
    public let privacy: ForgeComposerPrivacyIntent

    /// Calm, local-first V14 default for a new Composer/Plan Space session.
    public init() {
        intelligence = .automatic
        buildDepth = .complete
        creativity = .standardCreativity
        refactorRisk = .cautiousRefactorRisk
        autonomy = .collaborate
        privacy = .localOnly
    }

    private init(
        intelligence: ForgeComposerIntelligenceIntent,
        buildDepth: ForgeComposerBuildDepthIntent,
        creativity: ForgeComposerUnitInterval,
        refactorRisk: ForgeComposerUnitInterval,
        autonomy: ForgeComposerAutonomyIntent,
        privacy: ForgeComposerPrivacyIntent
    ) {
        self.intelligence = intelligence
        self.buildDepth = buildDepth
        self.creativity = creativity
        self.refactorRisk = refactorRisk
        self.autonomy = autonomy
        self.privacy = privacy
    }

    public static func validated(
        intelligence: ForgeComposerIntelligenceIntent = .automatic,
        buildDepth: ForgeComposerBuildDepthIntent = .complete,
        creativity: ForgeComposerUnitInterval = .standardCreativity,
        refactorRisk: ForgeComposerUnitInterval = .cautiousRefactorRisk,
        autonomy: ForgeComposerAutonomyIntent = .collaborate,
        privacy: ForgeComposerPrivacyIntent = .localOnly
    ) throws -> Self {
        let validatedIntelligence: ForgeComposerIntelligenceIntent
        switch intelligence {
        case .automatic:
            validatedIntelligence = .automatic
        case .explicitModel(let referenceID):
            validatedIntelligence = try .explicit(referenceID: referenceID)
        }

        let validatedPrivacy: ForgeComposerPrivacyIntent
        switch privacy {
        case .localOnly:
            validatedPrivacy = .localOnly
        case .providerAllowlist(let providerIDs):
            validatedPrivacy = try .providers(providerIDs)
        }

        return .init(
            intelligence: validatedIntelligence,
            buildDepth: buildDepth,
            creativity: creativity,
            refactorRisk: refactorRisk,
            autonomy: autonomy,
            privacy: validatedPrivacy
        )
    }

    public var requestsFullForge: Bool { autonomy == .fullForge }
    public var requiresExternalModelQualification: Bool {
        intelligence.requiresExternalQualification
    }
}

public enum ForgeComposerCreationKind: String, CaseIterable, Codable, Hashable, Sendable {
    case app
    case game
    case automation
    case experience
    case other
}

/// Durable user-owned front-door intent. The same V14 control profile is carried forward by
/// `PlanSpaceProposal` and `ReadyToForgeSummary`, so the front door cannot fork into a second
/// autonomy/privacy/intelligence authority while a plan is being resolved.
public struct ForgeComposerIntentEnvelope: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = ForgeComposerIntentValidation.schemaVersion

    public let schemaVersion: Int
    public let intentSummary: String
    public let controls: ForgeComposerV14ControlProfile
    public let creationKind: ForgeComposerCreationKind?
    public let runTargetID: String?

    public init(
        intentSummary: String,
        controls: ForgeComposerV14ControlProfile = .init(),
        creationKind: ForgeComposerCreationKind? = nil,
        runTargetID: String? = nil
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.intentSummary = try ForgeComposerIntentValidation.intentSummary(intentSummary)
        self.controls = controls
        self.creationKind = creationKind
        self.runTargetID = try runTargetID.map(ForgeComposerIntentValidation.identifier)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, intentSummary, controls, creationKind, runTargetID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ForgeComposerIntentError.unsupportedSchemaVersion(schemaVersion)
        }

        try self.init(
            intentSummary: container.decode(String.self, forKey: .intentSummary),
            controls: container.decode(ForgeComposerV14ControlProfile.self, forKey: .controls),
            creationKind: container.decodeIfPresent(ForgeComposerCreationKind.self, forKey: .creationKind),
            runTargetID: container.decodeIfPresent(String.self, forKey: .runTargetID)
        )
    }

    public var requiresExternalModelQualification: Bool {
        controls.requiresExternalModelQualification
    }

    public var requestsFullForge: Bool { controls.requestsFullForge }
}

public enum ForgeComposerMaterialControl: String, CaseIterable, Codable, Hashable, Sendable {
    case autonomy
    case buildDepth
    case intelligence
    case privacy
    case creativity
    case refactorRisk
    case creationKind
    case runTarget
}

/// Planner/presentation signals for progressive disclosure. They express materiality, not decisions.
public struct ForgeComposerDisclosureSignals: Hashable, Codable, Sendable {
    public let hasIntent: Bool
    public let creativityIsMaterial: Bool
    public let refactorRiskIsMaterial: Bool
    public let creationKindIsMaterial: Bool
    public let runTargetIsMaterial: Bool

    public init(
        hasIntent: Bool,
        creativityIsMaterial: Bool = false,
        refactorRiskIsMaterial: Bool = false,
        creationKindIsMaterial: Bool = false,
        runTargetIsMaterial: Bool = false
    ) {
        self.hasIntent = hasIntent
        self.creativityIsMaterial = creativityIsMaterial
        self.refactorRiskIsMaterial = refactorRiskIsMaterial
        self.creationKindIsMaterial = creationKindIsMaterial
        self.runTargetIsMaterial = runTargetIsMaterial
    }

    /// Resting Composer stays calm. Once intent exists, the four policy-significant controls appear;
    /// secondary controls are revealed only when the planner says they materially change the build.
    public var visibleControls: [ForgeComposerMaterialControl] {
        guard hasIntent else { return [] }
        var controls: [ForgeComposerMaterialControl] = [
            .autonomy, .buildDepth, .intelligence, .privacy,
        ]
        if creativityIsMaterial { controls.append(.creativity) }
        if refactorRiskIsMaterial { controls.append(.refactorRisk) }
        if creationKindIsMaterial { controls.append(.creationKind) }
        if runTargetIsMaterial { controls.append(.runTarget) }
        return controls
    }
}

public enum ForgeComposerNextAction: String, Codable, Hashable, Sendable {
    case describe
    case plan
    case forge
    case watch
    case run
    case improve
}

/// Presentation projection for the one obvious next action. Durable mission state/evidence must be
/// supplied by canonical authorities; this enum does not create or mutate mission lifecycle truth.
public enum ForgeComposerExperienceState: Hashable, Codable, Sendable {
    case resting
    case described(needsMaterialPlan: Bool)
    case waitingForPlanDecision
    case readyToForge
    case forging
    case completed(runnable: Bool, hasMaterialDefects: Bool)

    public var nextAction: ForgeComposerNextAction {
        switch self {
        case .resting:
            return .describe
        case .described(let needsMaterialPlan):
            return needsMaterialPlan ? .plan : .forge
        case .waitingForPlanDecision:
            return .plan
        case .readyToForge:
            return .forge
        case .forging:
            return .watch
        case .completed(let runnable, let hasMaterialDefects):
            if hasMaterialDefects { return .improve }
            return runnable ? .run : .improve
        }
    }
}
