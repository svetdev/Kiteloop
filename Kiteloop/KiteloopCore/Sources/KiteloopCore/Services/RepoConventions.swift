import Foundation

/// What a repository says about itself that the autopilot used to ask a
/// person to type twice: what a fresh worktree needs before anything runs in
/// it, and what to run on a merged tree before it lands. Both are on disk —
/// a lockfile means an install, a generator's spec beside a gitignored project
/// means a generate, and the verify map's widest rule is the project's own
/// idea of "green". A value a person configured still wins; this is the
/// answer when nothing was configured.
///
/// Pure over a listing of repo-relative paths (and the ignore rules), so the
/// tests build a directory and read what it implies; the `URL` entry points
/// do the listing.
package enum RepoConventions {

    /// A command and where it came from — `source` is prose for a settings
    /// page or a `GET`, never a value to parse.
    package struct Derived: Equatable, Sendable {
        package let command: String?
        package let source: String

        package init(command: String?, source: String) {
            self.command = command
            self.source = source
        }

        /// What a configured value reports as its source.
        package static let configured = "configured"
    }

    /// Directories nothing sensible lives in for this purpose — dependency
    /// trees, build output, the app's own state.
    package static let skippedDirectories: Set<String> = [
        ".git", ".kiteloop", "node_modules", "target", "build", "dist", "DerivedData",
        "Pods", ".build", "vendor", ".svn", ".hg", "coverage", ".next", ".turbo",
    ]

    /// How deep under the root a lockfile is still the project's own rather
    /// than a fixture's.
    package static let maxDepth = 4

    // MARK: - Setup

    /// The setup a tree implies, one step per lockfile or generator found,
    /// each run in its own directory in a subshell so the steps cannot
    /// leave each other in the wrong place. Nil when the tree implies nothing.
    package static func setupCommand(files: [String], gitignore: String = "") -> Derived {
        let paths = files.map(normalize).filter { !$0.isEmpty }
        let present = Set(paths)
        let steps = paths.compactMap { path -> Step? in
            let (directory, name) = split(path)
            guard depth(of: directory) < maxDepth else { return nil }
            return step(for: name, in: directory, present: present, gitignore: gitignore)
        }
        guard !steps.isEmpty else { return Derived(command: nil, source: "nothing to set up — no lockfile or generator in the tree") }
        return joined(steps.sorted { ($0.directory, $0.command) < ($1.directory, $1.command) })
    }

    /// One install or generate, in the directory that asked for it.
    private struct Step {
        let directory: String
        let command: String
        let why: String
    }

    /// The lockfiles that mean an install, and the install each means.
    private static let installs: [String: (command: String, why: String)] = [
        "package-lock.json": ("npm ci", "a package-lock"),
        "pnpm-lock.yaml": ("pnpm install --frozen-lockfile", "a pnpm lockfile"),
        "yarn.lock": ("yarn install --frozen-lockfile", "a yarn lockfile"),
        "Podfile.lock": ("pod install", "a Podfile.lock"),
    ]

    private static func step(for name: String, in directory: String, present: Set<String>, gitignore: String) -> Step? {
        if let install = installs[name] {
            return Step(directory: directory, command: install.command, why: install.why)
        }
        if name == "project.yml", xcodeprojIsGenerated(in: directory, present: present, gitignore: gitignore) {
            return Step(directory: directory, command: "xcodegen generate", why: "a project.yml with a gitignored .xcodeproj")
        }
        return nil
    }

    /// The steps as one command, each in its own subshell so none leaves the
    /// next in the wrong directory, and one source line naming them all.
    private static func joined(_ steps: [Step]) -> Derived {
        let command = steps.map { step in
            step.directory.isEmpty ? step.command : "(cd \(shellQuoted(step.directory)) && \(step.command))"
        }.joined(separator: " && ")
        let sources = steps.map { step in
            step.directory.isEmpty ? "\(step.why) at the root" : "\(step.why) under \(step.directory)"
        }
        return Derived(command: command, source: "from " + sources.joined(separator: ", "))
    }

    /// The setup the tree at `projectRoot` implies — the listing is git's own
    /// when the root is a repository (so ignored trees never count), a walk
    /// otherwise. The `.gitignore` at the root is read for the generator rule.
    package static func setupCommand(projectRoot: URL) -> Derived {
        let files = listing(of: projectRoot)
        let ignore = (try? Data(contentsOf: projectRoot.appending(path: ".gitignore")))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return setupCommand(files: files, gitignore: ignore)
    }

    // MARK: - Merge verify

    /// The verify map's widest rule — the one whose glob matches the most of
    /// the tree, ties to the longest command — as the project's merge-verify.
    /// Nil when there is no map or nothing in the tree matches any rule.
    package static func mergeVerifyCommand(map: VerifyCoverage.Map, files: [String]) -> Derived {
        guard !map.isEmpty else { return Derived(command: nil, source: "no verify map") }
        let paths = files.map(normalize).filter { !$0.isEmpty }
        var best: Candidate?
        for rule in map.rules {
            let matched = paths.filter { VerifyCoverage.matches(glob: rule.glob, path: $0) }.count
            let candidate = Candidate(rule: rule, matched: matched)
            if candidate.beats(best) { best = candidate }
        }
        guard let best else { return Derived(command: nil, source: "no verify-map rule matches anything in the tree") }
        return Derived(command: best.rule.runnable, source: "from verify-map rule `\(best.rule.glob)`")
    }

    /// A rule and how much of the tree it reaches; wider wins, a tie goes to
    /// the longer command, and a rule reaching nothing never wins.
    private struct Candidate {
        let rule: VerifyCoverage.Rule
        let matched: Int

        func beats(_ other: Candidate?) -> Bool {
            guard matched > 0 else { return false }
            guard let other else { return true }
            if matched != other.matched { return matched > other.matched }
            return rule.runnable.count > other.rule.runnable.count
        }
    }

    package static func mergeVerifyCommand(projectRoot: URL, map: VerifyCoverage.Map) -> Derived {
        guard !map.isEmpty else { return Derived(command: nil, source: "no verify map") }
        return mergeVerifyCommand(map: map, files: listing(of: projectRoot))
    }

    // MARK: - Reading the tree

    /// Repo-relative paths under the root: `git ls-files` where the root is a
    /// repository, a bounded walk that skips the usual heavy directories
    /// otherwise.
    package static func listing(of root: URL) -> [String] {
        let path = root.path(percentEncoded: false)
        let tracked = SubprocessOutput.git(["-C", path, "ls-files", "-z"])
        if tracked.status == 0 {
            let names = tracked.output.split(separator: "\0").map(String.init)
            if !names.isEmpty { return names }
        }
        return walk(root)
    }

    private static func walk(_ root: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        var out: [String] = []
        for case let url as URL in enumerator {
            let relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if skippedDirectories.contains(url.lastPathComponent) || depth(of: relative) >= maxDepth {
                    enumerator.skipDescendants()
                }
                continue
            }
            out.append(relative)
        }
        return out
    }

    // MARK: - Helpers

    private static func xcodeprojIsGenerated(in directory: String, present: Set<String>, gitignore: String) -> Bool {
        let prefix = directory.isEmpty ? "" : directory + "/"
        let projectOnDisk = present.contains { $0.hasPrefix(prefix) && $0.dropFirst(prefix.count).contains(".xcodeproj/") }
        if !projectOnDisk { return true }
        let ignored = gitignore.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { line in !line.hasPrefix("#") && line.contains(".xcodeproj") }
        return ignored
    }

    private static func split(_ path: String) -> (directory: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    private static func depth(of directory: String) -> Int {
        directory.isEmpty ? 0 : directory.split(separator: "/").count
    }

    private static func normalize(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        return value.unicodeScalars.allSatisfy(safe.contains) ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
