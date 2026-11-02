import Foundation

@Observable
@MainActor
final class TraceViewModel {
    private let store: TraceStoring
    /// Names an agent id as the team named it; read at call time, so an agent
    /// hired after the pane opened is named too.
    private let agentName: (String) -> String
    /// Names a CLI session id by the title of the chat it belongs to, or nil
    /// for one no chat carries; read at call time, as `agentName` is.
    private let chatTitle: (String) -> String?

    var sessions: [TraceSession] = []
    var selectedSession: TraceSession?
    var spans: [TraceSpan] = []
    var isLoading = false
    /// A filter that hides the selected session clears it and its spans, for
    /// the same reason `refresh()` does.
    var filterAgent: String? {
        didSet {
            guard let selected = selectedSession,
                  !filteredSessions.contains(where: { $0.id == selected.id }) else { return }
            selectedSession = nil
            spans = []
        }
    }

    init(store: TraceStoring,
         agentName: @escaping (String) -> String = { $0 },
         chatTitle: @escaping (String) -> String? = { _ in nil }) {
        self.store = store
        self.agentName = agentName
        self.chatTitle = chatTitle
    }

    /// The label the pane shows for an agent id: its team name, or the id
    /// itself for an agent no longer on the team.
    func label(forAgentID id: String) -> String {
        agentName(id)
    }

    /// The title of the chat a session was recorded in, or nil when no chat
    /// carries its CLI session id or that chat's title is blank — an older id
    /// from before a resume, or a deleted chat, reads as it always did.
    func chatTitle(forSessionID id: String) -> String? {
        guard let title = chatTitle(id)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }
        return title
    }

    func loadSessions() async {
        isLoading = true
        sessions = await store.allSessions()
        isLoading = false
    }

    /// Re-reads the store so the pane keeps up while it is on screen: a session
    /// that started after it appeared joins the list, and the turns of the
    /// session being looked at grow.
    ///
    /// The selection survives a re-read whose filtered list still carries its
    /// id, and is cleared — with its spans — by one that does not, so the detail
    /// pane never shows a session the list no longer offers.
    func refresh() async {
        sessions = await store.allSessions()
        guard let selected = selectedSession else { return }
        guard let reloaded = filteredSessions.first(where: { $0.id == selected.id }) else {
            selectedSession = nil
            spans = []
            return
        }
        await selectSession(reloaded)
    }

    func selectSession(_ session: TraceSession) async {
        selectedSession = session
        let agentSpans = await store.loadSpans(for: session.agentID)
        spans = agentSpans.filter { $0.sessionID == session.id }
            .sorted { $0.startTime < $1.startTime }
    }

    func loadSpansForToday() async {
        isLoading = true
        spans = await store.loadSpans(for: Date())
        isLoading = false
    }

    var filteredSessions: [TraceSession] {
        guard let agent = filterAgent, !agent.isEmpty else { return sessions }
        return sessions.filter { $0.agentID == agent }
    }

    var uniqueAgents: [String] {
        Array(Set(sessions.map(\.agentID))).sorted {
            label(forAgentID: $0).localizedStandardCompare(label(forAgentID: $1)) == .orderedAscending
        }
    }
}
