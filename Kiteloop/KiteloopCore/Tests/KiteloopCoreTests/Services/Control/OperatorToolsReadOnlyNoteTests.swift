import XCTest
@testable import KiteloopCore

/// `OperatorToolsKnowledge.readOnlyNote` — what an agent spawned with the read
/// token is told. It must name every read that token can make and not one
/// call it would be refused, both read off the routing table.
final class OperatorToolsReadOnlyNoteTests: XCTestCase {

    private let note = OperatorToolsKnowledge.readOnlyNote

    /// Every `METHOD $KITELOOP_CONTROL_URL/path` the note cites.
    private func citedMethods() throws -> [String] {
        let pattern = try NSRegularExpression(pattern: #"\b(GET|POST|PUT|PATCH|DELETE) \$KITELOOP_CONTROL_URL"#)
        return pattern.matches(in: note, range: NSRange(note.startIndex..., in: note)).compactMap { match in
            Range(match.range(at: 1), in: note).map { String(note[$0]) }
        }
    }

    func testTheNoteCitesNothingButGETs() throws {
        let methods = try citedMethods()

        XCTAssertFalse(methods.isEmpty)
        XCTAssertEqual(Set(methods), ["GET"])
    }

    func testEveryListedEndpointIsAGETTheReadScopeAllows() {
        XCTAssertFalse(OperatorToolsKnowledge.readOnlyEndpoints.isEmpty)
        for endpoint in OperatorToolsKnowledge.readOnlyEndpoints {
            let citation = OperatorToolsKnowledge.citation(endpoint)
            XCTAssertEqual(endpoint.method, "GET", citation)
            XCTAssertNil(ControlAccess.refusal(of: .scoped(.read), calling: endpoint.route, as: citation), citation)
            XCTAssertTrue(note.contains("- `\(citation)` — "), "the note does not list \(citation)")
        }
    }

    /// The other direction: a read the operator note lists is in this one too,
    /// unless the read scope is refused it.
    func testEveryReadTheOperatorNoteListsIsHereUnlessTheReadScopeIsRefusedIt() {
        for endpoint in ControlRouter.endpoints where endpoint.method == "GET" {
            let citation = OperatorToolsKnowledge.citation(endpoint)
            let listedForOperator = OperatorToolsKnowledge.exclusionReason(for: endpoint.route) == nil
            let allowed = ControlAccess.refusal(of: .scoped(.read), calling: endpoint.route, as: citation) == nil
            XCTAssertEqual(note.contains("- `\(citation)` — "), listedForOperator && allowed, citation)
        }
    }

    func testTheNoteListsNoEndpointTheOperatorNoteAddsForChanges() {
        for endpoint in ControlRouter.endpoints where endpoint.method != "GET" {
            XCTAssertFalse(note.contains("`\(OperatorToolsKnowledge.citation(endpoint))`"),
                           "\(endpoint.method) \(endpoint.path) is in the read-only note")
        }
    }

    func testTheNoteSaysTheTokenOnlyReadsAndNamesTheVariablesItArrivesIn() {
        XCTAssertTrue(note.contains("read-only"))
        XCTAssertTrue(note.contains("403"))
        XCTAssertTrue(note.contains("KITELOOP_OPERATOR_TOKEN"))
        XCTAssertTrue(note.contains("KITELOOP_CONTROL_URL"))
        XCTAssertTrue(note.contains("`GET $KITELOOP_CONTROL_URL/openapi.json` — "))
        XCTAssertFalse(note.contains("$KITELOOP_CONTROL_URL/v1"))
    }

    /// The agent that keeps the operator token is told what it was told before.
    func testTheOperatorNoteStillListsTheCallsThatChangeThings() {
        XCTAssertTrue(OperatorToolsKnowledge.note.contains("`POST $KITELOOP_CONTROL_URL/runs`"))
        XCTAssertNotEqual(OperatorToolsKnowledge.note, note)
    }
}
