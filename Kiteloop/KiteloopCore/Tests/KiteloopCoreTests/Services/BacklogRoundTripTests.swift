import XCTest
@testable import KiteloopCore

/// Backlog.md is the source of truth and every AI edit rewrites the whole file,
/// so `parse ∘ serialize` losing a field silently deletes it from the user's
/// backlog. These tests pin the round trip for each field the format carries.
final class BacklogRoundTripTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(
        id: String = "demo-001",
        title: String = "Some piece of work",
        verify: String? = nil,
        status: BacklogItemStatus = .ready,
        type: BacklogItemType = .local,
        size: ItemSize? = nil,
        queries: Int? = nil,
        cost: Double? = nil,
        completedDate: String? = nil,
        blockedReason: String? = nil,
        jiraKey: String? = nil,
        team: String? = nil,
        detailPath: String? = nil,
        from: String? = nil,
        needs: [String] = [],
        touches: [String] = [],
        unrecognisedFields: [String] = []
    ) -> BacklogItem {
        BacklogItem(
            id: id, title: title, verify: verify, status: status, type: type,
            size: size, queries: queries, cost: cost, completedDate: completedDate,
            blockedReason: blockedReason, jiraKey: jiraKey, team: team,
            detailPath: detailPath, from: from, needs: needs, touches: touches,
            unrecognisedFields: unrecognisedFields
        )
    }

    /// serialize → parse a single item line.
    private func roundTrip(_ item: BacklogItem, verifyDefault: String? = nil) -> BacklogItem? {
        BacklogParser.parseItemLine(
            BacklogSerializer.serializeItem(item),
            verifyDefault: verifyDefault
        )
    }

    private func assertItemsEqual(
        _ actual: BacklogItem?,
        _ expected: BacklogItem,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("item did not survive the round trip. \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual.id, expected.id, "id. \(message)", file: file, line: line)
        XCTAssertEqual(actual.title, expected.title, "title. \(message)", file: file, line: line)
        XCTAssertEqual(actual.verify, expected.verify, "verify. \(message)", file: file, line: line)
        XCTAssertEqual(actual.status, expected.status, "status. \(message)", file: file, line: line)
        XCTAssertEqual(actual.type, expected.type, "type. \(message)", file: file, line: line)
        XCTAssertEqual(actual.size, expected.size, "size. \(message)", file: file, line: line)
        XCTAssertEqual(actual.queries, expected.queries, "queries. \(message)", file: file, line: line)
        XCTAssertEqual(actual.cost, expected.cost, "cost. \(message)", file: file, line: line)
        XCTAssertEqual(actual.completedDate, expected.completedDate, "completedDate. \(message)", file: file, line: line)
        XCTAssertEqual(actual.blockedReason, expected.blockedReason, "blockedReason. \(message)", file: file, line: line)
        XCTAssertEqual(actual.jiraKey, expected.jiraKey, "jiraKey. \(message)", file: file, line: line)
        XCTAssertEqual(actual.detailPath, expected.detailPath, "detailPath. \(message)", file: file, line: line)
        XCTAssertEqual(actual.from, expected.from, "from. \(message)", file: file, line: line)
        XCTAssertEqual(actual.needs, expected.needs, "needs. \(message)", file: file, line: line)
        XCTAssertEqual(actual.touches, expected.touches, "touches. \(message)", file: file, line: line)
        XCTAssertEqual(actual.unrecognisedFields, expected.unrecognisedFields,
                       "unrecognisedFields. \(message)", file: file, line: line)
    }

    // MARK: - Statuses

    func testEveryStatusRoundTrips() {
        for status in BacklogItemStatus.allCases {
            let item = makeItem(id: "s-1", title: "Stage \(status.rawValue)", status: status)
            assertItemsEqual(roundTrip(item), item, "status \(status.rawValue)")
        }
    }

    func testBlockedReasonRoundTrips() {
        let item = makeItem(status: .blocked, blockedReason: "waiting on upstream API")
        assertItemsEqual(roundTrip(item), item)
    }

    func testBlockedWithoutReasonRoundTrips() {
        let item = makeItem(status: .blocked)
        let parsed = roundTrip(item)
        XCTAssertEqual(parsed?.status, .blocked)
        XCTAssertNil(parsed?.blockedReason)
    }

    /// The `[x]` checkbox — not a status token — is what carries `done`.
    func testDoneIsCarriedByTheCheckbox() {
        let line = BacklogSerializer.serializeItem(makeItem(status: .done))
        XCTAssertTrue(line.hasPrefix("- [x] "), "expected a checked box, got: \(line)")
        XCTAssertEqual(BacklogParser.parseItemLine(line, verifyDefault: nil)?.status, .done)
    }

    func testDoneMetricsRoundTrip() {
        let item = makeItem(
            status: .done, queries: 42, cost: 3.75, completedDate: "2026-01-15"
        )
        assertItemsEqual(roundTrip(item), item)
    }

    // MARK: - Sizes

    func testEverySizeRoundTrips() {
        for size in ItemSize.allCases {
            let item = makeItem(id: "sz-1", title: "Sized \(size.rawValue)", size: size)
            assertItemsEqual(roundTrip(item), item, "size \(size.rawValue)")
        }
    }

    func testMissingSizeStaysNil() {
        XCTAssertNil(roundTrip(makeItem(size: nil))?.size)
    }

    // MARK: - Verify commands

    func testVerifyCommandWithFlagsRoundTrips() {
        let item = makeItem(
            verify: "xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination \"platform=macOS\" test"
        )
        assertItemsEqual(roundTrip(item), item)
    }

    func testVerifyCommandSurvivesAlongsideSizeAndStatus() {
        let item = makeItem(verify: "swift test --filter BacklogRoundTripTests", status: .active, size: .m)
        assertItemsEqual(roundTrip(item), item)
    }

    func testVerifyDefaultFillsItemsThatHaveNone() {
        let parsed = roundTrip(makeItem(verify: nil), verifyDefault: "make check")
        XCTAssertEqual(parsed?.verify, "make check")
    }

    func testExplicitVerifyBeatsTheDefault() {
        let item = makeItem(verify: "swift build")
        XCTAssertEqual(roundTrip(item, verifyDefault: "make check")?.verify, "swift build")
    }

    // MARK: - Detail links

    func testDetailLinkRoundTripsWithEveryOtherField() {
        let item = makeItem(
            verify: "swift test", status: .inReview, size: .s,
            detailPath: "backlog/demo-001.md"
        )
        assertItemsEqual(roundTrip(item), item)
    }

    func testDetailLinkOnDoneItemRoundTrips() {
        let item = makeItem(
            status: .done, queries: 7, cost: 0.42, completedDate: "2026-02-01",
            detailPath: "backlog/demo-001.md"
        )
        assertItemsEqual(roundTrip(item), item)
    }

    func testMissingDetailLinkStaysNil() {
        XCTAssertNil(roundTrip(makeItem())?.detailPath)
    }

    // MARK: - Provenance

    func testProvenanceRoundTrips() {
        let item = makeItem(from: "big-parent-item")
        XCTAssertTrue(
            BacklogSerializer.serializeItem(item).contains("from:big-parent-item"),
            BacklogSerializer.serializeItem(item)
        )
        assertItemsEqual(roundTrip(item), item)
    }

    func testProvenanceSurvivesAlongsideEveryOtherFieldOnTheLine() {
        let item = makeItem(
            verify: "swift test --filter BacklogRoundTripTests", status: .inReview,
            size: .m, detailPath: "backlog/demo-001.md", from: "backlog-item-dependencies"
        )
        assertItemsEqual(roundTrip(item), item)
    }

    func testProvenanceOnADoneItemRoundTripsAlongsideItsMetrics() {
        let item = makeItem(
            status: .done, queries: 12, cost: 1.25, completedDate: "2026-03-04",
            from: "l-parent"
        )
        assertItemsEqual(roundTrip(item), item)
    }

    /// A parent no longer in the file is a record, not a dangling reference —
    /// parents get done and eventually archived, and the child still says where
    /// it came from.
    func testProvenanceNamingAnIDNotInTheFileIsKept() {
        let file = BacklogFile(
            project: "demo", repo: nil, verifyDefault: nil,
            sections: [BacklogSection(name: "Now", items: [
                makeItem(id: "child", title: "Split out of something archived", from: "long-gone")
            ])]
        )
        let reparsed = BacklogParser.parse(BacklogSerializer.serialize(file))
        XCTAssertEqual(reparsed.sections.first?.items.first?.from, "long-gone")
    }

    func testMissingProvenanceStaysNil() {
        XCTAssertNil(roundTrip(makeItem())?.from)
        XCTAssertFalse(BacklogSerializer.serializeItem(makeItem()).contains("from:"))
    }

    /// A hand-written `from:` with the spacing of `verify: ` reads the same as
    /// the tight form the serializer writes.
    func testProvenanceIsReadWithOrWithoutASpaceAfterTheColon() {
        let spaced = BacklogParser.parseItemLine(
            "- [ ] child | Split out | from: parent-item | ready", verifyDefault: nil)
        XCTAssertEqual(spaced?.from, "parent-item")
        XCTAssertEqual(spaced?.status, .ready, "the stage still parses next to it")
    }

    /// An empty token is no provenance rather than an empty one — otherwise the
    /// next write would put a bare `from:` back on the line forever.
    func testAnEmptyProvenanceTokenIsDropped() {
        let parsed = BacklogParser.parseItemLine(
            "- [ ] child | Split out | from: | ready", verifyDefault: nil)
        XCTAssertNil(parsed?.from)
    }

    // MARK: - Sequencing

    func testDependencyRoundTrips() {
        let item = makeItem(needs: ["run-output-pr"])
        XCTAssertTrue(
            BacklogSerializer.serializeItem(item).contains("needs:run-output-pr"),
            BacklogSerializer.serializeItem(item)
        )
        assertItemsEqual(roundTrip(item), item)
    }

    func testSeveralDependenciesRoundTripAsOneCommaSeparatedToken() {
        let item = makeItem(needs: ["first", "second", "third"])
        XCTAssertTrue(
            BacklogSerializer.serializeItem(item).contains("needs:first,second,third"),
            BacklogSerializer.serializeItem(item)
        )
        assertItemsEqual(roundTrip(item), item)
    }

    func testDependencySurvivesAlongsideEveryOtherFieldOnTheLine() {
        let item = makeItem(
            verify: "swift test --filter BacklogRoundTripTests", status: .inReview,
            size: .m, detailPath: "backlog/demo-001.md", from: "backlog-item-dependencies",
            needs: ["run-output-pr", "another-prerequisite"]
        )
        assertItemsEqual(roundTrip(item), item)
    }

    func testMissingDependencyStaysEmpty() {
        XCTAssertEqual(roundTrip(makeItem())?.needs, [])
        XCTAssertFalse(BacklogSerializer.serializeItem(makeItem()).contains("needs:"))
    }

    /// An id naming nothing is a readiness failure, not a parse failure — the
    /// line still has to survive a write-back, or a typo would delete the item
    /// instead of reporting it.
    func testADependencyNamingAnIDNotInTheFileIsKept() {
        let file = BacklogFile(
            project: "demo", repo: nil, verifyDefault: nil,
            sections: [BacklogSection(name: "Now", items: [
                makeItem(id: "dependent", title: "Waits on a typo", needs: ["run-outupt-pr"])
            ])]
        )
        let reparsed = BacklogParser.parse(BacklogSerializer.serialize(file))
        XCTAssertEqual(reparsed.sections.first?.items.first?.needs, ["run-outupt-pr"])
    }

    /// A hand-written `needs:` with the spacing of `verify: ` reads the same as
    /// the tight form the serializer writes.
    func testDependenciesAreReadWithOrWithoutSpaces() {
        let spaced = BacklogParser.parseItemLine(
            "- [ ] child | Waits | needs: first, second | ready", verifyDefault: nil)
        XCTAssertEqual(spaced?.needs, ["first", "second"])
        XCTAssertEqual(spaced?.status, .ready, "the stage still parses next to it")
    }

    /// An empty token is no dependency rather than an unnamed one — otherwise the
    /// next write would put a bare `needs:` back on the line forever.
    func testAnEmptyDependencyTokenIsDropped() {
        XCTAssertEqual(
            BacklogParser.parseItemLine("- [ ] child | Waits | needs: | ready",
                                        verifyDefault: nil)?.needs, [])
        XCTAssertEqual(
            BacklogParser.parseItemLine("- [ ] child | Waits | needs: first, , | ready",
                                        verifyDefault: nil)?.needs, ["first"])
    }

    /// `blocked:` reasons are free text and routinely start with the word
    /// "needs" — the stage token must still win.
    func testABlockedReasonBeginningWithNeedsIsNotADependency() {
        let parsed = BacklogParser.parseItemLine(
            "- [ ] child | Stuck | blocked:needs a contacts entitlement", verifyDefault: nil)
        XCTAssertEqual(parsed?.status, .blocked)
        XCTAssertEqual(parsed?.blockedReason, "needs a contacts entitlement")
        XCTAssertEqual(parsed?.needs, [])
    }

    // MARK: - Jira items

    func testJiraItemRoundTrips() {
        let item = makeItem(
            id: "PROJ-123", title: "Wire up SSO", verify: "swift build",
            status: .ready, type: .jira, size: .m, jiraKey: "PROJ-123"
        )
        assertItemsEqual(roundTrip(item), item)
    }

    /// A local id that merely looks shouty must not be promoted to a Jira item.
    func testLocalIdIsNotMistakenForAJiraKey() {
        let item = makeItem(id: "backlog-refactor-2", title: "Tidy up")
        let parsed = roundTrip(item)
        XCTAssertEqual(parsed?.type, .local)
        XCTAssertNil(parsed?.jiraKey)
    }

    // MARK: - Whole-file round trips

    private func makeFile() -> BacklogFile {
        BacklogFile(
            project: "demo",
            repo: "/Users/demo/code/demo",
            verifyDefault: "swift build",
            sections: [
                BacklogSection(
                    name: "Onboarding",
                    description: "Everything a new user sees on first launch.",
                    items: [
                        makeItem(id: "demo-001", title: "Welcome screen",
                                 verify: "swift build", status: .ready, size: .s,
                                 detailPath: "backlog/demo-001.md"),
                        makeItem(id: "demo-002", title: "Account setup",
                                 verify: "swift test", status: .active, size: .m,
                                 from: "demo-001", needs: ["demo-001"]),
                        makeItem(id: "demo-003", title: "Import contacts",
                                 verify: "swift build", status: .blocked, size: .xs,
                                 blockedReason: "needs a contacts entitlement")
                    ]
                ),
                BacklogSection(
                    name: "Billing",
                    items: [
                        makeItem(id: "demo-004", title: "Stripe integration",
                                 verify: "swift build", status: .done,
                                 size: .l, queries: 18, cost: 2.50,
                                 completedDate: "2026-01-30"),
                        makeItem(id: "PROJ-77", title: "Invoice PDFs",
                                 verify: "swift build", status: .draft,
                                 type: .jira, size: .xl, jiraKey: "PROJ-77")
                    ]
                ),
                BacklogSection(
                    name: "Bugs",
                    description: "Anything user-visible and broken.",
                    items: [
                        makeItem(id: "demo-005", title: "Crash on empty project",
                                 verify: "swift build", status: .awaitingApproval,
                                 size: .xs, detailPath: "backlog/demo-005.md")
                    ]
                )
            ]
        )
    }

    func testWholeFileRoundTripsLosslessly() {
        let original = makeFile()
        let reparsed = BacklogParser.parse(BacklogSerializer.serialize(original))

        XCTAssertEqual(reparsed.project, original.project)
        XCTAssertEqual(reparsed.repo, original.repo)
        XCTAssertEqual(reparsed.verifyDefault, original.verifyDefault)
        XCTAssertEqual(reparsed.sections.map(\.name), ["Onboarding", "Billing", "Bugs"])
        XCTAssertEqual(reparsed.sections.map(\.description), original.sections.map(\.description))

        for (section, expectedSection) in zip(reparsed.sections, original.sections) {
            XCTAssertEqual(section.items.count, expectedSection.items.count, "item count in \(section.name)")
            for (item, expected) in zip(section.items, expectedSection.items) {
                assertItemsEqual(item, expected, "\(section.name)/\(expected.id)")
            }
        }
    }

    /// The autopilot rewrites Backlog.md on every status change, so serializing
    /// an already-round-tripped file must not keep mutating the text.
    func testSerializedTextIsStableAcrossRepeatedRoundTrips() {
        let first = BacklogSerializer.serialize(makeFile())
        let second = BacklogSerializer.serialize(BacklogParser.parse(first))
        let third = BacklogSerializer.serialize(BacklogParser.parse(second))

        XCTAssertEqual(second, third, "serialize ∘ parse is not idempotent")
    }

    /// An item with no `verify:` token inherits nothing from `verify_default`,
    /// and the frontmatter line comes back exactly as it was read.
    func testVerifyDefaultSurvivesWholeFileRoundTripWithoutReachingItems() {
        let md = """
        ---
        project: demo
        verify_default: make check
        ---

        ## Epic: Core

        - [ ] c-1 | Thing | ready
        """
        let written = BacklogSerializer.serialize(BacklogParser.parse(md))
        XCTAssertTrue(written.components(separatedBy: "\n").contains("verify_default: make check"), written)
        XCTAssertTrue(written.contains("- [ ] c-1 | Thing | ready\n"), written)

        let reparsed = BacklogParser.parse(written)
        XCTAssertEqual(reparsed.verifyDefault, "make check")
        XCTAssertNil(reparsed.sections.first?.items.first?.verify)
    }

    // MARK: - Lines the parser could not read

    /// `- [x ]` is the typo the panel's parse-issue banner exists for: a stray
    /// space in the checkbox, so no item is made of the line. The banner said so
    /// and the next write-back then deleted the line, which is how a typo turned
    /// into lost work.
    private static let malformedLine = "- [x ] typo-line | Some work"

    private var backlogWithAMalformedLine: String {
        """
        ---
        project: demo
        ---

        # Demo Backlog

        ## Epic: Onboarding

        Everything a new user sees on first launch.
        - [ ] demo-001 | Welcome screen | ready
        \(Self.malformedLine)
        - [ ] demo-002 | Account setup | ready

        ## Epic: Billing
        - [ ] demo-003 | Stripe integration | ready
        """
    }

    func testAMalformedLineIsReportedAndSurvivesTheWriteBack() {
        let result = BacklogParser.parseWithIssues(backlogWithAMalformedLine)
        XCTAssertTrue(
            result.issues.contains { $0.text == Self.malformedLine },
            "the line should still be reported: \(result.issues)"
        )

        let rewritten = BacklogSerializer.serialize(result.file)
        XCTAssertTrue(
            rewritten.components(separatedBy: "\n").contains(Self.malformedLine),
            "the write-back erased the line:\n\(rewritten)"
        )
    }

    func testAPreservedLineComesBackUnderItsOwnHeading() {
        let rewritten = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithAMalformedLine))
        let lines = rewritten.components(separatedBy: "\n")

        guard let onboarding = lines.firstIndex(of: "## Epic: Onboarding"),
              let billing = lines.firstIndex(of: "## Epic: Billing"),
              let malformed = lines.firstIndex(of: Self.malformedLine) else {
            return XCTFail("expected both headings and the line:\n\(rewritten)")
        }
        XCTAssertGreaterThan(malformed, onboarding, "line moved above its heading:\n\(rewritten)")
        XCTAssertLessThan(malformed, billing, "line drifted into a later epic:\n\(rewritten)")
    }

    /// Preserving the line must not quiet the banner — the app still isn't
    /// reading it as work, and whoever typed it still has to fix it.
    func testAPreservedLineIsStillReportedOnTheNextRead() {
        let rewritten = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithAMalformedLine))
        XCTAssertTrue(
            BacklogParser.parseWithIssues(rewritten).issues.contains { $0.text == Self.malformedLine },
            "the rewritten file no longer reports the line"
        )
    }

    /// The autopilot rewrites the file on every status change, so a preserved
    /// line must not accumulate copies of itself or drift down the file.
    func testAPreservedLineIsStableAcrossRepeatedWriteBacks() {
        let first = BacklogSerializer.serialize(BacklogParser.parse(backlogWithAMalformedLine))
        let second = BacklogSerializer.serialize(BacklogParser.parse(first))
        let third = BacklogSerializer.serialize(BacklogParser.parse(second))

        XCTAssertEqual(second, third, "serialize ∘ parse is not idempotent")
        XCTAssertEqual(
            first.components(separatedBy: "\n").filter { $0 == Self.malformedLine }.count, 1,
            "the line was duplicated:\n\(first)"
        )
    }

    /// Everything the parser *could* read is unaffected by carrying the line.
    func testTheRestOfTheFileStillRoundTripsAroundAMalformedLine() {
        let file = BacklogParser.parse(backlogWithAMalformedLine)
        let reparsed = BacklogParser.parse(BacklogSerializer.serialize(file))

        XCTAssertEqual(reparsed.project, "demo")
        XCTAssertEqual(reparsed.sections.map(\.name), ["Onboarding", "Billing"])
        XCTAssertEqual(reparsed.sections[0].items.map(\.id), ["demo-001", "demo-002"])
        XCTAssertEqual(reparsed.sections[0].description, "Everything a new user sees on first launch.")
        XCTAssertEqual(reparsed.sections[1].items.map(\.id), ["demo-003"])
    }

    /// A malformed line above the first `## ` heading belongs to no section, so
    /// there is nothing to carry it — it is reported and not preserved, and in
    /// particular the epic that follows must not adopt it.
    func testAMalformedLineAboveTheFirstHeadingIsNotAdoptedByTheNextEpic() {
        let content = """
        ---
        project: demo
        ---

        # Demo Backlog

        - [x ] homeless | Typed above every heading

        ## Epic: Onboarding
        - [ ] demo-001 | Welcome screen | ready
        """
        let result = BacklogParser.parseWithIssues(content)
        XCTAssertTrue(result.issues.contains { $0.text.contains("homeless") },
                      "still reported: \(result.issues)")
        XCTAssertEqual(result.file.sections.first?.unparsedLines, [])
    }

    // MARK: - Fields the parser could not read

    /// A `verify:` whose pipe is written with spaces splits on the field
    /// separator, so the tail of the command arrives as a field nothing
    /// recognises. That is the case the dropped-field report was built for — and
    /// the report told whoever typed it to fix the line while the next
    /// write-back deleted the very text it was about.
    private static let truncatedVerifyLine =
        "- [ ] plat-1 | Config loader | verify: kiteloop-verify.py --json | python3 -c 'assert ok' | ready"

    private var backlogWithATruncatedVerify: String {
        """
        ---
        project: demo
        ---

        # Demo Backlog

        ## Epic: Platform
        \(Self.truncatedVerifyLine)
        """
    }

    /// The tail is on the item, so the write-back has something to put back.
    func testAnUnrecognisedFieldIsCarriedOntoTheItem() {
        let item = BacklogParser.parseItemLine(Self.truncatedVerifyLine, verifyDefault: nil)

        XCTAssertEqual(item?.verify, "kiteloop-verify.py --json", "the truncation itself is unchanged")
        XCTAssertEqual(item?.unrecognisedFields, ["python3 -c 'assert ok'"])
    }

    func testAnUnrecognisedFieldSurvivesTheWriteBack() {
        let rewritten = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithATruncatedVerify))

        XCTAssertTrue(
            rewritten.contains("python3 -c 'assert ok'"),
            "the write-back erased the tail:\n\(rewritten)"
        )
    }

    /// Preserving the text must not quiet the report — the command the item runs
    /// is still shorter than the one that was written, and whoever typed it still
    /// has to fix the pipe.
    func testAPreservedFieldIsStillReportedOnTheNextRead() {
        let rewritten = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithATruncatedVerify))
        let reasons = BacklogParser.parseWithIssues(rewritten).issues.map(\.reason)

        XCTAssertTrue(
            reasons.contains { $0.contains("`python3 -c 'assert ok'`") && $0.contains("unspaced") },
            "the rewritten file no longer reports the dropped field: \(reasons)"
        )
    }

    /// Reading the rewritten line back gives the same item with the same one
    /// dropped field — the preserved text is not re-read as a second one, and
    /// not swallowed by a branch on the way past.
    func testARewrittenLineReparsesToTheSameItem() {
        let first = BacklogParser.parseItemLine(Self.truncatedVerifyLine, verifyDefault: nil)
        let second = BacklogParser.parseItemLine(
            BacklogSerializer.serializeItem(first!), verifyDefault: nil)

        assertItemsEqual(second, first!)
        XCTAssertEqual(second?.unrecognisedFields, ["python3 -c 'assert ok'"])
    }

    /// The autopilot rewrites the file on every status change, so a preserved
    /// field must not accumulate copies of itself.
    func testAPreservedFieldIsStableAcrossRepeatedWriteBacks() {
        let first = BacklogSerializer.serialize(BacklogParser.parse(backlogWithATruncatedVerify))
        let second = BacklogSerializer.serialize(BacklogParser.parse(first))
        let third = BacklogSerializer.serialize(BacklogParser.parse(second))

        XCTAssertEqual(second, third, "serialize ∘ parse is not idempotent")
        XCTAssertEqual(
            first.components(separatedBy: "python3 -c 'assert ok'").count - 1, 1,
            "the field was duplicated:\n\(first)"
        )
    }

    /// Several dropped fields keep their order, as written.
    func testSeveralUnrecognisedFieldsAreAllKeptInOrder() {
        let line = "- [ ] plat-1 | Config loader | owner: alice | reviewer: bob | ready"
        let item = BacklogParser.parseItemLine(line, verifyDefault: nil)

        XCTAssertEqual(item?.unrecognisedFields, ["owner: alice", "reviewer: bob"])
        XCTAssertEqual(BacklogSerializer.serializeItem(item!), line)
    }

    /// Position is not preserved — content is. The field is written after the
    /// descriptive tokens and before the stage one, so the line still parses the
    /// same way however it was originally laid out.
    func testAPreservedFieldSitsAfterProvenanceAndBeforeTheStage() {
        let item = BacklogParser.parseItemLine(
            "- [ ] plat-1 | Config loader | owner: alice | from:parent | ready",
            verifyDefault: nil
        )

        XCTAssertEqual(
            BacklogSerializer.serializeItem(item!),
            "- [ ] plat-1 | Config loader | from:parent | owner: alice | ready"
        )
    }

    /// On a done line the metrics are the stage tokens, so the preserved field
    /// goes ahead of them — a date landing before `12q` would be read back as a
    /// different field.
    func testAPreservedFieldOnADoneItemSitsBeforeItsMetrics() {
        let item = BacklogParser.parseItemLine(
            "- [x] plat-3 | Feature flag | owner: alice | 12q | $3.40 | 2026-01-15",
            verifyDefault: nil
        )

        XCTAssertEqual(
            BacklogSerializer.serializeItem(item!),
            "- [x] plat-3 | Feature flag | owner: alice | 12q | $3.40 | 2026-01-15"
        )
    }

    /// The overwhelming majority of lines carry no such field, and they must be
    /// written exactly as they were before this was carried — no empty token, no
    /// trailing separator.
    func testAnItemWithNoUnrecognisedFieldsIsUnchanged() {
        XCTAssertEqual(
            BacklogSerializer.serializeItem(
                makeItem(id: "plat-1", title: "Config loader",
                         verify: "swift test", status: .active, size: .m,
                         from: "parent", needs: ["plat-0"])),
            "- [ ] plat-1 | Config loader | verify: swift test | size:M | needs:plat-0 | from:parent | active"
        )
        XCTAssertEqual(roundTrip(makeItem())?.unrecognisedFields, [])
    }

    /// A whitespace-only entry would serialize as an empty field, which reads
    /// back as nothing at all and would leave a bare separator on the line.
    func testABlankUnrecognisedFieldIsNotWritten() {
        XCTAssertEqual(
            BacklogSerializer.serializeItem(
                makeItem(id: "plat-1", title: "Config loader", unrecognisedFields: ["   "])),
            "- [ ] plat-1 | Config loader | ready"
        )
    }

    // MARK: - A write that would corrupt a verify: on the way out

    /// The scenario `control-api-doc-refill` hit: an item that already had a
    /// good line on disk gets a `verify:` edited to something containing
    /// `" | "` — a shell pipe written with spaces, or any value that happens to
    /// contain the field separator. Serialising it naively would embed that
    /// sequence in the line, and the very next parse would split on it and
    /// truncate the command — silently, since nothing about the write itself
    /// fails. The line the parser last read this item back from correctly is
    /// kept instead.
    func testALossyVerifyEditKeepsTheExistingLineInstead() {
        let originalLine = "- [ ] plat-9 | Config loader | verify: swift build | size:M | ready"
        var item = BacklogParser.parseItemLine(originalLine, verifyDefault: nil)!
        item.verify = "kiteloop-verify.py --json | python3 -c 'assert ok'"

        XCTAssertEqual(
            BacklogSerializer.serializeItem(item), originalLine,
            "a lossy write must not replace a good line with a truncated command"
        )
    }

    /// The revert is of the whole line, not just the field that made it lossy
    /// — the same shape as the durable-writer rule elsewhere in the app: a
    /// write that cannot be completed leaves what was there, rather than
    /// landing a partial patch.
    func testALossyVerifyEditRevertsEveryOtherChangeOnTheSameLineToo() {
        let originalLine = "- [ ] plat-9 | Config loader | verify: swift build | size:M | needs:plat-0 | active"
        var item = BacklogParser.parseItemLine(originalLine, verifyDefault: nil)!
        item.verify = "swift build | echo done"
        item.status = .inReview
        item.size = .l

        XCTAssertEqual(BacklogSerializer.serializeItem(item), originalLine)
    }

    /// The other fields on a line whose verify: gets reverted are unaffected —
    /// this is a round trip refusal, not a rewrite of the rest of the line.
    func testEveryOtherFieldSurvivesAlongsideARevertedVerify() {
        let originalLine = "- [ ] plat-9 | Config loader | verify: swift build | size:M | needs:plat-0 | active"
        var item = BacklogParser.parseItemLine(originalLine, verifyDefault: nil)!
        item.verify = "swift build | echo done"

        let reparsed = BacklogParser.parseItemLine(
            BacklogSerializer.serializeItem(item), verifyDefault: nil)
        XCTAssertEqual(reparsed?.verify, "swift build", "the corrupted edit must not have landed")
        XCTAssertEqual(reparsed?.size, .m)
        XCTAssertEqual(reparsed?.needs, ["plat-0"])
        XCTAssertEqual(reparsed?.status, .active)
    }

    /// A shell pipe written *without* spaces around it is the documented
    /// escape hatch, and must keep working for an item that never went through
    /// the parser at all — not only for one reconstructed from a line.
    func testVerifyWithAnUnspacedPipeRoundTripsForAFreshItem() {
        let item = makeItem(verify: "kiteloop-verify.py --json|python3 -c 'assert ok'")
        assertItemsEqual(roundTrip(item), item)
    }

    /// This guard exists to stop a *new* corruption, not to repair one already
    /// on disk — `control-api-doc-refill`'s own line stays exactly as
    /// truncated, since the tail it is missing is not something a serializer
    /// can reconstruct.
    func testAnAlreadyTruncatedLineIsNotTouchedByTheGuard() {
        let item = BacklogParser.parseItemLine(Self.truncatedVerifyLine, verifyDefault: nil)!
        XCTAssertEqual(BacklogSerializer.serializeItem(item), Self.truncatedVerifyLine)
    }

    /// An item that was never on disk has no existing line to fall back to —
    /// the write still lands rather than dropping the item's other fields, but
    /// it is not what this guard exists to fix (see `Out of Scope`).
    func testALossyVerifyWithNoPriorLineStillWritesTheRestOfTheItem() {
        let item = makeItem(id: "plat-9", title: "Config loader", verify: "swift build | echo done")
        let line = BacklogSerializer.serializeItem(item)

        XCTAssertTrue(line.contains("plat-9"))
        XCTAssertTrue(line.contains("Config loader"))
    }

    // MARK: - touches:

    /// The exemption survives the trip. It has to survive it *exactly*: the gate
    /// compares the token against `git diff` output, so a path the round trip
    /// reshapes is a path that stops matching what it was written to excuse.
    func testTouchesRoundTrips() {
        let item = makeItem(touches: ["docs/suite-status.md"])
        XCTAssertTrue(
            BacklogSerializer.serializeItem(item).contains("touches:docs/suite-status.md"),
            "serialized: \(BacklogSerializer.serializeItem(item))"
        )
        assertItemsEqual(roundTrip(item), item)
    }

    func testSeveralTouchesRoundTripCommaSeparated() {
        let item = makeItem(touches: ["docs/suite-status.md", "docs/features.md"])
        XCTAssertTrue(
            BacklogSerializer.serializeItem(item)
                .contains("touches:docs/suite-status.md,docs/features.md"),
            "serialized: \(BacklogSerializer.serializeItem(item))"
        )
        assertItemsEqual(roundTrip(item), item)
    }

    /// An item claiming nothing writes no token — the overwhelmingly common case,
    /// and the one where a stray `touches:` would read as a granted exemption.
    func testNoTouchesWritesNoToken() {
        XCTAssertFalse(BacklogSerializer.serializeItem(makeItem()).contains("touches:"))
    }

    /// `touches:` beside the tokens it shares a line with, none of them eating
    /// another's value.
    func testTouchesCoexistsWithTheOtherTokens() {
        let item = makeItem(
            verify: "swift build",
            size: .m,
            from: "parent-item",
            needs: ["first"],
            touches: ["docs/suite-status.md"]
        )
        assertItemsEqual(roundTrip(item), item)
    }

    /// Written by hand with a space after the colon, the way `verify: ` is
    /// spelled — the same tolerance `needs:` has.
    func testHandWrittenTouchesWithSpaceParses() {
        let spaced = BacklogParser.parseItemLine(
            "- [ ] recording-format | Widen the suite row | touches: docs/suite-status.md | ready",
            verifyDefault: nil
        )
        XCTAssertEqual(spaced?.touches, ["docs/suite-status.md"])
        XCTAssertEqual(spaced?.status, .ready, "the stage still parses next to it")
    }

    /// Several, hand-written with the spacing a person uses after a comma.
    func testHandWrittenTouchesSplitsOnCommas() {
        let spaced = BacklogParser.parseItemLine(
            "- [ ] recording-format | Widen it | touches: docs/suite-status.md, docs/features.md",
            verifyDefault: nil
        )
        XCTAssertEqual(spaced?.touches, ["docs/suite-status.md", "docs/features.md"])
    }

    /// An empty token is no exemption rather than a blank one — a bare `touches:`
    /// must not read as a claim, and must not be written back onto the line.
    func testAnEmptyTouchesTokenIsDropped() {
        let parsed = BacklogParser.parseItemLine(
            "- [ ] child | Claims nothing | touches: | ready", verifyDefault: nil)
        XCTAssertEqual(parsed?.touches, [])
        XCTAssertFalse(BacklogSerializer.serializeItem(parsed!).contains("touches:"))
    }

    func testEmptyEpicSurvivesRoundTrip() {
        let file = BacklogFile(
            project: "demo", repo: nil, verifyDefault: nil,
            sections: [
                BacklogSection(name: "Later", description: "Nothing scheduled yet.", items: []),
                BacklogSection(name: "Now", items: [makeItem(id: "n-1", title: "Ship it")])
            ]
        )
        let reparsed = BacklogParser.parse(BacklogSerializer.serialize(file))
        XCTAssertEqual(reparsed.sections.map(\.name), ["Later", "Now"])
        XCTAssertTrue(reparsed.sections[0].items.isEmpty)
        XCTAssertEqual(reparsed.sections[0].description, "Nothing scheduled yet.")
        XCTAssertEqual(reparsed.sections[1].items.map(\.id), ["n-1"])
    }

    // MARK: - Prose written after a section's first item

    /// Only the prose *above* the first item becomes the epic's description, so
    /// a note between two items — or a caveat after the last one — reached the
    /// end of the parse loop and was stored nowhere. The write-back then rebuilt
    /// the file from the sections and the note was gone: silently, on the first
    /// status change after it was typed, and with no parse issue to say so.
    private static let noteBetweenItems = "Ordering matters here: 002 depends on 001 landing first."
    private static let noteAfterTheLastItem = "None of this is scheduled before the beta."

    private var backlogWithNotesAmongItems: String {
        """
        ---
        project: demo
        ---

        # Demo Backlog

        ## Epic: Onboarding

        Everything a new user sees on first launch.
        - [ ] demo-001 | Welcome screen | ready
        \(Self.noteBetweenItems)
        - [ ] demo-002 | Account setup | ready
        \(Self.noteAfterTheLastItem)

        ## Epic: Billing
        - [ ] demo-003 | Stripe integration | ready
        """
    }

    func testANoteBetweenTwoItemsSurvivesTheWriteBack() {
        let rewritten = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithNotesAmongItems))
        XCTAssertTrue(
            rewritten.components(separatedBy: "\n").contains(Self.noteBetweenItems),
            "the write-back erased the note:\n\(rewritten)"
        )
    }

    func testANoteAfterTheLastItemSurvivesTheWriteBack() {
        let rewritten = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithNotesAmongItems))
        XCTAssertTrue(
            rewritten.components(separatedBy: "\n").contains(Self.noteAfterTheLastItem),
            "the write-back erased the note:\n\(rewritten)"
        )
    }

    func testBothNotesAreCarriedOnTheSectionInTheOrderTheyWereWritten() {
        let file = BacklogParser.parse(backlogWithNotesAmongItems)
        XCTAssertEqual(file.sections[0].trailingLines,
                       [Self.noteBetweenItems, Self.noteAfterTheLastItem])
        XCTAssertEqual(file.sections[1].trailingLines, [],
                       "a later epic adopted the notes above it")
    }

    func testANoteComesBackUnderItsOwnHeading() {
        let rewritten = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithNotesAmongItems))
        let lines = rewritten.components(separatedBy: "\n")

        guard let onboarding = lines.firstIndex(of: "## Epic: Onboarding"),
              let billing = lines.firstIndex(of: "## Epic: Billing"),
              let note = lines.firstIndex(of: Self.noteBetweenItems) else {
            return XCTFail("expected both headings and the note:\n\(rewritten)")
        }
        XCTAssertGreaterThan(note, onboarding, "note moved above its heading:\n\(rewritten)")
        XCTAssertLessThan(note, billing, "note drifted into a later epic:\n\(rewritten)")
    }

    /// The prose above the first item is a *description*, and preserving what
    /// follows must not change where it lands or how it is written back.
    func testProseAboveTheFirstItemIsStillTheDescription() {
        let file = BacklogParser.parse(backlogWithNotesAmongItems)
        XCTAssertEqual(file.sections[0].description,
                       "Everything a new user sees on first launch.")

        let lines = BacklogSerializer.serialize(file).components(separatedBy: "\n")
        guard let description = lines.firstIndex(of: "Everything a new user sees on first launch."),
              let firstItem = lines.firstIndex(where: { $0.hasPrefix("- [ ] demo-001") }) else {
            return XCTFail("expected the description and the first item:\n\(lines.joined(separator: "\n"))")
        }
        XCTAssertLessThan(description, firstItem, "the description moved below the items")
    }

    /// These lines are prose, not a line the parser refused — nothing is wrong
    /// with them, so the banner has nothing to say.
    func testAPreservedNoteRaisesNoParseIssue() {
        let result = BacklogParser.parseWithIssues(backlogWithNotesAmongItems)
        XCTAssertEqual(result.issues, [], "prose was reported as a parse issue")

        let rewritten = BacklogSerializer.serialize(result.file)
        XCTAssertEqual(BacklogParser.parseWithIssues(rewritten).issues, [],
                       "the rewritten file reports an issue the original didn't")
    }

    /// The autopilot rewrites the file on every status change, so a preserved
    /// note must not accumulate copies of itself or drift down the file.
    func testAPreservedNoteIsStableAcrossRepeatedWriteBacks() {
        let first = BacklogSerializer.serialize(BacklogParser.parse(backlogWithNotesAmongItems))
        let second = BacklogSerializer.serialize(BacklogParser.parse(first))
        let third = BacklogSerializer.serialize(BacklogParser.parse(second))

        XCTAssertEqual(second, third, "serialize ∘ parse is not idempotent")
        for note in [Self.noteBetweenItems, Self.noteAfterTheLastItem] {
            XCTAssertEqual(first.components(separatedBy: "\n").filter { $0 == note }.count, 1,
                           "the note was duplicated:\n\(first)")
        }
    }

    /// A second parse of the serialized output reads back the same items and the
    /// same preserved lines — the notes are carried, not re-read as work.
    func testASecondParseYieldsTheSameItemsAndTheSameNotes() {
        let file = BacklogParser.parse(backlogWithNotesAmongItems)
        let reparsed = BacklogParser.parse(BacklogSerializer.serialize(file))

        XCTAssertEqual(reparsed.sections.map(\.name), file.sections.map(\.name))
        XCTAssertEqual(reparsed.sections.map { $0.items.map(\.id) },
                       file.sections.map { $0.items.map(\.id) })
        XCTAssertEqual(reparsed.sections.map(\.trailingLines),
                       file.sections.map(\.trailingLines))
        XCTAssertEqual(reparsed.sections.map(\.description), file.sections.map(\.description))
    }

    /// A note and a line the parser refused sit in the same section: the refused
    /// one is still reported, the note is not, and both come back.
    func testANoteAndARefusedLineAreBothPreservedInOneSection() {
        let content = """
        ---
        project: demo
        ---

        # Demo Backlog

        ## Epic: Onboarding
        - [ ] demo-001 | Welcome screen | ready
        \(Self.noteBetweenItems)
        \(Self.malformedLine)
        """
        let result = BacklogParser.parseWithIssues(content)
        XCTAssertEqual(result.file.sections[0].trailingLines, [Self.noteBetweenItems])
        XCTAssertEqual(result.file.sections[0].unparsedLines, [Self.malformedLine])
        XCTAssertEqual(result.issues.map(\.text), [Self.malformedLine],
                       "the note should not be reported: \(result.issues)")

        let rewritten = BacklogSerializer.serialize(result.file).components(separatedBy: "\n")
        XCTAssertTrue(rewritten.contains(Self.noteBetweenItems))
        XCTAssertTrue(rewritten.contains(Self.malformedLine))
    }

    // MARK: - Frontmatter keys the parser has no use for

    /// The reader acts on `project`, `repo` and `verify_default`; the writer
    /// rebuilds the block from those three and closes it. Everything else the
    /// user had put in their own frontmatter was therefore deleted on the first
    /// status flip after it was typed, silently.
    private static let frontmatterOnlyKnownKeys = """
    ---
    project: demo
    repo: /Users/demo/code/demo
    verify_default: swift build
    ---

    # Demo Backlog

    ## Epic: Onboarding
    - [ ] demo-001 | Welcome screen | verify: swift build | ready

    """

    private var backlogWithExtraFrontmatterKeys: String {
        Self.frontmatterOnlyKnownKeys.replacingOccurrences(
            of: "verify_default: swift build",
            with: """
            verify_default: swift build
            owner: pat
            docs: https://example.com/handbook
            """
        )
    }

    func testAnUnrecognisedFrontmatterKeySurvivesTheWriteBack() {
        let rewritten = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithExtraFrontmatterKeys))

        XCTAssertTrue(
            rewritten.components(separatedBy: "\n").contains("owner: pat"),
            "the write-back erased the key:\n\(rewritten)"
        )
    }

    /// The value comes back as written — a colon inside it is part of the value,
    /// not a second key.
    func testAnUnrecognisedFrontmatterValueIsUnchanged() {
        let reparsed = BacklogParser.parse(
            BacklogSerializer.serialize(BacklogParser.parse(backlogWithExtraFrontmatterKeys)))

        XCTAssertEqual(reparsed.unrecognisedFrontmatterLines,
                       ["owner: pat", "docs: https://example.com/handbook"])
    }

    func testSeveralUnrecognisedFrontmatterKeysComeBackInOrder() {
        let file = BacklogParser.parse(backlogWithExtraFrontmatterKeys)
        XCTAssertEqual(file.unrecognisedFrontmatterLines,
                       ["owner: pat", "docs: https://example.com/handbook"])

        let lines = BacklogSerializer.serialize(file).components(separatedBy: "\n")
        guard let owner = lines.firstIndex(of: "owner: pat"),
              let docs = lines.firstIndex(of: "docs: https://example.com/handbook") else {
            return XCTFail("expected both keys:\n\(lines.joined(separator: "\n"))")
        }
        XCTAssertLessThan(owner, docs, "the keys were reordered:\n\(lines.joined(separator: "\n"))")
    }

    /// Position is not preserved — content is. The keys are written after the
    /// three the app acts on and inside the block, so the frontmatter still reads
    /// the same way however it was originally laid out.
    func testPreservedKeysSitAfterTheKnownOnesAndInsideTheBlock() {
        let lines = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithExtraFrontmatterKeys)
        ).components(separatedBy: "\n")

        XCTAssertEqual(Array(lines.prefix(7)), [
            "---",
            "project: demo",
            "repo: /Users/demo/code/demo",
            "verify_default: swift build",
            "owner: pat",
            "docs: https://example.com/handbook",
            "---"
        ], "frontmatter:\n\(lines.joined(separator: "\n"))")
    }

    /// The overwhelming majority of backlogs carry only the three known keys, and
    /// they must be written exactly as they were before this was carried — no
    /// blank line, no stray key.
    func testAFileWithOnlyKnownKeysRoundTripsByteIdentically() {
        XCTAssertEqual(
            BacklogSerializer.serialize(BacklogParser.parse(Self.frontmatterOnlyKnownKeys)),
            Self.frontmatterOnlyKnownKeys
        )
    }

    /// A whitespace-only entry would be written as a blank line inside the
    /// block, which reads back as nothing at all.
    func testABlankPreservedFrontmatterLineIsNotWritten() {
        let file = BacklogFile(
            project: "demo", repo: nil, verifyDefault: nil,
            sections: [BacklogSection(name: "Now", items: [makeItem(id: "n-1", title: "Ship it")])],
            unrecognisedFrontmatterLines: ["   "]
        )
        XCTAssertEqual(
            Array(BacklogSerializer.serialize(file).components(separatedBy: "\n").prefix(3)),
            ["---", "project: demo", "---"]
        )
    }

    /// A key the app does not use is legitimate project metadata, not a typo, so
    /// the panel's banner has nothing to say about it.
    func testAPreservedFrontmatterKeyRaisesNoParseIssue() {
        let result = BacklogParser.parseWithIssues(backlogWithExtraFrontmatterKeys)
        XCTAssertEqual(result.issues, [], "a frontmatter key was reported as a parse issue")

        let rewritten = BacklogSerializer.serialize(result.file)
        XCTAssertEqual(BacklogParser.parseWithIssues(rewritten).issues, [],
                       "the rewritten file reports an issue the original didn't")
    }

    /// The autopilot rewrites the file on every status change, so a preserved key
    /// must neither accumulate copies of itself nor drop out on a later write.
    func testPreservedFrontmatterKeysAreStableAcrossRepeatedWriteBacks() {
        let first = BacklogSerializer.serialize(BacklogParser.parse(backlogWithExtraFrontmatterKeys))
        let second = BacklogSerializer.serialize(BacklogParser.parse(first))
        let third = BacklogSerializer.serialize(BacklogParser.parse(second))

        XCTAssertEqual(second, third, "serialize ∘ parse is not idempotent")
        for key in ["owner: pat", "docs: https://example.com/handbook"] {
            XCTAssertEqual(third.components(separatedBy: "\n").filter { $0 == key }.count, 1,
                           "the key was duplicated or dropped:\n\(third)")
        }
    }

    /// Everything the parser *does* act on is unaffected by carrying the rest.
    func testTheKnownKeysStillRoundTripAroundAPreservedOne() {
        let reparsed = BacklogParser.parse(
            BacklogSerializer.serialize(BacklogParser.parse(backlogWithExtraFrontmatterKeys)))

        XCTAssertEqual(reparsed.project, "demo")
        XCTAssertEqual(reparsed.repo, "/Users/demo/code/demo")
        XCTAssertEqual(reparsed.verifyDefault, "swift build")
        XCTAssertEqual(reparsed.sections.map(\.name), ["Onboarding"])
        XCTAssertEqual(reparsed.sections[0].items.map(\.id), ["demo-001"])
    }

    /// `BacklogFile` is persisted, so a payload written before the lines were
    /// carried must still decode rather than failing the whole read.
    func testAPayloadWithoutThePreservedKeysStillDecodes() throws {
        let json = Data("""
        {"project":"demo","sections":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(BacklogFile.self, from: json)

        XCTAssertEqual(decoded.project, "demo")
        XCTAssertEqual(decoded.unrecognisedFrontmatterLines, [])
    }

    func testThePreservedKeysSurviveACodableRoundTrip() throws {
        let file = BacklogParser.parse(backlogWithExtraFrontmatterKeys)
        let decoded = try JSONDecoder().decode(
            BacklogFile.self, from: JSONEncoder().encode(file))

        XCTAssertEqual(decoded.unrecognisedFrontmatterLines, file.unrecognisedFrontmatterLines)
    }

    // MARK: - Preamble above the first epic heading

    /// Everything between the closing frontmatter marker and the first epic
    /// heading — the file's own H1, an introduction, a link block — used to be
    /// dropped on the floor: the parser only ever kept prose once a section had
    /// been opened, so this branch was silently discarded and the write-back
    /// replaced the H1 with a generated one.
    private static let customH1 = "# Kiteloop Team Backlog"
    private static let introLine = "This backlog tracks everything the team ships, groomed weekly."
    private static let linkLine = "See the [team charter](https://example.com/charter) before filing anything."

    private var backlogWithAPreamble: String {
        """
        ---
        project: demo
        ---

        \(Self.customH1)

        \(Self.introLine)

        \(Self.linkLine)

        ## Epic: Onboarding
        - [ ] demo-001 | Welcome screen | ready
        """
    }

    func testAPreambleWithAnIntroductionAndALinkRoundTrips() {
        let file = BacklogParser.parse(backlogWithAPreamble)
        XCTAssertEqual(file.preambleLines, [Self.customH1, Self.introLine, Self.linkLine])

        let rewritten = BacklogSerializer.serialize(file).components(separatedBy: "\n")
        for line in [Self.customH1, Self.introLine, Self.linkLine] {
            XCTAssertTrue(rewritten.contains(line), "the write-back erased the preamble:\n\(rewritten)")
        }
    }

    /// The preamble sits ahead of the first section, in the order it was typed —
    /// not scattered, not reordered.
    func testAPreambleComesBackBeforeTheFirstSection() {
        let rewritten = BacklogSerializer.serialize(
            BacklogParser.parse(backlogWithAPreamble)).components(separatedBy: "\n")

        guard let h1 = rewritten.firstIndex(of: Self.customH1),
              let intro = rewritten.firstIndex(of: Self.introLine),
              let link = rewritten.firstIndex(of: Self.linkLine),
              let onboarding = rewritten.firstIndex(of: "## Epic: Onboarding") else {
            return XCTFail("expected the preamble and the heading:\n\(rewritten.joined(separator: "\n"))")
        }
        XCTAssertLessThan(h1, intro)
        XCTAssertLessThan(intro, link)
        XCTAssertLessThan(link, onboarding)
    }

    /// A hand-written H1 that isn't the project name capitalised must survive —
    /// generating one over it is exactly the loss this item exists to close.
    func testACustomH1IsNotReplacedByTheGeneratedOne() {
        let rewritten = BacklogSerializer.serialize(BacklogParser.parse(backlogWithAPreamble))
        XCTAssertTrue(rewritten.contains(Self.customH1), "custom H1 missing:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("# Demo Backlog"), "a generated H1 was written anyway:\n\(rewritten)")
    }

    /// A file with nothing above its first heading still gets the generated H1,
    /// and writing it back a second time changes nothing.
    func testAFileWithNoPreambleStillGetsTheGeneratedHeading() {
        let content = """
        ---
        project: demo
        ---

        ## Epic: Onboarding
        - [ ] demo-001 | Welcome screen | ready
        """
        let file = BacklogParser.parse(content)
        XCTAssertEqual(file.preambleLines, [])

        let first = BacklogSerializer.serialize(file)
        XCTAssertTrue(first.contains("# Demo Backlog"), "no generated heading:\n\(first)")

        let second = BacklogSerializer.serialize(BacklogParser.parse(first))
        XCTAssertEqual(first, second, "serialize ∘ parse is not idempotent")
    }

    /// A well-formed item line above the first heading belongs to no epic — the
    /// parser already says so and refuses to adopt it into the epic that follows.
    /// It must not leak into the preamble either.
    func testAWellFormedItemAboveTheFirstHeadingIsReportedAndNotAdopted() {
        let content = """
        ---
        project: demo
        ---

        \(Self.customH1)

        - [ ] homeless-1 | Above every heading | ready

        ## Epic: Onboarding
        - [ ] demo-001 | Welcome screen | ready
        """
        let result = BacklogParser.parseWithIssues(content)

        XCTAssertTrue(
            result.issues.contains { $0.text.contains("homeless-1") },
            "expected the item to be reported: \(result.issues)"
        )
        XCTAssertEqual(result.file.sections.first?.items.map(\.id), ["demo-001"],
                       "the homeless item was adopted by the epic that follows")
        XCTAssertEqual(result.file.preambleLines, [Self.customH1],
                       "the item line leaked into the preamble")
    }

    /// The autopilot rewrites the file on every status change, so a preserved
    /// preamble must not accumulate copies of itself or drift.
    func testAPreambleIsStableAcrossRepeatedWriteBacks() {
        let first = BacklogSerializer.serialize(BacklogParser.parse(backlogWithAPreamble))
        let second = BacklogSerializer.serialize(BacklogParser.parse(first))
        let third = BacklogSerializer.serialize(BacklogParser.parse(second))

        XCTAssertEqual(second, third, "serialize ∘ parse is not idempotent")
        for line in [Self.customH1, Self.introLine, Self.linkLine] {
            XCTAssertEqual(second.components(separatedBy: "\n").filter { $0 == line }.count, 1,
                           "the preamble line was duplicated:\n\(second)")
        }
    }

    /// `BacklogFile` is persisted, so a payload written before the preamble was
    /// carried must still decode rather than failing the whole read.
    func testAPayloadWithoutThePreambleStillDecodes() throws {
        let json = Data("""
        {"project":"demo","sections":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(BacklogFile.self, from: json)

        XCTAssertEqual(decoded.preambleLines, [])
    }

    func testThePreambleSurvivesACodableRoundTrip() throws {
        let file = BacklogParser.parse(backlogWithAPreamble)
        let decoded = try JSONDecoder().decode(
            BacklogFile.self, from: JSONEncoder().encode(file))

        XCTAssertEqual(decoded.preambleLines, file.preambleLines)
    }
}
