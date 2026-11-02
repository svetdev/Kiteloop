import Foundation
import KiteloopCore

/// Items left mid-run — `active`, or `inReview` — with no run behind them, and
/// the sentence that says so in the item's Notes.
///
/// A run's *live* state is in-memory: the autopilot, its workflow execution and
/// the control server's `runs` all die with the process. So at launch no item can
/// legitimately be mid-run, and any that reads that way was interrupted — the app
/// quit, crashed, or was terminated while its run was in flight. What does survive is
/// the written-down half: `RunRecordStore` keeps a `PersistedRunRecord` per run in
/// `~/.kiteloop/control-runs.jsonl` and, at load, closes anything still open as
/// `interrupted`. That says how the run ended; it does not put the run back, and
/// it does not touch the backlog. Nothing clears such an item on its own, and the
/// pickup gate only takes `ready`, so it is stranded: the queue shows work, the
/// app shows no activity, and nothing explains the gap. It happened four times on
/// 2026-08-09, each time reported as "kiteloop has stopped working", and each time
/// the remedy was editing `BACKLOG.md` by hand.
///
/// This is the item-status counterpart of `BacklogAutopilot.reconcileStatus`,
/// which does the same for the autopilot's own busy flag. Both answer the same
/// question the same way — *is there a run behind this?* — so a project cannot
/// report an idle autopilot and a running item at once.
///
/// Pure, and free of run state on purpose: the decision is a function of the
/// backlog and the one item actually in flight, so it can be checked without a
/// project, an autopilot or a workflow engine.
enum StaleActiveItems {

    /// The stages an item can only be in because a run put it there. Both die
    /// with the process, so both strand the same way: `inReview` is written by
    /// the reviewer node in projects whose flow has that stage, and an app that
    /// stops mid-review would otherwise leave the item in a column no pickup
    /// gate reads.
    static let midRunStages: [BacklogItemStatus] = [.active, .inReview]

    /// An item left in a mid-run stage that nothing is running.
    struct Stranded: Equatable, Sendable {
        let id: String
        let title: String
    }

    /// The items a reconciliation would return to `ready`.
    ///
    /// `inFlightItemID` is the item a run is genuinely executing right now, from
    /// `BacklogAutopilot.inFlightRun()` — the same check the busy guard makes.
    /// Reopening a project whose run is still going must not touch that item, and
    /// it is the only mid-run item that can be legitimate — whichever of the
    /// stages it is on, since a run moves between them as it goes.
    static func stranded(in file: BacklogFile?, inFlightItemID: String?) -> [Stranded] {
        guard let file else { return [] }
        return file.sections
            .flatMap(\.items)
            .filter { midRunStages.contains($0.status) && $0.id != inFlightItemID }
            .map { Stranded(id: $0.id, title: $0.title) }
    }

    /// The Notes line for one reconciled item.
    ///
    /// A status that changes with no explanation is the reason a reader stops
    /// trusting the backlog — "was work lost, or did something reset this?" So
    /// the line says what happened, and names whatever the interrupted run left
    /// behind, which is the difference between re-running the item and paying
    /// twice for the same diff.
    static func note(reason: String, work: RunWorkEvidence.LeftBehind?) -> String {
        var text = "returned to ready: the app stopped while this was running "
                 + "(\(reason) — no run was behind it)"
        if let summary = work?.summary {
            text += ". The interrupted run left \(summary) — untouched, so a re-run "
                  + "should look there first"
        }
        return text
    }

    /// What an interrupted run left on disk for `itemID`, read from git.
    ///
    /// The branch and worktree an isolated run uses are named from the item id,
    /// so both can be found without any surviving run record — which is exactly
    /// what a restart destroys. A live-tree run has neither and reads back as
    /// `.unknown`, naming nothing rather than inventing a place to look.
    ///
    /// Read like a *blocked* run rather than a finished one: teardown is what
    /// commits a run's work, and an interrupted run never reached it, so its
    /// output is sitting uncommitted in the worktree. Judging it by the branch
    /// alone would report "nothing here" over a full implementation.
    ///
    /// Nothing here writes: the work is reported, never removed. Returning an
    /// item to `ready` is a statement about the queue, not a verdict on the diff.
    static func leftBehind(itemID: String, projectRoot: URL?) async -> RunWorkEvidence.LeftBehind? {
        guard let projectRoot else { return nil }
        let branch = WorktreeSession.branchName(for: itemID)
        let dir = WorktreeSession.worktreeDirectory(for: itemID, projectRoot: projectRoot)
        let worktree = FileManager.default.fileExists(atPath: dir.path(percentEncoded: false))
            ? dir : nil

        let onBranch = await RunWorkEvidence.inspect(
            projectRoot: projectRoot, branch: branch, isolated: true
        )
        var uncommitted: Int?
        if let worktree {
            uncommitted = await RunWorkEvidence.uncommittedFileCount(worktree: worktree)
        }
        let verdict = RunWorkEvidence.blockedVerdict(
            worktreeDirty: uncommitted.map { $0 > 0 },
            commits: commitSignal(from: onBranch)
        )

        let committed = onBranch == .produced
            ? (await RunWorkEvidence.changedFiles(projectRoot: projectRoot, branch: branch) ?? []).count
            : nil
        return RunWorkEvidence.LeftBehind(
            verdict: verdict,
            // Named only when the ref is actually there: both readings that say
            // it isn't — dropped with nothing on it, or dropped over commits
            // that outlived it — would otherwise send a reader to a branch git
            // can't resolve.
            branch: [.noBranch, .orphanedCommits].contains(onBranch) ? nil : branch,
            fileCount: RunWorkEvidence.totalChangedFiles(
                committed: committed, uncommitted: uncommitted
            ) ?? 0,
            worktreePath: worktree?.path(percentEncoded: false)
        )
    }

    /// The committed half of the evidence, as the commit count
    /// `RunWorkEvidence.blockedVerdict` weighs against the worktree.
    ///
    /// `.emptyDiff` counts as no commits on purpose: commits that change no file
    /// are not work left behind, and pointing a reader at them wastes the trip.
    /// `.unknown` stays nil — "nobody could read it" is not "there is nothing
    /// there", and only the second may count against the run. `.orphanedCommits`
    /// stays nil for the other half of that rule: the run's commits are still in
    /// the object store, so counting them as 0 would report real work as none —
    /// but no ref names them, so there is nothing here a re-run could be pointed
    /// at either.
    static func commitSignal(from verdict: RunWorkEvidence.Verdict) -> Int? {
        switch verdict {
        case .produced: return 1
        case .noBranch, .noCommits, .emptyDiff: return 0
        case .orphanedCommits, .noChanges, .unknown: return nil
        }
    }
}
