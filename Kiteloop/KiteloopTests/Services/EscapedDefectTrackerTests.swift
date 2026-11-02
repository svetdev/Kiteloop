import XCTest
import KiteloopCore
@testable import Kiteloop

/// Success metric #3b — the escaped-defect rate: the share of *approved* items
/// that come back within 7 days.
///
/// The measure only means anything if it separates a defect that escaped review
/// from one review caught: an item the reviewer bounced never passed, so it is a
/// first-pass failure (metric #3a) and must not be counted here as well.
@MainActor
final class EscapedDefectTrackerTests: XCTestCase {
    private var tempDir: URL!
    private var store: TaskMetricStore!

    private let projectPath = "/tmp/alpha"
    private let projectName = "alpha"

    /// Well clear of the window on either side, so no test depends on wall-clock time.
    private let day: TimeInterval = 24 * 60 * 60
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "escaped-defect")
        // Pointed at the temp directory so the tests never append to the
        // developer's real ~/.kiteloop/task-approvals.jsonl.
        store = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl")
        )
    }

    override func tearDownWithError() throws {
        store = nil
    }

    // MARK: - Detecting a reopen

    /// The transition the metric exists for: accepted work that came back.
    func testApprovedItemReturnedToReadyIsRecordedAsAReopen() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .awaitingApproval]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0 + day)
        tracker.observe(backlog(["task-1": .ready]), at: t0 + 2 * day)

        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved, .reopened])
        let reopen = store.approvalEvents[1]
        XCTAssertEqual(reopen.itemID, "task-1")
        XCTAssertEqual(reopen.toStatus, "ready")
        XCTAssertEqual(reopen.at, t0 + 2 * day)
        XCTAssertEqual(reopen.approvedAt, t0 + day, "The reopen carries when the item had been approved")
    }

    /// `blocked` is a reopen too: accepted work that turned out to be broken is
    /// often parked rather than re-queued, and it escaped review either way.
    func testApprovedItemMovedToBlockedIsRecordedAsAReopen() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0 + day)
        tracker.observe(backlog(["task-1": .done]), at: t0 + 2 * day)   // unchanged, no event
        tracker.observe(backlog(["task-1": .blocked]), at: t0 + 3 * day)

        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved, .reopened])
        XCTAssertEqual(store.approvalEvents[1].toStatus, "blocked")
        XCTAssertEqual(store.escapedDefectRate(projectPath: projectPath).reopened, 1)
    }

    /// A reopened item already picked back up before the next observation
    /// lands on `active`, not `ready` — still an escaped defect.
    func testApprovedItemPickedStraightUpAsActiveIsRecordedAsAReopen() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0 + day)
        tracker.observe(backlog(["task-1": .active]), at: t0 + 2 * day)

        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved, .reopened])
        XCTAssertEqual(store.approvalEvents[1].toStatus, "active")
        XCTAssertEqual(store.approvalEvents[1].approvedAt, t0 + day)
    }

    /// Same, landing on `in-review` instead.
    func testApprovedItemPickedStraightUpAsInReviewIsRecordedAsAReopen() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0 + day)
        tracker.observe(backlog(["task-1": .inReview]), at: t0 + 2 * day)

        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved, .reopened])
        XCTAssertEqual(store.approvalEvents[1].toStatus, "in-review")
        XCTAssertEqual(store.approvalEvents[1].approvedAt, t0 + day)
    }

    /// The distinction the whole metric rests on. A reviewer rejection goes
    /// `active` → `ready` without ever reaching `done`; counting it here would
    /// charge the same event to both halves of metric #3.
    func testReviewerRejectionBackToReadyIsNotAReopen() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .active]), at: t0 + 60)
        tracker.observe(backlog(["task-1": .inReview]), at: t0 + 120)
        tracker.observe(backlog(["task-1": .ready]), at: t0 + 180)

        XCTAssertEqual(store.approvalEvents, [], "A rejection is a first-pass failure, not an escaped defect")
        XCTAssertNil(store.escapedDefectRate(projectPath: projectPath).rate)
    }

    /// An item that never got near acceptance leaves the metric untouched.
    func testItemNeverApprovedContributesNothing() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .draft]), at: t0)
        tracker.observe(backlog(["task-1": .ready]), at: t0 + day)
        tracker.observe(backlog(["task-1": .blocked]), at: t0 + 2 * day)

        let rate = store.escapedDefectRate(projectPath: projectPath)
        XCTAssertEqual(rate.approvals, 0)
        XCTAssertEqual(rate.reopened, 0)
        XCTAssertNil(rate.rate, "0 of 0 is 'not measured yet', not 0%")
    }

    /// A status read once is a state, not a transition — it cannot say whether
    /// the item was ever approved, so the first look only sets the baseline.
    func testFirstObservationSeedsWithoutRecordingAnything() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .done, "task-2": .ready]), at: t0)

        XCTAssertEqual(store.approvalEvents, [])
    }

    /// Sent back to grooming is un-filing an item, not reporting a defect
    /// against shipped work.
    func testApprovedItemReturnedToDraftIsNotAReopen() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0 + day)
        tracker.observe(backlog(["task-1": .draft]), at: t0 + 2 * day)

        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved])
    }

    /// Re-approved work is approved again: the second pass through review is its
    /// own chance for a defect to escape, so both sides of the ratio grow.
    func testItemApprovedReopenedAndApprovedAgainCountsTwice() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0 + day)
        tracker.observe(backlog(["task-1": .ready]), at: t0 + 2 * day)
        tracker.observe(backlog(["task-1": .done]), at: t0 + 3 * day)
        tracker.observe(backlog(["task-1": .ready]), at: t0 + 4 * day)

        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved, .reopened, .approved, .reopened])
        XCTAssertEqual(store.approvalEvents[3].approvedAt, t0 + 3 * day,
                       "The second reopen is measured from the second approval, not the first")
        let rate = store.escapedDefectRate(projectPath: projectPath)
        XCTAssertEqual(rate.approvals, 2)
        XCTAssertEqual(rate.reopened, 2)
        XCTAssertEqual(rate.rate, 1.0)
    }

    // MARK: - The 7-day window

    /// An item that comes back a month later is a new piece of work, not a
    /// defect this review let through.
    func testReopenOutsideTheWindowIsExcludedFromTheRate() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0)
        tracker.observe(backlog(["task-1": .ready]), at: t0 + 30 * day)

        let rate = store.escapedDefectRate(projectPath: projectPath)
        XCTAssertEqual(rate.approvals, 1)
        XCTAssertEqual(rate.reopened, 0)
        XCTAssertEqual(rate.lateReopened, 1, "Still recorded, just not an escaped defect by this definition")
        XCTAssertEqual(rate.rate, 0.0)
    }

    /// The boundary is inclusive: exactly 7×24h counts, a second later does not.
    func testWindowBoundaryIsInclusive() {
        let onTime = makeTracker()
        onTime.observe(backlog(["task-1": .ready]), at: t0)
        onTime.observe(backlog(["task-1": .done]), at: t0)
        onTime.observe(backlog(["task-1": .ready]), at: t0 + 7 * day)
        XCTAssertEqual(store.escapedDefectRate(projectPath: projectPath).reopened, 1)

        let justLate = makeTracker()
        justLate.observe(backlog(["task-2": .ready]), at: t0)
        justLate.observe(backlog(["task-2": .done]), at: t0)
        justLate.observe(backlog(["task-2": .ready]), at: t0 + 7 * day + 1)

        let rate = store.escapedDefectRate(projectPath: projectPath)
        XCTAssertEqual(rate.approvals, 2)
        XCTAssertEqual(rate.reopened, 1)
        XCTAssertEqual(rate.lateReopened, 1)
        XCTAssertEqual(rate.rate, 0.5)
    }

    // MARK: - The gate-retry loop's own churn (an auto-merge retry is not an escaped defect)

    /// The real 2026-09-05 incident: `signal-drafts-push-a-pass-past-its-own-cap`
    /// was approved, bounced to `active` and re-approved four times in thirteen
    /// minutes — the merged-tree verify's own retries, a few minutes apart —
    /// before it stayed `done`. Replayed live through the tracker exactly as it
    /// happened, the rate must read one approval and no reopen: nothing here
    /// escaped review.
    func testTheRealAutoMergeRetryCascadeRecordsOneApprovalAndNoReopen() {
        let itemID = "signal-drafts-push-a-pass-past-its-own-cap"
        let tracker = makeTracker()
        tracker.observe(backlog([itemID: .active]), at: t0 - 1)   // seed
        tracker.observe(backlog([itemID: .done]), at: t0)
        tracker.observe(backlog([itemID: .active]), at: t0 + 27)
        tracker.observe(backlog([itemID: .done]), at: t0 + 29)
        tracker.observe(backlog([itemID: .active]), at: t0 + 274)
        tracker.observe(backlog([itemID: .done]), at: t0 + 276)
        tracker.observe(backlog([itemID: .active]), at: t0 + 498)
        tracker.observe(backlog([itemID: .done]), at: t0 + 499)
        tracker.observe(backlog([itemID: .active]), at: t0 + 726)
        tracker.observe(backlog([itemID: .done]), at: t0 + 727)

        let rate = store.escapedDefectRate(projectPath: projectPath)
        XCTAssertEqual(rate.approvals, 1)
        XCTAssertEqual(rate.reopened, 0)
        XCTAssertEqual(rate.lateReopened, 0)
    }

    /// The other half of the same fix: a person moving a `done` item back to
    /// `ready` — with nothing re-approving it soon after — is still a genuine
    /// reopen, measured from its approval exactly as before.
    func testAHumanReopenWithNoQuickReapprovalStillCounts() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0 + day)
        tracker.observe(backlog(["task-1": .ready]), at: t0 + day + 3_600)

        let rate = store.escapedDefectRate(projectPath: projectPath)
        XCTAssertEqual(rate.approvals, 1)
        XCTAssertEqual(rate.reopened, 1)
    }

    // MARK: - Rate

    func testRateCountsOnlyTheProjectAskedFor() {
        let alpha = makeTracker()
        alpha.observe(backlog(["task-1": .ready]), at: t0)
        alpha.observe(backlog(["task-1": .done]), at: t0)

        let beta = EscapedDefectTracker(store: store, projectPath: "/tmp/beta", projectName: "beta")
        beta.observe(backlog(["task-2": .ready]), at: t0)
        beta.observe(backlog(["task-2": .done]), at: t0)
        beta.observe(backlog(["task-2": .ready]), at: t0 + day)

        XCTAssertEqual(store.escapedDefectRate(projectPath: projectPath).reopened, 0)
        XCTAssertEqual(store.escapedDefectRate(projectPath: "/tmp/beta").reopened, 1)
        XCTAssertEqual(store.escapedDefectRate(projectPath: nil).approvals, 2, "No filter spans every project")
    }

    /// Records keep the raw root path while the registry keys on the canonical
    /// one, so a trailing slash must not hide a project's own approvals.
    func testRateMatchesDespiteATrailingSlash() {
        let tracker = EscapedDefectTracker(store: store, projectPath: projectPath + "/", projectName: projectName)
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0)

        XCTAssertEqual(store.escapedDefectRate(projectPath: projectPath).approvals, 1)
    }

    func testWindowDaysIsReportedAlongsideTheRate() {
        XCTAssertEqual(store.escapedDefectRate(projectPath: nil).windowDays, 7)
    }

    // MARK: - Durability

    /// The approval a reopen is measured against comes off disk, so an item
    /// approved before a restart and reopened after it is still counted.
    func testApprovalSurvivesAReloadOfTheStore() {
        let tracker = makeTracker()
        tracker.observe(backlog(["task-1": .ready]), at: t0)
        tracker.observe(backlog(["task-1": .done]), at: t0)

        let reloaded = TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl")
        )
        let afterRestart = EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
        afterRestart.observe(backlog(["task-1": .done]), at: t0 + day)      // baseline
        afterRestart.observe(backlog(["task-1": .ready]), at: t0 + 2 * day)

        let rate = reloaded.escapedDefectRate(projectPath: projectPath)
        XCTAssertEqual(rate.approvals, 1)
        XCTAssertEqual(rate.reopened, 1)
    }

    /// History recorded before this metric existed is not backfilled: without an
    /// approval time there is no way to say which side of the window a reopen
    /// falls on, and a guessed one would be worse than the gap.
    func testReopenWithNoRecordedApprovalIsNotCounted() {
        let tracker = makeTracker()
        // `done` on the first look — the approval itself was never observed.
        tracker.observe(backlog(["task-1": .done]), at: t0)
        tracker.observe(backlog(["task-1": .ready]), at: t0 + day)

        XCTAssertEqual(store.approvalEvents, [])
    }

    // MARK: - Reopens that happened while the project was closed

    /// The gap this closes: `lastSeen` is in-memory, so an item approved before
    /// the app quit and sent back before it returned used to seed as a plain
    /// `ready` and the escape was lost. The approval log still holds the other
    /// half of the transition.
    func testSeedRecordsAReopenThatHappenedWhileTheProjectWasClosed() {
        let before = makeTracker()
        before.observe(backlog(["foo": .ready]), at: t0)
        before.observe(backlog(["foo": .done]), at: t0 + day)

        // App quits; `foo` is sent back to `ready`; app returns.
        let reloaded = reloadStore()
        let afterRestart = EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
        afterRestart.observe(backlog(["foo": .ready]), at: t0 + 2 * day)

        XCTAssertEqual(reloaded.approvalEvents.map(\.kind), [.approved, .reopened])
        let reopen = reloaded.approvalEvents[1]
        XCTAssertEqual(reopen.itemID, "foo")
        XCTAssertEqual(reopen.toStatus, "ready")
        XCTAssertEqual(reopen.approvedAt, t0 + day, "Measured off the same approval the live path would use")
        XCTAssertEqual(reopen.at, t0 + 2 * day, "When the return was noticed — the most the log can say")
    }

    /// `blocked` is a reopen status on this path too, exactly as it is live.
    func testSeedRecordsAReopenForAnItemParkedAsBlockedWhileClosed() {
        let before = makeTracker()
        before.observe(backlog(["foo": .ready]), at: t0)
        before.observe(backlog(["foo": .done]), at: t0 + day)

        let reloaded = reloadStore()
        let afterRestart = EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
        afterRestart.observe(backlog(["foo": .blocked]), at: t0 + 2 * day)

        XCTAssertEqual(reloaded.approvalEvents.map(\.kind), [.approved, .reopened])
        XCTAssertEqual(reloaded.approvalEvents[1].toStatus, "blocked")
    }

    /// The gap this closes for the picked-straight-up case: an item reopened
    /// and picked up again before the app ever saw it at `ready`/`blocked`
    /// seeds straight into `active` with the approval still on record.
    func testSeedRecordsAReopenForAnItemPickedStraightUpAsActiveWhileClosed() {
        let before = makeTracker()
        before.observe(backlog(["foo": .ready]), at: t0)
        before.observe(backlog(["foo": .done]), at: t0 + day)

        let reloaded = reloadStore()
        let firstOpen = EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
        firstOpen.observe(backlog(["foo": .active]), at: t0 + 2 * day)

        XCTAssertEqual(reloaded.approvalEvents.map(\.kind), [.approved, .reopened])
        XCTAssertEqual(reloaded.approvalEvents[1].toStatus, "active")

        let secondOpen = EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
        secondOpen.observe(backlog(["foo": .active]), at: t0 + 3 * day)

        XCTAssertEqual(reloaded.approvalEvents.map(\.kind), [.approved, .reopened],
                       "A second open re-seeding the same state adds nothing")
    }

    /// Opening the project a second time seeds a second tracker over the same
    /// backlog and the same log. Without the "nothing recorded since this
    /// approval" test, every open would charge the escape again.
    func testSeedingASecondTimeOverTheSameStateAddsNothing() {
        let before = makeTracker()
        before.observe(backlog(["foo": .ready]), at: t0)
        before.observe(backlog(["foo": .done]), at: t0 + day)

        let reloaded = reloadStore()
        let firstOpen = EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
        firstOpen.observe(backlog(["foo": .ready]), at: t0 + 2 * day)
        XCTAssertEqual(reloaded.approvalEvents.count, 2)

        let secondOpen = EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
        secondOpen.observe(backlog(["foo": .ready]), at: t0 + 3 * day)

        XCTAssertEqual(reloaded.approvalEvents.map(\.kind), [.approved, .reopened],
                       "A second project open re-reads the same state, not a new transition")
        XCTAssertEqual(reloaded.escapedDefectRate(projectPath: projectPath).reopened, 1)
    }

    /// The rule the whole tracker rests on is unchanged: a status with no
    /// approval behind it says nothing, and most of a backlog is `ready`.
    func testSeedRecordsNothingForAnItemWithNoApprovalOnRecord() {
        let tracker = makeTracker()
        tracker.observe(backlog(["foo": .ready, "bar": .blocked]), at: t0)

        XCTAssertEqual(store.approvalEvents, [])
    }

    /// An item still sitting at `done` is a state, not a return — and the live
    /// path must still catch it when it does move.
    func testItemSeededAsDoneRecordsNothingUntilItActuallyMoves() {
        let before = makeTracker()
        before.observe(backlog(["foo": .ready]), at: t0)
        before.observe(backlog(["foo": .done]), at: t0 + day)

        let reloaded = reloadStore()
        let afterRestart = EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
        afterRestart.observe(backlog(["foo": .done]), at: t0 + 2 * day)
        XCTAssertEqual(reloaded.approvalEvents.map(\.kind), [.approved], "Seeding at `done` records nothing")

        afterRestart.observe(backlog(["foo": .ready]), at: t0 + 3 * day)

        XCTAssertEqual(reloaded.approvalEvents.map(\.kind), [.approved, .reopened],
                       "And exactly one reopen when it does come back")
        XCTAssertEqual(reloaded.approvalEvents[1].at, t0 + 3 * day)
    }

    /// A reopen found at seed is an ordinary reopen to the rate — including on
    /// which side of the window it lands, which is decided by its approval.
    func testSeedReopenIsCountedByTheRate() {
        let before = makeTracker()
        before.observe(backlog(["foo": .ready]), at: t0)
        before.observe(backlog(["foo": .done]), at: t0)

        let reloaded = reloadStore()
        EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
            .observe(backlog(["foo": .ready]), at: t0 + day)

        let rate = reloaded.escapedDefectRate(projectPath: projectPath)
        XCTAssertEqual(rate.approvals, 1)
        XCTAssertEqual(rate.reopened, 1)
        XCTAssertEqual(rate.rate, 1.0)
    }

    /// The app being closed for a month does not turn an old approval into a
    /// fresh escape: the window is measured off `approvedAt` either way.
    func testSeedReopenLongAfterItsApprovalIsALateReopen() {
        let before = makeTracker()
        before.observe(backlog(["foo": .ready]), at: t0)
        before.observe(backlog(["foo": .done]), at: t0)

        let reloaded = reloadStore()
        EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
            .observe(backlog(["foo": .ready]), at: t0 + 30 * day)

        let rate = reloaded.escapedDefectRate(projectPath: projectPath)
        XCTAssertEqual(rate.reopened, 0)
        XCTAssertEqual(rate.lateReopened, 1)
        XCTAssertEqual(rate.rate, 0.0)
    }

    /// Work that was re-approved and then came back again while closed is a
    /// second escape, not the first one seen twice.
    func testSeedRecordsAReopenAfterAnApprovalThatFollowedAnEarlierReopen() {
        let before = makeTracker()
        before.observe(backlog(["foo": .ready]), at: t0)
        before.observe(backlog(["foo": .done]), at: t0 + day)
        before.observe(backlog(["foo": .ready]), at: t0 + 2 * day)
        before.observe(backlog(["foo": .done]), at: t0 + 3 * day)

        let reloaded = reloadStore()
        EscapedDefectTracker(store: reloaded, projectPath: projectPath, projectName: projectName)
            .observe(backlog(["foo": .ready]), at: t0 + 4 * day)

        XCTAssertEqual(reloaded.approvalEvents.map(\.kind), [.approved, .reopened, .approved, .reopened])
        XCTAssertEqual(reloaded.approvalEvents[3].approvedAt, t0 + 3 * day,
                       "Measured from the second approval, not the reopen that preceded it")
    }

    /// Another project's approval of a same-named item is not this project's
    /// escape — the seed filters on the project like every other read does.
    func testSeedIgnoresAnApprovalRecordedByAnotherProject() {
        let beta = EscapedDefectTracker(store: store, projectPath: "/tmp/beta", projectName: "beta")
        beta.observe(backlog(["foo": .ready]), at: t0)
        beta.observe(backlog(["foo": .done]), at: t0 + day)

        makeTracker().observe(backlog(["foo": .ready]), at: t0 + 2 * day)

        XCTAssertEqual(store.escapedDefectRate(projectPath: projectPath).reopened, 0)
        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved])
    }

    // MARK: - Wiring

    /// End to end through the view model: approving at the human gate and then
    /// sending the item back is what the metric counts, and the view model is
    /// where both of those happen.
    func testViewModelRecordsAnApprovalFollowedByAReopen() throws {
        let vm = try makeViewModel()
        vm.configureEscapedDefectTracking(store: store, projectPath: projectPath, projectName: projectName)

        vm.approve(itemID: "task-1")
        vm.updateItemStatus(itemID: "task-1", newStatus: .ready)

        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved, .reopened])
        XCTAssertEqual(store.escapedDefectRate(projectPath: projectPath).rate, 1.0)
    }

    /// The same view model path a reviewer rejection takes must stay out of it.
    func testViewModelRejectionIsNotCountedAsAReopen() throws {
        let vm = try makeViewModel()
        vm.configureEscapedDefectTracking(store: store, projectPath: projectPath, projectName: projectName)

        vm.reject(itemID: "task-2", reason: "verify failed")

        XCTAssertEqual(store.approvalEvents, [])
    }

    /// A hand edit to BACKLOG.md reopens an item just as much as a click does.
    func testViewModelCatchesAReopenMadeOutsideTheApp() throws {
        let vm = try makeViewModel()
        vm.configureEscapedDefectTracking(store: store, projectPath: projectPath, projectName: projectName)
        vm.approve(itemID: "task-1")
        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved])

        try """
        ---
        project: alpha
        ---

        # Alpha Backlog

        ## Epic: Now

        - [ ] task-1 | First task | ready
        - [ ] task-2 | Second task | awaiting-approval
        """.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        vm.reload()

        XCTAssertEqual(store.approvalEvents.map(\.kind), [.approved, .reopened])
    }

    // MARK: - Helpers

    private func makeTracker() -> EscapedDefectTracker {
        EscapedDefectTracker(store: store, projectPath: projectPath, projectName: projectName)
    }

    /// A second store over the same files — what the next launch reads, and the
    /// only thing that survives the app quitting.
    private func reloadStore() -> TaskMetricStore {
        TaskMetricStore(
            metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
            estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
            approvalsURL: tempDir.appending(path: "task-approvals.jsonl")
        )
    }

    private func backlog(_ statuses: [String: BacklogItemStatus]) -> BacklogFile {
        let items = statuses.keys.sorted().map { id in
            BacklogItem(id: id, title: id, verify: nil, status: statuses[id]!, type: .local)
        }
        return BacklogFile(project: projectName, repo: nil, verifyDefault: nil,
                           sections: [BacklogSection(name: "Now", items: items)])
    }

    private func makeViewModel() throws -> BacklogViewModel {
        let backlog = """
        ---
        project: alpha
        ---

        # Alpha Backlog

        ## Epic: Now

        - [ ] task-1 | First task | awaiting-approval
        - [ ] task-2 | Second task | awaiting-approval
        """
        try backlog.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let vm = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        )
        vm.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        return vm
    }
}
