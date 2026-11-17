import XCTest
@testable import KiteloopCore
import KiteloopTestSupport

/// The rules for the one more pass a cut-short worker gets, and the tree mark
/// its progress is measured by — the mark against a real repository.
final class CutShortContinuationTests: XCTestCase {

    // MARK: - Whether a continuation follows

    func testACutShortFirstPassThatLeftWorkIsContinued() {
        XCTAssertTrue(CutShortContinuation.isDue(cutShortTurns: 51, hasWork: true, alreadyContinued: false))
    }

    func testAPassThatWasNotCutShortIsNotContinued() {
        XCTAssertFalse(CutShortContinuation.isDue(cutShortTurns: nil, hasWork: true, alreadyContinued: false))
    }

    func testACutShortPassThatLeftNoWorkIsNotContinued() {
        XCTAssertFalse(CutShortContinuation.isDue(cutShortTurns: 51, hasWork: false, alreadyContinued: false))
    }

    func testAnItemIsContinuedOnlyOnce() {
        XCTAssertFalse(CutShortContinuation.isDue(cutShortTurns: 51, hasWork: true, alreadyContinued: true))
    }

    // MARK: - What a continuation blocks on

    private func mark(_ diff: String) -> CutShortContinuation.TreeMark {
        .init(head: "abc", diff: diff, untracked: [])
    }

    func testAContinuationThatChangedTheTreeDoesNotBlock() {
        XCTAssertNil(CutShortContinuation.blockingTurns(
            firstPassTurns: 51, continuationTurns: nil, before: mark("one"), after: mark("two")))
    }

    func testAContinuationCutShortAgainBlocksOnItsOwnBudget() {
        XCTAssertEqual(CutShortContinuation.blockingTurns(
            firstPassTurns: 51, continuationTurns: 40, before: mark("one"), after: mark("two")), 40)
    }

    func testAContinuationThatLeftTheTreeUnchangedBlocksOnTheFirstPassBudget() {
        XCTAssertEqual(CutShortContinuation.blockingTurns(
            firstPassTurns: 51, continuationTurns: nil, before: mark("one"), after: mark("one")), 51)
    }

    func testATreeNobodyCouldReadIsNotProgress() {
        XCTAssertEqual(CutShortContinuation.blockingTurns(
            firstPassTurns: 51, continuationTurns: nil, before: nil, after: mark("one")), 51)
        XCTAssertEqual(CutShortContinuation.blockingTurns(
            firstPassTurns: 51, continuationTurns: nil, before: mark("one"), after: nil), 51)
    }

    // MARK: - The tree mark

    private func git(_ arguments: [String], in directory: URL) throws {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/usr/bin/git",
            arguments: ["-C", directory.path(percentEncoded: false),
                        "-c", "user.name=Test", "-c", "user.email=test@example.invalid"] + arguments,
            timeout: 60)
        XCTAssertEqual(result.status, 0, "git \(arguments.joined(separator: " ")): \(result.output)")
    }

    private func repository() throws -> URL {
        let url = try makeTemporaryDirectory(prefix: "cut-short")
        try git(["init", "-q", "-b", "main"], in: url)
        try "one\n".write(to: url.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-A"], in: url)
        try git(["commit", "-q", "-m", "start"], in: url)
        return url
    }

    func testAnUntouchedTreeReadsTheSameTwice() throws {
        let tree = try repository()
        try "half\n".write(to: tree.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        let before = try XCTUnwrap(CutShortContinuation.treeMark(worktree: tree))
        XCTAssertEqual(CutShortContinuation.treeMark(worktree: tree), before)
        XCTAssertEqual(before.untracked.count, 1)
    }

    func testAnEditToATrackedFileChangesTheMark() throws {
        let tree = try repository()
        let before = try XCTUnwrap(CutShortContinuation.treeMark(worktree: tree))
        try "two\n".write(to: tree.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(CutShortContinuation.treeMark(worktree: tree), before)
    }

    func testANewUntrackedFileChangesTheMark() throws {
        let tree = try repository()
        let before = try XCTUnwrap(CutShortContinuation.treeMark(worktree: tree))
        try "new\n".write(to: tree.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(CutShortContinuation.treeMark(worktree: tree), before)
    }

    func testGrowingAnUntrackedFileChangesTheMark() throws {
        let tree = try repository()
        try "half\n".write(to: tree.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        let before = try XCTUnwrap(CutShortContinuation.treeMark(worktree: tree))
        try "half\nand the rest\n".write(to: tree.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(CutShortContinuation.treeMark(worktree: tree), before)
    }

    func testACommitChangesTheMark() throws {
        let tree = try repository()
        try "two\n".write(to: tree.appending(path: "tracked.txt"), atomically: true, encoding: .utf8)
        let before = try XCTUnwrap(CutShortContinuation.treeMark(worktree: tree))
        try git(["commit", "-q", "-am", "more"], in: tree)
        let after = try XCTUnwrap(CutShortContinuation.treeMark(worktree: tree))
        XCTAssertNotEqual(after.head, before.head)
    }

    func testADirectoryThatIsNotARepositoryHasNoMark() throws {
        let directory = try makeTemporaryDirectory(prefix: "cut-short-plain")
        XCTAssertNil(CutShortContinuation.treeMark(worktree: directory))
    }

    func testAGitThatCannotAnswerLeavesNoMark() async {
        let runner = ScriptedSubprocessRunner { call in
            .init(status: call.arguments.contains("diff") ? 128 : 0, output: "abc\n")
        }
        let mark = await withScriptedSubprocesses(runner) {
            CutShortContinuation.treeMark(worktree: URL(fileURLWithPath: "/nowhere"))
        }
        XCTAssertNil(mark)
        XCTAssertEqual(runner.calls.count, 3)
    }
}
