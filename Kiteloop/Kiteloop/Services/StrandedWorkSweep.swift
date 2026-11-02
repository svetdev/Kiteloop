import Foundation
import KiteloopCore

/// One item the ledger calls done whose work never reached `HEAD` — still
/// sitting on a branch nothing merged, or in the object store with nothing
/// pointing at it after teardown dropped the branch.
struct StrandedItem: Equatable, Sendable, Identifiable {
    let itemID: String
    /// The ref this item's work is on, or was on before teardown deleted it —
    /// `gitSays` is what tells those apart.
    let branch: String
    /// Commits the branch carries that the project's `HEAD` cannot reach. Zero
    /// when there is no branch left to count them on, or when the finding is
    /// about uncommitted work rather than commits at all.
    let commitsAhead: Int
    /// The disagreement in `ItemDisagreements`' own words, so the sweep and the
    /// item detail view cannot describe the same finding differently.
    let ledgerSays: String
    let gitSays: String
    /// The worktree directory this finding is about, when it is about one —
    /// the branch and dangling-commit findings above are not; they are about a
    /// ref, and name no directory on disk.
    let worktreePath: String?
    /// Uncommitted files sitting in that worktree, set together with
    /// `worktreePath`.
    let uncommittedFiles: Int?

    // `let ... = nil` defaults are dropped from Swift's synthesized memberwise
    // init rather than made optional there, so the two call sites above (which
    // never set them) would stop compiling without this explicit one.
    init(itemID: String, branch: String, commitsAhead: Int, ledgerSays: String, gitSays: String,
         worktreePath: String? = nil, uncommittedFiles: Int? = nil) {
        self.itemID = itemID
        self.branch = branch
        self.commitsAhead = commitsAhead
        self.ledgerSays = ledgerSays
        self.gitSays = gitSays
        self.worktreePath = worktreePath
        self.uncommittedFiles = uncommittedFiles
    }

    var id: String { itemID }
}

/// A whole project's answer to "which done items never actually merged".
struct StrandedWorkReport: Equatable, Sendable {

    let stranded: [StrandedItem]
    /// git could not be asked at all — no project root, not a repository, or the
    /// listing failed. Distinct from "asked, and nothing is stranded": a project
    /// whose git cannot be read must not report every item as stranded, and must
    /// not report a clean sweep either.
    let unreadable: Bool
    /// How many done items the sweep was given.
    let doneItemsConsidered: Int
    /// How many branches it paid a second git call for.
    let branchesExamined: Int
    /// Candidates left unasked because the budget ran out. Reported rather than
    /// dropped in silence — a truncated sweep that reads like a complete one is
    /// the same failure as no sweep at all.
    let branchesNotExamined: Int
    /// How many done items the listing did not name — the candidates for a
    /// branch teardown dropped — the sweep read a ref for.
    let danglingCandidatesExamined: Int
    /// How many of those it left unasked because the dangling budget ran out.
    /// Same reason as `branchesNotExamined`: a sweep that stopped early must not
    /// read like one that finished.
    let danglingCandidatesNotExamined: Int

    var count: Int { stranded.count }

    static func clean(doneItemsConsidered: Int) -> StrandedWorkReport {
        StrandedWorkReport(stranded: [], unreadable: false,
                           doneItemsConsidered: doneItemsConsidered,
                           branchesExamined: 0, branchesNotExamined: 0,
                           danglingCandidatesExamined: 0, danglingCandidatesNotExamined: 0)
    }

    static func unreadable(doneItemsConsidered: Int) -> StrandedWorkReport {
        StrandedWorkReport(stranded: [], unreadable: true,
                           doneItemsConsidered: doneItemsConsidered,
                           branchesExamined: 0, branchesNotExamined: 0,
                           danglingCandidatesExamined: 0, danglingCandidatesNotExamined: 0)
    }

    /// The wording an unreadable repository gets, kept identical to
    /// `ItemGitTruth.summary` so a reader meets one sentence for one condition.
    static let unreadableReason = "git could not be read here"
}

/// The done-and-unmerged check, run across a project's whole backlog instead of
/// the one item whose detail view is open.
///
/// `ItemDisagreements` has had this case since 2026-08-09 and it is correct —
/// what it never had was a caller that asked it about more than one item.
/// Two items were found by hand on 2026-08-11 by walking the branch list:
/// `ui-started-runs-leave-no-record` (222 insertions, merged cleanly once found)
/// and `affiliate-redirect-rejects-non-http-targets` (278 insertions, by then
/// unmergeable — main had been refactored underneath it). Both read done, on
/// projects with auto-merge on, and nothing in the ledger told them apart from
/// the hundreds that genuinely shipped.
///
/// **The detection here is not new.** Each candidate is turned into an
/// `ItemGitTruth` and handed to `ItemDisagreements.detect`, and the finding is
/// that rule's own verdict and wording. With `status == .done` and no run, the
/// done-and-unmerged clause is the only one that can fire.
///
/// **A branch is not the only place work strands.** Teardown deletes the branch
/// it built, and when that happens over commits nobody merged, the work is left
/// in the object store with nothing pointing at it — an item in that state has
/// no branch for the listing to name, so the branch pass above counts it clean.
/// That is the same absence `ItemGitTruth.read` already corroborates for the one
/// item whose detail view is open (`RunWorkEvidence.orphanedCommitExists`), and
/// the sweep asks the same question of the whole project: which done items have
/// no branch, and of those, which have commits still dangling under their own
/// teardown subject.
///
/// **It is bounded, because reading git per done item is not affordable.** A
/// project with 300 done items would be 300 `git` invocations on every request.
/// So one listing answers "present and not merged" for the whole project at
/// once — a branch git will not list as unmerged has nothing to strand — and
/// only the handful of done items that appear in it cost a second call. The
/// dangling pass is bounded the same way, and its expensive half — one `fsck`
/// object walk — is paid once for the sweep, never per item, and not at all by
/// a project whose done items all still have branches. Nothing
/// here merges anything: a stale branch is exactly the decision a person has to
/// make, and of the two above one was mergeable and the other was not.
enum StrandedWorkSweep {

    /// How many candidate branches will be counted before the sweep stops
    /// asking. A project running with auto-merge off accumulates unmerged
    /// branches on purpose, and a poller must not pay for all of them.
    static let branchBudget = 50

    /// How many done items missing from the unmerged listing will have their ref
    /// read before the dangling pass stops asking. Every item that merged and
    /// had its branch tidied away lands in that set — on a healthy project, most
    /// of the backlog — so it is bounded for the same reason `branchBudget` is,
    /// and what goes unasked is reported rather than dropped in silence.
    static let danglingBudget = 50

    /// How the sweep asks git: arguments after `git -C <root>`, back come the
    /// exit status and stdout. A closure so the rules — and the number of calls
    /// they make — are testable without a repository. Deliberately not
    /// `@Sendable`: `sweep` calls it synchronously and `read` builds it inside
    /// the detached task, so nothing crosses an isolation boundary, and a test
    /// counting calls into a local `var` is what this exists for.
    typealias Git = (_ arguments: [String]) -> (status: Int32, output: String)

    /// What the branch pass and the object walk read: every local ref and
    /// where `HEAD` is, as one line per ref. The same refs give the same
    /// sweep, so a listing that has not moved is not walked again — the
    /// backlog endpoint was paying the whole sweep, 15 seconds on a project
    /// with 345 item branches, on every poll. Nil when git could not answer,
    /// which is never cached.
    static func fingerprint(git: Git) -> String? {
        let refs = git(["for-each-ref", "--format=%(objectname) %(refname)", "refs/heads/", "refs/kiteloop/"])
        let head = git(["rev-parse", "HEAD"])
        guard refs.status == 0, head.status == 0 else { return nil }
        return refs.output + "\n" + head.output
    }

    /// The last sweep per project, good for as long as the refs it read are
    /// the ones on disk and the done items are the same.
    private actor Cache {
        struct Entry { let fingerprint: String; let doneItemIDs: [String]; let report: StrandedWorkReport }
        private var byProject: [String: Entry] = [:]
        func lookup(project: String, fingerprint: String, doneItemIDs: [String]) -> StrandedWorkReport? {
            guard let entry = byProject[project], entry.fingerprint == fingerprint,
                  entry.doneItemIDs == doneItemIDs else { return nil }
            return entry.report
        }
        func store(project: String, fingerprint: String, doneItemIDs: [String], report: StrandedWorkReport) {
            byProject[project] = Entry(fingerprint: fingerprint, doneItemIDs: doneItemIDs, report: report)
        }
        func forget(project: String) { byProject.removeValue(forKey: project) }
    }
    private static let cache = Cache()

    /// `sweep`, answered from the cache when the refs and the done items are
    /// the ones it was last taken over. An unreadable fingerprint, or an
    /// unreadable sweep, is never kept: nothing is more expensive than a
    /// wrong answer served for as long as the refs stand still.
    static func cachedSweep(project: String, doneItemIDs: [String], git: Git) async -> StrandedWorkReport {
        guard let fingerprint = fingerprint(git: git) else { return sweep(doneItemIDs: doneItemIDs, git: git) }
        if let cached = await cache.lookup(project: project, fingerprint: fingerprint, doneItemIDs: doneItemIDs) {
            return cached
        }
        let report = sweep(doneItemIDs: doneItemIDs, git: git)
        if !report.unreadable {
            await cache.store(project: project, fingerprint: fingerprint, doneItemIDs: doneItemIDs, report: report)
        }
        return report
    }

    /// Drops the cached sweep for a project — for a test that rebuilds one
    /// under the same path.
    static func forgetCachedSweep(project: String) async { await cache.forget(project: project) }

    /// The sweep itself, over a git it is handed.
    ///
    /// - Parameter doneItemIDs: every item the backlog marks done, in file order.
    static func sweep(doneItemIDs: [String], git: Git) -> StrandedWorkReport {
        // Nothing done is nothing to strand, and the listing is not worth
        // spawning for it.
        guard !doneItemIDs.isEmpty else { return .clean(doneItemsConsidered: 0) }

        // The one call that scales with the project rather than the backlog:
        // every local branch whose tip HEAD cannot reach. Anything absent from
        // it is either merged or not there, and either way not stranded.
        let listing = git(["branch", "--list", "--no-merged", "HEAD", "--format=%(refname:short)"])
        guard listing.status == 0 else {
            return .unreadable(doneItemsConsidered: doneItemIDs.count)
        }
        let unmerged = Set(listing.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })

        let candidates = doneItemIDs.filter { unmerged.contains(WorktreeSession.branchName(for: $0)) }
        let examined = candidates.prefix(branchBudget)

        var stranded: [StrandedItem] = []
        for itemID in examined {
            let branch = WorktreeSession.branchName(for: itemID)
            let counted = git(["rev-list", "--count", branch, "^HEAD"])
            // A count that could not be read stays nil, which `detect` reads as
            // nothing ahead — an unanswered question is not a finding.
            let ahead = counted.status == 0
                ? Int(counted.output.trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            let truth = ItemGitTruth(branch: branch, presence: .present, merged: false,
                                     commitsAhead: ahead, changedFiles: nil, worktreePath: nil)
            guard let disagreement = ItemDisagreements
                .detect(status: .done, latestRun: nil, git: truth).first else { continue }
            stranded.append(StrandedItem(itemID: itemID, branch: branch,
                                         commitsAhead: ahead ?? 0,
                                         ledgerSays: disagreement.ledgerSays,
                                         gitSays: disagreement.gitSays))
        }

        // The done items the listing did not name. Almost all of them merged and
        // had their branch tidied away, which is the ordinary end of an item —
        // but a teardown that dropped a branch over unmerged commits leaves the
        // same absence, and only the ref read tells the two apart.
        let absentees = doneItemIDs.filter { !unmerged.contains(WorktreeSession.branchName(for: $0)) }
        let asked = absentees.prefix(danglingBudget)
        var withoutABranch: [String] = []
        for itemID in asked {
            let resolve = git(["rev-parse", "--verify", "--quiet",
                               "refs/heads/\(WorktreeSession.branchName(for: itemID))"])
            // 1 = git answered and there is no such ref. 0 = the branch is there
            // and merged, which is what done is supposed to mean; anything else
            // (128: not a repository) means the question could not be asked, and
            // an unanswered question is not a finding.
            if resolve.status == 1 { withoutABranch.append(itemID) }
        }

        // The backup refs first — a cheap ref read each — then the object
        // walk for whatever they did not account for.
        let backedUp = backedUpFindings(for: withoutABranch, git: git)
        let keptElsewhere = Set(backedUp.map(\.itemID))
        stranded += backedUp
        stranded += danglingFindings(for: withoutABranch.filter { !keptElsewhere.contains($0) }, git: git)

        return StrandedWorkReport(stranded: stranded, unreadable: false,
                                  doneItemsConsidered: doneItemIDs.count,
                                  branchesExamined: examined.count,
                                  branchesNotExamined: candidates.count - examined.count,
                                  danglingCandidatesExamined: asked.count,
                                  danglingCandidatesNotExamined: absentees.count - asked.count)
    }

    /// The done items among `itemIDs` whose branch `WorktreeManager
    /// .removeWorktree` took over unmerged commits: the tip is under
    /// `refs/kiteloop/backup/<id>/`, reachable, so the object walk would
    /// never see it and the finding names the ref instead.
    private static func backedUpFindings(for itemIDs: [String], git: Git) -> [StrandedItem] {
        itemIDs.compactMap { itemID in
            guard let ref = backupRef(for: itemID, git: git) else { return nil }
            let branch = WorktreeSession.branchName(for: itemID)
            return StrandedItem(itemID: itemID, branch: branch, commitsAhead: 0,
                                ledgerSays: "the item is Done",
                                gitSays: "there is no branch \(branch) — its tip is kept at \(ref)")
        }
    }

    /// The done items among `itemIDs` whose teardown commit is still in the
    /// object store with nothing pointing at it. One object walk for the whole
    /// sweep, and only once something is actually missing a branch to look
    /// for — a project whose done items all still have theirs never pays for it.
    private static func danglingFindings(for itemIDs: [String], git: Git) -> [StrandedItem] {
        guard !itemIDs.isEmpty else { return [] }
        let dangling = danglingSubjects(git: git)
        return itemIDs.compactMap { itemID in
            guard dangling.contains(RunWorkEvidence.teardownSubject(for: itemID)) else { return nil }
            let branch = WorktreeSession.branchName(for: itemID)
            let truth = ItemGitTruth(branch: branch, presence: .absent, merged: nil,
                                     commitsAhead: nil, changedFiles: nil,
                                     worktreePath: nil, orphanedCommits: true)
            guard let disagreement = ItemDisagreements
                .detect(status: .done, latestRun: nil, git: truth).first else { return nil }
            return StrandedItem(itemID: itemID, branch: branch, commitsAhead: 0,
                                ledgerSays: disagreement.ledgerSays, gitSays: disagreement.gitSays)
        }
    }

    /// The subject of every dangling commit in the object store.
    ///
    /// The same two calls `RunWorkEvidence.orphanedCommitExists` makes — one
    /// `fsck --no-reflogs --dangling`, then one `log -1 --format=%s` per commit
    /// it names — taken once for the project instead of once per item, since the
    /// walk is the expensive part (~2s on this repository) and its answer is the
    /// same for every item asking. `--no-reflogs` because `HEAD`'s reflog would
    /// otherwise keep a deleted branch's commits reachable, hiding exactly the
    /// case this exists to find.
    ///
    /// Output is parsed whatever `fsck` exits with, as `orphanedCommitExists`
    /// does: a repository with unrelated problems is reported as a failure while
    /// the dangling objects are still printed, and a command that never ran
    /// prints nothing — which reads as no match, so a failed `fsck` adds no
    /// finding and leaves the branch pass's standing.
    static func danglingSubjects(git: Git) -> Set<String> {
        let fsck = git(["fsck", "--no-reflogs", "--dangling"])
        var subjects: Set<String> = []
        for line in fsck.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "dangling", parts[1] == "commit" else { continue }
            let logged = git(["log", "-1", "--format=%s", String(parts[2])])
            guard logged.status == 0 else { continue }
            subjects.insert(logged.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return subjects
    }

    /// How `dirtyOpenWorktrees` asks git about one worktree directory — a
    /// second, simpler seam than `Git` above, because this pass asks a
    /// different question of a different directory per candidate rather than
    /// one project-wide question of the project root.
    /// The newest backup ref kept for `itemID`, or nil when none is — the
    /// refs `WorktreeManager.backUpUnmergedTip` writes, one per tip.
    static func backupRef(for itemID: String, git: Git) -> String? {
        let listed = git(["for-each-ref", "--sort=-committerdate", "--format=%(refname)",
                          "refs/kiteloop/backup/\(itemID)/"])
        guard listed.status == 0 else { return nil }
        return listed.output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    typealias WorktreeGit = (_ path: String, _ arguments: [String]) -> (status: Int32, output: String)

    /// Worktrees on disk holding uncommitted changes nothing is coming back
    /// for — the case neither pass above can see. The branch listing only
    /// knows refs, and these changes are in no commit; the object walk only
    /// knows commits, and there are none. Found by hand on 2026-08-21: a
    /// worktree sat dirty for ten days while its item stayed open, unpicked
    /// and unrun, and would have been silently destroyed by an ordinary
    /// `git worktree prune`.
    ///
    /// Two states are excluded on purpose, both of which are dirty for a
    /// reason that is not stranding: `inFlightItemID` is the run in progress
    /// right now — a run's worktree is dirty for the whole of it, that is what
    /// a run looks like from outside — and `.blocked` is
    /// `WorktreeSession.TeardownAction.keepForInspection`, kept on purpose for
    /// a person to look at. Everything else — ready, an `active` item nobody
    /// is actually running, awaiting approval, done, or an item the backlog no
    /// longer names — is a worktree nothing is coming back for.
    ///
    /// Shown, never resolved, same as the two passes above: nothing here
    /// commits, deletes or prunes anything.
    static func dirtyOpenWorktrees(
        worktrees: [(itemID: String, path: String)],
        statusByItemID: [String: BacklogItemStatus],
        inFlightItemID: String?,
        git: WorktreeGit
    ) -> [StrandedItem] {
        var stranded: [StrandedItem] = []
        for (itemID, path) in worktrees {
            guard itemID != inFlightItemID else { continue }
            guard statusByItemID[itemID] != .blocked else { continue }
            let result = git(path, ["status", "--porcelain"])
            guard result.status == 0 else { continue }
            let files = result.output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !files.isEmpty else { continue }
            let ledgerStatus = statusByItemID[itemID]?.displayName ?? "not in the backlog"
            stranded.append(StrandedItem(
                itemID: itemID,
                branch: WorktreeSession.branchName(for: itemID),
                commitsAhead: 0,
                ledgerSays: "the item is \(ledgerStatus)",
                gitSays: "the worktree at \(path) holds \(files.count) uncommitted "
                    + "file\(files.count == 1 ? "" : "s") — nothing is coming back for "
                    + (files.count == 1 ? "it" : "them"),
                worktreePath: path,
                uncommittedFiles: files.count))
        }
        return stranded
    }

    /// The sweep against a real repository. Runs off the calling actor, like
    /// `ItemGitTruth.read`.
    ///
    /// - Parameters:
    ///   - statusByItemID: every backlog item's current stage, for
    ///     `dirtyOpenWorktrees` — an item the map does not name is read as one
    ///     the backlog no longer tracks at all, which is stranded the same as
    ///     any other open item.
    ///   - inFlightItemID: the item this project's autopilot is running right
    ///     now, if any — its worktree is dirty for a reason that is not
    ///     stranding.
    static func read(
        projectRoot: URL?,
        doneItemIDs: [String],
        statusByItemID: [String: BacklogItemStatus] = [:],
        inFlightItemID: String? = nil
    ) async -> StrandedWorkReport {
        guard let projectRoot else { return .unreadable(doneItemsConsidered: doneItemIDs.count) }
        let root = projectRoot.path(percentEncoded: false)
        let worktreesDir = projectRoot.appending(path: ".kiteloop/worktrees")
        let worktreesPath = worktreesDir.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            let report = await cachedSweep(project: root, doneItemIDs: doneItemIDs) { SubprocessOutput.git(["-C", root] + $0) }

            let fm = FileManager.default
            let entries = ((try? fm.contentsOfDirectory(atPath: worktreesPath)) ?? []).sorted()
            let worktrees: [(itemID: String, path: String)] = entries.compactMap { itemID in
                let path = worktreesDir.appending(path: itemID).path(percentEncoded: false)
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
                else { return nil }
                return (itemID, path)
            }
            let dirty = dirtyOpenWorktrees(
                worktrees: worktrees, statusByItemID: statusByItemID, inFlightItemID: inFlightItemID
            ) { path, args in SubprocessOutput.git(["-C", path] + args) }
            guard !dirty.isEmpty else { return report }

            return StrandedWorkReport(
                stranded: report.stranded + dirty,
                unreadable: report.unreadable,
                doneItemsConsidered: report.doneItemsConsidered,
                branchesExamined: report.branchesExamined,
                branchesNotExamined: report.branchesNotExamined,
                danglingCandidatesExamined: report.danglingCandidatesExamined,
                danglingCandidatesNotExamined: report.danglingCandidatesNotExamined)
        }.value
    }
}
