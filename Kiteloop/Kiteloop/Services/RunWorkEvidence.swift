import Foundation
import KiteloopCore

/// Whether a finished run left any work behind — asked of git, in one place.
///
/// A run can pass its review having produced nothing at all: the worker's
/// session dies, the workflow still walks to its accepting node, and the item
/// arrives at the human gate asking a person to approve a change that does not
/// exist. Two cheap signals catch it — the branch the run was supposed to
/// produce, and a non-empty diff of that branch against the history it started
/// from. Neither is cost: cost read $0 on nine of thirty-one runs on 2026-08-08
/// for reasons that had nothing to do with the agent, so it cannot carry this.
///
/// `BacklogAutopilot` asks before letting the reviewer run at all, again before
/// offering an item for approval, again when a run blocks (to say what it left
/// behind) and once more before re-running an item; `CoordinatorBlockedTriage`
/// asks about an already-blocked one. They read the same git here rather than
/// each keeping their own answer to the same question, which is how two
/// implementations end up disagreeing about whether a run produced anything.
///
/// Three entry points because the run is in a different state at each: `inspect`
/// reads the committed branch of a run that reached the gate, `inspectBlocked`
/// the kept worktree of one that blocked, and `inspectInFlight` the working
/// worktree of one that has not finished — nothing is committed yet there.
enum RunWorkEvidence {

    /// How every empty-run signal starts. One definition because it is read back
    /// as well as written: a recorded run whose outcome carries this phrase is
    /// one that produced nothing, which is how `TaskMetricRecord.producedWork`
    /// judges records written before file counts were kept.
    static let noWorkPrefix = "run produced no work"

    /// What the git signals say about a finished run.
    enum Verdict: Equatable {
        /// The branch is there, carries commits the project's `HEAD` can't
        /// already reach, and those commits change files.
        case produced
        /// Teardown left no branch *and* no commit of this run's survives in the
        /// object store: there was nothing to commit. Corroborated — see
        /// `orphanedCommits` for the reading this used to be given wrongly.
        case noBranch
        /// The branch is gone, but commits this run wrote are still in the
        /// object store with nothing pointing at them. Teardown dropped a branch
        /// whose work was real, so the missing ref says nothing about whether
        /// the run produced anything — deliberately *not* evidence, and
        /// deliberately not `.produced` either: there is no ref to pick the work
        /// up from, and `LeftBehind` must not send a reader to a branch that
        /// isn't there.
        case orphanedCommits
        /// The branch exists but adds no commit over `HEAD`.
        case noCommits
        /// The branch adds commits, but they change no file.
        case emptyDiff
        /// A run with an uncommitted worktree left neither a commit nor an edit
        /// in it — one that ended blocked, or one still in flight. Separate from
        /// `noCommits` because neither of those commits anything by design — see
        /// `inspectBlocked` and `inspectInFlight`.
        case noChanges
        /// Nobody could tell — the run wasn't isolated (a live-tree run leaves
        /// no branch to read), there is no project root, or git couldn't be
        /// read. Deliberately distinct from the three above: only those are
        /// *evidence*, and evidence is what turning a run back requires.
        case unknown

        /// The signal that fired, phrased for a log line and a blocked reason;
        /// nil when nothing says the run was empty. This is what answers "why
        /// was this not offered for approval" days later.
        var missingSignal: String? {
            switch self {
            case .produced, .orphanedCommits, .unknown: return nil
            case .noBranch: return "\(RunWorkEvidence.noWorkPrefix) — no branch"
            case .noCommits: return "\(RunWorkEvidence.noWorkPrefix) — branch has no commits"
            case .emptyDiff: return "\(RunWorkEvidence.noWorkPrefix) — empty diff against base"
            case .noChanges: return "\(RunWorkEvidence.noWorkPrefix) — no commits and an unchanged worktree"
            }
        }

        /// True when git *says* the run was empty — the four signals above, and
        /// deliberately not `.unknown` or `.orphanedCommits`: "nobody could
        /// tell" and "the commits are still there, unreferenced" are both
        /// different facts from "there is nothing there", and only the last one
        /// is evidence.
        ///
        /// Read by `DailySpendLedger.resolveCharge`, which charges a run nothing
        /// only on evidence this strong; a run it cannot read keeps paying the
        /// stand-in, because assuming free is the direction that fails open.
        var producedNothing: Bool { missingSignal != nil }
    }

    // MARK: - Reading git

    /// Reads the signals off `branch` in `projectRoot`. `isolated` is whether
    /// the run had a worktree at all: a live-tree run has no branch to read and
    /// its edits sit in the project root indistinguishable from a human's, so
    /// there is nothing here that could be evidence about it.
    ///
    /// Runs git off the calling actor — both callers are `@MainActor`.
    static func inspect(projectRoot: URL?, branch: String?, isolated: Bool) async -> Verdict {
        guard isolated, let projectRoot else { return .unknown }
        let name = (branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // An isolated run whose teardown returned no branch committed nothing —
        // that is the signal itself, not a failure to read one.
        guard !name.isEmpty else { return .noBranch }
        let root = projectRoot.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            let resolve = SubprocessOutput.git(["-C", root, "rev-parse", "--verify", "--quiet",
                                                "refs/heads/\(name)"])
            // 0 = the ref is there, 1 = no such ref, anything else (128: not a
            // repository) means the question couldn't be asked.
            let branchResolves: Bool? = resolve.status == 0 ? true
                : (resolve.status == 1 ? false : nil)
            // Each signal only asked once the one before it left the question
            // open — a ref that isn't there has nothing to count commits on.
            guard branchResolves == true else {
                // A ref that isn't there was read as "nothing was committed" on
                // its own for a while, and that was wrong at least once: the
                // branch had been dropped while its commits were still in the
                // object store, and the run was filed as having produced
                // nothing over real work. So corroborate before believing it.
                if branchResolves == false, let itemID = itemID(fromBranch: name),
                   orphanedCommitExists(root: root, itemID: itemID) {
                    return .orphanedCommits
                }
                return verdict(branchResolves: branchResolves, commits: nil, hasDiff: nil)
            }

            let commits = SubprocessOutput.git(["-C", root, "rev-list", "--count", name, "^HEAD"])
            let count = commits.status == 0
                ? Int(commits.output.trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            guard let count, count > 0 else {
                return verdict(branchResolves: true, commits: count, hasDiff: nil)
            }

            // `--quiet` implies `--exit-code`: 0 = no difference, 1 = differs,
            // anything else is an error (e.g. an unborn HEAD, so no merge base).
            let diff = SubprocessOutput.git(["-C", root, "diff", "--quiet", "HEAD...\(name)"])
            let hasDiff: Bool? = diff.status == 0 ? false
                : (diff.status == 1 ? true : nil)

            return verdict(branchResolves: true, commits: count, hasDiff: hasDiff)
        }.value
    }

    /// Reads the signals off a run that ended **blocked**.
    ///
    /// A blocked run is torn down differently: its worktree is kept for a human
    /// to look at and nothing is committed (`WorktreeSession.TeardownAction
    /// .keepForInspection`). So `noCommits` — the signal for a run that reached
    /// the gate — is the *normal* state of a blocked run whose worker did real
    /// work and was rejected on it, and reading it as emptiness would turn every
    /// review rejection into a dead-session diagnosis. What separates the two is
    /// the worktree itself: work the reviewer rejected is still sitting in it,
    /// and a session that died left it untouched.
    ///
    /// `worktree` is the kept directory (nil once it's gone, or for a live-tree
    /// run). Untracked files count as work; ignored ones — build output — do
    /// not, which `git status --porcelain` already gets right.
    static func inspectBlocked(
        projectRoot: URL?,
        branch: String?,
        worktree: URL?,
        isolated: Bool
    ) async -> Verdict {
        guard isolated, let projectRoot, let worktree else { return .unknown }
        let root = projectRoot.path(percentEncoded: false)
        let tree = worktree.path(percentEncoded: false)
        let name = (branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return await Task.detached(priority: .userInitiated) {
            let status = SubprocessOutput.git(["-C", tree, "status", "--porcelain"])
            let dirty: Bool? = status.status == 0
                ? !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : nil

            // A worker that committed its own work is producing too, so the
            // branch is still worth asking about — but only when there is one.
            var commits: Int?
            if !name.isEmpty {
                let counted = SubprocessOutput.git(["-C", root, "rev-list", "--count", name, "^HEAD"])
                commits = counted.status == 0
                    ? Int(counted.output.trimmingCharacters(in: .whitespacesAndNewlines))
                    : nil
            }
            return blockedVerdict(worktreeDirty: dirty, commits: commits)
        }.value
    }

    /// The same two signals, asked **while the run is still in flight** — before
    /// the reviewer node runs rather than after teardown.
    ///
    /// It is the blocked-run reading because a run mid-flight is in the same
    /// state a blocked one is torn down in: nothing is committed yet (teardown is
    /// what commits), so the worker's work — if there is any — is sitting
    /// uncommitted in the worktree. Named separately because the question is a
    /// different one. `inspectBlocked` asks what a finished run left behind;
    /// this asks whether there is anything here to review, and a reviewer handed
    /// no diff has no evidence for a single one of its dimensions.
    ///
    /// `.unknown` — a live-tree run, an unreadable repo — means the run goes to
    /// the reviewer exactly as it did before. Only evidence stops it.
    static func inspectInFlight(
        projectRoot: URL?,
        branch: String?,
        worktree: URL?,
        isolated: Bool
    ) async -> Verdict {
        await inspectBlocked(projectRoot: projectRoot, branch: branch,
                             worktree: worktree, isolated: isolated)
    }

    /// The blocked-run rules, over signals already read. Either signal on its
    /// own is enough to say the run produced something; it takes *both* reading
    /// empty to call it empty, and a signal nobody could read leaves the
    /// question open rather than counting against the run.
    static func blockedVerdict(worktreeDirty: Bool?, commits: Int?) -> Verdict {
        if worktreeDirty == true { return .produced }
        if let commits, commits > 0 { return .produced }
        guard worktreeDirty != nil, commits != nil else { return .unknown }
        return .noChanges
    }

    // MARK: - The run that changed nothing because there was nothing to change

    /// A worker's claim, made on a run that left no files changed, that the item
    /// it was given is already built.
    ///
    /// CLAUDE.md tells a worker with an empty diff exactly what to do — "either
    /// make the change, **or say plainly that you believe it is already
    /// implemented and why**" — and until now only the first half of that
    /// sentence had an ending. The second was recorded as
    /// `\(RunWorkEvidence.noWorkPrefix)`, counted against `RetryCeiling`, and
    /// after three of them the item was retired. So an agent that followed the
    /// rule was punished by the counter, and the only way to avoid the
    /// punishment was to manufacture a diff — which the same document calls a
    /// defect. `wizard-hands-off-to-a-first-project` was retired that way on
    /// 2026-08-21: three runs, three workers, each closing with a claim and its
    /// evidence.
    ///
    /// So the claim is given a shape a machine can route on, the same way the
    /// reviewer's verdict has one:
    ///
    /// ```json
    /// {"outcome": "already-implemented",
    ///  "evidence": ["Views/Setup/SetupWizard.swift — `finish()` opens the home workspace"]}
    /// ```
    ///
    /// **The evidence is what makes it a claim.** A worker that says "already
    /// done" and names nothing has said no more than a worker that says nothing,
    /// and giving *that* an ending would hand every struggling run a way out of
    /// the ceiling. Absent, unreadable or empty evidence parses as no claim at
    /// all, and the run stays exactly what it is today: a no-work attempt that
    /// counts.
    ///
    /// Nothing here judges whether the claim is **true**. That is a reading of
    /// the code against the item's Validation — a reviewer's job, and its own
    /// item. This only gives the claim somewhere to go: the human gate, with the
    /// evidence written where the human will read it.
    struct AlreadyImplementedClaim: Equatable, Sendable {

        /// The `outcome` value a claim declares itself with, and the
        /// `TaskMetricRecord.outcome` the run is then filed under. One spelling,
        /// so what the worker writes and what the ledger counts cannot drift.
        static let outcome = TaskMetricRecord.alreadyImplementedOutcome

        /// What the worker named as the code that already satisfies the item —
        /// file and symbol, in the spelling the item's Validation uses.
        ///
        /// Never empty: a claim that names nothing is not parsed as a claim at
        /// all. Each entry is one line, because the item's `## Notes` renders
        /// them as a markdown list.
        let evidence: [String]

        /// The claim in the words a run log line uses.
        var summary: String {
            let named = evidence.count == 1 ? "1 piece of evidence" : "\(evidence.count) pieces of evidence"
            return "worker claims the item is already implemented and named \(named)"
        }

        /// What goes in the item's `## Notes` — the whole interface at the
        /// moment a human opens the item and asks why it is at the gate with no
        /// diff behind it.
        ///
        /// It says three things, because leaving any of them out is how the note
        /// gets misread: that no files changed, that **nothing has checked the
        /// claim**, and what the worker actually named. The second matters most:
        /// an item at the approval gate normally has a diff that passed a
        /// review, and approving this one accepts an agent's say-so.
        var note: String {
            let lines = evidence.map { "  - \($0)" }.joined(separator: "\n")
            return "Already implemented (claimed) — this run changed no files. The worker says the "
                + "item is already built and named the code it read. **Nothing has verified that**, "
                + "which is why the item is waiting for you rather than marked done: approving it "
                + "accepts the claim, and rejecting it returns the item for another attempt. "
                + "Evidence the worker named:\n\(lines)"
        }

        /// Reads a claim out of a worker's closing message, or nil when there
        /// isn't one there.
        ///
        /// Deliberately strict where `ReviewFindings` is lenient, and for the
        /// opposite reason: leniency there costs a run, and leniency here would
        /// widen an exit from the one guard that bounds a runaway item. Both the
        /// declared outcome and a non-empty list of named evidence have to be
        /// present, and anything else — prose, no JSON at all, a claim with an
        /// empty list, a list of nothing but blanks — is no claim.
        ///
        /// It reads the message **before** `RunClosingMessage.condensed` bounds
        /// it: that bound is what keeps a note and a log line readable, and JSON
        /// cut off at 300 characters is not JSON.
        ///
        /// The one lenient reading is the outcome token itself: `already_implemented`,
        /// `Already Implemented` and the canonical spelling are the same word,
        /// and rejecting a claim over a underscore would send a worker that did
        /// the right thing back to the ceiling.
        static func parse(_ closingMessage: String?) -> AlreadyImplementedClaim? {
            guard let closingMessage else { return nil }
            for candidate in RunQualityJudge.jsonObjects(in: closingMessage) {
                guard let data = candidate.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      declaresClaim(object["outcome"]) else { continue }
                let evidence = evidenceLines(object["evidence"])
                guard !evidence.isEmpty else { continue }
                return AlreadyImplementedClaim(evidence: evidence)
            }
            return nil
        }

        /// Whether an `outcome` value is this claim's, spelling and case aside.
        private static func declaresClaim(_ raw: Any?) -> Bool {
            guard let text = raw as? String else { return false }
            return normalised(text) == normalised(outcome)
        }

        /// Lowercased, with `_` and whitespace read as the `-` the canonical
        /// spelling uses.
        private static func normalised(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(whereSeparator: { $0 == "_" || $0 == "-" || $0.isWhitespace })
                .joined(separator: "-")
        }

        /// The evidence list, as lines. Non-string elements and blanks are
        /// dropped rather than failing the whole claim — but a list that leaves
        /// nothing behind is not evidence, and the caller treats it as none.
        ///
        /// Each entry is collapsed to one line: the notes render them as a
        /// markdown list, and an entry carrying its own newlines would break out
        /// of it.
        private static func evidenceLines(_ raw: Any?) -> [String] {
            guard let array = raw as? [Any] else { return [] }
            return array.compactMap { element in
                guard let text = element as? String else { return nil }
                let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return line.isEmpty ? nil : line
            }
        }
    }

    // MARK: - Work that landed outside the run's worktree

    /// How every stray-work signal starts, for the same reason `noWorkPrefix`
    /// has one: it is written to a run log, an item's Notes and a recorded
    /// outcome, and read back out of them.
    static let strayWorkPrefix = "run wrote outside its worktree"

    /// What the project's own checkout held uncommitted at a moment in time.
    ///
    /// An isolated run's promise is that this does not move: the worker edits
    /// its worktree and the project's checkout is left alone. Taking the
    /// baseline is what makes the promise checkable — the tree is very often
    /// already dirty with a human's own edits, and blaming those on the run
    /// would make the check cry wolf on every project anybody works in.
    struct RootSnapshot: Equatable, Sendable {
        /// Paths `git status --porcelain` reported, or nil when the read failed
        /// — which is not the same as a clean tree and must not be read as one.
        let paths: Set<String>?

        /// The baseline for a run there is nothing to compare: a live-tree run,
        /// no project root, or a `git status` that could not be taken. Every
        /// comparison against it comes back empty, so nothing is ever blamed on
        /// a run whose starting state nobody recorded.
        static let unreadable = RootSnapshot(paths: nil)
    }

    /// Reads the project root's uncommitted paths. `nil` root — or a git that
    /// cannot answer — gives `.unreadable`.
    static func snapshotProjectRoot(_ projectRoot: URL?) async -> RootSnapshot {
        guard let projectRoot else { return .unreadable }
        let root = projectRoot.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            let status = SubprocessOutput.git(["-C", root, "status", "--porcelain"])
            guard status.status == 0 else { return RootSnapshot.unreadable }
            return RootSnapshot(paths: Set(porcelainPaths(status.output)))
        }.value
    }

    /// A newly-dirty path split by who dirtied it — the run's own session, or
    /// someone else's, read while the run was up.
    ///
    /// Attribution by presence — "the checkout is dirty, so the run did it" —
    /// blames the wrong actor whenever anything else touches the same checkout
    /// while a run is in flight: a human editing alongside it, a second Claude
    /// Code session, the approval gate's own verify writing an instrument file.
    /// Three travel runs were blocked this way on 2026-08-28, none of them
    /// having actually left its worktree. `attributed` is what still blocks a
    /// run; `foreign` is recorded on the item and never does.
    struct StrayWorkReport: Equatable {
        /// Newly-dirty paths this session wrote itself, through `Edit`,
        /// `Write` or `NotebookEdit` — what `strayWorkRefusal` blocks on.
        let attributed: [String]
        /// Newly-dirty paths nothing says this session wrote. Not evidence
        /// against the run; recorded on the item so a human can see the
        /// checkout moved without either blaming or hiding it.
        let foreign: [String]

        static let clean = StrayWorkReport(attributed: [], foreign: [])
    }

    /// Paths that became dirty in the project root while an isolated run was in
    /// flight, split into what this session wrote and what it did not —
    /// `writtenBySession` is the set `Orchestrator.writtenPaths(for:)` collects
    /// off the worker's and reviewer's own `Write`/`Edit`/`MultiEdit`/
    /// `NotebookEdit` tool calls (`writtenPath(toolName:input:relativeTo:)`).
    ///
    /// `isolated` is the whole precondition: with isolation off the live tree is
    /// exactly where the work is meant to go, and every path here would be a
    /// finding about a run doing its job.
    static func strayWork(
        projectRoot: URL?,
        since baseline: RootSnapshot,
        isolated: Bool,
        writtenBySession: Set<String> = [],
        ignoring prefixes: [String] = []
    ) async -> StrayWorkReport {
        guard isolated, let projectRoot else { return .clean }
        let after = await snapshotProjectRoot(projectRoot)
        let dirty = strayPaths(before: baseline.paths, after: after.paths, ignoring: prefixes)
        return attributeStrayPaths(dirty, projectRoot: projectRoot, writtenBySession: writtenBySession)
    }

    /// The attribution rule, over paths already known to be newly dirty — pure,
    /// so it can be checked without a repository on disk. A path resolves
    /// against `projectRoot` to compare against `writtenBySession`, which holds
    /// the absolute path each of the session's file-writing tool calls named.
    static func attributeStrayPaths(
        _ paths: [String],
        projectRoot: URL,
        writtenBySession: Set<String>
    ) -> StrayWorkReport {
        guard !paths.isEmpty else { return .clean }
        let written = Set(writtenBySession.map(normalizedPath))
        var attributed: [String] = []
        var foreign: [String] = []
        for path in paths {
            let absolute = normalizedPath(projectRoot.appendingPathComponent(path).path)
            if written.contains(absolute) {
                attributed.append(path)
            } else {
                foreign.append(path)
            }
        }
        return StrayWorkReport(attributed: attributed, foreign: foreign)
    }

    /// The sentence written to an item's `## Notes` for dirt that appeared in
    /// the checkout during a run without the run having written it — nil when
    /// there is none, so the ordinary run says nothing.
    static func foreignDirtNote(paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        return "the checkout changed during this run — \(paths.joined(separator: ", ")) — not by the run"
    }

    /// Standardised so a path recorded off a tool call and one resolved from a
    /// `git status` line compare equal even when one carries a `..` or a
    /// double slash the other does not — and with symlinks resolved, so a
    /// checkout reached as `/var/…` and a tool call naming `/private/var/…`
    /// are the same file.
    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The tools that write a file, and the input key that names it.
    private static let writingToolPathKeys: [String: String] = [
        "Write": "file_path", "Edit": "file_path", "MultiEdit": "file_path",
        "NotebookEdit": "notebook_path",
    ]

    /// The file a tool call writes, as an absolute path — nil for a tool that
    /// writes no file (`Read`, `Bash`, `Grep`, …) or input that names none. A
    /// relative path resolves against `cwd`, the session's working directory,
    /// which is where the CLI would have written it.
    ///
    /// Pure, so the rule for what counts as the session's own write is
    /// checkable without a stream; `ChatViewModel` feeds every tool call it
    /// sees through it into `Orchestrator.recordWrittenPath(_:for:)`.
    static func writtenPath(toolName: String, input: String, relativeTo cwd: URL) -> String? {
        guard let key = writingToolPathKeys[toolName],
              let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json[key] as? String, !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : cwd.appendingPathComponent(path)
        return url.standardizedFileURL.path
    }

    /// The rule, over path sets already read — pure, so it can be checked
    /// without a repo on disk.
    ///
    /// Only paths that were *not* dirty before and are dirty now count. A read
    /// that failed on either side answers empty: "nobody could tell" is not
    /// evidence, and this signal blocks an item, so it fails towards letting the
    /// run through rather than towards accusing it.
    ///
    /// `prefixes` are the paths the run's own bookkeeping writes — the backlog
    /// file it moves through its statuses, the detail file it appends Notes to.
    /// Those land in the project root by design and are not the worker's edits.
    static func strayPaths(
        before: Set<String>?,
        after: Set<String>?,
        ignoring prefixes: [String] = []
    ) -> [String] {
        guard let before, let after else { return [] }
        return after
            .subtracting(before)
            .filter { path in !prefixes.contains { !$0.isEmpty && path.hasPrefix($0) } }
            .sorted()
    }

    /// The sentence a run that wrote outside its worktree is reported with,
    /// naming the paths — capped, because a run that dirtied a hundred files
    /// must not produce a log line nobody can read. Nil when there is nothing
    /// to report, so the ordinary run says nothing.
    static func strayWorkRefusal(paths: [String], maxPaths: Int = 3) -> String? {
        guard !paths.isEmpty else { return nil }
        let shown = paths.prefix(maxPaths).joined(separator: ", ")
        let extra = paths.count - min(paths.count, maxPaths)
        let named = extra > 0 ? "\(shown) (+\(extra) more)" : shown
        return "\(strayWorkPrefix) — \(paths.count == 1 ? "1 path" : "\(paths.count) paths") "
             + "changed in the project's checkout instead of the branch: \(named)"
    }

    /// The paths in `git status --porcelain` output, rename targets and all.
    /// Shares `WorktreeManager`'s reading so the two cannot disagree about what
    /// a status line names — that type already unquotes and splits renames, and
    /// a second parser here is a second set of edge cases.
    private nonisolated static func porcelainPaths(_ porcelain: String) -> [String] {
        let tree = WorktreeManager.classify(porcelain: porcelain)
        return tree.modified + tree.untracked
    }
    // MARK: - What a run left behind

    /// What a finished run left on its branch, in the words the run log, the
    /// run's recorded outcome and the item's Notes all use.
    ///
    /// The same question `inspect` answers, carried one detail further: *how
    /// much*, and *where*. A blocked run commits its work and keeps its
    /// worktree, and nothing downstream can point a reader at that work without
    /// a file count and a path to name — which is how six finished files sat
    /// unmentioned while the item was re-run twice (2026-08-08).
    struct LeftBehind: Equatable {
        let verdict: Verdict
        /// The branch the work is on, when the run had one.
        let branch: String?
        /// Files the branch's commits change against the project's `HEAD`. Zero
        /// unless `verdict` is `.produced`, and zero as well when git could be
        /// asked for the branch but not for the list — a count is never
        /// invented.
        let fileCount: Int
        /// The worktree still on disk, when teardown kept one.
        let worktreePath: String?

        /// Whether this run left anything a reader could pick up.
        ///
        /// `.unknown` answers no, like the three empty verdicts: a run nobody
        /// could read is not a run that left work, and claiming otherwise sends
        /// a human looking for a branch that was never there.
        var hasWork: Bool { verdict == .produced }

        /// The sentence that names the work — nil when there is none to name,
        /// so a run that genuinely produced nothing says nothing rather than
        /// reporting an empty find.
        var summary: String? {
            guard hasWork else { return nil }
            let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
            var text = fileCount > 0 ? "\(files) of work left behind" : "work left behind"
            if let branch { text += " on branch \(branch)" }
            if let worktreePath { text += " (worktree \(worktreePath))" }
            return text
        }
    }

    /// Reads `inspect`, then — only for a run git already agrees produced
    /// something — how many files it touched. `worktreePath` is whatever
    /// teardown kept on disk; it is reported, not verified, because the caller
    /// is the thing that just decided to keep it.
    static func leftBehind(
        projectRoot: URL?,
        branch: String?,
        isolated: Bool,
        worktreePath: URL? = nil
    ) async -> LeftBehind {
        let verdict = await inspect(projectRoot: projectRoot, branch: branch, isolated: isolated)
        let kept = worktreePath?.path(percentEncoded: false)
        guard verdict == .produced, let projectRoot, let branch else {
            return LeftBehind(verdict: verdict, branch: branch, fileCount: 0, worktreePath: kept)
        }
        // A count is never invented: git could be asked for the branch but not
        // for the list, and `fileCount` says zero rather than guessing — which is
        // what its own doc comment promises.
        let files = await changedFiles(projectRoot: projectRoot, branch: branch) ?? []
        return LeftBehind(verdict: verdict, branch: branch, fileCount: files.count, worktreePath: kept)
    }

    /// The repo-relative paths a run's branch changes against the project's
    /// `HEAD`, in git's order.
    ///
    /// Nil — not `[]` — when git couldn't be asked, for the same reason
    /// `uncommittedFileCount` answers nil and `Verdict.unknown` exists: a diff
    /// nobody could read is a different fact from a diff with nothing in it, and
    /// only the second one is evidence about the run. It matters because a caller
    /// reading emptiness as an answer draws a conclusion from it —
    /// `VerifyCoverage.evaluate` calls an empty path list covered, so a run whose
    /// branch had been deleted passed the coverage gate having checked nothing,
    /// indistinguishable in the log from one that was genuinely covered.
    ///
    /// `leftBehind` counts these; `VerifyCoverage` asks which of them a mapped
    /// glob touches. One `git diff` behind both, so the two can't disagree about
    /// what a run changed.
    static func changedFiles(projectRoot: URL, branch: String) async -> [String]? {
        let root = projectRoot.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            let result = SubprocessOutput.git(["-C", root, "diff", "--name-only", "HEAD...\(branch)"])
            guard result.status == 0 else { return nil }
            return result.output
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.value
    }

    /// Paths a kept worktree still holds uncommitted — the other half of what a
    /// blocked run left behind.
    ///
    /// A run that reached review committed everything to its branch, so the
    /// branch diff is the whole story. A run that ended blocked — stalled, timed
    /// out, capped, rejected — has its worktree kept, and whatever teardown
    /// could not commit is sitting in it. Counting only the branch would record
    /// such a run as having changed nothing, and since a run recorded as empty
    /// now costs the item an attempt against `RetryCeiling`, that reading has a
    /// price.
    ///
    /// Nil — not 0 — when git couldn't be read, so an unreadable worktree is
    /// never mistaken for a clean one. Untracked files count as work, ignored
    /// ones (build output) do not: the same `git status --porcelain` line
    /// `inspectBlocked` reads its dirty/clean answer from, so the count and the
    /// verdict cannot disagree.
    static func uncommittedFileCount(worktree: URL) async -> Int? {
        let tree = worktree.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            let status = SubprocessOutput.git(["-C", tree, "status", "--porcelain"])
            guard status.status == 0 else { return nil }
            return status.output.split(whereSeparator: \.isNewline)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count
        }.value
    }

    /// The paths a kept worktree still holds uncommitted — `uncommittedFileCount`
    /// with the names it counted.
    ///
    /// Read through the same `porcelainPaths` the count uses, so the list and
    /// the number cannot disagree about one worktree.
    ///
    /// Nil — not `[]` — when git could not be read, so an unreadable worktree is
    /// never mistaken for one that changed nothing.
    static func uncommittedPaths(worktree: URL) async -> [String]? {
        let tree = worktree.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            let status = SubprocessOutput.git(["-C", tree, "status", "--porcelain"])
            guard status.status == 0 else { return nil }
            return porcelainPaths(status.output)
        }.value
    }

    /// The two halves as the one number a metric record keeps.
    ///
    /// Added rather than merged: teardown commits everything it can, so a run
    /// with commits has a clean worktree and a run with a dirty worktree is one
    /// whose commit did not happen — the two are disjoint in practice. Nil only
    /// when *neither* half could be read, which is a live-tree run: "nobody
    /// could tell" and "changed nothing" are different facts, and only the
    /// second one counts against the item.
    static func totalChangedFiles(committed: Int?, uncommitted: Int?) -> Int? {
        guard committed != nil || uncommitted != nil else { return nil }
        return (committed ?? 0) + (uncommitted ?? 0)
    }

    /// The rules, over signals already read — pure, so they can be checked
    /// without a repo on disk. A nil argument is "couldn't tell", which stops
    /// the read rather than counting against the run.
    static func verdict(branchResolves: Bool?, commits: Int?, hasDiff: Bool?) -> Verdict {
        guard let branchResolves else { return .unknown }
        guard branchResolves else { return .noBranch }
        guard let commits else { return .unknown }
        guard commits > 0 else { return .noCommits }
        guard let hasDiff else { return .unknown }
        return hasDiff ? .produced : .emptyDiff
    }

    /// The item a run's branch name was built from, or nil when the name isn't
    /// one autopilot made — a human's branch carries no item id, and a commit
    /// subject matched against a guess at one would be a coincidence.
    ///
    /// Read back through `WorktreeSession.branchName(for:)` rather than by
    /// splitting on the prefix a second time, so the naming stays defined in the
    /// one place that builds it.
    static func itemID(fromBranch branch: String) -> String? {
        guard let slash = branch.lastIndex(of: "/") else { return nil }
        let candidate = String(branch[branch.index(after: slash)...])
        guard !candidate.isEmpty,
              WorktreeSession.branchName(for: candidate) == branch else { return nil }
        return candidate
    }

    /// The commit subject `WorktreeSession.commitWork(message:)` writes for an
    /// item's work at teardown, as the readers spell it.
    ///
    /// One definition on this side because there are now two readers — the
    /// per-item scan below and `StrandedWorkSweep`'s project-wide one — and a
    /// subject they spell differently is a dropped branch one of them fails to
    /// recognise, silently and in exactly the case both exist to catch.
    nonisolated static func teardownSubject(for itemID: String) -> String {
        "autopilot: \(itemID)"
    }

    /// Whether a commit this run wrote is still in the object store with nothing
    /// pointing at it — the shape left behind when teardown drops a branch whose
    /// commits were real.
    ///
    /// `--no-reflogs` because the reflog of a deleted branch goes with it and
    /// `HEAD`'s would otherwise keep the commit reachable, hiding exactly the
    /// case this asks about. The subject is the one `WorktreeSession
    /// .commitWork(message:)` writes at teardown, so a dangling commit from some
    /// other item — or from a human — is not read as this run's work.
    ///
    /// A full object scan — ~2s on this repository — so it is asked only after
    /// the cheap ref read has already come back empty, never on the path a run
    /// that produced a branch takes.
    ///
    /// Output is parsed whatever git exits with: `fsck` reports a repository
    /// with unrelated problems as a failure while still printing the dangling
    /// objects, and a command that never ran prints nothing, which reads as no
    /// match anyway.
    ///
    /// Not private because `ItemGitTruth.read` asks the same question, on the
    /// same arm — a ref that did not resolve — so the item detail and the run
    /// log cannot disagree about whether a dropped branch's work survives.
    nonisolated static func orphanedCommitExists(root: String, itemID: String) -> Bool {
        // A tip `WorktreeManager.backUpUnmergedTip` kept is this item's work
        // with no branch — the same answer, without the scan.
        let backups = SubprocessOutput.git(["-C", root, "for-each-ref", "refs/kiteloop/backup/\(itemID)/"])
        if backups.status == 0, !backups.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let subject = teardownSubject(for: itemID)
        let fsck = SubprocessOutput.git(["-C", root, "fsck", "--no-reflogs", "--dangling"])
        for line in fsck.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0] == "dangling", parts[1] == "commit" else { continue }
            let logged = SubprocessOutput.git(["-C", root, "log", "-1", "--format=%s", String(parts[2])])
            guard logged.status == 0 else { continue }
            if logged.output.trimmingCharacters(in: .whitespacesAndNewlines) == subject {
                return true
            }
        }
        return false
    }
}
