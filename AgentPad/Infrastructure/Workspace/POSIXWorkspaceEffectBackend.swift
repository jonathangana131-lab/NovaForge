import AgentDomain
import AgentPolicy
import AgentTools
import CryptoKit
import Darwin
import Foundation

typealias PolicySHA256Digest = AgentPolicy.SHA256Digest

/// A public-safe failure vocabulary for the trusted workspace boundary.
/// Deliberately carries no path, command, errno, file contents, or provider data.
enum POSIXWorkspaceInfrastructureError: LocalizedError, Equatable, Sendable {
    case workspaceUnavailable
    case invalidRelativePath
    case unsafeFilesystemObject
    case targetChanged
    case authorizationMismatch
    case unsupportedOperation
    case evidenceShapeUnsupported
    case resourceLimitExceeded
    case checkpointMismatch
    case checkpointUnavailable
    case checkpointCorrupt
    case persistenceFailed
    case operationFailed
    case recoveryFailed

    var errorDescription: String? {
        switch self {
        case .workspaceUnavailable:
            "The workspace is unavailable."
        case .invalidRelativePath:
            "The workspace path is invalid."
        case .unsafeFilesystemObject:
            "The workspace contains an unsupported filesystem object."
        case .targetChanged:
            "The workspace changed before the operation could finish."
        case .authorizationMismatch:
            "The workspace operation no longer matches its authorization."
        case .unsupportedOperation:
            "That workspace operation is not supported by the secure backend."
        case .evidenceShapeUnsupported:
            "The operation cannot produce the required evidence shape."
        case .resourceLimitExceeded:
            "The workspace is too large to process safely."
        case .checkpointMismatch:
            "The workspace no longer matches its recovery checkpoint."
        case .checkpointUnavailable:
            "The workspace recovery checkpoint is unavailable."
        case .checkpointCorrupt:
            "The workspace recovery checkpoint could not be verified."
        case .persistenceFailed:
            "The workspace recovery checkpoint could not be saved."
        case .operationFailed:
            "The workspace operation could not be completed safely."
        case .recoveryFailed:
            "The workspace could not be restored safely."
        }
    }
}

protocol AgentWorkspaceRootProviding: Sendable {
    func workspaceRootLocation(
        for workspaceID: WorkspaceID
    ) throws -> AgentWorkspaceRootLocation
}

struct AgentWorkspaceRootLocation: Equatable, Sendable {
    let containerURL: URL
    let directoryName: String

    init(containerURL: URL, directoryName: String) throws {
        _ = try POSIXRelativePath(
            directoryName,
            allowRoot: false,
            maximumDepth: 1
        )
        self.containerURL = containerURL
        self.directoryName = directoryName
    }

    init(rootURL: URL) throws {
        try self.init(
            containerURL: rootURL.deletingLastPathComponent(),
            directoryName: rootURL.lastPathComponent
        )
    }

    var rootURL: URL {
        containerURL.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
    }
}

/// Small production composition primitive for one currently selected workspace.
/// A multi-workspace registry can conform to `AgentWorkspaceRootProviding` later
/// without giving the policy package raw filesystem paths.
struct BoundAgentWorkspaceRootProvider: AgentWorkspaceRootProviding, Sendable {
    let workspaceID: WorkspaceID
    let location: AgentWorkspaceRootLocation

    init(workspaceID: WorkspaceID, rootURL: URL) throws {
        self.workspaceID = workspaceID
        location = try AgentWorkspaceRootLocation(rootURL: rootURL)
    }

    init(workspaceID: WorkspaceID, location: AgentWorkspaceRootLocation) {
        self.workspaceID = workspaceID
        self.location = location
    }

    func workspaceRootLocation(
        for candidate: WorkspaceID
    ) throws -> AgentWorkspaceRootLocation {
        guard candidate == workspaceID else {
            throw POSIXWorkspaceInfrastructureError.workspaceUnavailable
        }
        return location
    }
}

struct POSIXWorkspaceLimits: Equatable, Sendable {
    var maximumEntryCount = 10_000
    var maximumTotalFileBytes: UInt64 = 512 * 1_024 * 1_024
    var maximumSingleFileBytes: UInt64 = 64 * 1_024 * 1_024
    var maximumPathUTF8Bytes = 4_096
    var maximumDepth = 64

    static let production = POSIXWorkspaceLimits()
}

enum POSIXWorkspaceMutation: Equatable, Sendable {
    case writeFile(path: String, contents: Data)
    case appendFile(path: String, contents: Data)
    case replaceText(path: String, old: Data, new: Data, replaceAll: Bool)
    case deletePath(path: String)
    case movePath(from: String, to: String)
    case copyPath(from: String, to: String)
    case makeDirectory(path: String)
    case createFile(path: String)
    case touchFile(path: String)
    case resetWorkspace
    case seedWorkspace(entries: [POSIXWorkspaceSeedEntry])
}

struct POSIXWorkspaceSeedEntry: Equatable, Sendable {
    let path: String
    let contents: Data
}

struct POSIXWorkspaceMutationInterposition: Sendable {
    var afterInitialValidation: @Sendable () throws -> Void
    var beforeFinalFilesystemCommit: @Sendable () throws -> Void

    init(
        afterInitialValidation: @escaping @Sendable () throws -> Void,
        beforeFinalFilesystemCommit: @escaping @Sendable () throws -> Void = {}
    ) {
        self.afterInitialValidation = afterInitialValidation
        self.beforeFinalFilesystemCommit = beforeFinalFilesystemCommit
    }

    static let none = POSIXWorkspaceMutationInterposition(
        afterInitialValidation: {},
        beforeFinalFilesystemCommit: {}
    )
}

struct POSIXWorkspaceMutationOutcome: Equatable, Sendable {
    let workspaceBeforeSHA256: PolicySHA256Digest
    let workspaceAfterSHA256: PolicySHA256Digest
    let detailSHA256: PolicySHA256Digest
}

enum POSIXWorkspaceTargetDisposition: String, Codable, Sendable {
    case existingObject
    case creatableDestination
}

enum POSIXWorkspaceObjectKind: String, Codable, Sendable {
    case regularFile
    case directory
    case absent
}

/// Internal mirror of policy target evidence. Keeping this copyable value free
/// of authority makes the fd core independently hostile-testable.
struct POSIXWorkspaceTargetCondition: Equatable, Sendable {
    let path: String
    let disposition: POSIXWorkspaceTargetDisposition
    let workspaceRootIdentity: String
    let containmentIdentity: String
    let objectKind: POSIXWorkspaceObjectKind
    let objectDevice: UInt64?
    let objectInode: UInt64?
    let objectLinkCount: UInt64?

    init(_ precondition: ApprovalPrecondition) throws {
        let resolution = precondition.resolution
        guard !resolution.traversedSymlink,
              resolution.target.path == resolution.resolvedRelativePath
        else {
            throw POSIXWorkspaceInfrastructureError.authorizationMismatch
        }
        let disposition: POSIXWorkspaceTargetDisposition
        switch resolution.disposition {
        case .existingObject:
            disposition = .existingObject
        case .creatableDestination:
            disposition = .creatableDestination
        }
        let objectKind: POSIXWorkspaceObjectKind
        switch resolution.objectKind {
        case .regularFile:
            objectKind = .regularFile
        case .directory:
            objectKind = .directory
        case .absent:
            objectKind = .absent
        case .other:
            throw POSIXWorkspaceInfrastructureError.unsafeFilesystemObject
        }
        self.init(
            path: resolution.resolvedRelativePath,
            disposition: disposition,
            workspaceRootIdentity: resolution.workspaceRootIdentity,
            containmentIdentity: resolution.containmentIdentity,
            objectKind: objectKind,
            objectDevice: resolution.objectDevice,
            objectInode: resolution.objectInode,
            objectLinkCount: resolution.objectLinkCount
        )
    }

    init(
        path: String,
        disposition: POSIXWorkspaceTargetDisposition,
        workspaceRootIdentity: String,
        containmentIdentity: String,
        objectKind: POSIXWorkspaceObjectKind,
        objectDevice: UInt64?,
        objectInode: UInt64?,
        objectLinkCount: UInt64?
    ) {
        self.path = path
        self.disposition = disposition
        self.workspaceRootIdentity = workspaceRootIdentity
        self.containmentIdentity = containmentIdentity
        self.objectKind = objectKind
        self.objectDevice = objectDevice
        self.objectInode = objectInode
        self.objectLinkCount = objectLinkCount
    }

    static func capture(
        rootURL: URL,
        path: String,
        disposition: POSIXWorkspaceTargetDisposition
    ) throws -> Self {
        let root = try POSIXWorkspaceFD.openRoot(at: rootURL)
        let relative = try POSIXRelativePath(path, allowRoot: true)
        let state = try POSIXWorkspaceFD.targetState(root: root, path: relative)
        switch disposition {
        case .existingObject:
            guard state.object != nil else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
        case .creatableDestination:
            guard state.object == nil else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
        }
        return Self(
            path: relative.string,
            disposition: disposition,
            workspaceRootIdentity: POSIXWorkspaceFD.identityToken(root.stat),
            containmentIdentity: POSIXWorkspaceFD.containmentToken(
                state.containment,
                targetPath: relative.string
            ),
            objectKind: state.object.map(POSIXWorkspaceFD.objectKind) ?? .absent,
            objectDevice: state.object.map { UInt64($0.st_dev) },
            objectInode: state.object.map { UInt64($0.st_ino) },
            objectLinkCount: state.object.map { UInt64($0.st_nlink) }
        )
    }
}

/// Resolver paired with the checkpointer and applier below. All three consume
/// the same fd-root identity format and complete-tree revision digest, so a
/// path string can never become execution authority by itself.
struct POSIXWorkspaceTargetResolutionBackend:
    WorkspaceTargetResolutionBackend,
    Sendable
{
    private struct PreviewMaterial: Codable {
        let path: String
        let disposition: POSIXWorkspaceTargetDisposition
        let workspaceRootIdentity: String
        let containmentIdentity: String
        let objectKind: POSIXWorkspaceObjectKind
        let objectDevice: UInt64?
        let objectInode: UInt64?
        let objectLinkCount: UInt64?
        let contentSHA256: PolicySHA256Digest?
        let workspaceRevision: String
    }

    private let roots: any AgentWorkspaceRootProviding
    private let limits: POSIXWorkspaceLimits

    init(
        roots: any AgentWorkspaceRootProviding,
        limits: POSIXWorkspaceLimits = .production
    ) {
        self.roots = roots
        self.limits = limits
    }

    func resolveTargets(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation,
        workspaceID: WorkspaceID
    ) async throws -> WorkspaceResolutionCandidate {
        do {
            guard descriptor.identity == invocation.tool,
                  descriptor.effectClass == invocation.effectClass,
                  try descriptor.canonicalArgumentDigest(
                      for: invocation.arguments
                  ) == invocation.canonicalArgumentDigest
            else {
                throw POSIXWorkspaceInfrastructureError
                    .authorizationMismatch
            }
            let logical = try Self.logicalTargets(
                descriptor: descriptor,
                invocation: invocation
            )
            let location = try roots.workspaceRootLocation(for: workspaceID)
            let container = try POSIXWorkspaceFD.openContainer(
                at: location.containerURL
            )
            guard let root = try POSIXWorkspaceFD.openRoot(
                container: container,
                name: location.directoryName
            ) else {
                return try missingRootCandidate(
                    descriptor: descriptor,
                    targets: logical,
                    workspaceID: workspaceID,
                    container: container,
                    rootName: location.directoryName
                )
            }
            let before = try POSIXWorkspaceTree.capture(
                root: root,
                limits: limits
            )
            let rootIdentity = POSIXWorkspaceFD.identityToken(root.stat)
            var preconditions: [ApprovalPrecondition] = []
            preconditions.reserveCapacity(logical.count)
            for target in logical {
                let path = try POSIXRelativePath(
                    target.path,
                    allowRoot: true,
                    maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
                    maximumDepth: limits.maximumDepth
                )
                let state = try POSIXWorkspaceFD.targetState(
                    root: root,
                    path: path
                )
                let disposition: TargetResolutionDisposition = state.object == nil
                    ? .creatableDestination
                    : .existingObject
                let localDisposition: POSIXWorkspaceTargetDisposition = state.object == nil
                    ? .creatableDestination
                    : .existingObject
                let kind: ResolvedTargetObjectKind
                let localKind: POSIXWorkspaceObjectKind
                if let object = state.object {
                    if POSIXWorkspaceFD.isRegular(object) {
                        guard object.st_nlink == 1 else {
                            throw POSIXWorkspaceInfrastructureError
                                .unsafeFilesystemObject
                        }
                        kind = .regularFile
                        localKind = .regularFile
                    } else if POSIXWorkspaceFD.isDirectory(object) {
                        kind = .directory
                        localKind = .directory
                    } else {
                        throw POSIXWorkspaceInfrastructureError
                            .unsafeFilesystemObject
                    }
                } else {
                    kind = .absent
                    localKind = .absent
                }
                let revision = before.physicalSHA256.rawValue
                let snapshot = try ResolvedToolTargetSnapshot.make(
                    workspaceID: workspaceID,
                    target: target,
                    resolvedRelativePath: path.string,
                    disposition: disposition,
                    workspaceRootIdentity: rootIdentity,
                    containmentIdentity: POSIXWorkspaceFD.containmentToken(
                        state.containment,
                        targetPath: path.string
                    ),
                    objectKind: kind,
                    objectDevice: state.object.map { UInt64($0.st_dev) },
                    objectInode: state.object.map { UInt64($0.st_ino) },
                    objectLinkCount: state.object.map { UInt64($0.st_nlink) },
                    resolutionRevision: revision,
                    traversedSymlink: false
                )
                let contentDigest = before.entries.first(where: {
                    $0.path == path.string
                })?.contentSHA256
                let preview = try POSIXWorkspaceDigest.sha256(
                    domain: "workspace-target-preview-v1",
                    encodable: PreviewMaterial(
                        path: path.string,
                        disposition: localDisposition,
                        workspaceRootIdentity: rootIdentity,
                        containmentIdentity: POSIXWorkspaceFD.containmentToken(
                            state.containment,
                            targetPath: path.string
                        ),
                        objectKind: localKind,
                        objectDevice: state.object.map { UInt64($0.st_dev) },
                        objectInode: state.object.map { UInt64($0.st_ino) },
                        objectLinkCount: state.object.map {
                            UInt64($0.st_nlink)
                        },
                        contentSHA256: contentDigest,
                        workspaceRevision: revision
                    )
                )
                preconditions.append(ApprovalPrecondition(
                    resolution: snapshot,
                    previewSHA256: preview
                ))
            }
            let after = try POSIXWorkspaceTree.capture(
                root: root,
                limits: limits
            ).physicalSHA256
            guard after == before.physicalSHA256 else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
            return try WorkspaceResolutionCandidate(
                preconditions: preconditions,
                workspaceRevision: before.physicalSHA256.rawValue
            )
        } catch let error as POSIXWorkspaceInfrastructureError {
            throw error
        } catch {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
    }

    private func missingRootCandidate(
        descriptor: ToolDescriptor,
        targets: [NormalizedToolTarget],
        workspaceID: WorkspaceID,
        container: POSIXWorkspaceContainerFD,
        rootName: String
    ) throws -> WorkspaceResolutionCandidate {
        guard Self.isCanonicalSeedDescriptor(descriptor),
              !targets.isEmpty,
              targets.allSatisfy({ $0.access == .write })
        else {
            throw POSIXWorkspaceInfrastructureError.workspaceUnavailable
        }
        let revision = try POSIXWorkspaceTree.missingRootSHA256(
            container: container.stat,
            rootName: rootName
        ).rawValue
        let rootIdentity = POSIXWorkspaceFD.missingRootIdentityToken(
            container: container.stat,
            rootName: rootName
        )
        let preconditions = try targets.map { target in
            let path = try POSIXRelativePath(
                target.path,
                allowRoot: false,
                maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
                maximumDepth: limits.maximumDepth
            )
            let snapshot = try ResolvedToolTargetSnapshot.make(
                workspaceID: workspaceID,
                target: target,
                resolvedRelativePath: path.string,
                disposition: .creatableDestination,
                workspaceRootIdentity: rootIdentity,
                containmentIdentity: POSIXWorkspaceFD.containmentToken(
                    container.stat,
                    targetPath: path.string
                ),
                objectKind: .absent,
                objectDevice: nil,
                objectInode: nil,
                objectLinkCount: nil,
                resolutionRevision: revision,
                traversedSymlink: false
            )
            let preview = try POSIXWorkspaceDigest.sha256(
                domain: "workspace-target-preview-v1",
                encodable: PreviewMaterial(
                    path: path.string,
                    disposition: .creatableDestination,
                    workspaceRootIdentity: rootIdentity,
                    containmentIdentity: POSIXWorkspaceFD.containmentToken(
                        container.stat,
                        targetPath: path.string
                    ),
                    objectKind: .absent,
                    objectDevice: nil,
                    objectInode: nil,
                    objectLinkCount: nil,
                    contentSHA256: nil,
                    workspaceRevision: revision
                )
            )
            return ApprovalPrecondition(
                resolution: snapshot,
                previewSHA256: preview
            )
        }
        return try WorkspaceResolutionCandidate(
            preconditions: preconditions,
            workspaceRevision: revision
        )
    }

    static func isCanonicalSeedDescriptor(_ descriptor: ToolDescriptor) -> Bool {
        descriptor == ToolDescriptor(
            metadata: ToolDescriptorMetadata(
                name: "seed_workspace",
                version: ToolVersion(major: 1, minor: 0, patch: 0),
                toolset: "policy_workspace",
                description: "Write an exact bounded set of initial workspace files.",
                availability: ToolAvailabilityRequirement(
                    allowedLocalities: [.onDevice],
                    requiredCapabilities: [.workspaceWrite],
                    requiresWorkspace: true
                ),
                effectClass: .scopedReversibleWrite,
                approvalClass: .explicit,
                targetStrategy: .arrayArgumentPaths(
                    arrayPath: ["entries"],
                    elementRules: [
                        ToolTargetRule(
                            argumentPath: ["path"],
                            access: .write
                        ),
                    ]
                ),
                parallelSafety: .workspaceSerialized,
                concurrencyKey: "workspace",
                limits: ToolLimits(
                    timeoutMilliseconds: 30_000,
                    maximumArgumentBytes: 2_100_000,
                    maximumOutputBytes: 65_536
                ),
                redaction: ToolRedactionPolicy(
                    argumentRules: [
                        ToolArgumentRedactionRule(path: ["path"]),
                        ToolArgumentRedactionRule(
                            path: ["entries", "*", "path"]
                        ),
                        ToolArgumentRedactionRule(
                            path: ["entries", "*", "contents"]
                        ),
                    ],
                    output: .replace(
                        .string("<redacted-mutation-output>")
                    )
                ),
                legacyAdapter: nil,
                receipt: ToolReceiptMetadata(
                    actionVerb: "Changed",
                    successSummary: "Workspace changed"
                ),
                evidence: .changedPath,
                ui: ToolUIMetadata(
                    title: "Seed Workspace",
                    systemImageName: "folder.badge.gearshape",
                    category: .edit,
                    resultPresentation: .text
                )
            ),
            argumentSchema: SeedWorkspaceMutationArguments.jsonSchema
        )
    }

    private static func logicalTargets(
        descriptor: ToolDescriptor,
        invocation: ToolInvocation
    ) throws -> [NormalizedToolTarget] {
        let targets: [ToolTarget]
        switch descriptor.targetStrategy {
        case .legacyCommandParserRequired:
            let arguments = try RunCommandTool.decodeArguments(
                invocation.arguments
            )
            targets = try commandTargets(arguments.command)
        case .workspaceRoot, .argumentPaths, .arrayArgumentPaths:
            targets = try descriptor.extractTargets(from: invocation.arguments)
        }
        return try NormalizedToolTarget.canonicalize(targets)
    }

    private static func commandTargets(_ command: String) throws -> [ToolTarget] {
        try POSIXMutationCommand.parse(command).targets
    }
}

struct POSIXMutationCommand: Sendable {
    let mutation: POSIXWorkspaceMutation
    let targets: [ToolTarget]

    static func parse(_ command: String) throws -> Self {
        guard command == command.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty,
              command.unicodeScalars.allSatisfy({ scalar in
                  scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
              }),
              !containsShellSyntax(command)
        else {
            throw POSIXWorkspaceInfrastructureError.unsupportedOperation
        }
        let tokens = try tokenize(command)
        guard let name = tokens.first, name == name.lowercased() else {
            throw POSIXWorkspaceInfrastructureError.unsupportedOperation
        }
        let arguments = Array(tokens.dropFirst())
        switch name {
        case "mkdir":
            guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
                throw POSIXWorkspaceInfrastructureError.unsupportedOperation
            }
            let path = try canonicalPath(arguments[0])
            return Self(
                mutation: .makeDirectory(path: path),
                targets: [ToolTarget(
                    value: path,
                    access: .destination
                )]
            )
        case "touch":
            guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
                throw POSIXWorkspaceInfrastructureError.unsupportedOperation
            }
            let path = try canonicalPath(arguments[0])
            return Self(
                mutation: .touchFile(path: path),
                targets: [ToolTarget(value: path, access: .write)]
            )
        case "rm":
            guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
                throw POSIXWorkspaceInfrastructureError.unsupportedOperation
            }
            let path = try canonicalPath(arguments[0])
            return Self(
                mutation: .deletePath(path: path),
                targets: [ToolTarget(value: path, access: .delete)]
            )
        case "mv":
            guard arguments.count == 2,
                  !arguments[0].hasPrefix("-"),
                  !arguments[1].hasPrefix("-")
            else {
                throw POSIXWorkspaceInfrastructureError.unsupportedOperation
            }
            let source = try canonicalPath(arguments[0])
            let destination = try canonicalPath(arguments[1])
            return Self(
                mutation: .movePath(from: source, to: destination),
                targets: [
                    ToolTarget(value: source, access: .source),
                    ToolTarget(value: destination, access: .destination),
                ]
            )
        case "cp":
            guard arguments.count == 2,
                  !arguments[0].hasPrefix("-"),
                  !arguments[1].hasPrefix("-")
            else {
                throw POSIXWorkspaceInfrastructureError.unsupportedOperation
            }
            let source = try canonicalPath(arguments[0])
            let destination = try canonicalPath(arguments[1])
            return Self(
                mutation: .copyPath(from: source, to: destination),
                targets: [
                    ToolTarget(value: source, access: .source),
                    ToolTarget(value: destination, access: .destination),
                ]
            )
        default:
            throw POSIXWorkspaceInfrastructureError.unsupportedOperation
        }
    }

    private static func canonicalPath(_ raw: String) throws -> String {
        do {
            return try POSIXRelativePath(raw, allowRoot: false).string
        } catch {
            throw POSIXWorkspaceInfrastructureError.unsupportedOperation
        }
    }

    private static func containsShellSyntax(_ value: String) -> Bool {
        var quote: Character?
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "\"" || character == "'" {
                quote = quote == character ? nil : (quote == nil ? character : quote)
                index = value.index(after: index)
                continue
            }
            if quote == nil {
                if "|><;`".contains(character) { return true }
                let next = value.index(after: index)
                if next < value.endIndex,
                   (character == "&" && value[next] == "&"
                    || character == "$" && value[next] == "(") {
                    return true
                }
            }
            index = value.index(after: index)
        }
        return quote != nil
    }

    private static func tokenize(_ value: String) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in value {
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                } else {
                    current.append(character)
                }
            } else if character.isWhitespace, quote == nil {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        guard quote == nil else {
            throw POSIXWorkspaceInfrastructureError.unsupportedOperation
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

struct POSIXWorkspaceEffectBackend: MutationEffectApplying, Sendable {
    private let roots: any AgentWorkspaceRootProviding
    private let limits: POSIXWorkspaceLimits
    private let interposition: POSIXWorkspaceMutationInterposition

    init(
        roots: any AgentWorkspaceRootProviding,
        limits: POSIXWorkspaceLimits = .production,
        interposition: POSIXWorkspaceMutationInterposition = .none
    ) {
        self.roots = roots
        self.limits = limits
        self.interposition = interposition
    }

    func apply(
        _ operation: MutationEffectOperation,
        authorization: borrowing MutationEffectApplicationAuthorization
    ) throws -> MutationEffectApplicationResult {
        do {
            guard operation.origin == authorization.origin else {
                throw POSIXWorkspaceInfrastructureError.authorizationMismatch
            }
            let location = try roots.workspaceRootLocation(
                for: authorization.workspaceID
            )
            let mutation = try Self.mutation(operation.body)
            let expectedPaths = try Self.expectedPaths(mutation)
            let authorizedPaths = Set(authorization.resolvedTargets.map(\.path))
            guard expectedPaths == authorizedPaths,
                  authorization.preconditions.count
                    == authorization.resolvedTargets.count,
                  authorization.preconditions.allSatisfy({ precondition in
                      precondition.resolution.workspaceID
                        == authorization.workspaceID
                          && precondition.resolution.resolutionRevision
                            == authorization.workspaceRevision
                  })
            else {
                throw POSIXWorkspaceInfrastructureError.authorizationMismatch
            }

            let conditions = try authorization.preconditions.map(
                POSIXWorkspaceTargetCondition.init
            )
            let executor = POSIXWorkspaceMutationExecutor(
                limits: limits,
                interposition: interposition
            )
            let outcome: POSIXWorkspaceMutationOutcome
            let container = try POSIXWorkspaceFD.openContainer(
                at: location.containerURL
            )
            if let root = try POSIXWorkspaceFD.openRoot(
                container: container,
                name: location.directoryName
            ) {
                outcome = try executor.execute(
                    mutation,
                    root: root,
                    conditions: conditions,
                    requiredBeforeSHA256:
                        authorization.checkpoint.beforeStateSHA256
                )
            } else {
                guard case let .seedWorkspace(entries) = mutation else {
                    throw POSIXWorkspaceInfrastructureError
                        .workspaceUnavailable
                }
                outcome = try executor.executeSeedCreatingRoot(
                    entries: entries,
                    container: container,
                    rootName: location.directoryName,
                    conditions: conditions,
                    requiredBeforeSHA256:
                        authorization.checkpoint.beforeStateSHA256
                )
            }
            return try Self.applicationResult(
                operation: operation,
                targets: authorization.resolvedTargets,
                outcome: outcome
            )
        } catch let error as POSIXWorkspaceInfrastructureError {
            throw error
        } catch {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
    }

    private static func mutation(
        _ body: MutationEffectOperationBody
    ) throws -> POSIXWorkspaceMutation {
        switch body {
        case let .writeFile(arguments):
            return .writeFile(
                path: arguments.path,
                contents: Data(arguments.contents.utf8)
            )
        case let .appendFile(arguments):
            return .appendFile(
                path: arguments.path,
                contents: Data(arguments.contents.utf8)
            )
        case let .replaceText(arguments):
            return .replaceText(
                path: arguments.path,
                old: Data(arguments.old.utf8),
                new: Data(arguments.new.utf8),
                replaceAll: arguments.replaceAll == true
            )
        case let .deletePath(arguments):
            return .deletePath(path: arguments.path)
        case let .movePath(arguments):
            return .movePath(from: arguments.from, to: arguments.to)
        case let .copyPath(arguments):
            return .copyPath(from: arguments.from, to: arguments.to)
        case let .makeDirectory(arguments):
            return .makeDirectory(path: arguments.path)
        case let .createFile(arguments):
            return .createFile(path: arguments.path)
        case let .touchFile(arguments):
            return .touchFile(path: arguments.path)
        case .resetWorkspace:
            return .resetWorkspace
        case let .seedWorkspace(arguments):
            return .seedWorkspace(entries: arguments.entries.map {
                POSIXWorkspaceSeedEntry(
                    path: $0.path,
                    contents: Data($0.contents.utf8)
                )
            })
        case let .runCommand(arguments):
            return try terminalMutation(arguments.command)
        }
    }

    private static func terminalMutation(
        _ command: String
    ) throws -> POSIXWorkspaceMutation {
        try POSIXMutationCommand.parse(command).mutation
    }

    private static func expectedPaths(
        _ mutation: POSIXWorkspaceMutation
    ) throws -> Set<String> {
        func normalized(_ value: String) throws -> String {
            try POSIXRelativePath(value, allowRoot: false).string
        }
        switch mutation {
        case let .writeFile(path, _), let .appendFile(path, _),
             let .replaceText(path, _, _, _), let .deletePath(path),
             let .makeDirectory(path), let .createFile(path),
             let .touchFile(path):
            return [try normalized(path)]
        case let .movePath(from, to), let .copyPath(from, to):
            return [try normalized(from), try normalized(to)]
        case .resetWorkspace:
            return [""]
        case let .seedWorkspace(entries):
            let paths = try entries.map { try normalized($0.path) }
            guard Set(paths).count == paths.count else {
                throw POSIXWorkspaceInfrastructureError.invalidRelativePath
            }
            return Set(paths)
        }
    }

    private static func applicationResult(
        operation: MutationEffectOperation,
        targets: [NormalizedToolTarget],
        outcome: POSIXWorkspaceMutationOutcome
    ) throws -> MutationEffectApplicationResult {
        let outputKind: MutationEffectOutputKind
        let evidenceKind: MutationEffectEvidenceKind?
        switch operation.body {
        case .writeFile:
            outputKind = .writeFile
            evidenceKind = .changedPath
        case .appendFile:
            outputKind = .appendFile
            evidenceKind = .changedPath
        case .replaceText:
            outputKind = .replaceText
            evidenceKind = .changedPath
        case .deletePath:
            outputKind = .deletePath
            evidenceKind = .deletedPath
        case .movePath:
            outputKind = .movePath
            evidenceKind = .movedPath
        case .copyPath:
            outputKind = .copyPath
            evidenceKind = .copiedPath
        case .makeDirectory:
            outputKind = .makeDirectory
            evidenceKind = .createdDirectory
        case .runCommand:
            outputKind = .runCommand
            evidenceKind = nil
        case .createFile:
            outputKind = .createFile
            evidenceKind = .changedPath
        case .touchFile:
            outputKind = .touchFile
            evidenceKind = .changedPath
        case .resetWorkspace:
            outputKind = .resetWorkspace
            evidenceKind = .deletedPath
        case .seedWorkspace:
            outputKind = .seedWorkspace
            evidenceKind = .changedPath
        }

        let output = try MutationEffectOutput(
            kind: outputKind,
            summary: "Workspace operation completed.",
            targets: targets,
            text: outputKind == .runCommand ? "Command completed." : nil,
            commandExitCode: outputKind == .runCommand ? 0 : nil
        )
        var evidence = [try MutationEffectEvidenceFact(
            kind: .workspaceAfter,
            digest: outcome.workspaceAfterSHA256
        )]
        if let evidenceKind {
            evidence.append(try MutationEffectEvidenceFact(
                kind: evidenceKind,
                targets: targets,
                digest: outcome.detailSHA256
            ))
        } else {
            evidence.append(try MutationEffectEvidenceFact(
                kind: .commandTranscript,
                digest: outcome.detailSHA256
            ))
            evidence.append(try MutationEffectEvidenceFact(
                kind: .commandExit,
                digest: try POSIXWorkspaceDigest.sha256(
                    domain: "command-exit-v1",
                    data: Data("0".utf8)
                )
            ))
        }
        let resultMaterial = Data([
            operation.operationPayloadSHA256.rawValue,
            output.outputSHA256.rawValue,
            outcome.workspaceAfterSHA256.rawValue,
            outcome.detailSHA256.rawValue,
        ].joined(separator: "\u{0}").utf8)
        return try MutationEffectApplicationResult(
            resultSHA256: POSIXWorkspaceDigest.sha256(
                domain: "mutation-result-v1",
                data: resultMaterial
            ),
            output: output,
            evidence: evidence
        )
    }
}

struct POSIXWorkspaceMutationExecutor: Sendable {
    let limits: POSIXWorkspaceLimits
    let interposition: POSIXWorkspaceMutationInterposition

    init(
        limits: POSIXWorkspaceLimits = .production,
        interposition: POSIXWorkspaceMutationInterposition = .none
    ) {
        self.limits = limits
        self.interposition = interposition
    }

    func execute(
        _ mutation: POSIXWorkspaceMutation,
        rootURL: URL,
        conditions: [POSIXWorkspaceTargetCondition],
        requiredBeforeSHA256: PolicySHA256Digest? = nil
    ) throws -> POSIXWorkspaceMutationOutcome {
        let root = try POSIXWorkspaceFD.openRoot(at: rootURL)
        return try execute(
            mutation,
            root: root,
            conditions: conditions,
            requiredBeforeSHA256: requiredBeforeSHA256
        )
    }

    func execute(
        _ mutation: POSIXWorkspaceMutation,
        root: POSIXWorkspaceRootFD,
        conditions: [POSIXWorkspaceTargetCondition],
        requiredBeforeSHA256: PolicySHA256Digest? = nil
    ) throws -> POSIXWorkspaceMutationOutcome {
        let before = try POSIXWorkspaceTree.capture(
            root: root,
            limits: limits
        ).physicalSHA256
        if let requiredBeforeSHA256, before != requiredBeforeSHA256 {
            throw POSIXWorkspaceInfrastructureError.checkpointMismatch
        }
        try validate(conditions, root: root)
        try interposition.afterInitialValidation()

        // Re-hash the complete identity-bound state after the hostile seam.
        // This detects target swaps that are restored before path revalidation.
        let revalidatedBefore = try POSIXWorkspaceTree.capture(
            root: root,
            limits: limits
        ).physicalSHA256
        guard revalidatedBefore == before else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        try validate(conditions, root: root)

        try apply(mutation, root: root, conditions: conditions)
        try POSIXWorkspaceFD.verifyRoot(root)
        let after = try POSIXWorkspaceTree.capture(
            root: root,
            limits: limits
        ).physicalSHA256
        let detail = try POSIXWorkspaceDigest.sha256(
            domain: "mutation-detail-v1",
            data: Data(Self.detailMaterial(mutation, after: after).utf8)
        )
        return POSIXWorkspaceMutationOutcome(
            workspaceBeforeSHA256: before,
            workspaceAfterSHA256: after,
            detailSHA256: detail
        )
    }

    func executeSeedCreatingRoot(
        entries: [POSIXWorkspaceSeedEntry],
        container: POSIXWorkspaceContainerFD,
        rootName: String,
        conditions: [POSIXWorkspaceTargetCondition],
        requiredBeforeSHA256: PolicySHA256Digest
    ) throws -> POSIXWorkspaceMutationOutcome {
        guard !entries.isEmpty,
              conditions.count == entries.count,
              conditions.allSatisfy({
                  $0.disposition == .creatableDestination
                      && $0.objectKind == .absent
                      && $0.workspaceRootIdentity
                        == POSIXWorkspaceFD.missingRootIdentityToken(
                            container: container.stat,
                            rootName: rootName
                        )
                      && $0.containmentIdentity
                        == POSIXWorkspaceFD.containmentToken(
                            container.stat,
                            targetPath: $0.path
                        )
              }),
              try POSIXWorkspaceFD.openRoot(
                  container: container,
                  name: rootName
              ) == nil
        else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        let before = try POSIXWorkspaceTree.missingRootSHA256(
            container: container.stat,
            rootName: rootName
        )
        guard before == requiredBeforeSHA256 else {
            throw POSIXWorkspaceInfrastructureError.checkpointMismatch
        }
        try interposition.afterInitialValidation()
        guard try POSIXWorkspaceFD.openRoot(
            container: container,
            name: rootName
        ) == nil,
              try POSIXWorkspaceTree.missingRootSHA256(
                  container: container.stat,
                  rootName: rootName
              ) == before
        else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        let root = try POSIXWorkspaceFD.createRoot(
            container: container,
            name: rootName
        )
        let mutation = POSIXWorkspaceMutation.seedWorkspace(entries: entries)
        try apply(mutation, root: root, conditions: conditions)
        let after = try POSIXWorkspaceTree.capture(
            root: root,
            limits: limits
        ).physicalSHA256
        let detail = try POSIXWorkspaceDigest.sha256(
            domain: "mutation-detail-v1",
            data: Data(Self.detailMaterial(mutation, after: after).utf8)
        )
        return POSIXWorkspaceMutationOutcome(
            workspaceBeforeSHA256: before,
            workspaceAfterSHA256: after,
            detailSHA256: detail
        )
    }

    private func validate(
        _ conditions: [POSIXWorkspaceTargetCondition],
        root: POSIXWorkspaceRootFD
    ) throws {
        let rootIdentity = POSIXWorkspaceFD.identityToken(root.stat)
        for condition in conditions {
            guard condition.workspaceRootIdentity == rootIdentity else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
            let path = try POSIXRelativePath(
                condition.path,
                allowRoot: true,
                maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
                maximumDepth: limits.maximumDepth
            )
            let current = try POSIXWorkspaceFD.targetState(
                root: root,
                path: path
            )
            guard POSIXWorkspaceFD.containmentToken(
                current.containment,
                targetPath: path.string
            )
                    == condition.containmentIdentity
            else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
            switch condition.disposition {
            case .creatableDestination:
                guard current.object == nil,
                      condition.objectKind == .absent,
                      condition.objectDevice == nil,
                      condition.objectInode == nil,
                      condition.objectLinkCount == nil
                else {
                    throw POSIXWorkspaceInfrastructureError.targetChanged
                }
            case .existingObject:
                guard let object = current.object,
                      condition.objectKind
                        == POSIXWorkspaceFD.objectKind(object),
                      condition.objectDevice == UInt64(object.st_dev),
                      condition.objectInode == UInt64(object.st_ino),
                      condition.objectLinkCount == UInt64(object.st_nlink)
                else {
                    throw POSIXWorkspaceInfrastructureError.targetChanged
                }
                if POSIXWorkspaceFD.isRegular(object), object.st_nlink != 1 {
                    throw POSIXWorkspaceInfrastructureError
                        .unsafeFilesystemObject
                }
            }
        }
    }

    private func apply(
        _ mutation: POSIXWorkspaceMutation,
        root: POSIXWorkspaceRootFD,
        conditions: [POSIXWorkspaceTargetCondition]
    ) throws {
        let conditionsByPath = Dictionary(
            uniqueKeysWithValues: conditions.map { ($0.path, $0) }
        )
        switch mutation {
        case let .writeFile(path, contents):
            try writeAtomically(
                contents,
                path: path,
                root: root,
                expected: try condition(path, in: conditionsByPath)
            )
        case let .appendFile(path, contents):
            try append(
                contents,
                path: path,
                root: root,
                expected: try condition(path, in: conditionsByPath)
            )
        case let .replaceText(path, old, new, replaceAll):
            try replaceText(
                path: path,
                old: old,
                new: new,
                replaceAll: replaceAll,
                root: root,
                expected: try condition(path, in: conditionsByPath)
            )
        case let .deletePath(path):
            try remove(
                path: path,
                root: root,
                expected: try condition(path, in: conditionsByPath)
            )
        case let .movePath(from, to):
            try move(
                from: from,
                to: to,
                root: root,
                source: try condition(from, in: conditionsByPath),
                destination: try condition(to, in: conditionsByPath)
            )
        case let .copyPath(from, to):
            try copy(
                from: from,
                to: to,
                root: root,
                source: try condition(from, in: conditionsByPath),
                destination: try condition(to, in: conditionsByPath)
            )
        case let .makeDirectory(path):
            try makeDirectory(
                path: path,
                root: root,
                expected: try condition(path, in: conditionsByPath)
            )
        case let .createFile(path):
            let expected = try condition(path, in: conditionsByPath)
            guard expected.disposition == .creatableDestination else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
            try writeAtomically(Data(), path: path, root: root, expected: expected)
        case let .touchFile(path):
            try touch(
                path: path,
                root: root,
                expected: try condition(path, in: conditionsByPath)
            )
        case .resetWorkspace:
            guard conditions.count == 1, conditions[0].path.isEmpty else {
                throw POSIXWorkspaceInfrastructureError.authorizationMismatch
            }
            try POSIXWorkspaceFD.removeAllChildren(of: root.fd)
            try POSIXWorkspaceFD.sync(root.fd)
        case let .seedWorkspace(entries):
            for entry in entries {
                try writeAtomically(
                    entry.contents,
                    path: entry.path,
                    root: root,
                    expected: try condition(entry.path, in: conditionsByPath)
                )
            }
        }
    }

    private func condition(
        _ rawPath: String,
        in values: [String: POSIXWorkspaceTargetCondition]
    ) throws -> POSIXWorkspaceTargetCondition {
        let path = try POSIXRelativePath(
            rawPath,
            allowRoot: false,
            maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
            maximumDepth: limits.maximumDepth
        ).string
        guard let value = values[path] else {
            throw POSIXWorkspaceInfrastructureError.authorizationMismatch
        }
        return value
    }

    private func writeAtomically(
        _ data: Data,
        path rawPath: String,
        root: POSIXWorkspaceRootFD,
        expected: POSIXWorkspaceTargetCondition
    ) throws {
        guard UInt64(data.count) <= limits.maximumSingleFileBytes else {
            throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
        }
        let path = try checkedPath(rawPath)
        let parent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: path,
            createIntermediates: true
        )
        try POSIXWorkspaceFD.verifyAncestry(parent.fd, reaches: root)
        let temporaryName = ".novaforge-write-\(UUID().uuidString)"
        let temporary = try POSIXWorkspaceFD.createRegularFile(
            parent: parent.fd,
            name: temporaryName,
            mode: 0o600
        )
        var published = false
        defer {
            if !published {
                try? POSIXWorkspaceFD.unlink(
                    parent: parent.fd,
                    name: temporaryName,
                    directory: false
                )
            }
        }
        try POSIXWorkspaceFD.writeAll(data, to: temporary.fd)
        if expected.objectKind == .regularFile,
           let existing = try POSIXWorkspaceFD.statNoFollow(
               parent: parent.fd,
               name: path.leaf
           ) {
            _ = fchmod(temporary.fd, existing.st_mode & 0o777)
        }
        try POSIXWorkspaceFD.sync(temporary.fd)
        try POSIXWorkspaceFD.verifyFinalState(
            parent: parent.fd,
            leaf: path.leaf,
            expected: expected
        )
        try POSIXWorkspaceFD.verifyAncestry(parent.fd, reaches: root)
        try interposition.beforeFinalFilesystemCommit()
        if expected.disposition == .existingObject {
            guard expected.objectKind == .regularFile else {
                throw POSIXWorkspaceInfrastructureError.unsupportedOperation
            }
            let quarantine = try POSIXWorkspaceFD.quarantineExpected(
                parent: parent.fd,
                leaf: path.leaf,
                expected: expected
            )
            do {
                try POSIXWorkspaceFD.renameExclusive(
                    fromParent: parent.fd,
                    from: temporaryName,
                    toParent: parent.fd,
                    to: path.leaf
                )
                published = true
                try POSIXWorkspaceFD.removeNode(
                    parent: parent.fd,
                    name: quarantine
                )
            } catch {
                try? POSIXWorkspaceFD.restoreQuarantine(
                    parent: parent.fd,
                    quarantine: quarantine,
                    leaf: path.leaf
                )
                throw error
            }
        } else {
            try POSIXWorkspaceFD.renameExclusive(
                fromParent: parent.fd,
                from: temporaryName,
                toParent: parent.fd,
                to: path.leaf
            )
            published = true
        }
        try POSIXWorkspaceFD.sync(parent.fd)
    }

    private func append(
        _ data: Data,
        path rawPath: String,
        root: POSIXWorkspaceRootFD,
        expected: POSIXWorkspaceTargetCondition
    ) throws {
        guard UInt64(data.count) <= limits.maximumSingleFileBytes else {
            throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
        }
        let path = try checkedPath(rawPath)
        let parent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: path,
            createIntermediates: true
        )
        try POSIXWorkspaceFD.verifyFinalState(
            parent: parent.fd,
            leaf: path.leaf,
            expected: expected
        )
        try POSIXWorkspaceFD.verifyAncestry(parent.fd, reaches: root)
        let openedName: String
        let quarantine: String?
        if expected.disposition == .existingObject {
            let value = try POSIXWorkspaceFD.quarantineExpected(
                parent: parent.fd,
                leaf: path.leaf,
                expected: expected
            )
            openedName = value
            quarantine = value
        } else {
            openedName = path.leaf
            quarantine = nil
        }
        let flags = quarantine == nil
            ? O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
            : O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        let fd = openedName.withCString {
            openat(parent.fd, $0, flags, mode_t(0o600))
        }
        guard fd >= 0 else {
            if let quarantine {
                try? POSIXWorkspaceFD.restoreQuarantine(
                    parent: parent.fd,
                    quarantine: quarantine,
                    leaf: path.leaf
                )
            }
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        let file = POSIXOwnedFD(fd)
        let opened = try POSIXWorkspaceFD.stat(file.fd)
        guard POSIXWorkspaceFD.isRegular(opened), opened.st_nlink == 1 else {
            throw POSIXWorkspaceInfrastructureError.unsafeFilesystemObject
        }
        if expected.disposition == .existingObject {
            try POSIXWorkspaceFD.verifyIdentity(opened, expected: expected)
        }
        try POSIXWorkspaceFD.writeAll(data, to: file.fd)
        try POSIXWorkspaceFD.sync(file.fd)
        if let quarantine {
            do {
                try POSIXWorkspaceFD.renameExclusive(
                    fromParent: parent.fd,
                    from: quarantine,
                    toParent: parent.fd,
                    to: path.leaf
                )
            } catch {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
        }
        try POSIXWorkspaceFD.sync(parent.fd)
    }

    private func replaceText(
        path rawPath: String,
        old: Data,
        new: Data,
        replaceAll: Bool,
        root: POSIXWorkspaceRootFD,
        expected: POSIXWorkspaceTargetCondition
    ) throws {
        guard !old.isEmpty, expected.objectKind == .regularFile else {
            throw POSIXWorkspaceInfrastructureError.unsupportedOperation
        }
        let path = try checkedPath(rawPath)
        let parent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: path,
            createIntermediates: false
        )
        try POSIXWorkspaceFD.verifyFinalState(
            parent: parent.fd,
            leaf: path.leaf,
            expected: expected
        )
        let source = try POSIXWorkspaceFD.openRegularFile(
            parent: parent.fd,
            name: path.leaf,
            writable: false
        )
        try POSIXWorkspaceFD.verifyIdentity(source.stat, expected: expected)
        let data = try POSIXWorkspaceFD.readAll(
            from: source.fd,
            maximumBytes: limits.maximumSingleFileBytes
        )
        let matches = data.ranges(of: old)
        guard !matches.isEmpty else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        guard replaceAll || matches.count == 1 else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        let replaced = data.replacing(
            ranges: replaceAll ? matches : Array(matches.prefix(1)),
            with: new
        )
        try writeAtomically(
            replaced,
            path: path.string,
            root: root,
            expected: expected
        )
    }

    private func remove(
        path rawPath: String,
        root: POSIXWorkspaceRootFD,
        expected: POSIXWorkspaceTargetCondition
    ) throws {
        let path = try checkedPath(rawPath)
        let parent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: path,
            createIntermediates: false
        )
        try POSIXWorkspaceFD.verifyFinalState(
            parent: parent.fd,
            leaf: path.leaf,
            expected: expected
        )
        try POSIXWorkspaceFD.verifyAncestry(parent.fd, reaches: root)
        let quarantine = try POSIXWorkspaceFD.quarantineExpected(
            parent: parent.fd,
            leaf: path.leaf,
            expected: expected
        )
        try POSIXWorkspaceFD.removeNode(parent: parent.fd, name: quarantine)
        try POSIXWorkspaceFD.sync(parent.fd)
    }

    private func move(
        from rawSource: String,
        to rawDestination: String,
        root: POSIXWorkspaceRootFD,
        source: POSIXWorkspaceTargetCondition,
        destination: POSIXWorkspaceTargetCondition
    ) throws {
        let sourcePath = try checkedPath(rawSource)
        let destinationPath = try checkedPath(rawDestination)
        guard sourcePath.string != destinationPath.string,
              !destinationPath.string.hasPrefix(sourcePath.string + "/")
        else {
            throw POSIXWorkspaceInfrastructureError.invalidRelativePath
        }
        let sourceParent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: sourcePath,
            createIntermediates: false
        )
        let destinationParent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: destinationPath,
            createIntermediates: true
        )
        try POSIXWorkspaceFD.verifyFinalState(
            parent: sourceParent.fd,
            leaf: sourcePath.leaf,
            expected: source
        )
        try POSIXWorkspaceFD.verifyFinalState(
            parent: destinationParent.fd,
            leaf: destinationPath.leaf,
            expected: destination
        )
        if destination.objectKind == .directory {
            throw POSIXWorkspaceInfrastructureError.unsupportedOperation
        }
        try POSIXWorkspaceFD.verifyAncestry(sourceParent.fd, reaches: root)
        try POSIXWorkspaceFD.verifyAncestry(destinationParent.fd, reaches: root)
        let sourceQuarantine = try POSIXWorkspaceFD.quarantineExpected(
            parent: sourceParent.fd,
            leaf: sourcePath.leaf,
            expected: source
        )
        let destinationQuarantine: String?
        do {
            destinationQuarantine = destination.disposition == .existingObject
                ? try POSIXWorkspaceFD.quarantineExpected(
                    parent: destinationParent.fd,
                    leaf: destinationPath.leaf,
                    expected: destination
                )
                : nil
        } catch {
            try? POSIXWorkspaceFD.restoreQuarantine(
                parent: sourceParent.fd,
                quarantine: sourceQuarantine,
                leaf: sourcePath.leaf
            )
            throw error
        }
        do {
            try POSIXWorkspaceFD.renameExclusive(
                fromParent: sourceParent.fd,
                from: sourceQuarantine,
                toParent: destinationParent.fd,
                to: destinationPath.leaf
            )
        } catch {
            if let destinationQuarantine {
                try? POSIXWorkspaceFD.restoreQuarantine(
                    parent: destinationParent.fd,
                    quarantine: destinationQuarantine,
                    leaf: destinationPath.leaf
                )
            }
            try? POSIXWorkspaceFD.restoreQuarantine(
                parent: sourceParent.fd,
                quarantine: sourceQuarantine,
                leaf: sourcePath.leaf
            )
            throw error
        }
        if let destinationQuarantine {
            try POSIXWorkspaceFD.removeNode(
                parent: destinationParent.fd,
                name: destinationQuarantine
            )
        }
        try POSIXWorkspaceFD.sync(sourceParent.fd)
        if sourceParent.statIdentity != destinationParent.statIdentity {
            try POSIXWorkspaceFD.sync(destinationParent.fd)
        }
    }

    private func copy(
        from rawSource: String,
        to rawDestination: String,
        root: POSIXWorkspaceRootFD,
        source: POSIXWorkspaceTargetCondition,
        destination: POSIXWorkspaceTargetCondition
    ) throws {
        let sourcePath = try checkedPath(rawSource)
        let destinationPath = try checkedPath(rawDestination)
        guard sourcePath.string != destinationPath.string,
              !destinationPath.string.hasPrefix(sourcePath.string + "/")
        else {
            throw POSIXWorkspaceInfrastructureError.invalidRelativePath
        }
        let sourceParent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: sourcePath,
            createIntermediates: false
        )
        let destinationParent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: destinationPath,
            createIntermediates: true
        )
        try POSIXWorkspaceFD.verifyFinalState(
            parent: sourceParent.fd,
            leaf: sourcePath.leaf,
            expected: source
        )
        try POSIXWorkspaceFD.verifyFinalState(
            parent: destinationParent.fd,
            leaf: destinationPath.leaf,
            expected: destination
        )
        guard destination.objectKind != .directory else {
            throw POSIXWorkspaceInfrastructureError.unsupportedOperation
        }
        let sourceQuarantine = try POSIXWorkspaceFD.quarantineExpected(
            parent: sourceParent.fd,
            leaf: sourcePath.leaf,
            expected: source
        )
        let temporaryName = ".novaforge-copy-\(UUID().uuidString)"
        var published = false
        defer {
            if !published {
                try? POSIXWorkspaceFD.removeNode(
                    parent: destinationParent.fd,
                    name: temporaryName
                )
            }
        }
        do {
            try POSIXWorkspaceFD.copyNode(
                sourceParent: sourceParent.fd,
                sourceName: sourceQuarantine,
                destinationParent: destinationParent.fd,
                destinationName: temporaryName,
                limits: limits
            )
            try POSIXWorkspaceFD.restoreQuarantine(
                parent: sourceParent.fd,
                quarantine: sourceQuarantine,
                leaf: sourcePath.leaf
            )
            try POSIXWorkspaceFD.verifyFinalState(
                parent: sourceParent.fd,
                leaf: sourcePath.leaf,
                expected: source
            )
        } catch {
            try? POSIXWorkspaceFD.restoreQuarantine(
                parent: sourceParent.fd,
                quarantine: sourceQuarantine,
                leaf: sourcePath.leaf
            )
            throw error
        }
        try POSIXWorkspaceFD.verifyFinalState(
            parent: destinationParent.fd,
            leaf: destinationPath.leaf,
            expected: destination
        )
        try POSIXWorkspaceFD.verifyAncestry(sourceParent.fd, reaches: root)
        try POSIXWorkspaceFD.verifyAncestry(destinationParent.fd, reaches: root)
        let destinationQuarantine = destination.disposition == .existingObject
            ? try POSIXWorkspaceFD.quarantineExpected(
                parent: destinationParent.fd,
                leaf: destinationPath.leaf,
                expected: destination
            )
            : nil
        do {
            try POSIXWorkspaceFD.renameExclusive(
                fromParent: destinationParent.fd,
                from: temporaryName,
                toParent: destinationParent.fd,
                to: destinationPath.leaf
            )
            published = true
        } catch {
            if let destinationQuarantine {
                try? POSIXWorkspaceFD.restoreQuarantine(
                    parent: destinationParent.fd,
                    quarantine: destinationQuarantine,
                    leaf: destinationPath.leaf
                )
            }
            throw error
        }
        if let destinationQuarantine {
            try POSIXWorkspaceFD.removeNode(
                parent: destinationParent.fd,
                name: destinationQuarantine
            )
        }
        try POSIXWorkspaceFD.sync(destinationParent.fd)
    }

    private func makeDirectory(
        path rawPath: String,
        root: POSIXWorkspaceRootFD,
        expected: POSIXWorkspaceTargetCondition
    ) throws {
        let path = try checkedPath(rawPath)
        let parent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: path,
            createIntermediates: true
        )
        try POSIXWorkspaceFD.verifyFinalState(
            parent: parent.fd,
            leaf: path.leaf,
            expected: expected
        )
        if expected.objectKind == .directory { return }
        guard expected.disposition == .creatableDestination,
              path.leaf.withCString({ mkdirat(parent.fd, $0, 0o700) }) == 0
        else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        let created = try POSIXWorkspaceFD.openDirectory(
            parent: parent.fd,
            name: path.leaf
        )
        try POSIXWorkspaceFD.verifyAncestry(created.fd, reaches: root)
        try POSIXWorkspaceFD.sync(created.fd)
        try POSIXWorkspaceFD.sync(parent.fd)
    }

    private func touch(
        path rawPath: String,
        root: POSIXWorkspaceRootFD,
        expected: POSIXWorkspaceTargetCondition
    ) throws {
        let path = try checkedPath(rawPath)
        if expected.disposition == .creatableDestination {
            try writeAtomically(Data(), path: path.string, root: root, expected: expected)
            return
        }
        let parent = try POSIXWorkspaceFD.openParent(
            root: root,
            path: path,
            createIntermediates: false
        )
        try POSIXWorkspaceFD.verifyFinalState(
            parent: parent.fd,
            leaf: path.leaf,
            expected: expected
        )
        let quarantine = try POSIXWorkspaceFD.quarantineExpected(
            parent: parent.fd,
            leaf: path.leaf,
            expected: expected
        )
        let file = try POSIXWorkspaceFD.openRegularFile(
            parent: parent.fd,
            name: quarantine,
            writable: false
        )
        try POSIXWorkspaceFD.verifyIdentity(file.stat, expected: expected)
        guard futimens(file.fd, nil) == 0 else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        try POSIXWorkspaceFD.sync(file.fd)
        try POSIXWorkspaceFD.restoreQuarantine(
            parent: parent.fd,
            quarantine: quarantine,
            leaf: path.leaf
        )
        try POSIXWorkspaceFD.sync(parent.fd)
    }

    private func checkedPath(_ value: String) throws -> POSIXRelativePath {
        try POSIXRelativePath(
            value,
            allowRoot: false,
            maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
            maximumDepth: limits.maximumDepth
        )
    }

    private static func detailMaterial(
        _ mutation: POSIXWorkspaceMutation,
        after: PolicySHA256Digest
    ) -> String {
        let tag: String
        switch mutation {
        case .writeFile: tag = "write"
        case .appendFile: tag = "append"
        case .replaceText: tag = "replace"
        case .deletePath: tag = "delete"
        case .movePath: tag = "move"
        case .copyPath: tag = "copy"
        case .makeDirectory: tag = "mkdir"
        case .createFile: tag = "create"
        case .touchFile: tag = "touch"
        case .resetWorkspace: tag = "reset"
        case .seedWorkspace: tag = "seed"
        }
        return "\(tag)\u{0}\(after.rawValue)"
    }
}

struct POSIXRelativePath: Equatable, Hashable, Sendable {
    let components: [String]

    var string: String { components.joined(separator: "/") }
    var leaf: String { components.last ?? "" }
    var parentComponents: ArraySlice<String> { components.dropLast() }

    init(
        _ raw: String,
        allowRoot: Bool,
        maximumUTF8Bytes: Int = 4_096,
        maximumDepth: Int = 64
    ) throws {
        guard raw == raw.precomposedStringWithCanonicalMapping,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.utf8.count <= maximumUTF8Bytes,
              !raw.hasPrefix("/"),
              !raw.contains("\\"),
              raw.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && scalar.properties.generalCategory != .format
              })
        else {
            throw POSIXWorkspaceInfrastructureError.invalidRelativePath
        }
        if raw.isEmpty {
            guard allowRoot else {
                throw POSIXWorkspaceInfrastructureError.invalidRelativePath
            }
            components = []
            return
        }
        let values = raw.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !values.isEmpty,
              values.count <= maximumDepth,
              values.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && component.utf8.count <= Int(NAME_MAX)
                      && component == component.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      )
              })
        else {
            throw POSIXWorkspaceInfrastructureError.invalidRelativePath
        }
        components = values
    }
}

final class POSIXOwnedFD {
    let fd: Int32

    init(_ fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }
}

struct POSIXWorkspaceRootFD {
    let descriptor: POSIXOwnedFD
    let stat: stat

    var fd: Int32 { descriptor.fd }
}

struct POSIXWorkspaceContainerFD {
    let descriptor: POSIXOwnedFD
    let stat: stat

    var fd: Int32 { descriptor.fd }
}

struct POSIXWorkspaceDirectoryFD {
    let descriptor: POSIXOwnedFD
    let stat: stat

    var fd: Int32 { descriptor.fd }
    var statIdentity: POSIXIdentity {
        POSIXIdentity(device: UInt64(stat.st_dev), inode: UInt64(stat.st_ino))
    }
}

struct POSIXWorkspaceRegularFileFD {
    let descriptor: POSIXOwnedFD
    let stat: stat

    var fd: Int32 { descriptor.fd }
}

struct POSIXIdentity: Equatable, Hashable, Codable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct POSIXWorkspaceCurrentTargetState {
    let containment: stat
    let object: stat?
}

enum POSIXWorkspaceFD {
    static func openContainer(at url: URL) throws -> POSIXWorkspaceContainerFD {
        let fd = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return open(
                pointer,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard fd >= 0 else {
            throw POSIXWorkspaceInfrastructureError.workspaceUnavailable
        }
        let owned = POSIXOwnedFD(fd)
        let metadata = try stat(fd)
        guard isDirectory(metadata) else {
            throw POSIXWorkspaceInfrastructureError.workspaceUnavailable
        }
        return POSIXWorkspaceContainerFD(descriptor: owned, stat: metadata)
    }

    static func openRoot(at url: URL) throws -> POSIXWorkspaceRootFD {
        let fd = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return open(
                pointer,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard fd >= 0 else {
            throw POSIXWorkspaceInfrastructureError.workspaceUnavailable
        }
        let owned = POSIXOwnedFD(fd)
        let metadata = try stat(fd)
        guard isDirectory(metadata) else {
            throw POSIXWorkspaceInfrastructureError.workspaceUnavailable
        }
        return POSIXWorkspaceRootFD(descriptor: owned, stat: metadata)
    }

    static func openRoot(
        container: POSIXWorkspaceContainerFD,
        name: String
    ) throws -> POSIXWorkspaceRootFD? {
        _ = try POSIXRelativePath(
            name,
            allowRoot: false,
            maximumDepth: 1
        )
        guard let metadata = try statNoFollow(
            parent: container.fd,
            name: name
        ) else {
            return nil
        }
        guard isDirectory(metadata), !isSymlink(metadata) else {
            throw POSIXWorkspaceInfrastructureError
                .unsafeFilesystemObject
        }
        let directory = try openDirectory(parent: container.fd, name: name)
        guard sameIdentity(directory.stat, metadata) else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        return POSIXWorkspaceRootFD(
            descriptor: directory.descriptor,
            stat: directory.stat
        )
    }

    static func createRoot(
        container: POSIXWorkspaceContainerFD,
        name: String
    ) throws -> POSIXWorkspaceRootFD {
        _ = try POSIXRelativePath(
            name,
            allowRoot: false,
            maximumDepth: 1
        )
        guard name.withCString({ mkdirat(container.fd, $0, 0o700) }) == 0 else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        try sync(container.fd)
        guard let root = try openRoot(container: container, name: name) else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        return root
    }

    static func verifyRoot(_ root: POSIXWorkspaceRootFD) throws {
        let current = try stat(root.fd)
        guard sameIdentity(current, root.stat), isDirectory(current) else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
    }

    static func targetState(
        root: POSIXWorkspaceRootFD,
        path: POSIXRelativePath
    ) throws -> POSIXWorkspaceCurrentTargetState {
        if path.components.isEmpty {
            return POSIXWorkspaceCurrentTargetState(
                containment: root.stat,
                object: root.stat
            )
        }
        var directory = POSIXWorkspaceDirectoryFD(
            descriptor: POSIXOwnedFD(try duplicate(root.fd)),
            stat: root.stat
        )
        for (index, component) in path.components.enumerated() {
            let metadata = try statNoFollow(parent: directory.fd, name: component)
            guard let metadata else {
                return POSIXWorkspaceCurrentTargetState(
                    containment: directory.stat,
                    object: nil
                )
            }
            if index == path.components.count - 1 {
                guard !isSymlink(metadata),
                      isRegular(metadata) || isDirectory(metadata)
                else {
                    throw POSIXWorkspaceInfrastructureError
                        .unsafeFilesystemObject
                }
                return POSIXWorkspaceCurrentTargetState(
                    containment: directory.stat,
                    object: metadata
                )
            }
            guard isDirectory(metadata), !isSymlink(metadata) else {
                throw POSIXWorkspaceInfrastructureError
                    .unsafeFilesystemObject
            }
            directory = try openDirectory(parent: directory.fd, name: component)
        }
        throw POSIXWorkspaceInfrastructureError.operationFailed
    }

    static func openParent(
        root: POSIXWorkspaceRootFD,
        path: POSIXRelativePath,
        createIntermediates: Bool
    ) throws -> POSIXWorkspaceDirectoryFD {
        guard !path.components.isEmpty else {
            throw POSIXWorkspaceInfrastructureError.invalidRelativePath
        }
        var directory = POSIXWorkspaceDirectoryFD(
            descriptor: POSIXOwnedFD(try duplicate(root.fd)),
            stat: root.stat
        )
        for component in path.parentComponents {
            do {
                directory = try openDirectory(
                    parent: directory.fd,
                    name: component
                )
            } catch POSIXWorkspaceInfrastructureError.targetChanged
                where createIntermediates {
                let result = component.withCString {
                    mkdirat(directory.fd, $0, 0o700)
                }
                guard result == 0 || errno == EEXIST else {
                    throw POSIXWorkspaceInfrastructureError.operationFailed
                }
                directory = try openDirectory(
                    parent: directory.fd,
                    name: component
                )
            }
        }
        try verifyAncestry(directory.fd, reaches: root)
        return directory
    }

    static func openDirectory(
        parent: Int32,
        name: String
    ) throws -> POSIXWorkspaceDirectoryFD {
        let fd = name.withCString {
            openat(
                parent,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard fd >= 0 else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        let owned = POSIXOwnedFD(fd)
        let metadata = try stat(fd)
        guard isDirectory(metadata) else {
            throw POSIXWorkspaceInfrastructureError.unsafeFilesystemObject
        }
        return POSIXWorkspaceDirectoryFD(descriptor: owned, stat: metadata)
    }

    static func openRegularFile(
        parent: Int32,
        name: String,
        writable: Bool
    ) throws -> POSIXWorkspaceRegularFileFD {
        let access = writable ? O_RDWR : O_RDONLY
        let fd = name.withCString {
            openat(parent, $0, access | O_CLOEXEC | O_NOFOLLOW)
        }
        guard fd >= 0 else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        let owned = POSIXOwnedFD(fd)
        let metadata = try stat(fd)
        guard isRegular(metadata), metadata.st_nlink == 1 else {
            throw POSIXWorkspaceInfrastructureError.unsafeFilesystemObject
        }
        return POSIXWorkspaceRegularFileFD(
            descriptor: owned,
            stat: metadata
        )
    }

    static func createRegularFile(
        parent: Int32,
        name: String,
        mode: mode_t
    ) throws -> POSIXWorkspaceRegularFileFD {
        let fd = name.withCString {
            openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode
            )
        }
        guard fd >= 0 else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        let owned = POSIXOwnedFD(fd)
        let metadata = try stat(fd)
        guard isRegular(metadata), metadata.st_nlink == 1 else {
            throw POSIXWorkspaceInfrastructureError.unsafeFilesystemObject
        }
        return POSIXWorkspaceRegularFileFD(
            descriptor: owned,
            stat: metadata
        )
    }

    static func verifyFinalState(
        parent: Int32,
        leaf: String,
        expected: POSIXWorkspaceTargetCondition
    ) throws {
        let current = try statNoFollow(parent: parent, name: leaf)
        switch expected.disposition {
        case .creatableDestination:
            guard current == nil else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
        case .existingObject:
            guard let current else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
            try verifyIdentity(current, expected: expected)
        }
    }

    static func verifyIdentity(
        _ metadata: stat,
        expected: POSIXWorkspaceTargetCondition
    ) throws {
        guard expected.objectDevice == UInt64(metadata.st_dev),
              expected.objectInode == UInt64(metadata.st_ino),
              expected.objectLinkCount == UInt64(metadata.st_nlink),
              expected.objectKind == objectKind(metadata)
        else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        if isRegular(metadata), metadata.st_nlink != 1 {
            throw POSIXWorkspaceInfrastructureError.unsafeFilesystemObject
        }
    }

    static func verifyAncestry(
        _ directoryFD: Int32,
        reaches root: POSIXWorkspaceRootFD
    ) throws {
        var current = POSIXWorkspaceDirectoryFD(
            descriptor: POSIXOwnedFD(try duplicate(directoryFD)),
            stat: try stat(directoryFD)
        )
        for _ in 0 ... 128 {
            if sameIdentity(current.stat, root.stat) { return }
            let parent = try openDirectory(parent: current.fd, name: "..")
            guard !sameIdentity(parent.stat, current.stat) else { break }
            current = parent
        }
        throw POSIXWorkspaceInfrastructureError.targetChanged
    }

    static func statNoFollow(parent: Int32, name: String) throws -> stat? {
        var metadata = Darwin.stat()
        let result = name.withCString {
            fstatat(parent, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if result == 0 { return metadata }
        if errno == ENOENT { return nil }
        throw POSIXWorkspaceInfrastructureError.operationFailed
    }

    static func stat(_ fd: Int32) throws -> stat {
        var metadata = Darwin.stat()
        guard fstat(fd, &metadata) == 0 else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        return metadata
    }

    static func duplicate(_ fd: Int32) throws -> Int32 {
        let value = dup(fd)
        guard value >= 0 else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        return value
    }

    static func identityToken(_ metadata: stat) -> String {
        "posix-v1:\(UInt64(metadata.st_dev)):\(UInt64(metadata.st_ino))"
    }

    static func containmentToken(
        _ metadata: stat,
        targetPath: String
    ) -> String {
        let material = Data(
            "\(identityToken(metadata))\u{0}\(targetPath)".utf8
        )
        let digest = CryptoKit.SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
        return "posix-containment-v1:\(digest)"
    }

    static func missingRootIdentityToken(
        container: stat,
        rootName: String
    ) -> String {
        let nameDigest = CryptoKit.SHA256.hash(data: Data(rootName.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "posix-missing-root-v1:\(UInt64(container.st_dev)):\(UInt64(container.st_ino)):\(nameDigest)"
    }

    static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    static func objectKind(_ metadata: stat) -> POSIXWorkspaceObjectKind {
        if isRegular(metadata) { return .regularFile }
        if isDirectory(metadata) { return .directory }
        return .absent
    }

    static func isRegular(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
    }

    static func isDirectory(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFDIR
    }

    static func isSymlink(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFLNK
    }

    static func sync(_ fd: Int32) throws {
        guard fsync(fd) == 0 else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fd,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw POSIXWorkspaceInfrastructureError.operationFailed
                }
                offset += written
            }
        }
    }

    static func readAll(
        from fd: Int32,
        maximumBytes: UInt64
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var offset: off_t = 0
        while true {
            let count = pread(fd, &buffer, buffer.count, offset)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw POSIXWorkspaceInfrastructureError.operationFailed
            }
            if count == 0 { return result }
            guard UInt64(result.count + count) <= maximumBytes else {
                throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
            }
            result.append(buffer, count: count)
            offset += off_t(count)
        }
    }

    static func listNames(_ directoryFD: Int32) throws -> [String] {
        // `dup` shares one open-file-description offset with `directoryFD`.
        // Enumerating the duplicate would therefore leave later integrity
        // scans at EOF. Opening `.` relative to the pinned descriptor gives
        // this enumeration its own offset without resolving an ambient path.
        let independent = ".".withCString {
            openat(
                directoryFD,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard independent >= 0 else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        do {
            guard sameIdentity(
                try stat(directoryFD),
                try stat(independent)
            ) else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
        } catch {
            Darwin.close(independent)
            throw error
        }
        guard let stream = fdopendir(independent) else {
            Darwin.close(independent)
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(NAME_MAX) + 1
                ) {
                    String(validatingCString: $0)
                }
            }
            guard let name else {
                throw POSIXWorkspaceInfrastructureError
                    .unsafeFilesystemObject
            }
            if name == "." || name == ".." { continue }
            result.append(name)
            errno = 0
        }
        guard errno == 0 else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
        return result.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    static func removeAllChildren(of directoryFD: Int32) throws {
        for name in try listNames(directoryFD) {
            try removeNode(parent: directoryFD, name: name)
        }
    }

    static func removeNode(parent: Int32, name: String) throws {
        guard let metadata = try statNoFollow(parent: parent, name: name) else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        if isDirectory(metadata) {
            let directory = try openDirectory(parent: parent, name: name)
            try removeAllChildren(of: directory.fd)
            try sync(directory.fd)
            try unlink(parent: parent, name: name, directory: true)
        } else if isRegular(metadata), metadata.st_nlink == 1 {
            try unlink(parent: parent, name: name, directory: false)
        } else {
            throw POSIXWorkspaceInfrastructureError.unsafeFilesystemObject
        }
    }

    static func unlink(parent: Int32, name: String, directory: Bool) throws {
        let flags = directory ? AT_REMOVEDIR : 0
        guard name.withCString({ unlinkat(parent, $0, flags) }) == 0 else {
            throw POSIXWorkspaceInfrastructureError.operationFailed
        }
    }

    static func renameExclusive(
        fromParent: Int32,
        from: String,
        toParent: Int32,
        to: String
    ) throws {
        let result = from.withCString { source in
            to.withCString { destination in
                renameatx_np(
                    fromParent,
                    source,
                    toParent,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
    }

    static func quarantineExpected(
        parent: Int32,
        leaf: String,
        expected: POSIXWorkspaceTargetCondition
    ) throws -> String {
        guard expected.disposition == .existingObject else {
            throw POSIXWorkspaceInfrastructureError.authorizationMismatch
        }
        let quarantine = ".novaforge-quarantine-\(UUID().uuidString)"
        try renameExclusive(
            fromParent: parent,
            from: leaf,
            toParent: parent,
            to: quarantine
        )
        do {
            guard let moved = try statNoFollow(
                parent: parent,
                name: quarantine
            ) else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
            try verifyIdentity(moved, expected: expected)
            return quarantine
        } catch {
            try? restoreQuarantine(
                parent: parent,
                quarantine: quarantine,
                leaf: leaf
            )
            throw error
        }
    }

    static func restoreQuarantine(
        parent: Int32,
        quarantine: String,
        leaf: String
    ) throws {
        try renameExclusive(
            fromParent: parent,
            from: quarantine,
            toParent: parent,
            to: leaf
        )
    }

    static func copyNode(
        sourceParent: Int32,
        sourceName: String,
        destinationParent: Int32,
        destinationName: String,
        limits: POSIXWorkspaceLimits,
        depth: Int = 0
    ) throws {
        guard depth <= limits.maximumDepth,
              let source = try statNoFollow(
                  parent: sourceParent,
                  name: sourceName
              )
        else {
            throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
        }
        if isRegular(source), source.st_nlink == 1 {
            let input = try openRegularFile(
                parent: sourceParent,
                name: sourceName,
                writable: false
            )
            guard UInt64(source.st_size) <= limits.maximumSingleFileBytes else {
                throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
            }
            let output = try createRegularFile(
                parent: destinationParent,
                name: destinationName,
                mode: source.st_mode & 0o777
            )
            let data = try readAll(
                from: input.fd,
                maximumBytes: limits.maximumSingleFileBytes
            )
            try writeAll(data, to: output.fd)
            guard fchmod(output.fd, source.st_mode & 0o777) == 0 else {
                throw POSIXWorkspaceInfrastructureError.operationFailed
            }
            try sync(output.fd)
            let after = try stat(input.fd)
            guard stableFileSnapshot(source, after) else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
        } else if isDirectory(source) {
            guard destinationName.withCString({
                mkdirat(destinationParent, $0, source.st_mode & 0o777)
            }) == 0 else {
                throw POSIXWorkspaceInfrastructureError.operationFailed
            }
            let input = try openDirectory(
                parent: sourceParent,
                name: sourceName
            )
            let output = try openDirectory(
                parent: destinationParent,
                name: destinationName
            )
            for name in try listNames(input.fd) {
                try copyNode(
                    sourceParent: input.fd,
                    sourceName: name,
                    destinationParent: output.fd,
                    destinationName: name,
                    limits: limits,
                    depth: depth + 1
                )
            }
            guard fchmod(output.fd, source.st_mode & 0o777) == 0 else {
                throw POSIXWorkspaceInfrastructureError.operationFailed
            }
            try sync(output.fd)
            let after = try stat(input.fd)
            guard stableDirectorySnapshot(source, after) else {
                throw POSIXWorkspaceInfrastructureError.targetChanged
            }
        } else {
            throw POSIXWorkspaceInfrastructureError.unsafeFilesystemObject
        }
    }

    static func stableFileSnapshot(_ before: stat, _ after: stat) -> Bool {
        sameIdentity(before, after)
            && before.st_nlink == after.st_nlink
            && before.st_size == after.st_size
            && before.st_mode == after.st_mode
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    static func stableDirectorySnapshot(_ before: stat, _ after: stat) -> Bool {
        sameIdentity(before, after)
            && before.st_nlink == after.st_nlink
            && before.st_mode == after.st_mode
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }
}

struct POSIXWorkspaceSnapshotEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case directory, regularFile }

    let path: String
    let kind: Kind
    let mode: UInt16
    let device: UInt64
    let inode: UInt64
    let linkCount: UInt64
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
    let contentSHA256: PolicySHA256Digest?
}

struct POSIXWorkspaceSnapshot: Codable, Equatable, Sendable {
    let entries: [POSIXWorkspaceSnapshotEntry]
    let physicalSHA256: PolicySHA256Digest
}

enum POSIXWorkspaceTree {
    private struct DigestMaterial: Encodable {
        let scheme = "novaforge-posix-workspace-state-v1"
        let entries: [POSIXWorkspaceSnapshotEntry]
    }

    private struct MissingRootMaterial: Encodable {
        let scheme = "novaforge-posix-missing-workspace-root-v1"
        let rootIdentity: String
        let containmentIdentity: String
    }

    static func missingRootSHA256(
        container: stat,
        rootName: String
    ) throws -> PolicySHA256Digest {
        try POSIXWorkspaceDigest.sha256(
            domain: "workspace-physical-state-v1",
            encodable: MissingRootMaterial(
                rootIdentity: POSIXWorkspaceFD.missingRootIdentityToken(
                    container: container,
                    rootName: rootName
                ),
                containmentIdentity: POSIXWorkspaceFD.identityToken(container)
            )
        )
    }

    static func capture(
        root: POSIXWorkspaceRootFD,
        limits: POSIXWorkspaceLimits,
        copyTo destinationRoot: Int32? = nil
    ) throws -> POSIXWorkspaceSnapshot {
        let rootBefore = try POSIXWorkspaceFD.stat(root.fd)
        guard POSIXWorkspaceFD.sameIdentity(root.stat, rootBefore),
              POSIXWorkspaceFD.isDirectory(rootBefore)
        else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        var entries: [POSIXWorkspaceSnapshotEntry] = []
        var totalBytes: UInt64 = 0
        let rootEntry = try entry(
            path: "",
            metadata: rootBefore,
            contentSHA256: nil
        )
        entries.append(rootEntry)
        try walk(
            sourceDirectory: root.fd,
            destinationDirectory: destinationRoot,
            prefix: [],
            depth: 0,
            entries: &entries,
            totalBytes: &totalBytes,
            limits: limits
        )
        let rootAfter = try POSIXWorkspaceFD.stat(root.fd)
        guard POSIXWorkspaceFD.stableDirectorySnapshot(
            rootBefore,
            rootAfter
        ) else {
            throw POSIXWorkspaceInfrastructureError.targetChanged
        }
        let digest = try POSIXWorkspaceDigest.sha256(
            domain: "workspace-physical-state-v1",
            encodable: DigestMaterial(entries: entries)
        )
        return POSIXWorkspaceSnapshot(
            entries: entries,
            physicalSHA256: digest
        )
    }

    private static func walk(
        sourceDirectory: Int32,
        destinationDirectory: Int32?,
        prefix: [String],
        depth: Int,
        entries: inout [POSIXWorkspaceSnapshotEntry],
        totalBytes: inout UInt64,
        limits: POSIXWorkspaceLimits
    ) throws {
        guard depth <= limits.maximumDepth else {
            throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
        }
        for name in try POSIXWorkspaceFD.listNames(sourceDirectory) {
            guard entries.count < limits.maximumEntryCount else {
                throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
            }
            let components = prefix + [name]
            let path = components.joined(separator: "/")
            guard path.utf8.count <= limits.maximumPathUTF8Bytes,
                  let before = try POSIXWorkspaceFD.statNoFollow(
                      parent: sourceDirectory,
                      name: name
                  )
            else {
                throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
            }
            if POSIXWorkspaceFD.isRegular(before), before.st_nlink == 1 {
                guard before.st_size >= 0,
                      UInt64(before.st_size) <= limits.maximumSingleFileBytes,
                      totalBytes <= limits.maximumTotalFileBytes
                        - UInt64(before.st_size)
                else {
                    throw POSIXWorkspaceInfrastructureError.resourceLimitExceeded
                }
                let source = try POSIXWorkspaceFD.openRegularFile(
                    parent: sourceDirectory,
                    name: name,
                    writable: false
                )
                let data = try POSIXWorkspaceFD.readAll(
                    from: source.fd,
                    maximumBytes: limits.maximumSingleFileBytes
                )
                let contentDigest = try POSIXWorkspaceDigest.sha256(
                    domain: "workspace-file-content-v1",
                    data: data
                )
                if let destinationDirectory {
                    let output = try POSIXWorkspaceFD.createRegularFile(
                        parent: destinationDirectory,
                        name: name,
                        mode: before.st_mode & 0o777
                    )
                    try POSIXWorkspaceFD.writeAll(data, to: output.fd)
                    guard fchmod(output.fd, before.st_mode & 0o777) == 0 else {
                        throw POSIXWorkspaceInfrastructureError.persistenceFailed
                    }
                    try POSIXWorkspaceFD.sync(output.fd)
                }
                let after = try POSIXWorkspaceFD.stat(source.fd)
                guard POSIXWorkspaceFD.stableFileSnapshot(before, after) else {
                    throw POSIXWorkspaceInfrastructureError.targetChanged
                }
                totalBytes += UInt64(before.st_size)
                entries.append(try entry(
                    path: path,
                    metadata: before,
                    contentSHA256: contentDigest
                ))
            } else if POSIXWorkspaceFD.isDirectory(before) {
                let source = try POSIXWorkspaceFD.openDirectory(
                    parent: sourceDirectory,
                    name: name
                )
                let destination: POSIXWorkspaceDirectoryFD?
                if let destinationDirectory {
                    guard name.withCString({
                        mkdirat(destinationDirectory, $0, before.st_mode & 0o777)
                    }) == 0 else {
                        throw POSIXWorkspaceInfrastructureError.persistenceFailed
                    }
                    destination = try POSIXWorkspaceFD.openDirectory(
                        parent: destinationDirectory,
                        name: name
                    )
                } else {
                    destination = nil
                }
                entries.append(try entry(
                    path: path,
                    metadata: before,
                    contentSHA256: nil
                ))
                try walk(
                    sourceDirectory: source.fd,
                    destinationDirectory: destination?.fd,
                    prefix: components,
                    depth: depth + 1,
                    entries: &entries,
                    totalBytes: &totalBytes,
                    limits: limits
                )
                if let destination {
                    guard fchmod(destination.fd, before.st_mode & 0o777) == 0 else {
                        throw POSIXWorkspaceInfrastructureError.persistenceFailed
                    }
                    try POSIXWorkspaceFD.sync(destination.fd)
                }
                let after = try POSIXWorkspaceFD.stat(source.fd)
                guard POSIXWorkspaceFD.stableDirectorySnapshot(before, after) else {
                    throw POSIXWorkspaceInfrastructureError.targetChanged
                }
            } else {
                throw POSIXWorkspaceInfrastructureError
                    .unsafeFilesystemObject
            }
        }
    }

    private static func entry(
        path: String,
        metadata: stat,
        contentSHA256: PolicySHA256Digest?
    ) throws -> POSIXWorkspaceSnapshotEntry {
        let kind: POSIXWorkspaceSnapshotEntry.Kind
        if POSIXWorkspaceFD.isDirectory(metadata) {
            kind = .directory
        } else if POSIXWorkspaceFD.isRegular(metadata), metadata.st_nlink == 1 {
            kind = .regularFile
        } else {
            throw POSIXWorkspaceInfrastructureError.unsafeFilesystemObject
        }
        return POSIXWorkspaceSnapshotEntry(
            path: path,
            kind: kind,
            mode: UInt16(metadata.st_mode & 0o777),
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            linkCount: UInt64(metadata.st_nlink),
            size: UInt64(max(metadata.st_size, 0)),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec),
            contentSHA256: contentSHA256
        )
    }
}

enum POSIXWorkspaceDigest {
    private struct Envelope<Value: Encodable>: Encodable {
        let scheme: String
        let domain: String
        let value: Value
    }

    private struct DataValue: Encodable { let hexadecimal: String }

    static func sha256(domain: String, data: Data) throws -> PolicySHA256Digest {
        try sha256(
            domain: domain,
            encodable: DataValue(
                hexadecimal: data.map { String(format: "%02x", $0) }.joined()
            )
        )
    }

    static func sha256<Value: Encodable>(
        domain: String,
        encodable value: Value
    ) throws -> PolicySHA256Digest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Envelope(
            scheme: "novaforge-posix-infrastructure-v1",
            domain: domain,
            value: value
        ))
        let digest = CryptoKit.SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return try PolicySHA256Digest("sha256:" + digest)
    }
}

private extension Data {
    func ranges(of needle: Data) -> [Range<Data.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<Data.Index>] = []
        var start = startIndex
        while start < endIndex,
              let range = range(of: needle, options: [], in: start ..< endIndex) {
            result.append(range)
            start = range.upperBound
        }
        return result
    }

    func replacing(
        ranges: [Range<Data.Index>],
        with replacement: Data
    ) -> Data {
        guard !ranges.isEmpty else { return self }
        var result = Data()
        var cursor = startIndex
        for range in ranges {
            result.append(self[cursor ..< range.lowerBound])
            result.append(replacement)
            cursor = range.upperBound
        }
        result.append(self[cursor ..< endIndex])
        return result
    }
}
