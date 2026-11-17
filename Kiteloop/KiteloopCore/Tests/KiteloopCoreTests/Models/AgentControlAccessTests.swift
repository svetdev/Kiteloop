import XCTest
@testable import KiteloopCore

/// `controlAccess` — the key an agent package and an agent carry to say which
/// control API credential Operator tools hands over.
final class AgentControlAccessTests: XCTestCase {

    private struct Template: Decodable {
        let controlAccess: AgentControlAccess?
    }

    private func decode(_ json: String) throws -> AgentControlAccess? {
        try JSONDecoder().decode(Template.self, from: Data(json.utf8)).controlAccess
    }

    func testTheKeyDecodesItsTwoValues() throws {
        XCTAssertEqual(try decode(#"{"controlAccess": "read"}"#), .readOnly)
        XCTAssertEqual(try decode(#"{"controlAccess": "operator"}"#), .operatorToken)
    }

    /// A package or an agent written before the key existed has none, and
    /// keeps the operator token it was given then.
    func testAnAbsentOrNullKeyIsLeftToTheDefaultWhichIsTheOperatorToken() throws {
        XCTAssertNil(try decode("{}"))
        XCTAssertNil(try decode(#"{"controlAccess": null}"#))
        XCTAssertEqual(AgentControlAccess.whenUnstated, .operatorToken)
    }

    func testAValueThisBuildDoesNotKnowDecodesAsReadOnly() throws {
        XCTAssertEqual(try decode(#"{"controlAccess": "raed"}"#), .readOnly)
        XCTAssertEqual(try decode(#"{"controlAccess": "Read"}"#), .readOnly)
    }

    func testItEncodesAsTheWordThePackageUses() throws {
        let encoded = try JSONEncoder().encode([AgentControlAccess.readOnly, .operatorToken])
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #"["read","operator"]"#)
    }

    func testAReadOnlyAgentIsHandedTheReadTokenAndNeverTheOperatorToken() {
        var operatorTokenReads = 0
        let operatorToken = { operatorTokenReads += 1; return "operator-secret" }

        XCTAssertEqual(AgentControlAccess.readOnly.token(operatorToken: operatorToken, readToken: { "read-secret" }),
                       "read-secret")
        XCTAssertNil(AgentControlAccess.readOnly.token(operatorToken: operatorToken, readToken: { nil }),
                     "no read token is no credential, not the operator token")
        XCTAssertEqual(operatorTokenReads, 0)

        XCTAssertEqual(AgentControlAccess.operatorToken.token(operatorToken: operatorToken, readToken: { "read-secret" }),
                       "operator-secret")
    }

    func testEachAccessGetsItsOwnNote() {
        XCTAssertEqual(AgentControlAccess.operatorToken.note(operatorNote: "all", readOnlyNote: "reads"), "all")
        XCTAssertEqual(AgentControlAccess.readOnly.note(operatorNote: "all", readOnlyNote: "reads"), "reads")
    }
}
