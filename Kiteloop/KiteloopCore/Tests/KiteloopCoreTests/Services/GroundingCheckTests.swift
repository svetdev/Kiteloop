import XCTest
@testable import KiteloopCore

/// The grounding gate: whether a groomed item's cited paths, symbols and verify
/// command are things the repo actually has. The rules are exercised against a
/// stubbed `Sources` — only the index test touches a real directory.
final class GroundingCheckTests: XCTestCase {

    // MARK: - Fixtures

    private func sources(
        paths: Set<String> = ["Kiteloop/Kiteloop/Services/BacklogAutopilot.swift"],
        symbols: Set<String> = ["BacklogAutopilot", "start", "DefinitionOfReady", "evaluate"],
        executables: Set<String> = ["xcodebuild", "swift"],
        // The filenames this repo's sources construct — files the app writes at
        // run time, which are in no tree the check can walk. Empty by default,
        // so every other case here judges paths against the corpora alone.
        literals: Set<String> = [],
        // The actions this repo's workflow files use, both spellings, the way
        // the live index holds them. Empty by default for the same reason.
        actions: Set<String> = []
    ) -> GroundingCheck.Sources {
        GroundingCheck.Sources(
            pathExists: { paths.contains($0) },
            definesSymbol: { symbols.contains($0) },
            resolvesExecutable: { executables.contains($0) },
            // The same set the corpus answers from, indexed the way the live
            // one is: by last component, so a command's path can be asked about
            // exactly rather than by suffix.
            pathsNamed: { name in paths.filter { ($0 as NSString).lastPathComponent == name } },
            constructsFile: { literals.contains($0) },
            usesAction: { actions.contains($0) }
        )
    }

    private func item(verify: String? = "xcodebuild build", title: String = "Guard sync dedup") -> BacklogItem {
        BacklogItem(id: "sync-dedup-guard", title: title, verify: verify, status: .ready,
                    type: .local, size: .m, detailPath: "backlog/sync-dedup-guard.md")
    }

    private func detail(
        what: String? = "Dedupe the sync queue.",
        approach: String? = "Follow `BacklogAutopilot`.",
        criteria: [String] = ["A duplicate push is dropped"],
        outOfScope: [String] = [],
        verify: [BacklogItemDetail.VerifyCommand] = [.init(name: "build", cmd: "xcodebuild build", expect: nil)]
    ) -> BacklogItemDetail {
        BacklogItemDetail(id: "sync-dedup-guard", title: "Guard sync dedup",
                          verifyCommands: verify, acceptanceCriteria: criteria,
                          outOfScope: outOfScope, what: what, approach: approach)
    }

    // MARK: - A grounded draft passes, and says what it checked

    func testRealPathAndSymbolPassAndAreListed() {
        let detail = detail(
            what: "Dedupe the queue in `Kiteloop/Kiteloop/Services/BacklogAutopilot.swift`.",
            approach: "Key it the way `DefinitionOfReady.evaluate` does."
        )
        let verdict = GroundingCheck.evaluate(item: item(), detail: detail, sources: sources())

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.unresolved, [])
        // Auditable: the pass names every reference it stood on.
        XCTAssertEqual(verdict.checked.count, 3, verdict.audit)
        XCTAssertTrue(verdict.audit.contains("path Kiteloop/Kiteloop/Services/BacklogAutopilot.swift"), verdict.audit)
        XCTAssertTrue(verdict.audit.contains("symbol DefinitionOfReady.evaluate"), verdict.audit)
        XCTAssertTrue(verdict.audit.contains("command xcodebuild"), verdict.audit)
    }

    // MARK: - The failure this check exists for

    /// `phantomToolProvider` stands in for the tool-provider symbol a real detail
    /// file once told a worker to copy. Its actual name is kept out of the
    /// sources on purpose: writing it here would index it, and the live check
    /// would then find the one invention it was built to catch.
    func testInventedSymbolIsNotGrounded() {
        let detail = detail(approach: "Copy the pattern in `phantomToolProvider`.")
        let verdict = GroundingCheck.evaluate(item: item(), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["phantomToolProvider"])
        XCTAssertEqual(verdict.unresolved.first?.kind, .symbol)
        XCTAssertTrue(verdict.summary.contains("phantomToolProvider"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("no source file"), verdict.summary)
    }

    func testInventedPathIsNotGrounded() {
        let detail = detail(what: "Edit `Kiteloop/Kiteloop/Services/Nope.swift`.")
        let verdict = GroundingCheck.evaluate(item: item(), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.path])
        XCTAssertTrue(verdict.summary.contains("Nope.swift"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("not in the repo"), verdict.summary)
    }

    func testABrokenLinkInADottedSymbolNamesTheMissingPart() {
        let detail = detail(approach: "Reuse `BacklogAutopilot.resumeQueue`.")
        let verdict = GroundingCheck.evaluate(item: item(), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        // The whole reference is quoted, then the part that isn't there.
        XCTAssertTrue(verdict.summary.contains("`BacklogAutopilot.resumeQueue`"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("`resumeQueue`"), verdict.summary)
    }

    // MARK: - The remedy clause

    /// A grounded verdict's summary stays empty — the remedy is only appended
    /// when there is something to clear.
    func testGroundedVerdictSummaryStaysEmpty() {
        XCTAssertEqual(GroundingCheck.Verdict.grounded.summary, "")
        XCTAssertTrue(GroundingCheck.Verdict.grounded.isGrounded)
    }

    /// The remedy names the one thing that clears a refusal: a creation cue
    /// right before the citation. It's one line, appended after the note.
    func testRefusalSummaryEndsWithARemedyClause() throws {
        let detail = detail(approach: "Copy the pattern in `phantomToolProvider`.")
        let verdict = GroundingCheck.evaluate(item: item(), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        let note = try XCTUnwrap(verdict.unresolved.first?.note)
        // The per-reference note is untouched — byte-for-byte what it always was.
        XCTAssertEqual(note, "cites `phantomToolProvider`, which is in no source file in the repo"
                             + "; read as a claim because it is a lower-camel-case name,"
                             + " which is a member this repo would define")
        XCTAssertTrue(verdict.summary.hasPrefix(note), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("exempt from this check"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("creation cue"), verdict.summary)
        XCTAssertFalse(verdict.summary.contains("\n"), verdict.summary)
    }

    /// The remedy names both ways to clear a refusal — a creation cue for a
    /// reference the draft proposes to add, and an absence cue for one it
    /// reports as gone — so an operator reading a refusal about a file that
    /// was deleted is not told to claim it is being created.
    func testRemedyClauseNamesBothTheCreationAndAbsenceCue() {
        let detail = detail(approach: "Copy the pattern in `phantomToolProvider`.")
        let verdict = GroundingCheck.evaluate(item: item(), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.summary.contains("creation cue"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("absence cue"), verdict.summary)
    }

    /// However many references are refused, the remedy is said once.
    func testRemedyClauseAppearsOnceWithTwoUnresolvedReferences() {
        let detail = detail(
            what: "Edit `Kiteloop/Kiteloop/Services/Nope.swift`.",
            approach: "Copy the pattern in `phantomToolProvider`."
        )
        let verdict = GroundingCheck.evaluate(item: item(), detail: detail, sources: sources())

        XCTAssertEqual(verdict.unresolved.count, 2, verdict.summary)
        let occurrences = verdict.summary.components(separatedBy: "exempt from this check").count - 1
        XCTAssertEqual(occurrences, 1, verdict.summary)
    }

    // MARK: - A draft with nothing concrete to check

    func testProseWithoutCodeReferencesIsGrounded() {
        let detail = detail(
            what: "Make the queue drop duplicates instead of running them twice.",
            approach: "Key on whatever the remote already sent; keep it cheap.",
            criteria: ["A duplicate push is dropped"],
            verify: []
        )
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources())

        XCTAssertTrue(verdict.isGrounded)
        XCTAssertEqual(verdict.checked, [])
        XCTAssertEqual(verdict.audit, "no code references to check")
    }

    func testBacktickedProseWordIsNotTreatedAsASymbol() {
        // `ready` and `verify` are words a groomer quotes, not claims about code.
        let detail = detail(what: "Move the item to `ready` once its `verify` passes.", approach: nil)
        let verdict = GroundingCheck.evaluate(item: item(), detail: detail, sources: sources())

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked.map(\.kind), [.command])
    }

    // MARK: - Verify command

    func testUnresolvableVerifyCommandIsNotGrounded() {
        let detail = detail(approach: nil,
                            verify: [.init(name: "check", cmd: "kiteloopctl verify", expect: nil)])
        let verdict = GroundingCheck.evaluate(item: item(), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.command])
        XCTAssertTrue(verdict.summary.contains("kiteloopctl"), verdict.summary)
    }

    func testItemLineVerifyIsCheckedWhenThereIsNoGroomedOne() {
        let verdict = GroundingCheck.evaluate(item: item(verify: "nosuchtool test"),
                                              detail: detail(approach: nil, verify: []),
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["nosuchtool"])
    }

    func testShellBuiltinsAreNotExecutableClaims() {
        // `cd Kiteloop && xcodebuild …` claims xcodebuild exists, not cd.
        let tokens = GroundingCheck.executableTokens(in: "cd Kiteloop && xcodebuild -scheme Kiteloop build")
        XCTAssertEqual(tokens, ["xcodebuild"])
    }

    func testEnvironmentAssignmentsAreNotExecutables() {
        XCTAssertEqual(GroundingCheck.executableTokens(in: "CI=1 swift test"), ["swift"])
    }

    func testPipedSegmentsAreEachChecked() {
        XCTAssertEqual(GroundingCheck.executableTokens(in: "swift test | tee out.log"), ["swift", "tee"])
    }

    /// A separator inside quotes belongs to the argument, not to the shell. This
    /// held three website-audit items out of every run for a day: their
    /// `verify:` was one `python3 -c "…"` whose script contained `;`, and the
    /// check refused to ground `assert` and `print('ok` as programs.
    func testSeparatorsInsideQuotesDoNotStartANewCommand() {
        let cmd = "python3 -c \"import json; assert json.load(open('x.json')); print('ok')\""
        XCTAssertEqual(GroundingCheck.executableTokens(in: cmd), ["python3"])
    }

    func testSeparatorsInsideSingleQuotesDoNotStartANewCommand() {
        XCTAssertEqual(GroundingCheck.executableTokens(in: "sh -c 'make build; make test'"), ["sh"])
    }

    /// The quote-aware scan must not cost the real separators around it.
    func testRealSeparatorsStillSplitAroundAQuotedScript() {
        let cmd = "python3 -c \"print('a; b')\" && cargo test"
        XCTAssertEqual(GroundingCheck.executableTokens(in: cmd), ["python3", "cargo"])
    }

    /// A lone `&` is not a separator — cutting `2>&1` would leave `1` looking
    /// like a program.
    func testRedirectionIsNotReadAsASecondCommand() {
        XCTAssertEqual(GroundingCheck.executableTokens(in: "swift test 2>&1"), ["swift"])
    }

    // MARK: - A slashed executable runs from where the `cd` left the shell

    private static let rootScript = "scripts/run-core-tests.sh"
    private static let intoKiteloop = "cd \"$(git rev-parse --show-toplevel)/Kiteloop\" && "

    /// A root with `scripts/run-core-tests.sh` and a `Kiteloop/` without one,
    /// answering for slashed tokens from the root the way `Executables` does.
    private func scriptRepo() -> GroundingCheck.Sources {
        sources(paths: ["Kiteloop/Kiteloop.xcodeproj", Self.rootScript],
                executables: ["xcodebuild", "./\(Self.rootScript)"])
    }

    func testEachExecutableCarriesTheDirectoryItRunsFrom() {
        XCTAssertEqual(
            GroundingCheck.locatedExecutables(in: Self.intoKiteloop + "./scripts/x.sh && cd \"$HOME\" && ./y.sh"),
            [GroundingCheck.LocatedExecutable(text: "./scripts/x.sh", directory: "Kiteloop"),
             GroundingCheck.LocatedExecutable(text: "./y.sh", directory: nil)])
    }

    /// The ready item that ran `./scripts/run-core-tests.sh` from `Kiteloop/`
    /// grounded and then failed the moment it ran.
    func testARootScriptRunAfterACdIntoASubdirectoryIsRefused() {
        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil), detail: buildVerify(Self.intoKiteloop + "./\(Self.rootScript)"),
            sources: scriptRepo())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.command])
        XCTAssertEqual(verdict.unresolved.map(\.text), ["./\(Self.rootScript)"])
        XCTAssertTrue(verdict.summary.contains("`Kiteloop/`"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("the repo has it at `\(Self.rootScript)`"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("cd \"$(git rev-parse --show-toplevel)\" && ./\(Self.rootScript)"),
                      verdict.summary)
    }

    func testARootScriptRunFromTheRootStillResolves() {
        for command in ["cd \"$(git rev-parse --show-toplevel)\" && ./\(Self.rootScript)",
                        "./\(Self.rootScript)",
                        "cd Kiteloop && ../\(Self.rootScript)"] {
            let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: buildVerify(command),
                                                  sources: scriptRepo())
            XCTAssertTrue(verdict.isGrounded, "\(command) → \(verdict.summary)")
            XCTAssertTrue(verdict.checked.contains { $0.kind == .command && $0.resolved }, verdict.audit)
        }
    }

    func testBareAndAbsoluteExecutablesAfterACdResolveAsBefore() {
        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: buildVerify("cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj build && /usr/bin/true"),
            sources: sources(paths: ["Kiteloop/Kiteloop.xcodeproj"], executables: ["xcodebuild", "/usr/bin/true"]))

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked.filter { $0.kind == .command }.map(\.text), ["xcodebuild", "/usr/bin/true"])
    }

    func testASlashedExecutableAfterAnUnnameableCdIsNeitherRefusedNorResolved() {
        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil), detail: buildVerify("cd \"$HOME\" && ./\(Self.rootScript)"),
            sources: scriptRepo())

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertFalse(verdict.checked.contains { $0.kind == .command }, verdict.audit)
    }

    func testAProposedScriptRunAfterACdIsStillExempt() {
        let detail = detail(
            what: "The core has no smoke script.",
            approach: "Add `Kiteloop/scripts/smoke.sh` beside the package.",
            criteria: [],
            verify: [.init(name: "smoke", cmd: Self.intoKiteloop + "./scripts/smoke.sh", expect: nil)])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: scriptRepo())

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertTrue(verdict.audit.contains("command ./scripts/smoke.sh"), verdict.audit)
    }

    // MARK: - Shell negation

    /// `!` is the keyword that negates a segment's exit status, and it is in no
    /// `PATH`. Reading it as the program refused three correctly written items
    /// on 2026-08-11 within minutes of the queue starting to move — and it is
    /// the only way to write "this string must not be present", which is what a
    /// verify for a documentation fix needs.
    func testNegatedSegmentClaimsTheProgramAfterTheKeyword() {
        // ci-build-and-unit-suite, readme-and-contributing-test-facts: the
        // negation opens a later segment.
        XCTAssertEqual(
            GroundingCheck.executableTokens(
                in: "cd Kiteloop && ! grep -q 'KiteloopUITests' .github/workflows/ci.yml"),
            ["grep"])
        XCTAssertEqual(
            GroundingCheck.executableTokens(
                in: "test -f CONTRIBUTING.md && ! grep -q \"26 files under\" CONTRIBUTING.md"),
            ["grep"])
    }

    /// success-metrics-baseline-is-stale negates the whole command rather than a
    /// later segment, so the keyword is the first word there is.
    func testNegationIsReadAtTheStartOfAWholeCommandToo() {
        XCTAssertEqual(
            GroundingCheck.executableTokens(
                in: "! grep -qE 'missing stall-timeout|no baseline' docs/success-metrics.md"),
            ["grep"])
    }

    /// The negative: stepping over the keyword must not stop the segment being
    /// checked. A misspelled program behind a `!` is the same invention it is
    /// anywhere else, which is why `!` is skipped rather than treated as a
    /// builtin — a builtin drops the whole segment.
    func testAMisspelledProgramBehindTheNegationIsStillRefused() {
        XCTAssertEqual(GroundingCheck.executableTokens(in: "! gerp -q foo README.md"), ["gerp"])

        let detail = buildVerify("! gerp -q 'KiteloopUITests' README.md")
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail,
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded, verdict.audit)
        XCTAssertTrue(verdict.summary.contains("`gerp`"), verdict.summary)
    }

    /// A negated verify grounds end to end, and the paths after the keyword are
    /// still judged from the directory the command reaches them in.
    func testANegatedVerifyGroundsAndItsPathsAreStillChecked() {
        let sources = sources(paths: ["Kiteloop/Kiteloop/Services/BacklogAutopilot.swift"],
                              executables: ["grep"])
        let detail = buildVerify("! grep -q 'phantom' Kiteloop/Kiteloop/Services/BacklogAutopilot.swift")
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources)

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertTrue(verdict.checked.contains { $0.text == "grep" && $0.resolved }, verdict.audit)
    }

    /// The keyword is a word of its own. `!` welded to a name is a program with
    /// an odd name, not a negation, and dropping it would stop checking one.
    func testOnlyAStandaloneKeywordIsReadAsNegation() {
        XCTAssertTrue(GroundingCheck.isShellNegation("!"))
        XCTAssertFalse(GroundingCheck.isShellNegation("!grep"))
        XCTAssertEqual(GroundingCheck.executableTokens(in: "!grep -q foo README.md"), ["!grep"])
    }

    // MARK: - Verify path arguments

    /// The twelve-item failure of 2026-08-10: `-project Kiteloop.xcodeproj` from
    /// the project root, where the project is one directory down. Every one of
    /// them was destined to fail at its own merge gate, in front of a person.
    private func buildVerify(_ command: String) -> BacklogItemDetail {
        detail(approach: nil, verify: [.init(name: "build", cmd: command, expect: nil)])
    }

    private static let xcodeRepo: Set<String> = ["Kiteloop/Kiteloop.xcodeproj"]

    func testAVerifyPathThatNeedsACdIsRefused() {
        let verdict = GroundingCheck.evaluate(
            item: item(),
            detail: buildVerify("xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop build"),
            sources: sources(paths: Self.xcodeRepo))

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.commandPath])
        XCTAssertEqual(verdict.unresolved.map(\.text), ["Kiteloop.xcodeproj"])
        // Actionable where "verify failed" after a run is not: the path, the
        // directory the command runs in, and the edit that fixes it.
        XCTAssertTrue(verdict.summary.contains("`Kiteloop.xcodeproj`"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("the project root"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("`Kiteloop/Kiteloop.xcodeproj`"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("cd Kiteloop &&"), verdict.summary)
    }

    func testTheSameVerifyPassesOnceItCds() {
        let verdict = GroundingCheck.evaluate(
            item: item(),
            detail: buildVerify("cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop build"),
            sources: sources(paths: Self.xcodeRepo))

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        // And it is *checked*, not merely unflagged — the audit says so.
        XCTAssertTrue(verdict.audit.contains("command path Kiteloop.xcodeproj"), verdict.audit)
    }

    /// The sturdier spelling `CLAUDE.md` recommends. `git rev-parse
    /// --show-toplevel` names the repo root without anything being run, so the
    /// walk restarts there and the rest of the command is judged like any other.
    func testACdThroughTheRepoRootSubstitutionKeepsChecking() {
        let command = "cd \"$(git rev-parse --show-toplevel)/Kiteloop\" && "
            + "xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop build"
        let verdict = GroundingCheck.evaluate(item: item(), detail: buildVerify(command),
                                              sources: sources(paths: Self.xcodeRepo))

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertTrue(verdict.audit.contains("command path Kiteloop.xcodeproj"), verdict.audit)
    }

    /// And the point of checking it: the recommended spelling was the one form
    /// that let the twelve-item mistake of 2026-08-10 through. `cd` to the root
    /// and then name `Kiteloop.xcodeproj` is the same miss as no `cd` at all, and
    /// now gets the same refusal.
    func testTheRepoRootSubstitutionWithNoSubdirectoryStillRefusesAMissingPath() {
        let command = "cd \"$(git rev-parse --show-toplevel)\" && "
            + "xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop build"
        let verdict = GroundingCheck.evaluate(item: item(), detail: buildVerify(command),
                                              sources: sources(paths: Self.xcodeRepo))

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["Kiteloop.xcodeproj"])
        XCTAssertTrue(verdict.summary.contains("the project root"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("`Kiteloop/Kiteloop.xcodeproj`"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("cd Kiteloop &&"), verdict.summary)
    }

    func testAVerifyWithNoPathArgumentsIsUnaffected() {
        let verdict = GroundingCheck.evaluate(item: item(), detail: buildVerify("swift test"),
                                              sources: sources(paths: Self.xcodeRepo))

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked.map(\.kind), [.command])
    }

    /// A path the repo has nowhere is not judged at all. Static text can't tell
    /// a file the command reads from one it writes, or from one the run is about
    /// to create — so only the one miss that names its own fix is a refusal.
    func testAPathTheRepoDoesNotHaveAtAllIsNotJudged() {
        for command in ["swift test | tee results/out.json",
                        "xcodebuild -project Nope.xcodeproj build"] {
            let verdict = GroundingCheck.evaluate(item: item(), detail: buildVerify(command),
                                                  sources: sources(paths: Self.xcodeRepo,
                                                                   executables: ["xcodebuild", "swift", "tee"]))
            XCTAssertTrue(verdict.isGrounded, "\(command) → \(verdict.summary)")
            XCTAssertFalse(verdict.checked.contains { $0.kind == .commandPath }, verdict.audit)
        }
    }

    func testAResolvingPathArgumentIsRecordedAsChecked() {
        let verdict = GroundingCheck.evaluate(
            item: item(),
            detail: buildVerify("bash scripts/run-unit-suite.sh"),
            sources: sources(paths: ["scripts/run-unit-suite.sh"], executables: ["bash"]))

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertTrue(verdict.audit.contains("command path scripts/run-unit-suite.sh"), verdict.audit)
    }

    // MARK: - What counts as a path argument

    func testFlagsAssignmentsAndAbsolutePathsAreNotPathArguments() {
        let command = "cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop "
            + "-destination \"platform=macOS\" -only-testing:KiteloopTests "
            + "-derivedDataPath /tmp/dd build-for-testing"
        XCTAssertEqual(GroundingCheck.pathArguments(in: command),
                       [GroundingCheck.PathArgument(text: "Kiteloop.xcodeproj", directory: "Kiteloop")])
    }

    func testTheExecutableIsNotAlsoReadAsAPathArgument() {
        // `./scripts/kiteloop-verify.py` is checked as an executable; reading it
        // twice would refuse it twice for one mistake.
        XCTAssertEqual(GroundingCheck.pathArguments(in: "./scripts/kiteloop-verify.py --json"), [])
    }

    func testShellExpansionsAreNotPathArguments() {
        for command in ["rm -rf build/*", "swift test --filter $FILTER/x", "ls ~/.kiteloop/home"] {
            XCTAssertEqual(GroundingCheck.pathArguments(in: command), [], command)
        }
    }

    func testAPathArgumentAboveTheRootIsNotJudged() {
        // `../Other.xcodeproj` leaves the checkout, where nothing is indexed.
        let verdict = GroundingCheck.evaluate(
            item: item(), detail: buildVerify("xcodebuild -project ../Other.xcodeproj build"),
            sources: sources(paths: Self.xcodeRepo))
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    // MARK: - Where each segment runs

    func testTheWorkingDirectoryFollowsCdAcrossSegments() {
        XCTAssertEqual(GroundingCheck.pathArguments(in: "cd Kiteloop && cd .. && xcodebuild -project Kiteloop.xcodeproj build"),
                       [GroundingCheck.PathArgument(text: "Kiteloop.xcodeproj", directory: "")])
        XCTAssertEqual(GroundingCheck.destination(ofCD: ["Kiteloop/Kiteloop"], from: ""), "Kiteloop/Kiteloop")
        XCTAssertEqual(GroundingCheck.destination(ofCD: ["./Kiteloop"], from: ""), "Kiteloop")
    }

    func testACdThisCheckCannotFollowSilencesTheRestOfTheCommand() {
        for target in ["/usr/src", "~/code", "$ROOT", "../..",
                       "$(dirname $(git rev-parse --show-toplevel))", "$(mktemp -d)",
                       "`git rev-parse --show-toplevel`"] {
            XCTAssertNil(GroundingCheck.destination(ofCD: [target], from: ""), target)
        }
        // A bare `cd` goes home, and nothing after an unknown `cd` is judged.
        XCTAssertNil(GroundingCheck.destination(ofCD: [], from: ""))
        XCTAssertNil(GroundingCheck.destination(ofCD: ["Kiteloop"], from: nil))
        // And "stops the walk" means the later segments contribute nothing.
        XCTAssertEqual(
            GroundingCheck.pathArguments(in: "cd `git rev-parse --show-toplevel` && "
                + "xcodebuild -project Kiteloop.xcodeproj build"),
            [])
    }

    /// `git rev-parse --show-toplevel` prints the repo root, so its value is
    /// known from the text — the one substitution the walk can follow.
    func testTheRepoRootSubstitutionIsTheOneCdItCanFollow() {
        let root = GroundingCheck.repoRootSubstitution
        XCTAssertEqual(GroundingCheck.destination(ofCD: ["\(root)/Kiteloop"], from: ""), "Kiteloop")
        XCTAssertEqual(GroundingCheck.destination(ofCD: [root], from: ""), "")
        // It names the root absolutely, so it lands in the same place from
        // wherever an earlier segment had left the shell.
        XCTAssertEqual(GroundingCheck.destination(ofCD: ["\(root)/Kiteloop"], from: "docs"), "Kiteloop")
        // A second expansion in the remainder, and a word that merely starts
        // this way, are both back out of reach.
        XCTAssertNil(GroundingCheck.destination(ofCD: ["\(root)/$SUBDIR"], from: ""))
        XCTAssertNil(GroundingCheck.destination(ofCD: ["\(root)-backup"], from: ""))
        // Above the root is outside everything the index holds.
        XCTAssertNil(GroundingCheck.destination(ofCD: ["\(root)/.."], from: ""))
    }

    func testAQuotedArgumentIsOneWord() {
        XCTAssertEqual(GroundingCheck.shellWords(in: "cd \"$(git rev-parse --show-toplevel)/Kiteloop\""),
                       ["cd", "$(git rev-parse --show-toplevel)/Kiteloop"])
        XCTAssertEqual(GroundingCheck.shellWords(in: "xcodebuild -destination 'platform=macOS' build"),
                       ["xcodebuild", "-destination", "platform=macOS", "build"])
    }

    // MARK: - Extraction rules

    func testAProposedReferenceIsNotAClaim() {
        // A draft names what it will build; that is not a claim it exists.
        for prose in ["Add `GroundingCheck` under Services/.",
                      "Create `GroundingCheckTests.swift`.",
                      "A new `SourceIndex` holds the paths.",
                      "Rename `oldName` to `newName`."] {
            let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                                  detail: detail(what: prose, approach: nil, verify: []),
                                                  sources: sources())
            XCTAssertTrue(verdict.isGrounded, "\(prose) → \(verdict.summary)")
        }
    }

    /// Every word in the cue set, one sentence each, in the shape that exposed
    /// the gap: `backlog-templates` was refused on 2026-08-11 for citing the
    /// template it exists to produce, because it said "Ship" rather than "Add".
    ///
    /// The words are written out here rather than read back from
    /// `creationCues`, so dropping one from the set fails this test by name
    /// instead of quietly shrinking what a groomer is allowed to say.
    ///
    /// The last group is exercised on a member name instead of a path, because
    /// that is what "implement" and "override" are written on.
    func testEveryCreationCueExcusesTheFileItProposes() {
        let cues = [
            // The original nineteen.
            "Add", "Adds", "Adding", "Create", "Creates", "Creating", "New",
            "Introduce", "Introduces", "Introducing", "Write", "Writes", "Writing",
            "Rename", "Renames", "Scaffold", "Scaffolds", "Generate", "Generates",
            // The verbs that meant the same thing and were refused anyway.
            "Ship", "Ships", "Shipping", "Provide", "Provides", "Providing",
            "Supply", "Supplies", "Supplying", "Include", "Includes", "Including",
            "Publish", "Publishes", "Publishing", "Produce", "Produces", "Producing",
            "Emit", "Emits", "Emitting", "Define", "Defines", "Defining",
            "Declare", "Declares", "Declaring",
            "Extract", "Extracts", "Extracting", "Split", "Splits", "Splitting"
        ]
        for cue in cues {
            let prose = "\(cue) one real template: `backlog/templates/release.md`."
            let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                                  detail: detail(what: prose, approach: nil, verify: []),
                                                  sources: sources())
            XCTAssertTrue(verdict.isGrounded, "\(prose) → \(verdict.summary)")
        }

        // The control: the same sentence with no cue in it at all is still read
        // as a claim that the file is already there, and refused.
        let claim = "One real template: `backlog/templates/release.md`."
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: claim, approach: nil, verify: []),
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded, verdict.summary)

        // The two verbs a groomer reaches for when what is proposed is a method
        // rather than a file, in the shape they are actually written — a bare
        // lower-camel member name, which is the one shape the check refuses
        // outright. `finalize-run-records-at-quit` sat parked as a draft whose
        // How read "implement applicationShouldTerminate", an AppKit hook no
        // file in this repo defines yet.
        let memberCues = [
            "Implement", "Implements", "Implementing",
            "Override", "Overrides", "Overriding"
        ]
        for cue in memberCues {
            let prose = "\(cue) `applicationShouldTerminate` on the app delegate."
            let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                                  detail: detail(what: prose, approach: nil, verify: []),
                                                  sources: sources())
            XCTAssertTrue(verdict.isGrounded, "\(prose) → \(verdict.summary)")
        }

        // And its control: with the verb taken away the same name reads as a
        // claim that the method is already there, and is refused.
        let member = "The delegate's `applicationShouldTerminate` on quit."
        let memberVerdict = GroundingCheck.evaluate(item: item(verify: nil),
                                                    detail: detail(what: member, approach: nil, verify: []),
                                                    sources: sources())
        XCTAssertFalse(memberVerdict.isGrounded, memberVerdict.summary)
    }

    func testACueDoesNotExcuseAReferenceTwoSentencesLater() {
        // The cue window is the words just before the reference, so an unrelated
        // "add" earlier in the section can't wave a later invention through.
        let prose = "Add a dedup key. Then follow the shape of the existing queue "
            + "walker, which is the part worth copying here, and reuse `phantomToolProvider`."
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: prose, approach: nil, verify: []),
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded)
    }

    // MARK: - Absence cues

    /// Every word in the absence cue set, one sentence each, mirroring
    /// `testEveryCreationCueExcusesTheFileItProposes`: the words are written
    /// out here rather than read back from `absenceCues`, so dropping one from
    /// the set fails this test by name instead of quietly shrinking what a
    /// groomer is allowed to say about a reference that is gone.
    func testEveryAbsenceCueExcusesTheGoneReference() {
        let cues = [
            "Missing", "Gone", "Removed", "Removes", "Removing",
            "Deleted", "Deletes", "Deleting", "Dangling", "Absent"
        ]
        for cue in cues {
            let prose = "\(cue) now: `docs/removed-guide.md` is not part of the docs."
            let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                                  detail: detail(what: prose, approach: nil, verify: []),
                                                  sources: sources())
            XCTAssertTrue(verdict.isGrounded, "\(prose) → \(verdict.summary)")
        }

        // "no longer" excuses the same way, with no single-word cue at all.
        let noLonger = "The guide is no longer accurate: `docs/removed-guide.md`."
        let noLongerVerdict = GroundingCheck.evaluate(
            item: item(verify: nil), detail: detail(what: noLonger, approach: nil, verify: []),
            sources: sources())
        XCTAssertTrue(noLongerVerdict.isGrounded, noLongerVerdict.summary)

        // The control: the same sentence with no cue in it at all is still read
        // as a claim that the file is already there, and refused.
        let claim = "The docs mention `docs/removed-guide.md`."
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: claim, approach: nil, verify: []),
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded, verdict.summary)
    }

    /// The narrow half, mirroring the creation cue's own: a verb neither list
    /// carries — "deprecated" is neither an addition nor an absence — excuses
    /// nothing, because both cue sets stay closed lists rather than patterns.
    func testAVerbInNeitherCueSetExcusesNothing() {
        let prose = "Deprecated `docs/removed-guide.md` from the site."
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: prose, approach: nil, verify: []),
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded, verdict.summary)
    }

    /// The window rule is the same rule for an absence cue as for a creation
    /// one: the cue excuses only the reference in front of it, so an unrelated
    /// "removed" earlier in the section can't wave a later invention through.
    func testAnAbsenceCueDoesNotExcuseAReferenceTwoSentencesLater() {
        let prose = "The changelog entry was removed. Then follow the shape of the existing queue "
            + "walker, which is the part worth copying here, and reuse `docs/removed-guide.md`."
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: prose, approach: nil, verify: []),
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded)
    }

    /// A path that resolves nowhere and carries neither cue anywhere in the
    /// draft is refused exactly as before — same kind, same note.
    func testAPathWithNeitherACreationNorAnAbsenceCueIsStillRefused() {
        let missing = detail(what: "See `docs/removed-guide.md` for details.", approach: nil, verify: [])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: missing, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.path])
        XCTAssertTrue(verdict.summary.contains("docs/removed-guide.md"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("not in the repo"), verdict.summary)
    }

    /// The shape that parked `docs-link-to-two-documents-that-are-gone`: prose
    /// whose whole subject is a reference that is missing reads as a report of
    /// its absence, not a claim it exists, and a Validation criterion that
    /// cites the same path again is the acceptance criterion for that report,
    /// not a fresh claim the file is on disk.
    func testAPathTheDraftReportsAsGoneIsExcusedWhereverItIsNamedAgain() {
        let goneDoc = "docs/removed-guide.md"
        let reportsGone = detail(
            what: "The link to the old guide is dangling.",
            approach: "Dangling: `\(goneDoc)` no longer exists in this tree; stop linking to it.",
            criteria: ["A reader who follows the old link to `\(goneDoc)` sees nothing broken."],
            verify: [])
        let grounded = GroundingCheck.evaluate(item: item(verify: nil), detail: reportsGone,
                                               sources: sources())
        XCTAssertTrue(grounded.isGrounded, grounded.summary)

        // The control: with the absence wording gone, the same criterion is a
        // claim about a file the repo does not have, and is refused as before.
        let claims = detail(what: "The link to the old guide is dangling.", approach: nil,
                            criteria: ["A reader who follows the old link to `\(goneDoc)` sees nothing broken."],
                            verify: [])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: claims, sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.path])
        XCTAssertTrue(verdict.summary.contains(goneDoc), verdict.summary)
    }

    // MARK: - Creation cues

    /// The shape that parked `run-records-finalize-without-a-request`: the How
    /// proposes a new method, and the Validation three sections later says what
    /// it must do. The second mention is not a fresh claim that the method
    /// exists — it is the acceptance criterion for the one being added.
    func testANameTheDraftIntroducesIsExcusedWhereverItIsUsedAgain() {
        let detail = detail(
            what: "Run records should finalize on their own.",
            approach: "Add `finalizeRunRecord` to the control server.",
            criteria: ["A run that ends with no request still calls `finalizeRunRecord`."],
            outOfScope: ["Calling `finalizeRunRecord` from the quit path."],
            verify: []
        )
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources())

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    /// A groomer writes the introduction as a declaration, which holds more than
    /// one word — and `classify` drops any span with a space in it before the
    /// cue is ever consulted, so the introduction was invisible twice over. The
    /// identifier comes out of the span; the keywords around it have no camel
    /// hump and contribute nothing.
    func testADeclarationSpanContributesItsIdentifierAndNotItsKeywords() {
        let names = GroundingCheck.proposedNames(
            in: "Add a `func finalizeRunRecord(id: String) -> Bool` on the server.")

        XCTAssertEqual(names, ["finalizeRunRecord"])
    }

    func testOnlyASpanWithACueContributesToTheProposedSet() {
        // No cue in front of it, so the same declaration proposes nothing.
        XCTAssertEqual(
            GroundingCheck.proposedNames(in: "The `func finalizeRunRecord(id: String)` already there."),
            [])
    }

    /// A dotted name is judged by its root, and so is the excuse. Written on a
    /// root the repo *does* define, which is the only shape where the excuse
    /// changes the answer: an unknown root makes a dotted name somebody else's
    /// object and no claim about this repo at all.
    func testADottedCitationIsExcusedByItsRootAndOnlyByItsRoot() {
        let introduced = detail(
            what: "Add `BacklogAutopilot.resumeQueue` for the stalled queue.",
            approach: "Then `BacklogAutopilot.resumeQueue` drains what is left.",
            criteria: [], verify: []
        )
        XCTAssertTrue(GroundingCheck.evaluate(item: item(verify: nil), detail: introduced,
                                              sources: sources()).isGrounded)

        // The same second sentence, in a draft that introduced something else:
        // the root is defined here, the member is not, and nothing forgives it.
        let borrowed = detail(
            what: "Add `RunRecordStore` beside the server.",
            approach: "Then `BacklogAutopilot.resumeQueue` drains what is left.",
            criteria: [], verify: []
        )
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: borrowed, sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["BacklogAutopilot.resumeQueue"])
    }

    /// The narrow half of the rule: forgiving a proposed name must not forgive
    /// an invention nobody proposed, in the same draft or anywhere else.
    func testAnUnproposedSymbolIsStillRefusedBesideAProposedOne() {
        let detail = detail(
            what: "Add `finalizeRunRecord` to the control server.",
            approach: "Copy the pattern in `phantomToolProvider`, then call `finalizeRunRecord`.",
            criteria: [], verify: []
        )
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["phantomToolProvider"])
    }

    /// The excuse is for symbols the draft proposes, not for files it claims are
    /// on disk: introducing a name does not make an unrelated path exist.
    func testProposingASymbolDoesNotExcuseAPathCitation() {
        let detail = detail(
            what: "Add `finalizeRunRecord` to the control server.",
            approach: "Edit `Kiteloop/Kiteloop/Services/Nope.swift`.",
            criteria: [], verify: []
        )
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.path])
        XCTAssertTrue(verdict.summary.contains("Nope.swift"), verdict.summary)
    }

    // MARK: - A file the draft proposes, in prose and in its own verify command

    private static let newScript = "scripts/test-check-target-membership.py"

    /// The shape that parked `membership-check-has-no-tests`: the How proposes a
    /// script and the Validation says what running it must do. The second mention
    /// is the acceptance criterion for the file being added, not a claim that the
    /// file is already on disk — and a criterion that *opens* with the path has no
    /// preceding prose at all to carry a cue, so a correctly groomed draft was
    /// refused by its own acceptance criteria.
    func testAPathTheDraftProposesIsExcusedWhereverItIsNamedAgain() {
        let proposes = detail(
            what: "The membership check has no tests.",
            approach: "Add `\(Self.newScript)` beside the check it asserts.",
            criteria: ["`\(Self.newScript)` fails when a file is in no target."],
            verify: [])
        let grounded = GroundingCheck.evaluate(item: item(verify: nil), detail: proposes,
                                               sources: sources())
        XCTAssertTrue(grounded.isGrounded, grounded.summary)

        // The control: with the proposing sentence gone, the same criterion is a
        // claim about a file the repo does not have, and is refused as before.
        let claims = detail(what: "The membership check has no tests.", approach: nil,
                            criteria: ["`\(Self.newScript)` fails when a file is in no target."],
                            verify: [])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: claims, sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.path])
        XCTAssertTrue(verdict.summary.contains(Self.newScript), verdict.summary)
    }

    /// An item whose whole point is a new script has to verify by running it, and
    /// the shell has nothing to run until the item is built.
    func testAVerifyThatRunsTheScriptTheItemAddsResolvesAndIsStillChecked() {
        let detail = detail(
            what: "The membership check has no tests.",
            approach: "Add `\(Self.newScript)` beside the check it asserts.",
            criteria: [],
            verify: [.init(name: "tests", cmd: "./\(Self.newScript)", expect: nil)])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources())

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        // Looked at rather than skipped: the audit still names what it stood on.
        XCTAssertEqual(verdict.checked.map(\.kind), [.command])
        XCTAssertTrue(verdict.audit.contains("command ./\(Self.newScript)"), verdict.audit)
    }

    /// The narrow half: an executable no draft proposed is asked of the
    /// filesystem exactly as before, with the note and the rule it has always
    /// carried.
    func testAVerifyRunningAnExecutableNoDraftProposedIsStillRefused() {
        let detail = detail(
            what: "The membership check has no tests.",
            approach: "Add `\(Self.newScript)` beside the check it asserts.",
            criteria: [],
            verify: [.init(name: "tests", cmd: "./scripts/test-something-else.py", expect: nil)])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.command])
        XCTAssertTrue(verdict.summary.contains("resolves to no executable"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("it is the executable of a `verify:` command"),
                      verdict.summary)
    }

    func testAProposedPathArgumentResolvesWhileAMissingCdIsStillNamed() {
        let adds = detail(
            what: "The membership check has no tests.",
            approach: "Add `\(Self.newScript)` beside the check it asserts.",
            criteria: [],
            verify: [.init(name: "tests", cmd: "python3 \(Self.newScript)", expect: nil)])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: adds,
                                              sources: sources(executables: ["python3"]))

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertTrue(verdict.audit.contains("command path \(Self.newScript)"), verdict.audit)

        // And the refusal the rule exists for is untouched: a `cd` into a
        // directory the repo does not have still fails, and still names where the
        // directory actually is.
        let miss = detail(
            what: "The membership check has no tests.",
            approach: "Add `\(Self.newScript)` beside the check it asserts.",
            criteria: [],
            verify: [.init(name: "build", cmd: "cd Kiteloop/Services && swift build", expect: nil)])
        let refused = GroundingCheck.evaluate(
            item: item(verify: nil), detail: miss,
            sources: sources(paths: ["Kiteloop/Kiteloop/Services"]))

        XCTAssertFalse(refused.isGrounded)
        XCTAssertEqual(refused.unresolved.map(\.kind), [.commandPath])
        XCTAssertEqual(refused.unresolved.map(\.text), ["Kiteloop/Services"])
        XCTAssertTrue(refused.summary.contains("`Kiteloop/Kiteloop/Services`"), refused.summary)
        XCTAssertTrue(refused.summary.contains("cd Kiteloop &&"), refused.summary)
    }

    /// Forgiving one proposed file says nothing about any other file the draft
    /// cites — the same narrowness the symbol half has.
    func testAnUnproposedPathIsStillRefusedBesideAProposedOne() {
        let detail = detail(
            what: "Add `\(Self.newScript)` beside the check it asserts.",
            approach: "Read the target list the way `Kiteloop/Kiteloop/Services/Nope.swift` does.",
            criteria: [], verify: [])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources())

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["Kiteloop/Kiteloop/Services/Nope.swift"])
    }

    func testOnlyAPathWithACueIsProposedAndOneFileWrittenTwoWaysIsOneClaim() {
        XCTAssertEqual(GroundingCheck.proposedPaths(in: "Add `./scripts/check.sh` to the preflight."),
                       ["scripts/check.sh"])
        // No cue in front of it, so the same span proposes nothing.
        XCTAssertEqual(GroundingCheck.proposedPaths(in: "The `scripts/check.sh` in the preflight."), [])
        // A proposed symbol is not a proposed path.
        XCTAssertEqual(GroundingCheck.proposedPaths(in: "Add `finalizeRunRecord` to the server."), [])

        // A draft writes one file two ways; a different file is still a different
        // claim, and a longer name is not a suffix of the one proposed.
        let proposed: Set<String> = ["Kiteloop/Kiteloop/Services/Foo.swift"]
        XCTAssertTrue(GroundingCheck.isProposed(path: "Services/Foo.swift", among: proposed))
        XCTAssertTrue(GroundingCheck.isProposed(path: "./Kiteloop/Kiteloop/Services/Foo.swift",
                                                among: proposed))
        XCTAssertFalse(GroundingCheck.isProposed(path: "Services/MyFoo.swift", among: proposed))
        XCTAssertFalse(GroundingCheck.isProposed(path: "Services/Bar.swift", among: proposed))
    }

    func testFencedCodeBlocksAreNotClaims() {
        let approach = """
        Something like:

        ```
        let provider = madeUpThing()
        ```

        Follow `BacklogAutopilot`.
        """
        let verdict = GroundingCheck.evaluate(item: item(),
                                              detail: detail(what: nil, approach: approach),
                                              sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    func testPlaceholderPathsAreNotChecked() {
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: "Write `backlog/<id>.md`.",
                                                             approach: nil, verify: []),
                                              sources: sources())
        XCTAssertTrue(verdict.isGrounded)
        XCTAssertEqual(verdict.checked, [])
    }

    /// A draft about path-building has to quote the expression it is about, and
    /// an interpolation names no one file — the same reason a placeholder
    /// doesn't. `clone-that-stops-to-ask-a-question-never-returns` sat parked for
    /// citing the interpolated home-directory expression it existed to fix.
    func testSwiftInterpolationsInAPathAreNotChecked() {
        // Leading the path, and embedded in it.
        XCTAssertNil(GroundingCheck.classify("\\(home.path)/Library/Caches"))
        XCTAssertNil(GroundingCheck.classify("Library/Caches/\\(bundleID)/runs.jsonl"))

        let interpolated = detail(
            what: "The clone lands in `\\(home.path)/Library/Caches` and logs to "
                  + "`Library/Caches/\\(bundleID)/runs.jsonl`.",
            approach: nil, verify: [])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: interpolated,
                                              sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked, [])

        // The guard it shares still drops what it always dropped.
        XCTAssertNil(GroundingCheck.classify("backlog/<id>.md"))
        XCTAssertNil(GroundingCheck.classify("$HOME/.kiteloop/runs.jsonl"))

        // And an ordinary repo-relative path is still read as a claim, and still
        // refused when nothing holds it.
        XCTAssertEqual(GroundingCheck.classify("Kiteloop/Kiteloop/Services/Nope.swift"),
                       GroundingCheck.Citation(kind: .path,
                                               text: "Kiteloop/Kiteloop/Services/Nope.swift"))
        let missing = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Edit `Kiteloop/Kiteloop/Services/Nope.swift`.",
                           approach: nil, verify: []),
            sources: sources())
        XCTAssertFalse(missing.isGrounded)
        XCTAssertEqual(missing.unresolved.map(\.text), ["Kiteloop/Kiteloop/Services/Nope.swift"])
    }

    func testTrailingPunctuationAndCallParensAreTrimmed() {
        XCTAssertEqual(GroundingCheck.classify("BacklogAutopilot.start()", precededBy: "as in "),
                       GroundingCheck.Citation(kind: .symbol, text: "BacklogAutopilot.start"))
        XCTAssertEqual(GroundingCheck.classify("Services/Foo.swift,", precededBy: "in "),
                       GroundingCheck.Citation(kind: .path, text: "Services/Foo.swift"))
    }

    func testAMultiWordSpanIsNotASingleReference() {
        XCTAssertNil(GroundingCheck.classify("xcodebuild -scheme Kiteloop build", precededBy: "run "))
    }

    func testTheSameReferenceIsCheckedOnce() {
        let detail = detail(what: "Touch `phantomToolProvider`.",
                            approach: "Then `phantomToolProvider` again.", verify: [])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources())
        XCTAssertEqual(verdict.checked.count, 1, verdict.audit)
    }

    func testTheItemLineItselfIsRead() {
        // A project that grooms inline puts the whole draft in the title.
        let inline = item(verify: nil, title: "WHAT: dedupe. HOW: copy `phantomToolProvider`. VALIDATE: no dupes.")
        let verdict = GroundingCheck.evaluate(item: inline, detail: nil, sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["phantomToolProvider"])
    }

    // MARK: - The live index

    func testSourceIndexResolvesPathsSymbolsAndSkipsGeneratedDirectories() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding")
        let services = root.appending(path: "App/Services")
        let generated = root.appending(path: ".build")
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)

        try "enum SyncQueue { static func dedupe() {} }\n"
            .write(to: services.appending(path: "SyncQueue.swift"), atomically: true, encoding: .utf8)
        try "let phantomToolProvider = 1\n"
            .write(to: generated.appending(path: "Generated.swift"), atomically: true, encoding: .utf8)
        try "`ghostSymbol` lives only in prose here.\n"
            .write(to: root.appending(path: "NOTES.md"), atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)

        XCTAssertTrue(index.containsPath("App/Services/SyncQueue.swift"))
        // A draft may cite a suffix of the real path — the same claim, written short.
        XCTAssertTrue(index.containsPath("Services/SyncQueue.swift"))
        XCTAssertFalse(index.containsPath("Services/Nope.swift"))
        XCTAssertTrue(index.identifiers.contains("SyncQueue"))
        XCTAssertTrue(index.identifiers.contains("dedupe"))
        // Generated trees aren't the sources, and prose isn't either.
        XCTAssertFalse(index.identifiers.contains("phantomToolProvider"))
        XCTAssertFalse(index.identifiers.contains("ghostSymbol"))
    }

    /// `.kiteloop` is the app's own runtime state sitting inside the repo, and
    /// its two halves have to be read differently. Its paths are real — drafts
    /// cite `.kiteloop/team.json` — but its contents are this check's own output
    /// fed back to it: a checkpoint is JSON, `sourceExtensions` lists json, and
    /// each one embeds the item's What/How/Validation, so the very invention the
    /// check exists to catch grounded itself as soon as one run checkpointed.
    func testRuntimeStateGroundsPathsButNeverSymbols() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-runtime")
        let fm = FileManager.default
        let services = root.appending(path: "Kiteloop/Kiteloop/Services")
        let checkpoints = root.appending(path: ".kiteloop/checkpoints")
        try fm.createDirectory(at: services, withIntermediateDirectories: true)
        try fm.createDirectory(at: checkpoints, withIntermediateDirectories: true)

        try "enum SyncQueue { static func dedupeKey() {} }\n"
            .write(to: services.appending(path: "SyncQueue.swift"), atomically: true, encoding: .utf8)
        try "{\"agents\": []}\n"
            .write(to: root.appending(path: ".kiteloop/team.json"), atomically: true, encoding: .utf8)
        try "{\"what\": \"Reuse phantomCheckpointSymbol for the margin.\"}\n"
            .write(to: checkpoints.appending(path: "sync-dedup-guard.json"),
                   atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)
        XCTAssertTrue(index.containsPath(".kiteloop/team.json"))
        XCTAssertTrue(index.identifiers.contains("dedupeKey"))
        XCTAssertFalse(index.identifiers.contains("phantomCheckpointSymbol"),
                       "runtime state must not ground the symbols it echoes back")

        let sources = GroundingCheck.Sources.repository(root: root)
        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Read `.kiteloop/team.json` at pickup, keyed the way `dedupeKey` is.",
                           approach: "The checkpoint mentions `phantomCheckpointSymbol`.", verify: []),
            sources: sources)

        XCTAssertFalse(verdict.isGrounded, verdict.audit)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["phantomCheckpointSymbol"])
        // The rule that made it checkable is still named, as for any invention.
        XCTAssertEqual(verdict.unresolved.first?.rule,
                       "it is a lower-camel-case name, which is a member this repo would define")
        // The path and the real symbol were both checked, and both stand.
        XCTAssertTrue(verdict.checked.contains { $0.text == ".kiteloop/team.json" && $0.resolved },
                      verdict.audit)
        XCTAssertTrue(verdict.checked.contains { $0.text == "dedupeKey" && $0.resolved }, verdict.audit)
    }

    /// End to end over a real tree: a file the app *writes* is in no checkout,
    /// and the source that opens it names it. The same walk must not take that
    /// answer from runtime state — a checkpoint's quoted values are the check's
    /// own output fed back to it, and a JSON string that is nothing but a
    /// filename is file-shaped.
    func testFileLiteralsComeFromTheSourcesAndNeverFromRuntimeState() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-literals")
        let fm = FileManager.default
        let services = root.appending(path: "Kiteloop/Kiteloop/Services")
        let checkpoints = root.appending(path: ".kiteloop/checkpoints")
        try fm.createDirectory(at: services, withIntermediateDirectories: true)
        try fm.createDirectory(at: checkpoints, withIntermediateDirectories: true)

        try "func url() { dir.appending(path: \"global-config.json\") }\n"
            .write(to: services.appending(path: "GlobalConfigStore.swift"),
                   atomically: true, encoding: .utf8)
        try "{\"artifact\": \"phantom-checkpoint.json\"}\n"
            .write(to: checkpoints.appending(path: "sync-dedup-guard.json"),
                   atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)
        XCTAssertTrue(index.fileLiterals.contains("global-config.json"))
        XCTAssertFalse(index.fileLiterals.contains("phantom-checkpoint.json"),
                       "runtime state must not ground the filenames it echoes back")
        // What the repo writes is not what the repo has: the file is in no tree.
        XCTAssertFalse(index.containsPath("global-config.json"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Read the ceiling out of `global-config.json` at launch.",
                           approach: "The checkpoint mentions `phantom-checkpoint.json`.", verify: []),
            sources: .repository(root: root))

        XCTAssertFalse(verdict.isGrounded, verdict.audit)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["phantom-checkpoint.json"])
        XCTAssertTrue(verdict.checked.contains { $0.text == "global-config.json" && $0.resolved },
                      verdict.audit)
    }

    // MARK: - A GitHub Action is not a missing file

    /// An action reference has a slash in it and is no file in any tree, so it
    /// read as a repo-relative path and was refused — which is what parked the
    /// draft `ci-keeps-a-red-runs-output-nowhere` for citing the action
    /// `.github/workflows/ci.yml` names on its own `uses:` line. Both spellings
    /// a draft writes ground; one nothing uses is still an invention.
    func testAnActionThisReposWorkflowFilesUseIsGroundedInBothSpellings() throws {
        let workflowSources = sources(actions: ["actions/upload-artifact@v4",
                                               "actions/upload-artifact"])
        let groomed = detail(
            what: "The red run keeps its log with `actions/upload-artifact@v4`.",
            approach: "CI already runs `actions/upload-artifact` for the build log.",
            verify: [])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: groomed,
                                              sources: workflowSources)

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked.map(\.text),
                       ["actions/upload-artifact@v4", "actions/upload-artifact"])
        // Read as a path — the token's shape is unchanged — and accepted by the
        // rule that names the corpus which answered.
        XCTAssertEqual(verdict.checked.map(\.kind), [.path, .path])
        let accepted = try XCTUnwrap(verdict.checked.first)
        XCTAssertEqual(accepted.rule,
                       "it is written as a repo-relative path, and this repo's workflow files"
                       + " under `.github/workflows/` use the action `actions/upload-artifact@v4`")
        XCTAssertTrue(verdict.audit.contains("path actions/upload-artifact@v4"), verdict.audit)

        // An action no workflow file uses is refused exactly as before.
        let invented = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Keep it with `actions/phantom-upload@v9`.", approach: nil, verify: []),
            sources: workflowSources)
        XCTAssertFalse(invented.isGrounded)
        let refused = try XCTUnwrap(invented.unresolved.first)
        XCTAssertEqual(refused.rule, "it is written as a repo-relative path")
        XCTAssertTrue(refused.note?.contains("actions/phantom-upload@v9") == true, invented.summary)
        XCTAssertTrue(refused.note?.contains("repo-relative path") == true, invented.summary)
        XCTAssertTrue(refused.note?.contains("not in the repo") == true, invented.summary)
    }

    /// The corpus is `.github/workflows/` and nothing else: a `uses:` line in
    /// some other YAML is not a claim this repo's CI acts on, and a local
    /// action or a container image is not the shape being answered for.
    func testActionReferencesAreReadFromTheWorkflowFilesAndNowhereElse() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-actions")
        let fm = FileManager.default
        let workflows = root.appending(path: ".github/workflows")
        try fm.createDirectory(at: workflows, withIntermediateDirectories: true)

        try """
        jobs:
          build:
            steps:
              - uses: actions/checkout@v4
              - name: Keep the log
                uses: actions/upload-artifact@v4  # the red run's output
              - uses: ./.github/actions/setup
              - uses: docker://alpine:3
        """.write(to: workflows.appending(path: "ci.yml"), atomically: true, encoding: .utf8)
        try "uses: actions/phantom-deploy@v1\n"
            .write(to: root.appending(path: "compose.yml"), atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)
        XCTAssertTrue(index.actionReferences.contains("actions/upload-artifact@v4"))
        XCTAssertTrue(index.actionReferences.contains("actions/upload-artifact"))
        XCTAssertTrue(index.actionReferences.contains("actions/checkout@v4"))
        XCTAssertTrue(index.actionReferences.contains("actions/checkout"))
        XCTAssertFalse(index.actionReferences.contains("actions/phantom-deploy@v1"),
                       "only `.github/workflows/` answers for what this repo's CI runs")
        XCTAssertFalse(index.actionReferences.contains("./.github/actions/setup"))
        XCTAssertFalse(index.actionReferences.contains("docker://alpine:3"))
        // What CI runs is not a file the tree holds — the same split
        // `fileLiterals` makes.
        XCTAssertFalse(index.containsPath("actions/upload-artifact@v4"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Keep the log with `actions/upload-artifact@v4`.",
                           approach: "Not with `actions/phantom-deploy@v1`.", verify: []),
            sources: .repository(root: root))

        XCTAssertFalse(verdict.isGrounded, verdict.audit)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["actions/phantom-deploy@v1"])
        XCTAssertTrue(verdict.checked.contains { $0.text == "actions/upload-artifact@v4" && $0.resolved },
                      verdict.audit)
    }

    /// The live false positive, against the checkout the check actually runs in:
    /// `.github/workflows/ci.yml` uses `actions/upload-artifact@v4`, so a draft
    /// citing it — or the bare slug — is telling the truth.
    func testThisCheckoutsOwnWorkflowActionsGround() throws {
        // `<root>/Kiteloop/KiteloopTests/Services/GroundingCheckTests.swift`.
        let root = RepositoryRoot.of()
        let workflow = root.appending(path: ".github/workflows/ci.yml")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: workflow.path(percentEncoded: false)),
                          "no checkout to read at \(root.path(percentEncoded: false))")
        let yaml = try String(contentsOf: workflow, encoding: .utf8)
        XCTAssertTrue(yaml.contains("uses: actions/upload-artifact@v4"),
                      "this case is about the action ci.yml really uses")

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "A red run keeps its log with `actions/upload-artifact@v4`.",
                           approach: "That is the `actions/upload-artifact` CI already runs;"
                                     + " `actions/phantom-upload@v9` is nobody's.",
                           verify: []),
            sources: .repository(root: root))

        XCTAssertFalse(verdict.isGrounded, verdict.audit)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["actions/phantom-upload@v9"])
        for cited in ["actions/upload-artifact@v4", "actions/upload-artifact"] {
            XCTAssertTrue(verdict.checked.contains { $0.text == cited && $0.resolved }, verdict.audit)
        }
    }

    // MARK: - A dotted root is checkable only when this repo declares it

    /// A platform type this repo only *mentions* — `Bundle`, from
    /// `Bundle.main` — is not a claim about this code, whatever member
    /// follows it. This repo declares no `Bundle` of its own, so a member of
    /// it this repo never wrote is a platform's business, not an invention.
    /// Refusing it anyway is what parked
    /// `bundled-examples-exist-only-on-the-build-machine` for citing
    /// `Bundle.main.resourceURL`.
    func testAPlatformTypeThisRepoOnlyMentionsIsNotACheckableRoot() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-mentioned")
        let services = root.appending(path: "Kiteloop/Kiteloop/Services")
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)

        try "func resourcePath() -> URL? { Bundle.main.resourceURL }\n"
            .write(to: services.appending(path: "Examples.swift"), atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)
        XCTAssertTrue(index.identifiers.contains("Bundle"))
        XCTAssertFalse(index.declaredTypes.contains("Bundle"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Read the bundled examples out of `Bundle.main.resourceURL`.",
                           approach: nil, verify: []),
            sources: .repository(root: root))

        XCTAssertTrue(verdict.isGrounded, verdict.audit)
        XCTAssertEqual(verdict.checked, [], verdict.audit)
    }

    /// A dotted citation whose root this repo *declares* is still checked all
    /// the way down: a broken member is still a refusal, with the note and
    /// the rule sentence unchanged by the narrower root test.
    func testADeclaredRootWithAMissingMemberIsStillRefused() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-declared")
        let services = root.appending(path: "Kiteloop/Kiteloop/Services")
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)

        try "enum BacklogAutopilot { static func start() {} }\n"
            .write(to: services.appending(path: "BacklogAutopilot.swift"),
                   atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)
        XCTAssertTrue(index.declaredTypes.contains("BacklogAutopilot"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Reuse `BacklogAutopilot.resumeQueue`.", approach: nil, verify: []),
            sources: .repository(root: root))

        XCTAssertFalse(verdict.isGrounded)
        let reference = try XCTUnwrap(verdict.unresolved.first)
        XCTAssertEqual(reference.rule, "its root `BacklogAutopilot` is defined in this repo")
        XCTAssertTrue(reference.note?.contains("`resumeQueue`") == true, verdict.summary)
    }

    /// A root this repo declares only through an `extension` is still
    /// declared, so the chain it roots stays checkable — a repo
    /// `extension Bundle` means this repo *does* have standing to say a
    /// member of `Bundle` isn't there.
    func testARootDeclaredOnlyThroughAnExtensionIsStillCheckable() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-extension")
        let services = root.appending(path: "Kiteloop/Kiteloop/Services")
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)

        try "extension Bundle { var restingPlace: String { \"menu\" } }\n"
            .write(to: services.appending(path: "Bundle+Kiteloop.swift"),
                   atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)
        XCTAssertTrue(index.declaredTypes.contains("Bundle"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Read `Bundle.phantomExtensionMember`.", approach: nil, verify: []),
            sources: .repository(root: root))

        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.summary.contains("phantomExtensionMember"), verdict.summary)
    }

    /// Nothing should ever cite build output, so the derived tree is pruned
    /// rather than filtered afterwards. `DerivedData` — the leaf a worktree run
    /// builds into — was already skipped; `.derived` is the tracked tree the repo
    /// root keeps, several hundred megabytes checked out into every worktree,
    /// stat-walked on every pickup while its artefacts sat in `pathsByName`
    /// waiting to suffix-match a cited filename.
    func testTheDerivedBuildTreeIsPrunedRatherThanWalked() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-derived")
        let fm = FileManager.default
        let products = root.appending(path: ".derived/Build/Products/Debug")
        try fm.createDirectory(at: products, withIntermediateDirectories: true)

        try "let phantomBuildSymbol = 1\n"
            .write(to: products.appending(path: "GeneratedInterface.swift"),
                   atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)

        XCTAssertFalse(index.containsPath(".derived/Build/Products/Debug/GeneratedInterface.swift"))
        XCTAssertFalse(index.containsPath("Products/Debug/GeneratedInterface.swift"))
        XCTAssertFalse(index.identifiers.contains("phantomBuildSymbol"))
        // Pruned, not filtered: the walk never descended, so nothing under the
        // tree — not even the directories on the way down — was recorded.
        XCTAssertNil(index.pathsByName["Products"])
        XCTAssertNil(index.pathsByName["GeneratedInterface.swift"])
        XCTAssertTrue(GroundingCheck.SourceIndex.skippedDirectories.contains(".derived"))
        // The tree's *own* entry survives: it is a directory that is really
        // there, and citing it is a true claim. See the test below.
        XCTAssertEqual(index.pathsByName[".derived"], [".derived"])
    }

    /// A directory that holds tracked files is in the repo, and a draft that
    /// cites it is right. `untrack-derived-data` was refused on 2026-08-11 for
    /// citing `.derived/` while `git ls-files -- .derived` returned 4,759 files.
    ///
    /// The cause was not the trailing slash — `normalize` strips it and the walk
    /// records directories, so `Kiteloop/` has always resolved. It was that a
    /// `skippedDirectories` entry dropped the directory's own path along with
    /// its contents, so the one tree a draft had reason to name was the one tree
    /// the index denied.
    func testACitedDirectoryResolvesIncludingOneWhoseContentsArePruned() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-dirs")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: ".derived/Build"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "Kiteloop/Kiteloop/Services"),
                               withIntermediateDirectories: true)

        let index = GroundingCheck.SourceIndex.build(root: root)

        XCTAssertTrue(index.containsPath(".derived/"), "a pruned tree is still a directory in the repo")
        XCTAssertTrue(index.containsPath(".derived"))
        XCTAssertTrue(index.containsPath("Kiteloop/Services/"), "an ordinary directory, cited with a slash")
        XCTAssertTrue(index.containsPath("Kiteloop/Services"))
        // The negative: a directory that is nowhere is still a refusal, and
        // being under a pruned tree does not ground it.
        XCTAssertFalse(index.containsPath("Nowhere/"))
        XCTAssertFalse(index.containsPath(".derived/Build/"))
    }

    /// End to end against a real tree: the citation that stalled the item
    /// grounds, and an invented directory beside it is still refused, with the
    /// rule that made it checkable named in the refusal.
    func testADirectoryCitationIsJudgedAgainstTheRepoAndStillRefusedWhenInvented() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-dir-claim")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: ".derived/Build"),
                               withIntermediateDirectories: true)

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Untrack `.derived/`, which is checked out into every worktree.",
                           approach: "Leave `Nowhere/` alone.", verify: []),
            sources: GroundingCheck.Sources.repository(root: root))

        XCTAssertFalse(verdict.isGrounded, verdict.audit)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["Nowhere/"])
        XCTAssertTrue(verdict.checked.contains { $0.text == ".derived/" && $0.resolved }, verdict.audit)
        XCTAssertEqual(verdict.unresolved.first?.rule, "it is written as a repo-relative path")
        XCTAssertTrue(verdict.summary.contains("which is not in the repo"), verdict.summary)
    }

    /// A path rooted outside the repo is not a claim about the repo. Runtime
    /// files and API routes were being checked against the source index and
    /// reported missing, which refused correctly groomed items.
    func testPathsOutsideTheRepoAreNotTreatedAsRepoClaims() {
        XCTAssertFalse(GroundingCheck.looksLikePath("~/.kiteloop/global-config.json"),
                       "a runtime file in the home directory is not a repo path")
        XCTAssertFalse(GroundingCheck.looksLikePath("/v1/coordinator/policy"),
                       "an API route is not a repo path")
        XCTAssertFalse(GroundingCheck.looksLikePath("/usr/bin/git"))

        // Repo-relative paths are still claims, and still checked.
        XCTAssertTrue(GroundingCheck.looksLikePath("Kiteloop/Services/QueueRefill.swift"))
        XCTAssertTrue(GroundingCheck.looksLikePath("docs/control-api.md"))
        XCTAssertTrue(GroundingCheck.looksLikePath("GroundingCheck.swift"))
    }

    /// A URL's slashes are a scheme and an authority, not directories, so it is
    /// not a repo claim either. `docs-remote-control-tailnet` was refused on
    /// 2026-08-10 for citing the loopback address the control API listens on —
    /// a fact about the app, and one no checkout could ever contain as a file.
    func testURLsAreNotTreatedAsRepoClaims() {
        XCTAssertFalse(GroundingCheck.looksLikePath("http://127.0.0.1:4517/v1/backlog"),
                       "a loopback URL is not a repo path")
        XCTAssertFalse(GroundingCheck.looksLikePath("https://example.com/a/b.json"),
                       "an https URL is not a repo path, extension or not")

        // And nothing downstream picks them up as symbols instead.
        XCTAssertNil(GroundingCheck.classify("http://127.0.0.1:4517/v1/backlog", precededBy: "call "))

        // The exclusion is for the scheme, not for slashes: a real repo-relative
        // path that merely contains a colon-free host-like word still counts.
        XCTAssertTrue(GroundingCheck.looksLikePath("Kiteloop/Services/GroundingCheck.swift"))
    }

    /// A package name or a bundler alias begins with `@` and can never be a file
    /// at that path, so it is not a repo claim either — the same exclusion `~`
    /// and `/` already get. Drafts citing `@testing-library/react` were being
    /// refused for a dependency the repo installs rather than stores.
    func testTokensRootedAtAnAtSignAreNotTreatedAsRepoClaims() {
        XCTAssertFalse(GroundingCheck.looksLikePath("@testing-library/react"),
                       "a package name is not a repo path")
        XCTAssertFalse(GroundingCheck.looksLikePath("@/lib/api"),
                       "an aliased import is not a repo path")

        // And nothing downstream picks them up as symbols instead.
        XCTAssertNil(GroundingCheck.classify("@testing-library/react", precededBy: "render with "))
        XCTAssertNil(GroundingCheck.classify("@/lib/api", precededBy: "import from "))

        for prose in ["Render the table with `@testing-library/react`.",
                      "Fetch through `@/lib/api`."] {
            let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                                  detail: detail(what: prose, approach: nil, verify: []),
                                                  sources: sources())
            XCTAssertTrue(verdict.isGrounded, "\(prose) → \(verdict.summary)")
        }
    }

    /// A media type is written with a slash because that is how media types are
    /// written. `sitemap-served-not-just-200` was unstartable on 2026-08-11 for
    /// citing the two content types a sitemap may be served as, and the only
    /// workaround — dropping the backticks — makes the item worse to read.
    func testMediaTypesAreNotTreatedAsRepoClaims() {
        for type in ["text/xml", "text/html", "application/json", "image/svg+xml",
                     "application/vnd.api+json", "audio/mpeg", "video/mp4",
                     "font/woff2", "model/gltf+json", "multipart/form-data",
                     "message/rfc822"] {
            XCTAssertFalse(GroundingCheck.looksLikePath(type), "\(type) is a media type, not a repo path")
            XCTAssertNil(GroundingCheck.classify(type, precededBy: "served as "))
        }

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "The sitemap must be served as `text/xml`, and the page as `text/html`.",
                           approach: nil, verify: []),
            sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked, [])
    }

    /// The media-type exclusion is a closed list of the nine IANA top-level
    /// types, not "a word before a slash" — which would take half of every repo
    /// path with it. A directory that happens to be named for one of them is
    /// still a directory.
    func testTheMediaTypeExclusionIsAClosedListAndDoesNotSwallowRepoPaths() {
        // A top-level type that is not one of the nine leaves the path rule alone.
        XCTAssertTrue(GroundingCheck.looksLikePath("Services/Foo.swift"))
        XCTAssertTrue(GroundingCheck.looksLikePath("docs/control-api.md"))
        XCTAssertTrue(GroundingCheck.looksLikePath("scripts/run"))

        // A real subtype has no known file extension; a file under a directory
        // that shares a type's name has one, and stays a path.
        XCTAssertTrue(GroundingCheck.looksLikePath("image/logo.png"))
        XCTAssertTrue(GroundingCheck.looksLikePath("text/Foo.swift"))
        XCTAssertTrue(GroundingCheck.looksLikePath("application/main.swift"))
        // Only `type/subtype` — a third segment is a path however it starts.
        XCTAssertTrue(GroundingCheck.looksLikePath("application/Views/Backlog"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Edit `text/Foo.swift`.", approach: nil, verify: []),
            sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.path])
    }

    /// A span of nothing but dot segments — `./`, `../`, `../../` — names no
    /// file: there is no last component for any corpus to hold, so it is
    /// uncheckable prose, not an unresolvable path claim. A path that carries a
    /// real last component, even one that climbs above the repo root, is judged
    /// exactly as it is today.
    func testDotSegmentOnlyTokensAreNotTreatedAsRepoClaims() {
        XCTAssertFalse(GroundingCheck.looksLikePath("./"), "a bare current-directory prefix names no file")
        XCTAssertFalse(GroundingCheck.looksLikePath("../"), "a bare parent-directory prefix names no file")
        XCTAssertFalse(GroundingCheck.looksLikePath("../../"))
        XCTAssertFalse(GroundingCheck.looksLikePath("././"))

        // A real last component still counts, dot-prefixed or not, including one
        // that climbs above the repo root.
        XCTAssertTrue(GroundingCheck.looksLikePath("./Services/GroundingCheck.swift"))
        XCTAssertTrue(GroundingCheck.looksLikePath("../Services/GroundingCheck.swift"))
        XCTAssertTrue(GroundingCheck.looksLikePath("Services/GroundingCheck.swift"))

        // End to end: the dot-segment span produces no reference at all, while a
        // real path beside it is still checked and still refused when invented.
        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Look under `../` for `Services/NoSuchFile.swift`.",
                           approach: nil, verify: []),
            sources: sources())
        XCTAssertTrue(verdict.checked.allSatisfy { $0.text != "../" }, verdict.audit)
        XCTAssertTrue(verdict.unresolved.allSatisfy { $0.text != "../" }, verdict.audit)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["Services/NoSuchFile.swift"])
    }

    /// A component standing in for an elided remainder — `Kiteloop/Services/…`,
    /// the directory with the rest left out — names no file either, so it is
    /// uncheckable prose rather than an unresolvable claim.
    /// `runnable-queue-with-an-idle-fleet-reads-as-healthy` was refused for one,
    /// its recorded reason being that the token is in neither the repo nor the
    /// vault and was read as a claim because it is written as a repo-relative
    /// path.
    func testElidedPathsAreNotTreatedAsRepoClaims() {
        // Both spellings a groomer writes, at the end of the path…
        XCTAssertFalse(GroundingCheck.looksLikePath("Kiteloop/Services/…"),
                       "a directory with its remainder elided names no file")
        XCTAssertFalse(GroundingCheck.looksLikePath("Kiteloop/Services/..."),
                       "three periods are the same elision spelled out")
        // …and in the middle of it.
        XCTAssertFalse(GroundingCheck.looksLikePath("Kiteloop/…/GroundingCheck.swift"))
        XCTAssertFalse(GroundingCheck.looksLikePath("Kiteloop/.../GroundingCheck.swift"))
        XCTAssertFalse(GroundingCheck.looksLikePath("…/Services/GroundingCheck.swift"))

        // The trailing periods are the reference, not sentence punctuation:
        // stripping them would leave a `Kiteloop/Services/` no corpus holds and
        // refuse the elision under a name the draft never wrote.
        XCTAssertNil(GroundingCheck.classify("Kiteloop/Services/…", precededBy: "under "))
        XCTAssertNil(GroundingCheck.classify("Kiteloop/Services/...", precededBy: "under "))

        // A path with no elision in it is judged exactly as it is today.
        XCTAssertTrue(GroundingCheck.looksLikePath("Kiteloop/Services/GroundingCheck.swift"))
        XCTAssertTrue(GroundingCheck.looksLikePath("Services/NoSuchFile.swift"))

        // End to end: the elided directory produces no reference at all, while
        // an invented path beside it is still checked and still refused.
        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Look under `Kiteloop/Services/…` and `Kiteloop/Services/...`, "
                                 + "then edit `Services/NoSuchFile.swift`.",
                           approach: nil, verify: []),
            sources: sources())
        // The missing path is the only reference the draft produced: `checked`
        // holds it, marked unresolved, and neither elided token appears there at
        // all — under its written spelling or the `Kiteloop/Services/` the
        // punctuation strip would once have left behind.
        XCTAssertEqual(verdict.unresolved.map(\.text), ["Services/NoSuchFile.swift"], verdict.audit)
        XCTAssertEqual(verdict.checked.map(\.text), ["Services/NoSuchFile.swift"], verdict.audit)
    }

    /// A real directory cited with its remainder elided grounds, rather than
    /// being refused as a file the repo does not have.
    func testARealDirectoryWithAnElidedRemainderGrounds() {
        for cited in ["Kiteloop/Services/…", "Kiteloop/Services/..."] {
            let verdict = GroundingCheck.evaluate(
                item: item(verify: nil),
                detail: detail(what: "The services live under `\(cited)`.", approach: nil, verify: []),
                sources: sources())
            XCTAssertTrue(verdict.isGrounded, "\(cited) → \(verdict.summary)")
            XCTAssertEqual(verdict.checked, [], verdict.audit)
        }
    }

    /// Prose drops a URL's scheme far more often than it keeps it, and a project
    /// auditing other people's websites cites hosts by nature: three of the four
    /// website-audit items that stalled on 2026-08-11 did.
    ///
    /// The signal is a public suffix, not a dot — `Kiteloop.xcodeproj/project.pbxproj`
    /// has a dot in its first segment and is a real repo path.
    func testSchemelessHostsAreNotTreatedAsRepoClaims() {
        XCTAssertFalse(GroundingCheck.looksLikePath("squareup.com/appointments"),
                       "a schemeless host is not a repo path")
        XCTAssertFalse(GroundingCheck.looksLikePath("nebula.wsimg.com/aadc63d8/logo"),
                       "a CDN host is not a repo path")
        XCTAssertFalse(GroundingCheck.looksLikePath("example.co.uk/pricing"))
        XCTAssertNil(GroundingCheck.classify("squareup.com/appointments", precededBy: "book at "))

        // A dot in the first segment is not the signal. This repo's own file and
        // bundle extensions win the tie against the gTLDs that share their names.
        XCTAssertTrue(GroundingCheck.looksLikePath("Kiteloop.xcodeproj/project.pbxproj"))
        XCTAssertTrue(GroundingCheck.looksLikePath("Kiteloop.app/Contents/Info.plist"))
        XCTAssertTrue(GroundingCheck.looksLikePath("run.sh/wrapper"))
        XCTAssertTrue(GroundingCheck.looksLikePath(".github/workflows/ci.yml"))
        XCTAssertTrue(GroundingCheck.looksLikePath("Kiteloop/Kiteloop/Services/BacklogAutopilot.swift"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "The booking link points at `squareup.com/appointments`.",
                           approach: nil, verify: []),
            sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    /// A filename on an audited site — `sitemap.xml`, `Kurtis-300x199.png` — is
    /// deliberately left alone: a repository can contain either, so nothing in
    /// the token itself tells the two apart and no rule over it could be right.
    /// Recorded as a test so the next change here is a decision rather than an
    /// accident.
    func testARemoteFilenameIsStillReadAsARepoPath() {
        XCTAssertTrue(GroundingCheck.looksLikePath("sitemap.xml"))
        XCTAssertTrue(GroundingCheck.looksLikePath("Kurtis-300x199.png"))
    }

    /// A slash in prose is not always a directory separator: `n/a`, `and/or`,
    /// `w/o`, `I/O` and `24/7` are ordinary abbreviations, and no checkout ever
    /// holds a file at any of them. `marathon-scorecard-only-in-prose` was
    /// parked for citing `n/a` in a scorecard cell — a correctly groomed item
    /// refused because its own text happened to spell a word this way.
    func testSlashedProseAbbreviationsAreNotTreatedAsRepoClaims() {
        for abbreviation in ["n/a", "and/or", "w/o", "i/o", "24/7"] {
            XCTAssertFalse(GroundingCheck.looksLikePath(abbreviation),
                           "\(abbreviation) is a prose abbreviation, not a repo path")
            XCTAssertNil(GroundingCheck.classify(abbreviation, precededBy: "The field reads "))
        }

        // Matched case-insensitively, and after the punctuation trim `classify`
        // already does — an uppercase or punctuation-trailed spelling is the
        // same claim. One variant per listed abbreviation, so a regression
        // narrow enough to hit only one entry still fails a test.
        XCTAssertFalse(GroundingCheck.looksLikePath("N/A"))
        XCTAssertFalse(GroundingCheck.looksLikePath("AND/OR"))
        XCTAssertFalse(GroundingCheck.looksLikePath("I/O"))
        XCTAssertNil(GroundingCheck.classify("N/A.", precededBy: "The scorecard cell reads "))
        XCTAssertNil(GroundingCheck.classify("AND/OR", precededBy: "match on "))
        XCTAssertNil(GroundingCheck.classify("w/o,", precededBy: "shipped "))
        XCTAssertNil(GroundingCheck.classify("24/7,", precededBy: "runs "))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "The scorecard cell reads `n/a`, and it shipped `w/o` a rerun.",
                           approach: nil, verify: []),
            sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked, [], verdict.audit)
    }

    /// The exclusion is a closed list keyed on exact tokens, not on shape —
    /// nothing infers from a token's length or component count. A genuine
    /// repo path with two short, extensionless components is unaffected, and
    /// still refused when it doesn't resolve.
    func testTheProseAbbreviationExclusionDoesNotWidenToShortRepoPaths() {
        XCTAssertTrue(GroundingCheck.looksLikePath("ui/api"))

        let resolved = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "See `ui/api`.", approach: nil, verify: []),
            sources: sources(paths: ["ui/api"]))
        XCTAssertTrue(resolved.isGrounded, resolved.summary)
        XCTAssertEqual(resolved.checked.map(\.kind), [.path])

        let unresolved = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "See `ui/api`.", approach: nil, verify: []),
            sources: sources())
        XCTAssertFalse(unresolved.isGrounded)
        XCTAssertEqual(unresolved.unresolved.map(\.text), ["ui/api"])
    }

    /// A shell variable assignment is written with a slash because its value
    /// is a path, not because it names one — `PATH=/usr/bin:/bin:/usr/sbin:/sbin`
    /// is the search path a spawn is given, and no checkout ever holds a file
    /// at that token. `signal-sources-spawn-off-the-inherited-path` was parked
    /// for exactly this, its recorded reason being that the assignment it
    /// quotes is not in the repo or the vault and was read as a claim because
    /// it is written as a repo-relative path.
    func testAShellVariableAssignmentIsNotTreatedAsARepoClaim() {
        XCTAssertFalse(GroundingCheck.looksLikePath("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "The spawn inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin`.",
                           approach: nil, verify: []),
            sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked, [], verdict.audit)
    }

    /// The exclusion is the assignment shape, not the presence of an `=`
    /// anywhere in the token: a path that happens to hold one after its first
    /// slash, or whose leading component isn't a shell variable name, is still
    /// read as a path claim and still refused when it doesn't resolve.
    func testTheAssignmentExclusionDoesNotWidenToPathsThatMerelyContainAnEquals() {
        XCTAssertTrue(GroundingCheck.looksLikePath("Services/x=1.swift"))
        XCTAssertTrue(GroundingCheck.looksLikePath("3PATH=x/Foo.swift"))
        XCTAssertTrue(GroundingCheck.looksLikePath("PATH-X=x/Foo.swift"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Edit `Services/x=1.swift`.", approach: nil, verify: []),
            sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.path])
    }

    /// Every all-capitals word has a capital past its first letter, so the old
    /// symbol rule looked SQL keywords up as code and reported them missing.
    func testAnAllCapitalsWordIsNotASymbolClaim() {
        XCTAssertFalse(GroundingCheck.looksLikeSymbol("DROP"))
        XCTAssertFalse(GroundingCheck.looksLikeSymbol("GROUP"))
        XCTAssertFalse(GroundingCheck.looksLikeSymbol("DELETE"))
        XCTAssertNil(GroundingCheck.classify("DROP", precededBy: "the statement issues a "))
        // A multi-word span was never a single reference; `GROUP BY` stays prose.
        XCTAssertNil(GroundingCheck.classify("GROUP BY", precededBy: "aggregate with "))

        let prose = "The migration issues a `DROP` and the report aggregates with `GROUP BY`."
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: prose, approach: nil, verify: []),
                                              sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked, [])
    }

    /// The loosening above must not cost the check its reason to exist: a camel
    /// hump is still a symbol claim, and an invented one is still a refusal.
    func testACamelCasedNameIsStillASymbolClaimAndStillRefusedWhenInvented() {
        XCTAssertTrue(GroundingCheck.looksLikeSymbol("checkCostCaps"))
        XCTAssertTrue(GroundingCheck.looksLikeSymbol("phantomToolProvider"))
        XCTAssertTrue(GroundingCheck.looksLikeSymbol("BacklogAutopilot.start"))

        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: "Reuse `checkCostCaps` for the margin.",
                                                             approach: nil, verify: []),
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.text), ["checkCostCaps"])
        XCTAssertEqual(verdict.unresolved.first?.kind, .symbol)
    }

    func testARealSymbolStillResolvesAsASymbol() {
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: "Call `BacklogAutopilot.start`.",
                                                             approach: nil, verify: []),
                                              sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked.map(\.kind), [.symbol])
        XCTAssertEqual(verdict.checked.map(\.text), ["BacklogAutopilot.start"])
    }

    func testAMissingRepoPathIsStillRefused() {
        XCTAssertTrue(GroundingCheck.looksLikePath("Services/NoSuchFile.swift"))

        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: "Edit `Services/NoSuchFile.swift`.",
                                                             approach: nil, verify: []),
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.path])
        XCTAssertTrue(verdict.summary.contains("Services/NoSuchFile.swift"), verdict.summary)
    }

    // MARK: - Which corpus a citation belongs to

    /// The vault holds the backlog and every detail file, so `backlog/foo.md` and
    /// `Projects/kiteloop/Backlog.md` name real files — in a corpus the repo
    /// index has never held. Both were refused as inventions.
    func testAVaultPathResolvesAgainstTheVaultRatherThanTheRepo() {
        let sources = GroundingCheck.Sources(
            corpora: [
                .init(name: "the repo") { $0 == "Kiteloop/Kiteloop/Services/BacklogAutopilot.swift" },
                .init(name: "the vault") { ["backlog/foo.md", "Projects/kiteloop/Backlog.md"].contains($0) }
            ],
            definesSymbol: { _ in false },
            resolvesExecutable: { _ in true })

        let detail = detail(what: "Rewrite `backlog/foo.md` to match `Projects/kiteloop/Backlog.md`.",
                            approach: nil, verify: [])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: detail, sources: sources)

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked.map(\.text), ["backlog/foo.md", "Projects/kiteloop/Backlog.md"])
        XCTAssertTrue(verdict.checked.allSatisfy { $0.rule.contains("the vault") }, verdict.audit)
    }

    /// A sibling project answers only for an item that names it. Otherwise every
    /// project in the portfolio would ground every citation by coincidence, and
    /// the check would stop meaning anything.
    func testASiblingProjectPathResolvesOnlyForAnItemThatNamesThatProject() {
        let sources = GroundingCheck.Sources(
            corpora: [
                .init(name: "the repo") { _ in false },
                // Normalized the way the live sibling corpus normalizes, so
                // `.sqlx/` and `.sqlx` are the one claim they read as.
                .init(name: "the aurora project", namedBy: ["aurora"]) {
                    ["apps/web", "Cargo.toml", ".sqlx"]
                        .contains(GroundingCheck.SourceIndex.normalize($0))
                }
            ],
            definesSymbol: { _ in false },
            resolvesExecutable: { _ in true })

        let named = detail(what: "In the aurora repo, move `apps/web` off the `Cargo.toml` workspace "
                                 + "and regenerate `.sqlx/`.",
                           approach: nil, verify: [])
        let namedVerdict = GroundingCheck.evaluate(item: item(verify: nil), detail: named, sources: sources)
        XCTAssertTrue(namedVerdict.isGrounded, namedVerdict.summary)
        XCTAssertEqual(namedVerdict.checked.count, 3, namedVerdict.audit)

        // The same citations with no mention of aurora: the corpus is out of
        // scope, so nothing grounds them and the item is refused.
        let unnamed = detail(what: "Move `apps/web` off the `Cargo.toml` workspace.",
                             approach: nil, verify: [])
        let unnamedVerdict = GroundingCheck.evaluate(item: item(verify: nil), detail: unnamed, sources: sources)
        XCTAssertFalse(unnamedVerdict.isGrounded)
        XCTAssertFalse(unnamedVerdict.summary.contains("aurora"), unnamedVerdict.summary)
    }

    /// Property access on an object no file here defines is not a claim about
    /// this code. `window`, `res` and `process` root outside the repo, so the
    /// repo has no standing to call `window.name` wrong.
    func testPropertyAccessOnAnExternalObjectIsNotAClaimAboutThisCode() {
        let prose = "Read `window.name` when `res.ok`, and fall back to `process.env`."
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: prose, approach: nil, verify: []),
                                              sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked, [], verdict.audit)
    }

    /// A capitalised name is a type, and a platform, a package or the language
    /// defines types this tree could never index.
    func testAnExternalTypeNameIsNotRefused() {
        let prose = "The value arrives as a `DOMString`; widen `MutationObserver` to take it."
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: prose, approach: nil, verify: []),
                                              sources: sources())
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked, [], verdict.audit)
    }

    /// The loosening must not cost the check its purpose. A dotted name rooted in
    /// this repo is still a chain of claims, and a broken link is still a refusal.
    func testADottedNameRootedHereIsStillCheckedAllTheWayDown() {
        let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                              detail: detail(what: "Reuse `BacklogAutopilot.resumeQueue`.",
                                                             approach: nil, verify: []),
                                              sources: sources())
        XCTAssertFalse(verdict.isGrounded)
        XCTAssertTrue(verdict.summary.contains("`resumeQueue`"), verdict.summary)
    }

    // MARK: - Why a token was considered checkable

    /// Naming the token alone made every new false positive a fresh
    /// investigation into which rule had selected it. A refusal names both.
    func testARefusalNamesTheTokenAndTheRuleThatMadeItCheckable() throws {
        let symbol = GroundingCheck.evaluate(item: item(verify: nil),
                                             detail: detail(what: "Reuse `checkCostCaps`.",
                                                            approach: nil, verify: []),
                                             sources: sources())
        let refused = try XCTUnwrap(symbol.unresolved.first)
        XCTAssertTrue(refused.note?.contains("checkCostCaps") == true, symbol.summary)
        XCTAssertTrue(refused.note?.contains("lower-camel-case") == true, symbol.summary)
        XCTAssertEqual(refused.rule,
                       "it is a lower-camel-case name, which is a member this repo would define")

        let path = GroundingCheck.evaluate(item: item(verify: nil),
                                           detail: detail(what: "Edit `Services/NoSuchFile.swift`.",
                                                          approach: nil, verify: []),
                                           sources: sources())
        XCTAssertTrue(path.summary.contains("Services/NoSuchFile.swift"), path.summary)
        XCTAssertTrue(path.summary.contains("repo-relative path"), path.summary)
        // And it says where it looked, so "which corpus was missing" is a read.
        XCTAssertTrue(path.summary.contains("not in the repo"), path.summary)

        let command = GroundingCheck.evaluate(item: item(verify: "kiteloopctl verify"),
                                              detail: detail(approach: nil, verify: []),
                                              sources: sources())
        XCTAssertTrue(command.summary.contains("`verify:` command"), command.summary)
    }

    // MARK: - Every false-positive class seen on 2026-08-08/09

    /// The nine classes together, as one regression: each was a correctly groomed
    /// item that the gate refused, and each has to stay passing. The last two
    /// entries are the check's reason to exist and must still be refused.
    func testEveryObservedFalsePositiveClassPassesAndInventionsStillDoNot() {
        let sources = GroundingCheck.Sources(
            corpora: [
                .init(name: "the repo") { $0 == "Kiteloop/Kiteloop/Services/BacklogAutopilot.swift" },
                .init(name: "the vault") { $0 == "backlog/foo.md" },
                .init(name: "the aurora project", namedBy: ["aurora"]) { $0 == "apps/web" }
            ],
            definesSymbol: { ["BacklogAutopilot", "start"].contains($0) },
            resolvesExecutable: { $0 == "xcodebuild" })

        let passing = [
            "a home-rooted runtime file": "Read `~/.kiteloop/global-config.json` at launch.",
            "an API route": "Serve `/v1/coordinator/policy`.",
            "a package name": "Render with `@testing-library/react`.",
            "an all-capitals word": "The migration issues a `DROP`.",
            "a file:line reference": "See `Kiteloop/Kiteloop/Services/BacklogAutopilot.swift:145`.",
            "a file:line-range reference": "See `Kiteloop/Kiteloop/Services/BacklogAutopilot.swift:145-160`.",
            "a placeholder path": "Write `backlog/<id>.md`.",
            "a vault path": "Rewrite `backlog/foo.md`.",
            "property access on an external object": "Read `window.name` when `res.ok`.",
            "an external type name": "The value arrives as a `DOMString`.",
            "a sibling project path": "In aurora, move `apps/web`.",
            "a media type": "Serve it as `text/xml`, never as `text/html`.",
            "a schemeless host": "Book through `squareup.com/appointments`."
        ]
        for (label, prose) in passing {
            let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                                  detail: detail(what: prose, approach: nil, verify: []),
                                                  sources: sources)
            XCTAssertTrue(verdict.isGrounded, "\(label): \(prose) → \(verdict.summary)")
        }

        // Still refused, and still for the right reason.
        for prose in ["Reuse `checkCostCaps` for the margin.",
                      "Copy the pattern in `phantomToolProvider`.",
                      "Edit `Kiteloop/Kiteloop/Services/Nope.swift`."] {
            let verdict = GroundingCheck.evaluate(item: item(verify: nil),
                                                  detail: detail(what: prose, approach: nil, verify: []),
                                                  sources: sources)
            XCTAssertFalse(verdict.isGrounded, prose)
        }

        // And a real citation of each kind still resolves and still counts.
        let real = detail(what: "Call `BacklogAutopilot.start` in "
                                + "`Kiteloop/Kiteloop/Services/BacklogAutopilot.swift`.",
                          approach: nil,
                          verify: [.init(name: "build", cmd: "xcodebuild build", expect: nil)])
        let verdict = GroundingCheck.evaluate(item: item(verify: nil), detail: real, sources: sources)
        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked.count, 3, verdict.audit)
    }

    // MARK: - Files the app creates rather than keeps

    /// The settings file is real, and no checkout holds it: the app writes it to
    /// `~/.kiteloop/` on first launch, and `GlobalConfigStore` names it a line
    /// away from the code that opens it. Five of eight refusals in one pass were
    /// files of exactly that kind.
    func testAFileTheAppWritesResolvesFromTheSourceThatNamesIt() {
        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Read the ceiling out of `global-config.json` at launch.",
                           approach: nil, verify: []),
            sources: sources(literals: ["global-config.json"]))

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        // Audited like any other pass: the reference is listed, and its rule
        // says which question grounded it.
        XCTAssertEqual(verdict.checked.map(\.text), ["global-config.json"])
        XCTAssertEqual(verdict.checked.first?.kind, .path)
        XCTAssertTrue(verdict.audit.contains("path global-config.json"), verdict.audit)
        XCTAssertEqual(verdict.checked.first?.rule,
                       "it is written as a repo-relative path, and this repo's sources "
                       + "name the file `global-config.json`")
    }

    /// A runtime file is as often cited with the directory the app writes it to,
    /// and the sources construct the bare name — so the question is asked of the
    /// last component.
    func testARuntimeFileCitedWithItsDirectoryResolvesToo() {
        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Records survive a restart in `.kiteloop/control-runs.jsonl`.",
                           approach: nil, verify: []),
            sources: sources(literals: ["control-runs.jsonl"]))

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked.map(\.text), [".kiteloop/control-runs.jsonl"])
        XCTAssertEqual(verdict.checked.first?.rule,
                       "it is written as a repo-relative path, and this repo's sources "
                       + "name the file `control-runs.jsonl`")
    }

    /// The whole of the widening: a name no source constructs is refused exactly
    /// as it was, with the note it has always carried.
    func testAFilenameNoSourceConstructsIsStillRefusedWithTheNoteItCarriesToday() {
        let invented = detail(what: "Read the ceiling out of `phantom-config.json` at launch.",
                              approach: nil, verify: [])
        let widened = GroundingCheck.evaluate(item: item(verify: nil), detail: invented,
                                              sources: sources(literals: ["global-config.json"]))
        let before = GroundingCheck.evaluate(item: item(verify: nil), detail: invented,
                                             sources: sources())

        XCTAssertFalse(widened.isGrounded)
        XCTAssertEqual(widened.unresolved.map(\.kind), [.path])
        XCTAssertEqual(widened.unresolved.first?.note,
                       "cites `phantom-config.json`, which is not in the repo"
                       + "; read as a claim because it is written as a repo-relative path")
        // Word for word what it said before any of this existed.
        XCTAssertEqual(widened.unresolved, before.unresolved)
    }

    /// The corpora are still asked first, so a file that is genuinely on disk is
    /// still reported as being on disk — the weaker answer never displaces it.
    func testACorpusStillAnswersBeforeTheSourcesAreAsked() {
        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Edit `Kiteloop/Kiteloop/Services/BacklogAutopilot.swift`.",
                           approach: nil, verify: []),
            sources: sources(literals: ["BacklogAutopilot.swift"]))

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
        XCTAssertEqual(verdict.checked.first?.rule,
                       "it is written as a repo-relative path, and it is in the repo")
    }

    /// A `verify:` runs in a directory, and a file the app has not written yet is
    /// not in it — so a command's path arguments are judged as before, by where
    /// the repo actually keeps the file.
    func testACommandPathIsUnaffectedByWhatTheSourcesConstruct() {
        let verdict = GroundingCheck.evaluate(
            item: item(verify: "cat global-config.json"),
            detail: detail(what: "Read the ceiling.", approach: nil, verify: []),
            sources: sources(paths: ["Kiteloop/global-config.json"],
                             executables: ["cat"],
                             literals: ["global-config.json"]))

        XCTAssertFalse(verdict.isGrounded, verdict.audit)
        XCTAssertEqual(verdict.unresolved.map(\.kind), [.commandPath])
        XCTAssertTrue(verdict.summary.contains("cd Kiteloop"), verdict.summary)
    }

    // MARK: - Which literals a source contributes

    func testOnlyAFileShapedLiteralIsReadAsAFilename() {
        for literal in ["global-config.json", "control-runs.jsonl", "daily-spend.json",
                        "Info.plist", "run-unit-suite.sh", "a.b.c.yaml", "_private.swift"] {
            XCTAssertTrue(GroundingCheck.SourceIndex.looksLikeFilename(literal), literal)
        }
        for literal in ["", "platform=macOS", "a file.json", "Services/Foo.swift", "127.0.0.1",
                        "1.4.0", "BacklogAutopilot", "trailing.", ".json",
                        "x.verylongextension"] {
            XCTAssertFalse(GroundingCheck.SourceIndex.looksLikeFilename(literal), literal)
        }
    }

    func testLiteralsAreReadPerLineAndPerDelimiterSoProseCannotInventOne() {
        var literals: Set<String> = []
        GroundingCheck.SourceIndex.collectFileLiterals(from: """
        // the groomer's own note about a file.json it wants
        let url = dir.appending(path: "daily-spend.json")
        let script = 'run-unit-suite.sh'
        let unclosed = "orphan.json
        """, into: &literals)

        XCTAssertEqual(literals, ["daily-spend.json", "run-unit-suite.sh"])
    }

    /// A literal that already carries its directory — `home.appending(path:
    /// ".kiteloop/repo-links.json")` — still contributes its filename, so a
    /// draft citing the bare name is grounded.
    func testASlashBearingLiteralContributesItsLastComponent() {
        var literals: Set<String> = []
        GroundingCheck.SourceIndex.collectFileLiterals(from: """
        self.linksURL = home.appending(path: ".kiteloop/repo-links.json")
        """, into: &literals)

        XCTAssertEqual(literals, ["repo-links.json"])
    }

    /// The directory half of that same literal is not a claim this index makes —
    /// only the last component is a filename this repo's sources construct.
    func testASlashBearingLiteralContributesNothingForItsDirectory() {
        var literals: Set<String> = []
        GroundingCheck.SourceIndex.collectFileLiterals(from: """
        self.linksURL = home.appending(path: ".kiteloop/repo-links.json")
        """, into: &literals)

        XCTAssertFalse(literals.contains(".kiteloop"))
        XCTAssertFalse(literals.contains(".kiteloop/repo-links.json"))
    }

    /// A slash-bearing literal whose last component isn't file-shaped —
    /// no extension, or a fragment lifted out of prose — contributes nothing,
    /// same as a bare literal in that shape always has.
    func testASlashBearingLiteralWithAnUnshapedLastComponentContributesNothing() {
        var literals: Set<String> = []
        GroundingCheck.SourceIndex.collectFileLiterals(from: """
        let dir = root.appending(path: "logs/2024")
        let note = "see the docs/for more detail"
        """, into: &literals)

        XCTAssertTrue(literals.isEmpty, "\(literals)")
    }

    /// End to end: a draft citing the bare filename out of a multi-segment
    /// literal is no longer refused as an invention.
    func testConstructsFileGroundsABareFilenameFromASlashBearingLiteral() throws {
        let root = try makeTemporaryDirectory(prefix: "grounding-slash-literal")
        let fm = FileManager.default
        let services = root.appending(path: "Kiteloop/Kiteloop/Services")
        try fm.createDirectory(at: services, withIntermediateDirectories: true)

        try """
        struct RepoStatusStore {
            init() {
                self.linksURL = home.appending(path: ".kiteloop/repo-links.json")
            }
        }
        """.write(to: services.appending(path: "RepoStatusStore.swift"),
                  atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: root)
        XCTAssertTrue(index.fileLiterals.contains("repo-links.json"))

        let verdict = GroundingCheck.evaluate(
            item: item(verify: nil),
            detail: detail(what: "Read the links out of `repo-links.json` at launch.",
                           approach: nil, verify: []),
            sources: .repository(root: root))

        XCTAssertTrue(verdict.isGrounded, verdict.audit)
    }

    // MARK: - The live corpora

    /// The vault is walked for paths, never for identifiers: a name that appears
    /// only in a note is the invention the check exists to catch.
    func testTheVaultIsIndexedForPathsAndNotForIdentifiers() throws {
        let vault = try makeTemporaryDirectory(prefix: "grounding-vault")
        let project = vault.appending(path: "Projects/kiteloop/backlog")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        try "# Foo\n".write(to: project.appending(path: "foo.md"), atomically: true, encoding: .utf8)
        try "let ghostSymbol = 1\n"
            .write(to: vault.appending(path: "Projects/kiteloop/notes.swift"),
                   atomically: true, encoding: .utf8)

        let index = GroundingCheck.SourceIndex.build(root: vault, indexingIdentifiers: false)

        // The path a draft writes — relative to the backlog file — resolves.
        XCTAssertTrue(index.containsPath("backlog/foo.md"))
        XCTAssertTrue(index.containsPath("Projects/kiteloop/backlog/foo.md"))
        XCTAssertFalse(index.containsPath("backlog/nope.md"))
        XCTAssertTrue(index.identifiers.isEmpty, "the vault must not ground symbols")
    }

    /// Sibling corpora come from the vault's own registry, so no caller has to
    /// hand the check a portfolio it would then have to keep in step.
    func testSiblingCorporaComeFromTheVaultRegistryAndExcludeTheProjectItself() throws {
        let temporary = try makeTemporaryDirectory(prefix: "grounding-portfolio")
        let vault = temporary.appending(path: "vault")
        let here = temporary.appending(path: "kiteloop")
        let sibling = temporary.appending(path: "aurora")
        let fm = FileManager.default
        try fm.createDirectory(at: vault.appending(path: "Logs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: here, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling.appending(path: "apps/web"), withIntermediateDirectories: true)

        try "[workspace]\n".write(to: sibling.appending(path: "Cargo.toml"),
                                  atomically: true, encoding: .utf8)
        try """
        projects:
          kiteloop:
            name: Kiteloop
            backlog: Projects/kiteloop/Backlog.md
            repo: \(here.path(percentEncoded: false))
          aurora:
            name: Aurora
            backlog: Projects/aurora/Backlog.md
            repo: \(sibling.path(percentEncoded: false))
            aliases: [aurora-web]
        """.write(to: vault.appending(path: "Logs/registry.yaml"), atomically: true, encoding: .utf8)

        let corpora = GroundingCheck.Sources.siblingCorpora(vault: vault, excluding: here)

        // The project being checked is already the repo corpus, not a sibling.
        XCTAssertEqual(corpora.map(\.name), ["the Aurora project"])
        let aurora = try XCTUnwrap(corpora.first)
        XCTAssertTrue(aurora.contains("apps/web"))
        XCTAssertTrue(aurora.contains("Cargo.toml"))
        XCTAssertFalse(aurora.contains("apps/nope"))

        // In scope for a draft that names it — by name, folder or alias — and
        // out of scope for one that doesn't.
        XCTAssertTrue(aurora.isNamed(by: GroundingCheck.words(in: "Move the Aurora front end.")))
        XCTAssertTrue(aurora.isNamed(by: GroundingCheck.words(in: "Fix aurora-web routing.")))
        XCTAssertFalse(aurora.isNamed(by: GroundingCheck.words(in: "Dedupe the sync queue.")))
    }

    func testExecutableResolutionFindsToolchainBinariesOutsideAThinPath() {
        // A GUI app's PATH can be almost empty; the app's one search policy
        // reaches the usual locations anyway so a good command isn't refused
        // for the launch environment.
        let directories = ExecutableSearchPath.resolved(projectRoot: nil).directories
        XCTAssertTrue(directories.contains("/usr/bin"))
        XCTAssertTrue(directories.contains("/opt/homebrew/bin"))
        XCTAssertTrue(GroundingCheck.Executables.resolves("ls", root: URL(fileURLWithPath: "/"),
                                                          searchDirectories: directories))
        XCTAssertFalse(GroundingCheck.Executables.resolves("kiteloopctl", root: URL(fileURLWithPath: "/"),
                                                           searchDirectories: directories))
    }
}
