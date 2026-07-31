#if DEBUG
import AgentDomain
import AgentProviders
import Foundation
import XCTest
@testable import NovaForge

@MainActor
final class AgentHostedTextCanaryLiveSessionTests: XCTestCase {
    func testDraftPersistenceResolutionNeverErasesANewerDraft() throws {
        let accepted = try makeLiveRequest(seed: 11).draftIdentity

        XCTAssertEqual(
            accepted.persistenceResolution(
                visibleConversationID: accepted.conversationID,
                visibleDraftToken: accepted.draftToken,
                visibleText: accepted.text,
                persistedText: accepted.text
            ),
            .removeAndClearVisible
        )
        XCTAssertEqual(
            accepted.persistenceResolution(
                visibleConversationID: accepted.conversationID,
                visibleDraftToken: liveTestUUID(999_001),
                visibleText: "A newer visible draft",
                persistedText: accepted.text
            ),
            .replacePersistedWithVisible
        )
        XCTAssertEqual(
            accepted.persistenceResolution(
                visibleConversationID: liveTestUUID(999_002),
                visibleDraftToken: liveTestUUID(999_003),
                visibleText: "Another chat",
                persistedText: accepted.text
            ),
            .removePersistedOnly
        )
        XCTAssertEqual(
            accepted.persistenceResolution(
                visibleConversationID: liveTestUUID(999_002),
                visibleDraftToken: liveTestUUID(999_003),
                visibleText: "Another chat",
                persistedText: "A newer background draft"
            ),
            .preservePersisted
        )
    }

    func testSynchronousDoubleSubmitReservesExactlyOneOperation() async throws {
        let blueprint = try makeLiveBlueprint(seed: 1)
        let session = AgentHostedTextCanaryLiveSession()
        let prepareProbe = LiveMainActorProbe()
        let operationProbe = LiveAsyncProbe()
        let prepared = AgentHostedTextCanaryPreparedRun(
            blueprint: blueprint,
            operation: { _ in
                await operationProbe.record("started")
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        )

        let first = session.submit(
            draftIdentity: blueprint.draftIdentity,
            prepare: {
                prepareProbe.record("prepare")
                return prepared
            }
        )
        let second = session.submit(
            draftIdentity: blueprint.draftIdentity,
            prepare: {
                prepareProbe.record("second-prepare")
                return prepared
            }
        )

        XCTAssertEqual(first, .reserved)
        XCTAssertEqual(second, .busy)
        XCTAssertEqual(session.phase, .accepting)
        XCTAssertEqual(session.activeDraftIdentity, blueprint.draftIdentity)
        XCTAssertTrue(session.locksWorkspaceRouting)
        try await waitForLiveEvent("started", probe: operationProbe)
        XCTAssertEqual(session.activeRunID, blueprint.runID.rawValue)
        XCTAssertEqual(prepareProbe.events, ["prepare"])

        session.stop()
        try await waitForLivePhase(.idle, session: session)
        let operationStartCount = await operationProbe.count(of: "started")
        XCTAssertEqual(operationStartCount, 1)
    }

    func testStopCancelsOnlyTheSessionTaskAndASettledRunUnlocks() async throws {
        let blueprint = try makeLiveBlueprint(seed: 2)
        let session = AgentHostedTextCanaryLiveSession()
        let operationProbe = LiveAsyncProbe()
        let unrelatedProbe = LiveAsyncProbe()
        let prepared = AgentHostedTextCanaryPreparedRun(
            blueprint: blueprint,
            operation: { didAccept in
                await didAccept()
                await operationProbe.record("running")
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch is CancellationError {
                    await operationProbe.record("session-cancelled")
                    // The production executor returns only after it has made
                    // cancellation terminal and projected it.
                    return
                }
            }
        )
        let unrelated = Task {
            try await Task.sleep(nanoseconds: 25_000_000)
            await unrelatedProbe.record("finished")
        }

        XCTAssertEqual(
            session.submit(
                draftIdentity: blueprint.draftIdentity,
                prepare: { prepared }
            ),
            .reserved
        )
        try await waitForLiveEvent("running", probe: operationProbe)
        XCTAssertEqual(session.phase, .running)

        session.stop()
        XCTAssertEqual(session.phase, .stopping)
        try await waitForLivePhase(.idle, session: session)
        try await unrelated.value

        let cancellationCount = await operationProbe.count(
            of: "session-cancelled"
        )
        let unrelatedEvents = await unrelatedProbe.values()
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(unrelatedEvents, ["finished"])
        XCTAssertEqual(session.lastNotice, .cancelled)
        XCTAssertFalse(session.locksWorkspaceRouting)
    }

    func testDuplicateAcceptanceBlocksRecoveryAndRejectsNewSubmission() async throws {
        let blueprint = try makeLiveBlueprint(seed: 3)
        let session = AgentHostedTextCanaryLiveSession()
        let prepared = AgentHostedTextCanaryPreparedRun(
            blueprint: blueprint,
            operation: { _ in
                throw AgentHostedTextCanaryRunExecutorError.duplicateAcceptance
            }
        )

        XCTAssertEqual(
            session.submit(
                draftIdentity: blueprint.draftIdentity,
                prepare: { prepared }
            ),
            .reserved
        )
        try await waitForLivePhase(.blockedRecovery, session: session)

        XCTAssertEqual(session.lastNotice, .recoveryRequired)
        XCTAssertTrue(session.locksWorkspaceRouting)
        XCTAssertEqual(
            session.submit(
                draftIdentity: blueprint.draftIdentity,
                prepare: { prepared }
            ),
            .blockedRecovery
        )

        session.markRecoveryCompleted()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(session.locksWorkspaceRouting)
    }

    func testAcceptedProjectionAndUnknownFailuresRemainRecoveryLocked() async throws {
        let blueprint = try makeLiveBlueprint(seed: 31)
        let projectionSession = AgentHostedTextCanaryLiveSession()
        let projectionFailure = AgentHostedTextCanaryPreparedRun(
            blueprint: blueprint,
            operation: { didAccept in
                await didAccept()
                throw AgentHostedTextCanaryRunExecutorError
                    .projectionFailed(.completed)
            }
        )

        XCTAssertEqual(
            projectionSession.submit(
                draftIdentity: blueprint.draftIdentity,
                prepare: { projectionFailure }
            ),
            .reserved
        )
        try await waitForLivePhase(
            .blockedRecovery,
            session: projectionSession
        )
        XCTAssertTrue(projectionSession.locksWorkspaceRouting)
        XCTAssertTrue(projectionSession.isBusy)
        XCTAssertEqual(projectionSession.lastNotice, .recoveryRequired)

        let settlementSession = AgentHostedTextCanaryLiveSession()
        let settlementFailure = AgentHostedTextCanaryPreparedRun(
            blueprint: blueprint,
            operation: { didAccept in
                await didAccept()
                throw AgentHostedTextCanaryRunExecutorError.settlementFailed
            }
        )
        XCTAssertEqual(
            settlementSession.submit(
                draftIdentity: blueprint.draftIdentity,
                prepare: { settlementFailure }
            ),
            .reserved
        )
        try await waitForLivePhase(
            .blockedRecovery,
            session: settlementSession
        )
        XCTAssertTrue(settlementSession.locksWorkspaceRouting)
        XCTAssertTrue(settlementSession.isBusy)
        XCTAssertEqual(settlementSession.lastNotice, .recoveryRequired)

        let unknownSession = AgentHostedTextCanaryLiveSession()
        let unknownFailure = AgentHostedTextCanaryPreparedRun(
            blueprint: blueprint,
            operation: { didAccept in
                await didAccept()
                throw LiveSessionTestError.fixtureFailure
            }
        )
        XCTAssertEqual(
            unknownSession.submit(
                draftIdentity: blueprint.draftIdentity,
                prepare: { unknownFailure }
            ),
            .reserved
        )
        try await waitForLivePhase(.blockedRecovery, session: unknownSession)
        XCTAssertTrue(unknownSession.locksWorkspaceRouting)
        XCTAssertTrue(unknownSession.isBusy)
        XCTAssertEqual(unknownSession.lastNotice, .recoveryRequired)
    }

    func testPreAcceptanceCancellationReturnsIdleWithoutRecoveryLock() async throws {
        let blueprint = try makeLiveBlueprint(seed: 32)
        let session = AgentHostedTextCanaryLiveSession()
        let didAcceptProbe = LiveMainActorProbe()
        let prepared = AgentHostedTextCanaryPreparedRun(
            blueprint: blueprint,
            operation: { _ in throw CancellationError() }
        )

        XCTAssertEqual(
            session.submit(
                draftIdentity: blueprint.draftIdentity,
                prepare: { prepared },
                didAccept: { _ in didAcceptProbe.record("accepted") }
            ),
            .reserved
        )
        try await waitForLivePhase(.idle, session: session)

        XCTAssertFalse(session.locksWorkspaceRouting)
        XCTAssertFalse(session.isBusy)
        XCTAssertNil(session.lastNotice)
        XCTAssertTrue(didAcceptProbe.events.isEmpty)
    }

    func testRouteMismatchAndInvalidCredentialFailBeforeDidAccept() async throws {
        let credentialProbe = LiveCredentialProbe(value: "sk-valid")
        let invalidRouteRequest = try makeLiveRequest(
            seed: 4,
            routing: NovaForge.AgentRunRoutingMetadata(
                engineVersion: .v2,
                enabledFeatures: [.v2DarkReplay, .v2HostedText],
                executionNode: .onDevice,
                shadowMode: false
            )
        )
        let routeFactory = AgentHostedTextCanaryLiveFactory(
            readCredential: { credentialProbe.read() },
            now: { AgentInstant(rawValue: 4_000) }
        )
        let routeSession = AgentHostedTextCanaryLiveSession()
        let routeAcceptProbe = LiveMainActorProbe()

        XCTAssertEqual(
            routeSession.submit(
                draftIdentity: invalidRouteRequest.draftIdentity,
                prepare: {
                    _ = try routeFactory.makeBlueprint(for: invalidRouteRequest)
                    XCTFail("A mismatched route produced a prepared run")
                    throw AgentHostedTextCanaryLiveFactoryError.routeMismatch
                },
                didAccept: { _ in routeAcceptProbe.record("accepted") }
            ),
            .reserved
        )
        try await waitForLivePhase(.idle, session: routeSession)
        XCTAssertEqual(routeSession.lastNotice, .routeUnavailable)
        XCTAssertEqual(routeAcceptProbe.events, [])
        XCTAssertEqual(credentialProbe.readCount, 0)

        let invalidKeyProbe = LiveCredentialProbe(value: "contains space")
        let validRequest = try makeLiveRequest(seed: 5)
        let keyFactory = AgentHostedTextCanaryLiveFactory(
            readCredential: { invalidKeyProbe.read() },
            now: { AgentInstant(rawValue: 5_000) }
        )
        let keySession = AgentHostedTextCanaryLiveSession()
        let keyAcceptProbe = LiveMainActorProbe()

        XCTAssertEqual(
            keySession.submit(
                draftIdentity: validRequest.draftIdentity,
                prepare: {
                    _ = try keyFactory.makeBlueprint(for: validRequest)
                    XCTFail("An invalid credential produced a prepared run")
                    throw AgentHostedTextCanaryLiveFactoryError.invalidCredential
                },
                didAccept: { _ in keyAcceptProbe.record("accepted") }
            ),
            .reserved
        )
        try await waitForLivePhase(.idle, session: keySession)
        XCTAssertEqual(keySession.lastNotice, .credentialInvalid)
        XCTAssertEqual(keyAcceptProbe.events, [])
        XCTAssertEqual(invalidKeyProbe.readCount, 1)
    }

    func testCanonicalIdentitiesAreDeterministicAndIndependentOfClock() throws {
        let request = try makeLiveRequest(seed: 6)
        let early = try AgentHostedTextCanaryLiveFactory(
            readCredential: { "sk-test" },
            now: { AgentInstant(rawValue: 1) }
        ).makeBlueprint(for: request)
        let late = try AgentHostedTextCanaryLiveFactory(
            readCredential: { "sk-test" },
            now: { AgentInstant(rawValue: 9_999_999) }
        ).makeBlueprint(for: request)
        let other = try AgentHostedTextCanaryLiveFactory(
            readCredential: { "sk-test" },
            now: { AgentInstant(rawValue: 1) }
        ).makeBlueprint(for: makeLiveRequest(seed: 7))

        XCTAssertEqual(early.runID, late.runID)
        XCTAssertEqual(
            early.acceptance.metadata.acceptanceCommandID,
            late.acceptance.metadata.acceptanceCommandID
        )
        XCTAssertEqual(
            early.acceptance.metadata.acceptanceEventID,
            late.acceptance.metadata.acceptanceEventID
        )
        XCTAssertEqual(
            early.acceptance.envelope.event.header.correlationID,
            late.acceptance.envelope.event.header.correlationID
        )
        XCTAssertEqual(
            early.acceptance.metadata.context.cancellation,
            late.acceptance.metadata.context.cancellation
        )
        XCTAssertEqual(
            early.acceptance.metadata.context.executionNodeID,
            other.acceptance.metadata.context.executionNodeID,
            "The on-device node is fixed while run ownership remains run-scoped"
        )
        XCTAssertEqual(early.providerRequest.requestID, late.providerRequest.requestID)
        XCTAssertNotEqual(early.runID, other.runID)
        XCTAssertNotEqual(
            early.acceptance.metadata.context.acceptedAt,
            late.acceptance.metadata.context.acceptedAt
        )
    }

    func testBlueprintHasOneCanonicalUserItemAndExactTextOnlyOptions() throws {
        let request = try makeLiveRequest(seed: 8, prompt: "Build exactly this")
        let blueprint = try AgentHostedTextCanaryLiveFactory(
            readCredential: { "sk-test" },
            now: { AgentInstant(rawValue: 8_000) }
        ).makeBlueprint(for: request)

        guard case let .runAccepted(accepted) =
            blueprint.acceptance.envelope.event.payload else {
            return XCTFail("Expected runAccepted")
        }
        XCTAssertEqual(accepted.context.schemaVersion, .v1_1)
        XCTAssertEqual(
            blueprint.acceptance.envelope.event.header.schemaVersion,
            .v1_1
        )
        XCTAssertEqual(
            accepted.acceptedEngineVersion,
            AgentHostedTextCanaryCoordinator.engineVersion
        )
        XCTAssertEqual(
            blueprint.acceptance.metadata.acceptedEngineVersion,
            accepted.acceptedEngineVersion
        )
        XCTAssertEqual(accepted.initialItems.count, 1)
        XCTAssertEqual(
            accepted.initialItems.first?.id.rawValue,
            request.requestMessageID
        )
        XCTAssertEqual(accepted.initialItems.first?.payload, .message(ModelMessage(
            role: .user,
            content: [.text("Build exactly this")]
        )))
        XCTAssertEqual(
            blueprint.providerRequest.messages.last,
            ProviderMessage(
                role: .user,
                content: [.text("Build exactly this")]
            )
        )
        XCTAssertEqual(blueprint.providerRequest.messages.first?.role, .system)
        XCTAssertTrue(blueprint.providerRequest.tools.isEmpty)
        XCTAssertEqual(blueprint.providerRequest.options.maximumOutputTokens, 4_096)
        XCTAssertEqual(blueprint.providerRequest.options.temperature, 0.25)
        XCTAssertNil(blueprint.providerRequest.options.parallelToolCalls)
        XCTAssertEqual(blueprint.providerRequest.options.toolChoice, .none)
        XCTAssertNil(blueprint.providerRequest.options.reasoningSummary)
        XCTAssertNil(blueprint.providerRequest.options.promptCacheKey)
        XCTAssertNil(blueprint.providerRequest.options.previousResponseID)
        XCTAssertNil(blueprint.providerRequest.options.minimumContextWindowTokens)
        XCTAssertEqual(
            blueprint.legacyAcceptanceProjection.requestMessageID,
            request.requestMessageID
        )
        XCTAssertEqual(
            blueprint.legacyAcceptanceProjection.requestText,
            "Build exactly this"
        )
    }

    func testReadToolsBlueprintFreezesExactTwelveToolCatalogWithoutParallelism() throws {
        let route = NovaForge.AgentRunRoutingMetadata(
            engineVersion: .v2,
            enabledFeatures: [
                .v2DarkReplay,
                .v2HostedText,
                .v2ReadTools,
            ],
            executionNode: .onDevice,
            shadowMode: true
        )
        let request = try makeLiveRequest(seed: 801, routing: route)
        let blueprint = try AgentHostedTextCanaryLiveFactory(
            readCredential: { "sk-test" },
            now: { AgentInstant(rawValue: 801_000) }
        ).makeBlueprint(for: request)

        XCTAssertEqual(
            blueprint.acceptance.metadata.context.features,
            AgentHostedReadOnlyCanaryCoordinator.featureSet
        )
        XCTAssertEqual(
            blueprint.acceptance.metadata.context.schemaVersion,
            .v1_1
        )
        XCTAssertEqual(blueprint.providerRequest.tools.count, 12)
        XCTAssertEqual(Set(blueprint.providerRequest.tools.map(\.name)), Set([
            "list_directory", "list_tree", "workspace_summary", "file_info",
            "read_file", "read_file_range", "tail_file", "search_text",
            "diff_files", "validate_json", "validate_html_file",
            "extract_outline",
        ]))
        XCTAssertTrue(blueprint.providerRequest.tools.allSatisfy(\.strict))
        XCTAssertEqual(
            blueprint.providerRequest.options.parallelToolCalls,
            false
        )
        XCTAssertEqual(blueprint.providerRequest.options.toolChoice, .auto)
        XCTAssertEqual(
            blueprint.providerRequest.messages,
            request.capturedContext.providerMessages
        )
    }

    func testScorecardSinkEmitsOnlyMatchedContentFreeDigestAndTimingSchema() async throws {
        let sink = AgentHostedCanaryScorecardSink(route: try .init(
            provider: "openai",
            model: "gpt-test",
            temperature: 0,
            maxOutputTokens: 4_096
        ))
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let workspace = "sha256:" + String(repeating: "b", count: 64)
        let digests = try AgentHostedCanaryScorecardSink.Digests(
            contextSHA256: digest,
            transcriptSHA256: digest,
            evidenceSHA256: digest,
            workspaceBeforeSHA256: workspace,
            workspaceAfterSHA256: workspace
        )
        for index in 0 ..< 100 {
            for engine in [
                AgentHostedCanaryScorecardSink.Engine.v1,
                .v2,
            ] {
                try await sink.record(
                    pairID: String(format: "pair-%03d", index),
                    engine: engine,
                    success: true,
                    timing: try .init(
                        acceptanceMs: engine == .v1 ? 80 : 90,
                        ttftMs: engine == .v1 ? 500 : 540,
                        totalMs: engine == .v1 ? 1_000 : 1_080
                    ),
                    digests: digests
                )
            }
        }

        let encoded = try await sink.encodedMatched100PairPayload()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            Set(["route", "samples", "schemaVersion"])
        )
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(samples.count, 200)
        let allowed = Set([
            "pairID", "engine", "success", "acceptanceMs", "ttftMs",
            "totalMs", "contextSHA256", "transcriptSHA256",
            "evidenceSHA256", "workspaceBeforeSHA256",
            "workspaceAfterSHA256", "errorCategory",
        ])
        XCTAssertTrue(samples.allSatisfy { Set($0.keys).isSubset(of: allowed) })
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("prompt"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("path"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("content"))
    }

    func testSharedV1TranscriptExactlyMatchesV2CanonicalRoleTextSequence() throws {
        let history = [
            liveProviderInput(.user, "Earlier question", seed: 8_101, at: 1),
            liveProviderInput(.assistant, "Earlier answer", seed: 8_102, at: 2),
        ]
        let capturedAt = Date(timeIntervalSince1970: 3)
        let workspaceSummary = "file: Sources/Parity.swift"
        let request = try makeLiveRequest(
            seed: 81,
            prompt: "Current question",
            history: history,
            workspaceSummary: workspaceSummary,
            capturedAt: capturedAt
        )
        let blueprint = try AgentHostedTextCanaryLiveFactory(
            readCredential: { "sk-test" },
            now: { AgentInstant(rawValue: 81_000) }
        ).makeBlueprint(for: request)
        let expected = try NovaForge.ProviderContextWindow.prepareHostedTranscript(
            history: history + [liveProviderInput(
                .user,
                "Current question",
                id: request.requestMessageID,
                at: capturedAt.timeIntervalSince1970
            )],
            customSystemPrompt: nil,
            workspaceSummary: workspaceSummary
        )

        XCTAssertEqual(
            liveCanonicalSequence(blueprint.providerRequest.messages),
            liveV1Sequence(expected.messages)
        )
        XCTAssertEqual(
            blueprint.capturedContext.acceptedUserItemID,
            request.requestMessageID
        )
        XCTAssertEqual(
            blueprint.capturedContext.acceptedUserMessageIndex,
            blueprint.providerRequest.messages.count - 1
        )
    }

    func testCustomPromptAndWorkspaceSummaryMatchSharedHostedBoundary() throws {
        let custom = "  Follow this exact project policy.  "
        let customBlueprint = try makeLiveBlueprint(
            seed: 82,
            customSystemPrompt: custom,
            workspaceSummary: "must stay out of a custom prompt"
        )
        XCTAssertEqual(
            liveText(customBlueprint.providerRequest.messages[0]),
            custom
        )
        XCTAssertFalse(
            liveText(customBlueprint.providerRequest.messages[0])
                .contains("must stay out")
        )
        XCTAssertEqual(
            customBlueprint.capturedContext.systemInstruction,
            custom
        )
        XCTAssertTrue(AgentRunExecutionComposition.isSHA256(
            try XCTUnwrap(
                customBlueprint.executionComposition.systemInstructionDigest
            )
        ))
        XCTAssertNil(
            customBlueprint.executionComposition.developerInstructionDigest
        )

        let defaultBlueprint = try makeLiveBlueprint(
            seed: 83,
            workspaceSummary: "file: Sources/WorkspaceProof.swift"
        )
        XCTAssertTrue(
            liveText(defaultBlueprint.providerRequest.messages[0]).contains(
                "Current workspace files:\nfile: Sources/WorkspaceProof.swift"
            )
        )
    }

    func testLongHistoryUsesTheSameBoundedSanitizedSuffixAsV1() throws {
        let history = (0 ..< 120).map { index in
            liveProviderInput(
                index.isMultiple(of: 2) ? .user : .assistant,
                "historical turn \(index)",
                seed: UInt64(9_000 + index),
                at: TimeInterval(index)
            )
        }
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let request = try makeLiveRequest(
            seed: 84,
            prompt: "bounded current turn",
            history: history,
            workspaceSummary: "No files yet.",
            capturedAt: capturedAt
        )
        let blueprint = try AgentHostedTextCanaryLiveFactory(
            readCredential: { "sk-test" }
        ).makeBlueprint(for: request)
        let expected = try NovaForge.ProviderContextWindow.prepareHostedTranscript(
            history: history + [liveProviderInput(
                .user,
                "bounded current turn",
                id: request.requestMessageID,
                at: capturedAt.timeIntervalSince1970
            )],
            customSystemPrompt: nil,
            workspaceSummary: "No files yet."
        )

        XCTAssertEqual(
            liveCanonicalSequence(blueprint.providerRequest.messages),
            liveV1Sequence(expected.messages)
        )
        XCTAssertLessThanOrEqual(blueprint.providerRequest.messages.count, 72)
        XCTAssertFalse(
            liveCanonicalSequence(blueprint.providerRequest.messages)
                .contains("user\u{0}historical turn 0")
        )
        XCTAssertEqual(
            liveText(blueprint.providerRequest.messages.last!),
            "bounded current turn"
        )
    }

    func testSelectedToolBearingHistoryIsRejectedBeforeCredentialOrDispatch() throws {
        let call = NovaForge.APIToolCall(
            id: "call-context-rejection",
            type: "function",
            function: NovaForge.APIFunctionCall(
                name: "read_file",
                arguments: #"{"path":"Secrets.swift"}"#
            )
        )
        let history = [
            NovaForge.ProviderMessageInput(
                id: liveTestUUID(9_101),
                role: .assistant,
                content: "",
                createdAt: Date(timeIntervalSince1970: 1),
                toolCallID: nil,
                toolCalls: [call]
            ),
            NovaForge.ProviderMessageInput(
                id: liveTestUUID(9_102),
                role: .tool,
                content: "sensitive tool result",
                createdAt: Date(timeIntervalSince1970: 2),
                toolCallID: call.id,
                toolCalls: []
            ),
        ]

        XCTAssertThrowsError(try makeLiveRequest(
            seed: 85,
            history: history,
            workspaceSummary: "No files yet.",
            capturedAt: Date(timeIntervalSince1970: 3)
        )) { error in
            XCTAssertEqual(
                error as? AgentHostedTextCanaryLiveFactoryError,
                .toolBearingHistory
            )
        }
    }

    func testDidAcceptRunsOnlyAfterOperationSignalsDurableAcceptance() async throws {
        let blueprint = try makeLiveBlueprint(seed: 9)
        let session = AgentHostedTextCanaryLiveSession()
        let order = LiveMainActorProbe()
        let prepared = AgentHostedTextCanaryPreparedRun(
            blueprint: blueprint,
            operation: { didAccept in
                await MainActor.run { order.record("operation-before-commit") }
                await MainActor.run { order.record("durable-acceptance") }
                await didAccept()
                await MainActor.run { order.record("operation-after-callback") }
            }
        )

        XCTAssertEqual(
            session.submit(
                draftIdentity: blueprint.draftIdentity,
                prepare: { prepared },
                didAccept: { identity in
                    XCTAssertEqual(session.phase, .running)
                    XCTAssertEqual(session.acceptedDraftIdentity, identity)
                    order.record("didAccept")
                }
            ),
            .reserved
        )
        try await waitForLivePhase(.idle, session: session)

        XCTAssertEqual(order.events, [
            "operation-before-commit",
            "durable-acceptance",
            "didAccept",
            "operation-after-callback",
        ])
    }

    func testAcceptedDraftIdentityProtectsNewerVisibleText() throws {
        let identity = try makeLiveRequest(seed: 10).draftIdentity
        XCTAssertTrue(identity.matchesVisibleDraft(
            conversationID: identity.conversationID,
            draftToken: identity.draftToken,
            text: identity.text
        ))
        XCTAssertFalse(identity.matchesVisibleDraft(
            conversationID: identity.conversationID,
            draftToken: UUID(),
            text: identity.text
        ))
        XCTAssertFalse(identity.matchesVisibleDraft(
            conversationID: identity.conversationID,
            draftToken: identity.draftToken,
            text: identity.text + " newer"
        ))
    }
}

@MainActor
private final class LiveMainActorProbe {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private actor LiveAsyncProbe {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func values() -> [String] { events }

    func count(of event: String) -> Int {
        events.filter { $0 == event }.count
    }
}

private final class LiveCredentialProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let value: String?
    private var count = 0

    init(value: String?) {
        self.value = value
    }

    func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return value
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private enum LiveSessionTestError: Error {
    case timedOut
    case fixtureFailure
}

@MainActor
private func waitForLivePhase(
    _ expected: AgentHostedTextCanaryLivePhase,
    session: AgentHostedTextCanaryLiveSession
) async throws {
    for _ in 0 ..< 200 {
        if session.phase == expected { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw LiveSessionTestError.timedOut
}

private func waitForLiveEvent(
    _ expected: String,
    probe: LiveAsyncProbe
) async throws {
    for _ in 0 ..< 200 {
        if await probe.values().contains(expected) { return }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw LiveSessionTestError.timedOut
}

private func makeLiveBlueprint(
    seed: UInt64,
    history: [NovaForge.ProviderMessageInput] = [],
    customSystemPrompt: String? = nil,
    workspaceSummary: String? = "No files yet."
) throws -> AgentHostedTextCanaryLiveBlueprint {
    try AgentHostedTextCanaryLiveFactory(
        readCredential: { "sk-test" },
        now: { AgentInstant(rawValue: Int64(seed * 1_000)) }
    ).makeBlueprint(for: makeLiveRequest(
        seed: seed,
        history: history,
        customSystemPrompt: customSystemPrompt,
        workspaceSummary: workspaceSummary
    ))
}

private func makeLiveRequest(
    seed: UInt64,
    routing: NovaForge.AgentRunRoutingMetadata = NovaForge.AgentRunRoutingMetadata(
        engineVersion: .v2,
        enabledFeatures: [.v2DarkReplay, .v2HostedText],
        executionNode: .onDevice,
        shadowMode: true
    ),
    prompt: String = "Hello from the live canary",
    history: [NovaForge.ProviderMessageInput] = [],
    customSystemPrompt: String? = nil,
    workspaceSummary: String? = "No files yet.",
    capturedAt: Date = Date(timeIntervalSince1970: 10_000)
) throws -> AgentHostedTextCanaryLiveRequest {
    try AgentHostedTextCanaryLiveRequest(
        routing: routing,
        selectedProvider: .openAI,
        modelID: "gpt-4.1",
        temperature: 0.25,
        prompt: prompt,
        conversationID: liveTestUUID(seed * 10 + 1),
        projectID: liveTestUUID(seed * 10 + 2),
        workspace: NovaForge.SandboxWorkspace(
            rootURL: URL(
                fileURLWithPath: "/tmp/NovaForgeLiveSessionTests/workspace-\(seed)",
                isDirectory: true
            )
        ),
        history: history,
        customSystemPrompt: customSystemPrompt,
        workspaceSummary: workspaceSummary,
        capturedAt: capturedAt,
        requestMessageID: liveTestUUID(seed * 10 + 3),
        draftToken: liveTestUUID(seed * 10 + 4)
    )
}

private func liveProviderInput(
    _ role: NovaForge.ChatRole,
    _ content: String,
    seed: UInt64? = nil,
    id: UUID? = nil,
    at timestamp: TimeInterval
) -> NovaForge.ProviderMessageInput {
    NovaForge.ProviderMessageInput(
        id: id ?? liveTestUUID(seed!),
        role: role,
        content: content,
        createdAt: Date(timeIntervalSince1970: timestamp),
        toolCallID: nil,
        toolCalls: []
    )
}

private func liveCanonicalSequence(_ messages: [ProviderMessage]) -> [String] {
    messages.map { "\($0.role.rawValue)\u{0}\(liveText($0))" }
}

private func liveV1Sequence(
    _ messages: [NovaForge.ProviderChatMessage]
) -> [String] {
    messages.map { "\($0.role)\u{0}\($0.content ?? "")" }
}

private func liveText(_ message: ProviderMessage) -> String {
    guard message.content.count == 1,
          case let .text(text) = message.content[0] else { return "" }
    return text
}

private func liveTestUUID(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llX", value)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}
#endif
