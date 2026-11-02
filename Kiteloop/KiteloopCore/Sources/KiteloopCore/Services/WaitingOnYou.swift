import Foundation

/// Everything across every open project that only a person can clear or has
/// only a person to notice, as one list: items parked at the approval gate,
/// agents holding a question nobody has answered, and open items
/// `StaleItemSweep` finds nothing has touched in a while.
///
/// The cross-project "needs you" strip lives on the start screen, which is the
/// one screen that is *not* up while anybody is working — with a tab open the
/// question "what is waiting on me right now, across everything" had no single
/// answer, and finding out meant visiting each project in turn. This is that
/// answer, drawn in a drawer the sidebar footer opens.
///
/// Two properties are load-bearing:
///
/// * **A row exists because the gate does, not because a notice does.** The
///   inbox records that a gate opened, and the surfaces that close one resolve
///   its notice — `resolveApprovals` when an item is approved, `resolveQuestions`
///   when an agent's question is answered — but a notice can still outlive its
///   gate: one closed in a launch that ended before this one, or through a path
///   that never reached the store. A list built from those notices alone would
///   keep naming work that is finished, which is the one thing this list must
///   not do. So each row is a *live* gate — an item the backlog has at
///   `awaiting-approval`, an agent whose `ask_human` is still unanswered — and
///   the pending notice beside it supplies only the wording and the clock. Clear
///   the gate and the row goes, whatever the inbox still holds; dismiss the
///   notice and the row stays, because the gate is still there.
/// * **Reading it cannot do anything.** It holds values, not the sessions they
///   were read from, so there is no path from drawing the drawer to approving an
///   item or answering an agent. Rows carry where to go; the window does the
///   going.
package struct WaitingOnYou: Equatable, Sendable {

    /// One thing waiting on a person, and where they go to deal with it.
    package struct Row: Equatable, Sendable, Identifiable {

        /// What kind of gate this is — which decides both the words and the
        /// destination, and nothing else about the row.
        package enum Gate: Equatable, Sendable {
            /// An item at `awaiting-approval`. Approve/Reject live on the
            /// project's Autopilot panel.
            case approval(itemID: String)
            /// An agent's unanswered `ask_human`. The answer is typed into that
            /// agent's chat.
            case question(agentID: String)
            /// An open item `StaleItemSweep` still finds untouched past its
            /// window. Not a gate a human clears — there is no approve or
            /// answer for it — but the same drawer names it, since it is the
            /// same question: what does only a person here move forward. The
            /// row goes to the item's own page.
            case stale(itemID: String)
        }

        /// Keyed on the gate rather than on the notice: the notice can be
        /// dismissed out from under a gate that is still open, and a row whose
        /// identity changed underneath it is a row SwiftUI redraws from scratch
        /// mid-scroll.
        package let id: String
        /// The canonical project id — what the window switches tabs by.
        package let projectID: String
        /// The project's folder name, which is how it is named on screen.
        package let projectName: String
        package let projectPath: String
        package let gate: Gate
        /// What is waiting: the item's title, or the notice's ("Ada needs input").
        package let title: String
        /// The gate's own words — the notice's body. Nil where the notice is
        /// gone, or carried none.
        package let detail: String?
        /// When the notice was raised. Nil where the gate has outlived its
        /// notice — see `rows`, which sorts those first for exactly that reason.
        package let since: Date?
        /// For an `.approval` row: how many files conflict if the branch were
        /// merged onto the base right now. Nil for a clean or unchecked branch,
        /// and always nil for a `.question` row.
        package let staleFileCount: Int?
        /// The merge gate's refusal, verbatim, for an approval row whose gate
        /// has already run and said no — nil while the gate is waiting on a
        /// person or still verifying. Twenty-four refused merges sat in this
        /// drawer on 2026-09-12 reading exactly like items needing a decision;
        /// the row now says which it is.
        package let gateRefusal: String?
        /// For a `.question` row: the asking agent's display name. The gate
        /// keeps the id, which is what the chat is opened by; this is only
        /// what the row says. Nil for the other kinds.
        package let agentName: String?

        /// The row's second line: what it is, and where.
        package var subtitle: String {
            switch gate {
            case .approval(let itemID):
                let base = "\(itemID) · \(projectName)"
                let refused = gateRefusal == nil ? "" : " · refused at the gate"
                guard let staleFileCount, staleFileCount > 0 else { return base + refused }
                let files = staleFileCount == 1 ? "file" : "files"
                return "\(base) · stale · \(staleFileCount) \(files)\(refused)"
            case .question(let agentID): return "\(agentName ?? agentID) · \(projectName)"
            case .stale(let itemID): return "\(itemID) · \(projectName)"
            }
        }

        /// The memberwise init, spelled out: a `package` type's synthesised one is
        /// internal to the package, and the app constructs this.
        package init(id: String, projectID: String, projectName: String, projectPath: String, gate: Gate, title: String, detail: String?, since: Date?, staleFileCount: Int? = nil, gateRefusal: String? = nil, agentName: String? = nil) {
            self.id = id
            self.projectID = projectID
            self.projectName = projectName
            self.projectPath = projectPath
            self.gate = gate
            self.title = title
            self.detail = detail
            self.since = since
            self.staleFileCount = staleFileCount
            self.gateRefusal = gateRefusal
            self.agentName = agentName
        }
    }

    /// One open project, reduced to what this list needs: the gates it has open
    /// right now, and the notices its inbox is holding.
    ///
    /// Not `Equatable`, unlike everything around it: `NotificationItem` is not,
    /// and a reading is an argument rather than a value anything holds — what is
    /// compared, redrawn and asserted on is the `Row` list that comes back.
    package struct ProjectReading: Sendable {

        /// An item the backlog has at `awaiting-approval`.
        package struct GatedItem: Equatable, Sendable {
            package let id: String
            package let title: String
            /// How many files conflict if the branch were merged onto the
            /// project's current base right now — nil when the branch is still
            /// clean, or when nothing has checked yet. Set from the same cache
            /// `GET /v1/backlog` reads (`BacklogViewModel.freshnessByItemID`),
            /// which a live git call in this struct's synchronous caller
            /// (`WaitingOnYou.capture`, read on every redraw) must not become.
            package let staleFileCount: Int?
            /// The gate's refusal when its last merge attempt was refused —
            /// `GateState.refused`'s reason — and nil otherwise. Read from the
            /// same ledger the item page and `GET /v1/backlog` read.
            package let gateRefusal: String?

            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(id: String, title: String, staleFileCount: Int? = nil, gateRefusal: String? = nil) {
                self.id = id
                self.title = title
                self.staleFileCount = staleFileCount
                self.gateRefusal = gateRefusal
            }
        }

        /// An agent with an `ask_human` nobody has answered.
        package struct AskingAgent: Equatable, Sendable {
            package let id: String
            package let name: String

            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        /// An open item `StaleItemSweep` found untouched past its window —
        /// `StaleItemSweep.FlaggedItem`, read down to what a row needs.
        package struct StaleItem: Equatable, Sendable {
            package let id: String
            package let title: String
            package let status: BacklogItemStatus
            /// When git last saw a commit reach this item — the row's clock,
            /// same as a notice's timestamp is for the other two kinds.
            package let lastTouched: Date

            /// The memberwise init, spelled out: a `package` type's synthesised one is
            /// internal to the package, and the app constructs this.
            package init(id: String, title: String, status: BacklogItemStatus, lastTouched: Date) {
                self.id = id
                self.title = title
                self.status = status
                self.lastTouched = lastTouched
            }
        }

        package let id: String
        package let name: String
        package let path: String
        package let gatedItems: [GatedItem]
        package let askingAgents: [AskingAgent]
        package let staleItems: [StaleItem]
        /// The project inbox's pending notifications, as the badged bell reads
        /// them. Only `.approval` and `.question` are looked at, and only to
        /// dress a gate that is already open.
        package let pending: [NotificationItem]

        package init(id: String, name: String, path: String,
             gatedItems: [GatedItem] = [], askingAgents: [AskingAgent] = [],
             staleItems: [StaleItem] = [], pending: [NotificationItem] = []) {
            self.id = id
            self.name = name
            self.path = path
            self.gatedItems = gatedItems
            self.askingAgents = askingAgents
            self.staleItems = staleItems
            self.pending = pending
        }
    }

    /// Every open gate, longest-waiting first.
    package let rows: [Row]

    package var isEmpty: Bool { rows.isEmpty }

    package var approvals: Int {
        rows.count { if case .approval = $0.gate { true } else { false } }
    }

    /// Of `approvals`, the ones whose merge gate already ran and refused — not
    /// waiting on a decision but on a fix, and counted apart so a queue of
    /// refusals never reads as a queue of decisions.
    package var refusedAtGate: Int {
        rows.count { $0.gateRefusal != nil }
    }

    package var questions: Int {
        rows.count { if case .question = $0.gate { true } else { false } }
    }

    package var staleFlags: Int {
        rows.count { if case .stale = $0.gate { true } else { false } }
    }

    /// The footer's line: what is waiting, by kind. A gate, a question and a
    /// stale flag are each cleared (or, for a flag, simply noticed) in a
    /// different place and take a different amount of a person, so the
    /// summary counts them apart rather than totalling them.
    package var summary: String {
        guard !isEmpty else { return "nothing is waiting on you" }
        var parts: [String] = []
        if approvals > 0 { parts.append("\(approvals) \(approvals == 1 ? "approval" : "approvals")") }
        if questions > 0 { parts.append("\(questions) \(questions == 1 ? "question" : "questions")") }
        if staleFlags > 0 { parts.append("\(staleFlags) stale") }
        return parts.joined(separator: " · ")
    }

    /// Reads the open projects into one list.
    ///
    /// Order is longest-waiting first, because that is the one ranking a person
    /// scanning this list is actually applying. A gate whose notice is gone
    /// sorts to the very top: the notice is only removed by a human dismissing
    /// it or by the gate having been raised before the inbox recorded such
    /// things, and either way it has been sitting there longer than anything
    /// that still has a timestamp. Ties break on project then id, so a refresh
    /// that changes nothing redraws the same order.
    package static func capture(projects: [ProjectReading]) -> WaitingOnYou {
        WaitingOnYou(rows: projects.flatMap(rows(for:)).sorted(by: precedes))
    }

    /// One project's gates, dressed with whatever its inbox is still holding
    /// about them.
    private static func rows(for project: ProjectReading) -> [Row] {
        approvalRows(for: project) + questionRows(for: project) + staleRows(for: project)
    }

    private static func approvalRows(for project: ProjectReading) -> [Row] {
        project.gatedItems.map { item in
            let notice = newestPending(in: project, matching: { notification in
                guard notification.type == .approval else { return false }
                return notification.itemID == item.id
            })
            return Row(
                id: "\(project.id)#approval:\(item.id)",
                projectID: project.id,
                projectName: project.name,
                projectPath: project.path,
                gate: .approval(itemID: item.id),
                // The item's own title, not the notice's: the notice's is a
                // sentence about a run ("Waiting for approval — …"), and what a
                // person is deciding about is the item.
                title: item.title,
                // A refusal is the newer fact than the summons that preceded
                // it, and the one a person has to read before deciding.
                detail: item.gateRefusal ?? notice.map(\.body).flatMap { $0.isEmpty ? nil : $0 },
                since: notice?.timestamp,
                staleFileCount: item.staleFileCount,
                gateRefusal: item.gateRefusal
            )
        }
    }

    private static func questionRows(for project: ProjectReading) -> [Row] {
        project.askingAgents.map { agent in
            let notice = newestPending(in: project, matching: { notification in
                notification.type == .question && notification.agentID == agent.id
            })
            return Row(
                id: "\(project.id)#question:\(agent.id)",
                projectID: project.id,
                projectName: project.name,
                projectPath: project.path,
                gate: .question(agentID: agent.id),
                // The notice's title here, unlike the approval above: it is the
                // only place the agent's question was ever written down as a
                // headline, and "\(name) needs input" is what the bell said.
                title: notice?.title ?? "\(agent.name) needs input",
                detail: notice.map(\.body).flatMap { $0.isEmpty ? nil : $0 },
                since: notice?.timestamp,
                agentName: agent.name
            )
        }
    }

    /// The project's stale flags, less any item that is also at its approval
    /// gate.
    ///
    /// One item is one row. `StaleItemSweep.openStatuses` counts
    /// `awaiting-approval` as open, so an item parked at the gate for longer
    /// than the sweep's window comes back flagged *and* gated — one thing
    /// waiting on one person, which the drawer must not list twice. The
    /// approval row is the one kept: it is the gate a person can actually
    /// clear, and its `since` already says how long it has been sitting there.
    /// Only a duplicate inside one project collapses — the same id gated here
    /// and flagged in another project names two different items.
    ///
    /// No notice ever dresses one of these — the flag has no run and no inbox
    /// entry behind it, only the git history the sweep already read. `since`
    /// carries the item's last touch instead of a notice's timestamp, which is
    /// what lets a long-untouched item still sort among the gates by how long
    /// it has been waiting.
    private static func staleRows(for project: ProjectReading) -> [Row] {
        let gatedIDs = Set(project.gatedItems.map(\.id))
        return project.staleItems.filter { !gatedIDs.contains($0.id) }.map { item in
            Row(
                id: "\(project.id)#stale:\(item.id)",
                projectID: project.id,
                projectName: project.name,
                projectPath: project.path,
                gate: .stale(itemID: item.id),
                title: item.title,
                detail: "still \(item.status.displayName.lowercased()) — nothing has touched it",
                since: item.lastTouched
            )
        }
    }

    /// The newest pending notice about one gate. Newest rather than first: a
    /// gate re-opened after a rejection raises a second notice, and the run
    /// waiting now is the one that just spoke.
    private static func newestPending(in project: ProjectReading,
                                      matching isAbout: (NotificationItem) -> Bool) -> NotificationItem? {
        project.pending
            .filter { $0.status == .pending && isAbout($0) }
            .max { $0.timestamp < $1.timestamp }
    }

    private static func precedes(_ lhs: Row, _ rhs: Row) -> Bool {
        let left = lhs.since ?? .distantPast
        let right = rhs.since ?? .distantPast
        if left != right { return left < right }
        if lhs.projectName != rhs.projectName { return lhs.projectName < rhs.projectName }
        return lhs.id < rhs.id
    }

    /// The memberwise init, spelled out: a `package` type's synthesised one is
    /// internal to the package, and the app constructs this.
    package init(rows: [Row]) {
        self.rows = rows
    }
}
