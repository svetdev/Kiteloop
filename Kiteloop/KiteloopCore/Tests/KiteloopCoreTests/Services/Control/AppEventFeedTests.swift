import XCTest
@testable import KiteloopCore

final class AppEventFeedTests: XCTestCase {

    private func notice(_ agent: String = "coder", type: NotificationItem.NotificationType = .complete,
                        title: String = "Done", itemID: String? = nil, project: String? = nil) -> NotificationItem {
        NotificationItem(agentID: agent, type: type, title: title, body: "body", itemID: itemID, projectPath: project)
    }

    func testSequenceNumbersOnlyGoUp() async {
        let feed = AppEventFeed()
        var seqs: [Int] = []
        for _ in 0..<3 { seqs.append(await feed.publish(notice()).seq) }
        XCTAssertEqual(seqs, [1, 2, 3])
    }

    func testEventsAfterAnswersOnlyTheLaterOnes() async {
        let feed = AppEventFeed()
        for n in 1...4 { await feed.publish(notice(title: "n\(n)")) }

        let after = await feed.events(after: 2)

        XCTAssertEqual(after.map(\.seq), [3, 4])
        XCTAssertEqual(after.map(\.title), ["n3", "n4"])
        let all = await feed.events(after: nil)
        XCTAssertEqual(all.map(\.seq), [1, 2, 3, 4])
    }

    func testTheOldestDropsOncePastCapacity() async {
        let feed = AppEventFeed(capacity: 3)
        for _ in 1...5 { await feed.publish(notice()) }

        let held = await feed.events(after: 0)

        XCTAssertEqual(held.map(\.seq), [3, 4, 5], "a resume point older than the buffer gets what is still held")
    }

    func testANoticeMapsOntoTheEventFields() async {
        let feed = AppEventFeed()
        let item = notice("reviewer", type: .approval, title: "Approve it", itemID: "item-1", project: "/p/alpha")

        let event = await feed.publish(item, fallbackProject: "/p/other")

        XCTAssertEqual(event, AppEventFeed.Event(seq: 1, project: "/p/alpha", kind: "approval",
                                                 subject: "item-1", title: "Approve it", time: item.timestamp))
    }

    func testSubjectFallsBackToTheAgentAndProjectToTheFallback() async {
        let feed = AppEventFeed()

        let event = await feed.publish(notice("asker", type: .question), fallbackProject: "/p/beta")

        XCTAssertEqual(event.subject, "asker")
        XCTAssertEqual(event.project, "/p/beta")
        XCTAssertEqual(event.kind, "question")
    }

    func testTheJSONLineCarriesEveryField() async throws {
        let feed = AppEventFeed()
        let event = await feed.publish(notice(type: .error, title: "Broke", itemID: "x", project: "/p"))

        XCTAssertFalse(event.json.contains("\n"), "one compact line")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.json.utf8)) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 1)
        XCTAssertEqual(object["project"] as? String, "/p")
        XCTAssertEqual(object["kind"] as? String, "error")
        XCTAssertEqual(object["subject"] as? String, "x")
        XCTAssertEqual(object["title"] as? String, "Broke")
        let time = try XCTUnwrap(object["time"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: time))
    }

    func testASubscriberGetsTheBacklogAfterItsPointThenLiveEvents() async {
        let feed = AppEventFeed()
        for _ in 1...3 { await feed.publish(notice()) }

        let (backlog, live) = await feed.subscribe(after: 1)
        await feed.publish(notice(title: "live"))

        XCTAssertEqual(backlog.map(\.seq), [2, 3])
        var iterator = live.makeAsyncIterator()
        let next = await iterator.next()
        XCTAssertEqual(next?.seq, 4)
        XCTAssertEqual(next?.title, "live")
    }

    func testASubscriberWithNoResumePointGetsLiveEventsOnly() async {
        let feed = AppEventFeed()
        await feed.publish(notice())

        let (backlog, _) = await feed.subscribe(after: nil)

        XCTAssertTrue(backlog.isEmpty)
    }

    @MainActor
    func testASubscriptionEndsWithItsStream() async throws {
        let feed = AppEventFeed()
        var subscription: (backlog: [AppEventFeed.Event], live: AsyncStream<AppEventFeed.Event>)? =
            await feed.subscribe(after: nil)
        let count = await feed.subscriberCount
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(subscription)

        subscription = nil

        try await eventually("the subscription to be released") { await feed.subscriberCount == 0 }
    }
}
