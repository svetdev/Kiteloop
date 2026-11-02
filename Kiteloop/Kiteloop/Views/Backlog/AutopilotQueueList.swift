import Foundation
import KiteloopCore

/// Composes the Autopilot panel's single item list.
///
/// The panel used to render the same items twice while a run was in flight: the
/// Backlog box listed everything in a pickup stage, and the Execution box listed
/// the run's upcoming items again under a QUEUE heading. Those are the same rows
/// — an item is queued *because* it is Ready — so a run spent a large slice of
/// the left column saying one thing twice.
///
/// This collapses them into one list. The items the run already owns come first,
/// in run order, then whatever is still free to pick, grouped by backlog section
/// as before. Every item appears exactly once and its glyph says which of the two
/// it is: a queued item is not a checkbox any more, because the pick was made
/// when the run started.
///
/// The item *in flight* is deliberately not here — it has its own row in the
/// Execution box, with the step indicator and span trace hanging off it — and
/// neither are finished items, which belong to History. So this list is exactly
/// "what hasn't had its turn yet".
enum AutopilotQueueList {

    /// What a row's glyph means.
    enum RowState: Equatable {
        /// Committed to the run in flight, not started. `position` is the item's
        /// 1-based place in run order, which is what the row's tooltip quotes.
        case queued(position: Int)
        /// Not in the run: free to pick, so it carries a selection checkbox.
        case selectable(isSelected: Bool)
    }

    struct Row: Identifiable {
        let item: BacklogItem
        let state: RowState
        var id: String { item.id }
    }

    /// A group of rows under one heading — the run-order group, or one backlog
    /// section.
    struct Group: Identifiable {
        let title: String
        /// True for the single run-order group, which always sorts first and
        /// whose rows must never be re-sorted: the order *is* the information.
        let isRunOrder: Bool
        let rows: [Row]
        /// A section could legitimately be named "Queue", so the kind is part of
        /// the identity rather than the title alone.
        var id: String { (isRunOrder ? "run/" : "section/") + title }
    }

    /// Builds the list, dropping empty groups.
    ///
    /// - Parameters:
    ///   - sections: the backlog as parsed, in file order.
    ///   - pickupStages: stages this project's flow lets autopilot start from.
    ///   - runQueue: the run's items, in run order.
    ///   - activeIndex: index in `runQueue` of the item in flight, or nil when no
    ///     run is in flight. Everything after it is still queued; the item itself
    ///     and everything before it has already had its turn, and is shown by the
    ///     Execution and History boxes instead.
    ///   - selectedItemIDs: what the user has ticked.
    static func groups(
        sections: [BacklogSection],
        pickupStages: [BacklogItemStatus],
        runQueue: [BacklogItem],
        activeIndex: Int?,
        selectedItemIDs: Set<String>
    ) -> [Group] {
        let queued: [Row] = {
            guard let activeIndex, activeIndex >= 0, activeIndex + 1 < runQueue.count else { return [] }
            return runQueue[(activeIndex + 1)...].enumerated().map { offset, item in
                Row(item: item, state: .queued(position: activeIndex + 2 + offset))
            }
        }()
        // Everything the run owns — the item in flight and the ones already done,
        // not just the queued tail. Their rows live in the Execution and History
        // boxes; leaving them pickable here is the same duplication in a
        // different box, and it only stayed hidden while the item in flight
        // happened to have moved out of a pickup stage.
        //
        // Gated on a run actually being in flight: once `activeIndex` is nil the
        // run is over and its (now inert) queue must not strand its items behind
        // a queue nobody is working through.
        let runOwnedIDs: Set<String> = activeIndex == nil ? [] : Set(runQueue.map(\.id))

        var groups: [Group] = []
        if !queued.isEmpty {
            groups.append(Group(title: "Queue", isRunOrder: true, rows: queued))
        }
        for section in sections {
            // A run's item is filtered out here rather than left in both places:
            // this is the duplication the merged list exists to remove.
            let rows = section.items
                .filter { pickupStages.contains($0.status) && !runOwnedIDs.contains($0.id) }
                .map { Row(item: $0, state: .selectable(isSelected: selectedItemIDs.contains($0.id))) }
            if !rows.isEmpty {
                groups.append(Group(title: section.name, isRunOrder: false, rows: rows))
            }
        }
        return groups
    }

    /// What a console row shows *after* the id it leads with.
    ///
    /// Rows live in a column that is 280pt wide at its narrowest, so the title is
    /// the first thing truncation eats — and a backlog's titles tend to open with
    /// the same few words, which is exactly the part that survives. Leading with
    /// the id keeps the identifying half of the row legible at any width; history
    /// rows have done this since the branch chip, which drops the shared
    /// `kiteloop/` prefix for the same reason.
    ///
    /// Nil means the row is the id and nothing else: an untitled item (a backlog
    /// line with no `| title`), or a title that is just the id again, where a
    /// second copy would only take room from the badges.
    static func rowTitle(for item: BacklogItem) -> String? {
        let title = item.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != item.id else { return nil }
        return title
    }

    /// The ids the list is actually offering to pick. What "All" selects and what
    /// the "n selected" count is measured against — a queued row is no longer a
    /// choice, so counting it would report a selection with nothing ticked on
    /// screen to explain it.
    static func selectableIDs(in groups: [Group]) -> Set<String> {
        Set(groups.lazy.filter { !$0.isRunOrder }.flatMap(\.rows).map(\.id))
    }

    /// The part of a selection the list still offers as a row. A ticked id whose
    /// item has finished, or is held by a run in flight, has no checkbox left to
    /// point at — Run, the count and All/Clear read this, and a start sends only
    /// this, so a finished item is never handed back to the autopilot.
    static func pickableSelection(_ selection: Set<String>, in groups: [Group]) -> Set<String> {
        selection.intersection(selectableIDs(in: groups))
    }
}
