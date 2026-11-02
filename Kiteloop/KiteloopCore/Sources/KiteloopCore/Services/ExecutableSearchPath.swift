import Foundation

/// The one answer to "where does this app look for a tool". A GUI app launched
/// from Finder inherits a thin `PATH` — none of the login shell's additions
/// reach it — and on 2026-09-03 three places in Kiteloop each answered the
/// question with a list of their own: the grounding check refused a `cargo`
/// verify at grooming for resolving to no executable, and the merge gate's
/// login shell could not see a pip-installed `lizard`, both on a machine where
/// the tools were installed and on the operator's own `PATH`. This is the
/// single policy every consumer reads — grounding, the verify shell, agent
/// spawns, the credential checks — so the app's answer is one answer.
///
/// The search path is composed in this order, deduplicated keeping the first
/// occurrence:
///
///   1. the login shell's `PATH`, captured once per app launch
///      (`loginShellPath`); the app's own environment when the capture fails;
///   2. the fixed extras: Homebrew on both architectures, MacPorts,
///      `/usr/local/bin`, and `~/.local/bin`, `~/.npm/bin`, `~/.cargo/bin`;
///   3. the global setting `extraExecutablePaths` (`~/.kiteloop/global-config.json`);
///   4. the project's `extraExecutablePaths` (`.kiteloop/config.json`).
///
/// A settings entry may be written with `~`; it is expanded against `home`.
///
/// A child gets this as its `PATH` through `RunEnvironment`, which lays the
/// project's build exports (`BuildEnvironment`) beside it.
package enum ExecutableSearchPath {

    /// The variable this policy sets, and the one `BuildEnvironment` refuses
    /// to let a config map override.
    package static let pathVariable = "PATH"

    /// What the shell falls back to when it has no `PATH` at all — and what
    /// this policy falls back to when the app has none either.
    package static let standardSystemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// How long the login shell gets to print its `PATH`. A `~/.zprofile` that
    /// hangs — waiting on a network mount, an `ssh-add` prompt — must not hold
    /// the first spawn hostage; past this the app's own environment answers.
    package static let loginShellTimeout: TimeInterval = 5

    /// The composed search path in both shapes a consumer needs: the directory
    /// list a resolver walks, and the `PATH` string a child's environment takes.
    package struct Resolved: Equatable, Sendable {
        package let directories: [String]

        package init(directories: [String]) {
            self.directories = directories
        }

        /// The directories joined the way `PATH` is spelled.
        package var joined: String { directories.joined(separator: ":") }
    }

    // MARK: - Composition

    /// The fixed extras every lookup gets, in the order they are searched.
    /// `home` carries no trailing slash, matching
    /// `FileManager.homeDirectoryForCurrentUser.path(percentEncoded: false)`.
    package static func fixedExtras(home: String) -> [String] {
        [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm/bin",
            "\(home)/.cargo/bin",
        ]
    }

    /// The policy as a pure function of its four inputs, so the order and the
    /// dedup can be pinned without a shell, a home directory or a config file.
    /// `loginPath` nil means the capture failed and nothing else stood in — the
    /// standard system path is used, as a shell with no `PATH` would.
    package static func compose(loginPath: String?, home: String,
                                globalExtras: [String], projectExtras: [String]) -> Resolved {
        let login = (loginPath ?? standardSystemPath).split(separator: ":").map(String.init)
        let settings = (globalExtras + projectExtras).map { expandTilde($0, home: home) }
        var seen: Set<String> = []
        let directories = (login + fixedExtras(home: home) + settings)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return Resolved(directories: directories)
    }

    /// `~` and `~/…` against `home`; anything else is returned as written.
    /// Done by hand rather than through `expandingTildeInPath` so a test can
    /// hand in a home directory of its own.
    package static func expandTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    // MARK: - The login shell

    /// Asks `/bin/zsh -lc` for its `PATH`, through the subprocess seam so a
    /// test can script the answer. Falls back to `fallback` — the app's own
    /// `PATH` — when the shell fails, prints nothing, or does not answer within
    /// `loginShellTimeout`; the standard system path when that is nil too.
    package static func captureLoginShellPath(
        fallback: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> String {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/bin/zsh",
            arguments: ["-lc", "printf %s \"$PATH\""],
            timeout: loginShellTimeout,
            discardStandardError: true)
        let printed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !result.timedOut, !printed.isEmpty else {
            return fallback ?? standardSystemPath
        }
        return printed
    }

    /// The login shell's `PATH`, captured once per app launch. A `static let`
    /// is initialised exactly once and every later reader waits on that one
    /// initialisation, so no spawn pays for the capture twice. `KiteloopApp`
    /// warms it off the main actor at launch; a reader that gets there first
    /// blocks for at most `loginShellTimeout`.
    package static let loginShellPath: String = captureLoginShellPath()

    // MARK: - The live policy

    /// The composed search path for a project — or for no project, when the
    /// spawn is not on behalf of one — reading both settings files fresh, the
    /// way `SpawnTimeConfigRead` reads the global config at every spawn.
    package static func resolved(projectRoot: URL?) -> Resolved {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let global = SpawnTimeConfigRead.load()?.extraExecutablePaths ?? []
        let project = projectRoot.map { KiteloopProject(rootURL: $0).loadConfig().extraExecutablePaths ?? [] } ?? []
        return compose(loginPath: loginShellPath, home: home, globalExtras: global, projectExtras: project)
    }

    /// The project a working directory belongs to. An item's worktree lives at
    /// `<root>/.kiteloop/worktrees/<key>` (`WorktreeSession.worktreeDirectory`)
    /// and carries no `.kiteloop/config.json` of its own, so a spawn there
    /// reads the settings of the project above it; any other directory is its
    /// own project.
    package static func projectRoot(enclosing directory: URL) -> URL {
        let path = directory.path(percentEncoded: false)
        guard let range = path.range(of: "/.kiteloop/worktrees/") else { return directory }
        // `isDirectory: false` on purpose: it is how every project root URL in
        // the app is built, and the `true` form appends a slash `path()` keeps.
        return URL(fileURLWithPath: String(path[..<range.lowerBound]), isDirectory: false)
    }
}
