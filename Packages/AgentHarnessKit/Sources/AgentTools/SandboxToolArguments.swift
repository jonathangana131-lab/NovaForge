import Foundation

private enum SandboxArgumentSchemas {
    static let optionalPath: JSONSchema = .nullable(.string(
        description: "A workspace-relative path. Use an empty string for the workspace root.",
        minLength: 0,
        maxLength: 4_096
    ))
    static let requiredPath: JSONSchema = .string(
        description: "A non-empty workspace-relative path.",
        minLength: 1,
        maxLength: 4_096
    )
    static func optionalBoundedInteger(
        _ description: String,
        _ minimum: Int64,
        _ maximum: Int64
    ) -> JSONSchema {
        .nullable(.integer(description: description, minimum: minimum, maximum: maximum))
    }

    static func object(
        _ properties: [String: JSONSchema],
        required: [String]
    ) -> JSONSchema {
        .object(properties: properties, required: required, additionalProperties: false)
    }
}

public struct ListDirectoryArguments: AgentToolArguments {
    public let path: String?

    public init(path: String? = nil) {
        self.path = path
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        ["path": SandboxArgumentSchemas.optionalPath],
        required: []
    )
}

public struct ListTreeArguments: AgentToolArguments {
    public let maxDepth: Int?
    public let maxItems: Int?

    public init(maxDepth: Int? = nil, maxItems: Int? = nil) {
        self.maxDepth = maxDepth
        self.maxItems = maxItems
    }

    enum CodingKeys: String, CodingKey {
        case maxDepth = "max_depth"
        case maxItems = "max_items"
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        [
            "max_depth": SandboxArgumentSchemas.optionalBoundedInteger("Maximum recursive depth.", 1, 10),
            "max_items": SandboxArgumentSchemas.optionalBoundedInteger("Maximum returned rows.", 1, 800),
        ],
        required: []
    )
}

public struct WorkspaceSummaryArguments: AgentToolArguments {
    public let maxItems: Int?

    public init(maxItems: Int? = nil) {
        self.maxItems = maxItems
    }

    enum CodingKeys: String, CodingKey {
        case maxItems = "max_items"
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        ["max_items": SandboxArgumentSchemas.optionalBoundedInteger("Maximum workspace entries to inspect.", 50, 2_000)],
        required: []
    )
}

public struct PathArguments: AgentToolArguments {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        ["path": SandboxArgumentSchemas.requiredPath],
        required: ["path"]
    )
}

public struct ReadFileRangeArguments: AgentToolArguments {
    public let path: String
    public let startLine: Int?
    public let lineCount: Int?

    public init(path: String, startLine: Int? = nil, lineCount: Int? = nil) {
        self.path = path
        self.startLine = startLine
        self.lineCount = lineCount
    }

    enum CodingKeys: String, CodingKey {
        case path
        case startLine = "start_line"
        case lineCount = "line_count"
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        [
            "path": SandboxArgumentSchemas.requiredPath,
            "start_line": SandboxArgumentSchemas.optionalBoundedInteger("One-based first line.", 1, 50_000),
            "line_count": SandboxArgumentSchemas.optionalBoundedInteger("Number of lines to return.", 1, 400),
        ],
        required: ["path"]
    )
}

public struct TailFileArguments: AgentToolArguments {
    public let path: String
    public let lineCount: Int?

    public init(path: String, lineCount: Int? = nil) {
        self.path = path
        self.lineCount = lineCount
    }

    enum CodingKeys: String, CodingKey {
        case path
        case lineCount = "line_count"
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        [
            "path": SandboxArgumentSchemas.requiredPath,
            "line_count": SandboxArgumentSchemas.optionalBoundedInteger("Number of trailing lines.", 1, 300),
        ],
        required: ["path"]
    )
}

public struct WriteFileArguments: AgentToolArguments {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        [
            "path": SandboxArgumentSchemas.requiredPath,
            "contents": .string(description: "UTF-8 text to write.", minLength: 0, maxLength: 2_000_000),
        ],
        required: ["path", "contents"]
    )
}

public struct AppendFileArguments: AgentToolArguments {
    public let path: String
    public let contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }

    public static let jsonSchema = WriteFileArguments.jsonSchema
}

public struct ReplaceTextArguments: AgentToolArguments {
    public let path: String
    public let old: String
    public let new: String
    public let replaceAll: Bool?

    public init(path: String, old: String, new: String, replaceAll: Bool? = nil) {
        self.path = path
        self.old = old
        self.new = new
        self.replaceAll = replaceAll
    }

    enum CodingKeys: String, CodingKey {
        case path, old, new
        case replaceAll = "replace_all"
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        [
            "path": SandboxArgumentSchemas.requiredPath,
            "old": .string(description: "Exact text to replace.", minLength: 1, maxLength: 1_000_000),
            "new": .string(description: "Replacement text.", minLength: 0, maxLength: 1_000_000),
            "replace_all": .nullable(.boolean(description: "Replace every exact match when true.")),
        ],
        required: ["path", "old", "new"]
    )
}

public struct MovePathArguments: AgentToolArguments {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        [
            "from": SandboxArgumentSchemas.requiredPath,
            "to": SandboxArgumentSchemas.requiredPath,
        ],
        required: ["from", "to"]
    )
}

public struct SearchTextArguments: AgentToolArguments {
    public let query: String
    public let path: String?

    public init(query: String, path: String? = nil) {
        self.query = query
        self.path = path
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        [
            "query": .string(description: "Exact text search query.", minLength: 1, maxLength: 4_096),
            "path": SandboxArgumentSchemas.optionalPath,
        ],
        required: ["query"]
    )
}

public struct DiffFilesArguments: AgentToolArguments {
    public let left: String
    public let right: String

    public init(left: String, right: String) {
        self.left = left
        self.right = right
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        [
            "left": SandboxArgumentSchemas.requiredPath,
            "right": SandboxArgumentSchemas.requiredPath,
        ],
        required: ["left", "right"]
    )
}

public enum ValidateHTMLProfile: String, Codable, CaseIterable, Sendable {
    case page
    case game
    case auto
}

public struct ValidateHTMLArguments: AgentToolArguments {
    public let path: String
    public let profile: ValidateHTMLProfile?

    public init(path: String, profile: ValidateHTMLProfile? = nil) {
        self.path = path
        self.profile = profile
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        [
            "path": SandboxArgumentSchemas.requiredPath,
            "profile": .nullable(.string(
                description: "Validation profile.",
                allowedValues: ValidateHTMLProfile.allCases.map(\.rawValue)
            )),
        ],
        required: ["path"]
    )
}

public struct RunCommandArguments: AgentToolArguments {
    public let command: String

    public init(command: String) {
        self.command = command
    }

    public static let jsonSchema = SandboxArgumentSchemas.object(
        ["command": .string(description: "One allowlisted sandbox command without shell operators.", minLength: 1, maxLength: 16_384)],
        required: ["command"]
    )
}
