import KiteloopCore
import SwiftUI

/// The Routines page: every prompt sent to an agent on a schedule, in every
/// project, grouped under one heading per project — the tab's own project
/// first — each on a card with its arming switch, when it next falls and how
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
    /// The open projects' roots, in tab order.
    var openRoots: [URL] = []
    /// Each open project's team agents by name, keyed by its root.
    var agentsByRoot: [URL: [String]] = [:]

    @State private var editing: RoutineEditorSheet.Target?
    @State private var pendingDelete: Routine?
    @State private var failure: String?

    private var sections: [RoutineSection] {
        Self.sections(in: runner.routines, openRoots: openRoots, current: projectRoot)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if Self.showsEmptyState(sections) { emptyState } else { list }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("routines-page")
        .sheet(item: $editing) { target in
            RoutineEditorSheet(target: target, agentNames: editorAgents(for: target.routine)) { save($0, editing: target.routine) }
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
                Text(Self.subtitle(for: sections.flatMap(\.routines)))
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
            VStack(alignment: .leading, spacing: KiteloopTokens.Spacing.lg) {
                ForEach(sections) { section in
                    Text(section.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, KiteloopTokens.Spacing.md)
                        .accessibilityIdentifier("routines-section-\(section.id)")
                    ForEach(section.routines) { routine in card(for: routine) }
                }
            }
            .frame(maxWidth: 820)
            .padding(KiteloopTokens.Spacing.xl + KiteloopTokens.Spacing.md)
            .frame(maxWidth: .infinity)
        }
    }

    private func card(for routine: Routine) -> some View {
        RoutineCard(
            routine: routine,
            next: runner.next(for: routine),
            runs: runner.runs.filter { $0.routine == routine.id },
            setArmed: { arm(routine, $0) },
            runNow: { _ = runner.runNow(routine.id) },
            edit: { editing = .existing(routine) },
            delete: { pendingDelete = routine })
    }

    /// The agents the editor offers: the tab's team for a new routine, the
    /// team of the routine's own project when it is open, and the routine's
    /// own agent alone when its project is not.
    private func editorAgents(for routine: Routine?) -> [String] {
        guard let routine else { return agentNames }
        if !Self.routines(in: [routine], for: projectRoot).isEmpty { return agentNames }
        let root = openRoots.first { !Self.routines(in: [routine], for: $0).isEmpty }
        return root.flatMap { agentsByRoot[$0] } ?? [routine.agent]
    }

    // MARK: - Changes

    private func save(_ draft: RoutineDraft, editing existing: Routine?) {
        let id = RoutineDraft.id(forName: draft.name, taken: Set(runner.routines.map(\.id)))
        attempt { try runner.put(draft.routine(id: id, project: existing?.project ?? projectRoot.lastPathComponent,
                                          existing: existing)) }
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

    /// Every routine on file in one section per project: the project at
    /// `current` first — kept even when it has none, so its New Routine has a
    /// place — then the other open projects in tab order, then the routines
    /// naming a project not open. Each routine is in exactly one section, in
    /// file order.
    static func sections(in routines: [Routine], openRoots: [URL], current: URL) -> [RoutineSection] {
        let currentPath = current.standardizedFileURL.path
        let others = openRoots.filter { $0.standardizedFileURL.path != currentPath }
        var remaining = routines
        var sections: [RoutineSection] = []
        for root in [current] + others {
            let mine = Self.routines(in: remaining, for: root)
            let ids = Set(mine.map(\.id))
            remaining.removeAll { ids.contains($0.id) }
            if root == current || !mine.isEmpty {
                sections.append(RoutineSection(title: root.lastPathComponent, root: root, routines: mine))
            }
        }
        if !remaining.isEmpty {
            sections.append(RoutineSection(title: "Projects not open", root: nil, routines: remaining))
        }
        return sections
    }

    /// The empty state shows only when no project has a routine.
    static func showsEmptyState(_ sections: [RoutineSection]) -> Bool {
        sections.allSatisfy(\.routines.isEmpty)
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

/// One project's routines on the Routines page; `root` is nil for the group
/// of routines naming a project not open in Kiteloop.
struct RoutineSection: Identifiable, Equatable {
    let title: String
    let root: URL?
    let routines: [Routine]

    var id: String { root?.path(percentEncoded: false) ?? "not-open" }
}
