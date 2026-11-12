import KiteloopCore
import AppKit
import SwiftUI

struct MessageBubble: View {
    let message: Message
    var showStreamingCursor = false
    /// Turns an `.agent(id)` sender into the name shown above the reply.
    var senderName: (String) -> String = { $0.capitalized }
    /// Offered in the reply text's right-click menu, which covers the row's own.
    var onBranchFromHere: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        if case .systemEvent = message.content {
            contentView
                .padding(.horizontal, 12)
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    contentView
                }
                Spacer(minLength: 60)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .onHover { hovering in
                withAnimation(KiteloopTokens.Anim.hover) { isHovered = hovering }
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch message.content {
        case .text(let text):
            VStack(alignment: .leading, spacing: 2) {
                senderLabel
                if case .agent = message.sender {
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.blue.opacity(0.3))
                            .frame(width: 3)
                        Group {
                            SelectableMarkdownView(markdown: text, onBranchFromHere: onBranchFromHere)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 8)
                        .padding(.vertical, 10)
                        .padding(.trailing, 10)
                        if showStreamingCursor {
                            BlinkingCursor()
                                .padding(.trailing, 8)
                        }
                    }
                    .background(KiteloopTokens.Bubble.agent)
                    .cornerRadius(KiteloopTokens.Radius.lg)
                    .overlay(alignment: .topTrailing) {
                        if isHovered, let copy = Self.copyableText(of: message) {
                            CopyButton(text: copy)
                                .padding(6)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .transition(.opacity)
                        }
                    }
                } else if case .human = message.sender {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(KiteloopTokens.Bubble.human)
                        .cornerRadius(KiteloopTokens.Radius.lg)
                        .overlay(alignment: .topTrailing) {
                            if isHovered, let copy = Self.copyableText(of: message) {
                                CopyButton(text: copy, label: "Copy message")
                                    .padding(6)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                    .transition(.opacity)
                            }
                        }
                } else {
                    Text(Self.systemNoteText(text))
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(KiteloopTokens.Bubble.system)
                        .cornerRadius(KiteloopTokens.Radius.md)
                }
            }
            .help(sentTime)

        case .thinking(let text):
            ThinkingView(text: text, estimatedTokens: message.thinkingTokenEstimate)

        case .toolCall(let call):
            ToolCallView(toolCall: call)

        case .toolResult(let result):
            ToolResultView(result: result)

        case .image(let data):
            VStack(alignment: .leading, spacing: 2) {
                senderLabel
                ImageContentView(data: data)
                    .padding(4)
                    .background(KiteloopTokens.Bubble.agent)
                    .cornerRadius(KiteloopTokens.Radius.lg)
            }
            .help(sentTime)

        case .approval(let request):
            Text("Approval: \(request.action)")
                .font(.caption)
                .textSelection(.enabled)
                .padding(8)
                .background(KiteloopTokens.Bubble.system)
                .cornerRadius(KiteloopTokens.Radius.md)

        case .error(let msg):
            Text(msg)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .padding(8)
                .background(KiteloopTokens.Bubble.error)
                .cornerRadius(KiteloopTokens.Radius.md)
                .help(sentTime)

        case .systemEvent(let event):
            SystemEventDivider(event: event)

        case .mcpAuthRequest, .plan, .permission, .choices:
            EmptyView()
        }
    }

    private var sentTime: String {
        Self.sentTimeLabel(for: message.timestamp, now: Date(), calendar: .current, locale: .current)
    }

    /// What hovering a bubble says about when it was sent: the time alone for
    /// a message from today, the date and the time for one from an earlier day.
    static func sentTimeLabel(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let style = Date.FormatStyle(
            date: isToday ? .omitted : .abbreviated,
            time: .shortened,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        return style.format(date)
    }

    /// What a row's copy button copies, the same in either look: the whole
    /// text of a message you sent or an agent's reply, and nil for anything
    /// that offers no copy — a system note, an error, a tool call, an image.
    static func copyableText(of message: Message) -> String? {
        guard case .text(let text) = message.content else { return nil }
        switch message.sender {
        case .human, .agent: return text
        case .system: return nil
        }
    }

    /// What an unfolded tool output's copy button copies, the same in either
    /// look: the call's whole output, and nil when there is nothing but
    /// whitespace to copy.
    static func copyableOutput(of result: Message.ToolResult) -> String? {
        result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : result.output
    }

    /// A note the app writes into the chat, with its inline markdown — bold,
    /// code, links — formatted and its line breaks kept; the raw text when it
    /// does not parse.
    static func systemNoteText(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    @ViewBuilder
    private var senderLabel: some View {
        switch message.sender {
        case .human:
            Text("You")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .agent(let name):
            Text(senderName(name))
                .font(.caption)
                .foregroundStyle(.blue)
        case .system:
            Text("System")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

/// The blinking insertion cursor shown at the end of an actively streaming
/// agent message.
struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.blue.opacity(0.7))
            .frame(width: 7, height: 15)
            .opacity(visible ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}
