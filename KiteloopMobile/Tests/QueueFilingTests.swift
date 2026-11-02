import XCTest
@testable import KiteloopMobile

/// An idea filed from the phone's queue: the body says only what was given,
/// and the Mac's answer becomes a draft in the list straight away.
final class QueueFilingTests: XCTestCase {

    func testTheBodyCarriesTheNoteAndGroomOnlyWhenTheySaySomething() {
        let bare = QueueViewModel.filingBody(project: "kiteloop", title: " Fix login ", note: "  ", groom: false)
        XCTAssertEqual(bare as NSDictionary, ["project": "kiteloop", "title": "Fix login"] as NSDictionary)

        let full = QueueViewModel.filingBody(project: "kiteloop", title: "Fix login", note: "Seen on iOS", groom: true)
        XCTAssertEqual(full as NSDictionary,
                       ["project": "kiteloop", "title": "Fix login", "note": "Seen on iOS", "groom": true] as NSDictionary)
    }

    func testTheMacsAnswerIsADraftInTheList() throws {
        let item = try XCTUnwrap(QueueViewModel.filedItem(["item": "fix-login", "epic": "Inbox", "status": "draft"], title: "Fix login"))

        XCTAssertEqual(item.id, "fix-login")
        XCTAssertEqual(item.title, "Fix login")
        XCTAssertEqual(item.status, "draft")
        XCTAssertEqual(item.epic, "Inbox")
        XCTAssertNil(QueueViewModel.filedItem(["error": "Project not open"], title: "x"))
    }

    @MainActor
    func testAFiledItemIsListedUnderItsEpic() throws {
        let model = QueueViewModel()
        model.items = [try XCTUnwrap(QueueViewModel.filedItem(["item": "fix-login", "epic": "Inbox", "status": "draft"], title: "Fix login"))]

        XCTAssertEqual(model.epics.map(\.name), ["Inbox"])
        XCTAssertEqual(model.epics.first?.items.map(\.id), ["fix-login"])
    }
}
