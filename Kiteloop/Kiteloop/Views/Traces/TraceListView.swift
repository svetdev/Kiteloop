import KiteloopCore
import SwiftUI

struct TraceListView: View {
    @Bindable var viewModel: TraceViewModel

    var body: some View {
        HSplitView {
            sessionSidebar
                .frame(minWidth: 240, idealWidth: 300)
            traceDetail
                .frame(minWidth: 400)
        }
        .task {
            // The pane used to be a snapshot taken when it appeared: a session
            // that started a moment later, and the turns of the session on
            // screen, showed up only after the console was closed and reopened.
            // The console builds this view when the tab is shown and tears it
            // down when it is not, so SwiftUI's cancellation is what stops the
            // loop — no timer, no observer.
            await viewModel.loadSessions()
            guard !UITestingSupport.isUnitTesting else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                await viewModel.refresh()
            }
        }
    }

    private static let refreshInterval: Duration = .seconds(3)

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
                .padding(8)

            if let empty = Self.sidebarEmptyCopy(hasSessions: !viewModel.sessions.isEmpty) {
                PanelEmptyState(icon: "chart.bar.xaxis", title: empty.title, message: empty.message)
            } else {
                sessionList
            }
        }
    }

    private var sessionList: some View {
        List(viewModel.filteredSessions, selection: Binding(
            get: { viewModel.selectedSession?.id },
            set: { id in
                if let session = viewModel.filteredSessions.first(where: { $0.id == id }) {
                    Task { await viewModel.selectSession(session) }
                }
            }
        )) { session in
            SessionRow(
                session: session,
                agentName: viewModel.label(forAgentID:),
                chatTitle: viewModel.chatTitle(forSessionID: session.id)
            )
                .tag(session.id)
        }
    }

    /// What the session column says in place of the list, or nil when there is
    /// a session to list. An empty list says why it is empty and what fills it.
    static func sidebarEmptyCopy(hasSessions: Bool) -> (title: String, message: String)? {
        guard !hasSessions else { return nil }
        return ("No turns recorded yet",
                "A session appears here once an agent answers a message in this project.")
    }

    /// What the detail pane says with no session selected — pointing at the
    /// list only when the list has something in it.
    static func detailEmptyCopy(hasSessions: Bool) -> (title: String, message: String) {
        hasSessions
            ? ("No session selected",
               "Choose a session on the left to see its cost, tokens, and duration per turn.")
            : ("Nothing to show yet",
               "Each turn's cost, tokens, and duration show here after an agent replies in this project.")
    }

    private var sidebarHeader: some View {
        HStack(spacing: KiteloopTokens.Spacing.sm) {
            agentFilter
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .help("Re-read sessions now")
        }
    }

    @ViewBuilder
    private var agentFilter: some View {
        Picker("Agent", selection: Binding(
            get: { viewModel.filterAgent ?? "" },
            set: { viewModel.filterAgent = $0.isEmpty ? nil : $0 }
        )) {
            Text("All Agents").tag("")
            ForEach(viewModel.uniqueAgents, id: \.self) { agent in
                Text(viewModel.label(forAgentID: agent)).tag(agent)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var traceDetail: some View {
        if let session = viewModel.selectedSession {
            TraceDetailView(
                session: session,
                spans: viewModel.spans,
                agentName: viewModel.label(forAgentID:),
                chatTitle: viewModel.chatTitle(forSessionID: session.id)
            )
        } else {
            let copy = Self.detailEmptyCopy(hasSessions: !viewModel.sessions.isEmpty)
            PanelEmptyState(icon: "chart.bar.xaxis", title: copy.title, message: copy.message)
        }
    }
}

private struct SessionRow: View {
    let session: TraceSession
    let agentName: (String) -> String
    let chatTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(agentName(session.agentID))
                    .font(.headline)
                Spacer()
                Text(formattedCost)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let chatTitle {
                Text(chatTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack {
                Text(String(count: session.spanCount, noun: "turn"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(session.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var formattedCost: String {
        String(format: "$%.3f", session.totalCost)
    }
}
