import XCTest
import KiteloopCore
@testable import Kiteloop

/// Adding or renaming an epic to a name the backlog already holds used to return
/// with no word, so the field that asked for the name closed over an edit that
/// never happened. These cases pin the refusals `addEpic` and `renameEpic` now
/// report — a taken name and an empty one — and that a free name still applies.
/// A description holding a line the backlog file reads as structure is refused
/// the same way, rather than saved to split the epic on the next read.
@MainActor
final class BacklogViewModelEpicNameTests: XCTestCase {
    private var tempDir: URL!
    private var viewModel: BacklogViewModel!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "backlog-epic-name")
        let backlog = """
        # Test Backlog

        ## Epic: First
        - [ ] a-one | A one | verify: true | size:S

        ## Epic: Second
        - [ ] b-one | B one | verify: true | size:S
        """
        try backlog.write(to: tempDir.appending(path: "BACKLOG.md"), atomically: true, encoding: .utf8)
        viewModel = BacklogViewModel(
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
        viewModel.loadForProject(repoPath: tempDir.path(percentEncoded: false))
    }

    private var epicNames: [String] {
        viewModel.backlogFile?.sections.map(\.name) ?? []
    }

    func testAddingAnEpicUnderATakenNameIsRefused() {
        XCTAssertEqual(viewModel.addEpic(name: "Second"), .nameTaken)
        XCTAssertEqual(epicNames, ["First", "Second"], "no second section under the taken name")
        XCTAssertNotNil(viewModel.operationMessage, "the refusal is named beside the backlog")
    }

    func testAddingAnEpicWithAWhitespaceOnlyNameIsRefused() {
        XCTAssertEqual(viewModel.addEpic(name: "   "), .emptyName)
        XCTAssertEqual(epicNames, ["First", "Second"])
        XCTAssertNotNil(viewModel.operationMessage)
    }

    func testAddingAnEpicUnderAFreeNameApplies() {
        XCTAssertEqual(viewModel.addEpic(name: "  Third  "), .applied)
        XCTAssertEqual(epicNames, ["First", "Second", "Third"], "the name is stored trimmed")
        XCTAssertNil(viewModel.operationMessage, "an edit that landed clears the last refusal")
    }

    func testRenamingAnEpicToATakenNameIsRefused() {
        XCTAssertEqual(viewModel.renameEpic(from: "First", to: "Second"), .nameTaken)
        XCTAssertEqual(epicNames, ["First", "Second"], "neither epic's name moves")
        XCTAssertNotNil(viewModel.operationMessage)
    }

    func testRenamingAnEpicToAnEmptyNameIsRefused() {
        XCTAssertEqual(viewModel.renameEpic(from: "First", to: " "), .emptyName)
        XCTAssertEqual(epicNames, ["First", "Second"])
        XCTAssertNotNil(viewModel.operationMessage)
    }

    func testRenamingAnEpicToAFreeNameApplies() {
        XCTAssertEqual(viewModel.renameEpic(from: "First", to: "Foundations"), .applied)
        XCTAssertEqual(epicNames, ["Foundations", "Second"])
        XCTAssertNil(viewModel.operationMessage)
    }

    func testRenamingAnEpicToItsOwnNameIsNothingToRefuse() {
        XCTAssertEqual(viewModel.renameEpic(from: "First", to: "First"), .applied,
                       "nothing changes, and nothing is refused — the field closes")
        XCTAssertEqual(epicNames, ["First", "Second"])
    }

    func testRenamingAnEpicTheBacklogDoesNotHaveIsRefused() {
        XCTAssertEqual(viewModel.renameEpic(from: "No Such Epic", to: "Third"), .unknownEpic)
        XCTAssertEqual(epicNames, ["First", "Second"])
    }

    // MARK: - Descriptions

    private var backlogURL: URL { tempDir.appending(path: "BACKLOG.md") }

    private var itemIDs: [String] {
        viewModel.backlogFile?.sections.flatMap { $0.items.map(\.id) } ?? []
    }

    private func assertDescriptionRefused(_ text: String, quoting line: String,
                                          file: StaticString = #filePath, lineNo: UInt = #line) throws {
        let before = try String(contentsOf: backlogURL, encoding: .utf8)
        XCTAssertEqual(viewModel.updateEpicDescription(name: "First", text: text), .descriptionHoldsStructure,
                       file: file, line: lineNo)
        XCTAssertEqual(try String(contentsOf: backlogURL, encoding: .utf8), before,
                       "nothing is written", file: file, line: lineNo)
        XCTAssertTrue(viewModel.operationMessage?.contains("“\(line)”") == true,
                      viewModel.operationMessage ?? "no message", file: file, line: lineNo)
        XCTAssertNil(viewModel.backlogFile?.sections.first?.description, file: file, line: lineNo)
    }

    func testADescriptionHoldingAHeadingLineIsRefused() throws {
        try assertDescriptionRefused("Some context\n## Notes\nMore", quoting: "## Notes")
    }

    func testADescriptionHoldingAChecklistLineIsRefused() throws {
        try assertDescriptionRefused("Steps:\n  - [ ] x", quoting: "- [ ] x")
    }

    func testADescriptionHoldingABareRuleLineIsRefused() throws {
        try assertDescriptionRefused("Above\n---\nBelow", quoting: "---")
    }

    func testAPlainMultiLineDescriptionAppliesAndReadsBackUnchanged() {
        XCTAssertEqual(viewModel.updateEpicDescription(name: "First", text: "Line one\nLine two - with a dash"),
                       .applied)
        viewModel.reload()
        XCTAssertEqual(epicNames, ["First", "Second"])
        XCTAssertEqual(itemIDs, ["a-one", "b-one"])
        XCTAssertNil(viewModel.operationMessage)
    }

    func testAnAIBarEpicWhoseDescriptionIsRefusedReportsWhy() {
        let failures = BacklogAIEditor.apply(
            [.addEpic(name: "Third", description: "Intro\n## Notes")], to: viewModel)
        XCTAssertEqual(failures.count, 1, failures.joined(separator: "; "))
        XCTAssertTrue(failures.first?.contains("couldn't describe epic “Third”") == true,
                      failures.joined(separator: "; "))
    }
}
