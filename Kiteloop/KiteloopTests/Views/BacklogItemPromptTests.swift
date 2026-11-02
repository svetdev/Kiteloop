import XCTest
import KiteloopCore
@testable import Kiteloop

/// Run in Current Agent types a backlog item into the selected agent's input:
/// what the groomed detail says the work is, how to check it, and the budget.
/// A field the detail left empty is left out rather than printed blank.
@MainActor
final class BacklogItemPromptTests: XCTestCase {

    private let item = BacklogItem(id: "add-export", title: "Export a chat",
                                   verify: "swift test --filter Export", status: .ready, type: .local)

    func testAGroomedItemCarriesItsWholeDetail() {
        let detail = BacklogItemDetail(
            id: "add-export", title: "Export a chat",
            verifyCommands: [.init(name: "unit", cmd: "swift test"), .init(name: "lint", cmd: "swiftlint")],
            why: "People want to keep a conversation.",
            acceptanceCriteria: ["Saves Markdown", "Shows a failure"],
            outOfScope: ["PDF"],
            what: "Add Export Chat…", approach: "Reuse the exporter.")

        let prompt = MainWindow.backlogItemPrompt(item, detail: detail)

        XCTAssertEqual(prompt, """
            Working on add-export: Export a chat

            What: Add Export Chat…

            Suggested approach: Reuse the exporter.
            Why: People want to keep a conversation.
            Validation: Saves Markdown; Shows a failure
            Out of scope: PDF
            Verify:
              unit: swift test
              lint: swiftlint
            Budget: stop after $50 or 100 queries.
            """)
    }

    func testADetailWithEmptyFieldsLeavesThemOut() {
        let detail = BacklogItemDetail(id: "add-export", title: "Export a chat", verifyCommands: [],
                                       acceptanceCriteria: [], outOfScope: [])

        XCTAssertEqual(MainWindow.detailProse(detail), "")
        XCTAssertEqual(MainWindow.detailLists(detail), "")
        XCTAssertEqual(MainWindow.backlogItemPrompt(item, detail: detail),
                       "Working on add-export: Export a chat\nBudget: stop after $50 or 100 queries.")
    }

    /// Only the fields that are there: a detail with a What and criteria but no
    /// approach, reason, exclusions or commands.
    func testAPartlyGroomedDetailNamesOnlyWhatItHas() {
        let detail = BacklogItemDetail(id: "add-export", title: "Export a chat", verifyCommands: [],
                                       acceptanceCriteria: ["Saves Markdown"], outOfScope: [],
                                       what: "Add Export Chat…")

        XCTAssertEqual(MainWindow.detailProse(detail), "\n\nWhat: Add Export Chat…")
        XCTAssertEqual(MainWindow.detailLists(detail), "\nValidation: Saves Markdown")
    }

    /// An ungroomed item has only its line: its own verify command, or the
    /// default one when the line names none.
    func testAnItemWithNoDetailFallsBackToItsLinesVerify() {
        XCTAssertEqual(MainWindow.backlogItemPrompt(item, detail: nil), """
            Working on add-export: Export a chat
            Verify: swift test --filter Export
            Budget: stop after $50 or 100 queries.
            """)

        let bare = BacklogItem(id: "tidy", title: "Tidy up", status: .ready, type: .local)
        XCTAssertTrue(MainWindow.backlogItemPrompt(bare, detail: nil)
            .contains("\nVerify: swift build -scheme Kiteloop && swift test\n"))
    }
}
