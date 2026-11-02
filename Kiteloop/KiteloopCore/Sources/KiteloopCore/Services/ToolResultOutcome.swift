import Foundation

/// Whether a tool call's output reads as a failure.
///
/// Nothing in the stream-json protocol flags a tool result as an error, so the
/// verdict is read off the text the tool printed: an output that opens with
/// "error", one saying "command failed", or one wrapped in the
/// `<tool_use_error>` Claude Code returns for a refused or failed call, is a
/// failure.
///
/// The rule is a service rather than part of a view — the precedent
/// `ToolCallLabel` sets out — so every surface that draws a result reads the
/// same way and the rule can be asserted directly, with no view in the test.
/// It used to live privately inside the collapsed summary, which meant the
/// standalone result row never asked it: a failed Bash, Read or Grep arriving
/// as its own row wore a green tick, and a run that went wrong looked fine.
package enum ToolResultOutcome: Equatable {
    case success
    case failure

    /// How far into the output the verdict is read from. A tool that failed
    /// says so at the top; a line deep in a successful build log mentioning an
    /// error is not the call failing.
    private static let inspectedPrefixLength = 200

    /// The verdict for an output. An empty output is a success — a tool that
    /// printed nothing did not report a failure.
    package static func of(output: String) -> ToolResultOutcome {
        let prefix = output.prefix(inspectedPrefixLength).lowercased()
        let failed = prefix.hasPrefix("error")
            || prefix.contains("<tool_use_error>")
            || prefix.contains("command failed")
        return failed ? .failure : .success
    }

    package var isError: Bool { self == .failure }
}
