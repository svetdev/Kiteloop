import XCTest
@testable import KiteloopCore

/// The rule the travel incident of 2026-08-10 cost: a project's merge-verify
/// command is an **addition** to the item's own `verify:`, never a substitute
/// for it.
final class MergeVerifyPlanTests: XCTestCase {

    // MARK: - What runs

    /// The defect itself. A web-only project command and a Rust item verify used
    /// to resolve to the web command alone, so a Rust diff merged on a suite
    /// that never compiles it.
    func testBothCommandsRunWhenBothAreConfigured() {
        let plan = MergeVerifyPlan.resolve(projectCommand: "npm --prefix apps/web test",
                                           itemVerify: "./scripts/ci.sh")

        XCTAssertEqual(plan.commands, ["./scripts/ci.sh", "npm --prefix apps/web test"],
                       "the item's own verify must run, and must run first")
        XCTAssertEqual(plan.steps.map(\.source), [.item, .project])
    }

    /// `gate.py` for the work and `gate.py --strict` at the gate: the same
    /// tool, one flag apart, opposite verdicts — the plan names the drift.
    func testAProjectCommandThatIsTheItemVerifyPlusFlagsIsNamedAsDrift() {
        let plan = MergeVerifyPlan.resolve(projectCommand: "python3 quality/bin/gate.py --strict",
                                           itemVerify: "python3  quality/bin/gate.py")

        XCTAssertEqual(plan.commands.count, 2, "the stricter bar still runs")
        XCTAssertEqual(plan.flagDriftWarning,
                       "merge-verify is the item's verify with extra flags (--strict) — the work was built and "
                       + "judged against the weaker bar, so a refusal here is the project's gate, not the item")
    }

    func testUnrelatedCommandsAreNotDrift() {
        XCTAssertNil(MergeVerifyPlan.resolve(projectCommand: "npm test", itemVerify: "swift build").flagDriftWarning)
        XCTAssertNil(MergeVerifyPlan.resolve(projectCommand: "swift build", itemVerify: "swift build").flagDriftWarning)
        XCTAssertNil(MergeVerifyPlan.resolve(projectCommand: "swift build", itemVerify: nil).flagDriftWarning)
        XCTAssertNil(MergeVerifyPlan.resolve(projectCommand: "swift builder", itemVerify: "swift build").flagDriftWarning,
                     "a longer command is not the same command with flags")
    }

    func testOnlyTheProjectCommandIsUnchangedFromBefore() {
        let plan = MergeVerifyPlan.resolve(projectCommand: "swift build", itemVerify: nil)

        XCTAssertEqual(plan.commands, ["swift build"])
        XCTAssertEqual(plan.steps.first?.source, .project)
    }

    func testOnlyTheItemVerifyIsUnchangedFromBefore() {
        let plan = MergeVerifyPlan.resolve(projectCommand: nil, itemVerify: "swift build")

        XCTAssertEqual(plan.commands, ["swift build"])
        XCTAssertEqual(plan.steps.first?.source, .item)
    }

    /// A merge nothing checked. Allowed — the setting is optional and items need
    /// not carry a verify — but it has to be visibly that, not an empty success.
    func testNeitherConfiguredIsAnEmptyPlanThatSaysSo() {
        XCTAssertTrue(MergeVerifyPlan.resolve(projectCommand: nil, itemVerify: nil).isEmpty)
        XCTAssertEqual(MergeVerifyPlan.resolve(projectCommand: nil, itemVerify: nil).summary, "none")
    }

    /// Blank is not a command. A configured-then-cleared field arrives as `""`
    /// and used to win the `??` on truthiness alone.
    func testBlankCommandsAreDropped() {
        let plan = MergeVerifyPlan.resolve(projectCommand: "   \n ", itemVerify: "swift build")

        XCTAssertEqual(plan.commands, ["swift build"])
    }

    /// Running the same command twice is a slower gate, not a stronger one.
    func testTheSameCommandOnBothSidesRunsOnce() {
        let plan = MergeVerifyPlan.resolve(projectCommand: "swift  build", itemVerify: "swift build")

        XCTAssertEqual(plan.commands, ["swift build"])
        XCTAssertEqual(plan.steps.first?.source, .item,
                       "the item's is the one that must survive the deduplication")
    }

    /// Deduplication used to compare the *labels*, which are truncated, so two
    /// long commands agreeing on their first `maxLabelCommandLength` characters
    /// — two CI invocations differing in a trailing flag is the realistic shape
    /// — resolved to one step and the project's never ran. Sameness is decided
    /// on the whole command; only the label is bounded.
    func testTwoLongCommandsSharingAPrefixBothRun() {
        let shared = String(repeating: "x", count: MergeVerifyPlan.maxLabelCommandLength)
        let itemCommand = shared + " --workspace"
        let projectCommand = shared + " --release"

        let plan = MergeVerifyPlan.resolve(projectCommand: projectCommand, itemVerify: itemCommand)

        XCTAssertEqual(plan.commands, [itemCommand, projectCommand],
                       "commands differing only past the label's truncation are not duplicates")
        XCTAssertEqual(plan.steps.map(\.source), [.item, .project])
    }

    // MARK: - Read off the verify map

    private static let catchAll = MergeVerifyPlan.catchAll("./scripts/ci.sh")
    private static let mapRules = [
        catchAll,
        VerifyCoverage.Rule(glob: "Kiteloop/Kiteloop/**/*.swift", command: "xcodebuild -scheme Kiteloop",
                            run: "cd Kiteloop && xcodebuild -scheme Kiteloop build-for-testing"),
        VerifyCoverage.Rule(glob: "Kiteloop/Kiteloop.xcodeproj/**", command: "xcodebuild -scheme Kiteloop",
                            run: "cd Kiteloop && xcodebuild -scheme Kiteloop build-for-testing"),
        VerifyCoverage.Rule(glob: "**/*.swift", command: "./quality/bin/check-complexity.sh"),
        VerifyCoverage.Rule(glob: "**/*.swift", command: "./quality/bin/check-complexity.sh"),
        VerifyCoverage.Rule(glob: "docs/features.md", command: "./quality/bin/check-features-map.py"),
    ]

    func testADocsOnlyDiffRunsTheCatchAllAndTheItemChecksButNoSwiftRule() {
        let plan = MergeVerifyPlan.resolve(rules: Self.mapRules, paths: ["docs/testing.md", "README.md"],
                                           itemVerify: "./scripts/item-check.sh")

        XCTAssertEqual(plan.commands, ["./scripts/item-check.sh", "./scripts/ci.sh"])
        XCTAssertEqual(plan.steps.map(\.source), [.item, .project])
    }

    func testASwiftDiffRunsTheSwiftRulesTheCatchAllAndTheItemChecksEachOnce() {
        let plan = MergeVerifyPlan.resolve(
            rules: Self.mapRules,
            paths: ["Kiteloop/Kiteloop/Services/Foo.swift", "Kiteloop/Kiteloop.xcodeproj/project.pbxproj"],
            itemVerify: "./scripts/item-check.sh")

        XCTAssertEqual(plan.commands, [
            "./scripts/item-check.sh",
            "./scripts/ci.sh",
            "cd Kiteloop && xcodebuild -scheme Kiteloop build-for-testing",
            "./quality/bin/check-complexity.sh",
        ], "the rule's runnable spelling runs, and a command two rules name runs once")
    }

    func testAnItemCheckARuleAlsoNamesRunsOnceAsTheItems() {
        let plan = MergeVerifyPlan.resolve(rules: Self.mapRules, paths: ["Kiteloop/Kiteloop/A.swift"],
                                           itemVerify: "./quality/bin/check-complexity.sh")

        XCTAssertEqual(plan.commands.filter { $0 == "./quality/bin/check-complexity.sh" }.count, 1)
        XCTAssertEqual(plan.steps.first?.source, .item)
    }

    /// A gate that cannot tell what changed must not run less.
    func testAnUnreadableDiffRunsEveryRule() {
        let plan = MergeVerifyPlan.resolve(rules: Self.mapRules, paths: nil, itemVerify: nil)

        XCTAssertEqual(plan.commands, ["./scripts/ci.sh", "cd Kiteloop && xcodebuild -scheme Kiteloop build-for-testing",
                                       "./quality/bin/check-complexity.sh", "./quality/bin/check-features-map.py"])
    }

    /// No map: the derived command, as the one catch-all rule, runs on any diff
    /// exactly as the project command did.
    func testAProjectWithNoMapRunsTheDerivedCommandItRunsToday() {
        let derived = "cd Kiteloop && xcodebuild -project Kiteloop.xcodeproj build-for-testing"
        let today = MergeVerifyPlan.resolve(projectCommand: derived, itemVerify: "swift build")

        for paths in [["docs/a.md"], ["Sources/A.swift"]] {
            let plan = MergeVerifyPlan.resolve(rules: [MergeVerifyPlan.catchAll(derived)], paths: paths,
                                               itemVerify: "swift build")
            XCTAssertEqual(plan, today, "paths \(paths)")
            XCTAssertEqual(plan.commands, ["swift build", derived])
        }
    }

    // MARK: - Naming what gated the merge

    func testLabelsNameTheSourceAndTheCommand() {
        let plan = MergeVerifyPlan.resolve(projectCommand: "npm test", itemVerify: "cargo test")

        XCTAssertEqual(plan.labels, ["item verify: cargo test", "merge-verify: npm test"])
        XCTAssertEqual(plan.summary, "item verify: cargo test + merge-verify: npm test")
    }

    /// A verify written across several lines is one command, and a log line is
    /// one line.
    func testALabelCollapsesAMultiLineCommand() {
        let plan = MergeVerifyPlan.resolve(projectCommand: nil, itemVerify: "cargo test \\\n  --workspace")

        XCTAssertEqual(plan.labels, ["item verify: cargo test \\ --workspace"])
    }

    func testALongCommandIsTruncatedInItsLabelButNotInWhatRuns() {
        let long = String(repeating: "x", count: MergeVerifyPlan.maxLabelCommandLength + 50)
        let plan = MergeVerifyPlan.resolve(projectCommand: nil, itemVerify: long)

        XCTAssertEqual(plan.commands, [long], "what runs is never truncated")
        XCTAssertTrue(plan.labels[0].hasSuffix("…"))
        XCTAssertLessThan(plan.labels[0].count, long.count)
    }

    /// The bound is inclusive: a command that is exactly `maxLabelCommandLength`
    /// characters fits, and is carried whole. An ellipsis on it would say part
    /// of the command was left out when nothing was — the label would be
    /// *longer* than the command it claims to shorten.
    func testACommandExactlyAtTheLabelBoundIsNotTruncated() {
        let atBound = String(repeating: "x", count: MergeVerifyPlan.maxLabelCommandLength)

        XCTAssertEqual(MergeVerifyPlan.condense(atBound), atBound)
        XCTAssertFalse(MergeVerifyPlan.condense(atBound).hasSuffix("…"))
    }

    func testACommandOnePastTheLabelBoundIsTruncated() {
        let overBound = String(repeating: "x", count: MergeVerifyPlan.maxLabelCommandLength + 1)

        let label = MergeVerifyPlan.condense(overBound)
        XCTAssertTrue(label.hasSuffix("…"))
        XCTAssertEqual(label.count, MergeVerifyPlan.maxLabelCommandLength + 1,
                       "the bound's worth of the command, then the ellipsis")
    }
}
