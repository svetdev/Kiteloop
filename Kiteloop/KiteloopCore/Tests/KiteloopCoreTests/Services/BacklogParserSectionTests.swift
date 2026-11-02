import XCTest
@testable import KiteloopCore

/// Backlog.md is hand-edited as often as it is machine-written, so the parser
/// has to cope with the shapes humans actually type: `## Epic:` headings, `###`
/// sub-headings used to group items inside an epic, and a frontmatter block
/// carrying `repo` / `verify_default`. These tests pin how `parse` reads that
/// structure — the item-level token parsing is covered by BacklogRoundTripTests.
final class BacklogParserSectionTests: XCTestCase {

    // MARK: - Epic headings

    func testEpicPrefixIsStrippedFromSectionNames() {
        let md = """
        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen

        ## Epic: Billing

        - [ ] bil-1 | Invoice PDF
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.sections.map(\.name), ["Onboarding", "Billing"])
    }

    /// Not every heading is an epic — `## Bugs` and friends keep their text.
    func testHeadingsWithoutEpicPrefixKeepTheirName() {
        let md = """
        ## Bugs

        - [ ] bug-1 | Crash on launch

        ## Icebox

        - [ ] ice-1 | Someday
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.sections.map(\.name), ["Bugs", "Icebox"])
    }

    /// The `# Project Backlog` title the serializer writes is not a section, and
    /// neither is any prose sitting above the first epic.
    func testTitleAndPreambleDoNotCreateSections() {
        let md = """
        # Demo Backlog

        Everything the team plans to ship.

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.sections.map(\.name), ["Onboarding"])
        XCTAssertEqual(file.sections.first?.items.map(\.id), ["onb-1"])
    }

    func testProseUnderAnEpicBecomesItsDescription() {
        let md = """
        ## Epic: Onboarding

        Get new users to first value.
        Two screens, no more.

        - [ ] onb-1 | Welcome screen
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(
            file.sections.first?.description,
            "Get new users to first value.\nTwo screens, no more."
        )
    }

    func testEpicWithNoItemsIsStillASection() {
        let md = """
        ## Epic: Later

        Nothing scheduled yet.

        ## Epic: Now

        - [ ] now-1 | Ship it
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.sections.map(\.name), ["Later", "Now"])
        XCTAssertEqual(file.sections.first?.items.count, 0)
        XCTAssertEqual(file.sections.first?.description, "Nothing scheduled yet.")
        XCTAssertEqual(file.sections.last?.items.map(\.id), ["now-1"])
    }

    // MARK: - Flattened `###` sub-headings

    /// A backlog has exactly one level of grouping. `###` sub-headings inside an
    /// epic are presentation only: their items flatten into the enclosing epic
    /// rather than splitting it into extra sections.
    func testSubHeadingsFlattenIntoTheEnclosingEpic() {
        let md = """
        ## Epic: Platform

        ### Phase 1 — foundations

        - [ ] plat-1 | Config loader
        - [ ] plat-2 | Log plumbing

        ### Phase 2 — rollout

        - [ ] plat-3 | Feature flag

        ## Epic: Billing

        - [ ] bil-1 | Invoice PDF
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.sections.map(\.name), ["Platform", "Billing"])
        XCTAssertEqual(
            file.sections.first?.items.map(\.id),
            ["plat-1", "plat-2", "plat-3"],
            "items under `###` sub-headings must stay in their epic, in order"
        )
        XCTAssertFalse(
            file.sections.contains { $0.name.hasPrefix("Phase") },
            "a `###` sub-heading must not open a new section"
        )
    }

    /// Item tokens survive the flattening — a sub-heading must not swallow the
    /// status or size of the items that follow it.
    func testItemsUnderSubHeadingsKeepTheirTokens() {
        let md = """
        ## Epic: Platform

        ### Phase 2 — rollout

        - [ ] plat-3 | Feature flag | verify: swift test | size:M | active
        """

        let item = BacklogParser.parse(md).sections.first?.items.first

        XCTAssertEqual(item?.id, "plat-3")
        XCTAssertEqual(item?.title, "Feature flag")
        XCTAssertEqual(item?.verify, "swift test")
        XCTAssertEqual(item?.size, .m)
        XCTAssertEqual(item?.status, .active)
    }

    // MARK: - Frontmatter

    func testFrontmatterFieldsAreParsed() {
        let md = """
        ---
        project: demo
        repo: /Users/dev/demo
        verify_default: swift build
        ---

        # Demo Backlog

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.project, "demo")
        XCTAssertEqual(file.repo, "/Users/dev/demo")
        XCTAssertEqual(file.verifyDefault, "swift build")
    }

    func testUnknownFrontmatterKeysAreIgnored() {
        let md = """
        ---
        project: demo
        owner: alice
        updated: 2026-01-15
        ---

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.project, "demo")
        XCTAssertNil(file.repo)
        XCTAssertNil(file.verifyDefault)
        XCTAssertEqual(file.sections.first?.items.map(\.id), ["onb-1"])
    }

    func testMissingFrontmatterLeavesMetadataEmpty() {
        let md = """
        # Demo Backlog

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.project, "")
        XCTAssertNil(file.repo)
        XCTAssertNil(file.verifyDefault)
        XCTAssertEqual(file.sections.map(\.name), ["Onboarding"])
    }

    /// A verify command can carry its own colons — only the first one separates
    /// the frontmatter key from its value.
    func testVerifyDefaultKeepsColonsInItsValue() {
        let md = """
        ---
        project: demo
        verify_default: swift test --filter Backlog:Sections
        ---

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.verifyDefault, "swift test --filter Backlog:Sections")
    }

    /// `verify_default` is read into the file but no item inherits it: items
    /// without a `verify:` token have none, items with one keep theirs.
    func testVerifyDefaultIsNotInheritedByItemsWithoutTheirOwn() {
        let md = """
        ---
        project: demo
        verify_default: swift build
        ---

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        - [ ] onb-2 | Email verification | verify: swift test

        ## Bugs

        - [ ] bug-1 | Crash on launch
        """

        let file = BacklogParser.parse(md)
        let items = file.sections.flatMap(\.items)

        XCTAssertEqual(items.map(\.id), ["onb-1", "onb-2", "bug-1"])
        XCTAssertEqual(items.map(\.verify), [nil, "swift test", nil])
        XCTAssertEqual(file.verifyDefault, "swift build")
    }

    func testItemsHaveNoVerifyWhenNoDefaultIsDeclared() {
        let md = """
        ---
        project: demo
        ---

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        """

        XCTAssertNil(BacklogParser.parse(md).sections.first?.items.first?.verify)
    }

    /// A `---` rule in the body is just a rule — it must not reopen frontmatter
    /// and start eating headings and items.
    func testHorizontalRuleInBodyDoesNotReopenFrontmatter() {
        let md = """
        ---
        project: demo
        verify_default: swift build
        ---

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen

        ---

        ## Epic: Billing

        repo: not-really-frontmatter

        - [ ] bil-1 | Invoice PDF
        """

        let file = BacklogParser.parse(md)

        XCTAssertEqual(file.project, "demo")
        XCTAssertEqual(file.repo, nil, "a body line must not be read as frontmatter")
        XCTAssertEqual(file.sections.map(\.name), ["Onboarding", "Billing"])
        XCTAssertEqual(file.sections.last?.items.map(\.id), ["bil-1"])
    }

    // MARK: - Parse issues

    /// A checkbox the parser can't read used to vanish without a trace — and
    /// with it the work it described. `parseWithIssues` reports the line so the
    /// panel can show it.
    func testMalformedCheckboxIsReportedWithItsLine() {
        let md = """
        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        - [X] onb-2 | Email verification
        """

        let result = BacklogParser.parseWithIssues(md)

        XCTAssertEqual(result.file.sections.first?.items.map(\.id), ["onb-1"])
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues.first?.line, 4)
        XCTAssertEqual(result.issues.first?.text, "- [X] onb-2 | Email verification")
        XCTAssertTrue(
            result.issues.first?.reason.contains("[X]") == true,
            "the reason must name the marker that failed: \(result.issues.first?.reason ?? "")"
        )
    }

    func testEmptyCheckboxLineIsReported() {
        let md = """
        ## Epic: Onboarding

        - [ ]
        """

        let issues = BacklogParser.parseWithIssues(md).issues

        XCTAssertEqual(issues.map(\.line), [3])
        XCTAssertTrue(issues.first?.reason.contains("Empty item") == true)
    }

    /// Items above the first heading belong to no epic and are dropped on
    /// write-back. The item still parses — the point is that the user hears it.
    func testItemAboveTheFirstHeadingIsReported() {
        let md = """
        # Demo Backlog

        - [ ] stray-1 | Written before any epic

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        """

        let result = BacklogParser.parseWithIssues(md)

        XCTAssertEqual(result.file.sections.flatMap(\.items).map(\.id), ["onb-1"])
        XCTAssertEqual(result.issues.map(\.line), [3])
        XCTAssertTrue(result.issues.first?.reason.contains("stray-1") == true)
    }

    /// Ids key every lookup, run and hand-off, so a repeat means one of the two
    /// items is unreachable.
    func testDuplicateItemIDIsReported() {
        let md = """
        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen

        ## Bugs

        - [ ] onb-1 | Crash on launch
        """

        let result = BacklogParser.parseWithIssues(md)

        XCTAssertEqual(result.file.sections.flatMap(\.items).count, 2)
        XCTAssertEqual(result.issues.map(\.line), [7])
        XCTAssertTrue(result.issues.first?.reason.contains("Duplicate id `onb-1`") == true)
        XCTAssertTrue(
            result.issues.first?.reason.contains("line 3") == true,
            "the reason must point at the first use: \(result.issues.first?.reason ?? "")"
        )
    }

    // MARK: - Unrecognised fields

    /// The commonest cause, and the one `CLAUDE.md` warns about: a `verify:`
    /// written with a spaced pipe splits on the `" | "` field separator, so the
    /// command is truncated and its tail lands here as a field nothing claims.
    /// It used to be dropped in silence — the item ran a shorter command than
    /// its author wrote, and no surface anywhere said so.
    func testTruncatedVerifyTailIsReportedWithItsLine() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | verify: x --json | python3 -c 'y' | ready
        """

        let result = BacklogParser.parseWithIssues(md)

        // The item is still there: this reports, it does not reject.
        let item = result.file.sections.first?.items.first
        XCTAssertEqual(item?.id, "plat-1")
        XCTAssertEqual(item?.verify, "x --json", "the command truncates at the separator — that is the bug being reported")
        XCTAssertEqual(item?.status, .ready, "fields after the dropped one still parse")

        XCTAssertEqual(result.issues.map(\.line), [3])
        let issue = result.issues.first
        XCTAssertTrue(
            issue?.reason.contains("`python3 -c 'y'`") == true,
            "the reason must name what was dropped: \(issue?.reason ?? "")"
        )
        XCTAssertEqual(issue?.text, "- [ ] plat-1 | Config loader | verify: x --json | python3 -c 'y' | ready")
    }

    /// Rubric for the wording: someone looking at the banner must be able to fix
    /// the line without going and reading CLAUDE.md.
    func testTruncatedVerifyIssueSaysToWriteThePipeUnspaced() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | verify: x --json | python3 -c 'y'
        """

        let reason = BacklogParser.parseWithIssues(md).issues.first?.reason ?? ""

        XCTAssertTrue(reason.contains("unspaced"), "must name the fix: \(reason)")
        XCTAssertTrue(reason.contains("verify"), "must name the cause: \(reason)")
    }

    /// Several dropped fields on one line are one issue, not one per field —
    /// they share a cause and a fix.
    func testAllDroppedFieldsOnALineShareOneIssue() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | verify: a | python3 -c 'y' | python3 -c 'z' | ready
        """

        let issues = BacklogParser.parseWithIssues(md).issues

        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues.first?.reason.contains("`python3 -c 'y'`") == true)
        XCTAssertTrue(issues.first?.reason.contains("`python3 -c 'z'`") == true)
    }

    /// A line with no `verify:` gets the same report without the spaced-pipe
    /// story, which would be the wrong explanation there.
    func testDroppedFieldWithoutAVerifyListsTheFieldsALineCanCarry() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | owner: alice | ready
        """

        let issues = BacklogParser.parseWithIssues(md).issues

        XCTAssertEqual(issues.map(\.line), [3])
        let reason = issues.first?.reason ?? ""
        XCTAssertTrue(reason.contains("`owner: alice`"), "must name what was dropped: \(reason)")
        XCTAssertFalse(reason.contains("unspaced"), "no verify: on the line, so the pipe advice does not apply: \(reason)")
        XCTAssertTrue(reason.contains("`size:`"), "must say what a line can carry instead: \(reason)")
    }

    /// The chain's last branch absorbs short hyphenated junk as `completedDate`,
    /// so "unrecognised" means falling past *every* branch — not merely looking
    /// odd. Pinned so nobody widens the report into that grey area by accident.
    func testShortHyphenatedJunkIsStillReadAsADateNotReported() {
        let md = """
        ## Epic: Platform

        - [x] plat-2 | Log plumbing | not-a-date
        """

        let result = BacklogParser.parseWithIssues(md)

        XCTAssertEqual(result.file.sections.first?.items.first?.completedDate, "not-a-date")
        XCTAssertEqual(result.issues, [])
    }

    /// A status word on a `[x]` line is redundant — the checkbox already said
    /// done — but it is a field the parser knows, so reporting it as
    /// unrecognised would be noise on a hand-written backlog.
    func testStatusWordOnADoneLineIsNotReported() {
        let md = """
        ## Epic: Platform

        - [x] plat-2 | Log plumbing | done | 2026-01-15
        - [x] plat-3 | Feature flag | ready
        """

        let result = BacklogParser.parseWithIssues(md)

        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.file.sections.first?.items.map(\.status), [.done, .done])
    }

    /// Empty fields — `a | | b`, or a trailing separator — carry no text, so
    /// there is nothing to report as dropped.
    func testEmptyFieldsAreNotReported() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader |  | ready
        """

        XCTAssertEqual(BacklogParser.parseWithIssues(md).issues, [])
    }

    /// Every field the parser knows, on one line, must stay quiet.
    func testEveryRecognisedFieldTogetherReportsNoIssue() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | verify: swift test | size:M | needs:plat-0 | from:big-one | active
        - [ ] plat-2 | Log plumbing | blocked:waiting on design
        - [x] plat-3 | Feature flag | 12q | $3.40 | 2026-01-15
        - [ ] JIRA:ABC-123 | Imported | team | in-review
        """

        let result = BacklogParser.parseWithIssues(md)

        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(
            result.file.sections.first?.items.map(\.id),
            ["plat-1", "plat-2", "plat-3", "ABC-123"]
        )
    }

    /// The convenience entry point keeps its signature and its behaviour —
    /// existing callers are unaffected by the collection.
    func testParseItemLineStillReturnsTheItemForALineThatDroppedAField() {
        let item = BacklogParser.parseItemLine(
            "- [ ] plat-1 | Config loader | verify: x --json | python3 -c 'y' | ready",
            verifyDefault: nil
        )

        XCTAssertEqual(item?.id, "plat-1")
        XCTAssertEqual(item?.verify, "x --json")
    }

    /// The dropped fields are both reported *and* carried onto the item, so the
    /// write-back can put them back. Carrying them must not quiet the report:
    /// the item still runs a shorter command than the one that was written, and
    /// a banner that vanished the moment the text was preserved would leave
    /// nobody any the wiser.
    func testDroppedFieldsAreReportedAndAlsoCarriedOntoTheItem() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | verify: a | python3 -c 'y' | python3 -c 'z' | ready
        """

        let result = BacklogParser.parseWithIssues(md)

        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(
            result.file.sections.first?.items.first?.unrecognisedFields,
            ["python3 -c 'y'", "python3 -c 'z'"]
        )
    }

    /// The counterpart: a line the parser read whole carries nothing, so the
    /// serializer has nothing extra to write.
    func testALineWithNothingDroppedCarriesNoFields() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | verify: swift test | size:M | from:big-one | active
        """

        let result = BacklogParser.parseWithIssues(md)

        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.file.sections.first?.items.first?.unrecognisedFields, [])
    }

    // MARK: - Values a recognised field cannot read

    /// `size:` is the expensive one. `ItemSize(rawValue: "SMALL")` is nil, so the
    /// item reaches `DefinitionOfReady` with no size and is skipped at pickup
    /// for "no size set" — on a line that visibly reads `size:Small`. The value
    /// is reported so the reader is looking at the same fact the gate is.
    func testUnreadableSizeIsReportedWithTheAcceptedSizes() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | size:Small | ready
        """

        let result = BacklogParser.parseWithIssues(md)

        // The item is still there: this reports, it does not reject.
        let item = result.file.sections.first?.items.first
        XCTAssertEqual(item?.id, "plat-1")
        XCTAssertEqual(item?.status, .ready, "fields after the unreadable one still parse")

        XCTAssertEqual(result.issues.map(\.line), [3])
        let reason = result.issues.first?.reason ?? ""
        XCTAssertTrue(reason.contains("`size:Small`"), "must name the value as written: \(reason)")
        for accepted in ["XS", "S", "M", "L", "XL"] {
            XCTAssertTrue(reason.contains("`\(accepted)`"), "must name \(accepted) as accepted: \(reason)")
        }
        XCTAssertEqual(result.issues.first?.text, "- [ ] plat-1 | Config loader | size:Small | ready")
    }

    /// Reported, not repaired: `SMALL` looks like `S` and is not read as one, so
    /// nobody ends up running an item at a size they never wrote.
    func testUnreadableSizeIsLeftUnsetRatherThanGuessedAt() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | size:Small | ready
        - [ ] plat-2 | Log plumbing | size:medium | ready
        """

        let sizes = BacklogParser.parse(md).sections.first?.items.map(\.size)

        XCTAssertEqual(sizes, [nil, nil])
    }

    /// A cost and a query count fail the same way — the branch claims the field
    /// and `Double`/`Int` decline the value — so they are reported the same way,
    /// each with the shape its own field reads.
    func testUnreadableCostAndQueryCountAreReported() {
        let md = """
        ## Epic: Platform

        - [x] plat-1 | Config loader | $1,20 | 2026-01-15
        - [x] plat-2 | Log plumbing | abcq | 2026-01-15
        """

        let result = BacklogParser.parseWithIssues(md)
        let items = result.file.sections.first?.items

        XCTAssertEqual(items?.map(\.cost), [nil, nil])
        XCTAssertEqual(items?.map(\.queries), [nil, nil])
        XCTAssertEqual(items?.map(\.completedDate), ["2026-01-15", "2026-01-15"])

        XCTAssertEqual(result.issues.map(\.line), [3, 4])
        let cost = result.issues.first?.reason ?? ""
        XCTAssertTrue(cost.contains("`$1,20`"), "must name the value as written: \(cost)")
        XCTAssertTrue(cost.contains("`$3.50`"), "must show what a cost looks like: \(cost)")
        let queries = result.issues.last?.reason ?? ""
        XCTAssertTrue(queries.contains("`abcq`"), "must name the value as written: \(queries)")
        XCTAssertTrue(queries.contains("`12q`"), "must show what a query count looks like: \(queries)")
    }

    /// The values these fields do read must stay silent — including a lowercase
    /// `size:m`, which has always been accepted.
    func testReadableValuesRaiseNoIssue() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | size:m | ready
        - [ ] plat-2 | Log plumbing | size:XS | ready
        - [x] plat-3 | Feature flag | 12q | $3.50 | 2026-01-15
        """

        let result = BacklogParser.parseWithIssues(md)
        let items = result.file.sections.first?.items

        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(items?.map(\.size), [.m, .xs, nil])
        XCTAssertEqual(items?.last?.queries, 12)
        XCTAssertEqual(items?.last?.cost, 3.50)
    }

    /// A line carrying none of these fields gains no issue from the collection.
    func testLineWithoutSuchAFieldRaisesNoIssue() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | verify: swift test | needs:plat-0 | active
        """

        XCTAssertEqual(BacklogParser.parseWithIssues(md).issues, [])
    }

    /// An empty value is nothing to read rather than something unreadable — the
    /// same reading `a | | b` gets — and a bare `size:` is visibly unset on the
    /// line in the way `size:Small` is not.
    func testEmptyValueIsNotReported() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | size: | ready
        """

        let result = BacklogParser.parseWithIssues(md)

        XCTAssertEqual(result.issues, [])
        XCTAssertNil(result.file.sections.first?.items.first?.size)
    }

    /// Several unreadable values on one line are one issue, and each kind says
    /// what it reads once however many values got it wrong.
    func testAllUnreadableValuesOnALineShareOneIssue() {
        let md = """
        ## Epic: Platform

        - [x] plat-1 | Config loader | size:Small | size:Tiny | $1,20
        """

        let issues = BacklogParser.parseWithIssues(md).issues

        XCTAssertEqual(issues.count, 1)
        let reason = issues.first?.reason ?? ""
        XCTAssertTrue(reason.contains("`size:Small`"), reason)
        XCTAssertTrue(reason.contains("`size:Tiny`"), reason)
        XCTAssertTrue(reason.contains("`$1,20`"), reason)
        XCTAssertEqual(
            reason.components(separatedBy: "A size is written").count - 1, 1,
            "two unreadable sizes do not need telling twice: \(reason)"
        )
    }

    /// A dropped field and an unreadable value have different causes and
    /// different fixes, so a line carrying both gets both reports rather than
    /// one that has to cover for the other.
    func testADroppedFieldAndAnUnreadableValueAreReportedSeparately() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | owner: alice | size:Small | ready
        """

        let issues = BacklogParser.parseWithIssues(md).issues

        XCTAssertEqual(issues.map(\.line), [3, 3])
        XCTAssertTrue(issues.first?.reason.contains("`owner: alice`") == true, "\(issues)")
        XCTAssertTrue(issues.last?.reason.contains("`size:Small`") == true, "\(issues)")
    }

    /// The convenience entry point is unaffected: an unreadable value leaves the
    /// item parsed, with that one field unset.
    func testParseItemLineStillReturnsTheItemForAnUnreadableValue() {
        let item = BacklogParser.parseItemLine(
            "- [ ] plat-1 | Config loader | size:Small | ready",
            verifyDefault: nil
        )

        XCTAssertEqual(item?.id, "plat-1")
        XCTAssertNil(item?.size)
        XCTAssertEqual(item?.status, .ready)
    }

    /// The common shapes — including prose, links and `###` sub-headings that
    /// the parser folds away — must not raise noise.
    func testWellFormedBacklogHasNoIssues() {
        let md = """
        ---
        project: demo
        verify_default: swift build
        ---

        # Demo Backlog

        ## Epic: Platform

        Foundations first.

        ### Phase 1

        - [ ] plat-1 | Config loader | size:M | active
        - [x] plat-2 | Log plumbing | 3q | $0.42 | 2026-01-15
        - [ ] plat-3 | Feature flag → [detail](backlog/plat-3.md)
        """

        XCTAssertEqual(BacklogParser.parseWithIssues(md).issues, [])
    }

    /// `parse` stays the convenience entry point for callers that only want the
    /// content; it must agree with `parseWithIssues` on what parsed.
    func testParseReturnsTheSameFileAsParseWithIssues() {
        let md = """
        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen
        - [X] onb-2 | Malformed
        """

        XCTAssertEqual(
            BacklogParser.parse(md).sections.flatMap(\.items).map(\.id),
            BacklogParser.parseWithIssues(md).file.sections.flatMap(\.items).map(\.id)
        )
    }

    // MARK: - Detail file: Validation criteria

    /// The line whose detail file the cases below stand in for, so the criteria
    /// they parse can be run through the gate that reads them.
    private func groomedLine() -> BacklogItem {
        BacklogItem(id: "plain-bullet-validation", title: "Read plain-bullet criteria",
                    verify: "xcodebuild build", status: .ready, type: .local, size: .m,
                    detailPath: "backlog/plain-bullet-validation.md")
    }

    private func detailFile(validation: String, outOfScope: String = "- numbered lists") -> String {
        """
        ## What

        Autopilot skips a groomed item for having no criteria.

        ## How

        Widen the Validation filter to any `- ` bullet.

        ## Validation

        \(validation)

        ## Out of Scope

        \(outOfScope)
        """
    }

    /// A hand-groomed file that writes its criteria as ordinary bullets has
    /// criteria; reading none of them made autopilot skip the item at pickup for
    /// "no Validation criteria" over a file that plainly had a Validation section.
    func testPlainBulletValidationSectionYieldsItsCriteria() {
        let md = detailFile(validation: """
        - the run records its own tally
        - a skipped item names the clause it failed
        """)

        let detail = BacklogParser.parseDetail(md, fallbackID: "plain-bullet-validation")

        XCTAssertEqual(detail?.acceptanceCriteria,
                       ["the run records its own tally",
                        "a skipped item names the clause it failed"])

        let verdict = DefinitionOfReady.evaluate(item: groomedLine(), detail: detail)
        XCTAssertFalse(verdict.unmet.contains(.validation))
        XCTAssertFalse(verdict.summary.contains("Validation criteria"))
    }

    /// The scaffold the app writes — `BacklogViewModel.createDetail` and friends
    /// all emit `- [ ]` — reads exactly as it did, box stripped either way.
    func testCheckboxValidationSectionStillStripsItsBoxes() {
        let md = detailFile(validation: """
        - [ ] the run records its own tally
        - [x] a skipped item names the clause it failed
        """)

        XCTAssertEqual(BacklogParser.parseDetail(md, fallbackID: "plain-bullet-validation")?.acceptanceCriteria,
                       ["the run records its own tally",
                        "a skipped item names the clause it failed"])
    }

    /// A file part-way through being ticked off mixes the two spellings; every
    /// criterion comes back once, in the order written.
    func testMixedCheckboxAndPlainBulletsReturnEveryCriterionOnce() {
        let md = detailFile(validation: """
        - [x] the run records its own tally
        - a skipped item names the clause it failed
        - [ ] the gate still asks for criteria
        """)

        XCTAssertEqual(BacklogParser.parseDetail(md, fallbackID: "plain-bullet-validation")?.acceptanceCriteria,
                       ["the run records its own tally",
                        "a skipped item names the clause it failed",
                        "the gate still asks for criteria"])
    }

    /// Widening the filter to `- ` does not widen it to prose: a Validation
    /// section that only describes what to check lists nothing to check, and the
    /// Definition-of-Ready clause still fires.
    func testProseOnlyValidationSectionStillHasNoCriteria() {
        let md = detailFile(validation: "Check that the tally is recorded and the clause named.")

        let detail = BacklogParser.parseDetail(md, fallbackID: "plain-bullet-validation")

        XCTAssertEqual(detail?.acceptanceCriteria, [])
        let verdict = DefinitionOfReady.evaluate(item: groomedLine(), detail: detail)
        XCTAssertTrue(verdict.unmet.contains(.validation))
        XCTAssertEqual(verdict.summary, "detail file has no Validation criteria")
    }

    /// `## Acceptance Criteria` is the same section under another name, so it
    /// reads plain bullets too.
    func testAcceptanceCriteriaHeadingReadsPlainBulletsAsWell() {
        let md = """
        ## What

        Read plain bullets.

        ## Acceptance Criteria

        - the run records its own tally
        """

        XCTAssertEqual(BacklogParser.parseDetail(md, fallbackID: "plain-bullet-validation")?.acceptanceCriteria,
                       ["the run records its own tally"])
    }

    /// The sibling section this fix borrows its bullet test from is untouched:
    /// still plain bullets, still stripped of the `- ` and nothing else.
    func testOutOfScopeParsingIsUnchanged() {
        let md = detailFile(validation: "- the run records its own tally",
                            outOfScope: """
                            - numbered lists and `*` bullets
                            - [ ] a box someone typed out of habit
                            """)

        XCTAssertEqual(BacklogParser.parseDetail(md, fallbackID: "plain-bullet-validation")?.outOfScope,
                       ["numbered lists and `*` bullets",
                        "[ ] a box someone typed out of habit"])
    }

    // MARK: - Detail file on disk

    /// One byte that is not UTF-8 used to make the whole file unreadable, so a
    /// groomed item was refused at pickup for having no detail file at all.
    func testDetailFileWithABadByteStillParsesAndPassesTheDetailClause() throws {
        let dir = try makeTemporaryDirectory(prefix: "backlog-detail-bad-byte")
        let url = dir.appendingPathComponent("plain-bullet-validation.md")
        var data = Data("## What\n\nAutopilot skips a groomed ".utf8)
        data.append(0xFF)
        data.append(Data("""
         item.

        ## How

        Read the file lossily.

        ## Validation

        - the sections parse
        """.utf8))
        try data.write(to: url)

        let detail = BacklogParser.parseDetail(at: url)

        XCTAssertNotNil(detail)
        XCTAssertTrue(detail?.what?.contains("\u{FFFD}") == true, "the bad byte reads as U+FFFD: \(detail?.what ?? "nil")")
        XCTAssertFalse(detail?.approach?.isEmpty ?? true)
        XCTAssertFalse(detail?.acceptanceCriteria.isEmpty ?? true)
        let verdict = DefinitionOfReady.evaluate(item: groomedLine(), detail: detail)
        XCTAssertFalse(verdict.unmet.contains(.detail))
    }

    func testMissingDetailFileStillParsesAsNil() throws {
        let dir = try makeTemporaryDirectory(prefix: "backlog-detail-missing")

        XCTAssertNil(BacklogParser.parseDetail(at: dir.appendingPathComponent("absent.md")))
    }

    // MARK: - The edges of a line, and the wording of a report

    /// A bare id is a legitimate jot: the title is simply empty, not invented,
    /// and the line is not refused.
    func testAnItemWithOnlyAnIdParsesWithAnEmptyTitle() {
        let item = BacklogParser.parseItemLine("- [ ] fix-1", verifyDefault: nil)

        XCTAssertEqual(item?.id, "fix-1")
        XCTAssertEqual(item?.title, "")
    }

    /// One dropped field reads as a sentence about that field — singular —
    /// not boilerplate about "fields".
    func testASingleDroppedFieldIsReportedInTheSingular() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | owner: alice | ready
        """

        let reason = BacklogParser.parseWithIssues(md).issues.first?.reason ?? ""

        XCTAssertTrue(
            reason.hasPrefix("Unrecognised field `owner: alice` — dropped, so it has no effect."),
            reason
        )
    }

    /// Same rubric for a value a recognised field could not read.
    func testASingleUnreadableValueIsReportedInTheSingular() {
        let md = """
        ## Epic: Platform

        - [ ] plat-1 | Config loader | size:Small | ready
        """

        let reason = BacklogParser.parseWithIssues(md).issues.first?.reason ?? ""

        XCTAssertTrue(
            reason.hasPrefix("Unreadable value `size:Small` — the field is recognised but its value is not, so it was left unset."),
            reason
        )
    }
}
