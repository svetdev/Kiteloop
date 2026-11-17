import Foundation

/// What a caller asked `POST /v1/runs` to run: one item, or a list of them in
/// the order they are to run.
///
/// Running several chosen items used to take a script outside the app that
/// started one, waited for it and started the next. A list hands that order to
/// the autopilot instead, as one run: the items go through the same pickup
/// gates, review and approval gate as a single item, one after another, and
/// the run ends at the end of the list or at the budget. It is a start a
/// caller asked for — nothing outside the list is picked up, and the autonomy
/// dial is not consulted or changed.
///
/// The order is the caller's, which is the one thing a plain start cannot
/// carry: a selection is a set, walked lane first and then in the order the
/// backlog file is written.
package struct RunRequest: Equatable, Sendable {
    package let project: String
    /// The item ids, in the order they run. Never empty, never repeating.
    package let ids: [String]
    /// Whether the caller posted `items`. A single `item` is a list of one
    /// whose order says nothing, so it is run exactly as it always was.
    package let isList: Bool

    package init(project: String, ids: [String], isList: Bool) {
        self.project = project
        self.ids = ids
        self.isList = isList
    }

    /// Why a body is not a run request, in the words the 400 answers with.
    package struct Invalid: Error, Equatable {
        package let message: String
    }

    static let shape = "Body must be JSON: { \"project\": \"…\", \"item\": \"…\" } "
        + "or { \"project\": \"…\", \"items\": [\"…\", \"…\"] }"

    /// The order a list run walks, or nil for a single item — what the
    /// autopilot is handed beside the selection.
    package var requestedOrder: [String]? { isList ? ids : nil }

    package static func parse(_ body: Data) -> Result<RunRequest, Invalid> {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let project = json["project"] as? String else {
            return .failure(Invalid(message: shape))
        }
        let single = (json["item"] as? String) ?? (json["itemId"] as? String)
        guard let listed = json["items"] else {
            guard let single else { return .failure(Invalid(message: shape)) }
            return .success(RunRequest(project: project, ids: [single], isList: false))
        }
        guard single == nil else {
            return .failure(Invalid(message: "Give either \"item\" or \"items\", not both"))
        }
        return list(listed).map { RunRequest(project: project, ids: $0, isList: true) }
    }

    /// `items` as an order: strings, at least one, none twice. A repeated id
    /// is refused rather than collapsed, because which of its two places the
    /// caller meant is not something to guess.
    private static func list(_ value: Any) -> Result<[String], Invalid> {
        guard let ids = value as? [String] else {
            return .failure(Invalid(message: "\"items\" must be an array of backlog item ids"))
        }
        guard !ids.isEmpty else {
            return .failure(Invalid(message: "\"items\" is empty — name at least one backlog item"))
        }
        var seen = Set<String>()
        if let repeated = ids.first(where: { !seen.insert($0).inserted }) {
            return .failure(Invalid(message: "\"items\" names '\(repeated)' more than once"))
        }
        return .success(ids)
    }

    /// The first id, in the order given, that the backlog does not hold.
    package func firstUnknown(among known: Set<String>) -> String? {
        ids.first { !known.contains($0) }
    }

    /// `items` in the order a run walks them. With an order asked for, that
    /// order; without one, lane first and then the file's, as ever. An item
    /// the order does not name follows the ones it does, in lane order.
    package static func runOrder(_ items: [BacklogItem], requested: [String]?) -> [BacklogItem] {
        guard let requested else { return BacklogLane.ordered(items) }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let named = Set(requested)
        return requested.compactMap { byID[$0] } + BacklogLane.ordered(items.filter { !named.contains($0.id) })
    }

    /// Where the item in flight sits in the run's order, or nil when nothing
    /// is in flight.
    package static func position(of itemID: String?, in order: [String]) -> Int? {
        itemID.flatMap { order.firstIndex(of: $0) }
    }
}
