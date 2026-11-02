import XCTest
import KiteloopCore
@testable import Kiteloop

final class SubscriptionEngineTests: XCTestCase {
    private var tempDir: URL!
    private var eventsURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "subscription-engine")
        eventsURL = tempDir.appending(path: "events.jsonl")
    }

    func testEventMatchesSubscription() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let triggered = expectation(description: "agent triggered")

        let engine = SubscriptionEngine(eventBus: bus) { agentID, event in
            XCTAssertEqual(agentID, "reviewer-1")
            XCTAssertEqual(event.type, .prReady)
            triggered.fulfill()
        }

        let agent = Agent(
            id: "reviewer-1",
            name: "Reviewer",
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "default",
            subscriptions: ["pr_ready"],
            state: .idle
        )

        await engine.start(agents: [agent])
        try await eventually("reviewer-1 subscribed on the bus") { await bus.hasSubscription(agentID: "reviewer-1") }
        await bus.publish(KiteloopEvent(source: "coder", type: .prReady, payload: ["pr": "#42"]))

        await fulfillment(of: [triggered], timeout: 2)
        await engine.stop()
    }

    func testNonMatchingEventIgnored() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let notTriggered = expectation(description: "should not trigger")
        notTriggered.isInverted = true

        let engine = SubscriptionEngine(eventBus: bus) { _, _ in
            notTriggered.fulfill()
        }

        let agent = Agent(
            id: "reviewer-1",
            name: "Reviewer",
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "default",
            subscriptions: ["pr_ready"],
            state: .idle
        )

        await engine.start(agents: [agent])
        try await eventually("reviewer-1 subscribed on the bus") { await bus.hasSubscription(agentID: "reviewer-1") }
        await bus.publish(KiteloopEvent(source: "system", type: .error, payload: ["msg": "oops"]))

        await fulfillment(of: [notTriggered], timeout: 0.5)
        await engine.stop()
    }

    func testMultipleAgentsSameEvent() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let count = ManagedAtomic(0)

        let engine = SubscriptionEngine(eventBus: bus) { _, _ in
            count.wrappingIncrement()
        }

        let agents = [
            Agent(id: "a1", name: "A1", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", subscriptions: ["pr_ready"], state: .idle),
            Agent(id: "a2", name: "A2", model: "sonnet", systemPrompt: "", tools: [], denied: [], permissionMode: "default", subscriptions: ["pr_ready"], state: .idle),
        ]

        await engine.start(agents: agents)
        try await eventually("both agents subscribed on the bus") {
            let first = await bus.hasSubscription(agentID: "a1")
            let second = await bus.hasSubscription(agentID: "a2")
            return first && second
        }
        await bus.publish(KiteloopEvent(source: "system", type: .prReady))

        try await eventually("both agents triggered") { count.load() == 2 }
        XCTAssertEqual(count.load(), 2)
        await engine.stop()
    }

    // MARK: - Joining and leaving a running project

    /// The agent hired into a live project: `start(agents:)` has already run
    /// without it, and it must still be triggered without a restart.
    func testAgentAddedAfterStartIsWatched() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let triggered = expectation(description: "late joiner triggered")

        let engine = SubscriptionEngine(eventBus: bus) { agentID, event in
            XCTAssertEqual(agentID, "late-1")
            XCTAssertEqual(event.type, .prReady)
            triggered.fulfill()
        }

        await engine.start(agents: [])

        await engine.startWatching(agent(id: "late-1", subscriptions: ["pr_ready"]))
        try await eventually("late-1 subscribed on the bus") { await bus.hasSubscription(agentID: "late-1") }
        await bus.publish(KiteloopEvent(source: "coder", type: .prReady))

        await fulfillment(of: [triggered], timeout: 2)
        await engine.stop()
    }

    /// Watching an id that is already watched replaces the watch rather than
    /// stacking a second one: one event, one trigger.
    ///
    /// Driven against `MultiSubscriptionBus`, which keeps both subscriptions
    /// alive. The real `EventBus` finishes the first stream as the second is
    /// taken, which would end the replaced task whether or not the engine had
    /// cancelled it — the point here is that the engine cancels it itself.
    func testStartWatchingSameAgentTwiceLeavesOneWatch() async throws {
        let bus = MultiSubscriptionBus()
        let count = ManagedAtomic(0)

        let engine = SubscriptionEngine(eventBus: bus) { _, _ in
            count.wrappingIncrement()
        }

        let joiner = agent(id: "twice-1", subscriptions: ["pr_ready"])
        await engine.startWatching(joiner)
        try await eventually("the first watch subscribed") { await bus.subscribeCount == 1 }
        await engine.startWatching(joiner)
        try await eventually("the second watch subscribed") { await bus.subscribeCount == 2 }

        let subscribes = await bus.subscribeCount
        XCTAssertEqual(subscribes, 2)

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady))
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(count.load(), 1, "the replaced watch should have been cancelled")
        await engine.stop()
    }

    /// The fired agent: neither its watch task nor its subscription outlives it.
    func testStopWatchingEndsTriggersAndDropsSubscription() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let notTriggered = expectation(description: "should not trigger after leaving")
        notTriggered.isInverted = true

        let engine = SubscriptionEngine(eventBus: bus) { _, _ in
            notTriggered.fulfill()
        }

        await engine.startWatching(agent(id: "leaver-1", subscriptions: ["pr_ready"]))
        try await eventually("leaver-1 subscribed on the bus") { await bus.hasSubscription(agentID: "leaver-1") }
        let watchedWhileJoined = await bus.hasSubscription(agentID: "leaver-1")
        XCTAssertTrue(watchedWhileJoined)

        await engine.stopWatching(agentID: "leaver-1")

        let watchedAfterLeaving = await bus.hasSubscription(agentID: "leaver-1")
        XCTAssertFalse(watchedAfterLeaving, "the event bus still holds the subscription")

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady))
        await fulfillment(of: [notTriggered], timeout: 0.5)
        await engine.stop()
    }

    /// An aside is created with no subscriptions on purpose, and starts no watch
    /// — so nothing is registered on the bus for it either.
    func testAgentWithNoSubscriptionsStartsNoWatch() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let notTriggered = expectation(description: "should not trigger")
        notTriggered.isInverted = true

        let engine = SubscriptionEngine(eventBus: bus) { _, _ in
            notTriggered.fulfill()
        }

        await engine.startWatching(agent(id: "aside-1", subscriptions: []))

        let watched = await bus.hasSubscription(agentID: "aside-1")
        XCTAssertFalse(watched)

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady))
        await fulfillment(of: [notTriggered], timeout: 0.5)
        await engine.stop()
    }

    /// An agent that leaves and joins again is watched again — the departure
    /// clears the bus entry, and the return has to put a live one back.
    func testAgentRejoiningAfterLeavingIsWatchedAgain() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let triggered = expectation(description: "rejoiner triggered")

        let engine = SubscriptionEngine(eventBus: bus) { agentID, _ in
            XCTAssertEqual(agentID, "rejoin-1")
            triggered.fulfill()
        }

        let rejoiner = agent(id: "rejoin-1", subscriptions: ["pr_ready"])
        await engine.startWatching(rejoiner)
        try await eventually("rejoin-1 subscribed on the bus") { await bus.hasSubscription(agentID: "rejoin-1") }
        await engine.stopWatching(agentID: "rejoin-1")
        await engine.startWatching(rejoiner)
        try await eventually("rejoin-1 subscribed again") { await bus.hasSubscription(agentID: "rejoin-1") }

        let watched = await bus.hasSubscription(agentID: "rejoin-1")
        XCTAssertTrue(watched)

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady))
        await fulfillment(of: [triggered], timeout: 2)
        await engine.stop()
    }

    // MARK: - Closing the project

    /// The closed project: `stop()` has to do for every watched agent what
    /// `stopWatching(agentID:)` does for one. Cancelling the tasks alone left the
    /// bus handing events to subscriptions nobody reads, and each of those held
    /// the engine and the `EventBus` behind it alive for the life of the process.
    func testStopDropsEverySubscriptionAndEndsTriggers() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let notTriggered = expectation(description: "should not trigger after the project closes")
        notTriggered.isInverted = true

        let engine = SubscriptionEngine(eventBus: bus) { _, _ in
            notTriggered.fulfill()
        }

        await engine.start(agents: [
            agent(id: "closer-1", subscriptions: ["pr_ready"]),
            agent(id: "closer-2", subscriptions: ["pr_ready"]),
        ])
        try await eventually("both closers subscribed on the bus") {
            let first = await bus.hasSubscription(agentID: "closer-1")
            let second = await bus.hasSubscription(agentID: "closer-2")
            return first && second
        }
        let firstWhileOpen = await bus.hasSubscription(agentID: "closer-1")
        let secondWhileOpen = await bus.hasSubscription(agentID: "closer-2")
        XCTAssertTrue(firstWhileOpen)
        XCTAssertTrue(secondWhileOpen)

        await engine.stop()

        let firstAfterClose = await bus.hasSubscription(agentID: "closer-1")
        let secondAfterClose = await bus.hasSubscription(agentID: "closer-2")
        XCTAssertFalse(firstAfterClose, "the event bus still holds closer-1's subscription")
        XCTAssertFalse(secondAfterClose, "the event bus still holds closer-2's subscription")

        await bus.publish(KiteloopEvent(source: "coder", type: .prReady))
        await fulfillment(of: [notTriggered], timeout: 0.5)
    }

    /// Counted on a bus that records every unsubscribe it is asked for: one per
    /// watched agent, and no more.
    func testStopUnsubscribesOncePerWatchedAgent() async throws {
        let bus = MultiSubscriptionBus()
        let engine = SubscriptionEngine(eventBus: bus) { _, _ in }

        await engine.start(agents: [
            agent(id: "closer-1", subscriptions: ["pr_ready"]),
            agent(id: "closer-2", subscriptions: ["task_complete"]),
        ])
        try await eventually("both watches subscribed") { await bus.subscribeCount == 2 }

        await engine.stop()

        let unsubscribed = await bus.unsubscribed
        XCTAssertEqual(unsubscribed.sorted(), ["closer-1", "closer-2"])
    }

    /// The closed project's history goes with it — so an engine started again
    /// subscribes afresh rather than replaying what the previous run had already
    /// handed over.
    func testStopThenStartSubscribesAfreshAndReplaysNothing() async throws {
        let bus = EventBus(eventsURL: eventsURL)
        let triggers = ManagedAtomic(0)

        let engine = SubscriptionEngine(eventBus: bus) { _, _ in
            triggers.wrappingIncrement()
        }

        let watched = agent(id: "restart-1", subscriptions: ["task_complete"])
        await engine.start(agents: [watched])
        try await eventually("restart-1 subscribed on the bus") { await bus.hasSubscription(agentID: "restart-1") }
        await bus.publish(KiteloopEvent(source: "system", type: .taskComplete))
        try await eventually("the watched agent triggered") { triggers.load() == 1 }
        XCTAssertEqual(triggers.load(), 1, "the watched agent should have been triggered while the project was open")

        await engine.stop()

        await engine.start(agents: [watched])
        try await eventually("restart-1 subscribed again") { await bus.hasSubscription(agentID: "restart-1") }
        let watchedAgain = await bus.hasSubscription(agentID: "restart-1")
        XCTAssertTrue(watchedAgain, "a restarted engine should subscribe again")
        XCTAssertEqual(triggers.load(), 1, "the event published before stop() was replayed to the restarted engine")

        await bus.publish(KiteloopEvent(source: "system", type: .taskComplete))
        try await eventually("the restarted engine triggered") { triggers.load() == 2 }
        XCTAssertEqual(triggers.load(), 2, "the restarted engine should trigger on an event published after the restart")

        await engine.stop()
    }

    private func agent(id: String, subscriptions: [String]) -> Agent {
        Agent(
            id: id,
            name: id,
            model: "sonnet",
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: "default",
            subscriptions: subscriptions,
            state: .idle
        )
    }
}

/// An event bus that keeps every subscription it hands out, including a second
/// one taken under an id it is already serving. `EventBus` replaces the first in
/// that case; holding both is what lets a test see whether the engine cancelled
/// the watch task it replaced.
private actor MultiSubscriptionBus: EventBusProtocol {
    private struct Entry {
        let agentID: String
        let types: Set<KiteloopEvent.EventType>
        let continuation: AsyncStream<KiteloopEvent>.Continuation
    }

    private var entries: [Entry] = []
    private(set) var subscribeCount = 0
    private(set) var unsubscribed: [String] = []

    func publish(_ event: KiteloopEvent) {
        for entry in entries where entry.types.contains(event.type) {
            entry.continuation.yield(event)
        }
    }

    func subscribe(agentID: String, types: Set<KiteloopEvent.EventType>) -> AsyncStream<KiteloopEvent> {
        subscribeCount += 1
        return AsyncStream { continuation in
            entries.append(Entry(agentID: agentID, types: types, continuation: continuation))
        }
    }

    func unsubscribe(agentID: String) {
        unsubscribed.append(agentID)
        for entry in entries where entry.agentID == agentID {
            entry.continuation.finish()
        }
        entries.removeAll { $0.agentID == agentID }
    }

    func replayUndelivered(for agentID: String) -> [KiteloopEvent] { [] }
}

private final class ManagedAtomic: @unchecked Sendable {
    private var value: Int
    private let lock = NSLock()

    init(_ initial: Int) { value = initial }

    func wrappingIncrement(ordering: Void = ()) {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func load(ordering: Void = ()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
