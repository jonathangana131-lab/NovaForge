import AgentDomain
import AgentProviders
@testable import AgentShadow
import AgentStore
import AgentTools
import XCTest

final class DeveloperCanaryPolicyTests: XCTestCase {
    func testCanonicalReadOnlyAllowlistAndEveryEffectfulClassFailClosed() throws {
        let canonicalDescriptors = SandboxToolCatalog.all.map(\.descriptor)
        let canonicalReadOnly = canonicalDescriptors.filter {
            $0.effectClass == .readOnlyLocal
        }
        XCTAssertFalse(canonicalReadOnly.isEmpty)
        XCTAssertTrue(canonicalReadOnly.allSatisfy {
            DeveloperCanaryPolicy.decision(for: $0) == .allowed
        })

        let canonicalEffectful = canonicalDescriptors.filter {
            $0.effectClass != .readOnlyLocal
        }
        XCTAssertFalse(canonicalEffectful.isEmpty)
        for descriptor in canonicalEffectful {
            XCTAssertEqual(
                DeveloperCanaryPolicy.decision(for: descriptor),
                .denied(.effectful(descriptor.effectClass)),
                descriptor.name
            )
        }

        for effectClass in ToolEffectClass.allCases where effectClass != .readOnlyLocal {
            let descriptor = syntheticDescriptor(effectClass: effectClass)
            XCTAssertEqual(
                DeveloperCanaryPolicy.decision(for: descriptor),
                .denied(.effectful(effectClass)),
                effectClass.rawValue
            )
        }
    }

    func testDescriptorClaimingReadOnlyMustStillMatchCanonicalContract() {
        let spoofedReadFile = syntheticDescriptor(
            effectClass: .readOnlyLocal,
            name: "read_file"
        )
        XCTAssertEqual(
            DeveloperCanaryPolicy.decision(for: spoofedReadFile),
            .denied(.nonCanonicalDescriptor)
        )
    }

    func testFreezeBindsHostedRouteFeaturesAndSelectedToolsToAcceptedRun() async throws {
        let fixture = ShadowTestFixture(seed: 12)
        let store = try await fixture.makeStore()
        let attestation = try await DarkReplayEngine(reader: store)
            .attest(fixture.runID)
        let capability = try hostedTextCapability(model: "text-model")
        let policy = try await DeveloperCanaryPolicy.freeze(
            for: attestation,
            hostedTextCapability: capability,
            tools: [SearchTextTool.descriptor, ReadFileTool.descriptor]
        )

        XCTAssertEqual(policy.runID, fixture.runID)
        XCTAssertEqual(policy.hostedTextCapability, capability)
        XCTAssertEqual(policy.acceptedFeatures, fixture.context.features)
        XCTAssertEqual(policy.allowedToolIdentities, [
            ReadFileTool.descriptor.identity,
            SearchTextTool.descriptor.identity,
        ])
        XCTAssertTrue(policy.configurationSHA256.hasPrefix("sha256:"))
        XCTAssertEqual(policy.decision(for: ReadFileTool.descriptor), .allowed)
        XCTAssertEqual(
            policy.decision(for: ListTreeTool.descriptor),
            .denied(.notFrozenForRun)
        )
        XCTAssertEqual(
            policy.decision(for: WriteFileTool.descriptor),
            .denied(.effectful(.scopedReversibleWrite))
        )

        try policy.validateFrozenInputs(
            runID: fixture.runID,
            hostedTextCapability: capability,
            features: fixture.context.features
        )

        let changedRoute = try hostedTextCapability(model: "other-model")
        XCTAssertThrowsError(try policy.validateFrozenInputs(
            runID: fixture.runID,
            hostedTextCapability: changedRoute,
            features: fixture.context.features
        )) { error in
            XCTAssertEqual(error as? DeveloperCanaryPolicyError, .routeChanged)
        }
        XCTAssertThrowsError(try policy.validateFrozenInputs(
            runID: fixture.runID,
            hostedTextCapability: capability,
            features: AgentFeatureSet(["changed"])
        )) { error in
            XCTAssertEqual(error as? DeveloperCanaryPolicyError, .featureSetChanged)
        }
        let differentRunID: RunID = shadowID(900_001)
        XCTAssertThrowsError(try policy.validateFrozenInputs(
            runID: differentRunID,
            hostedTextCapability: capability,
            features: fixture.context.features
        )) { error in
            XCTAssertEqual(
                error as? DeveloperCanaryPolicyError,
                .runChanged(expected: fixture.runID, actual: differentRunID)
            )
        }
    }

    func testFreezeRejectsEffectfulAndDuplicateDescriptors() async throws {
        let fixture = ShadowTestFixture(seed: 13)
        let store = try await fixture.makeStore()
        let attestation = try await DarkReplayEngine(reader: store)
            .attest(fixture.runID)
        let capability = try hostedTextCapability(model: "text-model")

        do {
            _ = try await DeveloperCanaryPolicy.freeze(
                for: attestation,
                hostedTextCapability: capability,
                tools: [WriteFileTool.descriptor]
            )
            XCTFail("Effectful canary descriptor unexpectedly froze")
        } catch {
            XCTAssertEqual(
                error as? DeveloperCanaryPolicyError,
                .toolDenied(
                    WriteFileTool.descriptor.identity,
                    .effectful(.scopedReversibleWrite)
                )
            )
        }
        do {
            _ = try await DeveloperCanaryPolicy.freeze(
                for: attestation,
                hostedTextCapability: capability,
                tools: [ReadFileTool.descriptor, ReadFileTool.descriptor]
            )
            XCTFail("Duplicate canary descriptor unexpectedly froze")
        } catch {
            XCTAssertEqual(
                error as? DeveloperCanaryPolicyError,
                .duplicateTool(ReadFileTool.descriptor.identity)
            )
        }
    }

    func testHostedTextCapabilityRejectsToolCapableProviderDescriptor() throws {
        let catalog = TrustedHostedProviderCatalog.openAIResponses(
            model: ProviderModelID(rawValue: "text-model"),
            capabilities: .openAIResponsesBaseline
        )
        XCTAssertThrowsError(try catalog.hostedTextOnlyCapability(
            adapterID: catalog.adapterID
        )) { error in
            XCTAssertEqual(
                error as? HostedTextOnlyCapabilityError,
                .toolCapabilityPresent(.tools)
            )
        }
    }

    func testHostedTextCapabilityRejectsNonTextModalities() throws {
        let capabilities = ProviderModelCapabilities(
            features: ProviderCapabilitySet([
                .cancellation,
                .reasoning,
                .streaming,
                .usageStreaming,
            ]),
            contextWindowTokens: 8_192,
            maximumOutputTokens: 1_024,
            maximumToolDefinitions: 0,
            maximumToolCallsPerTurn: 0
        )
        let catalog = TrustedHostedProviderCatalog.openAIResponses(
            model: ProviderModelID(rawValue: "reasoning-model"),
            capabilities: capabilities
        )
        XCTAssertThrowsError(try catalog.hostedTextOnlyCapability(
            adapterID: catalog.adapterID
        )) { error in
            XCTAssertEqual(
                error as? HostedTextOnlyCapabilityError,
                .nonTextCapabilityPresent(.reasoning)
            )
        }
    }

    func testHostedTextBaselinesAreTruthfulForTheirDialect() throws {
        let chat = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: ProviderModelID(rawValue: "chat-text-model")
        )
        let chatCapability = try chat.hostedTextOnlyCapability(
            adapterID: chat.adapterID
        )
        XCTAssertFalse(
            chatCapability.snapshot.capabilities.features.contains(
                .responseContinuation
            )
        )

        let responses = TrustedHostedProviderCatalog.openAIResponses(
            model: ProviderModelID(rawValue: "responses-text-model")
        )
        let responsesCapability = try responses.hostedTextOnlyCapability(
            adapterID: responses.adapterID
        )
        XCTAssertTrue(
            responsesCapability.snapshot.capabilities.features.contains(
                .responseContinuation
            )
        )

        let lyingChat = TrustedHostedProviderCatalog.openAIChatCompletions(
            model: ProviderModelID(rawValue: "lying-chat"),
            capabilities: .hostedResponsesTextOnlyBaseline
        )
        XCTAssertThrowsError(try lyingChat.hostedTextOnlyCapability(
            adapterID: lyingChat.adapterID
        )) { error in
            XCTAssertEqual(
                error as? HostedTextOnlyCapabilityError,
                .dialectCapabilityMismatch(.responseContinuation)
            )
        }
    }

    func testHostedTextCapabilityBindsSealedHostedProvenance() throws {
        let capability = try hostedTextCapability(model: "trusted-text-model")
        XCTAssertEqual(capability.snapshot.deployment, .hostedService)
        XCTAssertEqual(
            capability.snapshot.provenance,
            .builtInOpenAIResponses
        )
        XCTAssertTrue(capability.snapshot.toolDispatchDisabled)
    }

    func testCanaryDigestBindsFullContractsAndToolOrderIsCanonical() async throws {
        let fixture = ShadowTestFixture(seed: 14)
        let store = try await fixture.makeStore()
        let attestation = try await DarkReplayEngine(reader: store).attest(fixture.runID)
        let capability = try hostedTextCapability(model: "digest-model")
        let first = try await DeveloperCanaryPolicy.freeze(
            for: attestation,
            hostedTextCapability: capability,
            tools: [ReadFileTool.descriptor, SearchTextTool.descriptor]
        )
        let reversed = try await DeveloperCanaryPolicy.freeze(
            for: attestation,
            hostedTextCapability: capability,
            tools: [SearchTextTool.descriptor, ReadFileTool.descriptor]
        )
        XCTAssertEqual(first.configurationSHA256, reversed.configurationSHA256)
        XCTAssertEqual(first.allowedToolContracts, reversed.allowedToolContracts)

        let spoof = syntheticDescriptor(effectClass: .readOnlyLocal, name: "read_file")
        XCTAssertNotEqual(
            try CanonicalToolContract.sha256(ReadFileTool.descriptor),
            try CanonicalToolContract.sha256(spoof)
        )
    }

    func testReplayAttestationRejectsLedgerChangeBeforeFreeze() async throws {
        let fixture = ShadowTestFixture(seed: 15)
        let store = InMemoryAgentEventJournal(
            clock: { AgentInstant(rawValue: 2_000_000_000_000) }
        )
        _ = try await store.accept(fixture.acceptance)
        let attestation = try await DarkReplayEngine(reader: store).attest(fixture.runID)
        _ = try await store.append(fixture.envelope(
            2,
            payload: .runStarted(RunStartedEvent()),
            key: "started-after-attestation"
        ))

        do {
            _ = try await DeveloperCanaryPolicy.freeze(
                for: attestation,
                hostedTextCapability: try hostedTextCapability(model: "text-model"),
                tools: [ReadFileTool.descriptor]
            )
            XCTFail("Stale replay attestation unexpectedly authorized a canary")
        } catch {
            XCTAssertEqual(
                error as? DarkReplayError,
                .staleReplayAttestation(runID: fixture.runID)
            )
        }
    }
}

private func hostedTextCapability(
    model: String
) throws -> HostedTextOnlyProviderCapability {
    let catalog = TrustedHostedProviderCatalog.openAIResponses(
        model: ProviderModelID(rawValue: model),
        capabilities: .hostedTextOnlyBaseline
    )
    return try catalog.hostedTextOnlyCapability(
        adapterID: catalog.adapterID
    )
}

private func syntheticDescriptor(
    effectClass: ToolEffectClass,
    name: String? = nil
) -> ToolDescriptor {
    let canonicalName = name ?? "synthetic_\(effectClass.rawValue.lowercased())"
    return ToolDescriptor(
        metadata: ToolDescriptorMetadata(
            name: canonicalName,
            version: ToolVersion(major: 1, minor: 0, patch: 0),
            toolset: "shadow-test",
            description: "Synthetic policy probe",
            availability: ToolAvailabilityRequirement(
                allowedLocalities: [.onDevice],
                requiredCapabilities: [],
                requiresWorkspace: false
            ),
            effectClass: effectClass,
            approvalClass: effectClass == .readOnlyLocal ? .none : .explicit,
            targetStrategy: .workspaceRoot(
                access: effectClass == .readOnlyLocal ? .inspect : .write
            ),
            parallelSafety: effectClass == .readOnlyLocal
                ? .parallelRead
                : .workspaceSerialized,
            concurrencyKey: effectClass == .readOnlyLocal ? nil : "workspace",
            limits: ToolLimits(
                timeoutMilliseconds: 1_000,
                maximumArgumentBytes: 1_024,
                maximumOutputBytes: 1_024
            ),
            redaction: ToolRedactionPolicy(
                argumentRules: [],
                output: .none
            ),
            legacyAdapter: nil,
            receipt: ToolReceiptMetadata(
                actionVerb: "Probed",
                successSummary: "Policy probed"
            ),
            evidence: .none,
            ui: ToolUIMetadata(
                title: "Synthetic",
                systemImageName: "checkmark",
                category: .inspect,
                resultPresentation: .text
            )
        ),
        argumentSchema: .object(properties: [:], required: [])
    )
}
