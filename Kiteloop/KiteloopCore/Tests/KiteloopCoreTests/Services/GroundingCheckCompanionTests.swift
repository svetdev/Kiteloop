import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

/// An item that names a companion repository in `repos:` cites that
/// repository's files (ADR-0005). They are real, so they ground — but only
/// for the item that opted in, the way a sibling project answers only for a
/// draft that names it.
final class GroundingCheckCompanionTests: XCTestCase {
    private var project: URL!
    private var companions: [CompanionRepo] = []

    override func setUpWithError() throws {
        let home = try makeTemporaryDirectory(prefix: "grounding-companion")
        project = home.appending(path: "app")
        let library = home.appending(path: "library")
        for (directory, file) in [(project!, "Sources/App.swift"), (library, "Sources/Shelf.swift")] {
            let url = directory.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "// source\n".write(to: url, atomically: true, encoding: .utf8)
        }
        companions = [CompanionRepo(name: "library", path: "../library")]
    }

    private func verdict(repos: [String]?, what: String) -> GroundingCheck.Verdict {
        let sources = GroundingCheck.Sources.repository(root: project, searchDirectories: ["/usr/bin"],
                                                        companions: companions)
        let item = BacklogItem(id: "shelf", title: "Shelf", verify: nil, status: .ready, type: .local, size: .s,
                               detailPath: "backlog/shelf.md", needs: [])
        let detail = BacklogItemDetail(id: "shelf", title: "Shelf", verifyCommands: [],
                                       acceptanceCriteria: ["It works"], outOfScope: [],
                                       what: what, approach: "Edit it.", repos: repos)
        return GroundingCheck.evaluate(item: item, detail: detail, sources: sources)
    }

    func testAnItemThatNamesTheCompanionMayCiteItsFiles() {
        let verdict = verdict(repos: ["library"], what: "Change `Sources/Shelf.swift` and `Sources/App.swift`.")

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    func testThePathTheRunReachesItByGroundsToo() {
        let verdict = verdict(repos: ["library"], what: "Change `.kiteloop/repos/library/Sources/Shelf.swift`.")

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    func testTheCompanionsOwnFolderInTheRunsTreeGrounds() {
        let verdict = verdict(repos: ["library"], what: "Run the tests in `.kiteloop/repos/library`.")

        XCTAssertTrue(verdict.isGrounded, verdict.summary)
    }

    func testAnItemThatDoesNotNameTheCompanionCannotLeanOnIt() {
        let verdict = verdict(repos: nil, what: "Change `Sources/Shelf.swift` in the library.")

        XCTAssertFalse(verdict.isGrounded, "a companion answers only for an item that opted into it")
    }

    func testAnInventedPathIsStillRefusedForAnItemThatNamesTheCompanion() {
        let verdict = verdict(repos: ["library"], what: "Change `Sources/Nowhere.swift`.")

        XCTAssertFalse(verdict.isGrounded)
    }
}
