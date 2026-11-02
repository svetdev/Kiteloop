import Foundation

/// What a phone may read of a project's working tree: what an agent has
/// changed so far, and a file it names — read-only, inside the project, and
/// never a file git ignores, which is where local secrets live.
package enum WorkspaceReader {

    /// The same cap the gate's diff uses, so a phone never holds more of one
    /// patch than the review screen does.
    package static let patchCap = 200_000
    /// The largest file shown whole: a source file, not a build artifact.
    package static let fileCap = 500_000
    /// Each git is killed rather than waited on past this.
    package static let gitTimeout: TimeInterval = 30

    // MARK: - Uncommitted changes

    package struct ChangedFile: Equatable {
        /// `git status --porcelain`'s two letters: " M", "A ", "??" and so on.
        package let status: String
        package let path: String
    }

    package enum Changes: Equatable {
        case changes(files: [ChangedFile], patch: String, truncated: Bool)
        case notARepository
        case timedOut
    }

    /// The working tree against HEAD: every changed or untracked file, and the
    /// patch for the tracked ones, cut at `patchCap`.
    package static func changes(root: String) -> Changes {
        let inside = git(["-C", root, "rev-parse", "--is-inside-work-tree"])
        guard !inside.timedOut else { return .timedOut }
        guard inside.status == 0 else { return .notARepository }
        let status = git(["-C", root, "status", "--porcelain=v1", "--untracked-files=all"])
        guard !status.timedOut else { return .timedOut }
        // A repository with no commit yet has no HEAD to diff against.
        let hasHead = git(["-C", root, "rev-parse", "--verify", "--quiet", "HEAD"]).status == 0
        let diff = git(["-C", root, "diff"] + (hasHead ? ["HEAD"] : []))
        guard !diff.timedOut else { return .timedOut }
        let truncated = diff.output.count > patchCap
        return .changes(files: parseStatus(status.output),
                        patch: truncated ? String(diff.output.prefix(patchCap)) : diff.output,
                        truncated: truncated)
    }

    /// `git status --porcelain=v1` lines as files; a rename keeps its new path.
    package static func parseStatus(_ output: String) -> [ChangedFile] {
        output.split(separator: "\n").compactMap { line in
            guard line.count > 3 else { return nil }
            let status = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            return ChangedFile(status: status, path: path.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
    }

    // MARK: - A file the agent names

    package struct Entry: Equatable {
        package let name: String
        package let isDirectory: Bool
    }

    package enum FileRead: Equatable {
        case text(String)
        case directory([Entry])
        /// Leaves the project, `..` or a symlink included, or names `.git`.
        case outside
        /// Git ignores it: an env file, a key, a build product.
        case ignored
        case missing
        case tooLarge(bytes: Int)
        case binary
    }

    /// `relative`, resolved inside `root` — symlinks followed before the check,
    /// so a link pointing out of the project is refused like a `..` is.
    package static func read(root: URL, relative: String) -> FileRead {
        guard let url = resolve(root: root, relative: relative) else { return .outside }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else {
            return .missing
        }
        if isIgnored(root: root, path: url) { return .ignored }
        return isDirectory.boolValue ? listing(url) : contents(url)
    }

    /// The file `relative` names, or nil when it is not inside `root`. An
    /// absolute path — what an agent's tool call carries — is taken as is and
    /// held to the same check.
    package static func resolve(root: URL, relative: String) -> URL? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let named = relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : base.appending(path: relative)
        let target = named.standardizedFileURL.resolvingSymlinksInPath()
        let basePath = base.path(percentEncoded: false).trimmingSuffix("/")
        let targetPath = target.path(percentEncoded: false).trimmingSuffix("/")
        guard targetPath == basePath || targetPath.hasPrefix(basePath + "/") else { return nil }
        let inside = targetPath.dropFirst(basePath.count).split(separator: "/")
        guard !inside.contains(".git") else { return nil }
        return target
    }

    private static func listing(_ url: URL) -> FileRead {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        let entries = names.filter { $0 != ".git" }.sorted().map { name -> Entry in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appending(path: name).path(percentEncoded: false), isDirectory: &isDirectory)
            return Entry(name: name, isDirectory: isDirectory.boolValue)
        }
        return .directory(entries)
    }

    private static func contents(_ url: URL) -> FileRead {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= fileCap else { return .tooLarge(bytes: size) }
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
        return .text(text)
    }

    private static func isIgnored(root: URL, path: URL) -> Bool {
        git(["-C", root.path(percentEncoded: false), "check-ignore", "--quiet", path.path(percentEncoded: false)]).status == 0
    }

    private static func git(_ arguments: [String]) -> (status: Int32, output: String, timedOut: Bool) {
        SubprocessOutput.runWithDeadline(executable: "/usr/bin/git", arguments: arguments,
                                         timeout: gitTimeout, discardStandardError: true)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) && count > suffix.count ? String(dropLast(suffix.count)) : self
    }
}
