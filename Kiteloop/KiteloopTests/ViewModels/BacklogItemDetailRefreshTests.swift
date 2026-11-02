import XCTest
import KiteloopCore
@testable import Kiteloop

/// The item page keeps up with the item while it is open.
///
/// The page was a snapshot taken when it was opened — a run that started,
/// advanced a phase or appended to the item's Notes showed only after going
/// Back and opening it again — and it is the surface an operator has open
/// precisely while a run is going. `BacklogItemDetailView` holds a loop over
/// `load()` open for the page's lifetime; these tests drive that loop directly.
@MainActor
final class BacklogItemDetailRefreshTests: XCTestCase {

    private var tempDir: URL!

    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] task-1 | First task | ready | size: S → [detail](backlog/task-1.md)
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "item-detail-refresh")
    }

    /// The measured failure: a line written to the item's Notes while the page
    /// is open, still absent from it seconds later.
    func testANoteWrittenWhileTheLoopRunsReachesTheModel() async throws {
        let backlog = try makeBacklog()
        XCTAssertTrue(backlog.appendNote(itemID: "task-1", "Run started"))
        let model = makeModel(backlog: backlog)
        await model.load()
        XCTAssertEqual(model.changes.count, 1, "Precondition: the first read has the note already on file")

        // The shape the page's `.task` holds open for the view's lifetime.
        let loop = Task {
            while !Task.isCancelled {
                await model.load()
                await Task.yield()
            }
        }
        defer { loop.cancel() }

        XCTAssertTrue(backlog.appendNote(itemID: "task-1", "Run reached its gate"))
        try await eventually("the appended note to reach the page") {
            model.changes.contains { ($0.detail ?? "").contains("Run reached its gate") }
        }
    }

    /// The other half of what the page joins: the item's own line. A status
    /// written to the backlog reaches the page without a reopen, because
    /// `load()` re-reads the item rather than keeping the one it was built on.
    func testAStatusChangedWhileTheLoopRunsReachesTheModel() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog)
        await model.load()
        XCTAssertEqual(model.item.status, .ready)

        let loop = Task {
            while !Task.isCancelled {
                await model.load()
                await Task.yield()
            }
        }
        defer { loop.cancel() }

        backlog.updateItemStatus(itemID: "task-1", newStatus: .active)
        try await eventually("the new status to reach the page") {
            model.item.status == .active
        }
    }

    /// Leaving the page stops the reading: the cancelled `.task` is the only
    /// thing that ends the loop, so a cancelled loop must stop calling `load()`.
    func testCancellingTheLoopStopsTheReading() async throws {
        let backlog = try makeBacklog()
        XCTAssertTrue(backlog.appendNote(itemID: "task-1", "Run started"))
        let model = makeModel(backlog: backlog)

        let loop = Task {
            while !Task.isCancelled {
                await model.load()
                await Task.yield()
            }
        }
        try await eventually("the loop's first read to land") { model.changes.count == 1 }
        loop.cancel()
        // The page is gone: awaiting the result is the loop having ended, so
        // anything written from here on has no reader left.
        _ = await loop.result

        XCTAssertTrue(backlog.appendNote(itemID: "task-1", "Written after the page closed"))
        XCTAssertEqual(model.changes.count, 1, "Nothing reads for a page that is closed")
    }

    // MARK: - Helpers

    private func makeBacklog() throws -> BacklogViewModel {
        try FileManager.default.createDirectory(at: tempDir.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        try "## What\n\nFirst task.\n".write(to: tempDir.appending(path: "backlog/task-1.md"),
                                             atomically: true, encoding: .utf8)
        try sampleBacklog.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        let backlog = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        )
        backlog.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        return backlog
    }

    /// The model the page is built on, with every store pointed at the temp
    /// directory so a test never reads or writes the real ledgers.
    private func makeModel(backlog: BacklogViewModel) -> BacklogItemDetailViewModel {
        let item = backlog.item(withID: "task-1")!
        return BacklogItemDetailViewModel(
            item: item,
            projectPath: tempDir.path(percentEncoded: false),
            projectName: "demo",
            isRetired: false,
            backlog: backlog,
            autopilot: BacklogAutopilot(),
            metricIndex: MetricIndex(sources: .standard(in: tempDir)),
            metricStore: TaskMetricStore(
                metricsURL: tempDir.appending(path: "task-metrics.jsonl"),
                estimatesURL: tempDir.appending(path: "task-estimates.jsonl"),
                approvalsURL: tempDir.appending(path: "task-approvals.jsonl"),
                mergesURL: tempDir.appending(path: "task-merges.jsonl")),
            groomingLedger: GroomingLedger(url: tempDir.appending(path: "grooming.jsonl")),
            runRecords: RunRecordStore(url: tempDir.appending(path: "runs.jsonl")))
    }
}
