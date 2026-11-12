import KiteloopCore
import SwiftUI

/// A call the session stopped to ask leave for, as a terminal would: allow it
/// this once, allow it and remember one of the rules the CLI offers, or
/// refuse it. The session waits on the card without limit; an answered card
/// reads what was chosen, and one the session took back says so.
struct PermissionCard: View {
    let request: Message.PermissionRequest
    /// Allow or refuse, and for an allow the suggestion to remember, if any.
    let onAnswer: (_ allow: Bool, _ remembering: Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.orange)
                Text(Self.title(for: request))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }

            Text(request.summary)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let answer = request.answer {
                HStack(spacing: 4) {
                    Image(systemName: Self.answeredSymbol(answer))
                        .foregroundStyle(answer == .allowed || answer == .allowedAlways ? .green : .secondary)
                    Text(Self.answeredLabel(answer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("permission-card-answer")
            } else {
                buttons
            }
        }
        .padding(12)
        .background(.orange.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .accessibilityIdentifier("permission-card")
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Allow once") { onAnswer(true, nil) }
                    .buttonStyle(.borderedProminent)
                Button("Deny") { onAnswer(false, nil) }
            }
            ForEach(Array(request.suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button(suggestion.label) { onAnswer(true, index) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    /// Who is asking, and for which tool: the agent itself, or the subagent
    /// whose call it is, named by the task it was given.
    static func title(for request: Message.PermissionRequest) -> String {
        guard let subagent = request.subagent else { return "Asks to use \(request.toolName)" }
        return "Subagent “\(subagent)” asks to use \(request.toolName)"
    }

    static func answeredLabel(_ answer: Message.PermissionRequest.Answer) -> String {
        switch answer {
        case .allowed: "Allowed once"
        case .allowedAlways: "Allowed, and remembered"
        case .denied: "Denied"
        case .lapsed: "No longer waiting on an answer"
        }
    }

    static func answeredSymbol(_ answer: Message.PermissionRequest.Answer) -> String {
        switch answer {
        case .allowed, .allowedAlways: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .lapsed: "clock.badge.xmark"
        }
    }
}
