import KiteloopTestSupport
import XCTest
@testable import KiteloopCore

/// `PortHolder` names whoever holds the control port, for Settings to show
/// beside "Not currently listening".
final class PortHolderTests: XCTestCase {

    func testParsesOneProcessListeningOnTwoAddresses() {
        let fields = "p1237\ncPython\nf8\nn192.168.1.5:4517\nf9\nn100.64.1.2:4517\n"
        XCTAssertEqual(PortHolder.parse(fields: fields), [
            .init(pid: 1237, command: "Python", addresses: ["192.168.1.5:4517", "100.64.1.2:4517"]),
        ])
    }

    func testParsesSeveralProcessesEachWithItsOwnAddresses() {
        let fields = "p10\ncnode\nf3\nn*:4517\np20\ncKiteloop\nf7\nn127.0.0.1:4517\n"
        XCTAssertEqual(PortHolder.parse(fields: fields), [
            .init(pid: 10, command: "node", addresses: ["*:4517"]),
            .init(pid: 20, command: "Kiteloop", addresses: ["127.0.0.1:4517"]),
        ])
    }

    func testEmptyOutputHasNoListeners() {
        XCTAssertEqual(PortHolder.parse(fields: ""), [])
    }

    func testDescribeNamesEachProcessItsPidAndAddresses() {
        let listeners: [PortHolder.Listener] = [
            .init(pid: 1237, command: "Python", addresses: ["192.168.1.5:4517", "100.64.1.2:4517"]),
            .init(pid: 20, command: "", addresses: []),
        ]
        XCTAssertEqual(PortHolder.describe(listeners),
                       "Python (pid 1237) on 192.168.1.5:4517, 100.64.1.2:4517; pid 20")
    }

    func testDescribeOfNoListenersIsNil() {
        XCTAssertNil(PortHolder.describe([]))
    }

    func testListenersAsksLsofForTheListeningSocketsOnThePort() async {
        let runner = ScriptedSubprocessRunner { _ in .init(output: "p5\ncnc\nf3\nn127.0.0.1:4517\n") }
        let listeners = await withScriptedSubprocesses(runner) { PortHolder.listeners(onPort: 4517) }

        XCTAssertEqual(listeners, [.init(pid: 5, command: "nc", addresses: ["127.0.0.1:4517"])])
        XCTAssertEqual(runner.calls.map(\.executable), ["/usr/sbin/lsof"])
        XCTAssertEqual(runner.calls.first?.arguments, ["-nP", "-iTCP:4517", "-sTCP:LISTEN", "-Fpcn"])
    }

    /// lsof exits 1 when it finds nothing; that is no holder, not a holder
    /// named from whatever it printed.
    func testAFailedLsofHasNoListeners() async {
        let runner = ScriptedSubprocessRunner { _ in .init(status: 1, output: "p5\ncnc\n") }
        let listeners = await withScriptedSubprocesses(runner) { PortHolder.listeners(onPort: 4517) }
        XCTAssertEqual(listeners, [])
    }

    func testAnLsofThatCannotStartHasNoListeners() async {
        let runner = ScriptedSubprocessRunner { _ in .init(spawnFails: true) }
        let listeners = await withScriptedSubprocesses(runner) { PortHolder.listeners(onPort: 4517) }
        XCTAssertEqual(listeners, [])
    }
}
