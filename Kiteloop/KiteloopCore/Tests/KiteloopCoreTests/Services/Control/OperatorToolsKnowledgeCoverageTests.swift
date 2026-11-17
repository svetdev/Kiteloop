import XCTest
@testable import KiteloopCore

/// `OperatorToolsKnowledge.note` tells an agent with operator tools every
/// endpoint it may call. These walk the routing table itself, so a row added to
/// `ControlRouter.table` fails here until the note lists it or a named exclusion
/// covers it.
final class OperatorToolsKnowledgeCoverageTests: XCTestCase {

    private let note = OperatorToolsKnowledge.note

    /// The line the note lists an endpoint on, up to its summary.
    private func listing(_ endpoint: ControlRouter.Endpoint) -> String {
        "- `\(OperatorToolsKnowledge.citation(endpoint))` — "
    }

    func testEveryEndpointIsListedOrExcludedForANamedReason() {
        for endpoint in ControlRouter.endpoints {
            let excluded = OperatorToolsKnowledge.exclusionReason(for: endpoint.route) != nil
            let gatedOrUnauthenticated = endpoint.route.isHumanGate || !endpoint.requiresAuth
            XCTAssertTrue(note.contains(listing(endpoint)) || excluded,
                          "\(endpoint.method) \(endpoint.path) is neither in the note nor excluded")
            XCTAssertFalse(gatedOrUnauthenticated && !excluded,
                           "\(endpoint.method) \(endpoint.path) must be excluded")
            XCTAssertFalse(excluded && note.contains(listing(endpoint)),
                           "\(endpoint.method) \(endpoint.path) is excluded yet listed")
        }
    }

    func testEachListedEndpointCarriesItsSummaryFromTheSpec() {
        for endpoint in ControlRouter.endpoints where OperatorToolsKnowledge.exclusionReason(for: endpoint.route) == nil {
            let line = listing(endpoint) + ControlAPISpec.summary(for: endpoint.route) + "\n"
            XCTAssertTrue((note + "\n").contains(line), "no spec summary on \(endpoint.method) \(endpoint.path)")
        }
    }

    func testTheOnlyRoutesLeftOutBesidesGatesAndTokensAreThePhonesOwn() {
        let leftOut = ControlRouter.endpoints.map(\.route).filter {
            OperatorToolsKnowledge.exclusionReason(for: $0) != nil
                && !$0.isHumanGate && $0.requiresAuth && !$0.isTokenManagement
        }
        XCTAssertEqual(leftOut, [.registerPushDevice, .registerLiveActivity])
    }

    func testManagementAgentAndRoutineEndpointsAreListed() {
        let wanted = ControlRouter.endpoints.filter {
            switch $0.route {
            case .manage, .updateAgent, .removeAgent, .listRoutines, .putRoutine,
                 .deleteRoutine, .runRoutine, .listRoutineRuns:
                return true
            default:
                return false
            }
        }
        XCTAssertGreaterThan(wanted.filter { if case .manage = $0.route { return true } else { return false } }.count, 20)
        for endpoint in wanted {
            XCTAssertTrue(note.contains(listing(endpoint)), "\(endpoint.method) \(endpoint.path) is not listed")
        }
    }

    func testHumanGatesAppearOnlyInTheParagraphThatSaysTheyAnswer403() {
        let gates = ControlRouter.endpoints.filter(\.route.isHumanGate)
        XCTAssertEqual(gates.count, 3)
        let paragraphs = note.components(separatedBy: "\n\n")
        for gate in gates {
            let citation = "`\(OperatorToolsKnowledge.citation(gate))`"
            let citing = paragraphs.filter { $0.contains(citation) }
            XCTAssertEqual(citing.count, 1, "\(citation) should be cited exactly once")
            XCTAssertTrue(citing.allSatisfy { $0.contains("403") && $0.contains("human gate") })
        }
        XCTAssertTrue(note.contains("`POST $KITELOOP_CONTROL_URL/backlog/land`"))
    }

    func testPathsAreRelativeToABaseURLEndingInV1() {
        XCTAssertTrue(note.contains("KITELOOP_OPERATOR_TOKEN"))
        XCTAssertTrue(note.contains("KITELOOP_CONTROL_URL"))
        XCTAssertFalse(note.contains("$KITELOOP_CONTROL_URL/v1"))
        XCTAssertTrue(note.contains("`GET $KITELOOP_CONTROL_URL/openapi.json` — "))
    }
}
