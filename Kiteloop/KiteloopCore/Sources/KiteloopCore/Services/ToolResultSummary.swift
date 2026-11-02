import Foundation

/// What a collapsed tool-call row says beside its tick or cross.
///
/// The text used to be a switch on the tool name that counted non-empty lines,
/// asking `ToolResultOutcome` only for which glyph to draw. A one-line error
/// therefore read "1 lines" or "1 matches", and the operator had to expand the
/// row to learn what went wrong. A failed row now says the error instead,
/// whatever the tool was; a successful row is unchanged.
///
/// The rule is a service rather than part of the view — the precedent
/// `ToolCallLabel` and `ToolResultOutcome` set out — so it can be asserted with
/// no view in the test.
package enum ToolResultSummary {

    /// How wide a collapsed row's summary may be, the width the default arm
    /// already cut its first line to.
    private static let rowWidth = 60

    /// The summary for a result: the error when the output reads as a failure,
    /// and otherwise the per-tool text.
    package static func text(tool: String, output: String) -> String {
        let lines = output.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard ToolResultOutcome.of(output: output).isError else {
            return success(tool: tool, lines: lines)
        }
        return ToolCallLabel.shorten(lines.first ?? "failed", limit: rowWidth)
    }

    private static func success(tool: String, lines: [String]) -> String {
        switch tool {
        case "Read":
            return "\(lines.count) lines"
        case "Grep", "Glob":
            return lines.count == 1 && lines[0].contains("No ") ? lines[0] : "\(lines.count) matches"
        default:
            return String((lines.first ?? "done").prefix(rowWidth))
        }
    }
}
