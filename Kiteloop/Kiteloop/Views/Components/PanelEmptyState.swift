import SwiftUI

/// The shared "nothing to show here" placeholder, and the copy rules every
/// empty surface in the app follows.
///
/// The view itself is the full-bleed centred recipe: one typography stack, so
/// the companion surfaces — the bottom Console tabs (Activity, Traces) and the
/// Inspector drawer tabs (Preview, Insights) — read as one system. The **rules**
/// below are wider than the view. They apply to the main surfaces too: the agent
/// sidebar, a chat with no messages, the backlog, the portfolio grid, an agent's
/// memory and the notification list. Those are the first things a new user
/// judges, and several of them lay out too differently to mount this view — a
/// sidebar column, a `List` row, a state with its own action button. Where the
/// layout genuinely differs, apply the rules in place; where it doesn't, mount
/// this view.
///
/// Copy rules for every empty surface, wherever it is drawn:
/// - `title` is a short sentence-case phrase, not Title Case ("No traces yet").
/// - `message` is one sentence that says what will appear here, or what to do
///   next to fill it. Never leave a panel with a bare title.
/// - Name the next action in the words of the control that performs it — "Press
///   + above and pick New Agent…", not "No agents".
/// - Prefer the words the surrounding UI uses ("turns", not "spans").
struct PanelEmptyState: View {
    let icon: String
    let title: String
    let message: String

    init(icon: String, title: String, message: String) {
        self.icon = icon
        self.title = title
        self.message = message
    }

    init(_ copy: Copy) {
        self.init(icon: copy.icon, title: copy.title, message: copy.message)
    }

    var body: some View {
        VStack(spacing: KiteloopTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, KiteloopTokens.Spacing.lg)
        .accessibilityElement(children: .combine)
    }
}

extension PanelEmptyState {
    /// One main surface's empty-state copy, written down where the rules are so
    /// the two can be checked against each other.
    ///
    /// The main surfaces keep their copy here rather than as literals at the
    /// call site — unlike the companion panels, they are drawn in six different
    /// layouts, and a rule that only some of them can be seen to follow is a
    /// rule that drifts. `PanelEmptyStateCopyTests` reads this list.
    struct Copy: Equatable {
        let icon: String
        /// A short sentence-case phrase.
        let title: String
        /// One sentence: what will appear here, or what to do next to fill it.
        let message: String
        /// The label of the control that fills this surface, exactly as the UI
        /// spells it — the message has to name it, so that "No agents" can't
        /// quietly replace "Press + above and pick New Agent…".
        ///
        /// Nil where nothing is pressed to fill the surface: a notification
        /// arrives because an agent sent one, and inventing a control for it
        /// would be worse copy, not better.
        let control: String?
    }
}

extension PanelEmptyState.Copy {
    /// The agent roster in the project sidebar, before anyone has been hired.
    static let agents = Self(
        icon: "person.2",
        title: "No agents yet",
        message: "Press + above and pick New Agent... to hire the first one.",
        control: "New Agent..."
    )

    /// A chat that has never been sent a message.
    static let chatMessages = Self(
        icon: "bubble.left.and.bubble.right",
        title: "No messages yet",
        message: "Type below and press ⌘↵ to send the first one.",
        control: "⌘↵"
    )

    /// The Backlog tab with a `BACKLOG.md` that has no sections in it. (A
    /// project with no backlog file at all gets its own state, offering to make
    /// one — that is a different question, and it already answered it.)
    static let backlogEpics = Self(
        icon: "checklist",
        title: "No epics yet",
        message: "Press Add Epic to make the first group this project's items go in.",
        control: "Add Epic"
    )

    /// The start screen's portfolio grid with nothing in it.
    static let portfolioProjects = Self(
        icon: "square.grid.2x2",
        title: "No projects yet",
        message: "Press Open Project... and the one you pick appears here with its backlog.",
        control: "Open Project..."
    )

    /// An agent whose memory index holds no facts.
    static let memoryFacts = Self(
        icon: "brain",
        title: "No memory recorded yet",
        message: "A fact lands here once this agent calls propose_memory and you press Approve.",
        control: "Approve"
    )

    /// The notification list with nothing in any of its three sections.
    static let notifications = Self(
        icon: "bell.slash",
        title: "No notifications yet",
        message: "An agent that needs an answer, or that hits an error, turns up here.",
        control: nil
    )

    /// Every main surface's copy, for the rules test.
    static let mainSurfaces: [Self] = [
        .agents, .chatMessages, .backlogEpics, .portfolioProjects, .memoryFacts, .notifications,
    ]
}
