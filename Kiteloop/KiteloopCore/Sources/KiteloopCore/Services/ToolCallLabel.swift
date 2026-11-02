import Foundation

/// What a tool call row *says* it is doing.
///
/// The CLI writes a one-line `description` alongside the arguments of every
/// `Bash` and `Agent` call — the sentence saying what the call is for. The rows
/// printed the arguments instead: forty or eighty characters of shell, cut
/// mid-token, with the sentence discarded, so a run read as
/// `Bash cd .kiteloop/backlog-tree && grep -nE '^\s*- \[' BACKLOG.md | awk -F'|'`
/// and said nothing about what the agent was doing.
///
/// The description is the primary text now. The raw command is not dropped —
/// it is what a failure is diagnosed from — it stays on the row beside it, in
/// the tooltip and the expansion.
///
/// The rules are a service rather than part of a view so both surfaces that
/// draw a call — the transcript's rows and the live activity ticker — read the
/// same way and can be asserted directly, with no view in the test.
package enum ToolCallLabel {

    /// Tools whose input carries a caller-written `description`. `Task` is the
    /// same tool as `Agent` under the other name the CLI uses for it.
    private static let describedTools: Set<String> = ["Bash", "Agent", "Task"]

    /// The sentence the caller wrote about this call, or nil when the tool
    /// carries none. A blank description counts as none — nothing was said, so
    /// the row falls back to the arguments it showed before.
    package static func description(tool: String, input: [String: Any]) -> String? {
        guard describedTools.contains(tool),
              let text = input["description"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The command the label stands in for, in full and untruncated, for the row
    /// to keep within reach. Nil when there is nothing worth keeping: an `Agent`
    /// call's other argument is a page of prompt, and the row already expands to
    /// show it.
    package static func detail(tool: String, input: [String: Any]) -> String? {
        guard tool == "Bash", let command = input["command"] as? String else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The body an expanded row should show for a call, or nil when the
    /// arguments themselves are the best there is.
    ///
    /// An expansion that has nothing better to print prints the raw JSON the
    /// CLI sent, so a shell command reads as one long line with `\n` in it and
    /// every argument carries its quoting. The command — and, for a delegated
    /// call, the prompt — is the text a person came to the expansion for, and
    /// it is already in the input; this hands it back as it was written, with
    /// its real line breaks. A blank one is nothing to show, so the row keeps
    /// the arguments.
    package static func expansionText(tool: String, input: [String: Any]) -> String? {
        let key: String
        switch tool {
        case "Bash": key = "command"
        case "Agent", "Task": key = "prompt"
        default: return nil
        }
        guard let text = input[key] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// One line, no runs of whitespace, cut on a word boundary.
    ///
    /// The cut lands on the last whitespace at or before the limit, because a
    /// cut mid-token is half of why the old rows read as noise. A token that
    /// runs past the limit on its own — a long path, a URL — leaves no boundary
    /// worth honouring, so anything that would throw away more than half the
    /// budget is cut where it lands instead.
    package static func shorten(_ text: String, limit: Int) -> String {
        let flattened = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        let head = flattened.prefix(limit)
        if let space = head.lastIndex(where: \.isWhitespace),
           head.distance(from: head.startIndex, to: space) >= limit / 2 {
            return head[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// How much of an argument each surface has room for.
    ///
    /// The list of tools, and the argument each call is named by, is shared;
    /// the widths are not. A transcript row is a full line, the ticker is one
    /// line beside a spinner, so the ticker cuts a command and a pattern
    /// shorter than the row does.
    package struct Widths: Equatable {
        let command: Int
        let pattern: Int

        /// The live activity ticker's room.
        package static let ticker = Widths(command: 40, pattern: 30)
    }

    /// The argument that names a call: the file it touches, the command it
    /// runs, the agent it messages, the page it opens. Nil when the tool has
    /// no such argument, or the call left it out — the surface then has only
    /// the tool's own name to show.
    ///
    /// This is the one list of tools and their arguments. Both surfaces read
    /// it, so a tool named here reads the same way in the row and in the
    /// ticker, and a tool added here is added to both at once.
    package static func argumentSummary(tool: String, input: [String: Any], widths: Widths) -> String? {
        if let summary = workspaceArgument(tool: tool, input: input, widths: widths) { return summary }
        return messagingOrWebArgument(tool: tool, input: input)
    }

    /// The tools that act on this machine: the file they touch, the command
    /// they run, the pattern they search for.
    private static func workspaceArgument(
        tool: String,
        input: [String: Any],
        widths: Widths
    ) -> String? {
        switch tool {
        case "Read", "Edit", "Write":
            guard let path = input["file_path"] as? String else { return nil }
            return URL(fileURLWithPath: path).lastPathComponent
        case "Bash":
            guard let command = input["command"] as? String else { return nil }
            return shorten(command, limit: widths.command)
        case "Glob", "Grep":
            guard let pattern = input["pattern"] as? String else { return nil }
            return String(pattern.prefix(widths.pattern))
        default:
            return nil
        }
    }

    /// The tools that reach another agent or a browser: who was messaged, and
    /// where the page went.
    private static func messagingOrWebArgument(tool: String, input: [String: Any]) -> String? {
        switch tool {
        case "message_agent":
            let agent = input["agent"] as? String ?? ""
            let msg = input["message"] as? String ?? ""
            return "@\(agent): \(String(msg.prefix(50)))"
        case "broadcast_agents":
            let msg = input["message"] as? String ?? ""
            let agents = input["agents"] as? [String]
            let target = agents?.joined(separator: ", ") ?? "all"
            return "→ \(target): \(String(msg.prefix(40)))"
        case "web_navigate":
            return String((input["url"] as? String ?? "").prefix(80))
        case "web_click":
            return String((input["ref"] as? String ?? "").prefix(16))
        case "web_type":
            let ref = String((input["ref"] as? String ?? "").prefix(16))
            return "\(ref): \(String((input["text"] as? String ?? "").prefix(50)))"
        case "web_scroll":
            if let ref = input["ref"] as? String { return "→ \(String(ref.prefix(16)))" }
            return String((input["direction"] as? String ?? "down").prefix(16))
        default:
            return nil
        }
    }

    /// The collapsed transcript row's text for a call with no file path to name:
    /// what it is doing when the tool says so, and otherwise the argument that
    /// identifies the call, as before.
    package static func rowSummary(tool: String, input: [String: Any], limit: Int = 80) -> String {
        if let description = description(tool: tool, input: input) {
            return shorten(description, limit: limit)
        }
        return argumentSummary(tool: tool, input: input,
                               widths: Widths(command: limit, pattern: .max)) ?? ""
    }
}
