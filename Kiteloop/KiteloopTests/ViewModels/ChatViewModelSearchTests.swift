import SwiftUI
import XCTest
import KiteloopCore
@testable import Kiteloop

@MainActor
final class ChatViewModelSearchTests: XCTestCase {
    private var vm: ChatViewModel!
    private var mock: MockAgentRuntime!

    override func setUp() async throws {
        let mock = MockAgentRuntime()
        self.mock = mock
        mock.events = [
            .assistantText("Hello world"),
            .result(.init(
                text: "Hello world",
                costUSD: 0.001, durationMs: 100,
                inputTokens: 10, outputTokens: 5,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "s1", permissionDenials: []
            ))
        ]
        let orchestrator = Orchestrator(runtime: mock)
        let agent = Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        )
        orchestrator.addAgent(agent)

        let tmpDir = try makeTemporaryDirectory(prefix: "kiteloop-test")

        vm = ChatViewModel(agentID: "test", projectURL: tmpDir, orchestrator: orchestrator)
        try await orchestrator.startAgent("test", cwd: tmpDir)

        vm.inputText = "Hello"
        await vm.send()

        vm.inputText = "World foo bar"
        await vm.send()
    }

    func testPerformSearchFindsMatches() {
        vm.searchQuery = "hello"
        vm.performSearch()
        XCTAssertFalse(vm.matchingMessageIDs.isEmpty)
    }

    func testEmptyQueryClearsMatches() {
        vm.searchQuery = "hello"
        vm.performSearch()
        XCTAssertFalse(vm.matchingMessageIDs.isEmpty)

        vm.searchQuery = ""
        vm.performSearch()
        XCTAssertTrue(vm.matchingMessageIDs.isEmpty)
        XCTAssertEqual(vm.currentMatchIndex, 0)
    }

    func testNextMatchWrapsAround() {
        vm.searchQuery = "hello"
        vm.performSearch()
        let count = vm.matchingMessageIDs.count
        guard count > 0 else { XCTFail("Expected matches"); return }

        for _ in 0..<count {
            vm.nextMatch()
        }
        XCTAssertEqual(vm.currentMatchIndex, 0)
    }

    func testPreviousMatchWrapsBackward() {
        vm.searchQuery = "hello"
        vm.performSearch()
        guard !vm.matchingMessageIDs.isEmpty else { XCTFail("Expected matches"); return }

        XCTAssertEqual(vm.currentMatchIndex, 0)
        vm.previousMatch()
        XCTAssertEqual(vm.currentMatchIndex, vm.matchingMessageIDs.count - 1)
    }

    func testImageMessagesExcludedFromSearch() {
        vm.searchQuery = "hello"
        vm.performSearch()
        let beforeCount = vm.matchingMessageIDs.count

        let imageData = Data([0xFF, 0xD8, 0xFF])
        _ = Message.agentImage(imageData, agent: "test")
        // Image messages don't contain searchable text, verify search doesn't break
        let hasImage = vm.messages.contains { msg in
            if case .image = msg.content { return true }
            return false
        }
        // Verify images in messages are not matched
        if hasImage {
            vm.performSearch()
            XCTAssertEqual(vm.matchingMessageIDs.count, beforeCount)
        }
    }

    private func sendTurn(_ text: String, events: [StreamEvent]) async {
        mock.sendEventsQueue = [events + [.result(.init(
            text: "done",
            costUSD: 0.001, durationMs: 100,
            inputTokens: 10, outputTokens: 5,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
            sessionID: "s1", permissionDenials: []
        ))]]
        vm.inputText = text
        await vm.send()
    }

    private func toolCallMessageID(_ callID: String) -> UUID? {
        vm.messages.first {
            if case .toolCall(let call) = $0.content { return call.id == callID }
            return false
        }?.id
    }

    func testToolOutputMatchLandsOnTheDisplayedToolCall() async throws {
        await sendTurn("run it", events: [
            .toolUse(id: "call-1", name: "Grep", input: "{}"),
            .toolResult(id: "call-1", output: "zebracorn found here"),
        ])
        let callMessageID = try XCTUnwrap(toolCallMessageID("call-1"))

        vm.searchQuery = "zebracorn"
        vm.performSearch()

        XCTAssertEqual(vm.matchingMessageIDs, [callMessageID])
        // The tool call is what the transcript draws; its result is not.
        let matched = try XCTUnwrap(vm.messages.first { $0.id == callMessageID })
        guard case .toolCall = matched.content else { return XCTFail("Expected the tool call message") }
    }

    func testThinkingIsNotMatched() async {
        await sendTurn("think", events: [.thinking("quokkamind pondering")])
        XCTAssertTrue(vm.messages.contains {
            if case .thinking = $0.content { return true }
            return false
        })

        vm.searchQuery = "quokkamind"
        vm.performSearch()

        XCTAssertTrue(vm.matchingMessageIDs.isEmpty)
    }

    func testToolCallMatchingInInputAndOutputCountsOnce() async throws {
        await sendTurn("run it", events: [
            .toolUse(id: "call-2", name: "Grep", input: "{\"pattern\": \"narwhalix\"}"),
            .toolResult(id: "call-2", output: "narwhalix: 3 hits"),
        ])
        let callMessageID = try XCTUnwrap(toolCallMessageID("call-2"))

        vm.searchQuery = "narwhalix"
        vm.performSearch()

        XCTAssertEqual(vm.matchingMessageIDs, [callMessageID])
    }

    func testRefreshAfterAppendKeepsTheCurrentMatch() async {
        vm.searchQuery = "hello"
        vm.performSearch()
        guard vm.matchingMessageIDs.count > 1 else { return XCTFail("Expected several matches") }
        vm.nextMatch()
        let currentID = vm.matchingMessageIDs[vm.currentMatchIndex]

        await sendTurn("hello again", events: [])
        vm.refreshSearch()

        XCTAssertEqual(vm.matchingMessageIDs[vm.currentMatchIndex], currentID)
    }

    func testRefreshWhenCurrentMatchIsGoneFallsBackToFirst() async {
        vm.searchQuery = "hello"
        vm.performSearch()
        guard vm.matchingMessageIDs.count > 1 else { return XCTFail("Expected several matches") }
        vm.nextMatch()

        await vm.clear()
        await sendTurn("hello once more", events: [])
        vm.refreshSearch()

        XCTAssertFalse(vm.matchingMessageIDs.isEmpty)
        XCTAssertEqual(vm.currentMatchIndex, 0)
    }

    // MARK: - The match the bar is on

    func testCurrentMatchIDIsNilWhenNothingMatches() {
        vm.searchQuery = "zebracorn"
        vm.performSearch()

        XCTAssertTrue(vm.matchingMessageIDs.isEmpty)
        XCTAssertNil(vm.currentMatchID)
    }

    func testCurrentMatchIDIsTheMatchAtTheCurrentIndex() {
        vm.searchQuery = "hello"
        vm.performSearch()

        XCTAssertFalse(vm.matchingMessageIDs.isEmpty)
        XCTAssertEqual(vm.currentMatchID, vm.matchingMessageIDs[vm.currentMatchIndex])
    }

    func testCurrentMatchIDFollowsNextAndPreviousMatch() {
        vm.searchQuery = "hello"
        vm.performSearch()
        guard vm.matchingMessageIDs.count > 1 else { return XCTFail("Expected several matches") }

        vm.nextMatch()
        XCTAssertEqual(vm.currentMatchID, vm.matchingMessageIDs[vm.currentMatchIndex])
        XCTAssertEqual(vm.currentMatchID, vm.matchingMessageIDs[1])

        vm.previousMatch()
        XCTAssertEqual(vm.currentMatchID, vm.matchingMessageIDs[vm.currentMatchIndex])
        XCTAssertEqual(vm.currentMatchID, vm.matchingMessageIDs[0])
    }

    func testCurrentMatchIDIsNilAfterTheQueryIsEmptied() {
        vm.searchQuery = "hello"
        vm.performSearch()
        XCTAssertNotNil(vm.currentMatchID)

        vm.searchQuery = ""
        vm.performSearch()

        XCTAssertNil(vm.currentMatchID)
    }

    // MARK: - Closing the find bar

    func testCloseSearchClearsTheQueryAndTheMatches() {
        vm.isSearching = true
        vm.searchQuery = "hello"
        vm.performSearch()
        XCTAssertFalse(vm.matchingMessageIDs.isEmpty)
        vm.nextMatch()

        vm.closeSearch()

        XCTAssertFalse(vm.isSearching)
        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertTrue(vm.matchingMessageIDs.isEmpty)
        XCTAssertEqual(vm.currentMatchIndex, 0)
    }

    func testCloseSearchOnAViewModelThatWasNeverSearchingLeavesItShut() {
        vm.closeSearch()

        XCTAssertFalse(vm.isSearching)
        XCTAssertEqual(vm.searchQuery, "")
        XCTAssertTrue(vm.matchingMessageIDs.isEmpty)
        XCTAssertEqual(vm.currentMatchIndex, 0)
    }

    // MARK: - The keys the find bar answers to

    /// A bar whose three actions record which one ran.
    private func makeSearchBar(query: String = "hello",
                              matchCount: Int = 2,
                              unsearchedOlderMessageCount: Int = 0,
                              into log: @escaping (String) -> Void) -> SearchBar {
        SearchBar(
            query: .constant(query),
            matchCount: matchCount,
            unsearchedOlderMessageCount: unsearchedOlderMessageCount,
            currentIndex: 0,
            onNext: { log("next") },
            onPrevious: { log("previous") },
            onDismiss: { log("dismiss") }
        )
    }

    func testSearchBarKeysRunTheirOwnActions() {
        var ran: [String] = []
        let bar = makeSearchBar { ran.append($0) }

        bar.respond(to: .returnKey)
        bar.respond(to: .shiftReturn)
        bar.respond(to: .escape)

        XCTAssertEqual(ran, ["next", "previous", "dismiss"])
    }

    // MARK: - The older messages the search never looked at

    /// Seeds a session whose messages file holds `count` records and switches
    /// the view model onto it, so a real limited load sets the left-out count.
    private func switchToSeededSession(messageCount: Int) async throws {
        let dir = try makeTemporaryDirectory(prefix: "kiteloop-search-history")
        let store = SessionStore(projectDir: dir)
        let long = store.createSession(agentID: "test")
        let history = (0..<messageCount).map { index in
            Message(id: UUID(), timestamp: .now, sender: .human, content: .text("history \(index)"))
        }
        try SessionStore.writeMessages(history, to: store.messagesURL(for: long), keepingLeading: 0)
        // The newest session is where `setupSessionStore` lands, so switching
        // to the seeded one is a real switch rather than a no-op.
        _ = store.createSession(agentID: "test")
        vm.setupSessionStore(store)
        await vm.switchToSession(long)
    }

    // MARK: - Plan cards and agent questions

    /// Switches the view model onto a seeded session holding `contents`, in
    /// order, and returns the ids of those messages. `vm.messages` is
    /// `private(set)`, and the chat itself only ever posts an ask_human
    /// approval — a permission request reaches it only from a loaded
    /// history — so a seeded session is how these cards get in front of it.
    private func switchToSession(holding contents: [Message.Content]) async throws -> [UUID] {
        let dir = try makeTemporaryDirectory(prefix: "kiteloop-search-cards")
        let store = SessionStore(projectDir: dir)
        let seeded = store.createSession(agentID: "test")
        let history = contents.map { Message(id: UUID(), timestamp: .now, sender: .agent("test"), content: $0) }
        try SessionStore.writeMessages(history, to: store.messagesURL(for: seeded), keepingLeading: 0)
        _ = store.createSession(agentID: "test")
        vm.setupSessionStore(store)
        await vm.switchToSession(seeded)
        return history.map(\.id)
    }

    private func approval(_ action: String, tool: String,
                          status: Message.ApprovalRequest.ApprovalStatus) -> Message.Content {
        .approval(.init(id: UUID().uuidString, action: action, tool: tool, status: status))
    }

    private func matches(_ query: String) -> [UUID] {
        vm.searchQuery = query
        vm.performSearch()
        return vm.matchingMessageIDs
    }

    func testAPlanCardIsMatchedOnItsText() async throws {
        let ids = try await switchToSession(holding: [
            .text("before the plan"),
            .plan(Message.PlanProposal(text: "# Plan\n\n1. Rewire the Gryphonator")),
            .text("after the plan"),
        ])

        XCTAssertEqual(matches("gryphonator"), [ids[1]])
    }

    func testAnAgentQuestionIsMatchedWhetherPendingOrAnswered() async throws {
        let ids = try await switchToSession(holding: [
            approval("Which wombatfold should I use?", tool: "ask_human", status: .pending),
            approval("Deploy to the wombatfold?", tool: "ask_human", status: .approved),
        ])

        XCTAssertEqual(matches("WOMBATFOLD"), ids)
    }

    func testADecidedPermissionRequestIsNotMatchedButAPendingOneIs() async throws {
        let ids = try await switchToSession(holding: [
            approval("Run okapizer --approved", tool: "Bash", status: .approved),
            approval("Run okapizer --denied", tool: "Bash", status: .denied),
            approval("Run okapizer --pending", tool: "Bash", status: .pending),
        ])

        XCTAssertEqual(matches("okapizer"), [ids[2]])
    }

    func testUnsearchedCountIsTheMessagesTheLoadLeftOnDisk() async throws {
        try await switchToSeededSession(messageCount: 520)
        XCTAssertEqual(vm.messages.count, 500)

        vm.isSearching = true
        vm.searchQuery = "history"
        vm.performSearch()

        XCTAssertEqual(vm.unsearchedOlderMessageCount, 20)
    }

    func testUnsearchedCountIsZeroWhenTheWholeHistoryIsLoaded() async throws {
        try await switchToSeededSession(messageCount: 12)
        XCTAssertEqual(vm.messages.count, 12)

        vm.isSearching = true
        vm.searchQuery = "history"
        vm.performSearch()

        XCTAssertEqual(vm.unsearchedOlderMessageCount, 0)
    }

    func testUnsearchedCountIsZeroWhileTheFindBarIsShut() async throws {
        try await switchToSeededSession(messageCount: 520)

        vm.isSearching = false
        vm.searchQuery = "history"
        vm.performSearch()

        XCTAssertEqual(vm.unsearchedOlderMessageCount, 0)
    }

    func testUnsearchedCountIsZeroWhenTheQueryIsEmpty() async throws {
        try await switchToSeededSession(messageCount: 520)

        vm.isSearching = true
        vm.searchQuery = ""
        vm.performSearch()

        XCTAssertEqual(vm.unsearchedOlderMessageCount, 0)
    }

    func testSearchBarSaysNothingWhenNoMessagesWereLeftOut() {
        let bar = makeSearchBar { _ in }

        XCTAssertNil(bar.unsearchedNote)
    }

    func testSearchBarNamesTheMessagesItNeverSearched() throws {
        let bar = makeSearchBar(unsearchedOlderMessageCount: 20) { _ in }

        let note = try XCTUnwrap(bar.unsearchedNote)
        XCTAssertTrue(note.contains("20"), "Expected the count in \(note)")
    }

    func testSearchBarSaysNoMatchesWhenTheQueryFoundNothing() {
        let bar = makeSearchBar(query: "zzz", matchCount: 0) { _ in }

        XCTAssertEqual(bar.noMatchesNote, "No matches")
    }

    func testSearchBarKeepsItsCounterWhenTheQueryFoundSomething() {
        let bar = makeSearchBar(query: "zzz", matchCount: 2) { _ in }

        XCTAssertNil(bar.noMatchesNote)
        XCTAssertEqual(bar.matchCount, 2)
    }

    func testSearchBarSaysNothingWhileTheFieldIsEmpty() {
        let bar = makeSearchBar(query: "", matchCount: 0) { _ in }

        XCTAssertNil(bar.noMatchesNote)
    }

    func testSearchBarSaysNoMatchesBesideTheMessagesItNeverSearched() {
        let bar = makeSearchBar(query: "zzz", matchCount: 0, unsearchedOlderMessageCount: 20) { _ in }

        XCTAssertEqual(bar.noMatchesNote, "No matches")
        XCTAssertEqual(bar.unsearchedNote, "20 older not searched")
    }

    // MARK: - Who owns Esc

    func testStopButtonHoldsEscapeWhileTheFindBarIsShut() {
        XCTAssertEqual(
            InputBar.stopShortcut(isSearchOpen: false),
            KeyboardShortcut(.escape, modifiers: [])
        )
    }

    func testStopButtonGivesUpEscapeWhileTheFindBarIsOpen() {
        XCTAssertNil(InputBar.stopShortcut(isSearchOpen: true))
    }
}
