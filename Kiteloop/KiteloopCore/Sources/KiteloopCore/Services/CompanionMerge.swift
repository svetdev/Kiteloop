import Foundation

/// The companions' half of one merge gate (ADR-0005): each companion's branch
/// merged into a scratch worktree nested in the project's own scratch one, so
/// the single `verify:` sees every repository as merged, and then landed —
/// every companion, all or nothing, before the project's own ref moves.
///
/// `prepare` moves no ref. `land` moves them one at a time and puts back the
/// ones already moved the moment one refuses. `rollback` is for the caller
/// whose own repository — the project, last — then fails to land.
package struct CompanionMerge: Sendable {
    /// How one companion's verified merge reaches its base.
    package enum Landing: Equatable, Sendable {
        /// The item changed nothing here: the base's tree is checked out for
        /// the verify to see, and there is nothing to land.
        case nothing
        /// The base is a branch nothing has checked out: its ref moves, by
        /// compare-and-swap against the tip the merge was built on.
        case updateRef(base: String, old: String)
        /// The companion's own checkout is on the base: it is fast-forwarded.
        case fastForward(old: String)
    }

    package struct Entry: Equatable, Sendable {
        package let name: String
        package let root: URL
        package let scratch: URL
        package let landing: Landing
        /// The merge commit made in the scratch worktree; nil for `.nothing`.
        package let mergeSHA: String?
    }

    /// One repository's landed merge, for the item's notes.
    package struct Landed: Equatable, Sendable {
        package let name: String
        package let commit: String
        /// The named base, or nil for the companion checkout's own branch.
        package let base: String?

        package init(name: String, commit: String, base: String?) {
            self.name = name
            self.commit = commit
            self.base = base
        }
    }

    package let entries: [Entry]
    let itemID: String

    private typealias Git = CompanionCheckouts

    // MARK: - Prepare

    /// Builds every companion's merged tree under `scratch`, the project's
    /// scratch worktree. `.failure` carries the reason, naming the repository,
    /// with nothing left behind.
    package static func prepare(
        _ companions: [CompanionRepo], itemID: String, message: String, projectRoot: URL, scratch: URL
    ) -> Result<CompanionMerge, Refusal> {
        var entries: [Entry] = []
        for companion in companions {
            switch prepareOne(companion, itemID: itemID, message: message,
                              projectRoot: projectRoot, scratch: scratch) {
            case .success(let entry):
                entries.append(entry)
            case .failure(let refusal):
                removeScratch(companions, projectRoot: projectRoot, scratch: scratch)
                return .failure(refusal)
            }
        }
        return .success(CompanionMerge(entries: entries, itemID: itemID))
    }

    package struct Refusal: Error, Equatable, Sendable {
        package let reason: String
    }

    private static func prepareOne(
        _ companion: CompanionRepo, itemID: String, message: String, projectRoot: URL, scratch: URL
    ) -> Result<Entry, Refusal> {
        let root = companion.root(projectRoot: projectRoot)
        let nested = companion.checkout(in: scratch)
        let landing: Landing
        switch checkOutBase(companion, root: root, nested: nested) {
        case .success(let settled): landing = settled
        case .failure(let refusal): return .failure(refusal)
        }
        guard Git.hasWork(companion, itemID: itemID, projectRoot: projectRoot) else {
            return .success(Entry(name: companion.name, root: root, scratch: nested, landing: .nothing, mergeSHA: nil))
        }
        if let refusal = mergeRefusal(companion, itemID: itemID, message: message, root: root,
                                      nested: nested, landing: landing) {
            return refuse(refusal)
        }
        let merged = Git.ask(["rev-parse", "HEAD"], in: nested)
        guard merged.ok, !merged.text.isEmpty else {
            return refuse("companion \(companion.name): could not read the merge commit")
        }
        return .success(Entry(name: companion.name, root: root, scratch: nested,
                              landing: landing, mergeSHA: merged.text))
    }

    /// Settles where the companion's merge would land and checks its base out,
    /// detached, at `nested`.
    private static func checkOutBase(
        _ companion: CompanionRepo, root: URL, nested: URL
    ) -> Result<Landing, Refusal> {
        guard Git.isRepository(root) else {
            return refuse("companion \(companion.name) at \(root.path(percentEncoded: false)) is not a git repository")
        }
        Git.run(["worktree", "prune"], in: root)
        let settled = landing(for: companion, root: root)
        guard case .success(let landing) = settled else { return settled }
        try? FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        let added = Git.run(["worktree", "add", "--detach", nested.path(percentEncoded: false),
                             landing.startSHA], in: root)
        guard added.ok else {
            return refuse("companion \(companion.name): could not create a scratch worktree to merge into: \(added.said)")
        }
        return settled
    }

    /// Why the item's branch cannot be merged at `nested`: the companion's own
    /// checkout holds changes the fast-forward would write over, or the merge
    /// conflicts. Nil when the merge is made.
    private static func mergeRefusal(
        _ companion: CompanionRepo, itemID: String, message: String, root: URL, nested: URL, landing: Landing
    ) -> String? {
        if case .fastForward(let start) = landing,
           let overlap = overlapRefusal(companion, itemID: itemID, root: root, start: start) {
            return overlap
        }
        return mergeConflict(companion, itemID: itemID, message: message, nested: nested)
    }

    private static func refuse<T>(_ reason: String) -> Result<T, Refusal> { .failure(Refusal(reason: reason)) }

    /// Where this companion's merge would land, settled before anything is
    /// built so the tip the merge starts from is the one the landing is later
    /// compared against.
    private static func landing(for companion: CompanionRepo, root: URL) -> Result<Landing, Refusal> {
        let current = Git.ask(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root).text
        guard let base = companion.baseBranch, base != current else {
            let head = Git.ask(["rev-parse", "HEAD"], in: root)
            guard head.ok, !head.text.isEmpty else {
                return refuse("companion \(companion.name): could not read its checkout's HEAD")
            }
            return .success(.fastForward(old: head.text))
        }
        if let holder = worktreeHolding(base, root: root) {
            return refuse("base branch \(base) of companion \(companion.name) is checked out at \(holder); "
                          + "merge there or remove that worktree")
        }
        let tip = Git.ask(["rev-parse", "--verify", "--quiet", "refs/heads/\(base)"], in: root)
        guard tip.ok, !tip.text.isEmpty else {
            return refuse("base branch \(base) does not exist in companion \(companion.name)")
        }
        return .success(.updateRef(base: base, old: tip.text))
    }

    /// The path of a worktree of `root`'s repository that has `branch` checked
    /// out; nil when none has.
    private static func worktreeHolding(_ branch: String, root: URL) -> String? {
        let list = SubprocessOutput.git(["-C", root.path(percentEncoded: false), "worktree", "list", "--porcelain"])
        guard list.status == 0 else { return nil }
        for block in list.output.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard lines.contains("branch refs/heads/\(branch)"),
                  let header = lines.first(where: { $0.hasPrefix("worktree ") }) else { continue }
            return String(header.dropFirst("worktree ".count))
        }
        return nil
    }

    /// A fast-forward writes the companion's own checkout, so a file changed
    /// there and by the merge is refused up front, by name.
    private static func overlapRefusal(
        _ companion: CompanionRepo, itemID: String, root: URL, start: String
    ) -> String? {
        let status = SubprocessOutput.git(["-C", root.path(percentEncoded: false), "status", "--porcelain"])
        let dirty = Set(status.output.split(whereSeparator: \.isNewline).map { line -> String in
            let path = String(line.dropFirst(3))
            return path.components(separatedBy: " -> ").last ?? path
        })
        guard !dirty.isEmpty else { return nil }
        let incoming = Git.ask(["diff", "--name-only", "\(start)...\(Git.branchRef(itemID))"], in: root).text
            .split(whereSeparator: \.isNewline).map(String.init)
        let overlap = incoming.filter(dirty.contains).sorted()
        guard !overlap.isEmpty else { return nil }
        return "companion \(companion.name)'s checkout has uncommitted changes to files the merge touches: "
            + overlap.prefix(5).joined(separator: ", ")
    }

    /// Merges the item's branch into the nested scratch worktree. Nil when it
    /// merged; the refusal, with the merge rolled back, when it conflicted.
    private static func mergeConflict(
        _ companion: CompanionRepo, itemID: String, message: String, nested: URL
    ) -> String? {
        let merge = Git.run(["merge", "--no-ff", "-m", message, Git.branchName(for: itemID)], in: nested)
        guard !merge.ok else { return nil }
        let conflicted = Git.ask(["diff", "--name-only", "--diff-filter=U"], in: nested).text
            .split(whereSeparator: \.isNewline).map(String.init)
        Git.run(["merge", "--abort"], in: nested)
        let base = companion.baseBranch ?? "its checkout's branch"
        guard !conflicted.isEmpty else {
            return "companion \(companion.name): \(Git.branchName(for: itemID)) could not be merged into \(base): \(merge.said)"
        }
        return "companion \(companion.name): \(Git.branchName(for: itemID)) no longer merges into \(base) — "
            + "conflicts in \(conflicted.prefix(5).joined(separator: ", "))"
    }

    // MARK: - Land

    package enum Outcome: Equatable, Sendable {
        case landed([Landed])
        /// One repository refused; every one moved before it has been put back.
        case refused(String)
    }

    /// Moves every companion onto its verified merge. The first refusal puts
    /// back the ones already moved and is the answer.
    package func land() -> Outcome {
        var moved: [Entry] = []
        for entry in entries {
            guard let refusal = Self.move(entry) else {
                moved.append(entry)
                continue
            }
            let stuck = Self.putBack(moved)
            let suffix = stuck.isEmpty ? "" : " — and could not put back \(stuck.joined(separator: ", ")), "
                + "which now holds the merge on its own"
            return .refused("could not land companion \(entry.name): \(refusal); nothing was landed\(suffix)")
        }
        return .landed(landed)
    }

    /// What landing put where, for the entries that had anything to land.
    package var landed: [Landed] {
        entries.compactMap { entry in
            guard let commit = entry.mergeSHA else { return nil }
            switch entry.landing {
            case .nothing: return nil
            case .updateRef(let base, _): return Landed(name: entry.name, commit: commit, base: base)
            case .fastForward: return Landed(name: entry.name, commit: commit, base: nil)
            }
        }
    }

    /// Puts every companion back where it was before `land` — for the caller
    /// whose own repository then refused. Returns the names that could not be
    /// put back; empty when every one was.
    @discardableResult
    package func rollback() -> [String] {
        Self.putBack(entries)
    }

    /// Nil when the entry is on its merge; git's refusal otherwise.
    private static func move(_ entry: Entry) -> String? {
        guard let merge = entry.mergeSHA else { return nil }
        switch entry.landing {
        case .nothing:
            return nil
        case .updateRef(let base, let old):
            let update = Git.run(["update-ref", "-m", "kiteloop: merged", "refs/heads/\(base)", merge, old], in: entry.root)
            return update.ok ? nil : "its base \(base) moved from \(old.prefix(7)) while the merge was verified: \(update.said)"
        case .fastForward:
            let forward = Git.run(["merge", "--ff-only", merge], in: entry.root)
            return forward.ok ? nil : "its checkout would not fast-forward: \(forward.said)"
        }
    }

    /// Undoes `move`, last moved first, each only if the repository is still
    /// exactly where `move` left it — a ref or a checkout someone has moved
    /// since is theirs, and is reported rather than overwritten.
    private static func putBack(_ moved: [Entry]) -> [String] {
        Array(moved.reversed().filter { !isPutBack($0) }.map(\.name).reversed())
    }

    /// Whether `entry` is back where it was before `move` — true as well for
    /// one that never moved.
    private static func isPutBack(_ entry: Entry) -> Bool {
        guard let merge = entry.mergeSHA else { return true }
        switch entry.landing {
        case .nothing:
            return true
        case .updateRef(let base, let old):
            return Git.run(["update-ref", "-m", "kiteloop: landing undone", "refs/heads/\(base)", old, merge],
                           in: entry.root).ok
        case .fastForward(let old):
            guard Git.ask(["rev-parse", "HEAD"], in: entry.root).text == merge else { return false }
            return Git.run(["reset", "--keep", old], in: entry.root).ok
        }
    }

    // MARK: - After

    /// Once everything has landed, each companion's item branch is entirely
    /// inside its base and the ref is all that is left of it. Removed — never
    /// one whose tip the base cannot reach.
    package func removeLandedBranches() {
        for entry in entries where entry.mergeSHA != nil {
            let branch = Git.branchRef(itemID)
            let target: String
            switch entry.landing {
            case .nothing: continue
            case .updateRef(let base, _): target = "refs/heads/\(base)"
            case .fastForward: target = "HEAD"
            }
            guard Git.ask(["merge-base", "--is-ancestor", branch, target], in: entry.root).ok else { continue }
            Git.run(["branch", "-D", Git.branchName(for: itemID)], in: entry.root)
        }
    }

    /// Removes every companion's scratch worktree nested in `scratch` — before
    /// the project's scratch worktree itself is removed, so no companion is
    /// left registering a checkout that is gone.
    package static func removeScratch(_ companions: [CompanionRepo], projectRoot: URL, scratch: URL) {
        for companion in companions {
            let root = companion.root(projectRoot: projectRoot)
            let nested = companion.checkout(in: scratch)
            Git.run(["worktree", "remove", "--force", nested.path(percentEncoded: false)], in: root)
            if FileManager.default.fileExists(atPath: nested.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: nested)
            }
            Git.run(["worktree", "prune"], in: root)
        }
    }
}

extension CompanionMerge.Landing {
    /// The commit the scratch worktree is checked out at — the base's tip.
    var startSHA: String {
        switch self {
        case .nothing: return ""
        case .updateRef(_, let old), .fastForward(let old): return old
        }
    }
}
