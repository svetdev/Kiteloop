import Foundation

/// The git side of a run that spans companion repositories (ADR-0005): each
/// companion's `kiteloop/<item-id>` branch, checked out under the run's own
/// worktree at `.kiteloop/repos/<name>`, from creation to teardown, and what
/// that branch holds.
///
/// Everything here is synchronous git against real repositories, so it blocks:
/// call it off the main actor. Nothing here fetches or pushes.
package enum CompanionCheckouts {
    static let gitTimeout: TimeInterval = 300

    package static func branchName(for itemID: String) -> String { "kiteloop/\(itemID)" }

    // MARK: - Git

    /// git's stdout alone, trimmed — for an answer that is parsed.
    static func ask(_ arguments: [String], in directory: URL) -> (ok: Bool, text: String) {
        let result = SubprocessOutput.git(["-C", directory.path(percentEncoded: false)] + arguments)
        return (result.status == 0, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// git with a deadline and its stderr kept — for a command whose refusal
    /// is the thing to report.
    @discardableResult
    static func run(_ arguments: [String], in directory: URL) -> (ok: Bool, said: String) {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/usr/bin/git",
            arguments: ["-C", directory.path(percentEncoded: false)] + arguments,
            timeout: gitTimeout)
        return (result.status == 0, oneLine(result.output))
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func isRepository(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            && ask(["rev-parse", "--is-inside-work-tree"], in: url).ok
    }

    /// What a companion's runs fork from and are judged against: its named
    /// base, else whatever its own checkout is on.
    static func baseRef(_ companion: CompanionRepo) -> String {
        companion.baseBranch.map { "refs/heads/\($0)" } ?? "HEAD"
    }

    static func branchRef(_ itemID: String) -> String { "refs/heads/\(branchName(for: itemID))" }

    // MARK: - Setup

    /// Makes every companion's branch and worktree for one item inside `tree`,
    /// the run's own worktree. Nil when all of them stand; otherwise why not,
    /// with whatever was made already taken away again — a run either has all
    /// of its repositories or does not start.
    package static func create(
        _ companions: [CompanionRepo], itemID: String, projectRoot: URL, in tree: URL
    ) -> String? {
        guard !companions.isEmpty else { return nil }
        if let first = companions.first,
           !ask(["check-ignore", "-q", first.relativePath], in: tree).ok {
            return "the project does not ignore \(CompanionRepo.directory)/ — a companion's worktree "
                + "would be committed into it; add `.kiteloop/` to its .gitignore"
        }
        var made: [CompanionRepo] = []
        for companion in companions {
            if let reason = createOne(companion, itemID: itemID, projectRoot: projectRoot, in: tree) {
                for undone in made {
                    discard(undone, itemID: itemID, projectRoot: projectRoot, in: tree)
                }
                return reason
            }
            made.append(companion)
        }
        return nil
    }

    private static func createOne(
        _ companion: CompanionRepo, itemID: String, projectRoot: URL, in tree: URL
    ) -> String? {
        let root = companion.root(projectRoot: projectRoot)
        guard isRepository(root) else {
            return "companion \(companion.name) at \(root.path(percentEncoded: false)) is not a git repository"
        }
        if let base = companion.baseBranch,
           !ask(["rev-parse", "--verify", "--quiet", "refs/heads/\(base)"], in: root).ok {
            return "base branch \(base) does not exist in companion \(companion.name)"
        }
        run(["worktree", "prune"], in: root)
        if let refusal = clearPreviousBranch(companion, itemID: itemID, root: root) { return refusal }

        let checkout = companion.checkout(in: tree)
        try? FileManager.default.createDirectory(
            at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let added = run(["worktree", "add", "-b", branchName(for: itemID),
                         checkout.path(percentEncoded: false), baseRef(companion)], in: root)
        guard added.ok else {
            return "companion \(companion.name): could not create its worktree: \(added.said)"
        }
        return nil
    }

    /// A previous run of this item left its branch in the companion. Its tip is
    /// kept under a backup ref when the base cannot reach it, then the branch
    /// goes so `worktree add -b` can make a fresh one. Nil when the way is
    /// clear; git's refusal otherwise.
    private static func clearPreviousBranch(_ companion: CompanionRepo, itemID: String, root: URL) -> String? {
        let tip = ask(["rev-parse", "--verify", "--quiet", branchRef(itemID)], in: root)
        guard tip.ok, !tip.text.isEmpty else { return nil }
        if !ask(["merge-base", "--is-ancestor", tip.text, baseRef(companion)], in: root).ok {
            run(["update-ref", backupRef(itemID: itemID, tip: tip.text), tip.text], in: root)
        }
        let deleted = run(["branch", "-D", branchName(for: itemID)], in: root)
        guard deleted.ok else {
            return "branch \(branchName(for: itemID)) in companion \(companion.name) "
                + "could not be deleted: \(deleted.said)"
        }
        return nil
    }

    /// Where an unmerged tip is kept before its branch is replaced — the same
    /// shape the project's own repository uses.
    package static func backupRef(itemID: String, tip: String) -> String {
        "refs/kiteloop/backup/\(itemID)/\(tip)"
    }

    /// Takes away a worktree and branch `create` made in this same call — only
    /// ever a fresh, empty branch, so nothing is lost.
    private static func discard(_ companion: CompanionRepo, itemID: String, projectRoot: URL, in tree: URL) {
        let root = companion.root(projectRoot: projectRoot)
        run(["worktree", "remove", "--force", companion.checkout(in: tree).path(percentEncoded: false)], in: root)
        run(["branch", "-D", branchName(for: itemID)], in: root)
    }

    // MARK: - Teardown

    /// What a finished run left in its companions.
    package struct Finished: Equatable, Sendable {
        /// Companions whose loose changes teardown committed for the worker.
        package var committedByTeardown: [String] = []
        /// Companions whose branch is ahead of its base — the ones the run
        /// actually changed.
        package var withWork: [String] = []

        package init(committedByTeardown: [String] = [], withWork: [String] = []) {
            self.committedByTeardown = committedByTeardown
            self.withWork = withWork
        }
    }

    /// Commits whatever each companion's worktree holds uncommitted and says
    /// which branches carry work. Unless `keepCheckouts`, the worktrees are
    /// then removed, and a branch with nothing on it goes with its worktree —
    /// never one that is ahead of its base.
    @discardableResult
    package static func finish(
        _ companions: [CompanionRepo], itemID: String, projectRoot: URL, in tree: URL,
        message: String, keepCheckouts: Bool
    ) -> Finished {
        var finished = Finished()
        for companion in companions {
            let root = companion.root(projectRoot: projectRoot)
            let checkout = companion.checkout(in: tree)
            if commitLooseWork(in: checkout, message: message) {
                finished.committedByTeardown.append(companion.name)
            }
            let worked = hasWork(companion, itemID: itemID, projectRoot: projectRoot)
            if worked { finished.withWork.append(companion.name) }
            guard !keepCheckouts else { continue }
            run(["worktree", "remove", "--force", checkout.path(percentEncoded: false)], in: root)
            run(["worktree", "prune"], in: root)
            if !worked { run(["branch", "-D", branchName(for: itemID)], in: root) }
        }
        return finished
    }

    /// Stages and commits everything loose in `checkout`. True when a commit
    /// was made; false for a clean tree, or a directory that is not there.
    ///
    /// The worktree is removed by force straight after this, so a commit the
    /// repository refuses — a pre-commit hook that fails, signing with no key
    /// to hand, no identity configured — would take the only copy of the
    /// work with it. The commit is made again without any of the three: this
    /// is a recovery commit on the run's own branch, never one on a base.
    static func commitLooseWork(in checkout: URL, message: String) -> Bool {
        guard FileManager.default.fileExists(atPath: checkout.appending(path: ".git").path(percentEncoded: false))
        else { return false }
        let status = ask(["status", "--porcelain"], in: checkout)
        guard status.ok, !status.text.isEmpty else { return false }
        run(["add", "-A"], in: checkout)
        if run(["commit", "-m", message], in: checkout).ok { return true }
        return run(recoveryIdentity + ["commit", "--no-verify", "-m", message], in: checkout).ok
    }

    /// What a recovery commit is made as when the repository's own
    /// configuration refused one.
    static let recoveryIdentity = [
        "-c", "user.name=Kiteloop", "-c", "user.email=kiteloop@localhost", "-c", "commit.gpgsign=false",
    ]

    /// Before a run's tree is deleted by anything — a restart of the item, a
    /// sweep — commits what every companion worktree nested in it holds loose
    /// and unregisters it, so removing the directory removes no work and
    /// leaves no branch held by a checkout that is gone. Reads the nested
    /// worktrees themselves, so it needs no config and is a no-op for a tree
    /// with none. Returns the names it committed for.
    @discardableResult
    package static func recoverAndRemoveAll(in tree: URL, message: String) -> [String] {
        let fm = FileManager.default
        let holder = tree.appending(path: CompanionRepo.directory)
        guard let names = try? fm.contentsOfDirectory(atPath: holder.path(percentEncoded: false)) else { return [] }
        var recovered: [String] = []
        for name in names.sorted() {
            let checkout = holder.appending(path: name)
            guard fm.fileExists(atPath: checkout.appending(path: ".git").path(percentEncoded: false)) else { continue }
            if commitLooseWork(in: checkout, message: message) { recovered.append(name) }
            let common = ask(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: checkout)
            guard common.ok, !common.text.isEmpty else { continue }
            _ = SubprocessOutput.runWithDeadline(
                executable: "/usr/bin/git",
                arguments: ["--git-dir", common.text, "worktree", "remove", "--force",
                            checkout.path(percentEncoded: false)],
                timeout: gitTimeout)
        }
        return recovered
    }

    // MARK: - What a branch holds

    /// Whether the item's branch in `companion` exists and is ahead of its
    /// base. An answer git could not give reads as work: an unreadable
    /// repository must not license a deletion.
    package static func hasWork(_ companion: CompanionRepo, itemID: String, projectRoot: URL) -> Bool {
        let root = companion.root(projectRoot: projectRoot)
        guard ask(["rev-parse", "--verify", "--quiet", branchRef(itemID)], in: root).ok else { return false }
        let count = ask(["rev-list", "--count", branchRef(itemID), "--not", baseRef(companion)], in: root)
        guard count.ok, let ahead = Int(count.text) else { return true }
        return ahead > 0
    }

    /// Whether a run still in flight has changed anything in a companion: a
    /// commit on its branch, or a loose change in its worktree under `tree`.
    package static func inFlightWork(
        _ companions: [CompanionRepo], itemID: String, projectRoot: URL, in tree: URL
    ) -> Bool {
        companions.contains { companion in
            if hasWork(companion, itemID: itemID, projectRoot: projectRoot) { return true }
            let status = ask(["status", "--porcelain"], in: companion.checkout(in: tree))
            return status.ok && !status.text.isEmpty
        }
    }

    /// What the worker and the reviewer are told about the repositories the
    /// item spans, beside the project's own.
    package static func promptNote(_ companions: [CompanionRepo], itemID: String) -> String? {
        guard !companions.isEmpty else { return nil }
        let lines = companions.map { "- `\($0.relativePath)` — the \($0.name) repository" }
        return """
            This item spans more than one repository. Besides this worktree, each of these is a \
            worktree of another repository, on its own `\(branchName(for: itemID))` branch:
            \(lines.joined(separator: "\n"))
            Edit those repositories only through these paths. Each is a separate git repository: \
            run `git -C <path> status` and `git -C <path> diff` there, and commit there separately. \
            The verify commands run once, from this worktree, and see all of them.
            """
    }

    package static func withWork(
        _ companions: [CompanionRepo], itemID: String, projectRoot: URL
    ) -> [CompanionRepo] {
        companions.filter { hasWork($0, itemID: itemID, projectRoot: projectRoot) }
    }

    /// One companion's part of a run's diff.
    package struct RepoDiff: Equatable, Sendable {
        package let name: String
        package let branch: String
        package let stat: String
        package let patch: String
        /// Paths as the repository names them.
        package let files: [String]

        package init(name: String, branch: String, stat: String, patch: String, files: [String]) {
            self.name = name
            self.branch = branch
            self.stat = stat
            self.patch = patch
            self.files = files
        }
    }

    /// Each companion's diff against its own merge base, for those whose
    /// branch exists — what the reviewer and the person at the gate read
    /// beside the project's own diff.
    package static func diffs(
        _ companions: [CompanionRepo], itemID: String, projectRoot: URL
    ) -> [RepoDiff] {
        companions.compactMap { companion in
            let root = companion.root(projectRoot: projectRoot)
            guard ask(["rev-parse", "--verify", "--quiet", branchRef(itemID)], in: root).ok else { return nil }
            let range = "\(baseRef(companion))...\(branchRef(itemID))"
            let files = ask(["diff", "--name-only", range], in: root).text
                .split(whereSeparator: \.isNewline).map(String.init)
            let stat = SubprocessOutput.git(["-C", root.path(percentEncoded: false), "diff", "--stat", range]).output
            let patch = SubprocessOutput.git(["-C", root.path(percentEncoded: false), "diff", range]).output
            return RepoDiff(name: companion.name, branch: branchName(for: itemID),
                            stat: stat, patch: patch, files: files)
        }
    }

    /// Every path the run changed in its companions, each as it is reached
    /// from the project's tree — `.kiteloop/repos/<name>/<path>`. Nil when a
    /// companion's branch is there and git could not say what it changed:
    /// that is not "nothing changed", and a reader choosing what to verify
    /// by these paths must be able to tell the two apart.
    package static func changedFiles(
        _ companions: [CompanionRepo], itemID: String, projectRoot: URL
    ) -> [String]? {
        var paths: [String] = []
        for companion in companions {
            let root = companion.root(projectRoot: projectRoot)
            guard ask(["rev-parse", "--verify", "--quiet", branchRef(itemID)], in: root).ok else { continue }
            let names = ask(["diff", "--name-only", "\(baseRef(companion))...\(branchRef(itemID))"], in: root)
            guard names.ok else { return nil }
            paths += names.text.split(whereSeparator: \.isNewline).map { "\(companion.relativePath)/\($0)" }
        }
        return paths
    }

    /// The paths a merge is verified by: the project's own and its
    /// companions'. Nil — every rule runs — when either could not be read.
    package static func verifyPaths(project: [String]?, companions: [String]?) -> [String]? {
        guard let project, let companions else { return nil }
        return project + companions
    }

    /// The project's part of a diff and its companions' as one text of at
    /// most `limit` characters. A diff too long for it is cut in both parts
    /// rather than at the end, where the companions are: the project's keeps
    /// at least half, and the companions' whatever the project's leaves.
    package static func fitted(own: String, companions: String, limit: Int) -> (text: String, truncated: Bool) {
        let whole = [own, companions].filter { !$0.isEmpty }.joined(separator: "\n")
        guard whole.count > limit else { return (whole, false) }
        guard !companions.isEmpty else { return (String(own.prefix(limit)), true) }
        let ownShare = max(limit / 2, limit - companions.count - 1)
        let kept = String(own.prefix(ownShare))
        return (kept + "\n" + companions.prefix(max(0, limit - kept.count - 1)), true)
    }

    /// The companion diffs as one text under a heading per repository, for a
    /// reader given a single patch.
    package static func combined(_ diffs: [RepoDiff], _ part: KeyPath<RepoDiff, String>) -> String {
        diffs.filter { !$0[keyPath: part].isEmpty }
            .map { "=== \($0.name) (\(CompanionRepo.directory)/\($0.name), branch \($0.branch)) ===\n\($0[keyPath: part])" }
            .joined(separator: "\n")
    }
}

/// The grounding check's reading of companion repositories (ADR-0005).
extension GroundingCheck.Sources {
    /// What stands in a draft's words for "this item names the companion
    /// `name` in `repos:`" — not a word prose can hold, so a companion is
    /// in scope only for an item that opted into it.
    static func companionMarker(_ name: String) -> String { "repos:\(name)" }

    /// The project's companion repositories, one corpus each, in scope
    /// only for an item whose `repos:` names it. A path is read from the
    /// companion's root, as its own files are cited, or from where the
    /// run reaches it — `.kiteloop/repos/<name>/…`.
    package static func companionCorpora(_ companions: [CompanionRepo], root: URL) -> [GroundingCheck.Corpus] {
        companions.map { companion in
            let tree = companion.root(projectRoot: root)
            let prefix = companion.relativePath + "/"
            return GroundingCheck.Corpus(name: "the \(companion.name) companion",
                          namedBy: [companionMarker(companion.name)]) { cited in
                var relative = GroundingCheck.SourceIndex.normalize(cited)
                // The companion's own folder in the run's tree is the
                // companion: "run the tests in `.kiteloop/repos/library`".
                if relative == companion.relativePath {
                    return FileManager.default.fileExists(atPath: tree.path(percentEncoded: false))
                }
                if relative.hasPrefix(prefix) { relative = String(relative.dropFirst(prefix.count)) }
                guard !relative.isEmpty else { return false }
                return FileManager.default.fileExists(
                    atPath: tree.appending(path: relative).path(percentEncoded: false))
            }
        }
    }
}
