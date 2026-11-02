import XCTest
@testable import Kiteloop

/// Covers the branch chip the run list shows for a finished item: which branch a
/// row names, whether there is still a worktree to open, and that history keeps
/// the branch across a restart.
///
/// The rule that matters is that the chip never lies. It points at a ref the
/// reader is meant to be able to check out, so an item that ran in the live tree
/// must show nothing at all, and a worktree that has since been cleaned up must
/// not still be offered as somewhere to open.
@MainActor
final class BacklogAutopilotBranchLinkTests: XCTestCase {

    // MARK: - Which branch a row names

    func testLinkIsNilWhenTheItemRanInTheLiveTree() {
        // No isolation means no branch — the row shows no chip rather than
        // inventing one from the item id.
        XCTAssertNil(BacklogAutopilot.branchLink(branch: nil, projectRoot: nil))
        XCTAssertNil(BacklogAutopilot.branchLink(branch: nil, projectRoot: URL(fileURLWithPath: "/tmp/p")))
    }

    func testLinkIsNilForABlankBranch() {
        XCTAssertNil(BacklogAutopilot.branchLink(branch: "", projectRoot: nil))
        XCTAssertNil(BacklogAutopilot.branchLink(branch: "   ", projectRoot: nil))
    }

    func testShortNameDropsTheAutopilotPrefix() {
        // Every autopilot branch carries the same prefix, and the rows are narrow.
        let link = BacklogAutopilot.branchLink(branch: "kiteloop/ui-branch-link", projectRoot: nil)
        XCTAssertEqual(link?.shortName, "ui-branch-link")
        // The full ref is preserved — that's what gets copied and typed at git.
        XCTAssertEqual(link?.branch, "kiteloop/ui-branch-link")
    }

    func testShortNameKeepsBranchesWithoutThePrefixIntact() {
        let link = BacklogAutopilot.branchLink(branch: "feature/x", projectRoot: nil)
        XCTAssertEqual(link?.shortName, "feature/x")
    }

    // MARK: - Whether there is a worktree to open

    func testWorktreePathPointsAtTheItemsWorktreeWhenItStillExists() {
        let root = URL(fileURLWithPath: "/repo")
        var checked: [String] = []
        let link = BacklogAutopilot.branchLink(
            branch: "kiteloop/item-7", projectRoot: root,
            worktreeExists: { checked.append($0.path(percentEncoded: false)); return true }
        )
        XCTAssertEqual(
            link?.worktreePath?.path(percentEncoded: false),
            "/repo/.kiteloop/worktrees/item-7"
        )
        XCTAssertEqual(checked, ["/repo/.kiteloop/worktrees/item-7"])
    }

    func testWorktreePathIsNilOnceTheWorktreeIsGone() {
        // The usual case: a successful run commits and removes its worktree, so
        // only the branch is left to point at. "Reveal in Finder" must not be
        // offered for a directory that isn't there.
        let link = BacklogAutopilot.branchLink(
            branch: "kiteloop/item-7", projectRoot: URL(fileURLWithPath: "/repo"),
            worktreeExists: { _ in false }
        )
        XCTAssertNotNil(link)
        XCTAssertNil(link?.worktreePath)
    }

    func testWorktreePathIsNilWithoutAProjectRoot() {
        let link = BacklogAutopilot.branchLink(
            branch: "kiteloop/item-7", projectRoot: nil, worktreeExists: { _ in true }
        )
        XCTAssertEqual(link?.branch, "kiteloop/item-7")
        XCTAssertNil(link?.worktreePath)
    }

    func testWorktreeIsNotProbedOnTheRealFilesystemByDefaultForAMissingRoot() {
        // Guards the default argument: no root, no probe, no crash.
        XCTAssertNil(BacklogAutopilot.branchLink(branch: "kiteloop/x", projectRoot: nil)?.worktreePath)
    }

    // MARK: - Persistence

    func testHistoryWrittenBeforeBranchesWereKeptStillDecodes() {
        let json = """
        {"id":"i-1","title":"Task","outcome":"done","duration":12.5}
        """
        let item = try? JSONDecoder().decode(
            BacklogAutopilot.RunRecord.ItemRecord.self, from: Data(json.utf8)
        )
        XCTAssertNotNil(item)
        XCTAssertNil(item?.branch)
    }

    func testBranchSurvivesARoundTripThroughHistory() throws {
        // The chip has to work on a run you open days later, not just the one
        // still on screen.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = BacklogAutopilot.RunRecord(
            id: "run-1", startedAt: Date(), completedAt: nil,
            items: [
                BacklogAutopilot.RunRecord.ItemRecord(
                    id: "i-0", title: "Isolated", outcome: "done", duration: 10,
                    executionID: "e-0", branch: "kiteloop/i-0"
                ),
                BacklogAutopilot.RunRecord.ItemRecord(
                    id: "i-1", title: "Live tree", outcome: "done", duration: 10,
                    executionID: "e-1", branch: nil
                )
            ],
            workerAgentName: "worker", reviewerAgentName: "reviewer"
        )

        let decoded = try decoder.decode(
            [BacklogAutopilot.RunRecord].self, from: encoder.encode([record])
        )
        XCTAssertEqual(decoded.first?.items.first?.branch, "kiteloop/i-0")
        XCTAssertNil(decoded.first?.items.last?.branch)
    }
}
