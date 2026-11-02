import KiteloopCore
import SwiftUI

/// Two lists, not one: an **inbox** of things blocking a human (question,
/// approval, error) above an ambient **activity** feed (completions, events).
/// Only the inbox is badged, so a marathon run's completion stream can't bury
/// the one agent that is waiting on an answer.
struct NotificationListView: View {
    let store: NotificationStoring
    /// Called after any mutation so the toolbar badge can follow along while
    /// the popover is still open.
    var onChange: (() -> Void)?
    /// The name to print for an agent id, given the notice's project. The
    /// store combines every project, so the caller looks it up across all of
    /// them; the default prints the id, as the popover always did.
    var agentName: (_ agentID: String, _ projectPath: String?) -> String = { id, _ in id }

    @State private var inboxItems: [NotificationItem] = []
    @State private var activityItems: [NotificationItem] = []
    @State private var resolvedItems: [NotificationItem] = []
    @State private var showResolved = false

    var body: some View {
        List {
            if inboxItems.isEmpty && activityItems.isEmpty && resolvedItems.isEmpty {
                // `PanelEmptyState`'s copy rules through `ContentUnavailableView`,
                // which is what a `List` row wants: sentence-case title, one
                // sentence saying what turns up here. There is no control to
                // name — a notification arrives because an agent sent one.
                let copy = PanelEmptyState.Copy.notifications
                ContentUnavailableView(copy.title, systemImage: copy.icon, description: Text(copy.message))
                    .accessibilityIdentifier("notifications-empty-state")
            }

            if !inboxItems.isEmpty {
                Section("Needs You") {
                    ForEach(inboxItems) { item in
                        NotificationRow(item: item, agentName: agentName) {
                            Task { await resolveItem(item) }
                        } onDismiss: {
                            Task { await dismissItem(item) }
                        }
                    }
                }
            }

            if !activityItems.isEmpty {
                Section {
                    ForEach(activityItems) { item in
                        // Ambient rows are read-only reports; there's nothing to
                        // "resolve", only to clear away.
                        NotificationRow(item: item, agentName: agentName, onResolve: nil) {
                            Task { await dismissItem(item) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Activity")
                        Spacer()
                        Button("Clear All") {
                            Task { await clearActivity() }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Dismiss every activity notification")
                    }
                }
            }

            if !resolvedItems.isEmpty {
                Section {
                    if showResolved {
                        ForEach(resolvedItems) { item in
                            NotificationRow(item: item, agentName: agentName, onResolve: nil, onDismiss: nil)
                        }
                    }
                } header: {
                    // Starts collapsed: acting on something has to make it leave
                    // the list, but it stays reachable rather than destroyed.
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showResolved.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showResolved ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Resolved (\(resolvedItems.count))")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Notifications")
        .task {
            // The list used to be a snapshot taken when the popover opened: a
            // question an agent asks a second later, or a gate a run reaches
            // while somebody watches for it, showed up only after a close and a
            // reopen. The popover builds this view when it opens and tears it
            // down when it closes, so SwiftUI's cancellation is what stops the
            // loop — no timer, no observer.
            guard !UITestingSupport.isUnitTesting else { return }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .refreshable { await refresh() }
    }

    private static let refreshInterval: Duration = .seconds(2)

    /// When a notice arrived, spelled as the chat spells a moment: the time
    /// alone for a notice from today, the date and the time for an earlier one.
    static func arrivalLabel(for item: NotificationItem, now: Date,
                             calendar: Calendar, locale: Locale) -> String {
        MessageBubble.sentTimeLabel(for: item.timestamp, now: now, calendar: calendar, locale: locale)
    }

    /// How many lines of a notice's body the row shows: two while it is
    /// folded, every line once it is opened — a store error's body is a path
    /// and then the reason, and two lines hold only the path.
    static func bodyLineLimit(isExpanded: Bool) -> Int? {
        isExpanded ? nil : 2
    }

    private func refresh() async {
        let contents = await NotificationListContents.load(from: store)
        inboxItems = contents.inbox
        activityItems = contents.activity
        resolvedItems = contents.resolved
    }

    private func resolveItem(_ item: NotificationItem) async {
        await store.markResolved(id: item.id)
        await refresh()
        onChange?()
    }

    private func dismissItem(_ item: NotificationItem) async {
        await store.dismiss(id: item.id)
        await refresh()
        onChange?()
    }

    private func clearActivity() async {
        await store.dismissAllPending(actionable: false)
        await refresh()
        onChange?()
    }
}

/// The three lists the popover shows, read off a store in one go. Lifted out of
/// the view so the split — and the fact that a later read sees what arrived
/// since — is assertable without a window.
struct NotificationListContents {
    /// Pending and actionable: what a human is blocking.
    let inbox: [NotificationItem]
    /// Pending but ambient: completions and events, there to watch, never badged.
    let activity: [NotificationItem]
    let resolved: [NotificationItem]

    static func load(from store: NotificationStoring) async -> NotificationListContents {
        let pending = await store.pending()
        return NotificationListContents(
            inbox: pending.filter { $0.isActionable },
            activity: pending.filter { !$0.isActionable },
            resolved: await store.resolved()
        )
    }
}

/// One open project's agents, keyed by id, for naming a notice's agent.
struct NotificationAgentRoster {
    let projectPath: String
    let names: [String: String]
}

extension NotificationListContents {
    /// The display name for `agentID`: from the roster whose path is the
    /// notice's project, or — for a notice that names no project — from the
    /// first roster that has the id. An id no open project carries is printed
    /// unchanged.
    static func agentName(_ agentID: String, projectPath: String?,
                          rosters: [NotificationAgentRoster]) -> String {
        let roster: NotificationAgentRoster?
        if let projectPath {
            roster = rosters.first { KiteloopProject.isSamePath($0.projectPath, projectPath) }
        } else {
            roster = rosters.first { $0.names[agentID] != nil }
        }
        return roster?.names[agentID] ?? agentID
    }
}

/// Where a notice's row leads. The item link comes first; a question with no
/// item leads to the agent that asked it, once it says which project that agent
/// lives in — a notice filed before questions carried one stays plain text.
enum NotificationRowLink: Equatable {
    case item(itemID: String, projectPath: String)
    case agent(agentID: String, projectPath: String)
    case none

    init(_ item: NotificationItem) {
        if let itemID = item.itemID, let projectPath = item.projectPath {
            self = .item(itemID: itemID, projectPath: projectPath)
        } else if item.type == .question, !item.agentID.isEmpty, let projectPath = item.projectPath {
            self = .agent(agentID: item.agentID, projectPath: projectPath)
        } else {
            self = .none
        }
    }
}

private struct NotificationRow: View {
    let item: NotificationItem
    let agentName: (_ agentID: String, _ projectPath: String?) -> String
    let onResolve: (() -> Void)?
    let onDismiss: (() -> Void)?
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                // A notice about an item — an approval gate is the one that
                // matters — links to it; a question links to the agent asking
                // it. Everything else is drawn exactly as it was.
                switch NotificationRowLink(item) {
                case .item(let itemID, let projectPath):
                    ItemLink(itemID, in: .path(projectPath)) {
                        notice
                    }
                case .agent(let agentID, let projectPath):
                    AgentLink(agentID, inProjectAt: projectPath,
                              displayName: agentName(agentID, projectPath)) {
                        notice
                    }
                case .none:
                    notice
                }
                // Outside the link: opening the body must not navigate, and a
                // selection can't be made inside a button.
                if !item.body.isEmpty {
                    noticeBody
                }
                HStack(spacing: 8) {
                    Text(agentName(item.agentID, item.projectPath))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(NotificationListView.arrivalLabel(for: item, now: Date(),
                                                           calendar: .current, locale: .current))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if let resolved = item.resolvedAt {
                        // With the reason, when something other than a click
                        // ended it: a row that closed itself has to say why, or
                        // it reads as one the operator forgot they handled.
                        Text(item.resolution.map { "Resolved \($0)" } ?? "Resolved")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text("\(resolved, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if onResolve != nil || onDismiss != nil {
                HStack(spacing: 4) {
                    if let onResolve {
                        Button(action: onResolve) {
                            Image(systemName: "checkmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Resolve")
                    }
                    if let onDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The title — what the notice is, with or without a link around it.
    /// Factored out so the linked and plain spellings above can't drift.
    private var notice: some View {
        Text(item.title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The body, folded to two lines with a chevron to open the rest.
    private var noticeBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(item.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(NotificationListView.bodyLineLimit(isExpanded: isExpanded))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Show less" : "Show more")
            .accessibilityLabel(isExpanded ? "Show less" : "Show more")
        }
    }

    private var iconName: String {
        switch item.type {
        case .approval: return "hand.raised"
        case .question: return "questionmark.circle"
        case .complete: return "checkmark.seal"
        case .error: return "exclamationmark.triangle"
        case .event: return "bolt"
        }
    }

    private var iconColor: Color {
        switch item.type {
        case .approval: return .orange
        case .question: return .blue
        case .complete: return .green
        case .error: return .red
        case .event: return .purple
        }
    }
}
