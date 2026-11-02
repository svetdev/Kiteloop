import Foundation

/// A chat written out as Markdown, for Export Chat…: every message headed by
/// who sent it and when. Text and errors are written in full, a tool call is one
/// line naming the tool. Thinking, tool results, approvals and MCP access cards
/// are left out — an access card's typed values most of all.
package enum ChatMarkdownExporter {
    /// The Markdown for the chat titled `title`. `agentName` maps an agent id to
    /// the name its messages are headed by.
    package static func markdown(
        title: String,
        messages: [Message],
        agentName: (String) -> String,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var sections = ["# \(title)"]
        for message in messages {
            guard let body = body(of: message.content) else { continue }
            let sender = senderName(message.sender, agentName: agentName)
            sections.append("### \(sender) — \(formatter.string(from: message.timestamp))\n\n\(body)")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// The file name Export Chat… suggests: the title the sidebar row shows.
    package static func fileName(for session: ChatSession) -> String {
        (session.isUntitled ? "New Chat" : session.title) + ".md"
    }

    static func senderName(_ sender: Message.Sender, agentName: (String) -> String) -> String {
        switch sender {
        case .human: "You"
        case .agent(let id): agentName(id)
        case .system: "System"
        }
    }

    /// What a message's content contributes, or nil for content left out.
    static func body(of content: Message.Content) -> String? {
        switch content {
        case .text(let text): text
        case .error(let error): "**Error:** \(error)"
        case .toolCall(let call): "- Tool call: `\(call.name)`"
        case .image: "_[image]_"
        case .systemEvent(let event): "_\(event.detail)_"
        case .thinking, .toolResult, .approval, .mcpAuthRequest, .plan: nil
        }
    }
}
