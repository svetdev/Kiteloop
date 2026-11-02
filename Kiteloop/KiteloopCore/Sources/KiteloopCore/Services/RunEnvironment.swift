import Foundation

/// The one environment a child runs with on a project's behalf: the composed
/// search path (`ExecutableSearchPath`) and the project's build exports
/// (`BuildEnvironment`), applied together so no caller can take one and miss
/// the other. The verify shell, the merge scratch verify and every agent
/// spawn read this; a child on behalf of no project gets the search path
/// alone.
package enum RunEnvironment {

    /// The variables this policy sets, without a base to lay them on — for a
    /// caller that composes an environment of its own and layers these on
    /// top, the way the runtime lays them over the auth environment.
    package static func overlay(projectRoot: URL?) -> [String: String] {
        var overlay = [ExecutableSearchPath.pathVariable: ExecutableSearchPath.resolved(projectRoot: projectRoot).joined]
        guard let projectRoot else { return overlay }
        for export in BuildEnvironment.resolved(projectRoot: projectRoot) {
            overlay[export.name] = export.value
        }
        return overlay
    }

    /// `base` with the overlay applied — what a verify shell is spawned with.
    package static func environment(projectRoot: URL?,
                                    base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.merging(overlay(projectRoot: projectRoot)) { _, policy in policy }
    }

    /// The overlay for a child spawned in `directory` — the project above it,
    /// when it is a worktree. The shape `ClaudeCodeCLIRuntime` is handed at
    /// construction: the runtime layer may not name this type, so the app
    /// injects this function.
    package static func overlay(forWorkingDirectory directory: URL) -> [String: String] {
        overlay(projectRoot: ExecutableSearchPath.projectRoot(enclosing: directory))
    }
}
