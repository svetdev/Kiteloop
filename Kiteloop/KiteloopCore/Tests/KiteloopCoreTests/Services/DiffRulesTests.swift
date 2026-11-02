import XCTest
@testable import KiteloopCore

/// `DiffRules` — the two Definition-of-Done rules a diff answers by itself.
final class DiffRulesTests: XCTestCase {

    func testARowInTheSuiteRecordFromAnUnrelatedItemBlocks() {
        let findings = DiffRules.evaluate(
            changedFiles: ["Kiteloop/Kiteloop/Services/Foo.swift", "docs/suite-status.md", "CHANGELOG.md"],
            itemID: "kiteloop-042", itemTitle: "Grounding index reads the vault")
        XCTAssertEqual(findings.map(\.severity), [.blocking])
        XCTAssertTrue(findings[0].text.contains("docs/suite-status.md"))
        XCTAssertTrue(findings[0].text.contains("run-unit-suite.sh"))
    }

    func testAnItemAboutTheSuiteRecordMayTouchIt() {
        for title in ["suite-status: record the skipped names", "The suite record carries the duration",
                      "run-unit-suite reads the bundle"] {
            let findings = DiffRules.evaluate(
                changedFiles: ["scripts/run-unit-suite.sh", "docs/suite-status.md"],
                itemID: "kiteloop-007", itemTitle: title)
            XCTAssertEqual(findings, [], title)
        }
    }

    func testSwiftChangedWithoutAChangelogLineIsAdvisoryNotBlocking() {
        let findings = DiffRules.evaluate(
            changedFiles: ["Kiteloop/Kiteloop/Services/Foo.swift", "Kiteloop/KiteloopCore/Sources/KiteloopCore/Models/Bar.swift"],
            itemID: "kiteloop-042", itemTitle: "Foo reads Bar")
        XCTAssertEqual(findings.map(\.severity), [.advisory])
        XCTAssertTrue(findings[0].text.contains("2 Swift files"))
        XCTAssertTrue(findings[0].text.contains("CHANGELOG.md"))
    }

    func testSwiftChangedWithAChangelogLineIsClean() {
        XCTAssertEqual(DiffRules.evaluate(
            changedFiles: ["Kiteloop/Kiteloop/Services/Foo.swift", "CHANGELOG.md"],
            itemID: "kiteloop-042", itemTitle: "Foo"), [])
    }

    func testCompanionSwiftWithoutAChangelogLineIsAdvisory() {
        let findings = DiffRules.evaluate(
            changedFiles: ["KiteloopMobile/Sources/Services/Foo.swift"],
            itemID: "kiteloop-042", itemTitle: "Foo")
        XCTAssertEqual(findings.map(\.severity), [.advisory])
        XCTAssertTrue(findings[0].text.contains("1 Swift file"))
        XCTAssertTrue(findings[0].text.contains("CHANGELOG.md"))
    }

    func testCompanionSwiftWithAChangelogLineIsClean() {
        XCTAssertEqual(DiffRules.evaluate(
            changedFiles: ["KiteloopMobile/Sources/Services/Foo.swift", "CHANGELOG.md"],
            itemID: "kiteloop-042", itemTitle: "Foo"), [])
    }

    /// Tests, scripts and docs are not behaviour the changelog describes.
    func testTestsScriptsAndDocsAloneRaiseNothing() {
        XCTAssertEqual(DiffRules.evaluate(
            changedFiles: ["Kiteloop/KiteloopTests/Services/FooTests.swift",
                           "Kiteloop/KiteloopCore/Tests/KiteloopCoreTests/Services/BarTests.swift",
                           "quality/bin/check-layering.py", "docs/testing.md"],
            itemID: "kiteloop-042", itemTitle: "Foo"), [])
    }

    func testBothFindingsCanStandTogether() {
        let findings = DiffRules.evaluate(
            changedFiles: ["Kiteloop/Kiteloop/Services/Foo.swift", "docs/suite-status.md"],
            itemID: "kiteloop-042", itemTitle: "Foo")
        XCTAssertEqual(findings.map(\.severity), [.blocking, .advisory])
    }

    func testAnEmptyDiffRaisesNothing() {
        XCTAssertEqual(DiffRules.evaluate(changedFiles: [], itemID: "x", itemTitle: "x"), [])
    }

    func testEachRatchetBaselineYieldsAnAdvisoryFindingNamingIt() {
        for path in DiffRules.ratchetBaselinePaths {
            let findings = DiffRules.evaluate(changedFiles: [path], itemID: "kiteloop-042", itemTitle: "Foo")
            XCTAssertEqual(findings.map(\.severity), [.advisory], path)
            XCTAssertTrue(findings[0].text.contains(path), path)
        }
    }

    func testTwoRatchetBaselinesYieldOneFindingNamingBoth() {
        let findings = DiffRules.evaluate(
            changedFiles: ["Kiteloop/.swiftlint-baseline.json", "Kiteloop/.crap-baseline.json"],
            itemID: "kiteloop-042", itemTitle: "Foo")
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].severity, .advisory)
        XCTAssertTrue(findings[0].text.contains("Kiteloop/.swiftlint-baseline.json"))
        XCTAssertTrue(findings[0].text.contains("Kiteloop/.crap-baseline.json"))
    }

    func testNoRatchetBaselineRaisesNothing() {
        XCTAssertEqual(DiffRules.evaluate(
            changedFiles: ["Kiteloop/Kiteloop/Services/Foo.swift", "CHANGELOG.md"],
            itemID: "kiteloop-042", itemTitle: "Foo"), [])
    }

    // MARK: - secret-shaped strings

    /// Fake values in the documented shapes only — never a real credential —
    /// and each is what one finding must name by pattern, not repeat.
    private static let fakeSecretsByPattern: [(name: String, value: String)] = [
        ("an Anthropic API key", "sk-ant-FAKE0000000000000000000000"),
        ("an AWS access key id", "AKIAFAKEFAKEFAKEFAKE"),
        ("a GitHub token", "ghp_" + String(repeating: "0", count: 20)),
        ("a GitHub token", "github_pat_" + String(repeating: "0", count: 22)),
        ("a Slack token", "xoxb-" + String(repeating: "0", count: 12)),
        ("a private key block", "-----BEGIN RSA PRIVATE KEY-----"),
    ]

    /// A minimal unified diff adding one line to one file — enough for
    /// `DiffRules` to read a path and a new-file line number off it, the same
    /// shape `git diff` itself produces.
    private static func addingOneLineDiff(path: String, line: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        new file mode 100644
        index 0000000..1111111 100644
        --- /dev/null
        +++ b/\(path)
        @@ -0,0 +1 @@
        +\(line)
        """
    }

    /// A diff whose one hunk only *removes* `line` from an existing file —
    /// what a worker deleting a secret-shaped line produces.
    private static func removingOneLineDiff(path: String, line: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..0000000 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -1 +0,0 @@
        -\(line)
        """
    }

    func testEachSecretPatternBlocksNamingFileLineAndPatternWithoutTheValue() {
        for (name, value) in Self.fakeSecretsByPattern {
            let diff = Self.addingOneLineDiff(path: "fixture.txt", line: "token = \(value)")
            let findings = DiffRules.evaluate(
                changedFiles: ["fixture.txt"], itemID: "kiteloop-042", itemTitle: "Foo", diffText: diff)
            XCTAssertEqual(findings.map(\.severity), [.blocking], name)
            XCTAssertTrue(findings[0].text.contains("fixture.txt:1"), "\(name): \(findings[0].text)")
            XCTAssertTrue(findings[0].text.contains(name), "\(name): \(findings[0].text)")
            XCTAssertFalse(findings[0].text.contains(value), "\(name) leaked its value: \(findings[0].text)")
        }
    }

    func testADiffThatOnlyRemovesASecretShapedLineRaisesNothing() {
        let diff = Self.removingOneLineDiff(path: "fixture.txt", line: "token = sk-ant-FAKE0000000000000000000000")
        XCTAssertEqual(DiffRules.evaluate(
            changedFiles: ["fixture.txt"], itemID: "kiteloop-042", itemTitle: "Foo", diffText: diff), [])
    }

    /// The two existing rules read only `changedFiles`, `itemID` and
    /// `itemTitle` — passing a `diffText` alongside their fixtures must not
    /// change what they find.
    func testExistingRulesAreUnchangedWhenDiffTextIsAlsoGiven() {
        let diff = Self.addingOneLineDiff(path: "Kiteloop/Kiteloop/Services/Foo.swift", line: "let x = 1")
        let findings = DiffRules.evaluate(
            changedFiles: ["Kiteloop/Kiteloop/Services/Foo.swift", "docs/suite-status.md"],
            itemID: "kiteloop-042", itemTitle: "Foo", diffText: diff)
        XCTAssertEqual(findings.map(\.severity), [.blocking, .advisory])
    }

    func testAnEmptyDiffTextRaisesNoSecretFinding() {
        XCTAssertEqual(DiffRules.evaluate(
            changedFiles: [], itemID: "x", itemTitle: "x", diffText: ""), [])
    }
}
