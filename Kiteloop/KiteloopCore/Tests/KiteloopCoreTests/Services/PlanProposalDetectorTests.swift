import XCTest
@testable import KiteloopCore

final class PlanProposalDetectorTests: XCTestCase {
    private let plans = URL(filePath: "/Users/someone/.claude/plans", directoryHint: .isDirectory)

    private func write(_ path: String, _ content: String) throws -> Message {
        let input = try JSONSerialization.data(withJSONObject: ["file_path": path, "content": content])
        return .toolCall(Message.ToolCall(id: UUID().uuidString, name: "Write",
                                          input: String(decoding: input, as: UTF8.self)), agent: "a")
    }

    private func edit(_ path: String, _ old: String, _ new: String, replaceAll: Bool = false) throws -> Message {
        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": path, "old_string": old, "new_string": new, "replace_all": replaceAll,
        ] as [String: Any])
        return .toolCall(Message.ToolCall(id: UUID().uuidString, name: "Edit",
                                          input: String(decoding: input, as: UTF8.self)), agent: "a")
    }

    private func multiEdit(_ path: String, _ edits: [(old: String, new: String)]) throws -> Message {
        let input = try JSONSerialization.data(withJSONObject: [
            "file_path": path,
            "edits": edits.map { ["old_string": $0.old, "new_string": $0.new] },
        ] as [String: Any])
        return .toolCall(Message.ToolCall(id: UUID().uuidString, name: "MultiEdit",
                                          input: String(decoding: input, as: UTF8.self)), agent: "a")
    }

    private func plan(_ messages: [Message], base: String? = nil) -> String? {
        PlanProposalDetector.plan(in: messages, permissionMode: "plan", plansDirectory: plans, basePlan: base)
    }

    func testTheLastWriteUnderThePlansDirectoryIsThePlan() throws {
        let messages = [
            try write("/Users/someone/.claude/plans/x.md", "# Draft"),
            .agentText("thinking it over", agent: "a"),
            try write("/Users/someone/.claude/plans/x.md", "# Plan\n\n1. Build it"),
        ]
        XCTAssertEqual(PlanProposalDetector.plan(in: messages, permissionMode: "plan", plansDirectory: plans),
                       "# Plan\n\n1. Build it")
    }

    func testAnAgentOutsidePlanModeHasNoPlan() throws {
        let messages = [try write("/Users/someone/.claude/plans/x.md", "# Plan")]
        XCTAssertNil(PlanProposalDetector.plan(in: messages, permissionMode: "auto", plansDirectory: plans))
    }

    func testAWriteElsewhereIsNoPlan() throws {
        let messages = [
            try write("/Users/someone/project/plan.md", "# Not a plan"),
            try write("/Users/someone/.claude/plans-old/x.md", "# Nor this"),
            try write("/Users/someone/.claude/plans/../settings.json", "{}"),
        ]
        XCTAssertNil(PlanProposalDetector.plan(in: messages, permissionMode: "plan", plansDirectory: plans))
    }

    func testAnEditUnderThePlansDirectoryIsNoPlan() {
        let edit = Message.toolCall(Message.ToolCall(
            id: "e", name: "Edit",
            input: ##"{"file_path":"/Users/someone/.claude/plans/x.md","content":"# Plan"}"##), agent: "a")
        XCTAssertNil(PlanProposalDetector.plan(in: [edit], permissionMode: "plan", plansDirectory: plans))
    }

    // MARK: - Edits

    private let path = "/Users/someone/.claude/plans/x.md"

    func testAWriteThenAnEditIsTheEditedPlan() throws {
        let messages = [try write(path, "# Plan\n\n1. Use JSON"), try edit(path, "JSON", "SQLite")]
        XCTAssertEqual(plan(messages), "# Plan\n\n1. Use SQLite")
    }

    func testAnEditOnlyTurnRevisesTheBasePlan() throws {
        XCTAssertEqual(plan([try edit(path, "JSON", "SQLite")], base: "# Plan\n\n1. Use JSON"),
                       "# Plan\n\n1. Use SQLite")
    }

    func testAWriteReplacesTheBasePlan() throws {
        XCTAssertEqual(plan([try write(path, "# New")], base: "# Old"), "# New")
    }

    func testMultiEditAppliesItsEditsInOrder() throws {
        let messages = [try multiEdit(path, [("JSON", "SQLite"), ("SQLite", "SQLite with WAL")])]
        XCTAssertEqual(plan(messages, base: "1. Use JSON"), "1. Use SQLite with WAL")
    }

    func testReplaceAllReplacesEveryOccurrence() throws {
        let messages = [try edit(path, "JSON", "SQLite", replaceAll: true)]
        XCTAssertEqual(plan(messages, base: "1. JSON\n2. JSON again"), "1. SQLite\n2. SQLite again")
    }

    func testANonUniqueOldStringWithoutReplaceAllDoesNotApply() throws {
        XCTAssertNil(plan([try edit(path, "JSON", "SQLite")], base: "1. JSON\n2. JSON again"))
    }

    func testAnEditWhoseOldStringIsMissingKeepsTheLastAppliedText() throws {
        let messages = [try write(path, "# Plan\n\n1. Use JSON"), try edit(path, "YAML", "SQLite")]
        XCTAssertEqual(plan(messages), "# Plan\n\n1. Use JSON")
    }

    func testAnEditWhoseOldStringIsMissingFromTheBaseIsNoPlan() throws {
        XCTAssertNil(plan([try edit(path, "YAML", "SQLite")], base: "# Plan\n\n1. Use JSON"))
    }

    func testAnEditWithNoBasePlanIsNoPlan() throws {
        XCTAssertNil(plan([try edit(path, "JSON", "SQLite")]))
    }

    func testAMultiEditWithAMissingEntryAppliesNoneOfIt() throws {
        let messages = [try multiEdit(path, [("JSON", "SQLite"), ("YAML", "TOML")])]
        XCTAssertNil(plan(messages, base: "1. Use JSON"))
    }

    func testAnEditOutsideThePlansDirectoryIsIgnored() throws {
        let messages = [try edit("/Users/someone/project/plan.md", "JSON", "SQLite")]
        XCTAssertNil(plan(messages, base: "1. Use JSON"))
    }

    func testAnEditOutsidePlanModeIsNoPlan() throws {
        let messages = [try edit(path, "JSON", "SQLite")]
        XCTAssertNil(PlanProposalDetector.plan(in: messages, permissionMode: "auto",
                                               plansDirectory: plans, basePlan: "1. Use JSON"))
    }
}
