import XCTest
@testable import KiteloopCore

/// Where an item mention goes when it is clicked.
///
/// The defect: the item page was reachable from the backlog surface and the
/// Autopilot queue and nowhere else, so every other place the app named an item
/// — the run in flight, the Coordinator's overnight starts, an approval notice,
/// the menu bar — named it as text and left the operator to go and find it.
///
/// What is asserted here is the routing: that an id plus however its surface
/// spells the project resolves to one destination, and that every way it can
/// fail comes back naming the id. A mention that can't be honoured has to *say*
/// so — a click that silently does nothing is the failure this path exists to
/// rule out.
final class ItemLinkResolverTests: XCTestCase {

    // MARK: - Fixtures

    private func open(_ path: String, items: Set<String>?) -> ItemLinkResolver.OpenProject {
        ItemLinkResolver.OpenProject(id: KiteloopProject.canonicalPath(path),
                                     path: path, itemIDs: items)
    }

    private let alphaPath = "/code/alpha"
    private let betaPath = "/code/beta"

    // MARK: - Resolving to a page

    /// The ordinary case: the project is open and its backlog holds the item.
    func testResolvesByProjectPath() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .path(alphaPath),
            openProjects: [open(alphaPath, items: ["widget-flies"])])

        XCTAssertEqual(destination, .open(projectID: "/code/alpha", itemID: "widget-flies"))
    }

    /// The Coordinator's records address a project by folder name rather than by
    /// path — the whole reason `ItemLinkProject` has two spellings.
    func testResolvesByProjectFolderName() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .name("alpha"),
            openProjects: [open(betaPath, items: ["other"]),
                           open(alphaPath, items: ["widget-flies"])])

        XCTAssertEqual(destination, .open(projectID: "/code/alpha", itemID: "widget-flies"))
    }

    /// A path with a trailing slash is the same project as one without — the
    /// canonicalisation `KiteloopProject` applies to its own id, applied here so
    /// a mention carrying either spelling lands.
    func testTrailingSlashIsTheSameProject() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .path("/code/alpha/"),
            openProjects: [open(alphaPath, items: ["widget-flies"])])

        XCTAssertEqual(destination, .open(projectID: "/code/alpha", itemID: "widget-flies"))
    }

    /// Surrounding whitespace is trimmed, and the trimmed id is the one routed —
    /// not merely accepted and then passed on with the spaces still attached.
    func testTrimsTheID() {
        let destination = ItemLinkResolver.resolve(
            itemID: "  widget-flies\n", in: .path(alphaPath),
            openProjects: [open(alphaPath, items: ["widget-flies"])])

        XCTAssertEqual(destination, .open(projectID: "/code/alpha", itemID: "widget-flies"))
    }

    /// A backlog that hasn't been read yet is not a backlog with no items in it.
    /// Nil must route, and let the page itself have the last word — otherwise a
    /// project opened by the click is guaranteed to refuse its own item.
    func testUnreadBacklogStillRoutes() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .path(alphaPath),
            openProjects: [open(alphaPath, items: nil)])

        XCTAssertEqual(destination, .open(projectID: "/code/alpha", itemID: "widget-flies"))
    }

    /// Two open checkouts can share a folder name. The one whose backlog holds
    /// the item is the one that was meant.
    func testAmbiguousFolderNamePrefersTheProjectHoldingTheItem() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .name("alpha"),
            openProjects: [open("/a/alpha", items: ["something-else"]),
                           open("/b/alpha", items: ["widget-flies"])])

        XCTAssertEqual(destination, .open(projectID: "/b/alpha", itemID: "widget-flies"))
    }

    // MARK: - Opening the project first

    /// The start screen is only on screen with nothing open, so every mention it
    /// carries names a project that has to be opened before there is a backlog
    /// to land on.
    func testClosedButKnownProjectIsOpenedFirst() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .path(alphaPath),
            openProjects: [],
            closedProjects: [.init(path: alphaPath)])

        XCTAssertEqual(destination, .openProject(path: alphaPath, itemID: "widget-flies"))
    }

    /// A recent addressed by folder name resolves the same way.
    func testClosedProjectMatchesByFolderName() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .name("alpha"),
            openProjects: [],
            closedProjects: [.init(path: betaPath), .init(path: alphaPath)])

        XCTAssertEqual(destination, .openProject(path: alphaPath, itemID: "widget-flies"))
    }

    /// An open project is never re-opened over itself: the recents are consulted
    /// only when nothing open matches.
    func testOpenProjectWinsOverTheSameProjectInRecents() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .path(alphaPath),
            openProjects: [open(alphaPath, items: ["widget-flies"])],
            closedProjects: [.init(path: alphaPath)])

        XCTAssertEqual(destination, .open(projectID: "/code/alpha", itemID: "widget-flies"))
    }

    // MARK: - Refusals

    /// The stale-id case the whole degrade exists for: the project is open, its
    /// backlog has been read, and the item isn't in it.
    func testRemovedItemIsRefusedByName() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .path(alphaPath),
            openProjects: [open(alphaPath, items: ["something-else"])])

        guard case .refused(let reason) = destination else {
            return XCTFail("expected a refusal, got \(destination)")
        }
        XCTAssertTrue(reason.contains("widget-flies"),
                      "the refusal has to name the id; got: \(reason)")
        XCTAssertTrue(reason.contains("alpha"),
                      "and the backlog it looked in; got: \(reason)")
    }

    /// A project this window has never heard of — neither open nor a recent.
    func testUnknownProjectIsRefusedByName() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .name("gamma"),
            openProjects: [open(alphaPath, items: ["widget-flies"])],
            closedProjects: [.init(path: betaPath)])

        guard case .refused(let reason) = destination else {
            return XCTFail("expected a refusal, got \(destination)")
        }
        XCTAssertTrue(reason.contains("widget-flies"), "got: \(reason)")
        XCTAssertTrue(reason.contains("gamma"),
                      "the refusal names the project it couldn't find; got: \(reason)")
    }

    /// A mention carrying no id at all. It refuses rather than routing to a page
    /// about nothing — and says that, rather than naming an empty string.
    func testBlankIDIsRefused() {
        for blank in ["", "   ", "\n"] {
            let destination = ItemLinkResolver.resolve(
                itemID: blank, in: .path(alphaPath),
                openProjects: [open(alphaPath, items: ["widget-flies"])])

            guard case .refused(let reason) = destination else {
                return XCTFail("expected a refusal for \(blank.debugDescription), got \(destination)")
            }
            XCTAssertTrue(reason.contains("no item id"), "got: \(reason)")
        }
    }

    /// With nothing open and nothing in recents there is no project to name from
    /// a record, so the refusal falls back to what the mention itself carried.
    func testRefusalNamesTheProjectTheMentionCarried() {
        let destination = ItemLinkResolver.resolve(
            itemID: "widget-flies", in: .path("/somewhere/deleted-project"),
            openProjects: [])

        guard case .refused(let reason) = destination else {
            return XCTFail("expected a refusal, got \(destination)")
        }
        XCTAssertTrue(reason.contains("deleted-project"),
                      "a path is named by its folder, not spelled out in full; got: \(reason)")
    }

    // MARK: - How a project reads in a refusal

    func testDisplayNameOfAPathIsItsFolder() {
        XCTAssertEqual(ItemLinkProject.path("/code/alpha").displayName, "alpha")
        XCTAssertEqual(ItemLinkProject.name("alpha").displayName, "alpha")
    }
}
