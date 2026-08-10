import Foundation

/// Exact identity of the project state against which a Physics Playground decision is made.
///
/// A tuning authorization is stale as soon as either component changes. The core deliberately
/// treats these as opaque host-provided identities rather than attempting to infer Git or runtime
/// semantics.
public struct PhysicsProjectRevision: Codable, Hashable, Sendable {
    public let projectID: String
    public let revisionID: String

    public init(projectID: String, revisionID: String) throws {
        self.projectID = try PhysicsOpaqueID.validating(projectID, field: "projectID")
        self.revisionID = try PhysicsOpaqueID.validating(revisionID, field: "revisionID")
    }
}

public enum PhysicsParameterKind: String, Codable, CaseIterable, Sendable {
    case gravity
    case mass
    case friction
    case linearDamping
    case angularDamping
    case steeringResponse
    case motorTorque
    case suspensionStiffness
    case suspensionDamping
    case cameraFieldOfView
}

public enum PhysicsParameterUnit: String, Codable, CaseIterable, Sendable {
    case metersPerSecondSquared
    case kilograms
    case coefficient
    case perSecond
    case normalized
    case newtonMeters
    case newtonsPerMeter
    case newtonSecondsPerMeter
    case degrees
}

public extension PhysicsParameterKind {
    var canonicalUnit: PhysicsParameterUnit {
        switch self {
        case .gravity:
            .metersPerSecondSquared
        case .mass:
            .kilograms
        case .friction:
            .coefficient
        case .linearDamping, .angularDamping:
            .perSecond
        case .steeringResponse:
            .normalized
        case .motorTorque:
            .newtonMeters
        case .suspensionStiffness:
            .newtonsPerMeter
        case .suspensionDamping:
            .newtonSecondsPerMeter
        case .cameraFieldOfView:
            .degrees
        }
    }
}

public struct PhysicsParameterDefinition: Codable, Hashable, Sendable {
    public let id: String
    public let kind: PhysicsParameterKind
    public let displayName: String
    public let unit: PhysicsParameterUnit
    public let minimumValue: Double
    public let maximumValue: Double
    /// A presentation hint only. The authority does not round or silently quantize user intent.
    public let recommendedStep: Double?

    public init(
        id: String,
        kind: PhysicsParameterKind,
        displayName: String,
        unit: PhysicsParameterUnit,
        minimumValue: Double,
        maximumValue: Double,
        recommendedStep: Double? = nil
    ) throws {
        self.id = try PhysicsOpaqueID.validating(id, field: "parameterID")
        self.kind = kind

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw PhysicsTuningValidationError.emptyDisplayName(parameterID: self.id)
        }
        self.displayName = trimmedName
        guard unit == kind.canonicalUnit else {
            throw PhysicsTuningValidationError.unitMismatch(
                parameterID: self.id,
                kind: kind,
                expected: kind.canonicalUnit,
                actual: unit
            )
        }
        self.unit = unit

        guard minimumValue.isFinite, maximumValue.isFinite else {
            throw PhysicsTuningValidationError.nonFiniteBounds(parameterID: self.id)
        }
        guard minimumValue < maximumValue else {
            throw PhysicsTuningValidationError.invalidBounds(
                parameterID: self.id,
                minimum: minimumValue,
                maximum: maximumValue
            )
        }
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue

        if let recommendedStep {
            guard recommendedStep.isFinite, recommendedStep > 0 else {
                throw PhysicsTuningValidationError.invalidRecommendedStep(
                    parameterID: self.id,
                    step: recommendedStep
                )
            }
            guard recommendedStep <= maximumValue - minimumValue else {
                throw PhysicsTuningValidationError.invalidRecommendedStep(
                    parameterID: self.id,
                    step: recommendedStep
                )
            }
        }
        self.recommendedStep = recommendedStep
    }

    public func contains(_ value: Double) -> Bool {
        value.isFinite && value >= minimumValue && value <= maximumValue
    }
}

/// The exact set of values the host intentionally exposes to Physics Playground.
/// Anything omitted here is not tunable through this authority.
public struct PhysicsExposedCatalog: Codable, Hashable, Sendable {
    public let projectRevision: PhysicsProjectRevision
    public let targetID: String
    public let catalogRevision: String
    public let parameters: [PhysicsParameterDefinition]

    public init(
        projectRevision: PhysicsProjectRevision,
        targetID: String,
        catalogRevision: String,
        parameters: [PhysicsParameterDefinition]
    ) throws {
        self.projectRevision = projectRevision
        self.targetID = try PhysicsOpaqueID.validating(targetID, field: "targetID")
        self.catalogRevision = try PhysicsOpaqueID.validating(catalogRevision, field: "catalogRevision")

        var ids = Set<String>()
        for parameter in parameters {
            guard ids.insert(parameter.id).inserted else {
                throw PhysicsTuningValidationError.duplicateParameterID(parameter.id)
            }
        }
        self.parameters = parameters
    }

    public func parameter(id: String) -> PhysicsParameterDefinition? {
        parameters.first { $0.id == id }
    }
}

public enum PhysicsSnapshotSource: String, Codable, Sendable {
    /// A host says these values came from a live runtime observation. The host remains responsible
    /// for the evidence behind `evidenceID`.
    case runtimeObservation
    /// Values were read from an accepted configuration/project snapshot, not a live runtime.
    case acceptedConfiguration
}

/// A caller-provided authoritative input snapshot. This type preserves provenance; it does not
/// upgrade a caller assertion into device/runtime proof.
public struct PhysicsTuningSnapshot: Codable, Hashable, Sendable {
    public let projectRevision: PhysicsProjectRevision
    public let targetID: String
    public let catalogRevision: String
    public let source: PhysicsSnapshotSource
    public let evidenceID: String
    public let values: [String: Double]

    public init(
        projectRevision: PhysicsProjectRevision,
        targetID: String,
        catalogRevision: String,
        source: PhysicsSnapshotSource,
        evidenceID: String,
        values: [String: Double]
    ) throws {
        self.projectRevision = projectRevision
        self.targetID = try PhysicsOpaqueID.validating(targetID, field: "targetID")
        self.catalogRevision = try PhysicsOpaqueID.validating(catalogRevision, field: "catalogRevision")
        self.source = source
        self.evidenceID = try PhysicsOpaqueID.validating(evidenceID, field: "evidenceID")

        for (parameterID, value) in values {
            _ = try PhysicsOpaqueID.validating(parameterID, field: "snapshotParameterID")
            guard value.isFinite else {
                throw PhysicsTuningValidationError.nonFiniteSnapshotValue(
                    parameterID: parameterID,
                    value: value
                )
            }
        }
        self.values = values
    }
}

public enum PhysicsTuningOperation: String, Codable, Sendable {
    case preview
    case commit
}

public enum PhysicsTuningActor: String, Codable, Sendable {
    case user
    case agent
    case preset
    case restore
}

/// A requested tuning decision with an optimistic-concurrency precondition.
/// `expectedCurrentValue` must match the bound snapshot exactly; stale sliders/agents fail closed.
public struct PhysicsTuningRequest: Codable, Hashable, Sendable {
    public let requestID: String
    public let projectRevision: PhysicsProjectRevision
    public let targetID: String
    public let catalogRevision: String
    public let parameterID: String
    public let expectedCurrentValue: Double
    public let proposedValue: Double
    public let operation: PhysicsTuningOperation
    public let actor: PhysicsTuningActor

    public init(
        requestID: String,
        projectRevision: PhysicsProjectRevision,
        targetID: String,
        catalogRevision: String,
        parameterID: String,
        expectedCurrentValue: Double,
        proposedValue: Double,
        operation: PhysicsTuningOperation,
        actor: PhysicsTuningActor
    ) throws {
        self.requestID = try PhysicsOpaqueID.validating(requestID, field: "requestID")
        self.projectRevision = projectRevision
        self.targetID = try PhysicsOpaqueID.validating(targetID, field: "targetID")
        self.catalogRevision = try PhysicsOpaqueID.validating(catalogRevision, field: "catalogRevision")
        self.parameterID = try PhysicsOpaqueID.validating(parameterID, field: "parameterID")

        guard expectedCurrentValue.isFinite else {
            throw PhysicsTuningValidationError.nonFiniteExpectedValue(
                parameterID: self.parameterID,
                value: expectedCurrentValue
            )
        }
        guard proposedValue.isFinite else {
            throw PhysicsTuningValidationError.nonFiniteProposedValue(
                parameterID: self.parameterID,
                value: proposedValue
            )
        }
        self.expectedCurrentValue = expectedCurrentValue
        self.proposedValue = proposedValue
        self.operation = operation
        self.actor = actor
    }
}

public enum PhysicsTuningEffect: String, Codable, Sendable {
    /// Safe for a host to use for ephemeral UI/runtime preview. It is not accepted project truth.
    case previewOnly
    /// The domain checks passed and a separate authorized runtime/config mutation is still required.
    case runtimeMutationRequired
}

/// Domain authorization only. This is intentionally not named an "applied receipt": the core has
/// no runtime writer and cannot truthfully claim that gameplay changed.
public struct PhysicsTuningAuthorization: Codable, Hashable, Sendable {
    public let requestID: String
    public let projectRevision: PhysicsProjectRevision
    public let targetID: String
    public let catalogRevision: String
    public let parameterID: String
    public let parameterKind: PhysicsParameterKind
    public let unit: PhysicsParameterUnit
    public let previousValue: Double
    public let proposedValue: Double
    public let operation: PhysicsTuningOperation
    public let actor: PhysicsTuningActor
    public let snapshotSource: PhysicsSnapshotSource
    public let sourceEvidenceID: String
    public let effect: PhysicsTuningEffect

    /// Always false in this package. Only a future runtime/config adapter observing a successful
    /// mutation may create applied evidence.
    public var runtimeMutationObserved: Bool { false }
}

public enum PhysicsTuningValidationError: Error, Equatable, Sendable {
    case emptyOpaqueID(field: String)
    case emptyDisplayName(parameterID: String)
    case duplicateParameterID(String)
    case unitMismatch(
        parameterID: String,
        kind: PhysicsParameterKind,
        expected: PhysicsParameterUnit,
        actual: PhysicsParameterUnit
    )
    case nonFiniteBounds(parameterID: String)
    case invalidBounds(parameterID: String, minimum: Double, maximum: Double)
    case invalidRecommendedStep(parameterID: String, step: Double)
    case nonFiniteSnapshotValue(parameterID: String, value: Double)
    case nonFiniteExpectedValue(parameterID: String, value: Double)
    case nonFiniteProposedValue(parameterID: String, value: Double)
}

public enum PhysicsTuningRejection: Error, Equatable, Sendable {
    case projectRevisionMismatch
    case targetMismatch
    case catalogRevisionMismatch
    case parameterNotExposed(String)
    case currentValueMissing(String)
    case staleCurrentValue(parameterID: String, expected: Double, observed: Double)
    case currentValueOutsideExposedBounds(parameterID: String, observed: Double)
    case proposedValueBelowMinimum(parameterID: String, proposed: Double, minimum: Double)
    case proposedValueAboveMaximum(parameterID: String, proposed: Double, maximum: Double)
}

enum PhysicsOpaqueID {
    static func validating(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PhysicsTuningValidationError.emptyOpaqueID(field: field)
        }
        return trimmed
    }
}

/// Fail-closed authority for Physics Playground tuning decisions.
///
/// This type performs identity, exposure, stale-state, finiteness and bounds checks. It has no I/O
/// and performs no runtime mutation. A successful `.commit` therefore means only that a downstream
/// mutation gateway may proceed with the exact authorized values and identities.
public enum PhysicsTuningAuthority {
    public static func authorize(
        _ request: PhysicsTuningRequest,
        catalog: PhysicsExposedCatalog,
        snapshot: PhysicsTuningSnapshot
    ) throws -> PhysicsTuningAuthorization {
        try requireExactIdentity(request: request, catalog: catalog, snapshot: snapshot)

        guard let definition = catalog.parameter(id: request.parameterID) else {
            throw PhysicsTuningRejection.parameterNotExposed(request.parameterID)
        }
        guard let observedValue = snapshot.values[request.parameterID] else {
            throw PhysicsTuningRejection.currentValueMissing(request.parameterID)
        }
        guard definition.contains(observedValue) else {
            throw PhysicsTuningRejection.currentValueOutsideExposedBounds(
                parameterID: request.parameterID,
                observed: observedValue
            )
        }
        guard valuesMatchExactly(request.expectedCurrentValue, observedValue) else {
            throw PhysicsTuningRejection.staleCurrentValue(
                parameterID: request.parameterID,
                expected: request.expectedCurrentValue,
                observed: observedValue
            )
        }
        guard request.proposedValue >= definition.minimumValue else {
            throw PhysicsTuningRejection.proposedValueBelowMinimum(
                parameterID: request.parameterID,
                proposed: request.proposedValue,
                minimum: definition.minimumValue
            )
        }
        guard request.proposedValue <= definition.maximumValue else {
            throw PhysicsTuningRejection.proposedValueAboveMaximum(
                parameterID: request.parameterID,
                proposed: request.proposedValue,
                maximum: definition.maximumValue
            )
        }

        return PhysicsTuningAuthorization(
            requestID: request.requestID,
            projectRevision: request.projectRevision,
            targetID: request.targetID,
            catalogRevision: request.catalogRevision,
            parameterID: request.parameterID,
            parameterKind: definition.kind,
            unit: definition.unit,
            previousValue: observedValue,
            proposedValue: request.proposedValue,
            operation: request.operation,
            actor: request.actor,
            snapshotSource: snapshot.source,
            sourceEvidenceID: snapshot.evidenceID,
            effect: request.operation == .preview ? .previewOnly : .runtimeMutationRequired
        )
    }

    private static func requireExactIdentity(
        request: PhysicsTuningRequest,
        catalog: PhysicsExposedCatalog,
        snapshot: PhysicsTuningSnapshot
    ) throws {
        guard request.projectRevision == catalog.projectRevision,
              request.projectRevision == snapshot.projectRevision else {
            throw PhysicsTuningRejection.projectRevisionMismatch
        }
        guard request.targetID == catalog.targetID,
              request.targetID == snapshot.targetID else {
            throw PhysicsTuningRejection.targetMismatch
        }
        guard request.catalogRevision == catalog.catalogRevision,
              request.catalogRevision == snapshot.catalogRevision else {
            throw PhysicsTuningRejection.catalogRevisionMismatch
        }
    }

    /// Deliberately no epsilon: this is an optimistic-concurrency token represented by the exact
    /// current numeric value, not a physics approximation. Normal equality also treats -0/+0 as the
    /// same semantic value, which is appropriate for user-facing tuning state.
    private static func valuesMatchExactly(_ lhs: Double, _ rhs: Double) -> Bool {
        lhs == rhs
    }
}
