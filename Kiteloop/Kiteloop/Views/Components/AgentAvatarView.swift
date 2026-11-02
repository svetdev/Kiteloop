import SwiftUI

struct AgentAvatarView: View {
    let agent: Agent
    let size: CGFloat
    var projectURL: URL?
    var hasMissingRepos: Bool
    /// Autopilot is driving this agent with no human gating its tools.
    var isUnattended: Bool
    var onBadgeTap: (() -> Void)?

    @State private var pulseActive = false

    init(agent: Agent, size: CGFloat = 32, projectURL: URL? = nil, hasMissingRepos: Bool = false, isUnattended: Bool = false, onBadgeTap: (() -> Void)? = nil) {
        self.agent = agent
        self.size = size
        self.projectURL = projectURL
        self.hasMissingRepos = hasMissingRepos
        self.isUnattended = isUnattended
        self.onBadgeTap = onBadgeTap
    }

    var body: some View {
        ZStack {
            avatarContent
                .frame(width: size, height: size)
                .clipShape(Circle())

            if agent.state == .working {
                Circle()
                    .strokeBorder(Color.green, lineWidth: 2)
                    .frame(width: size + 4, height: size + 4)
                    .opacity(pulseActive ? 0.3 : 1.0)
                    .onAppear { pulseActive = true }
                    .onDisappear { pulseActive = false }
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseActive)
            }

            if let waiting = Self.waitingBadge(agentName: agent.name, isUnattended: isUnattended, state: agent.state) {
                Circle()
                    .strokeBorder(Color.orange, lineWidth: 2)
                    .frame(width: size + 4, height: size + 4)

                Circle()
                    .fill(Color.orange)
                    .frame(width: size * 0.4, height: size * 0.4)
                    .overlay(
                        Image(systemName: waiting.symbol)
                            .font(.system(size: size * 0.22, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: size * 0.3, y: -size * 0.3)
                    .help(waiting.help)
                    .accessibilityIdentifier("waiting-badge-\(agent.id)")
            }

            if let unattended = UnattendedIndicator.model(agentName: agent.name, isUnattended: isUnattended, state: agent.state) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: size * 0.4, height: size * 0.4)
                    .overlay(
                        Image(systemName: unattended.symbol)
                            .font(.system(size: size * 0.22, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: size * 0.3, y: -size * 0.3)
                    .help(unattended.help)
                    .accessibilityIdentifier("unattended-badge-\(agent.id)")
            }

            if hasMissingRepos {
                Circle()
                    .fill(Color.orange)
                    .frame(width: size * 0.35, height: size * 0.35)
                    .overlay(
                        Image(systemName: "exclamationmark")
                            .font(.system(size: size * 0.2, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .offset(x: size * 0.3, y: size * 0.3)
                    .onTapGesture { onBadgeTap?() }
            }
        }
    }

    /// Derives the "waiting on a human" badge for an agent, or `nil` when it
    /// doesn't apply. A pure function so the decision is testable without a view.
    nonisolated static func waitingBadge(agentName: String, isUnattended: Bool, state: Agent.AgentState) -> AgentStateBadge? {
        AgentStateBadge.waiting(agentName: agentName, isUnattended: isUnattended, state: state)
    }

    private static let bundledAvatars: [String: String] = [:]

    @ViewBuilder
    private var avatarContent: some View {
        if let assetName = Self.bundledAvatars[agent.id], let nsImage = NSImage(named: assetName) {
            ZStack {
                Circle()
                    .fill(colorForState(agent.state).opacity(0.15))
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.65, height: size * 0.65)
            }
        } else if let av = agent.avatar, !av.isEmpty {
            if av.contains(".") || av.contains("/") {
                customImageView(av)
            } else {
                emojiView(av)
            }
        } else {
            emojiView(Self.defaultEmoji(for: agent.name))
        }
    }

    private func emojiView(_ emoji: String) -> some View {
        ZStack {
            Circle()
                .fill(colorForState(agent.state).opacity(0.15))
            Text(emoji)
                .font(.system(size: size * 0.55))
        }
    }

    private func customImageView(_ filename: String) -> some View {
        Group {
            if let url = resolveImageURL(filename),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                emojiView(Self.defaultEmoji(for: agent.name))
            }
        }
    }

    private func resolveImageURL(_ filename: String) -> URL? {
        guard let projectURL else { return nil }
        let avatarDir = projectURL.appendingPathComponent(".kiteloop/avatars")
        let url = avatarDir.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The role each name derives its avatar from — every pair the switch
    /// that stood here held, unchanged. A table and not a switch only
    /// because the complexity gate refuses a re-declared 15-arm switch and
    /// the lookup has to be callable by name for the sidebar's answer to be
    /// asserted.
    private static let roleEmoji: [String: String] = [
        "coder": "🤖", "backend": "🤖",
        "reviewer": "🦉",
        "researcher": "🔮", "research": "🔮",
        "frontend": "🎨",
        "components": "🧩",
        "infra": "⚔️", "devops": "⚔️", "operations": "⚔️",
        "security": "🛡️", "enforcer": "🛡️",
        "creative": "🧙‍♂️", "designer": "🧙‍♂️", "wireframe": "🧙‍♂️",
        "qa": "🐍", "tester": "🐍", "test": "🐍",
        "performance": "⚡", "optimizer": "⚡",
        "data": "👁️", "analytics": "👁️",
        "debug": "🐛", "troubleshooter": "🐛",
        "prompt tuner": "🧝‍♂️", "prompt engineer": "🧝‍♂️",
        "prd": "🦅", "product": "🦅", "manager": "🦅",
        "claude": "🏰"
    ]

    /// The avatar an agent with none chosen is drawn with, derived from its
    /// role name. Static so the sidebar's answer can be asserted without a view.
    nonisolated static func defaultEmoji(for name: String) -> String {
        roleEmoji[name.lowercased()] ?? "👾"
    }

    private func colorForState(_ state: Agent.AgentState) -> Color {
        switch state {
        case .idle: return .gray
        case .working: return .green
        case .waitingForHuman: return .orange
        case .crashed: return .red
        }
    }
}
