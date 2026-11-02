import Foundation

package struct CLIResolver {
    package static let claude: String? = resolveClaude()
    package static let node: String? = resolveNode()

    private static func resolveClaude() -> String? {
        if let path = whichPath("claude") {
            return path
        }
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/claude").path(percentEncoded: false),
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".npm/bin/claude").path(percentEncoded: false),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func resolveNode() -> String? {
        if let path = whichPath("node") {
            return path
        }
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The paths the app should actually spawn and report, honouring the
    /// `claudePath`/`nodePath` overrides in `~/.kiteloop/global-config.json`.
    ///
    /// An unusable override falls through to the memoized statics rather than
    /// re-running the lookup: the answer is the same — both statics *are* the
    /// PATH-then-candidates lookup — but that lookup spawns `which`, and this is
    /// called for every runtime the app builds and on every Settings redraw.
    package static func resolve(globalConfig: GlobalConfig) -> (claude: String?, node: String?) {
        (claude: usableOverride(globalConfig.claudePath) ?? claude,
         node: usableOverride(globalConfig.nodePath) ?? node)
    }

    /// A configured path counts only when it names a file we can execute. Empty,
    /// missing and non-executable are all "nothing configured": returning nil
    /// puts the caller back on the `which`-then-candidates fallback rather than
    /// failing to launch on a path the user typed wrong.
    private static func usableOverride(_ path: String?) -> String? {
        guard let path, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private static func whichPath(_ command: String) -> String? {
        guard let result = try? SubprocessOutput.run(
            executable: "/usr/bin/env",
            arguments: ["which", command]
        ), result.status == 0 else { return nil }
        let path = result.trimmedOutput
        return path.isEmpty ? nil : path
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init() {
    
    }
}
