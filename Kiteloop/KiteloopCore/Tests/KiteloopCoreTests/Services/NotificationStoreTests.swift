import XCTest
@testable import KiteloopCore

final class NotificationStoreTests: XCTestCase {
    private var tempDir: URL!
    private var notificationsURL: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "notification-store")
        notificationsURL = tempDir.appending(path: "notifications.log")
    }

    override func tearDownWithError() throws {
        // A test that made the directory read-only restores it itself; this is the
        // belt-and-braces so a failure mid-test cannot leave it undeletable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: tempDir.path(percentEncoded: false))
    }

    func testAddAndQueryPending() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        let item = NotificationItem(agentID: "coder", type: .complete, title: "Task done", body: "Finished refactoring")
        await store.add(item)

        let pending = await store.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Task done")
    }

    func testMarkResolved() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        let item = NotificationItem(agentID: "coder", type: .approval, title: "Approve PR", body: "PR #42")
        await store.add(item)

        await store.markResolved(id: item.id)

        let pending = await store.pending()
        XCTAssertEqual(pending.count, 0)

        let resolved = await store.resolved()
        XCTAssertEqual(resolved.count, 1)
        XCTAssertNotNil(resolved.first?.resolvedAt)
    }

    func testPendingCount() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        await store.add(NotificationItem(agentID: "reviewer", type: .approval, title: "B", body: ""))
        await store.add(NotificationItem(agentID: "coder", type: .error, title: "C", body: ""))

        let count = await store.pendingCount()
        XCTAssertEqual(count, 3)

        await store.markResolved(id: (await store.pending()).first!.id)
        let count2 = await store.pendingCount()
        XCTAssertEqual(count2, 2)
    }

    func testPersistenceAcrossInstances() async {
        let store1 = NotificationStore(notificationsURL: notificationsURL)
        await store1.add(NotificationItem(agentID: "coder", type: .complete, title: "Done", body: "Finished"))
        await store1.add(NotificationItem(agentID: "reviewer", type: .approval, title: "Review", body: "PR"))

        let store2 = NotificationStore(notificationsURL: notificationsURL)
        let pending = await store2.pending()
        XCTAssertEqual(pending.count, 2)
    }

    func testDismiss() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        let item = NotificationItem(agentID: "coder", type: .complete, title: "Done", body: "")
        await store.add(item)

        await store.dismiss(id: item.id)

        let pending = await store.pending()
        XCTAssertEqual(pending.count, 0)
        let resolved = await store.resolved()
        XCTAssertEqual(resolved.count, 0)
    }

    func testActionablePendingCountIgnoresAmbientTypes() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        for index in 0..<200 {
            await store.add(NotificationItem(agentID: "coder", type: .complete, title: "Done \(index)", body: ""))
        }
        await store.add(NotificationItem(agentID: "coder", type: .event, title: "Event", body: ""))

        let ambientOnly = await store.actionablePendingCount()
        XCTAssertEqual(ambientOnly, 0, "A marathon run's completions must not badge the bell")

        await store.add(NotificationItem(agentID: "coder", type: .question, title: "Which branch?", body: ""))
        await store.add(NotificationItem(agentID: "reviewer", type: .approval, title: "Approve PR", body: ""))
        await store.add(NotificationItem(agentID: "coder", type: .error, title: "Build failed", body: ""))

        let actionable = await store.actionablePendingCount()
        let pending = await store.pendingCount()
        XCTAssertEqual(actionable, 3)
        XCTAssertEqual(pending, 204)
    }

    func testActionablePendingCountDropsResolvedItems() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        let question = NotificationItem(agentID: "coder", type: .question, title: "Which branch?", body: "")
        await store.add(question)
        await store.add(NotificationItem(agentID: "coder", type: .error, title: "Build failed", body: ""))

        await store.markResolved(id: question.id)

        let count = await store.actionablePendingCount()
        XCTAssertEqual(count, 1)
    }

    func testDismissAllPendingAmbientKeepsActionableItems() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        for index in 0..<50 {
            await store.add(NotificationItem(agentID: "coder", type: .complete, title: "Done \(index)", body: ""))
        }
        await store.add(NotificationItem(agentID: "coder", type: .event, title: "Event", body: ""))
        let question = NotificationItem(agentID: "coder", type: .question, title: "Which branch?", body: "")
        await store.add(question)

        await store.dismissAllPending(actionable: false)

        let pending = await store.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, question.id, "A blocked agent survives a bulk clear of the feed")
        // Dismissed rows are cleared away, not filed under Resolved.
        let resolved = await store.resolved()
        XCTAssertEqual(resolved.count, 0)
    }

    func testDismissAllPendingActionableLeavesAmbientFeedIntact() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "coder", type: .complete, title: "Done", body: ""))
        await store.add(NotificationItem(agentID: "coder", type: .question, title: "Which branch?", body: ""))
        await store.add(NotificationItem(agentID: "reviewer", type: .approval, title: "Approve PR", body: ""))

        await store.dismissAllPending(actionable: true)

        let actionable = await store.actionablePendingCount()
        let pending = await store.pending()
        XCTAssertEqual(actionable, 0)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .complete)
    }

    func testDismissAllPendingPersistsAcrossInstances() async {
        let store1 = NotificationStore(notificationsURL: notificationsURL)
        await store1.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        await store1.add(NotificationItem(agentID: "coder", type: .complete, title: "B", body: ""))
        await store1.add(NotificationItem(agentID: "coder", type: .question, title: "C", body: ""))

        await store1.dismissAllPending(actionable: false)

        let store2 = NotificationStore(notificationsURL: notificationsURL)
        let pending = await store2.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "C")
    }

    func testDismissAllPendingIgnoresAlreadyResolvedItems() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        let done = NotificationItem(agentID: "coder", type: .complete, title: "Done", body: "")
        await store.add(done)
        await store.markResolved(id: done.id)

        await store.dismissAllPending(actionable: false)

        let resolved = await store.resolved()
        XCTAssertEqual(resolved.count, 1, "A bulk clear of pending rows must not wipe resolved history")
    }

    /// And the item added *after* the crash keeps its own line. Appending
    /// straight onto the remnant would glue the two into something that decodes
    /// as neither — and a pending actionable notification is the whole mechanism
    /// by which a human learns a run is waiting on them.
    func testAnItemAddedAfterATruncatedLineIsReadBackOnTheNextLoad() async throws {
        let store1 = NotificationStore(notificationsURL: notificationsURL)
        await store1.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        // The shape a kill mid-append leaves: half an item, no newline after it.
        try appendRaw("{\"agentID\":\"cut\",\"tit", to: notificationsURL)

        await NotificationStore(notificationsURL: notificationsURL)
            .add(NotificationItem(agentID: "reviewer", type: .approval, title: "Approve", body: ""))

        let pending = await NotificationStore(notificationsURL: notificationsURL).pending()
        XCTAssertEqual(Set(pending.map(\.title)), ["A", "Approve"],
                       "the notification added after the crash survives")
        let content = try String(contentsOf: notificationsURL, encoding: .utf8)
        XCTAssertTrue(content.contains("{\"agentID\":\"cut\",\"tit\n"),
                      "the remnant is still there, on its own line, and still skipped by the loader")
    }

    /// The ordinary append is unchanged by the repair: a file already ending in
    /// a newline gains one line, not a blank one before it.
    func testAddingToAFileEndingInANewlineAddsNoBlankLine() async throws {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        await store.add(NotificationItem(agentID: "reviewer", type: .approval, title: "B", body: ""))

        let content = try String(contentsOf: notificationsURL, encoding: .utf8)
        XCTAssertFalse(content.contains("\n\n"), "no blank line between the items")
        let reloaded = await NotificationStore(notificationsURL: notificationsURL).pending()
        XCTAssertEqual(reloaded.count, 2)
    }

    /// The file the first notification of a fresh install lands in doesn't exist yet.
    func testAddingToAFileThatDoesNotExistYetWritesOneTerminatedLine() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: notificationsURL.path(percentEncoded: false)))

        await NotificationStore(notificationsURL: notificationsURL)
            .add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))

        let content = try String(contentsOf: notificationsURL, encoding: .utf8)
        XCTAssertTrue(content.hasSuffix("\n"), "the line is newline-terminated")
        XCTAssertEqual(content.components(separatedBy: .newlines).filter { !$0.isEmpty }.count, 1)
        let reloaded = await NotificationStore(notificationsURL: notificationsURL).pending()
        XCTAssertEqual(reloaded.count, 1)
    }

    // MARK: - What a rewrite has to survive

    /// Resolving, dismissing and bulk-clearing all replace the whole file, and the
    /// file may hold a line the decoder refused — the half-written remnant of a
    /// kill mid-append. Writing back only what decoded is what used to delete it,
    /// on the first dismissal after the crash, and that line can be the approval a
    /// human still owes an answer to.
    func testARewriteKeepsTheLineTheDecoderRefused() async throws {
        let store1 = NotificationStore(notificationsURL: notificationsURL)
        let done = NotificationItem(agentID: "coder", type: .complete, title: "A", body: "")
        let approval = NotificationItem(agentID: "reviewer", type: .approval, title: "Approve", body: "")
        await store1.add(done)
        await store1.add(approval)
        try appendRaw(truncatedLine + "\n", to: notificationsURL)

        let store = NotificationStore(notificationsURL: notificationsURL)
        let count = await store.undecodableLineCount
        XCTAssertEqual(count, 1, "the store says how many lines it could not read")

        await store.markResolved(id: done.id)
        try assertFileHoldsTruncatedLine(after: "markResolved")
        await store.dismiss(id: approval.id)
        try assertFileHoldsTruncatedLine(after: "dismiss")

        // And a bulk clear, from a fresh store with something pending to clear.
        let store2 = NotificationStore(notificationsURL: notificationsURL)
        await store2.add(NotificationItem(agentID: "coder", type: .complete, title: "B", body: ""))
        await store2.dismissAllPending(actionable: false)
        try assertFileHoldsTruncatedLine(after: "dismissAllPending")

        let reloaded = NotificationStore(notificationsURL: notificationsURL)
        let stillUnreadable = await reloaded.undecodableLineCount
        XCTAssertEqual(stillUnreadable, 1, "and it is still the only line nobody can read")
        let resolved = await reloaded.resolved()
        XCTAssertEqual(resolved.map(\.title), ["A"], "the items around it are unchanged")
    }

    /// The half of durability a test can stage: a rewrite that cannot be written
    /// at all must leave the previous file alone. An empty file here is every
    /// pending approval gone.
    func testARewriteThatCannotBeWrittenLeavesThePreviousFileInPlace() async throws {
        let store = NotificationStore(notificationsURL: notificationsURL)
        let item = NotificationItem(agentID: "reviewer", type: .approval, title: "Approve", body: "")
        await store.add(item)
        await store.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        let before = try String(contentsOf: notificationsURL, encoding: .utf8)
        XCTAssertFalse(before.isEmpty)
        try setDirectoryWritable(false)
        defer { try? setDirectoryWritable(true) }

        await store.dismiss(id: item.id)

        XCTAssertEqual(try String(contentsOf: notificationsURL, encoding: .utf8), before,
                       "the notifications that were on disk are still on disk")
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: tempDir.path(percentEncoded: false)).sorted(),
                       ["notifications.log"], "and no half-written draft beside it")
    }

    // MARK: - A line that is not even text

    /// One truncated multi-byte character used to cost the whole inbox: the file
    /// was decoded as a single string, that decode failed, and the store came up
    /// empty with nothing held. Every notice around the bad byte is read now.
    func testALineOfBytesThatAreNotUTF8CostsNoNoticeAroundIt() async throws {
        let store1 = NotificationStore(notificationsURL: notificationsURL)
        await store1.add(NotificationItem(agentID: "coder", type: .complete, title: "A", body: ""))
        await store1.add(NotificationItem(agentID: "reviewer", type: .approval, title: "Approve", body: ""))
        try appendRaw(bytes: halfAnEmDashLine, to: notificationsURL)
        await NotificationStore(notificationsURL: notificationsURL)
            .add(NotificationItem(agentID: "coder", type: .question, title: "Which branch?", body: ""))

        let store = NotificationStore(notificationsURL: notificationsURL)

        let pending = await store.pending()
        XCTAssertEqual(Set(pending.map(\.title)), ["A", "Approve", "Which branch?"],
                       "the notices before and after the bad byte are all read")
        let count = await store.pendingCount()
        XCTAssertEqual(count, 3)
        let unreadable = await store.undecodableLineCount
        XCTAssertEqual(unreadable, 1, "and the line nobody could read is counted, not silently zero")
    }

    /// The erasure that followed the empty read: holding nothing meant the next
    /// rewrite wrote out only what this launch had added. The bad line is held —
    /// lossily, as replacement characters — so a rewrite puts it back.
    func testARewriteKeepsTheLineWhoseBytesAreNotUTF8() async throws {
        let store1 = NotificationStore(notificationsURL: notificationsURL)
        let done = NotificationItem(agentID: "coder", type: .complete, title: "A", body: "")
        await store1.add(done)
        await store1.add(NotificationItem(agentID: "reviewer", type: .approval, title: "Approve", body: ""))
        try appendRaw(bytes: halfAnEmDashLine, to: notificationsURL)

        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.markResolved(id: done.id)

        let reloaded = NotificationStore(notificationsURL: notificationsURL)
        let pending = await reloaded.pending()
        let resolved = await reloaded.resolved()
        XCTAssertEqual(Set((pending + resolved).map(\.title)), ["A", "Approve"],
                       "every notice that was there is still there")
        let stillUnreadable = await reloaded.undecodableLineCount
        XCTAssertEqual(stillUnreadable, 1, "and the held line was written back, not dropped")
        let content = try String(contentsOf: notificationsURL, encoding: .utf8)
        XCTAssertTrue(content.contains(readablePrefixOfTheEmDashLine),
                      "what could be read of it reads the same; the bad bytes came back as U+FFFD")
    }

    /// The one that costs somebody an answer: an approval filed before the bad
    /// byte, and an ordinary add-and-resolve after it. The rewrite that resolve
    /// triggers is exactly what used to delete the approval.
    func testAPendingApprovalBeforeABadByteSurvivesAnAddResolveAndReload() async throws {
        let store1 = NotificationStore(notificationsURL: notificationsURL)
        let approval = NotificationItem(agentID: "reviewer", type: .approval, title: "Approve",
                                        body: "", itemID: "task-1")
        await store1.add(approval)
        try appendRaw(bytes: halfAnEmDashLine, to: notificationsURL)

        let store2 = NotificationStore(notificationsURL: notificationsURL)
        let done = NotificationItem(agentID: "coder", type: .complete, title: "Done", body: "")
        await store2.add(done)
        await store2.markResolved(id: done.id)

        let pending = await NotificationStore(notificationsURL: notificationsURL).pending()
        XCTAssertEqual(pending.map(\.id), [approval.id],
                       "the approval a human owes an answer to is still waiting on them")
    }

    /// A fresh install reads no file at all, and that is an empty inbox rather
    /// than an unreadable one.
    func testAnAbsentFileLoadsAsAnEmptyInbox() async {
        XCTAssertFalse(FileManager.default.fileExists(atPath: notificationsURL.path(percentEncoded: false)))

        let store = NotificationStore(notificationsURL: notificationsURL)

        let pending = await store.pending()
        XCTAssertTrue(pending.isEmpty)
        let count = await store.pendingCount()
        XCTAssertEqual(count, 0)
        let unreadable = await store.undecodableLineCount
        XCTAssertEqual(unreadable, 0, "nothing was unreadable — there was nothing")
    }

    // MARK: - An approval notice is a view of its gate

    /// The whole point: the row closes when the gate closes, and says who closed
    /// it. Before this only a click resolved one, so a gate cleared over the API
    /// or by auto-approve left its summons standing for good.
    func testResolvingAnItemsGateResolvesItsApprovalNoticeAndSaysHow() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "worker", type: .approval,
                                         title: "Approval needed", body: "task-1", itemID: "task-1"))

        let count = await store.resolveApprovals(itemID: "task-1", closure: .approvedViaAPI)

        XCTAssertEqual(count, 1)
        let pending = await store.pending()
        XCTAssertTrue(pending.isEmpty, "the gate closed, so nothing is waiting on a human")
        let resolved = await store.resolved()
        XCTAssertEqual(resolved.first?.resolution, "approved via API")
        XCTAssertNotNil(resolved.first?.resolvedAt)
    }

    /// One item's gate is not another's, and a notice of a different kind about
    /// the same item is not the gate at all.
    func testResolvingOneItemsGateLeavesOtherNoticesPending() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "w", type: .approval, title: "A",
                                         body: "", itemID: "task-1"))
        await store.add(NotificationItem(agentID: "w", type: .approval, title: "B",
                                         body: "", itemID: "task-2"))
        await store.add(NotificationItem(agentID: "w", type: .question, title: "C",
                                         body: "", itemID: "task-1"))

        let count = await store.resolveApprovals(itemID: "task-1", closure: .approved)

        XCTAssertEqual(count, 1)
        let titles = Set((await store.pending()).map(\.title))
        XCTAssertEqual(titles, ["B", "C"])
    }

    /// A row a person already dealt with is settled history. Re-resolving it
    /// would restamp a reason over what they actually did.
    func testResolvingAGateDoesNotRestampANoticeAlreadySettled() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        let notice = NotificationItem(agentID: "w", type: .approval, title: "A",
                                      body: "", itemID: "task-1")
        await store.add(notice)
        await store.markResolved(id: notice.id)

        let count = await store.resolveApprovals(itemID: "task-1", closure: .autoApproved)

        XCTAssertEqual(count, 0)
        let resolved = await store.resolved()
        XCTAssertNil(resolved.first?.resolution, "a click leaves no reason — the person knows")
    }

    /// The resolution survives the file, since the launch that reads it back is
    /// exactly the one that has to explain a row nobody remembers clearing.
    func testTheResolutionSurvivesAReload() async {
        let first = NotificationStore(notificationsURL: notificationsURL)
        await first.add(NotificationItem(agentID: "w", type: .approval, title: "A",
                                         body: "", itemID: "task-1"))
        await first.resolveApprovals(itemID: "task-1", closure: .rejected)

        let second = NotificationStore(notificationsURL: notificationsURL)
        let resolved = await second.resolved()
        XCTAssertEqual(resolved.first?.resolution, "rejected")
    }

    /// The other gate a person stands at: answering an agent's question in the
    /// chat closes the notice it filed, rather than leaving an actionable row
    /// about an answer already given.
    func testAnsweringAnAgentsQuestionResolvesItsNoticeAndSaysHow() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "ada", type: .question,
                                         title: "Ada needs input", body: "Which port?"))

        let count = await store.resolveQuestions(agentID: "ada", closure: .answered)

        XCTAssertEqual(count, 1)
        let pending = await store.pending()
        XCTAssertTrue(pending.isEmpty, "the question was answered, so nothing is waiting")
        let resolved = await store.resolved()
        XCTAssertEqual(resolved.first?.resolution, "answered")
        XCTAssertNotNil(resolved.first?.resolvedAt)
    }

    /// One agent's question is not another's, and a notice of a different kind
    /// from the same agent is not the question at all.
    func testAnsweringOneAgentLeavesAnotherAgentsQuestionPending() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "ada", type: .question, title: "A", body: ""))
        await store.add(NotificationItem(agentID: "bob", type: .question, title: "B", body: ""))
        await store.add(NotificationItem(agentID: "ada", type: .approval, title: "C",
                                         body: "", itemID: "task-1"))

        let count = await store.resolveQuestions(agentID: "ada", closure: .answered)

        XCTAssertEqual(count, 1)
        let titles = Set((await store.pending()).map(\.title))
        XCTAssertEqual(titles, ["B", "C"])
    }

    // MARK: - Roll-up

    /// An autopilot run finishes a turn every few minutes and each one used to
    /// land its own row — 648 in one project by 2026-08-15. They are readings of
    /// one thing, so the newest replaces the one before it.
    func testANoticeWithARollUpKeyReplacesThePendingOneHoldingThatKey() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        let key = NotificationItem.runFinishedRollUpKey(projectID: "proj")

        for title in ["first", "second", "third"] {
            await store.add(NotificationItem(agentID: "", type: .complete, title: title,
                                             body: "", rollUpKey: key))
        }

        let pending = await store.pending()
        XCTAssertEqual(pending.map(\.title), ["third"], "one live row per project")
        let resolved = await store.resolved()
        XCTAssertEqual(Set(resolved.map(\.title)), ["first", "second"])
        XCTAssertEqual(Set(resolved.map(\.resolution)), ["replaced by a newer notice"])
    }

    /// Two projects are two states. One project's run finishing says nothing
    /// about the other's.
    func testRollUpIsPerKeySoOneProjectDoesNotClearAnother() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "", type: .complete, title: "alpha", body: "",
                                         rollUpKey: NotificationItem.runFinishedRollUpKey(projectID: "a")))
        await store.add(NotificationItem(agentID: "", type: .complete, title: "beta", body: "",
                                         rollUpKey: NotificationItem.runFinishedRollUpKey(projectID: "b")))

        let titles = Set((await store.pending()).map(\.title))
        XCTAssertEqual(titles, ["alpha", "beta"])
    }

    /// A person asked an agent something and the agent answered: each answer is
    /// its own row, and carries no key. Today's behaviour, unchanged.
    func testANoticeWithNoRollUpKeyStacks() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "coder", type: .complete, title: "first", body: ""))
        await store.add(NotificationItem(agentID: "coder", type: .complete, title: "second", body: ""))

        let pending = await store.pending()
        XCTAssertEqual(pending.count, 2)
    }

    // MARK: - The backfill on load

    /// The 2,000 standing rows: an item merged days ago still summoning somebody.
    /// The sweep judges each row against the items actually at the gate.
    func testTheBackfillResolvesApprovalsWhoseItemHasLeftTheGate() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "w", type: .approval, title: "merged",
                                         body: "", itemID: "task-1"))
        await store.add(NotificationItem(agentID: "w", type: .approval, title: "still waiting",
                                         body: "", itemID: "task-2"))

        let count = await store.backfillPassedNotices(itemsAtGate: ["task-2"])

        XCTAssertEqual(count, 1)
        let stillPending = await store.pending()
        XCTAssertEqual(stillPending.map(\.title), ["still waiting"])
        let resolved = await store.resolved()
        XCTAssertEqual(resolved.first?.resolution, "the item is no longer at the approval gate")
    }

    /// A rolled-up row reports a run in flight, and no run survives a launch —
    /// so every one of them found on load is about a run that has ended.
    func testTheBackfillResolvesRolledUpNoticesFromAnEarlierLaunch() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "", type: .complete, title: "Agents finished",
                                         body: "",
                                         rollUpKey: NotificationItem.runFinishedRollUpKey(projectID: "p")))

        let count = await store.backfillPassedNotices(itemsAtGate: [])

        XCTAssertEqual(count, 1)
        let pending = await store.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    /// What the sweep must not touch: a question an agent is still blocked on, a
    /// store failure nobody has fixed, and an approval naming no item — nothing
    /// here can judge that last one, so it is left for a person.
    func testTheBackfillLeavesEverythingItCannotJudgeAlone() async {
        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.add(NotificationItem(agentID: "coder", type: .question, title: "Which one?", body: ""))
        await store.add(NotificationItem(agentID: "", type: .error, title: "Could not write Settings", body: ""))
        await store.add(NotificationItem(agentID: "w", type: .approval, title: "no item named", body: ""))

        let count = await store.backfillPassedNotices(itemsAtGate: [])

        XCTAssertEqual(count, 0)
        let pending = await store.pending()
        XCTAssertEqual(pending.count, 3)
    }

    /// The sweep rewrites the file, so the launch after it starts clean rather
    /// than sweeping the same 2,000 rows again.
    func testTheBackfillSurvivesAReload() async {
        let first = NotificationStore(notificationsURL: notificationsURL)
        await first.add(NotificationItem(agentID: "w", type: .approval, title: "merged",
                                         body: "", itemID: "task-1"))
        await first.backfillPassedNotices(itemsAtGate: [])

        let second = NotificationStore(notificationsURL: notificationsURL)
        let swept = await second.backfillPassedNotices(itemsAtGate: [])
        XCTAssertEqual(swept, 0, "nothing left to sweep")
        let resolved = await second.resolved()
        XCTAssertEqual(resolved.first?.resolution, "the item is no longer at the approval gate")
    }

    // MARK: - The week's sweep at load

    /// The one that cost somebody their history: an approval gate that sat open
    /// for eight days and was answered this morning. Judged by when it arrived,
    /// it is gone at the next launch — and the notices that waited longest for an
    /// answer are exactly the ones worth finding under Resolved.
    func testANoticeResolvedTodaySurvivesEvenThoughItArrivedTenDaysAgo() async throws {
        try writeNotifications([
            notificationLine(id: "long-wait", title: "Approve", status: "resolved",
                             createdDaysAgo: 10, resolvedDaysAgo: 0)
        ])

        let store = NotificationStore(notificationsURL: notificationsURL)

        let resolved = await store.resolved()
        XCTAssertEqual(resolved.map(\.title), ["Approve"],
                       "the week runs from when it settled, not from when it arrived")
    }

    /// And the sweep still does its job: a week after it settled, it goes.
    func testANoticeCreatedAndResolvedTenDaysAgoIsStillDropped() async throws {
        try writeNotifications([
            notificationLine(id: "old", title: "Approve", status: "resolved",
                             createdDaysAgo: 10, resolvedDaysAgo: 10)
        ])

        let store = NotificationStore(notificationsURL: notificationsURL)

        let resolved = await store.resolved()
        XCTAssertTrue(resolved.isEmpty, "settled a week ago, so it is swept")
    }

    /// Unchanged from today: a pending notice is kept at any age — it still
    /// needs a human.
    func testAPendingNoticeTenDaysOldIsKept() async throws {
        try writeNotifications([
            notificationLine(id: "waiting", title: "Which branch?", status: "pending",
                             createdDaysAgo: 10)
        ])

        let store = NotificationStore(notificationsURL: notificationsURL)

        let pending = await store.pending()
        XCTAssertEqual(pending.map(\.title), ["Which branch?"])
    }

    /// A dismissed row is in neither list, so what it survived is read by
    /// resolving it: `markResolved` finds an id the sweep kept and nothing at all
    /// of one it dropped.
    func testADismissedNoticeIsJudgedByWhenItWasDismissed() async throws {
        try writeNotifications([
            notificationLine(id: "cleared-today", title: "recent", status: "dismissed",
                             createdDaysAgo: 10, resolvedDaysAgo: 1),
            notificationLine(id: "cleared-long-ago", title: "stale", status: "dismissed",
                             createdDaysAgo: 10, resolvedDaysAgo: 10)
        ])

        let store = NotificationStore(notificationsURL: notificationsURL)
        await store.markResolved(id: "cleared-today")
        await store.markResolved(id: "cleared-long-ago")

        let resolved = await store.resolved()
        XCTAssertEqual(resolved.map(\.title), ["recent"],
                       "the one dismissed yesterday is still on file; the one dismissed ten days ago is gone")
    }

    /// A line written before `resolvedAt` was recorded has none, and loses
    /// nothing it would not have lost before: its `timestamp` still judges it.
    func testANonPendingNoticeWithNoResolvedAtIsJudgedByItsTimestamp() async throws {
        try writeNotifications([
            notificationLine(id: "legacy-old", title: "old", status: "resolved", createdDaysAgo: 10),
            notificationLine(id: "legacy-recent", title: "recent", status: "resolved", createdDaysAgo: 1)
        ])

        let store = NotificationStore(notificationsURL: notificationsURL)

        let resolved = await store.resolved()
        XCTAssertEqual(resolved.map(\.title), ["recent"])
    }

    // MARK: - Helpers

    /// Half a JSON object, the way a process killed mid-append leaves the last line.
    private let truncatedLine = #"{"agentID":"cut","type":"approval","tit"#

    /// A line cut through the middle of an em dash: `0xE2 0x80` is the first two
    /// bytes of a three-byte character, so the line is not valid UTF-8 at all —
    /// not merely JSON the decoder refuses. Newline-terminated, so what follows
    /// it in the file is a line of its own.
    private let halfAnEmDashLine = Data(#"{"agentID":"cut","title":"em"#.utf8) + Data([0xE2, 0x80, 0x0A])

    /// As much of that line as survives a lossy decode unchanged.
    private let readablePrefixOfTheEmDashLine = #"{"agentID":"cut","title":"em"#

    private func assertFileHoldsTruncatedLine(after step: String,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) throws {
        let content = try String(contentsOf: notificationsURL, encoding: .utf8)
        XCTAssertTrue(content.contains(truncatedLine + "\n"),
                      "the remnant survives \(step), byte for byte", file: file, line: line)
    }

    /// A read-only directory is how a write is made to fail without touching the
    /// file itself: the temp sibling cannot be created at all.
    private func setDirectoryWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o500],
                                              ofItemAtPath: tempDir.path(percentEncoded: false))
    }

    private func appendRaw(_ text: String, to url: URL) throws {
        try appendRaw(bytes: Data(text.utf8), to: url)
    }

    private func appendRaw(bytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    /// Writes the notifications file whole. The sweep at load is the only thing
    /// that reads an age, and `NotificationItem.init` stamps `timestamp` with
    /// `Date()` — so a notice old enough to be judged has to be written by hand.
    private func writeNotifications(_ lines: [String]) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: notificationsURL)
    }

    /// One line of that file, aged: `createdDaysAgo` back for `timestamp`, and
    /// `resolvedDaysAgo` back for `resolvedAt` when the notice has one.
    private func notificationLine(id: String, title: String, status: String,
                                  createdDaysAgo: Double,
                                  resolvedDaysAgo: Double? = nil) -> String {
        let resolvedAt = resolvedDaysAgo.map { #","resolvedAt":"\#(iso8601(daysAgo: $0))""# } ?? ""
        return #"{"id":"\#(id)","timestamp":"\#(iso8601(daysAgo: createdDaysAgo))","agentID":"w","#
            + #""type":"approval","title":"\#(title)","body":"","status":"\#(status)"\#(resolvedAt)}"#
    }

    /// The spelling the store's decoder reads: `.iso8601`, no fractional seconds.
    private func iso8601(daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }
}
