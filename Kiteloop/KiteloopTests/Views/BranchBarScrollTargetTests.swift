import KiteloopCore
import XCTest
@testable import Kiteloop

@MainActor
final class BranchBarScrollTargetTests: XCTestCase {

    private func treeWithBranches(_ count: Int) -> (ConversationTree, [UUID]) {
        let tree = ConversationTree()
        let ids = (1...count).map { tree.createBranch(name: "branch-\($0)", from: UUID(), messages: []) }
        return (tree, ids)
    }

    func testTheBranchYouAreOnIsTheTargetEvenFifthOfEight() {
        let (tree, ids) = treeWithBranches(8)
        _ = tree.switchToBranch(ids[4], leaving: [])
        XCTAssertEqual(BranchBarView.scrollTarget(in: tree), .branch(ids[4]))
    }

    func testBackOnMainTheTargetIsMainAndNoBranch() {
        let (tree, ids) = treeWithBranches(8)
        _ = tree.switchToBranch(ids[4], leaving: [])
        _ = tree.switchToMain(leaving: [])
        let target = BranchBarView.scrollTarget(in: tree)
        XCTAssertEqual(target, .main)
        for id in ids {
            XCTAssertNotEqual(target, .branch(id))
        }
    }
}
