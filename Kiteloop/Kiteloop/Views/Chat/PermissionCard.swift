import KiteloopCore
import SwiftUI

/// A call the session stopped to ask leave for, as a terminal would: allow it
/// this once, allow it and remember one of the rules the CLI offers, or
/// refuse it. The session waits on the card without limit; an answered card
/// reads what was chosen, and one the session took back says so.
struct PermissionCard: View {
    let request: Message.PermissionRequest
    /// Allow or refuse; for an allow the suggestion to remember, if any, and
    /// the call's text fields as the person reworded them.
    let onAnswer: (_ allow: Bool, _ remembering: Int?, _ edits: [String: String]) -> Void

    /// The call's text fields while the person is rewording them; empty
    /// until Edit is pressed.
    @State private var drafts: [String: String] = [:]
    @State private var isEditing = false

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

            if isEditing, request.answer == nil {
                editor
            } else {
                Text(Self.shown(request))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let answer = request.answer {
                HStack(spacing: 4) {
                    Image(systemName: Self.answeredSymbol(answer))
                        .foregroundStyle(answer == .allowed || answer == .allowedAlways ? .green : .secondary)
                    Text(Self.answeredLabel(for: request))
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
                Button(isEditing ? "Allow as edited" : "Allow once") { onAnswer(true, nil, edits) }
                    .buttonStyle(.borderedProminent)
                Button("Deny") { onAnswer(false, nil, [:]) }
                if !isEditing, !Self.fields(of: request).isEmpty {
                    Button("Edit…") {
                        drafts = Dictionary(uniqueKeysWithValues: Self.fields(of: request).map { ($0.name, $0.value) })
                        isEditing = true
                    }
                    .accessibilityIdentifier("permission-card-edit")
                }
            }
            ForEach(Array(request.suggestions.enumerated()), id: \.offset) { index, suggestion in
                Button(suggestion.label) { onAnswer(true, index, edits) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    /// One box per text field of the call, the one that says what it does
    /// first; a call with a single field needs no label.
    private var editor: some View {
        let fields = Self.fields(of: request)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(fields, id: \.name) { field in
                if fields.count > 1 {
                    Text(field.name).font(.caption2).foregroundStyle(.secondary)
                }
                TextEditor(text: Binding(get: { drafts[field.name] ?? field.value },
                                         set: { drafts[field.name] = $0 }))
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 36, maxHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background.opacity(0.6))
                    .cornerRadius(6)
                    .accessibilityIdentifier("permission-card-field-\(field.name)")
            }
        }
    }

    /// What the person changed, by field; empty when nothing was.
    private var edits: [String: String] {
        Self.edits(from: drafts, over: request)
    }

    static func fields(of request: Message.PermissionRequest) -> [PermissionCards.EditableField] {
        PermissionCards.editableFields(ofInput: request.input)
    }

    /// The drafts that differ from what the call asked.
    static func edits(from drafts: [String: String], over request: Message.PermissionRequest) -> [String: String] {
        let asked = Dictionary(uniqueKeysWithValues: fields(of: request).map { ($0.name, $0.value) })
        return drafts.filter { asked[$0.key] != nil && asked[$0.key] != $0.value }
    }

    /// What the card reads: the call as asked, or — once it was allowed
    /// reworded — as it was sent.
    static func shown(_ request: Message.PermissionRequest) -> String {
        guard let sent = request.sent else { return request.summary }
        return PermissionPrompt.subject(ofInput: sent)?.value
            ?? PermissionCards.editableFields(ofInput: sent).map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// Who is asking, and for which tool: the agent itself, or the subagent
    /// whose call it is, named by the task it was given.
    static func title(for request: Message.PermissionRequest) -> String {
        guard let subagent = request.subagent else { return "Asks to use \(request.toolName)" }
        return "Subagent “\(subagent)” asks to use \(request.toolName)"
    }

    /// What an answered card says was chosen; an allow of a reworded call
    /// says it ran as edited.
    static func answeredLabel(for request: Message.PermissionRequest) -> String {
        guard let answer = request.answer else { return "" }
        let label = answeredLabel(answer)
        return request.sent == nil ? label : "\(label), as edited"
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
