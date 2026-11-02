import Foundation
import KiteloopCore

/// The tool rows for one open project, gathered here so `GET /v1/health` and
/// the Diagnostics window derive them the same way — both show the same list,
/// or neither is trustworthy.
extension ProjectSession {

    /// Every verify command this project declares — each item's, and the verify
    /// map's — resolved against the project's own composed search path.
    /// Reads detail files and stats executables, so it is a call per refresh,
    /// not a property to read in a loop.
    func toolReachability() -> ToolReachability.ProjectReport {
        let items = backlogViewModel.backlogFile?.sections.flatMap(\.items) ?? []
        let commands = ToolReachability.commands(
            items: items.map { ($0, backlogViewModel.loadDetail(for: $0)) },
            map: VerifyMapFile.load(for: project))
        let search = ExecutableSearchPath.resolved(projectRoot: project.rootURL)
        return ToolReachability.report(root: project.rootURL, commands: commands,
                                       searchDirectories: search.directories,
                                       exports: BuildEnvironment.resolved(projectRoot: project.rootURL))
    }
}
