import Foundation

/// The one line a phone shows for a tool call — the tool's name and what it
/// was pointed at — the way Claude Code's own transcript reads
/// (`Bash(git status)`, `Read(Services/Foo.swift)`), instead of a bare `Bash`
/// repeated ten times. The input is the tool's JSON, kept short and on one
/// line; a tool this doesn't know keeps its name alone.
package enum ToolCallSummary {
    /// Longest summary worth a phone row.
    package static let maxLength = 80

    /// `"<name> — <summary>"`, or `"<name>"` when the input says nothing worth
    /// a summary.
    package static func line(name: String, input: String) -> String {
        guard let summary = summary(name: name, input: input) else { return name }
        return "\(name) — \(summary)"
    }

    /// The part of the input a person would read, by tool: what Bash ran (its
    /// description when it has one, else the command's first line), the file
    /// a file tool touched, the pattern a search looked for, the task an agent
    /// was given, the host a fetch went to.
    package static func summary(name: String, input: String) -> String? {
        guard let fields = fields(of: input) else { return nil }
        for key in candidateKeys(for: name) {
            if let value = fields[key], let text = trimmed(value, forPath: key.hasSuffix("path")) { return text }
        }
        return nil
    }

    /// The input keys worth reading for a tool, most telling first; a tool
    /// this table does not know falls back to the common names.
    private static let keysByTool: [String: [String]] = [
        "Bash": ["description", "command"],
        "Read": ["file_path"], "Edit": ["file_path"], "Write": ["file_path"], "MultiEdit": ["file_path"],
        "NotebookEdit": ["notebook_path"],
        "Grep": ["pattern"], "Glob": ["pattern"],
        "Agent": ["description", "prompt"], "Task": ["description", "prompt"],
        "WebFetch": ["url"], "WebSearch": ["query"],
        "Skill": ["skill"],
    ]

    /// The whole path a file tool was pointed at — not the two components
    /// the summary keeps — so a phone can open the file; nil for other tools.
    package static func filePath(name: String, input: String) -> String? {
        let key: String
        switch name {
        case "Read", "Edit", "Write", "MultiEdit": key = "file_path"
        case "NotebookEdit": key = "notebook_path"
        default: return nil
        }
        guard let path = fields(of: input)?[key], !path.isEmpty else { return nil }
        return path
    }

    private static func candidateKeys(for name: String) -> [String] {
        keysByTool[name] ?? ["description", "command", "file_path", "pattern", "query"]
    }

    /// The input's top-level string fields; nil when it isn't a JSON object.
    private static func fields(of input: String) -> [String: String]? {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var strings: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String { strings[key] = text }
        }
        return strings
    }

    /// The first line, whitespace collapsed, cut to `maxLength` with an
    /// ellipsis; a path keeps its last two components so it still names the
    /// file and where it sits.
    private static func trimmed(_ value: String, forPath: Bool) -> String? {
        var text = value
        if forPath {
            let parts = value.split(separator: "/").map(String.init)
            text = parts.suffix(2).joined(separator: "/")
        }
        guard let firstLine = text.split(whereSeparator: \.isNewline).first else { return nil }
        let collapsed = firstLine.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength - 1)) + "…"
    }
}
