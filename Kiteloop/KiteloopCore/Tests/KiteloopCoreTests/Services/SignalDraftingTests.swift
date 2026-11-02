import XCTest
@testable import KiteloopCore

final class SignalDraftingTests: XCTestCase {

    private func finding(instrument: SignalFinding.Instrument = .flake, key: String = "FooTests.testBar",
                         title: String? = nil, evidence: [String] = ["3 flips at abc123 — a .. b"]) -> SignalFinding {
        SignalFinding(instrument: instrument, key: key, title: title ?? key, evidence: evidence)
    }

    // MARK: - Kind and shape

    /// The refill hands every draft the project's own verify: a Rust
    /// project's hotspot items carried `xcodebuild` until it did.
    func testADraftCarriesTheVerifyItIsGiven() {
        for instrument in [SignalFinding.Instrument.flake, .hotspot, .escapedDefect, .redSuite] {
            let draft = SignalDrafting.draft(for: finding(instrument: instrument, key: "k"), verify: "cargo test")
            XCTAssertEqual(draft.verify, "cargo test", "\(instrument)")
        }
        let drafts = SignalDrafting.drafts(for: [finding(instrument: .hotspot, key: "k")], existingIDs: [],
                                           verify: "cargo test")
        XCTAssertEqual(drafts.map(\.verify), ["cargo test"])
    }

    /// A map with a catch-all rule is run by the gate on any diff, so a
    /// signal draft carries no copy of the chain — one backlog held 361
    /// distinct `verify:` lines before it did not.
    func testACatchAllMapLeavesASignalDraftWithNoCopiedChain() {
        let map = VerifyCoverage.Map(rules: [
            VerifyCoverage.Rule(glob: "**/*.swift", command: "./quality/bin/check-complexity.sh"),
            VerifyCoverage.Rule(glob: "**", command: "./scripts/ci.sh && cargo test")
        ])
        let verify = SignalDrafting.verify(mergeVerify: "./scripts/ci.sh && cargo test", map: map)
        XCTAssertEqual(verify, "")
        for instrument in [SignalFinding.Instrument.flake, .hotspot, .escapedDefect, .redSuite] {
            let draft = SignalDrafting.draft(for: finding(instrument: instrument, key: "k"), verify: verify ?? "x")
            XCTAssertEqual(draft.verify, "", "\(instrument)")
        }
    }

    /// Without a catch-all rule — scoped rules only, or no map — a draft
    /// carries the project's merge-verify, as before.
    func testAMapWithoutACatchAllDraftsAsToday() {
        let scoped = VerifyCoverage.Map(rules: [
            VerifyCoverage.Rule(glob: "**/*.swift", command: "./quality/bin/check-complexity.sh"),
            VerifyCoverage.Rule(glob: "apps/**", command: "cargo test")
        ])
        XCTAssertFalse(SignalDrafting.hasCatchAll(scoped))
        XCTAssertEqual(SignalDrafting.verify(mergeVerify: "cargo test", map: scoped), "cargo test")
        XCTAssertEqual(SignalDrafting.verify(mergeVerify: "cargo test", map: .none), "cargo test")
        XCTAssertNil(SignalDrafting.verify(mergeVerify: nil, map: .none))
        let draft = SignalDrafting.draft(for: finding(instrument: .hotspot, key: "k"),
                                         verify: SignalDrafting.verify(mergeVerify: "cargo test", map: scoped) ?? "")
        XCTAssertEqual(draft.verify, "cargo test")
    }

    func testFlakeDraftsAsABug() {
        let draft = SignalDrafting.draft(for: finding())
        XCTAssertTrue(draft.title.contains("FooTests.testBar"))
        XCTAssertFalse(draft.what.isEmpty)
        XCTAssertFalse(draft.how.isEmpty)
        XCTAssertFalse(draft.validation.isEmpty)
        XCTAssertEqual(draft.verify, SignalDrafting.defaultVerify)
        XCTAssertEqual(draft.size, "S")
    }

    // A flake fix runs once, on the branch that fixes it — the record of a
    // flip that already happened stays in `docs/suite-status.md` forever, so a
    // criterion asking the flake ledger to stop naming the test can never be
    // met by any diff. Every criterion the draft writes has to be judged from
    // the diff alone.
    func testFlakeDraftValidationIsJudgeableFromTheDiffAlone() {
        let draft = SignalDrafting.draft(for: finding())
        XCTAssertFalse(draft.validation.contains { $0.contains("no longer names") })
        XCTAssertTrue(draft.validation.contains { $0.contains("nondeterminism") && $0.contains("pins it") })
    }

    func testHotspotDraftsAsARefactor() {
        let draft = SignalDrafting.draft(for: finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:12",
                                                       title: "func doThing()",
                                                       evidence: ["hotspot 56 (churn 8 x cc 7)"]))
        XCTAssertTrue(draft.title.hasPrefix("Refactor hotspot:"))
        // The file is cited in backticks so grounding looks it up — an item
        // was filed for a file that had become a directory.
        XCTAssertTrue(draft.what.contains("`Kiteloop/Foo.swift:12`"), draft.what)
        XCTAssertTrue(draft.how.contains("`Kiteloop/Foo.swift:12`"), draft.how)
        XCTAssertTrue(draft.what.contains("Kiteloop/Foo.swift:12"))
    }

    func testEscapedDefectDraftsAsABug() {
        let draft = SignalDrafting.draft(for: finding(instrument: .escapedDefect, key: "old-item",
                                                       evidence: ["reopened to ready on 2026-08-10T00:00:00Z"]))
        XCTAssertTrue(draft.title.contains("old-item"))
        XCTAssertTrue(draft.what.contains("old-item"))
    }

    /// A red row says the test did not pass; it says nothing about
    /// nondeterminism, so the draft must not ask for the flake draft's answer.
    func testRedSuiteDraftsAsABugAndDoesNotAskForASourceOfNondeterminism() {
        let draft = SignalDrafting.draft(
            for: finding(instrument: .redSuite, key: "KiteloopTests.FooTests.testA",
                         evidence: ["named in the failing cell of the newest row of docs/suite-status.md",
                                    "commit 445afbbd (clean tree)"]))
        XCTAssertEqual(SignalFinding.Kind.bug,
                       finding(instrument: .redSuite, key: "KiteloopTests.FooTests.testA").kind)
        XCTAssertTrue(draft.title.contains("KiteloopTests.FooTests.testA"))
        XCTAssertTrue(draft.what.contains("KiteloopTests.FooTests.testA"))
        XCTAssertTrue(draft.what.contains("commit 445afbbd (clean tree)"))
        XCTAssertEqual(draft.verify, SignalDrafting.defaultVerify)
        XCTAssertEqual(draft.size, "S")
        XCTAssertFalse(draft.how.contains("nondeterminism"))
    }

    // MARK: - Stable, deterministic ids

    func testIdIsDeterministicAndInstrumentPrefixed() {
        let flake = finding(instrument: .flake, key: "FooTests.testBar")
        let hotspot = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:12")
        let defect = finding(instrument: .escapedDefect, key: "old-item")
        XCTAssertEqual(SignalDrafting.id(for: flake), SignalDrafting.id(for: flake))
        XCTAssertTrue(SignalDrafting.id(for: flake).hasPrefix("flaky-test-"))
        XCTAssertTrue(SignalDrafting.id(for: hotspot).hasPrefix("hotspot-"))
        XCTAssertTrue(SignalDrafting.id(for: defect).hasPrefix("escaped-defect-"))
        let red = finding(instrument: .redSuite, key: "KiteloopTests.FooTests.testA")
        XCTAssertEqual(SignalDrafting.id(for: red), SignalDrafting.id(for: red))
        XCTAssertEqual(SignalDrafting.id(for: red), "red-suite-kitelooptests-footests-testa")
    }

    // MARK: - Escaped-defect prefixing is idempotent — a reopened item that is
    // itself an escaped-defect item folds onto the id already filed for it,
    // rather than nesting a second prefix onto the first.

    func testEscapedDefectIdOfAnAlreadyPrefixedKeyIsNotDoublyPrefixed() {
        let reopenedTwig = finding(instrument: .escapedDefect, key: "escaped-defect-old-item")
        XCTAssertEqual(SignalDrafting.id(for: reopenedTwig), "escaped-defect-old-item")
    }

    func testEscapedDefectIdIsStableAcrossRepeatedEscapes() {
        let firstEscape = finding(instrument: .escapedDefect, key: "old-item")
        let firstID = SignalDrafting.id(for: firstEscape)
        let secondEscape = finding(instrument: .escapedDefect, key: firstID)
        let secondID = SignalDrafting.id(for: secondEscape)
        let thirdEscape = finding(instrument: .escapedDefect, key: secondID)
        let thirdID = SignalDrafting.id(for: thirdEscape)
        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(secondID, thirdID)
    }

    func testEscapedDefectIdStillPrefixesAKeyWithoutIt() {
        let fresh = finding(instrument: .escapedDefect, key: "brand-new-item")
        XCTAssertEqual(SignalDrafting.id(for: fresh), "escaped-defect-brand-new-item")
    }

    func testAReescapedItemFilesNothingNewBecauseTheFoldedIdIsAlreadyFiled() {
        let reopenedTwig = finding(instrument: .escapedDefect, key: "escaped-defect-old-item",
                                   evidence: ["reopened to ready on 2026-08-10T00:00:00Z"])
        let existingID = "escaped-defect-old-item"
        XCTAssertEqual(SignalDrafting.drafts(for: [reopenedTwig], existingIDs: [existingID]), [])
    }

    // MARK: - Hotspot ids survive the function moving lines

    func testHotspotIdIsStableWhenTheDeclarationMovesLines() {
        let before = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:412", title: "func doThing()")
        let after = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:418", title: "func doThing()")
        XCTAssertEqual(SignalDrafting.id(for: before), SignalDrafting.id(for: after))
    }

    func testHotspotIdDiffersForDifferentDeclarationsInTheSameFile() {
        let doThing = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:412", title: "func doThing()")
        let doOther = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:412", title: "func doOther()")
        XCTAssertNotEqual(SignalDrafting.id(for: doThing), SignalDrafting.id(for: doOther))
    }

    func testHotspotIdDropsTheLineNumberWhenADeclaredNameIsReadable() {
        let title = "private func hotspotFindings(repoRoot: URL) -> [SignalFinding] {"
        let hotspot = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:412", title: title)
        XCTAssertFalse(SignalDrafting.id(for: hotspot).contains("412"))
        XCTAssertTrue(SignalDrafting.id(for: hotspot).contains("hotspotfindings"))
    }

    func testHotspotIdIsStableForAnInitializerAcrossLines() {
        let title = "init(path: String, projectRoot: String) {"
        let before = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:412", title: title)
        let after = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:418", title: title)
        XCTAssertEqual(SignalDrafting.id(for: before), SignalDrafting.id(for: after))
        XCTAssertFalse(SignalDrafting.id(for: before).contains("412"))
        XCTAssertTrue(SignalDrafting.id(for: before).contains("init"))
    }

    func testHotspotIdDiffersForOverloadedInitializersInTheSameFile() {
        let byPath = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:412",
                             title: "init(path: String) {")
        let byURL = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:412",
                            title: "init(url: URL) {")
        XCTAssertNotEqual(SignalDrafting.id(for: byPath), SignalDrafting.id(for: byURL))
    }

    func testHotspotIdFallsBackToTheKeyWhenNoDeclaredNameIsReadable() {
        let unparsedOne = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:412", title: "¯\\_(ツ)_/¯")
        let unparsedTwo = finding(instrument: .hotspot, key: "Kiteloop/Foo.swift:418", title: "¯\\_(ツ)_/¯")
        XCTAssertNotEqual(SignalDrafting.id(for: unparsedOne), SignalDrafting.id(for: unparsedTwo))
        XCTAssertTrue(SignalDrafting.id(for: unparsedOne).contains("412"))
    }

    // MARK: - The report is not Swift-only: Python and TypeScript rows too

    func testHotspotIdIsStableWhenAPythonDefMovesLines() {
        let title = "def marathon(client, report, project, hours, timeout_min, auto_approve"
        let before = finding(instrument: .hotspot, key: "scripts/kiteloop-verify.py:790", title: title)
        let after = finding(instrument: .hotspot, key: "scripts/kiteloop-verify.py:812", title: title)
        XCTAssertEqual(SignalDrafting.id(for: before), SignalDrafting.id(for: after))
        XCTAssertFalse(SignalDrafting.id(for: before).contains("790"))
        XCTAssertTrue(SignalDrafting.id(for: before).contains("marathon"))
    }

    func testHotspotIdDiffersForDifferentPythonDefsInTheSameFile() {
        let marathon = finding(instrument: .hotspot, key: "scripts/kiteloop-verify.py:790",
                               title: "def marathon(client, report, project, hours, timeout_min, auto_approve")
        let runLoop = finding(instrument: .hotspot, key: "scripts/kiteloop-verify.py:657",
                              title: "def run_loop(client, report, project, item, approve, timeout_min, repo")
        XCTAssertNotEqual(SignalDrafting.id(for: marathon), SignalDrafting.id(for: runLoop))
    }

    func testHotspotIdOfATypeScriptFunctionIsBuiltFromItsName() {
        let title = "export function resolveProject(context: vscode.ExtensionContext): void {"
        let hotspot = finding(instrument: .hotspot, key: "copilot-bridge-extension/src/extension.ts:7",
                              title: title)
        XCTAssertFalse(SignalDrafting.id(for: hotspot).contains("7"))
        XCTAssertTrue(SignalDrafting.id(for: hotspot).contains("resolveproject"))
    }

    // MARK: - The id is capped at 64 characters, the way `QueueRefill.Draft.slug`
    // caps a model-drafted id.

    func testIdOverTheCapIsTruncatedToExactly64Characters() {
        let longKey = "FooTests." + String(repeating: "testVeryLongScenarioName", count: 4)
        let long = finding(instrument: .flake, key: longKey)
        XCTAssertGreaterThan("flaky-test-\(longKey)".count, 64)
        XCTAssertEqual(SignalDrafting.id(for: long).count, 64)
    }

    func testIdAtOrUnderTheCapIsUnchanged() {
        let short = finding(instrument: .flake, key: "FooTests.testBar")
        XCTAssertEqual(SignalDrafting.id(for: short), "flaky-test-footests-testbar")
    }

    /// Two findings whose ids agree on their first 64 characters and differ
    /// only after it collide once capped: `id(for:)` cannot tell them apart
    /// any more, and `drafts(for:existingIDs:)` does not try to — nothing
    /// here adds the title-duplicate gate the model-draft path has. Both are
    /// drafted, both carry the same, now-shared id, and whichever is filed
    /// last — the later one in `findings` — is the one a backlog write keyed
    /// by id ends up holding, since the earlier one's file is overwritten.
    func testTwoFindingsSharingTheFirst64CharactersCollideAndTheLaterOneWins() {
        let sharedPrefix = String(repeating: "a", count: 70)
        let first = finding(instrument: .flake, key: "\(sharedPrefix)X")
        let second = finding(instrument: .flake, key: "\(sharedPrefix)Y")
        XCTAssertEqual(SignalDrafting.id(for: first), SignalDrafting.id(for: second))

        let drafted = SignalDrafting.drafts(for: [first, second], existingIDs: [])
        XCTAssertEqual(drafted.count, 2)
        XCTAssertEqual(drafted[0].id, drafted[1].id)
        // The later finding, `second`, is the one whose fields a keyed write
        // would end up with.
        XCTAssertEqual(drafted.last?.what, SignalDrafting.draft(for: second).what)
    }

    // MARK: - A finding already filed under its longer, pre-cap id is not
    // re-drafted once the cap shortens the id it would file under next.

    func testFindingFiledUnderItsPreCapIdIsNotRedraftedUnderTheCappedOne() {
        let longKey = "FooTests." + String(repeating: "testVeryLongScenarioName", count: 4)
        let long = finding(instrument: .flake, key: longKey)
        let preCapID = SignalDrafting.preCapID(for: long)
        XCTAssertGreaterThan(preCapID.count, 64)
        XCTAssertNotEqual(preCapID, SignalDrafting.id(for: long))

        XCTAssertEqual(SignalDrafting.drafts(for: [long], existingIDs: [preCapID]), [])
    }

    // MARK: - Dedup against open items — Validation: "a finding matching an open item's key is not re-filed"

    func testFindingAlreadyFiledIsNotRedrafted() {
        let target = finding()
        let existingID = SignalDrafting.id(for: target)
        XCTAssertEqual(SignalDrafting.drafts(for: [target], existingIDs: [existingID]), [])
    }

    func testFindingNotYetFiledIsDrafted() {
        let target = finding()
        XCTAssertEqual(SignalDrafting.drafts(for: [target], existingIDs: []).count, 1)
    }

    /// The red-suite finding is skipped by the same id check as the rest: once
    /// an item is filed for a failing test, the next refill pass over the same
    /// still-newest row files nothing new.
    func testARedSuiteFindingAlreadyFiledIsNotRedrafted() {
        let target = finding(instrument: .redSuite, key: "KiteloopTests.FooTests.testA")
        XCTAssertEqual(SignalDrafting.drafts(for: [target], existingIDs: []).map(\.id),
                       [SignalDrafting.id(for: target)])
        XCTAssertEqual(SignalDrafting.drafts(for: [target], existingIDs: [SignalDrafting.id(for: target)]), [])
    }

    func testOnlyTheMatchingFindingIsSkipped() {
        let filed = finding(key: "FooTests.testBar")
        let fresh = finding(key: "BazTests.testQux")
        let drafted = SignalDrafting.drafts(for: [filed, fresh], existingIDs: [SignalDrafting.id(for: filed)])
        XCTAssertEqual(drafted.map(\.id), [SignalDrafting.id(for: fresh)])
    }

    // MARK: - End to end: a flake fixture files a bug with the flip count in the What

    func testEndToEndFlakeFixtureFilesABugWithTheFlipCountInWhat() {
        let output = """
        run-unit-suite: flake ledger
          ChatViewModelTests.testForwardsToolCallEvent
            3 flips at abc123, def456 — 2026-08-01T00:00:00Z .. 2026-08-10T00:00:00Z
        """
        let findings = FlakeLedgerReader.read(output)
        let drafts = SignalDrafting.drafts(for: findings, existingIDs: [])

        XCTAssertEqual(drafts.count, 1)
        let draft = drafts[0]
        XCTAssertTrue(draft.title.contains("ChatViewModelTests.testForwardsToolCallEvent"))
        XCTAssertTrue(draft.what.contains("3 flips"))
        XCTAssertFalse(draft.verify.isEmpty)
    }

    // MARK: - Coverage: `defaultVerify` must run every unconditional Swift rule
    //
    // `.kiteloop/verify-map.json` applies `check-complexity.sh` and
    // `check-layering.py` to `**/*.swift` unconditionally — any changed Swift
    // file matches, wherever it lives. Every drafted item's `verify:` is
    // `defaultVerify`, and every instrument's finding names a Swift path, so
    // `defaultVerify` has to run both or every drafted item is guaranteed a
    // `VerifyCoverage` gap before a worker even starts. Mirrors
    // `VerifyDefaultCoverageTests`, which pins the same relationship for
    // `verify_default` in `.kiteloop/backlog-tree/BACKLOG.md`.

    private static let complexityRule = VerifyCoverage.Rule(
        glob: "**/*.swift", command: "./quality/bin/check-complexity.sh")
    private static let layeringRule = VerifyCoverage.Rule(
        glob: "**/*.swift", command: "./quality/bin/check-layering.py")
    private static let hygieneRule = VerifyCoverage.Rule(
        glob: "Kiteloop/KiteloopTests/**", command: "./quality/bin/check-test-hygiene.py")
    private static let coreTestsRule = VerifyCoverage.Rule(
        glob: "Kiteloop/KiteloopCore/**/*.swift", command: "scripts/run-core-tests.sh",
        run: "./scripts/run-core-tests.sh")
    private static let coreTestsHygieneRule = VerifyCoverage.Rule(
        glob: "Kiteloop/KiteloopCore/Tests/**", command: "./quality/bin/check-test-hygiene.py")
    private static let buildScheme = "xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop"
    private static let buildRun = "cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop "
        + "-destination \"platform=macOS\" build-for-testing"
    private static let appBuildRule = VerifyCoverage.Rule(
        glob: "Kiteloop/Kiteloop/**/*.swift", command: buildScheme, run: buildRun)
    private static let projectBuildRule = VerifyCoverage.Rule(
        glob: "Kiteloop/Kiteloop.xcodeproj/**", command: buildScheme, run: buildRun)
    private static let docSizeRule = VerifyCoverage.Rule(
        glob: "CLAUDE.md", command: "./quality/bin/check-doc-size.py")
    private static let featuresMapRule = VerifyCoverage.Rule(
        glob: "docs/features.md", command: "./quality/bin/check-features-map.py")

    func testDefaultVerifyCoversBothUnconditionalSwiftRules() {
        let map = VerifyCoverage.Map(rules: [Self.complexityRule, Self.layeringRule, Self.hygieneRule])
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Example.swift"],
            ranCommands: [SignalDrafting.defaultVerify],
            map: map)
        XCTAssertTrue(verdict.isCovered, verdict.summary)
        XCTAssertEqual(Set(verdict.covered.map(\.command)),
                        [Self.complexityRule.command, Self.layeringRule.command])
    }

    /// The gap this item exists to close: a fix landing in the package's
    /// sources, its own test tree, or the app's test tree must not gap on the
    /// command `.kiteloop/verify-map.json` names for that path — the map's own
    /// rules, hand-built here so a change to the map on disk cannot mask a
    /// regression in `defaultVerify` the way loading it would.
    func testDefaultVerifyCoversPackageAndTestTreePaths() {
        let map = VerifyCoverage.Map(rules: [
            Self.appBuildRule, Self.projectBuildRule,
            Self.complexityRule, Self.layeringRule, Self.hygieneRule,
            Self.coreTestsRule, Self.coreTestsHygieneRule,
            Self.docSizeRule, Self.featuresMapRule
        ])
        let verdict = VerifyCoverage.evaluate(
            changedFiles: [
                "Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Example.swift",
                "Kiteloop/KiteloopCore/Tests/KiteloopCoreTests/Services/ExampleTests.swift",
                "Kiteloop/KiteloopTests/Services/ExampleViewModelTests.swift"
            ],
            ranCommands: [SignalDrafting.defaultVerify],
            map: map)
        XCTAssertTrue(verdict.isCovered, verdict.summary)
        XCTAssertEqual(Set(verdict.covered.map(\.command)),
                        [Self.complexityRule.command, Self.layeringRule.command,
                         Self.hygieneRule.command, Self.coreTestsRule.command])
    }

    /// A rule is unconditional when its glob matches a path built from
    /// nothing this repo actually contains — see `VerifyDefaultCoverageTests.isUnconditional`.
    private static func isUnconditional(_ rule: VerifyCoverage.Rule) -> Bool {
        let suffix = rule.glob.lastIndex(of: "*").map { String(rule.glob[rule.glob.index(after: $0)...]) } ?? ""
        let probe = "zz-arbitrary-probe-3f1c9a2e/nested/zz-arbitrary-probe-3f1c9a2e" + suffix
        return VerifyCoverage.matches(glob: rule.glob, path: probe)
    }

    /// A rule a drafted fix reaches routinely even though it is not
    /// unconditional: the package's own sources and the two test trees the
    /// flake ledger and `report-hotspots.py` name findings in.
    private static func isRoutinelyReached(_ rule: VerifyCoverage.Rule) -> Bool {
        isUnconditional(rule)
            || rule.glob.hasPrefix("Kiteloop/KiteloopCore/")
            || rule.glob.hasPrefix("Kiteloop/KiteloopTests/")
    }

    /// It must fail if a new unconditional rule, or a package/test-tree rule
    /// a drafted fix reaches routinely, is added to `.kiteloop/verify-map.json`
    /// without widening `defaultVerify` to run it — the regression this item
    /// exists to stop happening twice.
    func testDefaultVerifyCoversEveryRuleItRoutinelyReachesInThisCheckoutsRealMap() throws {
        let root = RepositoryRoot.of()
        let project = KiteloopProject(rootURL: root)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: VerifyMapFile.url(for: project).path(percentEncoded: false)),
            "no .kiteloop/verify-map.json to read at \(root.path(percentEncoded: false)) — "
                + "absent in a throwaway worktree and on CI, present on a developer's own checkout")

        let map = VerifyMapFile.load(for: project)
        let alwaysReached = map.rules.filter(Self.isRoutinelyReached)
        for rule in alwaysReached {
            XCTAssertTrue(
                VerifyCoverage.wasRun(rule.command, in: [SignalDrafting.defaultVerify]),
                "SignalDrafting.defaultVerify does not run `\(rule.command)`, which \(rule.glob) applies to")
        }
    }
}
