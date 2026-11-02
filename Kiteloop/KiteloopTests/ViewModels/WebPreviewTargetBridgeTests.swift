import XCTest
import KiteloopCore
@testable import Kiteloop

/// The preview pane and the selected agent's chat VM point at each other. These
/// cover that the pair stays consistent across selection changes and that neither
/// side keeps the other alive.
@MainActor
final class WebPreviewTargetBridgeTests: XCTestCase {
    private var orchestrator: Orchestrator!

    override func setUp() async throws {
        let eventBus = EventBus(eventsURL: FileManager.default.temporaryDirectory.appending(path: "test-events"))
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let project = KiteloopProject(rootURL: FileManager.default.temporaryDirectory)
        let memoryManager = MemoryManager(project: project)
        orchestrator = Orchestrator(runtime: MockAgentRuntime(), eventBus: eventBus,
                                    subscriptionEngine: subscriptionEngine, memoryManager: memoryManager)
    }

    private func makeChatVM(id: String) -> ChatViewModel {
        let agent = Agent(id: id, name: id, model: "sonnet",
                          systemPrompt: "", tools: [], denied: [],
                          permissionMode: "default", state: .idle)
        orchestrator.addAgent(agent)
        return ChatViewModel(agentID: id, projectURL: FileManager.default.temporaryDirectory,
                             orchestrator: orchestrator)
    }

    func testRetargetWiresBothDirections() {
        let preview = WebPreviewViewModel()
        let chat = makeChatVM(id: "a")

        preview.retarget(to: chat, agentName: "a")

        XCTAssertTrue(preview.attachTargetVM === chat)
        XCTAssertTrue(chat.webPreview === preview)
        XCTAssertEqual(preview.currentAgentName, "a")
    }

    func testRetargetClearsPreviousTarget() {
        let preview = WebPreviewViewModel()
        let first = makeChatVM(id: "a")
        let second = makeChatVM(id: "b")

        preview.retarget(to: first, agentName: "a")
        preview.retarget(to: second, agentName: "b")

        XCTAssertNil(first.webPreview, "a deselected agent must not keep a handle on the preview")
        XCTAssertTrue(second.webPreview === preview)
        XCTAssertTrue(preview.attachTargetVM === second)
    }

    func testRetargetToNilClearsBothSides() {
        let preview = WebPreviewViewModel()
        let chat = makeChatVM(id: "a")

        preview.retarget(to: chat, agentName: "a")
        preview.retarget(to: nil, agentName: nil)

        XCTAssertNil(chat.webPreview)
        XCTAssertNil(preview.attachTargetVM)
        XCTAssertNil(preview.currentAgentName)
    }

    func testChatViewModelHoldsPreviewWeakly() {
        let chat = makeChatVM(id: "a")
        do {
            let preview = WebPreviewViewModel()
            preview.retarget(to: chat, agentName: "a")
            XCTAssertNotNil(chat.webPreview)
        }
        XCTAssertNil(chat.webPreview, "the pair must not form a retain cycle")
    }
}
