import KiteloopCore
import SwiftUI

/// The questions the model put with the choices it offers: pick one — or
/// several where the question allows — or type an answer of your own, for
/// each, then send them together. The session waits on the card without
/// limit; an answered card reads each answer.
struct ChoicesCard: View {
    let asked: Message.ChoiceQuestion
    /// One answer per question, in order.
    let onAnswer: ([String]) -> Void

    /// Per question: the labels picked, in the order the options are listed.
    @State private var picked: [Int: [String]] = [:]
    /// Per question: an answer typed instead of a pick.
    @State private var typed: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Agent needs your input")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }
            ForEach(Array(asked.questions.enumerated()), id: \.offset) { index, question in
                questionBlock(index, question)
            }
            footer
        }
        .padding(12)
        .background(.orange.opacity(0.06))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .accessibilityIdentifier("choices-card")
    }

    @ViewBuilder
    private func questionBlock(_ index: Int, _ question: Message.ChoiceQuestion.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.question)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let answers = asked.answers, answers.indices.contains(index) {
                Text(answers[index])
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
            } else if asked.isOpen {
                ForEach(question.options, id: \.label) { option in
                    optionRow(index, question, option)
                }
                TextField("Or type your own answer", text: Binding(
                    get: { typed[index] ?? "" },
                    set: { typed[index] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func optionRow(_ index: Int, _ question: Message.ChoiceQuestion.Question,
                           _ option: Message.ChoiceQuestion.Option) -> some View {
        let isPicked = picked[index]?.contains(option.label) ?? false
        return Button {
            picked[index] = Self.toggling(option.label, in: picked[index] ?? [], of: question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                    if !option.description.isEmpty {
                        Text(option.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var footer: some View {
        if asked.lapsed {
            Label("No longer waiting on an answer", systemImage: "clock.badge.xmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if asked.answers != nil {
            Label("Answered", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let answers = Self.answers(to: asked.questions, picked: picked, typed: typed)
            Button("Send") { if let answers { onAnswer(answers) } }
                .buttonStyle(.borderedProminent)
                .disabled(answers == nil)
        }
    }

    /// The picks of a question after `label` is clicked: a question that
    /// takes one answer holds only the newest, one that takes several adds
    /// or removes it, kept in the order the options are listed.
    static func toggling(_ label: String, in picks: [String], of question: Message.ChoiceQuestion.Question) -> [String] {
        guard question.multiSelect else { return [label] }
        let next = picks.contains(label) ? picks.filter { $0 != label } : picks + [label]
        return question.options.map(\.label).filter(next.contains)
    }

    /// One answer per question — what was typed, else the picks joined — or
    /// nil while any question has neither.
    static func answers(to questions: [Message.ChoiceQuestion.Question],
                        picked: [Int: [String]], typed: [Int: String]) -> [String]? {
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
