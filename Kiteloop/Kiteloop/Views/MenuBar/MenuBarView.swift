import KiteloopCore
import SwiftUI

/// Bridges the active project's orchestrator (owned by MainWindow) to scenes
/// outside the main window, like the menu bar extra.
@MainActor
@Observable
final class ActiveOrchestratorTracker {
    var orchestrator: Orchestrator?

    /// What every open project has a run in flight on — one entry per project
    /// that is running, across *all* of them rather than the active one alone,
    /// for the same reason `waiting` below is cross-project. Refreshed on the
    /// same cadence the project tabs' spinners are — see
    /// `MainWindow.refreshRunningProjects()`.
    var inFlightItems: [InFlightItem] = []

    /// What only a person can clear, across *every* open project — not the
    /// active one alone, unlike everything else in this scene. The menu bar is
    /// the one Kiteloop surface still on screen with the window behind
    /// everything else, so a run parked at the approval gate in a project you
    /// are not looking at has to be visible here or not at all. Set from
    /// `MainWindow.refreshWaitingNotices()`, which rides the same tick.
    var waiting: WaitingOnYou = WaitingOnYou(rows: [])

    /// The last open-item request made from a scene that cannot route one
    /// itself. `MainWindow` installs the app-level action into its own
    /// environment, but the menu bar extra is a *separate scene* and that
    /// environment doesn't reach it — so the mention posts here and the window
    /// drains it. One seam, not a second implementation of the navigation.
    var openItemRequest: OpenItemRequest?

    /// The last waiting row clicked in the menu bar, for the same reason as
    /// `openItemRequest`: the popover cannot reach the window's navigation, so
    /// it posts here and `MainWindow` drains it through its own `openGate`.
    var openGateRequest: OpenGateRequest?

    struct InFlightItem: Equatable, Sendable {
        let id: String
        let title: String
        let projectPath: String

        /// Title when it has one, id when it doesn't.
        var headline: String { title.isEmpty ? id : title }

        /// The project's folder name — `KiteloopProject` carries no name of its
        /// own, so this is what every other surface calls it too.
        var projectName: String { URL(fileURLWithPath: projectPath).lastPathComponent }
    }

    /// A request, with a sequence number so that asking for the same item twice
    /// is two requests rather than one no-op — `onChange` needs the value to
    /// actually change.
    struct OpenItemRequest: Equatable, Sendable {
        let sequence: Int
        let itemID: String
        let project: ItemLinkProject
    }

    /// A gate to open, sequenced like `OpenItemRequest` so that clicking the
    /// same row twice is two requests rather than one no-op.
    struct OpenGateRequest: Equatable, Sendable {
        let sequence: Int
        let row: WaitingOnYou.Row
    }

    private var sequence = 0

    func requestOpenItem(_ itemID: String, in project: ItemLinkProject) {
        sequence += 1
        openItemRequest = OpenItemRequest(sequence: sequence, itemID: itemID, project: project)
    }

    func requestOpenGate(_ row: WaitingOnYou.Row) {
        sequence += 1
        openGateRequest = OpenGateRequest(sequence: sequence, row: row)
    }

    /// The pending open-item request, cleared as it is handed over — a request
    /// posted with no window open waits here until one takes it, and is taken
    /// once.
    func takeOpenItemRequest() -> OpenItemRequest? {
        defer { openItemRequest = nil }
        return openItemRequest
    }

    /// The pending gate request, taken the same way as `takeOpenItemRequest`.
    func takeOpenGateRequest() -> OpenGateRequest? {
        defer { openGateRequest = nil }
        return openGateRequest
    }
}

/// What the menu bar says, and shows, about work that has stopped and been
/// handed back to a person.
///
/// Both decisions are a count reduced to a word: the headline the popover draws
/// above the in-flight row, and the SF Symbol the menu bar extra's label wears
/// so the bar itself reads differently without being clicked. Kept apart from
/// the view — and from `WaitingOnYou`, which counts the kinds and is shared with
/// the sidebar footer — for the same reason `ProjectTabIndicator` is: the rule
/// is the part worth asserting on.
enum MenuBarAttention {

    /// The headline above the summary: how many things are waiting, in words.
    /// Nil when nothing is, which is what draws no section at all — a menu bar
    /// that says "0 waiting on you" is asking to be read every time it is right
    /// about nothing.
    static func headline(waiting count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "thing" : "things") waiting on you"
    }

    /// How many waiting rows the popover lists before it stops and says how
    /// many more there are — the popover is 200pt wide and sits above the
    /// in-flight rows, so a long queue would push everything else off it.
    static let visibleWaitingLimit = 5

    /// The waiting rows the popover draws, in `WaitingOnYou`'s own order, and
    /// how many it leaves out for the "+N more" line — zero when all fit.
    static func visibleWaitingRows(
        _ rows: [WaitingOnYou.Row]
    ) -> (rows: [WaitingOnYou.Row], overflow: Int) {
        let visible = Array(rows.prefix(visibleWaitingLimit))
        return (visible, rows.count - visible.count)
    }

    /// One row for each open project with a run in flight, in the order the
    /// projects were read.
    ///
    /// Empty in, empty out — that is what draws no in-flight section at all,
    /// no divider and no empty row. A row names its project only when more than
    /// one project is running: with a single run in flight the popover's one row
    /// is unambiguous, and naming the folder there is noise.
    static func runningRows(_ items: [ActiveOrchestratorTracker.InFlightItem]) -> [RunningRow] {
        let namesProject = items.count > 1
        return items.map {
            RunningRow(item: $0, projectName: namesProject ? $0.projectName : nil)
        }
    }

    /// An in-flight row as the popover draws it: the item, and the project's
    /// name when the row has to say which project it is about.
    struct RunningRow: Identifiable, Equatable, Sendable {
        let item: ActiveOrchestratorTracker.InFlightItem
        let projectName: String?

        /// A project runs at most one item at a time, so its path identifies
        /// the row — and survives the item changing under it.
        var id: String { item.projectPath }
    }

    /// The menu bar extra's own glyph: the filled mark while anything waits, the
    /// plain one otherwise.
    static func labelSymbol(waiting: Bool) -> String {
        waiting ? "building.2.fill" : "building.2"
    }

    /// The word an agent row wears for its state — plain English, not the enum
    /// case, so an agent blocked on a question reads "waiting on you" rather
    /// than "waitingForHuman". No default case: a new state is a compile error
    /// here, not a raw string in the menu bar.
    static func stateLabel(_ state: Agent.AgentState) -> String {
        switch state {
        case .idle: return "idle"
        case .working: return "working"
        case .waitingForHuman: return "waiting on you"
        case .crashed: return "stopped"
        }
    }
}

struct MenuBarView: View {
    let tracker: ActiveOrchestratorTracker

    @Environment(\.openWindow) private var openWindow

    private var orchestrator: Orchestrator? { tracker.orchestrator }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "building.2")
                Text("Kiteloop")
                    .font(.headline)
            }
            .padding(.bottom, 4)

            Divider()

            if let orchestrator, !orchestrator.agents.isEmpty {
                ForEach(orchestrator.agents) { agent in
                    HStack {
                        Circle()
                            .fill(colorForState(agent.state))
                            .frame(width: 8, height: 8)
                        Text(agent.name)
                        Spacer()
                        Text(MenuBarAttention.stateLabel(agent.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No active agents")
                    .foregroundStyle(.secondary)
            }

            waitingSection

            inFlightSection

            Divider()

            Button("Open Kiteloop") {
                showMainWindow()
            }

            Button("Quit Kiteloop") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 200)
        // This scene sits outside the window, so the window's action doesn't
        // reach it. The request is posted to the tracker instead and the window
        // routes it — see `ActiveOrchestratorTracker.openItemRequest`.
        .environment(\.openItem, OpenItemAction { itemID, project in
            tracker.requestOpenItem(itemID, in: project)
            showMainWindow()
        })
    }

    /// Brings the main window forward, opening one when every window is
    /// closed — without it a posted request has no window to drain it. A
    /// `WindowGroup` opened by id makes a new window each time, so one already
    /// on screen (or in the Dock) is raised instead.
    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let existing = NSApplication.shared.windows.first { window in
            (window.identifier?.rawValue.hasPrefix(MainWindow.windowID) ?? false)
                && (window.isVisible || window.isMiniaturized)
        }
        guard let existing else {
            openWindow(id: MainWindow.windowID)
            return
        }
        existing.deminiaturize(nil)
        existing.makeKeyAndOrderFront(nil)
    }

    /// What the fleet is actually working on. The menu bar said which agents
    /// were busy and never what they were busy *with*, so the one surface
    /// visible with every window closed couldn't name the item — let alone open
    /// it. One row per running project, not the active project's run alone: a
    /// run in a project you are not looking at was invisible here.
    @ViewBuilder
    private var inFlightSection: some View {
        let rows = MenuBarAttention.runningRows(tracker.inFlightItems)
        if !rows.isEmpty {
            Divider()
            ForEach(rows) { row in
                ItemLink(row.item.id, in: .path(row.item.projectPath)) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text(row.item.headline)
                            .font(.caption)
                            .lineLimit(1)
                        if let name = row.projectName {
                            Text(name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// What has stopped and is waiting on you, across every open project — a
    /// count, `WaitingOnYou.summary` beneath it, and then the gates themselves,
    /// each a row that opens where it is cleared. Nothing at all when nothing
    /// is waiting.
    @ViewBuilder
    private var waitingSection: some View {
        if let headline = MenuBarAttention.headline(waiting: tracker.waiting.rows.count) {
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(headline)
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                Text(tracker.waiting.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                waitingRows
            }
            .accessibilityIdentifier("menu-bar-waiting")
        }
    }

    /// The gates under the headline, capped by
    /// `MenuBarAttention.visibleWaitingRows`. A click posts the row to the
    /// tracker and the window opens it the way the Waiting on you drawer does.
    @ViewBuilder
    private var waitingRows: some View {
        let visible = MenuBarAttention.visibleWaitingRows(tracker.waiting.rows)
        ForEach(visible.rows) { row in
            Button {
                tracker.requestOpenGate(row)
                showMainWindow()
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: waitingIcon(row.gate))
                        .font(.caption)
                        .foregroundStyle(waitingTint(row.gate))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.title)
                            .font(.caption)
                            .lineLimit(1)
                        Text(row.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menu-bar-waiting-row-\(row.id)")
        }
        if visible.overflow > 0 {
            Text("+\(visible.overflow) more")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// The Waiting on you drawer's glyph for each kind of gate, so a gate looks
    /// the same wherever it is read.
    private func waitingIcon(_ gate: WaitingOnYou.Row.Gate) -> String {
        switch gate {
        case .approval: "hand.raised"
        case .question: "questionmark.circle"
        case .stale: "clock.badge.exclamationmark"
        }
    }

    private func waitingTint(_ gate: WaitingOnYou.Row.Gate) -> Color {
        switch gate {
        case .approval: .orange
        case .question: .blue
        case .stale: .yellow
        }
    }

    private func colorForState(_ state: Agent.AgentState) -> Color {
        switch state {
        case .idle: return .green
        case .working: return .orange
        case .waitingForHuman: return .yellow
        case .crashed: return .red
        }
    }
}
