import Foundation
import os.log

private let eventBusLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "event-bus")

package protocol EventBusProtocol: Sendable {
    func publish(_ event: KiteloopEvent) async
    func subscribe(agentID: String, types: Set<KiteloopEvent.EventType>) async -> AsyncStream<KiteloopEvent>
    func unsubscribe(agentID: String) async
    func replayUndelivered(for agentID: String) async -> [KiteloopEvent]
}

package actor EventBus: EventBusProtocol {
    /// How many events are kept in memory. Only this sliding window is retained
    /// for replay and for the activity feed's backfill, so a long-running app
    /// doesn't grow without bound. Events evicted past the window are no longer
    /// replayable, though they stay on disk until they age out — see
    /// `retentionAge`.
    package static let defaultMaxInMemoryEvents = 2000

    /// How far back `events.jsonl` reaches. Thirty days, the same window
    /// `RunRecordStore.retentionAge` keeps: the two are read together as the
    /// source for the endurance and human-touch metrics in
    /// `docs/success-metrics.md`, and a window that ended earlier here would
    /// leave a run record with no events to join to.
    ///
    /// The bound is applied when the log is opened, not on every publish: events
    /// arrive hundreds to a run, and dropping a line means rewriting the whole
    /// file, which is the one thing a per-append policy must not do. A bus is
    /// built per project as the project opens, so the window is re-applied
    /// whenever a project is opened rather than only at launch.
    package static let retentionAge: TimeInterval = 30 * 24 * 60 * 60

    private let eventsURL: URL
    private let maxInMemoryEvents: Int
    private var subscriptions: [String: Subscription] = [:]
    private var events: [KiteloopEvent] = []
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    package struct Subscription {
        /// Distinguishes one subscription from the next taken under the same
        /// agent id, so a terminating stream only clears its own entry — see
        /// `removeSubscription(_:id:)`.
        package let id: UUID
        package let types: Set<KiteloopEvent.EventType>
        package let continuation: AsyncStream<KiteloopEvent>.Continuation
    
        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: UUID, types: Set<KiteloopEvent.EventType>, continuation: AsyncStream<KiteloopEvent>.Continuation) {
            self.id = id
            self.types = types
            self.continuation = continuation
        }
    }

    /// `clock` is for tests only, so the retention window can be exercised
    /// without waiting a month. It is read once, at load, which is the only place
    /// the window is applied.
    package init(
        eventsURL: URL,
        maxInMemoryEvents: Int = EventBus.defaultMaxInMemoryEvents,
        clock: () -> Date = { Date() }
    ) {
        self.eventsURL = eventsURL
        self.maxInMemoryEvents = max(1, maxInMemoryEvents)
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.events = Self.loadEvents(
            from: eventsURL,
            decoder: decoder,
            limit: self.maxInMemoryEvents,
            now: clock()
        )
    }

    /// The fan-out is resolved *before* the event is retained, so the copy kept in
    /// memory and the line written to disk both name who the event reached.
    /// `KiteloopEvent` is a struct: marking delivery after the append would only
    /// mutate a local nobody reads again, leaving `deliveredTo` empty for ever and
    /// `replayUndelivered(for:)` handing a reconnecting subscriber back everything
    /// it had already been given.
    package func publish(_ event: KiteloopEvent) {
        let matching = subscriptions.filter { $0.value.types.contains(event.type) }

        var mutableEvent = event
        mutableEvent.deliveredTo.formUnion(matching.keys)

        for sub in matching.values {
            sub.continuation.yield(mutableEvent)
        }

        events.append(mutableEvent)
        trimToCap()
        persistEvent(mutableEvent)
    }

    package func subscribe(agentID: String, types: Set<KiteloopEvent.EventType>) -> AsyncStream<KiteloopEvent> {
        if let existing = subscriptions[agentID] {
            existing.continuation.finish()
        }

        let id = UUID()
        return AsyncStream { continuation in
            subscriptions[agentID] = Subscription(id: id, types: types, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscription(agentID, id: id) }
            }
        }
    }

    package func unsubscribe(agentID: String) {
        if let sub = subscriptions.removeValue(forKey: agentID) {
            sub.continuation.finish()
        }
    }

    /// Most recent events, oldest→newest. The console activity feed's backfill is
    /// this window, taken through `backfillAndSubscribe(agentID:types:limit:)`.
    package func recentEvents(limit: Int = 300) -> [KiteloopEvent] {
        Array(events.suffix(limit))
    }

    /// The recent history *and* a live subscription, taken in one actor-isolated
    /// call. The console activity feed uses this to start tailing.
    ///
    /// Asking for the two separately — `recentEvents(limit:)` and then
    /// `subscribe(agentID:types:)` — leaves a window between the hops in which a
    /// `publish` reaches neither: it lands after the history was copied and
    /// before the subscription exists, so the caller simply never sees it. There
    /// is no suspension point here, so nothing can interleave: an event either
    /// precedes the whole call and is in the backfill, or follows it and arrives
    /// on the stream.
    ///
    /// And exactly one of the two, never both — the history is copied before the
    /// subscription is registered, and `subscribe` registers it synchronously in
    /// `AsyncStream`'s build closure, so no event can be in the backfill and also
    /// be yielded to this stream.
    package func backfillAndSubscribe(
        agentID: String,
        types: Set<KiteloopEvent.EventType>,
        limit: Int = 300
    ) -> (backfill: [KiteloopEvent], stream: AsyncStream<KiteloopEvent>) {
        let backfill = recentEvents(limit: limit)
        let stream = subscribe(agentID: agentID, types: types)
        return (backfill, stream)
    }

    package func replayUndelivered(for agentID: String) -> [KiteloopEvent] {
        guard let sub = subscriptions[agentID] else { return [] }
        return events.filter { event in
            sub.types.contains(event.type) && !event.deliveredTo.contains(agentID)
        }
    }

    /// Clears `agentID`'s entry only when it is still the subscription that
    /// terminated. Finishing the old continuation in `subscribe` runs its
    /// termination handler, whose cleanup lands on this actor *after* the
    /// replacement has been stored — so an id-blind removal would drop the live
    /// subscription of an agent that had just re-subscribed, leaving it watching
    /// nothing.
    private func removeSubscription(_ agentID: String, id: UUID) {
        guard subscriptions[agentID]?.id == id else { return }
        subscriptions.removeValue(forKey: agentID)
    }

    /// Whether `agentID` currently holds a live subscription. Read by tests that
    /// check a departing agent left nothing behind on the bus.
    package func hasSubscription(agentID: String) -> Bool {
        subscriptions[agentID] != nil
    }

    /// Drops the oldest events once the in-memory window is full.
    private func trimToCap() {
        let overflow = events.count - maxInMemoryEvents
        guard overflow > 0 else { return }
        events.removeFirst(overflow)
    }

    private func persistEvent(_ event: KiteloopEvent) {
        guard let data = try? encoder.encode(event),
              let line = String(data: data, encoding: .utf8) else { return }

        // Through `AtomicFileWriter.append`, which starts a new line first when the
        // log doesn't end in one. A plain seek-to-end writes this event onto the
        // remnant of one a kill cut short, and the pair decodes as neither — so the
        // event published after the crash is missing from the activity log, which
        // is the only record of what the team did while nobody was watching.
        try? AtomicFileWriter.append(Data((line + "\n").utf8), to: eventsURL)
    }

    /// Applies the retention window to the log and returns at most the last
    /// `limit` events from what survives it.
    ///
    /// A line older than `retentionAge` is dropped from the file; everything else
    /// is written back **verbatim**, as the bytes that were read. Re-encoding the
    /// decoded events would be the same thing only for as long as the wire format
    /// never gains a field, and a compaction that quietly rewrites history in the
    /// reader's dialect is not a bound, it is a migration.
    ///
    /// A line the decoder refuses is kept, in place, for the reason
    /// `RunRecordStore.rewrite()` keeps its own: compaction is the one thing that
    /// could erase it, on the very launch that failed to read it. Unreadable is
    /// not the same as expired — it has no timestamp to judge, so it is not
    /// judged.
    ///
    /// The file is only written when something actually aged out, so an install
    /// whose whole log is inside the window is left byte-for-byte alone.
    private static func loadEvents(
        from url: URL,
        decoder: JSONDecoder,
        limit: Int,
        now: Date
    ) -> [KiteloopEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        let cutoff = now.addingTimeInterval(-retentionAge)
        // Line by line on the byte: a line cut mid-character is not UTF-8, and must
        // not cost every event around it — nor the compaction below.
        let lines = data.split(separator: UInt8(ascii: "\n"))
        var keptLines: [Data] = []
        var events: [KiteloopEvent] = []
        var expired = 0
        for line in lines {
            guard let event = try? decoder.decode(KiteloopEvent.self, from: Data(line)) else {
                keptLines.append(Data(line))
                continue
            }
            guard event.timestamp >= cutoff else {
                expired += 1
                continue
            }
            keptLines.append(Data(line))
            events.append(event)
        }

        if expired > 0 {
            let body = keptLines.reduce(into: Data()) { $0.append($1); $0.append(UInt8(ascii: "\n")) }
            do {
                // Through `AtomicFileWriter`, the durable writer the other
                // compacting logs here use: `Data.write(options: .atomic)` renames
                // a temp file into place without flushing it, so a panic can leave
                // a zero-length event log where a month of history was.
                try AtomicFileWriter.write(body, to: url)
                eventBusLog.info("Dropped \(expired, privacy: .public) event(s) past the retention window from the event log")
            } catch {
                // The log is still the one that was read — nothing was lost, the
                // bound just isn't applied this time.
                eventBusLog.error("Could not compact the event log: \(error.localizedDescription, privacy: .public)")
            }
        }
        return Array(events.suffix(limit))
    }
}
