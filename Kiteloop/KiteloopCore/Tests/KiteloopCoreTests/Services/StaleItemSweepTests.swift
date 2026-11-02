import XCTest
@testable import KiteloopCore

/// The staleness sweep: which open items nothing has touched inside the
/// window, read as a fixture checkout would present it — an old open item, a
/// fresh open item, and an old done item that ages by design rather than by
/// neglect.
final class StaleItemSweepTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - flag: the pure judgment

    /// The load-bearing case: three items, three ages, one flagged.
    func testAnOldOpenItemIsFlaggedAFreshOneIsNotAndADoneOneIsNeverJudged() {
        let old = item("old-1", status: .ready)
        let fresh = item("fresh-1", status: .ready)
        let doneButOld = item("done-1", status: .done)

        let flagged = StaleItemSweep.flag(
            items: [old, fresh, doneButOld],
            lastTouched: [
                "old-1": now.addingTimeInterval(-40 * 24 * 60 * 60),
                "fresh-1": now.addingTimeInterval(-2 * 24 * 60 * 60),
                "done-1": now.addingTimeInterval(-90 * 24 * 60 * 60),
            ],
            now: now
        )

        XCTAssertEqual(flagged.map(\.itemID), ["old-1"])
        XCTAssertEqual(flagged.first?.status, .ready)
    }

    /// Exactly the window is stale — the boundary reads inclusive, not "one
    /// commit older than the number everyone quotes".
    func testAnItemExactlyAtTheWindowIsFlagged() {
        let boundary = item("boundary-1", status: .active)

        let flagged = StaleItemSweep.flag(
            items: [boundary],
            lastTouched: ["boundary-1": now.addingTimeInterval(-StaleItemSweep.window)],
            now: now
        )

        XCTAssertEqual(flagged.map(\.itemID), ["boundary-1"])
    }

    /// `blocked` ages by design, same as `done` — a human is already expected
    /// to be looking at it, so the sweep has nothing to add.
    func testABlockedItemIsNeverJudged() {
        let blocked = item("blocked-1", status: .blocked)

        let flagged = StaleItemSweep.flag(
            items: [blocked],
            lastTouched: ["blocked-1": now.addingTimeInterval(-90 * 24 * 60 * 60)],
            now: now
        )

        XCTAssertTrue(flagged.isEmpty)
    }

    /// An item with no signal at all — no detail file, or git could not read
    /// its history — is left alone rather than treated as infinitely stale.
    func testAnItemWithNoLastTouchedEntryIsSkipped() {
        let noSignal = item("no-detail-1", status: .draft)

        let flagged = StaleItemSweep.flag(items: [noSignal], lastTouched: [:], now: now)

        XCTAssertTrue(flagged.isEmpty)
    }

    /// Every open stage is judged, not only `ready`.
    func testEveryOpenStatusIsJudged() {
        let statuses: [BacklogItemStatus] = [.draft, .ready, .active, .inReview, .awaitingApproval]
        let items = statuses.enumerated().map { index, status in item("item-\(index)", status: status) }
        let lastTouched = Dictionary(uniqueKeysWithValues:
            items.map { ($0.id, now.addingTimeInterval(-40 * 24 * 60 * 60)) })

        let flagged = StaleItemSweep.flag(items: items, lastTouched: lastTouched, now: now)

        XCTAssertEqual(Set(flagged.map(\.itemID)), Set(items.map(\.id)))
    }

    // MARK: - lastTouched: reading git, and never writing it

    /// One `git log` per open item that carries a detail path, scoped to that
    /// file — and nothing else: no `add`, no `commit`, nothing that would
    /// write to the checkout the sweep is reading.
    func testLastTouchedReadsOneGitLogPerOpenItemWithADetailPathAndWritesNothing() async {
        let checkout = URL(fileURLWithPath: "/tmp/checkout")
        let runner = ScriptedSubprocessRunner { _ in .init(output: "1700000000\n") }
        let items = [
            item("a1", status: .ready, detailPath: "backlog/a1.md"),
            item("a2", status: .done, detailPath: "backlog/a2.md"),
            item("a3", status: .draft, detailPath: nil),
        ]

        let touched = await withScriptedSubprocesses(runner) {
            StaleItemSweep.lastTouched(items: items, checkout: checkout)
        }

        let seenPaths = runner.calls.map { $0.arguments.last ?? "" }
        XCTAssertEqual(seenPaths, ["backlog/a1.md"], "only the open item with a detail path is asked about")
        XCTAssertEqual(touched, ["a1": Date(timeIntervalSince1970: 1_700_000_000)])
        XCTAssertTrue(runner.calls.allSatisfy { $0.arguments.first == "log" }, "nothing but a read ever runs")
        XCTAssertEqual(runner.calls.first?.directory, checkout)
    }

    /// A git call that fails, or answers with something that isn't a
    /// timestamp, leaves the item with no entry — which `flag` then treats as
    /// no signal, not as stale.
    func testAFailedOrUnreadableGitLogLeavesNoEntry() async {
        let runner = ScriptedSubprocessRunner { _ in .init(status: 128, output: "fatal: bad object") }
        let items = [item("a1", status: .ready, detailPath: "backlog/a1.md")]

        let touched = await withScriptedSubprocesses(runner) {
            StaleItemSweep.lastTouched(items: items, checkout: URL(fileURLWithPath: "/tmp/checkout"))
        }

        XCTAssertTrue(touched.isEmpty)
    }

    /// A superseded sweep stops where it is rather than running its list out.
    /// The caller — `BacklogViewModel.refreshStaleFlags`, one reload
    /// superseding another — cancels the task this runs in, and every item past
    /// the one git is inside costs nothing.
    @MainActor
    func testACancelledSweepAsksGitNothingFurther() async throws {
        let release = DispatchSemaphore(value: 0)
        let runner = ScriptedSubprocessRunner { call in
            if call.arguments.last == "backlog/a1.md" { release.wait() }
            return .init(output: "1700000000\n")
        }
        let items = [
            item("a1", status: .ready, detailPath: "backlog/a1.md"),
            item("a2", status: .ready, detailPath: "backlog/a2.md"),
            item("a3", status: .ready, detailPath: "backlog/a3.md"),
        ]

        try await withScriptedSubprocesses(runner) {
            let sweep = Task.detached {
                StaleItemSweep.lastTouched(items: items, checkout: URL(fileURLWithPath: "/tmp/checkout"))
            }
            try await eventually("the sweep is inside git for the first item") { runner.calls.count == 1 }

            sweep.cancel()
            release.signal()
            let touched = await sweep.value

            XCTAssertEqual(runner.calls.map { $0.arguments.last }, ["backlog/a1.md"],
                           "a cancelled sweep kept spawning git")
            XCTAssertEqual(touched.keys.sorted(), ["a1"], "what it did read before the cancel is still returned")
        }
    }

    // MARK: - Fixtures

    private func item(_ id: String, status: BacklogItemStatus, detailPath: String? = "backlog/\(UUID().uuidString).md") -> BacklogItem {
        BacklogItem(id: id, title: "Title of \(id)", status: status, type: .local, detailPath: detailPath)
    }
}
