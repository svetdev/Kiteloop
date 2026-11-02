import XCTest
import KiteloopCore
@testable import Kiteloop

@MainActor
final class ActivityFeedViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var eventsURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "activity-feed")
        eventsURL = tempDir.appending(path: "events.jsonl")
    }

    // MARK: - filteredEvents

    func testFilteredEventsReturnsEverythingWhenNoFilter() async throws {
        let (vm, feed) = try await makeFeed(publishing: [
            event(.taskComplete, "a"),
            event(.error, "b"),
            event(.prReady, "c")
        ])
        defer { feed.cancel() }

        XCTAssertNil(vm.typeFilter)
        XCTAssertEqual(ids(vm.filteredEvents), ["c", "b", "a"], "Backfill is newest first")
    }

    func testFilteredEventsKeepsOnlyMatchingTypeInNewestFirstOrder() async throws {
        let (vm, feed) = try await makeFeed(publishing: [
            event(.taskComplete, "a"),
            event(.error, "b"),
            event(.taskComplete, "c"),
            event(.prReady, "d")
        ])
        defer { feed.cancel() }

        vm.typeFilter = .taskComplete
        XCTAssertEqual(ids(vm.filteredEvents), ["c", "a"])

        vm.typeFilter = .error
        XCTAssertEqual(ids(vm.filteredEvents), ["b"])

        vm.typeFilter = nil
        XCTAssertEqual(vm.filteredEvents.count, 4)
    }

    func testFilteredEventsIsEmptyForTypeNotInFeed() async throws {
        let (vm, feed) = try await makeFeed(publishing: [event(.taskComplete, "a")])
        defer { feed.cancel() }

        vm.typeFilter = .memoryProposed
        XCTAssertTrue(vm.filteredEvents.isEmpty)
    }

    // MARK: - searchText

    func testSearchMatchesAPayloadValueIgnoringCase() async throws {
        let (vm, feed) = try await makeFeed(publishing: [
            KiteloopEvent(source: "test", type: .taskComplete, payload: ["id": "a", "item": "fix-login"]),
            KiteloopEvent(source: "test", type: .error, payload: ["id": "b", "item": "add-search"]),
            KiteloopEvent(source: "test", type: .prReady, payload: ["id": "c", "item": "Fix-Logout"])
        ])
        defer { feed.cancel() }

        vm.searchText = "FIX-LOG"
        XCTAssertEqual(ids(vm.filteredEvents), ["c", "a"])
    }

    func testSearchMatchesTheSourceLabelNotOnlyTheRawSource() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        await bus.publish(KiteloopEvent(source: "rev-7", type: .custom, payload: ["id": "a"]))
        await bus.publish(KiteloopEvent(source: "Autopilot", type: .custom, payload: ["id": "b"]))
        let names = ["rev-7": "Reviewer"]
        let vm = ActivityFeedViewModel(eventBus: bus, agentName: { names[$0] ?? $0 })
        let feed = Task { await vm.run() }
        defer { feed.cancel() }
        try await waitUntil("backfill of 2 events") { vm.events.count == 2 }

        vm.searchText = "reviewer"
        XCTAssertEqual(ids(vm.filteredEvents), ["a"], "The agent's display name finds its events")

        vm.searchText = "autopilot"
        XCTAssertEqual(ids(vm.filteredEvents), ["b"])
    }

    func testBlankSearchShowsEveryRow() async throws {
        let (vm, feed) = try await makeFeed(publishing: [
            event(.taskComplete, "a"),
            event(.error, "b")
        ])
        defer { feed.cancel() }

        vm.searchText = ""
        XCTAssertEqual(ids(vm.filteredEvents), ["b", "a"])
        vm.searchText = "  \t "
        XCTAssertEqual(ids(vm.filteredEvents), ["b", "a"], "Whitespace alone is no search")
    }

    func testSearchTrimsSurroundingWhitespace() async throws {
        let (vm, feed) = try await makeFeed(publishing: [
            event(.taskComplete, "alpha"),
            event(.error, "beta")
        ])
        defer { feed.cancel() }

        vm.searchText = "  alp "
        XCTAssertEqual(ids(vm.filteredEvents), ["alpha"])
    }

    func testSearchCombinesWithTypeFilter() async throws {
        let (vm, feed) = try await makeFeed(publishing: [
            event(.taskComplete, "item-1"),
            event(.error, "item-2"),
            event(.taskComplete, "other"),
            event(.taskComplete, "item-3")
        ])
        defer { feed.cancel() }

        vm.searchText = "item"
        vm.typeFilter = .taskComplete
        XCTAssertEqual(ids(vm.filteredEvents), ["item-3", "item-1"])

        vm.searchText = "nothing-like-this"
        XCTAssertTrue(vm.filteredEvents.isEmpty)
    }

    // MARK: - presentTypes

    func testPresentTypesIsEmptyForEmptyFeed() async throws {
        let (vm, feed) = try await makeFeed(publishing: [])
        defer { feed.cancel() }

        XCTAssertTrue(vm.presentTypes.isEmpty)
    }

    func testPresentTypesDeduplicatesAndSortsByLabel() async throws {
        let (vm, feed) = try await makeFeed(publishing: [
            event(.workflowStarted, "a"),
            event(.taskComplete, "b"),
            event(.error, "c"),
            event(.taskComplete, "d"),
            event(.prReady, "e")
        ])
        defer { feed.cancel() }

        // Labels: "Error" < "Pr Ready" < "Task Complete" < "Workflow Started".
        XCTAssertEqual(vm.presentTypes, [.error, .prReady, .taskComplete, .workflowStarted])
    }

    func testPresentTypesIgnoresTypeFilter() async throws {
        let (vm, feed) = try await makeFeed(publishing: [
            event(.error, "a"),
            event(.prReady, "b")
        ])
        defer { feed.cancel() }

        vm.typeFilter = .error
        XCTAssertEqual(vm.presentTypes, [.error, .prReady], "The filter menu still lists every type in the feed")
    }

    // MARK: - Live ingest & event cap

    func testLiveEventsAreInsertedNewestFirst() async throws {
        let bus = EventBus(eventsURL: eventsURL)

        let vm = ActivityFeedViewModel(eventBus: bus)
        let feed = Task { await vm.run() }
        defer { feed.cancel() }
        try await waitForSubscription(on: bus, feeding: vm, probe: "probe")

        await bus.publish(event(.error, "live"))
        try await waitUntil("live event ingested") { vm.events.first?.payload["id"] == "live" }

        XCTAssertEqual(ids(vm.events), ["live", "probe"])
    }

    func testEventCapDropsOldestEvents() async throws {
        let bus = EventBus(eventsURL: eventsURL)

        let vm = ActivityFeedViewModel(eventBus: bus)
        let feed = Task { await vm.run() }
        defer { feed.cancel() }
        try await waitForSubscription(on: bus, feeding: vm, probe: "probe")

        // 1 probe + 450 live = 451, which must be trimmed back to the 400 cap.
        for i in 0..<450 {
            await bus.publish(event(.custom, String(i)))
        }
        try await waitUntil("all 450 live events ingested") { vm.events.first?.payload["id"] == "449" }

        XCTAssertEqual(vm.events.count, 400)
        XCTAssertEqual(vm.events.last?.payload["id"], "50", "The oldest 51 events (probe + 0...49) are dropped")
        XCTAssertFalse(ids(vm.events).contains("probe"))
    }

    // MARK: - Starting the feed

    func testEventPublishedAsTheFeedStartsReachesIt() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        await bus.publish(event(.custom, "history"))

        let vm = ActivityFeedViewModel(eventBus: bus)
        let feed = Task { await vm.run() }
        defer { feed.cancel() }

        // Let `run()` start and make its hop into the bus, then enqueue a publish
        // behind it. A `run()` that backfilled and subscribed in two hops drops
        // this one: it lands after the history was copied and before the
        // subscription exists, so it reaches neither and the feed never shows it.
        await Task.yield()
        await bus.publish(event(.error, "gap"))

        try await waitUntil("the event published as the feed started") {
            ids(vm.events).contains("gap")
        }
        XCTAssertEqual(ids(vm.events), ["gap", "history"])
    }

    func testAnEventReachesTheFeedExactlyOnce() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        for i in 0..<20 {
            await bus.publish(event(.custom, "history-\(i)"))
        }

        let vm = ActivityFeedViewModel(eventBus: bus)
        let feed = Task { await vm.run() }
        defer { feed.cancel() }

        // Published across the handoff: whichever of these the backfill already
        // carries, the live stream must not carry as well.
        await Task.yield()
        for i in 0..<20 {
            await bus.publish(event(.error, "race-\(i)"))
        }

        try await waitUntil("the last event ingested") { ids(vm.events).contains("race-19") }

        let seen = ids(vm.events)
        XCTAssertEqual(seen.count, 40)
        XCTAssertEqual(Set(seen).count, 40, "No event is shown twice")
    }

    func testCancellingTheFeedUnsubscribes() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        // Published before the feed exists, so it is never pushed to the
        // subscription and stays pending for as long as there is one to pend for.
        await bus.publish(event(.custom, "history"))

        let vm = ActivityFeedViewModel(eventBus: bus)
        let feed = Task { await vm.run() }
        try await waitForSubscription(on: bus, feeding: vm, probe: "probe")

        let whileSubscribed = await bus.replayUndelivered(for: ActivityFeedViewModel.consumerID)
        XCTAssertTrue(ids(whileSubscribed).contains("history"), "The subscription is live")

        feed.cancel()

        // `replayUndelivered` answers with nothing at all for an agent that has no
        // subscription, which is what the pending event now reads as.
        try await waitUntil("the consumer to be unsubscribed") {
            await bus.replayUndelivered(for: ActivityFeedViewModel.consumerID).isEmpty
        }
    }

    func testClearEmptiesFeed() async throws {
        let (vm, feed) = try await makeFeed(publishing: [
            event(.error, "a"),
            event(.prReady, "b")
        ])
        defer { feed.cancel() }

        vm.clear()

        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertTrue(vm.filteredEvents.isEmpty)
        XCTAssertTrue(vm.presentTypes.isEmpty)
    }

    func testClearHoldsWhenTheFeedRunsAgain() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        await bus.publish(event(.error, "a"))
        await bus.publish(event(.prReady, "b"))

        let vm = ActivityFeedViewModel(eventBus: bus)
        let first = Task { await vm.run() }
        try await waitUntil("backfill of the old events") { vm.events.count == 2 }

        vm.clear()
        first.cancel()
        // The old events stay pending on the bus for as long as the first feed is
        // subscribed; once they read as nothing, the subscription is gone and a
        // second `run()` cannot be unsubscribed by the first one's teardown.
        try await waitUntil("the first feed to unsubscribe") {
            await bus.replayUndelivered(for: ActivityFeedViewModel.consumerID).isEmpty
        }

        await bus.publish(event(.custom, "new"))

        // Switching back to the Activity tab: the same view model runs again over
        // a bus that still holds the cleared events.
        let second = Task { await vm.run() }
        defer { second.cancel() }
        try await waitUntil("backfill of the event published after the clear") {
            ids(vm.events).contains("new")
        }
        XCTAssertEqual(ids(vm.events), ["new"], "Nothing cleared comes back")

        await bus.publish(event(.error, "live"))
        try await waitUntil("live event ingested") { vm.events.first?.payload["id"] == "live" }
        XCTAssertEqual(ids(vm.events), ["live", "new"])
    }

    // MARK: - Source label

    func testSourceLabelNamesAnAgentAndLeavesOtherSourcesAsIs() {
        let names = ["ada-2": "Ada"]
        let vm = ActivityFeedViewModel(
            eventBus: EventBus(eventsURL: eventsURL),
            agentName: { names[$0] ?? $0 }
        )

        XCTAssertEqual(vm.sourceLabel(for: KiteloopEvent(source: "ada-2", type: .custom)), "Ada")
        XCTAssertEqual(vm.sourceLabel(for: KiteloopEvent(source: "Autopilot", type: .custom)), "Autopilot")
    }

    // MARK: - Time label

    func testAnEventFromEarlierTodayShowsTheTimeWithSecondsAndNoDate() {
        let label = timeLabel(hour: 9, minute: 41, second: 7, day: 5)
        XCTAssertTrue(label.contains("9:41:07"), label)
        XCTAssertFalse(label.contains("Mar"), label)
        XCTAssertFalse(label.contains("2026"), label)
    }

    func testAnEventMinutesBeforeMidnightYesterdayShowsItsDateAndTime() {
        let label = timeLabel(hour: 23, minute: 58, second: 30, day: 4)
        XCTAssertTrue(label.contains("11:58:30"), label)
        XCTAssertTrue(label.contains("Mar 4"), label)
        XCTAssertTrue(label.contains("2026"), label)
    }

    /// The label for an event at the given time on March `day`, 2026, read at
    /// 10:00 on March 5 in UTC with an en_US calendar.
    private func timeLabel(hour: Int, minute: Int, second: Int, day: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let at = { (day: Int, hour: Int, minute: Int, second: Int) in
            calendar.date(from: DateComponents(
                year: 2026, month: 3, day: day, hour: hour, minute: minute, second: second
            ))!
        }
        return ActivityFeedViewModel.timeLabel(
            for: at(day, hour, minute, second),
            now: at(5, 10, 0, 0),
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )
    }

    // MARK: - Summary line limit

    func testSummaryLineLimitWrapsFailuresErrorsAndGateQuestions() {
        XCTAssertEqual(KiteloopEvent.EventType.workflowFailed.summaryLineLimit, 4)
        XCTAssertEqual(KiteloopEvent.EventType.workflowApprovalRequired.summaryLineLimit, 4)
        XCTAssertEqual(KiteloopEvent.EventType.error.summaryLineLimit, 4)
    }

    func testSummaryLineLimitKeepsRoutineEventsToOneLine() {
        XCTAssertEqual(KiteloopEvent.EventType.workflowTransitioned.summaryLineLimit, 1)
    }

    // MARK: - Helpers

    private func event(_ type: KiteloopEvent.EventType, _ id: String) -> KiteloopEvent {
        KiteloopEvent(source: "test", type: type, payload: ["id": id])
    }

    private func ids(_ events: [KiteloopEvent]) -> [String] {
        events.compactMap { $0.payload["id"] }
    }

    /// Publishes `events` as history, then starts the feed and waits for the
    /// backfill to land.
    private func makeFeed(
        publishing events: [KiteloopEvent]
    ) async throws -> (ActivityFeedViewModel, Task<Void, Never>) {
        let bus = EventBus(eventsURL: eventsURL)
        for event in events {
            await bus.publish(event)
        }

        let vm = ActivityFeedViewModel(eventBus: bus)
        let feed = Task { await vm.run() }
        try await waitUntil("backfill of \(events.count) events") { vm.events.count == events.count }
        return (vm, feed)
    }

    /// Waits until the feed is tailing the live stream, by publishing `probe` and
    /// waiting for it to reach `vm`.
    ///
    /// `run()` takes the backfill and the subscription in one hop, so the probe
    /// lands in exactly one of them and reaches the feed either way — and both
    /// happen only once that hop has returned, which is when the subscription is
    /// registered. Seeing the probe in the feed is therefore a read of the
    /// subscription's own presence, not of any window between the two.
    private func waitForSubscription(
        on bus: EventBus,
        feeding vm: ActivityFeedViewModel,
        probe id: String
    ) async throws {
        await bus.publish(event(.custom, id))
        try await waitUntil("activity feed subscription (probe \(id))") {
            ids(vm.events).contains(id)
        }
    }

    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor @Sendable () async -> Bool
    ) async throws {
        try await eventually(timeout: .seconds(timeout), what, file: file, line: line) { await condition() }
    }
}
