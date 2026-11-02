import XCTest
import KiteloopCore
@testable import Kiteloop

/// The recorder that builds replay fixtures is switched on from the process
/// environment rather than a compiled-in constant, so a built app can capture
/// a fixture without anyone editing Swift and rebuilding — and stays off in
/// every build where nothing asks for it.
final class KiteloopAppRecordingTests: XCTestCase {

    func testUnsetEnvironmentDoesNotRecord() {
        XCTAssertFalse(KiteloopApp.shouldRecordSessions(environment: ["PATH": "/usr/bin"]))
    }

    func testEmptyValueDoesNotRecord() {
        XCTAssertFalse(KiteloopApp.shouldRecordSessions(environment: [KiteloopApp.recordingSessionsVariable: ""]))
    }

    func testUnrecognisedValueDoesNotRecord() {
        XCTAssertFalse(KiteloopApp.shouldRecordSessions(environment: [KiteloopApp.recordingSessionsVariable: "yes"]))
    }

    func testOnValueRecords() {
        XCTAssertTrue(KiteloopApp.shouldRecordSessions(
            environment: [KiteloopApp.recordingSessionsVariable: KiteloopApp.recordingSessionsOnValue]
        ))
    }

    /// Spelled out here because a typo would leave the switch pointing at a
    /// variable nothing sets, and the recorder silently unreachable again.
    func testRecordingSessionsVariableName() {
        XCTAssertEqual(KiteloopApp.recordingSessionsVariable, "KITELOOP_RECORD_SESSIONS")
    }

    // MARK: - Recent projects

    /// An isolated home keeps its own recents: a QA copy read the user's list
    /// and stat'ed their projects under ~/Documents.
    func testAnIsolatedHomeKeepsItsRecentProjectsInsideIt() {
        let url = KiteloopApp.recentsURL(environment: [KiteloopHome.variable: "/tmp/qa-home"])
        XCTAssertEqual(url.path(percentEncoded: false),
                       "/tmp/qa-home/Library/Application Support/Kiteloop/recent-projects.json")
    }

    func testWithoutOneTheRecentsStayInApplicationSupport() {
        let url = KiteloopApp.recentsURL(environment: [:])
        XCTAssertTrue(url.path(percentEncoded: false).hasSuffix("/Library/Application Support/Kiteloop/recent-projects.json"))
        XCTAssertFalse(url.path(percentEncoded: false).hasPrefix("/tmp/"))
    }
}
