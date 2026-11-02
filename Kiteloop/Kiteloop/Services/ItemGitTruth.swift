import Foundation
import KiteloopCore

/// What git says about one backlog item's work, asked at the moment someone
/// looks.
///
/// The ledgers record what a run *reported*. Git records what is actually on
/// disk, and the two disagree often enough that reading only the first is how
/// five items sat marked done on 2026-08-09 with their commits on branches
/// `main` had never seen. So the item detail view asks git directly, and shows
/// both answers rather than picking one.
///
/// This is deliberately not `RunWorkEvidence`. That answers "did this run leave
/// anything behind", once, at the end of a run, and its verdict is recorded
/// against the run. This answers "where is this item's work now" — merged or
/// not, how far ahead, how big — which is a question about the item and has a
/// different answer every time it is asked. The one thing they share is the
/// diff: `changedFiles` counts `RunWorkEvidence.changedFiles`, so the view and
/// the run log cannot disagree about what a branch changes.
///
/// Every count is optional and nil means **nobody could tell**: no repository,
/// no such branch, a git that failed. A zero would read as "changes nothing",
/// which is the one thing an unreadable repo must never be mistaken for.
struct ItemGitTruth: Equatable, Sendable {

    /// Whether the item's branch is there at all.
    enum Presence: String, Equatable, Sendable {
        case present
        /// git answered, and there is no such ref.
        case absent
        /// git could not be asked — no project root, not a repository, or the
        /// command failed.
        case unreadable
    }

    /// The ref this item's work would be on — `kiteloop/<id>`, from the one
    /// place that naming lives.
    let branch: String
    let presence: Presence
    /// Whether the branch tip is already reachable from the project's `HEAD`.
    /// Nil when there is no branch to ask about, or git could not be read.
    let merged: Bool?
    /// Commits the branch carries that `HEAD` cannot reach.
    let commitsAhead: Int?
    /// Files those commits change against `HEAD`.
    let changedFiles: Int?
    /// A worktree still checked out for this item, when one is on disk. What a
    /// blocked run leaves behind, and the directory a person would go read.
    let worktreePath: String?
    /// With no branch there, whether commits this item's runs wrote are still in
    /// the object store with nothing pointing at them. Nil means **nobody
    /// asked** — the scan is a full object walk, so it is only run once the
    /// cheap ref read has already come back empty (see `read`).
    ///
    /// Deliberately a property rather than a fourth `Presence`: the reading is
    /// still `absent`, so every rule that keys on `presence` — `ItemDisagreements
    /// .detect`, the view's unreadable branch — keeps behaving as it did.
    var orphanedCommits: Bool? = nil

    /// Nothing could be read — the state where every claim below is a nil, and
    /// the view says so instead of rendering a row of dashes as facts.
    var isUnreadable: Bool { presence == .unreadable }

    /// One line for the view's header. States what is known and stays silent
    /// about what is not.
    var summary: String {
        switch presence {
        case .unreadable:
            return "git could not be read here"
        case .absent:
            // A missing ref reads as "nothing was produced" on its own, and that
            // is wrong whenever teardown dropped a branch whose commits were
            // real. Say so when the object store still holds them; stay silent —
            // byte for byte the old line — when it doesn't, or when nobody asked.
            guard orphanedCommits == true else { return "no branch \(branch)" }
            return "no branch \(branch) · its commits are still in the object store, unreferenced"
        case .present:
            var parts = ["branch \(branch)"]
            switch merged {
            case true: parts.append("merged")
            case false: parts.append("not merged")
            case nil: break
            }
            if let commitsAhead {
                parts.append("\(commitsAhead) commit\(commitsAhead == 1 ? "" : "s") ahead")
            }
            if let changedFiles {
                parts.append("\(changedFiles) file\(changedFiles == 1 ? "" : "s") changed")
            }
            if worktreePath != nil { parts.append("worktree on disk") }
            return parts.joined(separator: " · ")
        }
    }

    /// The reading for a project that has no repository behind it — every claim
    /// unknown, which is what `unreadable` means.
    static func unreadable(branch: String) -> ItemGitTruth {
        ItemGitTruth(branch: branch, presence: .unreadable, merged: nil,
                     commitsAhead: nil, changedFiles: nil, worktreePath: nil)
    }

    // MARK: - Reading git

    /// Asks git about `itemID` in `projectRoot`.
    ///
    /// Each question is only asked once the one before it left it open: a ref
    /// that isn't there has no commits to count, and commits nobody could count
    /// have no diff worth measuring. Runs off the calling actor, like
    /// `RunWorkEvidence`.
    ///
    /// The one exception to "cheaper first" is the missing-ref arm, which pays
    /// for `RunWorkEvidence.orphanedCommitExists` — a full object scan, ~2s — to
    /// tell a branch that was dropped over real work apart from an item that
    /// never produced any. Only that arm asks: a branch that resolves never
    /// reaches it, and `orphanedCommits` stays nil.
    static func read(projectRoot: URL?, itemID: String) async -> ItemGitTruth {
        let branch = WorktreeSession.branchName(for: itemID)
        guard let projectRoot else { return .unreadable(branch: branch) }
        let root = projectRoot.path(percentEncoded: false)
        let worktree = WorktreeSession.worktreeDirectory(for: itemID, projectRoot: projectRoot)
        let keptWorktree = FileManager.default.fileExists(atPath: worktree.path(percentEncoded: false))
            ? worktree.path(percentEncoded: false) : nil

        let presenceAndCounts: (Presence, Bool?, Int?, Bool?) = await Task.detached(priority: .userInitiated) {
            let resolve = SubprocessOutput.git(["-C", root, "rev-parse", "--verify", "--quiet",
                                                "refs/heads/\(branch)"])
            // 0 = the ref is there, 1 = no such ref, anything else (128: not a
            // repository) means the question could not be asked at all.
            switch resolve.status {
            case 1:
                // git answered, and the ref isn't there. The same corroboration
                // `RunWorkEvidence` runs before believing that: teardown drops
                // branches whose commits were real, and the flat "no branch"
                // reading is how that work goes unmentioned.
                return (.absent, nil, nil,
                        RunWorkEvidence.orphanedCommitExists(root: root, itemID: itemID))
            case 0: break
            default: return (.unreadable, nil, nil, nil)
            }
            // `merge-base --is-ancestor` is the merged question exactly: is the
            // branch tip already reachable from HEAD. 0 = yes, 1 = no, anything
            // else is a read that failed and stays unknown.
            let ancestor = SubprocessOutput.git(["-C", root, "merge-base", "--is-ancestor", branch, "HEAD"])
            let merged: Bool? = ancestor.status == 0 ? true : (ancestor.status == 1 ? false : nil)

            let counted = SubprocessOutput.git(["-C", root, "rev-list", "--count", branch, "^HEAD"])
            let ahead = counted.status == 0
                ? Int(counted.output.trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            return (.present, merged, ahead, nil)
        }.value

        let (presence, merged, ahead, orphaned) = presenceAndCounts
        // Only worth a diff when there is something on the branch to diff. The
        // count comes from `RunWorkEvidence`, so this view and the run log are
        // reading the same `git diff`.
        var changed: Int?
        if presence == .present, let ahead, ahead > 0 {
            changed = (await RunWorkEvidence.changedFiles(projectRoot: projectRoot, branch: branch) ?? []).count
        } else if presence == .present, ahead == 0 {
            changed = 0
        }

        return ItemGitTruth(branch: branch, presence: presence, merged: merged,
                            commitsAhead: ahead, changedFiles: changed,
                            worktreePath: keptWorktree, orphanedCommits: orphaned)
    }
}
