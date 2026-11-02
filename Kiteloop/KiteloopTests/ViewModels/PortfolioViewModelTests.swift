import XCTest
import KiteloopCore
@testable import Kiteloop

/// The Portfolio screen's model, driven against a real `portfolio.md` in a temp
/// tree.
///
/// The live-reload cases write the file for real and wait for the watcher rather
/// than calling `reload()` — calling it directly was always going to pass, and
/// would say nothing about whether an edit to the portfolio file actually
/// arrives, which is one of the things this screen promises.
@MainActor
final class PortfolioViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var listURL: URL!

    /// The watcher debounces for 1s; give an edit comfortably longer than that
    /// before calling it lost.
    private let settleTimeout: TimeInterval = 5

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "portfolio")
        listURL = tempDir.appending(path: "portfolio.md")
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeProject(_ name: String, items: String) throws -> String {
        let root = tempDir.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        ---
        project: \(name)
        ---

        ## Epic: Now

        \(items)
        """.write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        return KiteloopProject.canonicalPath(root.path(percentEncoded: false))
    }

    private func writeList(_ paths: [String]) throws {
        try (paths.joined(separator: "\n") + "\n")
            .write(to: listURL, atomically: true, encoding: .utf8)
    }

    private func makeModel() -> PortfolioViewModel {
        PortfolioViewModel(listURL: listURL)
    }

    private func loaded(_ model: PortfolioViewModel) async throws {
        model.reload()
        try await waitUntil("the first load finishes") { model.hasLoaded }
    }

    // MARK: - Loading

    func testLoadsEveryProjectTheListNames() async throws {
        let alpha = try makeProject("alpha", items: "- [ ] alpha-1 | Work | ready | size: S")
        let beta = try makeProject("beta", items: "- [ ] beta-1 | Other work | ready | size: S")
        try writeList([alpha, beta])

        let model = makeModel()
        try await loaded(model)

        XCTAssertEqual(model.visibleProjects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(model.totalItemCount, 2)
        XCTAssertFalse(model.isEmpty)
    }

    /// No file yet is the state before anyone has written a portfolio — the one
    /// the seed offer belongs to, and never an error.
    func testAMissingListIsAnEmptyPortfolioOfferingToSeed() async throws {
        let model = makeModel()
        try await loaded(model)

        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(model.hasNoList)
        XCTAssertNil(model.errorMessage)
    }

    /// A list naming projects that all failed is *not* an empty portfolio, and
    /// must not offer to seed over the file somebody already wrote.
    func testAListWhoseProjectsAllFailIsNotMistakenForNoListAtAll() async throws {
        try writeList([tempDir.appending(path: "gone").path(percentEncoded: false)])

        let model = makeModel()
        try await loaded(model)

        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.hasNoList, "The file exists and names a project")
        XCTAssertEqual(model.backlogs.skipped.count, 1)
    }

    // MARK: - Live reload

    /// The acceptance criterion: editing `portfolio.md` is reflected without
    /// reopening anything.
    func testAddingAProjectToTheListAppearsWithoutReopening() async throws {
        let alpha = try makeProject("alpha", items: "- [ ] alpha-1 | Work | ready | size: S")
        let beta = try makeProject("beta", items: "- [ ] beta-1 | Other work | ready | size: S")
        try writeList([alpha])

        let model = makeModel()
        model.start()
        defer { model.stop() }
        try await waitUntil("alpha is loaded") { model.visibleProjects.count == 1 }

        try writeList([alpha, beta])

        try await waitUntil("beta appears") { model.visibleProjects.map(\.name) == ["alpha", "beta"] }
    }

    func testRemovingAProjectFromTheListRemovesItFromTheScreen() async throws {
        let alpha = try makeProject("alpha", items: "- [ ] alpha-1 | Work | ready | size: S")
        let beta = try makeProject("beta", items: "- [ ] beta-1 | Other work | ready | size: S")
        try writeList([alpha, beta])

        let model = makeModel()
        model.start()
        defer { model.stop() }
        try await waitUntil("both are loaded") { model.visibleProjects.count == 2 }

        try writeList([alpha])

        try await waitUntil("beta is gone") { model.visibleProjects.map(\.name) == ["alpha"] }
    }

    /// A portfolio file written *after* the screen is already open — the
    /// watcher has to pick up a file that did not exist when it started, which
    /// is exactly what the seed control produces.
    func testAListCreatedAfterTheScreenOpensIsPickedUp() async throws {
        let alpha = try makeProject("alpha", items: "- [ ] alpha-1 | Work | ready | size: S")

        let model = makeModel()
        model.start()
        defer { model.stop() }
        try await waitUntil("the empty state settles") { model.hasLoaded }
        XCTAssertTrue(model.hasNoList)

        try writeList([alpha])

        try await waitUntil("alpha appears") { model.visibleProjects.map(\.name) == ["alpha"] }
    }

    // MARK: - Filtering

    func testTheFilterNarrowsAcrossEveryProjectAtOnce() async throws {
        let alpha = try makeProject("alpha", items: """
        - [ ] alpha-1 | Ready work | ready | size: S
        - [ ] alpha-2 | Stuck | blocked | size: S
        """)
        let beta = try makeProject("beta", items: """
        - [ ] beta-1 | Ready too | ready | size: S
        """)
        try writeList([alpha, beta])

        let model = makeModel()
        try await loaded(model)

        model.filter = .status(.ready)

        XCTAssertEqual(model.visibleProjects.flatMap(\.items).map(\.item.id), ["alpha-1", "beta-1"])
        XCTAssertEqual(model.visibleItemCount, 2)
        XCTAssertEqual(model.totalItemCount, 3, "The total stays the portfolio's, not the filter's")
    }

    /// The control must not offer a stage that narrows to an empty screen.
    func testFilterChoicesAreAllPlusTheStagesPresent() async throws {
        let alpha = try makeProject("alpha", items: """
        - [ ] alpha-1 | Ready work | ready | size: S
        - [x] alpha-2 | Finished | size: S
        """)
        try writeList([alpha])

        let model = makeModel()
        try await loaded(model)

        XCTAssertEqual(model.filterChoices.map(\.label), ["All", "Ready", "Done"])
    }

    /// Narrowing the list must not leave a detail page open on an item the list
    /// behind it no longer holds.
    func testFilteringClearsASelectionItNoLongerShows() async throws {
        let alpha = try makeProject("alpha", items: """
        - [ ] alpha-1 | Ready work | ready | size: S
        - [ ] alpha-2 | Stuck | blocked | size: S
        """)
        try writeList([alpha])

        let model = makeModel()
        try await loaded(model)
        model.selectedItem = model.visibleProjects[0].items.first { $0.item.id == "alpha-2" }
        XCTAssertNotNil(model.selectedItem)

        model.filter = .status(.ready)

        XCTAssertNil(model.selectedItem)
    }

    func testFilteringKeepsASelectionItStillShows() async throws {
        let alpha = try makeProject("alpha", items: """
        - [ ] alpha-1 | Ready work | ready | size: S
        - [ ] alpha-2 | Stuck | blocked | size: S
        """)
        try writeList([alpha])

        let model = makeModel()
        try await loaded(model)
        model.selectedItem = model.visibleProjects[0].items.first { $0.item.id == "alpha-1" }

        model.filter = .status(.ready)

        XCTAssertEqual(model.selectedItem?.item.id, "alpha-1")
    }

    // MARK: - Detail

    func testSelectingAnItemResolvesItsDetailFile() async throws {
        let alpha = try makeProject("alpha", items: "- [ ] alpha-1 | Work | ready | size: S")
        let root = URL(fileURLWithPath: alpha)
        try FileManager.default.createDirectory(at: root.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        try "## What\n\nThe groomed work.".write(to: root.appending(path: "backlog/alpha-1.md"),
                                                 atomically: true, encoding: .utf8)
        try writeList([alpha])

        let model = makeModel()
        try await loaded(model)
        model.selectedItem = model.visibleProjects[0].items[0]

        XCTAssertEqual(model.selectedDetailURL?.lastPathComponent, "alpha-1.md")
        XCTAssertEqual(model.selectedDetail?.what, "The groomed work.")
    }

    /// An ungroomed item still opens; the page says there is no detail file
    /// rather than showing an empty one.
    func testAnItemWithNoDetailFileResolvesToNothing() async throws {
        let alpha = try makeProject("alpha", items: "- [ ] alpha-1 | Work | ready | size: S")
        try writeList([alpha])

        let model = makeModel()
        try await loaded(model)
        model.selectedItem = model.visibleProjects[0].items[0]

        XCTAssertNil(model.selectedDetailURL)
        XCTAssertNil(model.selectedDetail)
    }

    // MARK: - Seeding

    func testSeedingWritesAListThatLoadsBack() async throws {
        let alpha = try makeProject("alpha", items: "- [ ] alpha-1 | Work | ready | size: S")

        let model = makeModel()
        try await loaded(model)
        model.seedList(from: [alpha])

        try await waitUntil("the seeded list loads") { model.visibleProjects.map(\.name) == ["alpha"] }
        XCTAssertNil(model.errorMessage)
    }

    /// A portfolio somebody has edited is not something a button on an empty
    /// screen gets to replace.
    func testSeedingRefusesToOverwriteAnExistingList() async throws {
        let alpha = try makeProject("alpha", items: "- [ ] alpha-1 | Work | ready | size: S")
        try writeList([alpha])
        let original = try Data(contentsOf: listURL)

        let model = makeModel()
        try await loaded(model)
        model.seedList(from: ["/somewhere/else"])

        XCTAssertEqual(try Data(contentsOf: listURL), original)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - Read-only

    /// The v0 promise at the model level: nothing the screen drives — loading,
    /// filtering, selecting, opening a detail — writes to a `BACKLOG.md`.
    func testNothingTheScreenDoesModifiesABacklog() async throws {
        let alpha = try makeProject("alpha", items: """
        - [ ] alpha-1 | Ready work | ready | size: S
        - [ ] alpha-2 | Stuck | blocked | size: S
        """)
        try writeList([alpha])
        let backlogURL = URL(fileURLWithPath: alpha).appending(path: "BACKLOG.md")
        let before = try Data(contentsOf: backlogURL)

        let model = makeModel()
        try await loaded(model)
        model.filter = .status(.blocked)
        model.selectedItem = model.visibleProjects[0].items[0]
        _ = model.selectedDetail
        model.filter = .all
        model.reload()
        try await waitUntil("the reload finishes") { !model.isLoading }

        XCTAssertEqual(try Data(contentsOf: backlogURL), before)
    }

    // MARK: - Helpers

    private func waitUntil(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor @Sendable () -> Bool
    ) async throws {
        try await eventually(timeout: .seconds(settleTimeout), what, file: file, line: line) { await condition() }
    }
}
