import KiteloopCore
import AppKit
import SwiftUI

/// The Claude Code terminal look for a chat with one agent in it: a `>` before
/// what you typed, a `⏺` before each reply and tool call, a tool's output hung
/// under `⎿` and cut to a few lines — one monospaced column instead of bubbles.
enum TerminalStyle {
    static let font = Font.system(size: 13, design: .monospaced)
    static let smallFont = Font.system(size: 12, design: .monospaced)
    static let replyMark = "⏺"
    static let resultMark = "⎿"
    static let promptMark = ">"
    /// How many lines of a tool's output show before the "+N lines" fold.
    static let previewLines = 3

    /// `text` with every proportional run set in the system monospaced font a
    /// point smaller — bold kept as semibold, italic kept — so a rendered reply
    /// reads in the terminal's one typeface. Code is already monospaced and is
    /// left alone.
    static func monospaced(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let font = value as? NSFont, !font.isFixedPitch else { return }
            result.addAttribute(.font, value: monospacedFont(like: font), range: range)
        }
        return result
    }

    private static func monospacedFont(like font: NSFont) -> NSFont {
        let traits = font.fontDescriptor.symbolicTraits
        let mono = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: traits.contains(.bold) ? .semibold : .regular)
        guard traits.contains(.italic) else { return mono }
        return NSFontManager.shared.convert(mono, toHaveTrait: .italicFontMask)
    }
}

/// What the terminal rows print, kept apart from the views so a row's text can
/// be asserted without drawing it.
enum TerminalText {
    /// `Bash(swift test)`, `Read(Tests/LoginTests.swift)`: the tool and what it
    /// was pointed at, the way the terminal prints a call. A call with nothing
    /// to point at is its name alone.
    static func callLine(tool: String, target: String) -> String {
        target.isEmpty ? tool : "\(tool)(\(target))"
    }

    /// The lines printed under `⎿` for a finished call. A read or a search
    /// reads as a count — "Read 84 lines", "Found 12 matches" — and a failure
    /// as its error; anything else shows the first lines of its output, with
    /// how many more there were. A file change reads as what it changed —
    /// "Updated notes.txt with 2 additions and 1 removal", "Wrote 14 lines to
    /// notes.txt" — worked out from the call's `input`.
    static func resultLines(tool: String, output: String, input: [String: Any] = [:],
                            limit: Int = TerminalStyle.previewLines) -> [String] {
        let summary = ToolResultSummary.text(tool: tool, output: output)
        if ToolResultOutcome.of(output: output).isError { return [summary] }
        if let change = changeLine(tool: tool, input: input) { return [change] }
        switch tool {
        case "Read": return ["Read \(summary)"]
        case "Grep", "Glob": return [summary.hasSuffix("matches") ? "Found \(summary)" : summary]
        default: return preview(of: output, limit: limit)
        }
    }

    /// What an `Edit` or a `Write` changed, or nil for any other call and for
    /// one whose input holds no change to count. A written file's trailing
    /// newline ends its last line; it does not start another.
    static func changeLine(tool: String, input: [String: Any]) -> String? {
        guard let diff = EditDiff(tool: tool, input: input) else { return nil }
        let file = ((input["file_path"] as? String) ?? "").split(separator: "/").last.map(String.init) ?? "file"
        guard tool == "Write" else {
            return "Updated \(file) with \(counted(diff.addedLines, "addition")) and \(counted(diff.removedLines, "removal"))"
        }
        let written = diff.added.last == "" ? diff.addedLines - 1 : diff.addedLines
        return "Wrote \(counted(written, "line")) to \(file)"
    }

    /// The first `limit` changed lines, removed before added, each marked `-`
    /// or `+`, and the fold line naming how many were left out.
    static func diffPreview(_ diff: EditDiff, limit: Int = TerminalStyle.previewLines) -> [String] {
        let lines = diff.removed.map { "- " + $0 } + diff.added.map { "+ " + $0 }
        let hidden = lines.count - limit
        guard hidden > 0 else { return lines }
        return Array(lines.prefix(limit)) + ["… +\(hidden) \(hidden == 1 ? "line" : "lines") (click to expand)"]
    }

    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// The first `limit` lines of `output`, trailing blank lines dropped, and a
    /// fold line naming how many were left out. Empty output reads as "(No output)".
    static func preview(of output: String, limit: Int) -> [String] {
        var lines = output.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard !lines.isEmpty else { return ["(No output)"] }
        let hidden = lines.count - limit
        guard hidden > 0 else { return lines }
        return Array(lines.prefix(limit)) + ["… +\(hidden) \(hidden == 1 ? "line" : "lines") (click to expand)"]
    }
}

// MARK: - Message row

/// Everything but a tool call and the interactive cards, drawn terminal-style.
struct TerminalMessageRow: View {
    let message: Message
    var showStreamingCursor = false
    /// Offered in the reply text's right-click menu, which covers the row's own.
    var onBranchFromHere: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { isHovered = $0 }
            .help(MessageBubble.sentTimeLabel(for: message.timestamp, now: Date(), calendar: .current, locale: .current))
    }

    @ViewBuilder
    private var content: some View {
        switch message.content {
        case .text(let text): textRow(text)
        case .thinking(let text): TerminalThinkingRow(text: text, estimatedTokens: message.thinkingTokenEstimate)
        case .image(let data): marked(TerminalStyle.replyMark, color: .primary) { ImageContentView(data: data) }
        case .error(let text): marked(TerminalStyle.replyMark, color: .red) { plain(text, color: .red) }
        case .approval(let request): marked(TerminalStyle.replyMark, color: .orange) { plain("Approval: \(request.action)", color: .secondary) }
        case .toolResult(let result): ToolResultView(result: result)
        case .systemEvent(let event): SystemEventDivider(event: event)
        case .toolCall, .mcpAuthRequest, .plan: EmptyView()
        }
    }

    @ViewBuilder
    private func textRow(_ text: String) -> some View {
        switch message.sender {
        case .human: promptRow(text)
        case .agent: replyRow(text)
        case .system: marked(TerminalStyle.resultMark, color: .secondary) { plain(MessageBubble.systemNoteText(text), color: .secondary) }
        }
    }

    /// What you typed: `>` and the text on a quiet full-width band, as the
    /// terminal draws a submitted prompt.
    private func promptRow(_ text: String) -> some View {
        marked(TerminalStyle.promptMark, color: .secondary) { plain(text, color: .primary) }
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .topTrailing) {
                if isHovered, let copy = MessageBubble.copyableText(of: message) {
                    CopyButton(text: copy, label: "Copy message").padding(2)
                }
            }
            .padding(.top, 6)
    }

    /// Top-aligned rather than on the first baseline: the reply is an AppKit
    /// text view, whose baseline SwiftUI cannot see, so the mark would sit on a
    /// line of its own above the text.
    private func replyRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(TerminalStyle.replyMark).font(TerminalStyle.font).foregroundStyle(.primary)
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                SelectableMarkdownView(markdown: text, monospaced: true, onBranchFromHere: onBranchFromHere)
                    .fixedSize(horizontal: false, vertical: true)
                if showStreamingCursor { BlinkingCursor() }
            }
            .overlay(alignment: .topTrailing) {
                if isHovered, let copy = MessageBubble.copyableText(of: message) { CopyButton(text: copy).padding(2) }
            }
        }
    }

    private func plain(_ text: String, color: Color) -> some View {
        plain(AttributedString(text), color: color)
    }

    private func plain(_ text: AttributedString, color: Color) -> some View {
        Text(text)
            .font(TerminalStyle.font)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func marked<Body: View>(_ mark: String, color: Color, @ViewBuilder body: () -> Body) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mark).font(TerminalStyle.font).foregroundStyle(color)
            body()
        }
    }
}

// MARK: - Tool call row

/// `⏺ Tool(target)` with its outcome under `⎿`; a click shows the whole of it.
///
/// A call that started a subagent or a background shell says how that task
/// stands under `⎿` instead of what the call returned — the call returns at
/// once, the task is what is still going — and a subagent's own calls hang
/// under it.
struct TerminalToolCallRow: View {
    let toolCall: Message.ToolCall
    var result: Message.ToolResult?
    var task: AgentActivity.TaskState?
    var children: [SubagentChild] = []
    @State private var isExpanded = false
    @Environment(\.projectRootPath) private var projectRootPath

    private var input: [String: Any] {
        guard let data = toolCall.input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private var target: String {
        guard let path = input["file_path"] as? String else {
            return ToolCallLabel.rowSummary(tool: toolCall.name, input: input)
        }
        let display = PathDisplay(path: path, projectRoot: projectRootPath)
        return display.directory + display.filename
    }

    private var markColor: Color {
        if let task { return SubagentRowText.outcome(of: task).color }
        guard let result else { return .secondary }
        return ToolResultOutcome.of(output: result.output).isError ? .red : .green
    }

    /// What `⎿` carries: the whole output when unfolded, else the task's status
    /// when there is a task, else the output's first lines.
    private var outcomeLines: [String] {
        if isExpanded, let result { return [result.output] }
        if let status = SubagentRowText.statusLine(for: task) { return [status] }
        guard let result else { return ["Running…"] }
        return TerminalText.resultLines(tool: toolCall.name, output: result.output, input: input)
    }

    /// The change a finished, successful `Edit` or `Write` made, drawn as a
    /// diff under its summary line; nil for anything else.
    private var diff: EditDiff? {
        guard task == nil, let result, !ToolResultOutcome.of(output: result.output).isError else { return nil }
        return EditDiff(tool: toolCall.name, input: input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TerminalStyle.replyMark).font(TerminalStyle.font).foregroundStyle(markColor)
                Text(TerminalText.callLine(tool: toolCall.name, target: target))
                    .font(TerminalStyle.font.weight(.semibold))
                    .lineLimit(isExpanded ? nil : 1)
                    .truncationMode(.middle)
            }
            resultBlock
                .modifier(ToolOutputCopyOverlay(result: isExpanded ? result : nil))
            if !children.isEmpty {
                TerminalChildCalls(children: children)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }

    private var resultBlock: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("  \(TerminalStyle.resultMark)").font(TerminalStyle.smallFont).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                if let diff, let result {
                    outcomeText(TerminalText.resultLines(tool: toolCall.name, output: result.output, input: input))
                    diffBlock(diff)
                } else {
                    outcomeText(outcomeLines)
                }
            }
        }
    }

    private func outcomeText(_ lines: [String]) -> some View {
        Text(lines.joined(separator: "\n"))
            .font(TerminalStyle.smallFont)
            .foregroundStyle(markColor == .red ? Color.red : Color.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Folded, the first changed lines — removed in red, added in green — and
    /// the fold line; unfolded, the whole change.
    @ViewBuilder
    private func diffBlock(_ diff: EditDiff) -> some View {
        if isExpanded {
            DiffView(diff: diff)
        } else {
            ForEach(Array(TerminalText.diffPreview(diff).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(TerminalStyle.smallFont)
                    .foregroundStyle(line.hasPrefix("- ") ? Color.red : line.hasPrefix("+ ") ? Color.green : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Thinking row

/// `✻ Thinking…`, folded; a click shows what the model thought. A current
/// model sends its thinking with no text, so the row reads how much it thought
/// — `✻ Thinking… (201 tokens)` — and has nothing to unfold.
struct TerminalThinkingRow: View {
    let text: String
    var estimatedTokens: Int?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("✻ " + AgentActivityDisplay.thinkingLabel(text: text, estimatedTokens: estimatedTokens))
                .font(TerminalStyle.font.italic())
                .foregroundStyle(.secondary)
            if isExpanded {
                Text(text)
                    .font(TerminalStyle.smallFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded = !isExpanded && !AgentActivityDisplay.isBlankThinking(text) }
    }
}
