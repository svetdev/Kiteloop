import XCTest
@testable import Kiteloop

/// What an epic shows under its header: the editor while its description is
/// being edited, the description when it has one, otherwise nothing.
final class EpicBacklogDescriptionTests: XCTestCase {

    func testEpicWithADescriptionShowsIt() {
        XCTAssertEqual(EpicBacklogView.epicDescriptionLine(epicName: "Search", description: "Find anything",
                                                           editingEpic: nil),
                       .text("Find anything"))
    }

    func testEpicWithNoDescriptionShowsNothing() {
        XCTAssertEqual(EpicBacklogView.epicDescriptionLine(epicName: "Search", description: nil,
                                                           editingEpic: nil),
                       .hidden)
    }

    /// An empty description is not drawn as a blank, tappable line.
    func testEpicWithAnEmptyDescriptionShowsNothing() {
        XCTAssertEqual(EpicBacklogView.epicDescriptionLine(epicName: "Search", description: "",
                                                           editingEpic: nil),
                       .hidden)
    }

    /// "Add Description" opens the editor on an epic that has none yet.
    func testEpicBeingEditedShowsTheEditorEvenWithoutADescription() {
        XCTAssertEqual(EpicBacklogView.epicDescriptionLine(epicName: "Search", description: nil,
                                                           editingEpic: "Search"),
                       .editor)
    }

    func testEpicBeingEditedShowsTheEditorInPlaceOfItsDescription() {
        XCTAssertEqual(EpicBacklogView.epicDescriptionLine(epicName: "Search", description: "Find anything",
                                                           editingEpic: "Search"),
                       .editor)
    }

    /// Editing one epic's description leaves every other epic's as it was.
    func testAnotherEpicBeingEditedLeavesThisOnesDescriptionShowing() {
        XCTAssertEqual(EpicBacklogView.epicDescriptionLine(epicName: "Search", description: "Find anything",
                                                           editingEpic: "Merge"),
                       .text("Find anything"))
    }
}
