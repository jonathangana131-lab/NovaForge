import AgentDomain
import AgentTools
import Foundation

/// The only backend authority accepted by the developer read-tool gateway.
/// It exposes one legacy read request and no workspace writer, shell, approval,
/// provider transport, or general-purpose tool registry.
public protocol DeveloperReadOnlyCanaryToolBackend: Sendable {
    func executeReadOnly(_ request: LegacySandboxToolRequest) async throws -> String
}

public struct DeveloperReadOnlyCanaryToolRequest: Equatable, Sendable {
    public let runID: RunID
    public let callID: ToolCallID
    public let providerCallID: String
    public let modelAttemptID: AttemptID
    public let toolName: String
    public let toolVersion: String
    public let arguments: JSONValue

    public init(
        runID: RunID,
        callID: ToolCallID,
        providerCallID: String,
        modelAttemptID: AttemptID,
        toolName: String,
        toolVersion: String,
        arguments: JSONValue
    ) {
        self.runID = runID
        self.callID = callID
        self.providerCallID = providerCallID
        self.modelAttemptID = modelAttemptID
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.arguments = arguments
    }
}

/// Fully validated, immutable execution material. Its initializer is sealed to
/// AgentShadow so an app caller cannot fabricate a prepared invocation.
public struct PreparedDeveloperReadOnlyCanaryToolInvocation: Equatable, Sendable {
    public let invocation: ToolInvocation
    public let descriptor: ToolDescriptor
    public let providerDefinition: ProviderToolDefinition
    public let targets: [ToolTarget]
    public let legacyRequest: LegacySandboxToolRequest

    fileprivate let policyConfigurationSHA256: String
    fileprivate let contractSHA256: String

    fileprivate init(
        invocation: ToolInvocation,
        descriptor: ToolDescriptor,
        providerDefinition: ProviderToolDefinition,
        targets: [ToolTarget],
        legacyRequest: LegacySandboxToolRequest,
        policyConfigurationSHA256: String,
        contractSHA256: String
    ) {
        self.invocation = invocation
        self.descriptor = descriptor
        self.providerDefinition = providerDefinition
        self.targets = targets
        self.legacyRequest = legacyRequest
        self.policyConfigurationSHA256 = policyConfigurationSHA256
        self.contractSHA256 = contractSHA256
    }
}

public struct DeveloperReadOnlyCanaryToolExecution: Equatable, Sendable {
    public let prepared: PreparedDeveloperReadOnlyCanaryToolInvocation
    public let output: String
    public let outputByteCount: Int

    public init(
        prepared: PreparedDeveloperReadOnlyCanaryToolInvocation,
        output: String,
        outputByteCount: Int
    ) {
        self.prepared = prepared
        self.output = output
        self.outputByteCount = outputByteCount
    }
}

/// Public errors are deliberately closed and carry no caller input, backend
/// error text, path, provider response, or credential-bearing detail.
public enum DeveloperReadOnlyCanaryToolGatewayError: Error, Equatable, Sendable {
    case cancelled
    case runMismatch
    case invalidProviderCallIdentity
    case unknownTool
    case aliasNotAllowed
    case unsupportedVersion
    case effectfulTool
    case descriptorNotFrozen
    case invalidReadOnlyContract
    case invalidArguments
    case argumentTooLarge
    case legacyAdapterUnavailable
    case preparedInvocationMismatch
    case backendFailed
    case outputTooLarge
}

public struct DeveloperReadOnlyCanaryToolGateway: Sendable {
    private let policy: FrozenDeveloperReadOnlyCanaryPolicy
    private let registry: ToolRegistry
    private let backend: any DeveloperReadOnlyCanaryToolBackend

    public init(
        policy: FrozenDeveloperReadOnlyCanaryPolicy,
        registry: ToolRegistry,
        backend: any DeveloperReadOnlyCanaryToolBackend
    ) {
        self.policy = policy
        self.registry = registry
        self.backend = backend
    }

    public func prepare(
        _ request: DeveloperReadOnlyCanaryToolRequest
    ) throws -> PreparedDeveloperReadOnlyCanaryToolInvocation {
        guard !Task.isCancelled else { throw GatewayError.cancelled }
        guard request.runID == policy.runID else { throw GatewayError.runMismatch }
        guard Self.isSafeProviderCallIdentity(request.providerCallID) else {
            throw GatewayError.invalidProviderCallIdentity
        }

        let tool: AnyAgentTool
        do {
            tool = try registry.resolve(request.toolName)
        } catch {
            throw GatewayError.unknownTool
        }
        let descriptor = tool.descriptor
        guard descriptor.name == request.toolName else {
            throw GatewayError.aliasNotAllowed
        }
        guard descriptor.version.description == request.toolVersion else {
            throw GatewayError.unsupportedVersion
        }
        try validatePolicyAndReadOnlyContract(descriptor)

        let argumentData: Data
        do {
            argumentData = try AgentToolJSON.data(for: request.arguments)
        } catch {
            throw GatewayError.invalidArguments
        }
        guard argumentData.count <= descriptor.limits.maximumArgumentBytes else {
            throw GatewayError.argumentTooLarge
        }
        do {
            _ = try registry.decode(
                name: descriptor.name,
                version: request.toolVersion,
                arguments: request.arguments
            )
        } catch {
            throw GatewayError.invalidArguments
        }

        let targets: [ToolTarget]
        do {
            targets = try descriptor.extractTargets(from: request.arguments)
        } catch {
            throw GatewayError.invalidArguments
        }
        guard targets.allSatisfy({ $0.access == .inspect || $0.access == .read }) else {
            throw GatewayError.invalidReadOnlyContract
        }

        let canonicalArgumentDigest: String
        do {
            canonicalArgumentDigest = try descriptor.canonicalArgumentDigest(
                for: request.arguments
            )
        } catch {
            throw GatewayError.invalidArguments
        }
        let legacyRequest: LegacySandboxToolRequest
        do {
            legacyRequest = try registry.legacyRequest(
                name: descriptor.name,
                version: request.toolVersion,
                arguments: request.arguments
            )
        } catch {
            throw GatewayError.legacyAdapterUnavailable
        }
        guard !Task.isCancelled else { throw GatewayError.cancelled }

        let identity = descriptor.identity
        guard let fingerprint = policy.contractFingerprint(for: identity) else {
            throw GatewayError.descriptorNotFrozen
        }
        let idempotencyKey: String
        do {
            idempotencyKey = try Self.idempotencyKey(
                request: request,
                canonicalArgumentDigest: canonicalArgumentDigest,
                policyConfigurationSHA256: policy.configurationSHA256
            )
        } catch {
            throw GatewayError.invalidArguments
        }
        let invocation = ToolInvocation(
            callID: request.callID,
            providerCallID: request.providerCallID,
            modelAttemptID: request.modelAttemptID,
            tool: identity,
            arguments: request.arguments,
            canonicalArgumentDigest: canonicalArgumentDigest,
            idempotencyKey: idempotencyKey,
            effectClass: .readOnlyLocal,
            locality: .onDevice
        )
        return PreparedDeveloperReadOnlyCanaryToolInvocation(
            invocation: invocation,
            descriptor: descriptor,
            providerDefinition: ProviderToolDefinition(descriptor: descriptor),
            targets: targets,
            legacyRequest: legacyRequest,
            policyConfigurationSHA256: policy.configurationSHA256,
            contractSHA256: fingerprint.contractSHA256
        )
    }

    public func execute(
        _ prepared: PreparedDeveloperReadOnlyCanaryToolInvocation
    ) async throws -> DeveloperReadOnlyCanaryToolExecution {
        guard !Task.isCancelled else { throw GatewayError.cancelled }
        try revalidate(prepared)

        let output: String
        do {
            output = try await backend.executeReadOnly(prepared.legacyRequest)
        } catch is CancellationError {
            throw GatewayError.cancelled
        } catch {
            guard !Task.isCancelled else { throw GatewayError.cancelled }
            throw GatewayError.backendFailed
        }
        guard !Task.isCancelled else { throw GatewayError.cancelled }
        let byteCount = output.utf8.count
        guard byteCount <= prepared.descriptor.limits.maximumOutputBytes else {
            throw GatewayError.outputTooLarge
        }
        return DeveloperReadOnlyCanaryToolExecution(
            prepared: prepared,
            output: output,
            outputByteCount: byteCount
        )
    }

    private func validatePolicyAndReadOnlyContract(
        _ descriptor: ToolDescriptor
    ) throws {
        let decision = policy.decision(for: descriptor)
        guard decision.isAllowed else {
            if case .denied(.effectful) = decision {
                throw GatewayError.effectfulTool
            }
            throw GatewayError.descriptorNotFrozen
        }
        guard descriptor.effectClass == .readOnlyLocal,
              descriptor.approvalClass == .none,
              descriptor.parallelSafety == .parallelRead,
              descriptor.concurrencyKey == nil,
              descriptor.availability.allowedLocalities == [.onDevice],
              descriptor.availability.requiresWorkspace,
              descriptor.availability.requiredCapabilities.contains(.workspaceRead),
              !descriptor.availability.requiredCapabilities.contains(.workspaceWrite),
              !descriptor.availability.requiredCapabilities.contains(.sandboxCommand),
              descriptor.availability.requiredCapabilities.allSatisfy({
                  $0 == .workspaceRead || $0 == .htmlValidation
              }),
              descriptor.argumentSchema.isObject,
              descriptor.legacyAdapter != nil else {
            throw GatewayError.invalidReadOnlyContract
        }
        let providerDefinition = ProviderToolDefinition(descriptor: descriptor)
        guard providerDefinition.type == "function",
              providerDefinition.function.name == descriptor.name,
              providerDefinition.function.strict,
              providerDefinition.function.parameters == descriptor.argumentSchema.strictProviderValue else {
            throw GatewayError.invalidReadOnlyContract
        }
    }

    private func revalidate(
        _ prepared: PreparedDeveloperReadOnlyCanaryToolInvocation
    ) throws {
        guard prepared.policyConfigurationSHA256 == policy.configurationSHA256,
              prepared.invocation.providerCallID.map(Self.isSafeProviderCallIdentity) == true,
              prepared.invocation.tool == prepared.descriptor.identity,
              prepared.invocation.effectClass == .readOnlyLocal,
              prepared.invocation.locality == .onDevice,
              prepared.providerDefinition == ProviderToolDefinition(descriptor: prepared.descriptor),
              prepared.targets.allSatisfy({ $0.access == .inspect || $0.access == .read }) else {
            throw GatewayError.preparedInvocationMismatch
        }
        let registered: ToolDescriptor
        do {
            registered = try registry.descriptor(named: prepared.descriptor.name)
        } catch {
            throw GatewayError.preparedInvocationMismatch
        }
        guard registered == prepared.descriptor,
              policy.descriptor(for: prepared.descriptor.identity) == prepared.descriptor,
              policy.contractFingerprint(for: prepared.descriptor.identity)?.contractSHA256
                == prepared.contractSHA256 else {
            throw GatewayError.preparedInvocationMismatch
        }
        do {
            guard try CanonicalToolContract.sha256(prepared.descriptor)
                    == prepared.contractSHA256,
                  try prepared.descriptor.canonicalArgumentDigest(
                      for: prepared.invocation.arguments
                  ) == prepared.invocation.canonicalArgumentDigest,
                  try prepared.descriptor.extractTargets(
                      from: prepared.invocation.arguments
                  ) == prepared.targets,
                  try registry.legacyRequest(
                      name: prepared.descriptor.name,
                      version: prepared.descriptor.version.description,
                      arguments: prepared.invocation.arguments
                  ) == prepared.legacyRequest else {
                throw GatewayError.preparedInvocationMismatch
            }
        } catch let error as GatewayError {
            throw error
        } catch {
            throw GatewayError.preparedInvocationMismatch
        }
        try validatePolicyAndReadOnlyContract(prepared.descriptor)
    }

    private static func isSafeProviderCallIdentity(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.utf8.count <= 512 && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                    !CharacterSet.controlCharacters.contains(scalar) &&
                    scalar.properties.generalCategory != .format
            }
    }

    private static func idempotencyKey(
        request: DeveloperReadOnlyCanaryToolRequest,
        canonicalArgumentDigest: String,
        policyConfigurationSHA256: String
    ) throws -> String {
        try CanonicalShadowDigest.sha256(
            domain: .developerReadOnlyCanaryInvocation,
            DeveloperReadOnlyCanaryInvocationDigestMaterial(
                runID: request.runID,
                callID: request.callID,
                providerCallID: request.providerCallID,
                modelAttemptID: request.modelAttemptID,
                tool: ToolIdentity(name: request.toolName, version: request.toolVersion),
                canonicalArgumentDigest: canonicalArgumentDigest,
                policyConfigurationSHA256: policyConfigurationSHA256
            )
        )
    }
}

private typealias GatewayError = DeveloperReadOnlyCanaryToolGatewayError

private struct DeveloperReadOnlyCanaryInvocationDigestMaterial: Codable {
    let runID: RunID
    let callID: ToolCallID
    let providerCallID: String
    let modelAttemptID: AttemptID
    let tool: ToolIdentity
    let canonicalArgumentDigest: String
    let policyConfigurationSHA256: String
}
