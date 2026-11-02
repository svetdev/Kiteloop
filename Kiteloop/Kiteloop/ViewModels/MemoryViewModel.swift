import Foundation
import KiteloopCore

@Observable
@MainActor
class MemoryViewModel {
    private let memoryManager: MemoryManager
    private(set) var pendingProposals: [MemoryProposal] = []
    /// The index tier — one line per fact, and what the agent is actually shown.
    private(set) var currentMemory: String = ""
    /// `currentMemory`, parsed into facts — what the archive control in the
    /// Memory tab iterates. Anything `AgentMemoryIndex.parse` does not recognise
    /// (a human's own text below the fact list) has no row here and stays only
    /// in `currentMemory`.
    private(set) var memoryFacts: [AgentMemoryIndex.Fact] = []
    /// The body tier — read on demand by the agent, browsable here.
    private(set) var memoryTopics: [MemoryTopic] = []
    /// Bodies archived out of the index — kept on disk, no longer injected or
    /// recalled, browsable here and nowhere else in the app.
    private(set) var archivedTopics: [MemoryTopic] = []
    private(set) var sharedContext: String = ""
    /// What the runs have learned about this repo, as the distiller left it.
    private(set) var fleetKnowledge: String = ""
    /// Why the last write did not reach disk — a refused approval, or a project
    /// context the file system would not take. Saying nothing would look exactly
    /// like a write that worked, and the text the human wrote is still only in
    /// the editor.
    private(set) var lastWriteError: String?
    /// The project-context edit not yet on disk — nil when there is none.
    ///
    /// Held here rather than in the editor's view state: the Memory tab rebuilds
    /// the detail pane on every selection move, and an edit kept in the view
    /// went with it, silently. `refresh()` never touches it, and only a save
    /// that landed clears it.
    var sharedContextDraft: String? {
        didSet { sharedContextBaseline = Self.baseline(sharedContextBaseline, from: oldValue, to: sharedContextDraft, onDisk: sharedContext) }
    }
    /// The fleet-knowledge edit not yet on disk, held the same way.
    var fleetKnowledgeDraft: String? {
        didSet { fleetKnowledgeBaseline = Self.baseline(fleetKnowledgeBaseline, from: oldValue, to: fleetKnowledgeDraft, onDisk: fleetKnowledge) }
    }
    /// The file's text when the draft beside it began — what a save checks the
    /// file against, so it does not write over what a run or anyone else put
    /// there since. Nil while there is no draft.
    @ObservationIgnored private var sharedContextBaseline: String?
    @ObservationIgnored private var fleetKnowledgeBaseline: String?

    static let changedOnDiskMessage =
        "The file changed on disk since you started editing. Revert to see the new text, or Save again to replace it."

    /// The baseline after a draft moves: taken from the file as shown when the
    /// draft begins, kept while it is edited, dropped with it.
    private static func baseline(_ current: String?, from old: String?, to new: String?, onDisk: String) -> String? {
        guard new != nil else { return nil }
        return old == nil ? onDisk : current
    }

    /// A fact correction open in the Memory tab: the agent it was opened
    /// under, the fact's topic and the text being typed.
    struct FactEdit: Equatable {
        let agentID: String
        let topic: String
        var text: String
    }

    /// The fact correction open, whichever agent's page is showing — nil when
    /// there is none.
    ///
    /// Held here, with the agent it belongs to, rather than as a topic in the
    /// view: a topic is a slug of the fact's text, so two agents that learned
    /// the same thing share one, and an editor keyed by topic alone followed
    /// the selection to the other agent and saved into its fact.
    private(set) var factEdit: FactEdit?

    /// The open fact correction, if it belongs to the selected agent's page.
    var factEditForSelectedAgent: FactEdit? {
        guard let edit = factEdit, edit.agentID == selectedAgentID else { return nil }
        return edit
    }

    var hasUnsavedSharedContext: Bool {
        sharedContextDraft.map { $0 != sharedContext } ?? false
    }

    var hasUnsavedFleetKnowledge: Bool {
        fleetKnowledgeDraft.map { $0 != fleetKnowledge } ?? false
    }
    /// The selection the page is showing — an agent's id, or one of the two
    /// shared rows' tags.
    ///
    /// Moving it clears `lastWriteError`: the banner belongs to the selection
    /// the failed write happened under, and both shared editors read it to
    /// decide the edit is still unsaved. Left standing it reported one agent's
    /// refused archive under the next page you opened, and kept that page's
    /// Save button live. Staying on the page keeps the failure — only a move
    /// clears it.
    var selectedAgentID: String? {
        get { storedSelectedAgentID }
        set {
            guard newValue != storedSelectedAgentID else { return }
            storedSelectedAgentID = newValue
            lastWriteError = nil
        }
    }

    private var storedSelectedAgentID: String?

    /// The pending proposals belonging to the selected agent — what the Memory
    /// page shows under the heading "Memory index: <agent>".
    ///
    /// The page used to list `pendingProposals` whole, so Approve on a card
    /// sitting under one agent's index wrote a fact into another agent's
    /// memory. Empty when no agent is selected, which is also true of the
    /// shared Project Context and fleet-knowledge selections: neither has
    /// proposals of its own. `pendingProposals` stays project-wide — the
    /// sidebar's Pending section and the Memory row's badge count the whole
    /// project on purpose.
    var proposalsForSelectedAgent: [MemoryProposal] {
        guard let agentID = selectedAgentID else { return [] }
        return pendingProposals.filter { $0.agentID == agentID }
    }

    /// One entry per agent with facts waiting — what the sidebar's Pending
    /// section lists.
    struct PendingAgent: Identifiable, Equatable {
        /// The agent the facts were proposed for, and the row's selection tag.
        let agentID: String
        /// How many of that agent's facts are waiting.
        let count: Int

        var id: String { agentID }
    }

    /// `pendingProposals` collapsed to one entry per agent, ordered by agent id
    /// so the list does not reshuffle between refreshes.
    ///
    /// The section drew one row per proposal, so an agent that had filed three
    /// facts looked like three agents — three identical labels carrying the
    /// same selection tag. `pendingProposals` stays whole: the section header's
    /// `Pending (n)` and the sidebar's Memory badge count the project.
    var pendingAgents: [PendingAgent] {
        var counts: [String: Int] = [:]
        for proposal in pendingProposals {
            counts[proposal.agentID, default: 0] += 1
        }
        return counts.keys.sorted().map { PendingAgent(agentID: $0, count: counts[$0] ?? 0) }
    }

    // MARK: - Librarian

    /// The consolidation pass, once a project has wired one. Nil in a context
    /// that has no runtime to call — tests, and any embedding that only browses.
    private var librarian: MemoryLibrarianPass?
    /// The team the pass reads the memory of, supplied fresh at each run so it
    /// sees agents hired since the session started.
    private var agentsForPass: (@MainActor () -> [Agent])?
    private(set) var isRunningLibrarian = false
    /// What the last pass said — including "nothing to consolidate", which is an
    /// outcome and not a silence.
    private(set) var lastLibrarianOutcome: MemoryLibrarian.Outcome?
    /// When the corpus was last consolidated, from the record on disk.
    private(set) var lastLibrarianPassAt: Date?
    private(set) var isLibrarianDue = false

    var canRunLibrarian: Bool { librarian != nil }

    init(memoryManager: MemoryManager) {
        self.memoryManager = memoryManager
    }

    /// Give the tab a librarian to run. Separate from `init` because the pass
    /// needs a runtime and a project, and a view model that only browses memory
    /// should not have to supply either.
    func configureLibrarian(_ pass: MemoryLibrarianPass, agents: @escaping @MainActor () -> [Agent]) {
        librarian = pass
        agentsForPass = agents
        lastLibrarianPassAt = pass.state?.lastPassAt
        isLibrarianDue = pass.isDue()
    }

    /// Run one pass now. The button is always live — the due badge is a prompt,
    /// not a lock — and a pass already in flight is not started twice.
    func runLibrarian() async {
        guard let librarian, let agentsForPass, !isRunningLibrarian else { return }
        isRunningLibrarian = true
        defer { isRunningLibrarian = false }
        let outcome = await librarian.run(agents: agentsForPass())
        lastLibrarianOutcome = outcome
        lastLibrarianPassAt = librarian.state?.lastPassAt
        isLibrarianDue = librarian.isDue()
        await refresh()
    }

    /// Just the proposal list, for a caller that is not looking at the tab.
    ///
    /// The sidebar's Memory badge is the whole signal that a proposal is
    /// waiting, and it reads this count — so the window's tick re-asks here
    /// rather than through `refresh()`, which would re-read the selected
    /// agent's memory, its topics and both shared files every couple of
    /// seconds for a number nobody is browsing. `pendingProposals()` filters an
    /// array the manager already holds, so this costs one actor hop and no
    /// disk read.
    func refreshPendingProposals() async {
        pendingProposals = await memoryManager.pendingProposals()
    }

    func refresh() async {
        pendingProposals = await memoryManager.pendingProposals()
        if let agentID = selectedAgentID {
            currentMemory = await memoryManager.currentMemory(agentID: agentID)
            memoryFacts = AgentMemoryIndex.parse(currentMemory)
            memoryTopics = await memoryManager.memoryTopics(agentID: agentID)
            archivedTopics = await memoryManager.archivedTopics(agentID: agentID)
        }
        sharedContext = await memoryManager.sharedContext()
        fleetKnowledge = await memoryManager.fleetKnowledge()
    }

    func approve(_ proposal: MemoryProposal) async {
        await write { try await memoryManager.approve(proposalID: proposal.id) }
    }

    /// Through the same gate as approving: the status write can fail the same way
    /// — `MemoryManager` writes the proposal JSON before it marks it rejected —
    /// and a swallowed failure leaves the card sitting in the pending list, which
    /// reads exactly like a rejection that worked and a list that has not
    /// refreshed.
    func reject(_ proposal: MemoryProposal) async {
        await write { try await memoryManager.reject(proposalID: proposal.id) }
    }

    /// Whether the edit landed — the card keeps its editor open, and the
    /// human's rewrite in it, on a refusal.
    func edit(_ proposal: MemoryProposal, newContent: String) async -> Bool {
        await write { try await memoryManager.edit(proposalID: proposal.id, newContent: newContent) }
    }

    /// The human control this tab has for a full index: archives one fact,
    /// keeping its body. Through the same gate as `approve`/`reject`, so a
    /// failure — an unknown topic — lands in `lastWriteError` the same way an
    /// index-full refusal already does.
    func archive(topic: String) async {
        guard let agentID = selectedAgentID else { return }
        await write { try await memoryManager.archiveFact(agentID: agentID, topic: topic) }
    }

    /// Puts an archived fact back in the index, through the same gate — a full
    /// index or a covering fact refuses it into `lastWriteError`.
    func restore(topic: String) async {
        guard let agentID = selectedAgentID else { return }
        await write { try await memoryManager.restoreFact(agentID: agentID, topic: topic) }
    }

    /// Deletes an archived fact's body for good, through the same gate — one
    /// already gone refuses into `lastWriteError`.
    func deleteArchived(topic: String) async {
        guard let agentID = selectedAgentID else { return }
        await write { try await memoryManager.deleteArchivedFact(agentID: agentID, topic: topic) }
    }

    /// Corrects one fact in place, through the same gate. Whether it landed —
    /// the row keeps its editor open, and the correction in it, on a refusal.
    func rewrite(topic: String, content: String) async -> Bool {
        guard let agentID = selectedAgentID else { return false }
        return await write { try await memoryManager.rewriteFact(agentID: agentID, topic: topic, content: content) }
    }

    /// Opens a correction of `topic` under the selected agent, starting from
    /// `text`. Replaces any correction already open.
    func openFactEdit(topic: String, text: String) {
        guard let agentID = selectedAgentID else { return }
        factEdit = FactEdit(agentID: agentID, topic: topic, text: text)
    }

    /// Replaces the open correction's text — ignored when none is open.
    func updateFactEdit(text: String) {
        factEdit?.text = text
    }

    func cancelFactEdit() {
        factEdit = nil
    }

    /// Saves the open correction into the agent it was opened under, whichever
    /// page is selected now, through the same gate as `rewrite`. Only a save
    /// that landed closes it; a refusal keeps it, and its text, open.
    func saveFactEdit() async {
        guard let edit = factEdit else { return }
        let landed = await write {
            try await memoryManager.rewriteFact(agentID: edit.agentID, topic: edit.topic, content: edit.text)
        }
        if landed, factEdit == edit { factEdit = nil }
    }

    /// Writes a fact the human typed, through the same gate. Whether it landed
    /// — the editor stays open, and the text in it, on a refusal.
    func add(content: String) async -> Bool {
        guard let agentID = selectedAgentID else { return false }
        return await write { try await memoryManager.addFact(agentID: agentID, content: content) }
    }

    @discardableResult
    private func write(_ body: () async throws -> Void) async -> Bool {
        let landed: Bool
        do {
            try await body()
            lastWriteError = nil
            landed = true
        } catch {
            lastWriteError = error.localizedDescription
            landed = false
        }
        await refresh()
        return landed
    }

    /// Saves the project context, through the same gate an approval goes through.
    ///
    /// The text is not adopted because it was typed: `refresh()` re-reads the
    /// file, so `sharedContext` reports what is on disk either way, and a failed
    /// save leaves `lastWriteError` set and `sharedContextDraft` still holding
    /// the edit. A draft typed on past `content` while the save ran is kept.
    ///
    /// A file that no longer holds the text the draft began from is not written
    /// over: the save refuses into `lastWriteError`, and the baseline moves to
    /// the file as it is now, so a second Save replaces it on purpose.
    func saveSharedContext(_ content: String) async {
        let onDisk = await memoryManager.sharedContext()
        if await refusesOverwrite(baseline: sharedContextBaseline, onDisk: onDisk) {
            sharedContextBaseline = onDisk
            return
        }
        await write { try await memoryManager.saveSharedContext(content) }
        if lastWriteError == nil, sharedContextDraft == content { sharedContextDraft = nil }
    }

    func saveFleetKnowledge(_ content: String) async {
        let onDisk = await memoryManager.fleetKnowledge()
        if await refusesOverwrite(baseline: fleetKnowledgeBaseline, onDisk: onDisk) {
            fleetKnowledgeBaseline = onDisk
            return
        }
        await write { try await memoryManager.saveFleetKnowledge(content) }
        if lastWriteError == nil, fleetKnowledgeDraft == content { fleetKnowledgeDraft = nil }
    }

    /// Whether the file has moved on from the text a draft began from — if so,
    /// says so in `lastWriteError` and re-reads, so Revert shows the new text.
    private func refusesOverwrite(baseline: String?, onDisk: String) async -> Bool {
        guard let baseline, baseline != onDisk else { return false }
        lastWriteError = Self.changedOnDiskMessage
        await refresh()
        return true
    }

    /// Drops the unsaved project-context edit, so the editor shows the file as
    /// it is on disk. Clears `lastWriteError` too: the banner was about the
    /// edit being dropped.
    func revertSharedContext() {
        sharedContextDraft = nil
        lastWriteError = nil
    }

    /// Drops the unsaved fleet-knowledge edit, the same way.
    func revertFleetKnowledge() {
        fleetKnowledgeDraft = nil
        lastWriteError = nil
    }
}
