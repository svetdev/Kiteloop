import Foundation
import KiteloopCore

/// One backlog item's isolated git worktree, from creation to teardown (ADR-0001).
///
/// Setup and teardown are two halves of one thing: they have to agree on the
/// branch name, the `WorktreeManager` and — critically — which agents were
/// pinned into the worktree and therefore have to be put back on the project
/// root afterwards. Holding that state in a session object is what keeps the
/// two halves from drifting apart, and lets a failed setup undo its own
/// half-done work instead of leaving an agent editing a worktree the run has
/// already abandoned.
///
/// A session exists only for an isolated run: `begin` returns nil when the item
/// runs in the live tree (isolation off, no project root, not a git repo, or
/// setup failed), so the caller's `session?.` is exactly "if we isolated".
@MainActor
final class WorktreeSession {
    /// The worktree directory the item's work happens in.
    let path: URL
    /// The branch the worktree is checked out on, e.g. `kiteloop/<item-id>`.
    let branch: String

    private let itemID: String
    private let projectRoot: URL
    /// The branch the run forked from and lands on, when the project names
    /// one — what teardown judges "does the branch hold anything" against.
    /// Judged against `HEAD` before 2026-09-20, which on a project whose
    /// checkout is not its base answered the wrong question: a branch with
    /// commits the base had never seen read as empty, or the reverse.
    private let baseBranch: String?
    private let manager: WorktreeManager
    private let orchestrator: Orchestrator
    /// The agents pinned into the worktree by `begin`, to be restored by `end`.
    private let agentIDs: [String]
    private let log: @MainActor (String) -> Void

    private init(
        path: URL,
        itemID: String,
        projectRoot: URL,
        baseBranch: String?,
        manager: WorktreeManager,
        orchestrator: Orchestrator,
        agentIDs: [String],
        log: @escaping @MainActor (String) -> Void
    ) {
        self.path = path
        self.branch = Self.branchName(for: itemID)
        self.itemID = itemID
        self.projectRoot = projectRoot
        self.baseBranch = baseBranch
        self.manager = manager
        self.orchestrator = orchestrator
        self.agentIDs = agentIDs
        self.log = log
    }

    /// The one place the autopilot's branch naming lives — teardown, merge and
    /// the run result all have to name the same ref.
    nonisolated static func branchName(for itemID: String) -> String {
        "kiteloop/\(itemID)"
    }

    /// The folder under a project root that holds every item's worktree.
    nonisolated static func worktreesRoot(projectRoot: URL) -> URL {
        projectRoot.appending(path: ".kiteloop/worktrees")
    }

    /// The one place an item's worktree directory lives — `WorktreeManager` and
    /// every reader of an interrupted or finished run's worktree have to agree
    /// on this path, the way they already agree on `branchName(for:)`.
    nonisolated static func worktreeDirectory(for key: String, projectRoot: URL) -> URL {
        worktreesRoot(projectRoot: projectRoot).appending(path: key)
    }

    // MARK: - Setup

    /// Whether an item can be run in an isolated worktree — and, when it can't,
    /// why. Split out of `begin` so the fallback rules can be tested without an
    /// orchestrator or live agents.
    enum Decision: Equatable {
        case isolate
        /// Run in the live tree; `reason` is the log line saying why.
        case liveTree(reason: String)
    }

    /// The live-tree fallback rules. Isolation is not a setting (ADR-0001): a
    /// git project always isolates, and only a project with nothing to isolate
    /// with runs in its own checkout. `isGitRepository` is injectable so a test
    /// doesn't need a real repo on disk.
    nonisolated static func decide(
        projectRoot: URL?,
        isGitRepository: (URL) -> Bool = { WorktreeManager.isGitRepository(at: $0) }
    ) -> Decision {
        guard let projectRoot else {
            return .liveTree(reason: "Worktree isolation skipped — no project root")
        }
        guard isGitRepository(projectRoot) else {
            return .liveTree(reason: "Worktree isolation skipped — not a git repository")
        }
        return .isolate
    }

    /// What `begin` settled on for this item.
    enum Setup {
        /// The item has a worktree of its own and its agents are in it.
        case isolated(WorktreeSession)
        /// The item runs in the project's own checkout, by one of the rules in
        /// `decide` — there is nothing to isolate with.
        case liveTree
        /// Isolation was asked for and could not be established. `reason` says
        /// what failed.
        ///
        /// Deliberately not a live-tree run. Falling back used to look like the
        /// forgiving choice, and it is the opposite: the caller asked for the
        /// project's checkout to be left alone, so a run that cannot honour
        /// that must not proceed against it. On 2026-08-11 two items were built
        /// straight into the main tree, uncommitted and interleaved with each
        /// other, while the branches they were supposed to be on stayed empty —
        /// and both reached the approval gate reading as ordinary finished work.
        case failed(String)
    }

    /// Creates the item's worktree and restarts `agentIDs` into it (their process
    /// cwd is fixed at spawn, so a fresh session per item is how they end up
    /// editing the worktree), then pins them there so nothing else can move
    /// them back to the project root mid-item.
    ///
    /// `baseBranch` is the project's setting of that name: the worktree forks
    /// from the local `refs/heads/<name>` when there is one, from the
    /// checkout's `HEAD` when there is not. A name that matches no local branch
    /// refuses the start — `.failed`, with the branch in the reason — rather
    /// than forking from `HEAD` and calling it that branch: the item would run
    /// and land somewhere its project never asked for.
    static func begin(
        baseBranch: String? = nil,
        itemID: String,
        projectRoot: URL?,
        agentIDs: [String],
        orchestrator: Orchestrator?, setupCommand: String? = nil, setupTimeout: TimeInterval = defaultSetupTimeout,
        log: @escaping @MainActor (String) -> Void
    ) async -> Setup {
        switch decide(projectRoot: projectRoot) {
        case .liveTree(let reason):
            log(reason)
            return .liveTree
        case .isolate:
            break
        }
        guard let projectRoot, let orchestrator, !agentIDs.isEmpty else { return .liveTree }
        // An agent another item's session still holds is not this run's to take.
        // Restarting it would move a live run's worker out from under it and put
        // two items' edits in one tree, which is the other half of what went
        // wrong on 2026-08-11.
        if let held = agentIDs.first(where: { orchestrator.pinnedWorkingDirectory(for: $0) != nil }) {
            let reason = "agent \(held) is still pinned to another run's worktree"
            log("Worktree setup failed (\(reason)) — the item is not run")
            return .failed(reason)
        }
        let manager = WorktreeManager(projectRoot: projectRoot)
        do {
            if let reason = await startRefusal(itemID: itemID, baseBranch: baseBranch, manager: manager, log: log) {
                log("Worktree setup failed (\(reason)) — the item is not run")
                return .failed(reason)
            }
            let path = try await Self.createIsolatedWorktree(itemID: itemID, baseBranch: baseBranch, setupCommand: setupCommand, setupTimeout: setupTimeout, projectRoot: projectRoot, manager: manager)
            log("Isolated run in worktree \(branchName(for: itemID))")
            for agentID in agentIDs {
                orchestrator.stopAgent(agentID)
                orchestrator.pinWorkingDirectory(path, for: agentID)
                try await orchestrator.startAgent(agentID, cwd: path)
            }
            return .isolated(WorktreeSession(
                path: path,
                itemID: itemID,
                projectRoot: projectRoot,
                baseBranch: baseBranch,
                manager: manager,
                orchestrator: orchestrator,
                agentIDs: agentIDs, log: log
            ))
        } catch {
            let reason = error.localizedDescription
            log("Worktree setup failed (\(reason)) — the item is not run, "
                + "so nothing is written to the project's checkout")
            // The worktree may already exist and an agent may already be in it
            // (only the second restart failed). Drop it and put every agent back
            // on the project root — nothing here is going to use them.
            await manager.removeWorktree(for: itemID, keepBranch: false)
            for agentID in agentIDs {
                orchestrator.unpinWorkingDirectory(for: agentID)
                orchestrator.stopAgent(agentID)
                try? await orchestrator.startAgent(agentID, cwd: projectRoot)
            }
            return .failed(reason)
        }
    }

    /// How long the project's `worktreeSetupCommand` may run in a fresh
    /// worktree before it's treated as stuck — the same 900s a merge-verify
    /// step is given, since the work (`npm ci`, `xcodegen generate`, …) is the
    /// same shape. `nonisolated` (and overridable via `begin`'s `setupTimeout`)
    /// so a test can make it fire without waiting out the real 900s.
    nonisolated static let defaultSetupTimeout: TimeInterval = 900

    /// `manager.create`, then the project's `worktreeSetupCommand` in the
    /// worktree it just made, before an agent is ever pinned to it. Split out
    /// of `begin` so that decision lives here instead of adding a branch to
    /// an already-long function: a setup failure throws into `begin`'s
    /// existing `catch`, the same recovery a creation failure already gets.
    private static func createIsolatedWorktree(
        itemID: String, baseBranch: String?, setupCommand: String?, setupTimeout: TimeInterval,
        projectRoot: URL, manager: WorktreeManager
    ) async throws -> URL {
        let path = try await manager.create(for: itemID, baseBranch: baseBranch)
        if let reason = await Self.runSetupCommand(setupCommand, in: path, timeout: setupTimeout,
                                                    projectRoot: projectRoot) {
            throw WorktreeError.setupFailed(reason)
        }
        return path
    }

    /// Runs the project's `worktreeSetupCommand` in the worker's fresh
    /// worktree. `nil` when nothing is configured or the command exits clean;
    /// the reason to fail setup with otherwise, carrying the command and the
    /// tail of what it printed.
    ///
    /// `nonisolated` so `await`ing it from `begin` — itself `@MainActor`,
    /// like every other member of this class — actually leaves the main
    /// actor for the run: a `static func` on a `@MainActor` type inherits
    /// that isolation unless told otherwise, and this is the one call in
    /// `begin` that can block for the full `setupTimeout` on a real install
    /// command (`npm ci`, `xcodegen generate`), which must not freeze the
    /// app for its duration. Wrapped in `WorktreeManager.gateCommand` first,
    /// the same shell shape the merge gate's own setup step runs under, so
    /// one `worktreeSetupCommand` setting behaves identically on both paths.
    nonisolated private static func runSetupCommand(
        _ command: String?, in path: URL, timeout: TimeInterval, projectRoot: URL
    ) async -> String? {
        guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let shellCommand = WorktreeManager.gateCommand(command, projectRoot: path)
        let result = WorktreeManager.runShellCapturingOutput(
            shellCommand, in: path, timeout: timeout, projectRoot: projectRoot)
        guard !result.ok else { return nil }
        let tail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Wrapped by `WorktreeError.setupFailed` as `Worktree setup failed
        // (<this>)`, the same shape every other refusal in `begin` reads as —
        // so this names only what happened, not "setup failed" a second time.
        let base = result.timedOut
            ? "\(command) timed out after \(Int(timeout.rounded()))s"
            : "\(command) failed"
        return tail.isEmpty ? base : "\(base): \(tail)"
    }

    /// Why the worktree cannot be made, before anything is torn down for it.
    ///
    /// The base is checked first: a run refused for naming a branch that isn't
    /// there should leave the item's previous worktree and branch exactly as
    /// they were, since nothing is about to replace them. Then any stale
    /// worktree/branch from a previous run of this item is cleared so `git
    /// worktree add -b` doesn't fail on an existing branch. A branch git will
    /// not delete — checked out elsewhere, most often to review it — is this
    /// run's refusal, in git's words with the path in them. Unless the checkout
    /// holding it was one no run of this project owns and could be taken away,
    /// in which case the start goes ahead and `log` says whose checkout went.
    private static func startRefusal(
        itemID: String, baseBranch: String?, manager: WorktreeManager, log: @MainActor (String) -> Void
    ) async -> String? {
        if let base = baseBranch, await !manager.localBranchExists(named: base) {
            return "base branch \(base) does not exist in this repository"
        }
        let deletion = await manager.removeWorktree(for: itemID, keepBranch: false)
        if let backup = deletion.backupRef {
            log("Kept the previous run's unmerged tip of \(branchName(for: itemID)) at \(backup) "
                + "before starting over\(deletion.recoveredLooseWork ? " (its loose changes were committed first)" : "")")
        }
        if let stray = deletion.removedStrayWorktree {
            log("Removed a leftover worktree at \(stray) holding branch \(branchName(for: itemID)) — "
                + "no run of this project made it, and it was keeping the branch from being reused")
        }
        if let refusal = deletion.refusal {
            return "branch \(branchName(for: itemID)) could not be deleted: \(refusal)"
        }
        return nil
    }

    // MARK: - Teardown

    /// What a finished item asks of its worktree.
    enum TeardownAction: Equatable {
        /// Commit anything still uncommitted and keep the branch — unless the
        /// branch has no commits on it either, in which case it goes too.
        case commit
        /// Commit the work and leave the worktree on disk for a human to look
        /// at. Committing is not in tension with inspecting — it is what makes
        /// inspecting possible, because a diff can be read without knowing the
        /// directory exists.
        case keepForInspection
    }

    /// How an item's outcome decides the fate of its worktree. Pure, so the
    /// rules are testable without a repo, agents or an orchestrator.
    static func teardownAction(for outcome: BacklogAutopilot.ItemResult.Outcome) -> TeardownAction {
        switch outcome {
        case .done, .awaitingApproval: return .commit
        case .blocked: return .keepForInspection
        // A cancelled run used to discard worktree and branch, uncommitted work
        // included. A cancel is not a verdict on the work — a driver's own
        // timeout, a stop, an app quitting with the run up all arrive here —
        // and on 2026-09-12 one took 90 uncommitted tests with it. Committed
        // and kept, the branch is a ref a person can read or delete; an empty
        // one is still dropped, as `.commit` always has.
        case .cancelled: return .commit
        // A run that claims the item was already built changed no files, so
        // there is nothing to commit and nothing to discard — but it is now
        // sitting in front of a human, and the blocked reading is the one that
        // leaves them something to look at if git turns out to disagree.
        // Nothing reaches this today: the ending is derived after teardown has
        // already run, on the outcome the workflow produced.
        case .alreadyImplemented: return .keepForInspection
        // The same reading for the same reason: a refuted premise changed no
        // files, and the tree it was measured on is what a human at the gate
        // may want to look at. Reached the same way — derived after teardown,
        // on the outcome the workflow produced.
        case .investigation: return .keepForInspection
        }
    }

    /// How the run's work came to be on the branch — or that it isn't there.
    ///
    /// Teardown used to read `commitAll`'s boolean as "the branch has work on
    /// it". It doesn't: it means "*I* was the one who committed". The two differ
    /// in exactly one case, and that case is a worker doing the right thing —
    /// committing its own work leaves a clean tree, `commitAll` finds nothing to
    /// do, and the branch carrying the run's only output was deleted as empty.
    /// `RunWorkEvidence` then found no branch and reported "produced no work",
    /// the item went back to `ready`, and the next attempt repeated all of it.
    /// 26 commits across two repos were orphaned that way before this was found.
    enum CommitOutcome: Equatable {
        /// The worker left its changes uncommitted and teardown committed them.
        case committedByTeardown
        /// The tree was already clean because the worker committed its own
        /// work — the branch is ahead of the project's `HEAD`.
        case committedByWorker
        /// Nothing to commit *and* nothing already committed: the run really
        /// did produce nothing.
        case nothingProduced

        /// Whether the branch survives teardown. The branch is a finished run's
        /// only durable output, so it is dropped only when git says there is
        /// provably nothing on it — never merely because teardown didn't
        /// commit. A branch ahead of its base is never deleted here.
        var keepsBranch: Bool { self != .nothingProduced }
    }

    /// Which of the three cases a finished worktree is in. Pure, so the
    /// deletion criterion can be read and tested without a repo.
    ///
    /// `teardownCommitted` is `commitAll`'s return value; `branchHasCommits` is
    /// git's answer to whether the branch is ahead of the base it started from.
    /// Only the second may decide the branch's fate.
    nonisolated static func commitOutcome(teardownCommitted: Bool, branchHasCommits: Bool) -> CommitOutcome {
        if teardownCommitted { return .committedByTeardown }
        return branchHasCommits ? .committedByWorker : .nothingProduced
    }

    /// Where a finished run's work ended up, for the caller to report.
    struct Teardown: Equatable {
        /// The branch that survived teardown, or nil if there isn't one — a run
        /// that produced nothing at all and a cancelled run both delete their
        /// branch, and the result must not go on claiming a ref a reader can't
        /// check out.
        let branch: String?
        /// The worktree still on disk afterwards, when one was kept for
        /// inspection. Nil is "there is no directory to send anyone to".
        let worktreePath: URL?
        /// How many files the worker left uncommitted and teardown committed
        /// for it, on a run that reached its end; nil when the worker committed
        /// its own work, or produced none. Non-nil is worth a note on the item:
        /// four of eight runs on 2026-09-03 carried the teardown subject
        /// `autopilot: <item-id>` for exactly this reason, and it read as the
        /// worker's commit convention slipping.
        var committedByTeardown: Int? = nil
    }

    /// Commits the run's changes to the branch — for a passing run, a
    /// cancelled one, *and* a blocked one, whose worktree is additionally kept
    /// on disk; then restores the agents to the project root. No ending throws
    /// work away: a branch is only ever dropped when git says it is empty.
    ///
    /// A blocked run commits because the alternative was losing the work: its
    /// output used to sit uncommitted in a directory nobody was told about, and
    /// the next attempt's `begin` force-removed it. On 2026-08-08 one item was
    /// run three times while a finished implementation of it sat in exactly
    /// that state. Committing costs a ref and makes the work a diff a reader can
    /// find; the worktree is still there to poke at.
    @discardableResult
    func end(outcome: BacklogAutopilot.ItemResult.Outcome) async -> Teardown {
        var survivingBranch: String?
        var keptWorktree: URL?
        var teardownCommitted: Int?
        switch Self.teardownAction(for: outcome) {
        case .commit:
            let loose = await RunWorkEvidence.uncommittedFileCount(worktree: path)
            let disposition = await commitWork(message: "autopilot: \(itemID)")
            teardownCommitted = disposition == .committedByTeardown ? (loose ?? 0) : nil
            await manager.removeWorktree(for: itemID, keepBranch: disposition.keepsBranch)
            switch disposition {
            case .committedByTeardown: log("Committed changes to branch \(branch)")
            case .committedByWorker: log("Worker had already committed — kept branch \(branch)")
            case .nothingProduced: log("Nothing to commit and no commits on it — dropped branch \(branch)")
            }
            survivingBranch = disposition.keepsBranch ? branch : nil
        case .keepForInspection:
            let disposition = await commitWork(message: "autopilot (blocked): \(itemID)")
            // The worktree is kept for a human to look at — the checkout, branch
            // and diff stay exactly as they are. Its disposable Xcode build
            // output does not: left behind, it is dead weight that never gets
            // cleaned up, and any `.app` inside it stays registered under the
            // real bundle id (see `WorktreeBuildOutput`).
            await manager.releaseBuildOutput(for: itemID)
            let location = path.path(percentEncoded: false)
            switch disposition {
            case .committedByTeardown:
                log("Committed changes to branch \(branch) — worktree kept at \(location) for inspection")
            case .committedByWorker:
                log("Worker had already committed to branch \(branch) — worktree kept at \(location) for inspection")
            case .nothingProduced:
                log("No changes — left worktree \(branch) at \(location) for inspection")
            }
            // The branch survives either way here: the worktree is checked out
            // on it, so unlike the `.commit` path there is no dropping it. An
            // empty one reads as `noCommits` to `RunWorkEvidence`, which is the
            // honest answer rather than a missing ref.
            survivingBranch = branch
            keptWorktree = path
        }
        for agentID in agentIDs {
            // Released before the restart, not after: the pin is what would
            // otherwise send the agent straight back into a worktree this
            // teardown has just removed.
            orchestrator.unpinWorkingDirectory(for: agentID)
            orchestrator.stopAgent(agentID)
            try? await orchestrator.startAgent(agentID, cwd: projectRoot)
        }
        return Teardown(branch: survivingBranch, worktreePath: keptWorktree, committedByTeardown: teardownCommitted)
    }

    /// Commits whatever the worker left uncommitted, then asks git which of the
    /// three cases the branch is actually in. The second question is the one
    /// that decides the branch's fate — `commitAll`'s answer only tells the log
    /// line who did the committing.
    private func commitWork(message: String) async -> CommitOutcome {
        let teardownCommitted = await manager.commitAll(for: itemID, message: message)
        let branchHasCommits = await manager.hasUnmergedCommits(for: itemID, base: baseBranch)
        return Self.commitOutcome(teardownCommitted: teardownCommitted,
                                  branchHasCommits: branchHasCommits)
    }

    // MARK: - Merge

    /// Merges this session's branch into the project's base — `base` when the
    /// project names one, the checked-out branch when it does not — gated on a
    /// clean merge and a green `verify` plan on the merged tree. Called after
    /// `end()`: the worktree is gone by then and the branch it committed is
    /// what gets merged, in the live project root.
    ///
    /// `onGateWait` is handed straight to `mergeAndVerify`: it fires when this
    /// merge has to queue behind another gate on the same project, so the wait
    /// can be shown for as long as it lasts.
    func merge(
        message: String, verify: MergeVerifyPlan, timeout: TimeInterval = 900,
        base: String? = nil, setupCommand: String? = nil,
        onGateWait: (@Sendable (WorktreeManager.MergeGateWait) async -> Void)? = nil
    ) async -> WorktreeManager.MergeResult {
        await manager.mergeAndVerify(branch: branch, message: message, verify: verify, timeout: timeout,
                                     base: base, setupCommand: setupCommand, onGateWait: onGateWait)
    }
}
