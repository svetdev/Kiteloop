import Foundation

/// Spawn a child process and capture its stdout without ever deadlocking on a
/// pipe.
///
/// Three call sites had each written this sequence by hand and each got half of
/// it right: they drained stdout before waiting — the fix in 098848e — and then
/// handed stderr a fresh `Pipe()` that nobody ever read, so the hazard the
/// comment above them claimed to have handled was still live on the other
/// stream. A child that writes more than the pipe buffer holds (~64 KB) blocks
/// on the write and never exits, and `waitUntilExit()` then never returns.
///
/// The rule this encodes is the one `RepoCloneService.runGit` already states: a
/// stream nobody reads gets `FileHandle.nullDevice`, not a `Pipe`.
package enum SubprocessOutput {

    /// What a finished child reported: its exit status and everything it wrote
    /// to stdout.
    package struct Result: Sendable {
        package let status: Int32
        package let standardOutput: Data

        /// stdout as text with surrounding whitespace stripped — the shape every
        /// caller here parses from.
        package var trimmedOutput: String {
            // Lossy: one byte that is not UTF-8 costs only itself, not the
            // whole output.
            String(decoding: standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(status: Int32, standardOutput: Data) {
            self.status = status
            self.standardOutput = standardOutput
        }
    }

    /// The runner every call below goes through — `LiveSubprocessRunner` unless
    /// a test has installed `ScriptedSubprocessRunner` (KiteloopTests/Support),
    /// which answers without spawning and records what would have run. The app
    /// never writes this. `nonisolated(unsafe)` because it is written only
    /// from a test's setUp and tearDown, which run serially inside one host
    /// process — parallel testing puts classes in separate processes — and is
    /// read from whatever thread spawns a child.
    package nonisolated(unsafe) static var runner: any SubprocessRunning = LiveSubprocessRunner()

    /// Runs `executable` to completion and returns its status and stdout.
    ///
    /// Synchronous — it blocks until the child exits, so call it off the main
    /// actor. Throws whatever `Process.run()` throws: a missing executable is
    /// the caller's to interpret, not this helper's to flatten into an empty
    /// result.
    package static func run(
        executable: String,
        arguments: [String],
        directory: URL? = nil,
        environment: [String: String]? = nil,
        mergeStandardError: Bool = false
    ) throws -> Result {
        try runner.run(executable: executable, arguments: arguments, directory: directory,
                       environment: environment, mergeStandardError: mergeStandardError)
    }

    /// Runs `/usr/bin/git` with `arguments` and reports its exit status and
    /// stdout — or `(-1, "")` when the child could not be spawned at all.
    ///
    /// `StrandedWorkSweep`, `ItemGitTruth` and `RunWorkEvidence` each declared a
    /// byte-identical private copy of this, and each carried a comment naming
    /// the other two as the same defect and the same fix — the duplication
    /// confessing itself. This is that one runner: the next fix to how the app
    /// spawns git is written here and reaches all three.
    ///
    /// All three read the tuple the same way, so both readings are preserved
    /// exactly. A git that could not start is no different to them from a git
    /// that failed, so a throw flattens to `-1` rather than propagating. And the
    /// output is stdout *verbatim* — untrimmed, because the callers split it
    /// into lines and trim the pieces themselves — with stderr discarded to the
    /// null device, so a chatty git cannot be mistaken for an answer.
    ///
    /// A working directory is passed as git's own `-C <root>`, which is what
    /// every call site here already does; there is no directory parameter.
    ///
    /// Synchronous — it blocks until git exits, so call it off the main actor.
    ///
    /// `executable` exists so the failed-spawn arm can be tested; nothing in the
    /// app passes it.
    package static func git(
        _ arguments: [String],
        executable: String = "/usr/bin/git"
    ) -> (status: Int32, output: String) {
        guard let result = try? run(executable: executable, arguments: arguments) else {
            return (-1, "")
        }
        return (result.status, String(decoding: result.standardOutput, as: UTF8.self))
    }

    /// Runs `executable` with a **deadline**, returning its status and its
    /// stdout and stderr interleaved.
    ///
    /// `run(executable:…)` above has no time limit, which is right for a child
    /// that always exits and wrong for one that talks to a network: a `git
    /// fetch` against an unreachable host, or an ssh that stops for a
    /// passphrase, never exits at all, and a caller holding a serial queue while
    /// it waits blocks everything behind it for ever.
    ///
    /// Output goes to a temporary file rather than a `Pipe()`, for the reason
    /// `PullRequestPublisher.run` already states: draining a pipe means blocking
    /// until the child closes it, which is exactly what a hung command never
    /// does, so the deadline could never be reached. A file lets the wait be a
    /// poll.
    ///
    /// Past the deadline the child is killed — with its descendants, which
    /// signalling it alone leaves running and reparented — and the call reports
    /// a failed command (`-1`) whose output says it timed out. Callers that
    /// already branch on a non-zero status take their failure arm unchanged;
    /// `timedOut` is there for the ones that want to say *why* in a log line,
    /// without reading it back out of the output text.
    ///
    /// Synchronous: it blocks for up to `timeout`, so call it off the main
    /// actor. `directory` is the child's working directory, and `run` above takes
    /// one too; both go through `runner`.
    ///
    /// `discardStandardError` sends the child's stderr to the null device
    /// instead of folding it into `output`, for a caller whose stdout is
    /// parsed as an answer rather than a log — `SessionTitleGenerator` cannot
    /// let a child's stderr chatter end up in a session title. Defaults to
    /// `false`, the interleaved behaviour `DebateOrchestrator` and
    /// `BacklogParser` already depend on.
    package static func runWithDeadline(
        executable: String,
        arguments: [String],
        directory: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        discardStandardError: Bool = false
    ) -> (status: Int32, output: String, timedOut: Bool) {
        runner.runWithDeadline(executable: executable, arguments: arguments, directory: directory,
                               environment: environment, timeout: timeout,
                               discardStandardError: discardStandardError)
    }
}

/// How the app spawns a child and reads what it wrote — the one seam between
/// the code that decides to run `git`, `gh`, a hook or a verify command and
/// the process that actually runs. Every `Process()` the app starts to
/// completion goes through `SubprocessOutput`, which goes through this;
/// `LiveSubprocessRunner` is the only conformer the app constructs, and a test
/// installs another through `SubprocessOutput.runner` to make a git fail, a
/// command time out or a tool be missing without a real child and without a
/// real clock. The long-lived children — the agent CLI, a hook reading a JSON
/// payload on stdin — are not this shape and keep their own `Process`.
package protocol SubprocessRunning: Sendable {
    /// `SubprocessOutput.run`: to completion, stdout drained, stderr folded in
    /// or dropped, stdin the null device. Throws what `Process.run()` throws.
    func run(
        executable: String,
        arguments: [String],
        directory: URL?,
        environment: [String: String]?,
        mergeStandardError: Bool
    ) throws -> SubprocessOutput.Result

    /// `SubprocessOutput.runWithDeadline`: killed with its descendants past
    /// `timeout`, reported as `-1` with `timedOut` set.
    func runWithDeadline(
        executable: String,
        arguments: [String],
        directory: URL?,
        environment: [String: String]?,
        timeout: TimeInterval,
        discardStandardError: Bool
    ) -> (status: Int32, output: String, timedOut: Bool)
}

/// The runner that spawns. The bodies here are the ones `SubprocessOutput`
/// carried as statics, unchanged in what they do; see the doc comments on the
/// statics for why each does it that way.
package struct LiveSubprocessRunner: SubprocessRunning {
    package func run(
        executable: String,
        arguments: [String],
        directory: URL?,
        environment: [String: String]?,
        mergeStandardError: Bool
    ) throws -> SubprocessOutput.Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }

        let pipe = Pipe()
        process.standardOutput = pipe
        // nullDevice, not a second Pipe: nothing reads a separate stderr, and an
        // undrained pipe wedges the child the moment it writes past the buffer.
        // A caller that wants stderr gets it folded into the one pipe that is
        // drained.
        process.standardError = mergeStandardError ? pipe : FileHandle.nullDevice
        // Nothing here can answer a prompt, and this call has no deadline behind
        // it: a child that stopped to ask for a credential would otherwise hold
        // the app's own stdin — and this caller — open for ever. The null device
        // gives it EOF instead.
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Drain *before* waiting. A child that fills the stdout buffer blocks on
        // the write and never exits, so waiting first deadlocks.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Only after the wait: `terminationStatus` traps on a task that is still
        // running.
        return SubprocessOutput.Result(status: process.terminationStatus, standardOutput: data)
    }
    package func runWithDeadline(
        executable: String,
        arguments: [String],
        directory: URL?,
        environment: [String: String]?,
        timeout: TimeInterval,
        discardStandardError: Bool
    ) -> (status: Int32, output: String, timedOut: Bool) {
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "kiteloop-subprocess-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil),
              let sink = try? FileHandle(forWritingTo: logURL) else {
            // Nowhere to capture to. Every caller reads the output, so running
            // blind would be worse than not running: report a failed command.
            return (-1, "could not capture output", false)
        }
        defer { try? FileManager.default.removeItem(at: logURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if let environment { process.environment = environment }
        process.standardOutput = sink
        process.standardError = discardStandardError ? FileHandle.nullDevice : sink
        // Nothing here can answer a prompt, and `GIT_TERMINAL_PROMPT=0` does not
        // stop an askpass read: a child that stopped to ask for a passphrase
        // would otherwise sit on the app's own stdin until the deadline killed
        // it. The null device gives it EOF instead.
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            try? sink.close()
            return (-1, "", false)
        }
        let finished = Self.waitOrKill(process, timeout: timeout)
        try? sink.close()
        // Lossy: a child killed mid-character, or one printing a stray byte,
        // must not lose everything it wrote before it.
        let output = (try? Data(contentsOf: logURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard finished else { return (-1, output + "\ntimed out after \(Int(timeout))s", true) }
        return (process.terminationStatus, output, false)
    }
    /// Waits for `process`, killing it past `timeout`. False when it had to be
    /// killed.
    ///
    /// Signalling the child alone does not reach anything it forked, which TERM
    /// and KILL both leave running and reparented. So its descendants are
    /// collected *before* it is signalled, while the tree is still intact for
    /// `pgrep -P` to walk, and swept the same way once the root is down.
    private static func waitOrKill(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                let descendants = ProcessTree.descendantPIDs(of: process.processIdentifier)
                process.terminate()
                usleep(500_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                ProcessTree.killDescendants(descendants)
                return false
            }
            usleep(200_000)
        }
        return true
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init() {
    
    }
}
