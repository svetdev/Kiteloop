import KiteloopCore
import SwiftUI

struct AgentInfoPopover: View {
    let agent: Agent
    var onConfigure: (() -> Void)? = nil

    @State private var needsConfig = false

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
            header
            if !agent.mcpServers.isEmpty { mcpSection }
            if !agent.tools.isEmpty { toolsSection }
            if !agent.skills.isEmpty { skillsSection }
            permissionsSection
        }
        .padding(KiteloopTokens.Spacing.xl)
        .frame(width: 280, alignment: .leading)
        .onAppear { checkConfig() }
    }

    /// The blue model tag in the header, spelled the way the rest of the app spells
    /// a model; an id the catalog does not know is shown as stored.
    static func modelTag(for agent: Agent) -> String {
        ModelCatalog.displayName(for: agent.model)
    }

    /// The orange permission tag in the header, named as the Edit Agent sheet names
    /// the mode; a mode it does not know is shown as stored.
    static func permissionTag(for agent: Agent) -> String {
        SettingNames.permissionMode(agent.permissionMode)
    }

    /// The Effort row's value, named as the rest of the app names an effort level;
    /// a level it does not know is shown as stored.
    static func effortLabel(_ effort: String) -> String {
        SettingNames.effort(effort)
    }

    private func checkConfig() {
        guard let path = agent.mcpConfigPath else { return }
        if let config = ClaudeMCPConfig.load(from: path) {
            needsConfig = config.hasEmptyEnvVars
        }
    }

    private var header: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            AgentAvatarView(agent: agent, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    TagView(text: AgentInfoPopover.modelTag(for: agent), color: .blue)
                    TagView(text: AgentInfoPopover.permissionTag(for: agent), color: .orange)
                }
            }
        }
    }

    private var mcpSection: some View {
        InfoSection(title: "MCP Servers") {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 4) {
                    ForEach(agent.mcpServers, id: \.self) { server in
                        TagView(text: server, color: .purple)
                    }
                }
                if needsConfig, let onConfigure {
                    Button(action: onConfigure) {
                        Label("Configure credentials", systemImage: "key")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var toolsSection: some View {
        InfoSection(title: "Tools") {
            VStack(alignment: .leading, spacing: 4) {
                let allowed = agent.tools.filter { !agent.denied.contains($0) }
                if !allowed.isEmpty {
                    ToolRow(label: "Allowed", tools: allowed, color: .secondary)
                }
                if !agent.denied.isEmpty {
                    ToolRow(label: "Denied", tools: agent.denied, color: .red)
                }
            }
        }
    }

    private var skillsSection: some View {
        InfoSection(title: "Skills") {
            FlowLayout(spacing: 4) {
                ForEach(agent.skills, id: \.self) { skill in
                    TagView(text: skill, color: .teal)
                }
            }
        }
    }

    private var permissionsSection: some View {
        InfoSection(title: "Config") {
            VStack(alignment: .leading, spacing: 3) {
                if agent.thinkingEnabled {
                    ConfigRow(label: "Thinking", value: agent.thinkingBudget.map { "\($0) tokens" } ?? "enabled")
                }
                if let effort = agent.effort {
                    ConfigRow(label: "Effort", value: AgentInfoPopover.effortLabel(effort))
                }
                if !agent.crossAgentAccess.isEmpty {
                    ConfigRow(label: "Can message", value: agent.crossAgentAccess.joined(separator: ", "))
                }
            }
        }
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(.tertiary)
            content
        }
    }
}

private struct TagView: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct ToolRow: View {
    let label: String
    let tools: [String]
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            FlowLayout(spacing: 3) {
                ForEach(tools, id: \.self) { tool in
                    Text(tool)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(color.opacity(0.1))
                        .foregroundStyle(color == .secondary ? .primary : color)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
        }
    }
}

private struct ConfigRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary)
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, offsets: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
            totalHeight = max(totalHeight, y + rowHeight)
        }
        return (CGSize(width: totalWidth, height: totalHeight), offsets)
    }
}
