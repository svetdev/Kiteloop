import KiteloopCore
import SwiftUI

/// Settings → Control API → Quick replies: the one-tap replies every paired
/// phone offers above its chat composer, one per line.
struct QuickRepliesSection: View {
    @Bindable var globalConfigStore: GlobalConfigStore
    @State private var text = ""

    var body: some View {
        Section("Quick replies") {
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 60, maxHeight: 100)
                .accessibilityIdentifier("settings-quick-replies")
            HStack {
                Button("Save Replies") { globalConfigStore.setQuickReplies(QuickReplies.list(from: text)) }
                    .disabled(QuickReplies.list(from: text) == QuickReplies.effective(globalConfigStore.config))
                Spacer()
            }
            Text("One per line. The phone shows them above its chat: tapping one sends it, or queues it while the agent is working. Save an empty list to show none.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .onAppear { text = QuickReplies.effective(globalConfigStore.config).joined(separator: "\n") }
    }
}
