import XCTest
import KiteloopCore
@testable import Kiteloop

/// A note for the next worker run, added from the item page.
///
/// The Reject sheet was the only place in the app a person could write to an
/// item's `## Notes`, and it exists only for an item waiting at the gate. The
/// page's Add Note goes through the same writer, for any item with a detail
/// file.
@MainActor
final class BacklogItemDetailNoteTests: XCTestCase {

    private var tempDir: URL!

    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] task-1 | First task | ready | size: S → [detail](backlog/task-1.md)
    - [ ] task-2 | Ungroomed task | draft | size: S
    - [ ] task-3 | Missing detail | ready | size: S → [detail](backlog/missing.md)
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "item-detail-note")
    }

    func testANoteLandsUnderNotesAndLeavesTheLineAlone() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-1")
        await model.load()
        let lineBefore = try String(contentsOf: backlogURL, encoding: .utf8)

        let saved = await model.addNote("  Try the parser before the view.\n")

        XCTAssertTrue(saved)
        let detail = try String(contentsOf: tempDir.appending(path: "backlog/task-1.md"), encoding: .utf8)
        let notes = try XCTUnwrap(detail.components(separatedBy: "## Notes").last)
        let entries = notes.split(separator: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].hasPrefix("- \(DayKey.string(for: Date())) — "), "The entry is dated")
        XCTAssertTrue(entries[0].hasSuffix("Try the parser before the view."))
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), lineBefore,
                       "Adding a note changes nothing on the item's BACKLOG.md line")
        XCTAssertEqual(model.item.status, .ready)
        XCTAssertNil(model.actionNote)
        // The page re-read the file: the note is on it without a reopen.
        XCTAssertTrue(model.detail?.notes?.contains("Try the parser before the view.") == true)
    }

    func testABlankNoteWritesNothing() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-1")
        let detailURL = tempDir.appending(path: "backlog/task-1.md")
        let before = try String(contentsOf: detailURL, encoding: .utf8)

        let saved = await model.addNote("   \n\t ")

        XCTAssertFalse(saved, "A blank note is not saved, so the field stays open")
        XCTAssertEqual(try String(contentsOf: detailURL, encoding: .utf8), before)
        XCTAssertNil(model.actionNote)
    }

    func testAnItemWithNoDetailFileHasNowhereToWriteANote() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-2")

        XCTAssertNil(model.item.detailPath, "The page shows no note field for this item")
        let saved = await model.addNote("Something for the next run")
        XCTAssertFalse(saved)
    }

    func testANoteThatCannotBeWrittenSaysSoAndIsNotSaved() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-3")

        let saved = await model.addNote("Something for the next run")

        XCTAssertFalse(saved)
        XCTAssertEqual(model.actionNote, "The note didn't reach task-3's detail file — nothing was saved")
    }

    // MARK: - Helpers

    private var backlogURL: URL { tempDir.appending(path: "BACKLOG.md") }

    private func makeBacklog() throws -> BacklogViewModel {
        try FileManager.default.createDirectory(at: tempDir.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        try "## What\n\nFirst task.\n".write(to: tempDir.appending(path: "backlog/task-1.md"),
                                             atomically: true, encoding: .utf8)
        try sampleBacklog.write(to: backlogURL, atomically: true, encoding: .utf8)
        let backlog = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        )
        backlog.loadForProject(repoPath: tempDir.path(percentEncoded: false))
        return backlog
    }

    /// The model the page is built on, with every store pointed at the temp
    /// directory so a test never reads or writes the real ledgers.
    private func makeModel(backlog: BacklogViewModel, itemID: String) -> BacklogItemDetailViewModel {
        let item = backlog.item(withID: itemID)!
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
