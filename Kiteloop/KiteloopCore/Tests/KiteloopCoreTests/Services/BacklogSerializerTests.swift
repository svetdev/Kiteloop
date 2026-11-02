import XCTest
@testable import KiteloopCore

/// The serializer's own choices about the written form. The field-by-field
/// round trip lives in `BacklogRoundTripTests`; these pin what `serializeItem`
/// itself puts on the line, and how far its round-trip refusal reads.
final class BacklogSerializerTests: XCTestCase {

    // MARK: - The jira line form

    /// A jira item is written in the explicit `JIRA:<key>` form. The parser
    /// also accepts a bare canonical key, but the explicit prefix is the form
    /// the serializer promises: it says "jira" without relying on the key's
    /// shape, and it is what keeps repeated write-backs byte-stable against
    /// the lines the examples and existing backlogs carry.
    func testAJiraItemIsWrittenInTheExplicitJiraForm() {
        let item = BacklogItem(
            id: "PROJ-123", title: "Sync the widget",
            status: .ready, type: .jira, jiraKey: "PROJ-123"
        )
        let line = BacklogSerializer.serializeItem(item)
        XCTAssertTrue(line.hasPrefix("- [ ] JIRA:PROJ-123 | "),
                      "expected the explicit JIRA: form, got: \(line)")
    }

    /// The team marker on an in-flight jira item survives the write-back.
    /// Dropping it would silently move the item out of the team lane on the
    /// next status flip.
    func testTeamOnAnInFlightJiraItemSurvivesTheWriteBack() {
        let item = BacklogItem(
            id: "PROJ-9", title: "Escalate the flaky sync",
            status: .ready, type: .jira, jiraKey: "PROJ-9", team: "team"
        )
        let parsed = BacklogParser.parseItemLine(
            BacklogSerializer.serializeItem(item), verifyDefault: nil)
        XCTAssertEqual(parsed?.team, "team")
        XCTAssertEqual(parsed?.status, .ready)
        XCTAssertEqual(parsed?.jiraKey, "PROJ-9")
    }

    // MARK: - The round-trip refusal reads the whole item

    /// The reconciliation compares every field of what the line would read
    /// back as, not just the field that was edited. Here the edit is lossy in
    /// exactly one field — a trailing space the line format cannot carry,
    /// since the parser trims every field — and nothing else about the line
    /// drifts, so only the field comparison itself can catch it. The refusal
    /// is the same as for a spaced pipe: the last known-good line stands.
    func testAnEditLossyInOnlyOneFieldStillKeepsTheExistingLine() {
        let originalLine = "- [ ] plat-9 | Config loader | verify: swift build | ready"
        var item = BacklogParser.parseItemLine(originalLine, verifyDefault: nil)!
        item.verify = "swift build "

        XCTAssertEqual(BacklogSerializer.serializeItem(item), originalLine,
                       "a value the parser would read back differently must not land")
    }

    // MARK: - A kept line is reported

    private func makeKeptLineReport() throws -> (NotificationStore, StoreProblemReporter, BacklogKeptLineReport) {
        _ = try redirectSharedLoggerToTemporaryDirectory(prefix: "kept-line-log")
        let dir = try makeTemporaryDirectory(prefix: "kept-line")
        let inbox = NotificationStore(notificationsURL: dir.appending(path: "inbox.log"))
        let reporter = StoreProblemReporter(notifications: inbox)
        let report = BacklogKeptLineReport(reporter: reporter, url: dir.appending(path: "BACKLOG.md"))
        return (inbox, reporter, report)
    }

    private func lossyEdit() -> (line: String, item: BacklogItem) {
        let originalLine = "- [ ] plat-9 | Config loader | verify: swift build | ready"
        var item = BacklogParser.parseItemLine(originalLine, verifyDefault: nil)!
        item.verify = "swift build "
        item.status = .active
        return (originalLine, item)
    }

    /// Keeping the line means the item's status change never lands, so the
    /// write says so in the inbox — naming the item — rather than only in the
    /// system log.
    func testAKeptLineIsReportedOnceNamingTheItem() async throws {
        let (inbox, reporter, report) = try makeKeptLineReport()
        let (originalLine, item) = lossyEdit()

        XCTAssertEqual(BacklogSerializer.$keptLines.withValue(report) { BacklogSerializer.serializeItem(item) }, originalLine)
        await reporter.drain()

        let pending = await inbox.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.title, "Could not write backlog")
        XCTAssertTrue(pending.first?.body.contains("plat-9") ?? false,
                      "the report must name the item: \(pending.first?.body ?? "nil")")
    }

    /// Every save rewrites every line, so the same kept line is met on every
    /// write; it is news only the first time.
    func testWritingTheSameItemAgainReportsNothingNew() async throws {
        let (inbox, reporter, report) = try makeKeptLineReport()
        let (_, item) = lossyEdit()

        _ = BacklogSerializer.$keptLines.withValue(report) { BacklogSerializer.serializeItem(item) }
        await reporter.drain()
        let first = await inbox.pending().map(\.id)

        let file = BacklogFile(project: "plat", sections: [BacklogSection(name: "Core", items: [item])])
        _ = BacklogSerializer.$keptLines.withValue(report) { BacklogSerializer.serialize(file) }
        await reporter.drain()

        let after = await inbox.pending().map(\.id)
        XCTAssertEqual(after, first, "a second write of the same kept line must not file or refresh a row")
    }

    /// An item whose new line reads back as itself is written, and nothing is
    /// reported.
    func testAnItemThatRoundTripsCleanlyReportsNothing() async throws {
        let (inbox, reporter, report) = try makeKeptLineReport()
        var item = BacklogParser.parseItemLine(
            "- [ ] plat-9 | Config loader | verify: swift build | ready", verifyDefault: nil)!
        item.status = .active

        let line = BacklogSerializer.$keptLines.withValue(report) { BacklogSerializer.serializeItem(item) }
        await reporter.drain()

        XCTAssertTrue(line.hasSuffix("| active"), "the change must land: \(line)")
        let pending = await inbox.pending()
        XCTAssertTrue(pending.isEmpty)
    }
}
