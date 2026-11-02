import XCTest
@testable import KiteloopCore

/// `ReviewerDiffFacts` — the per-file block handed to the reviewer alongside
/// its verdict, and the two facts (test file changed, changelog changed) a
/// large diff's absences would otherwise leave to inference.
final class ReviewerDiffFactsTests: XCTestCase {

    // MARK: - isTestFile

    func testPathsUnderATestTargetAreTestFiles() {
        XCTAssertTrue(ReviewerDiffFacts.isTestFile("Kiteloop/KiteloopTests/Services/FooTests.swift"))
        XCTAssertTrue(ReviewerDiffFacts.isTestFile("Kiteloop/KiteloopCore/Tests/KiteloopCoreTests/Services/BarTests.swift"))
        XCTAssertTrue(ReviewerDiffFacts.isTestFile("Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/BazTests.swift"))
    }

    func testAnOrdinarySourceFileIsNotATestFile() {
        XCTAssertFalse(ReviewerDiffFacts.isTestFile("Kiteloop/Kiteloop/Services/BacklogAutopilot.swift"))
        XCTAssertFalse(ReviewerDiffFacts.isTestFile("Kiteloop/KiteloopCore/Sources/KiteloopCore/Services/DiffRules.swift"))
    }

    // MARK: - parseNumstat

    func testParsesAddedAndDeletedCountsPerFile() {
        let raw = "317\t12\tKiteloop/Kiteloop/Services/BacklogAutopilot.swift\n565\t0\tKiteloop/Kiteloop/Services/NewService.swift"
        let files = ReviewerDiffFacts.parseNumstat(raw)
        XCTAssertEqual(files, [
            .init(path: "Kiteloop/Kiteloop/Services/BacklogAutopilot.swift", added: 317, deleted: 12),
            .init(path: "Kiteloop/Kiteloop/Services/NewService.swift", added: 565, deleted: 0),
        ])
    }

    func testABinaryFileNumstatCountsParseAsNilNotZero() {
        let files = ReviewerDiffFacts.parseNumstat("-\t-\tKiteloop/Assets.xcassets/Icon.png")
        XCTAssertEqual(files, [.init(path: "Kiteloop/Assets.xcassets/Icon.png", added: nil, deleted: nil)])
    }

    func testAMalformedLineIsSkippedRatherThanGuessedAt() {
        XCTAssertEqual(ReviewerDiffFacts.parseNumstat("not a numstat line\n\n10\t2\tFoo.swift"),
                       [.init(path: "Foo.swift", added: 10, deleted: 2)])
    }

    /// Every file in the block is uncommitted by construction — it is read
    /// against HEAD — and the block says so, with the count, so a reviewer
    /// cannot mistake a tree the worker never committed for one it did.
    func testTheBlockSaysHowManyFilesTheWorkerLeftUncommitted() throws {
        let block = try XCTUnwrap(ReviewerDiffFacts.block(changedFiles: [
            .init(path: "Services/A.swift", added: 3, deleted: 1),
            .init(path: "Services/B.swift", added: 0, deleted: 2),
        ]))
        XCTAssertTrue(block.contains("Uncommitted at handoff: 2 file(s)"), block)
        XCTAssertTrue(block.hasSuffix("teardown will"), block)
    }

    func testEmptyInputParsesToNoFiles() {
        XCTAssertEqual(ReviewerDiffFacts.parseNumstat(""), [])
    }

    // MARK: - newFileLineCount

    func testANewFileEndingInANewlineCountsItsLinesAsNumstatDoes() {
        XCTAssertEqual(ReviewerDiffFacts.newFileLineCount(Data("a\nb\n".utf8)), 2)
    }

    func testANewFileWithoutATrailingNewlineCountsItsLastLine() {
        XCTAssertEqual(ReviewerDiffFacts.newFileLineCount(Data("a\nb".utf8)), 2)
    }

    func testAnEmptyNewFileCountsZeroLines() {
        XCTAssertEqual(ReviewerDiffFacts.newFileLineCount(Data()), 0)
    }

    func testOneInvalidUTF8ByteInATextFileStillCountsItsLines() {
        let data = Data("one\n".utf8) + Data([0x74, 0xFF, 0x77, 0x0A]) + Data("three\n".utf8)
        XCTAssertEqual(ReviewerDiffFacts.newFileLineCount(data), 3)
    }

    func testANulByteCountsAsBinaryAndRendersAsNumstatsPlaceholder() throws {
        let added = ReviewerDiffFacts.newFileLineCount(Data([0x61, 0x00, 0x0A]))
        XCTAssertNil(added)
        let block = try XCTUnwrap(ReviewerDiffFacts.block(changedFiles: [.init(path: "New.bin", added: added, deleted: 0)]))
        XCTAssertTrue(block.contains("- New.bin (+-/-0)"), block)
    }

    // MARK: - block

    func testNoChangedFilesProducesNoBlock() {
        XCTAssertNil(ReviewerDiffFacts.block(changedFiles: []))
    }

    func testBlockListsEveryFileWithItsCounts() {
        let block = ReviewerDiffFacts.block(changedFiles: [
            .init(path: "Kiteloop/Kiteloop/Services/BacklogAutopilot.swift", added: 317, deleted: 12),
            .init(path: "Kiteloop/Kiteloop/Services/NewService.swift", added: 565, deleted: 0),
        ])
        XCTAssertEqual(block, """
            ## Changed files
            - Kiteloop/Kiteloop/Services/BacklogAutopilot.swift (+317/-12)
            - Kiteloop/Kiteloop/Services/NewService.swift (+565/-0)

            Test files changed: no
            CHANGELOG.md changed: no
            Uncommitted at handoff: 2 file(s) — the worker did not commit; teardown will
            """)
    }

    /// The exact shape `pr-comments-resolved` shipped: 877 lines across two
    /// source files, no test file, no changelog line — the diff the item
    /// describes the reviewer having passed without being told either fact.
    func testTheShapeThatShippedPastTheReviewerReportsBothAbsences() {
        let files = [
            ReviewerDiffFacts.ChangedFile(path: "Kiteloop/Kiteloop/Services/BacklogAutopilot.swift", added: 317, deleted: 0),
            ReviewerDiffFacts.ChangedFile(path: "Kiteloop/Kiteloop/Services/NewReviewService.swift", added: 565, deleted: 0),
        ]
        let block = ReviewerDiffFacts.block(changedFiles: files)
        XCTAssertTrue(block?.contains("Test files changed: no") ?? false)
        XCTAssertTrue(block?.contains("CHANGELOG.md changed: no") ?? false)
    }

    func testATestFileAmongTheChangesReportsYes() {
        let files = [
            ReviewerDiffFacts.ChangedFile(path: "Kiteloop/Kiteloop/Services/Foo.swift", added: 10, deleted: 1),
            ReviewerDiffFacts.ChangedFile(path: "Kiteloop/KiteloopTests/Services/FooTests.swift", added: 40, deleted: 0),
        ]
        XCTAssertTrue(ReviewerDiffFacts.block(changedFiles: files)?.contains("Test files changed: yes") ?? false)
    }

    func testChangelogAmongTheChangesReportsYes() {
        let files = [
            ReviewerDiffFacts.ChangedFile(path: "Kiteloop/Kiteloop/Services/Foo.swift", added: 10, deleted: 1),
            ReviewerDiffFacts.ChangedFile(path: DiffRules.changelogPath, added: 2, deleted: 0),
        ]
        XCTAssertTrue(ReviewerDiffFacts.block(changedFiles: files)?.contains("CHANGELOG.md changed: yes") ?? false)
    }

    /// A documentation-only diff — no Swift changed at all — reports the same
    /// two "no"s, which is the correct answer for it, not a defect: this type
    /// never turns either fact into a verdict.
    func testADocumentationOnlyDiffReportsTheSameAbsencesWithoutJudging() {
        let files = [ReviewerDiffFacts.ChangedFile(path: "docs/testing.md", added: 8, deleted: 1)]
        let block = ReviewerDiffFacts.block(changedFiles: files)
        XCTAssertTrue(block?.contains("Test files changed: no") ?? false)
        XCTAssertTrue(block?.contains("CHANGELOG.md changed: no") ?? false)
    }

    /// The two statements are read off the full file list handed to `block`,
    /// never off however much of a diff's body a reader got through — so a
    /// caller that built this list from `--numstat` (bounded by file count,
    /// not by how many lines were truncated before reaching a reader) gets a
    /// correct answer regardless of what a diff's body would have shown.
    func testStatementsHoldEvenWhenOnlyTheStatWasEverRead() {
        let manyFiles = (1...500).map { ReviewerDiffFacts.ChangedFile(path: "Kiteloop/Kiteloop/Services/File\($0).swift", added: 4, deleted: 0) }
        let files = manyFiles + [ReviewerDiffFacts.ChangedFile(path: "Kiteloop/KiteloopTests/Services/LastTests.swift", added: 4, deleted: 0)]
        let block = ReviewerDiffFacts.block(changedFiles: files)
        XCTAssertTrue(block?.contains("Test files changed: yes") ?? false)
        XCTAssertTrue(block?.contains("Kiteloop/KiteloopTests/Services/LastTests.swift") ?? false)
    }
}
