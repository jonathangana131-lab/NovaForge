import AgentDomain
import AgentProviders
@testable import AgentShadow
import AgentTools
import XCTest

final class DeveloperReadOnlyCanaryToolGatewayTests: XCTestCase {
    func testAllCanonicalReadOnlyToolsPrepareWithStrictTypedArguments() async throws {
        let fixture = ShadowTestFixture(seed: 41)
        let descriptors = canonicalReadOnlyDescriptors
        XCTAssertEqual(descriptors.count, 12)
        let policy = try await makePolicy(fixture: fixture, tools: descriptors)
        let backend = RecordingReadOnlyBackend(mode: .output("ok"))
        let gateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: try SandboxToolCatalog.canonicalRegistry(),
            backend: backend
        )

        for (index, descriptor) in descriptors.enumerated() {
            let prepared = try gateway.prepare(request(
                fixture: fixture,
                index: UInt64(index + 1),
                descriptor: descriptor,
                arguments: validArguments(for: descriptor.name)
            ))
            XCTAssertEqual(prepared.descriptor, descriptor)
            XCTAssertTrue(prepared.providerDefinition.function.strict, descriptor.name)
            XCTAssertEqual(
                prepared.providerDefinition.function.parameters,
                descriptor.argumentSchema.strictProviderValue,
                descriptor.name
            )
            XCTAssertEqual(prepared.invocation.effectClass, .readOnlyLocal)
            XCTAssertEqual(prepared.invocation.locality, .onDevice)
            XCTAssertTrue(prepared.targets.allSatisfy {
                $0.access == .inspect || $0.access == .read
            })
            XCTAssertEqual(prepared.legacyRequest.name, descriptor.name)
        }
    }

    func testSuccessfulExecutionPreservesProviderIdentityDigestAndLegacyRequest() async throws {
        let fixture = ShadowTestFixture(seed: 42)
        let policy = try await makePolicy(
            fixture: fixture,
            tools: [ReadFileTool.descriptor]
        )
        let backend = RecordingReadOnlyBackend(mode: .output("file contents"))
        let gateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: try SandboxToolCatalog.canonicalRegistry(),
            backend: backend
        )
        let raw = request(
            fixture: fixture,
            descriptor: ReadFileTool.descriptor,
            arguments: .object(["path": .string("Sources/App.swift")])
        )

        let first = try gateway.prepare(raw)
        let second = try gateway.prepare(raw)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.invocation.providerCallID, raw.providerCallID)
        XCTAssertEqual(
            first.invocation.canonicalArgumentDigest,
            try ReadFileTool.descriptor.canonicalArgumentDigest(for: raw.arguments)
        )
        XCTAssertTrue(first.invocation.idempotencyKey.hasPrefix("sha256:"))
        XCTAssertEqual(first.legacyRequest.name, "read_file")
        XCTAssertEqual(first.legacyRequest.arguments["path"], "Sources/App.swift")

        let result = try await gateway.execute(first)
        XCTAssertEqual(result.prepared, first)
        XCTAssertEqual(result.output, "file contents")
        XCTAssertEqual(result.outputByteCount, 13)
        let backendRequests = await backend.requests()
        XCTAssertEqual(backendRequests, [first.legacyRequest])
    }

    func testUnknownAliasVersionEffectfulAndSpoofedDescriptorsFailClosed() async throws {
        let fixture = ShadowTestFixture(seed: 43)
        let policy = try await makePolicy(
            fixture: fixture,
            tools: [ReadFileTool.descriptor]
        )
        let backend = RecordingReadOnlyBackend(mode: .output("unused"))
        let canonicalGateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: try SandboxToolCatalog.canonicalRegistry(),
            backend: backend
        )

        XCTAssertThrowsError(try canonicalGateway.prepare(request(
            fixture: fixture,
            name: "not_a_tool",
            version: "1.0.0",
            arguments: .object([:])
        ))) { error in
            XCTAssertEqual(error as? GatewayError, .unknownTool)
        }
        XCTAssertThrowsError(try canonicalGateway.prepare(request(
            fixture: fixture,
            name: "read_file",
            version: "9.9.9",
            arguments: .object(["path": .string("README.md")])
        ))) { error in
            XCTAssertEqual(error as? GatewayError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try canonicalGateway.prepare(request(
            fixture: fixture,
            name: "write_file",
            version: "1.0.0",
            arguments: .object([
                "path": .string("README.md"),
                "contents": .string("mutate"),
            ])
        ))) { error in
            XCTAssertEqual(error as? GatewayError, .effectfulTool)
        }

        let aliasGateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: try ToolRegistry(tools: [.init(AliasedReadFileTool.self)]),
            backend: backend
        )
        XCTAssertThrowsError(try aliasGateway.prepare(request(
            fixture: fixture,
            name: "cat_file",
            version: "1.0.0",
            arguments: .object(["path": .string("README.md")])
        ))) { error in
            XCTAssertEqual(error as? GatewayError, .aliasNotAllowed)
        }

        let spoofGateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: try ToolRegistry(tools: [.init(SpoofedReadFileTool.self)]),
            backend: backend
        )
        XCTAssertThrowsError(try spoofGateway.prepare(request(
            fixture: fixture,
            descriptor: ReadFileTool.descriptor,
            arguments: .object(["path": .string("README.md")])
        ))) { error in
            XCTAssertEqual(error as? GatewayError, .descriptorNotFrozen)
        }
        let backendRequests = await backend.requests()
        XCTAssertEqual(backendRequests, [])
    }

    func testArgumentsProviderIdentityAndOutputAreStrictlyBounded() async throws {
        let fixture = ShadowTestFixture(seed: 44)
        let policy = try await makePolicy(
            fixture: fixture,
            tools: [ReadFileTool.descriptor]
        )
        let normalBackend = RecordingReadOnlyBackend(mode: .output("unused"))
        let gateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: try SandboxToolCatalog.canonicalRegistry(),
            backend: normalBackend
        )

        XCTAssertThrowsError(try gateway.prepare(request(
            fixture: fixture,
            descriptor: ReadFileTool.descriptor,
            arguments: .object(["path": .number(.integer(7))])
        ))) { error in
            XCTAssertEqual(error as? GatewayError, .invalidArguments)
        }
        XCTAssertThrowsError(try gateway.prepare(request(
            fixture: fixture,
            descriptor: ReadFileTool.descriptor,
            arguments: .object([
                "path": .string("README.md"),
                "hostile_unknown": .string(String(repeating: "x", count: 2_100_001)),
            ])
        ))) { error in
            XCTAssertEqual(error as? GatewayError, .argumentTooLarge)
        }
        var invalidIdentity = request(
            fixture: fixture,
            descriptor: ReadFileTool.descriptor,
            arguments: .object(["path": .string("README.md")])
        )
        invalidIdentity = DeveloperReadOnlyCanaryToolRequest(
            runID: invalidIdentity.runID,
            callID: invalidIdentity.callID,
            providerCallID: "call id with spaces",
            modelAttemptID: invalidIdentity.modelAttemptID,
            toolName: invalidIdentity.toolName,
            toolVersion: invalidIdentity.toolVersion,
            arguments: invalidIdentity.arguments
        )
        XCTAssertThrowsError(try gateway.prepare(invalidIdentity)) { error in
            XCTAssertEqual(error as? GatewayError, .invalidProviderCallIdentity)
        }

        let overflowBackend = RecordingReadOnlyBackend(
            mode: .output(String(repeating: "o", count: 2_100_001))
        )
        let overflowGateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: try SandboxToolCatalog.canonicalRegistry(),
            backend: overflowBackend
        )
        let prepared = try overflowGateway.prepare(request(
            fixture: fixture,
            descriptor: ReadFileTool.descriptor,
            arguments: .object(["path": .string("README.md")])
        ))
        do {
            _ = try await overflowGateway.execute(prepared)
            XCTFail("Oversized output unexpectedly crossed the gateway")
        } catch {
            XCTAssertEqual(error as? GatewayError, .outputTooLarge)
        }
    }

    func testCancellationAndBackendErrorsAreSanitized() async throws {
        let fixture = ShadowTestFixture(seed: 45)
        let policy = try await makePolicy(
            fixture: fixture,
            tools: [ReadFileTool.descriptor]
        )
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let raw = request(
            fixture: fixture,
            descriptor: ReadFileTool.descriptor,
            arguments: .object(["path": .string("README.md")])
        )

        let cancelledPrepare = await Task { () -> GatewayError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try DeveloperReadOnlyCanaryToolGateway(
                    policy: policy,
                    registry: registry,
                    backend: RecordingReadOnlyBackend(mode: .output("unused"))
                ).prepare(raw)
                return nil
            } catch {
                return error as? GatewayError
            }
        }.value
        XCTAssertEqual(cancelledPrepare, .cancelled)

        let cancellingBackend = RecordingReadOnlyBackend(mode: .cancel)
        let cancellingGateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: registry,
            backend: cancellingBackend
        )
        let prepared = try cancellingGateway.prepare(raw)
        do {
            _ = try await cancellingGateway.execute(prepared)
            XCTFail("Cancellation unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? GatewayError, .cancelled)
        }

        let failingBackend = RecordingReadOnlyBackend(mode: .secretFailure)
        let failingGateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: registry,
            backend: failingBackend
        )
        do {
            _ = try await failingGateway.execute(try failingGateway.prepare(raw))
            XCTFail("Backend failure unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? GatewayError, .backendFailed)
            XCTAssertFalse(String(describing: error).contains("credential"))
            XCTAssertFalse(String(describing: error).contains("private/path"))
        }
    }

    func testPreparedInvocationCannotCrossPolicyBoundary() async throws {
        let fixture = ShadowTestFixture(seed: 46)
        let first = try await makePolicy(
            fixture: fixture,
            tools: [ReadFileTool.descriptor],
            model: "read-route-a"
        )
        let second = try await makePolicy(
            fixture: fixture,
            tools: [ReadFileTool.descriptor],
            model: "read-route-b"
        )
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let backend = RecordingReadOnlyBackend(mode: .output("unused"))
        let prepared = try DeveloperReadOnlyCanaryToolGateway(
            policy: first,
            registry: registry,
            backend: backend
        ).prepare(request(
            fixture: fixture,
            descriptor: ReadFileTool.descriptor,
            arguments: .object(["path": .string("README.md")])
        ))

        let otherGateway = DeveloperReadOnlyCanaryToolGateway(
            policy: second,
            registry: registry,
            backend: backend
        )
        do {
            _ = try await otherGateway.execute(prepared)
            XCTFail("Prepared invocation crossed its frozen policy boundary")
        } catch {
            XCTAssertEqual(error as? GatewayError, .preparedInvocationMismatch)
        }
        let backendRequests = await backend.requests()
        XCTAssertEqual(backendRequests, [])
    }

    func testPolicyRejectsEmptyDuplicateEffectfulAndOverLimitToolSets() async throws {
        let fixture = ShadowTestFixture(seed: 47)
        let store = try await fixture.makeStore()
        let attestation = try await DarkReplayEngine(reader: store).attest(fixture.runID)
        let baselineCapability = try readCapability(model: "policy-baseline")

        await assertPolicyError(.emptyToolSet) {
            try await DeveloperReadOnlyCanaryPolicy.freeze(
                for: attestation,
                hostedReadOnlyToolsCapability: baselineCapability,
                tools: []
            )
        }
        await assertPolicyError(.duplicateTool(ReadFileTool.descriptor.identity)) {
            try await DeveloperReadOnlyCanaryPolicy.freeze(
                for: attestation,
                hostedReadOnlyToolsCapability: baselineCapability,
                tools: [ReadFileTool.descriptor, ReadFileTool.descriptor]
            )
        }
        await assertPolicyError(.toolDenied(
            WriteFileTool.descriptor.identity,
            .effectful(.scopedReversibleWrite)
        )) {
            try await DeveloperReadOnlyCanaryPolicy.freeze(
                for: attestation,
                hostedReadOnlyToolsCapability: baselineCapability,
                tools: [WriteFileTool.descriptor]
            )
        }

        let oneToolCapability = try readCapability(
            model: "one-tool-route",
            maximumToolDefinitions: 1
        )
        await assertPolicyError(.toolDefinitionLimitExceeded(maximum: 1, actual: 2)) {
            try await DeveloperReadOnlyCanaryPolicy.freeze(
                for: attestation,
                hostedReadOnlyToolsCapability: oneToolCapability,
                tools: [ReadFileTool.descriptor, SearchTextTool.descriptor]
            )
        }
    }

    func testPolicyDigestCanonicalizesToolOrderAndBindsRouteRunAndFeatures() async throws {
        let fixture = ShadowTestFixture(seed: 48)
        let first = try await makePolicy(
            fixture: fixture,
            tools: [ReadFileTool.descriptor, SearchTextTool.descriptor],
            model: "bound-route"
        )
        let reversed = try await makePolicy(
            fixture: fixture,
            tools: [SearchTextTool.descriptor, ReadFileTool.descriptor],
            model: "bound-route"
        )
        let changedRoute = try await makePolicy(
            fixture: fixture,
            tools: [ReadFileTool.descriptor, SearchTextTool.descriptor],
            model: "other-route"
        )

        XCTAssertEqual(first.configurationSHA256, reversed.configurationSHA256)
        XCTAssertEqual(first.allowedToolContracts, reversed.allowedToolContracts)
        XCTAssertNotEqual(first.configurationSHA256, changedRoute.configurationSHA256)
        try first.validateFrozenInputs(
            runID: fixture.runID,
            hostedReadOnlyToolsCapability: first.hostedReadOnlyToolsCapability,
            features: fixture.context.features
        )
        XCTAssertThrowsError(try first.validateFrozenInputs(
            runID: shadowID(999_048),
            hostedReadOnlyToolsCapability: first.hostedReadOnlyToolsCapability,
            features: fixture.context.features
        )) { error in
            XCTAssertEqual(
                error as? DeveloperReadOnlyCanaryPolicyError,
                .runChanged(expected: fixture.runID, actual: shadowID(999_048))
            )
        }
        XCTAssertThrowsError(try first.validateFrozenInputs(
            runID: fixture.runID,
            hostedReadOnlyToolsCapability: changedRoute.hostedReadOnlyToolsCapability,
            features: fixture.context.features
        )) { error in
            XCTAssertEqual(error as? DeveloperReadOnlyCanaryPolicyError, .routeChanged)
        }
        XCTAssertThrowsError(try first.validateFrozenInputs(
            runID: fixture.runID,
            hostedReadOnlyToolsCapability: first.hostedReadOnlyToolsCapability,
            features: AgentFeatureSet(["changed"])
        )) { error in
            XCTAssertEqual(error as? DeveloperReadOnlyCanaryPolicyError, .featureSetChanged)
        }
    }
}

private typealias GatewayError = DeveloperReadOnlyCanaryToolGatewayError

private var canonicalReadOnlyDescriptors: [ToolDescriptor] {
    SandboxToolCatalog.all.map(\.descriptor).filter {
        $0.effectClass == .readOnlyLocal
    }
}

private func makePolicy(
    fixture: ShadowTestFixture,
    tools: [ToolDescriptor],
    model: String = "read-canary-model"
) async throws -> FrozenDeveloperReadOnlyCanaryPolicy {
    let store = try await fixture.makeStore()
    let attestation = try await DarkReplayEngine(reader: store).attest(fixture.runID)
    return try await DeveloperReadOnlyCanaryPolicy.freeze(
        for: attestation,
        hostedReadOnlyToolsCapability: try readCapability(model: model),
        tools: tools
    )
}

private func readCapability(
    model: String,
    maximumToolDefinitions: UInt32 = 12
) throws -> HostedReadOnlyToolsProviderCapability {
    let baseline = ProviderModelCapabilities.hostedResponsesReadOnlyToolsCanaryBaseline
    let capabilities = ProviderModelCapabilities(
        features: baseline.features,
        contextWindowTokens: baseline.contextWindowTokens,
        maximumOutputTokens: baseline.maximumOutputTokens,
        maximumToolDefinitions: maximumToolDefinitions,
        maximumToolCallsPerTurn: 1
    )
    let catalog = TrustedHostedProviderCatalog.openAIResponses(
        model: ProviderModelID(rawValue: model),
        capabilities: capabilities
    )
    return try catalog.hostedReadOnlyToolsCapability(adapterID: catalog.adapterID)
}

private func request(
    fixture: ShadowTestFixture,
    index: UInt64 = 1,
    descriptor: ToolDescriptor,
    arguments: JSONValue
) -> DeveloperReadOnlyCanaryToolRequest {
    request(
        fixture: fixture,
        index: index,
        name: descriptor.name,
        version: descriptor.version.description,
        arguments: arguments
    )
}

private func request(
    fixture: ShadowTestFixture,
    index: UInt64 = 1,
    name: String,
    version: String,
    arguments: JSONValue
) -> DeveloperReadOnlyCanaryToolRequest {
    DeveloperReadOnlyCanaryToolRequest(
        runID: fixture.runID,
        callID: shadowID(200_000 + index),
        providerCallID: "call_provider_\(index)",
        modelAttemptID: fixture.secondAttemptID,
        toolName: name,
        toolVersion: version,
        arguments: arguments
    )
}

private func validArguments(for name: String) -> JSONValue {
    switch name {
    case "list_directory", "list_tree", "workspace_summary":
        .object([:])
    case "file_info", "read_file", "validate_json", "extract_outline":
        .object(["path": .string("Sources/App.swift")])
    case "read_file_range":
        .object([
            "path": .string("Sources/App.swift"),
            "start_line": .number(.integer(1)),
            "line_count": .number(.integer(20)),
        ])
    case "tail_file":
        .object([
            "path": .string("Logs/latest.log"),
            "line_count": .number(.integer(20)),
        ])
    case "search_text":
        .object(["query": .string("Agent")])
    case "diff_files":
        .object([
            "left": .string("before.txt"),
            "right": .string("after.txt"),
        ])
    case "validate_html_file":
        .object([
            "path": .string("index.html"),
            "profile": .string("page"),
        ])
    default:
        preconditionFailure("Missing valid argument fixture for \(name)")
    }
}

private func assertPolicyError(
    _ expected: DeveloperReadOnlyCanaryPolicyError,
    operation: () async throws -> FrozenDeveloperReadOnlyCanaryPolicy
) async {
    do {
        _ = try await operation()
        XCTFail("Policy unexpectedly froze")
    } catch {
        XCTAssertEqual(error as? DeveloperReadOnlyCanaryPolicyError, expected)
    }
}

private enum RecordingBackendMode: Sendable {
    case output(String)
    case cancel
    case secretFailure
}

private enum SecretBackendFailure: Error, Sendable {
    case leaked(String)
}

private actor RecordingReadOnlyBackend: DeveloperReadOnlyCanaryToolBackend {
    private let mode: RecordingBackendMode
    private var recorded: [LegacySandboxToolRequest] = []

    init(mode: RecordingBackendMode) {
        self.mode = mode
    }

    func executeReadOnly(_ request: LegacySandboxToolRequest) async throws -> String {
        recorded.append(request)
        switch mode {
        case let .output(output):
            return output
        case .cancel:
            throw CancellationError()
        case .secretFailure:
            throw SecretBackendFailure.leaked(
                "credential=super-secret path=/private/path"
            )
        }
    }

    func requests() -> [LegacySandboxToolRequest] {
        recorded
    }
}

private enum AliasedReadFileTool: AgentTool {
    typealias Arguments = PathArguments
    static let metadata = copiedReadFileMetadata(
        aliases: ["cat_file"],
        description: ReadFileTool.metadata.description
    )
}

private enum SpoofedReadFileTool: AgentTool {
    typealias Arguments = PathArguments
    static let metadata = copiedReadFileMetadata(
        aliases: [],
        description: "Spoofed read-file contract"
    )
}

private func copiedReadFileMetadata(
    aliases: [String],
    description: String
) -> ToolDescriptorMetadata {
    let source = ReadFileTool.metadata
    return ToolDescriptorMetadata(
        name: source.name,
        version: source.version,
        aliases: aliases,
        toolset: source.toolset,
        description: description,
        availability: source.availability,
        effectClass: source.effectClass,
        approvalClass: source.approvalClass,
        targetStrategy: source.targetStrategy,
        parallelSafety: source.parallelSafety,
        concurrencyKey: source.concurrencyKey,
        limits: source.limits,
        redaction: source.redaction,
        legacyAdapter: source.legacyAdapter,
        receipt: source.receipt,
        evidence: source.evidence,
        ui: source.ui
    )
}
