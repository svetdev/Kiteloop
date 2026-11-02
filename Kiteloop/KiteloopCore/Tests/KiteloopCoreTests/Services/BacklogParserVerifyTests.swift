import XCTest
@testable import KiteloopCore

/// `verify:` is the one token the autopilot cannot get wrong: it is the command
/// that decides whether an item's work is accepted, and it reaches the runner as
/// `item.verify ?? file.verifyDefault`. So the parser has to be exact about two
/// things — which items inherit the file-level default, and what an item's own
/// token is worth once a human has typed it by hand.
///
/// These tests drive `parseItemLine` with the line shapes people actually write
/// (the serializer's own output is covered by BacklogRoundTripTests, and the
/// section/frontmatter structure by BacklogParserSectionTests).
final class BacklogParserVerifyTests: XCTestCase {

    private let defaultVerify = "swift build"

    private func parse(_ line: String, verifyDefault: String? = nil) -> BacklogItem? {
        BacklogParser.parseItemLine(line, verifyDefault: verifyDefault)
    }

    // MARK: - Override vs fallback

    func testItemVerifyOverridesTheDefault() {
        let item = parse(
            "- [ ] onb-1 | Welcome screen | verify: swift test | size:M | ready",
            verifyDefault: defaultVerify
        )

        XCTAssertEqual(item?.verify, "swift test")
    }

    func testItemWithoutVerifyInheritsTheDefault() {
        let item = parse(
            "- [ ] onb-1 | Welcome screen | size:M | ready",
            verifyDefault: defaultVerify
        )

        XCTAssertEqual(item?.verify, defaultVerify)
    }

    func testItemWithoutVerifyAndNoDefaultHasNoCommand() {
        XCTAssertNil(parse("- [ ] onb-1 | Welcome screen | size:M | ready")?.verify)
    }

    func testItemVerifyStandsAloneWithoutADefault() {
        XCTAssertEqual(
            parse("- [ ] onb-1 | Welcome screen | verify: swift test")?.verify,
            "swift test"
        )
    }

    /// A file's `verify_default` is no fallback: the items that declare
    /// nothing have no command, beside the ones that declare their own.
    func testItemsWithoutTheirOwnVerifyIgnoreTheFilesDefault() {
        let md = """
        ---
        project: demo
        verify_default: swift build
        ---

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen | size:S | ready
        - [ ] onb-2 | Email verification | verify: swift test --filter Email | size:M | active
        - [ ] onb-3 | Password reset | verify: make check | size:S | ready
        - [x] onb-4 | Sign-out | 4q | $0.12 | 2026-01-15
        """

        let items = BacklogParser.parse(md).sections.flatMap(\.items)

        XCTAssertEqual(
            items.map(\.verify),
            [nil, "swift test --filter Email", "make check", nil]
        )
    }

    /// With no `verify_default` the items that declare nothing stay `nil` — the
    /// parser must not borrow a sibling's command to fill the gap.
    func testItemsKeepTheirOwnCommandsWhenNoDefaultIsDeclared() {
        let md = """
        ---
        project: demo
        ---

        ## Epic: Onboarding

        - [ ] onb-1 | Welcome screen | size:S | ready
        - [ ] onb-2 | Email verification | verify: swift test | size:M | ready
        - [ ] onb-3 | Password reset | size:S | ready
        """

        let items = BacklogParser.parse(md).sections.flatMap(\.items)

        XCTAssertEqual(items.map(\.verify), [nil, "swift test", nil])
    }

    /// The fallback is not limited to open work: a finished item still reports a
    /// command, so re-running verification on `done` items stays possible.
    func testDoneItemsAlsoInheritTheDefault() {
        let item = parse(
            "- [x] onb-1 | Welcome screen | size:S | 12q | $1.20 | 2026-01-15",
            verifyDefault: defaultVerify
        )

        XCTAssertEqual(item?.status, .done)
        XCTAssertEqual(item?.verify, defaultVerify)
    }

    func testJiraItemsInheritAndOverrideLikeLocalOnes() {
        let inherited = parse("- [ ] JIRA:PROJ-77 | Wire up SSO | size:M | ready", verifyDefault: defaultVerify)
        let overridden = parse("- [ ] PROJ-78 | Invoice PDFs | verify: make check | size:M | ready", verifyDefault: defaultVerify)

        XCTAssertEqual(inherited?.jiraKey, "PROJ-77")
        XCTAssertEqual(inherited?.verify, defaultVerify)
        XCTAssertEqual(overridden?.jiraKey, "PROJ-78")
        XCTAssertEqual(overridden?.verify, "make check")
    }

    // MARK: - How the token is written

    /// The space after `verify:` is cosmetic, and stray padding is trimmed —
    /// the command must come out identical either way.
    func testSpacingAroundTheTokenDoesNotChangeTheCommand() {
        let shapes = [
            "- [ ] onb-1 | Welcome | verify: swift test",
            "- [ ] onb-1 | Welcome | verify:swift test",
            "- [ ] onb-1 | Welcome | verify:    swift test   "
        ]

        for line in shapes {
            XCTAssertEqual(parse(line, verifyDefault: defaultVerify)?.verify, "swift test", line)
        }
    }

    /// Tokens are matched by prefix, not position — `verify:` is still the
    /// verify command when a human types it after `size:`.
    func testTokenOrderDoesNotMatter() {
        let item = parse(
            "- [ ] onb-1 | Welcome | size:M | active | verify: swift test",
            verifyDefault: defaultVerify
        )

        XCTAssertEqual(item?.verify, "swift test")
        XCTAssertEqual(item?.size, .m)
        XCTAssertEqual(item?.status, .active)
    }

    /// Only the `verify:` prefix is consumed; colons inside the command belong
    /// to the command, which matters for `--filter Suite:Case` and for
    /// `xcodebuild -destination "platform=macOS"`-shaped invocations.
    func testCommandKeepsItsOwnColonsAndQuotes() {
        let line = "- [ ] onb-1 | Welcome | verify: xcodebuild -scheme Kiteloop -destination \"platform=macOS\" test -only-testing:KiteloopTests/BacklogParserVerifyTests"

        XCTAssertEqual(
            parse(line, verifyDefault: defaultVerify)?.verify,
            "xcodebuild -scheme Kiteloop -destination \"platform=macOS\" test -only-testing:KiteloopTests/BacklogParserVerifyTests"
        )
    }

    /// The command survives the `→ [detail](…)` link that grooming adds — the
    /// link is stripped before the tokens are read, not after.
    func testCommandSurvivesADetailLink() {
        let item = parse(
            "- [ ] onb-1 | Welcome | verify: swift test | size:S | ready → [detail](backlog/onb-1.md)",
            verifyDefault: defaultVerify
        )

        XCTAssertEqual(item?.verify, "swift test")
        XCTAssertEqual(item?.detailPath, "backlog/onb-1.md")
    }

    func testCommandSurvivesAlongsideABlockedReason() {
        let item = parse(
            "- [ ] onb-1 | Welcome | verify: swift test | blocked:waiting on design",
            verifyDefault: defaultVerify
        )

        XCTAssertEqual(item?.verify, "swift test")
        XCTAssertEqual(item?.status, .blocked)
        XCTAssertEqual(item?.blockedReason, "waiting on design")
    }

    // MARK: - Shapes the one-line format cannot carry

    /// `verify:` is the third field onwards; the first two are always id and
    /// title. A token typed in the title slot is a title, and the item falls
    /// back to the default rather than silently running it.
    func testTokenInTheTitlePositionIsReadAsTheTitle() {
        let item = parse("- [ ] onb-1 | verify: swift test", verifyDefault: defaultVerify)

        XCTAssertEqual(item?.title, "verify: swift test")
        XCTAssertEqual(item?.verify, defaultVerify)
    }

    /// Fields are separated by `" | "` — spaces included. A token glued to the
    /// pipe stays part of the title, so it never becomes a verify command.
    func testTokenNeedsSpacesAroundItsSeparator() {
        let item = parse("- [ ] onb-1 | Welcome |verify: swift test", verifyDefault: defaultVerify)

        XCTAssertEqual(item?.verify, defaultVerify)
    }

    /// Known limitation: `|` is the field separator, so a shell pipeline in a
    /// one-line item is cut at the first `|`. Multi-command verification belongs
    /// in the item's detail file `verify:` block, which parses a real list.
    func testShellPipelineInTheCommandIsCutAtTheSeparator() {
        let item = parse(
            "- [ ] onb-1 | Welcome | verify: swift test | tee out.log",
            verifyDefault: defaultVerify
        )

        XCTAssertEqual(item?.verify, "swift test")
    }

    /// An empty `verify:` is still an explicit token, so it wins over the
    /// default and yields an empty command rather than `nil`. Consumers read
    /// `item.verify ?? verifyDefault`, so this suppresses the fallback — an
    /// item that means "use the default" must omit the token entirely.
    func testEmptyTokenSuppressesTheDefault() {
        let item = parse("- [ ] onb-1 | Welcome | verify: | ready", verifyDefault: defaultVerify)

        XCTAssertEqual(item?.verify, "")
        XCTAssertNotNil(item?.verify, "an empty token must not fall through to the default")
    }

    /// When a line carries the token twice — an edit layered over an older
    /// command — the last one written is the one that runs.
    func testLastTokenWinsWhenTheCommandIsDuplicated() {
        let item = parse(
            "- [ ] onb-1 | Welcome | verify: swift build | verify: swift test",
            verifyDefault: defaultVerify
        )

        XCTAssertEqual(item?.verify, "swift test")
    }

    // MARK: - Detail front-matter `cmd:`

    private func detailCommands(_ frontMatter: String) -> [String] {
        let md = """
        ---
        id: x
        title: X
        \(frontMatter)
        ---

        ## What
        """
        return BacklogParser.parseDetail(md)?.verifyCommands.map(\.cmd) ?? []
    }

    /// A command that quotes an inline script is written with `\\"` in YAML. The
    /// parser trimmed quote characters instead of resolving escapes, so the
    /// command reached the runner as `python3 -c \\"import json; assert x\\` —
    /// backslashes intact, closing quote eaten. Three website-audit
    /// items were unrunnable on this.
    func testEscapedQuotesInACommandAreResolved() {
        let commands = detailCommands("""
        verify:
          - name: t
            cmd: "python3 -c \\"import json; assert json.load(open('x.json')); print('ok')\\""
        """)

        XCTAssertEqual(commands, ["python3 -c \"import json; assert json.load(open('x.json')); print('ok')\""])
    }

    /// The common case has no quoting at all and must be untouched.
    func testAnUnquotedCommandIsUnchanged() {
        let commands = detailCommands("""
        verify:
          - name: t
            cmd: swift build
        """)

        XCTAssertEqual(commands, ["swift build"])
    }

    /// A plainly quoted command loses only its delimiters.
    func testAQuotedCommandLosesOnlyItsDelimiters() {
        let commands = detailCommands("""
        verify:
          - name: t
            cmd: "cd Kiteloop && xcodebuild build"
        """)

        XCTAssertEqual(commands, ["cd Kiteloop && xcodebuild build"])
    }

    /// Every writer now escapes what it quotes, but the files already on disk
    /// were written by ones that didn't: `createDetail`'s scaffold copied an
    /// item line's verify into quotes as it stood, so a command that quotes its
    /// own argument sits there with bare inner quotes. It has always read as the
    /// whole command, and it still has to — the fix is to the writers, and
    /// nothing rewrites what is already filed.
    func testUnescapedInnerQuotesStillReadAsPartOfTheCommand() {
        let commands = detailCommands("""
        verify:
          - name: t
            cmd: "cd Kiteloop && xcodebuild -destination "platform=macOS" build"
        """)

        XCTAssertEqual(commands, ["cd Kiteloop && xcodebuild -destination \"platform=macOS\" build"])
    }

    /// An escaped backslash is one backslash, not an escape for what follows.
    func testEscapedBackslashesSurviveAsOne() {
        let commands = detailCommands("""
        verify:
          - name: t
            cmd: "grep \\\\\\\\d out.txt"
        """)

        XCTAssertEqual(commands, ["grep \\\\d out.txt"])
    }

    /// The verify block ends where the next frontmatter key begins: `expect:`
    /// stays with its command, and a `status:` after the block is a field
    /// again, not more of the block.
    func testAVerifyBlockKeepsItsExpectAndReleasesTheKeysAfterIt() {
        let md = """
        ---
        id: x
        title: X
        verify:
          - name: tests
            cmd: swift test
            expect: exit 0
        status: ready
        ---

        ## What
        """

        let detail = BacklogParser.parseDetail(md)

        XCTAssertEqual(detail?.verifyCommands.count, 1)
        XCTAssertEqual(detail?.verifyCommands.first?.name, "tests")
        XCTAssertEqual(detail?.verifyCommands.first?.cmd, "swift test")
        XCTAssertEqual(detail?.verifyCommands.first?.expect, "exit 0")
        XCTAssertEqual(detail?.status, "ready", "the key after the block must be read as a field")
    }

    /// A quoted command comes through letter for letter — `npm` must not have
    /// its first letter read as the `\\n` escape.
    func testAQuotedCommandStartingWithAnEscapableLetterIsUntouched() {
        XCTAssertEqual(detailCommands("""
        verify:
          - name: t
            cmd: "npm test"
        """), ["npm test"])
    }

    /// `jira:` carries the linked key, and a literal `null` reads back as none.
    func testJiraReadsItsKeyAndNullMeansNone() {
        let linked = BacklogParser.parseDetail("---\nid: x\njira: PROJ-7\n---\n")
        let none = BacklogParser.parseDetail("---\nid: x\njira: null\n---\n")

        XCTAssertEqual(linked?.jira, "PROJ-7")
        XCTAssertNil(none?.jira)
    }

    // MARK: - Widening a detail's verify list

    /// The entry lands inside the frontmatter list, after the commands already
    /// there and before the next key, and is read back by the same parser —
    /// a groomed detail's list is what a run executes, so the line alone
    /// widened would declare a command no run makes.
    func testWideningADetailAddsAnEntryTheParserReadsBack() throws {
        let content = """
        ---
        id: item
        title: An item
        verify:
          - name: build
            cmd: "swift build"
        size: S
        ---

        ## What
        """
        let widened = try XCTUnwrap(BacklogParser.wideningDetailVerify(
            content, adding: "cd \"$(git rev-parse --show-toplevel)\" && ./quality/bin/check-complexity.sh"))
        let detail = try XCTUnwrap(BacklogParser.parseDetail(widened))
        XCTAssertEqual(detail.verifyCommands.map(\.name), ["build", "verify-map"])
        XCTAssertEqual(detail.verifyCommands.last?.cmd,
                       "cd \"$(git rev-parse --show-toplevel)\" && ./quality/bin/check-complexity.sh")
        XCTAssertEqual(detail.size, "S", "the key after the list still parses as its own")
        XCTAssertTrue(widened.hasSuffix("\n## What"), "the body is untouched")
    }

    /// No list, nothing to widen: the line is the whole verify then, and the
    /// caller has already widened it.
    func testADetailWithoutAVerifyListIsLeftToTheLine() {
        XCTAssertNil(BacklogParser.wideningDetailVerify("---\nid: item\n---\n\n## What\n", adding: "x"))
        XCTAssertNil(BacklogParser.wideningDetailVerify("## What\n", adding: "x"))
        XCTAssertNil(BacklogParser.wideningDetailVerify("---\nid: item\nverify:\n---\n", adding: "x"),
                     "an empty list has no entry to sit beside")
    }
}
