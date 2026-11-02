import XCTest
@testable import KiteloopCore

/// A write-back touches only the lines whose items changed.
///
/// Every edit — a status flip, an approval, a verify edit — writes the whole
/// file, so re-rendering every line from its parsed fields rewrote lines no
/// one touched: the `verify:` the parser filled from `verify_default` landed
/// on each of them, dirtying the diff and pinning the old default into every
/// item so a later change to it reached none.
final class BacklogWriteBackTests: XCTestCase {

    private let backlog = """
    ---
    project: demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] task-1 | First task | ready
    - [ ] task-2 | Second task | ready | size:S
    - [ ] task-4 | Pinned task | lane:now | ready

    ## Epic: Later

    - [ ] task-3 | Third task | draft
    - [ ] task-5 | Own verify | verify: make check | draft
    """

    private func itemLines(_ content: String) -> [String] {
        content.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }
    }

    private func edited(_ id: String, _ change: (inout BacklogItem) -> Void) -> String {
        var file = BacklogParser.parse(backlog)
        for s in file.sections.indices {
            for i in file.sections[s].items.indices where file.sections[s].items[i].id == id {
                change(&file.sections[s].items[i])
            }
        }
        return BacklogSerializer.serialize(file)
    }

    private func item(_ id: String, in content: String) -> BacklogItem? {
        BacklogParser.parse(content).sections.flatMap(\.items).first { $0.id == id }
    }

    // MARK: - Untouched lines

    func testAStatusFlipLeavesEveryOtherLineByteIdentical() {
        let written = edited("task-3") { $0.status = .ready }

        let before = itemLines(backlog)
        let after = itemLines(written)
        XCTAssertEqual(after.count, before.count)
        for (old, new) in zip(before, after) where !old.contains("task-3") {
            XCTAssertEqual(new, old, written)
        }
        XCTAssertTrue(after.contains("- [ ] task-3 | Third task | ready"), written)
        XCTAssertFalse(written.contains("verify: swift build"), written)
    }

    func testAnUnchangedFileWritesBackItsItemLinesAsTheyWere() {
        XCTAssertEqual(itemLines(BacklogSerializer.serialize(BacklogParser.parse(backlog))),
                       itemLines(backlog))
    }

    // MARK: - An item's own verify

    func testAnItemsOwnVerifySurvivesAChangeToItsStatus() {
        let written = edited("task-5") { $0.status = .ready }

        XCTAssertTrue(itemLines(written).contains("- [ ] task-5 | Own verify | verify: make check | ready"), written)
    }

    func testEditingAnOwnVerifyChangesOnlyThatLine() {
        let written = edited("task-5") { $0.verify = "make test" }

        let changed = zip(itemLines(backlog), itemLines(written)).filter { $0.0 != $0.1 }
        XCTAssertEqual(changed.map(\.1), ["- [ ] task-5 | Own verify | verify: make test | draft"], written)
    }

    func testAVerifyEditedAwayFromTheDefaultIsWritten() {
        let written = edited("task-3") { $0.verify = "make lint" }

        XCTAssertTrue(itemLines(written).contains("- [ ] task-3 | Third task | verify: make lint | draft"), written)
    }

    // MARK: - The default is kept, not inherited

    func testTheDefaultLineIsKeptAndNoItemInheritsIt() {
        let written = edited("task-3") { $0.status = .ready }

        XCTAssertTrue(written.components(separatedBy: "\n").contains("verify_default: swift build"), written)
        XCTAssertNil(item("task-1", in: written)?.verify)
        XCTAssertNil(item("task-3", in: written)?.verify, "the edited item too")
        XCTAssertEqual(item("task-5", in: written)?.verify, "make check")
    }

    // MARK: - Lanes

    func testAnUntouchedItemUnderTheNowEpicIsNotGivenALane() {
        let written = edited("task-3") { $0.status = .ready }

        XCTAssertTrue(itemLines(written).contains("- [ ] task-1 | First task | ready"), written)
        XCTAssertEqual(item("task-1", in: written)?.lane, .later)
    }

    func testAnExplicitLaneIsKeptOnAnUntouchedAndAChangedItem() {
        XCTAssertTrue(itemLines(edited("task-3") { $0.status = .ready })
            .contains("- [ ] task-4 | Pinned task | lane:now | ready"))

        let written = edited("task-4") { $0.status = .active }
        XCTAssertTrue(itemLines(written).contains("- [ ] task-4 | Pinned task | lane:now | active"), written)
    }
}
