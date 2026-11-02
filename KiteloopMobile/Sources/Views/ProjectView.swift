import SwiftUI

/// One project, the way a person checks on it from a phone: is it running and
/// on what, does it need me, and the one lever that changes that; then the
/// queue and the agents, each one tap away. The chip row at the top switches
/// projects; the line under it says whether the screen is fresh, refreshing,
/// or failed — and what to do about it. Refreshes every 10 s while it is up.
struct ProjectView: View {
    @Bindable var connection: ConnectionStore
    @State private var model = ProjectViewModel()
    @State private var gates = NowViewModel()
    @State private var agents = AgentsViewModel()
    @State private var hiring = false
    @State private var hireName = ""
    @State private var hireModel = ""

    private var client: ControlClient { ControlClient(baseURL: connection.baseURL, token: connection.token) }
    private var projectGates: [NowViewModel.Gate] { gates.gates.filter { $0.project == model.selected } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProjectChipRow(projects: model.projects, selected: $model.selected) { project, before in
                    Task { await model.reorder(client, project: project, before: before) }
                }
                RefreshStatusBar(state: model.freshness) { Task { await refreshAll() } }
                if let banner = model.compatibility.banner(macName: connection.current?.name ?? "this Mac") {
                    Label(banner, systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("api-version-banner")
                }
                Divider()
                content
            }
            .navigationTitle(model.selected.isEmpty ? "Projects" : model.selected)
            .onChange(of: model.selected) { Task { await refreshAll() } }
            .task {
                while !Task.isCancelled {
                    await refreshAll()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .onChange(of: PushRegistration.shared.pendingRoute) { follow(PushRegistration.shared.pendingRoute) }
            .onAppear { follow(PushRegistration.shared.pendingRoute) }
            .navigationDestination(isPresented: Binding(get: { agents.chatAgent != nil }, set: { if !$0 { agents.close() } })) {
                ChatView(model: agents, client: client)
            }
        }
    }

    /// The list, or — when nothing has ever loaded — a plain statement of
    /// why, so an empty screen is never a mystery.
    @ViewBuilder
    private var content: some View {
        if model.projects.isEmpty {
            if let problem = model.freshness.problem {
                ContentUnavailableView(problem.title, systemImage: "wifi.exclamationmark", description: Text(problem.advice))
            } else if model.freshness.phase == .refreshing {
                ContentUnavailableView("Connecting to the Mac…", systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text(connection.baseURL))
            } else {
                ContentUnavailableView("No projects open", systemImage: "folder",
                                       description: Text("Open a project in Kiteloop on the Mac and it appears here."))
            }
        } else {
            projectList
        }
    }

    private var projectList: some View {
        List {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
            Section {
                StatusCard(state: model.state, run: model.autopilot?.run,
                           spend: model.autopilot?.sessionSpendUSD, cap: model.autopilot?.sessionCostCapUSD,
                           acting: model.acting) { Task { await model.toggle(client) } }
            }
            if let gate = model.project?.gate, let item = gate.item {
                Section("Merge gate") {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Verifying the merged tree").font(.callout)
                            Text(item).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            if !projectGates.isEmpty {
                Section("Waiting on you") {
                    ForEach(projectGates) { gate in
                        NavigationLink(value: gate) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gate.item.title ?? gate.item.id).font(.callout)
                                    if gate.item.gate?.state == "refused", let reason = gate.item.gate?.reason {
                                        Text("Refused: \(reason)").font(.caption2).foregroundStyle(.red).lineLimit(2)
                                    }
                                }
                            } icon: {
                                Image(systemName: gate.item.gate?.state == "refused" ? "xmark.octagon.fill" : "hand.raised.fill")
                                    .foregroundStyle(gate.item.gate?.state == "refused" ? .red : .orange)
                            }
                        }
                    }
                }
            }
            queueSection
            agentsSection
            Section("Workspace") {
                NavigationLink(value: WorkspaceDestination.changes) {
                    Label("Uncommitted changes", systemImage: "plusminus")
                }
                NavigationLink(value: WorkspaceDestination.files) {
                    Label("Files", systemImage: "folder")
                }
                NavigationLink(value: WorkspaceDestination.preview) {
                    Label("Web preview", systemImage: "safari")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: NowViewModel.Gate.self) { gate in
            GateReviewView(model: gates, client: client, gate: gate)
        }
        .navigationDestination(for: String.self) { project in
            QueueListView(connection: connection, project: project)
        }
        .navigationDestination(for: WorkspaceDestination.self) { destination in
            switch destination {
            case .changes: ChangesView(project: model.selected, client: client)
            case .files: FileView(project: model.selected, path: "", client: client)
            case .preview: PreviewView(project: model.selected, client: client)
            }
        }
        .navigationDestination(for: FileRoute.self) { route in
            FileView(project: model.selected, path: route.path, client: client)
        }
        .refreshable { await refreshAll() }
    }

    /// A tapped notification: its project, and the agent's chat when it was about one.
    private func follow(_ route: PushRoute?) {
        guard let route else { return }
        PushRegistration.shared.pendingRoute = nil
        model.selected = route.project
        agents.project = route.project
        guard route.opensChat, let agent = route.agent else { return }
        agents.open(client, agent: agents.agents.first { $0.id == agent } ?? AgentInfo(id: agent))
    }

    private func refreshAll() async {
        await model.refresh(client)
        agents.project = model.selected
        await agents.refresh(client)
        await gates.refresh(client)
    }

    private var queueSection: some View {
        Section("Queue") {
            NavigationLink(value: model.selected) {
                if let queue = model.project?.queue {
                    HStack(spacing: 14) {
                        readyCount(queue)
                        count(queue.active ?? 0, "running", .green)
                        count(queue.awaitingApproval ?? 0, "at gates", .orange)
                        count(queue.blocked ?? 0, "blocked", .red)
                    }
                } else {
                    Text("Open the queue")
                }
            }
        }
    }

    /// "1 of 5 can start" when the Mac says fewer can run than are ready;
    /// otherwise — or from an older Mac without `runnable` — the ready count.
    @ViewBuilder
    private func readyCount(_ queue: QueueCounts) -> some View {
        let ready = queue.ready ?? 0
        if let runnable = queue.runnable, runnable < ready {
            count(runnable, "of \(ready) can start", .blue)
        } else {
            count(ready, "ready", .blue)
        }
    }

    private func count(_ n: Int, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(n)").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(n == 0 ? .secondary : tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Each agent's icon comes alive while it works; a tap opens the conversation.
    private var agentsSection: some View {
        Section("Agents") {
            if agents.agents.isEmpty {
                Text("No agents hired for this project yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(agents.agents) { agent in
                Button { agents.open(client, agent: agent) } label: { agentRow(agent) }
            }
            Button {
                hireName = ""
                hireModel = ""
                hiring = true
            } label: {
                Label("Hire an agent", systemImage: "person.badge.plus")
            }
            .accessibilityIdentifier("hire-agent")
        }
        .alert("Hire an agent", isPresented: $hiring) {
            TextField("Name", text: $hireName)
            TextField("Model (optional)", text: $hireModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Hire") { Task { _ = await agents.hire(client, name: hireName, model: hireModel) } }
                .disabled(hireName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Joins \(model.selected) on the Mac. Without a model it takes the project's.")
        }
    }

    private func agentRow(_ agent: AgentInfo) -> some View {
        let working = agent.state == "working"
        return HStack(spacing: 10) {
            Image(systemName: working ? "circle.hexagongrid.fill" : "person.crop.circle")
                .foregroundStyle(working ? .green : .secondary)
                .symbolEffect(.variableColor.iterative.reversing, isActive: working)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name ?? agent.id).font(.callout).foregroundStyle(.primary)
                Text(agent.model ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(agent.state ?? "").font(.caption2).foregroundStyle(working ? .green : .secondary)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// The project's Workspace section: its working tree and its web preview.
enum WorkspaceDestination: Hashable {
    case changes, files, preview
}
