import KiteloopCore
import XCTest
@testable import Kiteloop

/// The two places that name an agent's model to a person — the sidebar subtitle
/// and the blue tag in the info popover — spell it the way the rest of the app
/// does, rather than echoing whatever string the config happens to store.
final class AgentModelLabelTests: XCTestCase {

    private func agent(model: String, asideOf: String? = nil, permissionMode: String = "auto") -> Agent {
        Agent(
            id: "a1",
            name: "Builder",
            model: model,
            systemPrompt: "",
            tools: [],
            denied: [],
            permissionMode: permissionMode,
            asideOfAgentID: asideOf,
            state: .idle
        )
    }

    /// A Bedrock inference-profile id is 30-odd characters that truncate to nothing
    /// useful in a 190pt column; it collapses to its family name at both sites.
    func testBedrockInferenceProfileReadsAsItsFamily() {
        let agent = agent(model: "us.anthropic.claude-opus-4-8")
        XCTAssertEqual(KiteloopSidebar.modelSubtitle(for: agent), "Opus")
        XCTAssertEqual(AgentInfoPopover.modelTag(for: agent), "Opus")
    }

    /// A local Ollama model gets the catalog's display name, not its id.
    func testLocalModelReadsAsItsDisplayName() {
        let agent = agent(model: "qwen2.5-coder")
        XCTAssertEqual(KiteloopSidebar.modelSubtitle(for: agent), "Qwen 2.5 Coder")
        XCTAssertEqual(AgentInfoPopover.modelTag(for: agent), "Qwen 2.5 Coder")
    }

    /// Anything the catalog does not know is still shown exactly as stored — a
    /// pinned id is information, and blanking it or substituting a default hides
    /// what the agent is actually running.
    func testUnknownModelIsShownVerbatim() {
        let agent = agent(model: "mystery-model-v9")
        XCTAssertEqual(KiteloopSidebar.modelSubtitle(for: agent), "mystery-model-v9")
        XCTAssertEqual(AgentInfoPopover.modelTag(for: agent), "mystery-model-v9")
    }

    /// An aside still announces itself first; only the model part changes.
    func testAsideSubtitleStillLeadsWithItsPrefix() {
        XCTAssertEqual(
            KiteloopSidebar.modelSubtitle(for: agent(model: "us.anthropic.claude-opus-4-8", asideOf: "a0")),
            "aside · Opus"
        )
        XCTAssertEqual(
            KiteloopSidebar.modelSubtitle(for: agent(model: "mystery-model-v9", asideOf: "a0")),
            "aside · mystery-model-v9"
        )
    }

    /// The orange permission tag names the mode as the Edit Agent sheet does.
    func testPermissionTagReadsAsItsDisplayName() {
        XCTAssertEqual(AgentInfoPopover.permissionTag(for: agent(model: "", permissionMode: "bypassPermissions")), "Bypass All")
        XCTAssertEqual(AgentInfoPopover.permissionTag(for: agent(model: "", permissionMode: "acceptEdits")), "Accept Edits")
        XCTAssertEqual(AgentInfoPopover.permissionTag(for: agent(model: "", permissionMode: "auto")), "Auto")
    }

    /// A permission mode the app has no name for is shown as stored.
    func testUnknownPermissionModeIsShownVerbatim() {
        XCTAssertEqual(AgentInfoPopover.permissionTag(for: agent(model: "", permissionMode: "something-new")), "something-new")
    }

    /// The Effort row names the level as the rest of the app does.
    func testEffortReadsAsItsDisplayName() {
        XCTAssertEqual(AgentInfoPopover.effortLabel("xhigh"), "Extra High")
    }

    /// An effort level the app has no name for is shown as stored.
    func testUnknownEffortIsShownVerbatim() {
        XCTAssertEqual(AgentInfoPopover.effortLabel("turbo"), "turbo")
    }

    /// The chip under the chat header names the model as the popover does, and an
    /// agent with no model still reads "model".
    func testChatStripModelChipMatchesThePopover() {
        let agent = agent(model: "us.anthropic.claude-opus-4-8")
        XCTAssertEqual(ChatView.modelChipLabel(agent.model), AgentInfoPopover.modelTag(for: agent))
        XCTAssertEqual(ChatView.modelChipLabel(agent.model), "Opus")
        XCTAssertEqual(ChatView.modelChipLabel("mystery-model-v9"), "mystery-model-v9")
        XCTAssertEqual(ChatView.modelChipLabel(""), "model")
    }

    /// The chip under the chat header names the mode as `/mode` does; a mode the
    /// app has no name for is shown as stored.
    func testChatStripModeChipReadsAsItsDisplayName() {
        XCTAssertEqual(ChatView.permissionModeChipLabel("acceptEdits"), "Accept Edits")
        XCTAssertEqual(ChatView.permissionModeChipLabel("plan"), "Plan (read-only)")
        XCTAssertEqual(ChatView.permissionModeChipLabel("dontAsk"), "Don't Ask (refuse what would ask)")
        XCTAssertEqual(ChatView.permissionModeChipLabel("something-new"), "something-new")
    }
}
