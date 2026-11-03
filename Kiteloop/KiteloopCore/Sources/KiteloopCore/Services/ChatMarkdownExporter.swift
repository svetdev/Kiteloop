import Foundation

/// A chat written out as Markdown, for Export Chat…: every message headed by
/// who sent it and when. Text and errors are written in full, a tool call is one
/// line naming the tool. Thinking, tool results, approvals and MCP access cards
/// are left out — an access card's typed values most of all.
package enum ChatMarkdownExporter {
    /// The Markdown for the chat titled `title`. `agentName` maps an agent id to
    /// the name its messages are headed by.
    ///
    /// `messages` is the line the chat was on. With `branches` that hold any,
    /// the main line is written first and then each branch under a heading
    /// naming it, from the message it was branched at, so shared history is
    /// written once; without, the one line as it always was.
    package static func markdown(
        title: String,
        messages: [Message],
        branches: ConversationBranchSnapshot? = nil,
        agentName: @escaping (String) -> String,
        timeZone: TimeZone = .current
    ) -> String {
        let writer = Writer(agentName: agentName, timeZone: timeZone)
        var sections = ["# \(title)"]
        if let snapshot = branches, !snapshot.branches.isEmpty {
            sections += branchedSections(active: messages, snapshot: snapshot, writer: writer)
        } else {
            sections += writer.sections(messages)
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    /// One message per section, headed by sender and time.
    struct Writer {
        let agentName: (String) -> String
        let formatter: DateFormatter

        init(agentName: @escaping (String) -> String, timeZone: TimeZone) {
            self.agentName = agentName
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
        }

        func heading(_ message: Message) -> String {
            "\(senderName(message.sender, agentName: agentName)) — \(formatter.string(from: message.timestamp))"
        }

        func sections(_ messages: [Message]) -> [String] {
            messages.compactMap { message in
                body(of: message.content).map { "### \(heading(message))\n\n\($0)" }
            }
        }
    }

    /// The main line, then each branch from its fork point on.
    static func branchedSections(active: [Message], snapshot: ConversationBranchSnapshot,
                                 writer: Writer) -> [String] {
        let main = snapshot.activeBranchID == nil ? active : snapshot.mainMessages
        var sections = ["## Main line"] + writer.sections(main)
        for branch in snapshot.branches {
            let line = branch.id == snapshot.activeBranchID ? active : branch.messages
            sections += branchSections(branch, line: line, writer: writer)
        }
        return sections
    }

    /// A branch's heading, the message it was branched from, and what follows
    /// it — or the whole line when that message is not in it.
    static func branchSections(_ branch: ConversationBranch, line: [Message], writer: Writer) -> [String] {
        let heading = "## Branch: \(branch.name)"
        guard let fork = line.firstIndex(where: { $0.id == branch.parentMessageID }) else {
            return [heading] + writer.sections(line)
        }
        let after = Array(line[line.index(after: fork)...])
        return [heading, "_Branched from \(writer.heading(line[fork]))_"] + writer.sections(after)
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
