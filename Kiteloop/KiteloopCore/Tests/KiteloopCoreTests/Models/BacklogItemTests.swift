import XCTest
@testable import KiteloopCore

/// The judgements a backlog item's stages and sizes make for the autopilot, and
/// the id a file hands out for new work.
final class BacklogItemTests: XCTestCase {

    // MARK: - Which stages are a person's to set

    /// `done` and `draft` are human decisions, and they are the only two: an
    /// agent passing its own review is not the work being accepted, and filing
    /// work as a draft is grooming. Every stage an agent advances through — and
    /// `blocked`, which is reachable from anywhere — is not human-only, or the
    /// autopilot could not move an item at all.
    func testOnlyDoneAndDraftAreHumanOnly() {
        let humanOnly = Set(BacklogItemStatus.allCases.filter(\.isHumanOnly))

        XCTAssertEqual(humanOnly, [.done, .draft])
    }

    // MARK: - Which sizes the autopilot may pick up

    /// L and XL are broken down first; XS, S and M are runnable. Both bounds
    /// matter: M is the largest size a run may take, and L the smallest it may
    /// not.
    func testOnlyLAndXLAreTooLargeForAutopilot() {
        let tooLarge = Set(ItemSize.allCases.filter(\.isTooLargeForAutopilot))

        XCTAssertEqual(tooLarge, [.l, .xl])
    }

    // MARK: - The next generated id

    /// One past the highest number any id already carries — read off the ids in
    /// use, so a deleted item's number is never handed out twice. A gap in the
    /// sequence is exactly the state a deletion leaves.
    func testNextIDIsOnePastTheHighestNumberInUse() {
        let file = BacklogFile(project: "kiteloop", sections: [
            BacklogSection(name: "Epic", items: [
                item("kiteloop-001"),
                item("kiteloop-007"),
            ]),
        ])

        XCTAssertEqual(file.nextGeneratedItemID(), "kiteloop-008")
    }

    /// Ids that carry no number of this project's are not read as one: another
    /// project's id, an id that is the bare prefix, and one whose suffix is not
    /// a number all leave the count where it was.
    func testIdsThatCarryNoNumberDoNotRaiseTheCount() {
        let file = BacklogFile(project: "kiteloop", sections: [
            BacklogSection(name: "Epic", items: [
                item("other-900"),
                item("kiteloop-"),
                item("kiteloop-abc"),
                item("kiteloop-003"),
            ]),
        ])

        XCTAssertEqual(file.nextGeneratedItemID(), "kiteloop-004")
    }

    /// The first item a project files.
    func testAnEmptyFileStartsAtOne() {
        let file = BacklogFile(project: "kiteloop", sections: [])

        XCTAssertEqual(file.nextGeneratedItemID(), "kiteloop-001")
    }

    /// An id the project used that the file no longer holds — a removed
    /// item's detail file or run history — is read like one in the file.
    func testAnIDTakenElsewhereRaisesTheCount() {
        let file = BacklogFile(project: "kiteloop", sections: [
            BacklogSection(name: "Epic", items: [item("kiteloop-003")]),
        ])

        XCTAssertEqual(file.nextGeneratedItemID(takenElsewhere: ["kiteloop-007", "other-900"]),
                       "kiteloop-008")
    }

    // MARK: - Fixtures

    private func item(_ id: String) -> BacklogItem {
        BacklogItem(id: id, title: "t", status: .ready, type: .local)
    }
}
