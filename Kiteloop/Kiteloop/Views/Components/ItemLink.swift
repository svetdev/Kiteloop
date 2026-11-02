import KiteloopCore
import SwiftUI

// MARK: - The action

/// The app-level *open item `<id>` in project `<project>`* action.
///
/// Installed once, by `MainWindow`, and reached through the environment the way
/// `dismiss` and `openWindow` are — so a view that names an item does not have
/// to be handed a navigation closure through however many initialisers sit
/// between it and the window. The window's handler switches to the item's
/// project tab when it isn't the active one, lands on the backlog surface, and
/// pushes the item's page.
///
/// It is total: every call is answered. An id that no longer resolves, or one in
/// a project nobody has open, comes back as a named refusal — see
/// `ItemLinkResolver` — rather than a blank page or a click that does nothing.
struct OpenItemAction {
    private let handler: (@MainActor (String, ItemLinkProject) -> Void)?

    /// The action nothing installed. What a preview, a test host, or a scene
    /// outside the main window sees: `ItemLink` draws a plain mention rather than
    /// an affordance that leads nowhere.
    init() { handler = nil }

    init(_ handler: @escaping @MainActor (String, ItemLinkProject) -> Void) {
        self.handler = handler
    }

    /// Whether anything installed it. This is the only thing `ItemLink` asks:
    /// whether a *particular* id still resolves is the handler's answer, not a
    /// question every mention has to ask before drawing itself.
    var isInstalled: Bool { handler != nil }

    @MainActor
    func callAsFunction(_ itemID: String, in project: ItemLinkProject) {
        handler?(itemID, project)
    }
}

private struct OpenItemActionKey: EnvironmentKey {
    static let defaultValue = OpenItemAction()
}

extension EnvironmentValues {
    /// The app-level open-item action. See `OpenItemAction`.
    var openItem: OpenItemAction {
        get { self[OpenItemActionKey.self] }
        set { self[OpenItemActionKey.self] = newValue }
    }
}

// MARK: - The component

/// An item mention that opens the item's page.
///
/// One implementation, adopted declaratively: a surface wraps whatever it
/// already draws for the item — an id chip, a title, a run headline — and that
/// mention becomes a link, with a hover affordance and a tooltip naming what it
/// opens. No surface builds its own drill-in, and none of them carries a
/// navigation closure through its initialiser to get one.
///
/// With no action installed the label is drawn exactly as it was. An affordance
/// that leads nowhere is worse than plain text.
struct ItemLink<Label: View>: View {
    let itemID: String
    let project: ItemLinkProject
    @ViewBuilder let label: () -> Label

    @Environment(\.openItem) private var openItem
    @State private var isHovering = false

    init(_ itemID: String, in project: ItemLinkProject,
         @ViewBuilder label: @escaping () -> Label) {
        self.itemID = itemID
        self.project = project
        self.label = label
    }

    var body: some View {
        if openItem.isInstalled {
            Button {
                openItem(itemID, in: project)
            } label: {
                label()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm)
                    .fill(Color.accentColor.opacity(isHovering ? KiteloopTokens.Opacity.medium : 0))
            )
            .onHover { isHovering = $0 }
            .hoverCursor()
            .help("Open \(itemID)")
            .accessibilityIdentifier("item-link-\(itemID)")
        } else {
            label()
        }
    }
}

// MARK: - Opening an agent

/// The app-level *open agent `<id>` in the project at `<path>`* action — the
/// agent-shaped sibling of `OpenItemAction`, installed by `MainWindow` beside it.
/// The window's handler switches to the agent's project tab when it isn't the
/// active one and lands on the agent's chat, which is where a question it asked
/// is answered.
struct OpenAgentAction {
    private let handler: (@MainActor (String, String) -> Void)?

    /// The action nothing installed: `AgentLink` draws a plain label.
    init() { handler = nil }

    init(_ handler: @escaping @MainActor (String, String) -> Void) {
        self.handler = handler
    }

    var isInstalled: Bool { handler != nil }

    @MainActor
    func callAsFunction(_ agentID: String, inProjectAt projectPath: String) {
        handler?(agentID, projectPath)
    }
}

private struct OpenAgentActionKey: EnvironmentKey {
    static let defaultValue = OpenAgentAction()
}

extension EnvironmentValues {
    /// The app-level open-agent action. See `OpenAgentAction`.
    var openAgent: OpenAgentAction {
        get { self[OpenAgentActionKey.self] }
        set { self[OpenAgentActionKey.self] = newValue }
    }
}

/// What opening an agent does to the window, lifted out of `MainWindow` so it
/// can be asserted without one: the same steps as the question arm of
/// `openGate(_:)`, plus closing the notifications popover, which — unlike the
/// waiting drawer — sits over the chat it is sending you to.
enum AgentLinkLanding {
    @MainActor
    static func land(agentID: String, projectPath: String,
                     openProjects: [KiteloopProject], activeProjectID: String?,
                     switchTo: (KiteloopProject) -> Void,
                     select: (_ projectID: String, _ agentID: String) -> Void,
                     closeNotifications: () -> Void) {
        let projectID = KiteloopProject.canonicalPath(projectPath)
        // A project closed since the notice was filed has no session to land
        // on; its chat is gone with the tab.
        guard let target = openProjects.first(where: { $0.id == projectID }) else { return }
        closeNotifications()
        if activeProjectID != projectID {
            switchTo(target)
        }
        select(projectID, agentID)
    }
}

/// An agent mention that opens the agent's chat. Drawn exactly like `ItemLink`,
/// and like it, a plain label when nothing installed the action.
struct AgentLink<Label: View>: View {
    let agentID: String
    let projectPath: String
    /// What the hover text calls the agent; the id when nobody named it.
    let displayName: String?
    @ViewBuilder let label: () -> Label

    @Environment(\.openAgent) private var openAgent
    @State private var isHovering = false

    init(_ agentID: String, inProjectAt projectPath: String, displayName: String? = nil,
         @ViewBuilder label: @escaping () -> Label) {
        self.agentID = agentID
        self.projectPath = projectPath
        self.displayName = displayName
        self.label = label
    }

    var body: some View {
        if openAgent.isInstalled {
            Button {
                openAgent(agentID, inProjectAt: projectPath)
            } label: {
                label()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: KiteloopTokens.Radius.sm)
                    .fill(Color.accentColor.opacity(isHovering ? KiteloopTokens.Opacity.medium : 0))
            )
            .onHover { isHovering = $0 }
            .hoverCursor()
            .help("Open the chat with \(displayName ?? agentID)")
            .accessibilityIdentifier("agent-link-\(agentID)")
        } else {
            label()
        }
    }
}
