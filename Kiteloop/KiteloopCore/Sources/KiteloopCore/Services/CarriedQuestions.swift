import Foundation

/// A question a chat on disk ends on, unanswered: the agent's `ask_human`, or
/// the model's own questions with their choices.
///
/// The session that asked is gone — the app was quit, the Mac restarted — and
/// with it the call that was waiting on the answer. The question is not: it
/// is the last thing in the chat, nobody answered it, and the conversation it
/// belongs to is resumed when the agent starts again. So it stays open, and
/// its answer goes to the agent as the next thing said, naming what was asked.
///
/// Only a question the chat *ends* on is carried. One with anything after it
/// — a restart notice, a later message — was left behind on purpose.
package enum CarriedQuestions {

    package struct Carried: Equatable, Sendable {
        /// The id the question's card is answered by.
        package let id: String
        /// Each thing asked, in order: one for `ask_human`, one per question
        /// for a choices card.
        package let asked: [String]
        package let isChoices: Bool
    }

    /// The question `messages` ends on, if it ends on an open one.
    package static func trailing(in messages: [Message]) -> Carried? {
        switch messages.last?.content {
        case .approval(let request) where request.tool == "ask_human" && request.status == .pending:
            return Carried(id: request.id, asked: [request.action], isChoices: false)
        case .choices(let asked) where asked.isOpen:
            return Carried(id: asked.id, asked: asked.questions.map(\.question), isChoices: true)
        default:
            return nil
        }
    }

    /// Closes every card a chat on disk still had open — each was asked from
    /// a session that is gone — except a question it ends on, which is
    /// returned still open.
    package static func lapseAllButTrailing(in messages: inout [Message]) -> Carried? {
        let carried = trailing(in: messages)
        guard let carried, carried.isChoices, let last = messages.popLast() else {
            PermissionCards.lapse(in: &messages)
            return carried
        }
        PermissionCards.lapse(in: &messages)
        messages.append(last)
        return carried
    }

    /// What the agent is told when a carried question is answered: what it
    /// asked, and the answer to each.
    package static func reply(to asked: [String], with answers: [String]) -> String {
        guard asked.count != 1 else {
            return "Answering your earlier question — “\(asked[0])”:\n\n\(answers.first ?? "")"
        }
        let pairs = zip(asked, answers).map { "- \($0) → \($1)" }
        return "Answering your earlier questions:\n\n" + pairs.joined(separator: "\n")
    }
}
