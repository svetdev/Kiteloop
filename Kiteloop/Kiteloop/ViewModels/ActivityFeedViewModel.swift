import Foundation
import KiteloopCore

/// Live feed of `KiteloopEvent`s (workflow transitions, approvals, autopilot
/// progress, inter-agent messages) for the bottom console's "Activity" tab.
/// Backfills recent history from the `EventBus`, then tails the live stream for
/// as long as the view is on screen.
@Observable
@MainActor
final class ActivityFeedViewModel {
    private let eventBus: EventBus
    static let consumerID = "__console_activity__"
    private let maxEvents = 400

    /// Newest first.
    private(set) var events: [KiteloopEvent] = []
    var typeFilter: KiteloopEvent.EventType?
    /// Text a row's source label or one of its payload values must contain,
    /// ignoring case. Blank matches every row.
    var searchText = ""
    /// Ids of every event `clear()` has hidden. The bus keeps its history, so a
    /// later `run()` backfills them again unless it drops these.
    private var clearedIDs: Set<String> = []
    /// Names an agent id as the team named it; any other source stays as is.
    private let agentName: (String) -> String

    init(eventBus: EventBus, agentName: @escaping (String) -> String = { $0 }) {
        self.eventBus = eventBus
        self.agentName = agentName
    }

    /// Drives the feed for the lifetime of the caller's `.task`. Backfills
    /// history, subscribes to every event type, and appends live events until
    /// the task is cancelled (view dismissed), which unsubscribes.
    ///
    /// The backfill and the subscription are taken in a single hop into the bus:
    /// two hops leave a window between them in which a published event reaches
    /// neither the history that was already copied nor a subscription that does
    /// not yet exist, and the feed never shows it.
    func run() async {
        let id = Self.consumerID
        let bus = eventBus
        let (backfill, stream) = await bus.backfillAndSubscribe(
            agentID: id,
            types: Set(KiteloopEvent.EventType.allCases)
        )
        events = backfill.reversed().filter { !clearedIDs.contains($0.id) }

        await withTaskCancellationHandler {
            for await event in stream {
                ingest(event)
            }
        } onCancel: {
            Task { await bus.unsubscribe(agentID: id) }
        }
    }

    func clear() {
        clearedIDs.formUnion(events.map(\.id))
        events.removeAll()
    }

    var filteredEvents: [KiteloopEvent] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { event in
            (typeFilter == nil || event.type == typeFilter)
                && (query.isEmpty || matches(event, query))
        }
    }

    private func matches(_ event: KiteloopEvent, _ query: String) -> Bool {
        sourceLabel(for: event).localizedCaseInsensitiveContains(query)
            || event.payload.values.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// The row's source label: an agent's display name, or the source as is
    /// when no agent carries that id ("Autopilot", "Coordinator", …).
    func sourceLabel(for event: KiteloopEvent) -> String {
        agentName(event.source)
    }

    /// The row's time label: the time with seconds for an event from today,
    /// the date and the time for one from an earlier day.
    static func timeLabel(for date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let isToday = calendar.isDate(date, inSameDayAs: now)
        let style = Date.FormatStyle(
            date: isToday ? .omitted : .abbreviated,
            time: .standard,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        return style.format(date)
    }

    /// Event types actually present in the feed, for the filter menu.
    var presentTypes: [KiteloopEvent.EventType] {
        var seen: Set<KiteloopEvent.EventType> = []
        var ordered: [KiteloopEvent.EventType] = []
        for event in events where !seen.contains(event.type) {
            seen.insert(event.type)
            ordered.append(event.type)
        }
        return ordered.sorted { $0.label < $1.label }
    }

    private func ingest(_ event: KiteloopEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events.removeLast(events.count - maxEvents)
        }
    }
}
