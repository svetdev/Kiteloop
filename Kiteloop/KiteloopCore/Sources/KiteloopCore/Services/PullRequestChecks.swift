import Foundation

/// Follows the pull request `PullRequestPublisher` just opened until its checks
/// are green — the stage between "a PR exists" and "a human is summoned".
///
/// Opening a PR and walking away re-inserts the human below the gate ADR-0001
/// placed them above: a red CI check sits there until somebody notices, and the
/// first thing they do is what a worker could have done unattended. So the run
/// polls the checks, hands a failing one back to the worker for a bounded number
/// of fix rounds, and only then opens the gate — or gives up and says which
/// check it gave up on.
///
/// Three properties are load-bearing and are enforced here rather than left to
/// the caller:
///
/// * **Every state is terminal or waiting, never both.** `next` is a total
///   function over the five states, so a loop driven by it stops polling the
///   moment it returns `.finish` — there is no path that keeps asking `gh`
///   after a verdict.
/// * **A PR with no checks is green, after a short grace.** A project with no
///   CI must not wait out the deadline before its human is told; but an empty
///   answer within `noChecksGrace` of the last push means GitHub hasn't
///   registered the run yet, not that there is no CI, so `next` waits it out
///   before reading zero checks as nothing to wait for.
/// * **Rounds are capped, spend is capped harder.** Two fix rounds is the round
///   limit, but the item's own cost cap is the real backstop — `canAffordFix`
///   ends the loop with the failing check named rather than starting a round
///   the item can't pay for.
///
/// The decisions — how `gh`'s output reads, which bucket is a failure, what the
/// item's Notes say — are pure statics, so they can be checked without a
/// network, a repository or a GitHub account.
package enum PullRequestChecks {

    // MARK: - What is being followed

    /// One check on the pull request, as `gh pr checks --json` reports it.
    package struct Check: Equatable, Sendable {
        package let name: String
        /// `gh`'s own summary of where the check stands: `pass`, `fail`,
        /// `pending`, `skipping` or `cancel`. Normalised by `normalisedBucket`
        /// when `gh` reported none.
        package let bucket: String
        /// Where the check reports — an Actions job URL for a workflow check,
        /// which is what its log can be fetched by.
        package let link: String
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(name: String, bucket: String, link: String) {
            self.name = name
            self.bucket = bucket
            self.link = link
        }
    }

    /// Where the pull request's checks stand right now.
    package enum State: Equatable {
        /// Nothing is failing and nothing is still running.
        case green(checks: Int)
        /// `gh` reported no checks at all — either its "no checks reported"
        /// error, or an empty list. Ambiguous on its own: a check GitHub
        /// hasn't registered yet reads identically to a project with no CI at
        /// all, so `next` holds this for `noChecksGrace` before reading it as
        /// the latter.
        case noChecksYet
        /// At least one check failed; this is the first of them.
        case failing(Check)
        case pending(checks: Int)
        /// `gh` couldn't be asked, or answered something unreadable. Terminal —
        /// a loop that can't read the checks will not start reading them by
        /// asking again.
        case unavailable(reason: String)
    }

    /// How following the checks ended. Every case is terminal.
    package enum Outcome: Equatable {
        case green(checks: Int, rounds: Int, duration: TimeInterval)
        /// The loop stopped with a check still red. `reason` says what stopped
        /// it — rounds spent, cost cap, a fix round that couldn't run.
        case gaveUp(check: String, rounds: Int, reason: String)
        case timedOut(pending: Int, duration: TimeInterval)
        case unavailable(reason: String)

        package var isGreen: Bool {
            if case .green = self { return true }
            return false
        }
    }

    /// What the loop does next. Returned by `next`, which is the whole control
    /// flow of following a pull request expressed as one pure function.
    package enum Step: Equatable {
        case wait
        case fix(Check)
        case finish(Outcome)
    }

    /// How many times a failing check is handed back to the worker. Two: a pull
    /// request that fails CI twice with the worker looking at the failure both
    /// times needs a human, not a third identical attempt.
    package static let maxFixRounds = 2

    /// How long between polls. CI runs take minutes; polling faster buys
    /// nothing and spends a `gh` invocation each time.
    package static let pollInterval: TimeInterval = 30

    /// How long a run will wait for checks that never settle. Past it the item
    /// goes to the gate anyway with what was still running — an unattended run
    /// must not hold a queue open on a stuck CI provider.
    package static let deadline: TimeInterval = 40 * 60

    /// How long an empty check list is held as "GitHub hasn't registered the
    /// run yet" before it's read as "this project has no CI". Well under
    /// `deadline`: a project that genuinely has no checks must still reach its
    /// human in a couple of minutes, not wait out the full deadline first.
    package static let noChecksGrace: TimeInterval = 2 * 60

    /// How much of a failing check's log the worker is handed. Enough for a
    /// build failure's error lines and the summary under them, small enough not
    /// to become the whole prompt.
    package static let logTailBytes = 12_000

    // MARK: - The loop, as a decision

    /// What to do given where the checks stand. Total over `State`, so a caller
    /// is a `while` around this and nothing else.
    ///
    /// `canAffordFix` is the item's cost cap, asked *before* a round is started:
    /// the cap is the spend backstop, and a round that would breach it is not
    /// worth starting to find out.
    ///
    /// `sinceNoChecksOpportunity` is the no-checks clock: how long it has been
    /// since checks could last have started (following began, or a fix round's
    /// push landed) — not how long the item has been followed overall. Nil
    /// defaults it to `elapsed`, which is exactly right the first time through
    /// the loop, before any push has happened.
    package static func next(
        state: State,
        roundsUsed: Int,
        elapsed: TimeInterval,
        sinceNoChecksOpportunity: TimeInterval? = nil,
        canAffordFix: Bool,
        maxRounds: Int = maxFixRounds,
        deadline: TimeInterval = deadline
    ) -> Step {
        switch state {
        case .unavailable(let reason):
            return .finish(.unavailable(reason: reason))
        case .green(let checks):
            return .finish(.green(checks: checks, rounds: roundsUsed, duration: elapsed))
        case .noChecksYet:
            guard (sinceNoChecksOpportunity ?? elapsed) >= noChecksGrace else { return .wait }
            return .finish(.green(checks: 0, rounds: roundsUsed, duration: elapsed))
        case .failing(let check):
            guard roundsUsed < maxRounds else {
                let rounds = maxRounds == 1 ? "one fix round" : "\(maxRounds) fix rounds"
                return .finish(.gaveUp(check: check.name, rounds: roundsUsed,
                                       reason: "\(rounds) did not make it green"))
            }
            guard canAffordFix else {
                return .finish(.gaveUp(check: check.name, rounds: roundsUsed,
                                       reason: "the item's cost cap is spent"))
            }
            return .fix(check)
        case .pending(let checks):
            guard elapsed < deadline else {
                return .finish(.timedOut(pending: checks, duration: elapsed))
            }
            return .wait
        }
    }

    /// Whether the item can pay for another fix round. Uncapped items always
    /// can; a capped one stops at the ceiling it was started with, which is the
    /// same number the run loop measures the item against.
    package static func canAfford(spentUSD: Double, capUSD: Double?) -> Bool {
        guard let capUSD else { return true }
        return spentUSD < capUSD
    }

    // MARK: - Reading what `gh` said

    /// The checks in a `gh pr checks --json …` transcript, or nil when there is
    /// no readable list in it.
    ///
    /// Every balanced `[…]` slice is tried, not the first, and not from a `[` to
    /// the end of the output: `gh` prints advice above its output and notices
    /// below it — stderr is merged into the same capture — so the array is
    /// routinely neither the first bracket nor the last thing printed, and a
    /// slice running to end-of-output would hand `JSONSerialization` a trailing
    /// release notice it can only reject.
    package static func checks(inJSON output: String) -> [Check]? {
        for slice in StructuredOutputExtractor.balancedSlices(in: output, open: "[", close: "]") {
            guard let data = slice.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { continue }
            return rows.map {
                Check(
                    name: ($0["name"] as? String) ?? "check",
                    bucket: normalisedBucket(bucket: ($0["bucket"] as? String) ?? "",
                                             state: ($0["state"] as? String) ?? ""),
                    link: ($0["link"] as? String) ?? ""
                )
            }
        }
        return nil
    }

    /// `gh`'s bucket when it gave one, else the same verdict derived from the
    /// raw `state`. Older `gh` versions export no bucket, and every check
    /// reading as "no bucket" would otherwise look pending forever.
    package static func normalisedBucket(bucket: String, state: String) -> String {
        let bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !bucket.isEmpty { return bucket }
        switch state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "SUCCESS", "NEUTRAL", "SKIPPED": return "pass"
        case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": return "fail"
        case "CANCELLED": return "cancel"
        default: return "pending"
        }
    }

    /// Where a list of checks leaves the pull request. A failure wins over a
    /// pending check: the run has something to hand the worker, and waiting for
    /// the rest to finish first only spends the deadline.
    package static func classify(_ checks: [Check]) -> State {
        guard !checks.isEmpty else { return .noChecksYet }
        if let failing = checks.first(where: { isFailure($0.bucket) }) { return .failing(failing) }
        let pending = checks.filter { isPending($0.bucket) }
        guard pending.isEmpty else { return .pending(checks: pending.count) }
        return .green(checks: checks.count)
    }

    package static func isFailure(_ bucket: String) -> Bool {
        bucket == "fail" || bucket == "cancel"
    }

    package static func isPending(_ bucket: String) -> Bool {
        bucket == "pending"
    }

    /// What one `gh pr checks` invocation means.
    ///
    /// A pull request with no checks at all is `gh`'s *error* case — it exits
    /// non-zero saying so. That reads the same whether GitHub simply hasn't
    /// registered the run yet or the project has no CI at all, so it is
    /// `.noChecksYet` here and `next` is what tells the two apart.
    package static func state(exitStatus: Int32, output: String) -> State {
        if let checks = checks(inJSON: output) { return classify(checks) }
        if output.range(of: "no checks reported", options: .caseInsensitive) != nil {
            return .noChecksYet
        }
        guard exitStatus != 0 else {
            return .unavailable(reason: "gh pr checks printed no check list")
        }
        return .unavailable(reason: "gh pr checks failed"
                                  + PullRequestPublisher.failureDetail(output))
    }

    /// The Actions job id in a check's link (`…/actions/runs/12/job/34` → `34`),
    /// which is what its log can be fetched by. Nil for a check that doesn't
    /// report through Actions — an external status has no log to fetch.
    package static func jobID(inLink link: String) -> String? {
        guard let range = link.range(of: #"/job/\d+"#, options: .regularExpression) else { return nil }
        return String(link[range].dropFirst("/job/".count))
    }

    // MARK: - What the worker and the Notes are told

    /// The prompt one fix round hands the worker. Deliberately narrow: the diff
    /// on this branch has already been reviewed and approved, so anything
    /// beyond what the failing check demands is a change nobody reviewed.
    package static func fixPrompt(
        item: BacklogItem,
        branch: String,
        url: String,
        check: Check,
        log: String,
        round: Int,
        buildOutputNote: String?
    ) -> String {
        var parts = ["""
        The pull request for `\(item.id)` — \(item.title) — is failing CI.

        Pull request: \(url)
        Failing check: \(check.name)\(check.link.isEmpty ? "" : " (\(check.link))")
        Fix round \(round) of \(maxFixRounds).
        """]
        if !log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("## What the check printed\n\n```\n\(log)\n```")
        } else {
            parts.append("## What the check printed\n\nNothing could be fetched for this check — "
                         + "open the link above, or reproduce the failure locally.")
        }
        if let buildOutputNote, !buildOutputNote.isEmpty {
            parts.append("## Build Output\n\n\(buildOutputNote)")
        }
        parts.append("""
        ## What to do

        You are in a git worktree checked out on `\(branch)` — the branch this pull \
        request is built from. Fix the cause of this failure and nothing else: the \
        work on this branch has already been reviewed and approved, so any change \
        beyond what the failing check demands is out of scope and unreviewed. \
        Commit your fix; the run pushes the branch for you afterwards and re-reads \
        the checks.

        If nothing on this branch can fix it — an infrastructure outage, a missing \
        secret, a check unrelated to this diff — say so plainly and change nothing. \
        A commit that doesn't address the failure costs the item its remaining fix \
        round.
        """)
        return parts.joined(separator: "\n\n")
    }

    /// The line the item's Notes and the run log both get, next to the pull
    /// request's own note. One phrasing for both so the log and the backlog
    /// can't come to disagree about how the pull request ended up.
    package static func note(for outcome: Outcome) -> String {
        switch outcome {
        case .green(let checks, let rounds, let duration):
            guard checks > 0 else { return "Pull request has no checks — nothing to wait for" }
            return "Pull request checks green (\(count(checks, "check"))\(roundsPhrase(rounds))"
                 + ", \(durationPhrase(duration)))"
        case .gaveUp(let check, let rounds, let reason):
            return "Pull request check \(check) is still failing — \(reason)"
                 + " (\(count(rounds, "fix round")) spent); the gate is yours"
        case .timedOut(let pending, let duration):
            return "Pull request checks were still running after \(durationPhrase(duration)) "
                 + "(\(count(pending, "check")) pending) — going to the gate without them"
        case .unavailable(let reason):
            return "Pull request checks not followed — \(reason)"
        }
    }

    /// The clause appended to the approval-gate notification, so the human being
    /// summoned learns the state of the pull request in the same breath as the
    /// summons. Nil when there is nothing to add.
    package static func gateDetail(for outcome: Outcome) -> String? {
        switch outcome {
        case .green(let checks, _, _):
            return checks > 0 ? "PR green" : "PR has no checks"
        case .gaveUp(let check, _, _):
            return "PR check failing: \(check)"
        case .timedOut:
            return "PR checks still running"
        case .unavailable:
            return "PR checks could not be read"
        }
    }

    package static func durationPhrase(_ seconds: TimeInterval) -> String {
        DurationPhrase.phrase(seconds)
    }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    private static func roundsPhrase(_ rounds: Int) -> String {
        rounds == 0 ? "" : ", after \(count(rounds, "fix round"))"
    }

    /// The tail of a check's log — the end is where the error is.
    package static func clip(_ text: String, maxBytes: Int = logTailBytes) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let kept = String(decoding: text.utf8.suffix(maxBytes), as: UTF8.self)
        let firstLine = kept.firstIndex(of: "\n").map { kept.index(after: $0) } ?? kept.startIndex
        return "… (earlier output omitted)\n" + String(kept[firstLine...])
    }

    // MARK: - Talking to GitHub

    /// Where the pull request's checks stand, asked of `gh`. Runs off the
    /// calling actor — every step is a subprocess talking to a network.
    package static func poll(pullRequest url: String, in projectRoot: URL) async -> State {
        await Task.detached(priority: .userInitiated) {
            guard let gh = PullRequestPublisher.resolveGH() else {
                return State.unavailable(reason: "the GitHub CLI (gh) is not installed")
            }
            let result = PullRequestPublisher.run(
                gh, ["pr", "checks", url, "--json", "name,state,bucket,link"], in: projectRoot)
            return state(exitStatus: result.status, output: result.output)
        }.value
    }

    /// What the failing check printed, for the worker to read. Empty when the
    /// check reports somewhere `gh` can't fetch a log from — the prompt says so
    /// rather than pretending the check was silent.
    package static func failureLog(for check: Check, in projectRoot: URL) async -> String {
        guard let jobID = jobID(inLink: check.link) else { return "" }
        return await Task.detached(priority: .userInitiated) {
            guard let gh = PullRequestPublisher.resolveGH() else { return "" }
            let result = PullRequestPublisher.run(
                gh, ["run", "view", "--job", jobID, "--log-failed"], in: projectRoot)
            return clip(result.output)
        }.value
    }

    /// Pushes a fix round's commits to the branch the pull request is built
    /// from. Nil on success, else why it failed.
    ///
    /// Pushed explicitly by ref rather than relying on the upstream the publisher
    /// set: this runs in a worktree the run re-created, and a push that resolves
    /// its destination from local config is a push that can go somewhere else.
    package static func push(branch: String, from worktree: URL, projectRoot: URL) async -> String? {
        let root = projectRoot.path(percentEncoded: false)
        let path = worktree.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            let remotes = PullRequestPublisher.runGit(["-C", root, "remote"])
            guard remotes.status == 0,
                  let remote = PullRequestPublisher.remoteName(fromRemoteList: remotes.output)
            else { return "the project has no git remote" }
            let push = PullRequestPublisher.runGit(
                ["-C", path, "push", remote, "HEAD:refs/heads/\(branch)"])
            guard push.status == 0 else {
                return "pushing \(branch) to \(remote) failed"
                     + PullRequestPublisher.failureDetail(push.output)
            }
            return nil
        }.value
    }

    /// The commit a worktree is sitting on. Read either side of a fix round to
    /// tell "the worker fixed something" from "the worker changed nothing" —
    /// the second is the round that must not silently consume the next one.
    package static func headSHA(in worktree: URL) async -> String? {
        let path = worktree.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let result = PullRequestPublisher.runGit(["-C", path, "rev-parse", "HEAD"])
            guard result.status == 0 else { return nil }
            let sha = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return sha.isEmpty ? nil : sha
        }.value
    }
}
