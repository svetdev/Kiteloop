import KiteloopCore
import SwiftUI

/// The fleet's global execution controls: the unattended-running switch with
/// its arming confirm, the one daily autonomy budget, and the ladder. Consent
/// lives on the fleet board below — one row per project, where a roster used
/// to repeat the list.
///
/// Moved here from the Coordinator panel, not rewritten: the Coordinator knows
/// and feeds — awareness and grooming — and the fleet runs. Every gate
/// consulted here is the same one the API consults (`AutonomyArming`).
struct FleetRunControls: View {
    var scheduler: CoordinatorRunScheduler?
    var globalConfigStore: GlobalConfigStore?
    var registry: ControlSessionRegistry?
    var refill: CoordinatorQueueRefill?

    @State private var armingPreview: CoordinatorRunScheduler.ArmingPreview?
    @State private var showLadder = false

    /// Still read — it is what decides whether the switch may arm at all — but no
    /// longer edited here. The ceiling is one number both loops answer to, so it
    /// has a box of its own beside theirs rather than a field inside one of them.
    private var budgetUSD: Double? { globalConfigStore?.config.dailyBudgetUSD }
    private var schedulingRefusal: AutonomyArming.Refusal? {
        AutonomyArming.armScheduling(dailyBudgetUSD: budgetUSD)
    }
    private var switchOperable: Bool {
        (scheduler?.enabled ?? false) || (scheduler != nil && schedulingRefusal == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.sm) {
            AutonomyLoopSectionHeader(title: "Unattended running", icon: "gauge")

            Toggle("Run work unattended", isOn: Binding(
                get: { scheduler?.enabled ?? false },
                set: { newValue in
                    if newValue, scheduler?.enabled == false {
                        armingPreview = scheduler?.armingPreview()
                    } else {
                        scheduler?.enabled = newValue
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
            .disabled(!switchOperable)
            .accessibilityIdentifier("fleet-scheduling-toggle")
            .help("Whether the fleet's scheduler starts runs by itself, for projects with the autonomous column switched on in the board below.")
            .popover(isPresented: Binding(
                get: { armingPreview != nil },
                set: { if !$0 { armingPreview = nil } }
            )) {
                if let preview = armingPreview {
                    armingConfirmSurface(preview)
                }
            }

            if let scheduler {
                Stepper(value: Binding(get: { scheduler.maxConcurrentRuns },
                                       set: { scheduler.maxConcurrentRuns = $0 }),
                        in: CoordinatorRunScheduler.concurrentRunsRange) {
                    Text("Runs at once: \(scheduler.maxConcurrentRuns)").font(.caption).monospacedDigit()
                }
                .controlSize(.mini)
                .accessibilityIdentifier("fleet-max-concurrent-runs-stepper")
                .help("How many autonomous runs the fleet may have in flight at once, across projects — each project still runs one at a time. Every run is a worker and a reviewer session plus that project's builds, so raise it as far as the machine has room.")
            }
            if scheduler != nil, !(scheduler?.enabled ?? false), let refusal = schedulingRefusal {
                caption(refusal.message)
            }

            if refill != nil, registry != nil {
                Button {
                    showLadder = true
                } label: {
                    Label("Autonomy, rung by rung…", systemImage: "stairs")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .controlSize(.mini)
                .accessibilityIdentifier("fleet-autonomy-ladder-button")
                .popover(isPresented: $showLadder) {
                    if let refill {
                        AutonomyLadderView(rungs: AutonomyLadder.assess(.capture(
                            registry: registry, refill: refill,
                            scheduler: scheduler, store: globalConfigStore)))
                    }
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What one opted-in project says under its name on the confirm surface.
    enum ArmingProjectLine: Equatable {
        /// No Ready item at all.
        case nothingRunnable(String)
        /// Ready items, none of which can start: the note alone, so titles
        /// nothing will run are never shown as what runs next.
        case noneCanStart(String)
        /// The queue head, under how many Ready items can start — no count
        /// when the queue was never measured, rather than a guessed one.
        case queue(startable: String?, titles: [String])
    }

    static func armingLine(_ project: CoordinatorRunScheduler.ArmingPreview.Project) -> ArmingProjectLine {
        if project.nextItems.isEmpty {
            return .nothingRunnable("nothing runnable right now — the grooming loop feeds it")
        }
        if project.startable == 0 {
            return .noneCanStart("nothing here can start right now (0 of \(project.readyCount) ready) — check the project's queue line")
        }
        return .queue(startable: project.startable.map { "\($0) of \(project.readyCount) ready can start" },
                      titles: project.nextItems)
    }

    /// One opted-in project on the confirm surface: its name over `armingLine`.
    private func armingProjectPreview(_ project: CoordinatorRunScheduler.ArmingPreview.Project) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name).font(.caption).bold()
            switch Self.armingLine(project) {
            case .nothingRunnable(let note):
                Text(note)
                    .font(.caption2).foregroundStyle(.tertiary)
            case .noneCanStart(let note):
                Text(note)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .queue(let startable, let titles):
                armingQueueHead(startable: startable, titles: titles)
            }
        }
    }

    @ViewBuilder
    private func armingQueueHead(startable: String?, titles: [String]) -> some View {
        if let startable {
            Text(startable)
                .font(.caption2).foregroundStyle(.secondary)
        }
        ForEach(titles, id: \.self) { title in
            Text("· \(title)").font(.caption2).lineLimit(1)
        }
    }

    /// The same consent-with-the-facts surface the Coordinator panel used to
    /// hold — the opted-in projects, their queue heads, and the ceiling.
    private func armingConfirmSurface(_ preview: CoordinatorRunScheduler.ArmingPreview) -> some View {
        VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
            Text("Run work unattended?").font(.callout).bold()
            if let budget = budgetUSD {
                Text("Daily ceiling: $\(budget, specifier: "%.2f") across the portfolio.")
                    .font(.caption)
            }
            if preview.projects.isEmpty {
                Text("No project is set up for autonomous work yet — switch one on in the autonomous column of the board below. Arming now starts nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Opted-in projects and what would run next, in queue order:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(preview.projects) { project in
                    armingProjectPreview(project)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { armingPreview = nil }
                    .controlSize(.small)
                Button("Arm") {
                    scheduler?.enabled = true
                    armingPreview = nil
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("fleet-arming-confirm")
            }
        }
        .padding(KiteloopTokens.Spacing.md)
        .frame(minWidth: 300, maxWidth: 380)
    }
}
