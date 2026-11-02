import KiteloopCore
import SwiftUI

struct MemoryProposalView: View {
    let proposal: MemoryProposal
    let agentName: String
    /// The agent's loaded topics, read for the current text of each fact the
    /// proposal acts on.
    let topics: [MemoryTopic]
    let onApprove: () -> Void
    let onReject: () -> Void
    /// Reports whether the edit landed; a refused one keeps the editor open.
    let onEdit: (String) async -> Bool

    @State private var isEditing = false
    @State private var editedContent: String = ""

    /// When a proposal was filed, spelled as the chat spells a moment: the time
    /// alone for a proposal from today, the date and the time for an earlier one.
    static func filedLabel(for proposal: MemoryProposal, now: Date,
                           calendar: Calendar, locale: Locale) -> String {
        MessageBubble.sentTimeLabel(for: proposal.timestamp, now: now, calendar: calendar, locale: locale)
    }

    /// One fact a proposal acts on, with its current text — `nil` when the
    /// agent's loaded topics have no fact by that slug.
    struct AffectedFact: Equatable {
        let slug: String
        let body: String?
    }

    /// The current text of each fact `operation` acts on, in the proposal's
    /// order; empty for `.add`, which replaces nothing.
    static func affectedFacts(for operation: MemoryProposal.Operation,
                              in topics: [MemoryTopic]) -> [AffectedFact] {
        operation.topics.map { slug in
            AffectedFact(slug: slug, body: topics.first { $0.id == slug }?.body)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(proposal.operation.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(operationTint.opacity(0.18))
                    .foregroundStyle(operationTint)
                    .clipShape(Capsule())
                    .accessibilityIdentifier("memory-operation-\(proposal.id)")
                Label(agentName, systemImage: "person.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if proposal.source == .librarian {
                    Label("librarian", systemImage: "books.vertical")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.filedLabel(for: proposal, now: Date(), calendar: .current, locale: .current))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !proposal.operation.topics.isEmpty {
                Text(affectedFactsLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("memory-affected-\(proposal.id)")
                ForEach(Self.affectedFacts(for: proposal.operation, in: topics), id: \.slug) { fact in
                    affectedFactView(fact)
                }
            }

            // Shown apart from the content because it is the argument, not the
            // fact: a deletion destroys a body file, and what disproved it is
            // the whole basis on which anyone can say yes.
            if let evidence = proposal.evidence, !evidence.isEmpty {
                Label(evidence, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("memory-evidence-\(proposal.id)")
            }

            if isEditing {
                TextEditor(text: $editedContent)
                    .font(.body.monospaced())
                    .frame(minHeight: 80)
                    .border(Color.secondary.opacity(0.3))

                HStack {
                    Button("Save") {
                        Task {
                            if await onEdit(editedContent) { isEditing = false }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { isEditing = false }
                    .buttonStyle(.bordered)
                }
            } else {
                Text(proposal.proposedContent)
                    .font(.body.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
                    .cornerRadius(6)

                HStack(spacing: 12) {
                    Button("Approve") { onApprove() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .accessibilityIdentifier("approve-memory-\(proposal.id)")

                    // No editor for a deletion or an archival: their text is the
                    // reason, not the fact, so editing it would change nothing
                    // about what approving does.
                    if proposal.operation.isContentMeaningful {
                        Button("Edit") {
                            editedContent = proposal.proposedContent
                            isEditing = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("edit-memory-\(proposal.id)")
                    }

                    Button("Reject") { onReject() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .accessibilityIdentifier("reject-memory-\(proposal.id)")
                }
            }
        }
        .padding()
        .background(.background)
        .cornerRadius(8)
        .shadow(radius: 1)
    }

    /// The text approving replaces or removes, set apart from the proposed
    /// text by an edge in the operation's tint rather than a filled box.
    private func affectedFactView(_ fact: AffectedFact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(fact.slug)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let body = fact.body {
                Text(body)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Missing — this agent has no fact by that name")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(operationTint.opacity(0.5)).frame(width: 2)
        }
        .accessibilityIdentifier("memory-affected-fact-\(proposal.id)-\(fact.slug)")
    }

    private var operationTint: Color {
        switch proposal.operation {
        case .add: return .green
        case .merge: return .blue
        case .delete: return .red
        case .archive: return .orange
        }
    }

    /// Which facts approving this touches, named by the topic slugs the index
    /// prints — the same names `recall_knowledge` answers to.
    private var affectedFactsLine: String {
        let topics = proposal.operation.topics.joined(separator: ", ")
        switch proposal.operation {
        case .merge: return "Replaces: \(topics)"
        case .delete: return "Deletes: \(topics) — the fact and its full text"
        case .archive: return "Archives: \(topics) — kept on disk, no longer injected or recalled"
        case .add: return ""
        }
    }
}
