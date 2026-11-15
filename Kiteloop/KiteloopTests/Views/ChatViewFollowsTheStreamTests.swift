import AppKit
import SwiftUI
import XCTest
import KiteloopCore
@testable import Kiteloop

/// The message list, drawn in a window, keeps the newest line in view: the
/// end of a reply used to be left below the window, because the list went to
/// the bottom only when a message was added or a second passed, and a turn's
/// last lines arrive after both. Read off the scroll view the list is drawn in.
@MainActor
final class ChatViewFollowsTheStreamTests: XCTestCase {
    private var vm: ChatViewModel!
    private var window: NSWindow!
    private var host: NSHostingView<AnyView>!

    override func setUp() async throws {
        let dir = try makeTemporaryDirectory(prefix: "chat-follows")
        let mock = MockAgentRuntime()
        let reply = (1...6).map { "line \($0) of the reply" }.joined(separator: "\n\n")
        mock.events = [
            .assistantText(reply),
            .result(.init(text: reply, costUSD: 0.001, durationMs: 50, inputTokens: 5, outputTokens: 3,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "s", permissionDenials: []))
        ]
        let orchestrator = Orchestrator(runtime: mock)
        orchestrator.addAgent(Agent(id: "test", name: "Test", model: "sonnet", systemPrompt: "", tools: [],
                                    denied: [], permissionMode: "default", state: .idle))
        try await orchestrator.startAgent("test", cwd: dir)
        vm = ChatViewModel(agentID: "test", projectURL: dir, orchestrator: orchestrator)
        vm.contextWindowDefaults = UserDefaults(suiteName: "ChatViewFollowsTheStreamTests.\(UUID().uuidString)") ?? .standard

        // Something to open on, so the list — not the empty state — is drawn.
        try await say("first")
        host = NSHostingView(rootView: AnyView(
            MessageListContainer(viewModel: vm, isTranscriptMode: false, isStreaming: false,
                                 lastCompletedDuration: nil, elapsedSeconds: 0)
                .frame(width: 480, height: 300)))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        try await eventually("the list is drawn in a scroll view") { self.scrollView != nil }
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        host = nil
        vm = nil
    }

    private func say(_ text: String) async throws {
        let before = vm.messages.count
        vm.inputText = text
        await vm.send()
        try await eventually("the turn for \(text) to finish") { !self.vm.isStreaming && self.vm.messages.count > before }
    }

    private var scrollView: NSScrollView? {
        var pending: [NSView] = [host]
        while let view = pending.popLast() {
            if let found = view as? NSScrollView { return found }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// How far the end of the conversation sits below the window onto it.
    private var distanceFromBottom: CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return .infinity }
        let visible = scrollView.documentVisibleRect
        return document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
    }

    /// Where the list stands, for a wait that timed out to say.
    private var standing: String {
        guard let scrollView, let document = scrollView.documentView else { return "no scroll view" }
        return "document \(document.bounds), window onto it \(scrollView.documentVisibleRect), flipped \(document.isFlipped)"
    }

    private var overflows: Bool {
        guard let scrollView, let document = scrollView.documentView else { return false }
        return document.bounds.height > scrollView.documentVisibleRect.height + 100
    }

    func testTheListStaysOnTheNewestLineAsTheConversationOutgrowsTheWindow() async throws {
        for turn in 1...6 { try await say("turn \(turn)") }
        try await eventually("the conversation to outgrow the window") { self.overflows }
        try await eventually("the list to be at the bottom — \(self.standing)") { self.distanceFromBottom <= 4 }
    }

    func testAReaderWhoScrolledUpIsLeftThereUntilTheySendSomething() async throws {
        for turn in 1...6 { try await say("turn \(turn)") }
        try await eventually("the list to be at the bottom — \(self.standing)") { self.overflows && self.distanceFromBottom <= 4 }

        let scrollView = try XCTUnwrap(scrollView)
        let document = try XCTUnwrap(scrollView.documentView)
        let top = document.isFlipped ? document.bounds.minY : document.bounds.maxY - scrollView.documentVisibleRect.height
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await eventually("the scroll up to be taken") { self.distanceFromBottom > 100 }

        // A system note arrives below a reader who is reading further up.
        let height = document.bounds.height
        vm.inputText = "/cost"
        await vm.send()
        try await eventually("the note to be drawn") { document.bounds.height > height }
        XCTAssertGreaterThan(distanceFromBottom, 100, "the list moved a reader who had scrolled up")

        try await say("back")
        try await eventually("sending to take the reader to the bottom — \(self.standing)") { self.distanceFromBottom <= 4 }
    }
}
