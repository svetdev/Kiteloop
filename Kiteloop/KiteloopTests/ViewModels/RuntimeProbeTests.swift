import XCTest
@testable import Kiteloop

/// The quick-add menu and Settings ▸ General read runtime availability through
/// `RuntimeProbe`: a refresh asks the probe again rather than replaying its
/// first answer, so a runtime started after launch is reported once it is up.
@MainActor
final class RuntimeProbeTests: XCTestCase {

    func testNothingIsReportedBeforeTheFirstRefresh() {
        let probe = RuntimeProbe { true }
        XCTAssertNil(probe.value)
    }

    func testARuntimeStartedAfterTheFirstReadIsAvailableAfterARefresh() async {
        let answers = ScriptedAnswers([false, true])
        let probe = RuntimeProbe { await answers.next() }

        await probe.refresh()
        XCTAssertEqual(probe.value, false, "The first read reports the runtime as down")

        await probe.refresh()
        XCTAssertEqual(probe.value, true, "The second read probes again instead of replaying the first answer")
        let calls = await answers.calls
        XCTAssertEqual(calls, 2)
    }

    func testARuntimeThatStopsIsReportedDownAfterARefresh() async {
        let answers = ScriptedAnswers<[String]?>([["llama3.1"], nil])
        let probe = RuntimeProbe { await answers.next() }

        await probe.refresh()
        XCTAssertEqual(probe.value, .some(["llama3.1"]))

        await probe.refresh()
        XCTAssertEqual(probe.value, .some(nil), "Unreachable is an answer, not \"not yet read\"")
    }
}

/// Hands out its answers in order, repeating the last, and counts the reads.
private actor ScriptedAnswers<Value: Sendable> {
    private var answers: [Value]
    private(set) var calls = 0

    init(_ answers: [Value]) { self.answers = answers }

    func next() -> Value {
        calls += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}
