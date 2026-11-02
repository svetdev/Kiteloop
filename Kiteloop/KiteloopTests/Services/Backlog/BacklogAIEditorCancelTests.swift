import XCTest
@testable import Kiteloop
import KiteloopCore

/// Stop on the backlog's AI bar: `cancel()` ends a pending proposal, stops the
/// one-shot session behind it and leaves the bar idle — and a reply that lands
/// after Stop never becomes a preview or an error.
@MainActor
final class BacklogAIEditorCancelTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "kiteloop-ai-editor-cancel")
    }

    // MARK: - Helpers

    private let backlog = BacklogParser.parse("""
    # Demo Backlog

    ## Epic: Platform

    - [ ] kl-001 | Cache the index | ready | size: S
    """)

    private func makeEditor(_ runtime: StubHeadlessRuntime) -> BacklogAIEditor {
        BacklogAIEditor(
            runtimeFactory: { runtime },
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json")))
    }

    private func isIdle(_ phase: BacklogAIEditor.Phase) -> Bool {
        if case .idle = phase { return true }
        return false
    }

    private func phaseName(_ phase: BacklogAIEditor.Phase) -> String {
        switch phase {
        case .idle: "idle"
        case .thinking: "thinking"
        case .review: "review"
        case .error(let message): "error(\(message))"
        }
    }

    // MARK: - Stop

    func testCancelStopsAHungProposalAndReturnsToIdle() async throws {
        let runtime = StubHeadlessRuntime(behavior: .stall)
        let editor = makeEditor(runtime)

        let task = editor.submit(instruction: "Add an item", backlog: backlog, projectPath: tempDir.path)
        try await eventually("the stub to have been sent the prompt") { @MainActor in runtime.sentPrompts.count == 1 }
        XCTAssertTrue(editor.isBusy, "a hung reply keeps the bar thinking until Stop")

        editor.cancel()

        XCTAssertTrue(isIdle(editor.phase), "Stop returns the bar to idle, got \(phaseName(editor.phase))")
        XCTAssertFalse(editor.isBusy)
        await task.value
        XCTAssertEqual(runtime.stoppedSessionIDs.count, 1, "Stop must stop the one-shot session — no leaked process")
    }

    // MARK: - A reply after Stop is dropped

    func testUnwoundReplyAfterStopIsNotShownAsAnError() async throws {
        // The runner unwinds a cancelled stall with empty text, which decoded
        // would be an error; after Stop it must be dropped instead.
        let runtime = StubHeadlessRuntime(behavior: .stall)
        let editor = makeEditor(runtime)

        let task = editor.submit(instruction: "Add an item", backlog: backlog, projectPath: tempDir.path)
        try await eventually("the stub to have been sent the prompt") { @MainActor in runtime.sentPrompts.count == 1 }
        editor.cancel()
        await task.value

        XCTAssertTrue(isIdle(editor.phase), "a stopped request never reaches .error, got \(phaseName(editor.phase))")
    }

    func testReplyLandingAfterStopNeverBecomesAPreview() async {
        let reply = #"[{"op":"addItem","epic":"Platform","title":"Retry the upload"}]"#
        let runtime = StubHeadlessRuntime(behavior: .events([.assistantText(reply)]))
        let editor = makeEditor(runtime)

        let task = editor.submit(instruction: "Add an item", backlog: backlog, projectPath: tempDir.path)
        editor.cancel()
        await task.value

        XCTAssertTrue(isIdle(editor.phase), "a stopped request never reaches .review, got \(phaseName(editor.phase))")
    }
}
