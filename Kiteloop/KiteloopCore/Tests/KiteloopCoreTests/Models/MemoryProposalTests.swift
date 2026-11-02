import XCTest
@testable import KiteloopCore

final class MemoryProposalTests: XCTestCase {

    // MARK: - Whether the text is what approving acts on

    /// For an addition and a merge the proposed text *is* the fact that gets
    /// written, so editing it before approval changes what lands in memory —
    /// the editor is offered for exactly these.
    func testAddAndMergeCarryContentThatApprovalWrites() {
        XCTAssertTrue(MemoryProposal.Operation.add.isContentMeaningful)
        XCTAssertTrue(MemoryProposal.Operation.merge(topics: ["a", "b"]).isContentMeaningful)
    }

    /// For a deletion and an archival the text is the *reason*, not the fact:
    /// approving removes a named topic whatever the text says, so editing it
    /// would change nothing, and offering an editor would claim otherwise.
    func testDeleteAndArchiveCarryNoContentThatApprovalWrites() {
        XCTAssertFalse(MemoryProposal.Operation.delete(topic: "a").isContentMeaningful)
        XCTAssertFalse(MemoryProposal.Operation.archive(topic: "a").isContentMeaningful)
    }

    /// The two answers disagree — the operations that act on named topics are
    /// exactly the ones whose text is not the fact.
    func testContentIsMeaningfulExactlyWhenTheOperationNamesNoTopicToRemove() {
        let writes: [MemoryProposal.Operation] = [.add, .merge(topics: ["a"])]
        let removes: [MemoryProposal.Operation] = [.delete(topic: "a"), .archive(topic: "a")]

        XCTAssertEqual(writes.map(\.isContentMeaningful), [true, true])
        XCTAssertEqual(removes.map(\.isContentMeaningful), [false, false])
    }
}
