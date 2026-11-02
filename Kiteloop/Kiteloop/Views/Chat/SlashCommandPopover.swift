import KiteloopCore
import SwiftUI

struct SlashCommandPopover: View {
    let skills: [Skill]
    let selectedIndex: Int
    let onSelect: (Skill) -> Void

    /// How many rows the popover draws.
    static let rowLimit = 8

    /// The skills the popover draws from `matches`, in order — the only ones
    /// the arrow keys and Enter may reach.
    static func drawnSkills(from matches: [Skill]) -> [Skill] {
        Array(matches.prefix(rowLimit))
    }

    /// The commands the chat runs itself, in the order the popover lists them.
    /// Must match the commands `ChatViewModel.runSlashCommand` handles.
    static let builtInCommands: [Skill] = [
        ("clear", "Clear the conversation and start fresh"),
        ("fork", "Fork this conversation; /fork aside opens a side chat"),
        ("compact", "Summarize the conversation to free up context"),
        ("recap", "Recap the conversation so far"),
        ("model", "Show or switch the agent's model"),
        ("mode", "Show or switch the agent's permission mode"),
        ("effort", "Show or set the agent's reasoning effort"),
        ("thinking", "Turn extended thinking on or off"),
        ("fast", "Toggle the fast model"),
        ("cost", "Show what this session has cost"),
        ("context", "Show how full the context window is"),
        ("doctor", "Diagnose the agent's setup"),
        ("history", "Show this agent's current session, model and permission mode"),
        ("loop", "Run a prompt on a loop"),
        ("goal", "Give the agent a standing goal"),
        ("undo", "Remove the last turn from the transcript"),
        ("branch", "Branch the transcript, or switch branches"),
    ].map { name, description in
        Skill(
            id: "builtin:\(name)",
            name: name,
            description: description,
            isUserInvocable: true,
            argumentHint: nil,
            body: "",
            sourceURL: URL(fileURLWithPath: "/"),
            source: .user
        )
    }

    /// The built-in commands that only refuse on an Ollama or Copilot agent.
    static let claudeOnlyCommands: Set<String> = ["fork", "compact", "mode", "effort", "thinking", "fast"]

    /// The built-in commands whose name starts with `prefix`, case-insensitively,
    /// less the Claude-only ones on another `runtime`, ahead of the registry's
    /// `skills` — less any skill a built-in shadows, since the built-in is what
    /// sending the command runs.
    static func mergedMatches(prefix: String, skills: [Skill], runtime: RuntimeKind = .claude) -> [Skill] {
        let lowered = prefix.lowercased()
        let builtIns = builtInCommands.filter {
            $0.name.hasPrefix(lowered) && (runtime == .claude || !claudeOnlyCommands.contains($0.name))
        }
        let builtInNames = Set(builtInCommands.map(\.name))
        return builtIns + skills.filter { !builtInNames.contains($0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(Self.drawnSkills(from: skills).enumerated()), id: \.element.id) { index, skill in
                Button {
                    onSelect(skill)
                } label: {
                    HStack(spacing: 8) {
                        Text("/\(skill.name)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(skill.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(index == selectedIndex ? Color.accentColor.opacity(0.1) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: 450)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
