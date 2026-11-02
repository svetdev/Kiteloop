import XCTest
import KiteloopCore
@testable import Kiteloop

/// An item's `needs:` could only be changed by editing BACKLOG.md, where a
/// typo, a self-reference or a loop surfaced later as an item pickup withheld.
/// These cases pin `setItemNeeds`: a new list lands on disk with the rest of
/// the line intact, an empty one clears it, an unchanged one writes nothing,
/// and an unknown id, the item itself and a cycle are each refused by name
/// with the file untouched.
@MainActor
final class BacklogViewModelItemNeedsTests: XCTestCase {
    private var tempDir: URL!
    private var backlogURL: URL!
    private var viewModel: BacklogViewModel!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-item-needs")
        backlogURL = tempDir.appending(path: "BACKLOG.md")
        let backlog = """
        # Test Backlog

        ## Epic: First
        - [ ] x | X | verify: make check | size:S | needs:y
        - [ ] y | Y | size:M
        - [ ] a | A | size:S
        - [ ] b | B | size:S
        """
        try backlog.write(to: backlogURL, atomically: true, encoding: .utf8)
        viewModel = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
        viewModel.loadForProject(repoPath: tempDir.path(percentEncoded: false))
    }

    private func onDisk() throws -> String {
        try String(contentsOf: backlogURL, encoding: .utf8)
    }

    private func lineOnDisk(_ id: String) throws -> String? {
        try onDisk().components(separatedBy: "\n").first { $0.contains("] \(id) |") }
    }

    func testSavingAListWritesEveryIdAndKeepsTheRestOfTheLine() throws {
        let before = try XCTUnwrap(viewModel.item(withID: "x"))
        XCTAssertEqual(viewModel.setItemNeeds(itemID: "x", to: "a, b"), .applied)
        let line = try XCTUnwrap(lineOnDisk("x"))
        XCTAssertTrue(line.contains("needs:a,b"), line)
        XCTAssertTrue(line.hasPrefix("- [ ] x | X |"), line)
        XCTAssertTrue(line.contains("verify: make check"), line)
        XCTAssertTrue(line.contains("size:S"), line)
        let after = try XCTUnwrap(viewModel.item(withID: "x"))
        XCTAssertEqual(after.needs, ["a", "b"])
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.verify, before.verify)
        XCTAssertEqual(after.size, before.size)
    }

    func testSpacesCommasAndRepeatsAreOneListInOrder() {
        XCTAssertEqual(viewModel.setItemNeeds(itemID: "x", to: " b a,, b "), .applied)
        XCTAssertEqual(viewModel.item(withID: "x")?.needs, ["b", "a"])
    }

    func testAnEmptyFieldClearsNeeds() throws {
        XCTAssertEqual(viewModel.setItemNeeds(itemID: "x", to: "  "), .applied)
        let line = try XCTUnwrap(lineOnDisk("x"))
        XCTAssertFalse(line.contains("needs:"), line)
        XCTAssertEqual(viewModel.item(withID: "x")?.needs, [])
    }

    func testAnUnknownIdIsRefusedByName() throws {
        let before = try onDisk()
        XCTAssertEqual(viewModel.setItemNeeds(itemID: "x", to: "a, no-such-item"),
                       .unknownDependency("no-such-item"))
        XCTAssertEqual(try onDisk(), before, "BACKLOG.md is untouched")
        XCTAssertTrue(viewModel.operationMessage?.contains("no-such-item") == true,
                      viewModel.operationMessage ?? "no message")
    }

    func testTheItemItselfIsRefused() throws {
        let before = try onDisk()
        XCTAssertEqual(viewModel.setItemNeeds(itemID: "x", to: "x"), .selfDependency)
        XCTAssertEqual(try onDisk(), before)
        XCTAssertTrue(viewModel.operationMessage?.contains("itself") == true,
                      viewModel.operationMessage ?? "no message")
    }

    func testAListThatMakesACycleIsRefusedWithThePath() throws {
        let before = try onDisk()
        XCTAssertEqual(viewModel.setItemNeeds(itemID: "y", to: "x"), .cycle(["y", "x", "y"]))
        XCTAssertEqual(try onDisk(), before, "BACKLOG.md is untouched")
        XCTAssertTrue(viewModel.operationMessage?.contains("y → x → y") == true,
                      viewModel.operationMessage ?? "no message")
    }

    /// The file is changed behind the model first, so a write-back of the
    /// model's copy would show as the edit being undone.
    func testAnUnchangedListIsAppliedWithoutAWrite() throws {
        let edited = try onDisk().replacingOccurrences(of: "] b | B |", with: "] b | B edited |")
        try edited.write(to: backlogURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(viewModel.setItemNeeds(itemID: "x", to: "y"), .applied)
        XCTAssertEqual(try onDisk(), edited, "nothing was written")
    }

    func testAnItemTheBacklogDoesNotHaveIsRefused() throws {
        let before = try onDisk()
        XCTAssertEqual(viewModel.setItemNeeds(itemID: "no-such-item", to: "a"), .unknownItem)
        XCTAssertEqual(try onDisk(), before)
    }
}
