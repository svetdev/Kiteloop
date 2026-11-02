import XCTest
@testable import KiteloopCore

/// A QA run's storyboard, copied out of the worktree the run is about to
/// remove, so the note on the item names a page that is still there.
final class QAStoryboardArchiveTests: XCTestCase {

    private func makeStoryboard(in worktree: URL, picture: Data) throws {
        let boards = worktree.appending(path: "e2e/boards", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: boards.appending(path: "today"), withIntermediateDirectories: true)
        try Data("# Today\n\n![1](today/1.png)\n".utf8).write(to: boards.appending(path: "today.md"))
        try picture.write(to: boards.appending(path: "today/1.png"))
    }

    func testThePageAndItsPicturesAreKeptByteForByte() throws {
        let worktree = try makeTemporaryDirectory()
        let home = try makeTemporaryDirectory()
        let picture = Data((0..<256).map { UInt8($0) })
        try makeStoryboard(in: worktree, picture: picture)
        let destination = QAStoryboardArchive.destination(home: home, itemID: "today", runID: "run-1")

        let kept = try XCTUnwrap(QAStoryboardArchive.keep(storyboard: "e2e/boards/today.md", worktree: worktree,
                                                          into: destination))

        XCTAssertEqual(kept.standardizedFileURL, destination.appending(path: "today.md").standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "# Today\n\n![1](today/1.png)\n")
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "today/1.png")), picture)
    }

    func testAMissingPageKeepsNothing() throws {
        let worktree = try makeTemporaryDirectory()
        let home = try makeTemporaryDirectory()
        let destination = QAStoryboardArchive.destination(home: home, itemID: "today", runID: "run-1")

        XCTAssertNil(QAStoryboardArchive.keep(storyboard: "e2e/boards/today.md", worktree: worktree, into: destination))
        XCTAssertNil(QAStoryboardArchive.keep(storyboard: "  ", worktree: worktree, into: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }

    func testTwoRunsOfOneItemAreKeptApart() throws {
        let home = try makeTemporaryDirectory()
        let first = try makeTemporaryDirectory()
        let second = try makeTemporaryDirectory()
        try makeStoryboard(in: first, picture: Data([1]))
        try makeStoryboard(in: second, picture: Data([2]))

        let one = QAStoryboardArchive.destination(home: home, itemID: "today", runID: "run-1")
        let two = QAStoryboardArchive.destination(home: home, itemID: "today", runID: "run-2")
        XCTAssertNotNil(QAStoryboardArchive.keep(storyboard: "e2e/boards/today.md", worktree: first, into: one))
        XCTAssertNotNil(QAStoryboardArchive.keep(storyboard: "e2e/boards/today.md", worktree: second, into: two))

        XCTAssertEqual(try Data(contentsOf: one.appending(path: "today/1.png")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: two.appending(path: "today/1.png")), Data([2]))
    }

    func testTheNoteNamesTheKeptCopyUnderTheStoryboardsFolder() throws {
        let worktree = try makeTemporaryDirectory()
        let home = try makeTemporaryDirectory()
        try makeStoryboard(in: worktree, picture: Data([1]))
        let kept = QAStoryboardArchive.keep(storyboard: "e2e/boards/today.md", worktree: worktree,
                                            into: QAStoryboardArchive.destination(home: home, itemID: "today",
                                                                                  runID: "run-1"))

        let note = try XCTUnwrap(QAFlowStages.note(report: "1. shown — pass",
                                                   storyboard: kept?.path(percentEncoded: false),
                                                   passed: true, found: kept != nil))
        XCTAssertTrue(note.hasPrefix("QA passed — storyboard: \(home.path(percentEncoded: false))"), note)
        XCTAssertTrue(note.contains("/.kiteloop/storyboards/today/run-1/today.md\n"), note)
    }

    func testANoteForAStoryboardNotKeptSaysSo() {
        let note = QAFlowStages.note(report: "1. shown — pass", storyboard: "e2e/boards/today.md",
                                     passed: true, found: false)
        XCTAssertEqual(note?.hasPrefix("QA passed — storyboard: e2e/boards/today.md (not found"), true)
    }
}
