import Foundation
import os

private let buildEnvironmentLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "build-environment")

/// The environment variables a project exports into every verify shell and
/// agent spawn inside an item worktree or the merge scratch worktree, so build
/// output is shared per project across item worktrees.
///
/// Every autopilot item runs in a fresh worktree under
/// `.kiteloop/worktrees/<item-id>`, and a build tool that keys its output on
/// the directory it runs in starts cold in each one. On 2026-09-03 a Rust
/// project's items each paid a full `cargo build` — 18 to 27 minute runs,
/// most of it compilation the previous item had already done — and a verify
/// that needed an artifact under `target/` could never pass in the merge
/// scratch worktree, whose `target/` did not exist. Xcode is the one stack
/// deliberately left out: `WorktreeBuildOutput` gives each worktree its own
/// DerivedData because a shared one confused LaunchServices, and that decision
/// was measured and stands.
///
/// Two sources, composed into one list:
///
///   - **Derived defaults**, each only when its marker file exists at the
///     project root (`markers`): a `Cargo.toml` gives
///     `CARGO_TARGET_DIR=<root>/.kiteloop/build/cargo`, a `package.json` gives
///     `npm_config_cache=<root>/.kiteloop/build/npm`. Cargo serialises
///     concurrent users of one target directory with its own lock, so two item
///     runs building at once wait on each other rather than corrupt anything;
///     npm's cache is content-addressed and safe to share the same way.
///   - **The explicit map** `buildEnvironment` in `.kiteloop/config.json`,
///     whose entries win over the derived ones. A value may carry `~` and the
///     `$PROJECT_ROOT` placeholder. `PATH` is not settable here — it is
///     `ExecutableSearchPath`'s, and an entry naming it is dropped with a log
///     line rather than quietly splitting the search policy in two.
///
/// The directory under `.kiteloop/build` is the operator's to prune; nothing
/// here deletes it.
package enum BuildEnvironment {

    /// One exported variable, in the shape the health payload carries.
    package struct Export: Equatable, Hashable, Sendable {
        package let name: String
        package let value: String

        package init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// A file at the project root that names a stack, and what its presence
    /// exports: `variable` pointing at `outputDirectory/subdirectory`.
    package struct Marker: Equatable, Sendable {
        package let file: String
        package let variable: String
        package let subdirectory: String

        package init(file: String, variable: String, subdirectory: String) {
            self.file = file
            self.variable = variable
            self.subdirectory = subdirectory
        }
    }

    /// Where the shared output lives, relative to the project root. Under
    /// `.kiteloop/` because that path is already gitignored, so a build there
    /// never dirties the checkout's `git status`.
    package static let outputDirectory = ".kiteloop/build"

    /// What an explicit value may write in place of the project root's path.
    package static let projectRootPlaceholder = "$PROJECT_ROOT"

    /// The variable no explicit entry may set: the search path is one policy.
    package static let reservedName = ExecutableSearchPath.pathVariable

    /// The stacks with a derived default, in the order they are checked.
    package static let markers: [Marker] = [
        Marker(file: "Cargo.toml", variable: "CARGO_TARGET_DIR", subdirectory: "cargo"),
        Marker(file: "package.json", variable: "npm_config_cache", subdirectory: "npm"),
    ]

    // MARK: - Composition

    /// The policy as a pure function of its inputs, so a test drives it without
    /// a tree or a config file. `markers` is the set of marker file names found
    /// at the root; `explicit` the config map. Sorted by name so the same
    /// project reads the same way on every call.
    package static func compose(projectRoot: URL, markers: Set<String>,
                                explicit: [String: String], home: String) -> [Export] {
        let root = rootPath(projectRoot)
        var merged: [String: String] = [:]
        for marker in Self.markers where markers.contains(marker.file) {
            merged[marker.variable] = "\(root)/\(outputDirectory)/\(marker.subdirectory)"
        }
        for (name, value) in explicit {
            guard name != reservedName else {
                buildEnvironmentLog.notice("buildEnvironment: ignoring PATH — the search path is set by extraExecutablePaths")
                continue
            }
            merged[name] = expand(value, projectRoot: root, home: home)
        }
        return merged.keys.sorted().map { Export(name: $0, value: merged[$0]!) }
    }

    /// An explicit value with `~` expanded against `home` and every
    /// `$PROJECT_ROOT` replaced by the project root's path.
    package static func expand(_ value: String, projectRoot: String, home: String) -> String {
        ExecutableSearchPath.expandTilde(value, home: home)
            .replacingOccurrences(of: projectRootPlaceholder, with: projectRoot)
    }

    /// The root's path without a trailing slash, whichever way its URL was
    /// built, so a derived path never reads `root//.kiteloop`.
    private static func rootPath(_ projectRoot: URL) -> String {
        let path = projectRoot.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - The live policy

    /// Which marker files exist at `root`.
    package static func presentMarkers(at root: URL, fileManager: FileManager = .default) -> Set<String> {
        Set(markers.map(\.file).filter {
            fileManager.fileExists(atPath: root.appending(path: $0).path(percentEncoded: false))
        })
    }

    /// The exports for a project, reading its tree and its config fresh — the
    /// way `ExecutableSearchPath.resolved` reads the settings at every spawn.
    package static func resolved(projectRoot: URL) -> [Export] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let explicit = KiteloopProject(rootURL: projectRoot).loadConfig().buildEnvironment ?? [:]
        return compose(projectRoot: projectRoot, markers: presentMarkers(at: projectRoot),
                       explicit: explicit, home: home)
    }
}
