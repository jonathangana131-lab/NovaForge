import AgentDomain
import AgentEngine
import AgentTools
import Foundation

/// Closed failures for the production AgentEngine read boundary. No case
/// carries provider input, paths, file contents, or backend error text.
enum AgentSandboxReadOnlyToolExecutorError: Error, Equatable, Sendable {
    case cancelled
    case invalidLimits
    case invalidRunLineage
    case workspaceMismatch
    case projectMismatch
    case unknownTool
    case descriptorMismatch
    case invocationMismatch
    case invalidReadOnlyContract
    case effectMismatch
    case localityMismatch
    case invalidArguments
    case unsafeTarget
    case workspaceChanged
    case workspaceTooLarge
    case backendFailed
    case outputByteLimitExceeded
    case outputItemLimitExceeded
}

/// Production adapter from AgentEngine's typed read contract to the pinned-fd
/// workspace reader. The adapter owns no mutation authority and never invokes
/// a path-based content API.
struct AgentSandboxReadOnlyToolExecutor:
    AgentReadOnlyToolExecuting,
    Sendable
{
    struct OutputLimits: Equatable, Sendable {
        static let production = OutputLimits(
            maximumBytes: 512 * 1_024,
            maximumItems: 2_048
        )

        let maximumBytes: Int
        let maximumItems: Int

        init(maximumBytes: Int, maximumItems: Int) {
            self.maximumBytes = maximumBytes
            self.maximumItems = maximumItems
        }
    }

    private static let hardMaximumOutputBytes = 512 * 1_024
    private static let hardMaximumOutputItems = 2_048
    private static let allowedCapabilities: Set<ToolCapability> = [
        .workspaceRead,
        .htmlValidation,
    ]

    private let workspaceID: WorkspaceID
    private let projectID: ProjectID?
    private let registry: ToolRegistry
    private let backend: POSIXWorkspaceReadBackend
    private let outputLimits: OutputLimits

    init(
        workspace: SandboxWorkspace,
        projectID: ProjectID?
    ) throws {
        try self.init(
            workspace: workspace,
            projectID: projectID,
            outputLimits: .production
        )
    }

    /// A lower-limit seam for focused tests and constrained hosts. Callers can
    /// never raise either bound above the production hard ceiling.
    init(
        workspace: SandboxWorkspace,
        projectID: ProjectID?,
        outputLimits: OutputLimits,
        readInterposition: POSIXWorkspaceReadInterposition = .none
    ) throws {
        guard outputLimits.maximumBytes > 0,
              outputLimits.maximumItems > 0,
              outputLimits.maximumBytes <= Self.hardMaximumOutputBytes,
              outputLimits.maximumItems <= Self.hardMaximumOutputItems
        else {
            throw AgentSandboxReadOnlyToolExecutorError.invalidLimits
        }

        let identity: WorkspaceResourceIdentity
        do {
            identity = try WorkspaceResourceIdentity(workspace: workspace)
        } catch {
            throw AgentSandboxReadOnlyToolExecutorError.workspaceMismatch
        }

        do {
            registry = try SandboxToolCatalog.canonicalRegistry()
        } catch {
            throw AgentSandboxReadOnlyToolExecutorError
                .invalidReadOnlyContract
        }
        do {
            backend = try POSIXWorkspaceReadBackend(
                workspace: workspace,
                expectedIdentity: identity,
                interposition: readInterposition
            )
        } catch {
            throw AgentSandboxReadOnlyToolExecutorError.workspaceMismatch
        }
        workspaceID = WorkspaceID(rawValue: identity.persistentID)
        self.projectID = projectID
        self.outputLimits = outputLimits
    }

    func executeReadOnly(
        _ request: AgentReadOnlyToolRequest
    ) async throws -> AgentReadOnlyToolOutput {
        do {
            try Task.checkCancellation()
            guard request.context.lineage.validationError == nil else {
                throw AgentSandboxReadOnlyToolExecutorError.invalidRunLineage
            }
            guard request.context.workspaceID == workspaceID else {
                throw AgentSandboxReadOnlyToolExecutorError.workspaceMismatch
            }
            guard request.context.projectID == projectID else {
                throw AgentSandboxReadOnlyToolExecutorError.projectMismatch
            }
            let prepared = try prepare(request)
            let output = try await executeObserved(prepared)
            try Task.checkCancellation()

            let rawByteCount = output.utf8.count
            let classified = JSONValue.string(output)
            let classifiedByteCount: Int
            do {
                classifiedByteCount = try AgentToolJSON.data(
                    for: classified
                ).count
            } catch {
                throw AgentSandboxReadOnlyToolExecutorError.backendFailed
            }
            let byteLimit = min(
                outputLimits.maximumBytes,
                prepared.descriptor.limits.maximumOutputBytes
            )
            guard rawByteCount <= byteLimit,
                  classifiedByteCount <= byteLimit else {
                throw AgentSandboxReadOnlyToolExecutorError
                    .outputByteLimitExceeded
            }
            guard Self.outputItemCount(output)
                    <= outputLimits.maximumItems else {
                throw AgentSandboxReadOnlyToolExecutorError
                    .outputItemLimitExceeded
            }

            try Task.checkCancellation()
            return AgentReadOnlyToolOutput(
                output: classified,
                artifacts: [],
                evidence: [],
                warnings: []
            )
        } catch is CancellationError {
            throw AgentSandboxReadOnlyToolExecutorError.cancelled
        } catch let error as AgentSandboxReadOnlyToolExecutorError {
            throw error
        } catch let error as POSIXWorkspaceReadBackendError {
            throw Self.mapBackendError(error)
        } catch {
            guard !Task.isCancelled else {
                throw AgentSandboxReadOnlyToolExecutorError.cancelled
            }
            throw AgentSandboxReadOnlyToolExecutorError.backendFailed
        }
    }

    private struct PreparedRead: Sendable {
        let descriptor: ToolDescriptor
        let request: LegacySandboxToolRequest
    }

    private func prepare(
        _ request: AgentReadOnlyToolRequest
    ) throws -> PreparedRead {
        let invocation = request.invocation
        guard let providerCallID = invocation.providerCallID,
              Self.isSafeIdentityToken(providerCallID),
              Self.isSafeIdentityToken(invocation.idempotencyKey) else {
            throw AgentSandboxReadOnlyToolExecutorError.invocationMismatch
        }

        let registered: ToolDescriptor
        do {
            registered = try registry.resolve(
                invocation.tool.name,
                version: invocation.tool.version
            ).descriptor
        } catch let error as ToolRegistryError {
            if case .unknownTool = error {
                throw AgentSandboxReadOnlyToolExecutorError.unknownTool
            }
            throw AgentSandboxReadOnlyToolExecutorError.invocationMismatch
        } catch {
            throw AgentSandboxReadOnlyToolExecutorError.unknownTool
        }

        guard registered.name == invocation.tool.name,
              registered.identity == invocation.tool,
              request.descriptor == registered else {
            throw AgentSandboxReadOnlyToolExecutorError.descriptorMismatch
        }
        guard invocation.effectClass == registered.effectClass else {
            throw AgentSandboxReadOnlyToolExecutorError.effectMismatch
        }
        guard invocation.locality == .onDevice else {
            throw AgentSandboxReadOnlyToolExecutorError.localityMismatch
        }
        try validateReadOnlyContract(registered)

        let decoded: DecodedToolArguments
        let legacyRequest: LegacySandboxToolRequest
        do {
            decoded = try registry.decode(
                name: registered.name,
                version: registered.version.description,
                arguments: invocation.arguments
            )
            legacyRequest = try registry.legacyRequest(
                name: registered.name,
                version: registered.version.description,
                arguments: invocation.arguments
            )
            guard try registered.canonicalArgumentDigest(
                for: invocation.arguments
            ) == invocation.canonicalArgumentDigest else {
                throw AgentSandboxReadOnlyToolExecutorError
                    .invocationMismatch
            }
        } catch let error as AgentSandboxReadOnlyToolExecutorError {
            throw error
        } catch {
            throw AgentSandboxReadOnlyToolExecutorError.invalidArguments
        }
        guard decodedArgumentsMatch(
            supplied: request.decodedArguments,
            canonical: decoded,
            toolName: registered.name
        ) else {
            throw AgentSandboxReadOnlyToolExecutorError.invalidArguments
        }

        let targets: [ToolTarget]
        do {
            targets = try registered.extractTargets(
                from: invocation.arguments
            )
        } catch {
            throw AgentSandboxReadOnlyToolExecutorError.invalidArguments
        }
        guard targets.allSatisfy({
            $0.access == .inspect || $0.access == .read
        }) else {
            throw AgentSandboxReadOnlyToolExecutorError
                .invalidReadOnlyContract
        }
        do {
            for target in targets {
                try POSIXWorkspaceReadBackend.validateRelativeTarget(
                    target.value,
                    allowRoot: true
                )
            }
        } catch {
            throw AgentSandboxReadOnlyToolExecutorError.unsafeTarget
        }

        guard legacyRequest.name == registered.name,
              POSIXWorkspaceReadBackend.supportedToolNames.contains(
                  legacyRequest.name
              ) else {
            throw AgentSandboxReadOnlyToolExecutorError
                .invalidReadOnlyContract
        }
        return PreparedRead(
            descriptor: registered,
            request: legacyRequest
        )
    }

    private func validateReadOnlyContract(
        _ descriptor: ToolDescriptor
    ) throws {
        let capabilities = Set(
            descriptor.availability.requiredCapabilities
        )
        guard descriptor.effectClass == .readOnlyLocal,
              descriptor.approvalClass == .none,
              descriptor.parallelSafety == .parallelRead,
              descriptor.concurrencyKey == nil,
              descriptor.availability.allowedLocalities == [.onDevice],
              descriptor.availability.requiresWorkspace,
              capabilities.contains(.workspaceRead),
              capabilities.isSubset(of: Self.allowedCapabilities),
              descriptor.argumentSchema.isObject,
              descriptor.legacyAdapter?.executorName == descriptor.name,
              descriptor.legacyAdapter?.supportedMajorVersion
                == descriptor.version.major else {
            throw AgentSandboxReadOnlyToolExecutorError
                .invalidReadOnlyContract
        }
    }

    private func executeObserved(
        _ prepared: PreparedRead
    ) async throws -> String {
        try await backend.execute(prepared.request)
    }

    private func decodedArgumentsMatch(
        supplied: DecodedToolArguments,
        canonical: DecodedToolArguments,
        toolName: String
    ) -> Bool {
        func matches<T: AgentToolArguments>(_ type: T.Type) -> Bool {
            guard let lhs = try? supplied.value(as: type),
                  let rhs = try? canonical.value(as: type) else {
                return false
            }
            return lhs == rhs
        }

        switch toolName {
        case ListDirectoryTool.descriptor.name:
            return matches(ListDirectoryArguments.self)
        case ListTreeTool.descriptor.name:
            return matches(ListTreeArguments.self)
        case WorkspaceSummaryTool.descriptor.name:
            return matches(WorkspaceSummaryArguments.self)
        case FileInfoTool.descriptor.name,
             ReadFileTool.descriptor.name,
             ValidateJSONTool.descriptor.name,
             ExtractOutlineTool.descriptor.name:
            return matches(PathArguments.self)
        case ReadFileRangeTool.descriptor.name:
            return matches(ReadFileRangeArguments.self)
        case TailFileTool.descriptor.name:
            return matches(TailFileArguments.self)
        case SearchTextTool.descriptor.name:
            return matches(SearchTextArguments.self)
        case DiffFilesTool.descriptor.name:
            return matches(DiffFilesArguments.self)
        case ValidateHTMLFileTool.descriptor.name:
            return matches(ValidateHTMLArguments.self)
        default:
            return false
        }
    }

    private static func isSafeIdentityToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 &&
            value == value.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) && value.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                    !CharacterSet.controlCharacters.contains(scalar) &&
                    scalar.properties.generalCategory != .format
            }
    }

    private static func outputItemCount(_ output: String) -> Int {
        guard !output.isEmpty else { return 0 }
        var count = 1
        for byte in output.utf8 where byte == 0x0a {
            let increment = count.addingReportingOverflow(1)
            guard !increment.overflow else { return Int.max }
            count = increment.partialValue
        }
        return count
    }

    private static func mapBackendError(
        _ error: POSIXWorkspaceReadBackendError
    ) -> AgentSandboxReadOnlyToolExecutorError {
        switch error {
        case .cancelled:
            .cancelled
        case .workspaceUnavailable:
            .workspaceMismatch
        case .invalidRelativePath, .unsafeFilesystemObject:
            .unsafeTarget
        case .targetChanged:
            .workspaceChanged
        case .unsupportedTool:
            .invalidReadOnlyContract
        case .invalidArguments:
            .invalidArguments
        case .resourceLimitExceeded:
            .workspaceTooLarge
        case .outputLimitExceeded:
            .outputByteLimitExceeded
        case .invalidUTF8, .operationFailed:
            .backendFailed
        }
    }
}
