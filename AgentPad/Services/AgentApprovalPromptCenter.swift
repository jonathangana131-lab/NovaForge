import AgentDomain
import AgentPolicy
import AgentTools
import Foundation
import Observation

enum AgentApprovalPromptCenterError: Error, Equatable, Sendable {
    case invalidContext
    case duplicateRequestID(ApprovalRequestID)
}

/// Process-wide bridge between the sealed AgentPolicy approval authority and
/// NovaForge's UI.
///
/// The center deliberately converts the package's ephemeral prompt context at
/// the actor boundary. Its queue never retains exact argument JSON, file
/// contents, replacement text, seed contents, command text, or the context
/// itself. Only an exact durable request identity and a bounded, typed UI
/// projection survive while the user is deciding.
@MainActor
@Observable
final class AgentApprovalPromptCenter: ApprovalDecisionPrompting {
    struct PendingItem: Identifiable, Equatable, Sendable {
        enum ReplacementScope: Equatable, Sendable {
            case oneUnambiguousMatch
            case everyMatch
        }

        struct SeedTarget: Equatable, Sendable {
            let path: String
            let contentUTF8ByteCount: Int
        }

        /// A deliberately redacted operation projection. Associated values
        /// contain only bounded workspace paths and non-sensitive counts.
        /// `previewSHA256` on `PendingItem` is the exact payload fingerprint.
        enum OperationPreview: Equatable, Sendable {
            case writeFile(path: String, contentUTF8ByteCount: Int)
            case appendFile(path: String, contentUTF8ByteCount: Int)
            case replaceText(
                path: String,
                scope: ReplacementScope,
                matchedUTF8ByteCount: Int,
                replacementUTF8ByteCount: Int
            )
            case deletePath(path: String)
            case movePath(source: String, destination: String)
            case copyPath(source: String, destination: String)
            case makeDirectory(path: String)
            case runCommand(commandUTF8ByteCount: Int)
            case createFile(path: String)
            case touchFile(path: String)
            case resetWorkspace
            case seedWorkspace(targets: [SeedTarget])

            init(_ body: MutationEffectOperationBody) {
                switch body {
                case let .writeFile(arguments):
                    self = .writeFile(
                        path: PendingItem.sanitizedPath(arguments.path),
                        contentUTF8ByteCount: arguments.contents.utf8.count
                    )
                case let .appendFile(arguments):
                    self = .appendFile(
                        path: PendingItem.sanitizedPath(arguments.path),
                        contentUTF8ByteCount: arguments.contents.utf8.count
                    )
                case let .replaceText(arguments):
                    self = .replaceText(
                        path: PendingItem.sanitizedPath(arguments.path),
                        scope: arguments.replaceAll == true
                            ? .everyMatch
                            : .oneUnambiguousMatch,
                        matchedUTF8ByteCount: arguments.old.utf8.count,
                        replacementUTF8ByteCount: arguments.new.utf8.count
                    )
                case let .deletePath(arguments):
                    self = .deletePath(
                        path: PendingItem.sanitizedPath(arguments.path)
                    )
                case let .movePath(arguments):
                    self = .movePath(
                        source: PendingItem.sanitizedPath(arguments.from),
                        destination: PendingItem.sanitizedPath(arguments.to)
                    )
                case let .copyPath(arguments):
                    self = .copyPath(
                        source: PendingItem.sanitizedPath(arguments.from),
                        destination: PendingItem.sanitizedPath(arguments.to)
                    )
                case let .makeDirectory(arguments):
                    self = .makeDirectory(
                        path: PendingItem.sanitizedPath(arguments.path)
                    )
                case let .runCommand(arguments):
                    self = .runCommand(
                        commandUTF8ByteCount: arguments.command.utf8.count
                    )
                case let .createFile(arguments):
                    self = .createFile(
                        path: PendingItem.sanitizedPath(arguments.path)
                    )
                case let .touchFile(arguments):
                    self = .touchFile(
                        path: PendingItem.sanitizedPath(arguments.path)
                    )
                case .resetWorkspace:
                    self = .resetWorkspace
                case let .seedWorkspace(arguments):
                    self = .seedWorkspace(targets: arguments.entries.map {
                        SeedTarget(
                            path: PendingItem.sanitizedPath($0.path),
                            contentUTF8ByteCount: $0.contents.utf8.count
                        )
                    })
                }
            }
        }

        let requestID: ApprovalRequestID
        let runID: RunID
        let callID: ToolCallID
        let workspaceID: WorkspaceID
        let origin: MutationOrigin
        let toolTitle: String
        let toolName: String
        let toolVersion: String
        let effectClass: ToolEffectClass
        let operation: OperationPreview
        let previewSHA256: SHA256Digest
        let bindingSHA256: SHA256Digest
        let issuedAt: AgentInstant
        let expiresAt: AgentInstant

        var id: ApprovalRequestID { requestID }

        init(
            requestID: ApprovalRequestID,
            runID: RunID,
            callID: ToolCallID,
            workspaceID: WorkspaceID,
            origin: MutationOrigin,
            toolTitle: String,
            toolName: String,
            toolVersion: String,
            effectClass: ToolEffectClass,
            operation: OperationPreview,
            previewSHA256: SHA256Digest,
            bindingSHA256: SHA256Digest,
            issuedAt: AgentInstant,
            expiresAt: AgentInstant
        ) {
            self.requestID = requestID
            self.runID = runID
            self.callID = callID
            self.workspaceID = workspaceID
            self.origin = origin
            self.toolTitle = Self.sanitizedLabel(
                toolTitle,
                fallback: "Workspace change",
                maximumUTF8Bytes: 160
            )
            self.toolName = Self.sanitizedLabel(
                toolName,
                fallback: "workspace_mutation",
                maximumUTF8Bytes: 160
            )
            self.toolVersion = Self.sanitizedLabel(
                toolVersion,
                fallback: "unknown",
                maximumUTF8Bytes: 80
            )
            self.effectClass = effectClass
            self.operation = operation
            self.previewSHA256 = previewSHA256
            self.bindingSHA256 = bindingSHA256
            self.issuedAt = issuedAt
            self.expiresAt = expiresAt
        }

        fileprivate init(context: DurableApprovalPromptContext) throws {
            let request = context.approvalRequest
            let registration = request.registrationIdentity
            let binding = request.binding
            let preview = context.operationPreview
            guard registration.runID == binding.runID,
                  registration.callID == binding.callID,
                  binding.origin == preview.origin,
                  binding.tool == preview.tool,
                  binding.effectClass == preview.effectClass,
                  binding.operationPreviewSHA256 == preview.previewSHA256
            else { throw AgentApprovalPromptCenterError.invalidContext }

            self.init(
                requestID: request.requestID,
                runID: binding.runID,
                callID: binding.callID,
                workspaceID: binding.workspaceID,
                origin: binding.origin,
                toolTitle: preview.title,
                toolName: binding.tool.name,
                toolVersion: binding.tool.version,
                effectClass: binding.effectClass,
                operation: OperationPreview(preview.body),
                previewSHA256: preview.previewSHA256,
                bindingSHA256: binding.bindingSHA256,
                issuedAt: binding.issuedAt,
                expiresAt: binding.expiresAt
            )
        }

        private static func sanitizedPath(_ value: String) -> String {
            sanitizedLabel(
                value,
                fallback: "Workspace item",
                maximumUTF8Bytes: 512
            )
        }

        private static func sanitizedLabel(
            _ value: String,
            fallback: String,
            maximumUTF8Bytes: Int
        ) -> String {
            precondition(maximumUTF8Bytes >= 4)
            let ellipsis = "\u{2026}"
            let contentLimit = maximumUTF8Bytes - ellipsis.utf8.count
            var result = ""
            var byteCount = 0
            var wasTruncated = false

            for scalar in value.unicodeScalars {
                let category = scalar.properties.generalCategory
                let fragment: String
                if category == .format
                    || category == .control
                    || category == .lineSeparator
                    || category == .paragraphSeparator
                {
                    fragment = "\u{FFFD}"
                } else {
                    fragment = String(scalar)
                }
                guard byteCount + fragment.utf8.count <= contentLimit else {
                    wasTruncated = true
                    break
                }
                result += fragment
                byteCount += fragment.utf8.count
            }

            if wasTruncated { result += ellipsis }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            else { return fallback }
            return result
        }
    }

    enum SubmissionResult: Equatable, Sendable {
        case accepted
        case noPendingRequest
        case requestIDMismatch(expected: ApprovalRequestID)
    }

    enum CancellationResult: Equatable, Sendable {
        case cancelled
        case noPendingRequest
        case requestIDMismatch(expected: ApprovalRequestID)
    }

    private struct QueuedRequest {
        let token: UUID
        let item: PendingItem
        let continuation: CheckedContinuation<ApprovalDecision, Error>
    }

    /// Stable process-wide owner for production policy composition. Tests and
    /// previews may create an isolated center with `init()`.
    static let shared = AgentApprovalPromptCenter()

    private(set) var pendingItem: PendingItem?
    private(set) var queuedRequestCount = 0

    @ObservationIgnored
    private var requests: [QueuedRequest] = []

    init() {}

    func requestDecision(
        for context: DurableApprovalPromptContext
    ) async throws -> ApprovalDecision {
        try await requestDecision(
            forSanitizedItem: try PendingItem(context: context)
        )
    }

    /// Internal continuation seam used by deterministic tests. This method is
    /// not an authorization surface: only `requestDecision(for:)`, invoked by
    /// AgentPolicy's sealed trusted UI authority, can mint a trusted decision.
    func requestDecision(
        forSanitizedItem item: PendingItem
    ) async throws -> ApprovalDecision {
        try Task.checkCancellation()
        let token = UUID()
        let decision = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ApprovalDecision, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                enqueue(
                    token: token,
                    item: item,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(token: token)
            }
        }
        // Cancellation may race a user's tap and win after the continuation
        // resumed. Never return executable approval to a cancelled caller.
        try Task.checkCancellation()
        return decision
    }

    @discardableResult
    func approve(requestID: ApprovalRequestID) -> SubmissionResult {
        submit(.approved, for: requestID)
    }

    @discardableResult
    func reject(requestID: ApprovalRequestID) -> SubmissionResult {
        submit(.rejected, for: requestID)
    }

    @discardableResult
    func submit(
        _ decision: ApprovalDecision,
        for requestID: ApprovalRequestID
    ) -> SubmissionResult {
        guard let current = requests.first else {
            return .noPendingRequest
        }
        guard current.item.requestID == requestID else {
            return .requestIDMismatch(expected: current.item.requestID)
        }

        requests.removeFirst()
        publishQueueState()
        current.continuation.resume(returning: decision)
        return .accepted
    }

    /// Cancels only the visible request and only when its durable identity
    /// matches. A stale UI action can never cancel a newer prompt.
    @discardableResult
    func cancelPending(
        requestID: ApprovalRequestID
    ) -> CancellationResult {
        guard let current = requests.first else {
            return .noPendingRequest
        }
        guard current.item.requestID == requestID else {
            return .requestIDMismatch(expected: current.item.requestID)
        }

        requests.removeFirst()
        publishQueueState()
        current.continuation.resume(throwing: CancellationError())
        return .cancelled
    }

    /// App-shutdown/ownership teardown hook. Every retained continuation is
    /// resumed exactly once before the queue is cleared.
    @discardableResult
    func cancelAllPending() -> Int {
        let cancelled = requests
        requests.removeAll(keepingCapacity: false)
        publishQueueState()
        cancelled.forEach {
            $0.continuation.resume(throwing: CancellationError())
        }
        return cancelled.count
    }

    private func enqueue(
        token: UUID,
        item: PendingItem,
        continuation: CheckedContinuation<ApprovalDecision, Error>
    ) {
        guard !requests.contains(where: {
            $0.item.requestID == item.requestID
        }) else {
            continuation.resume(throwing:
                AgentApprovalPromptCenterError.duplicateRequestID(
                    item.requestID
                )
            )
            return
        }

        requests.append(QueuedRequest(
            token: token,
            item: item,
            continuation: continuation
        ))
        publishQueueState()
    }

    private func cancelRequest(token: UUID) {
        guard let index = requests.firstIndex(where: { $0.token == token })
        else { return }
        let cancelled = requests.remove(at: index)
        publishQueueState()
        cancelled.continuation.resume(throwing: CancellationError())
    }

    private func publishQueueState() {
        pendingItem = requests.first?.item
        queuedRequestCount = max(0, requests.count - 1)
    }
}
