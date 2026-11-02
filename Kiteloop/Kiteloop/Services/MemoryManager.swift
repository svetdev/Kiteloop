import Foundation
import KiteloopCore

protocol KnowledgeProviding: Sendable {
    func knowledgeContent(for agentID: String) -> String?
}

protocol MemoryManaging: Sendable {
    func proposeUpdate(agentID: String, content: String) async throws -> MemoryProposal
    func file(_ proposal: MemoryProposal) async throws -> MemoryProposal
    func approve(proposalID: String) async throws
    func reject(proposalID: String) async throws
    func edit(proposalID: String, newContent: String) async throws
    func archiveFact(agentID: String, topic: String) async throws
    func restoreFact(agentID: String, topic: String) async throws
    func deleteArchivedFact(agentID: String, topic: String) async throws
    func rewriteFact(agentID: String, topic: String, content: String) async throws
    func addFact(agentID: String, content: String) async throws
    func pendingProposals() async -> [MemoryProposal]
    func currentMemory(agentID: String) async -> String
    func memoryTopics(agentID: String) async -> [MemoryTopic]
    func archivedTopics(agentID: String) async -> [MemoryTopic]
    func recallMemory(agentID: String, query: String) async -> String
    func sharedContext() async -> String
    func saveSharedContext(_ content: String) async throws
    func composeSystemContext(agent: Agent) async -> String
    func composeSystemContext(agent: Agent, skillRegistry: SkillRegistry?) async -> String
}

/// One fact's body, as stored under `memory/<id>.md`.
struct MemoryTopic: Identifiable, Equatable, Sendable {
    /// The topic slug, which is also the name `recall_knowledge` answers to.
    let id: String
    let body: String
}

/// Why a memory write did not land — an approved proposal that did not reach the
/// index, or a proposal whose own JSON did not reach disk.
///
/// The index is capped, and a write past the cap is refused rather than silently
/// dropped — so the refusal has to carry a sentence saying what would let it
/// through. It is thrown from ``MemoryManager/approve(proposalID:)``, which
/// leaves the proposal pending: the human can edit it and approve again. It is
/// also thrown from ``MemoryManager/persistProposal(_:)``, which is what filing a
/// proposal *is*: a proposal only this process knows about is one the next launch
/// will not find, so a caller told it was filed was told something untrue.
enum MemoryWriteError: LocalizedError, Equatable {
    case rejected(reason: String)

    var errorDescription: String? {
        switch self {
        case .rejected(let reason): return "Memory not written — \(reason)"
        }
    }
}

actor MemoryManager: MemoryManaging {
    private let project: KiteloopProject
    private var proposals: [MemoryProposal] = []
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let knowledgeProvider: (any KnowledgeProviding)?
    private let knowledgeRecallService: KnowledgeRecallService?

    init(project: KiteloopProject, knowledgeProvider: (any KnowledgeProviding)? = nil, knowledgeRecallService: KnowledgeRecallService? = nil) {
        self.project = project
        self.knowledgeProvider = knowledgeProvider
        self.knowledgeRecallService = knowledgeRecallService
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted]
        self.encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.proposals = Self.loadProposals(project: project, decoder: decoder)
    }

    func proposeUpdate(agentID: String, content: String) throws -> MemoryProposal {
        try file(MemoryProposal(agentID: agentID, proposedContent: content))
    }

    /// Records a proposal built elsewhere — a librarian pass, which proposes
    /// merges and removals rather than the single add-a-fact shape
    /// ``proposeUpdate(agentID:content:)`` covers.
    ///
    /// Writes first, then remembers: a proposal that reached only this actor's
    /// array is one ``loadProposals`` will not find at the next launch, so filing
    /// it has to mean the JSON landed. A write that did not throws, and nothing
    /// is added — the caller is told the proposal was not recorded rather than
    /// handed one that will not be there tomorrow.
    @discardableResult
    func file(_ proposal: MemoryProposal) throws -> MemoryProposal {
        try persistProposal(proposal)
        proposals.append(proposal)
        return proposal
    }

    /// Writes first, then marks the proposal approved — a write the budget
    /// refuses must not leave behind a proposal that says it was recorded, so a
    /// rejection rethrows and the proposal stays pending for the human to edit.
    ///
    /// The status write is held to the same rule: the fact is on disk by then,
    /// but a status only this process knows about comes back pending at the next
    /// launch, so a status that did not land throws and the proposal is not
    /// reported as approved.
    func approve(proposalID: String) throws {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        let proposal = proposals[index]
        try apply(proposal.operation, agentID: proposal.agentID, content: proposal.proposedContent)
        try mark(at: index, as: .approved)
    }

    /// Carries out what approving a proposal means. Every arm either does the
    /// whole thing or throws ``MemoryWriteError/rejected(reason:)`` having
    /// changed nothing the caller can see — the proposal stays pending either
    /// way until the write has actually happened.
    private func apply(_ operation: MemoryProposal.Operation, agentID: String, content: String) throws {
        switch operation {
        case .add:
            try appendToMemory(agentID: agentID, content: content)
        case .merge(let topics):
            try mergeFacts(agentID: agentID, topics: topics, into: content)
        case .delete(let topic):
            try removeFact(agentID: agentID, topic: topic, keepingBody: false)
        case .archive(let topic):
            try removeFact(agentID: agentID, topic: topic, keepingBody: true)
        }
    }

    func reject(proposalID: String) throws {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        try mark(at: index, as: .rejected)
    }

    /// Records a status on disk, and only then in memory.
    ///
    /// The order is the whole point: a status flipped in the array first and
    /// written second reads as settled while the file still says `pending`, and
    /// the next launch loads the file. So the proposal keeps the status it had
    /// until the write lands, and a write that did not throws.
    private func mark(at index: Int, as status: MemoryProposal.Status, content: String? = nil) throws {
        var updated = proposals[index]
        updated.status = status
        updated.approvedContent = content
        try persistProposal(updated)
        proposals[index] = updated
    }

    /// Approve, with the human's own words in place of the proposed ones.
    ///
    /// The operation is unchanged: editing a merge's text edits what the merged
    /// fact will say, not which facts it replaces. For a deletion or an archival
    /// the text is only the reason, so there is nothing here to edit — the UI
    /// offers no editor for those.
    func edit(proposalID: String, newContent: String) throws {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else { return }
        try apply(proposals[index].operation, agentID: proposals[index].agentID, content: newContent)
        try mark(at: index, as: .edited, content: newContent)
    }

    func pendingProposals() -> [MemoryProposal] {
        proposals.filter { $0.status == .pending }
    }

    /// The human control the Memory tab actually has: takes one fact out of the
    /// index, keeping its body under `memory/archive/` — the same operation a
    /// `.archive` proposal applies, reached here without a proposal to approve.
    /// A topic naming neither an index line nor a body throws, same as it would
    /// through the proposal path.
    func archiveFact(agentID: String, topic: String) throws {
        try removeFact(agentID: agentID, topic: topic, keepingBody: true)
    }

    /// Puts an archived fact back: its body returns to `memory/` and its line
    /// to the index, so it is injected and recalled again. `topic` is the id
    /// ``archivedTopics(agentID:)`` gave it, which is also the restored fact's
    /// topic.
    ///
    /// The line goes through the same budget an approval does — a full index,
    /// or a line that already covers this one, refuses it with the same
    /// sentence — and never replaces a fact: any `supersedes` the body carries
    /// is dropped, and a line this one would displace refuses it too. A live
    /// body already under that name refuses it before anything moves. Same
    /// write order as ``removeFact(agentID:topic:keepingBody:)``: the body moves
    /// first, so a refused move leaves the index as it was.
    func restoreFact(agentID: String, topic: String) throws {
        migrateIfNeeded(agentID: agentID)
        let fm = FileManager.default
        let from = archiveDir(for: agentID).appending(path: "\(topic).md")
        let to = topicsDir(for: agentID).appending(path: "\(topic).md")
        guard let data = try? Data(contentsOf: from) else {
            throw MemoryWriteError.rejected(reason: "\(topic) names no archived fact — it may have been restored already.")
        }
        guard !fm.fileExists(atPath: to.path(percentEncoded: false)) else {
            throw MemoryWriteError.rejected(reason: "\(topic) already has a body in this agent's memory — archive or rename it first.")
        }

        let existing = readIndex(agentID: agentID) ?? ""
        let tail = AgentMemoryIndex.tail(of: existing)
        let fact = try restoredFact(topic: topic, body: String(decoding: data, as: UTF8.self))
        let updated = try restoredIndex(adding: fact, to: AgentMemoryIndex.parse(existing))

        do {
            try fm.moveItem(at: from, to: to)
        } catch {
            throw MemoryWriteError.rejected(reason: "\(topic)'s body could not be restored — \(error.localizedDescription)")
        }
        try AgentMemoryIndex.render(facts: updated, tail: tail)
            .write(to: indexURL(for: agentID), atomically: true, encoding: .utf8)
    }

    /// Removes one archived body for good — the only way out of the archive
    /// other than ``restoreFact(agentID:topic:)``. `topic` is the id
    /// ``archivedTopics(agentID:)`` gave it. Touches neither the index nor
    /// `memory/`: a live fact still leaves the index only by being archived.
    /// No archived body under that name, or a removal the file system refuses,
    /// throws naming the topic, having removed nothing.
    func deleteArchivedFact(agentID: String, topic: String) throws {
        let fm = FileManager.default
        let url = archiveDir(for: agentID).appending(path: "\(topic).md")
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw MemoryWriteError.rejected(reason: "\(topic) names no archived fact — it may have been deleted already.")
        }
        do {
            try fm.removeItem(at: url)
        } catch {
            throw MemoryWriteError.rejected(reason: "\(topic)'s body could not be deleted — \(error.localizedDescription)")
        }
    }

    /// Corrects one fact where it stands: the Memory tab's edit control. The
    /// line keeps its topic, its position and its `supersedes`; its headline
    /// is read from `content` the way an approval reads one, and its date is
    /// today. Not a budget write — the index does not grow, and nothing is
    /// displaced. Same write order as ``removeFact(agentID:topic:keepingBody:)``:
    /// the body first, so a refused body write leaves the index as it was. A
    /// topic with no index line, or text with no headline, is refused before
    /// anything is written.
    func rewriteFact(agentID: String, topic: String, content: String) throws {
        migrateIfNeeded(agentID: agentID)
        let existing = readIndex(agentID: agentID) ?? ""
        var facts = AgentMemoryIndex.parse(existing)
        guard !topic.isEmpty, let i = facts.firstIndex(where: { $0.topic == topic }) else {
            throw MemoryWriteError.rejected(reason: "\(topic) names no fact in this agent's memory index — it may have been archived already.")
        }
        guard var fact = AgentMemoryIndex.fact(from: content, date: AgentMemoryIndex.today(), taken: []) else {
            throw MemoryWriteError.rejected(reason: "the corrected memory has no text to record.")
        }
        fact.topic = topic
        fact.supersedes = facts[i].supersedes
        facts[i] = fact

        try FileManager.default.createDirectory(at: topicsDir(for: agentID), withIntermediateDirectories: true)
        try AgentMemoryIndex.renderBody(fact: fact, content: content)
            .write(to: topicsDir(for: agentID).appending(path: "\(topic).md"), atomically: true, encoding: .utf8)
        try AgentMemoryIndex.render(facts: facts, tail: AgentMemoryIndex.tail(of: existing))
            .write(to: indexURL(for: agentID), atomically: true, encoding: .utf8)
    }

    /// Records a fact a person typed into the Memory tab: the same write an
    /// approved `.add` proposal makes, reached without a proposal — the person
    /// typing it is the approver. Same budget, same topic naming, same write
    /// order; a full index, a covering line or text with no headline throws
    /// ``MemoryWriteError/rejected(reason:)`` having written nothing.
    func addFact(agentID: String, content: String) throws {
        try appendToMemory(agentID: agentID, content: content)
    }

    /// The index line an archived body stands for: its file name as the topic,
    /// the date its front matter records (or none), and the headline an
    /// approval of the text below the front matter would have given it.
    private func restoredFact(topic: String, body: String) throws -> AgentMemoryIndex.Fact {
        let (front, text) = Self.splitFrontMatter(body)
        let date = front.first { $0.hasPrefix("date: ") }.map { String($0.dropFirst("date: ".count)) } ?? ""
        guard var fact = AgentMemoryIndex.fact(from: text, date: date, taken: []) else {
            throw MemoryWriteError.rejected(reason: "\(topic) has no text to restore.")
        }
        fact.topic = topic
        fact.supersedes = nil
        return fact
    }

    /// `facts` with `fact` appended, or the budget's refusal. A restore only
    /// adds: an outcome that would displace a line is refused, naming it.
    private func restoredIndex(adding fact: AgentMemoryIndex.Fact, to facts: [AgentMemoryIndex.Fact]) throws -> [AgentMemoryIndex.Fact] {
        switch AgentMemoryIndex.apply(fact: fact, to: facts) {
        case .rejected(let reason):
            throw MemoryWriteError.rejected(reason: reason)
        case .replaced(_, let displaced):
            throw MemoryWriteError.rejected(
                reason: "restoring \(fact.topic) would replace [\(displaced)] in the index. Archive that fact first to restore this one.")
        case .appended(let out):
            return out
        }
    }

    /// The front-matter lines `AgentMemoryIndex.renderBody` wrote, and the text
    /// below them. A body with no front matter is all text.
    static func splitFrontMatter(_ body: String) -> (front: [String], text: String) {
        let lines = body.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return ([], body) }
        return (Array(lines[1..<close]), lines[(close + 1)...].joined(separator: "\n"))
    }

    /// The agent's memory index, as it sits on disk — one line per fact.
    ///
    /// Reading is a first touch, so a legacy `memory.md` is migrated here rather
    /// than waiting for the next approved write: until it is split, the whole of
    /// it would still ride into the system prompt.
    func currentMemory(agentID: String) -> String {
        migrateIfNeeded(agentID: agentID)
        return readIndex(agentID: agentID) ?? ""
    }

    /// Every topic body the agent has, oldest file name first — the second tier,
    /// which is read on demand rather than injected.
    func memoryTopics(agentID: String) -> [MemoryTopic] {
        migrateIfNeeded(agentID: agentID)
        let dir = topicsDir(for: agentID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else {
            return []
        }
        return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: dir.appending(path: name)) else { return nil }
            return MemoryTopic(id: String(name.dropLast(3)), body: String(decoding: data, as: UTF8.self))
        }
    }

    /// Every body `archiveBody` has moved out of the index — kept on disk, no
    /// longer injected or recalled, and until now visible only in Finder.
    ///
    /// Same read as ``memoryTopics(agentID:)``, over `memory/archive/` instead
    /// of `memory/`, and with no migration touch: an agent that has never had a
    /// fact archived has no archive directory at all, which is a legitimate
    /// empty list rather than something to create.
    func archivedTopics(agentID: String) -> [MemoryTopic] {
        let dir = archiveDir(for: agentID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)) else {
            return []
        }
        return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: dir.appending(path: name)) else { return nil }
            return MemoryTopic(id: String(name.dropLast(3)), body: String(decoding: data, as: UTF8.self))
        }
    }

    /// How many topic bodies one recall hands back.
    ///
    /// The same `topK` the knowledge half of the same tool call asks
    /// `KnowledgeIndex.search` for, and for the same reason: a tool result is
    /// context too, and the topic directory is not bounded the way the index is —
    /// a displaced fact keeps its body, and a migration writes one per block of a
    /// legacy `memory.md`, so bodies accumulate well past ``AgentMemoryIndex/maxFacts``.
    /// Without a cap the single-word fallback answers a common word with the whole
    /// store, which is the unbounded always-injected memory the two tiers exist to
    /// prevent, arriving through a tool result instead of the system prompt.
    static let maxRecalledTopics = 5

    /// Topic bodies matching `query`, or an empty string when none do.
    ///
    /// Same shape as `KnowledgeRecallService.recall`: every word has to match, and
    /// only if nothing does is a single-word match good enough. The topic name is
    /// searched alongside the body so recalling a fact by the slug the index
    /// prints works.
    ///
    /// At most ``maxRecalledTopics`` bodies come back, all-words hits ahead of
    /// single-word ones — which is what the fallback being reached only when
    /// nothing matched every word already means: a topic answering the whole query
    /// is never squeezed out by one answering a word of it. Within a group today's
    /// file-name order stands. A body that matched and was withheld is said rather
    /// than dropped, in the voice ``injectedMemory(agentID:)`` uses for the facts
    /// it leaves out; a body that is shown is shown whole.
    func recallMemory(agentID: String, query: String) -> String {
        let words = AgentMemoryIndex.normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return "" }
        let topics = memoryTopics(agentID: agentID)
        guard !topics.isEmpty else { return "" }

        let haystack = topics.map { ($0, AgentMemoryIndex.normalize("\($0.id) \($0.body)")) }
        var hits = haystack.filter { _, text in words.allSatisfy { text.contains($0) } }
        if hits.isEmpty {
            hits = haystack.filter { _, text in words.contains { text.contains($0) } }
        }

        let shown = hits.prefix(Self.maxRecalledTopics)
        var out = shown.map { $0.0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n---\n\n")
        let withheld = hits.count - shown.count
        if withheld > 0 {
            let said = withheld == 1 ? "topic matched and is" : "topics matched and are"
            out += "\n\n(\(withheld) further \(said) not shown here — recall again with a narrower query.)"
        }
        return out
    }

    func sharedContext() -> String {
        guard let data = try? Data(contentsOf: project.contextURL) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// What the fleet has learned about working in this repo —
    /// `.kiteloop/coordinator-knowledge.md`.
    ///
    /// Distinct from the shared context beside it: the context is what a human
    /// tells the agents, this is what the runs told themselves.
    /// `RunKnowledgeDistiller` merges a finished run's learnings into it, and
    /// the Planner, the worker and the reviewer all read it — so it shapes every
    /// run without ever having been visible in the app.
    ///
    /// It rots exactly because of that. On 2026-08-20 it was still briefing
    /// every worker that "the unit suite has 6 known-failing tests" (the suite
    /// was green, 4178 passing) and that "the merge-verify uses `build`, not
    /// `test`" (it had been changed to `build-for-testing` that morning). A
    /// memory nobody can see is a memory nobody can correct.
    /// The same file `RunKnowledgeDistiller.knowledgeURL` names, resolved from
    /// the project rather than through it: that helper is main-actor isolated
    /// and this is an actor, and the path is one join.
    private var fleetKnowledgeURL: URL {
        project.kiteloopDirURL.appending(path: CoordinatorKnowledge.fileName)
    }

    func fleetKnowledge() -> String {
        guard let data = try? Data(contentsOf: fleetKnowledgeURL) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Same all-or-nothing contract as `saveSharedContext`: this text is read
    /// into every run, and the editor holds the only copy of an edit.
    func saveFleetKnowledge(_ content: String) throws {
        try project.ensureKiteloopDirectory()
        try content.write(to: fleetKnowledgeURL, atomically: true, encoding: .utf8)
    }

    /// Writes the project context, and rethrows when the write does not land.
    ///
    /// This file rides into every agent's system prompt, so a save that failed —
    /// a `.kiteloop` directory that is missing or not writable — must not read
    /// like one that worked: the caller has the only copy of the edit. The write
    /// is atomic, so a refusal leaves what is on disk exactly as it was, the same
    /// all-or-nothing shape ``approve(proposalID:)`` has.
    func saveSharedContext(_ content: String) throws {
        try content.write(to: project.contextURL, atomically: true, encoding: .utf8)
    }

    func composeSystemContext(agent: Agent) async -> String {
        await composeSystemContext(agent: agent, skillRegistry: nil)
    }

    func composeSystemContext(agent: Agent, skillRegistry: SkillRegistry?) async -> String {
        var parts: [String] = []
        parts.append(agent.systemPrompt)

        let instructions = loadClaudeMDChain(projectRoot: project.rootURL)
        if !instructions.isEmpty {
            parts.append("# Project Instructions\n\n\(instructions)")
        }

        let context = sharedContext()
        if !context.isEmpty {
            parts.append("# Project Context\n\n\(context)")
        }

        if let recallService = knowledgeRecallService {
            let identity = await recallService.identityTier(for: agent.id)
            if !identity.isEmpty {
                parts.append("# Agent Identity\n\n\(identity)")
            }
            let index = await recallService.indexTier(for: agent.id)
            if !index.isEmpty {
                parts.append("# Available Knowledge\n\n\(index)")
            }
        } else if let knowledge = knowledgeProvider?.knowledgeContent(for: agent.id) {
            parts.append("# Domain Knowledge\n\n\(knowledge)")
        }

        let memory = injectedMemory(agentID: agent.id)
        if !memory.isEmpty {
            parts.append("# Your Memory\n\n\(memory)")
        }

        if let registry = skillRegistry, !agent.skills.isEmpty {
            var skillParts: [String] = []
            for skillName in agent.skills {
                if let skill = await registry.skill(named: skillName) {
                    skillParts.append("## \(skill.name)\n\n\(skill.body)")
                }
            }
            if !skillParts.isEmpty {
                parts.append("# Active Skills\n\n\(skillParts.joined(separator: "\n\n---\n\n"))")
            }
        }

        return parts.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Memory tiers

    private func indexURL(for agentID: String) -> URL {
        project.agentDir(for: agentID).appending(path: "memory.md")
    }

    /// The index as text, or nil when there is no file. Lossy, so one bad byte
    /// costs only itself — a strict decode read the whole index as empty and
    /// the next write replaced every fact in it.
    private func readIndex(agentID: String) -> String? {
        guard let data = try? Data(contentsOf: indexURL(for: agentID)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func topicsDir(for agentID: String) -> URL {
        project.agentDir(for: agentID).appending(path: "memory")
    }

    /// What actually rides into the system prompt: the index, bounded by the cap
    /// whatever the file on disk says.
    ///
    /// The write path already refuses to grow the index past ``AgentMemoryIndex/maxFacts``,
    /// but the file is plain Markdown a human can edit, and the point of the cap
    /// is the size of the prompt. So the bound is applied again on the way in —
    /// and what it left out is stated rather than quietly dropped, since a fact
    /// the agent is not being shown is one it will not act on.
    func injectedMemory(agentID: String) -> String {
        let text = currentMemory(agentID: agentID)
        guard !text.isEmpty else { return "" }
        let facts = AgentMemoryIndex.parse(text)
        guard !facts.isEmpty else { return "" }

        let shown = Array(facts.suffix(AgentMemoryIndex.maxFacts))
        var out = AgentMemoryIndex.render(facts: shown)
        let hidden = facts.count - shown.count
        if hidden > 0 {
            out += "\n(\(hidden) older fact\(hidden == 1 ? " is" : "s are") in the index file but not shown"
                + " here — recall_knowledge reads their topics.)\n"
        }
        return out
    }

    /// Records an approved proposal as one fact: a line in the index, and its
    /// full text as a topic body.
    ///
    /// Throws ``MemoryWriteError/rejected(reason:)`` when the budget refuses the
    /// write. It never appends past the cap and never shortens the index to make
    /// room — see ``AgentMemoryIndex/apply(fact:to:)`` for the rules.
    private func appendToMemory(agentID: String, content: String) throws {
        let fm = FileManager.default
        let dir = project.agentDir(for: agentID)
        if !fm.fileExists(atPath: dir.path(percentEncoded: false)) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        migrateIfNeeded(agentID: agentID)

        let existing = readIndex(agentID: agentID) ?? ""
        let facts = AgentMemoryIndex.parse(existing)
        let tail = AgentMemoryIndex.tail(of: existing)
        var taken = Set(facts.map(\.topic))
        taken.formUnion(existingTopicNames(agentID: agentID))

        guard let fact = AgentMemoryIndex.fact(from: content, date: AgentMemoryIndex.today(), taken: taken) else {
            throw MemoryWriteError.rejected(reason: "the proposed memory has no text to record.")
        }

        let updated: [AgentMemoryIndex.Fact]
        switch AgentMemoryIndex.apply(fact: fact, to: facts) {
        case .rejected(let reason):
            throw MemoryWriteError.rejected(reason: reason)
        case .appended(let out):
            updated = out
        case .replaced(let out, _):
            // The displaced fact keeps its body file: its line is gone from the
            // index, but what it said is still recallable, and deleting it here
            // would make a replacement the one lossy operation in the store.
            updated = out
        }

        try fm.createDirectory(at: topicsDir(for: agentID), withIntermediateDirectories: true)
        try AgentMemoryIndex.renderBody(fact: fact, content: content)
            .write(to: topicsDir(for: agentID).appending(path: "\(fact.topic).md"), atomically: true, encoding: .utf8)
        try AgentMemoryIndex.render(facts: updated, tail: tail)
            .write(to: indexURL(for: agentID), atomically: true, encoding: .utf8)
    }

    /// Replaces the facts named by `topics` with one fact saying `content`.
    ///
    /// The merged line takes the earliest source's position in the index, so a
    /// consolidation does not silently reorder what the agent reads; the other
    /// sources' lines go. Their bodies are moved to `memory/archive/` rather
    /// than deleted — the merged text is a summary, and what it was summarised
    /// from is the only way to check it.
    ///
    /// `topics` is read as the set of facts it names: a name repeated in it says
    /// nothing the first mention did not, so it counts once towards the two a
    /// merge needs and is removed once.
    private func mergeFacts(agentID: String, topics: [String], into content: String) throws {
        migrateIfNeeded(agentID: agentID)
        let existing = readIndex(agentID: agentID) ?? ""
        var facts = AgentMemoryIndex.parse(existing)
        let tail = AgentMemoryIndex.tail(of: existing)

        // A topic named twice is one fact, not two: counted raw it would pass the
        // guard below, and resolved raw it would put the same position in the
        // removal list — which deletes the merged line this write just put there.
        var seen = Set<String>()
        let named = topics.filter { seen.insert($0).inserted }

        guard named.count >= 2 else {
            throw MemoryWriteError.rejected(reason: "a merge has to name at least two facts; this one names \(named.count).")
        }
        let positions = named.map { topic in facts.firstIndex { $0.topic == topic } }
        if let missing = zip(named, positions).first(where: { $0.1 == nil })?.0 {
            throw MemoryWriteError.rejected(reason: "\(missing) names no fact in the index — it may have been merged or removed already.")
        }
        let indices = positions.compactMap { $0 }.sorted()

        var taken = Set(facts.map(\.topic))
        taken.formUnion(existingTopicNames(agentID: agentID))
        taken.formUnion(archivedTopicNames(agentID: agentID))
        guard let merged = AgentMemoryIndex.fact(from: content, date: AgentMemoryIndex.today(), taken: taken) else {
            throw MemoryWriteError.rejected(reason: "the merged memory has no text to record.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: topicsDir(for: agentID), withIntermediateDirectories: true)

        // Source bodies archive before anything else is written: a move the file
        // system refuses must leave the index holding both source facts, not the
        // merged line in place of them with an unarchived body left behind.
        for topic in named { try archiveBody(agentID: agentID, topic: topic) }

        try AgentMemoryIndex.renderBody(fact: merged, content: content)
            .write(to: topicsDir(for: agentID).appending(path: "\(merged.topic).md"), atomically: true, encoding: .utf8)

        facts[indices[0]] = merged
        for i in indices.dropFirst().reversed() { facts.remove(at: i) }
        try AgentMemoryIndex.render(facts: facts, tail: tail)
            .write(to: indexURL(for: agentID), atomically: true, encoding: .utf8)
    }

    /// Takes one fact out of the index. `keepingBody` is the whole difference
    /// between an archival and a deletion: archived, the body moves under
    /// `memory/archive/` and stops being injected and stops being recalled;
    /// deleted, it is gone.
    ///
    /// An index line with no body file, and a body file with no index line, are
    /// both legitimate states — a displaced fact leaves the second — so either
    /// one alone is enough to act on. Neither is a proposal naming a fact that
    /// is not there, which is refused rather than reported as done.
    private func removeFact(agentID: String, topic: String, keepingBody: Bool) throws {
        migrateIfNeeded(agentID: agentID)
        let existing = readIndex(agentID: agentID) ?? ""
        var facts = AgentMemoryIndex.parse(existing)
        let tail = AgentMemoryIndex.tail(of: existing)
        let indexed = facts.contains { $0.topic == topic }
        let bodyURL = topicsDir(for: agentID).appending(path: "\(topic).md")
        let hasBody = FileManager.default.fileExists(atPath: bodyURL.path(percentEncoded: false))

        guard indexed || hasBody else {
            throw MemoryWriteError.rejected(reason: "\(topic) names no fact in this agent's memory — it may have been removed already.")
        }

        // The body moves (or is deleted) before the index is rewritten: a move
        // the file system refuses must leave the index untouched, not remove the
        // fact's line while its body stays exactly where `memoryTopics` finds it.
        if hasBody {
            if keepingBody {
                try archiveBody(agentID: agentID, topic: topic)
            } else {
                try FileManager.default.removeItem(at: bodyURL)
            }
        }
        if indexed {
            facts.removeAll { $0.topic == topic }
            try AgentMemoryIndex.render(facts: facts, tail: tail)
                .write(to: indexURL(for: agentID), atomically: true, encoding: .utf8)
        }
    }

    /// Moves a topic body under `memory/archive/`, where `memoryTopics` and
    /// `recallMemory` no longer see it — both list `memory/` itself and take
    /// only the `.md` files in it, so a subdirectory is already invisible to
    /// them. A body that isn't there has nothing to move, so that case is a
    /// no-op rather than a rejection. A move the file system refuses — the
    /// archive directory cannot be created, or the move itself fails — throws
    /// ``MemoryWriteError/rejected(reason:)`` naming the topic, having moved
    /// nothing: the body is left exactly where it was.
    private func archiveBody(agentID: String, topic: String) throws {
        let fm = FileManager.default
        let from = topicsDir(for: agentID).appending(path: "\(topic).md")
        guard fm.fileExists(atPath: from.path(percentEncoded: false)) else { return }
        let dir = archiveDir(for: agentID)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw MemoryWriteError.rejected(reason: "\(topic)'s body could not be archived — \(error.localizedDescription)")
        }
        var to = dir.appending(path: "\(topic).md")
        var n = 2
        while fm.fileExists(atPath: to.path(percentEncoded: false)) {
            to = dir.appending(path: "\(topic)-\(n).md")
            n += 1
        }
        do {
            try fm.moveItem(at: from, to: to)
        } catch {
            throw MemoryWriteError.rejected(reason: "\(topic)'s body could not be archived — \(error.localizedDescription)")
        }
    }

    private func archiveDir(for agentID: String) -> URL {
        topicsDir(for: agentID).appending(path: "archive")
    }

    /// Names already spoken for in the archive — a merged fact must not be filed
    /// under a slug an archived body would collide with when it is archived too.
    private func archivedTopicNames(agentID: String) -> Set<String> {
        let path = archiveDir(for: agentID).path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return Set(names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
    }

    private func existingTopicNames(agentID: String) -> Set<String> {
        let path = topicsDir(for: agentID).path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return Set(names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) })
    }

    // MARK: - Migration

    /// Splits a pre-index `memory.md` into the two tiers, once.
    ///
    /// The old file was one append-only document, blocks joined by a blank line,
    /// and the whole of it was injected. Each block becomes a topic body; the
    /// newest ``AgentMemoryIndex/maxFacts`` of them also get an index line, and
    /// the rest stay recallable. Nothing is deleted — the original is renamed to
    /// `memory.md.pre-index.bak` (or `-2`, `-3`… if one is already there), so a
    /// migration that read the file wrongly costs nobody their memory.
    private func migrateIfNeeded(agentID: String) {
        let fm = FileManager.default
        let url = indexURL(for: agentID)
        guard let existing = readIndex(agentID: agentID),
              !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !AgentMemoryIndex.isIndex(existing) else { return }

        let dir = project.agentDir(for: agentID)
        var backup = dir.appending(path: "memory.md.pre-index.bak")
        var n = 2
        while fm.fileExists(atPath: backup.path(percentEncoded: false)) {
            backup = dir.appending(path: "memory.md.pre-index-\(n).bak")
            n += 1
        }
        guard (try? fm.moveItem(at: url, to: backup)) != nil else { return }

        let blocks = existing.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var taken = existingTopicNames(agentID: agentID)
        var facts: [AgentMemoryIndex.Fact] = []
        try? fm.createDirectory(at: topicsDir(for: agentID), withIntermediateDirectories: true)
        for block in blocks {
            // No date: the old format recorded none, and the file's mtime is the
            // last append's, not this fact's. An invented date reads as evidence.
            guard var fact = AgentMemoryIndex.fact(from: block, date: "", taken: taken) else { continue }
            // A `supersedes:` written in the old free-form file names nothing in
            // an index that did not exist when it was written.
            fact.supersedes = nil
            taken.insert(fact.topic)
            facts.append(fact)
            try? AgentMemoryIndex.renderBody(fact: fact, content: block)
                .write(to: topicsDir(for: agentID).appending(path: "\(fact.topic).md"), atomically: true, encoding: .utf8)
        }

        // Appends went to the end, so the tail is the most recent thing the agent
        // was told — that is what the index keeps when there are more than fit.
        let indexed = Array(facts.suffix(AgentMemoryIndex.maxFacts))
        try? AgentMemoryIndex.render(facts: indexed).write(to: url, atomically: true, encoding: .utf8)
    }

    private func proposalsDir(for agentID: String) -> URL {
        project.agentDir(for: agentID).appending(path: "proposals")
    }

    /// Writes one proposal's JSON, which is the only record of it there is —
    /// ``loadProposals`` reads these files and nothing else.
    ///
    /// Through ``AtomicFileWriter/write(_:to:)``, as `RunRecordStore` writes its
    /// records: the containing directory is made if it is missing, the bytes are
    /// on the platter before the name is, and a reader never sees half a file. A
    /// failure is thrown rather than swallowed — the proposal is a human's queue
    /// item, and one that exists only in memory is one they will be asked to
    /// approve once and never see again.
    private func persistProposal(_ proposal: MemoryProposal) throws {
        let url = proposalsDir(for: proposal.agentID).appending(path: "\(proposal.id).json")
        let data: Data
        do {
            data = try encoder.encode(proposal)
        } catch {
            throw MemoryWriteError.rejected(reason: "the proposal could not be encoded — \(error.localizedDescription)")
        }
        do {
            try AtomicFileWriter.write(data, to: url)
        } catch {
            throw MemoryWriteError.rejected(
                reason: "the proposal could not be written to \(url.path(percentEncoded: false)) — \(error)."
            )
        }
    }

    private static func loadProposals(project: KiteloopProject, decoder: JSONDecoder) -> [MemoryProposal] {
        let fm = FileManager.default
        let agentsPath = project.agentsURL.path(percentEncoded: false)
        guard let agentDirs = try? fm.contentsOfDirectory(atPath: agentsPath) else { return [] }

        var proposals: [MemoryProposal] = []
        for dir in agentDirs {
            let proposalsPath = project.agentDir(for: dir).appending(path: "proposals").path(percentEncoded: false)
            guard let files = try? fm.contentsOfDirectory(atPath: proposalsPath) else { continue }
            for file in files where file.hasSuffix(".json") {
                let url = project.agentDir(for: dir).appending(path: "proposals/\(file)")
                if let data = try? Data(contentsOf: url),
                   let proposal = try? decoder.decode(MemoryProposal.self, from: data) {
                    proposals.append(proposal)
                }
            }
        }
        return proposals
    }

    private func loadClaudeMDChain(projectRoot: URL) -> String {
        let home = KiteloopHome.url
        var paths: [URL] = []

        // Only include global ~/.claude/CLAUDE.md for non-home workspaces
        // Home workspace agents get context from knowledge packages, not personal CLAUDE.md
        let isHome = projectRoot.path(percentEncoded: false) == KiteloopProject.homeWorkspace.rootURL.path(percentEncoded: false)
        if !isHome {
            paths.append(home.appending(path: ".claude/CLAUDE.md"))
        }

        paths.append(projectRoot.appending(path: "CLAUDE.md"))
        paths.append(projectRoot.appending(path: ".claude/CLAUDE.md"))

        var sections: [String] = []
        var seen = Set<String>()
        for path in paths {
            guard let data = try? Data(contentsOf: path) else { continue }
            let content = String(decoding: data, as: UTF8.self)
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !seen.contains(content) else { continue }
            seen.insert(content)
            sections.append(content)
        }
        return sections.joined(separator: "\n\n")
    }
}
