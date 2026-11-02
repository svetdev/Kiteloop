import Foundation
import Combine

@MainActor
package final class StatusLineService: ObservableObject {
    @Published package var statusText: String = ""
    @Published package var contextWindowPercent: Double?

    private var timer: Timer?
    private let command: String?
    private let commandTimeout: TimeInterval
    private var sessionData: [String: Any] = [:]
    private var isRefreshing = false

    /// How long a status-line command may run before it's killed. Well under
    /// the 10s tick, so a hung command is gone long before the next refresh
    /// would otherwise pile a second one on top of it.
    package static let defaultCommandTimeout: TimeInterval = 5

    /// `settingsURL` is for tests only, so they read a settings file they wrote
    /// rather than whatever `statusLine.command` the developer running the suite
    /// happens to have configured — and never shell out to it. `commandTimeout`
    /// is likewise a test seam, so a case that asserts a hung command gets
    /// killed can use a fraction-of-a-second deadline instead of the real one.
    package init(settingsURL: URL? = nil, commandTimeout: TimeInterval = StatusLineService.defaultCommandTimeout) {
        self.command = Self.loadStatusLineCommand(at: settingsURL ?? Self.defaultSettingsURL)
        self.commandTimeout = commandTimeout
    }

    private static var defaultSettingsURL: URL {
        KiteloopHome.url
            .appendingPathComponent(".claude/settings.json")
    }

    package func updateSessionData(model: String? = nil, costUSD: Double? = nil,
                           inputTokens: Int? = nil, outputTokens: Int? = nil,
                           cacheReadInputTokens: Int? = nil, cacheCreationInputTokens: Int? = nil,
                           contextWindowSize: Int? = nil, sessionID: String? = nil,
                           cwd: String? = nil, gitBranch: String? = nil) {
        if let model { sessionData["model"] = ["display_name": model] }
        if let costUSD { sessionData["cost"] = ["total_cost_usd": costUSD] }
        if let contextWindowSize {
            var ctx = sessionData["context_window"] as? [String: Any] ?? [:]
            ctx["context_window_size"] = contextWindowSize
            if let inputTokens { ctx["total_input_tokens"] = inputTokens }
            if let outputTokens { ctx["total_output_tokens"] = outputTokens }
            if let cacheReadInputTokens { ctx["cache_read_input_tokens"] = cacheReadInputTokens }
            if let cacheCreationInputTokens { ctx["cache_creation_input_tokens"] = cacheCreationInputTokens }
            // Claude Code caches the prior conversation, so `input_tokens` is only the
            // newly-added (uncached) portion. Real context occupancy = all input components
            // (uncached + cache_read + cache_creation). Output tokens are NOT part of the
            // context window — they're the model's response, billed separately.
            let total = (inputTokens ?? 0)
                + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
            let pct = contextWindowSize > 0 ? (Double(total) / Double(contextWindowSize)) * 100 : 0
            ctx["used_percentage"] = Int(pct)
            ctx["remaining_percentage"] = 100 - Int(pct)
            sessionData["context_window"] = ctx
            contextWindowPercent = pct
        } else {
            if let inputTokens {
                var ctx = sessionData["context_window"] as? [String: Any] ?? [:]
                ctx["total_input_tokens"] = inputTokens
                sessionData["context_window"] = ctx
            }
            if let outputTokens {
                var ctx = sessionData["context_window"] as? [String: Any] ?? [:]
                ctx["total_output_tokens"] = outputTokens
                sessionData["context_window"] = ctx
            }
        }
        if let sessionID { sessionData["session"] = ["id": sessionID] }
        if let cwd { sessionData["cwd"] = cwd }
        if let gitBranch {
            sessionData["git"] = ["branch": gitBranch]
        }
    }

    package func start(interval: TimeInterval = 10) {
        guard command != nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    package func stop() {
        timer?.invalidate()
        timer = nil
        statusText = ""
    }

    package func refresh() {
        guard let command, !isRefreshing else { return }
        isRefreshing = true
        // sessionData is [String: Any] and can't cross into a detached task.
        // It only ever reaches the subprocess as JSON on stdin, so encode it
        // here on the main actor and send the Data.
        let inputData = (try? JSONSerialization.data(withJSONObject: sessionData)) ?? Data()
        let timeout = commandTimeout
        Task.detached {
            let result = Self.runCommand(command, input: inputData, timeout: timeout)
            await MainActor.run { [weak self] in
                self?.statusText = result
                self?.isRefreshing = false
            }
        }
    }

    private static func loadStatusLineCommand(at settingsURL: URL) -> String? {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusLine = json["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return nil
        }
        return command
    }

    /// Output goes to a temporary file rather than a `Pipe()`: draining a pipe
    /// means blocking until the child closes it, which is exactly what a
    /// command that never exits — one waiting on a network call, a stalled
    /// `git`, a script reading stdin — never does. That was the pipe-buffer
    /// deadlock this used to guard against (a command writing more than the
    /// ~64KB pipe buffer, the third instance of that defect after runDiff and
    /// the retired run supervisor's runGit); a hung child is the same failure
    /// by a different door, and a file sink alongside a bounded wait closes
    /// both at once — see `PullRequestPublisher.run`, which takes this same
    /// shape for the same reason.
    private nonisolated static func runCommand(_ command: String, input: Data, timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        // The app's one executable search policy, not a list of this file's
        // own: a status-line command finds `gh` or `jq` in the same places a
        // verify command does.
        process.environment = RunEnvironment.environment(projectRoot: nil)

        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "kiteloop-statusline-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path(percentEncoded: false), contents: nil),
              let sink = try? FileHandle(forWritingTo: outputURL) else {
            return ""
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = sink
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? sink.close()
            return ""
        }

        stdinPipe.fileHandleForWriting.write(input)
        stdinPipe.fileHandleForWriting.closeFile()

        waitOrKill(process, timeout: timeout)
        try? sink.close()

        let output = (try? Data(contentsOf: outputURL))
            .map { String(decoding: $0, as: UTF8.self) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Strip ANSI escape codes for display in SwiftUI
        return output.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// Waits for `process`, killing it and everything it forked past
    /// `timeout`. Descendants are collected *before* the root is signalled —
    /// `ProcessTree.descendantPIDs` walks `pgrep -P`, which only a still-running
    /// child reports — and swept the same way (TERM, a grace period, then KILL)
    /// once the root is down. Mirrors `PullRequestPublisher.waitOrKill`, with a
    /// shorter poll interval: that one bounds a 180s network call, this one a
    /// timeout meant to be a fraction of a second.
    private nonisolated static func waitOrKill(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                let descendants = ProcessTree.descendantPIDs(of: process.processIdentifier)
                process.terminate()
                usleep(500_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                ProcessTree.killDescendants(descendants)
                return
            }
            usleep(50_000)
        }
    }
}
