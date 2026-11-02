import XCTest
@testable import Kiteloop

/// Covers the turn a worker gets when git says it changed nothing.
///
/// Two halves. The rules are pure and asserted directly; the git half runs
/// against a real temporary repository and worktree, because the whole point of
/// the check is that it asks git rather than believing the worker's account of
/// itself — and because the case that matters most (a worker that *did* work and
/// must not be interrupted) is only real against a real tree.
final class EmptyDiffHandoffTests: XCTestCase {
    private var repo: URL!
    private var worktrees: [URL] = []

    override func setUpWithError() throws {
        repo = try makeTemporaryDirectory(prefix: "empty-diff-handoff")
        git(["init"])
        git(["config", "user.email", "test@test.com"])
        git(["config", "user.name", "Test"])
        try "init".write(to: repo.appending(path: "README.md"), atomically: true, encoding: .utf8)
        git(["add", "."])
        git(["commit", "-m", "init"])
    }

    override func tearDownWithError() throws {
        for worktree in worktrees { try? FileManager.default.removeItem(at: worktree) }
        worktrees = []
    }

    @discardableResult
    private func git(_ args: [String], in directory: URL? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory ?? repo
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func makeWorktree(branch: String) -> URL {
        let path = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        git(["worktree", "add", "-b", branch, path.path(percentEncoded: false), "HEAD"])
        worktrees.append(path)
        return path
    }

    /// What the autopilot's hand-off check does, minus the orchestrator wiring:
    /// read git the way a run in flight has to be read, then apply the rule.
    private func wouldTell(branch: String, worktree: URL, alreadyTold: Bool = false) async -> Bool {
        let verdict = await RunWorkEvidence.inspectBlocked(
            projectRoot: repo, branch: branch, worktree: worktree, isolated: true)
        return EmptyDiffHandoff.shouldTell(verdict: verdict, alreadyTold: alreadyTold)
    }

    // MARK: - The rule

    func testTellsOnlyOnEvidenceOfAnEmptyTree() {
        XCTAssertTrue(EmptyDiffHandoff.shouldTell(verdict: .noChanges, alreadyTold: false))
    }

    func testSaysNothingToAWorkerThatProduced() {
        XCTAssertFalse(EmptyDiffHandoff.shouldTell(verdict: .produced, alreadyTold: false))
    }

    /// "Nobody could tell" is not "there is nothing there". A run whose git
    /// couldn't be read must not be accused of having done nothing.
    func testSaysNothingWhenGitCouldNotBeRead() {
        XCTAssertFalse(EmptyDiffHandoff.shouldTell(verdict: .unknown, alreadyTold: false))
    }

    /// Once per run. A worker that was told and still changed nothing has
    /// answered; asking again spends a second pass to learn the same thing.
    func testNeverTellsTwice() {
        XCTAssertFalse(EmptyDiffHandoff.shouldTell(verdict: .noChanges, alreadyTold: true))
    }

    // MARK: - What it says

    /// The wording carries the finding *and* the reason a green verify is not an
    /// answer to it — the sentence the whole item exists to get in front of a
    /// worker. Asserted so trimming it is a test failure rather than a silent
    /// return to "Done, CI is green".
    func testPromptStatesTheFindingAndWhyAGreenVerifyIsNotCompletion() {
        let prompt = EmptyDiffHandoff.prompt
        XCTAssertTrue(prompt.contains("you have changed no files"), prompt)
        XCTAssertTrue(prompt.contains("clean checkout"), prompt)
        XCTAssertTrue(prompt.contains("not evidence that this item was built"), prompt)
    }

    /// Both replies are legitimate endings, so both are offered — and neither is
    /// a fabricated edit.
    func testPromptOffersBuildingItOrSayingItIsAlreadyImplemented() {
        let prompt = EmptyDiffHandoff.prompt
        XCTAssertTrue(prompt.contains("make the change the item asks for"), prompt)
        XCTAssertTrue(prompt.contains("already implemented"), prompt)
        XCTAssertTrue(prompt.contains("Do not invent an edit"), prompt)
    }

    /// The third ending. A worker that checked the item's premise and refuted
    /// it is told to restate the report rather than invent an edit — the run
    /// that did so on 2026-09-03 was the day's best and was filed as nothing.
    func testPromptOffersARefutedPremiseAsAnEnding() {
        let prompt = EmptyDiffHandoff.prompt
        XCTAssertTrue(prompt.contains("Do one of three things"), prompt)
        XCTAssertTrue(prompt.contains("refuted a claim"), prompt)
        XCTAssertTrue(prompt.contains("`refuted: <measurement>`"), prompt)
        XCTAssertTrue(prompt.contains("recorded as an investigation"), prompt)
    }

    // MARK: - How an empty run's handoff decides its ending

    /// A handoff carrying a `refuted:` premise line ends the empty run as an
    /// investigation carrying the report — not as a run that produced nothing,
    /// and not as an already-implemented claim.
    func testRefutedPremiseInTheHandoffEndsTheRunAsAnInvestigation() throws {
        let ending = try XCTUnwrap(BacklogAutopilot.noWorkEnding(closingMessage: """
        Premise check:
        - refuted: only `RetryCeiling.evaluate` is over CRAP 8 (9.0); the other three read 4.1, 3.8 and 2.0
        - held: the baseline lists all four
        Stopping here: one function qualifies, and it is already accepted in the baseline.
        """))
        guard case .investigation(let report) = ending.outcome else {
            return XCTFail("expected an investigation, got \(ending.outcome)")
        }
        XCTAssertTrue(report.contains("- refuted: only `RetryCeiling.evaluate`"), report)
        XCTAssertTrue(report.contains("- held: the baseline lists all four"), report)
        XCTAssertEqual(ending.headline, "Investigation")
        XCTAssertEqual(ending.gateLabel, "premise refuted")
        XCTAssertTrue(ending.summary.contains("refuted 1 of 2 claims"), ending.summary)
        XCTAssertTrue(ending.note.contains("Nothing has verified the measurement"), ending.note)
        XCTAssertEqual(BacklogAutopilot.outcomeString(ending.outcome), TaskMetricRecord.investigationOutcome)
        XCTAssertEqual(BacklogAutopilot.endingReason(ending.outcome), "premise-refuted")
    }

    /// Every claim held is not an ending — the worker was then expected to
    /// build — and a handoff with no report at all still reads as nothing.
    func testAHeldPremiseOrNoReportIsNotAnEnding() {
        XCTAssertNil(BacklogAutopilot.noWorkEnding(closingMessage: "- held: all four are over 8\nDone, CI is green."))
        XCTAssertNil(BacklogAutopilot.noWorkEnding(closingMessage: "Done. ./scripts/ci-local.sh is green"))
        XCTAssertNil(BacklogAutopilot.noWorkEnding(closingMessage: nil))
    }

    /// The already-implemented claim still ends the run as it did, and a
    /// handoff carrying both is the investigation — the measurement is the
    /// more specific finding.
    func testTheAlreadyImplementedClaimStillHasItsOwnEnding() throws {
        let claim = """
        {"outcome": "already-implemented", "evidence": ["Services/Foo.swift — `Foo.bar()` already does X"]}
        """
        let ending = try XCTUnwrap(BacklogAutopilot.noWorkEnding(closingMessage: claim))
        guard case .alreadyImplemented = ending.outcome else {
            return XCTFail("expected the claim ending, got \(ending.outcome)")
        }
        XCTAssertEqual(ending.gateLabel, "claimed already implemented")

        let both = try XCTUnwrap(BacklogAutopilot.noWorkEnding(
            closingMessage: "- refuted: the item's premise does not hold\n" + claim))
        guard case .investigation = both.outcome else {
            return XCTFail("a refuted premise outranks the claim, got \(both.outcome)")
        }
        XCTAssertNil(BacklogAutopilot.endingReason(ending.outcome))
        XCTAssertNil(BacklogAutopilot.endingReason(.done))
    }

    // MARK: - Against a real tree

    /// The failure this exists for: the worker ran the verify, it passed, and the
    /// worktree is exactly as it was handed over.
    func testWorkerThatChangedNothingIsTold() async throws {
        let worktree = makeWorktree(branch: "kiteloop/empty")
        let told = await wouldTell(branch: "kiteloop/empty", worktree: worktree)
        XCTAssertTrue(told)
    }

    /// A worker mid-run has committed nothing — teardown does that later — so
    /// its work is uncommitted edits, and those count.
    func testWorkerWithUncommittedEditsIsNotTold() async throws {
        let worktree = makeWorktree(branch: "kiteloop/edited")
        try "worked".write(to: worktree.appending(path: "worked.txt"),
                           atomically: true, encoding: .utf8)
        let told = await wouldTell(branch: "kiteloop/edited", worktree: worktree)
        XCTAssertFalse(told)
    }

    /// A worker that committed its own work is producing too — the branch is
    /// ahead of `HEAD` and the worktree is clean, which must not read as empty.
    func testWorkerThatCommittedItsOwnWorkIsNotTold() async throws {
        let worktree = makeWorktree(branch: "kiteloop/committed")
        try "worked".write(to: worktree.appending(path: "worked.txt"),
                           atomically: true, encoding: .utf8)
        git(["add", "."], in: worktree)
        git(["commit", "-m", "work"], in: worktree)
        let told = await wouldTell(branch: "kiteloop/committed", worktree: worktree)
        XCTAssertFalse(told)
    }

    /// Untracked-only work still counts: a worker whose whole item was adding a
    /// file has produced, and interrupting it to say otherwise would be wrong.
    func testUntrackedFileCountsAsWork() async throws {
        let worktree = makeWorktree(branch: "kiteloop/untracked")
        try "new".write(to: worktree.appending(path: "brand-new.swift"),
                        atomically: true, encoding: .utf8)
        let told = await wouldTell(branch: "kiteloop/untracked", worktree: worktree)
        XCTAssertFalse(told)
    }

    /// A live-tree run has no worktree to read and its edits are
    /// indistinguishable from a human's, so nothing is said.
    func testLiveTreeRunIsNeverTold() async throws {
        let verdict = await RunWorkEvidence.inspectBlocked(
            projectRoot: repo, branch: "kiteloop/live", worktree: nil, isolated: false)
        XCTAssertEqual(verdict, .unknown)
        XCTAssertFalse(EmptyDiffHandoff.shouldTell(verdict: verdict, alreadyTold: false))
    }
}
