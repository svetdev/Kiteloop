import XCTest
import KiteloopCore
@testable import Kiteloop

/// `POST /v1/agents/message` answering as soon as the message is in, and
/// `GET /v1/agents/events` carrying the reply as it streams. Driven over a real
/// loopback socket against a scripted runtime, so the path from the phone's
/// request to the chat view model and back out over SSE is the one the app runs.
@MainActor
final class KiteloopControlServerAgentEventsTests: XCTestCase {

    private var tempDir: URL!
    private var registry: ControlSessionRegistry!
    private var harness: ControlServerHarness!
    private var runtime: MockAgentRuntime!

    override func setUp() async throws {
        tempDir = try makeTemporaryDirectory(prefix: "control-agent-events")
        registry = ControlSessionRegistry()
        runtime = MockAgentRuntime()
        harness = try await ControlServerHarness.start(registry: registry)
    }

    override func tearDown() async throws {
        harness?.stop()
        harness = nil
        registry = nil
        runtime = nil
    }

    // MARK: - Usage

    /// The rate limit an agent's CLI reported reaches `GET /v1/usage`, the
    /// one closest to its limit across the agents.
    func testUsageReportsTheAgentClosestToItsRateLimit() async throws {
        let session = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: session)
        let warning: [String: Any] = [
            "type": "rate_limit_event",
            "rate_limit_info": ["status": "allowed_warning", "rateLimitType": "five_hour",
                                "unifiedWindows": ["five_hour": ["utilization": 0.9]]],
        ]
        runtime.events = [.system(subtype: AgentActivityEvent.rateLimitType, payload: warning),
                          .assistantText("ok"), .result(Self.done("ok"))]
        _ = try await harness.post("/v1/agents/message",
                                   ["project": "alpha", "agent": "Builder", "message": "go", "wait": true], timeout: 30)

        let (status, body) = try await harness.get("/v1/usage")

        XCTAssertEqual(status, 200)
        let limit = try XCTUnwrap(body["rateLimit"] as? [String: Any], "\(body)")
        XCTAssertEqual(limit["status"] as? String, "allowed_warning")
        XCTAssertEqual(limit["window"] as? String, "five_hour")
        XCTAssertEqual(limit["utilization"] as? Double, 0.9)
        XCTAssertEqual(body["agentsReporting"] as? Int, 1)
    }

    func testUsageWithNoAgentReportingSaysNull() async throws {
        let session = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: session)

        let (status, body) = try await harness.get("/v1/usage")

        XCTAssertEqual(status, 200)
        XCTAssertTrue(body["rateLimit"] is NSNull, "\(body)")
        XCTAssertEqual(body["agentsReporting"] as? Int, 0)
        XCTAssertTrue(body["spend"] is NSNull, "this server keeps no metrics")
    }

    // MARK: - Sending

    /// The defect: the request was held open for the agent's whole turn. A
    /// runtime that takes seconds before its first word must not hold it.
    func testAMessageToAnIdleAgentIsAnsweredBeforeTheAgentReplies() async throws {
        let session = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: session)
        runtime.startDelay = 3_000_000_000
        runtime.events = [.assistantText("the reply"), .result(Self.done("the reply"))]

        let started = Date()
        let (status, body) = try await harness.post("/v1/agents/message",
                                                    ["project": "alpha", "agent": "Builder", "message": "go"])

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["started"] as? Bool, true)
        XCTAssertEqual(body["queued"] as? Bool, false)
        XCTAssertNil(body["reply"], "the reply comes over the stream, not in this answer")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "answered without waiting out the turn")
        let vm = try XCTUnwrap(session.chatViewModels[agentID])
        XCTAssertFalse(vm.messages.contains { if case .text("the reply") = $0.content { return true }; return false })
    }

    /// `wait: true` is the old contract, kept for scripts: the reply in the answer.
    func testWaitTrueStillAnswersWithTheReply() async throws {
        let session = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: session)
        runtime.events = [.result(Self.done("Done"))]

        let (status, body) = try await harness.post(
            "/v1/agents/message",
            ["project": "alpha", "agent": "Builder", "message": "go", "wait": true],
            timeout: 30)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["reply"] as? String, "Done")
        XCTAssertEqual(body["queued"] as? Bool, false)
    }

    /// A screenshot taken on the phone reaches the agent attached to the
    /// message, as a file dropped on the Mac's input would.
    func testAMessageWithAnImageReachesTheAgentWithItAttached() async throws {
        let session = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: session)
        runtime.events = [.result(Self.done("Seen it"))]
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let (status, _) = try await harness.post("/v1/agents/message", [
            "project": "alpha", "agent": "Builder", "message": "this is wrong", "wait": true,
            "attachments": [["filename": "screenshot.png", "mediaType": "image/png", "data": png.base64EncodedString()]],
        ], timeout: 30)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(runtime.lastSentAttachments.map(\.filename), ["screenshot.png"])
        XCTAssertEqual(runtime.lastSentAttachments.first?.data, png)
    }

    func testANonImageAttachmentIs415AndNothingIsSent() async throws {
        let session = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: session)

        let (status, _) = try await harness.post("/v1/agents/message", [
            "project": "alpha", "agent": "Builder", "message": "read this",
            "attachments": [["filename": "notes.pdf", "mediaType": "application/pdf", "data": Data("x".utf8).base64EncodedString()]],
        ])

        XCTAssertEqual(status, 415)
        XCTAssertTrue(runtime.sentMessages.isEmpty)
    }

    func testANonBooleanWaitIs400() async throws {
        let session = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: session)

        let (status, _) = try await harness.post("/v1/agents/message",
                                                 ["project": "alpha", "agent": "Builder", "message": "go", "wait": "yes"])

        XCTAssertEqual(status, 400)
    }

    // MARK: - The stream

    /// The reply's text reaches the stream while the agent is still working —
    /// between the turn's start and its end — which is what makes the phone's
    /// chat live rather than a reload after the fact.
    func testTheStreamDeliversTheReplyBeforeTheTurnEnds() async throws {
        let session = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: session)
        runtime.events = [.assistantText("Found it"), .result(Self.done("Found it"))]

        let stream = try await openStream("/v1/agents/events?project=alpha&agent=Builder")
        let first = try await stream.next()
        XCTAssertEqual(first["type"] as? String, "state", "a connection opens with the agent's state")
        XCTAssertEqual(first["working"] as? Bool, false)

        _ = try await harness.post("/v1/agents/message", ["project": "alpha", "agent": "Builder", "message": "fix it"])

        var sawWorking = false
        var replyWhileWorking = false
        while true {
            let event = try await stream.next()
            if event["type"] as? String == "state" {
                if event["working"] as? Bool == true { sawWorking = true; continue }
                if sawWorking { break }
            }
            let message = event["message"] as? [String: Any]
            // An agent's own messages carry its id as the sender.
            if sawWorking, message?["sender"] as? String == agentID, message?["text"] as? String == "Found it" {
                replyWhileWorking = true
            }
        }
        stream.cancel()
        XCTAssertTrue(sawWorking)
        XCTAssertTrue(replyWhileWorking, "the agent's text arrived between the turn starting and ending")
    }

    /// The message the phone sent comes back over the stream too, so the chat
    /// shows it in the order the Mac does.
    func testTheStreamCarriesTheSentMessage() async throws {
        let session = try registerProject(named: "alpha")
        addAgent(named: "Builder", to: session)
        runtime.events = [.result(Self.done("ok"))]

        let stream = try await openStream("/v1/agents/events?project=alpha&agent=Builder")
        _ = try await stream.next()
        _ = try await harness.post("/v1/agents/message", ["project": "alpha", "agent": "Builder", "message": "hello there"])

        var found = false
        while !found {
            let event = try await stream.next()
            let message = event["message"] as? [String: Any]
            found = message?["sender"] as? String == "you" && message?["text"] as? String == "hello there"
        }
        stream.cancel()
    }

    /// Reconnecting with the last id seen replays only what came after it.
    func testReconnectingWithAfterReplaysOnlyWhatCameAfterIt() async throws {
        let session = try registerProject(named: "alpha")
        let agentID = addAgent(named: "Builder", to: session)
        runtime.events = [.assistantText("one"), .result(Self.done("one"))]
        _ = try await harness.post("/v1/agents/message",
                                   ["project": "alpha", "agent": "Builder", "message": "first", "wait": true],
                                   timeout: 30)
        let vm = try XCTUnwrap(session.chatViewModels[agentID])
        let flattened = AgentTranscript.tail(of: vm.messages, limit: 50)
        XCTAssertGreaterThan(flattened.count, 1)
        let firstID = try XCTUnwrap(flattened.first?["id"] as? String)
        let laterIDs = flattened.dropFirst().compactMap { $0["id"] as? String }

        let stream = try await openStream("/v1/agents/events?project=alpha&agent=Builder&after=\(firstID)")
        var replayed: [String] = []
        while replayed.count < laterIDs.count {
            let event = try await stream.next()
            if let id = (event["message"] as? [String: Any])?["id"] as? String { replayed.append(id) }
        }
        stream.cancel()

        XCTAssertEqual(replayed, laterIDs)
        XCTAssertFalse(replayed.contains(firstID))
    }

    func testTheStreamOfAnUnknownAgentIs404AndMissingAgentIs400() async throws {
        try registerProject(named: "alpha")

        let (unknown, _) = try await harness.get("/v1/agents/events?project=alpha&agent=nobody")
        XCTAssertEqual(unknown, 404)
        let (missing, _) = try await harness.get("/v1/agents/events?project=alpha")
        XCTAssertEqual(missing, 400)
    }

    // MARK: - Helpers

    /// An open SSE connection, read one `data:` frame at a time. Each read is
    /// bounded by the request's timeout, so a stream that never sends fails the
    /// test instead of hanging it.
    @MainActor
    final class EventStream {
        private var lines: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator
        private let task: URLSessionDataTask

        init(bytes: URLSession.AsyncBytes) {
            lines = bytes.lines.makeAsyncIterator()
            task = bytes.task
        }

        func next() async throws -> [String: Any] {
            var iterator = lines
            defer { lines = iterator }
            while let line = try await iterator.next() {
                guard line.hasPrefix("data: ") else { continue }
                let data = Data(line.dropFirst(6).utf8)
                if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
            }
            throw URLError(.networkConnectionLost)
        }

        func cancel() { task.cancel() }
    }

    private func openStream(_ path: String) async throws -> EventStream {
        var request = URLRequest(url: harness.url(path))
        request.timeoutInterval = ControlServerHarness.defaultTimeout
        request.setValue("Bearer \(harness.token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await harness.session.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return EventStream(bytes: bytes)
    }

    private static func done(_ text: String) -> StreamEvent.ResultPayload {
        .init(text: text, costUSD: 0.01, durationMs: 500, inputTokens: 100, outputTokens: 50,
              cacheCreationInputTokens: 0, cacheReadInputTokens: 0, sessionID: "s1", permissionDenials: [])
    }

    @discardableResult
    private func registerProject(named name: String) throws -> ProjectSession {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL = URL(fileURLWithPath: root.path(percentEncoded: false), isDirectory: false)
        let project = KiteloopProject(rootURL: rootURL)
        try project.ensureDirectoryExists()

        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: runtime,
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: MemoryManager(project: project)
        )
        let session = ProjectSession(
            project: project,
            projectURL: rootURL,
            orchestrator: orchestrator,
            sessionStore: SessionStore(projectDir: rootURL),
            knowledgeStore: AgentKnowledgeStore(baseURL: project.knowledgeURL),
            knowledgeIndex: KnowledgeIndex(baseURL: project.knowledgeURL),
            context: makeContext()
        )
        registry.register(session: session, autopilot: BacklogAutopilot())
        return session
    }

    @discardableResult
    private func addAgent(named name: String, to projectSession: ProjectSession) -> String {
        let agent = Agent(name: name, model: "sonnet", systemPrompt: "", tools: [], denied: [],
                          permissionMode: "acceptEdits")
        projectSession.orchestrator.addAgent(agent)
        return agent.id
    }

    private func makeContext() -> ProjectSessionContext {
        ProjectSessionContext(
            runtimeFactory: { [runtime] in runtime! },
            agentCatalogStore: AgentCatalogStore(storageURL: tempDir.appendingPathComponent("catalog.json")),
            packageResolver: nil,
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appendingPathComponent("global.json")),
            orgManifestLoader: OrgManifestLoader(),
            repoCloneService: RepoCloneService()
        )
    }
}
