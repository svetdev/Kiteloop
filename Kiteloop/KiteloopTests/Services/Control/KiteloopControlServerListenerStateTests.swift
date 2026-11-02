import XCTest
import KiteloopCore
@testable import Kiteloop

/// `KiteloopControlServer.isRunning` used to flip `true` the moment
/// `HTTPServer.start()` returned — before the loopback bind it kicks off had
/// actually succeeded, and with nothing turning it back `false` if the
/// listener later failed or was cancelled. These assert it against the
/// listener's real state instead: `true` only once bound, `false` again on a
/// bind conflict, and recovered once a bounded, backed-off restart succeeds.
@MainActor
final class KiteloopControlServerListenerStateTests: XCTestCase {

    func testIsRunningIsTrueOnlyOnceTheListenerIsBound() async throws {
        let harness = try await ControlServerHarness.start()
        defer { harness.stop() }
        XCTAssertTrue(harness.server.isRunning)
        XCTAssertEqual(harness.server.activePort, harness.port)
    }

    func testStopClearsIsRunningAndActivePort() async throws {
        let harness = try await ControlServerHarness.start()
        harness.stop()
        XCTAssertFalse(harness.server.isRunning)
        XCTAssertNil(harness.server.activePort)
    }

    func testIsRunningStaysFalseWhileAnotherServerHoldsThePort() async throws {
        let harness = try await ControlServerHarness.start()
        defer { harness.stop() }

        let contender = KiteloopControlServer(registry: ControlSessionRegistry(), token: "contender-token")
        contender.start(port: harness.port)
        defer { contender.stop() }

        try await eventually("the contender to observe the bind conflict") {
            contender.debugConsecutiveListenerFailures > 0
        }
        XCTAssertFalse(contender.isRunning, "a listener that lost the port must never report running")
    }

    func testFailedListenerRestartsAndSucceedsOnceThePortFrees() async throws {
        let shipped = KiteloopControlServer.listenerRestartBaseInterval
        KiteloopControlServer.listenerRestartBaseInterval = 0.02
        addTeardownBlock { await MainActor.run { KiteloopControlServer.listenerRestartBaseInterval = shipped } }

        let harness = try await ControlServerHarness.start()
        let contender = KiteloopControlServer(registry: ControlSessionRegistry(), token: "contender-token")
        contender.start(port: harness.port)
        defer { contender.stop() }

        try await eventually("the contender to observe the bind conflict") {
            contender.debugConsecutiveListenerFailures > 0
        }
        XCTAssertFalse(contender.isRunning)

        // Free the port the contender is backing off on; its next scheduled
        // restart should bind it and report running.
        harness.stop()

        try await eventually(timeout: .seconds(10),
                              "the contender to bind once the port frees, after backoff") {
            contender.isRunning
        }
        XCTAssertEqual(contender.activePort, harness.port)
    }

    func testGivesUpAfterMaxListenerRestartsRatherThanRetryingForever() async throws {
        let shipped = KiteloopControlServer.listenerRestartBaseInterval
        KiteloopControlServer.listenerRestartBaseInterval = 0.01
        addTeardownBlock { await MainActor.run { KiteloopControlServer.listenerRestartBaseInterval = shipped } }

        let harness = try await ControlServerHarness.start()
        defer { harness.stop() }

        let contender = KiteloopControlServer(registry: ControlSessionRegistry(), token: "contender-token")
        contender.start(port: harness.port)
        defer { contender.stop() }

        // `scheduleListenerRestart` never schedules another attempt once the
        // count passes `maxListenerRestarts`, so this count is the final one —
        // a listener that kept retrying past it would need a further failed
        // bind attempt to reach a higher count, which nothing here triggers.
        try await eventually(timeout: .seconds(15),
                              "the contender to exhaust its restart budget and stop there") {
            contender.debugConsecutiveListenerFailures == KiteloopControlServer.maxListenerRestarts + 1
        }
        XCTAssertFalse(contender.isRunning, "a listener that exhausted its restart budget must not report running")
    }

    // MARK: - Giving up says so, and Retry brings it back

    func testGivingUpFilesOneInboxNoticeNamingThePortAndGivingUpAgainReplacesIt() async throws {
        shrinkListenerBackoff()
        let harness = try await ControlServerHarness.start()
        defer { harness.stop() }
        let inbox = NotificationStore(notificationsURL: try makeTemporaryDirectory().appending(path: "inbox.log"))
        let contender = KiteloopControlServer(registry: ControlSessionRegistry(), token: "contender-token",
                                              inbox: { inbox })
        contender.start(port: harness.port)
        defer { contender.stop() }

        try await eventually(timeout: .seconds(15), "the give-up notice to reach the inbox") {
            await inbox.pending().count == 1
        }
        let filed = await inbox.pending()
        let first = try XCTUnwrap(filed.first)
        XCTAssertEqual(first.type, .error)
        XCTAssertTrue(first.title.contains(String(harness.port)), "the notice names the port: \(first.title)")
        XCTAssertEqual(first.rollUpKey, KiteloopControlServer.listenerGaveUpRollUpKey)

        contender.retryListening()
        try await eventually(timeout: .seconds(15), "the second give-up to replace the first notice") {
            let pending = await inbox.pending().map(\.id)
            return pending.count == 1 && pending != [first.id]
        }
        let resolved = await inbox.resolved().map(\.id)
        XCTAssertEqual(resolved, [first.id], "the earlier notice is resolved, not left beside the new one")
    }

    func testRetryResetsTheFailureCountAndAListenerThatStartsResolvesTheNotice() async throws {
        shrinkListenerBackoff()
        let harness = try await ControlServerHarness.start()
        let inbox = NotificationStore(notificationsURL: try makeTemporaryDirectory().appending(path: "inbox.log"))
        let contender = KiteloopControlServer(registry: ControlSessionRegistry(), token: "contender-token",
                                              inbox: { inbox })
        contender.start(port: harness.port)
        defer { contender.stop() }

        try await eventually(timeout: .seconds(15), "the contender to give up and say so") {
            await inbox.pending().count == 1
        }
        XCTAssertEqual(contender.debugConsecutiveListenerFailures, KiteloopControlServer.maxListenerRestarts + 1)

        harness.stop()
        contender.retryListening()
        XCTAssertLessThanOrEqual(contender.debugConsecutiveListenerFailures, 1,
                                 "Retry starts the failure count over")

        try await eventually(timeout: .seconds(10), "the contender to bind the freed port") {
            contender.isRunning
        }
        XCTAssertEqual(contender.activePort, harness.port)
        XCTAssertEqual(contender.debugConsecutiveListenerFailures, 0)
        try await eventually("the give-up notice to resolve once listening") {
            let pending = await inbox.pending()
            let resolved = await inbox.resolved()
            return pending.isEmpty && resolved.count == 1
        }
    }

    // MARK: - Settings can say why, and who has the port

    func testARefusedListenerKeepsWhyAndWhoHoldsThePort() async throws {
        let harness = try await ControlServerHarness.start()
        defer { harness.stop() }
        let runner = ScriptedSubprocessRunner { call in
            call.executable == "/usr/sbin/lsof"
                ? .init(output: "p1237\ncPython\nf8\nn127.0.0.1:\(harness.port)\n")
                : .init(status: 1)
        }
        let contender = KiteloopControlServer(registry: ControlSessionRegistry(), token: "contender-token")
        try await withScriptedSubprocesses(runner) {
            contender.start(port: harness.port)
            defer { contender.stop() }

            try await eventually("the contender to name who holds its port") {
                contender.portHolder != nil
            }
            XCTAssertEqual(contender.lastListenerFailure, "bind: Address already in use (errno 48)")
            XCTAssertEqual(contender.portHolder, "Python (pid 1237) on 127.0.0.1:\(harness.port)")
            XCTAssertTrue(runner.calls.contains { $0.arguments.contains("-iTCP:\(harness.port)") },
                          "the lookup asks about the refused port")
        }
    }

    func testListeningAndStoppingBothClearTheFailure() async throws {
        shrinkListenerBackoff()
        let harness = try await ControlServerHarness.start()
        let runner = ScriptedSubprocessRunner { _ in .init(output: "p1\ncholder\nf3\nn*:1\n") }
        let contender = KiteloopControlServer(registry: ControlSessionRegistry(), token: "contender-token")
        try await withScriptedSubprocesses(runner) {
            contender.start(port: harness.port)
            try await eventually("the contender to record the refusal") { contender.portHolder != nil }
            contender.stop()
            XCTAssertEqual(contender.lastListenerFailure, "", "a stopped server has no failure to show")
            XCTAssertNil(contender.portHolder)

            contender.start(port: harness.port)
            defer { contender.stop() }
            try await eventually("the contender to record the refusal again") { contender.portHolder != nil }
            harness.stop()
            try await eventually(timeout: .seconds(10), "the contender to bind the freed port") {
                contender.isRunning
            }
            XCTAssertEqual(contender.lastListenerFailure, "", "a listening server has no failure to show")
            XCTAssertNil(contender.portHolder)
        }
    }

    private func shrinkListenerBackoff() {
        let shipped = KiteloopControlServer.listenerRestartBaseInterval
        KiteloopControlServer.listenerRestartBaseInterval = 0.01
        addTeardownBlock { await MainActor.run { KiteloopControlServer.listenerRestartBaseInterval = shipped } }
    }
}
