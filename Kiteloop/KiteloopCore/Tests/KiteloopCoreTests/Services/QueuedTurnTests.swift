import XCTest
@testable import KiteloopCore

/// A queued message followed into the turn it gets: its observer hears of
/// that turn and of no other.
@MainActor
final class QueuedTurnTests: XCTestCase {

    private var heard: [String] = []

    private func observer(_ name: String) -> QueuedTurn.Observer {
        { [unowned self] running in self.heard.append("\(name) \(running ? "began" : "ended")") }
    }

    func testTheReplayedMessagesObserverHearsItsTurnBeginAndEnd() {
        var turn = QueuedTurn()
        turn.replaying(observer("routine"))
        XCTAssertEqual(heard, [], "replaying a message is not yet its turn")

        turn.began()
        turn.ended()
        turn.replaying(nil)

        XCTAssertEqual(heard, ["routine began", "routine ended"])
    }

    func testATurnThatIsNotAReplayedMessagesTellsNobody() {
        var turn = QueuedTurn()
        turn.began()
        turn.ended()
        XCTAssertEqual(heard, [])
    }

    func testAnObserverHearsOnlyTheFirstTurnAfterItsMessageIsReplayed() {
        var turn = QueuedTurn()
        turn.replaying(observer("routine"))
        turn.began()
        turn.ended()
        // The turn's end replays the next queued message — a person's — before
        // the first replay is over.
        turn.replaying(nil)
        turn.began()
        turn.ended()
        turn.replaying(nil)

        XCTAssertEqual(heard, ["routine began", "routine ended"])
    }

    func testAReplayedCommandThatStartsNoTurnLeavesTheNextTurnToItsOwnMessage() {
        var turn = QueuedTurn()
        turn.replaying(observer("command"))
        // The command ran with no turn; the queue's next message is replayed.
        turn.replaying(observer("prompt"))
        turn.began()
        turn.ended()
        turn.replaying(nil)
        turn.replaying(nil)

        XCTAssertEqual(heard, ["prompt began", "prompt ended"])
    }

    func testTwoQueuedMessagesEachHearTheirOwnTurn() {
        var turn = QueuedTurn()
        turn.replaying(observer("first"))
        turn.began()
        turn.ended()
        turn.replaying(observer("second"))
        turn.began()
        XCTAssertEqual(heard, ["first began", "first ended", "second began"])
        turn.ended()
        XCTAssertEqual(heard.last, "second ended")
    }
}
