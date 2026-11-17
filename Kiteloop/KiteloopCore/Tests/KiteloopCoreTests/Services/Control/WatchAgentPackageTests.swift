import XCTest
import KiteloopTestSupport
@testable import KiteloopCore

/// The bundled Watch agent reads the control API and reports. Its profile names
/// the reads by hand, so these hold that list to the routing table — and hold
/// the package to reading only, since its token would let it do more.
final class WatchAgentPackageTests: XCTestCase {

    private let package = RepositoryRoot.of().appending(path: "Kiteloop/examples/agents/watch")

    private func text(_ file: String) throws -> String {
        try String(contentsOf: package.appending(path: file), encoding: .utf8)
    }

    /// Every `METHOD /path` a file cites, the query string left off.
    private func citations(in text: String) throws -> [(method: String, path: String)] {
        let pattern = try NSRegularExpression(pattern: #"\b(GET|POST|PUT|PATCH|DELETE) (/[A-Za-z0-9/{}._-]+)"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let method = Range(match.range(at: 1), in: text), let path = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[method]), String(text[path]))
        }
    }

    /// The route a citation names; a `{id}` segment stands for any value.
    private func route(_ citation: (method: String, path: String)) -> ControlRoute? {
        let concrete = citation.path.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return ControlRouter.match(method: citation.method, path: concrete)
    }

    func testTheProfileCitesOnlyReadsAndEveryOneIsInTheRoutingTable() throws {
        let cited = try citations(in: text("profile.md"))

        for citation in cited {
            XCTAssertEqual(citation.method, "GET", "the profile cites \(citation.method) \(citation.path)")
            XCTAssertNotNil(route(citation), "GET \(citation.path) is not in the routing table")
        }
        let paths = Set(cited.map(\.path))
        for read in ["/health", "/v1/attention", "/v1/spend", "/v1/spend/forecast",
                     "/v1/autopilot/sitting-summary", "/v1/events"] {
            XCTAssertTrue(paths.contains(read), "the profile does not name GET \(read)")
        }
    }

    func testTheProfileForbidsEverythingButReading() throws {
        let profile = try text("profile.md")

        for rule in ["Never call anything but `GET`", "Never change configuration",
                     "Never approve, reject, answer or land work", "Never start, stop or resume a run",
                     "Never send anything outside Kiteloop"] {
            XCTAssertTrue(profile.contains(rule), "the profile lost the rule: \(rule)")
        }
    }

    func testEveryEndpointTheBriefKnowledgeCitesIsInTheRoutingTable() throws {
        let cited = try citations(in: text("knowledge/daily-brief.md"))

        XCTAssertFalse(cited.isEmpty)
        for citation in cited {
            XCTAssertNotNil(route(citation), "\(citation.method) \(citation.path) is not in the routing table")
        }
    }

    /// The routine a person is shown is one the API would take, and it is off.
    func testTheRoutineTheKnowledgeOffersIsAValidOneLeftUnarmed() throws {
        let knowledge = try text("knowledge/daily-brief.md")
        let opening = try XCTUnwrap(knowledge.range(of: "```json\n"), "no routine body in the knowledge file")
        let closing = try XCTUnwrap(knowledge.range(of: "\n```", range: opening.upperBound..<knowledge.endIndex))
        let body = Data(knowledge[opening.upperBound..<closing.lowerBound].utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        let routine = try Routine.parse(json, id: "watch-daily-brief", existing: nil).get()

        XCTAssertFalse(routine.armed)
        XCTAssertTrue(routine.startsFresh)
        XCTAssertEqual(routine.trigger, Routine.Trigger(at: "08:30"))
        XCTAssertNil(routine.precheck)
        XCTAssertTrue(Set(json.keys).isSubset(of: ["name", "project", "agent", "prompt", "trigger", "conversation", "armed"]))
        XCTAssertTrue(knowledge.contains("PUT /v1/routines/\(routine.id)"))
    }

    /// The tool list is the package's whole scope: reading files, `curl`, and
    /// its own knowledge — nothing that edits, messages or reaches the web.
    func testThePackageGrantsOperatorToolsAndTheNarrowestToolList() throws {
        let data = try Data(contentsOf: package.appending(path: "agent.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let template = try XCTUnwrap(json["template"] as? [String: Any])

        XCTAssertEqual(template["operatorToolsEnabled"] as? Bool, true)
        XCTAssertEqual(template["tools"] as? [String], ["Read", "Bash", "recall_knowledge"])
        let denied = Set(try XCTUnwrap(template["denied"] as? [String]))
        XCTAssertTrue(denied.isSuperset(of: ["Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch"]))
        XCTAssertNil(template["mcpServers"])
    }
}
