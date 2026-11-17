import Foundation

/// The starts `POST /v1/runs` has asked for and not yet had an answer to —
/// one per project at most.
///
/// A run request is held until the autopilot has decided: an execution
/// exists, or there will not be one. While the pickup checks run there is no
/// run in flight to refuse a second request against, so a second one for the
/// same project used to enter the start again — and a client whose first
/// request is being held is exactly the client that sends a second. This is
/// what the second request is refused on: the first start is recorded here
/// before it is asked for and removed when it is decided, started or refused.
///
/// A second start is refused whatever it names — the same item, another one
/// or a list — because a project runs one start at a time; the refusal names
/// what the first one asked for. Nothing here reads a clock: a start is in
/// its checks from the request that began it until the decision that ends it.
package struct StartsInChecks: Equatable, Sendable {

    private var itemsByProject: [String: [String]] = [:]

    package init() {}

    /// Why a start for `project` cannot be asked for now — the words the 409
    /// answers with — or nil when no start of its is still deciding.
    package func refusal(project: String) -> String? {
        guard let items = itemsByProject[project] else { return nil }
        return Self.refusal(items: items)
    }

    /// Records a start of `items` for `project` as deciding, and returns nil;
    /// or records nothing and returns the refusal, when one already is.
    package mutating func claim(project: String, items: [String]) -> String? {
        if let refusal = refusal(project: project) { return refusal }
        itemsByProject[project] = items
        return nil
    }

    /// The start for `project` was decided.
    package mutating func release(project: String) {
        itemsByProject.removeValue(forKey: project)
    }

    static func refusal(items: [String]) -> String {
        let named = items.map { "'\($0)'" }.joined(separator: ", ")
        let subject = items.count == 1 ? "item \(named)" : "items \(named)"
        return "A start for this project is already in its pickup checks — \(subject). "
            + "It answers its own request with the run it began or the reason there is none; "
            + "nothing was started for this one."
    }
}
