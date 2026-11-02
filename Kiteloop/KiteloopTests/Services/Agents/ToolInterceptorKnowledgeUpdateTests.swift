import NaturalLanguage
import XCTest
import KiteloopCore
@testable import Kiteloop

/// `save_knowledge` answers the agent, and the answer is the only thing the agent
/// has to go on: an entry it was told was updated is one it will not save again.
/// The update path used to write with `try?` and report success either way, so a
/// write that never landed read exactly like one that did — which is what
/// `ToolInterceptor.appendKnowledgeUpdate` now throws for.
final class ToolInterceptorKnowledgeUpdateTests: XCTestCase {
    private var tmpDir: URL!
    private var entryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = try makeTemporaryDirectory(prefix: "knowledge-update")
        entryURL = tmpDir.appending(path: "entry.md")
    }

    override func tearDownWithError() throws {
        tmpDir = nil
        entryURL = nil
        try super.tearDownWithError()
    }

    /// Makes the entry's directory unwritable for the duration of the test — an
    /// atomic write cannot create its temporary file there, so the write fails
    /// with the entry already on disk untouched.
    private func sealEntryDirectory() throws {
        let fm = FileManager.default
        let path = tmpDir.path(percentEncoded: false)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        addTeardownBlock {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    private func append(_ content: String, existing: String) throws {
        try ToolInterceptor.appendKnowledgeUpdate(
            content,
            to: entryURL,
            existing: existing,
            agentID: "tester",
            timestamp: "2026-08-12T09:00:00Z"
        )
    }

    // MARK: - What lands

    func testTheUpdateFollowsTheTextAlreadyThere() throws {
        let existing = "# Deploys\n\nDeploys run on Thursday."
        try existing.write(to: entryURL, atomically: true, encoding: .utf8)

        try append("They now run on Tuesday.", existing: existing)

        let written = try String(contentsOf: entryURL, encoding: .utf8)
        XCTAssertEqual(
            written,
            existing + "\n\n---\n_Updated 2026-08-12T09:00:00Z by tester:_\n\nThey now run on Tuesday.",
            "the update is appended, and what the entry already said stays put"
        )
        XCTAssertTrue(written.hasPrefix(existing), "an update must not overwrite the entry it is updating")
    }

    // MARK: - What does not

    func testASealedDirectoryThrowsAndLeavesTheEntryAsItWas() throws {
        let existing = "Deploys run on Thursday."
        try existing.write(to: entryURL, atomically: true, encoding: .utf8)
        try sealEntryDirectory()

        XCTAssertThrowsError(try append("They now run on Tuesday.", existing: existing),
                             "a write that cannot land has to say so rather than be swallowed")

        XCTAssertEqual(try String(contentsOf: entryURL, encoding: .utf8), existing,
                       "the entry on disk still holds exactly what it held before")
    }

    func testContentPastTheCeilingIsRefusedAndNothingIsWritten() throws {
        // One byte short of the 8192-byte ceiling, so any update at all passes it.
        let existing = String(repeating: "a", count: 8191)
        try existing.write(to: entryURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try append("One more fact.", existing: existing)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "updating existing entry would exceed max file size (8KB). Use conflict_policy: 'always_new' instead.",
                "the refusal keeps the wording that tells the agent what to do instead"
            )
        }

        XCTAssertEqual(try String(contentsOf: entryURL, encoding: .utf8), existing,
                       "a refused update writes nothing")
    }

    /// The ceiling is on the whole file, not on the appended block — an update
    /// that fits is written.
    func testAnUpdateThatFitsUnderTheCeilingIsWritten() throws {
        let existing = String(repeating: "a", count: 8000)
        try existing.write(to: entryURL, atomically: true, encoding: .utf8)

        try append("Short.", existing: existing)

        let written = try String(contentsOf: entryURL, encoding: .utf8)
        XCTAssertTrue(written.hasSuffix("Short."))
        XCTAssertLessThanOrEqual(written.utf8.count, 8192)
    }
}

// MARK: - The branch that reports it

/// The `update_if_similar` branch of `ChatViewModel.handleSaveKnowledge(input:)`,
/// driven end to end through the MCP tool-call path so the assertion is on the
/// string the agent is actually handed, not on the helper it calls.
@MainActor
final class SaveKnowledgeUpdateReportingTests: XCTestCase {
    private var tmpDir: URL!
    private var project: KiteloopProject!

    private let agentID = "tester"
    /// Saved after an entry holding the same sentence: the match scores well
    /// above the 0.85 threshold, which is what sends the call down the update
    /// branch rather than the new-entry one.
    private let fact = "Deployments run every Thursday using ArgoCD and Kubernetes."

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Canonical, because `KnowledgeIndex` trims its own base path off each
        // file to get the relative path the handler resolves the match from, and
        // that trim does not match through the /var symlink.
        let parent = FileManager.default.temporaryDirectory
        var canonicalParent = parent
        if let resolved = realpath(parent.path(percentEncoded: false), nil) {
            canonicalParent = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        }
        tmpDir = canonicalParent.appending(path: "save-knowledge-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        project = KiteloopProject(rootURL: tmpDir)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        tmpDir = nil
        try super.tearDownWithError()
    }

    /// Where the seeded entry lives — and the directory a failing write would
    /// have to stage its temporary file in.
    private var entryDirectory: URL {
        project.knowledgeURL
            .appending(path: "agents")
            .appending(path: agentID)
            .appending(path: "knowledge")
            .appending(path: "observation")
    }

    private var seedPath: String { "agents/\(agentID)/knowledge/observation/seed.md" }

    /// Seeds an entry, indexes it, then runs one `save_knowledge` call of the
    /// same fact through the stream and returns what the agent was told.
    ///
    /// Skips when this machine has no sentence embedding: `KnowledgeIndex`
    /// indexes nothing without one, so nothing can match and the branch under
    /// test is never reached.
    private func saveTheSameFactAgain(sealingTheDirectory sealed: Bool) async throws -> String {
        try XCTSkipIf(NLEmbedding.sentenceEmbedding(for: .english) == nil,
                      "no sentence embedding here — KnowledgeIndex indexes nothing, so nothing matches")

        let eventBus = EventBus(eventsURL: tmpDir.appending(path: "events"))
        let subscriptionEngine = SubscriptionEngine(eventBus: eventBus)
        let runtime = MockAgentRuntime()
        let orchestrator = Orchestrator(runtime: runtime, eventBus: eventBus,
                                        subscriptionEngine: subscriptionEngine,
                                        memoryManager: MemoryManager(project: project))
        let agent = Agent(id: agentID, name: "Tester", model: "sonnet",
                          systemPrompt: "", tools: ["save_knowledge"], denied: [],
                          permissionMode: "default", state: .idle)
        orchestrator.addAgent(agent)

        try FileManager.default.createDirectory(at: entryDirectory, withIntermediateDirectories: true)
        try (fact + "\n").write(to: entryDirectory.appending(path: "seed.md"), atomically: true, encoding: .utf8)

        let index = KnowledgeIndex(baseURL: project.knowledgeURL)
        await index.start()

        if sealed {
            let fm = FileManager.default
            let path = entryDirectory.path(percentEncoded: false)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
            addTeardownBlock {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
        }

        let input = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: ["content": fact, "type": "observation"]),
            encoding: .utf8
        ))
        runtime.events = [
            .mcpToolCall(.init(requestID: "mcp-1", toolName: "save_knowledge", input: input)),
            .result(.init(text: "done", costUSD: 0, durationMs: 1,
                          inputTokens: 1, outputTokens: 1,
                          cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                          sessionID: "s-\(agentID)", permissionDenials: []))
        ]
        try await orchestrator.startAgent(agentID, cwd: tmpDir)

        let viewModel = ChatViewModel(agentID: agentID, projectURL: tmpDir, orchestrator: orchestrator)
        viewModel.configure(catalogStore: AgentCatalogStore(storageURL: tmpDir.appending(path: "catalog.json")),
                            knowledgeIndex: index)
        viewModel.inputText = "save that"
        await viewModel.send()
        return try XCTUnwrap(runtime.mcpToolResults.last)
    }

    func testAnUpdateThatLandedIsReportedAsUpdated() async throws {
        let result = try await saveTheSameFactAgain(sealingTheDirectory: false)

        XCTAssertTrue(result.hasPrefix("Updated existing entry: \(seedPath)"),
                      "a write that landed reports the entry it updated, got: \(result)")
        let written = try String(contentsOf: entryDirectory.appending(path: "seed.md"), encoding: .utf8)
        XCTAssertTrue(written.contains("_Updated "), "and the update is on disk")
    }

    func testAnUpdateThatCouldNotBeWrittenIsReportedAsAnError() async throws {
        let result = try await saveTheSameFactAgain(sealingTheDirectory: true)

        XCTAssertFalse(result.hasPrefix("Updated existing entry:"),
                       "a write that never landed must not be reported as saved, got: \(result)")
        XCTAssertTrue(result.hasPrefix("Error:"), "got: \(result)")
        XCTAssertTrue(result.contains(seedPath),
                      "the error names the entry that was not updated, got: \(result)")
    }
}
