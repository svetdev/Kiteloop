import Foundation

/// Which tools a project's verify commands need, and where each one resolved
/// — or the directories that were searched when it did not.
///
/// The question behind it: "can this app run this project's `verify:`?" On
/// 2026-09-03 the answer was found one refusal at a time — a `cargo` refused at
/// grooming, a `lizard` invisible at the merge gate — each on a machine where
/// the tool was installed. This reads every verify command the project
/// declares, asks the one search policy (`ExecutableSearchPath`) where each
/// executable is, and hands back a row per tool for `GET /v1/health` and the
/// Diagnostics window to show *before* a run is refused.
package enum ToolReachability {

    /// One executable a verify command runs: its resolved absolute path, or
    /// nil with the directories that were searched for it.
    package struct Row: Equatable, Sendable {
        package let name: String
        package let path: String?
        /// Where the app looked, when `path` is nil. Empty otherwise.
        package let searched: [String]

        package init(name: String, path: String?, searched: [String]) {
            self.name = name
            self.path = path
            self.searched = searched
        }

        package var isReachable: Bool { path != nil }
    }

    /// The rows for one open project, with what names it in a payload — and
    /// the build exports (`BuildEnvironment`) every verify and spawn on the
    /// project's behalf runs with, shown beside the tools because a verify
    /// that cannot find its build output fails the same way as one that
    /// cannot find its tool.
    package struct ProjectReport: Equatable, Sendable {
        package let project: String
        package let path: String
        package let tools: [Row]
        package let exports: [BuildEnvironment.Export]

        package init(project: String, path: String, tools: [Row], exports: [BuildEnvironment.Export] = []) {
            self.project = project
            self.path = path
            self.tools = tools
            self.exports = exports
        }
    }

    /// Every verify command a project declares: each item's groomed or
    /// item-line `verify:` (the same reading `GroundingCheck` grounds against)
    /// and the verify map's runnable commands. Distinct, in first-seen order.
    package static func commands(items: [(item: BacklogItem, detail: BacklogItemDetail?)],
                                 map: VerifyCoverage.Map) -> [String] {
        var seen: Set<String> = []
        let declared = items.flatMap { GroundingCheck.verifyCommands(item: $0.item, detail: $0.detail) }
        let mapped = map.rules.map(\.runnable)
        return (declared + mapped).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// One row per distinct executable the commands run, sorted by name so the
    /// same project reads the same way on every call. Executables are lifted
    /// out of a command the way the grounding check lifts them
    /// (`GroundingCheck.executableTokens`), and resolved the way it resolves
    /// them — a bare name through `searchDirectories`, a path against `root`.
    package static func rows(commands: [String], root: URL, searchDirectories: [String],
                             fileManager: FileManager = .default) -> [Row] {
        var names: Set<String> = []
        let tokens = commands.flatMap(GroundingCheck.executableTokens(in:))
            .filter { names.insert($0).inserted }
        return tokens.sorted().map { token in
            let path = GroundingCheck.Executables.resolvedPath(
                token, root: root, fileManager: fileManager, searchDirectories: searchDirectories)
            return Row(name: token, path: path, searched: path == nil ? searched(for: token, root: root, in: searchDirectories) : [])
        }
    }

    /// What was searched for a token that resolved nowhere: the directory list
    /// for a bare name, the project root for a path written relative to it.
    private static func searched(for token: String, root: URL, in directories: [String]) -> [String] {
        token.contains("/") ? [root.path(percentEncoded: false)] : directories
    }

    /// `rows`, gathered into the report a payload carries. `root` names the
    /// project by its last path component, the way `GET /v1/projects` does.
    package static func report(root: URL, commands: [String], searchDirectories: [String],
                               exports: [BuildEnvironment.Export] = [],
                               fileManager: FileManager = .default) -> ProjectReport {
        ProjectReport(
            project: root.lastPathComponent,
            path: root.path(percentEncoded: false),
            tools: rows(commands: commands, root: root, searchDirectories: searchDirectories,
                        fileManager: fileManager),
            exports: exports)
    }
}
