import AgentDomain
import AgentTools
import Foundation

/// Exhaustive source identity for every workspace mutation routed through
/// AgentPolicy. This value is security material: requests, permits, claims,
/// lifecycle records, and receipts all bind it into their canonical digests.
public enum MutationOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case agentV2 = "agent_v2"
    case v1Fallback = "v1_fallback"
    case editor
    case files
    case terminal
    case artifact
    case control
    case projectOS = "project_os"
    case trustedSystem = "trusted_system"

    var isProviderAgent: Bool {
        self == .agentV2 || self == .v1Fallback
    }
}

/// Canonical sandbox mutations initiated by the editor surface. Keeping this
/// list distinct prevents an editor caller from relabeling a Files or Terminal
/// operation while still reusing the exact provider-reviewed tool contracts.
public enum EditorCanonicalMutationOperation: Equatable, Sendable {
    case writeFile(WriteFileArguments)
    case replaceText(ReplaceTextArguments)
}

/// Canonical sandbox mutations initiated by the file-management surface.
public enum FilesCanonicalMutationOperation: Equatable, Sendable {
    case writeFile(WriteFileArguments)
    case deletePath(PathArguments)
    case movePath(MovePathArguments)
    case copyPath(MovePathArguments)
    case makeDirectory(PathArguments)
}

/// Canonical sandbox mutations initiated by the terminal surface.
public enum TerminalCanonicalMutationOperation: Equatable, Sendable {
    case runCommand(RunCommandArguments)
}

/// Canonical sandbox mutations used to materialize durable artifacts.
public enum ArtifactCanonicalMutationOperation: Equatable, Sendable {
    case writeFile(WriteFileArguments)
    case appendFile(AppendFileArguments)
}

/// Canonical sandbox mutations initiated by ProjectOS orchestration.
public enum ProjectOSCanonicalMutationOperation: Equatable, Sendable {
    case writeFile(WriteFileArguments)
    case appendFile(AppendFileArguments)
    case replaceText(ReplaceTextArguments)
}

/// Canonical sandbox mutations available only through the explicitly named
/// trusted-system entry point. This broad set does not make the policy-only
/// create/touch/reset/seed contracts provider-visible.
public enum TrustedSystemCanonicalMutationOperation: Equatable, Sendable {
    case writeFile(WriteFileArguments)
    case appendFile(AppendFileArguments)
    case replaceText(ReplaceTextArguments)
    case deletePath(PathArguments)
    case movePath(MovePathArguments)
    case copyPath(MovePathArguments)
    case makeDirectory(PathArguments)
    case runCommand(RunCommandArguments)
}

/// Policy-only file creation initiated by the editor surface.
public enum EditorPolicyMutationOperation: Equatable, Sendable {
    case createFile(CreateFileMutationArguments)
}

/// Policy-only mutations initiated by the file-management surface.
public enum FilesPolicyMutationOperation: Equatable, Sendable {
    case createFile(CreateFileMutationArguments)
    case touchFile(TouchFileMutationArguments)
}

/// Broad lifecycle mutations reserved for ProjectOS orchestration.
public enum ProjectOSPolicyMutationOperation: Equatable, Sendable {
    case resetWorkspace(ResetWorkspaceMutationArguments)
    case seedWorkspace(SeedWorkspaceMutationArguments)
}

/// Policy-only mutations available only through the explicitly named trusted
/// system entry point.
public enum TrustedSystemPolicyMutationOperation: Equatable, Sendable {
    case createFile(CreateFileMutationArguments)
    case touchFile(TouchFileMutationArguments)
    case resetWorkspace(ResetWorkspaceMutationArguments)
    case seedWorkspace(SeedWorkspaceMutationArguments)
}

/// User-initiated workspace lifecycle mutations from the Control surface.
public enum ControlPolicyMutationOperation: Equatable, Sendable {
    case resetWorkspace(ResetWorkspaceMutationArguments)
}

enum CanonicalProviderMutationOperation: Equatable, Sendable {
    case writeFile(WriteFileArguments)
    case appendFile(AppendFileArguments)
    case replaceText(ReplaceTextArguments)
    case deletePath(PathArguments)
    case movePath(MovePathArguments)
    case copyPath(MovePathArguments)
    case makeDirectory(PathArguments)
    case runCommand(RunCommandArguments)
}

extension EditorCanonicalMutationOperation {
    var canonicalProviderOperation: CanonicalProviderMutationOperation {
        switch self {
        case let .writeFile(arguments): .writeFile(arguments)
        case let .replaceText(arguments): .replaceText(arguments)
        }
    }
}

extension FilesCanonicalMutationOperation {
    var canonicalProviderOperation: CanonicalProviderMutationOperation {
        switch self {
        case let .writeFile(arguments): .writeFile(arguments)
        case let .deletePath(arguments): .deletePath(arguments)
        case let .movePath(arguments): .movePath(arguments)
        case let .copyPath(arguments): .copyPath(arguments)
        case let .makeDirectory(arguments): .makeDirectory(arguments)
        }
    }
}

extension TerminalCanonicalMutationOperation {
    var canonicalProviderOperation: CanonicalProviderMutationOperation {
        switch self {
        case let .runCommand(arguments): .runCommand(arguments)
        }
    }
}

extension ArtifactCanonicalMutationOperation {
    var canonicalProviderOperation: CanonicalProviderMutationOperation {
        switch self {
        case let .writeFile(arguments): .writeFile(arguments)
        case let .appendFile(arguments): .appendFile(arguments)
        }
    }
}

extension ProjectOSCanonicalMutationOperation {
    var canonicalProviderOperation: CanonicalProviderMutationOperation {
        switch self {
        case let .writeFile(arguments): .writeFile(arguments)
        case let .appendFile(arguments): .appendFile(arguments)
        case let .replaceText(arguments): .replaceText(arguments)
        }
    }
}

extension TrustedSystemCanonicalMutationOperation {
    var canonicalProviderOperation: CanonicalProviderMutationOperation {
        switch self {
        case let .writeFile(arguments): .writeFile(arguments)
        case let .appendFile(arguments): .appendFile(arguments)
        case let .replaceText(arguments): .replaceText(arguments)
        case let .deletePath(arguments): .deletePath(arguments)
        case let .movePath(arguments): .movePath(arguments)
        case let .copyPath(arguments): .copyPath(arguments)
        case let .makeDirectory(arguments): .makeDirectory(arguments)
        case let .runCommand(arguments): .runCommand(arguments)
        }
    }
}

extension EditorPolicyMutationOperation {
    var nonProviderOperation: NonProviderMutationOperation {
        switch self {
        case let .createFile(arguments): .createFile(arguments)
        }
    }
}

extension FilesPolicyMutationOperation {
    var nonProviderOperation: NonProviderMutationOperation {
        switch self {
        case let .createFile(arguments): .createFile(arguments)
        case let .touchFile(arguments): .touchFile(arguments)
        }
    }
}

extension ProjectOSPolicyMutationOperation {
    var nonProviderOperation: NonProviderMutationOperation {
        switch self {
        case let .resetWorkspace(arguments): .resetWorkspace(arguments)
        case let .seedWorkspace(arguments): .seedWorkspace(arguments)
        }
    }
}

extension TrustedSystemPolicyMutationOperation {
    var nonProviderOperation: NonProviderMutationOperation {
        switch self {
        case let .createFile(arguments): .createFile(arguments)
        case let .touchFile(arguments): .touchFile(arguments)
        case let .resetWorkspace(arguments): .resetWorkspace(arguments)
        case let .seedWorkspace(arguments): .seedWorkspace(arguments)
        }
    }
}

extension ControlPolicyMutationOperation {
    var nonProviderOperation: NonProviderMutationOperation {
        switch self {
        case let .resetWorkspace(arguments): .resetWorkspace(arguments)
        }
    }
}

public struct CreateFileMutationArguments: AgentToolArguments {
    public let path: String

    public init(path: String) { self.path = path }

    public static let jsonSchema: JSONSchema = .object(
        properties: [
            "path": .string(
                description: "A non-empty workspace-relative path.",
                minLength: 1,
                maxLength: 4_096
            ),
        ],
        required: ["path"],
        additionalProperties: false
    )
}

public struct TouchFileMutationArguments: AgentToolArguments {
    public let path: String

    public init(path: String) { self.path = path }

    public static let jsonSchema = CreateFileMutationArguments.jsonSchema
}

public struct ResetWorkspaceMutationArguments: AgentToolArguments {
    public init() {}

    public static let jsonSchema: JSONSchema = .object(
        properties: [:],
        required: [],
        additionalProperties: false
    )
}

public struct SeedWorkspaceEntry: Codable, Equatable, Sendable {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

public struct SeedWorkspaceMutationArguments: AgentToolArguments {
    public let entries: [SeedWorkspaceEntry]

    public init(entries: [SeedWorkspaceEntry]) { self.entries = entries }

    public static let jsonSchema: JSONSchema = .object(
        properties: [
            "entries": .array(
                description: "Exact files and UTF-8 contents to seed.",
                items: .object(
                    properties: [
                        "path": .string(
                            description: "A non-empty workspace-relative path.",
                            minLength: 1,
                            maxLength: 4_096
                        ),
                        "contents": .string(
                            description: "Exact UTF-8 file contents.",
                            minLength: 0,
                            maxLength: 2_000_000
                        ),
                    ],
                    required: ["path", "contents"],
                    additionalProperties: false
                ),
                minItems: 1,
                maxItems: 128
            ),
        ],
        required: ["entries"],
        additionalProperties: false
    )
}

/// Policy-only operations used by human and trusted-system flows. They are not
/// members of `SandboxToolCatalog`, so providers can never advertise or invoke
/// these contracts by name.
enum NonProviderMutationOperation: Equatable, Sendable {
    case createFile(CreateFileMutationArguments)
    case touchFile(TouchFileMutationArguments)
    case resetWorkspace(ResetWorkspaceMutationArguments)
    case seedWorkspace(SeedWorkspaceMutationArguments)
}

enum CanonicalProviderMutationKind: CaseIterable, Hashable, Sendable {
    case writeFile
    case appendFile
    case replaceText
    case deletePath
    case movePath
    case copyPath
    case makeDirectory
    case runCommand
}

enum NonProviderMutationKind: CaseIterable, Hashable, Sendable {
    case createFile
    case touchFile
    case resetWorkspace
    case seedWorkspace
}

extension CanonicalProviderMutationOperation {
    var kind: CanonicalProviderMutationKind {
        switch self {
        case .writeFile: .writeFile
        case .appendFile: .appendFile
        case .replaceText: .replaceText
        case .deletePath: .deletePath
        case .movePath: .movePath
        case .copyPath: .copyPath
        case .makeDirectory: .makeDirectory
        case .runCommand: .runCommand
        }
    }
}

extension NonProviderMutationOperation {
    var kind: NonProviderMutationKind {
        switch self {
        case .createFile: .createFile
        case .touchFile: .touchFile
        case .resetWorkspace: .resetWorkspace
        case .seedWorkspace: .seedWorkspace
        }
    }
}

/// Defense-in-depth origin × operation allowlist. Public origin-specific enums
/// make invalid combinations unrepresentable to callers; these tables also
/// fail closed if a future internal adapter routes the wrong typed contract.
enum MutationOriginOperationPolicy {
    private static let canonicalProvider: [
        MutationOrigin: Set<CanonicalProviderMutationKind>
    ] = [
        .editor: [.writeFile, .replaceText],
        .files: [
            .writeFile, .deletePath, .movePath, .copyPath, .makeDirectory,
        ],
        .terminal: [.runCommand],
        .artifact: [.writeFile, .appendFile],
        .projectOS: [.writeFile, .appendFile, .replaceText],
        .trustedSystem: Set(CanonicalProviderMutationKind.allCases),
    ]

    private static let nonProvider: [
        MutationOrigin: Set<NonProviderMutationKind>
    ] = [
        .editor: [.createFile],
        .files: [.createFile, .touchFile],
        .control: [.resetWorkspace],
        .projectOS: [.resetWorkspace, .seedWorkspace],
        .trustedSystem: Set(NonProviderMutationKind.allCases),
    ]

    static func allows(
        origin: MutationOrigin,
        operation: CanonicalProviderMutationOperation
    ) -> Bool {
        canonicalProvider[origin]?.contains(operation.kind) == true
    }

    static func allows(
        origin: MutationOrigin,
        operation: NonProviderMutationOperation
    ) -> Bool {
        nonProvider[origin]?.contains(operation.kind) == true
    }
}

enum MutationEffectContractCatalog {
    private static let providerDescriptors: [ToolIdentity: ToolDescriptor] =
        Dictionary(uniqueKeysWithValues: SandboxToolCatalog.all.map {
            ($0.descriptor.identity, $0.descriptor)
        })

    private static let nonProviderDescriptors: [ToolIdentity: ToolDescriptor] =
        Dictionary(uniqueKeysWithValues: [
            PolicyCreateFileTool.descriptor,
            PolicyTouchFileTool.descriptor,
            PolicyResetWorkspaceTool.descriptor,
            PolicySeedWorkspaceTool.descriptor,
        ].map { ($0.identity, $0) })

    static func canonicalDescriptor(
        for identity: ToolIdentity
    ) -> ToolDescriptor? {
        providerDescriptors[identity] ?? nonProviderDescriptors[identity]
    }

    static func canonicalProviderDescriptor(
        for identity: ToolIdentity
    ) -> ToolDescriptor? {
        providerDescriptors[identity]
    }

    static func canonicalNonProviderDescriptor(
        for identity: ToolIdentity
    ) -> ToolDescriptor? {
        nonProviderDescriptors[identity]
    }

    static func canonicalDescriptor(
        for operation: CanonicalProviderMutationOperation
    ) -> ToolDescriptor {
        switch operation {
        case .writeFile: WriteFileTool.descriptor
        case .appendFile: AppendFileTool.descriptor
        case .replaceText: ReplaceTextTool.descriptor
        case .deletePath: DeletePathTool.descriptor
        case .movePath: MovePathTool.descriptor
        case .copyPath: CopyPathTool.descriptor
        case .makeDirectory: MakeDirectoryTool.descriptor
        case .runCommand: RunCommandTool.descriptor
        }
    }

    static func arguments(
        for operation: CanonicalProviderMutationOperation
    ) -> JSONValue {
        switch operation {
        case let .writeFile(value):
            .object([
                "path": .string(value.path),
                "contents": .string(value.contents),
            ])
        case let .appendFile(value):
            .object([
                "path": .string(value.path),
                "contents": .string(value.contents),
            ])
        case let .replaceText(value):
            .object([
                "path": .string(value.path),
                "old": .string(value.old),
                "new": .string(value.new),
                "replace_all": value.replaceAll.map(JSONValue.bool) ?? .null,
            ])
        case let .deletePath(value), let .makeDirectory(value):
            .object(["path": .string(value.path)])
        case let .movePath(value), let .copyPath(value):
            .object([
                "from": .string(value.from),
                "to": .string(value.to),
            ])
        case let .runCommand(value):
            .object(["command": .string(value.command)])
        }
    }

    static func canonicalDescriptor(
        for operation: NonProviderMutationOperation
    ) -> ToolDescriptor {
        switch operation {
        case .createFile: PolicyCreateFileTool.descriptor
        case .touchFile: PolicyTouchFileTool.descriptor
        case .resetWorkspace: PolicyResetWorkspaceTool.descriptor
        case .seedWorkspace: PolicySeedWorkspaceTool.descriptor
        }
    }

    static func arguments(
        for operation: NonProviderMutationOperation
    ) -> JSONValue {
        switch operation {
        case let .createFile(value):
            .object(["path": .string(value.path)])
        case let .touchFile(value):
            .object(["path": .string(value.path)])
        case .resetWorkspace:
            .object([:])
        case let .seedWorkspace(value):
            .object([
                "entries": .array(value.entries.map {
                    .object([
                        "path": .string($0.path),
                        "contents": .string($0.contents),
                    ])
                }),
            ])
        }
    }

    static func body(
        descriptor: ToolDescriptor,
        arguments: JSONValue
    ) throws -> MutationEffectOperationBody {
        switch descriptor.name {
        case "write_file":
            .writeFile(try WriteFileTool.decodeArguments(arguments))
        case "append_file":
            .appendFile(try AppendFileTool.decodeArguments(arguments))
        case "replace_text":
            .replaceText(try ReplaceTextTool.decodeArguments(arguments))
        case "delete_path":
            .deletePath(try DeletePathTool.decodeArguments(arguments))
        case "move_path":
            .movePath(try MovePathTool.decodeArguments(arguments))
        case "copy_path":
            .copyPath(try CopyPathTool.decodeArguments(arguments))
        case "make_directory":
            .makeDirectory(try MakeDirectoryTool.decodeArguments(arguments))
        case "run_command":
            .runCommand(try RunCommandTool.decodeArguments(arguments))
        case "create_file":
            .createFile(try PolicyCreateFileTool.decodeArguments(arguments))
        case "touch_file":
            .touchFile(try PolicyTouchFileTool.decodeArguments(arguments))
        case "reset_workspace":
            .resetWorkspace(
                try PolicyResetWorkspaceTool.decodeArguments(arguments)
            )
        case "seed_workspace":
            .seedWorkspace(
                try PolicySeedWorkspaceTool.decodeArguments(arguments)
            )
        default:
            throw MutationEffectGatewayError.unsupportedMutationTool(
                descriptor.identity
            )
        }
    }
}

private func policyOnlyMetadata(
    name: String,
    description: String,
    effectClass: ToolEffectClass,
    targetStrategy: ToolTargetStrategy,
    title: String,
    evidence: ToolEvidenceMapping
) -> ToolDescriptorMetadata {
    ToolDescriptorMetadata(
        name: name,
        version: .init(major: 1, minor: 0, patch: 0),
        toolset: "policy_workspace",
        description: description,
        availability: .init(
            allowedLocalities: [.onDevice],
            requiredCapabilities: [.workspaceWrite],
            requiresWorkspace: true
        ),
        effectClass: effectClass,
        approvalClass: .explicit,
        targetStrategy: targetStrategy,
        parallelSafety: .workspaceSerialized,
        concurrencyKey: "workspace",
        limits: .init(
            timeoutMilliseconds: 30_000,
            maximumArgumentBytes: 2_100_000,
            maximumOutputBytes: 65_536
        ),
        redaction: .init(
            argumentRules: [
                .init(path: ["path"]),
                .init(path: ["entries", "*", "path"]),
                .init(path: ["entries", "*", "contents"]),
            ],
            output: .replace(.string("<redacted-mutation-output>"))
        ),
        legacyAdapter: nil,
        receipt: .init(actionVerb: "Changed", successSummary: "Workspace changed"),
        evidence: evidence,
        ui: .init(
            title: title,
            systemImageName: "folder.badge.gearshape",
            category: .edit,
            resultPresentation: .text
        )
    )
}

private enum PolicyCreateFileTool: AgentTool {
    typealias Arguments = CreateFileMutationArguments
    static let metadata = policyOnlyMetadata(
        name: "create_file",
        description: "Create one empty workspace file without overwriting it.",
        effectClass: .scopedReversibleWrite,
        targetStrategy: .argumentPaths([
            .init(argumentPath: ["path"], access: .write),
        ]),
        title: "Create File",
        evidence: .changedPath
    )
}

private enum PolicyTouchFileTool: AgentTool {
    typealias Arguments = TouchFileMutationArguments
    static let metadata = policyOnlyMetadata(
        name: "touch_file",
        description: "Create an empty file or update one file's modification time.",
        effectClass: .scopedReversibleWrite,
        targetStrategy: .argumentPaths([
            .init(argumentPath: ["path"], access: .write),
        ]),
        title: "Touch File",
        evidence: .changedPath
    )
}

private enum PolicyResetWorkspaceTool: AgentTool {
    typealias Arguments = ResetWorkspaceMutationArguments
    static let metadata = policyOnlyMetadata(
        name: "reset_workspace",
        description: "Delete every child of the exact workspace root.",
        effectClass: .broadOrDestructiveWrite,
        targetStrategy: .workspaceRoot(access: .delete),
        title: "Reset Workspace",
        evidence: .deletedPath
    )
}

private enum PolicySeedWorkspaceTool: AgentTool {
    typealias Arguments = SeedWorkspaceMutationArguments
    static let metadata = policyOnlyMetadata(
        name: "seed_workspace",
        description: "Write an exact bounded set of initial workspace files.",
        effectClass: .scopedReversibleWrite,
        targetStrategy: .arrayArgumentPaths(
            arrayPath: ["entries"],
            elementRules: [
                .init(argumentPath: ["path"], access: .write),
            ]
        ),
        title: "Seed Workspace",
        evidence: .changedPath
    )
}
