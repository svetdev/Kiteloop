import SwiftUI

struct MemoryBrowserView: View {
    @Bindable var viewModel: MemoryViewModel
    let agents: [Agent]

    /// The two shared rows' selection tags — not agent ids. Named so a test can
    /// move the selection onto them the way the sidebar does.
    static let projectContextID = "__project_context__"
    static let fleetKnowledgeID = "__fleet_knowledge__"

    /// What the tab calls an agent: the name it was given, as the Agents section
    /// lists it — the id only when no agent on the team has it, as for a
    /// proposal filed for an agent since removed.
    static func agentLabel(for agentID: String, in agents: [Agent]) -> String {
        agents.first { $0.id == agentID }?.name ?? agentID
    }

    /// The fact awaiting confirmation before its archive control fires — nil
    /// keeps the dialog closed.
    @State private var pendingArchiveTopic: String?
    @State private var pendingDeleteArchivedTopic: String?
    /// The fact whose inline editor is open — nil when none is — and the text
    /// in it. Only a rewrite that landed closes it.
    /// Whether the add-fact editor is open, and the text in it. Only an add
    /// that landed closes it.
    @State private var isAddingFact = false
    @State private var newFact: String = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.refresh() }
    }

    private var sidebar: some View {
        List(selection: $viewModel.selectedAgentID) {
            Section("Shared") {
                Label("Project Context", systemImage: "doc.text")
                    .tag(Self.projectContextID)
                // The other half of what every run reads, and the half nothing
                // in the app has ever shown.
                Label("What the fleet has learned", systemImage: "brain")
                    .tag(Self.fleetKnowledgeID)
            }

            if !viewModel.pendingProposals.isEmpty {
                Section("Pending (\(viewModel.pendingProposals.count))") {
                    ForEach(viewModel.pendingAgents) { entry in
                        Label("\(Self.agentLabel(for: entry.agentID, in: agents)) (\(entry.count))", systemImage: "exclamationmark.circle")
                            .tag(entry.agentID)
                    }
                }
            }

            Section("Agents") {
                ForEach(agents) { agent in
                    Label(agent.name, systemImage: "person.circle")
                        .tag(agent.id)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("memory-sidebar")
        .onChange(of: viewModel.selectedAgentID) {
            Task { await viewModel.refresh() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if viewModel.selectedAgentID == Self.projectContextID {
            ProjectContextEditor(viewModel: viewModel)
        } else if viewModel.selectedAgentID == Self.fleetKnowledgeID {
            FleetKnowledgeEditor(viewModel: viewModel)
        } else {
            agentMemoryDetail
        }
    }

    private var agentMemoryDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                librarianSection

                // The selected agent's proposals, not the project's: Approve
                // here writes into the memory whose index is on this page.
                // The sidebar's Pending section still lists them all.
                if !viewModel.proposalsForSelectedAgent.isEmpty {
                    Text("Pending Proposals")
                        .font(.headline)
                    ForEach(viewModel.proposalsForSelectedAgent) { proposal in
                        MemoryProposalView(
                            proposal: proposal,
                            agentName: Self.agentLabel(for: proposal.agentID, in: agents),
                            topics: viewModel.memoryTopics,
                            onApprove: { Task { await viewModel.approve(proposal) } },
                            onReject: { Task { await viewModel.reject(proposal) } },
                            onEdit: { content in await viewModel.edit(proposal, newContent: content) }
                        )
                    }
                    Divider()
                }

                if let agentID = viewModel.selectedAgentID {
                    if let error = viewModel.lastWriteError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("memory-write-error")
                    }

                    Text("Memory index: \(Self.agentLabel(for: agentID, in: agents))")
                        .font(.headline)
                    Text("These lines go into every prompt — at most \(AgentMemoryIndex.maxFacts) of them. The full text of each fact is a topic below, which the agent reads on demand with recall_knowledge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    addFactControl
                    if viewModel.currentMemory.isEmpty {
                        // `PanelEmptyState`'s copy rules in place, not the view:
                        // this sits mid-page under its own heading, with the
                        // topics list below it, so a full-bleed centred block
                        // would displace both.
                        let copy = PanelEmptyState.Copy.memoryFacts
                        VStack(alignment: .leading, spacing: 2) {
                            Text(copy.title)
                                .foregroundStyle(.secondary)
                            Text(copy.message)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("memory-empty-state")
                    } else if !viewModel.memoryFacts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.memoryFacts, id: \.topic) { fact in
                                factRow(fact)
                            }
                        }
                    } else {
                        // Whatever `parse` did not recognise — a raw index that
                        // is not yet split into lines it can read.
                        Text(viewModel.currentMemory)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }

                    if !viewModel.memoryTopics.isEmpty {
                        Divider()
                        Text("Topics (\(viewModel.memoryTopics.count))")
                            .font(.headline)
                            .accessibilityIdentifier("memory-topics-header")
                        ForEach(viewModel.memoryTopics) { topic in
                            topicRow(topic)
                        }
                    }

                    if !viewModel.archivedTopics.isEmpty {
                        Divider()
                        Text("Archived (\(viewModel.archivedTopics.count))")
                            .font(.headline)
                            .accessibilityIdentifier("memory-archived-header")
                        Text("Kept on disk, no longer injected into prompts or returned by recall_knowledge.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(viewModel.archivedTopics) { topic in
                            DisclosureGroup(topic.id) {
                                Text(topic.body)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Restore") {
                                    Task { await viewModel.restore(topic: topic.id) }
                                }
                                .help("Put this fact back in the memory index — injected and recalled again.")
                                .accessibilityIdentifier("memory-restore-fact-\(topic.id)")
                                Button("Delete", role: .destructive) {
                                    pendingDeleteArchivedTopic = topic.id
                                }
                                .help("Remove this archived fact from disk permanently. It cannot be restored.")
                                .accessibilityIdentifier("memory-delete-archived-fact-\(topic.id)")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Select an Agent", systemImage: "brain", description: Text("Choose an agent to view their memory, or edit Project Context"))
                }
            }
            .padding()
        }
        .accessibilityIdentifier("memory-detail")
        .confirmationDialog(
            "Archive this fact?",
            isPresented: Binding(
                get: { pendingArchiveTopic != nil },
                set: { if !$0 { pendingArchiveTopic = nil } }
            )
        ) {
            Button("Archive", role: .destructive) {
                guard let topic = pendingArchiveTopic else { return }
                pendingArchiveTopic = nil
                Task { await viewModel.archive(topic: topic) }
            }
            Button("Cancel", role: .cancel) { pendingArchiveTopic = nil }
        } message: {
            Text("Takes this fact out of the memory index. Its full text is kept — moved to the agent's memory archive, no longer injected or recalled.")
        }
        .confirmationDialog(
            "Delete this archived fact?",
            isPresented: Binding(
                get: { pendingDeleteArchivedTopic != nil },
                set: { if !$0 { pendingDeleteArchivedTopic = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let topic = pendingDeleteArchivedTopic else { return }
                pendingDeleteArchivedTopic = nil
                Task { await viewModel.deleteArchived(topic: topic) }
            }
            Button("Cancel", role: .cancel) { pendingDeleteArchivedTopic = nil }
        } message: {
            Text("Its text is removed from disk permanently and cannot be restored.")
        }
    }

    /// One line of the index, with the controls that correct and archive it.
    /// The rendered text is `fact.rendered()` — the same line
    /// `Text(viewModel.currentMemory)` prints today, just one to a row instead
    /// of all of them in one block.
    @ViewBuilder
    private func factRow(_ fact: AgentMemoryIndex.Fact) -> some View {
        if let edit = viewModel.factEditForSelectedAgent, edit.topic == fact.topic {
            factEditor(fact)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Text(fact.rendered())
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    viewModel.openFactEdit(topic: fact.topic, text: currentText(of: fact))
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Correct this fact — rewrites its text in place, same topic.")
                .accessibilityIdentifier("memory-edit-fact-\(fact.topic)")
                Button {
                    pendingArchiveTopic = fact.topic
                } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.borderless)
                .help("Archive this fact — kept on disk, no longer injected or recalled.")
                .accessibilityIdentifier("memory-archive-fact-\(fact.topic)")
            }
        }
    }

    /// One topic body, with the control that archives it. A body whose line
    /// has left the index — a fact a later approval superseded — is marked, since
    /// recall still finds it and this row is the only place it can be archived.
    private func topicRow(_ topic: MemoryTopic) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DisclosureGroup {
                Text(topic.body)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 6) {
                    Text(topic.id)
                    if !viewModel.memoryFacts.contains(where: { $0.topic == topic.id }) {
                        Text("not in index")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("memory-topic-not-indexed-\(topic.id)")
                    }
                }
            }
            Button {
                pendingArchiveTopic = topic.id
            } label: {
                Image(systemName: "archivebox")
            }
            .buttonStyle(.borderless)
            .help("Archive this fact — kept on disk, no longer injected or recalled.")
            .accessibilityIdentifier("memory-archive-topic-\(topic.id)")
        }
    }

    /// The inline editor a fact row opens into. A refused save leaves it open
    /// with the text still in it; the reason is in the write-error label above.
    private func factEditor(_ fact: AgentMemoryIndex.Fact) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Binding(
                get: { viewModel.factEditForSelectedAgent?.text ?? "" },
                set: { viewModel.updateFactEdit(text: $0) }
            ))
                .font(.body.monospaced())
                .frame(minHeight: 80)
                .border(Color.secondary.opacity(0.3))
                .accessibilityIdentifier("memory-fact-editor-\(fact.topic)")
            HStack {
                Button("Save") {
                    Task { await viewModel.saveFactEdit() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("memory-save-fact-\(fact.topic)")
                Button("Cancel") { viewModel.cancelFactEdit() }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// The control that writes a new fact by hand: a button, or the editor it
    /// opens into. Same shape as `factEditor`, and the same rule — a refused
    /// save leaves it open with the text still in it.
    @ViewBuilder
    private var addFactControl: some View {
        if isAddingFact {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $newFact)
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
                    .border(Color.secondary.opacity(0.3))
                    .accessibilityIdentifier("memory-add-fact-editor")
                HStack {
                    Button("Save") {
                        Task {
                            if await viewModel.add(content: newFact) { isAddingFact = false }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("memory-add-fact-save")
                    Button("Cancel") { isAddingFact = false }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            Button {
                newFact = ""
                isAddingFact = true
            } label: {
                Label("Add fact", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Write a fact into this agent's memory yourself — same budget an approved proposal goes through.")
            .accessibilityIdentifier("memory-add-fact")
        }
    }

    /// The fact's full text as its body file holds it, front matter removed —
    /// the headline alone when it has no body.
    private func currentText(of fact: AgentMemoryIndex.Fact) -> String {
        guard let topic = viewModel.memoryTopics.first(where: { $0.id == fact.topic }) else { return fact.headline }
        return MemoryManager.splitFrontMatter(topic.body).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The librarian control: a consolidation pass over every agent's memory,
    /// which proposes merges and removals and applies none of them. Everything it
    /// finds arrives in the pending list above, through the same gate as an
    /// agent's own proposal.
    @ViewBuilder
    private var librarianSection: some View {
        if viewModel.canRunLibrarian {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("Librarian")
                        .font(.headline)
                    if viewModel.isLibrarianDue {
                        Text("due")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.tint.opacity(0.15))
                            .clipShape(Capsule())
                            .accessibilityIdentifier("librarian-due-badge")
                    }
                    Spacer()
                    if viewModel.isRunningLibrarian {
                        ProgressView().controlSize(.small)
                    }
                    Button("Run librarian") { Task { await viewModel.runLibrarian() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isRunningLibrarian)
                        .accessibilityIdentifier("run-librarian-button")
                }

                Text("Reads every agent's memory and proposes merges, deletions and archival. It changes nothing on its own — each proposal is approved or rejected here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let outcome = viewModel.lastLibrarianOutcome {
                    Text("\(outcome.summary) · $\(String(format: "%.4f", outcome.costUSD))")
                        .font(.caption)
                        .accessibilityIdentifier("librarian-outcome")
                    ForEach(Array(outcome.notes.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let last = viewModel.lastLibrarianPassAt {
                    Text("Last pass \(last, style: .relative) ago.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("librarian-last-pass")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4))
            .cornerRadius(8)
            Divider()
        }
    }
}

/// What the runs have learned about working in this repo — the other file every
/// agent reads, and the one that had no surface at all.
///
/// `RunKnowledgeDistiller` merges each finished run's learnings into
/// `.kiteloop/coordinator-knowledge.md`, and the Planner, the worker and the
/// reviewer all receive it. So it shapes every run, is written by the machine,
/// and until now could only be corrected by finding a file inside a dot
/// directory.
///
/// Which is why it rots. On 2026-08-20 it was still telling every worker that
/// the unit suite had six known-failing tests — the suite was green at 4178 —
/// and that the merge-verify used `build`, which had been changed to
/// `build-for-testing` that morning. Two false facts, briefed into every run,
/// invisible. A worker told the suite is already red will rationalise away a
/// regression, which is the failure this surface exists to make correctable.
private struct FleetKnowledgeEditor: View {
    @Bindable var viewModel: MemoryViewModel

    /// The draft when there is one, the file otherwise. Typing back to what is
    /// on disk drops the draft, so a distiller update shows again.
    private var content: Binding<String> {
        Binding(
            get: { viewModel.fleetKnowledgeDraft ?? viewModel.fleetKnowledge },
            set: { viewModel.fleetKnowledgeDraft = $0 == viewModel.fleetKnowledge ? nil : $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What the fleet has learned")
                    .font(.headline)
                Spacer()
                if let draft = viewModel.fleetKnowledgeDraft, viewModel.hasUnsavedFleetKnowledge {
                    Button("Revert") { viewModel.revertFleetKnowledge() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("fleet-knowledge-revert-button")
                    Button("Save") {
                        Task { await viewModel.saveFleetKnowledge(draft) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("fleet-knowledge-save-button")
                }
            }

            Text("Written by finished runs and read by the Planner, the worker and the reviewer — so it shapes every run. Correct anything that has stopped being true: a stale line here is briefed into work as fact.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = viewModel.lastWriteError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            TextEditor(text: content)
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("fleet-knowledge-text-editor")
        }
        .padding(16)
    }
}

private struct ProjectContextEditor: View {
    @Bindable var viewModel: MemoryViewModel

    /// The draft when there is one, the file otherwise. Typing back to what is
    /// on disk drops the draft.
    private var content: Binding<String> {
        Binding(
            get: { viewModel.sharedContextDraft ?? viewModel.sharedContext },
            set: { viewModel.sharedContextDraft = $0 == viewModel.sharedContext ? nil : $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Project Context")
                    .font(.headline)
                Spacer()
                if let draft = viewModel.sharedContextDraft, viewModel.hasUnsavedSharedContext {
                    Button("Revert") { viewModel.revertSharedContext() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("project-context-revert-button")
                    Button("Save") {
                        // Only a write that landed clears the draft. Otherwise
                        // the Save button stays, holding text that is not on
                        // disk and that nobody else has a copy of.
                        Task { await viewModel.saveSharedContext(draft) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("project-context-save-button")
                }
            }

            Text("All agents receive this as part of their system prompt. Edit to give your team shared knowledge about this project.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = viewModel.lastWriteError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("memory-write-error")
            }

            TextEditor(text: content)
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("project-context-text-editor")
        }
        .padding()
        .accessibilityIdentifier("project-context-editor")
    }
}
