import XCTest
import KiteloopCore
@testable import Kiteloop

/// The item page lists what the item waits on, one id per row, each with that
/// item's status read off the backlog — so an unmet `needs:` can be seen, and
/// followed, without leaving the page.
@MainActor
final class BacklogItemDetailDependencyTests: XCTestCase {

    private var tempDir: URL!

    private let sampleBacklog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [x] task-1 | First task | done | size: S
    - [ ] task-2 | Second task | ready | size: S | needs:task-1
    - [ ] task-3 | Third task | ready | size: S | needs:ghost
    - [ ] task-4 | Fourth task | draft | size: S
    - [ ] task-5 | Fifth task | ready | size: S | needs:task-4
    - [ ] task-6 | Sixth task | ready | size: S | from:task-1
    - [ ] task-7 | Seventh task | draft | size: S | from:gone
    - [ ] task-8 | Eighth task | draft | size: S | from:task-6
    - [ ] task-9 | Ninth task | ready | size: S | from:task-6
    """

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "item-detail-dependencies")
    }

    func testANeedThatIsDoneListsItsIDWithStatusDone() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-2")
        await model.load()

        XCTAssertEqual(model.dependencies, [.init(id: "task-1", status: .done)])
    }

    /// An id the backlog lacks is what the readiness gate reads as unmet; the
    /// page says so rather than dropping the row.
    func testANeedTheBacklogLacksHasNoStatus() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-3")
        await model.load()

        XCTAssertEqual(model.dependencies, [.init(id: "ghost", status: nil)])
    }

    /// The page's refresh loop is the only thing that re-reads: a need that
    /// moves on the backlog shows its new status on the next `load()`.
    func testANeedsStatusChangeReachesTheListOnTheNextLoad() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-5")
        await model.load()
        XCTAssertEqual(model.dependencies, [.init(id: "task-4", status: .draft)])

        backlog.updateItemStatus(itemID: "task-4", newStatus: .done)
        await model.load()

        XCTAssertEqual(model.dependencies, [.init(id: "task-4", status: .done)])
    }

    // MARK: - Lineage

    func testAFromThatIsDoneIsTheOriginWithStatusDone() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-6")
        await model.load()

        XCTAssertEqual(model.origin, .init(id: "task-1", status: .done))
    }

    /// A parent that has left the backlog keeps its id, with no status — the
    /// page shows it without a link rather than dropping the row.
    func testAFromTheBacklogLacksHasNoStatus() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-7")
        await model.load()

        XCTAssertEqual(model.origin, .init(id: "gone", status: nil))
        XCTAssertEqual(model.children, [])
    }

    func testAParentListsEveryChildInFileOrder() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-6")
        await model.load()

        XCTAssertEqual(model.children, [.init(id: "task-8", status: .draft),
                                        .init(id: "task-9", status: .ready)])
    }

    func testAnItemWithNoFromAndNoChildrenHasNoLineage() async throws {
        let backlog = try makeBacklog()
        let model = makeModel(backlog: backlog, itemID: "task-4")
        await model.load()

        XCTAssertNil(model.origin)
        XCTAssertEqual(model.children, [])
        XCTAssertEqual(model.dependencies, [])
    }

    // MARK: - Helpers

    private func makeBacklog() throws -> BacklogViewModel {
        try sampleBacklog.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
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
