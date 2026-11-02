import XCTest
@testable import Kiteloop

final class StreamEventPermissionTests: XCTestCase {
    func testResultWithPermissionDenials() throws {
        let json = """
        {"type":"result","result":"Done","total_cost_usd":0.01,"duration_ms":500,"usage":{"input_tokens":200,"output_tokens":50},"session_id":"sess-1","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}]}
        """
        let event = try StreamEvent.parse(json)
        guard case .result(let payload) = event else {
            XCTFail("Expected result event"); return
        }
        XCTAssertEqual(payload.permissionDenials.count, 1)
        XCTAssertEqual(payload.permissionDenials[0].toolName, "Bash")
        XCTAssertEqual(payload.permissionDenials[0].detail, "rm -rf /")
    }

    func testFilePathDenialDetailExtracted() throws {
        let json = """
        {"type":"result","result":"","total_cost_usd":0.0,"duration_ms":100,"usage":{},"session_id":"","permission_denials":[{"tool_name":"Edit","tool_input":{"file_path":"/etc/passwd"}}]}
        """
        let event = try StreamEvent.parse(json)
        guard case .result(let payload) = event else {
            XCTFail("Expected result event"); return
        }
        XCTAssertEqual(payload.permissionDenials[0].toolName, "Edit")
        XCTAssertEqual(payload.permissionDenials[0].detail, "/etc/passwd")
    }

    func testEmptyPermissionDenialsArray() throws {
        let json = """
        {"type":"result","result":"OK","total_cost_usd":0.001,"duration_ms":200,"usage":{"input_tokens":50,"output_tokens":10},"session_id":"s1","permission_denials":[]}
        """
        let event = try StreamEvent.parse(json)
        guard case .result(let payload) = event else {
            XCTFail("Expected result event"); return
        }
        XCTAssertTrue(payload.permissionDenials.isEmpty)
    }

    func testMissingPermissionDenialsFieldDefaultsToEmpty() throws {
        let json = """
        {"type":"result","result":"OK","total_cost_usd":0.001,"duration_ms":200,"usage":{"input_tokens":50,"output_tokens":10},"session_id":"s1"}
        """
        let event = try StreamEvent.parse(json)
        guard case .result(let payload) = event else {
            XCTFail("Expected result event"); return
        }
        XCTAssertTrue(payload.permissionDenials.isEmpty)
    }
}
