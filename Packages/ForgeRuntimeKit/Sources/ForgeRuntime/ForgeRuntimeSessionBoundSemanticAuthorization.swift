import Foundation

/// Gate-authorized semantic interaction whose authority retains the exact Runtime API version
/// from the package-owned automation session.
///
/// The older `ForgeRuntimeAuthorizedSemanticInteraction` remains authorization-only and does not
/// carry complete session provenance. Runtime hosts that need to bind dispatch to an exact loaded
/// runtime generation should consume this session-bound subject instead of reconstructing runtime
/// identity from caller-supplied IDs.
public struct ForgeRuntimeSessionBoundAuthorizedSemanticInteraction: Equatable, Sendable {
    public let runtimeVersion: ForgeRuntimeVersion
    private let authorizedInteraction: ForgeRuntimeAuthorizedSemanticInteraction

    init(
        authorizedInteraction: ForgeRuntimeAuthorizedSemanticInteraction,
        runtimeVersion: ForgeRuntimeVersion
    ) {
        self.authorizedInteraction = authorizedInteraction
        self.runtimeVersion = runtimeVersion
    }

    /// The validated semantic request. Runtime version deliberately lives beside this request as
    /// package-owned session provenance rather than being accepted from the untrusted wire envelope.
    public var request: ForgeRuntimeSemanticInteractionRequest {
        authorizedInteraction.request
    }

    /// Deterministic proof that the exact request crossed the host gate under this exact Runtime API
    /// version. This is still authorization evidence only; it does not claim runtime delivery.
    public func authorizationReceipt() -> ForgeRuntimeSessionBoundSemanticInteractionAuthorizationReceipt {
        .init(
            authorization: authorizedInteraction.authorizationReceipt(),
            runtimeVersion: runtimeVersion
        )
    }
}

/// Encodable-only authorization receipt retaining complete runtime-version provenance.
/// Construction is package-owned so persisted/model-shaped bytes cannot mint this binding.
public struct ForgeRuntimeSessionBoundSemanticInteractionAuthorizationReceipt: Encodable, Equatable, Sendable {
    public let authorization: ForgeRuntimeSemanticInteractionAuthorizationReceipt
    public let runtimeVersion: ForgeRuntimeVersion

    init(
        authorization: ForgeRuntimeSemanticInteractionAuthorizationReceipt,
        runtimeVersion: ForgeRuntimeVersion
    ) {
        self.authorization = authorization
        self.runtimeVersion = runtimeVersion
    }
}

public extension ForgeRuntimeSemanticInteractionGate {
    /// Canonical authorization entry point for downstream runtime hosts that must prove the semantic
    /// interaction was authorized for the same Runtime API version as the loaded runtime.
    ///
    /// Runtime identity is copied only from this gate's immutable package-owned session after the
    /// existing decoder/capability/sequence/budget gate accepts the request. It is never read from
    /// untrusted request JSON.
    mutating func authorizeSessionBound(
        _ data: Data
    ) throws -> ForgeRuntimeSessionBoundAuthorizedSemanticInteraction {
        let authorizedInteraction = try authorize(data)
        return ForgeRuntimeSessionBoundAuthorizedSemanticInteraction(
            authorizedInteraction: authorizedInteraction,
            runtimeVersion: session.runtimeVersion
        )
    }
}