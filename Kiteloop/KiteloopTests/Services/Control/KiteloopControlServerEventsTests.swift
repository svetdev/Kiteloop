import XCTest
import KiteloopCore
@testable import Kiteloop

/// `GET /v1/events`: every open project's inbox notices as one SSE stream, live
/// and resumable. Driven over a real loopback socket against a feed of the
/// test's own, so nothing another test files reaches it.
@MainActor
final class KiteloopControlServerEventsTests: XCTestCase {

    private var tempDir: URL!
    private var feed: AppEventFeed!
    private var harness: ControlServerHarness!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-app-events")
        feed = AppEventFeed()
        let feed = feed!
        harness = try await ControlServerHarness.start { token in
            KiteloopControlServer(registry: ControlSessionRegistry(), token: token, eventFeed: feed)
        }
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        feed = nil
    }

    /// A notice filed after the client connects reaches it, with its sequence
    /// number as the frame's `id:`.
    func testAConnectedClientReceivesANoticePublishedAfterwards() async throws {
        let store = NotificationStore(notificationsURL: tempDir.appending(path: "notifications.log"),
                                      feed: feed, feedProject: "/tmp/alpha")
        let stream = try await openStream("/v1/events")
        try await eventually("the stream to subscribe") { await self.feed.subscriberCount == 1 }

        await store.add(NotificationItem(agentID: "reviewer", type: .approval, title: "Approve it", body: "",
                                         itemID: "item-1"))

        let (id, event) = try await stream.next()
        stream.cancel()
        XCTAssertEqual(id, "1")
        XCTAssertEqual(event["id"] as? Int, 1)
        XCTAssertEqual(event["project"] as? String, "/tmp/alpha")
        XCTAssertEqual(event["kind"] as? String, "approval")
        XCTAssertEqual(event["subject"] as? String, "item-1")
        XCTAssertEqual(event["title"] as? String, "Approve it")
        XCTAssertNotNil(event["time"] as? String)
    }

    func testLastEventIDReplaysExactlyTheBufferedEventsAfterIt() async throws {
        try await publish(count: 4)

        let stream = try await openStream("/v1/events", lastEventID: "2")

        try await assertReplays(["3", "4"], from: stream)
    }

    func testAfterQueryReplaysExactlyTheBufferedEventsAfterIt() async throws {
        try await publish(count: 4)

        let stream = try await openStream("/v1/events?after=1")

        try await assertReplays(["2", "3", "4"], from: stream)
    }

    func testUnauthenticatedAccessIsRefused() async throws {
        let (status, _) = try await harness.get("/v1/events", bearer: nil)
        XCTAssertEqual(status, 401)
    }

    // MARK: - Helpers

    private func publish(count: Int) async throws {
        for n in 1...count {
            await feed.publish(NotificationItem(agentID: "agent-\(n)", type: .complete, title: "Done \(n)", body: ""))
        }
    }

    /// Reads the replayed frames, then publishes one more and expects it next:
    /// the backlog held exactly `ids`, and the stream went live after it.
    private func assertReplays(_ ids: [String], from stream: EventStream) async throws {
        var replayed: [String] = []
        for _ in ids { replayed.append(try await stream.next().id) }
        XCTAssertEqual(replayed, ids)
        try await eventually("the stream to subscribe") { await self.feed.subscriberCount == 1 }
        let live = await feed.publish(NotificationItem(agentID: "late", type: .event, title: "Later", body: ""))
        let (id, event) = try await stream.next()
        stream.cancel()
        XCTAssertEqual(id, String(live.seq))
        XCTAssertEqual(event["subject"] as? String, "late", "falls back to the agent with no item")
    }

    /// An open SSE connection, read one frame at a time as its `id:` and the
    /// object its `data:` line holds. Each read is bounded by the request's
    /// timeout, so a stream that never sends fails the test instead of hanging.
    @MainActor
    final class EventStream {
        private var lines: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator
        private let task: URLSessionDataTask

        init(bytes: URLSession.AsyncBytes) {
            lines = bytes.lines.makeAsyncIterator()
            task = bytes.task
        }

        func next() async throws -> (id: String?, event: [String: Any]) {
            var iterator = lines
            defer { lines = iterator }
            var id: String?
            while let line = try await iterator.next() {
                if line.hasPrefix("id: ") { id = String(line.dropFirst(4)); continue }
                guard line.hasPrefix("data: ") else { continue }
                let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8))
                if let object = object as? [String: Any] { return (id, object) }
            }
            throw URLError(.networkConnectionLost)
        }

        func cancel() { task.cancel() }
    }

    private func openStream(_ path: String, lastEventID: String? = nil) async throws -> EventStream {
        var request = URLRequest(url: harness.url(path))
        request.timeoutInterval = ControlServerHarness.defaultTimeout
        request.setValue("Bearer \(harness.token)", forHTTPHeaderField: "Authorization")
        if let lastEventID { request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        let (bytes, response) = try await harness.session.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return EventStream(bytes: bytes)
    }
}
