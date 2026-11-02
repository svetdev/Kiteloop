import XCTest
@testable import KiteloopCore

final class ConversationTreeTests: XCTestCase {

    /// Leaving a branch for main saves what was said on it, so switching back
    /// to the branch restores it rather than handing back the creation-time snapshot.
    func testLeavingBranchSavesItsMessages() {
        let tree = ConversationTree()
        let main = [Message.human("hello")]
        let branchID = tree.createBranch(name: "b", from: main[0].id, messages: main)

        let onBranch = tree.switchToBranch(branchID, leaving: main)
        XCTAssertEqual(onBranch?.map(\.id), main.map(\.id))

        let extended = main + [Message.human("said on the branch")]
        let backToMain = tree.switchToMain(leaving: extended)
        XCTAssertEqual(backToMain.map(\.id), main.map(\.id))

        let restored = tree.switchToBranch(branchID, leaving: backToMain)
        XCTAssertEqual(restored?.map(\.id), extended.map(\.id))
    }

    /// Switching to the branch already stood on keeps what was said on it,
    /// rather than handing back the transcript it held on arrival.
    func testSwitchingToActiveBranchKeepsItsMessages() {
        let tree = ConversationTree()
        let main = [Message.human("hello")]
        let branchID = tree.createBranch(name: "b", from: main[0].id, messages: main)
        _ = tree.switchToBranch(branchID, leaving: main)

        let extended = main + [Message.human("said on the branch")]
        let same = tree.switchToBranch(branchID, leaving: extended)

        XCTAssertEqual(same?.map(\.id), extended.map(\.id))
        XCTAssertEqual(tree.activeBranchID, branchID)
        XCTAssertEqual(tree.branches.first { $0.id == branchID }?.messages.map(\.id), extended.map(\.id))
    }

    /// Leaving main for a branch saves main's own transcript, so `/branch main`
    /// restores it as it stood at that point, not whatever the branch changed it to.
    func testLeavingMainSavesItsMessages() {
        let tree = ConversationTree()
        let main0 = [Message.human("on main")]
        let branchID = tree.createBranch(name: "b", from: main0[0].id, messages: main0)

        let mainAtSwitch = main0 + [Message.human("said on main before switching away")]
        _ = tree.switchToBranch(branchID, leaving: mainAtSwitch)

        let onBranch = main0 + [Message.human("said on the branch")]
        let backToMain = tree.switchToMain(leaving: onBranch)

        XCTAssertEqual(backToMain.map(\.id), mainAtSwitch.map(\.id))
    }

    /// Deleting the branch you are standing on hands back the main transcript,
    /// not the messages of the branch that was just removed.
    func testDeletingActiveBranchReturnsMainTranscript() {
        let tree = ConversationTree()
        let main = [Message.human("on main")]
        let branchID = tree.createBranch(name: "b", from: main[0].id, messages: main)

        _ = tree.switchToBranch(branchID, leaving: main)

        let restored = tree.removeBranch(branchID)
        XCTAssertEqual(restored?.map(\.id), main.map(\.id))
        XCTAssertNil(tree.activeBranchID)
        XCTAssertTrue(tree.branches.isEmpty)
    }

    /// Deleting a branch you are not standing on leaves the active transcript untouched.
    func testDeletingInactiveBranchReturnsNil() {
        let tree = ConversationTree()
        let main = [Message.human("on main")]
        let branchID = tree.createBranch(name: "b", from: main[0].id, messages: main)

        XCTAssertNil(tree.removeBranch(branchID))
        XCTAssertTrue(tree.branches.isEmpty)
    }

    /// Renaming keeps everything but the name: id, messages, parent message
    /// and which branch is active.
    func testRenamingKeepsIDMessagesParentAndActiveBranch() {
        let tree = ConversationTree()
        let main = [Message.human("on main")]
        let branchID = tree.createBranch(name: "branch-1", from: main[0].id, messages: main)
        _ = tree.switchToBranch(branchID, leaving: main)

        XCTAssertTrue(tree.renameBranch(branchID, to: "  idea  "))

        XCTAssertEqual(tree.branches.count, 1)
        XCTAssertEqual(tree.branches[0].id, branchID)
        XCTAssertEqual(tree.branches[0].name, "idea")
        XCTAssertEqual(tree.branches[0].messages.map(\.id), main.map(\.id))
        XCTAssertEqual(tree.branches[0].parentMessageID, main[0].id)
        XCTAssertEqual(tree.activeBranchID, branchID)
    }

    /// A blank name, a name another branch has and an unknown id are each
    /// refused, and the tree is left as it was.
    func testRenameRefusesBlankTakenAndUnknownLeavingTheTreeUnchanged() {
        let tree = ConversationTree()
        let main = [Message.human("on main")]
        let a = tree.createBranch(name: "a", from: main[0].id, messages: main)
        _ = tree.createBranch(name: "b", from: main[0].id, messages: main)
        _ = tree.switchToBranch(a, leaving: main)

        for (id, name) in [(a, ""), (a, "   \n"), (a, "b"), (a, " b "), (UUID(), "c")] {
            XCTAssertFalse(tree.renameBranch(id, to: name), "renamed \(id) to '\(name)'")
            XCTAssertEqual(tree.branches.map(\.name), ["a", "b"])
            XCTAssertEqual(tree.activeBranchID, a)
        }
    }

    func testRenameRefusesMainInAnyCaseButAcceptsANameStartingWithMain() {
        let tree = ConversationTree()
        let main = [Message.human("on main")]
        let a = tree.createBranch(name: "a", from: main[0].id, messages: main)

        for name in ["main", " Main ", "MAIN"] {
            XCTAssertFalse(tree.renameBranch(a, to: name), "renamed a to '\(name)'")
            XCTAssertEqual(tree.branches.map(\.name), ["a"])
        }
        XCTAssertTrue(tree.renameBranch(a, to: "mainline"))
        XCTAssertEqual(tree.branches.map(\.name), ["mainline"])
    }

    func testRenameRefusesAnotherBranchsNameInAnyCase() {
        let tree = ConversationTree()
        let main = [Message.human("on main")]
        let a = tree.createBranch(name: "a", from: main[0].id, messages: main)
        _ = tree.createBranch(name: "experiment", from: main[0].id, messages: main)

        for name in ["Experiment", "EXPERIMENT", " eXperiment "] {
            XCTAssertFalse(tree.renameBranch(a, to: name), "renamed a to '\(name)'")
            XCTAssertEqual(tree.branches.map(\.name), ["a", "experiment"])
        }
    }

    func testRenameAcceptsANewCasingOfTheBranchsOwnName() {
        let tree = ConversationTree()
        let main = [Message.human("on main")]
        let a = tree.createBranch(name: "experiment", from: main[0].id, messages: main)
        _ = tree.createBranch(name: "b", from: main[0].id, messages: main)

        XCTAssertTrue(tree.renameBranch(a, to: "Experiment"))
        XCTAssertEqual(tree.branches.map(\.name), ["Experiment", "b"])
    }
}
