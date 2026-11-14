import Foundation

/// A second git repository an item of this project may change alongside the
/// project's own (ADR-0005): a library beside its reference app, a client
/// beside the server it calls.
///
/// The project names its companions in `.kiteloop/config.json`; an item opts
/// in with `repos:` in its detail frontmatter. A companion has no backlog, no
/// autopilot and no gate of its own here — it is somewhere a run's branch may
/// also exist, checked out under the run's own worktree so one path names
/// both the repository and the file.
package struct CompanionRepo: Codable, Equatable, Sendable {
    /// What an item's `repos:` calls it, and the folder its worktree takes
    /// under `.kiteloop/repos/`.
    package var name: String
    /// Where the repository is on this Mac: absolute, `~`-relative, or
    /// relative to the project's root.
    package var path: String
    /// The branch its runs fork from and land on; nil for whatever its own
    /// checkout is on.
    package var baseBranch: String?

    package init(name: String, path: String, baseBranch: String? = nil) {
        self.name = name
        self.path = path
        self.baseBranch = baseBranch
    }

    /// Where every companion's worktree sits inside a run's tree. Under
    /// `.kiteloop/`, which a project ignores, so the project's own git never
    /// sees a repository nested in it.
    package static let directory = ".kiteloop/repos"

    /// A name is a folder name: letters, digits, `-`, `_` and `.`, not
    /// starting with a dot.
    package static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first != "." else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The repository's own checkout.
    package func root(projectRoot: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return projectRoot.appending(path: expanded).standardizedFileURL
    }

    /// This companion's worktree inside `tree` — a run's worktree, or the
    /// merge gate's scratch one.
    package func checkout(in tree: URL) -> URL {
        tree.appending(path: Self.directory).appending(path: name)
    }

    /// The path a worker, a reviewer and a `verify:` reach it by.
    package var relativePath: String { "\(Self.directory)/\(name)" }

    /// The names an item asked for, as it wrote them in `repos:` — a comma
    /// list, with or without brackets.
    package static func names(fromFrontmatter value: String) -> [String] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")) }
            .filter { !$0.isEmpty }
    }

    /// What is wrong with a project's list, one phrase per problem; empty for
    /// a list a run can use.
    package static func problems(in companions: [CompanionRepo]) -> [String] {
        var problems: [String] = []
        var seen: Set<String> = []
        for companion in companions {
            if !isValidName(companion.name) {
                problems.append("companion name \"\(companion.name)\" takes letters, digits, - _ and . only")
            }
            if !seen.insert(companion.name).inserted {
                problems.append("companion \"\(companion.name)\" is listed twice")
            }
            if companion.path.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("companion \"\(companion.name)\" has no path")
            }
        }
        return problems
    }

    /// The companions an item named, in the order it named them, and the names
    /// that match none.
    package static func resolve(
        _ names: [String], among companions: [CompanionRepo]
    ) -> (found: [CompanionRepo], unknown: [String]) {
        var found: [CompanionRepo] = []
        var unknown: [String] = []
        for name in names where !found.contains(where: { $0.name == name }) {
            if let match = companions.first(where: { $0.name == name }) {
                found.append(match)
            } else if !unknown.contains(name) {
                unknown.append(name)
            }
        }
        return (found, unknown)
    }

    /// The companion as the control API returns it.
    package var json: [String: Any] {
        var out: [String: Any] = ["name": name, "path": path]
        if let baseBranch { out["baseBranch"] = baseBranch }
        return out
    }
}
