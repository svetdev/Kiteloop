import KiteloopCore
import XCTest
@testable import Kiteloop

/// The join an item's history was missing. Every test here is about the three
/// ledgers agreeing on one order and keeping their reasons intact — the two
/// things that made answering "why has this been run five times" take minutes of
/// shell work and get the answer wrong twice.
final class ItemTimelineTests: XCTestCase {

    // MARK: - Notes

    /// Notes are written newest-first (the writer inserts directly under the
    /// `## Notes` heading), and a timeline reads oldest-first. Getting this
    /// backwards is the difference between "rejected, then released" and
    /// "released, then rejected".
    func testNoteEntriesAreReturnedOldestFirst() {
        let notes = """
        - 2026-08-10 — rejected: AC 3 is unimplemented
        - 2026-08-09 — blocked (review did not pass)
        - 2026-08-08 — Released for autopilot (backlog)
        """

        let changes = ItemTimeline.noteChanges(notes)

        XCTAssertEqual(changes.map(\.kind), [.released, .blocked, .rejected])
    }

    /// A continuation line — a refused approval's verify output — belongs to the
    /// entry above it, not to a bullet of its own.
    func testIndentedContinuationsStayWithTheirEntry() {
        let notes = """
        - 2026-08-10 — rejected: verify failed
          error: cannot find 'Foo' in scope
          exit status 65
        """

        let changes = ItemTimeline.noteChanges(notes)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].detail,
                       "rejected: verify failed\nerror: cannot find 'Foo' in scope\nexit status 65")
    }

    /// Hand-written prose under `## Notes` is common. It is dropped rather than
    /// dated by guesswork: a fabricated timestamp in the one place a person goes
    /// to check facts is worse than a line that isn't listed.
    func testUndatedLinesAreNotGivenAnInventedDate() {
        let notes = """
        - this needs discussing with the reviewer
        - 2026-08-09 — rejected: no tests
        """

        let changes = ItemTimeline.noteChanges(notes)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].detail, "rejected: no tests")
    }

    /// A note carries a date and no clock, and says so — the view prints the
    /// precision it has rather than a time it made up.
    func testNotesAreDayPrecision() {
        let changes = ItemTimeline.noteChanges("- 2026-08-09 — rejected: no tests")

        XCTAssertEqual(changes.first?.precision, .day)
    }

    /// The retirement note is what a person is reacting to when they release an
    /// item, so it has to be findable as a retirement rather than as prose.
    func testRetirementAndReleaseNotesAreClassified() {
        let retired = "\(RetryCeiling.noteMarker) — 3 attempts in a row started and produced no work"

        XCTAssertEqual(ItemTimeline.kind(ofNote: retired), .retired)
        XCTAssertEqual(ItemTimeline.kind(ofNote: RetryCeiling.releaseNote(source: "backlog")),
                       .released)
        XCTAssertEqual(ItemTimeline.kind(ofNote: "rejected: AC 3 unimplemented"), .rejected)
        XCTAssertEqual(ItemTimeline.kind(ofNote: "something nobody has a rule for"), .note)
    }

    // MARK: - The join

    /// The whole point: three ledgers, one ordered list, each entry still saying
    /// which one it came from.
    func testChangesFromEveryLedgerAreMergedInOrder() {
        // The ledger timestamps are placed relative to the same local midnight
        // the note parses to. A note carries a date and no zone, so it is a
        // *local* day — pinning the fixture to UTC instead would make this test
        // pass or fail depending on where it runs.
        let day = localMidnight("2026-08-09")
        let notes = "- 2026-08-09 — rejected: AC 3 is unimplemented"
        let approvals = [
            ItemApprovalEvent(projectPath: "/tmp/p", projectName: "p", itemID: "i",
                              kind: .approved, at: day.addingTimeInterval(3 * 3600))
        ]
        let grooming = [
            GroomingRecord(at: day.addingTimeInterval(-86_400), projectPath: "/tmp/p",
                           projectName: "p", itemID: "i", event: .filedReady)
        ]

        let changes = ItemTimeline.changes(notes: notes, approvals: approvals, grooming: grooming)

        XCTAssertEqual(changes.map(\.source), [.grooming, .notes, .approvals])
        XCTAssertEqual(changes.map(\.kind), [.filed, .rejected, .approved])
    }

    /// A pre-run refusal is the answer to "why did this never run", so the check
    /// that refused it and the clause it failed both survive the join.
    func testCheckFailuresKeepTheirCheckAndReason() {
        let record = GroomingRecord(
            at: Date(timeIntervalSince1970: 1_770_000_000), projectPath: "/tmp/p",
            projectName: "p", itemID: "i", event: .checkFailed,
            check: GroomingRecord.Check.definitionOfReady,
            reason: "no verify command")

        let changes = ItemTimeline.changes(notes: nil, approvals: [], grooming: [record])

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .refused)
        XCTAssertEqual(changes[0].detail, "definition-of-ready: no verify command")
    }

    /// An item nothing has happened to renders as an empty list, not as a crash
    /// or an invented row.
    func testAnItemWithNoHistoryHasNoChanges() {
        XCTAssertTrue(ItemTimeline.changes(notes: nil, approvals: [], grooming: []).isEmpty)
    }

    // MARK: - Fixtures

    /// The instant a `yyyy-MM-dd` note stamp resolves to here — the same
    /// formatter settings `ItemTimeline` parses with.
    private func localMidnight(_ stamp: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.date(from: stamp)!
    }
}
