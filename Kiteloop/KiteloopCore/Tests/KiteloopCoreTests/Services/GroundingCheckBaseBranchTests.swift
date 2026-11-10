import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

/// Grounding reads the tree the run will fork from: the project's
/// `baseBranch` when the checkout is on some other branch. Against a real
/// temporary repository, since which tree answers is git's to say.
///
/// The defect: with `baseBranch` set to a branch holding code the checkout
/// predates, every item about that code was refused as naming nothing — its
/// paths "not in the repo", its verify's `cd` "does not exist".
final class GroundingCheckBaseBranchTests: XCTestCase {

    private var repo: URL!

    override func setUpWithError() throws {
        repo = try makeTemporaryDirectory(prefix: "grounding-base-branch")
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "t@t"])
        git(["config", "user.name", "t"])
        try write("README.md", "hello\n")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "one"])
        // The base moves ahead; the checkout stays behind on `main`.
        git(["checkout", "-q", "-b", "develop"])
        try write("engine/Sources/Refund.swift", "enum Refund { static func settleLedger() {} }\n")
        try write("engine/scripts/check.sh", "#!/bin/sh\nexit 0\n")
        git(["add", "-A"])
        git(["commit", "-q", "-m", "two"])
        git(["checkout", "-q", "main"])
    }

    func testTheCheckoutAloneDoesNotKnowTheBasesCode() {
        let sources = GroundingCheck.Sources.repository(root: repo, searchDirectories: ["/usr/bin"])

        XCTAssertFalse(sources.corpora.contains { $0.contains("engine/Sources/Refund.swift") })
        XCTAssertFalse(sources.definesSymbol("settleLedger"))
    }

    func testWithABaseBranchItsTreeAnswersForPathsSymbolsAndScripts() {
        let sources = GroundingCheck.Sources.repository(root: repo, baseBranch: "develop",
                                                        searchDirectories: ["/usr/bin"])

        XCTAssertTrue(sources.corpora.contains { $0.contains("engine/Sources/Refund.swift") })
        XCTAssertTrue(sources.corpora.contains { $0.contains("engine") }, "a verify's `cd engine` resolves")
        XCTAssertTrue(sources.definesSymbol("settleLedger"))
        XCTAssertTrue(sources.resolvesExecutable("engine/scripts/check.sh"))
        XCTAssertFalse(sources.resolvesExecutable("engine/scripts/absent.sh"))
    }

    /// A file git does not track is real in the checkout, and a draft citing
    /// it is telling the truth whichever branch is the base.
    func testAnUntrackedFileInTheCheckoutStillGroundsAPath() throws {
        try write(".kiteloop/team.json", "{}\n")

        let sources = GroundingCheck.Sources.repository(root: repo, baseBranch: "develop",
                                                        searchDirectories: ["/usr/bin"])

        XCTAssertTrue(sources.corpora.contains { $0.contains(".kiteloop/team.json") })
    }

    func testABaseTheCheckoutIsOnOrThatNamesNoBranchReadsTheCheckout() {
        XCTAssertNil(GroundingCheck.BaseTree.branchToIndex(root: repo, baseBranch: "main"))
        XCTAssertNil(GroundingCheck.BaseTree.branchToIndex(root: repo, baseBranch: "no-such-branch"))
        XCTAssertNil(GroundingCheck.BaseTree.branchToIndex(root: repo, baseBranch: "  "))
        XCTAssertNil(GroundingCheck.BaseTree.branchToIndex(root: repo, baseBranch: nil))
        XCTAssertEqual(GroundingCheck.BaseTree.branchToIndex(root: repo, baseBranch: "develop"), "develop")
    }

    func testTheScratchTreeIsRemovedAfterIndexing() throws {
        let parent = try makeTemporaryDirectory(prefix: "grounding-scratch-parent")
        defer { try? FileManager.default.removeItem(at: parent) }

        XCTAssertNotNil(GroundingCheck.BaseTree.index(root: repo, branch: "develop", scratchParent: parent))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path(percentEncoded: false)), [])
    }

    // MARK: - Helpers

    private func write(_ relative: String, _ text: String) throws {
        let url = repo.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
