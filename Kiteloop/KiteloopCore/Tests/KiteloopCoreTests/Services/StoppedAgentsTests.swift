import KiteloopTestSupport
import XCTest
@testable import KiteloopCore

/// Who may start an agent the person stopped, what a refused sender is told,
/// and that the Stop outlives a relaunch.
final class StoppedAgentsTests: XCTestCase {

    // MARK: - Who may start it

    func testWhatThePersonDidOrSetUpStartsAStoppedAgent() {
        for origin in [ChatMessageOrigin.person, .routine, .automation] {
            XCTAssertNil(StoppedAgents.refusal(of: origin, toStart: "Builder"), "\(origin)")
        }
    }

    func testAnotherAgentDoesNotStartIt() throws {
        let refusal = try XCTUnwrap(StoppedAgents.refusal(of: .teammate, toStart: "Builder"))

        XCTAssertTrue(refusal.hasPrefix("Builder was stopped by the person"), refusal)
        XCTAssertTrue(refusal.contains("was not delivered"), refusal)
    }

    func testATeammateIsRefusedOnlyAnAgentThePersonStoppedThatHasNoSession() {
        var stopped = StoppedAgents()
        stopped.personStopped("builder")

        XCTAssertNotNil(stopped.refusal(of: .teammate, sendingTo: "builder", named: "Builder", hasSession: false))
        XCTAssertNil(stopped.refusal(of: .teammate, sendingTo: "builder", named: "Builder", hasSession: true),
                     "a running agent is sent to")
        XCTAssertNil(stopped.refusal(of: .teammate, sendingTo: "critic", named: "Critic", hasSession: false),
                     "an agent that never started, or crashed, was not stopped by the person")
        XCTAssertNil(stopped.refusal(of: .person, sendingTo: "builder", named: "Builder", hasSession: false))
        XCTAssertNil(stopped.refusal(of: .routine, sendingTo: "builder", named: "Builder", hasSession: false))
    }

    // MARK: - The record

    func testStartingTheAgentForgetsTheStop() {
        var stopped = StoppedAgents()

        XCTAssertTrue(stopped.personStopped("builder"))
        XCTAssertFalse(stopped.personStopped("builder"), "already recorded")
        XCTAssertTrue(stopped.contains("builder"))

        XCTAssertTrue(stopped.started("builder"))
        XCTAssertFalse(stopped.started("builder"), "nothing left to forget")
        XCTAssertFalse(stopped.contains("builder"))
        XCTAssertNil(stopped.refusal(of: .teammate, sendingTo: "builder", named: "Builder", hasSession: false))
    }

    // MARK: - On disk

    func testTheStopIsReadBackAfterARelaunch() throws {
        let file = try makeTemporaryDirectory(prefix: "stopped-agents").appending(path: ".kiteloop/stopped-agents.json")
        var stopped = StoppedAgents()
        stopped.personStopped("reviewer")
        stopped.personStopped("builder")

        try stopped.save(to: file)

        XCTAssertEqual(try StoppedAgents.load(from: file), stopped)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: file)), ["builder", "reviewer"])
    }

    func testNoFileMeansNobodyWasStopped() throws {
        let file = try makeTemporaryDirectory(prefix: "stopped-agents").appending(path: "stopped-agents.json")

        XCTAssertEqual(try StoppedAgents.load(from: file), StoppedAgents())
    }

    func testAnEmptyRecordRemovesTheFile() throws {
        let file = try makeTemporaryDirectory(prefix: "stopped-agents").appending(path: "stopped-agents.json")
        var stopped = StoppedAgents(ids: ["builder"])
        try stopped.save(to: file)

        stopped.started("builder")
        try stopped.save(to: file)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        XCTAssertNoThrow(try stopped.save(to: file), "nothing to remove the second time")
    }

    func testAFileThatCannotBeReadThrowsRatherThanReadingAsEmpty() throws {
        let file = try makeTemporaryDirectory(prefix: "stopped-agents").appending(path: "stopped-agents.json")
        try Data("not json".utf8).write(to: file)

        XCTAssertThrowsError(try StoppedAgents.load(from: file))
    }
}
