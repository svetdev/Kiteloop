import XCTest
import KiteloopCore
@testable import Kiteloop

/// An item's `verify:` could only be changed by a groom, the AI bar or by
/// hand. These cases pin `setItemVerify`: a new command lands on disk with the
/// rest of the line intact, an item without a verify gains one, and a blank
/// command, one holding the line's field separator, and an unknown id are each
/// refused by name rather than looking saved.
@MainActor
final class BacklogViewModelItemVerifyTests: XCTestCase {
    private var tempDir: URL!
    private var backlogURL: URL!
    private var viewModel: BacklogViewModel!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-item-verify")
        backlogURL = tempDir.appending(path: "BACKLOG.md")
        let backlog = """
        # Test Backlog

        ## Epic: First
        - [ ] a-one | A one | verify: make check | size:S | needs:a-two
        - [ ] a-two | A two | size:M
        """
        try backlog.write(to: backlogURL, atomically: true, encoding: .utf8)
        viewModel = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
        viewModel.loadForProject(repoPath: tempDir.path(percentEncoded: false))
    }

    private func lineOnDisk(_ id: String) throws -> String? {
        try String(contentsOf: backlogURL, encoding: .utf8)
            .components(separatedBy: "\n")
            // The item's own id field, not any line that mentions it: `a-one`
            // carries `needs:a-two`, which a bare "a-two |" also matches.
            .first { $0.contains("] \(id) |") }
    }

    func testSettingAVerifyWritesTheNewCommandAndKeepsTheRestOfItsLine() throws {
        let status = viewModel.item(withID: "a-one")?.status
        XCTAssertEqual(viewModel.setItemVerify(itemID: "a-one", to: "  make test|tee log  "), .applied)
        let line = try XCTUnwrap(lineOnDisk("a-one"))
        XCTAssertTrue(line.contains("verify: make test|tee log"), "the command is stored trimmed: \(line)")
        XCTAssertFalse(line.contains("make check"), line)
        XCTAssertTrue(line.hasPrefix("- [ ] a-one | A one |"), line)
        XCTAssertTrue(line.contains("size:S"), line)
        XCTAssertTrue(line.contains("needs:a-two"), line)
        XCTAssertEqual(viewModel.item(withID: "a-one")?.verify, "make test|tee log")
        XCTAssertEqual(viewModel.item(withID: "a-one")?.status, status)
    }

    func testAnItemWithoutAVerifyGainsOne() throws {
        XCTAssertEqual(viewModel.setItemVerify(itemID: "a-two", to: "true"), .applied)
        let line = try XCTUnwrap(lineOnDisk("a-two"))
        XCTAssertTrue(line.contains("verify: true"), line)
        XCTAssertEqual(viewModel.item(withID: "a-two")?.verify, "true")
    }

    func testAWhitespaceOnlyVerifyIsRefused() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertEqual(viewModel.setItemVerify(itemID: "a-one", to: "   "), .emptyVerify)
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
        XCTAssertEqual(viewModel.item(withID: "a-one")?.verify, "make check")
        XCTAssertTrue(viewModel.operationMessage?.contains("can't be empty") == true,
                      viewModel.operationMessage ?? "no message")
    }

    func testAVerifyHoldingTheFieldSeparatorIsRefused() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertEqual(viewModel.setItemVerify(itemID: "a-one", to: "make test | tee log"), .holdsFieldSeparator)
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before, "BACKLOG.md is untouched")
        XCTAssertEqual(viewModel.item(withID: "a-one")?.verify, "make check")
        XCTAssertTrue(viewModel.operationMessage?.contains("field separator") == true,
                      viewModel.operationMessage ?? "no message")
    }

    func testAVerifyForAnItemTheBacklogDoesNotHaveIsRefused() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertEqual(viewModel.setItemVerify(itemID: "no-such-item", to: "true"), .unknownItem)
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
        XCTAssertNotNil(viewModel.operationMessage)
    }

    func testSettingAnItemsOwnVerifyIsNothingToRefuse() throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertEqual(viewModel.setItemVerify(itemID: "a-one", to: "make check"), .applied,
                       "nothing changes, and nothing is refused — the field closes")
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before)
    }
}
