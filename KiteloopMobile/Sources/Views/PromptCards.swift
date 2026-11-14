import SwiftUI

/// A call the agent's session stopped to ask leave for, with the Mac card's
/// answers while it is open: allow it this once, refuse it, or allow it and
/// have the session remember one of the offers. The session waits on the
/// card with no time limit; answered, it reads what was chosen.
struct PermissionCardView: View {
    let agentName: String
    let text: String
    let state: PermissionState
    /// `allow`, `always` or `deny`; for `always` which offer to remember; and
    /// for an allow the call's text fields as the person reworded them.
    let onAnswer: (_ answer: String, _ always: Int?, _ edits: [String: String]) -> Void

    /// The call's text fields while the person rewords them.
    @State private var drafts: [String: String] = [:]
    @State private var isEditing = false

    private var fields: [PermissionField] { state.fields ?? [] }
    private var edits: [String: String] { Self.edits(from: drafts, over: fields) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.title(agentName: agentName, state: state))
                .font(.caption.bold()).foregroundStyle(.orange)
            if isEditing, state.open == true {
                editor
            } else {
                Text(Self.shown(text: text, state: state))
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(12)
            }
            if state.open == true {
                HStack {
                    Button(isEditing ? "Allow as edited" : "Allow once") { onAnswer("allow", nil, edits) }
                        .buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) { onAnswer("deny", nil, [:]) }
                        .buttonStyle(.bordered)
                    if !isEditing, !fields.isEmpty {
                        Button("Edit") {
                            drafts = Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
                            isEditing = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("permission-card-edit")
                    }
                }
                ForEach(Array((state.always ?? []).enumerated()), id: \.offset) { index, offer in
                    Button(offer) { onAnswer("always", index, edits) }
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
            } else {
                Text(Self.answerLabel(state.answer, edited: state.edited == true)).font(.caption.bold())
                    .foregroundStyle(Self.wasAllowed(state.answer) ? .green : .secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("permission-card")
    }

    /// One box per text field of the call; a call with one needs no label.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields, id: \.name) { field in
                if fields.count > 1 {
                    Text(field.name).font(.caption2).foregroundStyle(.secondary)
                }
                TextField(field.name, text: Binding(
                    get: { drafts[field.name] ?? field.value },
                    set: { drafts[field.name] = $0 }
                ), axis: .vertical)
                .font(.system(.callout, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
        }
    }

    /// The drafts that differ from what the call asked.
    nonisolated static func edits(from drafts: [String: String], over fields: [PermissionField]) -> [String: String] {
        let asked = Dictionary(fields.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        return drafts.filter { asked[$0.key] != nil && asked[$0.key] != $0.value }
    }

    /// What the card reads: the call as asked, or — once it was allowed
    /// reworded — its fields as they were sent.
    nonisolated static func shown(text: String, state: PermissionState) -> String {
        guard state.edited == true, let fields = state.fields, !fields.isEmpty else { return text }
        return fields.count == 1 ? fields[0].value : fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    /// Who asks, and for which tool: the agent, or the subagent whose call it
    /// is, named by the task it was given.
    nonisolated static func title(agentName: String, state: PermissionState) -> String {
        let tool = state.tool ?? "a tool"
        let asker = state.subagent.map { "\(agentName)’s subagent “\($0)”" } ?? agentName
        return state.open == true ? "\(asker) asks to use \(tool)" : "\(asker) asked to use \(tool)"
    }

    /// What an answered card says it was answered with; a card closed with an
    /// answer this build has no name for says only that it is closed.
    nonisolated static func answerLabel(_ answer: String?, edited: Bool) -> String {
        edited ? "\(answerLabel(answer)), as edited" : answerLabel(answer)
    }

    nonisolated static func answerLabel(_ answer: String?) -> String {
        switch answer {
        case "allowed": "Allowed once"
        case "allowedAlways": "Allowed, and remembered"
        case "denied": "Denied"
        case "lapsed": "No longer waiting on an answer"
        default: "Answered"
        }
    }

    nonisolated static func wasAllowed(_ answer: String?) -> Bool {
        answer == "allowed" || answer == "allowedAlways"
    }
}

/// The questions the agent put with the choices it offers: pick one — or
/// several where a question takes several — or type an answer of your own for
/// each, then send them together.
struct ChoicesCardView: View {
    let agentName: String
    let state: ChoicesState
    /// One answer per question, in order.
    let onAnswer: ([String]) -> Void

    /// Per question: the labels picked, in the order the options are listed.
    @State private var picked: [Int: [String]] = [:]
    /// Per question: an answer typed instead of a pick.
    @State private var typed: [Int: String] = [:]

    private var questions: [ChoiceQuestionInfo] { state.questions ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.open == true ? "\(agentName) is asking you" : "Asked you")
                .font(.caption.bold()).foregroundStyle(.orange)
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                questionBlock(index, question)
            }
            if state.open == true {
                let answers = Self.answers(to: questions, picked: picked, typed: typed)
                Button("Answer") { if let answers { onAnswer(answers) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(answers == nil)
            } else if state.answers == nil {
                Text("No longer waiting on an answer").font(.caption.bold()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("choices-card")
    }

    @ViewBuilder
    private func questionBlock(_ index: Int, _ question: ChoiceQuestionInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question ?? "").font(.callout).textSelection(.enabled)
            if let answers = state.answers, answers.indices.contains(index) {
                Text(answers[index]).font(.callout.bold())
            } else if state.open == true {
                ForEach(Array((question.options ?? []).enumerated()), id: \.offset) { _, option in
                    optionRow(index, question, option)
                }
                TextField("Or type your own answer", text: Binding(
                    get: { typed[index] ?? "" },
                    set: { typed[index] = $0 }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func optionRow(_ index: Int, _ question: ChoiceQuestionInfo, _ option: ChoiceOptionInfo) -> some View {
        let label = option.label ?? ""
        let isPicked = picked[index]?.contains(label) ?? false
        return Button {
            picked[index] = Self.toggling(label, in: picked[index] ?? [], of: question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).foregroundStyle(.primary)
                    if let detail = option.description, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The picks of a question after `label` is tapped: a question that takes
    /// one answer holds only the newest, one that takes several adds or
    /// removes it, kept in the order the options are listed.
    nonisolated static func toggling(_ label: String, in picks: [String], of question: ChoiceQuestionInfo) -> [String] {
        guard question.multiSelect == true else { return [label] }
        let next = picks.contains(label) ? picks.filter { $0 != label } : picks + [label]
        return (question.options ?? []).compactMap(\.label).filter(next.contains)
    }

    /// One answer per question — what was typed, else the picks joined — or
    /// nil while any question has neither.
    nonisolated static func answers(to questions: [ChoiceQuestionInfo], picked: [Int: [String]], typed: [Int: String]) -> [String]? {
        var answers: [String] = []
        for index in questions.indices {
            let own = (typed[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = own.isEmpty ? (picked[index] ?? []).joined(separator: ", ") : own
            guard !answer.isEmpty else { return nil }
            answers.append(answer)
        }
        return answers
    }
}

/// The open agent's session, beside the conversation: the permission mode it
/// runs in, changed as `/mode` changes it on the Mac, and the subagents and
/// background shells it has running, each stopped on its own.
struct AgentSessionSheet: View {
    @Bindable var model: AgentsViewModel
    let client: ControlClient
    @Environment(\.dismiss) private var dismiss

    private var mode: String {
        model.chatAgent.flatMap { agent in model.agents.first { $0.id == agent.id } }?.mode ?? model.chatAgent?.mode ?? ""
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Permission mode") {
                    ForEach(PermissionMode.all, id: \.id) { choice in
                        Button {
                            Task { await model.setMode(client, mode: choice.id) }
                        } label: {
                            HStack {
                                Text(choice.name).foregroundStyle(.primary)
                                Spacer()
                                if choice.id == mode { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                Section("Running") {
                    if model.tasks.isEmpty {
                        Text("No subagents or background shells are running.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.tasks) { task in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title).lineLimit(2)
                                Text(task.subagent ?? task.kind ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop", role: .destructive) { Task { await model.stopTask(client, taskID: task.id) } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if let failure = model.sendFailure {
                    Section { Text(failure).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(model.chatAgent?.name ?? "Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await reload() }
            .task { await reload() }
        }
        .presentationDetents([.medium, .large])
    }

    private func reload() async {
        await model.refresh(client)
        await model.loadTasks(client)
    }
}
