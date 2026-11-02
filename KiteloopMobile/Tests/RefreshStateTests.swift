import XCTest
@testable import KiteloopMobile

/// The line under the title says whether to wait or to pull, and a failure
/// says what failed and what to do — pinned here so "can't connect" never
/// degrades back into a raw error string.
final class RefreshStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testAFreshScreenSaysItRefreshesItself() {
        var state = RefreshState(interval: 10)
        state.succeed(at: t0)
        XCTAssertEqual(state.line(now: t0.addingTimeInterval(1)), "Updated just now · refreshes every 10s")
        XCTAssertEqual(state.line(now: t0.addingTimeInterval(12)), "Updated 12s ago · refreshes every 10s")
        XCTAssertFalse(state.isStale(now: t0.addingTimeInterval(12)))
    }

    func testAScreenThatMissedItsOwnBeatsAsksForAPull() {
        var state = RefreshState(interval: 10)
        state.succeed(at: t0)
        let later = t0.addingTimeInterval(45)
        XCTAssertTrue(state.isStale(now: later))
        XCTAssertEqual(state.line(now: later), "Updated 45s ago — later than it should be, pull to refresh")
    }

    func testRefreshingAndNeverLoadedAreSaidPlainly() {
        var state = RefreshState(interval: 15)
        XCTAssertEqual(state.line(now: t0), "Not loaded yet — pull to refresh")
        state.begin()
        XCTAssertEqual(state.line(now: t0), "Refreshing…")
        XCTAssertFalse(state.isStale(now: t0))
    }

    func testAnUnreachableMacIsNamedWithItsHostAndTheFix() {
        let problem = ConnectionProblem.classify(URLError(.cannotConnectToHost), host: "100.64.0.1:4517")
        XCTAssertEqual(problem.kind, .unreachable)
        XCTAssertEqual(problem.title, "Can't reach the Mac at 100.64.0.1:4517")
        XCTAssertTrue(problem.advice.contains("Tailscale"), problem.advice)
        XCTAssertTrue(problem.advice.contains("pull to refresh"), problem.advice)
        XCTAssertEqual(ConnectionProblem.classify(URLError(.timedOut), host: "h").kind, .unreachable)
    }

    func testARejectedTokenAndAnOlderMacAreToldApart() {
        let rejected = ConnectionProblem.classify(ControlClient.ClientError.http(401, "no"), host: "h")
        XCTAssertEqual(rejected.kind, .unauthorized)
        XCTAssertTrue(rejected.advice.contains("Pair again"), rejected.advice)
        let older = ConnectionProblem.classify(ControlClient.ClientError.http(404, "No route"), host: "h")
        XCTAssertEqual(older.kind, .outdatedMac)
        let server = ConnectionProblem.classify(ControlClient.ClientError.http(503, ""), host: "h")
        XCTAssertEqual(server.kind, .serverError(503))
        XCTAssertEqual(server.title, "The Mac answered with an error (503)")
    }

    func testAFailedRefreshKeepsTheLastSuccessAndSaysWhatFailed() {
        var state = RefreshState(interval: 10)
        state.succeed(at: t0)
        state.fail(URLError(.notConnectedToInternet), host: "mac")
        XCTAssertEqual(state.lastSuccess, t0)
        XCTAssertEqual(state.problem?.kind, .unreachable)
        XCTAssertEqual(state.line(now: t0.addingTimeInterval(5)), "Can't reach the Mac at mac")
    }

    func testAChatWhosePollFailedHidesItsStaleWorkingSpinner() {
        XCTAssertTrue(ChatView.showsWorking(state: "working", refreshFailure: nil))
        XCTAssertFalse(ChatView.showsWorking(state: "working", refreshFailure: "The request timed out."))
        XCTAssertFalse(ChatView.showsWorking(state: "idle", refreshFailure: nil))
        XCTAssertFalse(ChatView.showsWorking(state: nil, refreshFailure: nil))
    }
}
