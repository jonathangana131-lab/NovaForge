import AgentDomain
import AgentProviders
import AgentStore
import AgentTools
import CryptoKit
import Foundation
import SwiftData
import XCTest

@MainActor
final class SwiftDataAgentStoreTests: XCTestCase {
    func testAcceptanceAtomicallyPersistsMetadataAndOpaqueIndexedFirstEvent() async throws {
        let container = try makeContainer()
        let instant = AgentInstant(rawValue: 1_800_000_000_100)
        let fixture = AgentStoreFixture(seed: 100, acceptedAt: instant)
        let store = SwiftDataAgentStore(container: container, now: { instant })
        let expectedComposition = try fixture.executionComposition()

        let commit = try await acceptFixture(fixture, using: store, in: container)

        XCTAssertEqual(commit.disposition, .committed)
        XCTAssertEqual(commit.record.offset, AgentJournalOffset(rawValue: 1))
        XCTAssertEqual(commit.record.committedAt, instant)
        let loadedMetadata = try await store.metadata(for: fixture.runID)
        let loadedEvents = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(loadedMetadata, fixture.metadata)
        XCTAssertEqual(loadedEvents, [commit.record])
        let recoveryRecord = try await store.acceptedRunRecoveryRecord(
            for: fixture.runID
        )
        XCTAssertEqual(
            recoveryRecord,
            SwiftDataAcceptedRunRecoveryRecord(
                metadata: fixture.metadata,
                executionComposition: expectedComposition
            )
        )

        let context = ModelContext(container)
        let persistedEvent = try XCTUnwrap(context.fetch(FetchDescriptor<AgentEventRecord>()).first)
        XCTAssertEqual(persistedEvent.eventIDString, fixture.acceptanceEvent.header.eventID.description)
        XCTAssertEqual(persistedEvent.runIDString, fixture.runID.description)
        XCTAssertEqual(persistedEvent.rootRunIDString, fixture.runID.description)
        XCTAssertEqual(persistedEvent.writerIDString, fixture.writerID.description)
        XCTAssertEqual(persistedEvent.sequenceValue, 1)
        XCTAssertEqual(persistedEvent.writerSequenceValue, 1)
        XCTAssertEqual(persistedEvent.eventKind, AgentEventKind.runAccepted.rawValue)
        XCTAssertEqual(persistedEvent.timestampMilliseconds, instant.rawValue)
        XCTAssertFalse(persistedEvent.encodedEvent.isEmpty)
        XCTAssertFalse(persistedEvent.payloadDigest.isEmpty)
        XCTAssertEqual(
            try JSONAgentEventCodec().decode(persistedEvent.encodedEvent),
            fixture.acceptanceEvent
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PersistedAgentRunMetadataRecord>()),
            1
        )
        let persistedComposition = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ).first
        )
        XCTAssertEqual(persistedComposition.runIDString, fixture.runID.description)
        XCTAssertEqual(persistedComposition.workspaceIDString, fixture.context.workspaceID.description)
        XCTAssertEqual(persistedComposition.toolRegistryDigest, expectedComposition.toolRegistryDigest)
        XCTAssertEqual(
            persistedComposition.compositionDigest,
            SHA256.hash(data: persistedComposition.encodedComposition)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    func testAcceptanceSaveFailureRollsBackMetadataAndEventTogether() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 200)
        let store = SwiftDataAgentStore(
            container: container,
            failureInjector: { boundary in
                if case .beforeSave(.acceptRun) = boundary {
                    throw AgentStoreInjectedFailure.stop
                }
            }
        )

        do {
            _ = try await acceptFixture(fixture, using: store, in: container)
            XCTFail("Injected acceptance save failure unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .acceptRun,
                    code: "swiftdata_operation_failed"
                )
            )
        }

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentEventRecord>()), 0)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<PersistedAgentRunMetadataRecord>()),
            0
        )
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ),
            0
        )
        let loadedMetadata = try await store.metadata(for: fixture.runID)
        XCTAssertNil(loadedMetadata)
    }

    func testExecutionCompositionExactRetryIsIdempotentAndDivergenceConflicts() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 225)
        try seedLegacyConversation(for: fixture, in: container)
        let projection = legacyAcceptance(for: fixture, requestMessageSeed: 22_501)
        let composition = try fixture.executionComposition()
        let store = SwiftDataAgentStore(container: container)

        let first = try await store.accept(
            fixture.acceptance,
            executionComposition: composition,
            legacyProjection: projection
        )
        let retry = try await store.accept(
            fixture.acceptance,
            executionComposition: composition,
            legacyProjection: projection
        )
        XCTAssertEqual(first.disposition, .committed)
        XCTAssertEqual(retry.disposition, .alreadyCommitted)
        XCTAssertEqual(first.record, retry.record)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ),
            1
        )

        do {
            _ = try await store.accept(
                fixture.acceptance,
                executionComposition: try fixture.executionComposition(
                    policyVersion: "different-policy-v2"
                ),
                legacyProjection: projection
            )
            XCTFail("Divergent immutable composition unexpectedly retried")
        } catch let error as AgentStoreError {
            XCTAssertEqual(error, .runConflict(fixture.runID))
        }
    }

    func testExecutionCompositionRecoveryRejectsTamperedEncodedRecord() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 226)
        let store = SwiftDataAgentStore(container: container)
        _ = try await acceptFixture(fixture, using: store, in: container)

        let context = ModelContext(container)
        let record = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ).first
        )
        record.encodedComposition = Data("{\"tampered\":true}".utf8)
        try context.save()

        do {
            _ = try await store.acceptedRunRecoveryRecord(for: fixture.runID)
            XCTFail("Tampered execution composition unexpectedly recovered")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readMetadata,
                    code: "execution_composition_integrity_failed"
                )
            )
        }
    }

    func testExecutionCompositionRecoveryRejectsRehashedScalarConflict() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 2_261)
        let store = SwiftDataAgentStore(container: container)
        _ = try await acceptFixture(fixture, using: store, in: container)

        let context = ModelContext(container)
        let record = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ).first
        )
        let divergent = try fixture.executionComposition(
            policyVersion: "attacker-rehashed-policy-v2"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        record.encodedComposition = try encoder.encode(divergent)
        record.compositionDigest = SHA256.hash(data: record.encodedComposition)
            .map { String(format: "%02x", $0) }
            .joined()
        try context.save()

        do {
            _ = try await store.acceptedRunRecoveryRecord(for: fixture.runID)
            XCTFail("Rehashed composition with stale scalar binding unexpectedly recovered")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readMetadata,
                    code: "execution_composition_binding_mismatch"
                )
            )
        }
    }

    func testExecutionCompositionCanonicalizesToolLocalitiesAndRejectsSensitiveShapes() throws {
        let fixture = AgentStoreFixture(seed: 227)
        let registry = try ToolRegistry(
            tools: Array(SandboxToolCatalog.all.prefix(2))
        )
        let localities: [String: ToolExecutionLocality] = [
            "list_directory": .onDevice,
            "list_tree": .onDevice,
        ]
        let composition = try fixture.executionComposition(
            toolRegistry: registry,
            toolLocalities: localities
        )
        XCTAssertEqual(
            composition.tools.map(\.tool.name),
            ["list_directory", "list_tree"]
        )
        XCTAssertTrue(AgentRunExecutionComposition.isSHA256(
            composition.toolRegistryDigest
        ))
        XCTAssertTrue(AgentRunExecutionComposition.isSHA256(
            composition.toolLocalitiesDigest
        ))
        XCTAssertThrowsError(
            try fixture.executionComposition(
                toolRegistry: registry,
                toolLocalities: [
                    "list_directory": .worker,
                    "list_tree": .onDevice,
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentRunExecutionCompositionError,
                .invalidToolLocality("list_directory")
            )
        }

        XCTAssertThrowsError(
            try fixture.executionComposition(modelID: "/Users/example/private-model")
        ) { error in
            XCTAssertEqual(
                error as? AgentRunExecutionCompositionError,
                .rawHostPath(field: "modelID")
            )
        }
        XCTAssertThrowsError(
            try AgentRunProviderOptions(ProviderGenerationOptions(
                previousResponseID: "provider-response-opaque-id"
            ))
        ) { error in
            XCTAssertEqual(
                error as? AgentRunExecutionCompositionError,
                .attemptScopedProviderOption("previousResponseID")
            )
        }
    }

    func testExecutionCompositionInstructionDigestsAreDomainSeparatedAndNeverPersistPlaintext() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 228)
        let store = SwiftDataAgentStore(container: container)
        try seedLegacyConversation(for: fixture, in: container)
        let instruction = "TOP-SECRET-M9-INSTRUCTION-228"
        let composition = try fixture.executionComposition(
            systemInstruction: instruction,
            developerInstruction: instruction
        )

        XCTAssertNotNil(composition.systemInstructionDigest)
        XCTAssertNotNil(composition.developerInstructionDigest)
        XCTAssertNotEqual(
            composition.systemInstructionDigest,
            composition.developerInstructionDigest,
            "System and developer instructions require separate hash domains."
        )
        XCTAssertTrue(AgentRunExecutionComposition.isSHA256(
            try XCTUnwrap(composition.systemInstructionDigest)
        ))
        XCTAssertTrue(AgentRunExecutionComposition.isSHA256(
            try XCTUnwrap(composition.developerInstructionDigest)
        ))

        let absent = try fixture.executionComposition(
            systemInstruction: nil,
            developerInstruction: nil
        )
        let explicitlyEmpty = try fixture.executionComposition(
            systemInstruction: "",
            developerInstruction: ""
        )
        XCTAssertNil(absent.systemInstructionDigest)
        XCTAssertNil(absent.developerInstructionDigest)
        XCTAssertNotNil(explicitlyEmpty.systemInstructionDigest)
        XCTAssertNotNil(explicitlyEmpty.developerInstructionDigest)
        XCTAssertNotEqual(absent, explicitlyEmpty)
        XCTAssertThrowsError(
            try explicitlyEmpty.validateRuntimeBinding(
                fixture.runtimeBinding(
                    systemInstruction: nil,
                    developerInstruction: nil
                ),
                matching: fixture.context
            )
        ) { error in
            XCTAssertEqual(
                error as? AgentRunExecutionCompositionError,
                .runtimeBindingMismatch
            )
        }

        _ = try await store.accept(
            fixture.acceptance,
            executionComposition: composition,
            legacyProjection: legacyAcceptance(
                for: fixture,
                requestMessageSeed: 22_801
            )
        )
        let context = ModelContext(container)
        let record = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ).first
        )
        XCTAssertEqual(
            record.systemInstructionDigest,
            composition.systemInstructionDigest
        )
        XCTAssertEqual(
            record.developerInstructionDigest,
            composition.developerInstructionDigest
        )
        XCTAssertFalse(
            String(decoding: record.encodedComposition, as: UTF8.self)
                .contains(instruction),
            "Instruction plaintext must never enter the composition record."
        )
        let recoveryRecord = try await store.acceptedRunRecoveryRecord(
            for: fixture.runID
        )
        XCTAssertEqual(recoveryRecord?.executionComposition, composition)
    }

    func testExecutionCompositionRuntimeBindingRejectsEveryExecutableDependencyDrift() throws {
        let fixture = AgentStoreFixture(seed: 229)
        let registry = try ToolRegistry(
            tools: Array(SandboxToolCatalog.all.prefix(2))
        )
        let localities: [String: ToolExecutionLocality] = [
            "list_directory": .onDevice,
            "list_tree": .onDevice,
        ]
        let composition = try fixture.executionComposition(
            toolRegistry: registry,
            toolLocalities: localities,
            systemInstruction: "system-v1",
            developerInstruction: "developer-v1"
        )
        let exact = try fixture.runtimeBinding(
            toolRegistry: registry,
            toolLocalities: localities,
            systemInstruction: "system-v1",
            developerInstruction: "developer-v1"
        )
        XCTAssertNoThrow(
            try composition.validateRuntimeBinding(
                exact,
                matching: fixture.context
            )
        )

        let mismatches: [AgentRunExecutionRuntimeBinding] = [
            try fixture.runtimeBinding(
                modelID: "gpt-different",
                toolRegistry: registry,
                toolLocalities: localities,
                systemInstruction: "system-v1",
                developerInstruction: "developer-v1"
            ),
            try fixture.runtimeBinding(
                temperature: 0.3,
                toolRegistry: registry,
                toolLocalities: localities,
                systemInstruction: "system-v1",
                developerInstruction: "developer-v1"
            ),
            try fixture.runtimeBinding(
                policyVersion: "test-policy-v2",
                toolRegistry: registry,
                toolLocalities: localities,
                systemInstruction: "system-v1",
                developerInstruction: "developer-v1"
            ),
            try fixture.runtimeBinding(
                toolRegistry: registry,
                toolLocalities: localities,
                contextPreparationVersion: "test-context-preparation-v2",
                systemInstruction: "system-v1",
                developerInstruction: "developer-v1"
            ),
            try fixture.runtimeBinding(
                toolRegistry: try ToolRegistry(tools: []),
                toolLocalities: [:],
                systemInstruction: "system-v1",
                developerInstruction: "developer-v1"
            ),
            try fixture.runtimeBinding(
                toolRegistry: registry,
                toolLocalities: [
                    "list_directory": .worker,
                    "list_tree": .onDevice,
                ],
                systemInstruction: "system-v1",
                developerInstruction: "developer-v1"
            ),
            try fixture.runtimeBinding(
                toolRegistry: registry,
                toolLocalities: localities,
                systemInstruction: "system-v2",
                developerInstruction: "developer-v1"
            ),
            try fixture.runtimeBinding(
                toolRegistry: registry,
                toolLocalities: localities,
                systemInstruction: "system-v1",
                developerInstruction: "developer-v2"
            ),
        ]
        for (index, mismatch) in mismatches.enumerated() {
            XCTAssertThrowsError(
                try composition.validateRuntimeBinding(
                    mismatch,
                    matching: fixture.context
                ),
                "Mismatch index \(index) unexpectedly matched."
            ) { error in
                XCTAssertEqual(
                    error as? AgentRunExecutionCompositionError,
                    .runtimeBindingMismatch
                )
            }
        }
    }

    func testExecutionCompositionInstructionTamperingFailsClosed() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 230)
        let store = SwiftDataAgentStore(container: container)
        try seedLegacyConversation(for: fixture, in: container)
        let accepted = try fixture.executionComposition(
            systemInstruction: "accepted-system-v1",
            developerInstruction: "accepted-developer-v1"
        )
        _ = try await store.accept(
            fixture.acceptance,
            executionComposition: accepted,
            legacyProjection: legacyAcceptance(
                for: fixture,
                requestMessageSeed: 23_001
            )
        )

        let context = ModelContext(container)
        let record = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ).first
        )
        record.systemInstructionDigest = String(repeating: "0", count: 64)
        try context.save()
        do {
            _ = try await store.acceptedRunRecoveryRecord(for: fixture.runID)
            XCTFail("Scalar instruction digest tamper unexpectedly recovered")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readMetadata,
                    code: "execution_composition_binding_mismatch"
                )
            )
        }

        let rehashed = try fixture.executionComposition(
            systemInstruction: "attacker-system-v2",
            developerInstruction: "accepted-developer-v1"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        record.encodedComposition = try encoder.encode(rehashed)
        record.compositionDigest = SHA256.hash(data: record.encodedComposition)
            .map { String(format: "%02x", $0) }
            .joined()
        record.systemInstructionDigest = rehashed.systemInstructionDigest
        record.developerInstructionDigest = rehashed.developerInstructionDigest
        try context.save()

        do {
            _ = try await SwiftDataProjectedRunJournal.recovering(
                store: store,
                runID: fixture.runID,
                runtimeBinding: try fixture.runtimeBinding(
                    systemInstruction: "accepted-system-v1",
                    developerInstruction: "accepted-developer-v1"
                )
            )
            XCTFail("Rehashed instruction tamper unexpectedly rebuilt a journal")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readMetadata,
                    code: "execution_composition_runtime_binding_mismatch"
                )
            )
        }
    }

    func testAcceptanceAtomicallyBindsFreshConversationAndJoinsLegacyRowsOnExactRetry() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 250)
        try seedLegacyConversation(for: fixture, bindProject: false, in: container)
        let projection = legacyAcceptance(for: fixture, requestMessageSeed: 25_001)
        let store = SwiftDataAgentStore(container: container)

        let first = try await store.accept(
            fixture.acceptance,
            legacyProjection: projection
        )
        let retry = try await store.accept(
            fixture.acceptance,
            legacyProjection: projection
        )

        XCTAssertEqual(first.disposition, .committed)
        XCTAssertEqual(retry.disposition, .alreadyCommitted)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentEventRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedAgentRunMetadataRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentRunRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 1)
        let run = try XCTUnwrap(context.fetch(FetchDescriptor<AgentRunRecord>()).first)
        let message = try XCTUnwrap(context.fetch(FetchDescriptor<ChatMessage>()).first)
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(run.id, fixture.runID.rawValue)
        XCTAssertEqual(run.requestMessageID, projection.requestMessageID)
        XCTAssertEqual(message.id, projection.requestMessageID)
        XCTAssertEqual(message.content, "Build safely")
        XCTAssertEqual(conversation.project?.id, fixture.context.projectID?.rawValue)

        var divergent = projection
        divergent = SwiftDataLegacyAcceptanceProjection(
            runID: divergent.runID,
            conversationID: divergent.conversationID,
            projectID: divergent.projectID,
            workspaceID: divergent.workspaceID,
            workspaceName: divergent.workspaceName,
            requestMessageID: divergent.requestMessageID,
            requestText: "Different accepted request",
            origin: divergent.origin,
            providerRawValue: divergent.providerRawValue,
            modelID: divergent.modelID
        )
        do {
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: divergent
            )
            XCTFail("Divergent legacy acceptance retry unexpectedly succeeded")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .acceptRun,
                    code: "legacy_acceptance_binding_mismatch"
                )
            )
        }
    }

    func testExactAcceptanceRetryIgnoresMutableRouteButRejectsConversationRebinding() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 255)
        try seedLegacyConversation(for: fixture, bindProject: false, in: container)
        let base = legacyAcceptance(for: fixture, requestMessageSeed: 25_501)
        let projection = SwiftDataLegacyAcceptanceProjection(
            runID: base.runID,
            conversationID: base.conversationID,
            projectID: base.projectID,
            workspaceID: base.workspaceID,
            workspaceName: base.workspaceName,
            requestMessageID: base.requestMessageID,
            requestText: base.requestText,
            origin: base.origin,
            providerRawValue: AIProvider.openAI.rawValue,
            modelID: "accepted-route"
        )
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(fixture.acceptance, legacyProjection: projection)

        let mutationContext = ModelContext(container)
        let run = try XCTUnwrap(
            mutationContext.fetch(FetchDescriptor<AgentRunRecord>()).first
        )
        let conversation = try XCTUnwrap(
            mutationContext.fetch(FetchDescriptor<Conversation>()).first
        )
        let replacementProject = Project(
            name: "Mutable UI route context",
            workspaceName: "Default"
        )
        mutationContext.insert(replacementProject)
        run.provider = .openRouter
        run.modelID = "mutable-observed-route"
        try mutationContext.save()

        let retry = try await store.accept(
            fixture.acceptance,
            legacyProjection: projection
        )
        XCTAssertEqual(retry.disposition, .alreadyCommitted)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<AgentRunRecord>()),
            1
        )

        conversation.project = replacementProject
        try mutationContext.save()
        do {
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: projection
            )
            XCTFail("Conversation rebound to another project unexpectedly validated")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .acceptRun,
                    code: "legacy_acceptance_conflict"
                )
            )
        }
    }

    func testProjectedRunJournalProtocolCannotOmitLegacyAcceptanceRows() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 257)
        try seedLegacyConversation(for: fixture, bindProject: false, in: container)
        let baseProjection = legacyAcceptance(
            for: fixture,
            requestMessageSeed: 25_701
        )
        let projection = SwiftDataLegacyAcceptanceProjection(
            runID: baseProjection.runID,
            conversationID: baseProjection.conversationID,
            projectID: baseProjection.projectID,
            workspaceID: baseProjection.workspaceID,
            workspaceName: baseProjection.workspaceName,
            requestMessageID: baseProjection.requestMessageID,
            acceptedRequestText: baseProjection.acceptedRequestText,
            requestText: "Continue the accepted project safely.",
            origin: .autoContinue,
            providerRawValue: baseProjection.providerRawValue,
            modelID: baseProjection.modelID
        )
        let store = SwiftDataAgentStore(container: container)
        let journal: any AgentEventJournal = try SwiftDataProjectedRunJournal(
            store: store,
            legacyAcceptanceProjection: projection,
            executionComposition: try fixture.executionComposition()
        )

        let commit = try await journal.accept(fixture.acceptance)

        XCTAssertEqual(commit.disposition, .committed)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentEventRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentRunRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 1)
        let run = try XCTUnwrap(
            context.fetch(FetchDescriptor<AgentRunRecord>()).first
        )
        let message = try XCTUnwrap(
            context.fetch(FetchDescriptor<ChatMessage>()).first
        )
        XCTAssertEqual(run.id, fixture.runID.rawValue)
        XCTAssertEqual(run.origin, .autoContinue)
        XCTAssertEqual(message.content, "Continue the accepted project safely.")

        let other = AgentStoreFixture(seed: 258)
        do {
            _ = try await journal.accept(other.acceptance)
            XCTFail("Run-scoped projected journal accepted a different run")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .acceptRun,
                    code: "projected_journal_run_mismatch"
                )
            )
        }
        let unacceptedMetadata = try await store.metadata(for: other.runID)
        XCTAssertNil(unacceptedMetadata)

        try seedLegacyConversation(for: other, in: container)
        _ = try await store.accept(
            other.acceptance,
            legacyProjection: legacyAcceptance(
                for: other,
                requestMessageSeed: 25_801
            )
        )
        do {
            _ = try await journal.append(
                other.envelope(
                    sequence: 2,
                    idempotencyKey: "cross-run-start",
                    payload: .runStarted(RunStartedEvent())
                )
            )
            XCTFail("Run-scoped projected journal appended to a different run")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .appendEvent,
                    code: "projected_journal_run_mismatch"
                )
            )
        }
        do {
            _ = try await journal.events(for: other.runID, after: nil)
            XCTFail("Run-scoped projected journal read a different run")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readEvents,
                    code: "projected_journal_run_mismatch"
                )
            )
        }
        let otherRunEvents = try await store.events(for: other.runID, after: nil)
        XCTAssertEqual(otherRunEvents.count, 1)
    }

    func testProjectedRecoveryJournalBindsExactRunWithoutFabricatingLegacyProjection() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 2_571)
        try seedLegacyConversation(for: fixture, bindProject: false, in: container)
        let store = SwiftDataAgentStore(container: container)
        let composition = try fixture.executionComposition(
            systemInstruction: "recovery-system-v1",
            developerInstruction: "recovery-developer-v1"
        )
        let fresh = try SwiftDataProjectedRunJournal(
            store: store,
            legacyAcceptanceProjection: legacyAcceptance(
                for: fixture,
                requestMessageSeed: 257_101
            ),
            executionComposition: composition
        )
        _ = try await fresh.accept(fixture.acceptance)

        do {
            _ = try await SwiftDataProjectedRunJournal.recovering(
                store: store,
                runID: fixture.runID,
                runtimeBinding: try fixture.runtimeBinding(
                    modelID: "wrong-recovery-model",
                    systemInstruction: "recovery-system-v1",
                    developerInstruction: "recovery-developer-v1"
                )
            )
            XCTFail("Mismatched recovery dependencies unexpectedly rebuilt a journal")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readMetadata,
                    code: "execution_composition_runtime_binding_mismatch"
                )
            )
        }

        let recovered = try await SwiftDataProjectedRunJournal.recovering(
            store: store,
            runID: fixture.runID,
            runtimeBinding: try fixture.runtimeBinding(
                systemInstruction: "recovery-system-v1",
                developerInstruction: "recovery-developer-v1"
            )
        )
        XCTAssertEqual(recovered.boundRunID, fixture.runID)
        XCTAssertEqual(recovered.executionComposition, composition)
        let recoveredMetadata = try await recovered.metadata(for: fixture.runID)
        let initialRecoveredEvents = try await recovered.events(
            for: fixture.runID,
            after: nil
        )
        XCTAssertEqual(recoveredMetadata, fixture.metadata)
        XCTAssertEqual(initialRecoveredEvents.count, 1)

        let append = try await recovered.append(
            fixture.envelope(
                sequence: 2,
                idempotencyKey: "recovered-start",
                payload: .runStarted(RunStartedEvent())
            )
        )
        XCTAssertEqual(append.disposition, .committed)
        let appendedEvents = try await recovered.events(
            for: fixture.runID,
            after: .first
        )
        XCTAssertEqual(
            appendedEvents.map(\.envelope),
            [append.record.envelope]
        )

        do {
            _ = try await recovered.accept(fixture.acceptance)
            XCTFail("Recovery journal unexpectedly accepted a run")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .acceptRun,
                    code: "recovery_journal_accept_forbidden"
                )
            )
        }

        let context = ModelContext(container)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<AgentRunRecord>()),
            1
        )
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<ChatMessage>()),
            1,
            "Recovery must never fabricate another legacy request row."
        )
    }

    func testExactAcceptanceAndAppendRetriesCannotHideCorruptionInAnotherRun() async throws {
        let container = try makeContainer()
        let first = AgentStoreFixture(seed: 259)
        let second = AgentStoreFixture(seed: 269)
        let store = SwiftDataAgentStore(container: container)
        try seedLegacyConversation(for: first, in: container)
        try seedLegacyConversation(for: second, in: container)
        let firstProjection = legacyAcceptance(for: first, requestMessageSeed: 25_901)
        let secondProjection = legacyAcceptance(for: second, requestMessageSeed: 26_901)
        _ = try await store.accept(
            first.acceptance,
            legacyProjection: firstProjection
        )
        let started = first.envelope(
            sequence: 2,
            idempotencyKey: "first-started-before-corruption",
            payload: .runStarted(RunStartedEvent())
        )
        _ = try await store.append(started)
        _ = try await store.accept(
            second.acceptance,
            legacyProjection: secondProjection
        )

        let context = ModelContext(container)
        let secondRunID = second.runID.description
        let secondRow = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<AgentEventRecord>(
                    predicate: #Predicate { row in
                        row.runIDString == secondRunID
                    }
                )
            ).first
        )
        secondRow.sequenceValue = -1
        try context.save()

        do {
            _ = try await store.accept(
                first.acceptance,
                legacyProjection: firstProjection
            )
            XCTFail("Exact acceptance retry hid corruption in another run")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .acceptRun,
                    code: "negative_or_zero_sequence"
                )
            )
        }
        do {
            _ = try await store.append(started)
            XCTFail("Exact append retry hid corruption in another run")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .appendEvent,
                    code: "negative_or_zero_sequence"
                )
            )
        }
    }

    func testLegacyAcceptanceRowsAndFreshProjectBindingRollBackWithV2SaveFailure() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 260)
        try seedLegacyConversation(for: fixture, bindProject: false, in: container)
        let projection = legacyAcceptance(for: fixture, requestMessageSeed: 26_001)
        let store = SwiftDataAgentStore(
            container: container,
            failureInjector: { boundary in
                if case .beforeSave(.acceptRun) = boundary {
                    throw AgentStoreInjectedFailure.stop
                }
            }
        )

        do {
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: projection
            )
            XCTFail("Injected joined acceptance save unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .acceptRun,
                    code: "swiftdata_operation_failed"
                )
            )
        }

        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentEventRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedAgentRunMetadataRecord>()), 0)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ),
            0
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentRunRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 0)
        let conversation = try XCTUnwrap(context.fetch(FetchDescriptor<Conversation>()).first)
        XCTAssertEqual(conversation.messageCount, 0)
        XCTAssertTrue(conversation.messages.isEmpty)
        XCTAssertNil(conversation.project)
    }

    func testAcceptanceCommandIsGloballyUniqueAcrossStoreInstances() async throws {
        let container = try makeContainer()
        let commandID: CommandID = storeTagged(27_000)
        let first = AgentStoreFixture(seed: 270, commandID: commandID)
        let second = AgentStoreFixture(seed: 280, commandID: commandID)
        let firstStore = SwiftDataAgentStore(container: container)
        let secondStore = SwiftDataAgentStore(container: container)
        try seedLegacyConversation(for: first, in: container)
        try seedLegacyConversation(for: second, in: container)
        let firstProjection = legacyAcceptance(for: first, requestMessageSeed: 27_001)
        let secondProjection = legacyAcceptance(for: second, requestMessageSeed: 28_001)

        async let firstResult = captureAgentStoreResult(fallbackOperation: .acceptRun) {
            try await firstStore.accept(
                first.acceptance,
                legacyProjection: firstProjection
            )
        }
        async let secondResult = captureAgentStoreResult(fallbackOperation: .acceptRun) {
            try await secondStore.accept(
                second.acceptance,
                legacyProjection: secondProjection
            )
        }
        let pair = await (firstResult, secondResult)
        let results = [pair.0, pair.1]
        let commits = results.compactMap { try? $0.get() }
        let failures = results.compactMap { result -> AgentStoreError? in
            guard case let .failure(error) = result else { return nil }
            return error
        }

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(failures.count, 1)
        guard case let .acceptanceCommandConflict(conflictCommand, existingRun, incomingRun) = failures[0] else {
            return XCTFail("Duplicate acceptance command did not fail with the typed conflict")
        }
        XCTAssertEqual(conflictCommand, commandID)
        XCTAssertNotEqual(existingRun, incomingRun)
        XCTAssertEqual(Set([existingRun, incomingRun]), Set([first.runID, second.runID]))
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentEventRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersistedAgentRunMetadataRecord>()), 1)
        XCTAssertEqual(
            try context.fetchCount(
                FetchDescriptor<PersistedAgentRunExecutionCompositionRecord>()
            ),
            1
        )
    }

    func testAppendIsIdempotentAndReducerValidated() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 300)
        let store = SwiftDataAgentStore(container: container)
        _ = try await acceptFixture(fixture, using: store, in: container)
        let queued = fixture.envelope(
            sequence: 2,
            idempotencyKey: "queue-once",
            payload: .runQueued(RunQueuedEvent(reason: "foreground"))
        )

        let first = try await store.append(queued)
        let retry = try await store.append(queued)

        XCTAssertEqual(first.disposition, .committed)
        XCTAssertEqual(retry.disposition, .alreadyCommitted)
        XCTAssertEqual(first.record, retry.record)
        let eventsAfterRetry = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(eventsAfterRetry.count, 2)

        let skipped = fixture.envelope(
            sequence: 4,
            idempotencyKey: "skip-sequence",
            payload: .runStarted(RunStartedEvent())
        )
        do {
            _ = try await store.append(skipped)
            XCTFail("Non-contiguous append unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .nonMonotonicSequence(
                    runID: fixture.runID,
                    writerID: fixture.writerID,
                    expected: EventSequence(rawValue: 3),
                    actual: EventSequence(rawValue: 4)
                )
            )
        }
        let eventsAfterRejectedAppend = try await store.events(for: fixture.runID, after: nil)
        XCTAssertEqual(eventsAfterRejectedAppend.count, 2)
    }

    func testTwoRunsOnSameExecutionNodeEachCommitSequenceOne() async throws {
        let container = try makeContainer()
        let sharedNode: ExecutionNodeID = storeTagged(900)
        let first = AgentStoreFixture(seed: 400, executionNodeID: sharedNode)
        let second = AgentStoreFixture(seed: 500, executionNodeID: sharedNode)
        let store = SwiftDataAgentStore(container: container)

        let firstCommit = try await acceptFixture(first, using: store, in: container)
        let secondCommit = try await acceptFixture(second, using: store, in: container)

        XCTAssertEqual(firstCommit.record.envelope.writerSequence, .first)
        XCTAssertEqual(secondCommit.record.envelope.writerSequence, .first)
        XCTAssertNotEqual(first.writerID, second.writerID)
        XCTAssertEqual(first.writerID, AgentEventWriterID(runID: first.runID))
        XCTAssertEqual(second.writerID, AgentEventWriterID(runID: second.runID))
        XCTAssertEqual(firstCommit.record.offset, AgentJournalOffset(rawValue: 1))
        XCTAssertEqual(secondCommit.record.offset, AgentJournalOffset(rawValue: 2))

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<AgentEventRecord>())
        XCTAssertEqual(Set(records.map(\.writerSequenceKey)).count, 2)
        XCTAssertEqual(Set(records.map(\.runSequenceKey)).count, 2)
    }

    func testTwoStoreInstancesSerializeSameAndDifferentWrites() async throws {
        let container = try makeContainer()
        let firstStore = SwiftDataAgentStore(container: container)
        let secondStore = SwiftDataAgentStore(container: container)
        let shared = AgentStoreFixture(seed: 550)
        try seedLegacyConversation(for: shared, in: container)
        let sharedProjection = legacyAcceptance(
            for: shared,
            requestMessageSeed: 55_001
        )

        async let firstAcceptance = firstStore.accept(
            shared.acceptance,
            legacyProjection: sharedProjection
        )
        async let duplicateAcceptance = secondStore.accept(
            shared.acceptance,
            legacyProjection: sharedProjection
        )
        let acceptancePair = try await (firstAcceptance, duplicateAcceptance)
        let acceptanceCommits = [acceptancePair.0, acceptancePair.1]
        XCTAssertEqual(
            acceptanceCommits.filter { $0.disposition == .committed }.count,
            1
        )
        XCTAssertEqual(
            acceptanceCommits.filter { $0.disposition == .alreadyCommitted }.count,
            1
        )

        let started = shared.envelope(
            sequence: 2,
            idempotencyKey: "cross-instance-start",
            payload: .runStarted(RunStartedEvent())
        )
        async let firstAppend = firstStore.append(started)
        async let duplicateAppend = secondStore.append(started)
        let appendPair = try await (firstAppend, duplicateAppend)
        let appendCommits = [appendPair.0, appendPair.1]
        XCTAssertEqual(appendCommits.filter { $0.disposition == .committed }.count, 1)
        XCTAssertEqual(
            appendCommits.filter { $0.disposition == .alreadyCommitted }.count,
            1
        )

        let otherFirst = AgentStoreFixture(seed: 560)
        let otherSecond = AgentStoreFixture(seed: 570)
        try seedLegacyConversation(for: otherFirst, in: container)
        try seedLegacyConversation(for: otherSecond, in: container)
        let otherFirstProjection = legacyAcceptance(
            for: otherFirst,
            requestMessageSeed: 56_001
        )
        let otherSecondProjection = legacyAcceptance(
            for: otherSecond,
            requestMessageSeed: 57_001
        )
        async let otherFirstAcceptance = firstStore.accept(
            otherFirst.acceptance,
            legacyProjection: otherFirstProjection
        )
        async let otherSecondAcceptance = secondStore.accept(
            otherSecond.acceptance,
            legacyProjection: otherSecondProjection
        )
        let otherPair = try await (otherFirstAcceptance, otherSecondAcceptance)
        XCTAssertEqual(otherPair.0.disposition, .committed)
        XCTAssertEqual(otherPair.1.disposition, .committed)
        let all = try ModelContext(container).fetch(
            FetchDescriptor<AgentEventRecord>(
                sortBy: [SortDescriptor(\AgentEventRecord.journalOffsetValue)]
            )
        )
        XCTAssertEqual(all.map(\.journalOffsetValue), [1, 2, 3, 4])
        XCTAssertEqual(Set(all.map(\.eventIDString)).count, 4)
        XCTAssertEqual(Set(all.map(\.writerSequenceKey)).count, 4)
    }

    func testGlobalProjectionCursorUsesCASAndBatchHighWaterMark() async throws {
        let container = try makeContainer()
        let first = AgentStoreFixture(seed: 600)
        let second = AgentStoreFixture(seed: 700)
        let store = SwiftDataAgentStore(container: container)
        _ = try await acceptFixture(first, using: store, in: container)
        _ = try await acceptFixture(second, using: store, in: container)

        let batch = try await store.projectionBatch(after: .origin, limit: 1)
        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.records[0].offset, AgentJournalOffset(rawValue: 1))
        XCTAssertEqual(batch.highWaterMark, AgentJournalOffset(rawValue: 2))
        XCTAssertTrue(batch.hasMore)

        let projectionID = AgentProjectionID(rawValue: "legacy-run-projector:v1")
        let firstCursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: batch.throughOffset,
            updatedAt: AgentInstant(rawValue: 1_800_000_000_200)
        )
        let committed = try await store.saveCursor(
            firstCursor,
            expectedPreviousOffset: .origin
        )
        XCTAssertEqual(committed.disposition, .committed)
        let loadedCursor = try await store.loadCursor(for: projectionID)
        XCTAssertEqual(loadedCursor, firstCursor)

        do {
            _ = try await store.saveCursor(
                firstCursor,
                expectedPreviousOffset: .origin
            )
            XCTFail("Same-offset write with a stale CAS expectation unexpectedly succeeded")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .cursorConflict(
                    projectionID: projectionID,
                    expected: .origin,
                    actual: firstCursor.throughOffset
                )
            )
        }

        let duplicate = try await store.saveCursor(
            firstCursor,
            expectedPreviousOffset: firstCursor.throughOffset
        )
        XCTAssertEqual(duplicate.disposition, .alreadyCommitted)

        let secondCursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: AgentJournalOffset(rawValue: 2),
            updatedAt: AgentInstant(rawValue: 1_800_000_000_300)
        )
        do {
            _ = try await store.saveCursor(
                secondCursor,
                expectedPreviousOffset: .origin
            )
            XCTFail("Stale cursor compare-and-set unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .cursorConflict(
                    projectionID: projectionID,
                    expected: .origin,
                    actual: AgentJournalOffset(rawValue: 1)
                )
            )
        }
    }

    func testTwoStoreInstancesCannotBothWinOneCursorCAS() async throws {
        let container = try makeContainer()
        let firstStore = SwiftDataAgentStore(container: container)
        let secondStore = SwiftDataAgentStore(container: container)
        let firstFixture = AgentStoreFixture(seed: 750)
        let secondFixture = AgentStoreFixture(seed: 760)
        _ = try await acceptFixture(firstFixture, using: firstStore, in: container)
        _ = try await acceptFixture(secondFixture, using: firstStore, in: container)
        let projectionID = AgentProjectionID(rawValue: "concurrent-projector")
        let firstCursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: AgentJournalOffset(rawValue: 1),
            updatedAt: AgentInstant(rawValue: 1_800_000_000_400)
        )
        let secondCursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: AgentJournalOffset(rawValue: 2),
            updatedAt: AgentInstant(rawValue: 1_800_000_000_500)
        )

        async let firstResult = captureAgentStoreResult {
            try await firstStore.saveCursor(
                firstCursor,
                expectedPreviousOffset: .origin
            )
        }
        async let secondResult = captureAgentStoreResult {
            try await secondStore.saveCursor(
                secondCursor,
                expectedPreviousOffset: .origin
            )
        }
        let resultPair = await (firstResult, secondResult)
        let results = [resultPair.0, resultPair.1]
        let successes = results.compactMap { try? $0.get() }
        let failures = results.compactMap { result -> AgentStoreError? in
            guard case let .failure(error) = result else { return nil }
            return error
        }

        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(failures.count, 1)
        guard case let .cursorConflict(failedProjection, expected, actual) = failures[0] else {
            return XCTFail("Losing cursor write did not report a CAS conflict")
        }
        XCTAssertEqual(failedProjection, projectionID)
        XCTAssertEqual(expected, .origin)
        XCTAssertTrue(
            actual == AgentJournalOffset(rawValue: 1) ||
                actual == AgentJournalOffset(rawValue: 2)
        )
        let loaded = try await firstStore.loadCursor(for: projectionID)
        XCTAssertEqual(loaded, successes[0].cursor)
    }

    func testProjectionMutationAndCursorCommitOrRollBackTogether() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 780)
        try seedLegacyConversation(for: fixture, in: container)
        let legacy = legacyAcceptance(for: fixture, requestMessageSeed: 78_001)
        let failingStore = SwiftDataAgentStore(
            container: container,
            failureInjector: { boundary in
                if case .beforeSave(.saveProjectionCursor) = boundary {
                    throw AgentStoreInjectedFailure.stop
                }
            }
        )
        _ = try await failingStore.accept(
            fixture.acceptance,
            legacyProjection: legacy
        )
        let projectID = try XCTUnwrap(fixture.context.projectID?.rawValue)
        let projectionID = AgentProjectionID(rawValue: "legacy-run-projector:v1")
        let cursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: AgentJournalOffset(rawValue: 1),
            updatedAt: AgentInstant(rawValue: 1_800_000_000_600)
        )
        let plan = SwiftDataAgentProjectionPlan(
            mutations: [
                .transitionLegacyRun(
                    SwiftDataLegacyRunTransition(
                        runID: fixture.runID.rawValue,
                        expectedStatus: .queued,
                        status: .running,
                        at: AgentInstant(rawValue: 1_800_000_000_600)
                    )
                )
            ],
            evidenceProjectIDs: [projectID, projectID]
        )
        XCTAssertEqual(plan.evidenceProjectIDs, [projectID])

        do {
            _ = try await failingStore.commitProjection(
                plan,
                cursor: cursor,
                expectedPreviousOffset: .origin
            )
            XCTFail("Injected projection save unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "swiftdata_operation_failed"
                )
            )
        }

        let failedContext = ModelContext(container)
        let failedRun = try XCTUnwrap(
            failedContext.fetch(FetchDescriptor<AgentRunRecord>()).first
        )
        XCTAssertEqual(failedRun.status, .queued)
        XCTAssertEqual(
            try XCTUnwrap(failedContext.fetch(FetchDescriptor<ChatMessage>()).first).runStatus,
            .queued
        )
        let failedCursor = try await failingStore.loadCursor(for: projectionID)
        XCTAssertNil(failedCursor)
        XCTAssertNil(try materializedEvidenceRevision(for: projectID, in: container))

        let cleanStore = SwiftDataAgentStore(container: container)
        let committed = try await cleanStore.commitProjection(
            plan,
            cursor: cursor,
            expectedPreviousOffset: .origin
        )
        XCTAssertEqual(committed.disposition, .committed)
        let committedContext = ModelContext(container)
        let committedRun = try XCTUnwrap(
            committedContext.fetch(FetchDescriptor<AgentRunRecord>()).first
        )
        XCTAssertEqual(committedRun.status, .running)
        XCTAssertEqual(
            try XCTUnwrap(
                committedContext.fetch(FetchDescriptor<ChatMessage>()).first
            ).runStatus,
            .running
        )
        let committedCursor = try await cleanStore.loadCursor(for: projectionID)
        XCTAssertEqual(committedCursor, cursor)
        XCTAssertEqual(
            try materializedEvidenceRevision(for: projectID, in: container),
            1
        )

        let retry = try await cleanStore.commitProjection(
            plan,
            cursor: cursor,
            expectedPreviousOffset: cursor.throughOffset
        )
        XCTAssertEqual(retry.disposition, .alreadyCommitted)
        let retryContext = ModelContext(container)
        XCTAssertEqual(
            try XCTUnwrap(retryContext.fetch(FetchDescriptor<AgentRunRecord>()).first).status,
            .running
        )
        XCTAssertEqual(
            try materializedEvidenceRevision(for: projectID, in: container),
            1
        )
    }

    func testProjectionEvidenceRevisionRejectsMissingProjectAndOverflowAtomically() async throws {
        do {
            let container = try makeContainer()
            let fixture = AgentStoreFixture(seed: 790)
            try seedLegacyConversation(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            let accepted = try await store.accept(
                fixture.acceptance,
                legacyProjection: legacyAcceptance(
                    for: fixture,
                    requestMessageSeed: 79_001
                )
            )
            let missingProjectID = storeTaggedMessageUUID(79_999)
            let projectionID = AgentProjectionID(rawValue: "missing-evidence-project")

            do {
                _ = try await store.commitProjection(
                    SwiftDataAgentProjectionPlan(
                        mutations: [
                            .transitionLegacyRun(
                                SwiftDataLegacyRunTransition(
                                    runID: fixture.runID.rawValue,
                                    expectedStatus: .queued,
                                    status: .running,
                                    at: accepted.record.committedAt
                                )
                            )
                        ],
                        evidenceProjectIDs: [missingProjectID]
                    ),
                    cursor: AgentProjectionCursor(
                        projectionID: projectionID,
                        throughOffset: accepted.record.offset,
                        updatedAt: accepted.record.committedAt
                    ),
                    expectedPreviousOffset: .origin
                )
                XCTFail("Missing evidence project unexpectedly committed")
            } catch let error as AgentStoreError {
                XCTAssertEqual(
                    error,
                    .persistenceFailure(
                        operation: .saveProjectionCursor,
                        code: "projection_evidence_project_missing"
                    )
                )
            }

            let missingCursor = try await store.loadCursor(for: projectionID)
            XCTAssertNil(missingCursor)
            XCTAssertEqual(
                try XCTUnwrap(
                    ModelContext(container).fetch(FetchDescriptor<AgentRunRecord>()).first
                ).status,
                .queued
            )
            XCTAssertNil(
                try materializedEvidenceRevision(
                    for: missingProjectID,
                    in: container
                )
            )
        }

        do {
            let container = try makeContainer()
            let fixture = AgentStoreFixture(seed: 795)
            try seedLegacyConversation(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            let accepted = try await store.accept(
                fixture.acceptance,
                legacyProjection: legacyAcceptance(
                    for: fixture,
                    requestMessageSeed: 79_501
                )
            )
            let projectID = try XCTUnwrap(fixture.context.projectID?.rawValue)
            let overflowContext = ModelContext(container)
            overflowContext.insert(ProjectMaterializedEvidenceRevisionRecord(
                projectID: projectID,
                revision: Int64.max
            ))
            try overflowContext.save()
            let projectionID = AgentProjectionID(rawValue: "overflow-evidence-revision")

            do {
                _ = try await store.commitProjection(
                    SwiftDataAgentProjectionPlan(
                        mutations: [
                            .transitionLegacyRun(
                                SwiftDataLegacyRunTransition(
                                    runID: fixture.runID.rawValue,
                                    expectedStatus: .queued,
                                    status: .running,
                                    at: accepted.record.committedAt
                                )
                            )
                        ],
                        evidenceProjectIDs: [projectID]
                    ),
                    cursor: AgentProjectionCursor(
                        projectionID: projectionID,
                        throughOffset: accepted.record.offset,
                        updatedAt: accepted.record.committedAt
                    ),
                    expectedPreviousOffset: .origin
                )
                XCTFail("Overflowing evidence revision unexpectedly committed")
            } catch let error as AgentStoreError {
                XCTAssertEqual(
                    error,
                    .persistenceFailure(
                        operation: .saveProjectionCursor,
                        code: "projection_evidence_revision_overflow"
                    )
                )
            }

            let overflowCursor = try await store.loadCursor(for: projectionID)
            XCTAssertNil(overflowCursor)
            XCTAssertEqual(
                try XCTUnwrap(
                    ModelContext(container).fetch(FetchDescriptor<AgentRunRecord>()).first
                ).status,
                .queued
            )
            XCTAssertEqual(
                try materializedEvidenceRevision(for: projectID, in: container),
                Int64.max
            )
        }
    }

    func testReducerSnapshotRestoresThenReplaysLaterEvents() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 800)
        let store = SwiftDataAgentStore(container: container)
        _ = try await acceptFixture(fixture, using: store, in: container)
        _ = try await store.append(fixture.envelope(
            sequence: 2,
            idempotencyKey: "start",
            payload: .runStarted(RunStartedEvent())
        ))

        let running = try await store.replay(runID: fixture.runID)
        XCTAssertEqual(running.phase, .running)
        try await store.saveSnapshot(
            running,
            projectionID: NovaForgeAgentProjection.canonicalReducer,
            projectionVersion: NovaForgeAgentProjection.canonicalReducerVersion,
            runID: fixture.runID
        )

        _ = try await store.append(fixture.envelope(
            sequence: 3,
            idempotencyKey: "complete",
            payload: .runCompleted(RunCompletedEvent(summary: "done"))
        ))
        let completed = try await store.replay(runID: fixture.runID)

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.lastSequence, EventSequence(rawValue: 3))
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectionSnapshotRecord>()), 1)
    }

    func testOutOfRangeReadCursorFailsInsteadOfReplayingFromOrigin() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 900)
        let store = SwiftDataAgentStore(container: container)
        _ = try await acceptFixture(fixture, using: store, in: container)
        let unsupported = EventSequence(rawValue: UInt64(Int64.max) + 1)

        do {
            _ = try await store.events(for: fixture.runID, after: unsupported)
            XCTFail("Out-of-range sequence unexpectedly replayed from the beginning")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readEvents,
                    code: "sequence_out_of_range"
                )
            )
        }
    }

    func testCorruptSignedSequenceAndDuplicatedHeaderFailClosed() async throws {
        let negativeContainer = try makeContainer()
        let negativeFixture = AgentStoreFixture(seed: 1_000)
        let negativeStore = SwiftDataAgentStore(container: negativeContainer)
        _ = try await acceptFixture(
            negativeFixture,
            using: negativeStore,
            in: negativeContainer
        )
        let negativeContext = ModelContext(negativeContainer)
        let negativeRecord = try XCTUnwrap(
            negativeContext.fetch(FetchDescriptor<AgentEventRecord>()).first
        )
        negativeRecord.sequenceValue = -1
        try negativeContext.save()

        do {
            _ = try await negativeStore.events(for: negativeFixture.runID, after: nil)
            XCTFail("Negative persisted sequence unexpectedly decoded")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readEvents,
                    code: "negative_or_zero_sequence"
                )
            )
        }

        let headerContainer = try makeContainer()
        let headerFixture = AgentStoreFixture(seed: 1_100)
        let headerStore = SwiftDataAgentStore(container: headerContainer)
        _ = try await acceptFixture(
            headerFixture,
            using: headerStore,
            in: headerContainer
        )
        let headerContext = ModelContext(headerContainer)
        let headerRecord = try XCTUnwrap(
            headerContext.fetch(FetchDescriptor<AgentEventRecord>()).first
        )
        let wrongWorkspace: WorkspaceID = storeTagged(99_999)
        headerRecord.workspaceIDString = wrongWorkspace.description
        try headerContext.save()

        do {
            _ = try await headerStore.events(for: headerFixture.runID, after: nil)
            XCTFail("Mismatched indexed header unexpectedly decoded")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readEvents,
                    code: "event_header_index_mismatch"
                )
            )
        }
    }

    func testReducerInvalidPrefixCannotHideBehindReadOrProjectionCursor() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 1_125)
        try seedLegacyConversation(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: legacyAcceptance(
                for: fixture,
                requestMessageSeed: 112_501
            )
        )
        _ = try await store.append(
            fixture.envelope(
                sequence: 2,
                idempotencyKey: "valid-before-corruption",
                payload: .runStarted(RunStartedEvent())
            )
        )
        let projectionID = AgentProjectionID(rawValue: "prefix-validator")
        let cursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: AgentJournalOffset(rawValue: 2),
            updatedAt: AgentInstant(rawValue: 1_800_000_100_000)
        )
        _ = try await store.saveCursor(cursor, expectedPreviousOffset: .origin)

        let invalid = fixture.envelope(
            sequence: 2,
            idempotencyKey: "valid-before-corruption",
            payload: .toolStarted(
                ToolStartedEvent(callID: storeTagged(1_125_999))
            )
        ).event
        let encoded = try JSONAgentEventCodec().encode(invalid)
        let corruptionContext = ModelContext(container)
        let row = try XCTUnwrap(
            corruptionContext.fetch(
                FetchDescriptor<AgentEventRecord>(
                    sortBy: [SortDescriptor(\AgentEventRecord.sequenceValue)]
                )
            ).last
        )
        row.encodedEvent = encoded
        row.payloadDigest = testSHA256(encoded)
        row.eventKind = invalid.payload.kind.rawValue
        try corruptionContext.save()

        do {
            _ = try await store.events(
                for: fixture.runID,
                after: EventSequence(rawValue: 1)
            )
            XCTFail("Reducer-invalid prefix was hidden by the sequence cursor")
        } catch {
            XCTAssertTrue(error is AgentStoreError)
        }
        do {
            _ = try await store.projectionBatch(
                after: cursor.throughOffset,
                limit: 8
            )
            XCTFail("Reducer-invalid prefix was hidden by the projection cursor")
        } catch {
            XCTAssertTrue(error is AgentStoreError)
        }
        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try XCTUnwrap(
                verificationContext.fetch(FetchDescriptor<ProjectionCursorRecord>()).first
            ).throughOffsetValue,
            2
        )
        XCTAssertEqual(
            try XCTUnwrap(
                verificationContext.fetch(FetchDescriptor<AgentRunRecord>()).first
            ).status,
            .queued
        )
    }

    func testGlobalOffsetGapBeforeCursorFailsWithoutChangingCursorOrView() async throws {
        let container = try makeContainer()
        let first = AgentStoreFixture(seed: 1_130)
        let second = AgentStoreFixture(seed: 1_140)
        try seedLegacyConversation(for: first, in: container)
        try seedLegacyConversation(for: second, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(
            first.acceptance,
            legacyProjection: legacyAcceptance(for: first, requestMessageSeed: 113_001)
        )
        _ = try await store.accept(
            second.acceptance,
            legacyProjection: legacyAcceptance(for: second, requestMessageSeed: 114_001)
        )
        let projectionID = AgentProjectionID(rawValue: "global-prefix-validator")
        let cursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: AgentJournalOffset(rawValue: 2),
            updatedAt: AgentInstant(rawValue: 1_800_000_200_000)
        )
        _ = try await store.saveCursor(cursor, expectedPreviousOffset: .origin)

        let corruptionContext = ModelContext(container)
        let rows = try corruptionContext.fetch(
            FetchDescriptor<AgentEventRecord>(
                sortBy: [SortDescriptor(\AgentEventRecord.journalOffsetValue)]
            )
        )
        let firstRow = try XCTUnwrap(rows.first)
        firstRow.journalOffsetValue = 4
        try corruptionContext.save()

        do {
            _ = try await store.projectionBatch(after: cursor.throughOffset, limit: 8)
            XCTFail("An earlier global offset gap was hidden by the cursor")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .readProjection,
                    code: "non_contiguous_offsets"
                )
            )
        }
        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try XCTUnwrap(
                verificationContext.fetch(FetchDescriptor<ProjectionCursorRecord>()).first
            ).throughOffsetValue,
            2
        )
        XCTAssertTrue(
            try verificationContext.fetch(FetchDescriptor<AgentRunRecord>())
                .allSatisfy { $0.status == .queued }
        )
    }

    func testCursorIntegrityRejectsKeyProjectionAndHighWaterCorruption() async throws {
        for corruption in CursorCorruption.allCases {
            let container = try makeContainer()
            let fixture = AgentStoreFixture(seed: 1_150 + corruption.seedOffset)
            let store = SwiftDataAgentStore(container: container)
            _ = try await acceptFixture(fixture, using: store, in: container)
            let projectionID = AgentProjectionID(
                rawValue: "cursor-integrity-\(corruption.rawValue)"
            )
            let cursor = AgentProjectionCursor(
                projectionID: projectionID,
                throughOffset: AgentJournalOffset(rawValue: 1),
                updatedAt: AgentInstant(rawValue: 1_800_000_300_000)
            )
            _ = try await store.saveCursor(cursor, expectedPreviousOffset: .origin)
            let context = ModelContext(container)
            let row = try XCTUnwrap(
                context.fetch(FetchDescriptor<ProjectionCursorRecord>()).first
            )
            switch corruption {
            case .keyMismatch:
                row.cursorKey = "wrong-key"
            case .blankProjection:
                row.projectionIDString = ""
            case .beyondHighWaterMark:
                row.throughOffsetValue = 2
            }
            try context.save()

            do {
                _ = try await store.loadCursor(for: projectionID)
                XCTFail("Corrupt \(corruption.rawValue) cursor unexpectedly loaded")
            } catch let error as AgentStoreError {
                XCTAssertEqual(
                    error,
                    .persistenceFailure(
                        operation: .loadProjectionCursor,
                        code: "projection_cursor_integrity_failed"
                    )
                )
            }
        }
    }

    func testReplayIgnoresSnapshotsFromOtherProjectionNamespaces() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 1_200)
        let store = SwiftDataAgentStore(container: container)
        _ = try await acceptFixture(fixture, using: store, in: container)
        _ = try await store.append(fixture.envelope(
            sequence: 2,
            idempotencyKey: "start-before-foreign-snapshot",
            payload: .runStarted(RunStartedEvent())
        ))
        let running = try await store.replay(runID: fixture.runID)
        try await store.saveSnapshot(
            running,
            projectionID: AgentProjectionID(rawValue: "projectos-projector:v99"),
            projectionVersion: 99,
            runID: fixture.runID
        )

        let snapshotContext = ModelContext(container)
        let foreign = try XCTUnwrap(
            snapshotContext.fetch(FetchDescriptor<ProjectionSnapshotRecord>()).first
        )
        foreign.encodedState = Data("not canonical reducer state".utf8)
        foreign.stateDigest = "intentionally-invalid"
        try snapshotContext.save()

        let replayed = try await store.replay(runID: fixture.runID)
        XCTAssertEqual(replayed.phase, .running)
        XCTAssertEqual(replayed.lastSequence, EventSequence(rawValue: 2))
    }

    func testConversationDeletionDispositionIsAtomicIdempotentAndRejectsNewAcceptance() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 1_300)
        try seedLegacyConversation(for: fixture, in: container)
        let projection = legacyAcceptance(for: fixture, requestMessageSeed: 130_001)
        let cleanStore = SwiftDataAgentStore(container: container)
        _ = try await cleanStore.accept(
            fixture.acceptance,
            legacyProjection: projection
        )
        let deletedAt = AgentInstant(rawValue: 1_800_000_500_000).date

        let failingStore = SwiftDataAgentStore(
            container: container,
            failureInjector: { boundary in
                if case .beforeSave(.saveProjectionCursor) = boundary {
                    throw AgentStoreInjectedFailure.stop
                }
            }
        )
        do {
            try await failingStore.deleteConversationFromHistory(
                conversationID: fixture.context.conversationID.rawValue,
                deletedAt: deletedAt
            )
            XCTFail("Injected conversation deletion unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "swiftdata_operation_failed"
                )
            )
        }
        var context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 1)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<AgentMaterializationDispositionRecord>()),
            0
        )

        try await cleanStore.deleteConversationFromHistory(
            conversationID: fixture.context.conversationID.rawValue,
            deletedAt: deletedAt
        )
        // An exact policy retry is a no-op.
        try await cleanStore.deleteConversationFromHistory(
            conversationID: fixture.context.conversationID.rawValue,
            deletedAt: deletedAt.addingTimeInterval(60)
        )

        context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentRunRecord>()), 1)
        let dispositions = try context.fetch(
            FetchDescriptor<AgentMaterializationDispositionRecord>()
        )
        XCTAssertEqual(dispositions.count, 1)
        XCTAssertEqual(dispositions.first?.scopeID, fixture.context.conversationID.rawValue)
        XCTAssertEqual(dispositions.first?.actionRawValue, "suppressChat")
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<ProjectEvent>()).contains {
                $0.kind == .conversationDeleted &&
                    $0.sourceIDString == fixture.context.conversationID.rawValue.uuidString
            }
        )

        let exactRetry = try await cleanStore.accept(
            fixture.acceptance,
            legacyProjection: projection
        )
        XCTAssertEqual(exactRetry.disposition, .alreadyCommitted)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<ChatMessage>()),
            0
        )

        let newFixture = AgentStoreFixture(
            seed: 1_400,
            conversationID: fixture.context.conversationID,
            projectID: fixture.context.projectID
        )
        do {
            _ = try await cleanStore.accept(
                newFixture.acceptance,
                legacyProjection: legacyAcceptance(
                    for: newFixture,
                    requestMessageSeed: 140_001
                )
            )
            XCTFail("New acceptance targeting a suppressed chat unexpectedly committed")
        } catch let error as SwiftDataMaterializationDispositionError {
            XCTAssertEqual(
                error,
                .disposedAcceptance(
                    scopeKind: .conversation,
                    scopeID: fixture.context.conversationID.rawValue
                )
            )
        }
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<AgentEventRecord>()),
            1
        )
    }

    func testProjectDeletionRehomesRetainedReceiptsAndRollsBackAtomically() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 1_500)
        try seedLegacyConversation(for: fixture, in: container)
        let projection = legacyAcceptance(for: fixture, requestMessageSeed: 150_001)
        let cleanStore = SwiftDataAgentStore(container: container)
        _ = try await cleanStore.accept(
            fixture.acceptance,
            legacyProjection: projection
        )
        let projectID = try XCTUnwrap(fixture.context.projectID?.rawValue)
        let deletedAt = AgentInstant(rawValue: 1_800_000_600_000).date

        let seedContext = ModelContext(container)
        let project = try XCTUnwrap(seedContext.fetch(FetchDescriptor<Project>()).first)
        let settings = AgentSettings(
            activeWorkspaceName: project.workspaceName,
            activeProjectID: projectID
        )
        let operation = ToolOperationRecord(
            runID: fixture.runID.rawValue,
            projectID: projectID,
            conversationID: fixture.context.conversationID.rawValue,
            workspaceID: fixture.context.workspaceID.rawValue,
            workspaceName: project.workspaceName,
            toolName: "write_file",
            argumentsJSON: "{}"
        )
        let artifact = AgentArtifactProjectionRecord(
            artifactIDString: storeTaggedMessageUUID(150_010).uuidString.lowercased(),
            eventIDString: fixture.acceptanceEvent.header.eventID.description,
            runIDString: fixture.runID.description,
            projectIDString: projectID.uuidString.lowercased(),
            workspaceIDString: fixture.context.workspaceID.description,
            toolCallIDString: nil,
            sourceKind: "artifactCaptured",
            mediaType: "text/plain",
            displayName: "receipt.txt",
            encodingName: "agent-artifact-reference-json",
            encodingVersion: 1,
            encodedArtifact: Data("receipt".utf8),
            artifactDigest: "digest",
            encodedArtifactSHA256: testSHA256(Data("receipt".utf8)),
            occurredAtMilliseconds: fixture.context.acceptedAt.rawValue,
            createdAt: fixture.context.acceptedAt.date
        )
        let tool = ToolRun(
            name: "write_file",
            argumentsJSON: "{}",
            status: .completed,
            project: project,
            runID: fixture.runID.rawValue,
            runSequence: 2,
            runStatus: .completed
        )
        let projectOS = ProjectOSRun(
            project: project,
            projectName: project.name,
            mission: "Retained canonical mission",
            sourceConversationID: fixture.context.conversationID.rawValue,
            now: fixture.context.acceptedAt.date
        )
        projectOS.id = fixture.runID.rawValue
        let revision = ProjectMaterializedEvidenceRevisionRecord(
            projectID: projectID,
            revision: 9
        )
        seedContext.insert(settings)
        seedContext.insert(operation)
        seedContext.insert(artifact)
        seedContext.insert(tool)
        seedContext.insert(projectOS)
        seedContext.insert(revision)
        project.toolRuns.append(tool)
        project.projectOSRuns.append(projectOS)
        try seedContext.save()

        let failingStore = SwiftDataAgentStore(
            container: container,
            failureInjector: { boundary in
                if case .beforeSave(.saveProjectionCursor) = boundary {
                    throw AgentStoreInjectedFailure.stop
                }
            }
        )
        do {
            _ = try await failingStore.deleteProjectRetainingRunsInGeneral(
                projectID: projectID,
                deletedAt: deletedAt
            )
            XCTFail("Injected project deletion unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "swiftdata_operation_failed"
                )
            )
        }
        var context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectOSRun>()), 1)
        XCTAssertEqual(try materializedEvidenceRevision(for: projectID, in: container), 9)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<AgentMaterializationDispositionRecord>()),
            0
        )

        let receipt = try await cleanStore.deleteProjectRetainingRunsInGeneral(
            projectID: projectID,
            deletedAt: deletedAt
        )
        XCTAssertEqual(receipt.deletedProjectName, "V2 Acceptance")
        XCTAssertTrue(receipt.replacedActiveProject)
        XCTAssertEqual(receipt.fallbackWorkspaceName, "Default")
        _ = try await cleanStore.deleteProjectRetainingRunsInGeneral(
            projectID: projectID,
            deletedAt: deletedAt.addingTimeInterval(60)
        )

        context = ModelContext(container)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Project>()).contains { $0.id == projectID })
        XCTAssertNotNil(
            try context.fetch(FetchDescriptor<Project>()).first {
                $0.id == receipt.fallbackProjectID
            }
        )
        XCTAssertNil(try context.fetch(FetchDescriptor<AgentRunRecord>()).first?.projectID)
        XCTAssertNil(try context.fetch(FetchDescriptor<ToolOperationRecord>()).first?.projectID)
        XCTAssertNil(
            try context.fetch(FetchDescriptor<AgentArtifactProjectionRecord>()).first?.projectIDString
        )
        XCTAssertNil(try context.fetch(FetchDescriptor<ToolRun>()).first?.project)
        XCTAssertNil(try context.fetch(FetchDescriptor<Conversation>()).first?.project)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectOSRun>()), 0)
        XCTAssertNil(try materializedEvidenceRevision(for: projectID, in: container))
        XCTAssertEqual(try context.fetch(FetchDescriptor<AgentSettings>()).first?.activeProjectID, receipt.fallbackProjectID)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<AgentEventRecord>()).first?
                .projectIDString.flatMap(UUID.init(uuidString:)),
            projectID
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<PersistedAgentRunMetadataRecord>()).first?
                .projectIDString.flatMap(UUID.init(uuidString:)),
            projectID
        )
    }

    func testProjectionDispositionFingerprintRejectsStalePlanBeforeAnyMutation() async throws {
        let container = try makeContainer()
        let fixture = AgentStoreFixture(seed: 1_600)
        try seedLegacyConversation(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        let accepted = try await store.accept(
            fixture.acceptance,
            legacyProjection: legacyAcceptance(
                for: fixture,
                requestMessageSeed: 160_001
            )
        )
        let initial = try await store.validatedProjectionBatch(after: .origin, limit: 64)
        let projectionID = AgentProjectionID(rawValue: "stale-disposition-plan")
        let cursor = AgentProjectionCursor(
            projectionID: projectionID,
            throughOffset: accepted.record.offset,
            updatedAt: accepted.record.committedAt
        )
        let stalePlan = SwiftDataAgentProjectionPlan(
            mutations: [
                .transitionLegacyRun(
                    SwiftDataLegacyRunTransition(
                        runID: fixture.runID.rawValue,
                        expectedStatus: .queued,
                        status: .running,
                        at: accepted.record.committedAt
                    )
                )
            ],
            expectedDispositionFingerprint: initial.materializationDisposition.fingerprint
        )

        let mutationContext = ModelContext(container)
        let unrelatedConversationID = storeTaggedMessageUUID(160_999)
        let dispositionAt = AgentInstant(rawValue: 1_800_000_700_000)
        mutationContext.insert(
            AgentMaterializationDispositionRecord(
                scopeKind: .conversation,
                scopeID: unrelatedConversationID,
                action: .suppressChat,
                createdAtMilliseconds: dispositionAt.rawValue,
                createdAt: dispositionAt.date
            )
        )
        try mutationContext.save()

        do {
            _ = try await store.commitProjection(
                stalePlan,
                cursor: cursor,
                expectedPreviousOffset: .origin
            )
            XCTFail("Stale disposition plan unexpectedly committed")
        } catch let error as SwiftDataMaterializationDispositionError {
            guard case let .staleProjectionPlan(expected, actual) = error else {
                return XCTFail("Unexpected disposition error: \(error)")
            }
            XCTAssertEqual(expected, initial.materializationDisposition.fingerprint)
            XCTAssertNotEqual(actual, expected)
        }
        let cursorAfterStalePlan = try await store.loadCursor(for: projectionID)
        XCTAssertNil(cursorAfterStalePlan)
        XCTAssertEqual(
            try XCTUnwrap(
                ModelContext(container).fetch(FetchDescriptor<AgentRunRecord>()).first
            ).status,
            .queued
        )

        let refreshed = try await store.validatedProjectionBatch(after: .origin, limit: 64)
        let refreshedPlan = SwiftDataAgentProjectionPlan(
            mutations: stalePlan.mutations,
            expectedDispositionFingerprint: refreshed.materializationDisposition.fingerprint
        )
        _ = try await store.commitProjection(
            refreshedPlan,
            cursor: cursor,
            expectedPreviousOffset: .origin
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ModelContext(container).fetch(FetchDescriptor<AgentRunRecord>()).first
            ).status,
            .running
        )
    }

    func testMalformedAndConflictingDispositionRowsFailClosed() async throws {
        for conflicting in [false, true] {
            let container = try makeContainer()
            let fixture = AgentStoreFixture(seed: conflicting ? 1_710 : 1_700)
            try seedLegacyConversation(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: legacyAcceptance(
                    for: fixture,
                    requestMessageSeed: conflicting ? 171_001 : 170_001
                )
            )
            let context = ModelContext(container)
            let instant = AgentInstant(rawValue: 1_800_000_800_000)
            let row = AgentMaterializationDispositionRecord(
                scopeKind: .conversation,
                scopeID: storeTaggedMessageUUID(conflicting ? 171_999 : 170_999),
                action: conflicting ? .rehomeToGeneral : .suppressChat,
                createdAtMilliseconds: instant.rawValue,
                createdAt: instant.date
            )
            if !conflicting { row.dispositionKey = "malformed-key" }
            context.insert(row)
            try context.save()

            // Canonical reads/replay are deliberately independent from a
            // poisoned materialization policy table.
            let canonicalBatch = try await store.projectionBatch(
                after: .origin,
                limit: 64
            )
            XCTAssertEqual(canonicalBatch.records.count, 1)
            let canonicalReplay = try await store.replay(runID: fixture.runID)
            XCTAssertEqual(canonicalReplay.phase, .accepted)

            do {
                _ = try await store.validatedProjectionBatch(after: .origin, limit: 64)
                XCTFail("Invalid disposition row unexpectedly validated")
            } catch let error as SwiftDataMaterializationDispositionError {
                if conflicting {
                    guard case .conflictingRecord = error else {
                        return XCTFail("Expected conflicting disposition, got \(error)")
                    }
                } else {
                    XCTAssertEqual(error, .malformedRecord("malformed-key"))
                }
            }
        }
    }

    private func seedLegacyConversation(
        for fixture: AgentStoreFixture,
        bindProject: Bool = true,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        let projectID = try XCTUnwrap(fixture.context.projectID?.rawValue)
        let conversationID = fixture.context.conversationID.rawValue
        var projectDescriptor = FetchDescriptor<Project>(
            predicate: #Predicate { project in project.id == projectID }
        )
        projectDescriptor.fetchLimit = 1
        let project: Project
        if let existing = try context.fetch(projectDescriptor).first {
            project = existing
        } else {
            project = Project(name: "V2 Acceptance", workspaceName: "Default")
            project.id = projectID
            context.insert(project)
        }
        var conversationDescriptor = FetchDescriptor<Conversation>(
            predicate: #Predicate { conversation in
                conversation.id == conversationID
            }
        )
        conversationDescriptor.fetchLimit = 1
        if try context.fetch(conversationDescriptor).first != nil {
            return
        }
        let conversation = Conversation(
            title: "Accepted request",
            project: bindProject ? project : nil
        )
        conversation.id = conversationID
        context.insert(conversation)
        try context.save()
    }

    private func acceptFixture(
        _ fixture: AgentStoreFixture,
        using store: SwiftDataAgentStore,
        in container: ModelContainer
    ) async throws -> AgentJournalCommit {
        try seedLegacyConversation(for: fixture, in: container)
        return try await store.accept(
            fixture.acceptance,
            executionComposition: try fixture.executionComposition(),
            legacyProjection: legacyAcceptance(
                for: fixture,
                requestMessageSeed: 900_000 + fixture.seed
            )
        )
    }

    private func legacyAcceptance(
        for fixture: AgentStoreFixture,
        requestMessageSeed: UInt64
    ) -> SwiftDataLegacyAcceptanceProjection {
        SwiftDataLegacyAcceptanceProjection(
            runID: fixture.runID.rawValue,
            conversationID: fixture.context.conversationID.rawValue,
            projectID: fixture.context.projectID?.rawValue,
            workspaceID: fixture.context.workspaceID.rawValue,
            workspaceName: "Default",
            requestMessageID: storeTaggedMessageUUID(requestMessageSeed),
            requestText: "Build safely"
        )
    }

    private func materializedEvidenceRevision(
        for projectID: UUID,
        in container: ModelContainer
    ) throws -> Int64? {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ProjectMaterializedEvidenceRevisionRecord>(
            predicate: #Predicate { record in record.projectID == projectID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.revision
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: NovaForgeSchemaV4.self),
            migrationPlan: NovaForgeSchemaMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }
}

private enum CursorCorruption: String, CaseIterable {
    case keyMismatch
    case blankProjection
    case beyondHighWaterMark

    var seedOffset: UInt64 {
        switch self {
        case .keyMismatch: 0
        case .blankProjection: 10
        case .beyondHighWaterMark: 20
        }
    }
}

private struct AgentStoreFixture {
    let seed: UInt64
    let context: AgentRunContext
    let userItem: ModelItem
    let correlationID: CorrelationID
    let commandID: CommandID

    init(
        seed: UInt64,
        acceptedAt: AgentInstant? = nil,
        executionNodeID: ExecutionNodeID? = nil,
        commandID: CommandID? = nil,
        conversationID: ConversationID? = nil,
        projectID: ProjectID? = nil
    ) {
        self.seed = seed
        let runID: RunID = storeTagged(seed + 1)
        let instant = acceptedAt ?? AgentInstant(rawValue: 1_800_000_000_000 + Int64(seed))
        context = AgentRunContext(
            schemaVersion: .v1,
            lineage: .root(runID),
            conversationID: conversationID ?? storeTagged(seed + 2),
            projectID: projectID ?? storeTagged(seed + 3),
            workspaceID: storeTagged(seed + 4),
            executionNodeID: executionNodeID ?? storeTagged(seed + 5),
            engineVersion: .agentHarnessV1,
            acceptedAt: instant,
            features: AgentFeatureSet(["v2DarkReplay"]),
            cancellation: CancellationLineage(scopeID: storeTagged(seed + 6)),
            initialBudget: AgentBudget(limits: .standard)
        )
        userItem = ModelItem(
            id: storeTagged(seed + 7),
            createdAt: instant,
            payload: .message(ModelMessage(role: .user, content: [.text("Build safely")]))
        )
        correlationID = storeTagged(seed + 8)
        self.commandID = commandID ?? storeTagged(seed + 9)
    }

    var runID: RunID { context.lineage.runID }
    var writerID: AgentEventWriterID { AgentEventWriterID(runID: runID) }

    var acceptanceEvent: AgentEvent {
        event(
            sequence: 1,
            payload: .runAccepted(RunAcceptedEvent(context: context, initialItems: [userItem]))
        )
    }

    var metadata: AgentStore.AgentRunMetadataRecord {
        AgentStore.AgentRunMetadataRecord(
            context: context,
            writerID: writerID,
            acceptanceCommandID: commandID,
            acceptanceEventID: acceptanceEvent.header.eventID
        )
    }

    var acceptance: AgentRunAcceptance {
        AgentRunAcceptance(
            metadata: metadata,
            envelope: AgentEventEnvelope(
                writerID: writerID,
                writerSequence: .first,
                idempotencyKey: "accept-\(runID.description)",
                event: acceptanceEvent
            )
        )
    }

    func executionComposition(
        modelID: String = "gpt-test",
        policyVersion: String = "test-policy-v1",
        toolRegistry: ToolRegistry? = nil,
        toolLocalities: [String: ToolExecutionLocality] = [:],
        contextPreparationVersion: String = "test-context-preparation-v1",
        systemInstruction: String? = nil,
        developerInstruction: String? = nil
    ) throws -> AgentRunExecutionComposition {
        let registry: ToolRegistry
        if let toolRegistry {
            registry = toolRegistry
        } else {
            registry = try ToolRegistry(tools: [])
        }
        return try AgentRunExecutionComposition(
            context: context,
            providerRoute: providerRoute(modelID: modelID),
            providerOptions: providerOptions(),
            toolRegistry: registry,
            toolLocalities: toolLocalities,
            policyVersion: policyVersion,
            contextPreparationVersion: contextPreparationVersion,
            systemInstruction: systemInstruction,
            developerInstruction: developerInstruction
        )
    }

    func runtimeBinding(
        modelID: String = "gpt-test",
        temperature: Double? = 0.2,
        policyVersion: String = "test-policy-v1",
        toolRegistry: ToolRegistry? = nil,
        toolLocalities: [String: ToolExecutionLocality] = [:],
        contextPreparationVersion: String = "test-context-preparation-v1",
        systemInstruction: String? = nil,
        developerInstruction: String? = nil
    ) throws -> AgentRunExecutionRuntimeBinding {
        let registry: ToolRegistry
        if let toolRegistry {
            registry = toolRegistry
        } else {
            registry = try ToolRegistry(tools: [])
        }
        return AgentRunExecutionRuntimeBinding(
            providerRoute: providerRoute(modelID: modelID),
            providerOptions: providerOptions(temperature: temperature),
            toolRegistry: registry,
            toolLocalities: toolLocalities,
            policyVersion: policyVersion,
            contextPreparationVersion: contextPreparationVersion,
            systemInstruction: systemInstruction,
            developerInstruction: developerInstruction
        )
    }

    private func providerRoute(modelID: String) -> ProviderRoute {
        ProviderRoute(
            providerID: ProviderID(rawValue: "test-provider"),
            modelID: ProviderModelID(rawValue: modelID),
            adapterID: ProviderAdapterID(rawValue: "test-adapter-v1"),
            capabilities: .openAIChatBaseline,
            deployment: .callerManaged,
            provenance: .callerConfigured
        )
    }

    private func providerOptions(
        temperature: Double? = 0.2
    ) -> ProviderGenerationOptions {
        ProviderGenerationOptions(
            maximumOutputTokens: 2_048,
            temperature: temperature,
            parallelToolCalls: false,
            toolChoice: .none
        )
    }

    func envelope(
        sequence: UInt64,
        idempotencyKey: String,
        payload: AgentEventPayload
    ) -> AgentEventEnvelope {
        AgentEventEnvelope(
            writerID: writerID,
            writerSequence: EventSequence(rawValue: sequence),
            idempotencyKey: idempotencyKey,
            event: event(sequence: sequence, payload: payload)
        )
    }

    private func event(sequence: UInt64, payload: AgentEventPayload) -> AgentEvent {
        AgentEvent(
            header: AgentEventHeader(
                eventID: storeTagged(10_000 + seed * 10 + sequence),
                schemaVersion: context.schemaVersion,
                context: context,
                sequence: EventSequence(rawValue: sequence),
                timestamp: sequence == 1
                    ? context.acceptedAt
                    : AgentInstant(rawValue: context.acceptedAt.rawValue + Int64(sequence)),
                causationID: storeTagged(20_000 + sequence),
                correlationID: correlationID
            ),
            payload: payload
        )
    }
}

private enum AgentStoreInjectedFailure: Error {
    case stop
}

private func testSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func captureAgentStoreResult<Value: Sendable>(
    fallbackOperation: AgentStoreOperation = .saveProjectionCursor,
    _ operation: @escaping @Sendable () async throws -> Value
) async -> Result<Value, AgentStoreError> {
    do {
        return .success(try await operation())
    } catch let error as AgentStoreError {
        return .failure(error)
    } catch {
        return .failure(
            .persistenceFailure(
                operation: fallbackOperation,
                code: "unexpected_test_error"
            )
        )
    }
}

private func storeTagged<Tag: AgentIdentifierTag>(_ value: UInt64) -> AgentIdentifier<Tag> {
    let suffix = String(format: "%012llX", value)
    return AgentIdentifier(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    )
}

private func storeTaggedMessageUUID(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llX", value)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}
