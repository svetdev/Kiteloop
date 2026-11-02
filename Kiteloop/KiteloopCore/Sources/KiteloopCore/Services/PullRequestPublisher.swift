import Foundation

/// The PR half of ADR-0001 (sandbox → **PR** → human gate): pushes a finished
/// run's branch and opens a pull request for it.
///
/// Until this existed a successful unattended run ended with a branch and an
/// in-app approval gate, and nothing else — the work could only be reviewed
/// inside Kiteloop or by checking the branch out by hand. A PR puts the same
/// diff where code review already happens, without changing what the gate does:
/// the pull request is opened, never merged, and `autoMergeOnApproval` still
/// decides on its own whether the branch lands.
///
/// **A missing prerequisite is not a failed run.** A project with no remote, a
/// machine without the GitHub CLI, a `gh` nobody has logged in to, a push the
/// remote refuses — each of those ends as `.skipped(reason:)`, which the caller
/// writes into the item's Notes. The run already succeeded by then; refusing to
/// finish it over a missing side effect would throw away the work.
///
/// The decisions — which remote, what the PR says, what the Notes say, where the
/// URL is in `gh`'s output — are pure statics, so they can be checked without a
/// repository, a network or a GitHub account.
package enum PullRequestPublisher {

    /// What came of trying to open the pull request. `skipped` carries the
    /// sentence the item's Notes get, so a reader months later can tell "PRs are
    /// off" from "nobody had logged `gh` in".
    package enum Outcome: Equatable {
        case opened(url: String)
        case skipped(reason: String)
    }

    /// How long a push or a `gh pr create` may take before it is killed. Both
    /// talk to a network that can hang; an unattended run must not hang with
    /// them, and a timeout here costs the PR rather than the item.
    package static let commandTimeout: TimeInterval = 180

    // MARK: - Opening the pull request

    /// Pushes `branch` to the project's remote and opens a PR for it, against
    /// `base` when the project names one and otherwise against the branch the
    /// checkout is on (`targetBranch`).
    ///
    /// Runs off the calling actor: the caller is `@MainActor` and every step
    /// here is a subprocess that talks to a network.
    package static func open(
        projectRoot: URL?,
        branch: String,
        base: String? = nil,
        title: String,
        body: String
    ) async -> Outcome {
        guard let projectRoot else { return .skipped(reason: "no project root to push from") }
        let root = projectRoot.path(percentEncoded: false)
        return await Task.detached(priority: .userInitiated) {
            let remotes = runGit(["-C", root, "remote"])
            guard remotes.status == 0, let remote = remoteName(fromRemoteList: remotes.output) else {
                return Outcome.skipped(reason: "the project has no git remote")
            }
            guard let gh = resolveGH() else {
                return .skipped(reason: "the GitHub CLI (gh) is not installed")
            }
            guard run(gh, ["auth", "status"], in: projectRoot).status == 0 else {
                return .skipped(reason: "the GitHub CLI (gh) is not authenticated")
            }

            let push = runGit(["-C", root, "push", "--set-upstream", remote, branch])
            guard push.status == 0 else {
                return .skipped(reason: "pushing \(branch) to \(remote) failed"
                                      + failureDetail(push.output))
            }

            var arguments = ["pr", "create", "--head", branch, "--title", title, "--body", body]
            let checkoutHEAD = runGit(["-C", root, "rev-parse", "--abbrev-ref", "HEAD"])
            if let target = targetBranch(configured: base, checkoutHEAD: checkoutHEAD) {
                arguments.append(contentsOf: ["--base", target])
            }
            let created = run(gh, arguments, in: projectRoot)
            // The URL is read out of the output either way: `gh` refuses to
            // create a second PR for a branch that already has one and prints
            // the existing PR's URL as it does, which is the URL this run's work
            // is waiting behind — the honest answer rather than a skip.
            if let url = url(inOutput: created.output) { return .opened(url: url) }
            guard created.status == 0 else {
                return .skipped(reason: "gh pr create failed" + failureDetail(created.output))
            }
            return .skipped(reason: "gh pr create printed no pull request URL")
        }.value
    }

    /// What a run that reached the gate with **no branch behind it** came to.
    ///
    /// That is the ordinary shape of a run made with `useWorktree` off — the
    /// worker edited the live tree, so there is no branch to push and nothing
    /// for a pull request to carry. `open` is not called on this path: its first
    /// act is a `git remote` subprocess, and asking a remote about a branch that
    /// does not exist would answer the wrong question — the note would blame a
    /// missing remote or a missing `gh` for an absence that is neither.
    ///
    /// It is still a `.skipped`, not silence: an operator who turned publishing
    /// on is owed the reason no pull request appeared.
    package static let noBranch = Outcome.skipped(
        reason: "the run produced no branch to open a pull request from"
    )

    // MARK: - What the PR and the Notes say

    /// The PR title: the item's backlog line, as written. The id goes in the
    /// body instead — a title is read in a list of twenty others, and the thing
    /// that tells them apart is what the work was.
    package static func title(for item: BacklogItem) -> String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? item.id : title
    }

    /// The PR body: what the item asked for and what it will be judged against,
    /// which is exactly the pair a reviewer opening the PR needs. Sections with
    /// nothing in them are left out rather than rendered empty, and an item with
    /// no groomed detail at all still gets a body naming it.
    package static func body(item: BacklogItem, detail: BacklogItemDetail?) -> String {
        var parts = ["Backlog item `\(item.id)`."]
        if let what = detail?.what?.trimmingCharacters(in: .whitespacesAndNewlines), !what.isEmpty {
            parts.append("## What\n\n\(what)")
        }
        let criteria = (detail?.acceptanceCriteria ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !criteria.isEmpty {
            parts.append("## Validation\n\n" + criteria.map { "- \($0)" }.joined(separator: "\n"))
        }
        parts.append("---\n\nOpened by Kiteloop autopilot. The item is waiting for approval in "
                     + "Kiteloop; this pull request is the same branch that gate guards.")
        return parts.joined(separator: "\n\n")
    }

    /// The line the item's Notes and the run log both get. One phrasing for both
    /// so the log and the backlog can't come to disagree about what happened.
    package static func note(for outcome: Outcome) -> String {
        switch outcome {
        case .opened(let url): return "Pull request opened: \(url)"
        case .skipped(let reason): return "No pull request opened — \(reason)"
        }
    }

    // MARK: - Reading what the commands said

    /// Which remote to push to, from `git remote`'s output. `origin` wins when
    /// it is there — it is what a clone names its upstream — and otherwise the
    /// first one listed, so a repo whose only remote is called something else
    /// still gets a PR. Nil when there is no remote at all.
    package static func remoteName(fromRemoteList output: String) -> String? {
        let names = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return names.contains("origin") ? "origin" : names[0]
    }

    /// The branch the PR targets: the project's configured base when it has
    /// one — the same branch auto-merge lands on, so the PR and the merge can't
    /// name different targets — and otherwise the branch the project root has
    /// checked out. Nil when neither answers (no setting, and git couldn't say
    /// or the root is on a detached HEAD), in which case the PR is created
    /// without `--base` and GitHub's default branch is the target.
    package static func targetBranch(
        configured: String?, checkoutHEAD: (status: Int32, output: String)
    ) -> String? {
        if let configured = configured?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            return configured
        }
        return baseBranch(from: checkoutHEAD)
    }

    /// The branch the project root has checked out, read off `rev-parse
    /// --abbrev-ref HEAD`. Nil when git couldn't answer or the root is on a
    /// detached HEAD.
    package static func baseBranch(from result: (status: Int32, output: String)) -> String? {
        guard result.status == 0 else { return nil }
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "HEAD" else { return nil }
        return name
    }

    /// The pull request URL in a `gh` transcript. Matched on the GitHub PR shape
    /// rather than on "the first https:// in the output": `gh` prints advice and
    /// documentation links alongside its errors, and any of those would
    /// otherwise be recorded as the run's pull request.
    package static func url(inOutput output: String) -> String? {
        let pattern = #"https://[^\s]+/pull/\d+"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// A failed command's last word, appended to a skip reason — the line that
    /// says *why* the push or the create failed, trimmed to something that fits
    /// in a backlog note. Empty when the command said nothing.
    package static func failureDetail(_ output: String, limit: Int = 200) -> String {
        let last = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        guard let last, !last.isEmpty else { return "" }
        let clipped = last.count > limit ? String(last.prefix(limit)) + "…" : last
        return ": \(clipped)"
    }

    // MARK: - Subprocesses

    /// Where `gh` is, asked of a **login shell**: the app's own environment is
    /// whatever Finder handed it, which on a Homebrew machine does not include
    /// `/opt/homebrew/bin`. Nil when the shell can't find it — the machine has
    /// no GitHub CLI. Resolved once and then invoked by path, so the PR body
    /// never passes through a shell.
    ///
    /// Shared with `PullRequestChecks`, which follows the pull request this type
    /// opened: one resolution of `gh` and one way of running it, so the loop
    /// that watches a PR can't end up talking to a different binary than the one
    /// that created it.
    package nonisolated static func resolveGH() -> URL? {
        let result = run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v gh"], in: nil)
        guard result.status == 0 else { return nil }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    package nonisolated static func runGit(_ args: [String]) -> (status: Int32, output: String) {
        run(URL(fileURLWithPath: "/usr/bin/git"), args, in: nil)
    }

    /// Runs `executable` with `arguments` — an argument **array**, never a shell
    /// string, so a PR body full of backticks and newlines can't be re-read as
    /// shell syntax.
    ///
    /// Output goes to a temporary file rather than a `Pipe()`: draining a pipe
    /// means blocking until the child closes it, which is exactly what a hung
    /// `git push` never does, and `timeout` would then never be reached.
    /// A file lets the wait be a poll. Past the timeout the process is killed
    /// and the command counts as failed. All of that is
    /// `SubprocessOutput.runWithDeadline` now — this used to be its own copy.
    package nonisolated static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL?,
        timeout: TimeInterval = commandTimeout
    ) -> (status: Int32, output: String) {
        let result = SubprocessOutput.runWithDeadline(
            executable: executable.path(percentEncoded: false),
            arguments: arguments,
            directory: directory,
            timeout: timeout
        )
        return (result.status, result.output)
    }

}
