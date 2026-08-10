import Foundation

/// Stable lookup identity for a product route. Provider identity alone is not
/// sufficient to choose a wire contract; the exact model is part of the key.
public struct ProviderRouteKey: Codable, Hashable, Sendable {
    public let providerID: ProviderID
    public let modelID: ProviderModelID

    public init(providerID: ProviderID, modelID: ProviderModelID) {
        self.providerID = providerID
        self.modelID = modelID
    }

    public init(route: ProviderRoute) {
        self.init(providerID: route.providerID, modelID: route.modelID)
    }
}

/// Product support is separate from provider availability. A live catalog may
/// prove that a model exists, but it cannot promote that model into a trusted
/// NovaForge route or infer its dialect.
public enum ProviderProductSupportState: String, Codable, CaseIterable, Hashable, Sendable {
    case supported = "SUPPORTED"
    case experimental = "EXPERIMENTAL"
    case legacy = "LEGACY"
    case broken = "BROKEN"
    case unverified = "UNVERIFIED"
    case removedDoNotOffer = "REMOVED_DO_NOT_OFFER"

    public func isSelectable(allowExperimental: Bool) -> Bool {
        switch self {
        case .supported:
            true
        case .experimental:
            allowExperimental
        case .legacy, .broken, .unverified, .removedDoNotOffer:
            false
        }
    }
}

/// Credential *kind* required by a route. No token, session, key, or account
/// identifier belongs in this descriptor or its receipt projection.
public enum ProviderAuthenticationMode: String, Codable, Hashable, Sendable {
    case apiKeyBearer
    case oauthBearer
    case subscriptionSession
    case callerManaged
    case local
    case noneDocumented
    case unverified
}

/// Bounded data-handling semantics for one exact route/model. Provider catalog
/// text and price labels never mint this classification.
public enum ProviderDataHandlingClassification: String, Codable, Hashable, Sendable {
    case onDeviceOnly
    case standardHosted
    case providerMayUseContentForImprovement
    case trialNoConfidentialData
    case unverified
}

public struct ProviderDataHandlingPolicy: Codable, Equatable, Sendable {
    public let policyID: String
    public let classification: ProviderDataHandlingClassification
    public let requiresPreUseDisclosure: Bool
    public let sourceID: String
    public let verifiedAtISO8601: String

    public init(
        policyID: String,
        classification: ProviderDataHandlingClassification,
        requiresPreUseDisclosure: Bool,
        sourceID: String,
        verifiedAtISO8601: String
    ) {
        self.policyID = policyID
        self.classification = classification
        self.requiresPreUseDisclosure = requiresPreUseDisclosure
        self.sourceID = sourceID
        self.verifiedAtISO8601 = verifiedAtISO8601
    }
}

/// Stable, credential-free authority for the transport origin. The transport
/// owns the concrete URL mapping; the profile owns which mapping is permitted.
public struct ProviderEndpointAuthority: Codable, Equatable, Sendable {
    public let authorityID: String
    public let relativePath: String

    public init(authorityID: String, relativePath: String) {
        self.authorityID = authorityID
        self.relativePath = relativePath
    }
}

public struct ProviderRequestSerializerID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let openAIChatCompletions = Self(rawValue: "openai-chat-completions-json-v1")
    public static let openAIResponses = Self(rawValue: "openai-responses-json-v1")

    /// Derived from the executable adapter dialect so a caller cannot attach a
    /// contradictory serializer label to an accepted route profile.
    public init(descriptor: ProviderAdapterDescriptor) {
        switch descriptor.dialect {
        case .openAIChatCompletions, .openAICompatibleChat:
            self = .openAIChatCompletions
        case .openAIResponses:
            self = .openAIResponses
        }
    }
}

public struct ProviderStreamParserID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let openAIChatCompletions = Self(rawValue: "openai-chat-completions-stream-v1")
    public static let openAIResponses = Self(rawValue: "openai-responses-stream-v1")
    public static let localNative = Self(rawValue: "local-native-stream-v1")

    /// Hosted/caller-managed compatible-chat routes use the provider stream
    /// parser, while the on-device adapter is translated by LocalModelWireSession.
    public init(descriptor: ProviderAdapterDescriptor) {
        if descriptor.route.deployment == .onDevice {
            self = .localNative
            return
        }
        switch descriptor.dialect {
        case .openAIChatCompletions, .openAICompatibleChat:
            self = .openAIChatCompletions
        case .openAIResponses:
            self = .openAIResponses
        }
    }
}

/// Opaque protocol replay requirements. This is transport continuity metadata,
/// never user-visible hidden reasoning or chain-of-thought.
public enum ProviderReplayPolicy: String, Codable, Hashable, Sendable {
    case none
    case chatCompletionsReasoningEnvelope
    case responsesContinuationItems
    case adapterManagedOpaque
}

/// Same-route retry behavior. Cross-route fallback remains an engine/policy
/// decision and is intentionally not granted by this metadata.
public enum ProviderRetryBehavior: String, Codable, Hashable, Sendable {
    case never
    case transientSameRoute
}

public enum ProviderCancellationBehavior: String, Codable, Hashable, Sendable {
    case unavailable
    case cooperativeTransportAbort
}

/// Source/revision evidence used to explain why a route is in the curated
/// catalog and where its most recent availability/health assertion came from.
public struct ProviderRouteEvidence: Codable, Equatable, Sendable {
    public let catalogSourceID: String
    public let healthSourceID: String
    public let revision: String

    public init(catalogSourceID: String, healthSourceID: String, revision: String) {
        self.catalogSourceID = catalogSourceID
        self.healthSourceID = healthSourceID
        self.revision = revision
    }
}

public enum ProviderRouteProfileValidationError: Error, Equatable, Sendable {
    case emptyEndpointAuthority
    case emptyEvidenceRevision
    case emptyDataHandlingPolicyID
    case emptyDataHandlingSourceID
    case emptyDataHandlingVerifiedAt
    case descriptorPathMismatch(descriptorPath: String, profilePath: String)
    case cancellationCapabilityMismatch
    case supportedRouteHasUnverifiedAuthentication
    case supportedRouteHasUnverifiedDataHandling
    case localRouteAuthenticationMismatch
    case localRouteDataHandlingMismatch
    case hostedRouteUsesLocalAuthentication
}

/// One immutable, credential-free product routing snapshot. The concrete
/// adapter remains the executable serializer/parser authority; this profile
/// makes that exact choice visible to selection, dispatch, and receipts.
/// Profiles are intentionally not Codable, and ordinary package consumers
/// cannot mint them. Durable state stores only the receipt projection, then
/// recovery re-resolves package-owned current route authority. Decoding or
/// caller-shaped metadata must never manufacture a current supported route.
public struct ProviderRouteProfile: Equatable, Sendable {
    public let descriptor: ProviderAdapterDescriptor
    public let endpoint: ProviderEndpointAuthority
    public let authenticationMode: ProviderAuthenticationMode
    public let dataHandling: ProviderDataHandlingPolicy
    public let requestSerializerID: ProviderRequestSerializerID
    public let streamParserID: ProviderStreamParserID
    public let replayPolicy: ProviderReplayPolicy
    public let retryBehavior: ProviderRetryBehavior
    public let cancellationBehavior: ProviderCancellationBehavior
    public let supportState: ProviderProductSupportState
    public let evidence: ProviderRouteEvidence

    init(
        descriptor: ProviderAdapterDescriptor,
        endpoint: ProviderEndpointAuthority,
        authenticationMode: ProviderAuthenticationMode,
        dataHandling: ProviderDataHandlingPolicy,
        replayPolicy: ProviderReplayPolicy,
        retryBehavior: ProviderRetryBehavior,
        cancellationBehavior: ProviderCancellationBehavior,
        supportState: ProviderProductSupportState,
        evidence: ProviderRouteEvidence
    ) throws {
        guard !endpoint.authorityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderRouteProfileValidationError.emptyEndpointAuthority
        }
        guard !evidence.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderRouteProfileValidationError.emptyEvidenceRevision
        }
        guard !dataHandling.policyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderRouteProfileValidationError.emptyDataHandlingPolicyID
        }
        guard !dataHandling.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderRouteProfileValidationError.emptyDataHandlingSourceID
        }
        guard !dataHandling.verifiedAtISO8601.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderRouteProfileValidationError.emptyDataHandlingVerifiedAt
        }
        guard descriptor.requestPath == endpoint.relativePath else {
            throw ProviderRouteProfileValidationError.descriptorPathMismatch(
                descriptorPath: descriptor.requestPath,
                profilePath: endpoint.relativePath
            )
        }
        if cancellationBehavior != .unavailable,
           !descriptor.route.capabilities.features.contains(.cancellation) {
            throw ProviderRouteProfileValidationError.cancellationCapabilityMismatch
        }
        if supportState == .supported, authenticationMode == .unverified {
            throw ProviderRouteProfileValidationError.supportedRouteHasUnverifiedAuthentication
        }
        if supportState == .supported, dataHandling.classification == .unverified {
            throw ProviderRouteProfileValidationError.supportedRouteHasUnverifiedDataHandling
        }
        if descriptor.route.deployment == .onDevice {
            guard authenticationMode == .local else {
                throw ProviderRouteProfileValidationError.localRouteAuthenticationMismatch
            }
            guard dataHandling.classification == .onDeviceOnly else {
                throw ProviderRouteProfileValidationError.localRouteDataHandlingMismatch
            }
        } else if authenticationMode == .local {
            throw ProviderRouteProfileValidationError.hostedRouteUsesLocalAuthentication
        }

        self.descriptor = descriptor
        self.endpoint = endpoint
        self.authenticationMode = authenticationMode
        self.dataHandling = dataHandling
        requestSerializerID = ProviderRequestSerializerID(descriptor: descriptor)
        streamParserID = ProviderStreamParserID(descriptor: descriptor)
        self.replayPolicy = replayPolicy
        self.retryBehavior = retryBehavior
        self.cancellationBehavior = cancellationBehavior
        self.supportState = supportState
        self.evidence = evidence
    }

    public var key: ProviderRouteKey {
        ProviderRouteKey(route: descriptor.route)
    }

    public func isSelectable(allowExperimental: Bool = false) -> Bool {
        supportState.isSelectable(allowExperimental: allowExperimental)
    }

    public var receiptProjection: ProviderRouteReceiptProjection {
        ProviderRouteReceiptProjection(profile: self)
    }
}

public enum ProviderRouteRegistryFailure: Error, Equatable, Sendable {
    case duplicateRoute(ProviderRouteKey)
    case unknownRoute(ProviderRouteKey)
    case unavailableSupportState(ProviderRouteKey, ProviderProductSupportState)
    case descriptorDrift(ProviderRouteKey)
    case receiptDrift(ProviderRouteKey)
}

/// Immutable catalog used as the shared selection/dispatch truth. Dynamic
/// provider model lists can only intersect this registry; they cannot create a
/// new trusted profile or change its wire dialect/capabilities.
public struct ProviderRouteRegistry: Sendable {
    private let orderedProfiles: [ProviderRouteProfile]
    private let profilesByKey: [ProviderRouteKey: ProviderRouteProfile]

    public init(_ profiles: [ProviderRouteProfile]) throws {
        var index: [ProviderRouteKey: ProviderRouteProfile] = [:]
        for profile in profiles {
            guard index[profile.key] == nil else {
                throw ProviderRouteRegistryFailure.duplicateRoute(profile.key)
            }
            index[profile.key] = profile
        }
        orderedProfiles = profiles
        profilesByKey = index
    }

    public var allProfiles: [ProviderRouteProfile] {
        orderedProfiles
    }

    /// Exact resolution for a fresh product selection. Unknown models are not
    /// coerced to a provider default or dialect.
    public func resolve(
        providerID: ProviderID,
        modelID: ProviderModelID,
        allowExperimental: Bool = false
    ) throws -> ProviderRouteProfile {
        let key = ProviderRouteKey(providerID: providerID, modelID: modelID)
        guard let profile = profilesByKey[key] else {
            throw ProviderRouteRegistryFailure.unknownRoute(key)
        }
        guard profile.isSelectable(allowExperimental: allowExperimental) else {
            throw ProviderRouteRegistryFailure.unavailableSupportState(key, profile.supportState)
        }
        return profile
    }

    /// Intersects live availability with already-curated authority. Unknown
    /// live IDs are deliberately ignored and therefore cannot mint support.
    public func availableProfiles(
        providerID: ProviderID,
        liveModelIDs: some Sequence<ProviderModelID>,
        allowExperimental: Bool = false
    ) -> [ProviderRouteProfile] {
        let live = Set(liveModelIDs)
        return orderedProfiles.filter { profile in
            profile.key.providerID == providerID &&
                live.contains(profile.key.modelID) &&
                profile.isSelectable(allowExperimental: allowExperimental)
        }
    }

    /// Useful for catalog/UI diagnostics without fabricating a route. Unknown
    /// live models classify as UNVERIFIED but return no dispatch descriptor.
    public func supportState(providerID: ProviderID, modelID: ProviderModelID) -> ProviderProductSupportState {
        profilesByKey[ProviderRouteKey(providerID: providerID, modelID: modelID)]?.supportState ?? .unverified
    }

    /// Recovery/runtime verification must match the exact accepted adapter,
    /// dialect, path, capabilities, deployment, and provenance snapshot.
    public func profile(matching descriptor: ProviderAdapterDescriptor) throws -> ProviderRouteProfile {
        let key = ProviderRouteKey(route: descriptor.route)
        guard let profile = profilesByKey[key] else {
            throw ProviderRouteRegistryFailure.unknownRoute(key)
        }
        guard profile.descriptor == descriptor else {
            throw ProviderRouteRegistryFailure.descriptorDrift(key)
        }
        return profile
    }

    /// Receipt recovery is fail-closed if the current profile differs from the
    /// exact support/wire snapshot accepted for the historical run.
    public func profile(matching receipt: ProviderRouteReceiptProjection) throws -> ProviderRouteProfile {
        let key = ProviderRouteKey(providerID: receipt.providerID, modelID: receipt.modelID)
        guard let profile = profilesByKey[key] else {
            throw ProviderRouteRegistryFailure.unknownRoute(key)
        }
        guard profile.receiptProjection == receipt else {
            throw ProviderRouteRegistryFailure.receiptDrift(key)
        }
        return profile
    }
}

/// Stable, secret-free projection suitable for durable run receipts. It keeps
/// enough exact route truth to prove the accepted wire contract later without
/// serializing credentials or transport state.
public struct ProviderRouteReceiptProjection: Codable, Equatable, Sendable {
    public let providerID: ProviderID
    public let modelID: ProviderModelID
    public let adapterID: ProviderAdapterID
    public let dialect: ProviderAdapterDialect
    public let endpointAuthorityID: String
    public let requestPath: String
    public let authenticationMode: ProviderAuthenticationMode
    public let dataHandlingPolicyID: String
    public let dataHandlingClassification: ProviderDataHandlingClassification
    public let dataHandlingRequiresPreUseDisclosure: Bool
    public let dataHandlingSourceID: String
    public let dataHandlingVerifiedAtISO8601: String
    public let requestSerializerID: ProviderRequestSerializerID
    public let streamParserID: ProviderStreamParserID
    public let replayPolicy: ProviderReplayPolicy
    public let retryBehavior: ProviderRetryBehavior
    public let cancellationBehavior: ProviderCancellationBehavior
    public let supportState: ProviderProductSupportState
    public let supportRevision: String
    public let catalogSourceID: String
    public let healthSourceID: String

    public init(profile: ProviderRouteProfile) {
        providerID = profile.descriptor.route.providerID
        modelID = profile.descriptor.route.modelID
        adapterID = profile.descriptor.route.adapterID
        dialect = profile.descriptor.dialect
        endpointAuthorityID = profile.endpoint.authorityID
        requestPath = profile.descriptor.requestPath
        authenticationMode = profile.authenticationMode
        dataHandlingPolicyID = profile.dataHandling.policyID
        dataHandlingClassification = profile.dataHandling.classification
        dataHandlingRequiresPreUseDisclosure = profile.dataHandling.requiresPreUseDisclosure
        dataHandlingSourceID = profile.dataHandling.sourceID
        dataHandlingVerifiedAtISO8601 = profile.dataHandling.verifiedAtISO8601
        requestSerializerID = profile.requestSerializerID
        streamParserID = profile.streamParserID
        replayPolicy = profile.replayPolicy
        retryBehavior = profile.retryBehavior
        cancellationBehavior = profile.cancellationBehavior
        supportState = profile.supportState
        supportRevision = profile.evidence.revision
        catalogSourceID = profile.evidence.catalogSourceID
        healthSourceID = profile.evidence.healthSourceID
    }
}
