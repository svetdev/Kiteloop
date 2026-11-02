import XCTest
import KiteloopCore
@testable import Kiteloop

/// The Traces pane keeps up while it is on screen: `refresh()` re-reads the
/// store, and the session being looked at keeps both its selection and its
/// growing list of turns.
@MainActor
final class TraceViewModelRefreshTests: XCTestCase {

    // MARK: - The session list

    func testSessionAppendedAfterTheFirstReadJoinsTheList() async throws {
        let store = StubTraceStore(sessions: [session("a", spanCount: 1)])
        let viewModel = TraceViewModel(store: store)
        await viewModel.loadSessions()
        XCTAssertEqual(viewModel.sessions.map(\.id), ["a"])

        await store.setSessions([session("a", spanCount: 1), session("b", spanCount: 1)])
        await viewModel.refresh()

        XCTAssertEqual(viewModel.sessions.map(\.id), ["a", "b"], "The new session joins without a reopen")
    }

    func testARefreshLoopPicksUpASessionAppendedWhileItRuns() async throws {
        let store = StubTraceStore(sessions: [session("a", spanCount: 1)])
        let viewModel = TraceViewModel(store: store)
        await viewModel.loadSessions()

        // The shape the pane's `.task` holds open for the view's lifetime.
        let loop = Task {
            while !Task.isCancelled {
                await viewModel.refresh()
                await Task.yield()
            }
        }
        defer { loop.cancel() }

        await store.setSessions([session("a", spanCount: 1), session("b", spanCount: 1)])
        try await eventually("the appended session to reach the pane") {
            viewModel.sessions.map(\.id) == ["a", "b"]
        }
    }

    // MARK: - The selected session

    func testATurnAppendedToTheSelectedSessionAppearsAndTheSelectionHolds() async throws {
        let store = StubTraceStore(
            sessions: [session("a", spanCount: 1)],
            spans: ["agent-a": [span("s1", session: "a", at: 0)]]
        )
        let viewModel = TraceViewModel(store: store)
        await viewModel.loadSessions()
        await viewModel.selectSession(viewModel.sessions[0])
        XCTAssertEqual(viewModel.spans.map(\.id), ["s1"])

        await store.setSessions([session("a", spanCount: 2)])
        await store.setSpans(["agent-a": [span("s2", session: "a", at: 1), span("s1", session: "a", at: 0)]])
        await viewModel.refresh()

        XCTAssertEqual(viewModel.selectedSession?.id, "a", "The selection is unchanged")
        XCTAssertEqual(viewModel.spans.map(\.id), ["s1", "s2"], "The new turn appears, oldest first")
        XCTAssertEqual(viewModel.selectedSession?.spanCount, 2, "The selected session carries the reloaded counts")
    }

    func testARefreshThatNoLongerOffersTheSelectedSessionClearsIt() async throws {
        let store = StubTraceStore(
            sessions: [session("a", spanCount: 1)],
            spans: ["agent-a": [span("s1", session: "a", at: 0)]]
        )
        let viewModel = TraceViewModel(store: store)
        await viewModel.loadSessions()
        await viewModel.selectSession(viewModel.sessions[0])

        await store.setSessions([session("b", spanCount: 1)])
        await viewModel.refresh()

        XCTAssertNil(viewModel.selectedSession, "The detail pane never shows a session the list no longer offers")
        XCTAssertTrue(viewModel.spans.isEmpty)
        XCTAssertEqual(viewModel.sessions.map(\.id), ["b"])
    }

    func testRefreshWithNoSelectionLeavesTheDetailPaneEmpty() async throws {
        let store = StubTraceStore(sessions: [session("a", spanCount: 1)])
        let viewModel = TraceViewModel(store: store)
        await viewModel.loadSessions()

        await viewModel.refresh()

        XCTAssertNil(viewModel.selectedSession)
        XCTAssertTrue(viewModel.spans.isEmpty)
    }

    // MARK: - The agent filter

    func testAFilterThatHidesTheSelectedSessionClearsIt() async throws {
        let viewModel = await viewModelWithSessionASelected()

        viewModel.filterAgent = "agent-b"

        XCTAssertNil(viewModel.selectedSession, "The detail pane never shows a session the list no longer offers")
        XCTAssertTrue(viewModel.spans.isEmpty)
        XCTAssertEqual(viewModel.filteredSessions.map(\.id), ["b"])
    }

    func testAFilterThatStillOffersTheSelectedSessionKeepsIt() async throws {
        let viewModel = await viewModelWithSessionASelected()

        viewModel.filterAgent = "agent-a"
        XCTAssertEqual(viewModel.selectedSession?.id, "a")
        XCTAssertEqual(viewModel.spans.map(\.id), ["s1"])

        viewModel.filterAgent = nil
        XCTAssertEqual(viewModel.selectedSession?.id, "a", "All Agents never clears the selection")
        XCTAssertEqual(viewModel.spans.map(\.id), ["s1"])
    }

    func testARefreshDoesNotReselectASessionTheFilterHides() async throws {
        let viewModel = await viewModelWithSessionASelected()
        viewModel.filterAgent = "agent-b"
        await viewModel.selectSession(viewModel.sessions[0])

        await viewModel.refresh()

        XCTAssertNil(viewModel.selectedSession)
        XCTAssertTrue(viewModel.spans.isEmpty)
    }

    // MARK: - Agent names

    func testAKnownAgentIDIsLabelledWithItsTeamName() async throws {
        let viewModel = await namedViewModel()

        XCTAssertEqual(viewModel.label(forAgentID: "agent-a"), "API Lead")
    }

    func testAnAgentIDNoTeamAgentCarriesIsLabelledWithTheIDItself() async throws {
        let viewModel = await namedViewModel()

        XCTAssertEqual(viewModel.label(forAgentID: "agent-b"), "agent-b")
    }

    func testTheAgentMenuIsSortedByNameAndFilteringStillMatchesTheID() async throws {
        let viewModel = await namedViewModel()

        XCTAssertEqual(viewModel.uniqueAgents, ["agent-b", "agent-a"], "Sorted by the shown name: agent-b before API Lead")
        viewModel.filterAgent = "agent-a"
        try await eventually("the filter to offer agent-a's session alone") {
            viewModel.filteredSessions.map(\.id) == ["a"]
        }
    }

    // MARK: - Helpers

    private func namedViewModel() async -> TraceViewModel {
        let store = StubTraceStore(sessions: [session("a", spanCount: 1), session("b", spanCount: 1)])
        let viewModel = TraceViewModel(store: store, agentName: { $0 == "agent-a" ? "API Lead" : $0 })
        await viewModel.loadSessions()
        return viewModel
    }

    private func viewModelWithSessionASelected() async -> TraceViewModel {
        let store = StubTraceStore(
            sessions: [session("a", spanCount: 1), session("b", spanCount: 1)],
            spans: ["agent-a": [span("s1", session: "a", at: 0)]]
        )
        let viewModel = TraceViewModel(store: store)
        await viewModel.loadSessions()
        await viewModel.selectSession(viewModel.sessions[0])
        XCTAssertEqual(viewModel.selectedSession?.id, "a")
        return viewModel
    }

    private func session(_ id: String, spanCount: Int) -> TraceSession {
        TraceSession(
            id: id,
            agentID: "agent-\(id)",
            date: Date(timeIntervalSince1970: 1_000),
            spanCount: spanCount,
            totalCost: 0.5,
            duration: 12
        )
    }

    private func span(_ id: String, session sessionID: String, at offset: TimeInterval) -> TraceSpan {
        TraceSpan(
            id: id,
            agentID: "agent-\(sessionID)",
            sessionID: sessionID,
            startTime: Date(timeIntervalSince1970: 1_000 + offset),
            endTime: nil,
            type: .turn,
            metadata: [:],
            children: []
        )
    }
}

/// A `TraceStoring` whose answers a test can change between reads, standing in
/// for a store a run is still appending to.
private actor StubTraceStore: TraceStoring {
    private var sessions: [TraceSession]
    private var spansByAgent: [String: [TraceSpan]]

    init(sessions: [TraceSession], spans: [String: [TraceSpan]] = [:]) {
        self.sessions = sessions
        self.spansByAgent = spans
    }

    func setSessions(_ sessions: [TraceSession]) {
        self.sessions = sessions
    }

    func setSpans(_ spans: [String: [TraceSpan]]) {
        self.spansByAgent = spans
    }

    func loadSpans(for date: Date) async -> [TraceSpan] {
        spansByAgent.values.flatMap { $0 }
    }

    func loadSpans(for agentID: String) async -> [TraceSpan] {
        spansByAgent[agentID] ?? []
    }

    func allSessions() async -> [TraceSession] {
        sessions
    }
}
