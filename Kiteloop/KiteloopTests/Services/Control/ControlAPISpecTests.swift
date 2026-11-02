import XCTest
import KiteloopCore
@testable import Kiteloop

/// The documented shape of `/v1/autopilot`, checked against the field names
/// `KiteloopControlServer` actually reads and writes
/// (`KiteloopControlServer.autopilotConfigFieldNames`) — so a field the
/// server serves or accepts with nothing said about it here, or a described
/// field the server has stopped reading, is a drift the generated OpenAPI
/// document would otherwise carry silently.
///
/// Covers the autonomy dial (`autonomy`) and the one budget (`budgetUSD`),
/// and the three switches `autonomy` deprecates rather than removes: the
/// document still describes `autonomousWorkEnabled`, `approveReviewPassedRuns`
/// and `autoMergeOnApproval`, one release after the dial replaced them as the
/// decision a person makes. `stallTimeoutMinutes` and
/// `autoMergeVerifyTimeoutMinutes` are unrelated to either consolidation —
/// still plain, settable stored settings — and stay documented as such.
final class ControlAPISpecTests: XCTestCase {

    // MARK: - The backlog lane

    /// The lane is described with exactly the values the model has, on the
    /// listing's item and on the endpoint that flips it — a lane added to
    /// `BacklogLane` and not to the document would be one a driver cannot send.
    func testTheLaneIsDocumentedAsTheModelsTwoValues() throws {
        let lanes = BacklogLane.allCases.map(\.rawValue)
        let item = try XCTUnwrap(schemas()["BacklogItem"] as? [String: Any])
        let itemLane = try XCTUnwrap((item["properties"] as? [String: Any])?["lane"] as? [String: Any])
        XCTAssertEqual(itemLane["enum"] as? [String], lanes)
        XCTAssertTrue((item["required"] as? [String] ?? []).contains("lane"))

        let body = try bodySchema(of: try operation("post", "/v1/backlog/lane"))
        let bodyLane = try XCTUnwrap((body["properties"] as? [String: Any])?["lane"] as? [String: Any])
        XCTAssertEqual(bodyLane["enum"] as? [String], lanes)
        XCTAssertEqual(body["required"] as? [String], ["project", "lane"])

        let result = try XCTUnwrap(schemas()["ItemLane"] as? [String: Any])
        XCTAssertEqual(result["required"] as? [String], ["item", "was", "lane", "changed"])
    }

    // MARK: - The response shape (GET/PUT/reset all share it)

    /// Every field the server actually serves is described in
    /// `AutopilotConfig`, and every field described there is one the server
    /// actually serves — the two can't drift apart the way an
    /// eighteen-setting page and its doc once could.
    func testAutopilotConfigSchemaMatchesTheFieldsTheServerServes() throws {
        let schema = try XCTUnwrap(schemas()["AutopilotConfig"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(KiteloopControlServer.autopilotConfigFieldNames))
    }

    /// The dial is documented as an enum of exactly its three positions.
    func testAutonomyIsDocumentedAsTheThreePositionEnum() throws {
        let schema = try XCTUnwrap(schemas()["AutopilotConfig"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let autonomy = try XCTUnwrap(properties["autonomy"] as? [String: Any])
        XCTAssertEqual(autonomy["enum"] as? [String], ["off", "propose", "land"])
    }

    /// The one budget is nullable — nil defers to the portfolio's own ceiling.
    /// JSON Schema 2020-12 states that as a type union, not a flag.
    func testBudgetUSDIsDocumentedAsNullable() throws {
        let schema = try XCTUnwrap(schemas()["AutopilotConfig"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let budget = try XCTUnwrap(properties["budgetUSD"] as? [String: Any])
        XCTAssertEqual(budget["type"] as? [String], ["number", "null"])
    }

    /// The four settings the budget replaced are gone from the documented
    /// shape, not merely undescribed — a driver reading this schema learns
    /// they no longer exist rather than guessing why they're undocumented.
    func testTheFourReplacedBudgetSettingsAreNotInTheSchema() throws {
        let schema = try XCTUnwrap(schemas()["AutopilotConfig"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        for removed in ["perItemCostCapUSD", "sessionCostCapUSD", "costCapMargin", "dailyBudgetUSD"] {
            XCTAssertNil(properties[removed], "\(removed) should have been replaced by budgetUSD")
        }
    }

    // MARK: - The request body (PUT accepts more than GET/reset ever answer with)

    /// `PUT` accepts the dial, the budget, and — for one release — the fields
    /// they deprecate: a body naming only the old switches must still resolve
    /// to a real property somewhere in the request schema.
    func testSetAutopilotAcceptsBothTheDialAndTheDeprecatedSwitches() throws {
        let body = try bodySchema(of: try operation("put", "/v1/autopilot"))
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        for field in ["autonomy", "approvalGate", "autonomousWorkEnabled", "approveReviewPassedRuns", "autoMergeOnApproval"] {
            XCTAssertNotNil(properties[field], "PUT /v1/autopilot should still accept \(field)")
        }
    }

    /// `PUT` accepts `budgetUSD`, and no longer documents the four settings it
    /// replaced.
    func testSetAutopilotAcceptsBudgetUSDNotTheFourItReplaced() throws {
        let body = try bodySchema(of: try operation("put", "/v1/autopilot"))
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertNotNil(properties["budgetUSD"])
        for removed in ["perItemCostCapUSD", "sessionCostCapUSD", "costCapMargin", "dailyBudgetUSD"] {
            XCTAssertNil(properties[removed])
        }
    }

    /// `stallTimeoutMinutes` and `autoMergeVerifyTimeoutMinutes` are ordinary,
    /// still-written settings — untouched by either consolidation — so `PUT`
    /// documents them as real fields, not tolerated-and-ignored ones.
    func testSetAutopilotStillAcceptsTheTwoTimeouts() throws {
        let body = try bodySchema(of: try operation("put", "/v1/autopilot"))
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertNotNil(properties["stallTimeoutMinutes"])
        XCTAssertNotNil(properties["autoMergeVerifyTimeoutMinutes"])
    }

    /// `project` is the only field a `PUT` must carry — everything else,
    /// dial and deprecated switches alike, is optional and left unchanged
    /// when omitted.
    func testOnlyProjectIsRequiredOnSetAutopilot() throws {
        let body = try bodySchema(of: try operation("put", "/v1/autopilot"))
        XCTAssertEqual(body["required"] as? [String], ["project"])
    }

    // MARK: - Reading the document

    private func document() -> [String: Any] {
        ControlAPISpec.document(version: "1.2.3", port: 4517)
    }

    private func schemas() throws -> [String: Any] {
        let components = try XCTUnwrap(document()["components"] as? [String: Any])
        return try XCTUnwrap(components["schemas"] as? [String: Any])
    }

    private func operation(_ method: String, _ path: String) throws -> [String: Any] {
        let paths = try XCTUnwrap(document()["paths"] as? [String: Any])
        let item = try XCTUnwrap(paths[path] as? [String: Any], "no path item for \(path)")
        return try XCTUnwrap(item[method] as? [String: Any], "no \(method.uppercased()) operation at \(path)")
    }

    private func bodySchema(of operation: [String: Any]) throws -> [String: Any] {
        let requestBody = try XCTUnwrap(operation["requestBody"] as? [String: Any])
        let content = try XCTUnwrap(requestBody["content"] as? [String: Any])
        let json = try XCTUnwrap(content["application/json"] as? [String: Any])
        return try XCTUnwrap(json["schema"] as? [String: Any])
    }
}
