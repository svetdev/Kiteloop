import XCTest
@testable import KiteloopCore

/// A store that cannot read or write its file used to say nothing at all — the
/// error was discarded at the `try?` and the human found out by noticing their
/// settings kept reverting. These pin the one call that ends that: an error row
/// in the inbox, a Diagnostics line beside it, and one row per store rather than
/// one per failed autosave.
final class StoreProblemReporterTests: XCTestCase {

    private enum StoreFailure: Error {
        case boom(String)
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Every report here also writes a Diagnostics line through the shared
        // logger, and its fixture errors name temp directories nobody wants in
        // the human's real log.
        try redirectSharedLoggerToTemporaryDirectory(prefix: "store-problem-log")
        tempDir = try makeTemporaryDirectory(prefix: "store-problem")
    }

    private func makeInbox(_ name: String = "inbox") -> NotificationStore {
        NotificationStore(notificationsURL: tempDir.appending(path: "\(name).log"))
    }

    /// Keeps the order `add` was called in, which `NotificationStore` does not
    /// expose: it sorts by timestamp, and a held report carries the timestamp of
    /// when it was made rather than of when it was filed.
    private actor RecordingInbox: NotificationStoring {
        private var items: [NotificationItem] = []

        func add(_ item: NotificationItem) async { items.append(item) }
        func markResolved(id: String) async { items.removeAll { $0.id == id } }
        func resolveApprovals(itemID: String, closure: GateClosure) async -> Int { 0 }
        func resolveQuestions(agentID: String, closure: GateClosure) async -> Int { 0 }
        func backfillPassedNotices(itemsAtGate: Set<String>) async -> Int { 0 }
        func dismiss(id: String) async { items.removeAll { $0.id == id } }
        func dismissAllPending(actionable: Bool) async { items.removeAll() }
        func pending() async -> [NotificationItem] { items }
        func resolved() async -> [NotificationItem] { [] }
        func pendingCount() async -> Int { items.count }
        func actionablePendingCount() async -> Int { items.count }
    }

    // MARK: - Posting

    func testReportPostsAnActionableErrorNotification() async {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)

        reporter.report(store: "Settings",
                        operation: .write,
                        url: tempDir.appending(path: "global-config.json"),
                        error: StoreFailure.boom("no space"))
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        // `.error` is already actionable, so the row lands in the badged inbox
        // rather than the ambient feed.
        let actionable = await inbox.actionablePendingCount()
        XCTAssertEqual(actionable, 1)
    }

    /// The row has to say which store, which operation and which file — a bare
    /// "a write failed" is not something a human can act on.
    func testReportNamesTheStoreTheOperationAndTheFile() async {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")

        reporter.report(store: "Settings", operation: .write, url: url, error: StoreFailure.boom("EDQUOT"))
        await reporter.drain()

        let item = await inbox.pending().first
        XCTAssertEqual(item?.title, "Could not write Settings")
        XCTAssertEqual(item?.body.contains(url.path(percentEncoded: false)), true)
        XCTAssertEqual(item?.body.contains("EDQUOT"), true)
    }

    /// `localizedDescription` on a plain Swift enum is Foundation's "the
    /// operation couldn't be completed" placeholder, which names nothing. The
    /// case does.
    func testReportCarriesTheErrorItselfRatherThanAPlaceholder() async {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)

        reporter.report(store: "Settings",
                        operation: .write,
                        url: tempDir.appending(path: "c.json"),
                        error: AtomicFileWriter.WriteError.posix(operation: "rename", errno: 28))
        await reporter.drain()

        let body = await inbox.pending().first?.body
        XCTAssertEqual(body?.contains("rename"), true)
        XCTAssertEqual(body?.contains("28"), true)
        XCTAssertEqual(body?.contains("couldn't be completed"), false)
    }

    func testReportWritesOneDiagnosticsLine() async {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")
        let marker = "marker-\(UUID().uuidString)"

        reporter.report(store: "Settings", operation: .write, url: url, error: StoreFailure.boom(marker))
        await reporter.drain()

        let lines = KiteloopFileLogger.shared.snapshot()
            .filter { $0.category == StoreProblemReporter.logCategory && $0.message.contains(marker) }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.levelTag, "ERROR")
        XCTAssertEqual(lines.first?.message.contains("Settings"), true)
        XCTAssertEqual(lines.first?.message.contains("write"), true)
        XCTAssertEqual(lines.first?.message.contains(url.path(percentEncoded: false)), true)
    }

    /// Before a project is open there is no inbox. The Diagnostics line is
    /// written on the caller's thread either way — the row waits for an inbox,
    /// the log line does not.
    func testReportWithoutAnInboxStillLogsAndDoesNotCrash() async {
        let reporter = StoreProblemReporter()
        let marker = "marker-\(UUID().uuidString)"

        reporter.report(store: "Settings",
                        operation: .read,
                        url: tempDir.appending(path: "c.json"),
                        error: StoreFailure.boom(marker))
        await reporter.drain()

        let lines = KiteloopFileLogger.shared.snapshot()
            .filter { $0.category == StoreProblemReporter.logCategory && $0.message.contains(marker) }
        XCTAssertEqual(lines.count, 1)
    }

    // MARK: - Dedup

    /// The failure this is for: a store failing every autosave. One problem is
    /// one row, however many times it recurs.
    func testRepeatedFailuresRefreshTheOneRowRatherThanAddingRows() async {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")

        for attempt in 1...5 {
            reporter.report(store: "Settings",
                            operation: .write,
                            url: url,
                            error: StoreFailure.boom("attempt-\(attempt)"))
        }
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        // The row that survives is the newest one — a refresh, not a suppression:
        // a stale row would still be reporting a failure from an hour ago.
        XCTAssertEqual(pending.first?.body.contains("attempt-5"), true)
    }

    /// A store that can neither read nor write has two problems, and a human
    /// fixing one has not fixed the other.
    func testReadAndWriteFailuresFromOneStoreAreSeparateRows() async {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")

        reporter.report(store: "Settings", operation: .write, url: url, error: StoreFailure.boom("w"))
        reporter.report(store: "Settings", operation: .read, url: url, error: StoreFailure.boom("r"))
        reporter.report(store: "Settings", operation: .write, url: url, error: StoreFailure.boom("w2"))
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(Set(pending.map { $0.title }),
                       ["Could not write Settings", "Could not read Settings"])
    }

    func testDifferentStoresGetTheirOwnRows() async {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)

        reporter.report(store: "Settings", operation: .write,
                        url: tempDir.appending(path: "a.json"), error: StoreFailure.boom("a"))
        reporter.report(store: "Backlog", operation: .write,
                        url: tempDir.appending(path: "b.md"), error: StoreFailure.boom("b"))
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 2)
    }

    /// A row the human has already dealt with is settled history. Refreshing it
    /// would take a resolved item back out of the resolved list, and the failure
    /// that came after they cleared it is news rather than a repeat.
    func testAFailureAfterTheRowWasResolvedFilesAFreshRow() async throws {
        let inbox = makeInbox()
        let reporter = StoreProblemReporter(notifications: inbox)
        let url = tempDir.appending(path: "global-config.json")

        reporter.report(store: "Settings", operation: .write, url: url, error: StoreFailure.boom("first"))
        await reporter.drain()
        let firstRow = await inbox.pending().first
        let first = try XCTUnwrap(firstRow)
        await inbox.markResolved(id: first.id)

        reporter.report(store: "Settings", operation: .write, url: url, error: StoreFailure.boom("second"))
        await reporter.drain()

        let pending = await inbox.pending()
        let resolved = await inbox.resolved()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.body.contains("second"), true)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.id, first.id)
    }

    /// The remembered rows belong to the inbox they were filed in. Pointing the
    /// reporter at another project's inbox must not leave it trying to refresh a
    /// row that isn't there — which would swallow the first failure's row.
    func testConfiguringANewInboxFilesAFreshRowThere() async {
        let first = makeInbox("first")
        let second = makeInbox("second")
        let reporter = StoreProblemReporter(notifications: first)
        let url = tempDir.appending(path: "global-config.json")

        reporter.report(store: "Settings", operation: .write, url: url, error: StoreFailure.boom("1"))
        await reporter.drain()

        reporter.configure(notifications: second)
        reporter.report(store: "Settings", operation: .write, url: url, error: StoreFailure.boom("2"))
        await reporter.drain()

        let firstPending = await first.pending()
        let secondPending = await second.pending()
        XCTAssertEqual(firstPending.count, 1)
        XCTAssertEqual(secondPending.count, 1)
        XCTAssertEqual(secondPending.first?.body.contains("2"), true)
    }

    // MARK: - Held until there is an inbox

    /// The launch paths report before any project is open, so the row they file
    /// has nowhere to go. It waits, and lands in the first inbox attached —
    /// otherwise a settings file the app could not read at launch is a
    /// Diagnostics line nobody opens.
    func testAReportMadeBeforeAnInboxIsFiledWhenOneIsAttached() async {
        let reporter = StoreProblemReporter()
        let inbox = makeInbox()

        reporter.report(store: "Settings",
                        operation: .read,
                        url: tempDir.appending(path: "global-config.json"),
                        error: StoreFailure.boom("EILSEQ"))
        await reporter.drain()

        reporter.configure(notifications: inbox)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, .error)
        XCTAssertEqual(pending.first?.title, "Could not read Settings")
        XCTAssertEqual(pending.first?.body.contains("EILSEQ"), true)
    }

    /// A store failing in a loop before there is an inbox is still one problem.
    /// It holds one entry, refreshed each time, so the flush is one row carrying
    /// the newest failure rather than a backlog of identical ones.
    func testRepeatedFailuresWithNoInboxFileOneRowOnFlush() async {
        let reporter = StoreProblemReporter()
        let inbox = makeInbox()
        let url = tempDir.appending(path: "global-config.json")

        for attempt in 1...5 {
            reporter.report(store: "Settings",
                            operation: .write,
                            url: url,
                            error: StoreFailure.boom("attempt-\(attempt)"))
        }
        reporter.configure(notifications: inbox)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.body.contains("attempt-5"), true)
    }

    /// Two stores that both failed at launch are two problems, and they reach
    /// the inbox in the order they were reported.
    func testHeldReportsFromDifferentStoresAreFiledInReportOrder() async {
        let reporter = StoreProblemReporter()
        let inbox = RecordingInbox()

        reporter.report(store: "Settings", operation: .read,
                        url: tempDir.appending(path: "a.json"), error: StoreFailure.boom("a"))
        reporter.report(store: "Agent package", operation: .read,
                        url: tempDir.appending(path: "b.json"), error: StoreFailure.boom("b"))
        reporter.configure(notifications: inbox)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.map { $0.title },
                       ["Could not read Settings", "Could not read Agent package"])
    }

    /// The flush empties what was held: a second project opening later does not
    /// get the launch failures filed all over again.
    func testHeldReportsAreFiledOnceAndNotIntoALaterInbox() async {
        let reporter = StoreProblemReporter()
        let first = makeInbox("first")
        let second = makeInbox("second")

        reporter.report(store: "Settings", operation: .read,
                        url: tempDir.appending(path: "c.json"), error: StoreFailure.boom("1"))
        reporter.configure(notifications: first)
        await reporter.drain()

        reporter.configure(notifications: second)
        await reporter.drain()

        let firstPending = await first.pending()
        let secondPending = await second.pending()
        XCTAssertEqual(firstPending.count, 1)
        XCTAssertEqual(secondPending.count, 0)
    }

    /// Detaching the inbox is not the same as filing: a report made while there
    /// is still no inbox keeps waiting for the next one.
    func testDetachingTheInboxKeepsHoldingRatherThanDropping() async {
        let reporter = StoreProblemReporter()
        let inbox = makeInbox()

        reporter.report(store: "Settings", operation: .read,
                        url: tempDir.appending(path: "c.json"), error: StoreFailure.boom("held"))
        reporter.configure(notifications: nil)
        reporter.configure(notifications: inbox)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.body.contains("held"), true)
    }
}
