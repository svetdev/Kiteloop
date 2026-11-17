import XCTest
@testable import KiteloopCore

/// What `GET /v1/config-changes` and `GET /v1/config-changes/{id}` answer:
/// each state by name, the approved call's own status and body, and nothing
/// of the request beyond the redacted summary the card shows.
final class ConfigChangeReportTests: XCTestCase {

    private let asked = Date(timeIntervalSince1970: 1_700_000_000)

    private func change(project: HeldConfigChange.Project? = nil, summary: String = "defaultModel=opus") -> HeldConfigChange {
        HeldConfigChange(id: "c1", caller: "ci (configure)", asker: "token:1", route: "PUT /v1/settings",
                         summary: summary, project: project, askedAt: asked)
    }

    private func json(_ state: ConfigChangeOutcome.State) -> [String: Any] {
        ConfigChangeReport.json(ConfigChangeOutcome(change: change(), state: state))
    }

    func testAWaitingChangeSaysWhoAskedForWhatAndCarriesNoResponse() {
        let project = HeldConfigChange.Project(id: "p1", name: "site", path: "/work/site")
        let waiting = ConfigChangeReport.json(ConfigChangeOutcome(change: change(project: project), state: .waiting))

        XCTAssertEqual(waiting["id"] as? String, "c1")
        XCTAssertEqual(waiting["state"] as? String, "waiting")
        XCTAssertEqual(waiting["caller"] as? String, "ci (configure)")
        XCTAssertEqual(waiting["route"] as? String, "PUT /v1/settings")
        XCTAssertEqual(waiting["summary"] as? String, "defaultModel=opus")
        XCTAssertEqual(waiting["project"] as? String, "site")
        XCTAssertEqual(waiting["askedAt"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertTrue(waiting["response"] is NSNull)
        XCTAssertTrue(waiting["reason"] is NSNull)
        XCTAssertNil(waiting["asker"], "the key that tells credentials apart is not handed out")
    }

    func testAnApprovedChangeCarriesTheStatusAndBodyItsCallAnswered() throws {
        let applied = ConfigChangeOutcome.Applied(status: 200, headers: ["Content-Type": "application/json"],
                                                  body: Data(#"{"defaultModel":"opus"}"#.utf8))

        let approved = json(.approved(applied))

        XCTAssertEqual(approved["state"] as? String, "approved")
        let response = try XCTUnwrap(approved["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? Int, 200)
        XCTAssertEqual(response["body"] as? [String: String], ["defaultModel": "opus"])
    }

    /// A handler that answered an error is reported as it answered.
    func testAnApprovedChangeWhoseCallFailedCarriesThatAnswer() throws {
        let refused = ConfigChangeOutcome.Applied(status: 400, body: Data(#"{"error":"unknown model"}"#.utf8))

        let response = try XCTUnwrap(json(.approved(refused))["response"] as? [String: Any])

        XCTAssertEqual(response["status"] as? Int, 400)
        XCTAssertEqual(response["body"] as? [String: String], ["error": "unknown model"])
    }

    func testABodyThatIsNotJSONIsCarriedAsText() throws {
        let plain = ConfigChangeOutcome.Applied(status: 200, body: Data("done".utf8))

        let response = try XCTUnwrap(json(.approved(plain))["response"] as? [String: Any])

        XCTAssertEqual(response["body"] as? String, "done")
    }

    func testAnApprovalStillBeingAppliedHasNoResponseYet() {
        let applying = json(.approved(nil))

        XCTAssertEqual(applying["state"] as? String, "approved")
        XCTAssertTrue(applying["response"] is NSNull)
    }

    func testDeclinedAndUnrecordedSayNothingApplied() {
        XCTAssertEqual(json(.declined)["state"] as? String, "declined")
        XCTAssertTrue(json(.declined)["response"] is NSNull)

        let unrecorded = json(.unrecorded("the disk is full"))
        XCTAssertEqual(unrecorded["state"] as? String, "unrecorded")
        XCTAssertTrue(unrecorded["response"] is NSNull)
        XCTAssertEqual(unrecorded["reason"] as? String,
                       "approved, but the decision could not be written to the change log, so nothing was changed: the disk is full")
    }

    /// The payload carries the summary the card shows — already redacted —
    /// and nothing else of the request.
    func testTheRequestIsReportedOnlyAsItsRedactedSummary() throws {
        let body = Data(#"{"command":"npx","env":{"TRACKER_TOKEN":"s3cret-value"}}"#.utf8)
        let summary = ConfigChangeSummary.text(query: [:], body: body)
        let outcome = ConfigChangeOutcome(change: change(summary: summary), state: .waiting)

        let written = try JSONSerialization.data(withJSONObject: ConfigChangeReport.json(outcome))

        let text = String(decoding: written, as: UTF8.self)
        XCTAssertFalse(text.contains("s3cret-value"))
        XCTAssertTrue(text.contains("TRACKER_TOKEN"))
    }

    func testTheListCountsAndKeepsTheOrderItIsGiven() {
        let first = ConfigChangeOutcome(change: change(), state: .declined)
        let second = ConfigChangeOutcome(
            change: HeldConfigChange(id: "c2", caller: "operator", route: "PUT /v1/autopilot", summary: "",
                                     project: nil, askedAt: asked), state: .waiting)

        let list = ConfigChangeReport.list([first, second])

        XCTAssertEqual(list["count"] as? Int, 2)
        XCTAssertEqual((list["changes"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["c1", "c2"])
        XCTAssertEqual((list["changes"] as? [[String: Any]])?.compactMap { $0["state"] as? String }, ["declined", "waiting"])
    }
}
