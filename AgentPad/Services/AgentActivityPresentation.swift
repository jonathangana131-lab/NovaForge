import Foundation

/// Small, production-only presentation adapter for turning internal runtime
/// activity into stable human-facing copy.
///
/// This replaces the retired live-session reducer. It intentionally owns no
/// run state and performs no streaming work.
enum AgentActivityPresentation {
    static func presentation(
        forToolName name: String,
        arguments: [String: String] = [:],
        detail: String? = nil
    ) -> (title: String, target: String?) {
        toolSummary(name: name, arguments: arguments, detail: detail)
    }

    static func humanizedVisibleText(_ text: String, fallback: String? = nil) -> String {
        humanActivity(text, fallback: fallback)
    }

    static func humanizedVisibleDetail(_ text: String?) -> String? {
        sanitizedDetail(text)
    }

    private static func toolSummary(
        name: String,
        arguments: [String: String],
        detail: String?
    ) -> (title: String, target: String?) {
        let target = arguments["path"] ??
            arguments["file"] ??
            arguments["to"] ??
            arguments["from"] ??
            sanitizedDetail(detail ?? "")
        let loweredName = name.lowercased()
        if loweredName.contains("word tree") ||
            loweredName.contains("live feed") ||
            loweredName.contains("response renderer") {
            return ("Writing answer…", target)
        }

        switch name {
        case "read_file", "read_file_range", "tail_file":
            return ("Reading file", target)
        case "file_info":
            return ("Inspecting file", target)
        case "list_directory":
            return ("Browsing files", target)
        case "list_tree", "workspace_summary":
            return ("Scanning workspace", target)
        case "search_files", "search", "search_text":
            return ("Searching files", target)
        case "write_file":
            return ("Creating file", target)
        case "append_file", "replace_text", "move_path", "copy_path":
            return ("Editing file", target)
        case "make_directory":
            return ("Creating folder", target)
        case "delete_path":
            return ("Deleting file", target)
        case "run_command":
            let command = arguments["command"] ?? detail ?? ""
            if command.localizedCaseInsensitiveContains("xcodebuild") {
                return ("Running Xcode proof", nil)
            }
            if command.localizedCaseInsensitiveContains("screenshot") ||
                command.localizedCaseInsensitiveContains("simctl io") {
                return ("Capturing proof", nil)
            }
            return ("Running command", sanitizedDetail(command))
        default:
            return (
                humanActivity(
                    name.replacingOccurrences(of: "_", with: " "),
                    fallback: "Using tool"
                ),
                target
            )
        }
    }

    private static func humanActivity(_ text: String, fallback: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback ?? "" }
        let lower = trimmed.lowercased()
        if lower.contains("word tree") ||
            lower.contains("word-tree") ||
            lower.contains("forge live response") {
            return "Writing answer…"
        }
        if lower.contains("normalizing chunk") {
            return "Organizing the response"
        }
        if lower.contains("semantic reveal") {
            return "Keeping the live response readable."
        }
        if lower.contains("ragged chunks") {
            return "Smoothing the live response."
        }
        if lower.contains("streaming stress test") {
            return "Writing answer…"
        }
        if lower == "ready" {
            return fallback ?? "Ready"
        }
        if lower.contains("calling openai") {
            return "Waiting for model"
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    private static func sanitizedDetail(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.localizedCaseInsensitiveContains("normalizing chunk") {
            return "Organizing the response"
        }
        if trimmed.localizedCaseInsensitiveContains("word tree") ||
            trimmed.localizedCaseInsensitiveContains("word-tree") {
            return "Writing answer"
        }
        if trimmed.localizedCaseInsensitiveContains("semantic reveal") {
            return "Keeping the live response readable."
        }
        if trimmed.localizedCaseInsensitiveContains("ragged chunks") {
            return "Smoothing the live response."
        }
        if trimmed.first == "{" || trimmed.first == "[" {
            return "Details saved in History."
        }
        return trimmed
    }
}
