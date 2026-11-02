import XCTest
@testable import KiteloopCore

/// Several projects' backlogs read together, against real files in a temp tree.
///
/// Two properties matter more than the rest and are asserted directly rather
/// than reasoned about: one unreachable project must not empty the screen, and
/// nothing on any path through this type may write to a `BACKLOG.md` — read-only
/// is the whole of what v0 promises.
final class PortfolioBacklogsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "portfolio-backlogs")
    }

    // MARK: - Fixtures

    /// `KiteloopProject.canonicalPath`'s rule — no trailing slash — spelled out
    /// here because that type is the app's, and this test runs without it.
    private func canonical(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// A project root with a `BACKLOG.md`, returning its canonical path.
    @discardableResult
    private func makeProject(_ name: String, backlog: String) throws -> String {
        let root = tempDir.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try backlog.write(to: root.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        return canonical(root)
    }

    /// A directory with no backlog in it.
    private func makeBareDirectory(_ name: String) throws -> String {
        let root = tempDir.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return canonical(root)
    }

    private func backlog(project: String, items: String) -> String {
        """
        ---
        project: \(project)
        ---

        # \(project) Backlog

        ## Epic: Now

        \(items)
        """
    }

    private let alphaItems = """
    - [ ] alpha-1 | Ship the thing | ready | size: M
    - [ ] alpha-2 | Half done | active | size: S
    - [x] alpha-3 | Landed already | size: XS
    """

    private let betaItems = """
    - [ ] beta-1 | Another project's work | ready | size: L
    - [ ] beta-2 | Stuck | blocked | size: M
    """

    // MARK: - Aggregation

    func testTwoProjectsAreListedTogetherInTheOrderGiven() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))
        let beta = try makeProject("beta", backlog: backlog(project: "beta", items: betaItems))

        let loaded = PortfolioBacklogs.load(paths: [beta, alpha])

        XCTAssertEqual(loaded.projects.map(\.name), ["beta", "alpha"])
        XCTAssertEqual(loaded.projects.map(\.path), [beta, alpha])
        XCTAssertEqual(loaded.itemCount, 5)
        XCTAssertTrue(loaded.skipped.isEmpty)
    }

    /// Title, stage and size all have to survive the trip — they are what the
    /// row draws.
    func testItemsCarryTitleStatusAndSize() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))

        let items = PortfolioBacklogs.load(paths: [alpha]).projects[0].items

        XCTAssertEqual(items.map(\.item.id), ["alpha-1", "alpha-2", "alpha-3"])
        XCTAssertEqual(items[0].item.title, "Ship the thing")
        XCTAssertEqual(items[0].item.status, .ready)
        XCTAssertEqual(items[0].item.size, .m)
        XCTAssertEqual(items[2].item.status, .done, "A checked box is a finished item")
    }

    /// An id is unique inside one backlog and nowhere else. Two projects both
    /// holding `task-1` must stay two rows.
    func testIdenticalItemIDsInTwoProjectsStayDistinct() throws {
        let alpha = try makeProject("alpha", backlog: backlog(
            project: "alpha", items: "- [ ] task-1 | Alpha's task | ready | size: S"))
        let beta = try makeProject("beta", backlog: backlog(
            project: "beta", items: "- [ ] task-1 | Beta's task | ready | size: S"))

        let loaded = PortfolioBacklogs.load(paths: [alpha, beta])
        let entries = loaded.projects.flatMap(\.items)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2, "The pair is the identity, not the item id")
        XCTAssertEqual(entries.map(\.projectPath), [alpha, beta])
    }

    func testItemsAreFlattenedAcrossEpics() throws {
        let alpha = try makeProject("alpha", backlog: """
        ---
        project: alpha
        ---

        ## Epic: Now

        - [ ] alpha-1 | First | ready | size: S

        ## Epic: Later

        - [ ] alpha-2 | Second | draft | size: S
        """)

        XCTAssertEqual(PortfolioBacklogs.load(paths: [alpha]).projects[0].items.map(\.item.id),
                       ["alpha-1", "alpha-2"])
    }

    // MARK: - Naming

    func testProjectNameComesFromBacklogFrontmatter() throws {
        let path = try makeProject("repo-checkout", backlog: backlog(
            project: "Customer Portal", items: "- [ ] a-1 | Work | ready | size: S"))

        XCTAssertEqual(PortfolioBacklogs.load(paths: [path]).projects[0].name, "Customer Portal")
    }

    /// A backlog that states no project falls back to the folder, which is at
    /// least something a reader can recognise.
    func testProjectNameFallsBackToTheFolderWhenFrontmatterStatesNone() throws {
        let path = try makeProject("my-repo", backlog: "## Epic: Now\n\n- [ ] a-1 | Work | ready | size: S")

        XCTAssertEqual(PortfolioBacklogs.load(paths: [path]).projects[0].name, "my-repo")
    }

    // MARK: - Skipping

    /// The acceptance criterion, and the property the whole load is built
    /// around: one bad path must cost exactly one project.
    func testAProjectWithNoBacklogIsSkippedAndTheRestStillLoad() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))
        let bare = try makeBareDirectory("no-backlog-here")
        let beta = try makeProject("beta", backlog: backlog(project: "beta", items: betaItems))

        let loaded = PortfolioBacklogs.load(paths: [alpha, bare, beta])

        XCTAssertEqual(loaded.projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(loaded.skipped.map(\.path), [bare])
        XCTAssertEqual(loaded.skipped[0].reason, .noBacklogFile)
    }

    func testAPathThatIsNotThereIsSkippedAsAMissingDirectory() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))
        let gone = tempDir.appending(path: "moved-away").path(percentEncoded: false)

        let loaded = PortfolioBacklogs.load(paths: [gone, alpha])

        XCTAssertEqual(loaded.projects.map(\.name), ["alpha"])
        XCTAssertEqual(loaded.skipped.map(\.reason), [.missingDirectory])
    }

    /// A file where a directory should be is a typo, not a project.
    func testAPathNamingAFileIsSkipped() throws {
        let file = tempDir.appending(path: "notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let loaded = PortfolioBacklogs.load(paths: [file.path(percentEncoded: false)])

        XCTAssertTrue(loaded.projects.isEmpty)
        XCTAssertEqual(loaded.skipped.map(\.reason), [.missingDirectory])
    }

    /// One byte that is not UTF-8, in prose no item depends on, must not skip
    /// the project as unreadable and drop every item it holds.
    func testABacklogWithOneBadByteStillLoadsEveryItem() throws {
        let alpha = try makeProject("alpha", backlog: "")
        var data = Data("---\nproject: alpha\n---\n\n## Epic: Now\n\nPlanning ".utf8)
        data.append(0xFF)
        data.append(Data(" notes.\n\n\(alphaItems)\n".utf8))
        try data.write(to: URL(fileURLWithPath: alpha).appending(path: "BACKLOG.md"))

        let loaded = PortfolioBacklogs.load(paths: [alpha])

        XCTAssertTrue(loaded.skipped.isEmpty, "a bad byte reads as U+FFFD, not as an unreadable file")
        XCTAssertEqual(loaded.projects.map(\.name), ["alpha"])
        XCTAssertEqual(loaded.projects.first?.items.map(\.item.id), ["alpha-1", "alpha-2", "alpha-3"])
    }

    /// Every skipped path says something a human can act on in `portfolio.md`.
    func testEverySkipReasonExplainsItself() throws {
        let bare = try makeBareDirectory("bare")
        let gone = tempDir.appending(path: "gone").path(percentEncoded: false)

        for skipped in PortfolioBacklogs.load(paths: [bare, gone]).skipped {
            XCTAssertFalse(skipped.explanation.isEmpty)
        }
    }

    func testAnEmptyPortfolioLoadsToNothingRatherThanFailing() {
        let loaded = PortfolioBacklogs.load(paths: [])

        XCTAssertTrue(loaded.projects.isEmpty)
        XCTAssertTrue(loaded.skipped.isEmpty)
        XCTAssertEqual(loaded.itemCount, 0)
    }

    // MARK: - Read-only

    /// The v0 promise, asserted rather than described: reading a portfolio
    /// leaves every backlog byte-identical, and adds no file to any project.
    func testLoadingModifiesNoBacklogFile() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))
        let beta = try makeProject("beta", backlog: backlog(project: "beta", items: betaItems))
        let urls = [alpha, beta].map { URL(fileURLWithPath: $0).appending(path: "BACKLOG.md") }
        let before = try urls.map { try Data(contentsOf: $0) }
        let treeBefore = try directoryListing()

        let loaded = PortfolioBacklogs.load(paths: [alpha, beta])
        _ = loaded.filtered(by: .status(.ready))
        _ = loaded.projects.map { PortfolioBacklogs.detailURL(for: $0.items[0].item, backlogURL: $0.backlogURL) }

        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before,
                       "A portfolio read must not rewrite a project's backlog")
        XCTAssertEqual(try directoryListing(), treeBefore,
                       "A portfolio read must not add or remove any file")
    }

    /// Every file under the temp tree, sorted — enough to catch a stray write.
    private func directoryListing() throws -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: tempDir.path(percentEncoded: false))
        return ((enumerator?.allObjects as? [String]) ?? []).sorted()
    }

    // MARK: - Filtering

    /// The acceptance criterion: one control narrows every project at once.
    func testAStatusFilterNarrowsAcrossAllProjects() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))
        let beta = try makeProject("beta", backlog: backlog(project: "beta", items: betaItems))

        let ready = PortfolioBacklogs.load(paths: [alpha, beta]).filtered(by: .status(.ready))

        XCTAssertEqual(ready.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(ready.flatMap(\.items).map(\.item.id), ["alpha-1", "beta-1"])
    }

    func testTheAllFilterKeepsEverything() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))
        let beta = try makeProject("beta", backlog: backlog(project: "beta", items: betaItems))
        let loaded = PortfolioBacklogs.load(paths: [alpha, beta])

        XCTAssertEqual(loaded.filtered(by: .all).flatMap(\.items).count, loaded.itemCount)
    }

    /// A project with nothing matching drops out entirely. A heading with no
    /// rows under it is noise in a list that is already several projects long.
    func testAProjectWithNoMatchingItemsIsDroppedFromAFilteredList() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))
        let beta = try makeProject("beta", backlog: backlog(project: "beta", items: betaItems))

        let blocked = PortfolioBacklogs.load(paths: [alpha, beta]).filtered(by: .status(.blocked))

        XCTAssertEqual(blocked.map(\.name), ["beta"])
        XCTAssertEqual(blocked.flatMap(\.items).map(\.item.id), ["beta-2"])
    }

    func testFilteringToAStageNothingIsInShowsNothing() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))

        XCTAssertTrue(PortfolioBacklogs.load(paths: [alpha]).filtered(by: .status(.inReview)).isEmpty)
    }

    // MARK: - Filter choices

    /// The control offers stages the portfolio actually holds, so no choice on
    /// it narrows to an empty screen.
    func testPresentStatusesAreTheStagesThePortfolioHoldsInStageOrder() throws {
        let alpha = try makeProject("alpha", backlog: backlog(project: "alpha", items: alphaItems))
        let beta = try makeProject("beta", backlog: backlog(project: "beta", items: betaItems))

        XCTAssertEqual(PortfolioBacklogs.load(paths: [alpha, beta]).presentStatuses,
                       [.ready, .active, .blocked, .done])
    }

    func testFilterChoicesLeadWithAll() {
        let choices = PortfolioStatusFilter.choices(for: [.ready, .done])

        XCTAssertEqual(choices.map(\.label), ["All", "Ready", "Done"])
        XCTAssertEqual(choices.first, .all)
    }

    func testTheAllFilterMatchesEveryStage() {
        for status in BacklogItemStatus.allCases {
            XCTAssertTrue(PortfolioStatusFilter.all.matches(status))
        }
    }

    // MARK: - Detail files

    /// The convention `createDetail` writes to, which is what most items carry.
    func testDetailResolvesTheBacklogIDConventionWhenTheLineLinksNothing() throws {
        let path = try makeProject("alpha", backlog: backlog(
            project: "alpha", items: "- [ ] alpha-1 | Work | ready | size: S"))
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        try "## What\n\nThe work.".write(to: root.appending(path: "backlog/alpha-1.md"),
                                         atomically: true, encoding: .utf8)

        let project = PortfolioBacklogs.load(paths: [path]).projects[0]
        let url = PortfolioBacklogs.detailURL(for: project.items[0].item, backlogURL: project.backlogURL)

        XCTAssertEqual(url?.lastPathComponent, "alpha-1.md")
        XCTAssertEqual(BacklogParser.parseDetail(at: try XCTUnwrap(url))?.what, "The work.")
    }

    /// An explicit `→ [detail](…)` link wins, and resolves relative to the
    /// backlog file rather than to the project root — the same rule
    /// `BacklogViewModel.detailURL(for:)` follows.
    func testAnExplicitDetailLinkIsUsed() throws {
        let path = try makeProject("alpha", backlog: backlog(
            project: "alpha",
            items: "- [ ] alpha-1 | Work | ready | size: S → [detail](specs/custom.md)"))
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root.appending(path: "specs"),
                                                withIntermediateDirectories: true)
        try "## What\n\nLinked.".write(to: root.appending(path: "specs/custom.md"),
                                       atomically: true, encoding: .utf8)

        let project = PortfolioBacklogs.load(paths: [path]).projects[0]
        let url = PortfolioBacklogs.detailURL(for: project.items[0].item, backlogURL: project.backlogURL)

        XCTAssertEqual(url?.lastPathComponent, "custom.md")
    }

    /// An ungroomed item has no detail, and that is a state to report rather
    /// than a path to hand back and fail to open.
    func testAnItemWithNoDetailFileResolvesToNothing() throws {
        let path = try makeProject("alpha", backlog: backlog(
            project: "alpha", items: "- [ ] alpha-1 | Work | ready | size: S"))

        let project = PortfolioBacklogs.load(paths: [path]).projects[0]

        XCTAssertNil(PortfolioBacklogs.detailURL(for: project.items[0].item,
                                                 backlogURL: project.backlogURL))
    }

    /// A link pointing at a file that is not there falls through to the
    /// convention rather than returning a path nothing can open.
    func testADanglingDetailLinkFallsBackToTheConvention() throws {
        let path = try makeProject("alpha", backlog: backlog(
            project: "alpha",
            items: "- [ ] alpha-1 | Work | ready | size: S → [detail](specs/gone.md)"))
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root.appending(path: "backlog"),
                                                withIntermediateDirectories: true)
        try "## What\n\nStill here.".write(to: root.appending(path: "backlog/alpha-1.md"),
                                           atomically: true, encoding: .utf8)

        let project = PortfolioBacklogs.load(paths: [path]).projects[0]

        XCTAssertEqual(PortfolioBacklogs.detailURL(for: project.items[0].item,
                                                   backlogURL: project.backlogURL)?.lastPathComponent,
                       "alpha-1.md")
    }
}
