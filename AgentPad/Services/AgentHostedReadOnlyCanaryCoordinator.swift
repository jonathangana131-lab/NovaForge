#if DEBUG
import AgentDomain
import AgentEngine
import AgentProviders
import AgentShadow
import AgentStore
import AgentTools
import CryptoKit
import Darwin
import Foundation

enum AgentHostedReadOnlyCanaryCoordinatorError: Error, Equatable, Sendable {
    case invalidAcceptance
    case invalidCanaryFeatures
    case invalidRequest
    case routeMismatch
    case nonCanonicalToolCatalog
    case providerRoundLimitExceeded
    case providerOutputTooLarge
    case toolOutputTooLarge
    case duplicateProviderCallID
    case parallelToolCallRejected
    case unexpectedProviderEvent
    case missingProviderUsage
    case eventIdentityMismatch
    case duplicateProviderDispatch
    case unsafeRecoveryPrefix
    case workspaceMismatch
    case workspaceChanged
    case toolFailed
    case attemptFailed(AgentErrorInfo)
}

/// The app's separate package-minted hosted read-tools route. It cannot be
/// constructed from text-only authority and the live app intentionally limits
/// this milestone to the built-in Chat Completions adapter.
struct AgentHostedReadOnlyCanaryProvider: Sendable {
    let route: ProviderRoute
    let adapterID: ProviderAdapterID
    let capability: HostedReadOnlyToolsProviderCapability
    let catalog: ProviderAdapterCatalog

    init(
        trustedCatalog: TrustedHostedProviderCatalog,
        declaredRoute: ProviderRoute? = nil
    ) throws {
        let catalog = try trustedCatalog.providerCatalog()
        let adapterID = trustedCatalog.adapterID
        let adapter = try catalog.adapter(id: adapterID)
        let actualRoute = adapter.descriptor.route
        let route = declaredRoute ?? actualRoute
        let capability = try trustedCatalog.hostedReadOnlyToolsCapability(
            adapterID: adapterID
        )
        let snapshot = capability.snapshot
        guard adapter.descriptor.dialect == .openAIChatCompletions,
              route == actualRoute,
              route.providerID.rawValue == "openai",
              route.deployment == .hostedService,
              route.provenance == .builtInOpenAIChatCompletions,
              snapshot.providerID == route.providerID,
              snapshot.modelID == route.modelID,
              snapshot.adapterID == route.adapterID,
              snapshot.capabilities == route.capabilities,
              snapshot.maximumToolDefinitions == 12,
              snapshot.maximumToolCallsPerTurn == 1,
              !snapshot.parallelToolDispatchEnabled
        else {
            throw AgentHostedReadOnlyCanaryCoordinatorError.routeMismatch
        }
        self.route = route
        self.adapterID = adapterID
        self.capability = capability
        self.catalog = catalog
    }

    static func openAIChatCompletions(
        model: ProviderModelID
    ) throws -> Self {
        try Self(trustedCatalog: .openAIChatCompletions(
            model: model,
            capabilities: .hostedChatReadOnlyToolsCanaryBaseline
        ))
    }
}

enum AgentHostedReadOnlyCanaryBackendError: Error, Equatable, Sendable {
    case workspaceMismatch
    case workspaceChanged
    case workspaceTooLarge
}

/// The only app backend supplied to the package gateway. It owns no mutation
/// permit and calls `SandboxToolExecutor.execute(_:)`, whose public app seam
/// rejects every mutating legacy request. A bounded full-workspace digest is
/// checked around the read to turn accidental writes into a fail-closed error.
struct AgentHostedReadOnlyCanaryBackend:
    DeveloperReadOnlyCanaryToolBackend,
    Sendable
{
    let workspace: SandboxWorkspace
    let workspaceIdentity: WorkspaceResourceIdentity

    init(
        workspace: SandboxWorkspace,
        workspaceIdentity: WorkspaceResourceIdentity
    ) throws {
        guard try WorkspaceResourceIdentity(workspace: workspace) ==
                workspaceIdentity else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        self.workspace = workspace
        self.workspaceIdentity = workspaceIdentity
    }

    func executeReadOnly(
        _ request: LegacySandboxToolRequest
    ) async throws -> String {
        try Task.checkCancellation()
        guard try WorkspaceResourceIdentity(workspace: workspace) ==
                workspaceIdentity else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        let before = try Self.workspaceDigest(workspace)
        let output: String?
        let executionError: (any Error)?
        do {
            output = try SandboxToolExecutor(workspace: workspace).execute(
                ToolRequest(
                    id: "m5-read-only-canary",
                    name: request.name,
                    arguments: request.arguments
                )
            )
            executionError = nil
        } catch {
            output = nil
            executionError = error
        }
        // Cancellation or a rejected path must not skip the postcondition.
        // Detached hashing inherits no cancelled task state and owns no write
        // authority; the caller still observes cancellation after the proof.
        let workspaceSnapshot = workspace
        let after = try await Task.detached {
            try Self.workspaceDigest(workspaceSnapshot)
        }.value
        guard before == after else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceChanged
        }
        if let executionError { throw executionError }
        try Task.checkCancellation()
        guard let output else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        return output
    }

    typealias WorkspaceDigestTraversalHook = (
        _ parentComponents: [[UInt8]],
        _ entryName: [UInt8]
    ) throws -> Void

    static func workspaceDigest(
        _ workspace: SandboxWorkspace,
        willOpenEntry: WorkspaceDigestTraversalHook? = nil
    ) throws -> String {
        var walker = ReadOnlyWorkspaceDigestWalker(
            willOpenEntry: willOpenEntry
        )
        return try walker.digest(workspace)
    }
}

/// A deterministic, bounded workspace proof whose traversal never reopens a
/// descendant through an absolute path. Every child is inspected and opened
/// relative to an already-open, no-follow directory descriptor. Exact raw
/// filename bytes, file sizes, and per-file hashes give every entry an
/// unambiguous boundary in the top-level digest.
fileprivate struct ReadOnlyWorkspaceDigestWalker {
    private static let maximumEntries = 20_000
    private static let maximumBytes: Int64 = 128 * 1_024 * 1_024
    private static let maximumDepth = 256

    let willOpenEntry: AgentHostedReadOnlyCanaryBackend
        .WorkspaceDigestTraversalHook?

    init(
        willOpenEntry: AgentHostedReadOnlyCanaryBackend
            .WorkspaceDigestTraversalHook?
    ) {
        self.willOpenEntry = willOpenEntry
    }

    private var hasher = SHA256()
    private var entryCount = 0
    private var declaredBytes: Int64 = 0
    private var bytesActuallyRead: Int64 = 0

    mutating func digest(_ workspace: SandboxWorkspace) throws -> String {
        let root = try workspace.resolve("")
        guard root.path.utf8.allSatisfy({ $0 != 0 }) else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              Self.fileType(before) == mode_t(S_IFDIR) else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        updateField(Array("novaforge-m5-read-workspace-v2".utf8))
        updateEntry(
            tag: 0x44,
            components: [],
            status: before,
            contentSHA256: nil
        )
        try traverseDirectory(
            descriptor,
            components: [],
            openedStatus: before
        )

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Self.isStable(before, after),
              bytesActuallyRead == declaredBytes else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceChanged
        }
        return "sha256:" + hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }

    private mutating func traverseDirectory(
        _ directoryDescriptor: Int32,
        components: [[UInt8]],
        openedStatus: stat
    ) throws {
        try Task.checkCancellation()
        guard components.count <= Self.maximumDepth else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceTooLarge
        }
        let names = try Self.directoryEntryNames(
            directoryDescriptor,
            maximumCount: Self.maximumEntries - entryCount
        )
        let discoveredCount = entryCount.addingReportingOverflow(names.count)
        guard !discoveredCount.overflow,
              discoveredCount.partialValue <= Self.maximumEntries else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceTooLarge
        }
        entryCount = discoveredCount.partialValue
        for name in names {
            try Task.checkCancellation()
            var discovered = stat()
            let cName = name.map(Int8.init(bitPattern:)) + [0]
            let statusResult = cName.withUnsafeBufferPointer { pointer in
                Darwin.fstatat(
                    directoryDescriptor,
                    pointer.baseAddress!,
                    &discovered,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard statusResult == 0,
                  Self.fileType(discovered) != mode_t(S_IFLNK) else {
                throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
            }

            try willOpenEntry?(components, name)
            let type = Self.fileType(discovered)
            let flags: Int32
            if type == mode_t(S_IFDIR) {
                flags = O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
            } else if type == mode_t(S_IFREG) {
                flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            } else {
                throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
            }
            let childDescriptor = cName.withUnsafeBufferPointer { pointer in
                Darwin.openat(
                    directoryDescriptor,
                    pointer.baseAddress!,
                    flags
                )
            }
            guard childDescriptor >= 0 else {
                throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
            }
            defer { Darwin.close(childDescriptor) }

            var opened = stat()
            guard Darwin.fstat(childDescriptor, &opened) == 0,
                  Self.sameNode(discovered, opened),
                  Self.fileType(opened) == type else {
                throw AgentHostedReadOnlyCanaryBackendError.workspaceChanged
            }
            let path = components + [name]
            if type == mode_t(S_IFDIR) {
                updateEntry(
                    tag: 0x44,
                    components: path,
                    status: opened,
                    contentSHA256: nil
                )
                try traverseDirectory(
                    childDescriptor,
                    components: path,
                    openedStatus: opened
                )
            } else {
                try hashFile(
                    childDescriptor,
                    components: path,
                    openedStatus: opened
                )
            }
        }

        var after = stat()
        guard Darwin.fstat(directoryDescriptor, &after) == 0,
              Self.isStable(openedStatus, after) else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceChanged
        }
    }

    private mutating func hashFile(
        _ descriptor: Int32,
        components: [[UInt8]],
        openedStatus: stat
    ) throws {
        guard openedStatus.st_size >= 0 else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        let expectedBytes = Int64(openedStatus.st_size)
        declaredBytes = try Self.addBounded(
            expectedBytes,
            to: declaredBytes
        )

        var fileDigest = SHA256()
        var fileBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress!,
                    bytes.count
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
            }
            guard count > 0 else { break }
            fileBytes = try Self.addBounded(Int64(count), to: fileBytes)
            bytesActuallyRead = try Self.addBounded(
                Int64(count),
                to: bytesActuallyRead
            )
            fileDigest.update(data: Data(buffer.prefix(count)))
        }

        var after = stat()
        guard fileBytes == expectedBytes,
              Darwin.fstat(descriptor, &after) == 0,
              Self.isStable(openedStatus, after) else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceChanged
        }
        updateEntry(
            tag: 0x46,
            components: components,
            status: openedStatus,
            contentSHA256: Array(fileDigest.finalize())
        )
    }

    private mutating func updateEntry(
        tag: UInt8,
        components: [[UInt8]],
        status: stat,
        contentSHA256: [UInt8]?
    ) {
        hasher.update(data: Data([tag]))
        updateInteger(UInt64(components.count))
        for component in components { updateField(component) }
        // Identity and change-time metadata bridge the two independent
        // traversals around the legacy path-based read. A node that is
        // swapped away and restored with identical bytes retains its inode,
        // but the rename mutates ctime on that node or one of its parents.
        updateSigned(Int64(status.st_dev))
        updateInteger(UInt64(status.st_ino))
        updateInteger(UInt64(status.st_mode))
        updateSigned(Int64(status.st_size))
        updateSigned(Int64(status.st_mtimespec.tv_sec))
        updateSigned(Int64(status.st_mtimespec.tv_nsec))
        updateSigned(Int64(status.st_ctimespec.tv_sec))
        updateSigned(Int64(status.st_ctimespec.tv_nsec))
        if let contentSHA256 { updateField(contentSHA256) }
    }

    private mutating func updateField(_ bytes: [UInt8]) {
        updateInteger(UInt64(bytes.count))
        hasher.update(data: Data(bytes))
    }

    private mutating func updateInteger(_ value: UInt64) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { bytes in
            hasher.update(data: Data(bytes))
        }
    }

    private mutating func updateSigned(_ value: Int64) {
        updateInteger(UInt64(bitPattern: value))
    }

    private static func directoryEntryNames(
        _ descriptor: Int32,
        maximumCount: Int
    ) throws -> [[UInt8]] {
        guard maximumCount >= 0 else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceTooLarge
        }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        defer { Darwin.closedir(directory) }

        var names: [[UInt8]] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else {
                    throw AgentHostedReadOnlyCanaryBackendError
                        .workspaceMismatch
                }
                break
            }
            var storage = entry.pointee.d_name
            let name = withUnsafeBytes(of: &storage) { bytes -> [UInt8] in
                let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
                return Array(bytes[..<end])
            }
            guard !name.isEmpty else {
                throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
            }
            if name == [0x2e] || name == [0x2e, 0x2e] { continue }
            guard names.count < maximumCount else {
                throw AgentHostedReadOnlyCanaryBackendError.workspaceTooLarge
            }
            names.append(name)
        }
        names.sort { $0.lexicographicallyPrecedes($1) }
        return names
    }

    private static func addBounded(
        _ value: Int64,
        to total: Int64
    ) throws -> Int64 {
        guard value >= 0 else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceMismatch
        }
        let addition = total.addingReportingOverflow(value)
        guard !addition.overflow,
              addition.partialValue <= maximumBytes else {
            throw AgentHostedReadOnlyCanaryBackendError.workspaceTooLarge
        }
        return addition.partialValue
    }

    private static func fileType(_ value: stat) -> mode_t {
        value.st_mode & mode_t(S_IFMT)
    }

    private static func sameNode(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            fileType(lhs) == fileType(rhs)
    }

    private static func isStable(_ lhs: stat, _ rhs: stat) -> Bool {
        sameNode(lhs, rhs) &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}


struct AgentHostedReadOnlyCanaryCoordinator: Sendable {
    static let engineVersion = AgentHostedTextCanaryCoordinator.engineVersion
    static let featureSet = AgentFeatureSet([
        "v2DarkReplay",
        "v2HostedText",
        "v2ReadTools",
    ])
    static let maximumToolRounds = 4
    static let maximumProviderRounds = maximumToolRounds + 1
    static let maximumProviderTextBytes = 512 * 1_024
    static let maximumToolOutputBytes = 256 * 1_024
    static let maximumCumulativeToolOutputBytes = 512 * 1_024

    private let journal: any AgentEventJournal
    private let provider: AgentHostedReadOnlyCanaryProvider
    private let transport: any ProviderTransport
    private let registry: ToolRegistry
    private let descriptors: [ToolDescriptor]
    private let backend: any DeveloperReadOnlyCanaryToolBackend
    private let boundWorkspaceID: WorkspaceID

    init(
        journal: any AgentEventJournal,
        provider: AgentHostedReadOnlyCanaryProvider,
        transport: any ProviderTransport,
        backend: any DeveloperReadOnlyCanaryToolBackend,
        boundWorkspaceID: WorkspaceID
    ) throws {
        let registry = try SandboxToolCatalog.canonicalRegistry()
        let descriptors = SandboxToolCatalog.all.map(\.descriptor).filter {
            $0.effectClass == .readOnlyLocal
        }
        guard descriptors.count == 12,
              Set(descriptors.map(\.name)) == Self.canonicalToolNames,
              descriptors.allSatisfy({
                  $0.effectClass == .readOnlyLocal &&
                    $0.approvalClass == .none
              }) else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .nonCanonicalToolCatalog
        }
        self.journal = journal
        self.provider = provider
        self.transport = transport
        self.registry = registry
        self.descriptors = descriptors
        self.backend = backend
        self.boundWorkspaceID = boundWorkspaceID
    }

    func execute(
        acceptedRun acceptance: AgentRunAcceptance,
        request: CanonicalProviderRequest,
        capturedContext: AgentHostedTextCanaryCapturedContext? = nil
    ) async throws -> AgentHostedTextCanaryResult {
        try Task.checkCancellation()
        try validateAcceptedRun(
            acceptance,
            request: request,
            capturedContext: capturedContext
        )
        try await verifyDurableAcceptance(acceptance)

        // Freeze authority from the immutable acceptance prefix. Recovery may
        // occur after later lifecycle events, but those events must never
        // silently remint a different tool-policy configuration.
        let acceptedPrefix = AcceptedRunReplayReader(
            journal: journal,
            acceptance: acceptance
        )
        let attestation = try await DarkReplayEngine(
            reader: acceptedPrefix
        ).attest(acceptance.metadata.runID)
        let policy = try await DeveloperReadOnlyCanaryPolicy.freeze(
            for: attestation,
            hostedReadOnlyToolsCapability: provider.capability,
            tools: descriptors
        )
        try policy.validateFrozenInputs(
            runID: acceptance.metadata.runID,
            hostedReadOnlyToolsCapability: provider.capability,
            features: acceptance.metadata.context.features
        )
        let toolGateway = DeveloperReadOnlyCanaryToolGateway(
            policy: policy,
            registry: registry,
            backend: backend
        )

        var ledger = try await loadLedger(acceptance)
        if ledger.state.phase == .accepted {
            _ = try await appendRunStarted(
                acceptance,
                cursor: ledger.cursor
            )
            ledger = try await loadLedger(acceptance)
        }
        guard ledger.state.phase == .running,
              ledger.state.activeAttemptID == nil,
              ledger.state.scheduledAttemptID == nil else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unsafeRecoveryPrefix
        }

        var recovery = try recoverTranscript(
            request: request,
            ledger: ledger,
            gateway: toolGateway
        )
        if let final = recovery.finalResult { return final }

        var cursor = ledger.cursor
        if let pending = recovery.pendingTool {
            let completion = try await resumeOrExecute(
                pending,
                acceptance: acceptance,
                gateway: toolGateway,
                cursor: cursor
            )
            cursor = completion.cursor
            recovery.messages.append(contentsOf: completion.messages)
            recovery.completedToolRounds += 1
            recovery.cumulativeToolOutputBytes += completion.outputByteCount
        }

        guard recovery.completedToolRounds <= Self.maximumToolRounds,
              recovery.cumulativeToolOutputBytes <=
                Self.maximumCumulativeToolOutputBytes else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .toolOutputTooLarge
        }

        var seenProviderCallIDs = recovery.seenProviderCallIDs
        while true {
            try Task.checkCancellation()
            let providerRound = recovery.completedProviderRounds + 1
            guard providerRound <= Self.maximumProviderRounds else {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .providerRoundLimitExceeded
            }
            let roundRequest = CanonicalProviderRequest(
                requestID: request.requestID,
                model: request.model,
                messages: recovery.messages,
                tools: request.tools,
                options: request.options,
                metadata: request.metadata
            )
            let outcome = try await executeProviderRound(
                providerRound,
                acceptance: acceptance,
                request: roundRequest,
                cursor: cursor,
                gateway: toolGateway,
                seenProviderCallIDs: seenProviderCallIDs
            )
            cursor = outcome.cursor
            recovery.completedProviderRounds += 1

            switch outcome.value {
            case let .final(result):
                return result
            case let .tool(prepared):
                guard recovery.completedToolRounds < Self.maximumToolRounds else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .providerRoundLimitExceeded
                }
                guard let rawCallID = prepared.invocation.providerCallID,
                      seenProviderCallIDs.insert(rawCallID).inserted else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .duplicateProviderCallID
                }
                let completion = try await executePreparedTool(
                    prepared,
                    acceptance: acceptance,
                    gateway: toolGateway,
                    cursor: cursor,
                    existingStatus: nil
                )
                cursor = completion.cursor
                recovery.messages.append(contentsOf: completion.messages)
                recovery.completedToolRounds += 1
                recovery.cumulativeToolOutputBytes += completion.outputByteCount
                guard recovery.cumulativeToolOutputBytes <=
                        Self.maximumCumulativeToolOutputBytes else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .toolOutputTooLarge
                }
            }
        }
    }

    private func validateAcceptedRun(
        _ acceptance: AgentRunAcceptance,
        request: CanonicalProviderRequest,
        capturedContext: AgentHostedTextCanaryCapturedContext?
    ) throws {
        do {
            _ = try AgentJournalValidation.validateAcceptance(acceptance)
        } catch {
            throw AgentHostedReadOnlyCanaryCoordinatorError.invalidAcceptance
        }
        let context = acceptance.metadata.context
        guard context.schemaVersion == .v1_1,
              context.engineVersion == Self.engineVersion,
              context.features == Self.featureSet,
              context.workspaceID == boundWorkspaceID else {
            throw context.workspaceID == boundWorkspaceID
                ? AgentHostedReadOnlyCanaryCoordinatorError.invalidCanaryFeatures
                : AgentHostedReadOnlyCanaryCoordinatorError.workspaceMismatch
        }
        let expectedDefinitions = descriptors.map {
            Self.providerDefinition(for: $0)
        }
        guard request.model == provider.route.modelID,
              Self.isSafeRequestIdentity(request.requestID),
              request.tools == expectedDefinitions,
              request.options.parallelToolCalls == false,
              request.options.toolChoice == .auto,
              request.options.reasoningSummary != true,
              request.options.previousResponseID == nil,
              request.messages.allSatisfy(Self.isCanonicalInitialMessage),
              !request.messages.contains(where: Self.isToolBearing)
        else {
            throw AgentHostedReadOnlyCanaryCoordinatorError.invalidRequest
        }
        guard let acceptedUser = Self.acceptedUser(from: acceptance) else {
            throw AgentHostedReadOnlyCanaryCoordinatorError.invalidRequest
        }
        if let capturedContext {
            guard capturedContext.validates(
                providerMessages: request.messages,
                acceptedUserItemID: acceptedUser.itemID,
                acceptedUserOriginalText: acceptedUser.text
            ) else {
                throw AgentHostedReadOnlyCanaryCoordinatorError.invalidRequest
            }
        } else {
            guard let last = request.messages.last,
                  last.role == .user,
                  last.content == [.text(acceptedUser.text)] else {
                throw AgentHostedReadOnlyCanaryCoordinatorError.invalidRequest
            }
        }
    }

    private func verifyDurableAcceptance(
        _ acceptance: AgentRunAcceptance
    ) async throws {
        guard let metadata = try await journal.metadata(
            for: acceptance.metadata.runID
        ), metadata == acceptance.metadata,
              try await journal.events(
                  for: acceptance.metadata.runID,
                  after: nil
              ).first?.envelope == acceptance.envelope else {
            throw AgentHostedReadOnlyCanaryCoordinatorError.invalidAcceptance
        }
    }

    private func loadLedger(
        _ acceptance: AgentRunAcceptance
    ) async throws -> ReadOnlyCanaryLedger {
        let records = try await journal.events(
            for: acceptance.metadata.runID,
            after: nil
        )
        guard records.first?.envelope == acceptance.envelope,
              let last = records.last else {
            throw AgentHostedReadOnlyCanaryCoordinatorError.invalidAcceptance
        }
        let state = try AgentJournalReplay.replay(
            records,
            metadata: acceptance.metadata
        )
        return ReadOnlyCanaryLedger(
            records: records,
            state: state,
            cursor: ReadOnlyCanaryCursor(
                sequence: last.event.header.sequence,
                eventID: last.event.header.eventID
            )
        )
    }

    private func appendRunStarted(
        _ acceptance: AgentRunAcceptance,
        cursor: ReadOnlyCanaryCursor
    ) async throws -> ReadOnlyCanaryAppend {
        try await append(
            acceptance: acceptance,
            cursor: cursor,
            idempotencyKey: "m5-read-canary:run-started:v1",
            eventDomain: "m5-read-canary-run-started",
            eventMaterial: acceptance.metadata.runID.description,
            payload: .runStarted(RunStartedEvent())
        )
    }

    private func recoverTranscript(
        request: CanonicalProviderRequest,
        ledger: ReadOnlyCanaryLedger,
        gateway: DeveloperReadOnlyCanaryToolGateway
    ) throws -> ReadOnlyCanaryRecovery {
        var messages = request.messages
        var seenProviderCallIDs: Set<String> = []
        var pending: ReadOnlyPendingTool?
        var final: AgentHostedTextCanaryResult?
        var completedToolRounds = 0
        var completedProviderRounds = 0
        var cumulativeOutputBytes = 0

        for record in ledger.records {
            guard case let .modelResponseCommitted(response) =
                    record.event.payload else { continue }
            completedProviderRounds += 1
            let expectedScope = Self.scope(
                requestID: Self.runBoundRequestID(
                    request.requestID,
                    runID: record.runID
                ),
                round: completedProviderRounds
            )
            guard response.attemptID == Self.attemptID(
                scope: expectedScope,
                runID: record.runID
            ) else {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .unsafeRecoveryPrefix
            }
            let invocations = response.items.compactMap { item -> ToolInvocation? in
                guard case let .toolInvocation(value) = item.payload else {
                    return nil
                }
                return value
            }
            let assistantMessages = response.items.compactMap { item -> ModelMessage? in
                guard case let .message(value) = item.payload else { return nil }
                return value
            }
            if response.finishReason == .toolCalls {
                guard response.items.count == 1,
                      invocations.count == 1,
                      assistantMessages.isEmpty,
                      let invocation = invocations.first,
                      let rawCallID = invocation.providerCallID,
                      invocation.modelAttemptID == response.attemptID,
                      response.items[0].id == ModelItemID(rawValue:
                          Self.stableUUID(
                              domain: "m5-read-canary-tool-invocation-item",
                              material: record.runID.description + "|" +
                                  String(completedProviderRounds)
                          )
                      ),
                      response.items[0].createdAt ==
                        record.event.header.timestamp,
                      seenProviderCallIDs.insert(rawCallID).inserted,
                      pending == nil else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .unsafeRecoveryPrefix
                }
                let prepared = try gateway.prepare(
                    DeveloperReadOnlyCanaryToolRequest(
                        runID: record.runID,
                        callID: invocation.callID,
                        providerCallID: rawCallID,
                        modelAttemptID: invocation.modelAttemptID,
                        toolName: invocation.tool.name,
                        toolVersion: invocation.tool.version,
                        arguments: invocation.arguments
                    )
                )
                guard prepared.invocation == invocation else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .unsafeRecoveryPrefix
                }
                let state = ledger.state.tools.first {
                    $0.invocation.callID == invocation.callID
                }
                if let result = state?.result {
                    if result.status == .cancelled {
                        throw CancellationError()
                    }
                    guard state?.status == .completed,
                          result.status == .succeeded,
                          case let .string(output) = result.output,
                          output.utf8.count <= Self.maximumToolOutputBytes,
                          result == Self.toolResult(
                              invocation: invocation,
                              output: output,
                              status: .succeeded,
                              error: nil
                          ) else {
                        throw AgentHostedReadOnlyCanaryCoordinatorError.toolFailed
                    }
                    messages.append(contentsOf: Self.providerToolMessages(
                        invocation: invocation,
                        output: output
                    ))
                    completedToolRounds += 1
                    cumulativeOutputBytes += output.utf8.count
                } else {
                    pending = ReadOnlyPendingTool(
                        invocation: invocation,
                        status: state?.status
                    )
                }
                continue
            }

            guard invocations.isEmpty,
                  response.finishReason != .cancelled,
                  response.items.count == assistantMessages.count,
                  assistantMessages.count <= 1,
                  assistantMessages.allSatisfy(Self.isCanonicalFinalMessage),
                  final == nil else {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .unsafeRecoveryPrefix
            }
            if let item = response.items.first {
                guard item.id == ModelItemID(rawValue: Self.stableUUID(
                    domain: "m5-read-canary-final-message",
                    material: record.runID.description + "|" +
                        String(completedProviderRounds)
                )), item.createdAt == record.event.header.timestamp else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .unsafeRecoveryPrefix
                }
            }
            final = AgentHostedTextCanaryResult(
                scope: Self.scope(
                    requestID: Self.runBoundRequestID(
                        request.requestID,
                        runID: ledger.records[0].runID
                    ),
                    round: completedProviderRounds
                ),
                attemptID: response.attemptID,
                items: response.items,
                usage: response.usage,
                finishReason: response.finishReason,
                terminalCommit: AgentJournalCommit(
                    disposition: .alreadyCommitted,
                    record: record
                )
            )
        }
        guard pending == nil || final == nil else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unsafeRecoveryPrefix
        }
        return ReadOnlyCanaryRecovery(
            messages: messages,
            seenProviderCallIDs: seenProviderCallIDs,
            pendingTool: pending,
            finalResult: final,
            completedToolRounds: completedToolRounds,
            completedProviderRounds: completedProviderRounds,
            cumulativeToolOutputBytes: cumulativeOutputBytes
        )
    }

    private func resumeOrExecute(
        _ pending: ReadOnlyPendingTool,
        acceptance: AgentRunAcceptance,
        gateway: DeveloperReadOnlyCanaryToolGateway,
        cursor: ReadOnlyCanaryCursor
    ) async throws -> ReadOnlyToolCompletion {
        guard let providerCallID = pending.invocation.providerCallID else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unsafeRecoveryPrefix
        }
        let prepared = try gateway.prepare(
            DeveloperReadOnlyCanaryToolRequest(
                runID: acceptance.metadata.runID,
                callID: pending.invocation.callID,
                providerCallID: providerCallID,
                modelAttemptID: pending.invocation.modelAttemptID,
                toolName: pending.invocation.tool.name,
                toolVersion: pending.invocation.tool.version,
                arguments: pending.invocation.arguments
            )
        )
        guard prepared.invocation == pending.invocation else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unsafeRecoveryPrefix
        }
        return try await executePreparedTool(
            prepared,
            acceptance: acceptance,
            gateway: gateway,
            cursor: cursor,
            existingStatus: pending.status
        )
    }

    private func executePreparedTool(
        _ prepared: PreparedDeveloperReadOnlyCanaryToolInvocation,
        acceptance: AgentRunAcceptance,
        gateway: DeveloperReadOnlyCanaryToolGateway,
        cursor initialCursor: ReadOnlyCanaryCursor,
        existingStatus: ToolExecutionStatus?
    ) async throws -> ReadOnlyToolCompletion {
        var cursor = initialCursor
        var status = existingStatus
        if status == nil {
            let appended = try await append(
                acceptance: acceptance,
                cursor: cursor,
                idempotencyKey: "m5-read-canary:tool-proposed:\(prepared.invocation.idempotencyKey)",
                eventDomain: "m5-read-canary-tool-proposed",
                eventMaterial: prepared.invocation.idempotencyKey,
                payload: .toolProposed(ToolProposedEvent(
                    invocation: prepared.invocation
                ))
            )
            cursor = appended.cursor
            status = .proposed
        }
        if status == .proposed {
            let appended = try await append(
                acceptance: acceptance,
                cursor: cursor,
                idempotencyKey: "m5-read-canary:tool-scheduled:\(prepared.invocation.idempotencyKey)",
                eventDomain: "m5-read-canary-tool-scheduled",
                eventMaterial: prepared.invocation.idempotencyKey,
                payload: .toolScheduled(ToolScheduledEvent(
                    callID: prepared.invocation.callID,
                    effect: nil
                ))
            )
            cursor = appended.cursor
            status = .scheduled
        }
        if status == .scheduled {
            let appended = try await append(
                acceptance: acceptance,
                cursor: cursor,
                idempotencyKey: "m5-read-canary:tool-started:\(prepared.invocation.idempotencyKey)",
                eventDomain: "m5-read-canary-tool-started",
                eventMaterial: prepared.invocation.idempotencyKey,
                payload: .toolStarted(ToolStartedEvent(
                    callID: prepared.invocation.callID,
                    effect: nil
                ))
            )
            cursor = appended.cursor
            status = .running
        }
        guard status == .running else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unsafeRecoveryPrefix
        }

        let execution: DeveloperReadOnlyCanaryToolExecution
        do {
            execution = try await gateway.execute(prepared)
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError ||
                error as? DeveloperReadOnlyCanaryToolGatewayError == .cancelled
            let info = AgentErrorInfo(
                category: cancelled ? .cancelled : .tool,
                code: cancelled
                    ? "hosted_read_tool_cancelled"
                    : "hosted_read_tool_failed",
                publicMessage: cancelled
                    ? "The read-only tool was cancelled."
                    : "The read-only tool failed safely.",
                retryable: false
            )
            let result = Self.toolResult(
                invocation: prepared.invocation,
                output: "",
                status: cancelled ? .cancelled : .failed,
                error: cancelled ? nil : info
            )
            _ = try await appendToolCompletionDetached(
                result,
                acceptance: acceptance,
                cursor: cursor,
                idempotencyKey: prepared.invocation.idempotencyKey
            )
            if cancelled { throw CancellationError() }
            throw AgentHostedReadOnlyCanaryCoordinatorError.toolFailed
        }
        guard execution.outputByteCount <= Self.maximumToolOutputBytes else {
            let info = AgentErrorInfo(
                category: .tool,
                code: "hosted_read_tool_output_too_large",
                publicMessage: "The read-only tool returned too much output.",
                retryable: false
            )
            let result = Self.toolResult(
                invocation: prepared.invocation,
                output: "",
                status: .failed,
                error: info
            )
            _ = try await appendToolCompletionDetached(
                result,
                acceptance: acceptance,
                cursor: cursor,
                idempotencyKey: prepared.invocation.idempotencyKey
            )
            throw AgentHostedReadOnlyCanaryCoordinatorError.toolOutputTooLarge
        }
        let result = Self.toolResult(
            invocation: prepared.invocation,
            output: execution.output,
            status: .succeeded,
            error: nil
        )
        let appended = try await appendToolCompletionDetached(
            result,
            acceptance: acceptance,
            cursor: cursor,
            idempotencyKey: prepared.invocation.idempotencyKey
        )
        return ReadOnlyToolCompletion(
            cursor: appended.cursor,
            messages: Self.providerToolMessages(
                invocation: prepared.invocation,
                output: execution.output
            ),
            outputByteCount: execution.outputByteCount
        )
    }

    private func executeProviderRound(
        _ round: Int,
        acceptance: AgentRunAcceptance,
        request: CanonicalProviderRequest,
        cursor: ReadOnlyCanaryCursor,
        gateway toolGateway: DeveloperReadOnlyCanaryToolGateway,
        seenProviderCallIDs: Set<String>
    ) async throws -> ReadOnlyProviderRoundOutcome {
        let runID = acceptance.metadata.runID
        let wireRequestID = Self.runBoundRequestID(
            request.requestID,
            runID: runID
        )
        let wireRequest = CanonicalProviderRequest(
            requestID: wireRequestID,
            model: request.model,
            messages: request.messages,
            tools: request.tools,
            options: request.options,
            metadata: request.metadata
        )
        let scope = Self.scope(requestID: wireRequestID, round: round)
        let attemptID = Self.attemptID(scope: scope, runID: runID)
        guard let ordinal = UInt32(exactly: round) else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .providerRoundLimitExceeded
        }
        guard let requestSequence = cursor.sequence.successor else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unsafeRecoveryPrefix
        }
        let dispatchState = ReadOnlyProviderDispatchState()
        let barrier = DurableReadOnlyProviderAttemptBarrier(
            journal: journal,
            acceptance: acceptance,
            expectedScope: scope,
            expectedRoute: provider.route,
            expectedRequestPath: provider.capability.snapshot.requestPath,
            attemptID: attemptID,
            ordinal: ordinal,
            sequence: requestSequence,
            causationEventID: cursor.eventID,
            state: dispatchState
        )
        let modelGateway = ModelGateway(
            catalog: provider.catalog,
            transport: transport
        )

        let collected: ReadOnlyCollectedProviderAttempt
        do {
            let stream = await modelGateway.streamAttempt(
                ProviderSingleAttemptInvocation(
                    request: wireRequest,
                    adapterID: provider.adapterID,
                    scope: scope,
                    barrier: barrier
                )
            )
            collected = try await Self.collect(
                stream,
                expectedScope: scope
            )
        } catch {
            guard let dispatch = await dispatchState.snapshot() else {
                throw error
            }
            let info = Self.sanitizedFailure(error)
            let failed = try await appendAttemptFailureDetached(
                acceptance: acceptance,
                cursor: dispatch.cursor,
                attemptID: attemptID,
                scope: scope,
                failure: info
            )
            _ = failed
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .attemptFailed(info)
        }
        guard let dispatch = await dispatchState.snapshot() else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unexpectedProviderEvent
        }
        guard let responseSequence = dispatch.cursor.sequence.successor else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unsafeRecoveryPrefix
        }

        do {
        switch collected.value {
        case let .tool(call):
            guard !seenProviderCallIDs.contains(call.callID) else {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .duplicateProviderCallID
            }
            let descriptor: ToolDescriptor
            do {
                descriptor = try registry.descriptor(named: call.name)
            } catch {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .nonCanonicalToolCatalog
            }
            let prepared: PreparedDeveloperReadOnlyCanaryToolInvocation
            do {
                prepared = try toolGateway.prepare(
                    DeveloperReadOnlyCanaryToolRequest(
                        runID: runID,
                        callID: ToolCallID(rawValue: Self.stableUUID(
                            domain: "m5-read-canary-tool-call",
                            material: runID.description + "|" +
                                String(round) + "|" + call.callID
                        )),
                        providerCallID: call.callID,
                        modelAttemptID: attemptID,
                        toolName: call.name,
                        toolVersion: descriptor.version.description,
                        arguments: call.arguments
                    )
                )
            } catch {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .nonCanonicalToolCatalog
            }
            guard prepared.invocation.providerCallID == call.callID,
                  prepared.invocation.hasCanonicalProviderCallID else {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .duplicateProviderCallID
            }
            let item = ModelItem(
                id: ModelItemID(rawValue: Self.stableUUID(
                    domain: "m5-read-canary-tool-invocation-item",
                    material: runID.description + "|" + String(round)
                )),
                createdAt: Self.eventTimestamp(
                    acceptance,
                    sequence: responseSequence
                ),
                payload: .toolInvocation(prepared.invocation)
            )
            let appended = try await append(
                acceptance: acceptance,
                cursor: dispatch.cursor,
                idempotencyKey: Self.responseIdempotencyKey(
                    scope: scope,
                    outcome: "tool"
                ),
                eventDomain: "m5-read-canary-provider-tool-response",
                eventMaterial: runID.description + "|" +
                    scope.attemptID.rawValue,
                payload: .modelResponseCommitted(
                    ModelResponseCommittedEvent(
                        attemptID: attemptID,
                        items: [item],
                        usage: collected.usage.modelUsage,
                        finishReason: .toolCalls
                    )
                )
            )
            return ReadOnlyProviderRoundOutcome(
                value: .tool(prepared),
                cursor: appended.cursor
            )

        case let .final(text, finishReason):
            let items: [ModelItem]
            if text.isEmpty {
                items = []
            } else {
                items = [ModelItem(
                    id: ModelItemID(rawValue: Self.stableUUID(
                        domain: "m5-read-canary-final-message",
                        material: runID.description + "|" + String(round)
                    )),
                    createdAt: Self.eventTimestamp(
                        acceptance,
                        sequence: responseSequence
                    ),
                    payload: .message(ModelMessage(
                        role: .assistant,
                        content: [.text(text)]
                    ))
                )]
            }
            let appended = try await append(
                acceptance: acceptance,
                cursor: dispatch.cursor,
                idempotencyKey: Self.responseIdempotencyKey(
                    scope: scope,
                    outcome: "final"
                ),
                eventDomain: "m5-read-canary-provider-final-response",
                eventMaterial: runID.description + "|" +
                    scope.attemptID.rawValue,
                payload: .modelResponseCommitted(
                    ModelResponseCommittedEvent(
                        attemptID: attemptID,
                        items: items,
                        usage: collected.usage.modelUsage,
                        finishReason: finishReason
                    )
                )
            )
            let result = AgentHostedTextCanaryResult(
                scope: scope,
                attemptID: attemptID,
                items: items,
                usage: collected.usage.modelUsage,
                finishReason: finishReason,
                terminalCommit: appended.commit
            )
            return ReadOnlyProviderRoundOutcome(
                value: .final(result),
                cursor: appended.cursor
            )
        }
        } catch {
            let info = Self.sanitizedFailure(error)
            _ = try await appendAttemptFailureDetached(
                acceptance: acceptance,
                cursor: dispatch.cursor,
                attemptID: attemptID,
                scope: scope,
                failure: info
            )
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .attemptFailed(info)
        }
    }

    private static func collect(
        _ stream: AsyncThrowingStream<ProviderAttemptEvent, any Error>,
        expectedScope: ProviderAttemptScope
    ) async throws -> ReadOnlyCollectedProviderAttempt {
        var responseStarted = false
        var text = ""
        var callStart: ProviderToolCallStart?
        var callCompletion: ProviderToolCallCompletion?
        var usage: ProviderUsage?
        var finishReason: ModelFinishReason?

        for try await envelope in stream {
            guard envelope.scope == expectedScope else {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .unexpectedProviderEvent
            }
            switch envelope.event {
            case .responseStarted:
                guard !responseStarted else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .unexpectedProviderEvent
                }
                responseStarted = true
            case let .textDelta(delta):
                guard delta.outputIndex == 0,
                      callStart == nil,
                      callCompletion == nil else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .unexpectedProviderEvent
                }
                text.append(delta.text)
                guard text.utf8.count <= Self.maximumProviderTextBytes else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .providerOutputTooLarge
                }
            case let .toolCallStarted(start):
                guard start.outputIndex == 0,
                      callStart == nil,
                      callCompletion == nil,
                      text.isEmpty else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .parallelToolCallRejected
                }
                callStart = start
            case let .toolCallArgumentsDelta(delta):
                guard let callStart,
                      delta.outputIndex == 0,
                      delta.callID == callStart.callID,
                      callCompletion == nil else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .parallelToolCallRejected
                }
            case let .toolCallCompleted(completion):
                guard let callStart,
                      completion.outputIndex == 0,
                      completion.callID == callStart.callID,
                      completion.name == callStart.name,
                      callCompletion == nil,
                      text.isEmpty else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .parallelToolCallRejected
                }
                callCompletion = completion
            case let .usage(value):
                guard usage == nil else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .unexpectedProviderEvent
                }
                usage = value
            case let .responseCompleted(value):
                guard finishReason == nil,
                      value.finishReason != .cancelled else {
                    throw AgentHostedReadOnlyCanaryCoordinatorError
                        .unexpectedProviderEvent
                }
                finishReason = value.finishReason
            case .reasoningDelta:
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .unexpectedProviderEvent
            case .cancelled:
                throw CancellationError()
            }
        }
        guard responseStarted,
              let usage,
              let finishReason else {
            throw usage == nil
                ? AgentHostedReadOnlyCanaryCoordinatorError.missingProviderUsage
                : AgentHostedReadOnlyCanaryCoordinatorError.unexpectedProviderEvent
        }
        if let callCompletion {
            guard callStart != nil,
                  finishReason == .toolCalls else {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .unexpectedProviderEvent
            }
            return ReadOnlyCollectedProviderAttempt(
                value: .tool(callCompletion),
                usage: usage
            )
        }
        guard callStart == nil,
              finishReason != .toolCalls else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unexpectedProviderEvent
        }
        return ReadOnlyCollectedProviderAttempt(
            value: .final(text: text, finishReason: finishReason),
            usage: usage
        )
    }

    private func append(
        acceptance: AgentRunAcceptance,
        cursor: ReadOnlyCanaryCursor,
        idempotencyKey: String,
        eventDomain: String,
        eventMaterial: String,
        payload: AgentEventPayload
    ) async throws -> ReadOnlyCanaryAppend {
        guard let sequence = cursor.sequence.successor else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .unsafeRecoveryPrefix
        }
        let envelope = AgentHostedTextCanaryCoordinator.envelope(
            acceptance: acceptance,
            sequence: sequence,
            idempotencyKey: idempotencyKey,
            eventDomain: eventDomain,
            eventMaterial: eventMaterial,
            timestamp: Self.eventTimestamp(acceptance, sequence: sequence),
            causationEventID: cursor.eventID,
            payload: payload
        )
        let commit = try await Self.appendOrRecover(
            envelope,
            journal: journal
        )
        guard commit.record.envelope == envelope else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .eventIdentityMismatch
        }
        return ReadOnlyCanaryAppend(
            commit: commit,
            cursor: ReadOnlyCanaryCursor(
                sequence: sequence,
                eventID: envelope.event.header.eventID
            )
        )
    }

    private func appendToolCompletionDetached(
        _ result: ToolResult,
        acceptance: AgentRunAcceptance,
        cursor: ReadOnlyCanaryCursor,
        idempotencyKey: String
    ) async throws -> ReadOnlyCanaryAppend {
        let coordinator = self
        return try await Task.detached {
            try await coordinator.append(
                acceptance: acceptance,
                cursor: cursor,
                idempotencyKey: "m5-read-canary:tool-completed:\(idempotencyKey)",
                eventDomain: "m5-read-canary-tool-completed",
                eventMaterial: idempotencyKey + "|" + result.status.rawValue,
                payload: .toolCompleted(ToolCompletedEvent(
                    result: result,
                    effect: nil
                ))
            )
        }.value
    }

    private func appendAttemptFailureDetached(
        acceptance: AgentRunAcceptance,
        cursor: ReadOnlyCanaryCursor,
        attemptID: AttemptID,
        scope: ProviderAttemptScope,
        failure: AgentErrorInfo
    ) async throws -> ReadOnlyCanaryAppend {
        let coordinator = self
        return try await Task.detached {
            try await coordinator.append(
                acceptance: acceptance,
                cursor: cursor,
                idempotencyKey: Self.responseIdempotencyKey(
                    scope: scope,
                    outcome: "failure"
                ),
                eventDomain: "m5-read-canary-provider-failure",
                eventMaterial: acceptance.metadata.runID.description + "|" +
                    scope.attemptID.rawValue,
                payload: .modelRequestFailed(ModelRequestFailedEvent(
                    attemptID: attemptID,
                    error: failure,
                    outputWasCommitted: false
                ))
            )
        }.value
    }

    fileprivate static func appendOrRecover(
        _ envelope: AgentEventEnvelope,
        journal: any AgentEventJournal
    ) async throws -> AgentJournalCommit {
        do {
            let commit = try await journal.append(envelope)
            guard commit.record.envelope == envelope else {
                throw AgentHostedReadOnlyCanaryCoordinatorError
                    .eventIdentityMismatch
            }
            return commit
        } catch {
            let records = try await journal.events(
                for: envelope.runID,
                after: nil
            )
            guard let existing = records.first(where: {
                $0.event.header.eventID == envelope.event.header.eventID
            }), existing.envelope == envelope else { throw error }
            return AgentJournalCommit(
                disposition: .alreadyCommitted,
                record: existing
            )
        }
    }

    private static func toolResult(
        invocation: ToolInvocation,
        output: String,
        status: ToolResultStatus,
        error: AgentErrorInfo?
    ) -> ToolResult {
        let digest = SHA256.hash(data: Data(output.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return ToolResult(
            modelItemID: ModelItemID(rawValue: stableUUID(
                domain: "m5-read-canary-tool-result-item",
                material: invocation.idempotencyKey
            )),
            callID: invocation.callID,
            status: status,
            output: .string(output),
            evidence: status == .succeeded ? [ToolEvidence(
                kind: "read_only_tool_output",
                digest: "sha256:" + digest
            )] : [],
            error: error
        )
    }

    private static func providerToolMessages(
        invocation: ToolInvocation,
        output: String
    ) -> [ProviderMessage] {
        guard let providerCallID = invocation.providerCallID else { return [] }
        return [
            ProviderMessage(
                role: .assistant,
                content: [.toolCall(ProviderToolCallInput(
                    callID: providerCallID,
                    name: invocation.tool.name,
                    arguments: invocation.arguments
                ))]
            ),
            ProviderMessage(
                role: .tool,
                content: [.text(output)],
                toolCallID: providerCallID
            ),
        ]
    }

    fileprivate static func eventTimestamp(
        _ acceptance: AgentRunAcceptance,
        sequence: EventSequence
    ) -> AgentInstant {
        AgentHostedTextCanaryCoordinator.eventTimestamp(
            acceptance,
            sequence: sequence
        )
    }

    fileprivate static func requestStartedEnvelope(
        acceptance: AgentRunAcceptance,
        sequence: EventSequence,
        causationEventID: EventID,
        scope: ProviderAttemptScope,
        attemptID: AttemptID,
        dispatch: ProviderAttemptDispatch,
        providerAttempt: ProviderAttemptJournalMetadata
    ) -> AgentEventEnvelope {
        AgentHostedTextCanaryCoordinator.envelope(
            acceptance: acceptance,
            sequence: sequence,
            idempotencyKey: "m5-read-canary:request-started:" +
                String(dispatch.requestSHA256.rawValue.dropFirst(7)),
            eventDomain: "m5-read-canary-request-started",
            eventMaterial: acceptance.metadata.runID.description + "|" +
                scope.attemptID.rawValue + "|" +
                dispatch.requestSHA256.rawValue,
            timestamp: eventTimestamp(acceptance, sequence: sequence),
            causationEventID: causationEventID,
            payload: .modelRequestStarted(ModelRequestStartedEvent(
                attemptID: attemptID,
                route: ModelRoute(
                    provider: dispatch.route.providerID.rawValue,
                    model: dispatch.route.modelID.rawValue,
                    adapter: dispatch.route.adapterID.rawValue
                ),
                providerAttempt: providerAttempt
            ))
        )
    }

    static func runBoundRequestID(_ requestID: String, runID: RunID) -> String {
        AgentHostedTextCanaryCoordinator.runBoundRequestID(
            requestID,
            runID: runID
        )
    }

    static func scope(
        requestID: String,
        round: Int
    ) -> ProviderAttemptScope {
        ProviderAttemptScope(
            requestID: requestID,
            attemptID: ProviderAttemptID(
                rawValue: "\(requestID):provider-attempt:\(round)"
            )
        )
    }

    static func attemptID(
        scope: ProviderAttemptScope,
        runID: RunID
    ) -> AttemptID {
        AttemptID(rawValue: stableUUID(
            domain: "m5-read-canary-provider-attempt",
            material: runID.description + "|" + scope.attemptID.rawValue
        ))
    }

    /// AgentTools and AgentProviders deliberately own different tool-schema
    /// representations. Keep the bridge explicit so a package contract can
    /// never be mistaken for a provider request definition at the app seam.
    static func providerDefinition(
        for descriptor: ToolDescriptor
    ) -> AgentProviders.ProviderToolDefinition {
        let contract = AgentTools.ProviderToolDefinition(
            descriptor: descriptor
        )
        return AgentProviders.ProviderToolDefinition(
            name: contract.function.name,
            description: contract.function.description,
            parameters: contract.function.parameters,
            strict: contract.function.strict
        )
    }

    private static func responseIdempotencyKey(
        scope: ProviderAttemptScope,
        outcome: String
    ) -> String {
        let digest = SHA256.hash(data: Data(
            scope.attemptID.rawValue.utf8
        )).map { String(format: "%02x", $0) }.joined()
        return "m5-read-canary:provider-\(outcome):\(digest)"
    }

    private static func stableUUID(domain: String, material: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(
            (domain + "\u{0}" + material).utf8
        )).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func sanitizedFailure(_ error: Error) -> AgentErrorInfo {
        if Task.isCancelled || error is CancellationError {
            return AgentErrorInfo(
                category: .cancelled,
                code: "hosted_read_attempt_cancelled",
                publicMessage: "The hosted read attempt was cancelled.",
                retryable: false
            )
        }
        if let failure = error as? ProviderFailure {
            let category: AgentErrorCategory
            switch failure.category {
            case .cancelled: category = .cancelled
            case .timeout: category = .timeout
            case .authentication: category = .authentication
            case .authorization: category = .authorization
            case .invalidRequest: category = .invalidInput
            case .rateLimited: category = .rateLimited
            case .contextLimit: category = .contextLimit
            case .unavailable: category = .unavailable
            case .transport: category = .transport
            case .malformedEvent, .protocolViolation, .contentFiltered,
                 .providerInternal: category = .provider
            case .unknown: category = .unknown
            }
            return AgentErrorInfo(
                category: category,
                code: "hosted_read_provider_\(category.rawValue)",
                publicMessage: "The hosted read attempt failed safely.",
                retryable: false
            )
        }
        return AgentErrorInfo(
            category: .invariantViolation,
            code: "hosted_read_attempt_contract_failed",
            publicMessage: "The hosted read attempt failed a safety contract.",
            retryable: false
        )
    }

    private static func isSafeRequestIdentity(_ value: String) -> Bool {
        let suffix = ":provider-attempt:\(Self.maximumProviderRounds)"
        return !value.isEmpty && value.utf8.count + suffix.utf8.count <= 512 &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                    !CharacterSet.controlCharacters.contains(scalar) &&
                    scalar.properties.generalCategory != .format
            }
    }

    private static func isCanonicalInitialMessage(
        _ message: ProviderMessage
    ) -> Bool {
        guard message.role == .system || message.role == .user ||
                message.role == .assistant,
              message.toolCallID == nil,
              message.name == nil,
              message.content.count == 1,
              case let .text(text) = message.content[0] else { return false }
        return !text.isEmpty
    }

    private static func isCanonicalFinalMessage(_ message: ModelMessage) -> Bool {
        guard message.role == .assistant,
              message.content.count == 1,
              case let .text(text) = message.content[0] else { return false }
        return !text.isEmpty
    }

    private static func isToolBearing(_ message: ProviderMessage) -> Bool {
        message.role == .tool || message.toolCallID != nil ||
            message.content.contains {
                if case .toolCall = $0 { return true }
                return false
            }
    }

    private static func acceptedUser(
        from acceptance: AgentRunAcceptance
    ) -> (itemID: UUID, text: String)? {
        guard case let .runAccepted(payload) =
                acceptance.envelope.event.payload,
              payload.initialItems.count == 1,
              let item = payload.initialItems.first,
              case let .message(message) = item.payload,
              message.role == .user,
              message.content.count == 1,
              case let .text(text) = message.content[0],
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return (item.id.rawValue, text)
    }

    private static let canonicalToolNames: Set<String> = [
        "list_directory", "list_tree", "workspace_summary", "file_info",
        "read_file", "read_file_range", "tail_file", "search_text",
        "diff_files", "validate_json", "validate_html_file",
        "extract_outline",
    ]
}

private struct ReadOnlyCanaryCursor: Sendable {
    let sequence: EventSequence
    let eventID: EventID
}

private struct AcceptedRunReplayReader: AgentEventReading, Sendable {
    let journal: any AgentEventJournal
    let acceptance: AgentRunAcceptance

    func metadata(for runID: RunID) async throws -> AgentRunMetadataRecord? {
        guard runID == acceptance.metadata.runID else { return nil }
        return try await journal.metadata(for: runID)
    }

    func events(
        for runID: RunID,
        after sequence: EventSequence?
    ) async throws -> [StoredAgentEvent] {
        guard runID == acceptance.metadata.runID else { return [] }
        let first = try await journal.events(for: runID, after: nil).prefix(1)
        return first.filter { record in
            guard let sequence else { return true }
            return record.event.header.sequence > sequence
        }
    }

    func projectionBatch(
        after offset: AgentJournalOffset,
        limit: Int
    ) async throws -> AgentProjectionBatch {
        try await journal.projectionBatch(after: offset, limit: limit)
    }
}

private struct ReadOnlyCanaryAppend: Sendable {
    let commit: AgentJournalCommit
    let cursor: ReadOnlyCanaryCursor
}

private struct ReadOnlyCanaryLedger: Sendable {
    let records: [StoredAgentEvent]
    let state: AgentDomain.AgentRunState
    let cursor: ReadOnlyCanaryCursor
}

private struct ReadOnlyPendingTool: Sendable {
    let invocation: ToolInvocation
    let status: ToolExecutionStatus?
}

private struct ReadOnlyCanaryRecovery: Sendable {
    var messages: [ProviderMessage]
    var seenProviderCallIDs: Set<String>
    let pendingTool: ReadOnlyPendingTool?
    let finalResult: AgentHostedTextCanaryResult?
    var completedToolRounds: Int
    var completedProviderRounds: Int
    var cumulativeToolOutputBytes: Int
}

private struct ReadOnlyToolCompletion: Sendable {
    let cursor: ReadOnlyCanaryCursor
    let messages: [ProviderMessage]
    let outputByteCount: Int
}

private enum ReadOnlyProviderRoundValue: Sendable {
    case tool(PreparedDeveloperReadOnlyCanaryToolInvocation)
    case final(AgentHostedTextCanaryResult)
}

private struct ReadOnlyProviderRoundOutcome: Sendable {
    let value: ReadOnlyProviderRoundValue
    let cursor: ReadOnlyCanaryCursor
}

private enum ReadOnlyCollectedProviderValue: Sendable {
    case tool(ProviderToolCallCompletion)
    case final(text: String, finishReason: ModelFinishReason)
}

private struct ReadOnlyCollectedProviderAttempt: Sendable {
    let value: ReadOnlyCollectedProviderValue
    let usage: ProviderUsage
}

private struct ReadOnlyProviderDispatchSnapshot: Sendable {
    let cursor: ReadOnlyCanaryCursor
    let requestDigest: ProviderRequestDigest
}

private actor ReadOnlyProviderDispatchState {
    private var value: ReadOnlyProviderDispatchSnapshot?

    func record(_ value: ReadOnlyProviderDispatchSnapshot) {
        self.value = value
    }

    func snapshot() -> ReadOnlyProviderDispatchSnapshot? { value }
}

private struct DurableReadOnlyProviderAttemptBarrier:
    ProviderAttemptDispatchBarrier,
    Sendable
{
    let journal: any AgentEventJournal
    let acceptance: AgentRunAcceptance
    let expectedScope: ProviderAttemptScope
    let expectedRoute: ProviderRoute
    let expectedRequestPath: String
    let attemptID: AttemptID
    let ordinal: UInt32
    let sequence: EventSequence
    let causationEventID: EventID
    let state: ReadOnlyProviderDispatchState

    func beforeDispatch(_ dispatch: ProviderAttemptDispatch) async throws {
        try Task.checkCancellation()
        guard dispatch.scope == expectedScope,
              dispatch.route == expectedRoute,
              dispatch.method == .post,
              dispatch.relativePath == expectedRequestPath else {
            throw AgentHostedReadOnlyCanaryCoordinatorError.routeMismatch
        }
        let providerAttempt = try dispatch.journalMetadata(
            ordinal: ordinal,
            recoverySeed: AgentHostedTextCanaryCoordinator
                .providerRecoverySeed(
                    runID: acceptance.metadata.runID,
                    scope: expectedScope,
                    ordinal: ordinal
                )
        )
        let envelope = AgentHostedReadOnlyCanaryCoordinator
            .requestStartedEnvelope(
                acceptance: acceptance,
                sequence: sequence,
                causationEventID: causationEventID,
                scope: expectedScope,
                attemptID: attemptID,
                dispatch: dispatch,
                providerAttempt: providerAttempt
            )
        let commit = try await journal.append(envelope)
        guard commit.disposition == .committed,
              commit.record.envelope == envelope else {
            throw AgentHostedReadOnlyCanaryCoordinatorError
                .duplicateProviderDispatch
        }
        await state.record(ReadOnlyProviderDispatchSnapshot(
            cursor: ReadOnlyCanaryCursor(
                sequence: sequence,
                eventID: envelope.event.header.eventID
            ),
            requestDigest: dispatch.requestSHA256
        ))
        try Task.checkCancellation()
    }
}


#endif
