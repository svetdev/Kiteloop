import XCTest
@testable import KiteloopCore

/// The decisions behind ADR-0001's PR half: which remote a branch is pushed to,
/// what the pull request says, what the item's Notes are told, and how `gh`'s
/// output is read back.
///
/// All pure — deliberately. Opening a real pull request needs a GitHub account,
/// a network and a repository nobody minds being written to, none of which a
/// unit test should have; what *can* go wrong without them is the reading and
/// the phrasing, and that is what is asserted here. The one part that touches
/// the world is `open`, checked against a real temporary repository for the case
/// that matters most: a project with no remote must skip with a reason rather
/// than fail the run that already succeeded.
final class PullRequestPublisherTests: XCTestCase {

    // MARK: - Which remote

    /// `origin` wins when it is there — it is what a clone names its upstream,
    /// and a repo that also has a `fork` must not push the run's work to it.
    func testPrefersOriginOverOtherRemotes() {
        XCTAssertEqual(PullRequestPublisher.remoteName(fromRemoteList: "fork\norigin\nupstream\n"), "origin")
    }

    /// A repo whose only remote is called something else still gets a PR: the
    /// alternative is refusing to publish work over a naming convention.
    func testFallsBackToTheFirstRemoteWhenThereIsNoOrigin() {
        XCTAssertEqual(PullRequestPublisher.remoteName(fromRemoteList: "upstream\nfork\n"), "upstream")
    }

    func testNoRemotesMeansNoRemoteName() {
        XCTAssertNil(PullRequestPublisher.remoteName(fromRemoteList: ""))
        XCTAssertNil(PullRequestPublisher.remoteName(fromRemoteList: "\n  \n"))
    }

    // MARK: - Which base branch

    func testBaseBranchIsTheProjectRootsCheckedOutBranch() {
        XCTAssertEqual(PullRequestPublisher.baseBranch(from: (status: 0, output: "main\n")), "main")
    }

    /// A project that names its base opens the PR against it — the same branch
    /// the merge lands on, whatever the checkout happens to be on.
    func testAConfiguredBaseIsTheTargetWhateverTheCheckoutIsOn() {
        XCTAssertEqual(
            PullRequestPublisher.targetBranch(configured: "quality/rebased", checkoutHEAD: (status: 0, output: "main\n")),
            "quality/rebased")
    }

    /// No setting, or a blank one, is the checkout's branch as before — and a
    /// detached checkout still leaves `--base` off for GitHub's default.
    func testWithoutAConfiguredBaseTheCheckoutsBranchIsTheTarget() {
        XCTAssertEqual(PullRequestPublisher.targetBranch(configured: nil, checkoutHEAD: (status: 0, output: "main\n")), "main")
        XCTAssertEqual(PullRequestPublisher.targetBranch(configured: "  ", checkoutHEAD: (status: 0, output: "main\n")), "main")
        XCTAssertNil(PullRequestPublisher.targetBranch(configured: nil, checkoutHEAD: (status: 0, output: "HEAD\n")))
    }

    /// A detached HEAD names no branch, and git that couldn't answer names
    /// nothing either. Both mean "create the PR without `--base`" and let
    /// GitHub's default branch be the target — not "target a branch called
    /// HEAD", which is the ref that would silently be wrong.
    func testDetachedHeadOrAFailedReadTargetsTheRepositoryDefault() {
        XCTAssertNil(PullRequestPublisher.baseBranch(from: (status: 0, output: "HEAD\n")))
        XCTAssertNil(PullRequestPublisher.baseBranch(from: (status: 0, output: "  \n")))
        XCTAssertNil(PullRequestPublisher.baseBranch(from: (status: 128, output: "not a git repository")))
    }

    // MARK: - Reading gh's output

    func testReadsThePullRequestURLOutOfGhsOutput() {
        let output = "https://github.com/acme/kiteloop/pull/42\n"
        XCTAssertEqual(PullRequestPublisher.url(inOutput: output),
                       "https://github.com/acme/kiteloop/pull/42")
    }

    /// `gh` refuses to open a second PR for a branch that already has one and
    /// prints the existing PR's URL as it fails. That URL is the one this run's
    /// work is waiting behind, so it is read out of a *failed* create too.
    func testReadsTheExistingPullRequestURLOutOfAFailedCreate() {
        let output = """
        a pull request for branch "kiteloop/run-output-pr" into branch "main" already exists:
        https://github.com/acme/kiteloop/pull/17
        """
        XCTAssertEqual(PullRequestPublisher.url(inOutput: output),
                       "https://github.com/acme/kiteloop/pull/17")
    }

    /// The match is the PR shape, not "the first https:// in the output".
    /// `gh` prints documentation and advice links alongside its errors, and any
    /// of those would otherwise be recorded as the run's pull request.
    func testDoesNotMistakeAnAdviceLinkForAPullRequest() {
        let output = """
        error: failed to run git: fatal: could not read Username
        Learn more at https://cli.github.com/manual/gh_pr_create
        """
        XCTAssertNil(PullRequestPublisher.url(inOutput: output))
    }

    func testNoURLInSilentOutput() {
        XCTAssertNil(PullRequestPublisher.url(inOutput: ""))
    }

    // MARK: - What the Notes say

    /// The URL is what the note is *for* — an operator reading the backlog has
    /// to be able to click through without opening the run log.
    func testAnOpenedPullRequestIsNotedWithItsURL() {
        let note = PullRequestPublisher.note(for: .opened(url: "https://github.com/acme/k/pull/9"))
        XCTAssertEqual(note, "Pull request opened: https://github.com/acme/k/pull/9")
        XCTAssertTrue(note.contains("https://github.com/acme/k/pull/9"))
    }

    /// A skip has to name its cause. "No pull request" alone is the state a
    /// project with the setting off is in, and the two must not read alike.
    func testASkipIsNotedWithWhy() {
        XCTAssertEqual(PullRequestPublisher.note(for: .skipped(reason: "the project has no git remote")),
                       "No pull request opened — the project has no git remote")
    }

    /// A run made with `useWorktree` off reaches the gate with no branch, so
    /// there is nothing to push. That is a skip like any other and must name its
    /// own cause: the reason is the absent branch, not a missing remote or a
    /// missing `gh` — neither of which was ever asked about, since `open` is not
    /// called on this path.
    func testNoBranchSkipsBecauseTheRunProducedNoBranch() {
        guard case .skipped(let reason) = PullRequestPublisher.noBranch else {
            return XCTFail("a run with no branch opened no pull request, so its outcome is a skip")
        }
        XCTAssertEqual(reason, "the run produced no branch to open a pull request from")
        XCTAssertFalse(reason.contains("remote"))
        XCTAssertFalse(reason.contains("gh"))
    }

    /// And it is *said*: the same "No pull request opened — …" sentence the other
    /// skips get, which is what the run log and the item's Notes both carry. A
    /// run that opened no pull request must not read like one where the setting
    /// was off.
    func testTheNoBranchSkipIsNotedLikeEveryOtherSkip() {
        XCTAssertEqual(PullRequestPublisher.note(for: PullRequestPublisher.noBranch),
                       "No pull request opened — the run produced no branch to open a pull request from")
    }

    /// A failed push or create carries git's own last line into the note, so the
    /// reason is the tool's rather than a paraphrase of it.
    func testAFailedCommandsLastLineBecomesTheReason() {
        let detail = PullRequestPublisher.failureDetail("""
        Enumerating objects: 5, done.
        remote: Permission to acme/kiteloop.git denied.
        """)
        XCTAssertEqual(detail, ": remote: Permission to acme/kiteloop.git denied.")
    }

    /// A note lives in a markdown file a human reads — a 4KB stack trace in it
    /// buries every other note on the item.
    func testALongFailureLineIsClipped() {
        let detail = PullRequestPublisher.failureDetail(String(repeating: "x", count: 500), limit: 20)
        XCTAssertEqual(detail, ": " + String(repeating: "x", count: 20) + "…")
    }

    func testASilentFailureAddsNoDetail() {
        XCTAssertEqual(PullRequestPublisher.failureDetail(""), "")
        XCTAssertEqual(PullRequestPublisher.failureDetail("\n   \n"), "")
    }

    // MARK: - What the pull request says

    func testTitleIsTheItemsBacklogLine() {
        XCTAssertEqual(PullRequestPublisher.title(for: item(title: "Open a PR for a finished run")),
                       "Open a PR for a finished run")
    }

    /// A PR with no title at all is worse than one titled with the item id.
    func testAnEmptyTitleFallsBackToTheItemID() {
        XCTAssertEqual(PullRequestPublisher.title(for: item(title: "   ")), "run-output-pr")
    }

    /// The body is the pair a reviewer opening the PR needs: what was asked for,
    /// and what it will be judged against.
    func testBodyCarriesTheItemIDWhatAndValidation() {
        let body = PullRequestPublisher.body(item: item(), detail: detail())

        XCTAssertTrue(body.contains("`run-output-pr`"), body)
        XCTAssertTrue(body.contains("## What"), body)
        XCTAssertTrue(body.contains("Push the branch and open a pull request."), body)
        XCTAssertTrue(body.contains("## Validation"), body)
        XCTAssertTrue(body.contains("- The URL lands in the item's Notes"), body)
        XCTAssertTrue(body.contains("- The flag defaults to off"), body)
    }

    /// The PR must not read as a merge request: whoever opens it has to know the
    /// gate it answers to is still inside Kiteloop.
    func testBodySaysTheItemIsStillWaitingOnKiteloopsGate() {
        let body = PullRequestPublisher.body(item: item(), detail: detail())
        XCTAssertTrue(body.contains("waiting for approval in Kiteloop"), body)
    }

    /// An item whose detail has no What and no criteria still gets a body that
    /// names it, rather than a PR with empty headings under them.
    func testUngroomedSectionsAreLeftOutRatherThanRenderedEmpty() {
        let body = PullRequestPublisher.body(item: item(), detail: detail(what: nil, criteria: []))

        XCTAssertFalse(body.contains("## What"), body)
        XCTAssertFalse(body.contains("## Validation"), body)
        XCTAssertTrue(body.contains("`run-output-pr`"), body)
    }

    func testAnItemWithNoDetailFileStillGetsABody() {
        let body = PullRequestPublisher.body(item: item(), detail: nil)
        XCTAssertTrue(body.contains("`run-output-pr`"), body)
    }

    // MARK: - The timeout sweeps the whole tree, not just the root

    /// `resolveGH` runs `/bin/zsh -lc`, whose startup files can themselves fork,
    /// and a hung `gh` or `git` is usually itself the child of that shell —
    /// signalling the shell alone leaves whatever it forked running and
    /// reparented. `run` must collect `ProcessTree.descendantPIDs` before it
    /// signals the root, then sweep them once the root is down.
    func testATimedOutCommandsForkedChildIsAlsoKilled() {
        let result = PullRequestPublisher.run(
            URL(fileURLWithPath: "/bin/zsh"), ["-lc", "sleep 810101 & wait"], in: nil, timeout: 1)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(isProcessRunning(matching: "sleep 810101"),
                        "the forked child must not survive the call returning")
    }

    /// The sweep only reaches pids collected as descendants of the process this
    /// call started — never anything merely matching the killed command's text.
    /// A bystander process sharing that text must survive.
    func testASweepLeavesAProcessThatOnlySharesTheKilledCommandsTextAlone() {
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["810102"]
        try? bystander.run()
        defer {
            bystander.terminate()
            bystander.waitUntilExit()
        }

        _ = PullRequestPublisher.run(
            URL(fileURLWithPath: "/bin/zsh"), ["-lc", "sleep 810102 & wait"], in: nil, timeout: 1)

        XCTAssertTrue(bystander.isRunning,
                       "a process outside this call's own tree must not be touched")
    }

    /// True while some process anywhere on the machine has `pattern` in its
    /// command line — used to check a forked child is actually gone, not just
    /// the shell that forked it.
    private func isProcessRunning(matching pattern: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", pattern]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Against a real repository

    /// The prerequisite check that has to hold for the run's sake: a project
    /// with no remote is skipped **with a reason** and nothing is pushed. The
    /// run has already succeeded by the time this is asked, so a missing remote
    /// must cost the pull request and nothing else.
    func testAProjectWithNoRemoteSkipsWithAReason() async throws {
        let repo = try makeRepository()

        let outcome = await PullRequestPublisher.open(
            projectRoot: repo, branch: "kiteloop/run-output-pr", title: "t", body: "b"
        )

        XCTAssertEqual(outcome, .skipped(reason: "the project has no git remote"))
    }

    /// Nothing to push from is the same kind of miss, and is answered before any
    /// subprocess runs at all.
    func testNoProjectRootSkipsWithAReason() async {
        let outcome = await PullRequestPublisher.open(
            projectRoot: nil, branch: "kiteloop/run-output-pr", title: "t", body: "b"
        )
        XCTAssertEqual(outcome, .skipped(reason: "no project root to push from"))
    }

    // MARK: - Fixtures

    private func item(title: String = "Open a PR for a finished run") -> BacklogItem {
        BacklogItem(id: "run-output-pr", title: title, verify: "true", status: .ready, type: .local, size: .m)
    }

    private func detail(
        what: String? = "Push the branch and open a pull request.",
        criteria: [String] = ["The URL lands in the item's Notes", "The flag defaults to off"]
    ) -> BacklogItemDetail {
        BacklogItemDetail(id: "run-output-pr", title: "Open a PR for a finished run",
                          verifyCommands: [], acceptanceCriteria: criteria, outOfScope: [],
                          what: what)
    }

    private func makeRepository() throws -> URL {
        let repo = try makeTemporaryDirectory(prefix: "pull-request-publisher")
        git(["init"], in: repo)
        return repo
    }

    private func git(_ args: [String], in directory: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
