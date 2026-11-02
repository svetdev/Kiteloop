import XCTest
@testable import KiteloopCore

/// The lane: the ordering axis an item carries beside its size, read off the
/// line, written back beside it, and — for a project that spelled its ordering
/// as an epic called `Now` — carried across once by `BacklogLaneMigration`.
///
/// What is pinned here is that `later` costs a line nothing: it is the default,
/// it is never written, and an existing backlog reads and writes back exactly as
/// it did before lanes existed.
final class BacklogLaneTests: XCTestCase {

    // MARK: - The line

    func testALineCarryingLaneNowParsesWithTheLaneSet() {
        let item = BacklogParser.parseItemLine(
            "- [ ] plat-1 | Config loader | size:M | lane:now | ready", verifyDefault: nil)

        XCTAssertEqual(item?.lane, .now)
        XCTAssertEqual(item?.size, .m)
        XCTAssertEqual(item?.status, .ready)
    }

    /// No lane written is `later`, which is what makes every line already in
    /// every backlog a lane-carrying line without being edited.
    func testALineWithNoLaneParsesAsLater() {
        let item = BacklogParser.parseItemLine(
            "- [ ] plat-2 | Config loader | size:M | ready", verifyDefault: nil)

        XCTAssertEqual(item?.lane, .later)
    }

    /// `now` is the only lane a line writes, so anything else is a value the
    /// parser cannot read: it is reported the way `size:Small` is — the field
    /// named, the shape of a readable value given — and the lane is left at
    /// `later` rather than guessed at. `lane:later` is in that set on purpose:
    /// the default is said by leaving the field off.
    func testAnUnreadableLaneIsReportedAndLeftAtLater() {
        for written in ["lane:urgent", "lane:later", "lane:NOW-ish"] {
            let parsed = BacklogParser.parseItemLineWithUnrecognisedFields(
                "- [ ] plat-3 | Config loader | \(written) | ready", verifyDefault: nil)

            XCTAssertEqual(parsed?.item.lane, .later, "\(written) should leave the lane unset")
            XCTAssertEqual(parsed?.unreadable,
                           [BacklogParser.UnreadableValue(field: written, kind: .lane)],
                           "\(written) should be reported as an unreadable value")
            XCTAssertEqual(parsed?.unrecognised, [],
                           "\(written) is a field the parser recognises — only its value is unreadable")
        }
    }

    /// The whole file, not just one line: the issue reaches the panel with the
    /// lane named and the shape of a readable value spelled out.
    func testAnUnreadableLaneIsReportedAsAParseIssue() {
        let result = BacklogParser.parseWithIssues("""
        ---
        project: demo
        ---

        ## Epic: Platform

        - [ ] plat-4 | Config loader | lane:soon | ready
        """)

        let issue = result.issues.first { $0.reason.contains("lane:soon") }
        XCTAssertNotNil(issue, "the unreadable lane should be reported: \(result.issues)")
        XCTAssertTrue(issue?.reason.contains("`lane:now`") == true,
                      "the issue should say what a readable lane looks like: \(issue?.reason ?? "")")
    }

    // MARK: - The written form

    /// Beside `size:`, in the serializer's fixed order.
    func testLaneNowIsWrittenBesideTheSize() {
        let item = BacklogItem(id: "plat-5", title: "Config loader",
                               status: .ready, type: .local, size: .m, lane: .now)

        XCTAssertEqual(BacklogSerializer.serializeItem(item),
                       "- [ ] plat-5 | Config loader | size:M | lane:now | ready")
    }

    /// `later` writes nothing at all, so a backlog that never asked for a lane
    /// is byte-identical after a write-back.
    func testLaterWritesNoLaneField() {
        let item = BacklogItem(id: "plat-6", title: "Config loader",
                               status: .ready, type: .local, size: .m, lane: .later)

        XCTAssertEqual(BacklogSerializer.serializeItem(item),
                       "- [ ] plat-6 | Config loader | size:M | ready")
    }

    /// Both lanes survive the write-and-read the app does on every status flip.
    func testBothLanesRoundTripThroughTheLine() {
        for lane in BacklogLane.allCases {
            let item = BacklogItem(id: "plat-7", title: "Config loader", verify: "swift build",
                                   status: .ready, type: .local, size: .s, lane: lane,
                                   needs: ["plat-1"])
            let reparsed = BacklogParser.parseItemLine(
                BacklogSerializer.serializeItem(item), verifyDefault: nil)

            XCTAssertEqual(reparsed?.lane, lane)
            XCTAssertEqual(reparsed?.needs, ["plat-1"])
            XCTAssertEqual(reparsed?.verify, "swift build")
        }
    }

    // MARK: - The order

    /// Lane first, document order second: a `now` item in the last epic runs
    /// before every `later` one however far up the file it sits, and two `now`
    /// items keep the order they were written in.
    func testOrderedPutsEveryNowItemFirstAndKeepsDocumentOrderWithinALane() {
        let file = BacklogParser.parse("""
        ---
        project: demo
        ---

        ## Epic: Platform

        - [ ] first-later | A | ready
        - [ ] first-now | B | lane:now | ready

        ## Epic: Onboarding

        - [ ] last-later | C | ready
        - [ ] last-now | D | lane:now | ready
        """)

        XCTAssertEqual(BacklogLane.ordered(file.sections.flatMap(\.items)).map(\.id),
                       ["first-now", "last-now", "first-later", "last-later"])
    }

    /// Nothing to promote is nothing reordered.
    func testOrderedLeavesAnAllLaterQueueExactlyAsItWas() {
        let items = ["a", "b", "c"].map {
            BacklogItem(id: $0, title: $0, status: .ready, type: .local)
        }

        XCTAssertEqual(BacklogLane.ordered(items).map(\.id), ["a", "b", "c"])
    }

    // MARK: - The migration off the Now epic

    private static let backlogWithANowEpic = """
    ---
    project: demo
    ---

    # Demo Backlog

    ## Epic: Now

    - [ ] demo-001 | Config loader | size:M | ready
    - [ ] demo-002 | Second thing | ready

    ## Epic: Onboarding

    - [ ] demo-003 | Third thing | ready
    """

    /// Every item under an epic named `Now` comes out marked, and nothing under
    /// any other epic does.
    func testAnEpicNamedNowMarksItsItemsAsLaneNow() throws {
        let migrated = try XCTUnwrap(
            BacklogLaneMigration.migrated(BacklogParser.parse(Self.backlogWithANowEpic)))

        XCTAssertEqual(migrated.sections.flatMap(\.items).filter { $0.lane == .now }.map(\.id),
                       ["demo-001", "demo-002"])
        XCTAssertEqual(migrated.sections.map(\.name), ["Now", "Onboarding"],
                       "the epic keeps its items — moving them home is a person's edit")
    }

    /// The marks are written to the file, so the load after the migration reads
    /// them off the line.
    func testTheMarksAreWrittenBackOntoTheLines() throws {
        let migrated = try XCTUnwrap(
            BacklogLaneMigration.migrated(BacklogParser.parse(Self.backlogWithANowEpic)))
        let written = BacklogSerializer.serialize(migrated)

        XCTAssertTrue(written.contains("- [ ] demo-001 | Config loader | size:M | lane:now | ready"),
                      "the mark should be written beside the size:\n\(written)")
        XCTAssertTrue(written.contains("- [ ] demo-003 | Third thing | ready"),
                      "an item outside the Now epic keeps its line:\n\(written)")

        XCTAssertEqual(BacklogParser.parse(written).sections.flatMap(\.items)
            .filter { $0.lane == .now }.map(\.id), ["demo-001", "demo-002"])
    }

    /// Once, not on every load: the second read finds every item already
    /// marked, answers nil, and so nothing is written back. A migration that
    /// answered non-nil here would rewrite the backlog on every read of it.
    func testASecondLoadOfTheMigratedFileChangesNothing() throws {
        let first = try XCTUnwrap(
            BacklogLaneMigration.migrated(BacklogParser.parse(Self.backlogWithANowEpic)))
        let written = BacklogSerializer.serialize(first)

        XCTAssertNil(BacklogLaneMigration.migrated(BacklogParser.parse(written)))
        XCTAssertEqual(BacklogSerializer.serialize(BacklogParser.parse(written)), written,
                       "the migrated file is stable under a second write-back")
    }

    /// A backlog that never had a Now epic is not touched at all.
    func testAFileWithNoNowEpicIsLeftAlone() {
        XCTAssertNil(BacklogLaneMigration.migrated(BacklogParser.parse("""
        ---
        project: demo
        ---

        ## Epic: Onboarding

        - [ ] demo-003 | Third thing | ready
        """)))
    }
}
