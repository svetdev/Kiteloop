import XCTest
import KiteloopCore
@testable import Kiteloop

final class MemoryManagerTests: XCTestCase {
    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "memory-manager")
        project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()
    }

    func testProposeCreatesApendingProposal() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(agentID: "coder", content: "Learned: use async/await for concurrency")

        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.agentID, "coder")

        let pending = await manager.pendingProposals()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, proposal.id)
    }

    func testApproveWritesToMemory() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(agentID: "coder", content: "Pattern: use actors for shared state")

        try await manager.approve(proposalID: proposal.id)

        let memory = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(memory.contains("Pattern: use actors for shared state"))

        let pending = await manager.pendingProposals()
        XCTAssertEqual(pending.count, 0)
    }

    func testRejectRemovesFromPending() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(agentID: "coder", content: "Something wrong")

        try await manager.reject(proposalID: proposal.id)

        let pending = await manager.pendingProposals()
        XCTAssertEqual(pending.count, 0)

        let memory = await manager.currentMemory(agentID: "coder")
        XCTAssertFalse(memory.contains("Something wrong"))
    }

    func testEditWritesModifiedContent() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(agentID: "coder", content: "Original content")

        try await manager.edit(proposalID: proposal.id, newContent: "Edited content")

        let memory = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(memory.contains("Edited content"))
        XCTAssertFalse(memory.contains("Original content"))
    }

    func testEditRecordsBothProposedAndApprovedContentOnDisk() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(agentID: "coder", content: "Original content")

        try await manager.edit(proposalID: proposal.id, newContent: "Edited content")

        let url = project.agentDir(for: "coder").appending(path: "proposals/\(proposal.id).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(MemoryProposal.self, from: try Data(contentsOf: url))

        XCTAssertEqual(onDisk.status, .edited)
        XCTAssertEqual(onDisk.proposedContent, "Original content")
        XCTAssertEqual(onDisk.approvedContent, "Edited content")
    }

    func testApproveAndRejectLeaveApprovedContentNil() async throws {
        let manager = MemoryManager(project: project)
        let approved = try await manager.proposeUpdate(agentID: "coder", content: "Approve me")
        let rejected = try await manager.proposeUpdate(agentID: "coder", content: "Reject me")

        try await manager.approve(proposalID: approved.id)
        try await manager.reject(proposalID: rejected.id)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dir = project.agentDir(for: "coder").appending(path: "proposals")
        let approvedOnDisk = try decoder.decode(
            MemoryProposal.self,
            from: try Data(contentsOf: dir.appending(path: "\(approved.id).json"))
        )
        let rejectedOnDisk = try decoder.decode(
            MemoryProposal.self,
            from: try Data(contentsOf: dir.appending(path: "\(rejected.id).json"))
        )

        XCTAssertNil(approvedOnDisk.approvedContent)
        XCTAssertNil(rejectedOnDisk.approvedContent)
    }

    func testProposalWithoutApprovedContentKeyStillDecodes() throws {
        let json = """
        {
            "id": "legacy-1",
            "agentID": "coder",
            "timestamp": "2026-01-01T00:00:00Z",
            "proposedContent": "Some fact",
            "status": "approved"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let proposal = try decoder.decode(MemoryProposal.self, from: Data(json.utf8))

        XCTAssertNil(proposal.approvedContent)
        XCTAssertEqual(proposal.proposedContent, "Some fact")
    }

    func testMultipleApprovalsAccumulate() async throws {
        let manager = MemoryManager(project: project)
        let p1 = try await manager.proposeUpdate(agentID: "coder", content: "First learning")
        let p2 = try await manager.proposeUpdate(agentID: "coder", content: "Second learning")

        try await manager.approve(proposalID: p1.id)
        try await manager.approve(proposalID: p2.id)

        let memory = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(memory.contains("First learning"))
        XCTAssertTrue(memory.contains("Second learning"))
    }

    func testComposeSystemContext() async throws {
        let manager = MemoryManager(project: project)

        try "This is a Swift macOS app.".write(to: project.contextURL, atomically: true, encoding: .utf8)

        let p = try await manager.proposeUpdate(agentID: "coder", content: "Always use structured concurrency")
        try await manager.approve(proposalID: p.id)

        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "You are a senior developer.",
            tools: [], denied: [],
            permissionMode: "acceptEdits", state: .idle
        )

        let composed = await manager.composeSystemContext(agent: agent)
        XCTAssertTrue(composed.contains("You are a senior developer."))
        XCTAssertTrue(composed.contains("This is a Swift macOS app."))
        XCTAssertTrue(composed.contains("Always use structured concurrency"))
    }

    func testSharedContextEmpty() async {
        let manager = MemoryManager(project: project)
        let context = await manager.sharedContext()
        XCTAssertEqual(context, "")
    }

    func testSaveSharedContextWritesTheFile() async throws {
        let manager = MemoryManager(project: project)

        try await manager.saveSharedContext("This is a Swift macOS app.")

        let onDisk = try String(contentsOf: project.contextURL, encoding: .utf8)
        XCTAssertEqual(onDisk, "This is a Swift macOS app.")
        let context = await manager.sharedContext()
        XCTAssertEqual(context, "This is a Swift macOS app.")
    }

    /// A `.kiteloop` directory that is not there at all — the write has nowhere
    /// to land, and the caller has to hear about it rather than read the save as
    /// done.
    func testSaveSharedContextThrowsWhenDirectoryIsMissing() async throws {
        try FileManager.default.removeItem(at: project.kiteloopDirURL)
        let manager = MemoryManager(project: project)

        do {
            try await manager.saveSharedContext("Never lands.")
            XCTFail("expected saveSharedContext to throw when .kiteloop is missing")
        } catch {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.contextURL.path(percentEncoded: false)))
    }

    /// A directory the write cannot reach: the failure is reported, and what is
    /// already on disk is exactly what it was.
    func testSaveSharedContextLeavesPreviousContentsWhenWriteFails() async throws {
        try "The context we already had.".write(to: project.contextURL, atomically: true, encoding: .utf8)
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: project.kiteloopDirURL.path(percentEncoded: false))
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: project.kiteloopDirURL.path(percentEncoded: false))
        }

        let manager = MemoryManager(project: project)
        do {
            try await manager.saveSharedContext("The edit that cannot land.")
            XCTFail("expected saveSharedContext to throw when .kiteloop is not writable")
        } catch {
            // Expected.
        }

        let onDisk = try String(contentsOf: project.contextURL, encoding: .utf8)
        XCTAssertEqual(onDisk, "The context we already had.")
        let context = await manager.sharedContext()
        XCTAssertEqual(context, "The context we already had.")
    }

    func testCurrentMemoryEmpty() async {
        let manager = MemoryManager(project: project)
        let memory = await manager.currentMemory(agentID: "nonexistent")
        XCTAssertEqual(memory, "")
    }

    // MARK: - Composition Tests

    func testComposeSystemContextWithKnowledgeProvider() async {
        let provider = MockKnowledgeProvider(content: ["coder": "Swift concurrency patterns and best practices."])
        let manager = MemoryManager(project: project, knowledgeProvider: provider)

        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "You are a coder.",
            tools: [], denied: [],
            permissionMode: "acceptEdits", state: .idle
        )

        let composed = await manager.composeSystemContext(agent: agent)
        XCTAssertTrue(composed.contains("# Domain Knowledge"))
        XCTAssertTrue(composed.contains("Swift concurrency patterns and best practices."))
    }

    func testComposeSystemContextWithSkillRegistry() async throws {
        // Create a skill directory with a SKILL.md file
        let skillsDir = tempDir.appending(path: "skills")
        let skillSubdir = skillsDir.appending(path: "test-skill")
        try FileManager.default.createDirectory(at: skillSubdir, withIntermediateDirectories: true)

        let skillContent = """
        ---
        name: test-skill
        description: A test skill for unit testing
        ---
        You have access to the test-skill capability.
        Use it wisely.
        """
        try skillContent.write(to: skillSubdir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let registry = SkillRegistry(scanPaths: [skillsDir])
        await registry.reload()

        let manager = MemoryManager(project: project)
        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "You are a coder.",
            tools: [], denied: [],
            permissionMode: "acceptEdits",
            skills: ["test-skill"],
            state: .idle
        )

        let composed = await manager.composeSystemContext(agent: agent, skillRegistry: registry)
        XCTAssertTrue(composed.contains("# Active Skills"))
        XCTAssertTrue(composed.contains("## test-skill"))
        XCTAssertTrue(composed.contains("You have access to the test-skill capability."))
    }

    func testComposeSystemContextWithClaudeMD() async throws {
        // Write a CLAUDE.md at the project root
        let claudeMDContent = "Always use structured concurrency in this project."
        try claudeMDContent.write(to: tempDir.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)

        let manager = MemoryManager(project: project)
        let agent = Agent(
            id: "coder", name: "Coder", model: "sonnet",
            systemPrompt: "You are a coder.",
            tools: [], denied: [],
            permissionMode: "acceptEdits", state: .idle
        )

        let composed = await manager.composeSystemContext(agent: agent)
        XCTAssertTrue(composed.contains("# Project Instructions"))
        XCTAssertTrue(composed.contains("Always use structured concurrency in this project."))
    }

    func testComposeSystemContextKeepsClaudeMDWithInvalidUTF8Byte() async throws {
        var bytes = Data("Use structured concurrency.".utf8)
        bytes.append(0xFF)
        bytes.append(Data(" Never block main.".utf8))
        try bytes.write(to: tempDir.appending(path: "CLAUDE.md"))

        let manager = MemoryManager(project: project)
        let composed = await manager.composeSystemContext(agent: agent())
        XCTAssertTrue(composed.contains("# Project Instructions"))
        XCTAssertTrue(composed.contains("Use structured concurrency."))
        XCTAssertTrue(composed.contains(" Never block main."))
    }

    // MARK: - Two tiers

    private func agent(id: String = "coder") -> Agent {
        Agent(
            id: id, name: "Coder", model: "sonnet",
            systemPrompt: "You are a coder.",
            tools: [], denied: [],
            permissionMode: "acceptEdits", state: .idle
        )
    }

    private func memoryURL(_ agentID: String = "coder") -> URL {
        project.agentDir(for: agentID).appending(path: "memory.md")
    }

    private func topicsURL(_ agentID: String = "coder") -> URL {
        project.agentDir(for: agentID).appending(path: "memory")
    }

    /// An approved write lands as one index line plus a body carrying the whole
    /// of what was approved.
    func testApproveWritesAnIndexLineAndATopicBody() async throws {
        let manager = MemoryManager(project: project)
        let content = "Bedrock tokens expire after eight hours\n\nRe-run `aws sso login` when the runtime reports 403."
        let proposal = try await manager.proposeUpdate(agentID: "coder", content: content)
        try await manager.approve(proposalID: proposal.id)

        let index = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(AgentMemoryIndex.isIndex(index), index)
        let facts = AgentMemoryIndex.parse(index)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.headline, "Bedrock tokens expire after eight hours")
        // The index is a summary: the detail is not in it, it is one recall away.
        XCTAssertFalse(index.contains("aws sso login"))

        let topics = await manager.memoryTopics(agentID: "coder")
        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.id, facts.first?.topic)
        XCTAssertTrue(topics.first?.body.contains("aws sso login") ?? false)
    }

    /// The point of the split: what rides into the prompt stays bounded however
    /// much has been remembered.
    func testInjectedMemoryIsBoundedByTheIndexBudget() async throws {
        let manager = MemoryManager(project: project)
        // Far past the cap, written straight into the file: a hand-edited index
        // must be bounded on the way in too, not only on the way out.
        let facts = (0..<(AgentMemoryIndex.maxFacts + 30)).map {
            AgentMemoryIndex.Fact(date: "2026-08-11", headline: "fact number \($0)", topic: "topic-\($0)", supersedes: nil)
        }
        try FileManager.default.createDirectory(at: project.agentDir(for: "coder"), withIntermediateDirectories: true)
        try AgentMemoryIndex.render(facts: facts).write(to: memoryURL(), atomically: true, encoding: .utf8)

        let composed = await manager.composeSystemContext(agent: agent())
        let injected = AgentMemoryIndex.parse(composed)
        XCTAssertEqual(injected.count, AgentMemoryIndex.maxFacts)
        // The newest survive, and the ones left out are stated rather than
        // silently missing.
        XCTAssertTrue(injected.contains { $0.headline == "fact number 79" })
        XCTAssertFalse(injected.contains { $0.headline == "fact number 0" })
        XCTAssertTrue(composed.contains("30 older facts are in the index file but not shown"), composed)
    }

    /// Past the cap the write is refused, and the refusal says what would let it
    /// through. Nothing is appended and nothing is evicted.
    func testAWritePastTheCapIsRejectedWithAReason() async throws {
        let manager = MemoryManager(project: project)
        for i in 0..<AgentMemoryIndex.maxFacts {
            let p = try await manager.proposeUpdate(agentID: "coder", content: "fact \(i) about something distinct")
            try await manager.approve(proposalID: p.id)
        }

        let overflow = try await manager.proposeUpdate(agentID: "coder", content: "one fact too many")
        do {
            try await manager.approve(proposalID: overflow.id)
            XCTFail("the write past the cap was accepted")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(reason.contains("full"), reason)
            XCTAssertTrue(reason.contains("supersedes"), reason)
        }

        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        XCTAssertEqual(facts.count, AgentMemoryIndex.maxFacts)
        XCTAssertFalse(facts.contains { $0.headline == "one fact too many" })
        // Nothing was dropped to make room for it either.
        XCTAssertTrue(facts.contains { $0.headline == "fact 0 about something distinct" })
        // And the proposal is still there to be edited and approved again.
        let pending = await manager.pendingProposals()
        XCTAssertEqual(pending.map(\.id), [overflow.id])
    }

    /// The way past a full index: name the fact being replaced.
    func testSupersedesLetsAWriteThroughAFullIndex() async throws {
        let manager = MemoryManager(project: project)
        for i in 0..<AgentMemoryIndex.maxFacts {
            let p = try await manager.proposeUpdate(agentID: "coder", content: "fact \(i) about something distinct")
            try await manager.approve(proposalID: p.id)
        }
        let doomed = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[7]

        let p = try await manager.proposeUpdate(
            agentID: "coder",
            content: "supersedes: \(doomed.topic)\nfact number seven, corrected"
        )
        try await manager.approve(proposalID: p.id)

        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        XCTAssertEqual(facts.count, AgentMemoryIndex.maxFacts)
        XCTAssertTrue(facts.contains { $0.headline == "fact number seven, corrected" })
        XCTAssertFalse(facts.contains { $0.headline == doomed.headline })
        // The displaced fact's body stays readable — its line went, not its text.
        let topics = await manager.memoryTopics(agentID: "coder")
        XCTAssertTrue(topics.contains { $0.id == doomed.topic })
    }

    // MARK: - The human's own text

    /// A `## ` section a human appended below the fact list is still there,
    /// verbatim, after an approved `.add` rewrites the index — the bug this file
    /// exists to cover: the write used to rebuild the whole file from the facts
    /// alone and silently drop everything else.
    func testApprovedAddKeepsAHumanSectionBelowTheFactList() async throws {
        let manager = MemoryManager(project: project)
        let seed = try await manager.proposeUpdate(agentID: "coder", content: "First learning")
        try await manager.approve(proposalID: seed.id)

        let indexURL = memoryURL()
        let onDisk = try String(contentsOf: indexURL, encoding: .utf8)
        let withNote = onDisk + "\n## Notes\nDo not remove the retry-budget line without asking.\n"
        try withNote.write(to: indexURL, atomically: true, encoding: .utf8)

        let proposal = try await manager.proposeUpdate(agentID: "coder", content: "Second learning")
        try await manager.approve(proposalID: proposal.id)

        let index = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(index.contains("## Notes\nDo not remove the retry-budget line without asking."), index)
        let facts = AgentMemoryIndex.parse(index)
        XCTAssertEqual(facts.map(\.headline), ["First learning", "Second learning"])
    }

    /// The same section survives a merge, which also rewrites the whole index.
    func testApprovedMergeKeepsAHumanSectionBelowTheFactList() async throws {
        let manager = MemoryManager(project: project)
        let first = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime")
        try await manager.approve(proposalID: first.id)
        let second = try await manager.proposeUpdate(agentID: "coder", content: "The runtime spawns every session")
        try await manager.approve(proposalID: second.id)
        let topics = await manager.memoryTopics(agentID: "coder").map(\.id)

        let indexURL = memoryURL()
        let onDisk = try String(contentsOf: indexURL, encoding: .utf8)
        try (onDisk + "\n## Notes\nHand-written, keep me.\n").write(to: indexURL, atomically: true, encoding: .utf8)

        let merge = try await manager.file(MemoryProposal(
            agentID: "coder",
            proposedContent: "The runtime spawns every session",
            operation: .merge(topics: topics.sorted()), source: .librarian
        ))
        try await manager.approve(proposalID: merge.id)

        let index = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(index.contains("## Notes\nHand-written, keep me."), index)
        XCTAssertEqual(AgentMemoryIndex.parse(index).count, 1)
    }

    /// And a deletion, which rewrites the index with one fewer fact.
    func testApprovedDeleteKeepsAHumanSectionBelowTheFactList() async throws {
        let manager = MemoryManager(project: project)
        let seed = try await manager.proposeUpdate(agentID: "coder", content: "Fact to be deleted")
        try await manager.approve(proposalID: seed.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic

        let indexURL = memoryURL()
        let onDisk = try String(contentsOf: indexURL, encoding: .utf8)
        try (onDisk + "\n## Notes\nHand-written, keep me.\n").write(to: indexURL, atomically: true, encoding: .utf8)

        let deletion = try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "No longer true", operation: .delete(topic: topic),
            source: .librarian, evidence: "Superseded by a code change."
        ))
        try await manager.approve(proposalID: deletion.id)

        let index = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(index.contains("## Notes\nHand-written, keep me."), index)
        XCTAssertTrue(AgentMemoryIndex.parse(index).isEmpty)
    }

    // MARK: - A byte that is not UTF-8

    /// Seeds an index of two approved facts, then puts a 0xFF byte on a line
    /// of its own between their two lines.
    private func seedIndexWithABadByte(_ manager: MemoryManager) async throws {
        for content in ["First fact survives", "Second fact survives"] {
            let proposal = try await manager.proposeUpdate(agentID: "coder", content: content)
            try await manager.approve(proposalID: proposal.id)
        }
        let lines = try String(contentsOf: memoryURL(), encoding: .utf8).components(separatedBy: "\n")
        let second = try XCTUnwrap(lines.lastIndex { AgentMemoryIndex.parseLine($0) != nil })
        var data = Data((lines[..<second].joined(separator: "\n") + "\n").utf8)
        data.append(contentsOf: [0xFF, 0x0A])
        data.append(Data(lines[second...].joined(separator: "\n").utf8))
        try data.write(to: memoryURL())
    }

    func testCurrentAndInjectedMemoryKeepEveryFactAroundABadByte() async throws {
        let manager = MemoryManager(project: project)
        try await seedIndexWithABadByte(manager)

        let index = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(index.contains("First fact survives"), index)
        XCTAssertTrue(index.contains("Second fact survives"), index)
        XCTAssertTrue(index.contains("\u{FFFD}"), "only the bad byte is lost, as a replacement character")

        let injected = await manager.injectedMemory(agentID: "coder")
        XCTAssertTrue(injected.contains("First fact survives"), injected)
        XCTAssertTrue(injected.contains("Second fact survives"), injected)
    }

    func testApprovedAddKeepsEveryFactAroundABadByte() async throws {
        let manager = MemoryManager(project: project)
        try await seedIndexWithABadByte(manager)

        let proposal = try await manager.proposeUpdate(agentID: "coder", content: "Third fact is added")
        try await manager.approve(proposalID: proposal.id)

        let onDisk = String(decoding: try Data(contentsOf: memoryURL()), as: UTF8.self)
        XCTAssertTrue(onDisk.contains("First fact survives"), onDisk)
        XCTAssertTrue(onDisk.contains("Second fact survives"), onDisk)
        XCTAssertTrue(onDisk.contains("Third fact is added"), onDisk)
    }

    func testApprovedDeleteKeepsTheOtherFactAroundABadByte() async throws {
        let manager = MemoryManager(project: project)
        try await seedIndexWithABadByte(manager)
        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        let first = try XCTUnwrap(facts.first { $0.headline == "First fact survives" })

        let deletion = try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "No longer true", operation: .delete(topic: first.topic),
            source: .librarian, evidence: "Superseded by a code change."
        ))
        try await manager.approve(proposalID: deletion.id)

        let index = await manager.currentMemory(agentID: "coder")
        XCTAssertFalse(index.contains("First fact survives"), index)
        XCTAssertTrue(index.contains("Second fact survives"), index)
    }

    /// Writes two lines with a 0xFF byte on a line of its own between them.
    private func writeWithABadByte(_ first: String, _ second: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data("\(first)\n".utf8)
        data.append(contentsOf: [0xFF, 0x0A])
        data.append(Data("\(second)\n".utf8))
        try data.write(to: url)
    }

    func testSharedContextKeepsEveryLineAroundABadByte() async throws {
        let manager = MemoryManager(project: project)
        try writeWithABadByte("Context line before", "Context line after", to: project.contextURL)

        let context = await manager.sharedContext()
        XCTAssertTrue(context.contains("Context line before"), context)
        XCTAssertTrue(context.contains("Context line after"), context)
    }

    func testFleetKnowledgeKeepsEveryLineAroundABadByte() async throws {
        let manager = MemoryManager(project: project)
        let url = project.kiteloopDirURL.appending(path: CoordinatorKnowledge.fileName)
        try writeWithABadByte("Knowledge line before", "Knowledge line after", to: url)

        let knowledge = await manager.fleetKnowledge()
        XCTAssertTrue(knowledge.contains("Knowledge line before"), knowledge)
        XCTAssertTrue(knowledge.contains("Knowledge line after"), knowledge)
    }

    func testFleetKnowledgeIsEmptyWhenTheFileIsMissing() async {
        let manager = MemoryManager(project: project)
        let knowledge = await manager.fleetKnowledge()
        XCTAssertEqual(knowledge, "")
    }

    func testATopicBodyWithABadByteIsListedAndRecalled() async throws {
        let manager = MemoryManager(project: project)
        try writeWithABadByte("Zeppelin body before", "Zeppelin body after", to: topicsURL().appending(path: "zeppelin.md"))

        let topics = await manager.memoryTopics(agentID: "coder")
        let topic = try XCTUnwrap(topics.first { $0.id == "zeppelin" })
        XCTAssertTrue(topic.body.contains("Zeppelin body before"), topic.body)
        XCTAssertTrue(topic.body.contains("Zeppelin body after"), topic.body)

        let hit = await manager.recallMemory(agentID: "coder", query: "after")
        XCTAssertTrue(hit.contains("Zeppelin body after"), hit)
    }

    func testAnArchivedTopicBodyWithABadByteIsListed() async throws {
        let manager = MemoryManager(project: project)
        let url = topicsURL().appending(path: "archive").appending(path: "zeppelin.md")
        try writeWithABadByte("Archived body before", "Archived body after", to: url)

        let archived = await manager.archivedTopics(agentID: "coder")
        let topic = try XCTUnwrap(archived.first { $0.id == "zeppelin" })
        XCTAssertTrue(topic.body.contains("Archived body before"), topic.body)
        XCTAssertTrue(topic.body.contains("Archived body after"), topic.body)
    }

    // MARK: - Migration

    func testALegacyMemoryFileMigratesLosslessly() async throws {
        let blocks = (0..<(AgentMemoryIndex.maxFacts + 12)).map { "Learned: thing number \($0)" }
        let legacy = blocks.joined(separator: "\n\n")
        try FileManager.default.createDirectory(at: project.agentDir(for: "coder"), withIntermediateDirectories: true)
        try legacy.write(to: memoryURL(), atomically: true, encoding: .utf8)

        let manager = MemoryManager(project: project)
        let index = await manager.currentMemory(agentID: "coder")

        XCTAssertTrue(AgentMemoryIndex.isIndex(index), index)
        let facts = AgentMemoryIndex.parse(index)
        XCTAssertEqual(facts.count, AgentMemoryIndex.maxFacts)
        // Appends went to the end, so the tail is the most recent thing it knows.
        XCTAssertTrue(facts.contains { $0.headline == "Learned: thing number 61" })
        XCTAssertFalse(facts.contains { $0.headline == "Learned: thing number 0" })
        // Migrated facts carry no date: the old file recorded none, and a date
        // guessed from the mtime would read as evidence.
        XCTAssertTrue(facts.allSatisfy { $0.date.isEmpty })

        // Nothing was lost: every block has a body, and the original file is kept.
        let topics = await manager.memoryTopics(agentID: "coder")
        XCTAssertEqual(topics.count, blocks.count)
        let backup = project.agentDir(for: "coder").appending(path: "memory.md.pre-index.bak")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), legacy)
    }

    func testMigrationRunsOnceAndLeavesLaterWritesAlone() async throws {
        try FileManager.default.createDirectory(at: project.agentDir(for: "coder"), withIntermediateDirectories: true)
        try "Learned: the first thing".write(to: memoryURL(), atomically: true, encoding: .utf8)

        let manager = MemoryManager(project: project)
        _ = await manager.currentMemory(agentID: "coder")
        let p = try await manager.proposeUpdate(agentID: "coder", content: "Learned: a second thing")
        try await manager.approve(proposalID: p.id)
        _ = await manager.currentMemory(agentID: "coder")

        let names = try FileManager.default.contentsOfDirectory(atPath: project.agentDir(for: "coder").path(percentEncoded: false))
        XCTAssertEqual(names.filter { $0.hasSuffix(".bak") }.count, 1)
        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        XCTAssertEqual(facts.map(\.headline), ["Learned: the first thing", "Learned: a second thing"])
    }

    func testAnUnmigratedMemoryFileDoesNotRideIntoTheSystemPromptWhole() async throws {
        let legacy = (0..<200).map { "Learned: thing number \($0)" }.joined(separator: "\n\n")
        try FileManager.default.createDirectory(at: project.agentDir(for: "coder"), withIntermediateDirectories: true)
        try legacy.write(to: memoryURL(), atomically: true, encoding: .utf8)

        let manager = MemoryManager(project: project)
        let composed = await manager.composeSystemContext(agent: agent())
        XCTAssertEqual(AgentMemoryIndex.parse(composed).count, AgentMemoryIndex.maxFacts)
        XCTAssertFalse(composed.contains("Learned: thing number 0\n"))
    }

    // MARK: - Recall

    func testRecallReadsATopicBodyTheIndexOnlySummarises() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(
            agentID: "coder",
            content: "Bedrock tokens expire\n\nRe-run `aws sso login` when the runtime reports 403."
        )
        try await manager.approve(proposalID: p.id)

        let hit = await manager.recallMemory(agentID: "coder", query: "bedrock tokens")
        XCTAssertTrue(hit.contains("aws sso login"), hit)

        let miss = await manager.recallMemory(agentID: "coder", query: "kubernetes ingress")
        XCTAssertEqual(miss, "")
    }

    func testRecallFindsATopicByTheSlugTheIndexPrints() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "Prefer actors over locks\n\nBecause the orchestrator is @MainActor.")
        try await manager.approve(proposalID: p.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic

        let hit = await manager.recallMemory(agentID: "coder", query: topic)
        XCTAssertTrue(hit.contains("Because the orchestrator is @MainActor."), hit)
    }

    /// Writes a topic body straight to the second tier — the store the index
    /// bounds and the topic directory does not, which is the state recall has to
    /// answer in without handing back everything it matched.
    private func writeTopicBody(_ id: String, _ body: String, agentID: String = "coder") throws {
        try FileManager.default.createDirectory(at: topicsURL(agentID), withIntermediateDirectories: true)
        try body.write(to: topicsURL(agentID).appending(path: "\(id).md"), atomically: true, encoding: .utf8)
    }

    func testRecallHandsBackAtMostTheCapAndSaysHowManyItWithheld() async throws {
        for i in 1...8 {
            try writeTopicBody("topic-\(i)", "Bedrock tokens expire\n\nbody number \(i)")
        }

        let manager = MemoryManager(project: project)
        let hit = await manager.recallMemory(agentID: "coder", query: "bedrock tokens")

        let shown = (1...8).filter { hit.contains("body number \($0)") }
        XCTAssertEqual(shown.count, MemoryManager.maxRecalledTopics, hit)
        XCTAssertEqual(shown, [1, 2, 3, 4, 5], hit)
        XCTAssertTrue(hit.contains("(3 further topics matched and are not shown here"), hit)
    }

    func testRecallSaysOneWithheldTopicInTheSingular() async throws {
        for i in 1...(MemoryManager.maxRecalledTopics + 1) {
            try writeTopicBody("topic-\(i)", "Bedrock tokens expire\n\nbody number \(i)")
        }

        let manager = MemoryManager(project: project)
        let hit = await manager.recallMemory(agentID: "coder", query: "bedrock tokens")

        XCTAssertTrue(hit.contains("(1 further topic matched and is not shown here"), hit)
        XCTAssertFalse(hit.contains("topics"), hit)
    }

    /// The cap must not cost a topic that answers the whole query: these are
    /// named so the single-word matches sort first, so file-name order alone
    /// would fill the five and leave the one real hit out.
    func testRecallReturnsAnAllWordsHitAheadOfSingleWordOnes() async throws {
        for i in 1...6 {
            try writeTopicBody("aaa-partial-\(i)", "Tokens rotate nightly\n\nbody partial \(i)")
        }
        try writeTopicBody("zzz-exact", "Bedrock tokens expire\n\nbody exact")

        let manager = MemoryManager(project: project)
        let hit = await manager.recallMemory(agentID: "coder", query: "bedrock tokens")

        XCTAssertTrue(hit.contains("body exact"), hit)
        XCTAssertFalse(hit.contains("body partial"), hit)
    }

    /// Under the cap nothing was withheld, so nothing is said about withholding
    /// and the bodies read exactly as they always have.
    func testRecallUnderTheCapReadsAsItAlwaysHas() async throws {
        try writeTopicBody("a-note", "Bedrock tokens expire\n\nfirst body")
        try writeTopicBody("b-note", "Bedrock tokens rotate\n\nsecond body")

        let manager = MemoryManager(project: project)
        let hit = await manager.recallMemory(agentID: "coder", query: "bedrock tokens")

        XCTAssertEqual(
            hit,
            "Bedrock tokens expire\n\nfirst body\n\n---\n\nBedrock tokens rotate\n\nsecond body"
        )
    }

    /// The fallback is the worst case the cap exists for: one common word matches
    /// nearly every body, and answering with the store is the unbounded memory
    /// the two tiers prevent.
    func testRecallCapsTheSingleWordFallbackToo() async throws {
        for i in 1...9 {
            try writeTopicBody("topic-\(i)", "Note number \(i)\n\nbody number \(i) mentions tokens")
        }

        let manager = MemoryManager(project: project)
        let hit = await manager.recallMemory(agentID: "coder", query: "tokens kubernetes")

        let shown = (1...9).filter { hit.contains("body number \($0)") }
        XCTAssertEqual(shown.count, MemoryManager.maxRecalledTopics, hit)
        XCTAssertTrue(hit.contains("(4 further topics matched and are not shown here"), hit)
    }

    // MARK: - The human control: archiving a fact

    /// Drops exactly the named fact's line, leaves the others and their order
    /// untouched, and moves the body under `memory/archive/` — the same
    /// destination `archiveBody` uses for a `.archive` proposal.
    func testArchiveFactDropsOnlyThatLineAndKeepsTheBody() async throws {
        let manager = MemoryManager(project: project)
        for content in ["First fact", "Second fact", "Third fact"] {
            let p = try await manager.proposeUpdate(agentID: "coder", content: content)
            try await manager.approve(proposalID: p.id)
        }
        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        let target = facts[1]

        try await manager.archiveFact(agentID: "coder", topic: target.topic)

        let remaining = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        XCTAssertEqual(remaining.map(\.headline), ["First fact", "Third fact"])

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: topicsURL().appending(path: "\(target.topic).md").path(percentEncoded: false)
        ))
        let archived = topicsURL().appending(path: "archive/\(target.topic).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.path(percentEncoded: false)))
        XCTAssertTrue(try String(contentsOf: archived, encoding: .utf8).contains("Second fact"))
    }

    /// Archiving is the way past the cap the refusal already names: once it
    /// takes the index below `maxFacts`, a write that was refused for being
    /// full is accepted without needing `supersedes:`.
    func testArchivingTakesTheIndexBelowTheCapForTheNextApproval() async throws {
        let manager = MemoryManager(project: project)
        for i in 0..<AgentMemoryIndex.maxFacts {
            let p = try await manager.proposeUpdate(agentID: "coder", content: "fact \(i) about something distinct")
            try await manager.approve(proposalID: p.id)
        }
        let overflow = try await manager.proposeUpdate(agentID: "coder", content: "one fact too many")
        do {
            try await manager.approve(proposalID: overflow.id)
            XCTFail("expected the full index to refuse this write")
        } catch { /* expected */ }

        let victim = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0]
        try await manager.archiveFact(agentID: "coder", topic: victim.topic)

        try await manager.approve(proposalID: overflow.id)
        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        XCTAssertTrue(facts.contains { $0.headline == "one fact too many" })
        XCTAssertEqual(facts.count, AgentMemoryIndex.maxFacts)
    }

    /// A topic naming neither an index line nor a body changes nothing.
    func testArchivingAnUnknownTopicChangesNoFile() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "The only fact")
        try await manager.approve(proposalID: p.id)
        let before = await manager.currentMemory(agentID: "coder")

        do {
            try await manager.archiveFact(agentID: "coder", topic: "not-a-real-topic")
            XCTFail("expected an unknown topic to be refused")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(reason.contains("not-a-real-topic"), reason)
        }

        let after = await manager.currentMemory(agentID: "coder")
        XCTAssertEqual(after, before)
    }

    // MARK: - The archived list

    /// Approving an `.archive` proposal moves the fact out of `memoryTopics`
    /// and into `archivedTopics`, body intact — the surface this item exists
    /// to add, since nothing in the app read `memory/archive/` before it.
    func testArchivingMovesATopicIntoTheArchivedList() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth keeping around")
        try await manager.approve(proposalID: p.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic

        try await manager.archiveFact(agentID: "coder", topic: topic)

        let topics = await manager.memoryTopics(agentID: "coder")
        XCTAssertFalse(topics.contains { $0.id == topic })

        let archived = await manager.archivedTopics(agentID: "coder")
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(archived.first?.id, topic)
        XCTAssertTrue(archived.first?.body.contains("A fact worth keeping around") ?? false)
    }

    /// No archive directory at all — nothing has ever been archived — is an
    /// empty list, not an error.
    func testArchivedTopicsIsEmptyWhenNothingHasBeenArchived() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "A fact that stays in the index")
        try await manager.approve(proposalID: p.id)

        let archived = await manager.archivedTopics(agentID: "coder")
        XCTAssertTrue(archived.isEmpty)
    }

    /// A slug freed by archiving is not held back from a later fact — `taken`
    /// only looks at `memory/`, not `memory/archive/` — so archiving that
    /// later fact under the same slug collides, and `archiveBody` resolves it
    /// with a `-2` suffix. That suffixed body is listed too.
    func testACollisionSuffixedArchivedBodyIsListed() async throws {
        let manager = MemoryManager(project: project)
        let first = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime")
        try await manager.approve(proposalID: first.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic
        try await manager.archiveFact(agentID: "coder", topic: topic)

        let second = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime")
        try await manager.approve(proposalID: second.id)
        let reusedTopic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic
        XCTAssertEqual(reusedTopic, topic, "the freed slug should be reused since it isn't in memory/ anymore")
        try await manager.archiveFact(agentID: "coder", topic: reusedTopic)

        let archived = await manager.archivedTopics(agentID: "coder")
        XCTAssertTrue(archived.contains { $0.id == topic })
        XCTAssertTrue(archived.contains { $0.id == "\(topic)-2" })
    }

    /// Archived bodies stay out of both `recallMemory` and `injectedMemory` —
    /// the exclusion `archiveBody`'s doc comment promises, unaffected by
    /// `archivedTopics` existing.
    func testArchivedBodiesStayAbsentFromRecallAndInjectedMemory() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "Bedrock tokens expire\n\nRe-run aws sso login.")
        try await manager.approve(proposalID: p.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic

        try await manager.archiveFact(agentID: "coder", topic: topic)

        let recalled = await manager.recallMemory(agentID: "coder", query: "bedrock tokens")
        XCTAssertEqual(recalled, "")

        let injected = await manager.injectedMemory(agentID: "coder")
        XCTAssertFalse(injected.contains("Bedrock tokens expire"))
    }

    // MARK: - Restoring

    /// Archive then restore: the body is live again, gone from the archive,
    /// and the index carries one line with the original topic and date.
    func testRestoringAnArchivedFactPutsItBackInBothTiers() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "Bedrock tokens expire\n\nRe-run aws sso login.")
        try await manager.approve(proposalID: p.id)
        let original = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0]
        try await manager.archiveFact(agentID: "coder", topic: original.topic)

        try await manager.restoreFact(agentID: "coder", topic: original.topic)

        let topics = await manager.memoryTopics(agentID: "coder")
        XCTAssertTrue(topics.contains { $0.id == original.topic })
        let archived = await manager.archivedTopics(agentID: "coder")
        XCTAssertFalse(archived.contains { $0.id == original.topic })
        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        XCTAssertEqual(facts, [original])

        let recalled = await manager.recallMemory(agentID: "coder", query: "sso")
        XCTAssertTrue(recalled.contains("Re-run aws sso login."), recalled)
    }

    /// A full index refuses a restore with the approval's sentence, and
    /// nothing moves: the body stays archived and the index file is unchanged.
    func testRestoringIntoAFullIndexIsRefusedAndChangesNothing() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "A fact that gets archived early")
        try await manager.approve(proposalID: p.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic
        try await manager.archiveFact(agentID: "coder", topic: topic)
        for i in 0..<AgentMemoryIndex.maxFacts {
            let p = try await manager.proposeUpdate(agentID: "coder", content: "fact \(i) about something distinct")
            try await manager.approve(proposalID: p.id)
        }
        let before = try Data(contentsOf: memoryURL())

        do {
            try await manager.restoreFact(agentID: "coder", topic: topic)
            XCTFail("a restore into a full index was accepted")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(reason.contains("full"), reason)
        }

        XCTAssertEqual(try Data(contentsOf: memoryURL()), before)
        let archived = await manager.archivedTopics(agentID: "coder")
        XCTAssertTrue(archived.contains { $0.id == topic })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: topicsURL().appending(path: "\(topic).md").path(percentEncoded: false)
        ))
    }

    /// A live body under the same name refuses the restore before anything
    /// moves — neither body is overwritten and the index is left alone.
    func testRestoringOverALiveBodyOfTheSameNameIsRefused() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime")
        try await manager.approve(proposalID: p.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic
        try await manager.archiveFact(agentID: "coder", topic: topic)
        try writeTopicBody(topic, "A different body under the same name")
        let before = await manager.currentMemory(agentID: "coder")

        do {
            try await manager.restoreFact(agentID: "coder", topic: topic)
            XCTFail("a restore over a live body was accepted")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(reason.contains(topic), reason)
        }

        let after = await manager.currentMemory(agentID: "coder")
        XCTAssertEqual(after, before)
        let archived = await manager.archivedTopics(agentID: "coder")
        XCTAssertTrue(archived.contains { $0.id == topic })
        let live = try String(contentsOf: topicsURL().appending(path: "\(topic).md"), encoding: .utf8)
        XCTAssertEqual(live, "A different body under the same name")
    }

    /// A restore adds and never replaces: a `supersedes:` the body carries is
    /// dropped, and a line the index already has that covers it refuses it.
    func testRestoringAFactTheIndexAlreadyCoversIsRefused() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime")
        try await manager.approve(proposalID: p.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic
        try await manager.archiveFact(agentID: "coder", topic: topic)
        let again = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime today")
        try await manager.approve(proposalID: again.id)
        let before = await manager.currentMemory(agentID: "coder")

        do {
            try await manager.restoreFact(agentID: "coder", topic: topic)
            XCTFail("a covered restore was accepted")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(reason.contains("already covered"), reason)
        }

        let after = await manager.currentMemory(agentID: "coder")
        XCTAssertEqual(after, before)
    }

    // MARK: - Deleting an archived fact

    /// Deleting an archived body removes its file and its listing, and leaves
    /// the index and every live body byte-for-byte as they were.
    func testDeletingAnArchivedFactRemovesOnlyItsBody() async throws {
        let manager = MemoryManager(project: project)
        for content in ["A token was recorded here by mistake", "Sessions are spawned through the runtime"] {
            let p = try await manager.proposeUpdate(agentID: "coder", content: content)
            try await manager.approve(proposalID: p.id)
        }
        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        let doomed = facts[0].topic
        let kept = facts[1].topic
        try await manager.archiveFact(agentID: "coder", topic: doomed)
        let indexBefore = try Data(contentsOf: memoryURL())
        let liveBefore = try Data(contentsOf: topicsURL().appending(path: "\(kept).md"))

        try await manager.deleteArchivedFact(agentID: "coder", topic: doomed)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: topicsURL().appending(path: "archive/\(doomed).md").path(percentEncoded: false)
        ))
        let archived = await manager.archivedTopics(agentID: "coder")
        XCTAssertFalse(archived.contains { $0.id == doomed })
        XCTAssertEqual(try Data(contentsOf: memoryURL()), indexBefore)
        XCTAssertEqual(try Data(contentsOf: topicsURL().appending(path: "\(kept).md")), liveBefore)
    }

    /// An id naming no archived body is refused, naming the topic, and no
    /// file changes — not even a live body under that name.
    func testDeletingAnUnknownArchivedFactIsRefusedAndChangesNothing() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime")
        try await manager.approve(proposalID: p.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic
        let indexBefore = try Data(contentsOf: memoryURL())
        let liveBefore = try Data(contentsOf: topicsURL().appending(path: "\(topic).md"))

        do {
            try await manager.deleteArchivedFact(agentID: "coder", topic: topic)
            XCTFail("deleting a live fact through the archive was accepted")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(reason.contains(topic), reason)
        }

        XCTAssertEqual(try Data(contentsOf: memoryURL()), indexBefore)
        XCTAssertEqual(try Data(contentsOf: topicsURL().appending(path: "\(topic).md")), liveBefore)
    }

    /// Two archived bodies sharing a slug (`topic` and `topic-2`): deleting
    /// one leaves the other in place.
    func testDeletingOneOfTwoSameSlugArchivedBodiesLeavesTheOther() async throws {
        let manager = MemoryManager(project: project)
        let first = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime")
        try await manager.approve(proposalID: first.id)
        let topic = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))[0].topic
        try await manager.archiveFact(agentID: "coder", topic: topic)
        let second = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through the runtime")
        try await manager.approve(proposalID: second.id)
        try await manager.archiveFact(agentID: "coder", topic: topic)
        let before = await manager.archivedTopics(agentID: "coder")
        XCTAssertEqual(Set(before.map(\.id)), [topic, "\(topic)-2"])

        try await manager.deleteArchivedFact(agentID: "coder", topic: "\(topic)-2")

        let after = await manager.archivedTopics(agentID: "coder")
        XCTAssertEqual(after.map(\.id), [topic])
    }

    // MARK: - Correcting a fact

    /// Approves three facts and backdates every line, so a rewrite that sets
    /// today's date is told apart from one that left the date alone.
    private func seedThreeBackdatedFacts(_ manager: MemoryManager) async throws -> [AgentMemoryIndex.Fact] {
        for content in ["First fact", "Wrong port is 8080", "Third fact"] {
            let p = try await manager.proposeUpdate(agentID: "coder", content: content)
            try await manager.approve(proposalID: p.id)
        }
        var facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        for i in facts.indices { facts[i].date = "2020-01-01" }
        try AgentMemoryIndex.render(facts: facts).write(to: memoryURL(), atomically: true, encoding: .utf8)
        return facts
    }

    /// The corrected line keeps its topic and its place; only its headline and
    /// date change, and the lines around it are untouched.
    func testRewritingAFactKeepsItsTopicAndPositionAndDatesItToday() async throws {
        let manager = MemoryManager(project: project)
        let before = try await seedThreeBackdatedFacts(manager)

        try await manager.rewriteFact(agentID: "coder", topic: before[1].topic, content: "Right port is 8443\n\nThe dev server listens there.")

        let after = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        XCTAssertEqual(after.map(\.topic), before.map(\.topic))
        XCTAssertEqual(after[1].headline, "Right port is 8443")
        XCTAssertEqual(after[1].date, AgentMemoryIndex.today())
        XCTAssertEqual(after[0], before[0])
        XCTAssertEqual(after[2], before[2])
    }

    /// The body holds the corrected text, and recall finds it by a word only
    /// the correction says.
    func testRewritingAFactReplacesItsBodyAndRecallFindsTheNewText() async throws {
        let manager = MemoryManager(project: project)
        let facts = try await seedThreeBackdatedFacts(manager)
        let topic = facts[1].topic

        try await manager.rewriteFact(agentID: "coder", topic: topic, content: "Right port is 8443\n\nThe dev server listens on loopback.")

        let body = try String(contentsOf: topicsURL().appending(path: "\(topic).md"), encoding: .utf8)
        XCTAssertTrue(body.contains("The dev server listens on loopback."), body)
        // The frontmatter keeps the topic id, which names the old port; the text under it must not.
        let text = body.components(separatedBy: "---").last ?? body
        XCTAssertFalse(text.contains("8080"), body)
        let recalled = await manager.recallMemory(agentID: "coder", query: "loopback")
        XCTAssertTrue(recalled.contains("The dev server listens on loopback."), recalled)
    }

    /// An unknown topic and blank text are both refused, and neither the index
    /// nor the body changes by a byte.
    func testARefusedRewriteChangesNoFile() async throws {
        let manager = MemoryManager(project: project)
        let facts = try await seedThreeBackdatedFacts(manager)
        let bodyURL = topicsURL().appending(path: "\(facts[1].topic).md")
        let indexBefore = try Data(contentsOf: memoryURL())
        let bodyBefore = try Data(contentsOf: bodyURL)

        for (topic, content) in [("not-a-real-topic", "Some text"), (facts[1].topic, "  \n\n ")] {
            do {
                try await manager.rewriteFact(agentID: "coder", topic: topic, content: content)
                XCTFail("a rewrite of \(topic) with \(content.debugDescription) was accepted")
            } catch let error as MemoryWriteError {
                guard case .rejected = error else { return XCTFail("unexpected error \(error)") }
            }
            XCTAssertEqual(try Data(contentsOf: memoryURL()), indexBefore)
            XCTAssertEqual(try Data(contentsOf: bodyURL), bodyBefore)
        }
    }

    // MARK: - Adding a fact by hand

    /// A typed fact on an empty index lands as one line dated today and a
    /// body holding the whole text.
    func testAddingAFactByHandWritesAnIndexLineAndABody() async throws {
        let manager = MemoryManager(project: project)

        try await manager.addFact(agentID: "coder", content: "Deploys go through staging first\n\nNever straight to prod.")

        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.headline, "Deploys go through staging first")
        XCTAssertEqual(facts.first?.date, AgentMemoryIndex.today())
        let topic = try XCTUnwrap(facts.first?.topic)
        let body = try String(contentsOf: topicsURL().appending(path: "\(topic).md"), encoding: .utf8)
        XCTAssertTrue(body.contains("Deploys go through staging first"), body)
        XCTAssertTrue(body.contains("Never straight to prod."), body)
    }

    /// A full index refuses a typed fact the way it refuses an approval, and
    /// neither the index nor the topics directory changes.
    func testAddingAFactToAFullIndexIsRefusedAndChangesNothing() async throws {
        let manager = MemoryManager(project: project)
        for i in 0..<AgentMemoryIndex.maxFacts {
            let p = try await manager.proposeUpdate(agentID: "coder", content: "fact \(i) about something distinct")
            try await manager.approve(proposalID: p.id)
        }
        let indexBefore = try Data(contentsOf: memoryURL())
        let topicsBefore = try FileManager.default.contentsOfDirectory(atPath: topicsURL().path(percentEncoded: false)).sorted()

        do {
            try await manager.addFact(agentID: "coder", content: "A brand new unrelated observation")
            XCTFail("a typed fact past the cap was accepted")
        } catch let error as MemoryWriteError {
            guard case .rejected = error else { return XCTFail("unexpected error \(error)") }
        }

        XCTAssertEqual(try Data(contentsOf: memoryURL()), indexBefore)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: topicsURL().path(percentEncoded: false)).sorted(),
            topicsBefore
        )
    }

    /// Text with no headline is refused before any file is written.
    func testAddingBlankTextIsRefusedAndWritesNothing() async throws {
        let manager = MemoryManager(project: project)

        for content in ["", "  \n\n "] {
            do {
                try await manager.addFact(agentID: "coder", content: content)
                XCTFail("a typed fact of \(content.debugDescription) was accepted")
            } catch let error as MemoryWriteError {
                guard case .rejected = error else { return XCTFail("unexpected error \(error)") }
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: memoryURL().path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: topicsURL().path(percentEncoded: false)))
    }

    // MARK: - The gate

    /// The human gate is still the only way in: proposing writes nothing.
    func testAProposalAloneReachesNeitherTier() async throws {
        let manager = MemoryManager(project: project)
        _ = try await manager.proposeUpdate(agentID: "coder", content: "Something unapproved")

        let index = await manager.currentMemory(agentID: "coder")
        let topics = await manager.memoryTopics(agentID: "coder")
        XCTAssertEqual(index, "")
        XCTAssertTrue(topics.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: topicsURL().path(percentEncoded: false)))
        let composed = await manager.composeSystemContext(agent: agent())
        XCTAssertFalse(composed.contains("Something unapproved"))
    }

    func testARejectedProposalReachesNeitherTier() async throws {
        let manager = MemoryManager(project: project)
        let p = try await manager.proposeUpdate(agentID: "coder", content: "Something wrong")
        try await manager.reject(proposalID: p.id)

        let index = await manager.currentMemory(agentID: "coder")
        let topics = await manager.memoryTopics(agentID: "coder")
        XCTAssertEqual(index, "")
        XCTAssertTrue(topics.isEmpty)
    }

    // MARK: - A proposal that did not reach disk

    /// Puts a regular file where the agent's `proposals/` directory goes, so
    /// nothing can be created under it: `AtomicFileWriter.write` makes the
    /// containing directory first, and that call is what fails.
    ///
    /// Only the proposals path is blocked — the index and the topic bodies live
    /// beside it and still write, which is what lets an approval get as far as
    /// recording the fact and then fail on the status.
    private func blockProposals(agentID: String = "coder") throws {
        let dir = project.agentDir(for: agentID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let proposals = dir.appending(path: "proposals")
        try? FileManager.default.removeItem(at: proposals)
        try Data("not a directory".utf8).write(to: proposals)
    }

    /// A proposal is its JSON: one that did not land is one the next launch will
    /// not find, so filing throws rather than handing back a record that only
    /// this process knows about.
    func testAProposalThatCannotBeWrittenIsNotFiled() async throws {
        try blockProposals()
        let manager = MemoryManager(project: project)

        do {
            _ = try await manager.proposeUpdate(agentID: "coder", content: "Learned: something worth keeping")
            XCTFail("a proposal that reached no disk was reported as filed")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertTrue(reason.contains("proposals"), reason)
        }

        let pending = await manager.pendingProposals()
        XCTAssertTrue(pending.isEmpty,
                      "a proposal the next launch will not find must not be pending in this one")
    }

    /// And the agent hears it: the tool's answer is the only surface a
    /// `propose_memory` call has, so a failure there has to read as one rather
    /// than as work waiting for a human.
    @MainActor
    func testTheProposeMemoryToolAnswersWithTheFailure() async throws {
        let manager = MemoryManager(project: project)
        let eventBus = EventBus(eventsURL: project.eventsURL)
        let orchestrator = Orchestrator(
            runtime: MockAgentRuntime(),
            eventBus: eventBus,
            subscriptionEngine: SubscriptionEngine(eventBus: eventBus),
            memoryManager: manager
        )
        try blockProposals()

        let answer = await ToolInterceptor.handle(
            tool: .proposeMemory,
            input: #"{"content": "Learned: something worth keeping"}"#,
            agentID: "coder",
            orchestrator: orchestrator
        )

        XCTAssertFalse(answer.contains("Awaiting human approval"), answer)
        XCTAssertTrue(answer.contains("was not recorded"), answer)
    }

    /// The fact is written by the time the status is, so an approval can fail
    /// halfway. What must not happen is the proposal reading as approved: the
    /// file still says `pending`, and the file is what the next launch loads.
    @MainActor
    func testAnApprovalWhoseStatusWriteFailsSurfacesAsAWriteError() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(
            agentID: "coder", content: "Bedrock tokens expire after eight hours"
        )
        try blockProposals()

        let viewModel = MemoryViewModel(memoryManager: manager)
        viewModel.selectedAgentID = "coder"
        await viewModel.approve(proposal)

        XCTAssertNotNil(viewModel.lastWriteError,
                        "a status that never reached disk must not look like a save that worked")
        XCTAssertEqual(viewModel.pendingProposals.map(\.id), [proposal.id],
                       "the proposal stays pending — it is what is on disk")
    }

    /// The other half of the same rule, and the one that says the throwing path
    /// did not cost the working one: a proposal that was written is there at the
    /// next launch, and so is its approval.
    func testAProposalAndItsApprovalSurviveANewManager() async throws {
        let first = MemoryManager(project: project)
        let proposal = try await first.proposeUpdate(
            agentID: "coder", content: "Bedrock tokens expire after eight hours"
        )

        let reopened = MemoryManager(project: project)
        let reloaded = await reopened.pendingProposals()
        XCTAssertEqual(reloaded.map(\.id), [proposal.id],
                       "a filed proposal is on disk, not just in the actor that filed it")
        try await reopened.approve(proposalID: proposal.id)

        let again = MemoryManager(project: project)
        let pending = await again.pendingProposals()
        XCTAssertTrue(pending.isEmpty, "an approval that landed does not come back pending")
        let memory = await again.currentMemory(agentID: "coder")
        XCTAssertTrue(memory.contains("Bedrock tokens expire after eight hours"), memory)
    }
}

// MARK: - Test Helpers

private struct MockKnowledgeProvider: KnowledgeProviding {
    let content: [String: String]

    func knowledgeContent(for agentID: String) -> String? {
        content[agentID]
    }
}
