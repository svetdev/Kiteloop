import KiteloopCore
import SwiftUI

// MARK: - Project Root Environment

/// Project root path, used to relativize file paths in tool call rows.
private struct ProjectRootPathKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    var projectRootPath: String {
        get { self[ProjectRootPathKey.self] }
        set { self[ProjectRootPathKey.self] = newValue }
    }
}

// MARK: - Tool Call Row

/// A call's row in the bubble look. A call that started a subagent or a
/// background shell carries its task's status in place of the call's own
/// result, and a subagent's calls hang, indented, under it.
struct ToolCallView: View {
    let toolCall: Message.ToolCall
    var result: Message.ToolResult? = nil
    var task: AgentActivity.TaskState? = nil
    var children: [SubagentChild] = []

    @State private var isExpanded = false
    @Environment(\.projectRootPath) private var projectRootPath

    private var parsedInput: [String: Any] {
        guard let data = toolCall.input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private var diff: EditDiff? {
        EditDiff(tool: toolCall.name, input: parsedInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: ToolAppearance.icon(for: toolCall.name))
                    .font(.caption)
                    .foregroundStyle(ToolAppearance.tint(for: toolCall.name))
                Text(toolCall.name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(ToolAppearance.tint(for: toolCall.name))

                targetLabel

                if let diff {
                    DiffBadge(added: diff.addedLines, removed: diff.removedLines)
                }

                if let task {
                    TaskStatusLabel(task: task)
                } else if let result {
                    ResultSummary(result: result, tool: toolCall.name)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .modifier(CommandTooltip(command: commandTooltip))
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            if isExpanded {
                expandedContent
            }
            if !children.isEmpty {
                BubbleChildCalls(children: children)
            }
        }
    }

    // MARK: Collapsed Row Pieces

    @ViewBuilder
    private var targetLabel: some View {
        if let path = parsedInput["file_path"] as? String {
            let display = PathDisplay(path: path, projectRoot: projectRootPath)
            HStack(spacing: 0) {
                if !display.directory.isEmpty {
                    Text(display.directory)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(display.filename)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.head)
        } else {
            Text(fallbackSummary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var fallbackSummary: String {
        ToolCallLabel.rowSummary(tool: toolCall.name, input: parsedInput)
    }

    /// The command a shell row's label now stands in for, kept on the row: a
    /// result that is an error about a directory that does not exist is only
    /// actionable next to the command that produced it. Nil for the rows whose
    /// label already is the whole of their input.
    private var commandTooltip: String? {
        ToolCallLabel.detail(tool: toolCall.name, input: parsedInput)
    }

    // MARK: Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let diff {
                DiffView(diff: diff)
            } else {
                inputExpansion
            }

            if let result, !result.output.isEmpty {
                Divider()
                ScrollView {
                    Text(result.output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .frame(maxHeight: 200)
                .modifier(ToolOutputCopyOverlay(result: result))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    /// What a call with no diff to draw expands to: the command as it was run,
    /// or the prompt a delegated call was given, and otherwise the arguments
    /// verbatim — which is the JSON the CLI sent, so a command in it reads with
    /// its newlines escaped and its arguments quoted.
    @ViewBuilder
    private var inputExpansion: some View {
        Text(ToolCallLabel.expansionText(tool: toolCall.name, input: parsedInput) ?? toolCall.input)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}

/// Hangs the command off the row, and nothing at all off a row that has none:
/// `help` takes no optional, so the alternative is attaching an empty tooltip to
/// every `Read` and `Grep` row in the transcript.
private struct CommandTooltip: ViewModifier {
    let command: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let command, !command.isEmpty {
            content.help(command)
        } else {
            content
        }
    }
}

// MARK: - Tool Appearance

enum ToolAppearance {
    static func icon(for name: String) -> String {
        builtInIcons[name] ?? kiteloopIcons[name] ?? webIcons[name] ?? "wrench"
    }

    /// Claude Code's own tools.
    private static let builtInIcons: [String: String] = [
        "Read": "doc.text",
        "Edit": "pencil",
        "Write": "square.and.pencil",
        "Bash": "terminal",
        "Glob": "magnifyingglass", "Grep": "magnifyingglass",
        "Agent": "person.2", "Task": "person.2",
    ]

    /// The tools Kiteloop's tool bridge adds.
    private static let kiteloopIcons: [String: String] = [
        "message_agent": "bubble.left.and.bubble.right",
        "broadcast_agents": "megaphone",
        "publish_event": "bell",
        "recall_knowledge": "brain.head.profile", "save_knowledge": "brain.head.profile",
        "propose_memory": "tray.and.arrow.down",
        "hire_agent": "person.badge.plus",
        "fire_agent": "person.badge.minus",
    ]

    /// The browser tools.
    private static let webIcons: [String: String] = [
        "web_navigate": "safari",
        "web_screenshot": "camera.viewfinder",
        "web_read_text": "doc.plaintext",
        "web_console": "exclamationmark.bubble",
        "web_inspect_head": "chevron.left.forwardslash.chevron.right",
        "web_list_elements": "list.number",
        "web_click": "cursorarrow.click",
        "web_type": "keyboard",
        "web_scroll": "arrow.up.and.down",
    ]

    static func tint(for name: String) -> Color {
        switch name {
        case "Read": return .blue
        case "Edit", "Write": return .orange
        case "Bash": return Color(nsColor: .secondaryLabelColor)
        case "Glob", "Grep": return .purple
        case "message_agent", "broadcast_agents", "Agent", "Task": return .teal
        default: return .orange
        }
    }
}

// MARK: - Path Display

struct PathDisplay {
    let directory: String
    let filename: String

    init(path: String, projectRoot: String) {
        let root = projectRoot.hasSuffix("/") ? String(projectRoot.dropLast()) : projectRoot
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var relative = path
        if !root.isEmpty, PathDisplay.contains(root: root, path: path) {
            let tail = path.dropFirst(root.count)
            // The root itself: keep its own name rather than relativising to nothing.
            relative = tail.isEmpty ? URL(fileURLWithPath: root).lastPathComponent
                                    : String(tail.dropFirst())
        } else if PathDisplay.contains(root: home, path: path) {
            relative = "~" + path.dropFirst(home.count)
        }
        let url = URL(fileURLWithPath: relative)
        self.filename = url.lastPathComponent
        let dir = relative.hasSuffix(url.lastPathComponent)
            ? String(relative.dropLast(url.lastPathComponent.count))
            : ""
        self.directory = dir
    }

    /// Containment on a path-component boundary: a folder contains itself and
    /// what sits under it, so a project at `/Users/me/kite` does not swallow the
    /// first characters of `/Users/me/kiteloop/App.swift`.
    private static func contains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}

// MARK: - Diff

struct EditDiff {
    let removed: [String]
    let added: [String]

    var removedLines: Int { removed.count }
    var addedLines: Int { added.count }

    /// How many lines of each side the preview draws before it cuts.
    static let maxPreviewLines = 40

    /// Whether the preview leaves anything unshown. Each side is cut on its own, so
    /// the question is whether *either* side is longer than the cap — not whether the
    /// two together are.
    var isTruncated: Bool {
        removedLines > Self.maxPreviewLines || addedLines > Self.maxPreviewLines
    }

    init?(tool: String, input: [String: Any]) {
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String else { return nil }
            self.removed = old.isEmpty ? [] : old.components(separatedBy: "\n")
            self.added = new.isEmpty ? [] : new.components(separatedBy: "\n")
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            self.removed = []
            self.added = content.components(separatedBy: "\n")
        default:
            return nil
        }
    }
}

struct DiffBadge: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 {
                Text("+\(added)")
                    .foregroundStyle(.green)
            }
            if removed > 0 {
                Text("−\(removed)")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .fontWeight(.semibold)
    }
}

struct DiffView: View {
    let diff: EditDiff
    private let maxPreviewLines = EditDiff.maxPreviewLines

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.removed.prefix(maxPreviewLines).enumerated()), id: \.offset) { _, line in
                    diffLine(line, prefix: "-", color: .red)
                }
                ForEach(Array(diff.added.prefix(maxPreviewLines).enumerated()), id: \.offset) { _, line in
                    diffLine(line, prefix: "+", color: .green)
                }
                if diff.isTruncated {
                    Text("…")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 260)
    }

    private func diffLine(_ line: String, prefix: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(prefix)
                .foregroundStyle(color)
                .fontWeight(.bold)
            Text(line.isEmpty ? " " : line)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .font(.system(.caption2, design: .monospaced))
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .background(color.opacity(0.08))
    }
}

// MARK: - Result Summary (collapsed row)

private struct ResultSummary: View {
    let result: Message.ToolResult
    let tool: String

    private var isError: Bool {
        ToolResultOutcome.of(output: result.output).isError
    }

    private var summary: String {
        ToolResultSummary.text(tool: tool, output: result.output)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(isError ? .red : .green.opacity(0.7))
            Text(summary)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - Standalone Result Row (transcript mode fallback)

struct ToolResultView: View {
    let result: Message.ToolResult
    @State private var isExpanded = false

    private var outputPreview: String {
        let lines = result.output.components(separatedBy: "\n")
        let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return String(firstNonEmpty.prefix(100))
    }

    private var lineCount: Int {
        result.output.components(separatedBy: "\n").count
    }

    private var isError: Bool {
        ToolResultOutcome.of(output: result.output).isError
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isError ? "xmark.circle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)
                Text(outputPreview)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                if lineCount > 1 {
                    Text("\(lineCount) lines")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                guard lineCount > 1 else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            if isExpanded {
                ScrollView {
                    Text(result.output)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .frame(maxHeight: 200)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .modifier(ToolOutputCopyOverlay(result: result))
            }
        }
    }
}

/// A copy button over an unfolded tool output while it is hovered, copying
/// the whole output rather than what the scroll box shows; nothing over an
/// output that is only whitespace, or when there is no result.
struct ToolOutputCopyOverlay: ViewModifier {
    let result: Message.ToolResult?
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovered = $0 }
            .overlay(alignment: .topTrailing) {
                if isHovered, let result, let copy = MessageBubble.copyableOutput(of: result) {
                    CopyButton(text: copy, label: "Copy output")
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .transition(.opacity)
                }
            }
    }
}

/// The model's thinking, folded to its first words; a click unfolds it. A
/// current model sends its thinking with no text, so the row says how much it
/// thought instead, and has nothing to unfold.
struct ThinkingView: View {
    let text: String
    var estimatedTokens: Int?
    @State private var isExpanded = false

    private var isBlank: Bool { AgentActivityDisplay.isBlankThinking(text) }

    private var title: String {
        isBlank ? AgentActivityDisplay.thinkingLabel(text: text, estimatedTokens: estimatedTokens) : "Thinking"
    }

    private var thinkingPreview: String {
        String(text.prefix(60).replacingOccurrences(of: "\n", with: " "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text(title)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.purple)
                Text(thinkingPreview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(isBlank ? 0 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded = !isExpanded && !isBlank }
            }

            if isExpanded {
                ScrollView {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .frame(maxHeight: 200)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
        }
    }
}
