import Foundation

/// The plan a `plan`-mode agent handed over in a turn: Claude Code writes it
/// to a file under `~/.claude/plans/` and stops, and may revise it with an
/// `Edit` or `MultiEdit`, so the plan is replayed from the calls' own inputs
/// rather than read from disk.
package enum PlanProposalDetector {
    /// Where Claude Code keeps plans for the user running it.
    package static var userPlansDirectory: URL {
        KiteloopHome.url.appending(path: ".claude/plans", directoryHint: .isDirectory)
    }

    /// The plan text after the last change under `plansDirectory` among
    /// `messages` — a `Write` sets it, an `Edit` or `MultiEdit` revises it,
    /// starting from `basePlan` before any `Write` — or nil when the agent is
    /// not in `plan` mode or no change applied. An edit that cannot apply
    /// leaves the text as the last one that did.
    package static func plan(
        in messages: some Sequence<Message>,
        permissionMode: String,
        plansDirectory: URL = userPlansDirectory,
        basePlan: String? = nil
    ) -> String? {
        guard permissionMode == "plan" else { return nil }
        var running = basePlan
        var applied: String?
        for message in messages {
            guard case .toolCall(let call) = message.content,
                  let next = step(call, over: running, under: plansDirectory) else { continue }
            running = next
            applied = next
        }
        return applied
    }

    /// The plan text after `call`, or nil when it changes no plan or cannot apply.
    private static func step(_ call: Message.ToolCall, over plan: String?, under plansDirectory: URL) -> String? {
        switch call.name {
        case "Write":
            return planContent(of: call.input, under: plansDirectory)
        case "Edit":
            guard let plan, let input = planInput(call.input, under: plansDirectory) else { return nil }
            return applying(input, to: plan)
        case "MultiEdit":
            guard let plan, let input = planInput(call.input, under: plansDirectory),
                  let edits = input["edits"] as? [[String: Any]] else { return nil }
            return edits.reduce(Optional(plan)) { text, edit in text.flatMap { applying(edit, to: $0) } }
        default:
            return nil
        }
    }

    /// `text` with an edit's `old_string` replaced by its `new_string` — every
    /// occurrence under `replace_all`, else the single one — or nil when
    /// `old_string` is empty, absent, or not unique without `replace_all`.
    private static func applying(_ edit: [String: Any], to text: String) -> String? {
        guard let old = edit["old_string"] as? String, !old.isEmpty,
              let new = edit["new_string"] as? String else { return nil }
        let ranges = text.ranges(of: old)
        if edit["replace_all"] as? Bool == true {
            return ranges.isEmpty ? nil : text.replacingOccurrences(of: old, with: new)
        }
        guard ranges.count == 1, let range = ranges.first else { return nil }
        return text.replacingCharacters(in: range, with: new)
    }

    /// The `content` a `Write` input carries when its `file_path` lies under
    /// `plansDirectory`.
    static func planContent(of input: String, under plansDirectory: URL) -> String? {
        planInput(input, under: plansDirectory)?["content"] as? String
    }

    /// A tool call's input object when its `file_path` lies under `plansDirectory`.
    private static func planInput(_ input: String, under plansDirectory: URL) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
              let path = object["file_path"] as? String else { return nil }
        let written = URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let directory = plansDirectory.standardizedFileURL.path
        return written.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/") ? object : nil
    }
}
