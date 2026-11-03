import KiteloopCore
import SwiftUI

/// One line an `Agent` row hangs under itself: a call its subagent made,
/// with its result when one has come back, or something the subagent said or
/// thought.
struct SubagentChild: Identifiable {
    enum Kind {
        case call(Message.ToolCall, result: Message.ToolResult?)
        case text(String)
        case thinking(String, estimatedTokens: Int?)
    }

    let id: String
    let kind: Kind
    /// What the subagent this call started did, when the call is itself an
    /// `Agent` call — drawn under it, one step further in, inside its fold.
    var nested: [SubagentChild] = []

    /// The call, for a child that is one.
    var call: Message.ToolCall? {
        if case .call(let call, _) = kind { return call }
        return nil
    }

    /// The call's result, for a child that is a call answered.
    var result: Message.ToolResult? {
        if case .call(_, let result) = kind { return result }
        return nil
    }

    /// Everything each subagent in `messages` did, calls paired with their
    /// results, keyed by the `Agent` call it belongs under.
    ///
    /// Every depth is resolved: a subagent's own `Agent` call carries its
    /// subagent's children in `nested`, rather than leaving them to be drawn
    /// as if the outer subagent had made them.
    static func byParent(in messages: [Message], results: [String: Message.ToolResult]) -> [String: [SubagentChild]] {
        let flat = ToolCallNesting.childMessages(in: messages).mapValues { children in
            children.compactMap { child(for: $0, results: results) }
        }
        return flat.mapValues { nesting($0, in: flat, above: []) }
    }

    /// `children`, each call that started a subagent given that subagent's
    /// own children. `above` holds the calls already on the path, so a parent
    /// id that loops back is drawn once rather than for ever.
    private static func nesting(_ children: [SubagentChild], in flat: [String: [SubagentChild]],
                                above: Set<String>) -> [SubagentChild] {
        children.map { child in
            guard let call = child.call, !above.contains(call.id), let inner = flat[call.id] else { return child }
            var nested = child
            nested.nested = nesting(inner, in: flat, above: above.union([call.id]))
            return nested
        }
    }

    private static func child(for message: Message, results: [String: Message.ToolResult]) -> SubagentChild? {
        switch message.content {
        case .toolCall(let call):
            return SubagentChild(id: call.id, kind: .call(call, result: results[call.id]))
        case .text(let text):
            return SubagentChild(id: message.id.uuidString, kind: .text(text))
        case .thinking(let text):
            return SubagentChild(id: message.id.uuidString,
                                 kind: .thinking(text, estimatedTokens: message.thinkingTokenEstimate))
        default:
            return nil
        }
    }
}

/// What a subagent or background-shell row says about its task, kept apart
/// from the rows so it can be asserted without drawing one.
enum SubagentRowText {
    /// The line under the call — the task's status — or nil when the stream
    /// has said nothing about a task for this call, as for a chat reopened
    /// after the session that ran it.
    static func statusLine(for task: AgentActivity.TaskState?) -> String? {
        task.map(AgentActivityDisplay.statusLine(for:))
    }

    /// `Bash(ls -la)`: a subagent's call, printed the way the agent's own are.
    static func childLine(for call: Message.ToolCall) -> String {
        TerminalText.callLine(tool: call.name, target: ToolCallLabel.rowSummary(tool: call.name, input: input(of: call)))
    }

    /// What an opened child call shows under `⎿`: the lines the agent's own
    /// calls show for the same result — a read as a count, a failure as its
    /// error, anything else as its first lines — or "Running…" while no
    /// result has come back.
    static func openedLines(for call: Message.ToolCall, result: Message.ToolResult?) -> [String] {
        guard let result else { return ["Running…"] }
        return TerminalText.resultLines(tool: call.name, output: result.output, input: input(of: call))
    }

    private static func input(of call: Message.ToolCall) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(call.input.utf8))) as? [String: Any] ?? [:]
    }

    /// The fold line standing in for a subagent's calls while they are
    /// hidden, and for what it said, when it said anything.
    static func foldedLine(count: Int, said: Int = 0) -> String {
        "+\(summary(calls: count, said: said)) (click to expand)"
    }

    /// `2 tool calls` — with `, 1 message` when the subagent also said or
    /// thought something: the bubble look's disclosure label.
    static func summary(calls: Int, said: Int) -> String {
        let callCount = String(count: calls, noun: "tool call")
        return said == 0 ? callCount : "\(callCount), \(String(count: said, noun: "message"))"
    }

    /// How many of `children` are calls, and how many something said.
    static func counts(of children: [SubagentChild]) -> (calls: Int, said: Int) {
        let calls = children.filter { $0.call != nil }.count
        return (calls, children.count - calls)
    }

    /// A subagent's thought as its line reads — `Thinking…`, or how much it
    /// thought when the CLI estimated it.
    static func thinkingLine(_ text: String, estimatedTokens: Int?) -> String {
        AgentActivityDisplay.thinkingLabel(text: text, estimatedTokens: estimatedTokens)
    }

    /// Whether the task's row reads as failed, finished or still going.
    static func outcome(of task: AgentActivity.TaskState) -> ToolResultOutcomeTint {
        switch task.status {
        case .running: return .pending
        case .completed: return .success
        default: return .failure
        }
    }
}

/// The three colours a call's mark can take.
enum ToolResultOutcomeTint {
    case pending, success, failure

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .success: return .green
        case .failure: return .red
        }
    }
}

// MARK: - Terminal look

/// A subagent's calls, text and thinking under its `Agent` row,
/// terminal-style: each a smaller `⏺ Tool(target)`, `⏺ text` or `✻ Thinking…`
/// line that a click opens on its own, the group folded to one line by a
/// click on its fold line.
struct TerminalChildCalls: View {
    let children: [SubagentChild]
    @State private var isFolded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if isFolded {
                let counts = SubagentRowText.counts(of: children)
                foldToggle(SubagentRowText.foldedLine(count: counts.calls, said: counts.said))
            } else {
                ForEach(children) { TerminalChildRow(child: $0) }
                foldToggle("(click to fold)")
            }
        }
        .padding(.leading, 28)
    }

    private func foldToggle(_ text: String) -> some View {
        TerminalChildRow.line(mark: TerminalStyle.resultMark, text: text, color: .secondary)
            .contentShape(Rectangle())
            .onTapGesture { isFolded.toggle() }
    }
}

/// One child under an `Agent` row in the terminal look. A call opens to its
/// result lines under `⎿`, and a text line to its full text; a click again
/// closes it.
private struct TerminalChildRow: View {
    let child: SubagentChild
    @State private var isOpen = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { isOpen.toggle() }
    }

    @ViewBuilder
    private var content: some View {
        switch child.kind {
        case .call(let call, let result):
            VStack(alignment: .leading, spacing: 1) {
                callRow(call, result: result)
                if !child.nested.isEmpty {
                    TerminalChildCalls(children: child.nested)
                }
            }
        case .text(let text):
            Self.line(mark: TerminalStyle.replyMark, text: text, color: .primary, lineLimit: isOpen ? nil : 6)
        case .thinking(let text, let estimate):
            Self.line(mark: "✻", text: SubagentRowText.thinkingLine(text, estimatedTokens: estimate), color: .secondary)
                .italic()
        }
    }

    private func callRow(_ call: Message.ToolCall, result: Message.ToolResult?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Self.line(mark: TerminalStyle.replyMark, text: SubagentRowText.childLine(for: call), color: Self.markColor(result))
            if isOpen {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TerminalStyle.resultMark).font(TerminalStyle.smallFont).foregroundStyle(.tertiary)
                    Text(SubagentRowText.openedLines(for: call, result: result).joined(separator: "\n"))
                        .font(TerminalStyle.smallFont)
                        .foregroundStyle(Self.markColor(result) == .red ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 12)
            }
        }
    }

    static func line(mark: String, text: String, color: Color, lineLimit: Int? = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(mark).font(TerminalStyle.smallFont).foregroundStyle(color)
            Text(text).font(TerminalStyle.smallFont).foregroundStyle(.secondary)
                .lineLimit(lineLimit).truncationMode(lineLimit == 1 ? .middle : .tail)
        }
    }

    private static func markColor(_ result: Message.ToolResult?) -> Color {
        guard let result else { return .secondary }
        return ToolResultOutcome.of(output: result.output).isError ? .red : .green
    }
}

// MARK: - Bubble look

/// A subagent's calls under its `Agent` row in the bubble look: the agent's own
/// rows, indented, with what the subagent said and thought between them,
/// behind a disclosure that says how many there are.
struct BubbleChildCalls: View {
    let children: [SubagentChild]
    @State private var isFolded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isFolded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isFolded ? 0 : 90))
                    let counts = SubagentRowText.counts(of: children)
                    Text(SubagentRowText.summary(calls: counts.calls, said: counts.said))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 32)
            .padding(.vertical, 2)
            if !isFolded {
                ForEach(children) { childRow($0).padding(.leading, 20) }
            }
        }
    }
}

extension BubbleChildCalls {
    @ViewBuilder
    fileprivate func childRow(_ child: SubagentChild) -> some View {
        switch child.kind {
        case .call(let call, let result):
            ToolCallView(toolCall: call, result: result, children: child.nested)
        case .text(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(8)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        case .thinking(let text, let estimate):
            Text("✻ " + SubagentRowText.thinkingLine(text, estimatedTokens: estimate))
                .font(.caption.italic())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
        }
    }
}

/// The status a subagent or background shell's bubble row carries beside its
/// name.
struct TaskStatusLabel: View {
    let task: AgentActivity.TaskState

    var body: some View {
        HStack(spacing: 4) {
            if task.status == .running {
                ProgressView().controlSize(.mini)
            }
            Text(AgentActivityDisplay.statusLine(for: task))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(SubagentRowText.outcome(of: task) == .failure ? Color.red : Color.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Background strip

/// `Background: 1 running · Run the tests` above the input while a background
/// shell or subagent is up; nothing at all while none is.
struct BackgroundTasksStrip: View {
    let tasks: [AgentActivityEvent.BackgroundTask]

    var body: some View {
        if let summary = AgentActivityDisplay.backgroundSummary(tasks) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(summary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .help(tasks.map(\.description).joined(separator: "\n"))
            .accessibilityIdentifier("background-tasks-strip")
        }
    }
}
