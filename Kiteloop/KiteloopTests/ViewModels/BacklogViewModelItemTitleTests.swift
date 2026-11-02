import XCTest
import KiteloopCore
@testable import Kiteloop

/// An item's title could only be changed through the AI bar or by hand. These
/// cases pin `renameItem`: a new title lands on disk with the rest of the line
/// intact, and a blank title, one holding the line's field separator, and an
/// unknown id are each refused by name rather than looking saved. `addItem`
/// refuses the same two titles before anything is written, and says so when
/// the write itself fails.
@MainActor
final class BacklogViewModelItemTitleTests: XCTestCase {
    private var tempDir: URL!
    private var backlogURL: URL!
    private var viewModel: BacklogViewModel!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-item-title")
        backlogURL = tempDir.appending(path: "BACKLOG.md")
        let backlog = """
        # Test Backlog

        ## Epic: First
        - [ ] a-one | A one | verify: make check | size:S
        - [ ] a-two | A two | verify: true | size:M
        """
        try backlog.write(to: backlogURL, atomically: true, encoding: .utf8)
        viewModel = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
        viewModel.loadForProject(repoPath: tempDir.path(percentEncoded: false))
    }

    private func lineOnDisk(_ id: String) throws -> String? {
        try String(contentsOf: backlogURL, encoding: .utf8)
            .components(separatedBy: "\n")
            .first { $0.contains("\(id) |") }
    }

    func testRenamingAnItemWritesTheNewTitleAndKeepsTheRestOfItsLine() throws {
        XCTAssertEqual(viewModel.renameItem(itemID: "a-one", to: "  A better one  "), .applied)
        let line = try XCTUnwrap(lineOnDisk("a-one"))
        XCTAssertTrue(line.contains("| A better one |"), "the title is stored trimmed: \(line)")
        XCTAssertFalse(line.contains("A one"))
        XCTAssertTrue(line.contains("verify: make check"), line)
        XCTAssertTrue(line.contains("size:S"), line)
        XCTAssertEqual(viewModel.item(withID: "a-one")?.title, "A better one")
        XCTAssertNil(viewModel.operationMessage)
    }

    func testRenamingAnItemToAWhitespaceOnlyTitleIsRefused() {
        XCTAssertEqual(viewModel.renameItem(itemID: "a-one", to: "   "), .emptyTitle)
        XCTAssertEqual(viewModel.item(withID: "a-one")?.title, "A one")
        XCTAssertNotNil(viewModel.operationMessage, "the refusal is named beside the backlog")
    }

    func testRenamingAnItemToATitleHoldingTheFieldSeparatorIsRefused() throws {
        let before = try lineOnDisk("a-one")
        XCTAssertEqual(viewModel.renameItem(itemID: "a-one", to: "Left | right"), .holdsFieldSeparator)
        XCTAssertEqual(try lineOnDisk("a-one"), before, "the line on disk is untouched")
        XCTAssertEqual(viewModel.item(withID: "a-one")?.title, "A one")
        XCTAssertNotNil(viewModel.operationMessage)
    }

    func testRenamingAnItemTheBacklogDoesNotHaveIsRefused() {
        XCTAssertEqual(viewModel.renameItem(itemID: "no-such-item", to: "Anything"), .unknownItem)
        XCTAssertEqual(viewModel.item(withID: "a-one")?.title, "A one")
        XCTAssertEqual(viewModel.item(withID: "a-two")?.title, "A two")
    }

    func testRenamingAnItemToItsOwnTitleIsNothingToRefuse() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertEqual(viewModel.renameItem(itemID: "a-one", to: "A one"), .applied,
                       "nothing changes, and nothing is refused — the field closes")
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
    }

    func testAddingAnItemWhoseTitleHoldsTheFieldSeparatorIsRefusedAndWritesNothing() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        let outcome = viewModel.addItem(sectionName: "First", id: "a-three", title: "A | B", verify: nil)
        XCTAssertEqual(outcome, .holdsFieldSeparator)
        XCTAssertFalse(outcome.didFile)
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before, "BACKLOG.md is untouched")
        XCTAssertNil(viewModel.item(withID: "a-three"))
        let message = try XCTUnwrap(viewModel.operationMessage)
        XCTAssertTrue(message.contains("field separator"), message)
    }

    func testAddingAnItemWithAWhitespaceOnlyTitleIsRefusedAndWritesNothing() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        let outcome = viewModel.addItem(sectionName: "First", id: "a-three", title: "   ", verify: nil)
        XCTAssertEqual(outcome, .emptyTitle)
        XCTAssertFalse(outcome.didFile)
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
        XCTAssertNil(viewModel.item(withID: "a-three"))
        XCTAssertNotNil(viewModel.operationMessage)
    }

    func testAddingAnItemWithAPlainTitleFilesItTrimmed() throws {
        XCTAssertEqual(viewModel.addItem(sectionName: "First", id: "a-three", title: "  A three  ", verify: nil),
                       .filed)
        let line = try XCTUnwrap(lineOnDisk("a-three"))
        XCTAssertTrue(line.contains("a-three | A three"), "the title is stored trimmed: \(line)")
        XCTAssertFalse(line.contains("  A three"), line)
        XCTAssertEqual(viewModel.item(withID: "a-three")?.title, "A three")
    }

    func testAddingAnItemToABacklogThatCannotBeWrittenIsNotReportedAsFiled() throws {
        try FileManager.default.removeItem(at: backlogURL)
        try FileManager.default.createDirectory(at: backlogURL, withIntermediateDirectories: true)

        let outcome = viewModel.addItem(sectionName: "First", id: "a-three", title: "A three", verify: nil)

        guard case .backlogWriteFailed = outcome else {
            return XCTFail("an unwritable BACKLOG.md read as \(outcome)")
        }
        XCTAssertFalse(outcome.didFile)
    }
}
