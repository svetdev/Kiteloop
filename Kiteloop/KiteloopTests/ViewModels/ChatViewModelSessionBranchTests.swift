import XCTest
import KiteloopCore
@testable import Kiteloop

/// Branches belong to the chat they were made in: starting, switching to or
/// deleting into another chat opens it on its main line, and one chat's
/// branches never reach another's transcript or file.
@MainActor
final class ChatViewModelSessionBranchTests: XCTestCase {
    private var vm: ChatViewModel!
    private var store: SessionStore!
    private var runtime: MockAgentRuntime!
    private var tmpDir: URL!

    override func setUp() async throws {
        runtime = MockAgentRuntime()
        runtime.events = [.result(.init(
            text: "Done", costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50,
            cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: []
        ))]
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        tmpDir = try makeTemporaryDirectory(prefix: "kiteloop-session-branch")
        vm = ChatViewModel(agentID: "test", projectURL: tmpDir, orchestrator: orchestrator)
        try await orchestrator.startAgent("test", cwd: tmpDir)
        store = SessionStore(projectDir: tmpDir)
        vm.setupSessionStore(store)
    }

    /// A chat on disk holding `texts` as alternating human and agent messages.
    private func makeSession(_ title: String, texts: [String]) throws -> (ChatSession, [Message]) {
        var session = store.createSession(agentID: "test")
        session.title = title
        store.updateSession(session)
        let messages = texts.enumerated().map { index, text in
            Message(id: UUID(), timestamp: .now, sender: index.isMultiple(of: 2) ? .human : .agent("test"),
                    content: .text(text))
        }
        try SessionStore.writeMessages(messages, to: store.messagesURL(for: session), keepingLeading: 0)
        return (session, messages)
    }

    private func run(_ command: String) async {
        vm.inputText = command
        await vm.send()
    }

    private func savedIDs(of session: ChatSession) -> Set<UUID> {
        Set(SessionStore(projectDir: tmpDir).loadAllMessages(for: session).map(\.id))
    }

    func testSwitchingChatsLeavesTheBranchesBehind() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        let (chatB, _) = try makeSession("B", texts: ["b1", "b2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch switch x")
        XCTAssertEqual(vm.conversationTree.branchCount, 1)
        XCTAssertNotNil(vm.conversationTree.activeBranchID)

        await vm.switchToSession(chatB)

        XCTAssertEqual(vm.conversationTree.branchCount, 0)
        XCTAssertNil(vm.conversationTree.activeBranchID)
    }

    func testANewChatHasNoBranches() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        XCTAssertEqual(vm.conversationTree.branchCount, 1)

        await vm.startNewChat()

        XCTAssertEqual(vm.conversationTree.branchCount, 0)
        XCTAssertNil(vm.conversationTree.activeBranchID)
    }

    func testDeletingTheOpenChatOpensTheNextWithNoBranches() async throws {
        _ = try makeSession("B", texts: ["b1", "b2"])
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")

        await vm.deleteSession(chatA)

        XCTAssertNotEqual(vm.currentSession?.id, chatA.id)
        XCTAssertEqual(vm.conversationTree.branchCount, 0)
    }

    func testABranchInOneChatNeverReachesAnother() async throws {
        let (chatA, messagesA) = try makeSession("A", texts: ["a1", "a2"])
        let (chatB, messagesB) = try makeSession("B", texts: ["b1", "b2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch switch x")
        let branchOfA = try XCTUnwrap(vm.conversationTree.activeBranchID)
        let leftOnA = vm.messages.map(\.id)

        await vm.switchToSession(chatB)
        XCTAssertEqual(vm.messages.map(\.id), messagesB.map(\.id), "B shows what the store loaded for B")
        // What clicking A's branch in B's branch bar did before branches were per chat.
        vm.switchToBranch(id: branchOfA)
        XCTAssertEqual(vm.messages.map(\.id), messagesB.map(\.id), "A's branch cannot be opened from B")

        await vm.switchToSession(chatA)
        let idsOfA = Set(leftOnA)
        try await eventually("chat B's file to hold B's messages") { self.savedIDs(of: chatB) == Set(messagesB.map(\.id)) }
        XCTAssertTrue(savedIDs(of: chatB).isDisjoint(with: idsOfA), "none of A's messages were saved into B")
        XCTAssertEqual(vm.messages.map(\.id), leftOnA, "A comes back on the line it was left on")
        XCTAssertTrue(Set(messagesA.map(\.id)).isSubset(of: savedIDs(of: chatA)), "nothing is lost from A's file")
    }

    // MARK: - A chat's branches outlive leaving it

    /// The branch sidecar as a store opened afresh reads it.
    private func savedBranches(of session: ChatSession) -> ConversationBranchSnapshot? {
        SessionStore(projectDir: tmpDir).loadBranches(for: session)
    }

    /// Chat A left on branch x, with main's line only in the tree, once both of
    /// A's files hold it. B is opened first so its count is saved: a fresh
    /// store prunes a chat whose index says it is empty.
    private func leaveAOnBranchX() async throws
        -> (chatA: ChatSession, chatB: ChatSession, beforeBranching: [UUID], main: [UUID], onX: [UUID]) {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        let (chatB, _) = try makeSession("B", texts: ["b1", "b2"])
        await vm.switchToSession(chatB)
        await vm.switchToSession(chatA)
        let beforeBranching = vm.messages.map(\.id)
        await run("/branch x")
        await run("/branch switch x")
        let main = vm.conversationTree.mainMessages.map(\.id)
        let onX = vm.messages.map(\.id)
        let x = try branchID(named: "x")
        try await eventually("chat A's sidecar to hold branch x as the line it is on") {
            self.savedBranches(of: chatA)?.activeBranchID == x
        }
        try await eventually("chat A's file to hold branch x's transcript") { self.savedIDs(of: chatA) == Set(onX) }
        return (chatA, chatB, beforeBranching, main, onX)
    }

    func testLeavingAChatOnABranchReopensItOnThatBranch() async throws {
        let (chatA, chatB, beforeBranching, _, onX) = try await leaveAOnBranchX()
        let x = try branchID(named: "x")

        await vm.switchToSession(chatB)
        await vm.switchToSession(chatA)

        XCTAssertEqual(vm.conversationTree.branchCount, 1)
        XCTAssertEqual(vm.conversationTree.activeBranchID, x)
        XCTAssertEqual(vm.conversationTree.activeBranch?.name, "x")
        XCTAssertEqual(vm.messages.map(\.id), onX, "A reopens on branch x's transcript")

        await run("/branch main")
        XCTAssertNil(vm.conversationTree.activeBranchID)
        XCTAssertEqual(Array(vm.messages.prefix(beforeBranching.count)).map(\.id), beforeBranching,
                       "main's turns from before the branch are all back")
    }

    func testAMainLineLeftBehindComesBackExactlyAsItWasLeft() async throws {
        let (chatA, chatB, _, main, _) = try await leaveAOnBranchX()

        await vm.switchToSession(chatB)
        await vm.switchToSession(chatA)
        await run("/branch main")

        XCTAssertEqual(Array(vm.messages.dropLast()).map(\.id), main)
    }

    func testARelaunchedChatViewModelReopensTheChatOnItsBranch() async throws {
        let (chatA, chatB, _, _, onX) = try await leaveAOnBranchX()
        let x = try branchID(named: "x")

        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        let relaunched = ChatViewModel(agentID: "test", projectURL: tmpDir, orchestrator: orchestrator)
        try await orchestrator.startAgent("test", cwd: tmpDir)
        relaunched.setupSessionStore(SessionStore(projectDir: tmpDir))
        // Whichever chat the relaunch opens on, A is then opened from another.
        if relaunched.currentSession?.id == chatA.id { await relaunched.switchToSession(chatB) }
        await relaunched.switchToSession(chatA)

        XCTAssertEqual(relaunched.conversationTree.branches.map(\.name), ["x"])
        XCTAssertEqual(relaunched.conversationTree.activeBranchID, x)
        XCTAssertEqual(relaunched.messages.map(\.id), onX)
    }

    func testADeletedBranchDoesNotComeBackWhenTheChatIsReopened() async throws {
        let (chatA, chatB, _, _, _) = try await leaveAOnBranchX()
        await run("/branch delete x")
        try await eventually("chat A's sidecar to be gone") { self.savedBranches(of: chatA) == nil }
        let onMain = vm.messages.map(\.id)
        try await eventually("chat A's file to hold main") { self.savedIDs(of: chatA) == Set(onMain) }

        await vm.switchToSession(chatB)
        await vm.switchToSession(chatA)

        XCTAssertEqual(vm.conversationTree.branchCount, 0)
        XCTAssertNil(vm.conversationTree.activeBranchID)
        XCTAssertEqual(vm.messages.map(\.id), onMain)
    }

    // MARK: - Deleting a branch from the branch bar

    private func lastText() -> String? {
        guard case .text(let text)? = vm.messages.last?.content else { return nil }
        return text
    }

    private func branchID(named name: String) throws -> UUID {
        try XCTUnwrap(vm.conversationTree.branches.first { $0.name == name }?.id)
    }

    func testDeletingTheBranchYouAreOnByIDGoesBackToMainWithTheSlashCommandsNote() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch switch x")
        await run("/branch delete x")
        let slashNote = try XCTUnwrap(lastText())

        await run("/branch x")
        await run("/branch switch x")
        vm.deleteBranch(id: try branchID(named: "x"))

        XCTAssertNil(vm.conversationTree.activeBranchID)
        XCTAssertEqual(vm.conversationTree.branchCount, 0)
        XCTAssertEqual(Array(vm.messages.dropLast()).map(\.id), vm.conversationTree.mainMessages.map(\.id))
        XCTAssertEqual(vm.messages.last?.sender, .system)
        XCTAssertEqual(lastText(), slashNote)
    }

    func testDeletingABranchYouAreNotOnByIDLeavesTheTranscriptAndOtherBranches() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch y")
        let before = vm.messages.map(\.id)
        let y = try branchID(named: "y")

        vm.deleteBranch(id: try branchID(named: "x"))

        XCTAssertEqual(Array(vm.messages.dropLast()).map(\.id), before)
        XCTAssertEqual(lastText(), "Deleted branch **x**.")
        XCTAssertNil(vm.conversationTree.activeBranchID)
        XCTAssertEqual(vm.conversationTree.branches.map(\.id), [y])
    }

    func testDeletingAnIDThatNamesNoBranchChangesNothing() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch switch x")
        let before = vm.messages.map(\.id)
        let branches = vm.conversationTree.branches.map(\.id)
        let active = vm.conversationTree.activeBranchID

        vm.deleteBranch(id: UUID())

        XCTAssertEqual(vm.messages.map(\.id), before)
        XCTAssertEqual(vm.conversationTree.branches.map(\.id), branches)
        XCTAssertEqual(vm.conversationTree.activeBranchID, active)
    }

    func testSwitchingToMainFromTheBarSaysTheAgentStillRemembersAsTheSlashCommandDoes() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch switch x")
        await run("/branch main")
        let slashText = try XCTUnwrap(lastText())

        await run("/branch switch x")
        vm.switchToMainBranch()

        XCTAssertNil(vm.conversationTree.activeBranchID)
        XCTAssertEqual(vm.messages.last?.sender, .system)
        let barText = try XCTUnwrap(lastText())
        XCTAssertTrue(barText.contains("main"))
        XCTAssertTrue(barText.contains("the agent still remembers the earlier conversation"))
        XCTAssertEqual(barText, slashText)
    }

    func testSwitchingToABranchByIDNamesItAndSaysTheAgentStillRemembersAsTheSlashCommandDoes() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch switch x")
        let slashText = try XCTUnwrap(lastText())
        await run("/branch main")
        let x = try branchID(named: "x")

        vm.switchToBranch(id: x)

        XCTAssertEqual(vm.conversationTree.activeBranchID, x)
        XCTAssertEqual(vm.messages.last?.sender, .system)
        let barText = try XCTUnwrap(lastText())
        XCTAssertTrue(barText.contains("**x**"))
        XCTAssertTrue(barText.contains("the agent still remembers the earlier conversation"))
        XCTAssertEqual(barText, slashText)
    }

    func testSwitchingToAnIDThatNamesNoBranchChangesNothing() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        let before = vm.messages.map(\.id)
        let active = vm.conversationTree.activeBranchID

        vm.switchToBranch(id: UUID())

        XCTAssertEqual(vm.messages.map(\.id), before)
        XCTAssertEqual(vm.conversationTree.activeBranchID, active)
    }

    // MARK: - Changing lines while a reply streams

    private static let waitForTheReply =
        "Cannot change branches while the agent is replying. Wait for the reply, or stop the turn first."

    /// Sends `text` in the background and returns once its turn is streaming.
    private func startStreamingTurn(_ text: String) async throws -> Task<Void, Never> {
        runtime.startDelay = 300_000_000
        vm.inputText = text
        let turn = Task { await vm.send() }
        try await eventually("the turn is streaming") { self.vm.isStreaming }
        return turn
    }

    /// Chat A with branches x and y saved from main, on `line` (nil for main).
    private func openAWithBranchesXAndY(on line: String?) async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch y")
        if let line { await run("/branch switch \(line)") }
    }

    /// What must not move while a line change is refused.
    private func lineState() -> (messages: [UUID], active: UUID?, branches: [[UUID]], main: [UUID]) {
        (vm.messages.map(\.id), vm.conversationTree.activeBranchID,
         vm.conversationTree.branches.map { $0.messages.map(\.id) }, vm.conversationTree.mainMessages.map(\.id))
    }

    private func assertRefused(leaving before: (messages: [UUID], active: UUID?, branches: [[UUID]], main: [UUID]),
                               line: UInt = #line) {
        XCTAssertEqual(Array(vm.messages.dropLast()).map(\.id), before.messages, line: line)
        XCTAssertEqual(vm.messages.last?.sender, .system, line: line)
        XCTAssertEqual(lastText(), Self.waitForTheReply, line: line)
        XCTAssertEqual(vm.conversationTree.activeBranchID, before.active, line: line)
        XCTAssertEqual(vm.conversationTree.branches.map { $0.messages.map(\.id) }, before.branches, line: line)
        XCTAssertEqual(vm.conversationTree.mainMessages.map(\.id), before.main, line: line)
    }

    func testSwitchingToABranchWhileAReplyStreamsIsRefused() async throws {
        try await openAWithBranchesXAndY(on: nil)
        let turn = try await startStreamingTurn("go")
        let before = lineState()

        vm.switchToBranch(id: try branchID(named: "x"))

        assertRefused(leaving: before)
        await turn.value
    }

    func testTypedBranchSwitchWhileAReplyStreamsLeavesTheLineAlone() async throws {
        try await openAWithBranchesXAndY(on: nil)
        let turn = try await startStreamingTurn("go")
        let before = lineState()

        await run("/branch switch x")

        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(vm.conversationTree.activeBranchID, before.active)
        XCTAssertEqual(vm.conversationTree.branches.map { $0.messages.map(\.id) }, before.branches)
        XCTAssertEqual(vm.conversationTree.mainMessages.map(\.id), before.main)
        await turn.value
    }

    func testSwitchingToMainWhileAReplyStreamsOnABranchIsRefused() async throws {
        try await openAWithBranchesXAndY(on: "x")
        let turn = try await startStreamingTurn("go")
        let before = lineState()

        vm.switchToMainBranch()

        assertRefused(leaving: before)
        await turn.value
    }

    func testDeletingTheBranchYouAreOnWhileAReplyStreamsIsRefused() async throws {
        try await openAWithBranchesXAndY(on: "x")
        let turn = try await startStreamingTurn("go")
        let before = lineState()

        vm.deleteBranch(id: try branchID(named: "x"))

        assertRefused(leaving: before)
        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["x", "y"])
        await turn.value
    }

    func testDeletingAnotherBranchAndBranchingStillWorkWhileAReplyStreams() async throws {
        try await openAWithBranchesXAndY(on: "x")
        let x = try branchID(named: "x")
        let turn = try await startStreamingTurn("go")

        vm.deleteBranch(id: try branchID(named: "y"))
        XCTAssertEqual(lastText(), "Deleted branch **y**.")
        vm.branchFromMessage(id: try XCTUnwrap(vm.messages.last?.id))

        XCTAssertEqual(vm.conversationTree.branches.count, 2)
        XCTAssertFalse(vm.conversationTree.branches.contains { $0.name == "y" })
        XCTAssertEqual(vm.conversationTree.activeBranchID, x)
        await turn.value
    }

    func testSwitchingWorksOnceTheReplyHasEnded() async throws {
        try await openAWithBranchesXAndY(on: nil)
        let turn = try await startStreamingTurn("go")
        await turn.value
        XCTAssertFalse(vm.isStreaming)
        let y = try branchID(named: "y")

        vm.switchToBranch(id: y)

        XCTAssertEqual(vm.conversationTree.activeBranchID, y)
        XCTAssertNotEqual(lastText(), Self.waitForTheReply)
    }

    // MARK: - Renaming a branch from the branch bar

    func testRenamingABranchByIDSaysOldAndNewAndSwitchFindsOnlyTheNewName() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch")
        let id = try branchID(named: "branch-1")

        vm.renameBranch(id: id, to: " idea ")

        XCTAssertEqual(vm.messages.last?.sender, .system)
        XCTAssertEqual(lastText(), "Renamed branch **branch-1** to **idea**.")
        XCTAssertEqual(vm.conversationTree.branches.map(\.id), [id])

        await run("/branch switch branch-1")
        XCTAssertEqual(lastText(), "No branch named 'branch-1'. Use `/branch list` to see all.")
        XCTAssertNil(vm.conversationTree.activeBranchID)

        await run("/branch switch idea")
        XCTAssertEqual(vm.conversationTree.activeBranchID, id)
    }

    func testRenamingToABlankNameSaysWhyAndChangesNothing() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")

        vm.renameBranch(id: try branchID(named: "x"), to: "   ")

        XCTAssertEqual(lastText(), "A branch name cannot be blank. **x** keeps its name.")
        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["x"])
    }

    func testRenamingToANameAnotherBranchHasSaysWhyAndChangesNothing() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch y")

        vm.renameBranch(id: try branchID(named: "x"), to: "y")

        XCTAssertEqual(lastText(), "A branch named **y** already exists. **x** keeps its name.")
        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["x", "y"])
    }

    func testRenamingToMainSaysItIsTheMainLineAndChangesNothing() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")

        vm.renameBranch(id: try branchID(named: "x"), to: "Main")

        XCTAssertEqual(lastText(), "**main** is the conversation's main line. **x** keeps its name.")
        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["x"])
    }

    func testRenamingAnIDThatNamesNoBranchSaysSoAndChangesNothing() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")

        vm.renameBranch(id: UUID(), to: "z")

        XCTAssertEqual(lastText(), "No such branch to rename.")
        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["x"])
    }

    // MARK: - Renaming the branch you are on with /branch rename

    func testTypedRenameRenamesTheBranchYouAreOnAndMakesNoRenameBranch() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch switch x")
        let id = try branchID(named: "x")
        let transcript = vm.messages.map(\.id)

        await run("/branch rename y")

        XCTAssertEqual(lastText(), "Renamed branch **x** to **y**.")
        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["y"])
        XCTAssertEqual(vm.conversationTree.branches.map(\.id), [id])
        XCTAssertEqual(vm.conversationTree.activeBranchID, id)
        XCTAssertEqual(Array(vm.messages.map(\.id).prefix(transcript.count)), transcript)
        XCTAssertNil(vm.conversationTree.branch(named: "rename y"))
    }

    func testTypedRenameOnMainSaysTheMainLineCannotBeRenamedAndChangesNothing() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")

        await run("/branch rename y")

        XCTAssertEqual(lastText(), "The main line cannot be renamed.")
        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["x"])
        XCTAssertNil(vm.conversationTree.activeBranchID)
    }

    func testTypedRenameWithNoNameGivesItsUsageAndMakesNoBranch() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)

        await run("/branch rename")

        XCTAssertEqual(lastText(), "Usage: /branch rename <name>")
        XCTAssertEqual(vm.conversationTree.branchCount, 0)
    }

    func testTypedRenameToMainOrAnotherBranchsNameIsRefusedAsTheBarRefusesIt() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch y")
        await run("/branch switch x")

        await run("/branch rename MAIN")
        XCTAssertEqual(lastText(), "**main** is the conversation's main line. **x** keeps its name.")

        await run("/branch rename y")
        XCTAssertEqual(lastText(), "A branch named **y** already exists. **x** keeps its name.")
        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["x", "y"])
    }

    func testTypedRenameInAnotherCaseRenamesAsLowercaseDoes() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch switch x")

        await run("/branch RENAME y")

        XCTAssertEqual(lastText(), "Renamed branch **x** to **y**.")
        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["y"])
    }

    // MARK: - Branch names in another letter case

    func testSwitchingToABranchTypedInAnotherCaseGoesToItAndNamesItAsStored() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch experiment")

        await run("/branch switch Experiment")

        XCTAssertEqual(vm.conversationTree.activeBranchID, try branchID(named: "experiment"))
        XCTAssertEqual(lastText()?.hasPrefix("Switched to branch **experiment**."), true)
    }

    func testDeletingABranchTypedInAnotherCaseDeletesIt() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch experiment")

        await run("/branch delete EXPERIMENT")

        XCTAssertEqual(vm.conversationTree.branchCount, 0)
        XCTAssertEqual(lastText(), "Deleted branch **experiment**.")
    }

    func testBranchingWithAnExistingNameInAnotherCaseIsRefused() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch experiment")

        await run("/branch Experiment")

        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["experiment"])
        XCTAssertEqual(lastText(), "A branch named **experiment** already exists. Use `/branch switch experiment` to go to it, or pick another name.")
    }

    // MARK: - Branching from an earlier message

    func testBranchingFromTheSecondOfFourMessagesSavesTheFirstTwoAsBranch1() async throws {
        let (chatA, texts) = try makeSession("A", texts: ["a1", "a2", "a3", "a4"])
        await vm.switchToSession(chatA)
        let before = vm.messages.map(\.id)
        XCTAssertEqual(before, texts.map(\.id))

        vm.branchFromMessage(id: texts[1].id)

        let branch = try XCTUnwrap(vm.conversationTree.branches.first)
        XCTAssertEqual(vm.conversationTree.branchCount, 1)
        XCTAssertEqual(branch.name, "branch-1")
        XCTAssertEqual(branch.parentMessageID, texts[1].id)
        XCTAssertEqual(branch.messages.map(\.id), [texts[0].id, texts[1].id])
        XCTAssertEqual(Array(vm.messages.dropLast()).map(\.id), before)
        XCTAssertNil(vm.conversationTree.activeBranchID)
        XCTAssertEqual(lastText(), "Saved branch **branch-1** at this point. You are still on **main**; `/branch switch branch-1` to go to it.")
    }

    func testBranchingFromAnIDThatNamesNoMessageSaysSoAndMakesNoBranch() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)

        vm.branchFromMessage(id: UUID())

        XCTAssertEqual(vm.conversationTree.branchCount, 0)
        XCTAssertEqual(vm.messages.last?.sender, .system)
        XCTAssertEqual(lastText(), "That message is no longer in this conversation, so no branch was made.")
    }

    func testBranchingFromAMessageWhenBranch1ExistsNamesItBranch2() async throws {
        let (chatA, texts) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch")

        vm.branchFromMessage(id: texts[0].id)

        XCTAssertEqual(vm.conversationTree.branches.map(\.name), ["branch-1", "branch-2"])
    }

    func testABranchFromAnEarlierMessageSurvivesReopeningTheChat() async throws {
        let (chatA, texts) = try makeSession("A", texts: ["a1", "a2", "a3"])
        await vm.switchToSession(chatA)
        vm.branchFromMessage(id: texts[0].id)
        try await eventually("chat A's sidecar to hold the branch") {
            self.savedBranches(of: chatA)?.branches.map(\.name) == ["branch-1"]
        }

        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(
            id: "test", name: "Test", model: "sonnet",
            systemPrompt: "", tools: [],
            denied: [], permissionMode: "default", state: .idle
        ))
        let reopened = ChatViewModel(agentID: "test", projectURL: tmpDir, orchestrator: orchestrator)
        try await orchestrator.startAgent("test", cwd: tmpDir)
        reopened.setupSessionStore(store)
        await reopened.switchToSession(chatA)

        let branch = try XCTUnwrap(reopened.conversationTree.branches.first)
        XCTAssertEqual(reopened.conversationTree.branches.map(\.name), ["branch-1"])
        XCTAssertEqual(branch.parentMessageID, texts[0].id)
        XCTAssertEqual(branch.messages.map(\.id), [texts[0].id])
    }

    // MARK: - Listing branches

    /// The rows of the `/branch list` reply, after its heading.
    private func listRows() async throws -> [String] {
        await run("/branch list")
        return Array(try XCTUnwrap(lastText()).split(separator: "\n").dropFirst().map(String.init))
    }

    func testListingOnABranchGivesItsLiveCountAndMarksIt() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch switch x")
        let stored = try XCTUnwrap(vm.conversationTree.branches.first?.messages.count)
        await run("/branch list")
        let live = vm.messages.count
        XCTAssertGreaterThan(live, stored)

        let rows = try await listRows()

        XCTAssertEqual(rows, [
            "• main (\(vm.conversationTree.mainMessages.count) msgs)",
            "• x (\(live) msgs) (you are here)",
        ])
    }

    func testListingOnMainGivesMainsLiveCountAndEachBranchItsStoredCount() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)
        await run("/branch x")
        await run("/branch y")
        let x = try XCTUnwrap(vm.conversationTree.branches.first { $0.name == "x" }?.messages.count)
        let y = try XCTUnwrap(vm.conversationTree.branches.first { $0.name == "y" }?.messages.count)
        let live = vm.messages.count

        let rows = try await listRows()

        XCTAssertNil(vm.conversationTree.activeBranchID)
        XCTAssertEqual(rows, [
            "• main (\(live) msgs) (you are here)",
            "• x (\(x) msgs)",
            "• y (\(y) msgs)",
        ])
        XCTAssertEqual(rows.filter { $0.hasSuffix("(you are here)") }.count, 1)
    }

    func testListingWithNoBranchesStillSaysThereAreNone() async throws {
        let (chatA, _) = try makeSession("A", texts: ["a1", "a2"])
        await vm.switchToSession(chatA)

        await run("/branch list")

        XCTAssertEqual(lastText(), "No branches. Use `/branch <name>` to create one from this point.")
    }

    func testOnlyTheMessageABranchWasMadeFromListsIt() async throws {
        let (chatA, messages) = try makeSession("A", texts: ["a1", "a2", "a3", "a4"])
        await vm.switchToSession(chatA)

        vm.branchFromMessage(id: messages[1].id)

        let branch = try XCTUnwrap(vm.conversationTree.branches.first)
        XCTAssertEqual(vm.branchesForked(at: messages[1].id).map(\.id), [branch.id])
        for other in [messages[0], messages[2], messages[3]] {
            XCTAssertTrue(vm.branchesForked(at: other.id).isEmpty)
        }
    }

    func testTheBranchYouAreOnIsNotListedAtItsForkMessage() async throws {
        let (chatA, messages) = try makeSession("A", texts: ["a1", "a2", "a3", "a4"])
        await vm.switchToSession(chatA)
        vm.branchFromMessage(id: messages[1].id)
        let branch = try XCTUnwrap(vm.conversationTree.branches.first)

        await run("/branch switch \(branch.name)")

        XCTAssertEqual(vm.conversationTree.activeBranchID, branch.id)
        XCTAssertTrue(vm.branchesForked(at: messages[1].id).isEmpty)
    }

    func testEveryBranchMadeFromOneMessageIsListed() async throws {
        let (chatA, messages) = try makeSession("A", texts: ["a1", "a2", "a3", "a4"])
        await vm.switchToSession(chatA)

        vm.branchFromMessage(id: messages[1].id)
        vm.branchFromMessage(id: messages[1].id)

        let ids = vm.conversationTree.branches.map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(vm.branchesForked(at: messages[1].id).map(\.id)), Set(ids))
    }
}
