import Foundation
import KiteloopCore
import os.log

private let librarianLog = Logger(subsystem: "ai.kasatkin.kiteloop", category: "memory-librarian")

/// Runs one librarian pass: gather the corpus, ask once, file what comes back as
/// proposals, charge what it cost.
///
/// The model call is a one-shot through ``HeadlessAgentRunner``, which starts the
/// session `unattended` — so the CLI keeps no memory of its own
/// (`ClaudeCodeCLIRuntime.sessionEnvironment(_:unattended:)`). That matters more
/// here than anywhere else: a pass that read the whole memory corpus and then
/// wrote its own notes about it would be adding to exactly the pile it was sent
/// to reduce. It runs in `plan` mode with the default tool scope, so it can read
/// the repository to check whether a fact still holds and can change nothing.
///
/// It applies nothing. Everything it decides is a ``MemoryProposal`` in the
/// Memory tab, approved or rejected by a human one at a time.
@MainActor
final class MemoryLibrarianPass {
    private let project: KiteloopProject
    private let memoryManager: MemoryManager
    private let runtimeFactory: () -> any AgentRuntime
    private let globalConfigStore: GlobalConfigStore
    /// Where the pass's spend is booked. The project's own ledger — the same
    /// `costs.jsonl` every other attributed spend goes to — under an agent id of
    /// ``ledgerAgentID``, so a librarian pass shows up as work somebody paid for
    /// rather than as cost with no owner.
    private let costTracker: any CostTracking

    /// The name the ledger books a pass under. Not an agent in the team: the
    /// librarian is a pass over the team's memory, and attributing its cost to
    /// whichever agent happened to be selected would be a lie about who spent it.
    nonisolated static let ledgerAgentID = "librarian"

    init(
        project: KiteloopProject,
        memoryManager: MemoryManager,
        runtimeFactory: @escaping () -> any AgentRuntime,
        globalConfigStore: GlobalConfigStore,
        costTracker: (any CostTracking)? = nil
    ) {
        self.project = project
        self.memoryManager = memoryManager
        self.runtimeFactory = runtimeFactory
        self.globalConfigStore = globalConfigStore
        self.costTracker = costTracker ?? CostTracker(costsURL: project.costsURL)
    }

    // MARK: - The pass

    /// One pass over `agents`' memory.
    ///
    /// An empty corpus returns without calling a model at all: there is nothing
    /// to consolidate, that is a valid outcome, and it should cost nothing to
    /// establish. A corpus with facts in it costs one read — the pass makes a
    /// single call whether it finds work or not.
    ///
    /// A call that *throws* is the one outcome that records nothing. An empty
    /// reply still records a pass — the model was asked and was charged, and
    /// "nothing came back" is an answer about the corpus. A throw is not: the
    /// corpus was never read, so ``isDue`` has to keep saying so rather than
    /// quieting the Memory tab's badge for ``MemoryLibrarian/interval``.
    func run(agents: [Agent], now: Date = Date()) async -> MemoryLibrarian.Outcome {
        let corpus = await corpus(for: agents)
        guard !corpus.isEmpty else {
            return record(
                MemoryLibrarian.Outcome.nothing(
                    costUSD: 0,
                    notes: ["No agent has any memory recorded yet."]
                ),
                at: now
            )
        }

        let withheldNote = MemoryLibrarian.withheldBodiesNote(corpus: corpus)

        let reply: HeadlessAgentRunner.Reply
        do {
            reply = try await HeadlessAgentRunner.runDetailed(
                prompt: MemoryLibrarian.prompt(corpus: corpus),
                cwd: project.rootURL,
                systemPrompt: MemoryLibrarian.systemPrompt,
                agentName: "Librarian",
                runtimeFactory: runtimeFactory,
                globalConfigStore: globalConfigStore
            )
        } catch {
            // Nothing was read, so nothing is recorded: a pass that never ran
            // must leave `lastPassAt` where it was, or `isDue` answers false for
            // a week over a corpus no model ever looked at.
            librarianLog.error("Librarian pass could not run: \(error.localizedDescription, privacy: .public)")
            return MemoryLibrarian.Outcome(
                proposals: [], costUSD: 0,
                summary: "The librarian pass could not run — \(error.localizedDescription)",
                notes: []
            )
        }
        // Charged whatever came back, including nothing: the call happened.
        let costUSD = reply.costUSD
        await charge(costUSD, at: now)

        let text = reply.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            librarianLog.info("Librarian pass: no reply came back")
            return record(
                MemoryLibrarian.Outcome(
                    proposals: [], costUSD: costUSD,
                    summary: "The librarian pass returned nothing — no proposals were filed.",
                    notes: withheldNote.map { [$0] } ?? []
                ),
                at: now
            )
        }

        let (proposals, parseNotes) = MemoryLibrarian.parse(text, corpus: corpus)
        let (filed, notes) = await file(proposals, corpus: corpus, notes: (withheldNote.map { [$0] } ?? []) + parseNotes)
        let outcome = MemoryLibrarian.Outcome(
            proposals: filed,
            costUSD: costUSD,
            summary: MemoryLibrarian.summary(for: filed),
            notes: notes
        )
        librarianLog.info("Librarian pass: \(outcome.summary, privacy: .public) ($\(String(format: "%.4f", costUSD), privacy: .public))")
        return record(outcome, at: now)
    }

    /// Writes what the reply proposed, one at a time. A proposal whose JSON did
    /// not reach disk is not waiting for anybody, so it is not counted as
    /// filed — it is said, appended to whatever notes the corpus and the reply
    /// already carried.
    private func file(
        _ proposals: [MemoryProposal], corpus: MemoryLibrarian.Corpus, notes startingNotes: [String]
    ) async -> (filed: [MemoryProposal], notes: [String]) {
        var filed: [MemoryProposal] = []
        var notes = startingNotes
        for proposal in proposals {
            do {
                try await memoryManager.file(proposal)
                filed.append(proposal)
            } catch {
                let name = corpus.agents.first { $0.agentID == proposal.agentID }?.agentName ?? proposal.agentID
                notes.append("Could not file the \(proposal.operation.label.lowercased()) for \(name) — \(error.localizedDescription)")
            }
        }
        return (filed, notes)
    }

    /// What the pass reads: each agent's index and topic bodies, plus the
    /// project's own learned knowledge as context.
    func corpus(for agents: [Agent]) async -> MemoryLibrarian.Corpus {
        var entries: [MemoryLibrarian.AgentCorpus] = []
        for agent in agents {
            let index = await memoryManager.currentMemory(agentID: agent.id)
            let topics = await memoryManager.memoryTopics(agentID: agent.id)
            guard !index.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !topics.isEmpty else {
                continue
            }
            entries.append(MemoryLibrarian.AgentCorpus(
                agentID: agent.id, agentName: agent.name, index: index, topics: topics
            ))
        }
        return MemoryLibrarian.Corpus(
            agents: entries,
            coordinatorKnowledge: CoordinatorAdvisor.loadKiteloopFile(
                projectPath: project.rootURL.path(percentEncoded: false),
                name: CoordinatorKnowledge.fileName
            )
        )
    }

    private func charge(_ costUSD: Double, at now: Date) async {
        guard costUSD > 0 else { return }
        await costTracker.record(CostEntry(
            agentID: Self.ledgerAgentID,
            costUSD: costUSD,
            inputTokens: 0,
            outputTokens: 0,
            durationMs: 0
        ))
    }

    // MARK: - When the last pass was

    /// What a finished pass leaves behind, so the next launch can say when the
    /// corpus was last looked at and whether another pass is due.
    struct State: Codable, Equatable, Sendable {
        var lastPassAt: Date
        var summary: String
        var costUSD: Double
        var proposals: Int
    }

    /// Read from disk each time rather than cached: the file is the record, and
    /// a pass run from another window of the same project is still a pass.
    var state: State? { Self.loadState(from: project.memoryLibrarianStateURL) }

    /// Whether a pass is worth offering — never consolidated, or older than
    /// ``MemoryLibrarian/interval``. Advisory: the button works either way.
    func isDue(now: Date = Date()) -> Bool {
        MemoryLibrarian.isDue(lastPassAt: state?.lastPassAt, now: now)
    }

    /// Writes what this pass leaves behind, and returns the outcome the tab shows.
    ///
    /// A record that did not reach disk is the pass's own business, not a
    /// background detail: ``isDue`` reads that file and nothing else, so a pass
    /// that read the whole corpus, called a model and charged the project would
    /// otherwise report success while the Memory tab kept offering the same pass
    /// and `lastPassAt` stayed nil. It says so instead, in the notes the tab
    /// already prints. What the pass *found* and what it *spent* are untouched by
    /// the failure — the proposals are filed and the ledger is charged either way.
    private func record(_ outcome: MemoryLibrarian.Outcome, at now: Date) -> MemoryLibrarian.Outcome {
        do {
            try Self.saveState(
                State(lastPassAt: now, summary: outcome.summary,
                      costUSD: outcome.costUSD, proposals: outcome.proposals.count),
                to: project.memoryLibrarianStateURL
            )
            return outcome
        } catch {
            librarianLog.error("Librarian pass record could not be written: \(error.localizedDescription, privacy: .public)")
            return MemoryLibrarian.Outcome(
                proposals: outcome.proposals,
                costUSD: outcome.costUSD,
                summary: outcome.summary,
                notes: outcome.notes + [
                    // Both halves of the consequence come before the error text:
                    // an `AtomicFileWriter.WriteError` is not a `LocalizedError`,
                    // so what it renders as is diagnostic rather than a sentence,
                    // and the note has to read as one without it.
                    "This pass was not recorded, so another pass will be offered — the record could not be written: \(error.localizedDescription)"
                ]
            )
        }
    }

    /// Reading and writing the record are plain file operations on a Sendable
    /// value, so they are not the main actor's business — which also lets a test
    /// drive them without one.
    nonisolated static func loadState(from url: URL) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    /// Throwing, and durable — through the same ``AtomicFileWriter/write(_:to:)``
    /// `MemoryManager.persistProposal(_:)` uses, which makes the containing
    /// directory and commits the bytes before the name.
    ///
    /// Both halves matter here. A bare `data.write(to:)` is neither atomic nor
    /// flushed, so an unclean shutdown leaves a prefix of the JSON that
    /// ``loadState`` reads back as no record at all; and swallowing the error left
    /// the only caller with no way to know the record it had just asked for was
    /// never made.
    nonisolated static func saveState(_ state: State, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        try AtomicFileWriter.write(encoder.encode(state), to: url)
    }
}
