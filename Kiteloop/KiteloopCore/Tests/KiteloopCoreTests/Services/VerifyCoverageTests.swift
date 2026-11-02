import XCTest
@testable import KiteloopCore

/// The coverage gate: whether an item's `verify:` exercises what its run
/// changed, and what a run it turns back is told.
@MainActor
final class VerifyCoverageTests: XCTestCase {

    private let webRule = VerifyCoverage.Rule(glob: "apps/web/**",
                                              command: "npm --prefix apps/web test")
    private let apiRule = VerifyCoverage.Rule(glob: "apps/api/**",
                                              command: "cargo check --workspace")

    private func map(_ rules: VerifyCoverage.Rule...) -> VerifyCoverage.Map {
        VerifyCoverage.Map(rules: rules)
    }

    // MARK: - The failure this exists for

    /// `test-expert-profile`, 2026-08-08: a web-only verify over a diff that
    /// carried a new Rust endpoint, a query rewrite and a ratchet change. The
    /// backend half merged with nothing having compiled it.
    func testWebOnlyVerifyOverABackendDiffIsAGap() {
        let verdict = VerifyCoverage.evaluate(
            changedFiles: [
                "apps/web/src/ExpertProfile.tsx",
                "apps/web/src/ExpertProfile.test.tsx",
                "apps/api/src/routes/expert.rs",
                "apps/api/.sqlx/query-cache.json",
                "apps/api/query-ratchet.toml",
            ],
            ranCommands: ["npm --prefix apps/web test"],
            map: map(webRule, apiRule)
        )
        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.gaps.count, 1)
        XCTAssertEqual(verdict.covered, [webRule])
        XCTAssertEqual(verdict.gaps.first?.glob, "apps/api/**")
        XCTAssertEqual(verdict.gaps.first?.command, "cargo check --workspace")
        XCTAssertEqual(verdict.gaps.first?.paths, [
            "apps/api/src/routes/expert.rs",
            "apps/api/.sqlx/query-cache.json",
            "apps/api/query-ratchet.toml",
        ])
    }

    /// Naming all three — the files, the glob, the missing command — is the
    /// whole point: "coverage failed" sends someone reading code to find out why.
    func testSummaryNamesPathsGlobAndMissingCommand() {
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["apps/api/src/routes/expert.rs"],
            ranCommands: ["npm --prefix apps/web test"],
            map: map(apiRule)
        )
        let summary = verdict.summary
        XCTAssertTrue(summary.contains("apps/api/**"), summary)
        XCTAssertTrue(summary.contains("apps/api/src/routes/expert.rs"), summary)
        XCTAssertTrue(summary.contains("cargo check --workspace"), summary)
        XCTAssertTrue(summary.contains("1 file"), summary)
    }

    /// A gap over a big diff stays a log line: name enough files to identify the
    /// change, then say how many more there are.
    func testSummaryTruncatesLongPathLists() {
        let files = (1...9).map { "apps/api/src/f\($0).rs" }
        let verdict = VerifyCoverage.evaluate(changedFiles: files, ranCommands: [], map: map(apiRule))
        XCTAssertEqual(verdict.gaps.first?.paths.count, 9, "the verdict keeps every path")
        XCTAssertTrue(verdict.summary.contains("apps/api/src/f5.rs"), verdict.summary)
        XCTAssertFalse(verdict.summary.contains("apps/api/src/f6.rs"), verdict.summary)
        XCTAssertTrue(verdict.summary.contains("+4 more"), verdict.summary)
    }

    // MARK: - What must keep passing

    func testFullyCoveredDiffPasses() {
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["apps/web/src/ExpertProfile.tsx", "apps/api/src/lib.rs"],
            ranCommands: ["npm --prefix apps/web test", "cargo check --workspace"],
            map: map(webRule, apiRule)
        )
        XCTAssertTrue(verdict.isCovered)
        XCTAssertEqual(verdict.summary, "")
        XCTAssertEqual(verdict.covered, [webRule, apiRule])
    }

    /// A project that configured no map is not gated — this ships a mechanism,
    /// not a blocker every repo has to opt out of.
    func testEmptyMapNeverGates() {
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["apps/api/src/lib.rs"],
            ranCommands: [],
            map: .none
        )
        XCTAssertTrue(verdict.isCovered)
        XCTAssertEqual(verdict.covered, [])
    }

    /// An unmapped path is an unmade statement, not a claim that nothing covers
    /// it. Only a glob someone wrote can fail a run.
    func testFileMatchingNoGlobIsNotAGap() {
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["docs/architecture.md", "README.md"],
            ranCommands: [],
            map: map(webRule, apiRule)
        )
        XCTAssertTrue(verdict.isCovered)
    }

    /// Verify commands are routinely chained or prefixed with a `cd`; a rule
    /// naming `cargo check` is satisfied by all of those forms.
    func testCommandMatchesInsideAChainedVerify() {
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["apps/api/src/lib.rs"],
            ranCommands: ["cd repo && cargo check --workspace && npm test"],
            map: map(apiRule)
        )
        XCTAssertTrue(verdict.isCovered)
    }

    func testCommandMatchIgnoresWhitespaceShape() {
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["apps/api/src/lib.rs"],
            ranCommands: ["cargo   check\n  --workspace"],
            map: map(apiRule)
        )
        XCTAssertTrue(verdict.isCovered)
    }

    func testDifferentCommandDoesNotCount() {
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["apps/api/src/lib.rs"],
            ranCommands: ["cargo fmt --check"],
            map: map(apiRule)
        )
        XCTAssertFalse(verdict.isCovered)
    }

    /// An item that declares nothing can't cover anything — but only a mapped
    /// path makes that a failure.
    func testNoDeclaredCommandsFailsOnlyMappedPaths() {
        XCTAssertFalse(VerifyCoverage.evaluate(changedFiles: ["apps/api/src/lib.rs"],
                                               ranCommands: [], map: map(apiRule)).isCovered)
        XCTAssertTrue(VerifyCoverage.evaluate(changedFiles: ["notes.md"],
                                              ranCommands: [], map: map(apiRule)).isCovered)
    }

    // MARK: - Glob semantics

    func testDoubleStarSpansSegmentsAndNamesTheDirectoryItself() {
        XCTAssertTrue(VerifyCoverage.matches(glob: "apps/api/**", path: "apps/api/Cargo.toml"))
        XCTAssertTrue(VerifyCoverage.matches(glob: "apps/api/**", path: "apps/api/src/routes/x.rs"))
        XCTAssertTrue(VerifyCoverage.matches(glob: "**/*.rs", path: "apps/api/src/x.rs"))
        XCTAssertTrue(VerifyCoverage.matches(glob: "**/*.rs", path: "x.rs"))
    }

    func testSingleStarStaysWithinOneSegment() {
        XCTAssertTrue(VerifyCoverage.matches(glob: "apps/*/Cargo.toml", path: "apps/api/Cargo.toml"))
        XCTAssertFalse(VerifyCoverage.matches(glob: "apps/*/Cargo.toml", path: "apps/api/sub/Cargo.toml"))
        XCTAssertTrue(VerifyCoverage.matches(glob: "*.md", path: "README.md"))
        XCTAssertFalse(VerifyCoverage.matches(glob: "*.md", path: "docs/README.md"))
    }

    /// Anchored at both ends — a rule for `apps/api/**` must not pick up
    /// `vendor/apps/api/x`, and a `.rs` rule must not match `x.rs.bak`.
    func testGlobIsAnchored() {
        XCTAssertFalse(VerifyCoverage.matches(glob: "apps/api/**", path: "vendor/apps/api/x.rs"))
        XCTAssertFalse(VerifyCoverage.matches(glob: "**/*.rs", path: "apps/api/x.rs.bak"))
    }

    /// Dots are literal, not "any character" — `*.rs` is not a regex.
    func testGlobMetacharactersAreEscaped() {
        XCTAssertFalse(VerifyCoverage.matches(glob: "apps/api.rs", path: "apps/apiXrs"))
        XCTAssertTrue(VerifyCoverage.matches(glob: "apps/api.rs", path: "apps/api.rs"))
    }

    /// git prints repo-relative paths; a map or a caller may not.
    func testPathsAreNormalizedBeforeMatching() {
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["./apps/api/src/lib.rs"],
            ranCommands: [],
            map: map(apiRule)
        )
        XCTAssertEqual(verdict.gaps.first?.paths, ["apps/api/src/lib.rs"])
    }

    // MARK: - Loading the map

    private func writeMap(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "verify-map-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Where a project's map is read from

    private func makeProject() throws -> KiteloopProject {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appending(path: ".kiteloop"), withIntermediateDirectories: true)
        return KiteloopProject(rootURL: root)
    }

    private static let webMapJSON = """
        { "rules": [ { "glob": "apps/web/**", "command": "npm --prefix apps/web test" } ] }
        """

    func testAProjectWithAMapAtItsRootHasItsRulesApplied() throws {
        let project = try makeProject()
        try Self.webMapJSON.write(to: project.rootURL.appending(path: "kiteloop-verify.json"),
                                  atomically: true, encoding: .utf8)
        try #"{ "rules": [] }"#.write(to: project.legacyVerifyMapURL, atomically: true, encoding: .utf8)
        var logged: [String] = []

        let map = VerifyMapFile.load(for: project) { logged.append($0) }

        XCTAssertEqual(map.rules, [webRule], "the root file wins over the legacy copy")
        XCTAssertEqual(logged, [])
    }

    func testAProjectWithOnlyTheLegacyMapHasItsRulesAppliedAndSaysSoOnce() throws {
        let project = try makeProject()
        try Self.webMapJSON.write(to: project.legacyVerifyMapURL, atomically: true, encoding: .utf8)
        var logged: [String] = []

        let first = VerifyMapFile.load(for: project) { logged.append($0) }
        let (second, problem) = VerifyMapFile.loadReporting(for: project) { logged.append($0) }

        XCTAssertEqual(first.rules, [webRule])
        XCTAssertEqual(second.rules, [webRule])
        XCTAssertNil(problem)
        XCTAssertEqual(logged.count, 1, "\(logged)")
        XCTAssertTrue(logged.first?.contains(
            project.legacyVerifyMapURL.path(percentEncoded: false)) == true, "\(logged)")
    }

    func testAProjectWithNeitherMapHasNoMap() throws {
        let project = try makeProject()
        var logged: [String] = []

        let (map, problem) = VerifyMapFile.loadReporting(for: project) { logged.append($0) }

        XCTAssertTrue(map.isEmpty)
        XCTAssertNil(problem)
        XCTAssertEqual(logged, [])
    }

    func testLoadsRulesInOrder() throws {
        let url = try writeMap("""
        { "rules": [
            { "glob": "apps/web/**", "command": "npm --prefix apps/web test" },
            { "glob": "apps/api/**", "command": "cargo check --workspace" }
        ] }
        """)
        let map = VerifyCoverage.Map.load(from: url)
        XCTAssertEqual(map.rules, [webRule, apiRule])
    }

    func testMissingFileIsNoMapAndNoProblem() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        let (map, problem) = VerifyCoverage.Map.loadReporting(from: missing)
        XCTAssertTrue(map.isEmpty)
        XCTAssertNil(problem, "no map is the default state, not a misconfiguration")
        XCTAssertTrue(VerifyCoverage.Map.load(from: nil).isEmpty)
    }

    /// A typo in config must not block an otherwise finished run — but it has to
    /// be said out loud, or the gate silently stops checking.
    func testMalformedFileIsReportedAndNotEnforced() throws {
        let url = try writeMap("{ not json")
        let (map, problem) = VerifyCoverage.Map.loadReporting(from: url)
        XCTAssertTrue(map.isEmpty)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains(url.lastPathComponent) == true, problem ?? "")
    }

    /// A file that is there but can't be read — a directory in its place, a
    /// permission that was tightened, an I/O error — is not the same silence as
    /// a file nobody has written. It has to be said out loud too, in the same
    /// shape a malformed file is said in.
    func testUnreadableFileIsReportedAndNotEnforced() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "verify-map-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let (map, problem) = VerifyCoverage.Map.loadReporting(from: url)
        XCTAssertTrue(map.isEmpty)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains(url.lastPathComponent) == true, problem ?? "")
        XCTAssertTrue(problem?.hasSuffix("coverage not checked") == true, problem ?? "")
    }

    /// The gate's other silent failure: the map parsed, but git couldn't say
    /// what the run changed. `evaluate` reads an empty path list as covered, so
    /// nothing downstream would have shown the difference — the run has to say
    /// it, in the same shape a malformed map is said in, naming git and the
    /// branch nobody could diff.
    func testUnreadableDiffIsSaidInTheSameShapeAsAMalformedMap() {
        let said = VerifyCoverage.unreadableDiff(branch: "kiteloop/deleted")
        XCTAssertTrue(said.contains("kiteloop/deleted"), said)
        XCTAssertTrue(said.contains("git"), said)
        XCTAssertTrue(said.hasSuffix("coverage not checked"), said)

        // A diff that was genuinely empty is not this case and says nothing —
        // `evaluate` is what answers it, and it answers covered.
        XCTAssertTrue(VerifyCoverage.evaluate(changedFiles: [], ranCommands: [],
                                              map: map(apiRule)).isCovered)
    }

    /// A partly usable map still checks what survived — but the rules that were
    /// thrown away cover nothing, and nobody would know from the map file.
    func testBlankRulesAreDroppedAndReported() throws {
        let url = try writeMap("""
        { "rules": [
            { "glob": "  ", "command": "cargo check" },
            { "glob": "apps/api/**", "command": "" },
            { "glob": "apps/api/**", "command": "cargo check --workspace" }
        ] }
        """)
        let (map, problem) = VerifyCoverage.Map.loadReporting(from: url)
        XCTAssertEqual(map.rules, [apiRule])
        XCTAssertEqual(VerifyCoverage.Map.load(from: url).rules, [apiRule])
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains(url.lastPathComponent) == true, problem ?? "")
        XCTAssertTrue(problem?.contains("2 of its 3 rules") == true, problem ?? "")
        // The map is not empty, so coverage *is* still checked — this phrase
        // must not claim otherwise.
        XCTAssertFalse(problem?.contains("coverage not checked") == true, problem ?? "")
    }

    /// The failure this reporting exists for: a map that parses but checks
    /// nothing lets every run through exactly as no map does, and afterwards
    /// reads as coverage. An explicit empty list is the plainest way to write it.
    func testEmptyRuleListIsReported() throws {
        let url = try writeMap(#"{ "rules": [] }"#)
        let (map, problem) = VerifyCoverage.Map.loadReporting(from: url)
        XCTAssertTrue(map.isEmpty)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains(url.lastPathComponent) == true, problem ?? "")
        XCTAssertTrue(problem?.hasSuffix("coverage not checked") == true, problem ?? "")
    }

    /// The same silence, arrived at the other way: rules are there, and every one
    /// of them is dropped. The phrase says how many the file held, because that
    /// is what someone has to go and fix.
    func testMapWhoseEveryRuleIsBlankIsReported() throws {
        let url = try writeMap("""
        { "rules": [
            { "glob": "  ", "command": "cargo check" },
            { "glob": "apps/api/**", "command": "   " }
        ] }
        """)
        let (map, problem) = VerifyCoverage.Map.loadReporting(from: url)
        XCTAssertTrue(map.isEmpty)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains(url.lastPathComponent) == true, problem ?? "")
        XCTAssertTrue(problem?.contains("2 rules") == true, problem ?? "")
        XCTAssertTrue(problem?.hasSuffix("coverage not checked") == true, problem ?? "")
    }

    /// Reporting it must not start enforcing it: a map that checks nothing still
    /// lets every run through, as it always has.
    func testAMapThatChecksNothingStillFailsOpen() throws {
        let url = try writeMap(#"{ "rules": [{ "glob": "", "command": "" }] }"#)
        let map = VerifyCoverage.Map.load(from: url)
        XCTAssertTrue(VerifyCoverage.evaluate(changedFiles: ["apps/api/src/lib.rs"],
                                              ranCommands: [], map: map).isCovered)
    }

    /// A nil URL is the caller having no project root to look in — the same
    /// default state as a missing file, and just as much not a misconfiguration.
    func testNilURLIsNoMapAndNoProblem() {
        let (map, problem) = VerifyCoverage.Map.loadReporting(from: nil)
        XCTAssertTrue(map.isEmpty)
        XCTAssertNil(problem)
    }

    // MARK: - What the gate compares against

    // MARK: - The summary's counting

    /// Exactly `maxPathsInSummary` paths is the boundary: every one of them is
    /// named, and there is no "+0 more" — a count of nothing hidden is not a
    /// thing to say.
    func testSummaryAtTheTruncationBoundaryNamesEveryPathAndHidesNothing() {
        let files = (1...VerifyCoverage.maxPathsInSummary).map { "apps/api/src/f\($0).rs" }
        let verdict = VerifyCoverage.evaluate(changedFiles: files, ranCommands: [], map: map(apiRule))
        let summary = verdict.summary
        for file in files {
            XCTAssertTrue(summary.contains(file), summary)
        }
        XCTAssertFalse(summary.contains("more"), summary)
    }

    /// One file is "1 file"; anything else is "N files" — with N the number of
    /// files, not the number one.
    func testSummaryCountsTheFilesItNames() {
        let one = VerifyCoverage.evaluate(changedFiles: ["apps/api/src/lib.rs"],
                                          ranCommands: [], map: map(apiRule)).summary
        XCTAssertTrue(one.contains("(1 file: "), one)
        XCTAssertFalse(one.contains("files"), one)

        let three = VerifyCoverage.evaluate(
            changedFiles: ["apps/api/src/a.rs", "apps/api/src/b.rs", "apps/api/src/c.rs"],
            ranCommands: [], map: map(apiRule)
        ).summary
        XCTAssertTrue(three.contains("(3 files: "), three)
        XCTAssertFalse(three.contains("1 file"), three)
    }

    // MARK: - A rule that names no command

    /// `loadReporting` drops such rules, but `Map` is constructed directly too.
    /// A rule with nothing to run demands nothing: there is no command to add
    /// to the item's `verify:`, so it cannot be a gap — it counts as run even
    /// when the item declared nothing at all.
    func testARuleNamingNoCommandDemandsNothing() {
        XCTAssertTrue(VerifyCoverage.wasRun("", in: []))
        XCTAssertTrue(VerifyCoverage.wasRun(" \n\t", in: ["cargo check"]))

        let blank = VerifyCoverage.Rule(glob: "apps/api/**", command: "   ")
        let verdict = VerifyCoverage.evaluate(changedFiles: ["apps/api/src/lib.rs"],
                                              ranCommands: [], map: map(blank))
        XCTAssertTrue(verdict.isCovered, verdict.summary)
        XCTAssertEqual(verdict.covered, [blank])
    }

    // MARK: - Widening a verify the gap named

    private let buildRule = VerifyCoverage.Rule(
        glob: "Kiteloop/Kiteloop/**/*.swift",
        command: "xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop",
        run: "cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination \"platform=macOS\" build-for-testing")
    private let lintRule = VerifyCoverage.Rule(glob: "**/*.swift",
                                               command: "./quality/bin/check-complexity.sh")

    /// The gap reaches triage as the summary's prose and nothing more
    /// structured, so the commands are read back out of it — each once, in
    /// order, however many globs named the same one.
    func testTheCommandsAGapNamesAreReadBackOutOfItsSummary() {
        let summary = VerifyCoverage.evaluate(
            changedFiles: ["Kiteloop/Kiteloop/Services/A.swift", "Kiteloop/KiteloopTests/ATests.swift"],
            ranCommands: ["cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop build"],
            map: map(buildRule, lintRule, VerifyCoverage.Rule(glob: "**/*.swift", command: "./quality/bin/check-layering.py"))
        ).summary
        XCTAssertEqual(VerifyCoverage.commands(inGap: summary),
                       ["./quality/bin/check-complexity.sh", "./quality/bin/check-layering.py"])
        XCTAssertEqual(VerifyCoverage.commands(inGap: "verify failed with exit 1"), [])
    }

    /// The widened line runs the rule's `run` spelling, not the prefix a match
    /// needs — the prefix alone builds nothing — and re-roots at the repo top
    /// first, because the line it extends may have ended inside `Kiteloop/`.
    func testWideningAppendsTheRunnableSpellingRerootedAtTheTop() {
        let verify = "cd Kiteloop && swift build"
        let widened = VerifyCoverage.widen(
            verify: verify,
            adding: ["xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop", "./quality/bin/check-complexity.sh"],
            map: map(buildRule, lintRule))
        XCTAssertEqual(widened,
                       verify + " && cd \"$(git rev-parse --show-toplevel)\" && " + buildRule.run!
                       + " && cd \"$(git rev-parse --show-toplevel)\" && ./quality/bin/check-complexity.sh")
        XCTAssertTrue(VerifyCoverage.wasRun(buildRule.command, in: [widened!]))
    }

    /// Nil is "nothing to write": a verify that already runs the command gains
    /// no second copy, and an empty verify becomes just the commands.
    func testWideningAVerifyThatAlreadyRunsTheCommandIsNil() {
        XCTAssertNil(VerifyCoverage.widen(verify: "./quality/bin/check-complexity.sh --quiet",
                                          adding: ["./quality/bin/check-complexity.sh"], map: map(lintRule)))
        XCTAssertEqual(VerifyCoverage.widen(verify: nil, adding: ["./quality/bin/check-complexity.sh"],
                                            map: map(lintRule)),
                       "cd \"$(git rev-parse --show-toplevel)\" && ./quality/bin/check-complexity.sh")
    }

    /// A map written before `run` existed still decodes, and such a rule is
    /// added to a verify as written, from the root.
    func testARuleWithoutARunSpellingDecodesAndRunsItsCommandAsWritten() throws {
        let json = Data(#"{"rules":[{"glob":"**/*.sql","command":"cargo sqlx prepare --check"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(VerifyCoverage.Map.self, from: json)
        XCTAssertNil(decoded.rules.first?.run)
        XCTAssertEqual(decoded.rules.first?.runnable, "cargo sqlx prepare --check")
        XCTAssertEqual(VerifyCoverage.Rule(glob: "a", command: "b", run: "  ").runnable, "b")
    }
}
