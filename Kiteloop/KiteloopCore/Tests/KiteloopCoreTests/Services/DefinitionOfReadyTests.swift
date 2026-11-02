import XCTest
@testable import KiteloopCore

/// The ODD gate autopilot applies at pickup: which items are inside the
/// Definition-of-Ready, and what a refused item is told is missing.
final class DefinitionOfReadyTests: XCTestCase {

    private func item(
        id: String = "sync-dedup-guard",
        title: String = "Guard sync dedup",
        verify: String? = "xcodebuild build",
        size: ItemSize? = .m,
        status: BacklogItemStatus = .ready,
        needs: [String] = []
    ) -> BacklogItem {
        BacklogItem(id: id, title: title,
                    verify: verify, status: status, type: .local, size: size,
                    detailPath: "backlog/\(id).md", needs: needs)
    }

    private func detail(
        what: String? = "Dedupe the sync queue.",
        approach: String? = "Key on the remote id in SyncQueue.",
        criteria: [String] = ["A duplicate push is dropped"],
        verify: [BacklogItemDetail.VerifyCommand] = [.init(name: "build", cmd: "xcodebuild build", expect: nil)],
        size: String? = nil
    ) -> BacklogItemDetail {
        BacklogItemDetail(id: "sync-dedup-guard", title: "Guard sync dedup", size: size,
                          verifyCommands: verify,
                          acceptanceCriteria: criteria, outOfScope: [],
                          what: what, approach: approach)
    }

    // MARK: - Inside the ODD

    func testGroomedItemIsReady() {
        let verdict = DefinitionOfReady.evaluate(item: item(), detail: detail())
        XCTAssertTrue(verdict.isReady)
        XCTAssertEqual(verdict.unmet, [])
        XCTAssertEqual(verdict.summary, "")
    }

    func testEmptyOutOfScopeDoesNotBlock() {
        // An empty out-of-scope list reads the same as an unwritten one, so the
        // gate can't tell them apart and deliberately doesn't try.
        XCTAssertTrue(DefinitionOfReady.evaluate(item: item(), detail: detail()).isReady)
    }

    func testEverySizeUpToMIsReady() {
        for size in [ItemSize.xs, .s, .m] {
            XCTAssertTrue(DefinitionOfReady.evaluate(item: item(size: size), detail: detail()).isReady,
                          "\(size.rawValue) should be runnable")
        }
    }

    /// `from:` records where the work came from and nothing else. It is not
    /// `needs:` — a parent that is missing, unfinished or archived says nothing
    /// about whether this item can be picked up, so the gate must not read it.
    func testProvenanceIsInvisibleToTheGate() {
        var withParent = item()
        withParent.from = "an-item-that-no-longer-exists"
        XCTAssertEqual(DefinitionOfReady.evaluate(item: withParent, detail: detail()).unmet,
                       DefinitionOfReady.evaluate(item: item(), detail: detail()).unmet)
        XCTAssertTrue(DefinitionOfReady.evaluate(item: withParent, detail: detail()).isReady)

        // And it rescues nothing either: an ungroomed item with a parent is still
        // ungroomed.
        var ungroomed = item(verify: nil, size: nil)
        ungroomed.from = "some-parent"
        XCTAssertEqual(DefinitionOfReady.evaluate(item: ungroomed, detail: nil).unmet,
                       DefinitionOfReady.evaluate(item: item(verify: nil, size: nil), detail: nil).unmet)
    }

    // MARK: - Missing detail file

    func testNoDetailFileIsNotReady() {
        let verdict = DefinitionOfReady.evaluate(item: item(), detail: nil)
        XCTAssertFalse(verdict.isReady)
        // Reported once as "write the file", not four times as its missing sections.
        XCTAssertEqual(verdict.unmet, [.detail])
        XCTAssertTrue(verdict.summary.contains("backlog/sync-dedup-guard.md"), verdict.summary)
    }

    func testItemVerifyStillCountsWithoutADetailFile() {
        // The item line's verify: is a real command, so only the file is missing.
        XCTAssertEqual(DefinitionOfReady.evaluate(item: item(), detail: nil).unmet, [.detail])
        XCTAssertEqual(DefinitionOfReady.evaluate(item: item(verify: nil), detail: nil).unmet,
                       [.detail, .verify])
    }

    // MARK: - Missing sections

    func testBlankWhatHowAndValidationAreEachReported() {
        let verdict = DefinitionOfReady.evaluate(
            item: item(),
            detail: detail(what: "   ", approach: nil, criteria: [" "])
        )
        XCTAssertEqual(verdict.unmet, [.what, .how, .validation])
        XCTAssertEqual(verdict.reasons.count, 3)
    }

    func testMissingValidationAloneBlocks() {
        let verdict = DefinitionOfReady.evaluate(item: item(), detail: detail(criteria: []))
        XCTAssertEqual(verdict.unmet, [.validation])
    }

    // MARK: - verify:

    func testNoVerifyAnywhereBlocks() {
        let verdict = DefinitionOfReady.evaluate(item: item(verify: nil), detail: detail(verify: []))
        XCTAssertEqual(verdict.unmet, [.verify])
    }

    func testBlankGroomedCommandFallsBackToTheItemLine() {
        let blank = detail(verify: [.init(name: "empty", cmd: "  ", expect: nil)])
        XCTAssertTrue(DefinitionOfReady.evaluate(item: item(), detail: blank).isReady)
        XCTAssertEqual(DefinitionOfReady.evaluate(item: item(verify: "  "), detail: blank).unmet, [.verify])
    }

    func testGroomedCommandCountsWhenTheItemLineHasNone() {
        XCTAssertTrue(DefinitionOfReady.evaluate(item: item(verify: nil), detail: detail()).isReady)
    }

    /// A verify map with a rule matching every path gates every merge on its
    /// own, so an item needs no `verify:` of its own to be finishable.
    func testNoVerifyIsReadyWhenTheMapCoversEveryPath() {
        let verdict = DefinitionOfReady.evaluate(item: item(verify: nil), detail: detail(verify: []),
                                                 verifyMapCoversEveryPath: true)
        XCTAssertTrue(verdict.isReady)
    }

    func testNoVerifyIsRefusedWithTheSameReasonWithoutACatchAllRule() {
        let verdict = DefinitionOfReady.evaluate(item: item(verify: nil), detail: detail(verify: []),
                                                 verifyMapCoversEveryPath: false)
        XCTAssertEqual(verdict.unmet, [.verify])
        XCTAssertEqual(verdict.reasons, ["no verify: command — nothing objective for the run to pass"])
    }

    // MARK: - A verify: the backlog line can't carry

    /// A spaced shell pipe *is* the line's field separator, so the command would
    /// be truncated at it and the merge gate would open on the first half. The
    /// item is refused, and told the one thing that fixes it — not that it has
    /// no verify command, which it plainly does.
    func testASpacedPipeInTheItemVerifyIsNotReady() {
        let verdict = DefinitionOfReady.evaluate(
            item: item(verify: "swift build | python3 -c 'print(1)'"), detail: detail(verify: []))

        XCTAssertFalse(verdict.isReady)
        XCTAssertEqual(verdict.unmet, [.verifySeparator])
        XCTAssertTrue(verdict.summary.contains("unspaced"), verdict.summary)
        XCTAssertFalse(verdict.summary.contains("no verify:"), verdict.summary)
    }

    /// And the fix the reason names is the whole of it: the same command with
    /// the spaces taken out files as ready.
    func testTheSameCommandWithAnUnspacedPipeIsReady() {
        XCTAssertTrue(DefinitionOfReady.evaluate(
            item: item(verify: "swift build|python3 -c 'print(1)'"), detail: detail(verify: [])).isReady)
    }

    /// Only the separator is refused, not the pipe character. A redirect, a
    /// `||`, a pipe with a space on one side only — none of them split the line.
    func testOnlyTheFieldSeparatorIsRefused() {
        for command in ["swift build|wc -l", "swift build ||true", "swift build|| true",
                        "swift build 2>&1|grep -q ok", "swift build|| echo fail"] {
            XCTAssertTrue(DefinitionOfReady.evaluate(item: item(verify: command),
                                                     detail: detail(verify: [])).isReady,
                          "\(command) should be runnable")
        }
    }

    /// A detail file's verify command is read from YAML, not from a split line,
    /// so a spaced pipe there runs exactly as written. Refusing it would refuse
    /// a command that works.
    func testASpacedPipeInTheDetailFileAloneIsUntouched() {
        let groomed = detail(verify: [.init(name: "build", cmd: "swift build | wc -l", expect: nil)])
        XCTAssertTrue(DefinitionOfReady.evaluate(item: item(verify: nil), detail: groomed).isReady)
        XCTAssertTrue(DefinitionOfReady.evaluate(item: item(), detail: groomed).isReady)
    }

    /// The clause judges the line's own field, so it fires even when a groomed
    /// command exists alongside: `BacklogAutopilot.mergeVerifyPlan` gates the
    /// auto-merge on `item.verify` whatever the detail file says.
    func testTheClauseFiresEvenWhenTheDetailCarriesAGoodCommand() {
        XCTAssertEqual(DefinitionOfReady.evaluate(item: item(verify: "a | b"), detail: detail()).unmet,
                       [.verifySeparator])
    }

    /// Inert at pickup by construction: the parser split the line on `" | "`
    /// before building the item, so nothing it produces can carry one — an item
    /// that is ready today stays ready.
    func testAnItemParsedFromABacklogLineIsUnaffected() {
        let line = "- [ ] sync-dedup-guard | Guard sync dedup | "
            + "verify: swift build | python3 -c 'print(1)' | size:M"
        guard let parsed = BacklogParser.parseItemLine(line, verifyDefault: nil) else {
            return XCTFail("the line should still parse")
        }

        XCTAssertEqual(parsed.verify, "swift build")
        XCTAssertTrue(DefinitionOfReady.evaluate(item: parsed, detail: detail()).isReady)
    }

    // MARK: - A title the backlog line can't carry

    /// The title is the line's second field, so a separator inside it is dropped
    /// on the next write-back and the title on disk is shorter than the one that
    /// was groomed. Refused with the one thing that fixes it.
    func testATitleHoldingTheFieldSeparatorIsNotReady() {
        let verdict = DefinitionOfReady.evaluate(
            item: item(title: "Retry the push | and log the attempt"), detail: detail())

        XCTAssertFalse(verdict.isReady)
        XCTAssertEqual(verdict.unmet, [.titleSeparator])
        XCTAssertTrue(verdict.summary.contains("title"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains(DefinitionOfReady.fieldSeparator), verdict.summary)
    }

    /// Only the separator is refused, not the pipe character — none of these
    /// split the line, so the title survives verbatim.
    func testOnlyTheFieldSeparatorIsRefusedInATitle() {
        for title in ["Guard sync|dedup", "Guard sync |dedup", "Guard sync| dedup",
                      "Handle a|b|c ids", "Guard sync ||dedup"] {
            XCTAssertTrue(DefinitionOfReady.evaluate(item: item(title: title), detail: detail()).isReady,
                          "\(title) should be runnable")
        }
    }

    /// An ordinary title adds nothing: the clause is silent and the verdict is
    /// exactly what it was before it existed.
    func testATitleWithoutASeparatorIsUnaffected() {
        let verdict = DefinitionOfReady.evaluate(item: item(), detail: detail())
        XCTAssertEqual(verdict.unmet, [])
        XCTAssertEqual(verdict.reasons, [])
    }

    /// Inline grooming puts What/How/Validation in the title itself, and that
    /// title is still just a field — it satisfies `isGroomedInline` and stays
    /// ready, with or without a detail file.
    func testAnInlineGroomedTitleStaysReady() {
        let inline = item(title: "WHAT: dedupe pushes HOW: key on remote id VALIDATE: duplicate dropped")
        XCTAssertTrue(DefinitionOfReady.isGroomedInline(inline))
        XCTAssertTrue(DefinitionOfReady.evaluate(item: inline, detail: nil).isReady)
        XCTAssertTrue(DefinitionOfReady.evaluate(item: inline, detail: detail()).isReady)
    }

    /// Inert at pickup by construction, like the `verify:` clause: the parser
    /// split the line on `" | "` before building the item, so `parts[1]` cannot
    /// hold one — the tail became an unrecognised field, which is the loss this
    /// clause exists to refuse at grooming.
    func testATitleParsedFromABacklogLineIsUnaffected() {
        let line = "- [ ] sync-dedup-guard | Guard sync dedup | and log it | "
            + "verify: swift build | size:M"
        guard let parsed = BacklogParser.parseItemLine(line, verifyDefault: nil) else {
            return XCTFail("the line should still parse")
        }

        XCTAssertEqual(parsed.title, "Guard sync dedup")
        XCTAssertFalse(DefinitionOfReady.titleHoldsFieldSeparator(parsed))
    }

    // MARK: - Size

    func testUnsizedItemIsNotReady() {
        let verdict = DefinitionOfReady.evaluate(item: item(size: nil), detail: detail())
        XCTAssertEqual(verdict.unmet, [.size])
    }

    func testSizeFallsBackToTheDetailFrontmatter() {
        XCTAssertTrue(DefinitionOfReady.evaluate(item: item(size: nil), detail: detail(size: "S")).isReady)
        // Frontmatter is free text, so a lowercase size is the same statement.
        XCTAssertTrue(DefinitionOfReady.evaluate(item: item(size: nil), detail: detail(size: " m ")).isReady)
        XCTAssertEqual(DefinitionOfReady.evaluate(item: item(size: nil), detail: detail(size: "huge")).unmet,
                       [.size])
    }

    func testLAndXLAreTooLarge() {
        for size in [ItemSize.l, .xl] {
            let verdict = DefinitionOfReady.evaluate(item: item(size: size), detail: detail())
            XCTAssertEqual(verdict.unmet, [.sizeTooLarge], "\(size.rawValue) should be refused")
            XCTAssertTrue(verdict.summary.contains(size.rawValue), verdict.summary)
        }
    }

    func testItemLineSizeWinsOverTheFrontmatter() {
        // The backlog line is what the panel shows and what a groomer edits last.
        XCTAssertEqual(DefinitionOfReady.effectiveSize(item: item(size: .l), detail: detail(size: "S")), .l)
    }

    // MARK: - needs:

    /// The sequencing failure the clause exists to stop: an item promoted to
    /// `ready` ahead of what it builds on read as runnable work, and a worker
    /// spent a run discovering the dependency the file stated only in prose.
    func testDependencyThatIsNotDoneBlocks() {
        let dependent = item(needs: ["run-output-pr"])
        let verdict = DefinitionOfReady.evaluate(
            item: dependent, detail: detail(),
            dependencies: .init(items: [dependent, item(id: "run-output-pr")]))

        XCTAssertFalse(verdict.isReady)
        XCTAssertEqual(verdict.unmet, [.dependency])
        XCTAssertEqual(verdict.reasons, ["needs run-output-pr — not done (ready)"])
    }

    /// And the moment the prerequisite lands, nothing else has to change for the
    /// dependent to be picked up.
    func testTheItemIsReadyAsSoonAsItsDependencyIsDone() {
        let dependent = item(needs: ["run-output-pr"])
        let verdict = DefinitionOfReady.evaluate(
            item: dependent, detail: detail(),
            dependencies: .init(items: [dependent, item(id: "run-output-pr", status: .done)]))

        XCTAssertTrue(verdict.isReady, verdict.summary)
    }

    /// `done` is the only state that satisfies a dependency — a prerequisite that
    /// is merely selected, in flight or stuck is exactly the thing that isn't
    /// built yet.
    func testOnlyDoneSatisfiesADependency() {
        for status in BacklogItemStatus.allCases {
            let dependent = item(needs: ["prereq"])
            let verdict = DefinitionOfReady.evaluate(
                item: dependent, detail: detail(),
                dependencies: .init(items: [dependent, item(id: "prereq", status: status)]))
            XCTAssertEqual(verdict.isReady, status == .done,
                           "a \(status.rawValue) dependency: \(verdict.summary)")
        }
    }

    /// A typo must not make an item runnable. An id that names nothing is a
    /// dependency nobody can satisfy, so it reads as unmet — and says which of
    /// the two problems it is, since "not done" would send the groomer looking
    /// for an item that was never there.
    func testDependencyOnANonexistentIDIsNotReadyAndSaysSo() {
        let dependent = item(needs: ["no-such-item"])
        let verdict = DefinitionOfReady.evaluate(
            item: dependent, detail: detail(), dependencies: .init(items: [dependent]))

        XCTAssertEqual(verdict.unmet, [.dependency])
        XCTAssertEqual(verdict.reasons, ["needs no-such-item — no such item"])
    }

    /// Two items waiting on each other are both stuck forever, and "not done"
    /// reads like a queue that will sort itself out. Both are refused, and both
    /// are told what the loop is.
    func testATwoItemCycleIsReportedToBothItemsNamingTheCycle() {
        let a = item(id: "a", needs: ["b"])
        let b = item(id: "b", needs: ["a"])
        let backlog = DefinitionOfReady.Dependencies(items: [a, b])

        let first = DefinitionOfReady.evaluate(item: a, detail: detail(), dependencies: backlog)
        let second = DefinitionOfReady.evaluate(item: b, detail: detail(), dependencies: backlog)

        XCTAssertEqual(first.reasons, ["needs b — dependency cycle: a → b → a"])
        XCTAssertEqual(second.reasons, ["needs a — dependency cycle: b → a → b"])
    }

    /// A longer loop is walked breadth-first rather than followed, so a
    /// self-referential backlog reports rather than hangs.
    func testALongerCycleIsReportedInFull() {
        let a = item(id: "a", needs: ["b"])
        let b = item(id: "b", needs: ["c"])
        let c = item(id: "c", needs: ["a"])
        let verdict = DefinitionOfReady.evaluate(
            item: a, detail: detail(), dependencies: .init(items: [a, b, c]))

        XCTAssertEqual(verdict.reasons, ["needs b — dependency cycle: a → b → c → a"])
    }

    /// The walk the item page asks before writing a `needs:` edit: the path a
    /// new dependency would close, and nil when it closes none.
    func testCycleAnswersThePathADependencyLeadsBackThrough() {
        let backlog = DefinitionOfReady.Dependencies(items: [
            item(id: "a", needs: []), item(id: "b", needs: ["c"]), item(id: "c", needs: ["a"]),
            item(id: "d", needs: [])])

        XCTAssertEqual(backlog.cycle(from: "a", through: "b"), ["a", "b", "c", "a"])
        XCTAssertNil(backlog.cycle(from: "a", through: "d"))
        XCTAssertNil(backlog.cycle(from: "a", through: "no-such-item"))
    }

    func testAnItemThatNeedsItselfIsReportedAsACycle() {
        let a = item(id: "a", needs: ["a"])
        let verdict = DefinitionOfReady.evaluate(
            item: a, detail: detail(), dependencies: .init(items: [a]))

        XCTAssertEqual(verdict.reasons, ["needs a — dependency cycle: a → a"])
    }

    /// A self-reference is a cycle whatever unbuilt state the item is in — the
    /// gate reports it rather than walking a loop that names only itself.
    func testAnItemThatNeedsItselfIsACycleInEveryUnbuiltState() {
        for status in BacklogItemStatus.allCases where status != .done {
            let a = item(id: "a", status: status, needs: ["a"])
            let verdict = DefinitionOfReady.evaluate(
                item: a, detail: detail(), dependencies: .init(items: [a]))

            XCTAssertEqual(verdict.reasons, ["needs a — dependency cycle: a → a"],
                           "a \(status.rawValue) item naming itself")
        }
    }

    /// The prerequisite landing is what clears the clause, and it clears it even
    /// when the finished item's own line still points back at the dependent —
    /// the two lines describe an order that has now been served.
    ///
    /// The cycle probe used to run before the status lookup, so the one state
    /// that satisfies a dependency was never consulted once a loop was found:
    /// the survivor of a mutual pair was withheld at every pass, for good, with
    /// a reason no edit to it could clear.
    func testADoneDependencyIsSatisfiedEvenWhenItNamesTheItemBack() {
        let a = item(id: "a", needs: ["b"])
        let b = item(id: "b", status: .done, needs: ["a"])
        let verdict = DefinitionOfReady.evaluate(
            item: a, detail: detail(), dependencies: .init(items: [a, b]))

        XCTAssertTrue(verdict.isReady, verdict.summary)
        XCTAssertEqual(verdict.unmet, [])
    }

    /// Until it lands, the loop is still a loop: the wording stays for the case
    /// it was written for, prerequisites that are genuinely unbuilt.
    func testAMutualDependencyIsStillACycleWhileThePrerequisiteIsUnbuilt() {
        for status in BacklogItemStatus.allCases where status != .done {
            let a = item(id: "a", needs: ["b"])
            let b = item(id: "b", status: status, needs: ["a"])
            let verdict = DefinitionOfReady.evaluate(
                item: a, detail: detail(), dependencies: .init(items: [a, b]))

            XCTAssertEqual(verdict.unmet, [.dependency], "a \(status.rawValue) prerequisite")
            XCTAssertEqual(verdict.reasons, ["needs b — dependency cycle: a → b → a"],
                           "a \(status.rawValue) prerequisite")
        }
    }

    /// An item waiting on something that is *itself* in a cycle is only blocked,
    /// not part of the loop — the cycle is reported to the items that are in it.
    func testAnItemOutsideACycleIsOnlyBlockedByIt() {
        let a = item(id: "a", needs: ["b"])
        let b = item(id: "b", needs: ["c"])
        let c = item(id: "c", needs: ["b"])
        let verdict = DefinitionOfReady.evaluate(
            item: a, detail: detail(), dependencies: .init(items: [a, b, c]))

        XCTAssertEqual(verdict.reasons, ["needs b — not done (ready)"])
    }

    /// Each dependency is judged on its own terms, so a line naming three says
    /// which of them is the problem rather than that one of them is.
    func testEveryUnmetDependencyIsNamedSeparately() {
        let dependent = item(needs: ["shipped", "in-flight", "ghost"])
        let verdict = DefinitionOfReady.evaluate(
            item: dependent, detail: detail(),
            dependencies: .init(items: [dependent,
                                        item(id: "shipped", status: .done),
                                        item(id: "in-flight", status: .active)]))

        XCTAssertEqual(verdict.unmet, [.dependency, .dependency])
        XCTAssertEqual(verdict.reasons, ["needs in-flight — not done (active)",
                                         "needs ghost — no such item"])
    }

    /// Sequencing is reported after everything the groomer could act on, since
    /// the fix for it is time rather than an edit.
    func testSequencingIsReportedAfterTheGroomingClauses() {
        let dependent = item(size: nil, needs: ["prereq"])
        let verdict = DefinitionOfReady.evaluate(
            item: dependent, detail: detail(),
            dependencies: .init(items: [dependent, item(id: "prereq")]))

        XCTAssertEqual(verdict.unmet, [.size, .dependency])
    }

    /// An item that names no dependency is judged exactly as it was before the
    /// clause existed, backlog context or not.
    func testAnItemWithoutNeedsIsUnaffected() {
        let lone = item()
        let backlog = DefinitionOfReady.Dependencies(items: [lone, item(id: "unfinished")])

        XCTAssertTrue(DefinitionOfReady.evaluate(item: lone, detail: detail(),
                                                 dependencies: backlog).isReady)
        XCTAssertEqual(DefinitionOfReady.evaluate(item: lone, detail: nil, dependencies: backlog).unmet,
                       DefinitionOfReady.evaluate(item: lone, detail: nil).unmet)
    }

    /// A caller with no backlog to resolve against — grading a proposed draft,
    /// say — has no basis to call a dependency unmet, so the clause stays silent
    /// rather than refusing every item that states a sequence.
    func testWithoutBacklogContextTheClauseIsSilent() {
        let dependent = item(needs: ["no-such-item"])
        XCTAssertTrue(DefinitionOfReady.evaluate(item: dependent, detail: detail()).isReady)
    }

    // MARK: - Reporting

    func testEveryUnmetClauseGetsExactlyOneReason() {
        let verdict = DefinitionOfReady.evaluate(
            item: item(verify: nil, size: .xl),
            detail: detail(what: nil, approach: nil, criteria: [], verify: [])
        )
        XCTAssertEqual(verdict.unmet, [.what, .how, .validation, .verify, .sizeTooLarge])
        XCTAssertEqual(verdict.reasons.count, verdict.unmet.count)
        XCTAssertFalse(verdict.reasons.contains(where: \.isEmpty))
        // The summary is one log line, so it must stay on one line.
        XCTAssertFalse(verdict.summary.contains("\n"))
    }
}
