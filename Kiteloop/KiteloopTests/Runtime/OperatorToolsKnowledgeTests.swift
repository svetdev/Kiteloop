import XCTest
@testable import Kiteloop
import KiteloopCore

/// The knowledge note bundled with an "Operator tools" grant
/// (`OperatorToolsKnowledge.note`, appended to a spawned CLI's system prompt in
/// `ClaudeCodeCLIRuntime.provision`) is the only thing standing between an agent
/// holding `KITELOOP_OPERATOR_TOKEN` and a wasted turn probing endpoints that
/// don't exist. Every endpoint the note names is checked here against the real
/// routing table, so a typo'd path or a route that got renamed out from under
/// the note is a test failure rather than a bad first impression for whichever
/// agent reads it first.
final class OperatorToolsKnowledgeTests: XCTestCase {

    /// One endpoint the note tells an agent to call, and the literal substring
    /// it names it with — asserted present in the note text below, so this list
    /// cannot silently drift from what actually ships.
    private struct NotedEndpoint {
        let method: String
        let path: String
        let citedAs: String
    }

    private let notedEndpoints: [NotedEndpoint] = [
        NotedEndpoint(method: "GET", path: "/v1/projects", citedAs: "$KITELOOP_CONTROL_URL/projects"),
        NotedEndpoint(method: "GET", path: "/v1/report", citedAs: "$KITELOOP_CONTROL_URL/report"),
        NotedEndpoint(method: "GET", path: "/v1/fleet/quiesce", citedAs: "$KITELOOP_CONTROL_URL/fleet/quiesce"),
        NotedEndpoint(method: "GET", path: "/v1/backlog", citedAs: "$KITELOOP_CONTROL_URL/backlog?project="),
        NotedEndpoint(method: "GET", path: "/v1/runs", citedAs: "$KITELOOP_CONTROL_URL/runs?project="),
        NotedEndpoint(method: "POST", path: "/v1/backlog/approve", citedAs: "$KITELOOP_CONTROL_URL/backlog/approve"),
        NotedEndpoint(method: "POST", path: "/v1/runs/exec-1/approve", citedAs: "$KITELOOP_CONTROL_URL/runs/{id}/approve"),
        NotedEndpoint(method: "PUT", path: "/v1/autopilot", citedAs: "PUT /autopilot"),
        NotedEndpoint(method: "PUT", path: "/v1/coordinator/refill", citedAs: "PUT /coordinator/refill"),
        NotedEndpoint(method: "PUT", path: "/v1/coordinator/scheduling", citedAs: "/coordinator/scheduling"),
        NotedEndpoint(method: "POST", path: "/v1/runs", citedAs: "POST /runs"),
        NotedEndpoint(method: "POST", path: "/v1/runs/exec-1/note", citedAs: "POST /runs/{id}/note"),
        NotedEndpoint(method: "POST", path: "/v1/runs/exec-1/cancel", citedAs: "POST /runs/{id}/cancel"),
        NotedEndpoint(method: "POST", path: "/v1/autopilot/pause", citedAs: "POST /autopilot/pause"),
        NotedEndpoint(method: "POST", path: "/v1/autopilot/resume", citedAs: "/resume"),
        NotedEndpoint(method: "POST", path: "/v1/backlog/release", citedAs: "POST /backlog/release"),
        NotedEndpoint(method: "POST", path: "/v1/agents", citedAs: "POST /agents"),
    ]

    /// Every endpoint this test knows the note cites is actually present in the
    /// shipped text — catching a rewording that silently drops one.
    func testEveryNotedEndpointIsActuallyCitedInTheNote() {
        for endpoint in notedEndpoints {
            XCTAssertTrue(
                OperatorToolsKnowledge.note.contains(endpoint.citedAs),
                "expected the note to cite \(endpoint.citedAs)"
            )
        }
    }

    /// The note explicitly tells the agent it cannot resolve the human gate —
    /// the one thing this token is not authorized for.
    func testNoteNamesTheApprovalEndpointsAsOffLimits() {
        XCTAssertTrue(OperatorToolsKnowledge.note.contains("403"))
        XCTAssertTrue(OperatorToolsKnowledge.note.localizedCaseInsensitiveContains("human gate")
                      || OperatorToolsKnowledge.note.localizedCaseInsensitiveContains("approve"))
    }

    /// The note tells the agent which two variables its environment carries —
    /// the exact names `ClaudeCodeCLIRuntime` sets.
    func testNoteNamesTheEnvironmentVariablesItReliesOn() {
        XCTAssertTrue(OperatorToolsKnowledge.note.contains(ClaudeCodeCLIRuntime.operatorTokenVariable))
        XCTAssertTrue(OperatorToolsKnowledge.note.contains(ClaudeCodeCLIRuntime.controlURLVariable))
    }

    /// Every endpoint the note cites resolves to a real route — the note must
    /// never point an agent at a path this build doesn't answer.
    func testEveryNotedEndpointIsARealRoute() {
        for endpoint in notedEndpoints {
            XCTAssertNotNil(
                ControlRouter.match(method: endpoint.method, path: endpoint.path),
                "\(endpoint.method) \(endpoint.path) (cited as \(endpoint.citedAs)) is not a real route"
            )
        }
    }
}
