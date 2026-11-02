import XCTest
@testable import KiteloopCore

/// Seeding `.kiteloop/` into a project must leave the repo's `git status` clean:
/// `worktrees/` holds full checked-out git worktrees, `web/` holds built assets and
/// `backlog-tree/` is the shared backlog branch's private checkout, so all three have
/// to be ignored even in projects that deliberately track other parts of `.kiteloop/`
/// (team config, backlog). These tests pin the pattern matching and the on-disk
/// behaviour of `ensureDirectoryExists()`.
final class KiteloopProjectGitignoreTests: XCTestCase {

    // MARK: - Projects with no Kiteloop entries

    func testEmptyGitignoreGetsBlanketEntry() {
        XCTAssertEqual(KiteloopProject.gitignoreAddition(for: ""), ".kiteloop/\n")
    }

    func testUnrelatedGitignoreGetsBlanketEntry() {
        let contents = "node_modules/\n.DS_Store\n"
        XCTAssertEqual(KiteloopProject.gitignoreAddition(for: contents), ".kiteloop/\n")
    }

    func testCommentedOutEntryDoesNotCount() {
        // A `#`-prefixed line is documentation, not a rule.
        let contents = "# .kiteloop/\n"
        XCTAssertEqual(KiteloopProject.gitignoreAddition(for: contents), ".kiteloop/\n")
    }

    // MARK: - Projects already ignoring all of .kiteloop/

    func testBlanketEntryNeedsNothing() {
        XCTAssertNil(KiteloopProject.gitignoreAddition(for: ".kiteloop/\n"))
    }

    func testBlanketEntryWithoutTrailingSlashNeedsNothing() {
        XCTAssertNil(KiteloopProject.gitignoreAddition(for: "node_modules/\n.kiteloop\n"))
    }

    func testAnchoredBlanketEntryNeedsNothing() {
        XCTAssertNil(KiteloopProject.gitignoreAddition(for: "/.kiteloop/\n"))
    }

    func testIndentedBlanketEntryNeedsNothing() {
        XCTAssertNil(KiteloopProject.gitignoreAddition(for: "  .kiteloop/  \n"))
    }

    func testWildcardChildrenEntryNeedsNothing() {
        // `.kiteloop/*` ignores every child directory, so all three required entries
        // are covered.
        let contents = ".kiteloop/*\n!.kiteloop/team.json\n"
        XCTAssertNil(KiteloopProject.gitignoreAddition(for: contents))
    }

    // MARK: - Projects tracking part of .kiteloop/

    func testPartialIgnoreGetsOnlyTheRequiredEntries() {
        // The project tracks team.json and backlog on purpose — appending a blanket
        // `.kiteloop/` would silently stop tracking them.
        let contents = ".kiteloop/logs/\n.kiteloop/sessions/\n"
        XCTAssertEqual(
            KiteloopProject.gitignoreAddition(for: contents),
            ".kiteloop/worktrees/\n.kiteloop/web/\n.kiteloop/backlog-tree/\n"
        )
    }

    func testNegatedEntryCountsAsCustomizationNotAsIgnore() {
        let contents = "!.kiteloop/team.json\n"
        XCTAssertEqual(
            KiteloopProject.gitignoreAddition(for: contents),
            ".kiteloop/worktrees/\n.kiteloop/web/\n.kiteloop/backlog-tree/\n"
        )
    }

    func testOnlyTheMissingRequiredEntryIsAdded() {
        let contents = ".kiteloop/logs/\n.kiteloop/worktrees/\n.kiteloop/backlog-tree/\n"
        XCTAssertEqual(KiteloopProject.gitignoreAddition(for: contents), ".kiteloop/web/\n")
    }

    func testBacklogCheckoutIsForcedOnAProjectThatOnlyIgnoredTheOlderTwo() {
        // The shared backlog branch's checkout is a linked worktree inside the project
        // root: unignored it shows as untracked forever, and auto-merge refuses on a
        // dirty tree. A project seeded before it existed gets it backfilled.
        let contents = ".kiteloop/logs/\n.kiteloop/worktrees/\n.kiteloop/web/\n"
        XCTAssertEqual(KiteloopProject.gitignoreAddition(for: contents), ".kiteloop/backlog-tree/\n")
    }

    func testRequiredEntriesPresentNeedNothing() {
        let contents = ".kiteloop/logs/\n.kiteloop/worktrees/\n.kiteloop/web/\n.kiteloop/backlog-tree/\n"
        XCTAssertNil(KiteloopProject.gitignoreAddition(for: contents))
    }

    func testRequiredEntriesMatchRegardlessOfSlashStyle() {
        let contents = ".kiteloop/logs/\n/.kiteloop/worktrees\n.kiteloop/web/*\n/.kiteloop/backlog-tree/\n"
        XCTAssertNil(KiteloopProject.gitignoreAddition(for: contents))
    }

    func testSimilarlyNamedDirectoryIsNotMistakenForOurs() {
        // ".kiteloop-backup/" is a different directory and must not satisfy the check.
        let contents = ".kiteloop-backup/\n"
        XCTAssertEqual(KiteloopProject.gitignoreAddition(for: contents), ".kiteloop/\n")
    }

    // MARK: - On-disk behaviour

    func testSeedingAppendsToExistingGitignore() throws {
        let root = try makeTempDir()
        let gitignore = root.appending(path: ".gitignore")
        try "node_modules/\n".write(to: gitignore, atomically: true, encoding: .utf8)

        try KiteloopProject(rootURL: root).ensureDirectoryExists()

        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "node_modules/\n.kiteloop/\n")
    }

    func testSeedingInsertsNewlineWhenFileDoesNotEndInOne() throws {
        let root = try makeTempDir()
        let gitignore = root.appending(path: ".gitignore")
        try "node_modules/".write(to: gitignore, atomically: true, encoding: .utf8)

        try KiteloopProject(rootURL: root).ensureDirectoryExists()

        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "node_modules/\n.kiteloop/\n")
    }

    func testSeedingBackfillsRequiredEntriesOnExistingProject() throws {
        // `.kiteloop/` already exists — an upgrade path, not a fresh seed — and the
        // project tracks part of it, so only the required entries get appended.
        let root = try makeTempDir()
        let gitignore = root.appending(path: ".gitignore")
        try ".kiteloop/logs/\n".write(to: gitignore, atomically: true, encoding: .utf8)
        let project = KiteloopProject(rootURL: root)
        try FileManager.default.createDirectory(at: project.kiteloopDirURL, withIntermediateDirectories: true)

        try project.ensureDirectoryExists()

        XCTAssertEqual(
            try String(contentsOf: gitignore, encoding: .utf8),
            ".kiteloop/logs/\n.kiteloop/worktrees/\n.kiteloop/web/\n.kiteloop/backlog-tree/\n"
        )
    }

    func testSeedingIsIdempotent() throws {
        let root = try makeTempDir()
        let gitignore = root.appending(path: ".gitignore")
        try "node_modules/\n".write(to: gitignore, atomically: true, encoding: .utf8)
        let project = KiteloopProject(rootURL: root)

        try project.ensureDirectoryExists()
        try project.ensureDirectoryExists()

        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "node_modules/\n.kiteloop/\n")
    }

    /// A byte that is not UTF-8 no longer skips the file: the missing entry is
    /// appended after the original bytes, which are written back untouched.
    func testSeedingAGitignoreWithABadByteAppendsAfterTheOriginalBytes() throws {
        let root = try makeTempDir()
        let gitignore = root.appending(path: ".gitignore")
        let original = Data("node_modules/\n".utf8) + Data([0xFF]) + Data("\n".utf8)
        try original.write(to: gitignore)
        let project = KiteloopProject(rootURL: root)

        try project.ensureDirectoryExists()
        XCTAssertEqual(try Data(contentsOf: gitignore), original + Data(".kiteloop/\n".utf8))

        try project.ensureDirectoryExists()
        XCTAssertEqual(try Data(contentsOf: gitignore), original + Data(".kiteloop/\n".utf8))
    }

    func testSeedingDoesNotCreateAGitignore() throws {
        // Directories that aren't repos (the home workspace, plain folders) shouldn't
        // sprout a .gitignore just because Kiteloop opened them.
        let root = try makeTempDir()

        try KiteloopProject(rootURL: root).ensureDirectoryExists()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: ".gitignore").path(percentEncoded: false)))
    }

    // MARK: - Repos with no .gitignore

    func testSeedingCreatesAGitignoreForARepoWithNone() throws {
        let root = try makeGitRepo()

        try KiteloopProject(rootURL: root).ensureDirectoryExists()

        let gitignore = root.appending(path: ".gitignore")
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), ".kiteloop/\n")
    }

    func testSeedingTwiceOnARepoWithNoGitignoreAddsNothingTheSecondTime() throws {
        let root = try makeGitRepo()
        let project = KiteloopProject(rootURL: root)

        try project.ensureDirectoryExists()
        try project.ensureDirectoryExists()

        let gitignore = root.appending(path: ".gitignore")
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), ".kiteloop/\n")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        try makeTemporaryDirectory(prefix: "kiteloop-gitignore-tests")
    }

    private func makeGitRepo() throws -> URL {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        return root
    }
}
