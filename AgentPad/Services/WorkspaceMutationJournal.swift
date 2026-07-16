import CryptoKit
import Foundation
import SwiftData

/// Immutable write-ahead data captured before a mutation waits for its FIFO
/// lease. The resource key is a SHA-256 digest; no raw workspace root is held.
struct WorkspaceMutationJournalEntry: Equatable, Sendable {
    let operationID: UUID
    let workspaceResourceKey: String
    let workspacePersistentID: UUID
    let workspaceName: String
    let operationName: String
    let argumentsJSON: String
    let targetPaths: [String]
    let risk: WorkspaceMutationRisk
    let runID: UUID?
    let projectID: UUID?
    let conversationID: UUID?
    let toolCallID: String?
    let source: WorkspaceMutationSource
    let authorization: WorkspaceMutationAuthorization
    let ownerDescription: String
    let requestedAt: Date

    init(request: WorkspaceMutationRequest) {
        operationID = request.id
        workspaceResourceKey = request.workspaceIdentity.resourceKey
        workspacePersistentID = request.workspaceIdentity.persistentID
        workspaceName = request.workspaceName
        operationName = request.operation.journalName
        argumentsJSON = request.journalArgumentsJSON
        targetPaths = request.operation.targetPaths
        risk = request.operation.risk
        runID = request.context.runID
        projectID = request.context.projectID
        conversationID = request.context.conversationID
        toolCallID = request.context.toolCallID
        source = request.context.source
        authorization = request.context.authorization
        ownerDescription = request.context.ownerDescription
        requestedAt = request.requestedAt
    }
}

struct WorkspaceMutationJournalSnapshot: Equatable, Sendable {
    let operationID: UUID
    let phase: ToolOperationPhase
    let workspacePersistentID: UUID?
    let workspaceName: String?
    let operationName: String
    let argumentsHash: String
    let argumentsJSON: String
    let targetPaths: [String]
    let runID: UUID?
    let projectID: UUID?
    let conversationID: UUID?
    let toolCallID: String?
    let sourceRawValue: String?
    let authorizationKind: String?
    let authorizationDetail: String?
    let ownerDescription: String?
    let riskRawValue: String?
    let resultSummary: String?
    let errorMessage: String?
    let scheduledAt: Date
    let startedAt: Date?
    let appliedAt: Date?
    let completedAt: Date?
}

protocol WorkspaceMutationJournaling: Sendable {
    func schedule(_ entry: WorkspaceMutationJournalEntry) async throws

    /// Reads the durable phase after idempotent scheduling. The gateway uses
    /// this to decide whether replay may dispatch, settle only, or must stop for
    /// inspection; an in-memory implementation cannot safely return a guess.
    func snapshot(operationID: UUID) async throws -> WorkspaceMutationJournalSnapshot?

    func transition(
        operationID: UUID,
        to phase: ToolOperationPhase,
        resultSummary: String?,
        errorMessage: String?,
        at timestamp: Date
    ) async throws
}

extension WorkspaceMutationJournaling {
    func transition(
        operationID: UUID,
        to phase: ToolOperationPhase,
        resultSummary: String? = nil,
        errorMessage: String? = nil
    ) async throws {
        try await transition(
            operationID: operationID,
            to: phase,
            resultSummary: resultSummary,
            errorMessage: errorMessage,
            at: Date()
        )
    }
}

enum WorkspaceMutationJournalError: LocalizedError, Equatable, Sendable {
    case missingOperation(UUID)
    case operationConflict(UUID)
    case invalidTransition(operationID: UUID, from: ToolOperationPhase, to: ToolOperationPhase)
    case invalidMetadata(UUID)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .missingOperation(let id):
            return "The workspace operation receipt \(id.uuidString) is missing."
        case .operationConflict(let id):
            return "A different workspace operation already owns receipt \(id.uuidString)."
        case .invalidTransition(let id, let current, let next):
            return "Workspace receipt \(id.uuidString) cannot advance from \(current.rawValue) to \(next.rawValue)."
        case .invalidMetadata(let id):
            return "Workspace receipt \(id.uuidString) metadata could not be encoded."
        case .persistence(let message):
            return message
        }
    }
}

/// Metadata is stored inside the existing redacted arguments column so the M0
/// journal does not mutate the versioned SwiftData schema. Canonical identity
/// itself uses the existing `workspaceIDString`; the full digest stays memory-only.
private struct WorkspaceMutationJournalPayload: Codable, Equatable, Sendable {
    let version: Int
    let source: String
    let authorizationKind: String
    let authorizationDetail: String?
    let ownerDescription: String
    let risk: String
    let originalArgumentsJSON: String

    init(
        entry: WorkspaceMutationJournalEntry,
        originalArgumentsJSON: String
    ) {
        version = 1
        source = entry.source.rawValue
        authorizationKind = entry.authorization.journalKind
        authorizationDetail = entry.authorization.journalDetail
        ownerDescription = entry.ownerDescription
        risk = entry.risk.rawValue
        self.originalArgumentsJSON = originalArgumentsJSON
    }
}

/// SwiftData-backed mandatory journal. The actor serializes idempotency checks
/// and writes so duplicate operation IDs cannot create competing receipts.
actor SwiftDataWorkspaceMutationJournal: WorkspaceMutationJournaling {
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    func schedule(_ entry: WorkspaceMutationJournalEntry) async throws {
        let context = makeContext()
        do {
            if let existing = try fetch(operationID: entry.operationID, context: context) {
                guard try matches(existing, entry: entry) else {
                    throw WorkspaceMutationJournalError.operationConflict(entry.operationID)
                }
                return
            }

            let encodedPayload = try encodePayload(entry)
            let record = ToolOperationRecord(
                id: entry.operationID,
                runID: entry.runID,
                projectID: entry.projectID,
                conversationID: entry.conversationID,
                workspaceID: entry.workspacePersistentID,
                workspaceName: entry.workspaceName,
                toolCallID: entry.toolCallID,
                toolName: entry.operationName,
                argumentsJSON: encodedPayload.json,
                argumentsHash: hashArguments(entry.argumentsJSON),
                targetPaths: entry.targetPaths,
                phase: .scheduled,
                now: entry.requestedAt
            )
            // ToolOperationRecord applies its legacy persistence budget. The
            // gateway must fail closed if that would alter the receipt envelope
            // or make any typed target disappear.
            guard record.argumentsJSON == encodedPayload.json,
                  record.targetPaths == entry.targetPaths else {
                throw WorkspaceMutationJournalError.invalidMetadata(entry.operationID)
            }
            context.insert(record)
            try context.save()
        } catch let error as WorkspaceMutationJournalError {
            throw error
        } catch {
            throw WorkspaceMutationJournalError.persistence(error.localizedDescription)
        }
    }

    func transition(
        operationID: UUID,
        to phase: ToolOperationPhase,
        resultSummary: String?,
        errorMessage: String?,
        at timestamp: Date
    ) async throws {
        let context = makeContext()
        do {
            guard let record = try fetch(operationID: operationID, context: context) else {
                throw WorkspaceMutationJournalError.missingOperation(operationID)
            }
            do {
                try record.advanceJournalPhase(
                    to: phase,
                    at: timestamp,
                    resultSummary: resultSummary,
                    errorMessage: errorMessage
                )
            } catch let error as ToolOperationJournalTransitionError {
                throw WorkspaceMutationJournalError.invalidTransition(
                    operationID: operationID,
                    from: error.currentPhase,
                    to: error.requestedPhase
                )
            }
            try context.save()
        } catch let error as WorkspaceMutationJournalError {
            throw error
        } catch {
            throw WorkspaceMutationJournalError.persistence(error.localizedDescription)
        }
    }

    func snapshot(operationID: UUID) async throws -> WorkspaceMutationJournalSnapshot? {
        let context = makeContext()
        do {
            guard let record = try fetch(operationID: operationID, context: context) else {
                return nil
            }
            let payload = try decodePayload(record.argumentsJSON, operationID: operationID)
            return WorkspaceMutationJournalSnapshot(
                operationID: record.id,
                phase: record.phase,
                workspacePersistentID: record.workspaceID,
                workspaceName: record.workspaceName,
                operationName: record.toolName,
                argumentsHash: record.argumentsHash,
                argumentsJSON: payload.originalArgumentsJSON,
                targetPaths: record.targetPaths,
                runID: record.runID,
                projectID: record.projectID,
                conversationID: record.conversationID,
                toolCallID: record.toolCallID,
                sourceRawValue: payload.source,
                authorizationKind: payload.authorizationKind,
                authorizationDetail: payload.authorizationDetail,
                ownerDescription: payload.ownerDescription,
                riskRawValue: payload.risk,
                resultSummary: record.resultSummary,
                errorMessage: record.errorMessage,
                scheduledAt: record.scheduledAt,
                startedAt: record.startedAt,
                appliedAt: record.appliedAt,
                completedAt: record.completedAt
            )
        } catch let error as WorkspaceMutationJournalError {
            throw error
        } catch {
            throw WorkspaceMutationJournalError.persistence(error.localizedDescription)
        }
    }

    private func makeContext() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    private func fetch(
        operationID: UUID,
        context: ModelContext
    ) throws -> ToolOperationRecord? {
        var descriptor = FetchDescriptor<ToolOperationRecord>(
            predicate: #Predicate { $0.id == operationID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func matches(
        _ record: ToolOperationRecord,
        entry: WorkspaceMutationJournalEntry
    ) throws -> Bool {
        let payload = try decodePayload(record.argumentsJSON, operationID: record.id)
        let expectedPayload = try encodePayload(entry).payload
        return record.workspaceID == entry.workspacePersistentID &&
            record.workspaceName == entry.workspaceName &&
            record.toolName == entry.operationName &&
            record.targetPaths == entry.targetPaths &&
            record.runID == entry.runID &&
            record.projectID == entry.projectID &&
            record.conversationID == entry.conversationID &&
            record.toolCallID == entry.toolCallID &&
            record.argumentsHash == hashArguments(entry.argumentsJSON) &&
            payload == expectedPayload
    }

    private func encodePayload(
        _ entry: WorkspaceMutationJournalEntry
    ) throws -> (json: String, payload: WorkspaceMutationJournalPayload) {
        let limit = PersistedPayloadBudget.maxToolRunArgumentsCharacters
        var argumentBudget = limit

        while true {
            let arguments = argumentBudget == limit
                ? entry.argumentsJSON
                : PersistedPayloadBudget.compactWorkspaceMutationArguments(
                    entry.argumentsJSON,
                    limit: argumentBudget
                )
            let payload = WorkspaceMutationJournalPayload(
                entry: entry,
                originalArgumentsJSON: arguments
            )
            let json = try encode(payload, operationID: entry.operationID)
            if json.count <= limit {
                return (json, payload)
            }

            guard argumentBudget > 512 else {
                throw WorkspaceMutationJournalError.invalidMetadata(entry.operationID)
            }
            argumentBudget = max(512, argumentBudget / 2)
        }
    }

    private func encode(
        _ payload: WorkspaceMutationJournalPayload,
        operationID: UUID
    ) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(payload)
            guard let json = String(data: data, encoding: .utf8) else {
                throw WorkspaceMutationJournalError.invalidMetadata(operationID)
            }
            return json
        } catch let error as WorkspaceMutationJournalError {
            throw error
        } catch {
            throw WorkspaceMutationJournalError.invalidMetadata(operationID)
        }
    }

    private func decodePayload(
        _ json: String,
        operationID: UUID
    ) throws -> WorkspaceMutationJournalPayload {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(WorkspaceMutationJournalPayload.self, from: data) else {
            throw WorkspaceMutationJournalError.invalidMetadata(operationID)
        }
        return payload
    }

    private func hashArguments(_ argumentsJSON: String) -> String {
        SHA256.hash(data: Data(argumentsJSON.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
