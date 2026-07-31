import AgentDomain
@testable import AgentProviders
import AgentTools
import XCTest

final class LocalModelSingleCallToolsCapabilityTests: XCTestCase {
    func testTrustedFactoryMintsExactSingleCallLocalToolRoute() throws {
        let fixture = try makeFixture()
        let catalog = try makeCatalog(fixture)
        let capability = try catalog.localSingleCallToolsCapability(
            adapterID: fixture.adapterID
        )
        let snapshot = capability.snapshot

        XCTAssertEqual(snapshot.providerID.rawValue, "novaforge-local")
        XCTAssertEqual(snapshot.modelID, fixture.modelID)
        XCTAssertEqual(snapshot.adapterID, fixture.adapterID)
        XCTAssertEqual(snapshot.dialect, .openAICompatibleChat)
        XCTAssertEqual(snapshot.requestPath, "/v1/local/chat/completions")
        XCTAssertEqual(snapshot.deployment, .onDevice)
        XCTAssertEqual(snapshot.provenance, .builtInLocalModel)
        XCTAssertEqual(snapshot.maximumToolDefinitions, 2)
        XCTAssertEqual(snapshot.maximumToolCallsPerTurn, 1)
        XCTAssertFalse(snapshot.parallelToolDispatchEnabled)
        XCTAssertFalse(
            snapshot.capabilities.features.contains(.parallelToolCalls)
        )
        XCTAssertEqual(
            snapshot.capabilities.features,
            ProviderCapabilitySet([
                .cancellation,
                .streaming,
                .strictToolSchema,
                .temperature,
                .tools,
                .typedToolArguments,
                .usageStreaming,
            ])
        )
        assertStrictSHA256(snapshot.attestation.attestationSHA256)
        assertStrictSHA256(snapshot.orderedProviderDefinitionsSHA256)
        assertStrictSHA256(snapshot.descriptorSHA256)

        let adapter = try catalog.providerCatalog().adapter(
            id: fixture.adapterID
        )
        let request = canonicalRequest(
            model: fixture.modelID,
            tools: providerDefinitions(fixture.registry)
        )
        let encoded = try adapter.encode(request)
        XCTAssertEqual(encoded.relativePath, "/v1/local/chat/completions")
        let body = try XCTUnwrap(encoded.body.localCapabilityTestObject)
        XCTAssertEqual(body["model"], .string(fixture.modelID.rawValue))
        XCTAssertNil(body["base_url"])
        XCTAssertNil(body["authorization"])
        XCTAssertNil(body["api_key"])
    }

    func testTextOnlyAndWrongAdapterCannotMintToolAuthority() throws {
        let textOnly = try TrustedLocalProviderCatalog.textOnly(
            modelID: .init(rawValue: "hermes-text")
        )
        XCTAssertThrowsError(
            try textOnly.localSingleCallToolsCapability(
                adapterID: textOnly.adapterID
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalModelSingleCallToolsError,
                .authorityUnavailable
            )
        }

        let fixture = try makeFixture()
        let catalog = try makeCatalog(fixture)
        let wrongID = ProviderAdapterID(rawValue: "caller-route")
        XCTAssertThrowsError(
            try catalog.localSingleCallToolsCapability(adapterID: wrongID)
        ) { error in
            XCTAssertEqual(
                error as? LocalModelSingleCallToolsError,
                .unknownAdapter(wrongID)
            )
        }
    }

    func testEveryArtifactAndCompilerMismatchFailsClosed() throws {
        let fixture = try makeFixture()
        let mismatches: [(
            LocalModelAttestedBinding,
            LocalModelArtifactVerification
        )] = [
            (
                .modelArtifactSHA256,
                try verification(modelArtifactSHA256: sha("0"))
            ),
            (
                .tokenizerSHA256,
                try verification(tokenizerSHA256: sha("1"))
            ),
            (
                .promptTemplateSHA256,
                try verification(promptTemplateSHA256: sha("2"))
            ),
            (
                .contextConfigurationSHA256,
                try verification(contextConfigurationSHA256: sha("3"))
            ),
            (
                .grammarSHA256,
                try verification(grammarSHA256: sha("4"))
            ),
            (
                .grammarCompilerID,
                try verification(grammarCompilerID: "other-compiler")
            ),
            (
                .grammarCompilerVersion,
                try verification(grammarCompilerVersion: "9.9.9")
            ),
        ]

        for (binding, observed) in mismatches {
            XCTAssertThrowsError(try TrustedLocalProviderCatalog
                .grammarConstrainedSingleCall(
                    modelID: fixture.modelID,
                    adapterID: fixture.adapterID,
                    contextWindowTokens: fixture.contextWindowTokens,
                    maximumOutputTokens: fixture.maximumOutputTokens,
                    verifiedArtifacts: observed,
                    attestation: fixture.attestation,
                    toolRegistry: fixture.registry
                )) { error in
                    XCTAssertEqual(
                        error as? LocalModelSingleCallToolsError,
                        .bindingMismatch(binding)
                    )
                }
        }
    }

    func testEveryRouteIdentityAndLimitMismatchFailsClosed() throws {
        let fixture = try makeFixture()
        let attempts: [(
            LocalModelAttestedBinding,
            () throws -> TrustedLocalProviderCatalog
        )] = [
            (
                .modelID,
                { try makeCatalog(
                    fixture,
                    modelID: .init(rawValue: "other-model")
                ) }
            ),
            (
                .adapterID,
                { try makeCatalog(
                    fixture,
                    adapterID: .init(rawValue: "other-adapter")
                ) }
            ),
            (
                .contextWindowTokens,
                { try makeCatalog(
                    fixture,
                    contextWindowTokens: fixture.contextWindowTokens + 1
                ) }
            ),
            (
                .maximumOutputTokens,
                { try makeCatalog(
                    fixture,
                    maximumOutputTokens: fixture.maximumOutputTokens + 1
                ) }
            ),
        ]

        for (binding, attempt) in attempts {
            XCTAssertThrowsError(try attempt()) { error in
                XCTAssertEqual(
                    error as? LocalModelSingleCallToolsError,
                    .bindingMismatch(binding)
                )
            }
        }
    }

    func testRegistryDigestAndExactCountMismatchesFailClosed() throws {
        let fixture = try makeFixture()
        let wrongCount = try attestation(
            fixture.registryBinding,
            toolDefinitionCount: 1
        )
        XCTAssertThrowsError(try makeCatalog(
            fixture,
            attestation: wrongCount
        )) { error in
            XCTAssertEqual(
                error as? LocalModelSingleCallToolsError,
                .bindingMismatch(.toolDefinitionCount)
            )
        }

        let wrongDigest = try attestation(
            fixture.registryBinding,
            canonicalToolRegistrySHA256: sha("f")
        )
        XCTAssertThrowsError(try makeCatalog(
            fixture,
            attestation: wrongDigest
        )) { error in
            XCTAssertEqual(
                error as? LocalModelSingleCallToolsError,
                .bindingMismatch(.canonicalToolRegistrySHA256)
            )
        }

        let alternate = try ToolRegistry(tools: [
            AnyAgentTool(ReadFileRangeTool.self),
            AnyAgentTool(WorkspaceSummaryTool.self),
        ])
        XCTAssertEqual(alternate.descriptors.count, 2)
        XCTAssertThrowsError(try makeCatalog(
            fixture,
            toolRegistry: alternate
        )) { error in
            XCTAssertEqual(
                error as? LocalModelSingleCallToolsError,
                .bindingMismatch(.canonicalToolRegistrySHA256)
            )
        }
    }

    func testArtifactVerifierRejectsEveryMalformedDigestAndIdentity() {
        let invalidDigest = "SHA256:" + String(repeating: "A", count: 64)
        let digestAttempts: [(
            LocalModelAttestedBinding,
            () throws -> Void
        )] = [
            (.modelArtifactSHA256, {
                _ = try verification(modelArtifactSHA256: invalidDigest)
            }),
            (.tokenizerSHA256, {
                _ = try verification(tokenizerSHA256: invalidDigest)
            }),
            (.promptTemplateSHA256, {
                _ = try verification(promptTemplateSHA256: invalidDigest)
            }),
            (.contextConfigurationSHA256, {
                _ = try verification(
                    contextConfigurationSHA256: invalidDigest
                )
            }),
            (.grammarSHA256, {
                _ = try verification(grammarSHA256: invalidDigest)
            }),
        ]
        for (binding, attempt) in digestAttempts {
            XCTAssertThrowsError(try attempt()) { error in
                XCTAssertEqual(
                    error as? LocalModelSingleCallToolsError,
                    .invalidDigest(binding)
                )
            }
        }

        XCTAssertThrowsError(try verification(
            grammarCompilerID: "../../compiler"
        )) { error in
            XCTAssertEqual(
                error as? LocalModelSingleCallToolsError,
                .invalidIdentity(.grammarCompilerID)
            )
        }
        XCTAssertThrowsError(try verification(
            grammarCompilerVersion: "1.0 beta"
        )) { error in
            XCTAssertEqual(
                error as? LocalModelSingleCallToolsError,
                .invalidIdentity(.grammarCompilerVersion)
            )
        }
    }

    func testAttestationRejectsEveryMalformedDigest() throws {
        let binding = try TrustedLocalProviderCatalog
            .canonicalToolRegistryBinding(for: canonicalRegistry())
        let invalid = "sha256:" + String(repeating: "g", count: 64)
        let attempts: [(
            LocalModelAttestedBinding,
            () throws -> Void
        )] = [
            (.modelArtifactSHA256, {
                _ = try attestation(binding, modelArtifactSHA256: invalid)
            }),
            (.tokenizerSHA256, {
                _ = try attestation(binding, tokenizerSHA256: invalid)
            }),
            (.promptTemplateSHA256, {
                _ = try attestation(binding, promptTemplateSHA256: invalid)
            }),
            (.contextConfigurationSHA256, {
                _ = try attestation(
                    binding,
                    contextConfigurationSHA256: invalid
                )
            }),
            (.grammarSHA256, {
                _ = try attestation(binding, grammarSHA256: invalid)
            }),
            (.canonicalToolRegistrySHA256, {
                _ = try attestation(
                    binding,
                    canonicalToolRegistrySHA256: invalid
                )
            }),
        ]
        for (field, attempt) in attempts {
            XCTAssertThrowsError(try attempt()) { error in
                XCTAssertEqual(
                    error as? LocalModelSingleCallToolsError,
                    .invalidDigest(field)
                )
            }
        }
    }

    func testAttestationRejectsUnsafeIdentitiesAndInvalidLimits() throws {
        let binding = try TrustedLocalProviderCatalog
            .canonicalToolRegistryBinding(for: canonicalRegistry())
        let attempts: [(LocalModelSingleCallToolsError, () throws -> Void)] = [
            (.invalidIdentity(.grammarCompilerID), {
                _ = try attestation(binding, grammarCompilerID: "compiler/../../x")
            }),
            (.invalidIdentity(.grammarCompilerVersion), {
                _ = try attestation(binding, grammarCompilerVersion: "1 0")
            }),
            (.invalidIdentity(.modelID), {
                _ = try attestation(
                    binding,
                    modelID: .init(rawValue: "../../model")
                )
            }),
            (.invalidIdentity(.modelID), {
                _ = try attestation(
                    binding,
                    modelID: .init(rawValue: "https://remote/model")
                )
            }),
            (.invalidIdentity(.adapterID), {
                _ = try attestation(
                    binding,
                    adapterID: .init(rawValue: "namespace/adapter")
                )
            }),
            (.invalidIdentity(.adapterID), {
                _ = try attestation(
                    binding,
                    adapterID: .init(rawValue: "user@adapter")
                )
            }),
            (.invalidContextWindow, {
                _ = try attestation(binding, contextWindowTokens: 0)
            }),
            (.invalidContextWindow, {
                _ = try attestation(binding, contextWindowTokens: 1_048_577)
            }),
            (.invalidOutputLimit, {
                _ = try attestation(binding, maximumOutputTokens: 0)
            }),
            (.invalidOutputLimit, {
                _ = try attestation(
                    binding,
                    contextWindowTokens: 8_192,
                    maximumOutputTokens: 8_193
                )
            }),
            (.invalidToolDefinitionCount, {
                _ = try attestation(binding, toolDefinitionCount: 0)
            }),
            (.invalidToolDefinitionCount, {
                _ = try attestation(binding, toolDefinitionCount: 129)
            }),
            (.invalidToolCallLimit, {
                _ = try attestation(
                    binding,
                    maximumToolCallsPerTurn: 2
                )
            }),
            (.parallelToolCallsForbidden, {
                _ = try attestation(
                    binding,
                    supportsParallelToolCalls: true
                )
            }),
        ]
        for (expected, attempt) in attempts {
            XCTAssertThrowsError(try attempt()) { error in
                XCTAssertEqual(
                    error as? LocalModelSingleCallToolsError,
                    expected
                )
            }
        }
    }

    func testAttestationEncodingIsDeterministicAndBindsEveryVariableField() throws {
        let fixture = try makeFixture()
        let duplicate = try attestation(fixture.registryBinding)
        XCTAssertEqual(
            fixture.attestation.attestationSHA256,
            duplicate.attestationSHA256
        )

        let variants = try [
            attestation(fixture.registryBinding, modelArtifactSHA256: sha("0")),
            attestation(fixture.registryBinding, tokenizerSHA256: sha("1")),
            attestation(fixture.registryBinding, promptTemplateSHA256: sha("2")),
            attestation(
                fixture.registryBinding,
                contextConfigurationSHA256: sha("3")
            ),
            attestation(fixture.registryBinding, grammarSHA256: sha("4")),
            attestation(fixture.registryBinding, grammarCompilerID: "compiler-b"),
            attestation(fixture.registryBinding, grammarCompilerVersion: "2.0.0"),
            attestation(
                fixture.registryBinding,
                canonicalToolRegistrySHA256: sha("5")
            ),
            attestation(fixture.registryBinding, toolDefinitionCount: 3),
            attestation(
                fixture.registryBinding,
                modelID: .init(rawValue: "other/model")
            ),
            attestation(
                fixture.registryBinding,
                adapterID: .init(rawValue: "other-adapter")
            ),
            attestation(fixture.registryBinding, contextWindowTokens: 16_384),
            attestation(fixture.registryBinding, maximumOutputTokens: 1_025),
        ]
        for variant in variants {
            XCTAssertNotEqual(
                fixture.attestation.attestationSHA256,
                variant.attestationSHA256
            )
        }
    }

    func testCanonicalRegistryEncodingIgnoresRegistrationOrderOnly() throws {
        let forward = try canonicalRegistry()
        let reverse = try ToolRegistry(tools: [
            AnyAgentTool(ReadFileTool.self),
            AnyAgentTool(FileInfoTool.self),
        ])
        let forwardBinding = try TrustedLocalProviderCatalog
            .canonicalToolRegistryBinding(for: forward)
        let reverseBinding = try TrustedLocalProviderCatalog
            .canonicalToolRegistryBinding(for: reverse)
        XCTAssertEqual(forwardBinding, reverseBinding)
        XCTAssertEqual(
            try forward.providerDefinitionsData(),
            try reverse.providerDefinitionsData()
        )

        let verification = try verification()
        let manifest = try attestation(forwardBinding)
        let forwardCatalog = try TrustedLocalProviderCatalog
            .grammarConstrainedSingleCall(
                modelID: manifest.modelID,
                adapterID: manifest.adapterID,
                contextWindowTokens: manifest.contextWindowTokens,
                maximumOutputTokens: manifest.maximumOutputTokens,
                verifiedArtifacts: verification,
                attestation: manifest,
                toolRegistry: forward
            )
        let reverseCatalog = try TrustedLocalProviderCatalog
            .grammarConstrainedSingleCall(
                modelID: manifest.modelID,
                adapterID: manifest.adapterID,
                contextWindowTokens: manifest.contextWindowTokens,
                maximumOutputTokens: manifest.maximumOutputTokens,
                verifiedArtifacts: verification,
                attestation: manifest,
                toolRegistry: reverse
            )
        XCTAssertEqual(
            try forwardCatalog.localSingleCallToolsCapability(
                adapterID: manifest.adapterID
            ),
            try reverseCatalog.localSingleCallToolsCapability(
                adapterID: manifest.adapterID
            )
        )
    }

    func testRequestToolReorderMutationAndCountSpoofsAreRejected() throws {
        let fixture = try makeFixture()
        let catalog = try makeCatalog(fixture)
        let adapter = try catalog.providerCatalog().adapter(
            id: fixture.adapterID
        )
        let definitions = providerDefinitions(fixture.registry)
        XCTAssertEqual(definitions.count, 2)

        XCTAssertThrowsError(try adapter.encode(canonicalRequest(
            model: fixture.modelID,
            tools: definitions.reversed()
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_local_tool_catalog_order_mismatch"
            )
        }

        var changed = definitions
        changed[0] = AgentProviders.ProviderToolDefinition(
            name: changed[0].name,
            description: changed[0].description + " caller widened",
            parameters: changed[0].parameters,
            strict: changed[0].strict
        )
        XCTAssertThrowsError(try adapter.encode(canonicalRequest(
            model: fixture.modelID,
            tools: changed
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_local_tool_catalog_digest_mismatch"
            )
        }

        XCTAssertThrowsError(try adapter.encode(canonicalRequest(
            model: fixture.modelID,
            tools: [definitions[0]]
        ))) { error in
            XCTAssertEqual(
                (error as? ProviderFailure)?.code,
                "provider_local_tool_catalog_count_mismatch"
            )
        }
    }

    func testEveryTrustedRouteSpoofIsRejected() throws {
        let fixture = try makeFixture()
        let catalog = try makeCatalog(fixture)
        let capability = try catalog.localSingleCallToolsCapability(
            adapterID: fixture.adapterID
        )
        let valid = catalog.descriptor
        let widenedCapabilities = ProviderModelCapabilities(
            features: ProviderCapabilitySet(
                valid.route.capabilities.features.values + [.reasoning]
            ),
            contextWindowTokens:
                valid.route.capabilities.contextWindowTokens,
            maximumOutputTokens:
                valid.route.capabilities.maximumOutputTokens,
            maximumToolDefinitions:
                valid.route.capabilities.maximumToolDefinitions,
            maximumToolCallsPerTurn:
                valid.route.capabilities.maximumToolCallsPerTurn
        )
        let spoofs: [(
            LocalModelTrustedRouteBinding,
            ProviderAdapterDescriptor
        )] = [
            (
                .providerID,
                replacing(valid, providerID: .init(rawValue: "openai"))
            ),
            (
                .modelID,
                replacing(valid, modelID: .init(rawValue: "other/model"))
            ),
            (
                .adapterID,
                replacing(
                    valid,
                    adapterID: .init(rawValue: "caller-adapter")
                )
            ),
            (
                .dialect,
                replacing(valid, dialect: .openAIChatCompletions)
            ),
            (
                .requestPath,
                replacing(valid, requestPath: "/v1/chat/completions")
            ),
            (
                .capabilities,
                replacing(valid, capabilities: widenedCapabilities)
            ),
            (
                .deployment,
                replacing(valid, deployment: .callerManaged)
            ),
            (
                .provenance,
                replacing(valid, provenance: .callerConfigured)
            ),
        ]

        for (field, spoof) in spoofs {
            XCTAssertThrowsError(try spoof
                .validatedLocalModelSingleCallToolsSnapshot(
                    attestation: fixture.attestation,
                    orderedProviderDefinitionsSHA256:
                        capability.snapshot.orderedProviderDefinitionsSHA256
                )) { error in
                    XCTAssertEqual(
                        error as? LocalModelSingleCallToolsError,
                        .trustedRouteMismatch(field)
                    )
                }
        }
    }

    func testLocalAndHostedAuthoritiesRemainNominallyDistinct() throws {
        let localFixture = try makeFixture()
        let local = try makeCatalog(localFixture)
            .localSingleCallToolsCapability(adapterID: localFixture.adapterID)
        let hostedCatalog = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: .init(rawValue: "hosted-model"),
            capabilities: .hostedChatSingleCallToolsBaseline
        )
        let hosted = try hostedCatalog.hostedSingleCallToolsCapability(
            adapterID: hostedCatalog.adapterID
        )

        XCTAssertNotEqual(
            String(reflecting: type(of: local)),
            String(reflecting: type(of: hosted))
        )
        XCTAssertEqual(local.snapshot.deployment, .onDevice)
        XCTAssertEqual(hosted.snapshot.deployment, .hostedService)
        XCTAssertEqual(local.snapshot.maximumToolCallsPerTurn, 1)
        XCTAssertEqual(hosted.snapshot.maximumToolCallsPerTurn, 1)
    }
}

private struct LocalFixture {
    let registry: ToolRegistry
    let registryBinding: LocalModelCanonicalToolRegistryBinding
    let verification: LocalModelArtifactVerification
    let attestation: LocalModelSingleCallToolsAttestation
    let modelID = ProviderModelID(rawValue: "hermes/local-3b")
    let adapterID = ProviderAdapterID(rawValue: "novaforge-local-hermes")
    let contextWindowTokens: UInt64 = 8_192
    let maximumOutputTokens: UInt64 = 1_024
}

private func makeFixture() throws -> LocalFixture {
    let registry = try canonicalRegistry()
    let binding = try TrustedLocalProviderCatalog
        .canonicalToolRegistryBinding(for: registry)
    return LocalFixture(
        registry: registry,
        registryBinding: binding,
        verification: try verification(),
        attestation: try attestation(binding)
    )
}

private func makeCatalog(
    _ fixture: LocalFixture,
    modelID: ProviderModelID? = nil,
    adapterID: ProviderAdapterID? = nil,
    contextWindowTokens: UInt64? = nil,
    maximumOutputTokens: UInt64? = nil,
    verifiedArtifacts: LocalModelArtifactVerification? = nil,
    attestation: LocalModelSingleCallToolsAttestation? = nil,
    toolRegistry: ToolRegistry? = nil
) throws -> TrustedLocalProviderCatalog {
    try TrustedLocalProviderCatalog.grammarConstrainedSingleCall(
        modelID: modelID ?? fixture.modelID,
        adapterID: adapterID ?? fixture.adapterID,
        contextWindowTokens:
            contextWindowTokens ?? fixture.contextWindowTokens,
        maximumOutputTokens:
            maximumOutputTokens ?? fixture.maximumOutputTokens,
        verifiedArtifacts: verifiedArtifacts ?? fixture.verification,
        attestation: attestation ?? fixture.attestation,
        toolRegistry: toolRegistry ?? fixture.registry
    )
}

private func canonicalRegistry() throws -> ToolRegistry {
    try ToolRegistry(tools: [
        AnyAgentTool(FileInfoTool.self),
        AnyAgentTool(ReadFileTool.self),
    ])
}

private func verification(
    modelArtifactSHA256: String = sha("a"),
    tokenizerSHA256: String = sha("b"),
    promptTemplateSHA256: String = sha("c"),
    contextConfigurationSHA256: String = sha("d"),
    grammarSHA256: String = sha("e"),
    grammarCompilerID: String = "novaforge-grammar",
    grammarCompilerVersion: String = "1.2.3"
) throws -> LocalModelArtifactVerification {
    try LocalModelArtifactVerification(
        modelArtifactSHA256: modelArtifactSHA256,
        tokenizerSHA256: tokenizerSHA256,
        promptTemplateSHA256: promptTemplateSHA256,
        contextConfigurationSHA256: contextConfigurationSHA256,
        grammarSHA256: grammarSHA256,
        grammarCompilerID: grammarCompilerID,
        grammarCompilerVersion: grammarCompilerVersion
    )
}

private func attestation(
    _ binding: LocalModelCanonicalToolRegistryBinding,
    modelArtifactSHA256: String = sha("a"),
    tokenizerSHA256: String = sha("b"),
    promptTemplateSHA256: String = sha("c"),
    contextConfigurationSHA256: String = sha("d"),
    grammarSHA256: String = sha("e"),
    grammarCompilerID: String = "novaforge-grammar",
    grammarCompilerVersion: String = "1.2.3",
    canonicalToolRegistrySHA256: String? = nil,
    toolDefinitionCount: UInt32? = nil,
    modelID: ProviderModelID = .init(rawValue: "hermes/local-3b"),
    adapterID: ProviderAdapterID = .init(
        rawValue: "novaforge-local-hermes"
    ),
    contextWindowTokens: UInt64 = 8_192,
    maximumOutputTokens: UInt64 = 1_024,
    maximumToolCallsPerTurn: UInt32 = 1,
    supportsParallelToolCalls: Bool = false
) throws -> LocalModelSingleCallToolsAttestation {
    try LocalModelSingleCallToolsAttestation(
        modelArtifactSHA256: modelArtifactSHA256,
        tokenizerSHA256: tokenizerSHA256,
        promptTemplateSHA256: promptTemplateSHA256,
        contextConfigurationSHA256: contextConfigurationSHA256,
        grammarSHA256: grammarSHA256,
        grammarCompilerID: grammarCompilerID,
        grammarCompilerVersion: grammarCompilerVersion,
        canonicalToolRegistrySHA256:
            canonicalToolRegistrySHA256 ?? binding.providerDefinitionsSHA256,
        toolDefinitionCount:
            toolDefinitionCount ?? binding.toolDefinitionCount,
        modelID: modelID,
        adapterID: adapterID,
        contextWindowTokens: contextWindowTokens,
        maximumOutputTokens: maximumOutputTokens,
        maximumToolCallsPerTurn: maximumToolCallsPerTurn,
        supportsParallelToolCalls: supportsParallelToolCalls
    )
}

private func providerDefinitions(
    _ registry: ToolRegistry
) -> [AgentProviders.ProviderToolDefinition] {
    registry.providerDefinitions().map { definition in
        AgentProviders.ProviderToolDefinition(
            name: definition.function.name,
            description: definition.function.description,
            parameters: definition.function.parameters,
            strict: definition.function.strict
        )
    }
}

private func canonicalRequest(
    model: ProviderModelID,
    tools: some Sequence<AgentProviders.ProviderToolDefinition>
) -> CanonicalProviderRequest {
    CanonicalProviderRequest(
        requestID: "local-single-call-request",
        model: model,
        messages: [.init(role: .user, content: [.text("Inspect it")])],
        tools: Array(tools),
        options: .init(
            parallelToolCalls: false,
            toolChoice: .required
        )
    )
}

private func replacing(
    _ descriptor: ProviderAdapterDescriptor,
    providerID: ProviderID? = nil,
    modelID: ProviderModelID? = nil,
    adapterID: ProviderAdapterID? = nil,
    capabilities: ProviderModelCapabilities? = nil,
    deployment: ProviderDeployment? = nil,
    provenance: ProviderRouteProvenance? = nil,
    dialect: ProviderAdapterDialect? = nil,
    requestPath: String? = nil
) -> ProviderAdapterDescriptor {
    ProviderAdapterDescriptor(
        route: ProviderRoute(
            providerID: providerID ?? descriptor.route.providerID,
            modelID: modelID ?? descriptor.route.modelID,
            adapterID: adapterID ?? descriptor.route.adapterID,
            capabilities: capabilities ?? descriptor.route.capabilities,
            deployment: deployment ?? descriptor.route.deployment,
            provenance: provenance ?? descriptor.route.provenance
        ),
        dialect: dialect ?? descriptor.dialect,
        requestPath: requestPath ?? descriptor.requestPath
    )
}

private func sha(_ character: Character) -> String {
    "sha256:" + String(repeating: String(character), count: 64)
}

private func assertStrictSHA256(
    _ value: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(value.utf8.count, 71, file: file, line: line)
    XCTAssertTrue(value.hasPrefix("sha256:"), file: file, line: line)
    XCTAssertTrue(value.utf8.dropFirst(7).allSatisfy {
        (48 ... 57).contains($0) || (97 ... 102).contains($0)
    }, file: file, line: line)
}

private extension JSONValue {
    var localCapabilityTestObject: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}
