import XCTest
import KiteloopCore
@testable import Kiteloop

/// The activity ticker and the transcript's tool rows used to print the
/// arguments of a call — forty or eighty characters of shell, cut mid-token —
/// while the sentence saying what the call was for sat unread in the same JSON
/// object. These assert that the sentence is what shows now, that a call
/// carrying none reads as it always did, and that the command is still on the
/// row beside it.
@MainActor
final class ChatViewModelActivityLabelTests: XCTestCase {

    private var vm: ChatViewModel!
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = try makeTemporaryDirectory(prefix: "kiteloop-activity-label")

        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(
            id: "worker", name: "Worker", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        vm = ChatViewModel(agentID: "worker", projectURL: tmpDir, orchestrator: orchestrator)
    }

    override func tearDownWithError() throws {
        vm = nil
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - The ticker

    func testBashShowsItsDescriptionRatherThanTheCommand() {
        let activity = vm.activityLabel(tool: "Bash", input: json([
            "command": "cat ~/.kiteloop/global-config.json | head -100",
            "description": "Read Kiteloop global config for registered projects"
        ]))

        XCTAssertEqual(activity.label, "Bash · Read Kiteloop global config for registered projects")
    }

    func testBashKeepsTheCommandBesideTheDescription() {
        let command = "cat ~/.kiteloop/global-config.json | head -100"
        let activity = vm.activityLabel(tool: "Bash", input: json([
            "command": command,
            "description": "Read Kiteloop global config for registered projects"
        ]))

        XCTAssertEqual(activity.detail, command)
    }

    func testBashWithoutADescriptionStillShowsTheCommand() {
        let activity = vm.activityLabel(tool: "Bash", input: json([
            "command": "git status"
        ]))

        XCTAssertEqual(activity.label, "Bash · git status")
        XCTAssertEqual(activity.detail, "git status")
    }

    /// A blank description said nothing, so it is not preferred over the command.
    func testBashWithABlankDescriptionStillShowsTheCommand() {
        let activity = vm.activityLabel(tool: "Bash", input: json([
            "command": "git status", "description": "   "
        ]))

        XCTAssertEqual(activity.label, "Bash · git status")
    }

    func testAgentShowsItsDescription() {
        let activity = vm.activityLabel(tool: "Agent", input: json([
            "description": "Fix knowledge-subordinate test failure",
            "prompt": "In the given worktree, the test at …"
        ]))

        XCTAssertEqual(activity.label, "Agent · Fix knowledge-subordinate test failure")
    }

    func testFileToolsStillNameTheirFile() {
        for tool in ["Read", "Edit", "Write"] {
            let activity = vm.activityLabel(tool: tool, input: json([
                "file_path": "/a/b/ChatViewModel.swift"
            ]))
            XCTAssertEqual(activity.label, "\(tool) · ChatViewModel.swift")
            XCTAssertNil(activity.detail)
        }
    }

    func testSearchToolsStillNameTheirPattern() {
        for tool in ["Grep", "Glob"] {
            let activity = vm.activityLabel(tool: tool, input: json(["pattern": "activityLabel"]))
            XCTAssertEqual(activity.label, "\(tool) · activityLabel")
            XCTAssertNil(activity.detail)
        }
    }

    /// The ticker used to show these as nothing but the tool's name, while the
    /// row for the very same call, once it landed, named who was messaged.
    func testMessageAgentNamesTheHandleAndTheOpeningOfTheMessage() {
        let activity = vm.activityLabel(tool: "message_agent", input: json([
            "agent": "Reviewer", "message": "the branch is ready for review"
        ]))

        XCTAssertEqual(activity.label, "message_agent · @Reviewer: the branch is ready for review")
    }

    func testBroadcastNamesItsTargets() {
        let activity = vm.activityLabel(tool: "broadcast_agents", input: json([
            "agents": ["Reviewer", "Scribe"], "message": "build is green"
        ]))

        XCTAssertEqual(activity.label, "broadcast_agents · → Reviewer, Scribe: build is green")
    }

    func testWebCallsNameWhereTheBrowserWent() {
        let navigate = vm.activityLabel(tool: "web_navigate",
                                        input: json(["url": "https://example.com/docs"]))
        XCTAssertEqual(navigate.label, "web_navigate · https://example.com/docs")

        let type = vm.activityLabel(tool: "web_type", input: json(["ref": "e12", "text": "hello"]))
        XCTAssertEqual(type.label, "web_type · e12: hello")
    }

    /// One list, two surfaces: for the same call, the ticker's label is the
    /// tool's name and exactly the argument the transcript row is named by.
    func testTheTickerAndTheRowAgreeOnTheSameCallsArguments() {
        let calls: [(String, [String: Any])] = [
            ("Bash", ["command": "git status"]),
            ("Grep", ["pattern": "activityLabel"]),
            ("message_agent", ["agent": "Reviewer", "message": "the branch is ready for review"]),
            ("broadcast_agents", ["agents": ["Reviewer", "Scribe"], "message": "build is green"]),
            ("web_navigate", ["url": "https://example.com/docs"]),
            ("web_click", ["ref": "e12"])
        ]

        for (tool, input) in calls {
            let row = ToolCallLabel.rowSummary(tool: tool, input: input)
            XCTAssertEqual(vm.activityLabel(tool: tool, input: json(input)).label,
                           "\(tool) · \(row)", "ticker and row disagree for \(tool)")
        }
    }

    /// A tool neither surface names keeps its bare name in the ticker.
    func testAToolNeitherListCoversKeepsItsBareName() {
        let activity = vm.activityLabel(tool: "recall_knowledge",
                                        input: json(["query": "autopilot"]))

        XCTAssertEqual(activity.label, "recall_knowledge")
    }

    /// The old cut was a hard `prefix(40)`, which is how a row came to end
    /// `awk -F'|' '{print`. A label that needs shortening now ends on a word.
    func testALongLabelIsCutOnAWordBoundary() {
        let activity = vm.activityLabel(tool: "Bash", input: json([
            "description": "Read every backlog item in the tree and report which of them are ready"
        ]))

        XCTAssertEqual(activity.label,
                       "Bash · Read every backlog item in the tree and report which of…")
    }

    func testInputThatIsNotJSONFallsBackToTheToolName() {
        let activity = vm.activityLabel(tool: "Bash", input: "not json at all")

        XCTAssertEqual(activity.label, "Bash")
        XCTAssertNil(activity.detail)
    }
}
