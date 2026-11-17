import Foundation

/// What `GET /v1/events` streams: every notice any open project files in its
/// inbox, numbered in one sequence across all of them, so a monitor follows one
/// stream instead of polling each project.
///
/// Held in memory only and bounded — the oldest event drops once `capacity` is
/// reached — so a client resuming from a point older than the buffer gets what
/// is still held, and nothing survives a restart.
package actor AppEventFeed {
    package struct Event: Sendable, Equatable {
        package let seq: Int
        package let project: String?
        package let kind: String
        package let subject: String
        package let title: String
        package let time: Date

        /// The event as the one compact JSON line a `data:` frame carries.
        package var json: String {
            let object: [String: Any] = [
                "id": seq,
                "project": project as Any? ?? NSNull(),
                "kind": kind,
                "subject": subject,
                "title": title,
                "time": ISO8601DateFormatter().string(from: time)
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The feed every open project's inbox publishes to.
    package static let shared = AppEventFeed()

    package let capacity: Int
    private var buffer: [Event] = []
    private var lastSeq = 0
    private var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]

    /// How many events the feed holds for a client that reconnects.
    package static let defaultCapacity = 1000

    package init(capacity: Int = AppEventFeed.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Numbers `notice` as the next event, buffers it and hands it to every
    /// subscriber. `fallbackProject` names the project when the notice itself
    /// does not.
    @discardableResult
    package func publish(_ notice: NotificationItem, fallbackProject: String? = nil) -> Event {
        lastSeq += 1
        let event = Event(seq: lastSeq,
                          project: notice.projectPath ?? fallbackProject,
                          kind: notice.type.rawValue,
                          subject: notice.itemID ?? notice.agentID,
                          title: notice.title,
                          time: notice.timestamp)
        buffer.append(event)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        for continuation in subscribers.values { continuation.yield(event) }
        return event
    }

    /// The buffered events numbered after `after`, oldest first; every buffered
    /// event when `after` is nil.
    package func events(after: Int?) -> [Event] {
        guard let after else { return buffer }
        return buffer.filter { $0.seq > after }
    }

    /// The events after `after` already buffered, and a stream of every event
    /// published from now on — taken together, so nothing published between
    /// the two is lost or sent twice. A nil `after` means live events only.
    /// The subscription ends when the stream's consumer goes away.
    package func subscribe(after: Int?) -> (backlog: [Event], live: AsyncStream<Event>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(capacity))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        subscribers[id] = continuation
        return (after.map { events(after: $0) } ?? [], stream)
    }

    /// How many streams are subscribed — so a test can see a hung-up client
    /// released its subscription.
    package var subscriberCount: Int { subscribers.count }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }
}
