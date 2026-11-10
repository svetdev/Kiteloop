import Foundation
import os
import KiteloopCore

struct SandboxConfig: Codable, Sendable {
    var useWorktree: Bool
    var branchPrefix: String

    static let `default` = SandboxConfig(useWorktree: false, branchPrefix: "kiteloop")
}

/// A verify failure whose cause isn't necessarily the diff — a crashed test
/// binary, a lock some other run held, or a test that fails alone under a
/// parallel run and passes on its own — each one worth one retry on the same
/// merged tree before the gate calls it a refusal. A failure that matches none
/// of these is refused on the first attempt, exactly as before.
enum VerifyFailureClass: Equatable, Sendable {
    case crash(signal: String)
    case lockTimeout
    case testFailure(name: String)

    /// How the class reads once the retry cleared it. Not a refusal — the
    /// merge goes through — so this says "then passed" rather than anything a
    /// red merge would.
    var recoveredNote: String {
        switch self {
        case .crash(let signal): return "crashed (\(signal)) then passed"
        case .lockTimeout: return "lock timeout then passed"
        case .testFailure(let name): return "flaky: \(name) failed then passed"
        }
    }

    /// How the class reads when the retry failed the same way. This is the
    /// refusal, so "twice" is the word that says a second chance was already
    /// spent. A test that failed on both attempts is not called flaky: a
    /// failure that reproduces is the work being red, and on 2026-09-12 that
    /// word sent 24 refusals to the approval queue reading as chance.
    var refusedTwiceNote: String {
        switch self {
        case .crash(let signal): return "crashed twice (\(signal))"
        case .lockTimeout: return "lock timeout twice"
        case .testFailure(let name): return "\(name) failed on both attempts"
        }
    }
}

protocol WorktreeManaging: Sendable {
    func create(for agentID: String, baseBranch: String?) async throws -> URL
    func destroy(for agentID: String) async throws
    func worktreePath(for agentID: String) async -> URL?
    func exists(for agentID: String) async -> Bool
}

/// Serializes `WorktreeManager.mergeAndVerify` per project, keyed by the
/// project's root path. Nothing else does: the autopilot's own auto-merge
/// after a review, the approval endpoint's merge, and a merge from the item's
/// detail view each build their own `WorktreeManager` instance, so the
/// actor's own isolation — one call through a given instance at a time —
/// never serializes them against each other. Without this, two gates on one
/// project can build their scratch merges from the same tip and race to land,
/// which is exactly the race `mergeAndVerify`'s base-moved retry exists to
/// recover from once but must not have to recover from twice at once.
private actor MergeGateLock {
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Takes `key` if it is free, without ever suspending. `false` means
    /// somebody else holds it and the caller has to `acquire` and wait — the
    /// one moment at which a merge can tell that it is about to queue behind
    /// another rather than start, which is what makes the wait sayable.
    func tryAcquire(_ key: String) -> Bool {
        guard !held.contains(key) else { return false }
        held.insert(key)
        return true
    }

    /// Waits until nobody else holds `key`, then takes it. Every `acquire`
    /// (or successful `tryAcquire`) must be matched by exactly one `release`
    /// of the same key, whatever the caller's merge turns out to do.
    func acquire(_ key: String) async {
        guard held.contains(key) else {
            held.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    /// Hands `key` straight to the next waiter in line, if there is one, so
    /// its scratch merge starts from whatever this release just landed —
    /// or frees the key for the next `acquire` to take cold.
    func release(_ key: String) {
        guard var queue = waiters[key], !queue.isEmpty else {
            held.remove(key)
            return
        }
        let next = queue.removeFirst()
        waiters[key] = queue.isEmpty ? nil : queue
        next.resume()
    }
}

actor WorktreeManager: WorktreeManaging {
    /// Which merge gate a manager takes. Every manager the app builds takes
    /// `.shared` — the one process-wide lock is the whole point of
    /// `MergeGateLock`, since the racing gates are on *different* manager
    /// instances. `.unshared` hands this manager a lock nobody else holds,
    /// which serializes it against nothing: it exists so a test can run the
    /// same race with the gate effectively removed and watch the assertion
    /// that the gate buys go red.
    enum MergeGateSharing: Sendable {
        case shared
        case unshared
    }

    /// What a merge that had to queue behind another on the same project tells
    /// its caller, so the wait is visible while it lasts instead of reading as
    /// a merge already under way. `waiting` is sent only when the gate is held
    /// by somebody else, and `acquired` always follows it once this merge holds
    /// the gate; a merge that never waits sends neither.
    enum MergeGateWait: Sendable, Equatable {
        case waiting
        case acquired
    }

    private let projectRoot: URL
    private let worktreesDir: URL
    private var activeWorktrees: [String: URL] = [:]
    private let gitTimeout: TimeInterval
    /// Shared by every instance — see `MergeGateLock`.
    private static let mergeGateLock = MergeGateLock()
    /// This manager's gate: `Self.mergeGateLock` unless a test asked for one of
    /// its own. See `MergeGateSharing`.
    private let mergeGate: MergeGateLock

    /// Generous for a `worktree add` on a large repository — the operation that
    /// takes the longest on this path when git is actually making progress.
    static let defaultGitTimeout: TimeInterval = 300

    init(projectRoot: URL, gitTimeout: TimeInterval = defaultGitTimeout,
         mergeGate: MergeGateSharing = .shared) {
        self.projectRoot = projectRoot
        self.worktreesDir = WorktreeSession.worktreesRoot(projectRoot: projectRoot)
        self.gitTimeout = gitTimeout
        self.mergeGate = mergeGate == .shared ? Self.mergeGateLock : MergeGateLock()
    }

    func create(for agentID: String, baseBranch: String? = nil) throws -> URL {
        // A project that isn't a git repository has no worktrees to give. Say so
        // in the error rather than letting `git worktree add` fail generically —
        // the caller (`WorktreeSession.begin`) logs this and falls back to the
        // live tree, and "not a git repository" is the line that explains it.
        guard Self.isGitRepository(at: projectRoot) else {
            throw WorktreeError.notAGitRepository(projectRoot.path(percentEncoded: false))
        }

        let worktreePath = worktreesDir.appending(path: agentID)
        let branchName = "kiteloop/\(agentID)"
        // The full local ref, not the bare name: `worktree add` would otherwise
        // guess a branch that only exists on a remote, and the run would fork
        // from a commit no local branch is on — with a fetch nobody asked for.
        let base = baseBranch.map { "refs/heads/\($0)" } ?? "HEAD"

        let fm = FileManager.default
        if !fm.fileExists(atPath: worktreesDir.path(percentEncoded: false)) {
            try fm.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        }
        clearStaleCheckout(at: worktreePath)

        // Through `runGit`, which drains before waiting and hands back what git
        // printed — a refusal ("fatal: a branch named … already exists") is the
        // only thing that says why this item lost its isolation, and it used to
        // be thrown away with the pipe.
        let result = runGit(["worktree", "add", "-b", branchName, worktreePath.path(percentEncoded: false), base])

        guard result.status == 0 else {
            throw WorktreeError.creationFailed(agentID, git: result.output)
        }

        activeWorktrees[agentID] = worktreePath
        return worktreePath
    }

    /// Checks an **existing** branch back out as this item's worktree.
    ///
    /// `create` is for a branch that doesn't exist yet (`git worktree add -b`)
    /// and fails on one that does. This is the other half: a finished item's
    /// teardown removes the directory and keeps the branch, and a run that has
    /// to touch that work again — the CI fix rounds behind `PullRequestChecks` —
    /// needs somewhere to touch it that isn't the live project root.
    ///
    /// The branch is never created and never deleted here: if it isn't there,
    /// `git worktree add` fails and so does this, which is the honest answer
    /// rather than a fresh branch with none of the run's work on it.
    func reopen(for key: String, branch: String) throws -> URL {
        guard Self.isGitRepository(at: projectRoot) else {
            throw WorktreeError.notAGitRepository(projectRoot.path(percentEncoded: false))
        }
        let worktreePath = worktreesDir.appending(path: key)
        let path = worktreePath.path(percentEncoded: false)

        // Anything left at that path — an earlier round, a crashed run — would
        // make `worktree add` refuse. Drop the checkout and any stale
        // registration, never the branch: the branch is the work.
        removeWorktree(for: key, keepBranch: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
        if !fm.fileExists(atPath: worktreesDir.path(percentEncoded: false)) {
            try fm.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        }

        let result = runGit(["worktree", "add", path, branch])
        guard result.status == 0 else {
            throw WorktreeError.creationFailed(key, git: result.output)
        }
        activeWorktrees[key] = worktreePath
        return worktreePath
    }

    /// One rescue's own worktree: `branch` — the item's own, never created or
    /// deleted here — checked out fresh at `key`, with `base`'s tip merged into
    /// it. See `prepareRescueWorktree`.
    struct RescueWorktree: Sendable {
        let path: URL
        /// Non-empty only when the merge attempted here conflicted — the
        /// content a rescue agent has to resolve. Empty means the merge landed
        /// clean, which is the verify-red case: nothing here disagrees, so
        /// what needs fixing is the code, not the merge.
        let conflictedPaths: [String]
    }

    /// Reopens the item's own branch into a fresh worktree keyed `key`
    /// (`reopen`, so the branch is never created or deleted by this) and
    /// merges `base`'s current tip into it — `nil` for the live checkout's own
    /// `HEAD`, a name for that branch's local tip.
    ///
    /// A conflict is left exactly as git leaves it: markers in the files, the
    /// merge in progress, nothing aborted — the state a rescue agent needs to
    /// resolve. A clean merge lands straight through and commits, since a
    /// merge nothing here disagrees with is not what a rescue exists to fix
    /// (see `RescueWorktree.conflictedPaths`).
    func prepareRescueWorktree(key: String, branch: String, base: String?) throws -> RescueWorktree {
        let root = projectRoot.path(percentEncoded: false)
        let mergeRef = base.map { "refs/heads/\($0)" } ?? "HEAD"
        let mergeSHA = runGit(["-C", root, "rev-parse", "--verify", "--quiet", mergeRef]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mergeSHA.isEmpty else {
            throw WorktreeError.creationFailed(key, git: "could not resolve \(mergeRef) to rescue against")
        }

        let path = try reopen(for: key, branch: branch)
        let pathString = path.path(percentEncoded: false)
        let merge = runGit(["-C", pathString, "merge", "--no-ff", "-m",
                            "kiteloop rescue: merge \(mergeRef) for resolution", mergeSHA])
        guard merge.status != 0 else {
            return RescueWorktree(path: path, conflictedPaths: [])
        }
        let conflicted = runGit(["-C", pathString, "diff", "--name-only", "--diff-filter=U", "-z"])
        let paths = conflicted.status == 0
            ? conflicted.output.components(separatedBy: "\0").filter { !$0.isEmpty }
            : []
        return RescueWorktree(path: path, conflictedPaths: paths)
    }

    func destroy(for agentID: String) throws {
        let worktreePath = worktreesDir.appending(path: agentID)
        let branchName = "kiteloop/\(agentID)"

        WorktreeBuildOutput.release(for: worktreePath)

        // Both through `runGit`: teardown runs on the actor, so a git left
        // blocked on a full pipe buffer here would hold up every later worktree
        // call for this project, including the next item's setup.
        _ = runGit(["worktree", "remove", "--force", worktreePath.path(percentEncoded: false)])
        _ = runGit(["branch", "-D", branchName])

        activeWorktrees.removeValue(forKey: agentID)
    }

    func worktreePath(for agentID: String) -> URL? {
        activeWorktrees[agentID]
    }

    func exists(for agentID: String) -> Bool {
        let path = worktreesDir.appending(path: agentID)
        return FileManager.default.fileExists(atPath: path.path(percentEncoded: false))
    }

    /// Stages and commits everything in the worktree. Returns true if a commit was
    /// created (false when there was nothing to commit).
    func commitAll(for key: String, message: String) -> Bool {
        let path = worktreesDir.appending(path: key).path(percentEncoded: false)
        _ = runGit(["-C", path, "add", "-A"])
        return runGit(["-C", path, "commit", "-m", message]).status == 0
    }

    /// What became of the branch once the checkout was dropped.
    ///
    /// `refusal` is git's own words, one line, when the branch could not be
    /// deleted — and nil when it went, when it was never there, or when
    /// `keepBranch` said not to touch it. `removedStrayWorktree` names a
    /// checkout outside this project's `.kiteloop/worktrees` that was holding
    /// the branch and was taken away so the deletion could go ahead: worth
    /// saying on the item, because it is a checkout the run did not make.
    struct BranchDeletion: Sendable, Equatable {
        var refusal: String?
        var removedStrayWorktree: String?
        /// Where the branch tip was kept before the branch went, when it
        /// carried commits the project's `HEAD` could not reach — see
        /// `backUpUnmergedTip`. Nil when there was nothing unmerged to keep.
        var backupRef: String?
        /// Whether loose work in the worktree was committed before the
        /// directory was removed — see `recoverLooseWork`.
        var recoveredLooseWork: Bool = false
    }

    /// Removes the worktree directory. `keepBranch: false` also deletes the
    /// branch. Returns git's refusal when the branch could not be deleted, and
    /// the stray checkout removed to get the deletion through when there was one.
    ///
    /// The refusal is the answer a rerun needs. A rejected item's teardown keeps
    /// its branch on purpose — the branch is the work — and the next run of that
    /// item deletes it here before `create` makes a fresh one. git refuses to
    /// delete a branch some other worktree has checked out, and the ordinary
    /// reason one does is that a person checked the item branch out to review
    /// it. Ignoring that refusal, as this once did, let `create` fail a step
    /// later on "a branch named … already exists" — true, and useless, because
    /// the fix is in the checkout git names, not in the branch.
    ///
    /// Nothing here throws work away. Loose changes in the directory are
    /// committed before `worktree remove --force` deletes them, and a tip the
    /// project's `HEAD` cannot reach is kept under a backup ref before
    /// `branch -D` takes the branch. Four kinds of loss on 2026-09-12 — a
    /// cancelled run, a restart, a rebuilt branch, an item marked done off an
    /// unmerged branch — each came down to one of those two deletions.
    @discardableResult
    func removeWorktree(for key: String, keepBranch: Bool) -> BranchDeletion {
        let worktree = worktreesDir.appending(path: key)
        let path = worktree.path(percentEncoded: false)
        // The run's builds left an app bundle in the worktree that LaunchServices
        // registered under the real app's bundle id. Drop the registration while
        // the bundle is still there to name — afterwards `open -a <App>` can still
        // resolve to this path and launch nothing (or, worse, a stale copy that
        // survived). See `WorktreeBuildOutput`.
        WorktreeBuildOutput.release(for: worktree)
        var deletion = BranchDeletion(recoveredLooseWork: recoverLooseWork(for: key))
        _ = runGit(["worktree", "remove", "--force", path])
        activeWorktrees.removeValue(forKey: key)
        guard !keepBranch else { return deletion }
        deletion.backupRef = backUpUnmergedTip(for: key)
        let deleted = deleteBranch("kiteloop/\(key)")
        deletion.refusal = deleted.refusal
        deletion.removedStrayWorktree = deleted.removedStrayWorktree
        return deletion
    }

    /// Commits whatever the item's worktree holds uncommitted, so removing the
    /// directory removes no work. True when a commit was made; false when the
    /// worktree is absent, clean, or git would not commit (a merge left with
    /// unmerged paths — `commitAll` returns false and the caller's removal
    /// proceeds as before).
    private func recoverLooseWork(for key: String) -> Bool {
        guard exists(for: key), hasUncommittedChanges(for: key) else { return false }
        return commitAll(for: key, message: "autopilot (recovered before removal): \(key)")
    }

    /// The ref a branch tip is kept at before anything deletes or hands the
    /// branch to a worker: `refs/kiteloop/backup/<key>/<sha>`, outside
    /// `refs/heads/` so `branch -D` never touches it, and one per tip so a
    /// later backup never overwrites an earlier one.
    nonisolated static func backupRef(for key: String, tip: String) -> String {
        "refs/kiteloop/backup/\(key)/\(tip)"
    }

    /// Keeps the item branch's tip under `backupRef` when it carries commits
    /// the project's `HEAD` cannot reach. Returns the ref written; nil when
    /// there is no branch, the tip is already reachable, or git refused the
    /// write. A tip git could not place either way is backed up too — an
    /// unknown answer must not decide a deletion.
    @discardableResult
    func backUpUnmergedTip(for key: String) -> String? {
        let tip = runGit(["rev-parse", "--verify", "--quiet", "refs/heads/kiteloop/\(key)"])
        guard tip.status == 0 else { return nil }
        let sha = tip.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sha.isEmpty, runGit(["merge-base", "--is-ancestor", sha, "HEAD"]).status != 0 else { return nil }
        let ref = Self.backupRef(for: key, tip: sha)
        return runGit(["update-ref", ref, sha]).status == 0 ? ref : nil
    }

    /// Whether `sha` is no longer on the item's branch — a round that reset or
    /// rebased it rather than adding to it. The tip a fix round started from
    /// is read before the round (`PullRequestChecks.headSHA`) and asked about
    /// after: a worker that rewrote history has orphaned the commits the pull
    /// request was built from, and pushing that is how one went missing on
    /// 2026-09-12. An absent branch reads as rewritten — there is nothing left
    /// to push.
    func historyRewritten(for key: String, since sha: String) -> Bool {
        runGit(["merge-base", "--is-ancestor", sha, "refs/heads/kiteloop/\(key)"]).status != 0
    }

    /// `git branch -D`, with the one refusal worth reporting. A branch that is
    /// not there is not a refusal: the last run already took it, or never made it.
    ///
    /// A refusal is not the end of it. git only refuses because some worktree
    /// has the branch checked out, and when that worktree is not one of this
    /// project's own — a review checkout a person forgot, a directory left by
    /// a merge — the item's branch is being held hostage by something no run
    /// owns. That registration goes, and the deletion is tried once more, so
    /// the run starts instead of giving up. A worktree under
    /// `.kiteloop/worktrees` is a run's own and is never taken this way:
    /// `removeWorktree(for:keepBranch:)` owns those.
    private func deleteBranch(_ branch: String) -> BranchDeletion {
        guard runGit(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).status == 0 else {
            return BranchDeletion()
        }
        let deleted = runGit(["branch", "-D", branch])
        guard deleted.status != 0 else { return BranchDeletion() }
        let refusal = Self.branchDeletionRefusal(deleted, branch: branch)
        guard let stray = strayWorktree(holding: branch), removeStrayWorktree(at: stray) else {
            return BranchDeletion(refusal: refusal)
        }
        let retried = runGit(["branch", "-D", branch])
        guard retried.status != 0 else { return BranchDeletion(removedStrayWorktree: stray) }
        return BranchDeletion(refusal: Self.branchDeletionRefusal(retried, branch: branch),
                              removedStrayWorktree: stray)
    }

    /// git's reason for refusing `git branch -D`, flattened to one line. A
    /// refusal that printed nothing at all still has to say something, so the
    /// exit status stands in for words git didn't give.
    private nonisolated static func branchDeletionRefusal(
        _ result: (status: Int32, output: String), branch: String
    ) -> String {
        let reason = oneLineGitOutput(result.output)
        return reason.isEmpty ? "git branch -D \(branch) exited \(result.status)" : reason
    }

    /// The path of a worktree holding `branch` that no run of this project
    /// owns — anything outside `.kiteloop/worktrees`, the project's own
    /// checkout included. Nil when nothing holds the branch, or when what
    /// holds it is a run's own worktree.
    private func strayWorktree(holding branch: String) -> String? {
        let list = runGit(["worktree", "list", "--porcelain"])
        guard list.status == 0, let held = Self.worktreePath(holding: branch, in: list.output) else { return nil }
        return Self.isInside(worktreesDir, path: held) ? nil : held
    }

    /// Unregisters a checkout this manager did not make and prunes what the
    /// removal leaves behind. False when git refused — the project's own
    /// checkout, which git never removes, is the case that reaches here, and
    /// leaving it standing is the right answer: the caller then reports git's
    /// original refusal, which names it.
    private func removeStrayWorktree(at path: String) -> Bool {
        guard runGit(["worktree", "remove", "--force", path]).status == 0 else { return false }
        _ = runGit(["worktree", "prune"])
        return true
    }

    /// Whether `path` is `directory` or sits under it. git prints real paths,
    /// and a temp directory or a symlinked project root does not read the same
    /// as the URL this manager was given, so both sides resolve first.
    private nonisolated static func isInside(_ directory: URL, path: String) -> Bool {
        let root = resolvedPath(directory)
        let resolved = resolvedPath(URL(fileURLWithPath: path))
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    /// A path resolved for comparison. Foundation hands back a *directory* that
    /// exists with a trailing slash and one that doesn't without, so the slash
    /// is dropped: `/a/b/` and `/a/b` are the same place and must compare equal.
    private nonisolated static func resolvedPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Tags a rejected run's branch tip at `GateRejection.ref(itemID:)` —
    /// outside `refs/heads/`, so the next pickup's unconditional
    /// `removeWorktree(keepBranch: false)` (`deleteBranch` above, called from
    /// `WorktreeSession.startRefusal`) does not take the work with it. Nil
    /// when there is nothing to tag: the item never ran isolated, so it has
    /// no branch at all.
    @discardableResult
    func markRejected(for key: String) -> String? {
        let branch = "kiteloop/\(key)"
        guard runGit(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).status == 0 else { return nil }
        let ref = GateRejection.ref(itemID: key)
        guard runGit(["update-ref", ref, "refs/heads/\(branch)"]).status == 0 else { return nil }
        return ref
    }

    /// Removes a checkout left at `path` that git no longer registers — a
    /// crashed run's directory after `worktree prune` took its admin entry, the
    /// shape that makes `worktree add` refuse with "already exists". Only a
    /// directory carrying a `.git` file is touched: anything else at that path
    /// is not a worktree this manager made, and `create` fails on it as before.
    private func clearStaleCheckout(at worktreePath: URL) {
        let fm = FileManager.default
        let path = worktreePath.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.fileExists(atPath: worktreePath.appending(path: ".git").path(percentEncoded: false)) else { return }
        _ = runGit(["worktree", "prune"])
        // git prints real paths; a temp dir or a symlinked project root does
        // not read the same as the URL this was given, so both sides resolve.
        let resolved = worktreePath.resolvingSymlinksInPath().path(percentEncoded: false)
        let registered = runGit(["worktree", "list", "--porcelain"]).output
            .components(separatedBy: .newlines)
            .compactMap { $0.hasPrefix("worktree ") ? String($0.dropFirst("worktree ".count)) : nil }
            .contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path(percentEncoded: false) == resolved }
        guard !registered else { return }
        try? fm.removeItem(atPath: path)
    }

    /// Releases a kept worktree's disposable build output without touching the
    /// checkout — the `.keepForInspection` teardown and a `.keep` sweep verdict
    /// both leave the worktree in place but must not leave its DerivedData (and
    /// any LaunchServices registration) outliving the run that made it. Returns
    /// whether there was anything to release, so a caller can report how many
    /// kept worktrees actually had output freed.
    @discardableResult
    func releaseBuildOutput(for key: String) -> Bool {
        Self.releaseBuildOutput(for: worktreesDir.appending(path: key))
    }

    /// Whether `worktree` has any disposable build output, checked *before*
    /// `WorktreeBuildOutput.release` runs — it deletes but doesn't report what
    /// it found, and "nothing to free" has to be an honest answer, not a guess.
    private static func releaseBuildOutput(for worktree: URL) -> Bool {
        let fileManager = FileManager.default
        let hadOutput = fileManager.fileExists(
            atPath: WorktreeBuildOutput.derivedDataDirectory(for: worktree).path(percentEncoded: false))
            || !WorktreeBuildOutput.userDerivedDataTrees(builtFrom: worktree).isEmpty
        WorktreeBuildOutput.release(for: worktree)
        return hadOutput
    }

    // MARK: - Hygiene

    /// What one directory under the worktrees folder should have happen to it.
    enum OrphanVerdict: Equatable {
        /// A run is using it right now — not an orphan at all.
        case active
        /// Leave it alone; `reason` says what a reap would have destroyed.
        case keep(reason: String)
        /// Nothing to lose — drop the checkout (the branch is kept).
        case reap
    }

    /// The rule behind the open-time sweep. Pure, so the "never destroy work"
    /// guards can be read and tested without a repo on disk.
    ///
    /// A reap only ever removes a directory whose every byte is already in git
    /// and reachable from the project root's `HEAD`. Two things veto it:
    ///
    /// - **Unmerged commits** — that is the run's output; deleting it loses work.
    /// - **Uncommitted changes** — which is precisely what a `blocked` item's
    ///   worktree holds. Teardown keeps that one on purpose for a human to look
    ///   at (`WorktreeSession.TeardownAction.keepForInspection`), so reaping it
    ///   would quietly undo a documented feature, as well as taking any crashed
    ///   run's work-in-progress with it.
    ///
    /// Both are "when in doubt, leave it": every uncertain read of git below
    /// resolves to `keep`, never to `reap`.
    static func orphanVerdict(
        isActive: Bool,
        hasUnmergedCommits: Bool,
        hasUncommittedChanges: Bool
    ) -> OrphanVerdict {
        if isActive { return .active }
        if hasUnmergedCommits { return .keep(reason: "branch has unmerged commits") }
        if hasUncommittedChanges { return .keep(reason: "uncommitted changes") }
        return .reap
    }

    /// What one sweep did, for the log. Empty means the project was already tidy.
    struct SweepReport: Equatable, Sendable {
        struct Kept: Equatable, Sendable {
            let key: String
            let reason: String
        }

        /// Registrations `git worktree prune` dropped because their directory
        /// was gone (someone deleted it by hand, or an install moved the repo).
        var prunedRegistrations: Int = 0
        /// Orphan directories removed.
        var reaped: [String] = []
        /// Orphan directories deliberately left, with why.
        var kept: [Kept] = []
        /// How many of `kept`'s worktrees had disposable build output freed —
        /// the checkout and branch a kept worktree exists to be inspected stay
        /// exactly as they are; only the DerivedData behind them goes.
        var buildOutputFreed: Int = 0
        /// The item branches removed because the base already held every
        /// commit on them.
        var landedBranchesRemoved: [String] = []

        var isEmpty: Bool {
            prunedRegistrations == 0 && reaped.isEmpty && kept.isEmpty && landedBranchesRemoved.isEmpty
        }

        /// One line per thing that happened. A kept orphan gets its own line —
        /// the whole point of leaving it is that somebody is told it is there.
        var logLines: [String] {
            var lines: [String] = []
            if prunedRegistrations > 0 {
                lines.append("pruned \(prunedRegistrations) stale worktree registration(s)")
            }
            if !reaped.isEmpty {
                lines.append("reaped \(reaped.count) orphaned worktree(s): \(reaped.joined(separator: ", "))")
            }
            for entry in kept {
                lines.append("kept orphaned worktree \(entry.key) — \(entry.reason)")
            }
            if buildOutputFreed > 0 {
                lines.append("freed build output for \(buildOutputFreed) kept worktree(s)")
            }
            if !landedBranchesRemoved.isEmpty {
                lines.append("removed \(landedBranchesRemoved.count) landed item branch(es): "
                             + landedBranchesRemoved.joined(separator: ", "))
            }
            return lines
        }
    }

    /// Drops worktree registrations whose directory no longer exists. Safe by
    /// construction: prune only touches entries git can't find on disk.
    func prune() {
        guard Self.isGitRepository(at: projectRoot) else { return }
        _ = runGit(["-C", projectRoot.path(percentEncoded: false), "worktree", "prune"])
    }

    /// Prunes dead registrations, then reaps orphaned worktree directories — the
    /// ones no live run is behind, left by a run that crashed, was cancelled, or
    /// outlived the app. Nothing else cleans up after those paths, and each one
    /// is a full checkout of the project.
    ///
    /// Pass the item ids of any run in flight as `activeKeys`; a worktree in that
    /// set is never touched. A non-git project sweeps to an empty report rather
    /// than erroring — the same live-tree fallback the rest of this type takes.
    /// `base` is the branch the project's runs land on, when it names one;
    /// the verdict on each worktree's branch is taken against it, since
    /// "reachable from the checkout" says nothing on a project whose checkout
    /// is not its base.
    func sweep(activeKeys: Set<String> = [], base: String? = nil) -> SweepReport {
        var report = SweepReport()
        guard Self.isGitRepository(at: projectRoot) else { return report }

        let before = registeredWorktreeCount()
        prune()
        report.prunedRegistrations = max(0, before - registeredWorktreeCount())
        for key in worktreeDirectories() {
            sweepWorktree(key: key, activeKeys: activeKeys, base: base, report: &report)
        }
        report.landedBranchesRemoved = removeLandedItemBranches(activeKeys: activeKeys, base: base)
        return report
    }

    /// Every `kiteloop/*` branch the base already holds, removed — the
    /// landings from before a landed merge removed its own branch, and any
    /// merged by hand since. A branch a live run holds, one with a commit
    /// the base cannot reach, or one git will not delete is kept, and
    /// nothing here backs anything up because nothing here is lost.
    private func removeLandedItemBranches(activeKeys: Set<String>, base: String?) -> [String] {
        let listed = runGit(["for-each-ref", "--format=%(refname:short)", "refs/heads/kiteloop/"])
        guard listed.status == 0 else { return [] }
        return listed.output.split(whereSeparator: \.isNewline)
            .map { String($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.hasPrefix("kiteloop/") }
            .map { String($0.dropFirst("kiteloop/".count)) }
            .filter { !activeKeys.contains($0) && activeWorktrees[$0] == nil }
            .filter { removeMergedBranch(for: $0, base: base) == nil }
    }

    /// The directories under `.kiteloop/worktrees`, sorted — one per run
    /// that had a worktree, whether or not git still knows about it.
    private func worktreeDirectories() -> [String] {
        let fm = FileManager.default
        let worktreesPath = worktreesDir.path(percentEncoded: false)
        return ((try? fm.contentsOfDirectory(atPath: worktreesPath)) ?? []).sorted().filter { key in
            var isDirectory: ObjCBool = false
            let path = worktreesDir.appending(path: key).path(percentEncoded: false)
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func sweepWorktree(key: String, activeKeys: Set<String>, base: String?, report: inout SweepReport) {
        let fm = FileManager.default
        let path = worktreesDir.appending(path: key).path(percentEncoded: false)
        switch Self.orphanVerdict(
            isActive: activeKeys.contains(key) || activeWorktrees[key] != nil,
            hasUnmergedCommits: hasUnmergedCommits(for: key, base: base),
            hasUncommittedChanges: hasUncommittedChanges(for: key)
        ) {
        case .active:
            return
        case .keep(let reason):
            report.kept.append(SweepReport.Kept(key: key, reason: reason))
            if releaseBuildOutput(for: key) {
                report.buildOutputFreed += 1
            }
        case .reap:
            // Keep the branch: it is the audit trail of what ran, it costs a
            // ref rather than a checkout, and by the verdict above everything
            // in the directory is already reachable from the base anyway.
            removeWorktree(for: key, keepBranch: true)
            // A directory git doesn't know about (already pruned, or never
            // registered) survives `worktree remove`. It is still ours and
            // still holds nothing unrecoverable, so take it directly.
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
            if !fm.fileExists(atPath: path) {
                report.reaped.append(key)
            }
        }
    }

    /// Whether the item's branch holds commits the project's base can't reach
    /// — i.e. work that only exists on that branch. The base is `base` when
    /// the project names one, else the checkout's `HEAD`.
    ///
    /// Asked against the base rather than whatever is checked out: with the
    /// item's own branch checked out to review it, every commit on it is
    /// reachable from `HEAD`, and "nothing unmerged" then approved the item
    /// without a merge — Done, with the work on a branch nothing had merged.
    /// A checkout sitting on the item branch itself answers `true`.
    ///
    /// Reads that fail (no such branch is fine; an unborn `HEAD` or a broken repo
    /// is not) answer `true`: an unreadable repo must not license a delete.
    func hasUnmergedCommits(for key: String, base: String? = nil) -> Bool {
        let root = projectRoot.path(percentEncoded: false)
        let name = WorktreeSession.branchName(for: key)
        let branch = "refs/heads/\(name)"
        guard runGit(["-C", root, "rev-parse", "--verify", "--quiet", branch]).status == 0 else {
            return false  // no branch, so nothing unmerged can be sitting on one
        }
        let target = base.map { "refs/heads/\($0)" } ?? "HEAD"
        if target == "HEAD", currentBranchName() == name { return true }
        let result = runGit(["-C", root, "rev-list", "--count", branch, "--not", target])
        guard result.status == 0,
              let count = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return true }
        return count > 0
    }

    /// Removes an item branch the base already holds — after a landed merge,
    /// where the branch's every commit is reachable from the base and the ref
    /// is the one thing left of the run. 345 such refs had accumulated on one
    /// project by 2026-09-20 with nothing removing any. Nil when the branch
    /// is gone (or never was); otherwise why it was kept, which is always
    /// "git says something on it is not in the base" or git's own refusal —
    /// this never deletes over an unmerged commit, and an unreadable answer
    /// keeps the branch, as `hasUnmergedCommits` reads it.
    func removeMergedBranch(for key: String, base: String?) -> String? {
        let name = WorktreeSession.branchName(for: key)
        guard runGit(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]).status == 0 else { return nil }
        guard !hasUnmergedCommits(for: key, base: base) else {
            return "\(name) holds commits \(base ?? "the checkout") does not"
        }
        if currentBranchName() == name { return "\(name) is the checked-out branch" }
        // `-D`, not `-d`: git's own merged check is against `HEAD`, and the
        // base a run lands on need not be the checkout. The check above is
        // the one that matters, against the base the merge went into.
        let deleted = runGit(["branch", "-D", name])
        guard deleted.status != 0 else { return nil }
        return Self.branchDeletionRefusal(deleted, branch: name)
    }

    /// Whether the item's branch exists at all.
    ///
    /// `hasUnmergedCommits` answers false to two opposite questions — the branch
    /// was merged, and there never was a branch — and the approval gate has to
    /// tell them apart: only one of them means the work landed. An unreadable
    /// repo answers true, so a git nobody could ask never becomes the reason an
    /// item is refused.
    func branchExists(for key: String) -> Bool {
        let root = projectRoot.path(percentEncoded: false)
        let branch = "refs/heads/\(WorktreeSession.branchName(for: key))"
        let result = runGit(["-C", root, "rev-parse", "--verify", "--quiet", branch])
        // 0 = the ref is there, 1 = no such ref, anything else means the
        // question couldn't be asked.
        return result.status != 1
    }

    /// Whether `name` is a branch of this repository — a local one, under
    /// `refs/heads/`. A remote-tracking branch of the same name does not count:
    /// a run forks from and lands on local refs only, and never fetches.
    /// Unlike `branchExists(for:)` an unreadable repo answers false here — the
    /// caller is about to fork from the branch, and a base nobody can read is
    /// not one to start a run on.
    func localBranchExists(named name: String) -> Bool {
        let root = projectRoot.path(percentEncoded: false)
        return runGit(["-C", root, "rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]).status == 0
    }

    /// Whether the project root's `HEAD` has moved past what this item's branch
    /// was built on — the branch's own diff hasn't changed, but the tree it
    /// would land on has, so an approval now could be stamping a merge nobody
    /// has actually run `verify` against.
    ///
    /// Read the cheap way, with `merge-base --is-ancestor`, rather than
    /// attempting a real merge: a rebase round is only worth spending when
    /// something has actually moved, and this answers that without touching
    /// any checkout. An unreadable repo, a missing branch or an unresolved
    /// ancestor question all answer `false` — the same "leave it" direction
    /// `orphanVerdict` takes, since flagging a fresh branch stale would spend a
    /// round rebasing nothing.
    func isStale(for key: String) -> Bool {
        let root = projectRoot.path(percentEncoded: false)
        let branch = "refs/heads/\(WorktreeSession.branchName(for: key))"
        guard runGit(["-C", root, "rev-parse", "--verify", "--quiet", branch]).status == 0 else {
            return false
        }
        let head = runGit(["-C", root, "rev-parse", "HEAD"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty else { return false }
        // 0 = HEAD is already in the branch's history (fresh); 1 = it isn't
        // (stale); anything else means the question couldn't be answered.
        return runGit(["-C", root, "merge-base", "--is-ancestor", head, branch]).status == 1
    }

    /// The project root's current branch — the base a gate-refresh round merges
    /// into the item's branch. Empty when the checkout is detached or the
    /// question can't be answered, which the caller reads as "name it
    /// generically" rather than crash on.
    func currentBranchName() -> String {
        let root = projectRoot.path(percentEncoded: false)
        return runGit(["-C", root, "rev-parse", "--abbrev-ref", "HEAD"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The project root's own uncommitted tracked modifications, as paths.
    ///
    /// Tracked only, deliberately. Untracked paths are the ordinary state of a
    /// working checkout — a `.claude/settings.local.json`, build droppings — and
    /// `mergeAndVerify` already learned that treating them as dirt refuses
    /// everything in a project that has one. What this reads is the same set
    /// `mergeRefusal` always refuses on.
    func modifiedPaths() -> [String] {
        let root = projectRoot.path(percentEncoded: false)
        let result = runGit(["-C", root, "status", "--porcelain"])
        guard result.status == 0 else { return [] }
        return Self.classify(porcelain: result.output).modified
    }

    /// Why approving this item would not mean what it says — or nil when it
    /// would, which is the ordinary answer.
    ///
    /// The case: an item at the gate whose branch does not exist, on a project
    /// that runs its items in worktrees, with the project's own checkout holding
    /// uncommitted modifications. "Nothing to merge" is the answer that path
    /// gives today, and it is indistinguishable from the safe one — a branch
    /// already merged — while meaning the opposite: the work never reached a
    /// branch at all and is sitting loose in the tree. Approving stamps the item
    /// `done` and the backlog claims delivery over uncommitted files.
    ///
    /// Every clause is required, and each one is what keeps this from refusing
    /// ordinary approvals: with isolation off the live tree is where the work is
    /// *meant* to be, a branch that exists and is merged is work that landed,
    /// and a clean tree holds nothing to be wrong about.
    ///
    /// Pure, so the rule can be read without a repository.
    nonisolated static func emptyBranchRefusal(
        isolationExpected: Bool,
        branchExists: Bool,
        modified: [String],
        maxPaths: Int = 3
    ) -> String? {
        guard isolationExpected, !branchExists, !modified.isEmpty else { return nil }
        let shown = modified.prefix(maxPaths).joined(separator: ", ")
        let extra = modified.count - min(modified.count, maxPaths)
        let named = extra > 0 ? "\(shown) (+\(extra) more)" : shown
        return "the work is not where it should be — this item has no branch, and the "
             + "project's checkout has uncommitted changes (modified): \(named)"
    }

    /// Whether the item's worktree has changes that aren't committed anywhere —
    /// modified tracked files or new untracked ones, both of which are work.
    /// An unreadable worktree answers `true`, for the same reason as above.
    func hasUncommittedChanges(for key: String) -> Bool {
        let path = worktreesDir.appending(path: key).path(percentEncoded: false)
        let result = runGit(["-C", path, "status", "--porcelain"])
        guard result.status == 0 else { return true }
        return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// How many worktrees this repo currently has registered, the project root
    /// included. Used either side of a prune to report what it dropped.
    private func registeredWorktreeCount() -> Int {
        let result = runGit(["-C", projectRoot.path(percentEncoded: false), "worktree", "list", "--porcelain"])
        guard result.status == 0 else { return 0 }
        return result.output
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("worktree ") }
            .count
    }

    /// The live tree's dirt, split by whether a rollback could destroy it.
    ///
    /// `modified` is every tracked change — staged or not, deletes and renames
    /// included — i.e. the paths `git reset --hard` would overwrite. `untracked`
    /// is the `??` entries, which a reset never touches; git collapses a wholly
    /// untracked directory into a single `dir/` entry, so those keep their
    /// trailing slash.
    struct DirtyTree: Equatable, Sendable {
        var modified: [String] = []
        var untracked: [String] = []
        /// A non-empty status line no path could be read out of. Unknown dirt is
        /// read as tracked dirt — the conservative side.
        var unreadable = false
    }

    /// Splits `git status --porcelain` output into the two kinds of dirt.
    nonisolated static func classify(porcelain: String) -> DirtyTree {
        var tree = DirtyTree()
        for line in porcelain.components(separatedBy: .newlines) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let code = String(line.prefix(2))
            guard code != "!!" else { continue }  // ignored files never block a merge
            // `XY PATH`, or `XY ORIG -> PATH` for a rename: the status is two
            // columns wide, so the path field starts after them. The rename's
            // new name is the one worth reporting.
            guard line.count > 3 else {
                tree.unreadable = true
                continue
            }
            let field = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let path = unquotePath(field.components(separatedBy: " -> ").last ?? "")
            guard !path.isEmpty else {
                tree.unreadable = true
                continue
            }
            if code == "??" {
                tree.untracked.append(path)
            } else {
                tree.modified.append(path)
            }
        }
        return tree
    }

    /// The reason a merge was refused for a dirty tree, naming the paths that made
    /// it dirty and which kind they are — so the run log and the `.merge` phase-log
    /// row say *which* file to fix, and whether it needs committing/stashing or a
    /// real look, instead of leaving the operator to open a terminal and find out.
    /// `nil` means the dirt is harmless and the merge may go ahead.
    ///
    /// Refuses only on **overlap** with `incoming` — the paths the merge is
    /// about to bring in. A tracked modification used to refuse unconditionally,
    /// on the theory that a rollback (`reset --hard`) could throw it away; the
    /// merge no longer runs in this checkout at all (`mergeAndVerify` merges and
    /// verifies in a scratch worktree and only fast-forwards here once that's
    /// green), so nothing here is ever rolled back, and an edit to a file the
    /// merge never touches has nothing to lose. An untracked path refuses the
    /// same way it always did: `git merge` itself refuses to overwrite one it
    /// needs to write, so a collision is a real refusal, and everything else (a
    /// stray `.claude/settings.local.json`, build droppings) goes through.
    /// `incoming == nil` means the diff couldn't be read: every dirty path then
    /// counts as colliding rather than being waved past on a guess.
    ///
    /// Capped at `maxPaths` names with a "(+N more)" tail: a repo with hundreds of
    /// dirty files must not produce a log line nobody can read. Porcelain output
    /// that yields no path at all falls back to the bare reason rather than an
    /// empty list — an unparseable status is still a refusal.
    nonisolated static func mergeRefusal(
        porcelain: String,
        incoming: [String]?,
        maxPaths: Int = 3
    ) -> String? {
        let tree = classify(porcelain: porcelain)
        if tree.unreadable {
            return refusal(kind: "modified", paths: tree.modified, maxPaths: maxPaths)
        }
        let collidingModified = tree.modified.filter { collides($0, with: incoming) }
        if !collidingModified.isEmpty {
            return refusal(kind: "modified", paths: collidingModified, maxPaths: maxPaths)
        }
        let collidingUntracked = tree.untracked.filter { collides($0, with: incoming) }
        guard !collidingUntracked.isEmpty else { return nil }
        return refusal(kind: "untracked, colliding", paths: collidingUntracked, maxPaths: maxPaths)
    }

    /// Whether the merge would have to write over `path` — tracked or untracked,
    /// either one. An untracked directory entry (`dir/`) collides with anything
    /// the merge lands inside it.
    private nonisolated static func collides(_ path: String, with incoming: [String]?) -> Bool {
        guard let incoming else { return true }
        if path.hasSuffix("/") {
            return incoming.contains { $0.hasPrefix(path) }
        }
        return incoming.contains(path)
    }

    private nonisolated static func refusal(kind: String, paths: [String], maxPaths: Int) -> String {
        let base = "working tree not clean"
        guard !paths.isEmpty else { return base }
        let shown = paths.prefix(maxPaths).joined(separator: ", ")
        let extra = paths.count - min(paths.count, maxPaths)
        let named = extra > 0 ? "\(shown) (+\(extra) more)" : shown
        return "\(base) (\(kind)): \(named)"
    }

    /// Why a merge was refused for conflicting, naming the paths git left
    /// unmerged so the operator doesn't have to open a terminal and rediscover
    /// them — in this repo that path is very often `CHANGELOG.md`.
    ///
    /// Capped at `maxPaths` names with a "(+N more)" tail, same shape as
    /// `mergeRefusal`'s. `paths` empty — git answered nothing, or couldn't be
    /// asked — falls back to the bare `merge conflict` rather than naming
    /// nothing, so an unanticipated case degrades to today's wording instead of
    /// an empty phrase.
    ///
    /// `rebaseAlsoConflicted` says whether `mergeAndVerify` tried the one
    /// automatic recovery — rebasing the branch onto the current base — before
    /// giving up. That fact belongs in the same sentence: this string is what
    /// reaches the gate panel, the control API payload and the next run's
    /// rejection note, and "did it even try" is the second thing each of them
    /// asks, right after "which files."
    nonisolated static func conflictRefusal(
        paths: [String], maxPaths: Int = 3, rebaseAlsoConflicted: Bool = false
    ) -> String {
        let base = "merge conflict"
        let named: String? = paths.isEmpty ? nil : {
            let shown = paths.prefix(maxPaths).joined(separator: ", ")
            let extra = paths.count - min(paths.count, maxPaths)
            return extra > 0 ? "\(shown) (+\(extra) more)" : shown
        }()
        let headline = named.map { "\(base) in: \($0)" } ?? base
        guard rebaseAlsoConflicted else { return headline }
        return "\(headline) — a rebase onto the current base also conflicted"
    }

    /// Undoes the C-style quoting git applies to a porcelain path that contains a
    /// quote, a backslash or a control character (`"a \"b\".txt"` → `a "b".txt`).
    /// Escapes are unwrapped literally — a readable name is the whole goal here,
    /// not a path that round-trips.
    private nonisolated static func unquotePath(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        var out = ""
        var escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// What a merge attempt did, and — when a verify failed — what it printed
    /// while failing.
    ///
    /// The output is the whole point of carrying a result type here: the merge
    /// and its verify both happen in a scratch worktree that's discarded either
    /// way, so by the time anyone reads `reason` the tree that failed is already
    /// gone and "verify failed on merged tree" is the only thing left of it. An
    /// operator deciding between retrying and rejecting needs the failure itself.
    struct MergeResult: Equatable, Sendable {
        let merged: Bool
        let reason: String
        /// Tail of the verify command's combined output, present only when the
        /// refusal was the verify failing.
        var verifyOutput: String?
        /// The commands that actually ran on the merged tree, in run order and
        /// named by `MergeVerifyPlan.Step.label` — the ones that passed, plus
        /// the one that failed when a verify is what refused.
        ///
        /// Empty means nothing checked this merge. That is a real state (no
        /// project command, no item `verify:`) and the caller reports it as
        /// such: a merge nobody validated must not read like a merge that
        /// passed a gate.
        var verifyRan: [String] = []
        /// Every step that needed a second attempt, in run order — the
        /// attempt that failed (whether or not the step went on to pass) and
        /// the tail of what it printed. Empty means every step that ran
        /// passed outright: a merge with nothing to retry writes nothing
        /// here, the same as `verifyOutput` writes nothing on a clean pass.
        var stepOutputs: [VerifyStepOutput] = []
        /// The commit the base now points at, when the merge landed — the one
        /// durable link from an item to the work that satisfied it. Nil on a
        /// refusal.
        var mergeCommit: String? = nil
    }

    /// One verify step's failing attempt, kept for the ledger row and the
    /// item's `## Notes` — the merged tree it ran against is a scratch
    /// worktree gone by the time anyone reads this, so this is the one copy
    /// of what it printed that survives.
    ///
    /// `attempt`/`totalAttempts` name which try produced `output`: 1 of 1 for
    /// a step that was never retried (nothing recognized the failure, or it
    /// timed out), 2 of 2 for one given a retry that failed the same way
    /// again, 1 of 2 for one that failed once and passed on the retry —
    /// `recovered` tells those last two apart.
    struct VerifyStepOutput: Equatable, Sendable {
        let stepLabel: String
        let attempt: Int
        let totalAttempts: Int
        let recovered: Bool
        let output: String

        /// One block: which step, which attempt, and the tail it printed —
        /// the shape both the ledger row and a `## Notes` entry render this
        /// as, so there is exactly one place that formatting is decided.
        var noteText: String {
            let attemptPhrase = recovered
                ? "attempt \(attempt) of \(totalAttempts) — recovered"
                : "attempt \(attempt) of \(totalAttempts)"
            return "\(stepLabel) (\(attemptPhrase)):\n\(output)"
        }
    }

    /// Every kept step output, joined into the one block a ledger row and a
    /// `## Notes` entry each carry. `nil` when there is nothing to join — a
    /// merge that never needed a retry, which must write no output at all.
    nonisolated static func verifyStepOutputsNote(_ outputs: [VerifyStepOutput]) -> String? {
        guard !outputs.isEmpty else { return nil }
        return outputs.map(\.noteText).joined(separator: "\n\n")
    }

    /// Merges `branch` into a scratch worktree checked out detached from the
    /// base's tip, runs `verify`'s commands, in order, against that merged
    /// tree, and — only once every one of them is green — lands the resulting
    /// merge commit on the base. Nothing about the checkout moves before that
    /// last step: the merge itself and everything `verify` writes while
    /// checking it happen in the scratch worktree, which is removed whatever
    /// the outcome — so a red verify leaves the checkout exactly as it found
    /// it, with no rollback needed because nothing there was ever touched. On
    /// success the branch is kept (audit trail).
    ///
    /// **Which branch the merge lands on** is `base` — the project's
    /// `baseBranch` setting — and nil means the checkout's `HEAD`, which is
    /// exactly what this did before the setting existed. With a name, one of
    /// three things happens, decided by `landing(for:)` before the scratch
    /// worktree is made:
    ///
    /// - the live checkout is on the base: merge at its tip, verify, then
    ///   fast-forward the checkout, as for nil;
    /// - the base is checked out in some *other* worktree of the repository:
    ///   refuse, naming that worktree's path. `git update-ref` would not
    ///   refuse — it would move the ref under that worktree's live index and
    ///   `HEAD`, which is what happened on 2026-09-03 when "run on
    ///   `quality/rebased`" meant registering the checkout a second time and
    ///   the base turned up checked out in a stale scratch worktree;
    /// - otherwise: merge at the base's tip, verify, then move
    ///   `refs/heads/<base>` to the merge commit with a compare-and-swap
    ///   `update-ref` against the tip read at the start, and leave the checkout
    ///   alone. A tip that moved in between refuses, naming both. The app never
    ///   switches a checkout.
    ///
    /// A precheck still refuses up front, but only for **overlap**: an
    /// uncommitted tracked or untracked change to a file the merge would also
    /// touch — the same thing `git merge --ff-only` itself would refuse the
    /// fast-forward for, said with the paths named before the run pays for a
    /// scratch worktree and a verify. An edit to a file the merge never
    /// touches is not a reason to refuse; see `mergeRefusal`.
    ///
    /// A step whose failure `classifyVerifyFailure` recognizes — a crashed test
    /// binary, a lock timeout, a named test failure — gets one retry before its
    /// answer counts: a merge that passes the second time merges, with the
    /// reason saying it was retried and why; one that fails the same way twice
    /// is refused, naming the class and "twice". Anything else is refused on
    /// the first attempt, as before.
    ///
    /// A merge that conflicts gets one recovery of its own, tried before the
    /// conflict is taken as the answer: `branch` is rebased onto the same
    /// commit the scratch worktree is built on (`landing.startSHA`), in a
    /// second, disposable detached worktree that never touches `refs/heads/
    /// <branch>` until the rebase is known to succeed — a branch that ends this
    /// function unmerged must be exactly the branch a sibling's landed commits
    /// made stale, never a rewritten one a retry left half-changed. Only once
    /// the rebase is clean does the branch ref move, by compare-and-swap
    /// against the tip it started at, and the merge is retried with the
    /// rebased branch. This buys real ground: a straight `--no-ff` merge
    /// compares only the two sides' *final* trees, so it conflicts whenever a
    /// sibling's fix and this branch's history disagree on a spot, even if the
    /// branch's own commits, replayed one at a time onto that sibling's tip,
    /// resolve the same spot without a hand needed — the git-recorded case
    /// this repo's rejection notes call "branch no longer merges." A rebase
    /// that itself conflicts is aborted, the branch left untouched, and the
    /// reason names both facts — the original conflict's paths, and that the
    /// rebase was tried and also conflicted.
    ///
    /// Every command is run under its own `timeout`, so two of them bound a hang
    /// exactly as one did: an overrun still fails closed, and nothing is skipped
    /// to make room for what follows it. An overrun is also *said* to be one —
    /// see the reason a timed-out step writes below — and is never retried,
    /// since a killed process answered nothing either time.
    ///
    /// A base that moves while the verify runs — a sibling's gate landing
    /// first — gets one retry of its own, after the verify, distinct from the
    /// two above: `mergeOnceWithRetry` rebuilds the scratch merge on the
    /// base's now-current tip and verifies it again, once, before trying to
    /// land a second time. That retry is spent only on a base that *did*
    /// move: the tip is read again at the failure and compared with the one
    /// the scratch merge was built on, so a landing refused for its own
    /// reason — a checkout gone dirty under it, a base someone checked out
    /// meanwhile — is refused once with git's reason and never pays for a
    /// second verify. Two gates on the same project never race this: see
    /// `MergeGateLock`.
    ///
    /// `onGateWait` is how a caller says that this merge is queued behind
    /// another on the same project rather than running: `.waiting` before the
    /// wait, `.acquired` once the gate is held, neither when there was no
    /// wait. It is awaited, so a caller that draws the wait has drawn it
    /// before the merge starts.
    func mergeAndVerify(
        branch: String,
        message: String,
        verify: MergeVerifyPlan,
        timeout: TimeInterval = 900,
        base: String? = nil,
        setupCommand: String? = nil,
        onGateWait: (@Sendable (MergeGateWait) async -> Void)? = nil
    ) async -> MergeResult {
        let root = projectRoot.path(percentEncoded: false)
        if await mergeGate.tryAcquire(root) == false {
            await onGateWait?(.waiting)
            await mergeGate.acquire(root)
            await onGateWait?(.acquired)
        }
        let result = mergeOnceWithRetry(branch: branch, message: message, verify: verify, timeout: timeout,
                                        base: base, setupCommand: setupCommand, root: root)
        await mergeGate.release(root)
        return result
    }

    /// One full gate — merge, verify, land — with the one retry `mergeAndVerify`'s
    /// doc comment promises for a base that moved while the verify ran.
    /// `runScratchMergeAndLand`'s landing step is the only one of its stages
    /// that can fail *after* a green verify: a conflict is already resolved or
    /// refused, and a red verify already returned, before landing is ever
    /// tried. But not every landing failure is the race: a fast-forward also
    /// refuses for a checkout that went dirty under it, and re-running a
    /// ten-minute verify for that would cost the run twice over and then
    /// report "base moved" for something the base had nothing to do with. So
    /// the retry is gated on `tipIfMoved` — the base's tip now against the one
    /// the scratch merge was built on — and any other landing failure is
    /// returned as it stands, with git's own reason, exactly as before the
    /// retry existed. A base that has moved again by the time the retry lands
    /// is refused by name, not by relaying git's fast-forward hint text.
    private func mergeOnceWithRetry(
        branch: String, message: String, verify: MergeVerifyPlan, timeout: TimeInterval,
        base: String?, setupCommand: String?, root: String
    ) -> MergeResult {
        let landing = landing(for: base, branch: branch, root: root)
        if let refusal = landing.refusal { return refusal }

        let first = runScratchMergeAndLand(branch: branch, message: message, verify: verify, timeout: timeout,
                                           setupCommand: setupCommand, root: root, landing: landing)
        guard first.failedAtLanding, tipIfMoved(from: landing, root: root) != nil else { return first.result }

        let retryLanding = self.landing(for: base, branch: branch, root: root)
        if let refusal = retryLanding.refusal { return refusal }
        let second = runScratchMergeAndLand(branch: branch, message: message, verify: verify, timeout: timeout,
                                            setupCommand: setupCommand, root: root, landing: retryLanding)
        if second.failedAtLanding {
            return secondLandingRefusal(second, retryLanding: retryLanding, base: base, root: root)
        }
        guard second.result.merged else { return second.result }
        return MergeResult(
            merged: true,
            reason: "base moved during verify from \(landing.startSHA.prefix(7))"
                + " to \(retryLanding.startSHA.prefix(7)) — merged onto it and verified again",
            verifyRan: second.result.verifyRan, stepOutputs: second.result.stepOutputs)
    }

    /// The retry's own landing failure, worded by the same rule the first one
    /// is: "moved again" only when the tip actually moved a second time, and
    /// otherwise the refusal git gave, untouched.
    private func secondLandingRefusal(_ attempt: LandingAttempt, retryLanding: Landing,
                                      base: String?, root: String) -> MergeResult {
        guard tipIfMoved(from: retryLanding, root: root) != nil else { return attempt.result }
        return MergeResult(
            merged: false,
            reason: "\(baseLabel(retryLanding, base: base)) moved again during the retry"
                + " — refused rather than merging a third time",
            verifyRan: attempt.result.verifyRan)
    }

    /// The base's tip right now, when it differs from the one `landing`'s
    /// scratch merge was built on; `nil` when it is unchanged. This is what
    /// separates a landing that lost a race to a sibling's merge — worth one
    /// rebuild and a second verify — from one refused for its own reason,
    /// which a second verify cannot fix and must not be charged for.
    ///
    /// A tip that cannot be read at all reads as unmoved: a refusal whose
    /// cause could not be established is refused, not retried.
    private func tipIfMoved(from landing: Landing, root: String) -> String? {
        let now: String
        switch landing {
        case .updateRef(let base, _):
            now = trimmedGit(["-C", root, "rev-parse", "--verify", "--quiet", "refs/heads/\(base)"])
        case .fastForwardCheckout:
            now = trimmedGit(["-C", root, "rev-parse", "HEAD"])
        case .refused:
            return nil
        }
        guard !now.isEmpty, now != landing.startSHA else { return nil }
        return now
    }

    /// `runGit`'s output with its trailing newline gone — what every caller
    /// that reads a SHA or a single-token answer out of git wants.
    private func trimmedGit(_ args: [String]) -> String {
        runGit(args).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What to call the thing that moved, for the reason a second landing
    /// failure gets: the base's own name when the project names one — read
    /// off `landing` rather than `base` so an update-ref landing is always
    /// named even if a caller somehow passed a different string — the
    /// checkout's current branch otherwise.
    private func baseLabel(_ landing: Landing, base: String?) -> String {
        if case .updateRef(let name, _) = landing { return name }
        return base ?? currentBranchName()
    }

    /// One landing attempt's result, and whether its failure — if any —
    /// happened at the landing step itself (the fast-forward or the
    /// compare-and-swap) rather than the scratch setup, a conflict, or the
    /// verify. Only a landing-step failure is what `mergeOnceWithRetry` retries.
    private struct LandingAttempt {
        let result: MergeResult
        let failedAtLanding: Bool
    }

    /// Builds the scratch worktree at `landing.startSHA`, merges `branch` into
    /// it (recovering once from a conflict by rebasing, as `mergeAndVerify`'s
    /// doc comment describes), verifies the result, and lands it. This is
    /// what one attempt does, in full, so `mergeOnceWithRetry` can run it
    /// twice against two different tips without duplicating any of it.
    private func runScratchMergeAndLand(
        branch: String, message: String, verify: MergeVerifyPlan, timeout: TimeInterval,
        setupCommand: String?, root: String, landing: Landing
    ) -> LandingAttempt {
        let scratch = Self.scratchWorktreeDirectory(forBranch: branch, projectRoot: projectRoot)
        // Whatever happens below, the scratch worktree must not survive it — a
        // stale one left by an earlier crashed attempt would also make the
        // `worktree add` below refuse, so this doubles as that defensive clear.
        removeScratchWorktree(at: scratch)
        defer { removeScratchWorktree(at: scratch) }
        let scratchPath = scratch.path(percentEncoded: false)

        if let failure = createScratchWorktree(at: scratchPath, from: landing.startSHA, root: root) {
            return LandingAttempt(result: failure, failedAtLanding: false)
        }
        if let failure = Self.runSetupCommand(setupCommand, in: scratch, timeout: timeout,
                                              projectRoot: projectRoot) {
            return LandingAttempt(result: failure, failedAtLanding: false)
        }
        if let conflictedPaths = conflictingMerge(branch, message: message, scratchPath: scratchPath) {
            if let failure = rebaseThenRetryMerge(
                branch: branch, message: message, ontoSHA: landing.startSHA,
                scratchPath: scratchPath, root: root, conflictPaths: conflictedPaths,
                timeout: timeout, setupCommand: setupCommand
            ) {
                return LandingAttempt(result: failure, failedAtLanding: false)
            }
        }

        let outcome = Self.runVerifySteps(verify, workingDirectory: scratch, timeout: timeout,
                                          projectRoot: projectRoot)
        if let failure = outcome.failure {
            let reported = Self.scratchRemovedResult(at: scratchPath, failure: failure)
                ?? attributingToBase(failure, outcome: outcome, landing: landing, timeout: timeout,
                                     setupCommand: setupCommand)
            return LandingAttempt(result: reported, failedAtLanding: false)
        }

        let landed = landMerge(landing, root: root, scratchPath: scratchPath,
                               ran: outcome.ran, reason: outcome.recoveredReason ?? "merged",
                               stepOutputs: outcome.stepOutputs)
        return LandingAttempt(result: landed, failedAtLanding: !landed.merged)
    }

    /// `failure`, saying so when the base fails the same command with no diff
    /// on it — the refusal then reads as the base's, not as something this
    /// branch broke. On 2026-11-10 five tests a system proxy was breaking
    /// failed on the base and on every merged tree alike, and a branch that
    /// changed only Python was refused for "breaking" Rust tests.
    ///
    /// Asked only of a project-wide step. The item's own `verify:` is written
    /// for the item's change and is expected to fail without it, so its
    /// failing on the base says nothing. Not asked of a step the deadline
    /// killed either: that would spend the same deadline again to learn
    /// nothing about the diff.
    ///
    /// The base's answer is kept per tip and command for as long as the app
    /// runs, so a branch refused, fixed and refused again asks the base once.
    private func attributingToBase(
        _ failure: MergeResult, outcome: VerifyRunOutcome, landing: Landing,
        timeout: TimeInterval, setupCommand: String?
    ) -> MergeResult {
        guard let step = outcome.failedStep, step.source == .project, !outcome.failureTimedOut else {
            return failure
        }
        let sha = landing.startSHA
        let key = [projectRoot.path(percentEncoded: false), sha, step.command].joined(separator: "\u{0}")
        let basePasses = Self.baseAnswers.withLock { $0[key] }
            ?? askBase(step.command, sha: sha, key: key, timeout: timeout, setupCommand: setupCommand)
        guard basePasses == false else { return failure }
        return MergeResult(
            merged: false,
            reason: Self.baseAlsoFailsReason(failure.reason, base: baseLabel(landing, base: nil), sha: sha),
            verifyOutput: failure.verifyOutput, verifyRan: failure.verifyRan, stepOutputs: failure.stepOutputs)
    }

    /// Runs `command` on the base tip `sha` alone and remembers the answer.
    /// Nil — and nothing remembered — when the base could not be checked out
    /// or set up, or its scratch tree vanished: that is no answer about it.
    private func askBase(_ command: String, sha: String, key: String,
                         timeout: TimeInterval, setupCommand: String?) -> Bool? {
        let scratch = Self.scratchWorktreeDirectory(forBranch: "base-attribution", projectRoot: projectRoot)
        removeScratchWorktree(at: scratch)
        defer { removeScratchWorktree(at: scratch) }
        let scratchPath = scratch.path(percentEncoded: false)
        guard createScratchWorktree(at: scratchPath, from: sha,
                                    root: projectRoot.path(percentEncoded: false)) == nil,
              Self.runSetupCommand(setupCommand, in: scratch, timeout: timeout, projectRoot: projectRoot) == nil
        else { return nil }
        let plan = MergeVerifyPlan(steps: [MergeVerifyPlan.Step(source: .project, command: command)])
        let outcome = Self.runVerifySteps(plan, workingDirectory: scratch, timeout: timeout, projectRoot: projectRoot)
        if let failure = outcome.failure,
           outcome.failureTimedOut || Self.scratchRemovedResult(at: scratchPath, failure: failure) != nil {
            return nil
        }
        let passes = outcome.failure == nil
        Self.baseAnswers.withLock { $0[key] = passes }
        return passes
    }

    /// What the base answered to a project-wide verify command, by project,
    /// tip and command. Process-wide because managers are made per call.
    private static let baseAnswers = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    /// A verify refusal's reason, extended to say the base fails it too.
    nonisolated static func baseAlsoFailsReason(_ reason: String, base: String, sha: String) -> String {
        let name = base.isEmpty ? "the base" : base
        return "\(reason) — the same command also fails on \(name) at \(sha.prefix(7)) with no diff on it, "
            + "so this failure is not caused by this branch alone; fix the base first"
    }

    /// Where a verified merge goes, settled before the scratch worktree exists
    /// so the refusals are cheap and the SHA the merge starts from is the one
    /// the landing is later compared against.
    private enum Landing {
        /// The checkout is on the base (or no base is named): merge from its
        /// `HEAD` and fast-forward it.
        case fastForwardCheckout(from: String)
        /// The base is a branch nothing has checked out: merge from its tip and
        /// move the ref, only if the tip is still `oldSHA` when the merge lands.
        case updateRef(base: String, oldSHA: String)
        case refused(MergeResult)

        var refusal: MergeResult? {
            if case .refused(let result) = self { return result }
            return nil
        }

        /// The commit the scratch worktree is checked out at — the base's tip.
        var startSHA: String {
            switch self {
            case .fastForwardCheckout(let sha), .updateRef(_, let sha): return sha
            case .refused: return ""
            }
        }
    }

    /// The three cases the doc comment on `mergeAndVerify` lists, in the order
    /// they have to be asked: "is the checkout on the base" first, because the
    /// checkout is itself a worktree that has the base checked out and must not
    /// be refused as "elsewhere". The scratch worktree this merge makes is never
    /// in the list — it doesn't exist yet, and it is detached besides.
    private func landing(for base: String?, branch: String, root: String) -> Landing {
        guard let base, currentBranchName() != base else {
            return checkoutLanding(branch: branch, root: root)
        }
        if let path = baseCheckedOutElsewhere(base, root: root) {
            return .refused(MergeResult(
                merged: false,
                reason: "base branch \(base) is checked out at \(path); merge there or remove that worktree"))
        }
        let tip = runGit(["-C", root, "rev-parse", "--verify", "--quiet", "refs/heads/\(base)"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tip.isEmpty else {
            return .refused(MergeResult(
                merged: false, reason: "base branch \(base) does not exist in this repository"))
        }
        return .updateRef(base: base, oldSHA: tip)
    }

    /// Landing on the checkout itself: the overlap precheck applies, since the
    /// fast-forward writes the checkout's tree — see `mergeRefusal`.
    private func checkoutLanding(branch: String, root: String) -> Landing {
        if let refusal = precheckOverlapRefusal(branch: branch, root: root) {
            return .refused(MergeResult(merged: false, reason: refusal))
        }
        let preSHA = runGit(["-C", root, "rev-parse", "HEAD"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preSHA.isEmpty else {
            return .refused(MergeResult(merged: false, reason: "could not read the checkout's HEAD"))
        }
        return .fastForwardCheckout(from: preSHA)
    }

    /// The path of a worktree of this repository that has `base` checked out,
    /// or nil when none has. Read off `git worktree list --porcelain`, which
    /// lists the main checkout too — the caller has already ruled that one out
    /// by asking `currentBranchName()` first.
    private func baseCheckedOutElsewhere(_ base: String, root: String) -> String? {
        let list = runGit(["-C", root, "worktree", "list", "--porcelain"])
        guard list.status == 0 else { return nil }
        return Self.worktreePath(holding: base, in: list.output)
    }

    /// The `worktree <path>` of the porcelain block whose `branch` line names
    /// `refs/heads/<branch>`. Blocks are blank-line separated; a detached
    /// worktree has no `branch` line and never matches.
    nonisolated static func worktreePath(holding branch: String, in porcelain: String) -> String? {
        let wanted = "branch refs/heads/\(branch)"
        for block in porcelain.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard lines.contains(wanted),
                  let header = lines.first(where: { $0.hasPrefix("worktree ") }) else { continue }
            return String(header.dropFirst("worktree ".count))
        }
        return nil
    }

    /// The last step, by landing case: the checkout is fast-forwarded, or the
    /// base ref is moved under nobody's checkout.
    private func landMerge(
        _ landing: Landing, root: String, scratchPath: String, ran: [String], reason: String,
        stepOutputs: [VerifyStepOutput]
    ) -> MergeResult {
        switch landing {
        case .fastForwardCheckout:
            return fastForwardCheckout(root: root, scratchPath: scratchPath, ran: ran, reason: reason,
                                       stepOutputs: stepOutputs)
        case .updateRef(let base, let oldSHA):
            return updateBaseRef(base, oldSHA: oldSHA, root: root, scratchPath: scratchPath,
                                 ran: ran, reason: reason, stepOutputs: stepOutputs)
        case .refused(let result):
            return result
        }
    }

    /// Moves `refs/heads/<base>` to the scratch worktree's merge commit — but
    /// only if it is still at `oldSHA`, the tip the merge was built and
    /// verified on. `update-ref <ref> <new> <old>` is git's compare-and-swap:
    /// a base that advanced while the verify ran is refused rather than
    /// overwritten, because the tree that was verified is not the tree the
    /// ref would then describe. The checkout is not touched — `landing(for:)`
    /// already established nothing has the base checked out.
    private func updateBaseRef(
        _ base: String, oldSHA: String, root: String, scratchPath: String, ran: [String], reason: String,
        stepOutputs: [VerifyStepOutput]
    ) -> MergeResult {
        let mergeSHA = runGit(["-C", scratchPath, "rev-parse", "HEAD"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let update = runGit(["-C", root, "update-ref", "-m", "kiteloop: \(reason)",
                             "refs/heads/\(base)", mergeSHA, oldSHA])
        guard update.status == 0 else {
            return MergeResult(
                merged: false,
                reason: "could not move base branch \(base) onto the merge: its tip moved from "
                    + "\(oldSHA.prefix(7)) while the merge was verified: " + Self.oneLineGitOutput(update.output),
                verifyRan: ran)
        }
        return MergeResult(merged: true, reason: reason, verifyRan: ran, stepOutputs: stepOutputs,
                           mergeCommit: mergeSHA)
    }

    /// The precheck's answer: nil when the checkout is clean, or dirty in a way
    /// that doesn't overlap what `branch` would bring in. See `mergeRefusal`.
    private func precheckOverlapRefusal(branch: String, root: String) -> String? {
        let status = runGit(["-C", root, "status", "--porcelain"]).output
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Self.mergeRefusal(porcelain: status, incoming: incomingPaths(from: branch))
    }

    /// Checks out a detached scratch worktree at `preSHA` for the merge to
    /// happen in. `nil` on success; a `MergeResult` naming git's own refusal
    /// otherwise (its own directory already exists and won't clear, disk full,
    /// and the like).
    private func createScratchWorktree(at scratchPath: String, from preSHA: String, root: String) -> MergeResult? {
        let fm = FileManager.default
        let scratchRoot = Self.scratchRootDir(projectRoot: projectRoot)
        if !fm.fileExists(atPath: scratchRoot.path(percentEncoded: false)) {
            try? fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        }
        let add = runGit(["-C", root, "worktree", "add", "--detach", scratchPath, preSHA])
        guard add.status == 0 else {
            return MergeResult(
                merged: false,
                reason: "could not create a scratch worktree to merge into: \(Self.oneLineGitOutput(add.output))")
        }
        return nil
    }

    /// Merges `branch` into the scratch worktree at `scratchPath`. `nil` on a
    /// clean merge; the conflicting paths, with the scratch merge already
    /// rolled back, otherwise — nothing to roll back in the checkout, since
    /// the checkout was never touched.
    private func conflictingMerge(_ branch: String, message: String, scratchPath: String) -> [String]? {
        let merge = runGit(["-C", scratchPath, "merge", "--no-ff", "-m", message, branch])
        guard merge.status != 0 else { return nil }
        let conflicted = runGit(["-C", scratchPath, "diff", "--name-only", "--diff-filter=U", "-z"])
        let paths = conflicted.status == 0
            ? conflicted.output.components(separatedBy: "\0").filter { !$0.isEmpty }
            : []
        _ = runGit(["-C", scratchPath, "merge", "--abort"])
        return paths
    }

    /// The one recovery `mergeAndVerify` tries before a conflict is final: see
    /// the doc comment there for why this can succeed where the plain merge
    /// just failed. `nil` means the retried merge landed in `scratchPath` and
    /// the caller should carry on to `verify` as if nothing had gone wrong;
    /// otherwise the `MergeResult` to return as-is.
    ///
    /// Every failure path here — the branch has vanished, the rebase worktree
    /// can't be created, the rebase itself conflicts, the ref move loses a
    /// race — reports the *original* conflict, because that is still the true
    /// reason nothing landed; only a rebase that itself conflicts adds to that
    /// sentence, since only then did the recovery attempt leave a trace worth
    /// naming. `refs/heads/<branch>` is never touched until the rebase
    /// worktree proves the rebase clean, so every one of those paths leaves
    /// the branch exactly where it started.
    private func rebaseThenRetryMerge(
        branch: String, message: String, ontoSHA: String, scratchPath: String, root: String,
        conflictPaths: [String], timeout: TimeInterval, setupCommand: String?
    ) -> MergeResult? {
        let originalRefusal = MergeResult(merged: false, reason: Self.conflictRefusal(paths: conflictPaths))
        let preRebaseTip = runGit(["-C", root, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preRebaseTip.isEmpty else { return originalRefusal }

        let rebaseScratch = Self.scratchWorktreeDirectory(forBranch: "\(branch)-rebase", projectRoot: projectRoot)
        removeScratchWorktree(at: rebaseScratch)
        defer { removeScratchWorktree(at: rebaseScratch) }
        let rebaseScratchPath = rebaseScratch.path(percentEncoded: false)

        let add = runGit(["-C", root, "worktree", "add", "--detach", rebaseScratchPath, preRebaseTip])
        guard add.status == 0 else { return originalRefusal }
        if let failure = Self.runSetupCommand(setupCommand, in: rebaseScratch, timeout: timeout,
                                              projectRoot: projectRoot) {
            return failure
        }

        let rebase = runGit(["-C", rebaseScratchPath, "rebase", ontoSHA])
        guard rebase.status == 0 else {
            _ = runGit(["-C", rebaseScratchPath, "rebase", "--abort"])
            return MergeResult(merged: false, reason: Self.conflictRefusal(
                paths: conflictPaths, rebaseAlsoConflicted: true))
        }

        let rebasedTip = runGit(["-C", rebaseScratchPath, "rev-parse", "HEAD"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rebasedTip.isEmpty else { return originalRefusal }
        let update = runGit(["-C", root, "update-ref", "-m", "kiteloop: rebased onto current base before merge",
                             "refs/heads/\(branch)", rebasedTip, preRebaseTip])
        guard update.status == 0 else { return originalRefusal }

        guard let retryPaths = conflictingMerge(branch, message: message, scratchPath: scratchPath) else {
            return nil
        }
        return MergeResult(merged: false, reason: Self.conflictRefusal(paths: retryPaths))
    }

    /// What ran `verify`'s steps against the scratch worktree left behind: the
    /// labels of every step that got to run, in order, and either the reason a
    /// retried-but-still-red one was refused (`failure`, which already carries
    /// `verifyRan`) or the note that one of them needed a retry and cleared it
    /// (`recoveredReason`, read by the caller once the fast-forward succeeds).
    private struct VerifyRunOutcome {
        var ran: [String] = []
        var recoveredReason: String?
        var stepOutputs: [VerifyStepOutput] = []
        var failure: MergeResult?
        /// The step `failure` is about, and whether the deadline — rather than
        /// the command — is what ended it. What `attributingToBase` asks with.
        var failedStep: MergeVerifyPlan.Step?
        var failureTimedOut = false
    }

    /// A retried step is given exactly one second try. Named once so
    /// `VerifyStepOutput.totalAttempts` and the note it renders always agree
    /// on "out of how many" — this item does not change how many retries a
    /// step gets, only what is kept about them.
    private static let attemptsPerRetriedStep = 2

    /// How many trailing lines of a kept verify step's output travel with the
    /// ledger row and the item's `## Notes` — enough to show what failed
    /// without the full `verifyOutputTailBytes` capture bloating a note meant
    /// to be read at a glance.
    static let verifyStepOutputNoteLines = 40

    /// The last `verifyStepOutputNoteLines` lines of `output` — the bound a
    /// kept step output travels with, distinct from `verifyOutputTailBytes`'s
    /// byte cap on the raw capture this is trimmed from.
    private nonisolated static func noteTail(_ output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(verifyStepOutputNoteLines)
            .joined(separator: "\n")
    }

    /// The record to keep for a step that ended in failure — its own attempt
    /// (1 of 1 when nothing was retried, 2 of 2 when a retry was spent and
    /// still failed) — or `nil` when there is nothing worth keeping: a
    /// command killed at its deadline with nothing printed yet leaves no
    /// output to show.
    private nonisolated static func failedAttemptRecord(
        step: MergeVerifyPlan.Step, output: String, retriedClass: VerifyFailureClass?
    ) -> VerifyStepOutput? {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let attempt = retriedClass == nil ? 1 : attemptsPerRetriedStep
        return VerifyStepOutput(stepLabel: step.label, attempt: attempt, totalAttempts: attempt,
                                recovered: false, output: noteTail(output))
    }

    /// The record to keep for a step that failed once and passed on its
    /// retry — the first attempt's output, since that is the one that failed;
    /// `nil` when it printed nothing.
    private nonisolated static func recoveredAttemptRecord(
        step: MergeVerifyPlan.Step, firstOutput: String?
    ) -> VerifyStepOutput? {
        guard let firstOutput, !firstOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return VerifyStepOutput(stepLabel: step.label, attempt: 1, totalAttempts: attemptsPerRetriedStep,
                                recovered: true, output: noteTail(firstOutput))
    }

    private nonisolated static func runVerifySteps(
        _ verify: MergeVerifyPlan, workingDirectory: URL, timeout: TimeInterval, projectRoot: URL?
    ) -> VerifyRunOutcome {
        var outcome = VerifyRunOutcome()
        for step in verify.steps {
            let (result, retriedClass, firstOutput) = runStepWithRetry(
                step, workingDirectory: workingDirectory, timeout: timeout, projectRoot: projectRoot)
            outcome.ran.append(step.label)
            guard result.ok else {
                // The step is named in the reason, not just in `verifyRan`: this
                // string is what reaches the operator at the gate, the control
                // API's refusal payload and the next run's rejection note, and
                // "which of the two failed" is the first thing each of them asks.
                //
                // So is *how* it failed. A command killed at the deadline never
                // reported anything about the diff, and one that printed nothing
                // before it was killed leaves an empty `verifyOutput` the payload
                // then omits — so this string is the only place "the build never
                // finished" can be told apart from "the build failed".
                let reason = retriedClass.map {
                    verifyRetryReason(step: step, failureClass: $0, recovered: false)
                } ?? verifyRefusal(step: step, timedOut: result.timedOut, timeout: timeout)
                if let record = failedAttemptRecord(step: step, output: result.output, retriedClass: retriedClass) {
                    outcome.stepOutputs.append(record)
                }
                outcome.failure = MergeResult(merged: false, reason: reason,
                                              verifyOutput: result.output, verifyRan: outcome.ran,
                                              stepOutputs: outcome.stepOutputs)
                outcome.failedStep = step
                outcome.failureTimedOut = result.timedOut
                return outcome
            }
            if let retriedClass {
                outcome.recoveredReason = verifyRetryReason(
                    step: step, failureClass: retriedClass, recovered: true)
                if let record = recoveredAttemptRecord(step: step, firstOutput: firstOutput) {
                    outcome.stepOutputs.append(record)
                }
            }
        }
        return outcome
    }

    /// The last step: fast-forwards the checkout's branch onto the scratch
    /// worktree's merge commit. This is the one place the checkout is touched,
    /// and git itself is what enforces the overlap rule the precheck already
    /// checked — it refuses the same way for the same reason if something
    /// changed the checkout in between.
    private func fastForwardCheckout(
        root: String, scratchPath: String, ran: [String], reason: String, stepOutputs: [VerifyStepOutput]
    ) -> MergeResult {
        let mergeSHA = runGit(["-C", scratchPath, "rev-parse", "HEAD"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fastForward = runGit(["-C", root, "merge", "--ff-only", mergeSHA])
        guard fastForward.status == 0 else {
            return MergeResult(
                merged: false,
                reason: "could not fast-forward the checkout onto the merge: "
                    + Self.oneLineGitOutput(fastForward.output),
                verifyRan: ran)
        }
        return MergeResult(merged: true, reason: reason, verifyRan: ran, stepOutputs: stepOutputs,
                           mergeCommit: mergeSHA)
    }

    /// The `## Notes` line a landed merge writes: the commit the work became
    /// on the base, so "did this item's work land" is answered by git —
    /// `git merge-base --is-ancestor <commit> <base>` — and never by the
    /// status alone. On 2026-09-12 an item read Done with its branch never
    /// merged and no record either way; this is the record.
    nonisolated static func landedNote(commit: String, base: String?) -> String {
        let target = base ?? "the checkout's branch"
        return "Landed: merged as \(commit.prefix(12)) into \(target)"
    }

    /// Where every scratch merge-gate worktree for a project lives —
    /// deliberately **not** `.kiteloop/worktrees/`, the directory `sweep`
    /// (and `StrandedWorkSweep.read`) walk. The instant `mergeAndVerify`
    /// commits the merge into it, a scratch worktree has a clean tree and no
    /// branch of its own — exactly the shape `orphanVerdict` calls `.reap`
    /// — so if it lived where `sweep` looks, a sweep landing while the
    /// gate's verify was still running could reap the directory out from
    /// under it. A directory `sweep` never lists is what makes a scratch
    /// worktree's lifetime "as long as its own gate, and nothing else."
    private nonisolated static func scratchRootDir(projectRoot: URL) -> URL {
        projectRoot.appending(path: ".kiteloop/merge-gate-scratch")
    }

    /// Where the scratch worktree for one merge attempt lives, under a key
    /// derived from the branch so it can never collide with a sibling gate's.
    private nonisolated static func scratchWorktreeDirectory(
        forBranch branch: String, projectRoot: URL
    ) -> URL {
        let key = branch.hasPrefix("kiteloop/") ? String(branch.dropFirst("kiteloop/".count)) : branch
        return scratchRootDir(projectRoot: projectRoot).appending(path: "\(key)-merge-gate")
    }

    /// When a verify step failed only because the scratch worktree itself is
    /// gone — something else removed it while the gate was still running —
    /// the step's own output is a `cd: No such file or directory` or a
    /// Docker "path not found", which reads like the diff is broken when
    /// nothing about it was ever checked. Named here instead: `nil` when the
    /// directory is still there, so an ordinary verify failure is untouched.
    private nonisolated static func scratchRemovedResult(
        at scratchPath: String, failure: MergeResult
    ) -> MergeResult? {
        guard !FileManager.default.fileExists(atPath: scratchPath) else { return nil }
        return MergeResult(
            merged: false,
            reason: "the scratch worktree at \(scratchPath) was removed while verify was still "
                  + "running — not a verify failure",
            verifyOutput: failure.verifyOutput, verifyRan: failure.verifyRan, stepOutputs: failure.stepOutputs)
    }

    /// Force-removes the scratch worktree at `path`, whatever verify left dirty
    /// in it and whether the merge that used it succeeded or not. There is no
    /// branch to keep here — the worktree is checked out detached, so the only
    /// trace of the attempt worth keeping is what `MergeResult` already carries.
    private func removeScratchWorktree(at path: URL) {
        WorktreeBuildOutput.release(for: path)
        _ = runGit(["worktree", "remove", "--force", path.path(percentEncoded: false)])
        if FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// git's own refusal, flattened to one line for a `MergeResult.reason` — the
    /// two-attempt merge/verify above only fails this way on the scratch-worktree
    /// setup and the final fast-forward, both of which are rare enough that this
    /// doesn't need `WorktreeError`'s length cap.
    private nonisolated static func oneLineGitOutput(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// Runs one verify step, retrying it once when the first attempt fails in
    /// a way `classifyVerifyFailure` recognizes as not necessarily about the
    /// diff. `retriedClass` is `nil` unless a retry happened, so the caller can
    /// tell a step that simply passed from one that passed on its second try.
    ///
    /// A step killed at its own deadline is never retried — an overrun said
    /// nothing about the tree either time, so a second attempt would just wait
    /// out the same clock again.
    private nonisolated static func runStepWithRetry(
        _ step: MergeVerifyPlan.Step,
        workingDirectory: URL,
        timeout: TimeInterval,
        projectRoot: URL?
    ) -> (result: (ok: Bool, output: String, timedOut: Bool), retriedClass: VerifyFailureClass?,
          firstAttemptOutput: String?) {
        let command = gateCommand(step.command, projectRoot: workingDirectory)
        let first = runShellCapturingOutput(command, in: workingDirectory, timeout: timeout,
                                            projectRoot: projectRoot)
        guard !first.ok, !first.timedOut,
              let failureClass = classifyVerifyFailure(first.output) else {
            return (first, nil, nil)
        }
        let second = runShellCapturingOutput(command, in: workingDirectory, timeout: timeout,
                                             projectRoot: projectRoot)
        return (second, failureClass, first.output)
    }

    /// The reason string for a step that needed a retry — the same "which
    /// step, in what way" shape as `verifyRefusal`, with the class and whether
    /// the retry cleared it. `recovered` isn't a refusal (`MergeResult.merged`
    /// says so); it's the sentence that explains why a merge that looked red
    /// at first still went through.
    nonisolated static func verifyRetryReason(
        step: MergeVerifyPlan.Step,
        failureClass: VerifyFailureClass,
        recovered: Bool
    ) -> String {
        let note = recovered ? failureClass.recoveredNote : failureClass.refusedTwiceNote
        return "verify failed on merged tree (\(step.label)) — \(note)"
    }

    /// Classifies a failing verify step's captured output as something worth
    /// one retry, or `nil` when it names nothing the gate recognizes — the "as
    /// today" case that's refused without a second attempt.
    ///
    /// A crash signature is checked first: a crashed test binary's harness
    /// often also prints a failed-test line for whatever it was running when
    /// it went down, and the crash is the more specific answer.
    nonisolated static func classifyVerifyFailure(_ output: String) -> VerifyFailureClass? {
        for signal in ["SIGSEGV", "SIGABRT", "signal: 11"] where output.contains(signal) {
            return .crash(signal: signal)
        }
        let lockPhrases = ["waiting for lock", "could not acquire lock",
                            "lock timeout", "resource temporarily unavailable"]
        for phrase in lockPhrases where output.range(of: phrase, options: .caseInsensitive) != nil {
            return .lockTimeout
        }
        guard let name = failedTestName(in: output) else { return nil }
        return .testFailure(name: name)
    }

    /// The first line naming a failed test, jest-style (`FAIL <path>`) or
    /// XCTest-style (`Test Case '-[Suite testName]' failed`) — whichever shape
    /// the verify command's output happens to use. `nil` when neither is
    /// there.
    ///
    /// The jest shape is a *file*: one space, then a path. `quality/bin/gate.py`
    /// prints its own rows as `  FAIL  escapes` — two spaces and a gate name —
    /// and the bare prefix read that as a failed test, retried a deterministic
    /// gate, and refused it as "flaky". A gate's verdict is not a test's.
    private nonisolated static func failedTestName(in output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let path = jestFailedPath(in: trimmed) { return path }
            if trimmed.hasPrefix("Test Case '"), trimmed.contains("' failed") {
                return String(trimmed.dropFirst("Test Case '".count).prefix { $0 != "'" })
            }
        }
        return nil
    }

    /// `FAIL src/b.test.tsx` → `src/b.test.tsx`; nil for anything after the
    /// prefix that is not a single path-like token (a directory separator or
    /// an extension in it, and no second space before it).
    private nonisolated static func jestFailedPath(in line: String) -> String? {
        guard line.hasPrefix("FAIL ") else { return nil }
        let rest = String(line.dropFirst("FAIL ".count))
        guard !rest.hasPrefix(" "),
              let token = rest.split(separator: " ", maxSplits: 1).first,
              token.contains("/") || token.contains(".") else { return nil }
        return String(token)
    }

    /// Why a merge-verify step refused, in one line: which step, and whether it
    /// failed on its own or was killed at the deadline having never finished.
    ///
    /// The seconds are named rather than left implicit — an operator reading
    /// "timed out" wants to know whether the command was given 15 minutes or 15
    /// seconds before deciding it is stuck rather than slow.
    nonisolated static func verifyRefusal(
        step: MergeVerifyPlan.Step,
        timedOut: Bool,
        timeout: TimeInterval
    ) -> String {
        guard timedOut else { return "verify failed on merged tree (\(step.label))" }
        return "verify timed out after \(Int(timeout.rounded()))s on merged tree (\(step.label))"
    }

    // MARK: - The base's own health

    /// What the project's merge-verify said about the base tip itself, with
    /// no item's diff on it.
    struct BaseVerdict: Equatable, Sendable {
        let sha: String
        let ok: Bool
        /// The refusal, in the gate's own words, when not ok.
        let reason: String?
    }

    /// The commit `ref` resolves to in the project root, or nil when it does
    /// not resolve.
    func tipSHA(of ref: String) -> String? {
        let root = projectRoot.path(percentEncoded: false)
        let resolved = runGit(["-C", root, "rev-parse", "--verify", "--quiet", ref])
        guard resolved.status == 0 else { return nil }
        let sha = resolved.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Runs `command` on the base tip in a scratch worktree, exactly the way
    /// the merge gate runs it on a merged tree — same setup command, same
    /// deadline, same retry classes. Nil when the base cannot be resolved.
    ///
    /// The gate refuses every merge for a base that is already red, and on
    /// 2026-09-12 a stale baseline on the base was attributed, refusal by
    /// refusal, to 24 items in turn. Asked once with no diff on the tree, the
    /// answer belongs to the base and is said once.
    func verifyBase(command: String, base: String?, timeout: TimeInterval,
                    setupCommand: String?) -> BaseVerdict? {
        let root = projectRoot.path(percentEncoded: false)
        guard let sha = tipSHA(of: base.map { "refs/heads/\($0)" } ?? "HEAD") else { return nil }
        let scratch = Self.scratchWorktreeDirectory(forBranch: "base-health", projectRoot: projectRoot)
        removeScratchWorktree(at: scratch)
        defer { removeScratchWorktree(at: scratch) }
        if let failure = createScratchWorktree(at: scratch.path(percentEncoded: false), from: sha, root: root) {
            return BaseVerdict(sha: sha, ok: false, reason: failure.reason)
        }
        if let failure = Self.runSetupCommand(setupCommand, in: scratch, timeout: timeout, projectRoot: projectRoot) {
            return BaseVerdict(sha: sha, ok: false, reason: failure.reason)
        }
        let plan = MergeVerifyPlan(steps: [MergeVerifyPlan.Step(source: .project, command: command)])
        let outcome = Self.runVerifySteps(plan, workingDirectory: scratch, timeout: timeout, projectRoot: projectRoot)
        // A scratch checkout that vanished under the command — a second check
        // clearing it, a sweep — answered nothing about the base. Unknown, not
        // red: a red verdict here would refuse every start until the tip moves.
        if let failure = outcome.failure,
           Self.scratchRemovedResult(at: scratch.path(percentEncoded: false), failure: failure) != nil {
            return nil
        }
        return BaseVerdict(sha: sha, ok: outcome.failure == nil, reason: outcome.failure?.reason)
    }

    // MARK: - A finished branch, checked out to check

    /// Why `checkOutScratch` has no tree to hand back.
    struct ScratchCheckoutFailure: Error, Equatable {
        let reason: String
    }

    /// `branch`'s tip checked out, detached, into a scratch worktree of its
    /// own, with the project's setup command run in it — the tree a check the
    /// run's own worktree can no longer answer runs in. A finished run's
    /// teardown removes its worktree and keeps the branch, so after teardown
    /// the branch is the run's tree. Detached, so the branch is never moved,
    /// and never in the way of a later `reopen` of it. The caller removes it
    /// with `removeScratchCheckout` once the check has answered.
    func checkOutScratch(
        of branch: String, setupCommand: String?, timeout: TimeInterval
    ) -> Result<URL, ScratchCheckoutFailure> {
        let root = projectRoot.path(percentEncoded: false)
        guard let sha = tipSHA(of: "refs/heads/\(branch)") else {
            return .failure(ScratchCheckoutFailure(reason: "branch \(branch) could not be resolved to check out"))
        }
        let scratch = Self.scratchWorktreeDirectory(forBranch: "\(branch)-check", projectRoot: projectRoot)
        removeScratchWorktree(at: scratch)
        if let failure = createScratchWorktree(at: scratch.path(percentEncoded: false), from: sha, root: root)
            ?? Self.runSetupCommand(setupCommand, in: scratch, timeout: timeout, projectRoot: projectRoot) {
            removeScratchWorktree(at: scratch)
            return .failure(ScratchCheckoutFailure(reason: failure.reason))
        }
        return .success(scratch)
    }

    /// Removes a tree `checkOutScratch` handed out, and its build output.
    func removeScratchCheckout(_ path: URL) {
        removeScratchWorktree(at: path)
    }

    /// Runs the project's `worktreeSetupCommand` in a scratch worktree just
    /// after it is checked out and before anything else touches it — `nil`
    /// when there is nothing configured (today's behaviour) or the command
    /// exits clean, the refusal otherwise.
    ///
    /// Wrapped in `gateCommand` against `directory` first, the same shell
    /// shape a verify step already runs under (`runStepWithRetry`) and the
    /// one the worker's own `WorktreeSession` now wraps its setup command in
    /// too, so the same `worktreeSetupCommand` setting behaves identically
    /// wherever it runs.
    ///
    /// Not a verify step: it never appears in `verifyRan` or
    /// `MergeVerifyPlan.summary`, so "item verify + merge-verify" still names
    /// only the two things that actually check the work — this only makes
    /// sure a cold tree can run them at all. Never retried, unlike a
    /// classified verify failure: a setup command that failed once answered
    /// nothing about the diff either way.
    private nonisolated static func runSetupCommand(
        _ command: String?, in directory: URL, timeout: TimeInterval, projectRoot: URL?
    ) -> MergeResult? {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let shellCommand = gateCommand(command, projectRoot: directory)
        let result = runShellCapturingOutput(shellCommand, in: directory, timeout: timeout, projectRoot: projectRoot)
        guard !result.ok else { return nil }
        let reason = result.timedOut
            ? "setup timed out after \(Int(timeout.rounded()))s in merged tree (\(command))"
            : "setup failed in merged tree (\(command))"
        return MergeResult(merged: false, reason: reason, verifyOutput: result.output)
    }

    /// A read-only verdict on whether an item's branch still merges cleanly onto
    /// the project's current base — found with `git merge-tree --write-tree`,
    /// which writes no ref and checks nothing out, so asking again after every
    /// sibling's merge costs nothing.
    struct BranchFreshness: Equatable, Sendable {
        var clean: Bool
        /// The paths git could not merge cleanly. Empty when `clean`; also empty
        /// when the probe itself could not be answered (unreadable repo, no
        /// common history) — that reads as `clean: false` with nothing named,
        /// the same conservative default `hasUnmergedCommits` and its neighbours
        /// take, so a git nobody could ask never reads as a branch that is fine.
        var conflicts: [String]
        var checkedAt: Date
        /// The branch's commit this verdict was computed against. A caller
        /// trusting a cached conflict compares this against the branch's live
        /// tip (`branchTip(for:)`) first — a rebase or any other commit to the
        /// branch since moves the tip without this cache knowing, and a verdict
        /// computed against a tip the branch has left behind is not a verdict
        /// about the branch as it stands now.
        var branchTip: String

        init(clean: Bool, conflicts: [String] = [], checkedAt: Date = Date(), branchTip: String = "") {
            self.clean = clean
            self.conflicts = conflicts
            self.checkedAt = checkedAt
            self.branchTip = branchTip
        }
    }

    /// Whether `branch` still merges cleanly onto `base`. Run directly against
    /// the project's object database — no scratch worktree the way
    /// `mergeAndVerify` needs one, because `merge-tree` never touches a
    /// checkout at all.
    func checkFreshness(branch: String, against base: String = "HEAD") -> BranchFreshness {
        let root = projectRoot.path(percentEncoded: false)
        let tip = runGit(["-C", root, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = runGit(["-C", root, "merge-tree", "--write-tree", base, branch])
        switch result.status {
        case 0: return BranchFreshness(clean: true, branchTip: tip)
        case 1: return BranchFreshness(clean: false, conflicts: Self.conflictingPaths(in: result.output), branchTip: tip)
        default: return BranchFreshness(clean: false, branchTip: tip)
        }
    }

    /// The commit an item's branch points at right now — cheap next to
    /// `checkFreshness`'s `merge-tree`, so a cached verdict can be told apart
    /// from a stale one (the branch has since moved, by a rebase or any other
    /// commit) without re-running the merge probe on every approval. Empty
    /// when the branch cannot be read.
    func branchTip(for key: String) -> String {
        let root = projectRoot.path(percentEncoded: false)
        let branch = "refs/heads/\(WorktreeSession.branchName(for: key))"
        return runGit(["-C", root, "rev-parse", "--verify", "--quiet", branch]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The paths named on `merge-tree --write-tree`'s conflict stage lines
    /// (`<mode> <oid> <stage>\t<path>`), deduplicated in the order they first
    /// appear — a path shows up once per conflicting stage. Any other line
    /// (the tree OID, a diagnostic like "CONFLICT (content): …") simply
    /// doesn't match and is skipped.
    nonisolated static func conflictingPaths(in mergeTreeOutput: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for line in mergeTreeOutput.components(separatedBy: .newlines) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let head = parts[0].split(separator: " ")
            guard head.count == 3, ["1", "2", "3"].contains(String(head[2])) else { continue }
            let path = String(parts[1])
            guard seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
    }

    /// The paths merging `branch` would write, read from its diff against the
    /// merge base — the set an untracked file has to be in to actually be in the
    /// merge's way. `nil` if git couldn't answer (no merge base, unreadable repo),
    /// which the caller reads as "assume every untracked path collides".
    private func incomingPaths(from branch: String) -> [String]? {
        let root = projectRoot.path(percentEncoded: false)
        // `-z` so a path with a space or a quote comes back verbatim instead of
        // C-quoted; three-dot so the set is what the branch added since it forked,
        // not what HEAD has moved on to since.
        let result = runGit(["-C", root, "diff", "--name-only", "-z", "HEAD...\(branch)"])
        guard result.status == 0 else { return nil }
        return result.output.components(separatedBy: "\0").filter { !$0.isEmpty }
    }

    /// Runs `command` inside the item's worktree; true on exit code 0. Used to
    /// re-check the objective bar on a run that ended early (cost cap, stall,
    /// retry ceiling) before its work is discarded. False if there is no worktree.
    func runVerify(for key: String, command: String) -> Bool {
        let path = worktreesDir.appending(path: key)
        guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) else { return false }
        return Self.runShell(WorktreeBuildOutput.redirectingBuilds(in: command, worktree: path), in: path,
                             projectRoot: projectRoot)
    }

    /// Runs `command` under zsh in `directory`; true on exit code 0. Static so the
    /// salvage re-check can run an item's verify inside that item's own worktree.
    ///
    /// A `timeout` bounds a hang: past it the process is killed and the verify
    /// fails (so a stuck merge-verify can't freeze an unattended run).
    ///
    /// `projectRoot` is whose `extraExecutablePaths` and build exports the
    /// command runs with; nil for a command on behalf of no project.
    nonisolated static func runShell(
        _ command: String,
        in directory: URL,
        timeout: TimeInterval = 900,
        projectRoot: URL? = nil
    ) -> Bool {
        runShellCapturingOutput(command, in: directory, timeout: timeout, projectRoot: projectRoot).ok
    }

    /// The tail of a captured verify log that gets kept: enough to hold an
    /// xcodebuild failure's error lines and the summary under them, small enough
    /// to sit in a popover and in a backlog note.
    static let verifyOutputTailBytes = 16_384

    /// Runs `command` under zsh in `directory` and returns its exit status along
    /// with the tail of its combined stdout+stderr, and whether the deadline is
    /// what ended it.
    ///
    /// `timedOut` is carried rather than folded into `ok` because the poll loop
    /// underneath already knows the difference and every reader downstream needs
    /// it: a command killed at the deadline judged nothing about the tree, and a
    /// killed command that printed nothing leaves no output to say so either.
    ///
    /// Output goes to a temporary file — NOT a `Pipe()` — because an undrained
    /// pipe fills its ~64 KB buffer on a verbose command (e.g. xcodebuild), the
    /// child blocks writing, and `waitUntilExit()` hangs forever. A file has no
    /// such limit, and reading only its tail afterwards keeps a 200 MB build log
    /// from becoming a 200 MB string. The file is deleted either way.
    /// The step's command with every `xcodebuild` in it pointed at the gate's
    /// own DerivedData (`<root>/.kiteloop/DerivedData`), the way a worker's
    /// builds already are in its worktree (`WorktreeBuildOutput`).
    ///
    /// The default DerivedData is shared with the Xcode that launched the app,
    /// and a build there reused Xcode's package products instead of recompiling
    /// them: on 2026-08-25 `KiteloopCore.o` stayed at its 04:16 launch stamp
    /// through every gate build after it, so a branch that changed a package
    /// type compiled against the old one and was refused for a call that did
    /// not exist — while the same tree built clean with a fresh DerivedData.
    /// A verdict from the gate has to come from the tree it merged, not from
    /// whatever the IDE last built.
    nonisolated static func gateCommand(_ command: String, projectRoot: URL) -> String {
        WorktreeBuildOutput.redirectingBuilds(in: command, worktree: projectRoot)
    }

    ///
    /// The child's `PATH` is the app's composed search path
    /// (`ExecutableSearchPath`), exported explicitly rather than left to the
    /// login shell: `-l` reads `~/.zprofile` and not `~/.zshrc`, which is how
    /// a pip-installed `lizard` was invisible at the merge verify on 2026-09-03.
    /// Beside it ride the project's build exports (`BuildEnvironment`) — a
    /// `CARGO_TARGET_DIR` shared across item worktrees, so a verify in the
    /// scratch worktree finds the build the item's own run already paid for.
    /// The shell stays a login shell so everything else it sets up still is.
    nonisolated static func runShellCapturingOutput(
        _ command: String,
        in directory: URL,
        timeout: TimeInterval = 900,
        projectRoot: URL? = nil
    ) -> (ok: Bool, output: String, timedOut: Bool) {
        let result = runShellCapturingStatus(command, in: directory, timeout: timeout,
                                             projectRoot: projectRoot)
        return (result.status == 0, result.output, result.timedOut)
    }

    /// The status a verify wears when no process ever produced one: the shell
    /// could not be spawned, or the deadline killed it before it exited.
    /// Negative on purpose — no command can exit with it, so a record carrying
    /// it cannot be read as a real exit code.
    static let noExitStatus: Int32 = -1

    /// The same run as `runShellCapturingOutput`, reporting the child's exit
    /// **status** rather than only whether it was zero.
    ///
    /// The number is what an audit needs and what `ok` throws away: a verdict
    /// on the record has to say what the command answered, so `exit 1` and a
    /// command that was never spawned can be told apart afterwards
    /// (`RunVerifyVerdict`). `noExitStatus` covers both cases where there is no
    /// answer to report, and `timedOut` says which of them it was.
    nonisolated static func runShellCapturingStatus(
        _ command: String,
        in directory: URL,
        timeout: TimeInterval = 900,
        projectRoot: URL? = nil
    ) -> (status: Int32, output: String, timedOut: Bool) {
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "kiteloop-verify-\(UUID().uuidString).log")
        let path = logURL.path(percentEncoded: false)
        guard FileManager.default.createFile(atPath: path, contents: nil),
              let sink = try? FileHandle(forWritingTo: logURL) else {
            // No place to capture to is not a reason to skip the verify — run it
            // with the output discarded, exactly as this used to.
            let result = runShell(command, discardingOutputIn: directory, timeout: timeout,
                                  projectRoot: projectRoot)
            return (result.status, "", result.timedOut)
        }
        defer { try? FileManager.default.removeItem(at: logURL) }

        let process = verifyShell(command, in: directory, projectRoot: projectRoot)
        process.standardOutput = sink
        process.standardError = sink
        do { try process.run() } catch {
            try? sink.close()
            return (noExitStatus, "", false)
        }
        let result = wait(for: process, timeout: timeout)
        try? sink.close()
        let kept = tail(ofFileAt: logURL, maxBytes: verifyOutputTailBytes)
        // A failure's evidence is rarely at the end of a long log: the tail of
        // a test run is passing tests. A pass has nothing to look for.
        let output = result.status == 0 ? kept
            : VerifyFailureDigest.annotating(tail: kept, ofFileAt: logURL, tailBytes: verifyOutputTailBytes)
        return (result.status, output, result.timedOut)
    }

    /// The `/bin/zsh -lc` a verify runs under, in `directory`, with the
    /// composed `PATH` and the project's build exports in its environment
    /// (`RunEnvironment`) — the one way both capturing calls spawn it, so
    /// they cannot disagree about what the shell can see.
    private nonisolated static func verifyShell(_ command: String, in directory: URL,
                                                projectRoot: URL?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = directory
        process.environment = RunEnvironment.environment(projectRoot: projectRoot)
        return process
    }

    private nonisolated static func runShell(
        _ command: String,
        discardingOutputIn directory: URL,
        timeout: TimeInterval,
        projectRoot: URL?
    ) -> (status: Int32, timedOut: Bool) {
        let process = verifyShell(command, in: directory, projectRoot: projectRoot)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (noExitStatus, false) }
        return wait(for: process, timeout: timeout)
    }

    /// Polls until `process` exits or `timeout` passes, killing it in the latter
    /// case. `status` is the child's own exit status — 0 and only 0 is a pass —
    /// or `noExitStatus` for a process the deadline killed, which never reached
    /// one. `timedOut` says the deadline is what ended it, which is the one
    /// thing an exit status can no longer tell anyone afterwards.
    ///
    /// `process` is the shell, or whatever it exec'd into — signalling it alone
    /// does not reach anything that process forked, which TERM and KILL both
    /// leave running and reparented. So its descendants are collected *before*
    /// it's signalled, while the tree is still intact for `pgrep -P` to walk,
    /// and swept the same way (TERM, the same grace period, then KILL) once the
    /// root is down.
    private nonisolated static func wait(
        for process: Process,
        timeout: TimeInterval
    ) -> (status: Int32, timedOut: Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                let descendants = ProcessTree.descendantPIDs(of: process.processIdentifier)
                process.terminate()
                usleep(500_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                ProcessTree.killDescendants(descendants)
                return (noExitStatus, true)
            }
            usleep(200_000)
        }
        return (process.terminationStatus, false)
    }

    /// The last `maxBytes` of the file, decoded leniently and marked as cut when
    /// it was. Read by seeking rather than loading the file, so the size of a
    /// build log doesn't matter. A cut can land mid-line and mid-UTF-8-sequence;
    /// the partial first line is dropped and the decode is lossy.
    static func tail(ofFileAt url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let keep = UInt64(max(0, maxBytes))
        let start = size > keep ? size - keep : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        guard start > 0 else { return text }
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return "… (earlier output omitted — showing the last \(data.count) of \(size) bytes)\n" + text
    }

    @discardableResult
    private func runGit(_ args: [String]) -> (status: Int32, output: String) {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/usr/bin/git",
            arguments: args,
            directory: projectRoot,
            timeout: gitTimeout
        )
        return (result.status, result.output)
    }

    /// True if `url` is inside a git working tree.
    static func isGitRepository(at url: URL) -> Bool {
        // Only the exit status is read; the runner sends the output nowhere a
        // pipe nothing drains could block git on.
        SubprocessOutput.git(["-C", url.path(percentEncoded: false), "rev-parse", "--is-inside-work-tree"]).status == 0
    }
}

/// `LocalizedError` rather than a bare `Error`: `WorktreeSession.begin` puts
/// `localizedDescription` straight into the run log, and the default for an
/// enum is "The operation couldn't be completed. (Kiteloop.WorktreeError error
/// 2.)" — which tells a reader nothing about why their run lost its isolation.
enum WorktreeError: LocalizedError, Equatable {
    /// The item whose worktree could not be made, and what git said while
    /// refusing. Empty when git printed nothing or could not be started — the
    /// message is then the bare one this case always carried.
    case creationFailed(String, git: String = "")
    case destructionFailed(String)
    case notAGitRepository(String)
    /// The project's `worktreeSetupCommand` failed or timed out in a freshly
    /// created worktree — `reason` already names the command and carries the
    /// tail of what it printed (`WorktreeSession.runSetupCommand`).
    case setupFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let id, let git):
            let reason = Self.oneLine(git)
            return reason.isEmpty
                ? "could not create a worktree for \(id)"
                : "could not create a worktree for \(id): \(reason)"
        case .destructionFailed(let id):
            return "could not remove the worktree for \(id)"
        case .notAGitRepository(let path):
            return "\(path) is not a git repository"
        case .setupFailed(let reason):
            return reason
        }
    }

    /// git's refusal flattened onto one line: it answers in several ("fatal: …"
    /// under a hint, a usage block), and this goes inside the single
    /// `Worktree setup failed (…)` line `WorktreeSession.begin` writes. Capped
    /// so a git that answers at length can't take the run log with it.
    private static func oneLine(_ text: String, maxCharacters: Int = 400) -> String {
        let joined = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        guard joined.count > maxCharacters else { return joined }
        return String(joined.prefix(maxCharacters)) + "…"
    }
}
