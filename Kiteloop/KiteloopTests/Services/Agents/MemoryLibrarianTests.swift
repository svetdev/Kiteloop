import XCTest
import KiteloopCore
@testable import Kiteloop

/// The librarian's two halves: what it proposes off a reply, and what approving
/// one of those proposals does to the memory on disk.
///
/// The seeded corpus below is the one the item describes — a duplicate pair, a
/// fact the code contradicts, and a stale one — so the cases read against a
/// corpus with all three failure modes in it at once rather than one apiece.
final class MemoryLibrarianTests: XCTestCase {
    private var tempDir: URL!
    private var project: KiteloopProject!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory(prefix: "memory-librarian")
        project = KiteloopProject(rootURL: tempDir)
        try project.ensureDirectoryExists()
    }

    // MARK: - The seeded corpus

    /// Four facts: two that say the same thing, one the code disproves, one that
    /// has simply gone stale.
    private func seededCorpus() -> MemoryLibrarian.Corpus {
        let index = """
            # Memory Index

            One line per fact.

            - 2026-01-02 — Sessions are spawned through ClaudeCodeCLIRuntime [sessions-spawned-runtime]
            - 2026-02-03 — Every session is spawned by ClaudeCodeCLIRuntime [every-session-spawned]
            - 2026-03-04 — The permission bridge speaks over stdout [bridge-speaks-stdout]
            - 2026-04-05 — The Workflows tab is the place to build pipelines [workflows-tab-pipelines]
            """
        return MemoryLibrarian.Corpus(
            agents: [MemoryLibrarian.AgentCorpus(
                agentID: "coder", agentName: "Coder", index: index,
                topics: [
                    MemoryTopic(id: "sessions-spawned-runtime", body: "Sessions are spawned through ClaudeCodeCLIRuntime."),
                    MemoryTopic(id: "every-session-spawned", body: "Every session is spawned by ClaudeCodeCLIRuntime."),
                    MemoryTopic(id: "bridge-speaks-stdout", body: "The permission bridge speaks over stdout."),
                    MemoryTopic(id: "workflows-tab-pipelines", body: "The Workflows tab is the place to build pipelines."),
                ]
            )],
            coordinatorKnowledge: "- The permission bridge speaks over stderr."
        )
    }

    private let seededReply = """
        {"proposals": [
          {"kind": "merge", "agent": "coder",
           "topics": ["sessions-spawned-runtime", "every-session-spawned"],
           "content": "Sessions are spawned through ClaudeCodeCLIRuntime.",
           "reason": "Both facts say the same thing."},
          {"kind": "delete", "agent": "coder", "topic": "bridge-speaks-stdout",
           "reason": "The bridge uses stderr, not stdout.",
           "evidence": "ClaudeCodeCLIRuntime.swift reads permission JSON off stderr."},
          {"kind": "archive", "agent": "coder", "topic": "workflows-tab-pipelines",
           "reason": "The Workflows tab was removed."}
        ]}
        """

    // MARK: - Parsing a pass's answer

    func testSeededCorpusYieldsOneOfEachProposal() {
        let (proposals, notes) = MemoryLibrarian.parse(seededReply, corpus: seededCorpus())

        XCTAssertEqual(notes, [], "nothing in this reply should have been dropped")
        XCTAssertEqual(proposals.count, 3)
        XCTAssertEqual(proposals.map(\.operation), [
            .merge(topics: ["sessions-spawned-runtime", "every-session-spawned"]),
            .delete(topic: "bridge-speaks-stdout"),
            .archive(topic: "workflows-tab-pipelines"),
        ])
        XCTAssertTrue(proposals.allSatisfy { $0.source == .librarian })
        XCTAssertTrue(proposals.allSatisfy { $0.status == .pending })
    }

    func testDeleteCarriesItsEvidence() {
        let (proposals, _) = MemoryLibrarian.parse(seededReply, corpus: seededCorpus())
        let deletion = proposals.first { $0.operation == .delete(topic: "bridge-speaks-stdout") }

        XCTAssertEqual(deletion?.evidence, "ClaudeCodeCLIRuntime.swift reads permission JSON off stderr.")
        XCTAssertEqual(deletion?.rationale, "The bridge uses stderr, not stdout.")
    }

    /// "Seems old" is archival, not deletion — the one downgrade the parser makes,
    /// and it says so rather than dropping the proposal.
    func testDeleteWithoutEvidenceBecomesAnArchive() {
        let reply = """
            {"proposals": [{"kind": "delete", "agent": "coder",
                            "topic": "workflows-tab-pipelines", "reason": "Seems old."}]}
            """
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.operation, .archive(topic: "workflows-tab-pipelines"))
        XCTAssertNil(proposals.first?.evidence)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("named no evidence"), notes[0])
    }

    func testProposalAgainstAnUnknownFactIsDroppedAndSaidSo() {
        let reply = """
            {"proposals": [{"kind": "archive", "agent": "coder", "topic": "no-such-fact", "reason": "x"}]}
            """
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("no-such-fact"), notes[0])
    }

    func testProposalForAnUnknownAgentIsDroppedAndSaidSo() {
        let reply = """
            {"proposals": [{"kind": "archive", "agent": "ghost", "topic": "bridge-speaks-stdout", "reason": "x"}]}
            """
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("ghost"), notes[0])
    }

    func testMergeNamingOneFactIsDropped() {
        let reply = """
            {"proposals": [{"kind": "merge", "agent": "coder",
                            "topics": ["bridge-speaks-stdout"], "content": "x", "reason": "y"}]}
            """
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertTrue(proposals.isEmpty)
        XCTAssertTrue(notes.first?.contains("at least two") == true, notes.first ?? "")
    }

    /// One fact named twice is still one fact. Counted raw it passed the guard,
    /// and the merge it filed was a consolidation of a fact with itself.
    func testMergeNamingOneTopicTwiceIsDropped() {
        let reply = """
            {"proposals": [{"kind": "merge", "agent": "coder",
                            "topics": ["bridge-speaks-stdout", "bridge-speaks-stdout"],
                            "content": "x", "reason": "y"}]}
            """
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("at least two"), notes[0])
        XCTAssertTrue(notes[0].contains("names the same fact twice"), notes[0])
    }

    /// The dedupe only removes the repetition: a merge that names two facts and
    /// repeats one of them still names two, and is still filed.
    func testMergeRepeatingOneOfTwoTopicsIsStillFiled() {
        let reply = """
            {"proposals": [{"kind": "merge", "agent": "coder",
                            "topics": ["sessions-spawned-runtime", "every-session-spawned", "sessions-spawned-runtime"],
                            "content": "Sessions are spawned through ClaudeCodeCLIRuntime.", "reason": "y"}]}
            """
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertEqual(notes, [])
        XCTAssertEqual(proposals.count, 1)
    }

    /// A clean corpus is a valid answer, not a failure — and it reads as one.
    func testEmptyProposalListIsNothingToConsolidate() {
        let (proposals, notes) = MemoryLibrarian.parse("{\"proposals\": []}", corpus: seededCorpus())

        XCTAssertTrue(proposals.isEmpty)
        XCTAssertTrue(notes.isEmpty)
        XCTAssertEqual(MemoryLibrarian.summary(for: proposals), MemoryLibrarian.nothingToConsolidate)
    }

    func testSummaryCountsEachKindOfProposal() {
        let (proposals, _) = MemoryLibrarian.parse(seededReply, corpus: seededCorpus())
        XCTAssertEqual(
            MemoryLibrarian.summary(for: proposals),
            "Proposed 1 merge, 1 delete, 1 archive — waiting for your approval."
        )
    }

    func testFencedJSONIsStillRead() {
        let reply = "Here is what I found:\n```json\n\(seededReply)\n```\n"
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertEqual(proposals.count, 3)
        XCTAssertEqual(notes, [])
    }

    func testAReplyThatIsNotJSONProposesNothingAndSaysWhy() {
        let (proposals, notes) = MemoryLibrarian.parse("I could not do that.", corpus: seededCorpus())

        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("not the JSON object"), notes[0])
    }

    /// A brace in the prose ahead of the object used to be where the slice
    /// started, so the whole pass — already paid for — reported nothing.
    func testABraceInThePrefacingProseDoesNotSwallowTheObject() {
        let reply = "The pair {sessions-spawned-runtime} names is duplicated:\n\(seededReply)"
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertEqual(proposals.count, 3)
        XCTAssertEqual(notes, [])
    }

    /// The same failure from the other end: a `}` after the object used to be
    /// where the slice stopped.
    func testABraceInTheTrailingProseDoesNotSwallowTheObject() {
        let reply = "\(seededReply)\nI left the rest alone — nothing else closed a } for me."
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertEqual(proposals.count, 3)
        XCTAssertEqual(notes, [])
    }

    /// Several objects in one reply: the one carrying the proposals wins, not
    /// whichever came first.
    func testTheObjectCarryingProposalsWinsOverAnEarlierOne() {
        let reply = """
            A quick tally first: {"agents": 1, "facts": 4}

            \(seededReply)
            """
        let (proposals, notes) = MemoryLibrarian.parse(reply, corpus: seededCorpus())

        XCTAssertEqual(proposals.count, 3)
        XCTAssertEqual(notes, [])
    }

    func testAnObjectWithoutProposalsSaysSo() {
        let (proposals, notes) = MemoryLibrarian.parse("{\"summary\": \"nothing to do\"}", corpus: seededCorpus())

        XCTAssertTrue(proposals.isEmpty)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("carried no `proposals` list"), notes[0])
    }

    // MARK: - The corpus and the prompt

    func testCorpusWithNoFactsIsEmpty() {
        let corpus = MemoryLibrarian.Corpus(
            agents: [MemoryLibrarian.AgentCorpus(agentID: "a", agentName: "A", index: "", topics: [])],
            coordinatorKnowledge: "- something the project learned"
        )
        XCTAssertTrue(corpus.isEmpty, "coordinator knowledge alone is context, not a corpus to consolidate")
    }

    func testSeededCorpusCountsItsFacts() {
        XCTAssertEqual(seededCorpus().factCount, 4)
        XCTAssertFalse(seededCorpus().isEmpty)
    }

    func testPromptCarriesEveryTopicAndTheReplyContract() {
        let prompt = MemoryLibrarian.prompt(corpus: seededCorpus())

        for topic in ["sessions-spawned-runtime", "every-session-spawned", "bridge-speaks-stdout", "workflows-tab-pipelines"] {
            XCTAssertTrue(prompt.contains(topic), "prompt is missing \(topic)")
        }
        XCTAssertTrue(prompt.contains("coder"), "the prompt has to name the agent id the reply keys on")
        XCTAssertTrue(prompt.contains("\"proposals\""))
        XCTAssertTrue(prompt.contains("do not propose against it"),
                      "coordinator knowledge goes in as context, and the prompt has to say so")
    }

    /// A body long enough to bloat the prompt is cut, and the cut is marked —
    /// the system prompt forbids judging a fact on the part that was removed, so
    /// the marker is what makes that rule checkable.
    func testALongBodyIsTruncatedAndTheCutIsMarked() {
        let long = String(repeating: "a", count: MemoryLibrarian.maxBodyLength + 500)
        let rendered = MemoryLibrarian.render(agent: MemoryLibrarian.AgentCorpus(
            agentID: "coder", agentName: "Coder",
            index: "- 2026-01-01 — A fact [a-fact]",
            topics: [MemoryTopic(id: "a-fact", body: long)]
        ))

        XCTAssertTrue(rendered.contains("truncated"))
        XCTAssertLessThan(rendered.count, long.count)
    }

    // MARK: - The per-agent body cap

    /// An agent whose index names none of `count` topics — every body in the
    /// corpus is one the cap can drop without preferring it over another.
    private func agentWithUnindexedBodies(count: Int, agentID: String = "coder") -> MemoryLibrarian.AgentCorpus {
        MemoryLibrarian.AgentCorpus(
            agentID: agentID, agentName: "Coder", index: "",
            topics: (0..<count).map { MemoryTopic(id: "topic-\($0)", body: "Body \($0).") }
        )
    }

    func testACorpusUnderTheCapRendersExactlyAsBeforeWithNoWithheldLine() {
        let agent = agentWithUnindexedBodies(count: MemoryLibrarian.maxBodiesPerAgent)
        let (shown, withheld) = MemoryLibrarian.selectedBodies(for: agent)

        XCTAssertEqual(shown.map(\.id), agent.topics.map(\.id), "at the cap, nothing is reordered or dropped")
        XCTAssertEqual(withheld, 0)
        let rendered = MemoryLibrarian.render(agent: agent)
        XCTAssertFalse(rendered.contains("not shown here"), rendered)
    }

    func testACorpusOverTheCapRendersOnlyCapManyBodiesAndSaysHowManyWereWithheld() {
        let agent = agentWithUnindexedBodies(count: MemoryLibrarian.maxBodiesPerAgent + 7)
        let (shown, withheld) = MemoryLibrarian.selectedBodies(for: agent)

        XCTAssertEqual(shown.count, MemoryLibrarian.maxBodiesPerAgent)
        XCTAssertEqual(withheld, 7)
        let rendered = MemoryLibrarian.render(agent: agent)
        XCTAssertTrue(rendered.contains("7 further topic bodies are not shown here"), rendered)
    }

    /// The cap forces a choice between `maxBodiesPerAgent` bodies and the corpus
    /// has one more — a topic the index still names. It has to survive the cut
    /// even though every unindexed topic sorts ahead of it by file order.
    func testATopicNamedInTheIndexIsRenderedAheadOfOneThatIsNotWhenTheCapForcesAChoice() {
        let unindexed = (0..<MemoryLibrarian.maxBodiesPerAgent).map { MemoryTopic(id: "topic-\($0)", body: "Body \($0).") }
        let indexed = MemoryTopic(id: "still-in-the-index", body: "Kept.")
        let agent = MemoryLibrarian.AgentCorpus(
            agentID: "coder", agentName: "Coder",
            index: "- 2026-01-01 — Kept [still-in-the-index]",
            topics: unindexed + [indexed]
        )

        let (shown, withheld) = MemoryLibrarian.selectedBodies(for: agent)

        XCTAssertEqual(withheld, 1)
        XCTAssertTrue(shown.contains(indexed), "the topic the index still names must not be the one dropped")
    }

    func testAgentCorpusOverTheCapDoesNotAppearInThePromptAtAll() throws {
        let agent = agentWithUnindexedBodies(count: MemoryLibrarian.maxBodiesPerAgent + 1)
        let corpus = MemoryLibrarian.Corpus(agents: [agent], coordinatorKnowledge: nil)

        XCTAssertEqual(MemoryLibrarian.totalWithheldBodies(corpus: corpus), 1)
        let note = try XCTUnwrap(MemoryLibrarian.withheldBodiesNote(corpus: corpus))
        XCTAssertTrue(note.contains("1 topic body did not fit"), note)

        let lastTopic = try XCTUnwrap(agent.topics.last)
        XCTAssertFalse(MemoryLibrarian.prompt(corpus: corpus).contains(lastTopic.id))
    }

    func testACorpusUnderTheCapHasNoWithheldNote() {
        let agent = agentWithUnindexedBodies(count: 3)
        let corpus = MemoryLibrarian.Corpus(agents: [agent], coordinatorKnowledge: nil)

        XCTAssertNil(MemoryLibrarian.withheldBodiesNote(corpus: corpus))
    }

    // MARK: - Cadence

    func testACorpusNeverConsolidatedIsDue() {
        XCTAssertTrue(MemoryLibrarian.isDue(lastPassAt: nil))
    }

    func testARecentPassIsNotDueAndAnOldOneIs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(MemoryLibrarian.isDue(lastPassAt: now.addingTimeInterval(-60 * 60), now: now))
        XCTAssertTrue(MemoryLibrarian.isDue(lastPassAt: now.addingTimeInterval(-MemoryLibrarian.interval - 1), now: now))
    }

    func testStateRoundTripsThroughItsFile() throws {
        let url = project.memoryLibrarianStateURL
        let state = MemoryLibrarianPass.State(
            lastPassAt: Date(timeIntervalSince1970: 1_800_000_000),
            summary: "Proposed 1 merge — waiting for your approval.",
            costUSD: 0.0123, proposals: 1
        )
        try MemoryLibrarianPass.saveState(state, to: url)

        XCTAssertEqual(MemoryLibrarianPass.loadState(from: url), state)
    }

    func testNoStateFileMeansNeverConsolidated() {
        XCTAssertNil(MemoryLibrarianPass.loadState(from: project.memoryLibrarianStateURL))
    }

    /// A record that cannot be written throws rather than going quietly. It used
    /// to `try?` the encode, the directory and the write alike, so a save that
    /// never happened was indistinguishable from one that did.
    func testSavingARecordThatCannotBeWrittenThrowsAndLeavesDiskAsItWas() throws {
        // An ordinary file where the containing directory should be: nothing can
        // be created under it, so neither the temp file nor the rename can land.
        let blocked = tempDir.appending(path: "blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let url = blocked.appending(path: "memory-librarian.json")

        XCTAssertThrowsError(try MemoryLibrarianPass.saveState(
            MemoryLibrarianPass.State(
                lastPassAt: Date(timeIntervalSince1970: 1_800_000_000),
                summary: MemoryLibrarian.nothingToConsolidate, costUSD: 0.01, proposals: 0
            ),
            to: url
        ))

        XCTAssertEqual(try Data(contentsOf: blocked), Data("not a directory".utf8),
                       "what was on disk is what it was — no half-written record, no leftover temp file")
        XCTAssertNil(MemoryLibrarianPass.loadState(from: url))
    }

    // MARK: - Approving one, through the existing gate

    func testApprovingAMergeReplacesBothFactsWithOne() async throws {
        let manager = MemoryManager(project: project)
        let first = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through ClaudeCodeCLIRuntime")
        try await manager.approve(proposalID: first.id)
        let second = try await manager.proposeUpdate(agentID: "coder", content: "Runtime spawns every session")
        try await manager.approve(proposalID: second.id)

        let topics = await manager.memoryTopics(agentID: "coder").map(\.id)
        XCTAssertEqual(topics.count, 2)

        let merge = try await manager.file(MemoryProposal(
            agentID: "coder",
            proposedContent: "ClaudeCodeCLIRuntime spawns every session",
            operation: .merge(topics: topics.sorted()), source: .librarian,
            rationale: "Both say the same thing."
        ))
        try await manager.approve(proposalID: merge.id)

        let index = await manager.currentMemory(agentID: "coder")
        let facts = AgentMemoryIndex.parse(index)
        XCTAssertEqual(facts.count, 1, "two facts merged into one")
        XCTAssertEqual(facts.first?.headline, "ClaudeCodeCLIRuntime spawns every session")

        // The sources' bodies are archived, not destroyed: the merged text is a
        // summary, and the originals are what it was summarised from.
        let remaining = await manager.memoryTopics(agentID: "coder").map(\.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertFalse(topics.contains(remaining[0]))
        for topic in topics {
            XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL(topic: topic).path(percentEncoded: false)),
                          "\(topic) should have been archived")
        }
    }

    /// A merge naming one fact twice is a merge of one fact, and is refused as
    /// one. It used to be carried out: the repeated name resolved to a repeated
    /// position, and removing the second copy deleted the merged line the write
    /// had just put there — leaving the index without the fact just approved.
    func testApprovingAMergeNamingOneFactTwiceIsRefusedAndKeepsTheFact() async throws {
        let manager = MemoryManager(project: project)
        let seed = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through ClaudeCodeCLIRuntime")
        try await manager.approve(proposalID: seed.id)
        let seeded = await manager.memoryTopics(agentID: "coder")
        let topic = try XCTUnwrap(seeded.first?.id)

        let merge = try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "ClaudeCodeCLIRuntime spawns every session",
            operation: .merge(topics: [topic, topic]), source: .librarian
        ))

        do {
            try await manager.approve(proposalID: merge.id)
            XCTFail("a merge naming one fact twice should be refused")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(reason.contains("at least two facts"), reason)
        }

        let index = await manager.currentMemory(agentID: "coder")
        XCTAssertEqual(AgentMemoryIndex.parse(index).map(\.topic), [topic],
                       "the fact the merge named is still in the index")
        let remaining = await manager.memoryTopics(agentID: "coder").map(\.id)
        XCTAssertEqual(remaining, [topic])
    }

    /// A merge that names two facts and repeats one of them is a merge of those
    /// two: it goes through, and the fact it did not name is untouched.
    func testApprovingAMergeThatRepeatsATopicKeepsTheMergedFactAndTheRest() async throws {
        let manager = MemoryManager(project: project)
        for content in ["Sessions are spawned through ClaudeCodeCLIRuntime",
                        "Runtime spawns every session",
                        "The Workflows tab is the place to build pipelines"] {
            let seed = try await manager.proposeUpdate(agentID: "coder", content: content)
            try await manager.approve(proposalID: seed.id)
        }
        let seeded = await manager.memoryTopics(agentID: "coder").map(\.id)
        guard seeded.count == 3 else { return XCTFail("expected three seeded facts, got \(seeded.count)") }
        let (a, b, untouched) = (seeded[0], seeded[1], seeded[2])

        let merge = try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "ClaudeCodeCLIRuntime spawns every session",
            operation: .merge(topics: [a, b, a]), source: .librarian
        ))
        try await manager.approve(proposalID: merge.id)

        let facts = AgentMemoryIndex.parse(await manager.currentMemory(agentID: "coder"))
        XCTAssertEqual(facts.count, 2, "the merged fact and the one the merge did not name")
        XCTAssertTrue(facts.contains { $0.headline == "ClaudeCodeCLIRuntime spawns every session" },
                      "the merged fact is what the index lost when the removal ate its own line")
        XCTAssertTrue(facts.contains { $0.topic == untouched })
        XCTAssertFalse(facts.contains { $0.topic == a || $0.topic == b })

        for topic in [a, b] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL(topic: topic).path(percentEncoded: false)),
                          "\(topic) should have been archived")
        }
    }

    /// The refusal this item is about: a plain file sits where the archive
    /// directory would be created, so the move that archiving a body means can
    /// never land. It used to be swallowed — the index lost the fact's line while
    /// its body stayed exactly where `memoryTopics` and `recallMemory` still find
    /// it, so the fact kept being recalled after the card said it would not be.
    func testApprovingAMergeWhoseSourceBodiesCannotBeArchivedThrowsAndKeepsBothFacts() async throws {
        let manager = MemoryManager(project: project)
        let first = try await manager.proposeUpdate(agentID: "coder", content: "Sessions are spawned through ClaudeCodeCLIRuntime")
        try await manager.approve(proposalID: first.id)
        let second = try await manager.proposeUpdate(agentID: "coder", content: "Runtime spawns every session")
        try await manager.approve(proposalID: second.id)
        let topics = await manager.memoryTopics(agentID: "coder").map(\.id).sorted()
        XCTAssertEqual(topics.count, 2)
        let indexBefore = await manager.currentMemory(agentID: "coder")

        try blockArchiveDir()

        let merge = try await manager.file(MemoryProposal(
            agentID: "coder",
            proposedContent: "ClaudeCodeCLIRuntime spawns every session",
            operation: .merge(topics: topics), source: .librarian,
            rationale: "Both say the same thing."
        ))

        do {
            try await manager.approve(proposalID: merge.id)
            XCTFail("a merge whose source bodies cannot be archived should throw")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(topics.contains { reason.contains($0) }, reason)
        }

        let indexAfter = await manager.currentMemory(agentID: "coder")
        XCTAssertEqual(indexBefore, indexAfter, "the merged line has not replaced the two source facts")
        let remaining = await manager.memoryTopics(agentID: "coder").map(\.id).sorted()
        XCTAssertEqual(remaining, topics, "neither source body moved")
        let pending = await manager.pendingProposals()
        XCTAssertEqual(pending.map(\.id), [merge.id], "the refused approval leaves the proposal to be dealt with")
    }

    func testApprovingADeleteRemovesTheFactAndItsBody() async throws {
        let manager = MemoryManager(project: project)
        let seed = try await manager.proposeUpdate(agentID: "coder", content: "The permission bridge speaks over stdout")
        try await manager.approve(proposalID: seed.id)
        let seeded = await manager.memoryTopics(agentID: "coder")
        let topic = try XCTUnwrap(seeded.first?.id)

        let deletion = try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "The bridge uses stderr.",
            operation: .delete(topic: topic), source: .librarian,
            evidence: "ClaudeCodeCLIRuntime.swift reads permission JSON off stderr."
        ))
        try await manager.approve(proposalID: deletion.id)

        let index = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(AgentMemoryIndex.parse(index).isEmpty)
        let topics = await manager.memoryTopics(agentID: "coder")
        XCTAssertTrue(topics.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL(topic: topic).path(percentEncoded: false)),
                       "a deletion destroys the body — that is what makes it not an archival")
    }

    func testApprovingAnArchiveKeepsTheBodyButStopsInjectingAndRecallingIt() async throws {
        let manager = MemoryManager(project: project)
        let seed = try await manager.proposeUpdate(agentID: "coder", content: "The Workflows tab is the place to build pipelines")
        try await manager.approve(proposalID: seed.id)
        let seeded = await manager.memoryTopics(agentID: "coder")
        let topic = try XCTUnwrap(seeded.first?.id)

        let archival = try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "The Workflows tab was removed.",
            operation: .archive(topic: topic), source: .librarian
        ))
        try await manager.approve(proposalID: archival.id)

        let index = await manager.currentMemory(agentID: "coder")
        XCTAssertTrue(AgentMemoryIndex.parse(index).isEmpty)
        let topics = await manager.memoryTopics(agentID: "coder")
        XCTAssertTrue(topics.isEmpty, "an archived fact is no longer a topic")
        let recalled = await manager.recallMemory(agentID: "coder", query: "Workflows tab")
        XCTAssertTrue(recalled.isEmpty, "an archived fact is no longer recalled")
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL(topic: topic).path(percentEncoded: false)),
                      "an archival keeps the text")
    }

    /// Same refusal, on the single-fact path: a plain file where the archive
    /// directory belongs means the move `archiveFact` and an `.archive` proposal
    /// both rely on can never land, and that has to surface rather than vanish
    /// while the fact quietly stays exactly as recallable as it was.
    func testApprovingAnArchiveWhoseBodyCannotBeMovedThrowsAndLeavesMemoryUntouched() async throws {
        let manager = MemoryManager(project: project)
        let seed = try await manager.proposeUpdate(agentID: "coder", content: "The Workflows tab is the place to build pipelines")
        try await manager.approve(proposalID: seed.id)
        let seeded = await manager.memoryTopics(agentID: "coder")
        let topic = try XCTUnwrap(seeded.first?.id)
        let indexBefore = await manager.currentMemory(agentID: "coder")

        try blockArchiveDir()

        let archival = try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "The Workflows tab was removed.",
            operation: .archive(topic: topic), source: .librarian
        ))

        do {
            try await manager.approve(proposalID: archival.id)
            XCTFail("an archival whose body cannot be moved should throw")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(reason.contains(topic), reason)
        }

        let indexAfter = await manager.currentMemory(agentID: "coder")
        XCTAssertEqual(indexBefore, indexAfter, "the index is untouched by a refused archival")
        let topics = await manager.memoryTopics(agentID: "coder").map(\.id)
        XCTAssertEqual(topics, [topic], "the body is still where recallMemory and memoryTopics find it")
        let recalled = await manager.recallMemory(agentID: "coder", query: "Workflows tab")
        XCTAssertFalse(recalled.isEmpty, "a refused archival is still recalled — the write did not happen")
        let pending = await manager.pendingProposals()
        XCTAssertEqual(pending.map(\.id), [archival.id], "the refused approval leaves the proposal to be dealt with")
    }

    /// Rejecting is the other half of the gate: the proposal leaves the pending
    /// list and the memory it named is exactly as it was.
    func testRejectingALibrarianProposalChangesNothing() async throws {
        let manager = MemoryManager(project: project)
        let seed = try await manager.proposeUpdate(agentID: "coder", content: "A fact worth keeping")
        try await manager.approve(proposalID: seed.id)
        let seeded = await manager.memoryTopics(agentID: "coder")
        let topic = try XCTUnwrap(seeded.first?.id)
        let before = await manager.currentMemory(agentID: "coder")

        let deletion = try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "Wrong", operation: .delete(topic: topic),
            source: .librarian, evidence: "nothing, really"
        ))
        try await manager.reject(proposalID: deletion.id)

        let pending = await manager.pendingProposals()
        XCTAssertTrue(pending.isEmpty)
        let after = await manager.currentMemory(agentID: "coder")
        XCTAssertEqual(before, after)
        let topics = await manager.memoryTopics(agentID: "coder").map(\.id)
        XCTAssertEqual(topics, [topic])
    }

    /// A proposal naming a fact that has since gone is refused with a reason and
    /// stays pending, rather than reporting a change nobody made.
    func testApprovingARemovalOfAFactThatIsGoneIsRefused() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "Stale", operation: .archive(topic: "not-there"),
            source: .librarian
        ))

        do {
            try await manager.approve(proposalID: proposal.id)
            XCTFail("approving a removal of a fact that isn't there should throw")
        } catch let error as MemoryWriteError {
            guard case .rejected(let reason) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(reason.contains("not-there"), reason)
        }

        let pending = await manager.pendingProposals()
        XCTAssertEqual(pending.count, 1, "a refused approval leaves the proposal to be dealt with")
    }

    // MARK: - The record on disk

    /// Proposals written before the librarian existed carry none of its fields,
    /// and have to keep loading as what they were — an agent asking to add a
    /// fact — rather than failing to decode and vanishing from the gate.
    func testAProposalWrittenBeforeTheLibrarianStillDecodes() throws {
        let legacy = """
            {"id": "abc", "agentID": "coder", "timestamp": "2026-01-02T03:04:05Z",
             "proposedContent": "An older fact", "status": "pending"}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let proposal = try decoder.decode(MemoryProposal.self, from: Data(legacy.utf8))

        XCTAssertEqual(proposal.operation, .add)
        XCTAssertEqual(proposal.source, .agent)
        XCTAssertNil(proposal.rationale)
        XCTAssertNil(proposal.evidence)
        XCTAssertEqual(proposal.proposedContent, "An older fact")
    }

    func testALibrarianProposalSurvivesARestart() async throws {
        let manager = MemoryManager(project: project)
        try await manager.file(MemoryProposal(
            agentID: "coder", proposedContent: "Contradicted",
            operation: .delete(topic: "some-topic"), source: .librarian,
            rationale: "The code says otherwise.", evidence: "Foo.swift line 12"
        ))

        let reloaded = await MemoryManager(project: project).pendingProposals()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.operation, .delete(topic: "some-topic"))
        XCTAssertEqual(reloaded.first?.source, .librarian)
        XCTAssertEqual(reloaded.first?.evidence, "Foo.swift line 12")
    }

    // MARK: - Cost

    /// The pass is charged like any other LLM work: one entry in the project's
    /// own ledger, under an id that says a librarian pass spent it.
    func testAPassChargesTheProjectLedger() async {
        let tracker = CostTracker(costsURL: project.costsURL)
        await tracker.record(CostEntry(
            agentID: MemoryLibrarianPass.ledgerAgentID,
            costUSD: 0.0123, inputTokens: 0, outputTokens: 0, durationMs: 0
        ))

        let byAgent = await CostTracker(costsURL: project.costsURL).costByAgent()
        XCTAssertEqual(byAgent[MemoryLibrarianPass.ledgerAgentID] ?? 0, 0.0123, accuracy: 0.0001,
                       "the pass's spend has to land in the ledger, attributed")
    }

    // MARK: - A pass that never ran

    /// The agent the seeded memory below belongs to.
    private var coder: Agent {
        Agent(id: "coder", name: "Coder", model: "sonnet", systemPrompt: "",
              tools: [], denied: [], permissionMode: "default", state: .idle)
    }

    /// One approved fact on disk — enough that the corpus is not empty and the
    /// pass goes on to make its one model call.
    @MainActor
    private func seedOneFact() async throws {
        let manager = MemoryManager(project: project)
        let proposal = try await manager.proposeUpdate(
            agentID: coder.id, content: "The permission bridge speaks over stderr"
        )
        try await manager.approve(proposalID: proposal.id)
    }

    @MainActor
    private func makePass(runtime: StubHeadlessRuntime) -> MemoryLibrarianPass {
        MemoryLibrarianPass(
            project: project,
            memoryManager: MemoryManager(project: project),
            runtimeFactory: { runtime },
            globalConfigStore: GlobalConfigStore(storageURL: tempDir.appending(path: "global-config.json"))
        )
    }

    /// A pass whose model call throws read nothing at all, so it writes no
    /// record: the corpus is still unconsolidated and the tab keeps asking.
    @MainActor
    func testAPassWhoseModelCallThrowsRecordsNothing() async throws {
        try await seedOneFact()
        let pass = makePass(runtime: StubHeadlessRuntime(
            behavior: .startFailure(RuntimeError.processSpawnFailed("claude not found"))
        ))

        let outcome = await pass.run(agents: [coder], now: Date())

        XCTAssertNil(pass.state, "a pass that never ran leaves no record behind")
        XCTAssertTrue(pass.isDue(), "the corpus was never read, so a pass is still due")
        XCTAssertTrue(outcome.proposals.isEmpty)
        XCTAssertEqual(outcome.costUSD, 0, "a call that never started charged nothing")
    }

    /// And it says so: a failed call reads differently from a call that came
    /// back empty, which is what tells a human to try again rather than that
    /// their memory is tidy.
    @MainActor
    func testTheOutcomeOfAThrowSaysThePassCouldNotRun() async throws {
        try await seedOneFact()
        let pass = makePass(runtime: StubHeadlessRuntime(
            behavior: .startFailure(RuntimeError.processSpawnFailed("claude not found"))
        ))

        let outcome = await pass.run(agents: [coder], now: Date())

        XCTAssertTrue(outcome.summary.contains("could not run"), outcome.summary)
        XCTAssertFalse(outcome.summary.contains("returned nothing"),
                       "a failed call must not read as one that answered with nothing")
        XCTAssertTrue(outcome.summary.contains("claude not found"),
                      "the summary is the only surface there is, so it names the error: \(outcome.summary)")
    }

    /// The failure that started this: a throw used to stamp `lastPassAt` with
    /// the moment it failed, so `isDue` answered false for a week.
    @MainActor
    func testAThrowLeavesAnEarlierRecordWhereItWas() async throws {
        try await seedOneFact()
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        try MemoryLibrarianPass.saveState(
            MemoryLibrarianPass.State(lastPassAt: earlier, summary: MemoryLibrarian.nothingToConsolidate,
                                      costUSD: 0.01, proposals: 0),
            to: project.memoryLibrarianStateURL
        )
        let pass = makePass(runtime: StubHeadlessRuntime(
            behavior: .startFailure(RuntimeError.processSpawnFailed("claude not found"))
        ))
        let now = earlier.addingTimeInterval(MemoryLibrarian.interval + 1)

        _ = await pass.run(agents: [coder], now: now)

        XCTAssertEqual(pass.state?.lastPassAt, earlier, "a failed call must not move the due clock forward")
        XCTAssertEqual(pass.state?.summary, MemoryLibrarian.nothingToConsolidate,
                       "the earlier pass's record is what it was")
        XCTAssertTrue(pass.isDue(now: now))
    }

    /// The other half of the distinction: a call that happened and came back
    /// empty was asked and was charged, so it records exactly as before.
    @MainActor
    func testAReplyThatComesBackEmptyStillRecordsAPass() async throws {
        try await seedOneFact()
        let runtime = StubHeadlessRuntime(behavior: .events([]))
        let pass = makePass(runtime: runtime)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let outcome = await pass.run(agents: [coder], now: now)

        XCTAssertEqual(runtime.sentPrompts.count, 1, "the call did happen")
        XCTAssertEqual(pass.state?.lastPassAt, now)
        XCTAssertFalse(pass.isDue(now: now))
        XCTAssertTrue(outcome.summary.contains("returned nothing"), outcome.summary)
    }

    /// And an empty corpus, which answers without asking anything at all.
    @MainActor
    func testAnEmptyCorpusStillRecordsAPassAndCallsNoModel() async {
        let runtime = StubHeadlessRuntime(behavior: .events([]))
        let pass = makePass(runtime: runtime)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let outcome = await pass.run(agents: [coder], now: now)

        XCTAssertTrue(runtime.startedAgents.isEmpty, "nothing to consolidate costs no model call")
        XCTAssertTrue(runtime.sentPrompts.isEmpty)
        XCTAssertEqual(outcome.summary, MemoryLibrarian.nothingToConsolidate)
        XCTAssertEqual(pass.state?.lastPassAt, now)
        XCTAssertFalse(pass.isDue(now: now))
    }

    // MARK: - A proposal the pass could not file

    /// Puts a regular file where the agent's `proposals/` directory goes, so
    /// nothing can be written under it.
    private func blockProposals(agentID: String = "coder") throws {
        let dir = project.agentDir(for: agentID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let proposals = dir.appending(path: "proposals")
        try? FileManager.default.removeItem(at: proposals)
        try Data("not a directory".utf8).write(to: proposals)
    }

    /// A proposal whose JSON did not reach disk is waiting for nobody, so it is
    /// named among the notes rather than counted in the summary. The summary is
    /// what sends a human to the gate to approve something, and finding nothing
    /// there is the failure this case exists to prevent.
    @MainActor
    func testAPassNamesAProposalItCouldNotFile() async throws {
        try await seedOneFact()
        let index = await MemoryManager(project: project).currentMemory(agentID: coder.id)
        let topic = try XCTUnwrap(AgentMemoryIndex.parse(index).first?.topic, index)
        let reply = """
            {"proposals": [
              {"kind": "archive", "agent": "coder", "topic": "\(topic)",
               "reason": "The bridge was rewritten."}
            ]}
            """
        let pass = makePass(runtime: StubHeadlessRuntime(behavior: .events([.assistantText(reply)])))
        try blockProposals()

        let outcome = await pass.run(agents: [coder], now: Date())

        XCTAssertTrue(outcome.proposals.isEmpty, "nothing was filed, so nothing is waiting for a human")
        XCTAssertEqual(outcome.summary, MemoryLibrarian.nothingToConsolidate,
                       "a proposal that did not land must not be counted as proposed")
        XCTAssertEqual(outcome.notes.count, 1, outcome.notes.description)
        XCTAssertTrue(outcome.notes[0].contains("Could not file the archive for Coder"),
                      outcome.notes[0])
    }

    /// And the working path is untouched: a pass over a project it can write to
    /// files what it proposed and counts it.
    @MainActor
    func testAPassThatCanWriteFilesWhatItProposed() async throws {
        try await seedOneFact()
        let index = await MemoryManager(project: project).currentMemory(agentID: coder.id)
        let topic = try XCTUnwrap(AgentMemoryIndex.parse(index).first?.topic, index)
        let reply = """
            {"proposals": [
              {"kind": "archive", "agent": "coder", "topic": "\(topic)",
               "reason": "The bridge was rewritten."}
            ]}
            """
        let pass = makePass(runtime: StubHeadlessRuntime(behavior: .events([.assistantText(reply)])))

        let outcome = await pass.run(agents: [coder], now: Date())

        XCTAssertEqual(outcome.proposals.count, 1)
        XCTAssertTrue(outcome.notes.isEmpty, outcome.notes.description)
        let pending = await MemoryManager(project: project).pendingProposals()
        XCTAssertEqual(pending.map(\.operation), [.archive(topic: topic)],
                       "the proposal is on disk, which is what a human will be shown")
    }

    /// A corpus whose topic bodies exceed the per-agent cap: the pass still runs
    /// and files what it can, and its outcome says how many bodies did not make
    /// the prompt.
    @MainActor
    func testAPassOverACorpusThatWasCutNotesHowManyBodiesItLeftOut() async throws {
        try await seedOneFact()
        let topic = try await seededTopic()
        let dir = project.agentDir(for: coder.id).appending(path: "memory")
        for i in 0..<MemoryLibrarian.maxBodiesPerAgent {
            try Data("Body \(i).".utf8).write(to: dir.appending(path: "extra-\(i).md"))
        }
        let pass = makePass(runtime: StubHeadlessRuntime(behavior: .events(oneProposalReply(topic: topic))))

        let outcome = await pass.run(agents: [coder], now: Date())

        XCTAssertTrue(outcome.notes.contains { $0.contains("1 topic body did not fit this pass's per-agent cap") },
                      outcome.notes.description)
        XCTAssertEqual(outcome.proposals.map(\.operation), [.archive(topic: topic)],
                       "the cap withholds bodies from the prompt, not proposals the reply named")
    }

    // MARK: - A record the pass could not write

    /// Puts a directory where the record file goes, so the rename that commits it
    /// cannot land. Everything else the pass touches still works, which is the
    /// point: the corpus is read, the model is called and the ledger is charged
    /// exactly as on the working path.
    private func blockTheRecord() throws {
        try FileManager.default.createDirectory(
            at: project.memoryLibrarianStateURL, withIntermediateDirectories: true
        )
    }

    /// A reply filing one archival, plus a result line carrying what it cost.
    private func oneProposalReply(topic: String) -> [StreamEvent] {
        [
            .assistantText("""
                {"proposals": [
                  {"kind": "archive", "agent": "coder", "topic": "\(topic)",
                   "reason": "The bridge was rewritten."}
                ]}
                """),
            .result(StreamEvent.ResultPayload(
                text: "", costUSD: 0.0123, durationMs: 1200,
                inputTokens: 100, outputTokens: 50,
                cacheCreationInputTokens: 0, cacheReadInputTokens: 0,
                sessionID: "stub-coder", permissionDenials: []
            )),
        ]
    }

    @MainActor
    private func seededTopic() async throws -> String {
        let index = await MemoryManager(project: project).currentMemory(agentID: coder.id)
        return try XCTUnwrap(AgentMemoryIndex.parse(index).first?.topic, index)
    }

    /// The failure this item is about: the pass read the corpus, called a model
    /// and charged the project, and then its record did not reach disk. The write
    /// used to be a bare `try?`, so the pass reported success while `lastPassAt`
    /// stayed unset and the tab went on offering the same pass.
    @MainActor
    func testAPassWhoseRecordCannotBeWrittenSaysSo() async throws {
        try await seedOneFact()
        let topic = try await seededTopic()
        let pass = makePass(runtime: StubHeadlessRuntime(behavior: .events(oneProposalReply(topic: topic))))
        try blockTheRecord()

        let outcome = await pass.run(agents: [coder], now: Date(timeIntervalSince1970: 1_800_000_000))

        let note = try XCTUnwrap(outcome.notes.last, outcome.notes.description)
        XCTAssertTrue(note.contains("not recorded"), note)
        XCTAssertTrue(note.contains("another pass will be offered"), note)
        // What the pass found and what it spent are not the record's business.
        XCTAssertEqual(outcome.proposals.map(\.operation), [.archive(topic: topic)],
                       "the proposal was filed — only the record failed")
        XCTAssertEqual(outcome.costUSD, 0.0123, accuracy: 0.0001,
                       "the call happened and was charged, whatever the record did")
        XCTAssertEqual(outcome.summary, MemoryLibrarian.summary(for: outcome.proposals))
        // And the tab's other reading of the same failure agrees with the note.
        XCTAssertNil(pass.state, "there is no record, which is what the note says")
        XCTAssertTrue(pass.isDue(), "so another pass is still due")
    }

    /// The working path says nothing extra, and the record it wrote reads back as
    /// what the pass did.
    @MainActor
    func testAPassWhoseRecordLandsRoundTripsAndAddsNoNote() async throws {
        try await seedOneFact()
        let topic = try await seededTopic()
        let pass = makePass(runtime: StubHeadlessRuntime(behavior: .events(oneProposalReply(topic: topic))))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let outcome = await pass.run(agents: [coder], now: now)

        XCTAssertEqual(outcome.notes, [], "a record that landed is not worth a sentence")
        XCTAssertEqual(
            MemoryLibrarianPass.loadState(from: project.memoryLibrarianStateURL),
            MemoryLibrarianPass.State(lastPassAt: now, summary: outcome.summary,
                                      costUSD: 0.0123, proposals: 1)
        )
        XCTAssertFalse(pass.isDue(now: now))
    }

    // MARK: -

    private func archiveURL(topic: String) -> URL {
        project.agentDir(for: "coder").appending(path: "memory/archive/\(topic).md")
    }

    /// Puts a plain file where the agent's `memory/archive/` directory goes, so
    /// the `createDirectory` an archival's move opens with can never succeed.
    private func blockArchiveDir(agentID: String = "coder") throws {
        let dir = project.agentDir(for: agentID).appending(path: "memory")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let archivePath = dir.appending(path: "archive")
        try? FileManager.default.removeItem(at: archivePath)
        try Data("not a directory".utf8).write(to: archivePath)
    }
}
