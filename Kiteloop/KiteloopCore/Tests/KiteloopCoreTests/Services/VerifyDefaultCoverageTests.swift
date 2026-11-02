import XCTest
@testable import KiteloopCore

/// `.kiteloop/verify-map.json` applies `check-complexity.sh` and
/// `check-layering.py` to `**/*.swift` unconditionally — any changed Swift
/// file matches, wherever it lives. `verify_default` in
/// `.kiteloop/backlog-tree/BACKLOG.md` has to run both, or every item that
/// inherits it and touches Swift is guaranteed a `VerifyCoverage` gap before
/// the worker even starts.
///
/// Both files are this project's own runtime state — `.gitignore`s
/// `.kiteloop/` — so they exist on a developer's live checkout but not in a
/// throwaway worktree or on CI. `testRepoVerifyDefaultCoversEveryUnconditionalMapRule`
/// reads them for real and skips where they are absent, the same way
/// `GroundingCheckTests.testThisCheckoutsOwnWorkflowActionsGround` reads this
/// checkout's own `.github/workflows/ci.yml`. The other two tests pin the
/// relationship with a map that mirrors today's real rules, so they run
/// (and would catch a regression) everywhere.
@MainActor
final class VerifyDefaultCoverageTests: XCTestCase {

    // MARK: - Deterministic: a map shaped like the real one

    private static let complexityRule = VerifyCoverage.Rule(
        glob: "**/*.swift", command: "./quality/bin/check-complexity.sh")
    private static let layeringRule = VerifyCoverage.Rule(
        glob: "**/*.swift", command: "./quality/bin/check-layering.py")
    private static let hygieneRule = VerifyCoverage.Rule(
        glob: "Kiteloop/KiteloopTests/**", command: "./quality/bin/check-test-hygiene.py")

    /// The corrected `verify_default` — what `.kiteloop/backlog-tree/BACKLOG.md`
    /// carries once it names the two unconditional rules above.
    private static let repoVerifyDefault =
        "xcodebuild -project Kiteloop.xcodeproj -scheme Kiteloop -destination \"platform=macOS\" build"
            + " && cd \"$(git rev-parse --show-toplevel)\""
            + " && ./quality/bin/check-complexity.sh --quiet"
            + " && ./quality/bin/check-layering.py --quiet"

    func testRepoLikeDefaultCoversBothUnconditionalSwiftRules() {
        let map = VerifyCoverage.Map(rules: [Self.complexityRule, Self.layeringRule, Self.hygieneRule])
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/Example.swift"],
            ranCommands: [Self.repoVerifyDefault],
            map: map)
        XCTAssertTrue(verdict.isCovered, verdict.summary)
        XCTAssertEqual(Set(verdict.covered.map(\.command)),
                        [Self.complexityRule.command, Self.layeringRule.command])
    }

    /// The conditional rule stays out: a diff that never touches a test tree
    /// still gaps on it, so widening it into the default was never asked for.
    func testConditionalHygieneRuleIsNotSatisfiedByTheDefaultAlone() {
        let map = VerifyCoverage.Map(rules: [Self.hygieneRule])
        let verdict = VerifyCoverage.evaluate(
            changedFiles: ["Kiteloop/KiteloopTests/Services/ExampleTests.swift"],
            ranCommands: [Self.repoVerifyDefault],
            map: map)
        XCTAssertFalse(verdict.isCovered)
        XCTAssertEqual(verdict.gaps.first?.command, Self.hygieneRule.command)
    }

    // MARK: - Live: the relationship, against the repo's real files

    /// It must fail if a new unconditional rule is added to
    /// `.kiteloop/verify-map.json` without widening `verify_default` to run
    /// it — the regression this item exists to stop happening twice.
    func testRepoVerifyDefaultCoversEveryUnconditionalMapRule() throws {
        let root = RepositoryRoot.of()
        let project = KiteloopProject(rootURL: root)
        let backlogURL = BacklogBranch.backlogFileURL(projectRoot: root)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: VerifyMapFile.url(for: project).path(percentEncoded: false))
                && FileManager.default.fileExists(atPath: backlogURL.path(percentEncoded: false)),
            "no .kiteloop runtime state to read at \(root.path(percentEncoded: false)) — "
                + "absent in a throwaway worktree and on CI, present on a developer's own checkout")

        let map = VerifyMapFile.load(for: project)
        let content = try String(contentsOf: backlogURL, encoding: .utf8)
        let verifyDefault = BacklogParser.parse(content).verifyDefault ?? ""

        let unconditional = map.rules.filter(VerifyCoverage.isUnconditional)
        for rule in unconditional {
            XCTAssertTrue(
                VerifyCoverage.wasRun(rule.command, in: [verifyDefault]),
                "verify_default does not run `\(rule.command)`, which \(rule.glob) applies to any path")
        }
    }
}
