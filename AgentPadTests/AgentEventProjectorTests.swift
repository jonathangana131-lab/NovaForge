import AgentDomain
import AgentStore
import CryptoKit
import Foundation
import SwiftData
import XCTest

@MainActor
final class AgentEventProjectorTests: XCTestCase {
    func testPublicRunSummaryDoesNotBreakCanonicalMaterialization()
        async throws
    {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 950)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        let publicSummary = "Local agent device verification"
        let publicProjection = SwiftDataLegacyAcceptanceProjection(
            runID: fixture.runID.rawValue,
            conversationID: fixture.conversationID.rawValue,
            projectID: fixture.context.projectID?.rawValue,
            workspaceID: fixture.context.workspaceID.rawValue,
            workspaceName: "Projector Workspace",
            requestMessageID: fixture.legacyAcceptance.requestMessageID,
            acceptedRequestText: fixture.acceptedRequestText,
            requestText: publicSummary
        )
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: publicProjection
        )
        for envelope in fixture.fullRunEnvelopes {
            _ = try await store.append(envelope)
        }

        let report = try await LegacyRunProjector(
            store: store,
            batchSize: 3
        ).projectAvailableEvents()

        XCTAssertEqual(report.endingOffset, AgentJournalOffset(rawValue: 13))
        let context = ModelContext(container)
        let run = try XCTUnwrap(
            try fetchProjectorRun(fixture.runID.rawValue, in: context)
        )
        XCTAssertEqual(run.status, .completed)
        let request = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ChatMessage>()).first {
                $0.id == publicProjection.requestMessageID
            }
        )
        XCTAssertEqual(request.content, publicSummary)
        XCTAssertEqual(request.runStatus, .completed)
    }

    func testProjectorsMaterializeFullCanonicalRunAndReplayIsIdempotent() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 1_000)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        for envelope in fixture.fullRunEnvelopes {
            _ = try await store.append(envelope)
        }

        let legacyReport = try await LegacyRunProjector(
            store: store,
            batchSize: 3
        ).projectAvailableEvents()
        let projectOSReport = try await ProjectOSProjector(
            store: store,
            batchSize: 2
        ).projectAvailableEvents()

        XCTAssertEqual(legacyReport.startingOffset, .origin)
        XCTAssertEqual(legacyReport.endingOffset, AgentJournalOffset(rawValue: 13))
        XCTAssertEqual(legacyReport.projectedEventCount, 13)
        XCTAssertEqual(legacyReport.committedBatchCount, 5)
        XCTAssertEqual(projectOSReport.endingOffset, AgentJournalOffset(rawValue: 13))
        XCTAssertEqual(projectOSReport.projectedEventCount, 13)
        XCTAssertEqual(projectOSReport.committedBatchCount, 7)

        let context = ModelContext(container)
        let run = try XCTUnwrap(try fetchProjectorRun(fixture.runID.rawValue, in: context))
        XCTAssertEqual(run.id, fixture.runID.rawValue)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.responseMessageID, fixture.assistantItem.id.rawValue)
        XCTAssertEqual(run.provider, .openAI)
        XCTAssertEqual(run.modelID, "gpt-hermes-baseline")

        let messages = try context.fetch(FetchDescriptor<ChatMessage>())
        XCTAssertEqual(messages.count, 2)
        let response = try XCTUnwrap(messages.first { $0.id == fixture.assistantItem.id.rawValue })
        XCTAssertEqual(response.role, .assistant)
        XCTAssertEqual(response.content, "I will update the file safely.")
        XCTAssertEqual(response.runID, fixture.runID.rawValue)
        XCTAssertEqual(response.runSequence, 4)
        XCTAssertTrue(messages.allSatisfy { $0.runStatus == .completed })

        let tool = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ToolRun>()).first {
                $0.id == fixture.invocation.callID.rawValue
            }
        )
        XCTAssertEqual(tool.status, .completed)
        XCTAssertTrue(tool.requiresApproval)
        XCTAssertTrue(tool.isMutating)
        XCTAssertEqual(tool.runID, fixture.runID.rawValue)
        XCTAssertEqual(tool.runStatus, .completed)
        XCTAssertTrue(tool.output.contains("updated"))

        let approval = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ApprovalRequestRecord>()).first
        )
        XCTAssertEqual(approval.statusRawValue, ApprovalRequestStatus.approved.rawValue)
        XCTAssertNotNil(approval.encodedResolution)
        XCTAssertEqual(approval.runIDString, fixture.runID.description)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()),
            2
        )
        let artifacts = try context.fetch(FetchDescriptor<AgentArtifactProjectionRecord>())
        XCTAssertEqual(artifacts.count, 2)
        let resultArtifact = try XCTUnwrap(
            artifacts.first { $0.artifactIDString == fixture.toolResultArtifact.artifactID.description }
        )
        XCTAssertEqual(resultArtifact.toolCallIDString, fixture.invocation.callID.description)
        XCTAssertEqual(resultArtifact.sourceKind, "toolResult")
        XCTAssertEqual(resultArtifact.mediaType, fixture.toolResultArtifact.mediaType)
        XCTAssertEqual(resultArtifact.displayName, fixture.toolResultArtifact.displayName)
        XCTAssertEqual(resultArtifact.artifactDigest, fixture.toolResultArtifact.contentDigest)
        XCTAssertFalse(resultArtifact.encodedArtifactSHA256.isEmpty)
        let capturedArtifact = try XCTUnwrap(
            artifacts.first { $0.artifactIDString == fixture.capturedArtifact.artifactID.description }
        )
        XCTAssertNil(capturedArtifact.toolCallIDString)
        XCTAssertEqual(capturedArtifact.sourceKind, "artifactCaptured")
        XCTAssertEqual(capturedArtifact.artifactDigest, fixture.capturedArtifact.contentDigest)

        let projectOS = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ProjectOSRun>()).first {
                $0.id == fixture.runID.rawValue
            }
        )
        XCTAssertEqual(projectOS.id, fixture.runID.rawValue)
        XCTAssertEqual(projectOS.project?.id, fixture.projectID.rawValue)
        XCTAssertEqual(projectOS.sourceConversationIDString, fixture.conversationID.rawValue.uuidString)
        XCTAssertEqual(projectOS.status, .completed)
        XCTAssertEqual(projectOS.proofSummary, "Verified complete")
        XCTAssertEqual(projectOS.progressEventCount, 12)

        let legacyReplay = try await LegacyRunProjector(store: store).projectAvailableEvents()
        let projectOSReplay = try await ProjectOSProjector(store: store).projectAvailableEvents()
        XCTAssertEqual(legacyReplay.projectedEventCount, 0)
        XCTAssertEqual(projectOSReplay.projectedEventCount, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolRun>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ApprovalRequestRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectOSRun>()), 1)
    }

    func testProjectorsAdvanceEvidenceRevisionSeparatelyAtSameHighWater() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 1_500)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        _ = try await store.append(fixture.startedEnvelope)

        let legacy = try await LegacyRunProjector(store: store, batchSize: 64)
            .projectAvailableEvents()
        XCTAssertEqual(legacy.committedBatchCount, 1)
        XCTAssertEqual(
            try materializedEvidenceRevision(
                for: fixture.projectID.rawValue,
                in: container
            ),
            1
        )

        let projectOS = try await ProjectOSProjector(store: store, batchSize: 64)
            .projectAvailableEvents()
        XCTAssertEqual(projectOS.committedBatchCount, 1)
        XCTAssertEqual(projectOS.endingOffset, legacy.endingOffset)
        XCTAssertEqual(
            try materializedEvidenceRevision(
                for: fixture.projectID.rawValue,
                in: container
            ),
            2
        )

        let legacyNoOp = try await LegacyRunProjector(store: store)
            .projectAvailableEvents()
        let projectOSNoOp = try await ProjectOSProjector(store: store)
            .projectAvailableEvents()
        XCTAssertEqual(legacyNoOp.projectedEventCount, 0)
        XCTAssertEqual(legacyNoOp.committedBatchCount, 0)
        XCTAssertEqual(projectOSNoOp.projectedEventCount, 0)
        XCTAssertEqual(projectOSNoOp.committedBatchCount, 0)
        XCTAssertEqual(
            try materializedEvidenceRevision(
                for: fixture.projectID.rawValue,
                in: container
            ),
            2
        )
    }

    func testEvidenceRevisionInvalidatesSnapshotWhenCanonicalTimestampsMatch() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 1_550, sameTimestamp: true)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        _ = try await LegacyRunProjector(store: store).projectAvailableEvents()
        _ = try await ProjectOSProjector(store: store).projectAvailableEvents()

        func snapshotKey() throws -> ProjectDashboardSnapshotKey {
            let context = ModelContext(container)
            let project = try XCTUnwrap(
                context.fetch(FetchDescriptor<Project>()).first {
                    $0.id == fixture.projectID.rawValue
                }
            )
            let activeRun = try context.fetch(FetchDescriptor<ProjectOSRun>()).first {
                $0.id == fixture.runID.rawValue
            }
            return ProjectDashboardSnapshotKey(
                projectID: project.id,
                materializedEvidenceRevision: try materializedEvidenceRevision(
                    for: project.id,
                    in: container
                ) ?? 0,
                projectUpdatedAt: project.updatedAt,
                projectLastActivityAt: project.lastActivityAt,
                activeProjectOSRunID: activeRun?.id,
                activeProjectOSRunUpdatedAt: activeRun?.updatedAt,
                activeProjectOSRunStatusRawValue: activeRun?.statusRawValue
            )
        }

        let before = try snapshotKey()
        XCTAssertEqual(
            fixture.acceptanceEvent.header.timestamp,
            fixture.startedEnvelope.event.header.timestamp
        )
        _ = try await store.append(fixture.startedEnvelope)
        _ = try await LegacyRunProjector(store: store).projectAvailableEvents()
        let after = try snapshotKey()

        XCTAssertEqual(
            after.materializedEvidenceRevision,
            before.materializedEvidenceRevision + 1
        )
        XCTAssertEqual(after.projectUpdatedAt, before.projectUpdatedAt)
        XCTAssertEqual(after.projectLastActivityAt, before.projectLastActivityAt)
        XCTAssertEqual(after.activeProjectOSRunUpdatedAt, before.activeProjectOSRunUpdatedAt)
        XCTAssertEqual(
            after.activeProjectOSRunStatusRawValue,
            before.activeProjectOSRunStatusRawValue
        )
        XCTAssertNotEqual(after, before)
    }

    func testProjectionBatchAdvancesEachScopedProjectOnceAndSkipsGeneral() async throws {
        let container = try makeProjectorContainer()
        let first = ProjectorFixture(seed: 1_600)
        let sameProject = ProjectorFixture(
            seed: 1_700,
            conversationID: first.conversationID,
            projectID: first.projectID
        )
        let second = ProjectorFixture(seed: 1_800)
        let general = ProjectorFixture(seed: 1_900, hasProject: false)
        try seedProjectorLegacyContext(for: first, in: container)
        try seedProjectorLegacyContext(for: second, in: container)
        try seedProjectorLegacyContext(for: general, in: container)
        let unrelatedProjectID = projectorUUID(1_999)
        let unrelatedContext = ModelContext(container)
        let unrelatedProject = Project(
            name: "Unrelated",
            workspaceName: "Projector Workspace"
        )
        unrelatedProject.id = unrelatedProjectID
        unrelatedContext.insert(unrelatedProject)
        try unrelatedContext.save()

        let store = SwiftDataAgentStore(container: container)
        for fixture in [first, sameProject, second, general] {
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: fixture.legacyAcceptance
            )
        }

        let validated = try await store.validatedProjectionBatch(
            after: .origin,
            limit: 64
        )
        let legacyPlan = try LegacyRunProjector.plan(
            forRunPrefixes: validated.runPrefixes,
            canonicalScopes: validated.canonicalAcceptanceScopes
        )
        let projectOSPlan = try ProjectOSProjector.plan(
            forRunPrefixes: validated.runPrefixes,
            canonicalScopes: validated.canonicalAcceptanceScopes
        )
        let expectedProjectIDs = [
            first.projectID.rawValue,
            second.projectID.rawValue
        ].sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(legacyPlan.evidenceProjectIDs, expectedProjectIDs)
        XCTAssertEqual(projectOSPlan.evidenceProjectIDs, expectedProjectIDs)

        let report = try await LegacyRunProjector(store: store, batchSize: 64)
            .projectAvailableEvents()
        XCTAssertEqual(report.projectedEventCount, 4)
        XCTAssertEqual(report.committedBatchCount, 1)
        let revisions = try materializedEvidenceRevisions(in: container)
        XCTAssertEqual(
            revisions,
            Dictionary(uniqueKeysWithValues: expectedProjectIDs.map { ($0, Int64(1)) })
        )
        XCTAssertNil(revisions[unrelatedProjectID])
    }

    func testProjectOSProjectionSaveFailureRollsBackViewAndCursor() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 2_000)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let cleanStore = SwiftDataAgentStore(container: container)
        _ = try await cleanStore.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        _ = try await cleanStore.append(fixture.startedEnvelope)

        let failingStore = SwiftDataAgentStore(
            container: container,
            failureInjector: { boundary in
                if case .beforeSave(.saveProjectionCursor) = boundary {
                    throw ProjectorInjectedFailure.stop
                }
            }
        )
        do {
            _ = try await ProjectOSProjector(store: failingStore)
                .projectAvailableEvents()
            XCTFail("Injected projector save unexpectedly committed")
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
        XCTAssertEqual(try failedContext.fetchCount(FetchDescriptor<ProjectOSRun>()), 0)
        let failedCursor = try await failingStore.loadCursor(
            for: ProjectOSProjector.projectionID
        )
        XCTAssertNil(failedCursor)

        let report = try await ProjectOSProjector(store: cleanStore)
            .projectAvailableEvents()
        XCTAssertEqual(report.projectedEventCount, 2)
        let recoveredContext = ModelContext(container)
        let recovered = try XCTUnwrap(
            try recoveredContext.fetch(FetchDescriptor<ProjectOSRun>()).first
        )
        XCTAssertEqual(recovered.id, fixture.runID.rawValue)
        XCTAssertEqual(recovered.status, .running)
    }

    func testStaleConcurrentLegacyProjectionLosesStrictCursorCAS() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 3_000)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let firstStore = SwiftDataAgentStore(container: container)
        let secondStore = SwiftDataAgentStore(container: container)
        _ = try await firstStore.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        _ = try await firstStore.append(fixture.startedEnvelope)
        let batch = try await firstStore.projectionBatch(after: .origin, limit: 8)
        let plan = try LegacyRunProjector.plan(for: batch.records)
        let cursor = AgentProjectionCursor(
            projectionID: LegacyRunProjector.projectionID,
            throughOffset: batch.throughOffset,
            updatedAt: try XCTUnwrap(batch.records.last).committedAt
        )

        async let first = captureProjectorStoreResult {
            try await firstStore.commitProjection(
                plan,
                cursor: cursor,
                expectedPreviousOffset: .origin
            )
        }
        async let second = captureProjectorStoreResult {
            try await secondStore.commitProjection(
                plan,
                cursor: cursor,
                expectedPreviousOffset: .origin
            )
        }
        let pair = await (first, second)
        let results = [pair.0, pair.1]
        XCTAssertEqual(results.compactMap { try? $0.get() }.count, 1)
        let failure = try XCTUnwrap(results.compactMap { result -> AgentStoreError? in
            guard case let .failure(error) = result else { return nil }
            return error
        }.first)
        XCTAssertEqual(
            failure,
            .cursorConflict(
                projectionID: LegacyRunProjector.projectionID,
                expected: .origin,
                actual: cursor.throughOffset
            )
        )
        let run = try XCTUnwrap(
            try fetchProjectorRun(
                fixture.runID.rawValue,
                in: ModelContext(container)
            )
        )
        XCTAssertEqual(run.status, .running)
    }

    func testGlobalProjectionBatchKeepsTwoRunsExactlySeparated() async throws {
        let container = try makeProjectorContainer()
        let first = ProjectorFixture(seed: 4_000)
        let second = ProjectorFixture(seed: 5_000)
        try seedProjectorLegacyContext(for: first, in: container)
        try seedProjectorLegacyContext(for: second, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(first.acceptance, legacyProjection: first.legacyAcceptance)
        _ = try await store.accept(second.acceptance, legacyProjection: second.legacyAcceptance)
        _ = try await store.append(first.startedEnvelope)
        _ = try await store.append(second.startedEnvelope)

        let legacy = try await LegacyRunProjector(store: store, batchSize: 1)
            .projectAvailableEvents()
        let projectOS = try await ProjectOSProjector(store: store, batchSize: 3)
            .projectAvailableEvents()

        XCTAssertEqual(legacy.projectedEventCount, 4)
        XCTAssertEqual(projectOS.projectedEventCount, 4)
        XCTAssertEqual(legacy.endingOffset, AgentJournalOffset(rawValue: 4))
        XCTAssertEqual(projectOS.endingOffset, AgentJournalOffset(rawValue: 4))
        let context = ModelContext(container)
        let runs = try context.fetch(FetchDescriptor<AgentRunRecord>())
        XCTAssertEqual(Set(runs.map(\.id)), Set([first.runID.rawValue, second.runID.rawValue]))
        XCTAssertTrue(runs.allSatisfy { $0.status == .running })
        let projectOSRuns = try context.fetch(FetchDescriptor<ProjectOSRun>())
        XCTAssertEqual(
            Set(projectOSRuns.map(\.id)),
            Set([first.runID.rawValue, second.runID.rawValue])
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: projectOSRuns.map { ($0.id, $0.project?.id) }),
            [
                first.runID.rawValue: first.projectID.rawValue,
                second.runID.rawValue: second.projectID.rawValue
            ]
        )
    }

    func testMissingFutureAcceptanceBaselineRollsBackLegacyCursor() async throws {
        let container = try makeProjectorContainer()
        let first = ProjectorFixture(seed: 5_200)
        let second = ProjectorFixture(seed: 5_300)
        try seedProjectorLegacyContext(for: first, in: container)
        try seedProjectorLegacyContext(for: second, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(first.acceptance, legacyProjection: first.legacyAcceptance)
        _ = try await store.accept(second.acceptance, legacyProjection: second.legacyAcceptance)

        let corruptionContext = ModelContext(container)
        let missingRequest = try XCTUnwrap(
            corruptionContext.fetch(FetchDescriptor<ChatMessage>()).first {
                $0.id == second.legacyAcceptance.requestMessageID
            }
        )
        missingRequest.conversation?.messages.removeAll { $0.id == missingRequest.id }
        corruptionContext.delete(missingRequest)
        try corruptionContext.save()

        let projectionID = AgentProjectionID(rawValue: "legacy-missing-future-baseline")
        do {
            _ = try await LegacyRunProjector(
                store: store,
                batchSize: 1,
                projectionID: projectionID
            ).projectAvailableEvents()
            XCTFail("Missing future acceptance baseline unexpectedly projected")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "legacy_acceptance_projection_mismatch"
                )
            )
        }
        let missingFutureCursor = try await store.loadCursor(for: projectionID)
        XCTAssertNil(missingFutureCursor)
        let verification = ModelContext(container)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<AgentRunRecord>()), 2)
        XCTAssertEqual(try verification.fetchCount(FetchDescriptor<ChatMessage>()), 1)
    }

    func testProjectOSUpdateCannotSynthesizeRunBeforeAcceptanceProjection() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 6_000)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        let startedCommit = try await store.append(fixture.startedEnvelope)
        let plan = SwiftDataAgentProjectionPlan(mutations: [
            .updateProjectOSRun(
                SwiftDataProjectOSRunProjection(
                    runID: fixture.runID.rawValue,
                    projectID: fixture.projectID.rawValue,
                    status: .running,
                    currentAction: "Should not synthesize",
                    latestEventTitle: "Run started",
                    occurredAt: startedCommit.record.event.header.timestamp
                )
            )
        ])
        let cursor = AgentProjectionCursor(
            projectionID: ProjectOSProjector.projectionID,
            throughOffset: startedCommit.record.offset,
            updatedAt: startedCommit.record.committedAt
        )

        do {
            _ = try await store.commitProjection(
                plan,
                cursor: cursor,
                expectedPreviousOffset: .origin
            )
            XCTFail("ProjectOS update unexpectedly synthesized an unaccepted projection row")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "projectos_run_missing"
                )
            )
        }
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectOSRun>()), 0)
        let missingCursor = try await store.loadCursor(
            for: ProjectOSProjector.projectionID
        )
        XCTAssertNil(missingCursor)
    }

    func testCursorResetAndProjectionVersionBumpRebuildEveryPrefixAbsolutely() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 7_000)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        for envelope in fixture.fullRunEnvelopes {
            _ = try await store.append(envelope)
        }
        _ = try await LegacyRunProjector(store: store, batchSize: 64)
            .projectAvailableEvents()
        _ = try await ProjectOSProjector(store: store, batchSize: 64)
            .projectAvailableEvents()
        let baseline = try materializedProjectionDigest(in: container)

        let resetLegacyID = AgentProjectionID(
            rawValue: "legacy-run-projector:prefix-reset-test"
        )
        let firstLegacyBatch = try await store.validatedProjectionBatch(
            after: .origin,
            limit: 1
        )
        let firstLegacyPlan = try LegacyRunProjector.plan(
            forRunPrefixes: firstLegacyBatch.runPrefixes,
            canonicalScopes: firstLegacyBatch.canonicalAcceptanceScopes
        )
        _ = try await store.commitProjection(
            firstLegacyPlan,
            cursor: AgentProjectionCursor(
                projectionID: resetLegacyID,
                throughOffset: firstLegacyBatch.batch.throughOffset,
                updatedAt: try XCTUnwrap(firstLegacyBatch.batch.records.last).committedAt
            ),
            expectedPreviousOffset: .origin
        )
        let prefixContext = ModelContext(container)
        let prefixRun = try XCTUnwrap(
            try fetchProjectorRun(fixture.runID.rawValue, in: prefixContext)
        )
        XCTAssertEqual(prefixRun.status, .queued)
        XCTAssertNil(prefixRun.provider)
        XCTAssertNil(prefixRun.modelID)
        XCTAssertNil(prefixRun.responseMessageID)
        XCTAssertEqual(try prefixContext.fetchCount(FetchDescriptor<ChatMessage>()), 1)
        XCTAssertEqual(try prefixContext.fetchCount(FetchDescriptor<ToolRun>()), 0)
        XCTAssertEqual(try prefixContext.fetchCount(FetchDescriptor<ApprovalRequestRecord>()), 0)
        XCTAssertEqual(try prefixContext.fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()), 0)
        XCTAssertEqual(try prefixContext.fetchCount(FetchDescriptor<AgentArtifactProjectionRecord>()), 0)

        let resetProjectOSID = AgentProjectionID(
            rawValue: "projectos-projector:prefix-reset-test"
        )
        let firstProjectOSPlan = try ProjectOSProjector.plan(
            forRunPrefixes: firstLegacyBatch.runPrefixes,
            canonicalScopes: firstLegacyBatch.canonicalAcceptanceScopes
        )
        _ = try await store.commitProjection(
            firstProjectOSPlan,
            cursor: AgentProjectionCursor(
                projectionID: resetProjectOSID,
                throughOffset: firstLegacyBatch.batch.throughOffset,
                updatedAt: try XCTUnwrap(firstLegacyBatch.batch.records.last).committedAt
            ),
            expectedPreviousOffset: .origin
        )
        let projectOSPrefix = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<ProjectOSRun>()).first
        )
        XCTAssertEqual(projectOSPrefix.status, .planning)
        XCTAssertEqual(projectOSPrefix.progressEventCount, 0)
        XCTAssertEqual(projectOSPrefix.latestEventTitle, "Run accepted")

        _ = try await LegacyRunProjector(
            store: store,
            batchSize: 1,
            projectionID: resetLegacyID
        ).projectAvailableEvents()
        _ = try await ProjectOSProjector(
            store: store,
            batchSize: 1,
            projectionID: resetProjectOSID
        ).projectAvailableEvents()
        XCTAssertEqual(try materializedProjectionDigest(in: container), baseline)

        try deleteProjectionCursors(
            [LegacyRunProjector.projectionID, ProjectOSProjector.projectionID],
            in: container
        )
        _ = try await LegacyRunProjector(store: store, batchSize: 2)
            .projectAvailableEvents()
        _ = try await ProjectOSProjector(store: store, batchSize: 3)
            .projectAvailableEvents()
        XCTAssertEqual(try materializedProjectionDigest(in: container), baseline)

        let driftContext = ModelContext(container)
        let driftedApproval = try XCTUnwrap(
            driftContext.fetch(FetchDescriptor<ApprovalRequestRecord>()).first
        )
        driftedApproval.workspaceIDString = "drifted-workspace"
        driftedApproval.requestedEventIDString = "drifted-request-event"
        driftedApproval.resolvedEventIDString = "drifted-resolution-event"
        driftedApproval.requestedAtMilliseconds = -1
        driftedApproval.resolvedAtMilliseconds = -1
        driftedApproval.updatedAt = .distantPast
        let driftedEvidence = try XCTUnwrap(
            driftContext.fetch(FetchDescriptor<ToolEffectEvidenceRecord>()).first
        )
        driftedEvidence.createdAt = .distantPast
        let driftedArtifact = try XCTUnwrap(
            driftContext.fetch(FetchDescriptor<AgentArtifactProjectionRecord>()).first
        )
        driftedArtifact.createdAt = .distantPast
        try driftContext.save()
        XCTAssertNotEqual(try materializedProjectionDigest(in: container), baseline)

        _ = try await LegacyRunProjector(
            store: store,
            batchSize: 4,
            projectionID: AgentProjectionID(rawValue: "legacy-run-projector:v2-test")
        ).projectAvailableEvents()
        _ = try await ProjectOSProjector(
            store: store,
            batchSize: 5,
            projectionID: AgentProjectionID(rawValue: "projectos-projector:v2-test")
        ).projectAvailableEvents()
        XCTAssertEqual(try materializedProjectionDigest(in: container), baseline)
    }

    func testSharedConversationProjectionIsIndependentOfRunOrderAndBatchSize() async throws {
        let container = try makeProjectorContainer()
        let first = ProjectorFixture(
            seed: 9_000,
            acceptedAt: AgentInstant(rawValue: 1_950_000_000_100)
        )
        let second = ProjectorFixture(
            seed: 8_000,
            acceptedAt: AgentInstant(rawValue: 1_950_000_000_500),
            conversationID: first.conversationID,
            projectID: first.projectID
        )
        try seedProjectorLegacyContext(for: first, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(first.acceptance, legacyProjection: first.legacyAcceptance)
        _ = try await store.accept(second.acceptance, legacyProjection: second.legacyAcceptance)
        for envelope in first.fullRunEnvelopes { _ = try await store.append(envelope) }
        for envelope in second.fullRunEnvelopes { _ = try await store.append(envelope) }

        _ = try await LegacyRunProjector(store: store, batchSize: 128)
            .projectAvailableEvents()
        _ = try await ProjectOSProjector(store: store, batchSize: 128)
            .projectAvailableEvents()
        let largeBatchDigest = try materializedProjectionDigest(in: container)

        _ = try await LegacyRunProjector(
            store: store,
            batchSize: 1,
            projectionID: AgentProjectionID(rawValue: "legacy-shared-conversation:v2")
        ).projectAvailableEvents()
        _ = try await ProjectOSProjector(
            store: store,
            batchSize: 1,
            projectionID: AgentProjectionID(rawValue: "projectos-shared-conversation:v2")
        ).projectAvailableEvents()
        XCTAssertEqual(try materializedProjectionDigest(in: container), largeBatchDigest)
        let conversation = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<Conversation>()).first
        )
        XCTAssertEqual(conversation.messageCount, 4)
        XCTAssertTrue(conversation.hasUserMessages)
        XCTAssertEqual(
            conversation.updatedAt,
            AgentInstant(
                rawValue: second.context.acceptedAt.rawValue + 13
            ).date
        )
    }

    func testEvidenceAndArtifactIdentityConflictsRollBackRowsAndCursor() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 10_000)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        let accepted = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        let eventID = projectorUUID(10_900)
        let evidenceA = ToolEvidence(
            kind: "workspace-diff",
            digest: "declared-same-digest",
            metadata: .object(["path": .string("A.swift")])
        )
        let evidenceB = ToolEvidence(
            kind: "workspace-diff",
            digest: "declared-same-digest",
            metadata: .object(["path": .string("B.swift")])
        )
        let conflictingEvidence = makeLegacySnapshot(
            fixture: fixture,
            evidence: [
                SwiftDataCanonicalEvidenceSnapshot(
                    eventID: eventID,
                    callID: fixture.invocation.callID.rawValue,
                    occurredAt: fixture.context.acceptedAt,
                    evidence: evidenceA
                ),
                SwiftDataCanonicalEvidenceSnapshot(
                    eventID: eventID,
                    callID: fixture.invocation.callID.rawValue,
                    occurredAt: fixture.context.acceptedAt,
                    evidence: evidenceB
                )
            ]
        )
        let evidenceProjectionID = AgentProjectionID(rawValue: "conflicting-evidence")
        do {
            _ = try await store.commitProjection(
                SwiftDataAgentProjectionPlan(mutations: [
                    .replaceLegacyRun(conflictingEvidence)
                ]),
                cursor: AgentProjectionCursor(
                    projectionID: evidenceProjectionID,
                    throughOffset: accepted.record.offset,
                    updatedAt: accepted.record.committedAt
                ),
                expectedPreviousOffset: .origin
            )
            XCTFail("Conflicting evidence identity unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "projection_evidence_conflict"
                )
            )
        }
        let conflictingEvidenceCursor = try await store.loadCursor(
            for: evidenceProjectionID
        )
        XCTAssertNil(conflictingEvidenceCursor)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()),
            0
        )

        let exactEvidence = SwiftDataCanonicalEvidenceSnapshot(
            eventID: eventID,
            callID: fixture.invocation.callID.rawValue,
            occurredAt: fixture.context.acceptedAt,
            evidence: evidenceA
        )
        let deduplicatingEvidenceID = AgentProjectionID(rawValue: "duplicate-evidence")
        _ = try await store.commitProjection(
            SwiftDataAgentProjectionPlan(mutations: [
                .replaceLegacyRun(
                    makeLegacySnapshot(
                        fixture: fixture,
                        evidence: [exactEvidence, exactEvidence]
                    )
                )
            ]),
            cursor: AgentProjectionCursor(
                projectionID: deduplicatingEvidenceID,
                throughOffset: accepted.record.offset,
                updatedAt: accepted.record.committedAt
            ),
            expectedPreviousOffset: .origin
        )
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()),
            1
        )

        let upperDigest = ToolEvidence(
            kind: "case-sensitive",
            digest: "ABC",
            metadata: .object(["variant": .string("upper")])
        )
        let lowerDigest = ToolEvidence(
            kind: "case-sensitive",
            digest: "abc",
            metadata: .object(["variant": .string("lower")])
        )
        let caseSensitiveEvidence = makeLegacySnapshot(
            fixture: fixture,
            evidence: [upperDigest, lowerDigest].map {
                SwiftDataCanonicalEvidenceSnapshot(
                    eventID: eventID,
                    callID: fixture.invocation.callID.rawValue,
                    occurredAt: fixture.context.acceptedAt,
                    evidence: $0
                )
            }
        )
        _ = try await store.commitProjection(
            SwiftDataAgentProjectionPlan(mutations: [
                .replaceLegacyRun(caseSensitiveEvidence)
            ]),
            cursor: AgentProjectionCursor(
                projectionID: AgentProjectionID(
                    rawValue: "case-sensitive-declared-evidence"
                ),
                throughOffset: accepted.record.offset,
                updatedAt: accepted.record.committedAt
            ),
            expectedPreviousOffset: .origin
        )
        let caseSensitiveRows = try ModelContext(container).fetch(
            FetchDescriptor<ToolEffectEvidenceRecord>()
        )
        XCTAssertEqual(Set(caseSensitiveRows.map(\.evidenceDigest)), ["ABC", "abc"])
        XCTAssertEqual(Set(caseSensitiveRows.map(\.evidenceKey)).count, 2)

        let artifactA = fixture.toolResultArtifact
        let artifactB = ArtifactReference(
            artifactID: artifactA.artifactID,
            mediaType: artifactA.mediaType,
            contentDigest: artifactA.contentDigest,
            displayName: "conflicting-name.json"
        )
        let conflictingArtifacts = makeLegacySnapshot(
            fixture: fixture,
            artifacts: [
                SwiftDataCanonicalArtifactSnapshot(
                    eventID: eventID,
                    callID: fixture.invocation.callID.rawValue,
                    occurredAt: fixture.context.acceptedAt,
                    source: .toolResult,
                    artifact: artifactA
                ),
                SwiftDataCanonicalArtifactSnapshot(
                    eventID: eventID,
                    callID: fixture.invocation.callID.rawValue,
                    occurredAt: fixture.context.acceptedAt,
                    source: .toolResult,
                    artifact: artifactB
                )
            ]
        )
        let artifactProjectionID = AgentProjectionID(rawValue: "conflicting-artifact")
        do {
            _ = try await store.commitProjection(
                SwiftDataAgentProjectionPlan(mutations: [
                    .replaceLegacyRun(conflictingArtifacts)
                ]),
                cursor: AgentProjectionCursor(
                    projectionID: artifactProjectionID,
                    throughOffset: accepted.record.offset,
                    updatedAt: accepted.record.committedAt
                ),
                expectedPreviousOffset: .origin
            )
            XCTFail("Conflicting artifact identity unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "projection_artifact_conflict"
                )
            )
        }
        let conflictingArtifactCursor = try await store.loadCursor(
            for: artifactProjectionID
        )
        XCTAssertNil(conflictingArtifactCursor)
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<AgentArtifactProjectionRecord>()),
            0
        )
        XCTAssertEqual(
            try ModelContext(container).fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()),
            2
        )
    }

    func testDuplicateLegacyRunMessageToolAndProjectOSIdentitiesFailTyped() async throws {
        do {
            let container = try makeProjectorContainer()
            let fixture = ProjectorFixture(seed: 11_000)
            try seedProjectorLegacyContext(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: fixture.legacyAcceptance
            )
            let context = ModelContext(container)
            context.insert(
                AgentRunRecord(
                    id: fixture.runID.rawValue,
                    conversationID: fixture.conversationID.rawValue,
                    projectID: fixture.projectID.rawValue,
                    workspaceID: fixture.context.workspaceID.rawValue,
                    workspaceName: "Projector Workspace",
                    requestMessageID: projectorUUID(11_999),
                    now: fixture.context.acceptedAt.date
                )
            )
            try context.save()
            do {
                _ = try await LegacyRunProjector(store: store).projectAvailableEvents()
                XCTFail("Duplicate legacy run identity unexpectedly projected")
            } catch let error as SwiftDataAgentStoreIntegrityError {
                XCTAssertEqual(
                    error,
                    .duplicateLegacyIdentity(kind: .run, id: fixture.runID.rawValue)
                )
            }
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<ProjectionCursorRecord>()),
                0
            )
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentRunRecord>()), 2)
        }

        do {
            let container = try makeProjectorContainer()
            let fixture = ProjectorFixture(seed: 12_000)
            try seedProjectorLegacyContext(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: fixture.legacyAcceptance
            )
            let context = ModelContext(container)
            let conversation = try XCTUnwrap(
                context.fetch(FetchDescriptor<Conversation>()).first
            )
            let duplicate = ChatMessage(
                id: fixture.legacyAcceptance.requestMessageID,
                role: .user,
                content: "Build safely",
                conversation: conversation,
                runID: fixture.runID.rawValue,
                runSequence: 0,
                runStatus: .queued
            )
            context.insert(duplicate)
            conversation.messages.append(duplicate)
            try context.save()
            do {
                _ = try await LegacyRunProjector(store: store).projectAvailableEvents()
                XCTFail("Duplicate legacy message identity unexpectedly projected")
            } catch let error as SwiftDataAgentStoreIntegrityError {
                XCTAssertEqual(
                    error,
                    .duplicateLegacyIdentity(
                        kind: .message,
                        id: fixture.legacyAcceptance.requestMessageID
                    )
                )
            }
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<ProjectionCursorRecord>()),
                0
            )
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 2)
        }

        do {
            let container = try makeProjectorContainer()
            let fixture = ProjectorFixture(seed: 12_200)
            try seedProjectorLegacyContext(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: fixture.legacyAcceptance
            )
            let context = ModelContext(container)
            let duplicate = Conversation(title: "Duplicate identity")
            duplicate.id = fixture.conversationID.rawValue
            context.insert(duplicate)
            try context.save()
            do {
                _ = try await LegacyRunProjector(store: store).projectAvailableEvents()
                XCTFail("Duplicate conversation identity unexpectedly projected")
            } catch let error as SwiftDataAgentStoreIntegrityError {
                XCTAssertEqual(
                    error,
                    .duplicateLegacyIdentity(
                        kind: .conversation,
                        id: fixture.conversationID.rawValue
                    )
                )
            }
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<ProjectionCursorRecord>()),
                0
            )
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 2)
        }

        do {
            let container = try makeProjectorContainer()
            let fixture = ProjectorFixture(seed: 12_400)
            try seedProjectorLegacyContext(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: fixture.legacyAcceptance
            )
            let context = ModelContext(container)
            let duplicate = Project(
                name: "Duplicate identity",
                workspaceName: "Projector Workspace"
            )
            duplicate.id = fixture.projectID.rawValue
            context.insert(duplicate)
            try context.save()
            do {
                _ = try await LegacyRunProjector(store: store).projectAvailableEvents()
                XCTFail("Duplicate project identity unexpectedly projected")
            } catch let error as SwiftDataAgentStoreIntegrityError {
                XCTAssertEqual(
                    error,
                    .duplicateLegacyIdentity(
                        kind: .project,
                        id: fixture.projectID.rawValue
                    )
                )
            }
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<ProjectionCursorRecord>()),
                0
            )
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 2)
        }

        do {
            let container = try makeProjectorContainer()
            let fixture = ProjectorFixture(seed: 13_000)
            try seedProjectorLegacyContext(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: fixture.legacyAcceptance
            )
            for envelope in fixture.fullRunEnvelopes {
                _ = try await store.append(envelope)
            }
            let context = ModelContext(container)
            let project = try XCTUnwrap(context.fetch(FetchDescriptor<Project>()).first)
            for _ in 0..<2 {
                let duplicate = ToolRun(
                    name: fixture.invocation.tool.name,
                    argumentsJSON: "{}",
                    status: .approved,
                    project: project,
                    runID: fixture.runID.rawValue,
                    runSequence: 5,
                    runStatus: .running
                )
                duplicate.id = fixture.invocation.callID.rawValue
                context.insert(duplicate)
                project.toolRuns.append(duplicate)
            }
            try context.save()
            do {
                _ = try await LegacyRunProjector(store: store).projectAvailableEvents()
                XCTFail("Duplicate legacy tool identity unexpectedly projected")
            } catch let error as SwiftDataAgentStoreIntegrityError {
                XCTAssertEqual(
                    error,
                    .duplicateLegacyIdentity(
                        kind: .tool,
                        id: fixture.invocation.callID.rawValue
                    )
                )
            }
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<ProjectionCursorRecord>()),
                0
            )
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolRun>()), 2)
        }

        do {
            let container = try makeProjectorContainer()
            let fixture = ProjectorFixture(seed: 14_000)
            try seedProjectorLegacyContext(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: fixture.legacyAcceptance
            )
            let context = ModelContext(container)
            let project = try XCTUnwrap(context.fetch(FetchDescriptor<Project>()).first)
            for _ in 0..<2 {
                let duplicate = ProjectOSRun(
                    project: project,
                    projectName: project.name,
                    mission: "Duplicate",
                    sourceConversationID: fixture.conversationID.rawValue,
                    now: fixture.context.acceptedAt.date
                )
                duplicate.id = fixture.runID.rawValue
                context.insert(duplicate)
                project.projectOSRuns.append(duplicate)
            }
            try context.save()
            do {
                _ = try await ProjectOSProjector(store: store).projectAvailableEvents()
                XCTFail("Duplicate ProjectOS identity unexpectedly projected")
            } catch let error as SwiftDataAgentStoreIntegrityError {
                XCTAssertEqual(
                    error,
                    .duplicateLegacyIdentity(
                        kind: .projectOSRun,
                        id: fixture.runID.rawValue
                    )
                )
            }
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<ProjectionCursorRecord>()),
                0
            )
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectOSRun>()), 2)
        }
    }

    func testProjectOSPruneBindingCollisionRollsBackCursorAndPreservesRow() async throws {
        let container = try makeProjectorContainer()
        let first = ProjectorFixture(seed: 15_000)
        let second = ProjectorFixture(seed: 16_000)
        try seedProjectorLegacyContext(for: first, in: container)
        try seedProjectorLegacyContext(for: second, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(first.acceptance, legacyProjection: first.legacyAcceptance)
        _ = try await store.accept(second.acceptance, legacyProjection: second.legacyAcceptance)

        let context = ModelContext(container)
        let wrongProject = try XCTUnwrap(
            context.fetch(FetchDescriptor<Project>()).first {
                $0.id == first.projectID.rawValue
            }
        )
        let collision = ProjectOSRun(
            project: wrongProject,
            projectName: wrongProject.name,
            mission: "Unrelated V1 row",
            sourceConversationID: first.conversationID.rawValue,
            now: first.context.acceptedAt.date
        )
        collision.id = second.runID.rawValue
        context.insert(collision)
        wrongProject.projectOSRuns.append(collision)
        try context.save()

        let projectionID = AgentProjectionID(rawValue: "projectos-prune-collision")
        do {
            _ = try await ProjectOSProjector(
                store: store,
                batchSize: 1,
                projectionID: projectionID
            ).projectAvailableEvents()
            XCTFail("ProjectOS ownership collision was silently pruned")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "projectos_acceptance_conflict"
                )
            )
        }
        let pruneCollisionCursor = try await store.loadCursor(for: projectionID)
        XCTAssertNil(pruneCollisionCursor)
        let verification = ModelContext(container)
        let preserved = try XCTUnwrap(
            verification.fetch(FetchDescriptor<ProjectOSRun>()).first {
                $0.id == second.runID.rawValue
            }
        )
        XCTAssertEqual(preserved.mission, "Unrelated V1 row")
        XCTAssertEqual(preserved.project?.id, first.projectID.rawValue)
    }

    func testCrossRunArtifactKeyCollisionRollsBackWithoutUniqueUpsert() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 17_000)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        let accepted = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        let eventID = projectorUUID(17_900)
        let artifact = fixture.toolResultArtifact
        let encoded = try deterministicProjectorData(artifact)
        let wrongRunID = projectorUUID(17_999)
        let context = ModelContext(container)
        context.insert(
            AgentArtifactProjectionRecord(
                artifactIDString: artifact.artifactID.description,
                eventIDString: eventID.uuidString.lowercased(),
                runIDString: wrongRunID.uuidString.lowercased(),
                projectIDString: nil,
                workspaceIDString: fixture.context.workspaceID.description,
                toolCallIDString: nil,
                sourceKind: "artifactCaptured",
                mediaType: artifact.mediaType,
                displayName: artifact.displayName,
                encodingName: "agent-artifact-reference-json",
                encodingVersion: 1,
                encodedArtifact: encoded,
                artifactDigest: artifact.contentDigest,
                encodedArtifactSHA256: projectorSHA256(encoded),
                occurredAtMilliseconds: fixture.context.acceptedAt.rawValue,
                createdAt: fixture.context.acceptedAt.date
            )
        )
        try context.save()
        let snapshot = makeLegacySnapshot(
            fixture: fixture,
            artifacts: [
                SwiftDataCanonicalArtifactSnapshot(
                    eventID: eventID,
                    callID: fixture.invocation.callID.rawValue,
                    occurredAt: fixture.context.acceptedAt,
                    source: .toolResult,
                    artifact: artifact
                )
            ]
        )
        let projectionID = AgentProjectionID(rawValue: "cross-run-artifact-conflict")
        do {
            _ = try await store.commitProjection(
                SwiftDataAgentProjectionPlan(mutations: [
                    .replaceLegacyRun(snapshot)
                ]),
                cursor: AgentProjectionCursor(
                    projectionID: projectionID,
                    throughOffset: accepted.record.offset,
                    updatedAt: accepted.record.committedAt
                ),
                expectedPreviousOffset: .origin
            )
            XCTFail("Cross-run artifact key collision unexpectedly committed")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "projection_artifact_conflict"
                )
            )
        }
        let artifactCollisionCursor = try await store.loadCursor(for: projectionID)
        XCTAssertNil(artifactCollisionCursor)
        let rows = try ModelContext(container).fetch(
            FetchDescriptor<AgentArtifactProjectionRecord>()
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].runIDString, wrongRunID.uuidString.lowercased())
    }

    func testProjectlessCanonicalScopesPreserveSameIDRowsAndFailClosed() async throws {
        let container = try makeProjectorContainer()
        let first = ProjectorFixture(seed: 17_200, hasProject: false)
        let second = ProjectorFixture(seed: 17_300, hasProject: false)
        try seedProjectorLegacyContext(for: first, in: container)
        try seedProjectorLegacyContext(for: second, in: container)
        let store = SwiftDataAgentStore(container: container)
        let firstAccepted = try await store.accept(
            first.acceptance,
            legacyProjection: first.legacyAcceptance
        )
        _ = try await store.accept(second.acceptance, legacyProjection: second.legacyAcceptance)

        let staleContext = ModelContext(container)
        for fixture in [first, second] {
            let stale = ProjectOSRun(
                project: nil,
                projectName: "Stale projectless projection",
                mission: "Must be preserved as an unrelated V1 row",
                status: .running,
                origin: .fixture,
                sourceConversationID: fixture.conversationID.rawValue,
                now: fixture.context.acceptedAt.date
            )
            stale.id = fixture.runID.rawValue
            staleContext.insert(stale)
        }
        try staleContext.save()
        XCTAssertEqual(
            try staleContext.fetchCount(FetchDescriptor<ProjectOSRun>()),
            2
        )

        let pruneProjectionID = AgentProjectionID(
            rawValue: "projectos-projectless-prune-conflict:v2"
        )
        do {
            _ = try await ProjectOSProjector(
                store: store,
                batchSize: 1,
                projectionID: pruneProjectionID
            ).projectAvailableEvents()
            XCTFail("Projectless canonical scope silently pruned ProjectOS rows")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "projectos_acceptance_conflict"
                )
            )
        }

        let projectlessPruneCursor = try await store.loadCursor(
            for: pruneProjectionID
        )
        XCTAssertNil(projectlessPruneCursor)

        let replaceProjectionID = AgentProjectionID(
            rawValue: "projectos-projectless-replace-conflict:v2"
        )
        let replacePlan = try ProjectOSProjector.plan(for: [firstAccepted.record])
        do {
            _ = try await store.commitProjection(
                replacePlan,
                cursor: AgentProjectionCursor(
                    projectionID: replaceProjectionID,
                    throughOffset: firstAccepted.record.offset,
                    updatedAt: firstAccepted.record.committedAt
                ),
                expectedPreviousOffset: .origin
            )
            XCTFail("Projectless canonical scope silently replaced a ProjectOS row")
        } catch let error as AgentStoreError {
            XCTAssertEqual(
                error,
                .persistenceFailure(
                    operation: .saveProjectionCursor,
                    code: "projectos_acceptance_conflict"
                )
            )
        }

        let projectlessReplaceCursor = try await store.loadCursor(
            for: replaceProjectionID
        )
        XCTAssertNil(projectlessReplaceCursor)
        let preserved = try ModelContext(container).fetch(
            FetchDescriptor<ProjectOSRun>()
        )
        XCTAssertEqual(preserved.count, 2)
        XCTAssertEqual(
            Set(preserved.map(\.mission)),
            ["Must be preserved as an unrelated V1 row"]
        )
        XCTAssertEqual(
            Set(preserved.map(\.id)),
            [first.runID.rawValue, second.runID.rawValue]
        )
        for fixture in [first, second] {
            let row = try XCTUnwrap(preserved.first { $0.id == fixture.runID.rawValue })
            XCTAssertEqual(row.projectName, "Stale projectless projection")
            XCTAssertEqual(row.mission, "Must be preserved as an unrelated V1 row")
            XCTAssertEqual(row.status, .running)
            XCTAssertEqual(row.origin, .fixture)
            XCTAssertEqual(
                row.sourceConversationIDString,
                fixture.conversationID.rawValue.uuidString
            )
            XCTAssertNil(row.project)
        }
    }

    func testMessagePayloadNormalizationIsStableAcrossProjectionVersionReplay() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 17_500)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        let accepted = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        let toolMessageID = projectorUUID(175_901)
        let assistantMessageID = projectorUUID(175_902)
        let toolContent = String(repeating: "tool-output-", count: 2_000)
        let assistantContent = String(repeating: "assistant-proof-", count: 2_000)
        let snapshot = makeLegacySnapshot(
            fixture: fixture,
            messages: [
                SwiftDataLegacyMessageSnapshot(
                    messageID: toolMessageID,
                    sequence: 2,
                    role: .tool,
                    content: toolContent,
                    createdAt: AgentInstant(
                        rawValue: fixture.context.acceptedAt.rawValue + 2
                    )
                ),
                SwiftDataLegacyMessageSnapshot(
                    messageID: assistantMessageID,
                    sequence: 3,
                    role: .assistant,
                    content: assistantContent,
                    createdAt: AgentInstant(
                        rawValue: fixture.context.acceptedAt.rawValue + 3
                    )
                )
            ]
        )
        func commit(_ projectionID: String) async throws {
            _ = try await store.commitProjection(
                SwiftDataAgentProjectionPlan(mutations: [
                    .replaceLegacyRun(snapshot)
                ]),
                cursor: AgentProjectionCursor(
                    projectionID: AgentProjectionID(rawValue: projectionID),
                    throughOffset: accepted.record.offset,
                    updatedAt: accepted.record.committedAt
                ),
                expectedPreviousOffset: .origin
            )
        }
        try await commit("message-normalization:v1")
        let firstContext = ModelContext(container)
        let firstTool = try XCTUnwrap(
            firstContext.fetch(FetchDescriptor<ChatMessage>()).first {
                $0.id == toolMessageID
            }
        ).content
        let firstAssistant = try XCTUnwrap(
            firstContext.fetch(FetchDescriptor<ChatMessage>()).first {
                $0.id == assistantMessageID
            }
        ).content
        XCTAssertLessThan(firstTool.count, toolContent.count)
        XCTAssertEqual(firstAssistant, assistantContent)

        try await commit("message-normalization:v2")
        let secondContext = ModelContext(container)
        XCTAssertEqual(
            try XCTUnwrap(
                secondContext.fetch(FetchDescriptor<ChatMessage>()).first {
                    $0.id == toolMessageID
                }
            ).content,
            firstTool
        )
        XCTAssertEqual(
            try XCTUnwrap(
                secondContext.fetch(FetchDescriptor<ChatMessage>()).first {
                    $0.id == assistantMessageID
                }
            ).content,
            firstAssistant
        )
    }

    func testMultimodalAndImageOnlyAcceptanceUseOneCanonicalLegacyText() async throws {
        let artifact = ArtifactReference(
            artifactID: projectorTagged(176_001),
            mediaType: "application/pdf",
            contentDigest: "sha256:multimodal-artifact",
            displayName: "requirements.pdf"
        )
        let variants: [(UInt64, [ModelContentPart], String)] = [
            (
                17_600,
                [
                    .text("Inspect these inputs"),
                    .structured(.object(["mode": .string("strict")])),
                    .image(
                        ModelImageReference(
                            mediaType: "image/png",
                            contentDigest: "sha256:multimodal-image"
                        )
                    ),
                    .artifact(artifact)
                ],
                "Inspect these inputs\n{\"mode\":\"strict\"}\n[Image: image/png]\n[Artifact: requirements.pdf]"
            ),
            (
                17_700,
                [
                    .image(
                        ModelImageReference(
                            mediaType: "image/jpeg",
                            contentDigest: "sha256:image-only"
                        )
                    )
                ],
                "[Image: image/jpeg]"
            )
        ]

        for (seed, content, expectedText) in variants {
            let container = try makeProjectorContainer()
            let fixture = ProjectorFixture(seed: seed, userContent: content)
            XCTAssertEqual(fixture.acceptedRequestText, expectedText)
            try seedProjectorLegacyContext(for: fixture, in: container)
            let store = SwiftDataAgentStore(container: container)
            _ = try await store.accept(
                fixture.acceptance,
                legacyProjection: fixture.legacyAcceptance
            )
            _ = try await LegacyRunProjector(store: store)
                .projectAvailableEvents()
            let context = ModelContext(container)
            let request = try XCTUnwrap(
                context.fetch(FetchDescriptor<ChatMessage>()).first
            )
            XCTAssertEqual(request.content, expectedText)
            XCTAssertEqual(
                try XCTUnwrap(context.fetch(FetchDescriptor<AgentRunRecord>()).first).status,
                .queued
            )
        }
    }

    func testSuppressedConversationRebuildKeepsReceiptsAndProjectOSWithoutTranscript() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 17_800)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        _ = try await LegacyRunProjector(store: store).projectAvailableEvents()
        _ = try await ProjectOSProjector(store: store).projectAvailableEvents()

        try await store.deleteConversationFromHistory(
            conversationID: fixture.conversationID.rawValue,
            deletedAt: AgentInstant(rawValue: 1_900_001_000_000).date
        )
        for envelope in fixture.fullRunEnvelopes {
            _ = try await store.append(envelope)
        }
        let unrelated = ProjectorFixture(seed: 17_850)
        try seedProjectorLegacyContext(for: unrelated, in: container)
        _ = try await store.accept(
            unrelated.acceptance,
            legacyProjection: unrelated.legacyAcceptance
        )
        _ = try await store.append(unrelated.startedEnvelope)

        let legacy = try await LegacyRunProjector(store: store, batchSize: 3)
            .projectAvailableEvents()
        let projectOS = try await ProjectOSProjector(store: store, batchSize: 2)
            .projectAvailableEvents()
        XCTAssertEqual(legacy.startingOffset, AgentJournalOffset(rawValue: 1))
        XCTAssertEqual(legacy.endingOffset, AgentJournalOffset(rawValue: 15))
        XCTAssertEqual(projectOS.endingOffset, AgentJournalOffset(rawValue: 15))

        var context = ModelContext(container)
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<Conversation>()).contains {
                $0.id == fixture.conversationID.rawValue
            }
        )
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<ChatMessage>()).contains {
                $0.runID == fixture.runID.rawValue
            }
        )
        XCTAssertEqual(
            try XCTUnwrap(
                context.fetch(FetchDescriptor<AgentRunRecord>()).first {
                    $0.id == fixture.runID.rawValue
                }
            ).status,
            .completed
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolRun>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ApprovalRequestRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentArtifactProjectionRecord>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectOSRun>()), 2)

        let retry = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        XCTAssertEqual(retry.disposition, .alreadyCommitted)
        let replayed = try await store.replay(runID: fixture.runID)
        XCTAssertEqual(replayed.phase, .completed)
        let canonicalEvents = try await store.events(for: fixture.runID, after: nil)
        XCTAssertTrue(canonicalEvents.allSatisfy {
            $0.event.header.conversationID == fixture.conversationID
        })

        try deleteProjectionCursors(
            [LegacyRunProjector.projectionID, ProjectOSProjector.projectionID],
            in: container
        )
        _ = try await LegacyRunProjector(store: store, batchSize: 4)
            .projectAvailableEvents()
        _ = try await ProjectOSProjector(store: store, batchSize: 4)
            .projectAvailableEvents()
        context = ModelContext(container)
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<Conversation>()).contains {
                $0.id == fixture.conversationID.rawValue
            }
        )
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<ChatMessage>()).contains {
                $0.runID == fixture.runID.rawValue
            }
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ProjectOSRun>()), 2)
        let rebuiltLegacyCursor = try await store.loadCursor(
            for: LegacyRunProjector.projectionID
        )
        let rebuiltProjectOSCursor = try await store.loadCursor(
            for: ProjectOSProjector.projectionID
        )
        XCTAssertEqual(
            rebuiltLegacyCursor?.throughOffset,
            AgentJournalOffset(rawValue: 15)
        )
        XCTAssertEqual(
            rebuiltProjectOSCursor?.throughOffset,
            AgentJournalOffset(rawValue: 15)
        )
    }

    func testRehomedProjectRebuildStaysDeletedAndRetainsCanonicalGeneralReceipts() async throws {
        let container = try makeProjectorContainer()
        let fixture = ProjectorFixture(seed: 17_900)
        try seedProjectorLegacyContext(for: fixture, in: container)
        let store = SwiftDataAgentStore(container: container)
        _ = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        for envelope in fixture.fullRunEnvelopes {
            _ = try await store.append(envelope)
        }
        _ = try await LegacyRunProjector(store: store).projectAvailableEvents()
        _ = try await ProjectOSProjector(store: store).projectAvailableEvents()
        XCTAssertNotNil(
            try materializedEvidenceRevision(
                for: fixture.projectID.rawValue,
                in: container
            )
        )

        let receipt = try await store.deleteProjectRetainingRunsInGeneral(
            projectID: fixture.projectID.rawValue,
            deletedAt: AgentInstant(rawValue: 1_900_001_100_000).date
        )
        XCTAssertNotEqual(receipt.fallbackProjectID, fixture.projectID.rawValue)
        let unrelated = ProjectorFixture(seed: 17_950)
        try seedProjectorLegacyContext(for: unrelated, in: container)
        _ = try await store.accept(
            unrelated.acceptance,
            legacyProjection: unrelated.legacyAcceptance
        )
        _ = try await store.append(unrelated.startedEnvelope)

        try deleteProjectionCursors(
            [LegacyRunProjector.projectionID, ProjectOSProjector.projectionID],
            in: container
        )
        let legacy = try await LegacyRunProjector(store: store, batchSize: 3)
            .projectAvailableEvents()
        let projectOS = try await ProjectOSProjector(store: store, batchSize: 2)
            .projectAvailableEvents()
        XCTAssertEqual(legacy.endingOffset, AgentJournalOffset(rawValue: 15))
        XCTAssertEqual(projectOS.endingOffset, AgentJournalOffset(rawValue: 15))

        let context = ModelContext(container)
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<Project>()).contains {
                $0.id == fixture.projectID.rawValue
            }
        )
        XCTAssertNil(
            try materializedEvidenceRevision(
                for: fixture.projectID.rawValue,
                in: container
            )
        )
        XCTAssertFalse(
            try context.fetch(FetchDescriptor<ProjectOSRun>()).contains {
                $0.id == fixture.runID.rawValue
            }
        )
        XCTAssertNil(
            try context.fetch(FetchDescriptor<AgentRunRecord>()).first {
                $0.id == fixture.runID.rawValue
            }?.projectID
        )
        XCTAssertNil(try context.fetch(FetchDescriptor<ToolRun>()).first?.project)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<AgentArtifactProjectionRecord>())
                .allSatisfy { $0.projectIDString == nil }
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Conversation>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatMessage>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ApprovalRequestRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()), 2)
        let canonicalEvents = try await store.events(for: fixture.runID, after: nil)
        XCTAssertTrue(canonicalEvents.allSatisfy {
            $0.event.header.projectID == fixture.context.projectID
        })
        let retry = try await store.accept(
            fixture.acceptance,
            legacyProjection: fixture.legacyAcceptance
        )
        XCTAssertEqual(retry.disposition, .alreadyCommitted)
    }

    func testOnDiskRelaunchRecoversJournalCursorAndMaterializedViews() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NovaForge-M4-Relaunch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("NovaForge.store")
        let fixture = ProjectorFixture(seed: 18_000)
        try await populateOnDiskProjectorStore(at: storeURL, fixture: fixture)

        do {
            let container = try makeProjectorContainer(at: storeURL)
            let store = SwiftDataAgentStore(container: container)
            let recovered = try await store.replay(runID: fixture.runID)
            XCTAssertEqual(recovered.phase, .completed)
            XCTAssertEqual(recovered.lastSequence, EventSequence(rawValue: 13))
            let initialLegacyCursor = try await store.loadCursor(
                for: LegacyRunProjector.projectionID
            )
            let initialProjectOSCursor = try await store.loadCursor(
                for: ProjectOSProjector.projectionID
            )
            XCTAssertEqual(
                initialLegacyCursor?.throughOffset,
                AgentJournalOffset(rawValue: 13)
            )
            XCTAssertEqual(
                initialProjectOSCursor?.throughOffset,
                AgentJournalOffset(rawValue: 13)
            )
            let legacyNoOpReport = try await LegacyRunProjector(store: store)
                .projectAvailableEvents()
            let projectOSNoOpReport = try await ProjectOSProjector(store: store)
                .projectAvailableEvents()
            XCTAssertEqual(legacyNoOpReport.projectedEventCount, 0)
            XCTAssertEqual(projectOSNoOpReport.projectedEventCount, 0)

            try deleteProjectionCursors(
                [LegacyRunProjector.projectionID, ProjectOSProjector.projectionID],
                in: container
            )
            _ = try await LegacyRunProjector(store: store, batchSize: 2)
                .projectAvailableEvents()
            _ = try await ProjectOSProjector(store: store, batchSize: 3)
                .projectAvailableEvents()
            let rebuiltLegacyCursor = try await store.loadCursor(
                for: LegacyRunProjector.projectionID
            )
            let rebuiltProjectOSCursor = try await store.loadCursor(
                for: ProjectOSProjector.projectionID
            )
            XCTAssertEqual(
                rebuiltLegacyCursor?.throughOffset,
                AgentJournalOffset(rawValue: 13)
            )
            XCTAssertEqual(
                rebuiltProjectOSCursor?.throughOffset,
                AgentJournalOffset(rawValue: 13)
            )
            let context = ModelContext(container)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ApprovalRequestRecord>()), 1)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<ToolEffectEvidenceRecord>()), 2)
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<AgentArtifactProjectionRecord>()), 2)
            XCTAssertEqual(
                try XCTUnwrap(context.fetch(FetchDescriptor<AgentRunRecord>()).first).status,
                .completed
            )
        }

        do {
            let container = try makeProjectorContainer(at: storeURL)
            let store = SwiftDataAgentStore(container: container)
            let reopenedState = try await store.replay(runID: fixture.runID)
            XCTAssertEqual(reopenedState.phase, .completed)
            XCTAssertEqual(
                try ModelContext(container).fetchCount(FetchDescriptor<ProjectOSRun>()),
                1
            )
            let reopenedLegacyCursor = try await store.loadCursor(
                for: LegacyRunProjector.projectionID
            )
            let reopenedProjectOSCursor = try await store.loadCursor(
                for: ProjectOSProjector.projectionID
            )
            XCTAssertEqual(
                reopenedLegacyCursor?.throughOffset,
                AgentJournalOffset(rawValue: 13)
            )
            XCTAssertEqual(
                reopenedProjectOSCursor?.throughOffset,
                AgentJournalOffset(rawValue: 13)
            )
        }
    }
}

private struct ProjectorFixture {
    let seed: UInt64
    let context: AgentRunContext
    let userItem: ModelItem
    let acceptedRequestText: String
    let assistantItem: ModelItem
    let invocationItem: ModelItem
    let invocation: ToolInvocation
    let approvalRequest: ApprovalRequest
    let correlationID: CorrelationID
    let sameTimestamp: Bool

    init(
        seed: UInt64,
        acceptedAt: AgentInstant? = nil,
        conversationID: ConversationID? = nil,
        projectID: ProjectID? = nil,
        hasProject: Bool = true,
        userContent: [ModelContentPart] = [.text("Build safely")],
        sameTimestamp: Bool = false
    ) {
        self.seed = seed
        self.sameTimestamp = sameTimestamp
        let acceptedAt = acceptedAt
            ?? AgentInstant(rawValue: 1_900_000_000_000 + Int64(seed))
        let runID: RunID = projectorTagged(seed + 1)
        context = AgentRunContext(
            schemaVersion: .v1,
            lineage: .root(runID),
            conversationID: conversationID ?? projectorTagged(seed + 2),
            projectID: hasProject ? (projectID ?? projectorTagged(seed + 3)) : nil,
            workspaceID: projectorTagged(seed + 4),
            executionNodeID: projectorTagged(seed + 5),
            engineVersion: .agentHarnessV1,
            acceptedAt: acceptedAt,
            features: AgentFeatureSet(["v2DarkReplay"]),
            cancellation: CancellationLineage(scopeID: projectorTagged(seed + 6)),
            initialBudget: AgentBudget(limits: .standard)
        )
        let builtUserItem = ModelItem(
            id: projectorTagged(seed + 7),
            createdAt: acceptedAt,
            payload: .message(
                ModelMessage(role: .user, content: userContent)
            )
        )
        userItem = builtUserItem
        acceptedRequestText = canonicalAcceptedUserText([builtUserItem])
        assistantItem = ModelItem(
            id: projectorTagged(seed + 8),
            createdAt: AgentInstant(rawValue: acceptedAt.rawValue + 4),
            payload: .message(
                ModelMessage(
                    role: .assistant,
                    content: [.text("I will update the file safely.")]
                )
            )
        )
        let callID: ToolCallID = projectorTagged(seed + 9)
        let attemptID: AttemptID = projectorTagged(seed + 10)
        let builtInvocation = ToolInvocation(
            callID: callID,
            modelAttemptID: attemptID,
            tool: ToolIdentity(name: "workspace.writeFile", version: "1"),
            arguments: .object(["path": .string("Sources/App.swift")]),
            canonicalArgumentDigest: "arguments-\(seed)",
            idempotencyKey: "tool-\(seed)",
            effectClass: .scopedReversibleWrite,
            locality: .onDevice
        )
        invocation = builtInvocation
        invocationItem = ModelItem(
            id: projectorTagged(seed + 11),
            createdAt: AgentInstant(rawValue: acceptedAt.rawValue + 4),
            payload: .toolInvocation(builtInvocation)
        )
        approvalRequest = ApprovalRequest(
            requestID: projectorTagged(seed + 12),
            binding: ApprovalBinding(
                runID: runID,
                callID: callID,
                tool: builtInvocation.tool,
                canonicalArgumentDigest: builtInvocation.canonicalArgumentDigest,
                workspaceID: projectorTagged(seed + 4),
                previewDigest: "preview-\(seed)",
                workspaceRevision: "revision-\(seed)"
            ),
            summary: "Allow the scoped file update?",
            requestedAt: AgentInstant(rawValue: acceptedAt.rawValue + 6)
        )
        correlationID = projectorTagged(seed + 13)
    }

    var runID: RunID { context.lineage.runID }
    var conversationID: ConversationID { context.conversationID }
    var projectID: ProjectID { context.projectID! }
    var writerID: AgentEventWriterID { AgentEventWriterID(runID: runID) }

    var toolResultArtifact: ArtifactReference {
        ArtifactReference(
            artifactID: projectorTagged(seed + 17),
            mediaType: "application/json",
            contentDigest: "sha256:tool-result-\(seed)",
            displayName: "tool-result-\(seed).json"
        )
    }

    var capturedArtifact: ArtifactReference {
        ArtifactReference(
            artifactID: projectorTagged(seed + 18),
            mediaType: "text/plain",
            contentDigest: "sha256:captured-\(seed)",
            displayName: "proof-\(seed).txt"
        )
    }

    var acceptanceEvent: AgentEvent {
        event(
            sequence: 1,
            payload: .runAccepted(
                RunAcceptedEvent(context: context, initialItems: [userItem])
            )
        )
    }

    var acceptance: AgentRunAcceptance {
        AgentRunAcceptance(
            metadata: AgentStore.AgentRunMetadataRecord(
                context: context,
                writerID: writerID,
                acceptanceCommandID: projectorTagged(seed + 14),
                acceptanceEventID: acceptanceEvent.header.eventID
            ),
            envelope: AgentEventEnvelope(
                writerID: writerID,
                writerSequence: .first,
                idempotencyKey: "accept-\(seed)",
                event: acceptanceEvent
            )
        )
    }

    var legacyAcceptance: SwiftDataLegacyAcceptanceProjection {
        SwiftDataLegacyAcceptanceProjection(
            runID: runID.rawValue,
            conversationID: conversationID.rawValue,
            projectID: context.projectID?.rawValue,
            workspaceID: context.workspaceID.rawValue,
            workspaceName: "Projector Workspace",
            requestMessageID: projectorUUID(seed + 15),
            requestText: acceptedRequestText
        )
    }

    var startedEnvelope: AgentEventEnvelope {
        envelope(sequence: 2, payload: .runStarted(RunStartedEvent()))
    }

    var fullRunEnvelopes: [AgentEventEnvelope] {
        let attemptID = invocation.modelAttemptID
        let evidence = ToolEvidence(
            kind: "workspace-diff",
            digest: "evidence-\(seed)",
            metadata: .object(["path": .string("Sources/App.swift")])
        )
        let resultEvidence = ToolEvidence(
            kind: "verification",
            digest: "verification-\(seed)",
            metadata: .object(["gate": .string("swift-test")])
        )
        let resolution = ApprovalResolution(
            requestID: approvalRequest.requestID,
            callID: invocation.callID,
            decision: .approved,
            resolvedAt: AgentInstant(rawValue: context.acceptedAt.rawValue + 7),
            rationale: "Scoped change approved"
        )
        let result = ToolResult(
            modelItemID: projectorTagged(seed + 16),
            callID: invocation.callID,
            status: .succeeded,
            output: .object(["status": .string("updated")]),
            artifacts: [toolResultArtifact, toolResultArtifact],
            evidence: [resultEvidence]
        )
        return [
            startedEnvelope,
            envelope(
                sequence: 3,
                payload: .modelRequestStarted(
                    ModelRequestStartedEvent(
                        attemptID: attemptID,
                        route: ModelRoute(
                            provider: "openai",
                            model: "gpt-hermes-baseline",
                            adapter: "responses"
                        ),
                        providerAttempt: .legacyV1
                    )
                )
            ),
            envelope(
                sequence: 4,
                payload: .modelResponseCommitted(
                    ModelResponseCommittedEvent(
                        attemptID: attemptID,
                        items: [assistantItem, invocationItem],
                        usage: ModelUsage(inputTokens: 100, outputTokens: 40),
                        finishReason: .toolCalls
                    )
                )
            ),
            envelope(sequence: 5, payload: .toolProposed(ToolProposedEvent(invocation: invocation))),
            envelope(
                sequence: 6,
                payload: .approvalRequested(ApprovalRequestedEvent(request: approvalRequest))
            ),
            envelope(
                sequence: 7,
                payload: .approvalResolved(ApprovalResolvedEvent(resolution: resolution))
            ),
            envelope(
                sequence: 8,
                payload: .toolScheduled(ToolScheduledEvent(callID: invocation.callID))
            ),
            envelope(
                sequence: 9,
                payload: .toolStarted(ToolStartedEvent(callID: invocation.callID))
            ),
            envelope(
                sequence: 10,
                payload: .toolApplied(
                    ToolAppliedEvent(callID: invocation.callID, evidence: [evidence])
                )
            ),
            envelope(
                sequence: 11,
                payload: .toolCompleted(ToolCompletedEvent(result: result))
            ),
            envelope(
                sequence: 12,
                payload: .artifactCaptured(
                    ArtifactCapturedEvent(artifact: capturedArtifact)
                )
            ),
            envelope(
                sequence: 13,
                payload: .runCompleted(RunCompletedEvent(summary: "Verified complete"))
            )
        ]
    }

    private func envelope(
        sequence: UInt64,
        payload: AgentEventPayload
    ) -> AgentEventEnvelope {
        AgentEventEnvelope(
            writerID: writerID,
            writerSequence: EventSequence(rawValue: sequence),
            idempotencyKey: "projector-\(seed)-\(sequence)",
            event: event(sequence: sequence, payload: payload)
        )
    }

    private func event(
        sequence: UInt64,
        payload: AgentEventPayload
    ) -> AgentEvent {
        AgentEvent(
            header: AgentEventHeader(
                eventID: projectorTagged(50_000 + seed * 20 + sequence),
                schemaVersion: context.schemaVersion,
                context: context,
                sequence: EventSequence(rawValue: sequence),
                timestamp: sequence == 1 || sameTimestamp
                    ? context.acceptedAt
                    : AgentInstant(rawValue: context.acceptedAt.rawValue + Int64(sequence)),
                causationID: projectorTagged(70_000 + seed * 20 + sequence),
                correlationID: correlationID
            ),
            payload: payload
        )
    }
}

private enum ProjectorInjectedFailure: Error {
    case stop
}

private func seedProjectorLegacyContext(
    for fixture: ProjectorFixture,
    in container: ModelContainer
) throws {
    let context = ModelContext(container)
    let project: Project?
    if let projectID = fixture.context.projectID {
        let value = Project(
            name: "Project \(fixture.seed)",
            mission: "Projector verification",
            workspaceName: "Projector Workspace"
        )
        value.id = projectID.rawValue
        context.insert(value)
        project = value
    } else {
        project = nil
    }
    let conversation = Conversation(
        title: "Projector \(fixture.seed)",
        project: project
    )
    conversation.id = fixture.conversationID.rawValue
    context.insert(conversation)
    try context.save()
}

@MainActor
private func materializedEvidenceRevisions(
    in container: ModelContainer
) throws -> [UUID: Int64] {
    let records = try ModelContext(container).fetch(
        FetchDescriptor<ProjectMaterializedEvidenceRevisionRecord>()
    )
    return Dictionary(uniqueKeysWithValues: records.map {
        ($0.projectID, $0.revision)
    })
}

@MainActor
private func materializedEvidenceRevision(
    for projectID: UUID,
    in container: ModelContainer
) throws -> Int64? {
    try materializedEvidenceRevisions(in: container)[projectID]
}

private func makeProjectorContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Schema(versionedSchema: NovaForgeSchemaV4.self),
        migrationPlan: NovaForgeSchemaMigrationPlan.self,
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )
}

private func makeProjectorContainer(at storeURL: URL) throws -> ModelContainer {
    try ModelContainer(
        for: Schema(versionedSchema: NovaForgeSchemaV4.self),
        migrationPlan: NovaForgeSchemaMigrationPlan.self,
        configurations: [ModelConfiguration(url: storeURL)]
    )
}

@MainActor
private func populateOnDiskProjectorStore(
    at storeURL: URL,
    fixture: ProjectorFixture
) async throws {
    let container = try makeProjectorContainer(at: storeURL)
    try seedProjectorLegacyContext(for: fixture, in: container)
    let store = SwiftDataAgentStore(container: container)
    _ = try await store.accept(
        fixture.acceptance,
        legacyProjection: fixture.legacyAcceptance
    )
    for envelope in fixture.fullRunEnvelopes {
        _ = try await store.append(envelope)
    }
    _ = try await LegacyRunProjector(store: store, batchSize: 3)
        .projectAvailableEvents()
    _ = try await ProjectOSProjector(store: store, batchSize: 4)
        .projectAvailableEvents()
}

private func makeLegacySnapshot(
    fixture: ProjectorFixture,
    messages: [SwiftDataLegacyMessageSnapshot] = [],
    evidence: [SwiftDataCanonicalEvidenceSnapshot] = [],
    artifacts: [SwiftDataCanonicalArtifactSnapshot] = []
) -> SwiftDataLegacyRunSnapshot {
    SwiftDataLegacyRunSnapshot(
        acceptance: SwiftDataLegacyAcceptanceCheck(
            runID: fixture.runID.rawValue,
            conversationID: fixture.conversationID.rawValue,
            projectID: fixture.projectID.rawValue,
            workspaceID: fixture.context.workspaceID.rawValue,
            requestText: fixture.acceptedRequestText
        ),
        status: .queued,
        updatedAt: fixture.context.acceptedAt,
        startedAt: nil,
        completedAt: nil,
        errorKind: nil,
        errorMessage: nil,
        observedRoute: nil,
        responseMessageID: nil,
        messages: messages,
        tools: [],
        approvals: [],
        evidence: evidence,
        artifacts: artifacts
    )
}

private func deleteProjectionCursors(
    _ projectionIDs: [AgentProjectionID],
    in container: ModelContainer
) throws {
    let values = Set(projectionIDs.map(\.rawValue))
    let context = ModelContext(container)
    for cursor in try context.fetch(FetchDescriptor<ProjectionCursorRecord>())
        where values.contains(cursor.projectionIDString) {
        context.delete(cursor)
    }
    try context.save()
}

private func materializedProjectionDigest(
    in container: ModelContainer
) throws -> [String] {
    let context = ModelContext(container)
    var values: [String] = []

    values.append(contentsOf: try context.fetch(FetchDescriptor<AgentRunRecord>())
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .map { run in
            "run|\(run.id.uuidString)|\(run.statusRawValue)|\(run.originRawValue)" +
                "|conversation=\(run.conversationIDString ?? "nil")" +
                "|project=\(run.projectIDString ?? "nil")|workspace=\(run.workspaceIDString ?? "nil")" +
                "|request=\(run.requestMessageIDString ?? "nil")|response=\(run.responseMessageIDString ?? "nil")" +
                "|provider=\(run.providerRawValue ?? "nil")|model=\(run.modelID ?? "nil")" +
                "|error=\(run.errorKindRawValue ?? "nil"):\(run.errorMessage ?? "nil")" +
                "|created=\(dateBits(run.createdAt))|queued=\(dateBits(run.queuedAt))" +
                "|started=\(dateBits(run.startedAt))|updated=\(dateBits(run.updatedAt))" +
                "|completed=\(dateBits(run.completedAt))"
        })
    values.append(contentsOf: try context.fetch(FetchDescriptor<Conversation>())
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .map { conversation in
            "conversation|\(conversation.id.uuidString)|count=\(conversation.messageCount)" +
                "|user=\(conversation.hasUserMessages)|preview=\(conversation.lastMessagePreview)" +
                "|updated=\(dateBits(conversation.updatedAt))" +
                "|messages=\(conversation.messages.map(\.id.uuidString).sorted().joined(separator: ","))"
        })
    values.append(contentsOf: try context.fetch(FetchDescriptor<ChatMessage>())
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .map { message in
            "message|\(message.id.uuidString)|\(message.roleRawValue)|\(message.content)" +
                "|conversation=\(message.conversation?.id.uuidString ?? "nil")" +
                "|run=\(message.runIDString ?? "nil")|sequence=\(message.runSequence ?? -1)" +
                "|status=\(message.runStatusRawValue ?? "nil")|created=\(dateBits(message.createdAt))"
        })
    values.append(contentsOf: try context.fetch(FetchDescriptor<ToolRun>())
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .map { tool in
            "tool|\(tool.id.uuidString)|\(tool.name)|\(tool.argumentsJSON)|\(tool.output)" +
                "|\(tool.statusRawValue)|approval=\(tool.requiresApproval)|mutating=\(tool.isMutating)" +
                "|project=\(tool.project?.id.uuidString ?? "nil")|run=\(tool.runIDString ?? "nil")" +
                "|sequence=\(tool.runSequence ?? -1)|runStatus=\(tool.runStatusRawValue ?? "nil")" +
                "|created=\(dateBits(tool.createdAt))|completed=\(dateBits(tool.completedAt))"
        })
    values.append(contentsOf: try context.fetch(FetchDescriptor<ApprovalRequestRecord>())
        .sorted { $0.approvalRequestIDString < $1.approvalRequestIDString }
        .map { approval in
            "approval|\(approval.approvalRequestIDString)|\(approval.runIDString)" +
                "|\(approval.toolCallIDString)|\(approval.statusRawValue)" +
                "|workspace=\(approval.workspaceIDString)" +
                "|requestedEvent=\(approval.requestedEventIDString)" +
                "|resolvedEvent=\(approval.resolvedEventIDString ?? "nil")" +
                "|request=\(approval.encodedRequest.base64EncodedString())" +
                "|resolution=\(approval.encodedResolution?.base64EncodedString() ?? "nil")" +
                "|requestedAt=\(approval.requestedAtMilliseconds)" +
                "|resolvedAt=\(approval.resolvedAtMilliseconds.map(String.init) ?? "nil")" +
                "|updated=\(dateBits(approval.updatedAt))"
        })
    values.append(contentsOf: try context.fetch(FetchDescriptor<ToolEffectEvidenceRecord>())
        .sorted { $0.evidenceKey < $1.evidenceKey }
        .map { evidence in
            "evidence|\(evidence.evidenceKey)|\(evidence.runIDString)|\(evidence.toolCallIDString)" +
                "|\(evidence.evidenceKind)|\(evidence.evidenceDigest)" +
                "|event=\(evidence.appliedEventIDString)|workspace=\(evidence.workspaceIDString)" +
                "|\(evidence.encodedEvidence.base64EncodedString())|at=\(evidence.appliedAtMilliseconds)" +
                "|created=\(dateBits(evidence.createdAt))"
        })
    values.append(contentsOf: try context.fetch(FetchDescriptor<AgentArtifactProjectionRecord>())
        .sorted { $0.artifactProjectionKey < $1.artifactProjectionKey }
        .map { artifact in
            "artifact|\(artifact.artifactProjectionKey)|\(artifact.runIDString)" +
                "|project=\(artifact.projectIDString ?? "nil")|workspace=\(artifact.workspaceIDString)" +
                "|call=\(artifact.toolCallIDString ?? "nil")|source=\(artifact.sourceKind)" +
                "|media=\(artifact.mediaType)|name=\(artifact.displayName)" +
                "|event=\(artifact.eventIDString)|encoding=\(artifact.encodingName):\(artifact.encodingVersion)" +
                "|digest=\(artifact.artifactDigest)|envelope=\(artifact.encodedArtifactSHA256)" +
                "|encoded=\(artifact.encodedArtifact.base64EncodedString())|at=\(artifact.occurredAtMilliseconds)" +
                "|created=\(dateBits(artifact.createdAt))"
        })
    values.append(contentsOf: try context.fetch(FetchDescriptor<ProjectOSRun>())
        .sorted { $0.id.uuidString < $1.id.uuidString }
        .map { run in
            "projectOS|\(run.id.uuidString)|\(run.statusRawValue)|\(run.mission)" +
                "|planning=\(run.planningState)|action=\(run.currentAction)|command=\(run.currentCommand)" +
                "|next=\(run.nextStep)|title=\(run.latestEventTitle)|detail=\(run.latestEventDetail)" +
                "|files=\(run.changedFilesSummary)|artifacts=\(run.artifactsSummary)|proof=\(run.proofSummary)" +
                "|blocker=\(run.blockerReason)|waiting=\(run.waitingReason)|failure=\(run.failureReason)" +
                "|resume=\(run.resumeState)|progress=\(run.progressEventCount)" +
                "|project=\(run.project?.id.uuidString ?? "nil")" +
                "|conversation=\(run.sourceConversationIDString ?? "nil")" +
                "|created=\(dateBits(run.createdAt))|updated=\(dateBits(run.updatedAt))" +
                "|completed=\(dateBits(run.completedAt))"
        })
    return values
}

private func dateBits(_ date: Date?) -> String {
    guard let date else { return "nil" }
    return String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
}

private func deterministicProjectorData<Value: Encodable>(
    _ value: Value
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func projectorSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func fetchProjectorRun(
    _ id: UUID,
    in context: ModelContext
) throws -> AgentRunRecord? {
    var descriptor = FetchDescriptor<AgentRunRecord>(
        predicate: #Predicate { record in record.id == id }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
}

private func captureProjectorStoreResult<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) async -> Result<Value, AgentStoreError> {
    do {
        return .success(try await operation())
    } catch let error as AgentStoreError {
        return .failure(error)
    } catch {
        return .failure(
            .persistenceFailure(
                operation: .saveProjectionCursor,
                code: "unexpected_projector_test_error"
            )
        )
    }
}

private func projectorTagged<Tag: AgentIdentifierTag>(
    _ value: UInt64
) -> AgentIdentifier<Tag> {
    AgentIdentifier(rawValue: projectorUUID(value))
}

private func projectorUUID(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llX", value)
    return UUID(uuidString: "10000000-0000-0000-0000-\(suffix)")!
}
