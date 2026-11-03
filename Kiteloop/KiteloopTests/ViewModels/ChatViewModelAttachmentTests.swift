import AppKit
import XCTest
import KiteloopCore
@testable import Kiteloop

@MainActor
final class ChatViewModelAttachmentTests: XCTestCase {
    private var runtime: MockAgentRuntime!
    private var orchestrator: Orchestrator!
    private var vm: ChatViewModel!

    override func setUp() async throws {
        runtime = MockAgentRuntime()
        runtime.events = [
            .result(.init(text: "Done", costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50, cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: []))
        ]
        let eventBus = EventBus(eventsURL: FileManager.default.temporaryDirectory.appending(path: "test-events"))
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let project = KiteloopProject(rootURL: FileManager.default.temporaryDirectory)
        let memoryManager = MemoryManager(project: project)
        orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus, subscriptionEngine: subscriptionEngine, memoryManager: memoryManager)

        let agent = Agent(id: "test-agent", name: "Test", model: "sonnet",
                         systemPrompt: "", tools: [], denied: [],
                         permissionMode: "default", state: .idle)
        orchestrator.addAgent(agent)
        try await orchestrator.startAgent(agent.id, cwd: FileManager.default.temporaryDirectory)

        vm = ChatViewModel(agentID: "test-agent", projectURL: FileManager.default.temporaryDirectory, orchestrator: orchestrator)
    }

    func testAddAttachment() {
        let tempFile = FileManager.default.temporaryDirectory.appending(path: "test.png")
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        vm.addAttachment(url: tempFile)

        XCTAssertEqual(vm.pendingAttachments.count, 1)
        XCTAssertEqual(vm.pendingAttachments.first?.filename, "test.png")
        XCTAssertEqual(vm.pendingAttachments.first?.mimeType, "image/png")
    }

    func testRemoveAttachment() {
        let tempFile = FileManager.default.temporaryDirectory.appending(path: "test.txt")
        try? "hello".data(using: .utf8)?.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        vm.addAttachment(url: tempFile)
        XCTAssertEqual(vm.pendingAttachments.count, 1)

        let id = vm.pendingAttachments.first!.id
        vm.removeAttachment(id: id)
        XCTAssertEqual(vm.pendingAttachments.count, 0)
    }

    func testSendClearsAttachments() async {
        let tempFile = FileManager.default.temporaryDirectory.appending(path: "img.jpg")
        try? Data([0xFF, 0xD8, 0xFF]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        vm.addAttachment(url: tempFile)
        vm.inputText = "describe this"
        XCTAssertEqual(vm.pendingAttachments.count, 1)

        await vm.send()

        XCTAssertEqual(vm.pendingAttachments.count, 0)
    }

    func testSendWithAttachmentPassesToRuntime() async {
        let tempFile = FileManager.default.temporaryDirectory.appending(path: "photo.png")
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        vm.addAttachment(url: tempFile)
        vm.inputText = "what is this"

        await vm.send()

        XCTAssertEqual(runtime.lastSentMessage, "what is this")
        XCTAssertEqual(runtime.lastSentAttachments.count, 1)
        XCTAssertEqual(runtime.lastSentAttachments.first?.filename, "photo.png")
    }

    func testSendWithOnlyAnAttachmentDeliversIt() async {
        vm.pendingAttachments = [ChatAttachment(filename: "shot.png", data: Data([0x89, 0x50]), mimeType: "image/png")]
        vm.inputText = "  \n "
        let before = vm.messages.count

        await vm.send()

        XCTAssertNotNil(runtime.lastSentMessage)
        XCTAssertEqual(runtime.lastSentAttachments.map(\.filename), ["shot.png"])
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        let humanTexts = vm.messages.dropFirst(before).compactMap { message -> String? in
            guard message.sender == .human, case .text(let text) = message.content else { return nil }
            return text
        }
        XCTAssertEqual(humanTexts.count, 1)
        XCTAssertEqual(humanTexts.first, "Attached: shot.png")
        XCTAssertTrue(attachedLines(in: vm.messages.dropFirst(before)).isEmpty)
    }

    func testSendWithTextAndAttachmentNamesTheFilesOnASystemLine() async {
        vm.pendingAttachments = [ChatAttachment(filename: "photo.png", data: Data([0x89, 0x50]), mimeType: "image/png")]
        vm.inputText = "describe this"
        let before = vm.messages.count

        await vm.send()

        let sent = Array(vm.messages.dropFirst(before))
        guard let humanIndex = sent.firstIndex(where: { $0.sender == .human }) else {
            return XCTFail("no human message was recorded")
        }
        guard case .text(let humanText) = sent[humanIndex].content else {
            return XCTFail("the human message is not text")
        }
        XCTAssertEqual(humanText, "describe this")
        let next = sent.dropFirst(humanIndex + 1).first
        XCTAssertEqual(next?.sender, .system)
        guard case .text(let systemText)? = next?.content else {
            return XCTFail("no system text follows the human message")
        }
        XCTAssertEqual(systemText, "Attached: photo.png")
        XCTAssertEqual(InputBar.sentHistory(from: sent), ["describe this"])
        XCTAssertEqual(runtime.lastSentMessage, "describe this")
    }

    func testSendWithTextAndNoAttachmentAddsNoSystemLine() async {
        vm.inputText = "just text"
        let before = vm.messages.count

        await vm.send()

        XCTAssertEqual(runtime.lastSentMessage, "just text")
        XCTAssertTrue(attachedLines(in: vm.messages.dropFirst(before)).isEmpty)
    }

    private func attachedLines(in messages: ArraySlice<Message>) -> [String] {
        messages.compactMap { message -> String? in
            guard message.sender == .system, case .text(let text) = message.content,
                  text.hasPrefix("Attached:") else { return nil }
            return text
        }
    }

    func testSendWithNoTextAndNoAttachmentSendsNothing() async {
        vm.inputText = "   "
        let before = vm.messages.count

        await vm.send()

        XCTAssertNil(runtime.lastSentMessage)
        XCTAssertTrue(runtime.lastSentAttachments.isEmpty)
        XCTAssertEqual(vm.messages.count, before)
    }

    // MARK: - Queued and forwarded messages

    private func attachment(_ filename: String) -> ChatAttachment {
        ChatAttachment(filename: filename, data: Data([0x01]), mimeType: "text/plain")
    }

    /// Sends `text` in the background and returns once its turn is streaming,
    /// so the next `send()` is queued behind it.
    private func startStreamingTurn(_ text: String) async throws -> Task<Void, Never> {
        runtime.startDelay = 300_000_000
        vm.inputText = text
        let turn = Task { await vm.send() }
        try await eventually("the first turn is streaming") { self.vm.isStreaming }
        return turn
    }

    func testQueuedMessageKeepsTheAttachmentsStagedWhenItWasQueued() async throws {
        let turn = try await startStreamingTurn("first")

        vm.pendingAttachments = [attachment("x.txt")]
        vm.inputText = "A"
        await vm.send()
        vm.pendingAttachments = [attachment("y.txt")]
        await turn.value

        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first", "A"])
        XCTAssertEqual(runtime.sentMessages.last?.attachments.map(\.filename), ["x.txt"])
        XCTAssertEqual(vm.pendingAttachments.map(\.filename), ["y.txt"])
    }

    func testQueuingWhileStreamingEmptiesTheTray() async throws {
        let turn = try await startStreamingTurn("first")

        vm.pendingAttachments = [attachment("x.txt")]
        vm.inputText = "A"
        await vm.send()

        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        XCTAssertEqual(vm.queuedMessageCount, 1)
        await turn.value
    }

    func testTwoQueuedMessagesEachCarryTheirOwnAttachmentsInOrder() async throws {
        let turn = try await startStreamingTurn("first")

        vm.pendingAttachments = [attachment("a.txt")]
        vm.inputText = "A"
        await vm.send()
        vm.pendingAttachments = [attachment("b1.txt"), attachment("b2.txt")]
        vm.inputText = "B"
        await vm.send()
        await turn.value

        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first", "A", "B"])
        XCTAssertEqual(runtime.sentMessages.map { $0.attachments.map(\.filename) },
                       [[], ["a.txt"], ["b1.txt", "b2.txt"]])
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
    }

    func testForwardedMessageLeavesTheStagedAttachmentsInTheTray() async throws {
        vm.pendingAttachments = [attachment("z.txt")]

        NotificationCenter.default.post(
            name: .agentTriggered, object: orchestrator,
            userInfo: ["agentID": "test-agent", "message": "from a teammate"]
        )
        try await eventually("the forwarded message reached the runtime") {
            self.runtime.sentMessages.count == 1 && !self.vm.isStreaming
        }

        XCTAssertEqual(runtime.lastSentMessage, "from a teammate")
        XCTAssertTrue(runtime.lastSentAttachments.isEmpty)
        XCTAssertEqual(vm.pendingAttachments.map(\.filename), ["z.txt"])
    }

    func testAForwardReplayedAfterTheTurnLeavesTheDraftBeingTyped() async throws {
        let turn = try await startStreamingTurn("first")
        NotificationCenter.default.post(
            name: .agentTriggered, object: orchestrator,
            userInfo: ["agentID": "test-agent", "message": "from a teammate"]
        )
        try await eventually("the forward is queued") { self.vm.queuedMessageCount == 1 }
        vm.inputText = "half-typed"

        await turn.value

        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first", "from a teammate"])
        XCTAssertEqual(vm.inputText, "half-typed")
    }

    // MARK: - Stop hands the queue back

    func testInterruptReturnsAQueuedMessageToTheInputInsteadOfSendingIt() async throws {
        let turn = try await startStreamingTurn("first")
        vm.inputText = "A"
        await vm.send()

        vm.interrupt()
        await turn.value

        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first"])
        XCTAssertEqual(vm.queuedMessageCount, 0)
        XCTAssertEqual(vm.inputText, "A")
    }

    func testInterruptReturnsTwoQueuedMessagesOldestFirstAheadOfWhatWasTyped() async throws {
        let turn = try await startStreamingTurn("first")
        vm.inputText = "A"
        await vm.send()
        vm.inputText = "B"
        await vm.send()
        vm.inputText = "C"

        vm.interrupt()
        await turn.value

        XCTAssertEqual(vm.inputText, "A\n\nB\n\nC")
        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first"])
    }

    func testInterruptReturnsAQueuedMessagesAttachmentsToTheTrayUnsent() async throws {
        let turn = try await startStreamingTurn("first")
        vm.pendingAttachments = [attachment("x.txt")]
        vm.inputText = "A"
        await vm.send()
        vm.pendingAttachments = [attachment("y.txt")]

        vm.interrupt()
        await turn.value

        XCTAssertEqual(vm.pendingAttachments.map(\.filename), ["y.txt", "x.txt"])
        XCTAssertEqual(runtime.sentMessages.flatMap { $0.attachments.map(\.filename) }, [])
    }

    func testInterruptStillDeliversAMessageATeammateForwardedDuringTheTurn() async throws {
        let turn = try await startStreamingTurn("first")
        vm.inputText = "A"
        await vm.send()
        NotificationCenter.default.post(
            name: .agentTriggered, object: orchestrator,
            userInfo: ["agentID": "test-agent", "message": "from a teammate"]
        )
        try await eventually("the forward is queued") { self.vm.queuedMessageCount == 2 }

        vm.interrupt()
        await turn.value

        XCTAssertEqual(runtime.sentMessages.map(\.message), ["first", "from a teammate"])
        XCTAssertEqual(vm.inputText, "A")
    }

    // MARK: - Files the chat cannot take

    func testAFileThatCannotBeReadIsNamedInTheChat() throws {
        let directory = try makeTemporaryDirectory()
        let missing = directory.appending(path: "gone.txt")
        let before = vm.messages.count

        vm.addAttachment(url: missing)

        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        let error = try XCTUnwrap(errorTexts(after: before).first)
        XCTAssertTrue(error.contains("gone.txt"), error)
        XCTAssertTrue(error.contains("could not be read"), error)
    }

    func testAFileOverTheCeilingIsRefusedWithItsSize() throws {
        let directory = try makeTemporaryDirectory()
        let huge = directory.appending(path: "huge.bin")
        try writeSparseFile(at: huge, ofSize: ChatAttachment.maxBytes + 5 * 1_048_576)
        let before = vm.messages.count

        vm.addAttachment(url: huge)

        XCTAssertTrue(vm.pendingAttachments.isEmpty)
        let error = try XCTUnwrap(errorTexts(after: before).first)
        XCTAssertTrue(error.contains("huge.bin"), error)
        XCTAssertTrue(error.contains("15.0 MB"), error)
        XCTAssertTrue(error.contains("10 MB limit"), error)
    }

    func testAReadableFileStillAttachesAndSaysNothing() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appending(path: "shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        let before = vm.messages.count

        vm.addAttachment(url: file)

        XCTAssertEqual(vm.pendingAttachments.map(\.filename), ["shot.png"])
        XCTAssertEqual(vm.pendingAttachments.first?.mimeType, "image/png")
        XCTAssertEqual(errorTexts(after: before), [])
    }

    /// What a drop of a readable file and one over the ceiling reaches the view
    /// model as: the readable one is staged, the large one is named with why.
    func testAFileDroppedBesideAnOverCeilingOneIsStagedAndTheOtherRefused() throws {
        let directory = try makeTemporaryDirectory()
        let note = directory.appending(path: "note.txt")
        try Data("hello".utf8).write(to: note)
        let huge = directory.appending(path: "huge.bin")
        try writeSparseFile(at: huge, ofSize: ChatAttachment.maxBytes + 5 * 1_048_576)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kiteloop-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        addTeardownBlock { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([note as NSURL, huge as NSURL])
        let before = vm.messages.count

        let input = InputTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        input.onFileURLs = { urls in urls.forEach { self.vm.addAttachment(url: $0) } }
        XCTAssertTrue(input.takeAttachments(from: pasteboard))

        XCTAssertEqual(vm.pendingAttachments.map(\.filename), ["note.txt"])
        let error = try XCTUnwrap(errorTexts(after: before).first)
        XCTAssertTrue(error.contains("huge.bin"), error)
        XCTAssertTrue(error.contains("10 MB limit"), error)
    }

    private func errorTexts(after count: Int) -> [String] {
        vm.messages.dropFirst(count).compactMap { message in
            guard case .error(let text) = message.content else { return nil }
            return text
        }
    }

    /// A file of `size` bytes that costs no disk — only its recorded size matters.
    private func writeSparseFile(at url: URL, ofSize size: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }
}

/// A message that mentions a catalog specialist summons it, and the files in
/// the tray go with that message rather than disappearing.
@MainActor
final class ChatViewModelSummonAttachmentTests: XCTestCase {
    private var vm: ChatViewModel!

    override func setUp() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "summon-attachments")
        let orchestrator = Orchestrator(runtime: MockAgentRuntime())
        orchestrator.addAgent(Agent(id: "lead", name: "Lead", model: "sonnet", systemPrompt: "", tools: [],
                                    denied: [], permissionMode: "default", state: .idle))
        try await orchestrator.startAgent("lead", cwd: tempDir)
        let catalog = AgentCatalogStore(storageURL: tempDir.appending(path: "catalog.json"))
        catalog.add(AgentTemplate(id: "reviewer-t", name: "Reviewer"))
        catalog.add(AgentTemplate(id: "designer-t", name: "Designer"))
        vm = ChatViewModel(agentID: "lead", projectURL: tempDir, orchestrator: orchestrator)
        vm.configure(catalogStore: catalog)
        vm.pendingAttachments = [
            ChatAttachment(filename: "shot.png", data: Data([0x89, 0x50]), mimeType: "image/png"),
            ChatAttachment(filename: "notes.txt", data: Data("hi".utf8), mimeType: "text/plain"),
        ]
    }

    /// The files each `.agentSummoned` post carried, in post order.
    private func sendCollectingSummons(_ text: String) async -> [[String]] {
        var summoned: [[String]] = []
        let token = NotificationCenter.default.addObserver(forName: .agentSummoned, object: nil, queue: nil) { note in
            let files = note.userInfo?[Notification.summonedAttachmentsKey] as? [ChatAttachment] ?? []
            summoned.append(files.map(\.filename))
        }
        defer { NotificationCenter.default.removeObserver(token) }
        vm.inputText = text
        await vm.send()
        return summoned
    }

    func testASummonedSpecialistIsSentTheTraysFilesAndTheTrayEmpties() async {
        let summoned = await sendCollectingSummons("@reviewer what do you think of this?")
        XCTAssertEqual(summoned, [["shot.png", "notes.txt"]])
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
    }

    func testTwoSpecialistsNamedInOneMessageEachGetTheSameFiles() async {
        let summoned = await sendCollectingSummons("@reviewer and @designer, thoughts?")
        XCTAssertEqual(summoned, [["shot.png", "notes.txt"], ["shot.png", "notes.txt"]])
        XCTAssertTrue(vm.pendingAttachments.isEmpty)
    }
}

/// The chat hands every rate-limit reading to the orchestrator, which is where
/// the autopilot asks whether the account's usage limit stopped a run.
@MainActor
final class ChatViewModelUsageLimitTests: XCTestCase {
    func testARefusedReadingSetsTheStandingLimit() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "chat-usage-limit")
        let runtime = MockAgentRuntime()
        let reset = Date().addingTimeInterval(3_600)
        runtime.events = [
            .system(subtype: AgentActivityEvent.rateLimitType, payload: [
                "type": AgentActivityEvent.rateLimitType,
                "rate_limit_info": ["status": "rejected", "rateLimitType": "five_hour",
                                    "resetsAt": reset.timeIntervalSince1970],
            ]),
            .result(.init(text: "", costUSD: 0, durationMs: 1, inputTokens: 0, outputTokens: 0,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s",
                          permissionDenials: [])),
        ]
        let orchestrator = Orchestrator(runtime: runtime)
        orchestrator.addAgent(Agent(id: "worker", name: "Worker", model: "sonnet", systemPrompt: "", tools: [],
                                    denied: [], permissionMode: "default", state: .idle))
        try await orchestrator.startAgent("worker", cwd: tempDir)
        let vm = ChatViewModel(agentID: "worker", projectURL: tempDir, orchestrator: orchestrator)
        vm.inputText = "go"
        await vm.send()

        let limit = try XCTUnwrap(orchestrator.usageLimit(standingAt: Date()))
        XCTAssertEqual(limit.resetsAt.timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(limit.resetReported)
    }
}
