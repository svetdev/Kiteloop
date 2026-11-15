import KiteloopCore
import SwiftUI

/// The project's Routines page: every prompt this project sends an agent on a
/// schedule, each on a card with its arming switch, when it next falls and how
/// it last went — and the place a routine is made, changed and removed.
///
/// Routines used to be a strip on the Autopilot tab that could arm one and run
/// it, with making one left to the control API or `~/.kiteloop/routines.json`.
/// They are not the autopilot's — a routine is a chat turn, not a backlog run —
/// so they have a page of their own.
struct RoutinesView: View {
    let runner: RoutineRunner
    let projectRoot: URL
    /// The team's agents by name, which is how a routine names its agent.
    let agentNames: [String]

    @State private var editing: RoutineEditorSheet.Target?
    @State private var pendingDelete: Routine?
    @State private var failure: String?

    private var routines: [Routine] { Self.routines(in: runner.routines, for: projectRoot) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if routines.isEmpty { emptyState } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("routines-page")
        .sheet(item: $editing) { target in
            RoutineEditorSheet(target: target, agentNames: agentNames) { save($0, editing: target.routine) }
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { routine in
            Button("Delete Routine", role: .destructive) { delete(routine) }
        } message: { _ in
            Text("Its schedule and prompt are removed. Its past runs stay in the ledger.")
        }
        .alert("The routine was not saved", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: KiteloopTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.xs) {
                Text("Routines").font(.title2.weight(.semibold))
                Text(Self.subtitle(for: routines))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            newButton
        }
        .padding(.horizontal, KiteloopTokens.Spacing.xl + KiteloopTokens.Spacing.md)
        .padding(.vertical, KiteloopTokens.Spacing.xl)
    }

    private var newButton: some View {
        Button { editing = .new(agent: agentNames.first ?? "") } label: {
            Label("New Routine", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .help("Schedule a prompt for one of this project's agents")
        .accessibilityIdentifier("routines-new-button")
    }

    private var emptyState: some View {
        VStack(spacing: KiteloopTokens.Spacing.lg) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No routines yet").font(.headline)
            Text("A routine sends a prompt to one of this project's agents on a schedule — a morning brief, a poll of open pull requests, a Friday review.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            newButton
        }
        .padding(KiteloopTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("routines-empty-state")
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: KiteloopTokens.Spacing.lg) {
                ForEach(routines) { routine in
                    RoutineCard(
                        routine: routine,
                        next: runner.next(for: routine),
                        runs: runner.runs.filter { $0.routine == routine.id },
                        setArmed: { arm(routine, $0) },
                        runNow: { _ = runner.runNow(routine.id) },
                        edit: { editing = .existing(routine) },
                        delete: { pendingDelete = routine })
                }
            }
            .frame(maxWidth: 820)
            .padding(KiteloopTokens.Spacing.xl + KiteloopTokens.Spacing.md)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Changes

    private func save(_ draft: RoutineDraft, editing existing: Routine?) {
        let id = RoutineDraft.id(forName: draft.name, taken: Set(runner.routines.map(\.id)))
        attempt { try runner.put(draft.routine(id: id, project: projectRoot.lastPathComponent, existing: existing)) }
    }

    private func arm(_ routine: Routine, _ armed: Bool) {
        attempt { try runner.setArmed(routine.id, armed) }
    }

    private func delete(_ routine: Routine) {
        attempt { _ = try runner.remove(routine.id) }
    }

    /// Makes a change to the routines file, and says so when the file could
    /// not be written rather than leaving the page showing what was asked for.
    private func attempt(_ change: () throws -> Void) {
        do { try change() } catch { failure = error.localizedDescription }
    }

    // MARK: - Words

    /// The routines that name the project at `root` — by its folder's name, as
    /// the control API names a project, or by its path.
    static func routines(in routines: [Routine], for root: URL) -> [Routine] {
        let path = root.path(percentEncoded: false)
        return routines.filter {
            $0.project == root.lastPathComponent || KiteloopProject.isSamePath($0.project, path)
        }
    }

    /// The line under the page's title: what a routine is while there are
    /// none, and how many are armed once there are.
    static func subtitle(for routines: [Routine]) -> String {
        guard !routines.isEmpty else { return "Prompts sent to an agent on a schedule." }
        let armed = routines.filter(\.armed).count
        let count = routines.count == 1 ? "1 routine" : "\(routines.count) routines"
        return armed == 0 ? "\(count), none armed" : "\(count), \(armed) armed"
    }
}
