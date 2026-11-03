import KiteloopCore
import AppKit
import SwiftUI

/// Renders all chat messages as a single scrollable, selectable NSTextView.
/// ⌘A selects everything, ⌘C copies the full transcript.
struct TranscriptView: NSViewRepresentable {
    let messages: [Message]
    @Environment(\.colorScheme) private var colorScheme
    /// The coordinator's markdown cache, for the one render that is about to
    /// read it. It stays nil on every value SwiftUI builds — the cache has to
    /// outlive a view SwiftUI rebuilds on each update, so it lives on the
    /// coordinator and `transcript(cachedBy:)` puts it on a copy of this one.
    /// Not private only because a private stored property would take the
    /// memberwise initializer private with it.
    var markdownCache: MarkdownCache?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isRichText = true

        context.coordinator.textView = textView
        context.coordinator.apply(transcript(cachedBy: context.coordinator), to: scrollView, openingAtTheEnd: true)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.apply(transcript(cachedBy: context.coordinator), to: scrollView)
    }

    // MARK: - Rendering

    /// The transcript rendered against `coordinator`'s markdown cache, so a
    /// streaming chunk costs the markdown of the message that changed rather
    /// than of every message in the conversation. Entries for messages the
    /// conversation no longer holds go first, so the cache's size tracks it.
    private func transcript(cachedBy coordinator: Coordinator) -> NSAttributedString {
        coordinator.markdownCache.prune(keeping: messages.map(\.id))
        var view = self
        view.markdownCache = coordinator.markdownCache
        return view.renderTranscript()
    }

    private func renderTranscript() -> NSAttributedString {
        let isDark = colorScheme == .dark
        let result = NSMutableAttributedString()

        // Fonts
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.systemFont(ofSize: 14, weight: .bold)

        // Colors
        let dimColor = NSColor.secondaryLabelColor
        let toolColor = NSColor.tertiaryLabelColor
        let senderColor = NSColor.systemBlue
        let errorColor = NSColor.systemRed
        let systemColor = NSColor.systemOrange

        for entry in Self.transcriptOrder(messages) {
            let message = entry.message, start = result.length
            switch (message.sender, message.content) {

            // ── Human text ──────────────────────────────────────────────────
            case (.human, .text(let t)):
                // Bold "You:" in blue
                result.append(NSAttributedString(string: "You:", attributes: [
                    .font: boldFont,
                    .foregroundColor: senderColor
                ]))
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                // Plain body text
                result.append(NSAttributedString(string: t, attributes: [
                    .font: bodyFont,
                    .foregroundColor: NSColor.labelColor
                ]))
                result.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))

            // ── Agent text ──────────────────────────────────────────────────
            case (.agent(let name), .text(let t)):
                // Bold "{Name}:" in blue
                result.append(NSAttributedString(string: "\(name):", attributes: [
                    .font: boldFont,
                    .foregroundColor: senderColor
                ]))
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
                // Markdown-rendered body
                result.append(markdown(t, forMessage: message.id, isDark: isDark))
                result.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))

            // ── Agent thinking ──────────────────────────────────────────────
            case (.agent, .thinking(let t)):
                let preview = Self.thinkingPreview(t, estimatedTokens: message.thinkingTokenEstimate)
                result.append(NSAttributedString(string: "💭 \(preview)\n", attributes: [
                    .font: monoFont,
                    .foregroundColor: dimColor
                ]))

            // ── Tool call ────────────────────────────────────────────────────
            case (_, .toolCall(let call)):
                let summary = toolSummary(call.input, tool: call.name)
                let line = summary.isEmpty
                    ? "⚙ \(call.name)\n"
                    : "⚙ \(call.name)  \(summary)\n"
                result.append(NSAttributedString(string: line, attributes: [
                    .font: monoFont,
                    .foregroundColor: toolColor
                ]))

            // ── Tool result ──────────────────────────────────────────────────
            case (_, .toolResult(let res)):
                let firstLine = res.output
                    .components(separatedBy: "\n")
                    .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
                let preview = String(firstLine.prefix(80))
                result.append(NSAttributedString(string: "✓ \(preview)\n", attributes: [
                    .font: monoFont,
                    .foregroundColor: toolColor
                ]))

            // ── System text ──────────────────────────────────────────────────
            case (.system, .text(let t)):
                let italicFont = NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: 13),
                    toHaveTrait: .italicFontMask
                )
                result.append(NSAttributedString(string: "\(t)\n", attributes: [
                    .font: italicFont,
                    .foregroundColor: systemColor
                ]))

            // ── System event divider ────────────────────────────────────────
            case (_, .systemEvent(let event)):
                result.append(NSAttributedString(string: Self.dividerLine(for: event), attributes: [
                    .font: monoFont,
                    .foregroundColor: dimColor
                ]))

            // ── Error ────────────────────────────────────────────────────────
            case (_, .error(let msg)):
                result.append(NSAttributedString(string: "\(msg)\n", attributes: [
                    .font: bodyFont,
                    .foregroundColor: errorColor
                ]))

            // ── Image ─────────────────────────────────────────────────────────
            case (_, .image):
                result.append(NSAttributedString(string: "[Image]\n", attributes: [
                    .font: monoFont,
                    .foregroundColor: dimColor
                ]))

            // ── Cards: a plan or a question; the rest is skipped ─────────────
            default:
                appendCardText(of: message, to: result, isDark: isDark)
            }
            Self.indent(result, from: start, depth: entry.depth)
        }

        return result
    }

    /// `── ⚗️ Context compacted ──`: a system event's divider line.
    static func dividerLine(for event: Message.SystemEvent) -> String {
        let icon: String = switch event.kind {
        case .compaction: "⚗️"
        case .apiRetry: "⟳"
        case .sessionResumed: "▶"
        case .reconnecting: "📡"
        }
        return "── \(icon) \(event.detail) ──\n"
    }

    /// The order the transcript prints in, and how deep: the agent's own
    /// messages in the order they came, each subagent's calls, results, text
    /// and thinking right after the `Agent` call that started it, one level
    /// in — so a copied transcript never reads as if the main agent made a
    /// subagent's calls. A message whose parent call is not in the list is
    /// printed where it came, unindented, rather than lost.
    static func transcriptOrder(_ messages: [Message]) -> [(message: Message, depth: Int)] {
        var byParent: [String: [Message]] = [:]
        for message in messages {
            if let parent = transcriptParent(of: message) { byParent[parent, default: []].append(message) }
        }
        let calls = Set(messages.compactMap(callID(of:)))
        let top = messages.filter { transcriptParent(of: $0).map { !calls.contains($0) } ?? true }
        var ordered: [(message: Message, depth: Int)] = []
        append(top, depth: 0, byParent: byParent, above: [], to: &ordered)
        return ordered
    }

    private static func append(_ list: [Message], depth: Int, byParent: [String: [Message]],
                               above: Set<String>, to ordered: inout [(message: Message, depth: Int)]) {
        for message in list {
            ordered.append((message, depth))
            guard let id = callID(of: message), !above.contains(id), let children = byParent[id] else { continue }
            append(children, depth: depth + 1, byParent: byParent, above: above.union([id]), to: &ordered)
        }
    }

    /// The call a subagent's message hangs under — a result's included,
    /// which the chat draws with its call and so `ToolCallNesting` leaves out.
    private static func transcriptParent(of message: Message) -> String? {
        if case .toolResult(let result) = message.content { return result.parentToolUseID }
        return ToolCallNesting.subagentParent(of: message)
    }

    private static func callID(of message: Message) -> String? {
        if case .toolCall(let call) = message.content { return call.id }
        return nil
    }

    /// Indents what was appended from `start` by `depth` steps.
    static func indent(_ text: NSMutableAttributedString, from start: Int, depth: Int) {
        guard depth > 0, start < text.length else { return }
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = CGFloat(depth) * 20
        style.headIndent = style.firstLineHeadIndent
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: text.length - start))
    }

    /// A plan card or an agent's question, printed as the agent's text is:
    /// its name in bold, then the markdown. Anything `cardText(for:)` has no
    /// text for — a permission request, an MCP access card — prints nothing.
    private func appendCardText(of message: Message, to result: NSMutableAttributedString, isDark: Bool) {
        guard case .agent(let name) = message.sender, let text = Self.cardText(for: message) else { return }
        let bodyFont = NSFont.systemFont(ofSize: 14)
        result.append(NSAttributedString(string: "\(name):", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.systemBlue
        ]))
        result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
        result.append(markdown(text, forMessage: message.id, isDark: isDark))
        result.append(NSAttributedString(string: "\n\n", attributes: [.font: bodyFont]))
    }

    /// What transcript mode prints for a card: a plan's text, followed once
    /// answered by what was chosen, or the question an agent asked. Nil for
    /// every other message, a permission request included.
    static func cardText(for message: Message) -> String? {
        switch message.content {
        case .plan(let plan):
            guard let answer = plan.answer else { return plan.text }
            return plan.text + "\n\n" + PlanCard.answeredLabel(answer)
        case .approval(let request) where request.tool == "ask_human":
            return request.action
        default:
            return nil
        }
    }

    /// The markdown of an agent message, from the cache this render was handed
    /// when it holds the message as it stands now. A render nobody handed a
    /// cache — there is no such caller, but the view is a value anyone can
    /// build — renders it outright.
    private func markdown(_ text: String, forMessage id: UUID, isDark: Bool) -> NSAttributedString {
        guard let markdownCache else { return MarkdownRenderer.render(text, isDark: isDark) }
        return markdownCache.rendered(text, forMessage: id, isDark: isDark)
    }

    // MARK: - Tool Summary Helper

    /// A thinking line's words: its first sixty characters, or — for the empty
    /// block a current model sends — how much it thought.
    static func thinkingPreview(_ text: String, estimatedTokens: Int?) -> String {
        guard AgentActivityDisplay.isBlankThinking(text) else {
            return String(text.prefix(60).replacingOccurrences(of: "\n", with: " "))
        }
        return AgentActivityDisplay.thinkingLabel(text: text, estimatedTokens: estimatedTokens)
    }

    private func toolSummary(_ input: String, tool: String) -> String {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        switch tool {
        case "Read", "Edit", "Write": return json["file_path"] as? String ?? ""
        case "Bash":                  return json["command"] as? String ?? ""
        case "Glob", "Grep":          return json["pattern"] as? String ?? ""
        default:                      return ""
        }
    }

    // MARK: - Coordinator

    /// Owns the one place the transcript's text is replaced, so a rebuild keeps
    /// the reader's place: a selection survives, a view already at the end of the
    /// conversation stays there as replies arrive, and one scrolled up is left
    /// where it was.
    class Coordinator {
        var textView: NSTextView?
        /// Kept across rebuilds, which is the whole point of it.
        let markdownCache = MarkdownCache()

        /// Replaces the transcript with `transcript`, restoring the selection
        /// clamped to the new text and the end of the conversation if that is
        /// where the reader already was. `openingAtTheEnd` is how the first
        /// render lands on the newest message: the view has no content yet, so
        /// nothing about it reads as being at the end.
        func apply(
            _ transcript: NSAttributedString,
            to scrollView: NSScrollView,
            openingAtTheEnd: Bool = false
        ) {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            let visible = scrollView.documentVisibleRect
            let contentHeight = scrollView.documentView?.bounds.height ?? visible.maxY
            // a point or two short of the bottom is still the bottom
            let wasAtEnd = openingAtTheEnd || visible.maxY >= contentHeight - 2

            storage.setAttributedString(transcript)

            let location = min(selection.location, storage.length)
            textView.setSelectedRange(NSRange(
                location: location,
                length: min(selection.length, storage.length - location)
            ))
            if wasAtEnd {
                textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
            }
        }
    }

    // MARK: - Markdown Cache

    /// What each agent message's markdown was last rendered from and to.
    ///
    /// The transcript is rebuilt whole on every SwiftUI update — one per
    /// streaming chunk — so without this an N-message conversation paid N
    /// markdown renders per chunk, every fenced code block in them going
    /// through the shared highlighter's JavaScriptCore context again. A message
    /// is keyed by its id, beside the text and the colour scheme it was
    /// rendered under, because `Message.Content` is not Equatable.
    final class MarkdownCache {
        struct Entry {
            let text: String
            let isDark: Bool
            let rendered: NSAttributedString
        }

        /// One entry per agent message the last render saw.
        private(set) var entries: [UUID: Entry] = [:]

        /// `text` rendered, which is a fresh render only when the message has
        /// nothing cached, its text has grown as a chunk arrived, or it was
        /// last rendered under the other colour scheme. On the main actor,
        /// which is where `MarkdownRenderer` renders; nothing else touches this
        /// cache, which SwiftUI reaches only from a view update.
        @MainActor
        func rendered(_ text: String, forMessage id: UUID, isDark: Bool) -> NSAttributedString {
            if let entry = entries[id], entry.text == text, entry.isDark == isDark {
                return entry.rendered
            }
            let rendered = MarkdownRenderer.render(text, isDark: isDark)
            entries[id] = Entry(text: text, isDark: isDark, rendered: rendered)
            return rendered
        }

        /// Drops every message that is no longer in the conversation, so the
        /// cache holds a conversation rather than everything ever shown in one.
        func prune(keeping ids: [UUID]) {
            let live = Set(ids)
            entries = entries.filter { live.contains($0.key) }
        }
    }
}
