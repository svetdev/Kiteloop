import SwiftUI

struct SearchBar: View {
    @Binding var query: String
    let matchCount: Int
    /// How many older messages the chat never loaded, and so never searched.
    let unsearchedOlderMessageCount: Int
    let currentIndex: Int
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onDismiss: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search messages...", text: $query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .onSubmit { respond(to: .returnKey) }
                .accessibilityIdentifier("search-field")
            if matchCount > 0 {
                Text("\(currentIndex + 1)/\(matchCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("match-counter")
            }
            if let noMatchesNote {
                Text(noMatchesNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("search-no-matches")
            }
            if let unsearchedNote {
                Text(unsearchedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("unsearched-note")
            }
            Button(action: onPrevious) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            .accessibilityIdentifier("search-previous")
            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            .accessibilityIdentifier("search-next")
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search-close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .background(
            Group {
                Button("") { respond(to: .shiftReturn) }
                    .keyboardShortcut(.return, modifiers: .shift)
                    .hidden()
                Button("") { respond(to: .escape) }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
            }
        )
        .onAppear { isFieldFocused = true }
    }

    /// What the bar says beside its counter about the messages it never
    /// searched, so the count is not read as covering the whole conversation.
    /// Nil when there are none, and nothing is drawn.
    var unsearchedNote: String? {
        guard unsearchedOlderMessageCount > 0 else { return nil }
        return "\(unsearchedOlderMessageCount) older not searched"
    }

    /// What the bar says in its counter's place when the query found nothing,
    /// so a search with no results does not look like an untouched field.
    /// Nil while the field is empty or something matched.
    var noMatchesNote: String? {
        guard !query.isEmpty, matchCount == 0 else { return nil }
        return "No matches"
    }

    /// The keys the bar answers to while it is open. Esc is one of them, which
    /// is why the input bar's stop button gives its own Esc up for as long as
    /// the bar is on screen — only one view may own the key at a time.
    enum Key {
        case returnKey
        case shiftReturn
        case escape
    }

    func respond(to key: Key) {
        switch key {
        case .returnKey: onNext()
        case .shiftReturn: onPrevious()
        case .escape: onDismiss()
        }
    }
}
