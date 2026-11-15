import AppKit
import KiteloopCore
import SwiftUI

/// The Memory tab's page for the notes the Claude CLI keeps for the project:
/// what an agent wrote when someone in chat said "remember this".
struct ClaudeMemoryPane: View {
    @Bindable var viewModel: ClaudeMemoryViewModel

    /// The note awaiting confirmation before it is deleted.
    @State private var pendingDelete: ClaudeMemoryNote?
    /// The notes opened to show their text.
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let error = viewModel.lastWriteError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("claude-memory-write-error")
                }
                if !viewModel.notes.isEmpty {
                    TextField("Filter notes", text: $viewModel.filter)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("claude-memory-filter")
                    ForEach(viewModel.shownNotes) { note in
                        noteRow(note)
                    }
                }
            }
            .padding()
        }
        .accessibilityIdentifier("claude-memory-pane")
        .task { await viewModel.refresh() }
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { note in
            Button("Delete", role: .destructive) {
                Task { await viewModel.delete(note) }
            }
        } message: { note in
            Text("\"\(note.name)\" is removed from disk and from the index. Agents in this project's chats stop seeing it. This cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Claude's memory")
                    .font(.headline)
                Spacer()
                Button("Reload") { Task { await viewModel.refresh() } }
                    .controlSize(.small)
                    .accessibilityIdentifier("claude-memory-reload")
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([viewModel.store.directory])
                }
                .controlSize(.small)
                .disabled(viewModel.notes.isEmpty)
            }
            Text(ClaudeMemoryViewModel.subtitle(noteCount: viewModel.noteCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("claude-memory-subtitle")
            Text("Chat sessions read and write these; autopilot runs do not see them. Kiteloop's own per-agent memory is under Agents.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(viewModel.store.directory.path(percentEncoded: false))
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func noteRow(_ note: ClaudeMemoryNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if !expanded.insert(note.id).inserted { expanded.remove(note.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: expanded.contains(note.id) ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(note.name).fontWeight(.medium)
                            if let kind = note.kind {
                                Text(kind)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        if let summary = note.summary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("claude-memory-note-\(note.id)")

            if expanded.contains(note.id) {
                noteDetail(note)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func noteDetail(_ note: ClaudeMemoryNote) -> some View {
        if let edit = viewModel.edit, edit.noteID == note.id {
            TextEditor(text: Binding(get: { edit.text }, set: { viewModel.updateEdit(text: $0) }))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .accessibilityIdentifier("claude-memory-editor-\(note.id)")
            HStack {
                Button("Save") { Task { await viewModel.saveEdit() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(edit.text == edit.baseline && viewModel.lastWriteError == nil)
                Button("Cancel") { viewModel.cancelEdit() }
            }
            .controlSize(.small)
        } else {
            Text(note.isIndex ? note.text : note.body)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Edit") { viewModel.openEdit(note) }
                    .accessibilityIdentifier("claude-memory-edit-\(note.id)")
                if !note.isIndex {
                    Button("Delete", role: .destructive) { pendingDelete = note }
                        .accessibilityIdentifier("claude-memory-delete-\(note.id)")
                }
            }
            .controlSize(.small)
        }
    }
}
