import Foundation
import KiteloopCore

/// Shapes an agent's raw message stream into the rows the Autopilot console's
/// worker and reviewer panes render.
///
/// The console used to render the chat transcript's bubbles: every tool call was
/// a boxed row naming the tool, and its result — when it was shown at all — was a
/// second, separately-boxed row further down, usually several calls later. Two
/// thirds of a run's height went to chrome around `Bash`, and the agent's own
/// prose, which is the part a human reads to know what is happening, was one
/// bubble among dozens.
///
/// This is the terminal's idiom instead: one call is one `Verb(target)` headline
/// with its result on a dimmed line beneath it, a shell burst is one row rather
/// than eleven, and prose is left the widest, largest thing on screen. The rules
/// live here rather than in the view so they can be asserted against a message
/// stream directly.
enum AutopilotTranscript {

    // MARK: - Rows

    /// One tool call: `Read(AutopilotView.swift)` over `⎿ Read 1651 lines`.
    struct Call: Identifiable, Equatable {
        /// The tool call id, which is also the row's identity.
        let id: String
        /// Raw tool name, kept so grouping can ask "is this a shell call?".
        let tool: String
        /// The headline's verb — the *action*, not the tool: `Edit` reads as
        /// `Update`, `Grep` and `Glob` both read as `Search`.
        let verb: String
        /// What the verb acted on, already shortened to one line.
        let target: String
        /// The dimmed line beneath, or nil while the call is still in flight.
        let result: String?
        let isError: Bool
        /// Everything the call returned, which the row unfolds to when clicked —
        /// the result line is a summary, and a failed build's summary is only its
        /// first line. Nil while the call is still in flight.
        var output: String? = nil

        /// `Verb(target)`, or the bare verb for a call with nothing to name.
        var headline: String { target.isEmpty ? verb : "\(verb)(\(target))" }
    }

    enum Kind {
        /// Something written for a human to read: agent prose, an error, a
        /// session event. The rows the transcript exists to make legible.
        case prose(Message)
        case call(Call)
        /// Two or more consecutive shell calls, collapsed into one row.
        case shell([Call])
    }

    struct Row: Identifiable {
        let id: String
        let kind: Kind
    }

    /// A capped window onto the stream. The cap is on rows rather than messages
    /// because grouping runs first: eleven shell calls that became one row cost
    /// one row of the budget, not eleven.
    struct Transcript {
        let rows: [Row]
        /// Rows dropped off the top by the cap.
        let hiddenRowCount: Int

        /// Rows the stream has produced in total, capped and dropped alike.
        ///
        /// This is what the pane watches to decide it should scroll: `rows.count`
        /// stops changing the moment the cap is reached, so a run that scrolled
        /// itself for its first sixty rows silently stopped for the rest of the
        /// run — the tail nobody could see was the tail that mattered.
        var totalRowCount: Int { rows.count + hiddenRowCount }
    }

    /// Rows kept per pane. Two panes render at once and every row costs an
    /// alignment and sizing pass, so the stream is windowed rather than unbounded
    /// — see the note on `AutopilotTranscriptView`.
    static let defaultRowLimit = 60

    /// The next window when the reader asks for earlier rows: one more page above
    /// the rows already shown, and how many that reveals — the button's N. Nil
    /// when nothing is hidden, so there is no button to offer.
    static func earlierPage(limit: Int, hiddenRowCount: Int,
                            page: Int = defaultRowLimit) -> (nextLimit: Int, revealed: Int)? {
        guard hiddenRowCount > 0 else { return nil }
        let revealed = min(hiddenRowCount, page)
        return (limit + revealed, revealed)
    }

    // MARK: - Building

    static func make(from messages: [Message], limit: Int = defaultRowLimit) -> Transcript {
        var outputs: [String: String] = [:]
        for message in messages {
            if case .toolResult(let result) = message.content {
                outputs[result.toolCallID] = result.output
            }
        }

        var rows: [Row] = []
        for message in messages {
            switch message.content {
            // A result is not a row of its own any more — it is the dimmed line
            // under the call that asked for it. Thinking stays hidden here as it
            // always has: this pane is a record of what the agent did.
            case .thinking, .toolResult:
                continue

            // This draws nothing in a console pane: MCP authorization is answered
            // in the chat tab, and a run's human gate is the Execution box. It
            // used to reach the pane and render an empty row.
            case .mcpAuthRequest:
                continue

            case .approval(let request):
                guard request.status == .pending else { continue }
                rows.append(Row(id: message.id.uuidString, kind: .prose(message)))

            case .toolCall(let call):
                let made = self.call(call, output: outputs[call.id] ?? call.output)
                if made.tool == "Bash", let merged = merging(made, into: rows.last) {
                    rows[rows.count - 1] = merged
                } else {
                    rows.append(Row(id: made.id, kind: .call(made)))
                }

            default:
                rows.append(Row(id: message.id.uuidString, kind: .prose(message)))
            }
        }

        return Transcript(rows: Array(rows.suffix(limit)),
                          hiddenRowCount: max(0, rows.count - limit))
    }

    /// Folds a shell call into the row above it, or returns nil when that row is
    /// not shell activity — prose between two commands breaks the burst, because
    /// the agent stopping to say something is exactly the boundary a reader is
    /// looking for.
    ///
    /// The group keeps the first call's id so the row doesn't change identity as
    /// it grows, which would restart its expansion state mid-burst.
    private static func merging(_ call: Call, into row: Row?) -> Row? {
        guard let row else { return nil }
        switch row.kind {
        case .call(let previous) where previous.tool == "Bash":
            return Row(id: row.id, kind: .shell([previous, call]))
        case .shell(let calls):
            return Row(id: row.id, kind: .shell(calls + [call]))
        default:
            return nil
        }
    }

    private static func call(_ call: Message.ToolCall, output: String?) -> Call {
        let input = parseInput(call.input)
        return Call(
            id: call.id,
            tool: call.name,
            verb: verb(for: call.name),
            target: target(tool: call.name, input: input),
            result: output.map { resultLine(tool: call.name, input: input, output: $0) },
            isError: output.map(isError) ?? false,
            output: output
        )
    }

    // MARK: - Unfolded output

    /// Lines an unfolded call shows before the rest is counted instead of drawn.
    static let outputLineLimit = 200

    /// A call's output as its unfolded row draws it: whole when it fits, else its
    /// first `limit` lines and `… +M lines` for the rest. A build log can be ten
    /// thousand lines, and laying that out on the main thread is the stall the
    /// pane's row window exists to prevent.
    static func cappedOutput(_ output: String, limit: Int = outputLineLimit) -> String {
        let lines = output.components(separatedBy: "\n")
        guard lines.count > limit else { return output }
        let rest = lines.count - limit
        return lines.prefix(limit).joined(separator: "\n") + "\n… +\(count(rest, "line"))"
    }

    // MARK: - Collapsed shell group

    /// A burst of shell calls names its size where a single call names its
    /// target, so the row still parses as `Verb(target)`.
    static func shellHeadline(_ calls: [Call]) -> String {
        "Bash(\(calls.count) commands)"
    }

    /// The dimmed line under a collapsed burst. A failure outranks everything —
    /// it is the reason to expand the row — then whatever is running now, then
    /// the last thing that finished.
    static func shellSummary(_ calls: [Call]) -> String {
        let failed = calls.filter(\.isError).count
        if failed > 0 { return "\(failed) of \(calls.count) failed" }
        if let running = calls.first(where: { $0.result == nil }) {
            return running.target.isEmpty ? "running" : "running \(running.target)"
        }
        return calls.last?.result ?? "\(calls.count) commands"
    }

    // MARK: - Verb

    /// The action, in the same words the terminal uses. Anything unmapped —
    /// every Kiteloop and MCP tool — falls back to its own name made readable,
    /// so a new tool reads sensibly without being listed here.
    static func verb(for tool: String) -> String {
        switch tool {
        case "Read", "NotebookRead":        return "Read"
        case "Edit", "MultiEdit":           return "Update"
        case "NotebookEdit":                return "Update"
        case "Write":                       return "Write"
        case "Bash", "BashOutput":          return "Bash"
        case "Glob", "Grep":                return "Search"
        case "Task", "Agent":               return "Task"
        case "WebFetch":                    return "Fetch"
        case "WebSearch":                   return "Web Search"
        case "TodoWrite":                   return "Update Todos"
        default:                            return readableName(tool)
        }
    }

    /// `mcp__kiteloop-tools__message_agent` → `Message Agent`.
    private static func readableName(_ tool: String) -> String {
        var name = tool
        if name.hasPrefix("mcp__"), let separator = name.range(of: "__", options: .backwards) {
            name = String(name[separator.upperBound...])
        }
        let words = name.split { $0 == "_" || $0 == "-" }
        guard !words.isEmpty else { return tool }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    // MARK: - Target

    /// What goes in the parentheses. A file is its basename — the pane is 280pt
    /// at its narrowest and the directory is the half that repeats — and
    /// everything else is the argument that identifies the call, shortened to a
    /// single line.
    static func target(tool: String, input: [String: Any]) -> String {
        if let path = (input["file_path"] ?? input["notebook_path"]) as? String, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        switch tool {
        case "Bash", "BashOutput":
            return shorten(input["command"] as? String ?? "")
        case "Glob", "Grep":
            return shorten(input["pattern"] as? String ?? "")
        case "Task", "Agent":
            return shorten(input["description"] as? String ?? "")
        case "WebFetch", "web_navigate":
            return shorten(input["url"] as? String ?? "")
        case "WebSearch":
            return shorten(input["query"] as? String ?? "")
        default:
            if let agent = input["agent"] as? String, !agent.isEmpty { return "@\(agent)" }
            return ""
        }
    }

    // MARK: - Result

    /// The one dimmed line under a headline. Counted where a count is the answer
    /// — nobody needs the first line of a file they can already see was read —
    /// and otherwise the head of the output, which is where a command puts the
    /// thing that went wrong.
    static func resultLine(tool: String, input: [String: Any], output: String) -> String {
        let lines = output
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if isError(output) { return shorten(lines.first ?? "Failed", limit: 90) }

        switch tool {
        case "Read":
            return "Read \(count(lines.count, "line"))"
        case "Glob":
            return lines.isEmpty ? "No files found" : "Found \(count(lines.count, "file"))"
        case "Grep":
            return lines.isEmpty ? "No matches found"
                                 : "Found \(count(lines.count, "match", plural: "matches"))"
        case "Edit", "MultiEdit", "Write":
            if let diff = EditDiff(tool: tool, input: input) {
                if tool == "Write" { return "Wrote \(count(diff.addedLines, "line"))" }
                var parts: [String] = []
                if diff.addedLines > 0 { parts.append(count(diff.addedLines, "addition")) }
                if diff.removedLines > 0 { parts.append(count(diff.removedLines, "removal")) }
                if !parts.isEmpty { return "Updated · \(parts.joined(separator: ", "))" }
            }
            return headOfOutput(lines)
        default:
            return headOfOutput(lines)
        }
    }

    /// A command that printed nothing succeeded quietly; one that printed a
    /// screenful gets its first line and how much it is standing in for.
    private static func headOfOutput(_ lines: [String]) -> String {
        guard let first = lines.first else { return "(no output)" }
        let head = shorten(first, limit: 90)
        return lines.count > 1 ? "\(head)  +\(count(lines.count - 1, "line"))" : head
    }

    /// Whether a row turns red. The rule itself lives in `ToolResultOutcome`,
    /// so the console and the chat transcript cannot drift apart again.
    static func isError(_ output: String) -> Bool {
        ToolResultOutcome.of(output: output).isError
    }

    // MARK: - Helpers

    private static func parseInput(_ input: String) -> [String: Any] {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// One line, no runs of whitespace, and short enough to sit in a headline —
    /// a heredoc or a wrapped `xcodebuild` invocation is otherwise several
    /// hundred characters of row.
    private static func shorten(_ text: String, limit: Int = 48) -> String {
        let flattened = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return flattened.prefix(limit).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : (plural ?? noun + "s"))"
    }
}
