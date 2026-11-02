import XCTest
@testable import KiteloopCore

final class EventBusTests: XCTestCase {
    private var tempDir: URL!
    private var eventsURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "event-bus")
        eventsURL = tempDir.appending(path: "events.jsonl")
    }

    func testPublishDeliversToSubscriber() async {
        let bus = EventBus(eventsURL: eventsURL)
        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady])

        let event = KiteloopEvent(source: "coder", type: .prReady, payload: ["branch": "feature/auth"])
        await bus.publish(event)
        await bus.unsubscribe(agentID: "reviewer")

        var received: [KiteloopEvent] = []
        for await e in stream {
            received.append(e)
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.source, "coder")
        XCTAssertEqual(received.first?.type, .prReady)
        XCTAssertEqual(received.first?.payload["branch"], "feature/auth")
    }

    func testUnsubscribedAgentDoesNotReceive() async {
        let bus = EventBus(eventsURL: eventsURL)
        let stream = await bus.subscribe(agentID: "reviewer", types: [.reviewComplete])

        let event = KiteloopEvent(source: "coder", type: .prReady)
        await bus.publish(event)
        await bus.unsubscribe(agentID: "reviewer")

        var received: [KiteloopEvent] = []
        for await e in stream {
            received.append(e)
        }
        XCTAssertEqual(received.count, 0)
    }

    func testPersistenceRoundtrip() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        await bus.publish(KiteloopEvent(source: "coder", type: .taskComplete, payload: ["task": "build"]))
        await bus.publish(KiteloopEvent(source: "researcher", type: .prReady))

        let bus2 = EventBus(eventsURL: eventsURL)
        let undelivered = await bus2.replayUndelivered(for: "reviewer")
        XCTAssertEqual(undelivered.count, 0)

        // Held for the duration of the replay: a discarded AsyncStream is deinit'd
        // at once, and its onTermination hook unsubscribes the agent — which would
        // make replayUndelivered return nothing for a reason this test isn't about.
        let stream = await bus2.subscribe(agentID: "reviewer", types: [.taskComplete, .prReady])
        let replay = await bus2.replayUndelivered(for: "reviewer")
        XCTAssertEqual(replay.count, 2)
        withExtendedLifetime(stream) {}
    }

    func testPublishCapsInMemoryHistory() async {
        let bus = EventBus(eventsURL: eventsURL, maxInMemoryEvents: 5)
        var published: [KiteloopEvent] = []
        for i in 0..<20 {
            let event = KiteloopEvent(source: "coder", type: .custom, payload: ["n": "\(i)"])
            published.append(event)
            await bus.publish(event)
        }

        let retained = await bus.recentEvents()
        XCTAssertEqual(retained.count, 5, "In-memory history should stop growing at the cap")
        XCTAssertEqual(retained.map(\.id), published.suffix(5).map(\.id),
                       "The newest events should be the ones retained, oldest→newest")
    }

    func testCappingDoesNotTruncateTheOnDiskLog() async throws {
        let bus = EventBus(eventsURL: eventsURL, maxInMemoryEvents: 2)
        for i in 0..<10 {
            await bus.publish(KiteloopEvent(source: "coder", type: .custom, payload: ["n": "\(i)"]))
        }

        let content = try String(contentsOf: eventsURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 10, "Every event should still be persisted")
    }

    func testStartupLoadIsCapped() async {
        let writer = EventBus(eventsURL: eventsURL)
        var published: [KiteloopEvent] = []
        for i in 0..<10 {
            let event = KiteloopEvent(source: "coder", type: .prReady, payload: ["n": "\(i)"])
            published.append(event)
            await writer.publish(event)
        }

        let reopened = EventBus(eventsURL: eventsURL, maxInMemoryEvents: 3)
        let loaded = await reopened.recentEvents()
        XCTAssertEqual(loaded.map(\.id), published.suffix(3).map(\.id),
                       "Only the tail of the on-disk log should be loaded into memory")
    }

    func testReplayUndeliveredIsBoundedByTheCap() async {
        let bus = EventBus(eventsURL: eventsURL, maxInMemoryEvents: 4)
        // Published before anyone subscribed, so nothing is marked delivered and
        // the only thing holding the replay down is the in-memory window.
        for i in 0..<10 {
            await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["n": "\(i)"]))
        }

        // Held for the rest of the test: a discarded AsyncStream is deinit'd at
        // once, and its onTermination hook unsubscribes the agent — after which
        // replayUndelivered returns [] for a reason this test isn't about, and
        // both assertions below would hold whatever delivery did.
        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady])
        let backlog = await bus.replayUndelivered(for: "reviewer")
        XCTAssertEqual(backlog.count, 4, "Replay cannot exceed the retained window")

        for i in 10..<14 {
            await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["n": "\(i)"]))
        }

        let replay = await bus.replayUndelivered(for: "reviewer")
        XCTAssertEqual(replay.count, 0,
                       "The window now holds only events this live subscriber was handed")
        withExtendedLifetime(stream) {}
    }

    func testReplayUndeliveredFiltersCorrectly() async {
        let bus = EventBus(eventsURL: eventsURL)
        // Published before the reviewer arrived, so nobody was handed it.
        await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["n": "before"]))

        // Held for the rest of the test, for the reason spelled out above.
        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady])
        await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["n": "delivered"]))
        await bus.publish(KiteloopEvent(source: "coder", type: .error, payload: ["n": "other-type"]))

        let undelivered = await bus.replayUndelivered(for: "reviewer")
        XCTAssertEqual(undelivered.map { $0.payload["n"] }, ["before"],
                       "What a live subscriber was handed does not replay; what it missed still does")
        withExtendedLifetime(stream) {}
    }

    // MARK: - Delivery marks

    /// The mark has to land on the copy the bus keeps, not on a local the fan-out
    /// throws away — that retained copy is what `replayUndelivered` filters on.
    func testDeliveryIsRecordedOnTheRetainedEvent() async {
        let bus = EventBus(eventsURL: eventsURL)
        let reviewer = await bus.subscribe(agentID: "reviewer", types: [.prReady])
        let auditor = await bus.subscribe(agentID: "auditor", types: [.prReady])
        let planner = await bus.subscribe(agentID: "planner", types: [.reviewComplete])

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady))

        let retained = await bus.recentEvents()
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.deliveredTo, ["reviewer", "auditor"],
                       "Every subscriber the event was handed to is named, and only those")

        let reviewerReplay = await bus.replayUndelivered(for: "reviewer")
        XCTAssertEqual(reviewerReplay.count, 0)
        let plannerReplay = await bus.replayUndelivered(for: "planner")
        XCTAssertEqual(plannerReplay.count, 0,
                       "A type the agent didn't subscribe to was never its to replay")
        withExtendedLifetime((reviewer, auditor, planner)) {}
    }

    /// And on the line written to disk, so a relaunch reads the same answer the
    /// running bus had rather than replaying a month of delivered history.
    func testDeliveryIsRecordedOnTheLineWrittenToDisk() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady])

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["n": "delivered"]))
        await bus.publish(KiteloopEvent(source: "coder", type: .error, payload: ["n": "unheard"]))
        withExtendedLifetime(stream) {}

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try fileLines().map { try decoder.decode(KiteloopEvent.self, from: Data($0.utf8)) }

        XCTAssertEqual(persisted.map { $0.payload["n"] }, ["delivered", "unheard"])
        XCTAssertEqual(persisted.first?.deliveredTo, ["reviewer"])
        XCTAssertEqual(persisted.last?.deliveredTo, [],
                       "A publish no subscriber matched is written undelivered")
    }

    // MARK: - publish fan-out

    /// One publish must reach *every* subscriber whose type filter matches, and
    /// only those — the fan-out loop is what makes agents react to each other.
    func testPublishDeliversToAllMatchingSubscribers() async {
        let bus = EventBus(eventsURL: eventsURL)
        // Held in locals: a discarded AsyncStream is deinit'd immediately, and its
        // onTermination hook unsubscribes the agent behind the test's back.
        let reviewer = await bus.subscribe(agentID: "reviewer", types: [.prReady])
        let auditor = await bus.subscribe(agentID: "auditor", types: [.prReady, .error])
        let planner = await bus.subscribe(agentID: "planner", types: [.reviewComplete])

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["branch": "feature/auth"]))
        for agentID in ["reviewer", "auditor", "planner"] {
            await bus.unsubscribe(agentID: agentID)
        }

        let reviewerEvents = await drain(reviewer)
        let auditorEvents = await drain(auditor)
        let plannerEvents = await drain(planner)

        XCTAssertEqual(reviewerEvents.map(\.type), [.prReady])
        XCTAssertEqual(reviewerEvents.first?.payload["branch"], "feature/auth")
        XCTAssertEqual(auditorEvents.map(\.type), [.prReady], "A multi-type filter still matches on one type")
        XCTAssertEqual(plannerEvents.count, 0, "Non-matching type filter receives nothing")
    }

    /// Subscribers see events in publish order, not just the latest one.
    func testPublishDeliversEveryMatchingEventInOrder() async {
        let bus = EventBus(eventsURL: eventsURL)
        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady, .taskComplete])

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["n": "1"]))
        await bus.publish(KiteloopEvent(source: "coder", type: .error, payload: ["n": "skipped"]))
        await bus.publish(KiteloopEvent(source: "coder", type: .taskComplete, payload: ["n": "2"]))
        await bus.unsubscribe(agentID: "reviewer")

        let received = await drain(stream)
        XCTAssertEqual(received.map { $0.payload["n"] }, ["1", "2"])
    }

    // MARK: - recentEvents backfill

    /// The console feed's backfill is this window, so the order has to be
    /// oldest→newest to append straight onto the feed.
    func testRecentEventsReturnsPublishedEventsOldestToNewest() async {
        let bus = EventBus(eventsURL: eventsURL)
        let empty = await bus.recentEvents()
        XCTAssertTrue(empty.isEmpty, "A bus with no history backfills nothing")

        for n in 0..<3 {
            await bus.publish(KiteloopEvent(source: "coder", type: .taskComplete, payload: ["n": "\(n)"]))
        }

        let recent = await bus.recentEvents()
        XCTAssertEqual(recent.map { $0.payload["n"] }, ["0", "1", "2"])
    }

    /// The limit trims the *oldest* events — a backfill should show the newest
    /// activity, not the first events the bus ever saw.
    func testRecentEventsLimitKeepsNewest() async {
        let bus = EventBus(eventsURL: eventsURL)
        for n in 0..<5 {
            await bus.publish(KiteloopEvent(source: "coder", type: .taskComplete, payload: ["n": "\(n)"]))
        }

        let recent = await bus.recentEvents(limit: 2)
        XCTAssertEqual(recent.map { $0.payload["n"] }, ["3", "4"])

        let overshoot = await bus.recentEvents(limit: 50)
        XCTAssertEqual(overshoot.count, 5, "A limit above the history size returns everything")
    }

    /// On relaunch the feed backfills from the persisted log, so recentEvents has
    /// to include events this bus instance never published itself.
    func testRecentEventsBackfillsFromPersistedHistory() async {
        let bus = EventBus(eventsURL: eventsURL)
        await bus.publish(KiteloopEvent(source: "coder", type: .taskComplete, payload: ["task": "build"]))
        await bus.publish(KiteloopEvent(source: "reviewer", type: .reviewComplete))

        let reloaded = EventBus(eventsURL: eventsURL)
        let recent = await reloaded.recentEvents()

        XCTAssertEqual(recent.map(\.source), ["coder", "reviewer"])
        XCTAssertEqual(recent.map(\.type), [.taskComplete, .reviewComplete])
        XCTAssertEqual(recent.first?.payload["task"], "build")
    }

    // MARK: - backfillAndSubscribe

    /// The whole point of the combined call: an event published after it cannot
    /// have slipped past both the history it copied and the subscription it
    /// registered, because there is no moment between the two to slip into.
    func testBackfillAndSubscribeLeavesNoGapForAPublish() async {
        let bus = EventBus(eventsURL: eventsURL)
        await bus.publish(KiteloopEvent(source: "coder", type: .taskComplete, payload: ["n": "history"]))

        let (backfill, stream) = await bus.backfillAndSubscribe(
            agentID: "console",
            types: Set(KiteloopEvent.EventType.allCases)
        )
        XCTAssertEqual(backfill.map { $0.payload["n"] }, ["history"])

        await bus.publish(KiteloopEvent(source: "coder", type: .error, payload: ["n": "after"]))
        await bus.unsubscribe(agentID: "console")

        let live = await drain(stream)
        XCTAssertEqual(live.map { $0.payload["n"] }, ["after"])
    }

    /// The history is copied before the subscription is registered, so an event
    /// the backfill already carries is never yielded to the stream as well.
    func testBackfillAndSubscribeDoesNotDeliverTheBackfillTwice() async {
        let bus = EventBus(eventsURL: eventsURL)
        for n in 0..<3 {
            await bus.publish(KiteloopEvent(source: "coder", type: .taskComplete, payload: ["n": "\(n)"]))
        }

        let (backfill, stream) = await bus.backfillAndSubscribe(
            agentID: "console",
            types: Set(KiteloopEvent.EventType.allCases)
        )
        await bus.unsubscribe(agentID: "console")

        let live = await drain(stream)
        XCTAssertEqual(backfill.map { $0.payload["n"] }, ["0", "1", "2"])
        XCTAssertTrue(live.isEmpty, "History is not replayed onto the live stream")
    }

    /// It honours `limit` exactly as `recentEvents(limit:)` does — the backfill is
    /// that same window, not the whole retained history.
    func testBackfillAndSubscribeHonoursTheLimit() async {
        let bus = EventBus(eventsURL: eventsURL)
        for n in 0..<5 {
            await bus.publish(KiteloopEvent(source: "coder", type: .taskComplete, payload: ["n": "\(n)"]))
        }

        let (backfill, _) = await bus.backfillAndSubscribe(
            agentID: "console",
            types: Set(KiteloopEvent.EventType.allCases),
            limit: 2
        )
        await bus.unsubscribe(agentID: "console")

        XCTAssertEqual(backfill.map { $0.payload["n"] }, ["3", "4"])
    }

    /// The subscription it returns is a real one: it filters by type and is
    /// visible to `unsubscribe` under the agent id that was passed.
    func testBackfillAndSubscribeRegistersATypeFilteredSubscription() async {
        let bus = EventBus(eventsURL: eventsURL)
        let (_, stream) = await bus.backfillAndSubscribe(agentID: "reviewer", types: [.prReady])

        await bus.publish(KiteloopEvent(source: "coder", type: .taskComplete, payload: ["n": "ignored"]))
        await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["n": "wanted"]))
        await bus.unsubscribe(agentID: "reviewer")

        let live = await drain(stream)
        XCTAssertEqual(live.map { $0.payload["n"] }, ["wanted"])
    }

    // MARK: - unsubscribe

    /// unsubscribe must finish the continuation: a subscriber's `for await` loop
    /// would otherwise hang forever and leak the consuming task.
    func testUnsubscribeFinishesStream() async {
        let bus = EventBus(eventsURL: eventsURL)
        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady])

        let finished = XCTestExpectation(description: "stream terminated after unsubscribe")
        Task {
            for await _ in stream {}
            finished.fulfill()
        }

        await bus.unsubscribe(agentID: "reviewer")

        await fulfillment(of: [finished], timeout: 2.0)
    }

    /// Buffered events survive the finish — unsubscribing right after a publish
    /// drains what was already yielded rather than dropping it.
    func testUnsubscribeDeliversBufferedEventsBeforeFinishing() async {
        let bus = EventBus(eventsURL: eventsURL)
        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady])

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["n": "1"]))
        await bus.unsubscribe(agentID: "reviewer")

        let received = await drain(stream)
        XCTAssertEqual(received.map { $0.payload["n"] }, ["1"])
    }

    /// After unsubscribe the agent is off the fan-out list entirely.
    func testUnsubscribeStopsFurtherDelivery() async {
        let bus = EventBus(eventsURL: eventsURL)
        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady])

        await bus.unsubscribe(agentID: "reviewer")
        await bus.publish(KiteloopEvent(source: "coder", type: .prReady))

        let received = await drain(stream)
        XCTAssertEqual(received.count, 0)
    }

    /// Unsubscribing an agent that never subscribed is a no-op, not a crash.
    func testUnsubscribeUnknownAgentIsHarmless() async {
        let bus = EventBus(eventsURL: eventsURL)
        await bus.unsubscribe(agentID: "ghost")

        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady])
        await bus.publish(KiteloopEvent(source: "coder", type: .prReady))
        await bus.unsubscribe(agentID: "reviewer")

        let received = await drain(stream)
        XCTAssertEqual(received.count, 1, "An unrelated unsubscribe must not disturb live subscribers")
    }

    // MARK: - On-disk retention

    /// The whole point: a log left running for months stops carrying every event
    /// it ever published. What is outside the window goes from the *file*, and
    /// what is inside it stays, in order.
    func testLoadDropsEventsPastTheRetentionWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write([
            eventLine(id: "ancient", at: now.addingTimeInterval(-90 * day)),
            eventLine(id: "expired", at: now.addingTimeInterval(-EventBus.retentionAge - 60)),
            eventLine(id: "just-inside", at: now.addingTimeInterval(-EventBus.retentionAge + 60)),
            eventLine(id: "recent", at: now.addingTimeInterval(-60))
        ])

        _ = EventBus(eventsURL: eventsURL, clock: { now })

        XCTAssertEqual(try idsInFile(), ["just-inside", "recent"],
                       "Aged-out lines should be gone from the file, the newer ones kept in order")
    }

    /// The compaction has to reach memory too — an event dropped from the file
    /// must not come back through the feed or a replay.
    func testCompactedEventsAreNotLoadedIntoMemory() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write([
            eventLine(id: "expired", at: now.addingTimeInterval(-40 * day)),
            eventLine(id: "recent", at: now.addingTimeInterval(-60))
        ])

        let bus = EventBus(eventsURL: eventsURL, clock: { now })
        let recent = await bus.recentEvents()
        XCTAssertEqual(recent.map(\.id), ["recent"])
    }

    /// A log entirely inside the window is not rewritten at all: no reordering, no
    /// re-encoding into whatever dialect today's decoder speaks, not so much as a
    /// changed byte.
    func testLogInsideTheWindowIsLeftByteForByteAlone() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write([
            eventLine(id: "a", at: now.addingTimeInterval(-2 * day)),
            eventLine(id: "b", at: now.addingTimeInterval(-60))
        ])
        let before = try Data(contentsOf: eventsURL)

        _ = EventBus(eventsURL: eventsURL, clock: { now })

        XCTAssertEqual(try Data(contentsOf: eventsURL), before,
                       "Nothing aged out, so nothing should have been written")
    }

    /// A line nobody can decode has no timestamp to judge, and compaction is the
    /// one thing that could erase it — the same choice `RunRecordStore` makes.
    func testCompactionKeepsLinesTheDecoderCannotRead() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write([
            eventLine(id: "expired", at: now.addingTimeInterval(-40 * day)),
            #"{"id":"truncated","timestamp":"#,
            "not json at all",
            eventLine(id: "recent", at: now.addingTimeInterval(-60))
        ])

        _ = EventBus(eventsURL: eventsURL, clock: { now })

        let lines = try fileLines()
        XCTAssertEqual(lines.count, 3, "Only the expired event should have gone")
        XCTAssertEqual(lines[0], #"{"id":"truncated","timestamp":"#)
        XCTAssertEqual(lines[1], "not json at all")
        XCTAssertTrue(lines[2].contains("\"recent\""))
    }

    /// A kill partway through appending an em dash leaves bytes that are not
    /// valid UTF-8. That one line must not cost the events on either side of it.
    func testEventsAroundAnInvalidUTF8LineStillBackfill() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeBytes([
            Data(eventLine(id: "before", at: now.addingTimeInterval(-2 * day)).utf8),
            cutOffMultiByteLine,
            Data(eventLine(id: "after", at: now.addingTimeInterval(-60)).utf8)
        ])

        let bus = EventBus(eventsURL: eventsURL, clock: { now })
        let recent = await bus.recentEvents()
        XCTAssertEqual(recent.map(\.id), ["before", "after"])
    }

    /// The bad line must not stop retention either: the expired event goes, and
    /// the unreadable line goes back as the bytes that were read — no
    /// replacement characters.
    func testCompactionRunsAndKeepsAnInvalidUTF8LineByteForByte() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recentLine = Data(eventLine(id: "recent", at: now.addingTimeInterval(-60)).utf8)
        try writeBytes([
            Data(eventLine(id: "expired", at: now.addingTimeInterval(-40 * day)).utf8),
            cutOffMultiByteLine,
            recentLine
        ])

        _ = EventBus(eventsURL: eventsURL, clock: { now })

        let newline = Data([UInt8(ascii: "\n")])
        XCTAssertEqual(try Data(contentsOf: eventsURL), cutOffMultiByteLine + newline + recentLine + newline,
                       "Only the expired event should have gone; the bad line stays exactly as it was")
    }

    /// Nothing aged out, so a log with a bad line in it is not rewritten at all.
    func testLogInsideTheWindowWithAnInvalidUTF8LineIsLeftByteForByteAlone() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeBytes([
            Data(eventLine(id: "a", at: now.addingTimeInterval(-2 * day)).utf8),
            cutOffMultiByteLine,
            Data(eventLine(id: "b", at: now.addingTimeInterval(-60)).utf8)
        ])
        let before = try Data(contentsOf: eventsURL)

        _ = EventBus(eventsURL: eventsURL, clock: { now })

        XCTAssertEqual(try Data(contentsOf: eventsURL), before)
    }

    /// Everything inside the window behaves exactly as it did before the window
    /// existed — the backfill order and the replay filter are untouched.
    func testEventsInsideTheWindowReplayAsBefore() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try write([
            eventLine(id: "expired", at: now.addingTimeInterval(-40 * day), type: "pr_ready"),
            eventLine(id: "kept-1", at: now.addingTimeInterval(-2 * day), type: "pr_ready", n: "1"),
            eventLine(id: "kept-2", at: now.addingTimeInterval(-1 * day), type: "task_complete", n: "2"),
            eventLine(id: "kept-3", at: now.addingTimeInterval(-60), type: "pr_ready", n: "3")
        ])

        let bus = EventBus(eventsURL: eventsURL, clock: { now })
        let recent = await bus.recentEvents()
        XCTAssertEqual(recent.map { $0.payload["n"] }, ["1", "2", "3"],
                       "Backfill still runs oldest→newest over what survives")

        let stream = await bus.subscribe(agentID: "reviewer", types: [.prReady])
        let replay = await bus.replayUndelivered(for: "reviewer")
        XCTAssertEqual(replay.map(\.id), ["kept-1", "kept-3"],
                       "Replay still filters by type and by what was already delivered")
        withExtendedLifetime(stream) {}
    }

    /// The compacted file has to be the same kind of file it was: a rewrite that
    /// dropped the trailing newline would splice the next event onto the last line.
    func testCompactedLogStaysAppendable() async throws {
        // Wall-clock here, unlike the cases above: the event this test publishes
        // stamps itself with `Date()`, and it has to be inside the window the
        // reopened bus applies.
        let now = Date()
        try write([
            eventLine(id: "expired", at: now.addingTimeInterval(-40 * day)),
            eventLine(id: "recent", at: now.addingTimeInterval(-60))
        ])

        let bus = EventBus(eventsURL: eventsURL, clock: { now })
        await bus.publish(KiteloopEvent(source: "coder", type: .custom, payload: ["n": "new"]))

        let reopened = EventBus(eventsURL: eventsURL, clock: { now })
        let loaded = await reopened.recentEvents()
        XCTAssertEqual(loaded.count, 2, "The appended event should decode alongside the survivor")
        XCTAssertEqual(loaded.last?.payload["n"], "new")
    }

    /// And the event published *after* the crash keeps its own line. Appending
    /// straight onto the remnant would glue the two into something that decodes
    /// as neither, so the activity log would be missing the event published after
    /// the crash — the only record of what the team did while nobody watched.
    func testAnEventPublishedAfterATruncatedLineIsReadBackOnTheNextLoad() async throws {
        let now = Date()
        try write([eventLine(id: "before", at: now.addingTimeInterval(-60))])
        // The shape a kill mid-append leaves: half an event, no newline after it.
        try appendRaw(#"{"id":"cut","timestamp":"#)

        await EventBus(eventsURL: eventsURL, clock: { now })
            .publish(KiteloopEvent(source: "coder", type: .custom, payload: ["n": "after"]))

        let reopened = EventBus(eventsURL: eventsURL, clock: { now })
        let loaded = await reopened.recentEvents()
        XCTAssertEqual(loaded.map(\.id).filter { $0 == "before" }.count, 1)
        XCTAssertEqual(loaded.last?.payload["n"], "after",
                       "the event published after the crash survives")

        let lines = try fileLines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1], #"{"id":"cut","timestamp":"#,
                       "the remnant is still there, on its own line, and still kept verbatim")
    }

    /// The ordinary append is unchanged by the repair: a log already ending in a
    /// newline gains one line, not a blank one before it.
    func testPublishingIntoALogEndingInANewlineAddsNoBlankLine() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        await bus.publish(KiteloopEvent(source: "coder", type: .custom, payload: ["n": "1"]))
        await bus.publish(KiteloopEvent(source: "coder", type: .custom, payload: ["n": "2"]))

        let content = try String(contentsOf: eventsURL, encoding: .utf8)
        XCTAssertFalse(content.contains("\n\n"), "no blank line between the events")
        XCTAssertEqual(try fileLines().count, 2)
    }

    /// The log the first event of a fresh install lands in doesn't exist yet.
    func testPublishingIntoALogThatDoesNotExistYetWritesOneTerminatedLine() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventsURL.path(percentEncoded: false)))

        await EventBus(eventsURL: eventsURL)
            .publish(KiteloopEvent(source: "coder", type: .custom, payload: ["n": "1"]))

        let content = try String(contentsOf: eventsURL, encoding: .utf8)
        XCTAssertTrue(content.hasSuffix("\n"), "the line is newline-terminated")
        XCTAssertEqual(try fileLines().count, 1)
        let reloaded = await EventBus(eventsURL: eventsURL).recentEvents()
        XCTAssertEqual(reloaded.count, 1)
    }

    // MARK: - Helpers

    private let day: TimeInterval = 24 * 60 * 60

    /// A log line as `EventBus` writes one. Built by hand rather than by
    /// publishing, because `KiteloopEvent` stamps itself with `Date()` and these
    /// cases are about lines older than any test can wait for.
    private func eventLine(
        id: String,
        at timestamp: Date,
        source: String = "coder",
        type: String = "custom",
        n: String? = nil
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let payload = n.map { #""n":"\#($0)""# } ?? ""
        return """
        {"id":"\(id)","timestamp":"\(formatter.string(from: timestamp))","source":"\(source)",\
        "type":"\(type)","payload":{\(payload)},"deliveredTo":[]}
        """
    }

    private func write(_ lines: [String]) throws {
        try (lines.map { $0 + "\n" }.joined()).write(to: eventsURL, atomically: true, encoding: .utf8)
    }

    /// Writes each line's raw bytes, newline-terminated, so a line need not be UTF-8.
    private func writeBytes(_ lines: [Data]) throws {
        try lines.reduce(into: Data()) { $0.append($1); $0.append(UInt8(ascii: "\n")) }
            .write(to: eventsURL)
    }

    /// An event cut off two bytes into an em dash (`E2 80 94`) — not valid UTF-8.
    private var cutOffMultiByteLine: Data {
        Data(#"{"id":"cut","message":"a "#.utf8) + Data([0xE2, 0x80])
    }

    /// Writes bytes onto the end of the log as it stands — no newline of its own,
    /// which is what a kill mid-append leaves behind.
    private func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: eventsURL)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func fileLines() throws -> [String] {
        try String(contentsOf: eventsURL, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
    }

    /// The `id` of every event still on disk, in file order.
    private func idsInFile() throws -> [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try fileLines().compactMap {
            try? decoder.decode(KiteloopEvent.self, from: Data($0.utf8)).id
        }
    }

    /// Collects a finished stream. Guarded by a timeout so a stream that never
    /// terminates fails the test instead of hanging the suite.
    private func drain(
        _ stream: AsyncStream<KiteloopEvent>,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [KiteloopEvent] {
        let collected = XCTestExpectation(description: "stream drained")
        let task = Task { () -> [KiteloopEvent] in
            var received: [KiteloopEvent] = []
            for await event in stream {
                received.append(event)
            }
            collected.fulfill()
            return received
        }

        let result = await XCTWaiter().fulfillment(of: [collected], timeout: timeout)
        guard result == .completed else {
            XCTFail("Stream did not finish within \(timeout)s", file: file, line: line)
            task.cancel()
            return []
        }
        return await task.value
    }
}
