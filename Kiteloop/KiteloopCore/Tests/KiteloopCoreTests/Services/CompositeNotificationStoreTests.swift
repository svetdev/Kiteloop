import XCTest
@testable import KiteloopCore

final class CompositeNotificationStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "composite-notification-store")
    }

    private func makeStore(_ name: String) -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "\(name).log"))
    }

    func testPendingCountIsZeroWithNoStores() async {
        let composite = CompositeNotificationStore(stores: [])
        let count = await composite.pendingCount()
        XCTAssertEqual(count, 0)
    }

    func testPendingCountIsZeroWhenAllStoresEmpty() async {
        let composite = CompositeNotificationStore(stores: [makeStore("a"), makeStore("b")])
        let count = await composite.pendingCount()
        XCTAssertEqual(count, 0)
    }

    func testPendingCountSumsAcrossStores() async {
        let projectStore = makeStore("project")
        let homeStore = makeStore("home")

        await projectStore.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        await projectStore.add(NotificationItem(agentID: "coder", type: .error, title: "B", body: ""))
        await homeStore.add(NotificationItem(agentID: "manager", type: .approval, title: "C", body: ""))

        let composite = CompositeNotificationStore(stores: [projectStore, homeStore])

        let count = await composite.pendingCount()
        XCTAssertEqual(count, 3)
    }

    func testPendingCountMatchesMergedPendingList() async {
        let first = makeStore("first")
        let second = makeStore("second")
        await first.add(NotificationItem(agentID: "coder", type: .question, title: "A", body: ""))
        await second.add(NotificationItem(agentID: "reviewer", type: .approval, title: "B", body: ""))
        await second.add(NotificationItem(agentID: "reviewer", type: .event, title: "C", body: ""))

        let composite = CompositeNotificationStore(stores: [first, second])

        let count = await composite.pendingCount()
        let pending = await composite.pending()
        XCTAssertEqual(count, pending.count)
        XCTAssertEqual(count, 3)
    }

    func testPendingCountDropsResolvedItemFromOwningStore() async {
        let first = makeStore("first")
        let second = makeStore("second")
        let owned = NotificationItem(agentID: "reviewer", type: .approval, title: "Approve PR", body: "PR #42")
        await first.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        await second.add(owned)

        let composite = CompositeNotificationStore(stores: [first, second])
        let before = await composite.pendingCount()
        XCTAssertEqual(before, 2)

        await composite.markResolved(id: owned.id)

        let after = await composite.pendingCount()
        let firstCount = await first.pendingCount()
        let secondCount = await second.pendingCount()
        XCTAssertEqual(after, 1)
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0)
    }

    func testPendingCountDropsDismissedItemFromOwningStore() async {
        let first = makeStore("first")
        let second = makeStore("second")
        let owned = NotificationItem(agentID: "coder", type: .event, title: "Noise", body: "")
        await first.add(owned)
        await second.add(NotificationItem(agentID: "manager", type: .question, title: "B", body: ""))

        let composite = CompositeNotificationStore(stores: [first, second])
        let before = await composite.pendingCount()
        XCTAssertEqual(before, 2)

        await composite.dismiss(id: owned.id)

        let after = await composite.pendingCount()
        let firstCount = await first.pendingCount()
        let secondCount = await second.pendingCount()
        XCTAssertEqual(after, 1)
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(secondCount, 1)
    }

    func testPendingCountReflectsItemsAddedThroughComposite() async {
        let first = makeStore("first")
        let second = makeStore("second")
        let composite = CompositeNotificationStore(stores: [first, second])

        await composite.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        await composite.add(NotificationItem(agentID: "coder", type: .complete, title: "B", body: ""))

        let count = await composite.pendingCount()
        let firstCount = await first.pendingCount()
        let secondCount = await second.pendingCount()
        XCTAssertEqual(count, 2)
        // add() only writes to the first store — the merged count still sees both.
        XCTAssertEqual(firstCount, 2)
        XCTAssertEqual(secondCount, 0)
    }

    func testPendingCountIgnoresResolvedItemsInEveryStore() async {
        let first = makeStore("first")
        let second = makeStore("second")
        let firstItem = NotificationItem(agentID: "coder", type: .complete, title: "A", body: "")
        let secondItem = NotificationItem(agentID: "reviewer", type: .approval, title: "B", body: "")
        await first.add(firstItem)
        await first.add(NotificationItem(agentID: "coder", type: .error, title: "C", body: ""))
        await second.add(secondItem)

        await first.markResolved(id: firstItem.id)
        await second.markResolved(id: secondItem.id)

        let composite = CompositeNotificationStore(stores: [first, second])

        let count = await composite.pendingCount()
        let resolved = await composite.resolved()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(resolved.count, 2)
    }

    func testActionablePendingCountIsZeroWithNoStores() async {
        let composite = CompositeNotificationStore(stores: [])
        let count = await composite.actionablePendingCount()
        XCTAssertEqual(count, 0)
    }

    func testActionablePendingCountSumsAcrossStoresIgnoringAmbient() async {
        let projectStore = makeStore("project")
        let homeStore = makeStore("home")

        await projectStore.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        await projectStore.add(NotificationItem(agentID: "coder", type: .event, title: "B", body: ""))
        await projectStore.add(NotificationItem(agentID: "coder", type: .question, title: "C", body: ""))
        await homeStore.add(NotificationItem(agentID: "manager", type: .approval, title: "D", body: ""))
        await homeStore.add(NotificationItem(agentID: "manager", type: .complete, title: "E", body: ""))

        let composite = CompositeNotificationStore(stores: [projectStore, homeStore])

        let actionable = await composite.actionablePendingCount()
        let pending = await composite.pendingCount()
        XCTAssertEqual(actionable, 2)
        XCTAssertEqual(pending, 5)
    }

    func testDismissAllPendingAmbientClearsEveryStore() async {
        let first = makeStore("first")
        let second = makeStore("second")
        await first.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        await second.add(NotificationItem(agentID: "reviewer", type: .event, title: "B", body: ""))
        await second.add(NotificationItem(agentID: "reviewer", type: .question, title: "C", body: ""))

        let composite = CompositeNotificationStore(stores: [first, second])
        await composite.dismissAllPending(actionable: false)

        let pending = await composite.pending()
        let firstCount = await first.pendingCount()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "C")
        XCTAssertEqual(firstCount, 0)
    }

    // MARK: - Resolving a gate, and the backfill, across every store

    /// The window's bell reads a composite, and the item whose gate closed can be
    /// in either half of it — the project's inbox or the home workspace's.
    func testResolvingAGateReachesEveryStore() async {
        let projectStore = makeStore("project")
        let homeStore = makeStore("home")
        await projectStore.add(NotificationItem(agentID: "worker", type: .approval, title: "A",
                                               body: "", itemID: "task-1"))
        await homeStore.add(NotificationItem(agentID: "manager", type: .approval, title: "B",
                                             body: "", itemID: "task-1"))

        let composite = CompositeNotificationStore(stores: [projectStore, homeStore])
        let count = await composite.resolveApprovals(itemID: "task-1", closure: .autoApproved)

        XCTAssertEqual(count, 2)
        let pending = await composite.pending()
        XCTAssertTrue(pending.isEmpty)
        let resolved = await composite.resolved()
        XCTAssertEqual(Set(resolved.map(\.resolution)), ["auto-approved"])
    }

    /// The same for an answered question: the agent that asked it may have
    /// filed the notice in either half of the composite.
    func testAnsweringAQuestionReachesEveryStore() async {
        let projectStore = makeStore("project")
        let homeStore = makeStore("home")
        await projectStore.add(NotificationItem(agentID: "ada", type: .question, title: "A", body: ""))
        await homeStore.add(NotificationItem(agentID: "ada", type: .question, title: "B", body: ""))
        await homeStore.add(NotificationItem(agentID: "bob", type: .question, title: "C", body: ""))

        let composite = CompositeNotificationStore(stores: [projectStore, homeStore])
        let count = await composite.resolveQuestions(agentID: "ada", closure: .answered)

        XCTAssertEqual(count, 2)
        let pending = await composite.pending()
        XCTAssertEqual(pending.map(\.title), ["C"])
        let resolved = await composite.resolved()
        XCTAssertEqual(Set(resolved.map(\.resolution)), ["answered"])
    }

    /// And so does the sweep on load, counting what every store cleared.
    func testTheBackfillSweepsEveryStoreAndSumsWhatItCleared() async {
        let first = makeStore("first")
        let second = makeStore("second")
        await first.add(NotificationItem(agentID: "w", type: .approval, title: "gone",
                                         body: "", itemID: "task-1"))
        await second.add(NotificationItem(agentID: "w", type: .approval, title: "gone too",
                                          body: "", itemID: "task-2"))
        await second.add(NotificationItem(agentID: "w", type: .approval, title: "still at the gate",
                                          body: "", itemID: "task-3"))

        let composite = CompositeNotificationStore(stores: [first, second])
        let count = await composite.backfillPassedNotices(itemsAtGate: ["task-3"])

        XCTAssertEqual(count, 2)
        let pending = await composite.pending()
        XCTAssertEqual(pending.map(\.title), ["still at the gate"])
    }
}
