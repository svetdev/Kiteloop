import XCTest
@testable import KiteloopMobile

final class ControlClientTests: XCTestCase {
    func testQueryPercentEncodesCharactersThatWouldSplitTheQuery() {
        let client = ControlClient(baseURL: "http://100.1.1.1:8787", token: "t")

        let result = client.query("/v1/projects/select", [("name", "a b&c=d#e")])

        XCTAssertEqual(result, "/v1/projects/select?name=a%20b%26c%3Dd%23e")
    }

    func testQueryJoinsMultipleParamsWithAmpersand() {
        let client = ControlClient(baseURL: "http://100.1.1.1:8787", token: "t")

        let result = client.query("/v1/backlog", [("project", "kiteloop"), ("state", "ready")])

        XCTAssertEqual(result, "/v1/backlog?project=kiteloop&state=ready")
    }

    func testRefusalTextIsTheReasonOfA409Body() {
        let error = ControlClient.ClientError.http(409, #"{"resolved":"not approved","reason":"merge conflict in: CHANGELOG.md"}"#)

        XCTAssertEqual(NowViewModel.refusalText(error), "merge conflict in: CHANGELOG.md")
    }

    func testRefusalTextFallsBackToTheErrorField() {
        let error = ControlClient.ClientError.http(403, #"{"error":"the human gate takes the operator's own token"}"#)

        XCTAssertEqual(NowViewModel.refusalText(error), "the human gate takes the operator's own token")
    }

    func testRefusalTextReturnsANonJSONBodyAsWritten() {
        let error = ControlClient.ClientError.http(502, "Bad Gateway")

        XCTAssertEqual(NowViewModel.refusalText(error), "Bad Gateway")
    }

    func testDiffFailureOnA404IsNoBranch() {
        let error = ControlClient.ClientError.http(404, #"{"error":"no branch for item"}"#)

        guard case .noBranch = NowViewModel.diffFailure(error) else { return XCTFail("a 404 is no branch") }
    }

    func testDiffFailureOnA409CarriesItsReason() {
        let error = ControlClient.ClientError.http(409, #"{"reason":"project not open"}"#)

        guard case .failed(let reason) = NowViewModel.diffFailure(error) else { return XCTFail("a 409 is a failed fetch") }
        XCTAssertEqual(reason, "project not open")
    }

    func testDiffFailureOnATransportErrorCarriesItsDescription() {
        let error = URLError(.timedOut)

        guard case .failed(let reason) = NowViewModel.diffFailure(error) else { return XCTFail("a transport error is a failed fetch") }
        XCTAssertEqual(reason, error.localizedDescription)
    }

    func testApprovalBodyForARejectionWithAReasonCarriesItTrimmed() {
        let body = NowViewModel.approvalBody(project: "kiteloop", item: "x", approve: false, reason: "  tests missing \n")

        XCTAssertEqual(body["reason"] as? String, "tests missing")
        XCTAssertEqual(body["approve"] as? Bool, false)
        XCTAssertEqual(body["project"] as? String, "kiteloop")
        XCTAssertEqual(body["item"] as? String, "x")
    }

    func testApprovalBodyForARejectionWithABlankReasonHasNoReasonKey() {
        let body = NowViewModel.approvalBody(project: "kiteloop", item: "x", approve: false, reason: " \n\t")

        XCTAssertNil(body["reason"])
        XCTAssertEqual(body["approve"] as? Bool, false)
    }

    func testApprovalBodyForAnApprovalNeverHasAReason() {
        let body = NowViewModel.approvalBody(project: "kiteloop", item: "x", approve: true, reason: "looks good")

        XCTAssertNil(body["reason"])
        XCTAssertEqual(body["approve"] as? Bool, true)
    }
}
