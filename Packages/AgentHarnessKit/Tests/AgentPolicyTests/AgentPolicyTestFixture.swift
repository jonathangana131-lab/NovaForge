import AgentDomain
@testable import AgentPolicy
import AgentTools
import CryptoKit
import Foundation

enum AgentPolicyTestFixture {
    static func descriptor(_ name: String) throws -> ToolDescriptor {
        try SandboxToolCatalog.canonicalRegistry().descriptor(named: name)
    }

    static func invocation(
        _ name: String,
        arguments: JSONValue,
        idempotencyKey: String = "operation-1"
    ) throws -> (ToolDescriptor, ToolInvocation) {
        let descriptor = try descriptor(name)
        return (
            descriptor,
            ToolInvocation(
                callID: ToolCallID(),
                modelAttemptID: AttemptID(),
                tool: descriptor.identity,
                arguments: arguments,
                canonicalArgumentDigest: try descriptor.canonicalArgumentDigest(
                    for: arguments
                ),
                idempotencyKey: idempotencyKey,
                effectClass: descriptor.effectClass,
                locality: .onDevice
            )
        )
    }

    static func digest(_ text: String) throws -> AgentPolicy.SHA256Digest {
        let hash = SHA256.hash(data: Data(text.utf8))
        return try AgentPolicy.SHA256Digest(
            "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
        )
    }

    static func request(
        _ name: String,
        arguments: JSONValue,
        resolver: WorkspaceTargetResolverAuthority,
        workspaceID: WorkspaceID = WorkspaceID(),
        runID: RunID = RunID(),
        idempotencyKey: String = "operation-1"
    ) async throws -> RiskPolicyRequest {
        let (descriptor, invocation) = try invocation(
            name,
            arguments: arguments,
            idempotencyKey: idempotencyKey
        )
        return try await RiskPolicyRequest.resolveAgentV2(
            runID: runID,
            projectID: nil,
            workspaceID: workspaceID,
            sessionID: nil,
            backend: .onDevice,
            descriptor: descriptor,
            invocation: invocation,
            using: resolver
        )
    }
}

/// Keeps older test setup concise while production composition still requires
/// an explicit shared revision authority. Tests that cross authority boundaries
/// pass `policyRevisionAuthority` from this evaluator onward.
extension LayeredRiskPolicyEvaluator {
    init(
        configuration: RiskPolicyConfiguration,
        clock: any PolicyClock,
        resolver: WorkspaceTargetResolverAuthority,
        grantStore: (any DurablePolicyGrantRedemptionStore)? = nil,
        advisory: (any RiskPolicyAdvisoryTransport)? = nil
    ) throws {
        try self.init(
            policyRevisionAuthority: PolicyRevisionAuthority(
                configuration: configuration
            ),
            clock: clock,
            resolver: resolver,
            grantStore: grantStore,
            advisory: advisory
        )
    }
}

actor MutableResolutionBackend: WorkspaceTargetResolutionBackend {
    var resolvedPathOverride: String?
    var resolvedPathOverrides: [String: String] = [:]
    var workspaceRevision = "workspace-r1"
    var resolutionRevision = "resolution-r1"
    var previewSeed = "preview-r1"
    var commandTargets: [NormalizedToolTarget] = []
    var containmentIdentityOverride: String?
    var objectInodeOverride: UInt64?
    var objectLinkCount: UInt64 = 1
    var delayNanoseconds: UInt64 = 0
    var resolutionHook: (@Sendable (Int) -> Void)?
    private(set) var resolutionCount = 0

    func configure(
        resolvedPathOverride: String? = nil,
        resolvedPathOverrides: [String: String]? = nil,
        workspaceRevision: String? = nil,
        resolutionRevision: String? = nil,
        previewSeed: String? = nil,
        commandTargets: [NormalizedToolTarget]? = nil,
        containmentIdentityOverride: String? = nil,
        objectInodeOverride: UInt64? = nil,
        objectLinkCount: UInt64? = nil,
        delayNanoseconds: UInt64? = nil
    ) {
        if let resolvedPathOverride {
            self.resolvedPathOverride = resolvedPathOverride
        }
        if let resolvedPathOverrides {
            self.resolvedPathOverrides = resolvedPathOverrides
        }
        if let workspaceRevision { self.workspaceRevision = workspaceRevision }
        if let resolutionRevision { self.resolutionRevision = resolutionRevision }
        if let previewSeed { self.previewSeed = previewSeed }
        if let commandTargets { self.commandTargets = commandTargets }
        if let containmentIdentityOverride {
            self.containmentIdentityOverride = containmentIdentityOverride
        }
        if let objectInodeOverride {
            self.objectInodeOverride = objectInodeOverride
        }
        if let objectLinkCount { self.objectLinkCount = objectLinkCount }
        if let delayNanoseconds { self.delayNanoseconds = delayNanoseconds }
    }

    func setResolutionHook(
        _ hook: (@Sendable (Int) -> Void)?
    ) {
        resolutionHook = hook
    }

    func resolveTargets(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        workspaceID: WorkspaceID
    ) async throws -> WorkspaceResolutionCandidate {
        resolutionCount += 1
        resolutionHook?(resolutionCount)
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let logical: [NormalizedToolTarget]
        switch descriptor.targetStrategy {
        case .legacyCommandParserRequired:
            logical = commandTargets
        case .workspaceRoot, .argumentPaths, .arrayArgumentPaths:
            logical = try NormalizedToolTarget.canonicalize(
                descriptor.extractTargets(from: invocation.arguments)
            )
        }
        let preconditions = try logical.enumerated().map { index, target in
            let resolved = resolvedPathOverrides[target.path]
                ?? resolvedPathOverride
                ?? target.path
            let snapshot = try ResolvedToolTargetSnapshot.make(
                workspaceID: workspaceID,
                target: target,
                resolvedRelativePath: resolved,
                disposition: .existingObject,
                workspaceRootIdentity: "root-identity",
                containmentIdentity:
                    containmentIdentityOverride ?? "contained-\(resolved)",
                objectKind: .regularFile,
                objectDevice: 1,
                objectInode: objectInodeOverride ?? UInt64(index + 1),
                objectLinkCount: objectLinkCount,
                resolutionRevision: resolutionRevision,
                traversedSymlink: resolved != target.path
            )
            return ApprovalPrecondition(
                resolution: snapshot,
                previewSHA256: try AgentPolicyTestFixture.digest(
                    "\(previewSeed)-\(index)-\(resolved)"
                )
            )
        }
        return try WorkspaceResolutionCandidate(
            preconditions: preconditions,
            workspaceRevision: workspaceRevision
        )
    }
}

actor SequencePolicyClock: PolicyClock {
    private var values: [AgentInstant]
    private var index = 0
    private(set) var readCount = 0

    init(_ values: [Int64]) {
        self.values = values.map(AgentInstant.init(rawValue:))
    }

    func currentInstant() throws -> AgentInstant {
        readCount += 1
        guard !values.isEmpty else { throw ClockError.empty }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }

    enum ClockError: Error { case empty }
}

actor StaticApprovalPrompt: ApprovalDecisionPrompting {
    var decision: ApprovalDecision
    private(set) var promptCount = 0
    private(set) var lastContext: DurableApprovalPromptContext?

    init(_ decision: ApprovalDecision) { self.decision = decision }

    func requestDecision(
        for context: DurableApprovalPromptContext
    ) -> ApprovalDecision {
        lastContext = context
        promptCount += 1
        return decision
    }
}
