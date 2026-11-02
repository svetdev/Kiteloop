import Foundation

package enum SessionTitleGenerator {
    /// How long the child gets before it is killed and the title given up on.
    package static let defaultTimeout: TimeInterval = 60

    /// Asks `claude` for a short title for the conversation so far.
    ///
    /// `claudePath` is the executable to spawn — resolve it the same way every
    /// other caller does, via `CLIResolver`, and pass `nil` when nothing
    /// resolves; this makes no lookup of its own. `executableURL` and
    /// `arguments` default to the real CLI invocation; they exist so a test can
    /// point the run at `/bin/sh` and assert the draining and the timeout
    /// without a `claude` binary on the machine.
    package static func generate(
        from messages: [Message],
        claudePath: String?,
        executableURL: URL? = nil,
        arguments: (String) -> [String] = { ["--print", "--model", "haiku", "-p", $0] },
        timeout: TimeInterval = defaultTimeout
    ) async -> String? {
        let context = messages.prefix(6).compactMap { msg -> String? in
            switch (msg.sender, msg.content) {
            case (.human, .text(let t)): return "User: \(String(t.prefix(200)))"
            case (.agent, .text(let t)): return "Agent: \(String(t.prefix(300)))"
            default: return nil
            }
        }.joined(separator: "\n")

        guard !context.isEmpty else { return nil }
        // Nothing to spawn: no configured override, no `which`, no candidate
        // path found anything, so the session keeps its heuristic title.
        guard let executable = executableURL?.path(percentEncoded: false) ?? claudePath else { return nil }

        let prompt = """
        Generate a short title (3-7 words, no quotes) summarizing this conversation:

        \(context)
        """
        let args = arguments(prompt)
        let environment = ProcessInfo.processInfo.environment

        // `runWithDeadline` blocks until the child exits or the deadline fires,
        // so it is kept off the Swift concurrency pool the same way every other
        // call to it already is.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = SubprocessOutput.runWithDeadline(
                    executable: executable,
                    arguments: args,
                    environment: environment,
                    timeout: timeout,
                    // A session title is read straight off stdout; a chatty
                    // stderr must not end up in it the way it can in the
                    // grounding and git callers of this runner.
                    discardStandardError: true
                )
                guard result.status == 0, !result.timedOut else {
                    continuation.resume(returning: nil)
                    return
                }
                // The first non-blank line, whitespace collapsed: a model that
                // adds an explanation under its title does not get it shown.
                let firstLine = result.output.split(whereSeparator: \.isNewline)
                    .lazy
                    .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                    .first { !$0.isEmpty }
                continuation.resume(returning: firstLine.map { String($0.prefix(60)) })
            }
        }
    }
}
