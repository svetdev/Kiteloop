import XCTest
@testable import KiteloopCore
import KiteloopTestSupport

/// Against real repositories in a temp directory: a project that ignores
/// `.kiteloop/`, one worktree of it standing in for a run's, and companions.
final class CompanionCheckoutsTests: XCTestCase {
    private var home: URL!
    private var project: URL!
    private var tree: URL!

    override func setUpWithError() throws {
        home = try makeTemporaryDirectory(prefix: "companions")
        project = try repository("project", files: [".gitignore": ".kiteloop/\n", "app.txt": "app\n"])
        tree = project.appending(path: ".kiteloop/worktrees/item-1")
        try git(["worktree", "add", "-b", "kiteloop/item-1", tree.path(percentEncoded: false)], in: project)
    }

    // MARK: - Fixtures

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/usr/bin/git",
            arguments: ["-C", directory.path(percentEncoded: false),
                        "-c", "user.name=Test", "-c", "user.email=test@example.invalid"] + arguments,
            timeout: 60)
        XCTAssertEqual(result.status, 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func repository(_ name: String, files: [String: String]) throws -> URL {
        let url = home.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: url)
        try git(["config", "user.name", "Test"], in: url)
        try git(["config", "user.email", "test@example.invalid"], in: url)
        for (path, text) in files { try write(text, to: path, in: url) }
        try git(["add", "-A"], in: url)
        try git(["commit", "-q", "-m", "start"], in: url)
        return url
    }

    private func write(_ text: String, to path: String, in directory: URL) throws {
        try text.write(to: directory.appending(path: path), atomically: true, encoding: .utf8)
    }

    private func library(base: String? = nil) throws -> CompanionRepo {
        let url = try repository("library", files: ["lib.txt": "one\n"])
        return CompanionRepo(name: "library", path: url.path(percentEncoded: false), baseBranch: base)
    }

    private func tip(_ ref: String, in directory: URL) throws -> String {
        try git(["rev-parse", ref], in: directory)
    }

    // MARK: - Setup

    func testCreateChecksTheBranchOutUnderTheRunsTree() throws {
        let companion = try library()

        XCTAssertNil(CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree))

        let checkout = tree.appending(path: ".kiteloop/repos/library")
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: checkout), "kiteloop/item-1")
        XCTAssertEqual(try String(contentsOf: checkout.appending(path: "lib.txt"), encoding: .utf8), "one\n")
        XCTAssertEqual(try git(["status", "--porcelain"], in: tree), "", "the project never sees the nested repository")
    }

    func testCreateRefusesAPathThatIsNotARepository() throws {
        let companion = CompanionRepo(name: "ghost", path: home.appending(path: "nowhere").path(percentEncoded: false))

        let refusal = CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree)

        XCTAssertEqual(refusal?.contains("companion ghost"), true)
        XCTAssertEqual(refusal?.contains("not a git repository"), true)
    }

    func testCreateRefusesABaseBranchTheCompanionLacks() throws {
        let companion = try library(base: "release")

        let refusal = CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree)

        XCTAssertEqual(refusal, "base branch release does not exist in companion library")
    }

    func testCreateRefusesAProjectThatDoesNotIgnoreTheFolder() throws {
        let bare = try repository("bare-project", files: ["app.txt": "app\n"])
        let companion = try library()

        let refusal = CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: bare, in: bare)

        XCTAssertEqual(refusal?.contains("does not ignore"), true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: bare.appending(path: ".kiteloop/repos/library").path(percentEncoded: false)))
    }

    func testAFailedSecondCompanionTakesTheFirstAwayAgain() throws {
        let companion = try library()
        let ghost = CompanionRepo(name: "ghost", path: home.appending(path: "nowhere").path(percentEncoded: false))

        XCTAssertNotNil(CompanionCheckouts.create([companion, ghost], itemID: "item-1", projectRoot: project, in: tree))

        let root = companion.root(projectRoot: project)
        XCTAssertEqual(try git(["branch", "--list", "kiteloop/item-1"], in: root), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: companion.checkout(in: tree).path(percentEncoded: false)))
    }

    func testCreateKeepsAPreviousRunsUnmergedTipUnderABackupRef() throws {
        let companion = try library()
        let root = companion.root(projectRoot: project)
        try git(["checkout", "-q", "-b", "kiteloop/item-1"], in: root)
        try write("earlier\n", to: "lib.txt", in: root)
        try git(["commit", "-q", "-am", "earlier attempt"], in: root)
        let earlier = try tip("HEAD", in: root)
        try git(["checkout", "-q", "main"], in: root)

        XCTAssertNil(CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree))

        XCTAssertEqual(try tip(CompanionCheckouts.backupRef(itemID: "item-1", tip: earlier), in: root), earlier)
        XCTAssertEqual(try tip("kiteloop/item-1", in: root), try tip("main", in: root))
    }

    // MARK: - Teardown

    func testFinishCommitsLooseWorkAndKeepsTheBranch() throws {
        let companion = try library()
        XCTAssertNil(CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree))
        try write("two\n", to: "lib.txt", in: companion.checkout(in: tree))

        let finished = CompanionCheckouts.finish([companion], itemID: "item-1", projectRoot: project, in: tree,
                                                 message: "autopilot: item-1", keepCheckouts: false)

        XCTAssertEqual(finished, .init(committedByTeardown: ["library"], withWork: ["library"]))
        let root = companion.root(projectRoot: project)
        XCTAssertEqual(try git(["show", "kiteloop/item-1:lib.txt"], in: root), "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: companion.checkout(in: tree).path(percentEncoded: false)))
        XCTAssertEqual(try git(["show", "main:lib.txt"], in: root), "one", "the base has not moved")
    }

    func testFinishDropsABranchWithNothingOnIt() throws {
        let companion = try library()
        XCTAssertNil(CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree))

        let finished = CompanionCheckouts.finish([companion], itemID: "item-1", projectRoot: project, in: tree,
                                                 message: "autopilot: item-1", keepCheckouts: false)

        XCTAssertEqual(finished, .init())
        XCTAssertEqual(try git(["branch", "--list", "kiteloop/item-1"], in: companion.root(projectRoot: project)), "")
    }

    func testFinishKeepingCheckoutsLeavesTheWorktreeForInspection() throws {
        let companion = try library()
        XCTAssertNil(CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree))
        try write("two\n", to: "lib.txt", in: companion.checkout(in: tree))

        let finished = CompanionCheckouts.finish([companion], itemID: "item-1", projectRoot: project, in: tree,
                                                 message: "autopilot (blocked): item-1", keepCheckouts: true)

        XCTAssertEqual(finished.withWork, ["library"])
        XCTAssertEqual(try git(["status", "--porcelain"], in: companion.checkout(in: tree)), "")
    }

    func testRecoverCommitsWhatANestedWorktreeHoldsBeforeItsTreeIsDeleted() throws {
        let companion = try library()
        XCTAssertNil(CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree))
        try write("loose\n", to: "new.txt", in: companion.checkout(in: tree))

        let recovered = CompanionCheckouts.recoverAndRemoveAll(in: tree, message: "recovered")

        XCTAssertEqual(recovered, ["library"])
        let root = companion.root(projectRoot: project)
        XCTAssertEqual(try git(["show", "kiteloop/item-1:new.txt"], in: root), "loose")
        XCTAssertFalse(try git(["worktree", "list"], in: root).contains(".kiteloop/repos"),
                       "the branch is no longer held by a checkout")
    }

    func testRecoverIsANoOpForATreeWithNoCompanions() {
        XCTAssertEqual(CompanionCheckouts.recoverAndRemoveAll(in: tree, message: "recovered"), [])
    }

    // MARK: - What a branch holds

    func testDiffsNameEachRepositoryAndItsFiles() throws {
        let companion = try library()
        XCTAssertNil(CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree))
        try write("two\n", to: "lib.txt", in: companion.checkout(in: tree))
        CompanionCheckouts.finish([companion], itemID: "item-1", projectRoot: project, in: tree,
                                  message: "autopilot: item-1", keepCheckouts: false)

        let diffs = CompanionCheckouts.diffs([companion], itemID: "item-1", projectRoot: project)

        XCTAssertEqual(diffs.map(\.name), ["library"])
        XCTAssertEqual(diffs.first?.files, ["lib.txt"])
        XCTAssertEqual(diffs.first?.patch.contains("+two"), true)
        XCTAssertEqual(CompanionCheckouts.changedFiles([companion], itemID: "item-1", projectRoot: project),
                       [".kiteloop/repos/library/lib.txt"])
        XCTAssertTrue(CompanionCheckouts.combined(diffs, \.patch).hasPrefix("=== library (.kiteloop/repos/library, branch kiteloop/item-1) ==="))
    }

    func testACompanionTheRunNeverTouchedHasNoDiff() throws {
        let companion = try library()

        XCTAssertEqual(CompanionCheckouts.diffs([companion], itemID: "item-1", projectRoot: project), [])
        XCTAssertFalse(CompanionCheckouts.hasWork(companion, itemID: "item-1", projectRoot: project))
    }

    // MARK: - Review fixes

    func testLooseWorkIsCommittedEvenWhenTheRepositorysHookRefusesTheCommit() throws {
        let companion = try library()
        let root = companion.root(projectRoot: project)
        let hook = root.appending(path: ".git/hooks/pre-commit")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path(percentEncoded: false))
        XCTAssertNil(CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree))
        try write("two\n", to: "lib.txt", in: companion.checkout(in: tree))

        let finished = CompanionCheckouts.finish([companion], itemID: "item-1", projectRoot: project, in: tree,
                                                 message: "autopilot: item-1", keepCheckouts: false)

        XCTAssertEqual(finished.committedByTeardown, ["library"])
        XCTAssertEqual(finished.withWork, ["library"], "a refused commit must not read as nothing changed")
        XCTAssertEqual(try git(["show", "kiteloop/item-1:lib.txt"], in: root), "two")
    }

    func testChangedFilesAreUnreadNotEmptyWhenGitCannotSay() throws {
        let companion = try library()
        XCTAssertNil(CompanionCheckouts.create([companion], itemID: "item-1", projectRoot: project, in: tree))
        let gone = CompanionRepo(name: "library", path: companion.path, baseBranch: "no-such-base")

        XCTAssertNil(CompanionCheckouts.changedFiles([gone], itemID: "item-1", projectRoot: project))
        XCTAssertEqual(CompanionCheckouts.changedFiles([companion], itemID: "item-1", projectRoot: project), [])
    }

    func testVerifyPathsStayUnreadWhenEitherPartIs() {
        XCTAssertNil(CompanionCheckouts.verifyPaths(project: nil, companions: ["a"]))
        XCTAssertNil(CompanionCheckouts.verifyPaths(project: ["a"], companions: nil))
        XCTAssertEqual(CompanionCheckouts.verifyPaths(project: ["a"], companions: []), ["a"])
        XCTAssertEqual(CompanionCheckouts.verifyPaths(project: ["a"], companions: ["b"]), ["a", "b"])
    }

    func testADiffThatFitsIsJoinedWhole() {
        let fitted = CompanionCheckouts.fitted(own: "own", companions: "lib", limit: 100)

        XCTAssertEqual(fitted.text, "own\nlib")
        XCTAssertFalse(fitted.truncated)
        XCTAssertEqual(CompanionCheckouts.fitted(own: "own", companions: "", limit: 100).text, "own")
    }

    func testALongProjectDiffIsCutToLeaveTheCompanionsInView() {
        let own = String(repeating: "p", count: 500)

        let fitted = CompanionCheckouts.fitted(own: own, companions: "=== library ===\n+two", limit: 100)

        XCTAssertTrue(fitted.truncated)
        XCTAssertEqual(fitted.text.count, 100)
        XCTAssertTrue(fitted.text.hasSuffix("=== library ===\n+two"), fitted.text)
    }

    func testTwoLongPartsShareTheLimit() {
        let fitted = CompanionCheckouts.fitted(own: String(repeating: "p", count: 500),
                                               companions: String(repeating: "c", count: 500), limit: 100)

        XCTAssertTrue(fitted.truncated)
        XCTAssertEqual(fitted.text.count, 100)
        XCTAssertEqual(fitted.text.filter { $0 == "p" }.count, 50)
        XCTAssertEqual(fitted.text.filter { $0 == "c" }.count, 49)
    }

    func testALongDiffWithNoCompanionsIsCutAtTheLimit() {
        let fitted = CompanionCheckouts.fitted(own: String(repeating: "p", count: 500), companions: "", limit: 100)

        XCTAssertTrue(fitted.truncated)
        XCTAssertEqual(fitted.text.count, 100)
    }
}
