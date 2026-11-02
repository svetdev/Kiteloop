import KiteloopCore
import SwiftUI

struct AskHumanBubble: View {
    let request: Message.ApprovalRequest
    /// Whether the session is still waiting on *this* question. A transcript
    /// loaded from another session, or an agent restarted since, leaves a
    /// bubble still marked pending whose call is gone — it says so rather than
    /// drawing a Reply button that answers nothing.
    let isAnswerable: Bool
    let onRespond: (String) -> Void

    @State private var answer = ""

    /// The answer field and its Reply button are drawn only for a question the
    /// session is still waiting on — a pending bubble whose call is gone gets
    /// the dead-question line instead.
    var showsAnswerField: Bool { request.status == .pending && isAnswerable }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Agent needs your input")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }

            SelectableMarkdownView(markdown: request.action)
                .fixedSize(horizontal: false, vertical: true)

            if showsAnswerField {
                HStack(spacing: 8) {
                    TextField("Your answer…", text: $answer, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .onSubmit { submit() }

                    Button("Reply") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if request.status == .pending {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.xmark")
                        .foregroundStyle(.secondary)
                    Text("This question can no longer be answered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("ask-human-unanswerable")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Answered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.orange.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .accessibilityIdentifier("ask-human-bubble")
    }

    private func submit() {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRespond(trimmed)
    }
}
