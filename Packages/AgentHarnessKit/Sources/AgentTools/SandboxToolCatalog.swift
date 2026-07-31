import AgentDomain
import Foundation

private func sandboxMetadata(
    name: String,
    description: String,
    effectClass: ToolEffectClass,
    approvalClass: ToolApprovalClass,
    targetStrategy: ToolTargetStrategy,
    capabilities: [ToolCapability],
    redactedFields: [String],
    title: String,
    symbol: String,
    category: ToolUICategory,
    presentation: ToolUIResultPresentation,
    receiptVerb: String,
    successSummary: String,
    evidence: ToolEvidenceMapping,
    timeoutMilliseconds: Int = 30_000,
    maximumArgumentBytes: Int = 2_100_000,
    maximumOutputBytes: Int = 2_100_000
) -> ToolDescriptorMetadata {
    let mutating = effectClass != .readOnlyLocal
    return ToolDescriptorMetadata(
        name: name,
        version: .init(major: 1, minor: 0, patch: 0),
        toolset: "sandbox",
        description: description,
        availability: .init(
            allowedLocalities: [.onDevice],
            requiredCapabilities: capabilities,
            requiresWorkspace: true
        ),
        effectClass: effectClass,
        approvalClass: approvalClass,
        targetStrategy: targetStrategy,
        parallelSafety: mutating ? .workspaceSerialized : .parallelRead,
        concurrencyKey: mutating ? "workspace" : nil,
        limits: .init(
            timeoutMilliseconds: timeoutMilliseconds,
            maximumArgumentBytes: maximumArgumentBytes,
            maximumOutputBytes: maximumOutputBytes
        ),
        redaction: .init(
            argumentRules: redactedFields.map { .init(path: [$0]) },
            output: .replace(.string("<redacted-tool-output>"))
        ),
        legacyAdapter: .init(executorName: name, supportedMajorVersion: 1),
        receipt: .init(actionVerb: receiptVerb, successSummary: successSummary),
        evidence: evidence,
        ui: .init(
            title: title,
            systemImageName: symbol,
            category: category,
            resultPresentation: presentation
        )
    )
}

public enum ListDirectoryTool: AgentTool {
    public typealias Arguments = ListDirectoryArguments
    public static let metadata = sandboxMetadata(
        name: "list_directory",
        description: "List one workspace directory and identify each returned file or folder.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([.init(
            argumentPath: ["path"],
            access: .inspect,
            optional: true,
            defaultValue: ""
        )]),
        capabilities: [.workspaceRead],
        redactedFields: ["path"],
        title: "List Directory",
        symbol: "folder",
        category: .inspect,
        presentation: .directory,
        receiptVerb: "Listed",
        successSummary: "Directory inspected",
        evidence: .inspectedPath
    )
}

public enum ListTreeTool: AgentTool {
    public typealias Arguments = ListTreeArguments
    public static let metadata = sandboxMetadata(
        name: "list_tree",
        description: "Show a bounded recursive workspace tree for project-structure inspection.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .workspaceRoot(access: .inspect),
        capabilities: [.workspaceRead],
        redactedFields: [],
        title: "Workspace Tree",
        symbol: "list.bullet.indent",
        category: .inspect,
        presentation: .directory,
        receiptVerb: "Inspected",
        successSummary: "Workspace tree inspected",
        evidence: .inspectedPath
    )
}

public enum WorkspaceSummaryTool: AgentTool {
    public typealias Arguments = WorkspaceSummaryArguments
    public static let metadata = sandboxMetadata(
        name: "workspace_summary",
        description: "Summarize workspace file and folder counts, bytes, and common file types.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .workspaceRoot(access: .inspect),
        capabilities: [.workspaceRead],
        redactedFields: [],
        title: "Workspace Summary",
        symbol: "chart.bar.doc.horizontal",
        category: .inspect,
        presentation: .text,
        receiptVerb: "Summarized",
        successSummary: "Workspace summarized",
        evidence: .inspectedPath
    )
}

public enum FileInfoTool: AgentTool {
    public typealias Arguments = PathArguments
    public static let metadata = sandboxMetadata(
        name: "file_info",
        description: "Read the kind, byte size, creation date, and modification date of one workspace path.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .inspect)]),
        capabilities: [.workspaceRead],
        redactedFields: ["path"],
        title: "File Info",
        symbol: "info.circle",
        category: .inspect,
        presentation: .text,
        receiptVerb: "Inspected",
        successSummary: "File metadata inspected",
        evidence: .inspectedPath
    )
}

public enum ReadFileTool: AgentTool {
    public typealias Arguments = PathArguments
    public static let metadata = sandboxMetadata(
        name: "read_file",
        description: "Read the complete UTF-8 contents of a bounded workspace file.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .read)]),
        capabilities: [.workspaceRead],
        redactedFields: ["path"],
        title: "Read File",
        symbol: "doc.text",
        category: .inspect,
        presentation: .fileContent,
        receiptVerb: "Read",
        successSummary: "File read",
        evidence: .inspectedPath
    )
}

public enum ReadFileRangeTool: AgentTool {
    public typealias Arguments = ReadFileRangeArguments
    public static let metadata = sandboxMetadata(
        name: "read_file_range",
        description: "Read a bounded, numbered line range from a workspace file.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .read)]),
        capabilities: [.workspaceRead],
        redactedFields: ["path"],
        title: "Read File Range",
        symbol: "text.line.first.and.arrowtriangle.forward",
        category: .inspect,
        presentation: .fileContent,
        receiptVerb: "Read",
        successSummary: "File range read",
        evidence: .inspectedPath
    )
}

public enum TailFileTool: AgentTool {
    public typealias Arguments = TailFileArguments
    public static let metadata = sandboxMetadata(
        name: "tail_file",
        description: "Read a bounded number of trailing lines from a workspace file.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .read)]),
        capabilities: [.workspaceRead],
        redactedFields: ["path"],
        title: "Tail File",
        symbol: "text.append",
        category: .inspect,
        presentation: .fileContent,
        receiptVerb: "Read",
        successSummary: "File tail read",
        evidence: .inspectedPath
    )
}

public enum WriteFileTool: AgentTool {
    public typealias Arguments = WriteFileArguments
    public static let metadata = sandboxMetadata(
        name: "write_file",
        description: "Create or overwrite a workspace file with UTF-8 text.",
        effectClass: .scopedReversibleWrite,
        approvalClass: .explicit,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .write)]),
        capabilities: [.workspaceWrite],
        redactedFields: ["path", "contents"],
        title: "Write File",
        symbol: "square.and.pencil",
        category: .edit,
        presentation: .text,
        receiptVerb: "Wrote",
        successSummary: "File written",
        evidence: .changedPath
    )
}

public enum AppendFileTool: AgentTool {
    public typealias Arguments = AppendFileArguments
    public static let metadata = sandboxMetadata(
        name: "append_file",
        description: "Append UTF-8 text to an existing workspace file.",
        effectClass: .scopedReversibleWrite,
        approvalClass: .explicit,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .write)]),
        capabilities: [.workspaceWrite],
        redactedFields: ["path", "contents"],
        title: "Append File",
        symbol: "text.badge.plus",
        category: .edit,
        presentation: .text,
        receiptVerb: "Appended",
        successSummary: "File appended",
        evidence: .changedPath
    )
}

public enum ReplaceTextTool: AgentTool {
    public typealias Arguments = ReplaceTextArguments
    public static let metadata = sandboxMetadata(
        name: "replace_text",
        description: "Replace exact text in one workspace file, refusing ambiguous matches unless explicitly allowed.",
        effectClass: .scopedReversibleWrite,
        approvalClass: .explicit,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .write)]),
        capabilities: [.workspaceRead, .workspaceWrite],
        redactedFields: ["path", "old", "new"],
        title: "Replace Text",
        symbol: "text.redaction",
        category: .edit,
        presentation: .text,
        receiptVerb: "Replaced",
        successSummary: "Text replaced",
        evidence: .changedPath
    )
}

public enum DeletePathTool: AgentTool {
    public typealias Arguments = PathArguments
    public static let metadata = sandboxMetadata(
        name: "delete_path",
        description: "Permanently delete one workspace file or directory after explicit authorization.",
        effectClass: .broadOrDestructiveWrite,
        approvalClass: .explicit,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .delete)]),
        capabilities: [.workspaceWrite],
        redactedFields: ["path"],
        title: "Delete Path",
        symbol: "trash",
        category: .organize,
        presentation: .text,
        receiptVerb: "Deleted",
        successSummary: "Path deleted",
        evidence: .deletedPath
    )
}

public enum MovePathTool: AgentTool {
    public typealias Arguments = MovePathArguments
    public static let metadata = sandboxMetadata(
        name: "move_path",
        description: "Move or rename one workspace file or directory.",
        effectClass: .scopedReversibleWrite,
        approvalClass: .explicit,
        targetStrategy: .argumentPaths([
            .init(argumentPath: ["from"], access: .source),
            .init(argumentPath: ["to"], access: .destination),
        ]),
        capabilities: [.workspaceRead, .workspaceWrite],
        redactedFields: ["from", "to"],
        title: "Move Path",
        symbol: "arrow.right.square",
        category: .organize,
        presentation: .text,
        receiptVerb: "Moved",
        successSummary: "Path moved",
        evidence: .movedPath
    )
}

public enum CopyPathTool: AgentTool {
    public typealias Arguments = MovePathArguments
    public static let metadata = sandboxMetadata(
        name: "copy_path",
        description: "Copy one workspace file or directory to a new workspace path.",
        effectClass: .scopedReversibleWrite,
        approvalClass: .explicit,
        targetStrategy: .argumentPaths([
            .init(argumentPath: ["from"], access: .source),
            .init(argumentPath: ["to"], access: .destination),
        ]),
        capabilities: [.workspaceRead, .workspaceWrite],
        redactedFields: ["from", "to"],
        title: "Copy Path",
        symbol: "doc.on.doc",
        category: .organize,
        presentation: .text,
        receiptVerb: "Copied",
        successSummary: "Path copied",
        evidence: .copiedPath
    )
}

public enum MakeDirectoryTool: AgentTool {
    public typealias Arguments = PathArguments
    public static let metadata = sandboxMetadata(
        name: "make_directory",
        description: "Create a directory inside the workspace.",
        effectClass: .scopedReversibleWrite,
        approvalClass: .explicit,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .write)]),
        capabilities: [.workspaceWrite],
        redactedFields: ["path"],
        title: "Make Directory",
        symbol: "folder.badge.plus",
        category: .organize,
        presentation: .text,
        receiptVerb: "Created",
        successSummary: "Directory created",
        evidence: .changedPath
    )
}

public enum SearchTextTool: AgentTool {
    public typealias Arguments = SearchTextArguments
    public static let metadata = sandboxMetadata(
        name: "search_text",
        description: "Search recursively for an exact text query within bounded workspace files.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([.init(
            argumentPath: ["path"],
            access: .inspect,
            optional: true,
            defaultValue: ""
        )]),
        capabilities: [.workspaceRead],
        redactedFields: ["query", "path"],
        title: "Search Text",
        symbol: "magnifyingglass",
        category: .inspect,
        presentation: .text,
        receiptVerb: "Searched",
        successSummary: "Workspace searched",
        evidence: .inspectedPath
    )
}

public enum DiffFilesTool: AgentTool {
    public typealias Arguments = DiffFilesArguments
    public static let metadata = sandboxMetadata(
        name: "diff_files",
        description: "Compare two workspace text files and return a bounded line-oriented diff.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([
            .init(argumentPath: ["left"], access: .read),
            .init(argumentPath: ["right"], access: .read),
        ]),
        capabilities: [.workspaceRead],
        redactedFields: ["left", "right"],
        title: "Diff Files",
        symbol: "arrow.left.arrow.right",
        category: .inspect,
        presentation: .diff,
        receiptVerb: "Compared",
        successSummary: "Files compared",
        evidence: .inspectedPath
    )
}

public enum ValidateJSONTool: AgentTool {
    public typealias Arguments = PathArguments
    public static let metadata = sandboxMetadata(
        name: "validate_json",
        description: "Validate that a bounded workspace file contains parseable JSON.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .read)]),
        capabilities: [.workspaceRead],
        redactedFields: ["path"],
        title: "Validate JSON",
        symbol: "checkmark.seal",
        category: .validate,
        presentation: .validation,
        receiptVerb: "Validated",
        successSummary: "JSON validated",
        evidence: .validationReport
    )
}

public enum ValidateHTMLFileTool: AgentTool {
    public typealias Arguments = ValidateHTMLArguments
    public static let metadata = sandboxMetadata(
        name: "validate_html_file",
        description: "Run NovaForge's bounded HTML readiness checks for page, game, or automatic profiles.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .read)]),
        capabilities: [.workspaceRead, .htmlValidation],
        redactedFields: ["path"],
        title: "Validate HTML",
        symbol: "checkmark.seal",
        category: .validate,
        presentation: .validation,
        receiptVerb: "Validated",
        successSummary: "HTML validated",
        evidence: .validationReport
    )
}

public enum ExtractOutlineTool: AgentTool {
    public typealias Arguments = PathArguments
    public static let metadata = sandboxMetadata(
        name: "extract_outline",
        description: "Extract bounded code or document outline lines from one workspace file.",
        effectClass: .readOnlyLocal,
        approvalClass: .none,
        targetStrategy: .argumentPaths([.init(argumentPath: ["path"], access: .read)]),
        capabilities: [.workspaceRead],
        redactedFields: ["path"],
        title: "Extract Outline",
        symbol: "list.bullet.rectangle",
        category: .inspect,
        presentation: .text,
        receiptVerb: "Outlined",
        successSummary: "Outline extracted",
        evidence: .inspectedPath
    )
}

public enum RunCommandTool: AgentTool {
    public typealias Arguments = RunCommandArguments
    public static let metadata = sandboxMetadata(
        name: "run_command",
        description: "Run one allowlisted sandbox command without shell operators or an unrestricted shell.",
        effectClass: .broadOrDestructiveWrite,
        approvalClass: .explicit,
        targetStrategy: .legacyCommandParserRequired,
        capabilities: [.sandboxCommand, .workspaceRead, .workspaceWrite],
        redactedFields: ["command"],
        title: "Run Command",
        symbol: "terminal",
        category: .command,
        presentation: .commandOutput,
        receiptVerb: "Ran",
        successSummary: "Sandbox command completed",
        evidence: .commandTranscript,
        timeoutMilliseconds: 60_000,
        maximumArgumentBytes: 32_768,
        maximumOutputBytes: 2_100_000
    )
}

public enum SandboxToolCatalog {
    /// The single M2 catalog for every operation currently dispatched by `SandboxToolExecutor`.
    public static let all: [AnyAgentTool] = [
        .init(ListDirectoryTool.self),
        .init(ListTreeTool.self),
        .init(WorkspaceSummaryTool.self),
        .init(FileInfoTool.self),
        .init(ReadFileTool.self),
        .init(ReadFileRangeTool.self),
        .init(TailFileTool.self),
        .init(WriteFileTool.self),
        .init(AppendFileTool.self),
        .init(ReplaceTextTool.self),
        .init(DeletePathTool.self),
        .init(MovePathTool.self),
        .init(CopyPathTool.self),
        .init(MakeDirectoryTool.self),
        .init(SearchTextTool.self),
        .init(DiffFilesTool.self),
        .init(ValidateJSONTool.self),
        .init(ValidateHTMLFileTool.self),
        .init(ExtractOutlineTool.self),
        .init(RunCommandTool.self),
    ]

    public static func canonicalRegistry() throws -> ToolRegistry {
        try ToolRegistry(tools: all)
    }

    /// A compact, deterministic tool surface for memory-constrained on-device
    /// models. These are the only operations NovaForge's local planner can
    /// emit; keeping the registry small also keeps its provider definition
    /// envelope practical on an iPhone 12.
    public static let localAgentTools: [AnyAgentTool] = [
        .init(ListDirectoryTool.self),
        .init(ListTreeTool.self),
        .init(WorkspaceSummaryTool.self),
        .init(FileInfoTool.self),
        .init(ReadFileTool.self),
        .init(ReadFileRangeTool.self),
        .init(TailFileTool.self),
        .init(WriteFileTool.self),
        .init(AppendFileTool.self),
        .init(ReplaceTextTool.self),
        .init(SearchTextTool.self),
        .init(ValidateHTMLFileTool.self),
        .init(RunCommandTool.self),
    ]

    public static func localAgentRegistry() throws -> ToolRegistry {
        try ToolRegistry(tools: localAgentTools)
    }
}
