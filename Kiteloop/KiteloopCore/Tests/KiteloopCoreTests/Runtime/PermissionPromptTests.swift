import XCTest
@testable import KiteloopCore

/// The CLI's permission prompts as read off its stdout and answered on its
/// stdin. The lines here are the ones a 2.1.322 session wrote and accepted.
final class PermissionPromptTests: XCTestCase {

    private let bashRequest = """
    {"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Bash",\
    "display_name":"Bash","input":{"command":"touch probe.txt","description":"Create probe.txt"},\
    "description":"Create probe.txt","permission_suggestions":[\
    {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch probe.txt"}],"behavior":"allow","destination":"localSettings"},\
    {"type":"addDirectories","directories":["/tmp/work"],"destination":"session"},\
    {"type":"setMode","mode":"acceptEdits","destination":"session"},\
    {"type":"somethingNew","destination":"session"}],\
    "blocked_path":"/tmp/work/probe.txt","tool_use_id":"toolu_1"}}
    """

    private func request(_ line: String, file: StaticString = #filePath, lineNumber: UInt = #line) throws -> PermissionPrompt.Request {
        guard case .request(let request) = PermissionPrompt.line(line) else {
            XCTFail("not a request", file: file, line: lineNumber)
            throw CancellationError()
        }
        return request
    }

    private func object(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    // MARK: - Reading

    func testACallWaitingOnLeaveIsReadWithWhatItWouldDo() throws {
        let request = try request(bashRequest)
        XCTAssertEqual(request.id, "req-1")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.description, "Create probe.txt")
        XCTAssertEqual(request.blockedPath, "/tmp/work/probe.txt")
        XCTAssertEqual(request.toolUseID, "toolu_1")
        XCTAssertNil(request.subagentTaskID, "the agent's own call names no subagent")
        XCTAssertFalse(request.needsAnswer)
        XCTAssertEqual(try object(request.input)["command"] as? String, "touch probe.txt")
        XCTAssertEqual(PermissionPrompt.summary(of: request), "touch probe.txt",
                       "the command is what is decided on, not the model's description of it")
    }

    func testEachOfferIsPutIntoWordsAndAnOfferWithNoWordsIsNotMade() throws {
        let request = try request(bashRequest)
        XCTAssertEqual(request.suggestions.map(\.label), [
            "Always allow Bash(touch probe.txt) in this project",
            "Allow work in /tmp/work for this session",
            "Switch to Accept Edits for this session"
        ])
        XCTAssertEqual(try object(request.suggestions[0].json)["destination"] as? String, "localSettings",
                       "an offer goes back as the CLI wrote it")
    }

    func testASubagentsCallNamesItsTask() throws {
        let line = """
        {"type":"control_request","request_id":"req-2","request":{"subtype":"can_use_tool","tool_name":"Write",\
        "input":{"file_path":"/tmp/work/a.txt","content":"hi"},"tool_use_id":"toolu_2","agent_id":"task-9"}}
        """
        let request = try request(line)
        XCTAssertEqual(request.subagentTaskID, "task-9")
        XCTAssertEqual(PermissionPrompt.summary(of: request), "/tmp/work/a.txt")
        XCTAssertTrue(request.suggestions.isEmpty)
    }

    func testTheModelsOwnQuestionIsMarkedAsNeedingAnAnswer() throws {
        let line = """
        {"type":"control_request","request_id":"req-3","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion",\
        "input":{"questions":[{"question":"Tea or coffee?","header":"Drink","options":[],"multiSelect":false}]},\
        "tool_use_id":"toolu_3","requires_user_interaction":true}}
        """
        let request = try request(line)
        XCTAssertTrue(request.needsAnswer)
        XCTAssertEqual(PermissionPrompt.summary(of: request), "AskUserQuestion",
                       "a call with nothing to point at and no line from the CLI is named by its tool")
    }

    func testAQuestionTakenBackIsReadWithItsID() {
        XCTAssertEqual(PermissionPrompt.line(#"{"type":"control_cancel_request","request_id":"req-1"}"#),
                       .cancelled(requestID: "req-1"))
    }

    func testEveryOtherLineIsNoPrompt() {
        XCTAssertNil(PermissionPrompt.line(#"{"type":"assistant","message":{"content":[]}}"#))
        XCTAssertNil(PermissionPrompt.line(#"{"type":"control_response","response":{"subtype":"success","request_id":"x"}}"#),
                     "the session's answer to a request Kiteloop made is not a question")
        XCTAssertNil(PermissionPrompt.line(#"{"type":"control_request","request_id":"x","request":{"subtype":"hook_callback"}}"#),
                     "a request of another kind is not one this answers")
        XCTAssertNil(PermissionPrompt.line(#"{"type":"control_request""#), "half a line is not a prompt")
        XCTAssertNil(PermissionPrompt.line("\"control_ in the middle of prose"))
    }

    // MARK: - Writing

    private func response(_ decision: PermissionPrompt.Decision) throws -> [String: Any] {
        let line = PermissionPrompt.response(requestID: "req-1", decision: decision)
        XCTAssertTrue(line.hasSuffix("\n"), "the CLI reads its stdin a line at a time")
        let json = try object(line)
        XCTAssertEqual(json["type"] as? String, "control_response")
        let outer = try XCTUnwrap(json["response"] as? [String: Any])
        XCTAssertEqual(outer["subtype"] as? String, "success")
        XCTAssertEqual(outer["request_id"] as? String, "req-1")
        return try XCTUnwrap(outer["response"] as? [String: Any])
    }

    func testAllowingHandsTheInputBack() throws {
        let answer = try response(.allow(input: #"{"command":"touch probe.txt"}"#))
        XCTAssertEqual(answer["behavior"] as? String, "allow")
        XCTAssertEqual((answer["updatedInput"] as? [String: Any])?["command"] as? String, "touch probe.txt")
        XCTAssertNil(answer["updatedPermissions"], "an allow that remembers nothing says nothing about rules")
    }

    func testAllowingAndRememberingCarriesTheOfferBack() throws {
        let offer = try request(bashRequest).suggestions[0].json
        let answer = try response(.allow(input: "{}", remembering: [offer]))
        let remembered = try XCTUnwrap(answer["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(remembered.count, 1)
        XCTAssertEqual(remembered[0]["type"] as? String, "addRules")
        XCTAssertEqual((remembered[0]["rules"] as? [[String: Any]])?.first?["ruleContent"] as? String, "touch probe.txt")
    }

    func testRefusingCarriesWhatTheModelIsTold() throws {
        let answer = try response(.deny(message: PermissionPrompt.declined))
        XCTAssertEqual(answer["behavior"] as? String, "deny")
        XCTAssertEqual(answer["message"] as? String, PermissionPrompt.declined)
        XCTAssertNil(answer["updatedInput"])
    }

    func testTheModesThatPromiseToAskAreTheOnesThatAsk() {
        for mode in ["default", "acceptEdits", "plan"] {
            XCTAssertTrue(PermissionPrompt.asksBeforeListedTools(mode: mode), mode)
        }
        for mode in ["auto", "dontAsk", "bypassPermissions", ""] {
            XCTAssertFalse(PermissionPrompt.asksBeforeListedTools(mode: mode), mode)
        }
    }

    func testTheHostsOwnRequestsAreOneLineEach() throws {
        let mode = try object(PermissionPrompt.setMode("acceptEdits", requestID: "m-1"))
        XCTAssertEqual(mode["type"] as? String, "control_request")
        XCTAssertEqual(mode["request_id"] as? String, "m-1")
        XCTAssertEqual((mode["request"] as? [String: Any])?["subtype"] as? String, "set_permission_mode")
        XCTAssertEqual((mode["request"] as? [String: Any])?["mode"] as? String, "acceptEdits")

        let stop = try object(PermissionPrompt.stopTask("task-9", requestID: "s-1"))
        XCTAssertEqual((stop["request"] as? [String: Any])?["subtype"] as? String, "stop_task")
        XCTAssertEqual((stop["request"] as? [String: Any])?["task_id"] as? String, "task-9")
        XCTAssertTrue(PermissionPrompt.stopTask("task-9", requestID: "s-1").hasSuffix("\n"))
    }
}
