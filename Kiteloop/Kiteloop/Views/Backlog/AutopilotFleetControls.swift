import KiteloopCore
import SwiftUI

/// This project's two switches on the fleet board — paused and autonomous —
/// on the project's own Autopilot tab, under its title row.
///
/// They are the fleet's controls over one project, and the fleet drawer was
/// the only place both could be reached: someone watching a project's queue
/// had to open the drawer and find its row to park it. Both are the settings
/// they have always been — paused is `.kiteloop/config.json`, written through
/// the board's own `PortfolioSummaryLoader.save`; autonomous is the
/// autopilot's `autonomousWorkEnabled` — so the board and this row cannot
/// come to disagree.
struct AutopilotFleetControls: View {
    @Bindable var autopilot: BacklogAutopilot
    /// What the project's config last said; the file is the truth and is
    /// read again whenever a parking is saved anywhere.
    @State private var paused: Bool

    /// `paused` is what the switch shows before the config has been read —
    /// off in the app; a test hands it the state to draw.
    init(autopilot: BacklogAutopilot, paused: Bool = false) {
        self.autopilot = autopilot
        _paused = State(initialValue: paused)
    }

    static let pausedHelp = "Park this project: no run starts for it — unattended, from its Run button or over the control API — "
        + "until it is unparked. A run already in flight finishes, and items at the approval gate stay there."
    static let autonomousHelp = "Let the fleet pick this project up, and the Planner groom its backlog, when work is run "
        + "unattended. Off: the project is never picked up autonomously — pressing Run here, or starting an item over "
        + "the API, still works exactly as before."

    /// What the row says beside the switches: the one of the two that decides
    /// whether anything starts here by itself.
    static func note(paused: Bool, autonomous: Bool) -> String {
        if paused { return "Paused by hand — no run starts here until it is switched off." }
        return autonomous ? "The fleet may start runs here when work is run unattended."
                          : "Runs start here only when you press Run."
    }

    var body: some View {
        HStack(spacing: KiteloopTokens.Spacing.md) {
            Text("In the fleet")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if autopilot.projectRoot != nil {
                Toggle(isOn: Binding(get: { paused }, set: setPaused)) {
                    Text("Paused").font(.caption).lineLimit(1)
                }
                .help(Self.pausedHelp)
                .accessibilityIdentifier("autopilot-paused-toggle")
            }
            Toggle(isOn: Binding(
                get: { autopilot.autonomousWorkEnabled },
                set: { autopilot.autonomousWorkEnabled = $0 }
            )) {
                Text("Autonomous").font(.caption).lineLimit(1)
            }
            .help(Self.autonomousHelp)
            .accessibilityIdentifier("autopilot-autonomous-work-toggle")
            Text(Self.note(paused: paused, autonomous: autopilot.autonomousWorkEnabled))
                .font(.caption2)
                .foregroundStyle(paused ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("autopilot-fleet-note")
            Spacer(minLength: 0)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityIdentifier("autopilot-fleet-controls")
        .task { await readPaused() }
        .onReceive(NotificationCenter.default.publisher(for: .projectParkingChanged)) { _ in
            Task { await readPaused() }
        }
    }

    /// Shows the switch where it was put, saves it, then shows what the file
    /// says — which is the old value when the write failed.
    private func setPaused(_ newValue: Bool) {
        guard let path = autopilot.projectRoot?.path(percentEncoded: false) else { return }
        paused = newValue
        Task {
            await PortfolioSummaryLoader.park(newValue, projectPath: path)
            await readPaused()
        }
    }

    private func readPaused() async {
        guard let path = autopilot.projectRoot?.path(percentEncoded: false) else { return }
        paused = await Task.detached { KiteloopProject(rootURL: URL(fileURLWithPath: path)).isPaused }.value
    }
}

extension Notification.Name {
    /// Posted on the main actor after a project's paused switch was saved,
    /// from whichever surface saved it; the object is the project's path.
    static let projectParkingChanged = Notification.Name("ai.kasatkin.kiteloop.projectParkingChanged")
}

extension PortfolioSummaryLoader {
    /// Parks or unparks a project and leaves its goal as it is on disk.
    @discardableResult
    nonisolated static func park(_ paused: Bool, projectPath: String) async -> Bool {
        let goal = KiteloopProject(rootURL: URL(fileURLWithPath: projectPath)).goal
        return await save(paused: paused, goal: goal, projectPath: projectPath)
    }
}
