import Foundation
import KiteloopCore

/// The Memory tab's page over the notes the Claude CLI keeps for the project.
///
/// The folder belongs to the CLI: a chat session may rewrite a note while this
/// page is open, so every save checks the file against what the edit began
/// from, and nothing here writes unless a person pressed a button.
@Observable
@MainActor
final class ClaudeMemoryViewModel {
    let store: ClaudeMemoryStore

    /// The index first, then the notes by name, as last read from disk.
    private(set) var notes: [ClaudeMemoryNote] = []
    /// Why the last save or delete did not land — nil when it did.
    private(set) var lastWriteError: String?
    /// Narrows the list to notes whose name, summary or text contains it.
    var filter: String = ""

    /// An edit open on one note: the text being typed and the file's text when
    /// the edit began.
    struct Edit: Equatable {
        let noteID: String
        var text: String
        var baseline: String
    }

    private(set) var edit: Edit?

    init(store: ClaudeMemoryStore) {
        self.store = store
    }

    /// How many notes there are, the index not among them.
    var noteCount: Int { notes.filter { !$0.isIndex }.count }

    var shownNotes: [ClaudeMemoryNote] {
        Self.notes(notes, matching: filter)
    }

    static func notes(_ notes: [ClaudeMemoryNote], matching filter: String) -> [ClaudeMemoryNote] {
        let wanted = filter.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return notes }
        return notes.filter { note in
            [note.name, note.summary ?? "", note.text].contains { $0.localizedCaseInsensitiveContains(wanted) }
        }
    }

    /// "41 notes", "1 note", or what an empty folder means.
    static func subtitle(noteCount: Int) -> String {
        switch noteCount {
        case 0: "No notes yet. The Claude CLI writes them when you ask an agent in chat to remember something."
        case 1: "1 note, written by the Claude CLI in this project's chats."
        default: "\(noteCount) notes, written by the Claude CLI in this project's chats."
        }
    }

    func refresh() async {
        let store = store
        notes = await Task.detached { store.notes() }.value
    }

    func isEditing(_ note: ClaudeMemoryNote) -> Bool {
        edit?.noteID == note.id
    }

    func openEdit(_ note: ClaudeMemoryNote) {
        lastWriteError = nil
        edit = Edit(noteID: note.id, text: note.text, baseline: note.text)
    }

    func updateEdit(text: String) {
        edit?.text = text
    }

    func cancelEdit() {
        edit = nil
        lastWriteError = nil
    }

    /// Writes the open edit. A file that changed since the edit began is not
    /// written over the first time: the edit stays open, says so, and takes the
    /// file's new text as its baseline, so a second Save is a decision.
    func saveEdit() async {
        guard let open = edit else { return }
        let store = store
        let onDisk = await Task.detached { store.text(of: open.noteID) }.value
        guard onDisk == open.baseline else {
            edit?.baseline = onDisk ?? ""
            lastWriteError = onDisk == nil
                ? "The note was deleted on disk since you started editing. Save again to write it back."
                : MemoryViewModel.changedOnDiskMessage
            return
        }
        let failure = await Task.detached { () -> String? in
            do { try store.save(id: open.noteID, text: open.text); return nil } catch { return error.localizedDescription }
        }.value
        lastWriteError = failure.map { "Could not save the note: \($0)" }
        guard failure == nil else { return }
        edit = nil
        await refresh()
    }

    func delete(_ note: ClaudeMemoryNote) async {
        let store = store
        let failure = await Task.detached { () -> String? in
            do { try store.delete(id: note.id); return nil } catch { return error.localizedDescription }
        }.value
        lastWriteError = failure.map { "Could not delete the note: \($0)" }
        if failure == nil, edit?.noteID == note.id { edit = nil }
        await refresh()
    }
}
