import XCTest
import KiteloopCore
@testable import Kiteloop

/// The loader's backlog resolution mirrors `BacklogViewModel.loadForProject` —
/// local, then the shared branch's checkout, then the vault. The middle layer
/// is what these tests pin: skipping it had every branch-backed project
/// reporting "No backlog file — nothing to groom into" while the grooming loop
/// filed items into that very backlog.
final class PortfolioSummaryLoaderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "summary-loader")
    }

    private func recent(_ name: String) -> RecentProject {
        RecentProject(id: name, name: name,
                      path: tempDir.appendingPathComponent(name).path(percentEncoded: false),
                      lastOpened: Date(timeIntervalSince1970: 0))
    }

    private func write(_ content: String, to relative: String, project name: String) throws {
        let url = tempDir.appendingPathComponent(name).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private let backlog = """
    # Backlog

    ## Epic: One

    - [ ] a | First | verify: true | size:S | ready
    - [ ] b | Second | verify: true | size:S | blocked
    """

    func testABranchCheckoutBacklogIsFoundAndCounted() async throws {
        try write(backlog, to: ".kiteloop/backlog-tree/BACKLOG.md", project: "alpha")

        let summaries = await PortfolioSummaryLoader.load([recent("alpha")], vaultURL: nil)

        XCTAssertEqual(summaries.first?.hasBacklog, true,
                       "a backlog on the branch checkout is a backlog")
        XCTAssertEqual(summaries.first?.readyItems, 1)
        XCTAssertEqual(summaries.first?.blocked, 1)
    }

    func testAProjectLocalBacklogStillWinsOverTheCheckout() async throws {
        try write(backlog, to: ".kiteloop/backlog-tree/BACKLOG.md", project: "alpha")
        try write("# Backlog\n\n## Epic: L\n\n- [ ] only | Local | verify: true | size:S | ready\n",
                  to: "BACKLOG.md", project: "alpha")

        let summaries = await PortfolioSummaryLoader.load([recent("alpha")], vaultURL: nil)

        XCTAssertEqual(summaries.first?.readyItems, 1)
        XCTAssertEqual(summaries.first?.blocked, 0, "the local file won, not the checkout")
    }

    func testNeitherLayerPresentStillReadsNoBacklog() async throws {
        try FileManager.default.createDirectory(at: tempDir.appendingPathComponent("bare"),
                                                withIntermediateDirectories: true)
        let summaries = await PortfolioSummaryLoader.load([recent("bare")], vaultURL: nil)
        XCTAssertEqual(summaries.first?.hasBacklog, false)
    }
}
