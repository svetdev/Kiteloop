import KiteloopCore
import XCTest
@testable import Kiteloop

/// A proposal card shows the current text of every fact approving it replaces,
/// deletes or archives — and says so when the agent no longer has one.
final class MemoryProposalAffectedFactsTests: XCTestCase {

    private let topics = [
        MemoryTopic(id: "build-dir", body: "Builds run from Kiteloop/"),
        MemoryTopic(id: "test-host", body: "KiteloopTests is hosted by the app"),
        MemoryTopic(id: "unrelated", body: "Not named by any proposal"),
    ]

    func testAnAddReplacesNothing() {
        XCTAssertEqual(MemoryProposalView.affectedFacts(for: .add, in: topics), [])
    }

    func testAMergeGivesEveryBodyInTheProposalsOrder() {
        let facts = MemoryProposalView.affectedFacts(for: .merge(topics: ["test-host", "build-dir"]), in: topics)

        XCTAssertEqual(facts, [
            .init(slug: "test-host", body: "KiteloopTests is hosted by the app"),
            .init(slug: "build-dir", body: "Builds run from Kiteloop/"),
        ])
    }

    func testADeleteGivesItsOneBody() {
        let facts = MemoryProposalView.affectedFacts(for: .delete(topic: "build-dir"), in: topics)

        XCTAssertEqual(facts, [.init(slug: "build-dir", body: "Builds run from Kiteloop/")])
    }

    func testAnArchiveGivesItsOneBody() {
        let facts = MemoryProposalView.affectedFacts(for: .archive(topic: "test-host"), in: topics)

        XCTAssertEqual(facts, [.init(slug: "test-host", body: "KiteloopTests is hosted by the app")])
    }

    /// A slug the agent's loaded topics do not have comes back as missing, in
    /// its place, rather than dropped.
    func testATopicThatIsNotLoadedComesBackAsMissing() {
        let facts = MemoryProposalView.affectedFacts(for: .merge(topics: ["build-dir", "gone"]), in: topics)

        XCTAssertEqual(facts, [
            .init(slug: "build-dir", body: "Builds run from Kiteloop/"),
            .init(slug: "gone", body: nil),
        ])
    }
}
