import KiteloopCore
import SwiftUI

/// The plan a `plan`-mode agent wrote, offered for approval: approve and let
/// it build in Auto or Accept Edits, or keep planning — with what should
/// change, if you type it. An answered card reads which choice was made.
struct PlanCard: View {
    let plan: Message.PlanProposal
    /// The choice, and for Keep planning what should change, trimmed.
    let onAnswer: (Message.PlanProposal.Answer, String?) -> Void

    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard.fill")
                    .foregroundStyle(.blue)
                Text("Plan ready for your approval")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
                Spacer()
                CopyButton(text: plan.text, label: "Copy plan")
            }

            SelectableMarkdownView(markdown: plan.text)
                .fixedSize(horizontal: false, vertical: true)

            if let answer = plan.answer {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(Self.answeredLabel(answer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("plan-card-answer")
            } else {
                TextField("What should change?", text: $feedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { if Self.returnAnswers(feedback) { keepPlanning() } }
                HStack(spacing: 8) {
                    Button("Approve and build (Auto)") { onAnswer(.approveAuto, nil) }
                        .buttonStyle(.borderedProminent)
                    Button("Approve and build (Accept Edits)") { onAnswer(.approveAcceptEdits, nil) }
                    Button("Keep planning") { keepPlanning() }
                }
            }
        }
        .padding(12)
        .background(.blue.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .accessibilityIdentifier("plan-card")
    }

    private func keepPlanning() {
        onAnswer(.keepPlanning, feedback.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether Return in the feedback field answers the card: only with text
    /// in it, so a stray Return in an empty field keeps the plan open.
    static func returnAnswers(_ feedback: String) -> Bool {
        !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What an answered card says was chosen.
    static func answeredLabel(_ answer: Message.PlanProposal.Answer) -> String {
        switch answer {
        case .approveAuto: "Approved — building in Auto"
        case .approveAcceptEdits: "Approved — building in Accept Edits"
        case .keepPlanning: "Kept planning"
        }
    }
}
