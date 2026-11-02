import XCTest
import KiteloopCore
@testable import Kiteloop

/// `web_navigate` is the agent's only way to steer the preview pane, so these
/// cover the gate it runs through: what loads, what stops at the human, and what
/// is refused outright — driven end to end through the MCP tool-call path.
@MainActor
final class WebNavigateToolTests: XCTestCase {
    private var tempDir: URL!
    private var runtime: MockAgentRuntime!
    private var orchestrator: Orchestrator!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "web-navigate-tests")

        let eventBus = EventBus(eventsURL: tempDir.appending(path: "events"))
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let project = KiteloopProject(rootURL: tempDir)
        let memoryManager = MemoryManager(project: project)
        runtime = MockAgentRuntime()
        orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus,
                                    subscriptionEngine: subscriptionEngine, memoryManager: memoryManager)
    }

    /// Runs one `web_navigate` call through the real stream-handling path and
    /// returns the VM, so assertions read the preview state the tool produced.
    private func navigate(_ url: String, preview: WebPreviewViewModel?) async -> ChatViewModel {
        let agent = Agent(id: "a", name: "A", model: "sonnet",
                          systemPrompt: "", tools: ["web_navigate"], denied: [],
                          permissionMode: "default", state: .idle)
        orchestrator.addAgent(agent)
        runtime.events = [
            .mcpToolCall(.init(requestID: "mcp-1", toolName: "web_navigate",
                               input: #"{"url":"\#(url)"}"#)),
            .result(.init(text: "done", costUSD: 0, durationMs: 1,
                          inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "s-a", permissionDenials: []))
        ]
        try? await orchestrator.startAgent("a", cwd: tempDir)

        let vm = ChatViewModel(agentID: "a", projectURL: tempDir, orchestrator: orchestrator)
        preview?.retarget(to: vm, agentName: "A")
        vm.inputText = "look at the page"
        await vm.send()
        return vm
    }

    // MARK: - The gate

    func testLocalURLLoadsInTrustedMode() async {
        let preview = WebPreviewViewModel()
        preview.mode = .trusted

        _ = await navigate("http://localhost:3000/", preview: preview)

        XCTAssertEqual(preview.urlText, "http://localhost:3000/")
        XCTAssertNil(preview.pendingExternalURL)
        XCTAssertNil(preview.blockedMessage)
    }

    func testExternalURLIsRefusedInTrustedMode() async {
        let preview = WebPreviewViewModel()
        preview.mode = .trusted

        _ = await navigate("https://example.com/", preview: preview)

        XCTAssertNotNil(preview.blockedMessage, "trusted mode must wall off real sites")
        XCTAssertNil(preview.pendingExternalURL, "a denial is not a confirmation prompt")
        XCTAssertTrue(preview.urlText.isEmpty)
    }

    func testUnallowlistedExternalURLWaitsForTheHuman() async {
        let preview = WebPreviewViewModel()
        preview.mode = .external

        _ = await navigate("https://example.com/", preview: preview)

        XCTAssertEqual(preview.pendingExternalURL?.host, "example.com")
        XCTAssertTrue(preview.urlText.isEmpty, "the page must not load before approval")
    }

    func testAllowlistedExternalURLLoadsWithoutPrompting() async {
        let preview = WebPreviewViewModel()
        preview.mode = .external
        preview.allowlist = ["example.com"]

        _ = await navigate("https://example.com/", preview: preview)

        XCTAssertEqual(preview.urlText, "https://example.com/")
        XCTAssertNil(preview.pendingExternalURL)
    }

    // MARK: - Reachability

    func testNavigationIsInertWithoutAnAttachedPane() async {
        let preview = WebPreviewViewModel()
        preview.mode = .external

        // The pane is targeted at a *different* agent, so this agent's
        // `webPreview` is nil and the tool has nothing to drive.
        let vm = await navigate("http://localhost:3000/", preview: nil)

        XCTAssertNil(vm.webPreview)
        XCTAssertTrue(preview.urlText.isEmpty)
    }

    // MARK: - Decision reporting (what the handler reads back)

    func testLoadReportsTheGateDecision() {
        let preview = WebPreviewViewModel()
        preview.mode = .external

        XCTAssertEqual(preview.load("http://localhost:3000/", source: .programmatic), .allow)
        XCTAssertEqual(preview.load("https://example.com/", source: .programmatic), .confirm)
        XCTAssertEqual(preview.load("ftp://example.com/x", source: .programmatic), .deny)
        XCTAssertEqual(preview.load("   ", source: .programmatic), .deny)
        XCTAssertEqual(preview.blockedMessage, "Not a valid URL or path.")
    }

    func testTrustedModeReportsDenyForExternal() {
        let preview = WebPreviewViewModel()
        preview.mode = .trusted

        XCTAssertEqual(preview.load("https://example.com/", source: .programmatic), .deny)
        XCTAssertEqual(preview.load("https://example.com/", source: .user), .deny,
                       "trusted mode holds regardless of who asked")
    }

    // MARK: - Schema exposure

    func testSchemaIsOnlyOfferedToAgentsGrantedTheTool() {
        let granted = Agent(id: "g", name: "G", model: "sonnet", systemPrompt: "",
                            tools: ["web_navigate"], denied: [],
                            permissionMode: "default", state: .idle)
        let ungranted = Agent(id: "u", name: "U", model: "sonnet", systemPrompt: "",
                              tools: ["Read"], denied: [],
                              permissionMode: "default", state: .idle)

        XCTAssertTrue(KiteloopToolSchemas.schemasForAgent(granted).contains { $0.name == "web_navigate" })
        XCTAssertFalse(KiteloopToolSchemas.schemasForAgent(ungranted).contains { $0.name == "web_navigate" })
    }

    func testSchemaRequiresAURL() {
        let schema = KiteloopToolSchemas.webNavigate
        XCTAssertEqual(schema.name, "web_navigate")
        XCTAssertEqual(schema.inputSchema["required"] as? [String], ["url"])
    }
}
