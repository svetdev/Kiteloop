import XCTest
@testable import KiteloopCore

/// The decisions behind following a pull request's checks: how `gh`'s answer is
/// read, when a failing check earns another fix round, when the loop stops, and
/// what the item's Notes and the human's summons are told.
///
/// All pure — deliberately. Waiting on a real pull request needs a GitHub
/// account, a network and a CI provider that will fail on cue; what *can* go
/// wrong without them is the reading and the deciding, and a decision function
/// that is total over the four states is exactly what makes "no polling after a
/// terminal state" a property rather than a hope.
final class PullRequestChecksTests: XCTestCase {

    // MARK: - Reading what `gh` said

    func testReadsTheCheckListOutOfGHsJSON() {
        let output = """
        [{"name":"build","state":"SUCCESS","bucket":"pass","link":"https://github.com/a/b/actions/runs/1/job/2"},
         {"name":"lint","state":"FAILURE","bucket":"fail","link":"https://github.com/a/b/actions/runs/1/job/3"}]
        """
        let checks = PullRequestChecks.checks(inJSON: output)

        XCTAssertEqual(checks?.count, 2)
        XCTAssertEqual(checks?.first?.name, "build")
        XCTAssertEqual(checks?.first?.bucket, "pass")
        XCTAssertEqual(checks?.last?.bucket, "fail")
    }

    /// `gh` prints advice above its output. A bracket in one of those lines must
    /// not cost the poll its answer — the scan tries every `[`, not the first.
    func testFindsTheJSONUnderAWarningThatContainsABracket() {
        let output = """
        warning: [deprecated] something or other
        [{"name":"build","state":"SUCCESS","bucket":"pass","link":""}]
        """
        XCTAssertEqual(PullRequestChecks.checks(inJSON: output)?.count, 1)
    }

    /// `gh` also prints *below* its output — the new-release notice goes to
    /// stderr, which `PullRequestPublisher.run` merges into the same capture. A
    /// slice that ran to the end of the output handed that line to
    /// `JSONSerialization` along with the array and was rejected whole, so one
    /// upgrade notice ended the follow with the check list sitting in the output
    /// that had just been discarded.
    func testFindsTheJSONWhenGHPrintsAnotherLineAfterIt() {
        let output = """
        [{"name":"build","state":"SUCCESS","bucket":"pass","link":""},
         {"name":"lint","state":"FAILURE","bucket":"fail","link":""}]

        A new release of gh is available: 2.40.0 → 2.62.0
        To upgrade, run: gh upgrade
        """
        let checks = PullRequestChecks.checks(inJSON: output)

        XCTAssertEqual(checks?.count, 2)
        XCTAssertEqual(checks?.last?.bucket, "fail")
        XCTAssertEqual(PullRequestChecks.state(exitStatus: 1, output: output),
                       .failing(check(name: "lint", bucket: "fail")))
    }

    /// The scan used to give up after eight `[` characters, so enough bracketed
    /// prose ahead of the array hid it just as thoroughly as no array at all.
    func testFindsTheJSONBehindMoreThanEightBracketsOfPreamble() {
        let preamble = (1...10).map { "[notice \($0)] waiting for the checks to be reported" }
        let output = (preamble + [#"[{"name":"build","state":"SUCCESS","bucket":"pass","link":""}]"#])
            .joined(separator: "\n")

        XCTAssertEqual(PullRequestChecks.checks(inJSON: output)?.count, 1)
    }

    func testOutputWithNoCheckListReadsAsUnparseable() {
        XCTAssertNil(PullRequestChecks.checks(inJSON: "could not resolve to a PullRequest"))
        XCTAssertNil(PullRequestChecks.checks(inJSON: ""))
    }

    /// An older `gh` exports no bucket. Every check reading as "no bucket" would
    /// otherwise look pending forever and the loop would wait out its deadline
    /// on a pull request that was green all along.
    func testDerivesTheBucketFromTheRawStateWhenGHGaveNone() {
        XCTAssertEqual(PullRequestChecks.normalisedBucket(bucket: "", state: "SUCCESS"), "pass")
        XCTAssertEqual(PullRequestChecks.normalisedBucket(bucket: "", state: "SKIPPED"), "pass")
        XCTAssertEqual(PullRequestChecks.normalisedBucket(bucket: "", state: "FAILURE"), "fail")
        XCTAssertEqual(PullRequestChecks.normalisedBucket(bucket: "", state: "TIMED_OUT"), "fail")
        XCTAssertEqual(PullRequestChecks.normalisedBucket(bucket: "", state: "CANCELLED"), "cancel")
        XCTAssertEqual(PullRequestChecks.normalisedBucket(bucket: "", state: "IN_PROGRESS"), "pending")
    }

    func testAReportedBucketWinsOverTheRawState() {
        XCTAssertEqual(PullRequestChecks.normalisedBucket(bucket: "Fail", state: "SUCCESS"), "fail")
    }

    // MARK: - Where a list of checks leaves the pull request

    func testAllPassingIsGreen() {
        XCTAssertEqual(PullRequestChecks.classify([check(bucket: "pass"), check(name: "b", bucket: "skipping")]),
                       .green(checks: 2))
    }

    /// A failure wins over a pending check: the run has something to hand the
    /// worker now, and waiting for the rest only spends the deadline.
    func testAFailureWinsOverStillRunningChecks() {
        let failing = check(name: "lint", bucket: "fail")
        XCTAssertEqual(PullRequestChecks.classify([check(bucket: "pending"), failing]),
                       .failing(failing))
    }

    func testACancelledCheckCountsAsAFailure() {
        let cancelled = check(name: "e2e", bucket: "cancel")
        XCTAssertEqual(PullRequestChecks.classify([cancelled]), .failing(cancelled))
    }

    func testAnythingStillRunningIsPending() {
        XCTAssertEqual(PullRequestChecks.classify([check(bucket: "pass"), check(name: "b", bucket: "pending")]),
                       .pending(checks: 1))
    }

    /// An empty answer is ambiguous — GitHub may simply not have registered the
    /// run yet — so it reads as `.noChecksYet`, not straight to green; `next`
    /// is what tells "no CI" from "not yet" apart.
    func testAPullRequestWithNoChecksIsAmbiguousUntilTheGraceElapses() {
        XCTAssertEqual(PullRequestChecks.classify([]), .noChecksYet)
        XCTAssertEqual(PullRequestChecks.state(exitStatus: 0, output: "[]"), .noChecksYet)
        XCTAssertEqual(
            PullRequestChecks.state(exitStatus: 1, output: "no checks reported on the 'kiteloop/x' branch"),
            .noChecksYet
        )
    }

    func testAFailedGHInvocationIsUnavailableWithItsLastWord() {
        let state = PullRequestChecks.state(exitStatus: 1, output: "gh: could not resolve to a PullRequest")

        guard case .unavailable(let reason) = state else { return XCTFail("expected unavailable, got \(state)") }
        XCTAssertTrue(reason.contains("could not resolve to a PullRequest"), reason)
    }

    // MARK: - The loop, as a decision

    func testGreenChecksFinishTheLoop() {
        let step = PullRequestChecks.next(state: .green(checks: 3), roundsUsed: 1,
                                          elapsed: 120, canAffordFix: true)
        XCTAssertEqual(step, .finish(.green(checks: 3, rounds: 1, duration: 120)))
    }

    func testAFailingCheckWithRoundsLeftEarnsAFixRound() {
        let failing = check(name: "build", bucket: "fail")
        XCTAssertEqual(
            PullRequestChecks.next(state: .failing(failing), roundsUsed: 0,
                                   elapsed: 60, canAffordFix: true),
            .fix(failing)
        )
    }

    /// A pull request that fails CI twice with the worker looking at the failure
    /// both times needs a human, not a third identical attempt.
    func testTheRoundCapEndsTheLoopNamingTheCheck() {
        let step = PullRequestChecks.next(state: .failing(check(name: "build", bucket: "fail")),
                                          roundsUsed: PullRequestChecks.maxFixRounds,
                                          elapsed: 600, canAffordFix: true)

        guard case .finish(.gaveUp(let name, let rounds, let reason)) = step else {
            return XCTFail("expected gave-up, got \(step)")
        }
        XCTAssertEqual(name, "build")
        XCTAssertEqual(rounds, PullRequestChecks.maxFixRounds)
        XCTAssertTrue(reason.contains("2 fix rounds"), reason)
    }

    /// The cap, not the round limit, is the spend backstop: a round the item
    /// can't pay for is not started to find out.
    func testASpentCostCapEndsTheLoopBeforeTheRoundLimit() {
        let step = PullRequestChecks.next(state: .failing(check(name: "build", bucket: "fail")),
                                          roundsUsed: 0, elapsed: 60, canAffordFix: false)

        guard case .finish(.gaveUp(let name, _, let reason)) = step else {
            return XCTFail("expected gave-up, got \(step)")
        }
        XCTAssertEqual(name, "build")
        XCTAssertTrue(reason.contains("cost cap"), reason)
    }

    func testAnUncappedItemCanAlwaysAffordAnotherRound() {
        XCTAssertTrue(PullRequestChecks.canAfford(spentUSD: 99, capUSD: nil))
        XCTAssertTrue(PullRequestChecks.canAfford(spentUSD: 1.5, capUSD: 2))
        XCTAssertFalse(PullRequestChecks.canAfford(spentUSD: 2, capUSD: 2))
    }

    /// An empty answer waits out `noChecksGrace` before it's allowed to mean
    /// "this project has no CI" — GitHub may simply not have registered the
    /// run yet.
    func testNoChecksYetWaitsOutTheGraceThenFinishesGreen() {
        XCTAssertEqual(
            PullRequestChecks.next(state: .noChecksYet, roundsUsed: 0,
                                   elapsed: PullRequestChecks.noChecksGrace - 1, canAffordFix: true),
            .wait
        )
        XCTAssertEqual(
            PullRequestChecks.next(state: .noChecksYet, roundsUsed: 0,
                                   elapsed: PullRequestChecks.noChecksGrace, canAffordFix: true),
            .finish(.green(checks: 0, rounds: 0, duration: PullRequestChecks.noChecksGrace))
        )
    }

    /// The no-checks clock is measured from the last moment checks could have
    /// started — not from when following began — so it is a separate
    /// parameter from `elapsed`, the deadline clock. A fix round's push resets
    /// it: a round that ran longer than the grace must not let the very next
    /// empty answer resolve to green immediately.
    func testNoChecksClockIsDistinctFromElapsedAndCanBeReset() {
        XCTAssertEqual(
            PullRequestChecks.next(state: .noChecksYet, roundsUsed: 1,
                                   elapsed: PullRequestChecks.noChecksGrace + 500,
                                   sinceNoChecksOpportunity: 1, canAffordFix: true),
            .wait
        )
        XCTAssertEqual(
            PullRequestChecks.next(state: .noChecksYet, roundsUsed: 1,
                                   elapsed: PullRequestChecks.noChecksGrace + 500,
                                   sinceNoChecksOpportunity: PullRequestChecks.noChecksGrace,
                                   canAffordFix: true),
            .finish(.green(checks: 0, rounds: 1, duration: PullRequestChecks.noChecksGrace + 500))
        )
    }

    func testPendingChecksWaitUntilTheDeadline() {
        XCTAssertEqual(
            PullRequestChecks.next(state: .pending(checks: 2), roundsUsed: 0,
                                   elapsed: 60, canAffordFix: true),
            .wait
        )
        XCTAssertEqual(
            PullRequestChecks.next(state: .pending(checks: 2), roundsUsed: 0,
                                   elapsed: PullRequestChecks.deadline, canAffordFix: true),
            .finish(.timedOut(pending: 2, duration: PullRequestChecks.deadline))
        )
    }

    /// Every state resolves to waiting or to a terminal outcome, and
    /// `unavailable` is terminal: a loop that can't read the checks does not
    /// start reading them by asking again.
    func testAnUnreadableStateIsTerminal() {
        XCTAssertEqual(
            PullRequestChecks.next(state: .unavailable(reason: "no gh"), roundsUsed: 0,
                                   elapsed: 0, canAffordFix: true),
            .finish(.unavailable(reason: "no gh"))
        )
    }

    // MARK: - What the Notes and the summons say

    func testGreenNoteCarriesTheChecksTheRoundsAndTheDuration() {
        let note = PullRequestChecks.note(for: .green(checks: 3, rounds: 1, duration: 185))

        XCTAssertTrue(note.contains("3 checks"), note)
        XCTAssertTrue(note.contains("1 fix round"), note)
        XCTAssertTrue(note.contains("3m 5s"), note)
    }

    func testAProjectWithoutCIGetsANoteSayingSoRatherThanAGreenOne() {
        XCTAssertEqual(PullRequestChecks.note(for: .green(checks: 0, rounds: 0, duration: 2)),
                       "Pull request has no checks — nothing to wait for")
    }

    func testTheGiveUpNoteNamesTheCheckAndWhyItStopped() {
        let note = PullRequestChecks.note(
            for: .gaveUp(check: "build (macOS)", rounds: 2, reason: "2 fix rounds did not make it green"))

        XCTAssertTrue(note.contains("build (macOS)"), note)
        XCTAssertTrue(note.contains("2 fix rounds did not make it green"), note)
    }

    func testTheTimeoutNoteSaysItWentToTheGateWithout() {
        let note = PullRequestChecks.note(for: .timedOut(pending: 1, duration: 2400))

        XCTAssertTrue(note.contains("1 check pending"), note)
        XCTAssertTrue(note.contains("40m 0s"), note)
    }

    /// The summons is the one place a human reads before deciding to get up, so
    /// a red pull request says which check is red.
    func testTheGateDetailDistinguishesGreenFromFailingFromNoChecks() {
        XCTAssertEqual(PullRequestChecks.gateDetail(for: .green(checks: 2, rounds: 0, duration: 1)), "PR green")
        XCTAssertEqual(PullRequestChecks.gateDetail(for: .green(checks: 0, rounds: 0, duration: 1)), "PR has no checks")
        XCTAssertEqual(PullRequestChecks.gateDetail(for: .gaveUp(check: "build", rounds: 2, reason: "x")),
                       "PR check failing: build")
        XCTAssertEqual(PullRequestChecks.gateDetail(for: .timedOut(pending: 1, duration: 1)),
                       "PR checks still running")
    }

    // MARK: - What the worker is handed

    func testTheFixPromptNamesTheCheckThePRAndTheBranchAndCarriesTheLog() {
        let prompt = PullRequestChecks.fixPrompt(
            item: item(), branch: "kiteloop/pr-checks-loop",
            url: "https://github.com/acme/k/pull/9",
            check: check(name: "build", bucket: "fail",
                         link: "https://github.com/acme/k/actions/runs/1/job/2"),
            log: "error: no such module 'Kiteloop'",
            round: 1,
            buildOutputNote: nil
        )

        XCTAssertTrue(prompt.contains("build"), prompt)
        XCTAssertTrue(prompt.contains("https://github.com/acme/k/pull/9"), prompt)
        XCTAssertTrue(prompt.contains("kiteloop/pr-checks-loop"), prompt)
        XCTAssertTrue(prompt.contains("error: no such module 'Kiteloop'"), prompt)
        XCTAssertTrue(prompt.contains("Fix round 1 of 2"), prompt)
    }

    /// The diff on this branch has already been reviewed and approved, so a fix
    /// round that widens it is unreviewed work. The prompt has to say so.
    func testTheFixPromptForbidsAnythingBeyondTheFailingCheck() {
        let prompt = PullRequestChecks.fixPrompt(
            item: item(), branch: "kiteloop/x", url: "u",
            check: check(bucket: "fail"), log: "", round: 2, buildOutputNote: "build into /tmp/dd"
        )

        XCTAssertTrue(prompt.contains("out of scope"), prompt)
        XCTAssertTrue(prompt.contains("build into /tmp/dd"), prompt)
    }

    /// A check whose log couldn't be fetched says so rather than reading as a
    /// check that printed nothing.
    func testAnEmptyLogIsReportedAsUnfetchedRatherThanAsSilence() {
        let prompt = PullRequestChecks.fixPrompt(
            item: item(), branch: "b", url: "u", check: check(bucket: "fail"),
            log: "   ", round: 1, buildOutputNote: nil
        )
        XCTAssertTrue(prompt.contains("Nothing could be fetched"), prompt)
    }

    // MARK: - Fetching a failure's log

    func testReadsTheActionsJobIDOutOfACheckLink() {
        XCTAssertEqual(
            PullRequestChecks.jobID(inLink: "https://github.com/acme/k/actions/runs/123/job/456"),
            "456"
        )
    }

    /// A check that doesn't report through Actions has no log to fetch, and
    /// inventing a job id for it would fetch somebody else's.
    func testACheckWithoutAJobLinkHasNoJobID() {
        XCTAssertNil(PullRequestChecks.jobID(inLink: "https://ci.example.com/builds/7"))
        XCTAssertNil(PullRequestChecks.jobID(inLink: ""))
    }

    func testClipKeepsTheEndOfALogWhereTheErrorIs() {
        let long = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let clipped = PullRequestChecks.clip(long, maxBytes: 200)

        XCTAssertTrue(clipped.hasPrefix("… (earlier output omitted)"), clipped)
        XCTAssertTrue(clipped.hasSuffix("line 500"), clipped)
        XCTAssertFalse(clipped.contains("line 1\n"), clipped)
    }

    func testAShortLogIsKeptWhole() {
        XCTAssertEqual(PullRequestChecks.clip("error: boom", maxBytes: 200), "error: boom")
    }

    // MARK: - Fixtures

    private func check(name: String = "a", bucket: String, link: String = "") -> PullRequestChecks.Check {
        PullRequestChecks.Check(name: name, bucket: bucket, link: link)
    }

    private func item() -> BacklogItem {
        BacklogItem(id: "pr-checks-loop", title: "Follow the run's PR until its checks are green",
                    verify: "true", status: .awaitingApproval, type: .local, size: .m)
    }
}
