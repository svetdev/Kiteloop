import XCTest
@testable import KiteloopCore
import KiteloopTestSupport

/// The companions' half of a merge gate, against real repositories: a
/// `scratch` directory stands in for the project's scratch worktree.
final class CompanionMergeTests: XCTestCase {
    private var home: URL!
    private var scratch: URL!

    override func setUpWithError() throws {
        home = try makeTemporaryDirectory(prefix: "companion-merge")
        scratch = home.appending(path: "scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    // MARK: - Fixtures

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let result = SubprocessOutput.runWithDeadline(
            executable: "/usr/bin/git",
            arguments: ["-C", directory.path(percentEncoded: false)] + arguments, timeout: 60)
        XCTAssertEqual(result.status, 0, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ text: String, to path: String, in directory: URL) throws {
        try text.write(to: directory.appending(path: path), atomically: true, encoding: .utf8)
    }

    /// A repository on `main` with one file, and — when `work` is given — the
    /// item's branch one commit ahead, changing that file.
    private func companion(_ name: String, base: String? = nil, work: String? = "changed\n") throws -> CompanionRepo {
        let url = home.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: url)
        try git(["config", "user.name", "Test"], in: url)
        try git(["config", "user.email", "test@example.invalid"], in: url)
        try write("start\n", to: "file.txt", in: url)
        try git(["add", "-A"], in: url)
        try git(["commit", "-q", "-m", "start"], in: url)
        if let work {
            try git(["checkout", "-q", "-b", "kiteloop/item-1"], in: url)
            try write(work, to: "file.txt", in: url)
            try git(["commit", "-q", "-am", "the item's work"], in: url)
            try git(["checkout", "-q", "main"], in: url)
        }
        return CompanionRepo(name: name, path: url.path(percentEncoded: false), baseBranch: base)
    }

    /// Parks the companion's own checkout on another branch, so `main` is a
    /// base nothing has checked out.
    private func parkCheckout(_ companion: CompanionRepo) throws {
        try git(["checkout", "-q", "-b", "parked"], in: root(companion))
    }

    private func root(_ companion: CompanionRepo) -> URL { companion.root(projectRoot: home) }

    private func tip(_ ref: String, _ companion: CompanionRepo) throws -> String {
        try git(["rev-parse", ref], in: root(companion))
    }

    private func prepare(_ companions: [CompanionRepo]) throws -> CompanionMerge {
        try CompanionMerge.prepare(companions, itemID: "item-1", message: "autopilot: merge item-1",
                                   projectRoot: home, scratch: scratch).get()
    }

    // MARK: - Prepare

    func testPrepareBuildsTheMergedTreeUnderTheScratchAndMovesNoRef() throws {
        let library = try companion("library")
        let before = try tip("main", library)

        let merge = try prepare([library])

        let nested = scratch.appending(path: ".kiteloop/repos/library")
        XCTAssertEqual(try String(contentsOf: nested.appending(path: "file.txt"), encoding: .utf8), "changed\n")
        XCTAssertEqual(try tip("main", library), before)
        XCTAssertEqual(merge.entries.map(\.landing), [.fastForward(old: before)])
    }

    func testACompanionTheItemNeverTouchedIsCheckedOutAtItsBaseWithNothingToLand() throws {
        let library = try companion("library", work: nil)

        let merge = try prepare([library])

        XCTAssertEqual(merge.entries.map(\.landing), [.nothing])
        XCTAssertEqual(try String(contentsOf: scratch.appending(path: ".kiteloop/repos/library/file.txt"),
                                  encoding: .utf8), "start\n")
        XCTAssertEqual(merge.land(), .landed([]))
    }

    func testPrepareRefusesAConflictNamingTheRepositoryAndThePath() throws {
        let library = try companion("library")
        try write("someone else\n", to: "file.txt", in: root(library))
        try git(["commit", "-q", "-am", "the base moved"], in: root(library))

        let result = CompanionMerge.prepare([library], itemID: "item-1", message: "merge",
                                            projectRoot: home, scratch: scratch)

        guard case .failure(let refusal) = result else { return XCTFail("a conflict was prepared") }
        XCTAssertTrue(refusal.reason.hasPrefix("companion library: kiteloop/item-1 no longer merges"), refusal.reason)
        XCTAssertTrue(refusal.reason.contains("file.txt"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: scratch.appending(path: ".kiteloop/repos/library").path(percentEncoded: false)))
    }

    func testPrepareRefusesAFastForwardOverUncommittedChangesToTheSameFile() throws {
        let library = try companion("library")
        try write("being edited\n", to: "file.txt", in: root(library))

        let result = CompanionMerge.prepare([library], itemID: "item-1", message: "merge",
                                            projectRoot: home, scratch: scratch)

        guard case .failure(let refusal) = result else { return XCTFail("an overlapping checkout was prepared") }
        XCTAssertTrue(refusal.reason.contains("uncommitted changes to files the merge touches: file.txt"), refusal.reason)
    }

    func testPrepareRefusesABaseCheckedOutInAnotherWorktree() throws {
        let library = try companion("library", base: "main")
        try parkCheckout(library)
        let elsewhere = home.appending(path: "elsewhere")
        try git(["worktree", "add", "-q", elsewhere.path(percentEncoded: false), "main"], in: root(library))

        let result = CompanionMerge.prepare([library], itemID: "item-1", message: "merge",
                                            projectRoot: home, scratch: scratch)

        guard case .failure(let refusal) = result else { return XCTFail("a held base was prepared") }
        XCTAssertTrue(refusal.reason.hasPrefix("base branch main of companion library is checked out at"), refusal.reason)
    }

    // MARK: - Land

    func testLandFastForwardsACheckoutOnItsBase() throws {
        let library = try companion("library")
        let merge = try prepare([library])

        let outcome = merge.land()

        let landed = try tip("main", library)
        XCTAssertEqual(outcome, .landed([.init(name: "library", commit: landed, base: nil)]))
        XCTAssertEqual(try String(contentsOf: root(library).appending(path: "file.txt"), encoding: .utf8), "changed\n")
    }

    func testLandMovesABaseNothingHasCheckedOutAndLeavesTheCheckoutAlone() throws {
        let library = try companion("library", base: "main")
        try parkCheckout(library)
        let merge = try prepare([library])

        let outcome = merge.land()

        let landed = try tip("main", library)
        XCTAssertEqual(outcome, .landed([.init(name: "library", commit: landed, base: "main")]))
        XCTAssertEqual(try git(["show", "main:file.txt"], in: root(library)), "changed")
        XCTAssertEqual(try git(["symbolic-ref", "--short", "HEAD"], in: root(library)), "parked")
        XCTAssertEqual(try String(contentsOf: root(library).appending(path: "file.txt"), encoding: .utf8), "start\n")
    }

    func testARefusalPutsBackTheCompanionsAlreadyLanded() throws {
        let library = try companion("library", base: "main")
        try parkCheckout(library)
        let client = try companion("client", base: "main")
        try parkCheckout(client)
        let libraryBefore = try tip("main", library)
        let merge = try prepare([library, client])
        // The second companion's base moves while the merge is being verified.
        try git(["commit", "-q", "--allow-empty", "-m", "someone else"], in: root(client))
        try git(["branch", "-f", "main", "parked"], in: root(client))
        let clientNow = try tip("main", client)

        let outcome = merge.land()

        guard case .refused(let reason) = outcome else { return XCTFail("landed over a moved base") }
        XCTAssertTrue(reason.hasPrefix("could not land companion client:"), reason)
        XCTAssertTrue(reason.contains("nothing was landed"), reason)
        XCTAssertEqual(try tip("main", library), libraryBefore, "the first companion was put back")
        XCTAssertEqual(try tip("main", client), clientNow)
    }

    func testRollbackUndoesAFastForwardAndARefMove() throws {
        let library = try companion("library")
        let client = try companion("client", base: "main")
        try parkCheckout(client)
        let libraryBefore = try tip("main", library)
        let clientBefore = try tip("main", client)
        let merge = try prepare([library, client])
        XCTAssertEqual(merge.land(), .landed(merge.landed))

        XCTAssertEqual(merge.rollback(), [])

        XCTAssertEqual(try tip("main", library), libraryBefore)
        XCTAssertEqual(try String(contentsOf: root(library).appending(path: "file.txt"), encoding: .utf8), "start\n")
        XCTAssertEqual(try tip("main", client), clientBefore)
    }

    func testRollbackNamesARepositorySomeoneMovedSince() throws {
        let library = try companion("library")
        let merge = try prepare([library])
        XCTAssertEqual(merge.land(), .landed(merge.landed))
        try git(["commit", "-q", "--allow-empty", "-m", "built on the merge"], in: root(library))
        let now = try tip("main", library)

        XCTAssertEqual(merge.rollback(), ["library"])
        XCTAssertEqual(try tip("main", library), now, "their commit is not thrown away")
    }

    // MARK: - After

    func testALandedBranchIsRemovedAndTheScratchLeavesNoRegistration() throws {
        let library = try companion("library")
        let merge = try prepare([library])
        XCTAssertEqual(merge.land(), .landed(merge.landed))

        merge.removeLandedBranches()
        CompanionMerge.removeScratch([library], projectRoot: home, scratch: scratch)

        XCTAssertEqual(try git(["branch", "--list", "kiteloop/item-1"], in: root(library)), "")
        XCTAssertFalse(try git(["worktree", "list"], in: root(library)).contains("scratch"))
    }

    func testAnUnlandedBranchIsKept() throws {
        let library = try companion("library")
        let merge = try prepare([library])

        merge.removeLandedBranches()

        XCTAssertEqual(try git(["branch", "--list", "kiteloop/item-1"], in: root(library)).isEmpty, false)
    }
}
